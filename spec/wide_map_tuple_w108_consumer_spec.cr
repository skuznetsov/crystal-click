require "./spec_helper"
require "file_utils"

private def w108c_write_part(parent : String) : {String, String, Array(UInt64)}
  type_name = "Map(String, Tuple(meta Tuple(note Nullable(String), id UInt64), at DateTime64(3, 'America/New_York')))"
  row_sizes = [0_u64, 2_u64, 0_u64, 1_u64, 0_u64]
  container = File.join(parent, "parts")
  FileUtils.mkdir_p(container)
  part = File.join(container, "all_1_1_0")
  keys = [10_u64, 20_u64, 30_u64, 40_u64, 50_u64]
  map_keys = CrystalClick::WideTupleLeafColumn.new("keys", ["dup", "dup", "\0key"] of String)
  nullable_type = CrystalClick::WideTupleLeafType.parse("Nullable(String)").not_nil!
  mask = CrystalClick::ScalarNullMap.new(Bytes[0_u8, 1_u8, 0_u8], 3_u64)
  columns = [
    CrystalClick::WideTupleLeafColumn.new("meta.note", nullable_type, ["alpha", "hidden", "omega"] of String, mask),
    CrystalClick::WideTupleLeafColumn.new("meta.id", [101_u64, 102_u64, 103_u64] of UInt64),
    CrystalClick::WideTupleLeafColumn.new(
      "at",
      CrystalClick::WideTupleLeafType.parse("DateTime64(3, 'America/New_York')").not_nil!,
      [CrystalClick::DateTime64Value.new(1_234_567_i64, 3), CrystalClick::DateTime64Value.new(0_i64, 3), CrystalClick::DateTime64Value.new(Int64::MIN, 3)] of CrystalClick::DateTime64Value,
      nil
    ),
  ] of CrystalClick::WideTupleLeafColumn
  CrystalClick::WidePartWriter.write_uint64_map_tuple_part(
    part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", type_name,
    row_sizes.to_unsafe.to_slice(row_sizes.size), map_keys, columns, 2
  )
  {part, type_name, row_sizes}
end

