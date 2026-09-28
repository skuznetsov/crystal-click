require "./spec_helper"

W55_ARRAY_TUPLE_FIXTURE = File.expand_path("../test/fixtures/public/wide_array_tuple_w55/part", __DIR__)
W55_KEYS                = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64]
W55_TYPE                = "Array(Tuple(a UInt64, b UInt64))"
W55_VALUES              = [
  [] of Tuple(UInt64, UInt64),
  [{0_u64, 0_u64}, {UInt64::MAX, UInt64::MAX}] of Tuple(UInt64, UInt64),
  [{42_u64, UInt64::MAX}] of Tuple(UInt64, UInt64),
  [{UInt64::MAX, 0_u64}, {0_u64, UInt64::MAX}] of Tuple(UInt64, UInt64),
  [] of Tuple(UInt64, UInt64),
  [] of Tuple(UInt64, UInt64),
  [{123_u64, 456_u64}] of Tuple(UInt64, UInt64),
] of Array(Tuple(UInt64, UInt64))

private def w55_copy_fixture : String
  parent = File.tempname("crystal-click-w55-array-tuple-part")
  Dir.mkdir(parent)
  part = File.join(parent, "all_1_1_0")
  FileUtils.cp_r(W55_ARRAY_TUPLE_FIXTURE, part)
  part
end

private def w55_remove_fixture(part : String) : Nil
  parent = File.dirname(part)
  unless File.basename(part) == "all_1_1_0" && File.basename(parent).includes?("crystal-click-w55-array-tuple-part")
    raise "refusing to remove a path that is not a W55 temporary fixture"
  end
  FileUtils.rm_rf(parent)
end

