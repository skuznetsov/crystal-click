require "./spec_helper"
require "json"

private def json_typed_writer_u64_bytes(values : Array(UInt64)) : Array(UInt8)
  bytes = Bytes.new(values.size * 8)
  values.each_with_index do |value, index|
    8.times { |offset| bytes[index * 8 + offset] = (value >> (offset * 8)).to_u8 }
  end
  bytes.to_a
end

private def json_typed_writer_u64_at(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

private def json_typed_writer_marks(path : String, logical_name : String) : Array({UInt64, UInt64, UInt64})
  bytes = File.read(File.join(path, "#{CrystalClick::StreamName.hash(logical_name)}.mrk2")).to_slice
  raise "invalid test mark fixture" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array({UInt64, UInt64, UInt64}).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE
    {
      json_typed_writer_u64_at(bytes, offset),
      json_typed_writer_u64_at(bytes, offset + 8),
      json_typed_writer_u64_at(bytes, offset + 16),
    }
  end
end

private def json_typed_writer_expected_frame_offsets(data : Bytes, raw_marks : Array(Array(UInt8))) : Array(UInt64)
  offsets = [] of UInt64
  cursor = 0_i64
  raw_marks.each do |raw|
    offsets << cursor.to_u64
    next if raw.empty?

    frame = CrystalClick::CompressedBlock.decode_frame(
      data,
      cursor,
      CrystalClick::WidePart::MAX_FRAME_COMPRESSED_BYTES.to_i64,
      CrystalClick::WidePart::MAX_FRAME_DECOMPRESSED_BYTES.to_i64
    )
    frame.output.to_a.should eq(raw)
    cursor = frame.end_offset
  end
  offsets << cursor.to_u64
  cursor.should eq(data.size.to_i64)
  offsets
end

describe CrystalClick::WidePartWriter do
  it "writes the declared UInt64 and String JSON typed paths as independent Object V3 streams" do
    parent = File.tempname("crystal-click-wide-writer-json-typed")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [0_u64, 2_u64, 4_u64]
    values = [{7_u64, "x\0y"}, {0_u64, ""}, {9_u64, "last"}]

    begin
      CrystalClick::WidePartWriter.write_uint64_json_typed_a_uint64_b_string_pair(
        destination,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "j",
        values,
        rows_per_mark: 1
      )

      File.read(File.join(destination, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`pk` UInt64\n`j` JSON(a UInt64, b String)\n"
      )
      File.read(File.join(destination, "columns_substreams.txt")).should eq(
        "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n7 substreams for column `j`:\n" +
        "\tj.object_structure\n\tj.a\n\tj.b.size\n\tj.b\n" +
        "\tj.object_shared_data.0.size0\n\tj.object_shared_data.0%2Epaths\n\tj.object_shared_data.0%2Evalues\n"
      )
      File.read(File.join(destination, "count.txt")).should eq("3")
      File.read(File.join(destination, "default_compression_codec.txt")).should eq("CODEC(LZ4)")
      File.read(File.join(destination, "metadata_version.txt")).should eq("0")

      serialization = JSON.parse(File.read(File.join(destination, "serialization.json")))
      serialization["types_serialization_versions"]["string"].as_i.should eq(1)
      serialization["columns"].as_a.size.should eq(1)
      serialization["columns"][0]["name"].as_s.should eq("pk")
      serialization["columns"][0]["num_defaults"].as_i.should eq(1)
      serialization["columns"][0]["num_rows"].as_i.should eq(3)

      logical_names = [
        "pk",
        "j.object_structure",
        "j.a",
        "j.b.size",
        "j.b",
        "j.object_shared_data.0.size0",
        "j.object_shared_data.0%2Epaths",
        "j.object_shared_data.0%2Evalues",
      ]
      stream_bases = logical_names.map { |name| CrystalClick::StreamName.hash(name) }
      stream_bases.uniq.size.should eq(8)

      logical_names.each do |name|
        base = CrystalClick::StreamName.hash(name)
        File.exists?(File.join(destination, "#{base}.bin")).should be_true
        File.exists?(File.join(destination, "#{base}.mrk2")).should be_true
        File.exists?(File.join(destination, "#{base}.cmrk2")).should be_false
      end

      raw_values = values.map(&.[0])
      raw_sizes = values.map { |value| value[1].bytesize.to_u64 }
      raw_b = values.map { |value| value[1].to_slice.to_a }.flatten
      raw_shared_size0 = [0_u64, 0_u64, 0_u64]
      expected_raw = {
        "pk"                              => json_typed_writer_u64_bytes(keys),
        "j.object_structure"              => [0x04_u8, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 0],
        "j.a"                             => json_typed_writer_u64_bytes(raw_values),
        "j.b.size"                        => json_typed_writer_u64_bytes(raw_sizes),
        "j.b"                             => raw_b,
        "j.object_shared_data.0.size0"    => json_typed_writer_u64_bytes(raw_shared_size0),
        "j.object_shared_data.0%2Epaths"  => [] of UInt8,
        "j.object_shared_data.0%2Evalues" => [] of UInt8,
      }

      expected_raw.each do |logical_name, expected|
        data_path = File.join(destination, "#{CrystalClick::StreamName.hash(logical_name)}.bin")
        if logical_name == "j.object_structure"
          CrystalClick::CompressedBlock.decode_all(File.read(data_path).to_slice).to_a.should eq(expected)
        elsif logical_name == "j.object_shared_data.0%2Epaths" || logical_name == "j.object_shared_data.0%2Evalues"
          File.size(data_path).should eq(0_i64)
        else
          CrystalClick::CompressedBlock.decode_all(File.read(data_path).to_slice).to_a.should eq(expected)
        end
      end

      expected_raw_marks = {
        "pk"                           => keys.map { |value| json_typed_writer_u64_bytes([value]) },
        "j.a"                          => raw_values.map { |value| json_typed_writer_u64_bytes([value]) },
        "j.b.size"                     => raw_sizes.map { |value| json_typed_writer_u64_bytes([value]) },
        "j.b"                          => values.map { |value| value[1].to_slice.to_a },
        "j.object_shared_data.0.size0" => raw_shared_size0.map { |value| json_typed_writer_u64_bytes([value]) },
      }
      expected_raw_marks.each do |logical_name, raw_marks|
        data = File.read(File.join(destination, "#{CrystalClick::StreamName.hash(logical_name)}.bin")).to_slice
        marks = json_typed_writer_marks(destination, logical_name)
        marks.size.should eq(4)
        marks.map(&.[2]).should eq([1_u64, 1_u64, 1_u64, 0_u64])
        marks.map(&.[0]).should eq(json_typed_writer_expected_frame_offsets(data, raw_marks))
        marks.each { |mark| mark[1].should eq(0_u64) }
      end

      structure_marks = json_typed_writer_marks(destination, "j.object_structure")
      structure_marks.should eq([{0_u64, 11_u64, 1_u64}, {0_u64, 11_u64, 1_u64}, {0_u64, 11_u64, 1_u64}, {0_u64, 13_u64, 0_u64}])
      {"j.object_shared_data.0%2Epaths", "j.object_shared_data.0%2Evalues"}.each do |logical_name|
        json_typed_writer_marks(destination, logical_name).should eq([
          {0_u64, 0_u64, 1_u64},
          {0_u64, 0_u64, 1_u64},
          {0_u64, 0_u64, 1_u64},
          {0_u64, 0_u64, 0_u64},
        ])
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects invalid names, unequal rows, unsorted keys, and existing destinations before publication" do
    parent = File.tempname("crystal-click-wide-writer-json-typed-invalid")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64]
    values = [{3_u64, "x"}, {4_u64, "y"}]

    begin
      invalid_name = File.join(parent, "invalid-name")
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_json_typed_a_uint64_b_string_pair(
          invalid_name, "pk", keys.to_unsafe.to_slice(keys.size), "j.value", values, rows_per_mark: 1
        )
      end
      File.exists?(invalid_name).should be_false

      unequal_rows = File.join(parent, "unequal-rows")
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_json_typed_a_uint64_b_string_pair(
          unequal_rows, "pk", keys.to_unsafe.to_slice(keys.size), "j", values[0, 1], rows_per_mark: 1
        )
      end
      File.exists?(unequal_rows).should be_false

      unsorted = File.join(parent, "unsorted")
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_json_typed_a_uint64_b_string_pair(
          unsorted, "pk", [2_u64, 1_u64].to_unsafe.to_slice(2), "j", values, rows_per_mark: 1
        )
      end
      File.exists?(unsorted).should be_false

      existing = File.join(parent, "existing")
      Dir.mkdir(existing)
      File.write(File.join(existing, "sentinel"), "preserve")
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_json_typed_a_uint64_b_string_pair(
          existing, "pk", keys.to_unsafe.to_slice(keys.size), "j", values, rows_per_mark: 1
        )
      end
      File.read(File.join(existing, "sentinel")).should eq("preserve")

      oversized_destination = File.join(parent, "oversized-string")
      oversized_string = String.new(Bytes.new(CrystalClick::WidePart::MAX_FRAME_DECOMPRESSED_BYTES + 1, 0x61_u8))
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_json_typed_a_uint64_b_string_pair(
          oversized_destination,
          "pk",
          [1_u64].to_unsafe.to_slice(1),
          "j",
          [{3_u64, oversized_string}],
          rows_per_mark: 1
        )
      end
      File.exists?(oversized_destination).should be_false
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "writes a short final mark when every String typed path is empty" do
    parent = File.tempname("crystal-click-wide-writer-json-typed-empty-string")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64, 2_u64, 3_u64]
    values = [{0_u64, ""}, {0_u64, ""}, {5_u64, ""}]

    begin
      CrystalClick::WidePartWriter.write_uint64_json_typed_a_uint64_b_string_pair(
        destination,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "j",
        values,
        rows_per_mark: 2
      )

      b_data = File.join(destination, "#{CrystalClick::StreamName.hash("j.b")}.bin")
      File.size(b_data).should eq(0_i64)
      b_size_marks = json_typed_writer_marks(destination, "j.b.size")
      b_marks = json_typed_writer_marks(destination, "j.b")
      b_size_data = File.read(File.join(destination, "#{CrystalClick::StreamName.hash("j.b.size")}.bin")).to_slice
      b_size_marks.map(&.[0]).should eq(json_typed_writer_expected_frame_offsets(
        b_size_data,
        [json_typed_writer_u64_bytes([0_u64, 0_u64]), json_typed_writer_u64_bytes([0_u64])]
      ))
      b_size_marks.map(&.[1]).should eq([0_u64, 0_u64, 0_u64])
      b_size_marks.map(&.[2]).should eq([2_u64, 1_u64, 0_u64])
      b_marks.should eq([{0_u64, 0_u64, 2_u64}, {0_u64, 0_u64, 1_u64}, {0_u64, 0_u64, 0_u64}])

      structure_marks = json_typed_writer_marks(destination, "j.object_structure")
      structure_marks.should eq([{0_u64, 11_u64, 2_u64}, {0_u64, 11_u64, 1_u64}, {0_u64, 13_u64, 0_u64}])
      shared_size0 = CrystalClick::CompressedBlock.decode_all(
        File.read(File.join(destination, "#{CrystalClick::StreamName.hash("j.object_shared_data.0.size0")}.bin")).to_slice
      ).to_a
      shared_size0.should eq(json_typed_writer_u64_bytes([0_u64, 0_u64, 0_u64]))
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
