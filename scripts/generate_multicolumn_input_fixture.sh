#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUT="$ROOT/test/fixtures/public/wide_multi_input_delta_zstd/part"
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
target_hash = "40e9692b249087848c5984b3e27b0514"
stream_hashes = {
    # prefix: prefix.size, prefix
    "51d1a3d8e5acb077506e218b27af9100",
    "0d365cf0b11cc61870b4eb176160463f",
    # input: input
    target_hash,
    # suffix: suffix.size0, suffix.null, suffix.size, suffix
    "84417d12ebd18d230f6c54abe3d93754",
    "194ae83f6cdac689225deb5127b14952",
    "4eea0b6cf1014e5ee4c2862e5ec326d8",
    "1e8c0ffecee24cc6ccbf743d5f16c33f",
}
expected_files = {
    "checksums.txt",
    "columns.txt",
    "columns_substreams.txt",
    "count.txt",
    "default_compression_codec.txt",
    "metadata_version.txt",
    "serialization.json",
}
for stream_hash in stream_hashes:
    expected_files.add(f"{stream_hash}.bin")
    expected_files.add(f"{stream_hash}.cmrk2")


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
    "columns.txt": (
        b"columns format version: 1\n"
        b"3 columns:\n"
        b"`prefix` String\n"
        b"`input` UInt64\n"
        b"`suffix` Array(Nullable(String))\n"
    ),
    "columns_substreams.txt": (
        b"columns substreams version: 1\n"
        b"3 columns:\n"
        b"2 substreams for column `prefix`:\n"
        b"\tprefix.size\n"
        b"\tprefix\n"
        b"1 substreams for column `input`:\n"
        b"\tinput\n"
        b"4 substreams for column `suffix`:\n"
        b"\tsuffix.size0\n"
        b"\tsuffix.null\n"
        b"\tsuffix.size\n"
        b"\tsuffix\n"
    ),
    "default_compression_codec.txt": b"CODEC(LZ4)",
    "metadata_version.txt": b"0",
    "serialization.json": (
        b'{"columns":[{"kind":"Default","name":"input","num_defaults":0,'
        b'"num_rows":4096},{"kind":"Default","name":"prefix","num_defaults":0,'
        b'"num_rows":4096}],"propagate_types_serialization_versions_to_nested_types":true,'
        b'"types_serialization_versions":{"string":1},"version":1}'
    ),
}
for name, expected in expected_metadata.items():
    actual = (root / name).read_bytes()
    if actual != expected:
        fail(f"{name} does not describe the pinned multi-column fixture")

if (root / "checksums.txt").stat().st_size == 0:
    fail("checksums.txt is empty")


def read_u32(data, offset):
    if offset < 0 or offset + 4 > len(data):
        fail(f"truncated 32-bit field at offset {offset}")
    return struct.unpack_from("<I", data, offset)[0]


def read_frames(path, expected_method, expected_sizes=None, minimum_frames=1):
    data = path.read_bytes()
    offset = 0
    frames = []
    while offset < len(data):
        if len(data) - offset < 25:
            fail(f"{path.name} has a truncated frame header at {offset}")
        method = data[offset + 16]
        if method != expected_method:
            fail(
                f"{path.name} has method 0x{method:02x} at {offset}, "
                f"expected 0x{expected_method:02x}"
            )
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
    if not frames:
        fail(f"{path.name} is empty")
    if len(frames) < minimum_frames:
        fail(f"{path.name} has only {len(frames)} compressed frame(s)")
    if expected_sizes is not None and [frame[2] for frame in frames] != expected_sizes:
        fail(
            f"{path.name} has decoded sizes {[frame[2] for frame in frames]!r}, "
            f"expected {expected_sizes!r}"
        )
    return data, frames


target_data = root / f"{target_hash}.bin"
target_marks = root / f"{target_hash}.cmrk2"
if (root / "input.bin").exists() or (root / "input.cmrk2").exists():
    fail("target exact-name alternate must not be present in the fixture")

data, data_frames = read_frames(target_data, 0x91, [4096] * 8, 8)
if sum(frame[2] for frame in data_frames) != 4096 * 8:
    fail("target data frames do not cover 4096 UInt64 values")

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
        fail(
            f"Multiple methods are {methods.hex()} at {offset}, "
            "expected 9290"
        )
    nested_offset = payload_offset + 1 + codec_count
    if nested_offset + 9 > payload_end:
        fail(f"nested ZSTD header is truncated at {nested_offset}")
    if data[nested_offset] != 0x90:
        fail(
            f"nested method is 0x{data[nested_offset]:02x} at {nested_offset}, "
            "expected 0x90"
        )
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

mark_data, mark_frames = read_frames(target_marks, 0x90, [256, 152], 2)
if sum(frame[2] for frame in mark_frames) != 17 * 24:
    fail("target compressed marks do not decode to 16 marks plus an EOF sentinel")

# The three-column shape must retain opaque physical neighbors.  Their stream
# hashes are asserted above, and these counts make an accidental first-column
# or target-only fixture impossible to pass.
prefix_hashes = {
    "51d1a3d8e5acb077506e218b27af9100",
    "0d365cf0b11cc61870b4eb176160463f",
}
suffix_hashes = {
    "84417d12ebd18d230f6c54abe3d93754",
    "194ae83f6cdac689225deb5127b14952",
    "4eea0b6cf1014e5ee4c2862e5ec326d8",
    "1e8c0ffecee24cc6ccbf743d5f16c33f",
}
for group, expected_count in ((prefix_hashes, 2), (suffix_hashes, 4)):
    if sum((root / f"{stream_hash}.bin").is_file() for stream_hash in group) != expected_count:
        fail("neighbor data substream count does not match metadata")
    if sum((root / f"{stream_hash}.cmrk2").is_file() for stream_hash in group) != expected_count:
        fail("neighbor mark substream count does not match metadata")
PY
}

if ((CHECK == 1)); then
  check_shape "$OUT"
  printf 'fixture shape: prefix/input/suffix Wide part, 4096 rows, Delta/ZSTD input, compressed ZSTD marks\n'
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

TMP_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/crystal-click-multicolumn.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

STORE="$TMP_ROOT/store"
mkdir -p "$(dirname -- "$OUT")"

"$CLICKHOUSE" local --path "$STORE" --query '
CREATE TABLE source
(
    `prefix` String,
    `input` UInt64 CODEC(Delta(8), ZSTD(1)),
    `suffix` Array(Nullable(String))
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
    default_compression_codec = '\''LZ4'\'';

INSERT INTO source
SELECT
    concat('\''prefix-'\'', toString(number % 17)),
    multiIf(
        number = 1, toUInt64(18446744073709551615),
        number = 2, toUInt64(0),
        number = 3, toUInt64(1),
        number = 2047, toUInt64(18446744073709551615),
        number = 2048, toUInt64(0),
        number % 23 = 0, toUInt64(42),
        toUInt64((number * 17) % 100000)
    ),
    [
        if(number % 5 = 0, CAST(NULL, '\''Nullable(String)'\''), concat('\''suffix-'\'', toString(number % 13))),
        if(number % 7 = 0, CAST(NULL, '\''Nullable(String)'\''), concat('\''tail-'\'', toString(number % 11)))
    ]
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
