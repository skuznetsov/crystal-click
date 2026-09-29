require "file_utils"
require "../src/crystal_click"

W87_DATABASE   = "w87_projection_oracle"
W87_COMPLETE   = "w87_complete"
W87_PARTIAL    = "w87_partial"
W87_PROJECTION = "by_tag"

alias W87ProjectionRow = Tuple(String, UInt64)

def assert_w87(condition : Bool, message : String) : Nil
  raise "W87 projection oracle: #{message}" unless condition
end

def run_w87_clickhouse(binary : String, store : String, query : String) : String
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

def w87_snapshot_rows(snapshot : String, label : String) : Array(Array(String))
  snapshot.lines
    .map(&.strip)
    .reject(&.empty?)
    .map(&.split('\t'))
    .select { |columns| columns[0]? == label }
end

def w87_pairs(rows : Array(W87ProjectionRow)) : Array(W87ProjectionRow)
  rows.sort_by { |row| row[0] }
end

def w87_read_query_pairs(snapshot : String, label : String) : Hash(String, Array(W87ProjectionRow))
  groups = Hash(String, Array(W87ProjectionRow)).new do |hash, name|
    hash[name] = [] of W87ProjectionRow
  end
  w87_snapshot_rows(snapshot, label).each do |columns|
    raise "malformed #{label} row: #{columns.inspect}" unless columns.size == 4
    groups[columns[1]] << {columns[2], columns[3].to_u64}
  end
  groups
end

def w87_collect(reader : CrystalClick::WidePartTable) : Array(W87ProjectionRow)
  observed = [] of W87ProjectionRow
  reader.scan_typed(batch_rows: 1) do |batch|
    tags = batch.strings_for("tag")
    amounts = batch.values_for("amount", UInt64)
    raise "projection batch columns are not row-aligned" unless tags.size == amounts.size
    tags.each_index do |index|
      observed << {tags[index].dup, amounts[index]}
    end
  end
  observed
end

def w87_scan_catalog(
  table : CrystalClick::OfflineTable,
  projection_name : String,
) : Array(W87ProjectionRow)
  observed = [] of W87ProjectionRow
  table.scan_projection_typed(projection_name, ["tag", "amount"], batch_rows: 1) do |batch|
    tags = batch.strings_for("tag")
    amounts = batch.values_for("amount", UInt64)
    raise "catalog projection batch columns are not row-aligned" unless tags.size == amounts.size
    tags.each_index do |index|
      observed << {tags[index].dup, amounts[index]}
    end
  end
  observed
end

binary = ENV.fetch("CLICKHOUSE_BIN")
store = ENV.fetch("CLICKHOUSE_STORE")