private def w55_with_offline_catalog_root(& : String ->)
  root = File.tempname("crystal-click-w55-array-tuple-catalog")
  Dir.mkdir(root)
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))

  database_uuid = "ff1ac04e-f1fd-424d-a879-08034966ec79"
  table_uuid = "310d4941-3310-420f-9718-30fe870b8f0b"
  database_store = File.join(root, "store", database_uuid[0, 3], database_uuid)
  table_store = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(database_store)
  File.write(File.join(root, "metadata", "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  File.write(
    File.join(database_store, "events.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `pk` UInt64,\n    `payload` #{W55_TYPE}\n)\nENGINE = MergeTree\nORDER BY pk\n"
  )
  FileUtils.mkdir_p(table_store)
  File.write(File.join(table_store, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_store, "detached"))
  FileUtils.cp_r(W55_ARRAY_TUPLE_FIXTURE, File.join(table_store, "all_1_1_0"))

  yield root
ensure
  FileUtils.rm_rf(root) if root && Dir.exists?(root)
end

private def w55_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

private def w55_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def w55_shift_mark_rows(path : String, stream : String) : Nil
  marks_path = File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  marks = File.read(marks_path).to_slice.dup
  raise "W55 mutation requires four marks and a sentinel" if marks.size < 5 * CrystalClick::WidePart::MARK_SIZE
  w55_write_u64(marks, CrystalClick::WidePart::MARK_SIZE + 16, 1_u64)
  w55_write_u64(marks, 2 * CrystalClick::WidePart::MARK_SIZE + 16, 3_u64)
  File.write(marks_path, marks)
end

private def w55_shift_mark(path : String, stream : String, field_offset : Int, delta : UInt64) : Nil
  marks_path = File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  marks = File.read(marks_path).to_slice.dup
  raise "W55 mutation requires four marks and a sentinel" if marks.size < 5 * CrystalClick::WidePart::MARK_SIZE
  # Shift the second mark boundary so the first selected granule is malformed;
  # the table must reject it before emitting any callback.
  offset = CrystalClick::WidePart::MARK_SIZE + field_offset
  original = w55_read_u64(marks, offset)
  raise "W55 mutation target overflows UInt64" if delta > UInt64::MAX - original
  w55_write_u64(marks, offset, original + delta)
  File.write(marks_path, marks)
end

private def w55_assert_scan_fails_before_callback(path : String) : Nil
  callbacks = 0
  expect_raises(CrystalClick::CorruptPartError) do
    table = CrystalClick::WidePartTable.open_selected_typed([path], ["payload"])
    table.scan_typed(batch_rows: 2) { callbacks += 1 }
  end
  callbacks.should eq(0)
end

describe "W55 Array of named UInt64 Tuple reader and writer" do
  it "reads the exact stock type across marks, including its empty child mark" do
    columns = File.read(File.join(W55_ARRAY_TUPLE_FIXTURE, "columns.txt"))
    columns.should contain("`payload` #{W55_TYPE}")

    reader = CrystalClick::WidePart.open_typed(W55_ARRAY_TUPLE_FIXTURE, "payload")
    reader.column_type.should eq(W55_TYPE)
    reader.row_count.should eq(7_u64)
    reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
    reader.read_array_tuple_uint64_uint64_mark_range("payload", 0, reader.mark_count)
      .should eq(W55_VALUES)
    reader.read_array_tuple_uint64_uint64_mark_range("payload", 2, 2)
      .should eq(W55_VALUES[4, 3])

    {"payload%2Ea", "payload%2Eb"}.each do |stream|
      marks_path = File.join(W55_ARRAY_TUPLE_FIXTURE, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
      marks = File.read(marks_path).to_slice
      empty_granule = 2 * CrystalClick::WidePart::MARK_SIZE
      short_tail = 3 * CrystalClick::WidePart::MARK_SIZE
      w55_read_u64(marks, empty_granule).should eq(w55_read_u64(marks, short_tail))
      w55_read_u64(marks, empty_granule + 8).should eq(w55_read_u64(marks, short_tail + 8))
    end
  end

  it "keeps table batches and offline catalog materialization row-aligned" do
    table_path = w55_copy_fixture
    begin
      table = CrystalClick::WidePartTable.open_selected_typed([table_path], ["payload"])
      observed = [] of Array(Tuple(UInt64, UInt64))
      table.scan_typed(batch_rows: 2) do |batch|
        observed.concat(batch.array_tuple_uint64_uint64_for("payload"))
      end
      observed.should eq(W55_VALUES)

      one_row_batches = [] of Int32
      one_row_values = [] of Array(Tuple(UInt64, UInt64))
      table.scan_typed(batch_rows: 1) do |batch|
        rows = batch.array_tuple_uint64_uint64_for("payload")
        one_row_batches << rows.size.to_i32
        one_row_values.concat(rows)
      end
      one_row_batches.should eq(Array.new(W55_VALUES.size, 1_i32))
      one_row_values.should eq(W55_VALUES)

      later_rows = [] of Array(Tuple(UInt64, UInt64))
      table.scan_typed_window(4_u64, max_rows: 3) do |batch|
        later_rows.concat(batch.array_tuple_uint64_uint64_for("payload"))
      end
      later_rows.should eq(W55_VALUES[4, 3])
    ensure
      w55_remove_fixture(table_path)
    end

    w55_with_offline_catalog_root do |root|
      table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")
      values = table["payload"].values
      values.size.should eq(W55_VALUES.size)
      values.each_with_index { |value, index| value.should eq(W55_VALUES[index]) }
    end
  end

  it "rejects independent child mark row-count and offset mutations before callbacks" do
    {"payload%2Ea", "payload%2Eb"}.each do |stream|
      row_count_path = w55_copy_fixture
      begin
        w55_shift_mark_rows(row_count_path, stream)
        w55_assert_scan_fails_before_callback(row_count_path)
      ensure
        w55_remove_fixture(row_count_path)
      end

      offset_path = w55_copy_fixture
      begin
        # Move the second-mark decompressed offset one UInt64 forward while
        # leaving its row count intact, making the first granule inconsistent.
        w55_shift_mark(offset_path, stream, 8, 8_u64)
        w55_assert_scan_fails_before_callback(offset_path)
      ensure
        w55_remove_fixture(offset_path)
      end
    end
  end

  it "rejects reordered or missing physical child declarations" do
    reordered_path = w55_copy_fixture
    begin
      metadata_path = File.join(reordered_path, "columns_substreams.txt")
      original = File.read(metadata_path)
      reordered = original.sub(
        "\tpayload.size0\n\tpayload%2Ea\n\tpayload%2Eb\n",
        "\tpayload.size0\n\tpayload%2Eb\n\tpayload%2Ea\n"
      )
      reordered.should_not eq(original)
      File.write(metadata_path, reordered)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(reordered_path, "payload")
      end
    ensure
      w55_remove_fixture(reordered_path)
    end

    missing_path = w55_copy_fixture
    begin
      metadata_path = File.join(missing_path, "columns_substreams.txt")
      original = File.read(metadata_path)
      missing = original.sub(
        "3 substreams for column `payload`:\n\tpayload.size0\n\tpayload%2Ea\n\tpayload%2Eb\n",
        "2 substreams for column `payload`:\n\tpayload.size0\n\tpayload%2Ea\n"
      )
      missing.should_not eq(original)
      File.write(metadata_path, missing)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(missing_path, "payload")
      end
    ensure
      w55_remove_fixture(missing_path)
    end
  end

  it "writes and self-reads the exact shape with empty rows and a short final mark" do
    parent = File.tempname("crystal-click-w55-array-tuple-writer")
    Dir.mkdir(parent)
    path = File.join(parent, "part")
    begin
      CrystalClick::WidePartWriter.write_uint64_array_tuple_uint64_uint64_pair(
        path,
        "pk",
        W55_KEYS.to_unsafe.to_slice(W55_KEYS.size),
        "payload",
        W55_VALUES.to_unsafe.to_slice(W55_VALUES.size),
        rows_per_mark: 2
      )
      writer_part = CrystalClick::WidePart.open_typed(path, "payload")
      writer_part.column_type.should eq(W55_TYPE)
      writer_part.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
      writer_part.read_array_tuple_uint64_uint64_mark_range("payload", 0, writer_part.mark_count)
        .should eq(W55_VALUES)
      writer_part.read_array_tuple_uint64_uint64_mark_range("payload", 2, 2)
        .should eq(W55_VALUES[4, 3])
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
