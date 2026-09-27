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

TMP_ROOT="$(mktemp -d /private/tmp/crystal-click-fixed-string-array-oracle.XXXXXX)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

cd "$ROOT"
scripts/verify_stock_fixed_string_array_fixture.sh
export CLICKHOUSE_BIN
export CLICKHOUSE_STORE="$TMP_ROOT/clickhouse-store"
export ORACLE_ROOT="$TMP_ROOT"
export STOCK_PART="$ROOT/test/fixtures/public/wide_array_fixed_string/part"
export STOCK_KEYED_PART="$ROOT/test/fixtures/public/wide_array_fixed_string_keyed/part"
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache"
mkdir -p "$CRYSTAL_CACHE_DIR"

crystal run --link-flags='-fuse-ld=ld' scripts/check_fixed_string_array_oracle.cr
