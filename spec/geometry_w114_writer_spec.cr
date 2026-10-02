require "./spec_helper"
require "file_utils"

private struct W114WriterFixture
  getter keys : Array(UInt64)
  getter data : CrystalClick::WideGeometryColumnData
  getter stream_names : Array(String)

  def initialize(@keys : Array(UInt64), @data : CrystalClick::WideGeometryColumnData, @stream_names : Array(String))
  end
end

private def w114w_slice(values : Array(T)) : Slice(T) forall T
  values.to_unsafe.to_slice(values.size)
end

private def w114w_point(x_bits : UInt64, y_bits : UInt64) : CrystalClick::WidePointValue
  CrystalClick::WidePointValue.from_bits(x_bits, y_bits)
end

private def w114w_geo_array(
  type_name : String,
  level_sizes : Array(Array(UInt64)),
  points : Array(CrystalClick::WidePointValue),
) : CrystalClick::WideGeoArrayColumnData
  plan = CrystalClick::GeoArrayColumnType.for_type(type_name) ||
         raise ArgumentError.new("unknown W114 writer fixture type")
  CrystalClick::WideGeoArrayColumnData.new(plan, level_sizes, points)
end

private def w114w_fixture : W114WriterFixture
  tags = [0_u8, 255_u8, 3_u8, 1_u8, 2_u8, 4_u8, 5_u8, 6_u8, 3_u8, 255_u8, 0_u8]
  keys = (0_u64...tags.size.to_u64).to_a
  points = [
    w114w_point(0x8000_0000_0000_0000_u64, 0x7ff8_0000_0000_0042_u64),
    w114w_point(0x3ff0_0000_0000_0000_u64, 0xfff0_0000_0000_0000_u64),
    w114w_point(0x4008_0000_0000_0000_u64, 1_u64),
    w114w_point(0x7ff8_0000_0000_1234_u64, 0x4010_0000_0000_0000_u64),
    w114w_point(0x4014_0000_0000_0000_u64, 0x7ff8_0000_0000_5678_u64),
    w114w_point(0xfff0_0000_0000_0000_u64, 0x4020_0000_0000_0000_u64),
    w114w_point(0x4022_0000_0000_0000_u64, 0x7ff0_0000_0000_0000_u64),
    w114w_point(0x7ff8_0000_0000_9abc_u64, 0x4028_0000_0000_0000_u64),
    w114w_point(0x402a_0000_0000_0000_u64, 0x8000_0000_0000_0000_u64),
  ] of CrystalClick::WidePointValue

  owners = {} of CrystalClick::WideGeometryArm => CrystalClick::WideGeoArrayColumnData
  owners[CrystalClick::WideGeometryArm::LineString] = w114w_geo_array(
    "LineString", [[2_u64, 0_u64]], [points[0], points[1]]
  )
  owners[CrystalClick::WideGeometryArm::MultiLineString] = w114w_geo_array(
    "MultiLineString", [[2_u64], [1_u64, 0_u64]], [points[2]]
  )
  owners[CrystalClick::WideGeometryArm::MultiPolygon] = w114w_geo_array(
    "MultiPolygon", [[1_u64], [1_u64], [2_u64]], [points[3], points[4]]
  )
  owners[CrystalClick::WideGeometryArm::Polygon] = w114w_geo_array(
    "Polygon", [[1_u64], [0_u64]], [] of CrystalClick::WidePointValue
  )
  owners[CrystalClick::WideGeometryArm::Ring] = w114w_geo_array(
    "Ring", [[2_u64]], [points[5], points[6]]
  )
  owners[CrystalClick::WideGeometryArm::MultiPoint] = w114w_geo_array(
    "MultiPoint", [[0_u64]], [] of CrystalClick::WidePointValue
  )

  data = CrystalClick::WideGeometryColumnData.new(
    tags,
    [points[7], points[8]],
    owners
  )
  streams = [
    "payload.variant_discr",
    "payload.LineString.size0",
    "payload.LineString%2E1",
    "payload.LineString%2E2",
    "payload.MultiLineString.size0",
    "payload.MultiLineString.size1",
    "payload.MultiLineString%2E1",
    "payload.MultiLineString%2E2",
    "payload.MultiPolygon.size0",
    "payload.MultiPolygon.size1",
    "payload.MultiPolygon.size2",
    "payload.MultiPolygon%2E1",
    "payload.MultiPolygon%2E2",
    "payload.Point%2E1",
    "payload.Point%2E2",
    "payload.Polygon.size0",
    "payload.Polygon.size1",
    "payload.Polygon%2E1",
    "payload.Polygon%2E2",
    "payload.Ring.size0",
    "payload.Ring%2E1",
    "payload.Ring%2E2",
    "payload.MultiPoint.size0",
    "payload.MultiPoint%2E1",
    "payload.MultiPoint%2E2",
  ] of String
  W114WriterFixture.new(keys, data, streams)
