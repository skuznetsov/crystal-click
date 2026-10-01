require "./spec_helper"
require "file_utils"

private struct W111ConsumerFixture
  getter type_name : String
  getter depth : Int32
  getter level_sizes : Array(Array(UInt64))
  getter points : Array(CrystalClick::WidePointValue)

  def initialize(@type_name : String, @depth : Int32, @level_sizes : Array(Array(UInt64)), @points : Array(CrystalClick::WidePointValue))
  end
end

private W111_CONSUMER_KEYS = [0_u64, 1_u64, 2_u64, 3_u64, 4_u64]

private def w111c_slice(values : Array(T)) : Slice(T) forall T
  values.to_unsafe.to_slice(values.size)
end

private def w111c_points : Array(CrystalClick::WidePointValue)
  [
    CrystalClick::WidePointValue.from_bits(0x8000_0000_0000_0000_u64, 0_u64),
    CrystalClick::WidePointValue.from_bits(0x7ff8_0000_0000_1234_u64, 0x400c_0000_0000_0000_u64),
    CrystalClick::WidePointValue.from_bits(0xfff0_0000_0000_0000_u64, 1_u64),
    CrystalClick::WidePointValue.from_bits(0x4002_0000_0000_0000_u64, 0x7ff8_0000_0000_5678_u64),
  ] of CrystalClick::WidePointValue
end

private def w111c_fixture(type_name : String, depth : Int32) : W111ConsumerFixture
  points = w111c_points
  case depth
  when 1
    W111ConsumerFixture.new(type_name, depth, [[1_u64, 0_u64, 2_u64, 1_u64, 0_u64]], points)
  when 2
    W111ConsumerFixture.new(
      type_name,
      depth,
      [[2_u64, 0_u64, 1_u64, 1_u64, 0_u64], [1_u64, 0_u64, 2_u64, 1_u64]],
      points
    )
  when 3
    W111ConsumerFixture.new(
      type_name,
      depth,
      [
        [2_u64, 0_u64, 1_u64, 1_u64, 0_u64],
        [1_u64, 0_u64, 2_u64, 1_u64],
        [1_u64, 0_u64, 2_u64, 1_u64],
      ],
      points
    )
  else
    raise "unexpected W111 consumer depth #{depth}"
  end
end

private def w111c_expected_profiles : Array(Tuple(String, Int32))
  [
    {"LineString", 1},
    {"Ring", 1},
    {"Polygon", 2},
    {"MultiLineString", 2},
    {"MultiPolygon", 3},
  ]
end

private def w111c_prefix(sizes : Array(UInt64), count : Int32) : Int32
  sizes[0, count].sum(&.to_i32)
end

private def w111c_check_row(
  actual : CrystalClick::WideGeoArrayRow,
  fixture : W111ConsumerFixture,
  level : Int32,
  record_index : Int32,
) : Nil
  sizes = fixture.level_sizes[level]
  expected_size = sizes[record_index].to_i
  actual.type_name.should eq(fixture.type_name)
  actual.level.should eq(level)
  actual.size.should eq(expected_size)

  if level + 1 == fixture.depth
    point_start = w111c_prefix(sizes, record_index)
    expected_size.times do |index|
      actual_point = actual.point_at(index)
      expected_point = fixture.points[point_start + index]
      actual_point.x_bits.should eq(expected_point.x_bits)
      actual_point.y_bits.should eq(expected_point.y_bits)
    end
  else
    child_start = w111c_prefix(sizes, record_index)
    expected_size.times do |index|
      w111c_check_row(actual.array_at(index), fixture, level + 1, child_start + index)
    end
  end
end

private def w111c_check_rows(rows : Indexable(CrystalClick::WideGeoArrayRow), fixture : W111ConsumerFixture, first_index : Int32 = 0) : Nil
  rows.size.times do |index|
    w111c_check_row(rows[index], fixture, 0, first_index + index)
  end
end

