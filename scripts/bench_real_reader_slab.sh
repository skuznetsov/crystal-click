#!/usr/bin/env bash
set -euo pipefail

# End-to-end WidePart benchmark.  Each measured observation is a fresh release
# subprocess.  The legacy positional path receives an independently supplied
# row count and checksum; manifest mode validates the caller-owned workload
# without copying or echoing it. Neither track is a correctness oracle for the
# other.
# Cache regimes are deliberately named warm_shared and natural_unknown.  This
# runner does not flush system caches and therefore never claims cold-cache
# behavior.

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(CDPATH= cd -- "$script_dir/.." && pwd)"

# All values that later enter Bash arithmetic are bounded before arithmetic is
# used.  These limits also keep the controlled manifest and its derived
# geometry within the signed range supported by Bash arithmetic.
MAX_MANIFEST_BYTES=65536
MAX_REPETITIONS=1000
MAX_EXPECTED_ROWS=1000000000
MAX_COLUMN_COUNT=1024
MAX_DECODED_BYTES=9223372036854775807
MAX_SHIFT_COUNT=64

smoke=false
manifest_mode=false
workload_json=''
if [[ "${1:-}" == "--smoke" ]]; then
  smoke=true
  shift
fi

if [[ "${1:-}" == "--manifest" ]]; then
  [[ "$smoke" != true ]] || {
    printf 'usage: %s [--smoke] [--manifest WORKLOAD_JSON] [FIXTURE COLUMN EXPECTED_ROWS EXPECTED_CHECKSUM]\n' "${BASH_SOURCE[0]}" >&2
    exit 64
  }
  manifest_mode=true
  shift
  (( $# == 1 )) || {
    printf 'usage: %s --manifest WORKLOAD_JSON\n' "${BASH_SOURCE[0]}" >&2
    exit 64
  }
  workload_json="$1"
  : "${BENCH_REPETITIONS:=7}"
  : "${BENCH_SHIFTS:=10 12 14}"
  : "${BENCH_CACHE_REGIME:=natural_unknown}"
elif [[ "$smoke" == true ]]; then
  (( $# == 0 )) || { printf 'usage: %s [--smoke] [FIXTURE COLUMN EXPECTED_ROWS EXPECTED_CHECKSUM]\n' "${BASH_SOURCE[0]}" >&2; exit 64; }
  fixture="$root_dir/test/fixtures/public/wide_u64_zstd_cmrk2/part"
  column='value'
  expected_rows='200000'
  # Independent roll of values 0..199999 with the benchmark checksum formula.
  expected_checksum='15108874301622009856'
  : "${BENCH_REPETITIONS:=1}"
  : "${BENCH_SHIFTS:=12}"
  : "${BENCH_CACHE_REGIME:=natural_unknown}"
else
  (( $# == 4 )) || {
    printf 'usage: %s [--smoke] FIXTURE COLUMN EXPECTED_ROWS EXPECTED_CHECKSUM\n' "${BASH_SOURCE[0]}" >&2
    exit 64
  }
  fixture="$1"
  column="$2"
  expected_rows="$3"
  expected_checksum="$4"
  : "${BENCH_REPETITIONS:=7}"
  : "${BENCH_SHIFTS:=10 12 14}"
  : "${BENCH_CACHE_REGIME:=natural_unknown}"
fi

die() {
  printf 'bench_real_reader_slab: %s\n' "$*" >&2
  exit 1
}

is_positive_integer() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

is_nonnegative_integer() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

decimal_leq() {
  local value="$1"
  local limit="$2"
  is_nonnegative_integer "$value" || return 1
  while [[ ${#value} -gt 1 && ${value:0:1} == 0 ]]; do
    value="${value:1}"
  done
  while [[ ${#limit} -gt 1 && ${limit:0:1} == 0 ]]; do
    limit="${limit:1}"
  done
  if (( ${#value} < ${#limit} )); then
    return 0
  fi
  if (( ${#value} > ${#limit} )); then
    return 1
  fi
  [[ "$value" == "$limit" || "$value" < "$limit" ]]
}

is_bounded_positive_integer() {
  is_positive_integer "$1" && decimal_leq "$1" "$2"
}

is_bounded_nonnegative_integer() {
  is_nonnegative_integer "$1" && decimal_leq "$1" "$2"
}

normalize_decimal() {
  local value="$1"
  while [[ ${#value} -gt 1 && ${value:0:1} == 0 ]]; do
    value="${value:1}"
  done
  printf '%s' "$value"
}

read_manifest_snapshot() {
  local source_path="$1"
  local snapshot_with_sentinel
  # macOS's system Bash does not provide read -N. Keep a sentinel after the
  # bounded dd output so command substitution cannot strip trailing newlines
  # from the manifest snapshot.
  snapshot_with_sentinel="$(dd if="$source_path" bs=1 count=$((MAX_MANIFEST_BYTES + 1)) 2>/dev/null && printf '\001')" || return 1
  manifest_snapshot="${snapshot_with_sentinel%$'\001'}"
  (( ${#manifest_snapshot} <= MAX_MANIFEST_BYTES )) || return 1
}

if [[ "$manifest_mode" == true ]]; then
  [[ -f "$workload_json" ]] || die "workload manifest is missing"
  [[ -r "$workload_json" ]] || die "workload manifest cannot be read"
  # Capture the caller-owned workload exactly once, before any build,
  # validation, or fixture lookup. The snapshot never goes to disk or into
  # child arguments.
  workload_manifest_size="$(stat -f '%z' -- "$workload_json" 2>/dev/null)" || die "workload manifest size cannot be read"
  is_bounded_nonnegative_integer "$workload_manifest_size" "$MAX_MANIFEST_BYTES" || die "workload manifest is too large"
  read_manifest_snapshot "$workload_json" || die "workload manifest cannot be read"
  workload_manifest_snapshot="$manifest_snapshot"
  workload_manifest_sha256="$(printf '%s' "$workload_manifest_snapshot" | shasum -a 256 2>/dev/null | awk '{print $1}')" || die "workload manifest cannot be hashed"
  [[ "$workload_manifest_sha256" =~ ^[[:xdigit:]]{64}$ ]] || die "workload manifest hash is invalid"
else
  [[ -d "$fixture" ]] || die "fixture directory is missing"
  [[ -n "$column" ]] || die "column must be non-empty"
  is_bounded_positive_integer "$expected_rows" "$MAX_EXPECTED_ROWS" || die "expected rows are outside the controlled limit"
  is_nonnegative_integer "$expected_checksum" || die "expected checksum must be a non-negative integer"
fi

if [[ "$manifest_mode" == true ]]; then
  :
else
  expected_rows="$(normalize_decimal "$expected_rows")"
fi

verify_workload_manifest() {
  [[ "$manifest_mode" == true ]] || return 0
  local current_workload_manifest_size current_workload_manifest_snapshot current_workload_manifest_sha256
  current_workload_manifest_size="$(stat -f '%z' -- "$workload_json" 2>/dev/null)" || die "workload manifest changed"
  is_bounded_nonnegative_integer "$current_workload_manifest_size" "$MAX_MANIFEST_BYTES" || die "workload manifest changed"
  read_manifest_snapshot "$workload_json" || die "workload manifest changed"
  current_workload_manifest_snapshot="$manifest_snapshot"
  current_workload_manifest_sha256="$(printf '%s' "$current_workload_manifest_snapshot" | shasum -a 256 2>/dev/null | awk '{print $1}')" || die "workload manifest changed"
  [[ "$current_workload_manifest_sha256" == "$workload_manifest_sha256" && "$current_workload_manifest_snapshot" == "$workload_manifest_snapshot" ]] || die "workload manifest changed"
}

is_positive_integer "$BENCH_REPETITIONS" || die "BENCH_REPETITIONS must be a positive integer"
is_bounded_positive_integer "$BENCH_REPETITIONS" "$MAX_REPETITIONS" || die "BENCH_REPETITIONS exceeds the controlled limit"
BENCH_REPETITIONS="$(normalize_decimal "$BENCH_REPETITIONS")"
if [[ "$smoke" != true ]]; then
  (( BENCH_REPETITIONS >= 7 )) || die "controlled mode requires BENCH_REPETITIONS >= 7"
fi
case "$BENCH_CACHE_REGIME" in
  warm_shared|natural_unknown) ;;
  *) die "BENCH_CACHE_REGIME must be warm_shared or natural_unknown" ;;
esac

shift_values=()
for slab_shift in $BENCH_SHIFTS; do
  is_bounded_nonnegative_integer "$slab_shift" 20 || die "BENCH_SHIFTS contains an out-of-range value"
  (( slab_shift >= 4 )) || die "slab shifts must be in 4..20"
  shift_values+=("$(normalize_decimal "$slab_shift")")
done
(( ${#shift_values[@]} > 0 )) || die "BENCH_SHIFTS must contain at least one shift"
(( ${#shift_values[@]} <= MAX_SHIFT_COUNT )) || die "BENCH_SHIFTS contains too many shifts"

time_bin=/usr/bin/time
[[ -x "$time_bin" ]] || die "/usr/bin/time is required"

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
      sub(/^\"/, "", value)
      sub(/\"$/, "", value)
      print value
      next
    }
    { exit 4 }
    END { if (NR != 1) exit 5 }
  ' "$json_path"
}

run_dir="$(mktemp -d "${TMPDIR:-/private/tmp}/crystal_click_real_reader_slab_bench.XXXXXX")"
binary_dir="$(mktemp -d "${TMPDIR:-/private/tmp}/crystal_click_real_reader_slab_binary.XXXXXX")"
binary_path="$binary_dir/real_reader_slab"
trap 'rm -rf "$binary_dir"' EXIT

export CRYSTAL_CACHE_DIR="${CRYSTAL_CACHE_DIR:-$run_dir/crystal_cache}"
crystal build --release "$root_dir/benchmarks/real_reader_slab.cr" -o "$binary_path"

if [[ "$manifest_mode" == true ]]; then
  manifest_validation_path="$run_dir/workload.validation.json"
  manifest_validation_error="$run_dir/workload.validation.err"
  set +e
  printf '%s' "$workload_manifest_snapshot" | "$binary_path" validate --manifest-stdin > "$manifest_validation_path" 2> "$manifest_validation_error"
  manifest_validation_status=$?
  set -e
  if (( manifest_validation_status != 0 )); then
    printf 'bench_real_reader_slab: workload manifest validation failed\n' >&2
    exit 64
  fi
  # The binary parsed the in-memory snapshot. Recheck the caller-owned file
  # only as an audit signal; observation correctness comes from that snapshot.
  verify_workload_manifest
  schema_version="$(json_field schema_version "$manifest_validation_path")" || die "workload manifest validation output is malformed"
  column_count="$(json_field column_count "$manifest_validation_path")" || die "workload manifest validation output is malformed"
  expected_rows="$(json_field rows_per_column "$manifest_validation_path")" || die "workload manifest validation output is malformed"
  decoded_bytes="$(json_field decoded_bytes "$manifest_validation_path")" || die "workload manifest validation output is malformed"
  threshold_met_expected="$(json_field threshold_met "$manifest_validation_path")" || die "workload manifest validation output is malformed"
  [[ "$schema_version" == 2 && "$threshold_met_expected" == true ]] || die "workload manifest validation output is invalid"
  is_bounded_positive_integer "$column_count" "$MAX_COLUMN_COUNT" || die "workload manifest column count is invalid"
  is_bounded_positive_integer "$expected_rows" "$MAX_EXPECTED_ROWS" || die "workload manifest expected rows are invalid"
  is_bounded_positive_integer "$decoded_bytes" "$MAX_DECODED_BYTES" || die "workload manifest decoded bytes are invalid"
  column_count="$(normalize_decimal "$column_count")"
  expected_rows="$(normalize_decimal "$expected_rows")"
  decoded_bytes="$(normalize_decimal "$decoded_bytes")"
  command -v jq >/dev/null 2>&1 || die "jq is required for manifest mode"
  fixture="$(printf '%s' "$workload_manifest_snapshot" | jq -er '.fixture | select(type == "string" and length > 0)' 2>/dev/null)" || die "workload manifest validation failed"
  [[ "$fixture" == /* && "$fixture" != "/" ]] || die "controlled fixture must be absolute and non-root"
  verify_workload_manifest
  [[ -d "$fixture" ]] || die "fixture directory is missing"
  [[ -f "$fixture/columns.txt" && -f "$fixture/count.txt" ]] || die "fixture markers are missing"
else
  decoded_bytes=$(( expected_rows * 8 ))
  if (( decoded_bytes >= 64 * 1024 * 1024 )); then
    threshold_met_expected=true
  else
    threshold_met_expected=false
  fi
  column_count=1
fi

# Compute one aggregate tree digest. Relative filenames exist only in the
# in-memory pipe feeding the digest; no per-file manifest or fixture path is
# persisted or printed.
fixture_tree_digest() {
  local digest
  digest="$(
    (
      cd "$fixture" 2>/dev/null || exit 1
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

fixture_manifest_sha256="$(fixture_tree_digest)" || die "fixture tree digest failed"

verify_manifest() {
  local current_digest
  current_digest="$(fixture_tree_digest)" || die "fixture tree digest failed"
  [[ "$current_digest" == "$fixture_manifest_sha256" ]] || die "fixture tree changed"
}

results_path="$run_dir/results.tsv"
printf 'rep\tslab_shift\ttrack\tcache_regime\tjson_path\ttime_path\twarmup_path\ttime_status\trss_available\tmax_rss_bytes\trows\tchecksum\telapsed_ns\tgc_total_bytes_delta\tgc_collections_delta\tretained_values\tfixture_rows\tmark_count\tdata_bytes\tmark_bytes\tslab_count\tcapacity\tdirectory_capacity\n' > "$results_path"
if [[ "$manifest_mode" == true ]]; then
  printf 'manifest_mode=true\tcolumn_count=%s\trows_per_column=%s\tdecoded_bytes=%s\trepetitions=%s\tshifts=%s\tcache_regime=%s\n' \
    "$column_count" "$expected_rows" "$decoded_bytes" "$BENCH_REPETITIONS" "$BENCH_SHIFTS" "$BENCH_CACHE_REGIME" > "$run_dir/config.tsv"
else
  printf 'manifest_mode=false\texpected_rows=%s\texpected_checksum=%s\trepetitions=%s\tshifts=%s\tcache_regime=%s\n' \
    "$expected_rows" "$expected_checksum" "$BENCH_REPETITIONS" "$BENCH_SHIFTS" "$BENCH_CACHE_REGIME" > "$run_dir/config.tsv"
fi

check_decimal() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

check_bounded_decimal() {
  is_bounded_nonnegative_integer "$1" "$MAX_DECODED_BYTES"
}

run_track() {
  local selected_track="$1"
  local selected_shift="$2"
  if [[ "$manifest_mode" == true ]]; then
    printf '%s' "$workload_manifest_snapshot" | "$binary_path" "$selected_track" --manifest-stdin "$selected_shift" "$BENCH_CACHE_REGIME"
  else
    "$binary_path" "$selected_track" "$fixture" "$column" "$selected_shift" "$expected_rows" "$expected_checksum" "$BENCH_CACHE_REGIME"
  fi
}

tracks=(array slab)
time_metadata_warning=false
rss_available_any=false
rep=1
while (( rep <= BENCH_REPETITIONS )); do
  for slab_shift in "${shift_values[@]}"; do
    rotation=$(( (rep - 1 + slab_shift) % ${#tracks[@]} ))
    slot=0
    while (( slot < ${#tracks[@]} )); do
      track_index=$(( (slot + rotation) % ${#tracks[@]} ))
      track="${tracks[$track_index]}"
      run_id="rep${rep}_shift${slab_shift}_${track}"
      json_path="$run_dir/$run_id.json"
      time_path="$run_dir/$run_id.time"
      warmup_path="$run_dir/$run_id.warmup"

      verify_workload_manifest
      verify_manifest
      if [[ "$BENCH_CACHE_REGIME" == warm_shared ]]; then
        # Warm the same workload in a separate child before every timed
        # observation.  The warmup itself is not a measured observation.
        set +e
        run_track array "$slab_shift" > /dev/null 2> "$warmup_path"
        warmup_status=$?
        set -e
        if (( warmup_status != 0 )); then
          die "$run_id warmup failed; see $warmup_path"
        fi
      else
        : > "$warmup_path"
      fi

      # Recheck after the optional warmup so the timed child cannot start
      # against a manifest or fixture changed during that separate child.
      verify_workload_manifest
      verify_manifest
      set +e
      if [[ "$manifest_mode" == true ]]; then
        printf '%s' "$workload_manifest_snapshot" | "$time_bin" -l "$binary_path" "$track" --manifest-stdin "$slab_shift" "$BENCH_CACHE_REGIME" > "$json_path" 2> "$time_path"
      else
        "$time_bin" -l "$binary_path" "$track" "$fixture" "$column" "$slab_shift" "$expected_rows" "$expected_checksum" "$BENCH_CACHE_REGIME" > "$json_path" 2> "$time_path"
      fi
      time_status=$?
      set -e
      verify_workload_manifest
      verify_manifest
      if (( time_status != 0 )); then
        if (( time_status != 1 )) || ! grep -Fq 'time: sysctl kern.clockrate: Operation not permitted' "$time_path"; then
          die "$run_id failed (time status=$time_status); see $time_path"
        fi
        time_metadata_warning=true
      fi
      # /usr/bin/time may return 1 for its own metadata warning even when the
      # child succeeded. A failed child still leaves no result JSON, so reject
      # that state before attempting to parse a success-looking observation.
      [[ -s "$json_path" ]] || die "$run_id produced no result"

      max_rss_bytes="$(awk '/maximum resident set size/ {
        for (field = 1; field <= NF; field++) {
          if ($field ~ /^[0-9]+$/) { print $field; found=1; exit }
        }
      } END {if (!found) exit 1}' "$time_path" 2>/dev/null || true)"
      [[ -n "$max_rss_bytes" ]] || max_rss_bytes='-'
      rss_available=false
      if [[ "$max_rss_bytes" != '-' ]]; then
        check_decimal "$max_rss_bytes" || die "$run_id reported a non-decimal maximum resident set size"
        rss_available=true
        rss_available_any=true
      fi

      output_schema_version="$(json_field schema_version "$json_path")"
      output_track="$(json_field track "$json_path")"
      output_regime="$(json_field cache_regime "$json_path")"
      output_rows="$(json_field rows "$json_path")"
      output_expected_rows="$(json_field expected_rows "$json_path")"
      output_column_count="$(json_field column_count "$json_path")"
      output_rows_per_column="$(json_field rows_per_column "$json_path")"
      output_decoded_bytes="$(json_field decoded_bytes "$json_path")"
      output_threshold_met="$(json_field threshold_met "$json_path")"
      rows_ok="$(json_field rows_ok "$json_path")"
      checksums_ok="$(json_field checksums_ok "$json_path")"
      elapsed_ns="$(json_field elapsed_ns "$json_path")"
      gc_bytes="$(json_field gc_total_bytes_delta "$json_path")"
      gc_collections="$(json_field gc_collections_delta "$json_path")"
      gc_available="$(json_field gc_metrics_available "$json_path")"
      retained_values="$(json_field retained_values_total "$json_path")"
      fixture_rows="$(json_field fixture_rows "$json_path")"
      mark_count="$(json_field mark_count "$json_path")"
      data_bytes="$(json_field data_bytes "$json_path")"
      mark_bytes="$(json_field mark_bytes "$json_path")"
      output_shift="$(json_field slab_shift "$json_path")"
      slab_count="$(json_field slab_count_total "$json_path")"
      capacity="$(json_field capacity_total "$json_path")"
      directory_capacity="$(json_field directory_capacity_total "$json_path")"
      tail_unused="$(json_field tail_unused_slots_total "$json_path")"
      checksum='-'
      checksum_ok="$checksums_ok"
      if [[ "$manifest_mode" != true ]]; then
        checksum="$(json_field checksum "$json_path")"
        output_expected_checksum="$(json_field expected_checksum "$json_path")"
        checksum_ok="$(json_field checksum_ok "$json_path")"
        [[ "$output_expected_checksum" == "$expected_checksum" ]] || die "$run_id reported expected_checksum=$output_expected_checksum"
      fi

      [[ "$output_schema_version" == 2 ]] || die "$run_id reported schema_version=$output_schema_version"
      [[ "$output_track" == "$track" ]] || die "$run_id reported track=$output_track"
      [[ "$output_regime" == "$BENCH_CACHE_REGIME" ]] || die "$run_id reported cache_regime=$output_regime"
      [[ "$output_rows" == "$expected_rows" ]] || die "$run_id reported rows=$output_rows"
      [[ "$output_expected_rows" == "$expected_rows" ]] || die "$run_id reported expected_rows=$output_expected_rows"
      [[ "$output_column_count" == "$column_count" ]] || die "$run_id reported column_count=$output_column_count"
      [[ "$output_rows_per_column" == "$expected_rows" ]] || die "$run_id reported rows_per_column=$output_rows_per_column"
      [[ "$output_decoded_bytes" == "$decoded_bytes" ]] || die "$run_id reported decoded_bytes=$output_decoded_bytes"
      [[ "$output_threshold_met" == "$threshold_met_expected" ]] || die "$run_id reported threshold_met=$output_threshold_met"
      [[ "$rows_ok" == true && "$checksums_ok" == true && "$checksum_ok" == true ]] || die "$run_id did not report parity success"
      [[ "$output_shift" == "$slab_shift" ]] || die "$run_id reported slab_shift=$output_shift"
      check_decimal "$checksum" || [[ "$manifest_mode" == true ]] || die "$run_id reported a non-decimal checksum"
      check_decimal "$elapsed_ns" || die "$run_id reported a non-decimal elapsed_ns"
      check_decimal "$gc_bytes" || die "$run_id reported a non-decimal GC byte delta"
      check_decimal "$gc_collections" || die "$run_id reported a non-decimal GC collection delta"
      [[ "$gc_available" == true ]] || die "$run_id did not report GC metric availability"
      check_decimal "$retained_values" || die "$run_id reported a non-decimal retained_values"
      check_decimal "$fixture_rows" || die "$run_id reported a non-decimal fixture_rows"
      check_decimal "$mark_count" || die "$run_id reported a non-decimal mark_count"
      check_decimal "$data_bytes" || die "$run_id reported a non-decimal data_bytes"
      check_decimal "$mark_bytes" || die "$run_id reported a non-decimal mark_bytes"
      check_decimal "$slab_count" || die "$run_id reported a non-decimal slab_count"
      check_decimal "$capacity" || die "$run_id reported a non-decimal capacity"
      check_decimal "$directory_capacity" || die "$run_id reported a non-decimal directory_capacity"
      check_decimal "$tail_unused" || die "$run_id reported a non-decimal tail_unused_slots_total"
      check_bounded_decimal "$output_rows" || die "$run_id reported out-of-range rows"
      check_bounded_decimal "$output_expected_rows" || die "$run_id reported out-of-range expected_rows"
      check_bounded_decimal "$output_column_count" || die "$run_id reported out-of-range column_count"
      check_bounded_decimal "$output_rows_per_column" || die "$run_id reported out-of-range rows_per_column"
      check_bounded_decimal "$output_decoded_bytes" || die "$run_id reported out-of-range decoded_bytes"
      check_bounded_decimal "$retained_values" || die "$run_id reported out-of-range retained_values"
      check_bounded_decimal "$fixture_rows" || die "$run_id reported out-of-range fixture_rows"
      check_bounded_decimal "$slab_count" || die "$run_id reported out-of-range slab_count"
      check_bounded_decimal "$capacity" || die "$run_id reported out-of-range capacity"
      check_bounded_decimal "$directory_capacity" || die "$run_id reported out-of-range directory_capacity"
      check_bounded_decimal "$tail_unused" || die "$run_id reported out-of-range tail_unused_slots_total"
      [[ "$elapsed_ns" != 0 ]] || die "$run_id reported zero elapsed_ns"
      expected_retained_values=$(( expected_rows * column_count ))
      [[ "$retained_values" == "$expected_retained_values" ]] || die "$run_id retained_values=$retained_values expected=$expected_retained_values"
      [[ "$fixture_rows" == "$expected_rows" ]] || die "$run_id reported fixture_rows=$fixture_rows"
      [[ "$retained_values" != 0 ]] || die "$run_id reported zero retained values"

      if [[ "$track" == slab ]]; then
        slab_size=$((1 << slab_shift))
        expected_slab_count=$(( (expected_rows + slab_size - 1) / slab_size ))
        expected_slab_count_total=$(( expected_slab_count * column_count ))
        expected_capacity=$(( expected_slab_count_total * slab_size ))
        expected_tail_unused=$(( expected_capacity - expected_retained_values ))
        [[ "$slab_count" == "$expected_slab_count_total" ]] || die "$run_id slab_count=$slab_count expected=$expected_slab_count_total"
        [[ "$capacity" == "$expected_capacity" ]] || die "$run_id capacity=$capacity expected=$expected_capacity"
        [[ "$tail_unused" == "$expected_tail_unused" ]] || die "$run_id tail_unused_slots_total=$tail_unused expected=$expected_tail_unused"
        (( directory_capacity >= slab_count )) || die "$run_id directory_capacity=$directory_capacity below slab_count=$slab_count"
      else
        [[ "$slab_count" == 0 && "$capacity" == 0 && "$directory_capacity" == 0 && "$tail_unused" == 0 ]] || die "$run_id array track reported slab geometry"
      fi

      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$rep" "$slab_shift" "$track" "$BENCH_CACHE_REGIME" "$json_path" "$time_path" "$warmup_path" "$time_status" "$rss_available" "$max_rss_bytes" \
        "$output_rows" "$checksum" "$elapsed_ns" "$gc_bytes" "$gc_collections" "$retained_values" "$fixture_rows" "$mark_count" "$data_bytes" "$mark_bytes" \
        "$slab_count" "$capacity" "$directory_capacity" >> "$results_path"
      slot=$((slot + 1))
    done
  done
  rep=$((rep + 1))
done

printf 'verified=true\n'
printf 'cache_regime=%s\n' "$BENCH_CACHE_REGIME"
printf 'cold_cache_claim=false\n'
printf 'time_metadata_warning=%s\n' "$time_metadata_warning"
printf 'rss_available_any=%s\n' "$rss_available_any"
printf 'gc_metrics_available=true\n'
printf 'fixture_manifest_verified=true\n'
if [[ "$manifest_mode" == true ]]; then
  printf 'workload_manifest_verified=true\n'
else
printf 'workload_manifest_verified=not_applicable\n'
fi
printf 'fixture_manifest_sha256=%s\n' "$fixture_manifest_sha256"
printf 'fixture_tree_sha256=%s\n' "$fixture_manifest_sha256"
printf 'column_count=%s\n' "$column_count"
printf 'rows_per_column=%s\n' "$expected_rows"
printf 'decoded_bytes=%s\n' "$decoded_bytes"
printf 'threshold_met=%s\n' "$threshold_met_expected"
printf 'result_dir=%s\n' "$run_dir"
printf 'results_tsv=%s\n' "$results_path"
