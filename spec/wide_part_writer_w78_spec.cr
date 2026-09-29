require "./spec_helper"

W78_WRITER_KEYS = [0_u64, 1_u64, 2_u64, 3_u64, 4_u64, 5_u64]

W78_WRITER_INT8_VALUES = [
  [] of Tuple(UInt64, Array(Int8)),
  [
    {3_u64, [] of Int8},
    {3_u64, [-128_i8, 127_i8] of Int8},
  ] of Tuple(UInt64, Array(Int8)),
  [
    {7_u64, [0_i8, -1_i8] of Int8},
    {9_u64, [42_i8] of Int8},
  ] of Tuple(UInt64, Array(Int8)),
  [] of Tuple(UInt64, Array(Int8)),
  [] of Tuple(UInt64, Array(Int8)),
  [] of Tuple(UInt64, Array(Int8)),
] of Array(Tuple(UInt64, Array(Int8)))

W78_WRITER_FLOAT64_NAN    = 0x7ff8_0000_0000_0042_u64.unsafe_as(Float64)
W78_WRITER_FLOAT64_VALUES = [
  [] of Tuple(String, Array(Float64)),
  [
    {"dup", [] of Float64},
    {"dup", [-0.0_f64, W78_WRITER_FLOAT64_NAN] of Float64},
  ] of Tuple(String, Array(Float64)),
  [
    {"z", [-1.5_f64] of Float64},
    {"", [9.25_f64] of Float64},
  ] of Tuple(String, Array(Float64)),
  [] of Tuple(String, Array(Float64)),
  [] of Tuple(String, Array(Float64)),
  [] of Tuple(String, Array(Float64)),
] of Array(Tuple(String, Array(Float64)))

private def w78_writer_raw_stream(path : String, stream : String) : Array(UInt8)
  encoded = File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
  return [] of UInt8 if encoded.empty?
  CrystalClick::CompressedBlock.decode_all(encoded).to_a
end

private def w78_writer_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

private def w78_writer_marks(path : String, stream : String) : Array(Tuple(UInt64, UInt64, UInt64))
  bytes = File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")).to_slice
  raise "W78 writer mark file is malformed: #{stream}" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(Tuple(UInt64, UInt64, UInt64)).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE
    {
      w78_writer_read_u64(bytes, offset),
      w78_writer_read_u64(bytes, offset + 8),
      w78_writer_read_u64(bytes, offset + 16),
    }
  end
end

private def w78_writer_assert_marks(
  path : String,
  stream : String,
  raw_mark_sizes : Array(Int32),
  mark_rows : Array(UInt64) = [2_u64, 2_u64, 2_u64],
) : Nil
  marks = w78_writer_marks(path, stream)
  marks.size.should eq(raw_mark_sizes.size + 1)
  marks.map(&.[2]).should eq(mark_rows + [0_u64])

  encoded = File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
  compressed_offset = 0_i64
  raw_mark_sizes.each_with_index do |raw_size, index|
    marks[index][0].should eq(compressed_offset.to_u64)
    marks[index][1].should eq(0_u64)
    next if raw_size == 0
    frame = CrystalClick::CompressedBlock.decode_frame(
      encoded,
      compressed_offset,
      CrystalClick::WidePartWriter::MAX_FRAME_COMPRESSED.to_i64,
      CrystalClick::WidePartWriter::MAX_FRAME_RAW_BYTES.to_i64
    )
    frame.output.size.should eq(raw_size)
    compressed_offset = frame.end_offset
  end
  marks.last.should eq({compressed_offset.to_u64, 0_u64, 0_u64})
  compressed_offset.should eq(encoded.size.to_i64)
  nil
end

private def w78_writer_assert_checksums(path : String, streams : Array(String)) : Nil
  expected = ["count.txt", "primary.idx", "serialization.json"]
  streams.each do |stream|
    base = CrystalClick::StreamName.hash(stream)
    expected << "#{base}.bin"
    expected << "#{base}.mrk2"
  end
  checksums = CrystalClick::PartChecksums.open(path)
  checksums.entries.keys.sort.should eq(expected.sort)
  checksums.entries.each_key { |name| checksums.validate_selected_entries(path, name) }
end

