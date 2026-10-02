#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
CRYSTAL_BIN="${CRYSTAL_BIN:-$(command -v crystal || true)}"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/private/tmp/crystal-click-w112-runtime.u0Jn1f/clickhouse}"
KEEP_TMP="${W128_KEEP_TMP:-0}"

if [[ ! -x "$CLICKHOUSE_BIN" ]]; then
  printf 'Pinned ClickHouse executable is unavailable: %s\n' "$CLICKHOUSE_BIN" >&2
  exit 1
fi
if [[ -z "$CRYSTAL_BIN" || ! -x "$CRYSTAL_BIN" ]]; then
  printf 'Set CRYSTAL_BIN to the Crystal executable\n' >&2
  exit 1
fi
if [[ "$KEEP_TMP" != 0 && "$KEEP_TMP" != 1 ]]; then
  printf 'W128_KEEP_TMP must be 0 or 1\n' >&2
  exit 2
fi

TMP_ROOT="$(mktemp -d /private/tmp/crystal-click-json-w128.XXXXXX)"
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)"
case "$TMP_ROOT" in
  /private/tmp/crystal-click-json-w128.*) ;;
  *) printf 'Refusing unexpected W128 temporary root: %s\n' "$TMP_ROOT" >&2; exit 1 ;;
esac
if [[ ! -d "$TMP_ROOT" || -L "$TMP_ROOT" ]]; then
  printf 'Refusing invalid W128 temporary root: %s\n' "$TMP_ROOT" >&2
  exit 1
fi

cleanup() {
  local status=$?
  if [[ "$KEEP_TMP" == 1 || "$status" -ne 0 ]]; then
    printf 'W128 retained temporary root: %s\n' "$TMP_ROOT" >&2
  elif [[ "$TMP_ROOT" == /private/tmp/crystal-click-json-w128.* && -d "$TMP_ROOT" && ! -L "$TMP_ROOT" ]]; then
    rm -rf -- "$TMP_ROOT"
  fi
}
trap cleanup EXIT

mkdir -p "$TMP_ROOT/crystal-cache"
cd "$ROOT"
export W128_TMP_ROOT="$TMP_ROOT" CLICKHOUSE_BIN
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache"
printf 'W128 fresh library-owned whole Object part check root=%s keep=%s\n' "$TMP_ROOT" "$KEEP_TMP"
# The parent owns the serial resource guard; this wrapper does not nest one.
"$CRYSTAL_BIN" run --single-module --threads 1 --link-flags='-fuse-ld=ld' --error-trace \
  "$ROOT/scripts/check_object_part_writer_w128.cr" 2>&1 | tee "$TMP_ROOT/check.log"
