#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/Users/sergey/.local/bin/clickhouse}"
OUT="${WIDE_NULLABLE_INTEGER256_FIXTURE_OUT:-$ROOT/test/fixtures/public/wide_nullable_integer256}"
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

TMP_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/crystal-click-wide-nullable-integer256-fixture.XXXXXX")"
STAGE=""
cleanup() {
  if [[ -n "$STAGE" && -d "$STAGE" ]]; then
    rm -rf -- "$STAGE"
  fi
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT
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
    i Nullable(Int256),
    u Nullable(UInt256)
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
    default_compression_codec = 'LZ4',
    nullable_serialization_version = '$nullable_version',
    ratio_of_defaults_for_sparse_serialization = $default_ratio
"
done

"$CLICKHOUSE_BIN" local --path "$STORE" --query "
INSERT INTO default.basic_source VALUES
    (1, NULL, NULL),
    (2, CAST('-1', 'Int256'), CAST('1', 'UInt256')),
    (3, CAST('1', 'Int256'), CAST('115792089237316195423570985008687907853269984665640564039457584007913129639935', 'UInt256')),
    (4, CAST('-57896044618658097711785492504343953926634992332820282019728792003956564819968', 'Int256'), CAST('57896044618658097711785492504343953926634992332820282019728792003956564819968', 'UInt256')),
    (5, CAST('57896044618658097711785492504343953926634992332820282019728792003956564819967', 'Int256'), NULL),
    (6, CAST('-42', 'Int256'), CAST('115792089237316195423570985008687907853269984665640564039457584007913129639934', 'UInt256')),
    (7, CAST('42', 'Int256'), CAST('57896044618658097711785492504343953926634992332820282019728792003956564819967', 'UInt256')),
    (8, CAST('-28948022309329048855892746252171976963317496166410141009864396001978282409984', 'Int256'), CAST('28948022309329048855892746252171976963317496166410141009864396001978282409984', 'UInt256')),
    (9, CAST('28948022309329048855892746252171976963317496166410141009864396001978282409984', 'Int256'), CAST('57896044618658097711785492504343953926634992332820282019728792003956564819970', 'UInt256')),
    (10, CAST('-123456789012345678901234567890123456789', 'Int256'), CAST('57896044618658097711785492504343953926634992332820282019728792003956564819967', 'UInt256')),
    (11, CAST('123456789012345678901234567890123456789', 'Int256'), CAST('115792089237316195423570985008687907853269984665640564039457584007913129639933', 'UInt256')),
    (12, NULL, NULL),
    (13, CAST('57896044618658097711785492504343953926634992332820282019728792003956564819967', 'Int256'), CAST('42', 'UInt256'))
"

"$CLICKHOUSE_BIN" local --path "$STORE" --query "
INSERT INTO default.sparse_source VALUES
    (1, NULL, NULL),
    (2, CAST('-1', 'Int256'), CAST('1', 'UInt256')),
    (3, NULL, NULL),
    (4, NULL, NULL),
    (5, NULL, NULL),
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
    (21, NULL, NULL),
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
  expected_shape=$'13\t8\tWide'
  if [[ "$table" == 'sparse_source' ]]; then
    expected_shape=$'32\t17\tWide'
  fi
  if [[ "$shape" != "$expected_shape" ]]; then
    printf '%s: expected %q; got %q\n' "$table" "$expected_shape" "$shape" >&2
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
for part_path in "$BASIC_PATH" "$SPARSE_PATH"; do
  [[ -d "$part_path" && ! -L "$part_path" ]] || { printf 'stock part not found: %s\n' "$part_path" >&2; exit 1; }
  [[ -z "$(find "$part_path" -mindepth 1 -type l -print -quit)" ]] || { printf 'stock part contains symlinks: %s\n' "$part_path" >&2; exit 1; }
done

OUT_PARENT="$(dirname -- "$OUT")"
mkdir -p "$OUT_PARENT"
STAGE="$(mktemp -d "$OUT.tmp.XXXXXX")"
cp -R "$BASIC_PATH" "$STAGE/part"
mkdir -p "$STAGE/sparse"
cp -R "$SPARSE_PATH" "$STAGE/sparse/part"
cat > "$STAGE/PROVENANCE.md" <<'EOF'
# Public Wide BASIC Nullable raw Int256/UInt256 fixture

The `part/` tree was generated by the pinned ClickHouse local 26.7.1.1315
official build using `scripts/generate_public_wide_nullable_integer256_fixture.sh`.
It is a 13-row `(pk UInt64, i Nullable(Int256), u Nullable(UInt256))` Wide
MergeTree part ordered by `pk`, with LZ4 streams, plain `.mrk2` marks,
`index_granularity = 2`, seven data marks, and a terminal EOF sentinel.
The fixed values include signed minimum/maximum, unsigned maximum, high-bit
crossovers, negative values, large decimal values, and nulls in both columns.

The companion `sparse/part/` tree is a separate stock Sparse nullable
serialization control with the same schema and profile, 32 rows, 16 data
marks, a terminal EOF sentinel, and one non-NULL payload per nullable column.
It is deliberately outside BASIC admission. `SHA256SUMS` covers every regular
file in both part trees.

The fixture verifier checks exact metadata and stream inventory, null maps,
all 32-byte nested value slots (including zero-filled NULL slots), plain mark
records, and ClickHouse ATTACH/CHECK plus independent SQL and RowBinary results.
The bidirectional oracle exercises Crystal reads and writes against this
pinned ClickHouse build. The generator refuses to replace existing output.
Regenerate only into a new output directory.
EOF
(cd "$STAGE" && find part sparse/part -type f -print0 | sort -z | xargs -0 shasum -a 256 > SHA256SUMS)
if [[ -e "$OUT" || -L "$OUT" ]]; then
  printf 'fixture appeared during generation; refusing to replace it: %s\n' "$OUT" >&2
  exit 2
fi
mv "$STAGE" "$OUT"
STAGE=""
printf 'generated %s with %s\n' "$OUT" "$ACTUAL_VERSION"
