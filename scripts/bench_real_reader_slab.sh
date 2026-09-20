#!/usr/bin/env bash
set -euo pipefail

# End-to-end WidePart benchmark.  Each measured observation is a fresh release
# subprocess.  The benchmark binary receives an independently supplied row
# count and checksum; neither track is a correctness oracle for the other.
# Cache regimes are deliberately named warm_shared and natural_unknown.  This
# runner does not flush system caches and therefore never claims cold-cache
# behavior.

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(CDPATH= cd -- "$script_dir/.." && pwd)"

smoke=false
if [[ "${1:-}" == "--smoke" ]]; then
  smoke=true
  shift
fi

if [[ "$smoke" == true ]]; then
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

[[ -d "$fixture" ]] || die "fixture directory is missing"
[[ -n "$column" ]] || die "column must be non-empty"
is_positive_integer "$expected_rows" || die "expected rows must be a positive integer"
is_nonnegative_integer "$expected_checksum" || die "expected checksum must be a non-negative integer"
is_positive_integer "$BENCH_REPETITIONS" || die "BENCH_REPETITIONS must be a positive integer"
if [[ "$smoke" != true ]] && (( BENCH_REPETITIONS < 7 )); then
  die "controlled mode requires BENCH_REPETITIONS >= 7"
fi
case "$BENCH_CACHE_REGIME" in
  warm_shared|natural_unknown) ;;
  *) die "BENCH_CACHE_REGIME must be warm_shared or natural_unknown" ;;
esac

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

run_dir="$(mktemp -d "${TMPDIR:-/private/tmp}/crystal_click_real_reader_slab_bench.XXXXXX")"
binary_dir="$(mktemp -d "${TMPDIR:-/private/tmp}/crystal_click_real_reader_slab_binary.XXXXXX")"
binary_path="$binary_dir/real_reader_slab"
trap 'rm -rf "$binary_dir"' EXIT

export CRYSTAL_CACHE_DIR="${CRYSTAL_CACHE_DIR:-$run_dir/crystal_cache}"
crystal build --release "$root_dir/benchmarks/real_reader_slab.cr" -o "$binary_path"

# Relative names, sizes, and SHA-256s make an immutable replayable manifest
# without recording the caller's absolute fixture path.  No decoded row values
# are printed or persisted by this manifest.
manifest_path="$run_dir/fixture.manifest"
write_manifest() {
  (
    cd "$fixture"
    while IFS= read -r relative_path; do
      bytes="$(wc -c < "$relative_path" | tr -d '[:space:]')"
      digest="$(shasum -a 256 -- "$relative_path" | awk '{print $1}')"
      printf '%s\t%s\t%s\n' "$relative_path" "$bytes" "$digest"
    done < <(find . -type f -print | LC_ALL=C sort)
  )
}
write_manifest > "$manifest_path"
[[ -s "$manifest_path" ]] || die "fixture manifest is empty"

verify_manifest() {
  local current_manifest="$run_dir/fixture.manifest.current"
  write_manifest > "$current_manifest"
  cmp -s "$manifest_path" "$current_manifest" || die "fixture manifest changed"
  rm -f "$current_manifest"
}

results_path="$run_dir/results.tsv"
printf 'rep\tslab_shift\ttrack\tcache_regime\tjson_path\ttime_path\twarmup_path\ttime_status\trss_available\tmax_rss_bytes\trows\tchecksum\telapsed_ns\tgc_total_bytes_delta\tgc_collections_delta\tretained_values\tfixture_rows\tmark_count\tdata_bytes\tmark_bytes\tslab_count\tcapacity\tdirectory_capacity\n' > "$results_path"
printf 'expected_rows=%s\texpected_checksum=%s\trepetitions=%s\tshifts=%s\tcache_regime=%s\n' \
  "$expected_rows" "$expected_checksum" "$BENCH_REPETITIONS" "$BENCH_SHIFTS" "$BENCH_CACHE_REGIME" > "$run_dir/config.tsv"

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

