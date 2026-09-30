# Shared Bool Value Semantics Frontier

Status: W98 is VERIFIED within the sealed profiles by the executed gates
below; pre-change anchor `ed66c53`. This is not full type compatibility.
The full compatible-type/MV/projection goal remains active. Memory and speed
optimization is deferred, and the matched ClickHouse slowdown target is unproved.

## Problem and seal

W97 independently qualified all 256 stock Bool payload bytes inside a named
Tuple: zero means false and any nonzero means true, while stock persists the
original UInt8 byte. At the pre-change anchor, root/Nullable, Array, Array(Map)
and Variant Bool decoders rejected noncanonical value bytes. Canonical-only Bool admission
is therefore not a complete value-domain compatibility policy. Reconcile all
already-admitted Bool value paths, and place the common policy in one owner
file rather than adding another local decoder.

Source reference: separate shallow checkout at
`a9581941254d6113f3740a8ec125ee7519cb1bda`; `SerializationBool.cpp` uses
the stored UInt8 as a condition for text, and its wrapper retains nested bulk
binary serialization. This is not an executable master certificate. Runtime
evidence remains pinned to ClickHouse 26.7.1.1315.

Admit: semantic Bool decoding for every UInt8 value in existing supported
root `Bool`/`Nullable(Bool)`, `Array(Bool)`/`Array(Nullable(Bool))`, the four
`Array(Map(UInt64|String, Bool|Nullable(Bool)))` forms, the existing
`Variant(Bool, String, UInt64)`, and W97 named Tuple paths. Writer output
remains canonical 0/1 with exact nominal Bool identity. Byte 2 becomes true
and rewrites as 1; this is not a raw-byte-preserving representation.

Reject/non-goal: new type compositions, formats or schemas; weakening null-map,
Variant-tag, offset/count, mark, checksum, materialization-budget or metadata
guards; introducing Bool into the numeric identity owner; lossless Bool byte
roundtrip; concurrency, memory/performance claims, general MV/projections.
Null-map bytes and discriminator tags have different roles from Bool values;
their existing strict policy remains unchanged and is not a claim about all
stock ClickHouse null-map or tag representations.

Risk: CAUTION (persisted value domain and shared codec dispatch).
Rollback: one coherent local commit after gates pass, from the clean anchor;
preserve unrelated work, with no push or history rewrite.
Strongest likely failure: broadly replacing boolean-looking checks and
accidentally admitting malformed null maps/tags, or leaving one preflight/full
reader path strict while a ranged reader becomes semantic. Check both.
Permissive staged semantic readback also no longer establishes canonical writer
bytes. Preserve independent raw writer-byte checks and investigate reusing the
existing staged stream-validation path before adding another full-file read.

## Plan and ownership

1. Inventory Bool value decode/encode sites and all superseded value-domain
   negative specs, separately from null-map/tag guards, under `src`, `spec`,
   `scripts` and the fresh source anchor. Root controls the require graph.
2. Run a stock-created existing-API RED discriminator on unchanged production:
   canonical positive controls, independent physical and RowBinary payload
   bytes, stock CHECK, then missing semantic reads in each affected family.
   Instrument errors are not a behavioral RED.
3. Add `src/crystal_click/bool_value_codec.cr` as the sole value policy owner:
   exact UInt8-to-Bool decode, Bool-to-UInt8 canonical encode, and owned byte
   buffer decoding. Root loads it before reader/writer consumers. Route all
   existing Bool value codec sites to this owner, retaining structural guards.
4. Replace only superseded value-byte rejection assertions with semantic
   assertions; retain null-map/tag and truncated/count/mark negative controls.
   Add all-256 owner tests and independent consumer/stock probes.
5. Run the declared gates, hostile root review, exact-path hygiene and an
   atomic local commit. Workers do not run heavy workloads or Git; root runs
   compiler/spec/ClickHouse serially under the unchanged watchdog.