end

private def w114w_u64_at(bytes : Bytes, offset : Int32) : UInt64
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

private def w114w_mark_rows(part : String, stream_name : String) : Array(UInt64)
  bytes = File.read(File.join(part, "#{CrystalClick::StreamName.hash(stream_name)}.mrk2")).to_slice
  raise "W114 writer mark file is not a sequence of 24-byte records" unless bytes.size % 24 == 0
  (0...(bytes.size // 24)).map do |index|
    w114w_u64_at(bytes, (index * 24 + 16).to_i32)
  end
end

private def w114w_mark_offsets(part : String, stream_name : String) : Array(UInt64)
  bytes = File.read(File.join(part, "#{CrystalClick::StreamName.hash(stream_name)}.mrk2")).to_slice
  raise "W114 writer mark file is not a sequence of 24-byte records" unless bytes.size % 24 == 0
  (0...(bytes.size // 24)).map do |index|
    w114w_u64_at(bytes, (index * 24).to_i32)
  end
end

module CrystalClick::WidePartWriter
  # Test-only seam: production keeps staging and mutation hooks private.
  def self.w114_test_write_with_hooks(
    destination : String,
    key_name : String,
    keys : Slice(UInt64),
    value_name : String,
    data : WideGeometryColumnData,
    rows_per_mark : Int32,
    stage_factory : Proc(String, String),
    before_validation_hook : Proc(String, Nil),
  ) : String
    write_geometry_pair_with_hooks(
      destination, key_name, keys, value_name, data, rows_per_mark,
      stage_factory, before_validation_hook
    )
  end

  def self.w114_stage_factory_for_spec(calls : Array(Int32)) : Proc(String, String)
    ->(parent : String) do
      calls << 1
      stage = File.tempname("crystal-click-geometry-w114-stage", nil, dir: parent)
      Dir.mkdir(stage)
      stage
    end
  end

  def self.w114_mutating_stage_factory_for_spec(
    keys : Slice(UInt64),
    calls : Array(Int32),
  ) : Proc(String, String)
    ->(parent : String) do
      calls << 1
      keys[0] = 99_u64
      stage = File.tempname("crystal-click-geometry-w114-snapshot-stage", nil, dir: parent)
      Dir.mkdir(stage)
      stage
    end
  end

  def self.w114_no_op_hook_for_spec : Proc(String, Nil)
    ->(_stage : String) { nil }
  end

  def self.w114_tamper_point_x_and_refresh_for_spec(logical_name : String) : Proc(String, Nil)
    ->(stage : String) do
      checksums = PartChecksums.open(stage)
      data_path = File.join(stage, "#{StreamName.hash(logical_name)}.bin")
      encoded = File.read(data_path).to_slice
      frame = CompressedBlock.decode_frame(
        encoded,
        0_i64,
        PartChecksums::MAX_FRAME_COMPRESSED_BYTES,
        PartChecksums::MAX_FRAME_DECOMPRESSED_BYTES
      )
      raw = frame.output.dup
      raise "W114 tamper fixture did not select one Float64 coordinate" unless raw.size == 8
      raw[0] ^= 1_u8
      replacement = StreamEncoding.encode_lz4_frame(raw)
      suffix = encoded[frame.end_offset.to_i32, encoded.size - frame.end_offset.to_i32].dup
      original_size = encoded.size
      File.write(data_path, String.build do |output|
        output.write(replacement)
        output.write(suffix)
      end)
      rewritten = File.read(data_path).to_slice
      raise "W114 tamper changed the encoded stream size" unless rewritten.size == original_size
      rewritten[replacement.size, rewritten.size - replacement.size].should eq(suffix)

      records = [] of ChecksumRecord
      checksums.entries.each do |name, entry|
        bytes = File.read(File.join(stage, name)).to_slice
        if entry.compressed
          decoded = bytes.empty? ? Bytes.empty : CompressedBlock.decode_all(
            bytes,
            PartChecksums::MAX_FRAME_COMPRESSED_BYTES,
            PartChecksums::MAX_FRAME_DECOMPRESSED_BYTES,
            PartChecksums::MAX_PAYLOAD_BYTES
          )
          records << ChecksumRecord.new(
            name, bytes.size.to_u64, CityHashV1.file_hash(bytes), true,
            decoded.size.to_u64, CityHashV1.file_hash(decoded)
          )
        else
          records << ChecksumRecord.new(name, bytes.size.to_u64, CityHashV1.file_hash(bytes), false)
        end
      end
      write_checksums(stage, records)
      nil
    end
  end

  def self.w114_corrupt_raw_hash_only_for_spec(logical_name : String) : Proc(String, Nil)
    ->(stage : String) do
      checksums = PartChecksums.open(stage)
      original_manifest = File.read(File.join(stage, "checksums.txt"))
      target_name = "#{StreamName.hash(logical_name)}.bin"
      target_seen = false
      records = [] of ChecksumRecord

      checksums.entries.each do |name, entry|
        bytes = File.read(File.join(stage, name)).to_slice
        actual_file_hash = CityHashV1.file_hash(bytes)
        raise "W114 checksum fixture changed a physical file size" unless bytes.size.to_u64 == entry.physical_size
        raise "W114 checksum fixture changed a physical file hash" unless actual_file_hash == entry.file_hash

        if entry.compressed
          decoded = bytes.empty? ? Bytes.empty : CompressedBlock.decode_all(
            bytes,
            PartChecksums::MAX_FRAME_COMPRESSED_BYTES,
            PartChecksums::MAX_FRAME_DECOMPRESSED_BYTES,
            PartChecksums::MAX_PAYLOAD_BYTES
          )
          raw_hash = CityHashV1.file_hash(decoded)
          raise "W114 checksum fixture changed an uncompressed size" unless entry.uncompressed_size == decoded.size.to_u64
          if name == target_name
            raise "W114 checksum target is not compressed" if target_seen
            target_seen = true
            records << ChecksumRecord.new(
              name, entry.physical_size, entry.file_hash, true,
              entry.uncompressed_size, {raw_hash[0] ^ 1_u64, raw_hash[1]}
            )
          else
            records << ChecksumRecord.new(
              name, entry.physical_size, entry.file_hash, true,
              entry.uncompressed_size, raw_hash
            )
          end
        else
          records << ChecksumRecord.new(name, entry.physical_size, entry.file_hash, false)
        end
      end

      raise "W114 checksum target was not found" unless target_seen
      write_checksums(stage, records)

      rewritten_manifest = File.read(File.join(stage, "checksums.txt"))
      raise "W114 raw-hash mutation did not change checksums.txt" if rewritten_manifest == original_manifest
      rewritten = PartChecksums.open(stage)
      raise "W114 raw-hash mutation changed the manifest inventory" unless rewritten.entries.keys.sort == checksums.entries.keys.sort
      checksums.entries.each do |name, before|
        after = rewritten.entry(name) || raise "W114 rewritten checksum entry is missing"
        unless after.physical_size == before.physical_size && after.file_hash == before.file_hash &&
               after.compressed == before.compressed && after.uncompressed_size == before.uncompressed_size
          raise "W114 raw-hash mutation changed a non-raw checksum field"
        end
      end
      nil
    end
  end
end

describe "W114 paired Geometry writer" do
  it "writes the exact 25-stream profile with every sparse lane on the outer table mark grid" do
    fixture = w114w_fixture
    parent = File.tempname("crystal-click-geometry-w114-writer")
    Dir.mkdir(parent)
    destination = File.join(parent, "all_1_1_0")

    begin
      CrystalClick::WidePartWriter.write_uint64_geometry_pair(
        destination,
        "pk",
        w114w_slice(fixture.keys),
        "payload",
        fixture.data,
        rows_per_mark: 3
      ).should eq(destination)

      File.read(File.join(destination, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` Geometry\n"
      )
      File.read(File.join(destination, "columns_substreams.txt")).should eq(
        String.build do |metadata|
          metadata << "columns substreams version: 1\n2 columns:\n"
          metadata << "1 substreams for column `pk`:\n\tpk\n"
          metadata << "25 substreams for column `payload`:\n"
          fixture.stream_names.each { |stream| metadata << "\t#{stream}\n" }
        end
      )
      serialization = JSON.parse(File.read(File.join(destination, "serialization.json")))
      columns = serialization["columns"].as_a
      columns.size.should eq(1)
      columns[0]["name"].as_s.should eq("pk")
      columns[0]["num_rows"].as_i.should eq(fixture.keys.size)
      columns[0]["num_defaults"].as_i.should eq(1)
      columns[0]["exact_num_defaults"].as_bool.should be_true
      serialization["types_serialization_versions"]["string"].as_i.should eq(1)
      serialization["propagate_types_serialization_versions_to_nested_types"].as_bool.should be_true
      File.exists?(File.join(destination, "statistics.packed")).should be_false

      physical_rows = [3_u64, 3_u64, 3_u64, 2_u64, 0_u64]
      fixture.stream_names.each do |stream|
        base = CrystalClick::StreamName.hash(stream)
        File.exists?(File.join(destination, "#{base}.bin")).should be_true
        File.exists?(File.join(destination, "#{base}.mrk2")).should be_true
        w114w_mark_rows(destination, stream).should eq(physical_rows)
      end
      w114w_mark_rows(destination, "pk").should eq(physical_rows)

      # MultiLineString exists only in table mark 1. The empty preceding and
      # trailing arm marks retain outer-grid entries rather than disappearing.
      offsets = w114w_mark_offsets(destination, "payload.MultiLineString%2E1")
      offsets[0].should eq(offsets[1])
      offsets[2].should eq(offsets[3])
      offsets[3].should eq(offsets[4])

      # Polygon and MultiPoint are present but have no coordinates at all;
      # their coordinate streams still carry the complete mark grid.
      {"payload.Polygon%2E1", "payload.Polygon%2E2", "payload.MultiPoint%2E1", "payload.MultiPoint%2E2"}.each do |stream|
        File.size(File.join(destination, "#{CrystalClick::StreamName.hash(stream)}.bin")).should eq(0)
        w114w_mark_rows(destination, stream).should eq(physical_rows)
      end

      checksums = CrystalClick::PartChecksums.open(destination)
      expected_entries = ["count.txt", "primary.idx", "serialization.json", "#{CrystalClick::StreamName.hash("pk")}.bin", "#{CrystalClick::StreamName.hash("pk")}.mrk2"] of String
      fixture.stream_names.each do |stream|
        base = CrystalClick::StreamName.hash(stream)
        expected_entries << "#{base}.bin"
        expected_entries << "#{base}.mrk2"
      end
      checksums.entries.keys.sort.should eq(expected_entries.sort)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a self-consistent staged coordinate mutation before publication" do
    fixture = w114w_fixture
    parent = File.tempname("crystal-click-geometry-w114-tamper")
    Dir.mkdir(parent)
    destination = File.join(parent, "all_1_1_0")
    stage_calls = [] of Int32
    stage_factory = CrystalClick::WidePartWriter.w114_stage_factory_for_spec(stage_calls)
    hook = CrystalClick::WidePartWriter.w114_tamper_point_x_and_refresh_for_spec("payload.Point%2E1")

    begin
      expect_raises(CrystalClick::CorruptPartError, "staged Geometry Point values differ") do
        CrystalClick::WidePartWriter.w114_test_write_with_hooks(
          destination,
          "pk",
          w114w_slice(fixture.keys),
          "payload",
          fixture.data,
          3,
          stage_factory,
          hook
        )
      end
      stage_calls.should eq([1])
      File.exists?(destination).should be_false
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a raw checksum-manifest mutation after identical physical readback" do
    fixture = w114w_fixture
    parent = File.tempname("crystal-click-geometry-w114-checksum-manifest-tamper")
    Dir.mkdir(parent)
    destination = File.join(parent, "all_1_1_0")
    stage_calls = [] of Int32
    stage_factory = CrystalClick::WidePartWriter.w114_stage_factory_for_spec(stage_calls)
    hook = CrystalClick::WidePartWriter.w114_corrupt_raw_hash_only_for_spec("payload.Point%2E1")

    begin
      expect_raises(CrystalClick::CorruptPartError, "staged Geometry checksum manifest differs") do
        CrystalClick::WidePartWriter.w114_test_write_with_hooks(
          destination,
          "pk",
          w114w_slice(fixture.keys),
          "payload",
          fixture.data,
          3,
          stage_factory,
          hook
        )
      end
      stage_calls.should eq([1])
      File.exists?(destination).should be_false
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a key-cardinality mismatch before requesting a stage" do
    fixture = w114w_fixture
    parent = File.tempname("crystal-click-geometry-w114-preflight")
    Dir.mkdir(parent)
    destination = File.join(parent, "all_1_1_0")
    stage_calls = [] of Int32
    stage_factory = CrystalClick::WidePartWriter.w114_stage_factory_for_spec(stage_calls)
    no_op = CrystalClick::WidePartWriter.w114_no_op_hook_for_spec
    short_keys = fixture.keys[0, fixture.keys.size - 1]

    begin
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.w114_test_write_with_hooks(
          destination,
          "pk",
          w114w_slice(short_keys),
          "payload",
          fixture.data,
          3,
          stage_factory,
          no_op
        )
      end
      stage_calls.should be_empty
      File.exists?(destination).should be_false
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "freezes caller keys before the staging callback can mutate their source slice" do
    fixture = w114w_fixture
    parent = File.tempname("crystal-click-geometry-w114-snapshot")
    Dir.mkdir(parent)
    destination = File.join(parent, "all_1_1_0")
    keys = w114w_slice(fixture.keys)
    stage_calls = [] of Int32
    stage_factory = CrystalClick::WidePartWriter.w114_mutating_stage_factory_for_spec(keys, stage_calls)
    no_op = CrystalClick::WidePartWriter.w114_no_op_hook_for_spec

    begin
      CrystalClick::WidePartWriter.w114_test_write_with_hooks(
        destination,
        "pk",
        keys,
        "payload",
        fixture.data,
        3,
        stage_factory,
        no_op
      ).should eq(destination)

      stage_calls.should eq([1])
      fixture.keys[0].should eq(99_u64)
      index = CrystalClick::PrimaryKeyIndex.open(
        destination, 4, CrystalClick::PartChecksums.open(destination)
      )
      index.keys.should eq([0_u64, 3_u64, 6_u64, 9_u64, 10_u64])

      key_part = CrystalClick::WidePart.open_typed(destination, "pk")
      actual = [] of UInt64
      4.times do |mark_index|
        actual.concat(key_part.read_uint64_mark_range("pk", mark_index, 1))
      end
      actual.should eq((0_u64...11_u64).to_a)
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
