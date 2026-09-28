require "./spec_helper"

W61_TABLE_DATABASE_UUID = "fb5b6c80-6374-48cf-91d5-e036f60c6371"
W61_TABLE_UUID          = "5de1e294-80fa-48e2-9346-43e0e0e6a148"

private def w61_table_store_path(root : String, uuid : String) : String
  File.join(root, "store", uuid[0, 3], uuid)
end

private def w61_table_values : Array(Array(Array(String?)))
  long_payload = "x" * 65_537
  binary_payload = "a\x00b"
  [
    [] of Array(String?),
    [[] of String?],
    [[nil, nil] of String?, [] of String?],
    [[nil] of String?, [nil, nil] of String?],
    [[] of String?],
    [[] of String?],
    [[nil, "", binary_payload, "é", long_payload] of String?, [] of String?],
    [["tail", nil] of String?],
  ] of Array(Array(String?))
end

private def w61_table_write_part(path : String, values : Array(Array(Array(String?))), rows_per_mark : Int = 2) : Nil
  keys = Array(UInt64).new(values.size) { |index| (index + 1).to_u64 }
  CrystalClick::WidePartWriter.write_uint64_array_array_nullable_string_pair(
    path,
    "pk",
    keys.to_unsafe.to_slice(keys.size),
    "payload",
    values.to_unsafe.to_slice(values.size),
    rows_per_mark: rows_per_mark
  )
end

private def w61_table_catalog(root : String, part : String) : CrystalClick::OfflineTable
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))
  File.write(File.join(root, "metadata", "lab.sql"), "ATTACH DATABASE _ UUID '#{W61_TABLE_DATABASE_UUID}'\nENGINE = Atomic\n")
  database_path = w61_table_store_path(root, W61_TABLE_DATABASE_UUID)
  FileUtils.mkdir_p(database_path)
  File.write(
    File.join(database_path, "events.sql"),
    "ATTACH TABLE _ UUID '#{W61_TABLE_UUID}'\n" +
    "(\n    `pk` UInt64,\n    `payload` Array(Array(Nullable(String)))\n)\n" +
    "ENGINE = MergeTree\nORDER BY pk\n"
  )

  table_path = w61_table_store_path(root, W61_TABLE_UUID)
  FileUtils.mkdir_p(table_path)
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  FileUtils.cp_r(part, File.join(table_path, File.basename(part)))
  CrystalClick::OfflineCatalog.open(root).table("lab", "events")
end

private def w61_table_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def w61_table_shift_mark_decompressed_offset(part : String, stream : String, mark_index : Int, delta : UInt64) : Nil
  marks_path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  marks = File.read(marks_path).to_slice.dup
  raise "W61 mutation requires the selected mark" unless marks.size >= (mark_index + 1) * CrystalClick::WidePart::MARK_SIZE
  offset = mark_index * CrystalClick::WidePart::MARK_SIZE + 8
  current = 0_u64
  8.times { |byte| current |= marks[offset + byte].to_u64 << (byte * 8) }
  w61_table_write_u64(marks, offset, current + delta)
  File.write(marks_path, marks)
end

describe CrystalClick::WidePartTable do
  it "batches exact nested nullable String values and materializes deep-owned catalog copies" do
    parent = File.tempname("crystal-click-w61-table-array-array-nullable-string")
    Dir.mkdir(parent)
    part = File.join(parent, "all_1_8_0")
    values = w61_table_values

    begin
      w61_table_write_part(part, values)
      reader = CrystalClick::WidePart.open_typed(part, "payload")
      reader.column_type.should eq("Array(Array(Nullable(String)))")
      reader.array_array_nullable_string_mark_range_raw_bytes("payload", 0, reader.mark_count).should be > 0_u64

      selected = CrystalClick::WidePartTable.open_selected_typed([part], ["payload"])
      observed = [] of Array(Array(String?))
      mark_indexes = [] of Int32
      part_offsets = [] of UInt64
      selected.scan_typed(batch_rows: 1) do |batch|
        batch.column_type_for("payload").should eq("Array(Array(Nullable(String)))")
        observed.concat(batch.array_array_nullable_strings_for("payload"))
        mark_indexes << batch.mark_index
        part_offsets << batch.part_row_offset
      end
      observed.should eq(values)
      mark_indexes.should eq([0_i32, 0_i32, 1_i32, 1_i32, 2_i32, 2_i32, 3_i32, 3_i32])
      part_offsets.should eq((0_u64..7_u64).to_a)

      catalog = w61_table_catalog(File.join(parent, "catalog"), part)
      catalog.columns.map { |column| {column.name, column.type} }.should eq([
        {"pk", "UInt64"},
        {"payload", "Array(Array(Nullable(String)))"},
      ])
      materialized = catalog["payload"].values.map { |value| value.as(Array(Array(String?))) }
      materialized.should eq(values)
      materialized[6][0][1] = "changed"
      materialized[6][0] << "also changed"
      materialized[6] << ([] of String?)
      catalog["payload"].values.map { |value| value.as(Array(Array(String?))) }.should eq(values)

      error = expect_raises(CrystalClick::BoundsError) do
        catalog["payload"].values(max_string_bytes: 2_u64)
      end
      error.message.to_s.should contain("String payload limit")
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "does not callback with a selected mark whose W61 stream boundary shifted" do
    parent = File.tempname("crystal-click-w61-table-corrupt-mark")
    Dir.mkdir(parent)
    values = [
      [[nil, "one"] of String?],
      [["two", nil] of String?],
      [["three", nil] of String?],
    ] of Array(Array(String?))

    begin
      ["payload.size0", "payload.size1", "payload.null", "payload.size", "payload"].each_with_index do |stream, index|
        part = File.join(parent, "all_#{index + 1}_#{index + 1}_0")
        w61_table_write_part(part, values)
        delta = stream.ends_with?(".null") || stream == "payload" ? 1_u64 : 8_u64
        w61_table_shift_mark_decompressed_offset(part, stream, 1, delta)

        callbacks = [] of Int32
        table = CrystalClick::WidePartTable.open_selected_typed([part], ["payload"])
        expect_raises(CrystalClick::CorruptPartError) do
          table.scan_typed_candidate_marks([[1_i32]]) { |batch| callbacks << batch.mark_index }
        end
        callbacks.should be_empty
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
