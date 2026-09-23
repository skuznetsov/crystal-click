require "./spec_helper"

NUMERIC_SCAN_FIXTURE    = File.expand_path("../test/fixtures/public/wide_numeric_mixed/part", __DIR__)
NUMERIC_SCAN_DB_UUID    = "6fe2a5b1-8151-43b7-a3e2-44365183c082"
NUMERIC_SCAN_TABLE_UUID = "7823e81c-d72b-4f1c-aad5-41c5a173d103"

def with_numeric_scan_table(ddl_columns : String = numeric_scan_columns, &)
  root = File.tempname("crystal-click-numeric-catalog-spec")
  metadata_root = File.join(root, "metadata")
  database_path = File.join(root, "store", NUMERIC_SCAN_DB_UUID[0, 3], NUMERIC_SCAN_DB_UUID)
  table_path = File.join(root, "store", NUMERIC_SCAN_TABLE_UUID[0, 3], NUMERIC_SCAN_TABLE_UUID)
  FileUtils.mkdir_p(metadata_root)
  FileUtils.mkdir_p(database_path)
  FileUtils.mkdir_p(table_path)
  begin
    File.write(File.join(metadata_root, "lab.sql"), "ATTACH DATABASE _ UUID '#{NUMERIC_SCAN_DB_UUID}'\nENGINE = Atomic\n")
    File.write(
      File.join(database_path, "events.sql"),
      "ATTACH TABLE _ UUID '#{NUMERIC_SCAN_TABLE_UUID}'\n(\n#{ddl_columns}\n)\nENGINE = MergeTree\nORDER BY tuple()\n"
    )
    File.write(File.join(table_path, "format_version.txt"), "1\n")
    Dir.mkdir(File.join(table_path, "detached"))
    FileUtils.cp_r(NUMERIC_SCAN_FIXTURE, File.join(table_path, "all_1_1_0"))
    yield root, File.join(table_path, "all_1_1_0")
  ensure
    FileUtils.rm_rf(root)
  end
end

def numeric_scan_columns : String
  "    `u8` UInt8,\n" +
    "    `u16` UInt16,\n" +
    "    `u32` UInt32,\n" +
    "    `u64` UInt64,\n" +
    "    `i8` Int8,\n" +
    "    `i16` Int16,\n" +
    "    `i32` Int32,\n" +
    "    `i64` Int64,\n" +
    "    `f32` Float32,\n" +
    "    `f64` Float64"
end

def numeric_scan_read_column(name : String, type : T.class) : Array(T) forall T
  part = CrystalClick::WidePart.open_numeric(NUMERIC_SCAN_FIXTURE, name)
  part.read_numeric_mark_range(name, 0, part.mark_count, type)
end

