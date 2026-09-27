#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/Users/sergey/.local/bin/clickhouse}"
OUT="${WIDE_NULLABLE_INTEGER_FIXTURE_OUT:-$ROOT/test/fixtures/public/wide_nullable_integer128}"
EXPECTED_VERSION='ClickHouse local version 26.7.1.1315 (official build).'

if [[ "$#" -ne 0 ]]; then
  printf 'usage: %s\n' "$0" >&2
  exit 2
fi
if [[ -e "$OUT" || -L "$OUT" ]]; then
  printf 'fixture exists; refusing to replace it: %s\n' "$OUT" >&2
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

TMP_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/crystal-click-wide-nullable-integer-fixture.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT
STORE="$TMP_ROOT/store"

for table in basic_source sparse_source; do
  nullable_version='basic'
  default_ratio='1.0'
  if [[ "$table" == 'sparse_source' ]]; then
    nullable_version='allow_sparse'
    default_ratio='0.5'
  fi
  "$CLICKHOUSE_BIN" local --path "$STORE" --query "
CREATE TABLE default.$table
(
    pk UInt64,
    signed Nullable(Int128),
    unsigned Nullable(UInt128)
)
ENGINE = MergeTree
ORDER BY pk
SETTINGS
    index_granularity = 4,
    index_granularity_bytes = 10485760,
    enable_mixed_granularity_parts = 1,
    min_rows_for_wide_part = 0,
    min_bytes_for_wide_part = 0,
    compress_marks = 0,
    min_compress_block_size = 0,
    max_compress_block_size = 4096,
    default_compression_codec = 'LZ4',
    nullable_serialization_version = '$nullable_version',
    ratio_of_defaults_for_sparse_serialization = $default_ratio
"
done

"$CLICKHOUSE_BIN" local --path "$STORE" --query "
INSERT INTO default.basic_source VALUES
    (1, NULL, NULL),
    (2, CAST('-9223372036854775809', 'Int128'), CAST('1', 'UInt128')),
    (3, CAST('-18446744073709551617', 'Int128'), CAST('18446744073709551615', 'UInt128')),
    (4, NULL, NULL),
    (5, CAST('-170141183460469231731687303715884105728', 'Int128'), CAST('340282366920938463463374607431768211455', 'UInt128')),
    (6, CAST('170141183460469231731687303715884105727', 'Int128'), CAST('170141183460469231731687303715884105728', 'UInt128')),
    (7, CAST('-1', 'Int128'), CAST('18446744073709551616', 'UInt128')),
    (8, CAST('0', 'Int128'), CAST('0', 'UInt128')),
    (9, NULL, NULL),
    (10, CAST('18446744073709551616', 'Int128'), CAST('18446744073709551617', 'UInt128')),
    (11, CAST('-170141183460469231731687303715884105727', 'Int128'), CAST('340282366920938463463374607431768211454', 'UInt128')),
    (12, CAST('12345678901234567890123456789012345678', 'Int128'), CAST('12345678901234567890123456789012345678', 'UInt128')),
    (13, CAST('0', 'Int128'), CAST('0', 'UInt128')),
    (14, NULL, NULL),
    (15, CAST('1', 'Int128'), CAST('42', 'UInt128')),
    (16, CAST('170141183460469231731687303715884105727', 'Int128'), CAST('340282366920938463463374607431768211455', 'UInt128')),
    (17, NULL, NULL),
    (18, CAST('-1267650600228229401496703205376', 'Int128'), CAST('1267650600228229401496703205376', 'UInt128')),
    (19, CAST('1267650600228229401496703205376', 'Int128'), CAST('340282366920938463463374607431768211454', 'UInt128')),
    (20, CAST('42', 'Int128'), CAST('1', 'UInt128')),
    (21, NULL, NULL),
    (22, CAST('-1', 'Int128'), CAST('18446744073709551616', 'UInt128')),
    (23, CAST('0', 'Int128'), CAST('0', 'UInt128')),
    (24, CAST('18446744073709551615', 'Int128'), CAST('340282366920938463463374607431768211455', 'UInt128')),
    (25, CAST('-170141183460469231731687303715884105728', 'Int128'), CAST('170141183460469231731687303715884105728', 'UInt128')),
    (26, NULL, CAST('1267650600228229401496703205377', 'UInt128')),
    (27, CAST('-170141183460469231731687303715884105727', 'Int128'), CAST('0', 'UInt128')),
    (28, CAST('1329227995784915872903807060280344576', 'Int128'), CAST('340282366920938463463374607431768211454', 'UInt128')),
    (29, NULL, NULL),
    (30, CAST('-12345678901234567890123456789012345678', 'Int128'), CAST('12345678901234567890123456789012345678', 'UInt128')),
    (31, CAST('12345678901234567890123456789012345678', 'Int128'), CAST('0', 'UInt128')),
    (32, NULL, NULL)
