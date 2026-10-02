require "./spec_helper"
require "file_utils"

private def w114h_slice(values : Array(T)) : Slice(T) forall T
  values.to_unsafe.to_slice(values.size)
end

private def w114h_point(x_bits : UInt64, y_bits : UInt64) : CrystalClick::WidePointValue
  CrystalClick::WidePointValue.from_bits(x_bits, y_bits)
end

private def w114h_geo_array(
  type_name : String,
  levels : Array(Array(UInt64)),
  points : Array(CrystalClick::WidePointValue) = [] of CrystalClick::WidePointValue,
) : CrystalClick::WideGeoArrayColumnData
  plan = CrystalClick::GeoArrayColumnType.for_type(type_name) ||
         raise ArgumentError.new("unknown W114 hostile Geometry fixture type")
  CrystalClick::WideGeoArrayColumnData.new(plan, levels, points)
end

private def w114h_sparse_data : CrystalClick::WideGeometryColumnData
  points = [
    w114h_point(0x8000_0000_0000_0000_u64, 0x7ff8_0000_0000_0042_u64),
    w114h_point(0xfff0_0000_0000_0000_u64, 1_u64),
    w114h_point(0x7ff8_0000_0000_1234_u64, 0x3ff0_0000_0000_0000_u64),
  ] of CrystalClick::WidePointValue
  polygon_points = [
    w114h_point(0x4008_0000_0000_0000_u64, 0x4010_0000_0000_0000_u64),
    w114h_point(0x4014_0000_0000_0000_u64, 0x4020_0000_0000_0000_u64),
  ] of CrystalClick::WidePointValue
  owners = {} of CrystalClick::WideGeometryArm => CrystalClick::WideGeoArrayColumnData
  owners[CrystalClick::WideGeometryArm::LineString] = w114h_geo_array("LineString", [[] of UInt64])
  owners[CrystalClick::WideGeometryArm::MultiLineString] = w114h_geo_array(
    "MultiLineString", [[] of UInt64, [] of UInt64]
  )
  owners[CrystalClick::WideGeometryArm::MultiPolygon] = w114h_geo_array(
    "MultiPolygon", [[1_u64], [1_u64], [2_u64]], polygon_points
  )
  owners[CrystalClick::WideGeometryArm::Polygon] = w114h_geo_array(
    "Polygon", [[] of UInt64, [] of UInt64]
  )
  owners[CrystalClick::WideGeometryArm::Ring] = w114h_geo_array("Ring", [[] of UInt64])
  owners[CrystalClick::WideGeometryArm::MultiPoint] = w114h_geo_array("MultiPoint", [[] of UInt64])

  # Two earlier Point values make the selected window's local Point ranks
  # differ from their global ranks. The MultiPolygon row exercises all three
  # nested size levels within the same selected window.
  CrystalClick::WideGeometryColumnData.new(
    [3_u8, 255_u8, 3_u8, 2_u8, 3_u8, 255_u8],
    points,
    owners
  )
end

private def w114h_all_null_data : CrystalClick::WideGeometryColumnData
  owners = {} of CrystalClick::WideGeometryArm => CrystalClick::WideGeoArrayColumnData
  owners[CrystalClick::WideGeometryArm::LineString] = w114h_geo_array("LineString", [[] of UInt64])
  owners[CrystalClick::WideGeometryArm::MultiLineString] = w114h_geo_array(
    "MultiLineString", [[] of UInt64, [] of UInt64]
  )
  owners[CrystalClick::WideGeometryArm::MultiPolygon] = w114h_geo_array(
    "MultiPolygon", [[] of UInt64, [] of UInt64, [] of UInt64]
  )
  owners[CrystalClick::WideGeometryArm::Polygon] = w114h_geo_array(
    "Polygon", [[] of UInt64, [] of UInt64]
  )
  owners[CrystalClick::WideGeometryArm::Ring] = w114h_geo_array("Ring", [[] of UInt64])
  owners[CrystalClick::WideGeometryArm::MultiPoint] = w114h_geo_array("MultiPoint", [[] of UInt64])
  CrystalClick::WideGeometryColumnData.new(
    [255_u8, 255_u8, 255_u8],
    [] of CrystalClick::WidePointValue,
    owners
  )
