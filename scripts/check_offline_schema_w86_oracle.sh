#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-$(command -v clickhouse || true)}"
EXPECTED_VERSION='ClickHouse local version 26.7.1.1315 (official build).'

if [[ -z "$CLICKHOUSE_BIN" ]] || ! command -v "$CLICKHOUSE_BIN" >/dev/null 2>&1; then
  printf 'SKIP W86 stock oracle: ClickHouse not found; set CLICKHOUSE_BIN to 26.7.1.1315\n' >&2
  exit 77
fi
CLICKHOUSE_BIN="$(command -v "$CLICKHOUSE_BIN")"

if ! ACTUAL_VERSION="$("$CLICKHOUSE_BIN" local --version 2>/dev/null)"; then
  printf 'W86 stock oracle could not run ClickHouse at %s\n' "$CLICKHOUSE_BIN" >&2
  exit 1
fi
if [[ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]]; then
  printf 'W86 stock oracle requires %s, got %s\n' "$EXPECTED_VERSION" "$ACTUAL_VERSION" >&2
  exit 1
fi
if ! command -v crystal >/dev/null 2>&1; then
  printf 'W86 stock oracle requires Crystal; add it to PATH\n' >&2
  exit 1
fi

TMP_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/crystal-click-offline-schema-w86.XXXXXX")"
TMP_ROOT="$(CDPATH= cd -- "$TMP_ROOT" && pwd -P)"
TMPDIR="$TMP_ROOT"
export TMPDIR
trap 'rm -rf -- "$TMP_ROOT"' EXIT

cd "$ROOT"
export CLICKHOUSE_BIN
export CLICKHOUSE_STORE="$TMP_ROOT/clickhouse-store"
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache"
CC="${CC:-/usr/bin/clang}"
export CC
mkdir -p "$CRYSTAL_CACHE_DIR"

crystal run --link-flags='-fuse-ld=ld' scripts/check_offline_schema_w86_oracle.cr
