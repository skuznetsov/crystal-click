require "./spec_helper"
require "file_utils"
require "./support/projection_checksum_fixture"

W87_DATABASE_UUID = "f87a0000-7b7f-4e2f-9e44-dc13a87b8701"
W87_FIXTURE       = File.expand_path("../test/fixtures/public/wide_two_uint64/part", __DIR__)
W87_PROJECTION    = "by_tag"

private def w87_catalog_root(root : String) : String
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))
  File.write(
    File.join(root, "metadata", "lab.sql"),
    "ATTACH DATABASE _ UUID '#{W87_DATABASE_UUID}'\nENGINE = Atomic\n"
  )
  database_path = File.join(root, "store", W87_DATABASE_UUID[0, 3], W87_DATABASE_UUID)
  FileUtils.mkdir_p(database_path)
  database_path
end

private def w87_write_table(
  root : String,
  database_path : String,
  name : String,
  uuid : String,
  columns : String,
  projection : Bool = true,
  projection_name : String = W87_PROJECTION,
) : String
  projection_ddl = projection ? ",\n    PROJECTION `#{projection_name}` (SELECT left, right ORDER BY left)" : ""
  ddl = <<-DDL
  ATTACH TABLE _ UUID '#{uuid}'
  (
      #{columns}#{projection_ddl}
  )
  ENGINE = MergeTree
  ORDER BY tuple()
  DDL
  File.write(File.join(database_path, "#{name}.sql"), ddl)

  table_path = File.join(root, "store", uuid[0, 3], uuid)
  FileUtils.mkdir_p(table_path)
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  table_path
end

private def w87_add_parent_part(table_path : String, name : String, projection : Bool = true) : String
  part_path = File.join(table_path, name)
  FileUtils.cp_r(W87_FIXTURE, part_path)
  if projection
    FileUtils.cp_r(W87_FIXTURE, File.join(part_path, "#{W87_PROJECTION}.proj"))
    ProjectionChecksumFixture.rebind!(part_path, W87_PROJECTION)
  end
  part_path
end

private def w87_attach_materialized_view(database_path : String) : Nil
  ddl = <<-DDL
  ATTACH MATERIALIZED VIEW _ UUID 'f87a0000-7b7f-4e2f-9e44-dc13a87b8702' TO INNER UUID 'f87a0000-7b7f-4e2f-9e44-dc13a87b8703'
  (
      `left` UInt64,
      `right` UInt64,
      PROJECTION #{W87_PROJECTION} (SELECT left, right ORDER BY left)
  )
  ENGINE = MergeTree
  ORDER BY left
  AS SELECT left, right FROM lab.source
  DDL
  File.write(File.join(database_path, "rollup.sql"), ddl)
end

