require "./spec_helper"
require "file_utils"
require "./support/projection_checksum_fixture"

W229_DATABASE_UUID  = "22900000-0000-4000-8000-000000000001"
W229_PARENT_FIXTURE = File.expand_path("../test/fixtures/public/wide_two_uint64/part", __DIR__)
W229_PROJECTION     = "by_bucket"

private def w229_catalog_root(root : String) : String
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))
  File.write(
    File.join(root, "metadata", "lab.sql"),
    "ATTACH DATABASE _ UUID '#{W229_DATABASE_UUID}'\nENGINE = Atomic\n"
  )
  database_path = File.join(root, "store", W229_DATABASE_UUID[0, 3], W229_DATABASE_UUID)
  FileUtils.mkdir_p(database_path)
  database_path
end

private def w229_uuid(index : Int32) : String
  "22900000-0000-4000-8000-#{index.to_s(16).rjust(12, '0')}"
end

private def w229_write_table(
  root : String,
  database_path : String,
  name : String,
  uuid : String,
  engine : String = "MergeTree",
  projection_name : String? = W229_PROJECTION,
) : String
  projection_clause = ""
  if selected_name = projection_name
    quote = 96.chr
    projection_clause = ",\n    PROJECTION #{quote}#{selected_name}#{quote} (SELECT #{quote}right#{quote} % 2 AS bucket, count() AS n GROUP BY bucket ORDER BY bucket)"
  end

  quote = 96.chr
  ddl = "ATTACH TABLE _ UUID '#{uuid}'\n(\n    #{quote}left#{quote} UInt64,\n    #{quote}right#{quote} UInt64#{projection_clause}\n)\nENGINE = #{engine}\nORDER BY tuple()\n"
  File.write(File.join(database_path, "#{name}.sql"), ddl)

  table_path = File.join(root, "store", uuid[0, 3], uuid)
  FileUtils.mkdir_p(table_path)
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  table_path
end

private def w229_write_projection_child(parent_path : String, rows_per_mark : Int32) : String
  child_path = File.join(parent_path, "#{W229_PROJECTION}.proj")
  buckets = [0_u64, 1_u64]
  counts = [8_500_u64, 8_501_u64]
  CrystalClick::WidePartWriter.write_uint64_pair(
    child_path,
    "bucket",
    buckets.to_unsafe.to_slice(buckets.size),
    "n",
    counts.to_unsafe.to_slice(counts.size),
    rows_per_mark: rows_per_mark
  )
  ProjectionChecksumFixture.rebind!(parent_path, W229_PROJECTION)
  child_path
end

private def w229_add_parent_part(
  table_path : String,
  name : String,
  child_rows_per_mark : Int32? = nil,
) : String
  parent_path = File.join(table_path, name)
  FileUtils.cp_r(W229_PARENT_FIXTURE, parent_path)
  if rows_per_mark = child_rows_per_mark
    w229_write_projection_child(parent_path, rows_per_mark)
  end
  parent_path
end

