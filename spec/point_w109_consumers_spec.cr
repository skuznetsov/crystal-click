require "./spec_helper"
require "file_utils"

private def w109c_write_part(
  parent : String,
  values : Array(CrystalClick::WidePointValue),
  rows_per_mark : Int32,
) : String
  destination = File.join(parent, "all_1_1_0")
  keys = Array(UInt64).new(values.size) { |index| (index + 10).to_u64 }
  CrystalClick::WidePartWriter.write_uint64_point_pair(
    destination,
    "a",
    keys.to_unsafe.to_slice(keys.size),
    "z",
    values.to_unsafe.to_slice(values.size),
    rows_per_mark: rows_per_mark
  )
end

private def w109c_offline_root(parent : String, part : String) : String
  root = File.join(parent, "catalog")
  metadata = File.join(root, "metadata")
  database_uuid = "10900000-0000-4000-8000-000000000001"
  table_uuid = "10900000-0000-4000-8000-000000000002"
  database = File.join(root, "store", database_uuid[0, 3], database_uuid)
  table = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(metadata)
  FileUtils.mkdir_p(database)
  FileUtils.mkdir_p(table)
  File.write(File.join(metadata, "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  File.write(
    File.join(database, "events.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `a` UInt64,\n    `z` Point\n)\nENGINE = MergeTree\nORDER BY a\n"
  )
  File.write(File.join(table, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table, "detached"))
  FileUtils.cp_r(part, File.join(table, "all_1_1_0"))
  root
end

private def w109c_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

private def w109c_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w109c_shift_mark_boundary(part : String, stream_name : String, mark_index : Int32) : Nil
  mark_path = File.join(part, "#{CrystalClick::StreamName.hash(stream_name)}.mrk2")
  marks = File.read(mark_path).to_slice.dup
  offset = mark_index * CrystalClick::WidePart::MARK_SIZE + 8
  w109c_write_u64(marks, offset, w109c_u64(marks, offset) + 8_u64)
  File.write(mark_path, marks)
end

describe "W109 Point table and catalog consumers" do
  it "preserves raw Point values through full, window, batch, and OfflineColumnSelection APIs" do
    parent = File.tempname("crystal-click-point-w109-consumers")
    Dir.mkdir(parent)
    values = [
      CrystalClick::WidePointValue.from_bits(0x8000_0000_0000_0000_u64, 0_u64),
      CrystalClick::WidePointValue.from_bits(0x7ff8_0000_0000_0042_u64, 0xfff0_0000_0000_0000_u64),
      CrystalClick::WidePointValue.new(1.25, -3.5),
      CrystalClick::WidePointValue.new(-0.125, 4096.0),
      CrystalClick::WidePointValue.new(42.0, -0.0),
    ]

    begin
      part = w109c_write_part(parent, values, 2)
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["a", "z"])
      table.column_types.should eq([{"a", "UInt64"}, {"z", "Point"}])
      full = [] of CrystalClick::WidePointValue
      table.scan_typed(batch_rows: 2) do |batch|
        batch.point_values_for("z").each { |value| full << value }
        nil
      end
      full.size.should eq(values.size)

      window = [] of CrystalClick::WidePointValue
      table.scan_typed_window(1_u64, 3) do |batch|
        batch.point_values_for("z").each { |value| window << value }
        nil
      end
      window.size.should eq(3)
      window.zip(values[1, 3]).each { |actual, expected| actual.same_bits?(expected).should be_true }
      # Later scans reuse callback-local batch storage; retained value objects
      # collected above must remain independent of those buffers.
      full.zip(values).each { |actual, expected| actual.same_bits?(expected).should be_true }

      catalog_root = w109c_offline_root(parent, part)
      offline = CrystalClick::OfflineCatalog.open(catalog_root)["lab"]["events"]
      values_api = offline["z"].values.map(&.as(CrystalClick::WidePointValue))
      values_api.size.should eq(values.size)
      values_api.zip(values).each { |actual, expected| actual.same_bits?(expected).should be_true }

      catalog_scan = [] of CrystalClick::WidePointValue
      offline.scan_typed(["a", "z"], batch_rows: 2) do |batch|
        batch.point_values_for("z").each { |value| catalog_scan << value }
        nil
      end
      catalog_scan.size.should eq(values.size)
      catalog_scan.zip(values).each { |actual, expected| actual.same_bits?(expected).should be_true }

      catalog_window = [] of CrystalClick::WidePointValue
      offline.scan_typed_window(["a", "z"], 1_u64, 3) do |batch|
        batch.point_values_for("z").each { |value| catalog_window << value }
        nil
      end
      catalog_window.size.should eq(3)
      catalog_window.zip(values[1, 3]).each { |actual, expected| actual.same_bits?(expected).should be_true }
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a later selected coordinate boundary before table or catalog callbacks" do
    parent = File.tempname("crystal-click-point-w109-boundary")
    Dir.mkdir(parent)
    values = [
      CrystalClick::WidePointValue.new(1.0, 2.0),
      CrystalClick::WidePointValue.new(3.0, 4.0),
      CrystalClick::WidePointValue.new(5.0, 6.0),
    ]

    begin
      part = w109c_write_part(parent, values, 1)
      w109c_shift_mark_boundary(part, "z%2E2", 2)

      table = CrystalClick::WidePartTable.open_selected_typed([part], ["a", "z"])
      table_window = [] of CrystalClick::WidePointValue
      table.scan_typed_window(0_u64, 1) do |batch|
        batch.point_values_for("z").each { |value| table_window << value }
        nil
      end
      table_window.size.should eq(1)
      table_window.first.same_bits?(values.first).should be_true

      table_callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table.scan_typed(batch_rows: 1) do |_batch|
          table_callbacks += 1
          nil
        end
      end
      table_callbacks.should eq(0)

      catalog_root = w109c_offline_root(parent, part)
      offline = CrystalClick::OfflineCatalog.open(catalog_root)["lab"]["events"]
      catalog_window = [] of CrystalClick::WidePointValue
      offline.scan_typed_window(["a", "z"], 0_u64, 1) do |batch|
        batch.point_values_for("z").each { |value| catalog_window << value }
        nil
      end
      catalog_window.size.should eq(1)
      catalog_window.first.same_bits?(values.first).should be_true

      catalog_callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        offline.scan_typed(["a", "z"], batch_rows: 1) do |_batch|
          catalog_callbacks += 1
          nil
        end
      end
      catalog_callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
