require "./spec_helper"

W51_ARRAY_TUPLE_FIXTURE  = File.expand_path("../test/fixtures/public/wide_array_tuple_w51/part", __DIR__)
W51_KEYS                 = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64]
W51_LONG_STRING          = "a longer string crosses the row and mark boundary"
W51_NULLABLE_LONG_STRING = "nullable long string crosses the row and mark boundary"
W51_BINARY_STRING        = String.new(Bytes[0x41_u8, 0_u8, 0x42_u8, 0xff_u8])

W51_ARRAY_TUPLE_VALUES = [
  [] of Tuple(UInt64, String),
  [{0_u64, ""}, {UInt64::MAX, "small"}] of Tuple(UInt64, String),
  [{42_u64, W51_BINARY_STRING}, {3_u64, "second"}] of Tuple(UInt64, String),
  [] of Tuple(UInt64, String),
  [{7_u64, W51_LONG_STRING}] of Tuple(UInt64, String),
  [{2_u64, "tail"}, {3_u64, "last"}] of Tuple(UInt64, String),
  [] of Tuple(UInt64, String),
] of Array(Tuple(UInt64, String))
W51_EMPTY_STRING_MARK_VALUES = [
  [{1_u64, "before"}] of Tuple(UInt64, String),
  [{2_u64, "before-last"}] of Tuple(UInt64, String),
  [{3_u64, ""}, {4_u64, ""}] of Tuple(UInt64, String),
  [{5_u64, ""}] of Tuple(UInt64, String),
  [{6_u64, "after"}] of Tuple(UInt64, String),
  [{7_u64, "after-last"}] of Tuple(UInt64, String),
  [{8_u64, "tail"}] of Tuple(UInt64, String),
] of Array(Tuple(UInt64, String))

W51_ARRAY_TUPLE_NULLABLE_VALUES = [
  [] of Tuple(UInt64?, String),
  [{nil.as(UInt64?), ""}, {0_u64.as(UInt64?), "zero"}] of Tuple(UInt64?, String),
  [{nil.as(UInt64?), "all null one"}, {nil.as(UInt64?), "all null two"}] of Tuple(UInt64?, String),
  [] of Tuple(UInt64?, String),
  [{9_u64.as(UInt64?), W51_NULLABLE_LONG_STRING}] of Tuple(UInt64?, String),
  [{8_u64.as(UInt64?), "nullable"}, {nil.as(UInt64?), "end"}] of Tuple(UInt64?, String),
  [] of Tuple(UInt64?, String),
] of Array(Tuple(UInt64?, String))

private def w51_copy_fixture : String
  parent = File.tempname("crystal-click-w51-array-tuple-part")
  Dir.mkdir(parent)
  part = File.join(parent, "all_1_1_0")
  FileUtils.cp_r(W51_ARRAY_TUPLE_FIXTURE, part)
  part
end

private def w51_remove_fixture(part : String) : Nil
  parent = File.dirname(part)
  unless File.basename(part) == "all_1_1_0" && File.basename(parent).includes?("crystal-click-w51-array-tuple-part")
    raise "refusing to remove a path that is not a W51 temporary fixture"
  end
  FileUtils.rm_rf(parent)
end

