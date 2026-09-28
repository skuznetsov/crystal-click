require "file_utils"
require "json"
require "../src/crystal_click"

W73_ORACLE_KEYS    = [0_u64, 1_u64, 2_u64, 3_u64, UInt64::MAX]
W73_EDGE_KEYS      = [1_u64, 2_u64, 3_u64]
W73_ORACLE_BINARY  = String.new(Bytes[0x4b_u8, 0_u8, 0xff_u8])
W73_ORACLE_U64_U64 = [
  [] of Tuple(UInt64, Array(UInt64)),
  [
    {0_u64, [] of UInt64},
    {0_u64, [0_u64, UInt64::MAX] of UInt64},
    {UInt64::MAX, [7_u64, 7_u64] of UInt64},
  ] of Tuple(UInt64, Array(UInt64)),
  [{1_u64, [] of UInt64}] of Tuple(UInt64, Array(UInt64)),
  [{UInt64::MAX, [UInt64::MAX, 1_u64, 2_u64] of UInt64}] of Tuple(UInt64, Array(UInt64)),
  [{42_u64, [5_u64] of UInt64}] of Tuple(UInt64, Array(UInt64)),
] of Array(Tuple(UInt64, Array(UInt64)))
W73_ORACLE_STRING_STRING = [
  [] of Tuple(String, Array(String)),
  [
    {"dup", [] of String},
    {"dup", ["", "a\0b"] of String},
    {W73_ORACLE_BINARY, ["é"] of String},
  ] of Tuple(String, Array(String)),
  [{"empty-array", [] of String}] of Tuple(String, Array(String)),
  [
    {"雪", ["x", ""] of String},
    {"", ["尾"] of String},
  ] of Tuple(String, Array(String)),
  [{"tail", ["after", ""] of String}] of Tuple(String, Array(String)),
] of Array(Tuple(String, Array(String)))
W73_ORACLE_U64_STRING = [
  [] of Tuple(UInt64, Array(String)),
  [
    {0_u64, [] of String},
    {0_u64, ["", "a\0b"] of String},
    {UInt64::MAX, ["é"] of String},
  ] of Tuple(UInt64, Array(String)),
  [{1_u64, [] of String}] of Tuple(UInt64, Array(String)),
  [
    {UInt64::MAX, ["x", ""] of String},
    {7_u64, ["尾"] of String},
  ] of Tuple(UInt64, Array(String)),
  [{42_u64, ["tail", ""] of String}] of Tuple(UInt64, Array(String)),
] of Array(Tuple(UInt64, Array(String)))
W73_ORACLE_ALL_EMPTY_MAPS = [
  [] of Tuple(UInt64, Array(UInt64)),
  [] of Tuple(UInt64, Array(UInt64)),
  [] of Tuple(UInt64, Array(UInt64)),
] of Array(Tuple(UInt64, Array(UInt64)))
W73_ORACLE_MAPS_WITH_EMPTY_ARRAYS = [
  [
    {"dup", [] of String},
    {"dup", [] of String},
  ] of Tuple(String, Array(String)),
  [{"雪", [] of String}] of Tuple(String, Array(String)),
  [{"z", [] of String}] of Tuple(String, Array(String)),
] of Array(Tuple(String, Array(String)))

W73_U64_U64_STREAMS       = ["payload.size0", "payload%2Ekeys", "payload%2Evalues.size1", "payload%2Evalues"]
W73_STRING_STRING_STREAMS = [
  "payload.size0", "payload%2Ekeys.size", "payload%2Ekeys",
  "payload%2Evalues.size1", "payload%2Evalues.size", "payload%2Evalues",
]
W73_U64_STRING_STREAMS = [
  "payload.size0", "payload%2Ekeys", "payload%2Evalues.size1",
  "payload%2Evalues.size", "payload%2Evalues",
]

