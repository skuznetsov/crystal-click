require "./spec_helper"
require "file_utils"
require "./support/projection_checksum_fixture"

W288_PROJECTION_NAME = "by_compact_values"
W288_PARENT_FIXTURE  = File.expand_path("../test/fixtures/public/wide_two_uint64/part", __DIR__)

private def w288_uint64_column(
  name : String,
  values : Array(UInt64),
  rows_per_mark : Int32,
) : CrystalClick::CompactPartColumn
  type = CrystalClick::BinaryDataType.primitive("UInt64")
  granules = [] of Array(CrystalClick::BinaryValue)
  values.each_slice(rows_per_mark) do |slice|
    granules << slice.map { |value| CrystalClick::BinaryValue.uint64(value) }
  end
  CrystalClick::CompactPartColumn.binary_bulk(name, type, granules)
end

private def w288_write_compact_child(
  parent_path : String,
  bucket_values : Array(UInt64),
  n_values : Array(UInt64),
  rows_per_mark : Int32,
) : String
  child_path = File.join(parent_path, "#{W288_PROJECTION_NAME}.proj")
  keys = bucket_values.map_with_index { |value, index| 901_u64 + index.to_u64 }
  columns = [
    w288_uint64_column("bucket", bucket_values, rows_per_mark),
    w288_uint64_column("n", n_values, rows_per_mark),
  ] of CrystalClick::CompactPartColumn
  CrystalClick::CompactPartWriter.write_uint64_columns(
    child_path,
    "pk",
    keys.to_unsafe.to_slice(keys.size),
    columns,
    rows_per_mark: rows_per_mark,
    frame_bytes: 32,
    mark_format: CrystalClick::CompactMarkFormat::Mrk4,
  )
  ProjectionChecksumFixture.rebind!(parent_path, W288_PROJECTION_NAME)
  child_path
end

private def w288_write_wide_child(
  parent_path : String,
  bucket_values : Array(UInt64),
  n_values : Array(UInt64),
  rows_per_mark : Int32,
) : String
  child_path = File.join(parent_path, "#{W288_PROJECTION_NAME}.proj")
  CrystalClick::WidePartWriter.write_uint64_pair(
    child_path,
    "bucket",
    bucket_values.to_unsafe.to_slice(bucket_values.size),
    "n",
    n_values.to_unsafe.to_slice(n_values.size),
    rows_per_mark: rows_per_mark,
  )
  ProjectionChecksumFixture.rebind!(parent_path, W288_PROJECTION_NAME)
  child_path
end

private def w288_wide_parent(root : String, name : String) : String
  parent_path = File.join(root, name)
  FileUtils.cp_r(W288_PARENT_FIXTURE, parent_path)
  parent_path
end

private def w288_compact_parent(root : String, name : String) : String
  parent_path = File.join(root, name)
  keys = [1_u64, 2_u64]
  columns = [
    w288_uint64_column("bucket", [51_u64, 52_u64], 1),
    w288_uint64_column("n", [601_u64, 602_u64], 1),
  ] of CrystalClick::CompactPartColumn
  CrystalClick::CompactPartWriter.write_uint64_columns(
    parent_path,
    "pk",
    keys.to_unsafe.to_slice(keys.size),
    columns,
    rows_per_mark: 1,
    frame_bytes: 32,
  )
  parent_path
end

private def w288_offline_table(parts : Array({String, String})) : CrystalClick::OfflineTable
  candidates = parts.map do |name, path|
    info = CrystalClick::MergeTreePartInfo.parse(name).not_nil!
    CrystalClick::OfflinePartCandidate.new(name, path, info, 17_001_u64)
  end
  CrystalClick::OfflineTable.new(
    "events",
    "28800000-0000-4000-8000-000000000001",
    "MergeTree",
    [
      CrystalClick::OfflineColumn.new("bucket", "UInt64"),
      CrystalClick::OfflineColumn.new("n", "UInt64"),
    ] of CrystalClick::OfflineColumn,
    candidates,
    primary_key_column: "bucket",
    projections: [
      CrystalClick::OfflineProjection.new(
        W288_PROJECTION_NAME,
        "SELECT bucket, n ORDER BY bucket",
      ),
    ] of CrystalClick::OfflineProjection,
  )
