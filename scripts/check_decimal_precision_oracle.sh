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
  printf 'W102 oracle requires %s, got %s\n' "$EXPECTED_VERSION" "$ACTUAL_VERSION" >&2
  exit 1
fi

TMP_ROOT="$(mktemp -d /private/tmp/crystal-click-decimal-precision-w102-oracle.XXXXXX)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

cd "$ROOT"
export CLICKHOUSE_BIN
export W102_STORE="$TMP_ROOT/clickhouse-store"
export W102_WRITER_ROOT="$TMP_ROOT/writer-parts"
export W102_ORACLE_ROOT="$TMP_ROOT/catalogs"
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache"
mkdir -p "$W102_STORE" "$W102_WRITER_ROOT" "$W102_ORACLE_ROOT" "$CRYSTAL_CACHE_DIR"

crystal run --link-flags='-fuse-ld=ld' "$ROOT/scripts/check_decimal_precision_oracle.cr"
