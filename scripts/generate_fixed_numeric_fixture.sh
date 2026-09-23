#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUT="$ROOT/test/fixtures/public/wide_numeric_mixed/part"
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
expected_columns = [
    ("u8", "UInt8"),
    ("u16", "UInt16"),
    ("u32", "UInt32"),
    ("u64", "UInt64"),
    ("i8", "Int8"),
    ("i16", "Int16"),
    ("i32", "Int32"),
    ("i64", "Int64"),
    ("f32", "Float32"),
    ("f64", "Float64"),
]


def fail(message):
    raise SystemExit(f"fixed-numeric fixture shape error: {message}")


if not root.is_dir():
    fail(f"missing fixture: {root}")
entries = list(root.iterdir())
if any(entry.is_symlink() or not entry.is_file() for entry in entries):
    fail("fixture contains a directory or non-regular entry")
if root.joinpath("count.txt").read_bytes() != b"4":
    fail("unexpected row count")
if root.joinpath("default_compression_codec.txt").read_bytes() != b"CODEC(LZ4)":
    fail("unexpected default codec")
columns = root.joinpath("columns.txt").read_text().splitlines()
if columns != ["columns format version: 1", "10 columns:"] + [f"`{name}` {kind}" for name, kind in expected_columns]:
    fail("columns.txt differs from the expected exact primitive schema")
streams = root.joinpath("columns_substreams.txt").read_text().splitlines()
expected_streams = ["columns substreams version: 1", "10 columns:"]
for name, _ in expected_columns:
    expected_streams.extend((f"1 substreams for column `{name}`:", f"\t{name}"))
if streams != expected_streams:
    fail("columns_substreams.txt differs from the expected primitive streams")
data_paths = sorted(root.glob("*.bin"))
mark_paths = sorted(root.glob("*.mrk2"))
if len(data_paths) != len(expected_columns) or len(mark_paths) != len(expected_columns):
    fail("expected one .bin and one plain .mrk2 stream per column")
if list(root.glob("*.cmrk2")):
    fail("expected plain .mrk2 marks")
sequences = []
for path in mark_paths:
    data = path.read_bytes()
    if not data or len(data) % 24:
        fail(f"{path.name} has a truncated mark record")
    records = [struct.unpack_from("<QQQ", data, offset) for offset in range(0, len(data), 24)]
    if records[-1][2] != 0 or any(record[2] == 0 for record in records[:-1]):
        fail(f"{path.name} has an invalid EOF sentinel")
    rows = [record[2] for record in records[:-1]]
    if sum(rows) != 4 or len(rows) < 1:
        fail(f"{path.name} does not describe all four rows")
    sequences.append(rows)
if any(rows != sequences[0] for rows in sequences[1:]):
    fail("primitive columns have different mark row sequences")
PY
}

if ((CHECK == 1)); then
  check_shape "$OUT"
  printf 'fixture shape: 10 primitive numeric columns, 4 rows, LZ4, plain .mrk2\n'
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

TMP_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/crystal-click-fixed-numeric.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT
STORE="$TMP_ROOT/store"
mkdir -p "$(dirname -- "$OUT")"

"$CLICKHOUSE" local --path "$STORE" --query '
CREATE TABLE source
(
    `u8` UInt8,
    `u16` UInt16,
    `u32` UInt32,
    `u64` UInt64,
    `i8` Int8,
    `i16` Int16,
    `i32` Int32,
    `i64` Int64,
    `f32` Float32,
    `f64` Float64
)
ENGINE = MergeTree
ORDER BY tuple()
SETTINGS
    min_rows_for_wide_part = 0,
    min_bytes_for_wide_part = 0,
    enable_mixed_granularity_parts = 1,
    index_granularity = 2,
    compress_marks = 0,
    min_compress_block_size = 0,
    max_compress_block_size = 4096,
    default_compression_codec = '\''LZ4'\'';

INSERT INTO source
SELECT
    multiIf(number = 0, toUInt8(0), number = 1, toUInt8(127), number = 2, toUInt8(255), toUInt8(1)),
    multiIf(number = 0, toUInt16(0), number = 1, toUInt16(32767), number = 2, toUInt16(65535), toUInt16(1)),
    multiIf(number = 0, toUInt32(0), number = 1, toUInt32(2147483647), number = 2, toUInt32(4294967295), toUInt32(1)),
    multiIf(number = 0, toUInt64(0), number = 1, toUInt64(9223372036854775807), number = 2, toUInt64('\''18446744073709551615'\''), toUInt64(1)),
    multiIf(number = 0, toInt8(-128), number = 1, toInt8(-1), number = 2, toInt8(0), toInt8(127)),
    multiIf(number = 0, toInt16(-32768), number = 1, toInt16(-1), number = 2, toInt16(0), toInt16(32767)),
    multiIf(number = 0, toInt32(-2147483648), number = 1, toInt32(-1), number = 2, toInt32(0), toInt32(2147483647)),
    multiIf(number = 0, toInt64('\''-9223372036854775808'\''), number = 1, toInt64(-1), number = 2, toInt64(0), toInt64(9223372036854775807)),
    multiIf(number = 0, reinterpretAsFloat32(unhex('\''00000000'\'')), number = 1, reinterpretAsFloat32(unhex('\''00000080'\'')), number = 2, reinterpretAsFloat32(unhex('\''0000c03f'\'')), reinterpretAsFloat32(unhex('\''000010c0'\''))),
    multiIf(number = 0, reinterpretAsFloat64(unhex('\''0000000000000000'\'')), number = 1, reinterpretAsFloat64(unhex('\''0000000000000080'\'')), number = 2, reinterpretAsFloat64(unhex('\''000000000000f83f'\'')), reinterpretAsFloat64(unhex('\''00000000000002c0'\'')))
FROM numbers(4);
'

PART_PATH="$("$CLICKHOUSE" local --path "$STORE" --query "SELECT path FROM system.parts WHERE table = 'source' AND active FORMAT TSVRaw")"
[[ -n "$PART_PATH" ]] || { printf 'ClickHouse did not report a part path\n' >&2; exit 1; }

STAGED="$TMP_ROOT/part"
cp -R "$PART_PATH" "$STAGED"
check_shape "$STAGED"
mv "$STAGED" "$OUT"
printf 'generated %s\n' "$OUT"
