# Temporal Tuple Leaf Frontier

Status: W100 is verified within the pinned named-flat temporal Tuple profile.
Qualified RED was recorded on predecessor
`498f5e141cfed4aac6d58dc2c865c24f5c06de8a`; the frozen combined source passed
focused DEBUG/RELEASE, full DEBUG and all declared stock-oracle gates below.
The active goal is all type read/write compatibility and MV/projection support
before memory/performance work, not completion of this one family.

W104 subsequently admits exact timezone-qualified DateTime and DateTime64
leaves under its separate seven-shape certificate in
`TIMEZONE_TEMPORAL_FRONTIER.md`. The historical timezone rejection below is
the W100 boundary, not the current W104 admission policy; the original W100
certificate is not retroactively widened.

## Problem, scope and design laws

The existing scalar and Array temporal paths retain exact semantic type
metadata but expose raw integer carriers. On the predecessor, named flat
Tuple leaves inferred metadata from the Array element class, which would
conflate Date with UInt16, Date32/Time with Int32, DateTime with UInt32, and
DateTime64/Time64 with Int64. Precision would also disappear from empty buffers
and extracted scalars. W99's nominal identifier extension does not solve this
parameter boundary.

Bounded admission qualified by the executed gates below: the entire
existing raw temporal family in named, nonempty, nonrecursive Tuple schemas:
Date, Date32, bare DateTime, DateTime64(p), bare Time and Time64(p), with every
canonical precision p from 0 through 9. Arbitrary ordering and repetition with
existing admitted numeric, Bool, String and UUID/IP leaves must work. Reader,
writer, owned row values, table scans and catalog values advance together.

Rejected here: timezone/calendar conversions, timezone-qualified declarations,
aliases, malformed or noncanonical parameters, Nullable/nested/unnamed Tuple,
Decimal/Enum/FixedString leaves, Sparse/Compact/new metadata, arbitrary-table
writing, primitive relabels and performance claims. These are library frontier
limits, not claims that ClickHouse rejects those shapes.

Use six immutable nominal value structs, one per file: DateValue (UInt16 day
code), Date32Value (Int32 day code), DateTimeValue (UInt32 epoch seconds),
DateTime64Value (Int64 ticks plus validated precision), TimeValue (Int32 signed
seconds) and Time64Value (Int64 ticks plus validated precision). No mutable
String or descriptor allocation per row. The two scaled wrappers preserve
precision when detached from a row; no conversion, rounding or clamping.

One cohesive WideTupleTemporalType owner defines closed identities, exact
type/parameter recognition, physical widths, owned-representation charges,
nominal equality, metadata/buffer compatibility and qualified serialization
default predicates. Temporal values do not enter WideTupleNumericType. An
explicit temporal leaf constructor retains exact metadata even for empty
arrays, validates every value's nominal identity/precision, and preserves
metadata through owned_copy. Existing constructors and scalar/Array APIs keep
their current contract. No Cartesian arity/type serializers or per-temporal-
type facade API.

Reuse existing fixed-width LE scalar primitives. Physical width and the
logical charge for the actual owned wrapper representation are separate:
scaled Int64 wrappers carry precision and cannot be charged as an eight-byte
integer slot by assumption. This charge is not a peak-RSS or allocation proof.
Keep all preflight, ownership, mark/checksum/metadata, Bool raw semantics and
exclusive-publication guards.

## Default context bridge and next discriminator

In the fresh source at a9581941254d6113f3740a8ec125ee7519cb1bda,
DataTypeDate32::getDefault() returns -25567 (1900-01-01), but the native
ColumnVector<Int32>::isDefaultAt() predicate uses raw zero. SerializationInfo
counts column defaults and SerializationInfoTuple forwards each child column.
These are distinct default domains; importing the type default into Tuple
serialization statistics is not authorized by the matching word alone.

