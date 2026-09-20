#!/usr/bin/env bash
set -euo pipefail

# Generate a deterministic public Wide part for the real-reader benchmark.
# The output directory is explicit and --force is accepted only for a fixture
# carrying this generator's ownership marker. Generated data stays outside git.

ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CLICKHOUSE="${CLICKHOUSE:-$(command -v clickhouse || true)}"
ROWS=10000000
FORCE=0
CHECK=0
OUT_INPUT=''

MARKER_NAME='.crystal-click-real-reader-benchmark-fixture'
MARKER_CONTENT='crystal-click-real-reader-benchmark-fixture-v1'
EXPECTED_VERSION='ClickHouse local version 26.7.1.1315 (official build).'
MAX_ROWS=100000000

usage() {
  printf 'usage: %s OUTPUT_DIR [--rows ROWS] [--force] [--check]\n' "${BASH_SOURCE[0]}" >&2
  printf 'default rows: 10000000; column: value; codec: Delta(8), ZSTD(1)\n' >&2
}

die() {
  printf 'generate_real_reader_benchmark_fixture: %s\n' "$*" >&2
  exit 1
}

is_positive_integer() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

while (($# > 0)); do
  case "$1" in
    --rows)
      (($# >= 2)) || { usage; exit 64; }
      ROWS="$2"
      shift 2
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --check)
      CHECK=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --*)
      usage
      exit 64
      ;;
    *)
      [[ -z "$OUT_INPUT" ]] || { usage; exit 64; }
      OUT_INPUT="$1"
      shift
      ;;
  esac
done

