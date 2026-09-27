#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/Users/sergey/.local/bin/clickhouse}"
OUT="${W28_ARRAY_ARRAY_FIXTURE_OUT:-$ROOT/test/fixtures/public/wide_array_array_uint64/part}"
EXPECTED_VERSION='ClickHouse local version 26.7.1.1315 (official build).'

if [[ "${1:-}" != '' ]]; then
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

TMP_ROOT="$(mktemp -d /private/tmp/crystal-click-array-array-fixture.XXXXXX)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT
STORE="$TMP_ROOT/store"

"$CLICKHOUSE_BIN" local --path "$STORE" --query "
CREATE TABLE source
(
    pk UInt64,
    payload Array(Array(UInt64))
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
    (1, CAST([], 'Array(Array(UInt64))')),
    (2, CAST([[], [0, 18446744073709551615], []], 'Array(Array(UInt64))')),
    (4, CAST([[42], []], 'Array(Array(UInt64))')),
    (6, CAST([], 'Array(Array(UInt64))')),
    (9, CAST([[], []], 'Array(Array(UInt64))')),
    (11, CAST([[1, 2, 3]], 'Array(Array(UInt64))')),
    (13, CAST([], 'Array(Array(UInt64))'))
"

PART_PATH="$("$CLICKHOUSE_BIN" local --path "$STORE" --query "SELECT path FROM system.parts WHERE table = 'source' AND active FORMAT TSVRaw")"
[[ -d "$PART_PATH" && ! -L "$PART_PATH" ]] || { printf 'stock part not found\n' >&2; exit 1; }
INTEGRITY="$("$CLICKHOUSE_BIN" local --path "$STORE" --query "CHECK TABLE source FORMAT TabSeparated")"
[[ "$INTEGRITY" == $'all_1_1_0\t1\t' ]] || { printf 'stock CHECK TABLE failed: %q\n' "$INTEGRITY" >&2; exit 1; }
cmp -s "$PART_PATH/columns_substreams.txt" <(printf 'columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n3 substreams for column `payload`:\n\tpayload.size0\n\tpayload.size1\n\tpayload\n') || {
  printf 'unexpected stock Array(Array(UInt64)) stream layout\n' >&2
  exit 1
}

mkdir -p "$(dirname -- "$OUT")"
cp -R "$PART_PATH" "$OUT"
printf 'generated %s\n' "$OUT"
