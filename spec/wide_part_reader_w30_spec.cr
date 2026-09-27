require "./spec_helper"

W30_ARRAY_NUMERIC_FIXTURE = File.expand_path("../test/fixtures/public/wide_array_numeric/part", __DIR__)
W30_ARRAY_NUMERIC_COLUMNS = {
  {"arr_u8", "UInt8"},
  {"arr_u16", "UInt16"},
  {"arr_u32", "UInt32"},
  {"arr_u64", "UInt64"},
  {"arr_i8", "Int8"},
  {"arr_i16", "Int16"},
  {"arr_i32", "Int32"},
  {"arr_i64", "Int64"},
  {"arr_f32", "Float32"},
  {"arr_f64", "Float64"},
}

private def w30_expected_array_values(type : T.class) : Array(Array(T)) forall T
  {% if T == UInt8 %}
    [
      [] of UInt8,
      [0_u8, UInt8::MAX],
      [] of UInt8,
      [1_u8, 128_u8],
      [0_u8, 1_u8],
      [UInt8::MAX],
      [] of UInt8,
    ] of Array(UInt8)
  {% elsif T == UInt16 %}
    [
      [] of UInt16,
      [0_u16, UInt16::MAX],
      [] of UInt16,
      [1_u16, 32_768_u16],
      [0_u16, 1_u16],
      [UInt16::MAX],
      [] of UInt16,
    ] of Array(UInt16)
  {% elsif T == UInt32 %}
    [
      [] of UInt32,
      [0_u32, UInt32::MAX],
      [] of UInt32,
      [1_u32, 0x8000_0000_u32],
      [0_u32, 1_u32],
      [UInt32::MAX],
      [] of UInt32,
    ] of Array(UInt32)
  {% elsif T == UInt64 %}
    [
      [] of UInt64,
      [0_u64, UInt64::MAX],
      [] of UInt64,
      [1_u64, 0x8000_0000_0000_0000_u64],
      [0_u64, 1_u64],
      [UInt64::MAX],
      [] of UInt64,
    ] of Array(UInt64)
  {% elsif T == Int8 %}
    [
      [] of Int8,
      [0_i8, Int8::MAX],
      [] of Int8,
      [Int8::MIN, -1_i8],
      [0_i8, 1_i8],
      [Int8::MAX],
      [] of Int8,
    ] of Array(Int8)
  {% elsif T == Int16 %}
    [
      [] of Int16,
      [0_i16, Int16::MAX],
      [] of Int16,
      [Int16::MIN, -1_i16],
      [0_i16, 1_i16],
      [Int16::MAX],
      [] of Int16,
    ] of Array(Int16)
  {% elsif T == Int32 %}
    [
      [] of Int32,
      [0_i32, Int32::MAX],
      [] of Int32,
      [Int32::MIN, -1_i32],
      [0_i32, 1_i32],
      [Int32::MAX],
      [] of Int32,
    ] of Array(Int32)
  {% elsif T == Int64 %}
    [
      [] of Int64,
      [0_i64, Int64::MAX],
      [] of Int64,
      [Int64::MIN, -1_i64],
      [0_i64, 1_i64],
      [Int64::MAX],
      [] of Int64,
    ] of Array(Int64)
  {% elsif T == Float32 %}
    [
      [] of Float32,
      [0x8000_0000_u32.unsafe_as(Float32), 0x0000_0000_u32.unsafe_as(Float32), 0x7fc1_2345_u32.unsafe_as(Float32), 0x7f7f_ffff_u32.unsafe_as(Float32), 0x7f80_0000_u32.unsafe_as(Float32)],
      [] of Float32,
      [0xff7f_ffff_u32.unsafe_as(Float32), 0xff80_0000_u32.unsafe_as(Float32)],
      [0x3fc0_0000_u32.unsafe_as(Float32), 0xc010_0000_u32.unsafe_as(Float32)],
      [0x0000_0001_u32.unsafe_as(Float32), 0x8000_0001_u32.unsafe_as(Float32)],
      [] of Float32,
    ] of Array(Float32)
  {% elsif T == Float64 %}
    [
      [] of Float64,
      [0x8000_0000_0000_0000_u64.unsafe_as(Float64), 0x0000_0000_0000_0000_u64.unsafe_as(Float64), 0x7ff8_0000_0000_1234_u64.unsafe_as(Float64), 0x7fef_ffff_ffff_ffff_u64.unsafe_as(Float64), 0x7ff0_0000_0000_0000_u64.unsafe_as(Float64)],
      [] of Float64,
      [0xffef_ffff_ffff_ffff_u64.unsafe_as(Float64), 0xfff0_0000_0000_0000_u64.unsafe_as(Float64)],
      [0x3ff8_0000_0000_0000_u64.unsafe_as(Float64), 0xc002_0000_0000_0000_u64.unsafe_as(Float64)],
      [0x0000_0000_0000_0001_u64.unsafe_as(Float64), 0x8000_0000_0000_0001_u64.unsafe_as(Float64)],
      [] of Float64,
    ] of Array(Float64)
  {% else %}
    raise "unsupported W30 test type"
  {% end %}
