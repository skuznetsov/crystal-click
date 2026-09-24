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

string_keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64, 8_u64]
string_values = ["alpha", "a\0b", "", "", "é", "tail", "", ""]
string_part = File.join(root, "string_part")
CrystalClick::WidePartWriter.write_uint64_string_pair(
  string_part,
  "pk",
  string_keys.to_unsafe.to_slice(string_keys.size),
  "payload",
  string_values.to_unsafe.to_slice(string_values.size),
  rows_per_mark: 2
)

run_clickhouse(binary, store, <<-SQL)
CREATE TABLE default.wide_string_writer_oracle
(
    `pk` UInt64,
    `payload` String
)
ENGINE = MergeTree
ORDER BY pk
SETTINGS
    index_granularity = 2,
    index_granularity_bytes = 0,
    min_rows_for_wide_part = 0,
    min_bytes_for_wide_part = 0,
    compress_marks = 0,
    ratio_of_defaults_for_sparse_serialization = 1.0;
SQL

string_data_path = run_clickhouse(
  binary,
  store,
  "SELECT data_paths[1] FROM system.tables WHERE database = 'default' AND name = 'wide_string_writer_oracle' FORMAT TSVRaw"
).strip
raise "ClickHouse returned no String oracle data path" if string_data_path.empty?
FileUtils.mkdir_p(File.join(string_data_path, "detached"))
FileUtils.cp_r(string_part, File.join(string_data_path, "detached", "all_1_1_0"))
run_clickhouse(binary, store, "ALTER TABLE default.wide_string_writer_oracle ATTACH PART 'all_1_1_0'")

string_actual = run_clickhouse(
  binary,
  store,
  "SELECT pk, hex(payload) FROM default.wide_string_writer_oracle ORDER BY pk FORMAT TabSeparated"
)
string_expected = "1\t616C706861\n2\t610062\n3\t\n4\t\n5\tC3A9\n6\t7461696C\n7\t\n8\t\n"
raise "ClickHouse String bytes differ: #{string_actual.inspect}" unless string_actual == string_expected

string_indexed = run_clickhouse(
  binary,
  store,
  "SELECT pk, hex(payload) FROM default.wide_string_writer_oracle WHERE pk >= 2 AND pk < 6 ORDER BY pk FORMAT TabSeparated"
)
raise "ClickHouse String key range differs: #{string_indexed.inspect}" unless string_indexed == "2\t610062\n3\t\n4\t\n5\tC3A9\n"

string_integrity = run_clickhouse(binary, store, "CHECK TABLE default.wide_string_writer_oracle FORMAT TabSeparated").strip
raise "ClickHouse String CHECK TABLE failed: #{string_integrity.inspect}" unless string_integrity == "all_1_1_0\t1"

string_stream = File.join(string_data_path, "all_1_1_0", "#{CrystalClick::StreamName.hash("payload")}.bin")
File.open(string_stream, "r+") do |file|
  first = file.read_byte || raise "oracle String raw stream is empty"
  file.pos = 0
  file.write_byte(first ^ 1_u8)
end
string_damaged = run_clickhouse(binary, store, "CHECK TABLE default.wide_string_writer_oracle FORMAT TabSeparated").strip
string_damaged_fields = string_damaged.split('\t', 3)
unless string_damaged_fields.size == 3 &&
       string_damaged_fields[0] == "all_1_1_0" &&
       string_damaged_fields[1] == "0" &&
       string_damaged_fields[2].includes?("CHECKSUM_DOESNT_MATCH")
  raise "ClickHouse CHECK TABLE missed mutated String raw stream: #{string_damaged.inspect}"
end

puts "ClickHouse attached the mixed String part (including middle and final empty granules), returned exact binary/UTF-8 and key-range rows, passed CHECK TABLE, then detected a one-byte raw-stream checksum mutation."

