#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"

if [[ "${W164_EXECUTE_AS_ROOT:-}" != YES ]]; then
  printf 'Refusing W164 paired oracle without root-owned W164_EXECUTE_AS_ROOT=YES\n' >&2
  exit 1
fi

CRYSTAL_BIN="${CRYSTAL_BIN:-$(command -v crystal || true)}"
RUBY_BIN="${RUBY_BIN:-$(command -v ruby || true)}"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/private/tmp/crystal-click-w144-runtime-recovery.Pm8VNb/clickhouse-stripped}"
if [[ -z "$CRYSTAL_BIN" || ! -x "$CRYSTAL_BIN" ]]; then
  printf 'Set CRYSTAL_BIN to the Crystal executable\n' >&2
  exit 1
fi
if [[ -z "$RUBY_BIN" || ! -x "$RUBY_BIN" ]]; then
  printf 'Set RUBY_BIN to the Ruby executable\n' >&2
  exit 1
fi
if [[ ! -f "$CLICKHOUSE_BIN" || ! -x "$CLICKHOUSE_BIN" || -L "$CLICKHOUSE_BIN" ]]; then
  printf 'Pinned ClickHouse executable is unavailable or unsafe: %s\n' "$CLICKHOUSE_BIN" >&2
  exit 1
fi

if [[ -n "${W164_PAIR_ROOT:-}" ]]; then
  TMP_ROOT="$W164_PAIR_ROOT"
  if [[ ! "$TMP_ROOT" =~ ^/private/tmp/crystal-click-w164\.[A-Za-z0-9_-]+$ ]]; then
    printf 'W164_PAIR_ROOT must be a direct /private/tmp child with a safe fresh leaf\n' >&2
    exit 1
  fi
  if [[ -e "$TMP_ROOT" || -L "$TMP_ROOT" ]]; then
    printf 'Refusing to overwrite existing W164 evidence root: %s\n' "$TMP_ROOT" >&2
    exit 1
  fi
  mkdir -m 700 "$TMP_ROOT"
else
  TMP_ROOT="$(mktemp -d /private/tmp/crystal-click-w164.XXXXXX)"
fi

TMP_ROOT="$(CDPATH= cd -- "$TMP_ROOT" && pwd -P)"
if [[ -L "$TMP_ROOT" || ! "$TMP_ROOT" =~ ^/private/tmp/crystal-click-w164\.[A-Za-z0-9_-]+$ ]]; then
  printf 'Refusing unexpected W164 output root: %s\n' "$TMP_ROOT" >&2
  exit 1
fi
mkdir -m 700 "$TMP_ROOT/crystal-cache"
cd "$ROOT"
export W164_EXECUTE_AS_ROOT=YES W164_PAIR_ROOT="$TMP_ROOT" CLICKHOUSE_BIN CRYSTAL_BIN RUBY_BIN
export W164_PART_ROOT="$TMP_ROOT/library-parts"
export W164_SIMPLE_AGGREGATE_STOCK_WIDE_PART="$TMP_ROOT/native-stock-part/all_1_1_0"
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache" TZ=UTC
printf 'W164 SimpleAggregateFunction stock/library oracle root=%s (retained) TZ=%s\n' "$TMP_ROOT" "$TZ"
# The caller owns the serial resource guard. This wrapper intentionally does not nest one.
"$RUBY_BIN" "$ROOT/scripts/recheck_simple_aggregate_w164.rb" 2>&1 | tee "$TMP_ROOT/recheck.log"
