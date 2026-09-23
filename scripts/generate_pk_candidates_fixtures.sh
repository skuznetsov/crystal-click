#!/usr/bin/env bash
set -euo pipefail

CLICKHOUSE="${CLICKHOUSE:-$(command -v clickhouse || true)}"
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
FIXTURE_ROOT="$ROOT/test/fixtures/public"
ORACLE="$FIXTURE_ROOT/wide_u64_pk_candidates_oracle.tsv"
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
  local encoding="$2"
  python3 - "$dir" "$encoding" <<'PY'
from pathlib import Path
import struct
import sys

root = Path(sys.argv[1])
encoding = sys.argv[2]


def fail(message):
    raise SystemExit(f"UInt64 PK fixture shape error: {message}")


if encoding not in {"raw", "cidx"}:
    fail(f"unknown encoding: {encoding}")
if not root.is_dir():
    fail(f"missing fixture: {root}")
entries = list(root.iterdir())
if any(entry.is_symlink() or not entry.is_file() for entry in entries):
    fail("fixture contains a directory or non-regular entry")
names = {entry.name for entry in entries}
if root.joinpath("count.txt").read_bytes() != b"40":
    fail("expected 40 rows")
columns = root.joinpath("columns.txt").read_bytes()
if b"`pk` UInt64\n" not in columns or b"`value` UInt64\n" not in columns:
    fail("expected pk and value UInt64 columns")
mark_paths = sorted(root.glob("*.mrk2"))
if len(mark_paths) != 2:
    fail("expected two plain adaptive .mrk2 streams")
if any(name.endswith((".mrk", ".mrk3", ".mrk4", ".cmrk", ".cmrk2", ".cmrk3", ".cmrk4")) for name in names):
    fail("fixture contains an unsupported or compressed mark format")
mark_sequences = []
for path in mark_paths:
    data = path.read_bytes()
    if not data or len(data) % 24:
        fail(f"{path.name} has a truncated .mrk2 record")
    records = [struct.unpack_from("<QQQ", data, offset) for offset in range(0, len(data), 24)]
    if records[-1][2] != 0 or any(record[2] == 0 for record in records[:-1]):
        fail(f"{path.name} lacks the final zero-row sentinel")
    rows = [record[2] for record in records[:-1]]
    if rows != [8, 8, 8, 8, 8]:
        fail(f"{path.name} has unexpected data mark rows: {rows!r}")
    mark_sequences.append(rows)
if mark_sequences[0] != mark_sequences[1]:
    fail("the two columns have different mark rows")

raw_indexes = list(root.glob("primary.idx"))
compressed_indexes = list(root.glob("primary.cidx"))
if encoding == "raw":
    if len(raw_indexes) != 1 or compressed_indexes:
        fail("expected only primary.idx")
    data = raw_indexes[0].read_bytes()
    if len(data) != 6 * 8:
        fail("raw primary index must include five mark starts and one sentinel")
    if struct.unpack("<6Q", data) != (0, 0, 1, 2, 3, 4):
        fail("raw primary index does not contain the expected duplicate boundary key")
else:
    if len(compressed_indexes) != 1 or raw_indexes:
        fail("expected only primary.cidx")
    if compressed_indexes[0].stat().st_size == 0:
        fail("primary.cidx is empty")
PY
}

check_oracle() {
  python3 - "$ORACLE" <<'PY'
from pathlib import Path
import sys

oracle = Path(sys.argv[1])
if not oracle.is_file() or oracle.is_symlink():
    raise SystemExit(f"missing or unsafe PK candidate oracle: {oracle}")
expected = "".join(f"{row // 9}\t{row}\n" for row in range(40)).encode()
if oracle.read_bytes() != expected:
    raise SystemExit("PK candidate oracle differs from the expected ClickHouse SELECT rows")
PY
}

