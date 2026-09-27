#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/Users/sergey/.local/bin/clickhouse}"
FIXTURE_ROOT="$ROOT/test/fixtures/public/wide_array_enum_w48"
OUT="$FIXTURE_ROOT/part"
EXPECTED_VERSION='ClickHouse local version 26.7.1.1315 (official build).'

if [[ -e "$FIXTURE_ROOT" || -L "$FIXTURE_ROOT" ]]; then
  printf 'fixture exists; refusing to replace it: %s\n' "$FIXTURE_ROOT" >&2
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

TMP_ROOT="$(mktemp -d /private/tmp/crystal-click-array-enum-w48-fixture.XXXXXX)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT
STORE="$TMP_ROOT/store"
ENUM8="Enum8('min' = -128, 'neg' = -7, 'zero' = 0, 'pos' = 7, 'max' = 127)"
ENUM16="Enum16('min' = -32768, 'neg' = -300, 'zero' = 0, 'pos' = 300, 'max' = 32767)"
ENUM8_CAST="Enum8(\\'min\\' = -128, \\'neg\\' = -7, \\'zero\\' = 0, \\'pos\\' = 7, \\'max\\' = 127)"
ENUM16_CAST="Enum16(\\'min\\' = -32768, \\'neg\\' = -300, \\'zero\\' = 0, \\'pos\\' = 300, \\'max\\' = 32767)"

"$CLICKHOUSE_BIN" local --path "$STORE" --query "
CREATE TABLE source
(
    pk UInt64,
    plain8 Array($ENUM8),
    maybe8 Array(Nullable($ENUM8)),
    plain16 Array($ENUM16),
    maybe16 Array(Nullable($ENUM16))
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
    default_compression_codec = 'LZ4'
"

# Labels are mapped to independently asserted signed codes in the verifier and
# oracle. Values are synthetic and cover signed endpoints, zero, and signs.
"$CLICKHOUSE_BIN" local --path "$STORE" --query "
INSERT INTO source VALUES
    (1,
      CAST([], 'Array($ENUM8_CAST)'), CAST([], 'Array(Nullable($ENUM8_CAST))'),
      CAST([], 'Array($ENUM16_CAST)'), CAST([], 'Array(Nullable($ENUM16_CAST))')),
    (2,
      CAST(['min', 'neg', 'zero', 'pos', 'max'], 'Array($ENUM8_CAST)'),
      CAST([NULL, 'zero', 'min', 'max', 'pos'], 'Array(Nullable($ENUM8_CAST))'),
      CAST(['min', 'neg', 'zero', 'pos', 'max'], 'Array($ENUM16_CAST)'),
      CAST([NULL, 'zero', 'min', 'max', 'pos'], 'Array(Nullable($ENUM16_CAST))')),
    (4,
      CAST(['zero'], 'Array($ENUM8_CAST)'), CAST([NULL, NULL], 'Array(Nullable($ENUM8_CAST))'),
      CAST(['zero'], 'Array($ENUM16_CAST)'), CAST([NULL, NULL], 'Array(Nullable($ENUM16_CAST))')),
    (6,
      CAST([], 'Array($ENUM8_CAST)'), CAST([], 'Array(Nullable($ENUM8_CAST))'),
      CAST([], 'Array($ENUM16_CAST)'), CAST([], 'Array(Nullable($ENUM16_CAST))')),
    (9,
      CAST(['zero', 'neg'], 'Array($ENUM8_CAST)'),
      CAST(['pos', NULL, 'max'], 'Array(Nullable($ENUM8_CAST))'),
      CAST(['zero', 'neg'], 'Array($ENUM16_CAST)'),
      CAST(['pos', NULL, 'max'], 'Array(Nullable($ENUM16_CAST))')),
    (11,
      CAST(['max'], 'Array($ENUM8_CAST)'), CAST(['zero', NULL], 'Array(Nullable($ENUM8_CAST))'),
      CAST(['max'], 'Array($ENUM16_CAST)'), CAST(['zero', NULL], 'Array(Nullable($ENUM16_CAST))')),
    (13,
      CAST([], 'Array($ENUM8_CAST)'), CAST([], 'Array(Nullable($ENUM8_CAST))'),
      CAST([], 'Array($ENUM16_CAST)'), CAST([], 'Array(Nullable($ENUM16_CAST))'))
"

PART_PATH="$("$CLICKHOUSE_BIN" local --path "$STORE" --query "SELECT path FROM system.parts WHERE table = 'source' AND active FORMAT TSVRaw")"
[[ -d "$PART_PATH" && ! -L "$PART_PATH" ]] || { printf 'stock part not found\n' >&2; exit 1; }
INTEGRITY="$("$CLICKHOUSE_BIN" local --path "$STORE" --query "CHECK TABLE source FORMAT TabSeparated")"
[[ "$INTEGRITY" == $'all_1_1_0\t1\t' ]] || { printf 'stock CHECK TABLE failed: %q\n' "$INTEGRITY" >&2; exit 1; }

mkdir "$FIXTURE_ROOT"
cp -R "$PART_PATH" "$OUT"
(cd "$FIXTURE_ROOT" && shasum -a 256 part/* > SHA256SUMS)
printf 'generated pinned Enum Array fixture at %s\n' "$OUT"
printf 'rows per mark: [2, 2, 2, 1]; codec CODEC(LZ4); mark files .mrk2\n'
