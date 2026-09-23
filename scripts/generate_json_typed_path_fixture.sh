#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUT="$ROOT/test/fixtures/public/wide_json_typed_path/part"
CLICKHOUSE="${CLICKHOUSE:-$(command -v clickhouse || true)}"
CHECK=0

usage() {
  printf 'usage: %s [--check]\n' "$0" >&2
}

while (($# > 0)); do
  case "$1" in
    --check) CHECK=1 ;;
    *) usage; exit 2 ;;
  esac
  shift
done

check_shape() {
  local dir="$1"
  python3 - "$dir" <<'PY'
from pathlib import Path
import json
import sys

root = Path(sys.argv[1])


def fail(message):
    raise SystemExit(f"JSON typed-path fixture shape error: {message}")


if not root.is_dir():
    fail(f"missing fixture: {root}")
entries = list(root.iterdir())
if any(entry.is_symlink() or not entry.is_file() for entry in entries):
    fail("fixture contains a directory or non-regular entry")
names = {entry.name for entry in entries}
required = {
    "checksums.txt",
    "columns.txt",
    "columns_substreams.txt",
    "count.txt",
    "default_compression_codec.txt",
    "metadata_version.txt",
    "serialization.json",
}
if not required <= names:
    fail(f"missing required files: {sorted(required - names)!r}")
if len([name for name in names if name.endswith(".bin")]) != 8:
    fail("expected seven JSON data streams plus the ordinal")
mark_paths = sorted(root.glob("*.cmrk2"))
if len(mark_paths) != 8 or list(root.glob("*.mrk2")):
    fail("expected eight compressed .cmrk2 streams including the ordinal")
if any(name.endswith((".mrk", ".mrk3", ".mrk4", ".cmrk", ".cmrk3", ".cmrk4")) for name in names):
    fail("fixture contains an unsupported mark format")
if root.joinpath("count.txt").read_bytes() != b"3":
    fail("unexpected row count")
if root.joinpath("metadata_version.txt").read_bytes() != b"0":
    fail("unexpected part metadata version")
if root.joinpath("default_compression_codec.txt").read_bytes() != b"CODEC(LZ4)":
    fail("unexpected default codec")
if root.joinpath("columns.txt").read_bytes() != (
    b"columns format version: 1\n2 columns:\n`seq` UInt64\n`j` JSON(a UInt64, b String)\n"
):
    fail("columns.txt differs from the exact ordinal and JSON schema")
if root.joinpath("columns_substreams.txt").read_bytes() != (
    b"columns substreams version: 1\n2 columns:\n"
    b"1 substreams for column `seq`:\n\tseq\n"
    b"7 substreams for column `j`:\n"
    b"\tj.object_structure\n\tj.a\n\tj.b.size\n\tj.b\n"
    b"\tj.object_shared_data.0.size0\n"
    b"\tj.object_shared_data.0%2Epaths\n"
    b"\tj.object_shared_data.0%2Evalues\n"
):
    fail("columns_substreams.txt differs from the known typed-path/shared-data shape")
serialization = json.loads(root.joinpath("serialization.json").read_bytes())
if serialization != {
    "columns": [{"kind": "Default", "name": "seq", "num_defaults": 1, "num_rows": 3}],
    "propagate_types_serialization_versions_to_nested_types": True,
    "types_serialization_versions": {"string": 1},
    "version": 1,
}:
    fail("serialization.json differs from the known version-1 envelope")

expected = {
    "034f2bafb30e18a16e9cb6040b2bd5d9": (42, "ordinal"),
    "f524e6c5728e7232425c76a53f4b3238": (39, "a"),
    "0af765b778ababa45eda6e20bc1cfb84": (36, "b-size"),
    "5f9bb7e029812fc7058bf4f625e93761": (29, "b"),
    "b3fd249161d9f4e6fdd046db90c97560": (39, "object-structure"),
    "62389a7cd33ee571289ed4edbd9c3f59": (35, "shared-size0"),
    "0d07a47ce3eee6b1d700a951ceb74448": (0, "shared-paths"),
    "a3353ada92c11c5d04a5d5456547c594": (0, "shared-values"),
}
data_stems = {path.stem for path in root.glob("*.bin")}
if data_stems != set(expected):
    fail("hashed .bin inventory differs from the observed ClickHouse stream inventory")
mark_stems = {path.stem for path in mark_paths}
if mark_stems != set(expected):
    fail("hashed .cmrk2 inventory differs from the observed ClickHouse stream inventory")
for digest, (data_size, label) in expected.items():
    if root.joinpath(f"{digest}.bin").stat().st_size != data_size:
        fail(f"{label} data size differs from the observed shape")
    mark_size = root.joinpath(f"{digest}.cmrk2").stat().st_size
    if not 48 <= mark_size <= 64:
        fail(f"{label} compressed marks have an unexpected size")
PY
}

if ((CHECK == 1)); then
  check_shape "$OUT"
  printf 'fixture shape: seq + JSON(a UInt64, b String), 3 ordered rows, eight compressed-mark streams\n'
  exit 0
fi

if [[ -z "$CLICKHOUSE" || ! -x "$CLICKHOUSE" ]]; then
  printf 'clickhouse executable not found; set CLICKHOUSE or add it to PATH\n' >&2
  exit 1
fi
if [[ -e "$OUT" ]]; then
  printf 'refusing to replace existing fixture: %s\n' "$OUT" >&2
  exit 2
fi

ACTUAL_VERSION="$("$CLICKHOUSE" local --version)"
EXPECTED_VERSION='ClickHouse local version 26.7.1.1315 (official build).'
if [[ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]]; then
  printf 'fixture producer mismatch: expected %s, got %s\n' "$EXPECTED_VERSION" "$ACTUAL_VERSION" >&2
  exit 1
fi

TMP_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/crystal-click-json-typed-path.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT
STORE="$TMP_ROOT/store"
mkdir -p "$(dirname -- "$OUT")"

"$CLICKHOUSE" local --path "$STORE" --query '
CREATE TABLE source
(
    seq UInt64,
    j JSON(a UInt64, b String)
)
ENGINE = MergeTree
ORDER BY seq
SETTINGS
    min_rows_for_wide_part = 0,
    min_bytes_for_wide_part = 0,
    enable_mixed_granularity_parts = 1,
    index_granularity = 2,
    compress_marks = 1,
    min_compress_block_size = 0,
    max_compress_block_size = 4096,
    default_compression_codec = '\''LZ4'\'';
'

"$CLICKHOUSE" local --path "$STORE" --query 'INSERT INTO source FORMAT JSONEachRow' <<'JSON'
{"seq":0,"j":{"a":10,"b":"x\u0000y"}}
{"seq":1,"j":{}}
{"seq":2,"j":{"a":30}}
JSON

PART_PATH="$("$CLICKHOUSE" local --path "$STORE" --query "SELECT path FROM system.parts WHERE table = 'source' AND active FORMAT TSVRaw")"
[[ -n "$PART_PATH" ]] || { printf 'ClickHouse did not report a part path\n' >&2; exit 1; }

STAGED="$TMP_ROOT/part"
cp -R "$PART_PATH" "$STAGED"
check_shape "$STAGED"
mv "$STAGED" "$OUT"
printf 'generated %s\n' "$OUT"
