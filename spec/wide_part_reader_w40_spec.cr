require "./spec_helper"

W40_TEMPORAL_ARRAY_FIXTURE = File.expand_path("../test/fixtures/public/wide_array_temporal/part", __DIR__)
W40_KEYS                   = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64]

W40_DATE_ROWS = [
  [] of UInt16, [0_u16, 1_u16], [UInt16::MAX], [] of UInt16,
  [42_u16, 0_u16], [UInt16::MAX], [] of UInt16,
] of Array(UInt16)
W40_DATE32_ROWS = [
  [] of Int32, [-1_i32, 1_i32], [-25_567_i32], [] of Int32,
  [-25_567_i32, 24_854_i32], [-1_i32], [] of Int32,
] of Array(Int32)
W40_DATE32_WRITER_ROWS = [
  [] of Int32, [-1_i32, 1_i32], [-25_567_i32], [] of Int32,
  [Int32::MIN, Int32::MAX], [-1_i32], [] of Int32,
] of Array(Int32)
W40_DATETIME_ROWS = [
  [] of UInt32, [0_u32, 1_u32], [UInt32::MAX], [] of UInt32,
  [0_u32, UInt32::MAX], [1_u32], [] of UInt32,
] of Array(UInt32)
W40_DATETIME64_ROWS = [
  [] of Int64, [-1_i64, 1_000_i64], [Int64::MAX], [] of Int64,
  [Int64::MIN, Int64::MAX], [-1_i64], [] of Int64,
] of Array(Int64)

W40_NULLABLE_DATE_ROWS = [
  [] of UInt16?, [nil, 0_u16] of UInt16?, [1_u16] of UInt16?, [] of UInt16?,
  [nil, 0_u16] of UInt16?, [0_u16] of UInt16?, [] of UInt16?,
] of Array(UInt16?)
W40_NULLABLE_DATE32_ROWS = [
  [] of Int32?, [nil, -1_i32] of Int32?, [0_i32] of Int32?, [] of Int32?,
  [nil, 0_i32] of Int32?, [-1_i32] of Int32?, [] of Int32?,
] of Array(Int32?)
W40_NULLABLE_DATETIME_ROWS = [
  [] of UInt32?, [nil, 0_u32] of UInt32?, [1_u32] of UInt32?, [] of UInt32?,
  [nil, 0_u32] of UInt32?, [0_u32] of UInt32?, [] of UInt32?,
] of Array(UInt32?)
W40_NULLABLE_DATETIME64_ROWS = [
  [] of Int64?, [nil, -1_i64] of Int64?, [0_i64] of Int64?, [] of Int64?,
  [nil, -1_i64] of Int64?, [Int64::MIN] of Int64?, [] of Int64?,
] of Array(Int64?)

W40_CATALOG_COLUMNS = [
  {"a_date", "Array(Date)"},
  {"a_date32", "Array(Date32)"},
  {"a_datetime", "Array(DateTime)"},
  {"a_datetime64", "Array(DateTime64(3))"},
  {"n_date", "Array(Nullable(Date))"},
  {"n_date32", "Array(Nullable(Date32))"},
  {"n_datetime", "Array(Nullable(DateTime))"},
  {"n_datetime64", "Array(Nullable(DateTime64(3)))"},
]

private def w40_read_array(part : CrystalClick::WidePart, column : String, first_mark : Int, mark_count : Int, expected : Array(Array(T))) : Array(Array(T)) forall T
  {% if T == UInt16 %}
    part.read_array_date_codes_mark_range(column, first_mark, mark_count)
  {% elsif T == Int32 %}
    part.read_array_date32_codes_mark_range(column, first_mark, mark_count)
  {% elsif T == UInt32 %}
    part.read_array_datetime_seconds_mark_range(column, first_mark, mark_count)
  {% elsif T == Int64 %}
    part.read_array_datetime64_ticks_mark_range(column, first_mark, mark_count)
  {% else %}
    {% raise "unsupported W40 non-nullable leaf type" %}
  {% end %}
end

