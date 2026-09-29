require "file_utils"
require "set"
require "../src/crystal_click"

W88_TRIGGER_DATABASE   = "w88_mv_trigger"
W88_RECOMPUTE_DATABASE = "w88_mv_recompute"

alias W88Row = Tuple(UInt64, String)
alias W88StockRow = Tuple(String, String)

def assert_w88(condition : Bool, message : String) : Nil
  raise "W88 stock oracle: #{message}" unless condition
end

def run_w88_clickhouse(binary : String, store : String, query : String) : String
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

def w88_rows(snapshot : String, label : String) : Array(Array(String))
  snapshot.lines
    .map(&.strip)
    .reject(&.empty?)
    .map(&.split('\t'))
    .select { |columns| columns[0]? == label }
end

def w88_stock_rows(snapshot : String, label : String) : Array(W88StockRow)
  w88_rows(snapshot, label).map do |columns|
    raise "malformed #{label} row: #{columns.inspect}" unless columns.size == 3
    {columns[1], columns[2]}
  end
end

def normalize_w88_whitespace(text : String) : String
  text.gsub(/\s+/, " ").strip
end

def w88_store_uuid_dir(store : String, uuid : String) : String
  File.join(store, "store", uuid[0, 3], uuid)
end

def normalize_w88_path(path : String) : String
  expanded = File.expand_path(path)
  expanded == "/" ? expanded : expanded.rstrip('/')
end

def read_w88_source_rows(table : CrystalClick::OfflineTable) : Array(W88Row)
  rows = [] of W88Row
  table.scan_typed(["k", "v"], batch_rows: 2) do |batch|
    keys = batch.values_for("k", UInt64)
    values = batch.strings_for("v")
    raise "W88 source batch columns are not row-aligned" unless keys.size == values.size
    keys.each_index do |index|
      rows << {keys[index], values[index].dup}
    end
  end
  rows
end

def w88_hex_rows(rows : Array(W88Row)) : Array(W88StockRow)
  rows.map { |row| {row[0].to_s, row[1].to_slice.hexstring.upcase} }
end

binary = ENV.fetch("CLICKHOUSE_BIN")
root = ENV.fetch("TMP_ROOT")
trigger_store = File.join(root, "stock-trigger-store")
recompute_store = File.join(root, "crystal-recompute-store")

# Stock control: two source INSERT blocks must fire the MV twice and preserve
# corresponding source/target parts while merges are stopped in this process.
trigger_snapshot = run_w88_clickhouse(binary, trigger_store, <<-SQL)
CREATE DATABASE #{W88_TRIGGER_DATABASE} ENGINE = Atomic;
CREATE TABLE #{W88_TRIGGER_DATABASE}.source
(
    `k` UInt64,
    `v` String
)
ENGINE = MergeTree
ORDER BY k
SETTINGS min_rows_for_wide_part = 0, min_bytes_for_wide_part = 0;
CREATE TABLE #{W88_TRIGGER_DATABASE}.target
(
    `k` UInt64,
    `v` String
)
ENGINE = MergeTree
ORDER BY k
SETTINGS min_rows_for_wide_part = 0, min_bytes_for_wide_part = 0;
SYSTEM STOP MERGES #{W88_TRIGGER_DATABASE}.source;
SYSTEM STOP MERGES #{W88_TRIGGER_DATABASE}.target;
CREATE MATERIALIZED VIEW #{W88_TRIGGER_DATABASE}.mv
TO #{W88_TRIGGER_DATABASE}.target
AS SELECT k, v FROM #{W88_TRIGGER_DATABASE}.source;
INSERT INTO #{W88_TRIGGER_DATABASE}.source VALUES (1, 'one'), (2, 'two');
INSERT INTO #{W88_TRIGGER_DATABASE}.source VALUES (3, 'three');
SELECT 'trigger_source_row', toString(k), hex(v) FROM #{W88_TRIGGER_DATABASE}.source ORDER BY k FORMAT TSVRaw;
SELECT 'trigger_target_row', toString(k), hex(v) FROM #{W88_TRIGGER_DATABASE}.target ORDER BY k FORMAT TSVRaw;
SELECT 'trigger_source_part', name, toString(rows) FROM system.parts WHERE database='#{W88_TRIGGER_DATABASE}' AND table='source' AND active ORDER BY min_block_number FORMAT TSVRaw;
SELECT 'trigger_target_part', name, toString(rows) FROM system.parts WHERE database='#{W88_TRIGGER_DATABASE}' AND table='target' AND active ORDER BY min_block_number FORMAT TSVRaw;
SQL

