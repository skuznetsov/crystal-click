require "./spec_helper"

FIXED_STRING_SCAN_FIXTURE    = File.expand_path("../test/fixtures/public/wide_numeric_mixed/part", __DIR__)
FIXED_STRING_SCAN_DB_UUID    = "95c7b6de-2b53-43e5-914a-a7a2c04c1e31"
FIXED_STRING_SCAN_TABLE_UUID = "799fa62f-6fd6-421c-b0dd-fd6c52e11bc7"

def with_fixed_string_scan_table(width : String = "8", &)
  root = File.tempname("crystal-click-fixed-string-catalog-spec")
  metadata_root = File.join(root, "metadata")
  database_path = File.join(root, "store", FIXED_STRING_SCAN_DB_UUID[0, 3], FIXED_STRING_SCAN_DB_UUID)
  table_path = File.join(root, "store", FIXED_STRING_SCAN_TABLE_UUID[0, 3], FIXED_STRING_SCAN_TABLE_UUID)
  FileUtils.mkdir_p(metadata_root)
  FileUtils.mkdir_p(database_path)
  FileUtils.mkdir_p(table_path)
  begin
    File.write(File.join(metadata_root, "lab.sql"), "ATTACH DATABASE _ UUID '#{FIXED_STRING_SCAN_DB_UUID}'\nENGINE = Atomic\n")
    File.write(
      File.join(database_path, "events.sql"),
      "ATTACH TABLE _ UUID '#{FIXED_STRING_SCAN_TABLE_UUID}'\n(\n    `u64` FixedString(#{width}),\n    `u8` UInt8\n)\nENGINE = MergeTree\nORDER BY tuple()\n"
    )
    File.write(File.join(table_path, "format_version.txt"), "1\n")
    Dir.mkdir(File.join(table_path, "detached"))
    part_path = File.join(table_path, "all_1_1_0")
    FileUtils.cp_r(FIXED_STRING_SCAN_FIXTURE, part_path)
    columns_path = File.join(part_path, "columns.txt")
    original_columns = File.read(columns_path)
    columns = original_columns.gsub("`u64` UInt64", "`u64` FixedString(#{width})")
    raise "test fixture column type was not replaced" if columns == original_columns
    File.write(columns_path, columns)
    yield root, part_path
  ensure
    FileUtils.rm_rf(root)
  end
end

