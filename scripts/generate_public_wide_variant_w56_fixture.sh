#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/Users/sergey/.local/bin/clickhouse}"
FIXTURE_ROOT="${W56_FIXTURE_ROOT:-$ROOT/test/fixtures/public/wide_variant_w56}"
PROFILE="${1:-compact}"
case "$PROFILE" in
  compact) COMPACT_DISCRIMINATORS=1 ;;
  basic) COMPACT_DISCRIMINATORS=0 ;;
  *) printf 'unknown W56 fixture profile: %s\n' "$PROFILE" >&2; exit 2 ;;
esac
FIXTURE="$FIXTURE_ROOT/$PROFILE"
OUT="$FIXTURE/part"
EXPECTED_VERSION='ClickHouse local version 26.7.1.1315 (official build).'

if [[ -e "$FIXTURE" || -L "$FIXTURE" ]]; then
  printf 'fixture exists; refusing to replace it: %s\n' "$FIXTURE" >&2
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

TMP_ROOT="$(mktemp -d /private/tmp/crystal-click-wide-variant-w56-fixture.XXXXXX)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT
STORE="$TMP_ROOT/store"

"$CLICKHOUSE_BIN" local --path "$STORE" --query "
CREATE TABLE source
(
    pk UInt64,
    payload Variant(String, UInt64)
)
ENGINE = MergeTree
ORDER BY pk
SETTINGS
    index_granularity = 3,
    index_granularity_bytes = 10485760,
    enable_mixed_granularity_parts = 1,
    min_rows_for_wide_part = 0,
    min_bytes_for_wide_part = 0,
    compress_marks = 0,
    min_compress_block_size = 0,
    max_compress_block_size = 4096,
    ratio_of_defaults_for_sparse_serialization = 1.0,
    default_compression_codec = 'LZ4',
    use_compact_variant_discriminators_serialization = $COMPACT_DISCRIMINATORS
"

"$CLICKHOUSE_BIN" local --path "$STORE" --query "
INSERT INTO source VALUES
    (1, CAST('alpha', 'Variant(String, UInt64)')),
    (2, CAST(toUInt64(42), 'Variant(String, UInt64)')),
    (3, CAST(NULL, 'Variant(String, UInt64)')),
    (4, CAST(NULL, 'Variant(String, UInt64)')),
    (5, CAST(NULL, 'Variant(String, UInt64)')),
    (6, CAST(NULL, 'Variant(String, UInt64)')),
    (7, CAST('', 'Variant(String, UInt64)'))
"

PART_PATH="$("$CLICKHOUSE_BIN" local --path "$STORE" --query "SELECT path FROM system.parts WHERE table = 'source' AND active FORMAT TSVRaw")"
[[ -d "$PART_PATH" && ! -L "$PART_PATH" ]] || { printf 'stock part not found\n' >&2; exit 1; }
INTEGRITY="$("$CLICKHOUSE_BIN" local --path "$STORE" --query "CHECK TABLE source FORMAT TabSeparated")"
[[ "$INTEGRITY" == $'all_1_1_0\t1\t' ]] || { printf 'stock CHECK TABLE failed: %q\n' "$INTEGRITY" >&2; exit 1; }
cmp -s "$PART_PATH/columns.txt" <(printf 'columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` Variant(String, UInt64)\n') || {
  printf 'unexpected stock Variant column metadata\n' >&2
  exit 1
}
cmp -s "$PART_PATH/columns_substreams.txt" <(printf 'columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n4 substreams for column `payload`:\n\tpayload.variant_discr\n\tpayload.String.size\n\tpayload.String\n\tpayload.UInt64\n') || {
  printf 'unexpected stock Variant child-stream layout\n' >&2
  exit 1
}
[[ "$(<"$PART_PATH/count.txt")" == 7 ]] || { printf 'unexpected stock row count\n' >&2; exit 1; }
[[ "$(<"$PART_PATH/default_compression_codec.txt")" == 'CODEC(LZ4)' ]] || {
  printf 'unexpected stock codec\n' >&2
  exit 1
}
[[ -z "$(find "$PART_PATH" -mindepth 1 -type l -print -quit)" ]] || { printf 'stock part contains symlinks\n' >&2; exit 1; }

mkdir -p "$FIXTURE"
cp -R "$PART_PATH" "$OUT"
(cd "$FIXTURE" && shasum -a 256 part/* > SHA256SUMS)
bash "$ROOT/scripts/verify_stock_wide_variant_w56_fixture.sh" "$PROFILE"
printf 'generated pinned Variant(String, UInt64) %s fixture at %s\n' "${PROFILE^^}" "$OUT"
printf 'rows per mark: [3, 3, 1]; tags: String/UInt64/NULL; codec CODEC(LZ4); marks .mrk2\n'
