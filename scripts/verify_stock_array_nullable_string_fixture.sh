#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
FIXTURE="$ROOT/test/fixtures/public/wide_array_nullable_string"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/Users/sergey/.local/bin/clickhouse}"
if [[ "${1:-}" == "--part-only" && "$#" -eq 2 ]]; then
  PART="$2"; VERIFY_HASHES=0
elif [[ "$#" -eq 0 ]]; then
  PART="$FIXTURE/part"; VERIFY_HASHES=1
else
  printf 'usage: %s [--part-only part-directory]\n' "$0" >&2
  exit 2
fi
if [[ ! -d "$PART" || -L "$PART" ]]; then
  printf 'fixture part directory not found: %s\n' "$PART" >&2
  exit 1
fi

CLICKHOUSE_BIN="$CLICKHOUSE_BIN" python3 - "$PART" <<'PY'
from pathlib import Path
import os, struct, subprocess, sys
root = Path(sys.argv[1])
tick = chr(96)

def fail(message):
    raise SystemExit(f"array-nullable-string fixture shape error: {message}")

def rotl(value, count):
    mask = (1 << 64) - 1
    return ((value << count) | (value >> (64 - count))) & mask

def stream_hash(name):
    mask = (1 << 64) - 1
    v0, v1, v2, v3 = (0x736f6d6570736575, 0x646f72616e646f6d, 0x6c7967656e657261, 0x7465646279746573)
    raw, index = name.encode(), 0
    def rnd(v0, v1, v2, v3):
        v0=(v0+v1)&mask; v1=rotl(v1,13)^v0; v0=rotl(v0,32)
        v2=(v2+v3)&mask; v3=rotl(v3,16)^v2
        v0=(v0+v3)&mask; v3=rotl(v3,21)^v0
        v2=(v2+v1)&mask; v1=rotl(v1,17)^v2; v2=rotl(v2,32)
        return v0,v1,v2,v3
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

def u64s(values):
    return b"".join(struct.pack("<Q", value) for value in values)

def decode_frame(path):
    result = subprocess.run([os.environ["CLICKHOUSE_BIN"], "compressor", "--decompress"],
                            input=path.read_bytes(), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode: fail(f"cannot decompress {path.name}: {result.stderr.decode(errors='replace')}")
    return result.stdout

if root.is_symlink() or any(path.is_symlink() for path in root.rglob("*")):
    fail("fixture contains a symlink")
entries = list(root.iterdir())
if any(not path.is_file() for path in entries): fail("part contains non-regular entries")
if root.joinpath("columns.txt").read_text().splitlines() != [
    "columns format version: 1", "2 columns:", tick+"pk"+tick+" UInt64", tick+"a"+tick+" Array(Nullable(String))",
]: fail("columns.txt differs from exact two-column schema")
if root.joinpath("columns_substreams.txt").read_text().splitlines() != [
    "columns substreams version: 1", "2 columns:", "1 substreams for column "+tick+"pk"+tick+":", "\tpk",
    "4 substreams for column "+tick+"a"+tick+":", "\ta.size0", "\ta.null", "\ta.size", "\ta",
]: fail("columns_substreams.txt differs from size0/null/size/value streams")
if root.joinpath("serialization.json").read_bytes() != b'{"columns":[],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1}':
    fail("serialization.json differs from pinned metadata")
if root.joinpath("default_compression_codec.txt").read_bytes() != b"CODEC(LZ4)": fail("unexpected codec")
if root.joinpath("metadata_version.txt").read_bytes() != b"0": fail("unexpected metadata version")
if root.joinpath("count.txt").read_bytes() != b"11": fail("unexpected row count")

metadata = {"checksums.txt","columns.txt","columns_substreams.txt","count.txt","default_compression_codec.txt","metadata_version.txt","primary.cidx","serialization.json"}
streams = ["pk","a.size0","a.null","a.size","a"]
expected_files = metadata | {f"{stream_hash(name)}.{ext}" for name in streams for ext in ("bin","mrk2")}
if {path.name for path in entries} != expected_files: fail("unexpected physical file inventory")
rows = [2,2,2,2,2,1,0]
offsets = {
    "pk":[0,16,32,48,64,80,88], "a.size0":[0,16,32,48,64,80,88],
    "a.null":[0,0,5,8,8,11,13], "a.size":[0,0,40,64,64,88,104],
    "a":[0,0,5,5,5,5,13],
}
for stream in streams:
    path = root / f"{stream_hash(stream)}.mrk2"
    raw = path.read_bytes()
    if len(raw) != 7*24: fail(f"{path.name} lacks six marks plus sentinel")
    marks = [struct.unpack_from("<QQQ",raw,n) for n in range(0,len(raw),24)]
    if [m[0] for m in marks] != [0]*7: fail(f"{path.name} compressed offsets differ")
    if [m[1] for m in marks] != offsets[stream]: fail(f"{path.name} decompressed offsets differ")
    if [m[2] for m in marks] != rows: fail(f"{path.name} row counts differ")

expected = {
    "pk":u64s([1,2,4,6,9,11,13,17,19,21,25]),
    "a.size0":u64s([0,0,3,2,2,1,0,0,2,1,2]),
    "a.null":bytes([1,0,0,0,0,1,1,1,0,0,0,0,0]),
    "a.size":u64s([0,0,3,0,2,0,0,0,0,0,0,2,6]),
    "a":b"a\x00bB\xff\xc3\xa9tail\x00x",
}
for stream, wanted in expected.items():
    path = root / f"{stream_hash(stream)}.bin"
    actual = decode_frame(path)
    if actual != wanted: fail(f"{stream} raw bytes differ: expected {wanted.hex()} got {actual.hex()}")
PY

if [[ "$VERIFY_HASHES" -eq 1 ]]; then
  [[ -f "$FIXTURE/PROVENANCE.md" && ! -L "$FIXTURE/PROVENANCE.md" ]] || { printf 'fixture provenance is missing\n' >&2; exit 1; }
  [[ -f "$FIXTURE/SHA256SUMS" && ! -L "$FIXTURE/SHA256SUMS" ]] || { printf 'fixture SHA256SUMS is missing\n' >&2; exit 1; }
  (cd "$FIXTURE" && shasum -a 256 -c SHA256SUMS >/dev/null)
  python3 - "$FIXTURE" <<'PY'
from pathlib import Path
import sys
fixture=Path(sys.argv[1])
expected=sorted(str(p.relative_to(fixture)) for p in (fixture/"part").rglob("*") if p.is_file())
listed=sorted(line.split(None,1)[1].lstrip("* ") for line in (fixture/"SHA256SUMS").read_text().splitlines())
if listed != expected: raise SystemExit("manifest does not list exactly the part files")
PY
fi
printf 'stock Array(Nullable(String)) fixture verified: exact streams, NULL slots, raw bytes, and MRK2 offsets\n'
