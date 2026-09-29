require "./spec_helper"

W88_DATABASE_UUID = "f88a0000-7b7f-4e2f-9e44-dc13a87b8801"
W88_SOURCE_UUID   = "f88a0000-7b7f-4e2f-9e44-dc13a87b8802"
W88_TARGET_UUID   = "f88a0000-7b7f-4e2f-9e44-dc13a87b8803"
W88_VIEW_UUID     = "f88a0000-7b7f-4e2f-9e44-dc13a87b8804"

private def w88_database_path(root : String) : String
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))
  File.write(
    File.join(root, "metadata", "lab.sql"),
    "ATTACH DATABASE _ UUID '#{W88_DATABASE_UUID}'\nENGINE = Atomic\n"
  )
  path = File.join(root, "store", W88_DATABASE_UUID[0, 3], W88_DATABASE_UUID)
  FileUtils.mkdir_p(path)
  path
end

private def w88_write_table(
  root : String,
  database_path : String,
  name : String,
  uuid : String,
  columns : String = "`k` UInt64, `v` String",
  tail : String = "ORDER BY k SETTINGS index_granularity = 8192",
) : String
  ddl = <<-DDL
  ATTACH TABLE _ UUID '#{uuid}'
  (
      #{columns}
  )
  ENGINE = MergeTree
  #{tail}
  DDL
  File.write(File.join(database_path, "#{name}.sql"), ddl)

  table_path = File.join(root, "store", uuid[0, 3], uuid)
  FileUtils.mkdir_p(table_path)
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  table_path
end

private def w88_write_view(
  database_path : String,
  query : String = "SELECT k, v FROM lab.source",
  target : String = "lab.target",
) : Nil
  ddl = <<-DDL
  ATTACH MATERIALIZED VIEW _ UUID '#{W88_VIEW_UUID}' TO #{target}
  (
      `k` UInt64,
      `v` String
  )
  AS #{query}
  DDL
  File.write(File.join(database_path, "view.sql"), ddl)
end

private def w88_write_source_part(
  source_path : String,
  name : String,
  keys : Array(UInt64) = [1_u64, 2_u64, 3_u64],
  values : Array(String) = ["alpha", "", "omega"],
) : String
  CrystalClick::WidePartWriter.write_uint64_typed_pair(
    File.join(source_path, name),
    "k",
    keys.to_unsafe.to_slice(keys.size),
    "v",
    values.to_unsafe.to_slice(values.size)
  )
end

private def w88_catalog(
  root : String,
  source_columns : String = "`k` UInt64, `v` String",
  source_tail : String = "ORDER BY k SETTINGS index_granularity = 8192",
  target_columns : String = "`k` UInt64, `v` String",
  target_tail : String = "ORDER BY k SETTINGS index_granularity = 8192",
  query : String = "SELECT k, v FROM lab.source",
  target : String = "lab.target",
  include_second_part : Bool = true,
) : CrystalClick::OfflineCatalog
  database_path = w88_database_path(root)
  source_path = w88_write_table(root, database_path, "source", W88_SOURCE_UUID, source_columns, source_tail)
  w88_write_table(root, database_path, "target", W88_TARGET_UUID, target_columns, target_tail)
  w88_write_view(database_path, query, target)
  w88_write_source_part(source_path, "all_1_1_0")
  if include_second_part
    w88_write_source_part(source_path, "all_2_2_0", [4_u64], ["other"])
  end
  CrystalClick::OfflineCatalog.open(root)
end

private def w88_assert_unpublished(destination : String) : Nil
  File.exists?(destination).should be_false
  File.symlink?(destination).should be_false
end

