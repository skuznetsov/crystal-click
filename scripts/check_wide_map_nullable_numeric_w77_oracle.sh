#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/Users/sergey/.local/bin/clickhouse}"
EXPECTED_VERSION='ClickHouse local version 26.7.1.1315 (official build).'

[[ -x "$CLICKHOUSE_BIN" ]] || { printf 'ClickHouse executable not found: %s\n' "$CLICKHOUSE_BIN" >&2; exit 1; }
ACTUAL_VERSION="$("$CLICKHOUSE_BIN" local --version)"
[[ "$ACTUAL_VERSION" == "$EXPECTED_VERSION" ]] || {
  printf 'oracle requires %s, got %s\n' "$EXPECTED_VERSION" "$ACTUAL_VERSION" >&2
  exit 1
}

TMP_ROOT="$(mktemp -d /private/tmp/crystal-click-map-nullable-numeric-w77.XXXXXX)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

cd "$ROOT"
export CLICKHOUSE_BIN
export CLICKHOUSE_STORE="$TMP_ROOT/clickhouse-store"
export ORACLE_ROOT="$TMP_ROOT"
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache"
mkdir -p "$CRYSTAL_CACHE_DIR"

crystal run --link-flags='-fuse-ld=ld' scripts/check_wide_map_nullable_numeric_w77_oracle.cr
