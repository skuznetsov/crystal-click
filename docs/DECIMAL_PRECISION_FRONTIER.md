# Decimal Precision Frontier

Status: W102 implemented and verified within the bounded profile below on
2026-09-30; the verified predecessor is
`bab43e5924f2807c9bf5902ccc2605f10664d178`.
This slice advances paired type compatibility, not the full types,
MV/projection, architecture or later matched-performance goal.

## Contract and boundaries

Admit every canonical `Decimal(P, S)` with P=1..76 and S=0..P in the six
previously supported shapes: scalar, Nullable scalar, Array, Array of Nullable
leaves, two-level Array, and two-level Array of Nullable leaves. Preserve exact
P/S in column metadata, typed accessors, selected-mark scans, table batches,
catalog column values and writer staged readback. Precision bands 1..9,
10..18, 19..38 and 39..76 select signed 4/8/16/32-byte coefficients.

Retain the existing raw carriers Int32, Int64, Int128 and Decimal256Value and
their public reader methods. Raw coefficient bytes neither carry nor infer
P/S. There is no SQL arithmetic, rounding, rescaling, decimal text conversion
or SQL precision-range enforcement for raw coefficients. Same-width integer
types do not gain Decimal identity. Preserve all old width-named writer calls:
add an optional named `precision` after existing arguments, defaulting to
9/18/38/76. Reject a precision outside the entry point's physical band and
S>P before creating a staging directory. Carry exact P through metadata and
readback, not merely preflight. Existing positional rows_per_mark remains valid.

Persisted declarations must be canonical exact `Decimal(P, S)` with bounded,
non-leading-zero integers. Catalog DDL normalization may additionally accept
Decimal32/64/128/256(S), Decimal(P) and bare Decimal, in these six shapes,
normalizing respectively to max-P, (P,0) and (10,0). Retain original DDL spelling
separately. Do not normalize an arbitrary P to its carrier's maximum. General
SQL spelling/whitespace/case aliases are not admitted by this bounded parser.

Keep the prior Wide/LZ4/plain adaptive mark, sorted UInt64-key physical profile
and existing null-map/zero-placeholder, offset/cardinality, checksum and
materialization guards. Nullable Array containers, deeper Arrays, Map Decimal
compositions, additional Tuple shapes, LowCardinality Decimal, Sparse/Compact,
other codecs/marks and current-master metadata extensions remain rejected.
The W101 named-flat Tuple profile remains unchanged and must regress green.

## Ownership and context bridge

One concrete owner per file: DecimalType owns exact leaf P/S and width laws;
DecimalColumnType owns only six-shape canonical parsing and bounded DDL
normalization. WideTupleDecimalType retains its public identity and buffer
contract while delegating the shared descriptor law; do not rename it or force
Tuple nominal wrappers into legacy raw APIs. Facades delegate identity decisions
to these owners and keep existing physical codecs. No parallel Cartesian value
union, per-combination class or speculative performance rewrite is needed.

Fresh inspected source is a9581941254d6113f3740a8ec125ee7519cb1bda at
`/Users/sergey/SrcArchives/clickhouse-2026-09-29-depth1`; runtime oracle remains
ClickHouse 26.7.1.1315, not a current-master build. DataTypesDecimal.cpp names
exact P/S but SQL equals compares carrier/scale without P. That lossy SQL
equivalence cannot authorize metadata or descriptor precision loss. Binary
serialization uses signed little-endian carrier bytes; payload equality is
not schema identity. Nullable RowBinary omits a coefficient for NULL, whereas
part storage retains its qualified nested zero placeholder. Array defaults
are empty, distinct from an outer Array containing an empty inner Array.
Default-statistics predicates and stream inventories require runtime probes,
not imports from SQL value semantics. Source/runtime or metadata/codec changes
invalidate the corresponding evidence and require affected gates to rerun.

## Risk, plan and falsifiers

CAUTION: additive API plus persisted type admission across shared consumers.
Rollback is the isolated W102 diff/one coherent local commit from the clean
predecessor. No push, dependency/runtime installation, history rewrite or old
ClickHouse checkout mutation. Strongest failure: widened parsing silently
loses P or routes an interior precision through the wrong table/catalog codec.
Guard it with exact metadata and raw-value comparisons in every shape/width,
including same-carrier/same-scale/different-P counterexamples.

Root owns this document, root requires, combined inspection, all serial
compiler/ClickHouse runs and commit. The external cogni-ml run_safe.sh envelope
is 600 seconds/8 GiB for focused and oracle gates, 600 seconds/32 GiB with
--single-module for full DEBUG, and a 50 percent system-free floor. Luna Max
workers are correlated assistance, not independent execution evidence.

