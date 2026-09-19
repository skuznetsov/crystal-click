#!/usr/bin/env bash
set -euo pipefail

CLICKHOUSE="${CLICKHOUSE:-$(command -v clickhouse || true)}"
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUT="$ROOT/test/fixtures/public/wide_u64_lz4/part"
FORCE=0

usage() {
  printf 'usage: %s [--check] [--force]\n' "$0" >&2
}

CHECK=0
while (($# > 0)); do
  case "$1" in
    --check) CHECK=1 ;;
    --force) FORCE=1 ;;
    *) usage; exit 2 ;;
  esac
  shift
done

check_shape() {
  local dir="$1"
  [[ -d "$dir" ]] || { printf 'missing fixture: %s\n' "$dir" >&2; return 1; }
  [[ "$(cat "$dir/count.txt")" == 200000 ]] || return 1
  grep -Fxq '`value` UInt64' "$dir/columns.txt" || return 1
  grep -Fxq 'CODEC(LZ4)' "$dir/default_compression_codec.txt" || return 1
  [[ "$(find "$dir" -maxdepth 1 -type f -name '*.bin' -print | wc -l | tr -d ' ')" == 1 ]] || return 1
  [[ "$(find "$dir" -maxdepth 1 -type f -name '*.mrk2' -print | wc -l | tr -d ' ')" == 1 ]] || return 1
  [[ "$(find "$dir" -maxdepth 1 -type f -name '*.cmrk*' -print | wc -l | tr -d ' ')" == 0 ]] || return 1
  [[ "$(find "$dir" -maxdepth 1 -type f \( -name '*.mrk' -o -name '*.mrk3' -o -name '*.mrk4' \) -print | wc -l | tr -d ' ')" == 0 ]] || return 1
}

if ((CHECK == 1)); then
  check_shape "$OUT"
  printf 'fixture shape: Wide UInt64 CODEC(LZ4), 200000 rows, plain .mrk2\n'
  exit 0
fi

if [[ -z "$CLICKHOUSE" || ! -x "$CLICKHOUSE" ]]; then
  printf 'clickhouse executable not found; set CLICKHOUSE or add it to PATH\n' >&2
  exit 1
fi

EXPECTED_VERSION='ClickHouse local version 26.7.1.1315 (official build).'
ACTUAL_VERSION="$("$CLICKHOUSE" local --version)"
if [[ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]]; then
  printf 'fixture producer mismatch: expected %s, got %s\n' "$EXPECTED_VERSION" "$ACTUAL_VERSION" >&2
  exit 1
fi

if [[ -e "$OUT" && "$FORCE" != 1 ]]; then
  printf 'fixture exists; use --force only to replace this owned path: %s\n' "$OUT" >&2
  exit 2
fi

TMP_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/crystal-click-fixture.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

STORE="$TMP_ROOT/store"
mkdir -p "$(dirname -- "$OUT")"

"$CLICKHOUSE" local --path "$STORE" --query '
CREATE TABLE source
(
    `value` UInt64 CODEC(LZ4)
)
ENGINE = MergeTree
ORDER BY tuple()
SETTINGS
    min_rows_for_wide_part = 0,
    min_bytes_for_wide_part = 0,
    enable_mixed_granularity_parts = 1,
    index_granularity = 1024,
    compress_marks = 0;

INSERT INTO source SELECT number FROM numbers(200000);
'

PART_PATH="$("$CLICKHOUSE" local --path "$STORE" --query "SELECT path FROM system.parts WHERE table = 'source' AND active FORMAT TSVRaw")"
[[ -n "$PART_PATH" ]] || { printf 'ClickHouse did not report a part path\n' >&2; exit 1; }

STAGED="$TMP_ROOT/part"
cp -R "$PART_PATH" "$STAGED"
check_shape "$STAGED"

if [[ -e "$OUT" ]]; then
  rm -rf "$OUT"
fi
mv "$STAGED" "$OUT"
printf 'generated %s\n' "$OUT"
