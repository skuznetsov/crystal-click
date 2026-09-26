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

  it "displays Date and Date32 as lossless raw day codes without treating them as numeric filters" do
    keys = [1_u64, 2_u64, 3_u64]
    date_codes = [0_u16, 1_u16, UInt16::MAX]
    date_setup = ->(table_path : String) : Nil {
      CrystalClick::WidePartWriter.write_uint64_date_pair(
        File.join(table_path, "all_1_1_0"), "seq", keys.to_unsafe.to_slice(keys.size),
        "event_date", date_codes.to_unsafe.to_slice(date_codes.size), 2
      )
      nil
    }
    with_offline_page_table("    `seq` UInt64,\n    `event_date` Date", nil, date_setup) do |table, _table_path|
      source = CrystalClick::Examples::OfflinePageSource.new(table, ["event_date"], 2)
      source.load(0_u64).rows.should eq([["0"], ["1"]])
      source.load(2_u64).rows.should eq([[UInt16::MAX.to_s]])
      expect_raises(CrystalClick::UnsupportedFormatError) do
        source.load(0_u64, CrystalClick::Examples::OfflineEqualityFilter.new("event_date", 0_u64))
      end
    end

    date32_codes = [Int32::MIN, -1_i32, Int32::MAX]
    date32_setup = ->(table_path : String) : Nil {
      CrystalClick::WidePartWriter.write_uint64_date32_pair(
        File.join(table_path, "all_1_1_0"), "seq", keys.to_unsafe.to_slice(keys.size),
        "event_date", date32_codes.to_unsafe.to_slice(date32_codes.size), 2
      )
      nil
    }
    with_offline_page_table("    `seq` UInt64,\n    `event_date` Date32", nil, date32_setup) do |table, _table_path|
      source = CrystalClick::Examples::OfflinePageSource.new(table, ["event_date"], 2)
      source.load(0_u64).rows.should eq([[Int32::MIN.to_s], ["-1"]])
      source.load(2_u64).rows.should eq([[Int32::MAX.to_s]])
      expect_raises(CrystalClick::UnsupportedFormatError) do
        source.load(0_u64, CrystalClick::Examples::OfflineEqualityFilter.new("event_date", 0_u64))
      end
    end
  end

  it "displays DateTime seconds and DateTime64 ticks as raw codes without numeric filters" do
    keys = [1_u64, 2_u64, 3_u64]
    seconds = [0_u32, 1_u32, UInt32::MAX]
    datetime_setup = ->(table_path : String) : Nil {
      CrystalClick::WidePartWriter.write_uint64_datetime_pair(
        File.join(table_path, "all_1_1_0"), "seq", keys.to_unsafe.to_slice(keys.size),
        "event_time", seconds.to_unsafe.to_slice(seconds.size), 2
      )
      nil
    }
    with_offline_page_table("    `seq` UInt64,\n    `event_time` DateTime", nil, datetime_setup) do |table, _table_path|
      source = CrystalClick::Examples::OfflinePageSource.new(table, ["event_time"], 2)
      source.load(0_u64).rows.should eq([["0"], ["1"]])
      source.load(2_u64).rows.should eq([[UInt32::MAX.to_s]])
      expect_raises(CrystalClick::UnsupportedFormatError) do
        source.load(0_u64, CrystalClick::Examples::OfflineEqualityFilter.new("event_time", 0_u64))
      end
    end

    ticks = [Int64::MIN, -1_i64, Int64::MAX]
    datetime64_setup = ->(table_path : String) : Nil {
      CrystalClick::WidePartWriter.write_uint64_datetime64_pair(
        File.join(table_path, "all_1_1_0"), "seq", keys.to_unsafe.to_slice(keys.size),
        "event_time", ticks.to_unsafe.to_slice(ticks.size), 3, 2
      )
      nil
    }
    with_offline_page_table("    `seq` UInt64,\n    `event_time` DateTime64(3)", nil, datetime64_setup) do |table, _table_path|
      source = CrystalClick::Examples::OfflinePageSource.new(table, ["event_time"], 2)
      source.load(0_u64).rows.should eq([["#{Int64::MIN} [p=3]"], ["-1 [p=3]"]])
      source.load(2_u64).rows.should eq([["#{Int64::MAX} [p=3]"]])
      expect_raises(CrystalClick::UnsupportedFormatError) do
        source.load(0_u64, CrystalClick::Examples::OfflineEqualityFilter.new("event_time", 0_u64))
      end
    end
  end

  it "displays nullable date/time codes without confusing NULL with raw zero" do
    keys = [1_u64, 2_u64, 3_u64]

    dates = [nil, 0_u16.as(UInt16?), UInt16::MAX.as(UInt16?)]
    date_setup = ->(table_path : String) : Nil {
      CrystalClick::WidePartWriter.write_uint64_nullable_date_pair(
        File.join(table_path, "all_1_1_0"), "seq", keys.to_unsafe.to_slice(keys.size),
        "event_date", dates.to_unsafe.to_slice(dates.size), 2
      )
      nil
    }
    with_offline_page_table("    `seq` UInt64,\n    `event_date` Nullable(Date)", nil, date_setup) do |table, _table_path|
      source = CrystalClick::Examples::OfflinePageSource.new(table, ["event_date"], 2)
      source.load(0_u64).rows.should eq([["NULL"], ["0"]])
      source.load(2_u64).rows.should eq([[UInt16::MAX.to_s]])
      expect_raises(CrystalClick::UnsupportedFormatError) do
        source.load(0_u64, CrystalClick::Examples::OfflineEqualityFilter.new("event_date", 0_u64))
      end
    end

    date32_codes = [Int32::MIN.as(Int32?), nil, 0_i32.as(Int32?)]
    date32_setup = ->(table_path : String) : Nil {
      CrystalClick::WidePartWriter.write_uint64_nullable_date32_pair(
        File.join(table_path, "all_1_1_0"), "seq", keys.to_unsafe.to_slice(keys.size),
        "event_date", date32_codes.to_unsafe.to_slice(date32_codes.size), 2
      )
      nil
    }
    with_offline_page_table("    `seq` UInt64,\n    `event_date` Nullable(Date32)", nil, date32_setup) do |table, _table_path|
      source = CrystalClick::Examples::OfflinePageSource.new(table, ["event_date"], 2)
      source.load(0_u64).rows.should eq([[Int32::MIN.to_s], ["NULL"]])
      source.load(2_u64).rows.should eq([["0"]])
    end

    seconds = [nil, 0_u32.as(UInt32?), UInt32::MAX.as(UInt32?)]
    datetime_setup = ->(table_path : String) : Nil {
      CrystalClick::WidePartWriter.write_uint64_nullable_datetime_pair(
        File.join(table_path, "all_1_1_0"), "seq", keys.to_unsafe.to_slice(keys.size),
        "event_time", seconds.to_unsafe.to_slice(seconds.size), 2
      )
      nil
    }
    with_offline_page_table("    `seq` UInt64,\n    `event_time` Nullable(DateTime)", nil, datetime_setup) do |table, _table_path|
      source = CrystalClick::Examples::OfflinePageSource.new(table, ["event_time"], 2)
      source.load(0_u64).rows.should eq([["NULL"], ["0"]])
      source.load(2_u64).rows.should eq([[UInt32::MAX.to_s]])
    end

    ticks = [nil, Int64::MIN.as(Int64?), 0_i64.as(Int64?)]
    datetime64_setup = ->(table_path : String) : Nil {
      CrystalClick::WidePartWriter.write_uint64_nullable_datetime64_pair(
        File.join(table_path, "all_1_1_0"), "seq", keys.to_unsafe.to_slice(keys.size),
        "event_time", ticks.to_unsafe.to_slice(ticks.size), 3, 2
      )
      nil
    }
    with_offline_page_table("    `seq` UInt64,\n    `event_time` Nullable(DateTime64(3))", nil, datetime64_setup) do |table, _table_path|
      source = CrystalClick::Examples::OfflinePageSource.new(table, ["event_time"], 2)
      source.load(0_u64).rows.should eq([["NULL"], ["#{Int64::MIN} [p=3]"]])
      source.load(2_u64).rows.should eq([["0 [p=3]"]])
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

  it "formats FixedString values and distinguishes Nullable(FixedString) NULLs" do
    keys = [1_u64, 2_u64, 3_u64]
    fixed_values = ["a", "xy", ""]
    fixed_setup = ->(table_path : String) : Nil {
      CrystalClick::WidePartWriter.write_uint64_fixed_string_pair(
        File.join(table_path, "all_1_1_0"), "seq", keys.to_unsafe.to_slice(keys.size),
        "payload", fixed_values.to_unsafe.to_slice(fixed_values.size), 3, 2
      )
      nil
    }
    with_offline_page_table("    `seq` UInt64,\n    `payload` FixedString(3)", nil, fixed_setup) do |table, _table_path|
      page = CrystalClick::Examples::OfflinePageSource.new(table, ["payload"], 3).load(0_u64)
      page.rows.map(&.[0]).should eq(["\"a\\u0000\\u0000\"", "\"xy\\u0000\"", "\"\\u0000\\u0000\\u0000\""])
    end

    nullable_values = [nil, "b", "xy"]
    nullable_setup = ->(table_path : String) : Nil {
      CrystalClick::WidePartWriter.write_uint64_nullable_fixed_string_pair(
        File.join(table_path, "all_1_1_0"), "seq", keys.to_unsafe.to_slice(keys.size),
        "payload", nullable_values.to_unsafe.to_slice(nullable_values.size), 3, 2
      )
      nil
    }
    with_offline_page_table("    `seq` UInt64,\n    `payload` Nullable(FixedString(3))", nil, nullable_setup) do |table, _table_path|
      page = CrystalClick::Examples::OfflinePageSource.new(table, ["payload"], 3).load(0_u64)
      page.rows.map(&.[0]).should eq(["NULL", "\"b\\u0000\\u0000\"", "\"xy\\u0000\""])
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

  it "formats Bool semantically and keeps Nullable(Bool) NULL distinct from false" do
    keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
    values = [false, true, false, true, true]
    bool_setup = ->(table_path : String) : Nil {
      CrystalClick::WidePartWriter.write_uint64_bool_pair(
        File.join(table_path, "all_1_1_0"), "seq", keys.to_unsafe.to_slice(keys.size),
        "flag", values.to_unsafe.to_slice(values.size), 2
      )
      nil
    }
    with_offline_page_table("    `seq` UInt64,\n    `flag` Bool", nil, bool_setup) do |table, _table_path|
      page = CrystalClick::Examples::OfflinePageSource.new(table, ["flag"], 5).load(0_u64)
      page.rows.map(&.[0]).should eq(["false", "true", "false", "true", "true"])
      table["flag"].values.should eq(values)
    end

    nullable_values = [nil, false.as(Bool?), true.as(Bool?), nil, false.as(Bool?)]
    nullable_setup = ->(table_path : String) : Nil {
      CrystalClick::WidePartWriter.write_uint64_nullable_bool_pair(
        File.join(table_path, "all_1_1_0"), "seq", keys.to_unsafe.to_slice(keys.size),
        "flag", nullable_values.to_unsafe.to_slice(nullable_values.size), 2
      )
      nil
    }
    with_offline_page_table("    `seq` UInt64,\n    `flag` Nullable(Bool)", nil, nullable_setup) do |table, _table_path|
      page = CrystalClick::Examples::OfflinePageSource.new(table, ["flag"], 5).load(0_u64)
      page.rows.map(&.[0]).should eq(["NULL", "false", "true", "NULL", "false"])
      table["flag"].values.should eq(nullable_values)
    end
  end

  it "formats Enum8 signed codes and Nullable(Enum8) NULLs without decoding labels" do
    keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
    enum_type = "Enum8('neg' = -7, 'zero' = 0, 'pos' = 7)"
    values = [-7_i8, 0_i8, 7_i8, -7_i8, 7_i8]
    setup = ->(table_path : String) : Nil {
      CrystalClick::WidePartWriter.write_uint64_enum8_pair(
        File.join(table_path, "all_1_1_0"), "seq", keys.to_unsafe.to_slice(keys.size),
        "state", values.to_unsafe.to_slice(values.size), enum_type, 2
      )
      nil
    }
    with_offline_page_table("    `seq` UInt64,\n    `state` #{enum_type}", nil, setup) do |table, _table_path|
      page = CrystalClick::Examples::OfflinePageSource.new(table, ["state"], 5).load(0_u64)
      page.rows.map(&.[0]).should eq(["-7", "0", "7", "-7", "7"])
      table["state"].values.should eq(values)
    end

    nullable_values = [nil, -7_i8.as(Int8?), 7_i8.as(Int8?), nil, -7_i8.as(Int8?)]
    nullable_setup = ->(table_path : String) : Nil {
      CrystalClick::WidePartWriter.write_uint64_nullable_enum8_pair(
        File.join(table_path, "all_1_1_0"), "seq", keys.to_unsafe.to_slice(keys.size),
        "state", nullable_values.to_unsafe.to_slice(nullable_values.size), enum_type, 2
      )
      nil
    }
    with_offline_page_table("    `seq` UInt64,\n    `state` Nullable(#{enum_type})", nil, nullable_setup) do |table, _table_path|
      page = CrystalClick::Examples::OfflinePageSource.new(table, ["state"], 5).load(0_u64)
      page.rows.map(&.[0]).should eq(["NULL", "-7", "7", "NULL", "-7"])
      table["state"].values.should eq(nullable_values)
    end
  end

  it "formats Enum16 signed codes and Nullable(Enum16) NULLs without decoding labels" do
    keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
    enum_type = "Enum16('neg' = -257, 'zero' = 0, 'pos' = 257)"
    values = [-257_i16, 0_i16, 257_i16, -257_i16, 257_i16]
    setup = ->(table_path : String) : Nil {
      CrystalClick::WidePartWriter.write_uint64_enum16_pair(
        File.join(table_path, "all_1_1_0"), "seq", keys.to_unsafe.to_slice(keys.size),
        "state", values.to_unsafe.to_slice(values.size), enum_type, 2
      )
      nil
    }
    with_offline_page_table("    `seq` UInt64,\n    `state` #{enum_type}", nil, setup) do |table, _table_path|
      page = CrystalClick::Examples::OfflinePageSource.new(table, ["state"], 5).load(0_u64)
      page.rows.map(&.[0]).should eq(["-257", "0", "257", "-257", "257"])
    end

    nullable_values = [nil, -257_i16.as(Int16?), 257_i16.as(Int16?), nil, -257_i16.as(Int16?)]
    nullable_setup = ->(table_path : String) : Nil {
      CrystalClick::WidePartWriter.write_uint64_nullable_enum16_pair(
        File.join(table_path, "all_1_1_0"), "seq", keys.to_unsafe.to_slice(keys.size),
        "state", nullable_values.to_unsafe.to_slice(nullable_values.size), enum_type, 2
      )
      nil
    }
    with_offline_page_table("    `seq` UInt64,\n    `state` Nullable(#{enum_type})", nil, nullable_setup) do |table, _table_path|
      page = CrystalClick::Examples::OfflinePageSource.new(table, ["state"], 5).load(0_u64)
      page.rows.map(&.[0]).should eq(["NULL", "-257", "257", "NULL", "-257"])
    end
  end

  it "formats Decimal(9, S) as raw scaled codes and preserves Nullable NULLs" do
    keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
    values = [-12_345_i32, -1_i32, 0_i32, 1_i32, 12_345_i32]
    setup = ->(table_path : String) : Nil {
      CrystalClick::WidePartWriter.write_uint64_decimal32_pair(
        File.join(table_path, "all_1_1_0"), "seq", keys.to_unsafe.to_slice(keys.size),
        "amount", values.to_unsafe.to_slice(values.size), 2, 2
      )
      nil
    }
    with_offline_page_table("    `seq` UInt64,\n    `amount` Decimal(9, 2)", nil, setup) do |table, _table_path|
      page = CrystalClick::Examples::OfflinePageSource.new(table, ["amount"], 5).load(0_u64)
      page.rows.map(&.[0]).should eq(["-12345 [s=2]", "-1 [s=2]", "0 [s=2]", "1 [s=2]", "12345 [s=2]"])
    end

    nullable_values = [nil, -123_i32.as(Int32?), 0_i32.as(Int32?), nil, 456_i32.as(Int32?)]
    nullable_setup = ->(table_path : String) : Nil {
      CrystalClick::WidePartWriter.write_uint64_nullable_decimal32_pair(
        File.join(table_path, "all_1_1_0"), "seq", keys.to_unsafe.to_slice(keys.size),
        "amount", nullable_values.to_unsafe.to_slice(nullable_values.size), 2, 2
      )
      nil
    }
    with_offline_page_table("    `seq` UInt64,\n    `amount` Nullable(Decimal(9, 2))", nil, nullable_setup) do |table, _table_path|
      page = CrystalClick::Examples::OfflinePageSource.new(table, ["amount"], 5).load(0_u64)
      page.rows.map(&.[0]).should eq(["NULL", "-123 [s=2]", "0 [s=2]", "NULL", "456 [s=2]"])
    end
  end

  it "formats Decimal(18, S) as raw scaled codes and preserves Nullable NULLs" do
    keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
    values = [-123_456_789_i64, -1_i64, 0_i64, 1_i64, 123_456_789_i64]
    setup = ->(table_path : String) : Nil {
      CrystalClick::WidePartWriter.write_uint64_decimal64_pair(
        File.join(table_path, "all_1_1_0"), "seq", keys.to_unsafe.to_slice(keys.size),
        "amount", values.to_unsafe.to_slice(values.size), 4, 2
      )
      nil
    }
    with_offline_page_table("    `seq` UInt64,\n    `amount` Decimal(18, 4)", nil, setup) do |table, _table_path|
      page = CrystalClick::Examples::OfflinePageSource.new(table, ["amount"], 5).load(0_u64)
      page.rows.map(&.[0]).should eq(["-123456789 [s=4]", "-1 [s=4]", "0 [s=4]", "1 [s=4]", "123456789 [s=4]"])
    end

    nullable_values = [nil, -12_345_i64.as(Int64?), 0_i64.as(Int64?), nil, 67_890_i64.as(Int64?)]
    nullable_setup = ->(table_path : String) : Nil {
      CrystalClick::WidePartWriter.write_uint64_nullable_decimal64_pair(
        File.join(table_path, "all_1_1_0"), "seq", keys.to_unsafe.to_slice(keys.size),
        "amount", nullable_values.to_unsafe.to_slice(nullable_values.size), 4, 2
      )
      nil
    }
    with_offline_page_table("    `seq` UInt64,\n    `amount` Nullable(Decimal(18, 4))", nil, nullable_setup) do |table, _table_path|
      page = CrystalClick::Examples::OfflinePageSource.new(table, ["amount"], 5).load(0_u64)
      page.rows.map(&.[0]).should eq(["NULL", "-12345 [s=4]", "0 [s=4]", "NULL", "67890 [s=4]"])
    end
  end

  it "normalizes Decimal32 and Decimal64 aliases before formatting typed pages" do
    keys = [1_u64, 2_u64, 3_u64]

    decimal32_values = [-12_345_i32, 0_i32, 12_345_i32]
    decimal32_setup = ->(table_path : String) : Nil {
      CrystalClick::WidePartWriter.write_uint64_decimal32_pair(
        File.join(table_path, "all_1_1_0"), "seq", keys.to_unsafe.to_slice(keys.size),
        "amount", decimal32_values.to_unsafe.to_slice(decimal32_values.size), 2, 2
      )
      nil
    }
    with_offline_page_table("    `seq` UInt64,\n    `amount` Decimal32(2)", nil, decimal32_setup) do |table, _table_path|
      page = CrystalClick::Examples::OfflinePageSource.new(table, ["amount"], 3).load(0_u64)
      page.rows.map(&.[0]).should eq(["-12345 [s=2]", "0 [s=2]", "12345 [s=2]"])
      table["amount"].values.should eq(decimal32_values)
    end

    nullable_decimal32_values = [nil, 0_i32.as(Int32?), 12_345_i32.as(Int32?)]
    nullable_decimal32_setup = ->(table_path : String) : Nil {
      CrystalClick::WidePartWriter.write_uint64_nullable_decimal32_pair(
        File.join(table_path, "all_1_1_0"), "seq", keys.to_unsafe.to_slice(keys.size),
        "amount", nullable_decimal32_values.to_unsafe.to_slice(nullable_decimal32_values.size), 2, 2
      )
      nil
    }
    with_offline_page_table("    `seq` UInt64,\n    `amount` Nullable(Decimal32(2))", nil, nullable_decimal32_setup) do |table, _table_path|
      page = CrystalClick::Examples::OfflinePageSource.new(table, ["amount"], 3).load(0_u64)
      page.rows.map(&.[0]).should eq(["NULL", "0 [s=2]", "12345 [s=2]"])
    end

    decimal64_values = [-123_456_i64, 0_i64, 123_456_i64]
    decimal64_setup = ->(table_path : String) : Nil {
      CrystalClick::WidePartWriter.write_uint64_decimal64_pair(
        File.join(table_path, "all_1_1_0"), "seq", keys.to_unsafe.to_slice(keys.size),
        "amount", decimal64_values.to_unsafe.to_slice(decimal64_values.size), 4, 2
      )
      nil
    }
    with_offline_page_table("    `seq` UInt64,\n    `amount` Decimal64(4)", nil, decimal64_setup) do |table, _table_path|
      page = CrystalClick::Examples::OfflinePageSource.new(table, ["amount"], 3).load(0_u64)
      page.rows.map(&.[0]).should eq(["-123456 [s=4]", "0 [s=4]", "123456 [s=4]"])
    end

    nullable_decimal64_values = [nil, 0_i64.as(Int64?), 123_456_i64.as(Int64?)]
    nullable_decimal64_setup = ->(table_path : String) : Nil {
      CrystalClick::WidePartWriter.write_uint64_nullable_decimal64_pair(
        File.join(table_path, "all_1_1_0"), "seq", keys.to_unsafe.to_slice(keys.size),
        "amount", nullable_decimal64_values.to_unsafe.to_slice(nullable_decimal64_values.size), 4, 2
      )
      nil
    }
    with_offline_page_table("    `seq` UInt64,\n    `amount` Nullable(Decimal64(4))", nil, nullable_decimal64_setup) do |table, _table_path|
      page = CrystalClick::Examples::OfflinePageSource.new(table, ["amount"], 3).load(0_u64)
      page.rows.map(&.[0]).should eq(["NULL", "0 [s=4]", "123456 [s=4]"])
    end
  end

  it "formats Decimal128 raw codes and keeps Nullable NULL distinct from zero" do
    keys = [1_u64, 2_u64, 3_u64]
    large = 1_i128 << 80
    values = [-1_i128, 0_i128, large]
    setup = ->(table_path : String) : Nil {
      CrystalClick::WidePartWriter.write_uint64_decimal128_pair(
        File.join(table_path, "all_1_1_0"), "seq", keys.to_unsafe.to_slice(keys.size),
        "amount", values.to_unsafe.to_slice(values.size), 2, 2
      )
      nil
    }
    with_offline_page_table("    `seq` UInt64,\n    `amount` Decimal128(2)", nil, setup) do |table, _table_path|
      page = CrystalClick::Examples::OfflinePageSource.new(table, ["amount"], 2).load(0_u64)
      page.rows.should eq([["-1 [s=2]"], ["0 [s=2]"]])
      CrystalClick::Examples::OfflinePageSource.new(table, ["amount"], 2).load(2_u64).rows.should eq([["#{large} [s=2]"]])
      table["amount"].values.should eq(values)
    end

    nullable_values = [nil, 0_i128.as(Int128?), large.as(Int128?)]
    nullable_setup = ->(table_path : String) : Nil {
      CrystalClick::WidePartWriter.write_uint64_nullable_decimal128_pair(
        File.join(table_path, "all_1_1_0"), "seq", keys.to_unsafe.to_slice(keys.size),
        "amount", nullable_values.to_unsafe.to_slice(nullable_values.size), 2, 2
      )
      nil
    }
    with_offline_page_table("    `seq` UInt64,\n    `amount` Nullable(Decimal128(2))", nil, nullable_setup) do |table, _table_path|
      page = CrystalClick::Examples::OfflinePageSource.new(table, ["amount"], 3).load(0_u64)
      page.rows.should eq([["NULL"], ["0 [s=2]"], ["#{large} [s=2]"]])
      table["amount"].values.should eq(nullable_values)
    end
  end

  it "formats UUID values canonically and keeps Nullable NULL distinct from zero UUID" do
    keys = [1_u64, 2_u64, 3_u64]
    zero = CrystalClick::UUIDValue.new(0_u64, 0_u64)
    asymmetric = CrystalClick::UUIDValue.new(0x61f0c4045cb311e7_u64, 0x907ba6006ad3dba0_u64)
    other = CrystalClick::UUIDValue.new(0x123456789abcdef0_u64, 0x0fedcba987654321_u64)
    values = [zero, asymmetric, other]
    setup = ->(table_path : String) : Nil {
      CrystalClick::WidePartWriter.write_uint64_uuid_pair(
        File.join(table_path, "all_1_1_0"), "seq", keys.to_unsafe.to_slice(keys.size),
        "identifier", values.to_unsafe.to_slice(values.size), 2
      )
      nil
    }
    with_offline_page_table("    `seq` UInt64,\n    `identifier` UUID", nil, setup) do |table, _table_path|
      source = CrystalClick::Examples::OfflinePageSource.new(table, ["identifier"], 2)
      source.load(0_u64).rows.should eq([
        ["00000000-0000-0000-0000-000000000000"],
        ["61f0c404-5cb3-11e7-907b-a6006ad3dba0"],
      ])
      source.load(2_u64).rows.should eq([["12345678-9abc-def0-0fed-cba987654321"]])
      table["identifier"].values.should eq(values)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        source.load(0_u64, CrystalClick::Examples::OfflineEqualityFilter.new("identifier", asymmetric.to_s))
      end
    end

    nullable_values = [nil, zero.as(CrystalClick::UUIDValue?), asymmetric.as(CrystalClick::UUIDValue?)]
    nullable_setup = ->(table_path : String) : Nil {
      CrystalClick::WidePartWriter.write_uint64_nullable_uuid_pair(
        File.join(table_path, "all_1_1_0"), "seq", keys.to_unsafe.to_slice(keys.size),
        "identifier", nullable_values.to_unsafe.to_slice(nullable_values.size), 2
      )
      nil
    }
    with_offline_page_table("    `seq` UInt64,\n    `identifier` Nullable(UUID)", nil, nullable_setup) do |table, _table_path|
      source = CrystalClick::Examples::OfflinePageSource.new(table, ["identifier"], 3)
      source.load(0_u64).rows.should eq([
        ["NULL"],
        ["00000000-0000-0000-0000-000000000000"],
        ["61f0c404-5cb3-11e7-907b-a6006ad3dba0"],
      ])
      table["identifier"].values.should eq(nullable_values)
    end
  end

  it "formats IPv4 values canonically and keeps Nullable NULL distinct from 0.0.0.0" do
    keys = [1_u64, 2_u64, 3_u64]
    zero = CrystalClick::IPv4Value.from_octets(0_u8, 0_u8, 0_u8, 0_u8)
    asymmetric = CrystalClick::IPv4Value.from_octets(1_u8, 2_u8, 3_u8, 4_u8)
    reversed = CrystalClick::IPv4Value.from_octets(4_u8, 3_u8, 2_u8, 1_u8)
    values = [zero, asymmetric, reversed]
    setup = ->(table_path : String) : Nil {
      CrystalClick::WidePartWriter.write_uint64_ipv4_pair(
        File.join(table_path, "all_1_1_0"), "seq", keys.to_unsafe.to_slice(keys.size),
        "address", values.to_unsafe.to_slice(values.size), 2
      )
      nil
    }
    with_offline_page_table("    `seq` UInt64,\n    `address` IPv4", nil, setup) do |table, _table_path|
      source = CrystalClick::Examples::OfflinePageSource.new(table, ["address"], 2)
      source.load(0_u64).rows.should eq([["0.0.0.0"], ["1.2.3.4"]])
      source.load(2_u64).rows.should eq([["4.3.2.1"]])
      table["address"].values.should eq(values)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        source.load(0_u64, CrystalClick::Examples::OfflineEqualityFilter.new("address", "1.2.3.4"))
      end
    end

    nullable_values = [nil, zero.as(CrystalClick::IPv4Value?), asymmetric.as(CrystalClick::IPv4Value?)]
    nullable_setup = ->(table_path : String) : Nil {
      CrystalClick::WidePartWriter.write_uint64_nullable_ipv4_pair(
        File.join(table_path, "all_1_1_0"), "seq", keys.to_unsafe.to_slice(keys.size),
        "address", nullable_values.to_unsafe.to_slice(nullable_values.size), 2
      )
      nil
    }
    with_offline_page_table("    `seq` UInt64,\n    `address` Nullable(IPv4)", nil, nullable_setup) do |table, _table_path|
      source = CrystalClick::Examples::OfflinePageSource.new(table, ["address"], 3)
      source.load(0_u64).rows.should eq([["NULL"], ["0.0.0.0"], ["1.2.3.4"]])
      table["address"].values.should eq(nullable_values)
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