Owners: reader/codec worker owns `wide_part.cr`, the new codec and focused
reader/codec specs; writer worker owns `wide_part_writer.cr`, Tuple writer
infrastructure/orchestration and staged writer regressions; oracle worker
owns the pre-production probe and final oracle
scripts/consumer tests. Root owns `src/crystal_click.cr`, living frontiers,
central runs and local Git. Everyone preserves other owners' changes.

## Executable gates

- Qualified stock RED before production, covering the nine affected profiles
  listed above with independent expected bytes and a canonical control.
- Focused DEBUG and RELEASE Bool codec, W15/W34/W57/W83 and W97 specs plus
  neighboring numeric/ownership/negative controls: zero failures/errors/pending.
- New pinned-stock bidirectional Bool-domain oracle: all UInt8 codes where
  applicable, canonical writes from actual decoded stock values, independent
  RowBinary/physical bytes, seeded comparator mismatch, ATTACH/CHECK, ranged
  and table/catalog consumers; zero failures. Profile assertions must remain
  exact, and stock conversions must not silently normalize the raw fixture.
- Existing Bool/enum/decimal, Bool Array, Variant W57, Array(Map) W83 and Tuple
  W97 oracles unchanged; zero failures.
- Full DEBUG `crystal spec --single-module --link-flags=-fuse-ld=ld`, Crystal
  format, shell syntax and diff checks; zero failures/errors/pending. Full
  RELEASE is not required or claimed.

All heavy runs use fresh 50% free-memory admission and the inspected external
`cogni-ml/scripts/run_safe.sh`, 600 seconds, 8192 MiB focused/oracle or 32768 MiB
full DEBUG. Its resource guards are not library performance measurements;
the W97 many-module lsof-row guard event is recorded separately from suite
results. No shared watchdog or unrelated process is modified.

Root must inspect the combined diff and attack incomplete routing, null-map/tag
guard erosion, ownership/nominal mismatch and lazy corruption before promoting
this slice. Worker source reviews are correlated, not independent evidence.
Evidence decays on codec/role/dispatch changes, admission/import/budget/mark
policy changes, fixtures, compiler semantics or pinned executable changes.

## Pre-production observations

On unchanged production `ed66c53`, root handle 10337 ran
`crystal spec spec/bool_semantics_w98_spec.cr --link-flags=-fuse-ld=ld`
under the declared watchdog. Ten examples executed: nine reached the intended
strict Bool value checks and raised `CorruptPartError`; the W97 named Tuple
semantic positive control passed. No compile/instrumentation error occurred.
The later helper addition explicitly size-validates the selected checksum
entries; `SizeChecked` does not authenticate recorded file hashes.

The first stock preprobe (29367) passed stock CHECK, exact schema, independent
RowBinary for all nine columns, physical all-256 payloads and separate 0/1
null maps. It then failed before canonical reader controls with
`UnsupportedFormatError: W15 per-column serialization is unsupported`.
This is an unqualified profile/instrument failure, not the required persisted
behavioral RED. Production remains frozen until an admitted stock profile
passes controls and reaches the intended value-domain discriminator.

After changing the fixture's sparse-serialization ratio to the existing 1.0
profile and asserting exact metadata, handle 34926 passed the stock checks
again and reached the intended RED for root and Nullable(Bool). It then
failed opening Array(Bool): that admitted serializer requires the one-UInt64-
key/value-pair shape when no key serializer record exists. The shared nine-
column table route is rejected; the probe must instead use nine separate
already-admitted key/value tables. Partial root evidence is retained, but
this run does not satisfy the all-nine gate or authorize production changes.

Staged canonical-byte discriminator 44444 independently exposed the W97
Tuple gap on unchanged production: the untouched canonical stage validated;
a cloned stage with a validly checksummed Bool byte 1 changed to 2 still read
as true, and the actual private staged validator accepted it. The intended
`expect_raises(CorruptPartError)` failed (one example, one failure, no errors).
This is a qualified raw-output guard RED, not a compression/checksum failure.

