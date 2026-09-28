require "./spec_helper"
require "file_utils"

W68_READER_KEYS   = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64]
W68_READER_VALUES = [
  [] of Tuple(String, Array(UInt64?)),
  [
    {"dup", [nil, 0_u64] of UInt64?},
    {"dup", [] of UInt64?},
  ] of Tuple(String, Array(UInt64?)),
  [{"empty", [] of UInt64?}] of Tuple(String, Array(UInt64?)),
  [
    {"max", [UInt64::MAX] of UInt64?},
    {"zero!", [0_u64] of UInt64?},
  ] of Tuple(String, Array(UInt64?)),
  [{"all-null", [nil, nil] of UInt64?}] of Tuple(String, Array(UInt64?)),
  [{"null-tail", [nil] of UInt64?}] of Tuple(String, Array(UInt64?)),
  [{"tail", [7_u64] of UInt64?}] of Tuple(String, Array(UInt64?)),
] of Array(Tuple(String, Array(UInt64?)))

W68_READER_STREAMS = [
  "payload.size0",
  "payload%2Ekeys.size",
  "payload%2Ekeys",
  "payload%2Evalues.size1",
  "payload%2Evalues.null",
  "payload%2Evalues",
]

private def with_w68_reader_part(& : String ->)
  parent = File.tempname("crystal-click-w68-reader")
  Dir.mkdir(parent)
  part = File.join(parent, "all_1_1_0")
  begin
    CrystalClick::WidePartWriter.write_uint64_map_string_array_nullable_uint64_pair(
      part,
      "pk",
      W68_READER_KEYS.to_unsafe.to_slice(W68_READER_KEYS.size),
      "payload",
      W68_READER_VALUES.to_unsafe.to_slice(W68_READER_VALUES.size),
      rows_per_mark: 2
    )
    yield part
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def w68_reader_write_u32(bytes : Bytes, offset : Int, value : UInt32) : Nil
  4.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u32).to_u8 }
end

private def w68_reader_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def w68_reader_shift_mark(path : String, stream : String, mark_index : Int) : Nil
  marks_path = File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  marks = File.read(marks_path).to_slice.dup
  offset = mark_index * CrystalClick::WidePart::MARK_SIZE
  raise "W68 selected mark is missing for #{stream}" if offset > marks.size - CrystalClick::WidePart::MARK_SIZE
  compressed_offset = 0_u64
  8.times { |byte| compressed_offset |= marks[offset + byte].to_u64 << (byte * 8) }
  w68_reader_write_u64(marks, offset, compressed_offset + 1_u64)
  File.write(marks_path, marks)
end

private def w68_reader_change_mark_rows(path : String, stream : String, mark_index : Int, rows : UInt64) : Nil
  marks_path = File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  marks = File.read(marks_path).to_slice.dup
  offset = mark_index * CrystalClick::WidePart::MARK_SIZE
  raise "W68 selected mark is missing for #{stream}" if offset > marks.size - CrystalClick::WidePart::MARK_SIZE
  w68_reader_write_u64(marks, offset + 16, rows)
  File.write(marks_path, marks)
end