describe CrystalClick::OfflineTable do
  it "scans a declared projection only when every resolved parent has a child" do
    root = File.tempname("crystal-click-offline-projection-w87-complete")
    database_path = w87_catalog_root(root)
    begin
      table_path = w87_write_table(
        root,
        database_path,
        "events",
        "f87a0000-7b7f-4e2f-9e44-dc13a87b8711",
        "`left` UInt64,\n    `right` UInt64"
      )
      w87_add_parent_part(table_path, "all_1_1_0")
      w87_add_parent_part(table_path, "all_2_2_0")
      table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")

      part_names = Set(String).new
      rows = 0_u64
      table.scan_projection_typed(W87_PROJECTION, ["left", "right"], batch_rows: 1_024) do |batch|
        part_names << batch.part_name
        left = batch.values_for("left")
        right = batch.values_for("right")
        left.size.should eq(right.size)
        left.each_with_index do |value, index|
          right[index].should eq(value * 3_u64 + 7_u64)
        end
        rows += left.size.to_u64
      end

      part_names.should eq(Set{"all_1_1_0", "all_2_2_0"})
      rows.should eq(2_u64 * File.read(File.join(W87_FIXTURE, "count.txt")).strip.to_u64)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "rejects partial projection coverage before exposing any batch" do
    root = File.tempname("crystal-click-offline-projection-w87-partial")
    database_path = w87_catalog_root(root)
    begin
      table_path = w87_write_table(
        root,
        database_path,
        "events",
        "f87a0000-7b7f-4e2f-9e44-dc13a87b8712",
        "`left` UInt64,\n    `right` UInt64"
      )
      w87_add_parent_part(table_path, "all_1_1_0")
      w87_add_parent_part(table_path, "all_2_2_0", projection: false)
      table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")

      callbacks = 0
      expect_raises(CrystalClick::InvalidPartError) do
        table.scan_projection_typed(W87_PROJECTION, ["left"]) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "rejects undeclared projections and does not substitute parent rows" do
    root = File.tempname("crystal-click-offline-projection-w87-unknown")
    database_path = w87_catalog_root(root)
    begin
      table_path = w87_write_table(
        root,
        database_path,
        "events",
        "f87a0000-7b7f-4e2f-9e44-dc13a87b8713",
        "`left` UInt64,\n    `right` UInt64"
      )
      w87_add_parent_part(table_path, "all_1_1_0")
      table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")

      callbacks = 0
      expect_raises(CrystalClick::UnsupportedFormatError) do
        table.scan_projection_typed("not_declared", ["left"]) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "returns no batches for an empty table with a declared projection" do
    root = File.tempname("crystal-click-offline-projection-w87-empty")
    database_path = w87_catalog_root(root)
    begin
      w87_write_table(
        root,
        database_path,
        "events",
        "f87a0000-7b7f-4e2f-9e44-dc13a87b8714",
        "`left` UInt64,\n    `right` UInt64"
      )
      table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")

      callbacks = 0
      table.scan_projection_typed(W87_PROJECTION, ["left"]) { |_batch| callbacks += 1 }
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "rejects unsafe declared projection names even when there are no parent parts" do
    root = File.tempname("crystal-click-offline-projection-w87-empty-unsafe-name")
    database_path = w87_catalog_root(root)
    begin
      w87_write_table(
        root,
        database_path,
        "events",
        "f87a0000-7b7f-4e2f-9e44-dc13a87b8717",
        "`left` UInt64,\n    `right` UInt64",
        projection_name: "by/tag"
      )
      table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")

      callbacks = 0
      expect_raises(CrystalClick::InvalidPartError) do
        table.scan_projection_typed("by/tag", ["left"]) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "rejects unsupported physical child types before the first callback" do
    root = File.tempname("crystal-click-offline-projection-w87-unsupported-type")
    database_path = w87_catalog_root(root)
    begin
      table_path = w87_write_table(
        root,
        database_path,
        "events",
        "f87a0000-7b7f-4e2f-9e44-dc13a87b8718",
        "`left` UInt64,\n    `right` UInt64"
      )
      parent_path = w87_add_parent_part(table_path, "all_1_1_0")
      child_path = File.join(parent_path, "#{W87_PROJECTION}.proj")
      child_columns = File.read(File.join(child_path, "columns.txt")).gsub("`left` UInt64", "`left` UnsupportedType")
      File.write(File.join(child_path, "columns.txt"), child_columns)
      table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")

      callbacks = 0
      expect_raises(CrystalClick::UnsupportedFormatError) do
        table.scan_projection_typed(W87_PROJECTION, ["left"]) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "rejects projection data access on materialized views before callbacks" do
    root = File.tempname("crystal-click-offline-projection-w87-view")
    database_path = w87_catalog_root(root)
    begin
      w87_attach_materialized_view(database_path)
      view = CrystalClick::OfflineCatalog.open(root).table("lab", "rollup")

      callbacks = 0
      expect_raises(CrystalClick::UnsupportedFormatError) do
        view.scan_projection_typed(W87_PROJECTION, ["left"]) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "uses the physical projection child schema rather than the base-table DDL" do
    root = File.tempname("crystal-click-offline-projection-w87-child-schema")
    database_path = w87_catalog_root(root)
    begin
      table_path = w87_write_table(
        root,
        database_path,
        "events",
        "f87a0000-7b7f-4e2f-9e44-dc13a87b8715",
        "`left` String,\n    `right` UInt64"
      )
      w87_add_parent_part(table_path, "all_1_1_0")
      table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")

      rows = 0_u64
      table.scan_projection_typed(W87_PROJECTION, ["left"], batch_rows: 1_024) do |batch|
        batch.column_type_for("left").should eq("UInt64")
        batch.values_for("left").each_with_index do |value, index|
          value.should eq(batch.source_row_offset + index.to_u64)
        end
        rows += batch.values_for("left").size.to_u64
      end
      rows.should eq(File.read(File.join(W87_FIXTURE, "count.txt")).strip.to_u64)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "keeps ordinary parent scans on the parent part path" do
    root = File.tempname("crystal-click-offline-projection-w87-parent-control")
    database_path = w87_catalog_root(root)
    begin
      table_path = w87_write_table(
        root,
        database_path,
        "events",
        "f87a0000-7b7f-4e2f-9e44-dc13a87b8716",
        "`left` UInt64,\n    `right` UInt64",
        projection: false
      )
      w87_add_parent_part(table_path, "all_1_1_0", projection: false)
      table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")

      rows = 0_u64
      table.scan_typed(["left"], batch_rows: 1_024) do |batch|
        batch.part_name.should eq("all_1_1_0")
        batch.values_for("left").each_with_index do |value, index|
          value.should eq(batch.source_row_offset + index.to_u64)
        end
        rows += batch.values_for("left").size.to_u64
      end
      rows.should eq(File.read(File.join(W87_FIXTURE, "count.txt")).strip.to_u64)
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
