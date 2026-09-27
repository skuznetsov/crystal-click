#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/Users/sergey/.local/bin/clickhouse}"
FIXTURE_ROOT="$ROOT/test/fixtures/public/wide_array_decimal32_w42"
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

TMP_ROOT="$(mktemp -d /private/tmp/crystal-click-array-decimal32-w42-fixture.XXXXXX)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT
STORE="$TMP_ROOT/store"

"$CLICKHOUSE_BIN" local --path "$STORE" --query "
CREATE TABLE source
(
    pk UInt64,
    plain Array(Decimal32(2)),
    maybe Array(Nullable(Decimal32(2)))
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
    (1, CAST([], 'Array(Decimal32(2))'), CAST([], 'Array(Nullable(Decimal32(2)))')),
    (2, CAST(['-12.34', '0.00', '99.99'], 'Array(Decimal32(2))'), CAST([NULL, '0.00', '-0.05'], 'Array(Nullable(Decimal32(2)))')),
    (4, CAST(['-9999999.99', '0.01'], 'Array(Decimal32(2))'), CAST([NULL, '1.23'], 'Array(Nullable(Decimal32(2)))')),
    (6, CAST([], 'Array(Decimal32(2))'), CAST([], 'Array(Nullable(Decimal32(2)))')),
    (9, CAST(['-1.23'], 'Array(Decimal32(2))'), CAST(['-1.00', NULL], 'Array(Nullable(Decimal32(2)))')),
    (11, CAST(['12.34', '-0.01'], 'Array(Decimal32(2))'), CAST(['0.00', NULL], 'Array(Nullable(Decimal32(2)))')),
    (13, CAST([], 'Array(Decimal32(2))'), CAST([], 'Array(Nullable(Decimal32(2)))'))
"

PART_PATH="$("$CLICKHOUSE_BIN" local --path "$STORE" --query "SELECT path FROM system.parts WHERE table = 'source' AND active FORMAT TSVRaw")"
[[ -d "$PART_PATH" && ! -L "$PART_PATH" ]] || { printf 'stock part not found\n' >&2; exit 1; }
INTEGRITY="$("$CLICKHOUSE_BIN" local --path "$STORE" --query "CHECK TABLE source FORMAT TabSeparated")"
[[ "$INTEGRITY" == $'all_1_1_0\t1\t' ]] || { printf 'stock CHECK TABLE failed: %q\n' "$INTEGRITY" >&2; exit 1; }
cmp -s "$PART_PATH/columns.txt" <(printf 'columns format version: 1\n3 columns:\n`pk` UInt64\n`plain` Array(Decimal(9, 2))\n`maybe` Array(Nullable(Decimal(9, 2)))\n') || {
  printf 'unexpected stock Decimal32 Array column metadata\n' >&2
  exit 1
}
cmp -s "$PART_PATH/columns_substreams.txt" <(printf 'columns substreams version: 1\n3 columns:\n1 substreams for column `pk`:\n\tpk\n2 substreams for column `plain`:\n\tplain.size0\n\tplain\n3 substreams for column `maybe`:\n\tmaybe.size0\n\tmaybe.null\n\tmaybe\n') || {
  printf 'unexpected stock Decimal32 Array stream layout\n' >&2
  exit 1
}
[[ "$(<"$PART_PATH/count.txt")" == 7 ]] || { printf 'unexpected stock row count\n' >&2; exit 1; }
[[ "$(<"$PART_PATH/default_compression_codec.txt")" == 'CODEC(LZ4)' ]] || {
  printf 'unexpected stock codec\n' >&2
  exit 1
}
[[ -z "$(find "$PART_PATH" -mindepth 1 -type l -print -quit)" ]] || { printf 'stock part contains symlinks\n' >&2; exit 1; }
[[ "$(find "$PART_PATH" -maxdepth 1 -type f -name '*.bin' | wc -l | tr -d ' ')" == 6 ]] || {
  printf 'expected six LZ4 data streams\n' >&2
  exit 1
}
[[ "$(find "$PART_PATH" -maxdepth 1 -type f -name '*.mrk2' | wc -l | tr -d ' ')" == 6 ]] || {
  printf 'expected six plain adaptive .mrk2 streams\n' >&2
  exit 1
}
if find "$PART_PATH" -maxdepth 1 -type f \( -name '*.cmrk*' -o -name '*.mrk' -o -name '*.mrk3' \) -print -quit | rg -q .; then
  printf 'expected plain .mrk2 marks only\n' >&2
  exit 1
fi

mkdir -p "$FIXTURE_ROOT"
cp -R "$PART_PATH" "$OUT"
(cd "$FIXTURE_ROOT" && shasum -a 256 part/* > SHA256SUMS)
printf 'generated pinned Decimal32 Array fixture at %s\n' "$OUT"
printf 'rows per mark: [2, 2, 2, 1]; codec CODEC(LZ4); mark files .mrk2\n'
