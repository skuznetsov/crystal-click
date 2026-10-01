#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/Users/sergey/.local/bin/clickhouse}"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/crystal-click-w109-red.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

if [[ ! -x "$CLICKHOUSE_BIN" ]]; then
  printf 'ClickHouse executable not found or not executable: %s\n' "$CLICKHOUSE_BIN" >&2
  exit 1
fi

EXPECTED_VERSION='ClickHouse local version 26.7.1.1315 (official build).'
ACTUAL_VERSION="$("$CLICKHOUSE_BIN" local --version)"
if [[ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]]; then
  printf 'W109 oracle requires %s, got %s\n' "$EXPECTED_VERSION" "$ACTUAL_VERSION" >&2
  exit 1
fi

cd "$ROOT"
export CLICKHOUSE_BIN
export W109_STORE="$TMP_ROOT/clickhouse-store"
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache"
mkdir -p "$W109_STORE" "$CRYSTAL_CACHE_DIR"

# Exit 1 is the expected predecessor RED only after the Point source and
# fresh-ATTACH copies pass exact stock physical, metadata, CHECK and RowBinary
# qualifications. Any earlier failure is an oracle/instrument failure.
crystal run --single-module --link-flags='-fuse-ld=ld' "$ROOT/scripts/probe_point_w109_red.cr"
