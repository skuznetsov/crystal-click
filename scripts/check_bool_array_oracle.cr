require "file_utils"
require "./../src/crystal_click"

W34_ORACLE_KEYS  = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64, 17_u64, 19_u64, 21_u64, 25_u64, 31_u64, 40_u64]
W34_ORACLE_PLAIN = [
  [] of Bool,
  [false, true],
  [true],
  [] of Bool,
  [false],
  [true, false],
  [] of Bool,
  [true],
  [false, true],
  [] of Bool,
  [false],
  [true],
  [false, false],
] of Array(Bool)
W34_ORACLE_NULLABLE = [
  [] of Bool?,
  [nil, false, true] of Bool?,
  [false, nil] of Bool?,
  [true] of Bool?,
  [] of Bool?,
  [nil, true] of Bool?,
  [false] of Bool?,
  [nil, false] of Bool?,
  [] of Bool?,
  [false, nil] of Bool?,
  [true] of Bool?,
  [nil] of Bool?,
  [true, nil] of Bool?,
] of Array(Bool?)

def w34_oracle_clickhouse(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  result = Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse query failed (#{result.exit_code}): #{query}" unless result.success?
  output.to_s
end

def w34_append_u64(io : IO, value : UInt64) : Nil
  8.times { |byte| io.write_byte(((value >> (byte * 8)) & 0xff_u64).to_u8) }
end

def w34_append_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

def w34_append_bool_array(io : IO, values : Array(Bool)) : Nil
  w34_append_varuint(io, values.size.to_u64)
  values.each { |value| io.write_byte(value ? 1_u8 : 0_u8) }
end

def w34_append_nullable_bool_array(io : IO, values : Array(Bool?)) : Nil
  w34_append_varuint(io, values.size.to_u64)
  values.each do |value|
    if value.nil?
      io.write_byte(1_u8)
    else
      io.write_byte(0_u8)
      io.write_byte(value.as(Bool) ? 1_u8 : 0_u8)
    end
  end
end

def w34_expected_pair_rowbinary(rows : Array(Int32)) : Bytes
  io = IO::Memory.new
  rows.each do |index|
    w34_append_u64(io, W34_ORACLE_KEYS[index])
    w34_append_bool_array(io, W34_ORACLE_PLAIN[index])
    w34_append_nullable_bool_array(io, W34_ORACLE_NULLABLE[index])
  end
  io.to_slice
end

def w34_expected_plain_rowbinary(rows : Array(Int32)) : Bytes
  io = IO::Memory.new
  rows.each do |index|
    w34_append_u64(io, W34_ORACLE_KEYS[index])
    w34_append_bool_array(io, W34_ORACLE_PLAIN[index])
  end
  io.to_slice
end

def w34_expected_nullable_rowbinary(rows : Array(Int32)) : Bytes
  io = IO::Memory.new
  rows.each do |index|
    w34_append_u64(io, W34_ORACLE_KEYS[index])
    w34_append_nullable_bool_array(io, W34_ORACLE_NULLABLE[index])
  end
  io.to_slice
end

def w34_hex_context(bytes : Bytes, start : Int32, count : Int32) : String
  String.build do |io|
    index = start
    finish = Math.min(bytes.size, start + count)
    while index < finish
      io << ' ' if index > start
      io << bytes[index].to_s(16).rjust(2, '0')
      index += 1
    end
  end
end

def w34_assert_rowbinary(actual : String, expected : Bytes, label : String) : Nil
  unless actual.to_slice == expected
    actual_bytes = actual.to_slice
    shared = Math.min(actual_bytes.size, expected.size)
    first_difference = 0
    while first_difference < shared && actual_bytes[first_difference] == expected[first_difference]
      first_difference += 1
    end
    wanted = first_difference < expected.size ? expected[first_difference].to_s(16).rjust(2, '0') : "<eof>"
    observed = first_difference < actual_bytes.size ? actual_bytes[first_difference].to_s(16).rjust(2, '0') : "<eof>"
    context_start = Math.max(0, first_difference - 8)
    raise "#{label} RowBinary mismatch: expected #{expected.size} bytes, got #{actual.bytesize}; first difference at byte #{first_difference}: expected #{wanted}, got #{observed}; expected context [#{w34_hex_context(expected, context_start, 24)}], actual context [#{w34_hex_context(actual_bytes, context_start, 24)}]"
  end
end

def w34_attach_part(binary : String, store : String, table : String, schema : String, part : String) : Nil
  w34_oracle_clickhouse(binary, store, <<-SQL)
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
  data_path = w34_oracle_clickhouse(
    binary,
    store,
    "SELECT data_paths[1] FROM system.tables WHERE database = 'default' AND name = '#{table}' FORMAT TSVRaw"
  ).strip
  raise "no ClickHouse data path for #{table}" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  w34_oracle_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  integrity = w34_oracle_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "CHECK TABLE failed for #{table}: #{integrity.inspect}" unless integrity == "all_1_1_0\t1"
  puts "CHECK TABLE #{table}: all_1_1_0\t1"
end

def w34_check_full_and_range(binary : String, store : String, table : String, columns : String, full : Bytes, ranged : Bytes) : Nil
  full_actual = w34_oracle_clickhouse(binary, store, "SELECT pk, #{columns} FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  w34_assert_rowbinary(full_actual, full, "#{table} full")
  range_actual = w34_oracle_clickhouse(binary, store, "SELECT pk, #{columns} FROM default.#{table} WHERE pk >= 4 AND pk < 21 ORDER BY pk FORMAT RowBinary")
  w34_assert_rowbinary(range_actual, ranged, "#{table} key range")
  puts "RowBinary #{table}: full #{full.size} bytes exact; key range #{ranged.size} bytes exact"
end

binary = ENV.fetch("CLICKHOUSE_BIN")
store = ENV.fetch("CLICKHOUSE_STORE")
root = ENV.fetch("ORACLE_ROOT")
stock_part = ENV.fetch("STOCK_PART")
stock_keyed_part = ENV.fetch("STOCK_KEYED_PART")
all_rows = (0...W34_ORACLE_KEYS.size).map(&.to_i32)
range_rows = W34_ORACLE_KEYS.each_with_index.compact_map do |key, index|
  index.to_i32 if key >= 4_u64 && key < 21_u64
end.to_a

schema = <<-SCHEMA
  pk UInt64,
  plain Array(Bool),
  maybe Array(Nullable(Bool))
  SCHEMA

[{"bool_array_stock", stock_part}, {"bool_array_stock_keyed", stock_keyed_part}].each do |table, part|
  w34_attach_part(binary, store, table, schema, part)
  w34_check_full_and_range(
    binary,
    store,
    table,
    "plain, maybe",
    w34_expected_pair_rowbinary(all_rows),
    w34_expected_pair_rowbinary(range_rows),
  )
end

plain_part = File.join(root, "writer-plain-part")
CrystalClick::WidePartWriter.write_uint64_array_bool_pair(
  plain_part,
  "pk",
  W34_ORACLE_KEYS.to_unsafe.to_slice(W34_ORACLE_KEYS.size),
  "payload",
  W34_ORACLE_PLAIN.to_unsafe.to_slice(W34_ORACLE_PLAIN.size),
  rows_per_mark: 2,
)
plain_table = "bool_array_writer_plain"
w34_attach_part(binary, store, plain_table, "pk UInt64, payload Array(Bool)", plain_part)
w34_check_full_and_range(
  binary,
  store,
  plain_table,
  "payload",
  w34_expected_plain_rowbinary(all_rows),
  w34_expected_plain_rowbinary(range_rows),
)

nullable_part = File.join(root, "writer-nullable-part")
CrystalClick::WidePartWriter.write_uint64_array_nullable_bool_pair(
  nullable_part,
  "pk",
  W34_ORACLE_KEYS.to_unsafe.to_slice(W34_ORACLE_KEYS.size),
  "payload",
  W34_ORACLE_NULLABLE.to_unsafe.to_slice(W34_ORACLE_NULLABLE.size),
  rows_per_mark: 2,
)
nullable_table = "bool_array_writer_nullable"
w34_attach_part(binary, store, nullable_table, "pk UInt64, payload Array(Nullable(Bool))", nullable_part)
w34_check_full_and_range(
  binary,
  store,
  nullable_table,
  "payload",
  w34_expected_nullable_rowbinary(all_rows),
  w34_expected_nullable_rowbinary(range_rows),
)
