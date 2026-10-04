#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"

if [[ "${W158_EXECUTE_AS_ROOT:-}" != YES ]]; then
  printf 'Refusing W158 paired oracle without root-owned W158_EXECUTE_AS_ROOT=YES\n' >&2
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

if [[ -n "${W158_PAIR_ROOT:-}" ]]; then
  TMP_ROOT="$W158_PAIR_ROOT"
  if [[ ! "$TMP_ROOT" =~ ^/private/tmp/crystal-click-object-dynamic-w158\.[A-Za-z0-9_-]+$ ]]; then
    printf 'W158_PAIR_ROOT must be a direct /private/tmp child with a safe fresh leaf\n' >&2
    exit 1
  fi
  if [[ -e "$TMP_ROOT" || -L "$TMP_ROOT" ]]; then
    printf 'Refusing to overwrite existing W158 evidence root: %s\n' "$TMP_ROOT" >&2
    exit 1
  fi
  mkdir -m 700 "$TMP_ROOT"
else
  TMP_ROOT="$(mktemp -d /private/tmp/crystal-click-object-dynamic-w158.XXXXXX)"
fi

TMP_ROOT="$(CDPATH= cd -- "$TMP_ROOT" && pwd -P)"
if [[ -L "$TMP_ROOT" || ! "$TMP_ROOT" =~ ^/private/tmp/crystal-click-object-dynamic-w158\.[A-Za-z0-9_-]+$ ]]; then
  printf 'Refusing unexpected W158 output root: %s\n' "$TMP_ROOT" >&2
  exit 1
fi
mkdir -m 700 "$TMP_ROOT/crystal-cache"
cd "$ROOT"
export W158_EXECUTE_AS_ROOT=YES W158_PAIR_ROOT="$TMP_ROOT" CLICKHOUSE_BIN
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache" TZ=UTC
printf 'W158 declared Object Dynamic oracle root=%s (retained) TZ=%s\n' "$TMP_ROOT" "$TZ"

"$CRYSTAL_BIN" run --single-module --threads 1 --error-trace --link-flags=-fuse-ld=ld \
  "$ROOT/scripts/check_object_dynamic_w158.cr" 2>&1 | tee "$TMP_ROOT/check.log"
"$RUBY_BIN" "$ROOT/scripts/recheck_object_dynamic_w158.rb" 2>&1 | tee "$TMP_ROOT/recheck.log"
