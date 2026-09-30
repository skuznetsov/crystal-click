# Numeric Tuple Leaf Frontier

Status: W96 is VERIFIED within the named primitive-numeric/String Wide Tuple
profile below: focused DEBUG/RELEASE, full DEBUG, pinned numeric/legacy stock
oracles and final hygiene passed. The clean pre-change implementation anchor
is `e42367af302d8b2ff7f5b766198786369b1d8d53`.
W96 extends W94/W95's UInt64/String named leaves to the 15 numeric identities
below; it is not a certificate for every ClickHouse Tuple composition.
The full compatible-type/MV/projection goal and eventual matched
ClickHouse slowdown <=10% target remain unchanged.

## Problem and source anchor

Existing primitive numeric scalar readers/writers already cover more types
than the compositional Tuple leaf owner. Widening whole-Tuple literal branches
or enumerating native Tuple arities would reproduce the old coupling instead
of extending shared leaf responsibilities.

Reference source: `/Users/sergey/SrcArchives/clickhouse-2026-09-29-depth1`,
`a9581941254d6113f3740a8ec125ee7519cb1bda` (shallow checkout rechecked).
`DataTypeTuple.cpp:331-358` delegates each field to its own serializer under
`SerializationNamed(..., TupleElement)`. `SerializationNumber.cpp:300-369`
uses little-endian scalar bytes and fixed-width bulk bytes;
its instantiations at lines 384-398 enumerate Int/UInt8/16/32/64/128/256,
Float32/64 and BFloat16. Source inspection is not persisted-part evidence.
The executable oracle remains ClickHouse 26.7.1.1315, rechecked independently.

## Proposed boundary and first discriminator

Extend the existing named, nonempty Tuple plan and owned leaf contract to the
15 bare numeric types above plus String. Preserve declaration order, nominal
width/signedness and wrapper identities. Existing UInt64/String constructors,
the exact raw native-pair accessor and the W95 row API remain compatible.
The physical profile stays one UInt64 key plus one Tuple payload in the
admitted Wide Default/AlwaysDefault layouts. Preserve complete eager metadata
schedule checks, lazy per-mark payload checks, pre-stage writer validation and
aggregate logical budgets with each leaf's actual slot width.

First executable RED must use existing APIs, not fail solely on a missing
new constructor: an admitted UInt64/String plan control, then expected plans
and stream widths for the 15 numeric leaf types. An independent stock-created
non-UInt64 Tuple should also expose the current persisted reader rejection.
The plan RED was observed on the unchanged production anchor: root handle
73510, exit 1, 17 examples / 14 unsupported-plan failures / 0 errors. UInt64,
the existing pair control and rejected-neighbor control passed. A separate
stock-created reader RED was required before production edits.
Two probe-instrument failures do not satisfy that gate: the first used
Int32 literals where mark rows require UInt64, and root handle 56347 exited
1 at the existing positive-control `.mrk2` inventory because its settings
forced nonadaptive marks. The corrected fixture uses the already verified
W94 adaptive-mark settings; no reader admission or inventory guard was relaxed.
The corrected probe then produced the valid persisted RED on unchanged
production: root handle 41773, exit 1, wrapper about 2 seconds. Existing
UInt64/String typed-open, mark-range and independently encoded RowBinary
controls passed. The stock-created five-row `Tuple(value Int8)` had the exact
expected streams, Default metadata and [2, 2, 1] marks; typed-open raised
`UnsupportedFormatError: unsupported exact typed column` in `parse_metadata`.

The pinned Float32/Float64/BFloat16 fixture preserved independently expected
bits for four +0 rows followed by -0, finite one, infinity and quiet NaN.
Its observed root and all three child `num_defaults` were 4, not 5. This
supports an all-zero-bit default predicate for this bounded fixture, separately
from master `ColumnVector.h:292-312`; it does not establish that every stock
metadata count is exact rather than sampled. Writer defaults and staged
comparison must use raw bits, while the reader retains bounded-count guards.

Strongest failure: equal-width nominal types are conflated or numeric casts
change NaN payloads, signed zero or high integer words; ordinary value equality
could conceal it. Use independently encoded expected little-endian bytes,
signed extrema/high-bit words and IEEE/BFloat bit patterns in both directions.
Also retain wrong-buffer-type, later unsupported field, parser alias,
String/row ownership, combined-budget and zero-stage-on-invalid-input guards.

