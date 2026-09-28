require "./spec_helper"

W58_DATABASE_UUID = "c6fb0a8d-5268-4dcf-8f7b-d6819be3d5d1"
W58_TABLE_UUID    = "ff7f84ed-f83f-4610-a38c-1c7023ff0ebf"

private def w58_expected_rows(type : T.class) : Array(Array(Array(T))) forall T
  {% if T == UInt8 %}
    [
      [] of Array(UInt8),
      [[] of UInt8, [0_u8, UInt8::MAX], [] of UInt8],
      [[] of UInt8],
      [[1_u8, 128_u8], [] of UInt8],
      [[UInt8::MAX]],
    ] of Array(Array(UInt8))
  {% elsif T == UInt16 %}
    [
      [] of Array(UInt16),
      [[] of UInt16, [0_u16, UInt16::MAX], [] of UInt16],
      [[] of UInt16],
      [[1_u16, 32_768_u16], [] of UInt16],
      [[UInt16::MAX]],
    ] of Array(Array(UInt16))
  {% elsif T == UInt32 %}
    [
      [] of Array(UInt32),
      [[] of UInt32, [0_u32, UInt32::MAX], [] of UInt32],
      [[] of UInt32],
      [[1_u32, 0x8000_0000_u32], [] of UInt32],
      [[UInt32::MAX]],
    ] of Array(Array(UInt32))
  {% elsif T == UInt64 %}
    [
      [] of Array(UInt64),
      [[] of UInt64, [0_u64, UInt64::MAX], [] of UInt64],
      [[] of UInt64],
      [[1_u64, 0x8000_0000_0000_0000_u64], [] of UInt64],
      [[UInt64::MAX]],
    ] of Array(Array(UInt64))
  {% elsif T == Int8 %}
    [
      [] of Array(Int8),
      [[] of Int8, [Int8::MIN, -1_i8], [] of Int8],
      [[] of Int8],
      [[0_i8, Int8::MAX], [] of Int8],
      [[-42_i8]],
    ] of Array(Array(Int8))
  {% elsif T == Int16 %}
    [
      [] of Array(Int16),
      [[] of Int16, [Int16::MIN, -1_i16], [] of Int16],
      [[] of Int16],
      [[0_i16, Int16::MAX], [] of Int16],
      [[-42_i16]],
    ] of Array(Array(Int16))
  {% elsif T == Int32 %}
    [
      [] of Array(Int32),
      [[] of Int32, [Int32::MIN, -1_i32], [] of Int32],
      [[] of Int32],
      [[0_i32, Int32::MAX], [] of Int32],
      [[-42_i32]],
    ] of Array(Array(Int32))
  {% elsif T == Int64 %}
    [
      [] of Array(Int64),
      [[] of Int64, [Int64::MIN, -1_i64], [] of Int64],
      [[] of Int64],
      [[0_i64, Int64::MAX], [] of Int64],
      [[-42_i64]],
    ] of Array(Array(Int64))
  {% elsif T == Float32 %}
    [
      [] of Array(Float32),
      [[] of Float32, [0x8000_0000_u32.unsafe_as(Float32), 0x0000_0000_u32.unsafe_as(Float32), 0x7fc1_2345_u32.unsafe_as(Float32)], [] of Float32],
      [[] of Float32],
      [[0x0000_0001_u32.unsafe_as(Float32), 0x8000_0001_u32.unsafe_as(Float32)], [] of Float32],
      [[0x7f80_0000_u32.unsafe_as(Float32)]],
    ] of Array(Array(Float32))
  {% elsif T == Float64 %}
    [
      [] of Array(Float64),
      [[] of Float64, [0x8000_0000_0000_0000_u64.unsafe_as(Float64), 0x0000_0000_0000_0000_u64.unsafe_as(Float64), 0x7ff8_0000_0000_1234_u64.unsafe_as(Float64)], [] of Float64],
      [[] of Float64],
      [[0x0000_0000_0000_0001_u64.unsafe_as(Float64), 0x8000_0000_0000_0001_u64.unsafe_as(Float64)], [] of Float64],
      [[0x7ff0_0000_0000_0000_u64.unsafe_as(Float64)]],
    ] of Array(Array(Float64))
  {% else %}
    raise "unsupported W58 test type"
  {% end %}
end

