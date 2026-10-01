# Timezone-qualified Temporal Frontier

Status: W104 is verified within the pinned seven-shape timezone-qualified
Wide-part profile. Root executed the final focused DEBUG/RELEASE, full DEBUG,
both exhaustive stock-oracle phases and six regression oracles below.
Predecessor:
`f3ff06b5b06ad7b997401cf78133a8a9bfa2ef5d`. The full active goal remains all
type read/write compatibility and MV/projection support before performance
work. This slice does not replace that goal with a timestamp-only target.

## Anchor and problem

The predecessor admits bare DateTime and DateTime64(0..9) in scalar,
Nullable scalar, Array, Array(Nullable), Array(Array),
Array(Array(Nullable)) and named-flat Tuple paths. Exact timezone-qualified
declarations are rejected by the shared-reader regexes and the Tuple temporal
owner. Existing primitive carriers must not be used to relabel those types.

Fresh reference source is the immutable shallow a9581941254d snapshot in
`/Users/sergey/SrcArchives/clickhouse-2026-09-29-depth1`; runtime qualification
uses `/Users/sergey/.local/bin/clickhouse`, version 26.7.1.1315. Root queried
`system.time_zones`: 597 unique names, sorted, maximum length 32 bytes. The
measured name fixture is `spec/fixtures/stock_timezone_names_26_7.txt`.
Source DateLUTImpl.cpp:71-152 describes a newer embedded-name admission policy
and 598 database names, plus canonical quarter-hour Fixed offsets within
14 hours. Do not import the host timezone database as ClickHouse authority or
claim the pinned name list is the newer executable's list.

Root additionally observed exact stock names for Etc/UTC, US/Eastern,
Fixed/UTC+05:45:00, Fixed/UTC-14:00:00 and Fixed/UTC-00:00:00. This is a
type-name probe, not yet a part read/write certificate.

## Proposed admission and design laws

Extend every existing shape above with exact canonical DateTime('zone') and
DateTime64(p, 'zone'), all precisions 0..9. Use a versioned pinned name
catalog plus canonical Fixed/UTC+HH:MM:SS and Fixed/UTC-HH:MM:SS quarter-hour
offsets no further than 14 hours; preserve both signed-zero spellings.
The catalog must have a replaceable/versioned boundary rather than a host
lookup or an assumption that type names never evolve.

Raw DateTime payload remains UInt32 epoch seconds, DateTime64 remains signed
Int64 ticks. No timezone conversion, rounding, clamping, rescaling, session
timezone substitution, alias normalization, per-row zone parsing or primitive
numeric admission. Reader and writer advance together for all seven shapes.
Legacy APIs and bare constructors keep their current behavior; writer APIs
may add an optional timezone parameter without breaking existing calls.

`TimezoneName` and `DateTimeColumnType` govern exact name admission, parsing,
canonical strings, parameter identity and shape recognizers, one concrete
owner per source file. Zone provenance belongs to the column/field/plan;
owned Tuple rows retain it through their shared data's fields/type_name,
including copied and empty columns. Extracted DateTimeValue scalars remain raw
instants; DateTime64Value additionally retains precision, exactly as before.
Their constructors/equality do not acquire zone semantics or per-row metadata
allocations. Share immutable schema descriptors rather than allocating or
normalizing a zone string per row. The new descriptor owners and retained
Tuple field/plan/leaf snapshots must not expose mutable schema authority.
This does not establish defensive exports for every older table/part facade;
their existing mutable String exports remain outside this slice. Charge actual
wrapper slots and retained
descriptors, not only four/eight physical bytes.

Context bridge: CH DataTypeDateTime.cpp:32-38 treats different zones as equal;
DataTypeDateTime64.cpp:50-62 equality/hash use scale, not zone. Library exact
declaration/provenance equality is deliberately stronger for storage readback
and DDL/part matching. It must not be presented as CH execution type equality,
nor imply that different zones have different raw physical bytes.

