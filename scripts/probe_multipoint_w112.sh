#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

if [[ "$#" -ne 1 ]]; then
  printf 'Usage: %s qualify|red|reader|writer\n' "$0" >&2
  exit 2
fi
MODE="$1"
case "$MODE" in
  qualify|red|reader|writer) ;;
  *) printf 'Usage: %s qualify|red|reader|writer\n' "$0" >&2; exit 2 ;;
esac

CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-}"
if [[ -z "$CLICKHOUSE_BIN" || ! -x "$CLICKHOUSE_BIN" ]]; then
  printf 'Set CLICKHOUSE_BIN to the isolated W112 ClickHouse executable\n' >&2
  exit 1
fi

EXPECTED_VERSION='ClickHouse local version 26.10.1.1201 (official build).'
# The official 174,530,241-byte download is a self-extracting carrier. On
# macOS its first execution replaces that path with the expanded Mach-O before
# execv; the carrier and the tested executable therefore have distinct hashes.
EXPECTED_CARRIER_SHA256='23b2e0292f622565b8312795c190b8af89cb0eae559b6e51ac856a7259bdbf44'
EXPECTED_EXECUTED_SHA256='bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2'
INPUT_SHA256="$(shasum -a 256 "$CLICKHOUSE_BIN" | cut -d ' ' -f 1)"
if [[ "$INPUT_SHA256" != "$EXPECTED_CARRIER_SHA256" && "$INPUT_SHA256" != "$EXPECTED_EXECUTED_SHA256" ]]; then
  printf 'W112 input SHA-256 mismatch: expected known carrier %s or expanded Mach-O %s, got %s\n' \
    "$EXPECTED_CARRIER_SHA256" "$EXPECTED_EXECUTED_SHA256" "$INPUT_SHA256" >&2
  exit 1
fi
ACTUAL_VERSION="$("$CLICKHOUSE_BIN" local --version)"
if [[ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]]; then
  printf 'W112 requires %s, got %s\n' "$EXPECTED_VERSION" "$ACTUAL_VERSION" >&2
  exit 1
fi
EXECUTED_SHA256="$(shasum -a 256 "$CLICKHOUSE_BIN" | cut -d ' ' -f 1)"
if [[ "$EXECUTED_SHA256" != "$EXPECTED_EXECUTED_SHA256" ]]; then
  printf 'W112 expanded executable SHA-256 mismatch: expected %s, got %s\n' "$EXPECTED_EXECUTED_SHA256" "$EXECUTED_SHA256" >&2
  exit 1
fi

TMP_ROOT="$(mktemp -d /private/tmp/crystal-click-w112.XXXXXX)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

cd "$ROOT"
export CLICKHOUSE_BIN
export W112_STORE="$TMP_ROOT/clickhouse-store"
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache"
mkdir -p "$W112_STORE" "$CRYSTAL_CACHE_DIR"

# `qualify` exits 0 after stock-only source and fresh-ATTACH checks. `red`
# exits 1 only after those certificates pass and the predecessor typed reader
# returns its exact admission/metadata refusals. `reader` and `writer` run the
# paired W112 implementation checks after the same stock qualification.
crystal run --single-module --link-flags='-fuse-ld=ld' "$ROOT/scripts/probe_multipoint_w112.cr" -- "$MODE"
