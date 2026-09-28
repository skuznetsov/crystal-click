#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
FIXTURE_ROOT="${W57_FIXTURE_ROOT:-$ROOT/test/fixtures/public/wide_variant_w57}"
PROFILE="${1:-compact}"
case "$PROFILE" in
  compact) FIXTURE="$FIXTURE_ROOT/compact" ;;
  basic) FIXTURE="$FIXTURE_ROOT/basic" ;;
  *) printf 'unknown W57 fixture profile: %s\n' "$PROFILE" >&2; exit 2 ;;
esac
PART="$FIXTURE/part"

[[ -d "$PART" && ! -L "$PART" ]] || { printf 'W57 fixture part missing or symlinked\n' >&2; exit 1; }
[[ -f "$FIXTURE/SHA256SUMS" && ! -L "$FIXTURE/SHA256SUMS" ]] || { printf 'W57 fixture checksums missing\n' >&2; exit 1; }

python3 - "$PROFILE" "$PART" "$FIXTURE" <<'PY'
from pathlib import Path
import struct
import sys

profile, part_name, fixture_name = sys.argv[1:]
part = Path(part_name)
fixture = Path(fixture_name)

def fail(message):
    raise SystemExit(f"W57 fixture shape error: {message}")

def decode_lz4_block(source, expected_size):
    output = bytearray()
    cursor = 0
    while cursor < len(source):
        token = source[cursor]
        cursor += 1
        literal_size = token >> 4
        if literal_size == 15:
            while True:
                extension = source[cursor]
                cursor += 1
                literal_size += extension
                if extension != 255:
                    break
        end = cursor + literal_size
        if end > len(source):
            fail("LZ4 literal run exceeds its frame")
        output.extend(source[cursor:end])
        cursor = end
        if cursor == len(source):
            break
        if cursor + 2 > len(source):
            fail("LZ4 match offset is truncated")
        distance = source[cursor] | (source[cursor + 1] << 8)
        cursor += 2
        if distance == 0 or distance > len(output):
            fail("LZ4 match offset is invalid")
        match_size = (token & 0x0F) + 4
        if token & 0x0F == 15:
            while True:
                extension = source[cursor]
                cursor += 1
                match_size += extension
                if extension != 255:
                    break
        for _ in range(match_size):
            output.append(output[-distance])
    if len(output) != expected_size:
        fail(f"LZ4 decoded size {len(output)} differs from frame header {expected_size}")
    return bytes(output)

def decode_first_clickhouse_frame(path):
    raw = path.read_bytes()
    if len(raw) < 25:
        fail(f"{path.name} has a truncated ClickHouse frame")
    method = raw[16]
    compressed_size, decompressed_size = struct.unpack_from("<II", raw, 17)
    if method != 0x82 or compressed_size < 9 or 16 + compressed_size > len(raw):
        fail(f"{path.name} has an invalid first LZ4 frame")
    payload = raw[25:16 + compressed_size]
    return decode_lz4_block(payload, decompressed_size)

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
if len(bins) != 6 or bins != marks:
    fail("expected six matched LZ4 data streams and plain .mrk2 mark files")
expected_files = metadata | {f"{stream}.{suffix}" for stream in bins for suffix in ("bin", "mrk2")}
if {path.name for path in entries} != expected_files:
    fail("part file inventory differs from six data streams, six mark files, and eight metadata files")
if any(part.glob("*.cmrk*")) or any(part.glob("*.mrk")) or any(part.glob("*.mrk3")):
    fail("fixture must use plain .mrk2 marks only")
if part.joinpath("count.txt").read_bytes() != b"13":
    fail("unexpected row count")
if part.joinpath("metadata_version.txt").read_bytes() != b"0":
    fail("unexpected metadata version")
if part.joinpath("default_compression_codec.txt").read_bytes() != b"CODEC(LZ4)":
    fail("unexpected default compression codec")
if part.joinpath("columns.txt").read_text().splitlines() != [
    "columns format version: 1", "2 columns:", "`pk` UInt64",
    "`payload` Variant(Bool, String, UInt64)",
]:
    fail("columns.txt differs from the exact canonical schema")
if part.joinpath("columns_substreams.txt").read_text().splitlines() != [
    "columns substreams version: 1", "2 columns:", "1 substreams for column `pk`:", "\tpk",
    "5 substreams for column `payload`:", "\tpayload.variant_discr", "\tpayload.Bool",
    "\tpayload.String.size", "\tpayload.String", "\tpayload.UInt64",
]:
    fail("columns_substreams.txt differs from the exact ordered Variant child topology")
if part.joinpath("serialization.json").read_text() != (
    '{"columns":[],"propagate_types_serialization_versions_to_nested_types":true,'
    '"types_serialization_versions":{"string":1},"version":1}'
):
    fail("serialization.json differs from the pinned stock Variant profile")

expected_counts = [3, 3, 3, 3, 1, 0]
for path in part.glob("*.mrk2"):
    raw = path.read_bytes()
    if len(raw) != len(expected_counts) * 24:
        fail(f"{path.name} does not contain five marks and an EOF sentinel")
    records = [struct.unpack_from("<QQQ", raw, offset) for offset in range(0, len(raw), 24)]
    counts = [record[2] for record in records]
    if counts != expected_counts:
        fail(f"{path.name} has unexpected rows-per-mark: {counts}")
    if records[0][0] != 0:
        fail(f"{path.name} first mark does not begin at compressed offset zero")

# This is StreamName.hash("payload.variant_discr"), shared by the pinned W56
# fixture. Check the stream by identity instead of guessing from file sizes.
discriminator_stem = "f599d23f7de1b820c958bccc3c6ddb57"
if discriminator_stem not in bins:
    fail("payload.variant_discr stream hash is missing")
discriminator_marks = [
    struct.unpack_from("<QQQ", part.joinpath(f"{discriminator_stem}.mrk2").read_bytes(), offset)
    for offset in range(0, 6 * 24, 24)
]
if discriminator_marks[0] != (0, 8, 3):
    fail(f"payload.variant_discr first mark differs from (0, 8, 3): {discriminator_marks[0]}")
discriminator = decode_first_clickhouse_frame(part.joinpath(f"{discriminator_stem}.bin"))
expected_mode = 1 if profile == "compact" else 0
if len(discriminator) < 8 or struct.unpack_from("<Q", discriminator)[0] != expected_mode:
    fail(f"payload.variant_discr does not encode {profile.upper()} mode {expected_mode}")

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
printf 'stock W57 %s fixture verified: canonical Variant streams, six LZ4 streams, mark rows [3, 3, 3, 3, 1]\n' "$PROFILE"