end

private def w114h_write_part(parent : String, data : CrystalClick::WideGeometryColumnData) : String
  part = File.join(parent, "all_1_1_0")
  keys = Array(UInt64).new(data.row_count) { |index| index.to_u64 }
  CrystalClick::WidePartWriter.write_uint64_geometry_pair(
    part,
    "pk",
    w114h_slice(keys),
    "payload",
    data,
    rows_per_mark: 2
  )
end

module CrystalClick::WidePartWriter
  # Test-only bridge for checksum-valid on-disk hostile mutations.
  def self.w114h_refresh_checksums_for_spec(part : String) : Nil
    checksums = PartChecksums.open(part)
    records = [] of ChecksumRecord
    checksums.entries.each do |name, entry|
      bytes = File.read(File.join(part, name)).to_slice
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
    write_checksums(part, records)
    nil
  end

  def self.w114h_replace_first_discriminator_tag_for_spec(part : String, tag : UInt8) : Nil
    path = File.join(part, "#{StreamName.hash("payload.variant_discr")}.bin")
    encoded = File.read(path).to_slice
    frame = CompressedBlock.decode_frame(
      encoded,
      0_i64,
      PartChecksums::MAX_FRAME_COMPRESSED_BYTES,
      PartChecksums::MAX_FRAME_DECOMPRESSED_BYTES
    )
    raw = frame.output.dup
    raise "W114 hostile discriminator fixture does not have the writer's BASIC prefix and first row" unless raw.size >= 9
    raw[8] = tag
    replacement = StreamEncoding.encode_lz4_frame(raw)
    suffix = encoded[frame.end_offset.to_i32, encoded.size - frame.end_offset.to_i32].dup
    File.write(path, String.build do |output|
      output.write(replacement)
      output.write(suffix)
    end)
    w114h_refresh_checksums_for_spec(part)
    nil
  end

  def self.w114h_truncate_last_child_mark_for_spec(part : String, stream : String) : Nil
    path = File.join(part, "#{StreamName.hash(stream)}.mrk2")
    marks = File.read(path).to_slice
    mark_size = WidePart::MARK_SIZE
    raise "W114 hostile child mark fixture does not have four records" unless marks.size == mark_size * 4
    File.write(path, String.build do |output|
      output.write(marks[0, mark_size * 2])
      output.write(marks[mark_size * 3, mark_size]) # retain the EOF record
    end)
    w114h_refresh_checksums_for_spec(part)
    nil
  end
end