end

private def w30_numeric_bits(value : T) : UInt64 forall T
  {% if T == UInt8 || T == UInt16 || T == UInt32 %}
    value.to_u64
  {% elsif T == UInt64 %}
    value
  {% elsif T == Int8 %}
    value.unsafe_as(UInt8).to_u64
  {% elsif T == Int16 %}
    value.unsafe_as(UInt16).to_u64
  {% elsif T == Int32 %}
    value.unsafe_as(UInt32).to_u64
  {% elsif T == Int64 %}
    value.unsafe_as(UInt64)
  {% elsif T == Float32 %}
    value.unsafe_as(UInt32).to_u64
  {% elsif T == Float64 %}
    value.unsafe_as(UInt64)
  {% else %}
    raise "unsupported W30 test type"
  {% end %}
end

private def w30_numeric_width(type : T.class) : Int32 forall T
  {% if T == UInt8 || T == Int8 %}
    1
  {% elsif T == UInt16 || T == Int16 %}
    2
  {% elsif T == UInt32 || T == Int32 || T == Float32 %}
    4
  {% else %}
    8
  {% end %}
end

private def w30_append_little_endian(bytes : Array(UInt8), value : UInt64, width : Int32) : Nil
  width.times { |index| bytes << ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w30_nested_bits(values : Array(Array(T))) : Array(Array(UInt64)) forall T
  values.map { |row| row.map { |value| w30_numeric_bits(value) } }
end

private def w30_assert_nested_equal(actual : Array(Array(T)), expected : Array(Array(T))) : Nil forall T
  w30_nested_bits(actual).should eq(w30_nested_bits(expected))
end

private def w30_payload_bytes(values : Array(Array(T)), type : T.class) : Array(UInt8) forall T
  bytes = [] of UInt8
  width = w30_numeric_width(type)
  values.each do |row|
    row.each { |value| w30_append_little_endian(bytes, w30_numeric_bits(value), width) }
  end
  bytes
end

private def w30_array_size_bytes(values : Array(Array(T))) : Array(UInt8) forall T
  bytes = [] of UInt8
  values.each do |row|
    w30_append_little_endian(bytes, row.size.to_u64, 8)
  end
  bytes
end

private def w30_decode_stream(part_path : String, stream : String) : Array(UInt8)
  data_path = File.join(part_path, "#{CrystalClick::StreamName.hash(stream)}.bin")
  CrystalClick::CompressedBlock.decode_all(File.read(data_path).to_slice).to_a
end

private def w30_mark_rows(part_path : String, stream : String) : Array(UInt64)
  marks_path = File.join(part_path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  raw = File.read(marks_path).to_slice
  raise "invalid W30 mark stream" unless raw.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(UInt64).new(raw.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE + 16
    rows = 0_u64
    8.times { |byte| rows |= raw[offset + byte].to_u64 << (8 * byte) }
    rows
  end
end

private def w30_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (8 * byte)) & 0xff_u64).to_u8 }
end

