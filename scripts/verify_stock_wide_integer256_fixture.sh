#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/Users/sergey/.local/bin/clickhouse}"
FIXTURE="${1:-$ROOT/test/fixtures/public/wide_integer256}"
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
[[ -d "$FIXTURE" && ! -L "$FIXTURE" ]] || { printf 'fixture directory missing or a symlink: %s\n' "$FIXTURE" >&2; exit 1; }
for path in "$FIXTURE/part" "$FIXTURE/PROVENANCE.md" "$FIXTURE/SHA256SUMS"; do
  [[ -e "$path" && ! -L "$path" ]] || { printf 'fixture path missing or a symlink: %s\n' "$path" >&2; exit 1; }
done
(cd "$FIXTURE" && shasum -a 256 -c SHA256SUMS >/dev/null)

TMP_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/crystal-click-wide-integer256-verify.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT
CLICKHOUSE_BIN="$CLICKHOUSE_BIN" TMP_ROOT="$TMP_ROOT" python3 - "$FIXTURE" <<'PY'
from pathlib import Path
import json, os, shutil, struct, subprocess, sys

fixture = Path(sys.argv[1])
part = fixture / "part"
tick = chr(96)
clickhouse = os.environ["CLICKHOUSE_BIN"]
store = Path(os.environ["TMP_ROOT"]) / "store"

def fail(message):
    raise SystemExit(f"Wide Int256/UInt256 fixture verification failed: {message}")

