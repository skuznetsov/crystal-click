#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
CRYSTAL_BIN="${CRYSTAL_BIN:-$(command -v crystal || true)}"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/private/tmp/crystal-click-w112-runtime.u0Jn1f/clickhouse}"
KEEP_TMP="${W117_KEEP_TMP:-0}"
SUPPLIED_ROOT="${W117_TEST_ROOT:-}"
OWN_ROOT=0

if [[ -z "$CRYSTAL_BIN" || ! -x "$CRYSTAL_BIN" ]]; then
  printf 'Set CRYSTAL_BIN to the Crystal executable\n' >&2
  exit 1
fi
if [[ ! -x "$CLICKHOUSE_BIN" ]]; then
  printf 'Pinned ClickHouse executable is unavailable: %s\n' "$CLICKHOUSE_BIN" >&2
  exit 1
fi
if [[ "$KEEP_TMP" != 0 && "$KEEP_TMP" != 1 ]]; then
  printf 'W117_KEEP_TMP must be 0 or 1\n' >&2
  exit 2
fi

EXPECTED_VERSION='ClickHouse local version 26.10.1.1201 (official build).'
EXPECTED_CARRIER_SHA256='23b2e0292f622565b8312795c190b8af89cb0eae559b6e51ac856a7259bdbf44'
EXPECTED_EXECUTABLE_SHA256='bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2'
INPUT_SHA256="$(shasum -a 256 "$CLICKHOUSE_BIN" | cut -d ' ' -f 1)"
if [[ "$INPUT_SHA256" != "$EXPECTED_CARRIER_SHA256" && "$INPUT_SHA256" != "$EXPECTED_EXECUTABLE_SHA256" ]]; then
  printf 'W117 ClickHouse SHA-256 mismatch: expected pinned carrier %s or executable %s, got %s\n' \
    "$EXPECTED_CARRIER_SHA256" "$EXPECTED_EXECUTABLE_SHA256" "$INPUT_SHA256" >&2
  exit 1
fi
ACTUAL_VERSION="$("$CLICKHOUSE_BIN" local --version)"
if [[ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]]; then
  printf 'W117 requires %s, got %s\n' "$EXPECTED_VERSION" "$ACTUAL_VERSION" >&2
  exit 1
fi
EXECUTED_SHA256="$(shasum -a 256 "$CLICKHOUSE_BIN" | cut -d ' ' -f 1)"
if [[ "$EXECUTED_SHA256" != "$EXPECTED_EXECUTABLE_SHA256" ]]; then
  printf 'W117 expanded executable SHA-256 mismatch: expected %s, got %s\n' \
    "$EXPECTED_EXECUTABLE_SHA256" "$EXECUTED_SHA256" >&2
  exit 1
fi

if [[ -n "$SUPPLIED_ROOT" ]]; then
  if [[ ! -d "$SUPPLIED_ROOT" || -L "$SUPPLIED_ROOT" ]]; then
    printf 'W117_TEST_ROOT must be an existing non-symlink directory\n' >&2
    exit 2
  fi
  TEST_ROOT="$(cd -- "$SUPPLIED_ROOT" && pwd -P)"
  case "$TEST_ROOT" in
    /private/tmp/*) ;;
    *) printf 'Refusing W117 test root outside /private/tmp\n' >&2; exit 2 ;;
  esac
  if [[ -n "$(find "$TEST_ROOT" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    printf 'W117_TEST_ROOT must be fresh and empty\n' >&2
    exit 2
  fi
else
  TEST_ROOT="$(mktemp -d /private/tmp/crystal-click-binary-w117.XXXXXX)"
  TEST_ROOT="$(cd -- "$TEST_ROOT" && pwd -P)"
  case "$TEST_ROOT" in
    /private/tmp/crystal-click-binary-w117.*) ;;
    *) printf 'Refusing unexpected W117 temporary root\n' >&2; exit 1 ;;
  esac
  OWN_ROOT=1
fi
if [[ ! -d "$TEST_ROOT" || -L "$TEST_ROOT" ]]; then
  printf 'Refusing invalid W117 test root\n' >&2
  exit 1
fi

cleanup() {
  local status=$?
  if [[ "$OWN_ROOT" == 0 ]]; then
    printf 'W117 caller-owned test root retained: %s\n' "$TEST_ROOT"
  elif [[ "$KEEP_TMP" == 1 || "$status" -ne 0 ]]; then
    printf 'W117 retained temporary root: %s\n' "$TEST_ROOT"
  elif [[ "$TEST_ROOT" == /private/tmp/crystal-click-binary-w117.* && -d "$TEST_ROOT" && ! -L "$TEST_ROOT" ]]; then
    rm -rf -- "$TEST_ROOT"
  fi
}
trap cleanup EXIT

STORE="$TEST_ROOT/clickhouse-store"
CRYSTAL_CACHE="$TEST_ROOT/crystal-cache"
mkdir "$STORE"
mkdir "$CRYSTAL_CACHE"

cd "$ROOT"
export CLICKHOUSE_BIN W117_STORE="$STORE" W117_TEST_ROOT="$TEST_ROOT"
export CRYSTAL_CACHE_DIR="$CRYSTAL_CACHE"
printf 'W117 paired binary codec check root=%s runtime=%s grammar-source=935de744 codec-source=current-workspace keep=%s\n' \
  "$TEST_ROOT" "$EXECUTED_SHA256" "$KEEP_TMP"
# Caller owns any serial resource guard; this wrapper does not nest one.
"$CRYSTAL_BIN" run --single-module --link-flags='-fuse-ld=ld' \
  "$ROOT/scripts/check_binary_w117.cr" 2>&1 | tee "$TEST_ROOT/check.log"
