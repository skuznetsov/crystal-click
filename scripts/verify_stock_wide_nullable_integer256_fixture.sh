#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/Users/sergey/.local/bin/clickhouse}"
FIXTURE="${1:-$ROOT/test/fixtures/public/wide_nullable_integer256}"
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
for path in "$FIXTURE/part" "$FIXTURE/sparse/part" "$FIXTURE/PROVENANCE.md" "$FIXTURE/SHA256SUMS"; do
  [[ -e "$path" && ! -L "$path" ]] || { printf 'fixture path missing or a symlink: %s\n' "$path" >&2; exit 1; }
done
(cd "$FIXTURE" && shasum -a 256 -c SHA256SUMS >/dev/null)

TMP_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/crystal-click-wide-nullable-integer256-verify.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT
CLICKHOUSE_BIN="$CLICKHOUSE_BIN" TMP_ROOT="$TMP_ROOT" python3 - "$FIXTURE" <<'PY'
from pathlib import Path
import json, os, shutil, struct, subprocess, sys

fixture = Path(sys.argv[1])
basic_part = fixture / "part"
sparse_part = fixture / "sparse" / "part"
clickhouse = os.environ["CLICKHOUSE_BIN"]
store = Path(os.environ["TMP_ROOT"]) / "store"
tick = chr(96)

def fail(message):
    raise SystemExit(f"Wide nullable Int256/UInt256 fixture verification failed: {message}")

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
        [clickhouse, "compressor", "--decompress"], input=path.read_bytes(),
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    if result.returncode:
        fail(f"cannot decode {path.name}: {result.stderr.decode(errors='replace')}")
    return result.stdout

def assert_tree(root):
    if root.is_symlink() or any(path.is_symlink() for path in root.rglob("*")):
        fail(f"symlink in {root.relative_to(fixture)}")
    if any(not path.is_file() for path in root.iterdir()):
        fail(f"non-file direct entry in {root.relative_to(fixture)}")

def expected_binary(keys, signed, unsigned):
    output = bytearray()
    for key, i_value, u_value in zip(keys, signed, unsigned):
        output.extend(key.to_bytes(8, "little"))
        for value, is_signed in ((i_value, True), (u_value, False)):
            if value is None:
                output.append(1)
            else:
                output.append(0)
                output.extend(value.to_bytes(32, "little", signed=is_signed))
    return bytes(output)

def assert_attached(table, part, nullable_version, expected_types, expected_rowbinary, expected_tsv, expected_rows=13, expected_marks=8):
    settings = ""
    if nullable_version == "allow_sparse":
        settings = ", nullable_serialization_version = 'allow_sparse', ratio_of_defaults_for_sparse_serialization = 0.5"
    run_ch(f"""
CREATE TABLE default.{table}
(
    pk UInt64,
    i Nullable(Int256),
    u Nullable(UInt256)
)
ENGINE = MergeTree ORDER BY pk
SETTINGS index_granularity = 2, index_granularity_bytes = 10485760,
    enable_mixed_granularity_parts = 1, min_rows_for_wide_part = 0,
    min_bytes_for_wide_part = 0, compress_marks = 0,
    min_compress_block_size = 0, max_compress_block_size = 4096,
    default_compression_codec = 'LZ4'{settings}
""")
    data_path = run_ch(f"SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='{table}' FORMAT TSVRaw").decode().strip()
    if not data_path:
        fail(f"{table}: ClickHouse table data path is missing")
    detached = Path(data_path) / "detached"
    detached.mkdir(parents=True, exist_ok=True)
    shutil.copytree(part, detached / "all_1_1_0")
    run_ch(f"ALTER TABLE default.{table} ATTACH PART 'all_1_1_0'")
    columns = run_ch(f"SELECT name, type FROM system.columns WHERE database='default' AND table='{table}' ORDER BY position FORMAT TabSeparated").decode().strip()
    if columns != expected_types:
        fail(f"{table}: attached schema differs: {columns!r}")
    shape = run_ch(f"SELECT rows, marks, part_type FROM system.parts WHERE database='default' AND table='{table}' AND active FORMAT TabSeparated").decode().strip()
    expected_shape = f"{expected_rows}\t{expected_marks}\tWide"
    if shape != expected_shape:
        fail(f"{table}: expected {expected_shape!r}; got {shape!r}")
    part_name = run_ch(f"SELECT name FROM system.parts WHERE database='default' AND table='{table}' AND active FORMAT TSVRaw").decode().strip()
    check = run_ch(f"CHECK TABLE default.{table} FORMAT TabSeparated").decode().strip()
    if check != f"{part_name}\t1":
        fail(f"{table}: CHECK TABLE failed: {check!r}")
    actual_binary = run_ch(f"SELECT pk, i, u FROM default.{table} ORDER BY pk FORMAT RowBinary")
    if actual_binary != expected_rowbinary:
        fail(f"{table}: full RowBinary differs ({len(expected_rowbinary)} expected bytes, {len(actual_binary)} actual)")
    actual_tsv = run_ch(f"SELECT pk, ifNull(toString(i), 'NULL'), ifNull(toString(u), 'NULL') FROM default.{table} ORDER BY pk FORMAT TabSeparated")
    if actual_tsv != expected_tsv:
        fail(f"{table}: SQL edge-value TSV differs: {actual_tsv!r}")
    return data_path, part_name

