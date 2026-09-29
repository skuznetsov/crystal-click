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

ORACLE_MODE="${W79_ORACLE_MODE:-stock}"
case "$ORACLE_MODE" in
  stock|reader|full) ;;
  *) printf 'W79_ORACLE_MODE must be stock, reader, or full.\n' >&2; exit 1 ;;
esac

TMP_ROOT="$(mktemp -d /private/tmp/crystal-click-map-array-nullable-numeric-w79.XXXXXX)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

cd "$ROOT"
export CLICKHOUSE_BIN
export CLICKHOUSE_STORE="$TMP_ROOT/clickhouse-store"
export ORACLE_ROOT="$TMP_ROOT"
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache"
mkdir -p "$CRYSTAL_CACHE_DIR"

case "$ORACLE_MODE" in
  stock)
    crystal run --link-flags='-fuse-ld=ld' scripts/check_map_array_nullable_numeric_w79_oracle.cr
    ;;
  reader)
    crystal run -D w79_reader --link-flags='-fuse-ld=ld' scripts/check_map_array_nullable_numeric_w79_oracle.cr
    ;;
  full)
    crystal run -D w79_reader -D w79_writer --link-flags='-fuse-ld=ld' scripts/check_map_array_nullable_numeric_w79_oracle.cr
    ;;
esac