1. Reader/model worker owns DecimalType, DecimalColumnType,
   WideTupleDecimalType, narrow WidePart/WidePartTable/OfflineCatalog adapters
   and new descriptor/admission/reader specs. Root owns require ordering.
2. Writer worker owns WidePartWriter precision propagation and new writer
   specs, preserving legacy calls and pre-stage validation.
3. Oracle worker owns independent stock RED/final bidirectional scripts and
   high-level consumer specs. It must qualify stock bytes/marks/CHECK and
   independent RowBinary before observing expected reader rejection.

Initially workers write tests/instruments only. A compiling admission RED
must exercise all 3,002 P/S pairs in all six shapes, with old/max-P positives,
malformed/bounds/unsupported-shape negatives and canonical-vs-DDL separation.
A separate stock-qualified RED must cover all six shapes in every carrier
band using lower-than-maximum P before production is authorized. Instrument
compilation or fixture construction failure is not feature RED.

Final DoD: focused DEBUG and RELEASE specs, full DEBUG --single-module,
independent bidirectional oracle, legacy scalar/Array/two-level Decimal and
W101 Tuple regression oracles, format/shell/diff hygiene, then root hostile
review before one atomic local commit. Final stock profiles hit P=1,9,10,18,
19,38,39,76 plus lower-than-maximum interior P, scales 0/interior/P, NULL vs
zero, empty outer vs empty inner Arrays and all-null/all-empty cases. Separate
native carrier extrema qualify raw backing compatibility without claiming SQL
text validity. Assert exact P/S, full/window reads, table/catalog values,
conservative UInt64 PK candidate selection and writer ATTACH/CHECK/RowBinary.
Do not infer exact row filtering from candidate granule selection.

Additional falsifiers: wrong band/scale before staging, empty buffers retaining
metadata, tampered same-width P/S rejected by staged validator, nil placeholders
and both Array offset levels, semantic same-width integer refusal, alias/bare/
implicit-scale normalization, unsupported deeper/composed shapes remaining
closed, bounded parser input and old default writer schema unchanged.
Logical accounting is not a memory/RSS or performance certificate.

## Observed baseline evidence

At unchanged production predecessor bab43e5, root executed
`run_safe.sh /opt/homebrew/bin/crystal 600 8192 spec
spec/decimal_precision_admission_w102_spec.cr --link-flags=-fuse-ld=ld`, with
the declared 50 percent system-free floor. Compilation succeeded: four
examples, two expected behavioral failures, zero errors/pending. The full
matrix measured 17,142 rejected legal declarations out of 18,012; existing
max-P positives and malformed/deeper-shape negatives passed. The separate
Decimal(P)/bare normalization group failed at its Decimal(P) assertion;
its eight printed examples are capped samples, not a total rejection count.
Width-alias normalization passed. This parser test alone does not qualify
physical streams or writer compatibility.

Root then executed the stock RED launcher under the same 600-second/8-GiB
watchdog. The completed probe qualified all 24 interior-P fixtures (P=7,15,25,50
across six shapes) against ClickHouse 26.7.1.1315: exact columns/substreams,
complete decoded physical stream bytes, logical mark row counts, system.columns,
CHECK TABLE, and independent full/key-range RowBinary. Six shape-matched max-P9
controls additionally passed full and selected-mark typed reads. A seeded
one-byte defect was rejected by the RowBinary comparator. Only after these
controls did the unchanged typed reader reject all 24 interior declarations with
the exact UnsupportedFormatError reason. The probe emitted EXPECTED RED and
exited 1 after approximately 10 seconds; this authorized the production patch.

Earlier instrument failures were not feature evidence: a Process.run nil-input
compile error, an incorrect one-level .size stream name, and cumulative Array
offset expectations. They were repaired before the qualifying run. The fresh
SerializationArray.cpp position-independent law writes each array cardinality,
not cumulative offsets or per-granule-reset cumulative offsets, at both levels.
The stock ratio-1 serialization records were empty, so this RED makes no default
counter claim; its mark-byte helper checks row counts, not all frame bounds.

## Measured instrument refutations

Instrument failures are not production failures or completed oracle evidence.
The final oracle initially exposed an invariant nullable-Array fixture type,
then an incorrect physical-EOF assumption. The pinned stock scalar P1 part's
key sentinel was `{0, 40, 0}` for one frame spanning 52 encoded bytes and 40
decoded bytes. It addresses logical EOF inside the final frame. Fresh source
corroborates this: `MergeTreeDataPartWriterWide.cpp:510-511` captures the
compressed/decompressed mark pair, `:955-974` writes the final zero-row mark,
and `:881` calls stream pre-finalization afterward; stream
`MergeTreeWriterStream.cpp:252-254` drains the compression buffers. This
source snapshot is not the pinned executable's exact build revision.