expected_columns = [
    "columns format version: 1", "3 columns:", tick+"pk"+tick+" UInt64",
    tick+"i"+tick+" Nullable(Int256)", tick+"u"+tick+" Nullable(UInt256)",
]
expected_substreams = [
    "columns substreams version: 1", "3 columns:",
    "1 substreams for column "+tick+"pk"+tick+":", "\tpk",
    "2 substreams for column "+tick+"i"+tick+":", "\ti.null", "\ti",
    "2 substreams for column "+tick+"u"+tick+":", "\tu.null", "\tu",
]
if (basic_part/"columns.txt").read_text().splitlines() != expected_columns:
    fail("BASIC columns.txt differs from the pinned raw Nullable Int256/UInt256 schema")
if (basic_part/"columns_substreams.txt").read_text().splitlines() != expected_substreams:
    fail("BASIC columns_substreams.txt differs from pk plus exact nullable map/value streams")
if (basic_part/"serialization.json").read_bytes() != (
    b'{"columns":[],"propagate_types_serialization_versions_to_nested_types":true,'
    b'"types_serialization_versions":{"string":1},"version":1}'
):
    fail("BASIC serialization.json is not the pinned empty Default-list, nullable-version-0 shape")

metadata = {
    "checksums.txt", "columns.txt", "columns_substreams.txt", "count.txt",
    "default_compression_codec.txt", "metadata_version.txt", "primary.cidx", "serialization.json",
}
basic_streams = {
    "pk": "fcc8daf1be9ac27649fa2186ad926aea",
    "i.null": "63cc878a3389f5155419e0b7ed212d19",
    "i": "e48542285e2b02db625d5f9b9ec1b5d3",
    "u.null": "0697be279a388a3398102d02ec1ab3ea",
    "u": "fa396ff91b8d36df3be72fd80cd08788",
}
if {path.name for path in basic_part.iterdir()} != metadata | {f"{digest}.{ext}" for digest in basic_streams.values() for ext in ("bin", "mrk2")}:
    fail("BASIC part file inventory differs")
if (basic_part/"default_compression_codec.txt").read_bytes() != b"CODEC(LZ4)":
    fail("BASIC default compression codec differs")
if (basic_part/"metadata_version.txt").read_bytes() != b"0" or (basic_part/"count.txt").read_bytes() != b"13":
    fail("BASIC metadata version or row count differs")
if not (basic_part/"checksums.txt").read_bytes().startswith(b"checksums format version: 4\n"):
    fail("BASIC checksums.txt header differs")

signed = [
    None, -1, 1, -(1 << 255), (1 << 255)-1, -42, 42, -(1 << 254),
    1 << 254, -123456789012345678901234567890123456789,
    123456789012345678901234567890123456789, None, (1 << 255)-1,
]
unsigned = [
    None, 1, (1 << 256)-1, 1 << 255, None, (1 << 256)-2,
    (1 << 255)-1, 1 << 254, (1 << 255)+2, (1 << 255)-1,
    (1 << 256)-3, None, 42,
]
keys = list(range(1, 14))
raw_values = {
    "pk": b"".join(key.to_bytes(8, "little") for key in keys),
    "i.null": bytes(value is None for value in signed),
    "i": b"".join((0 if value is None else value).to_bytes(32, "little", signed=True) for value in signed),
    "u.null": bytes(value is None for value in unsigned),
    "u": b"".join((0 if value is None else value).to_bytes(32, "little") for value in unsigned),
}
widths = {"pk": 8, "i.null": 1, "i": 32, "u.null": 1, "u": 32}
compressed_sizes = {"pk": 84, "i.null": 39, "i": 126, "u.null": 39, "u": 100}
mark_rows = [0, 2, 4, 6, 8, 10, 12, 13]
mark_counts = [2, 2, 2, 2, 2, 2, 1, 0]
for logical, digest in basic_streams.items():
    bin_path, mark_path = basic_part/f"{digest}.bin", basic_part/f"{digest}.mrk2"
    if bin_path.stat().st_size != compressed_sizes[logical]:
        fail(f"BASIC {logical} compressed size differs")
    decoded = decode(bin_path)
    if decoded != raw_values[logical]:
        fail(f"BASIC {logical} decompressed bytes differ from independent expected vector")
    mark_bytes = mark_path.read_bytes()
    if len(mark_bytes) != 8*24:
        fail(f"BASIC {logical} must have seven data marks and one EOF sentinel")
    marks = [struct.unpack_from("<QQQ", mark_bytes, offset*24) for offset in range(8)]
    expected_marks = [(0, row*widths[logical], count) for row, count in zip(mark_rows, mark_counts)]
    if marks != expected_marks:
        fail(f"BASIC {logical} .mrk2 records differ: {marks!r}")

