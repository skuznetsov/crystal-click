# Nullable scalar Tuple frontier (W105)

Status: VERIFIED within the declared named-flat Tuple/Wide/LZ4 profile on
stock 26.7.1.1315, at the implementation committed after predecessor
`889cac544ac39665adb1f839e490f2dda8bb896d`.
This is one compatibility increment in the all-types roadmap, not a substitute
for recursive compositions, MV/projection support, or the final performance gate.

## Contract and physical boundary

Admit `Nullable(S)` fields inside the existing nonempty named-flat Tuple plan,
where `S` is any already-admitted scalar leaf: primitive numeric, Bool, String,
identifier, temporal (including exact timezone declarations), FixedString,
Enum8/16, or Decimal. Reader and writer must admit the same declarations.
Existing non-null value semantics, nominal typed accessors, and exact schema
identity remain intact. The shared `.values` static return type is widened to
include the nullable logical view; raw-buffer consumers must use the explicit
`.physical_values` API instead of assuming `.values` always has Buffer type.

Represent nullability with one immutable `WideTupleLeafType` schema owner and
one immutable `ScalarNullMap` storage owner, each in its own file. Keep the
closed physical Buffer carriers, not a Cartesian list of `Array(T?)` carriers.
Logical row access returns Nil for masked rows; the physical buffer and mask
remain available as detached snapshots for lossless rewriting.

Every nullable field has one canonical 0/1 null byte and one underlying payload
slot per row. Emit `<column>%2E<field>.null` before the underlying leaf streams;
String additionally retains its existing size and raw payload streams. All
streams share the Tuple row/mark axis, including zero-row final marks.

Masked Enum slots can contain codes that are not valid visible semantic values.
Preserve those physical bytes without weakening non-null constructors or
visible-row validation. Nullable Enum codes use the already-existing signed
integer carriers; Decimal coefficients and Bool bytes likewise use their
existing raw carriers. Bool retains the existing nonzero-to-true reader rule;
only mask bytes are restricted to 0/1. Decimal validates the existing exact
precision/scale identity, not a newly invented coefficient-magnitude rule.
Nil must not trigger construction of a semantic value from a hidden slot.

The nullable `.values` view exposes logical values including Nil; internal
writer snapshots use `physical_values` and the mask. Non-null typed accessors
must not silently return placeholders for nullable rows. Materialization charge
includes physical slots, null bytes, and retained descriptors. Detached semantic
snapshots are caller-created allocations; the charge is not a complete RSS cap.
The null-map accessor shares its immutable owner in constant time; only its
explicit `.bytes` export creates a detached mutable snapshot. This prevents an
O(rows) mask allocation before the writer's materialization bound is checked.

Reject unnamed/nested Tuple, nullable containers, double Nullable, Sparse,
Compact, LowCardinality, and arbitrary recursive schemas at this frontier.
The existing parser/source-size, node/depth, metadata, frame, range, publication,
checksum, and 64 MiB logical materialization guards remain operative.

## Source and runtime qualification

Reference source: separate shallow snapshot
`/Users/sergey/SrcArchives/clickhouse-2026-09-29-depth1`,
`a9581941254d6113f3740a8ec125ee7519cb1bda` (2026-09-29).
Runtime oracle: stock `26.7.1.1315`; source agreement does not qualify a newer
binary. `SerializationNullable` writes both mask and nested payload;
`ColumnNullable::isDefaultAt` uses the mask. Enum SQL datatype defaults and
ColumnVector hidden defaults are different consumers and require a stock probe.

## Plan, ownership, and rollback

Risk: CAUTION (persistent serialization and shared public leaf model).
Rollback: one atomic local commit after gates; clean predecessor is the anchor.
Root owns this frontier, the admission regression, verification, and integration.
Luna owns disjoint model/reader, writer, and independent oracle changes. Workers
must preserve each other's edits and run no competing heavy workloads.

1. Establish RED before production: the existing plan rejects all 53 wrapped
   declarations in `spec/wide_tuple_nullable_w105_admission_spec.cr`, while every
   bare control passes. Qualify a stock-created mixed nullable Tuple and observe
   the existing reader reject it. Instrument failures are not behavioral RED.
2. Add schema/mask owners and nullable leaf storage, then propagate them through
   parser, plan, ColumnData/Row, and TupleReader. Existing table/catalog carry
   Tuple rows and must be tested through their public APIs, not assumed covered.
3. Snapshot and validate aligned masks/payloads before staging; write exact mask
   streams and stock-compatible serialization statistics; validate staged raw
   bytes as well as logical readback before exclusive publication.