"

"$CLICKHOUSE_BIN" local --path "$STORE" --query "
INSERT INTO default.sparse_source VALUES
    (1, NULL, NULL),
    (2, NULL, NULL),
    (3, NULL, NULL),
    (4, NULL, NULL),
    (5, CAST('-18446744073709551617', 'Int128'), CAST('340282366920938463463374607431768211455', 'UInt128')),
    (6, NULL, NULL),
    (7, NULL, NULL),
    (8, NULL, NULL),
    (9, NULL, NULL),
    (10, NULL, NULL),
    (11, NULL, NULL),
    (12, NULL, NULL),
    (13, NULL, NULL),
    (14, NULL, NULL),
    (15, NULL, NULL),
    (16, NULL, NULL),
    (17, NULL, NULL),
    (18, NULL, NULL),
    (19, NULL, NULL),
    (20, NULL, NULL),
    (21, CAST('-170141183460469231731687303715884105728', 'Int128'), CAST('170141183460469231731687303715884105728', 'UInt128')),
    (22, NULL, NULL),
    (23, NULL, NULL),
    (24, NULL, NULL),
    (25, NULL, NULL),
    (26, NULL, NULL),
    (27, NULL, NULL),
    (28, NULL, NULL),
    (29, NULL, NULL),
    (30, NULL, NULL),
    (31, NULL, NULL),
    (32, NULL, NULL)
"

for table in basic_source sparse_source; do
  shape="$("$CLICKHOUSE_BIN" local --path "$STORE" --query "SELECT rows, marks, part_type FROM system.parts WHERE database = 'default' AND table = '$table' AND active FORMAT TabSeparated")"
  if [[ "$shape" != $'32\t9\tWide' ]]; then
    printf '%s: expected 32 rows, 9 mark records, Wide; got %q\n' "$table" "$shape" >&2
    exit 1
  fi
  check="$("$CLICKHOUSE_BIN" local --path "$STORE" --query "CHECK TABLE default.$table FORMAT TabSeparated")"
  if [[ "$check" != $'all_1_1_0\t1\t' ]]; then
    printf '%s: CHECK TABLE failed: %q\n' "$table" "$check" >&2
    exit 1
  fi
done

BASIC_PATH="$("$CLICKHOUSE_BIN" local --path "$STORE" --query "SELECT path FROM system.parts WHERE database = 'default' AND table = 'basic_source' AND active FORMAT TSVRaw")"
SPARSE_PATH="$("$CLICKHOUSE_BIN" local --path "$STORE" --query "SELECT path FROM system.parts WHERE database = 'default' AND table = 'sparse_source' AND active FORMAT TSVRaw")"
[[ -d "$BASIC_PATH" && ! -L "$BASIC_PATH" ]] || { printf 'basic stock part not found\n' >&2; exit 1; }
[[ -d "$SPARSE_PATH" && ! -L "$SPARSE_PATH" ]] || { printf 'sparse stock part not found\n' >&2; exit 1; }
[[ -z "$(find "$BASIC_PATH" -mindepth 1 -type l -print -quit)" ]] || { printf 'basic stock part contains symlinks\n' >&2; exit 1; }
[[ -z "$(find "$SPARSE_PATH" -mindepth 1 -type l -print -quit)" ]] || { printf 'sparse stock part contains symlinks\n' >&2; exit 1; }

mkdir -p "$OUT"
cp -R "$BASIC_PATH" "$OUT/part"
mkdir -p "$OUT/sparse"
cp -R "$SPARSE_PATH" "$OUT/sparse/part"
(cd "$OUT" && find part sparse/part -type f -print0 | sort -z | xargs -0 shasum -a 256 > SHA256SUMS)
printf 'generated %s with %s\n' "$OUT" "$ACTUAL_VERSION"