private def w58_numeric_bits(value : T) : UInt64 forall T
  {% if T == UInt8 || T == Int8 %}
    value.unsafe_as(UInt8).to_u64
  {% elsif T == UInt16 || T == Int16 %}
    value.unsafe_as(UInt16).to_u64
  {% elsif T == UInt32 || T == Int32 || T == Float32 %}
    value.unsafe_as(UInt32).to_u64
  {% else %}
    value.unsafe_as(UInt64)
  {% end %}
end

private def w58_nested_bits(rows : Array(Array(Array(T)))) : Array(Array(Array(UInt64))) forall T
  rows.map { |row| row.map { |inner| inner.map { |value| w58_numeric_bits(value) } } }
end

private def w58_assert_rows_equal(actual : Array(Array(Array(T))), expected : Array(Array(Array(T)))) : Nil forall T
  w58_nested_bits(actual).should eq(w58_nested_bits(expected))
end

private def w58_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def w58_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

private def w58_mark_offsets(part : String, stream : String, mark_index : Int) : {UInt64, UInt64}
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  marks = File.read(path).to_slice
  offset = mark_index * CrystalClick::WidePart::MARK_SIZE
  {w58_read_u64(marks, offset), w58_read_u64(marks, offset + 8)}
end

private def w58_store_path(root : String, uuid : String) : String
  File.join(root, "store", uuid[0, 3], uuid)
end

private def w58_check_catalog(part : String, rows : Array(Array(Array(T))), type : T.class) : Nil forall T
  root = File.join(File.dirname(part), "offline-catalog")
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))

  File.write(File.join(root, "metadata", "lab.sql"), "ATTACH DATABASE _ UUID '#{W58_DATABASE_UUID}'\nENGINE = Atomic\n")
  database_path = w58_store_path(root, W58_DATABASE_UUID)
  FileUtils.mkdir_p(database_path)
  type_name = CrystalClick::WidePart.numeric_type_name(type)
  File.write(
    File.join(database_path, "events.sql"),
    "ATTACH TABLE _ UUID '#{W58_TABLE_UUID}'\n" +
    "(\n    `pk` UInt64,\n    `payload` Array(Array(#{type_name}))\n)\n" +
    "ENGINE = MergeTree\nORDER BY pk\n"
  )

  table_path = w58_store_path(root, W58_TABLE_UUID)
  FileUtils.mkdir_p(table_path)
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  FileUtils.cp_r(part, File.join(table_path, File.basename(part)))

  table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")
  table.columns.map { |column| {column.name, column.type} }.should eq([
    {"pk", "UInt64"},
    {"payload", "Array(Array(#{type_name}))"},
  ])

  scanned = [] of Array(Array(T))
  table.scan_typed(["payload"], batch_rows: 1) do |batch|
    scanned.concat(batch.array_array_numeric_values("payload", type))
  end
  w58_assert_rows_equal(scanned, rows)

  materialized = table["payload"].values.map { |value| value.as(Array(Array(T))) }
  w58_assert_rows_equal(materialized, rows)
  owned = materialized[1]
  owned[1] << owned[1][0]
  owned << ([] of T)
  refreshed = table["payload"].values.map { |value| value.as(Array(Array(T))) }
  w58_assert_rows_equal(refreshed, rows)
end

