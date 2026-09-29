require "./spec_helper"

private alias W80MapEntries = Array(Tuple(String, UInt64))
private alias W80ArrayOfMaps = Array(W80MapEntries)

private def w80_writer_raw_stream(path : String, stream : String) : Array(UInt8)
  encoded = File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
  return [] of UInt8 if encoded.empty?
  CrystalClick::CompressedBlock.decode_all(encoded).to_a
end

private def w80_writer_u64_bytes(values : Enumerable(UInt64)) : Array(UInt8)
  bytes = [] of UInt8
  values.each do |value|
    8.times { |byte| bytes << ((value >> (byte * 8)) & 0xff_u64).to_u8 }
  end
  bytes
end

private def w80_writer_marks(path : String, stream : String) : Array(Tuple(UInt64, UInt64, UInt64))
  bytes = File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")).to_slice
  raise "W80 mark file is malformed: #{stream}" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(Tuple(UInt64, UInt64, UInt64)).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE
    words = Array(UInt64).new(3) do |word|
      value = 0_u64
      8.times { |byte| value |= bytes[offset + word * 8 + byte].to_u64 << (byte * 8) }
      value
    end
    {words[0], words[1], words[2]}
  end
end

private def w80_writer_assert_stream_frames(
  path : String,
  stream : String,
  expected_chunks : Array(Array(UInt8)),
  expected_rows : Array(UInt64),
) : Nil
  encoded = File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
  marks = w80_writer_marks(path, stream)
  marks.size.should eq(expected_chunks.size + 1)
  marks.map(&.[2]).should eq(expected_rows + [0_u64])

  offset = 0_i64
  expected_chunks.each_with_index do |expected, index|
    marks[index][0].should eq(offset.to_u64)
    marks[index][1].should eq(0_u64)
    unless expected.empty?
      frame = CrystalClick::CompressedBlock.decode_frame(
        encoded,
        offset,
        CrystalClick::WidePartWriter::MAX_FRAME_COMPRESSED.to_i64,
        CrystalClick::WidePartWriter::MAX_FRAME_RAW_BYTES.to_i64
      )
      frame.output.to_a.should eq(expected)
      offset = frame.end_offset
    end
    marks[index + 1][0].should eq(offset.to_u64)
  end
  marks.last.should eq({offset.to_u64, 0_u64, 0_u64})
  offset.should eq(encoded.size.to_i64)
  nil
end