private def w40_read_nullable_array(part : CrystalClick::WidePart, column : String, first_mark : Int, mark_count : Int, expected : Array(Array(T?))) : Array(Array(T?)) forall T
  {% if T == UInt16 %}
    part.read_array_nullable_date_codes_mark_range(column, first_mark, mark_count)
  {% elsif T == Int32 %}
    part.read_array_nullable_date32_codes_mark_range(column, first_mark, mark_count)
  {% elsif T == UInt32 %}
    part.read_array_nullable_datetime_seconds_mark_range(column, first_mark, mark_count)
  {% elsif T == Int64 %}
    part.read_array_nullable_datetime64_ticks_mark_range(column, first_mark, mark_count)
  {% else %}
    {% raise "unsupported W40 nullable leaf type" %}
  {% end %}
end

private def w40_batch_array(batch : CrystalClick::WidePartTableBatch, column : String, type : T.class) : Slice(Array(T)) forall T
  {% if T == UInt16 %}
    batch.array_date_codes_for(column)
  {% elsif T == Int32 %}
    batch.array_date32_codes_for(column)
  {% elsif T == UInt32 %}
    batch.array_datetime_seconds_for(column)
  {% elsif T == Int64 %}
    batch.array_datetime64_ticks_for(column)
  {% else %}
    {% raise "unsupported W40 non-nullable batch leaf type" %}
  {% end %}
end

private def w40_batch_nullable_array(batch : CrystalClick::WidePartTableBatch, column : String, type : T.class) : Slice(Array(T?)) forall T
  {% if T == UInt16 %}
    batch.array_nullable_date_codes_for(column)
  {% elsif T == Int32 %}
    batch.array_nullable_date32_codes_for(column)
  {% elsif T == UInt32 %}
    batch.array_nullable_datetime_seconds_for(column)
  {% elsif T == Int64 %}
    batch.array_nullable_datetime64_ticks_for(column)
  {% else %}
    {% raise "unsupported W40 nullable batch leaf type" %}
  {% end %}
end

private def w40_write_array(destination : String, keys : Array(UInt64), values : Array(Array(T)), scale : Int32, rows_per_mark : Int32) : String forall T
  key_slice = keys.to_unsafe.to_slice(keys.size)
  value_slice = values.to_unsafe.to_slice(values.size)
  {% if T == UInt16 %}
    CrystalClick::WidePartWriter.write_uint64_array_date_pair(destination, "pk", key_slice, "payload", value_slice, rows_per_mark: rows_per_mark)
  {% elsif T == Int32 %}
    CrystalClick::WidePartWriter.write_uint64_array_date32_pair(destination, "pk", key_slice, "payload", value_slice, rows_per_mark: rows_per_mark)
  {% elsif T == UInt32 %}
    CrystalClick::WidePartWriter.write_uint64_array_datetime_pair(destination, "pk", key_slice, "payload", value_slice, rows_per_mark: rows_per_mark)
  {% elsif T == Int64 %}
    CrystalClick::WidePartWriter.write_uint64_array_datetime64_pair(destination, "pk", key_slice, "payload", value_slice, scale, rows_per_mark: rows_per_mark)
  {% else %}
    {% raise "unsupported W40 non-nullable writer leaf type" %}
  {% end %}
end

private def w40_write_nullable_array(destination : String, keys : Array(UInt64), values : Array(Array(T?)), scale : Int32, rows_per_mark : Int32) : String forall T
  key_slice = keys.to_unsafe.to_slice(keys.size)
  value_slice = values.to_unsafe.to_slice(values.size)
  {% if T == UInt16 %}
    CrystalClick::WidePartWriter.write_uint64_array_nullable_date_pair(destination, "pk", key_slice, "payload", value_slice, rows_per_mark: rows_per_mark)
  {% elsif T == Int32 %}
    CrystalClick::WidePartWriter.write_uint64_array_nullable_date32_pair(destination, "pk", key_slice, "payload", value_slice, rows_per_mark: rows_per_mark)
  {% elsif T == UInt32 %}
    CrystalClick::WidePartWriter.write_uint64_array_nullable_datetime_pair(destination, "pk", key_slice, "payload", value_slice, rows_per_mark: rows_per_mark)
  {% elsif T == Int64 %}
    CrystalClick::WidePartWriter.write_uint64_array_nullable_datetime64_pair(destination, "pk", key_slice, "payload", value_slice, scale, rows_per_mark: rows_per_mark)
  {% else %}
    {% raise "unsupported W40 nullable writer leaf type" %}
  {% end %}
end

