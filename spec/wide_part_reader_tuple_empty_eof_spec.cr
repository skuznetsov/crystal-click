require "./spec_helper"

private def w92_tuple_empty_eof_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times do |index|
    value |= bytes[offset + index].to_u64 << (index * 8)
  end
  value
end

private def w92_tuple_empty_eof_raw_marks(part_path : String) : Array(Tuple(UInt64, UInt64, UInt64))
  stream = CrystalClick::StreamName.hash("payload%2Eb")
  mark_path = File.join(part_path, "#{stream}.mrk2")
  File.exists?(mark_path).should be_true

  bytes = File.read(mark_path).to_slice
  (bytes.size % CrystalClick::WidePart::MARK_SIZE).should eq(0)
  marks = [] of Tuple(UInt64, UInt64, UInt64)
  (bytes.size // CrystalClick::WidePart::MARK_SIZE).times do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE
    marks << {
      w92_tuple_empty_eof_u64(bytes, offset),
      w92_tuple_empty_eof_u64(bytes, offset + 8),
      w92_tuple_empty_eof_u64(bytes, offset + 16),
    }
  end
  marks
end

private def with_w92_tuple_empty_eof_part(
  values : Array(Tuple(UInt64, String)),
  rows_per_mark : Int32,
  & : String ->
)
  parent = File.tempname("crystal-click-w92-tuple-empty-eof")
  Dir.mkdir(parent)
  destination = File.join(parent, "part")
  keys = values.map(&.[0])

  begin
    CrystalClick::WidePartWriter.write_uint64_tuple_string_pair(
      destination,
      "pk",
      keys.to_unsafe.to_slice(keys.size),
      "payload",
      values,
      rows_per_mark: rows_per_mark
    )
    yield destination
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def w92_tuple_empty_eof_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w92_tuple_empty_eof_write_u32(bytes : Bytes, offset : Int, value : UInt32) : Nil
  4.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u32).to_u8 }
end

private def w92_tuple_empty_eof_write_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w92_tuple_empty_eof_write_hash(io : IO, hash : {UInt64, UInt64}) : Nil
  8.times { |index| io.write_byte(((hash[0] >> (index * 8)) & 0xff_u64).to_u8) }
  8.times { |index| io.write_byte(((hash[1] >> (index * 8)) & 0xff_u64).to_u8) }
end

