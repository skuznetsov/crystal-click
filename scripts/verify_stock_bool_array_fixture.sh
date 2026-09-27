#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/Users/sergey/.local/bin/clickhouse}"
EXPECTED_VERSION='ClickHouse local version 26.7.1.1315 (official build).'

if [[ "$#" -eq 0 ]]; then
  "$0" "$ROOT/test/fixtures/public/wide_array_bool"
  "$0" "$ROOT/test/fixtures/public/wide_array_bool_keyed"
  exit 0
elif [[ "$#" -gt 1 ]]; then
  printf 'usage: %s [fixture-directory]\n' "$0" >&2
  exit 2
fi
FIXTURE="$1"

if [[ ! -x "$CLICKHOUSE_BIN" ]]; then
  printf 'ClickHouse executable not found: %s\n' "$CLICKHOUSE_BIN" >&2
  exit 1
fi
ACTUAL_VERSION="$("$CLICKHOUSE_BIN" local --version)"
if [[ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]]; then
  printf 'fixture verifier requires %s, got %s\n' "$EXPECTED_VERSION" "$ACTUAL_VERSION" >&2
  exit 1
fi
[[ -d "$FIXTURE/part" && ! -L "$FIXTURE/part" ]] || { printf 'fixture part missing\n' >&2; exit 1; }
[[ -f "$FIXTURE/PROVENANCE.md" && ! -L "$FIXTURE/PROVENANCE.md" ]] || { printf 'fixture provenance missing\n' >&2; exit 1; }
[[ -f "$FIXTURE/SHA256SUMS" && ! -L "$FIXTURE/SHA256SUMS" ]] || { printf 'fixture SHA256SUMS missing\n' >&2; exit 1; }
(cd "$FIXTURE" && shasum -a 256 -c SHA256SUMS >/dev/null)

CLICKHOUSE_BIN="$CLICKHOUSE_BIN" python3 - "$FIXTURE" <<'PY'
from pathlib import Path
import os, struct, subprocess, sys

fixture = Path(sys.argv[1])
part = fixture / "part"
tick = chr(96)

def fail(message):
    raise SystemExit(f"Bool array fixture verification failed: {message}")

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

