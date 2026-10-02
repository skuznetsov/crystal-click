#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
CRYSTAL_BIN="${CRYSTAL_BIN:-$(command -v crystal || true)}"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/private/tmp/crystal-click-w112-runtime.u0Jn1f/clickhouse}"
W125_OUTPUT_ROOT="${W125_OUTPUT_ROOT:-/private/tmp/crystal-click-json-w125.msh17X}"

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
if [[ ! -d "$W125_OUTPUT_ROOT" || -L "$W125_OUTPUT_ROOT" ]]; then
  printf 'W125_OUTPUT_ROOT must be an existing non-symlink retained W125 directory\n' >&2
  exit 2
fi
W125_OUTPUT_ROOT="$(cd -- "$W125_OUTPUT_ROOT" && pwd -P)"
case "$W125_OUTPUT_ROOT" in
  /private/tmp/crystal-click-json-w125.*) ;;
  *) printf 'Refusing non-W125 output root: %s\n' "$W125_OUTPUT_ROOT" >&2; exit 2 ;;
esac
if [[ ! -d "$W125_OUTPUT_ROOT/stores/dynamic_paths_basic" || -L "$W125_OUTPUT_ROOT/stores/dynamic_paths_basic" ]]; then
  printf 'W125 output root has no safe retained stock stores\n' >&2
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

CACHE_ROOT="$(mktemp -d /private/tmp/crystal-click-json-w126-cache.XXXXXX)"
CACHE_ROOT="$(cd -- "$CACHE_ROOT" && pwd -P)"
case "$CACHE_ROOT" in
  /private/tmp/crystal-click-json-w126-cache.*) ;;
  *) printf 'Refusing unexpected W126 Crystal cache root: %s\n' "$CACHE_ROOT" >&2; exit 1 ;;
esac
if [[ ! -d "$CACHE_ROOT" || -L "$CACHE_ROOT" ]]; then
  printf 'Refusing invalid W126 Crystal cache root: %s\n' "$CACHE_ROOT" >&2
  exit 1
fi

cleanup() {
  local status=$?
  if [[ "$status" -eq 0 && "$CACHE_ROOT" == /private/tmp/crystal-click-json-w126-cache.* && -d "$CACHE_ROOT" && ! -L "$CACHE_ROOT" ]]; then
    rm -rf -- "$CACHE_ROOT"
  else
    printf 'W126 retained Crystal cache root: %s\n' "$CACHE_ROOT" >&2
  fi
}
trap cleanup EXIT

cd "$ROOT"
export CLICKHOUSE_BIN
export W126_W115_CAPTURE_ROOT="$W115_CAPTURE_ROOT"
export W126_W125_OUTPUT_ROOT="$W125_OUTPUT_ROOT"
export CRYSTAL_CACHE_DIR="$CACHE_ROOT"
printf 'W126 Object file reader check retained_w125=%s w115_capture=%s\n' "$W125_OUTPUT_ROOT" "$W115_CAPTURE_ROOT"
# The caller owns the serial resource guard; this wrapper does not nest one.
"$CRYSTAL_BIN" run --single-module --link-flags='-fuse-ld=ld' --error-trace \
  "$ROOT/scripts/check_object_file_reader_w126.cr" 2>&1 | tee "$CACHE_ROOT/check.log"
