#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/Users/sergey/.local/bin/clickhouse}"
FIXTURE="${1:-$ROOT/test/fixtures/public/wide_nullable_integer128}"
EXPECTED_VERSION='ClickHouse local version 26.7.1.1315 (official build).'

if [[ "$#" -gt 1 ]]; then
  printf 'usage: %s [fixture-directory]\n' "$0" >&2
  exit 2
fi
if [[ ! -x "$CLICKHOUSE_BIN" ]]; then
  printf 'ClickHouse executable not found: %s\n' "$CLICKHOUSE_BIN" >&2
  exit 1
fi
ACTUAL_VERSION="$("$CLICKHOUSE_BIN" local --version)"
if [[ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]]; then
  printf 'fixture verifier requires %s, got %s\n' "$EXPECTED_VERSION" "$ACTUAL_VERSION" >&2
  exit 1
fi
for path in "$FIXTURE/part" "$FIXTURE/sparse/part" "$FIXTURE/PROVENANCE.md" "$FIXTURE/SHA256SUMS"; do
  [[ -e "$path" && ! -L "$path" ]] || { printf 'fixture path missing or a symlink: %s\n' "$path" >&2; exit 1; }
done
(cd "$FIXTURE" && shasum -a 256 -c SHA256SUMS >/dev/null)

CLICKHOUSE_BIN="$CLICKHOUSE_BIN" python3 - "$FIXTURE" <<'PY'
from pathlib import Path
import json, os, struct, subprocess, sys

fixture = Path(sys.argv[1])
part = fixture / "part"
sparse = fixture / "sparse" / "part"
tick = chr(96)

def fail(message):
    raise SystemExit(f"Nullable Wide integer fixture verification failed: {message}")

def rotl(value, count):
    mask = (1 << 64) - 1
    return ((value << count) | (value >> (64 - count))) & mask

def stream_hash(name):
    mask = (1 << 64) - 1
    v0, v1, v2, v3 = (0x736f6d6570736575, 0x646f72616e646f6d, 0x6c7967656e657261, 0x7465646279746573)
    raw, index = name.encode(), 0
    def rnd(a, b, c, d):
        a=(a+b)&mask; b=rotl(b,13)^a; a=rotl(a,32)
        c=(c+d)&mask; d=rotl(d,16)^c
        a=(a+d)&mask; d=rotl(d,21)^a
        c=(c+b)&mask; b=rotl(b,17)^c; c=rotl(c,32)
        return a,b,c,d
    while index + 8 <= len(raw):
        word = int.from_bytes(raw[index:index+8], "little")
        v3 ^= word
        for _ in range(2): v0,v1,v2,v3 = rnd(v0,v1,v2,v3)
        v0 ^= word; index += 8
    word = len(raw) << 56
    for offset, byte in enumerate(raw[index:]): word |= byte << (offset*8)
    v3 ^= word
    for _ in range(2): v0,v1,v2,v3 = rnd(v0,v1,v2,v3)
    v0 ^= word; v2 ^= 0xff
    for _ in range(4): v0,v1,v2,v3 = rnd(v0,v1,v2,v3)
    return f"{(v2^v3):016x}{(v0^v1):016x}"

