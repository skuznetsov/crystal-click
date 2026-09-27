#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/Users/sergey/.local/bin/clickhouse}"
FIXTURE_ROOT="$ROOT/test/fixtures/public/wide_bfloat16_w49"
OUT="$FIXTURE_ROOT/part"
EXPECTED_VERSION='ClickHouse local version 26.7.1.1315 (official build).'

if [[ -e "$FIXTURE_ROOT/part" || -L "$FIXTURE_ROOT/part" ]]; then
  printf 'fixture part exists; refusing to replace it: %s\n' "$FIXTURE_ROOT/part" >&2
  exit 2
fi
[[ ! -L "$FIXTURE_ROOT" ]] || { printf 'fixture root must not be a symlink: %s\n' "$FIXTURE_ROOT" >&2; exit 2; }
if [[ ! -x "$CLICKHOUSE_BIN" ]]; then
  printf 'ClickHouse executable not found: %s\n' "$CLICKHOUSE_BIN" >&2
  exit 1
fi
ACTUAL_VERSION="$("$CLICKHOUSE_BIN" local --version)"
if [[ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]]; then
  printf 'fixture producer mismatch: expected %s, got %s\n' "$EXPECTED_VERSION" "$ACTUAL_VERSION" >&2
  exit 1
fi

TMP_ROOT="$(mktemp -d /private/tmp/crystal-click-bfloat16-w49-fixture.XXXXXX)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT
STORE="$TMP_ROOT/store"

"$CLICKHOUSE_BIN" local --path "$STORE" --query "
CREATE TABLE source
(
    pk UInt64,
    scalar BFloat16,
    maybe Nullable(BFloat16),
    plain Array(BFloat16),
    nullable_array Array(Nullable(BFloat16))
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

# Values are synthesized from exact binary32 bit patterns whose low 16 bits
# are zero. BFloat16 conversion therefore has no rounding ambiguity, even for
# distinct NaN payloads and signed zero.
"$CLICKHOUSE_BIN" local --path "$STORE" --query "
INSERT INTO source VALUES
    (1, toBFloat16(reinterpretAsFloat32(toUInt32(0x00000000))), NULL,
      CAST([], 'Array(BFloat16)'), CAST([], 'Array(Nullable(BFloat16))')),
    (2, toBFloat16(reinterpretAsFloat32(toUInt32(0x80000000))),
      toBFloat16(reinterpretAsFloat32(toUInt32(0x80000000))),
      [toBFloat16(reinterpretAsFloat32(toUInt32(0x80000000))), toBFloat16(reinterpretAsFloat32(toUInt32(0x7fc10000))), toBFloat16(reinterpretAsFloat32(toUInt32(0xffe20000)))],
      [NULL, toBFloat16(reinterpretAsFloat32(toUInt32(0x80000000))), toBFloat16(reinterpretAsFloat32(toUInt32(0x7fc10000)))]),
    (4, toBFloat16(reinterpretAsFloat32(toUInt32(0x3f800000))),
      toBFloat16(reinterpretAsFloat32(toUInt32(0x7fc20000))),
      [toBFloat16(reinterpretAsFloat32(toUInt32(0x00010000)))], [NULL, NULL]),
    (6, toBFloat16(reinterpretAsFloat32(toUInt32(0x00010000))), NULL,
      CAST([], 'Array(BFloat16)'), CAST([], 'Array(Nullable(BFloat16))')),
    (9, toBFloat16(reinterpretAsFloat32(toUInt32(0x7f7f0000))),
      toBFloat16(reinterpretAsFloat32(toUInt32(0x80010000))),
      [toBFloat16(reinterpretAsFloat32(toUInt32(0x7f7f0000))), toBFloat16(reinterpretAsFloat32(toUInt32(0xff800000))), toBFloat16(reinterpretAsFloat32(toUInt32(0x00800000)))],
      [toBFloat16(reinterpretAsFloat32(toUInt32(0x7fe20000))), NULL, toBFloat16(reinterpretAsFloat32(toUInt32(0x3f800000)))]),
    (11, toBFloat16(reinterpretAsFloat32(toUInt32(0x7fc10000))), NULL,
      [toBFloat16(reinterpretAsFloat32(toUInt32(0x7fe20000)))],
      [NULL, toBFloat16(reinterpretAsFloat32(toUInt32(0x80010000))), NULL]),
    (13, toBFloat16(reinterpretAsFloat32(toUInt32(0xffe20000))),
      toBFloat16(reinterpretAsFloat32(toUInt32(0x7fc10000))),
      CAST([], 'Array(BFloat16)'), CAST([], 'Array(Nullable(BFloat16))'))
"

PART_PATH="$("$CLICKHOUSE_BIN" local --path "$STORE" --query "SELECT path FROM system.parts WHERE table = 'source' AND active FORMAT TSVRaw")"
[[ -d "$PART_PATH" && ! -L "$PART_PATH" ]] || { printf 'stock part not found\n' >&2; exit 1; }
INTEGRITY="$("$CLICKHOUSE_BIN" local --path "$STORE" --query "CHECK TABLE source FORMAT TabSeparated")"
[[ "$INTEGRITY" == $'all_1_1_0\t1\t' ]] || { printf 'stock CHECK TABLE failed: %q\n' "$INTEGRITY" >&2; exit 1; }

mkdir -p "$FIXTURE_ROOT"
cp -R "$PART_PATH" "$OUT"
(cd "$FIXTURE_ROOT" && shasum -a 256 part/* > SHA256SUMS)
[[ -f "$FIXTURE_ROOT/PROVENANCE.md" && ! -L "$FIXTURE_ROOT/PROVENANCE.md" ]] || { printf 'fixture provenance must exist before generation\n' >&2; exit 1; }
bash "$ROOT/scripts/verify_stock_wide_bfloat16_w49_fixture.sh"
printf 'generated pinned BFloat16 fixture at %s\n' "$OUT"
printf 'rows per mark: [2, 2, 2, 1]; codec CODEC(LZ4); mark files .mrk2\n'
