#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"

if [[ "$#" -ne 1 ]]; then
  printf 'Usage: %s fixtures|stock-capture|qualify|red\n' "$0" >&2
  exit 2
fi
MODE="$1"
case "$MODE" in
  fixtures|stock-capture|qualify|red) ;;
  *) printf 'Usage: %s fixtures|stock-capture|qualify|red\n' "$0" >&2; exit 2 ;;
esac

if [[ "$MODE" != fixtures ]]; then
  CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-}"
  if [[ -z "$CLICKHOUSE_BIN" || ! -x "$CLICKHOUSE_BIN" ]]; then
    printf 'Set CLICKHOUSE_BIN to the isolated W114 ClickHouse executable\n' >&2
    exit 1
  fi
  export CLICKHOUSE_BIN
fi

CRYSTAL_BIN="${CRYSTAL_BIN:-$(command -v crystal || true)}"
if [[ -z "$CRYSTAL_BIN" || ! -x "$CRYSTAL_BIN" ]]; then
  printf 'Set CRYSTAL_BIN to the Crystal executable\n' >&2
  exit 1
fi

KEEP_TMP="${W114_KEEP_TMP:-0}"
if [[ "$KEEP_TMP" != 0 && "$KEEP_TMP" != 1 ]]; then
  printf 'W114_KEEP_TMP must be 0 or 1\n' >&2
  exit 2
fi

TMP_ROOT="$(mktemp -d /private/tmp/crystal-click-w114.XXXXXX)"
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)"
case "$TMP_ROOT" in
  /private/tmp/crystal-click-w114.*) ;;
  *) printf 'Refusing unexpected W114 temporary root: %s\n' "$TMP_ROOT" >&2; exit 1 ;;
esac
if [[ ! -d "$TMP_ROOT" || -L "$TMP_ROOT" ]]; then
  printf 'Refusing invalid W114 temporary root: %s\n' "$TMP_ROOT" >&2
  exit 1
fi

cleanup() {
  if [[ "$KEEP_TMP" == 1 ]]; then
    printf 'W114 retained temporary root: %s\n' "$TMP_ROOT"
  elif [[ "$TMP_ROOT" == /private/tmp/crystal-click-w114.* && -d "$TMP_ROOT" && ! -L "$TMP_ROOT" ]]; then
    rm -rf -- "$TMP_ROOT"
  fi
}
trap cleanup EXIT

cd "$ROOT"
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache"
mkdir -p "$CRYSTAL_CACHE_DIR"
case "$MODE" in
  stock-capture) export W114_CAPTURE_STORE="$TMP_ROOT/store" ;;
  qualify|red) export W114_STORE="$TMP_ROOT/store" ;;
esac

printf 'W114 mode=%s root=%s store=%s cache=%s keep=%s\n' \
  "$MODE" "$TMP_ROOT" "${W114_STORE:-${W114_CAPTURE_STORE:-<none>}}" "$CRYSTAL_CACHE_DIR" "$KEEP_TMP"

# The caller owns the single serial run_safe guard; do not nest another guard.
"$CRYSTAL_BIN" run --single-module --link-flags='-fuse-ld=ld' \
  "$ROOT/scripts/probe_geometry_w114.cr" -- "$MODE"
