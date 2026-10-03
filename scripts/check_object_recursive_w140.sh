#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
CRYSTAL_BIN="${CRYSTAL_BIN:-$(command -v crystal || true)}"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/private/tmp/crystal-click-w112-runtime.u0Jn1f/clickhouse}"

if [[ -z "$CRYSTAL_BIN" || ! -x "$CRYSTAL_BIN" ]]; then
  printf 'Set CRYSTAL_BIN to the Crystal executable\n' >&2
  exit 1
fi
if [[ ! -x "$CLICKHOUSE_BIN" ]]; then
  printf 'Pinned ClickHouse executable is unavailable: %s\n' "$CLICKHOUSE_BIN" >&2
  exit 1
fi

if [[ -n "${W140_TMP_ROOT:-}" ]]; then
  [[ "$W140_TMP_ROOT" == /* && -d "$W140_TMP_ROOT" && ! -L "$W140_TMP_ROOT" ]] || {
    printf 'W140_TMP_ROOT must be an existing absolute non-symlink directory\n' >&2
    exit 1
  }
  TMP_ROOT="$(CDPATH= cd -- "$W140_TMP_ROOT" && pwd -P)"
elif [[ -n "${W140_PROBE_ROOT:-}" ]]; then
  [[ "$W140_PROBE_ROOT" == /* && -d "$W140_PROBE_ROOT" && ! -L "$W140_PROBE_ROOT" ]] || {
    printf 'W140_PROBE_ROOT must be an existing absolute non-symlink directory\n' >&2
    exit 1
  }
  PROBE_ROOT="$(CDPATH= cd -- "$W140_PROBE_ROOT" && pwd -P)"
  TMP_ROOT="$PROBE_ROOT/paired"
  if [[ -e "$TMP_ROOT" || -L "$TMP_ROOT" ]]; then
    printf 'Refusing to overwrite existing paired evidence root: %s\n' "$TMP_ROOT" >&2
    exit 1
  fi
  mkdir "$TMP_ROOT"
else
  TMP_ROOT="$(mktemp -d /private/tmp/crystal-click-object-recursive-w140.XXXXXX)"
fi

TMP_ROOT="$(CDPATH= cd -- "$TMP_ROOT" && pwd -P)"
TMP_PARENT="${TMP_ROOT%/*}"
TMP_LEAF="${TMP_ROOT##*/}"
if [[ ! -d "$TMP_ROOT" || -L "$TMP_ROOT" || \
      ( "$TMP_PARENT" != /private/tmp && \
        ! ( "$TMP_LEAF" == paired && "${TMP_PARENT%/*}" == /private/tmp && \
            "${TMP_PARENT##*/}" == crystal-click-object-recursive-w140.* ) ) || \
      ( "$TMP_PARENT" == /private/tmp && "$TMP_LEAF" != crystal-click-object-recursive-w140.* ) ]]; then
  printf 'Refusing unexpected W140 paired temporary root: %s\n' "$TMP_ROOT" >&2
  exit 1
fi
if [[ -e "$TMP_ROOT/stores" || -e "$TMP_ROOT/results" || -e "$TMP_ROOT/manifest.json" ]]; then
  printf 'Refusing to overwrite existing W140 evidence under %s\n' "$TMP_ROOT" >&2
  exit 1
fi

mkdir "$TMP_ROOT/crystal-cache"
cd "$ROOT"
export W140_TMP_ROOT="$TMP_ROOT" CLICKHOUSE_BIN
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache"
export TZ=UTC
printf 'W140 paired recursive Object interoperability oracle root=%s (retained) TZ=%s\n' "$TMP_ROOT" "$TZ"
# The parent owns the serial resource guard; this wrapper does not nest one.
"$CRYSTAL_BIN" run --single-module --threads 1 --link-flags='-fuse-ld=ld' --error-trace \
  "$ROOT/scripts/check_object_recursive_w140.cr" 2>&1 | tee "$TMP_ROOT/check.log"
