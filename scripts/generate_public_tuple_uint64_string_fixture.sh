#!/usr/bin/env bash
set -euo pipefail

CLICKHOUSE="${CLICKHOUSE:-/Users/sergey/.local/bin/clickhouse}"
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUT="${W23_TUPLE_FIXTURE_OUT:-$ROOT/test/fixtures/public/wide_tuple_uint64_string/part}"
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
  local expected_data_digest='10170f463e3d68beaa9e08cc930f07448b78534d48d7f1199b7900f503d56b41'
  local actual_data_digest
  [[ -d "$dir" && ! -L "$dir" ]] || { printf 'missing or invalid fixture directory: %s\n' "$dir" >&2; return 1; }
  [[ -z "$(find "$dir" -mindepth 1 \( -type l -o ! -type f \) -print -quit)" ]] || return 1
  [[ "$(<"$dir/count.txt")" == 5 ]] || return 1
  cmp -s "$dir/columns.txt" <(printf 'columns format version: 1\n2 columns:\n`id` UInt64\n`payload` Tuple(a UInt64, b String)\n') || return 1
  cmp -s "$dir/columns_substreams.txt" <(printf 'columns substreams version: 1\n2 columns:\n1 substreams for column `id`:\n\tid\n3 substreams for column `payload`:\n\tpayload%%2Ea\n\tpayload%%2Eb.size\n\tpayload%%2Eb\n') || return 1
  cmp -s "$dir/serialization.json" <(printf '{"columns":[{"kind":"Default","name":"id","num_defaults":0,"num_rows":5},{"kind":"Default","name":"payload","num_defaults":1,"num_rows":5,"subcolumns":[{"kind":"Default","num_defaults":1,"num_rows":5},{"kind":"Default","num_defaults":2,"num_rows":5}]}],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1}') || return 1
  actual_data_digest="$(cd "$dir" && shasum -a 256 ./*.bin | shasum -a 256 | awk '{print $1}')"
  [[ "$actual_data_digest" == "$expected_data_digest" ]] || { printf 'fixture stream data digest mismatch\n' >&2; return 1; }
  grep -Fxq 'CODEC(LZ4)' "$dir/default_compression_codec.txt" || return 1
  [[ "$(find "$dir" -maxdepth 1 -type f -name '*.bin' -print | wc -l | tr -d ' ')" == 4 ]] || return 1
  [[ "$(find "$dir" -maxdepth 1 -type f -name '*.mrk2' -print | wc -l | tr -d ' ')" == 4 ]] || return 1
  [[ "$(find "$dir" -maxdepth 1 -type f -name '*.cmrk2' -print | wc -l | tr -d ' ')" == 0 ]] || return 1
  [[ "$(find "$dir" -maxdepth 1 -type f \( -name '*.mrk' -o -name '*.mrk3' -o -name '*.mrk4' -o -name '*.cmrk' \) -print | wc -l | tr -d ' ')" == 0 ]] || return 1
  while IFS= read -r mark; do
    [[ "$(wc -c < "$mark" | tr -d ' ')" == 96 ]] || return 1
  done < <(find "$dir" -maxdepth 1 -type f -name '*.mrk2' -print)
}

if ((CHECK == 1)); then
  check_shape "$OUT"
  printf 'fixture shape: ClickHouse Wide Tuple(a UInt64, b String), LZ4, 5 rows, four independent .mrk2 streams\n'
  exit 0
fi

if [[ ! -x "$CLICKHOUSE" ]]; then
  printf 'clickhouse executable not found; set CLICKHOUSE to the pinned binary\n' >&2
  exit 1
fi

EXPECTED_VERSION='ClickHouse local version 26.7.1.1315 (official build).'
ACTUAL_VERSION="$("$CLICKHOUSE" local --version)"
if [[ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]]; then
  printf 'fixture producer mismatch: expected %s, got %s\n' "$EXPECTED_VERSION" "$ACTUAL_VERSION" >&2
  exit 1
fi

if [[ -e "$OUT" ]]; then
  printf 'fixture exists; refusing to replace it: %s\n' "$OUT" >&2
  exit 2
fi

TMP_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/crystal-click-tuple-fixture.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT
STORE="$TMP_ROOT/store"
mkdir -p "$(dirname -- "$OUT")"

"$CLICKHOUSE" local --path "$STORE" --query "
CREATE TABLE source
(
    \`id\` UInt64,
    \`payload\` Tuple(a UInt64, b String)
)
ENGINE = MergeTree
ORDER BY id
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

"$CLICKHOUSE" local --path "$STORE" --query "
INSERT INTO source
SELECT
    toUInt64(number + 1),
    tuple(
        multiIf(number = 1, toUInt64('18446744073709551615'), toUInt64(number)),
        multiIf(
            number = 0, '',
            number = 1, 'short',
            number = 2, unhex('410042FF'),
            number = 3, 'a much longer payload crossing offsets',
            ''
        )
    )
FROM numbers(5)
"

PART_PATH="$("$CLICKHOUSE" local --path "$STORE" --query "SELECT path FROM system.parts WHERE table = 'source' AND active FORMAT TSVRaw")"
[[ -n "$PART_PATH" ]] || { printf 'ClickHouse did not report a part path\n' >&2; exit 1; }
STAGED="$TMP_ROOT/part"
cp -R "$PART_PATH" "$STAGED"
check_shape "$STAGED"

mv "$STAGED" "$OUT"
printf 'generated %s\n' "$OUT"
