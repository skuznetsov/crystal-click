require "./spec_helper"

private def w26_writer_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

private def w26_writer_decoded_u64(path : String, stream : String) : Array(UInt64)
  bytes = CrystalClick::CompressedBlock.decode_all(
    File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
  )
  raise "W26 stream is not UInt64 aligned" unless bytes.size % 8 == 0
  Array(UInt64).new(bytes.size // 8) { |index| w26_writer_u64(bytes, index * 8) }
end

private def w26_writer_marks(path : String, stream : String) : Array(Tuple(UInt64, UInt64, UInt64))
  bytes = File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")).to_slice
  raise "W26 mark file is malformed" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(Tuple(UInt64, UInt64, UInt64)).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE
    {w26_writer_u64(bytes, offset), w26_writer_u64(bytes, offset + 8), w26_writer_u64(bytes, offset + 16)}
  end
end

describe CrystalClick::WidePartWriter do
  it "writes only the three exact Map(UInt64, UInt64) substreams and independently marked values" do
    parent = File.tempname("crystal-click-wide-writer-w26-map")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [0_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64]
    maps = [
      [] of Tuple(UInt64, UInt64),
      [{3_u64, 0_u64}, {3_u64, UInt64::MAX}],
      [{0_u64, 0_u64}, {UInt64::MAX, 42_u64}],
      [{42_u64, UInt64::MAX}],
      [] of Tuple(UInt64, UInt64),
      [{6_u64, 8_u64}, {1_u64, 9_u64}],
      [{5_u64, 5_u64}],
    ] of Array(Tuple(UInt64, UInt64))
    begin
      CrystalClick::WidePartWriter.write_uint64_map_uint64_uint64_pair(
        destination,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "m",
        maps.to_unsafe.to_slice(maps.size),
        rows_per_mark: 2
      ).should eq(destination)

      CrystalClick::WidePart.open_typed(destination, "m").read_map_uint64_uint64_mark_range("m", 0, 4).should eq(maps)
      File.read(File.join(destination, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`pk` UInt64\n`m` Map(UInt64, UInt64)\n"
      )
      File.read(File.join(destination, "columns_substreams.txt")).should eq(
        "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n3 substreams for column `m`:\n\tm.size0\n\tm%2Ekeys\n\tm%2Evalues\n"
      )
      File.read(File.join(destination, "serialization.json")).should eq(
        %({"columns":[],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
      )
      w26_writer_decoded_u64(destination, "m.size0").should eq([0_u64, 2_u64, 2_u64, 1_u64, 0_u64, 2_u64, 1_u64])
      w26_writer_decoded_u64(destination, "m%2Ekeys").should eq(maps.flatten.map(&.[0]))
      w26_writer_decoded_u64(destination, "m%2Evalues").should eq(maps.flatten.map(&.[1]))
      ["pk", "m.size0", "m%2Ekeys", "m%2Evalues"].each do |stream|
        w26_writer_marks(destination, stream).map(&.[2]).should eq([2_u64, 2_u64, 2_u64, 1_u64, 0_u64])
        w26_writer_marks(destination, stream).map(&.[1]).should eq([0_u64, 0_u64, 0_u64, 0_u64, 0_u64])
      end
      expected_files = ["count.txt", "primary.idx", "serialization.json"]
      ["pk", "m.size0", "m%2Ekeys", "m%2Evalues"].each do |stream|
        base = CrystalClick::StreamName.hash(stream)
        expected_files << "#{base}.bin"
        expected_files << "#{base}.mrk2"
      end
      CrystalClick::PartChecksums.open(destination).entries.keys.sort.should eq(expected_files.sort)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects unsorted keys without publishing a part" do
    parent = File.tempname("crystal-click-wide-writer-w26-map-invalid")
    Dir.mkdir(parent)
    begin
      destination = File.join(parent, "part")
      maps = [[{1_u64, 2_u64}], [{3_u64, 4_u64}]] of Array(Tuple(UInt64, UInt64))
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_map_uint64_uint64_pair(
          destination,
          "pk",
          [2_u64, 1_u64].to_unsafe.to_slice(2),
          "m",
          maps.to_unsafe.to_slice(2),
          rows_per_mark: 1
        )
      end
      Dir.children(parent).should eq([] of String)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "writes all-empty maps with zero-byte child streams" do
    parent = File.tempname("crystal-click-wide-writer-w26-map-empty")
    Dir.mkdir(parent)
    begin
      destination = File.join(parent, "part")
      keys = [1_u64, 2_u64, 3_u64]
      maps = [
        [] of Tuple(UInt64, UInt64),
        [] of Tuple(UInt64, UInt64),
        [] of Tuple(UInt64, UInt64),
      ]
      CrystalClick::WidePartWriter.write_uint64_map_uint64_uint64_pair(
        destination,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "m",
        maps.to_unsafe.to_slice(maps.size),
        rows_per_mark: 1
      )
      w26_writer_decoded_u64(destination, "m.size0").should eq([0_u64, 0_u64, 0_u64])
      ["m%2Ekeys", "m%2Evalues"].each do |stream|
        File.size(File.join(destination, "#{CrystalClick::StreamName.hash(stream)}.bin")).should eq(0_i64)
        w26_writer_marks(destination, stream).map(&.[0]).should eq([0_u64, 0_u64, 0_u64, 0_u64])
      end
      CrystalClick::WidePart.open_typed(destination, "m").read_map_uint64_uint64_mark_range("m", 0, 3).should eq(maps)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "keeps child marks aligned across an empty middle granule" do
    parent = File.tempname("crystal-click-wide-writer-w26-map-middle-empty")
    Dir.mkdir(parent)
    begin
      destination = File.join(parent, "part")
      keys = [1_u64, 2_u64, 3_u64]
      maps = [
        [{7_u64, 8_u64}],
        [] of Tuple(UInt64, UInt64),
        [{9_u64, 10_u64}],
      ]
      CrystalClick::WidePartWriter.write_uint64_map_uint64_uint64_pair(
        destination, "pk", keys.to_unsafe.to_slice(keys.size), "m",
        maps.to_unsafe.to_slice(maps.size), rows_per_mark: 1
      )
      ["m%2Ekeys", "m%2Evalues"].each do |stream|
        offsets = w26_writer_marks(destination, stream).map(&.[0])
        offsets[1].should eq(offsets[2])
        offsets[0].should be < offsets[1]
        offsets[2].should be < offsets[3]
      end
      reader = CrystalClick::WidePart.open_typed(destination, "m")
      reader.read_map_uint64_uint64_mark_range("m", 0, 3).should eq(maps)
      reader.read_map_uint64_uint64_mark_range("m", 1, 1).should eq(maps[1, 1])
      reader.read_map_uint64_uint64_mark_range("m", 2, 1).should eq(maps[2, 1])
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