empty_keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
empty_values = ["", "", "", "", ""]
empty_part = File.join(root, "empty_string_part")
CrystalClick::WidePartWriter.write_uint64_string_pair(
  empty_part,
  "pk",
  empty_keys.to_unsafe.to_slice(empty_keys.size),
  "payload",
  empty_values.to_unsafe.to_slice(empty_values.size),
  rows_per_mark: 2
)
empty_raw_stream = File.join(empty_part, "#{CrystalClick::StreamName.hash("payload")}.bin")
raise "all-empty String payload must have a zero-byte regular stream" unless File.size(empty_raw_stream) == 0

run_clickhouse(binary, store, <<-SQL)
CREATE TABLE default.wide_empty_string_writer_oracle
(
    `pk` UInt64,
    `payload` String
)
ENGINE = MergeTree
ORDER BY pk
SETTINGS
    index_granularity = 2,
    index_granularity_bytes = 0,
    min_rows_for_wide_part = 0,
    min_bytes_for_wide_part = 0,
    compress_marks = 0,
    ratio_of_defaults_for_sparse_serialization = 1.0;
SQL

empty_data_path = run_clickhouse(
  binary,
  store,
  "SELECT data_paths[1] FROM system.tables WHERE database = 'default' AND name = 'wide_empty_string_writer_oracle' FORMAT TSVRaw"
).strip
raise "ClickHouse returned no all-empty String oracle data path" if empty_data_path.empty?
FileUtils.mkdir_p(File.join(empty_data_path, "detached"))
FileUtils.cp_r(empty_part, File.join(empty_data_path, "detached", "all_1_1_0"))
run_clickhouse(binary, store, "ALTER TABLE default.wide_empty_string_writer_oracle ATTACH PART 'all_1_1_0'")

empty_actual = run_clickhouse(
  binary,
  store,
  "SELECT pk, length(payload) FROM default.wide_empty_string_writer_oracle ORDER BY pk FORMAT TabSeparated"
)
raise "ClickHouse all-empty String values differ: #{empty_actual.inspect}" unless empty_actual == "1\t0\n2\t0\n3\t0\n4\t0\n5\t0\n"

empty_indexed = run_clickhouse(
  binary,
  store,
  "SELECT pk, length(payload) FROM default.wide_empty_string_writer_oracle WHERE pk >= 2 AND pk < 5 ORDER BY pk FORMAT TabSeparated"
)
raise "ClickHouse all-empty String key range differs: #{empty_indexed.inspect}" unless empty_indexed == "2\t0\n3\t0\n4\t0\n"

empty_integrity = run_clickhouse(binary, store, "CHECK TABLE default.wide_empty_string_writer_oracle FORMAT TabSeparated").strip
raise "ClickHouse all-empty String CHECK TABLE failed: #{empty_integrity.inspect}" unless empty_integrity == "all_1_1_0\t1"

empty_size_stream = File.join(empty_data_path, "all_1_1_0", "#{CrystalClick::StreamName.hash("payload.size")}.bin")
File.open(empty_size_stream, "r+") do |file|
  first = file.read_byte || raise "oracle String size stream is empty"
  file.pos = 0
  file.write_byte(first ^ 1_u8)
end
empty_damaged = run_clickhouse(binary, store, "CHECK TABLE default.wide_empty_string_writer_oracle FORMAT TabSeparated").strip
empty_damaged_fields = empty_damaged.split('\t', 3)
unless empty_damaged_fields.size == 3 &&
       empty_damaged_fields[0] == "all_1_1_0" &&
       empty_damaged_fields[1] == "0" &&
       empty_damaged_fields[2].includes?("CHECKSUM_DOESNT_MATCH")
  raise "ClickHouse CHECK TABLE missed mutated String size stream: #{empty_damaged.inspect}"
end

puts "ClickHouse attached the all-empty String part with a zero-byte raw stream, returned exact and key-range rows, passed CHECK TABLE, then detected a one-byte size-stream checksum mutation."
CRYSTAL