def run_ch(query):
    result = subprocess.run(
        [clickhouse, "local", "--path", str(store), "--query", query],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    if result.returncode:
        fail(f"ClickHouse query failed: {result.stderr.decode(errors='replace')}")
    return result.stdout

def decode(path):
    result = subprocess.run(
        [clickhouse, "compressor", "--decompress"],
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
expected_columns = [
    "columns format version: 1", "3 columns:", tick+"pk"+tick+" UInt64",
    tick+"i"+tick+" Int256", tick+"u"+tick+" UInt256",
]
if (part/"columns.txt").read_text().splitlines() != expected_columns:
    fail("columns.txt differs from exact raw Int256/UInt256 schema")
if (part/"columns_substreams.txt").read_text().splitlines() != [
    "columns substreams version: 1", "3 columns:",
    "1 substreams for column "+tick+"pk"+tick+":", "\tpk",
    "1 substreams for column "+tick+"i"+tick+":", "\ti",
    "1 substreams for column "+tick+"u"+tick+":", "\tu",
]:
    fail("columns_substreams.txt differs from one raw value stream per column")
expected_serialization = (
    b'{"columns":[{"kind":"Default","name":"i","num_defaults":1,"num_rows":13},'
    b'{"kind":"Default","name":"pk","num_defaults":0,"num_rows":13},'
    b'{"kind":"Default","name":"u","num_defaults":2,"num_rows":13}],'
    b'"propagate_types_serialization_versions_to_nested_types":true,'
    b'"types_serialization_versions":{"string":1},"version":1}'
)
if (part/"serialization.json").read_bytes() != expected_serialization:
    fail("serialization.json differs from the pinned stock Default records")
if (part/"default_compression_codec.txt").read_bytes() != b"CODEC(LZ4)":
    fail("unexpected compression codec")
if (part/"metadata_version.txt").read_bytes() != b"0" or (part/"count.txt").read_bytes() != b"13":
    fail("metadata version or row count differs")

stream_hashes = {
    "pk": "fcc8daf1be9ac27649fa2186ad926aea",
    "i": "e48542285e2b02db625d5f9b9ec1b5d3",
    "u": "fa396ff91b8d36df3be72fd80cd08788",
}
metadata = {
    "checksums.txt", "columns.txt", "columns_substreams.txt", "count.txt",
    "default_compression_codec.txt", "metadata_version.txt", "primary.cidx", "serialization.json",
}
expected_files = metadata | {f"{digest}.{ext}" for digest in stream_hashes.values() for ext in ("bin", "mrk2")}
if {path.name for path in part.iterdir()} != expected_files:
    fail("part file inventory differs")
if any(path.suffix == ".cmrk2" for path in part.iterdir()):
    fail("part unexpectedly uses compressed marks")

signed = [
    0, -1, 1, -(1 << 255), (1 << 255) - 1, -42, 42, -(1 << 254),
    1 << 254, -123456789012345678901234567890123456789,
    123456789012345678901234567890123456789, -(1 << 255), (1 << 255) - 1,
]
unsigned = [
    0, 1, (1 << 256) - 1, 1 << 255, (1 << 255) + 1,
    (1 << 256) - 2, (1 << 255) - 1, 1 << 254, (1 << 255) + 2,
    (1 << 255) - 1, (1 << 256) - 3, 0, 42,
]
keys = list(range(1, 14))
raw_expected = {
    "pk": b"".join(value.to_bytes(8, "little") for value in keys),
    "i": b"".join(value.to_bytes(32, "little", signed=True) for value in signed),
    "u": b"".join(value.to_bytes(32, "little") for value in unsigned),
}
expected_sizes = {"pk": (84, 104, 8), "i": (124, 416, 32), "u": (100, 416, 32)}
mark_rows = [0, 2, 4, 6, 8, 10, 12, 13]
mark_counts = [2, 2, 2, 2, 2, 2, 1, 0]
for logical, digest in stream_hashes.items():
    bin_path, mark_path = part/f"{digest}.bin", part/f"{digest}.mrk2"
    compressed_size, raw_size, width = expected_sizes[logical]
    if bin_path.stat().st_size != compressed_size:
        fail(f"{logical} compressed size differs")
    decoded = decode(bin_path)
    if len(decoded) != raw_size or decoded != raw_expected[logical]:
        fail(f"{logical} raw byte stream differs from fixed-width little-endian encoding")
    raw_marks = mark_path.read_bytes()
    if len(raw_marks) != 8 * 24:
        fail(f"{logical} must contain seven data marks and one EOF sentinel")
    marks = [struct.unpack_from("<QQQ", raw_marks, index*24) for index in range(8)]
    expected_marks = [(0, row*width, count) for row, count in zip(mark_rows, mark_counts)]
    if marks != expected_marks:
        fail(f"{logical} marks differ: {marks!r}")

listed = sorted(line.split(None, 1)[1].lstrip("* ") for line in (fixture/"SHA256SUMS").read_text().splitlines())
actual = sorted(str(path.relative_to(fixture)) for path in part.rglob("*") if path.is_file())
if listed != actual:
    fail("SHA256SUMS does not cover exactly every regular file in part/")

# Independently make ClickHouse ingest and validate this part, then check both
# SQL text values and RowBinary bytes against the hard-coded decimal vectors.
run_ch("""
CREATE TABLE default.stock_integer256
(
    pk UInt64,
    i Int256,
    u UInt256
)
ENGINE = MergeTree
ORDER BY pk
SETTINGS
    index_granularity = 2,
    index_granularity_bytes = 10485760,
    enable_mixed_granularity_parts = 1,
    min_rows_for_wide_part = 0,
    min_bytes_for_wide_part = 0,
    compress_marks = 0,
    min_compress_block_size = 0,
    max_compress_block_size = 4096,
    default_compression_codec = 'LZ4'
""")
data_path = run_ch("SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='stock_integer256' FORMAT TSVRaw").decode().strip()
if not data_path:
    fail("ClickHouse table data path is missing")
detached = Path(data_path) / "detached"
detached.mkdir(parents=True, exist_ok=True)
shutil.copytree(part, detached / "all_1_1_0")
run_ch("ALTER TABLE default.stock_integer256 ATTACH PART 'all_1_1_0'")
shape = run_ch("SELECT rows, marks, part_type FROM system.parts WHERE database='default' AND table='stock_integer256' AND active FORMAT TabSeparated").decode().strip()
if shape != "13\t8\tWide":
    fail(f"attached stock part shape differs: {shape!r}")
check = run_ch("CHECK TABLE default.stock_integer256 FORMAT TabSeparated").decode().strip()
if check != "all_1_1_0\t1":
    fail(f"CHECK TABLE failed: {check!r}")
schema = run_ch("SELECT name, type FROM system.columns WHERE database='default' AND table='stock_integer256' ORDER BY position FORMAT TabSeparated").decode().strip()
if schema != "pk\tUInt64\ni\tInt256\nu\tUInt256":
    fail(f"attached stock table schema differs: {schema!r}")
sql_rows = run_ch("SELECT pk, toString(i), toString(u) FROM default.stock_integer256 ORDER BY pk FORMAT TSVRaw").decode().splitlines()
expected_sql = [f"{pk}\t{i}\t{u}" for pk, i, u in zip(keys, signed, unsigned)]
if sql_rows != expected_sql:
    fail("ClickHouse SQL-decoded values differ from signed/unsigned endpoints and crossover vectors")
rowbinary = run_ch("SELECT pk, i, u FROM default.stock_integer256 ORDER BY pk FORMAT RowBinary")
expected_rowbinary = b"".join(
    pk.to_bytes(8, "little") + i.to_bytes(32, "little", signed=True) + u.to_bytes(32, "little")
    for pk, i, u in zip(keys, signed, unsigned)
)
if rowbinary != expected_rowbinary:
    fail("ClickHouse RowBinary differs from independent 8+32+32 byte encoding")
edge_checks = run_ch("""
SELECT
    countIf(i = CAST('-57896044618658097711785492504343953926634992332820282019728792003956564819968', 'Int256')),
    countIf(i = CAST('57896044618658097711785492504343953926634992332820282019728792003956564819967', 'Int256')),
    countIf(u = CAST('0', 'UInt256')),
    countIf(u = CAST('115792089237316195423570985008687907853269984665640564039457584007913129639935', 'UInt256')),
    countIf(u = CAST('57896044618658097711785492504343953926634992332820282019728792003956564819969', 'UInt256'))
FROM default.stock_integer256 FORMAT TabSeparated
""").decode().strip()
if edge_checks != "2\t2\t2\t1\t1":
    fail(f"ClickHouse SQL endpoint/crossover checks differ: {edge_checks!r}")
PY

printf 'stock Int256/UInt256 fixture verified: pinned Wide layout, exact Default metadata, fixed-width raw bytes, marks/sentinel, SHA256 manifest, ClickHouse ATTACH/CHECK, SQL edges, and independent RowBinary\n'
