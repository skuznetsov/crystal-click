#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-clickhouse}"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/crystal-click-wide-writer-oracle.XXXXXX")"
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
crystal run --link-flags='-fuse-ld=ld' --stdin-filename "$ROOT/scripts/check_wide_part_writer_oracle.cr" <<'CRYSTAL'
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

binary = ENV.fetch("CLICKHOUSE_BIN")
root = ENV.fetch("TMP_ROOT")
store = File.join(root, "store")
part = File.join(root, "part")
detached = ""
keys = [1_u64, 2_u64, 2_u64, 9_u64, UInt64::MAX]
values = [80_u64, 81_u64, 82_u64, 83_u64, 84_u64]

CrystalClick::WidePartWriter.write_uint64_pair(
  part,
  "pk",
  keys.to_unsafe.to_slice(keys.size),
  "value",
  values.to_unsafe.to_slice(values.size),
  rows_per_mark: 2
)

run_clickhouse(binary, store, <<-SQL)
CREATE TABLE default.wide_writer_oracle
(
    `pk` UInt64,
    `value` UInt64
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
  "SELECT data_paths[1] FROM system.tables WHERE database = 'default' AND name = 'wide_writer_oracle' FORMAT TSVRaw"
).strip
raise "ClickHouse returned no data path for the oracle table" if data_path.empty?

detached = File.join(data_path, "detached")
FileUtils.mkdir_p(detached)
FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
run_clickhouse(binary, store, "ALTER TABLE default.wide_writer_oracle ATTACH PART 'all_1_1_0'")

actual = run_clickhouse(
  binary,
  store,
  "SELECT pk, value FROM default.wide_writer_oracle ORDER BY pk, value FORMAT TabSeparated"
)
expected = "1\t80\n2\t81\n2\t82\n9\t83\n18446744073709551615\t84\n"
unless actual == expected
  raise "ClickHouse rows differ from expected pairs:\n#{actual.inspect}"
end

indexed = run_clickhouse(
  binary,
  store,
  "SELECT pk, value FROM default.wide_writer_oracle WHERE pk >= 2 AND pk < 9 ORDER BY pk, value FORMAT TabSeparated"
)
raise "ClickHouse indexed range differs from expected pairs: #{indexed.inspect}" unless indexed == "2\t81\n2\t82\n"

integrity = run_clickhouse(binary, store, "CHECK TABLE default.wide_writer_oracle FORMAT TabSeparated").strip
raise "ClickHouse CHECK TABLE did not confirm part integrity: #{integrity.inspect}" unless integrity == "all_1_1_0\t1"

index_path = File.join(data_path, "all_1_1_0", "primary.idx")
File.open(index_path, "r+") do |file|
  first = file.read_byte || raise "oracle part has an empty primary.idx"
  file.pos = 0
  file.write_byte(first ^ 1_u8)
end
damaged_integrity = run_clickhouse(binary, store, "CHECK TABLE default.wide_writer_oracle FORMAT TabSeparated").strip
damaged_fields = damaged_integrity.split('\t', 3)
unless damaged_fields.size == 3 &&
       damaged_fields[0] == "all_1_1_0" &&
       damaged_fields[1] == "0" &&
       damaged_fields[2].includes?("primary.idx") &&
       damaged_fields[2].includes?("CHECKSUM_DOESNT_MATCH")
  raise "ClickHouse CHECK TABLE missed mutated primary.idx: #{damaged_integrity.inspect}"
end

puts "ClickHouse #{ENV.fetch("CLICKHOUSE_BIN")} attached the synthetic part, returned exact rows and key-range results, passed CHECK TABLE, then detected one-byte primary.idx corruption."

