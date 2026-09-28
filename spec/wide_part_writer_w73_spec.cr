require "./spec_helper"

W73_WRITER_BINARY = String.new(Bytes[0x4b_u8, 0_u8, 0xff_u8])
W73_U64_KEYS      = [0_u64, 1_u64, 2_u64, 3_u64, UInt64::MAX]
W73_EDGE_KEYS     = [1_u64, 2_u64, 3_u64]
W73_U64_VALUES    = [
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

W73_STRING_STRING_VALUES = [
  [] of Tuple(String, Array(String)),
  [
    {"dup", [] of String},
    {"dup", ["", "a\0b"] of String},
    {W73_WRITER_BINARY, ["é"] of String},
  ] of Tuple(String, Array(String)),
  [{"empty-array", [] of String}] of Tuple(String, Array(String)),
  [
    {"雪", ["x", ""] of String},
    {"", ["尾"] of String},
  ] of Tuple(String, Array(String)),
  [{"tail", ["after", ""] of String}] of Tuple(String, Array(String)),
] of Array(Tuple(String, Array(String)))

W73_U64_STRING_VALUES = [
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

W73_ALL_EMPTY_MAPS = [
  [] of Tuple(UInt64, Array(UInt64)),
  [] of Tuple(UInt64, Array(UInt64)),
  [] of Tuple(UInt64, Array(UInt64)),
] of Array(Tuple(UInt64, Array(UInt64)))

W73_MAPS_WITH_EMPTY_ARRAYS = [
  [
    {"dup", [] of String},
    {"dup", [] of String},
  ] of Tuple(String, Array(String)),
  [{"雪", [] of String}] of Tuple(String, Array(String)),
  [{"z", [] of String}] of Tuple(String, Array(String)),
] of Array(Tuple(String, Array(String)))

private def w73_writer_raw_stream(path : String, stream : String) : Array(UInt8)
  encoded = File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
  return [] of UInt8 if encoded.empty?
  CrystalClick::CompressedBlock.decode_all(encoded).to_a
end

private def w73_writer_raw_u64_stream(path : String, stream : String) : Array(UInt64)
  bytes = w73_writer_raw_stream(path, stream)
  raise "W73 writer UInt64 stream is not aligned: #{stream}" unless bytes.size % 8 == 0
  Array(UInt64).new(bytes.size // 8) do |index|
    offset = index * 8
    value = 0_u64
    8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
    value
  end
end

private def w73_writer_string_bytes(values : Array(String)) : Array(UInt8)
  bytes = [] of UInt8
  values.each { |value| value.to_slice.each { |byte| bytes << byte } }
  bytes
end

private def w73_writer_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

private def w73_writer_marks(path : String, stream : String) : Array(Tuple(UInt64, UInt64, UInt64))
  bytes = File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")).to_slice
  raise "W73 writer mark file is malformed: #{stream}" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(Tuple(UInt64, UInt64, UInt64)).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE
    {
      w73_writer_read_u64(bytes, offset),
      w73_writer_read_u64(bytes, offset + 8),
      w73_writer_read_u64(bytes, offset + 16),
    }
  end
end

private def w73_writer_assert_marks(
  path : String,
  stream : String,
  raw_mark_sizes : Array(Int32),
  mark_rows : Array(UInt64) = [2_u64, 2_u64, 1_u64],
) : Nil
  marks = w73_writer_marks(path, stream)
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

private def w73_writer_assert_checksums(path : String, streams : Array(String)) : Nil
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
  it "writes ordered UInt64-key Map entries and nested UInt64 Arrays with independent row, entry, and leaf offsets" do
    parent = File.tempname("crystal-click-w73-map-u64-array-u64-writer")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    begin
      CrystalClick::WidePartWriter.write_uint64_map_uint64_array_uint64_pair(
        destination, "pk", W73_U64_KEYS.to_unsafe.to_slice(W73_U64_KEYS.size), "payload",
        W73_U64_VALUES.to_unsafe.to_slice(W73_U64_VALUES.size), rows_per_mark: 2
      )

      File.read(File.join(destination, "columns.txt")).should contain("`payload` Map(UInt64, Array(UInt64))")
      w73_writer_raw_u64_stream(destination, "payload.size0").should eq([0_u64, 3_u64, 1_u64, 1_u64, 1_u64])
      w73_writer_raw_u64_stream(destination, "payload%2Ekeys").should eq([0_u64, 0_u64, UInt64::MAX, 1_u64, UInt64::MAX, 42_u64])
      w73_writer_raw_u64_stream(destination, "payload%2Evalues.size1").should eq([0_u64, 2_u64, 2_u64, 0_u64, 3_u64, 1_u64])
      w73_writer_raw_u64_stream(destination, "payload%2Evalues").should eq([0_u64, UInt64::MAX, 7_u64, 7_u64, UInt64::MAX, 1_u64, 2_u64, 5_u64])

      { {"pk", [16, 16, 8]}, {"payload.size0", [16, 16, 8]}, {"payload%2Ekeys", [24, 16, 8]},
       {"payload%2Evalues.size1", [24, 16, 8]}, {"payload%2Evalues", [32, 24, 8]} }.each do |stream, sizes|
        w73_writer_assert_marks(destination, stream, sizes)
      end
      w73_writer_assert_checksums(destination, ["pk", "payload.size0", "payload%2Ekeys", "payload%2Evalues.size1", "payload%2Evalues"])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "writes ordered String-key Map entries and nested String Arrays, including binary and empty strings" do
    parent = File.tempname("crystal-click-w73-map-string-array-string-writer")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    begin
      CrystalClick::WidePartWriter.write_uint64_map_string_array_string_pair(
        destination, "pk", W73_U64_KEYS.to_unsafe.to_slice(W73_U64_KEYS.size), "payload",
        W73_STRING_STRING_VALUES.to_unsafe.to_slice(W73_STRING_STRING_VALUES.size), rows_per_mark: 2
      )

      File.read(File.join(destination, "columns.txt")).should contain("`payload` Map(String, Array(String))")
      w73_writer_raw_u64_stream(destination, "payload.size0").should eq([0_u64, 3_u64, 1_u64, 2_u64, 1_u64])
      entries = W73_STRING_STRING_VALUES.flatten
      w73_writer_raw_u64_stream(destination, "payload%2Ekeys.size").should eq(entries.map { |entry| entry[0].bytesize.to_u64 })
      w73_writer_raw_stream(destination, "payload%2Ekeys").should eq(w73_writer_string_bytes(entries.map(&.[0])))
      w73_writer_raw_u64_stream(destination, "payload%2Evalues.size1").should eq(entries.map { |entry| entry[1].size.to_u64 })
      leaves = entries.flat_map(&.[1])
      w73_writer_raw_u64_stream(destination, "payload%2Evalues.size").should eq(leaves.map { |value| value.bytesize.to_u64 })
      w73_writer_raw_stream(destination, "payload%2Evalues").should eq(w73_writer_string_bytes(leaves))

      { {"pk", [16, 16, 8]}, {"payload.size0", [16, 16, 8]}, {"payload%2Ekeys.size", [24, 24, 8]},
       {"payload%2Ekeys", [9, 14, 4]}, {"payload%2Evalues.size1", [24, 24, 8]},
       {"payload%2Evalues.size", [24, 24, 16]}, {"payload%2Evalues", [5, 4, 5]} }.each do |stream, sizes|
        w73_writer_assert_marks(destination, stream, sizes)
      end
      w73_writer_assert_checksums(destination, ["pk", "payload.size0", "payload%2Ekeys.size", "payload%2Ekeys", "payload%2Evalues.size1", "payload%2Evalues.size", "payload%2Evalues"])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "writes ordered UInt64-key Map entries and nested String Arrays with independent entry and leaf cardinalities" do
    parent = File.tempname("crystal-click-w73-map-u64-array-string-writer")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    begin
      CrystalClick::WidePartWriter.write_uint64_map_uint64_array_string_pair(
        destination, "pk", W73_U64_KEYS.to_unsafe.to_slice(W73_U64_KEYS.size), "payload",
        W73_U64_STRING_VALUES.to_unsafe.to_slice(W73_U64_STRING_VALUES.size), rows_per_mark: 2
      )

      File.read(File.join(destination, "columns.txt")).should contain("`payload` Map(UInt64, Array(String))")
      w73_writer_raw_u64_stream(destination, "payload.size0").should eq([0_u64, 3_u64, 1_u64, 2_u64, 1_u64])
      entries = W73_U64_STRING_VALUES.flatten
      w73_writer_raw_u64_stream(destination, "payload%2Ekeys").should eq(entries.map(&.[0]))
      w73_writer_raw_u64_stream(destination, "payload%2Evalues.size1").should eq(entries.map { |entry| entry[1].size.to_u64 })
      leaves = entries.flat_map(&.[1])
      w73_writer_raw_u64_stream(destination, "payload%2Evalues.size").should eq(leaves.map { |value| value.bytesize.to_u64 })
      w73_writer_raw_stream(destination, "payload%2Evalues").should eq(w73_writer_string_bytes(leaves))

      { {"pk", [16, 16, 8]}, {"payload.size0", [16, 16, 8]}, {"payload%2Ekeys", [24, 24, 8]},
       {"payload%2Evalues.size1", [24, 24, 8]}, {"payload%2Evalues.size", [24, 24, 16]},
       {"payload%2Evalues", [5, 4, 4]} }.each do |stream, sizes|
        w73_writer_assert_marks(destination, stream, sizes)
      end
      w73_writer_assert_checksums(destination, ["pk", "payload.size0", "payload%2Ekeys", "payload%2Evalues.size1", "payload%2Evalues.size", "payload%2Evalues"])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "preserves marks and checksums when every nested child stream is empty" do
    parent = File.tempname("crystal-click-w73-map-empty-child-writer")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    begin
      CrystalClick::WidePartWriter.write_uint64_map_uint64_array_uint64_pair(
        destination, "pk", W73_EDGE_KEYS.to_unsafe.to_slice(W73_EDGE_KEYS.size), "payload",
        W73_ALL_EMPTY_MAPS.to_unsafe.to_slice(W73_ALL_EMPTY_MAPS.size), rows_per_mark: 2
      )

      w73_writer_raw_u64_stream(destination, "payload.size0").should eq([0_u64, 0_u64, 0_u64])
      { {"pk", [16, 8]}, {"payload.size0", [16, 8]}, {"payload%2Ekeys", [0, 0]},
       {"payload%2Evalues.size1", [0, 0]}, {"payload%2Evalues", [0, 0]} }.each do |stream, sizes|
        w73_writer_assert_marks(destination, stream, sizes, [2_u64, 1_u64])
      end
      w73_writer_assert_checksums(destination, ["pk", "payload.size0", "payload%2Ekeys", "payload%2Evalues.size1", "payload%2Evalues"])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "preserves nonempty Map entries when all nested Arrays are empty" do
    parent = File.tempname("crystal-click-w73-map-empty-arrays-writer")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    begin
      CrystalClick::WidePartWriter.write_uint64_map_string_array_string_pair(
        destination, "pk", W73_EDGE_KEYS.to_unsafe.to_slice(W73_EDGE_KEYS.size), "payload",
        W73_MAPS_WITH_EMPTY_ARRAYS.to_unsafe.to_slice(W73_MAPS_WITH_EMPTY_ARRAYS.size), rows_per_mark: 2
      )

      w73_writer_raw_u64_stream(destination, "payload.size0").should eq([2_u64, 1_u64, 1_u64])
      entries = W73_MAPS_WITH_EMPTY_ARRAYS.flatten
      w73_writer_raw_u64_stream(destination, "payload%2Ekeys.size").should eq(entries.map { |entry| entry[0].bytesize.to_u64 })
      w73_writer_raw_stream(destination, "payload%2Ekeys").should eq(w73_writer_string_bytes(entries.map(&.[0])))
      w73_writer_raw_u64_stream(destination, "payload%2Evalues.size1").should eq([0_u64, 0_u64, 0_u64, 0_u64])
      w73_writer_raw_u64_stream(destination, "payload%2Evalues.size").should be_empty
      w73_writer_raw_stream(destination, "payload%2Evalues").should be_empty

      { {"pk", [16, 8]}, {"payload.size0", [16, 8]}, {"payload%2Ekeys.size", [24, 8]},
       {"payload%2Ekeys", [9, 1]}, {"payload%2Evalues.size1", [24, 8]},
       {"payload%2Evalues.size", [0, 0]}, {"payload%2Evalues", [0, 0]} }.each do |stream, sizes|
        w73_writer_assert_marks(destination, stream, sizes, [2_u64, 1_u64])
      end
      w73_writer_assert_checksums(destination, ["pk", "payload.size0", "payload%2Ekeys.size", "payload%2Ekeys", "payload%2Evalues.size1", "payload%2Evalues.size", "payload%2Evalues"])
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