private def w40_check_batch_declaration(part : String, column : String, declaration : String) : Nil
  root = File.tempname("crystal-click-w40-batch-type")
  Dir.mkdir(root)
  valid_part = File.join(root, "all_1_1_0")
  begin
    FileUtils.cp_r(part, valid_part)
    table = CrystalClick::WidePartTable.open_selected_typed([valid_part], ["pk", column])
    checked_missing_name = false
    table.scan_typed(batch_rows: 2) do |batch|
      batch.column_type_for(column).should eq(declaration)
      unless checked_missing_name
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.column_type_for("not_selected") }
        checked_missing_name = true
      end
    end
    checked_missing_name.should be_true
  ensure
    FileUtils.rm_rf(root)
  end
end

private def w40_check_typed_batches(column : String, declaration : String, rows : Array(Array(T))) : Nil forall T
  parent = File.tempname("crystal-click-w40-array-batch-#{column}")
  Dir.mkdir(parent)
  part = File.join(parent, "all_1_1_0")
  begin
    FileUtils.cp_r(W40_TEMPORAL_ARRAY_FIXTURE, part)
    table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", column])
    observed_keys = [] of UInt64
    observed_values = [] of Array(T)
    batch_shapes = [] of {Int32, UInt64, Int32}
    checked_missing_name = false
    table.scan_typed(batch_rows: 3) do |batch|
      keys = batch.values_for("pk", UInt64)
      values = w40_batch_array(batch, column, T)
      batch.column_type_for(column).should eq(declaration)
      unless checked_missing_name
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.column_type_for("not_selected") }
        checked_missing_name = true
      end
      observed_keys.concat(keys)
      observed_values.concat(values)
      batch_shapes << {batch.mark_index, batch.part_row_offset, values.size.to_i32}
    end

    observed_keys.should eq(W40_KEYS)
    observed_values.should eq(rows)
    checked_missing_name.should be_true
    batch_shapes.should eq([
      {0_i32, 0_u64, 2_i32},
      {1_i32, 2_u64, 2_i32},
      {2_i32, 4_u64, 2_i32},
      {3_i32, 6_u64, 1_i32},
    ])

    later_values = [] of Array(T)
    table.scan_typed_window(4_u64, max_rows: 3) do |batch|
      later_values.concat(w40_batch_array(batch, column, T))
    end
    later_values.should eq(rows[4, 3])
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def w40_check_reader(column : String, type_name : String, rows : Array(Array(T))) : Nil forall T
  reader = CrystalClick::WidePart.open_typed(W40_TEMPORAL_ARRAY_FIXTURE, column)
  reader.column_type.should eq("Array(#{type_name})")
  reader.row_count.should eq(7_u64)
  reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
  w40_read_array(reader, column, 0, reader.mark_count, rows).should eq(rows)
  w40_read_array(reader, column, 1, 2, rows).should eq(rows[2, 4])
end

private def w40_check_nullable_reader(column : String, type_name : String, rows : Array(Array(T?))) : Nil forall T
  reader = CrystalClick::WidePart.open_typed(W40_TEMPORAL_ARRAY_FIXTURE, column)
  reader.column_type.should eq("Array(Nullable(#{type_name}))")
  reader.row_count.should eq(7_u64)
  reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
  w40_read_nullable_array(reader, column, 0, reader.mark_count, rows).should eq(rows)
  w40_read_nullable_array(reader, column, 1, 2, rows).should eq(rows[2, 4])
end