describe "W114 Geometry direct reader hostile boundaries" do
  it "accepts its exact reported charge and rejects one byte less" do
    parent = File.tempname("crystal-click-w114-geometry-reader-charge")
    Dir.mkdir(parent)
    begin
      part = w114h_write_part(parent, w114h_sparse_data)
      reader = CrystalClick::WidePart.open_typed(part, "payload")
      charge = reader.geometry_mark_range_materialization_charge("payload", 0, reader.mark_count)
      charge.should be > 0_u64
      data = reader.read_geometry_mark_range("payload", 0, reader.mark_count, charge)
      data.tags.should eq([3_u8, 255_u8, 3_u8, 2_u8, 3_u8, 255_u8])
      data.point_at(0).x_bits.should eq(0x8000_0000_0000_0000_u64)
      data.point_at(2).y_bits.should eq(0x3ff0_0000_0000_0000_u64)
      expect_raises(CrystalClick::CorruptPartError) do
        reader.read_geometry_mark_range("payload", 0, reader.mark_count, charge - 1_u64)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "keeps Point and depth-three MultiPolygon ranks local to a nonzero selected window" do
    parent = File.tempname("crystal-click-w114-geometry-reader-window")
    Dir.mkdir(parent)
    begin
      part = w114h_write_part(parent, w114h_sparse_data)
      reader = CrystalClick::WidePart.open_typed(part, "payload")
      reader.validate_geometry_mark_range_structure("payload", 1, 2)
      selected = reader.read_geometry_mark_range("payload", 1, 2)
      selected.tags.should eq([3_u8, 2_u8, 3_u8, 255_u8])
      selected.row(0).arm_index.should eq(0)
      selected.row(0).point.x_bits.should eq(0xfff0_0000_0000_0000_u64)
      selected.row(1).arm_index.should eq(0)
      polygon = selected.row(1).geo_array
      polygon.type_name.should eq("MultiPolygon")
      polygon.size.should eq(1)
      polygon.array_at(0).size.should eq(1)
      polygon.array_at(0).array_at(0).size.should eq(2)
      polygon.array_at(0).array_at(0).point_at(1).y_bits.should eq(0x4020_0000_0000_0000_u64)
      selected.row(2).arm_index.should eq(1)
      selected.row(2).point.x_bits.should eq(0x7ff8_0000_0000_1234_u64)

      streamed = [] of Tuple(Int32, CrystalClick::WideGeometryColumnData)
      reader.each_geometry_mark_range("payload", 1, 2) do |mark_data, mark_index|
        streamed << {mark_index, mark_data}
        nil
      end
      streamed.map(&.[0]).should eq([1, 2])
      streamed[0][1].row(0).arm_index.should eq(0)
      streamed[0][1].row(0).point.x_bits.should eq(0xfff0_0000_0000_0000_u64)
      streamed[1][1].row(0).arm_index.should eq(0)
      streamed[1][1].row(0).point.x_bits.should eq(0x7ff8_0000_0000_1234_u64)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a checksum-valid global tag 7 before the first each callback" do
    parent = File.tempname("crystal-click-w114-geometry-reader-tag-hostile")
    Dir.mkdir(parent)
    begin
      part = w114h_write_part(parent, w114h_sparse_data)
      CrystalClick::WidePartWriter.w114h_replace_first_discriminator_tag_for_spec(part, 7_u8)
      reader = CrystalClick::WidePart.open_typed(part, "payload")
      callbacks = 0
      error = expect_raises(CrystalClick::CorruptPartError) do
        reader.each_geometry_mark_range("payload", 0, reader.mark_count) do |_data, _mark|
          callbacks += 1
          nil
        end
      end
      error.message.to_s.downcase.includes?("tag").should be_true
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a checksummed child stream missing a mandatory outer mark" do
    parent = File.tempname("crystal-click-w114-geometry-reader-mark-hostile")
    Dir.mkdir(parent)
    begin
      part = w114h_write_part(parent, w114h_sparse_data)
      CrystalClick::WidePartWriter.w114h_truncate_last_child_mark_for_spec(
        part, "payload.MultiPolygon.size0"
      )
      expect_raises(CrystalClick::CorruptPartError, "row count does not match marks") do
        CrystalClick::WidePart.open_typed(part, "payload")
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "reads all-NULL rows when all 24 child payload streams are zero-byte" do
    parent = File.tempname("crystal-click-w114-geometry-reader-all-null")
    Dir.mkdir(parent)
    begin
      part = w114h_write_part(parent, w114h_all_null_data)
      plan = CrystalClick::GeometryColumnType.for_type("Geometry").not_nil!
      streams = plan.physical_streams("payload")
      child_streams = streams[1, streams.size - 1]
      streams.size.should eq(25)
      child_streams.size.should eq(24)
      child_streams.each do |stream, _width|
        File.size(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")).should eq(0)
      end

      reader = CrystalClick::WidePart.open_typed(part, "payload")
      data = reader.read_geometry_mark_range("payload", 0, reader.mark_count)
      data.tags.should eq([255_u8, 255_u8, 255_u8])
      data.points.should be_empty
      {
        CrystalClick::WideGeometryArm::LineString,
        CrystalClick::WideGeometryArm::MultiLineString,
        CrystalClick::WideGeometryArm::MultiPolygon,
        CrystalClick::WideGeometryArm::Point,
        CrystalClick::WideGeometryArm::Polygon,
        CrystalClick::WideGeometryArm::Ring,
        CrystalClick::WideGeometryArm::MultiPoint,
      }.each do |arm|
        data.arm_count(arm).should eq(0)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
