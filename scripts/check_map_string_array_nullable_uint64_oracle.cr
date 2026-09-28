require "file_utils"
require "../src/crystal_click"

W68_ORACLE_KEYS = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64]
W68_ORACLE_ROWS = [
  [
    {"dup", [nil, 0_u64] of UInt64?},
    {"dup", [] of UInt64?},
  ] of Tuple(String, Array(UInt64?)),
  [] of Tuple(String, Array(UInt64?)),
  [{"empty", [] of UInt64?}] of Tuple(String, Array(UInt64?)),
  [
    {"null", [nil] of UInt64?},
    {"zero", [0_u64] of UInt64?},
  ] of Tuple(String, Array(UInt64?)),
  [{"all-null", [nil, nil] of UInt64?}] of Tuple(String, Array(UInt64?)),
  [{"also-null", [nil] of UInt64?}] of Tuple(String, Array(UInt64?)),
  [{"tail", [UInt64::MAX] of UInt64?}] of Tuple(String, Array(UInt64?)),
] of Array(Tuple(String, Array(UInt64?)))

W68_ORACLE_STREAMS = [
  "payload.size0",
  "payload%2Ekeys.size",
  "payload%2Ekeys",
  "payload%2Evalues.size1",
  "payload%2Evalues.null",
  "payload%2Evalues",
]
W68_ORACLE_MARK_ROWS    = [2_u64, 2_u64, 2_u64, 1_u64]
W68_ORACLE_MARK_OFFSETS = {
  "pk"                     => [0_u64, 16_u64, 32_u64, 48_u64, 56_u64],
  "payload.size0"          => [0_u64, 16_u64, 32_u64, 48_u64, 56_u64],
  "payload%2Ekeys.size"    => [0_u64, 16_u64, 40_u64, 56_u64, 64_u64],
  "payload%2Ekeys"         => [0_u64, 6_u64, 19_u64, 36_u64, 40_u64],
  "payload%2Evalues.size1" => [0_u64, 16_u64, 40_u64, 56_u64, 64_u64],
  "payload%2Evalues.null"  => [0_u64, 2_u64, 4_u64, 7_u64, 8_u64],
  "payload%2Evalues"       => [0_u64, 16_u64, 32_u64, 56_u64, 64_u64],
}

private def w68_clickhouse(binary : String, store : String, query : String, input : IO = IO::Memory.new) : String
  output = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], input: input, output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse query failed (#{status.exit_code}): #{query}" unless status.success?
  output.to_s
end

private def w68_u64(io : IO, value : UInt64) : Nil
  8.times { |byte| io.write_byte(((value >> (byte * 8)) & 0xff_u64).to_u8) }
end

private def w68_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w68_string(io : IO, value : String) : Nil
  w68_varuint(io, value.bytesize.to_u64)
  io.write(value.to_slice)
end

private def w68_nullable_u64(io : IO, value : UInt64?) : Nil
  if value.nil?
    io.write_byte(1_u8)
  else
    io.write_byte(0_u8)
    w68_u64(io, value.not_nil!)
  end
end

# Independent RowBinary encoder; expected bytes do not come from the part writer.
private def w68_rowbinary(keys : Array(UInt64), rows : Array(Array(Tuple(String, Array(UInt64?)))), indices : Array(Int32)) : Bytes
  raise "RowBinary input row counts differ" unless keys.size == rows.size
  io = IO::Memory.new
  indices.each do |index|
    w68_u64(io, keys[index])
    entries = rows[index]
    w68_varuint(io, entries.size.to_u64)
    entries.each do |key, values|
      w68_string(io, key)
      w68_varuint(io, values.size.to_u64)
      values.each { |value| w68_nullable_u64(io, value) }
    end
  end
  io.to_slice
end

private def w68_create_table(binary : String, store : String, table : String) : Nil
  w68_clickhouse(binary, store, <<-SQL)
  CREATE TABLE default.#{table} (pk UInt64, payload Map(String, Array(Nullable(UInt64))))
  ENGINE = MergeTree ORDER BY pk
  SETTINGS index_granularity = 2, index_granularity_bytes = 10485760,
    enable_mixed_granularity_parts = 1, min_rows_for_wide_part = 0,
    min_bytes_for_wide_part = 0, compress_marks = 0,
    min_compress_block_size = 0, max_compress_block_size = 4096,
    ratio_of_defaults_for_sparse_serialization = 1.0,
    default_compression_codec = 'LZ4'
  SQL
end

private def w68_check_table(binary : String, store : String, table : String) : Nil
  observed = w68_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "#{table} CHECK TABLE failed: #{observed.inspect}" unless observed == "all_1_1_0\t1"
end

private def w68_assert_rowbinary(binary : String, store : String, table : String, full_expected : Bytes, keyed_expected : Bytes) : Nil
  full = w68_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  raise "#{table} full RowBinary mismatch" unless full.to_slice == full_expected
  keyed = w68_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} WHERE pk >= 3 AND pk <= 7 ORDER BY pk FORMAT RowBinary")
  raise "#{table} keyed RowBinary mismatch" unless keyed.to_slice == keyed_expected
end

private def w68_stock_part(binary : String, store : String, root : String, table : String) : String
  path = w68_clickhouse(binary, store, "SELECT path FROM system.parts WHERE database = 'default' AND table = '#{table}' AND active FORMAT TSVRaw").strip
  raise "#{table} stock source part missing" unless Dir.exists?(path)
  part = File.join(root, "stock-#{table}")
  FileUtils.cp_r(path, part)
  part
end

private def w68_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

