require "file_utils"
require "../src/crystal_click"

private def w63_clickhouse(binary : String, store : String, query : String, input : IO = IO::Memory.new) : String
  output = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], input: input, output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse query failed (#{status.exit_code}): #{query}" unless status.success?
  output.to_s
end

private def w63_u64(io : IO, value : UInt64) : Nil
  8.times { |byte| io.write_byte(((value >> (byte * 8)) & 0xff_u64).to_u8) }
end

private def w63_varuint(io : IO, value : UInt64) : Nil
  while value >= 0x80_u64
    io.write_byte(((value & 0x7f_u64) | 0x80_u64).to_u8)
    value >>= 7
  end
  io.write_byte(value.to_u8)
end

# Independent RowBinary encoder; this does not call the part writer.
private def w63_rowbinary(
  keys : Array(UInt64),
  rows : Array(Array(Tuple(String, Array(UInt64)))),
  indices : Array(Int32),
) : Bytes
  io = IO::Memory.new
  indices.each do |index|
    w63_u64(io, keys[index])
    row = rows[index]
    w63_varuint(io, row.size.to_u64)
    row.each do |key, values|
      w63_varuint(io, key.bytesize.to_u64)
      io.write(key.to_slice)
      w63_varuint(io, values.size.to_u64)
      values.each { |value| w63_u64(io, value) }
    end
  end
  io.to_slice
end

private def w63_create_table(binary : String, store : String, table : String) : Nil
  w63_clickhouse(binary, store, <<-SQL)
  CREATE TABLE default.#{table} (pk UInt64, payload Map(String, Array(UInt64)))
  ENGINE = MergeTree ORDER BY pk
  SETTINGS index_granularity = 2, index_granularity_bytes = 10485760,
    enable_mixed_granularity_parts = 1, min_rows_for_wide_part = 0,
    min_bytes_for_wide_part = 0, compress_marks = 0,
    min_compress_block_size = 0, max_compress_block_size = 4096,
    ratio_of_defaults_for_sparse_serialization = 1.0,
    default_compression_codec = 'LZ4'
  SQL
end

private def w63_check_table(binary : String, store : String, table : String) : Nil
  observed = w63_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "#{table} CHECK TABLE failed: #{observed.inspect}" unless observed == "all_1_1_0\t1"
end

private def w63_query_rows(binary : String, store : String, table : String, expected : Bytes, ranged : Bytes) : Nil
  full = w63_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  raise "#{table} full RowBinary mismatch" unless full.to_slice == expected
  selected = w63_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} WHERE pk >= 2 AND pk < 10 ORDER BY pk FORMAT RowBinary")
  raise "#{table} key-range RowBinary mismatch" unless selected.to_slice == ranged
end

private def w63_assert_topology(part : String) : Nil
  expected_columns = "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` Map(String, Array(UInt64))\n"
  raise "#{part} columns differ" unless File.read(File.join(part, "columns.txt")) == expected_columns
  streams = ["payload.size0", "payload%2Ekeys.size", "payload%2Ekeys", "payload%2Evalues.size1", "payload%2Evalues"]
  expected_substreams = "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n5 substreams for column `payload`:\n" + streams.map { |name| "\t#{name}\n" }.join
  raise "#{part} substreams differ" unless File.read(File.join(part, "columns_substreams.txt")) == expected_substreams
  expected_serialization = %({"columns":[],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
  raise "#{part} serialization differs" unless File.read(File.join(part, "serialization.json")).strip == expected_serialization
  streams.each do |stream|
    marks = File.read(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")).to_slice
    raise "#{part} #{stream} mark size differs" unless marks.size == 5 * CrystalClick::WidePart::MARK_SIZE
    [2_u64, 2_u64, 2_u64, 1_u64, 0_u64].each_with_index do |expected_rows, index|
      offset = index * CrystalClick::WidePart::MARK_SIZE + 16
      observed_rows = 0_u64
      8.times { |byte| observed_rows |= marks[offset + byte].to_u64 << (byte * 8) }
      raise "#{part} #{stream} mark #{index} rows differ" unless observed_rows == expected_rows
    end
  end
end

private def w63_stock_part(binary : String, store : String, root : String, table : String) : String
  path = w63_clickhouse(binary, store, "SELECT path FROM system.parts WHERE database = 'default' AND table = '#{table}' AND active FORMAT TSVRaw").strip
  raise "#{table} source part missing" unless Dir.exists?(path)
  part = File.join(root, "stock-#{table}")
  FileUtils.cp_r(path, part)
  part
end

private def w63_attach(binary : String, store : String, table : String, part : String) : Nil
  data_path = w63_clickhouse(binary, store, "SELECT data_paths[1] FROM system.tables WHERE database = 'default' AND name = '#{table}' FORMAT TSVRaw").strip
  raise "#{table} data path missing" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  w63_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  w63_check_table(binary, store, table)
end

binary = ENV.fetch("CLICKHOUSE_BIN")
store = ENV.fetch("CLICKHOUSE_STORE")
root = ENV.fetch("ORACLE_ROOT")
keys = [1_u64, 2_u64, 4_u64, 7_u64, 10_u64, 11_u64, 12_u64]
binary_key = String.new(Bytes[0x41_u8, 0_u8, 0xff_u8])
rows = [
  [{"dup", Array(UInt64).new(600) { |index| index.to_u64 }}, {"dup", [] of UInt64}],
  [{"alpha", [2_u64, 2_u64]}],
  [] of Tuple(String, Array(UInt64)),
  [] of Tuple(String, Array(UInt64)),
  [{"middle", [] of UInt64}],
  [] of Tuple(String, Array(UInt64)),
  [{"tail", [10_u64, UInt64::MAX]}, {"", [11_u64]}, {binary_key, [] of UInt64}],
] of Array(Tuple(String, Array(UInt64)))
all = (0...keys.size).map(&.to_i32)
selected = keys.each_with_index.compact_map { |key, index| index.to_i32 if key >= 2_u64 && key < 10_u64 }.to_a
expected = w63_rowbinary(keys, rows, all)
ranged = w63_rowbinary(keys, rows, selected)

w63_create_table(binary, store, "w63_stock")
w63_clickhouse(binary, store, "INSERT INTO default.w63_stock FORMAT RowBinary", IO::Memory.new(expected))
w63_check_table(binary, store, "w63_stock")
w63_query_rows(binary, store, "w63_stock", expected, ranged)
stock_part = w63_stock_part(binary, store, root, "w63_stock")
w63_assert_topology(stock_part)
reader = CrystalClick::WidePart.open_typed(stock_part, "payload")
raise "stock part Crystal read differs" unless reader.read_map_string_array_uint64_mark_range("payload", 0, reader.mark_count) == rows
raise "stock part selected mark differs" unless reader.read_map_string_array_uint64_mark_range("payload", 3, 1) == rows[6, 1]

writer_part = File.join(root, "writer-w63")
CrystalClick::WidePartWriter.write_uint64_map_string_array_uint64_pair(
  writer_part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", rows.to_unsafe.to_slice(rows.size), rows_per_mark: 2
)
w63_assert_topology(writer_part)
w63_create_table(binary, store, "w63_writer")
w63_attach(binary, store, "w63_writer", writer_part)
w63_query_rows(binary, store, "w63_writer", expected, ranged)
puts "W63 pinned ClickHouse bidirectional oracle passed"
