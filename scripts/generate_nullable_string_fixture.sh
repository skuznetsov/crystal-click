#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUT_ROOT="$ROOT/test/fixtures/public/wide_nullable_string"
OUT="$OUT_ROOT/part"
ORACLE="$OUT_ROOT/oracle.tsv"
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

check_fixture() {
  local dir="$1"
  local oracle="$2"
  python3 - "$dir" "$oracle" <<'PY'
from pathlib import Path
import json
import struct
import sys

root = Path(sys.argv[1])
oracle = Path(sys.argv[2])


def fail(message):
    raise SystemExit(f"Nullable(String) fixture shape error: {message}")


if not root.is_dir():
    fail(f"missing fixture: {root}")
entries = list(root.iterdir())
if any(entry.is_symlink() or not entry.is_file() for entry in entries):
    fail("part contains a directory or non-regular entry")
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
if len([name for name in names if name.endswith(".bin")]) != 4:
    fail("expected exactly four selected physical data streams")
mark_paths = sorted(root.glob("*.mrk2"))
if len(mark_paths) != 4 or any(path.name.endswith(".cmrk2") for path in root.iterdir()):
    fail("expected exactly four plain .mrk2 streams")
if any(name.endswith((".mrk", ".mrk3", ".mrk4", ".cmrk", ".cmrk2", ".cmrk3", ".cmrk4")) for name in names):
    fail("fixture contains an unsupported mark format")
if root.joinpath("count.txt").read_bytes() != b"8":
    fail("unexpected row count")
if root.joinpath("columns.txt").read_bytes() != (
    b"columns format version: 1\n2 columns:\n"
    b"`seq` UInt64\n`payload` Nullable(String)\n"
):
    fail("columns.txt differs from the exact UInt64/Nullable(String) schema")
if root.joinpath("columns_substreams.txt").read_bytes() != (
    b"columns substreams version: 1\n2 columns:\n"
    b"1 substreams for column `seq`:\n\tseq\n"
    b"3 substreams for column `payload`:\n"
    b"\tpayload.null\n\tpayload.size\n\tpayload\n"
):
    fail("columns_substreams.txt differs from the expected Nullable(String) shape")
serialization = json.loads(root.joinpath("serialization.json").read_bytes())
if serialization.get("version") != 1:
    fail("serialization.json must use WITH_TYPES version 1")
if serialization.get("types_serialization_versions") != {"string": 1}:
    fail("serialization.json must declare String WITH_SIZE_STREAM version 1 and default Nullable version 0")
if serialization.get("propagate_types_serialization_versions_to_nested_types") is not True:
    fail("serialization.json must preserve the producer's nested-version propagation flag")

expected_oracle = (
    b"1\tLEN:1\tHEX:50\n"
    b"2\tNULL\tNULL\n"
    b"3\tLEN:1\tHEX:51\n"
    b"4\tLEN:0\tHEX:\n"
    b"5\tLEN:3\tHEX:610062\n"
    b"6\tLEN:1\tHEX:7A\n"
    b"7\tNULL\tNULL\n"
    b"8\tLEN:3\tHEX:510052\n"
)
if not oracle.is_file() or oracle.is_symlink() or oracle.read_bytes() != expected_oracle:
    fail("ordered ClickHouse oracle differs from NULL/empty/embedded-NUL expectations")

mark_sequences = []
for path in mark_paths:
    data = path.read_bytes()
    if not data or len(data) % 24:
        fail(f"{path.name} has a truncated mark record")
    records = [struct.unpack_from("<QQQ", data, offset) for offset in range(0, len(data), 24)]
    if records[-1][2] != 0 or any(record[2] == 0 for record in records[:-1]):
        fail(f"{path.name} has an invalid EOF sentinel")
    rows = [record[2] for record in records[:-1]]
    if rows != [2, 2, 2, 2]:
        fail(f"{path.name} does not contain the expected four mark row counts")
    mark_sequences.append(rows)
if any(rows != mark_sequences[0] for rows in mark_sequences[1:]):
    fail("the selected substreams have different mark rows")
PY
}

if ((CHECK == 1)); then
  check_fixture "$OUT" "$ORACLE"
  printf 'fixture shape: ordered Nullable(String), 8 rows, three payload streams, four plain .mrk2 marks\n'
  exit 0
fi

if [[ -z "$CLICKHOUSE" || ! -x "$CLICKHOUSE" ]]; then
  printf 'clickhouse executable not found; set CLICKHOUSE or add it to PATH\n' >&2
  exit 1
fi
if [[ -e "$OUT_ROOT" ]]; then
  printf 'refusing to replace existing fixture: %s\n' "$OUT_ROOT" >&2
  exit 2
fi

EXPECTED_VERSION='ClickHouse local version 26.7.1.1315 (official build).'
ACTUAL_VERSION="$("$CLICKHOUSE" local --version)"
if [[ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]]; then
  printf 'fixture producer mismatch: expected %s, got %s\n' "$EXPECTED_VERSION" "$ACTUAL_VERSION" >&2
  exit 1
fi

TMP_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/crystal-click-nullable-string.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT
STORE="$TMP_ROOT/store"

"$CLICKHOUSE" local --path "$STORE" --query "
CREATE TABLE source
(
    seq UInt64,
    payload Nullable(String)
)
ENGINE = MergeTree
ORDER BY seq
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
    (1, 'P'),
    (2, NULL),
    (3, 'Q'),
    (4, ''),
    (5, unhex('610062')),
    (6, 'z'),
    (7, NULL),
    (8, unhex('510052'));
"

"$CLICKHOUSE" local --path "$STORE" --query \
  "SELECT seq, if(isNull(payload), 'NULL', concat('LEN:', toString(length(payload)))), if(isNull(payload), 'NULL', concat('HEX:', hex(payload))) FROM source ORDER BY seq FORMAT TSVRaw" \
  > "$TMP_ROOT/oracle.tsv"

PART_PATH="$("$CLICKHOUSE" local --path "$STORE" --query "SELECT path FROM system.parts WHERE table = 'source' AND active FORMAT TSVRaw")"
[[ -n "$PART_PATH" ]] || { printf 'ClickHouse did not report a part path\n' >&2; exit 1; }

STAGED="$TMP_ROOT/part"
cp -R "$PART_PATH" "$STAGED"
check_fixture "$STAGED" "$TMP_ROOT/oracle.tsv"

mkdir -p "$(dirname -- "$OUT")"
mv "$STAGED" "$OUT"
mv "$TMP_ROOT/oracle.tsv" "$ORACLE"
printf 'generated %s\n' "$OUT_ROOT"