Source anchors: src/DataTypes/DataTypeDate32.cpp:18-21,
src/Columns/ColumnVector.h:292-313,
src/DataTypes/Serializations/SerializationInfo.cpp:77-95 and
SerializationInfoTuple.cpp:49-59. This is inspected source evidence, not a
26.7 runtime certificate. Before production, separately stock-create raw-zero
and raw-minus-25567 Date32 Tuple fixtures; inspect complete bytes, RowBinary,
metadata and actual stream presence in the plain ratio-1.0 profile. An empty
`columns` metadata array is not evidence of a numeric default count. Qualify
counts separately in stats-enabled ratio-0.9375 fixtures: inspect actual child
counts and serializer kinds, CHECK and independent full/selected RowBinary.
These statistics-only fixtures may choose Sparse and are never used to claim
plain-reader admission or a Sparse physical-codec certificate. Only observed
column-default statistics may govern the writer's Default counts.

## Risk, rollback and execution ownership

Risk is CAUTION: persisted serialization and public value-union changes.
Strongest failures are equal-width semantic relabels, lost/mixed precision,
empty-column metadata loss, incorrect Date32 default statistics, or budget
undercharging before staging. Attack with same raw ticks at different types
and precisions, wrong carriers, all canonical precisions, asymmetric negative/
positive values, empty buffers, owned copies and a checksum-valid canonical
stage checked against altered expected raw/precision buffers. The latter
attacks the internal readback comparator, not payload mutation or public
mid-write cleanup.

Rollback is the coherent local W100 commit from the clean predecessor after
gates. Preserve unrelated edits; no push, history rewrite, dependency update,
new executable installation or mutation of the old CH checkout.

1. Root owns this SDD, shared require graph and combined review. Inventory
   anchors are WideTupleTypePlan, WideTupleLeafColumn, WideTupleColumnData,
   WideTupleRow, TupleReader, TuplePartWriter and TuplePartWriteInput;
   table/catalog delegate through the existing shared row/column owners.
2. Model/reader owner: six new value files, wide_tuple_temporal_type.cr,
   wide_tuple_leaf_column.cr, wide_tuple_type_plan.cr, wide_part/tuple_reader.cr
   and the narrow adapter in wide_part.cr. Write the existing-API plan RED
   spec before production; extend it for nominal/parameter/ownership cases
   only after RED is qualified. Existing unsupported temporal assertions may
   change only within the new admitted family.
3. Writer owner: wide_part_writer/tuple_part_writer.cr,
   tuple_part_infrastructure.cr and narrow wide_part_writer.cr adapter/codec
   dispatch. Validate every row/parameter before the stage factory; compare
   exact nominal values and precision on staged readback. Own writer specs.
4. Oracle/consumer owner: probe_temporal_tuple_w100_red.cr, the new
   check_temporal_tuple_oracle.cr/.sh and temporal Tuple consumer specs.
   Qualify stock CHECK/schema/substreams/marks/full physical bytes/full and
   selected RowBinary plus existing admitted Tuple controls before claiming
   current typed-reader rejection. Probe every canonical precision and the
   Date32 default discriminator. The historical RED is tied to predecessor.
5. Root alone runs compiler/spec/ClickHouse workloads serially, reviews the
   frozen combined diff, attacks the strongest counterexample and commits
   exact owned paths only after the declared gates pass.

Workers are not alone in the codebase and must preserve others' edits. No
worker runs heavy commands or Git writes. Root authorized production edits
only after the qualified stock RED, not after a compile/fixture error.

## Falsifiers and Definition of Done

- Existing-API plan RED: all 24 exact declarations fail temporal admission on
  unchanged production, while existing primitive/identifier/Bools/Strings and
  malformed-type rejection controls pass. Missing future classes must not be
  used as a compile-failure substitute for behavioral RED.
- Qualified stock RED: all six families and all twenty scaled declarations
  pass the differently constructed stock byte/schema/mark/RowBinary controls;
  current typed reader then rejects them. Separately qualify Date32 raw 0
  versus -25567 and all-zero temporal values under the admitted plain profile.
- New model/reader/writer/consumer specs plus W94-W99 Tuple, ownership,
  numeric/Bool/identifier, legacy and scalar temporal guards in DEBUG and
  RELEASE: zero failures/errors/pending. Include mismatched wrapper/kind/
  precision, typed empty ownership, unsupported later leaf, zero stage calls
  on invalid input, budget charges and complete mark schedule validation.
