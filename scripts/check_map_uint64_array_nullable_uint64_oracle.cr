require "file_utils"
require "../src/crystal_click"

W69_ORACLE_KEYS = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64]
W69_ORACLE_ROWS = [
  [] of Tuple(UInt64, Array(UInt64?)),
  [
    {7_u64, [nil, 0_u64] of UInt64?},
    {7_u64, [] of UInt64?},
  ] of Tuple(UInt64, Array(UInt64?)),
  [
    {UInt64::MAX, [UInt64::MAX, nil] of UInt64?},
    {0_u64, [] of UInt64?},
  ] of Tuple(UInt64, Array(UInt64?)),
  [{1_u64, [] of UInt64?}] of Tuple(UInt64, Array(UInt64?)),
  [
    {3_u64, [nil, nil] of UInt64?},
    {UInt64::MAX, [] of UInt64?},
  ] of Tuple(UInt64, Array(UInt64?)),
  [{4_u64, [nil, nil] of UInt64?}] of Tuple(UInt64, Array(UInt64?)),
  [{9_u64, [7_u64] of UInt64?}] of Tuple(UInt64, Array(UInt64?)),
] of Array(Tuple(UInt64, Array(UInt64?)))

W69_ORACLE_STREAMS = [
  "payload.size0",
  "payload%2Ekeys",
  "payload%2Evalues.size1",
  "payload%2Evalues.null",
  "payload%2Evalues",
]
W69_ORACLE_MARK_ROWS    = [2_u64, 2_u64, 2_u64, 1_u64]
W69_ORACLE_MARK_OFFSETS = {
  "pk"                     => [0_u64, 16_u64, 32_u64, 48_u64, 56_u64],
  "payload.size0"          => [0_u64, 16_u64, 32_u64, 48_u64, 56_u64],
  "payload%2Ekeys"         => [0_u64, 16_u64, 40_u64, 64_u64, 72_u64],
  "payload%2Evalues.size1" => [0_u64, 16_u64, 40_u64, 64_u64, 72_u64],
  "payload%2Evalues.null"  => [0_u64, 2_u64, 4_u64, 8_u64, 9_u64],
  "payload%2Evalues"       => [0_u64, 16_u64, 32_u64, 64_u64, 72_u64],
}
W69_WRITER_RAW_MARK_SIZES = {
  "pk"                     => [16, 16, 16, 8],
  "payload.size0"          => [16, 16, 16, 8],
  "payload%2Ekeys"         => [16, 24, 24, 8],
  "payload%2Evalues.size1" => [16, 24, 24, 8],
  "payload%2Evalues.null"  => [2, 2, 4, 1],
  "payload%2Evalues"       => [16, 16, 32, 8],
}

private def w69_clickhouse(binary : String, store : String, query : String, input : IO = IO::Memory.new) : String
  output = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], input: input, output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse query failed (#{status.exit_code}): #{query}" unless status.success?
  output.to_s
end

private def w69_u64(io : IO, value : UInt64) : Nil
  8.times { |byte| io.write_byte(((value >> (byte * 8)) & 0xff_u64).to_u8) }
end

private def w69_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w69_nullable_u64(io : IO, value : UInt64?) : Nil
  if value.nil?
    io.write_byte(1_u8)
  else
    io.write_byte(0_u8)
    w69_u64(io, value.not_nil!)
  end
end

# Independent RowBinary encoder: Map entries stay ordered and nullable leaves
# encode NULL separately from zero.
private def w69_rowbinary(keys : Array(UInt64), rows : Array(Array(Tuple(UInt64, Array(UInt64?)))), indices : Array(Int32)) : Bytes
  raise "RowBinary input row counts differ" unless keys.size == rows.size
  io = IO::Memory.new
  indices.each do |index|
    w69_u64(io, keys[index])
    entries = rows[index]
    w69_varuint(io, entries.size.to_u64)
    entries.each do |key, values|
      w69_u64(io, key)
      w69_varuint(io, values.size.to_u64)
      values.each { |value| w69_nullable_u64(io, value) }
    end
  end
  io.to_slice
end

private def w69_create_table(binary : String, store : String, table : String) : Nil
  w69_clickhouse(binary, store, <<-SQL)
  CREATE TABLE default.#{table} (pk UInt64, payload Map(UInt64, Array(Nullable(UInt64))))
  ENGINE = MergeTree ORDER BY pk
  SETTINGS index_granularity = 2, index_granularity_bytes = 10485760,
    enable_mixed_granularity_parts = 1, min_rows_for_wide_part = 0,
    min_bytes_for_wide_part = 0, compress_marks = 0,
    min_compress_block_size = 0, max_compress_block_size = 4096,
    ratio_of_defaults_for_sparse_serialization = 1.0,
    default_compression_codec = 'LZ4'
  SQL
end

private def w69_check_table(binary : String, store : String, table : String) : Nil
  observed = w69_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "#{table} CHECK TABLE failed: #{observed.inspect}" unless observed == "all_1_1_0\t1"
end

private def w69_assert_rowbinary(binary : String, store : String, table : String, full_expected : Bytes, keyed_expected : Bytes) : Nil
  full = w69_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  raise "#{table} full RowBinary mismatch" unless full.to_slice == full_expected
  keyed = w69_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} WHERE pk >= 3 AND pk <= 7 ORDER BY pk FORMAT RowBinary")
  raise "#{table} keyed RowBinary mismatch" unless keyed.to_slice == keyed_expected