Rejected here: semantic Bool/date/time/decimal/UUID/IP leaves, Nullable,
recursive/unnamed/empty Tuples, Compact/Sparse and newer-master metadata.
These remain real compatibility work, not evidence of ClickHouse rejection.
Performance optimization and a new master executable installation are not
part of W96.

Risk: CAUTION (public leaf representation and persisted serialization).
Rollback: one coherent W96 local commit after its declared gates pass; preserve
other user work and do not push. Evidence will decay on changed type mapping,
codec/bit semantics, ownership, budgets, stream/metadata/mark policy, fixtures,
compiler semantics or executable version. The declared W96 gates passed as
recorded below; admitting another type profile requires its own discriminator.

## Implementation seal and ownership

Consumer inventory: bounded `rg` for `WideTupleLeafColumn`, `WideTupleRow`,
`TupleLeafBuffers`, `value_at` and `TuplePartInfrastructure.new` in source,
specs, scripts and examples. Changes propagate through leaf buffers, row
access, TupleReader, TuplePartWriteInput, TuplePartWriter and its private
infrastructure; table/catalog already use the single nominal WideTupleRow.
No per-arity table/catalog union is needed.

- Model/reader owner: new `src/crystal_click/wide_tuple_numeric_type.cr`,
  existing `wide_tuple_type_plan.cr`, `wide_tuple_leaf_column.cr`,
  `wide_tuple_column_data.cr`, `wide_tuple_row.cr`, `wide_part/tuple_reader.cr`,
  and narrow Tuple integration in `wide_part.cr`; new
  `spec/wide_tuple_numeric_model_w96_spec.cr`.
- Writer owner: existing `wide_part_writer/tuple_part_write_input.cr`,
  `tuple_part_infrastructure.cr`, `tuple_part_writer.cr`, the narrow adapter
  in `wide_part_writer.cr`; new `spec/wide_part_writer_numeric_tuple_w96_spec.cr`.
- Consumer/oracle owner: `spec/wide_tuple_numeric_w96_spec.cr`, new
  `spec/numeric_tuple_consumers_w96_spec.cr`,
  `scripts/probe_numeric_tuple_w96_red.cr`,
  `scripts/check_numeric_tuple_oracle.cr` and matching `.sh` wrapper.
  It may update only the superseded UInt8 rejection in
  `spec/wide_tuple_type_plan_spec.cr`; replace it with a still-rejected Bool
  neighbor, retaining positive UInt8 coverage in the W96 plan specs.
- Root: import order, documentation, central executions, hostile review and
  atomic local commit. Workers do not execute compiler/spec/oracle or Git.

`WideTupleNumericType` is the closed numeric identity/width contract, not a
second payload codec. Its Value and Buffer aliases are linear across the 15
nominal scalar types. `WideTupleLeafColumn::Value` and `::Buffer` add String.
Existing array constructors remain; inferred concrete Array(T) constructors
admit only these exact native types/wrappers. `values_as(T.class)` returns an
owned typed array or rejects a nominal mismatch; old UInt64/String getters
remain. Row/data scalar access widens to the single closed Value union;
`value_as(field, T.class)` returns exactly T or rejects without conversion.
This deliberately widens static return unions, not prior values or behavior.

TupleReader consumes one numeric-leaf decode delegate, builds concrete typed
arrays, and delegates to existing `decode_array_numeric_value`. The writer's
one private numeric-buffer delegate reuses `write_typed_numeric_stream`.
String operations and UInt64 key/index operations retain their own delegates.
No public unguarded raw decoder is introduced. Each field uses its exact width
for pre-allocation/pre-stage frame/file and logical-result charges.
Staged readback compares Float32/64 raw bits, BFloat16 bits and nominal
256-bit words, never arithmetic Float equality. Default-count policy must be
anchored to persisted stock observations, separately from fresh master source
(`ColumnVector.h:292` now distinguishes negative-zero default bits).

## Executable gates and strongest fallback

