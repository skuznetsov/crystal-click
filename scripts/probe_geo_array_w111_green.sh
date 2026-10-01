#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/Users/sergey/.local/bin/clickhouse}"

if [[ "$#" -ne 1 ]]; then
  printf 'usage: %s --green-reader|--green-writer\n' "$0" >&2
  exit 2
fi
MODE="$1"
case "$MODE" in
  --green-reader|--green-writer) ;;
  *) printf 'usage: %s --green-reader|--green-writer\n' "$0" >&2; exit 2 ;;
esac

TMP_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/crystal-click-w111-green.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

if [[ ! -x "$CLICKHOUSE_BIN" ]]; then
  printf 'ClickHouse executable not found or not executable: %s\n' "$CLICKHOUSE_BIN" >&2
  exit 1
fi

EXPECTED_VERSION='ClickHouse local version 26.7.1.1315 (official build).'
ACTUAL_VERSION="$("$CLICKHOUSE_BIN" local --version)"
if [[ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]]; then
  printf 'W111 GREEN requires %s, got %s\n' "$EXPECTED_VERSION" "$ACTUAL_VERSION" >&2
  exit 1
fi

cd "$ROOT"
export CLICKHOUSE_BIN
export W111G_STORE="$TMP_ROOT/clickhouse-store"
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache"
mkdir -p "$W111G_STORE" "$CRYSTAL_CACHE_DIR"

crystal run --single-module --link-flags='-fuse-ld=ld' "$ROOT/scripts/probe_geo_array_w111_green.cr" -- "$MODE"
