#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/Users/sergey/.local/bin/clickhouse}"
OUT="${WIDE_INTEGER_FIXTURE_OUT:-$ROOT/test/fixtures/public/wide_integer128/part}"
EXPECTED_VERSION='ClickHouse local version 26.7.1.1315 (official build).'

if [[ "$#" -ne 0 ]]; then
  printf 'usage: %s\n' "$0" >&2
  exit 2
fi
if [[ -e "$OUT" || -L "$OUT" ]]; then
  printf 'fixture exists; refusing to replace it: %s\n' "$OUT" >&2
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

TMP_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/crystal-click-wide-integer-fixture.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT
STORE="$TMP_ROOT/store"

"$CLICKHOUSE_BIN" local --path "$STORE" --query "
CREATE TABLE source
(
    pk UInt64,
    signed Int128,
    unsigned UInt128
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
    default_compression_codec = 'LZ4'
"

"$CLICKHOUSE_BIN" local --path "$STORE" --query "
INSERT INTO source VALUES
    (1, CAST('-170141183460469231731687303715884105728', 'Int128'), CAST('0', 'UInt128')),
    (2, CAST('-9223372036854775809', 'Int128'), CAST('1', 'UInt128')),
    (4, CAST('-18446744073709551617', 'Int128'), CAST('18446744073709551615', 'UInt128')),
    (6, CAST('-1', 'Int128'), CAST('18446744073709551616', 'UInt128')),
    (9, CAST('0', 'Int128'), CAST('18446744073709551617', 'UInt128')),
    (11, CAST('1', 'Int128'), CAST('170141183460469231731687303715884105727', 'UInt128')),
    (13, CAST('18446744073709551615', 'Int128'), CAST('170141183460469231731687303715884105728', 'UInt128')),
    (17, CAST('18446744073709551616', 'Int128'), CAST('340282366920938463463374607431768211455', 'UInt128')),
    (19, CAST('-170141183460469231731687303715884105727', 'Int128'), CAST('340282366920938463463374607431768211454', 'UInt128')),
    (21, CAST('170141183460469231731687303715884105726', 'Int128'), CAST('12345678901234567890123456789012345678', 'UInt128')),
    (25, CAST('12345678901234567890123456789012345678', 'Int128'), CAST('18446744073709551616', 'UInt128')),
    (31, CAST('-12345678901234567890123456789012345678', 'Int128'), CAST('295147905179352825856', 'UInt128')),
    (40, CAST('170141183460469231731687303715884105727', 'Int128'), CAST('42', 'UInt128'))
"

PART_PATH="$("$CLICKHOUSE_BIN" local --path "$STORE" --query "SELECT path FROM system.parts WHERE database = 'default' AND table = 'source' AND active FORMAT TSVRaw")"
[[ -d "$PART_PATH" && ! -L "$PART_PATH" ]] || { printf 'stock part not found\n' >&2; exit 1; }
INTEGRITY="$("$CLICKHOUSE_BIN" local --path "$STORE" --query "CHECK TABLE source FORMAT TabSeparated")"
[[ "$INTEGRITY" == $'all_1_1_0\t1\t' ]] || { printf 'stock CHECK TABLE failed: %q\n' "$INTEGRITY" >&2; exit 1; }
cmp -s "$PART_PATH/columns.txt" <(printf 'columns format version: 1\n3 columns:\n`pk` UInt64\n`signed` Int128\n`unsigned` UInt128\n') || {
  printf 'unexpected stock raw integer column metadata\n' >&2
  exit 1
}
cmp -s "$PART_PATH/columns_substreams.txt" <(printf 'columns substreams version: 1\n3 columns:\n1 substreams for column `pk`:\n\tpk\n1 substreams for column `signed`:\n\tsigned\n1 substreams for column `unsigned`:\n\tunsigned\n') || {
  printf 'unexpected stock raw integer substreams\n' >&2
  exit 1
}
[[ "$(<"$PART_PATH/count.txt")" == 13 ]] || { printf 'unexpected stock row count\n' >&2; exit 1; }
[[ "$(<"$PART_PATH/default_compression_codec.txt")" == 'CODEC(LZ4)' ]] || { printf 'unexpected stock compression codec\n' >&2; exit 1; }
[[ -z "$(find "$PART_PATH" -mindepth 1 -type l -print -quit)" ]] || { printf 'stock part contains symlinks\n' >&2; exit 1; }

mkdir -p "$(dirname -- "$OUT")"
cp -R "$PART_PATH" "$OUT"
FIXTURE_ROOT="$(dirname -- "$OUT")"
(cd "$FIXTURE_ROOT" && find "$(basename -- "$OUT")" -type f -print0 | sort -z | xargs -0 shasum -a 256 > SHA256SUMS)
printf 'generated %s with %s\n' "$OUT" "$ACTUAL_VERSION"