4. Qualify reader against stock-created parts and writer through stock
   ATTACH/CHECK and independent full/PK-selected RowBinary. Preserve hidden bytes
   across reader-to-writer copies. Seed a byte comparator defect to prove the
   oracle can fail.
5. Run focused DEBUG/RELEASE tests, existing Tuple/temporal regression oracles,
   full DEBUG suite, formatting/syntax/diff checks, and hostile review.

Consumer inventory anchor: bounded `rg` over WideTuple owners and part/writer/
table/catalog facades found 76 references to WideTupleLeafColumn/WideTupleField.
Changed shared accessors must be propagated through all matching consumers;
syntax-only `WideTypeExpression` and exact Array(Tuple) profiles are not widened.

DoD: all declared commands exit 0, no test failures/errors/pending, stock
bidirectional byte/mark/logical agreement, malformed masks and invalid visible
codes rejected before the affected materialized mark's callback or writer
staging, intended diff only. Every selected stream's metadata/mark-row schedule
is checked before the first callback; later lazy payload corruption may be
reported after earlier valid marks have been yielded. Runtime runs are
serial under `run_safe.sh`, 600 s, 8 GiB (full suite 32 GiB), free-memory floor 50%.
Strongest counterexample: undeclared Enum raw zero is legal under a NULL mask,
but the same raw code must fail when its mask is zero. Also distinguish NULL
from numeric zero, false, padded zero bytes, and empty String.

## Evidence and residuals

Observed admission RED: 2 examples, 1 failure, 0 errors/pending; all 53 nullable
declarations rejected, all 53 bare controls admitted, container/double-null guard
passed. The initial sandbox launch exited 75 because `ps` was unavailable;
the subsequent guarded, escalated run produced the genuine behavioral RED.

Observed stock RED: `scripts/probe_nullable_tuple_w105_red.sh`, guarded at
600 s / 8 GiB / 50% free-memory floor, reached its explicit expected-RED marker
and exited 1 after stock qualification. Six nullable fields (UInt64, String,
Enum8 without code zero, FixedString, zoned DateTime64, Decimal) matched exact
schema, all 14 physical streams and mark records, Default serialization counters,
CHECK, and independent full/PK-selected RowBinary. The existing typed reader then
rejected the part with `UnsupportedFormatError: unsupported exact typed column`.
The Enum comparator also rejected a seeded one-byte mismatch.

For this explicit RowBinary input route, hidden Enum NULL slots contain raw zero:
the observed nested stream is `[0, 249, 7, 0, 249]`. A separate stock SQL CAST
probe returned the first declared code -7 for NULL; neither route licenses a
universal hidden-value default claim. Preserve actual physical slots.

Earlier probe failures were instruments, not reader RED: an incorrectly selected
runner executable and a ratio of 1.0 that omitted Default serializer records.
The qualified profile uses ratio 0.9375 and does not enable the newer exact-counter
metadata key; this does not widen the reader's admitted serialization envelope.

Observed bidirectional GREEN: `scripts/probe_nullable_tuple_w105_green.sh
--green-reader` and `--green-writer` each exited 0 on stock 26.7.1.1315. The
profile covers 53 nullable declarations plus two bare controls, 55 fields and
111 physical streams. Exact schema, stream inventory, raw payloads, all mark
records and bounded Default statistics agreed. Fresh stock ATTACH/CHECK and
independent full/PK-selected RowBinary agreed in both directions. The typed
reader checked every nullable family, hidden slots, nominal descriptors and
full/selected reads. A seeded Enum byte mismatch was rejected. This is a
bounded profile certificate, not arbitrary-schema or newer-binary coverage.

The unchanged parameterized, numeric, Bool and identifier Tuple stock oracle
scripts all exited 0. W104's separate timezone reader phase also exited 0:
297 stock declarations and typed reads, plus its higher-rank two-column
profiles. The corrected 42-file focused DEBUG and RELEASE suites each passed
537 examples with zero failures, errors or pending. Full DEBUG passed 1,719
examples with zero failures, errors or pending; its only reported linker
warning was duplicate `-lc`. W104's separate writer phase also passed all
297 profiles, 14 table/catalog consumer profiles and seven seeded shape
checks. The six unchanged scalar temporal, Nullable temporal, Array temporal,
Array(Array) temporal, temporal Tuple and QBit regression oracles all exited
0. QBit retained its 80 paired profiles and 3,000-row split-plane control.
All 39 changed Crystal source/spec/probe files passed format checking; both
new shell probes passed syntax checking and `git diff --check` passed.
The 39-file SHA-256 manifest was unchanged across the final runtime gates.