private def w68_mark_records(part : String, stream : String) : Array(Tuple(UInt64, UInt64, UInt64))
  marks_path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  bytes = File.read(marks_path).to_slice
  raise "#{part} #{stream} mark size differs" unless bytes.size == 5 * CrystalClick::WidePart::MARK_SIZE
  Array(Tuple(UInt64, UInt64, UInt64)).new(5) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE
    {
      w68_read_u64(bytes, offset),
      w68_read_u64(bytes, offset + 8),
      w68_read_u64(bytes, offset + 16),
    }
  end
end

private def w68_assert_part_metadata(part : String) : Nil
  expected_columns = "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` Map(String, Array(Nullable(UInt64)))\n"
  raise "#{part} columns differ" unless File.read(File.join(part, "columns.txt")) == expected_columns
  expected_substreams = "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n" +
                        "6 substreams for column `payload`:\n" + W68_ORACLE_STREAMS.map { |name| "\t#{name}\n" }.join
  raise "#{part} substreams differ" unless File.read(File.join(part, "columns_substreams.txt")) == expected_substreams
  expected_serialization = %({"columns":[],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
  raise "#{part} serialization differs" unless File.read(File.join(part, "serialization.json")).strip == expected_serialization
  raise "#{part} default codec differs" unless File.read(File.join(part, "default_compression_codec.txt")).strip == "CODEC(LZ4)"
  raise "#{part} row count differs" unless File.read(File.join(part, "count.txt")).strip == W68_ORACLE_KEYS.size.to_s
end

# Stock ClickHouse emits one plain .mrk2 stream coordinate per table-row mark.
# The second coordinate is a byte offset into the decompressed stream, so its
# deltas must follow the stream's storage axis rather than always being rows.
private def w68_assert_stock_marks(part : String) : Nil
  expected_rows = W68_ORACLE_MARK_ROWS + [0_u64]
  all_streams = ["pk"] + W68_ORACLE_STREAMS
  all_streams.each do |stream|
    records = w68_mark_records(part, stream)
    raise "#{part} #{stream} compressed offsets differ" unless records.all? { |record| record[0] == 0_u64 }
    raise "#{part} #{stream} decompressed offsets differ" unless records.map(&.[1]) == W68_ORACLE_MARK_OFFSETS[stream]
    raise "#{part} #{stream} table-row mark counts differ" unless records.map(&.[2]) == expected_rows
  end
end

private def w68_attach(binary : String, store : String, table : String, part : String) : Nil
  data_path = w68_clickhouse(binary, store, "SELECT data_paths[1] FROM system.tables WHERE database = 'default' AND name = '#{table}' FORMAT TSVRaw").strip
  raise "#{table} data path missing" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  w68_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  w68_check_table(binary, store, table)
end

binary = ENV.fetch("CLICKHOUSE_BIN")
store = ENV.fetch("CLICKHOUSE_STORE")
root = ENV.fetch("ORACLE_ROOT")
all_rows = (0...W68_ORACLE_KEYS.size).map(&.to_i32)
keyed_rows = (2...W68_ORACLE_KEYS.size).map(&.to_i32)
full_expected = w68_rowbinary(W68_ORACLE_KEYS, W68_ORACLE_ROWS, all_rows)
keyed_expected = w68_rowbinary(W68_ORACLE_KEYS, W68_ORACLE_ROWS, keyed_rows)

# Stock producer -> Crystal reader.
w68_create_table(binary, store, "w68_stock")
w68_clickhouse(binary, store, "INSERT INTO default.w68_stock FORMAT RowBinary", IO::Memory.new(full_expected))
w68_check_table(binary, store, "w68_stock")
w68_assert_rowbinary(binary, store, "w68_stock", full_expected, keyed_expected)
stock_part = w68_stock_part(binary, store, root, "w68_stock")
w68_assert_part_metadata(stock_part)
w68_assert_stock_marks(stock_part)
reader = CrystalClick::WidePart.open_typed(stock_part, "payload")
raise "stock part full Crystal read differs" unless reader.read_map_string_array_nullable_uint64_mark_range("payload", 0, reader.mark_count) == W68_ORACLE_ROWS
raise "stock all-NULL mark read differs" unless reader.read_map_string_array_nullable_uint64_mark_range("payload", 2, 1) == W68_ORACLE_ROWS[4, 2]
raise "stock later tail mark read differs" unless reader.read_map_string_array_nullable_uint64_mark_range("payload", 3, 1) == W68_ORACLE_ROWS[6, 1]
raise "stock cross-boundary mark read differs" unless reader.read_map_string_array_nullable_uint64_mark_range("payload", 2, 2) == W68_ORACLE_ROWS[4, 3]

# Crystal writer -> stock ClickHouse reader.
writer_part = File.join(root, "writer-w68")
CrystalClick::WidePartWriter.write_uint64_map_string_array_nullable_uint64_pair(
  writer_part,
  "pk",
  W68_ORACLE_KEYS.to_unsafe.to_slice(W68_ORACLE_KEYS.size),
  "payload",
  W68_ORACLE_ROWS.to_unsafe.to_slice(W68_ORACLE_ROWS.size),
  rows_per_mark: 2
)
w68_assert_part_metadata(writer_part)
w68_create_table(binary, store, "w68_writer")
w68_attach(binary, store, "w68_writer", writer_part)
w68_assert_rowbinary(binary, store, "w68_writer", full_expected, keyed_expected)

puts "W68 pinned ClickHouse bidirectional Map(String, Array(Nullable(UInt64))) oracle passed"