Rejected/non-goals for this slice: unknown or unavailable catalog names,
noncanonical parameters, NUL/path/libc spellings, arbitrary recursive or
nullable Tuple shapes, SQL formatting/functions/conversions, Compact/Sparse/
new metadata profiles, arbitrary schema writer and performance claims.
These remain implementation/profile limits, not claims that old CH binaries
reject every guarded spelling. Current-master executable/name qualification
is still open.

## Risk, falsifiers and rollback

Risk: CAUTION (persisted serialization and public nominal values). Strongest
failure: a same-width/same-tick different-zone declaration silently loses its
name in a reader, wrapper, Array accessor, writer or staged readback. Attack
bare versus UTC, UTC versus Etc/UTC, US/Eastern versus America/New_York,
positive/negative fixed zero, every precision, reordered/repeated Tuple
leaves, empty/all-zero/all-NULL buffers and same-raw/wrong-zone schemas.

Before production, execute existing-API admission RED across every shape and
both temporal families, all precisions and positive legacy controls. Then
stock-create qualified timezone parts: independently check exact metadata,
physical stream bytes and actual mark schedules, CHECK and full/selected
RowBinary before asserting current typed-reader rejection. A fixture/compiler
failure is not production RED. The comparator must reject a seeded wrong
expectation. Timezone-independence of raw bytes is an opposite-frame control.

After implementation, verify pre-stage input validation and no publication
for wrong precision/zone/shape/count, unsafe names and budget overflow;
validate actual staged schema and raw values, not a replaceable test callback.
Exact same-raw/wrong-zone schema must fail the real readback/schema comparator.
Reader preflight and no-callback-on-metadata mismatch remain mandatory.

Rollback: one coherent local commit based on the clean predecessor, after
declared gates. Preserve unrelated work. No push, history rewrite, dependency
changes, binary installation or mutation of the existing CH checkouts.

## Execution plan and Definition of Done

Root owns this frontier, the require graph, the measured name fixture, combined
review, serial runtime gates and exact-path commit. Luna Max reader/model
owns new declaration/name owners, temporal wrappers, reader/Array/Tuple
admission and table/catalog adapters; writer owns writer APIs/infrastructure
and writer specs; oracle owns independent stock probes and consumer specs.
Workers are not alone and must preserve each other's changes. Exact paths and
interfaces are sealed after the read-only inventories, before production.

Sealed shared interface: `TimezoneName.parse(String)` returns an exact copied
name owner or nil; its public `name` is a copy. `DateTimeColumnType` has
`Family::{DateTime, DateTime64}` and `Shape::{Scalar, Nullable, Array,
ArrayNullable, ArrayArray, ArrayArrayNullable}`. Factories `datetime(time_zone:
String? = nil)` and `datetime64(scale: Int32, time_zone: String? = nil)` raise
ArgumentError for invalid input; `parse` and scalar-only `parse_leaf` return
nil for invalid or noncanonical declarations. `with_shape` retains the exact
leaf identity. Accessors expose family, optional UInt8 precision, optional
TimezoneName, shape, array depth, nullable-leaf flag, raw width and canonical
leaf/full names. Tuple is not an outer shape of this descriptor: its plan
retains a scalar descriptor for each temporal field. The twelve specialized
writer entry points add only a keyword `time_zone: String? = nil` after their
existing `rows_per_mark` argument; Tuple takes its zones from the declared
field types. No DateTimeValue/DateTime64Value constructor change is admitted.
`WideTupleField.datetime_type` exposes the optional immutable scalar descriptor;
`DateTimeColumnType.logical_charge` bills the retained descriptor, zone String
storage and any cached names once per field, including bare descriptors. These
are logical budget contracts, not peak-RSS estimates. Field/plan/leaf snapshots
must preserve the descriptor without per-row parsing or mutable public exports.
The existing container/slot accounting does not itemize every copied schema
name/type-name String, allocation header or transient snapshot; W104 adds the
actual field slot and retained temporal descriptor charge, not a complete
allocation or RSS model.

The existing catalog-only DDL normalization boundary may accept harmless
whitespace around temporal parameters, including `DateTime64(3,'US/Eastern')`,
and produce the canonical declaration without changing the exact alias.
Persisted `columns.txt` parsing remains strict. A normalized DDL declaration
with a different exact zone must still reject the part before user callbacks;
matching raw widths or values is not sufficient.