# STOP MERGES and both INSERTs for each table execute in one local server
# process. This makes the complete and partial per-part coverage states stable.
stock_snapshot = run_w87_clickhouse(binary, store, <<-SQL)
CREATE DATABASE #{W87_DATABASE} ENGINE = Atomic;
CREATE TABLE #{W87_DATABASE}.#{W87_COMPLETE}
(
    id UInt64,
    tag String,
    amount UInt64,
    PROJECTION #{W87_PROJECTION} (SELECT tag, amount ORDER BY tag)
)
ENGINE = MergeTree
ORDER BY id
SETTINGS min_rows_for_wide_part = 0, min_bytes_for_wide_part = 0
;
SYSTEM STOP MERGES #{W87_DATABASE}.#{W87_COMPLETE};
INSERT INTO #{W87_DATABASE}.#{W87_COMPLETE} VALUES (1, 'alpha', 10), (2, 'bravo', 20);
INSERT INTO #{W87_DATABASE}.#{W87_COMPLETE} VALUES (3, 'charlie', 30), (4, 'delta', 40);
CHECK TABLE #{W87_DATABASE}.#{W87_COMPLETE};
SELECT 'check_table', 'succeeded' FORMAT TSVRaw;
CREATE TABLE #{W87_DATABASE}.#{W87_PARTIAL}
(
    id UInt64,
    tag String,
    amount UInt64
)
ENGINE = MergeTree
ORDER BY id
SETTINGS min_rows_for_wide_part = 0, min_bytes_for_wide_part = 0
;
SYSTEM STOP MERGES #{W87_DATABASE}.#{W87_PARTIAL};
INSERT INTO #{W87_DATABASE}.#{W87_PARTIAL} VALUES (1, 'before', 11);
ALTER TABLE #{W87_DATABASE}.#{W87_PARTIAL} ADD PROJECTION #{W87_PROJECTION} (SELECT tag, amount ORDER BY tag);
INSERT INTO #{W87_DATABASE}.#{W87_PARTIAL} VALUES (2, 'after', 22);
SELECT 'complete_part', name, path, toString(rows), toString(min_block_number)
FROM system.parts
WHERE database='#{W87_DATABASE}' AND table='#{W87_COMPLETE}' AND active
ORDER BY min_block_number FORMAT TSVRaw;
SELECT 'partial_part', name, path, toString(rows), toString(min_block_number)
FROM system.parts
WHERE database='#{W87_DATABASE}' AND table='#{W87_PARTIAL}' AND active
ORDER BY min_block_number FORMAT TSVRaw;
SELECT 'complete_query', _part, tag, toString(amount)
FROM #{W87_DATABASE}.#{W87_COMPLETE}
ORDER BY _part, tag FORMAT TSVRaw;
SELECT 'partial_query', _part, tag, toString(amount)
FROM #{W87_DATABASE}.#{W87_PARTIAL}
ORDER BY _part, tag FORMAT TSVRaw;
SQL

assert_w87(w87_snapshot_rows(stock_snapshot, "check_table") == [["check_table", "succeeded"]],
  "stock CHECK TABLE did not reach its success marker")

complete_parts = w87_snapshot_rows(stock_snapshot, "complete_part")
assert_w87(complete_parts.size == 2, "stock complete table has #{complete_parts.size} active parent parts, expected 2")
assert_w87(complete_parts.all? { |columns| columns.size == 5 && columns[3].to_u64 == 2_u64 },
  "stock complete parent parts do not each contain two rows")
complete_part_names = complete_parts.map(&.[1])
check_marker_index = stock_snapshot.lines.index { |line| line.starts_with?("check_table\t") } ||
                     raise "stock CHECK TABLE success marker is missing"
check_rows = stock_snapshot.lines[0, check_marker_index].map do |line|
  line.strip.split('\t')
end.reject(&.empty?)
assert_w87(check_rows.size == complete_parts.size && check_rows.all? { |columns| columns.size >= 2 && columns[1] == "1" } &&
           check_rows.map(&.[0]).sort == complete_part_names.sort,
  "CHECK TABLE rows did not report result=1 for every complete parent part: #{check_rows.inspect}")
complete_artifacts = complete_parts.map do |columns|
  File.directory?(File.join(columns[2], "#{W87_PROJECTION}.proj"))
end
assert_w87(complete_artifacts == [true, true],
  "stock complete table projection artifact coverage was #{complete_artifacts.inspect}, expected [present, present]")

partial_parts = w87_snapshot_rows(stock_snapshot, "partial_part")
assert_w87(partial_parts.size == 2, "stock partial table has #{partial_parts.size} active parent parts, expected 2")
partial_artifacts = partial_parts.map do |columns|
  File.directory?(File.join(columns[2], "#{W87_PROJECTION}.proj"))
end
assert_w87(partial_artifacts == [false, true],
  "stock partial table projection artifact coverage was #{partial_artifacts.inspect}, expected [absent, present]")

