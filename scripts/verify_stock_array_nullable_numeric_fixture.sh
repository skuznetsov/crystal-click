#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
FIXTURE="$ROOT/test/fixtures/public/wide_array_nullable_numeric"

if [[ "${1:-}" == "--part-only" && "$#" -eq 2 ]]; then
  PART="$2"
  VERIFY_HASHES=0
elif [[ "$#" -eq 0 ]]; then
  PART="$FIXTURE/part"
  VERIFY_HASHES=1
else
  printf 'usage: %s [--part-only part-directory]\n' "$0" >&2
  exit 2
fi

if [[ ! -d "$PART" || -L "$PART" ]]; then
  printf 'fixture part directory not found: %s\n' "$PART" >&2
  exit 1
fi

python3 - "$PART" <<'PY'
from pathlib import Path
import struct
import sys

root = Path(sys.argv[1])
types = [
    ("arr_u8", "UInt8"),
    ("arr_u16", "UInt16"),
    ("arr_u32", "UInt32"),
    ("arr_u64", "UInt64"),
    ("arr_i8", "Int8"),
    ("arr_i16", "Int16"),
    ("arr_i32", "Int32"),
    ("arr_i64", "Int64"),
    ("arr_f32", "Float32"),
    ("arr_f64", "Float64"),
]

def fail(message):
    raise SystemExit(f"array-nullable-numeric fixture shape error: {message}")

if root.is_symlink() or any(path.is_symlink() for path in root.rglob("*")):
    fail("fixture contains a symlink")
entries = list(root.iterdir())
if any(not path.is_file() for path in entries):
    fail("part directory contains a nested directory or non-regular entry")
if root.joinpath("count.txt").read_bytes() != b"11":
    fail("unexpected row count")
expected_columns = ["columns format version: 1", "11 columns:", "`pk` UInt64"]
expected_columns.extend(f"`{name}` Array(Nullable({kind}))" for name, kind in types)
if root.joinpath("columns.txt").read_text().splitlines() != expected_columns:
    fail("columns.txt differs from the exact eleven-column schema")
expected_streams = ["columns substreams version: 1", "11 columns:", "1 substreams for column `pk`:", "\tpk"]
for name, _kind in types:
    expected_streams.extend((
        f"3 substreams for column `{name}`:",
        f"\t{name}.size0",
        f"\t{name}.null",
        f"\t{name}",
    ))
if root.joinpath("columns_substreams.txt").read_text().splitlines() != expected_streams:
    fail("columns_substreams.txt differs from size0/null/value streams for all leaves")
if root.joinpath("default_compression_codec.txt").read_bytes() != b"CODEC(LZ4)":
    fail("unexpected default compression codec")

files = {path.name for path in entries}
required = {
    "checksums.txt", "columns.txt", "columns_substreams.txt", "count.txt",
    "default_compression_codec.txt", "metadata_version.txt", "primary.cidx", "serialization.json",
}
if not required.issubset(files):
    fail("missing required Wide part metadata")
if len(list(root.glob("*.bin"))) != 31 or len(list(root.glob("*.mrk2"))) != 31:
    fail("expected one key stream and three streams per nullable numeric Array")
if any(root.glob("*.cmrk*")) or any(root.glob("*.mrk")) or any(root.glob("*.mrk3")):
    fail("fixture must use plain .mrk2 marks")

row_sequences = []
for path in root.glob("*.mrk2"):
    raw = path.read_bytes()
    if not raw or len(raw) % 24:
        fail(f"{path.name} has a truncated mark record")
    records = [struct.unpack_from("<QQQ", raw, offset) for offset in range(0, len(raw), 24)]
    if len(records) != 7 or records[-1][2] != 0 or any(record[2] == 0 for record in records[:-1]):
        fail(f"{path.name} does not contain six data marks and one EOF sentinel")
    rows = [record[2] for record in records[:-1]]
    if rows != [2, 2, 2, 2, 2, 1] or sum(rows) != 11:
        fail(f"{path.name} has unexpected rows-per-mark: {rows}")
    row_sequences.append(rows)
if len(row_sequences) != 31:
    fail("not all 31 physical streams have mark files")
PY

if [[ "$VERIFY_HASHES" -eq 1 ]]; then
  [[ -f "$FIXTURE/PROVENANCE.md" && ! -L "$FIXTURE/PROVENANCE.md" ]] || {
    printf 'fixture provenance is missing\n' >&2
    exit 1
  }
  [[ -f "$FIXTURE/SHA256SUMS" && ! -L "$FIXTURE/SHA256SUMS" ]] || {
    printf 'fixture SHA256SUMS is missing\n' >&2
    exit 1
  }
  (cd "$FIXTURE" && shasum -a 256 -c SHA256SUMS >/dev/null)
  python3 - "$FIXTURE" <<'PY'
from pathlib import Path
import sys

fixture = Path(sys.argv[1])
expected = sorted(str(path.relative_to(fixture)) for path in (fixture / "part").rglob("*") if path.is_file())
listed = sorted(line.split(None, 1)[1].lstrip("* ") for line in (fixture / "SHA256SUMS").read_text().splitlines())
if listed != expected:
    raise SystemExit("array-nullable-numeric fixture manifest does not list exactly the part files")
PY
fi

printf 'stock Array(Nullable(numeric)) fixture shape verified: 10 leaf types, 31 streams, mark rows [2, 2, 2, 2, 2, 1]\n'