1. Existing-API plan RED above; small pinned stock-created Int8 Tuple reader
   RED, with UInt64/String positive control and observed numeric metadata.
2. `crystal spec` on the three new model/writer/consumer spec files plus
   `wide_tuple_numeric_w96_spec.cr` and existing compositional/W95 Tuple specs,
   in debug and `--release`: zero failures/errors.
3. `bash scripts/check_numeric_tuple_oracle.sh`: both directions for all 15
   types, independent bytes, multiple/short marks, full/window/sparse
   high-level/catalog reads, stock ATTACH and CHECK. Qualify byte checks with a
   seeded bit mismatch, and retain nominal mismatch/zero-stage/budget guards.
4. Existing `check_compositional_tuple_oracle.sh` and `check_tuple_oracle.sh`:
   zero failures, including legacy raw exact-pair behavior and empty-String EOF.
5. Full debug `crystal spec --link-flags='-fuse-ld=ld'`, format check, shell
   syntax and `git diff --check`: zero failures/errors. Full release is not a
   declared gate; focused release is. Run heavy commands only under fresh
   memory/resource admission and the inspected scoped process-tree watchdog.

Persisted stock bytes/ATTACH/CHECK are the differently constructed fallback
to library self-roundtrip; a passing self-roundtrip alone cannot close W96.
Wrong widths, equal-width signedness confusion, empty-argument aliases, bad
mark schedules, later unsupported fields and budget overflow must reject.
Keep all older metadata, ownership and lazy-payload guards unchanged. If
stock metadata or default semantics differ, stop that sub-boundary and record
the distinction; do not silently broaden accepted metadata or weaken bytes.

## W96 observed result

The frozen code extends the shared owned leaf/row contract and Tuple reader
and writer to all 15 exact primitive numeric types. It reuses existing scalar
payload codecs rather than implementing a second numeric serializer. The
table and catalog consume the single nominal `WideTupleRow`; no per-arity
native Tuple union was added. Existing UInt64/String accessors and the legacy
exact-pair API retain their own regression gates.

Root executed these checks on the combined W96 source with the MacOSX26.5 SDK,
the existing local Crystal compiler and `--link-flags='-fuse-ld=ld'`:

- Focused DEBUG handle 84503: exit 0, 83 examples, zero failures/errors/pending;
  focused RELEASE handle 18561: the same 83 examples and result. Both use the
  four new W96 spec files and ten existing ownership, plan, row, table/catalog,
  reader and writer Tuple regression files. Their test execution times were
  532.94 ms and 345.02 ms; these are not reader benchmarks.
- `bash scripts/check_numeric_tuple_oracle.sh`, handle 23381: exit 0. All 15
  numeric identities passed both directions against pinned stock 26.7.1.1315
  for mixed-with-String, numeric-only and all-default profiles. The oracle
  independently encodes little-endian/VarUInt RowBinary bytes, preserves
  signed extrema, high integer words, signed zero, NaN and BFloat bits, and
  first rejects a seeded byte mismatch. It checks exact stream inventories,
  short-final/terminal marks, direct full/ranged reads, typed full/window/sparse
  reads, catalog values, stock `ATTACH`/`CHECK` and full/selected RowBinary.
  Stock sampled default counts are bounded, not assumed exact; the all-default
  stock profile has empty column records while the writer emits explicit
  Default records.
- One sequential watchdog batch of
  `bash scripts/check_compositional_tuple_oracle.sh && bash scripts/check_tuple_oracle.sh`,
  handle 72214: exit 0. W94/W95 high-level/catalog and 1/2/3/9-field profiles,
  legacy exact-pair Default/AlwaysDefault, binary/empty String EOF, Sparse
  rejection and malformed-input no-publication checks passed.

Focused and oracle phases had fresh free memory 76%, a 600-second process-tree
timeout, an 8192 MiB process-tree RSS guard and a 50% free-memory floor. No
guard fired in those phases.
This establishes bounded execution admission, not a measured peak RSS or a
matched ClickHouse speed ratio. Resource ordering used separate serial phases;
the old-oracle batch was independently admitted after a read-only host check
when delivery of the peer's intended grant failed at message permission.

