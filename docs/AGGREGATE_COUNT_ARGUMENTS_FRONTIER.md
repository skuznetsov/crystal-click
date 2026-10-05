# Count argument-descriptor frontier (W178)

Status: VERIFIED within the declared ordinary Count profile (2026-10-05).
Baseline `67db3be`; the loaded W178 argument-descriptor policy and canonical
parser replace W175-W177's closed three-Count discriminator without adding
per-argument physical lanes. The 63-profile paired native component and the
same 582-example coverage pass in DEBUG and RELEASE, each partitioned into
four disjoint serial cohorts. A combined RELEASE process did not pass: its
compiler exceeded the unchanged memory guard. This certificate covers the
declared canonical metadata law with finite native witnesses, not every
recursive argument product. The overall types, MV/projections, modularization
and later performance goal remains active.

## Boundary under investigation

Count's zero-or-one argument is nominal descriptor metadata, not a physical
value child. Broaden this metadata domain across the library's existing
canonical scalar and compound descriptors only after establishing the actual
ClickHouse construction and state law. Preserve exact argument identity through
binary descriptors, scalar/envelope/bulk codecs, paired Wide/LZ4 parts, typed
table windows, candidate granules and owned offline column values.

The pinned source factory checks no parameters and arity at most one
(`AggregateFunctionCount.cpp:269-276`); ordinary Count serializes a UInt64
VarUInt (`AggregateFunctionCount.h:114-132`). These facts do not prove that
every argument selects the ordinary implementation. In particular, only-null
nullable arguments select a different nominal function, `nothingUInt64`, with
a strict zero-only serializer. Source and the executed stock diagnostic
distinguish bare `Nothing` (ordinary Count) from `Nullable(Nothing)` (canonical
`AggregateFunction(nothingUInt64, Nullable(Nothing))`):
`AggregateFunctionFactory.cpp:101-121`, `DataTypeNullable.cpp:37-40`,
`AggregateFunctionNull.cpp:100-114` and `AggregateFunctionNothing.h:106-123`.
Exclude this transformed identity from ordinary Count admission. A future
`nothingUInt64` descriptor would need its own paired qualification; a zero-only
guard on a nominal `count` descriptor would persist incompatible metadata.

Still rejected: other aggregate functions or combinators, parameters,
unqualified versions, invalid CH argument-type composition, arbitrary unknown
type names, outer Count composition/Nullable, borrowed JSON/shared or Dynamic
placement of Count, Count projection payloads, general aggregate execution,
arbitrary-schema parts and generic MV/projection execution/writes. An argument
descriptor containing a container is not permission for a container of Count
states. Canonical-name and descriptor budgets remain load-bearing.

## Risks and evidence-producing order

Risk: CAUTION (nominal descriptor and persistent-format admission). Rollback:
the exact local diff followed by an atomic commit after qualification; no push.
Root owns specification, the admission RED, loader, independent oracle,
compiler/native/Git jobs and final evidence. Luna owns bounded implementation
and source inventory; parallel workers must not edit overlapping paths.

Strongest failure: broad argument admission accepts a CH-invalid composition
or persists `count` where CH canonicalizes to `nothingUInt64`. Other risks
are losing argument identity, charging metadata as physical children, silently
widening borrowed placement, and failing to parse quoted or compound canonical
names consistently in offline DDL.

1. Execute a root-owned stock diagnostic across scalar, nullable and compound
   arguments. Record actual process exit/signal and independent literal state
   output, exact nominal names and special-only-null behavior. A construction
   success is not state compatibility proof.
2. Run `spec/aggregate_count_arguments_w178_admission_spec.cr` against the
   unchanged implementation. Require explicit missing-admission assertions,
   not compilation errors; retain the legacy Count control.
3. Seal the exact argument law from source and diagnostics before production
   widening. Inventory shared descriptor/value/bulk/physical visitors and all
   type-name consumers. Replace closed per-type routing with cohesive owners,
   preserve metadata budgets and physical leaf roles, and pair reader/writer
   and consumers in this slice.