- New bidirectional stock oracle: all canonical precisions, mixed/reordered/
  repeated leaves, all-zero and Date32 discriminator profiles, complete
  physical bytes, full/key-range RowBinary, independent physical-mark ranges,
  source values as writer inputs, stock ATTACH/CHECK and table/catalog
  full/window/candidate paths. The actual comparator must reject a seeded
  wrong expectation. Do not conflate SQL key ranges with mark ranges.
- Unchanged date, datetime and time scalar oracles, W99 identifier Tuple,
  numeric Tuple, Bool semantics, compositional and legacy Tuple oracles must
  pass. Identify the actual Time oracle path before freezing commands.
- Full DEBUG spec --single-module --link-flags=-fuse-ld=ld; changed Crystal
  format checks, shell syntax, diff and exact-path hygiene: exit zero.
  Full RELEASE is not a declared gate or claim.

Heavy envelopes: the inspected external cogni-ml/scripts/run_safe.sh, 50%
free-memory admission/floor, 600 seconds, 8192 MiB focused/oracle and 32768 MiB
full DEBUG. Use pinned ClickHouse 26.7.1.1315, Crystal 1.21.0, host SDK/linker
settings and isolated cache. Supply CLICKHOUSE and CLICKHOUSE_BIN because
existing fixtures and oracles use different environment names. These are
resource safety gates, not performance measurements.

Evidence decays on identity/parameter/codec/admission/default/ownership/budget,
mark/metadata/import/fixture changes or compiler/pinned executable changes.
Source comparison is against the recorded fresh shallow snapshot, not an
unexecuted current-master runtime claim. Wider all-types/MV/projection and
matched-performance completion remains unproved.

## Current evidence and continuation

W99 was committed and the predecessor was clean before this slice. Read-only inventories found
the six scalar raw-carrier contracts and exact 0..9 DateTime64/Time64 parser
guards (wide_part.cr:1012-1024), existing LE codecs and shared Tuple consumers.
Independent root inspection confirmed predecessor Tuple admission lacked
temporal leaves. Production edits were authorized only after qualified stock
RED and Date32 default discrimination, not by relaxing admission to make an
invalid instrument pass.

Root executed the existing-API plan RED on the unchanged predecessor with the
declared watchdog, pinned compiler/SDK and isolated cache:
`crystal spec spec/wide_tuple_temporal_spec.cr --link-flags=-fuse-ld=ld`.
Observed: 27 examples, 25 failures, 0 errors, 0 pending, exit 1. Every one of
the 24 individually registered temporal declarations and the all-24 ordered
composition failed the non-nil admission assertion; primitive/identifier/
Bool/String positive controls and malformed/unsupported rejection controls
passed. This is behavioral admission RED, not a compiler or missing-class
failure. It does not yet qualify a stock part or authorize production edits.

Root then executed `crystal run scripts/probe_temporal_tuple_w100_red.cr
--link-flags=-fuse-ld=ld` under the same watchdog, with the pinned ClickHouse
and a fresh temporary store. After the existing UInt64/String positive typed
control, all 24 stock singleton declarations passed complete schema/substream/
physical-byte/mark/default-statistic/CHECK/full and selected RowBinary controls.
Both plain Date32 profiles retained streams but exposed `columns=[]`; these
were not treated as count evidence. Separate statistics-only profiles exposed
child defaults 5 for raw zero (Sparse) and 0 for -25567 (Default), with stock
CHECK and independent full/selected RowBinary. The plain all-zero 24-leaf
composite passed actual streams, physical bytes, marks, CHECK and RowBinary.
Only then did all 24 current typed reads reject with exactly `unsupported
exact typed column`; the final expected-RED marker was reached, exit 1.
This qualified stock RED authorizes the bounded production implementation.

Two earlier attempts were instrumentation failures, not reader RED: the
positive String size stream was incorrectly modeled as cumulative offsets
rather than per-row lengths, and the stats-only Sparse all-zero stream was
incorrectly sent to a nonempty compressed-block decoder. Root corrected only
the instrument and reran from fresh stores. Neither failure is counted as
production evidence or Sparse-reader admission.

## Executed post-change gates and adversarial verdict