expected_types = "pk\tUInt64\ni\tNullable(Int256)\nu\tNullable(UInt256)"
expected_full_rowbinary = expected_binary(keys, signed, unsigned)
expected_tsv = "".join(
    f"{key}\t{'NULL' if i_value is None else i_value}\t{'NULL' if u_value is None else u_value}\n"
    for key, i_value, u_value in zip(keys, signed, unsigned)
).encode()
assert_tree(basic_part)
assert_attached("stock_nullable_basic", basic_part, "basic", expected_types, expected_full_rowbinary, expected_tsv)

# The Sparse control is deliberately rejected by the Crystal reader. Here the
# independent stock check proves that the fixture really is a distinct,
# attachable Sparse representation rather than a mislabeled BASIC part.
assert_tree(sparse_part)
if (sparse_part/"columns.txt").read_text().splitlines() != expected_columns:
    fail("Sparse control columns.txt differs")
if (sparse_part/"columns_substreams.txt").read_text().splitlines() != [
    "columns substreams version: 1", "3 columns:",
    "1 substreams for column "+tick+"pk"+tick+":", "\tpk",
    "2 substreams for column "+tick+"i"+tick+":", "\ti.sparse.idx", "\ti",
    "2 substreams for column "+tick+"u"+tick+":", "\tu.sparse.idx", "\tu",
]:
    fail("Sparse control substreams differ from sparse index plus value streams")
sparse_metadata = json.loads((sparse_part/"serialization.json").read_text())
if sparse_metadata != {
    "columns": [
        {"kind": "Sparse", "name": "i", "num_defaults": 31, "num_rows": 32},
        {"kind": "Default", "name": "pk", "num_defaults": 0, "num_rows": 32},
        {"kind": "Sparse", "name": "u", "num_defaults": 31, "num_rows": 32},
    ],
    "propagate_types_serialization_versions_to_nested_types": True,
    "types_serialization_versions": {"nullable": 1, "string": 1},
    "version": 1,
}:
    fail(f"Sparse control serialization metadata is not the stock nullable-version-1 shape: {sparse_metadata!r}")
sparse_streams = {
    "pk": "fcc8daf1be9ac27649fa2186ad926aea",
    "i.sparse.idx": "6b07a82a83d2dc60fa30df3316d607fe",
    "i": "e48542285e2b02db625d5f9b9ec1b5d3",
    "u.sparse.idx": "e2c7d0bc46a51c9ce3263193b6ff6c46",
    "u": "fa396ff91b8d36df3be72fd80cd08788",
}
if {path.name for path in sparse_part.iterdir()} != metadata | {f"{digest}.{ext}" for digest in sparse_streams.values() for ext in ("bin", "mrk2")}:
    fail("Sparse control part file inventory differs")
for logical, digest in sparse_streams.items():
    marks = sparse_part/f"{digest}.mrk2"
    if len(marks.read_bytes()) != 17*24:
        fail(f"Sparse control {logical} does not have 16 data marks plus an EOF sentinel")
    decoded = decode(sparse_part/f"{digest}.bin")
    if logical in ("i.sparse.idx", "u.sparse.idx") and not decoded:
        fail(f"Sparse control {logical} index stream is empty")
    if logical in ("i", "u") and len(decoded) != 32:
        fail(f"Sparse control {logical} must carry only one non-NULL 32-byte child")
assert_attached(
    "stock_nullable_sparse", sparse_part, "allow_sparse", expected_types,
    expected_binary(list(range(1, 33)), [None, -1]+[None]*30, [None, 1]+[None]*30),
    "".join(f"{key}\t{'-1' if key == 2 else 'NULL'}\t{'1' if key == 2 else 'NULL'}\n" for key in range(1, 33)).encode(),
    32,
    17,
)

listed = sorted(line.split(None, 1)[1].lstrip("* ") for line in (fixture/"SHA256SUMS").read_text().splitlines())
actual = sorted(str(path.relative_to(fixture)) for root in (basic_part, sparse_part) for path in root.rglob("*") if path.is_file())
if listed != actual:
    fail("SHA256SUMS does not cover exactly every regular file in both part trees")
print("stock W38 fixture verified: pinned 26.7.1.1315 BASIC + Sparse, exact bytes/marks/metadata, ATTACH/CHECK, SQL and RowBinary")
PY
