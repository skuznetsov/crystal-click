#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUT="$ROOT/test/fixtures/public/wide_string_nullable/part"
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
import struct
import sys

root = Path(sys.argv[1])


def fail(message):
    raise SystemExit(f"String/Nullable fixture shape error: {message}")


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
    fail("expected exactly eight selected physical data streams")
mark_paths = sorted(root.glob("*.mrk2"))
if len(mark_paths) != 8 or any(path.name.endswith(".cmrk2") for path in root.iterdir()):
    fail("expected exactly eight plain .mrk2 streams")
if any(name.endswith((".mrk", ".mrk3", ".mrk4", ".cmrk", ".cmrk3", ".cmrk4")) for name in names):
    fail("fixture contains an unsupported mark format")
if root.joinpath("count.txt").read_bytes() != b"5":
    fail("unexpected row count")
if root.joinpath("columns.txt").read_bytes() != (
    b"columns format version: 1\n4 columns:\n"
    b"`label` String\n`maybe_u64` Nullable(UInt64)\n"
    b"`maybe_i16` Nullable(Int16)\n`maybe_f32` Nullable(Float32)\n"
):
    fail("columns.txt differs from the exact String/Nullable(UInt64) schema")
if root.joinpath("columns_substreams.txt").read_bytes() != (
    b"columns substreams version: 1\n4 columns:\n"
    b"2 substreams for column `label`:\n\tlabel.size\n\tlabel\n"
    b"2 substreams for column `maybe_u64`:\n\tmaybe_u64.null\n\tmaybe_u64\n"
    b"2 substreams for column `maybe_i16`:\n\tmaybe_i16.null\n\tmaybe_i16\n"
    b"2 substreams for column `maybe_f32`:\n\tmaybe_f32.null\n\tmaybe_f32\n"
):
    fail("columns_substreams.txt differs from the expected serialization shape")
serialization = json.loads(root.joinpath("serialization.json").read_bytes())
if serialization.get("version") != 1:
    fail("serialization.json must use WITH_TYPES version 1")
if serialization.get("types_serialization_versions") != {"string": 1}:
    fail("serialization.json must declare String WITH_SIZE_STREAM version 1 and default other types")
if serialization.get("propagate_types_serialization_versions_to_nested_types") is not True:
    fail("serialization.json must preserve the producer's nested-version propagation flag")

mark_sequences = []
for path in mark_paths:
    data = path.read_bytes()
    if not data or len(data) % 24:
        fail(f"{path.name} has a truncated mark record")
    records = [struct.unpack_from("<QQQ", data, offset) for offset in range(0, len(data), 24)]
    if records[-1][2] != 0 or any(record[2] == 0 for record in records[:-1]):
        fail(f"{path.name} has an invalid EOF sentinel")
    rows = [record[2] for record in records[:-1]]
    if rows != [2, 2, 1]:
        fail(f"{path.name} does not contain the expected mark rows")
    mark_sequences.append(rows)
if any(rows != mark_sequences[0] for rows in mark_sequences[1:]):
    fail("the eight selected substreams have different mark rows")
PY
}

if ((CHECK == 1)); then
  check_shape "$OUT"
  printf 'fixture shape: String + Nullable(UInt64, Int16, Float32), 5 rows, eight plain .mrk2 streams, mark rows [2, 2, 1]\n'
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

EXPECTED_VERSION='ClickHouse local version 26.7.1.1315 (official build).'
ACTUAL_VERSION="$("$CLICKHOUSE" local --version)"
if [[ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]]; then
  printf 'fixture producer mismatch: expected %s, got %s\n' "$EXPECTED_VERSION" "$ACTUAL_VERSION" >&2
  exit 1
fi

TMP_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/crystal-click-string-nullable.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT
STORE="$TMP_ROOT/store"
mkdir -p "$(dirname -- "$OUT")"

"$CLICKHOUSE" local --path "$STORE" --query "
CREATE TABLE source
(
    label String,
    maybe_u64 Nullable(UInt64),
    maybe_i16 Nullable(Int16),
    maybe_f32 Nullable(Float32)
)
ENGINE = MergeTree
ORDER BY tuple()
SETTINGS
    min_rows_for_wide_part = 0,
    min_bytes_for_wide_part = 0,
    enable_mixed_granularity_parts = 1,
    index_granularity = 2,
    compress_marks = 0,
    min_compress_block_size = 0,
    max_compress_block_size = 4096,
    default_compression_codec = 'LZ4';

INSERT INTO source VALUES
    ('', 0, -32768, -0.0),
    ('alpha', NULL, NULL, NULL),
    (unhex('610062'), 18446744073709551615, 32767, 1.5),
    ('tail', 7, -1, -2.25),
    ('', NULL, NULL, NULL);
"

PART_PATH="$("$CLICKHOUSE" local --path "$STORE" --query "SELECT path FROM system.parts WHERE table = 'source' AND active FORMAT TSVRaw")"
[[ -n "$PART_PATH" ]] || { printf 'ClickHouse did not report a part path\n' >&2; exit 1; }

STAGED="$TMP_ROOT/part"
cp -R "$PART_PATH" "$STAGED"
check_shape "$STAGED"
mv "$STAGED" "$OUT"
printf 'generated %s\n' "$OUT"
