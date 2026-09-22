#!/usr/bin/env bash
set -euo pipefail

# Bounded decode-and-aggregate execution benchmark.  Each timed observation is
# a fresh release child.  The source is the public/generated single UInt64 Wide-part
# contract whose rows are exactly 0..rows-1; the runner derives expected
# count/sum/min/max independently before accepting any child result.
#
# Cache labels are deliberately limited to warm_shared and natural_unknown.
# This runner never flushes caches and never makes a cold-cache claim.

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(CDPATH= cd -- "$script_dir/.." && pwd)"

MAX_REPETITIONS=1000
MAX_ROWS=1000000000
MAX_SCRATCH_SIZE=65536
MIN_CONTROLLED_BYTES=$((64 * 1024 * 1024))

smoke=false
if [[ "${1:-}" == "--smoke" ]]; then
  smoke=true
  shift
fi

if [[ "$smoke" == true ]]; then
  (( $# == 0 )) || {
    printf 'usage: %s [--smoke]\n' "${BASH_SOURCE[0]}" >&2
    exit 64
  }
  fixture="$root_dir/test/fixtures/public/wide_u64_lz4/part"
  : "${BENCH_REPETITIONS:=1}"
  : "${BENCH_SCRATCH_SIZES:=73}"
else
  (( $# == 1 )) || {
    printf 'usage: %s FIXTURE_PART\n' "${BASH_SOURCE[0]}" >&2
    printf 'controlled mode requires a generated/public UInt64 Wide part with at least 64 MiB decoded\n' >&2
    exit 64
  }
  fixture="$1"
  : "${BENCH_REPETITIONS:=7}"
  : "${BENCH_SCRATCH_SIZES:=4096 8191}"
fi
: "${BENCH_CACHE_REGIME:=natural_unknown}"

: "${BENCH_DELTA_BACKEND:=scalar}"

die() {
  printf 'bench_uint64_execution_pipeline: %s\n' "$*" >&2
  exit 1
}

delta_backend_flags=()
delta_backend_compile_flags=-Ddelta_scalar
delta_backend_effective="$BENCH_DELTA_BACKEND"
case "$BENCH_DELTA_BACKEND" in
  neon)
    delta_backend_flags=(-Ddelta_neon)
    delta_backend_compile_flags=-Ddelta_neon
    # The NEON selector is admitted only on AArch64.  On other targets the
    # checked decoder retains its portable scalar fallback.
    case "$(uname -m 2>/dev/null || true)" in
      arm64|aarch64) ;;
      *) delta_backend_effective=scalar_fallback ;;
    esac
    ;;
  scalar)
    delta_backend_flags=(-Ddelta_scalar)
    delta_backend_compile_flags=-Ddelta_scalar
    ;;
  byte_scalar)
    delta_backend_flags=(-Ddelta_byte_scalar)
    delta_backend_compile_flags=-Ddelta_byte_scalar
    ;;
  *) die "BENCH_DELTA_BACKEND must be neon, scalar, or byte_scalar" ;;
esac

is_nonnegative_integer() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

is_positive_integer() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