private def w73_clickhouse(binary : String, store : String, query : String, input : IO = IO::Memory.new) : String
  output = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], input: input, output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse query failed (#{status.exit_code}): #{query}" unless status.success?
  output.to_s
end

private def w73_u64(io : IO, value : UInt64) : Nil
  8.times { |byte| io.write_byte(((value >> (byte * 8)) & 0xff_u64).to_u8) }
end

private def w73_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w73_string(io : IO, value : String) : Nil
  w73_varuint(io, value.bytesize.to_u64)
  io.write(value.to_slice)
end

private def w73_rowbinary_u64_u64(keys : Array(UInt64), rows : Array(Array(Tuple(UInt64, Array(UInt64)))), indices : Array(Int32)) : Bytes
  io = IO::Memory.new
  indices.each do |index|
    w73_u64(io, keys[index])
    entries = rows[index]
    w73_varuint(io, entries.size.to_u64)
    entries.each do |key, values|
      w73_u64(io, key)
      w73_varuint(io, values.size.to_u64)
      values.each { |value| w73_u64(io, value) }
    end
  end
  io.to_slice
end

private def w73_rowbinary_string_string(keys : Array(UInt64), rows : Array(Array(Tuple(String, Array(String)))), indices : Array(Int32)) : Bytes
  io = IO::Memory.new
  indices.each do |index|
    w73_u64(io, keys[index])
    entries = rows[index]
    w73_varuint(io, entries.size.to_u64)
    entries.each do |key, values|
      w73_string(io, key)
      w73_varuint(io, values.size.to_u64)
      values.each { |value| w73_string(io, value) }
    end
  end
  io.to_slice
end

private def w73_rowbinary_u64_string(keys : Array(UInt64), rows : Array(Array(Tuple(UInt64, Array(String)))), indices : Array(Int32)) : Bytes
  io = IO::Memory.new
  indices.each do |index|
    w73_u64(io, keys[index])
    entries = rows[index]
    w73_varuint(io, entries.size.to_u64)
    entries.each do |key, values|
      w73_u64(io, key)
      w73_varuint(io, values.size.to_u64)
      values.each { |value| w73_string(io, value) }
    end
  end
  io.to_slice
end

private def w73_u64_raw(values : Array(UInt64)) : Array(UInt8)
  bytes = [] of UInt8
  values.each { |value| 8.times { |byte| bytes << ((value >> (byte * 8)) & 0xff_u64).to_u8 } }
  bytes
end

private def w73_string_raw(values : Array(String)) : Array(UInt8)
  values.flat_map(&.to_slice.to_a)
end

private def w73_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

private def w73_mark_records(part : String, stream : String) : Array(Tuple(UInt64, UInt64, UInt64))
  bytes = File.read(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")).to_slice
  raise "#{part} #{stream} mark file is malformed" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(Tuple(UInt64, UInt64, UInt64)).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE
    {w73_read_u64(bytes, offset), w73_read_u64(bytes, offset + 8), w73_read_u64(bytes, offset + 16)}
  end
end

private def w73_assert_stream(
  part : String,
  stream : String,
  expected_raw : Array(UInt8),
  mark_raw_sizes : Array(Int32),
  mark_rows : Array(UInt64) = [2_u64, 2_u64, 1_u64],
) : Nil
  data_path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")
  mark_records = w73_mark_records(part, stream)
  raise "#{part} #{stream} mark count differs" unless mark_records.size == mark_rows.size + 1
  raise "#{part} #{stream} row counts differ: #{mark_records.map(&.[2])}" unless mark_records.map(&.[2]) == mark_rows + [0_u64]
  encoded = File.read(data_path).to_slice
  actual_raw = encoded.empty? ? [] of UInt8 : CrystalClick::CompressedBlock.decode_all(encoded).to_a
  raise "#{part} #{stream} raw stream differs" unless actual_raw == expected_raw

  raw_offset = 0_u64
  raise "#{part} #{stream} raw mark-size count differs" unless mark_raw_sizes.size == mark_rows.size
  mark_raw_sizes.each_with_index do |raw_size, index|
    observed = mark_records[index]
    raise "#{part} #{stream} compressed mark offset differs" unless observed[0] == 0_u64
    raise "#{part} #{stream} uncompressed mark offset differs at #{index}: #{observed[1]} != #{raw_offset}" unless observed[1] == raw_offset
    raw_offset += raw_size.to_u64
  end
  terminal = mark_records.last
  raise "#{part} #{stream} terminal mark differs" unless terminal == {0_u64, raw_offset, 0_u64}
  raise "#{part} #{stream} raw mark sizes do not cover the stream" unless raw_offset == expected_raw.size.to_u64
  nil
end

private def w73_assert_part(
  part : String,
  type_name : String,
  streams : Array(String),
  raw_streams : Hash(String, Array(UInt8)),
  mark_sizes : Hash(String, Array(Int32)),
  row_count : Int32 = W73_ORACLE_KEYS.size,
  default_count : Int32 = 1,
  mark_rows : Array(UInt64) = [2_u64, 2_u64, 1_u64],
) : Nil
  expected_columns = "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` #{type_name}\n"
  raise "#{part} columns metadata differs" unless File.read(File.join(part, "columns.txt")) == expected_columns
  serialization = File.read(File.join(part, "serialization.json")).strip
  metadata = JSON.parse(serialization)
  columns = metadata["columns"].as_a
  raise "#{part} key serialization inventory differs" unless columns.size == 1
  key_serializer = columns[0]
  unless key_serializer["kind"].as_s == "Default" && key_serializer["name"].as_s == "pk" &&
         key_serializer["num_defaults"].as_i == default_count && key_serializer["num_rows"].as_i == row_count
    raise "#{part} key serializer differs: #{key_serializer.to_json}, expected stock Default pk with #{default_count} defaults and #{row_count} rows"
  end
  unless metadata["types_serialization_versions"]["string"].as_i == 1 &&
         metadata["propagate_types_serialization_versions_to_nested_types"].as_bool && metadata["version"].as_i == 1
    raise "#{part} nested String serializer version differs"
  end
  expected_serialization = %({"columns":[{"kind":"Default","name":"pk","num_defaults":#{default_count},"num_rows":#{row_count}}],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
  raise "#{part} serialization.json bytes differ" unless serialization == expected_serialization
  expected_substreams = "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n" +
                        "#{streams.size} substreams for column `payload`:\n" + streams.map { |stream| "\t#{stream}\n" }.join
  raise "#{part} substream inventory differs" unless File.read(File.join(part, "columns_substreams.txt")) == expected_substreams

  streams.each do |stream|
    w73_assert_stream(part, stream, raw_streams[stream], mark_sizes[stream], mark_rows)
  end
  w73_assert_stream(part, "pk", raw_streams["pk"], mark_sizes["pk"], mark_rows)

  checksums = CrystalClick::PartChecksums.open(part)
  expected_files = ["count.txt", "primary.cidx", "serialization.json"]
  (["pk"] + streams).each do |stream|
    base = CrystalClick::StreamName.hash(stream)
    expected_files << "#{base}.bin"
    expected_files << "#{base}.mrk2"
  end
  unless checksums.entries.keys.sort == expected_files.sort
    raise "#{part} checksum inventory differs: #{checksums.entries.keys.sort}"
  end
  checksums.entries.each_key { |name| checksums.validate_selected_entries(part, name) }

  puts "#{File.basename(part)} serialization.json=#{serialization}"
  streams.each do |stream|
    puts "#{File.basename(part)} #{stream} marks=#{w73_mark_records(part, stream)}"
  end
  nil
end

private def w73_create_table(binary : String, store : String, table : String, type_name : String) : Nil
  w73_clickhouse(binary, store, <<-SQL)
  CREATE TABLE default.#{table} (`pk` UInt64, `payload` #{type_name})
  ENGINE = MergeTree ORDER BY pk
  SETTINGS index_granularity = 2, index_granularity_bytes = 10485760,
    enable_mixed_granularity_parts = 1, min_rows_for_wide_part = 0,
    min_bytes_for_wide_part = 0, compress_marks = 0,
    min_compress_block_size = 0, max_compress_block_size = 4096,
    write_final_mark = 1, default_compression_codec = 'LZ4'
  SQL
  nil
end

private def w73_check_table(binary : String, store : String, table : String) : Nil
  result = w73_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "#{table} CHECK TABLE failed: #{result.inspect}" unless result == "all_1_1_0\t1"
  nil
end

private def w73_assert_rows(binary : String, store : String, table : String, full : Bytes, keyed : Bytes) : Nil
  actual = w73_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  raise "#{table} full RowBinary mismatch" unless actual.to_slice == full
  selected = w73_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} WHERE pk >= 2 AND pk <= 3 ORDER BY pk FORMAT RowBinary")
  raise "#{table} keyed RowBinary mismatch" unless selected.to_slice == keyed
  nil
end

private def w73_stock_part(binary : String, store : String, root : String, table : String) : String
  path = w73_clickhouse(binary, store, "SELECT path FROM system.parts WHERE database = 'default' AND table = '#{table}' AND active FORMAT TSVRaw").strip
  raise "#{table} stock part missing" unless Dir.exists?(path)
  target = File.join(root, "stock-#{table}")
  FileUtils.cp_r(path, target)
  target
end

private def w73_attach(binary : String, store : String, table : String, part : String, type_name : String) : Nil
  w73_create_table(binary, store, table, type_name)
  data_path = w73_clickhouse(binary, store, "SELECT data_paths[1] FROM system.tables WHERE database = 'default' AND name = '#{table}' FORMAT TSVRaw").strip
  raise "#{table} data path missing" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  w73_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  w73_check_table(binary, store, table)
  nil
end

private def w73_assert_stock_key_read(part : String, expected : Array(UInt64)) : Nil
  key_part = CrystalClick::WidePart.open(part, "pk")
  actual = key_part.read_uint64_mark_range("pk", 0, key_part.mark_count)
  raise "#{part} stock primary-key readback differs" unless actual == expected
  nil
end

binary = ENV.fetch("CLICKHOUSE_BIN")
store = ENV.fetch("CLICKHOUSE_STORE")
root = ENV.fetch("ORACLE_ROOT")
all_indices = [0_i32, 1_i32, 2_i32, 3_i32, 4_i32]
keyed_indices = [2_i32, 3_i32]
pk_raw = w73_u64_raw(W73_ORACLE_KEYS)
pk_marks = [16, 16, 8]

u64_u64_full = w73_rowbinary_u64_u64(W73_ORACLE_KEYS, W73_ORACLE_U64_U64, all_indices)
u64_u64_keyed = w73_rowbinary_u64_u64(W73_ORACLE_KEYS, W73_ORACLE_U64_U64, keyed_indices)
w73_create_table(binary, store, "w73_stock_u64_u64", "Map(UInt64, Array(UInt64))")
w73_clickhouse(binary, store, "INSERT INTO default.w73_stock_u64_u64 FORMAT RowBinary", IO::Memory.new(u64_u64_full))
w73_check_table(binary, store, "w73_stock_u64_u64")
w73_assert_rows(binary, store, "w73_stock_u64_u64", u64_u64_full, u64_u64_keyed)
u64_u64_part = w73_stock_part(binary, store, root, "w73_stock_u64_u64")
u64_u64_entries = W73_ORACLE_U64_U64.flatten
u64_u64_raw = {
  "pk"                     => pk_raw,
  "payload.size0"          => w73_u64_raw(W73_ORACLE_U64_U64.map { |row| row.size.to_u64 }),
  "payload%2Ekeys"         => w73_u64_raw(u64_u64_entries.map(&.[0])),
  "payload%2Evalues.size1" => w73_u64_raw(u64_u64_entries.map { |entry| entry[1].size.to_u64 }),
  "payload%2Evalues"       => w73_u64_raw(u64_u64_entries.flat_map(&.[1])),
}
u64_u64_marks = {
  "pk" => pk_marks, "payload.size0" => [16, 16, 8], "payload%2Ekeys" => [24, 16, 8],
  "payload%2Evalues.size1" => [24, 16, 8], "payload%2Evalues" => [32, 24, 8],
}
w73_assert_part(u64_u64_part, "Map(UInt64, Array(UInt64))", W73_U64_U64_STREAMS, u64_u64_raw, u64_u64_marks)
u64_u64_stock_reader = CrystalClick::WidePart.open_typed(u64_u64_part, "payload")
raise "stock Map(UInt64, Array(UInt64)) Crystal read differs" unless u64_u64_stock_reader.read_map_uint64_array_uint64_mark_range("payload", 0, u64_u64_stock_reader.mark_count) == W73_ORACLE_U64_U64
raise "stock Map(UInt64, Array(UInt64)) final-mark read differs" unless u64_u64_stock_reader.read_map_uint64_array_uint64_mark_range("payload", 2, 1) == W73_ORACLE_U64_U64[4, 1]
w73_assert_stock_key_read(u64_u64_part, W73_ORACLE_KEYS)
u64_u64_writer_part = File.join(root, "crystal-writer-u64-u64")
CrystalClick::WidePartWriter.write_uint64_map_uint64_array_uint64_pair(
  u64_u64_writer_part, "pk", W73_ORACLE_KEYS.to_unsafe.to_slice(W73_ORACLE_KEYS.size), "payload",
  W73_ORACLE_U64_U64.to_unsafe.to_slice(W73_ORACLE_U64_U64.size), rows_per_mark: 2
)
w73_attach(binary, store, "w73_writer_u64_u64", u64_u64_writer_part, "Map(UInt64, Array(UInt64))")
w73_assert_rows(binary, store, "w73_writer_u64_u64", u64_u64_full, u64_u64_keyed)

string_string_full = w73_rowbinary_string_string(W73_ORACLE_KEYS, W73_ORACLE_STRING_STRING, all_indices)
string_string_keyed = w73_rowbinary_string_string(W73_ORACLE_KEYS, W73_ORACLE_STRING_STRING, keyed_indices)
w73_create_table(binary, store, "w73_stock_string_string", "Map(String, Array(String))")
w73_clickhouse(binary, store, "INSERT INTO default.w73_stock_string_string FORMAT RowBinary", IO::Memory.new(string_string_full))
w73_check_table(binary, store, "w73_stock_string_string")
w73_assert_rows(binary, store, "w73_stock_string_string", string_string_full, string_string_keyed)
string_string_part = w73_stock_part(binary, store, root, "w73_stock_string_string")
string_string_entries = W73_ORACLE_STRING_STRING.flatten
string_string_leaves = string_string_entries.flat_map(&.[1])
string_string_raw = {
  "pk"                     => pk_raw,
  "payload.size0"          => w73_u64_raw(W73_ORACLE_STRING_STRING.map { |row| row.size.to_u64 }),
  "payload%2Ekeys.size"    => w73_u64_raw(string_string_entries.map { |entry| entry[0].bytesize.to_u64 }),
  "payload%2Ekeys"         => w73_string_raw(string_string_entries.map(&.[0])),
  "payload%2Evalues.size1" => w73_u64_raw(string_string_entries.map { |entry| entry[1].size.to_u64 }),
  "payload%2Evalues.size"  => w73_u64_raw(string_string_leaves.map { |value| value.bytesize.to_u64 }),
  "payload%2Evalues"       => w73_string_raw(string_string_leaves),
}
string_string_marks = {
  "pk" => pk_marks, "payload.size0" => [16, 16, 8], "payload%2Ekeys.size" => [24, 24, 8],
  "payload%2Ekeys" => [9, 14, 4], "payload%2Evalues.size1" => [24, 24, 8],
  "payload%2Evalues.size" => [24, 24, 16], "payload%2Evalues" => [5, 4, 5],
}
w73_assert_part(string_string_part, "Map(String, Array(String))", W73_STRING_STRING_STREAMS, string_string_raw, string_string_marks)
string_string_stock_reader = CrystalClick::WidePart.open_typed(string_string_part, "payload")
raise "stock Map(String, Array(String)) Crystal read differs" unless string_string_stock_reader.read_map_string_array_string_mark_range("payload", 0, string_string_stock_reader.mark_count) == W73_ORACLE_STRING_STRING
raise "stock Map(String, Array(String)) final-mark read differs" unless string_string_stock_reader.read_map_string_array_string_mark_range("payload", 2, 1) == W73_ORACLE_STRING_STRING[4, 1]
w73_assert_stock_key_read(string_string_part, W73_ORACLE_KEYS)
string_string_writer_part = File.join(root, "crystal-writer-string-string")
CrystalClick::WidePartWriter.write_uint64_map_string_array_string_pair(
  string_string_writer_part, "pk", W73_ORACLE_KEYS.to_unsafe.to_slice(W73_ORACLE_KEYS.size), "payload",
  W73_ORACLE_STRING_STRING.to_unsafe.to_slice(W73_ORACLE_STRING_STRING.size), rows_per_mark: 2
)
w73_attach(binary, store, "w73_writer_string_string", string_string_writer_part, "Map(String, Array(String))")
w73_assert_rows(binary, store, "w73_writer_string_string", string_string_full, string_string_keyed)

u64_string_full = w73_rowbinary_u64_string(W73_ORACLE_KEYS, W73_ORACLE_U64_STRING, all_indices)
u64_string_keyed = w73_rowbinary_u64_string(W73_ORACLE_KEYS, W73_ORACLE_U64_STRING, keyed_indices)
w73_create_table(binary, store, "w73_stock_u64_string", "Map(UInt64, Array(String))")
w73_clickhouse(binary, store, "INSERT INTO default.w73_stock_u64_string FORMAT RowBinary", IO::Memory.new(u64_string_full))
w73_check_table(binary, store, "w73_stock_u64_string")
w73_assert_rows(binary, store, "w73_stock_u64_string", u64_string_full, u64_string_keyed)
u64_string_part = w73_stock_part(binary, store, root, "w73_stock_u64_string")
u64_string_entries = W73_ORACLE_U64_STRING.flatten
u64_string_leaves = u64_string_entries.flat_map(&.[1])
u64_string_raw = {
  "pk"                     => pk_raw,
  "payload.size0"          => w73_u64_raw(W73_ORACLE_U64_STRING.map { |row| row.size.to_u64 }),
  "payload%2Ekeys"         => w73_u64_raw(u64_string_entries.map(&.[0])),
  "payload%2Evalues.size1" => w73_u64_raw(u64_string_entries.map { |entry| entry[1].size.to_u64 }),
  "payload%2Evalues.size"  => w73_u64_raw(u64_string_leaves.map { |value| value.bytesize.to_u64 }),
  "payload%2Evalues"       => w73_string_raw(u64_string_leaves),
}
u64_string_marks = {
  "pk" => pk_marks, "payload.size0" => [16, 16, 8], "payload%2Ekeys" => [24, 24, 8],
  "payload%2Evalues.size1" => [24, 24, 8], "payload%2Evalues.size" => [24, 24, 16],
  "payload%2Evalues" => [5, 4, 4],
}
w73_assert_part(u64_string_part, "Map(UInt64, Array(String))", W73_U64_STRING_STREAMS, u64_string_raw, u64_string_marks)
u64_string_stock_reader = CrystalClick::WidePart.open_typed(u64_string_part, "payload")
raise "stock Map(UInt64, Array(String)) Crystal read differs" unless u64_string_stock_reader.read_map_uint64_array_string_mark_range("payload", 0, u64_string_stock_reader.mark_count) == W73_ORACLE_U64_STRING
raise "stock Map(UInt64, Array(String)) final-mark read differs" unless u64_string_stock_reader.read_map_uint64_array_string_mark_range("payload", 2, 1) == W73_ORACLE_U64_STRING[4, 1]
w73_assert_stock_key_read(u64_string_part, W73_ORACLE_KEYS)
u64_string_writer_part = File.join(root, "crystal-writer-u64-string")
CrystalClick::WidePartWriter.write_uint64_map_uint64_array_string_pair(
  u64_string_writer_part, "pk", W73_ORACLE_KEYS.to_unsafe.to_slice(W73_ORACLE_KEYS.size), "payload",
  W73_ORACLE_U64_STRING.to_unsafe.to_slice(W73_ORACLE_U64_STRING.size), rows_per_mark: 2
)
w73_attach(binary, store, "w73_writer_u64_string", u64_string_writer_part, "Map(UInt64, Array(String))")
w73_assert_rows(binary, store, "w73_writer_u64_string", u64_string_full, u64_string_keyed)

edge_indices = [0_i32, 1_i32, 2_i32]
edge_keyed_indices = [1_i32, 2_i32]
edge_pk_raw = w73_u64_raw(W73_EDGE_KEYS)
edge_pk_marks = [16, 8]

all_empty_full = w73_rowbinary_u64_u64(W73_EDGE_KEYS, W73_ORACLE_ALL_EMPTY_MAPS, edge_indices)
all_empty_keyed = w73_rowbinary_u64_u64(W73_EDGE_KEYS, W73_ORACLE_ALL_EMPTY_MAPS, edge_keyed_indices)
w73_create_table(binary, store, "w73_stock_all_empty_u64", "Map(UInt64, Array(UInt64))")
w73_clickhouse(binary, store, "INSERT INTO default.w73_stock_all_empty_u64 FORMAT RowBinary", IO::Memory.new(all_empty_full))
w73_check_table(binary, store, "w73_stock_all_empty_u64")
w73_assert_rows(binary, store, "w73_stock_all_empty_u64", all_empty_full, all_empty_keyed)
all_empty_part = w73_stock_part(binary, store, root, "w73_stock_all_empty_u64")
all_empty_raw = {
  "pk"                     => edge_pk_raw,
  "payload.size0"          => w73_u64_raw([0_u64, 0_u64, 0_u64]),
  "payload%2Ekeys"         => [] of UInt8,
  "payload%2Evalues.size1" => [] of UInt8,
  "payload%2Evalues"       => [] of UInt8,
}
all_empty_marks = {
  "pk" => edge_pk_marks, "payload.size0" => [16, 8], "payload%2Ekeys" => [0, 0],
  "payload%2Evalues.size1" => [0, 0], "payload%2Evalues" => [0, 0],
}
w73_assert_part(all_empty_part, "Map(UInt64, Array(UInt64))", W73_U64_U64_STREAMS, all_empty_raw, all_empty_marks,
  row_count: W73_EDGE_KEYS.size, default_count: 0, mark_rows: [2_u64, 1_u64])
all_empty_stock_reader = CrystalClick::WidePart.open_typed(all_empty_part, "payload")
raise "all-empty stock Map Crystal read differs" unless all_empty_stock_reader.read_map_uint64_array_uint64_mark_range("payload", 0, all_empty_stock_reader.mark_count) == W73_ORACLE_ALL_EMPTY_MAPS
raise "all-empty stock Map final-mark read differs" unless all_empty_stock_reader.read_map_uint64_array_uint64_mark_range("payload", 1, 1) == W73_ORACLE_ALL_EMPTY_MAPS[2, 1]
w73_assert_stock_key_read(all_empty_part, W73_EDGE_KEYS)
all_empty_writer_part = File.join(root, "crystal-writer-all-empty-u64")
CrystalClick::WidePartWriter.write_uint64_map_uint64_array_uint64_pair(
  all_empty_writer_part, "pk", W73_EDGE_KEYS.to_unsafe.to_slice(W73_EDGE_KEYS.size), "payload",
  W73_ORACLE_ALL_EMPTY_MAPS.to_unsafe.to_slice(W73_ORACLE_ALL_EMPTY_MAPS.size), rows_per_mark: 2
)
w73_attach(binary, store, "w73_writer_all_empty_u64", all_empty_writer_part, "Map(UInt64, Array(UInt64))")
w73_assert_rows(binary, store, "w73_writer_all_empty_u64", all_empty_full, all_empty_keyed)

empty_arrays_full = w73_rowbinary_string_string(W73_EDGE_KEYS, W73_ORACLE_MAPS_WITH_EMPTY_ARRAYS, edge_indices)
empty_arrays_keyed = w73_rowbinary_string_string(W73_EDGE_KEYS, W73_ORACLE_MAPS_WITH_EMPTY_ARRAYS, edge_keyed_indices)
w73_create_table(binary, store, "w73_stock_empty_arrays_string", "Map(String, Array(String))")
w73_clickhouse(binary, store, "INSERT INTO default.w73_stock_empty_arrays_string FORMAT RowBinary", IO::Memory.new(empty_arrays_full))
w73_check_table(binary, store, "w73_stock_empty_arrays_string")
w73_assert_rows(binary, store, "w73_stock_empty_arrays_string", empty_arrays_full, empty_arrays_keyed)
empty_arrays_part = w73_stock_part(binary, store, root, "w73_stock_empty_arrays_string")
empty_array_entries = W73_ORACLE_MAPS_WITH_EMPTY_ARRAYS.flatten
empty_arrays_raw = {
  "pk"                     => edge_pk_raw,
  "payload.size0"          => w73_u64_raw([2_u64, 1_u64, 1_u64]),
  "payload%2Ekeys.size"    => w73_u64_raw(empty_array_entries.map { |entry| entry[0].bytesize.to_u64 }),
  "payload%2Ekeys"         => w73_string_raw(empty_array_entries.map(&.[0])),
  "payload%2Evalues.size1" => w73_u64_raw([0_u64, 0_u64, 0_u64, 0_u64]),
  "payload%2Evalues.size"  => [] of UInt8,
  "payload%2Evalues"       => [] of UInt8,
}
empty_arrays_marks = {
  "pk" => edge_pk_marks, "payload.size0" => [16, 8], "payload%2Ekeys.size" => [24, 8],
  "payload%2Ekeys" => [9, 1], "payload%2Evalues.size1" => [24, 8],
  "payload%2Evalues.size" => [0, 0], "payload%2Evalues" => [0, 0],
}
w73_assert_part(empty_arrays_part, "Map(String, Array(String))", W73_STRING_STRING_STREAMS, empty_arrays_raw, empty_arrays_marks,
  row_count: W73_EDGE_KEYS.size, default_count: 0, mark_rows: [2_u64, 1_u64])
empty_arrays_stock_reader = CrystalClick::WidePart.open_typed(empty_arrays_part, "payload")
raise "empty-array stock Map Crystal read differs" unless empty_arrays_stock_reader.read_map_string_array_string_mark_range("payload", 0, empty_arrays_stock_reader.mark_count) == W73_ORACLE_MAPS_WITH_EMPTY_ARRAYS
raise "empty-array stock Map final-mark read differs" unless empty_arrays_stock_reader.read_map_string_array_string_mark_range("payload", 1, 1) == W73_ORACLE_MAPS_WITH_EMPTY_ARRAYS[2, 1]
w73_assert_stock_key_read(empty_arrays_part, W73_EDGE_KEYS)
empty_arrays_writer_part = File.join(root, "crystal-writer-empty-arrays-string")
CrystalClick::WidePartWriter.write_uint64_map_string_array_string_pair(
  empty_arrays_writer_part, "pk", W73_EDGE_KEYS.to_unsafe.to_slice(W73_EDGE_KEYS.size), "payload",
  W73_ORACLE_MAPS_WITH_EMPTY_ARRAYS.to_unsafe.to_slice(W73_ORACLE_MAPS_WITH_EMPTY_ARRAYS.size), rows_per_mark: 2
)
w73_attach(binary, store, "w73_writer_empty_arrays_string", empty_arrays_writer_part, "Map(String, Array(String))")
w73_assert_rows(binary, store, "w73_writer_empty_arrays_string", empty_arrays_full, empty_arrays_keyed)

puts "Pinned ClickHouse and Crystal passed W73 Map/Array plus zero-byte nested-child bidirectional oracle."