describe "fixed numeric Wide-part scans" do
  it "decodes the public ClickHouse fixture into exact primitive types" do
    expected_u8 = [0_u8, 127_u8, 255_u8, 1_u8]
    expected_u16 = [0_u16, 32767_u16, 65535_u16, 1_u16]
    expected_u32 = [0_u32, 2_147_483_647_u32, UInt32::MAX, 1_u32]
    expected_u64 = [0_u64, Int64::MAX.to_u64, UInt64::MAX, 1_u64]
    expected_i8 = [-128_i8, -1_i8, 0_i8, 127_i8]
    expected_i16 = [-32768_i16, -1_i16, 0_i16, 32767_i16]
    expected_i32 = [-2_147_483_648_i32, -1_i32, 0_i32, 2_147_483_647_i32]
    expected_i64 = [Int64::MIN, -1_i64, 0_i64, Int64::MAX]
    expected_f32_bits = [0_u32, 0x80000000_u32, 0x3fc00000_u32, 0xc0100000_u32]
    expected_f64_bits = [0_u64, 0x8000000000000000_u64, 0x3ff8000000000000_u64, 0xc002000000000000_u64]

    part = CrystalClick::WidePart.open_numeric(NUMERIC_SCAN_FIXTURE, "u8")
    part.row_count.should eq(4_u64)
    numeric_scan_read_column("u8", UInt8).should eq(expected_u8)
    numeric_scan_read_column("u16", UInt16).should eq(expected_u16)
    numeric_scan_read_column("u32", UInt32).should eq(expected_u32)
    numeric_scan_read_column("u64", UInt64).should eq(expected_u64)
    numeric_scan_read_column("i8", Int8).should eq(expected_i8)
    numeric_scan_read_column("i16", Int16).should eq(expected_i16)
    numeric_scan_read_column("i32", Int32).should eq(expected_i32)
    numeric_scan_read_column("i64", Int64).should eq(expected_i64)
    numeric_scan_read_column("f32", Float32).map(&.unsafe_as(UInt32)).should eq(expected_f32_bits)
    numeric_scan_read_column("f64", Float64).map(&.unsafe_as(UInt64)).should eq(expected_f64_bits)
  end

  it "scans mixed types through OfflineTable with row aligned callback batches" do
    with_numeric_scan_table do |root, _part_path|
      table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")
      callbacks = 0
      observed_u8 = [] of UInt8
      observed_i16 = [] of Int16
      observed_f32_bits = [] of UInt32
      observed_u64 = [] of UInt64
      observed_offsets = [] of {Int32, Int32, UInt64, UInt64}
      table.scan_numeric(["u8", "i16", "f32", "u64"], batch_rows: 3) do |batch|
        u8 = batch.values_for("u8", UInt8)
        i16 = batch.values_for("i16", Int16)
        f32 = batch.values_for("f32", Float32)
        u64 = batch.values_for("u64", UInt64)
        u8.size.should eq(i16.size)
        u8.size.should eq(f32.size)
        u8.size.should eq(u64.size)
        observed_u8.concat(u8)
        observed_i16.concat(i16)
        f32.each { |value| observed_f32_bits << value.unsafe_as(UInt32) }
        observed_u64.concat(u64)
        observed_offsets << {batch.part_index, batch.mark_index, batch.part_row_offset, batch.source_row_offset}
        callbacks += 1
      end
      callbacks.should eq(2)
      observed_offsets.should eq([{0_i32, 0_i32, 0_u64, 0_u64}, {0_i32, 1_i32, 2_u64, 2_u64}])
      observed_u8.should eq([0_u8, 127_u8, 255_u8, 1_u8])
      observed_i16.should eq([-32768_i16, -1_i16, 0_i16, 32767_i16])
      observed_f32_bits.should eq([0_u32, 0x80000000_u32, 0x3fc00000_u32, 0xc0100000_u32])
      observed_u64.should eq([0_u64, Int64::MAX.to_u64, UInt64::MAX, 1_u64])
    end
  end

  it "preserves mixed-column values and offsets across two non-overlapping parts" do
    with_numeric_scan_table do |root, _first_part_path|
      table_path = File.join(root, "store", NUMERIC_SCAN_TABLE_UUID[0, 3], NUMERIC_SCAN_TABLE_UUID)
      FileUtils.cp_r(NUMERIC_SCAN_FIXTURE, File.join(table_path, "all_2_2_0"))

      rows = [] of {Int32, UInt64, UInt64, UInt8, Int16}
      CrystalClick::OfflineCatalog.open(root).table("lab", "events").scan_numeric(["u8", "i16"], batch_rows: 3) do |batch|
        u8 = batch.values_for("u8", UInt8)
        i16 = batch.values_for("i16", Int16)
        u8.each_with_index do |value, index|
          rows << {batch.part_index, batch.part_row_offset + index.to_u64,
                   batch.source_row_offset + index.to_u64, value, i16[index]}
        end
      end

      expected = [
        {0_i32, 0_u64, 0_u64, 0_u8, -32768_i16},
        {0_i32, 1_u64, 1_u64, 127_u8, -1_i16},
        {0_i32, 2_u64, 2_u64, 255_u8, 0_i16},
        {0_i32, 3_u64, 3_u64, 1_u8, 32767_i16},
        {1_i32, 0_u64, 4_u64, 0_u8, -32768_i16},
        {1_i32, 1_u64, 5_u64, 127_u8, -1_i16},
        {1_i32, 2_u64, 6_u64, 255_u8, 0_i16},
        {1_i32, 3_u64, 7_u64, 1_u8, 32767_i16},
      ]
      rows.should eq(expected)
    end
  end

  it "preserves the original UInt64 batch initializer and accessor" do
    values = [1_u64, 2_u64]
    slice = values.to_unsafe.to_slice(values.size)
    batch = CrystalClick::WidePartTableBatch.new(
      0_i32,
      "all_1_1_0",
      NUMERIC_SCAN_FIXTURE,
      0_i32,
      0_u64,
      0_u64,
      0_u64,
      ["value"],
      [slice]
    )

    batch.values_for("value").to_a.should eq(values)
    batch.values_for("value", UInt64).to_a.should eq(values)
  end

  it "rejects DDL and part type mismatches and rejects the old UInt64 reader on non-UInt64 columns" do
    with_numeric_scan_table("    `u32` Int32") do |root, _part_path|
      callbacks = 0
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::OfflineCatalog.open(root).table("lab", "events").scan_numeric(["u32"]) do |_batch|
          callbacks += 1
        end
      end
      callbacks.should eq(0)
    end

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::WidePart.open(NUMERIC_SCAN_FIXTURE, "u8")
    end
    numeric_part = CrystalClick::WidePart.open_numeric(NUMERIC_SCAN_FIXTURE, "u8")
    expect_raises(CrystalClick::UnsupportedFormatError) do
      numeric_part.read_uint64("u8")
    end
    scratch_values = Array(UInt64).new(2, 0_u64)
    scratch = scratch_values.to_unsafe.to_slice(scratch_values.size)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      numeric_part.scan_uint64_mark_range_into("u8", 0, 1, scratch) { |_| }
    end
  end

  it "rejects same-width typed accessor mismatches and corrupted width alignment before use" do
    with_numeric_scan_table do |root, part_path|
      accessed = false
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::OfflineCatalog.open(root).table("lab", "events").scan_numeric(["i32"]) do |batch|
          batch.values_for("i32", UInt32)
          accessed = true
        end
      end
      accessed.should be_false

      numeric_part = CrystalClick::WidePart.open_numeric(part_path, "u16")
      mutate_fixture_file(part_path, File.basename(numeric_part.mark_path)) do |bytes|
        # The UInt16 second mark must start on an even decompressed offset.
        bytes[24 + 8] = 3_u8
        bytes[24 + 9] = 0_u8
        6.times { |index| bytes[24 + 10 + index] = 0_u8 }
      end
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePart.open_numeric(part_path, "u16")
      end
    end
  end

  it "rejects mark row counts whose implied byte width exceeds the bounded range" do
    with_numeric_scan_table do |_root, part_path|
      numeric_part = CrystalClick::WidePart.open_numeric(part_path, "u16")
      mutate_fixture_file(part_path, File.basename(numeric_part.mark_path)) do |bytes|
        # Keep the aggregate row count valid, but make the first mark claim one
        # UInt16 row although its physical range still contains two values.
        bytes[16] = 1_u8
        7.times { |index| bytes[17 + index] = 0_u8 }
        bytes[40] = 3_u8
        7.times { |index| bytes[41 + index] = 0_u8 }
      end
      corrupted = CrystalClick::WidePart.open_numeric(part_path, "u16")
      corrupted.mark_row_counts.should eq([1_u64, 3_u64])
      expect_raises(CrystalClick::CorruptPartError) do
        corrupted.read_numeric_mark_range("u16", 0, 1, UInt16)
      end
    end
  end

  it "rejects equal-width type disagreement across selected parts during preflight" do
    with_numeric_scan_table do |root, first_part_path|
      table_path = File.join(root, "store", NUMERIC_SCAN_TABLE_UUID[0, 3], NUMERIC_SCAN_TABLE_UUID)
      second_part_path = File.join(table_path, "all_2_2_0")
      FileUtils.cp_r(NUMERIC_SCAN_FIXTURE, second_part_path)
      columns_path = File.join(second_part_path, "columns.txt")
      File.write(columns_path, File.read(columns_path).gsub("`u32` UInt32", "`u32` Int32"))

      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartTable.open_selected_numeric([first_part_path, second_part_path], ["u32"])
      end
    end
  end

  it "materializes all selected columns for a mark before invoking its callback" do
    with_numeric_scan_table do |root, part_path|
      numeric_part = CrystalClick::WidePart.open_numeric(part_path, "u16")
      mutate_fixture_file(part_path, File.basename(numeric_part.data_path)) { |bytes| bytes[16] = 0xff_u8 }

      table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")
      callbacks = 0
      expect_raises(CrystalClick::UnsupportedFormatError) do
        table.scan_numeric(["u8", "u16"]) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    end
  end

  it "rejects overlapping numeric candidates before invoking the callback" do
    with_numeric_scan_table do |root, _part_path|
      table_path = File.join(root, "store", NUMERIC_SCAN_TABLE_UUID[0, 3], NUMERIC_SCAN_TABLE_UUID)
      FileUtils.cp_r(NUMERIC_SCAN_FIXTURE, File.join(table_path, "same_0_1_0"))
      FileUtils.cp_r(NUMERIC_SCAN_FIXTURE, File.join(table_path, "same_1_2_0"))

      table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")
      callbacks = 0
      error = expect_raises(CrystalClick::InvalidPartError) do
        table.scan_numeric(["u8"]) { |_batch| callbacks += 1 }
      end
      error.message.not_nil!.should contain("overlap")
      callbacks.should eq(0)
    end
  end
end