Nine exact-pair stock tables in 82947 passed their independent stock gates;
the first four canonical reader controls reached the intended Bool RED. The
Array(Map) canonical expectation omitted the outer Array layer and aborted
the probe. Correcting that expected container shape does not change fixture
bytes, production admission, or the value-domain policy; this instrument
failure still does not satisfy the all-nine behavioral gate.

Qualified stock discriminator 53379 used nine exact UInt64-key/value tables,
granularity two except the admitted Variant profile's three-row granularity,
and canonical first marks. Each table passed exact schema and metadata, stock
CHECK, independently encoded RowBinary, and physical Bool payloads containing
every UInt8 code; nullable controls separately checked only 0/1 null maps.
All nine canonical reader controls passed, followed by their intended strict
Bool-value `CorruptPartError`, and the probe reported `EXPECTED W98 RED: 9/9`
(exit 1). This satisfies the persisted pre-production gate. Root then released
the three bounded implementation owners; no production changes preceded it.
The physical-prefix expectation includes the repeated canonical control byte
and all 256 codes, not an assertion that the first 256 bytes are 0..255 in order.

## Source inventory

Bounded search: Bool-related decode/encode branches under `src`, with existing
byte-domain tests under `spec`. All direct Bool value decoding sites are in
`wide_part.cr`: root 1786/1820, Array 6883/6916, Array(Map) preflight 8222 and
materialization 8314, Variant 10065 and Tuple 14650 at the pre-change anchor.
Table/catalog consume those paths rather than independently decoding bytes.
Superseded value-byte rejection assertions occur in W15, W34, W57 and W83 specs;
W34 separately distinguishes payload and null streams. Existing nullable readers
consume but skip payload values beneath NULL; this behavior remains unchanged.

Writer value emissions are confined to `wide_part_writer.cr`:
`write_typed_numeric_le` (shared by root/Nullable, Array(Map) and Tuple), Variant
Bool sparse child, direct Array/Nullable Array children, and Array(Map)'s staged
expected bytes. Nullable null-map ternaries and Variant tags/modes are separate
control roles and must not use this value codec. The numerical width remains
one; no numeric identity or serialization-info default policy changes.

## Implementation review observations

Before runtime verification, root's diff review found a falsey-Bool bug in
the new Variant staged expected-byte traversal: an `as?(Bool)` assignment
condition skipped false while its count pass included it. The writer now
uses nominal `is_a?(Bool)` dispatch and needs a false/true positive control.
Root also found that opening both stream files before entering cleanup could
leak the first file if opening marks failed; nested `File.open` blocks now
cover both opens. Neither static correction is a passing executable gate.

A bounded search then found W34's older visible-byte 2/255 rejection assertion
missing from the initial superseded-test inventory. Its replacement checks
semantic true while independently checking that the mutated raw bytes remain
2/255. Strict nullable-flag controls remain. Additional Array(Map) and Variant
tests corrupt a selected Bool frame's compressed-size header while retaining
its file size, and must reject before callbacks. These discriminate retained
physical preflight from the removed value-domain loops; their runtime results
are included in the successful focused gates below.

## Runtime gate observations

Focused attempt 58099 failed during compilation, before executing examples:
the new W83 collector declared one extra nested Array level. Correcting that
test type is an instrument repair, not behavioral evidence. Attempt 59951
then executed 168 examples: one failure, zero errors/pending. The new W83
semantic callback test selected individual marks `[0, 1]` while expecting
one callback and one row; two callbacks were correct for that API. Its
candidate list is corrected to `[0]`. Neither attempt passes the declared
focused gate; the corrected source must be rerun.

Corrected focused DEBUG run 9366 passed all 168 examples with zero failures,
errors or pending (exit 0, approximately 39 seconds including compilation;
4.95 seconds test execution). It used the 31 listed Bool and neighboring
numeric/Tuple/ownership files under the declared unchanged guards. Release,
stock oracles and the full suite remain pending at this observation.

Focused RELEASE run 46636 passed the same 168 examples with zero failures,
errors or pending (exit 0, approximately 112 seconds including compilation;
1.57 seconds test execution). These timings are regression-run diagnostics,
not reader benchmarks. Production/spec source remained frozen between the
successful DEBUG and RELEASE runs; only the isolated oracle instrument and
this evidence document changed.

