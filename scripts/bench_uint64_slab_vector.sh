#!/usr/bin/env bash
set -euo pipefail

# This runner isolates container ingestion. It does not exercise a compressed
# reader, codec, decompressor, mmap path, or disk-format integration.
# `max_rss_bytes` is parsed from macOS `/usr/bin/time -l` when available;
# restricted hosts report `rss_available=false` instead of inventing an RSS.

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(CDPATH= cd -- "$script_dir/.." && pwd)"

if [[ "${1:-}" == "--smoke" ]]; then
  [[ -n "${BENCH_ROWS+x}" ]] || BENCH_ROWS=10003
  [[ -n "${BENCH_SHIFTS+x}" ]] || BENCH_SHIFTS="12"
  [[ -n "${BENCH_REPETITIONS+x}" ]] || BENCH_REPETITIONS=1
  shift
fi
if (( $# != 0 )); then
  printf 'usage: %s [--smoke]\n' "${BASH_SOURCE[0]}" >&2
  exit 64
fi

: "${BENCH_ROWS:=10000000}"
: "${BENCH_SHIFTS:=10 12 14}"
: "${BENCH_SCRATCH_SIZE:=4096}"
: "${BENCH_REPETITIONS:=7}"

die() {
  printf 'bench_uint64_slab_vector: %s\n' "$*" >&2
  exit 1
}

is_positive_integer() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

is_nonnegative_integer() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

is_positive_integer "$BENCH_ROWS" || die "BENCH_ROWS must be a positive integer"
is_positive_integer "$BENCH_SCRATCH_SIZE" || die "BENCH_SCRATCH_SIZE must be a positive integer"
is_positive_integer "$BENCH_REPETITIONS" || die "BENCH_REPETITIONS must be a positive integer"

shift_values=()
for slab_shift in $BENCH_SHIFTS; do
  is_nonnegative_integer "$slab_shift" || die "BENCH_SHIFTS contains a non-integer: $slab_shift"
  if (( slab_shift < 4 || slab_shift > 20 )); then
    die "slab shifts must be in 4..20: $slab_shift"
  fi
  shift_values+=("$slab_shift")
done
(( ${#shift_values[@]} > 0 )) || die "BENCH_SHIFTS must contain at least one shift"

time_bin=/usr/bin/time
[[ -x "$time_bin" ]] || die "/usr/bin/time is required"

run_dir="$(mktemp -d "${TMPDIR:-/tmp}/crystal_click_uint64_slab_bench.XXXXXX")"
binary_dir="$(mktemp -d "${TMPDIR:-/tmp}/crystal_click_uint64_slab_binary.XXXXXX")"
binary_path="$binary_dir/uint64_slab_vector"
trap 'rm -rf "$binary_dir"' EXIT

# Keep the compiler cache in the run directory so this script is self-contained
# on hosts where the default Crystal cache is not writable.
export CRYSTAL_CACHE_DIR="${CRYSTAL_CACHE_DIR:-$run_dir/crystal_cache}"
crystal build --release "$root_dir/benchmarks/uint64_slab_vector.cr" -o "$binary_path"

results_path="$run_dir/results.tsv"
printf 'rep\tslab_shift\ttrack\tjson_path\ttime_path\ttime_status\trss_available\tmax_rss_bytes\trows\tchecksum\telapsed_ns\tgc_total_bytes_delta\tgc_collections_delta\tretained_values\tslab_count\tcapacity\tdirectory_capacity\n' > "$results_path"
printf 'rows=%s\tscratch_size=%s\trepetitions=%s\tshifts=%s\n' \
  "$BENCH_ROWS" "$BENCH_SCRATCH_SIZE" "$BENCH_REPETITIONS" "$BENCH_SHIFTS" > "$run_dir/config.tsv"

# Extract one scalar from the benchmark's deliberately compact one-line JSON.
# This uses only POSIX awk; jq is intentionally not a runner dependency.
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

check_decimal() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

tracks=(array_direct array_stream slab_stream slice_sink)
reference_checksum=''
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

      # Each track is a fresh process. JSON stdout and /usr/bin/time -l stderr
      # are kept as separate, replayable files under the machine-readable run
      # directory.
      set +e
      "$time_bin" -l "$binary_path" "$track" "$BENCH_ROWS" "$slab_shift" "$BENCH_SCRATCH_SIZE" \
        > "$json_path" 2> "$time_path"
      time_status=$?
      set -e
      if (( time_status != 0 )); then
        # In restricted macOS sandboxes, /usr/bin/time -l can complete the
        # child successfully but return 1 because kern.clockrate is denied.
        if (( time_status != 1 )) || ! grep -Fq 'time: sysctl kern.clockrate: Operation not permitted' "$time_path"; then
          die "$run_id failed (time status=$time_status); see $time_path"
        fi
        time_metadata_warning=true
      fi

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

      output_track="$(json_field track "$json_path")"
      output_rows="$(json_field rows "$json_path")"
      checksum="$(json_field checksum "$json_path")"
      elapsed_ns="$(json_field elapsed_ns "$json_path")"
      gc_bytes="$(json_field gc_total_bytes_delta "$json_path")"
      gc_collections="$(json_field gc_collections_delta "$json_path")"
      retained_values="$(json_field retained_values "$json_path")"
      output_shift="$(json_field slab_shift "$json_path")"
      output_scratch="$(json_field scratch_size "$json_path")"

      [[ "$output_track" == "$track" ]] || die "$run_id reported track=$output_track"
      [[ "$output_rows" == "$BENCH_ROWS" ]] || die "$run_id reported rows=$output_rows"
      [[ "$output_shift" == "$slab_shift" ]] || die "$run_id reported slab_shift=$output_shift"
      [[ "$output_scratch" == "$BENCH_SCRATCH_SIZE" ]] || die "$run_id reported scratch_size=$output_scratch"
      check_decimal "$checksum" || die "$run_id reported a non-decimal checksum"
      check_decimal "$elapsed_ns" || die "$run_id reported a non-decimal elapsed_ns"
      check_decimal "$gc_bytes" || die "$run_id reported a non-decimal GC byte delta"
      check_decimal "$gc_collections" || die "$run_id reported a non-decimal GC collection delta"
      check_decimal "$retained_values" || die "$run_id reported a non-decimal retained_values"
      [[ "$elapsed_ns" != 0 ]] || die "$run_id reported zero elapsed_ns"

      if [[ -z "$reference_checksum" ]]; then
        reference_checksum="$checksum"
      elif [[ "$checksum" != "$reference_checksum" ]]; then
        die "$run_id checksum=$checksum differs from reference=$reference_checksum"
      fi

      expected_retained="$BENCH_ROWS"
      slab_count='-'
      capacity='-'
      directory_capacity='-'
      if [[ "$track" == "slice_sink" ]]; then
        expected_retained=0
      elif [[ "$track" == "slab_stream" ]]; then
        slab_count="$(json_field slab_count "$json_path")"
        capacity="$(json_field capacity "$json_path")"
        directory_capacity="$(json_field directory_capacity "$json_path")"
        check_decimal "$slab_count" || die "$run_id reported a non-decimal slab_count"
        check_decimal "$capacity" || die "$run_id reported a non-decimal capacity"
        check_decimal "$directory_capacity" || die "$run_id reported a non-decimal directory_capacity"
        slab_size=$((1 << slab_shift))
        expected_slab_count=$(( (BENCH_ROWS + slab_size - 1) / slab_size ))
        expected_capacity=$(( expected_slab_count * slab_size ))
        [[ "$slab_count" == "$expected_slab_count" ]] || die "$run_id slab_count=$slab_count expected=$expected_slab_count"
        [[ "$capacity" == "$expected_capacity" ]] || die "$run_id capacity=$capacity expected=$expected_capacity"
        if (( directory_capacity < slab_count )); then
          die "$run_id directory_capacity=$directory_capacity below slab_count=$slab_count"
        fi
      fi
      [[ "$retained_values" == "$expected_retained" ]] || die "$run_id retained_values=$retained_values expected=$expected_retained"

      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$rep" "$slab_shift" "$track" "$json_path" "$time_path" "$time_status" "$rss_available" "$max_rss_bytes" \
        "$output_rows" "$checksum" "$elapsed_ns" "$gc_bytes" "$gc_collections" "$retained_values" \
        "$slab_count" "$capacity" "$directory_capacity" >> "$results_path"
      slot=$((slot + 1))
    done
  done
  rep=$((rep + 1))
done

printf 'verified=true\n'
printf 'reference_checksum=%s\n' "$reference_checksum"
printf 'time_metadata_warning=%s\n' "$time_metadata_warning"
printf 'rss_available_any=%s\n' "$rss_available_any"
printf 'result_dir=%s\n' "$run_dir"
printf 'results_tsv=%s\n' "$results_path"
