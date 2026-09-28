require "./spec_helper"

W63_WRITER_BINARY_KEY = String.new(Bytes[0x41_u8, 0_u8, 0x42_u8, 0xff_u8])
W63_WRITER_KEYS       = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64, 15_u64, 17_u64]
W63_WRITER_VALUES     = [
  [] of Tuple(String, Array(UInt64)),
  [
    {"dup", [] of UInt64},
    {"dup", [0_u64, UInt64::MAX] of UInt64},
    {W63_WRITER_BINARY_KEY, [42_u64, 42_u64] of UInt64},
  ] of Tuple(String, Array(UInt64)),
  [] of Tuple(String, Array(UInt64)),
  [] of Tuple(String, Array(UInt64)),
  [{"empty", [] of UInt64}] of Tuple(String, Array(UInt64)),
  [{"雪", [7_u64] of UInt64}] of Tuple(String, Array(UInt64)),
  [] of Tuple(String, Array(UInt64)),
  [{"tail", [9_u64, 9_u64] of UInt64}] of Tuple(String, Array(UInt64)),
  [{"last", [] of UInt64}] of Tuple(String, Array(UInt64)),
] of Array(Tuple(String, Array(UInt64)))

private def w63_writer_raw_stream(path : String, stream : String) : Array(UInt8)
  encoded = File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
  CrystalClick::CompressedBlock.decode_all(encoded).to_a
end

