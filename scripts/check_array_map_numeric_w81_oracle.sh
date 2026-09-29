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

MODE="${W81_ORACLE_MODE:-full}"
case "$MODE" in
  stock) DEFINES=() ;;
  reader) DEFINES=(-D w81_reader) ;;
  full) DEFINES=(-D w81_reader -D w81_writer) ;;
  *) printf 'W81_ORACLE_MODE must be stock, reader, or full.\n' >&2; exit 1 ;;
esac

TMP_ROOT="$(mktemp -d /private/tmp/crystal-click-array-map-numeric-w81.XXXXXX)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

cd "$ROOT"
export CLICKHOUSE_BIN
export CLICKHOUSE_STORE="$TMP_ROOT/clickhouse-store"
export ORACLE_ROOT="$TMP_ROOT"
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache"
export W81_ORACLE_MODE="$MODE"
mkdir -p "$CRYSTAL_CACHE_DIR"

crystal run "${DEFINES[@]}" --link-flags='-fuse-ld=ld' scripts/check_array_map_numeric_w81_oracle.cr