The frozen production and final 39-file focused set passed DEBUG and RELEASE:
259 examples each, zero failures/errors/pending. The added internal-validator
attack first accepts the unchanged canonical six-field temporal part against
its original source buffers, then rejects six same-nominal raw-value
mismatches and same-raw/wrong-precision buffers for both scaled types with
exactly `staged Tuple temporal leaf readback differs`. This test changes the
expected input, not the payload, and does not certify public mid-write cleanup.

Earlier post-change attempts exposed only new-test instrumentation errors:
two typed-Array helper arguments needed parentheses for Crystal parsing;
a copied String ownership test used readonly `to_slice` instead of the
existing unsafe-mutation convention; and the high-level consumer fixture
used an invalid part basename. Only the tests were corrected. Production
admission, reader selection and ownership guards were not relaxed.

The final full DEBUG command passed 1,348 examples, zero failures/errors/
pending (171-second workload, 36.62-second reported spec execution). The only
reported linker warning was duplicate `-lc`. Full RELEASE was not run or
claimed.

The bidirectional temporal oracle passed all 24 singleton declarations and
a reordered/repeated composite with existing UInt64, Bool, binary String,
UUID and IPv4 leaves. Four Crystal-written profiles use stock-decoded
columns as actual writer inputs: the mixed composite, all-zero 24-leaf
composite and both Date32 raw-zero/-25567 discriminators. Each native
profile passes exact schema/substreams, complete physical bytes and
`[2, 2, 1, 0]` marks, actual stock ATTACH/CHECK, and independent full/
key-range RowBinary. The mixed profile additionally passes reader physical
mark ranges, table full/window/candidate scans and catalog full/values/
window consumers in both directions. Candidate marks 1 and 2 yield rows
3,4,5; the separate SQL key range yields rows 2,3,4. The actual byte
comparator rejects its seeded one-byte wrong expectation.

Plain ratio-1.0 Date32 source profiles expose `columns=[]`, not an inferred
count. Separate ratio-0.9375 statistics controls observe five raw-zero
defaults with Sparse and zero -25567 defaults with Default, while passing
stock CHECK/full/key-range RowBinary. Their actual stream inventories are
observed, not decoded as admitted Sparse parts. The Crystal writer emits
explicit Default records with raw-zero counts 5/0; stock retains and reads
both native profiles after ATTACH. This qualifies storage defaults, not SQL
calendar defaults or exact stock counts under arbitrary sampling settings.

All eight unchanged regression oracles passed: scalar Date/Date32,
DateTime/DateTime64, W50 Time/Time64, identifier Tuple, numeric Tuple,
nine-profile Bool semantics, compositional Tuple and legacy Tuple. They
provide differently constructed scalar/text and existing-container fallback
checks. Changed Crystal format checks, shell syntax and exact-path diff
hygiene pass. Oracle formatting changed only constant alignment and a blank
line; no fixture, comparator or production semantics changed.

Root's combined-diff adversarial verdict is ROBUST within the declared
profile: exact nominal identity and parameters, copied/empty ownership,
same-width rejection, later unsupported leaves, every canonical precision,
all-zero/default discrimination, pre-stage row/budget/type checks, mark
schedule validation and staged temporal readback disagreement are covered.
Luna static reviews are correlated support; stock physical/RowBinary/
ATTACH/CHECK observations and root-executed tests are the primary evidence.

## Reproduction commands

Run from the repository root with the pinned compiler and executable.
The external watchdog remains mandatory; its resource envelope is not a
reader-performance measurement.

