#!/usr/bin/env bash
set -euo pipefail

W83_REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/Users/sergey/.local/bin/clickhouse}"
W83_EXPECTED_VERSION='ClickHouse local version 26.7.1.1315 (official build).'

if [[ ! -x "$CLICKHOUSE_BIN" ]]; then
  printf 'ClickHouse executable is unavailable; set CLICKHOUSE_BIN to the pinned binary.\n' >&2
  exit 1
fi
W83_ACTUAL_VERSION="$("$CLICKHOUSE_BIN" local --version)"
if [[ "$W83_ACTUAL_VERSION" != "$W83_EXPECTED_VERSION" ]]; then
  printf 'oracle requires %s, got %s\n' "$W83_EXPECTED_VERSION" "$W83_ACTUAL_VERSION" >&2
  exit 1
fi

W83_MODE="${W83_ORACLE_MODE:-full}"
case "$W83_MODE" in
  stock) W83_DEFINES=() ;;
  reader) W83_DEFINES=(-D w83_reader) ;;
  writer) W83_DEFINES=(-D w83_writer) ;;
  full) W83_DEFINES=(-D w83_reader -D w83_writer) ;;
  *) printf 'W83_ORACLE_MODE must be stock, reader, writer, or full.\n' >&2; exit 1 ;;
esac

W83_ORACLE_TMP_ROOT="$(mktemp -d /private/tmp/crystal-click-array-map-bool-w83.XXXXXX)"
trap 'rm -rf -- "$W83_ORACLE_TMP_ROOT"' EXIT

cd "$W83_REPO_ROOT"
export CLICKHOUSE_BIN
export CLICKHOUSE_STORE="$W83_ORACLE_TMP_ROOT/clickhouse-store"
export ORACLE_ROOT="$W83_ORACLE_TMP_ROOT"
export CRYSTAL_CACHE_DIR="$W83_ORACLE_TMP_ROOT/crystal-cache"
export W83_ORACLE_MODE="$W83_MODE"
mkdir -p "$CRYSTAL_CACHE_DIR"

crystal run "${W83_DEFINES[@]}" --link-flags='-fuse-ld=ld' scripts/check_array_map_bool_values_w83_oracle.cr
