#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/Users/sergey/.local/bin/clickhouse}"
FIXTURE="$ROOT/test/fixtures/public/wide_array_nullable_string"
EXPECTED_VERSION='ClickHouse local version 26.7.1.1315 (official build).'

if [[ "${1:-}" == "--check" && "$#" -eq 1 ]]; then
  exec "$ROOT/scripts/verify_stock_array_nullable_string_fixture.sh"
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

TMP_ROOT="$(mktemp -d /private/tmp/crystal-click-array-nullable-string-fixture.XXXXXX)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT
STORE="$TMP_ROOT/store"
STAGED="$TMP_ROOT/staged"

"$CLICKHOUSE_BIN" local --path "$STORE" --query '
CREATE TABLE source
(
    pk UInt64,
    a Array(Nullable(String))
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
    ratio_of_defaults_for_sparse_serialization = 1.0,
    default_compression_codec = '\''LZ4'\'';
'

python3 - <<'PY' | "$CLICKHOUSE_BIN" local --path "$STORE" --query 'INSERT INTO source FORMAT RowBinary'
import struct
import sys

keys = [1, 2, 4, 6, 9, 11, 13, 17, 19, 21, 25]
values = [
    [], [],
    [None, b"", b"a\x00b"], [b"", b"B\xff"],
    [None, None], [None],
    [], [],
    [b"", b""], [b""],
    [b"\xc3\xa9", b"tail\x00x"],
]

def write_varuint(out, value):
    while value >= 0x80:
        out.write(bytes(((value & 0x7F) | 0x80,)))
        value >>= 7
    out.write(bytes((value,)))

out = sys.stdout.buffer
for key, row in zip(keys, values):
    out.write(struct.pack("<Q", key))
    write_varuint(out, len(row))
    for value in row:
        if value is None:
            out.write(b"\x01")
        else:
            out.write(b"\x00")
            write_varuint(out, len(value))
            out.write(value)
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
CLICKHOUSE_BIN="$CLICKHOUSE_BIN" "$ROOT/scripts/verify_stock_array_nullable_string_fixture.sh" --part-only "$STAGED/part"
(cd "$STAGED" && find part -type f -print0 | sort -z | xargs -0 shasum -a 256 > SHA256SUMS)
mkdir -p "$(dirname -- "$FIXTURE")"
mkdir -p "$FIXTURE"
mv "$STAGED/part" "$FIXTURE/part"
mv "$STAGED/SHA256SUMS" "$FIXTURE/SHA256SUMS"
"$ROOT/scripts/verify_stock_array_nullable_string_fixture.sh"
printf 'generated %s from %s; CHECK TABLE all_1_1_0\t1\n' "$FIXTURE" "$EXPECTED_VERSION"