private def w58_check_reader_writer(type : T.class) : Nil forall T
  rows = w58_expected_rows(type)
  keys = [1_u64, 2_u64, 4_u64, 7_u64, 10_u64]
  parent = File.tempname("crystal-click-w58-numeric-array-array")
  Dir.mkdir(parent)
  part = File.join(parent, "all_1_1_0")

  begin
    CrystalClick::WidePartWriter.write_uint64_array_array_numeric_pair(
      part,
      "pk",
      keys.to_unsafe.to_slice(keys.size),
      "payload",
      rows.to_unsafe.to_slice(rows.size),
      rows_per_mark: 2
    )

    reader = CrystalClick::WidePart.open_typed(part, "payload")
    reader.column_type.should eq("Array(Array(#{CrystalClick::WidePart.numeric_type_name(type)}))")
    reader.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
    w58_assert_rows_equal(reader.read_array_array_numeric_mark_range("payload", 0, reader.mark_count, type), rows)
    w58_assert_rows_equal(reader.read_array_array_numeric_mark_range("payload", 1, 1, type), rows[2, 2])
    w58_assert_rows_equal(reader.read_array_array_numeric_mark_range("payload", 2, 1, type), rows[4, 1])

    table = CrystalClick::WidePartTable.open_selected_typed([part], ["payload"])
    observed = [] of Array(Array(T))
    offsets = [] of {Int32, UInt64, Int32}
    table.scan_typed(batch_rows: 1) do |batch|
      values = batch.array_array_numeric_values("payload", type)
      observed.concat(values)
      offsets << {batch.mark_index, batch.part_row_offset, values.size.to_i32}
    end
    w58_assert_rows_equal(observed, rows)
    offsets.should eq([
      {0_i32, 0_u64, 1_i32},
      {0_i32, 1_u64, 1_i32},
      {1_i32, 2_u64, 1_i32},
      {1_i32, 3_u64, 1_i32},
      {2_i32, 4_u64, 1_i32},
    ])

    w58_check_catalog(part, rows, type)
  ensure
    FileUtils.rm_rf(parent)
  end
end