private def w40_check_nullable_typed_batches(column : String, declaration : String, rows : Array(Array(T?))) : Nil forall T
  parent = File.tempname("crystal-click-w40-null-array-batch-#{column}")
  Dir.mkdir(parent)
  part = File.join(parent, "all_1_1_0")
  begin
    FileUtils.cp_r(W40_TEMPORAL_ARRAY_FIXTURE, part)
    table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", column])
    observed_keys = [] of UInt64
    observed_values = [] of Array(T?)
    checked_missing_name = false
    table.scan_typed(batch_rows: 3) do |batch|
      batch.column_type_for(column).should eq(declaration)
      unless checked_missing_name
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.column_type_for("not_selected") }
        checked_missing_name = true
      end
      observed_keys.concat(batch.values_for("pk", UInt64))
      observed_values.concat(w40_batch_nullable_array(batch, column, T))
    end
    observed_keys.should eq(W40_KEYS)
    observed_values.should eq(rows)
    checked_missing_name.should be_true

    later_values = [] of Array(T?)
    table.scan_typed_window(4_u64, max_rows: 3) do |batch|
      later_values.concat(w40_batch_nullable_array(batch, column, T))
    end
    later_values.should eq(rows[4, 3])
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def w40_check_plain_writer(type_name : String, rows : Array(Array(T)), scale : Int32 = 3) : Nil forall T
  parent = File.tempname("crystal-click-w40-array-writer-#{type_name}-#{scale}")
  Dir.mkdir(parent)
  part = File.join(parent, "part")
  begin
    w40_write_array(part, W40_KEYS, rows, scale, 2)
    reader = CrystalClick::WidePart.open_typed(part, "payload")
    expected_type = type_name == "DateTime64" ? "Array(DateTime64(#{scale}))" : "Array(#{type_name})"
    reader.column_type.should eq(expected_type)
    reader.row_count.should eq(7_u64)
    reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
    w40_read_array(reader, "payload", 0, reader.mark_count, rows).should eq(rows)
    w40_read_array(reader, "payload", 1, 2, rows).should eq(rows[2, 4])
    w40_check_batch_declaration(part, "payload", expected_type)
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def w40_check_nullable_writer(type_name : String, rows : Array(Array(T?)), scale : Int32 = 3) : Nil forall T
  parent = File.tempname("crystal-click-w40-null-array-writer-#{type_name}-#{scale}")
  Dir.mkdir(parent)
  part = File.join(parent, "part")
  begin
    w40_write_nullable_array(part, W40_KEYS, rows, scale, 2)
    reader = CrystalClick::WidePart.open_typed(part, "payload")
    inner_type = type_name == "DateTime64" ? "DateTime64(#{scale})" : type_name
    reader.column_type.should eq("Array(Nullable(#{inner_type}))")
    reader.row_count.should eq(7_u64)
    reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
    w40_read_nullable_array(reader, "payload", 0, reader.mark_count, rows).should eq(rows)
    w40_read_nullable_array(reader, "payload", 1, 2, rows).should eq(rows[2, 4])
    w40_check_batch_declaration(part, "payload", reader.column_type)
  ensure
    FileUtils.rm_rf(parent)
  end
end

W40_DATABASE_UUID = "e7c0807e-f31f-40bc-bcac-e2ffb942a99a"
W40_TABLE_UUID    = "2632e77f-e688-4ccb-9dd9-57c986074dbc"

private def w40_catalog_store_path(root : String, uuid : String) : String
  File.join(root, "store", uuid[0, 3], uuid)
end

private def with_w40_catalog_root(& : String ->)
  root = File.tempname("crystal-click-w40-offline-catalog")
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))
  begin
    File.write(
      File.join(root, "metadata", "lab.sql"),
      "ATTACH DATABASE _ UUID '#{W40_DATABASE_UUID}'\nENGINE = Atomic\n"
    )

    database_path = w40_catalog_store_path(root, W40_DATABASE_UUID)
    table_path = w40_catalog_store_path(root, W40_TABLE_UUID)
    FileUtils.mkdir_p(database_path)
    FileUtils.mkdir_p(table_path)
    columns = String.build do |io|
      io << "    `pk` UInt64,\n"
      W40_CATALOG_COLUMNS.each_with_index do |(name, type), index|
        io << "    `" << name << "` " << type
        io << ",\n" unless index == W40_CATALOG_COLUMNS.size - 1
        io << "\n" if index == W40_CATALOG_COLUMNS.size - 1
      end
    end
    File.write(
      File.join(database_path, "events.sql"),
      "ATTACH TABLE _ UUID '#{W40_TABLE_UUID}'\n(\n#{columns})\nENGINE = MergeTree\nORDER BY pk\n"
    )
    File.write(File.join(table_path, "format_version.txt"), "1\n")
    Dir.mkdir(File.join(table_path, "detached"))
    FileUtils.cp_r(W40_TEMPORAL_ARRAY_FIXTURE, File.join(table_path, "all_1_1_0"))
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

