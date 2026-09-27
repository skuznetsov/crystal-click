#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
FIXTURE="$ROOT/test/fixtures/public/wide_array_integer128_256"

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
plain = [("a_i128", "Int128"), ("a_u128", "UInt128"), ("a_i256", "Int256"), ("a_u256", "UInt256")]
nullable = [("n_i128", "Int128"), ("n_u128", "UInt128"), ("n_i256", "Int256"), ("n_u256", "UInt256")]

def fail(message):
    raise SystemExit(f"wide integer Array fixture shape error: {message}")

if any(path.is_symlink() for path in root.rglob("*")):
    fail("fixture contains a symlink")
entries = list(root.iterdir())
if any(not path.is_file() for path in entries):
    fail("part directory contains a nested directory or non-regular entry")
if root.joinpath("count.txt").read_bytes() != b"7":
    fail("unexpected row count")

expected_columns = ["columns format version: 1", "9 columns:", "`pk` UInt64"]
expected_columns.extend(f"`{name}` Array({kind})" for name, kind in plain)
expected_columns.extend(f"`{name}` Array(Nullable({kind}))" for name, kind in nullable)
if root.joinpath("columns.txt").read_text().splitlines() != expected_columns:
    fail("columns.txt differs from the exact nine-column schema")

expected_streams = ["columns substreams version: 1", "9 columns:", "1 substreams for column `pk`:", "\tpk"]
for name, _ in plain:
    expected_streams.extend((f"2 substreams for column `{name}`:", f"\t{name}.size0", f"\t{name}"))
for name, _ in nullable:
    expected_streams.extend((f"3 substreams for column `{name}`:", f"\t{name}.size0", f"\t{name}.null", f"\t{name}"))
if root.joinpath("columns_substreams.txt").read_text().splitlines() != expected_streams:
    fail("columns_substreams.txt differs from the exact Array streams")
if root.joinpath("default_compression_codec.txt").read_bytes() != b"CODEC(LZ4)":
    fail("unexpected default compression codec")
if root.joinpath("serialization.json").read_text() != '{"columns":[],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1}':
    fail("unexpected serialization profile")

files = {path.name for path in entries}
if len(list(root.glob("*.bin"))) != 21 or len(list(root.glob("*.mrk2"))) != 21:
    fail("expected one key stream, two streams per plain Array, and three per nullable Array")
if any(root.glob("*.cmrk*")) or any(root.glob("*.mrk")) or any(root.glob("*.mrk3")):
    fail("fixture must use plain .mrk2 marks")
metadata = {"checksums.txt", "columns.txt", "columns_substreams.txt", "count.txt", "default_compression_codec.txt", "metadata_version.txt", "primary.cidx", "serialization.json"}
if not metadata.issubset(files) or len(files) != 50:
    fail("unexpected Wide part file inventory")
for path in root.glob("*.mrk2"):
    raw = path.read_bytes()
    if len(raw) != 5 * 24:
        fail(f"{path.name} does not have four data marks plus EOF sentinel")
    rows = [struct.unpack_from("<QQQ", raw, offset)[2] for offset in range(0, len(raw), 24)]
    if rows != [2, 2, 2, 1, 0]:
        fail(f"{path.name} has unexpected rows-per-mark: {rows}")
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
    raise SystemExit("wide integer Array fixture manifest does not list exactly the part files")
PY
fi

printf 'stock wide integer Array fixture shape verified: 8 types, 21 streams, mark rows [2, 2, 2, 1]\n'