4. Qualify the full declared argument-domain matrix, independent stock-authored
   and library-authored state/part witnesses, exact type retention, full/empty/
   nonzero windows and invalid-composition/nominal/transformed-identity guards. Run affected
   Count and shared type/consumer regressions serially in DEBUG and RELEASE.
5. Execute the strongest applicable seeded guard bypass, restore exact source,
   and rerun green before an atomic local commit. Perform hostile self-review;
   do not substitute CHECK TABLE or model agreement for literal value evidence.

Root commands use `crystal spec <recorded exact roster> --single-module
--threads 1 --link-flags=-fuse-ld=ld --error-trace`; RELEASE additionally uses
`--release --no-debug`. Use isolated caches and the existing 50%-free,
12-GB/600-s serial guard. Expected signal: nonzero example count, zero failures,
errors or pending, actual child/guard exit 0, immutable code inputs and exact
recorded rosters in both modes. Native processes are root-only and separately
pin version/build/hash. Fresh source snapshot
`29e0e201c786933171818f17c0fefc2bb11ec0a2` is in
`/Users/sergey/SrcArchives/clickhouse-2026-10-05-depth1-29e0e201` (clean, shallow,
unbuilt). The previous `095fae5865df96627496345209d6bbf2013121f3` snapshot is
preserved. Executed stock is separately pinned to `26.10.1.1201`, build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`, SHA256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.

## Observed source and stock boundary

Luna's read-only comparison, independently hash-checked by root, finds the same bytes in 16 decisive Count,
factory/Null/Nothing, LowCardinality, Decimal, AggregateFunction serialization
and binary type encoding files across the two snapshots. Root inspected the
current type-tag and transformed-function boundary independently. This is a
scoped source comparison, not a build or runtime certificate for fresh master.

The current binary type header explicitly reserves 0x33/0x35 after removing
timezone-bearing Time/Time64 forms. Thus append-only type admission is not an
invariant. JSON descriptors are versioned, and QBit has separate 0x36/0x37
tags; dedicated local QBit storage already supports stride, whereas its general
recursive `BinaryDataType` descriptor remains absent. Set/Function are internal
expression descriptors, not missing MergeTree column serializers.

Root executed `scripts/check_aggregate_count_arguments_w178.rb`, SHA256
`3f8e56296e1133cf4db06d5b5804b9eb5ddc9fc74b68bd9408a0ea653dbad59d`, under the
serial guard against the separately pinned executable above. Exact command:

```text
env COGNI_RUN_SAFE_MIN_FREE_PCT=50 RUN_SAFE_PASSTHROUGH_STDIO=1 TMPDIR=/private/tmp \
/bin/bash /Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh \
/usr/bin/ruby 600 12288 \
/Users/sergey/Projects/Crystal/crystal-click/scripts/check_aggregate_count_arguments_w178.rb \
/private/tmp/crystal-click-w178-arguments-stock-final.LDKOyJ
```

Observed signal: 75/75 profiles attempted, 66 CREATE admissions, 65 exact
ordinary Count lanes, one canonicalized `nothingUInt64` zero-only profile,
nine server construction refusals and zero runtime/system failures. Both build
pins pass; root reconciled all 409 process records and their input/stdout/
stderr hashes with no mismatches, signals or timeouts. Exit counts are
399 x 0, 1 x 117, 6 x 43, 1 x 50, 1 x 133 and 1 x 42; runner/guard exit 0.
Ordinary states use independent literal VarUInt bytes for
0/127/128/16384/UInt64::MAX, with exact RowBinary, finalized values and nominal
metadata checks. The special profile checks both metadata sources against the
actual `nothingUInt64` identity, five zero states and a separate nonzero-input
rejection. Its rejection is not an ordinary Count-state success.

The nine refusals include Time64 timezone forms, legacy Object('json'), invalid
LC/Nullable composition, parameters, excess arguments and outer Nullable.
CREATE success and the diagnostic's exit 0 do not admit those types locally.
This runner deliberately reports semantic mismatches rather than failing a
support gate. The witness uses stock-authored MergeTree tables and RowBinary;
it is not paired local complete Wide/LZ4 part qualification. Evidence lives in
the scratch path in the command; rerun if it is unavailable.

## Observed admission baseline

Root ran `w178-arguments-admission-red` before production changes: five
examples, four explicit missing-admission assertion failures, zero errors or
pending, and actual child/guard exit 1. UInt8, String, Nullable(String) and
Array(UInt64) fail at the public Count factory; the three legacy signatures
pass. The 963 code-input hashes and log hash reconcile without drift. Records
are in `/private/tmp/crystal-click-architecture-r1.shwDws`; the first sandboxed
launch aborted at the process-group guard before a test record existed and is
not counted as a compatibility RED. The successfully isolated launch used the
same serial guard and actual test assertions.

## Historical preparation certificate, not production admission

This section records the preparation at `67db3be`, before the W178 production
candidate below. Its unloaded-loader and closed-factory statements describe
that revision, not the current implementation diff awaiting RELEASE closure.

Two cohesive classes have separate files. Private
`BinaryAggregateCountArgumentNameReader` (362 lines) owns bounded recursive
grammar. `BinaryAggregateCountArgumentNameParser` (27) owns bounded canonical
render-back policy. Neither is required by the library's default loader; the
unit spec explicitly requires the parser. Existing production owners and the
three-signature Count factory are unchanged.

The utility recognizes the model's supported scalar/parameterized/container,
Enum, temporal, canonical Decimal, Dynamic and eligible SimpleAggregateFunction
argument names. Constructor validation, parse budgets and exact bounded
render-back reject invalid/noncanonical names. This is not a reversible binary
descriptor identity oracle: `Decimal(5, 2)` selects canonical Decimal32, not
another-width descriptor with the same displayed name. The spec explicitly
distinguishes them. `Nullable(Nothing)` remains a legal standalone parsed type,
not ordinary Count admission; aggregate factory normalization belongs to the
future Count admission owner. Unsupported JSON and AggregateFunction argument
names are refused by this utility.

DoD for this preparation: the one-spec roster
`spec/aggregate_count_arguments_w178_parser_spec.cr` under the serial Crystal
guard and flags above, in DEBUG and RELEASE; require nonzero examples, zero
failures/errors/pending, child/guard exit 0, immutable inputs, exact-path format
checking and `git diff --check`. Root observes five examples in each mode in
`w178-parser-separated-{debug,release}` records in the same architecture scratch
directory. Both log hashes and recorded code inputs reconcile without drift.
The moved reader body is byte-identical after declared deindent/class rename;
the retained policy method differs only in the helper name. Production loader
and facades remain unchanged. This is not the full-project suite or W178's
paired physical/consumer DoD.

Root's pre-fix negative-Enum falsifier failed exactly one assertion for
canonical Enum8 -128, with zero errors/pending and child/guard exit 1
(`w178-parser-enum-red`). Skipping separator whitespace before the sign fixes
that bug; the final tests also exercise -1 and Enum16 -32768/-1. An earlier
invalid sum/Decimal32 positive fixture produced a setup error and is not
counted as an admission RED; it was corrected to the admitted min/Decimal32
pair. Malformed/composition/quoted-name, noninjective Decimal and four resource
limit controls pass. Root's scoped adversary verdict is ROBUST for this finite
utility certificate, VULNERABLE as a whole-domain or stored Count identity
oracle. Luna's source review is supplementary and correlated, not independent
verification. No heap/RSS or performance claim is made.

Refresh this preparation certificate after either grammar/policy owner,
constructor, name renderer, limits, spec, source snapshot or runtime changes.
At that preparation checkpoint, production Count admission stayed closed and
the public admission RED was not staged. The candidate below now loads both
the parser and admission policy; those historical restrictions are not a
description of its working diff.

## W178 implementation law and ownership

The ordinary Count argument domain is the existing canonical `BinaryDataType`
model, as recognized by the bounded argument-name parser: primitives, supported
parameterized scalar/temporal/Enum/Interval/Decimal leaves, containers,
LowCardinality, Variant, Dynamic and eligible SimpleAggregateFunction pairs.
This is a recursive descriptor law, not a claim that every argument's own
physical value storage is qualified. Count remains one physical VarUInt lane.

`BinaryAggregateCountArgumentPolicy` owns admission in one file. It first
rejects Count-containing arguments and top-level `Nullable(Nothing)`, bounds
descriptor/name work, then requires exact parsed-descriptor equality with the
canonical name. Equality, not name equality alone, rejects noncanonical Decimal
storage widths recursively. Unknown JSON/QBit/custom/other AggregateFunction
descriptors remain outside this generic model. No-argument Count stays legal.

`BinaryAggregateCountType` retains an immutable optional argument descriptor;
equality/hash include that complete descriptor. The public `BinaryDataType`
factory and argument accessor delegate to this owner. The existing metadata
edge visitors remain budgeted; Count has zero generic value children. Name
budgeting uses a fixed Count shell plus the recursively measured argument, not
a per-signature switch. Binary encoding remains version 0, `count`, no
parameters and arity zero or one. The Wide storage-plan gateway parses the
same canonical argument grammar and checks the same policy, preserving the
exact descriptor through writer, reader, table and offline consumers.

Implementation ownership: Luna logical worker owns the nominal owner, new
policy, factory/accessor, name-budget owner and W175 test migration plus a new
W178 logical guard matrix. Luna inventory worker owns the Wide storage-plan
gateway and its focused tests. Luna oracle worker owns only new W178 consumer
and paired native-oracle files. Root owns the loader, specification, original
admission probe and all compiler/native/Git jobs. Shared paths are not assigned
to multiple workers. DoD and rollback are the serial qualification and atomic
local commit described above. The prepared public admission RED has already
failed four missing-admission assertions before these changes.

Strongest guard checks: transformed `nothingUInt64` identity, exact canonical
Decimal width including compound descendants, descriptor/state nominal
mismatch, recursive metadata depth/node/element/byte budgets, and unchanged
outer composition, borrowed placement and hidden-key/mark-axis refusals.

## Executed Count-root budget falsifier

The first candidate measured the argument as a standalone depth-1 tree. Luna's
hostile review identified `Array` nested 63 times around UInt8: the argument
passes the default depth-64 budget, but its Count metadata edge makes the
complete descriptor depth 65. Root reproduced this with unchanged assertions
before the repair in `w178-count-root-budget-red`: six examples, one explicit
admission failure, zero errors/pending, actual child/guard exit 1 and no changed
inputs. The exact one-spec roster is
`spec/aggregate_count_arguments_w178_core_spec.cr`, using the serial guard and
flags above. Root reconciles the output log hash and record in the architecture
scratch directory. Root-node, metadata-edge and full Count-shell name work must
be charged before argument rendering; standalone argument budgets are not the
complete Count descriptor budget.

Root also reproduced the no-argument branch's early-return bypass with
`w178-count-noarg-budget-red`: eight examples, one admission assertion failure,
zero errors/pending, actual child/guard exit 1 and immutable inputs. Limits with
zero depth/nodes or fewer than 48 name-work bytes must reject even no-argument
Count; depth 1, one node, zero metadata edges and exactly 48 bytes admit it.
The repaired candidate's focused library gate passes 95 examples, including
63 distinct canonical argument profiles. An earlier 94-example run had 63
fixture-path setup errors, not semantic admission failures or native proof;
those errors are not counted as a compatibility RED or successful DoD.

After exact-path mechanical formatting, root temporarily weakened full
descriptor equality to canonical-name equality. Unchanged core and storage-plan
Decimal-width controls fail in `w178-count-descriptor-identity-bypass-red`:
13 examples, two assertion failures, zero errors/pending, actual child/guard
exit 1 and immutable inputs. Root restores the exact formatted policy SHA256
`f75999d19158cbc71930d4d9b13d64d54050b3b4b7719c19a546c5719972b846`.
This establishes sensitivity to a name-alias guard bypass; final restored
DEBUG/RELEASE regressions and native paired qualification remain required.

## Qualification components and scope

The frozen Ruby oracle is
`scripts/recheck_aggregate_count_arguments_w178.rb`, SHA256
`ff45000e922dc80af29c8c5b2f3a3b879468c111111591039bbe12cbf503f45b`.
It is only the ClickHouse component of the paired DoD: 63 canonical argument
names are created, checked and exported as stock-authored Wide parts, and 63
library-authored parts are attached and checked in ClickHouse. The separate
Crystal consumer spec must read all 63 exported parts with
`W178_STOCK_ROOT` enabled before claiming stock-to-library compatibility.
Both components are mandatory; script exit 0 alone is insufficient.

The native checks require exact `system.columns` and `toTypeName` output,
literal RowBinary bytes for full/middle/empty selections, finalized counts,
CHECK success and one active Wide part with five rows and four marks.
The 63 profiles cover 21 primitive and 42 parameterized/compound canonical
arguments; this is neither an exhaustive recursive cross-product nor alias
spelling qualification. Expected state bytes are independent literals:
`00`, `7f`, `8001`, `808001`, `ffffffffffffffffff01`; keys are
7/13/22/31/50. The 128-to-129 check is only an in-memory expected-literal
separation control, not a newly executed corrupt/re-read physical fixture.
The seeded descriptor-equality bypass above is the executed W178 production
guard falsifier.

Root separately passes the final restored 63-spec affected regression roster
in DEBUG: 456 examples, zero failures/errors/pending, child/guard exit 0,
970 immutable code inputs and reconciled log hash in
`w178-restored-regressions-debug`. The enabled fresh library-part run,
`w178-restored-library-enabled-debug`, passes 95 examples across seven specs,
including all 63 writer/reader/table/offline profiles. The earlier
`w178-restored-library-debug` run accidentally used the wrong environment key
and executed only 32 static examples; it is not counted as a matrix gate.
Use `W178_LIBRARY_PART_ROOT`, not `W178_LIBRARY_ROOT`, for part generation.

The first native component attempt recorded all 126 cases and 1,325 successful
invocations with reconciled input/stdout/stderr hashes, but failed while
serializing its final report: `force_encoding` tried to mutate the frozen
version constant. Guard exit 1 and no summary mean this is not a successful
DoD certificate. Duplicating constants and observed pin strings before an
encoding change fixes that reporting bug; root's non-native preflight/report
probe succeeds with frozen pin strings and writes no files. The repaired
native component is rerun into fresh disjoint roots below.

The report-repair native component attempt exits 0 under the serial guard
at script SHA256
`26926abcd024586de4e4fea7b218d231e7769c4bb75c94679b207bdbe5b98100`.
All 63 stock
creation/check/export and 63 library attach/check cases pass, with zero gate
failures or fatal errors. All 1,325 actual invocation statuses are exit 0 with
no signals/timeouts. Root independently reconciles every process record and
input/stdout/stderr byte/hash pair, exact full/middle/empty literals and both
version/build/hash pins. This precedes the canonical-directory correction
below and is not the final paired certificate. The evidence root is
`/private/tmp/crystal-click-w178-paired-native-final.tvNZHH`; its summary SHA256
is `cad07632b33d12124491e78d02b836e38720a5c55c5641fcd775a5c33fd73071`.
The library input is
`/private/tmp/crystal-click-w178-paired-library-restored.Ru64Az`; exported
stock parts are in
`/private/tmp/crystal-click-w178-paired-stock-final.xeFbXu`.
At that checkpoint, the separate Crystal stock-part consumer gate was still
required; the canonical replay and bounded consumer closure are recorded below.

The first enabled 64-spec DEBUG run executes 582 examples with zero assertion
failures and 63 stock-consumer setup errors: exported directories named
`part-<profile>` are rejected by the table's canonical MergeTree part-name
guard. This is a fixture contract defect, not evidence of state compatibility
or a production reason to weaken the guard. The repaired export/consumer
layout is `<stock root>/part-<profile>/all_1_1_0`, matching the library layout.
Native and consumer gates were replayed after this correction as recorded
below; that failed run is not the final DoD certificate.

The canonical-directory native replay uses the frozen script SHA256 above and
exits 0 under the serial guard. All 126 cases qualify; root reconciles all
1,325 recorded process statuses, input/stdout/stderr byte/hash pairs, independent
full/middle/empty RowBinary and finalized-count literals, both runtime pins and
all exported canonical part paths. No signal, timeout, gate failure or fatal
error is recorded. Evidence:
`/private/tmp/crystal-click-w178-canonical-native.vGB4C9/summary.json`, SHA256
`813b333a88a3da2684161e7bcf3e26b23e2653e6e94c0110a8efb23229ab9cae`.
The library input remains
`/private/tmp/crystal-click-w178-paired-library-restored.Ru64Az`; stock output
is `/private/tmp/crystal-click-w178-canonical-stock.AAovER`, with 63 canonical
inner `all_1_1_0` directories. This is the final native component, not by itself
the separate Crystal stock-consumer certificate.

## Resource-limited full-roster attempt

`w178-canonical-final-debug` passes the exact 64-spec roster below: 582
examples, zero failures/errors/pending, actual child/guard exit 0. Root
reconciles all 970 code-input hashes and the log SHA256
`ff6dbc35465e0f1bcea7e8f2b22cc76b73491fec6378439826311eb8258b316d`.
All 63 generated library part directory/file inventories and bytes match the
native-qualified input; all 63 exported stock part trees still match the
native records.

The corresponding full-roster RELEASE attempt is killed by the unchanged
12-GB process-tree guard: 12,593,520 KB exceeds 12,288 MB after approximately
219 seconds according to the guard. Its log is empty and no test summary or
gate record exists. This is a compiler-resource failure, not an assertion RED,
reader RSS measurement or successful DoD. Do not widen the memory allowance or
count the interrupted attempt as RELEASE coverage. The successful replay partitions
the same roster into disjoint bounded cohorts, serially in both modes, with
their union and aggregate example count checked against this DEBUG baseline.

## Paired replay coverage roster

The affected coverage roster below has 64 specs. Run it in both DEBUG and RELEASE
with all four fixture switches explicitly enabled:

```text
W176_STOCK_ROOT=/private/tmp/crystal-click-w176-release-native.KH635o
W177_STOCK_ROOT=/private/tmp/crystal-click-w176-release-native.KH635o
W178_STOCK_ROOT=<63-part stock output from the successful W178 native run>
W178_LIBRARY_PART_ROOT=<new empty /private/tmp directory for this mode>
```

The earlier W176/W177 fixture is only a historical three-profile regression
input, not the new W178 native certificate. DEBUG and RELEASE must generate
their own 63 library parts and consume all 63 freshly exported stock parts.
Expected aggregate signal per mode: 582 examples, zero failures/errors/pending,
the same exact 64-spec union, every cohort's child/guard exit 0 and immutable
code inputs. Compare complete generated
part file inventories/bytes against the library root qualified in ClickHouse;
otherwise requalify a differing mode's parts natively before closing.

Use the unchanged serial flags/guard above with the following disjoint cohorts
in both modes. Root verifies their exact union against the 64-spec full DEBUG
record; cohort example forecasts were 207/106/120/149 before execution and
match the observations recorded below.
Keep `W176_PART_ROOT` unset and use a fresh empty library output root per run.

### C1: Count capability and controls (14 specs)

```text
spec/aggregate_count_consumers_w177_admission_spec.cr
spec/aggregate_count_consumers_w177_oracle_spec.cr
spec/aggregate_count_table_w177_spec.cr
spec/aggregate_count_offline_w177_spec.cr
spec/aggregate_count_w176_admission_spec.cr
spec/aggregate_count_w176_reader_spec.cr
spec/aggregate_count_w176_writer_spec.cr
spec/aggregate_count_w175_admission_red_spec.cr
spec/aggregate_count_w175_core_spec.cr
spec/aggregate_count_arguments_w178_admission_spec.cr
spec/aggregate_count_arguments_w178_core_spec.cr
spec/aggregate_count_arguments_w178_parser_spec.cr
spec/aggregate_count_arguments_w178_plan_spec.cr
spec/aggregate_count_arguments_w178_consumers_spec.cr
```

### C2: Physical/table/projection consumers (16 specs)

```text
spec/part_checksums_spec.cr
spec/wide_part_spec.cr
spec/multicolumn_table_scan_spec.cr
spec/lazy_window_reader_spec.cr
spec/wide_part_table_projection_w87_spec.cr
spec/wide_part_table_w53_spec.cr
spec/wide_part_table_w54_spec.cr
spec/wide_part_table_w95_tuple_spec.cr
spec/simple_aggregate_w164_wide_spec.cr
spec/simple_aggregate_w168_wide_spec.cr
spec/wide_part_simple_aggregate_decimal_w169_spec.cr
spec/wide_part_simple_aggregate_temporal_w170_spec.cr
spec/wide_flattened_nested_consumers_w174_spec.cr
spec/wide_flattened_nested_consumers_w174_guards_spec.cr
spec/object_table_w130_root_spec.cr
spec/object_offline_table_w130_spec.cr
```

### C3: Offline/catalog/Object consumers (10 specs)

```text
spec/offline_catalog_spec.cr
spec/offline_catalog_w27_spec.cr
spec/offline_catalog_w28_spec.cr
spec/offline_catalog_projection_w87_spec.cr
spec/offline_tui_page_source_spec.cr
spec/offline_catalog_w95_tuple_values_spec.cr
spec/object_shared_map_w118_spec.cr
spec/object_documents_w123_spec.cr
spec/object_documents_w123_root_spec.cr
spec/object_documents_w123_adversary_spec.cr
```

### C4: Binary descriptor/value/bulk cores (24 specs)

```text
spec/binary_value_codec_w117_spec.cr
spec/binary_scalar_types_w119_spec.cr
spec/binary_parameter_owners_w119_spec.cr
spec/binary_bulk_w122_spec.cr
spec/bulk_nominal_w122_spec.cr
spec/bulk_budget_w122_adversary_spec.cr
spec/bulk_string_size_w122_spec.cr
spec/simple_aggregate_w161_core_spec.cr
spec/simple_aggregate_w163_core_spec.cr
spec/simple_aggregate_w164_core_spec.cr
spec/simple_aggregate_w168_core_spec.cr
spec/binary_nested_w172_spec.cr
spec/binary_nested_w172_guards_spec.cr
spec/binary_low_cardinality_w141_spec.cr
spec/binary_low_cardinality_bulk_w143_spec.cr
spec/dynamic_values_w122_spec.cr
spec/dynamic_values_w122_adversary_spec.cr
spec/binary_dynamic_bulk_plan_w154_spec.cr
spec/binary_dynamic_bulk_plan_w154_adversary_spec.cr
spec/dynamic_structure_roster_w154_red_spec.cr
spec/binary_bulk_physical_prefix_w151_spec.cr
spec/object_variant_prefix_w151_adversary_spec.cr
spec/object_variant_consumers_w151_spec.cr
spec/binary_dynamic_value_w153_spec.cr
```

## Observed bounded replay and closure

All eight guarded runs finish with actual child/guard exit 0, zero failures,
errors or pending. Every record retains the same 970 immutable code-input
hashes as the successful combined DEBUG baseline. Root independently checks
each exact roster, record/log hashes and the disjoint 64-spec union in each
mode; both aggregate counts are 582. This is partitioned RELEASE coverage,
not a successful combined RELEASE process or the complete repository suite.

| Cohort | Specs | DEBUG examples | RELEASE examples |
| --- | ---: | ---: | ---: |
| C1 | 14 | 207 | 207 |
| C2 | 16 | 106 | 106 |
| C3 | 10 | 120 | 120 |
| C4 | 24 | 149 | 149 |

Records and logs live in `/private/tmp/crystal-click-architecture-r1.shwDws`
under the exact labels `w178-cohort-c{1,2,3,4}-{debug,release}`. Observed log
SHA256 values, in C1 through C4 order:

```text
DEBUG
f9d3c13427cde01e70748b68bff98f2b82a1d1e39f7ed2664e4e96ea064d8934
591240ad9a7b6a7be847eb7b6d6a102b29ad864170c2b5549fa5b3e5ee258d0c
3bf014c39faf40a1fca604fb565269dc56fe3cee33d3e7d96f5b23c094956e9a
173cc1977366a817696ed48c7a25b86a2444b90d17470ec30fbd9393d03d8435
RELEASE
d99fb04e8ffa6255910d9c4b4b455e90619e5596d0ffd7f185d9c897f8d95f86
b62732d8ffc179cd5935232782d1499b9c24535d77b9a3438259beee7166ec31
e20a6e7421c7aab07bc0c3913ae91ccc55665248c40880ac35b74f4981982a07
b2a23f97f705c54a6a03876da65e669a6c0aed4c30c4ba5d2896b2376ae3bc0d
```

Each mode consumes all 63 canonical stock-authored parts and generates its
own 63 library parts. Root compares complete directory/file inventories and
contents from `/private/tmp/crystal-click-w178-cohort-debug.G8Y9tw` and
`/private/tmp/crystal-click-w178-cohort-release.dxXtcS` with the 63 library
inputs already qualified by the canonical native run. Every part is
byte-identical. Root also reconciles all 63 stock and 63 native-input part
tree hashes. The existing native certificate therefore applies to these
exact generated bytes; this is not two additional native runs.

Scoped hostile-review verdict: ROBUST for ordinary Count's declared canonical
argument metadata and the finite paired logical/Wide/table/offline witnesses.
The executed descriptor-equality bypass fails two unchanged negative
assertions; exact policy restoration and all final gates pass. Luna's source
review is correlated support, not independent runtime replication. Root's
literal oracle, process/input/hash reconciliation and generated-part byte
comparison are the independent checks. Neither finite matrix coverage nor
the metadata grammar proves all recursive physical type products, other
aggregate states, general MV/projections, lower RSS or faster execution.

## Continuation

Confirmed return pointer: the qualified W178 ordinary Count checkpoint, based
on W177's paired consumers and parser preparation at `67db3be`. Generic parsing
of `Nullable(Nothing)` is still not ordinary Count identity admission;
`nothingUInt64` is separately unsupported. Next type boundaries are the general
JSON/QBit descriptors, other aggregate states and remaining recursive/layout
products, each requiring paired reader/writer and native witnesses before
admission. General MV/projections and larger responsibility-level facade
extractions remain open; performance work remains deferred.

Refresh this scoped certificate after owner/visitor, canonical-name,
type-composition, runtime or fixture changes. If scratch evidence is absent,
rerun the recorded native and enabled cohort commands before relying on the
certificate. Existing local implementation/Luna/atomic-commit authority applies;
no remote push or external data mutation is authorized.