nullable_part = File.join(root, "nullable_part")
nullable_keys = [1_u64, 2_u64, 2_u64, 9_u64, UInt64::MAX]
nullable_values = [nil, 0_u64, 7_u64, UInt64::MAX, nil] of UInt64?
CrystalClick::WidePartWriter.write_uint64_nullable_uint64_pair(
  nullable_part,
  "pk",
  nullable_keys.to_unsafe.to_slice(nullable_keys.size),
  "payload",
  nullable_values.to_unsafe.to_slice(nullable_values.size),
  rows_per_mark: 2
)

run_clickhouse(binary, store, <<-SQL)
CREATE TABLE default.wide_nullable_writer_oracle
(
    `pk` UInt64,
    `payload` Nullable(UInt64)
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

nullable_data_path = run_clickhouse(
  binary,
  store,
  "SELECT data_paths[1] FROM system.tables WHERE database = 'default' AND name = 'wide_nullable_writer_oracle' FORMAT TSVRaw"
).strip
raise "ClickHouse returned no Nullable oracle data path" if nullable_data_path.empty?

nullable_detached = File.join(nullable_data_path, "detached")
FileUtils.mkdir_p(nullable_detached)
FileUtils.cp_r(nullable_part, File.join(nullable_detached, "all_1_1_0"))
run_clickhouse(binary, store, "ALTER TABLE default.wide_nullable_writer_oracle ATTACH PART 'all_1_1_0'")

nullable_actual = run_clickhouse(
  binary,
  store,
  "SELECT pk, isNull(payload), ifNull(payload, 0) FROM default.wide_nullable_writer_oracle ORDER BY pk, isNull(payload), ifNull(payload, 0) FORMAT TabSeparated"
)
nullable_expected = "1\t1\t0\n2\t0\t0\n2\t0\t7\n9\t0\t18446744073709551615\n18446744073709551615\t1\t0\n"
raise "ClickHouse Nullable values differ: #{nullable_actual.inspect}" unless nullable_actual == nullable_expected

nullable_indexed = run_clickhouse(
  binary,
  store,
  "SELECT pk, isNull(payload), ifNull(payload, 0) FROM default.wide_nullable_writer_oracle WHERE pk >= 2 AND pk < 9 ORDER BY pk, ifNull(payload, 0) FORMAT TabSeparated"
)
raise "ClickHouse Nullable key range differs: #{nullable_indexed.inspect}" unless nullable_indexed == "2\t0\t0\n2\t0\t7\n"

nullable_integrity = run_clickhouse(binary, store, "CHECK TABLE default.wide_nullable_writer_oracle FORMAT TabSeparated").strip
raise "ClickHouse Nullable CHECK TABLE failed: #{nullable_integrity.inspect}" unless nullable_integrity == "all_1_1_0\t1"

null_stream_name = "#{CrystalClick::StreamName.hash("payload.null")}.bin"
null_stream_path = File.join(nullable_data_path, "all_1_1_0", null_stream_name)
# Flip a compressed-frame checksum byte, not a decoded null-map flag.
File.open(null_stream_path, "r+") do |file|
  first = file.read_byte || raise "oracle null-map stream is empty"
  file.pos = 0
  file.write_byte(first ^ 1_u8)
end
nullable_damaged_integrity = run_clickhouse(binary, store, "CHECK TABLE default.wide_nullable_writer_oracle FORMAT TabSeparated").strip
nullable_damaged_fields = nullable_damaged_integrity.split('\t', 3)
unless nullable_damaged_fields.size == 3 &&
       nullable_damaged_fields[0] == "all_1_1_0" &&
       nullable_damaged_fields[1] == "0" &&
       nullable_damaged_fields[2].includes?("CHECKSUM_DOESNT_MATCH")
  raise "ClickHouse CHECK TABLE missed mutated Nullable null-map stream: #{nullable_damaged_integrity.inspect}"
end

puts "ClickHouse attached the synthetic Nullable part, returned exact null-vs-zero and key-range rows, passed CHECK TABLE, then detected a one-byte null-map stream checksum mutation."
CRYSTAL
