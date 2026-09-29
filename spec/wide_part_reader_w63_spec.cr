require "./spec_helper"
require "file_utils"

W63_READER_KEYS       = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64, 15_u64, 17_u64]
W63_READER_BINARY_KEY = String.new(Bytes[0x41_u8, 0_u8, 0x42_u8, 0xff_u8])
W63_READER_VALUES     = [
  [] of Tuple(String, Array(UInt64)),
  [
    {"dup", [] of UInt64},
    {"dup", [0_u64, UInt64::MAX] of UInt64},
    {W63_READER_BINARY_KEY, [42_u64, 42_u64] of UInt64},
  ] of Tuple(String, Array(UInt64)),
  [] of Tuple(String, Array(UInt64)),
  [] of Tuple(String, Array(UInt64)),
  [{"empty", [] of UInt64}] of Tuple(String, Array(UInt64)),
  [{"雪", [7_u64] of UInt64}] of Tuple(String, Array(UInt64)),
  [] of Tuple(String, Array(UInt64)),
  [{"tail", [9_u64, 9_u64] of UInt64}] of Tuple(String, Array(UInt64)),
  [{"last", [] of UInt64}] of Tuple(String, Array(UInt64)),
] of Array(Tuple(String, Array(UInt64)))

private def with_w63_reader_part(& : String ->)
  parent = File.tempname("crystal-click-w63-reader")
  Dir.mkdir(parent)
  part = File.join(parent, "all_1_1_0")
  CrystalClick::WidePartWriter.write_uint64_map_string_array_uint64_pair(
    part,
    "pk",
    W63_READER_KEYS.to_unsafe.to_slice(W63_READER_KEYS.size),
    "payload",
    W63_READER_VALUES.to_unsafe.to_slice(W63_READER_VALUES.size),
    rows_per_mark: 2
  )
  begin
    yield part
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def w63_reader_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def w63_reader_write_u32(bytes : Bytes, offset : Int, value : UInt32) : Nil
  4.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u32).to_u8 }
end

private def w63_reader_shift_mark(path : String, stream : String, mark_index : Int) : Nil
  marks_path = File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  marks = File.read(marks_path).to_slice.dup
  offset = mark_index * CrystalClick::WidePart::MARK_SIZE
  raise "W63 selected mark is missing for #{stream}" if offset > marks.size - CrystalClick::WidePart::MARK_SIZE
  compressed_offset = 0_u64
  8.times { |byte| compressed_offset |= marks[offset + byte].to_u64 << (byte * 8) }
  w63_reader_write_u64(marks, offset, compressed_offset + 1_u64)
  File.write(marks_path, marks)
end

private def w63_reader_rewrite_first_size1(path : String, value : UInt64) : Nil
  data_path = File.join(path, "#{CrystalClick::StreamName.hash("payload%2Evalues.size1")}.bin")
  encoded = File.read(data_path).to_slice.dup
  frame = CrystalClick::CompressedBlock.decode_frame(encoded, 0_i64)
  raw = frame.output.dup
  w63_reader_write_u64(raw, 0, value)

  extension_size = raw.size < 15 ? 0 : ((raw.size - 15) // 255) + 1
  payload_size = 1 + extension_size + raw.size
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload_size
  rewritten = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload_size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  rewritten[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  w63_reader_write_u32(rewritten, header + 1, compressed_size.to_u32)
  w63_reader_write_u32(rewritten, header + 5, raw.size.to_u32)
  cursor = CrystalClick::CompressedBlock::FRAME_HEADER_SIZE
  if raw.size < 15
    rewritten[cursor] = (raw.size << 4).to_u8
    cursor += 1
  else
    rewritten[cursor] = 0xf0_u8
    cursor += 1
    remaining = raw.size - 15
    while remaining >= 255
      rewritten[cursor] = 255_u8
      cursor += 1
      remaining -= 255
    end
    rewritten[cursor] = remaining.to_u8
    cursor += 1
  end
  raw.copy_to(rewritten.to_unsafe + cursor, raw.size)
  hash = CrystalClick::CityHashV1.hash128(rewritten[header, compressed_size])
  w63_reader_write_u64(rewritten, 0, hash[0])
  w63_reader_write_u64(rewritten, 8, hash[1])
  raise "W63 size1 mutation changed frame size" unless rewritten.size == frame.end_offset
  rewritten.copy_to(encoded.to_unsafe, rewritten.size)
  File.write(data_path, encoded)
end

describe CrystalClick::WidePart do
  it "admits the W63 Map of UInt64 Arrays shape without nearby unsupported spellings" do
    CrystalClick::WidePart.supports_typed_type?("Map(String, Array(UInt64))").should be_true
    {
      "Map(UInt32, Array(UInt64))",
      "Map(String, Array(Array(UInt64)))",
      "Map(String, Array(UInt64)) trailing",
    }.each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end
  end

  it "reads selected marks in Map order and preflights nested Array objects" do
    with_w63_reader_part do |path|
      reader = CrystalClick::WidePart.open_typed(path, "payload")
      reader.column_type.should eq("Map(String, Array(UInt64))")
      reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64, 1_u64])
      reader.read_map_string_array_uint64_mark_range("payload", 0, reader.mark_count).should eq(W63_READER_VALUES)

      # Mark index 1 contains empty Maps; the next mark carries data after it.
      reader.read_map_string_array_uint64_mark_range("payload", 1, 3)
        .should eq(W63_READER_VALUES[2, 6])
      reader.read_map_string_array_uint64_mark_range("payload", 1, 1)
        .should eq(W63_READER_VALUES[2, 2])
      reader.map_string_array_uint64_mark_range_raw_bytes("payload", 0, 5).should eq(82_u64)
      reader.map_string_array_uint64_mark_range_materialization_preflight("payload", 0, 5)
        .should eq({82_u64, 434_u64})
      # Two empty Map rows still charge their outer row slots.
      reader.map_string_array_uint64_mark_range_materialization_preflight("payload", 1, 1)
        .should eq({0_u64, 16_u64})
      expect_raises(CrystalClick::BoundsError) do
        reader.read_map_string_array_uint64_mark_range("payload", 0, 0)
      end
      expect_raises(CrystalClick::BoundsError) do
        reader.read_map_string_array_uint64_mark_range("payload", reader.mark_count, 1)
      end
    end
  end

  it "rejects a shifted selected mark boundary in each of the five physical streams" do
    [
      "payload.size0",
      "payload%2Ekeys.size",
      "payload%2Ekeys",
      "payload%2Evalues.size1",
      "payload%2Evalues",
    ].each do |stream|
      with_w63_reader_part do |path|
        # The third mark follows the intentionally empty middle mark. Shifting
        # it by one compressed byte must fail closed before values are returned.
        w63_reader_shift_mark(path, stream, 2)
        reader = CrystalClick::WidePart.open_typed(path, "payload")
        expect_raises(CrystalClick::CorruptPartError) do
          reader.read_map_string_array_uint64_mark_range("payload", 2, 1)
        end
      end
    end
  end

  it "rejects a size1 count that disagrees with the per-mark UInt64 payload" do
    with_w63_reader_part do |path|
      # First entry is an empty Array; changing its size from zero to one keeps
      # the offset frame valid but contradicts the fixed-width value bytes.
      w63_reader_rewrite_first_size1(path, 1_u64)
      reader = CrystalClick::WidePart.open_typed(path, "payload")
      error = expect_raises(CrystalClick::CorruptPartError) do
        reader.read_map_string_array_uint64_mark_range("payload", 0, 1)
      end
      error.to_s.should contain("mark range byte count mismatch")
    end
  end
end
