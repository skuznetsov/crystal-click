#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/Users/sergey/.local/bin/clickhouse}"
OUT="${BOOL_ARRAY_FIXTURE_OUT:-$ROOT/test/fixtures/public/wide_array_bool/part}"
SERIALIZATION_VARIANT="${BOOL_ARRAY_SERIALIZATION_VARIANT:-empty}"
EXPECTED_VERSION='ClickHouse local version 26.7.1.1315 (official build).'

if [[ "$#" -ne 0 ]]; then
  printf 'usage: %s\n' "$0" >&2
  exit 2
fi
if [[ "$SERIALIZATION_VARIANT" == empty ]]; then
  SPARSE_SERIALIZATION_SETTING=$',\n    ratio_of_defaults_for_sparse_serialization = 1.0'
  EXPECTED_SERIALIZATION='{"columns":[],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1}'
elif [[ "$SERIALIZATION_VARIANT" == keyed ]]; then
  SPARSE_SERIALIZATION_SETTING=''
  EXPECTED_SERIALIZATION='{"columns":[{"kind":"Default","name":"pk","num_defaults":0,"num_rows":13}],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1}'
else
  printf 'unsupported BOOL_ARRAY_SERIALIZATION_VARIANT: %s\n' "$SERIALIZATION_VARIANT" >&2
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

TMP_ROOT="$(mktemp -d /private/tmp/crystal-click-bool-array-fixture.XXXXXX)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT
STORE="$TMP_ROOT/store"

"$CLICKHOUSE_BIN" local --path "$STORE" --query "
CREATE TABLE source
(
    pk UInt64,
    plain Array(Bool),
    maybe Array(Nullable(Bool))
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
    max_compress_block_size = 4096${SPARSE_SERIALIZATION_SETTING},
    default_compression_codec = 'LZ4'
"

"$CLICKHOUSE_BIN" local --path "$STORE" --query "
INSERT INTO source VALUES
    (1, CAST([], 'Array(Bool)'), CAST([], 'Array(Nullable(Bool))')),
    (2, [false, true], CAST([NULL, false, true], 'Array(Nullable(Bool))')),
    (4, [true], [false, NULL]),
    (6, CAST([], 'Array(Bool)'), [true]),
    (9, [false], CAST([], 'Array(Nullable(Bool))')),
    (11, [true, false], [NULL, true]),
    (13, CAST([], 'Array(Bool)'), [false]),
    (17, [true], [NULL, false]),
    (19, [false, true], CAST([], 'Array(Nullable(Bool))')),
    (21, CAST([], 'Array(Bool)'), [false, NULL]),
    (25, [false], [true]),
    (31, [true], [NULL]),
    (40, [false, false], [true, NULL])
"

PART_PATH="$("$CLICKHOUSE_BIN" local --path "$STORE" --query "SELECT path FROM system.parts WHERE table = 'source' AND active FORMAT TSVRaw")"
[[ -d "$PART_PATH" && ! -L "$PART_PATH" ]] || { printf 'stock part not found\n' >&2; exit 1; }
INTEGRITY="$("$CLICKHOUSE_BIN" local --path "$STORE" --query "CHECK TABLE source FORMAT TabSeparated")"
[[ "$INTEGRITY" == $'all_1_1_0\t1\t' ]] || { printf 'stock CHECK TABLE failed: %q\n' "$INTEGRITY" >&2; exit 1; }
cmp -s "$PART_PATH/columns.txt" <(printf 'columns format version: 1\n3 columns:\n`pk` UInt64\n`plain` Array(Bool)\n`maybe` Array(Nullable(Bool))\n') || {
  printf 'unexpected stock Bool array column metadata\n' >&2
  exit 1
}
cmp -s "$PART_PATH/columns_substreams.txt" <(printf 'columns substreams version: 1\n3 columns:\n1 substreams for column `pk`:\n\tpk\n2 substreams for column `plain`:\n\tplain.size0\n\tplain\n3 substreams for column `maybe`:\n\tmaybe.size0\n\tmaybe.null\n\tmaybe\n') || {
  printf 'unexpected stock Bool array substreams\n' >&2
  exit 1
}
[[ "$(<"$PART_PATH/count.txt")" == 13 ]] || { printf 'unexpected stock row count\n' >&2; exit 1; }
[[ "$(<"$PART_PATH/serialization.json")" == "$EXPECTED_SERIALIZATION" ]] || {
  printf 'stock serializer metadata differs from requested %s variant\n' "$SERIALIZATION_VARIANT" >&2
  exit 1
}
[[ -z "$(find "$PART_PATH" -mindepth 1 -type l -print -quit)" ]] || { printf 'stock part contains symlinks\n' >&2; exit 1; }

mkdir -p "$(dirname -- "$OUT")"
cp -R "$PART_PATH" "$OUT"
FIXTURE_ROOT="$(dirname -- "$OUT")"
(cd "$FIXTURE_ROOT" && find "$(basename -- "$OUT")" -type f -print0 | sort -z | xargs -0 shasum -a 256 > SHA256SUMS)
printf 'generated %s\n' "$OUT"
