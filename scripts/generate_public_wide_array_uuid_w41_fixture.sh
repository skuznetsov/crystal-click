#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/Users/sergey/.local/bin/clickhouse}"
FIXTURE_ROOT="$ROOT/test/fixtures/public/wide_array_uuid_w41"
OUT="$FIXTURE_ROOT/part"
EXPECTED_VERSION='ClickHouse local version 26.7.1.1315 (official build).'

if [[ -e "$FIXTURE_ROOT" || -L "$FIXTURE_ROOT" ]]; then
  printf 'fixture exists; refusing to replace it: %s\n' "$FIXTURE_ROOT" >&2
  exit 2
fi
if [[ ! -x "$CLICKHOUSE_BIN" ]]; then
  printf 'ClickHouse executable not found: %s\n' "$CLICKHOUSE_BIN" >&2
  exit 1
fi
ACTUAL_VERSION="$("$CLICKHOUSE_BIN" local --version)"
if [[ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]]; then
  printf 'fixture producer mismatch: expected %s, got %s\n' "$EXPECTED_VERSION" "$ACTUAL_VERSION" >&2
  exit 1
fi

TMP_ROOT="$(mktemp -d /private/tmp/crystal-click-array-uuid-fixture.XXXXXX)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT
STORE="$TMP_ROOT/store"

"$CLICKHOUSE_BIN" local --path "$STORE" --query "
CREATE TABLE source
(
    pk UInt64,
    plain Array(UUID),
    maybe Array(Nullable(UUID))
)
ENGINE = MergeTree
ORDER BY pk
SETTINGS
    index_granularity = 2,
    index_granularity_bytes = 10485760,
    enable_mixed_granularity_parts = 1,
    min_rows_for_wide_part = 0,
    min_bytes_for_wide_part = 0,
    compress_marks = 0,
    min_compress_block_size = 0,
    max_compress_block_size = 4096,
    ratio_of_defaults_for_sparse_serialization = 1.0,
    default_compression_codec = 'LZ4'
"

"$CLICKHOUSE_BIN" local --path "$STORE" --query "
INSERT INTO source VALUES
    (1, CAST([], 'Array(UUID)'), CAST([], 'Array(Nullable(UUID))')),
    (2, [toUUID('00112233-4455-6677-8899-aabbccddeeff'), toUUID('00000000-0000-0000-0000-000000000000')], CAST([NULL, toUUID('00000000-0000-0000-0000-000000000000')], 'Array(Nullable(UUID))')),
    (4, [toUUID('ffffffff-ffff-ffff-ffff-ffffffffffff')], CAST([NULL, NULL], 'Array(Nullable(UUID))')),
    (6, CAST([], 'Array(UUID)'), CAST([], 'Array(Nullable(UUID))')),
    (9, [toUUID('61f0c404-5cb3-11e7-907b-a6006ad3dba0')], [toUUID('01234567-89ab-cdef-fedc-ba9876543210')]),
    (11, [toUUID('01234567-89ab-cdef-fedc-ba9876543210'), toUUID('10203040-5060-7080-90a0-b0c0d0e0f001')], CAST([NULL, toUUID('61f0c404-5cb3-11e7-907b-a6006ad3dba0')], 'Array(Nullable(UUID))')),
    (13, CAST([], 'Array(UUID)'), CAST([], 'Array(Nullable(UUID))'))
"

PART_PATH="$("$CLICKHOUSE_BIN" local --path "$STORE" --query "SELECT path FROM system.parts WHERE table = 'source' AND active FORMAT TSVRaw")"
[[ -d "$PART_PATH" && ! -L "$PART_PATH" ]] || { printf 'stock part not found\n' >&2; exit 1; }
INTEGRITY="$("$CLICKHOUSE_BIN" local --path "$STORE" --query "CHECK TABLE source FORMAT TabSeparated")"
[[ "$INTEGRITY" == $'all_1_1_0\t1\t' ]] || { printf 'stock CHECK TABLE failed: %q\n' "$INTEGRITY" >&2; exit 1; }
cmp -s "$PART_PATH/columns.txt" <(printf 'columns format version: 1\n3 columns:\n`pk` UInt64\n`plain` Array(UUID)\n`maybe` Array(Nullable(UUID))\n') || {
  printf 'unexpected stock UUID Array column metadata\n' >&2
  exit 1
}
cmp -s "$PART_PATH/columns_substreams.txt" <(printf 'columns substreams version: 1\n3 columns:\n1 substreams for column `pk`:\n\tpk\n2 substreams for column `plain`:\n\tplain.size0\n\tplain\n3 substreams for column `maybe`:\n\tmaybe.size0\n\tmaybe.null\n\tmaybe\n') || {
  printf 'unexpected stock UUID Array stream layout\n' >&2
  exit 1
}
[[ "$(<"$PART_PATH/count.txt")" == 7 ]] || { printf 'unexpected stock row count\n' >&2; exit 1; }
[[ "$(<"$PART_PATH/default_compression_codec.txt")" == 'CODEC(LZ4)' ]] || {
  printf 'unexpected stock codec\n' >&2
  exit 1
}
[[ -z "$(find "$PART_PATH" -mindepth 1 -type l -print -quit)" ]] || { printf 'stock part contains symlinks\n' >&2; exit 1; }

mkdir -p "$FIXTURE_ROOT"
cp -R "$PART_PATH" "$OUT"
printf 'generated %s\n' "$OUT"
printf 'serialization.json: '
cat "$OUT/serialization.json"
printf '\nstream files:\n'
find "$OUT" -maxdepth 1 -type f \( -name '*.bin' -o -name '*.mrk2' \) -exec basename {} \; | sort
printf 'first mark bytes (primary key stream):\n'
PRIMARY_MARK="$(find "$OUT" -maxdepth 1 -type f -name '*.mrk2' -print | head -n 1)"
od -An -tx8 -N48 "$PRIMARY_MARK"
