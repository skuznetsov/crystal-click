require "./spec_helper"

W59_TABLE_DATABASE_UUID = "b7100d53-f783-40da-a9ee-94e998d9f2a3"
W59_TABLE_UUID          = "1d49d460-aadd-4bc7-8b93-902ff7635a0b"

private def w59_table_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def w59_table_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

private def w59_table_store_path(root : String, uuid : String) : String
  File.join(root, "store", uuid[0, 3], uuid)
end

private def w59_table_values : Array(Array(Array(String)))
  [
    [] of Array(String),
    [[] of String, ["alpha", ""]],
    [] of Array(String),
    [["later", "é"], [] of String],
    [["tail"]],
  ] of Array(Array(String))
end

private def w59_table_write_part(path : String, values : Array(Array(Array(String))), rows_per_mark : Int = 2) : Nil
  keys = Array(UInt64).new(values.size) { |index| (index + 1).to_u64 }
  CrystalClick::WidePartWriter.write_uint64_array_array_string_pair(
    path,
    "pk",
    keys.to_unsafe.to_slice(keys.size),
    "payload",
    values.to_unsafe.to_slice(values.size),
    rows_per_mark: rows_per_mark
  )
end

private def w59_table_catalog(root : String, part : String) : CrystalClick::OfflineTable
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))
  File.write(File.join(root, "metadata", "lab.sql"), "ATTACH DATABASE _ UUID '#{W59_TABLE_DATABASE_UUID}'\nENGINE = Atomic\n")
  database_path = w59_table_store_path(root, W59_TABLE_DATABASE_UUID)
  FileUtils.mkdir_p(database_path)
  File.write(
    File.join(database_path, "events.sql"),
    "ATTACH TABLE _ UUID '#{W59_TABLE_UUID}'\n" +
    "(\n    `pk` UInt64,\n    `payload` Array(Array(String))\n)\n" +
    "ENGINE = MergeTree\nORDER BY pk\n"
  )

  table_path = w59_table_store_path(root, W59_TABLE_UUID)
  FileUtils.mkdir_p(table_path)
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  FileUtils.cp_r(part, File.join(table_path, File.basename(part)))
  CrystalClick::OfflineCatalog.open(root).table("lab", "events")
end

describe CrystalClick::WidePartTable do
  it "batches exact Array(Array(String)) values across marks and materializes owned catalog values" do
    parent = File.tempname("crystal-click-w59-table-array-array-string")
    Dir.mkdir(parent)
    part = File.join(parent, "all_1_5_0")
    values = w59_table_values

    begin
      w59_table_write_part(part, values)
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["payload"])
      observed = [] of Array(Array(String))
      mark_indexes = [] of Int32
      table.scan_typed(batch_rows: 1) do |batch|
        batch.column_type_for("payload").should eq("Array(Array(String))")
        observed.concat(batch.array_array_strings_for("payload"))
        mark_indexes << batch.mark_index
      end
      observed.should eq(values)
      mark_indexes.should eq([0_i32, 0_i32, 1_i32, 1_i32, 2_i32])

      catalog = w59_table_catalog(File.join(parent, "catalog"), part)
      catalog.columns.map { |column| {column.name, column.type} }.should eq([
        {"pk", "UInt64"},
        {"payload", "Array(Array(String))"},
      ])
      materialized = catalog["payload"].values.map { |value| value.as(Array(Array(String))) }
      materialized.should eq(values)
      owned_row = materialized[3]
      owned_row[0][0].to_unsafe.should_not eq(observed[3][0][0].to_unsafe)
      owned_row[0][0] = "changed"
      owned_row[0] << "also changed"
      owned_row << ([] of String)
      catalog["payload"].values.map { |value| value.as(Array(Array(String))) }.should eq(values)

      expect_raises(CrystalClick::BoundsError) do
        catalog["payload"].values(max_string_bytes: 1_u64)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "does not callback with a selected mark whose nested child offset is corrupt" do
    parent = File.tempname("crystal-click-w59-table-corrupt-child-mark")
    Dir.mkdir(parent)
    part = File.join(parent, "all_1_5_0")
    values = w59_table_values

    begin
      w59_table_write_part(part, values)
      valid_callbacks = [] of Int32
      CrystalClick::WidePartTable.open_selected_typed([part], ["payload"])
        .scan_typed_candidate_marks([[1_i32]]) { |batch| valid_callbacks << batch.mark_index }
      valid_callbacks.should eq([1_i32])

      marks_path = File.join(part, "#{CrystalClick::StreamName.hash("payload.size1")}.mrk2")
      marks = File.read(marks_path).to_slice.dup
      mark_offset = CrystalClick::WidePart::MARK_SIZE + 8
      original_offset = w59_table_read_u64(marks, mark_offset)
      w59_table_write_u64(marks, mark_offset, original_offset + 8_u64)
      File.write(marks_path, marks)

      table = CrystalClick::WidePartTable.open_selected_typed([part], ["payload"])
      callback_marks = [] of Int32
      expect_raises(CrystalClick::CorruptPartError) do
        table.scan_typed_candidate_marks([[1_i32]]) do |batch|
          callback_marks << batch.mark_index
        end
      end
      callback_marks.should be_empty
      callback_marks.should_not contain(1_i32)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "enforces the catalog Array-element budget across nested String marks" do
    parent = File.tempname("crystal-click-w59-catalog-array-budget")
    Dir.mkdir(parent)
    part = File.join(parent, "all_1_16_0")
    # Each mark stays below the reader/writer's 65,536-leaf bound. The
    # catalog-owned aggregate crosses its separate one-million-element cap.
    large_inner = Array(String).new(62_500, "")
    values = Array(Array(Array(String))).new(16) { [large_inner] }

    begin
      w59_table_write_part(part, values, rows_per_mark: 1)
      catalog = w59_table_catalog(File.join(parent, "catalog"), part)
      error = expect_raises(CrystalClick::BoundsError) { catalog["payload"].values }
      error.message.to_s.should contain("Array element limit")
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