Root's oracle review separately found omitted physical hidden-NULL slots,
an invalid comparison of compact Variant framing with flat tags, and missing
high-level consumers for the original noncanonical stock parts. Correcting
those instruments must retain independent complete-byte expectations and
strict bounds, with source and canonical-writer consumers tested separately.

Corrected bidirectional stock oracle 33493 exited 0 at approximately 38 seconds
including compilation. All nine independently created exact-profile source
tables passed CHECK, schema/metadata, complete physical Bool streams including
hidden NULL slots, all 256 source payload codes, and full/selected raw RowBinary.
All nine passed semantic direct/ranged reads, typed full/window/candidate scans
and source catalog materialization. Writer inputs were the actual decoded
stock values. Their parts passed independent complete canonical-byte checks,
separate NULL maps and independently parsed compact Variant framing, stock
ATTACH/CHECK/full/selected RowBinary, direct/table scans and separate writer
catalogs. The deliberately wrong-byte comparator control also rejected.
The source and writer serialization JSON expectations are separately sealed
constants; both match the same existing pinned profile. No production
admission was widened to make the oracle pass.

All five existing oracle source/wrapper pairs remained unchanged and passed:

- 55716: Bool/Enum/Decimal, exit 0, approximately 20 seconds.
- 27785: Bool Array, exit 0, approximately 3 seconds.
- 26519: W57 BASIC/COMPACT Variant, exit 0, approximately 3 seconds.
- 37611: W83 Array(Map) in explicit `full` mode, exit 0, approximately 9 seconds.
- 33059: W97 Bool Tuple/all-256/AlwaysDefault consumers, exit 0,
  approximately 28 seconds.

Times include each wrapper's compilation and fixture checks, and are not
performance comparisons. Each used the same pinned binary, fresh owned
temporary paths, 8192-MiB watchdog and unchanged 50% memory admission/floor.

Full DEBUG run 71249 exited 0 at approximately 164 seconds including compilation:
1,259 examples, zero failures/errors/pending, 34.64 seconds test execution.
It used the declared single-module build and unchanged 600-second/32768-MiB
watchdog, with fresh 77% free-memory admission above the 50% floor. The linker
reported only its duplicate `-lc` warning. Full RELEASE was not run or claimed.
Crystal format checks on all 15 changed Crystal files, the new shell wrapper's
syntax check and diff whitespace checks passed. Exact-path staged hygiene is
the final pre-commit gate. These checks do not establish whole-library compatibility.

## Reproduction at the frozen W98 source

The historical `scripts/probe_bool_semantics_w98_red.cr` is a baseline-only RED
probe for `ed66c53`, not a green command for the post-change source.

The successful gates used Crystal 1.21.0, LLVM 22.1.8, aarch64 Darwin and the
pinned ClickHouse binary. Equivalent guarded commands from the repository root:

