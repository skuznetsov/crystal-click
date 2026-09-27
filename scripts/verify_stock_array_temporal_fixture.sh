#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
FIXTURE="$ROOT/test/fixtures/public/wide_array_temporal"
PART="$FIXTURE/part"

if [[ ! -d "$PART" || -L "$PART" ]]; then
  printf 'temporal Array fixture part directory missing or symlinked\n' >&2
  exit 1
fi
[[ -f "$FIXTURE/PROVENANCE.md" && ! -L "$FIXTURE/PROVENANCE.md" ]] || {
  printf 'temporal Array fixture provenance is missing\n' >&2
  exit 1
}
[[ -f "$FIXTURE/SHA256SUMS" && ! -L "$FIXTURE/SHA256SUMS" ]] || {
  printf 'temporal Array fixture SHA256SUMS is missing\n' >&2
  exit 1
}

python3 - "$PART" "$FIXTURE" <<'PY'
from pathlib import Path
import struct
import sys

part = Path(sys.argv[1])
fixture = Path(sys.argv[2])
plain = [
    ("a_date", "Date"),
    ("a_date32", "Date32"),
    ("a_datetime", "DateTime"),
    ("a_datetime64", "DateTime64(3)"),
]
nullable = [
    ("n_date", "Date"),
    ("n_date32", "Date32"),
    ("n_datetime", "DateTime"),
    ("n_datetime64", "DateTime64(3)"),
]

def fail(message):
    raise SystemExit(f"temporal Array fixture shape error: {message}")

if any(path.is_symlink() for path in part.rglob("*")):
    fail("part contains a symlink")
entries = list(part.iterdir())
if any(not path.is_file() for path in entries):
    fail("part contains a nested directory or non-regular entry")
if part.joinpath("count.txt").read_bytes() != b"7":
    fail("unexpected row count")

columns = ["columns format version: 1", "9 columns:", "`pk` UInt64"]
columns.extend(f"`{name}` Array({kind})" for name, kind in plain)
columns.extend(f"`{name}` Array(Nullable({kind}))" for name, kind in nullable)
if part.joinpath("columns.txt").read_text().splitlines() != columns:
    fail("columns.txt differs from the exact nine-column schema")

streams = [
    "columns substreams version: 1",
    "9 columns:",
    "1 substreams for column `pk`:",
    "\tpk",
]
for name, _ in plain:
    streams.extend((f"2 substreams for column `{name}`:", f"\t{name}.size0", f"\t{name}"))
for name, _ in nullable:
    streams.extend((f"3 substreams for column `{name}`:", f"\t{name}.size0", f"\t{name}.null", f"\t{name}"))
if part.joinpath("columns_substreams.txt").read_text().splitlines() != streams:
    fail("columns_substreams.txt differs from the exact temporal Array streams")
if part.joinpath("default_compression_codec.txt").read_bytes() != b"CODEC(LZ4)":
    fail("unexpected default compression codec")
if part.joinpath("serialization.json").read_text() != (
    '{"columns":[],"propagate_types_serialization_versions_to_nested_types":true,'
    '"types_serialization_versions":{"string":1},"version":1}'
):
    fail("unexpected serialization profile")

files = {path.name for path in entries}
metadata = {
    "checksums.txt", "columns.txt", "columns_substreams.txt", "count.txt",
    "default_compression_codec.txt", "metadata_version.txt", "primary.cidx",
    "serialization.json",
}
if not metadata.issubset(files) or len(files) != 50:
    fail("unexpected Wide part file inventory")
if len(list(part.glob("*.bin"))) != 21 or len(list(part.glob("*.mrk2"))) != 21:
    fail("expected 21 data streams and 21 plain adaptive .mrk2 mark files")
if any(part.glob("*.cmrk*")) or any(part.glob("*.mrk")) or any(part.glob("*.mrk3")):
    fail("fixture must use plain .mrk2 marks")
for path in part.glob("*.mrk2"):
    raw = path.read_bytes()
    if len(raw) != 5 * 24:
        fail(f"{path.name} does not have four marks plus the EOF sentinel")
    rows = [struct.unpack_from("<QQQ", raw, offset)[2] for offset in range(0, len(raw), 24)]
    if rows != [2, 2, 2, 1, 0]:
        fail(f"{path.name} has unexpected rows-per-mark: {rows}")

expected_hash_paths = sorted(str(path.relative_to(fixture)) for path in part.rglob("*") if path.is_file())
listed_hash_paths = sorted(
    line.split(None, 1)[1].lstrip("* ")
    for line in fixture.joinpath("SHA256SUMS").read_text().splitlines()
)
if listed_hash_paths != expected_hash_paths:
    fail("SHA256SUMS does not list exactly the part files")
PY

(cd "$FIXTURE" && shasum -a 256 -c SHA256SUMS >/dev/null)
printf 'stock temporal Array fixture shape verified: 8 types, 21 streams, mark rows [2, 2, 2, 1]\n'
