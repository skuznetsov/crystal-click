#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/Users/sergey/.local/bin/clickhouse}"
FIXTURE_ROOT="$ROOT/test/fixtures/public/wide_array_tuple_w51"
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

TMP_ROOT="$(mktemp -d /private/tmp/crystal-click-array-tuple-w51-fixture.XXXXXX)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT
STORE="$TMP_ROOT/store"

"$CLICKHOUSE_BIN" local --path "$STORE" --query "
CREATE TABLE source
(
    pk UInt64,
    arr_tuple Array(Tuple(a UInt64, b String)),
    arr_tuple_nullable Array(Tuple(a Nullable(UInt64), b String))
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
    (1, CAST([], 'Array(Tuple(a UInt64, b String))'), CAST([], 'Array(Tuple(a Nullable(UInt64), b String))')),
    (2, [(toUInt64(0), ''), (toUInt64(18446744073709551615), 'small')], CAST([(NULL, ''), (toUInt64(0), 'zero')], 'Array(Tuple(a Nullable(UInt64), b String))')),
    (4, [(toUInt64(42), unhex('410042FF')), (toUInt64(3), 'second')], CAST([(NULL, 'all null one'), (NULL, 'all null two')], 'Array(Tuple(a Nullable(UInt64), b String))')),
    (6, CAST([], 'Array(Tuple(a UInt64, b String))'), CAST([], 'Array(Tuple(a Nullable(UInt64), b String))')),
    (9, [(toUInt64(7), 'a longer string crosses the row and mark boundary')], CAST([(toUInt64(9), 'nullable long string crosses the row and mark boundary')], 'Array(Tuple(a Nullable(UInt64), b String))')),
    (11, [(toUInt64(2), 'tail'), (toUInt64(3), 'last')], CAST([(toUInt64(8), 'nullable'), (NULL, 'end')], 'Array(Tuple(a Nullable(UInt64), b String))')),
    (13, CAST([], 'Array(Tuple(a UInt64, b String))'), CAST([], 'Array(Tuple(a Nullable(UInt64), b String))'))
"

PART_PATH="$("$CLICKHOUSE_BIN" local --path "$STORE" --query "SELECT path FROM system.parts WHERE table = 'source' AND active FORMAT TSVRaw")"
[[ -d "$PART_PATH" && ! -L "$PART_PATH" ]] || { printf 'stock part not found\n' >&2; exit 1; }
INTEGRITY="$("$CLICKHOUSE_BIN" local --path "$STORE" --query "CHECK TABLE source FORMAT TabSeparated")"
[[ "$INTEGRITY" == $'all_1_1_0\t1\t' ]] || { printf 'stock CHECK TABLE failed: %q\n' "$INTEGRITY" >&2; exit 1; }
cmp -s "$PART_PATH/columns.txt" <(printf 'columns format version: 1\n3 columns:\n`pk` UInt64\n`arr_tuple` Array(Tuple(a UInt64, b String))\n`arr_tuple_nullable` Array(Tuple(a Nullable(UInt64), b String))\n') || {
  printf 'unexpected stock Array(Tuple) column metadata\n' >&2
  exit 1
}
cmp -s "$PART_PATH/columns_substreams.txt" <(printf 'columns substreams version: 1\n3 columns:\n1 substreams for column `pk`:\n\tpk\n4 substreams for column `arr_tuple`:\n\tarr_tuple.size0\n\tarr_tuple%%2Ea\n\tarr_tuple%%2Eb.size\n\tarr_tuple%%2Eb\n5 substreams for column `arr_tuple_nullable`:\n\tarr_tuple_nullable.size0\n\tarr_tuple_nullable%%2Ea.null\n\tarr_tuple_nullable%%2Ea\n\tarr_tuple_nullable%%2Eb.size\n\tarr_tuple_nullable%%2Eb\n') || {
  printf 'unexpected stock Array(Tuple) child stream layout\n' >&2
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
(cd "$FIXTURE_ROOT" && shasum -a 256 part/* > SHA256SUMS)
printf 'generated pinned Array(Tuple) fixture at %s\n' "$OUT"
printf 'schemas: Array(Tuple(a UInt64, b String)) and Array(Tuple(a Nullable(UInt64), b String))\n'
printf 'rows per mark: [2, 2, 2, 1]; codec CODEC(LZ4); mark files .mrk2\n'