1. Execute admission/stock RED on unchanged production; expected behavioral
   rejection after passing positive fixture controls.
2. Implement the shared exact owners and propagate every existing temporal
   shape in reader/writer/model/consumers, one owner per file. Preserve all
   metadata/checksum/mark, ownership, exclusive-publication and resource gates.
3. Focused DEBUG and RELEASE: new timezone specs plus existing scalar,
   Nullable, one/two Array levels and Tuple temporal specs; no failures,
   errors or pending examples.
4. Bidirectional timezone stock oracle: all precisions and shapes, measured
   name-catalog agreement, aliases/DST/fractional and bounded fixed offsets,
   independent bytes/marks/full and selected RowBinary, stock ATTACH/CHECK,
   high-level full/window/catalog consumers and seeded comparator defect.
   Exhaustive declaration-name tests are distinct from physical profile tests.
5. Unchanged datetime, nullable temporal, Array temporal, nested Array temporal,
   temporal Tuple and QBit oracles; full DEBUG with --single-module. Format,
   shell syntax, diff and exact-path hygiene checks exit zero.
6. Root hostile review, seal this frontier with executed commands and limits,
   then atomic local commit. No all-types or performance-completion claim.

Runtime envelopes: inspected cogni-ml/scripts/run_safe.sh; 50-percent system
free-memory floor, 600-second timeout, 8-GiB focused/oracle and 32-GiB full
DEBUG process envelopes. Crystal 1.21.0/LLVM 22.1.8, SDK 26.5, linker
--link-flags=-fuse-ld=ld, isolated W104 cache, pinned CLICKHOUSE and
CLICKHOUSE_BIN. Root alone executes heavy workloads serially. Sandbox ps
denial requires an approved runtime escalation, not a disabled watchdog.

Certificate decay: any catalog/binary, timezone grammar, nominal identity,
precision, wrapper/ownership/charge, codec, mark/metadata, Array/Tuple
consumer, writer or publication change requires affected gates to refresh.
MV/projection breadth, whole-facade decomposition and the <=10-percent
ClickHouse performance target remain open.

## Executed preimplementation admission probe

At the unchanged predecessor, root executed:

```sh
crystal spec --link-flags=-fuse-ld=ld spec/timezone_temporal_admission_w104_spec.cr
```

The exhaustive existing-API instrument reported 234 examples, 156 assertion
failures, zero errors and zero pending examples. All 154 zoned shape/leaf/zone
cases and two exact Tuple alias cases failed at the admission boundary; 77
bare declaration controls and the malformed/out-of-profile control passed.
The initial loop-based probe was replaced because its first assertion skipped
the remaining matrix and a nil assertion produced an instrument error. Neither
that error nor a runtime-wrapper invocation error counts as physical-format RED.
The subsequent qualified stock RED below authorizes the paired implementation.

The stock byte matrix may use many payload columns, but the admitted Array
and named-flat Tuple reader profiles require exactly a UInt64 key and one
payload column. Root qualified all seven multi-column source/ATTACH matrices;
their Array bare-reader control then failed at that existing layout guard.
This is not a timezone RED. Admission must additionally use real, separately
qualified two-column stock parts with passing bare controls and zoned probes;
do not widen production's layout policy to repair a test fixture.

The unchanged temporal baseline passed: 96 examples, zero failures, errors or
pending examples across scalar, Nullable and named-flat Tuple reader/writer,
model and consumer specs. During instrument qualification, scalar and
Nullable stock profiles passed, but the Array expected size stream incorrectly
used cumulative offsets instead of physical per-row lengths. That instrument
defect and the earlier iterator-return compile defect do not establish a
production RED. All seven source/ATTACH profiles must still qualify together.

The pinned binary also admitted malformed Fixed offsets `+00:75:00`,
`+01:14:60` and `+14:15:00`, retaining their source spelling. W104 deliberately
guards these spellings under the canonical source-derived admission policy;
it does not assert that 26.7 rejects them or that their physical storage has
been qualified.

## Qualified stock RED and implementation authorization