decimal_leq() {
  local value="$1"
  local limit="$2"
  is_nonnegative_integer "$value" || return 1
  while [[ ${#value} -gt 1 && ${value:0:1} == 0 ]]; do value="${value:1}"; done
  while [[ ${#limit} -gt 1 && ${limit:0:1} == 0 ]]; do limit="${limit:1}"; done
  if (( ${#value} < ${#limit} )); then return 0; fi
  if (( ${#value} > ${#limit} )); then return 1; fi
  [[ "$value" == "$limit" || "$value" < "$limit" ]]
}

normalize_decimal() {
  local value="$1"
  while [[ ${#value} -gt 1 && ${value:0:1} == 0 ]]; do value="${value:1}"; done
  printf '%s' "$value"
}

is_bounded_positive_integer() {
  is_positive_integer "$1" && decimal_leq "$1" "$2"
}

[[ -d "$fixture" && ! -L "$fixture" ]] || die "fixture part is missing or symbolic"
fixture="$(cd "$fixture" && pwd)" || die "fixture path is unavailable"
[[ "$fixture" != / && "$fixture" != "$root_dir" ]] || die "fixture path is unsafe"
[[ -f "$fixture/count.txt" && -f "$fixture/columns.txt" ]] || die "fixture metadata is incomplete"
[[ -f "$fixture/columns_substreams.txt" ]] || die "fixture substream metadata is missing"

link_entry="$(find "$fixture" -type l -print -quit 2>/dev/null || true)"
[[ -z "$link_entry" ]] || die "fixture contains a symbolic link"

fixture_rows_raw="$(tr -d '\r\n' < "$fixture/count.txt")" || die "fixture row count cannot be read"
is_bounded_positive_integer "$fixture_rows_raw" "$MAX_ROWS" || die "fixture row count is outside the bounded range"
fixture_rows="$(normalize_decimal "$fixture_rows_raw")"

# The generated fixture producer and the committed public smoke fixture both
# describe one exact UInt64 value column.  The benchmark child performs the
# authoritative decoder checks; these cheap metadata checks fail closed early.
grep -Fqx '1 columns:' "$fixture/columns.txt" || die "fixture is not a one-column part"
grep -Fqx '`value` UInt64' "$fixture/columns.txt" || die "fixture does not expose the value UInt64 column"

decoded_bytes=$(( fixture_rows * 8 ))
threshold_met=false
if (( decoded_bytes >= MIN_CONTROLLED_BYTES )); then
  threshold_met=true
fi
if [[ "$smoke" != true && "$threshold_met" != true ]]; then
  die "controlled fixture must contain at least 64 MiB decoded"
fi

# This benchmark is intentionally scoped to the deterministic generated
# sequence 0..rows-1.  Keep the expected aggregate outside the Crystal child
# so an implementation bug cannot manufacture its own oracle.
expected_count="$fixture_rows"
expected_sum=$(( fixture_rows * (fixture_rows - 1) / 2 ))
expected_min=0
expected_max=$(( fixture_rows - 1 ))

is_bounded_positive_integer "$BENCH_REPETITIONS" "$MAX_REPETITIONS" || die "BENCH_REPETITIONS is outside the bounded range"
BENCH_REPETITIONS="$(normalize_decimal "$BENCH_REPETITIONS")"
if [[ "$smoke" != true && "$BENCH_REPETITIONS" -lt 7 ]]; then
  die "controlled mode requires BENCH_REPETITIONS >= 7"
fi

case "$BENCH_CACHE_REGIME" in
  warm_shared|natural_unknown) ;;
  *) die "BENCH_CACHE_REGIME must be warm_shared or natural_unknown" ;;
esac

: "${BENCH_CLICKHOUSE_TRACK:=auto}"
case "$BENCH_CLICKHOUSE_TRACK" in
  auto|required|off) ;;
  *) die "BENCH_CLICKHOUSE_TRACK must be auto, required, or off" ;;
esac

is_supported_codec() {
  case "$1" in
    lz4|zstd|delta-zstd) return 0 ;;
    *) return 1 ;;
  esac
}

clickhouse_track=disabled
clickhouse_guard_reason=disabled
clickhouse_bin="${CLICKHOUSE:-$(command -v clickhouse || true)}"
clickhouse_codec=''
clickhouse_column_codec=''
clickhouse_mark_settings=''
clickhouse_version=''

if [[ "$BENCH_CLICKHOUSE_TRACK" != off ]]; then
  if [[ -z "$clickhouse_bin" || ! -x "$clickhouse_bin" ]]; then
    if [[ "$BENCH_CLICKHOUSE_TRACK" == required ]]; then
      die "ClickHouse executable is unavailable"
    fi
    clickhouse_guard_reason=executable_unavailable
  else
    clickhouse_version="$($clickhouse_bin local --version 2>/dev/null || true)"
    if [[ "$clickhouse_version" != 'ClickHouse local version 26.7.1.1315 (official build).' ]]; then
      if [[ "$BENCH_CLICKHOUSE_TRACK" == required ]]; then
        die "ClickHouse version is not the verified oracle version"
      fi
      clickhouse_guard_reason=version_unverified
    else
      marker_path="$fixture/.crystal-click-real-reader-benchmark-fixture"
      if [[ -f "$marker_path" && ! -L "$marker_path" ]]; then
        marker_version="$(sed -n '1p' "$marker_path")"
        marker_codec_line="$(sed -n '2p' "$marker_path")"
        [[ "$marker_version" == crystal-click-real-reader-benchmark-fixture-v2 ]] || die "fixture ownership marker is not recognized"
        [[ "$marker_codec_line" == codec=* ]] || die "fixture codec marker is malformed"
        clickhouse_codec="${marker_codec_line#codec=}"
        is_supported_codec "$clickhouse_codec" || die "fixture codec marker is unsupported"
      elif [[ "$smoke" == true && "$fixture" == "$root_dir/test/fixtures/public/wide_u64_lz4/part" ]]; then
        clickhouse_codec=lz4
      elif [[ -n "${BENCH_CODEC:-}" ]]; then
        clickhouse_codec="$BENCH_CODEC"
        is_supported_codec "$clickhouse_codec" || die "BENCH_CODEC must be lz4, zstd, or delta-zstd"
      else
        if [[ "$BENCH_CLICKHOUSE_TRACK" == required ]]; then
          die "ClickHouse track requires a verified fixture codec marker or BENCH_CODEC"
        fi
        clickhouse_guard_reason=fixture_codec_unidentified
      fi

      if [[ -n "$clickhouse_codec" ]]; then
        case "$clickhouse_codec" in
          lz4) clickhouse_column_codec='LZ4' ;;
          zstd) clickhouse_column_codec='ZSTD(1)' ;;
          delta-zstd) clickhouse_column_codec='Delta(8), ZSTD(1)' ;;
        esac
        cmrk_count="$(find "$fixture" -maxdepth 1 -type f -name '*.cmrk2' -print | wc -l | tr -d ' ')"
        mrk_count="$(find "$fixture" -maxdepth 1 -type f -name '*.mrk2' -print | wc -l | tr -d ' ')"
        if [[ "$cmrk_count" == 1 && "$mrk_count" == 0 ]]; then
          clickhouse_mark_settings="
    index_granularity = 8192,
    compress_marks = 1,
    marks_compression_codec = 'ZSTD(1)',
    marks_compress_block_size = 256,"
        elif [[ "$cmrk_count" == 0 && "$mrk_count" == 1 ]]; then
          clickhouse_mark_settings=$'\n    index_granularity = 1024,\n    compress_marks = 0,'
        else
          if [[ "$BENCH_CLICKHOUSE_TRACK" == required ]]; then
            die "ClickHouse track requires exactly one recognized marks format"
          fi
          clickhouse_codec=''
          clickhouse_guard_reason=marks_format_unidentified
        fi
      fi

      if [[ -n "$clickhouse_codec" ]]; then
        clickhouse_track=verified
        clickhouse_guard_reason=none
      fi
    fi
  fi
fi

tracks=(array borrowed pipeline)
if [[ "$clickhouse_track" == verified ]]; then
  tracks+=(clickhouse)
fi
track_count=${#tracks[@]}

scratch_values=()
for scratch_size in $BENCH_SCRATCH_SIZES; do
  is_bounded_positive_integer "$scratch_size" "$MAX_SCRATCH_SIZE" || die "BENCH_SCRATCH_SIZES contains an out-of-range value"
  scratch_values+=("$(normalize_decimal "$scratch_size")")
done
(( ${#scratch_values[@]} > 0 )) || die "BENCH_SCRATCH_SIZES must contain at least one size"

time_bin=/usr/bin/time
[[ -x "$time_bin" ]] || die "/usr/bin/time is unavailable"

run_dir="$(mktemp -d "${TMPDIR:-/private/tmp}/crystal_click_uint64_execution_bench.XXXXXX")"
binary_dir="$(mktemp -d "${TMPDIR:-/private/tmp}/crystal_click_uint64_execution_binary.XXXXXX")"
binary_path="$binary_dir/uint64_execution_pipeline"
workload_root="$run_dir/workload"
mkdir -p "$workload_root" || die "temporary workload directory is unavailable"
cp -R -- "$fixture" "$workload_root/part_0_0_1_0" || die "fixture staging failed"
trap 'rm -rf "$binary_dir"' EXIT

export CRYSTAL_CACHE_DIR="${CRYSTAL_CACHE_DIR:-$run_dir/crystal_cache}"
crystal_link_flags="${CRYSTAL_LINK_FLAGS:--fuse-ld=ld}"
crystal build --release "${delta_backend_flags[@]}" "$root_dir/benchmarks/uint64_execution_pipeline.cr" -o "$binary_path" \
  --link-flags="$crystal_link_flags"

tree_digest() {
  local directory="$1"
  local digest
  digest="$(
    (
    cd "$directory" 2>/dev/null || exit 1
    find . -type f -print0 2>/dev/null |
      LC_ALL=C sort -z |
      while IFS= read -r -d '' relative_path; do
        file_digest="$(shasum -a 256 -- "$relative_path" 2>/dev/null | awk '{print $1}')" || exit 1
        [[ "$file_digest" =~ ^[[:xdigit:]]{64}$ ]] || exit 1
        printf '%s\t%s\n' "$relative_path" "$file_digest" || exit 1
      done
    ) | shasum -a 256 2>/dev/null | awk '{print $1}'
  )" || return 1
  [[ "$digest" =~ ^[[:xdigit:]]{64}$ ]] || return 1
  printf '%s\n' "$digest"
}

physical_stream_digest() {
  local directory="$1"
  local digest
  digest="$(
    (
    cd "$directory" 2>/dev/null || exit 1
    find . -maxdepth 1 -type f \( -name '*.bin' -o -name '*.mrk2' -o -name '*.cmrk2' \) -print0 2>/dev/null |
      LC_ALL=C sort -z |
      while IFS= read -r -d '' relative_path; do
        file_digest="$(shasum -a 256 -- "$relative_path" 2>/dev/null | awk '{print $1}')" || exit 1
        [[ "$file_digest" =~ ^[[:xdigit:]]{64}$ ]] || exit 1
        printf '%s\t%s\n' "$relative_path" "$file_digest" || exit 1
      done
    ) | shasum -a 256 2>/dev/null | awk '{print $1}'
  )" || return 1
  [[ "$digest" =~ ^[[:xdigit:]]{64}$ ]] || return 1
  printf '%s\n' "$digest"
}

fixture_digest="$(tree_digest "$fixture")" || die "fixture digest failed"
staged_digest="$(tree_digest "$workload_root/part_0_0_1_0")" || die "staged fixture digest failed"
[[ "$staged_digest" == "$fixture_digest" ]] || die "staged fixture differs from source fixture"
fixture_stream_digest="$(physical_stream_digest "$fixture")" || die "fixture physical stream digest failed"
staged_stream_digest="$(physical_stream_digest "$workload_root/part_0_0_1_0")" || die "staged physical stream digest failed"
[[ "$staged_stream_digest" == "$fixture_stream_digest" ]] || die "staged physical streams differ from source fixture"

crystal_sequence_count="$("$binary_path" --verify-sequence "$workload_root" "$expected_count" 8191 2> "$run_dir/crystal_sequence.err")" || die "Crystal fixture sequence verification failed"
[[ "$crystal_sequence_count" == "$expected_count" ]] || die "Crystal fixture sequence verification returned the wrong count"
sequence_verification=crystal

clickhouse_store=''
clickhouse_part_path=''
clickhouse_part_digest=''
clickhouse_stream_digest=''
clickhouse_query=""
if [[ "$clickhouse_track" == verified ]]; then
  clickhouse_store="$run_dir/clickhouse_store"
  mkdir -p "$clickhouse_store" || die "ClickHouse workspace is unavailable"
  clickhouse_query="SELECT count(),sum(value),min(value),max(value),toTypeName(sum(value)) FROM source SETTINGS max_threads=1,use_uncompressed_cache=0,use_query_cache=0,use_query_condition_cache=0,enable_filesystem_cache=0,use_page_cache_for_local_disks=0,use_statistics_cache=0,load_marks_asynchronously=0 FORMAT TSVRaw"
  clickhouse_setup_query="CREATE TABLE source
(
    \`value\` UInt64 CODEC($clickhouse_column_codec)
)
ENGINE = MergeTree
ORDER BY tuple()
SETTINGS
    min_rows_for_wide_part = 0,
    min_bytes_for_wide_part = 0,
    enable_mixed_granularity_parts = 1,${clickhouse_mark_settings}
    min_compress_block_size = 0,
    max_compress_block_size = 65536,
    default_compression_codec = 'ZSTD(1)';"
  "$clickhouse_bin" local --path "$clickhouse_store" --query "$clickhouse_setup_query" > /dev/null 2> "$run_dir/clickhouse_setup.err" || die "ClickHouse table setup failed"
  clickhouse_source_path="$("$clickhouse_bin" local --path "$clickhouse_store" --query "SELECT arrayElement(data_paths, 1) FROM system.tables WHERE database = currentDatabase() AND name = 'source' FORMAT TSVRaw" 2> "$run_dir/clickhouse_table_path.err" | tr -d '\r\n')" || die "ClickHouse table path inspection failed"
  [[ "$clickhouse_source_path" = /* ]] || die "ClickHouse table path is not absolute"
  clickhouse_source_path="$(cd "$clickhouse_source_path" 2>/dev/null && pwd -P)" || die "ClickHouse table path is unavailable"
  [[ -d "$clickhouse_source_path" && ! -L "$clickhouse_source_path" ]] || die "ClickHouse table path is invalid"
  mkdir -p "$clickhouse_source_path/detached" || die "ClickHouse detached area is unavailable"
  cp -R -- "$workload_root/part_0_0_1_0" "$clickhouse_source_path/detached/all_1_1_1" || die "ClickHouse part staging failed"
  "$clickhouse_bin" local --path "$clickhouse_store" --query "ALTER TABLE source ATTACH PART 'all_1_1_1'" > /dev/null 2> "$run_dir/clickhouse_attach.err" || die "ClickHouse part attach failed"
  clickhouse_part_path="$("$clickhouse_bin" local --path "$clickhouse_store" --query "SELECT path FROM system.parts WHERE table = 'source' AND active FORMAT TSVRaw" 2> "$run_dir/clickhouse_part.err" | tr -d '\r\n')" || die "ClickHouse part inspection failed"
  [[ -d "$clickhouse_part_path" && ! -L "$clickhouse_part_path" ]] || die "ClickHouse active part is unavailable"
  clickhouse_part_digest="$(tree_digest "$clickhouse_part_path")" || die "ClickHouse part digest failed"
  clickhouse_stream_digest="$(physical_stream_digest "$clickhouse_part_path")" || die "ClickHouse physical stream digest failed"
  [[ "$clickhouse_stream_digest" == "$fixture_stream_digest" ]] || die "ClickHouse attached physical streams differ from source fixture"
  clickhouse_sequence_summary="$("$clickhouse_bin" local --path "$clickhouse_store" --query "SELECT countIf(value != _part_offset), count() FROM source SETTINGS max_threads=1 FORMAT TSVRaw" 2> "$run_dir/clickhouse_sequence.err" | tr -d '\r\n')" || die "ClickHouse fixture sequence verification failed"
  [[ "$clickhouse_sequence_summary" == $'0\t'"$expected_count" ]] || die "ClickHouse fixture does not contain the declared sequence"
  sequence_verification=crystal_and_clickhouse
fi

verify_fixture() {
  local current_digest
  current_digest="$(tree_digest "$fixture")" || die "fixture changed or cannot be read"
  [[ "$current_digest" == "$fixture_digest" ]] || die "fixture changed during benchmark"
  current_digest="$(tree_digest "$workload_root/part_0_0_1_0")" || die "staged fixture changed"
  [[ "$current_digest" == "$staged_digest" ]] || die "staged fixture changed during benchmark"
  if [[ "$clickhouse_track" == verified ]]; then
    current_digest="$(tree_digest "$clickhouse_part_path")" || die "ClickHouse active part changed or cannot be read"
    [[ "$current_digest" == "$clickhouse_part_digest" ]] || die "ClickHouse active part changed"
    current_digest="$(physical_stream_digest "$clickhouse_part_path")" || die "ClickHouse physical streams changed or cannot be read"
    [[ "$current_digest" == "$fixture_stream_digest" ]] || die "ClickHouse physical streams differ from source fixture"
  fi
}

json_field() {
  local key="$1"
  local json_path="$2"
  awk -v key="$key" '
    NR == 1 {
      if ($0 !~ /^\{.*\}$/) exit 2
      marker = "\"" key "\":"
      position = index($0, marker)
      if (position == 0) exit 3
      value = substr($0, position + length(marker))
      sub(/[,}].*$/, "", value)
      sub(/^"/, "", value)
      sub(/"$/, "", value)
      print value
      next
    }
    { exit 4 }
    END { if (NR != 1) exit 5 }
  ' "$json_path"
}

run_child() {
  local track="$1"
  local scratch_size="$2"
  "$binary_path" --run "$track" "$workload_root" "$scratch_size" "$BENCH_CACHE_REGIME" \
    "$expected_count" "$expected_sum" "$expected_min" "$expected_max"
}

time_args=()
time_probe="$run_dir/time_probe"
set +e
"$time_bin" -l true >/dev/null 2>"$time_probe"
time_probe_status=$?
set -e
if (( time_probe_status == 0 )) || grep -Fq 'kern.clockrate' "$time_probe"; then
  time_args=(-l)
fi

results_path="$run_dir/results.tsv"
printf 'schema_version\trepetition\tmatrix_scratch_size\torder_slot\ttrack\tcache_regime\ttime_status\trss_available\tmax_rss_bytes\tcount\tsum\tmin\tmax\telapsed_ns\tquery_elapsed_ns\tgc_total_bytes_delta\tgc_collections_delta\tretained_rows\tcontainer_state\n' > "$results_path"
time_metadata_warning=false
rss_available_any=false
observation_count=0

check_decimal() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

parse_clickhouse_elapsed_ns() {
  awk '
    /^[0-9]+([.][0-9]+)?$/ {
      if (found) exit 1
      printf "%.0f\n", ($1 * 1000000000)
      found = 1
    }
    END { if (!found) exit 1 }
  ' "$1"
}

rep=1
while (( rep <= BENCH_REPETITIONS )); do
  scratch_index=0
  while (( scratch_index < ${#scratch_values[@]} )); do
    scratch_size="${scratch_values[$scratch_index]}"
    rotation=$(( (rep - 1 + scratch_index) % track_count ))
    slot=0
    while (( slot < track_count )); do
      track_index=$(( (slot + rotation) % track_count ))
      track="${tracks[$track_index]}"

      run_id="rep${rep}_scratch${scratch_size}_slot${slot}_${track}"
      result_path="$run_dir/$run_id.result"
      time_path="$run_dir/$run_id.time"
      warmup_path="$run_dir/$run_id.warmup"

      verify_fixture
      if [[ "$BENCH_CACHE_REGIME" == warm_shared ]]; then
        set +e
        if [[ "$track" == clickhouse ]]; then
          "$clickhouse_bin" local --path "$clickhouse_store" --query "$clickhouse_query" > /dev/null 2>"$warmup_path"
        else
          run_child "$track" "$scratch_size" > /dev/null 2>"$warmup_path"
        fi
        warmup_status=$?
        set -e
        (( warmup_status == 0 )) || die "$run_id warmup failed"
      else
        : > "$warmup_path"
      fi

      verify_fixture
      set +e
      if [[ "$track" == clickhouse ]]; then
        "$time_bin" "${time_args[@]}" "$clickhouse_bin" local --path "$clickhouse_store" --query "$clickhouse_query" --time > "$result_path" 2> "$time_path"
      else
        "$time_bin" "${time_args[@]}" "$binary_path" --run "$track" "$workload_root" "$scratch_size" "$BENCH_CACHE_REGIME" \
          "$expected_count" "$expected_sum" "$expected_min" "$expected_max" > "$result_path" 2> "$time_path"
      fi
      time_status=$?
      set -e
      verify_fixture

      [[ -s "$result_path" ]] || die "$run_id produced no structured result"
      if (( time_status != 0 )); then
        if (( time_status != 1 )) || ! grep -Fq 'time: sysctl kern.clockrate: Operation not permitted' "$time_path"; then
          die "$run_id failed"
        fi
        time_metadata_warning=true
      fi

      max_rss_bytes="$(awk '/maximum resident set size:/ {
        for (field = 1; field <= NF; field++) {
          if ($field ~ /^[0-9]+$/) { print $field; found=1; exit }
        }
      } END {if (!found) exit 1}' "$time_path" 2>/dev/null || true)"
      [[ -n "$max_rss_bytes" ]] || max_rss_bytes='-'
      rss_available=false
      if [[ "$max_rss_bytes" != '-' ]]; then
        check_decimal "$max_rss_bytes" || die "$run_id reported malformed RSS"
        rss_available=true
        rss_available_any=true
      fi

      query_elapsed_ns=-
      if [[ "$track" == clickhouse ]]; then
        query_elapsed_ns="$(parse_clickhouse_elapsed_ns "$time_path")" || die "$run_id ClickHouse --time output is malformed"
        result_line="$(tr -d '\r\n' < "$result_path")"
        IFS=$'\t' read -r output_count output_sum output_min output_max output_type output_extra <<< "$result_line"
        [[ -n "$output_count" && -z "${output_extra:-}" ]] || die "$run_id ClickHouse result shape is malformed"
        output_schema=1
        output_track=clickhouse
        output_regime="$BENCH_CACHE_REGIME"
        output_scratch=n/a
        output_min="${output_min:-}"
        output_max="${output_max:-}"
        output_type="${output_type:-}"
        parity_ok=true
        elapsed_ns="$query_elapsed_ns"
        gc_bytes=-
        gc_collections=-
        gc_available=false
        retained_rows=-
        container_state=clickhouse_query
      else
        output_schema="$(json_field schema_version "$result_path")" || die "$run_id JSON schema is malformed"
        output_track="$(json_field track "$result_path")" || die "$run_id JSON track is malformed"
        output_regime="$(json_field cache_regime "$result_path")" || die "$run_id JSON cache regime is malformed"
        output_scratch="$(json_field scratch_size "$result_path")" || die "$run_id JSON scratch size is malformed"
        output_count="$(json_field count "$result_path")" || die "$run_id JSON count is malformed"
        output_sum="$(json_field sum "$result_path")" || die "$run_id JSON sum is malformed"
        output_min="$(json_field min "$result_path")" || die "$run_id JSON minimum is malformed"
        output_max="$(json_field max "$result_path")" || die "$run_id JSON maximum is malformed"
        parity_ok="$(json_field parity_ok "$result_path")" || die "$run_id JSON parity flag is malformed"
        elapsed_ns="$(json_field elapsed_ns "$result_path")" || die "$run_id JSON elapsed time is malformed"
        gc_bytes="$(json_field gc_total_bytes_delta "$result_path")" || die "$run_id JSON GC bytes are malformed"
        gc_collections="$(json_field gc_collections_delta "$result_path")" || die "$run_id JSON GC collections are malformed"
        gc_available="$(json_field gc_metrics_available "$result_path")" || die "$run_id JSON GC availability is malformed"
        retained_rows="$(json_field retained_rows "$result_path")" || die "$run_id JSON retained rows are malformed"
        container_state="$(json_field container_state "$result_path")" || die "$run_id JSON container state is malformed"
      fi

      [[ "$output_schema" == 1 && "$output_track" == "$track" && "$output_regime" == "$BENCH_CACHE_REGIME" ]] || die "$run_id reported the wrong identity"
      if [[ "$track" == clickhouse ]]; then
        [[ "$output_scratch" == n/a && "$output_type" == UInt64 ]] || die "$run_id ClickHouse metadata is malformed"
        [[ "$parity_ok" == true && "$gc_available" == false ]] || die "$run_id ClickHouse availability flags are malformed"
      else
        [[ "$output_scratch" == "$scratch_size" ]] || die "$run_id reported the wrong scratch size"
        [[ "$parity_ok" == true && "$gc_available" == true ]] || die "$run_id did not report parity and GC success"
      fi
      [[ "$output_count" == "$expected_count" && "$output_sum" == "$expected_sum" ]] || die "$run_id aggregate count/sum mismatch"
      [[ "$output_min" == "$expected_min" && "$output_max" == "$expected_max" ]] || die "$run_id aggregate extrema mismatch"
      check_decimal "$elapsed_ns" || die "$run_id reported malformed elapsed_ns"
      [[ "$elapsed_ns" != 0 ]] || die "$run_id reported zero elapsed_ns"
      if [[ "$track" == clickhouse ]]; then
        check_decimal "$query_elapsed_ns" || die "$run_id reported malformed query_elapsed_ns"
        [[ "$query_elapsed_ns" != 0 && "$gc_bytes" == - && "$gc_collections" == - && "$retained_rows" == - ]] || die "$run_id ClickHouse metrics are malformed"
        expected_state=clickhouse_query
      else
        [[ "$query_elapsed_ns" == - ]] || die "$run_id Crystal query_elapsed_ns is malformed"
        check_decimal "$gc_bytes" || die "$run_id reported malformed GC byte delta"
        check_decimal "$gc_collections" || die "$run_id reported malformed GC collection delta"
        check_decimal "$retained_rows" || die "$run_id reported malformed retained rows"
        expected_retained=0
        expected_state=borrowed_scratch_only
        if [[ "$track" == array ]]; then
          expected_retained="$expected_count"
          expected_state=array_owned
        elif [[ "$track" == pipeline ]]; then
          expected_state=aggregate_result_only
        fi
        [[ "$retained_rows" == "$expected_retained" ]] || die "$run_id retained row count mismatch"
      fi
      [[ "$container_state" == "$expected_state" ]] || die "$run_id retained container state mismatch"

      printf '1\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$rep" "$scratch_size" "$slot" "$track" "$BENCH_CACHE_REGIME" "$time_status" "$rss_available" "$max_rss_bytes" \
        "$output_count" "$output_sum" "$output_min" "$output_max" "$elapsed_ns" "$query_elapsed_ns" "$gc_bytes" "$gc_collections" "$retained_rows" "$container_state" >> "$results_path"

      observation_count=$(( observation_count + 1 ))
      slot=$(( slot + 1 ))
    done
    scratch_index=$(( scratch_index + 1 ))
  done
  rep=$(( rep + 1 ))
done

expected_observations=$(( BENCH_REPETITIONS * ${#scratch_values[@]} * track_count ))
[[ "$observation_count" -eq "$expected_observations" ]] || die "observation count mismatch"

printf 'verified=true\n'
printf 'schema_version=1\n'
printf 'smoke=%s\n' "$smoke"
printf 'delta_backend=%s\n' "$BENCH_DELTA_BACKEND"
printf 'delta_backend_effective=%s\n' "$delta_backend_effective"
printf 'delta_backend_compile_flags=%s\n' "$delta_backend_compile_flags"
printf 'performance_observations_eligible=%s\n' "$([[ "$smoke" == true ]] && printf false || printf true)"
printf 'performance_winner_claim=false\n'
printf 'tracks=%s\n' "${tracks[*]}"
printf 'clickhouse_track=%s\n' "$clickhouse_track"
printf 'clickhouse_guard_reason=%s\n' "$clickhouse_guard_reason"
printf 'cache_regime=%s\n' "$BENCH_CACHE_REGIME"
printf 'cold_cache_claim=false\n'
printf 'time_metadata_warning=%s\n' "$time_metadata_warning"
printf 'rss_available_any=%s\n' "$rss_available_any"
printf 'gc_metrics_available=crystal_tracks_only\n'
printf 'fixture_tree_sha256=%s\n' "$fixture_digest"
printf 'physical_streams_same_bytes=%s\n' "$([[ "$clickhouse_track" == verified ]] && printf true || printf not_applicable)"
printf 'sequence_verification=%s\n' "$sequence_verification"
printf 'fixture_unchanged=true\n'
printf 'rows=%s\n' "$expected_count"
printf 'decoded_bytes=%s\n' "$decoded_bytes"
printf 'threshold_met=%s\n' "$threshold_met"
printf 'repetitions=%s\n' "$BENCH_REPETITIONS"
printf 'scratch_sizes=%s\n' "$BENCH_SCRATCH_SIZES"
printf 'observation_count=%s\n' "$observation_count"
printf 'result_dir=%s\n' "$run_dir"
printf 'results_tsv=%s\n' "$results_path"
