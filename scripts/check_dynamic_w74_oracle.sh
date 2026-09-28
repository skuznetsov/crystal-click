#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/Users/sergey/.local/bin/clickhouse}"
EXPECTED_VERSION='ClickHouse local version 26.7.1.1315 (official build).'

if [[ ! -x "$CLICKHOUSE_BIN" ]]; then
  printf 'ClickHouse executable not found: %s\n' "$CLICKHOUSE_BIN" >&2
  exit 1
fi
ACTUAL_VERSION="$("$CLICKHOUSE_BIN" local --version)"
if [[ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]]; then
  printf 'oracle requires %s, got %s\n' "$EXPECTED_VERSION" "$ACTUAL_VERSION" >&2
  exit 1
fi

TMP_ROOT="$(mktemp -d /private/tmp/crystal-click-dynamic-w74-oracle.XXXXXX)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT
STORE="$TMP_ROOT/clickhouse-store"

"$CLICKHOUSE_BIN" local --path "$STORE" --query "
CREATE TABLE default.dynamic_stock
(
    pk UInt64,
    payload Dynamic
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
    default_compression_codec = 'LZ4';
"
"$CLICKHOUSE_BIN" local --path "$STORE" --query "
INSERT INTO default.dynamic_stock (pk, payload) VALUES
    (1, 'alpha'),
    (2, ''),
    (3, 'beta'),
    (4, unhex('610062')),
    (5, 'tail');
"

"$CLICKHOUSE_BIN" local --path "$STORE" --query "
CREATE TABLE default.dynamic_stock_empty
(
    pk UInt64,
    payload Dynamic
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
    default_compression_codec = 'LZ4';
"
"$CLICKHOUSE_BIN" local --path "$STORE" --query "
INSERT INTO default.dynamic_stock_empty (pk, payload)
SELECT number + 1, '' FROM numbers(130);
"

STOCK_TABLE_PATH="$("$CLICKHOUSE_BIN" local --path "$STORE" --query "
SELECT data_paths[1]
FROM system.tables
WHERE database = 'default' AND name = 'dynamic_stock'
FORMAT TSVRaw
")"
if [[ -z "$STOCK_TABLE_PATH" || ! -d "$STOCK_TABLE_PATH" ]]; then
  printf 'stock Dynamic table data path is missing: %s\n' "$STOCK_TABLE_PATH" >&2
  exit 1
fi
STOCK_PART_PATH="$(find "$STOCK_TABLE_PATH" -mindepth 1 -maxdepth 1 -type d -name 'all_*' -print -quit)"
if [[ -z "$STOCK_PART_PATH" || ! -d "$STOCK_PART_PATH" ]]; then
  printf 'stock Dynamic Wide part was not produced under: %s\n' "$STOCK_TABLE_PATH" >&2
  exit 1
fi
EMPTY_TABLE_PATH="$("$CLICKHOUSE_BIN" local --path "$STORE" --query "
SELECT data_paths[1]
FROM system.tables
WHERE database = 'default' AND name = 'dynamic_stock_empty'
FORMAT TSVRaw
")"
EMPTY_STOCK_PART_PATH="$(find "$EMPTY_TABLE_PATH" -mindepth 1 -maxdepth 1 -type d -name 'all_*' -print -quit)"
if [[ -z "$EMPTY_STOCK_PART_PATH" || ! -d "$EMPTY_STOCK_PART_PATH" ]]; then
  printf 'all-empty stock Dynamic Wide part was not produced under: %s\n' "$EMPTY_TABLE_PATH" >&2
  exit 1
fi

cd "$ROOT"
export CLICKHOUSE_BIN TMP_ROOT STOCK_PART_PATH EMPTY_STOCK_PART_PATH
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache"
mkdir -p "$CRYSTAL_CACHE_DIR"
crystal run --link-flags='-fuse-ld=ld' scripts/check_dynamic_w74_oracle.cr