describe CrystalClick::OfflineCatalog do
  it "materializes exactly the selected source part as a detached identity-MV part" do
    root = File.tempname("crystal-click-offline-mv-w88-positive")
    begin
      catalog = w88_catalog(root)
      output_parent = File.join(root, "detached")
      Dir.mkdir(output_parent)
      destination = File.join(output_parent, "all_9_9_0")

      result = catalog.materialize_view_part("lab", "view", "all_1_1_0", destination, rows_per_mark: 8192)

      result.should eq(File.join(File.realpath(output_parent), File.basename(destination)))
      reader = CrystalClick::WidePartTable.open_selected_typed([destination], ["k", "v"])
      reader.column_types.should eq([{"k", "UInt64"}, {"v", "String"}])
      rows = [] of {UInt64, String}
      reader.scan_typed do |batch|
        keys = batch.values_for("k")
        values = batch.strings_for("v")
        keys.size.should eq(values.size)
        keys.each_with_index { |key, index| rows << {key, String.new(values[index].to_slice)} }
      end
      rows.should eq([{1_u64, "alpha"}, {2_u64, ""}, {3_u64, "omega"}])
      catalog.table("lab", "target").part_candidates.should be_empty
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "rejects unsupported MV targets and non-identity SELECTs before publication" do
    [
      {"INNER UUID target", "SELECT k, v FROM lab.source", "INNER UUID '#{W88_TARGET_UUID}'"},
      {"wrong target database", "SELECT k, v FROM lab.source", "other.target"},
      {"expression", "SELECT k + 1, v FROM lab.source", "lab.target"},
      {"alias", "SELECT k AS key, v FROM lab.source", "lab.target"},
      {"filter", "SELECT k, v FROM lab.source WHERE k > 1", "lab.target"},
      {"wrong source", "SELECT k, v FROM other.source", "lab.target"},
      {"trailing clause", "SELECT k, v FROM lab.source ORDER BY k", "lab.target"},
    ].each do |label, query, target|
      root = File.tempname("crystal-click-offline-mv-w88-unsupported-#{label}")
      begin
        catalog = w88_catalog(root, query: query, target: target)
        output_parent = File.join(root, "detached")
        Dir.mkdir(output_parent)
        destination = File.join(output_parent, "all_9_9_0")
        expect_raises(CrystalClick::UnsupportedFormatError) do
          catalog.materialize_view_part("lab", "view", "all_1_1_0", destination)
        end
        w88_assert_unpublished(destination)
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end

  it "rejects missing view, source, or target identities without output" do
    root = File.tempname("crystal-click-offline-mv-w88-missing-identity")
    begin
      catalog = w88_catalog(root)
      output_parent = File.join(root, "detached")
      Dir.mkdir(output_parent)
      destination = File.join(output_parent, "all_9_9_0")

      expect_raises(CrystalClick::InvalidPartError) do
        catalog.materialize_view_part("lab", "missing", "all_1_1_0", destination)
      end
      missing_source_root = File.tempname("crystal-click-offline-mv-w88-missing-source")
      begin
        missing_source_catalog = w88_catalog(missing_source_root, query: "SELECT k, v FROM lab.missing")
        missing_source_output = File.join(missing_source_root, "detached")
        Dir.mkdir(missing_source_output)
        expect_raises(CrystalClick::InvalidPartError) do
          missing_source_catalog.materialize_view_part(
            "lab", "view", "all_1_1_0", File.join(missing_source_output, "all_9_9_0")
          )
        end
      ensure
        FileUtils.rm_rf(missing_source_root)
      end

      missing_target_root = File.tempname("crystal-click-offline-mv-w88-missing-target")
      begin
        missing_target_catalog = w88_catalog(missing_target_root, target: "lab.missing")
        missing_target_output = File.join(missing_target_root, "detached")
        Dir.mkdir(missing_target_output)
        expect_raises(CrystalClick::InvalidPartError) do
          missing_target_catalog.materialize_view_part(
            "lab", "view", "all_1_1_0", File.join(missing_target_output, "all_9_9_0")
          )
        end
      ensure
        FileUtils.rm_rf(missing_target_root)
      end
      w88_assert_unpublished(destination)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "rejects non-exact source and target schemas, non-simple keys, and partitioned tables" do
    cases = [
      {"target order", "`k` UInt64, `v` String, `extra` UInt64", "ORDER BY k", "`k` UInt64, `v` String", "ORDER BY k"},
      {"target key type", "`k` UInt64, `v` String", "ORDER BY tuple(k)", "`k` UInt64, `v` String", "ORDER BY k"},
      {"target partition", "`k` UInt64, `v` String", "PARTITION BY v ORDER BY k", "`k` UInt64, `v` String", "ORDER BY k"},
      {"source schema", "`k` UInt64, `v` FixedString(4)", "ORDER BY k", "`k` UInt64, `v` String", "ORDER BY k"},
      {"source key", "`k` UInt64, `v` String", "ORDER BY tuple(k)", "`k` UInt64, `v` String", "ORDER BY k"},
      {"source partition", "`k` UInt64, `v` String", "PARTITION BY v ORDER BY k", "`k` UInt64, `v` String", "ORDER BY k"},
    ]
    cases.each do |label, source_columns, source_tail, target_columns, target_tail|
      root = File.tempname("crystal-click-offline-mv-w88-schema-#{label}")
      begin
        catalog = w88_catalog(
          root,
          source_columns: source_columns,
          source_tail: source_tail,
          target_columns: target_columns,
          target_tail: target_tail
        )
        output_parent = File.join(root, "detached")
        Dir.mkdir(output_parent)
        destination = File.join(output_parent, "all_9_9_0")
        expect_raises(CrystalClick::UnsupportedFormatError) do
          catalog.materialize_view_part("lab", "view", "all_1_1_0", destination)
        end
        w88_assert_unpublished(destination)
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end

  it "accepts only the stock wide-part selection settings and rejects other settings" do
    root = File.tempname("crystal-click-offline-mv-w88-wide-settings")
    begin
      wide_settings = "ORDER BY k SETTINGS min_rows_for_wide_part = 0, min_bytes_for_wide_part = 0, index_granularity = 8192"
      catalog = w88_catalog(root, source_tail: wide_settings, target_tail: wide_settings)
      output_parent = File.join(root, "detached")
      Dir.mkdir(output_parent)
      destination = File.join(output_parent, "all_9_9_0")

      catalog.materialize_view_part("lab", "view", "all_1_1_0", destination)
      File.directory?(destination).should be_true
    ensure
      FileUtils.rm_rf(root)
    end

    [
      {"unsafe wide threshold", "ORDER BY k SETTINGS min_rows_for_wide_part = 1, min_bytes_for_wide_part = 0"},
      {"unknown setting", "ORDER BY k SETTINGS min_rows_for_wide_part = 0, min_bytes_for_wide_part = 0, allow_nullable_key = 1"},
    ].each do |label, tail|
      root = File.tempname("crystal-click-offline-mv-w88-settings-#{label}")
      begin
        catalog = w88_catalog(root, source_tail: tail)
        output_parent = File.join(root, "detached")
        Dir.mkdir(output_parent)
        destination = File.join(output_parent, "all_9_9_0")
        expect_raises(CrystalClick::UnsupportedFormatError) do
          catalog.materialize_view_part("lab", "view", "all_1_1_0", destination)
        end
        w88_assert_unpublished(destination)
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end

  it "requires exactly one resolved, non-overlapping selected source part" do
    root = File.tempname("crystal-click-offline-mv-w88-source-selection")
    begin
      catalog = w88_catalog(root)
      output_parent = File.join(root, "detached")
      Dir.mkdir(output_parent)
      destination = File.join(output_parent, "all_9_9_0")
      expect_raises(CrystalClick::InvalidPartError) do
        catalog.materialize_view_part("lab", "view", "all_7_7_0", destination)
      end
      w88_assert_unpublished(destination)

      source_path = File.join(root, "store", W88_SOURCE_UUID[0, 3], W88_SOURCE_UUID)
      w88_write_source_part(source_path, "all_1_2_0", [8_u64], ["overlap"])
      catalog = CrystalClick::OfflineCatalog.open(root)
      expect_raises(CrystalClick::InvalidPartError) do
        catalog.materialize_view_part("lab", "view", "all_1_1_0", destination)
      end
      w88_assert_unpublished(destination)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "rejects non-canonical or overlapping output identity and occupied output path" do
    root = File.tempname("crystal-click-offline-mv-w88-output-path")
    begin
      catalog = w88_catalog(root)
      output_parent = File.join(root, "detached")
      Dir.mkdir(output_parent)
      bad_destination = File.join(output_parent, "part_9_9_0")
      expect_raises(CrystalClick::InvalidPartError) do
        catalog.materialize_view_part("lab", "view", "all_1_1_0", bad_destination)
      end
      w88_assert_unpublished(bad_destination)

      target_path = File.join(root, "store", W88_TARGET_UUID[0, 3], W88_TARGET_UUID)
      w88_write_source_part(target_path, "all_9_9_0", [20_u64], ["target"])
      catalog = CrystalClick::OfflineCatalog.open(root)
      overlap_destination = File.join(output_parent, "all_9_9_0")
      expect_raises(CrystalClick::InvalidPartError) do
        catalog.materialize_view_part("lab", "view", "all_1_1_0", overlap_destination)
      end
      w88_assert_unpublished(overlap_destination)

      occupied_destination = File.join(output_parent, "all_12_12_0")
      Dir.mkdir(occupied_destination)
      File.write(File.join(occupied_destination, "keep"), "do not replace")
      expect_raises(CrystalClick::InvalidPartError) do
        catalog.materialize_view_part("lab", "view", "all_1_1_0", occupied_destination)
      end
      File.read(File.join(occupied_destination, "keep")).should eq("do not replace")
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "accepts only a non-symlinked detached parent, never an active target path" do
    root = File.tempname("crystal-click-offline-mv-w88-detached-boundary")
    begin
      catalog = w88_catalog(root)
      real_parent = File.join(root, "detached-real")
      Dir.mkdir(real_parent)
      linked_parent = File.join(root, "detached")
      File.symlink(real_parent, linked_parent)
      symlink_destination = File.join(linked_parent, "all_9_9_0")
      expect_raises(CrystalClick::InvalidPartError) do
        catalog.materialize_view_part("lab", "view", "all_1_1_0", symlink_destination)
      end
      w88_assert_unpublished(symlink_destination)
      Dir.exists?(real_parent).should be_true

      table_path = File.join(root, "store", W88_TARGET_UUID[0, 3], W88_TARGET_UUID)
      active_destination = File.join(table_path, "all_9_9_0")
      expect_raises(CrystalClick::InvalidPartError) do
        catalog.materialize_view_part("lab", "view", "all_1_1_0", active_destination)
      end
      w88_assert_unpublished(active_destination)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "rejects a symlinked destination leaf before publishing" do
    root = File.tempname("crystal-click-offline-mv-w88-symlink-leaf")
    begin
      catalog = w88_catalog(root)
      output_parent = File.join(root, "detached")
      Dir.mkdir(output_parent)
      destination = File.join(output_parent, "all_9_9_0")
      File.symlink(File.join(root, "missing-target"), destination)

      expect_raises(CrystalClick::InvalidPartError) do
        catalog.materialize_view_part("lab", "view", "all_1_1_0", destination)
      end
      File.symlink?(destination).should be_true
      File.exists?(File.join(output_parent, "all_9_9_0.stage")).should be_false
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "rejects writer and materialization bounds before publishing" do
    root = File.tempname("crystal-click-offline-mv-w88-bounds")
    begin
      catalog = w88_catalog(root)
      output_parent = File.join(root, "detached")
      Dir.mkdir(output_parent)
      destination = File.join(output_parent, "all_9_9_0")
      {0, CrystalClick::WidePartWriter::MAX_ROWS_PER_MARK + 1}.each do |rows_per_mark|
        expect_raises(CrystalClick::BoundsError) do
          catalog.materialize_view_part("lab", "view", "all_1_1_0", destination, rows_per_mark: rows_per_mark)
        end
        w88_assert_unpublished(destination)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        catalog.materialize_view_part("lab", "view", "all_1_1_0", destination, rows_per_mark: 4096)
      end
      w88_assert_unpublished(destination)

      source_count = File.join(root, "store", W88_SOURCE_UUID[0, 3], W88_SOURCE_UUID, "all_1_1_0", "count.txt")
      File.write(source_count, "100001")
      catalog = CrystalClick::OfflineCatalog.open(root)
      expect_raises(CrystalClick::BoundsError) do
        catalog.materialize_view_part("lab", "view", "all_1_1_0", destination)
      end
      w88_assert_unpublished(destination)
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