describe "FixedString(N) Wide-part scans" do
  it "accepts only the canonical positive bounded width" do
    CrystalClick::WidePart.fixed_string_width("FixedString(8)").should eq(8)
    CrystalClick::WidePart.fixed_string_width("FixedString(65536)").should eq(CrystalClick::WidePart::MAX_FIXED_STRING_WIDTH)
    CrystalClick::WidePart.supports_typed_type?("FixedString(8)").should be_true

    ["FixedString(0)", "FixedString(01)", "FixedString(-1)", "FixedString(65537)", "FixedString(8) ", "Nullable(FixedString(8))"].each do |type|
      CrystalClick::WidePart.fixed_string_width(type).should be_nil
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end
  end

  it "opens a canonical FixedString column from a one-stream fixed-width part" do
    with_fixed_string_scan_table do |_root, part_path|
      part = CrystalClick::WidePart.open_typed(part_path, "u64")
      part.column_type.should eq("FixedString(8)")
      part.mark_row_counts.should eq([2_u64, 2_u64])

      observed = part.read_fixed_string_mark_range("u64", 0, part.mark_count).map(&.to_slice.to_a)
      observed.should eq([
        [0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8],
        [255_u8, 255_u8, 255_u8, 255_u8, 255_u8, 255_u8, 255_u8, 127_u8],
        [255_u8, 255_u8, 255_u8, 255_u8, 255_u8, 255_u8, 255_u8, 255_u8],
        [1_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8],
      ])
      part.read_fixed_string_mark_range("u64", 1, 1).map(&.to_slice.to_a).should eq(observed[2, 2])
    end
  end

  it "rejects malformed and over-limit declarations before opening their streams" do
    ["0", "01", "65537"].each do |width|
      with_fixed_string_scan_table(width) do |_root, part_path|
        expect_raises(CrystalClick::UnsupportedFormatError) do
          CrystalClick::WidePart.open_typed(part_path, "u64")
        end
      end
    end
  end

  it "rejects an invalid global String serialization version for FixedString" do
    with_fixed_string_scan_table do |_root, part_path|
      path = File.join(part_path, "serialization.json")
      serialization = JSON.parse(File.read(path))
      serialization["types_serialization_versions"].as_h["string"] = JSON::Any.new(999_i64)
      File.write(path, serialization.to_json)

      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(part_path, "u64")
      end
    end
  end

  it "accepts the valid SINGLE_STREAM global version for FixedString" do
    with_fixed_string_scan_table do |_root, part_path|
      path = File.join(part_path, "serialization.json")
      serialization = JSON.parse(File.read(path))
      serialization["types_serialization_versions"].as_h["string"] = JSON::Any.new(0_i64)
      File.write(path, serialization.to_json)

      CrystalClick::WidePart.open_typed(part_path, "u64").read_fixed_string_mark_range("u64", 0, 1).size.should eq(2)
    end
  end

  it "rejects a selected range with too many returned values before reading its data" do
    with_fixed_string_scan_table("1") do |_root, part_path|
      mark_path = CrystalClick::WidePart.open_typed(part_path, "u64").mark_path
      marks = File.read(mark_path).to_slice.dup
      oversized_rows = CrystalClick::WidePart::MAX_FIXED_STRING_RANGE_ROWS + 1_u64
      8.times do |byte_index|
        marks[16 + byte_index] = ((oversized_rows >> (8 * byte_index)) & 0xff_u64).to_u8
      end
      File.write(mark_path, marks)
      File.write(File.join(part_path, "count.txt"), "#{oversized_rows + 2_u64}\n")

      part = CrystalClick::WidePart.open_typed(part_path, "u64")
      expect_raises(CrystalClick::CorruptPartError) do
        part.read_fixed_string_mark_range("u64", 0, 1)
      end
    end
  end

  it "scans borrowed FixedString values and materializes exact catalog bytes" do
    with_fixed_string_scan_table do |root, _part_path|
      table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")
      observed = [] of Array(UInt8)
      offsets = [] of UInt64
      observed_u8 = [] of UInt8
      table.scan_typed(["u64", "u8"], batch_rows: 1) do |batch|
        values = batch.fixed_strings_for("u64")
        values.size.should eq(1)
        observed << values[0].to_slice.to_a
        observed_u8 << batch.values_for("u8", UInt8)[0]
        offsets << batch.source_row_offset
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.strings_for("u64") }
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.fixed_strings_for("u8") }
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.values_for("u64", UInt64) }
      end
      offsets.should eq([0_u64, 1_u64, 2_u64, 3_u64])
      observed_u8.should eq([0_u8, 127_u8, 255_u8, 1_u8])
      observed.should eq(table["u64"].values.map { |value| value.as(String).to_slice.to_a })
      expect_raises(CrystalClick::BoundsError) do
        table["u64"].values(max_string_bytes: 31_u64)
      end
    end
  end

  it "rejects cross-part FixedString width disagreement before callbacks" do
    with_fixed_string_scan_table do |root, _first_part_path|
      table_path = File.join(root, "store", FIXED_STRING_SCAN_TABLE_UUID[0, 3], FIXED_STRING_SCAN_TABLE_UUID)
      second_part = File.join(table_path, "all_2_2_0")
      FileUtils.cp_r(FIXED_STRING_SCAN_FIXTURE, second_part)
      columns_path = File.join(second_part, "columns.txt")
      columns = File.read(columns_path).gsub("`u64` UInt64", "`u64` FixedString(4)")
      File.write(columns_path, columns)

      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::OfflineCatalog.open(root).table("lab", "events").scan_typed(["u64"]) do |_batch|
          callbacks += 1
        end
      end
      callbacks.should eq(0)
    end
  end

  it "rejects a physical stream shape that adds a String size stream" do
    with_fixed_string_scan_table do |_root, part_path|
      path = File.join(part_path, "columns_substreams.txt")
      text = File.read(path)
      changed = text.gsub("1 substreams for column `u64`:\n\tu64\n", "2 substreams for column `u64`:\n\tu64\n\tu64.size\n")
      raise "test fixture substream block was not replaced" if changed == text
      File.write(path, changed)

      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(part_path, "u64")
      end
    end
  end

  it "rejects truncated fixed-width compressed data during materialization" do
    with_fixed_string_scan_table do |_root, part_path|
      part = CrystalClick::WidePart.open_typed(part_path, "u64")
      path = part.data_path
      bytes = File.read(path).to_slice
      File.write(path, bytes[0, bytes.size - 1])
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePart.open_typed(part_path, "u64").read_fixed_string_mark_range("u64", 0, 2)
      end
    end
  end
end
