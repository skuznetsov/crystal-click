#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
CRYSTAL_BIN="${CRYSTAL_BIN:-$(command -v crystal || true)}"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/private/tmp/crystal-click-w112-runtime.u0Jn1f/clickhouse}"
KEEP_TMP="${W120_KEEP_TMP:-0}"

if [[ -z "${W115_CAPTURE_ROOT:-}" ]]; then
  printf 'Set W115_CAPTURE_ROOT to the retained successful W115 capture root\n' >&2
  exit 2
fi
if [[ ! -d "$W115_CAPTURE_ROOT" || -L "$W115_CAPTURE_ROOT" ]]; then
  printf 'W115_CAPTURE_ROOT must be an existing non-symlink directory\n' >&2
  exit 2
fi
W115_CAPTURE_ROOT="$(cd -- "$W115_CAPTURE_ROOT" && pwd -P)"
case "$W115_CAPTURE_ROOT" in
  /private/tmp/crystal-click-json-w115.*) ;;
  *) printf 'Refusing non-W115 capture root: %s\n' "$W115_CAPTURE_ROOT" >&2; exit 2 ;;
esac
if [[ ! -d "$W115_CAPTURE_ROOT/store" || -L "$W115_CAPTURE_ROOT/store" ]]; then
  printf 'W115 capture root has no safe retained store\n' >&2
  exit 2
fi
if [[ ! -x "$CLICKHOUSE_BIN" ]]; then
  printf 'Pinned ClickHouse executable is unavailable: %s\n' "$CLICKHOUSE_BIN" >&2
  exit 1
fi
if [[ -z "$CRYSTAL_BIN" || ! -x "$CRYSTAL_BIN" ]]; then
  printf 'Set CRYSTAL_BIN to the Crystal executable\n' >&2
  exit 1
fi
if [[ "$KEEP_TMP" != 0 && "$KEEP_TMP" != 1 ]]; then
  printf 'W120_KEEP_TMP must be 0 or 1\n' >&2
  exit 2
fi

TMP_ROOT="$(mktemp -d /private/tmp/crystal-click-json-w120.XXXXXX)"
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)"
case "$TMP_ROOT" in
  /private/tmp/crystal-click-json-w120.*) ;;
  *) printf 'Refusing unexpected W120 temporary root: %s\n' "$TMP_ROOT" >&2; exit 1 ;;
esac
if [[ ! -d "$TMP_ROOT" || -L "$TMP_ROOT" ]]; then
  printf 'Refusing invalid W120 temporary root: %s\n' "$TMP_ROOT" >&2
  exit 1
fi

CACHE_ROOT=""

cleanup() {
  local status=$?
  if [[ "$KEEP_TMP" == 1 || "$status" -ne 0 ]]; then
    printf 'W120 retained temporary root: %s\n' "$TMP_ROOT" >&2
    if [[ -n "$CACHE_ROOT" ]]; then
      printf 'W120 retained Crystal cache root: %s\n' "$CACHE_ROOT" >&2
    fi
  else
    if [[ "$TMP_ROOT" == /private/tmp/crystal-click-json-w120.* && -d "$TMP_ROOT" && ! -L "$TMP_ROOT" ]]; then
      rm -rf -- "$TMP_ROOT"
    fi
    if [[ "$CACHE_ROOT" == /private/tmp/crystal-click-json-w120-cache.* && -d "$CACHE_ROOT" && ! -L "$CACHE_ROOT" ]]; then
      rm -rf -- "$CACHE_ROOT"
    fi
  fi
}
trap cleanup EXIT

CACHE_ROOT="$(mktemp -d /private/tmp/crystal-click-json-w120-cache.XXXXXX)"
CACHE_ROOT="$(cd -- "$CACHE_ROOT" && pwd -P)"
case "$CACHE_ROOT" in
  /private/tmp/crystal-click-json-w120-cache.*) ;;
  *) printf 'Refusing unexpected W120 Crystal cache root: %s\n' "$CACHE_ROOT" >&2; exit 1 ;;
esac
if [[ ! -d "$CACHE_ROOT" || -L "$CACHE_ROOT" ]]; then
  printf 'Refusing invalid W120 Crystal cache root: %s\n' "$CACHE_ROOT" >&2
  exit 1
fi

cd "$ROOT"
export W115_CAPTURE_ROOT W120_TMP_ROOT="$TMP_ROOT" CLICKHOUSE_BIN
export CRYSTAL_CACHE_DIR="$CACHE_ROOT"
printf 'W120 structure check root=%s source_capture=%s keep=%s\n' "$TMP_ROOT" "$W115_CAPTURE_ROOT" "$KEEP_TMP"
# The caller owns the serial resource guard; this wrapper does not nest one.
"$CRYSTAL_BIN" run --single-module --link-flags='-fuse-ld=ld' --error-trace \
  "$ROOT/scripts/check_object_dynamic_structure_w120.cr" 2>&1 | tee "$CACHE_ROOT/check.log"
