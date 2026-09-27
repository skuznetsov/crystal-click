require "./spec_helper"

private def w25_writer_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

private def w25_writer_decoded_u64(path : String, stream : String) : Array(UInt64)
  bytes = CrystalClick::CompressedBlock.decode_all(
    File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
  )
  raise "W25 writer stream is not UInt64-aligned: #{stream}" unless bytes.size % 8 == 0
  Array(UInt64).new(bytes.size // 8) { |index| w25_writer_u64(bytes, index * 8) }
end

private def w25_writer_mark_values(path : String, stream : String) : Array(Tuple(UInt64, UInt64, UInt64))
  bytes = File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")).to_slice
  raise "W25 writer mark file is malformed: #{stream}" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(Tuple(UInt64, UInt64, UInt64)).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    base = index * CrystalClick::WidePart::MARK_SIZE
    {
      w25_writer_u64(bytes, base),
      w25_writer_u64(bytes, base + 8),
      w25_writer_u64(bytes, base + 16),
    }
  end
end

private def w25_writer_compressed_offsets(path : String, stream : String, raw_mark_sizes : Array(Int32)) : Array(UInt64)
  bytes = File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
  offsets = Array(UInt64).new(raw_mark_sizes.size + 1)
  compressed_offset = 0_i64
  raw_mark_sizes.each do |raw_size|
    offsets << compressed_offset.to_u64
    next if raw_size == 0
    frame = CrystalClick::CompressedBlock.decode_frame(
      bytes,
      compressed_offset,
      CrystalClick::WidePartWriter::MAX_FRAME_COMPRESSED.to_i64,
      CrystalClick::WidePartWriter::MAX_FRAME_RAW_BYTES.to_i64
    )
    raise "W25 writer frame raw size differs: #{stream}" unless frame.output.size == raw_size
    compressed_offset = frame.end_offset
  end
  raise "W25 writer frame boundary differs from file size: #{stream}" unless compressed_offset == bytes.size.to_i64
  offsets << compressed_offset.to_u64
  offsets
end

private def w25_writer_u64_bytes(values : Array(UInt64)) : Array(UInt8)
  bytes = Bytes.new(values.size * 8)
  values.each_with_index do |value, index|
    8.times { |byte| bytes[index * 8 + byte] = (value >> (byte * 8)).to_u8 }
  end
  bytes.to_a
end

describe CrystalClick::WidePartWriter do
  it "writes the exact Wide Map(UInt64, String) substreams, metadata, and adaptive marks" do
    parent = File.tempname("crystal-click-wide-writer-w25-map")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [0_u64, 2_u64, 2_u64, 4_u64, 9_u64, 11_u64, 13_u64]
    binary = String.new(Bytes[0x61_u8, 0_u8, 0x62_u8])
    invalid_utf8 = String.new(Bytes[0xff_u8, 0_u8])
    values = [
      [] of Tuple(UInt64, String),
      [{3_u64, "a"}, {3_u64, ""}],
      [{0_u64, binary}, {UInt64::MAX, "é"}],
      [{42_u64, ""}],
      [] of Tuple(UInt64, String),
      [{6_u64, "tail"}],
      [{5_u64, invalid_utf8}],
    ] of Array(Tuple(UInt64, String))

    begin
      CrystalClick::WidePartWriter.write_uint64_map_uint64_string_pair(
        destination,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "m",
        values.to_unsafe.to_slice(values.size),
        rows_per_mark: 2
      ).should eq(destination)

      CrystalClick::WidePart.open_typed(destination, "m")
        .read_map_uint64_string_mark_range("m", 0, 4).should eq(values)

      File.read(File.join(destination, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`pk` UInt64\n`m` Map(UInt64, String)\n"
      )
      File.read(File.join(destination, "columns_substreams.txt")).should eq(
        "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n4 substreams for column `m`:\n\tm.size0\n\tm%2Ekeys\n\tm%2Evalues.size\n\tm%2Evalues\n"
      )
      File.read(File.join(destination, "serialization.json")).should eq(
        %({"columns":[],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
      )
      File.read(File.join(destination, "default_compression_codec.txt")).should eq("CODEC(LZ4)")

      flattened = values.flatten
      w25_writer_decoded_u64(destination, "m.size0").should eq([0_u64, 2_u64, 2_u64, 1_u64, 0_u64, 1_u64, 1_u64])
      w25_writer_decoded_u64(destination, "m%2Ekeys").should eq(flattened.map(&.[0]))
      w25_writer_decoded_u64(destination, "m%2Evalues.size").should eq(flattened.map { |entry| entry[1].bytesize.to_u64 })
      CrystalClick::CompressedBlock.decode_all(
        File.read(File.join(destination, "#{CrystalClick::StreamName.hash("m%2Evalues")}.bin")).to_slice
      ).to_a.should eq(flattened.map { |entry| entry[1].to_slice.to_a }.flatten)

      expected_rows = [2_u64, 2_u64, 2_u64, 1_u64, 0_u64]
      expected_raw_mark_sizes = {
        "pk"              => [16, 16, 16, 8],
        "m.size0"         => [16, 16, 16, 8],
        "m%2Ekeys"        => [16, 24, 8, 8],
        "m%2Evalues.size" => [16, 24, 8, 8],
        "m%2Evalues"      => [1, 5, 4, 2],
      }
      streams = ["pk", "m.size0", "m%2Ekeys", "m%2Evalues.size", "m%2Evalues"]
      streams.each do |stream|
        marks = w25_writer_mark_values(destination, stream)
        marks.map(&.[2]).should eq(expected_rows)
        marks.map(&.[0]).should eq(w25_writer_compressed_offsets(destination, stream, expected_raw_mark_sizes[stream]))
        marks.map(&.[1]).should eq(Array(UInt64).new(expected_rows.size, 0_u64))
      end

      expected_checksum_files = ["count.txt", "primary.idx", "serialization.json"]
      streams.each do |stream|
        base = CrystalClick::StreamName.hash(stream)
        expected_checksum_files << "#{base}.bin"
        expected_checksum_files << "#{base}.mrk2"
      end
      CrystalClick::PartChecksums.open(destination).entries.keys.sort.should eq(expected_checksum_files.sort)
      expected_stage_files = expected_checksum_files + [
        "checksums.txt",
        "columns.txt",
        "columns_substreams.txt",
        "default_compression_codec.txt",
        "metadata_version.txt",
      ]
      Dir.children(destination).sort.should eq(expected_stage_files.sort)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects malformed inputs before creating staging files or publishing" do
    parent = File.tempname("crystal-click-wide-writer-w25-map-invalid")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    values = [[{1_u64, "x"}], [{2_u64, "y"}]] of Array(Tuple(UInt64, String))

    begin
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_map_uint64_string_pair(
          destination,
          "pk",
          [2_u64, 1_u64].to_unsafe.to_slice(2),
          "m",
          values.to_unsafe.to_slice(values.size),
          rows_per_mark: 1
        )
      end
      Dir.children(parent).should eq([] of String)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "writes all-empty maps and maps containing only empty strings without fake data frames" do
    parent = File.tempname("crystal-click-wide-writer-w25-map-empty")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64, 3_u64]
    empty_maps = [
      [] of Tuple(UInt64, String),
      [] of Tuple(UInt64, String),
      [] of Tuple(UInt64, String),
    ]
    empty_map_destination = File.join(parent, "empty-maps")
    empty_string_maps = [
      [{0_u64, ""}],
      [{1_u64, ""}, {1_u64, ""}],
      [] of Tuple(UInt64, String),
    ] of Array(Tuple(UInt64, String))
    empty_string_destination = File.join(parent, "empty-strings")

    begin
      CrystalClick::WidePartWriter.write_uint64_map_uint64_string_pair(
        empty_map_destination,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "m",
        empty_maps.to_unsafe.to_slice(empty_maps.size),
        rows_per_mark: 1
      )
      w25_writer_decoded_u64(empty_map_destination, "m.size0").should eq([0_u64, 0_u64, 0_u64])
      ["m%2Ekeys", "m%2Evalues.size", "m%2Evalues"].each do |stream|
        File.size(File.join(empty_map_destination, "#{CrystalClick::StreamName.hash(stream)}.bin")).should eq(0_i64)
        w25_writer_mark_values(empty_map_destination, stream).map(&.[0]).should eq([0_u64, 0_u64, 0_u64, 0_u64])
      end
      w25_writer_mark_values(empty_map_destination, "m.size0").map(&.[2]).should eq([1_u64, 1_u64, 1_u64, 0_u64])

      CrystalClick::WidePartWriter.write_uint64_map_uint64_string_pair(
        empty_string_destination,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "m",
        empty_string_maps.to_unsafe.to_slice(empty_string_maps.size),
        rows_per_mark: 1
      )
      w25_writer_decoded_u64(empty_string_destination, "m.size0").should eq([1_u64, 2_u64, 0_u64])
      w25_writer_decoded_u64(empty_string_destination, "m%2Ekeys").should eq([0_u64, 1_u64, 1_u64])
      w25_writer_decoded_u64(empty_string_destination, "m%2Evalues.size").should eq([0_u64, 0_u64, 0_u64])
      File.size(File.join(empty_string_destination, "#{CrystalClick::StreamName.hash("m%2Evalues")}.bin")).should eq(0_i64)
      w25_writer_mark_values(empty_string_destination, "m%2Evalues").map(&.[0]).should eq([0_u64, 0_u64, 0_u64, 0_u64])
      w25_writer_mark_values(empty_string_destination, "m%2Evalues").map(&.[2]).should eq([1_u64, 1_u64, 1_u64, 0_u64])
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