describe CrystalClick::WidePartWriter do
  it "writes width-correct signed numeric leaves under UInt64 Map keys with independent empty offsets" do
    parent = File.tempname("crystal-click-w78-map-u64-array-int8-writer")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    begin
      CrystalClick::WidePartWriter.write_uint64_map_uint64_array_numeric_pair(
        destination, "pk", W78_WRITER_KEYS.to_unsafe.to_slice(W78_WRITER_KEYS.size), "payload",
        W78_WRITER_INT8_VALUES.to_unsafe.to_slice(W78_WRITER_INT8_VALUES.size), rows_per_mark: 2
      )

      File.read(File.join(destination, "columns.txt")).should contain("`payload` Map(UInt64, Array(Int8))")
      w78_writer_raw_stream(destination, "payload.size0").should eq([0_u8, 0, 0, 0, 0, 0, 0, 0,
                                                                     2, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0,
                                                                     0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                                                                     0, 0, 0, 0, 0, 0, 0, 0])
      w78_writer_raw_stream(destination, "payload%2Ekeys").should eq([
        3_u8, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0,
        7, 0, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 0, 0, 0, 0,
      ])
      w78_writer_raw_stream(destination, "payload%2Evalues.size1").should eq([
        0_u8, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0,
        2, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0,
      ])
      w78_writer_raw_stream(destination, "payload%2Evalues").should eq([0x80_u8, 0x7f_u8, 0_u8, 0xff_u8, 42_u8])

      {
        {"pk", [16, 16, 16]},
        {"payload.size0", [16, 16, 16]},
        {"payload%2Ekeys", [16, 16, 0]},
        {"payload%2Evalues.size1", [16, 16, 0]},
        {"payload%2Evalues", [2, 3, 0]},
      }.each do |stream, sizes|
        w78_writer_assert_marks(destination, stream, sizes)
      end
      w78_writer_assert_checksums(destination, ["pk", "payload.size0", "payload%2Ekeys", "payload%2Evalues.size1", "payload%2Evalues"])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "writes exact Float64 payload bits under String Map keys and marks the String key-size stream" do
    parent = File.tempname("crystal-click-w78-map-string-array-float64-writer")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    begin
      CrystalClick::WidePartWriter.write_uint64_map_string_array_numeric_pair(
        destination, "pk", W78_WRITER_KEYS.to_unsafe.to_slice(W78_WRITER_KEYS.size), "payload",
        W78_WRITER_FLOAT64_VALUES.to_unsafe.to_slice(W78_WRITER_FLOAT64_VALUES.size), rows_per_mark: 2
      )

      File.read(File.join(destination, "columns.txt")).should contain("`payload` Map(String, Array(Float64))")
      w78_writer_raw_stream(destination, "payload%2Ekeys.size").should eq([
        3_u8, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0,
        1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      ])
      w78_writer_raw_stream(destination, "payload%2Ekeys").should eq("dupdupz".to_slice.to_a)
      w78_writer_raw_stream(destination, "payload%2Evalues.size1").should eq([
        0_u8, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0,
        1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0,
      ])
      value_raw = w78_writer_raw_stream(destination, "payload%2Evalues")
      value_raw.size.should eq(32)
      value_bytes = value_raw.to_unsafe.to_slice(value_raw.size)
      w78_writer_read_u64(value_bytes, 0).should eq(0x8000_0000_0000_0000_u64)
      w78_writer_read_u64(value_bytes, 8).should eq(0x7ff8_0000_0000_0042_u64)
      w78_writer_read_u64(value_bytes, 16).should eq((-1.5_f64).unsafe_as(UInt64))
      w78_writer_read_u64(value_bytes, 24).should eq(9.25_f64.unsafe_as(UInt64))

      {
        {"pk", [16, 16, 16]},
        {"payload.size0", [16, 16, 16]},
        {"payload%2Ekeys.size", [16, 16, 0]},
        {"payload%2Ekeys", [6, 1, 0]},
        {"payload%2Evalues.size1", [16, 16, 0]},
        {"payload%2Evalues", [16, 16, 0]},
      }.each do |stream, sizes|
        w78_writer_assert_marks(destination, stream, sizes)
      end
      w78_writer_assert_checksums(destination, [
        "pk", "payload.size0", "payload%2Ekeys.size", "payload%2Ekeys",
        "payload%2Evalues.size1", "payload%2Evalues",
      ])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects Bool leaves without creating a destination" do
    parent = File.tempname("crystal-click-w78-map-bool-array-writer")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [0_u64]
    values = [[{1_u64, [true, false] of Bool}] of Tuple(UInt64, Array(Bool))]
    begin
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartWriter.write_uint64_map_uint64_array_numeric_pair(
          destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
          values.to_unsafe.to_slice(values.size), rows_per_mark: 1
        )
      end
      File.exists?(destination).should be_false
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "removes its private stage when exclusive publication fails" do
    parent = File.tempname("crystal-click-w78-map-writer-publish-failure")
    Dir.mkdir(parent)
    destination = File.join(parent, "x" * 256)
    keys = [1_u64]
    values = [[{7_u64, [-1_i8, 2_i8] of Int8}] of Tuple(UInt64, Array(Int8))]
    begin
      expect_raises(IO::Error) do
        CrystalClick::WidePartWriter.write_uint64_map_uint64_array_numeric_pair(
          destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
          values.to_unsafe.to_slice(values.size), rows_per_mark: 1
        )
      end
      Dir.children(parent).should be_empty
      File.exists?(destination).should be_false
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
