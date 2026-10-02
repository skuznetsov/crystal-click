#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
CRYSTAL_BIN="${CRYSTAL_BIN:-$(command -v crystal || true)}"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/private/tmp/crystal-click-w112-runtime.u0Jn1f/clickhouse}"
KEEP_TMP="${W118_KEEP_TMP:-0}"
SUPPLIED_ROOT="${W118_TEST_ROOT:-}"
OWN_ROOT=0

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
if [[ ! -d "$W115_CAPTURE_ROOT/store" || -L "$W115_CAPTURE_ROOT/store" || ! -f "$W115_CAPTURE_ROOT/capture.log" || -L "$W115_CAPTURE_ROOT/capture.log" ]]; then
  printf 'W115 capture root has no safe retained store/capture log\n' >&2
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
  printf 'W118_KEEP_TMP must be 0 or 1\n' >&2
  exit 2
fi

if [[ -n "$SUPPLIED_ROOT" ]]; then
  if [[ ! -d "$SUPPLIED_ROOT" || -L "$SUPPLIED_ROOT" ]]; then
    printf 'W118_TEST_ROOT must be an existing non-symlink directory\n' >&2
    exit 2
  fi
  TEST_ROOT="$(cd -- "$SUPPLIED_ROOT" && pwd -P)"
  case "$TEST_ROOT" in
    /private/tmp/*) ;;
    *) printf 'Refusing W118 test root outside /private/tmp\n' >&2; exit 2 ;;
  esac
  if [[ -n "$(find "$TEST_ROOT" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    printf 'W118_TEST_ROOT must be fresh and empty\n' >&2
    exit 2
  fi
else
  TEST_ROOT="$(mktemp -d /private/tmp/crystal-click-object-shared-map-w118.XXXXXX)"
  TEST_ROOT="$(cd -- "$TEST_ROOT" && pwd -P)"
  case "$TEST_ROOT" in
    /private/tmp/crystal-click-object-shared-map-w118.*) ;;
    *) printf 'Refusing unexpected W118 temporary root\n' >&2; exit 1 ;;
  esac
  OWN_ROOT=1
fi
if [[ ! -d "$TEST_ROOT" || -L "$TEST_ROOT" ]]; then
  printf 'Refusing invalid W118 test root\n' >&2
  exit 1
fi

cleanup() {
  local status=$?
  if [[ "$OWN_ROOT" == 0 ]]; then
    printf 'W118 caller-owned test root retained: %s\n' "$TEST_ROOT"
  elif [[ "$KEEP_TMP" == 1 || "$status" -ne 0 ]]; then
    printf 'W118 retained temporary root: %s\n' "$TEST_ROOT"
  elif [[ "$TEST_ROOT" == /private/tmp/crystal-click-object-shared-map-w118.* && -d "$TEST_ROOT" && ! -L "$TEST_ROOT" ]]; then
    rm -rf -- "$TEST_ROOT"
  fi
}
trap cleanup EXIT

STORE="$TEST_ROOT/clickhouse-store"
CRYSTAL_CACHE="$TEST_ROOT/crystal-cache"
mkdir "$STORE"
mkdir "$CRYSTAL_CACHE"

cd "$ROOT"
export W115_CAPTURE_ROOT W118_TEST_ROOT="$TEST_ROOT" W118_STORE="$STORE" CLICKHOUSE_BIN
export CRYSTAL_CACHE_DIR="$CRYSTAL_CACHE"
printf 'W118 Object MAP tri-lane check root=%s capture=%s runtime=%s grammar-source=0c68f01a keep=%s\n' \
  "$TEST_ROOT" "$W115_CAPTURE_ROOT" "$CLICKHOUSE_BIN" "$KEEP_TMP"
# Caller owns any serial resource guard; this wrapper does not nest one.
"$CRYSTAL_BIN" run --single-module --link-flags='-fuse-ld=ld' \
  "$ROOT/scripts/check_object_shared_map_w118.cr" 2>&1 | tee "$TEST_ROOT/check.log"