describe CrystalClick::WidePart do
  it "admits the canonical semantic Array leaves and rejects aliases, wrappers, and nesting" do
    {
      "Array(Date)", "Array(Date32)", "Array(DateTime)", "Array(DateTime64(3))",
      "Array(Nullable(Date))", "Array(Nullable(Date32))",
      "Array(Nullable(DateTime))", "Array(Nullable(DateTime64(3)))",
    }.each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_true
    end

    (0_i32..9_i32).each do |scale|
      CrystalClick::WidePart.supports_typed_type?("Array(DateTime64(#{scale}))").should be_true
      CrystalClick::WidePart.supports_typed_type?("Array(Nullable(DateTime64(#{scale})))").should be_true
    end

    {
      "Array(DateTime('UTC'))", "Array(DateTime64(03))", "Array(DateTime64(10))",
      "Array(DateTime64(3, 'UTC'))", "Array(Nullable(DateTime64(03)))",
      "Array(Nullable(DateTime64(3, 'UTC')))",
      "Array(Nullable(Nullable(Date)))", "Nullable(Array(Date))", "Array(Date )",
    }.each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end
  end

  it "reads all eight stock temporal Array declarations, raw values, later marks, and NULL distinct from zero" do
    w40_check_reader("a_date", "Date", W40_DATE_ROWS)
    w40_check_reader("a_date32", "Date32", W40_DATE32_ROWS)
    w40_check_reader("a_datetime", "DateTime", W40_DATETIME_ROWS)
    w40_check_reader("a_datetime64", "DateTime64(3)", W40_DATETIME64_ROWS)
    w40_check_nullable_reader("n_date", "Date", W40_NULLABLE_DATE_ROWS)
    w40_check_nullable_reader("n_date32", "Date32", W40_NULLABLE_DATE32_ROWS)
    w40_check_nullable_reader("n_datetime", "DateTime", W40_NULLABLE_DATETIME_ROWS)
    w40_check_nullable_reader("n_datetime64", "DateTime64(3)", W40_NULLABLE_DATETIME64_ROWS)
  end

  it "does not route temporal arrays through same-width numeric accessors or cross semantic types" do
    date = CrystalClick::WidePart.open_typed(W40_TEMPORAL_ARRAY_FIXTURE, "a_date")
    date32 = CrystalClick::WidePart.open_typed(W40_TEMPORAL_ARRAY_FIXTURE, "a_date32")
    datetime = CrystalClick::WidePart.open_typed(W40_TEMPORAL_ARRAY_FIXTURE, "a_datetime")
    datetime64 = CrystalClick::WidePart.open_typed(W40_TEMPORAL_ARRAY_FIXTURE, "a_datetime64")

    expect_raises(CrystalClick::UnsupportedFormatError) do
      date.read_array_numeric_mark_range("a_date", 0, date.mark_count, UInt16)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      date.read_array_date32_codes_mark_range("a_date", 0, 1)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      date32.read_array_date_codes_mark_range("a_date32", 0, 1)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      datetime.read_array_numeric_mark_range("a_datetime", 0, datetime.mark_count, UInt32)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      datetime64.read_array_numeric_mark_range("a_datetime64", 0, datetime64.mark_count, Int64)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      datetime64.read_array_datetime_seconds_mark_range("a_datetime64", 0, 1)
    end

    nullable_date = CrystalClick::WidePart.open_typed(W40_TEMPORAL_ARRAY_FIXTURE, "n_date")
    expect_raises(CrystalClick::UnsupportedFormatError) do
      nullable_date.read_array_date_codes_mark_range("n_date", 0, 1)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      nullable_date.read_array_nullable_numeric_mark_range("n_date", 0, nullable_date.mark_count, UInt16)
    end
  end

  it "rejects truncated temporal child data before returning a reader result or typed batch" do
    parent = File.tempname("crystal-click-w40-corrupt-temporal-array")
    Dir.mkdir(parent)
    part = File.join(parent, "all_1_1_0")
    FileUtils.cp_r(W40_TEMPORAL_ARRAY_FIXTURE, part)
    begin
      payload_file = File.join(part, "#{CrystalClick::StreamName.hash("n_datetime64")}.bin")
      bytes = writable_file_bytes(payload_file)
      File.open(payload_file, "wb") { |io| io.write(bytes[0, bytes.size - 1]) }

      expect_raises(CrystalClick::CorruptPartError) do
        reader = CrystalClick::WidePart.open_typed(part, "n_datetime64")
        reader.read_array_nullable_datetime64_ticks_mark_range("n_datetime64", 0, reader.mark_count)
      end

      published_batches = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "n_datetime64"])
        table.scan_typed do |_batch|
          published_batches += 1
        end
      end
      published_batches.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "does not publish invalid temporal writer inputs and rejects out-of-range DateTime64 scales" do
    parent = File.tempname("crystal-click-w40-temporal-array-preflight")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64]
    begin
      expect_raises(ArgumentError) do
        w40_write_array(File.join(parent, "date"), keys, W40_DATE_ROWS[0, 1], 3, 1)
      end
      Dir.children(parent).should be_empty

      expect_raises(ArgumentError) do
        w40_write_nullable_array(File.join(parent, "nullable-datetime64"), keys, W40_NULLABLE_DATETIME64_ROWS[0, 1], 3, 1)
      end
      Dir.children(parent).should be_empty

      expect_raises(ArgumentError) do
        w40_write_array(File.join(parent, "scale-10"), W40_KEYS, W40_DATETIME64_ROWS, 10, 2)
      end
      Dir.children(parent).should be_empty
      expect_raises(ArgumentError) do
        w40_write_nullable_array(File.join(parent, "scale-minus-one"), W40_KEYS, W40_NULLABLE_DATETIME64_ROWS, -1, 2)
      end
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects ordinary integer Arrays of each matching storage width through temporal readers" do
    w40_reject_numeric_array_as_temporal(UInt16, "Date", [[0_u16]])
    w40_reject_numeric_array_as_temporal(Int32, "Date32", [[-1_i32]])
    w40_reject_numeric_array_as_temporal(UInt32, "DateTime", [[0_u32]])
    w40_reject_numeric_array_as_temporal(Int64, "DateTime64", [[-1_i64]])
  end