private def w30_check_reader_and_table(type : T.class, column : String) : Nil forall T
  expected = w30_expected_array_values(type)
  reader = CrystalClick::WidePart.open_typed(W30_ARRAY_NUMERIC_FIXTURE, column)
  reader.column_type.should eq("Array(#{CrystalClick::WidePart.numeric_type_name(type)})")
  reader.row_count.should eq(7_u64)
  reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
  w30_assert_nested_equal(reader.read_array_numeric_mark_range(column, 0, reader.mark_count, type), expected)
  w30_assert_nested_equal(reader.read_array_numeric_mark_range(column, 1, 2, type), expected[2, 4])

  parent = File.tempname("crystal-click-w30-table-#{column}")
  Dir.mkdir(parent)
  part_path = File.join(parent, "all_1_1_0")
  begin
    FileUtils.cp_r(W30_ARRAY_NUMERIC_FIXTURE, part_path)
    table = CrystalClick::WidePartTable.open_selected_typed([part_path], [column])
    observed = [] of Array(T)
    batches = [] of {Int32, UInt64, Int32}
    table.scan_typed(batch_rows: 3) do |batch|
      values = batch.array_numeric_values(column, type)
      observed.concat(values)
      batches << {batch.mark_index, batch.part_row_offset, values.size.to_i32}
    end
    w30_assert_nested_equal(observed, expected)
    batches.should eq([
      {0_i32, 0_u64, 2_i32},
      {1_i32, 2_u64, 2_i32},
      {2_i32, 4_u64, 2_i32},
      {3_i32, 6_u64, 1_i32},
    ])
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def w30_check_writer(type : T.class, column : String) : Nil forall T
  values = w30_expected_array_values(type)
  keys = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64]
  parent = File.tempname("crystal-click-w30-writer-#{column}")
  Dir.mkdir(parent)
  part_path = File.join(parent, "part")
  begin
    CrystalClick::WidePartWriter.write_uint64_array_numeric_pair(
      part_path,
      "pk",
      keys.to_unsafe.to_slice(keys.size),
      "payload",
      values.to_unsafe.to_slice(values.size),
      rows_per_mark: 2
    )
    reader = CrystalClick::WidePart.open_typed(part_path, "payload")
    reader.column_type.should eq("Array(#{CrystalClick::WidePart.numeric_type_name(type)})")
    reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
    w30_assert_nested_equal(reader.read_array_numeric_mark_range("payload", 0, reader.mark_count, type), values)
    w30_assert_nested_equal(reader.read_array_numeric_mark_range("payload", 1, 2, type), values[2, 4])
    w30_decode_stream(part_path, "payload.size0").should eq(w30_array_size_bytes(values))
    w30_decode_stream(part_path, "payload").should eq(w30_payload_bytes(values, type))
    w30_mark_rows(part_path, "payload.size0").should eq([2_u64, 2_u64, 2_u64, 1_u64, 0_u64])
    w30_mark_rows(part_path, "payload").should eq([2_u64, 2_u64, 2_u64, 1_u64, 0_u64])
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def with_w30_catalog_root(&)
  root = File.tempname("crystal-click-w30-offline-catalog")
  Dir.mkdir(root)
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))
  begin
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

