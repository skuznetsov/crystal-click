#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || ( "$1" != "--red" && "$1" != "--green" && "$1" != "--green-reader" && "$1" != "--green-writer" && "$1" != "--green-writer-smoke" ) ]]; then
  printf 'usage: %s --red|--green|--green-reader|--green-writer|--green-writer-smoke\n' "$0" >&2
  exit 2
fi

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/Users/sergey/.local/bin/clickhouse}"
EXPECTED_VERSION='ClickHouse local version 26.7.1.1315 (official build).'

if [[ ! -x "$CLICKHOUSE_BIN" ]]; then
  printf 'ClickHouse executable not found or not executable: %s\n' "$CLICKHOUSE_BIN" >&2
  exit 1
fi

ACTUAL_VERSION="$("$CLICKHOUSE_BIN" local --version)"
if [[ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]]; then
  printf 'oracle requires %s, got %s\n' "$EXPECTED_VERSION" "$ACTUAL_VERSION" >&2
  exit 1
fi

TMP_ROOT="$(mktemp -d /private/tmp/crystal-click-timezone-temporal.XXXXXX)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

cd "$ROOT"
export CLICKHOUSE_BIN
export W104_CLICKHOUSE_STORE="$TMP_ROOT/clickhouse-store"
export W104_ZONE_MANIFEST="$ROOT/spec/fixtures/stock_timezone_names_26_7.txt"
export W104_ORACLE_VERSION="$ACTUAL_VERSION"
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache"
mkdir -p "$W104_CLICKHOUSE_STORE" "$CRYSTAL_CACHE_DIR"

crystal run --link-flags='-fuse-ld=ld' "$ROOT/scripts/check_timezone_temporal_oracle.cr" -- "$1"

if [[ "$1" == "--red" ]]; then
  printf 'PASS timezone-qualified temporal stock RED oracle on %s\n' "$ACTUAL_VERSION"
elif [[ "$1" == "--green" ]]; then
  printf 'PASS timezone-qualified temporal bidirectional GREEN oracle on %s\n' "$ACTUAL_VERSION"
elif [[ "$1" == "--green-reader" ]]; then
  printf 'PASS timezone-qualified temporal reader phase on %s\n' "$ACTUAL_VERSION"
elif [[ "$1" == "--green-writer" ]]; then
  printf 'PASS timezone-qualified temporal writer phase on %s\n' "$ACTUAL_VERSION"
else
  printf 'PASS timezone-qualified temporal writer-mark smoke (one profile; not exhaustive GREEN) on %s\n' "$ACTUAL_VERSION"
fi
