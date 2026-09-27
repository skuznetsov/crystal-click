require "file_utils"
require "./../src/crystal_click"

W32_ORACLE_KEYS   = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64, 17_u64, 19_u64, 21_u64, 25_u64]
W32_ORACLE_VALUES = [
  [] of String?,
  [] of String?,
  [nil, "", "a\x00b"] of String?,
  ["", String.new(Bytes[0x42_u8, 0xff_u8])] of String?,
  [nil, nil] of String?,
  [nil] of String?,
  [] of String?,
  [] of String?,
  ["", ""] of String?,
  [""] of String?,
  ["é", "tail\x00x"] of String?,
]

def oracle_clickhouse(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  result = Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse query failed (#{result.exit_code}): #{query}" unless result.success?
  output.to_s
end

def append_u64(io : IO, value : UInt64) : Nil
  8.times { |byte| io.write_byte(((value >> (byte * 8)) & 0xff_u64).to_u8) }
end

def append_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

def append_nullable_string_array(io : IO, values : Array(String?)) : Nil
  append_varuint(io, values.size.to_u64)
  values.each do |value|
    if value.nil?
      io.write_byte(1_u8)
    else
      bytes = value.not_nil!.to_slice
      io.write_byte(0_u8)
      append_varuint(io, bytes.size.to_u64)
      io.write(bytes)
    end
  end
end

def expected_rowbinary(rows : Array(Int32)) : Bytes
  io = IO::Memory.new
  rows.each do |index|
    append_u64(io, W32_ORACLE_KEYS[index])
    append_nullable_string_array(io, W32_ORACLE_VALUES[index])
  end
  io.to_slice
end

def assert_rowbinary(actual : String, expected : Bytes, label : String) : Nil
  unless actual.to_slice == expected
    raise "#{label} RowBinary mismatch: expected #{expected.size} bytes, got #{actual.bytesize}"
  end
end

def attach_part(binary : String, store : String, table : String, part : String) : Nil
  oracle_clickhouse(binary, store, <<-SQL)
  CREATE TABLE default.#{table}
  (
      pk UInt64,
      a Array(Nullable(String))
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
  data_path = oracle_clickhouse(
    binary,
    store,
    "SELECT data_paths[1] FROM system.tables WHERE database = 'default' AND name = '#{table}' FORMAT TSVRaw"
  ).strip
  raise "no ClickHouse data path for #{table}" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  oracle_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  integrity = oracle_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "CHECK TABLE failed for #{table}: #{integrity.inspect}" unless integrity == "all_1_1_0\t1"
end

binary = ENV.fetch("CLICKHOUSE_BIN")
store = ENV.fetch("CLICKHOUSE_STORE")
root = ENV.fetch("ORACLE_ROOT")
selected = W32_ORACLE_KEYS.each_with_index.compact_map do |key, index|
  index.to_i32 if key >= 4_u64 && key < 21_u64
end.to_a
all_rows = (0...W32_ORACLE_KEYS.size).map(&.to_i32)

attach_part(binary, store, "array_nullable_string_stock", ENV.fetch("STOCK_PART"))
stock_full = oracle_clickhouse(binary, store, "SELECT pk, a FROM default.array_nullable_string_stock ORDER BY pk FORMAT RowBinary")
assert_rowbinary(stock_full, expected_rowbinary(all_rows), "stock full")
stock_range = oracle_clickhouse(binary, store, "SELECT pk, a FROM default.array_nullable_string_stock WHERE pk >= 4 AND pk < 21 ORDER BY pk FORMAT RowBinary")
assert_rowbinary(stock_range, expected_rowbinary(selected), "stock range")

writer_part = File.join(root, "writer-part")
CrystalClick::WidePartWriter.write_uint64_array_nullable_string_pair(
  writer_part,
  "pk",
  W32_ORACLE_KEYS.to_unsafe.to_slice(W32_ORACLE_KEYS.size),
  "a",
  W32_ORACLE_VALUES.to_unsafe.to_slice(W32_ORACLE_VALUES.size),
  rows_per_mark: 2
)
attach_part(binary, store, "array_nullable_string_writer", writer_part)
writer_full = oracle_clickhouse(binary, store, "SELECT pk, a FROM default.array_nullable_string_writer ORDER BY pk FORMAT RowBinary")
assert_rowbinary(writer_full, expected_rowbinary(all_rows), "writer full")
writer_range = oracle_clickhouse(binary, store, "SELECT pk, a FROM default.array_nullable_string_writer WHERE pk >= 4 AND pk < 21 ORDER BY pk FORMAT RowBinary")
assert_rowbinary(writer_range, expected_rowbinary(selected), "writer range")

puts "stock and writer Array(Nullable(String)) parts passed CHECK TABLE and direct full/range RowBinary"
