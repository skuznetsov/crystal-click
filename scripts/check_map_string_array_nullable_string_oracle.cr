require "file_utils"
require "../src/crystal_click"

W70_ORACLE_KEYS = [0_u64, 1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64]
W70_ORACLE_ROWS = [
  [
    {"dup", [nil, "", "a\0b", "café"] of String?},
    {"dup", ["tail"] of String?},
    {"dup", ["dup-third"] of String?},
  ] of Tuple(String, Array(String?)),
  [] of Tuple(String, Array(String?)),
  [{"empty_array", [] of String?}] of Tuple(String, Array(String?)),
  [
    {"x", ["x3"] of String?},
    {"x2", ["x2", "x2b"] of String?},
  ] of Tuple(String, Array(String?)),
  [
    {"later", [nil, nil] of String?},
    {"later2", [nil] of String?},
  ] of Tuple(String, Array(String?)),
  [{"later", [nil] of String?}] of Tuple(String, Array(String?)),
  [
    {"tail", ["after-null", ""] of String?},
    {"tail2", ["tail2"] of String?},
  ] of Tuple(String, Array(String?)),
] of Array(Tuple(String, Array(String?)))
W70_EMPTY_CHILD_KEYS = [7_u64, 8_u64, 9_u64, 10_u64]
W70_EMPTY_CHILD_ROWS = [
  [] of Tuple(String, Array(String?)),
  [] of Tuple(String, Array(String?)),
  [{"", [""] of String?}] of Tuple(String, Array(String?)),
  [] of Tuple(String, Array(String?)),
] of Array(Tuple(String, Array(String?)))

W70_ORACLE_STREAMS = [
  "m.size0",
  "m%2Ekeys.size",
  "m%2Ekeys",
  "m%2Evalues.size1",
  "m%2Evalues.null",
  "m%2Evalues.size",
  "m%2Evalues",
]
W70_ORACLE_MARK_ROWS    = [2_u64, 2_u64, 2_u64, 1_u64]
W70_ORACLE_MARK_OFFSETS = {
  "id"               => [0_u64, 16_u64, 32_u64, 48_u64, 56_u64],
  "m.size0"          => [0_u64, 16_u64, 32_u64, 48_u64, 56_u64],
  "m%2Ekeys.size"    => [0_u64, 24_u64, 48_u64, 72_u64, 88_u64],
  "m%2Ekeys"         => [0_u64, 9_u64, 23_u64, 39_u64, 48_u64],
  "m%2Evalues.size1" => [0_u64, 24_u64, 48_u64, 72_u64, 88_u64],
  "m%2Evalues.null"  => [0_u64, 6_u64, 9_u64, 13_u64, 16_u64],
  "m%2Evalues.size"  => [0_u64, 48_u64, 72_u64, 104_u64, 128_u64],
  "m%2Evalues"       => [0_u64, 21_u64, 28_u64, 28_u64, 43_u64],
}
W70_WRITER_RAW_MARK_SIZES = {
  "id"               => [16, 16, 16, 8],
  "m.size0"          => [16, 16, 16, 8],
  "m%2Ekeys.size"    => [24, 24, 24, 16],
  "m%2Ekeys"         => [9, 14, 16, 9],
  "m%2Evalues.size1" => [24, 24, 24, 16],
  "m%2Evalues.null"  => [6, 3, 4, 3],
  "m%2Evalues.size"  => [48, 24, 32, 24],
  "m%2Evalues"       => [21, 7, 0, 15],
}

