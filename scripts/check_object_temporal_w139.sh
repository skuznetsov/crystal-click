#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
CRYSTAL_BIN="${CRYSTAL_BIN:-$(command -v crystal || true)}"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/private/tmp/crystal-click-w112-runtime.u0Jn1f/clickhouse}"
KEEP_TMP="${W139_KEEP_TMP:-0}"

if [[ -z "$CRYSTAL_BIN" || ! -x "$CRYSTAL_BIN" ]]; then
  printf 'Set CRYSTAL_BIN to the Crystal executable\n' >&2
  exit 1
fi
if [[ ! -x "$CLICKHOUSE_BIN" ]]; then
  printf 'Pinned ClickHouse executable is unavailable: %s\n' "$CLICKHOUSE_BIN" >&2
  exit 1
fi
if [[ "$KEEP_TMP" != 0 && "$KEEP_TMP" != 1 ]]; then
  printf 'W139_KEEP_TMP must be 0 or 1\n' >&2
  exit 2
fi

TMP_ROOT="$(mktemp -d /private/tmp/crystal-click-object-temporal-w139.XXXXXX)"
TMP_ROOT="$(CDPATH= cd -- "$TMP_ROOT" && pwd -P)"
TMP_ROOT_PARENT="${TMP_ROOT%/*}"
TMP_ROOT_LEAF="${TMP_ROOT##*/}"
if [[ "$TMP_ROOT_PARENT" != /private/tmp || ! "$TMP_ROOT_LEAF" =~ ^crystal-click-object-temporal-w139\.[[:alnum:]]+$ ]]; then
  printf 'Refusing unexpected W139 temporary root: %s\n' "$TMP_ROOT" >&2
  exit 1
fi
if [[ ! -d "$TMP_ROOT" || -L "$TMP_ROOT" ]]; then
  printf 'Refusing invalid W139 temporary root: %s\n' "$TMP_ROOT" >&2
  exit 1
fi

cleanup() {
  local status=$?
  local current=''
  trap - EXIT
  if [[ "$KEEP_TMP" == 1 || "$status" -ne 0 ]]; then
    printf 'W139 retained temporary root: %s\n' "$TMP_ROOT" >&2
  elif [[ -d "$TMP_ROOT" && ! -L "$TMP_ROOT" ]]; then
    current="$(CDPATH= cd -- "$TMP_ROOT" && pwd -P)"
    if [[ "$current" == "$TMP_ROOT" && "${TMP_ROOT%/*}" == /private/tmp && "${TMP_ROOT##*/}" =~ ^crystal-click-object-temporal-w139\.[[:alnum:]]+$ ]]; then
      rm -rf -- "$TMP_ROOT"
    else
      printf 'Refusing to clean changed W139 temporary root: %s\n' "$TMP_ROOT" >&2
    fi
  else
    printf 'Refusing to clean missing or symlinked W139 temporary root: %s\n' "$TMP_ROOT" >&2
  fi
  return "$status"
}
trap cleanup EXIT

mkdir -p "$TMP_ROOT/crystal-cache"
cd "$ROOT"
export W139_TMP_ROOT="$TMP_ROOT" CLICKHOUSE_BIN
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache"
export TZ=UTC
printf 'W139 declared temporal Object interoperability oracle root=%s keep=%s TZ=%s\n' "$TMP_ROOT" "$KEEP_TMP" "$TZ"
# The parent owns the serial resource guard; this wrapper does not nest one.
"$CRYSTAL_BIN" run --single-module --threads 1 --link-flags='-fuse-ld=ld' --error-trace \
  "$ROOT/scripts/check_object_temporal_w139.cr" 2>&1 | tee "$TMP_ROOT/check.log"