```sh
export CLICKHOUSE=/Users/sergey/.local/bin/clickhouse
export CLICKHOUSE_BIN=/Users/sergey/.local/bin/clickhouse
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
export TMPDIR=/private/tmp
export CRYSTAL_CACHE_DIR=/private/tmp/crystal-click-w100-cache
export COGNI_RUN_SAFE_MIN_FREE_PCT=50
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
guard=/Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh
crystal_bin=/opt/homebrew/bin/crystal
focused=(
  spec/wide_tuple_identifier_w99_spec.cr spec/wide_part_writer_identifier_tuple_w99_spec.cr
  spec/identifier_tuple_consumers_w99_spec.cr spec/wide_tuple_type_plan_spec.cr
  spec/wide_tuple_column_data_ownership_spec.cr spec/wide_tuple_row_w95_spec.cr
  spec/wide_tuple_numeric_w96_spec.cr spec/wide_tuple_numeric_model_w96_spec.cr
  spec/numeric_tuple_consumers_w96_spec.cr spec/wide_part_writer_numeric_tuple_w96_spec.cr
  spec/wide_tuple_bool_w97_spec.cr spec/wide_tuple_bool_model_w97_spec.cr
  spec/wide_part_writer_bool_tuple_w97_spec.cr spec/bool_tuple_consumers_w97_spec.cr
  spec/wide_part_writer_compositional_tuple_spec.cr spec/wide_part_reader_compositional_tuple_spec.cr
  spec/wide_part_table_w95_tuple_spec.cr spec/offline_catalog_w95_tuple_values_spec.cr
  spec/wide_part_reader_tuple_metadata_spec.cr spec/wide_part_reader_tuple_empty_eof_spec.cr
  spec/wide_part_writer_tuple_spec.cr spec/bool_value_codec_spec.cr
  spec/bool_semantics_w98_spec.cr spec/wide_part_writer_bool_canonical_w98_spec.cr
  spec/wide_part_reader_w17_spec.cr spec/wide_part_writer_w17_spec.cr
  spec/wide_part_reader_w18_spec.cr spec/wide_part_writer_w18_spec.cr
  spec/wide_part_reader_w19_spec.cr spec/wide_part_writer_w19_spec.cr
  spec/wide_tuple_temporal_spec.cr spec/wide_tuple_temporal_model_spec.cr
  spec/wide_part_writer_temporal_tuple_spec.cr spec/temporal_tuple_consumers_spec.cr
  spec/wide_part_writer_date_spec.cr spec/wide_part_writer_datetime_spec.cr
  spec/date_scan_spec.cr spec/datetime_scan_spec.cr
  spec/wide_part_reader_w50_spec.cr
)
bash "$guard" "$crystal_bin" 600 8192 spec "${focused[@]}" --link-flags=-fuse-ld=ld
bash "$guard" "$crystal_bin" 600 8192 spec "${focused[@]}" --release --link-flags=-fuse-ld=ld
bash "$guard" /bin/bash 600 8192 scripts/check_temporal_tuple_oracle.sh
for oracle in \
  scripts/check_date_oracle.sh scripts/check_datetime_oracle.sh \
  scripts/check_wide_time_w50_oracle.sh scripts/check_identifier_tuple_oracle.sh \
  scripts/check_numeric_tuple_oracle.sh scripts/check_bool_semantics_oracle.sh \
  scripts/check_compositional_tuple_oracle.sh scripts/check_tuple_oracle.sh
do
  bash "$guard" /bin/bash 600 8192 "$oracle" || exit "$?"
done
bash "$guard" "$crystal_bin" 600 32768 spec --single-module --link-flags=-fuse-ld=ld
bash -n scripts/check_temporal_tuple_oracle.sh
git diff --check
```

## Residual boundaries and next signal

This certificate belongs to the coherent W100 commit containing this
document, based on predecessor 498f5e1, Crystal 1.21.0/LLVM 22.1.8 on this
aarch64 Darwin host and ClickHouse 26.7.1.1315. Refresh the affected gates on
any declared decay trigger above. The fresh depth-1 source is the immutable
a958194 snapshot; it is not a current-master executable certificate.

No timezone conversion, primitive relabeling, Sparse/Compact/new metadata,
nullable/recursive/unnamed Tuple, general table writer, arbitrary type
composition or performance result is admitted. A validly checksummed
equal-width semantic relabel cannot be recovered without a trusted exact
DDL/type authority. Logical owned-slot charging (16 bytes for the scaled
wrappers here versus 8 physical bytes) is not peak RSS or a GC certificate.

The larger facade extraction and older Array(Map) intermediate-file-open
cleanup concern remain open. The direct staged-validator test is not public
mid-write cleanup or a power-loss recovery proof. The next compatibility
slice is FixedString/Enum/Decimal Tuple leaves with equally explicit
parameter/nominal ownership, followed by structural recursion. Broader
MV/projection capabilities and the matched ClickHouse <=10% slowdown target
remain unproved; the active goal is not completed by W100.