private def w70_clickhouse(binary : String, store : String, query : String, input : IO = IO::Memory.new) : String
  output = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], input: input, output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse query failed (#{status.exit_code}): #{query}" unless status.success?
  output.to_s
end

private def w70_u64(io : IO, value : UInt64) : Nil
  8.times { |byte| io.write_byte(((value >> (byte * 8)) & 0xff_u64).to_u8) }
end

private def w70_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w70_string(io : IO, value : String) : Nil
  w70_varuint(io, value.bytesize.to_u64)
  io.write(value.to_slice)
end

private def w70_nullable_string(io : IO, value : String?) : Nil
  if value.nil?
    io.write_byte(1_u8)
  else
    io.write_byte(0_u8)
    w70_string(io, value.not_nil!)
  end
end

# Independent RowBinary encoder; it preserves Map insertion order and separates
# Nullable(String)'s NULL byte from the String's own VarUInt length and bytes.
private def w70_rowbinary(keys : Array(UInt64), rows : Array(Array(Tuple(String, Array(String?)))), indices : Array(Int32)) : Bytes
  raise "RowBinary input row counts differ" unless keys.size == rows.size
  io = IO::Memory.new
  indices.each do |index|
    w70_u64(io, keys[index])
    entries = rows[index]
    w70_varuint(io, entries.size.to_u64)
    entries.each do |key, values|
      w70_string(io, key)
      w70_varuint(io, values.size.to_u64)
      values.each { |value| w70_nullable_string(io, value) }
    end
  end
  io.to_slice
end

private def w70_create_table(binary : String, store : String, table : String) : Nil
  w70_clickhouse(binary, store, <<-SQL)
  CREATE TABLE default.#{table} (id UInt64, m Map(String, Array(Nullable(String))))
  ENGINE = MergeTree ORDER BY id
  SETTINGS index_granularity = 2, index_granularity_bytes = 10485760,
    enable_mixed_granularity_parts = 1, min_rows_for_wide_part = 0,
    min_bytes_for_wide_part = 0, compress_marks = 0,
    min_compress_block_size = 0, max_compress_block_size = 4096,
    write_final_mark = 1,
    default_compression_codec = 'LZ4'
  SQL
end

private def w70_check_table(binary : String, store : String, table : String, expected_parts : Array(String) = ["all_1_1_0"]) : Nil
  observed = w70_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  observed_rows = observed.lines.map(&.strip).sort
  expected_rows = expected_parts.map { |part| "#{part}\t1" }.sort
  raise "#{table} CHECK TABLE failed: #{observed.inspect}" unless observed_rows == expected_rows
end

private def w70_assert_rowbinary(binary : String, store : String, table : String, full_expected : Bytes, keyed_expected : Bytes, keyed_max_id : UInt64 = 6_u64) : Nil
  full = w70_clickhouse(binary, store, "SELECT id, m FROM default.#{table} ORDER BY id FORMAT RowBinary")
  raise "#{table} full RowBinary mismatch" unless full.to_slice == full_expected
  keyed = w70_clickhouse(binary, store, "SELECT id, m FROM default.#{table} WHERE id >= 2 AND id <= #{keyed_max_id} ORDER BY id FORMAT RowBinary")
  raise "#{table} keyed RowBinary mismatch" unless keyed.to_slice == keyed_expected
end

private def w70_assert_columns(binary : String, store : String, table : String) : Nil
  actual = w70_clickhouse(binary, store,
    "SELECT name || ' ' || type FROM system.columns WHERE database = 'default' AND table = '#{table}' ORDER BY position FORMAT TSVRaw")
  expected = "id UInt64\nm Map(String, Array(Nullable(String)))\n"
  raise "#{table} exact system.columns mismatch: #{actual.inspect}" unless actual == expected
end

private def w70_stock_part(binary : String, store : String, root : String, table : String) : String
  path = w70_clickhouse(binary, store, "SELECT path FROM system.parts WHERE database = 'default' AND table = '#{table}' AND active FORMAT TSVRaw").strip
  raise "#{table} stock source part missing" unless Dir.exists?(path)
  part = File.join(root, "stock-#{table}")
  FileUtils.cp_r(path, part)
  part
end

private def w70_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

private def w70_write_u32(bytes : Bytes, offset : Int, value : UInt32) : Nil
  4.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u32).to_u8 }
end

private def w70_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def w70_write_hash(io : IO, hash : {UInt64, UInt64}) : Nil
  8.times { |byte| io.write_byte(((hash[0] >> (byte * 8)) & 0xff_u64).to_u8) }
  8.times { |byte| io.write_byte(((hash[1] >> (byte * 8)) & 0xff_u64).to_u8) }
end