def decode(path):
    result = subprocess.run(
        [os.environ["CLICKHOUSE_BIN"], "compressor", "--decompress"],
        input=path.read_bytes(), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    if result.returncode:
        fail(f"cannot decode {path.name}: {result.stderr.decode(errors='replace')}")
    return result.stdout

if fixture.is_symlink() or part.is_symlink() or any(path.is_symlink() for path in fixture.rglob("*")):
    fail("fixture contains a symlink")
if any(not path.is_file() for path in part.iterdir()):
    fail("part contains a non-file entry")
expected_columns = [
    "columns format version: 1", "3 columns:", tick+"pk"+tick+" UInt64",
    tick+"plain"+tick+" Array(Bool)", tick+"maybe"+tick+" Array(Nullable(Bool))",
]
if (part/"columns.txt").read_text().splitlines() != expected_columns:
    fail("columns.txt differs from schema")
expected_substreams = [
    "columns substreams version: 1", "3 columns:", "1 substreams for column "+tick+"pk"+tick+":", "\tpk",
    "2 substreams for column "+tick+"plain"+tick+":", "\tplain.size0", "\tplain",
    "3 substreams for column "+tick+"maybe"+tick+":", "\tmaybe.size0", "\tmaybe.null", "\tmaybe",
]
if (part/"columns_substreams.txt").read_text().splitlines() != expected_substreams:
    fail("columns_substreams.txt differs")
serialization = (part/"serialization.json").read_bytes()
if fixture.name == "wide_array_bool":
    expected_serialization = b'{"columns":[],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1}'
elif fixture.name == "wide_array_bool_keyed":
    expected_serialization = b'{"columns":[{"kind":"Default","name":"pk","num_defaults":0,"num_rows":13}],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1}'
else:
    fail("fixture directory is not one of the two pinned stock variants")
if serialization != expected_serialization:
    fail("serialization.json differs from this fixture's exact stock variant")
if (part/"default_compression_codec.txt").read_bytes() != b"CODEC(LZ4)":
    fail("unexpected compression codec")
if (part/"metadata_version.txt").read_bytes() != b"0":
    fail("unexpected metadata version")
if (part/"count.txt").read_bytes() != b"13":
    fail("unexpected row count")

streams = ["pk", "plain.size0", "plain", "maybe.size0", "maybe.null", "maybe"]
metadata = {"checksums.txt", "columns.txt", "columns_substreams.txt", "count.txt", "default_compression_codec.txt", "metadata_version.txt", "primary.cidx", "serialization.json"}
expected_files = metadata | {f"{stream_hash(name)}.{ext}" for name in streams for ext in ("bin", "mrk2")}
if {path.name for path in part.iterdir()} != expected_files:
    fail("part file inventory differs from six expected streams")

mark_rows = [2, 2, 2, 2, 2, 2, 1, 0]
mark_offsets = {
    "pk": [0, 16, 32, 48, 64, 80, 96, 104],
    "plain.size0": [0, 16, 32, 48, 64, 80, 96, 104],
    "plain": [0, 2, 3, 6, 7, 9, 11, 13],
    "maybe.size0": [0, 16, 32, 48, 64, 80, 96, 104],
    "maybe.null": [0, 3, 6, 8, 11, 13, 15, 17],
    "maybe": [0, 3, 6, 8, 11, 13, 15, 17],
}
for name in streams:
    raw = (part / f"{stream_hash(name)}.mrk2").read_bytes()
    if len(raw) != len(mark_rows) * 24:
        fail(f"{name} marks must contain seven data marks and a sentinel")
    records = [struct.unpack_from("<QQQ", raw, offset) for offset in range(0, len(raw), 24)]
    if [row[0] for row in records] != [0] * len(mark_rows):
        fail(f"{name} compressed mark offsets differ")
    if [row[1] for row in records] != mark_offsets[name]:
        fail(f"{name} decompressed mark offsets differ")
    if [row[2] for row in records] != mark_rows:
        fail(f"{name} row-count marks differ")

keys = [1, 2, 4, 6, 9, 11, 13, 17, 19, 21, 25, 31, 40]
plain = [[], [0,1], [1], [], [0], [1,0], [], [1], [0,1], [], [0], [1], [0,0]]
nullable = [[], [None,0,1], [0,None], [1], [], [None,1], [0], [None,0], [], [0,None], [1], [None], [1,None]]
u64s = lambda values: b"".join(struct.pack("<Q", value) for value in values)
expected = {
    "pk": u64s(keys),
    "plain.size0": u64s([len(row) for row in plain]),
    "plain": bytes(value for row in plain for value in row),
    "maybe.size0": u64s([len(row) for row in nullable]),
    "maybe.null": bytes(1 if value is None else 0 for row in nullable for value in row),
    "maybe": bytes(0 if value is None else value for row in nullable for value in row),
}
for name, wanted in expected.items():
    actual = decode(part / f"{stream_hash(name)}.bin")
    if actual != wanted:
        fail(f"{name} raw bytes differ: expected {wanted.hex()} got {actual.hex()}")

listed = sorted(line.split(None, 1)[1].lstrip("* ") for line in (fixture/"SHA256SUMS").read_text().splitlines())
actual = sorted(str(path.relative_to(fixture)) for path in part.rglob("*") if path.is_file())
if listed != actual:
    fail("SHA256SUMS does not list exactly the stock part files")
PY

printf 'stock Bool array fixture verified: %s; exact streams, marks, binary bytes, NULL slots, and SHA256 manifest\n' "$(basename -- "$FIXTURE")"