At the unchanged predecessor, root ran the pinned oracle under the declared
600-second/8-GiB watchdog and 50-percent free-memory floor:

```sh
bash scripts/check_timezone_temporal_oracle.sh --red
```

Observed exit zero after approximately 257 seconds. All seven multi-column
source and ATTACH shape matrices passed exact schema/substreams, handwritten
raw bytes, complete stream inventory, exact marks, pinned serialization
statistics, CHECK TABLE and full/PK-selected RowBinary. The five pair-restricted
shapes additionally passed 120 separate exact key/value source and ATTACH
profiles (22 zoned fields plus two bare controls per shape), before any typed
reader probe. Fourteen bare typed-reader controls passed. All seven seeded
one-byte comparator defects were rejected. The same-epoch UTC/NY spring/fall
text control differed while raw payload streams remained equal.

The existing reader then rejected exactly 297 qualified zoned declarations
with UnsupportedFormatError. This measured count supersedes an earlier
unverified 319 estimate. Fixture, compiler, layout and watchdog errors are
excluded from this result. Root authorized the paired production implementation
only after this complete run. This is a predecessor RED certificate, not a
GREEN certificate for implementation, current-master executable coverage,
all types or performance.

## Verification feedback before final qualification

The first combined focused DEBUG and RELEASE runs each passed 429 examples;
the full DEBUG run passed 1,693 examples after a test-only private TupleReader
constructor forwarding repair. All six declared regression oracles passed.
The isolated one-profile writer smoke passed actual stock ATTACH, CHECK and
full/selected RowBinary after correcting the instrument's frame schedule,
optional serialization metadata policy and MergeTree fixture basename.
None of those instrument repairs changed production serialization.

The subsequent complete GREEN invocation failed with a real production
counterexample, not a watchdog timeout: low-level reads of all 297 qualified
zoned declarations passed, but the table consumer for
`Nullable(DateTime('America/New_York'))` reached the literal-only
`Nullable(DateTime)` dispatch in `WidePartTable#read_nullable_values` and
raised UnsupportedFormatError. Existing successful tests do not close this
consumer path. Add focused full/window/catalog/column-values regressions
before the narrow descriptor-based repair, then refresh affected final gates.
No complete bidirectional GREEN or W104 completion is claimed at this point.

The focused consumer counterexample was then reproduced with a valid
`all_1_1_0` fixture: five examples ran, with only the zoned Nullable(DateTime)
example raising the dispatch error. The separate DateTime64 control passed
table/catalog full and window scans, exact schema, and column `.values`.
The shared descriptor's exact Nullable/DateTime guard now delegates to the
existing raw-seconds reader; the five-example regression passed afterward.
No payload codec or writer-publication policy changed in that repair.

The subsequent monolithic `--green` invocation exited one after roughly
eleven minutes with no captured diagnostic output or completion signal.
The inspected runner's independent backstop exits without dumping buffered
stdout; the observed timing/output is consistent with that path, but the
termination reason was not logged. This run is inconclusive, not GREEN.
Do not increase or disable its runtime/resource limits. Qualify the same
matrix as independently executable `--green-reader` and `--green-writer`
phases, each on a fresh temporary store under the existing 600-second,
8-GiB and 50-percent free-memory guards. Preserve the combined `--green`
mode, all 297 reads and 297 writes, 14 consumer profiles, seven seeded
comparators, and opposite-frame controls. Enable the runner's existing
stdout passthrough for discriminating progress; both phase exits must be
observed before a complete bidirectional certificate is admitted.

## Executed W104 compatibility certificate

The frozen implementation, including the descriptor-based Nullable(DateTime)
consumer repair, passed these final gates. This certificate belongs to the
atomic Git commit containing it; the earlier 429/1,693-example runs do not
replace the refreshed results.

