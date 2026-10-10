require "./spec_helper"
require "file_utils"

private def w95_offline_tuple_type(columns : Array(CrystalClick::WideTupleLeafColumn)) : String
  "Tuple(#{columns.map { |column| "#{column.name} #{column.type_name}" }.join(", ")})"
end

private def w95_with_offline_tuple_catalog(
  keys : Array(UInt64),
  columns : Array(CrystalClick::WideTupleLeafColumn),
  ddl_type_name : String? = nil,
  &
) : Nil
  root = File.tempname("crystal-click-offline-catalog-w95-tuple-values")
  Dir.mkdir(root)

  begin
    metadata_path = File.join(root, "metadata")
    FileUtils.mkdir_p(metadata_path)
    FileUtils.mkdir_p(File.join(root, "store"))

    database_uuid = "95000000-0000-4000-8000-000000000001"
    table_uuid = "95000000-0000-4000-8000-000000000002"
    File.write(
      File.join(metadata_path, "lab.sql"),
      "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n"
    )

    database_path = File.join(root, "store", database_uuid[0, 3], database_uuid)
    FileUtils.mkdir_p(database_path)
    type_name = w95_offline_tuple_type(columns)
    declared_type_name = ddl_type_name || type_name
    File.write(
      File.join(database_path, "events.sql"),
      "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `pk` UInt64,\n    `payload` #{declared_type_name}\n)\nENGINE = MergeTree\nORDER BY pk\n"
    )

    table_path = File.join(root, "store", table_uuid[0, 3], table_uuid)
    FileUtils.mkdir_p(table_path)
    File.write(File.join(table_path, "format_version.txt"), "1\n")
    Dir.mkdir(File.join(table_path, "detached"))

    part = File.join(table_path, "all_1_1_0")
    CrystalClick::WidePartWriter.write_uint64_tuple_pair(
      part,
      "pk",
      keys.to_unsafe.to_slice(keys.size),
      "payload",
      type_name,
      columns,
      rows_per_mark: 2
    )

    yield root, part
  ensure
    FileUtils.rm_rf(root)
  end
end

