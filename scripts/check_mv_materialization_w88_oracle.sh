#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
REQUESTED_CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-clickhouse}"
CLICKHOUSE_BIN="$REQUESTED_CLICKHOUSE_BIN"
case "$CLICKHOUSE_BIN" in
  /*) ;;
  */*) CLICKHOUSE_BIN="$PWD/$CLICKHOUSE_BIN" ;;
  *)
    RESOLVED_CLICKHOUSE_BIN="$(command -v "$CLICKHOUSE_BIN" || true)"
    if [[ -z "$RESOLVED_CLICKHOUSE_BIN" ]]; then
      printf 'ClickHouse executable not found: %s\n' "$REQUESTED_CLICKHOUSE_BIN" >&2
      exit 1
    fi
    CLICKHOUSE_BIN="$RESOLVED_CLICKHOUSE_BIN"
    ;;
esac

# Resolve relative TMPDIR against the caller's directory before changing cwd.
TMP_PARENT="${TMPDIR:-/private/tmp}"
case "$TMP_PARENT" in
  /*) ;;
  *) TMP_PARENT="$PWD/$TMP_PARENT" ;;
esac
TMP_PARENT="$(CDPATH= cd -- "$TMP_PARENT" && pwd -P)"
TMP_ROOT="$(mktemp -d "$TMP_PARENT/crystal-click-mv-materialization-w88.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

if ! command -v "$CLICKHOUSE_BIN" >/dev/null 2>&1; then
  printf 'ClickHouse executable not found: %s\n' "$CLICKHOUSE_BIN" >&2
  exit 1
fi

EXPECTED_VERSION='ClickHouse local version 26.7.1.1315 (official build).'
ACTUAL_VERSION="$("$CLICKHOUSE_BIN" local --version)"
if [[ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]]; then
  printf 'oracle requires %s, got %s\n' "$EXPECTED_VERSION" "$ACTUAL_VERSION" >&2
  exit 1
fi

export CLICKHOUSE_BIN TMP_ROOT
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache"
mkdir -p "$CRYSTAL_CACHE_DIR"
cd "$ROOT"
crystal run --link-flags='-fuse-ld=ld' "$ROOT/scripts/check_mv_materialization_w88_oracle.cr"
