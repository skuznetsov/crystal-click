#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/Users/sergey/.local/bin/clickhouse}"
FIXTURE="$ROOT/test/fixtures/public/wide_array_numeric"
EXPECTED_VERSION='ClickHouse local version 26.7.1.1315 (official build).'

if [[ "${1:-}" == "--check" && "$#" -eq 1 ]]; then
  exec "$ROOT/scripts/verify_stock_array_numeric_fixture.sh"
fi
if [[ "$#" -ne 0 ]]; then
  printf 'usage: %s [--check]\n' "$0" >&2
  exit 2
fi
if [[ ! -x "$CLICKHOUSE_BIN" ]]; then
  printf 'ClickHouse executable not found: %s\n' "$CLICKHOUSE_BIN" >&2
  exit 1
fi
ACTUAL_VERSION="$("$CLICKHOUSE_BIN" local --version)"
if [[ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]]; then
  printf 'fixture producer mismatch: expected %s, got %s\n' "$EXPECTED_VERSION" "$ACTUAL_VERSION" >&2
  exit 1
fi
if [[ -L "$FIXTURE" || -e "$FIXTURE/part" || -e "$FIXTURE/SHA256SUMS" ]]; then
  printf 'refusing to replace existing fixture data: %s\n' "$FIXTURE" >&2
  exit 2
fi
if [[ -e "$FIXTURE" ]]; then
  [[ -d "$FIXTURE" && ! -L "$FIXTURE" && -f "$FIXTURE/PROVENANCE.md" && ! -L "$FIXTURE/PROVENANCE.md" ]] || {
    printf 'refusing to modify unexpected fixture path: %s\n' "$FIXTURE" >&2
    exit 2
  }
  [[ "$(find "$FIXTURE" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d ' ')" == 1 ]] || {
    printf 'refusing to modify non-empty fixture directory: %s\n' "$FIXTURE" >&2
    exit 2
  }
fi

TMP_ROOT="$(mktemp -d /private/tmp/crystal-click-array-numeric-fixture.XXXXXX)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT
STORE="$TMP_ROOT/store"
STAGED="$TMP_ROOT/staged"

"$CLICKHOUSE_BIN" local --path "$STORE" --query '
CREATE TABLE source
(
    pk UInt64,
    arr_u8 Array(UInt8),
    arr_u16 Array(UInt16),
    arr_u32 Array(UInt32),
    arr_u64 Array(UInt64),
    arr_i8 Array(Int8),
    arr_i16 Array(Int16),
    arr_i32 Array(Int32),
    arr_i64 Array(Int64),
    arr_f32 Array(Float32),
    arr_f64 Array(Float64)
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
    default_compression_codec = '\''LZ4'\'';
'

python3 - <<'PY' | "$CLICKHOUSE_BIN" local --path "$STORE" --query 'INSERT INTO source FORMAT RowBinary'
import struct
import sys

keys = [1, 2, 4, 6, 9, 11, 13]
columns = {
    "u8": ("B", [[], [0, 255], [], [1, 128], [0, 1], [255], []]),
    "u16": ("H", [[], [0, 65535], [], [1, 32768], [0, 1], [65535], []]),
    "u32": ("I", [[], [0, 0xFFFFFFFF], [], [1, 0x80000000], [0, 1], [0xFFFFFFFF], []]),
    "u64": ("Q", [[], [0, 0xFFFFFFFFFFFFFFFF], [], [1, 0x8000000000000000], [0, 1], [0xFFFFFFFFFFFFFFFF], []]),
    "i8": ("b", [[], [0, 127], [], [-128, -1], [0, 1], [127], []]),
    "i16": ("h", [[], [0, 32767], [], [-32768, -1], [0, 1], [32767], []]),
    "i32": ("i", [[], [0, 0x7FFFFFFF], [], [-0x80000000, -1], [0, 1], [0x7FFFFFFF], []]),
    "i64": ("q", [[], [0, 0x7FFFFFFFFFFFFFFF], [], [-0x8000000000000000, -1], [0, 1], [0x7FFFFFFFFFFFFFFF], []]),
    # Floating-point values are supplied as integer bit patterns, not parsed text.
    "f32": ("I", [[], [0x80000000, 0, 0x7FC12345, 0x7F7FFFFF, 0x7F800000], [], [0xFF7FFFFF, 0xFF800000], [0x3FC00000, 0xC0100000], [1, 0x80000001], []]),
    "f64": ("Q", [[], [0x8000000000000000, 0, 0x7FF8000000001234, 0x7FEFFFFFFFFFFFFF, 0x7FF0000000000000], [], [0xFFEFFFFFFFFFFFFF, 0xFFF0000000000000], [0x3FF8000000000000, 0xC002000000000000], [1, 0x8000000000000001], []]),
}

def write_varuint(out, value):
    while value >= 0x80:
        out.write(bytes(((value & 0x7F) | 0x80,)))
        value >>= 7
    out.write(bytes((value,)))

out = sys.stdout.buffer
for row, key in enumerate(keys):
    out.write(struct.pack("<Q", key))
    for fmt, values_by_row in columns.values():
        values = values_by_row[row]
        write_varuint(out, len(values))
        for value in values:
            out.write(struct.pack("<" + fmt, value))
PY

PART_PATH="$("$CLICKHOUSE_BIN" local --path "$STORE" --query "SELECT path FROM system.parts WHERE table = 'source' AND active FORMAT TSVRaw")"
[[ -n "$PART_PATH" && -d "$PART_PATH" && ! -L "$PART_PATH" ]] || {
  printf 'ClickHouse did not report exactly one source part directory\n' >&2
  exit 1
}
CHECK_RESULT="$("$CLICKHOUSE_BIN" local --path "$STORE" --query 'CHECK TABLE source FORMAT TabSeparated')"
CHECK_RESULT="${CHECK_RESULT%$'\t'}"
[[ "$CHECK_RESULT" == $'all_1_1_0\t1' ]] || {
  printf 'source CHECK TABLE failed: %q\n' "$CHECK_RESULT" >&2
  exit 1
}

mkdir -p "$STAGED"
cp -R "$PART_PATH" "$STAGED/part"
"$ROOT/scripts/verify_stock_array_numeric_fixture.sh" --part-only "$STAGED/part"
(cd "$STAGED" && find part -type f -print0 | sort -z | xargs -0 shasum -a 256 > SHA256SUMS)
mkdir -p "$(dirname -- "$FIXTURE")"
mkdir -p "$FIXTURE"
mv "$STAGED/part" "$FIXTURE/part"
mv "$STAGED/SHA256SUMS" "$FIXTURE/SHA256SUMS"
"$ROOT/scripts/verify_stock_array_numeric_fixture.sh"
printf 'generated %s from %s\n' "$FIXTURE" "$EXPECTED_VERSION"