describe "W80 Array(Map(String, UInt64)) writer" do
  it "writes ordered maps through the five exact child streams with outer-row marks" do
    parent = File.tempname("crystal-click-w80-array-map-writer")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [0_u64, 1_u64, 1_u64, 4_u64, UInt64::MAX]
    duplicate_entries = [{"dup", 7_u64}, {"dup", UInt64::MAX}] of Tuple(String, UInt64)
    values = [
      [] of W80MapEntries,
      [([] of Tuple(String, UInt64)), duplicate_entries],
      [[{"", 0_u64}] of Tuple(String, UInt64)],
      [] of W80MapEntries,
      [[{"ключ💥", 42_u64}] of Tuple(String, UInt64)],
    ] of W80ArrayOfMaps
    key_slice = keys.to_unsafe.to_slice(keys.size)
    value_slice = values.to_unsafe.to_slice(values.size)

    begin
      CrystalClick::WidePartWriter.write_uint64_array_map_string_uint64_pair(
        destination, "pk", key_slice, "payload", value_slice, rows_per_mark: 2
      ).should eq(destination)

      File.read(File.join(destination, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` Array(Map(String, UInt64))\n"
      )
      File.read(File.join(destination, "columns_substreams.txt")).should eq(
        "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n" +
        "5 substreams for column `payload`:\n\tpayload.size0\n\tpayload.size1\n" +
        "\tpayload%2Ekeys.size\n\tpayload%2Ekeys\n\tpayload%2Evalues\n"
      )
      File.read(File.join(destination, "serialization.json")).should eq(
        %({"columns":[],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
      )
      File.read(File.join(destination, "default_compression_codec.txt")).should eq("CODEC(LZ4)")
      File.read(File.join(destination, "metadata_version.txt")).should eq("0")
      File.read(File.join(destination, "count.txt")).should eq("5")

      expected_rows = [2_u64, 2_u64, 1_u64]
      w80_writer_assert_stream_frames(destination, "payload.size0", [
        w80_writer_u64_bytes([0_u64, 2_u64]),
        w80_writer_u64_bytes([1_u64, 0_u64]),
        w80_writer_u64_bytes([1_u64]),
      ], expected_rows)
      w80_writer_assert_stream_frames(destination, "payload.size1", [
        w80_writer_u64_bytes([0_u64, 2_u64]),
        w80_writer_u64_bytes([1_u64]),
        w80_writer_u64_bytes([1_u64]),
      ], expected_rows)
      w80_writer_assert_stream_frames(destination, "payload%2Ekeys.size", [
        w80_writer_u64_bytes([3_u64, 3_u64]),
        w80_writer_u64_bytes([0_u64]),
        w80_writer_u64_bytes(["ключ💥".bytesize.to_u64]),
      ], expected_rows)
      w80_writer_assert_stream_frames(destination, "payload%2Ekeys", [
        "dupdup".bytes,
        [] of UInt8,
        "ключ💥".bytes,
      ], expected_rows)
      w80_writer_assert_stream_frames(destination, "payload%2Evalues", [
        w80_writer_u64_bytes([7_u64, UInt64::MAX]),
        w80_writer_u64_bytes([0_u64]),
        w80_writer_u64_bytes([42_u64]),
      ], expected_rows)

      expected_files = ["count.txt", "primary.idx", "serialization.json"]
      ["pk", "payload.size0", "payload.size1", "payload%2Ekeys.size", "payload%2Ekeys", "payload%2Evalues"].each do |stream|
        base = CrystalClick::StreamName.hash(stream)
        expected_files << "#{base}.bin" << "#{base}.mrk2"
      end
      checksums = CrystalClick::PartChecksums.open(destination)
      checksums.entries.keys.sort.should eq(expected_files.sort)
      checksums.entries.each_key { |name| checksums.validate_selected_entries(destination, name) }

      # The raw frame checks above are independent of the reader; this readback
      # additionally exercises the public logical result after stage validation.
      reader = CrystalClick::WidePart.open_typed(destination, "payload")
      reader.column_type.should eq("Array(Map(String, UInt64))")
      reader.read_array_map_string_uint64_mark_range("payload", 0, reader.mark_count).should eq(values)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects mismatched rows and unsorted keys before creating a stage" do
    parent = File.tempname("crystal-click-w80-array-map-invalid")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [2_u64, 1_u64]
    values = [[] of W80MapEntries, [] of W80MapEntries] of W80ArrayOfMaps
    begin
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_array_map_string_uint64_pair(
          destination,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "payload",
          values.to_unsafe.to_slice(values.size),
          rows_per_mark: 1
        )
      end
      Dir.children(parent).should be_empty

      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_array_map_string_uint64_pair(
          destination,
          "pk",
          [1_u64, 2_u64].to_unsafe.to_slice(2),
          "payload",
          values.to_unsafe.to_slice(1),
          rows_per_mark: 1
        )
      end
      Dir.children(parent).should be_empty
      File.exists?(destination).should be_false
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects an over-bound nested cardinality before creating a stage" do
    parent = File.tempname("crystal-click-w80-array-map-bound")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64]
    maps = Array(W80MapEntries).new(CrystalClick::WidePart::MAX_ARRAY_MARK_ELEMENTS.to_i + 1) do
      [] of Tuple(String, UInt64)
    end
    values = [maps] of W80ArrayOfMaps

    begin
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_array_map_string_uint64_pair(
          destination,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "payload",
          values.to_unsafe.to_slice(values.size),
          rows_per_mark: 1
        )
      end
      Dir.children(parent).should be_empty
      File.exists?(destination).should be_false
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "removes the private stage after exclusive publication fails" do
    parent = File.tempname("crystal-click-w80-array-map-publish-failure")
    Dir.mkdir(parent)
    destination = File.join(parent, "x" * 256)
    keys = [1_u64]
    values = [[[{"k", 1_u64}] of Tuple(String, UInt64)]] of W80ArrayOfMaps
    begin
      expect_raises(IO::Error) do
        CrystalClick::WidePartWriter.write_uint64_array_map_string_uint64_pair(
          destination,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "payload",
          values.to_unsafe.to_slice(values.size),
          rows_per_mark: 1
        )
      end
      Dir.children(parent).should be_empty
      File.exists?(destination).should be_false
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