end

private def w69_assert_columns(binary : String, store : String, table : String) : Nil
  actual = w69_clickhouse(binary, store,
    "SELECT name || ' ' || type FROM system.columns WHERE database = 'default' AND table = '#{table}' ORDER BY position FORMAT TSVRaw")
  expected = "pk UInt64\npayload Map(UInt64, Array(Nullable(UInt64)))\n"
  raise "#{table} exact system.columns mismatch: #{actual.inspect}" unless actual == expected
end

private def w69_stock_part(binary : String, store : String, root : String, table : String) : String
  path = w69_clickhouse(binary, store, "SELECT path FROM system.parts WHERE database = 'default' AND table = '#{table}' AND active FORMAT TSVRaw").strip
  raise "#{table} stock source part missing" unless Dir.exists?(path)
  part = File.join(root, "stock-#{table}")
  FileUtils.cp_r(path, part)
  part
end

private def w69_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

private def w69_write_u32(bytes : Bytes, offset : Int, value : UInt32) : Nil
  4.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u32).to_u8 }
end

private def w69_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def w69_write_hash(io : IO, hash : {UInt64, UInt64}) : Nil
  8.times { |byte| io.write_byte(((hash[0] >> (byte * 8)) & 0xff_u64).to_u8) }
  8.times { |byte| io.write_byte(((hash[1] >> (byte * 8)) & 0xff_u64).to_u8) }
end

