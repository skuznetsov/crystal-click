require "./spec_helper"

OFFLINE_CATALOG_FIXTURE = File.expand_path("../test/fixtures/public/wide_two_uint64/part", __DIR__)
OFFLINE_DB_UUID         = "835e7af8-f57c-42b8-bcb0-863f3de0ca51"
OFFLINE_TABLE_UUID      = "1f068934-2439-44ce-9501-c2dc252a9027"
OFFLINE_TABLE_ROWS      = 17_001

class OfflineCatalogSpecStop < Exception
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

describe CrystalClick::OfflineCatalog do
  it "resolves Atomic UUID paths, exposes parsed table metadata, and scans selected columns" do
    with_offline_catalog_root do |root|
      database_store = offline_catalog_create_database(root, metadata_symlink: true)
      offline_catalog_create_table(root, with_part: true)

      catalog = CrystalClick::OfflineCatalog.open(root)
      catalog.database_names.should eq(["lab"])
      catalog.table_names("lab").should eq(["events"])

      table = catalog.table("lab", "events")
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
end