expected_trigger_rows = [{"1", "6F6E65"}, {"2", "74776F"}, {"3", "7468726565"}]
trigger_source_rows = w88_stock_rows(trigger_snapshot, "trigger_source_row")
trigger_target_rows = w88_stock_rows(trigger_snapshot, "trigger_target_row")
assert_w88(trigger_source_rows == expected_trigger_rows, "stock source rows differed: #{trigger_source_rows.inspect}")
assert_w88(trigger_target_rows == expected_trigger_rows, "stock MV trigger did not mirror exact rows: #{trigger_target_rows.inspect}")

trigger_source_parts = w88_rows(trigger_snapshot, "trigger_source_part")
trigger_target_parts = w88_rows(trigger_snapshot, "trigger_target_part")
assert_w88(trigger_source_parts.size == 2 && trigger_target_parts.size == 2,
  "stock two-block fixture did not retain two source/target parts: source=#{trigger_source_parts.inspect}, target=#{trigger_target_parts.inspect}")
source_shapes = trigger_source_parts.map { |columns| {columns[1], columns[2]} }
target_shapes = trigger_target_parts.map { |columns| {columns[1], columns[2]} }
assert_w88(source_shapes == target_shapes,
  "stock source and trigger-target part identities/row counts differ: #{source_shapes.inspect} vs #{target_shapes.inspect}")

# Separate no-backfill fixture: insert source data first, then create its MV.
recompute_snapshot = run_w88_clickhouse(binary, recompute_store, <<-SQL)
CREATE DATABASE #{W88_RECOMPUTE_DATABASE} ENGINE = Atomic;
CREATE TABLE #{W88_RECOMPUTE_DATABASE}.source
(
    `k` UInt64,
    `v` String
)
ENGINE = MergeTree
ORDER BY k
SETTINGS min_rows_for_wide_part = 0, min_bytes_for_wide_part = 0;
CREATE TABLE #{W88_RECOMPUTE_DATABASE}.target
(
    `k` UInt64,
    `v` String
)
ENGINE = MergeTree
ORDER BY k
SETTINGS min_rows_for_wide_part = 0, min_bytes_for_wide_part = 0;
SYSTEM STOP MERGES #{W88_RECOMPUTE_DATABASE}.source;
SYSTEM STOP MERGES #{W88_RECOMPUTE_DATABASE}.target;
INSERT INTO #{W88_RECOMPUTE_DATABASE}.source VALUES (11, 'alpha'), (12, 'beta'), (13, 'gamma');
CREATE MATERIALIZED VIEW #{W88_RECOMPUTE_DATABASE}.mv
TO #{W88_RECOMPUTE_DATABASE}.target
AS SELECT k, v FROM #{W88_RECOMPUTE_DATABASE}.source;
SELECT 'recompute_source_row', toString(k), hex(v) FROM #{W88_RECOMPUTE_DATABASE}.source ORDER BY k FORMAT TSVRaw;
SELECT 'recompute_target_count', toString(count()) FROM #{W88_RECOMPUTE_DATABASE}.target FORMAT TSVRaw;
SELECT 'recompute_source_part', name, toString(rows), path FROM system.parts WHERE database='#{W88_RECOMPUTE_DATABASE}' AND table='source' AND active ORDER BY min_block_number FORMAT TSVRaw;
SELECT 'recompute_target_part_count', toString(count()) FROM system.parts WHERE database='#{W88_RECOMPUTE_DATABASE}' AND table='target' AND active FORMAT TSVRaw;
SELECT 'recompute_object', name, uuid, engine FROM system.tables WHERE database='#{W88_RECOMPUTE_DATABASE}' AND name IN ('source', 'target', 'mv') ORDER BY name FORMAT TSVRaw;
SELECT 'recompute_database', uuid FROM system.databases WHERE name='#{W88_RECOMPUTE_DATABASE}' FORMAT TSVRaw;
SELECT 'recompute_target_path', data_paths[1] FROM system.tables WHERE database='#{W88_RECOMPUTE_DATABASE}' AND name='target' FORMAT TSVRaw;
SQL

