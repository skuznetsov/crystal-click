require "./spec_helper"

private def w62_catalog_table(root : String, part : String, type : String) : CrystalClick::OfflineTable
  database_uuid = "39fb5af3-33d7-4270-97c6-7a05027c9aa7"
  table_uuid = "acf5fcb3-6448-49b0-91c6-c647bce9ce04"
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))
  File.write(File.join(root, "metadata", "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  database_path = File.join(root, "store", database_uuid[0, 3], database_uuid)
  FileUtils.mkdir_p(database_path)
  File.write(
    File.join(database_path, "events.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(`pk` UInt64, `payload` #{type})\nENGINE = MergeTree\nORDER BY pk\n"
  )
  table_path = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(table_path)
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  FileUtils.cp_r(part, File.join(table_path, File.basename(part)))
  CrystalClick::OfflineCatalog.open(root).table("lab", "events")
end

private def w62_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def w62_shift_first_mark_rows(part : String, stream : String) : Nil
  marks_path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  marks = File.read(marks_path).to_slice.dup
  w62_write_u64(marks, 16, 1_u64)
  w62_write_u64(marks, CrystalClick::WidePart::MARK_SIZE + 16, 2_u64)
  File.write(marks_path, marks)
end

describe CrystalClick::WidePartTable do
  it "scans nullable nested BFloat16 and gives the offline catalog deep-owned rows" do
    parent = File.tempname("crystal-click-w62-table-catalog")
    Dir.mkdir(parent)
    part = File.join(parent, "all_1_3_0")
    keys = [1_u64, 2_u64, 3_u64]
    low = CrystalClick::BFloat16Value.new(0x3f80_u16)
    high = CrystalClick::BFloat16Value.new(0xbf80_u16)
    values = [
      [] of Array(CrystalClick::BFloat16Value?),
      [[] of CrystalClick::BFloat16Value?, [nil, low, high] of CrystalClick::BFloat16Value?],
      [[high, nil] of CrystalClick::BFloat16Value?],
    ] of Array(Array(CrystalClick::BFloat16Value?))

    begin
      CrystalClick::WidePartWriter.write_uint64_array_array_nullable_numeric_pair(
        part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", values.to_unsafe.to_slice(values.size), rows_per_mark: 2
      )

      selected = CrystalClick::WidePartTable.open_selected_typed([part], ["payload"])
      observed = [] of Array(Array(CrystalClick::BFloat16Value?))
      selected.scan_typed(batch_rows: 1) do |batch|
        observed.concat(batch.array_array_nullable_numeric_values("payload", CrystalClick::BFloat16Value))
      end
      observed.should eq(values)

      table = w62_catalog_table(File.join(parent, "catalog"), part, "Array(Array(Nullable(BFloat16)))")
      materialized = table["payload"].values.map { |value| value.as(Array(Array(CrystalClick::BFloat16Value?))) }
      materialized.should eq(values)
      materialized[1][1][1] = nil
      materialized[1] << ([] of CrystalClick::BFloat16Value?)
      table["payload"].values.map { |value| value.as(Array(Array(CrystalClick::BFloat16Value?))) }.should eq(values)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects shifted selected-mark boundaries on each nullable nested wide stream before callback" do
    parent = File.tempname("crystal-click-w62-table-corruption")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64, 3_u64]
    bit = CrystalClick::BFloat16Value.new(0x3f80_u16)
    values = [
      [[bit, nil] of CrystalClick::BFloat16Value?],
      [[nil, bit] of CrystalClick::BFloat16Value?],
      [[bit] of CrystalClick::BFloat16Value?],
    ] of Array(Array(CrystalClick::BFloat16Value?))

    begin
      ["payload.size0", "payload.size1", "payload.null", "payload"].each_with_index do |stream, index|
        part = File.join(parent, "all_#{index + 1}_#{index + 1}_0")
        CrystalClick::WidePartWriter.write_uint64_array_array_nullable_numeric_pair(
          part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", values.to_unsafe.to_slice(values.size), rows_per_mark: 2
        )
        w62_shift_first_mark_rows(part, stream)
        callbacks = 0
        expect_raises(CrystalClick::CorruptPartError) do
          table = CrystalClick::WidePartTable.open_selected_typed([part], ["payload"])
          table.scan_typed_candidate_marks([[1_i32]]) { |_batch| callbacks += 1 }
        end
        callbacks.should eq(0)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
