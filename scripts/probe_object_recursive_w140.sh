#!/usr/bin/env bash
set -euo pipefail

# Runtime-only ClickHouse JSON typed-path probe. No Crystal/native build occurs.
# Keep all stores and output beneath a fresh retained evidence directory.
# This is a native discovery probe, not paired Crystal compatibility evidence.
ROOT="${W140_PROBE_ROOT:-}"
if [[ -z "$ROOT" ]]; then
  ROOT="$(mktemp -d /private/tmp/crystal-click-object-recursive-w140.XXXXXX)"
fi
[[ "$ROOT" == /* && -d "$ROOT" ]] || { echo "W140_PROBE_ROOT must be an existing absolute directory" >&2; exit 1; }
BIN=/private/tmp/crystal-click-w112-runtime.u0Jn1f/clickhouse
EXPECTED_SHA=bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2
EXPECTED_HASH=d9bcb5ab007f0f6299f7f973f2642245bab3d028
export TZ=UTC

if [[ -e "$ROOT/stores" || -e "$ROOT/results" ]]; then
  printf 'refusing to overwrite existing probe evidence under %s\n' "$ROOT" >&2
  exit 1
fi
mkdir -p "$ROOT/stores" "$ROOT/results"
printf 'probe_dir=%s\n' "$ROOT" | tee "$ROOT/results/run.txt"
printf 'binary=%s\n' "$BIN" | tee -a "$ROOT/results/run.txt"

actual_sha="$(shasum -a 256 "$BIN" | awk '{print $1}')"
[[ "$actual_sha" == "$EXPECTED_SHA" ]] || { echo "binary SHA mismatch: $actual_sha" >&2; exit 1; }
version="$(TZ=UTC "$BIN" local --version)"
case "$version" in
  *26.10.1.1201*) ;;
  *) echo "unexpected ClickHouse version: $version" >&2; exit 1 ;;
esac
printf 'sha256=%s\nversion=%s\n' "$actual_sha" "$version" | tee -a "$ROOT/results/run.txt"

click() {
  local store="$1" query="$2"
  shift 2
  TZ=UTC "$BIN" local --path "$store" --session_timezone=UTC --enable_time_time64_type=1 --print_pretty_type_names=0 --query "$query" "$@"
}

# Verify both source/build identity strings before any DDL probe.
id_store="$ROOT/stores/identity"
mkdir -p "$id_store"
identity="$(click "$id_store" "SELECT concat(name, '=', value) FROM system.build_options WHERE name IN ('GIT_HASH', 'VERSION_GITHASH') ORDER BY name FORMAT TSVRaw")"
expected_identity="$(printf 'GIT_HASH=%s\nVERSION_GITHASH=%s' "$EXPECTED_HASH" "$EXPECTED_HASH")"
[[ "$identity" == "$expected_identity" ]] || {
  printf 'build identity mismatch\nexpected:\n%s\nactual:\n%s\n' "$expected_identity" "$identity" >&2
  exit 1
}
printf '%s\n' "$identity" | tee -a "$ROOT/results/run.txt"

admitted=0
rejected=0

candidate() {
  local label="$1" declaration="$2" canonical="$3" row1="$4" row2="$5" guard="$6"
  local store="$ROOT/stores/$label" out="$ROOT/results/$label"
  mkdir -p "$store" "$out"
  local create="CREATE TABLE default.p (id UInt8, j JSON(v $declaration)) ENGINE=MergeTree ORDER BY id SETTINGS min_rows_for_wide_part=0, min_bytes_for_wide_part=0"

  if ! click "$store" "$create" >"$out/create.stdout" 2>"$out/create.stderr"; then
    printf 'REQUIRED_DDL_ADMISSION_FAILED\t%s\t%s\n' "$label" "$declaration" | tee -a "$ROOT/results/decisions.tsv" >&2
    return 1
  fi

  # These are independent literal JSONEachRow fixtures, never SELECT output.
  if [[ "$row1" == __MISSING__ && "$row2" == __MISSING__ ]]; then
    printf '{"id":1,"j":{}}\n{"id":2,"j":{}}\n' \
      | click "$store" 'INSERT INTO default.p FORMAT JSONEachRow' >"$out/insert.stdout" 2>"$out/insert.stderr"
  elif [[ "$row2" == __MISSING__ ]]; then
    printf '{"id":1,"j":{"v":%s}}\n{"id":2,"j":{}}\n' "$row1" \
      | click "$store" 'INSERT INTO default.p FORMAT JSONEachRow' >"$out/insert.stdout" 2>"$out/insert.stderr"
  else
    printf '{"id":1,"j":{"v":%s}}\n{"id":2,"j":{"v":%s}}\n' "$row1" "$row2" \
      | click "$store" 'INSERT INTO default.p FORMAT JSONEachRow' >"$out/insert.stdout" 2>"$out/insert.stderr"
  fi

  local check_query="SELECT count() AS rows, uniqExact(toTypeName(j.v)) AS type_count, any(toTypeName(j.v)) AS type_name, countIf($guard) AS expected_rows FROM default.p FORMAT TSVRaw"
  local actual
  actual="$(click "$store" "$check_query")"
  printf '%s\n' "$actual" >"$out/value-check.tsv"
  local expected=$'2\t1\t'"$canonical"$'\t2'
  [[ "$actual" == "$expected" ]] || {
    printf 'FAIL %s: expected %q, got %q\n' "$label" "$expected" "$actual" >&2
    return 1
  }

  # Capture the actual stored part's stream inventory and serialization metadata.
  click "$store" "SHOW CREATE TABLE default.p FORMAT TSVRaw" >"$out/show-create.tsv"
  click "$store" "SELECT name, type FROM system.columns WHERE database='default' AND table='p' ORDER BY name FORMAT TSV" >"$out/columns.tsv"
  local part
  part="$(click "$store" "SELECT path FROM system.parts WHERE database='default' AND table='p' AND active ORDER BY name LIMIT 1 FORMAT TSVRaw")"
  [[ -d "$part" ]] || { echo "missing active part for $label: $part" >&2; return 1; }
  find "$part" -maxdepth 1 -type f -exec ls -ln {} \; | sort >"$out/stream-inventory.txt"
  if [[ -f "$part/serialization.json" ]]; then
    cp "$part/serialization.json" "$out/serialization.json"
  fi

  local active_parts
  active_parts="$(click "$store" "SELECT count() FROM system.parts WHERE database='default' AND table='p' AND active FORMAT TSVRaw")"
  [[ "$active_parts" =~ ^[1-9][0-9]*$ ]] || {
    printf 'expected a positive active-part count for %s, got %q\n' "$label" "$active_parts" >&2
    return 1
  }

  local check_output check_rows
  check_output="$(click "$store" 'CHECK TABLE default.p FORMAT TabSeparated')"
  printf '%s\n' "$check_output" >"$out/check-table.tsv"
  check_rows="$(awk -F '\t' 'BEGIN { ok=1 } NF != 3 || $1 == "" || $2 != "1" || $3 != "" { ok=0 } END { if (NR == 0 || !ok) exit 1; print NR }' <<<"$check_output")" || {
    printf 'CHECK TABLE returned malformed or failing rows for %s: %q\n' "$label" "$check_output" >&2
    return 1
  }
  [[ "$check_rows" == "$active_parts" ]] || {
    printf 'CHECK TABLE row count for %s was %s; active system.parts count was %s\n' "$label" "$check_rows" "$active_parts" >&2
    return 1
  }
  printf 'ADMITTED_AND_CHECKED\t%s\t%s\n' "$label" "$canonical" | tee -a "$ROOT/results/decisions.tsv"
  admitted=$((admitted + 1))
}

must_reject() {
  local label="$1" declaration="$2" code="$3" cause="$4"
  local store="$ROOT/stores/reject-$label" out="$ROOT/results/reject-$label"
  mkdir -p "$store" "$out"
  if click "$store" "CREATE TABLE default.p (id UInt8, j JSON(v $declaration)) ENGINE=MergeTree ORDER BY id" >"$out/create.stdout" 2>"$out/create.stderr"; then
    printf 'UNEXPECTEDLY_ADMITTED\t%s\t%s\n' "$label" "$declaration" | tee -a "$ROOT/results/decisions.tsv" >&2
    return 1
  fi
  # A missing binary/store or unrelated DDL error is not a constraint witness.
  if ! rg -q -F "Code: $code. DB::Exception:" "$out/create.stderr" || ! rg -q -F "$cause" "$out/create.stderr"; then
    printf 'WRONG_REJECTION_CAUSE\t%s\t%s\n' "$label" "$declaration" | tee -a "$ROOT/results/decisions.tsv" >&2
    return 1
  fi
  printf 'REJECTED_AS_EXPECTED\t%s\t%s\n' "$label" "$declaration" | tee -a "$ROOT/results/decisions.tsv"
  rejected=$((rejected + 1))
}

# Scalar and recursive candidates. Empty arrays/maps and explicit nulls are
# included where meaningful; guards check both rows and the canonical type.
candidate array-u16 'Array(UInt16)' 'Array(UInt16)' '[1,3]' '[2]' 'if(id=1, j.v=[1,3], j.v=[2])'
candidate map-string-u16 'Map(String, UInt16)' 'Map(String, UInt16)' '{"a":1,"b":3}' '{}' 'if(id=1, length(mapKeys(j.v))=2 AND j.v[char(97)]=1 AND j.v[char(98)]=3, empty(mapKeys(j.v)))'
candidate tuple-unnamed 'Tuple(UInt16, String)' 'Tuple(UInt16, String)' '[17,"u"]' '[18,"v"]' 'if(id=1, tupleElement(j.v,1)=17 AND tupleElement(j.v,2)=char(117), tupleElement(j.v,1)=18 AND tupleElement(j.v,2)=char(118))'
candidate tuple-named 'Tuple(n UInt16, s String)' 'Tuple(n UInt16, s String)' '[17,"a"]' '[18,"b"]' 'if(id=1, j.v.n=17 AND j.v.s=char(97), j.v.n=18 AND j.v.s=char(98))'
# Explicit [] input failed in the initial retained native discovery run.
# Missing-path defaults test a separate producer corridor, not that input form.
candidate tuple-empty-default 'Tuple()' 'Tuple()' '__MISSING__' '__MISSING__' '1'
candidate nullable-tuple 'Nullable(Tuple(n UInt16, s String))' 'Nullable(Tuple(n UInt16, s String))' '[11,"z"]' 'null' 'if(id=1, tupleElement(assumeNotNull(j.v),1)=11 AND tupleElement(assumeNotNull(j.v),2)=char(122), isNull(j.v))'
candidate nullable-u16 'Nullable(UInt16)' 'Nullable(UInt16)' '7' 'null' 'if(id=1, j.v=7, isNull(j.v))'
candidate nullable-missing 'Nullable(UInt16)' 'Nullable(UInt16)' '9' '__MISSING__' 'if(id=1, j.v=9, isNull(j.v))'
candidate lowcard-string 'LowCardinality(String)' 'LowCardinality(String)' '"lc"' '""' 'if(id=1, j.v=concat(char(108),char(99)), empty(j.v))'
candidate variant-string-u16 'Variant(String, UInt16)' 'Variant(String, UInt16)' '"branch"' '17' 'isNotNull(j.v)'
candidate dynamic 'Dynamic' 'Dynamic' '17' '"dynamic"' 'isNotNull(j.v)'
candidate array-map 'Array(Map(String, UInt16))' 'Array(Map(String, UInt16))' '[{"a":1},{"b":2}]' '[]' 'if(id=1, length(j.v)=2 AND j.v[1][char(97)]=1 AND j.v[2][char(98)]=2, empty(j.v))'
candidate map-tuple 'Map(String, Tuple(n UInt16, s String))' 'Map(String, Tuple(n UInt16, s String))' '{"x":[1,"a"]}' '{"y":[2,"b"]}' 'if(id=1, tupleElement(j.v[char(120)],1)=1 AND tupleElement(j.v[char(120)],2)=char(97), tupleElement(j.v[char(121)],1)=2 AND tupleElement(j.v[char(121)],2)=char(98))'
candidate tuple-array-map 'Tuple(a Array(UInt16), m Map(String, UInt16))' 'Tuple(a Array(UInt16), m Map(String, UInt16))' '[[1,2],{"x":3}]' '[[4],{}]' 'if(id=1, j.v.a=[1,2] AND j.v.m[char(120)]=3, j.v.a=[4] AND empty(mapKeys(j.v.m)))'
candidate array-nullable 'Array(Nullable(UInt16))' 'Array(Nullable(UInt16))' '[1,null]' '[]' 'if(id=1, length(j.v)=2 AND j.v[1]=1 AND isNull(j.v[2]), empty(j.v))'
candidate array-missing 'Array(UInt16)' 'Array(UInt16)' '[9]' '__MISSING__' 'if(id=1, j.v=[9], empty(j.v))'
candidate decimal 'Decimal(9, 2)' 'Decimal(9, 2)' '12.34' '-0.50' 'if(id=1, toInt64(j.v*100)=1234, toInt64(j.v*100)=-50)'
candidate datetime64-utc "DateTime64(3, 'UTC')" "DateTime64(3, 'UTC')" '"2024-01-02 03:04:05.123"' '"2024-01-02 03:04:06.000"' 'if(id=1, toUnixTimestamp64Milli(j.v)=1704164645123, toUnixTimestamp64Milli(j.v)=1704164646000)'

# Constructor-level controls: each must be rejected, and rejection is retained.
must_reject map-nullable-key 'Map(Nullable(String), UInt16)' 36 'Map cannot have a key of type Nullable(String).'
must_reject json-map-array-key 'Map(Array(UInt8), UInt16)' 43 "JSON serialization doesn't support the return type schema: Map(Array(UInt8), UInt16) with key type not String."
must_reject json-map-numeric-key 'Map(UInt16, UInt16)' 43 "JSON serialization doesn't support the return type schema: Map(UInt16, UInt16) with key type not String."
must_reject json-nested-map-numeric-key 'Array(Map(UInt16, UInt16))' 43 "JSON serialization doesn't support the return type schema: Map(UInt16, UInt16) with key type not String."
must_reject nullable-array 'Nullable(Array(UInt16))' 43 'Nested type Array(UInt16) cannot be inside Nullable type.'
must_reject lowcard-array 'LowCardinality(Array(UInt16))' 43 'DataTypeLowCardinality is supported only for numbers, strings, Date or DateTime, but got Array(UInt16).'
must_reject variant-nested 'Variant(String, Variant(UInt8, UInt16))' 36 'Nested Variant types are not allowed.'
must_reject variant-dynamic 'Variant(String, Dynamic)' 36 'Dynamic type is not allowed inside Variant type.'
must_reject variant-nullable 'Variant(String, Nullable(UInt8))' 36 'Nullable/LowCardinality(Nullable) types are not allowed inside Variant type.'

[[ "$admitted" == 18 && "$rejected" == 9 ]] || { echo 'incomplete required probe inventory' >&2; exit 1; }
printf 'summary admitted=%s rejected=%s\n' "$admitted" "$rejected" | tee -a "$ROOT/results/run.txt"