Read-only hostile accounting audit found no retained-result charge
counterexample within the stated logical scope. The plan charges a null-map
owner once and its bytes per row once; adding the map's complete charge again
would double-count. Hidden String bytes remain chargeable even under NULL.
Decoded buffers, constructor/result copies, caller-created snapshots, metadata
names and transient parse buffers are not a peak-RSS certificate. The legacy
String-taking temporal leaf constructor also creates two equal declaration
graphs in the caller leaf; result-plan rebinding uses the plan owner. This
caller-allocation caveat is not a claim of descriptor identity everywhere.

The bounded writer review independently checked nullable default counters
against `ColumnNullable::isDefaultAt` and Tuple's conjunction rule. Staged
validation compares the exact mask and every physical slot, not Nil-filtered
logical values; executed tests attack hidden Enum bytes, a same-payload mask
change, NaN payloads and Decimal256 backing extrema by changing the expected
snapshot passed to the real staged validator. These controls certify readback
comparison, not a new on-disk tampering experiment. Caller-owned keys and
column-array membership must not be mutated concurrently during the synchronous
write call. This frontier does not certify thread-safe concurrent input mutation.

Root's final scoped hostile verdict is ROBUST: the executed negative tests
distinguish NULL from visible zero/false/empty values; reject malformed masks,
misaligned selected schedules and invalid visible Enum codes; retain hidden
physical slots and nominal schema across copies; reject hidden payload over
the logical cap before writer copying/staging; and detect staged readback versus
expected mask/raw mismatches. A later corrupt lazy mark may still be reported
after earlier valid marks were yielded, as stated in the contract. Same-lineage static review is
correlated; the root's source inspection and executed stock/test gates are the
independent anchors, not model agreement. This verdict is VULNERABLE if widened
to peak RSS, arbitrary recursive schemas, current-master binaries, concurrent
input mutation, or a speed comparison. No such wider claim is made.
Evidence decays when nullable owner/codec/metadata paths, fixture profiles, stock
binary, or relevant format settings change; refresh the affected gates first.

## Reproduction commands

Run from the repository root. Use the guarded runner on a quiet host; its
watchdog must be able to observe its own child group. These are verification
commands, not permission to stop unrelated workloads.