| Gate | Observed final signal |
| --- | --- |
| Focused DEBUG | 431 examples, zero failures/errors/pending |
| Focused RELEASE | 431 examples, zero failures/errors/pending |
| Full DEBUG, single module | 1,695 examples, zero failures/errors/pending |
| Stock-reader phase | 297 zoned stock declarations attached and 297 typed reads; exit zero |
| Library-writer phase | 297 writes, stock ATTACH/CHECK and full/selected RowBinary, 14 table/catalog consumer profiles, seven seeded comparator defects; exit zero |
| Six unchanged regression oracles | All exited zero; QBit retained all 80 profiles and its 3,000-row split-plane control |
| Static/instrument guards | Crystal format, Bash syntax and diff checks exited zero; missing/unknown oracle mode exited two before creating a store |

Reader and writer phases completed under their original per-command guards in
approximately 232 and 169 seconds. The combined mode remains available, but
the inconclusive monolithic run is not promoted to a successful invocation.
The bidirectional certificate is the conjunction of the two successful,
fresh-store phases, with the original matrix and aggregate count gates intact.

Reproduction commands, run from the repository root with Bash:

```bash
verification_env=(env
  CLICKHOUSE=/Users/sergey/.local/bin/clickhouse
  CLICKHOUSE_BIN=/Users/sergey/.local/bin/clickhouse
  COGNI_RUN_SAFE_MIN_FREE_PCT=50
  SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
  TMPDIR=/private/tmp
  CRYSTAL_CACHE_DIR=/private/tmp/crystal-click-w104-cache
  PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
  bash /Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh)
focused_specs=(
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
  spec/wide_part_reader_compositional_tuple_spec.cr)
"${verification_env[@]}" crystal 600 8192 spec --link-flags=-fuse-ld=ld "${focused_specs[@]}"
"${verification_env[@]}" crystal 600 8192 spec --release --link-flags=-fuse-ld=ld "${focused_specs[@]}"
RUN_SAFE_PASSTHROUGH_STDIO=1 "${verification_env[@]}" bash 600 8192 scripts/check_timezone_temporal_oracle.sh --green-reader
RUN_SAFE_PASSTHROUGH_STDIO=1 "${verification_env[@]}" bash 600 8192 scripts/check_timezone_temporal_oracle.sh --green-writer
"${verification_env[@]}" crystal 600 32768 spec --single-module --link-flags=-fuse-ld=ld
RUN_SAFE_PASSTHROUGH_STDIO=1 "${verification_env[@]}" bash 600 8192 -c 'set -eu; for oracle_script in scripts/check_datetime_oracle.sh scripts/check_nullable_temporal_oracle.sh scripts/check_array_temporal_oracle.sh scripts/check_array_array_temporal_oracle.sh scripts/check_temporal_tuple_oracle.sh scripts/check_qbit_oracle.sh; do bash "$oracle_script"; done'
```

Expected signals are the counts above and successful exits, not merely a
compiler result or presence of a certificate. The full DEBUG linker emitted
the existing nonfatal duplicate `-lc` warning. No resource guard was disabled,
no current-master binary was installed, and no performance claim is made.

Root adversarial verdict: ROBUST within this tested profile. The strongest
actual counterexample was low-level reader success with a broken high-level
Nullable(DateTime) dispatch; its valid-fixture RED, separate DateTime64 control,
five-example GREEN and complete fourteen-profile consumer refresh close that
specific path. Independent handwritten bytes/marks, stock RowBinary/CHECK and
seeded expected-byte defects guard against reader/writer mutual agreement on
the same encoding error. Same-raw/different-zone schema tests preserve exact
provenance rather than importing ClickHouse's zone-insensitive execution type
equality.

Residual limits: the 597-name manifest is a pinned admission/name certificate,
not 597 physical timezone profiles. Physical coverage is the explicit
297-declaration matrix. Its nine-row/two-rows-per-mark fixtures contain empty
array rows, but do not separately qualify an entirely empty flattened temporal
leaf granule against stock; all-NULL/all-empty writer unit controls are not
such an independent stock certificate. Current-master names/metadata, arbitrary
recursive types, Compact/Sparse profiles, general multi-column writers,
universal defensive facade exports and complete allocation/RSS accounting
remain open. MV/projection expansion, whole-facade decomposition and the
<=10-percent performance target are unchanged. Refresh affected gates on the
decay events listed above; do not silently widen this certificate.
