require "./spec_helper"
require "file_utils"

private def w105c_nullable_column(
  name : String,
  base_type_name : String,
  physical_values : CrystalClick::WideTupleLeafColumn::Buffer,
  null_bytes : Array(UInt8),
) : CrystalClick::WideTupleLeafColumn
  leaf_type = CrystalClick::WideTupleLeafType.parse("Nullable(#{base_type_name})") ||
              raise "invalid W105 consumer leaf type: #{base_type_name}"
  null_map = CrystalClick::ScalarNullMap.new(
    null_bytes.to_unsafe.to_slice(null_bytes.size), physical_values.size.to_u64
  )
  CrystalClick::WideTupleLeafColumn.new(name, leaf_type, physical_values, null_map)
end

private def w105c_columns : Array(CrystalClick::WideTupleLeafColumn)
  enum_type = "Enum8('minus' = -7, 'plus' = 4)"
  [
    w105c_nullable_column("count", "UInt64", [999_u64, 0_u64, 7_u64, 888_u64, 9_u64] of UInt64, [1_u8, 0_u8, 0_u8, 1_u8, 0_u8]),
    w105c_nullable_column("text", "String", ["hidden", "", "middle", "masked", "tail"] of String, [1_u8, 0_u8, 0_u8, 1_u8, 0_u8]),
    w105c_nullable_column(
      "stamp", "DateTime64(3, 'US/Eastern')",
      [
        CrystalClick::DateTime64Value.new(1111_i64, 3),
        CrystalClick::DateTime64Value.new(-17_i64, 3),
        CrystalClick::DateTime64Value.new(Int64::MIN, 3),
        CrystalClick::DateTime64Value.new(42_i64, 3),
        CrystalClick::DateTime64Value.new(Int64::MAX, 3),
      ] of CrystalClick::DateTime64Value,
      [1_u8, 0_u8, 0_u8, 1_u8, 0_u8]
    ),
    w105c_nullable_column("status", enum_type, [127_i8, -7_i8, 4_i8, -128_i8, 4_i8] of Int8, [1_u8, 0_u8, 0_u8, 1_u8, 0_u8]),
    w105c_nullable_column("amount", "Decimal(9, 2)", [Int32::MIN, 100_i32, -22_i32, Int32::MAX, 0_i32] of Int32, [1_u8, 0_u8, 0_u8, 1_u8, 0_u8]),
    w105c_nullable_column("flag", "Bool", [99_u8, 0_u8, 2_u8, 255_u8, 0_u8] of UInt8, [1_u8, 0_u8, 0_u8, 1_u8, 0_u8]),
    w105c_nullable_column(
      "id", "UUID",
      [
        CrystalClick::UUIDValue.new(1_u64, 11_u64),
        CrystalClick::UUIDValue.new(2_u64, 22_u64),
        CrystalClick::UUIDValue.new(3_u64, 33_u64),
        CrystalClick::UUIDValue.new(4_u64, 44_u64),
        CrystalClick::UUIDValue.new(5_u64, 55_u64),
      ] of CrystalClick::UUIDValue,
      [1_u8, 0_u8, 1_u8, 0_u8, 0_u8]
    ),
    w105c_nullable_column(
      "fixed", "FixedString(3)",
      [
        CrystalClick::FixedStringValue.from_raw(3, Bytes[0x61_u8, 0xff_u8, 0_u8]),
        CrystalClick::FixedStringValue.new(3, ""),
        CrystalClick::FixedStringValue.from_raw(3, Bytes[0x62_u8, 0_u8, 0_u8]),
        CrystalClick::FixedStringValue.from_raw(3, Bytes[0xff_u8, 0_u8, 0x63_u8]),
        CrystalClick::FixedStringValue.new(3, "z"),
      ] of CrystalClick::FixedStringValue,
      [1_u8, 0_u8, 0_u8, 1_u8, 0_u8]
    ),
  ] of CrystalClick::WideTupleLeafColumn
end

private def w105c_type_name(columns : Array(CrystalClick::WideTupleLeafColumn)) : String
  "Tuple(#{columns.map { |column| "#{column.name} #{column.type_name}" }.join(", ")})"
end

