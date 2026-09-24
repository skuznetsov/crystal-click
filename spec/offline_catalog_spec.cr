require "./spec_helper"

OFFLINE_CATALOG_FIXTURE = File.expand_path("../test/fixtures/public/wide_two_uint64/part", __DIR__)
OFFLINE_DB_UUID         = "835e7af8-f57c-42b8-bcb0-863f3de0ca51"
OFFLINE_TABLE_UUID      = "1f068934-2439-44ce-9501-c2dc252a9027"
OFFLINE_TABLE_ROWS      = 17_001

class OfflineCatalogSpecStop < Exception
end

class OfflineCatalogCapacityProbe < CrystalClick::OfflineCatalog
  def initialize(root : String, @candidate_limit : Int32 = CrystalClick::OfflineCatalog::MAX_PART_CANDIDATES)
    super(root)
  end

  private def max_projected_candidates : Int32
    @candidate_limit
  end

  def validate_projected_candidates(count : Int32) : Nil
    ensure_candidate_capacity!(count)
  end
end

def with_offline_catalog_root(&)
  root = File.tempname("crystal-click-offline-catalog-spec")
  Dir.mkdir(root)
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))
  begin
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

def offline_catalog_escape_identifier(name : String) : String
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

def offline_catalog_store_path(root : String, uuid : String) : String
  File.join(root, "store", uuid[0, 3], uuid)
end

def offline_catalog_create_database(
  root : String,
  name : String = "lab",
  uuid : String = OFFLINE_DB_UUID,
  metadata_symlink : Bool = false,
)
  metadata_path = File.join(root, "metadata")
  store_path = offline_catalog_store_path(root, uuid)
  FileUtils.mkdir_p(store_path)

  ddl_path = File.join(metadata_path, "#{offline_catalog_escape_identifier(name)}.sql")
  File.write(ddl_path, "ATTACH DATABASE _ UUID '#{uuid}'\nENGINE = Atomic\n")

  if metadata_symlink
    File.symlink("../store/#{uuid[0, 3]}/#{uuid}", File.join(metadata_path, offline_catalog_escape_identifier(name)))
  end
  store_path
end

def offline_catalog_create_table(
  root : String,
  database_uuid : String = OFFLINE_DB_UUID,
  name : String = "events",
  uuid : String = OFFLINE_TABLE_UUID,
  columns : String = "    `left` UInt64,\n    `right` UInt64",
  engine : String = "MergeTree",
  with_part : Bool = false,
) : String
  database_metadata = offline_catalog_store_path(root, database_uuid)
  FileUtils.mkdir_p(database_metadata)
  ddl = "ATTACH TABLE _ UUID '#{uuid}'\n(\n#{columns}\n)\nENGINE = #{engine}\nORDER BY tuple()\n"
  File.write(File.join(database_metadata, "#{offline_catalog_escape_identifier(name)}.sql"), ddl)

  table_path = offline_catalog_store_path(root, uuid)
  FileUtils.mkdir_p(table_path)
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  if with_part
    FileUtils.cp_r(OFFLINE_CATALOG_FIXTURE, File.join(table_path, "all_1_1_0"))
  end
  table_path
end

def offline_catalog_database(root : String, name : String = "lab") : CrystalClick::OfflineDatabase
  CrystalClick::OfflineCatalog.open(root).database(name)
end

