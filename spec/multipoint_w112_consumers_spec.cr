require "./spec_helper"
require "file_utils"

private def w112m_slice(values : Array(T)) : Slice(T) forall T
  values.to_unsafe.to_slice(values.size)
end

private def w112m_points : Array(CrystalClick::WidePointValue)
  [
    CrystalClick::WidePointValue.from_bits(0x3ff4_0000_0000_0000_u64, 0xc024_0000_0000_0000_u64),
    CrystalClick::WidePointValue.from_bits(0x8000_0000_0000_0000_u64, 0x7ff8_0000_0000_1234_u64),
    CrystalClick::WidePointValue.from_bits(1_u64, 0x400c_0000_0000_0000_u64),
    CrystalClick::WidePointValue.from_bits(0xfff0_0000_0000_0000_u64, 0x3ff0_0000_0000_0000_u64),
    CrystalClick::WidePointValue.from_bits(0x4002_0000_0000_0000_u64, 0x7ff8_0000_0000_5678_u64),
  ] of CrystalClick::WidePointValue
end

private W112M_KEYS  = [0_u64, 1_u64, 2_u64, 3_u64, 4_u64]
private W112M_SIZES = [[2_u64, 0_u64, 1_u64, 2_u64, 0_u64]]

private def w112m_check_rows(
  rows : Indexable(CrystalClick::WideGeoArrayRow),
  sizes : Array(UInt64),
  points : Array(CrystalClick::WidePointValue),
  first_row : Int32 = 0,
) : Nil
  point_offset = 0
  sizes[0, first_row].each { |size| point_offset += size.to_i }
  rows.each_with_index do |row, local_index|
    record_index = first_row + local_index
    expected_size = sizes[record_index].to_i
    row.type_name.should eq("MultiPoint")
    row.level.should eq(0)
    row.size.should eq(expected_size)
    expected_size.times do |index|
      row.point_at(index).same_bits?(points[point_offset + index]).should be_true
    end
    point_offset += expected_size
  end
end

