# SimpleAggregateFunction nullable-storage frontier — W221

## Current state

Status: VERIFIED within the finite W221 scope; scoped adversary verdict ROBUST.
Construction and stock physical laws were measured and behavioral admission
RED established before implementation. The 16-file core/public gate passes
101 examples in DEBUG and RELEASE. The 14-file affected regression gate
passes 81 examples per mode (three serial groups in RELEASE): 182 examples
across 30 unique files per mode, zero failures/errors/pending.
Fresh bidirectional qualification passes 186 stock reads and 186 library
ATTACH/CHECK/value witnesses per mode. Both separate raw-evidence audits pass.
Baseline: clean `8e42a4ee6d36b2f4fe5489501d466308dfd5c4d8`.
The previous W220 turn made authoritative progress: the generic owned Dynamic
consumer was verified within its declared scope and committed. The full
reader/writer type and MV/projection goal stays active; memory/performance,
including the original <=10 percent speed-gap target, remains deferred.

Risk: CAUTION (nominal type identity, null-map ownership, public read/write
dispatch and staged publication). Rollback: exact W221-owned changes or the
eventual single coherent local feature commit. Preserve other work; no push.

Comparison source: `/Users/sergey/SrcArchives/clickhouse-2026-10-07-depth1`,
revision `0ca8150d9b1d0886edb2e3b4ab65eebb768d0357`.
Executed stock is separately pinned to `26.10.1.1201`, build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`, executable SHA256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
The source snapshot is not that executable's build or a perpetual latest claim.

## Existing and proposed surface

Baseline admitted SAF profiles: nine canonical unary, non-parametric
functions under the W163/W164 numeric, W168 text, W169 Decimal and W170
temporal function/result-type laws; scalar or outer Nullable. Logical SAF
values and bulk recursively delegate to their storage child. Inner Nullable
storage and the two `respect_nulls` function identities were refused at baseline.

Implemented capability: compose `any_respect_nulls` and
`anyLast_respect_nulls` with existing eligible leaf codecs; compose one inner
Nullable child under the source/runtime function-result equality law for
the admitted functions. Reader and writer admission must move together,
including their public table/offline consumers and staged validation. A
logical-only descriptor change does not establish complete-part support.
Exact carrier/scale/zone/function identity and all existing byte/owner bounds
remain required. Finite witnesses do not qualify every parameter value.

Production admission after the measured law and observed RED:

- Canonical inner Nullable over an already admitted scalar storage leaf.
- Scalar-child SAF with either new canonical respect-null function.
- The matching existing physical reader/writer and public consumer routes.

Rejected/non-guaranteed in this slice:

- Double nullability: outer Nullable over a SAF whose child is Nullable.
- Alias spellings, function parameters, additional arguments and unmeasured
  function/child products; no inference from equal raw widths.
- General SAF Array/Map/Tuple/LC/Variant/Dynamic/JSON products, additional
  allowlisted aggregate functions, aggregate-state execution/serialization,
  Compact/legacy mark transports or arbitrary complete-part qualification.
- Memory/performance claims, generalized MV execution or projection generation.

These are current implementation/evidence boundaries, not universal CH laws.
Source factory admission still has 22 function identities; implementing this
capability does not close the remaining SAF or AggregateFunction state gaps.

The independently executed matrix on 2026-10-08 covers eleven canonical
functions, twenty-nine leaf/parameter witnesses and four Nullable placements,
plus seven controls: 1,283 cases, 717 accepted and 566 specific semantic
refusals, zero law mismatches or probe failures. All eleven functions admit
inner Nullable exactly when their bare function/result law accepts the leaf.
This is a finite construction certificate, not complete-part compatibility.
The raw matrix is `/private/tmp/crystal-click-w221.gqkEtb/matrix.json`; the
outer guard exited 0 with minimum free-memory threshold 50 percent. The
probe pins executable SHA, version and build before interpreting cases.

## Observed discriminators

ROOT's isolated stock construction probe accepts and prints exact names for
`SAF(any_respect_nulls, UInt8)`, `SAF(any_respect_nulls, Nullable(UInt8))` and
`SAF(anyLast_respect_nulls, Nullable(UInt8))` (abbreviation only in this prose).
`CREATE TABLE x(v Nullable(SimpleAggregateFunction(any_respect_nulls,
Nullable(UInt8)))) ENGINE=Memory` refuses with actual Code 43
`ILLEGAL_TYPE_OF_ARGUMENT`, not a crash or runtime-resource failure.
Logs are retained under `/private/tmp/crystal-click-w221.33A6fF`.

Source anchors: `DataTypeCustomSimpleAggregateFunction.cpp:31-64` allowlist;
`:151-169` builds the storage child, requires aggregate-result equality and
adds only a custom name, not a custom serializer. `DataTypeNullable.cpp:32`
checks whether the nested storage type can be inside Nullable. At the baseline,
Crystal's `BinarySimpleAggregateType` rejected the new function names and
inner child; `BinaryDataType.simple_aggregate` admitted only scalar leaf tags.

## Design laws and execution order

Composition direction (2026-10-08 clarification): reuse recursive child codecs
through a physical column adapter carrying stream bindings, occurrence ranges
and serializer state. Do not create a codec or a typed accessor chain for every
function/carrier/wrapper product. Existing `BinaryBulkCodec` returns owned
`BinaryValue` roots, and the offline result union already includes that owner.
The current specialized complete-column adapters and nominal admission rules,
not an absent Nullable value codec, are the integration boundary. The shared
static-bulk reader, writer and private part-publication owner now have separate
files; thin nominal Nested and SAF adapters preserve admission.
Dynamic and JSON must not be implicitly admitted without their structure context.

The independent stock physical probe subsequently passed 186 profiles: two
respect-null identities across the 29 leaf witnesses and three legal nominal
shapes, both String profiles, plus six existing-function inner-Nullable
controls. Every source part passed stock CHECK, exact native declarations,
copied-file identity and literal full/middle/empty RowBinary comparisons.
The raw matrix is `/private/tmp/crystal-click-w221-physical.OLMb5t/matrix.json`;
the 50-percent guard exited 0. At that stage it established stock fixtures and
physical policy, not yet Crystal reads or library writes. Nullable BASIC adds no
serialization-version key: the measured metadata has only `string:0` or
`string:1`, with version 1 and nested-version propagation enabled. Existing
strict metadata policy is retained, not widened for an anticipated key.

The stock probe leaves the String setting unspecified on 174 non-String
profiles: the pinned runtime emits the global `string:1` default for those
parts. Its six explicit single-stream String profiles emit `string:0`, and
six explicit with-size profiles emit `string:1`. The library's explicit
single-stream profile emits `string:0` even without a String leaf. The native
oracle therefore checks separate exact source and library metadata policies;
it must not infer the global stock setting from the absence of a String leaf.
The generated key's Default serialization-info entry also intentionally
differs from the stock source's empty `columns` array. These bounded metadata
differences require successful stock ATTACH/CHECK and literal value reads,
not a byte-identical metadata claim.

The first physical attempt used an unsupported Ruby 2.7 `filter_map` API on
the host's Ruby 2.6. Its 186 helper exceptions are probe failures, not CH type
or format rejections. Its evidence remains at
`/private/tmp/crystal-click-w221-physical.liohIX`; the corrected probe reran in
a fresh root. Stock processes themselves succeeded in that failed attempt.

Keep `SimpleAggregateColumnType` as the legacy scalar-child/optional-outer-NULL
facade. Its `nullable?` flag must not acquire a second meaning. Canonical
inner-Nullable SAF is admitted by the binary descriptor and a dedicated bulk
declaration route; legacy typed scalar accessors continue to refuse that shape.
The longest function name is 21 bytes. The existing 32-byte timezone witness
requires 107 bytes for either SAF with one inner Nullable or outer Nullable
over bare SAF; no accepted shape includes both shells.

The independent construction matrix uses the live current leaf roster: fifteen
numeric leaves (six UInt, six Int, Float32, Float64 and BFloat16), String,
FixedString, four Decimal widths and six temporal families: 27 base witnesses
before parameter/long-zone controls. The earlier inventory count of seventeen
numeric leaves was incorrect; Bool and Float16 are not in the existing SAF
storage policy. Parameter witnesses are finite, not exhaustive domains.

1. Measure a construction matrix from the pinned stock runtime independently
   of Crystal support fixtures. Distinguish expected CH type/result refusals
   from crashes, signals, timeouts and runtime drift. Inspect the corresponding
   source laws; freeze accepted/rejected products before production changes.
2. Add an existing-API behavioral RED with an old-profile positive control.
   New enum names or methods must not be the reason compilation fails.
3. Preserve nominal `Nullable(SAF(f,T))` versus `SAF(f,Nullable(T))` identity
   while reusing the single ordinary null-map/payload codec. Reject double
   nullability at descriptor, parser, writer and consumer admission boundaries.
4. Prefer a cohesive storage-child/nullability owner or explicit shape, not
   one codec/class per function/carrier product. Reuse the existing leaf,
   recursive budget, physical binding and staged-publication responsibilities.
   Raise parser caps only to a derived bounded grammar maximum; do not turn
   this into unchecked recursive SQL parsing.
5. ROOT runs focused DEBUG/RELEASE plus affected existing SAF/Nullable/core,
   writer, catalog and projection consumers, serially under `run_safe.sh`
   with minimum 50 percent free memory. Luna owns bounded implementation and
   static analysis only; no simultaneous compiler/native jobs.
6. Fresh stock-authored parts must be read by Crystal; independently authored
   library complete parts must pass actual stock ATTACH/CHECK and exact
   RowBinary/type comparisons. Use asymmetric values, adjacent NULL/non-NULL
   rows, independent siblings and multiple granules. Retain exact raw artifacts
   and distinguish the schema/consumer path actually exercised.
7. Attack wrong nominal placement/function/carrier, malformed/null-map lengths,
   parser cap/parameter boundaries, stage comparison and publication cleanup.
   Restore seeded code exactly and rerun green. Update this frontier and
   PROJECT_STATUS after evidence, then create the atomic local commit.

Strongest predicted failure: flattening the two nominal Nullable placements
lets same physical bytes conceal a schema mismatch, or feeds a Nullable child
to an existing scalar-only semantic gate. The decisive guard must compare exact
source declarations and reject a valid-but-wrong nullability placement; a
library-only roundtrip is insufficient.

DoD: the new focused specs and affected guards pass with nonzero counts and
zero failures/errors/pending in both modes; paired native witnesses pass exact
metadata, stock CHECK and independent value bytes; an executed nominal/staged
falsifier rejects and restoration returns green. Actual commands, scope and
residuals are indexed in the [W221 evidence packet](../.landmark/evidence/simple-aggregate-nullable-w221.json).

## Continuation

Construction-law measurement is complete for the stated finite roster. The
corrected existing-API RED executed before production changes: seven examples,
five intended admission failures, zero errors or pending; the old Min(UInt64)
control and negative guards pass. The first candidate failed to compile because
it used a nonexistent test helper; that attempt is not semantic RED. A candidate
negative assertion was corrected to the existing corruption classification,
not weakened in production.

ROOT executed `crystal spec
spec/simple_aggregate_nullable_w221_admission_red_spec.cr --single-module
--threads 1 --link-flags=-fuse-ld=ld --error-trace` serially through the
50-percent `run_safe.sh` guard (600 seconds, 12 GiB ceiling). The observed RED
log is `/private/tmp/crystal-click-w221-matrix.JkdRHH/saf-admission-red-observed-3.log`.
Core implementation owns the five nominal/legacy policy files. The first
focused run passed ten of eleven examples; the remaining candidate assertion
incorrectly gave both respect-null names the longest function's size. It was
corrected to exact per-function shell accounting. Compile-only attempts that
intersected an incomplete extraction are not behavioral evidence.

The stable core/paired-part/Nested regression run then executed 90 examples:
seven failures, zero errors/pending. All new fourteen examples and the shared
Nested/physical controls passed; the seven failures were older negative
assertions about the now-admitted single Nullable child or the previous name
cap. The affected assertions now check exact positive descriptor roundtrips
and retain repeated-Nullable and other unsupported-wrapper guards. The public `.values` probe independently
produced the intended semantic RED: the existing dispatcher refused the new
inner-Nullable declaration. ROOT subsequently executed the stable 16-file
core/public cohort: 101 examples, zero failures/errors/pending, in each of
DEBUG and RELEASE. It includes exact nominal function/carrier/nullability
refusals, a parseable missing-null-map roster, wrong writer input, and executed
staged nominal/payload substitutions with preservation of unrelated files and
stage cleanup. The 14-file legacy SAF/Dynamic/projection cohort passes 81
examples in DEBUG. Its combined RELEASE compilation approached the 12 GiB
guard ceiling and ROOT terminated only its owned compiler (exit 143), before
tests ran. The same exact roster is being checked in three smaller sequential
RELEASE groups. This censored resource attempt is not a passed gate or a
behavioral test failure. The replacement groups pass 35, 23 and 23 examples,
respectively, with zero failures/errors/pending; together they check the same
81-example affected roster as DEBUG.

Fresh native attempt `/private/tmp/crystal-click-w221-bulk.1n4h2J` passed all
186 stock reads and library writer/readback checks. All 186 ATTACH/CHECK/query
processes exited successfully, but the driver's postchecks rejected two
incorrect oracle assumptions: byte-identical substream order and no auxiliary
file addition. Native Nullable substreams list the null lane first; the shared
library metadata owner sorts names. The corrected oracle parses version 1,
requires exact column identities and shape/profile-derived duplicate-free
rosters (including `v.size`), and bounds counts before allocation. Every
original file must preserve its size and SHA-256 through ATTACH. Only a new
`invalidated_system_columns.txt` containing the two distinct terminated names
`_block_number` and `_block_offset` is permitted. The pinned source explicitly
writes that file during `loadPartAndFixMetadataImpl` (MergeTreeData.cpp:9044);
IMergeTreeDataPart.cpp:1899-1904 and :1950-1974 define its contents/writer.
The failed raw evidence is retained. Fresh corrected DEBUG evidence at
`/private/tmp/crystal-click-w221-bulk.txTiUQ` passes all 186 stock reads,
library writes/readbacks and native ATTACH/CHECK/literal-window comparisons,
with 190 successful process records. No production guard was relaxed to
repair these oracles. Fresh RELEASE evidence at
`/private/tmp/crystal-click-w221-bulk.YnJ7Zl` also passes the exact 186-profile
matrix and 190 process records. Both separate evidence audits pass with
externally measured runtime/helper artifact hashes. The audits dereference
actual SQL, process sidecars, native stdout, full/middle/empty literal
RowBinary windows and every original/attached file inventory. An actual
`exitstatus=1` seed with a still-green summary is rejected; exact restoration
recovers the original sidecar SHA256 and a passing DEBUG audit.

The 2,496 library-authored files across the 186 profiles have identical
relative path/size/SHA256 inventories between DEBUG and RELEASE. These are
finite Wide/LZ4/plain-mrk2 witnesses, not every carrier parameter or transport.
The helper checks full, first, middle, final-short and zero-end mark reads
against independent literal leaf bytes. The six public consumer examples
cover actual stock part reads, borrowed batches and owned `.values`, cumulative
limits and legacy refusals. Their multi-part and projection-child controls
are synthetic; this does not qualify native full catalog or projection discovery.

Implementation ownership is split by responsibility, not type products:

- Nominal policy: `binary_simple_aggregate_type.cr`, `binary_data_type.cr`,
  `binary_data_type_codec.cr`, `simple_aggregate_column_type.cr`, and
  `simple_aggregate_temporal_storage_plan.cr`.
- Shared static physical owners: new `binary_bulk_column_reader.cr` and
  `binary_bulk_column_writer.cr`, with old Nested facades retaining their
  nominal guards. `simple_aggregate_bulk_column_declaration.cr` owns the
  bounded source declaration, not a serializer.
- Paired publication: the private `wide_part_writer/binary_bulk_part_writer.cr`
  owns shared preflight, physical planning and exact staged readback. Thin
  `nested_bulk_part_writer.cr` and `simple_aggregate_bulk_part_writer.cr`
  retain their nominal admission. The existing two-column publication envelope
  and recursive metadata remain shared. Dynamic/JSON context guards stay closed.
- Consumers: a shared BinaryValue table entry/batch path and owned offline
  materializer, plus exact source probing in WidePart. Legacy scalar/outer
  typed APIs and return values remain unchanged. Required files are added by
  the physical owner's facade change to avoid concurrent require edits.
- Independent qualification: stock physical probe and separate native
  Crystal/Ruby read-write helper; ROOT alone executes guarded jobs.

## Closure and remaining frontier

W221 is verified only within the scope above, under quiescent immutable-part
assumptions. The production physical source checks declared sizes, not all
payload hashes; same-size concurrent mutation is outside this certificate.
Logical retained/workspace limits are not a peak-RSS or allocator-capacity
guarantee. Luna's static review is correlated; ROOT inspected the guards and
executed the tests, staged substitutions and independently pinned CH witnesses.

All compiled Crystal input bytes stayed fixed across final gates and native
runs. The final 1,267-entry source manifest differs from the unit freeze only
in the corrected Ruby oracle and added Ruby evidence auditor. Evidence is an
index to actual observations, not proof by field presence. Raw temporary
artifacts, runtime/helper pins or source changes require requalification before
reusing the same claim; no perpetual latest-source claim is made.

SAF admission now has eleven of the pinned source's twenty-two function
identities. The other eleven and broader recursive storage products,
non-Count aggregate states, additional JSON/Dynamic/Variant/LC/Nested physical
profiles, fixed/cmrk/Compact transports, MV/projection writing and semantics,
and broad legacy-facade decomposition remain part of the unchanged full goal.
Memory/performance, including the original <=10 percent speed-gap target,
remains deferred and unmeasured. No push or full-goal completion is claimed.