describe CrystalClick::OfflineCatalog do
  it "resolves Atomic UUID paths, exposes parsed table metadata, and scans selected columns" do
    with_offline_catalog_root do |root|
      database_store = offline_catalog_create_database(root, metadata_symlink: true)
      offline_catalog_create_table(root, with_part: true)

      catalog = CrystalClick::OfflineCatalog.open(root)
      catalog.database_names.should eq(["lab"])
      catalog.table_names("lab").should eq(["events"])

      catalog.databases.map(&.name).should eq(["lab"])
      database = CrystalClick::OfflineCatalog.open(root).databases.first
      database.name.should eq("lab")
      database.uuid.should eq(OFFLINE_DB_UUID)
      catalog.database("lab").uuid.should eq(database.uuid)
      database.table_names.should eq(["events"])
      tables = database.tables
      tables.map(&.name).should eq(["events"])

      table = tables.first
      database.table("events").uuid.should eq(table.uuid)
      table.name.should eq("events")
      table.uuid.should eq(OFFLINE_TABLE_UUID)
      table.engine.should eq("MergeTree")
      table.columns.map { |column| {column.name, column.type} }.should eq([
        {"left", "UInt64"},
        {"right", "UInt64"},
      ])
      table.part_candidates.size.should eq(1)
      candidate = table.part_candidates.first
      candidate.name.should eq("all_1_1_0")
      expected_part_path = File.realpath(offline_catalog_store_path(root, OFFLINE_TABLE_UUID) + "/all_1_1_0")
      candidate.path.should eq(expected_part_path)
      candidate.info.partition_id.should eq("all")
      candidate.info.min_block.should eq(1_i64)
      candidate.row_count.should eq(OFFLINE_TABLE_ROWS.to_u64)
      database_store.should eq(offline_catalog_store_path(root, OFFLINE_DB_UUID))
      direct_table = catalog.table("lab", "events")
      direct_table.uuid.should eq(table.uuid)
      direct_table.columns.map { |column| {column.name, column.type} }.should eq(
        table.columns.map { |column| {column.name, column.type} }
      )
      direct_table.part_candidates.map { |part| {part.name, part.path, part.row_count} }.should eq(
        table.part_candidates.map { |part| {part.name, part.path, part.row_count} }
      )

      seen = 0_u64
      table.scan_uint64(["left", "right"], batch_rows: 127) do |batch|
        left = batch.values_for("left")
        right = batch.values_for("right")
        left.size.should eq(right.size)
        left.size.should be <= 127
        left.each_with_index do |value, index|
          value.should eq(seen + index.to_u64)
          right[index].should eq((seen + index.to_u64) * 3_u64 + 7_u64)
        end
        seen += left.size.to_u64
      end
      seen.should eq(OFFLINE_TABLE_ROWS.to_u64)

      direct_seen = 0_u64
      direct_table.scan_uint64(["left"], batch_rows: 127) do |batch|
        direct_seen += batch.values_for("left").size.to_u64
      end
      direct_seen.should eq(seen)
    end
  end

  it "decodes canonical ClickHouse escaped database and table filenames" do
    with_offline_catalog_root do |root|
      database_store = offline_catalog_create_database(root, "lab room", metadata_symlink: true)
      offline_catalog_create_table(root, database_store.split('/').last, "foo-bar")

      catalog = CrystalClick::OfflineCatalog.open(root)
      catalog.database_names.should eq(["lab room"])
      catalog.table_names("lab room").should eq(["foo-bar"])
      catalog.table("lab room", "foo-bar").name.should eq("foo-bar")

      database = catalog.database("lab room")
      database.name.should eq("lab room")
      database.uuid.should eq(OFFLINE_DB_UUID)
      database.table_names.should eq(["foo-bar"])
      database.table("foo-bar").name.should eq("foo-bar")
    end

    with_offline_catalog_root do |root|
      outside = File.tempname("crystal-click-offline-catalog-escaped-alias-outside")
      Dir.mkdir(outside)
      offline_catalog_create_database(root, "lab room", metadata_symlink: true)
      alias_path = File.join(root, "metadata", "lab%20room")
      begin
        File.delete(alias_path)
        File.symlink(outside, alias_path)
        expect_raises(CrystalClick::InvalidPartError) do
          CrystalClick::OfflineCatalog.open(root).table_names("lab room")
        end
      ensure
        FileUtils.rm_rf(outside)
      end
    end
  end

  it "rejects noncanonical escaped metadata filenames instead of omitting them" do
    with_offline_catalog_root do |root|
      offline_catalog_create_database(root)
      File.write(File.join(root, "metadata", "bad%2fname.sql"), "ATTACH DATABASE _ UUID '#{OFFLINE_DB_UUID}'\nENGINE = Atomic\n")
      expect_raises(CrystalClick::InvalidPartError) do
        CrystalClick::OfflineCatalog.open(root).database_names
      end
    end
  end

  it "rejects statement separators and a second engine declaration after table clauses" do
    ["ORDER BY tuple(); ENGINE = Memory", "ORDER BY tuple() ENGINE = Memory"].each do |table_tail|
      with_offline_catalog_root do |root|
        offline_catalog_create_database(root)
        offline_catalog_create_table(root)
        ddl_path = File.join(offline_catalog_store_path(root, OFFLINE_DB_UUID), "events.sql")
        ddl = File.read(ddl_path).sub("ORDER BY tuple()\n", "#{table_tail}\n")
        File.write(ddl_path, ddl)

        expect_raises(CrystalClick::UnsupportedFormatError) do
          CrystalClick::OfflineCatalog.open(root).table("lab", "events")
        end
      end
    end
  end

  it "accepts the default metadata symlink only when its target is the canonical in-root UUID path" do
    with_offline_catalog_root do |root|
      default_store = offline_catalog_store_path(root, OFFLINE_DB_UUID)
      FileUtils.mkdir_p(default_store)
      File.symlink("../store/#{OFFLINE_DB_UUID[0, 3]}/#{OFFLINE_DB_UUID}", File.join(root, "metadata", "default"))
      offline_catalog_create_table(root, OFFLINE_DB_UUID, "items", OFFLINE_TABLE_UUID)

      catalog = CrystalClick::OfflineCatalog.open(root)
      catalog.database_names.should eq(["default"])
      catalog.table_names("default").should eq(["items"])
      catalog.table("default", "items").uuid.should eq(OFFLINE_TABLE_UUID)

      database = catalog.database("default")
      database.name.should eq("default")
      database.uuid.should eq(OFFLINE_DB_UUID)
      database.table_names.should eq(["items"])
      database.table("items").uuid.should eq(OFFLINE_TABLE_UUID)
    end

    with_offline_catalog_root do |root|
      outside = File.tempname("crystal-click-offline-catalog-outside")
      Dir.mkdir(outside)
      begin
        File.symlink(outside, File.join(root, "metadata", "default"))
        expect_raises(CrystalClick::InvalidPartError) do
          CrystalClick::OfflineCatalog.open(root).database_names
        end
      ensure
        FileUtils.rm_rf(outside)
      end
    end
  end

  it "rejects a store-prefix symlink that redirects UUID resolution outside the root" do
    with_offline_catalog_root do |root|
      outside = File.tempname("crystal-click-offline-catalog-store-outside")
      Dir.mkdir(outside)
      prefix_path = File.join(root, "store", OFFLINE_DB_UUID[0, 3])
      begin
        File.symlink(outside, prefix_path)
        offline_catalog_create_database(root)
        expect_raises(CrystalClick::InvalidPartError) do
          CrystalClick::OfflineCatalog.open(root).table_names("lab")
        end
      ensure
        FileUtils.rm_rf(outside)
      end
    end
  end

  it "lists metadata without parsing unrelated tables and rejects malformed selected DDL" do
    with_offline_catalog_root do |root|
      offline_catalog_create_database(root)
      offline_catalog_create_table(root, name: "good")
      database_store = offline_catalog_store_path(root, OFFLINE_DB_UUID)
      File.write(File.join(database_store, "later.sql"), "ATTACH TABLE _ UUID 'not-a-uuid'\nENGINE = MergeTree\n")

      catalog = CrystalClick::OfflineCatalog.open(root)
      catalog.table_names("lab").should eq(["good", "later"])
      catalog.table("lab", "good").name.should eq("good")
      expect_raises(CrystalClick::UnsupportedFormatError) { catalog.table("lab", "later") }

      database = catalog.database("lab")
      database.table_names.should eq(["good", "later"])
      database.table("good").name.should eq("good")
      expect_raises(CrystalClick::UnsupportedFormatError) { database.tables }
    end
  end

  it "returns database objects in sorted order without parsing their tables" do
    with_offline_catalog_root do |root|
      offline_catalog_create_database(root, "zeta", "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
      offline_catalog_create_database(root, "alpha", "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
      File.write(
        File.join(offline_catalog_store_path(root, "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"), "bad.sql"),
        "not a table DDL\n"
      )

      catalog = CrystalClick::OfflineCatalog.open(root)
      databases = catalog.databases
      databases.map(&.name).should eq(["alpha", "zeta"])
      databases.map(&.uuid).should eq([
        "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
        "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      ])
      databases.last.table_names.should eq(["bad"])
    end
  end

  it "uses bracket navigation for the same targeted database and table lookups" do
    with_offline_catalog_root do |root|
      offline_catalog_create_database(root)
      offline_catalog_create_table(root, name: "events")

      catalog = CrystalClick::OfflineCatalog.open(root)
      database = catalog["lab"]
      database.uuid.should eq(catalog.database("lab").uuid)
      database["events"].uuid.should eq(database.table("events").uuid)
      catalog["system"].table_names.should eq(["part_candidates"])
      catalog.database_names.should eq(["lab"])
      catalog.databases.map(&.name).should eq(["lab"])
      expect_raises(CrystalClick::InvalidPartError) { database["missing"] }
    end
  end

  it "fails database-object enumeration on malformed sibling database DDL but keeps targeted lookup" do
    with_offline_catalog_root do |root|
      offline_catalog_create_database(root, "alpha", "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
      offline_catalog_create_database(root, "zeta", "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
      File.write(File.join(root, "metadata", "zeta.sql"), "not an Atomic database DDL\n")

      catalog = CrystalClick::OfflineCatalog.open(root)
      catalog.database("alpha").uuid.should eq("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
      expect_raises(CrystalClick::UnsupportedFormatError) { catalog.databases }
    end
  end

  it "rejects a database object after its metadata UUID changes" do
    with_offline_catalog_root do |root|
      offline_catalog_create_database(root)
      offline_catalog_create_table(root, name: "events")
      database = offline_catalog_database(root)

      replacement_uuid = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
      offline_catalog_create_database(root, "lab", replacement_uuid)
      offline_catalog_create_table(root, replacement_uuid, "events", "cccccccc-cccc-4ccc-8ccc-cccccccccccc")

      database.uuid.should eq(OFFLINE_DB_UUID)
      expect_raises(CrystalClick::InvalidPartError) { database.table_names }
      expect_raises(CrystalClick::InvalidPartError) { database.table("events") }
    end
  end

  it "rejects using a database object through a different catalog root" do
    with_offline_catalog_root do |first_root|
      with_offline_catalog_root do |second_root|
        offline_catalog_create_database(first_root)
        offline_catalog_create_table(first_root, uuid: "11111111-1111-4111-8111-111111111111")
        database = offline_catalog_database(first_root)

        offline_catalog_create_database(second_root)
        offline_catalog_create_table(second_root, uuid: "22222222-2222-4222-8222-222222222222")
        other_catalog = CrystalClick::OfflineCatalog.open(second_root)

        database.table("events").uuid.should eq("11111111-1111-4111-8111-111111111111")
        expect_raises(CrystalClick::InvalidPartError) { other_catalog.table_names(database) }
        expect_raises(CrystalClick::InvalidPartError) { other_catalog.table(database, "events") }
        expect_raises(CrystalClick::InvalidPartError) { other_catalog.tables(database) }
      end
    end
  end

  it "keeps unsupported engine and column types inspectable but rejects their scan" do
    with_offline_catalog_root do |root|
      offline_catalog_create_database(root)
      offline_catalog_create_table(
        root,
        name: "unsupported",
        columns: "    `label` String",
        engine: "ReplacingMergeTree"
      )

      table = CrystalClick::OfflineCatalog.open(root).table("lab", "unsupported")
      table.engine.should eq("ReplacingMergeTree")
      table.columns.first.type.should eq("String")
      expect_raises(CrystalClick::UnsupportedFormatError) { table.part_candidates }
      expect_raises(CrystalClick::UnsupportedFormatError) do
        table.scan_uint64(["label"]) { |_batch| }
      end
    end
  end

  it "parses ClickHouse nested types and ignores supported column defaults" do
    with_offline_catalog_root do |root|
      offline_catalog_create_database(root)
      offline_catalog_create_table(
        root,
        name: "typed",
        columns: "    `id` UInt64,\n    `note` Nullable(String),\n    `category` LowCardinality(String),\n    `created_at` DateTime DEFAULT now()"
      )

      table = CrystalClick::OfflineCatalog.open(root).table("lab", "typed")
      table.columns.map { |column| {column.name, column.type} }.should eq([
        {"id", "UInt64"},
        {"note", "Nullable(String)"},
        {"category", "LowCardinality(String)"},
        {"created_at", "DateTime"},
      ])
    end
  end

  it "excludes detached and temporary directories and yields no batches for an empty table" do
    with_offline_catalog_root do |root|
      offline_catalog_create_database(root)
      table_path = offline_catalog_create_table(root)
      FileUtils.cp_r(OFFLINE_CATALOG_FIXTURE, File.join(table_path, "all_1_1_0"))
      FileUtils.cp_r(OFFLINE_CATALOG_FIXTURE, File.join(table_path, "detached", "stale_2_2_0"))
      FileUtils.cp_r(OFFLINE_CATALOG_FIXTURE, File.join(table_path, "tmp_insert_3_3_0"))
      FileUtils.cp_r(OFFLINE_CATALOG_FIXTURE, File.join(table_path, "tmp-fetch_all_1_1_0"))
      FileUtils.cp_r(OFFLINE_CATALOG_FIXTURE, File.join(table_path, "delete_tmp_all_1_1_0"))

      catalog_table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")
      catalog_table.part_candidates.map(&.name).should eq(["all_1_1_0"])

      empty_table_path = offline_catalog_create_table(root, name: "empty", uuid: "a95cbb65-0e4d-4d29-a754-74c29da741c3")
      empty_table = CrystalClick::OfflineCatalog.open(root).table("lab", "empty")
      empty_table.part_candidates.should be_empty
      callbacks = 0
      empty_table.scan_uint64(["left"], batch_rows: 127) { |_batch| callbacks += 1 }
      callbacks.should eq(0)
      empty_table_path.should eq(offline_catalog_store_path(root, "a95cbb65-0e4d-4d29-a754-74c29da741c3"))
    end

    with_offline_catalog_root do |root|
      offline_catalog_create_database(root)
      table_path = offline_catalog_create_table(root)
      File.symlink(OFFLINE_CATALOG_FIXTURE, File.join(table_path, "tmp-fetch_all_1_1_0"))
      expect_raises(CrystalClick::InvalidPartError) do
        CrystalClick::OfflineCatalog.open(root).table("lab", "events")
      end
    end
  end

  it "scans only the covering part when a merge result and its source coexist" do
    with_offline_catalog_root do |root|
      offline_catalog_create_database(root)
      table_path = offline_catalog_create_table(root, with_part: true)
      FileUtils.cp_r(OFFLINE_CATALOG_FIXTURE, File.join(table_path, "all_1_1_1"))

      table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")
      table.part_candidates.map(&.name).should eq(["all_1_1_0", "all_1_1_1"])
      table.resolved_scan_parts.map(&.name).should eq(["all_1_1_1"])

      {"UInt64", "numeric", "typed"}.each do |scan_kind|
        seen_rows = 0_u64
        scan = ->(batch : CrystalClick::WidePartTableBatch) do
          batch.part_name.should eq("all_1_1_1")
          seen_rows += batch.values_for("left").size.to_u64
        end
        case scan_kind
        when "UInt64"
          table.scan_uint64(["left"], batch_rows: 127, &scan)
        when "numeric"
          table.scan_numeric(["left"], batch_rows: 127, &scan)
        else
          table.scan_typed(["left"], batch_rows: 127, &scan)
        end
        seen_rows.should eq(OFFLINE_TABLE_ROWS.to_u64)
      end
    end
  end

  it "rejects transaction metadata on a selected candidate before callbacks" do
    ["txn_version.txt", "txn_version.txt.tmp"].each do |metadata_name|
      with_offline_catalog_root do |root|
        offline_catalog_create_database(root)
        table_path = offline_catalog_create_table(root, with_part: true)
        File.write(File.join(table_path, "all_1_1_0", metadata_name), "transaction metadata\n")

        table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")
        callbacks = 0
        expect_raises(CrystalClick::UnsupportedFormatError) { table.resolved_scan_parts }
        expect_raises(CrystalClick::UnsupportedFormatError) do
          table.scan_uint64(["left"], batch_rows: 127) { |_batch| callbacks += 1 }
        end
        callbacks.should eq(0)
      end
    end
  end

  it "rejects selected lightweight-delete markers before callbacks" do
    ["_row_exists", "\\x5frow_exists"].each do |marker_name|
      with_offline_catalog_root do |root|
        offline_catalog_create_database(root)
        table_path = offline_catalog_create_table(root, with_part: true)
        part_path = File.join(table_path, "all_1_1_0")
        File.write(File.join(part_path, "columns.txt"), "columns format version: 1\n3 columns:\n`left` UInt64\n`right` UInt64\n`#{marker_name}` UInt8\n")

        table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")
        callbacks = 0
        expect_raises(CrystalClick::UnsupportedFormatError) { table.resolved_scan_parts }
        expect_raises(CrystalClick::UnsupportedFormatError) do
          table.scan_uint64(["left"], batch_rows: 127) { |_batch| callbacks += 1 }
        end
        callbacks.should eq(0)
      end
    end
  end

  it "rejects selected delete-bitmap sidecars before callbacks" do
    with_offline_catalog_root do |root|
      offline_catalog_create_database(root)
      table_path = offline_catalog_create_table(root, with_part: true)
      File.write(File.join(table_path, "all_1_1_0", "delete_bitmap_7.rbm"), "bitmap\n")

      table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")
      callbacks = 0
      expect_raises(CrystalClick::UnsupportedFormatError) { table.resolved_scan_parts }
      expect_raises(CrystalClick::UnsupportedFormatError) do
        table.scan_uint64(["left"], batch_rows: 127) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    end
  end

  it "resolves mutation replacements, ordinary merges, and MAX_LEVEL covering parts" do
    with_offline_catalog_root do |root|
      offline_catalog_create_database(root)
      table_path = offline_catalog_create_table(root, with_part: true)
      FileUtils.cp_r(OFFLINE_CATALOG_FIXTURE, File.join(table_path, "all_1_1_0_3"))

      table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")
      table.resolved_scan_parts.map(&.name).should eq(["all_1_1_0_3"])
    end

    with_offline_catalog_root do |root|
      offline_catalog_create_database(root)
      table_path = offline_catalog_create_table(root, with_part: true)
      FileUtils.cp_r(OFFLINE_CATALOG_FIXTURE, File.join(table_path, "all_1_2_1"))

      table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")
      table.resolved_scan_parts.map(&.name).should eq(["all_1_2_1"])
    end

    with_offline_catalog_root do |root|
      offline_catalog_create_database(root)
      table_path = offline_catalog_create_table(root, with_part: true)
      FileUtils.cp_r(OFFLINE_CATALOG_FIXTURE, File.join(table_path, "all_1_2_999999999"))

      table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")
      table.resolved_scan_parts.map(&.name).should eq(["all_1_2_999999999"])
    end
  end

  it "rejects equal-info duplicate spellings and equal-level wide overlaps" do
    with_offline_catalog_root do |root|
      offline_catalog_create_database(root)
      table_path = offline_catalog_create_table(root, with_part: true)
      FileUtils.cp_r(OFFLINE_CATALOG_FIXTURE, File.join(table_path, "all_1_1_4294967295"))
      FileUtils.cp_r(OFFLINE_CATALOG_FIXTURE, File.join(table_path, "all_1_1_999999999"))

      table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")
      expect_raises(CrystalClick::InvalidPartError) { table.resolved_scan_parts }
    end

    with_offline_catalog_root do |root|
      offline_catalog_create_database(root)
      table_path = offline_catalog_create_table(root)
      FileUtils.cp_r(OFFLINE_CATALOG_FIXTURE, File.join(table_path, "same_1_3_2"))
      FileUtils.cp_r(OFFLINE_CATALOG_FIXTURE, File.join(table_path, "same_2_2_2"))

      table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")
      expect_raises(CrystalClick::InvalidPartError) { table.resolved_scan_parts }
    end
  end

  it "keeps disjoint parts in deterministic inventory order" do
    with_offline_catalog_root do |root|
      offline_catalog_create_database(root)
      table_path = offline_catalog_create_table(root, with_part: true)
      FileUtils.cp_r(OFFLINE_CATALOG_FIXTURE, File.join(table_path, "all_2_2_0"))
      FileUtils.cp_r(OFFLINE_CATALOG_FIXTURE, File.join(table_path, "other_1_1_0"))

      table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")
      table.resolved_scan_parts.map(&.name).should eq(["all_1_1_0", "all_2_2_0", "other_1_1_0"])
    end
  end

  it "keeps resolved scan selection scoped to exact MergeTree" do
    info = CrystalClick::MergeTreePartInfo.parse("all_1_1_0").not_nil!
    candidate = CrystalClick::OfflinePartCandidate.new("all_1_1_0", "/unused", info, 1_u64)
    table = CrystalClick::OfflineTable.new("events", "uuid", "ReplacingMergeTree", [] of CrystalClick::OfflineColumn, [candidate])

    expect_raises(CrystalClick::UnsupportedFormatError) { table.resolved_scan_parts }
  end

  it "does not mistake similar column names for lightweight-delete markers" do
    with_offline_catalog_root do |root|
      offline_catalog_create_database(root)
      table_path = offline_catalog_create_table(root, with_part: true)
      File.write(File.join(table_path, "all_1_1_0", "columns.txt"), "columns format version: 1\n3 columns:\n`left` UInt64\n`right` UInt64\n`_row_exists_backup` UInt8\n")

      table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")
      table.resolved_scan_parts.map(&.name).should eq(["all_1_1_0"])
    end
  end

  it "rejects transaction metadata on covered candidates, including symlinks" do
    ["txn_version.txt", "txn_version.txt.tmp"].each do |metadata_name|
      with_offline_catalog_root do |root|
        offline_catalog_create_database(root)
        table_path = offline_catalog_create_table(root, with_part: true)
        FileUtils.cp_r(OFFLINE_CATALOG_FIXTURE, File.join(table_path, "all_1_1_1"))
        File.write(File.join(table_path, "all_1_1_0", metadata_name), "transaction metadata\n")

        table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")
        expect_raises(CrystalClick::UnsupportedFormatError) { table.resolved_scan_parts }
      end
    end

    with_offline_catalog_root do |root|
      offline_catalog_create_database(root)
      table_path = offline_catalog_create_table(root, with_part: true)
      FileUtils.cp_r(OFFLINE_CATALOG_FIXTURE, File.join(table_path, "all_1_1_1"))
      File.symlink("missing-target", File.join(table_path, "all_1_1_0", "txn_version.txt"))

      table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")
      expect_raises(CrystalClick::UnsupportedFormatError) { table.resolved_scan_parts }
    end
  end

  it "does not fall back to covered children when the selected covering part is corrupt" do
    with_offline_catalog_root do |root|
      offline_catalog_create_database(root)
      table_path = offline_catalog_create_table(root, with_part: true)
      covering_path = File.join(table_path, "all_1_1_1")
      FileUtils.cp_r(OFFLINE_CATALOG_FIXTURE, covering_path)
      selected_stream = CrystalClick::WidePart.open(covering_path, "left")
      File.delete(selected_stream.data_path)

      table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")
      table.resolved_scan_parts.map(&.name).should eq(["all_1_1_1"])
      callbacks = 0
      expect_raises(CrystalClick::Error) do
        table.scan_uint64(["left"], batch_rows: 127) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    end
  end

  it "rejects overlapping candidates before invoking a scan callback" do
    with_offline_catalog_root do |root|
      offline_catalog_create_database(root)
      table_path = offline_catalog_create_table(root, with_part: true)
      FileUtils.cp_r(OFFLINE_CATALOG_FIXTURE, File.join(table_path, "same_0_1_0"))
      FileUtils.cp_r(OFFLINE_CATALOG_FIXTURE, File.join(table_path, "same_1_2_0"))

      table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")
      table.part_candidates.map(&.name).should eq(["all_1_1_0", "same_0_1_0", "same_1_2_0"])
      callbacks = 0
      error = expect_raises(CrystalClick::InvalidPartError) do
        table.scan_uint64(["left", "right"], batch_rows: 127) { |_batch| callbacks += 1 }
      end
      error.message.not_nil!.should contain("overlap")
      callbacks.should eq(0)
    end
  end

  it "fails closed for malformed part-like candidates and schema disagreement" do
    with_offline_catalog_root do |root|
      offline_catalog_create_database(root)
      table_path = offline_catalog_create_table(root)
      Dir.mkdir(File.join(table_path, "bad_0_1_x"))
      expect_raises(CrystalClick::InvalidPartError) do
        CrystalClick::OfflineCatalog.open(root).table("lab", "events")
      end
    end

    with_offline_catalog_root do |root|
      offline_catalog_create_database(root)
      table_path = offline_catalog_create_table(root)
      Dir.mkdir(File.join(table_path, "all_1_1"))
      expect_raises(CrystalClick::InvalidPartError) do
        CrystalClick::OfflineCatalog.open(root).table("lab", "events")
      end
    end

    with_offline_catalog_root do |root|
      offline_catalog_create_database(root)
      table_path = offline_catalog_create_table(root, with_part: true)
      File.write(File.join(table_path, "all_1_1_0", "columns.txt"), "columns format version: 1\n2 columns:\n`left` String\n`right` UInt64\n")
      table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")
      expect_raises(CrystalClick::UnsupportedFormatError) do
        table.scan_uint64(["left", "right"], batch_rows: 127) { |_batch| }
      end
    end
  end

  it "preserves callback exceptions and rejects selected columns outside table UInt64 declarations" do
    with_offline_catalog_root do |root|
      offline_catalog_create_database(root)
      offline_catalog_create_table(root, with_part: true)
      table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")

      error = expect_raises(OfflineCatalogSpecStop) do
        table.scan_uint64(["left"], batch_rows: 127) { |_batch| raise OfflineCatalogSpecStop.new("stop at caller") }
      end
      error.message.should eq("stop at caller")

      expect_raises(CrystalClick::UnsupportedFormatError) do
        table.scan_uint64(["missing"]) { |_batch| }
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        table.scan_uint64(["label"]) { |_batch| }
      end
    end
  end

  it "materializes deterministic owned values for synthetic system part candidates" do
    with_offline_catalog_root do |root|
      alpha_database_uuid = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
      zeta_database_uuid = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
      alpha_table_uuid = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
      zeta_table_uuid = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
      offline_catalog_create_database(root, "zeta", zeta_database_uuid)
      offline_catalog_create_database(root, "alpha", alpha_database_uuid)
      alpha_path = offline_catalog_create_table(root, alpha_database_uuid, "events", alpha_table_uuid, with_part: true)
      FileUtils.cp_r(OFFLINE_CATALOG_FIXTURE, File.join(alpha_path, "all_2_2_0"))
      File.write(File.join(alpha_path, "all_1_1_0", "count.txt"), "11\n")
      File.write(File.join(alpha_path, "all_2_2_0", "count.txt"), "17\n")
      zeta_path = offline_catalog_create_table(root, zeta_database_uuid, "events", zeta_table_uuid, with_part: true)
      File.write(File.join(zeta_path, "all_1_1_0", "count.txt"), "13\n")

      catalog = CrystalClick::OfflineCatalog.open(root)
      catalog.database_names.should eq(["alpha", "zeta"])
      system_database = catalog["system"]
      system_database.name.should eq("system")
      system_database.table_names.should eq(["part_candidates"])
      system_database.tables.map(&.name).should eq(["part_candidates"])
      expect_raises(CrystalClick::UnsupportedFormatError) { system_database.uuid }
      forged = CrystalClick::OfflineDatabase.new(catalog, "lab", "fabricated-uuid", true)
      expect_raises(CrystalClick::UnsupportedFormatError) { forged.uuid }
      expect_raises(CrystalClick::InvalidPartError) { forged.table_names }

      part_candidates = system_database["part_candidates"]
      part_candidates.name.should eq("part_candidates")
      part_candidates.columns.map(&.name).should eq(["database", "table", "name", "partition_id", "rows"])
      expect_raises(CrystalClick::UnsupportedFormatError) { part_candidates.uuid }
      expect_raises(CrystalClick::UnsupportedFormatError) { part_candidates["active"] }

      part_candidates["database"].values.map { |value| value.as(String) }.should eq(["alpha", "alpha", "zeta"])
      part_candidates["table"].values.map { |value| value.as(String) }.should eq(["events", "events", "events"])
      part_candidates["name"].values.map { |value| value.as(String) }.should eq(["all_1_1_0", "all_2_2_0", "all_1_1_0"])
      part_candidates["partition_id"].values.map { |value| value.as(String) }.should eq(["all", "all", "all"])
      part_candidates["rows"].values.map { |value| value.as(UInt64) }.should eq([11_u64, 17_u64, 13_u64])
      caller_owned = part_candidates["database"].values
      caller_owned << "caller-only"
      part_candidates["database"].values.map { |value| value.as(String) }.should eq(["alpha", "alpha", "zeta"])
      CrystalClick::OfflineCatalog.open(root)["system"]["part_candidates"]["rows"].values.map { |value| value.as(UInt64) }.should eq([11_u64, 17_u64, 13_u64])
    end
  end

  it "defers part reads until values are requested and rejects covering overlap" do
    with_offline_catalog_root do |root|
      alpha_database_uuid = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
      zeta_database_uuid = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
      offline_catalog_create_database(root, "alpha", alpha_database_uuid)
      offline_catalog_create_database(root, "zeta", zeta_database_uuid)
      offline_catalog_create_table(root, alpha_database_uuid, "events", "cccccccc-cccc-4ccc-8ccc-cccccccccccc", with_part: true)
      later_path = offline_catalog_create_table(root, zeta_database_uuid, "events", "dddddddd-dddd-4ddd-8ddd-dddddddddddd", with_part: true)
      count_path = File.join(later_path, "all_1_1_0", "count.txt")
      File.delete(count_path)

      selected_rows = CrystalClick::OfflineCatalog.open(root)["system"]["part_candidates"]["rows"]
      expect_raises(CrystalClick::InvalidPartError) { selected_rows.values }
    end

    with_offline_catalog_root do |root|
      offline_catalog_create_database(root)
      table_path = offline_catalog_create_table(root, with_part: true)
      FileUtils.cp_r(OFFLINE_CATALOG_FIXTURE, File.join(table_path, "all_1_1_1"))

      selected_rows = CrystalClick::OfflineCatalog.open(root)["system"]["part_candidates"]["rows"]
      error = expect_raises(CrystalClick::InvalidPartError) { selected_rows.values }
      error.message.not_nil!.should contain("overlap")
    end
  end

  it "fails closed on a physical system database and unsupported MergeTree-family parts" do
    with_offline_catalog_root do |root|
      offline_catalog_create_database(root, "system", "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")
      catalog = CrystalClick::OfflineCatalog.open(root)
      catalog.database_names.should eq(["system"])
      expect_raises(CrystalClick::InvalidPartError) { catalog["system"] }
    end

    with_offline_catalog_root do |root|
      database_uuid = "ffffffff-ffff-4fff-8fff-ffffffffffff"
      offline_catalog_create_database(root, "lab", database_uuid)
      offline_catalog_create_table(root, database_uuid, "replacing", "11111111-1111-4111-8111-111111111111", engine: "ReplacingMergeTree", with_part: true)

      selected_rows = CrystalClick::OfflineCatalog.open(root)["system"]["part_candidates"]["rows"]
      expect_raises(CrystalClick::UnsupportedFormatError) { selected_rows.values }
    end

    with_offline_catalog_root do |root|
      database_uuid = "44444444-4444-4444-8444-444444444444"
      offline_catalog_create_database(root, "lab", database_uuid)
      offline_catalog_create_table(root, database_uuid, "replacing", "55555555-5555-4555-8555-555555555555", engine: "replacingmergetree", with_part: true)

      selected_rows = CrystalClick::OfflineCatalog.open(root)["system"]["part_candidates"]["rows"]
      expect_raises(CrystalClick::UnsupportedFormatError) { selected_rows.values }
    end

    with_offline_catalog_root do |root|
      database_uuid = "22222222-2222-4222-8222-222222222222"
      offline_catalog_create_database(root, "lab", database_uuid)
      offline_catalog_create_table(root, database_uuid, "memory", "33333333-3333-4333-8333-333333333333", engine: "Memory")

      selected_rows = CrystalClick::OfflineCatalog.open(root)["system"]["part_candidates"]["rows"]
      selected_rows.values.should be_empty
    end
  end

  it "keeps physical column selection lazy and rejects materialization in this slice" do
    with_offline_catalog_root do |root|
      offline_catalog_create_database(root)
      offline_catalog_create_table(root, with_part: true)

      selected = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]["left"]
      expect_raises(CrystalClick::UnsupportedFormatError) { selected.values }
      values = [] of UInt64
      CrystalClick::OfflineCatalog.open(root)["lab"]["events"].scan_uint64(["left"], batch_rows: 127) do |batch|
        values.concat(batch.values_for("left"))
      end
      values.size.should eq(OFFLINE_TABLE_ROWS)
      values.first.should eq(0_u64)
      values.last.should eq((OFFLINE_TABLE_ROWS - 1).to_u64)
    end
  end

  it "enforces the global projected-part cap at its boundary" do
    with_offline_catalog_root do |root|
      catalog = OfflineCatalogCapacityProbe.new(root)
      catalog.validate_projected_candidates(CrystalClick::OfflineCatalog::MAX_PART_CANDIDATES)
      expect_raises(CrystalClick::BoundsError) do
        catalog.validate_projected_candidates(CrystalClick::OfflineCatalog::MAX_PART_CANDIDATES + 1)
      end
    end
  end

  it "stops incrementally at the projected candidate cap before visiting later table counts" do
    with_offline_catalog_root do |root|
      database_uuid = "66666666-6666-4666-8666-666666666666"
      offline_catalog_create_database(root, "lab", database_uuid)
      first_table_path = offline_catalog_create_table(root, database_uuid, "a_events", "77777777-7777-4777-8777-777777777777", with_part: true)
      second_part_path = File.join(first_table_path, "all_2_2_0")
      FileUtils.cp_r(OFFLINE_CATALOG_FIXTURE, second_part_path)
      File.write(File.join(second_part_path, "count.txt"), "17\n")

      later_table_path = offline_catalog_create_table(root, database_uuid, "z_events", "88888888-8888-4888-8888-888888888888", with_part: true)
      File.delete(File.join(later_table_path, "all_1_1_0", "count.txt"))

      selected_rows = OfflineCatalogCapacityProbe.new(root, 1)["system"]["part_candidates"]["rows"]
      error = expect_raises(CrystalClick::BoundsError) { selected_rows.values }
      error.message.not_nil!.should contain("projected candidate count exceeds limit")
    end
  end
end