check_decimal() {
  [[ "$1" =~ ^[0-9]+$ ]]
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

      verify_manifest
      if [[ "$BENCH_CACHE_REGIME" == warm_shared ]]; then
        # Warm the same fixture/column in a separate child before every timed
        # observation.  The warmup itself is not a measured observation.
        set +e
        "$binary_path" array "$fixture" "$column" "$slab_shift" "$expected_rows" "$expected_checksum" "$BENCH_CACHE_REGIME" \
          > /dev/null 2> "$warmup_path"
        warmup_status=$?
        set -e
        if (( warmup_status != 0 )); then
          die "$run_id warmup failed; see $warmup_path"
        fi
      else
        : > "$warmup_path"
      fi

      set +e
      "$time_bin" -l "$binary_path" "$track" "$fixture" "$column" "$slab_shift" "$expected_rows" "$expected_checksum" "$BENCH_CACHE_REGIME" \
        > "$json_path" 2> "$time_path"
      time_status=$?
      set -e
      if (( time_status != 0 )); then
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
      output_regime="$(json_field cache_regime "$json_path")"
      output_rows="$(json_field rows "$json_path")"
      output_expected_rows="$(json_field expected_rows "$json_path")"
      checksum="$(json_field checksum "$json_path")"
      output_expected_checksum="$(json_field expected_checksum "$json_path")"
      rows_ok="$(json_field rows_ok "$json_path")"
      checksum_ok="$(json_field checksum_ok "$json_path")"
      elapsed_ns="$(json_field elapsed_ns "$json_path")"
      gc_bytes="$(json_field gc_total_bytes_delta "$json_path")"
      gc_collections="$(json_field gc_collections_delta "$json_path")"
      gc_available="$(json_field gc_metrics_available "$json_path")"
      retained_values="$(json_field retained_values "$json_path")"
      fixture_rows="$(json_field fixture_rows "$json_path")"
      mark_count="$(json_field mark_count "$json_path")"
      data_bytes="$(json_field data_bytes "$json_path")"
      mark_bytes="$(json_field mark_bytes "$json_path")"
      output_shift="$(json_field slab_shift "$json_path")"
      slab_count="$(json_field slab_count "$json_path")"
      capacity="$(json_field capacity "$json_path")"
      directory_capacity="$(json_field directory_capacity "$json_path")"

      [[ "$output_track" == "$track" ]] || die "$run_id reported track=$output_track"
      [[ "$output_regime" == "$BENCH_CACHE_REGIME" ]] || die "$run_id reported cache_regime=$output_regime"
      [[ "$output_rows" == "$expected_rows" ]] || die "$run_id reported rows=$output_rows"
      [[ "$output_expected_rows" == "$expected_rows" ]] || die "$run_id reported expected_rows=$output_expected_rows"
      [[ "$output_expected_checksum" == "$expected_checksum" ]] || die "$run_id reported expected_checksum=$output_expected_checksum"
      [[ "$rows_ok" == true && "$checksum_ok" == true ]] || die "$run_id did not report parity success"
      [[ "$output_shift" == "$slab_shift" ]] || die "$run_id reported slab_shift=$output_shift"
      check_decimal "$checksum" || die "$run_id reported a non-decimal checksum"
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
      [[ "$elapsed_ns" != 0 ]] || die "$run_id reported zero elapsed_ns"
      [[ "$retained_values" == "$expected_rows" ]] || die "$run_id retained_values=$retained_values expected=$expected_rows"

      if [[ "$track" == slab ]]; then
        slab_size=$((1 << slab_shift))
        expected_slab_count=$(( (expected_rows + slab_size - 1) / slab_size ))
        expected_capacity=$(( expected_slab_count * slab_size ))
        [[ "$slab_count" == "$expected_slab_count" ]] || die "$run_id slab_count=$slab_count expected=$expected_slab_count"
        [[ "$capacity" == "$expected_capacity" ]] || die "$run_id capacity=$capacity expected=$expected_capacity"
        (( directory_capacity >= slab_count )) || die "$run_id directory_capacity=$directory_capacity below slab_count=$slab_count"
      else
        [[ "$slab_count" == 0 && "$capacity" == 0 && "$directory_capacity" == 0 ]] || die "$run_id array track reported slab geometry"
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
printf 'result_dir=%s\n' "$run_dir"
printf 'results_tsv=%s\n' "$results_path"
