#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/Users/sergey/.local/bin/clickhouse}"
EXPECTED_VERSION='ClickHouse local version 26.7.1.1315 (official build).'

if [[ ! -x "$CLICKHOUSE_BIN" ]]; then
  printf 'ClickHouse executable not found or not executable: %s\n' "$CLICKHOUSE_BIN" >&2
  exit 1
fi
ACTUAL_VERSION="$("$CLICKHOUSE_BIN" local --version)"
if [[ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]]; then
  printf 'W103 oracle requires %s, got %s\n' "$EXPECTED_VERSION" "$ACTUAL_VERSION" >&2
  exit 1
fi

TMP_ROOT="$(mktemp -d /private/tmp/crystal-click-qbit-w103-oracle.XXXXXX)"
case "$TMP_ROOT" in
  /private/tmp/crystal-click-qbit-w103-oracle.*) ;;
  *) printf 'Refusing unexpected temporary directory: %s\n' "$TMP_ROOT" >&2; exit 1 ;;
esac
cleanup() {
  case "$TMP_ROOT" in
    /private/tmp/crystal-click-qbit-w103-oracle.*) rm -rf -- "$TMP_ROOT" ;;
    *) printf 'Refusing cleanup outside owned W103 temporary root: %s\n' "$TMP_ROOT" >&2; return 1 ;;
  esac
}
trap cleanup EXIT

cd "$ROOT"
export CLICKHOUSE_BIN
export W103O_STORE="$TMP_ROOT/clickhouse-store"
export W103O_WRITER_ROOT="$TMP_ROOT/writer-parts"
export W103O_CATALOG_ROOT="$TMP_ROOT/catalog-fixtures"
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache"
mkdir -p "$W103O_STORE" "$W103O_WRITER_ROOT" "$W103O_CATALOG_ROOT" "$CRYSTAL_CACHE_DIR"

crystal run --link-flags='-fuse-ld=ld' "$ROOT/scripts/check_qbit_oracle.cr"
printf 'PASS W103 QBit oracle on %s\n' "$ACTUAL_VERSION"
