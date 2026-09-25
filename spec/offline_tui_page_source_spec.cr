require "./spec_helper"
require "../examples/offline_tui/page_source"

OFFLINE_PAGE_STRING_FIXTURE          = File.expand_path("../test/fixtures/public/wide_string_nullable/part", __DIR__)
OFFLINE_PAGE_NUMERIC_FIXTURE         = File.expand_path("../test/fixtures/public/wide_numeric_mixed/part", __DIR__)
OFFLINE_PAGE_NULLABLE_STRING_FIXTURE = File.expand_path("../test/fixtures/public/wide_nullable_string/part", __DIR__)
OFFLINE_PAGE_DB_UUID                 = "8d908d2a-589c-4f7b-84a4-0c6730dfcbac"
OFFLINE_PAGE_TABLE_UUID              = "8db445cf-0f66-4bfa-8544-275d43fa4110"

def with_offline_page_table(
  columns : String = "    `label` String,\n    `maybe_u64` Nullable(UInt64),\n    `maybe_i16` Nullable(Int16),\n    `maybe_f32` Nullable(Float32)",
  fixture_path : String? = OFFLINE_PAGE_STRING_FIXTURE,
  setup_part : Proc(String, Nil)? = nil,
  &
)
  root = File.tempname("crystal-click-offline-page-spec")
  metadata_root = File.join(root, "metadata")
  database_path = File.join(root, "store", OFFLINE_PAGE_DB_UUID[0, 3], OFFLINE_PAGE_DB_UUID)
  table_path = File.join(root, "store", OFFLINE_PAGE_TABLE_UUID[0, 3], OFFLINE_PAGE_TABLE_UUID)
  FileUtils.mkdir_p(metadata_root)
  FileUtils.mkdir_p(database_path)
  FileUtils.mkdir_p(table_path)
  begin
    File.write(File.join(metadata_root, "lab.sql"), "ATTACH DATABASE _ UUID '#{OFFLINE_PAGE_DB_UUID}'\nENGINE = Atomic\n")
    File.write(
      File.join(database_path, "events.sql"),
      "ATTACH TABLE _ UUID '#{OFFLINE_PAGE_TABLE_UUID}'\n(\n#{columns}\n)\nENGINE = MergeTree\nORDER BY tuple()\n"
    )
    File.write(File.join(table_path, "format_version.txt"), "1\n")
    Dir.mkdir(File.join(table_path, "detached"))
    if fixture = fixture_path
      FileUtils.cp_r(fixture, File.join(table_path, "all_1_1_0"))
    end
    if setup = setup_part
      setup.call(table_path)
    end
    yield CrystalClick::OfflineCatalog.open(root).table("lab", "events"), table_path
  ensure
    FileUtils.rm_rf(root)
  end
end

