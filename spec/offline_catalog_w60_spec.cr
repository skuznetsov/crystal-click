require "./spec_helper"

OFFLINE_W60_DATABASE_UUID = "f9477900-1255-40dc-aef2-1f74f167b2df"
OFFLINE_W60_TABLE_UUID    = "729140dc-51b8-48d6-958a-123d8d09e17c"

private def offline_w60_store_path(root : String, uuid : String) : String
  File.join(root, "store", uuid[0, 3], uuid)
end

private def offline_w60_catalog_table(root : String, part : String) : CrystalClick::OfflineTable
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))
  File.write(
    File.join(root, "metadata", "lab.sql"),
    "ATTACH DATABASE _ UUID '#{OFFLINE_W60_DATABASE_UUID}'\nENGINE = Atomic\n"
  )
  database_path = offline_w60_store_path(root, OFFLINE_W60_DATABASE_UUID)
  FileUtils.mkdir_p(database_path)
  File.write(
    File.join(database_path, "events.sql"),
    "ATTACH TABLE _ UUID '#{OFFLINE_W60_TABLE_UUID}'\n" +
    "(\n    `pk` UInt64,\n    `payload` Array(Array(Nullable(Int16)))\n)\n" +
    "ENGINE = MergeTree\nORDER BY pk\n"
  )

  table_path = offline_w60_store_path(root, OFFLINE_W60_TABLE_UUID)
  FileUtils.mkdir_p(table_path)
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  FileUtils.cp_r(part, File.join(table_path, File.basename(part)))
  CrystalClick::OfflineCatalog.open(root).table("lab", "events")
end

private def offline_w60_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def offline_w60_shift_mark_rows(part : String, stream : String) : Nil
  marks_path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  marks = File.read(marks_path).to_slice.dup
  raise "W60 mutation requires two data marks and a sentinel" unless marks.size >= 3 * CrystalClick::WidePart::MARK_SIZE
  offline_w60_write_u64(marks, 16, 1_u64)
  offline_w60_write_u64(marks, CrystalClick::WidePart::MARK_SIZE + 16, 2_u64)
  File.write(marks_path, marks)
end

describe CrystalClick::WidePartTable do
  it "scans nested nullable primitive numerics and returns catalog-owned deep copies" do
    parent = File.tempname("crystal-click-offline-w60-array-array-nullable-numeric")
    Dir.mkdir(parent)
    part = File.join(parent, "all_1_3_0")
    keys = [1_u64, 2_u64, 3_u64]
    values = [
      [] of Array(Int16?),
      [[] of Int16?, [nil, 0_i16, Int16::MIN] of Int16?, [] of Int16?],
      [[Int16::MAX, nil] of Int16?, [] of Int16?],
    ] of Array(Array(Int16?))

    begin
      CrystalClick::WidePartWriter.write_uint64_array_array_nullable_numeric_pair(
        part,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "payload",
        values.to_unsafe.to_slice(values.size),
        rows_per_mark: 2
      )

      reader = CrystalClick::WidePart.open_typed(part, "payload")
      reader.column_type.should eq("Array(Array(Nullable(Int16)))")
      reader.array_array_nullable_numeric_mark_range_raw_bytes("payload", 0, reader.mark_count).should eq(79_u64)

      selected = CrystalClick::WidePartTable.open_selected_typed([part], ["payload"])
      observed = [] of Array(Array(Int16?))
      offsets = [] of {Int32, UInt64}
      selected.scan_typed(batch_rows: 1) do |batch|
        batch.column_type_for("payload").should eq("Array(Array(Nullable(Int16)))")
        rows = batch.array_array_nullable_numeric_values("payload", Int16)
        observed.concat(rows)
        offsets << {batch.mark_index, batch.part_row_offset}
        expect_raises(CrystalClick::UnsupportedFormatError) do
          batch.array_array_nullable_numeric_values("payload", UInt16)
        end
      end
      observed.should eq(values)
      offsets.should eq([{0_i32, 0_u64}, {0_i32, 1_u64}, {1_i32, 2_u64}])

      table = offline_w60_catalog_table(File.join(parent, "catalog"), part)
      table.columns.map { |column| {column.name, column.type} }.should eq([
        {"pk", "UInt64"},
        {"payload", "Array(Array(Nullable(Int16)))"},
      ])
      materialized = table["payload"].values.map { |value| value.as(Array(Array(Int16?))) }
      materialized.should eq(values)

      owned_row = materialized[1]
      owned_row[1][1] = -9_i16
      owned_row[1] << 42_i16
      owned_row << ([] of Int16?)
      table["payload"].values.map { |value| value.as(Array(Array(Int16?))) }.should eq(values)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "does not callback for a nested nullable numeric mark with shifted child boundaries" do
    parent = File.tempname("crystal-click-offline-w60-corrupt-mark")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64, 3_u64]
    values = [
      [[1_i16, nil] of Int16?],
      [[2_i16, nil] of Int16?],
      [[3_i16, nil] of Int16?],
    ] of Array(Array(Int16?))

    begin
      ["payload.size0", "payload.size1", "payload.null", "payload"].each_with_index do |stream, index|
        part = File.join(parent, "all_#{index + 1}_#{index + 1}_0")
        CrystalClick::WidePartWriter.write_uint64_array_array_nullable_numeric_pair(
          part,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "payload",
          values.to_unsafe.to_slice(values.size),
          rows_per_mark: 2
        )
        offline_w60_shift_mark_rows(part, stream)

        callbacks = 0
        expect_raises(CrystalClick::CorruptPartError) do
          table = CrystalClick::WidePartTable.open_selected_typed([part], ["payload"])
          table.scan_typed_candidate_marks([[1_i32]]) do |_batch|
            callbacks += 1
          end
        end
        callbacks.should eq(0)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
