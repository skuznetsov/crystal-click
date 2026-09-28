require "./spec_helper"

private def w69_raw_stream(path : String, stream : String) : Array(UInt8)
  encoded = File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
  CrystalClick::CompressedBlock.decode_all(encoded).to_a
end

private def w69_raw_u64_stream(path : String, stream : String) : Array(UInt64)
  bytes = w69_raw_stream(path, stream)
  raise "W69 UInt64 stream is not aligned: #{stream}" unless bytes.size % 8 == 0
  Array(UInt64).new(bytes.size // 8) do |index|
    offset = index * 8
    value = 0_u64
    8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
    value
  end
end

private def w69_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

private def w69_mark_records(path : String, stream : String) : Array(Tuple(UInt64, UInt64, UInt64))
  bytes = File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")).to_slice
  raise "W69 mark file is malformed: #{stream}" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(Tuple(UInt64, UInt64, UInt64)).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE
    {
      w69_read_u64(bytes, offset),
      w69_read_u64(bytes, offset + 8),
      w69_read_u64(bytes, offset + 16),
    }
  end
end

private def w69_assert_marks(
  path : String,
  stream : String,
  raw_mark_sizes : Array(Int32),
  expected_rows : Array(UInt64),
) : Nil
  marks = w69_mark_records(path, stream)
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
  it "writes exact Map(UInt64, Array(Nullable(UInt64))) streams and preserves nested distinctions" do
    parent = File.tempname("crystal-click-wide-writer-w69")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [0_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64]
    values = [
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

    begin
      CrystalClick::WidePartWriter.write_uint64_map_uint64_array_nullable_uint64_pair(
        destination,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "payload",
        values.to_unsafe.to_slice(values.size),
        rows_per_mark: 2
      ).should eq(destination)

      File.read(File.join(destination, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` Map(UInt64, Array(Nullable(UInt64)))\n"
      )
      File.read(File.join(destination, "columns_substreams.txt")).should eq(
        "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n" +
        "5 substreams for column `payload`:\n\tpayload.size0\n\tpayload%2Ekeys\n" +
        "\tpayload%2Evalues.size1\n\tpayload%2Evalues.null\n\tpayload%2Evalues\n"
      )
      File.read(File.join(destination, "serialization.json")).should eq(
        %({"columns":[],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
      )
      File.read(File.join(destination, "default_compression_codec.txt")).should eq("CODEC(LZ4)")
      File.read(File.join(destination, "count.txt")).should eq(keys.size.to_s)

      flattened_entries = values.flatten
      flattened_entries.map(&.[0]).should eq([7_u64, 7_u64, UInt64::MAX, 0_u64, 1_u64, 3_u64, UInt64::MAX, 4_u64, 9_u64])
      w69_raw_u64_stream(destination, "payload.size0").should eq([0_u64, 2_u64, 2_u64, 1_u64, 2_u64, 1_u64, 1_u64])
      w69_raw_u64_stream(destination, "payload%2Ekeys").should eq([7_u64, 7_u64, UInt64::MAX, 0_u64, 1_u64, 3_u64, UInt64::MAX, 4_u64, 9_u64])
      w69_raw_u64_stream(destination, "payload%2Evalues.size1").should eq([2_u64, 0_u64, 2_u64, 0_u64, 0_u64, 2_u64, 0_u64, 2_u64, 1_u64])
      w69_raw_stream(destination, "payload%2Evalues.null").should eq([1_u8, 0_u8, 0_u8, 1_u8, 1_u8, 1_u8, 1_u8, 1_u8, 0_u8])
      w69_raw_u64_stream(destination, "payload%2Evalues").should eq([0_u64, 0_u64, UInt64::MAX, 0_u64, 0_u64, 0_u64, 0_u64, 0_u64, 7_u64])

      mark_rows = [2_u64, 2_u64, 2_u64, 1_u64]
      {
        {"pk", [16, 16, 16, 8]},
        {"payload.size0", [16, 16, 16, 8]},
        {"payload%2Ekeys", [16, 24, 24, 8]},
        {"payload%2Evalues.size1", [16, 24, 24, 8]},
        {"payload%2Evalues.null", [2, 2, 4, 1]},
        {"payload%2Evalues", [16, 16, 32, 8]},
      }.each do |stream, raw_sizes|
        w69_assert_marks(destination, stream, raw_sizes, mark_rows)
      end

      w69_raw_stream(destination, "payload%2Evalues.null")[0, 2].should eq([1_u8, 0_u8])
      w69_raw_u64_stream(destination, "payload%2Evalues")[0, 2].should eq([0_u64, 0_u64])
      w69_raw_stream(destination, "payload%2Evalues.null")[4, 4].should eq([1_u8, 1_u8, 1_u8, 1_u8])
      w69_raw_u64_stream(destination, "payload%2Evalues")[4, 4].should eq([0_u64, 0_u64, 0_u64, 0_u64])

      reader = CrystalClick::WidePart.open_typed(destination, "payload")
      reader.column_type.should eq("Map(UInt64, Array(Nullable(UInt64)))")
      reader.row_count.should eq(keys.size.to_u64)
      reader.mark_row_counts.should eq(mark_rows)
      reader.read_map_uint64_array_nullable_uint64_mark_range("payload", 0, reader.mark_count).should eq(values)
      reader.read_map_uint64_array_nullable_uint64_mark_range("payload", 2, 1).should eq(values[4, 2])
      reader.read_map_uint64_array_nullable_uint64_mark_range("payload", 3, 1).should eq(values[6, 1])
      reader.read_map_uint64_array_nullable_uint64_mark_range("payload", 2, 2).should eq(values[4, 3])

      expected_files = ["count.txt", "primary.idx", "serialization.json"]
      {"pk", "payload.size0", "payload%2Ekeys", "payload%2Evalues.size1", "payload%2Evalues.null", "payload%2Evalues"}.each do |stream|
        base = CrystalClick::StreamName.hash(stream)
        expected_files << "#{base}.bin"
        expected_files << "#{base}.mrk2"
      end
      checksums = CrystalClick::PartChecksums.open(destination)
      checksums.entries.keys.sort.should eq(expected_files.sort)
      checksums.entries.each_key { |name| checksums.validate_selected_entries(destination, name) }

      original_checksums = File.read(File.join(destination, "checksums.txt"))
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_map_uint64_array_nullable_uint64_pair(
          destination,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "payload",
          values.to_unsafe.to_slice(values.size),
          rows_per_mark: 2
        )
      end
      File.read(File.join(destination, "checksums.txt")).should eq(original_checksums)
      Dir.children(parent).should eq(["part"])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects nested leaf overflow before creating a staged or published part" do
    parent = File.tempname("crystal-click-wide-writer-w69-overflow")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64]
    too_many_values = Array(UInt64?).new((CrystalClick::WidePart::MAX_ARRAY_MARK_ELEMENTS + 1_u64).to_i, nil)
    values = [[{7_u64, too_many_values}] of Tuple(UInt64, Array(UInt64?))] of Array(Tuple(UInt64, Array(UInt64?)))
    begin
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_map_uint64_array_nullable_uint64_pair(
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
    parent = File.tempname("crystal-click-wide-writer-w69-entry-overflow")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64]
    too_many_entries = Array(Tuple(UInt64, Array(UInt64?))).new(
      (CrystalClick::WidePart::MAX_ARRAY_MARK_ELEMENTS + 1_u64).to_i
    ) { {7_u64, [] of UInt64?} }
    values = [too_many_entries] of Array(Tuple(UInt64, Array(UInt64?)))
    begin
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_map_uint64_array_nullable_uint64_pair(
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
