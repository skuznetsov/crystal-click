#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/private/tmp/crystal-click-w112-runtime.u0Jn1f/clickhouse}"
CRYSTAL_BIN="${CRYSTAL_BIN:-$(command -v crystal || true)}"
KEEP_TMP="${W115_KEEP_TMP:-0}"

if [[ ! -x "$CLICKHOUSE_BIN" ]]; then
  printf 'Pinned ClickHouse executable is unavailable: %s\n' "$CLICKHOUSE_BIN" >&2
  exit 1
fi
if [[ -z "$CRYSTAL_BIN" || ! -x "$CRYSTAL_BIN" ]]; then
  printf 'Set CRYSTAL_BIN to the Crystal executable\n' >&2
  exit 1
fi
if [[ "$KEEP_TMP" != 0 && "$KEEP_TMP" != 1 ]]; then
  printf 'W115_KEEP_TMP must be 0 or 1\n' >&2
  exit 2
fi

TMP_ROOT="$(mktemp -d /private/tmp/crystal-click-json-w115.XXXXXX)"
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)"
case "$TMP_ROOT" in
  /private/tmp/crystal-click-json-w115.*) ;;
  *) printf 'Refusing unexpected W115 temporary root: %s\n' "$TMP_ROOT" >&2; exit 1 ;;
esac
if [[ ! -d "$TMP_ROOT" || -L "$TMP_ROOT" ]]; then
  printf 'Refusing invalid W115 temporary root: %s\n' "$TMP_ROOT" >&2
  exit 1
fi

cleanup() {
  capture_status=$?
  if [[ "$KEEP_TMP" == 1 || "$capture_status" != 0 ]]; then
    printf 'W115 retained temporary root: %s\n' "$TMP_ROOT" >&2
  elif [[ "$TMP_ROOT" == /private/tmp/crystal-click-json-w115.* && -d "$TMP_ROOT" && ! -L "$TMP_ROOT" ]]; then
    rm -rf -- "$TMP_ROOT"
  fi
  return "$capture_status"
}
trap cleanup EXIT

cd "$ROOT"
export CLICKHOUSE_BIN W115_CAPTURE_ROOT="$TMP_ROOT" W115_CAPTURE_STORE="$TMP_ROOT/store"
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache"
mkdir -p "$CRYSTAL_CACHE_DIR"
printf 'W115 CAPTURE-ONLY root=%s store=%s keep=%s\n' "$TMP_ROOT" "$W115_CAPTURE_STORE" "$KEEP_TMP"
# The caller owns the serial resource guard; do not nest another guard here.
"$CRYSTAL_BIN" run --single-module --link-flags='-fuse-ld=ld' --error-trace \
  "$ROOT/scripts/capture_json_w115.cr" 2>&1 | tee "$TMP_ROOT/capture.log"
