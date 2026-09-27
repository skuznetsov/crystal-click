#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
FIXTURE="$ROOT/test/fixtures/public/wide_array_uuid_w41"
PART="$FIXTURE/part"

[[ -d "$PART" && ! -L "$PART" ]] || { printf 'UUID Array fixture part missing or symlinked\n' >&2; exit 1; }
[[ -f "$FIXTURE/PROVENANCE.md" && ! -L "$FIXTURE/PROVENANCE.md" ]] || { printf 'UUID Array fixture provenance missing\n' >&2; exit 1; }
[[ -f "$FIXTURE/SHA256SUMS" && ! -L "$FIXTURE/SHA256SUMS" ]] || { printf 'UUID Array fixture checksums missing\n' >&2; exit 1; }

python3 - "$PART" "$FIXTURE" <<'PY'
from pathlib import Path
import struct
import sys

part = Path(sys.argv[1])
fixture = Path(sys.argv[2])

def fail(message):
    raise SystemExit(f"UUID Array fixture shape error: {message}")

if any(path.is_symlink() for path in part.rglob("*")):
    fail("part contains a symlink")
entries = list(part.iterdir())
if any(not path.is_file() for path in entries):
    fail("part contains a nested directory or non-regular entry")

expected_streams = {
    "27c15c8839f2ca471418ccedc41a69d1",
    "4c6e5d2c4d23db0c9ac8179b7139ddfa",
    "b7ce9c84d550d03beef21f11a8335ffc",
    "e5ebf9b2a6c547bd921080eef0d17c2e",
    "ee32d58e143f5573f00a2f8a4d7c036a",
    "fcc8daf1be9ac27649fa2186ad926aea",
}
metadata = {
    "checksums.txt", "columns.txt", "columns_substreams.txt", "count.txt",
    "default_compression_codec.txt", "metadata_version.txt", "primary.cidx", "serialization.json",
}
expected_files = metadata | {f"{stream}.{suffix}" for stream in expected_streams for suffix in ("bin", "mrk2")}
if {path.name for path in entries} != expected_files:
    fail("part file inventory differs from six expected streams and eight metadata files")
if part.joinpath("count.txt").read_bytes() != b"7":
    fail("unexpected row count")
if part.joinpath("metadata_version.txt").read_bytes() != b"0":
    fail("unexpected metadata version")
if part.joinpath("default_compression_codec.txt").read_bytes() != b"CODEC(LZ4)":
    fail("unexpected default compression codec")
if part.joinpath("columns.txt").read_text().splitlines() != [
    "columns format version: 1", "3 columns:", "`pk` UInt64", "`plain` Array(UUID)", "`maybe` Array(Nullable(UUID))",
]:
    fail("columns.txt differs from exact three-column UUID Array schema")
if part.joinpath("columns_substreams.txt").read_text().splitlines() != [
    "columns substreams version: 1", "3 columns:", "1 substreams for column `pk`:", "\tpk",
    "2 substreams for column `plain`:", "\tplain.size0", "\tplain",
    "3 substreams for column `maybe`:", "\tmaybe.size0", "\tmaybe.null", "\tmaybe",
]:
    fail("columns_substreams.txt differs from exact UUID Array stream topology")
if part.joinpath("serialization.json").read_text() != (
    '{"columns":[],"propagate_types_serialization_versions_to_nested_types":true,'
    '"types_serialization_versions":{"string":1},"version":1}'
):
    fail("serialization.json differs from the pinned BASIC UUID profile")
if len(list(part.glob("*.bin"))) != 6 or len(list(part.glob("*.mrk2"))) != 6:
    fail("expected six LZ4 data streams and six plain adaptive .mrk2 files")
if any(part.glob("*.cmrk*")) or any(part.glob("*.mrk")) or any(part.glob("*.mrk3")):
    fail("fixture must use plain .mrk2 marks")
for path in part.glob("*.mrk2"):
    raw = path.read_bytes()
    if len(raw) != 5 * 24:
        fail(f"{path.name} does not contain four marks and EOF sentinel")
    row_counts = [struct.unpack_from("<QQQ", raw, offset)[2] for offset in range(0, len(raw), 24)]
    if row_counts != [2, 2, 2, 1, 0]:
        fail(f"{path.name} has unexpected rows-per-mark: {row_counts}")

expected_hash_paths = sorted(str(path.relative_to(fixture)) for path in part.rglob("*") if path.is_file())
listed_hash_paths = sorted(line.split(None, 1)[1].lstrip("* ") for line in fixture.joinpath("SHA256SUMS").read_text().splitlines())
if listed_hash_paths != expected_hash_paths:
    fail("SHA256SUMS does not list exactly the part files")
PY

(cd "$FIXTURE" && shasum -a 256 -c SHA256SUMS >/dev/null)
printf 'stock UUID Array fixture shape verified: 2 declarations, 6 streams, mark rows [2, 2, 2, 1]\n'
