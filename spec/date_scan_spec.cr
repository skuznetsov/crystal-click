require "./spec_helper"

DATE_SCAN_DATABASE_UUID = "71ef0b0d-07f8-425a-a045-91683f53b205"
DATE_SCAN_TABLE_UUID    = "a98fe120-11b4-489f-87df-5c21c9a24413"

def with_date_scan_root(&)
  root = File.tempname("crystal-click-date-scan-spec")
  Dir.mkdir(root)
  begin
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

def date_scan_write_part(
  destination : String,
  values : Slice(T),
  semantic_type : String,
  physical_type : String,
  rows_per_mark : Int32 = 2,
) : String forall T
  keys = Slice(UInt64).new(values.size) { |index| index.to_u64 }
  CrystalClick::WidePartWriter.write_uint64_typed_pair(
    destination,
    "pk",
    keys,
    "codes",
    values,
    rows_per_mark
  )

  columns_path = File.join(destination, "columns.txt")
  metadata = File.read(columns_path)
  old_declaration = "`codes` #{physical_type}"
  raise "generated part did not contain expected numeric declaration" unless metadata.includes?(old_declaration)
  File.write(columns_path, metadata.gsub(old_declaration, "`codes` #{semantic_type}"))
  destination
end

def date_scan_create_catalog_table(root : String, semantic_type : String, values : Slice(T)) : CrystalClick::OfflineTable forall T
  metadata_path = File.join(root, "metadata")
  store_path = File.join(root, "store")
  Dir.mkdir(metadata_path)
  Dir.mkdir(store_path)

  database_path = File.join(store_path, DATE_SCAN_DATABASE_UUID[0, 3], DATE_SCAN_DATABASE_UUID)
  FileUtils.mkdir_p(database_path)
  File.write(
    File.join(metadata_path, "lab.sql"),
    "ATTACH DATABASE _ UUID '#{DATE_SCAN_DATABASE_UUID}'\nENGINE = Atomic\n"
  )

  table_path = File.join(database_path, "events.sql")
  File.write(
    table_path,
    "ATTACH TABLE _ UUID '#{DATE_SCAN_TABLE_UUID}'\n" +
    "(\n    `pk` UInt64,\n    `codes` #{semantic_type}\n)\n" +
    "ENGINE = MergeTree\nORDER BY `pk`\n"
  )

  physical_table_path = File.join(store_path, DATE_SCAN_TABLE_UUID[0, 3], DATE_SCAN_TABLE_UUID)
  FileUtils.mkdir_p(physical_table_path)
  File.write(File.join(physical_table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(physical_table_path, "detached"))
  date_scan_write_part(File.join(physical_table_path, "all_1_1_0"), values, semantic_type,
    semantic_type == "Date" ? "UInt16" : "Int32")

  CrystalClick::OfflineCatalog.open(root).table("lab", "events")
end

describe CrystalClick::WidePart do
  it "reads Date day codes across marks without opening the primitive UInt16 API" do
    with_date_scan_root do |root|
      values = Slice(UInt16).new(5) do |index|
        [0_u16, UInt16::MAX, 1_u16, 32_000_u16, 7_u16][index]
      end
      part_path = date_scan_write_part(File.join(root, "all_1_1_0"), values, "Date", "UInt16")
      reader = CrystalClick::WidePart.open_typed(part_path, "codes")

      reader.column_type.should eq("Date")
      reader.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
      reader.read_date_codes_mark_range("codes", 0, 3).should eq(values.to_a)
      reader.read_date_codes_mark_range("codes", 1, 2).should eq([1_u16, 32_000_u16, 7_u16])
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_date32_codes_mark_range("codes", 0, 1)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_numeric_mark_range("codes", 0, 1, UInt16)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_numeric(part_path, "codes")
      end
    end
  end

  it "reads Date32 raw signed codes across marks, including both Int32 extrema" do
    with_date_scan_root do |root|
      values = Slice(Int32).new(5) do |index|
        [Int32::MIN, -1_i32, 0_i32, 1_i32, Int32::MAX][index]
      end
      part_path = date_scan_write_part(File.join(root, "all_1_1_0"), values, "Date32", "Int32")
      reader = CrystalClick::WidePart.open_typed(part_path, "codes")

      reader.column_type.should eq("Date32")
      reader.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
      reader.read_date32_codes_mark_range("codes", 0, 3).should eq(values.to_a)
      reader.read_date32_codes_mark_range("codes", 1, 2).should eq([0_i32, 1_i32, Int32::MAX])
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_date_codes_mark_range("codes", 0, 1)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_numeric_mark_range("codes", 0, 1, Int32)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_numeric(part_path, "codes")
      end
    end
  end
end

describe CrystalClick::WidePartTable do
  it "exposes separate Date and Date32 batch accessors and keeps numeric scans narrow" do
    with_date_scan_root do |root|
      date_values = Slice(UInt16).new(5) do |index|
        [0_u16, UInt16::MAX, 1_u16, 32_000_u16, 7_u16][index]
      end
      date_path = date_scan_write_part(File.join(root, "all_1_1_0"), date_values, "Date", "UInt16")
      date_table = CrystalClick::WidePartTable.open_selected_typed([date_path], ["codes"])
      date_table.column_types.should eq([{"codes", "Date"}])
      observed_dates = [] of UInt16
      date_table.scan_typed(batch_rows: 1) do |batch|
        batch.date_codes_for("codes").each { |code| observed_dates << code }
        expect_raises(CrystalClick::UnsupportedFormatError) do
          batch.values_for("codes", UInt16)
        end
      end
      observed_dates.should eq(date_values.to_a)

      callbacks = 0
      expect_raises(CrystalClick::UnsupportedFormatError) do
        date_table.scan_numeric do |_batch|
          callbacks += 1
        end
      end
      callbacks.should eq(0)
    end

    with_date_scan_root do |root|
      date32_values = Slice(Int32).new(5) do |index|
        [Int32::MIN, -1_i32, 0_i32, 1_i32, Int32::MAX][index]
      end
      date32_path = date_scan_write_part(File.join(root, "all_1_1_0"), date32_values, "Date32", "Int32")
      date32_table = CrystalClick::WidePartTable.open_selected_typed([date32_path], ["codes"])
      date32_table.column_types.should eq([{"codes", "Date32"}])
      observed_date32 = [] of Int32
      date32_table.scan_typed(batch_rows: 2) do |batch|
        batch.date32_codes_for("codes").each { |code| observed_date32 << code }
        expect_raises(CrystalClick::UnsupportedFormatError) do
          batch.values_for("codes", Int32)
        end
      end
      observed_date32.should eq(date32_values.to_a)

      callbacks = 0
      expect_raises(CrystalClick::UnsupportedFormatError) do
        date32_table.scan_numeric do |_batch|
          callbacks += 1
        end
      end
      callbacks.should eq(0)
    end
  end
end

describe CrystalClick::OfflineCatalog do
  it "materializes raw Date and Date32 codes while retaining their DDL types" do
    with_date_scan_root do |root|
      date_values = Slice(UInt16).new(5) do |index|
        [0_u16, UInt16::MAX, 1_u16, 32_000_u16, 7_u16][index]
      end
      date_table = date_scan_create_catalog_table(root, "Date", date_values)
      date_table.columns.find { |column| column.name == "codes" }.not_nil!.type.should eq("Date")
      date_table.materialize_selected_values("codes").map(&.as(UInt16)).should eq(date_values.to_a)
    end

    with_date_scan_root do |root|
      date32_values = Slice(Int32).new(5) do |index|
        [Int32::MIN, -1_i32, 0_i32, 1_i32, Int32::MAX][index]
      end
      date32_table = date_scan_create_catalog_table(root, "Date32", date32_values)
      date32_table.columns.find { |column| column.name == "codes" }.not_nil!.type.should eq("Date32")
      date32_table.materialize_selected_values("codes").map(&.as(Int32)).should eq(date32_values.to_a)
    end
  end
end