private def w111c_catalog_root(root : String, part : String, type_name : String, profile_index : Int32) : Nil
  suffix = profile_index.to_s.rjust(12, '0')
  database_uuid = "11100000-0000-4000-8000-#{suffix}"
  table_uuid = "11100000-0001-4000-8000-#{suffix}"
  metadata_path = File.join(root, "metadata")
  database_path = File.join(root, "store", database_uuid[0, 3], database_uuid)
  table_path = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(metadata_path)
  FileUtils.mkdir_p(database_path)
  FileUtils.mkdir_p(table_path)
  File.write(File.join(metadata_path, "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  File.write(
    File.join(database_path, "events.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `pk` UInt64,\n    `payload` #{type_name}\n)\nENGINE = MergeTree\nORDER BY pk\n"
  )
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  FileUtils.cp_r(part, File.join(table_path, "all_1_1_0"))
end

describe "W111 Geo Array table and catalog consumers" do
  it "retains exact nominal identity, ragged rows, and raw Point bits through full/window/catalog scans" do
    parent = File.tempname("crystal-click-w111-geo-consumers")
    Dir.mkdir(parent)

    begin
      w111c_expected_profiles.each_with_index do |entry, profile_index|
        type_name, depth = entry
        fixture = w111c_fixture(type_name, depth)
        profile_root = File.join(parent, type_name.downcase)
        Dir.mkdir(profile_root)
        part = File.join(profile_root, "all_1_1_0")

        CrystalClick::WidePartWriter.write_uint64_geo_array_pair(
          part,
          "pk",
          w111c_slice(W111_CONSUMER_KEYS),
          "payload",
          fixture.type_name,
          fixture.level_sizes,
          fixture.points,
          rows_per_mark: 2
        ).should eq(part)

        table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
        table.column_types.should eq([{"pk", "UInt64"}, {"payload", type_name}])
        table_rows = [] of CrystalClick::WideGeoArrayRow
        retained_table_row = nil.as(CrystalClick::WideGeoArrayRow?)
        callback_count = 0
        table.scan_typed(batch_rows: 2) do |batch|
          batch.column_type_for("payload").should eq(type_name)
          rows = batch.geo_array_rows_for("payload")
          rows.size.should be > 0
          expect_raises(CrystalClick::UnsupportedFormatError) { batch.point_values_for("payload") }
          retained_table_row ||= rows[0]
          w111c_check_rows(rows, fixture, table_rows.size.to_i32)
          rows.each { |row| table_rows << row }
          if retained = retained_table_row
            retained.type_name.should eq(type_name)
            w111c_check_row(retained, fixture, 0, 0)
          end
          callback_count += 1
          nil
        end
        callback_count.should be > 1
        table_rows.size.should eq(W111_CONSUMER_KEYS.size)
        w111c_check_rows(table_rows, fixture)

        table_window = [] of CrystalClick::WideGeoArrayRow
        table.scan_typed_window(2_u64, 2) do |batch|
          batch.column_type_for("payload").should eq(type_name)
          rows = batch.geo_array_rows_for("payload")
          w111c_check_rows(rows, fixture, 2)
          rows.each { |row| table_window << row }
          nil
        end
        table_window.size.should eq(2)

        # The UInt64 PK index selects one complete granule (rows 2..3). This
        # exercises the candidate-mark path rather than a post-read row window.
        data_mark_count = table.part_mark_row_counts[0].size
        pk_index = CrystalClick::PrimaryKeyIndex.open(
          part,
          data_mark_count,
          CrystalClick::PartChecksums.open(part),
          verify_recorded_hash: true
        )
        candidate_marks = pk_index.candidate_marks(3_u64, 3_u64)
        candidate_marks.should eq([1_i32])
        selected_rows = [] of CrystalClick::WideGeoArrayRow
        selected_pks = [] of UInt64
        retained_selected_row = nil.as(CrystalClick::WideGeoArrayRow?)
        selected_callbacks = 0
        table.scan_typed_candidate_marks([candidate_marks]) do |batch|
          batch.mark_index.should eq(1)
          batch.column_type_for("payload").should eq(type_name)
          batch.values_for("pk").each { |pk| selected_pks << pk }
          rows = batch.geo_array_rows_for("payload")
          rows.size.should eq(2)
          retained_selected_row ||= rows[0]
          w111c_check_rows(rows, fixture, 2)
          rows.each { |row| selected_rows << row }
          selected_callbacks += 1
          nil
        end
        selected_callbacks.should eq(1)
        selected_pks.should eq([2_u64, 3_u64])
        selected_rows.size.should eq(2)
        w111c_check_rows(selected_rows, fixture, 2)
        exact_rows = [] of CrystalClick::WideGeoArrayRow
        selected_rows.each_with_index do |row, index|
          exact_rows << row if selected_pks[index] == 3_u64
        end
        exact_rows.size.should eq(1)
        w111c_check_row(exact_rows[0], fixture, 0, 3)
        retained_selected = retained_selected_row.not_nil!
        retained_selected.type_name.should eq(type_name)
        w111c_check_row(retained_selected, fixture, 0, 2)

        catalog_root = File.join(profile_root, "catalog")
        w111c_catalog_root(catalog_root, part, type_name, profile_index + 1)
        offline = CrystalClick::OfflineCatalog.open(catalog_root).table("lab", "events")
        offline.columns.find { |column| column.name == "payload" }.not_nil!.type.should eq(type_name)
        selection_values = offline["payload"].values(max_rows: 16_u64, max_string_bytes: 1024_u64, max_tuple_cells: 256_u64)
        catalog_values = selection_values.map(&.as(CrystalClick::WideGeoArrayRow))
        catalog_values.size.should eq(W111_CONSUMER_KEYS.size)
        w111c_check_rows(catalog_values, fixture)
        retained_catalog_row = catalog_values[0]

        catalog_rows = [] of CrystalClick::WideGeoArrayRow
        offline.scan_typed(["pk", "payload"], batch_rows: 2) do |batch|
          batch.column_type_for("payload").should eq(type_name)
          rows = batch.geo_array_rows_for("payload")
          w111c_check_rows(rows, fixture, catalog_rows.size.to_i32)
          rows.each { |row| catalog_rows << row }
          retained_catalog_row.type_name.should eq(type_name)
          w111c_check_row(retained_catalog_row, fixture, 0, 0)
          nil
        end
        catalog_rows.size.should eq(W111_CONSUMER_KEYS.size)

        catalog_window = [] of CrystalClick::WideGeoArrayRow
        offline.scan_typed_window(["pk", "payload"], 2_u64, 2) do |batch|
          batch.column_type_for("payload").should eq(type_name)
          rows = batch.geo_array_rows_for("payload")
          w111c_check_rows(rows, fixture, 2)
          rows.each { |row| catalog_window << row }
          nil
        end
        catalog_window.size.should eq(2)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
