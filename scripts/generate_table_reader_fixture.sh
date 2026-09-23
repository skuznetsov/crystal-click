#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUT="$ROOT/test/fixtures/public/wide_two_uint64/part"
CLICKHOUSE="${CLICKHOUSE:-$(command -v clickhouse || true)}"
CHECK=0

usage() {
  printf 'usage: %s [--check]\n' "$0" >&2
}

while (($# > 0)); do
  case "$1" in
    --check) CHECK=1 ;;
    *) usage; exit 2 ;;
  esac
  shift
done

check_shape() {
  local dir="$1"
  python3 - "$dir" <<'PY'
from pathlib import Path
import struct
import sys

root = Path(sys.argv[1])


def fail(message):
    raise SystemExit(f"table-reader fixture shape error: {message}")


if not root.is_dir():
    fail(f"missing fixture: {root}")
entries = list(root.iterdir())
if any(entry.is_symlink() or not entry.is_file() for entry in entries):
    fail("fixture contains a directory or non-regular entry")
names = {entry.name for entry in entries}
required = {
    "checksums.txt",
    "columns.txt",
    "columns_substreams.txt",
    "count.txt",
    "default_compression_codec.txt",
    "metadata_version.txt",
    "serialization.json",
}
if not required <= names:
    fail(f"missing required files: {sorted(required - names)!r}")
if len([name for name in names if name.endswith(".bin")]) != 2:
    fail("expected exactly two UInt64 data streams")
mark_paths = sorted(root.glob("*.mrk2"))
if len(mark_paths) != 2 or any(path.name.endswith(".cmrk2") for path in root.iterdir()):
    fail("expected exactly two plain .mrk2 streams")
if root.joinpath("count.txt").read_bytes() != b"17001":
    fail("unexpected row count")
if root.joinpath("columns.txt").read_bytes() != (
    b"columns format version: 1\n2 columns:\n`left` UInt64\n`right` UInt64\n"
):
    fail("columns.txt differs from the two-UInt64 schema")
if root.joinpath("columns_substreams.txt").read_bytes() != (
    b"columns substreams version: 1\n2 columns:\n"
    b"1 substreams for column `left`:\n\tleft\n"
    b"1 substreams for column `right`:\n\tright\n"
):
    fail("columns_substreams.txt differs from the two selected streams")

mark_sequences = []
for path in mark_paths:
    data = path.read_bytes()
    if not data or len(data) % 24:
        fail(f"{path.name} has a truncated mark record")
    records = [struct.unpack_from("<QQQ", data, offset) for offset in range(0, len(data), 24)]
    if records[-1][2] != 0 or any(record[2] == 0 for record in records[:-1]):
        fail(f"{path.name} has an invalid EOF sentinel")
    rows = [record[2] for record in records[:-1]]
    if rows != [8192, 8192, 617]:
        fail(f"{path.name} does not contain the expected adaptive mark rows")
    mark_sequences.append(rows)
if mark_sequences[0] != mark_sequences[1]:
    fail("selected UInt64 columns have different mark row sequences")
PY
}

if ((CHECK == 1)); then
  check_shape "$OUT"
  printf 'fixture shape: two UInt64 columns, 17001 rows, [8192, 8192, 617] plain .mrk2 marks\n'
  exit 0
fi

if [[ -z "$CLICKHOUSE" || ! -x "$CLICKHOUSE" ]]; then
  printf 'clickhouse executable not found; set CLICKHOUSE or add it to PATH\n' >&2
  exit 1
fi
if [[ -e "$OUT" ]]; then
  printf 'refusing to replace existing fixture: %s\n' "$OUT" >&2
  exit 2
fi

ACTUAL_VERSION="$("$CLICKHOUSE" local --version)"
EXPECTED_VERSION='ClickHouse local version 26.7.1.1315 (official build).'
if [[ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]]; then
  printf 'fixture producer mismatch: expected %s, got %s\n' "$EXPECTED_VERSION" "$ACTUAL_VERSION" >&2
  exit 1
fi

TMP_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/crystal-click-table-reader.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT
STORE="$TMP_ROOT/store"
mkdir -p "$(dirname -- "$OUT")"

"$CLICKHOUSE" local --path "$STORE" --query '
CREATE TABLE source
(
    `left` UInt64,
    `right` UInt64
)
ENGINE = MergeTree
ORDER BY tuple()
SETTINGS
    min_rows_for_wide_part = 0,
    min_bytes_for_wide_part = 0,
    enable_mixed_granularity_parts = 1,
    index_granularity = 8192,
    compress_marks = 0,
    min_compress_block_size = 0,
    max_compress_block_size = 4096,
    default_compression_codec = '\''LZ4'\'';

INSERT INTO source
SELECT toUInt64(number), toUInt64(number * 3 + 7)
FROM numbers(17001);
'

PART_PATH="$("$CLICKHOUSE" local --path "$STORE" --query "SELECT path FROM system.parts WHERE table = 'source' AND active FORMAT TSVRaw")"
[[ -n "$PART_PATH" ]] || { printf 'ClickHouse did not report a part path\n' >&2; exit 1; }

STAGED="$TMP_ROOT/part"
cp -R "$PART_PATH" "$STAGED"
check_shape "$STAGED"
mv "$STAGED" "$OUT"
printf 'generated %s\n' "$OUT"