expected_source_rows = [{"11", "616C706861"}, {"12", "62657461"}, {"13", "67616D6D61"}]
stock_source_rows = w88_stock_rows(recompute_snapshot, "recompute_source_row")
assert_w88(stock_source_rows == expected_source_rows, "source-before-MV rows differed: #{stock_source_rows.inspect}")
assert_w88(w88_rows(recompute_snapshot, "recompute_target_count") == [["recompute_target_count", "0"]],
  "stock MV unexpectedly backfilled its TO target")
assert_w88(w88_rows(recompute_snapshot, "recompute_target_part_count") == [["recompute_target_part_count", "0"]],
  "stock MV unexpectedly created target parts")

source_parts = w88_rows(recompute_snapshot, "recompute_source_part")
assert_w88(source_parts.size == 1 && source_parts[0].size == 4 && source_parts[0][2] == "3",
  "source-before-MV fixture did not retain one 3-row part: #{source_parts.inspect}")
source_part_name = source_parts[0][1]
assert_w88(source_part_name.starts_with?("all_"), "stock source part is not an all-part: #{source_part_name.inspect}")

objects = w88_rows(recompute_snapshot, "recompute_object")
assert_w88(objects.size == 3 && objects.all? { |columns| columns.size == 4 },
  "stock Atomic database did not expose source/target/view UUIDs: #{objects.inspect}")
object_map = objects.to_h { |columns| {columns[1], {columns[2], columns[3]}} }
source_uuid, source_engine = object_map["source"]
target_uuid, target_engine = object_map["target"]
view_uuid, view_engine = object_map["mv"]
assert_w88(source_engine == "MergeTree" && target_engine == "MergeTree" && view_engine == "MaterializedView",
  "stock source/target/view engines differed: #{object_map.inspect}")
assert_w88(Set{source_uuid, target_uuid, view_uuid}.size == 3,
  "stock source, target, and view UUIDs are not distinct: #{object_map.inspect}")

database_rows = w88_rows(recompute_snapshot, "recompute_database")
assert_w88(database_rows.size == 1 && database_rows[0].size == 2,
  "stock Atomic database UUID missing: #{database_rows.inspect}")
database_uuid = database_rows[0][1]
database_metadata_dir = w88_store_uuid_dir(recompute_store, database_uuid)
source_ddl = File.read(File.join(database_metadata_dir, "source.sql"))
target_ddl = File.read(File.join(database_metadata_dir, "target.sql"))
view_ddl = File.read(File.join(database_metadata_dir, "mv.sql"))
assert_w88(source_ddl.starts_with?("ATTACH TABLE _ UUID '#{source_uuid}'"), "persisted source UUID differs from system.tables")
assert_w88(target_ddl.starts_with?("ATTACH TABLE _ UUID '#{target_uuid}'"), "persisted target UUID differs from system.tables")
assert_w88(view_ddl.starts_with?("ATTACH MATERIALIZED VIEW _ UUID '#{view_uuid}' TO #{W88_RECOMPUTE_DATABASE}.target"),
  "persisted MV DDL did not map its own UUID to explicit target UUID/name")
normalized_view_ddl = normalize_w88_whitespace(view_ddl)
assert_w88(normalized_view_ddl.includes?("AS SELECT k, v FROM #{W88_RECOMPUTE_DATABASE}.source"),
  "persisted MV DDL did not retain the identity source query: #{view_ddl.inspect}")
assert_w88(Dir.exists?(w88_store_uuid_dir(recompute_store, source_uuid)), "source UUID data directory is missing")
assert_w88(Dir.exists?(w88_store_uuid_dir(recompute_store, target_uuid)), "target UUID data directory is missing")
assert_w88(!Dir.exists?(w88_store_uuid_dir(recompute_store, view_uuid)), "MV UUID unexpectedly owns a data directory")

catalog = CrystalClick::OfflineCatalog.open(recompute_store)
catalog_view = catalog.table(W88_RECOMPUTE_DATABASE, "mv")
catalog_source = catalog.table(W88_RECOMPUTE_DATABASE, "source")
catalog_target = catalog.table(W88_RECOMPUTE_DATABASE, "target")
assert_w88(catalog_view.kind == :materialized_view && catalog_view.engine == "MaterializedView" && catalog_view.uuid == view_uuid,
  "catalog did not resolve the explicit-TO MV metadata identity")
assert_w88(catalog_view.metadata_ddl == view_ddl, "catalog MV metadata differs from stock persisted ATTACH DDL")
assert_w88(catalog_source.uuid == source_uuid && catalog_source.engine == "MergeTree", "catalog source identity differs")
assert_w88(catalog_target.uuid == target_uuid && catalog_target.engine == "MergeTree", "catalog target identity differs")
assert_w88(catalog_source.part_candidates.map(&.name) == [source_part_name],
  "catalog source candidates differ from stock system.parts name #{source_part_name.inspect}")