private def w70_literal_lz4_frame(raw : Bytes) : Bytes
  raise "cannot encode an empty LZ4 frame" if raw.empty?
  extension_size = raw.size < 15 ? 0 : ((raw.size - 15) // 255) + 1
  payload_size = 1 + extension_size + raw.size
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload_size
  frame = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload_size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  frame[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  w70_write_u32(frame, header + 1, compressed_size.to_u32)
  w70_write_u32(frame, header + 5, raw.size.to_u32)
  cursor = CrystalClick::CompressedBlock::FRAME_HEADER_SIZE
  if raw.size < 15
    frame[cursor] = (raw.size << 4).to_u8
    cursor += 1
  else
    frame[cursor] = 0xf0_u8
    cursor += 1
    remaining = raw.size - 15
    while remaining >= 255
      frame[cursor] = 255_u8
      cursor += 1
      remaining -= 255
    end
    frame[cursor] = remaining.to_u8
    cursor += 1
  end
  raw.copy_to(frame.to_unsafe + cursor, raw.size)
  hash = CrystalClick::CityHashV1.hash128(frame[header, compressed_size])
  w70_write_u64(frame, 0, hash[0])
  w70_write_u64(frame, 8, hash[1])
  frame
end

private def w70_refresh_checksums(part : String) : Nil
  parsed = CrystalClick::PartChecksums.open(part)
  payload = IO::Memory.new
  names = parsed.entries.keys.sort
  w70_varuint(payload, names.size.to_u64)
  names.each do |name|
    file_bytes = File.read(File.join(part, name)).to_slice
    entry = parsed.entries[name]
    w70_varuint(payload, name.bytesize.to_u64)
    payload.write(name.to_slice)
    w70_varuint(payload, file_bytes.size.to_u64)
    w70_write_hash(payload, CrystalClick::CityHashV1.file_hash(file_bytes))
    if entry.compressed
      raw = CrystalClick::CompressedBlock.decode_all(file_bytes)
      payload.write_byte(1_u8)
      w70_varuint(payload, raw.size.to_u64)
      w70_write_hash(payload, CrystalClick::CityHashV1.file_hash(raw))
    else
      payload.write_byte(0_u8)
    end
  end
  output = IO::Memory.new
  output << CrystalClick::PartChecksums::CHECKSUMS_HEADER
  output.write(w70_literal_lz4_frame(payload.to_slice))
  File.write(File.join(part, "checksums.txt"), output.to_slice)
end

private def w70_mutate_stock_null_hidden_string(part : String) : Nil
  stream = "m%2Evalues.size"
  marks = w70_mark_records(part, stream)
  encoded_path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")
  encoded = File.read(encoded_path).to_slice
  frame = CrystalClick::CompressedBlock.decode_frame(encoded, marks[0][0].to_i64)
  raise "stock #{stream} does not share one LZ4 frame" unless marks.all? { |record| record[0] == 0_u64 } && frame.end_offset == encoded.size.to_i64
  raw = frame.output.dup
  # In mark 0 the first leaf is NULL(size 0); leaf 2 is "a\0b"(size 3).
  # Moving one byte of the visible string into the hidden NULL slot keeps the
  # total size stream and all following raw-value coordinates unchanged.
  w70_write_u64(raw, 0, 1_u64)
  w70_write_u64(raw, 2 * 8, 2_u64)
  File.write(encoded_path, w70_literal_lz4_frame(raw))
  w70_refresh_checksums(part)
  changed = CrystalClick::CompressedBlock.decode_all(File.read(encoded_path).to_slice)
  raise "hidden NULL String mutation did not land" unless w70_read_u64(changed, 0) == 1_u64 && w70_read_u64(changed, 16) == 2_u64
end

private def w70_mark_records(part : String, stream : String, mark_count : Int32 = 5) : Array(Tuple(UInt64, UInt64, UInt64))
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  bytes = File.read(path).to_slice
  raise "#{part} #{stream} mark file size differs" unless bytes.size == mark_count * CrystalClick::WidePart::MARK_SIZE
  Array(Tuple(UInt64, UInt64, UInt64)).new(mark_count) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE
    {w70_read_u64(bytes, offset), w70_read_u64(bytes, offset + 8), w70_read_u64(bytes, offset + 16)}
  end
end

private def w70_assert_part_metadata(part : String) : Nil
  columns = "columns format version: 1\n2 columns:\n`id` UInt64\n`m` Map(String, Array(Nullable(String)))\n"
  raise "#{part} columns differ" unless File.read(File.join(part, "columns.txt")) == columns
  substreams = "columns substreams version: 1\n2 columns:\n1 substreams for column `id`:\n\tid\n" +
               "7 substreams for column `m`:\n" + W70_ORACLE_STREAMS.map { |name| "\t#{name}\n" }.join
  raise "#{part} substreams differ" unless File.read(File.join(part, "columns_substreams.txt")) == substreams
  serialization = %({"columns":[{"kind":"Default","name":"id","num_defaults":1,"num_rows":7}],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
  actual_serialization = File.read(File.join(part, "serialization.json")).strip
  raise "#{part} serialization differs: #{actual_serialization.inspect}" unless actual_serialization == serialization
  raise "#{part} default codec differs" unless File.read(File.join(part, "default_compression_codec.txt")).strip == "CODEC(LZ4)"
  raise "#{part} metadata version differs" unless File.read(File.join(part, "metadata_version.txt")).strip == "0"
  raise "#{part} row count differs" unless File.read(File.join(part, "count.txt")).strip == W70_ORACLE_KEYS.size.to_s
end

private def w70_assert_stock_marks(part : String) : Nil
  expected_rows = W70_ORACLE_MARK_ROWS + [0_u64]
  (["id"] + W70_ORACLE_STREAMS).each do |stream|
    records = w70_mark_records(part, stream)
    raise "#{part} #{stream} compressed offsets differ" unless records.all? { |record| record[0] == 0_u64 }
    raise "#{part} #{stream} decompressed offsets differ" unless records.map(&.[1]) == W70_ORACLE_MARK_OFFSETS[stream]
    raise "#{part} #{stream} row vector differs" unless records.map(&.[2]) == expected_rows
  end
end

private def w70_raw_stream(part : String, stream : String) : Array(UInt8)
  encoded = File.read(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
  return [] of UInt8 if encoded.empty?
  CrystalClick::CompressedBlock.decode_all(encoded).to_a
end

private def w70_raw_u64_stream(part : String, stream : String) : Array(UInt64)
  bytes = w70_raw_stream(part, stream)
  raise "#{part} #{stream} UInt64 data is not aligned" unless bytes.size % 8 == 0
  Array(UInt64).new(bytes.size // 8) { |index| w70_read_u64(bytes, index * 8) }
end

private def w70_assert_writer_marks(part : String) : Nil
  expected_rows = W70_ORACLE_MARK_ROWS + [0_u64]
  W70_WRITER_RAW_MARK_SIZES.each do |stream, raw_sizes|
    records = w70_mark_records(part, stream)
    raise "#{part} #{stream} writer row vector differs" unless records.map(&.[2]) == expected_rows
    encoded = File.read(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
    compressed_offset = 0_i64
    raw_sizes.each_with_index do |raw_size, index|
      raise "#{part} #{stream} writer compressed offset differs" unless records[index][0] == compressed_offset.to_u64
      raise "#{part} #{stream} writer decompressed offset differs" unless records[index][1] == 0_u64
      next if raw_size == 0
      frame = CrystalClick::CompressedBlock.decode_frame(encoded, compressed_offset,
        CrystalClick::WidePartWriter::MAX_FRAME_COMPRESSED.to_i64,
        CrystalClick::WidePartWriter::MAX_FRAME_RAW_BYTES.to_i64)
      raise "#{part} #{stream} writer frame size differs" unless frame.output.size == raw_size
      compressed_offset = frame.end_offset
    end
    raise "#{part} #{stream} terminal mark differs" unless records.last == {compressed_offset.to_u64, 0_u64, 0_u64}
    raise "#{part} #{stream} trailing compressed bytes" unless compressed_offset == encoded.size.to_i64
  end
end

private def w70_assert_empty_child_writer_marks(part : String) : Nil
  expected_rows = [2_u64, 2_u64, 0_u64]
  raw_mark_sizes = {
    "id"               => [16, 16],
    "m.size0"          => [16, 16],
    "m%2Ekeys.size"    => [0, 8],
    "m%2Ekeys"         => [0, 0],
    "m%2Evalues.size1" => [0, 8],
    "m%2Evalues.null"  => [0, 1],
    "m%2Evalues.size"  => [0, 8],
    "m%2Evalues"       => [0, 0],
  }
  raw_mark_sizes.each do |stream, raw_sizes|
    records = w70_mark_records(part, stream, 3)
    raise "#{part} #{stream} writer row vector differs" unless records.map(&.[2]) == expected_rows
    encoded = File.read(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
    compressed_offset = 0_i64
    raw_sizes.each_with_index do |raw_size, index|
      raise "#{part} #{stream} writer compressed offset differs" unless records[index][0] == compressed_offset.to_u64
      raise "#{part} #{stream} writer decompressed offset differs" unless records[index][1] == 0_u64
      next if raw_size == 0
      frame = CrystalClick::CompressedBlock.decode_frame(encoded, compressed_offset,
        CrystalClick::WidePartWriter::MAX_FRAME_COMPRESSED.to_i64,
        CrystalClick::WidePartWriter::MAX_FRAME_RAW_BYTES.to_i64)
      raise "#{part} #{stream} writer frame size differs" unless frame.output.size == raw_size
      compressed_offset = frame.end_offset
    end
    raise "#{part} #{stream} terminal mark differs" unless records.last == {compressed_offset.to_u64, 0_u64, 0_u64}
    raise "#{part} #{stream} trailing compressed bytes" unless compressed_offset == encoded.size.to_i64
  end
end

private def w70_attach(binary : String, store : String, table : String, part : String, part_name : String = "all_1_1_0", expected_parts : Array(String) = ["all_1_1_0"]) : Nil
  data_path = w70_clickhouse(binary, store,
    "SELECT data_paths[1] FROM system.tables WHERE database = 'default' AND name = '#{table}' FORMAT TSVRaw").strip
  raise "#{table} data path missing" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, part_name))
  w70_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART '#{part_name}'")
  w70_check_table(binary, store, table, expected_parts)
end

binary = ENV.fetch("CLICKHOUSE_BIN")
store = ENV.fetch("CLICKHOUSE_STORE")
root = ENV.fetch("ORACLE_ROOT")
all_rows = (0...W70_ORACLE_KEYS.size).map(&.to_i32)
keyed_rows = (2...W70_ORACLE_KEYS.size).map(&.to_i32)
full_expected = w70_rowbinary(W70_ORACLE_KEYS, W70_ORACLE_ROWS, all_rows)
keyed_expected = w70_rowbinary(W70_ORACLE_KEYS, W70_ORACLE_ROWS, keyed_rows)

# Stock producer -> Crystal reader.
w70_create_table(binary, store, "w70_stock")
w70_clickhouse(binary, store, "INSERT INTO default.w70_stock FORMAT RowBinary", IO::Memory.new(full_expected))
w70_check_table(binary, store, "w70_stock")
w70_assert_columns(binary, store, "w70_stock")
w70_assert_rowbinary(binary, store, "w70_stock", full_expected, keyed_expected)
stock_part = w70_stock_part(binary, store, root, "w70_stock")
w70_assert_part_metadata(stock_part)
w70_assert_stock_marks(stock_part)
reader = CrystalClick::WidePart.open_typed(stock_part, "m")
raise "stock part full Crystal read differs" unless reader.read_map_string_array_nullable_string_mark_range("m", 0, reader.mark_count) == W70_ORACLE_ROWS
raise "stock all-NULL mark read differs" unless reader.read_map_string_array_nullable_string_mark_range("m", 2, 1) == W70_ORACLE_ROWS[4, 2]
raise "stock non-NULL tail mark read differs" unless reader.read_map_string_array_nullable_string_mark_range("m", 3, 1) == W70_ORACLE_ROWS[6, 1]
raise "stock all-NULL-to-tail boundary read differs" unless reader.read_map_string_array_nullable_string_mark_range("m", 2, 2) == W70_ORACLE_ROWS[4, 3]

# Mutate hidden NULL String size and consume one byte from the later visible
# String while preserving all total sizes and the stock shared-frame topology.
mutated_rows = W70_ORACLE_ROWS.map(&.dup)
mutated_rows[0] = W70_ORACLE_ROWS[0].dup
mutated_rows[0][0] = {"dup", [nil, "", "\0b", "café"] of String?}
mutated_stock_part = File.join(root, "stock-w70-hidden-null-string")
FileUtils.cp_r(stock_part, mutated_stock_part)
w70_mutate_stock_null_hidden_string(mutated_stock_part)
w70_assert_stock_marks(mutated_stock_part)
mutated_reader = CrystalClick::WidePart.open_typed(mutated_stock_part, "m")
raise "mutated stock NULL/tail read differs" unless mutated_reader.read_map_string_array_nullable_string_mark_range("m", 0, 1) == [mutated_rows[0], W70_ORACLE_ROWS[1]]
w70_create_table(binary, store, "w70_stock_hidden_null")
w70_attach(binary, store, "w70_stock_hidden_null", mutated_stock_part)
mutated_expected = w70_rowbinary(W70_ORACLE_KEYS, mutated_rows, all_rows)
mutated_keyed_expected = w70_rowbinary(W70_ORACLE_KEYS, mutated_rows, keyed_rows)
w70_assert_columns(binary, store, "w70_stock_hidden_null")
w70_assert_rowbinary(binary, store, "w70_stock_hidden_null", mutated_expected, mutated_keyed_expected)

# Crystal writer -> stock ClickHouse reader.
writer_part = File.join(root, "writer-w70")
CrystalClick::WidePartWriter.write_uint64_map_string_array_nullable_string_pair(
  writer_part,
  "id",
  W70_ORACLE_KEYS.to_unsafe.to_slice(W70_ORACLE_KEYS.size),
  "m",
  W70_ORACLE_ROWS.to_unsafe.to_slice(W70_ORACLE_ROWS.size),
  rows_per_mark: 2
)
w70_assert_part_metadata(writer_part)
w70_assert_writer_marks(writer_part)
w70_create_table(binary, store, "w70_writer")
w70_attach(binary, store, "w70_writer", writer_part)
w70_assert_columns(binary, store, "w70_writer")
w70_assert_rowbinary(binary, store, "w70_writer", full_expected, keyed_expected)

# Attach a second writer part with a positive-row all-empty Map mark, followed
# by a mark whose only key and visible value are empty Strings. The second
# mark forces zero-byte key/value data streams to be consumed at a later mark.
empty_child_part = File.join(root, "writer-w70-empty-child")
CrystalClick::WidePartWriter.write_uint64_map_string_array_nullable_string_pair(
  empty_child_part,
  "id",
  W70_EMPTY_CHILD_KEYS.to_unsafe.to_slice(W70_EMPTY_CHILD_KEYS.size),
  "m",
  W70_EMPTY_CHILD_ROWS.to_unsafe.to_slice(W70_EMPTY_CHILD_ROWS.size),
  rows_per_mark: 2
)
w70_assert_empty_child_writer_marks(empty_child_part)
w70_attach(binary, store, "w70_writer", empty_child_part, "all_2_2_0", ["all_1_1_0", "all_2_2_0"])
w70_assert_columns(binary, store, "w70_writer")
combined_keys = W70_ORACLE_KEYS + W70_EMPTY_CHILD_KEYS
combined_rows = W70_ORACLE_ROWS + W70_EMPTY_CHILD_ROWS
combined_indices = (0...combined_keys.size).map(&.to_i32)
combined_keyed_indices = (2...combined_keys.size).map(&.to_i32)
combined_expected = w70_rowbinary(combined_keys, combined_rows, combined_indices)
combined_keyed_expected = w70_rowbinary(combined_keys, combined_rows, combined_keyed_indices)
w70_assert_rowbinary(binary, store, "w70_writer", combined_expected, combined_keyed_expected, 10_u64)

puts "W70 pinned ClickHouse bidirectional Map(String, Array(Nullable(String))) oracle passed"