private def w63_writer_raw_u64_stream(path : String, stream : String) : Array(UInt64)
  bytes = w63_writer_raw_stream(path, stream)
  raise "W63 writer UInt64 stream is not aligned: #{stream}" unless bytes.size % 8 == 0
  Array(UInt64).new(bytes.size // 8) do |index|
    offset = index * 8
    value = 0_u64
    8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
    value
  end
end

private def w63_writer_string_bytes(values : Array(String)) : Array(UInt8)
  bytes = [] of UInt8
  values.each { |value| value.to_slice.each { |byte| bytes << byte } }
  bytes
end

private def w63_writer_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

private def w63_writer_marks(path : String, stream : String) : Array(Tuple(UInt64, UInt64, UInt64))
  bytes = File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")).to_slice
  raise "W63 writer mark file is malformed: #{stream}" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(Tuple(UInt64, UInt64, UInt64)).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE
    {
      w63_writer_read_u64(bytes, offset),
      w63_writer_read_u64(bytes, offset + 8),
      w63_writer_read_u64(bytes, offset + 16),
    }
  end
end

private def w63_writer_assert_marks(
  path : String,
  stream : String,
  raw_mark_sizes : Array(Int32),
  row_count : Int32,
  rows_per_mark : Int32,
) : Nil
  marks = w63_writer_marks(path, stream)
  marks.size.should eq(raw_mark_sizes.size + 1)
  expected_rows = [] of UInt64
  start_row = 0
  while start_row < row_count
    rows = {rows_per_mark, row_count - start_row}.min
    expected_rows << rows.to_u64
    start_row += rows
  end
  marks.map(&.[2]).should eq(expected_rows + [0_u64])

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
  marks.last[0].should eq(compressed_offset.to_u64)
  marks.last[1].should eq(0_u64)
  marks.last[2].should eq(0_u64)
  compressed_offset.should eq(encoded.size.to_i64)
  nil
end

describe "W63 String-key Map of UInt64 Arrays writer" do
  it "writes ordered Map entries, both offset levels, exact metadata, and independent marks" do
    parent = File.tempname("crystal-click-w63-map-array-writer")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    begin
      CrystalClick::WidePartWriter.write_uint64_map_string_array_uint64_pair(
        destination,
        "pk",
        W63_WRITER_KEYS.to_unsafe.to_slice(W63_WRITER_KEYS.size),
        "payload",
        W63_WRITER_VALUES.to_unsafe.to_slice(W63_WRITER_VALUES.size),
        rows_per_mark: 2
      ).should eq(destination)

      File.read(File.join(destination, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` Map(String, Array(UInt64))\n"
      )
      File.read(File.join(destination, "columns_substreams.txt")).should eq(
        "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n" +
        "5 substreams for column `payload`:\n\tpayload.size0\n\tpayload%2Ekeys.size\n\tpayload%2Ekeys\n" +
        "\tpayload%2Evalues.size1\n\tpayload%2Evalues\n"
      )
      File.read(File.join(destination, "serialization.json")).should eq(
        %({"columns":[],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
      )
      File.read(File.join(destination, "default_compression_codec.txt")).should eq("CODEC(LZ4)")
      File.read(File.join(destination, "count.txt")).should eq(W63_WRITER_KEYS.size.to_s)

      flattened_entries = W63_WRITER_VALUES.flatten
      w63_writer_raw_u64_stream(destination, "payload.size0").should eq([0_u64, 3_u64, 0_u64, 0_u64, 1_u64, 1_u64, 0_u64, 1_u64, 1_u64])
      w63_writer_raw_u64_stream(destination, "payload%2Ekeys.size").should eq(
        flattened_entries.map { |entry| entry[0].bytesize.to_u64 }
      )
      w63_writer_raw_stream(destination, "payload%2Ekeys").should eq(
        w63_writer_string_bytes(flattened_entries.map(&.[0]))
      )
      w63_writer_raw_u64_stream(destination, "payload%2Evalues.size1").should eq(
        flattened_entries.map { |entry| entry[1].size.to_u64 }
      )
      w63_writer_raw_u64_stream(destination, "payload%2Evalues").should eq(
        flattened_entries.flat_map(&.[1])
      )

      streams_and_mark_sizes = {
        {"pk", [16, 16, 16, 16, 8]},
        {"payload.size0", [16, 16, 16, 16, 8]},
        {"payload%2Ekeys.size", [24, 0, 16, 8, 8]},
        {"payload%2Ekeys", [10, 0, 8, 4, 4]},
        {"payload%2Evalues.size1", [24, 0, 16, 8, 8]},
        {"payload%2Evalues", [32, 0, 8, 16, 0]},
      }
      streams_and_mark_sizes.each do |stream, mark_sizes|
        w63_writer_assert_marks(destination, stream, mark_sizes, W63_WRITER_KEYS.size, 2)
      end

      expected_files = ["count.txt", "primary.idx", "serialization.json"]
      {"pk", "payload.size0", "payload%2Ekeys.size", "payload%2Ekeys", "payload%2Evalues.size1", "payload%2Evalues"}.each do |stream|
        base = CrystalClick::StreamName.hash(stream)
        expected_files << "#{base}.bin"
        expected_files << "#{base}.mrk2"
      end
      checksums = CrystalClick::PartChecksums.open(destination)
      checksums.entries.keys.sort.should eq(expected_files.sort)
      checksums.entries.each_key { |name| checksums.validate_selected_entries(destination, name) }
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "keeps empty maps and empty arrays as distinct zero-length nested levels" do
    parent = File.tempname("crystal-click-w63-map-array-writer-empty")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64, 2_u64, 3_u64]
    values = [
      [] of Tuple(String, Array(UInt64)),
      [{"empty", [] of UInt64}] of Tuple(String, Array(UInt64)),
      [] of Tuple(String, Array(UInt64)),
    ] of Array(Tuple(String, Array(UInt64)))
    begin
      CrystalClick::WidePartWriter.write_uint64_map_string_array_uint64_pair(
        destination,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "payload",
        values.to_unsafe.to_slice(values.size),
        rows_per_mark: 2
      )

      w63_writer_raw_u64_stream(destination, "payload.size0").should eq([0_u64, 1_u64, 0_u64])
      w63_writer_raw_u64_stream(destination, "payload%2Ekeys.size").should eq([5_u64])
      w63_writer_raw_stream(destination, "payload%2Ekeys").should eq(w63_writer_string_bytes(["empty"]))
      w63_writer_raw_u64_stream(destination, "payload%2Evalues.size1").should eq([0_u64])
      File.size(File.join(destination, "#{CrystalClick::StreamName.hash("payload%2Evalues")}.bin")).should eq(0_i64)
      w63_writer_marks(destination, "payload%2Evalues").map(&.[0]).should eq([0_u64, 0_u64, 0_u64])
      w63_writer_assert_marks(destination, "payload.size0", [16, 8], keys.size, 2)
      w63_writer_assert_marks(destination, "payload%2Ekeys.size", [8, 0], keys.size, 2)
      w63_writer_assert_marks(destination, "payload%2Ekeys", [5, 0], keys.size, 2)
      w63_writer_assert_marks(destination, "payload%2Evalues.size1", [8, 0], keys.size, 2)
      w63_writer_assert_marks(destination, "payload%2Evalues", [0, 0], keys.size, 2)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "writes a leaf Array larger than a small block and preserves an empty middle mark" do
    parent = File.tempname("crystal-click-w63-map-array-writer-large-leaf")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64, 2_u64, 3_u64]
    large_values = Array(UInt64).new(600) { |index| (index * 17).to_u64 }
    values = [
      [{"large", large_values}] of Tuple(String, Array(UInt64)),
      [] of Tuple(String, Array(UInt64)),
      [{"tail", [UInt64::MAX] of UInt64}] of Tuple(String, Array(UInt64)),
    ] of Array(Tuple(String, Array(UInt64)))
    begin
      CrystalClick::WidePartWriter.write_uint64_map_string_array_uint64_pair(
        destination,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "payload",
        values.to_unsafe.to_slice(values.size),
        rows_per_mark: 1
      )

      w63_writer_raw_u64_stream(destination, "payload%2Evalues").should eq(large_values + [UInt64::MAX])
      w63_writer_raw_u64_stream(destination, "payload%2Evalues.size1").should eq([600_u64, 1_u64])
      w63_writer_assert_marks(destination, "payload%2Evalues", [4800, 0, 8], keys.size, 1)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects unsorted keys and per-mark Map or nested Array overflow before publishing" do
    parent = File.tempname("crystal-click-w63-map-array-writer-invalid")
    Dir.mkdir(parent)
    begin
      unsorted_path = File.join(parent, "unsorted")
      one_row = [[{"k", [1_u64]}] of Tuple(String, Array(UInt64))] of Array(Tuple(String, Array(UInt64)))
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_map_string_array_uint64_pair(
          unsorted_path,
          "pk",
          [2_u64, 1_u64].to_unsafe.to_slice(2),
          "payload",
          [one_row[0], one_row[0]].to_unsafe.to_slice(2),
          rows_per_mark: 2
        )
      end

      too_many_entries_path = File.join(parent, "too-many-entries")
      too_many_entries = Array(Tuple(String, Array(UInt64))).new(
        (CrystalClick::WidePart::MAX_ARRAY_MARK_ELEMENTS + 1_u64).to_i
      ) { {"k", [] of UInt64} }
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_map_string_array_uint64_pair(
          too_many_entries_path,
          "pk",
          [1_u64].to_unsafe.to_slice(1),
          "payload",
          [too_many_entries].to_unsafe.to_slice(1),
          rows_per_mark: 1
        )
      end

      too_many_values_path = File.join(parent, "too-many-values")
      too_many_values = Array(UInt64).new((CrystalClick::WidePart::MAX_ARRAY_MARK_ELEMENTS + 1_u64).to_i, 7_u64)
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_map_string_array_uint64_pair(
          too_many_values_path,
          "pk",
          [1_u64].to_unsafe.to_slice(1),
          "payload",
          [[{"k", too_many_values}] of Tuple(String, Array(UInt64))].to_unsafe.to_slice(1),
          rows_per_mark: 1
        )
      end

      too_many_key_bytes_path = File.join(parent, "too-many-key-bytes")
      too_many_key_bytes = String.new(Bytes.new((CrystalClick::WidePart::MAX_ARRAY_MARK_BYTES + 1).to_i, 0x61_u8))
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_map_string_array_uint64_pair(
          too_many_key_bytes_path,
          "pk",
          [1_u64].to_unsafe.to_slice(1),
          "payload",
          [[{too_many_key_bytes, [] of UInt64}] of Tuple(String, Array(UInt64))].to_unsafe.to_slice(1),
          rows_per_mark: 1
        )
      end

      Dir.children(parent).should eq([] of String)
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
