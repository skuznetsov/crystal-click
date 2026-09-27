#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
FIXTURE="$ROOT/test/fixtures/public/wide_array_decimal128_w44"
PART="$FIXTURE/part"

[[ -d "$PART" && ! -L "$PART" ]] || { printf 'Decimal128 Array fixture part missing or symlinked\n' >&2; exit 1; }
[[ -f "$FIXTURE/PROVENANCE.md" && ! -L "$FIXTURE/PROVENANCE.md" ]] || { printf 'Decimal128 Array fixture provenance missing\n' >&2; exit 1; }
[[ -f "$FIXTURE/SHA256SUMS" && ! -L "$FIXTURE/SHA256SUMS" ]] || { printf 'Decimal128 Array fixture checksums missing\n' >&2; exit 1; }

python3 - "$PART" "$FIXTURE" <<'PY'
from pathlib import Path
import struct
import sys

part = Path(sys.argv[1])
fixture = Path(sys.argv[2])

def fail(message):
    raise SystemExit(f"Decimal128 Array fixture shape error: {message}")

if any(path.is_symlink() for path in part.rglob("*")):
    fail("part contains a symlink")
entries = list(part.iterdir())
if any(not path.is_file() for path in entries):
    fail("part contains a nested directory or non-regular entry")

metadata = {
    "checksums.txt", "columns.txt", "columns_substreams.txt", "count.txt",
    "default_compression_codec.txt", "metadata_version.txt", "primary.cidx", "serialization.json",
}
bins = {path.stem for path in entries if path.suffix == ".bin"}
marks = {path.stem for path in entries if path.suffix == ".mrk2"}
if len(bins) != 6 or marks != bins:
    fail("file inventory differs from six paired .bin/.mrk2 child streams")
expected_files = metadata | {f"{stream}.{suffix}" for stream in bins for suffix in ("bin", "mrk2")}
if {path.name for path in entries} != expected_files:
    fail("file inventory differs from six child streams and eight metadata files")
if part.joinpath("count.txt").read_bytes() != b"7":
    fail("unexpected row count")
if part.joinpath("metadata_version.txt").read_bytes() != b"0":
    fail("unexpected metadata version")
if part.joinpath("default_compression_codec.txt").read_bytes() != b"CODEC(LZ4)":
    fail("unexpected default compression codec")
if part.joinpath("columns.txt").read_text().splitlines() != [
    "columns format version: 1", "3 columns:", "`pk` UInt64",
    "`plain` Array(Decimal(38, 2))", "`maybe` Array(Nullable(Decimal(38, 2)))",
]:
    fail("columns.txt differs from the exact canonical three-column schema")
if part.joinpath("columns_substreams.txt").read_text().splitlines() != [
    "columns substreams version: 1", "3 columns:",
    "1 substreams for column `pk`:", "\tpk",
    "2 substreams for column `plain`:", "\tplain.size0", "\tplain",
    "3 substreams for column `maybe`:", "\tmaybe.size0", "\tmaybe.null", "\tmaybe",
]:
    fail("columns_substreams.txt differs from the exact Decimal128 Array topology")
if part.joinpath("serialization.json").read_text() != (
    '{"columns":[],"propagate_types_serialization_versions_to_nested_types":true,'
    '"types_serialization_versions":{"string":1},"version":1}'
):
    fail("serialization.json differs from the pinned BASIC profile")

for path in part.glob("*.mrk2"):
    raw = path.read_bytes()
    if len(raw) != 5 * 24:
        fail(f"{path.name} does not contain four marks and an EOF sentinel")
    counts = [struct.unpack_from("<QQQ", raw, offset)[2] for offset in range(0, len(raw), 24)]
    if counts != [2, 2, 2, 1, 0]:
        fail(f"{path.name} has unexpected rows-per-mark: {counts}")

for path in part.glob("*.bin"):
    raw = path.read_bytes()
    offset = 0
    frame_count = 0
    while offset < len(raw):
        if offset + 25 > len(raw):
            fail(f"{path.name} ends inside a ClickHouse frame")
        method = raw[offset + 16]
        compressed_size, decompressed_size = struct.unpack_from("<II", raw, offset + 17)
        if method != 0x82:
            fail(f"{path.name} frame {frame_count} is not LZ4")
        if compressed_size < 9 or decompressed_size == 0 or offset + 16 + compressed_size > len(raw):
            fail(f"{path.name} frame {frame_count} has invalid size fields")
        offset += 16 + compressed_size
        frame_count += 1
    if offset != len(raw) or frame_count == 0:
        fail(f"{path.name} has no complete LZ4 frame sequence")

listed = sorted(line.split(None, 1)[1].lstrip("* ") for line in fixture.joinpath("SHA256SUMS").read_text().splitlines())
actual = sorted(str(path.relative_to(fixture)) for path in part.iterdir() if path.is_file())
if listed != actual:
    fail("SHA256SUMS does not list exactly the part files")
PY

(cd "$FIXTURE" && shasum -a 256 -c SHA256SUMS >/dev/null)
printf 'stock Decimal128 Array fixture verified: 3 canonical columns, 6 LZ4 streams, mark rows [2, 2, 2, 1]\n'
