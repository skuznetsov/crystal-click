require "./spec_helper"

private def w64_catalog_table(root : String, part : String, type : String) : CrystalClick::OfflineTable
  database_uuid = "39fb5af3-33d7-4270-97c6-7a05027c9aa8"
  table_uuid = "acf5fcb3-6448-49b0-91c6-c647bce9ce05"
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))
  File.write(File.join(root, "metadata", "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  database_path = File.join(root, "store", database_uuid[0, 3], database_uuid)
  FileUtils.mkdir_p(database_path)
  File.write(File.join(database_path, "events.sql"), "ATTACH TABLE _ UUID '#{table_uuid}'\n(`pk` UInt64, `payload` #{type})\nENGINE = MergeTree\nORDER BY pk\n")
  table_path = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(table_path)
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  FileUtils.cp_r(part, File.join(table_path, File.basename(part)))
  CrystalClick::OfflineCatalog.open(root).table("lab", "events")
end

private def w64_shift_first_mark_rows(part : String, stream : String) : Nil
  marks_path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  marks = File.read(marks_path).to_slice.dup
  {0, 1}.each do |mark_index|
    value = mark_index == 0 ? 1_u64 : 2_u64
    offset = mark_index * CrystalClick::WidePart::MARK_SIZE + 16
    8.times { |index| marks[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
  end
  File.write(marks_path, marks)
end

describe CrystalClick::WidePartTable do
  it "exposes nested Decimal32 coefficients through typed batches and deep-owned catalog values" do
    parent = File.tempname("crystal-click-w64-table-decimal32")
    Dir.mkdir(parent)
    part = File.join(parent, "all_1_3_0")
    keys = [1_u64, 2_u64, 3_u64]
    values = [
      [] of Array(Int32),
      [[] of Int32, [-123_i32, 0_i32, 999_999_999_i32]],
      [[42_i32]],
    ] of Array(Array(Int32))
    begin
      CrystalClick::WidePartWriter.write_uint64_array_array_decimal32_pair(
        part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", values.to_unsafe.to_slice(values.size), 2, rows_per_mark: 2
      )
      selected = CrystalClick::WidePartTable.open_selected_typed([part], ["payload"])
      observed = [] of Array(Array(Int32))
      selected.scan_typed(batch_rows: 1) { |batch| observed.concat(batch.array_array_decimal32_raw_for("payload")) }
      observed.should eq(values)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        selected.scan_typed(batch_rows: 1) { |batch| batch.array_array_numeric_values("payload", Int32) }
      end

      table = w64_catalog_table(File.join(parent, "catalog"), part, "Array(Array(Decimal32(2)))")
      materialized = table["payload"].values.map { |value| value.as(Array(Array(Int32))) }
      materialized.should eq(values)
      materialized[1][1][0] = 7_i32
      materialized[1] << ([] of Int32)
      table["payload"].values.map { |value| value.as(Array(Array(Int32))) }.should eq(values)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "exposes nested nullable Decimal256 without collapsing NULL into zero" do
    parent = File.tempname("crystal-click-w64-table-decimal256")
    Dir.mkdir(parent)
    part = File.join(parent, "all_1_3_0")
    keys = [1_u64, 2_u64, 3_u64]
    zero = CrystalClick::Decimal256Value.from_int128(0_i128)
    high = CrystalClick::Decimal256Value.from_int128(123_i128)
    values = [
      [] of Array(CrystalClick::Decimal256Value?),
      [[] of CrystalClick::Decimal256Value?, [nil, zero, high] of CrystalClick::Decimal256Value?],
      [[nil, nil] of CrystalClick::Decimal256Value?],
    ] of Array(Array(CrystalClick::Decimal256Value?))
    begin
      CrystalClick::WidePartWriter.write_uint64_array_array_nullable_decimal256_pair(
        part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", values.to_unsafe.to_slice(values.size), 2, rows_per_mark: 2
      )
      selected = CrystalClick::WidePartTable.open_selected_typed([part], ["payload"])
      observed = [] of Array(Array(CrystalClick::Decimal256Value?))
      selected.scan_typed(batch_rows: 1) { |batch| observed.concat(batch.array_array_nullable_decimal256_raw_for("payload")) }
      observed.should eq(values)

      table = w64_catalog_table(File.join(parent, "catalog"), part, "Array(Array(Nullable(Decimal256(2))))")
      materialized = table["payload"].values.map { |value| value.as(Array(Array(CrystalClick::Decimal256Value?))) }
      materialized.should eq(values)
      materialized[1][1][0] = high
      table["payload"].values.map { |value| value.as(Array(Array(CrystalClick::Decimal256Value?))) }.should eq(values)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects changed selected Decimal stream marks before delivering a batch" do
    parent = File.tempname("crystal-click-w64-table-corruption")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64, 3_u64]
    values = [
      [[1_i32, nil] of Int32?],
      [[nil, 2_i32] of Int32?],
      [[3_i32] of Int32?],
    ] of Array(Array(Int32?))
    begin
      ["payload.size0", "payload.size1", "payload.null", "payload"].each_with_index do |stream, index|
        part = File.join(parent, "all_#{index + 1}_#{index + 1}_0")
        CrystalClick::WidePartWriter.write_uint64_array_array_nullable_decimal32_pair(
          part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", values.to_unsafe.to_slice(values.size), 2, rows_per_mark: 2
        )
        w64_shift_first_mark_rows(part, stream)
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