if ((CHECK == 1)); then
  check_shape "$FIXTURE_ROOT/wide_u64_pk_raw/part" raw
  check_shape "$FIXTURE_ROOT/wide_u64_pk_cidx/part" cidx
  check_oracle
  printf 'fixture shape: 40 UInt64 rows, five 8-row data marks plus .mrk2 sentinel, raw and compressed primary indexes\n'
  exit 0
fi

if [[ -z "$CLICKHOUSE" || ! -x "$CLICKHOUSE" ]]; then
  printf 'clickhouse executable not found; set CLICKHOUSE or add it to PATH\n' >&2
  exit 1
fi

EXPECTED_VERSION='ClickHouse local version 26.7.1.1315 (official build).'
ACTUAL_VERSION="$("$CLICKHOUSE" local --version)"
if [[ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]]; then
  printf 'fixture producer mismatch: expected %s, got %s\n' "$EXPECTED_VERSION" "$ACTUAL_VERSION" >&2
  exit 1
fi

TMP_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/crystal-click-pk-fixture.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

for encoding in raw cidx; do
  out="$FIXTURE_ROOT/wide_u64_pk_${encoding}/part"
  if [[ -e "$out" ]]; then
    printf 'refusing to replace existing fixture: %s\n' "$out" >&2
    exit 2
  fi
done
if [[ -e "$ORACLE" ]]; then
  printf 'refusing to replace existing oracle: %s\n' "$ORACLE" >&2
  exit 2
fi

for encoding in raw cidx; do
  out="$FIXTURE_ROOT/wide_u64_pk_${encoding}/part"
  store="$TMP_ROOT/$encoding/store"
  mkdir -p "$store" "$(dirname -- "$out")"
  if [[ "$encoding" == raw ]]; then
    compress_primary_key=0
  else
    compress_primary_key=1
  fi

  "$CLICKHOUSE" local --path "$store" --query "
CREATE TABLE source
(
    \`pk\` UInt64,
    \`value\` UInt64
)
ENGINE = MergeTree
ORDER BY pk
SETTINGS
    min_rows_for_wide_part = 0,
    min_bytes_for_wide_part = 0,
    enable_mixed_granularity_parts = 1,
    index_granularity = 8,
    index_granularity_bytes = 1024,
    compress_marks = 0,
    compress_primary_key = $compress_primary_key;

INSERT INTO source SELECT intDiv(number, 9), number FROM numbers(40);
"

  part_path="$("$CLICKHOUSE" local --path "$store" --query "SELECT path FROM system.parts WHERE table = 'source' AND active FORMAT TSVRaw")"
  [[ -n "$part_path" ]] || { printf 'ClickHouse did not report a part path\n' >&2; exit 1; }

  staged="$TMP_ROOT/$encoding/part"
  cp -R "$part_path" "$staged"
  check_shape "$staged" "$encoding"
done

"$CLICKHOUSE" local --path "$TMP_ROOT/raw/store" --query \
  'SELECT pk, value FROM source ORDER BY value FORMAT TabSeparated' > "$TMP_ROOT/oracle.tsv"
python3 - "$TMP_ROOT/oracle.tsv" <<'PY'
from pathlib import Path
import sys

expected = "".join(f"{row // 9}\t{row}\n" for row in range(40)).encode()
if Path(sys.argv[1]).read_bytes() != expected:
    raise SystemExit("ClickHouse SELECT oracle differs from expected source rows")
PY

mkdir -p "$FIXTURE_ROOT/wide_u64_pk_raw" "$FIXTURE_ROOT/wide_u64_pk_cidx"
mv "$TMP_ROOT/raw/part" "$FIXTURE_ROOT/wide_u64_pk_raw/part"
mv "$TMP_ROOT/cidx/part" "$FIXTURE_ROOT/wide_u64_pk_cidx/part"
mv "$TMP_ROOT/oracle.tsv" "$ORACLE"
printf 'generated %s\n' "$FIXTURE_ROOT/wide_u64_pk_raw/part"
printf 'generated %s\n' "$FIXTURE_ROOT/wide_u64_pk_cidx/part"
printf 'generated %s\n' "$ORACLE"
