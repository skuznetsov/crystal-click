#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUT="$ROOT/test/fixtures/public/wide_u64_delta_zstd/part"
CLICKHOUSE="${CLICKHOUSE:-$(command -v clickhouse || true)}"
FORCE=0
CHECK=0

usage() {
  printf 'usage: %s [--check] [--force]\n' "$0" >&2
}

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
  python3 - "$dir" <<'PY'
from pathlib import Path
import struct
import sys

root = Path(sys.argv[1])
stream_name = "caa7f9c8e43d2fa739d1e26d71e99843"
expected_files = {
    f"{stream_name}.bin",
    f"{stream_name}.cmrk2",
    "checksums.txt",
    "columns.txt",
    "columns_substreams.txt",
    "count.txt",
    "default_compression_codec.txt",
    "metadata_version.txt",
    "serialization.json",
}


def fail(message):
    raise SystemExit(f"fixture shape error: {message}")


if not root.is_dir():
    fail(f"missing fixture: {root}")
entries = list(root.iterdir())
if any(not entry.is_file() for entry in entries):
    fail("fixture contains a directory or non-regular entry")
actual_files = {entry.name for entry in entries}
if actual_files != expected_files:
    fail(f"unexpected file set: {sorted(actual_files)!r}")

expected_metadata = {
    "count.txt": b"4096",
    "columns.txt": b"columns format version: 1\n1 columns:\n`value` UInt64\n",
    "columns_substreams.txt": (
        b"columns substreams version: 1\n"
        b"1 columns:\n"
        b"1 substreams for column `value`:\n"
        b"\tvalue\n"
    ),
    "default_compression_codec.txt": b"CODEC(ZSTD(1))",
    "metadata_version.txt": b"0",
    "serialization.json": (
        b'{"columns":[{"kind":"Default","name":"value","num_defaults":90,'
        b'"num_rows":4096}],"propagate_types_serialization_versions_to_nested_types":true,'
        b'"types_serialization_versions":{"string":1},"version":1}'
    ),
}
for name, expected in expected_metadata.items():
    actual = (root / name).read_bytes()
    if actual != expected:
        fail(f"{name} does not describe the pinned Delta(8)/ZSTD(1) fixture")


def read_u32(data, offset):
    if offset < 0 or offset + 4 > len(data):
        fail(f"truncated 32-bit field at offset {offset}")
    return struct.unpack_from("<I", data, offset)[0]


def read_frames(path, expected_method, expected_sizes, minimum_frames):
    data = path.read_bytes()
    offset = 0
    frames = []
    while offset < len(data):
        if len(data) - offset < 25:
            fail(f"{path.name} has a truncated frame header at {offset}")
        method = data[offset + 16]
        if method != expected_method:
            fail(f"{path.name} has method 0x{method:02x} at {offset}, expected 0x{expected_method:02x}")
        compressed_size = read_u32(data, offset + 17)
        decompressed_size = read_u32(data, offset + 21)
        if compressed_size < 9:
            fail(f"{path.name} has an invalid compressed size at {offset}")
        if decompressed_size == 0:
            fail(f"{path.name} has a zero decompressed size at {offset}")
        end = offset + 16 + compressed_size
        if end > len(data):
            fail(f"{path.name} has a truncated frame payload at {offset}")
        frames.append((offset, compressed_size, decompressed_size, end))
        offset = end
    if len(frames) < minimum_frames:
        fail(f"{path.name} has only {len(frames)} compressed frame(s)")
    if expected_sizes is not None and [frame[2] for frame in frames] != expected_sizes:
        fail(f"{path.name} has decoded sizes {[frame[2] for frame in frames]!r}, expected {expected_sizes!r}")
    return data, frames


data_path = root / f"{stream_name}.bin"
data, data_frames = read_frames(data_path, 0x91, [4096] * 8, 8)
if sum(frame[2] for frame in data_frames) != 4096 * 8:
    fail("data frames do not cover 4096 UInt64 values")

