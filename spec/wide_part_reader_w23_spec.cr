require "./spec_helper"

W23_TUPLE_FIXTURE = File.expand_path("../test/fixtures/public/wide_tuple_uint64_string/part", __DIR__)

def w23_tuple_values : Array(Tuple(UInt64, String))
  [
    {0_u64, ""},
    {UInt64::MAX, "short"},
    {2_u64, String.new(Bytes[0x41, 0x00, 0x42, 0xff])},
    {3_u64, "a much longer payload crossing offsets"},
    {4_u64, ""},
  ]
end

def w23_copy_tuple_fixture : String
  path = File.tempname("crystal-click-w23-part")
  FileUtils.cp_r(W23_TUPLE_FIXTURE, path)
  path
end

def with_w23_named_tuple_part(& : String ->)
  root = File.tempname("crystal-click-w23-part")
  Dir.mkdir(root)
  path = File.join(root, "all_1_1_0")
  FileUtils.cp_r(W23_TUPLE_FIXTURE, path)
  yield path
ensure
  FileUtils.rm_rf(root) if root && Dir.exists?(root)
end

def with_w23_offline_catalog_root(& : String ->)
  root = File.tempname("crystal-click-w23-catalog")
  Dir.mkdir(root)
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))

  database_uuid = "835e7af8-f57c-42b8-bcb0-863f3de0ca51"
  table_uuid = "1f068934-2439-44ce-9501-c2dc252a9027"
  database_store = File.join(root, "store", database_uuid[0, 3], database_uuid)
  table_store = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(database_store)
  File.write(File.join(root, "metadata", "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  File.write(
    File.join(database_store, "events.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `id` UInt64,\n    `payload` Tuple(a UInt64, b String)\n)\nENGINE = MergeTree\nORDER BY id\n"
  )
  FileUtils.mkdir_p(table_store)
  File.write(File.join(table_store, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_store, "detached"))
  FileUtils.cp_r(W23_TUPLE_FIXTURE, File.join(table_store, "all_1_1_0"))

  yield root
ensure
  FileUtils.rm_rf(root) if root && Dir.exists?(root)
end

describe "W23 named UInt64/String Tuple reader" do
  it "admits only the exact named tuple payload type from the stock fixture" do
    File.read(File.join(W23_TUPLE_FIXTURE, "columns.txt")).should contain("`payload` Tuple(a UInt64, b String)")
    CrystalClick::WidePart.supports_typed_type?("Tuple(a UInt64, b String)").should be_true
    CrystalClick::WidePart.supports_typed_type?("Tuple(UInt64, String)").should be_false
  end

  it "reads positional values through each independently marked nested stream" do
    reader = CrystalClick::WidePart.open_typed(W23_TUPLE_FIXTURE, "payload")
    expected = w23_tuple_values

    reader.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
    reader.tuple_uint64_string_mark_range_raw_bytes("payload", 0, 1).should eq(5_u64)
    reader.tuple_uint64_string_mark_range_raw_bytes("payload", 1, 1).should eq(expected[2][1].bytesize.to_u64 + expected[3][1].bytesize.to_u64)
    reader.tuple_uint64_string_mark_range_raw_bytes("payload", 2, 1).should eq(0_u64)
    reader.read_tuple_uint64_string_mark_range("payload", 0, 1).should eq(expected[0, 2])
    reader.read_tuple_uint64_string_mark_range("payload", 1, 1).should eq(expected[2, 2])
    reader.read_tuple_uint64_string_mark_range("payload", 2, 1).should eq(expected[4, 1])
    reader.read_tuple_uint64_string_mark_range("payload", 1, 2).should eq(expected[2, 3])

    expect_raises(CrystalClick::UnsupportedFormatError) do
      reader.read_string_mark_range("payload", 0, 1)
    end
  end

  it "exposes row-aligned named Tuple slices from bounded callbacks" do
    with_w23_named_tuple_part do |part_path|
      table = CrystalClick::WidePartTable.open_selected_typed([part_path], ["payload"])
      observed = [] of Tuple(UInt64, String)

      table.scan_typed(batch_rows: 1) do |batch|
        batch.tuples_for("payload").each do |value|
          observed << {value[0], String.new(value[1].to_slice)}
        end
      end

      observed.should eq(w23_tuple_values)

      expect_raises(CrystalClick::UnsupportedFormatError) do
        table.scan_typed do |batch|
          batch.values_for("payload")
        end
      end
    end
  end

  it "materializes positional Tuple values through the offline catalog" do
    with_w23_offline_catalog_root do |root|
      values = CrystalClick::OfflineCatalog.open(root).table("lab", "events")["payload"].values
      values.size.should eq(5)
      values.each_with_index do |value, index|
        value.should eq(w23_tuple_values[index])
      end
    end
  end

  it "rejects alternate tuple spellings and unsupported metadata or substreams" do
    type_path = w23_copy_tuple_fixture
    begin
      columns_path = File.join(type_path, "columns.txt")
      File.write(columns_path, File.read(columns_path).sub("Tuple(a UInt64, b String)", "Tuple(UInt64, String)"))
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(type_path, "payload")
      end
    ensure
      FileUtils.rm_rf(type_path)
    end

    metadata_path = w23_copy_tuple_fixture
    begin
      serialization_path = File.join(metadata_path, "serialization.json")
      File.write(serialization_path, File.read(serialization_path).sub("\"version\":1}", "\"version\":1,\"unknown\":true}"))
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(metadata_path, "payload")
      end
    ensure
      FileUtils.rm_rf(metadata_path)
    end

    substream_path = w23_copy_tuple_fixture
    begin
      substreams_path = File.join(substream_path, "columns_substreams.txt")
      File.write(substreams_path, File.read(substreams_path).sub("payload%2Eb.size", "payload.b.size"))
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(substream_path, "payload")
      end
    ensure
      FileUtils.rm_rf(substream_path)
    end
  end

  it "rejects a same-size child mark row-count mutation before returning values" do
    mark_path = w23_copy_tuple_fixture
    begin
      stream = CrystalClick::StreamName.hash("payload%2Eb.size")
      marks_file = File.join(mark_path, "#{stream}.mrk2")
      marks = File.read(marks_file).to_slice.dup
      marks[16] = 1_u8
      File.write(marks_file, marks)

      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePart.open_typed(mark_path, "payload")
      end
    ensure
      FileUtils.rm_rf(mark_path)
    end
  end
end