private def w30_catalog_table_path(root : String) : String
  database_uuid = "4e0a08e8-29b4-4b2c-92d0-4f9d35635140"
  table_uuid = "7bc773d5-a16f-4e3e-89c2-c9627ee8a671"
  database_path = File.join(root, "store", database_uuid[0, 3], database_uuid)
  table_path = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(database_path)
  FileUtils.mkdir_p(table_path)
  File.write(File.join(root, "metadata", "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  columns = String.build do |io|
    io << "    `pk` UInt64,\n"
    W30_ARRAY_NUMERIC_COLUMNS.each_with_index do |(name, type), index|
      io << "    `" << name << "` Array(" << type << ")"
      io << ",\n" unless index == W30_ARRAY_NUMERIC_COLUMNS.size - 1
      io << "\n" if index == W30_ARRAY_NUMERIC_COLUMNS.size - 1
    end
  end
  File.write(
    File.join(database_path, "events.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n#{columns})\nENGINE = MergeTree\nORDER BY pk\n"
  )
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  FileUtils.cp_r(W30_ARRAY_NUMERIC_FIXTURE, File.join(table_path, "all_1_1_0"))
  table_path
end

private def w30_check_catalog(type : T.class, column : String) : Nil forall T
  expected = w30_expected_array_values(type)
  with_w30_catalog_root do |root|
    w30_catalog_table_path(root)
    table = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]
    values = table[column].values.map { |value| value.as(Array(T)) }
    w30_assert_nested_equal(values, expected)

    {% if T == UInt8 %}
      values[1][0] = 99_u8
      w30_assert_nested_equal(table[column].values.map { |value| value.as(Array(UInt8)) }, expected)
    {% end %}
  end
end

describe CrystalClick::WidePart do
  it "admits only one-level Array of the exact supported numeric leaves" do
    {"UInt8", "UInt16", "UInt32", "UInt64", "Int8", "Int16", "Int32", "Int64", "Float32", "Float64"}.each do |leaf_type|
      CrystalClick::WidePart.supports_typed_type?("Array(#{leaf_type})").should be_true
    end

    [
      "Array(Array(UInt8))",
      "Array(Tuple(UInt64, UInt64))",
      "Array(Decimal(75, 0))",
      "Array(UInt8) trailing",
    ].each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end

    [
      "Array(UInt64)",
      "Array(String)",
      "Array(Array(UInt64))",
      "Array(Array(Nullable(UInt64)))",
    ].each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_true
    end

    {"UInt8", "UInt16", "UInt32", "UInt64", "Int8", "Int16", "Int32", "Int64", "Float32", "Float64"}.each do |leaf_type|
      CrystalClick::WidePart.supports_typed_type?("Array(Nullable(#{leaf_type}))").should be_true
    end
  end

  it "reads stock streams for every numeric array leaf and exposes typed batches" do
    w30_check_reader_and_table(UInt8, "arr_u8")
    w30_check_reader_and_table(UInt16, "arr_u16")
    w30_check_reader_and_table(UInt32, "arr_u32")
    w30_check_reader_and_table(UInt64, "arr_u64")
    w30_check_reader_and_table(Int8, "arr_i8")
    w30_check_reader_and_table(Int16, "arr_i16")
    w30_check_reader_and_table(Int32, "arr_i32")
    w30_check_reader_and_table(Int64, "arr_i64")
    w30_check_reader_and_table(Float32, "arr_f32")
    w30_check_reader_and_table(Float64, "arr_f64")
  end

  it "writes exact size and payload bytes for every numeric array leaf" do
    w30_check_writer(UInt8, "arr_u8")
    w30_check_writer(UInt16, "arr_u16")
    w30_check_writer(UInt32, "arr_u32")
    w30_check_writer(UInt64, "arr_u64")
    w30_check_writer(Int8, "arr_i8")
    w30_check_writer(Int16, "arr_i16")
    w30_check_writer(Int32, "arr_i32")
    w30_check_writer(Int64, "arr_i64")
    w30_check_writer(Float32, "arr_f32")
    w30_check_writer(Float64, "arr_f64")
  end

  it "materializes every numeric array leaf through OfflineCatalog" do
    w30_check_catalog(UInt8, "arr_u8")
    w30_check_catalog(UInt16, "arr_u16")
    w30_check_catalog(UInt32, "arr_u32")
    w30_check_catalog(UInt64, "arr_u64")
    w30_check_catalog(Int8, "arr_i8")
    w30_check_catalog(Int16, "arr_i16")
    w30_check_catalog(Int32, "arr_i32")
    w30_check_catalog(Int64, "arr_i64")
    w30_check_catalog(Float32, "arr_f32")
    w30_check_catalog(Float64, "arr_f64")
  end

  it "rejects a later payload mark offset before publishing a typed batch" do
    parent = File.tempname("crystal-click-w30-array-numeric-corrupt-mark")
    Dir.mkdir(parent)
    part_path = File.join(parent, "all_1_1_0")
    callbacks = 0
    begin
      FileUtils.cp_r(W30_ARRAY_NUMERIC_FIXTURE, part_path)
      marks_path = File.join(part_path, "#{CrystalClick::StreamName.hash("arr_u8")}.mrk2")
      marks = File.read(marks_path).to_slice.dup
      original_rows = w30_mark_rows(part_path, "arr_u8")
      original_rows.should eq([2_u64, 2_u64, 2_u64, 1_u64, 0_u64])

      # Keep all row totals and mark rows intact, but move the second payload mark
      # one UInt8 into its frame. Its byte range can no longer satisfy the two
      # values described by the unchanged size0 rows.
      decompressed_offset = CrystalClick::WidePart::MARK_SIZE + 8
      w30_write_u64(marks, decompressed_offset, 3_u64)
      File.write(marks_path, marks)
      w30_mark_rows(part_path, "arr_u8").should eq(original_rows)

      table = CrystalClick::WidePartTable.open_selected_typed([part_path], ["arr_u8"])
      error = expect_raises(CrystalClick::CorruptPartError) do
        table.scan_typed_candidate_marks([[1_i32]]) do |_batch|
          callbacks += 1
        end
      end
      error.message.to_s.should contain("mark")
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a leaf width mismatch before publishing a typed batch" do
    parent = File.tempname("crystal-click-w30-array-numeric-corrupt-width")
    Dir.mkdir(parent)
    part_path = File.join(parent, "all_1_1_0")
    callbacks = 0
    begin
      FileUtils.cp_r(W30_ARRAY_NUMERIC_FIXTURE, part_path)
      columns_path = File.join(part_path, "columns.txt")
      columns = File.read(columns_path)
      File.write(columns_path, columns.sub("`arr_u8` Array(UInt8)", "`arr_u8` Array(UInt16)"))

      expect_raises(CrystalClick::CorruptPartError) do
        table = CrystalClick::WidePartTable.open_selected_typed([part_path], ["arr_u8"])
        table.scan_typed_candidate_marks([[1_i32]]) do |_batch|
          callbacks += 1
        end
      end
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects oversized numeric arrays before publishing a part" do
    parent = File.tempname("crystal-click-w30-array-numeric-oversized")
    Dir.mkdir(parent)
    part_path = File.join(parent, "part")
    keys = [1_u64]
    values = [Array(UInt8).new(CrystalClick::WidePart::MAX_ARRAY_MARK_ELEMENTS.to_i + 1, 0_u8)]
    begin
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_array_numeric_pair(
          part_path,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "payload",
          values.to_unsafe.to_slice(values.size),
          rows_per_mark: 1
        )
      end
      File.exists?(part_path).should be_false
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