for offset, compressed_size, decompressed_size, frame_end in data_frames:
    payload_offset = offset + 16 + 9
    payload_end = offset + 16 + compressed_size
    if payload_offset >= payload_end:
        fail(f"Multiple payload is empty at {offset}")
    codec_count = data[payload_offset]
    if codec_count != 2:
        fail(f"Multiple codec count is {codec_count} at {offset}, expected 2")
    methods = data[payload_offset + 1:payload_offset + 1 + codec_count]
    if methods != bytes((0x92, 0x90)):
        fail(f"Multiple methods are {methods.hex()} at {offset}, expected 9290")
    nested_offset = payload_offset + 1 + codec_count
    if nested_offset + 9 > payload_end:
        fail(f"nested ZSTD header is truncated at {nested_offset}")
    if data[nested_offset] != 0x90:
        fail(f"nested method is 0x{data[nested_offset]:02x} at {nested_offset}, expected 0x90")
    nested_compressed_size = read_u32(data, nested_offset + 1)
    nested_decompressed_size = read_u32(data, nested_offset + 5)
    if nested_compressed_size < 9:
        fail(f"nested ZSTD compressed size is invalid at {nested_offset}")
    if nested_decompressed_size != decompressed_size + 11:
        fail(
            f"nested ZSTD decoded size is {nested_decompressed_size} at {nested_offset}, "
            f"expected Delta frame size {decompressed_size + 11}"
        )
    if nested_offset + nested_compressed_size != frame_end:
        fail(f"nested ZSTD frame does not end with its Multiple block at {nested_offset}")

mark_path = root / f"{stream_name}.cmrk2"
mark_data, mark_frames = read_frames(mark_path, 0x90, [256, 152], 2)
if sum(frame[2] for frame in mark_frames) != 17 * 24:
    fail("compressed marks do not decode to 16 marks plus an EOF sentinel")
if len(mark_data) == 0:
    fail("compressed marks are empty")

checksums = root / "checksums.txt"
if checksums.stat().st_size == 0:
    fail("checksums.txt is empty")
PY
}

if ((CHECK == 1)); then
  check_shape "$OUT"
  printf 'fixture shape: Wide UInt64 CODEC(Delta(8), ZSTD(1)), 4096 rows, 8 data frames, ZSTD .cmrk2\n'
  exit 0
fi

if [[ -z "$CLICKHOUSE" || ! -x "$CLICKHOUSE" ]]; then
  printf 'clickhouse executable not found; set CLICKHOUSE or add it to PATH\n' >&2
  exit 1
fi

EXPECTED_VERSION='ClickHouse local version 26.7.1.1315 (official build).'
ACTUAL_VERSION="$($CLICKHOUSE local --version)"
if [[ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]]; then
  printf 'fixture producer mismatch: expected %s, got %s\n' "$EXPECTED_VERSION" "$ACTUAL_VERSION" >&2
  exit 1
fi

if [[ -e "$OUT" && "$FORCE" != 1 ]]; then
  printf 'fixture exists; use --force only to replace this owned path: %s\n' "$OUT" >&2
  exit 2
fi

TMP_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/crystal-click-delta-zstd.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

STORE="$TMP_ROOT/store"
mkdir -p "$(dirname -- "$OUT")"

"$CLICKHOUSE" local --path "$STORE" --query '
CREATE TABLE source
(
    `value` UInt64 CODEC(Delta(8), ZSTD(1))
)
ENGINE = MergeTree
ORDER BY tuple()
SETTINGS
    min_rows_for_wide_part = 0,
    min_bytes_for_wide_part = 0,
    enable_mixed_granularity_parts = 1,
    index_granularity = 256,
    compress_marks = 1,
    marks_compression_codec = '\''ZSTD(1)'\'',
    marks_compress_block_size = 256,
    min_compress_block_size = 0,
    max_compress_block_size = 4096,
    default_compression_codec = '\''ZSTD(1)'\'';

INSERT INTO source
SELECT multiIf(
    number = 127, toUInt64(18446744073709551615),
    number = 128, toUInt64(0),
    number = 129, toUInt64(1),
    number = 255, toUInt64(18446744073709551615),
    number = 256, toUInt64(0),
    number < 512, toUInt64(number % 7),
    number < 1024, toUInt64(1000),
    number % 11 = 0, toUInt64(42),
    toUInt64(number)
)
FROM numbers(4096);
'

PART_PATH="$($CLICKHOUSE local --path "$STORE" --query "SELECT path FROM system.parts WHERE table = 'source' AND active FORMAT TSVRaw")"
[[ -n "$PART_PATH" ]] || { printf 'ClickHouse did not report a part path\n' >&2; exit 1; }

STAGED="$TMP_ROOT/part"
cp -R "$PART_PATH" "$STAGED"
check_shape "$STAGED"

if [[ -e "$OUT" ]]; then
  rm -rf "$OUT"
fi
mv "$STAGED" "$OUT"
printf 'generated %s\n' "$OUT"
