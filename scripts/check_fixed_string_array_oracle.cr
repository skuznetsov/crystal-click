require "file_utils"
require "./../src/crystal_click"

W33_ORACLE_KEYS  = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64, 17_u64, 19_u64, 21_u64, 25_u64, 31_u64, 40_u64]
W33_ORACLE_PLAIN = [
  [] of String,
  [String.new(Bytes[0, 0, 0, 0]), String.new(Bytes[0x61_u8, 0, 0x62_u8, 0xff_u8])],
  [String.new(Bytes[0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8]), String.new(Bytes[0x78_u8, 0xff_u8, 0, 0xff_u8])],
  [] of String,
  [String.new(Bytes[0xc3_u8, 0xa9_u8, 0, 0])],
  [String.new(Bytes[0, 0, 0, 0])],
  [] of String,
  [String.new(Bytes[0x61_u8, 0, 0, 0]), String.new(Bytes[0x62_u8, 0, 0, 0]), String.new(Bytes[0x63_u8, 0, 0, 0])],
  [] of String,
  [String.new(Bytes[0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8])],
  [String.new(Bytes[0xc3_u8, 0xa9_u8, 0, 0])],
  [] of String,
  [String.new(Bytes[0, 0, 0, 0])],
] of Array(String)
W33_ORACLE_NULLABLE = [
  [] of String?,
  [nil, String.new(Bytes[0, 0, 0, 0]), String.new(Bytes[0x71_u8, 0xff_u8, 0, 0])],
  [nil] of String?,
  [String.new(Bytes[0, 0, 0, 0]), nil] of String?,
  [] of String?,
  [String.new(Bytes[0xff_u8, 0, 0, 0])] of String?,
  [nil, String.new(Bytes[0, 0, 0, 0])] of String?,
  [String.new(Bytes[0, 0, 0, 0])] of String?,
  [String.new(Bytes[0, 0, 0, 0]), nil, String.new(Bytes[0x61_u8, 0, 0x62_u8, 0xff_u8])] of String?,
  [] of String?,
  [nil] of String?,
  [] of String?,
  [nil, String.new(Bytes[0xff_u8, 0, 0, 0])] of String?,
] of Array(String?)