private def w92_tuple_empty_eof_encode_lz4_frame(raw : Bytes) : Bytes
  raise "W92 checksum fixture cannot encode an empty LZ4 block" if raw.empty?
  extension_size = raw.size < 15 ? 0 : ((raw.size - 15) // 255) + 1
  payload_size = 1 + extension_size + raw.size
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload_size
  frame = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload_size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  frame[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  w92_tuple_empty_eof_write_u32(frame, header + 1, compressed_size.to_u32)
  w92_tuple_empty_eof_write_u32(frame, header + 5, raw.size.to_u32)
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
  raw.copy_to(frame[cursor, raw.size])
  checksum = CrystalClick::CityHashV1.hash128(frame[header, compressed_size])
  w92_tuple_empty_eof_write_u64(frame, 0, checksum[0])
  w92_tuple_empty_eof_write_u64(frame, 8, checksum[1])
  frame
end

private def w92_tuple_empty_eof_refresh_checksums(part_path : String) : Nil
  checksums = CrystalClick::PartChecksums.open(part_path)
  payload = IO::Memory.new
  names = checksums.entries.keys.sort
  w92_tuple_empty_eof_write_varuint(payload, names.size.to_u64)
  names.each do |name|
    file_bytes = File.read(File.join(part_path, name)).to_slice
    entry = checksums.entries[name]
    w92_tuple_empty_eof_write_varuint(payload, name.bytesize.to_u64)
    payload.write(name.to_slice)
    w92_tuple_empty_eof_write_varuint(payload, file_bytes.size.to_u64)
    w92_tuple_empty_eof_write_hash(payload, CrystalClick::CityHashV1.file_hash(file_bytes))
    if entry.compressed
      raw = if file_bytes.empty?
              raise "W92 empty compressed checksum entry must declare zero raw bytes" unless entry.uncompressed_size == 0_u64
              file_bytes
            else
              CrystalClick::CompressedBlock.decode_all(file_bytes)
            end
      payload.write_byte(1_u8)
      w92_tuple_empty_eof_write_varuint(payload, raw.size.to_u64)
      w92_tuple_empty_eof_write_hash(payload, CrystalClick::CityHashV1.file_hash(raw))
    else
      payload.write_byte(0_u8)
    end
  end
  frame = w92_tuple_empty_eof_encode_lz4_frame(payload.to_slice)
  File.open(File.join(part_path, "checksums.txt"), "wb") do |io|
    io << CrystalClick::PartChecksums::CHECKSUMS_HEADER
    io.write(frame)
  end
end

private def w92_tuple_empty_eof_mutate_first_string_size(part_path : String) : Nil
  stream_name = "payload%2Eb.size"
  data_path = File.join(part_path, "#{CrystalClick::StreamName.hash(stream_name)}.bin")
  encoded = File.read(data_path).to_slice.dup
  original_file_size = encoded.size
  original_frame = CrystalClick::CompressedBlock.decode_frame(encoded, 0_i64)
  raise "W92 size mutation requires a single frame" unless original_frame.end_offset == encoded.size
  raw = original_frame.output.dup
  raise "W92 size mutation expected an empty first String" unless w92_tuple_empty_eof_u64(raw, 0) == 0_u64
  w92_tuple_empty_eof_write_u64(raw, 0, 1_u64)
  replacement = w92_tuple_empty_eof_encode_lz4_frame(raw)
  raise "W92 size mutation changed the compressed frame size" unless replacement.size == original_frame.end_offset
  replacement.copy_to(encoded)
  File.write(data_path, encoded)
  w92_tuple_empty_eof_refresh_checksums(part_path)

  mutated = CrystalClick::CompressedBlock.decode_frame(File.read(data_path).to_slice, 0_i64)
  w92_tuple_empty_eof_u64(mutated.output, 0).should eq(1_u64)
  mutated.end_offset.should eq(original_frame.end_offset)
  File.size(data_path).should eq(original_file_size)
end

private def w92_tuple_empty_eof_move_second_mark_to_eof(part_path : String, stream_name : String) : Nil
  data_path = File.join(part_path, "#{CrystalClick::StreamName.hash(stream_name)}.bin")
  marks_path = File.join(part_path, "#{CrystalClick::StreamName.hash(stream_name)}.mrk2")
  data_size = File.size(data_path).to_u64
  marks = File.read(marks_path).to_slice.dup
  raise "W92 mark mutation requires two data marks and a sentinel" unless marks.size == 3 * CrystalClick::WidePart::MARK_SIZE
  w92_tuple_empty_eof_write_u64(marks, CrystalClick::WidePart::MARK_SIZE, data_size)
  File.write(marks_path, marks)
  w92_tuple_empty_eof_refresh_checksums(part_path)
end

describe "W92 exact Tuple empty String EOF" do
  it "reads one empty String leaf row after the writer publishes a zero-byte raw stream" do
    values = [{7_u64, ""}]
    with_w92_tuple_empty_eof_part(values, 1) do |part_path|
      raw_path = File.join(part_path, "#{CrystalClick::StreamName.hash("payload%2Eb")}.bin")
      File.exists?(raw_path).should be_true
      File.size(raw_path).should eq(0_i64)
      marks = w92_tuple_empty_eof_raw_marks(part_path)
      marks.map(&.[2]).should eq([1_u64, 0_u64])
      marks.map(&.[0]).should eq([0_u64, 0_u64])
      marks.map(&.[1]).should eq([0_u64, 0_u64])

      reader = CrystalClick::WidePart.open_typed(part_path, "payload")
      reader.tuple_uint64_string_mark_range_raw_bytes("payload", 0, 1).should eq(0_u64)
      reader.read_tuple_uint64_string_mark_range("payload", 0, 1).should eq(values)
    end
  end

  it "reads full and ranged all-empty marks including a short final mark" do
    values = [
      {0_u64, ""},
      {1_u64, ""},
      {2_u64, ""},
      {3_u64, ""},
      {4_u64, ""},
    ]
    with_w92_tuple_empty_eof_part(values, 2) do |part_path|
      raw_path = File.join(part_path, "#{CrystalClick::StreamName.hash("payload%2Eb")}.bin")
      File.exists?(raw_path).should be_true
      File.size(raw_path).should eq(0_i64)
      marks = w92_tuple_empty_eof_raw_marks(part_path)
      marks.map(&.[2]).should eq([2_u64, 2_u64, 1_u64, 0_u64])
      marks.map(&.[0]).should eq([0_u64, 0_u64, 0_u64, 0_u64])
      marks.map(&.[1]).should eq([0_u64, 0_u64, 0_u64, 0_u64])

      reader = CrystalClick::WidePart.open_typed(part_path, "payload")
      reader.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
      reader.tuple_uint64_string_mark_range_raw_bytes("payload", 0, 3).should eq(0_u64)
      reader.read_tuple_uint64_string_mark_range("payload", 0, 3).should eq(values)
      [
        {0, 1, values[0, 2]},
        {1, 1, values[2, 2]},
        {2, 1, values[4, 1]},
      ].each do |first_mark, mark_count, expected|
        reader.tuple_uint64_string_mark_range_raw_bytes("payload", first_mark, mark_count).should eq(0_u64)
        reader.read_tuple_uint64_string_mark_range("payload", first_mark, mark_count).should eq(expected)
      end
      reader.read_tuple_uint64_string_mark_range("payload", 1, 2).should eq(values[2, 3])
    end
  end

  it "reads trailing empty marks at positive-row EOF boundaries after nonempty data" do
    values = [
      {0_u64, "a"},
      {1_u64, "bc"},
      {2_u64, ""},
      {3_u64, ""},
      {4_u64, ""},
    ]
    with_w92_tuple_empty_eof_part(values, 2) do |part_path|
      raw_path = File.join(part_path, "#{CrystalClick::StreamName.hash("payload%2Eb")}.bin")
      File.exists?(raw_path).should be_true
      raw_size = File.size(raw_path)
      raw_size.should be > 0
      marks = w92_tuple_empty_eof_raw_marks(part_path)
      marks.map(&.[2]).should eq([2_u64, 2_u64, 1_u64, 0_u64])
      marks.map(&.[0]).should eq([0_u64, raw_size.to_u64, raw_size.to_u64, raw_size.to_u64])
      marks.map(&.[1]).should eq([0_u64, 0_u64, 0_u64, 0_u64])

      reader = CrystalClick::WidePart.open_typed(part_path, "payload")
      reader.tuple_uint64_string_mark_range_raw_bytes("payload", 0, 3).should eq(3_u64)
      reader.tuple_uint64_string_mark_range_raw_bytes("payload", 1, 2).should eq(0_u64)
      reader.read_tuple_uint64_string_mark_range("payload", 0, 3).should eq(values)
      reader.read_tuple_uint64_string_mark_range("payload", 1, 2).should eq(values[2, 3])
      reader.read_tuple_uint64_string_mark_range("payload", 2, 1).should eq(values[4, 1])
    end
  end

  it "keeps the nonempty Tuple string control readable" do
    values = [
      {10_u64, "alpha"},
      {11_u64, "beta"},
      {12_u64, "gamma"},
    ]
    with_w92_tuple_empty_eof_part(values, 2) do |part_path|
      raw_path = File.join(part_path, "#{CrystalClick::StreamName.hash("payload%2Eb")}.bin")
      File.exists?(raw_path).should be_true
      raw_size = File.size(raw_path)
      raw_size.should be > 0
      marks = w92_tuple_empty_eof_raw_marks(part_path)
      marks.map(&.[2]).should eq([2_u64, 1_u64, 0_u64])
      marks.first[0].should eq(0_u64)
      marks.last[0].should eq(raw_size.to_u64)

      reader = CrystalClick::WidePart.open_typed(part_path, "payload")
      reader.tuple_uint64_string_mark_range_raw_bytes("payload", 0, 2).should eq(14_u64)
      reader.read_tuple_uint64_string_mark_range("payload", 0, 2).should eq(values)
    end
  end

  it "rejects declared nonzero String bytes when the exact Tuple raw stream is empty" do
    values = [{7_u64, ""}]
    with_w92_tuple_empty_eof_part(values, 1) do |part_path|
      raw_path = File.join(part_path, "#{CrystalClick::StreamName.hash("payload%2Eb")}.bin")
      File.exists?(raw_path).should be_true
      File.size(raw_path).should eq(0_i64)
      raw_marks = w92_tuple_empty_eof_raw_marks(part_path)
      raw_marks.map(&.[2]).should eq([1_u64, 0_u64])
      raw_marks.map(&.[0]).should eq([0_u64, 0_u64])

      size_path = File.join(part_path, "#{CrystalClick::StreamName.hash("payload%2Eb.size")}.bin")
      original_size_file_size = File.size(size_path)
      original_size_frame_size = CrystalClick::CompressedBlock.decode_frame(File.read(size_path).to_slice, 0_i64).end_offset
      w92_tuple_empty_eof_mutate_first_string_size(part_path)
      File.size(size_path).should eq(original_size_file_size)
      CrystalClick::CompressedBlock.decode_frame(File.read(size_path).to_slice, 0_i64).end_offset.should eq(original_size_frame_size)
      File.size(raw_path).should eq(0_i64)
      w92_tuple_empty_eof_raw_marks(part_path).should eq(raw_marks)

      reader = CrystalClick::WidePart.open_typed(part_path, "payload")
      expect_raises(CrystalClick::CorruptPartError, "empty payload range at EOF must select zero expected bytes") do
        reader.tuple_uint64_string_mark_range_raw_bytes("payload", 0, 1)
      end
      expect_raises(CrystalClick::CorruptPartError, "empty payload range at EOF must select zero expected bytes") do
        reader.read_tuple_uint64_string_mark_range("payload", 0, 1)
      end
    end
  end

  it "keeps Tuple numeric and String-size marks ineligible for empty EOF" do
    values = [{0_u64, ""}, {1_u64, ""}]
    ["payload%2Ea", "payload%2Eb.size"].each do |stream_name|
      with_w92_tuple_empty_eof_part(values, 1) do |part_path|
        w92_tuple_empty_eof_move_second_mark_to_eof(part_path, stream_name)
        expect_raises(CrystalClick::CorruptPartError, "mark compressed offset exceeds data") do
          CrystalClick::WidePart.open_typed(part_path, "payload")
        end
      end
    end
  end
end
