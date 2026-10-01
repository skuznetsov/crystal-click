#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/Users/sergey/.local/bin/clickhouse}"
if [[ "$#" -gt 1 ]]; then
  printf 'usage: %s [qualify|red|capability-only]\n' "$0" >&2
  exit 2
fi
MODE="${1:-qualify}"
case "$MODE" in
  qualify|red|capability-only) ;;
  *) printf 'usage: %s [qualify|red|capability-only]\n' "$0" >&2; exit 2 ;;
esac

TMP_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/crystal-click-w110-red.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

if [[ ! -x "$CLICKHOUSE_BIN" ]]; then
  printf 'ClickHouse executable not found or not executable: %s\n' "$CLICKHOUSE_BIN" >&2
  exit 1
fi

EXPECTED_VERSION='ClickHouse local version 26.7.1.1315 (official build).'
ACTUAL_VERSION="$("$CLICKHOUSE_BIN" local --version)"
if [[ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]]; then
  printf 'W110 oracle requires %s, got %s\n' "$EXPECTED_VERSION" "$ACTUAL_VERSION" >&2
  exit 1
fi

cd "$ROOT"
export CLICKHOUSE_BIN
export W110_MODE="$MODE"
export W110_STORE="$TMP_ROOT/clickhouse-store"
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache"
mkdir -p "$W110_STORE" "$CRYSTAL_CACHE_DIR"

# `qualify` is the repeatable passing storage/admission-baseline gate.
# `red` runs the same full certificate and exits 1 only for the measured
# predecessor typed refusals after all five stock profiles pass.
crystal run --single-module --link-flags='-fuse-ld=ld' "$ROOT/scripts/probe_geo_array_w110_red.cr"