private def w69_literal_lz4_frame(raw : Bytes) : Bytes
  raise "cannot encode an empty LZ4 frame" if raw.empty?
  extension_size = raw.size < 15 ? 0 : ((raw.size - 15) // 255) + 1
  payload_size = 1 + extension_size + raw.size
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload_size
  frame = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload_size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  frame[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  w69_write_u32(frame, header + 1, compressed_size.to_u32)
  w69_write_u32(frame, header + 5, raw.size.to_u32)

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
  w69_write_u64(frame, 0, hash[0])
  w69_write_u64(frame, 8, hash[1])
  frame
end

private def w69_refresh_checksums(part : String) : Nil
  parsed = CrystalClick::PartChecksums.open(part)
  payload = IO::Memory.new
  names = parsed.entries.keys.sort
  w69_varuint(payload, names.size.to_u64)
  names.each do |name|
    file_bytes = File.read(File.join(part, name)).to_slice
    entry = parsed.entries[name]
    w69_varuint(payload, name.bytesize.to_u64)
    payload.write(name.to_slice)
    w69_varuint(payload, file_bytes.size.to_u64)
    w69_write_hash(payload, CrystalClick::CityHashV1.file_hash(file_bytes))
    if entry.compressed
      raw = CrystalClick::CompressedBlock.decode_all(file_bytes)
      payload.write_byte(1_u8)
      w69_varuint(payload, raw.size.to_u64)
      w69_write_hash(payload, CrystalClick::CityHashV1.file_hash(raw))
    else
      payload.write_byte(0_u8)
    end
  end
  output = IO::Memory.new
  output << CrystalClick::PartChecksums::CHECKSUMS_HEADER
  output.write(w69_literal_lz4_frame(payload.to_slice))
  File.write(File.join(part, "checksums.txt"), output.to_slice)
end

private def w69_mutate_stock_null_hidden_value(part : String, value_stream : String, null_stream : String, mark_index : Int32) : Nil
  value_marks = w69_mark_records(part, value_stream)
  null_marks = w69_mark_records(part, null_stream)
  value_mark = value_marks[mark_index]
  null_mark = null_marks[mark_index]
  value_encoded_path = File.join(part, "#{CrystalClick::StreamName.hash(value_stream)}.bin")
  value_encoded = File.read(value_encoded_path).to_slice
  value_frame = CrystalClick::CompressedBlock.decode_frame(value_encoded, value_mark[0].to_i64)
  raise "stock #{value_stream} mark does not share one LZ4 frame" unless value_mark[0] == 0_u64 && value_frame.end_offset == value_encoded.size.to_i64

  null_raw = w69_raw_stream(part, null_stream)
  null_end = null_marks[mark_index + 1][1].to_i
  null_range = null_raw[null_mark[1].to_i, null_end - null_mark[1].to_i]
  raise "selected stock mark is not all-NULL" unless value_mark[2] > 0_u64 && null_mark[2] > 0_u64 && !null_range.empty? && null_range.all? { |flag| flag == 1_u8 }

  raw = value_frame.output.dup
  value_offset = value_mark[1].to_i
  hidden_value = 0xfedcba9876543210_u64
  raise "NULL placeholder offset exceeds stock values stream" if value_offset > raw.size - 8
  w69_write_u64(raw, value_offset, hidden_value)

  # This pinned producer stores one shared LZ4 frame per physical stream. Keep
  # that topology and all decompressed mark coordinates intact while changing
  # a hidden NULL slot, then refresh the data and part checksums.
  File.write(value_encoded_path, w69_literal_lz4_frame(raw))
  w69_refresh_checksums(part)
  mutated_values = w69_raw_u64_stream(part, value_stream)
  raise "stock NULL placeholder mutation did not land at decompressed mark offset" unless mutated_values[value_offset // 8] == hidden_value
end

private def w69_mark_records(part : String, stream : String) : Array(Tuple(UInt64, UInt64, UInt64))
  marks_path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  bytes = File.read(marks_path).to_slice
  expected_bytes = 5 * CrystalClick::WidePart::MARK_SIZE
  raise "#{part} #{stream} mark file size differs" unless bytes.size == expected_bytes
  Array(Tuple(UInt64, UInt64, UInt64)).new(5) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE
    {w69_read_u64(bytes, offset), w69_read_u64(bytes, offset + 8), w69_read_u64(bytes, offset + 16)}
  end
end

private def w69_assert_part_metadata(part : String) : Nil
  expected_columns = "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` Map(UInt64, Array(Nullable(UInt64)))\n"
  raise "#{part} columns differ" unless File.read(File.join(part, "columns.txt")) == expected_columns
  expected_substreams = "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n" +
                        "5 substreams for column `payload`:\n" + W69_ORACLE_STREAMS.map { |name| "\t#{name}\n" }.join
  raise "#{part} substreams differ" unless File.read(File.join(part, "columns_substreams.txt")) == expected_substreams
  expected_serialization = %({"columns":[],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
  raise "#{part} serialization differs" unless File.read(File.join(part, "serialization.json")).strip == expected_serialization
  raise "#{part} default codec differs" unless File.read(File.join(part, "default_compression_codec.txt")).strip == "CODEC(LZ4)"
  raise "#{part} metadata version differs" unless File.read(File.join(part, "metadata_version.txt")).strip == "0"
  raise "#{part} row count differs" unless File.read(File.join(part, "count.txt")).strip == W69_ORACLE_KEYS.size.to_s
end

# Pinned stock ClickHouse emits a plain .mrk2 stream coordinate for each
# table-row mark. The decompressed offset advances along each stream's storage
# axis, not by the number of table rows.
private def w69_assert_stock_marks(part : String) : Nil
  expected_rows = W69_ORACLE_MARK_ROWS + [0_u64]
  (["pk"] + W69_ORACLE_STREAMS).each do |stream|
    records = w69_mark_records(part, stream)
    raise "#{part} #{stream} compressed offsets differ" unless records.all? { |record| record[0] == 0_u64 }
    raise "#{part} #{stream} decompressed offsets differ" unless records.map(&.[1]) == W69_ORACLE_MARK_OFFSETS[stream]
    raise "#{part} #{stream} table-row marks differ" unless records.map(&.[2]) == expected_rows
  end
end

private def w69_raw_stream(part : String, stream : String) : Array(UInt8)
  encoded = File.read(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
  CrystalClick::CompressedBlock.decode_all(encoded).to_a
end

private def w69_raw_u64_stream(part : String, stream : String) : Array(UInt64)
  bytes = w69_raw_stream(part, stream)
  raise "#{part} #{stream} UInt64 data is not aligned" unless bytes.size % 8 == 0
  Array(UInt64).new(bytes.size // 8) do |index|
    value = 0_u64
    8.times { |byte| value |= bytes[index * 8 + byte].to_u64 << (byte * 8) }
    value
  end
end

private def w69_assert_writer_marks(part : String) : Nil
  expected_rows = W69_ORACLE_MARK_ROWS + [0_u64]
  W69_WRITER_RAW_MARK_SIZES.each do |stream, raw_sizes|
    records = w69_mark_records(part, stream)
    raise "#{part} #{stream} table-row marks differ" unless records.map(&.[2]) == expected_rows
    encoded = File.read(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
    compressed_offset = 0_i64
    raw_sizes.each_with_index do |raw_size, index|
      raise "#{part} #{stream} compressed mark offset differs" unless records[index][0] == compressed_offset.to_u64
      raise "#{part} #{stream} writer decompressed mark offset is not zero" unless records[index][1] == 0_u64
      frame = CrystalClick::CompressedBlock.decode_frame(
        encoded,
        compressed_offset,
        CrystalClick::WidePartWriter::MAX_FRAME_COMPRESSED.to_i64,
        CrystalClick::WidePartWriter::MAX_FRAME_RAW_BYTES.to_i64
      )
      raise "#{part} #{stream} frame raw size differs" unless frame.output.size == raw_size
      compressed_offset = frame.end_offset
    end
    terminal = records.last
    raise "#{part} #{stream} terminal mark differs" unless terminal == {compressed_offset.to_u64, 0_u64, 0_u64}
    raise "#{part} #{stream} compressed stream has trailing bytes" unless compressed_offset == encoded.size.to_i64
  end
end

private def w69_attach(binary : String, store : String, table : String, part : String) : Nil
  data_path = w69_clickhouse(binary, store,
    "SELECT data_paths[1] FROM system.tables WHERE database = 'default' AND name = '#{table}' FORMAT TSVRaw").strip
  raise "#{table} data path missing" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  w69_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  w69_check_table(binary, store, table)
end

binary = ENV.fetch("CLICKHOUSE_BIN")
store = ENV.fetch("CLICKHOUSE_STORE")
root = ENV.fetch("ORACLE_ROOT")
all_rows = (0...W69_ORACLE_KEYS.size).map(&.to_i32)
keyed_rows = (2...W69_ORACLE_KEYS.size).map(&.to_i32)
full_expected = w69_rowbinary(W69_ORACLE_KEYS, W69_ORACLE_ROWS, all_rows)
keyed_expected = w69_rowbinary(W69_ORACLE_KEYS, W69_ORACLE_ROWS, keyed_rows)

# Stock ClickHouse producer -> Crystal reader.
w69_create_table(binary, store, "w69_stock")
w69_clickhouse(binary, store, "INSERT INTO default.w69_stock FORMAT RowBinary", IO::Memory.new(full_expected))
w69_check_table(binary, store, "w69_stock")
w69_assert_columns(binary, store, "w69_stock")
w69_assert_rowbinary(binary, store, "w69_stock", full_expected, keyed_expected)
stock_part = w69_stock_part(binary, store, root, "w69_stock")
w69_assert_part_metadata(stock_part)
w69_assert_stock_marks(stock_part)
reader = CrystalClick::WidePart.open_typed(stock_part, "payload")
raise "stock part full Crystal read differs" unless reader.read_map_uint64_array_nullable_uint64_mark_range("payload", 0, reader.mark_count) == W69_ORACLE_ROWS
raise "stock first mark read differs" unless reader.read_map_uint64_array_nullable_uint64_mark_range("payload", 0, 1) == W69_ORACLE_ROWS[0, 2]
raise "stock nullable/extrema mark read differs" unless reader.read_map_uint64_array_nullable_uint64_mark_range("payload", 2, 1) == W69_ORACLE_ROWS[4, 2]
raise "stock tail mark read differs" unless reader.read_map_uint64_array_nullable_uint64_mark_range("payload", 3, 1) == W69_ORACLE_ROWS[6, 1]
raise "stock all-NULL-to-tail boundary read differs" unless reader.read_map_uint64_array_nullable_uint64_mark_range("payload", 2, 2) == W69_ORACLE_ROWS[4, 3]

# Adversarial nullable-slot check against the pinned stock part. The stock
# frame has all mark starts at compressed offset zero, so the mutation targets
# mark 2's decompressed UInt64 offset (32), not the start of the shared frame.
mutated_stock_part = File.join(root, "stock-w69-hidden-null")
FileUtils.cp_r(stock_part, mutated_stock_part)
w69_mutate_stock_null_hidden_value(mutated_stock_part, "payload%2Evalues", "payload%2Evalues.null", 2)
w69_assert_stock_marks(mutated_stock_part)
mutated_reader = CrystalClick::WidePart.open_typed(mutated_stock_part, "payload")
raise "mutated stock all-NULL mark read differs" unless mutated_reader.read_map_uint64_array_nullable_uint64_mark_range("payload", 2, 1) == W69_ORACLE_ROWS[4, 2]
raise "mutated stock all-NULL-to-tail read lost alignment" unless mutated_reader.read_map_uint64_array_nullable_uint64_mark_range("payload", 2, 2) == W69_ORACLE_ROWS[4, 3]
w69_create_table(binary, store, "w69_stock_hidden_null")
w69_attach(binary, store, "w69_stock_hidden_null", mutated_stock_part)
w69_assert_columns(binary, store, "w69_stock_hidden_null")
w69_assert_rowbinary(binary, store, "w69_stock_hidden_null", full_expected, keyed_expected)

# Crystal writer -> stock ClickHouse reader.
writer_part = File.join(root, "writer-w69")
CrystalClick::WidePartWriter.write_uint64_map_uint64_array_nullable_uint64_pair(
  writer_part,
  "pk",
  W69_ORACLE_KEYS.to_unsafe.to_slice(W69_ORACLE_KEYS.size),
  "payload",
  W69_ORACLE_ROWS.to_unsafe.to_slice(W69_ORACLE_ROWS.size),
  rows_per_mark: 2
)
w69_assert_part_metadata(writer_part)
w69_assert_writer_marks(writer_part)
raise "writer null-map bytes differ" unless w69_raw_stream(writer_part, "payload%2Evalues.null") == [1_u8, 0_u8, 0_u8, 1_u8, 1_u8, 1_u8, 1_u8, 1_u8, 0_u8]
raise "writer NULL slots are not deterministic zeroes" unless w69_raw_u64_stream(writer_part, "payload%2Evalues") == [0_u64, 0_u64, UInt64::MAX, 0_u64, 0_u64, 0_u64, 0_u64, 0_u64, 7_u64]
w69_create_table(binary, store, "w69_writer")
w69_attach(binary, store, "w69_writer", writer_part)
w69_assert_columns(binary, store, "w69_writer")
w69_assert_rowbinary(binary, store, "w69_writer", full_expected, keyed_expected)

puts "W69 pinned ClickHouse bidirectional Map(UInt64, Array(Nullable(UInt64))) oracle passed"