private def w229_attach_view(database_path : String) : Nil
  quote = 96.chr
  ddl = <<-DDL
  ATTACH MATERIALIZED VIEW _ UUID '#{w229_uuid(90)}' TO INNER UUID '#{w229_uuid(91)}'
  (
      #{quote}left#{quote} UInt64,
      #{quote}right#{quote} UInt64,
      PROJECTION by_bucket (SELECT #{quote}right#{quote} % 2 AS bucket, count() AS n GROUP BY bucket ORDER BY bucket)
  )
  ENGINE = MergeTree
  ORDER BY #{quote}left#{quote}
  AS SELECT #{quote}left#{quote}, #{quote}right#{quote} FROM lab.events
  DDL
  File.write(File.join(database_path, "rollup.sql"), ddl)
end

describe "W229 offline projection typed row windows" do
  it "uses child rows, marks, and parent identity across middle and cross-child windows" do
    root = File.tempname("crystal-click-offline-projection-window-w229-read")
    database_path = w229_catalog_root(root)
    begin
      table_path = w229_write_table(root, database_path, "events", w229_uuid(10))
      parent_a = w229_add_parent_part(table_path, "all_1_1_0", child_rows_per_mark: 1)
      parent_b = w229_add_parent_part(table_path, "all_2_2_0", child_rows_per_mark: 2)
      table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")

      table.responds_to?(:scan_projection_typed_window).should be_true
      if table.responds_to?(:scan_projection_typed_window)
        # The parent fixture has 17,001 rows per part. Each grouped child has
        # only two rows, with independent child mark grids [1, 1] and [2].
        full_batches = [] of {Int32, String, String, Int32, UInt64, UInt64, UInt64, Array(UInt64), Array(UInt64)}
        table.scan_projection_typed_window(W229_PROJECTION, ["bucket", "n"], 0_u64, 4) do |batch|
          batch.column_type_for("bucket").should eq("UInt64")
          batch.column_type_for("n").should eq("UInt64")
          full_batches << {
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
        full_batches.should eq([
          {0_i32, "all_1_1_0", parent_a, 0_i32, 0_u64, 0_u64, 0_u64, [0_u64], [8_500_u64]},
          {0_i32, "all_1_1_0", parent_a, 1_i32, 0_u64, 1_u64, 1_u64, [1_u64], [8_501_u64]},
          {1_i32, "all_2_2_0", parent_b, 0_i32, 0_u64, 0_u64, 2_u64, [0_u64, 1_u64], [8_500_u64, 8_501_u64]},
        ])

        middle = [] of {String, Int32, UInt64, UInt64, UInt64, Array(UInt64)}
        table.scan_projection_typed_window(W229_PROJECTION, ["bucket"], 1_u64, 1) do |batch|
          middle << {
            batch.part_name,
            batch.mark_index,
            batch.mark_row_offset,
            batch.part_row_offset,
            batch.source_row_offset,
            batch.values_for("bucket", UInt64).to_a,
          }
        end
        middle.should eq([{"all_1_1_0", 1_i32, 0_u64, 1_u64, 1_u64, [1_u64]}])

        intra_child_mark = [] of {Int32, String, String, Int32, UInt64, UInt64, UInt64, Array(UInt64)}
        table.scan_projection_typed_window(W229_PROJECTION, ["bucket"], 3_u64, 1) do |batch|
          intra_child_mark << {
            batch.part_index,
            batch.part_name,
            batch.part_path,
            batch.mark_index,
            batch.mark_row_offset,
            batch.part_row_offset,
            batch.source_row_offset,
            # Copy borrowed batch data before the callback returns.
            batch.values_for("bucket", UInt64).to_a,
          }
        end
        intra_child_mark.should eq([
          {1_i32, "all_2_2_0", parent_b, 0_i32, 1_u64, 1_u64, 3_u64, [1_u64]},
        ])

        crossing = [] of {Int32, String, Int32, UInt64, UInt64, UInt64, Array(UInt64)}
        table.scan_projection_typed_window(W229_PROJECTION, ["bucket"], 1_u64, 3) do |batch|
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
          {0_i32, "all_1_1_0", 1_i32, 0_u64, 1_u64, 1_u64, [1_u64]},
          {1_i32, "all_2_2_0", 0_i32, 0_u64, 0_u64, 2_u64, [0_u64, 1_u64]},
        ])
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "returns exact EOF, rejects past EOF and invalid selections or row limits before callbacks" do
    root = File.tempname("crystal-click-offline-projection-window-w229-bounds")
    database_path = w229_catalog_root(root)
    begin
      table_path = w229_write_table(root, database_path, "events", w229_uuid(11))
      w229_add_parent_part(table_path, "all_1_1_0", child_rows_per_mark: 1)
      w229_add_parent_part(table_path, "all_2_2_0", child_rows_per_mark: 2)
      table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")

      table.responds_to?(:scan_projection_typed_window).should be_true
      if table.responds_to?(:scan_projection_typed_window)
        callbacks = 0
        table.scan_projection_typed_window(W229_PROJECTION, ["bucket"], 4_u64, 1) do |_batch|
          callbacks += 1
        end
        callbacks.should eq(0)

        expect_raises(CrystalClick::BoundsError) do
          table.scan_projection_typed_window(W229_PROJECTION, ["bucket"], 5_u64, 1) { |_batch| callbacks += 1 }
        end
        expect_raises(CrystalClick::BoundsError) do
          table.scan_projection_typed_window(W229_PROJECTION, ["bucket"], 0_u64, 0) { |_batch| callbacks += 1 }
        end
        expect_raises(CrystalClick::BoundsError) do
          table.scan_projection_typed_window(W229_PROJECTION, ["bucket"], 0_u64, -1) { |_batch| callbacks += 1 }
        end
        expect_raises(CrystalClick::BoundsError) do
          table.scan_projection_typed_window(
            W229_PROJECTION,
            ["bucket"],
            0_u64,
            CrystalClick::WidePartTable::MAX_BATCH_ROWS + 1
          ) { |_batch| callbacks += 1 }
        end
        expect_raises(CrystalClick::BoundsError) do
          table.scan_projection_typed_window(W229_PROJECTION, [] of String, 0_u64, 1) { |_batch| callbacks += 1 }
        end
        expect_raises(CrystalClick::BoundsError) do
          table.scan_projection_typed_window(W229_PROJECTION, ["bucket", "bucket"], 0_u64, 1) { |_batch| callbacks += 1 }
        end
        callbacks.should eq(0)
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "admits only row zero for an empty resolved projection set" do
    root = File.tempname("crystal-click-offline-projection-window-w229-empty")
    database_path = w229_catalog_root(root)
    begin
      w229_write_table(root, database_path, "events", w229_uuid(12))
      table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")

      table.responds_to?(:scan_projection_typed_window).should be_true
      if table.responds_to?(:scan_projection_typed_window)
        callbacks = 0
        table.scan_projection_typed_window(W229_PROJECTION, ["bucket"], 0_u64, 1) { |_batch| callbacks += 1 }
        callbacks.should eq(0)

        expect_raises(CrystalClick::BoundsError) do
          table.scan_projection_typed_window(W229_PROJECTION, ["bucket"], 1_u64, 1) { |_batch| callbacks += 1 }
        end
        callbacks.should eq(0)
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "preflights a missing child outside the interval, including the expected full EOF" do
    root = File.tempname("crystal-click-offline-projection-window-w229-missing")
    database_path = w229_catalog_root(root)
    begin
      table_path = w229_write_table(root, database_path, "events", w229_uuid(13))
      w229_add_parent_part(table_path, "all_1_1_0", child_rows_per_mark: 1)
      missing_parent = w229_add_parent_part(table_path, "all_2_2_0", child_rows_per_mark: 1)
      FileUtils.rm_rf(File.join(missing_parent, "#{W229_PROJECTION}.proj"))
      table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")

      table.responds_to?(:scan_projection_typed_window).should be_true
      if table.responds_to?(:scan_projection_typed_window)
        # Four is the known full extent from the complete two-child control.
        # Even at that intended EOF, the incomplete later parent must be rejected.
        [0_u64, 4_u64].each do |start_row|
          callbacks = 0
          expect_raises(CrystalClick::InvalidPartError) do
            table.scan_projection_typed_window(W229_PROJECTION, ["bucket"], start_row, 1) do |_batch|
              callbacks += 1
            end
          end
          callbacks.should eq(0)
        end
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "preflights a symlink child outside the interval, including the expected full EOF" do
    root = File.tempname("crystal-click-offline-projection-window-w229-symlink")
    database_path = w229_catalog_root(root)
    begin
      table_path = w229_write_table(root, database_path, "events", w229_uuid(14))
      parent_a = w229_add_parent_part(table_path, "all_1_1_0", child_rows_per_mark: 1)
      parent_b = w229_add_parent_part(table_path, "all_2_2_0", child_rows_per_mark: 1)
      FileUtils.rm_rf(File.join(parent_b, "#{W229_PROJECTION}.proj"))
      File.symlink(
        File.join(parent_a, "#{W229_PROJECTION}.proj"),
        File.join(parent_b, "#{W229_PROJECTION}.proj")
      )
      table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")

      table.responds_to?(:scan_projection_typed_window).should be_true
      if table.responds_to?(:scan_projection_typed_window)
        [0_u64, 4_u64].each do |start_row|
          callbacks = 0
          expect_raises(CrystalClick::InvalidPartError) do
            table.scan_projection_typed_window(W229_PROJECTION, ["bucket"], start_row, 1) do |_batch|
              callbacks += 1
            end
          end
          callbacks.should eq(0)
        end
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "preserves name, declaration, exact-engine, and materialized-view guards" do
    root = File.tempname("crystal-click-offline-projection-window-w229-fences")
    database_path = w229_catalog_root(root)
    begin
      w229_write_table(root, database_path, "events", w229_uuid(15))
      w229_write_table(root, database_path, "unsafe", w229_uuid(16), projection_name: "by/tag")
      w229_write_table(root, database_path, "replacing", w229_uuid(17), engine: "ReplacingMergeTree")
      w229_attach_view(database_path)

      catalog = CrystalClick::OfflineCatalog.open(root)
      events = catalog.table("lab", "events")
      unsafe = catalog.table("lab", "unsafe")
      replacing = catalog.table("lab", "replacing")
      rollup = catalog.table("lab", "rollup")

      events.responds_to?(:scan_projection_typed_window).should be_true
      unsafe.responds_to?(:scan_projection_typed_window).should be_true
      replacing.responds_to?(:scan_projection_typed_window).should be_true
      rollup.responds_to?(:scan_projection_typed_window).should be_true
      if events.responds_to?(:scan_projection_typed_window)
        expect_raises(CrystalClick::UnsupportedFormatError) do
          events.scan_projection_typed_window("not_declared", ["bucket"], 0_u64, 1) { |_batch| }
        end
      end
      if unsafe.responds_to?(:scan_projection_typed_window)
        expect_raises(CrystalClick::InvalidPartError) do
          unsafe.scan_projection_typed_window("by/tag", ["bucket"], 0_u64, 1) { |_batch| }
        end
      end
      if replacing.responds_to?(:scan_projection_typed_window)
        expect_raises(CrystalClick::UnsupportedFormatError) do
          replacing.scan_projection_typed_window(W229_PROJECTION, ["bucket"], 0_u64, 1) { |_batch| }
        end
      end
      if rollup.responds_to?(:scan_projection_typed_window)
        expect_raises(CrystalClick::UnsupportedFormatError) do
          rollup.scan_projection_typed_window(W229_PROJECTION, ["bucket"], 0_u64, 1) { |_batch| }
        end
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