```sh
w105_guard=(
  env
  CLICKHOUSE=/Users/sergey/.local/bin/clickhouse
  CLICKHOUSE_BIN=/Users/sergey/.local/bin/clickhouse
  COGNI_RUN_SAFE_MIN_FREE_PCT=50
  RUN_SAFE_PASSTHROUGH_STDIO=1
  SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
  TMPDIR=/private/tmp
  CRYSTAL_CACHE_DIR=/private/tmp/crystal-click-w105-cache
  PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
  bash /Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh
)
w105_focused_specs=(
  spec/timezone_temporal_admission_w104_spec.cr
  spec/timezone_temporal_model_w104_spec.cr
  spec/timezone_temporal_writer_w104_spec.cr
  spec/timezone_temporal_consumers_w104_spec.cr
  spec/datetime_scan_spec.cr
  spec/nullable_temporal_scan_spec.cr
  spec/wide_part_writer_datetime_spec.cr
  spec/wide_part_writer_nullable_temporal_spec.cr
  spec/wide_tuple_temporal_model_spec.cr
  spec/wide_tuple_temporal_spec.cr
  spec/wide_part_writer_temporal_tuple_spec.cr
  spec/temporal_tuple_consumers_spec.cr
  spec/wide_part_reader_w40_spec.cr
  spec/wide_part_reader_w65_spec.cr
  spec/wide_part_reader_w66_spec.cr
  spec/wide_part_writer_w65_spec.cr
  spec/wide_part_writer_w66_spec.cr
  spec/wide_tuple_bool_model_w97_spec.cr
  spec/wide_tuple_bool_w97_spec.cr
  spec/wide_tuple_identifier_w99_spec.cr
  spec/wide_tuple_numeric_w96_spec.cr
  spec/wide_tuple_type_plan_spec.cr
  spec/wide_part_reader_compositional_tuple_spec.cr
  spec/wide_tuple_nullable_w105_admission_spec.cr
  spec/wide_tuple_nullable_w105_model_spec.cr
  spec/wide_part_writer_nullable_tuple_w105_spec.cr
  spec/wide_tuple_parameterized_w101_spec.cr
  spec/wide_part_writer_parameterized_tuple_spec.cr
  spec/wide_tuple_column_data_ownership_spec.cr
  spec/wide_tuple_parameterized_ownership_spec.cr
  spec/wide_tuple_parameterized_reader_budget_spec.cr
  spec/wide_tuple_parameterized_consumers_w101_spec.cr
  spec/wide_part_reader_tuple_metadata_spec.cr
  spec/wide_part_reader_tuple_empty_eof_spec.cr
  spec/wide_part_writer_numeric_tuple_w96_spec.cr
  spec/wide_part_writer_bool_tuple_w97_spec.cr
  spec/wide_part_writer_identifier_tuple_w99_spec.cr
  spec/wide_part_writer_bool_canonical_w98_spec.cr
  spec/wide_tuple_nullable_w105_consumers_spec.cr
  spec/wide_tuple_nullable_w105_lazy_spec.cr
  spec/offline_catalog_w95_tuple_values_spec.cr
  spec/wide_part_writer_compositional_tuple_spec.cr
)
"${w105_guard[@]}" crystal 600 8192 spec --single-module --link-flags=-fuse-ld=ld "${w105_focused_specs[@]}"
"${w105_guard[@]}" crystal 600 8192 spec --release --single-module --link-flags=-fuse-ld=ld "${w105_focused_specs[@]}"
"${w105_guard[@]}" crystal 600 32768 spec --single-module --link-flags=-fuse-ld=ld
"${w105_guard[@]}" bash 600 8192 scripts/probe_nullable_tuple_w105_green.sh --green-reader
"${w105_guard[@]}" bash 600 8192 scripts/probe_nullable_tuple_w105_green.sh --green-writer
"${w105_guard[@]}" bash 600 8192 scripts/check_timezone_temporal_oracle.sh --green-reader
"${w105_guard[@]}" bash 600 8192 scripts/check_timezone_temporal_oracle.sh --green-writer
"${w105_guard[@]}" bash 600 8192 -c 'for script in scripts/check_parameterized_tuple_oracle.sh scripts/check_numeric_tuple_oracle.sh scripts/check_bool_tuple_oracle.sh scripts/check_identifier_tuple_oracle.sh; do bash "$script" || exit "$?"; done'
"${w105_guard[@]}" bash 600 8192 -c 'for regression_script in scripts/check_datetime_oracle.sh scripts/check_nullable_temporal_oracle.sh scripts/check_array_temporal_oracle.sh scripts/check_array_array_temporal_oracle.sh scripts/check_temporal_tuple_oracle.sh scripts/check_qbit_oracle.sh; do bash "$regression_script" || exit $?; done'
```

The first expanded focused selection exposed stale guard and budget
expectations after the new admitted leaf envelope. They were migrated to
positive Nullable controls, still-unsupported containers, and independently
computed owner charges; limits and corruption guards were not removed. A
new lazy spec then called a nonexistent row method; the test was corrected to
the existing nominal `value_as` API. Neither event is physical compatibility
evidence.

A subsequent multi-module DEBUG compilation was stopped before a suite
result at a reported 2,842 lsof records. The fixed watchdog counts mapped/text
files as well as numeric descriptors; this alone does not prove a growing
library FD leak. The retry uses the established `--single-module` compiler
layout with unchanged DEBUG optimization, timeout, RSS/free-memory and lsof
guards. Its focused result passed 537 examples with zero failures, errors or
pending. The same 42-file RELEASE selection passed 537 examples, also with
zero failures, errors or pending. Full DEBUG with the same single-module
layout passed 1,719 examples, zero failures, errors or pending. Full RELEASE
was not run and is not claimed.

## Continuation boundary

The active roadmap remains all-type reader/writer compatibility, then MV and
projection compatibility, then like-for-like memory/performance qualification.
The next type-side gap is recursive composition, not another Cartesian set of
nullable scalar buffers. Return to this contract for exact leaf/mask ownership;
use `COMPOSITIONAL_TUPLE_FRONTIER.md` and `CLICKHOUSE_REFERENCE.md` for the
existing container and current-source boundaries. Before widening production,
pin one nested Tuple/container declaration and its stock physical topology,
establish the current public-reader rejection, and specify the shared recursive
plan/ownership model. Nested/unnamed Tuple and container leaves remain rejected
here until that separate frontier is qualified.

Heavy work remains delegated to Luna Max and independently checked by root.
Local coherent commits are authorized; this increment grants no remote push
or unrelated-process control. The broader facade decomposition is still open
in `MODULARIZATION_FRONTIER.md`; this two-owner addition is not its completion.
