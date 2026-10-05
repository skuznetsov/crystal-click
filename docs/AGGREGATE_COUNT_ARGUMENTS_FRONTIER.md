# Count argument-descriptor frontier (W178)

Status: IN_PROGRESS. Baseline `3a727d9`; W175-W177's three Count signatures
remain admitted. The next capability is a reusable argument-descriptor law,
not a separate implementation for each argument type. The overall types,
MV/projections and later performance goal remains active.

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

## Qualified preparation, not production admission

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
Keep production Count admission closed until the paired DoD above passes. The
untracked public admission RED remains a future capability probe, not a green
test or a file staged with this preparation.

## Continuation

Confirmed return pointer: W177 paired Count consumers at `3a727d9`. The stock
argument/state diagnostic and assertion-based public RED are established.
Next discriminator: pair the ordinary Count argument domain across existing production owners and
consumers. The parser candidate is unloaded; its generic parsing of
`Nullable(Nothing)` is not Count identity admission.
Local argument breadth remains unqualified; `nothingUInt64` is separately
unsupported. Do not infer
generic AggregateFunction compatibility, all-type completion, lower memory
usage or performance from this slice. Refresh evidence after owner/visitor,
canonical-name, type-composition, runtime or fixture changes. Existing local
implementation/Luna/atomic-commit authority applies; no remote push or external
data mutation is authorized.
