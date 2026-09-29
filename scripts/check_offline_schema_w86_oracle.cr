require "file_utils"
require "../src/crystal_click"

W86_DATABASE = "w86_offline"
W86_SOURCE   = "w86_source"
W86_VIEW     = "w86_mv"
W86_PARTIAL  = "w86_partial"

def assert_w86(condition : Bool, message : String) : Nil
  raise "W86 stock oracle: #{message}" unless condition
end

def run_w86_clickhouse(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  status = Process.run(
    binary,
    ["local", "--path", store, "--query", query],
    output: output,
    error: Process::Redirect::Inherit
  )
  raise "ClickHouse query failed (status #{status.exit_code}): #{query}" unless status.success?
  output.to_s
end

def one_w86_row(binary : String, store : String, query : String) : Array(String)
  rows = run_w86_clickhouse(binary, store, query).lines.map(&.strip).reject(&.empty?)
  raise "expected one ClickHouse row, got #{rows.size}: #{query}" unless rows.size == 1
  rows[0].split('\t')
end

def snapshot_w86_rows(snapshot : String, label : String) : Array(Array(String))
  snapshot.lines.map { |line| line.split('\t') }.select { |columns| columns[0]? == label }
end

def one_snapshot_w86_row(snapshot : String, label : String) : Array(String)
  rows = snapshot_w86_rows(snapshot, label)
  raise "expected one #{label.inspect} snapshot row, got #{rows.size}" unless rows.size == 1
  rows[0]
end

def w86_store_uuid_dir(store : String, uuid : String) : String
  File.join(store, "store", uuid[0, 3], uuid)
end

def normalize_w86_whitespace(text : String) : String
  text.gsub(/\s+/, " ").strip
end

binary = ENV.fetch("CLICKHOUSE_BIN")
store = ENV.fetch("CLICKHOUSE_STORE")

stock_snapshot = run_w86_clickhouse(binary, store, <<-SQL)
CREATE DATABASE #{W86_DATABASE} ENGINE = Atomic;
CREATE TABLE #{W86_DATABASE}.#{W86_SOURCE}
(
    id UInt64,
    tag String,
    amount UInt64,
    PROJECTION by_tag (SELECT tag, amount ORDER BY tag)
)
ENGINE = MergeTree
ORDER BY id
;
CREATE MATERIALIZED VIEW #{W86_DATABASE}.#{W86_VIEW}
ENGINE = MergeTree
ORDER BY id
AS SELECT id, tag, amount FROM #{W86_DATABASE}.#{W86_SOURCE}
;

# Keep two parent parts around an ADD PROJECTION. This probes only the persisted
# per-part artifact boundary; it does not read or scan projection data. STOP
# MERGES and both inserts run in this same local process. A later local process
# would have merges enabled again and could merge away the partial-coverage state.
CREATE TABLE #{W86_DATABASE}.#{W86_PARTIAL}
(
    id UInt64,
    tag String,
    amount UInt64
)
ENGINE = MergeTree
ORDER BY id
SETTINGS min_rows_for_wide_part = 0, min_bytes_for_wide_part = 0
;
SYSTEM STOP MERGES #{W86_DATABASE}.#{W86_PARTIAL};
INSERT INTO #{W86_DATABASE}.#{W86_PARTIAL} VALUES (1, 'first', 10);
ALTER TABLE #{W86_DATABASE}.#{W86_PARTIAL} ADD PROJECTION by_tag (SELECT tag, amount ORDER BY tag);
INSERT INTO #{W86_DATABASE}.#{W86_PARTIAL} VALUES (2, 'second', 20);

SELECT 'database', uuid FROM system.databases WHERE name='#{W86_DATABASE}' FORMAT TSVRaw;
SELECT 'view', uuid, engine FROM system.tables WHERE database='#{W86_DATABASE}' AND name='#{W86_VIEW}' FORMAT TSVRaw;
SELECT 'inner_count', toString(count()) FROM system.tables WHERE database='#{W86_DATABASE}' AND startsWith(name, '.inner_id.') FORMAT TSVRaw;
SELECT 'inner', name, uuid, engine FROM system.tables WHERE database='#{W86_DATABASE}' AND startsWith(name, '.inner_id.') FORMAT TSVRaw;
SELECT 'partial_path', path FROM system.parts WHERE database='#{W86_DATABASE}' AND table='#{W86_PARTIAL}' AND active ORDER BY min_block_number FORMAT TSVRaw;
SQL

database_snapshot = one_snapshot_w86_row(stock_snapshot, "database")
database_uuid = database_snapshot[1]
database_metadata = w86_store_uuid_dir(store, database_uuid)
view_row = one_snapshot_w86_row(stock_snapshot, "view")
view_uuid = view_row[1]
assert_w86(view_row[2] == "MaterializedView", "stock view engine was #{view_row[2].inspect}")
inner_count_row = one_snapshot_w86_row(stock_snapshot, "inner_count")
inner_count = inner_count_row[1].to_i
assert_w86(inner_count == 1, "expected one persisted hidden inner target, got #{inner_count}")
inner_row = one_snapshot_w86_row(stock_snapshot, "inner")
inner_name, inner_uuid, inner_engine = inner_row[1], inner_row[2], inner_row[3]
assert_w86(inner_name == ".inner_id.#{view_uuid}", "unexpected hidden inner target name #{inner_name.inspect}")
assert_w86(inner_engine == "MergeTree", "hidden inner target engine was #{inner_engine.inspect}")
assert_w86(inner_uuid != view_uuid, "view UUID and inner target UUID unexpectedly match")
assert_w86(Dir.exists?(w86_store_uuid_dir(store, inner_uuid)), "inner target store directory is missing")
assert_w86(!Dir.exists?(w86_store_uuid_dir(store, view_uuid)), "stock created a store directory under the view UUID")

view_metadata_path = File.join(database_metadata, "w86_mv.sql")
view_ddl = File.read(view_metadata_path)
assert_w86(view_ddl.starts_with?("ATTACH MATERIALIZED VIEW _ UUID '#{view_uuid}'"),
  "persisted MV DDL does not begin with ATTACH MATERIALIZED VIEW and its UUID")
assert_w86(view_ddl.includes?("TO INNER UUID '#{inner_uuid}'"), "persisted MV DDL lost TO INNER UUID")
assert_w86(view_ddl.includes?("ENGINE = MergeTree"), "persisted MV DDL lost its inner engine clause")
assert_w86(view_ddl.includes?("AS SELECT"), "persisted MV DDL lost its SELECT declaration")

source_ddl_path = File.join(database_metadata, "w86_source.sql")
source_ddl = File.read(source_ddl_path)
assert_w86(source_ddl.includes?("PROJECTION by_tag"), "persisted source DDL lost its PROJECTION")

encoded_inner_name = "%2Einner_id%2E#{view_uuid.gsub("-", "%2D")}.sql"
inner_metadata = File.read(File.join(database_metadata, encoded_inner_name))
assert_w86(inner_metadata.starts_with?("ATTACH TABLE _ UUID '#{inner_uuid}'"),
  "hidden inner target metadata does not carry its distinct UUID")

partial_paths = snapshot_w86_rows(stock_snapshot, "partial_path").map { |columns| columns[1] }
assert_w86(partial_paths.size == 2, "partial-projection fixture has #{partial_paths.size} parent parts, expected 2")
projection_artifacts = partial_paths.map { |path| Dir.exists?(File.join(path, "by_tag.proj")) }
assert_w86(projection_artifacts == [false, true],
  "stock partial-coverage probe expected one old part without and one new part with by_tag.proj, got #{projection_artifacts.inspect}")

catalog = CrystalClick::OfflineCatalog.open(store)
catalog_tables = catalog.database(W86_DATABASE).tables
catalog_view = catalog.table(W86_DATABASE, W86_VIEW)
catalog_source = catalog.table(W86_DATABASE, W86_SOURCE)
catalog_partial = catalog.table(W86_DATABASE, W86_PARTIAL)

assert_w86(catalog_tables.any? { |table| table.name == W86_VIEW }, "catalog-wide enumeration omitted the MV")
assert_w86(catalog_view.engine == "MaterializedView", "catalog logical MV engine is #{catalog_view.engine.inspect}")
assert_w86(catalog_view.kind == :materialized_view, "catalog MV kind is #{catalog_view.kind.inspect}")
assert_w86(catalog_view.uuid == view_uuid, "catalog MV UUID differs from persisted ATTACH UUID")
assert_w86(catalog_view.metadata_ddl == view_ddl, "catalog MV metadata_ddl differs from persisted stock DDL")
assert_w86(catalog_view.projections.empty?, "MV unexpectedly exposes table projection declarations")

assert_w86(catalog_source.kind == :table, "ordinary source table kind is #{catalog_source.kind.inspect}")
assert_w86(catalog_source.metadata_ddl == source_ddl, "source metadata_ddl differs from persisted stock DDL")
source_projection_pairs = catalog_source.projections.map do |projection|
  {projection.name, normalize_w86_whitespace(projection.definition)}
end
assert_w86(source_projection_pairs == [{"by_tag", "SELECT tag, amount ORDER BY tag"}],
  "source projection metadata differs: #{source_projection_pairs.inspect}")
assert_w86(catalog_source.columns.map(&.name) == ["id", "tag", "amount"],
  "projection declaration leaked into ordinary source columns")

partial_ddl = File.read(File.join(database_metadata, "w86_partial.sql"))
assert_w86(catalog_partial.kind == :table, "partial table kind is #{catalog_partial.kind.inspect}")
assert_w86(catalog_partial.metadata_ddl == partial_ddl, "partial table metadata_ddl differs from persisted stock DDL")
partial_projection_pairs = catalog_partial.projections.map do |projection|
  {projection.name, normalize_w86_whitespace(projection.definition)}
end
assert_w86(partial_projection_pairs == [{"by_tag", "SELECT tag, amount ORDER BY tag"}],
  "partial table projection metadata differs: #{partial_projection_pairs.inspect}")
assert_w86(catalog_partial.columns.map(&.name) == ["id", "tag", "amount"],
  "projection declaration leaked into ordinary partial-table columns")
catalog_parts = catalog_partial.part_candidates
assert_w86(catalog_parts.size == 2, "catalog partial table exposes #{catalog_parts.size} parent part candidates, expected 2")
catalog_artifacts = catalog_parts.sort_by(&.name).map { |part| Dir.exists?(File.join(part.path, "by_tag.proj")) }
assert_w86(catalog_artifacts == [false, true],
  "catalog parent parts disagree with the stock partial-coverage probe: #{catalog_artifacts.inspect}")

view_scan_rejected = false
view_callbacks = 0
begin
  catalog_view.scan_typed(["tag"]) do |_batch|
    view_callbacks += 1
    nil
  end
rescue CrystalClick::UnsupportedFormatError
  view_scan_rejected = true
end
assert_w86(view_scan_rejected && view_callbacks == 0, "MV row scan was not rejected before callbacks")

candidate_tables = catalog.table("system", "part_candidates").materialize_selected_values("table").map(&.as(String))
assert_w86(candidate_tables.count { |name| name == W86_PARTIAL } == 2,
  "system.part_candidates did not inventory both ordinary parent parts")
assert_w86(!candidate_tables.includes?(W86_VIEW), "system.part_candidates attributed a physical part to the MV")
puts "PASS W86 stock metadata oracle on ClickHouse #{run_w86_clickhouse(binary, store, "SELECT version() FORMAT TSVRaw").strip}"
puts "  persisted Atomic ATTACH MATERIALIZED VIEW has a distinct inner UUID and no view-UUID store directory"
puts "  catalog MV/table kinds, exact metadata DDL, and named projection definition match persisted files"
puts "  two-part projection artifact probe observed [absent, present]; no projection scan was performed"