def decode(path):
    result = subprocess.run(
        [os.environ["CLICKHOUSE_BIN"], "compressor", "--decompress"],
        input=path.read_bytes(), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    if result.returncode:
        fail(f"cannot decode {path.name}: {result.stderr.decode(errors='replace')}")
    return result.stdout

def assert_tree(root):
    if root.is_symlink() or any(path.is_symlink() for path in root.rglob("*")):
        fail(f"symlink in {root.relative_to(fixture)}")
    if any(not path.is_file() for path in root.iterdir()):
        fail(f"non-file direct entry in {root.relative_to(fixture)}")

assert_tree(part)
assert_tree(sparse)
expected_columns = [
    "columns format version: 1", "3 columns:", tick+"pk"+tick+" UInt64",
    tick+"signed"+tick+" Nullable(Int128)", tick+"unsigned"+tick+" Nullable(UInt128)",
]
if (part/"columns.txt").read_text().splitlines() != expected_columns:
    fail("BASIC columns.txt differs from exact raw Nullable schema")
expected_substreams = [
    "columns substreams version: 1", "3 columns:",
    "1 substreams for column "+tick+"pk"+tick+":", "\tpk",
    "2 substreams for column "+tick+"signed"+tick+":", "\tsigned.null", "\tsigned",
    "2 substreams for column "+tick+"unsigned"+tick+":", "\tunsigned.null", "\tunsigned",
]
if (part/"columns_substreams.txt").read_text().splitlines() != expected_substreams:
    fail("BASIC columns_substreams.txt differs")
expected_serialization = (
    b'{"columns":[],"propagate_types_serialization_versions_to_nested_types":true,'
    b'"types_serialization_versions":{"string":1},"version":1}'
)
if (part/"serialization.json").read_bytes() != expected_serialization:
    fail("BASIC serialization.json differs")
if (part/"default_compression_codec.txt").read_bytes() != b"CODEC(LZ4)":
    fail("unexpected BASIC codec")
if (part/"metadata_version.txt").read_bytes() != b"0" or (part/"count.txt").read_bytes() != b"32":
    fail("BASIC metadata version or row count differs")

metadata = {
    "checksums.txt", "columns.txt", "columns_substreams.txt", "count.txt",
    "default_compression_codec.txt", "metadata_version.txt", "primary.cidx", "serialization.json",
}
basic_streams = ["pk", "signed.null", "signed", "unsigned.null", "unsigned"]
expected_basic = metadata | {f"{stream_hash(name)}.{ext}" for name in basic_streams for ext in ("bin", "mrk2")}
if {path.name for path in part.iterdir()} != expected_basic:
    fail("BASIC part file inventory differs")
if any(path.suffix == ".cmrk2" for path in part.iterdir()):
    fail("BASIC part unexpectedly uses compressed marks")

nulls = {
    "signed.null": [1 if row in {1,4,9,14,17,21,26,29,32} else 0 for row in range(1,33)],
    "unsigned.null": [1 if row in {1,4,9,14,17,21,29,32} else 0 for row in range(1,33)],
}
for name, width in {"pk":8, "signed.null":1, "signed":16, "unsigned.null":1, "unsigned":16}.items():
    mark_path = part / f"{stream_hash(name)}.mrk2"
    raw_marks = mark_path.read_bytes()
    if len(raw_marks) != 9 * 24:
        fail(f"{name} must contain eight marks and one sentinel")
    marks = [struct.unpack_from("<QQQ", raw_marks, i*24) for i in range(9)]
    expected = [(0, row*width, 4 if row < 32 else 0) for row in range(0, 36, 4)]
    if marks != expected:
        fail(f"{name} mark offsets/counts differ: {marks!r}")
    decoded = decode(part / f"{stream_hash(name)}.bin")
    wanted = width * 32
    if len(decoded) != wanted:
        fail(f"{name} decoded to {len(decoded)} bytes, expected {wanted}")
    if name in nulls and list(decoded) != nulls[name]:
        fail(f"{name} has unexpected null-map bytes")
for value_name, map_name in (("signed", "signed.null"), ("unsigned", "unsigned.null")):
    values = decode(part / f"{stream_hash(value_name)}.bin")
    for row, is_null in enumerate(nulls[map_name]):
        if is_null and values[row*16:(row+1)*16] != bytes(16):
            fail(f"{value_name} NULL slot {row} is not zero-filled")

sparse_json = json.loads((sparse/"serialization.json").read_text())
if sparse_json.get("types_serialization_versions", {}).get("nullable") != 1:
    fail("Sparse control lacks nullable serialization version 1")
records = {record.get("name"): record for record in sparse_json.get("columns", [])}
if set(records) != {"pk", "signed", "unsigned"}:
    fail("Sparse control serializer record names differ")
if records["pk"].get("kind") != "Default" or any(records[name].get("kind") != "Sparse" for name in ("signed", "unsigned")):
    fail("Sparse control does not have exact Default key and Sparse nullable records")
if records["signed"].get("num_defaults") != 30 or records["unsigned"].get("num_defaults") != 30:
    fail("Sparse control NULL/default counts differ")
if (sparse/"columns_substreams.txt").read_text().splitlines() != [
    "columns substreams version: 1", "3 columns:",
    "1 substreams for column "+tick+"pk"+tick+":", "\tpk",
    "2 substreams for column "+tick+"signed"+tick+":", "\tsigned.sparse.idx", "\tsigned",
    "2 substreams for column "+tick+"unsigned"+tick+":", "\tunsigned.sparse.idx", "\tunsigned",
]:
    fail("Sparse control substream layout differs")
for logical in ("signed.sparse.idx", "signed", "unsigned.sparse.idx", "unsigned"):
    if not (sparse/f"{stream_hash(logical)}.bin").is_file():
        fail(f"Sparse stream is missing: {logical}")
if any(".null" in path.name for path in sparse.glob("*.bin")):
    fail("Sparse control unexpectedly has BASIC null-map files")

listed = sorted(line.split(None, 1)[1].lstrip("* ") for line in (fixture/"SHA256SUMS").read_text().splitlines())
actual = sorted(str(path.relative_to(fixture)) for base in (part, sparse) for path in base.rglob("*") if path.is_file())
if listed != actual:
    fail("SHA256SUMS does not cover exactly both stock part trees")
PY

printf 'stock Nullable(Int128)/Nullable(UInt128) fixtures verified: BASIC null/value streams and marks, Sparse negative control, pinned provenance and SHA256 manifest\n'
