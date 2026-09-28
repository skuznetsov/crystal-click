#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
FIXTURE_ROOT="${W56_FIXTURE_ROOT:-$ROOT/test/fixtures/public/wide_variant_w56}"
PROFILE="${1:-compact}"
case "$PROFILE" in
  compact) FIXTURE="$FIXTURE_ROOT/compact" ;;
  basic) FIXTURE="$FIXTURE_ROOT/basic" ;;
  *) printf 'unknown W56 fixture profile: %s\n' "$PROFILE" >&2; exit 2 ;;
esac
PART="$FIXTURE/part"

[[ -d "$PART" && ! -L "$PART" ]] || { printf 'W56 fixture part missing or symlinked\n' >&2; exit 1; }
[[ -f "$FIXTURE/SHA256SUMS" && ! -L "$FIXTURE/SHA256SUMS" ]] || { printf 'W56 fixture checksums missing\n' >&2; exit 1; }

python3 - "$PROFILE" "$PART" "$FIXTURE" <<'PY'
from pathlib import Path
import struct
import sys

profile, part_name, fixture_name = sys.argv[1:]
part = Path(part_name)
fixture = Path(fixture_name)

def fail(message):
    raise SystemExit(f"W56 fixture shape error: {message}")

if any(path.is_symlink() for path in part.rglob("*")):
    fail("part contains a symlink")
entries = list(part.iterdir())
if any(not path.is_file() for path in entries):
    fail("part contains a nested directory or non-regular entry")

metadata = {
    "checksums.txt", "columns.txt", "columns_substreams.txt", "count.txt",
    "default_compression_codec.txt", "metadata_version.txt", "primary.cidx", "serialization.json",
}
bins = {path.stem for path in part.glob("*.bin")}
marks = {path.stem for path in part.glob("*.mrk2")}
if len(bins) != 5 or bins != marks:
    fail("expected five matched LZ4 data streams and plain .mrk2 mark files")
expected_files = metadata | {f"{stream}.{suffix}" for stream in bins for suffix in ("bin", "mrk2")}
if {path.name for path in entries} != expected_files:
    fail("part file inventory differs from five data streams, five mark files, and eight metadata files")
if any(part.glob("*.cmrk*")) or any(part.glob("*.mrk")) or any(part.glob("*.mrk3")):
    fail("fixture must use plain .mrk2 marks only")
if part.joinpath("count.txt").read_bytes() != b"7":
    fail("unexpected row count")
if part.joinpath("metadata_version.txt").read_bytes() != b"0":
    fail("unexpected metadata version")
if part.joinpath("default_compression_codec.txt").read_bytes() != b"CODEC(LZ4)":
    fail("unexpected default compression codec")
if part.joinpath("columns.txt").read_text().splitlines() != [
    "columns format version: 1", "2 columns:", "`pk` UInt64",
    "`payload` Variant(String, UInt64)",
]:
    fail("columns.txt differs from the exact canonical schema")
if part.joinpath("columns_substreams.txt").read_text().splitlines() != [
    "columns substreams version: 1", "2 columns:", "1 substreams for column `pk`:", "\tpk",
    "4 substreams for column `payload`:", "\tpayload.variant_discr", "\tpayload.String.size",
    "\tpayload.String", "\tpayload.UInt64",
]:
    fail("columns_substreams.txt differs from the exact escaped Variant child topology")
if part.joinpath("serialization.json").read_text() != (
    '{"columns":[],"propagate_types_serialization_versions_to_nested_types":true,'
    '"types_serialization_versions":{"string":1},"version":1}'
):
    fail("serialization.json differs from the pinned BASIC Variant profile")

expected_counts = [3, 3, 1, 0]
for path in part.glob("*.mrk2"):
    raw = path.read_bytes()
    if len(raw) != 4 * 24:
        fail(f"{path.name} does not contain three marks and an EOF sentinel")
    records = [struct.unpack_from("<QQQ", raw, offset) for offset in range(0, len(raw), 24)]
    counts = [record[2] for record in records]
    if counts != expected_counts:
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
printf 'stock W56 %s fixture verified: exact Variant streams, five LZ4 streams, mark rows [3, 3, 1]\n' "$PROFILE"