def w33_oracle_clickhouse(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  result = Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse query failed (#{result.exit_code}): #{query}" unless result.success?
  output.to_s
end

def w33_append_u64(io : IO, value : UInt64) : Nil
  8.times { |byte| io.write_byte(((value >> (byte * 8)) & 0xff_u64).to_u8) }
end

def w33_append_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

def w33_append_fixed_array(io : IO, values : Array(String)) : Nil
  w33_append_varuint(io, values.size.to_u64)
  values.each do |value|
    raise "oracle FixedString value must have four bytes" unless value.bytesize == 4
    io.write(value.to_slice)
  end
end

def w33_append_nullable_fixed_array(io : IO, values : Array(String?)) : Nil
  w33_append_varuint(io, values.size.to_u64)
  values.each do |value|
    if item = value
      raise "oracle Nullable(FixedString) value must have four bytes" unless item.bytesize == 4
      io.write_byte(0_u8)
      io.write(item.to_slice)
    else
      io.write_byte(1_u8)
    end
  end
end

def w33_expected_pair_rowbinary(rows : Array(Int32)) : Bytes
  io = IO::Memory.new
  rows.each do |index|
    w33_append_u64(io, W33_ORACLE_KEYS[index])
    w33_append_fixed_array(io, W33_ORACLE_PLAIN[index])
    w33_append_nullable_fixed_array(io, W33_ORACLE_NULLABLE[index])
  end
  io.to_slice
end

def w33_expected_plain_rowbinary(rows : Array(Int32)) : Bytes
  io = IO::Memory.new
  rows.each do |index|
    w33_append_u64(io, W33_ORACLE_KEYS[index])
    w33_append_fixed_array(io, W33_ORACLE_PLAIN[index])
  end
  io.to_slice
end

def w33_expected_nullable_rowbinary(rows : Array(Int32)) : Bytes
  io = IO::Memory.new
  rows.each do |index|
    w33_append_u64(io, W33_ORACLE_KEYS[index])
    w33_append_nullable_fixed_array(io, W33_ORACLE_NULLABLE[index])
  end
  io.to_slice
end

def w33_empty_array_rowbinary(keys : Array(UInt64)) : Bytes
  io = IO::Memory.new
  keys.each do |key|
    w33_append_u64(io, key)
    w33_append_varuint(io, 0_u64)
  end
  io.to_slice
end

def w33_assert_rowbinary(actual : String, expected : Bytes, label : String) : Nil
  unless actual.to_slice == expected
    raise "#{label} RowBinary mismatch: expected #{expected.size} bytes, got #{actual.bytesize}"
  end
end

def w33_attach_part(binary : String, store : String, table : String, schema : String, part : String) : Nil
  w33_oracle_clickhouse(binary, store, <<-SQL)
  CREATE TABLE default.#{table}
  (
      #{schema}
  )
  ENGINE = MergeTree
  ORDER BY pk
  SETTINGS
      index_granularity = 2,
      index_granularity_bytes = 10485760,
      enable_mixed_granularity_parts = 1,
      min_rows_for_wide_part = 0,
      min_bytes_for_wide_part = 0,
      compress_marks = 0,
      min_compress_block_size = 0,
      max_compress_block_size = 4096,
      ratio_of_defaults_for_sparse_serialization = 1.0,
      default_compression_codec = 'LZ4';
  SQL
  data_path = w33_oracle_clickhouse(
    binary,
    store,
    "SELECT data_paths[1] FROM system.tables WHERE database = 'default' AND name = '#{table}' FORMAT TSVRaw"
  ).strip
  raise "no ClickHouse data path for #{table}" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  w33_oracle_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  integrity = w33_oracle_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "CHECK TABLE failed for #{table}: #{integrity.inspect}" unless integrity == "all_1_1_0\t1"
end

def w33_check_full_and_range(binary : String, store : String, table : String, columns : String, full : Bytes, ranged : Bytes) : Nil
  full_actual = w33_oracle_clickhouse(binary, store, "SELECT pk, #{columns} FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  w33_assert_rowbinary(full_actual, full, "#{table} full")
  range_actual = w33_oracle_clickhouse(binary, store, "SELECT pk, #{columns} FROM default.#{table} WHERE pk >= 4 AND pk < 21 ORDER BY pk FORMAT RowBinary")
  w33_assert_rowbinary(range_actual, ranged, "#{table} key range")
end

binary = ENV.fetch("CLICKHOUSE_BIN")
store = ENV.fetch("CLICKHOUSE_STORE")
root = ENV.fetch("ORACLE_ROOT")
stock_part = ENV.fetch("STOCK_PART")
stock_keyed_part = ENV.fetch("STOCK_KEYED_PART")
all_rows = (0...W33_ORACLE_KEYS.size).map(&.to_i32)
range_rows = W33_ORACLE_KEYS.each_with_index.compact_map do |key, index|
  index.to_i32 if key >= 4_u64 && key < 21_u64
end.to_a

w33_attach_part(binary, store, "fixed_string_array_stock", <<-SCHEMA, stock_part)
  pk UInt64,
  plain Array(FixedString(4)),
  maybe Array(Nullable(FixedString(4)))
  SCHEMA
w33_check_full_and_range(
  binary,
  store,
  "fixed_string_array_stock",
  "plain, maybe",
  w33_expected_pair_rowbinary(all_rows),
  w33_expected_pair_rowbinary(range_rows),
)

w33_attach_part(binary, store, "fixed_string_array_stock_keyed", <<-SCHEMA, stock_keyed_part)
  pk UInt64,
  plain Array(FixedString(4)),
  maybe Array(Nullable(FixedString(4)))
  SCHEMA
w33_check_full_and_range(
  binary,
  store,
  "fixed_string_array_stock_keyed",
  "plain, maybe",
  w33_expected_pair_rowbinary(all_rows),
  w33_expected_pair_rowbinary(range_rows),
)

plain_part = File.join(root, "writer-plain-part")
CrystalClick::WidePartWriter.write_uint64_array_fixed_string_pair(
  plain_part,
  "pk",
  W33_ORACLE_KEYS.to_unsafe.to_slice(W33_ORACLE_KEYS.size),
  "payload",
  W33_ORACLE_PLAIN.to_unsafe.to_slice(W33_ORACLE_PLAIN.size),
  width: 4,
  rows_per_mark: 2,
)
w33_attach_part(binary, store, "fixed_string_array_writer_plain", "pk UInt64, payload Array(FixedString(4))", plain_part)
w33_check_full_and_range(
  binary,
  store,
  "fixed_string_array_writer_plain",
  "payload",
  w33_expected_plain_rowbinary(all_rows),
  w33_expected_plain_rowbinary(range_rows),
)

nullable_part = File.join(root, "writer-nullable-part")
CrystalClick::WidePartWriter.write_uint64_array_nullable_fixed_string_pair(
  nullable_part,
  "pk",
  W33_ORACLE_KEYS.to_unsafe.to_slice(W33_ORACLE_KEYS.size),
  "payload",
  W33_ORACLE_NULLABLE.to_unsafe.to_slice(W33_ORACLE_NULLABLE.size),
  width: 4,
  rows_per_mark: 2,
)
w33_attach_part(binary, store, "fixed_string_array_writer_nullable", "pk UInt64, payload Array(Nullable(FixedString(4)))", nullable_part)
w33_check_full_and_range(
  binary,
  store,
  "fixed_string_array_writer_nullable",
  "payload",
  w33_expected_nullable_rowbinary(all_rows),
  w33_expected_nullable_rowbinary(range_rows),
)

empty_keys = [1_u64, 4_u64]
empty_range_keys = [4_u64]
empty_plain_part = File.join(root, "writer-empty-plain-part")
empty_plain_values = [[] of String, [] of String]
CrystalClick::WidePartWriter.write_uint64_array_fixed_string_pair(
  empty_plain_part,
  "pk",
  empty_keys.to_unsafe.to_slice(empty_keys.size),
  "payload",
  empty_plain_values.to_unsafe.to_slice(empty_plain_values.size),
  width: 4,
  rows_per_mark: 1,
)
w33_attach_part(binary, store, "fixed_string_array_writer_empty_plain", "pk UInt64, payload Array(FixedString(4))", empty_plain_part)
w33_check_full_and_range(
  binary,
  store,
  "fixed_string_array_writer_empty_plain",
  "payload",
  w33_empty_array_rowbinary(empty_keys),
  w33_empty_array_rowbinary(empty_range_keys),
)

empty_nullable_part = File.join(root, "writer-empty-nullable-part")
empty_nullable_values = [[] of String?, [] of String?]
CrystalClick::WidePartWriter.write_uint64_array_nullable_fixed_string_pair(
  empty_nullable_part,
  "pk",
  empty_keys.to_unsafe.to_slice(empty_keys.size),
  "payload",
  empty_nullable_values.to_unsafe.to_slice(empty_nullable_values.size),
  width: 4,
  rows_per_mark: 1,
)
w33_attach_part(binary, store, "fixed_string_array_writer_empty_nullable", "pk UInt64, payload Array(Nullable(FixedString(4)))", empty_nullable_part)
w33_check_full_and_range(
  binary,
  store,
  "fixed_string_array_writer_empty_nullable",
  "payload",
  w33_empty_array_rowbinary(empty_keys),
  w33_empty_array_rowbinary(empty_range_keys),
)

puts "PASS stock serializer variants and Crystal writers: CHECK TABLE plus exact full/key-range RowBinary, including all-empty plain/nullable arrays"