The oracle resolves every data and sentinel mark to an independently encoded
logical byte prefix, with compressed-frame and decoded-offset bounds. Its
one-byte-early EOF control rejects logical boundary mismatch; the one-byte-
outside-frame control rejects frame bounds. Known library-writer framing
retains its stricter physical-EOF check. Do not apply that local writer rule
to arbitrary stock frame layouts.

A test-encoder overload initially omitted the non-NULL RowBinary tag for a
present nullable coefficient. Cross-carrier casts in generic helpers then
failed Crystal specialization; restricting a generic union did not prevent
those casts from being compiled. The accepted pivot threads schema nullability
through recursive Array encoding and handles concrete leaves without carrier
casts. Array cardinalities are not null tags. The full/keyed comparators and
table/catalog paths all passed after this change.

After all 72 core profiles passed, an all-empty Array control refuted the
instrument's unconditional compressed decode of an empty child file. The
oracle now permits empty encoded data only when independently constructed
expected stream bytes are empty; it still checks exact file inventories,
mark row counts, logical prefixes, frame bounds and EOF. A seeded missing-
nonempty-stream control rejects that case with its exact reason. An all-NULL
non-Sparse scalar retains zero coefficient placeholders in its part stream;
only RowBinary omits coefficients at NULL rows. It is not an empty-child case.

The initial focused specs also exposed legacy scale-diagnostic changes. The
writer preserves width-named scale messages at default maximum P, while
interior precisions use the exact shared descriptor guard.

## Observed integration results

Root observed the final 24-file focused DEBUG and RELEASE selections each
pass 144 examples, with zero failures/errors/pending. The full DEBUG
--single-module gate passed 1,404 examples, also with zero failures, errors
or pending cases. The admission matrix covers all 3,002 legal P/S pairs
in each of six shapes (18,012 declarations), separate from the sampled
physical profiles below.

The completed final oracle passed against ClickHouse 26.7.1.1315:

- 72 core profiles: six shapes across twelve precision profiles, each with
  stock bytes/marks/schema/CHECK/RowBinary, library full/window reads,
  table/catalog consumers and library writer to stock ATTACH/CHECK/RowBinary.
- Twelve independent scalar SQL text endpoint checks at scale zero, comparing
  to independently constructed signed P-digit nines. These do not qualify
  text behavior for arbitrary raw carrier extrema.
- Four native raw-carrier extrema profiles and sixteen direct writer controls
  for all-zero, all-NULL, all-empty Array and all-empty two-level Array cases
  across all four width bands. Each writer part passed stock ATTACH, CHECK and
  exact full/key-range RowBinary.
- Four stock-only raw-zero statistics profiles. These qualify metadata/default
  observations, not Sparse payload decoding or admission by Crystal.
- Seeded byte comparator, early logical EOF, out-of-frame EOF and missing
  nonempty stream negatives, with expected-reason checks and unexpected
  exceptions rethrown.

All ten legacy oracle launchers also passed: Array Decimal32/64/128/256,
two-level Decimal, Bool/Enum/Decimal, scalar Decimal128/256, parameterized Tuple
and typed writer. Compiler/oracle execution was serial under the declared
watchdog. Full RELEASE and a current-master executable were not run.
Final formatting of all 23 changed Crystal files, shell syntax of both new
launchers and diff-whitespace checks passed. The intended 28-path change
contains no generated fixture directories, binaries or dependency changes;
the bounded credential-pattern hygiene scan returned no matches.

## Reproduction commands

Run from the repository root, in a Bash shell, serially. The frozen RED
probe is predecessor-only; it is not a post-change gate. The external watchdog
is not vendored into this repository.