[[ -n "$OUT_INPUT" ]] || { usage; exit 64; }
is_positive_integer "$ROWS" || die '--rows must be a positive integer'
(( 10#$ROWS <= MAX_ROWS )) || die "--rows exceeds reader limit ${MAX_ROWS}"
if (( CHECK == 1 && FORCE == 1 )); then
  die '--check and --force cannot be combined'
fi

if [[ "$OUT_INPUT" = /* ]]; then
  OUT="$OUT_INPUT"
else
  OUT="$PWD/$OUT_INPUT"
fi
OUT="${OUT%/}"
[[ -n "$OUT" && "$OUT" != '/' && "$OUT" != "$ROOT" ]] || die 'unsafe output directory'
out_parent="$(dirname -- "$OUT")"
out_name="$(basename -- "$OUT")"
[[ -n "$out_name" && "$out_name" != '/' && "$out_name" != '.' && "$out_name" != '..' ]] || die 'invalid output directory'
mkdir -p -- "$out_parent"
out_parent="$(cd "$out_parent" && pwd)"
OUT="$out_parent/$out_name"

checksum_for_rows() {
  python3 - "$1" <<'PY'
import sys
rows = int(sys.argv[1])
mask = (1 << 64) - 1
multiplier = 0x94d049bb133111eb
checksum = 0
for value in range(rows):
    checksum = ((checksum * multiplier) & mask) ^ value
print(checksum)
PY
}

EXPECTED_CHECKSUM="$(checksum_for_rows "$ROWS")"

check_owned_output() {
  local directory="$1"
  [[ -d "$directory" && ! -L "$directory" ]] || die 'existing output is not a real directory'
  [[ -f "$directory/$MARKER_NAME" && ! -L "$directory/$MARKER_NAME" ]] || die 'existing output is not owned by this generator; refusing deletion'
  cmp -s "$directory/$MARKER_NAME" <(printf '%s\n' "$MARKER_CONTENT") || die 'existing output marker is not recognized; refusing deletion'
}

if [[ -e "$OUT" || -L "$OUT" ]]; then
  check_owned_output "$OUT"
  if (( CHECK == 0 && FORCE == 0 )); then
    die 'output exists; use --force only for an owned fixture'
  fi
fi

TMP_ROOT=''
STAGING_ROOT=''
cleanup() {
  if [[ -n "$TMP_ROOT" && -d "$TMP_ROOT" && ! -L "$TMP_ROOT" ]]; then
    rm -rf -- "$TMP_ROOT"
  fi
  if [[ -n "$STAGING_ROOT" && -d "$STAGING_ROOT" && ! -L "$STAGING_ROOT" ]]; then
    rm -rf -- "$STAGING_ROOT"
  fi
}
trap cleanup EXIT

validate_fixture() {
  local directory="$1"
  local expected_rows="$2"
  python3 - "$directory" "$expected_rows" "$MARKER_NAME" "$MARKER_CONTENT" <<'PY'
from pathlib import Path
import struct
import sys

root = Path(sys.argv[1])
expected_rows = int(sys.argv[2])
marker_name = sys.argv[3]
marker_content = sys.argv[4].encode()


def fail(message):
    raise SystemExit(f"fixture validation error: {message}")


if not root.is_dir() or root.is_symlink():
    fail("missing or invalid output directory")
if (root / marker_name).read_bytes() != marker_content + b"\n":
    fail("ownership marker is missing or invalid")

bin_files = sorted(root.glob("*.bin"))
cmrk_files = sorted(root.glob("*.cmrk2"))
if len(bin_files) != 1:
    fail(f"expected one .bin file, found {len(bin_files)}")
if len(cmrk_files) != 1:
    fail(f"expected one .cmrk2 file, found {len(cmrk_files)}")
if list(root.glob("*.mrk2")):
    fail("legacy .mrk2 marks are not allowed")

def read(name):
    path = root / name
    if not path.is_file():
        fail(f"missing metadata file {name}")
    return path.read_bytes()

if read("count.txt").strip() != str(expected_rows).encode():
    fail("count.txt row count mismatch")
if read("columns.txt") != b"columns format version: 1\n1 columns:\n`value` UInt64\n":
    fail("columns.txt is not one UInt64 value column")
if read("columns_substreams.txt") != (
    b"columns substreams version: 1\n"
    b"1 columns:\n"
    b"1 substreams for column `value`:\n"
    b"\tvalue\n"
):
    fail("columns_substreams.txt does not describe value")
if read("default_compression_codec.txt") != b"CODEC(ZSTD(1))":
    fail("default codec mismatch")
if not read("checksums.txt").strip():
    fail("checksums.txt is empty")

def u32(data, offset):
    if offset < 0 or offset + 4 > len(data):
        fail(f"truncated frame field at {offset}")
    return struct.unpack_from("<I", data, offset)[0]

def frames(path, method):
    data = path.read_bytes()
    offset = 0
    result = []
    while offset < len(data):
        if len(data) - offset < 25:
            fail(f"truncated frame header in {path.name}")
        if data[offset + 16] != method:
            fail(f"unexpected method in {path.name}")
        compressed_size = u32(data, offset + 17)
        decompressed_size = u32(data, offset + 21)
        if compressed_size < 9 or decompressed_size == 0:
            fail(f"invalid frame size in {path.name}")
        end = offset + 16 + compressed_size
        if end > len(data):
            fail(f"truncated frame payload in {path.name}")
        result.append((offset, compressed_size, decompressed_size, end))
        offset = end
    if not result:
        fail(f"empty {path.name}")
    return data, result

data, data_frames = frames(bin_files[0], 0x91)
decoded_data_bytes = sum(frame[2] for frame in data_frames)
if decoded_data_bytes != expected_rows * 8:
    fail("data frames do not cover expected UInt64 bytes")
if expected_rows == 10_000_000 and decoded_data_bytes < 64 * 1024 * 1024:
    fail("default fixture data is smaller than 64 MiB decoded")
for offset, compressed_size, decoded_size, frame_end in data_frames:
    payload = offset + 16 + 9
    payload_end = offset + 16 + compressed_size
    if payload >= payload_end:
        fail("empty Multiple payload")
    codec_count = data[payload]
    methods_end = payload + 1 + codec_count
    if methods_end > payload_end or data[payload + 1:methods_end] != bytes((0x92, 0x90)):
        fail("data frame is not Multiple[Delta,ZSTD]")
    nested = methods_end
    if nested + 9 > payload_end or data[nested] != 0x90:
        fail("data frame has no nested ZSTD stage")
    nested_compressed = u32(data, nested + 1)
    nested_decoded = u32(data, nested + 5)
    if nested_decoded != decoded_size + 11 or nested + nested_compressed != frame_end:
        fail("nested Delta/ZSTD frame size mismatch")

_, mark_frames = frames(cmrk_files[0], 0x90)
mark_records = sum(frame[2] for frame in mark_frames)
if mark_records == 0 or mark_records % 24 != 0:
    fail("compressed marks do not contain whole records")

print(f"data_bytes={bin_files[0].stat().st_size}")
print(f"mark_bytes={cmrk_files[0].stat().st_size}")
PY
}

if (( CHECK == 1 )); then
  check_owned_output "$OUT"
  shape_output="$(validate_fixture "$OUT" "$ROWS")"
  printf 'fixture_path=%s\n' "$OUT"
  printf 'column=value\n'
  printf 'rows=%s\n' "$ROWS"
  printf 'checksum=%s\n' "$EXPECTED_CHECKSUM"
  printf '%s\n' "$shape_output"
  exit 0
fi

[[ -n "$CLICKHOUSE" && -x "$CLICKHOUSE" ]] || die 'clickhouse executable not found; set CLICKHOUSE or add it to PATH'
actual_version="$("$CLICKHOUSE" local --version)"
[[ "$actual_version" == "$EXPECTED_VERSION" ]] || die "fixture producer mismatch: expected $EXPECTED_VERSION, got $actual_version"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/crystal-click-real-reader-fixture.XXXXXX")"
STAGING_ROOT="$(mktemp -d "$out_parent/.crystal-click-real-reader-fixture.XXXXXX")"
STORE="$TMP_ROOT/store"
mkdir -p -- "$STORE"

"$CLICKHOUSE" local --path "$STORE" --query "
CREATE TABLE source
(
    \`value\` UInt64 CODEC(Delta(8), ZSTD(1))
)
ENGINE = MergeTree
ORDER BY tuple()
SETTINGS
    min_rows_for_wide_part = 0,
    min_bytes_for_wide_part = 0,
    enable_mixed_granularity_parts = 1,
    index_granularity = 8192,
    compress_marks = 1,
    marks_compression_codec = 'ZSTD(1)',
    marks_compress_block_size = 256,
    min_compress_block_size = 0,
    max_compress_block_size = 65536,
    default_compression_codec = 'ZSTD(1)';

INSERT INTO source SELECT toUInt64(number) FROM numbers($ROWS);
OPTIMIZE TABLE source FINAL;
"

part_summary="$("$CLICKHOUSE" local --path "$STORE" --query "SELECT count(), coalesce(sum(rows), 0) FROM system.parts WHERE table = 'source' AND active FORMAT TSVRaw" | tr -d '\r\n')"
expected_part_summary=$'1\t'"$ROWS"
[[ "$part_summary" == "$expected_part_summary" ]] || die "expected one active part with $ROWS rows, got: $part_summary"

part_path="$("$CLICKHOUSE" local --path "$STORE" --query "SELECT path FROM system.parts WHERE table = 'source' AND active FORMAT TSVRaw" | tr -d '\r\n')"
[[ -n "$part_path" && -d "$part_path" && ! -L "$part_path" ]] || die 'ClickHouse did not report a valid active part path'

staged_part="$STAGING_ROOT/part"
cp -R -- "$part_path" "$staged_part"
printf '%s\n' "$MARKER_CONTENT" > "$staged_part/$MARKER_NAME"
shape_output="$(validate_fixture "$staged_part" "$ROWS")"

if [[ -e "$OUT" || -L "$OUT" ]]; then
  check_owned_output "$OUT"
  (( FORCE == 1 )) || die 'output appeared during generation; refusing replacement'
  rm -rf -- "$OUT"
fi
mv -- "$staged_part" "$OUT"

printf 'fixture_path=%s\n' "$OUT"
printf 'column=value\n'
printf 'rows=%s\n' "$ROWS"
printf 'checksum=%s\n' "$EXPECTED_CHECKSUM"
printf '%s\n' "$shape_output"
