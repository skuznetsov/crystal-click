#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/Users/sergey/.local/bin/clickhouse}"
FIXTURE_ROOT="$ROOT/test/fixtures/public/wide_time_w50"
OUT="$FIXTURE_ROOT/part"
EXPECTED_VERSION='ClickHouse local version 26.7.1.1315 (official build).'

if [[ -e "$OUT" || -L "$OUT" ]]; then
  printf 'fixture part exists; refusing to replace it: %s\n' "$OUT" >&2
  exit 2
fi
[[ ! -L "$FIXTURE_ROOT" ]] || { printf 'fixture root must not be a symlink: %s\n' "$FIXTURE_ROOT" >&2; exit 2; }
[[ -f "$FIXTURE_ROOT/PROVENANCE.md" && ! -L "$FIXTURE_ROOT/PROVENANCE.md" ]] || {
  printf 'fixture provenance must exist before generation\n' >&2
  exit 2
}
if [[ ! -x "$CLICKHOUSE_BIN" ]]; then
  printf 'ClickHouse executable not found: %s\n' "$CLICKHOUSE_BIN" >&2
  exit 1
fi
ACTUAL_VERSION="$("$CLICKHOUSE_BIN" local --version)"
if [[ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]]; then
  printf 'fixture producer mismatch: expected %s, got %s\n' "$EXPECTED_VERSION" "$ACTUAL_VERSION" >&2
  exit 1
fi

TMP_ROOT="$(mktemp -d /private/tmp/crystal-click-time-w50-fixture.XXXXXX)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT
STORE="$TMP_ROOT/store"

"$CLICKHOUSE_BIN" local --path "$STORE" --query "
CREATE TABLE source
(
    pk UInt64,
    t Time,
    nt Nullable(Time),
    a Array(Time),
    an Array(Nullable(Time)),
    t64_0 Time64(0),
    t64_3 Time64(3),
    t64_9 Time64(9),
    nt64_3 Nullable(Time64(3)),
    a64_3 Array(Time64(3)),
    an64_3 Array(Nullable(Time64(3)))
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

# Time inputs are signed integer seconds. Time64 inputs are signed decimal
# seconds; expected physical ticks are independently fixed in the W50 spec and
# stock RowBinary oracle, rather than derived by re-reading these columns.
"$CLICKHOUSE_BIN" local --path "$STORE" --query "
INSERT INTO source VALUES
    (1, -3723, NULL, [], [], -1, -1.234, -1.234567891, NULL, [], []),
    (2, 0, -3723, [-1, 0, 1], [NULL, -1, 0], 0, 0, 0, -1.234, [-1.234, 0.001, 1.234], [NULL, -1.234, 0.001]),
    (4, 1, 0, [52225], [NULL, NULL], 1, 1.234, 1.234567891, 0, [59.123], [NULL, NULL]),
    (6, 59, 1, [], [], 59, -0.001, -0.000000001, 1.234, [], []),
    (9, 60, NULL, [-2, 59], [59], 3600, 59.123, 59.123456789, NULL, [-0.001, 0], [59.123]),
    (11, 52225, 3600, [3600], [NULL, 1, NULL], 3600, 3600.999, 3600.999999999, 3600.999, [1.234], [NULL, 1.234, NULL]),
    (13, -1, -1, [], [], -3723, -3723.456, -3723.456789123, -3723.456, [], [])
"

PART_PATH="$("$CLICKHOUSE_BIN" local --path "$STORE" --query "SELECT path FROM system.parts WHERE table = 'source' AND active FORMAT TSVRaw")"
[[ -d "$PART_PATH" && ! -L "$PART_PATH" ]] || { printf 'stock part not found\n' >&2; exit 1; }
INTEGRITY="$("$CLICKHOUSE_BIN" local --path "$STORE" --query "CHECK TABLE source FORMAT TabSeparated")"
[[ "$INTEGRITY" == $'all_1_1_0\t1\t' ]] || { printf 'stock CHECK TABLE failed: %q\n' "$INTEGRITY" >&2; exit 1; }

mkdir "$OUT"
cp -R "$PART_PATH". "$OUT"/
(cd "$FIXTURE_ROOT" && shasum -a 256 part/* > SHA256SUMS)
bash "$ROOT/scripts/verify_stock_wide_time_w50_fixture.sh"
printf 'generated pinned Time/Time64 fixture at %s\n' "$OUT"
printf 'rows per mark: [2, 2, 2, 1]; codec CODEC(LZ4); 19 paired .mrk2 streams\n'