The first full DEBUG attempt, handle 77490, was inconclusive: after about
40 seconds the watchdog killed its process tree at 8,811,760 KB RSS, above the
8192 MiB cap. No suite result was produced. This is test-process resource
evidence, not a failing example or library runtime memory measurement. The
16 GiB retry considered during diagnosis was never launched. The actual
retry uses the previously observed W95 full-suite 32768 MiB envelope, still
with a fresh admission and unchanged 50% host free-memory kill guard.
That retry, handle 51830, exited 0 after about 128 seconds including
compilation: 1226 examples, zero failures/errors/pending, test execution
34.19 seconds. Fresh free memory was 76%; no timeout, RSS or free-memory guard
fired. The full-suite command was
`crystal spec --link-flags='-fuse-ld=ld'`, with Crystal 1.21.0 / LLVM 22.1.8
on aarch64 Darwin and the isolated W96 cache. This result does not claim a
full RELEASE run or infer library runtime RSS from the process-tree guard.

Two initial DEBUG attempts were compile failures before any examples ran:
the generic constructor did not definitely initialize `@values`, and a spec
macro used unqualified wrapper constants. Both were corrected before the
passing gates; neither failure is test coverage. Oracle instrumentation also
needed local range indexes rather than global row indexes and a window
expectation derived from selected keys. These corrections did not relax
production admission, physical inventories or bit comparisons.

Scoped hostile model/reader and writer reviews found no counterexample to
exact nominal admission, bit preservation, ownership, mark alignment or the
declared logical charge. Same-lineage reviews are correlated static evidence;
root's differently constructed persisted-stock oracle is the compatibility
fallback, not model agreement. Existing staged-readback copies and post-snapshot
metadata-budget validation are recorded in `PERFORMANCE_BACKLOG.md`, not
optimized here. The 64 MiB charge is logical accounting, not peak memory.
Caller inputs must remain stable during synchronous writes; concurrent key
mutation is not a supported thread-safe contract.

Final hygiene passed: all 19 owned Crystal paths pass `crystal tool format
--check`; the new numeric and two legacy Tuple wrappers pass `bash -n`;
`git diff --check` passes. The final scoped adversarial verdict is ROBUST
for the declared profile, supported by the executed negative controls and
independent persisted-stock bytes/ATTACH/CHECK, not static model agreement
alone. A full RELEASE suite is not required or claimed.
The optional evidence-packet template and structural
validator are absent in this checkout; this living source-linked frontier is
the fallback record, not a claimed validator pass.

## Remaining frontier and continuation

Active goal: complete compatible read/write types and MV/projections before
memory/performance optimization; the eventual matched ClickHouse slowdown
<=10% condition is still unproven. W96 is one bounded type-composition slice,
not overall completion.

Return pointer: the implementation seal and observed results in this file;
`COMPOSITIONAL_TUPLE_FRONTIER.md` retains the separate W94/W95 and legacy
pair certificates. The next type falsifier should use a pinned stock-created
named Tuple with a semantic leaf (for example Bool), verify its exact nominal
schema/physical streams/default records, then establish the current reader
rejection before admitting matching reader, writer and high-level access.
Do not relabel Bool as UInt8 solely because its physical width is one byte.

Still rejected by this compositional Tuple profile: semantic leaves such as
Bool, date/time, decimals, UUID/IP and Enum; Nullable, nested/unnamed/empty
Tuples; arbitrary table schemas/writing, Compact/Sparse and current-master
metadata. This does not say those scalar types are unsupported at the root
column level. Fresh-master MultiPoint/Geometry discriminator 6, JSON shared
`ADVANCED_CHUNKED` and `exact_num_defaults` need their own runtime/version
matrix; the source snapshot is not a current-master executable certificate.
Broader MV/projection behavior and remaining facade ownership are separate
open obligations.

Standing authority: scoped local code, tests, temporary fixtures and coherent
atomic local commits. No push, history rewrite, new-master executable
installation or private production-data mutation. Synchronous writer inputs
must remain stable. Refresh the focused gates, full DEBUG and pinned stock
oracles when the identity/codec/ownership/charge/metadata/mark/import/fixture
or compiler/executable assumptions above change; otherwise preserve this
slice and advance through a separately sealed semantic-leaf probe.