private def w108c_offline_root(parent : String, part : String, type_name : String) : String
  root = File.join(parent, "catalog")
  metadata = File.join(root, "metadata")
  database_uuid = "10800000-0000-4000-8000-000000000001"
  table_uuid = "10800000-0000-4000-8000-000000000002"
  database = File.join(root, "store", database_uuid[0, 3], database_uuid)
  table = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(metadata)
  FileUtils.mkdir_p(database)
  FileUtils.mkdir_p(table)
  File.write(File.join(metadata, "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  File.write(
    File.join(database, "events.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `pk` UInt64,\n    `payload` #{type_name}\n)\nENGINE = MergeTree\nORDER BY pk\n"
  )
  File.write(File.join(table, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table, "detached"))
  FileUtils.cp_r(part, File.join(table, "all_1_1_0"))
  root
end

class CrystalClick::WidePartTable
  def self.w108_test_map_tuple_table_charge(
    reader : WidePart,
    column : String,
    mark_index : Int32,
    limit : UInt64,
  ) : UInt64
    MapTupleColumnAdapter.preflight_mark_charge(
      reader, column, mark_index, reader.mark_row_counts[mark_index].to_u64, limit
    )
  end
end

describe "W108 Map(Tuple) table and catalog consumers" do
  it "retains ordered entries and nested Nullable values through full/window/catalog scans and values" do
    parent = File.tempname("crystal-click-map-tuple-w108-consumers")
    Dir.mkdir(parent)

    begin
      part, type_name, sizes = w108c_write_part(parent)
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      full_rows = [] of CrystalClick::WideMapTupleRow
      table.scan_typed(batch_rows: 2) do |batch|
        batch.map_tuple_rows_for("payload").each { |row| full_rows << row }
        nil
      end

      full_rows.size.should eq(5)
      full_rows.map(&.size).should eq(sizes.map(&.to_i32))
      full_rows[1].key_at(0).should eq("dup")
      full_rows[1].key_at(1).should eq("dup")
      full_rows[1].value_at(0).tuple("meta").value_as("id", UInt64).should eq(101_u64)
      full_rows[1].value_at(1).tuple("meta")["note"].should be_nil
      full_rows[3].value_at(0).tuple("meta")["note"].should eq("omega")

      window_rows = [] of CrystalClick::WideMapTupleRow
      table.scan_typed_window(1_u64, 3) do |batch|
        batch.map_tuple_rows_for("payload").each { |row| window_rows << row }
        nil
      end
      window_rows.map(&.size).should eq([2_i32, 0_i32, 1_i32])
      window_rows[0].value_at(1).tuple("meta")["note"].should be_nil
      window_rows[2].key_at(0).should eq("\0key")

      catalog_root = w108c_offline_root(parent, part, type_name)
      offline = CrystalClick::OfflineCatalog.open(catalog_root)["lab"]["events"]
      selected = offline["payload"]
      materialized = selected.values(max_tuple_cells: 9_u64, max_string_bytes: 26_u64)
      values = materialized.map(&.as(CrystalClick::WideMapTupleRow))
      values.map(&.size).should eq(sizes.map(&.to_i32))
      values[1].key_at(0).should eq("dup")
      values[1].key_at(1).should eq("dup")
      values[1].value_at(1).tuple("meta")["note"].should be_nil
      values[3].value_at(0).tuple("meta").value_as("id", UInt64).should eq(103_u64)
      expect_raises(CrystalClick::BoundsError, "selected column materialization exceeds Tuple cell limit") do
        selected.values(max_tuple_cells: 8_u64)
      end
      expect_raises(CrystalClick::BoundsError, "selected column materialization exceeds String payload limit") do
        selected.values(max_tuple_cells: 9_u64, max_string_bytes: 25_u64)
      end

      catalog_scan = [] of CrystalClick::WideMapTupleRow
      offline.scan_typed(["pk", "payload"], batch_rows: 2) do |batch|
        batch.map_tuple_rows_for("payload").each { |row| catalog_scan << row }
        nil
      end
      catalog_scan.map(&.size).should eq(sizes.map(&.to_i32))
      catalog_window = [] of CrystalClick::WideMapTupleRow
      offline.scan_typed_window(["pk", "payload"], 1_u64, 3) do |batch|
        batch.map_tuple_rows_for("payload").each { |row| catalog_window << row }
        nil
      end
      catalog_window.map(&.size).should eq([2_i32, 0_i32, 1_i32])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "enforces one exact table budget for the reader result plus retained row handles" do
    parent = File.tempname("crystal-click-map-tuple-w108-table-charge")
    Dir.mkdir(parent)

    begin
      part, _type_name, _sizes = w108c_write_part(parent)
      reader = CrystalClick::WidePart.open_typed(part, "payload")
      wide_limit = CrystalClick::WideTupleTypePlan::MAX_MATERIALIZED_BYTES
      reader_charge = reader.map_tuple_mark_range_materialization_charge("payload", 0, 1, wide_limit)
      table_header = instance_sizeof(Array(CrystalClick::WideMapTupleRow)).to_u64
      table_slots = reader.mark_row_counts[0].to_u64 * sizeof(CrystalClick::WideMapTupleRow).to_u64
      independently_derived_charge = reader_charge + table_header + table_slots

      exact_charge = CrystalClick::WidePartTable.w108_test_map_tuple_table_charge(
        reader, "payload", 0, wide_limit
      )
      exact_charge.should eq(independently_derived_charge)
      CrystalClick::WidePartTable.w108_test_map_tuple_table_charge(
        reader, "payload", 0, exact_charge
      ).should eq(exact_charge)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartTable.w108_test_map_tuple_table_charge(
          reader, "payload", 0, exact_charge - 1_u64
        )
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