```sh
export CLICKHOUSE=/Users/sergey/.local/bin/clickhouse
export CLICKHOUSE_BIN=/Users/sergey/.local/bin/clickhouse
export COGNI_RUN_SAFE_MIN_FREE_PCT=50
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
export TMPDIR=/private/tmp
export CRYSTAL_CACHE_DIR=/private/tmp/crystal-click-w102-cache
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
w102_guard=/Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh
w102_crystal=/opt/homebrew/bin/crystal
w102_focused=(
  spec/wide_part_reader_w45_spec.cr
  spec/wide_part_reader_w44_spec.cr
  spec/wide_part_writer_w16_spec.cr
  spec/wide_part_writer_w20_spec.cr
  spec/wide_part_reader_w15_spec.cr
  spec/wide_tuple_parameterized_consumers_w101_spec.cr
  spec/wide_part_reader_w64_spec.cr
  spec/wide_part_reader_w16_spec.cr
  spec/wide_tuple_parameterized_w101_spec.cr
  spec/wide_part_reader_w20_spec.cr
  spec/wide_part_reader_w42_spec.cr
  spec/wide_part_table_w64_spec.cr
  spec/decimal_precision_admission_w102_spec.cr
  spec/wide_part_writer_w15_spec.cr
  spec/wide_part_reader_w43_spec.cr
  spec/wide_part_writer_decimal_precision_w102_spec.cr
  spec/wide_tuple_parameterized_ownership_spec.cr
  spec/wide_tuple_parameterized_reader_budget_spec.cr
  spec/wide_part_writer_parameterized_tuple_spec.cr
  spec/decimal_column_type_w102_spec.cr
  spec/wide_part_reader_w30_spec.cr
  spec/wide_part_reader_w31_spec.cr
  spec/wide_part_reader_w39_spec.cr
  spec/decimal_precision_consumers_w102_spec.cr
)
bash "$w102_guard" "$w102_crystal" 600 8192 spec "${w102_focused[@]}" --link-flags=-fuse-ld=ld
bash "$w102_guard" "$w102_crystal" 600 8192 spec "${w102_focused[@]}" --release --link-flags=-fuse-ld=ld
bash "$w102_guard" "$w102_crystal" 600 32768 spec --single-module --link-flags=-fuse-ld=ld
for w102_oracle in \
  scripts/check_decimal_precision_oracle.sh \
  scripts/check_array_decimal32_w42_oracle.sh \
  scripts/check_array_decimal64_w43_oracle.sh \
  scripts/check_array_decimal128_w44_oracle.sh \
  scripts/check_array_decimal256_w45_oracle.sh \
  scripts/check_array_array_decimal_w64_oracle.sh \
  scripts/check_bool_enum_decimal_oracle.sh \
  scripts/check_decimal128_oracle.sh \
  scripts/check_decimal256_oracle.sh \
  scripts/check_parameterized_tuple_oracle.sh \
  scripts/check_typed_writer_oracle.sh
do
  bash "$w102_guard" /bin/bash 600 8192 "$w102_oracle" || exit "$?"
done
bash -n scripts/check_decimal_precision_oracle.sh scripts/probe_decimal_precision_w102_red.sh
bash "$w102_guard" "$w102_crystal" 600 8192 tool format --check \
  spec/wide_part_reader_w15_spec.cr spec/wide_part_reader_w16_spec.cr spec/wide_part_reader_w20_spec.cr spec/wide_part_reader_w30_spec.cr \
  spec/wide_part_reader_w31_spec.cr spec/wide_part_reader_w39_spec.cr spec/wide_part_reader_w44_spec.cr spec/wide_part_reader_w45_spec.cr \
  spec/wide_part_reader_w64_spec.cr src/crystal_click.cr src/crystal_click/offline_catalog.cr src/crystal_click/wide_part.cr \
  src/crystal_click/wide_part_table.cr src/crystal_click/wide_part_writer.cr src/crystal_click/wide_tuple_decimal_type.cr scripts/check_decimal_precision_oracle.cr \
  scripts/probe_decimal_precision_w102_red.cr spec/decimal_column_type_w102_spec.cr spec/decimal_precision_admission_w102_spec.cr spec/decimal_precision_consumers_w102_spec.cr \
  spec/wide_part_writer_decimal_precision_w102_spec.cr src/crystal_click/decimal_column_type.cr src/crystal_click/decimal_type.cr
git diff --check
```

## Scoped hostile seal and residual risks

Root inspected the combined production diff and executed every reported
compiler/oracle gate. Correlated Luna Max static reviews supplied additional
counterexamples, not independent runtime certificates. The scoped verdict is
ROBUST for exact descriptor identity, band selection, all six admitted shapes,
paired writer preflight and staged expected-schema validation, high-level
consumers and the tested pinned physical profile. The failing predecessor
matrix and stock-qualified RED distinguish the new capability from the old
implementation; seeded byte/EOF/empty-stream defects qualify the instrument
against its strongest measured false-positive routes.

The certificate belongs to the W102 source in the commit containing this
document, with predecessor bab43e5, the exact fresh-source reference above,
Crystal 1.21.0 / LLVM 22.1.8 on arm64 Darwin and the pinned CH 26.7.1.1315
runtime. Reproduction commands state the host SDK, cache and watchdog envelope.
Refresh affected gates after changes to descriptor grammar/identity, any
consumer dispatch, stream layouts, mark/frame boundary handling, staged
validation, binary version or fixtures. Until refreshed, do not transfer this
certificate to a changed context or silently admit a previously rejected type.

This is not SQL precision validation or decimal arithmetic, arbitrary recursive
type compatibility, Sparse/Compact admission, current-master runtime parity,
full RELEASE qualification, MV/projection expansion, total memory/RSS analysis
or a performance result. The two descriptor owners improve cohesion but do not
close the large reader/writer/table/catalog refactor. PK scans still return
candidate granules; the caller applies exact row predicates. The broad goal
remains active: finish paired type coverage and MV/projection support before
the deferred memory/performance work and matched ClickHouse benchmark.
