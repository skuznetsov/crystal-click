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

TMP_ROOT="$(mktemp -d /private/tmp/crystal-click-dynamic-w75-oracle.XXXXXX)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT
CLICKHOUSE_STORE="$TMP_ROOT/clickhouse-store"

create_table() {
  local table="$1"
  "$CLICKHOUSE_BIN" local --path "$CLICKHOUSE_STORE" --query "
CREATE TABLE default.${table}
(
    pk UInt64,
    payload Dynamic
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
    default_compression_codec = 'LZ4';
"
}

create_table dynamic_stock_string_first
"$CLICKHOUSE_BIN" local --path "$CLICKHOUSE_STORE" --query "
INSERT INTO default.dynamic_stock_string_first
SELECT * FROM
(
    SELECT toUInt64(1) AS pk, CAST('alpha', 'Dynamic') AS payload
    UNION ALL SELECT toUInt64(2), CAST(toUInt64(0), 'Dynamic')
    UNION ALL SELECT toUInt64(3), CAST(NULL, 'Dynamic')
    UNION ALL SELECT toUInt64(4), CAST('', 'Dynamic')
    UNION ALL SELECT toUInt64(5), CAST(unhex('610062'), 'Dynamic')
    UNION ALL SELECT toUInt64(6), CAST(NULL, 'Dynamic')
    UNION ALL SELECT toUInt64(7), CAST(toUInt64(18446744073709551615), 'Dynamic')
)
"

create_table dynamic_stock_u64_first
"$CLICKHOUSE_BIN" local --path "$CLICKHOUSE_STORE" --query "
INSERT INTO default.dynamic_stock_u64_first
SELECT * FROM
(
    SELECT toUInt64(1) AS pk, CAST(toUInt64(42), 'Dynamic') AS payload
    UNION ALL SELECT toUInt64(2), CAST('s', 'Dynamic')
    UNION ALL SELECT toUInt64(3), CAST(NULL, 'Dynamic')
    UNION ALL SELECT toUInt64(4), CAST(toUInt64(18446744073709551615), 'Dynamic')
    UNION ALL SELECT toUInt64(5), CAST('', 'Dynamic')
    UNION ALL SELECT toUInt64(6), CAST(NULL, 'Dynamic')
    UNION ALL SELECT toUInt64(7), CAST('tail', 'Dynamic')
)
"

stock_part_path() {
  local table="$1"
  local table_path
  table_path="$("$CLICKHOUSE_BIN" local --path "$CLICKHOUSE_STORE" --query "
SELECT data_paths[1]
FROM system.tables
WHERE database = 'default' AND name = '${table}'
FORMAT TSVRaw
")"
  if [[ -z "$table_path" || ! -d "$table_path" ]]; then
    printf 'stock table data path is missing: %s\n' "$table_path" >&2
    exit 1
  fi
  local part
  part="$(find "$table_path" -mindepth 1 -maxdepth 1 -type d -name 'all_*' -print -quit)"
  if [[ -z "$part" || ! -d "$part" ]]; then
    printf 'stock Dynamic Wide part missing for table %s\n' "$table" >&2
    exit 1
  fi
  local part_count
  part_count="$("$CLICKHOUSE_BIN" local --path "$CLICKHOUSE_STORE" --query "
SELECT count()
FROM system.parts
WHERE database = 'default' AND table = '${table}' AND active
FORMAT TSVRaw
")"
  if [[ "$part_count" != 1 ]]; then
    printf 'expected one stock part for %s, got %s\n' "$table" "$part_count" >&2
    exit 1
  fi
  printf '%s' "$part"
}

STOCK_STRING_FIRST_PART="$(stock_part_path dynamic_stock_string_first)"
STOCK_U64_FIRST_PART="$(stock_part_path dynamic_stock_u64_first)"

export CLICKHOUSE_BIN CLICKHOUSE_STORE TMP_ROOT STOCK_STRING_FIRST_PART STOCK_U64_FIRST_PART
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache"
mkdir -p "$CRYSTAL_CACHE_DIR"

cd "$ROOT"
crystal run --link-flags='-fuse-ld=ld' scripts/check_dynamic_w75_oracle.cr
