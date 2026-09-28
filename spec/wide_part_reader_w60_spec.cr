require "./spec_helper"

W60_GENERIC_READER_UINT64_FIXTURE = File.expand_path("../test/fixtures/public/wide_array_array_nullable_uint64/part", __DIR__)

private def w60_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def w60_shift_mark_decompressed_offset(path : String, stream : String, mark_index : Int) : Nil
  marks_path = File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  marks = File.read(marks_path).to_slice.dup
  offset = mark_index * CrystalClick::WidePart::MARK_SIZE + 8
  value = 0_u64
  8.times { |byte| value |= marks[offset + byte].to_u64 << (byte * 8) }
  w60_write_u64(marks, offset, value + 1_u64)
  File.write(marks_path, marks)
end

describe CrystalClick::WidePart do
  it "admits the bounded two-level nullable primitive numeric family" do
    {
      "UInt8", "UInt16", "UInt32", "UInt64",
      "Int8", "Int16", "Int32", "Int64",
      "Float32", "Float64",
    }.each do |leaf|
      CrystalClick::WidePart.supports_typed_type?("Array(Array(Nullable(#{leaf})))").should be_true
    end

    {
      "Array(Array(Nullable(FixedString(4))))",
      "Array(Array(Nullable(Decimal32(9))))",
      "Array(Array(Array(Nullable(Int32))))",
      "Array(Array(Nullable(Int32))) trailing",
    }.each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end
  end

  it "reads the existing nested nullable UInt64 fixture through the generic API" do
    expected = [
      [] of Array(UInt64?),
      [[] of UInt64?, [nil, 0_u64, UInt64::MAX] of UInt64?, [] of UInt64?],
      [[42_u64, nil] of UInt64?, [] of UInt64?],
      [] of Array(UInt64?),
      [[nil] of UInt64?, [] of UInt64?],
      [[1_u64, 2_u64, 3_u64] of UInt64?],
      [] of Array(UInt64?),
    ] of Array(Array(UInt64?))

    reader = CrystalClick::WidePart.open_typed(W60_GENERIC_READER_UINT64_FIXTURE, "payload")
    reader.read_array_array_nullable_numeric_mark_range("payload", 0, reader.mark_count, UInt64).should eq(expected)
    reader.read_array_array_nullable_numeric_mark_range("payload", 1, 2, UInt64).should eq(expected[2, 4])
    reader.array_array_nullable_numeric_mark_range_raw_bytes("payload", 0, reader.mark_count).should eq(201_u64)
  end

  it "rejects shifted later-mark boundaries in each W60 physical stream" do
    ["payload.size0", "payload.size1", "payload.null", "payload"].each do |stream|
      parent = File.tempname("crystal-click-w60-mark-corruption")
      Dir.mkdir(parent)
      part_path = File.join(parent, "all_1_1_0")
      FileUtils.cp_r(W60_GENERIC_READER_UINT64_FIXTURE, part_path)
      begin
        w60_shift_mark_decompressed_offset(part_path, stream, 2)
        expect_raises(CrystalClick::CorruptPartError) do
          reader = CrystalClick::WidePart.open_typed(part_path, "payload")
          reader.read_array_array_nullable_numeric_mark_range("payload", 2, 1, UInt64)
        end
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end
end
