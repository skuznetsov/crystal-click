#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-clickhouse}"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/crystal-click-embedded-merge-oracle.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

if ! command -v "$CLICKHOUSE_BIN" >/dev/null 2>&1; then
  printf 'ClickHouse executable not found: %s\n' "$CLICKHOUSE_BIN" >&2
  exit 1
fi

EXPECTED_VERSION='ClickHouse local version 26.7.1.1315 (official build).'
ACTUAL_VERSION="$("$CLICKHOUSE_BIN" local --version)"
if [[ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]]; then
  printf 'oracle requires %s, got %s\n' "$EXPECTED_VERSION" "$ACTUAL_VERSION" >&2
  exit 1
fi

cd "$ROOT"
export CLICKHOUSE_BIN TMP_ROOT
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache"
mkdir -p "$CRYSTAL_CACHE_DIR"

crystal run --link-flags='-fuse-ld=ld' --stdin-filename "$ROOT/scripts/check_embedded_merge_oracle.cr" <<'CRYSTAL'
require "file_utils"
require "../src/crystal_click"

def run_clickhouse(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  status = Process.run(
    binary,
    ["local", "--path", store, "--query", query],
    output: output,
    error: Process::Redirect::Inherit
  )
  raise "ClickHouse local query failed (status #{status.exit_code})" unless status.success?
  output.to_s
end

def embedded_rows(table : CrystalClick::EmbeddedMergeTreeTable) : Array({UInt64, String})
  rows = [] of {UInt64, String}
  table.scan_typed(["pk", "value"], batch_rows: 2) do |batch|
    keys = batch.values_for("pk", UInt64)
    values = batch.strings_for("value")
    raise "embedded scan returned mismatched column lengths" unless keys.size == values.size
    keys.size.times { |index| rows << {keys[index], values[index]} }
  end
  rows
end

binary = ENV.fetch("CLICKHOUSE_BIN")
tmp_root = ENV.fetch("TMP_ROOT")
store = File.join(tmp_root, "clickhouse-store")
table_root = File.join(tmp_root, "embedded-table")

left_keys = [1_u64, 4_u64, 7_u64, 7_u64, 10_u64]
left_values = ["left-1", "left-4", "", "left-7b", "left-10"]
right_keys = [2_u64, 4_u64, 6_u64, 7_u64, 11_u64]
right_values = ["right-2", "right-4", "right-6", "right-7", "right-\0-é"]
expected_rows = [
  {1_u64, "left-1"},
  {2_u64, "right-2"},
  {4_u64, "left-4"},
  {4_u64, "right-4"},
  {6_u64, "right-6"},
  {7_u64, ""},
  {7_u64, "left-7b"},
  {7_u64, "right-7"},
  {10_u64, "left-10"},
  {11_u64, "right-\0-é"},
]

table = CrystalClick::EmbeddedMergeTreeTable.create(table_root, "pk", "value")
left_name = table.insert(left_keys.to_unsafe.to_slice(left_keys.size), left_values.to_unsafe.to_slice(left_values.size), rows_per_mark: 2)
right_name = table.insert(right_keys.to_unsafe.to_slice(right_keys.size), right_values.to_unsafe.to_slice(right_values.size), rows_per_mark: 2)
raise "unexpected input part names: #{left_name}, #{right_name}" unless left_name == "all_1_1_0" && right_name == "all_2_2_0"

merged_name = table.merge_adjacent(left_name, right_name, rows_per_mark: 2)
raise "embedded merge rows differ: #{embedded_rows(table).inspect}" unless embedded_rows(table) == expected_rows

visible_parts = table.part_paths
raise "embedded merge did not select exactly one merged part: #{visible_parts.inspect}" unless visible_parts.size == 1
merged_part = visible_parts[0]
unless File.expand_path(File.dirname(merged_part)) == File.expand_path(File.join(table_root, "parts")) &&
       File.basename(merged_part) == merged_name &&
       merged_name.matches?(/\Aall_1_2_[1-9][0-9]*\z/)
  raise "embedded merge output is not the expected positive-level part: path=#{merged_part.inspect}, parent=#{File.dirname(merged_part).inspect}, expected_parent=#{File.join(table_root, "parts").inspect}, basename=#{File.basename(merged_part).inspect}, returned_name=#{merged_name.inspect}, positive_level=#{merged_name.matches?(/\Aall_1_2_[1-9][0-9]*\z/)}"
end

run_clickhouse(binary, store, <<-SQL)
CREATE TABLE default.embedded_merge_oracle
(
    `pk` UInt64,
    `value` String
)
ENGINE = MergeTree
ORDER BY pk
SETTINGS
    index_granularity = 2,
    index_granularity_bytes = 0,
    min_rows_for_wide_part = 0,
    min_bytes_for_wide_part = 0,
    compress_marks = 0;
SQL

data_path = run_clickhouse(
  binary,
  store,
  "SELECT data_paths[1] FROM system.tables WHERE database = 'default' AND name = 'embedded_merge_oracle' FORMAT TSVRaw"
).strip
raise "ClickHouse returned no data path for the merge oracle table" if data_path.empty?

detached = File.join(data_path, "detached")
FileUtils.mkdir_p(detached)
FileUtils.cp_r(merged_part, File.join(detached, merged_name))
run_clickhouse(binary, store, "ALTER TABLE default.embedded_merge_oracle ATTACH PART '#{merged_name}'")

actual = run_clickhouse(
  binary,
  store,
  "SELECT pk, hex(value) FROM default.embedded_merge_oracle ORDER BY pk, _part_offset FORMAT TabSeparated"
)
expected = "1\t6C6566742D31\n2\t72696768742D32\n4\t6C6566742D34\n4\t72696768742D34\n6\t72696768742D36\n7\t\n7\t6C6566742D3762\n7\t72696768742D37\n10\t6C6566742D3130\n11\t72696768742D002DC3A9\n"
raise "ClickHouse merged rows differ from expected stable rows: #{actual.inspect}" unless actual == expected

indexed = run_clickhouse(
  binary,
  store,
  "SELECT pk, hex(value) FROM default.embedded_merge_oracle WHERE pk >= 4 AND pk <= 7 ORDER BY pk, _part_offset FORMAT TabSeparated"
)
expected_indexed = "4\t6C6566742D34\n4\t72696768742D34\n6\t72696768742D36\n7\t\n7\t6C6566742D3762\n7\t72696768742D37\n"
raise "ClickHouse merged key range differs: #{indexed.inspect}" unless indexed == expected_indexed

attached_parts = run_clickhouse(
  binary,
  store,
  "SELECT name FROM system.parts WHERE database = 'default' AND table = 'embedded_merge_oracle' AND active ORDER BY name FORMAT TSVRaw"
).lines.map(&.strip).reject(&.empty?)
integrity = run_clickhouse(binary, store, "CHECK TABLE default.embedded_merge_oracle FORMAT TabSeparated").strip
integrity_fields = integrity.split('\t', 2)
unless attached_parts.size == 1 && integrity_fields.size == 2 &&
       integrity_fields[0] == attached_parts[0] && integrity_fields[1] == "1"
  raise "ClickHouse CHECK TABLE did not confirm exactly one active merged part: #{integrity.inspect}; active parts=#{attached_parts.inspect}"
end

puts "ClickHouse 26.7.1.1315 attached source #{merged_name} as active part #{attached_parts[0]}, returned exact interleaved rows with stable duplicates and binary/empty String values, matched the key range, and passed CHECK TABLE."
CRYSTAL
