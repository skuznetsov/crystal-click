#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"

if [[ "${W146_EXECUTE_AS_ROOT:-}" != YES ]]; then
  printf 'Refusing W146 paired oracle without root-owned W146_EXECUTE_AS_ROOT=YES\n' >&2
  exit 1
fi

CRYSTAL_BIN="${CRYSTAL_BIN:-$(command -v crystal || true)}"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/private/tmp/crystal-click-w144-runtime-recovery.Pm8VNb/clickhouse-stripped}"
if [[ -z "$CRYSTAL_BIN" || ! -x "$CRYSTAL_BIN" ]]; then
  printf 'Set CRYSTAL_BIN to the Crystal executable\n' >&2
  exit 1
fi
if [[ ! -f "$CLICKHOUSE_BIN" || ! -x "$CLICKHOUSE_BIN" || -L "$CLICKHOUSE_BIN" ]]; then
  printf 'Pinned ClickHouse executable is unavailable or unsafe: %s\n' "$CLICKHOUSE_BIN" >&2
  exit 1
fi

if [[ -n "${W146_PAIR_ROOT:-}" ]]; then
  RAW_ROOT="$W146_PAIR_ROOT"
  if [[ ! "$RAW_ROOT" =~ ^/private/tmp/crystal-click-object-low-cardinality-w146-paired\.[A-Za-z0-9_-]+$ ]]; then
    printf 'W146_PAIR_ROOT must be a direct /private/tmp child with a safe fresh leaf\n' >&2
    exit 1
  fi
  if [[ -e "$RAW_ROOT" || -L "$RAW_ROOT" ]]; then
    printf 'Refusing to overwrite existing W146 evidence root: %s\n' "$RAW_ROOT" >&2
    exit 1
  fi
  mkdir -m 700 "$RAW_ROOT"
  TMP_ROOT="$RAW_ROOT"
else
  TMP_ROOT="$(mktemp -d /private/tmp/crystal-click-object-low-cardinality-w146-paired.XXXXXX)"
fi

TMP_ROOT="$(CDPATH= cd -- "$TMP_ROOT" && pwd -P)"
if [[ -L "$TMP_ROOT" || ! "$TMP_ROOT" =~ ^/private/tmp/crystal-click-object-low-cardinality-w146-paired\.[A-Za-z0-9_-]+$ ]]; then
  printf 'Refusing unexpected W146 paired output root: %s\n' "$TMP_ROOT" >&2
  exit 1
fi
if [[ -n "${RAW_ROOT:-}" && "$TMP_ROOT" != "$RAW_ROOT" ]]; then
  printf 'W146 output root changed during canonicalization\n' >&2
  exit 1
fi

mkdir -m 700 "$TMP_ROOT/crystal-cache"
cd "$ROOT"
export W146_PAIR_ROOT="$TMP_ROOT" CLICKHOUSE_BIN
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache"
export TZ=UTC
printf 'W146 paired Object LowCardinality oracle root=%s (retained) TZ=%s\n' "$TMP_ROOT" "$TZ"
# The parent owns the serial ClickHouse resource guard; do not nest it here.
"$CRYSTAL_BIN" run --single-module --threads 1 --error-trace --link-flags=-fuse-ld=ld \
  "$ROOT/scripts/check_object_low_cardinality_w146.cr" 2>&1 | tee "$TMP_ROOT/check.log"