private def w105c_assert_row(row : CrystalClick::WideTupleRow, index : Int32) : Nil
  row.type_name.should eq(
    "Tuple(count Nullable(UInt64), text Nullable(String), stamp Nullable(DateTime64(3, 'US/Eastern')), " +
    "status Nullable(Enum8('minus' = -7, 'plus' = 4)), amount Nullable(Decimal(9, 2)), " +
    "flag Nullable(Bool), id Nullable(UUID), fixed Nullable(FixedString(3)))"
  )
  row.fields.map { |field| {field.name, field.type_name} }.should eq([
    {"count", "Nullable(UInt64)"},
    {"text", "Nullable(String)"},
    {"stamp", "Nullable(DateTime64(3, 'US/Eastern'))"},
    {"status", "Nullable(Enum8('minus' = -7, 'plus' = 4))"},
    {"amount", "Nullable(Decimal(9, 2))"},
    {"flag", "Nullable(Bool)"},
    {"id", "Nullable(UUID)"},
    {"fixed", "Nullable(FixedString(3))"},
  ])

  if index == 0 || index == 3
    row["count"].should be_nil
    row["text"].should be_nil
    row["stamp"].should be_nil
    row["status"].should be_nil
    row["amount"].should be_nil
    row["flag"].should be_nil
    row["fixed"].should be_nil
  end

  case index
  when 0
    row["id"].should be_nil
  when 1
    row["count"].should eq(0_u64)
    row["text"].should eq("")
    row["stamp"].as(CrystalClick::DateTime64Value).should eq(CrystalClick::DateTime64Value.new(-17_i64, 3))
    row["status"].as(CrystalClick::Enum8Value).code.should eq(-7_i8)
    row["amount"].as(CrystalClick::Decimal32Value).raw.should eq(100_i32)
    row["flag"].should eq(false)
    row["id"].as(CrystalClick::UUIDValue).should eq(CrystalClick::UUIDValue.new(2_u64, 22_u64))
    row["fixed"].as(CrystalClick::FixedStringValue).raw_bytes.should eq(Bytes[0_u8, 0_u8, 0_u8])
  when 2
    row["count"].should eq(7_u64)
    row["text"].should eq("middle")
    row["stamp"].as(CrystalClick::DateTime64Value).should eq(CrystalClick::DateTime64Value.new(Int64::MIN, 3))
    row["status"].as(CrystalClick::Enum8Value).label.should eq("plus")
    row["amount"].as(CrystalClick::Decimal32Value).raw.should eq(-22_i32)
    row["flag"].should eq(true)
    row["id"].should be_nil
    row["fixed"].as(CrystalClick::FixedStringValue).raw_bytes.should eq(Bytes[0x62_u8, 0_u8, 0_u8])
  when 3
    row["id"].as(CrystalClick::UUIDValue).should eq(CrystalClick::UUIDValue.new(4_u64, 44_u64))
  when 4
    row["count"].should eq(9_u64)
    row["text"].should eq("tail")
    row["stamp"].as(CrystalClick::DateTime64Value).should eq(CrystalClick::DateTime64Value.new(Int64::MAX, 3))
    row["status"].as(CrystalClick::Enum8Value).code.should eq(4_i8)
    row["amount"].as(CrystalClick::Decimal32Value).raw.should eq(0_i32)
    row["flag"].should eq(false)
    row["id"].as(CrystalClick::UUIDValue).should eq(CrystalClick::UUIDValue.new(5_u64, 55_u64))
    row["fixed"].as(CrystalClick::FixedStringValue).raw_bytes.should eq(Bytes[0x7a_u8, 0_u8, 0_u8])
  else
    raise "unexpected W105 row index"
  end
end

private def w105c_offline_catalog_root(parent : String, part : String, type_name : String) : String
  root = File.join(parent, "catalog")
  metadata = File.join(root, "metadata")
  database_uuid = "10500000-0000-4000-8000-000000000001"
  table_uuid = "10500000-0000-4000-8000-000000000002"
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
  copied_part = File.join(table, "all_1_1_0")
  FileUtils.cp_r(part, copied_part)
  root
end

