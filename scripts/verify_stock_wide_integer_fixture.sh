#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/Users/sergey/.local/bin/clickhouse}"
FIXTURE="${1:-$ROOT/test/fixtures/public/wide_integer128}"
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
    raise SystemExit(f"Wide integer fixture verification failed: {message}")

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
    tick+"signed"+tick+" Int128", tick+"unsigned"+tick+" UInt128",
]
if (part/"columns.txt").read_text().splitlines() != expected_columns:
    fail("columns.txt differs from the exact raw scalar schema")
expected_substreams = [
    "columns substreams version: 1", "3 columns:",
    "1 substreams for column "+tick+"pk"+tick+":", "\tpk",
    "1 substreams for column "+tick+"signed"+tick+":", "\tsigned",
    "1 substreams for column "+tick+"unsigned"+tick+":", "\tunsigned",
]
if (part/"columns_substreams.txt").read_text().splitlines() != expected_substreams:
    fail("columns_substreams.txt differs")
expected_serialization = (
    b'{"columns":[{"kind":"Default","name":"pk","num_defaults":0,"num_rows":13},'
    b'{"kind":"Default","name":"signed","num_defaults":1,"num_rows":13},'
    b'{"kind":"Default","name":"unsigned","num_defaults":1,"num_rows":13}],'
    b'"propagate_types_serialization_versions_to_nested_types":true,'
    b'"types_serialization_versions":{"string":1},"version":1}'
)
if (part/"serialization.json").read_bytes() != expected_serialization:
    fail("serialization.json differs from the pinned stock part")
if (part/"default_compression_codec.txt").read_bytes() != b"CODEC(LZ4)":
    fail("unexpected compression codec")
if (part/"metadata_version.txt").read_bytes() != b"0":
    fail("unexpected metadata version")
if (part/"count.txt").read_bytes() != b"13":
    fail("unexpected row count")

streams = {"pk": 8, "signed": 16, "unsigned": 16}
metadata = {
    "checksums.txt", "columns.txt", "columns_substreams.txt", "count.txt",
    "default_compression_codec.txt", "metadata_version.txt", "primary.cidx", "serialization.json",
}
expected_files = metadata | {f"{stream_hash(name)}.{ext}" for name in streams for ext in ("bin", "mrk2")}
if {path.name for path in part.iterdir()} != expected_files:
    fail("part file inventory differs from the three plain data streams and marks")
if any(path.suffix == ".cmrk2" for path in part.iterdir()):
    fail("part unexpectedly uses compressed marks")

keys = [1, 2, 4, 6, 9, 11, 13, 17, 19, 21, 25, 31, 40]
signed = [
    -170141183460469231731687303715884105728,
    -9223372036854775809,
    -18446744073709551617,
    -1,
    0,
    1,
    18446744073709551615,
    18446744073709551616,
    -170141183460469231731687303715884105727,
    170141183460469231731687303715884105726,
    12345678901234567890123456789012345678,
    -12345678901234567890123456789012345678,
    170141183460469231731687303715884105727,
]
unsigned = [
    0, 1, 18446744073709551615, 18446744073709551616, 18446744073709551617,
    170141183460469231731687303715884105727,
    170141183460469231731687303715884105728,
    340282366920938463463374607431768211455,
    340282366920938463463374607431768211454,
    12345678901234567890123456789012345678,
    18446744073709551616, 295147905179352825856, 42,
]
expected_raw = {
    "pk": b"".join(struct.pack("<Q", value) for value in keys),
    "signed": b"".join(value.to_bytes(16, "little", signed=True) for value in signed),
    "unsigned": b"".join(value.to_bytes(16, "little", signed=False) for value in unsigned),
}
row_counts = [2, 2, 2, 2, 2, 2, 1, 0]
for name, width in streams.items():
    path = part / f"{stream_hash(name)}.mrk2"
    raw_marks = path.read_bytes()
    expected_offsets = [min(index * 2, len(keys)) * width for index in range(len(row_counts))]
    expected_marks = [(0, offset, count) for offset, count in zip(expected_offsets, row_counts)]
    if len(raw_marks) != len(row_counts) * 24:
        fail(f"{name} marks must contain seven data marks and one sentinel")
    observed_marks = [struct.unpack_from("<QQQ", raw_marks, offset) for offset in range(0, len(raw_marks), 24)]
    if observed_marks != expected_marks:
        fail(f"{name} marks differ: {observed_marks!r}")
    actual = decode(part / f"{stream_hash(name)}.bin")
    if actual != expected_raw[name]:
        fail(f"{name} little-endian bytes differ")

listed = sorted(line.split(None, 1)[1].lstrip("* ") for line in (fixture/"SHA256SUMS").read_text().splitlines())
actual = sorted(str(path.relative_to(fixture)) for path in part.rglob("*") if path.is_file())
if listed != actual:
    fail("SHA256SUMS does not list exactly the stock part files")
PY

printf 'stock raw Int128/UInt128 fixture verified: exact schema, LZ4 streams, 24-byte marks/sentinel, and SHA256 manifest\n'