describe "W95 offline catalog named Tuple values" do
  it "materializes a library-written String-first named Tuple column" do
    keys = [10_u64, 20_u64, 30_u64, 40_u64, 50_u64, 60_u64, 70_u64]
    c_values = [
      "c0", String.new(Bytes[0x00_u8, 0xff_u8]), "", "c3", "c4", "c5", "c6",
    ] of String
    a_values = [101_u64, 102_u64, 103_u64, 104_u64, 105_u64, 106_u64, 107_u64]
    b_values = [
      "b0", "", String.new(Bytes[0x61_u8, 0x00_u8, 0x62_u8]), "b3", "b4", "b5", "",
    ] of String
    columns = [
      CrystalClick::WideTupleLeafColumn.new("c", c_values),
      CrystalClick::WideTupleLeafColumn.new("a", a_values),
      CrystalClick::WideTupleLeafColumn.new("b", b_values),
    ] of CrystalClick::WideTupleLeafColumn

    w95_with_offline_tuple_catalog(keys, columns) do |root, part|
      low_level = CrystalClick::WidePart.open_typed(part, "payload")
      low_level.mark_count.should eq(4)
      mark_row_counts = [0, 1, 2, 3].map do |mark_index|
        low_level.read_tuple_mark_range("payload", mark_index, 1).row_count
      end
      mark_row_counts.should eq([2, 2, 2, 1])
      low_level_data = low_level.read_tuple_mark_range("payload", 0, low_level.mark_count)
      low_level_data.row_count.should eq(7)
      low_level_data["c"].string_values.should eq(c_values)
      low_level_data["a"].uint64_values.should eq(a_values)
      low_level_data["b"].string_values.should eq(b_values)

      catalog = CrystalClick::OfflineCatalog.open(root)
      table = catalog["lab"]["events"]
      selected = table["payload"]
      materialized = selected.values(max_string_bytes: 23_u64, max_tuple_cells: 21_u64)
      rows = materialized.map(&.as(CrystalClick::WideTupleRow))
      rows.size.should eq(7)
      rows.first.type_name.should eq(w95_offline_tuple_type(columns))
      rows.first.fields.map(&.name).should eq(["c", "a", "b"])
      rows.map { |row| row["c"].as(String) }.should eq(c_values)
      rows.map { |row| row["a"].as(UInt64) }.should eq(a_values)
      rows.map { |row| row["b"].as(String) }.should eq(b_values)

      string_limit_error = expect_raises(CrystalClick::BoundsError) { selected.values(max_string_bytes: 22_u64) }
      string_limit_error.message.should eq("selected column materialization exceeds String payload limit")
      cell_limit_error = expect_raises(CrystalClick::BoundsError) { selected.values(max_tuple_cells: 20_u64) }
      cell_limit_error.message.should eq("selected column materialization exceeds Tuple cell limit")

      # Full/window scans retain independently checked physical row pairing;
      # returned catalog rows remain usable after later callbacks finish.
      full_scan = [] of Tuple(UInt64, String, UInt64, String)
      table.scan_typed_window(["pk", "payload"], 0_u64) do |batch|
        keys_for_batch = batch.values_for("pk")
        batch.tuple_rows_for("payload").each_with_index do |row, index|
          full_scan << {
            keys_for_batch[index],
            row["c"].as(String),
            row["a"].as(UInt64),
            row["b"].as(String),
          }
        end
      end
      full_scan.should eq([
        {10_u64, "c0", 101_u64, "b0"},
        {20_u64, String.new(Bytes[0x00_u8, 0xff_u8]), 102_u64, ""},
        {30_u64, "", 103_u64, String.new(Bytes[0x61_u8, 0x00_u8, 0x62_u8])},
        {40_u64, "c3", 104_u64, "b3"},
        {50_u64, "c4", 105_u64, "b4"},
        {60_u64, "c5", 106_u64, "b5"},
        {70_u64, "c6", 107_u64, ""},
      ])

      window_scan = [] of Tuple(UInt64, String, UInt64, String)
      table.scan_typed_window(["pk", "payload"], 2_u64, 3) do |batch|
        keys_for_batch = batch.values_for("pk")
        batch.tuple_rows_for("payload").each_with_index do |row, index|
          window_scan << {
            keys_for_batch[index],
            row["c"].as(String),
            row["a"].as(UInt64),
            row["b"].as(String),
          }
        end
      end
      window_scan.should eq(full_scan[2, 3])

      exposed = rows[1]["c"].as(String)
      exposed.to_unsafe[0] = 0x5a_u8
      rows[1]["c"].as(String).should eq(c_values[1])
      materialized << 999_u64
      selected.values.size.should eq(7)
      rows[0]["b"].as(String).should eq("b0")
    end
  end

  it "materializes supported one-, two-, three-, and nine-field row profiles" do
    profiles = [] of Array(CrystalClick::WideTupleLeafColumn)
    profiles << [
      CrystalClick::WideTupleLeafColumn.new("s", [""] of String),
    ]
    profiles << [
      CrystalClick::WideTupleLeafColumn.new("s", ["two"] of String),
      CrystalClick::WideTupleLeafColumn.new("n", [2_u64]),
    ]
    profiles << [
      CrystalClick::WideTupleLeafColumn.new("s0", [""] of String),
      CrystalClick::WideTupleLeafColumn.new("n1", [11_u64]),
      CrystalClick::WideTupleLeafColumn.new("s2", ["three"] of String),
    ]
    profiles << [
      CrystalClick::WideTupleLeafColumn.new("s0", [""] of String),
      CrystalClick::WideTupleLeafColumn.new("n1", [21_u64]),
      CrystalClick::WideTupleLeafColumn.new("s2", ["nine"] of String),
      CrystalClick::WideTupleLeafColumn.new("n3", [23_u64]),
      CrystalClick::WideTupleLeafColumn.new("s4", [""] of String),
      CrystalClick::WideTupleLeafColumn.new("n5", [25_u64]),
      CrystalClick::WideTupleLeafColumn.new("s6", ["tail"] of String),
      CrystalClick::WideTupleLeafColumn.new("n7", [27_u64]),
      CrystalClick::WideTupleLeafColumn.new("s8", [""] of String),
    ]

    profiles.each do |columns|
      w95_with_offline_tuple_catalog([7_u64], columns) do |root, _part|
        selection = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]["payload"]
        field_count = columns.size.to_u64
        expect_raises(CrystalClick::BoundsError) do
          selection.values(max_tuple_cells: field_count - 1_u64)
        end
        values = selection.values(max_tuple_cells: field_count)
        values.size.should eq(1)
        row = values.first.as(CrystalClick::WideTupleRow)
        row.field_count.should eq(columns.size)
        row.fields.map(&.name).should eq(columns.map(&.name))
        row.type_name.should eq(w95_offline_tuple_type(columns))
        columns.each do |column|
          if column.type_name == "String"
            row[column.name].as(String).should eq(column.string_values[0])
          else
            row[column.name].as(UInt64).should eq(column.uint64_values[0])
          end
        end
      end
    end
  end

  it "dispatches a parseable noncanonical exact-pair spelling through the row API" do
    keys = [7_u64, 11_u64, 19_u64]
    strings = ["first", "", "tail"] of String
    columns = [
      CrystalClick::WideTupleLeafColumn.new("a", keys),
      CrystalClick::WideTupleLeafColumn.new("b", strings),
    ] of CrystalClick::WideTupleLeafColumn
    canonical_type = w95_offline_tuple_type(columns)
    raw_type = "Tuple( a UInt64, b String )"

    plan = CrystalClick::WideTupleTypePlan.for_type(raw_type).not_nil!
    plan.type_name.should eq(canonical_type)
    CrystalClick::WidePart.supports_tuple_uint64_string_type?(raw_type).should be_false

    w95_with_offline_tuple_catalog(keys, columns, raw_type) do |root, part|
      columns_path = File.join(part, "columns.txt")
      columns_text = File.read(columns_path)
      canonical_line = "`payload` #{canonical_type}\n"
      raw_line = "`payload` #{raw_type}\n"
      columns_text.should contain(canonical_line)
      File.write(columns_path, columns_text.sub(canonical_line, raw_line))
      File.read(columns_path).should contain(raw_line)

      physical = CrystalClick::WidePart.open_typed(part, "payload")
      physical.column_type.should eq(raw_type)
      physical.read_tuple_mark_range("payload", 0, physical.mark_count).row_count.should eq(3)

      values = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]["payload"].values
      rows = values.map(&.as(CrystalClick::WideTupleRow))
      rows.map { |row| row["a"].as(UInt64) }.should eq(keys)
      rows.map { |row| row["b"].as(String) }.should eq(strings)
    end
  end

  it "validates Tuple cell caps before synthetic catalog delegation" do
    keys = [10_u64]
    columns = [CrystalClick::WideTupleLeafColumn.new("s", [""] of String)]
    w95_with_offline_tuple_catalog(keys, columns) do |root, _part|
      catalog = CrystalClick::OfflineCatalog.open(root)
      synthetic = catalog["system"]["part_candidates"]["name"]
      error = expect_raises(CrystalClick::BoundsError) do
        synthetic.values(max_tuple_cells: CrystalClick::OfflineTable::MAX_MATERIALIZED_VALUES_TUPLE_CELLS + 1_u64)
      end
      error.message.should eq("selected column Tuple cell limit exceeds hard limit")
    end
  end

  it "rejects incompatible and unsupported Tuple DDL before materializing rows" do
    columns = [CrystalClick::WideTupleLeafColumn.new("s", ["value"] of String)]

    w95_with_offline_tuple_catalog([7_u64], columns, "Tuple(other String)") do |root, _part|
      selection = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]["payload"]
      error = expect_raises(CrystalClick::UnsupportedFormatError) { selection.values }
      error.message.should eq("table DDL and selected part column types differ")
    end

    admitted_array_tuple = "Tuple(s Array(String))"
    CrystalClick::StaticBinaryBulkColumnDeclaration.parse(admitted_array_tuple).should_not be_nil
    CrystalClick::WidePart.supports_generic_static_binary_bulk_type?(admitted_array_tuple).should be_true
    w95_with_offline_tuple_catalog([7_u64], columns, admitted_array_tuple) do |root, _part|
      selection = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]["payload"]
      error = expect_raises(CrystalClick::CorruptPartError) { selection.values }
      error.message.should eq("Binary bulk source declaration differs from the expected nominal descriptor")
    end

    illegal_nullable_array_tuple = "Tuple(s Nullable(Array(String)))"
    CrystalClick::StaticBinaryBulkColumnDeclaration.parse(illegal_nullable_array_tuple).should be_nil
    CrystalClick::WidePart.supports_generic_static_binary_bulk_type?(illegal_nullable_array_tuple).should be_false
    w95_with_offline_tuple_catalog([7_u64], columns, illegal_nullable_array_tuple) do |root, _part|
      selection = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]["payload"]
      error = expect_raises(CrystalClick::UnsupportedFormatError) { selection.values }
      error.message.should eq("selected table column type is unsupported")
    end
  end
end