end

private def w288_root(name : String) : String
  root = File.tempname("crystal-click-#{name}")
  FileUtils.mkdir_p(root)
  root
end

private def w288_corrupt_child_manifest!(child_path : String) : Nil
  records = [] of CrystalClick::PartWriterInfrastructure::ChecksumRecord
  changed = false
  CrystalClick::PartChecksums.open(child_path).entries.each do |name, entry|
    file_hash = entry.file_hash
    if !changed
      file_hash = {file_hash[0] ^ 1_u64, file_hash[1]}
      changed = true
    end
    records << CrystalClick::PartWriterInfrastructure::ChecksumRecord.new(
      name,
      entry.physical_size,
      file_hash,
      entry.compressed,
      entry.uncompressed_size,
      entry.uncompressed_hash,
    )
  end
  raise "child manifest had no entries" unless changed
  CrystalClick::PartWriterInfrastructure::PartChecksumsWriter.write(child_path, records)
end

private def w288_add_manifest_only_mark_hint!(child_path : String) : Nil
  records = [] of CrystalClick::PartWriterInfrastructure::ChecksumRecord
  CrystalClick::PartChecksums.open(child_path).entries.each do |name, entry|
    records << CrystalClick::PartWriterInfrastructure::ChecksumRecord.new(
      name,
      entry.physical_size,
      entry.file_hash,
      entry.compressed,
      entry.uncompressed_size,
      entry.uncompressed_hash,
    )
  end
  records << CrystalClick::PartWriterInfrastructure::ChecksumRecord.new(
    "data.mrk4",
    0_u64,
    {0_u64, 0_u64},
    false,
  )
  CrystalClick::PartWriterInfrastructure::PartChecksumsWriter.write(child_path, records)
  ProjectionChecksumFixture.rebind!(File.dirname(child_path), W288_PROJECTION_NAME)
end