end

describe CrystalClick::WidePartTable do
  it "materializes each W40 temporal Array shape in mark batches and later row windows" do
    w40_check_typed_batches("a_date", "Array(Date)", W40_DATE_ROWS)
    w40_check_typed_batches("a_date32", "Array(Date32)", W40_DATE32_ROWS)
    w40_check_typed_batches("a_datetime", "Array(DateTime)", W40_DATETIME_ROWS)
    w40_check_typed_batches("a_datetime64", "Array(DateTime64(3))", W40_DATETIME64_ROWS)
    w40_check_nullable_typed_batches("n_date", "Array(Nullable(Date))", W40_NULLABLE_DATE_ROWS)
    w40_check_nullable_typed_batches("n_date32", "Array(Nullable(Date32))", W40_NULLABLE_DATE32_ROWS)
    w40_check_nullable_typed_batches("n_datetime", "Array(Nullable(DateTime))", W40_NULLABLE_DATETIME_ROWS)
    w40_check_nullable_typed_batches("n_datetime64", "Array(Nullable(DateTime64(3)))", W40_NULLABLE_DATETIME64_ROWS)
  end

  it "rejects numeric and semantic temporal aliases in typed batches" do
    parent = File.tempname("crystal-click-w40-batch-alias")
    Dir.mkdir(parent)
    temporal_part = File.join(parent, "all_1_1_0")
    numeric_root = File.join(parent, "numeric")
    numeric_part = File.join(numeric_root, "all_1_1_0")
    begin
      FileUtils.cp_r(W40_TEMPORAL_ARRAY_FIXTURE, temporal_part)
      temporal_table = CrystalClick::WidePartTable.open_selected_typed([temporal_part], ["pk", "a_date"])
      checked_temporal_batch = false
      temporal_table.scan_typed(batch_rows: 2) do |batch|
        unless checked_temporal_batch
          expect_raises(CrystalClick::UnsupportedFormatError) do
            batch.array_numeric_values("a_date", UInt16)
          end
          checked_temporal_batch = true
        end
      end
      checked_temporal_batch.should be_true

      FileUtils.mkdir_p(numeric_root)
      keys = [1_u64, 2_u64]
      values = [[0_u16], [1_u16, 2_u16]] of Array(UInt16)
      CrystalClick::WidePartWriter.write_uint64_array_numeric_pair(
        numeric_part,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "payload",
        values.to_unsafe.to_slice(values.size),
        rows_per_mark: 1,
      )
      numeric_table = CrystalClick::WidePartTable.open_selected_typed([numeric_part], ["pk", "payload"])
      checked_numeric_batch = false
      numeric_table.scan_typed(batch_rows: 1) do |batch|
        unless checked_numeric_batch
          expect_raises(CrystalClick::UnsupportedFormatError) do
            batch.array_date_codes_for("payload")
          end
          checked_numeric_batch = true
        end
      end
      checked_numeric_batch.should be_true
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end

