require "./spec_helper"

module CrystalClick::WidePartWriter
  # Hostile-test adapter: production exposes no stage or validation hook.
  def self.w111_test_write_with_hooks(
    destination : String,
    key_name : String,
    keys : Slice(UInt64),
    value_name : String,
    type_name : String,
    level_sizes : Array(Array(UInt64)),
    points : Array(WidePointValue),
    rows_per_mark : Int32,
    stage_factory : Proc(String, String),
    before_validation_hook : Proc(String, Nil),
  ) : String
    write_geo_array_pair_with_hooks(
      destination, key_name, keys, value_name, type_name, level_sizes, points,
      rows_per_mark, stage_factory, before_validation_hook
    )
  end

  def self.w111_stage_factory_for_spec(calls : Array(Int32)) : Proc(String, String)
    ->(parent : String) do
      calls << 1
      stage = File.tempname("crystal-click-geo-array-w111-stage", nil, dir: parent)
      Dir.mkdir(stage)
      stage
    end
  end

  def self.w111_no_op_hook_for_spec : Proc(String, Nil)
    ->(_stage : String) { nil }
  end

  def self.w111_tamper_nested_sizes_and_refresh_for_spec(logical_name : String) : Proc(String, Nil)
    ->(stage : String) do
      checksums = PartChecksums.open(stage)
      data_path = File.join(stage, "#{StreamName.hash(logical_name)}.bin")
      encoded = File.read(data_path).to_slice
      frame = CompressedBlock.decode_frame(
        encoded, 0_i64,
        PartChecksums::MAX_FRAME_COMPRESSED_BYTES,
        PartChecksums::MAX_FRAME_DECOMPRESSED_BYTES
      )
      raw = frame.output.dup
      # Swap the two little-endian size values [1, 2] to [2, 1]. The record
      # and Point totals stay fixed, but the nested topology is no longer the
      # preflighted caller snapshot.
      raw[0] = 2_u8
      raw[8] = 1_u8
      File.write(data_path, StreamEncoding.encode_lz4_frame(raw))
      w111_refresh_checksums_for_spec(stage, checksums)
      nil
    end
  end

  def self.w111_refresh_checksums_for_spec(stage : String, checksums : PartChecksums) : Nil
    records = [] of ChecksumRecord
    checksums.entries.each do |name, entry|
      path = File.join(stage, name)
      encoded = File.read(path).to_slice
      if entry.compressed
        decoded = CompressedBlock.decode_all(
          encoded,
          PartChecksums::MAX_FRAME_COMPRESSED_BYTES,
          PartChecksums::MAX_FRAME_DECOMPRESSED_BYTES,
          PartChecksums::MAX_PAYLOAD_BYTES
        )
        records << ChecksumRecord.new(
          name, encoded.size.to_u64, CityHashV1.file_hash(encoded), true,
          decoded.size.to_u64, CityHashV1.file_hash(decoded)
        )
      else
        records << ChecksumRecord.new(name, encoded.size.to_u64, CityHashV1.file_hash(encoded), false)
      end
    end
    write_checksums(stage, records)
    nil
  end
end

