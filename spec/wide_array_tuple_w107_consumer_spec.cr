require "./spec_helper"
require "file_utils"

private def w107c_nullable_string_column(name : String, values : Array(String), nulls : Array(UInt8)) : CrystalClick::WideTupleLeafColumn
  leaf_type = CrystalClick::WideTupleLeafType.parse("Nullable(String)").not_nil!
  null_map = CrystalClick::ScalarNullMap.new(nulls.to_unsafe.to_slice(nulls.size), values.size.to_u64)
  CrystalClick::WideTupleLeafColumn.new(name, leaf_type, values, null_map)
end

private def w107c_write_part(parent : String) : {String, String, Array(UInt64)}
  type_name = "Array(Tuple(id UInt64, details Tuple(note Nullable(String), score UInt64)))"
  row_sizes = [0_u64, 2_u64, 0_u64, 1_u64, 0_u64]
  columns = [
    CrystalClick::WideTupleLeafColumn.new("id", [101_u64, 102_u64, 103_u64] of UInt64),
    w107c_nullable_string_column("details.note", ["alpha", "hidden", "omega"] of String, [0_u8, 1_u8, 0_u8]),
    CrystalClick::WideTupleLeafColumn.new("details.score", [7_u64, 8_u64, 9_u64] of UInt64),
  ] of CrystalClick::WideTupleLeafColumn
  container = File.join(parent, "parts")
  Dir.mkdir(container)
  part = File.join(container, "all_1_1_0")
  keys = [10_u64, 20_u64, 30_u64, 40_u64, 50_u64]
  CrystalClick::WidePartWriter.write_uint64_array_tuple_part(
    part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", type_name,
    row_sizes.to_unsafe.to_slice(row_sizes.size), columns, 2
  )
  {part, type_name, row_sizes}
end

private def w107c_offline_root(parent : String, part : String, type_name : String) : String
  root = File.join(parent, "catalog")
  metadata = File.join(root, "metadata")
  database_uuid = "10700000-0000-4000-8000-000000000001"
  table_uuid = "10700000-0000-4000-8000-000000000002"
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
  # Spec-only hook for the actual aggregate mark charge enforced by the table
  # adapter, including its retained row-array header.
  def self.w107_test_array_tuple_table_charge(
    reader : WidePart,
    column : String,
    mark_index : Int32,
    max_bytes : UInt64,
  ) : UInt64
    ArrayTupleColumnAdapter.preflight_mark_charge(reader, column, mark_index, max_bytes)
  end
end

describe "W107 Array(Tuple) table and catalog consumers" do
  it "preserves the outer-row axis and nested Nullable elements through full, window, and values APIs" do
    parent = File.tempname("crystal-click-array-tuple-w107-consumers")
    Dir.mkdir(parent)

    begin
      part, type_name, sizes = w107c_write_part(parent)
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      full_rows = [] of CrystalClick::WideArrayTupleRow
      table.scan_typed(batch_rows: 2) do |batch|
        batch.array_tuple_rows_for("payload").each { |row| full_rows << row }
        nil
      end

      full_rows.size.should eq(5)
      full_rows.map(&.size).should eq(sizes.map(&.to_i32))
      full_rows[1][0]["id"].should eq(101_u64)
      full_rows[1][0].tuple("details")["note"].should eq("alpha")
      full_rows[1][1]["id"].should eq(102_u64)
      full_rows[1][1].tuple("details")["note"].should be_nil
      full_rows[3][0].tuple("details")["note"].should eq("omega")

      window_rows = [] of CrystalClick::WideArrayTupleRow
      table.scan_typed_window(1_u64, 3) do |batch|
        batch.array_tuple_rows_for("payload").each { |row| window_rows << row }
        nil
      end
      window_rows.map(&.size).should eq([2_i32, 0_i32, 1_i32])
      window_rows[0][1].tuple("details")["note"].should be_nil
      window_rows[2][0]["id"].should eq(103_u64)

      catalog_root = w107c_offline_root(parent, part, type_name)
      offline = CrystalClick::OfflineCatalog.open(catalog_root)["lab"]["events"]
      materialized = offline["payload"].values(max_tuple_cells: 9_u64)
      materialized_rows = materialized.map(&.as(CrystalClick::WideArrayTupleRow))
      materialized_rows.map(&.size).should eq(sizes.map(&.to_i32))
      materialized_rows[1][1].tuple("details")["note"].should be_nil
      materialized_rows[3][0]["id"].should eq(103_u64)
      expect_raises(CrystalClick::BoundsError, "selected column materialization exceeds Tuple cell limit") do
        offline["payload"].values(max_tuple_cells: 8_u64)
      end

      catalog_scan = [] of CrystalClick::WideArrayTupleRow
      offline.scan_typed(["pk", "payload"], batch_rows: 2) do |batch|
        batch.array_tuple_rows_for("payload").each { |row| catalog_scan << row }
        nil
      end
      catalog_scan.map(&.size).should eq(sizes.map(&.to_i32))
      catalog_window = [] of CrystalClick::WideArrayTupleRow
      offline.scan_typed_window(["pk", "payload"], 1_u64, 3) do |batch|
        batch.array_tuple_rows_for("payload").each { |row| catalog_window << row }
        nil
      end
      catalog_window.map(&.size).should eq([2_i32, 0_i32, 1_i32])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "enforces an exact aggregate table mark charge including the table row-array header" do
    parent = File.tempname("crystal-click-array-tuple-w107-table-charge")
    Dir.mkdir(parent)
    begin
      part, _type_name, _sizes = w107c_write_part(parent)
      reader = CrystalClick::WidePart.open_typed(part, "payload")
      wide_limit = CrystalClick::WideTupleTypePlan::MAX_MATERIALIZED_BYTES
      reader_charge = reader.array_tuple_mark_range_materialization_charge("payload", 0, 1, wide_limit)
      table_header = instance_sizeof(Array(CrystalClick::WideArrayTupleRow)).to_u64
      independently_derived_charge = reader_charge + table_header
      exact_charge = CrystalClick::WidePartTable.w107_test_array_tuple_table_charge(
        reader, "payload", 0, wide_limit
      )
      exact_charge.should eq(independently_derived_charge)
      CrystalClick::WidePartTable.w107_test_array_tuple_table_charge(
        reader, "payload", 0, exact_charge
      ).should eq(exact_charge)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartTable.w107_test_array_tuple_table_charge(
          reader, "payload", 0, exact_charge - 1_u64
        )
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
