require "./spec_helper"

W86_DATABASE_UUID    = "f86a4b30-7b7f-4e2f-9e44-dc13a87b8601"
W86_VIEW_UUID        = "f86a4b30-7b7f-4e2f-9e44-dc13a87b8602"
W86_TABLE_UUID       = "f86a4b30-7b7f-4e2f-9e44-dc13a87b8603"
W86_INNER_UUID       = "f86a4b30-7b7f-4e2f-9e44-dc13a87b8604"
W86_CONTROL_UUID     = "f86a4b30-7b7f-4e2f-9e44-dc13a87b8605"
W86_FALSE_AS_UUID    = "f86a4b30-7b7f-4e2f-9e44-dc13a87b8606"
W86_EMPTY_AS_UUID    = "f86a4b30-7b7f-4e2f-9e44-dc13a87b8607"
W86_TRAILING_AS_UUID = "f86a4b30-7b7f-4e2f-9e44-dc13a87b8608"
W86_ESCAPED_AS_UUID  = "f86a4b30-7b7f-4e2f-9e44-dc13a87b8609"
W86_PART_FIXTURE     = File.expand_path("../test/fixtures/public/wide_two_uint64/part", __DIR__)

private def w86_catalog_root(root : String) : String
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))
  File.write(
    File.join(root, "metadata", "lab.sql"),
    "ATTACH DATABASE _ UUID '#{W86_DATABASE_UUID}'\nENGINE = Atomic\n"
  )
  database_path = File.join(root, "store", W86_DATABASE_UUID[0, 3], W86_DATABASE_UUID)
  FileUtils.mkdir_p(database_path)
  database_path
end

private def w86_store_path(root : String, uuid : String) : String
  File.join(root, "store", uuid[0, 3], uuid)
end

private def w86_encode_identifier(name : String) : String
  String.build do |io|
    name.each_byte do |byte|
      if byte >= 'a'.ord && byte <= 'z'.ord ||
         byte >= 'A'.ord && byte <= 'Z'.ord ||
         byte >= '0'.ord && byte <= '9'.ord ||
         byte == '_'.ord
        io.write_byte(byte)
      else
        io << '%' << byte.to_s(16).upcase.rjust(2, '0')
      end
    end
  end
end

private def w86_write_physical_table(
  root : String,
  database_path : String,
  name : String,
  uuid : String,
  ddl : String,
  with_part : Bool = false,
) : String
  File.write(File.join(database_path, "#{w86_encode_identifier(name)}.sql"), ddl)
  table_path = w86_store_path(root, uuid)
  FileUtils.mkdir_p(table_path)
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  if with_part
    FileUtils.cp_r(W86_PART_FIXTURE, File.join(table_path, "all_1_1_0"))
  end
  table_path
end

private def w86_attach_materialized_view_ddl : String
  <<-DDL
  ATTACH MATERIALIZED VIEW _ UUID '#{W86_VIEW_UUID}' TO INNER UUID '#{W86_INNER_UUID}'
  (
      `id` UInt64,
      `tag` String,
      `amount` UInt64
  )
  ENGINE = MergeTree
  ORDER BY id SETTINGS index_granularity = 8192
  AS SELECT id, tag, amount FROM lab.physical
  DDL
end

private def w86_attach_projected_table_ddl : String
  <<-DDL
  ATTACH TABLE _ UUID '#{W86_TABLE_UUID}'
  (
      `tag` String,
      `amount` UInt64,
      PROJECTION by_tag (SELECT tag, amount ORDER BY tag)
  )
  ENGINE = MergeTree
  ORDER BY amount
  DDL
end

private def w86_assert_kind(table : CrystalClick::OfflineTable, expected : Symbol) : Nil
  if table.responds_to?(:kind)
    table.kind.should eq(expected)
  else
    fail("OfflineTable#kind is missing")
  end
end

private def w86_assert_metadata_ddl(table : CrystalClick::OfflineTable, expected : String) : Nil
  if table.responds_to?(:metadata_ddl)
    table.metadata_ddl.should eq(expected)
  else
    fail("OfflineTable#metadata_ddl is missing")
  end
end