describe CrystalClick::Examples::OfflinePageSource do
  it "returns bounded consecutive pages including a short final page with owned display strings" do
    with_offline_page_table do |table, _table_path|
      source = CrystalClick::Examples::OfflinePageSource.new(table, ["label", "maybe_u64"], 2)

      first = source.load(0_u64)
      first.start_row.should eq(0_u64)
      first.end_row.should eq(2_u64)
      first.total_rows.should eq(5_u64)
      first.column_names.should eq(["label", "maybe_u64"])
      first.rows.should eq([["\"\"", "0"], ["\"alpha\"", "NULL"]])
      first.row_offsets.should eq([0_u64, 1_u64])

      second = source.load(2_u64)
      second.start_row.should eq(2_u64)
      second.end_row.should eq(4_u64)
      second.rows.size.should eq(2)
      second.row_offsets.should eq([2_u64, 3_u64])
      second.rows[1].should eq(["\"tail\"", "7"])

      final = source.load(4_u64)
      final.end_row.should eq(5_u64)
      final.rows.should eq([["\"\"", "NULL"]])
      final.row_offsets.should eq([4_u64])
      eof = source.load(5_u64)
      eof.end_row.should eq(5_u64)
      eof.rows.should be_empty
      eof.row_offsets.should be_empty
      first.rows.should eq([["\"\"", "0"], ["\"alpha\"", "NULL"]])
    end
  end

  it "keeps equality pages on physical windows when a later UInt64 match follows a zero-hit page" do
    numeric_columns = "    `u8` UInt8,\n    `u16` UInt16,\n    `u32` UInt32,\n    `u64` UInt64,\n" +
                      "    `i8` Int8,\n    `i16` Int16,\n    `i32` Int32,\n    `i64` Int64,\n" +
                      "    `f32` Float32,\n    `f64` Float64"
    with_offline_page_table(numeric_columns, OFFLINE_PAGE_NUMERIC_FIXTURE) do |table, _table_path|
      source = CrystalClick::Examples::OfflinePageSource.new(table, ["u64"], 2)
      equality = CrystalClick::Examples::OfflineEqualityFilter.new("u64", UInt64::MAX)

      first = source.load(0_u64, equality)
      first.start_row.should eq(0_u64)
      first.end_row.should eq(2_u64)
      first.total_rows.should eq(4_u64)
      first.rows.should be_empty
      first.row_offsets.should be_empty

      late = source.load(first.end_row, equality)
      late.start_row.should eq(2_u64)
      late.end_row.should eq(4_u64)
      late.rows.should eq([[UInt64::MAX.to_s]])
      late.row_offsets.should eq([2_u64])
    end
  end

  it "compares raw String values before display truncation" do
    columns = "    `seq` UInt64,\n    `payload` String"
    prefix = "x" * 300
    expected = prefix + "B"
    keys = [0_u64, 1_u64]
    values = [prefix + "A", expected]
    setup_part = ->(table_path : String) : Nil {
      CrystalClick::WidePartWriter.write_uint64_string_pair(
        File.join(table_path, "all_1_1_0"),
        "seq",
        keys.to_unsafe.to_slice(keys.size),
        "payload",
        values.to_unsafe.to_slice(values.size),
        1
      )
      nil
    }

    with_offline_page_table(columns, nil, setup_part) do |table, _table_path|
      source = CrystalClick::Examples::OfflinePageSource.new(table, ["payload"], 2)
      page = source.load(0_u64, CrystalClick::Examples::OfflineEqualityFilter.new("payload", expected))

      page.end_row.should eq(2_u64)
      page.rows.size.should eq(1)
      page.row_offsets.should eq([1_u64])
      page.rows[0][0].should start_with("[truncated] ")
      page.rows[0][0].should eq("[truncated] #{(prefix + "A").byte_slice(0, 256).inspect}")
    end
  end

  it "matches an empty String exactly and reports a filtered EOF window" do
    with_offline_page_table do |table, _table_path|
      source = CrystalClick::Examples::OfflinePageSource.new(table, ["label"], 2)
      equality = CrystalClick::Examples::OfflineEqualityFilter.new("label", "")

      first = source.load(0_u64, equality)
      first.rows.should eq([["\"\""]])
      first.row_offsets.should eq([0_u64])
      first.end_row.should eq(2_u64)

      middle = source.load(first.end_row, equality)
      middle.rows.should be_empty
      middle.row_offsets.should be_empty
      middle.end_row.should eq(4_u64)

      final = source.load(middle.end_row, equality)
      final.rows.should eq([["\"\""]])
      final.row_offsets.should eq([4_u64])
      final.end_row.should eq(5_u64)

      eof = source.load(final.end_row, equality)
      eof.rows.should be_empty
      eof.row_offsets.should be_empty
      eof.end_row.should eq(5_u64)
    end
  end

  it "rejects unselected columns, unsupported types, and mismatched equality values" do
    with_offline_page_table do |table, _table_path|
      source = CrystalClick::Examples::OfflinePageSource.new(table, ["label"], 2)

      expect_raises(CrystalClick::UnsupportedFormatError) do
        source.load(0_u64, CrystalClick::Examples::OfflineEqualityFilter.new("maybe_u64", 1_u64))
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        source.load(0_u64, CrystalClick::Examples::OfflineEqualityFilter.new("label", 1_u64))
      end

      no_hits = source.load(0_u64, CrystalClick::Examples::OfflineEqualityFilter.new("label", "label"))
      no_hits.rows.should be_empty
      no_hits.row_offsets.should be_empty
      no_hits.end_row.should eq(2_u64)

      nullable_source = CrystalClick::Examples::OfflinePageSource.new(table, ["maybe_u64"], 2)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        nullable_source.load(0_u64, CrystalClick::Examples::OfflineEqualityFilter.new("maybe_u64", 1_u64))
      end
    end
  end

  it "escapes embedded NUL and rejects a window past the table end" do
    with_offline_page_table do |table, _table_path|
      source = CrystalClick::Examples::OfflinePageSource.new(table, ["label", "maybe_u64"], 2)
      cell = source.load(2_u64).rows[0][0]

      cell.should start_with("\"")
      cell.should end_with("\"")
      cell.each_byte.all? { |byte| byte >= 0x20 && byte != 0x7f }.should be_true
      expect_raises(CrystalClick::BoundsError) { source.load(6_u64) }
    end
  end

  it "caps and quotes long String cells while escaping terminal controls" do
    columns = "    `seq` UInt64,\n    `payload` String"
    exact_limit = "\0\n\t\e" + ("x" * 252)
    setup_part = ->(table_path : String) : Nil {
      keys = [0_u64, 1_u64]
      values = [exact_limit, exact_limit + "extra"]
      CrystalClick::WidePartWriter.write_uint64_string_pair(
        File.join(table_path, "all_1_1_0"),
        "seq",
        keys.to_unsafe.to_slice(keys.size),
        "payload",
        values.to_unsafe.to_slice(values.size),
        1
      )
      nil
    }

    with_offline_page_table(columns, nil, setup_part) do |table, _table_path|
      source = CrystalClick::Examples::OfflinePageSource.new(table, ["payload"], 1)
      exact_display = source.load(0_u64).rows[0][0]
      display = source.load(1_u64).rows[0][0]
      exact_display.should start_with("\"")
      display.should start_with("[truncated] \"")
      display.should_not eq(exact_display)
      display.should end_with("\"")
      display.each_byte.all? { |byte| byte >= 0x20 && byte != 0x7f }.should be_true
      display.count('x').should be <= 256
      display.bytesize.should be <= 1040
    end
  end

  it "rejects unsupported selected types and page sizes above the example bound" do
    columns = "    `payload` Array(String)"
    with_offline_page_table(columns, nil) do |table, _table_path|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::Examples::OfflinePageSource.new(table, ["payload"], 1).load(0_u64)
      end
      expect_raises(CrystalClick::BoundsError) do
        CrystalClick::Examples::OfflinePageSource.new(table, ["payload"], 257)
      end
    end
  end

  it "formats all primitive numeric types and Nullable(String) from public parts" do
    numeric_columns = "    `u8` UInt8,\n    `u16` UInt16,\n    `u32` UInt32,\n    `u64` UInt64,\n" +
                      "    `i8` Int8,\n    `i16` Int16,\n    `i32` Int32,\n    `i64` Int64,\n" +
                      "    `f32` Float32,\n    `f64` Float64"
    with_offline_page_table(numeric_columns, OFFLINE_PAGE_NUMERIC_FIXTURE) do |table, _table_path|
      names = %w[u8 u16 u32 u64 i8 i16 i32 i64 f32 f64]
      page = CrystalClick::Examples::OfflinePageSource.new(table, names, 4).load(0_u64)
      page.rows.size.should eq(4)
      page.rows[0][0..7].should eq(["0", "0", "0", "0", "-128", "-32768", "-2147483648", Int64::MIN.to_s])
      page.rows[2][0..7].should eq(["255", "65535", UInt32::MAX.to_s, UInt64::MAX.to_s, "0", "0", "0", "0"])
      page.rows[2][8..9].should eq(["1.5", "1.5"])
    end

    nullable_columns = "    `seq` UInt64,\n    `payload` Nullable(String)"
    with_offline_page_table(nullable_columns, OFFLINE_PAGE_NULLABLE_STRING_FIXTURE) do |table, _table_path|
      page = CrystalClick::Examples::OfflinePageSource.new(table, ["payload"], 6).load(0_u64)
      page.rows.map(&.[0]).should eq(["\"P\"", "NULL", "\"Q\"", "\"\"", "\"a\\u0000b\"", "\"z\""])
    end
  end

  it "returns an empty page for an empty table without materializing rows" do
    with_offline_page_table("    `seq` UInt64", nil) do |table, _table_path|
      page = CrystalClick::Examples::OfflinePageSource.new(table, ["seq"], 2).load(0_u64)
      page.total_rows.should eq(0_u64)
      page.rows.should be_empty
      filtered = CrystalClick::Examples::OfflinePageSource.new(table, ["seq"], 2).load(
        0_u64,
        CrystalClick::Examples::OfflineEqualityFilter.new("seq", 0_u64)
      )
      filtered.end_row.should eq(0_u64)
      filtered.rows.should be_empty
      filtered.row_offsets.should be_empty
    end
  end
end