private def w112m_catalog_root(root : String, part : String, table_name : String, profile_index : Int32) : Nil
  suffix = profile_index.to_s.rjust(12, '0')
  database_uuid = "11200000-0000-4000-8000-#{suffix}"
  table_uuid = "11200000-0001-4000-8000-#{suffix}"
  metadata_path = File.join(root, "metadata")
  database_path = File.join(root, "store", database_uuid[0, 3], database_uuid)
  table_path = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(metadata_path)
  FileUtils.mkdir_p(database_path)
  FileUtils.mkdir_p(table_path)
  File.write(File.join(metadata_path, "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  File.write(
    File.join(database_path, "events.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `pk` UInt64,\n    `payload` #{table_name}\n)\nENGINE = MergeTree\nORDER BY pk\n"
  )
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  FileUtils.cp_r(part, File.join(table_path, "all_1_1_0"))
end

private def w112m_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w112m_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

private def w112m_shift_mark_local_offset(part : String, stream_name : String, mark_index : Int32) : Nil
  mark_path = File.join(part, "#{CrystalClick::StreamName.hash(stream_name)}.mrk2")
  marks = File.read(mark_path).to_slice.dup
  offset = mark_index * CrystalClick::WidePart::MARK_SIZE + 8
  w112m_write_u64(marks, offset, w112m_read_u64(marks, offset) + 24_u64)
  File.write(mark_path, marks)
end

module CrystalClick::WidePartWriter
  # A fresh checksum file makes the negative case identify the selected frame
  # boundary guard rather than checksum mismatch handling.
  def self.w112m_refresh_checksums_for_spec(stage : String, checksums : PartChecksums) : Nil
    records = [] of ChecksumRecord
    checksums.entries.each do |name, entry|
      encoded = File.read(File.join(stage, name)).to_slice
      if entry.compressed
        decoded = CompressedBlock.decode_all(
          encoded,
          PartChecksums::MAX_FRAME_COMPRESSED_BYTES,
          PartChecksums::MAX_FRAME_DECOMPRESSED_BYTES,
          PartChecksums::MAX_PAYLOAD_BYTES
        )
        records << ChecksumRecord.new(
          name, encoded.size.to_u64, CityHashV1.file_hash(encoded), true,
          decoded.size.to_u64, CityHashV1.file_hash(decoded)
        )
      else
        records << ChecksumRecord.new(name, encoded.size.to_u64, CityHashV1.file_hash(encoded), false)
      end
    end
    write_checksums(stage, records)
  end
end

describe "W112 MultiPoint table and catalog consumers" do
  it "preserves nominal identity and raw Point bits through full, selected, and catalog paths" do
    parent = File.tempname("crystal-click-w112-multipoint-consumers")
    Dir.mkdir(parent)
    part = File.join(parent, "all_1_1_0")
    points = w112m_points

    begin
      plan = CrystalClick::GeoArrayColumnType.for_type("MultiPoint").not_nil!
      plan.depth.should eq(1)
      plan.type_name.should eq("MultiPoint")
      CrystalClick::GeoArrayColumnType.for_type("Array(Point)").should be_nil
      CrystalClick::GeoArrayColumnType.for_type("LineString").not_nil!.type_name.should eq("LineString")
      CrystalClick::GeoArrayColumnType.for_type("Ring").not_nil!.type_name.should eq("Ring")

      CrystalClick::WidePartWriter.write_uint64_geo_array_pair(
        part,
        "pk",
        w112m_slice(W112M_KEYS),
        "payload",
        "MultiPoint",
        W112M_SIZES,
        points,
        rows_per_mark: 2
      ).should eq(part)

      reader = CrystalClick::WidePart.open_typed(part, "payload")
      reader.column_type.should eq("MultiPoint")
      reader.read_geo_array_mark_range("payload", 0, reader.mark_count).type_name.should eq("MultiPoint")

      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      table.column_types.should eq([{"pk", "UInt64"}, {"payload", "MultiPoint"}])
      full_rows = [] of CrystalClick::WideGeoArrayRow
      table.scan_typed(batch_rows: 2) do |batch|
        batch.column_type_for("payload").should eq("MultiPoint")
        rows = batch.geo_array_rows_for("payload")
        w112m_check_rows(rows, W112M_SIZES[0], points, full_rows.size.to_i32)
        rows.each { |row| full_rows << row }
        nil
      end
      full_rows.size.should eq(W112M_KEYS.size)

      window_rows = [] of CrystalClick::WideGeoArrayRow
      table.scan_typed_window(1_u64, 3) do |batch|
        rows = batch.geo_array_rows_for("payload")
        w112m_check_rows(rows, W112M_SIZES[0], points, 1 + window_rows.size.to_i32)
        rows.each { |row| window_rows << row }
        nil
      end
      window_rows.map(&.size).should eq([0, 1, 2])

      data_mark_count = table.part_mark_row_counts[0].size
      pk_index = CrystalClick::PrimaryKeyIndex.open(
        part,
        data_mark_count,
        CrystalClick::PartChecksums.open(part),
        verify_recorded_hash: true
      )
      candidate_marks = pk_index.candidate_marks(3_u64, 3_u64)
      candidate_marks.should eq([1_i32])
      candidate_rows = [] of CrystalClick::WideGeoArrayRow
      candidate_pks = [] of UInt64
      table.scan_typed_candidate_marks([candidate_marks]) do |batch|
        batch.values_for("pk").each { |value| candidate_pks << value }
        rows = batch.geo_array_rows_for("payload")
        w112m_check_rows(rows, W112M_SIZES[0], points, 2)
        rows.each { |row| candidate_rows << row }
        nil
      end
      candidate_pks.should eq([2_u64, 3_u64])
      candidate_rows.size.should eq(2)

      catalog_root = File.join(parent, "catalog")
      w112m_catalog_root(catalog_root, part, "MultiPoint", 1)
      offline = CrystalClick::OfflineCatalog.open(catalog_root).table("lab", "events")
      offline.columns.find { |column| column.name == "payload" }.not_nil!.type.should eq("MultiPoint")
      values = offline["payload"].values(max_rows: 16_u64, max_string_bytes: 1024_u64, max_tuple_cells: 256_u64)
      catalog_rows = values.map(&.as(CrystalClick::WideGeoArrayRow))
      catalog_rows.size.should eq(W112M_KEYS.size)
      w112m_check_rows(catalog_rows, W112M_SIZES[0], points)

      catalog_window = [] of CrystalClick::WideGeoArrayRow
      offline.scan_typed_window(["pk", "payload"], 1_u64, 3) do |batch|
        rows = batch.geo_array_rows_for("payload")
        w112m_check_rows(rows, W112M_SIZES[0], points, 1 + catalog_window.size.to_i32)
        rows.each { |row| catalog_window << row }
        nil
      end
      catalog_window.map(&.size).should eq([0, 1, 2])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "keeps all-empty MultiPoint rows addressable through the typed table and catalog" do
    parent = File.tempname("crystal-click-w112-multipoint-empty")
    Dir.mkdir(parent)
    part = File.join(parent, "all_1_1_0")
    keys = [0_u64, 1_u64, 2_u64]
    empty_points = [] of CrystalClick::WidePointValue

    begin
      CrystalClick::WidePartWriter.write_uint64_geo_array_pair(
        part,
        "pk",
        w112m_slice(keys),
        "payload",
        "MultiPoint",
        [[0_u64, 0_u64, 0_u64]],
        empty_points,
        rows_per_mark: 2
      )
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      table_rows = [] of CrystalClick::WideGeoArrayRow
      table.scan_typed(batch_rows: 2) do |batch|
        batch.geo_array_rows_for("payload").each do |row|
          row.type_name.should eq("MultiPoint")
          row.size.should eq(0)
          table_rows << row
        end
        nil
      end
      table_rows.size.should eq(keys.size)

      catalog_root = File.join(parent, "catalog")
      w112m_catalog_root(catalog_root, part, "MultiPoint", 2)
      offline = CrystalClick::OfflineCatalog.open(catalog_root).table("lab", "events")
      catalog_rows = offline["payload"].values(max_rows: 8_u64, max_string_bytes: 128_u64, max_tuple_cells: 16_u64)
        .map(&.as(CrystalClick::WideGeoArrayRow))
      catalog_rows.size.should eq(keys.size)
      catalog_rows.each do |row|
        row.type_name.should eq("MultiPoint")
        row.size.should eq(0)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "preflights checksum-valid selected mark corruption before callbacks but not an earlier-only window" do
    parent = File.tempname("crystal-click-w112-multipoint-hostile")
    Dir.mkdir(parent)
    part = File.join(parent, "all_1_1_0")
    keys = [0_u64, 1_u64, 2_u64, 3_u64, 4_u64]
    sizes = [[1_u64, 1_u64, 1_u64, 1_u64, 1_u64]]
    points = Array(CrystalClick::WidePointValue).new(5) do |index|
      CrystalClick::WidePointValue.new(index.to_f64, (index + 20).to_f64)
    end

    begin
      CrystalClick::WidePartWriter.write_uint64_geo_array_pair(
        part,
        "pk",
        w112m_slice(keys),
        "payload",
        "MultiPoint",
        sizes,
        points,
        rows_per_mark: 2
      )
      checksums = CrystalClick::PartChecksums.open(part)
      w112m_shift_mark_local_offset(part, "payload%2E2", 2)
      CrystalClick::WidePartWriter.w112m_refresh_checksums_for_spec(part, checksums)

      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError, "mark offset exceeds frame output") do
        table.scan_typed(batch_rows: 2) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)

      callbacks = 0
      table.scan_typed_window(0_u64, 2) { |_batch| callbacks += 1 }
      callbacks.should eq(1)

      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError, "mark offset exceeds frame output") do
        table.scan_typed_window(0_u64, 5) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