private def w51_with_offline_catalog_root(& : String ->)
  root = File.tempname("crystal-click-w51-array-tuple-catalog")
  Dir.mkdir(root)
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))

  database_uuid = "54a281d1-0d32-4b0d-9784-3a7188c7f0ab"
  table_uuid = "aae7288e-3502-47cd-a085-220d58dcf660"
  database_store = File.join(root, "store", database_uuid[0, 3], database_uuid)
  table_store = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(database_store)
  File.write(File.join(root, "metadata", "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  File.write(
    File.join(database_store, "events.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `pk` UInt64,\n    `arr_tuple` Array(Tuple(a UInt64, b String)),\n    `arr_tuple_nullable` Array(Tuple(a Nullable(UInt64), b String))\n)\nENGINE = MergeTree\nORDER BY pk\n"
  )
  FileUtils.mkdir_p(table_store)
  File.write(File.join(table_store, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_store, "detached"))
  FileUtils.cp_r(W51_ARRAY_TUPLE_FIXTURE, File.join(table_store, "all_1_1_0"))

  yield root
ensure
  FileUtils.rm_rf(root) if root && Dir.exists?(root)
end

private def w51_tuple_string_raw_bytes(values : Array(Array(Tuple(UInt64, String)))) : UInt64
  bytes = values.size.to_u64 * 8_u64
  values.each do |row|
    bytes += row.size.to_u64 * 16_u64
    row.each { |entry| bytes += entry[1].bytesize.to_u64 }
  end
  bytes
end

private def w51_nullable_tuple_string_raw_bytes(values : Array(Array(Tuple(UInt64?, String)))) : UInt64
  bytes = values.size.to_u64 * 8_u64
  values.each do |row|
    bytes += row.size.to_u64 * 17_u64
    row.each { |entry| bytes += entry[1].bytesize.to_u64 }
  end
  bytes
end

private def w51_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def w51_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

private def w51_assert_mark_entry_size_checked(path : String, stream : String) : Nil
  name = "#{CrystalClick::StreamName.hash(stream)}.mrk2"
  checksums = CrystalClick::PartChecksums.open(path)
  checksums.validate_selected_entries(path, name)
    .should eq(CrystalClick::ChecksumVerification::SizeChecked)
end

private def w51_mark_rows_by_file(path : String) : Hash(String, Array(UInt64))
  rows_by_file = Hash(String, Array(UInt64)).new
  Dir.glob(File.join(path, "*.mrk2")).sort.each do |mark_path|
    bytes = File.read(mark_path).to_slice
    raise "W51 mark file is not record-aligned" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
    rows = Array(UInt64).new(bytes.size // CrystalClick::WidePart::MARK_SIZE)
    offset = 0
    while offset < bytes.size
      rows << w51_read_u64(bytes, offset + 16)
      offset += CrystalClick::WidePart::MARK_SIZE
    end
    rows_by_file[File.basename(mark_path)] = rows
  end
  rows_by_file
end

private def w51_shift_child_mark_row_counts(path : String, stream : String) : Nil
  marks_path = File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  marks = File.read(marks_path).to_slice.dup
  raise "W51 mutation requires four marks and a sentinel" if marks.size < 5 * CrystalClick::WidePart::MARK_SIZE
  w51_write_u64(marks, CrystalClick::WidePart::MARK_SIZE + 16, 1_u64)
  w51_write_u64(marks, 2 * CrystalClick::WidePart::MARK_SIZE + 16, 3_u64)
  File.write(marks_path, marks)
end

private def w51_shift_child_stream_offsets(path : String, stream : String) : Nil
  marks_path = File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  marks = File.read(marks_path).to_slice.dup
  raise "W51 mutation requires four marks and a sentinel" if marks.size < 5 * CrystalClick::WidePart::MARK_SIZE
  raise "W51 offset mutation did not select the expected stock String stream" unless w51_read_u64(marks, CrystalClick::WidePart::MARK_SIZE + 8) == 5_u64 &&
                                                                                     w51_read_u64(marks, 2 * CrystalClick::WidePart::MARK_SIZE + 8) == 15_u64 &&
                                                                                     w51_read_u64(marks, 3 * CrystalClick::WidePart::MARK_SIZE + 8) == 72_u64
  w51_write_u64(marks, CrystalClick::WidePart::MARK_SIZE + 8, 6_u64)
  w51_write_u64(marks, 2 * CrystalClick::WidePart::MARK_SIZE + 8, 14_u64)
  File.write(marks_path, marks)
end

describe "W51 Array of named Tuple reader" do
  it "opens the two exact stock declarations at the current admission boundary" do
    columns = File.read(File.join(W51_ARRAY_TUPLE_FIXTURE, "columns.txt"))
    columns.should contain("`arr_tuple` Array(Tuple(a UInt64, b String))")
    columns.should contain("`arr_tuple_nullable` Array(Tuple(a Nullable(UInt64), b String))")

    plain = CrystalClick::WidePart.open_typed(W51_ARRAY_TUPLE_FIXTURE, "arr_tuple")
    plain.column_type.should eq("Array(Tuple(a UInt64, b String))")
    nullable = CrystalClick::WidePart.open_typed(W51_ARRAY_TUPLE_FIXTURE, "arr_tuple_nullable")
    nullable.column_type.should eq("Array(Tuple(a Nullable(UInt64), b String))")
  end

  it "admits only the three exact recursive declarations" do
    {
      "Array(Tuple(a UInt64, b String))",
      "Array(Tuple(a Nullable(UInt64), b String))",
      "Array(Tuple(a UInt64, b UInt64))",
    }.each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_true
    end

    {
      "Array(Tuple(UInt64, String))",
      "Array(Tuple(a Nullable(UInt64), b String, c UInt64))",
      "Array(Nullable(Tuple(a UInt64, b String)))",
      "Nullable(Array(Tuple(a UInt64, b String)))",
      "Array(Array(Tuple(a UInt64, b String)))",
    }.each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end
  end

  it "parses recursive syntax separately from exact admission and pins escaped stream order" do
    unadmitted_type = "Array(Tuple(a UInt64, b UInt32))"
    parsed = CrystalClick::WideTypePlan.parse(unadmitted_type).not_nil!
    parsed.name.should eq("Array")
    parsed.child(0).name.should eq("Tuple")
    CrystalClick::WideTypePlan.admitted(unadmitted_type).should be_nil

    plain = CrystalClick::WideTypePlan.admitted("Array(Tuple(a UInt64, b String))").not_nil!
    nullable = CrystalClick::WideTypePlan.admitted("Array(Tuple(a Nullable(UInt64), b String))").not_nil!
    uint64_pair = CrystalClick::WideTypePlan.admitted("Array(Tuple(a UInt64, b UInt64))").not_nil!
    plain.physical_substreams("arr_tuple").should eq([
      "arr_tuple.size0",
      "arr_tuple%2Ea",
      "arr_tuple%2Eb.size",
      "arr_tuple%2Eb",
    ])
    nullable.physical_substreams("arr_tuple_nullable").should eq([
      "arr_tuple_nullable.size0",
      "arr_tuple_nullable%2Ea.null",
      "arr_tuple_nullable%2Ea",
      "arr_tuple_nullable%2Eb.size",
      "arr_tuple_nullable%2Eb",
    ])
    uint64_pair.physical_substreams("arr_tuple_u64_pair").should eq([
      "arr_tuple_u64_pair.size0",
      "arr_tuple_u64_pair%2Ea",
      "arr_tuple_u64_pair%2Eb",
    ])
  end

  it "reads both shapes at exact marks and exposes bounded row-aligned typed batches" do
    plain = CrystalClick::WidePart.open_typed(W51_ARRAY_TUPLE_FIXTURE, "arr_tuple")
    nullable = CrystalClick::WidePart.open_typed(W51_ARRAY_TUPLE_FIXTURE, "arr_tuple_nullable")

    plain.column_type.should eq("Array(Tuple(a UInt64, b String))")
    nullable.column_type.should eq("Array(Tuple(a Nullable(UInt64), b String))")
    plain.row_count.should eq(7_u64)
    nullable.row_count.should eq(7_u64)
    plain.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
    nullable.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
    plain.read_array_tuple_uint64_string_mark_range("arr_tuple", 0, plain.mark_count)
      .should eq(W51_ARRAY_TUPLE_VALUES)
    nullable.read_array_tuple_nullable_uint64_string_mark_range("arr_tuple_nullable", 0, nullable.mark_count)
      .should eq(W51_ARRAY_TUPLE_NULLABLE_VALUES)
    plain.read_array_tuple_uint64_string_mark_range("arr_tuple", 1, 2)
      .should eq(W51_ARRAY_TUPLE_VALUES[2, 4])
    nullable.read_array_tuple_nullable_uint64_string_mark_range("arr_tuple_nullable", 1, 2)
      .should eq(W51_ARRAY_TUPLE_NULLABLE_VALUES[2, 4])
    plain.array_tuple_uint64_string_mark_range_raw_bytes("arr_tuple", 0, plain.mark_count)
      .should eq(w51_tuple_string_raw_bytes(W51_ARRAY_TUPLE_VALUES))
    nullable.array_tuple_nullable_uint64_string_mark_range_raw_bytes("arr_tuple_nullable", 0, nullable.mark_count)
      .should eq(w51_nullable_tuple_string_raw_bytes(W51_ARRAY_TUPLE_NULLABLE_VALUES))

    table_path = w51_copy_fixture
    begin
      table = CrystalClick::WidePartTable.open_selected_typed(
        [table_path], ["arr_tuple", "arr_tuple_nullable"]
      )
      observed_plain = [] of Array(Tuple(UInt64, String))
      observed_nullable = [] of Array(Tuple(UInt64?, String))
      table.scan_typed(batch_rows: 2) do |batch|
        observed_plain.concat(batch.array_tuple_uint64_string_for("arr_tuple"))
        observed_nullable.concat(batch.array_tuple_nullable_uint64_string_for("arr_tuple_nullable"))
      end
      observed_plain.should eq(W51_ARRAY_TUPLE_VALUES)
      observed_nullable.should eq(W51_ARRAY_TUPLE_NULLABLE_VALUES)
    ensure
      w51_remove_fixture(table_path)
    end
  end

  it "materializes both nested Tuple shapes through the offline catalog" do
    w51_with_offline_catalog_root do |root|
      table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")
      plain = table["arr_tuple"].values
      nullable = table["arr_tuple_nullable"].values

      plain.size.should eq(W51_ARRAY_TUPLE_VALUES.size)
      nullable.size.should eq(W51_ARRAY_TUPLE_NULLABLE_VALUES.size)
      plain.each_with_index { |value, index| value.should eq(W51_ARRAY_TUPLE_VALUES[index]) }
      nullable.each_with_index { |value, index| value.should eq(W51_ARRAY_TUPLE_NULLABLE_VALUES[index]) }
    end
  end

  it "rejects mismatched types, shifted per-mark counts, and String offsets before callbacks" do
    type_path = w51_copy_fixture
    begin
      columns_path = File.join(type_path, "columns.txt")
      File.write(
        columns_path,
        File.read(columns_path).sub(
          "Array(Tuple(a UInt64, b String))",
          "Array(Tuple(a UInt64, b UInt64))"
        )
      )
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(type_path, "arr_tuple")
      end
    ensure
      w51_remove_fixture(type_path)
    end

    shifted_path = w51_copy_fixture
    begin
      # Preserve the child stream's aggregate row count and bytes, but move one
      # element boundary from the second mark into the third mark.
      w51_shift_child_mark_row_counts(shifted_path, "arr_tuple%2Eb.size")
      w51_assert_mark_entry_size_checked(shifted_path, "arr_tuple%2Eb.size")
      reader_error = expect_raises(CrystalClick::CorruptPartError) do
        reader = CrystalClick::WidePart.open_typed(shifted_path, "arr_tuple")
        reader.preflight_array_tuple_uint64_string_mark_range_raw_bytes("arr_tuple", 0, 4)
      end
      (reader_error.message || "").should contain("selected substreams have different mark row counts")

      callback_count = 0
      error = expect_raises(CrystalClick::CorruptPartError) do
        table = CrystalClick::WidePartTable.open_selected_typed([shifted_path], ["arr_tuple"])
        table.scan_typed(batch_rows: 2) { callback_count += 1 }
      end
      (error.message || "").should contain("selected substreams have different mark row counts")
      callback_count.should eq(0)
    ensure
      w51_remove_fixture(shifted_path)
    end

    offset_path = w51_copy_fixture
    begin
      original_mark_rows = w51_mark_rows_by_file(offset_path)
      original_mark_rows.size.should eq(10)
      original_mark_rows.each_value { |rows| rows.should eq([2_u64, 2_u64, 2_u64, 1_u64, 0_u64]) }
      payload_path = File.join(offset_path, "#{CrystalClick::StreamName.hash("arr_tuple%2Eb")}.bin")
      original_payload = File.read(payload_path).to_slice.dup
      w51_shift_child_stream_offsets(offset_path, "arr_tuple%2Eb")
      w51_assert_mark_entry_size_checked(offset_path, "arr_tuple%2Eb")
      w51_mark_rows_by_file(offset_path).should eq(original_mark_rows)
      File.read(payload_path).to_slice.should eq(original_payload)
      reader = CrystalClick::WidePart.open_typed(offset_path, "arr_tuple")
      reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
      preflight_error = expect_raises(CrystalClick::CorruptPartError) do
        reader.preflight_array_tuple_uint64_string_mark_range_raw_bytes(
          "arr_tuple", 0, reader.mark_count
        )
      end
      (preflight_error.message || "").should contain("selected data exceeds expected byte count")

      callback_count = 0
      error = expect_raises(CrystalClick::CorruptPartError) do
        table = CrystalClick::WidePartTable.open_selected_typed([offset_path], ["arr_tuple"])
        table.scan_typed(batch_rows: 2) { callback_count += 1 }
      end
      (error.message || "").should contain("selected data exceeds expected byte count")
      callback_count.should eq(0)
    ensure
      w51_remove_fixture(offset_path)
    end
  end

  it "writes and self-reads both exact Array(Tuple) shapes" do
    parent = File.tempname("crystal-click-w51-array-tuple-writer")
    Dir.mkdir(parent)
    plain_path = File.join(parent, "plain")
    nullable_path = File.join(parent, "nullable")
    empty_path = File.join(parent, "empty")
    empty_string_mark_path = File.join(parent, "empty-string-mark")
    all_null_path = File.join(parent, "all-null")
    empty_values = Array.new(W51_KEYS.size) { [] of Tuple(UInt64, String) }
    all_null_values = Array.new(W51_KEYS.size) do |index|
      [{nil.as(UInt64?), "only-null-#{index}"}] of Tuple(UInt64?, String)
    end

    begin
      CrystalClick::WidePartWriter.write_uint64_array_tuple_uint64_string_pair(
        plain_path,
        "pk",
        W51_KEYS.to_unsafe.to_slice(W51_KEYS.size),
        "payload",
        W51_ARRAY_TUPLE_VALUES.to_unsafe.to_slice(W51_ARRAY_TUPLE_VALUES.size),
        rows_per_mark: 2
      )
      CrystalClick::WidePartWriter.write_uint64_array_tuple_nullable_uint64_string_pair(
        nullable_path,
        "pk",
        W51_KEYS.to_unsafe.to_slice(W51_KEYS.size),
        "payload",
        W51_ARRAY_TUPLE_NULLABLE_VALUES.to_unsafe.to_slice(W51_ARRAY_TUPLE_NULLABLE_VALUES.size),
        rows_per_mark: 2
      )
      CrystalClick::WidePartWriter.write_uint64_array_tuple_uint64_string_pair(
        empty_string_mark_path,
        "pk",
        W51_KEYS.to_unsafe.to_slice(W51_KEYS.size),
        "payload",
        W51_EMPTY_STRING_MARK_VALUES.to_unsafe.to_slice(W51_EMPTY_STRING_MARK_VALUES.size),
        rows_per_mark: 2
      )
      CrystalClick::WidePartWriter.write_uint64_array_tuple_uint64_string_pair(
        empty_path,
        "pk",
        W51_KEYS.to_unsafe.to_slice(W51_KEYS.size),
        "payload",
        empty_values.to_unsafe.to_slice(empty_values.size),
        rows_per_mark: 2
      )
      CrystalClick::WidePartWriter.write_uint64_array_tuple_nullable_uint64_string_pair(
        all_null_path,
        "pk",
        W51_KEYS.to_unsafe.to_slice(W51_KEYS.size),
        "payload",
        all_null_values.to_unsafe.to_slice(all_null_values.size),
        rows_per_mark: 2
      )

      plain = CrystalClick::WidePart.open_typed(plain_path, "payload")
      nullable = CrystalClick::WidePart.open_typed(nullable_path, "payload")
      plain.column_type.should eq("Array(Tuple(a UInt64, b String))")
      nullable.column_type.should eq("Array(Tuple(a Nullable(UInt64), b String))")
      plain.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
      nullable.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
      plain.read_array_tuple_uint64_string_mark_range("payload", 0, plain.mark_count)
        .should eq(W51_ARRAY_TUPLE_VALUES)
      nullable.read_array_tuple_nullable_uint64_string_mark_range("payload", 0, nullable.mark_count)
        .should eq(W51_ARRAY_TUPLE_NULLABLE_VALUES)
      plain.read_array_tuple_uint64_string_mark_range("payload", 1, 2)
        .should eq(W51_ARRAY_TUPLE_VALUES[2, 4])
      nullable.read_array_tuple_nullable_uint64_string_mark_range("payload", 1, 2)
        .should eq(W51_ARRAY_TUPLE_NULLABLE_VALUES[2, 4])

      empty = CrystalClick::WidePart.open_typed(empty_path, "payload")
      empty.read_array_tuple_uint64_string_mark_range("payload", 0, empty.mark_count)
        .should eq(empty_values)
      empty_string_mark = CrystalClick::WidePart.open_typed(empty_string_mark_path, "payload")
      empty_string_mark.read_array_tuple_uint64_string_mark_range("payload", 0, empty_string_mark.mark_count)
        .should eq(W51_EMPTY_STRING_MARK_VALUES)
      empty_string_marks = File.read(
        File.join(empty_string_mark_path, "#{CrystalClick::StreamName.hash("payload%2Eb")}.mrk2")
      ).to_slice
      first_empty_boundary = CrystalClick::WidePart::MARK_SIZE
      after_empty_boundary = 2 * CrystalClick::WidePart::MARK_SIZE
      w51_read_u64(empty_string_marks, first_empty_boundary)
        .should eq(w51_read_u64(empty_string_marks, after_empty_boundary))
      w51_read_u64(empty_string_marks, first_empty_boundary + 8)
        .should eq(w51_read_u64(empty_string_marks, after_empty_boundary + 8))
      w51_read_u64(empty_string_marks, first_empty_boundary + 16).should eq(2_u64)
      w51_read_u64(empty_string_marks, after_empty_boundary + 16).should eq(2_u64)
      all_null = CrystalClick::WidePart.open_typed(all_null_path, "payload")
      all_null.read_array_tuple_nullable_uint64_string_mark_range("payload", 0, all_null.mark_count)
        .should eq(all_null_values)
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