describe "Compact projection child reader" do
  it "reads a selected Compact MRK4 child through the existing offline full-scan API" do
    root = w288_root("compact-projection-red")
    parent_path = w288_wide_parent(root, "all_1_1_0")
    begin
      child_path = w288_write_compact_child(parent_path, [7_u64, 11_u64, 19_u64], [101_u64, 202_u64, 303_u64], 2)
      table = w288_offline_table([{"all_1_1_0", parent_path}])

      rows = [] of {Int32, String, String, Int32, UInt64, UInt64, UInt64, Array(UInt64), Array(UInt64)}
      table.scan_projection_typed(
        W288_PROJECTION_NAME,
        ["bucket", "n"],
        batch_rows: 2,
      ) do |batch|
        rows << {
          batch.part_index,
          batch.part_name,
          batch.part_path,
          batch.mark_index,
          batch.mark_row_offset,
          batch.part_row_offset,
          batch.source_row_offset,
          batch.values_for("bucket", UInt64).to_a,
          batch.values_for("n", UInt64).to_a,
        }
      end

      rows.should eq([
        {0_i32, "all_1_1_0", parent_path, 0_i32, 0_u64, 0_u64, 0_u64, [7_u64, 11_u64], [101_u64, 202_u64]},
        {0_i32, "all_1_1_0", parent_path, 1_i32, 0_u64, 2_u64, 2_u64, [19_u64], [303_u64]},
      ])
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "composes Compact and Wide children over Wide and Compact parents with child coordinates" do
    root = w288_root("compact-projection-mixed")
    wide_parent_compact_child = w288_wide_parent(root, "all_1_1_0")
    compact_parent_wide_child = w288_compact_parent(root, "all_2_2_0")
    begin
      w288_write_compact_child(wide_parent_compact_child, [7_u64, 11_u64, 19_u64], [101_u64, 202_u64, 303_u64], 2)
      w288_write_wide_child(compact_parent_wide_child, [31_u64, 37_u64], [401_u64, 503_u64], 1)
      table = w288_offline_table([
        {"all_1_1_0", wide_parent_compact_child},
        {"all_2_2_0", compact_parent_wide_child},
      ])

      full = [] of {Int32, String, String, Int32, UInt64, UInt64, UInt64, Array(UInt64), Array(UInt64)}
      table.scan_projection_typed(W288_PROJECTION_NAME, ["bucket", "n"], batch_rows: 2) do |batch|
        full << {
          batch.part_index,
          batch.part_name,
          batch.part_path,
          batch.mark_index,
          batch.mark_row_offset,
          batch.part_row_offset,
          batch.source_row_offset,
          batch.values_for("bucket", UInt64).to_a,
          batch.values_for("n", UInt64).to_a,
        }
      end
      full.should eq([
        {0_i32, "all_1_1_0", wide_parent_compact_child, 0_i32, 0_u64, 0_u64, 0_u64, [7_u64, 11_u64], [101_u64, 202_u64]},
        {0_i32, "all_1_1_0", wide_parent_compact_child, 1_i32, 0_u64, 2_u64, 2_u64, [19_u64], [303_u64]},
        {1_i32, "all_2_2_0", compact_parent_wide_child, 0_i32, 0_u64, 0_u64, 3_u64, [31_u64], [401_u64]},
        {1_i32, "all_2_2_0", compact_parent_wide_child, 1_i32, 0_u64, 1_u64, 4_u64, [37_u64], [503_u64]},
      ])

      cropped = [] of {Int32, String, String, Int32, UInt64, UInt64, UInt64, Array(UInt64)}
      table.scan_projection_typed_window(W288_PROJECTION_NAME, ["bucket"], 1_u64, 3) do |batch|
        cropped << {
          batch.part_index,
          batch.part_name,
          batch.part_path,
          batch.mark_index,
          batch.mark_row_offset,
          batch.part_row_offset,
          batch.source_row_offset,
          batch.values_for("bucket", UInt64).to_a,
        }
      end
      cropped.should eq([
        {0_i32, "all_1_1_0", wide_parent_compact_child, 0_i32, 1_u64, 1_u64, 1_u64, [11_u64]},
        {0_i32, "all_1_1_0", wide_parent_compact_child, 1_i32, 0_u64, 2_u64, 2_u64, [19_u64]},
        {1_i32, "all_2_2_0", compact_parent_wide_child, 0_i32, 0_u64, 0_u64, 3_u64, [31_u64]},
      ])

      crossing = [] of {Int32, String, Int32, UInt64, UInt64, UInt64, Array(UInt64)}
      table.scan_projection_typed_window(W288_PROJECTION_NAME, ["bucket"], 2_u64, 2) do |batch|
        crossing << {
          batch.part_index,
          batch.part_name,
          batch.mark_index,
          batch.mark_row_offset,
          batch.part_row_offset,
          batch.source_row_offset,
          batch.values_for("bucket", UInt64).to_a,
        }
      end
      crossing.should eq([
        {0_i32, "all_1_1_0", 1_i32, 0_u64, 2_u64, 2_u64, [19_u64]},
        {1_i32, "all_2_2_0", 0_i32, 0_u64, 0_u64, 3_u64, [31_u64]},
      ])

      eof_callbacks = 0
      table.scan_projection_typed_window(W288_PROJECTION_NAME, ["bucket"], 5_u64, 1) do |_batch|
        eof_callbacks += 1
      end
      eof_callbacks.should eq(0)
      expect_raises(CrystalClick::BoundsError) do
        table.scan_projection_typed_window(W288_PROJECTION_NAME, ["bucket"], 6_u64, 1) { |_batch| }
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "keeps the all-Wide projection route and parent identity" do
    root = w288_root("wide-projection-control")
    parent_path = w288_wide_parent(root, "all_1_1_0")
    begin
      w288_write_wide_child(parent_path, [41_u64, 43_u64], [701_u64, 703_u64], 2)
      table = w288_offline_table([{"all_1_1_0", parent_path}])
      observed = [] of {String, String, Array(UInt64), Array(UInt64)}
      table.scan_projection_typed(W288_PROJECTION_NAME, ["bucket", "n"]) do |batch|
        observed << {
          batch.part_name,
          batch.part_path,
          batch.values_for("bucket", UInt64).to_a,
          batch.values_for("n", UInt64).to_a,
        }
      end
      observed.should eq([{"all_1_1_0", parent_path, [41_u64, 43_u64], [701_u64, 703_u64]}])
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "preflights a late Compact child binding mismatch before full and window callbacks" do
    root = w288_root("projection-late-mismatch")
    parent_a = w288_wide_parent(root, "all_1_1_0")
    parent_b = w288_wide_parent(root, "all_2_2_0")
    begin
      w288_write_wide_child(parent_a, [7_u64], [101_u64], 1)
      child_b = w288_write_compact_child(parent_b, [31_u64], [401_u64], 1)
      w288_corrupt_child_manifest!(child_b)
      table = w288_offline_table([{"all_1_1_0", parent_a}, {"all_2_2_0", parent_b}])

      expect_raises(CrystalClick::CorruptPartError, /does not match parent manifest/) do
        CrystalClick::CompactPartTable.open_selected_projection_child_typed(parent_b, W288_PROJECTION_NAME, ["bucket"])
      end

      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError, /does not match parent manifest/) do
        table.scan_projection_typed(W288_PROJECTION_NAME, ["bucket"]) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)

      [0_u64, 2_u64].each do |start_row|
        expect_raises(CrystalClick::CorruptPartError, /does not match parent manifest/) do
          table.scan_projection_typed_window(W288_PROJECTION_NAME, ["bucket"], start_row, 1) { |_batch| callbacks += 1 }
        end
        callbacks.should eq(0)
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "rejects unsupported Compact marks and missing or symbolic child paths before callbacks" do
    root = w288_root("projection-child-guards")
    parent_a = w288_wide_parent(root, "all_1_1_0")
    parent_b = w288_wide_parent(root, "all_2_2_0")
    parent_c = w288_wide_parent(root, "all_3_3_0")
    parent_d = w288_wide_parent(root, "all_4_4_0")
    external_child = File.join(root, "external.proj")
    begin
      child_a = w288_write_compact_child(parent_a, [7_u64], [101_u64], 1)
      File.write(File.join(child_a, "data.mrk5"), "unsupported")
      table_a = w288_offline_table([{"all_1_1_0", parent_a}])
      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table_a.scan_projection_typed(W288_PROJECTION_NAME, ["bucket"]) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)

      missing_child = w288_write_wide_child(parent_b, [31_u64], [401_u64], 1)
      FileUtils.cp_r(missing_child, external_child)
      FileUtils.rm_rf(missing_child)
      table_b = w288_offline_table([{"all_2_2_0", parent_b}])
      callbacks = 0
      expect_raises(CrystalClick::InvalidPartError) do
        table_b.scan_projection_typed(W288_PROJECTION_NAME, ["bucket"]) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)

      File.symlink(external_child, File.join(parent_c, "#{W288_PROJECTION_NAME}.proj"))
      table_c = w288_offline_table([{"all_3_3_0", parent_c}])
      callbacks = 0
      expect_raises(CrystalClick::InvalidPartError) do
        table_c.scan_projection_typed(W288_PROJECTION_NAME, ["bucket"]) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)

      manifest_only_child = w288_write_wide_child(parent_d, [47_u64], [709_u64], 1)
      w288_add_manifest_only_mark_hint!(manifest_only_child)
      table_d = w288_offline_table([{"all_4_4_0", parent_d}])
      callbacks = 0
      expect_raises(CrystalClick::Error) do
        table_d.scan_projection_typed(W288_PROJECTION_NAME, ["bucket"]) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
