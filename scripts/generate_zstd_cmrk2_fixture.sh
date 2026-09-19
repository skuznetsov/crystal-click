#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUT="$ROOT/test/fixtures/public/wide_u64_zstd_cmrk2/part"
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
expected_files = {
    "caa7f9c8e43d2fa739d1e26d71e99843.bin",
    "caa7f9c8e43d2fa739d1e26d71e99843.cmrk2",
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
    "count.txt": b"200000",
    "columns.txt": b"columns format version: 1\n1 columns:\n`value` UInt64\n",
    "columns_substreams.txt": (
        b"columns substreams version: 1\n"
        b"1 columns:\n"
        b"1 substreams for column `value`:\n"
        b"\tvalue\n"
    ),
    "default_compression_codec.txt": b"CODEC(ZSTD(1))",
}
for name, expected in expected_metadata.items():
    actual = (root / name).read_bytes()
    if actual != expected:
        fail(f"{name} does not describe the pinned UInt64/ZSTD fixture")

def check_frames(path, expected_decompressed_size, minimum_frames):
    data = path.read_bytes()
    offset = 0
    frames = []
    while offset < len(data):
        if len(data) - offset < 25:
            fail(f"{path.name} has a truncated frame header at {offset}")
        method = data[offset + 16]
        if method != 0x90:
            fail(f"{path.name} has compression method 0x{method:02x} at {offset}")
        compressed_size = struct.unpack_from("<I", data, offset + 17)[0]
        decompressed_size = struct.unpack_from("<I", data, offset + 21)[0]
        if compressed_size < 9:
            fail(f"{path.name} has an invalid compressed size at {offset}")
        if decompressed_size == 0:
            fail(f"{path.name} has a zero decompressed size at {offset}")
        end = offset + 16 + compressed_size
        if end > len(data):
            fail(f"{path.name} has a truncated frame payload at {offset}")
        frames.append((offset, compressed_size, decompressed_size))
        offset = end
    if len(frames) < minimum_frames:
        fail(f"{path.name} has only {len(frames)} compressed frame(s)")
    total_decompressed = sum(frame[2] for frame in frames)
    if total_decompressed != expected_decompressed_size:
        fail(
            f"{path.name} decompresses to {total_decompressed} bytes, "
            f"expected {expected_decompressed_size}"
        )
    return frames

check_frames(root / "caa7f9c8e43d2fa739d1e26d71e99843.bin", 1_600_000, 1)
check_frames(root / "caa7f9c8e43d2fa739d1e26d71e99843.cmrk2", 4_728, 2)
PY
}

if ((CHECK == 1)); then
  check_shape "$OUT"
  printf 'fixture shape: Wide UInt64 CODEC(ZSTD), 200000 rows, compressed .cmrk2, method 0x90\n'
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

TMP_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/crystal-click-zstd-cmrk2.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

STORE="$TMP_ROOT/store"
mkdir -p "$(dirname -- "$OUT")"

"$CLICKHOUSE" local --path "$STORE" --query '
CREATE TABLE source
(
    `value` UInt64 CODEC(ZSTD)
)
ENGINE = MergeTree
ORDER BY tuple()
SETTINGS
    min_rows_for_wide_part = 0,
    min_bytes_for_wide_part = 0,
    enable_mixed_granularity_parts = 1,
    index_granularity = 1024,
    compress_marks = 1,
    marks_compression_codec = '\''ZSTD(3)'\'',
    marks_compress_block_size = 256,
    default_compression_codec = '\''ZSTD(1)'\'';

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
