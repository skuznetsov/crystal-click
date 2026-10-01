#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/Users/sergey/.local/bin/clickhouse}"
MODE="${1:?usage: probe_map_tuple_w108_green.sh --green-reader | --green-writer}"
if [[ "$MODE" != "--green-reader" && "$MODE" != "--green-writer" ]]; then
  printf 'unknown W108 GREEN mode: %s\n' "$MODE" >&2
  exit 2
fi

TMP_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/crystal-click-w108-green.XXXXXX")"
TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

if [[ ! -x "$CLICKHOUSE_BIN" ]]; then
  printf 'ClickHouse executable not found or not executable: %s\n' "$CLICKHOUSE_BIN" >&2
  exit 1
fi

EXPECTED_VERSION='ClickHouse local version 26.7.1.1315 (official build).'
ACTUAL_VERSION="$("$CLICKHOUSE_BIN" local --version)"
if [[ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]]; then
  printf 'W108 GREEN requires %s, got %s\n' "$EXPECTED_VERSION" "$ACTUAL_VERSION" >&2
  exit 1
fi

cd "$ROOT"
export CLICKHOUSE_BIN
export W108G_STORE="$TMP_ROOT/clickhouse-store"
export W108G_CATALOG_ROOT="$TMP_ROOT/catalogs"
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache"
mkdir -p "$W108G_STORE" "$W108G_CATALOG_ROOT" "$CRYSTAL_CACHE_DIR"

# Reader and writer are separate fresh-store certificates. Each mode retains
# the five independently qualified String/UInt64 mixed/all-empty and external-PK-zero profiles.
crystal run --single-module --link-flags='-fuse-ld=ld' "$ROOT/scripts/probe_map_tuple_w108_green.cr" -- "$MODE"
