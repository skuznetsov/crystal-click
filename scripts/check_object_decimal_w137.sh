#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
CRYSTAL_BIN="${CRYSTAL_BIN:-$(command -v crystal || true)}"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/private/tmp/crystal-click-w112-runtime.u0Jn1f/clickhouse}"
KEEP_TMP="${W137_KEEP_TMP:-0}"

if [[ -z "$CRYSTAL_BIN" || ! -x "$CRYSTAL_BIN" ]]; then
  printf 'Set CRYSTAL_BIN to the Crystal executable\n' >&2
  exit 1
fi
if [[ ! -x "$CLICKHOUSE_BIN" ]]; then
  printf 'Pinned ClickHouse executable is unavailable: %s\n' "$CLICKHOUSE_BIN" >&2
  exit 1
fi
if [[ "$KEEP_TMP" != 0 && "$KEEP_TMP" != 1 ]]; then
  printf 'W137_KEEP_TMP must be 0 or 1\n' >&2
  exit 2
fi

TMP_ROOT="$(mktemp -d /private/tmp/crystal-click-object-decimal-w137.XXXXXX)"
TMP_ROOT="$(CDPATH= cd -- "$TMP_ROOT" && pwd -P)"
TMP_ROOT_PARENT="${TMP_ROOT%/*}"
TMP_ROOT_LEAF="${TMP_ROOT##*/}"
if [[ "$TMP_ROOT_PARENT" != /private/tmp || ! "$TMP_ROOT_LEAF" =~ ^crystal-click-object-decimal-w137\.[[:alnum:]]+$ ]]; then
  printf 'Refusing unexpected W137 temporary root: %s\n' "$TMP_ROOT" >&2
  exit 1
fi
if [[ ! -d "$TMP_ROOT" || -L "$TMP_ROOT" ]]; then
  printf 'Refusing invalid W137 temporary root: %s\n' "$TMP_ROOT" >&2
  exit 1
fi

cleanup() {
  local status=$?
  local current=''
  trap - EXIT
  if [[ "$KEEP_TMP" == 1 || "$status" -ne 0 ]]; then
    printf 'W137 retained temporary root: %s\n' "$TMP_ROOT" >&2
  elif [[ -d "$TMP_ROOT" && ! -L "$TMP_ROOT" ]]; then
    current="$(CDPATH= cd -- "$TMP_ROOT" && pwd -P)"
    if [[ "$current" == "$TMP_ROOT" && "${TMP_ROOT%/*}" == /private/tmp && "${TMP_ROOT##*/}" =~ ^crystal-click-object-decimal-w137\.[[:alnum:]]+$ ]]; then
      rm -rf -- "$TMP_ROOT"
    else
      printf 'Refusing to clean changed W137 temporary root: %s\n' "$TMP_ROOT" >&2
    fi
  else
    printf 'Refusing to clean missing or symlinked W137 temporary root: %s\n' "$TMP_ROOT" >&2
  fi
  return "$status"
}
trap cleanup EXIT

mkdir -p "$TMP_ROOT/crystal-cache"
cd "$ROOT"
export W137_TMP_ROOT="$TMP_ROOT" CLICKHOUSE_BIN
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache"
printf 'W137 fresh declared Decimal Object bidirectional oracle root=%s keep=%s\n' "$TMP_ROOT" "$KEEP_TMP"
# The parent owns the serial resource guard; this wrapper does not nest one.
"$CRYSTAL_BIN" run --single-module --threads 1 --link-flags='-fuse-ld=ld' --error-trace \
  "$ROOT/scripts/check_object_decimal_w137.cr" 2>&1 | tee "$TMP_ROOT/check.log"