describe CrystalClick::WidePartWriter do
  it "writes every temporal Array leaf with exact raw codes and exact DateTime64 precision" do
    w40_check_plain_writer("Date", W40_DATE_ROWS)
    w40_check_plain_writer("Date32", W40_DATE32_WRITER_ROWS)
    w40_check_plain_writer("DateTime", W40_DATETIME_ROWS)
    (0_i32..9_i32).each do |scale|
      w40_check_plain_writer("DateTime64", W40_DATETIME64_ROWS, scale)
    end

    w40_check_nullable_writer("Date", W40_NULLABLE_DATE_ROWS)
    w40_check_nullable_writer("Date32", W40_NULLABLE_DATE32_ROWS)
    w40_check_nullable_writer("DateTime", W40_NULLABLE_DATETIME_ROWS)
    (0_i32..9_i32).each do |scale|
      w40_check_nullable_writer("DateTime64", W40_NULLABLE_DATETIME64_ROWS, scale)
    end
  end
end

describe CrystalClick::OfflineCatalog do
  it "materializes all eight temporal Array shapes with exact declarations and caller-owned nested values" do
    with_w40_catalog_root do |root|
      table = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]
      table.columns.map { |column| {column.name, column.type} }.should eq(
        [{"pk", "UInt64"}] + W40_CATALOG_COLUMNS
      )

      table["a_date"].values.map { |value| value.as(Array(UInt16)) }.should eq(W40_DATE_ROWS)
      table["a_date32"].values.map { |value| value.as(Array(Int32)) }.should eq(W40_DATE32_ROWS)
      table["a_datetime"].values.map { |value| value.as(Array(UInt32)) }.should eq(W40_DATETIME_ROWS)
      table["a_datetime64"].values.map { |value| value.as(Array(Int64)) }.should eq(W40_DATETIME64_ROWS)
      table["n_date"].values.map { |value| value.as(Array(UInt16?)) }.should eq(W40_NULLABLE_DATE_ROWS)
      table["n_date32"].values.map { |value| value.as(Array(Int32?)) }.should eq(W40_NULLABLE_DATE32_ROWS)
      table["n_datetime"].values.map { |value| value.as(Array(UInt32?)) }.should eq(W40_NULLABLE_DATETIME_ROWS)
      table["n_datetime64"].values.map { |value| value.as(Array(Int64?)) }.should eq(W40_NULLABLE_DATETIME64_ROWS)

      owned_date = table["a_date"].values.map { |value| value.as(Array(UInt16)) }
      owned_date[1][0] = 7_u16
      owned_date[1] << 8_u16
      table["a_date"].values.map { |value| value.as(Array(UInt16)) }.should eq(W40_DATE_ROWS)

      owned_nullable = table["n_datetime64"].values.map { |value| value.as(Array(Int64?)) }
      owned_nullable[1][0] = 99_i64
      owned_nullable[1] << nil
      table["n_datetime64"].values.map { |value| value.as(Array(Int64?)) }.should eq(W40_NULLABLE_DATETIME64_ROWS)
    end
  end
end

private def w40_reject_numeric_array_as_temporal(type : T.class, type_name : String, rows : Array(Array(T))) : Nil forall T
  parent = File.tempname("crystal-click-w40-numeric-array-alias-#{type_name}")
  Dir.mkdir(parent)
  part_path = File.join(parent, "part")
  keys = [1_u64]
  begin
    CrystalClick::WidePartWriter.write_uint64_array_numeric_pair(
      part_path, "pk", keys.to_unsafe.to_slice(keys.size), "payload", rows.to_unsafe.to_slice(rows.size), rows_per_mark: 1
    )
    reader = CrystalClick::WidePart.open_typed(part_path, "payload")
    reader.column_type.should eq("Array(#{CrystalClick::WidePart.array_numeric_type_name(T)})")
    {% if T == UInt16 %}
      expect_raises(CrystalClick::UnsupportedFormatError) { reader.read_array_date_codes_mark_range("payload", 0, 1) }
    {% elsif T == Int32 %}
      expect_raises(CrystalClick::UnsupportedFormatError) { reader.read_array_date32_codes_mark_range("payload", 0, 1) }
    {% elsif T == UInt32 %}
      expect_raises(CrystalClick::UnsupportedFormatError) { reader.read_array_datetime_seconds_mark_range("payload", 0, 1) }
    {% elsif T == Int64 %}
      expect_raises(CrystalClick::UnsupportedFormatError) { reader.read_array_datetime64_ticks_mark_range("payload", 0, 1) }
    {% end %}
  ensure
    FileUtils.rm_rf(parent)
  end
end
