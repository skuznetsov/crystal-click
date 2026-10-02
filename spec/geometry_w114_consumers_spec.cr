require "./spec_helper"
require "file_utils"

module CrystalClick::WidePartWriter
  # Test-only bridge into the staged validation hook; production keeps the
  # hook private and publishes only after the exact readback succeeds.
  def self.w114c_test_write_with_hooks(
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

  def self.w114c_stage_factory_for_spec(calls : Array(Int32)) : Proc(String, String)
    ->(parent : String) do
      calls << 1
      stage = File.tempname("crystal-click-w114-geometry-stage", nil, dir: parent)
      Dir.mkdir(stage)
      stage
    end
  end

  def self.w114c_tamper_primary_index_and_refresh_for_spec : Proc(String, Nil)
    ->(stage : String) do
      path = File.join(stage, "primary.idx")
      bytes = File.read(path).to_slice.dup
      raise "W114 primary index fixture is empty" if bytes.empty?
      bytes[0] = bytes[0] ^ 1_u8
      File.write(path, bytes)
      w114c_refresh_checksums_for_spec(stage)
      nil
    end
  end

  def self.w114c_refresh_checksums_for_spec(stage : String) : Nil
    checksums = PartChecksums.open(stage)
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

private W114C_BLOCK_TAGS = [
  255_u8, 0_u8, 1_u8, 2_u8, 3_u8, 4_u8, 5_u8, 6_u8,
]

private W114C_POINTS = [
  CrystalClick::WidePointValue.from_bits(0x8000_0000_0000_0000_u64, 0x7ff8_0000_0000_0042_u64),
  CrystalClick::WidePointValue.from_bits(0x7ff0_0000_0000_0000_u64, 1_u64),
  CrystalClick::WidePointValue.from_bits(0xfff8_0000_0000_1234_u64, 0x3ff4_0000_0000_0000_u64),
  CrystalClick::WidePointValue.from_bits(0xfff0_0000_0000_0000_u64, 0xc004_0000_0000_0000_u64),
  CrystalClick::WidePointValue.from_bits(0x4002_0000_0000_0000_u64, 0x4008_0000_0000_0000_u64),
  CrystalClick::WidePointValue.from_bits(0x0000_0000_0000_0001_u64, 0x8000_0000_0000_0000_u64),
  CrystalClick::WidePointValue.from_bits(0x4014_0000_0000_0000_u64, 0x7ff8_0000_0000_5678_u64),
  CrystalClick::WidePointValue.from_bits(0xc01c_0000_0000_0000_u64, 0x3ff0_0000_0000_0000_u64),
  CrystalClick::WidePointValue.from_bits(0x4022_0000_0000_0000_u64, 0xfff8_0000_0000_9abc_u64),
  CrystalClick::WidePointValue.from_bits(0x4026_0000_0000_0000_u64, 0xc024_0000_0000_0000_u64),
  CrystalClick::WidePointValue.from_bits(0x402a_0000_0000_0000_u64, 0x400c_0000_0000_0000_u64),
  CrystalClick::WidePointValue.from_bits(0x402e_0000_0000_0000_u64, 0x4010_0000_0000_0000_u64),
  CrystalClick::WidePointValue.from_bits(0x4031_0000_0000_0000_u64, 0x4012_0000_0000_0000_u64),
] of CrystalClick::WidePointValue

private def w114c_tags : Array(UInt8)
  tags = [] of UInt8
  4.times { tags.concat(W114C_BLOCK_TAGS) }
  tags << 6_u8 # One-row short tail in the last physical mark.
  tags
end

private def w114c_slice(values : Array(T)) : Slice(T) forall T
  values.to_unsafe.to_slice(values.size)
end

private def w114c_u64_at(bytes : Bytes, offset : Int32) : UInt64
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

private def w114c_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w114c_shift_mark_local_start(part : String, stream_name : String, mark_index : Int32) : Nil
  mark_path = File.join(part, "#{CrystalClick::StreamName.hash(stream_name)}.mrk2")
  marks = File.read(mark_path).to_slice.dup
  mark_size = CrystalClick::WidePart::MARK_SIZE
  raise "W114 hostile mark file is not a sequence of records" unless marks.size % mark_size == 0
  raise "W114 hostile mark index is out of range" if mark_index < 0 || mark_index >= marks.size // mark_size

  # Widen the selected frame-local offset beyond the frame's decoded output,
  # leaving a well-shaped mark record and repairing checksums below.
  offset = mark_index * mark_size + 8
  previous = w114c_u64_at(marks, offset.to_i32)
  raise "W114 hostile mark offset overflows" if previous > UInt64::MAX - 24_u64
  w114c_write_u64(marks, offset, previous + 24_u64)
  File.write(mark_path, marks)
  nil
end

private def w114c_geo_array(
  type_name : String,
  level_sizes : Array(Array(UInt64)),
  points : Array(CrystalClick::WidePointValue),
) : CrystalClick::WideGeoArrayColumnData
  plan = CrystalClick::GeoArrayColumnType.for_type(type_name) ||
         raise ArgumentError.new("unknown W114 consumer fixture arm")
  CrystalClick::WideGeoArrayColumnData.new(plan, level_sizes, points)
end

private def w114c_geometry_data : CrystalClick::WideGeometryColumnData
  arrays = {} of CrystalClick::WideGeometryArm => CrystalClick::WideGeoArrayColumnData
  arrays[CrystalClick::WideGeometryArm::LineString] = w114c_geo_array(
    "LineString", [[2_u64, 0_u64, 2_u64, 0_u64]], W114C_POINTS[0, 4]
  )
  arrays[CrystalClick::WideGeometryArm::MultiLineString] = w114c_geo_array(
    "MultiLineString",
    [[1_u64, 0_u64, 1_u64, 0_u64], [0_u64, 0_u64]],
    [] of CrystalClick::WidePointValue
  )
  arrays[CrystalClick::WideGeometryArm::MultiPolygon] = w114c_geo_array(
    "MultiPolygon",
    [[1_u64, 0_u64, 1_u64, 0_u64], [1_u64, 1_u64], [1_u64, 0_u64]],
    [W114C_POINTS[4]]
  )
  arrays[CrystalClick::WideGeometryArm::Polygon] = w114c_geo_array(
    "Polygon", [[1_u64, 0_u64, 1_u64, 0_u64], [0_u64, 0_u64]],
    [] of CrystalClick::WidePointValue
  )
  arrays[CrystalClick::WideGeometryArm::Ring] = w114c_geo_array(
    "Ring", [[1_u64, 0_u64, 1_u64, 0_u64]], [W114C_POINTS[5], W114C_POINTS[6]]
  )
  arrays[CrystalClick::WideGeometryArm::MultiPoint] = w114c_geo_array(
    "MultiPoint", [[0_u64, 1_u64, 0_u64, 1_u64, 0_u64]], [W114C_POINTS[7], W114C_POINTS[8]]
  )
  CrystalClick::WideGeometryColumnData.new(
    w114c_tags,
    [W114C_POINTS[9], W114C_POINTS[10], W114C_POINTS[11], W114C_POINTS[12]],
    arrays
  )
end

private def w114c_late_coordinate_geometry_data : CrystalClick::WideGeometryColumnData
  data = w114c_geometry_data
  tags = data.tags
  tags[32] = 3_u8 # Make the final outer row a Point with a non-empty lane.
  arrays = {} of CrystalClick::WideGeometryArm => CrystalClick::WideGeoArrayColumnData
  {
    CrystalClick::WideGeometryArm::LineString,
    CrystalClick::WideGeometryArm::MultiLineString,
    CrystalClick::WideGeometryArm::MultiPolygon,
    CrystalClick::WideGeometryArm::Polygon,
    CrystalClick::WideGeometryArm::Ring,
    CrystalClick::WideGeometryArm::MultiPoint,
  }.each do |arm|
    arrays[arm] = if arm == CrystalClick::WideGeometryArm::MultiPoint
                    w114c_geo_array("MultiPoint", [[0_u64, 1_u64, 0_u64, 1_u64]], [W114C_POINTS[7], W114C_POINTS[8]])
                  else
                    data.geo_array_data(arm)
                  end
  end
  points = data.points
  points << W114C_POINTS[0]
  CrystalClick::WideGeometryColumnData.new(tags, points, arrays)
end

private def w114c_catalog_root(root : String, part : String) : String
  database_uuid = "11400000-0000-4000-8000-000000000001"
  table_uuid = "11400000-0001-4000-8000-000000000001"
  metadata_path = File.join(root, "metadata")
  database_path = File.join(root, "store", database_uuid[0, 3], database_uuid)
  table_path = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(metadata_path)
  FileUtils.mkdir_p(database_path)
  FileUtils.mkdir_p(table_path)
  File.write(File.join(metadata_path, "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  File.write(
    File.join(database_path, "events.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `pk` UInt64,\n    `payload` Geometry\n)\nENGINE = MergeTree\nORDER BY pk\n"
  )
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  FileUtils.cp_r(part, File.join(table_path, "all_1_1_0"))
  root
end

private def w114c_assert_point(actual : CrystalClick::WidePointValue, expected : CrystalClick::WidePointValue) : Nil
  actual.x_bits.should eq(expected.x_bits)
  actual.y_bits.should eq(expected.y_bits)
end

private def w114c_assert_row(
  actual : CrystalClick::WideGeometryRow,
  expected_tag : UInt8,
  fixture_rank : Int32?,
  owner_rank : Int32?,
) : Nil
  actual.type_name.should eq("Geometry")
  actual.tag.should eq(expected_tag)

  if expected_tag == 255_u8
    actual.null?.should be_true
    actual.arm.should be_nil
    actual.arm_index.should be_nil
    expect_raises(ArgumentError) { actual.geo_array }
    return
  end

  arm = CrystalClick::WideGeometryArm.for_tag(expected_tag).not_nil!
  actual.null?.should be_false
  actual.arm.should eq(arm)
  actual.arm_type_name.should eq(arm.type_name)
  actual.arm_index.should eq(owner_rank)
  rank = fixture_rank.not_nil!

  case arm
  when CrystalClick::WideGeometryArm::Point
    w114c_assert_point(actual.point, W114C_POINTS[9 + rank])
    expect_raises(ArgumentError) { actual.geo_array }
  else
    geo = actual.geo_array
    geo.type_name.should eq(arm.type_name)
    geo.level.should eq(0)
    case arm
    when CrystalClick::WideGeometryArm::LineString
      sizes = [2, 0, 2, 0]
      geo.size.should eq(sizes[rank])
      if rank == 0 || rank == 2
        start = rank == 0 ? 0 : 2
        w114c_assert_point(geo.point_at(0), W114C_POINTS[start])
        w114c_assert_point(geo.point_at(1), W114C_POINTS[start + 1])
      end
    when CrystalClick::WideGeometryArm::MultiLineString
      sizes = [1, 0, 1, 0]
      geo.size.should eq(sizes[rank])
      if geo.size == 1
        geo.array_at(0).size.should eq(0)
      end
    when CrystalClick::WideGeometryArm::MultiPolygon
      sizes = [1, 0, 1, 0]
      geo.size.should eq(sizes[rank])
      if geo.size == 1
        polygon = geo.array_at(0)
        polygon.size.should eq(1)
        ring = polygon.array_at(0)
        ring.size.should eq(rank == 0 ? 1 : 0)
        if ring.size == 1
          w114c_assert_point(ring.point_at(0), W114C_POINTS[4])
        end
      end
    when CrystalClick::WideGeometryArm::Polygon
      sizes = [1, 0, 1, 0]
      geo.size.should eq(sizes[rank])
      if geo.size == 1
        geo.array_at(0).size.should eq(0)
      end
    when CrystalClick::WideGeometryArm::Ring
      sizes = [1, 0, 1, 0]
      geo.size.should eq(sizes[rank])
      if geo.size == 1
        point_index = rank == 0 ? 5 : 6
        w114c_assert_point(geo.point_at(0), W114C_POINTS[point_index])
      end
    when CrystalClick::WideGeometryArm::MultiPoint
      sizes = [0, 1, 0, 1, 0]
      geo.size.should eq(sizes[rank])
      if geo.size == 1
        point_index = rank == 1 ? 7 : 8
        w114c_assert_point(geo.point_at(0), W114C_POINTS[point_index])
      end
    end
  end
end

private def w114c_assert_rows(
  rows : Indexable(CrystalClick::WideGeometryRow),
  expected_start : Int32,
  owner_start : Int32,
) : Nil
  tags = w114c_tags
  fixture_ranks = Array(Int32).new(7, 0)
  owner_ranks = Array(Int32).new(7, 0)
  (0...expected_start).each do |row_index|
    tag = tags[row_index]
    fixture_ranks[tag.to_i] += 1 unless tag == 255_u8
  end
  (owner_start...expected_start).each do |row_index|
    tag = tags[row_index]
    owner_ranks[tag.to_i] += 1 unless tag == 255_u8
  end

  rows.each_with_index do |row, local_index|
    tag = tags[expected_start + local_index]
    fixture_rank = tag == 255_u8 ? nil : fixture_ranks[tag.to_i]
    owner_rank = tag == 255_u8 ? nil : owner_ranks[tag.to_i]
    w114c_assert_row(row, tag, fixture_rank, owner_rank)
    unless tag == 255_u8
      fixture_ranks[tag.to_i] += 1
      owner_ranks[tag.to_i] += 1
    end
  end
end

private def w114c_assert_data(
  data : CrystalClick::WideGeometryColumnData,
  expected_start : Int32,
  owner_start : Int32,
  expected_count : Int32,
) : Nil
  data.row_count.should eq(expected_count)
  rows = Array(CrystalClick::WideGeometryRow).new(data.row_count) { |index| data.row(index) }
  w114c_assert_rows(rows, expected_start, owner_start)
end

describe "W114 Geometry direct, typed-table, and catalog consumers" do
  it "preserves all nominal arms, sparse ranks, nested empties, and raw bits across selected reads and scans" do
    parent = File.tempname("crystal-click-w114-geometry-consumers")
    Dir.mkdir(parent)
    part = File.join(parent, "all_1_1_0")
    data = w114c_geometry_data
    keys = Array(UInt64).new(33) { |index| index.to_u64 }
    keys[2] = keys[1]
    keys[18] = keys[17]

    begin
      CrystalClick::WidePartWriter.write_uint64_geometry_pair(
        part,
        "pk",
        w114c_slice(keys),
        "payload",
        data,
        rows_per_mark: 16
      ).should eq(part)

      CrystalClick::WidePart.supports_typed_type?("Geometry").should be_true
      reader = CrystalClick::WidePart.open_typed(part, "payload")
      reader.column_type.should eq("Geometry")
      reader.mark_count.should eq(3)
      full_charge = reader.geometry_mark_range_materialization_charge("payload", 0, reader.mark_count)
      full = reader.read_geometry_mark_range("payload", 0, reader.mark_count, full_charge)
      w114c_assert_data(full, 0, 0, 33)
      expect_raises(CrystalClick::CorruptPartError) do
        reader.read_geometry_mark_range("payload", 0, reader.mark_count, full_charge - 1_u64)
      end

      reader.validate_geometry_mark_range_structure("payload", 1, 1)
      selected = reader.read_geometry_mark_range("payload", 1, 1)
      w114c_assert_data(selected, 16, 16, 16)
      selected.row(9).arm_index.should eq(1)

      streamed_marks = [] of Int32
      reader.each_geometry_mark_range("payload", 1, 2) do |mark_data, mark_index|
        streamed_marks << mark_index
        expected_count = mark_index == 2 ? 1 : 16
        w114c_assert_data(mark_data, mark_index * 16, mark_index * 16, expected_count)
      end
      streamed_marks.should eq([1, 2])
      expect_raises(CrystalClick::BoundsError) do
        reader.validate_geometry_mark_range_structure("payload", -1, 1)
      end

      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      table.column_types.should eq([{"pk", "UInt64"}, {"payload", "Geometry"}])
      table_rows = [] of CrystalClick::WideGeometryRow
      retained_row = nil.as(CrystalClick::WideGeometryRow?)
      table.scan_typed(batch_rows: 16) do |batch|
        batch.column_type_for("payload").should eq("Geometry")
        rows = batch.geometry_rows_for("payload")
        start = batch.source_row_offset.to_i
        owner_start = (batch.source_row_offset - batch.mark_row_offset).to_i
        w114c_assert_rows(rows, start, owner_start)
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.point_values_for("payload") }
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.geo_array_rows_for("payload") }
        retained_row ||= rows[0]?
        rows.each { |row| table_rows << row }
        nil
      end
      table_rows.size.should eq(33)
      w114c_assert_rows(table_rows[0, 16], 0, 0)
      retained = retained_row.not_nil!
      w114c_assert_row(retained, 255_u8, nil, nil)

      window_rows = [] of CrystalClick::WideGeometryRow
      table.scan_typed_window(8_u64, 8) do |batch|
        start = batch.source_row_offset.to_i
        owner_start = (batch.source_row_offset - batch.mark_row_offset).to_i
        w114c_assert_rows(batch.geometry_rows_for("payload"), start, owner_start)
        batch.geometry_rows_for("payload").each { |row| window_rows << row }
        nil
      end
      window_rows.size.should eq(8)
      window_rows[0].arm_index.should be_nil
      (1..7).each { |index| window_rows[index].arm_index.should eq(1) }

      catalog_root = w114c_catalog_root(File.join(parent, "catalog"), part)
      offline = CrystalClick::OfflineCatalog.open(catalog_root).table("lab", "events")
      offline.columns.find { |column| column.name == "payload" }.not_nil!.type.should eq("Geometry")
      catalog_rows = offline["payload"].values.map(&.as(CrystalClick::WideGeometryRow))
      catalog_rows.size.should eq(33)
      catalog_rows.each_with_index do |row, index|
        owner_start = (index // 16) * 16
        w114c_assert_rows([row], index, owner_start)
      end

      catalog_window = [] of CrystalClick::WideGeometryRow
      offline.scan_typed_window(["pk", "payload"], 24_u64, 9) do |batch|
        start = batch.source_row_offset.to_i
        owner_start = (batch.source_row_offset - batch.mark_row_offset).to_i
        batch.geometry_rows_for("payload").each do |row|
          w114c_assert_rows([row], start, owner_start)
          catalog_window << row
          start += 1
        end
        nil
      end
      catalog_window.size.should eq(9)
      catalog_window.last.tag.should eq(6_u8)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "preflights a checksum-valid malformed later Geometry coordinate mark before callbacks" do
    parent = File.tempname("crystal-click-w114-geometry-later-mark-hostile")
    Dir.mkdir(parent)
    part = File.join(parent, "all_1_1_0")
    keys = Array(UInt64).new(33) { |index| index.to_u64 }
    keys[2] = keys[1]
    keys[18] = keys[17]

    begin
      CrystalClick::WidePartWriter.write_uint64_geometry_pair(
        part,
        "pk",
        w114c_slice(keys),
        "payload",
        w114c_late_coordinate_geometry_data,
        rows_per_mark: 16
      )

      # The hostile fixture gives mark 2 a Point, so this is a real coordinate
      # frame while marks 0 and 1 stay intact.
      w114c_shift_mark_local_start(part, "payload.Point%2E1", 2)
      CrystalClick::WidePartWriter.w114c_refresh_checksums_for_spec(part)
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])

      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError, "mark offset exceeds frame output") do
        table.scan_typed(batch_rows: 16) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)

      # The selected range ends before the defective final mark, so it is
      # still readable; only a range selecting that later mark must fail.
      callbacks = 0
      observed_rows = 0
      table.scan_typed_window(0_u64, 16) do |batch|
        callbacks += 1
        observed_rows += batch.geometry_rows_for("payload").size
        nil
      end
      callbacks.should eq(1)
      observed_rows.should eq(16)

      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError, "mark offset exceeds frame output") do
        table.scan_typed_window(0_u64, 33) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a checksum-valid staged primary-index mutation before publishing" do
    parent = File.tempname("crystal-click-w114-geometry-stage-tamper")
    Dir.mkdir(parent)
    destination = File.join(parent, "all_1_1_0")
    stage_calls = [] of Int32
    stage_factory = CrystalClick::WidePartWriter.w114c_stage_factory_for_spec(stage_calls)
    tamper = CrystalClick::WidePartWriter.w114c_tamper_primary_index_and_refresh_for_spec
    keys = Array(UInt64).new(33) { |index| index.to_u64 }
    keys[2] = keys[1]
    keys[18] = keys[17]

    begin
      expect_raises(CrystalClick::CorruptPartError, "staged Geometry primary index differs from input") do
        CrystalClick::WidePartWriter.w114c_test_write_with_hooks(
          destination,
          "pk",
          w114c_slice(keys),
          "payload",
          w114c_geometry_data,
          16,
          stage_factory,
          tamper
        )
      end
      stage_calls.should eq([1])
      File.exists?(destination).should be_false
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