describe "W105 nullable named-flat Tuple reader and consumers" do
  it "preserves exact leaf descriptors, physical hidden values, and logical Nil across reader, table, and catalog APIs" do
    parent = File.tempname("crystal-click-w105-nullable-consumers")
    Dir.mkdir(parent)
    columns = w105c_columns
    type_name = w105c_type_name(columns)
    keys = [10_u64, 20_u64, 30_u64, 40_u64, 50_u64]
    part = File.join(parent, "all_1_1_0")

    begin
      CrystalClick::WidePartWriter.write_uint64_tuple_pair(
        part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", type_name, columns, rows_per_mark: 2
      ).should eq(part)

      reader = CrystalClick::WidePart.open_typed(part, "payload")
      reader.column_type.should eq(type_name)
      reader.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
      data = reader.read_tuple_mark_range("payload", 0, reader.mark_count)
      data.type_name.should eq(type_name)
      data.row_count.should eq(keys.size)
      data.fields.map { |field| {field.name, field.type_name} }.should eq(columns.map { |column| {column.name, column.type_name} })
      data.columns.map(&.null_map).each { |null_map| null_map.not_nil!.size.should eq(keys.size) }
      data["text"].physical_values.as(Array(String)).should eq(["hidden", "", "middle", "masked", "tail"])
      data["text"].null_map.not_nil!.bytes.should eq([1_u8, 0_u8, 0_u8, 1_u8, 0_u8])
      data["stamp"].datetime_type.not_nil!.time_zone?.not_nil!.name.should eq("US/Eastern")
      data["stamp"].datetime_type.not_nil!.precision?.should eq(3_u8)
      expect_raises(CrystalClick::UnsupportedFormatError) { data["count"].uint64_values }
      5.times { |index| w105c_assert_row(data.row(index), index) }

      selected = reader.read_tuple_mark_range("payload", 1, 1)
      selected.row_count.should eq(2)
      w105c_assert_row(selected.row(0), 2)
      w105c_assert_row(selected.row(1), 3)

      mark_indices = [] of Int32
      each_rows = [] of CrystalClick::WideTupleRow
      reader.each_tuple_mark_range("payload", 0, reader.mark_count) do |mark_data, mark_index|
        mark_indices << mark_index
        mark_data.row_count.times { |index| each_rows << mark_data.row(index) }
      end
      mark_indices.should eq([0_i32, 1_i32, 2_i32])
      each_rows.each_with_index { |row, index| w105c_assert_row(row, index.to_i32) }

      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      table_seen = [] of CrystalClick::WideTupleRow
      table.scan_typed(batch_rows: 3) do |batch|
        batch.values_for("pk").each_with_index do |key, offset|
          key.should eq(keys[table_seen.size])
          table_seen << batch.tuple_rows_for("payload")[offset]
        end
      end
      table_seen.size.should eq(keys.size)
      table_seen.each_with_index { |row, index| w105c_assert_row(row, index.to_i32) }

      window_seen = [] of CrystalClick::WideTupleRow
      table.scan_typed_window(1_u64, 3) do |batch|
        batch.tuple_rows_for("payload").each { |row| window_seen << row }
      end
      window_seen.size.should eq(3)
      window_seen.each_with_index { |row, offset| w105c_assert_row(row, offset + 1) }

      catalog_root = w105c_offline_catalog_root(parent, part, type_name)
      offline_table = CrystalClick::OfflineCatalog.open(catalog_root)["lab"]["events"]
      materialized = offline_table["payload"].values(max_tuple_cells: 40_u64)
      materialized_rows = materialized.map(&.as(CrystalClick::WideTupleRow))
      materialized_rows.size.should eq(keys.size)
      materialized_rows.each_with_index { |row, index| w105c_assert_row(row, index.to_i32) }

      # The hidden String slots still count toward materialization limits even
      # though their logical values are nil.
      expect_raises(CrystalClick::BoundsError) do
        offline_table["payload"].values(max_tuple_cells: 39_u64)
      end
      expect_raises(CrystalClick::BoundsError) do
        offline_table["payload"].values(max_string_bytes: 21_u64)
      end

      catalog_seen = [] of CrystalClick::WideTupleRow
      offline_table.scan_typed(["pk", "payload"], batch_rows: 3) do |batch|
        batch.tuple_rows_for("payload").each { |row| catalog_seen << row }
      end
      catalog_seen.size.should eq(keys.size)
      catalog_seen.each_with_index { |row, index| w105c_assert_row(row, index.to_i32) }

      catalog_window = [] of CrystalClick::WideTupleRow
      offline_table.scan_typed_window(["pk", "payload"], 1_u64, 3) do |batch|
        batch.tuple_rows_for("payload").each { |row| catalog_window << row }
      end
      catalog_window.size.should eq(3)
      catalog_window.each_with_index { |row, offset| w105c_assert_row(row, offset + 1) }
    ensure
      FileUtils.rm_rf(parent) if Dir.exists?(parent)
    end
  end
end
