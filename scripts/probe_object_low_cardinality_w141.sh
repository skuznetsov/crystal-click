#!/usr/bin/env bash
set -euo pipefail

# Runtime-only ClickHouse Object LowCardinality discovery probe. Do not build
# ClickHouse or Crystal here. Root owns execution through its resource guard.
[[ "${W141_EXECUTE_AS_ROOT:-}" == YES ]] || {
  printf 'refusing W141 execution without root-owned W141_EXECUTE_AS_ROOT=YES\n' >&2
  exit 1
}

BIN=/private/tmp/crystal-click-w112-runtime.u0Jn1f/clickhouse
EXPECTED_SHA=bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2
EXPECTED_HASH=d9bcb5ab007f0f6299f7f973f2642245bab3d028
SOURCE_REVISION=9007d227b64a3f8b667fc5258ceb2923f3cf477d
export TZ=UTC

ROOT="${W141_PROBE_ROOT:-}"
if [[ -z "$ROOT" ]]; then
  ROOT="$(mktemp -d /private/tmp/crystal-click-object-low-cardinality-w141.XXXXXX)"
fi
[[ "$ROOT" == /* && -d "$ROOT" && ! -L "$ROOT" ]] || {
  printf 'W141_PROBE_ROOT must be an existing absolute non-symlink directory\n' >&2
  exit 1
}
ROOT="$(CDPATH= cd -- "$ROOT" && pwd -P)"
case "$ROOT" in
  /private/tmp/crystal-click-object-low-cardinality-w141.*) ;;
  *) printf 'refusing unexpected W141 retained evidence root: %s\n' "$ROOT" >&2; exit 1 ;;
esac
if [[ -e "$ROOT/stores" || -e "$ROOT/results" || -e "$ROOT/manifest.json" ]]; then
  printf 'refusing to overwrite existing W141 evidence under %s\n' "$ROOT" >&2
  exit 1
fi
mkdir "$ROOT/stores" "$ROOT/results"

printf 'probe_dir=%s\nsource_reference_revision=%s\n' "$ROOT" "$SOURCE_REVISION" >"$ROOT/results/run.txt"
printf 'runtime_binary=%s\n' "$BIN" >>"$ROOT/results/run.txt"
actual_sha="$(shasum -a 256 "$BIN" | awk '{print $1}')"
[[ "$actual_sha" == "$EXPECTED_SHA" ]] || {
  printf 'runtime SHA mismatch: %s\n' "$actual_sha" >&2
  exit 1
}
version="$(TZ=UTC "$BIN" local --version)"
case "$version" in
  *26.10.1.1201*) ;;
  *) printf 'unexpected ClickHouse version: %s\n' "$version" >&2; exit 1 ;;
esac
printf 'runtime_sha256=%s\nruntime_version=%s\n' "$actual_sha" "$version" >>"$ROOT/results/run.txt"

click() {
  local store="$1" query="$2"
  shift 2
  TZ=UTC "$BIN" local --path "$store" --session_timezone=UTC --enable_time_time64_type=1 \
    --print_pretty_type_names=0 --query "$query" "$@"
}

# The numeric candidate opts in to the session setting. Kept as a helper
# rather than an empty Bash array because the host's system Bash may be 3.2.
candidate_click() {
  local store="$1" query="$2"
  shift 2
  if [[ "${candidate_suspicious:-no}" == yes ]]; then
    click "$store" "$query" --allow_suspicious_low_cardinality_types=1 "$@"
  else
    click "$store" "$query" "$@"
  fi
}

identity_store="$ROOT/stores/identity"
mkdir "$identity_store"
identity="$(click "$identity_store" "SELECT concat(name, '=', value) FROM system.build_options WHERE name IN ('GIT_HASH', 'VERSION_GITHASH') ORDER BY name FORMAT TSVRaw")"
expected_identity="$(printf 'GIT_HASH=%s\nVERSION_GITHASH=%s' "$EXPECTED_HASH" "$EXPECTED_HASH")"
[[ "$identity" == "$expected_identity" ]] || {
  printf 'runtime build identity mismatch\nexpected:\n%s\nactual:\n%s\n' "$expected_identity" "$identity" >&2
  exit 1
}
printf '%s\n' "$identity" >>"$ROOT/results/run.txt"

admitted=0
rejected=0

candidate() {
  local label="$1" declaration="$2" canonical="$3" guard="$4" cert_sql="$5" candidate_suspicious="${6:-no}"
  local store="$ROOT/stores/$label" out="$ROOT/results/$label"
  mkdir "$store" "$out"
  local create="CREATE TABLE default.p (id UInt8, j JSON(v $declaration)) ENGINE=MergeTree ORDER BY id SETTINGS index_granularity=4, index_granularity_bytes=0, min_rows_for_wide_part=0, min_bytes_for_wide_part=0"
  if ! candidate_click "$store" "$create" >"$out/create.stdout" 2>"$out/create.stderr"; then
    printf 'REQUIRED_DDL_ADMISSION_FAILED\t%s\t%s\n' "$label" "$declaration" | tee -a "$ROOT/results/decisions.tsv" >&2
    return 1
  fi

  # Each table gets its own literal nine-row JSONEachRow fixture. With the
  # explicit four-row granularity this crosses multiple marks and changes
  # dictionary contents across mark boundaries.
  case "$label" in
    lc-string)
      printf '%s\n' \
        '{"id":1,"j":{"v":"red"}}' '{"id":2,"j":{"v":"blue"}}' '{"id":3,"j":{"v":"red"}}' \
        '{"id":4,"j":{"v":"green"}}' '{"id":5,"j":{"v":"blue"}}' '{"id":6,"j":{"v":""}}' \
        '{"id":7,"j":{"v":"red"}}' '{"id":8,"j":{"v":"雪"}}' '{"id":9,"j":{"v":"green"}}' >"$out/fixture.jsonl"
      ;;
    lc-nullable-string)
      printf '%s\n' \
        '{"id":1,"j":{"v":"a"}}' '{"id":2,"j":{"v":null}}' '{"id":3,"j":{"v":"a"}}' \
        '{"id":4,"j":{"v":""}}' '{"id":5,"j":{"v":null}}' '{"id":6,"j":{"v":"b"}}' \
        '{"id":7,"j":{"v":"a"}}' '{"id":8,"j":{"v":"c"}}' '{"id":9,"j":{"v":null}}' >"$out/fixture.jsonl"
      ;;
    lc-int64)
      printf '%s\n' \
        '{"id":1,"j":{"v":-81985529216486896}}' '{"id":2,"j":{"v":81985529216486895}}' '{"id":3,"j":{"v":0}}' \
        '{"id":4,"j":{"v":-81985529216486896}}' '{"id":5,"j":{"v":81985529216486895}}' '{"id":6,"j":{"v":-1}}' \
        '{"id":7,"j":{"v":0}}' '{"id":8,"j":{"v":81985529216486895}}' '{"id":9,"j":{"v":-81985529216486896}}' >"$out/fixture.jsonl"
      ;;
    lc-date)
      printf '%s\n' \
        '{"id":1,"j":{"v":"2024-12-31"}}' '{"id":2,"j":{"v":"1970-01-02"}}' '{"id":3,"j":{"v":"2024-12-31"}}' \
        '{"id":4,"j":{"v":"2000-02-29"}}' '{"id":5,"j":{"v":"1970-01-02"}}' '{"id":6,"j":{"v":"2024-12-31"}}' \
        '{"id":7,"j":{"v":"2000-02-29"}}' '{"id":8,"j":{"v":"1970-01-02"}}' '{"id":9,"j":{"v":"2024-12-31"}}' >"$out/fixture.jsonl"
      ;;
    lc-ipv4)
      printf '%s\n' \
        '{"id":1,"j":{"v":"192.0.2.1"}}' '{"id":2,"j":{"v":"198.51.100.7"}}' '{"id":3,"j":{"v":"192.0.2.1"}}' \
        '{"id":4,"j":{"v":"203.0.113.9"}}' '{"id":5,"j":{"v":"198.51.100.7"}}' '{"id":6,"j":{"v":"192.0.2.1"}}' \
        '{"id":7,"j":{"v":"203.0.113.9"}}' '{"id":8,"j":{"v":"198.51.100.7"}}' '{"id":9,"j":{"v":"192.0.2.1"}}' >"$out/fixture.jsonl"
      ;;
    lc-fixed-string)
      printf '%s\n' \
        '{"id":1,"j":{"v":"cat"}}' '{"id":2,"j":{"v":"dog"}}' '{"id":3,"j":{"v":"cat"}}' \
        '{"id":4,"j":{"v":"owl"}}' '{"id":5,"j":{"v":"dog"}}' '{"id":6,"j":{"v":"fox"}}' \
        '{"id":7,"j":{"v":"cat"}}' '{"id":8,"j":{"v":"owl"}}' '{"id":9,"j":{"v":"dog"}}' >"$out/fixture.jsonl"
      ;;
    array-lc-string)
      printf '%s\n' \
        '{"id":1,"j":{"v":["red","blue"]}}' '{"id":2,"j":{"v":[]}}' '{"id":3,"j":{"v":["red"]}}' \
        '{"id":4,"j":{"v":["green","blue"]}}' '{"id":5,"j":{"v":["blue"]}}' '{"id":6,"j":{"v":[""]}}' \
        '{"id":7,"j":{"v":["red","雪"]}}' '{"id":8,"j":{"v":["雪"]}}' '{"id":9,"j":{"v":["green"]}}' >"$out/fixture.jsonl"
      ;;
    map-lc-string)
      printf '%s\n' \
        '{"id":1,"j":{"v":{"a":"red","b":"blue"}}}' '{"id":2,"j":{"v":{}}}' '{"id":3,"j":{"v":{"a":"red"}}}' \
        '{"id":4,"j":{"v":{"a":"green","b":"blue"}}}' '{"id":5,"j":{"v":{"b":"blue"}}}' '{"id":6,"j":{"v":{"a":""}}}' \
        '{"id":7,"j":{"v":{"a":"red","b":"雪"}}}' '{"id":8,"j":{"v":{"a":"雪"}}}' '{"id":9,"j":{"v":{"a":"green"}}}' >"$out/fixture.jsonl"
      ;;
    tuple-lc-string)
      printf '%s\n' \
        '{"id":1,"j":{"v":["red",4660]}}' '{"id":2,"j":{"v":["blue",1]}}' '{"id":3,"j":{"v":["red",4660]}}' \
        '{"id":4,"j":{"v":["green",4294967295]}}' '{"id":5,"j":{"v":["blue",1]}}' '{"id":6,"j":{"v":["",65535]}}' \
        '{"id":7,"j":{"v":["red",4660]}}' '{"id":8,"j":{"v":["雪",42]}}' '{"id":9,"j":{"v":["green",4294967295]}}' >"$out/fixture.jsonl"
      ;;
    *) printf 'missing literal fixture for %s\n' "$label" >&2; return 1 ;;
  esac
  candidate_click "$store" 'INSERT INTO default.p FORMAT JSONEachRow' <"$out/fixture.jsonl" >"$out/insert.stdout" 2>"$out/insert.stderr"

  local check_query="SELECT count() AS rows, uniqExact(toTypeName(j.v)) AS type_count, any(toTypeName(j.v)) AS type_name, countIf($guard) AS expected_rows FROM default.p FORMAT TSVRaw"
  local actual expected=$'9\t1\t'"$canonical"$'\t9'
  actual="$(candidate_click "$store" "$check_query")"
  printf '%s\n' "$actual" >"$out/value-check.tsv"
  [[ "$actual" == "$expected" ]] || {
    printf 'value/type witness mismatch for %s: expected %q, got %q\n' "$label" "$expected" "$actual" >&2
    return 1
  }

  candidate_click "$store" 'SHOW CREATE TABLE default.p FORMAT TSVRaw' >"$out/show-create.tsv"
  candidate_click "$store" "SELECT name, type FROM system.columns WHERE database='default' AND table='p' ORDER BY name FORMAT TSV" >"$out/columns.tsv"
  candidate_click "$store" "SELECT name, rows, marks, part_type, bytes_on_disk FROM system.parts WHERE database='default' AND table='p' AND active ORDER BY name FORMAT TSV" >"$out/part-metadata.tsv"
  local part
  part="$(candidate_click "$store" "SELECT path FROM system.parts WHERE database='default' AND table='p' AND active ORDER BY name LIMIT 1 FORMAT TSVRaw")"
  [[ -d "$part" ]] || { printf 'missing active part for %s: %s\n' "$label" "$part" >&2; return 1; }
  find "$part" -maxdepth 1 -type f -exec ls -ln {} \; | sort >"$out/stream-inventory.txt"
  if [[ -f "$part/serialization.json" ]]; then cp "$part/serialization.json" "$out/serialization.json"; fi

  # RowBinary's per-row LC corridor is a logical value stream. Native format
  # and the part inventory separately expose dictionary/index bulk framing.
  candidate_click "$store" 'SELECT j.v FROM default.p ORDER BY id FORMAT RowBinary' >"$out/values.rowbinary.bin"
  candidate_click "$store" 'SELECT j.v FROM default.p ORDER BY id FORMAT RowBinaryWithNamesAndTypes' >"$out/values.rowbinary-with-names-and-types.bin"
  candidate_click "$store" 'SELECT j.v FROM default.p ORDER BY id FORMAT Native' >"$out/values.native.bin"
  shasum -a 256 "$out/values.rowbinary.bin" "$out/values.rowbinary-with-names-and-types.bin" "$out/values.native.bin" >"$out/binary-sha256.txt"
  wc -c "$out/values.rowbinary.bin" "$out/values.rowbinary-with-names-and-types.bin" "$out/values.native.bin" >"$out/binary-sizes.txt"

  if [[ -n "$cert_sql" ]]; then
    # Use the direct output-format producer. formatRow() is a different
    # consumer path that can erase LowCardinality from the emitted type tag.
    candidate_click "$store" "$cert_sql" >"$out/binary-type-row.bin"
    od -An -v -tx1 "$out/binary-type-row.bin" | tr -d ' \n' >"$out/binary-type-row.hex"
  fi

  local active_parts check_output check_rows
  active_parts="$(candidate_click "$store" "SELECT count() FROM system.parts WHERE database='default' AND table='p' AND active FORMAT TSVRaw")"
  [[ "$active_parts" == 1 ]] || { printf 'expected one active part for %s, got %s\n' "$label" "$active_parts" >&2; return 1; }
  check_output="$(candidate_click "$store" 'CHECK TABLE default.p FORMAT TabSeparated')"
  printf '%s\n' "$check_output" >"$out/check-table.tsv"
  check_rows="$(awk -F '\t' 'BEGIN { ok=1 } NF != 3 || $1 == "" || $2 != "1" || $3 != "" { ok=0 } END { if (NR == 0 || !ok) exit 1; print NR }' <<<"$check_output")" || {
    printf 'CHECK TABLE returned malformed/failing rows for %s: %q\n' "$label" "$check_output" >&2
    return 1
  }
  [[ "$check_rows" == "$active_parts" ]] || {
    printf 'CHECK TABLE row count %s differs from active parts %s for %s\n' "$check_rows" "$active_parts" "$label" >&2
    return 1
  }
  printf 'ADMITTED_AND_CHECKED\t%s\t%s\n' "$label" "$canonical" | tee -a "$ROOT/results/decisions.tsv"
  admitted=$((admitted + 1))
}

must_reject() {
  local label="$1" declaration="$2" code="$3" cause="$4"
  local store="$ROOT/stores/reject-$label" out="$ROOT/results/reject-$label"
  mkdir "$store" "$out"
  if click "$store" "CREATE TABLE default.p (id UInt8, j JSON(v $declaration)) ENGINE=MergeTree ORDER BY id" >"$out/create.stdout" 2>"$out/create.stderr"; then
    printf 'UNEXPECTEDLY_ADMITTED\t%s\t%s\n' "$label" "$declaration" | tee -a "$ROOT/results/decisions.tsv" >&2
    return 1
  fi
  if ! rg -q -F "Code: $code. DB::Exception:" "$out/create.stderr" || ! rg -q -F "$cause" "$out/create.stderr"; then
    printf 'WRONG_REJECTION_CAUSE\t%s\t%s\n' "$label" "$declaration" | tee -a "$ROOT/results/decisions.tsv" >&2
    return 1
  fi
  printf 'REJECTED_AS_EXPECTED\t%s\t%s\n' "$label" "$declaration" | tee -a "$ROOT/results/decisions.tsv"
  rejected=$((rejected + 1))
}

# The single-path DDLs and independent fixtures establish exact nominal
# admission. Small fixed granules force repeated LC state transitions.
candidate lc-string 'LowCardinality(String)' 'LowCardinality(String)' \
  "(id=1 AND hex(j.v)='726564') OR (id=2 AND hex(j.v)='626C7565') OR (id=3 AND hex(j.v)='726564') OR (id=4 AND hex(j.v)='677265656E') OR (id=5 AND hex(j.v)='626C7565') OR (id=6 AND empty(j.v)) OR (id=7 AND hex(j.v)='726564') OR (id=8 AND hex(j.v)='E99BAA') OR (id=9 AND hex(j.v)='677265656E')" \
  "SELECT CAST(unhex('E99BAA'), 'LowCardinality(String)') AS x SETTINGS output_format_binary_encode_types_in_binary_format=1, print_pretty_type_names=0 FORMAT RowBinaryWithNamesAndTypes"

candidate lc-nullable-string 'LowCardinality(Nullable(String))' 'LowCardinality(Nullable(String))' \
  "(id=1 AND hex(j.v)='61') OR (id=2 AND isNull(j.v)) OR (id=3 AND hex(j.v)='61') OR (id=4 AND empty(assumeNotNull(j.v))) OR (id=5 AND isNull(j.v)) OR (id=6 AND hex(j.v)='62') OR (id=7 AND hex(j.v)='61') OR (id=8 AND hex(j.v)='63') OR (id=9 AND isNull(j.v))" \
  "SELECT x FROM (SELECT CAST(NULL, 'LowCardinality(Nullable(String))') AS x, 1 AS ordinal UNION ALL SELECT CAST('λ雪', 'LowCardinality(Nullable(String))') AS x, 2 AS ordinal) ORDER BY ordinal SETTINGS output_format_binary_encode_types_in_binary_format=1, print_pretty_type_names=0 FORMAT RowBinaryWithNamesAndTypes"

candidate lc-int64 'LowCardinality(Int64)' 'LowCardinality(Int64)' \
  "(id=1 AND j.v=-81985529216486896) OR (id=2 AND j.v=81985529216486895) OR (id=3 AND j.v=0) OR (id=4 AND j.v=-81985529216486896) OR (id=5 AND j.v=81985529216486895) OR (id=6 AND j.v=-1) OR (id=7 AND j.v=0) OR (id=8 AND j.v=81985529216486895) OR (id=9 AND j.v=-81985529216486896)" \
  "SELECT CAST(-81985529216486896, 'LowCardinality(Int64)') AS x SETTINGS output_format_binary_encode_types_in_binary_format=1, print_pretty_type_names=0 FORMAT RowBinaryWithNamesAndTypes" yes

candidate lc-date 'LowCardinality(Date)' 'LowCardinality(Date)' \
  "(id=1 AND j.v=toDate('2024-12-31')) OR (id=2 AND j.v=toDate('1970-01-02')) OR (id=3 AND j.v=toDate('2024-12-31')) OR (id=4 AND j.v=toDate('2000-02-29')) OR (id=5 AND j.v=toDate('1970-01-02')) OR (id=6 AND j.v=toDate('2024-12-31')) OR (id=7 AND j.v=toDate('2000-02-29')) OR (id=8 AND j.v=toDate('1970-01-02')) OR (id=9 AND j.v=toDate('2024-12-31'))" \
  "SELECT CAST(toDate('2024-12-31'), 'LowCardinality(Date)') AS x SETTINGS output_format_binary_encode_types_in_binary_format=1, print_pretty_type_names=0 FORMAT RowBinaryWithNamesAndTypes" yes

candidate lc-ipv4 'LowCardinality(IPv4)' 'LowCardinality(IPv4)' \
  "(id=1 AND j.v=toIPv4('192.0.2.1')) OR (id=2 AND j.v=toIPv4('198.51.100.7')) OR (id=3 AND j.v=toIPv4('192.0.2.1')) OR (id=4 AND j.v=toIPv4('203.0.113.9')) OR (id=5 AND j.v=toIPv4('198.51.100.7')) OR (id=6 AND j.v=toIPv4('192.0.2.1')) OR (id=7 AND j.v=toIPv4('203.0.113.9')) OR (id=8 AND j.v=toIPv4('198.51.100.7')) OR (id=9 AND j.v=toIPv4('192.0.2.1'))" \
  "SELECT CAST(toIPv4('192.0.2.1'), 'LowCardinality(IPv4)') AS x SETTINGS output_format_binary_encode_types_in_binary_format=1, print_pretty_type_names=0 FORMAT RowBinaryWithNamesAndTypes" yes

candidate lc-fixed-string 'LowCardinality(FixedString(3))' 'LowCardinality(FixedString(3))' \
  "(id=1 AND hex(j.v)='636174') OR (id=2 AND hex(j.v)='646F67') OR (id=3 AND hex(j.v)='636174') OR (id=4 AND hex(j.v)='6F776C') OR (id=5 AND hex(j.v)='646F67') OR (id=6 AND hex(j.v)='666F78') OR (id=7 AND hex(j.v)='636174') OR (id=8 AND hex(j.v)='6F776C') OR (id=9 AND hex(j.v)='646F67')" \
  "SELECT CAST('cat', 'LowCardinality(FixedString(3))') AS x SETTINGS output_format_binary_encode_types_in_binary_format=1, print_pretty_type_names=0 FORMAT RowBinaryWithNamesAndTypes"

candidate array-lc-string 'Array(LowCardinality(String))' 'Array(LowCardinality(String))' \
  "(id=1 AND length(j.v)=2 AND hex(j.v[1])='726564' AND hex(j.v[2])='626C7565') OR (id=2 AND empty(j.v)) OR (id=3 AND length(j.v)=1 AND hex(j.v[1])='726564') OR (id=4 AND length(j.v)=2 AND hex(j.v[1])='677265656E' AND hex(j.v[2])='626C7565') OR (id=5 AND length(j.v)=1 AND hex(j.v[1])='626C7565') OR (id=6 AND length(j.v)=1 AND empty(j.v[1])) OR (id=7 AND length(j.v)=2 AND hex(j.v[1])='726564' AND hex(j.v[2])='E99BAA') OR (id=8 AND length(j.v)=1 AND hex(j.v[1])='E99BAA') OR (id=9 AND length(j.v)=1 AND hex(j.v[1])='677265656E')" \
  "SELECT CAST(['red','雪'], 'Array(LowCardinality(String))') AS x SETTINGS output_format_binary_encode_types_in_binary_format=1, print_pretty_type_names=0 FORMAT RowBinaryWithNamesAndTypes"

candidate map-lc-string 'Map(String, LowCardinality(String))' 'Map(String, LowCardinality(String))' \
  "(id=1 AND length(mapKeys(j.v))=2 AND hex(j.v['a'])='726564' AND hex(j.v['b'])='626C7565') OR (id=2 AND empty(mapKeys(j.v))) OR (id=3 AND length(mapKeys(j.v))=1 AND hex(j.v['a'])='726564') OR (id=4 AND length(mapKeys(j.v))=2 AND hex(j.v['a'])='677265656E' AND hex(j.v['b'])='626C7565') OR (id=5 AND length(mapKeys(j.v))=1 AND hex(j.v['b'])='626C7565') OR (id=6 AND length(mapKeys(j.v))=1 AND empty(j.v['a'])) OR (id=7 AND length(mapKeys(j.v))=2 AND hex(j.v['a'])='726564' AND hex(j.v['b'])='E99BAA') OR (id=8 AND length(mapKeys(j.v))=1 AND hex(j.v['a'])='E99BAA') OR (id=9 AND length(mapKeys(j.v))=1 AND hex(j.v['a'])='677265656E')" \
  "SELECT CAST(map('a','red','b','雪'), 'Map(String, LowCardinality(String))') AS x SETTINGS output_format_binary_encode_types_in_binary_format=1, print_pretty_type_names=0 FORMAT RowBinaryWithNamesAndTypes"

candidate tuple-lc-string 'Tuple(s LowCardinality(String), n UInt32)' 'Tuple(s LowCardinality(String), n UInt32)' \
  "(id=1 AND hex(j.v.s)='726564' AND j.v.n=4660) OR (id=2 AND hex(j.v.s)='626C7565' AND j.v.n=1) OR (id=3 AND hex(j.v.s)='726564' AND j.v.n=4660) OR (id=4 AND hex(j.v.s)='677265656E' AND j.v.n=4294967295) OR (id=5 AND hex(j.v.s)='626C7565' AND j.v.n=1) OR (id=6 AND empty(j.v.s) AND j.v.n=65535) OR (id=7 AND hex(j.v.s)='726564' AND j.v.n=4660) OR (id=8 AND hex(j.v.s)='E99BAA' AND j.v.n=42) OR (id=9 AND hex(j.v.s)='677265656E' AND j.v.n=4294967295)" \
  "SELECT CAST(('雪', 4294967295), 'Tuple(s LowCardinality(String), n UInt32)') AS x SETTINGS output_format_binary_encode_types_in_binary_format=1, print_pretty_type_names=0 FORMAT RowBinaryWithNamesAndTypes"

# Constructor / wrapper legality controls. Their exact native causes are part
# of the observation; blanket creation failure is not counted.
must_reject lowcard-array 'LowCardinality(Array(UInt16))' 43 'DataTypeLowCardinality is supported only for numbers, strings, Date or DateTime, but got Array(UInt16).'
must_reject nullable-lowcard 'Nullable(LowCardinality(String))' 43 'Nested type LowCardinality(String) cannot be inside Nullable type'
must_reject nested-lowcard 'LowCardinality(LowCardinality(String))' 43 'DataTypeLowCardinality is supported only for numbers, strings, Date or DateTime, but got LowCardinality(String).'
must_reject lowcard-decimal 'LowCardinality(Decimal(9, 2))' 43 'DataTypeLowCardinality is supported only for numbers, strings, Date or DateTime, but got Decimal(9, 2).'

[[ "$admitted" == 9 && "$rejected" == 4 ]] || {
  printf 'incomplete W141 inventory: admitted=%s rejected=%s\n' "$admitted" "$rejected" >&2
  exit 1
}
printf 'summary admitted=%s rejected=%s\n' "$admitted" "$rejected" | tee -a "$ROOT/results/run.txt"
