require "./spec_helper"

DATETIME_SCAN_DATABASE_UUID = "2e62ff38-2f50-4b9e-b779-6a0ae1370c31"
DATETIME_SCAN_TABLE_UUID    = "7426ee8a-5a15-4fbb-bf0e-a1fd780db473"

def with_datetime_scan_root(&)
  root = File.tempname("crystal-click-datetime-scan-spec")
  Dir.mkdir(root)
  begin
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

def datetime_scan_write_part(
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

def datetime_scan_create_catalog_table(root : String, semantic_type : String, values : Slice(T), physical_type : String) : CrystalClick::OfflineTable forall T
  metadata_path = File.join(root, "metadata")
  store_path = File.join(root, "store")
  Dir.mkdir(metadata_path)
  Dir.mkdir(store_path)

  database_path = File.join(store_path, DATETIME_SCAN_DATABASE_UUID[0, 3], DATETIME_SCAN_DATABASE_UUID)
  FileUtils.mkdir_p(database_path)
  File.write(
    File.join(metadata_path, "lab.sql"),
    "ATTACH DATABASE _ UUID '#{DATETIME_SCAN_DATABASE_UUID}'\nENGINE = Atomic\n"
  )

  table_path = File.join(database_path, "events.sql")
  File.write(
    table_path,
    "ATTACH TABLE _ UUID '#{DATETIME_SCAN_TABLE_UUID}'\n" +
    "(\n    `pk` UInt64,\n    `codes` #{semantic_type}\n)\n" +
    "ENGINE = MergeTree\nORDER BY `pk`\n"
  )

  physical_table_path = File.join(store_path, DATETIME_SCAN_TABLE_UUID[0, 3], DATETIME_SCAN_TABLE_UUID)
  FileUtils.mkdir_p(physical_table_path)
  File.write(File.join(physical_table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(physical_table_path, "detached"))
  datetime_scan_write_part(
    File.join(physical_table_path, "all_1_1_0"),
    values,
    semantic_type,
    physical_type
  )

  CrystalClick::OfflineCatalog.open(root).table("lab", "events")
end

describe CrystalClick::WidePart do
  it "parses only canonical DateTime64 precisions and exact bare DateTime" do
    (0..9).each do |precision|
      type = "DateTime64(#{precision})"
      CrystalClick::WidePart.datetime64_scale(type).should eq(precision)
      CrystalClick::WidePart.supports_typed_type?(type).should be_true
    end

    CrystalClick::WidePart.datetime64_scale("DateTime64(03)").should be_nil
    CrystalClick::WidePart.datetime64_scale("DateTime64(10)").should be_nil
    CrystalClick::WidePart.datetime64_scale("DateTime64(-1)").should be_nil
    CrystalClick::WidePart.datetime64_scale("DateTime64(3, 'UTC')").should be_nil
    CrystalClick::WidePart.datetime64_scale("DateTime64(3) ").should be_nil
    CrystalClick::WidePart.supports_typed_type?("DateTime").should be_true
    CrystalClick::WidePart.supports_typed_type?("DateTime('UTC')").should be_false
    CrystalClick::WidePart.supports_typed_type?("DateTime64(03)").should be_false
    CrystalClick::WidePart.supports_typed_type?("DateTime64(10)").should be_false
    CrystalClick::WidePart.supports_typed_type?("DateTime64(3, 'UTC')").should be_false
  end

  it "reads bare DateTime raw UInt32 seconds across marks without numeric aliases" do
    with_datetime_scan_root do |root|
      values = Slice(UInt32).new(5) do |index|
        [0_u32, 1_u32, 2_000_000_000_u32, 4_000_000_000_u32, UInt32::MAX][index]
      end
      part_path = datetime_scan_write_part(File.join(root, "all_1_1_0"), values, "DateTime", "UInt32")
      reader = CrystalClick::WidePart.open_typed(part_path, "codes")

      reader.column_type.should eq("DateTime")
      reader.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
      reader.read_datetime_seconds_mark_range("codes", 0, 3).should eq(values.to_a)
      reader.read_datetime_seconds_mark_range("codes", 1, 2).should eq([2_000_000_000_u32, 4_000_000_000_u32, UInt32::MAX])
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_numeric_mark_range("codes", 0, 1, UInt32)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_numeric(part_path, "codes")
      end
    end
  end

  it "reads DateTime64(0), (3), and (9) raw signed ticks across marks" do
    values = Slice(Int64).new(5) do |index|
      [Int64::MIN, -1_i64, 0_i64, 1_i64, Int64::MAX][index]
    end

    [0, 3, 9].each do |precision|
      with_datetime_scan_root do |root|
        type = "DateTime64(#{precision})"
        part_path = datetime_scan_write_part(File.join(root, "all_1_1_0"), values, type, "Int64")
        reader = CrystalClick::WidePart.open_typed(part_path, "codes")

        reader.column_type.should eq(type)
        reader.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
        reader.read_datetime64_ticks_mark_range("codes", 0, 3).should eq(values.to_a)
        reader.read_datetime64_ticks_mark_range("codes", 1, 2).should eq([0_i64, 1_i64, Int64::MAX])
        expect_raises(CrystalClick::UnsupportedFormatError) do
          reader.read_numeric_mark_range("codes", 0, 1, Int64)
        end
        expect_raises(CrystalClick::UnsupportedFormatError) do
          CrystalClick::WidePart.open_numeric(part_path, "codes")
        end
      end
    end
  end

  it "rejects timezone-qualified and malformed time metadata at typed open" do
    [
      {"DateTime('UTC')", "UInt32"},
      {"DateTime64(3, 'UTC')", "Int64"},
      {"DateTime64(03)", "Int64"},
      {"DateTime64(10)", "Int64"},
      {"DateTime64(-1)", "Int64"},
      {"DateTime64(3) ", "Int64"},
    ].each do |entry|
      with_datetime_scan_root do |root|
        type, physical_type = entry
        if physical_type == "UInt32"
          values = Slice(UInt32).new(2) { |index| index.to_u32 }
          part_path = datetime_scan_write_part(File.join(root, "all_1_1_0"), values, type, physical_type)
          expect_raises(CrystalClick::UnsupportedFormatError) { CrystalClick::WidePart.open_typed(part_path, "codes") }
        else
          values = Slice(Int64).new(2) { |index| index.to_i64 }
          part_path = datetime_scan_write_part(File.join(root, "all_1_1_0"), values, type, physical_type)
          expect_raises(CrystalClick::UnsupportedFormatError) { CrystalClick::WidePart.open_typed(part_path, "codes") }
        end
      end
    end
  end
end

describe CrystalClick::WidePartTable do
  it "keeps time accessors semantic in typed batches and refuses numeric scans" do
    with_datetime_scan_root do |root|
      values = Slice(UInt32).new(5) do |index|
        [0_u32, 1_u32, 2_000_000_000_u32, 4_000_000_000_u32, UInt32::MAX][index]
      end
      part_path = datetime_scan_write_part(File.join(root, "all_1_1_0"), values, "DateTime", "UInt32")
      table = CrystalClick::WidePartTable.open_selected_typed([part_path], ["codes"])
      table.column_types.should eq([{"codes", "DateTime"}])

      observed = [] of UInt32
      table.scan_typed(batch_rows: 1) do |batch|
        batch.datetime_seconds_for("codes").each { |value| observed << value }
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.values_for("codes", UInt32) }
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.datetime64_ticks_for("codes") }
      end
      observed.should eq(values.to_a)

      callbacks = 0
      expect_raises(CrystalClick::UnsupportedFormatError) do
        table.scan_numeric { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    end

    with_datetime_scan_root do |root|
      values = Slice(Int64).new(5) do |index|
        [Int64::MIN, -1_i64, 0_i64, 1_i64, Int64::MAX][index]
      end
      type = "DateTime64(9)"
      part_path = datetime_scan_write_part(File.join(root, "all_1_1_0"), values, type, "Int64")
      table = CrystalClick::WidePartTable.open_selected_typed([part_path], ["codes"])
      table.column_types.should eq([{"codes", type}])

      observed = [] of Int64
      table.scan_typed(batch_rows: 2) do |batch|
        batch.datetime64_ticks_for("codes").each { |value| observed << value }
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.values_for("codes", Int64) }
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.datetime_seconds_for("codes") }
      end
      observed.should eq(values.to_a)

      callbacks = 0
      expect_raises(CrystalClick::UnsupportedFormatError) do
        table.scan_numeric { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    end
  end
end

describe CrystalClick::OfflineCatalog do
  it "materializes raw time codes while preserving complete DDL types" do
    with_datetime_scan_root do |root|
      values = Slice(UInt32).new(5) do |index|
        [0_u32, 1_u32, 2_000_000_000_u32, 4_000_000_000_u32, UInt32::MAX][index]
      end
      table = datetime_scan_create_catalog_table(root, "DateTime", values, "UInt32")
      table.columns.find { |column| column.name == "codes" }.not_nil!.type.should eq("DateTime")
      table.materialize_selected_values("codes").map(&.as(UInt32)).should eq(values.to_a)
    end

    with_datetime_scan_root do |root|
      values = Slice(Int64).new(5) do |index|
        [Int64::MIN, -1_i64, 0_i64, 1_i64, Int64::MAX][index]
      end
      type = "DateTime64(3)"
      table = datetime_scan_create_catalog_table(root, type, values, "Int64")
      table.columns.find { |column| column.name == "codes" }.not_nil!.type.should eq(type)
      table.materialize_selected_values("codes").map(&.as(Int64)).should eq(values.to_a)
    end
  end
end
