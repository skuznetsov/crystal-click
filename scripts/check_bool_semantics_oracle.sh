#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/Users/sergey/.local/bin/clickhouse}"
TMP_ROOT="$(mktemp -d /private/tmp/crystal-click-bool-semantics.XXXXXX)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

if [[ ! -x "$CLICKHOUSE_BIN" ]]; then
  printf 'ClickHouse executable not found or not executable: %s\n' "$CLICKHOUSE_BIN" >&2
  exit 1
fi

EXPECTED_VERSION='ClickHouse local version 26.7.1.1315 (official build).'
ACTUAL_VERSION="$("$CLICKHOUSE_BIN" local --version)"
if [[ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]]; then
  printf 'oracle requires %s, got %s\n' "$EXPECTED_VERSION" "$ACTUAL_VERSION" >&2
  exit 1
fi

cd "$ROOT"
export CLICKHOUSE_BIN
export BOOL_SEMANTICS_STORE="$TMP_ROOT/clickhouse-store"
export BOOL_SEMANTICS_WRITER_ROOT="$TMP_ROOT/writer-parts"
export BOOL_SEMANTICS_CATALOG_ROOT="$TMP_ROOT/catalog-fixtures"
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache"
mkdir -p "$BOOL_SEMANTICS_STORE" "$BOOL_SEMANTICS_WRITER_ROOT" "$BOOL_SEMANTICS_CATALOG_ROOT" "$CRYSTAL_CACHE_DIR"

crystal run --link-flags='-fuse-ld=ld' "$ROOT/scripts/check_bool_semantics_oracle.cr"

printf 'PASS Bool semantics oracle on ClickHouse %s\n' "$ACTUAL_VERSION"
