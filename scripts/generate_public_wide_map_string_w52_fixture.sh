#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/Users/sergey/.local/bin/clickhouse}"
FIXTURE_ROOT="$ROOT/test/fixtures/public/wide_map_string_w52"
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

TMP_ROOT="$(mktemp -d /private/tmp/crystal-click-map-string-w52-fixture.XXXXXX)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT
STORE="$TMP_ROOT/store"

"$CLICKHOUSE_BIN" local --path "$STORE" --query "
CREATE TABLE source
(
    pk UInt64,
    map_u64 Map(String, UInt64),
    map_string Map(String, String)
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
    (1, CAST(map(), 'Map(String, UInt64)'), CAST(map(), 'Map(String, String)')),
    (2, map('dup', toUInt64(0), 'dup', toUInt64(18446744073709551615)), map('dup', '', 'dup', 'second')),
    (4, map(unhex('410042FF'), toUInt64(42), '雪', toUInt64(7)), map(unhex('410042FF'), concat('binary', char(0), 'value'), '', '')),
    (6, map('empty', toUInt64(18446744073709551615)), map('empty-value', '', 'nonempty-value', 'a longer value crosses the row and mark boundary')),
    (9, CAST(map(), 'Map(String, UInt64)'), CAST(map(), 'Map(String, String)')),
    (11, map('tail', toUInt64(8), '', toUInt64(9)), map('tail', 'emoji💥', 'tail', 'second duplicate')),
    (13, map('end', toUInt64(0)), map('end', 'final'))
"

PART_PATH="$("$CLICKHOUSE_BIN" local --path "$STORE" --query "SELECT path FROM system.parts WHERE table = 'source' AND active FORMAT TSVRaw")"
[[ -d "$PART_PATH" && ! -L "$PART_PATH" ]] || { printf 'stock part not found\n' >&2; exit 1; }
INTEGRITY="$("$CLICKHOUSE_BIN" local --path "$STORE" --query "CHECK TABLE source FORMAT TabSeparated")"
[[ "$INTEGRITY" == $'all_1_1_0\t1\t' ]] || { printf 'stock CHECK TABLE failed: %q\n' "$INTEGRITY" >&2; exit 1; }
[[ "$(<"$PART_PATH/count.txt")" == 7 ]] || { printf 'unexpected stock row count\n' >&2; exit 1; }
[[ "$(<"$PART_PATH/default_compression_codec.txt")" == 'CODEC(LZ4)' ]] || {
  printf 'unexpected stock codec\n' >&2
  exit 1
}
[[ -z "$(find "$PART_PATH" -mindepth 1 -type l -print -quit)" ]] || { printf 'stock part contains symlinks\n' >&2; exit 1; }

mkdir -p "$FIXTURE_ROOT"
cp -R "$PART_PATH" "$OUT"
(cd "$FIXTURE_ROOT" && shasum -a 256 part/* > SHA256SUMS)
printf 'generated pinned String-key Map fixture at %s\n' "$OUT"
printf 'schemas: Map(String, UInt64) and Map(String, String)\n'
printf 'rows per mark: [2, 2, 2, 1]; codec CODEC(LZ4); mark files .mrk2\n'