```sh
export COGNI_RUN_SAFE_MIN_FREE_PCT=50
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
export TMPDIR=/private/tmp
export CRYSTAL_CACHE_DIR=/private/tmp/crystal-click-w98-cache
export CLICKHOUSE_BIN=/Users/sergey/.local/bin/clickhouse
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
w98_guard=(bash /Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh)
w98_specs=(
  spec/bool_value_codec_spec.cr spec/bool_semantics_w98_spec.cr spec/wide_part_writer_bool_canonical_w98_spec.cr
  spec/wide_part_reader_w15_spec.cr spec/wide_part_writer_w15_spec.cr spec/wide_part_reader_w34_spec.cr
  spec/wide_part_reader_w57_spec.cr spec/wide_part_reader_w83_spec.cr spec/wide_part_writer_w83_spec.cr
  spec/wide_part_table_w83_spec.cr spec/offline_catalog_w83_spec.cr spec/wide_type_plan_w83_spec.cr
  spec/wide_tuple_bool_w97_spec.cr spec/wide_tuple_bool_model_w97_spec.cr spec/wide_part_writer_bool_tuple_w97_spec.cr
  spec/bool_tuple_consumers_w97_spec.cr spec/wide_tuple_numeric_w96_spec.cr spec/wide_tuple_numeric_model_w96_spec.cr
  spec/wide_part_writer_numeric_tuple_w96_spec.cr spec/numeric_tuple_consumers_w96_spec.cr spec/wide_tuple_type_plan_spec.cr
  spec/wide_tuple_column_data_ownership_spec.cr spec/wide_tuple_row_w95_spec.cr spec/offline_catalog_w95_tuple_values_spec.cr
  spec/wide_part_table_w95_tuple_spec.cr spec/wide_part_writer_compositional_tuple_spec.cr spec/wide_part_writer_tuple_spec.cr
  spec/wide_part_reader_compositional_tuple_spec.cr spec/wide_part_reader_tuple_metadata_spec.cr spec/wide_part_reader_tuple_empty_eof_spec.cr
  spec/fixed_numeric_scan_spec.cr
)
"${w98_guard[@]}" /opt/homebrew/bin/crystal 600 8192 spec "${w98_specs[@]}" --link-flags=-fuse-ld=ld
"${w98_guard[@]}" /opt/homebrew/bin/crystal 600 8192 spec "${w98_specs[@]}" --release --link-flags=-fuse-ld=ld
"${w98_guard[@]}" /bin/bash 600 8192 scripts/check_bool_semantics_oracle.sh
"${w98_guard[@]}" /bin/bash 600 8192 scripts/check_bool_enum_decimal_oracle.sh
"${w98_guard[@]}" /bin/bash 600 8192 scripts/check_bool_array_oracle.sh
"${w98_guard[@]}" /bin/bash 600 8192 scripts/check_wide_variant_w57_oracle.sh
W83_ORACLE_MODE=full "${w98_guard[@]}" /bin/bash 600 8192 scripts/check_array_map_bool_values_w83_oracle.sh
"${w98_guard[@]}" /bin/bash 600 8192 scripts/check_bool_tuple_oracle.sh
"${w98_guard[@]}" /opt/homebrew/bin/crystal 600 32768 spec --single-module --link-flags=-fuse-ld=ld
```

## Scoped closure and continuation

Root independently inspected the combined production diff, actual staging
call sites, selected-frame preflight/callback ordering, shared Bool routing,
nominal Bool versus UInt8 dispatch, null maps/tags and the independent oracle
instruments. The two same-lineage worker static reviews are correlated
support, not independent runtime proof. With the executed gates above, root's
verdict is ROBUST for the sealed W98 profiles and aggregate import boundary.

Residual limitations: arbitrary recursive compositions, alternate physical
layouts and current-master runtime behavior are not certified. Tuple staging
still materializes its bounded semantic readback before the per-mark raw
check. Existing Array(Map) staged validation opens multiple files before its
cleanup region; an intermediate open failure remains a separate resource-
ownership concern, not resolved by W98's newly nested Bool-stream file opens.
No dedicated root-Bool corrupt-frame callback regression was added; existing
decode-before-yield ordering was source-reviewed, and selected Variant and
Array(Map) frame-corruption controls executed. No performance or allocation
claim is made.

The wider type/MV/projection goal remains active. Next compatibility falsifier:
a stock-created named Tuple with semantic Date/time, Decimal, UUID/IP or Enum
leaves, checked for exact nominal types and physical substreams before any
admission extension; then bidirectional writer and table/catalog consumers.
Recursive Nullable/container Tuple forms, broader JSON/Dynamic/Variant
profiles, current-master additions, MV/projection writes and large facade
decomposition remain separate work. Keep memory/performance work deferred.

Certificate anchor: the W98 atomic commit containing this document and its
exact source/tests/oracles; predecessor `ed66c53`. Evidence is valid only for
the sealed profile, compiler and pinned executable stated here. Refresh the
affected focused and stock gates when their listed decay triggers change;
a stale or failed certificate reopens the relevant compatibility claim.