source_rows = read_w88_source_rows(catalog_source)
assert_w88(w88_hex_rows(source_rows) == stock_source_rows,
  "catalog source scan differs from stock source rows: #{w88_hex_rows(source_rows).inspect}")

crystal_parts_root = File.join(root, "detached")
Dir.mkdir(crystal_parts_root)
crystal_part_path = File.join(crystal_parts_root, source_part_name)
assert_w88(!File.exists?(crystal_part_path) && !File.symlink?(crystal_part_path), "materialization destination was not absent")
catalog.materialize_view_part(W88_RECOMPUTE_DATABASE, "mv", source_part_name, crystal_part_path)
assert_w88(Dir.exists?(crystal_part_path) && !File.symlink?(crystal_part_path),
  "Crystal did not publish a real detached part directory")

target_path_rows = w88_rows(recompute_snapshot, "recompute_target_path")
assert_w88(target_path_rows.size == 1 && target_path_rows[0].size == 2,
  "stock target data path missing: #{target_path_rows.inspect}")
target_data_path = target_path_rows[0][1]
expected_target_path = w88_store_uuid_dir(recompute_store, target_uuid)
assert_w88(!target_data_path.empty? && normalize_w88_path(target_data_path) == normalize_w88_path(expected_target_path),
  "system.tables target path does not resolve to target UUID store: #{target_data_path.inspect} vs #{expected_target_path.inspect}")
assert_w88(Dir.exists?(target_data_path), "stock target UUID store directory is missing")
target_detached = File.join(target_data_path, "detached")
assert_w88(!File.symlink?(target_detached), "stock target detached directory unexpectedly is a symlink")
Dir.mkdir(target_detached) unless Dir.exists?(target_detached)
attached_destination = File.join(target_detached, source_part_name)
assert_w88(!File.exists?(attached_destination) && !File.symlink?(attached_destination), "target detached name is occupied")
FileUtils.cp_r(crystal_part_path, attached_destination)

run_w88_clickhouse(binary, recompute_store,
  "ALTER TABLE #{W88_RECOMPUTE_DATABASE}.target ATTACH PART '#{source_part_name}'")
check_table = run_w88_clickhouse(binary, recompute_store,
  "CHECK TABLE #{W88_RECOMPUTE_DATABASE}.target FORMAT TabSeparated").strip
assert_w88(check_table == "#{source_part_name}\t1", "stock CHECK TABLE rejected Crystal part: #{check_table.inspect}")

attached_rows = w88_stock_rows(run_w88_clickhouse(binary, recompute_store, <<-SQL), "attached_target_row")
SELECT 'attached_target_row', toString(k), hex(v)
FROM #{W88_RECOMPUTE_DATABASE}.target
ORDER BY k
FORMAT TSVRaw
SQL
assert_w88(attached_rows == stock_source_rows,
  "stock target after ATTACH PART differs from source: #{attached_rows.inspect} vs #{stock_source_rows.inspect}")

target_tsv = run_w88_clickhouse(binary, recompute_store,
  "SELECT toString(k), hex(v) FROM #{W88_RECOMPUTE_DATABASE}.target ORDER BY k FORMAT TSVRaw")
expected_tsv = stock_source_rows.map { |row| "#{row[0]}\t#{row[1]}" }.join("\n") + "\n"
assert_w88(target_tsv == expected_tsv, "direct exact source/target TSV equality failed: #{target_tsv.inspect}")

puts "PASS W88 stock MV trigger control on ClickHouse #{run_w88_clickhouse(binary, trigger_store, "SELECT version() FORMAT TSVRaw").strip}"
puts "  stock trigger mirrored three exact rows in two corresponding source/target parts"
puts "PASS W88 Crystal detached part on ClickHouse #{run_w88_clickhouse(binary, recompute_store, "SELECT version() FORMAT TSVRaw").strip}"
puts "  UUIDs: source=#{source_uuid}, target=#{target_uuid}, view=#{view_uuid}; view UUID has no data store"
puts "  persisted MV ATTACH DDL: #{normalized_view_ddl}"
puts "  source-before-MV target was empty; #{source_part_name} passed stock ATTACH PART and CHECK TABLE"
puts "  exact source/target rows (key, hex(String)): #{attached_rows.inspect}"