private def w86_assert_projection_metadata(table : CrystalClick::OfflineTable) : Nil
  if table.responds_to?(:projections)
    table.projections.map { |projection| {projection.name, projection.definition} }.should eq([
      {"by_tag", "SELECT tag, amount ORDER BY tag"},
    ])
  else
    fail("OfflineTable#projections is missing")
  end
end

private def w86_assert_no_projections(table : CrystalClick::OfflineTable) : Nil
  if table.responds_to?(:projections)
    table.projections.should be_empty
  else
    fail("OfflineTable#projections is missing")
  end
end

private def w86_assert_rejected_materialized_storage_clause(name : String, uuid : String, storage_clause : String) : Nil
  root = File.tempname("crystal-click-offline-catalog-w86-malformed-storage-#{name}")
  database_path = w86_catalog_root(root)
  ddl = <<-DDL
  ATTACH MATERIALIZED VIEW _ UUID '#{uuid}' TO INNER UUID '#{W86_INNER_UUID}'
  (
      `id` UInt64
  )
  ENGINE = MergeTree
  #{storage_clause}
  DDL

  begin
    File.write(File.join(database_path, "#{name}.sql"), ddl)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::OfflineCatalog.open(root).table("lab", name)
    end
  ensure
    FileUtils.rm_rf(root)
  end
end

