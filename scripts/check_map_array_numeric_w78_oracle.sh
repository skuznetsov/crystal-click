#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/Users/sergey/.local/bin/clickhouse}"
EXPECTED_VERSION='ClickHouse local version 26.7.1.1315 (official build).'

if [[ ! -x "$CLICKHOUSE_BIN" ]]; then
  printf 'ClickHouse executable is unavailable; set CLICKHOUSE_BIN to the pinned binary.\n' >&2
  exit 1
fi
ACTUAL_VERSION="$("$CLICKHOUSE_BIN" local --version)"
if [[ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]]; then
  printf 'oracle requires %s, got %s\n' "$EXPECTED_VERSION" "$ACTUAL_VERSION" >&2
  exit 1
fi

ORACLE_MODE="${W78_ORACLE_MODE:-full}"
case "$ORACLE_MODE" in
  stock|reader|full) ;;
  *) printf 'W78_ORACLE_MODE must be stock, reader, or full.\n' >&2; exit 1 ;;
esac

TMP_ROOT="$(mktemp -d /private/tmp/crystal-click-map-array-numeric-w78.XXXXXX)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

cd "$ROOT"
export CLICKHOUSE_BIN
export CLICKHOUSE_STORE="$TMP_ROOT/clickhouse-store"
export ORACLE_ROOT="$TMP_ROOT"
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache"
mkdir -p "$CRYSTAL_CACHE_DIR"

case "$ORACLE_MODE" in
  stock)
    crystal run --link-flags='-fuse-ld=ld' scripts/check_map_array_numeric_w78_oracle.cr
    ;;
  reader)
    crystal run -D w78_reader --link-flags='-fuse-ld=ld' scripts/check_map_array_numeric_w78_oracle.cr
    ;;
  full)
    crystal run -D w78_reader -D w78_writer --link-flags='-fuse-ld=ld' scripts/check_map_array_numeric_w78_oracle.cr
    ;;
esac
