#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/Users/sergey/.local/bin/clickhouse}"
OUT="${WIDE_INTEGER256_FIXTURE_OUT:-$ROOT/test/fixtures/public/wide_integer256}"
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

TMP_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/crystal-click-wide-integer256-fixture.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT
STORE="$TMP_ROOT/store"

"$CLICKHOUSE_BIN" local --path "$STORE" --query "
CREATE TABLE default.integer256_source
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
"

"$CLICKHOUSE_BIN" local --path "$STORE" --query "
INSERT INTO default.integer256_source VALUES
    (1, CAST('0', 'Int256'), CAST('0', 'UInt256')),
    (2, CAST('-1', 'Int256'), CAST('1', 'UInt256')),
    (3, CAST('1', 'Int256'), CAST('115792089237316195423570985008687907853269984665640564039457584007913129639935', 'UInt256')),
    (4, CAST('-57896044618658097711785492504343953926634992332820282019728792003956564819968', 'Int256'), CAST('57896044618658097711785492504343953926634992332820282019728792003956564819968', 'UInt256')),
    (5, CAST('57896044618658097711785492504343953926634992332820282019728792003956564819967', 'Int256'), CAST('57896044618658097711785492504343953926634992332820282019728792003956564819969', 'UInt256')),
    (6, CAST('-42', 'Int256'), CAST('115792089237316195423570985008687907853269984665640564039457584007913129639934', 'UInt256')),
    (7, CAST('42', 'Int256'), CAST('57896044618658097711785492504343953926634992332820282019728792003956564819967', 'UInt256')),
    (8, CAST('-28948022309329048855892746252171976963317496166410141009864396001978282409984', 'Int256'), CAST('28948022309329048855892746252171976963317496166410141009864396001978282409984', 'UInt256')),
    (9, CAST('28948022309329048855892746252171976963317496166410141009864396001978282409984', 'Int256'), CAST('57896044618658097711785492504343953926634992332820282019728792003956564819970', 'UInt256')),
    (10, CAST('-123456789012345678901234567890123456789', 'Int256'), CAST('57896044618658097711785492504343953926634992332820282019728792003956564819967', 'UInt256')),
    (11, CAST('123456789012345678901234567890123456789', 'Int256'), CAST('115792089237316195423570985008687907853269984665640564039457584007913129639933', 'UInt256')),
    (12, CAST('-57896044618658097711785492504343953926634992332820282019728792003956564819968', 'Int256'), CAST('0', 'UInt256')),
    (13, CAST('57896044618658097711785492504343953926634992332820282019728792003956564819967', 'Int256'), CAST('42', 'UInt256'))
"

shape="$("$CLICKHOUSE_BIN" local --path "$STORE" --query "SELECT rows, marks, part_type FROM system.parts WHERE database = 'default' AND table = 'integer256_source' AND active FORMAT TabSeparated")"
if [[ "$shape" != $'13\t8\tWide' ]]; then
  printf 'expected 13 rows, 8 mark records, Wide; got %q\n' "$shape" >&2
  exit 1
fi
check="$("$CLICKHOUSE_BIN" local --path "$STORE" --query "CHECK TABLE default.integer256_source FORMAT TabSeparated")"
if [[ "$check" != $'all_1_1_0\t1\t' ]]; then
  printf 'CHECK TABLE failed: %q\n' "$check" >&2
  exit 1
fi

PART_PATH="$("$CLICKHOUSE_BIN" local --path "$STORE" --query "SELECT path FROM system.parts WHERE database = 'default' AND table = 'integer256_source' AND active FORMAT TSVRaw")"
[[ -d "$PART_PATH" && ! -L "$PART_PATH" ]] || { printf 'stock part not found\n' >&2; exit 1; }
[[ -z "$(find "$PART_PATH" -mindepth 1 -type l -print -quit)" ]] || { printf 'stock part contains symlinks\n' >&2; exit 1; }

mkdir -p "$OUT"
cp -R "$PART_PATH" "$OUT/part"
cat > "$OUT/PROVENANCE.md" <<'EOF'
# Public Wide raw Int256/UInt256 fixture

This fixture was produced by the pinned ClickHouse local 26.7.1.1315 official
build using `scripts/generate_public_wide_integer256_fixture.sh`. The `part/`
directory is a 13-row, three-column Wide part ordered by `pk UInt64`, with
non-nullable `i Int256` and `u UInt256` values, LZ4-compressed data streams,
plain `.mrk2` marks, `index_granularity = 2`, seven data marks, and a terminal
EOF sentinel. Signed and unsigned endpoints, limb crossovers, repeated endpoint
values, negative two's-complement values, and a large decimal pair are included.

Each Int256/UInt256 value occupies exactly 32 little-endian bytes. The fixture
was generated independently by ClickHouse and is verified against pinned
physical metadata, decompressed bytes, mark records, RowBinary bytes, and SQL
edge values by `scripts/verify_stock_wide_integer256_fixture.sh`.

`SHA256SUMS` lists every regular file below `part/`. The generator refuses to
replace an existing output directory; recreate only into a new output path.
EOF
(cd "$OUT" && find part -type f -print0 | sort -z | xargs -0 shasum -a 256 > SHA256SUMS)
printf 'generated %s with %s\n' "$OUT" "$ACTUAL_VERSION"
