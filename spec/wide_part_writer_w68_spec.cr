require "./spec_helper"

private def w68_raw_stream(path : String, stream : String) : Array(UInt8)
  encoded = File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
  CrystalClick::CompressedBlock.decode_all(encoded).to_a
end

private def w68_raw_u64_stream(path : String, stream : String) : Array(UInt64)
  bytes = w68_raw_stream(path, stream)
  raise "W68 UInt64 stream is not aligned: #{stream}" unless bytes.size % 8 == 0
  Array(UInt64).new(bytes.size // 8) do |index|
    offset = index * 8
    value = 0_u64
    8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
    value
  end
end

private def w68_string_bytes(values : Array(String)) : Array(UInt8)
  bytes = [] of UInt8
  values.each { |value| value.to_slice.each { |byte| bytes << byte } }
  bytes
end

private def w68_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

private def w68_mark_records(path : String, stream : String) : Array(Tuple(UInt64, UInt64, UInt64))
  bytes = File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")).to_slice
  raise "W68 mark file is malformed: #{stream}" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(Tuple(UInt64, UInt64, UInt64)).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE
    {
      w68_read_u64(bytes, offset),
      w68_read_u64(bytes, offset + 8),
      w68_read_u64(bytes, offset + 16),
    }
  end
end

private def w68_assert_marks(
  path : String,
  stream : String,
  raw_mark_sizes : Array(Int32),
  expected_rows : Array(UInt64),
) : Nil
  marks = w68_mark_records(path, stream)
  marks.size.should eq(raw_mark_sizes.size + 1)
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

describe CrystalClick::WidePartWriter do
  it "writes exact Map(String, Array(Nullable(UInt64))) streams and preserves nested distinctions" do
    parent = File.tempname("crystal-click-wide-writer-w68")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64]
    values = [
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

    begin
      CrystalClick::WidePartWriter.write_uint64_map_string_array_nullable_uint64_pair(
        destination,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "payload",
        values.to_unsafe.to_slice(values.size),
        rows_per_mark: 2
      ).should eq(destination)

      File.read(File.join(destination, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` Map(String, Array(Nullable(UInt64)))\n"
      )
      File.read(File.join(destination, "columns_substreams.txt")).should eq(
        "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n" +
        "6 substreams for column `payload`:\n\tpayload.size0\n\tpayload%2Ekeys.size\n\tpayload%2Ekeys\n" +
        "\tpayload%2Evalues.size1\n\tpayload%2Evalues.null\n\tpayload%2Evalues\n"
      )
      File.read(File.join(destination, "serialization.json")).should eq(
        %({"columns":[],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
      )
      File.read(File.join(destination, "default_compression_codec.txt")).should eq("CODEC(LZ4)")
      File.read(File.join(destination, "count.txt")).should eq(keys.size.to_s)

      entries = values.flatten
      entries.map(&.[0]).should eq(["dup", "dup", "empty", "max", "zero!", "all-null", "null-tail", "tail"])
      w68_raw_u64_stream(destination, "payload.size0").should eq([0_u64, 2_u64, 1_u64, 2_u64, 1_u64, 1_u64, 1_u64])
      w68_raw_u64_stream(destination, "payload%2Ekeys.size").should eq([3_u64, 3_u64, 5_u64, 3_u64, 5_u64, 8_u64, 9_u64, 4_u64])
      w68_raw_stream(destination, "payload%2Ekeys").should eq(w68_string_bytes(["dup", "dup", "empty", "max", "zero!", "all-null", "null-tail", "tail"]))
      w68_raw_u64_stream(destination, "payload%2Evalues.size1").should eq([2_u64, 0_u64, 0_u64, 1_u64, 1_u64, 2_u64, 1_u64, 1_u64])
      w68_raw_stream(destination, "payload%2Evalues.null").should eq([1_u8, 0_u8, 0_u8, 0_u8, 1_u8, 1_u8, 1_u8, 0_u8])
      w68_raw_u64_stream(destination, "payload%2Evalues").should eq([0_u64, 0_u64, UInt64::MAX, 0_u64, 0_u64, 0_u64, 0_u64, 7_u64])

      mark_rows = [2_u64, 2_u64, 2_u64, 1_u64]
      {
        {"pk", [16, 16, 16, 8]},
        {"payload.size0", [16, 16, 16, 8]},
        {"payload%2Ekeys.size", [16, 24, 16, 8]},
        {"payload%2Ekeys", [6, 13, 17, 4]},
        {"payload%2Evalues.size1", [16, 24, 16, 8]},
        {"payload%2Evalues.null", [2, 2, 3, 1]},
        {"payload%2Evalues", [16, 16, 24, 8]},
      }.each do |stream, raw_sizes|
        w68_assert_marks(destination, stream, raw_sizes, mark_rows)
      end

      w68_raw_stream(destination, "payload%2Evalues.null")[4, 3].should eq([1_u8, 1_u8, 1_u8])
      w68_raw_u64_stream(destination, "payload%2Evalues")[4, 3].should eq([0_u64, 0_u64, 0_u64])

      reader = CrystalClick::WidePart.open_typed(destination, "payload")
      reader.column_type.should eq("Map(String, Array(Nullable(UInt64)))")
      reader.row_count.should eq(keys.size.to_u64)
      reader.mark_row_counts.should eq(mark_rows)
      reader.read_map_string_array_nullable_uint64_mark_range("payload", 0, reader.mark_count).should eq(values)

      expected_files = ["count.txt", "primary.idx", "serialization.json"]
      {"pk", "payload.size0", "payload%2Ekeys.size", "payload%2Ekeys", "payload%2Evalues.size1", "payload%2Evalues.null", "payload%2Evalues"}.each do |stream|
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

  it "rejects nested leaf overflow before creating a staged or published part" do
    parent = File.tempname("crystal-click-wide-writer-w68-overflow")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64]
    too_many_values = Array(UInt64?).new((CrystalClick::WidePart::MAX_ARRAY_MARK_ELEMENTS + 1_u64).to_i, nil)
    values = [[{"overflow", too_many_values}] of Tuple(String, Array(UInt64?))] of Array(Tuple(String, Array(UInt64?)))
    begin
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_map_string_array_nullable_uint64_pair(
          destination,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "payload",
          values.to_unsafe.to_slice(values.size),
          rows_per_mark: 1
        )
      end
      Dir.children(parent).should eq([] of String)
      File.exists?(destination).should be_false
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects Map-entry overflow independently before staging" do
    parent = File.tempname("crystal-click-wide-writer-w68-entry-overflow")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64]
    too_many_entries = Array(Tuple(String, Array(UInt64?))).new(
      (CrystalClick::WidePart::MAX_ARRAY_MARK_ELEMENTS + 1_u64).to_i
    ) { {"k", [] of UInt64?} }
    values = [too_many_entries] of Array(Tuple(String, Array(UInt64?)))
    begin
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_map_string_array_nullable_uint64_pair(
          destination,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "payload",
          values.to_unsafe.to_slice(values.size),
          rows_per_mark: 1
        )
      end
      Dir.children(parent).should eq([] of String)
      File.exists?(destination).should be_false
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