describe "W111 paired Geo Array writer" do
  it "preserves exact nominal declarations, nested sizes, raw Point bits and outer mark rows" do
    parent = File.tempname("crystal-click-geo-array-w111-mixed")
    Dir.mkdir(parent)
    keys = [0_u64, 2_u64, 4_u64]
    values = [
      CrystalClick::WidePointValue.from_bits(0x8000_0000_0000_0000_u64, 0x7ff8_0000_0000_0042_u64),
      CrystalClick::WidePointValue.from_bits(0x3ff0_0000_0000_0000_u64, 0xfff0_0000_0000_0000_u64),
      CrystalClick::WidePointValue.from_bits(1_u64, 0x7ff0_0000_0000_0000_u64),
    ]
    declarations = {
      "LineString"      => [[0_u64, 1_u64, 2_u64]],
      "Ring"            => [[0_u64, 1_u64, 2_u64]],
      "Polygon"         => [[2_u64, 0_u64, 1_u64], [1_u64, 2_u64, 0_u64]],
      "MultiLineString" => [[2_u64, 0_u64, 1_u64], [1_u64, 2_u64, 0_u64]],
      "MultiPolygon"    => [[2_u64, 0_u64, 1_u64], [1_u64, 2_u64, 0_u64], [1_u64, 0_u64, 2_u64]],
    }

    begin
      declarations.each do |type_name, level_sizes|
        destination = File.join(parent, "#{type_name}_1_1_0")
        CrystalClick::WidePartWriter.write_uint64_geo_array_pair(
          destination, "a_key", keys.to_unsafe.to_slice(keys.size), "z_geo", type_name,
          level_sizes, values, rows_per_mark: 2
        ).should eq(destination)

        part = CrystalClick::WidePart.open_typed(destination, "z_geo")
        part.column_type.should eq(type_name)
        part.row_count.should eq(keys.size.to_u64)
        part.mark_row_counts.should eq([2_u64, 1_u64])
        data = part.read_geo_array_mark_range("z_geo", 0, part.mark_count)
        data.type_name.should eq(type_name)
        data.row_count.should eq(keys.size)
        data.point_count.should eq(values.size)
        level_sizes.each_with_index do |expected, level|
          data.topology.sizes(level).should eq(expected)
        end
        values.each_with_index do |expected, index|
          data.point_at(index).same_bits?(expected).should be_true
        end

        key_part = CrystalClick::WidePart.open_typed(destination, "a_key")
        key_part.read_uint64_mark_range("a_key", 0, key_part.mark_count).should eq(keys)
        checksums = CrystalClick::PartChecksums.open(destination)
        CrystalClick::PrimaryKeyIndex.open(destination, part.mark_count, checksums).keys.should eq([0_u64, 4_u64, 4_u64])

        streams = CrystalClick::GeoArrayColumnType.for_type(type_name).not_nil!.physical_streams("z_geo").map(&.[0])
        File.read(File.join(destination, "columns.txt")).should eq(
          "columns format version: 1\n2 columns:\n`a_key` UInt64\n`z_geo` #{type_name}\n"
        )
        File.read(File.join(destination, "columns_substreams.txt")).should eq(
          String.build do |metadata|
            metadata << "columns substreams version: 1\n2 columns:\n"
            metadata << "1 substreams for column `a_key`:\n\ta_key\n"
            metadata << "#{streams.size} substreams for column `z_geo`:\n"
            streams.each { |stream| metadata << "\t#{stream}\n" }
          end
        )
        File.read(File.join(destination, "serialization.json")).should eq(
          "{\"columns\":[{\"kind\":\"Default\",\"name\":\"a_key\",\"num_defaults\":1,\"num_rows\":3}]," +
          "\"propagate_types_serialization_versions_to_nested_types\":true,\"types_serialization_versions\":{\"string\":1},\"version\":1}"
        )
        expected_checksums = ["count.txt", "primary.idx", "serialization.json"] of String
        logical_names = ["a_key"] of String
        logical_names.concat(streams)
        logical_names.each do |logical|
          base = CrystalClick::StreamName.hash(logical)
          expected_checksums << "#{base}.bin"
          expected_checksums << "#{base}.mrk2"
        end
        checksums.entries.keys.sort.should eq(expected_checksums.sort)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "writes legal all-empty values for every exact nominal array depth" do
    parent = File.tempname("crystal-click-geo-array-w111-empty")
    Dir.mkdir(parent)
    keys = [7_u64, 8_u64, 9_u64]
    empty_values = [] of CrystalClick::WidePointValue
    begin
      {
        "LineString"      => [[0_u64, 0_u64, 0_u64]],
        "Ring"            => [[0_u64, 0_u64, 0_u64]],
        "Polygon"         => [[0_u64, 0_u64, 0_u64], [] of UInt64],
        "MultiLineString" => [[0_u64, 0_u64, 0_u64], [] of UInt64],
        "MultiPolygon"    => [[0_u64, 0_u64, 0_u64], [] of UInt64, [] of UInt64],
      }.each do |type_name, level_sizes|
        destination = File.join(parent, "#{type_name}_1_1_0")
        CrystalClick::WidePartWriter.write_uint64_geo_array_pair(
          destination, "pk", keys.to_unsafe.to_slice(keys.size), "geo", type_name,
          level_sizes, empty_values, rows_per_mark: 2
        )
        part = CrystalClick::WidePart.open_typed(destination, "geo")
        data = part.read_geo_array_mark_range("geo", 0, part.mark_count)
        data.type_name.should eq(type_name)
        data.row_count.should eq(keys.size)
        data.point_count.should eq(0)
        data.points.should be_empty
        data.topology.level_counts.should eq(level_sizes.map(&.size.to_u64))
        part.mark_row_counts.should eq([2_u64, 1_u64])
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a checksum-valid nested topology mutation before publishing" do
    parent = File.tempname("crystal-click-geo-array-w111-tamper")
    Dir.mkdir(parent)
    destination = File.join(parent, "all_1_1_0")
    stage_calls = [] of Int32
    factory = CrystalClick::WidePartWriter.w111_stage_factory_for_spec(stage_calls)
    hook = CrystalClick::WidePartWriter.w111_tamper_nested_sizes_and_refresh_for_spec("geo.size2")
    keys = [1_u64, 2_u64]
    levels = [[1_u64, 1_u64], [1_u64, 1_u64], [1_u64, 2_u64]]
    points = [CrystalClick::WidePointValue.new(1.0, 2.0), CrystalClick::WidePointValue.new(3.0, 4.0), CrystalClick::WidePointValue.new(5.0, 6.0)]
    begin
      expect_raises(CrystalClick::CorruptPartError, "staged Geo Array nested size topology differs") do
        CrystalClick::WidePartWriter.w111_test_write_with_hooks(
          destination, "pk", keys.to_unsafe.to_slice(keys.size), "geo", "MultiPolygon",
          levels, points, 2, factory, hook
        )
      end
      stage_calls.should eq([1])
      File.exists?(destination).should be_false
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects malformed declarations and topology before making a stage" do
    parent = File.tempname("crystal-click-geo-array-w111-invalid")
    Dir.mkdir(parent)
    destination = File.join(parent, "all_1_1_0")
    stage_calls = [] of Int32
    factory = CrystalClick::WidePartWriter.w111_stage_factory_for_spec(stage_calls)
    no_op = CrystalClick::WidePartWriter.w111_no_op_hook_for_spec
    keys = [1_u64, 2_u64]
    points = [CrystalClick::WidePointValue.new(1.0, 2.0)]
    begin
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.w111_test_write_with_hooks(
          destination, "pk", keys.to_unsafe.to_slice(keys.size), "geo", "Array(Point)",
          [[1_u64, 0_u64]], points, 1, factory, no_op
        )
      end
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.w111_test_write_with_hooks(
          destination, "pk", keys.to_unsafe.to_slice(keys.size), "geo", "LineString",
          [[1_u64]], points, 1, factory, no_op
        )
      end
      stage_calls.should be_empty
      File.exists?(destination).should be_false
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