stock_complete_groups = w87_read_query_pairs(stock_snapshot, "complete_query")
stock_complete_rows = stock_complete_groups.values.flatten
assert_w87(w87_pairs(stock_complete_rows) == [{"alpha", 10_u64}, {"bravo", 20_u64}, {"charlie", 30_u64}, {"delta", 40_u64}],
  "ClickHouse complete-table query returned unexpected projection values: #{w87_pairs(stock_complete_rows).inspect}")

catalog = CrystalClick::OfflineCatalog.open(store)
complete = catalog.table(W87_DATABASE, W87_COMPLETE)
partial = catalog.table(W87_DATABASE, W87_PARTIAL)
catalog_parts = complete.part_candidates
assert_w87(catalog_parts.map(&.name).sort == complete_part_names.sort &&
           catalog_parts.all? { |part| Dir.exists?(File.join(part.path, "#{W87_PROJECTION}.proj")) },
  "catalog physical parents or child paths differ from stock system.parts: #{catalog_parts.map { |part| {part.name, part.path, Dir.exists?(File.join(part.path, "#{W87_PROJECTION}.proj"))} }.inspect}")
catalog_complete_rows = w87_scan_catalog(complete, W87_PROJECTION)
stock_rows_in_parent_order = complete_parts.flat_map do |columns|
  stock_complete_groups[columns[1]]? || raise "ClickHouse query has no rows for parent part #{columns[1]}"
end
assert_w87(catalog_complete_rows == stock_rows_in_parent_order,
  "catalog projection scan differs from ClickHouse _part groups in system.parts order: #{catalog_complete_rows.inspect}")

assert_w87(complete.projections.any? { |projection| projection.name == W87_PROJECTION },
  "catalog complete table omitted its declared projection")

# Also open each physical parent part independently, proving that the low-level
# factory can read the projection child under either parent part.
complete_parts_by_name = complete_parts.to_h { |columns| {columns[1], columns[2]} }
assert_w87(stock_complete_groups.keys.sort == complete_parts_by_name.keys.sort,
  "ClickHouse query _part identities differ from system.parts parent identities")
complete_parts.each do |columns|
  part_name, path = columns[1], columns[2]
  reader = CrystalClick::WidePartTable.open_selected_projection_typed([path], W87_PROJECTION, ["tag", "amount"])
  assert_w87(reader.part_count == 1, "low-level reader for #{part_name} opened #{reader.part_count} parent parts")
  assert_w87(reader.checksum_verification == CrystalClick::ChecksumVerification::SizeChecked,
    "low-level projection reader checksum status was #{reader.checksum_verification}, expected SizeChecked")
  observed = w87_collect(reader)
  expected = stock_complete_groups[part_name]? || raise "ClickHouse query has no rows for parent part #{part_name}"
  assert_w87(observed == expected,
    "low-level projection scan for #{part_name} differs: #{observed.inspect}")
end

partial_rejected = false
partial_callbacks = 0
begin
  partial.scan_projection_typed(W87_PROJECTION, ["tag", "amount"], batch_rows: 1) do |_batch|
    partial_callbacks += 1
    nil
  end
rescue CrystalClick::InvalidPartError
  partial_rejected = true
end
assert_w87(partial_rejected, "catalog projection scan accepted partial [absent, present] coverage")
assert_w87(partial_callbacks == 0, "partial-coverage rejection occurred after #{partial_callbacks} callback(s)")

puts "PASS W87 pinned stock projection oracle on ClickHouse 26.7.1.1315"
puts "  complete parent parts: #{complete_parts.size}; projection artifacts: #{complete_artifacts.inspect}"
puts "  CHECK TABLE result=1 for parts: #{check_rows.map { |columns| {columns[0], columns[1]} }.inspect}"
puts "  ClickHouse query and catalog projection scan agree in parent-part order on #{catalog_complete_rows.size} rows"
puts "  low-level selected-projection factory independently read both child parts; checksum status: SizeChecked"
puts "  partial parent artifacts: #{partial_artifacts.inspect}; catalog scan rejected before callbacks"