private def w68_reader_rewrite_first_frame(path : String, stream : String, & : Bytes -> Nil) : Nil
  data_path = File.join(path, "#{CrystalClick::StreamName.hash(stream)}.bin")
  encoded = File.read(data_path).to_slice.dup
  frame = CrystalClick::CompressedBlock.decode_frame(encoded, 0_i64)
  raw = frame.output.dup
  yield raw

  extension_size = raw.size < 15 ? 0 : ((raw.size - 15) // 255) + 1
  payload_size = 1 + extension_size + raw.size
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload_size
  rewritten = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload_size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  rewritten[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  w68_reader_write_u32(rewritten, header + 1, compressed_size.to_u32)
  w68_reader_write_u32(rewritten, header + 5, raw.size.to_u32)
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
  w68_reader_write_u64(rewritten, 0, hash[0])
  w68_reader_write_u64(rewritten, 8, hash[1])
  raise "W68 mutation changed frame size" unless rewritten.size == frame.end_offset
  rewritten.copy_to(encoded.to_unsafe, rewritten.size)
  File.write(data_path, encoded)
end

describe CrystalClick::WidePart do
  it "admits only the exact W68 nullable UInt64 Array Map shape" do
    CrystalClick::WidePart.supports_typed_type?("Map(String, Array(Nullable(UInt64)))").should be_true
    CrystalClick::WidePart.supports_typed_type?("Map(String, Array(UInt64))").should be_true
    {
      "Map(String, Array(Nullable(UInt32)))",
      "Map(UInt64, Array(Nullable(UInt64)))",
      "Map(String, Array(Nullable(Int64)))",
      "Map(String, Array(Array(Nullable(UInt64))))",
      "Map(String, Nullable(Array(UInt64)))",
    }.each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end
  end

  it "reads ordered nested nullable values, preserves duplicates, and preflights every physical slot" do
    with_w68_reader_part do |path|
      reader = CrystalClick::WidePart.open_typed(path, "payload")
      reader.column_type.should eq("Map(String, Array(Nullable(UInt64)))")
      reader.row_count.should eq(7_u64)
      reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
      reader.read_map_string_array_nullable_uint64_mark_range("payload", 0, reader.mark_count).should eq(W68_READER_VALUES)

      # Mark 0 distinguishes NULL from zero and retains duplicate keys; mark 1
      # contains an empty nested Array. Mark 2 is all-NULL and mark 3 is later data.
      reader.read_map_string_array_nullable_uint64_mark_range("payload", 0, 1)
        .should eq(W68_READER_VALUES[0, 2])
      reader.read_map_string_array_nullable_uint64_mark_range("payload", 1, 1)
        .should eq(W68_READER_VALUES[2, 2])
      reader.read_map_string_array_nullable_uint64_mark_range("payload", 2, 1)
        .should eq(W68_READER_VALUES[4, 2])
      reader.read_map_string_array_nullable_uint64_mark_range("payload", 3, 1)
        .should eq(W68_READER_VALUES[6, 1])
      reader.map_string_array_nullable_uint64_mark_range_raw_bytes("payload", 0, reader.mark_count).should eq(112_u64)
      reader.map_string_array_nullable_uint64_mark_range_materialization_preflight("payload", 0, reader.mark_count)
        .should eq({112_u64, 488_u64})
      expect_raises(CrystalClick::BoundsError) do
        reader.read_map_string_array_nullable_uint64_mark_range("payload", 0, 0)
      end
      expect_raises(CrystalClick::BoundsError) do
        reader.read_map_string_array_nullable_uint64_mark_range("payload", reader.mark_count, 1)
      end
    end
  end

  it "consumes the UInt64 slot beneath NULL so an adjacent zero does not shift" do
    with_w68_reader_part do |path|
      # The first hidden slot is deliberately nonzero. The public value remains
      # NULL; the adjacent non-NULL zero must still come from slot 1.
      w68_reader_rewrite_first_frame(path, "payload%2Evalues") do |raw|
        w68_reader_write_u64(raw, 0, UInt64::MAX)
      end
      reader = CrystalClick::WidePart.open_typed(path, "payload")
      reader.read_map_string_array_nullable_uint64_mark_range("payload", 0, 1)
        .should eq(W68_READER_VALUES[0, 2])
    end
  end

  it "rejects shifted boundaries in every W68 stream" do
    W68_READER_STREAMS.each do |stream|
      with_w68_reader_part do |path|
        w68_reader_shift_mark(path, stream, 2)
        reader = CrystalClick::WidePart.open_typed(path, "payload")
        expect_raises(CrystalClick::CorruptPartError) do
          reader.read_map_string_array_nullable_uint64_mark_range("payload", 2, 1)
        end
      end
    end
  end

  it "rejects inconsistent per-mark table-row coordinates in every W68 stream" do
    W68_READER_STREAMS.each do |stream|
      with_w68_reader_part do |path|
        w68_reader_change_mark_rows(path, stream, 2, 3_u64)
        expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::WidePart.open_typed(path, "payload")
        end
      end
    end
  end

  it "rejects non-boolean nullable bytes and nested-size disagreement" do
    with_w68_reader_part do |path|
      w68_reader_rewrite_first_frame(path, "payload%2Evalues.null") { |raw| raw[0] = 2_u8 }
      reader = CrystalClick::WidePart.open_typed(path, "payload")
      error = expect_raises(CrystalClick::CorruptPartError) do
        reader.read_map_string_array_nullable_uint64_mark_range("payload", 0, 1)
      end
      error.to_s.should contain("null-map byte is not boolean")
    end

    with_w68_reader_part do |path|
      w68_reader_rewrite_first_frame(path, "payload%2Evalues.size1") do |raw|
        w68_reader_write_u64(raw, 0, 3_u64)
      end
      reader = CrystalClick::WidePart.open_typed(path, "payload")
      expect_raises(CrystalClick::CorruptPartError) do
        reader.read_map_string_array_nullable_uint64_mark_range("payload", 0, 1)
      end
    end
  end

  it "keeps a selected later mark independent from an earlier invalid null byte" do
    with_w68_reader_part do |path|
      w68_reader_rewrite_first_frame(path, "payload%2Evalues.null") { |raw| raw[0] = 2_u8 }
      reader = CrystalClick::WidePart.open_typed(path, "payload")
      reader.read_map_string_array_nullable_uint64_mark_range("payload", 3, 1)
        .should eq(W68_READER_VALUES[6, 1])
    end
  end

  it "allows empty nested child streams at EOF while retaining a positive mark row" do
    parent = File.tempname("crystal-click-w68-reader-empty-eof")
    Dir.mkdir(parent)
    part = File.join(parent, "empty_eof")
    keys = [1_u64, 2_u64]
    values = [
      [{"empty-array", [] of UInt64?}] of Tuple(String, Array(UInt64?)),
      [] of Tuple(String, Array(UInt64?)),
    ] of Array(Tuple(String, Array(UInt64?)))
    begin
      CrystalClick::WidePartWriter.write_uint64_map_string_array_nullable_uint64_pair(
        part,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "payload",
        values.to_unsafe.to_slice(values.size),
        rows_per_mark: 1
      )
      reader = CrystalClick::WidePart.open_typed(part, "payload")
      reader.mark_row_counts.should eq([1_u64, 1_u64])
      reader.read_map_string_array_nullable_uint64_mark_range("payload", 0, 2).should eq(values)
      reader.read_map_string_array_nullable_uint64_mark_range("payload", 1, 1).should eq([values[1]])
      reader.map_string_array_nullable_uint64_mark_range_materialization_preflight("payload", 1, 1)
        .should eq({0_u64, 8_u64})
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