describe CrystalClick::OfflineCatalog do
  it "opens a stock-shaped MATERIALIZED VIEW without looking up its UUID store" do
    root = File.tempname("crystal-click-offline-catalog-w86-mv")
    database_path = w86_catalog_root(root)
    begin
      File.write(File.join(database_path, "rollup.sql"), w86_attach_materialized_view_ddl)
      inner_name = ".inner_id.#{W86_VIEW_UUID}"
      inner_ddl = <<-DDL
      ATTACH TABLE _ UUID '#{W86_INNER_UUID}'
      (
          `id` UInt64,
          `tag` String,
          `amount` UInt64
      )
      ENGINE = MergeTree
      ORDER BY id
      DDL
      w86_write_physical_table(root, database_path, inner_name, W86_INNER_UUID, inner_ddl, with_part: true)

      catalog = CrystalClick::OfflineCatalog.open(root)
      tables = catalog["lab"].tables
      tables.map(&.name).sort.should eq([inner_name, "rollup"].sort)
      view = catalog.table("lab", "rollup")

      view.engine.should eq("MaterializedView")
      w86_assert_kind(view, :materialized_view)
      w86_assert_metadata_ddl(view, w86_attach_materialized_view_ddl)
      view.columns.map { |column| {column.name, column.type} }.should eq([
        {"id", "UInt64"},
        {"tag", "String"},
        {"amount", "UInt64"},
      ])
      Dir.exists?(w86_store_path(root, W86_VIEW_UUID)).should be_false

      inner_table = catalog.table("lab", inner_name)
      inner_table.uuid.should eq(W86_INNER_UUID)
      inner_table.engine.should eq("MergeTree")
      inner_table.part_candidates.map { |candidate| {candidate.name, candidate.row_count} }.should eq([
        {"all_1_1_0", File.read(File.join(W86_PART_FIXTURE, "count.txt")).strip.to_u64},
      ])

      expect_raises(CrystalClick::UnsupportedFormatError) { view.part_candidates }
      callbacks = 0
      expect_raises(CrystalClick::UnsupportedFormatError) do
        view.scan_typed(["tag"]) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)

      candidates = catalog["system"]["part_candidates"]
      candidates["database"].values.map(&.as(String)).should eq(["lab"])
      candidates["table"].values.map(&.as(String)).should eq([inner_name])
      candidates["name"].values.map(&.as(String)).should eq(["all_1_1_0"])
      candidates["rows"].values.map(&.as(UInt64)).should eq([
        File.read(File.join(W86_PART_FIXTURE, "count.txt")).strip.to_u64,
      ])
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "keeps a top-level PROJECTION declaration separate from ordinary table columns" do
    root = File.tempname("crystal-click-offline-catalog-w86-projection")
    database_path = w86_catalog_root(root)
    begin
      File.write(File.join(database_path, "physical.sql"), w86_attach_projected_table_ddl)
      w86_write_physical_table(root, database_path, "physical", W86_TABLE_UUID, w86_attach_projected_table_ddl)

      catalog = CrystalClick::OfflineCatalog.open(root)
      table = catalog.table("lab", "physical")

      table.engine.should eq("MergeTree")
      w86_assert_kind(table, :table)
      w86_assert_metadata_ddl(table, w86_attach_projected_table_ddl)
      table.columns.map { |column| {column.name, column.type} }.should eq([
        {"tag", "String"},
        {"amount", "UInt64"},
      ])
      w86_assert_projection_metadata(table)
      table.part_candidates.should be_empty
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "keeps ordinary MergeTree columns, candidates, and scans unchanged" do
    root = File.tempname("crystal-click-offline-catalog-w86-control")
    database_path = w86_catalog_root(root)
    ddl = <<-DDL
    ATTACH TABLE _ UUID '#{W86_CONTROL_UUID}'
    (
        `left` UInt64,
        `right` UInt64
    )
    ENGINE = MergeTree
    ORDER BY tuple()
    DDL
    begin
      w86_write_physical_table(root, database_path, "control", W86_CONTROL_UUID, ddl, with_part: true)
      table = CrystalClick::OfflineCatalog.open(root).table("lab", "control")

      table.engine.should eq("MergeTree")
      w86_assert_kind(table, :table)
      w86_assert_metadata_ddl(table, ddl)
      w86_assert_no_projections(table)
      table.columns.map { |column| {column.name, column.type} }.should eq([
        {"left", "UInt64"},
        {"right", "UInt64"},
      ])
      table.part_candidates.size.should eq(1)
      table.part_candidates.first.row_count.should eq(File.read(File.join(W86_PART_FIXTURE, "count.txt")).strip.to_u64)

      callback_count = 0
      table.scan_typed_window(["left"], 0_u64, 1) do |batch|
        batch.values_for("left").size.should eq(1)
        callback_count += 1
      end
      callback_count.should eq(1)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "rejects malformed projection declarations, duplicate names, and invalid names" do
    root = File.tempname("crystal-click-offline-catalog-w86-invalid")
    database_path = w86_catalog_root(root)
    cases = [
      {
        "malformed",
        "f86a4b30-7b7f-4e2f-9e44-dc13a87b8611",
        "PROJECTION by_tag SELECT tag, amount ORDER BY tag",
      },
      {
        "duplicate",
        "f86a4b30-7b7f-4e2f-9e44-dc13a87b8612",
        "PROJECTION by_tag (SELECT tag ORDER BY tag), PROJECTION by_tag (SELECT amount ORDER BY amount)",
      },
      {
        "invalid_name",
        "f86a4b30-7b7f-4e2f-9e44-dc13a87b8613",
        "PROJECTION 9by_tag (SELECT tag ORDER BY tag)",
      },
      {
        "semicolon",
        "f86a4b30-7b7f-4e2f-9e44-dc13a87b8614",
        "PROJECTION by_tag (SELECT tag ORDER BY tag; SELECT tag ORDER BY tag)",
      },
      {
        "comment",
        "f86a4b30-7b7f-4e2f-9e44-dc13a87b8615",
        "PROJECTION by_tag (SELECT tag ORDER BY tag /* trailing */)",
      },
      {
        "trailing_tokens",
        "f86a4b30-7b7f-4e2f-9e44-dc13a87b8616",
        "PROJECTION by_tag (SELECT tag ORDER BY tag) trailing",
      },
    ]

    begin
      cases.each do |name, uuid, projection|
        ddl = <<-DDL
        ATTACH TABLE _ UUID '#{uuid}'
        (
            `tag` String,
            `amount` UInt64,
            #{projection}
        )
        ENGINE = MergeTree
        ORDER BY amount
        DDL
        metadata_path = File.join(database_path, "#{name}.sql")
        File.write(metadata_path, ddl)
        expect_raises(CrystalClick::UnsupportedFormatError) do
          CrystalClick::OfflineCatalog.open(root).table("lab", name)
        end
        File.delete(metadata_path)
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "distinguishes quoted AS SELECT tokens from a real MATERIALIZED VIEW query delimiter" do
    root = File.tempname("crystal-click-offline-catalog-w86-false-as")
    database_path = w86_catalog_root(root)
    ddl = <<-DDL
    ATTACH MATERIALIZED VIEW _ UUID '#{W86_FALSE_AS_UUID}' TO INNER UUID '#{W86_INNER_UUID}'
    (
        `id` UInt64,
        `tag` String
    )
    ENGINE = MergeTree
    ORDER BY id SETTINGS storage_policy = 'AS SELECT id, tag FROM lab.physical'
    DDL
    empty_select_ddl = <<-DDL
    ATTACH MATERIALIZED VIEW _ UUID '#{W86_EMPTY_AS_UUID}' TO INNER UUID '#{W86_INNER_UUID}'
    (
        `id` UInt64,
        `tag` String
    )
    ENGINE = MergeTree
    ORDER BY id
    AS SELECT
    DDL
    trailing_statement_ddl = <<-DDL
    ATTACH MATERIALIZED VIEW _ UUID '#{W86_TRAILING_AS_UUID}' TO INNER UUID '#{W86_INNER_UUID}'
    (
        `id` UInt64
    )
    ENGINE = MergeTree
    ORDER BY id
    AS SELECT 1; DROP TABLE lab.source
    DDL
    escaped_quoted_as_ddl = <<-DDL
    ATTACH MATERIALIZED VIEW _ UUID '#{W86_ESCAPED_AS_UUID}' TO INNER UUID '#{W86_INNER_UUID}'
    (
        `id` UInt64,
        `tag` String
    )
    ENGINE = MergeTree
    ORDER BY id
    SETTINGS storage_policy = 'literal ''AS SELECT id, tag FROM lab.physical'''
    AS SELECT id, tag FROM lab.physical
    DDL
    begin
      File.write(File.join(database_path, "false_delimiter.sql"), ddl)

      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::OfflineCatalog.open(root).table("lab", "false_delimiter")
      end
      File.delete(File.join(database_path, "false_delimiter.sql"))

      File.write(File.join(database_path, "empty_select.sql"), empty_select_ddl)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::OfflineCatalog.open(root).table("lab", "empty_select")
      end
      File.delete(File.join(database_path, "empty_select.sql"))

      File.write(File.join(database_path, "trailing_statement.sql"), trailing_statement_ddl)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::OfflineCatalog.open(root).table("lab", "trailing_statement")
      end
      File.delete(File.join(database_path, "trailing_statement.sql"))

      File.write(File.join(database_path, "escaped_quoted_as.sql"), escaped_quoted_as_ddl)
      escaped_quoted_as = CrystalClick::OfflineCatalog.open(root).table("lab", "escaped_quoted_as")
      escaped_quoted_as.engine.should eq("MaterializedView")
      w86_assert_kind(escaped_quoted_as, :materialized_view)
      w86_assert_metadata_ddl(escaped_quoted_as, escaped_quoted_as_ddl)
      escaped_quoted_as.columns.map { |column| {column.name, column.type} }.should eq([
        {"id", "UInt64"},
        {"tag", "String"},
      ])
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "rejects ORDER BY AS SELECT as a same-line query delimiter" do
    w86_assert_rejected_materialized_storage_clause(
      "order_by_inline",
      "f86a4b30-7b7f-4e2f-9e44-dc13a87b8617",
      "ORDER BY AS SELECT 1",
    )
  end

  it "rejects ORDER BY AS SELECT split across a newline" do
    w86_assert_rejected_materialized_storage_clause(
      "order_by_newline",
      "f86a4b30-7b7f-4e2f-9e44-dc13a87b8618",
      "ORDER BY\nAS SELECT 1",
    )
  end

  it "rejects AS SELECT after an empty SETTINGS value" do
    w86_assert_rejected_materialized_storage_clause(
      "settings_missing_value",
      "f86a4b30-7b7f-4e2f-9e44-dc13a87b8619",
      "ORDER BY id SETTINGS = AS SELECT 1",
    )
  end

  it "bounds raw table attach DDL before parsing or exposing metadata" do
    root = File.tempname("crystal-click-offline-catalog-w86-ddl-bound")
    database_path = w86_catalog_root(root)
    begin
      oversized = "x" * (CrystalClick::OfflineCatalog::MAX_METADATA_BYTES + 1)
      File.write(File.join(database_path, "oversized.sql"), oversized)

      expect_raises(CrystalClick::BoundsError) do
        CrystalClick::OfflineCatalog.open(root).table("lab", "oversized")
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