describe CrystalClick::WidePart do
  it "admits exactly two-level Arrays for the ten primitive numeric leaves" do
    {
      "UInt8", "UInt16", "UInt32", "UInt64",
      "Int8", "Int16", "Int32", "Int64",
      "Float32", "Float64",
    }.each do |leaf_type|
      CrystalClick::WidePart.supports_typed_type?("Array(Array(#{leaf_type}))").should be_true
    end

    {
      "Array(Array(Bool))",
      "Array(Array(Nullable(Bool)))",
      "Array(Array(Nullable(FixedString(4))))",
      "Array(Array(Array(Int32)))",
      "Array(Array(Int32)) trailing",
    }.each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end

    # The W28 and W29 exact shapes remain admitted controls.
    CrystalClick::WidePart.supports_typed_type?("Array(Array(UInt64))").should be_true
    CrystalClick::WidePart.supports_typed_type?("Array(Array(Nullable(UInt64)))").should be_true
  end

  it "reads, writes, batches, and materializes every numeric leaf across multiple marks and a short tail" do
    w58_check_reader_writer(UInt8)
    w58_check_reader_writer(UInt16)
    w58_check_reader_writer(UInt32)
    w58_check_reader_writer(UInt64)
    w58_check_reader_writer(Int8)
    w58_check_reader_writer(Int16)
    w58_check_reader_writer(Int32)
    w58_check_reader_writer(Int64)
    w58_check_reader_writer(Float32)
    w58_check_reader_writer(Float64)
  end

  it "preserves a zero-byte middle child mark before a later nonempty mark" do
    rows = [
      [[11_i32, 12_i32]],
      [] of Array(Int32),
      [] of Array(Int32),
      [] of Array(Int32),
      [[33_i32], [] of Int32],
      [[] of Int32],
    ] of Array(Array(Int32))
    keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64]
    parent = File.tempname("crystal-click-w58-zero-middle-child-mark")
    Dir.mkdir(parent)
    part = File.join(parent, "all_1_1_0")

    begin
      CrystalClick::WidePartWriter.write_uint64_array_array_numeric_pair(
        part,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "payload",
        rows.to_unsafe.to_slice(rows.size),
        rows_per_mark: 2
      )

      reader = CrystalClick::WidePart.open_typed(part, "payload")
      reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64])
      w58_mark_offsets(part, "payload.size1", 1).should eq(w58_mark_offsets(part, "payload.size1", 2))
      w58_mark_offsets(part, "payload", 1).should eq(w58_mark_offsets(part, "payload", 2))
      w58_assert_rows_equal(reader.read_array_array_numeric_mark_range("payload", 0, reader.mark_count, Int32), rows)
      w58_assert_rows_equal(reader.read_array_array_numeric_mark_range("payload", 2, 1, Int32), rows[4, 2])

      table = CrystalClick::WidePartTable.open_selected_typed([part], ["payload"])
      observed = [] of Array(Array(Int32))
      table.scan_typed(batch_rows: 1) do |batch|
        observed.concat(batch.array_array_numeric_values("payload", Int32))
      end
      w58_assert_rows_equal(observed, rows)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "reads and scans a part with entirely empty size1 and leaf streams" do
    rows = Array(Array(Array(Int32))).new(5) { [] of Array(Int32) }
    keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
    parent = File.tempname("crystal-click-w58-entirely-empty-child-streams")
    Dir.mkdir(parent)
    part = File.join(parent, "all_1_1_0")

    begin
      CrystalClick::WidePartWriter.write_uint64_array_array_numeric_pair(
        part,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "payload",
        rows.to_unsafe.to_slice(rows.size),
        rows_per_mark: 2
      )

      {"payload.size1", "payload"}.each do |stream|
        path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")
        File.size(path).should eq(0_i64)
      end
      File.size(File.join(part, "#{CrystalClick::StreamName.hash("payload.size0")}.bin")).should be > 0

      reader = CrystalClick::WidePart.open_typed(part, "payload")
      reader.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
      w58_assert_rows_equal(reader.read_array_array_numeric_mark_range("payload", 0, reader.mark_count, Int32), rows)
      w58_assert_rows_equal(reader.read_array_array_numeric_mark_range("payload", 2, 1, Int32), rows[4, 1])

      table = CrystalClick::WidePartTable.open_selected_typed([part], ["payload"])
      observed = [] of Array(Array(Int32))
      table.scan_typed(batch_rows: 1) do |batch|
        observed.concat(batch.array_array_numeric_values("payload", Int32))
      end
      w58_assert_rows_equal(observed, rows)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a later size1 or leaf mark offset before yielding the affected candidate batch" do
    rows = w58_expected_rows(Int32)
    keys = [1_u64, 2_u64, 4_u64, 7_u64, 10_u64]
    parent = File.tempname("crystal-click-w58-corrupt-later-leaf-mark")
    Dir.mkdir(parent)

    begin
      { {"payload.size1", 8_u64}, {"payload", 4_u64} }.each_with_index do |probe, index|
        stream, delta = probe
        part = File.join(parent, "all_#{index + 1}_#{index + 1}_0")
        CrystalClick::WidePartWriter.write_uint64_array_array_numeric_pair(
          part,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "payload",
          rows.to_unsafe.to_slice(rows.size),
          rows_per_mark: 2
        )

        marks_path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
        marks = File.read(marks_path).to_slice.dup
        mark_offset = CrystalClick::WidePart::MARK_SIZE + 8
        original_offset = w58_read_u64(marks, mark_offset)
        w58_write_u64(marks, mark_offset, original_offset + delta)
        File.write(marks_path, marks)

        callbacks = 0
        table = CrystalClick::WidePartTable.open_selected_typed([part], ["payload"])
        error = expect_raises(CrystalClick::CorruptPartError) do
          table.scan_typed_candidate_marks([[1_i32]]) do |_batch|
            callbacks += 1
          end
        end
        error.message.to_s.should contain("mark")
        callbacks.should eq(0)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects an intermediate size0 mark boundary corrupt across a direct full-range read" do
    rows = w58_expected_rows(Int32)
    keys = [1_u64, 2_u64, 4_u64, 7_u64, 10_u64]
    parent = File.tempname("crystal-click-w58-corrupt-size0-intermediate-mark")
    Dir.mkdir(parent)
    part = File.join(parent, "all_1_1_0")

    begin
      CrystalClick::WidePartWriter.write_uint64_array_array_numeric_pair(
        part,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "payload",
        rows.to_unsafe.to_slice(rows.size),
        rows_per_mark: 2
      )

      marks_path = File.join(part, "#{CrystalClick::StreamName.hash("payload.size0")}.mrk2")
      marks = File.read(marks_path).to_slice.dup
      mark_offset = CrystalClick::WidePart::MARK_SIZE + 8
      original_offset = w58_read_u64(marks, mark_offset)
      w58_write_u64(marks, mark_offset, original_offset + 8_u64)
      File.write(marks_path, marks)

      reader = CrystalClick::WidePart.open_typed(part, "payload")
      error = expect_raises(CrystalClick::CorruptPartError) do
        reader.read_array_array_numeric_mark_range("payload", 0, reader.mark_count, Int32)
      end
      error.message.to_s.should contain("mark")
      raw_error = expect_raises(CrystalClick::CorruptPartError) do
        reader.array_array_numeric_mark_range_raw_bytes("payload", 0, reader.mark_count)
      end
      raw_error.message.to_s.should contain("mark")
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
