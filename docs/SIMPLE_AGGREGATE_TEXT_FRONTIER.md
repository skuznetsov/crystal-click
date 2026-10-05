# SimpleAggregateFunction text paired frontier — W168

## State and authority

Status: VERIFIED within the finite stored-value profile below; scoped hostile
verdict ROBUST. This is not complete SimpleAggregateFunction compatibility.
Baseline: `646d45a`. This slice extends paired stored values, not aggregate execution.
Remaining types and general MV/projection support precede performance work.
Risk: CAUTION (serialization admission, semantic dispatch and staged readback).
Rollback: revert the eventual atomic W168 commit, preserving unrelated work.
Root owns serial resource-guarded jobs, independent evidence checks and git.
Luna owns disjoint core, runtime and qualification files. No push, dependency,
production server, optimization or wider lifecycle change is authorized.

## Anchors and exact frontier

Comparison source: clean, unbuilt shallow checkout
`/Users/sergey/SrcArchives/clickhouse-2026-10-05-depth1`, commit
`e9b645ed83ad3c07b64f09fbd014e8f770d8691b`.
Executed stock is separately pinned to `26.10.1.1201`, build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`, binary SHA256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
`DataTypeCustomSimpleAggregateFunction.cpp:151-165` requires aggregate result
type to equal the child storage type after LowCardinality removal. Existing
numeric SAF admission does not admit text child carriers.

Implemented paired profile: canonical unary
non-parametric `any`, `anyLast`,
`min`, `max` with bare `String` or canonical `FixedString(N)` for the existing
library width range 1..65536, scalar or outer `Nullable`. Identity is
`{function, exact child carrier including fixed width, outer shape}`.
CH's own FixedString ceiling is 0xFFFFFF, not the library ceiling. Stock
column construction above width 256 requires
`allow_suspicious_fixed_string_types=1`; this is a setting, not an encoding law.
Native whole-part qualification pins Wide/LZ4, String WITH_SIZE_STREAM,
Nullable BASIC and propagated type serialization versions. SINGLE_STREAM,
sparse Nullable and Compact are not qualified by this slice.
Native whole-part qualification is finite: 32 profiles at String and widths
1, 3, 130, not every possible width. Boundary 65536 receives construction and
Crystal guard tests only unless a later executed certificate says otherwise.

Rejected or guard-only: other text functions, aliases, parameters, extra
arguments, inner Nullable/LowCardinality, recursive whole-part products,
Compact layouts, aggregate states and aggregation. Some are valid ClickHouse
types outside this certificate. Existing 118 numeric pairs / 236 outer-shape
profiles, legacy UInt64 defaults and inferred writer admission must not widen.
Ordinary String/FixedString accessors must refuse nominal SAF wrappers.
Variable String must not enter a numeric fixed-width codec accidentally.

Staged readback checks visible logical values, NULL positions, exact metadata,
marks and raw byte lengths. It is not a content-hash or byte-complete
canonicalization audit: `PartChecksums` reports `SizeChecked`, and the legal
N-byte nested payload beneath a NULL FixedString row is not a visible value.
Public readers must not reject stock parts merely because such a hidden slot
contains nonzero bytes. Independent raw-layout fixtures check that this writer
generates zero-filled NULL slots; these are distinct evidence boundaries.

## Owners and public paths

`BinarySimpleAggregateType` owns canonical function/child eligibility;
`SimpleAggregateColumnType` owns exact scalar/outer-Nullable identity.
The new 75-line `SimpleAggregateTextStoragePlan` owns the text stream/width/EOF
law in one file, and the private 235-line
`WidePartWriter::StagedSimpleAggregateTextPartValidator` owns staged logical
readback in another. Existing `PartSchemaMetadata` owns metadata rendering;
I/O, staging and publication remain with their prior owners.

`WidePartWriter.write_uint64_simple_aggregate_string_pair` and
`write_uint64_simple_aggregate_fixed_string_pair` have explicit nullable
counterparts. FixedString width is explicit before the function enum argument.
Direct readers, exact typed-batch accessors, table windows and offline column
`.values` retain the declared function/width/shape rather than inferring it from
a Crystal String. The reader/writer/table facades remain 16,017/25,377/7,015
lines: this adds cohesive owners, not completion of the architecture refactor.
Table callback validation is per mark, not whole-scan atomic publication.

## Plan and falsifiers

1. Execute runtime RED on unchanged production using existing APIs. A compiler
   error or an unexecuted assertion is not a behavioral RED signal.
2. Extend existing nominal/column-plan/descriptor owners. Reuse child logical,
   bulk and physical codecs with exact tags, budgets and fixed width preserved.
3. Pair public Wide reader/writer, staged semantic readback, table batches and
   windows, and offline column `.values`. Use cohesive owners, not one class
   per function/carrier pair. Preserve ordinary and inferred admission maps.
4. Run focused DEBUG and bounded affected RELEASE groups under the root-owned
   guard, isolated caches, single Crystal compiler thread and host linker.
5. Read a stock-authored Wide/LZ4 source; author 32 independent complete parts
   in Crystal; require actual stock ATTACH/CHECK, exact types and independent
   literal RowBinary full/middle/empty windows.
6. Attack binary NULs, empty strings, multibyte byte lengths, fixed padding,
   null maps/placeholders, wrong carrier/width/shape, primitive accessors,
   partial/empty windows and pre-publication refusals. Seed a semantic-guard
   bypass and require the unchanged tests to fail. CHECK-valid nominal/value
   mutants must fail the unchanged stock oracle.
7. Root reconciles raw logs, actual counts, input hashes and intended diff;
   hostile review precedes an exact-path local atomic commit after green DoD.

Executed DoD: new W168 core/wide/native specs; affected numeric SAF and ordinary text,
writer, table, catalog and staged readback tests; qualification wrapper;
formatter, Ruby/Bash syntax and `git diff --check`. Exact commands and counts
are recorded below. Each positive gate needs nonzero executed
examples, zero failures/errors/pending, actual child and guard exit 0, unchanged
inputs, and independent root reconciliation. Descriptor construction alone
cannot certify a complete part. Strongest failure: text storage silently loses
the function/width identity or routes through an ordinary/numeric accessor;
type, literal-byte and pre-publication negative controls discriminate it.

## Observed pre-implementation evidence

Root construction probe executes 90 stock declarations across nine existing
canonical functions, String/FixedString(1,3,130,65536) and both outer shapes:
40 accepted, 50 rejected, zero eligibility mismatches, child/guard exit 0.
Literal native types equal declarations for all accepted profiles. A first
candidate omitted the suspicious-width setting and stopped on ILLEGAL_COLUMN;
it is not counted as a type-law falsifier or positive gate.
Evidence root: `/private/tmp/crystal-click-w168.pP9nlr`.

## Behavioral controls

Baseline `core-red` executes five examples with three intended admission
assertion failures, zero errors/pending and child exit 1; the RED wrapper and
guard exit 0. All 303 source/spec/support/page inputs match before/after.
This authorizes the proposed production slice, not a positive certificate.
The initial gate authorizes paired core/runtime implementation and qualification;
it does not establish whole-part interoperability, architecture completion or
performance.
The first positive core candidate executes 58 examples with two failures in
historical W161 String-refusal expectations, zero errors/pending and child exit
1; all 315 inputs remain unchanged. These guards are updated only for the newly
admitted four functions; unsupported functions and wrapper refusals remain.

Hostile inspection found an unhandled variable-payload EOF constructor boundary.
The final behavioral RED (`wide-empty-red-final`) executes 22 examples with one
intended assertion failure, zero errors/pending, child exit 1 and RED wrapper /
guard exit 0. All 309 inputs match. Both nonzero-row all-empty scalar String and
all-NULL outer-Nullable String parts report `mark compressed offset exceeds data`.
Earlier compiler and fixture-path errors do not count as behavioral evidence.
The narrow repair uses the nominal text plan's `empty_payload_stream?` during
constructor mark parsing: only variable String's raw lane may have positive-row
EOF; sizes, null maps and FixedString lanes retain refusal. Tests also cover an
empty terminal mark after a nonempty mark, predicate exclusions and EOF zero.

`final-wide-debug` passes 24 examples, zero failures/errors/pending and actual
child/guard exit 0 with all 309 inputs unchanged. A temporary scalar staged-value
comparison bypass (`unless true`) then executes the unchanged W168 wide spec:
10 examples, one intended failure (`CorruptPartError` expected but nothing raised),
zero errors/pending, child exit 1 and RED wrapper/guard exit 0; 306 inputs match.
The validator is restored exactly, SHA256
`2336322c7c4143123401f57dd25d643b47833e12d2713c8b3cab1491aac5e497`.
`restored-scalar-staged-guard` passes the same 10 examples with zero
failures/errors/pending and child/guard exit 0; all 306 inputs match.
This discriminates the value comparison, not hashes or whole-scan atomicity.

## Final-source qualification and reproduction

Four disjoint groups per mode pass on the final production/spec state:

| Group | DEBUG examples | RELEASE examples | Unique specs per mode |
| --- | ---: | ---: | ---: |
| core | 58 | 58 | 10 |
| writers | 31 | 31 | 8 |
| consumers | 177 | 177 | 11 |
| wide | 24 | 24 | 4 |
| total | 290 | 290 | 33 |

All eight gates have zero failures/errors/pending, actual child/guard exit 0,
and matching before/after input hashes. These are affected regressions, not
a fresh full-inventory run. Exact spec membership is in the retained
`final-{core,writers,consumers,wide}-{debug,release}/result.json` records under
`/private/tmp/crystal-click-w168.pP9nlr`. Each group uses:

```sh
/opt/homebrew/bin/crystal spec <recorded-spec-roster> --single-module --threads 1 \
  --link-flags=-fuse-ld=ld --error-trace
# RELEASE additionally uses --release --no-debug.
```

The root-owned serial wrapper is `/private/tmp/crystal-click-w168.pP9nlr/run_gate.rb`
under `cogni-ml/scripts/run_safe.sh /usr/bin/ruby 600 12288`, with
`COGNI_RUN_SAFE_MIN_FREE_PCT=50`, isolated DEBUG/RELEASE Crystal caches,
`SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk` and
`TMPDIR=/private/tmp`. The strongest fallback is the separate stock oracle,
not a second self-roundtrip.

Final native evidence: `/private/tmp/crystal-click-w168.native-5-pP9nlr`.
Two actual native-fixture examples pass with zero failures/errors/pending.
Stock accepts all 32 independently library-authored complete parts through
ATTACH/CHECK, exact metadata, six rows/four marks and Wide layout. It also
authors a 33-column source (UInt64 key plus all profiles) read by Crystal.
Root separately recomputes 216 literal checks without importing the worker
oracle: metadata, 96 library full/middle/empty RowBinary windows, native
descriptors/windows, and three CHECK-valid controls. The controls change
only min-to-max metadata, one String byte, or a NULL position respectively;
the unchanged original oracle rejects all three. The metadata control changes
only `columns.txt`. Native actual child/outer guard exit 0, completion marker
present, all 307 gate inputs unchanged. Reproduce under the same serial guard:

```sh
W168_EXECUTE_AS_ROOT=YES CRYSTAL_BIN=/opt/homebrew/bin/crystal \
  RUBY_BIN=/usr/bin/ruby \
  /bin/bash scripts/check_simple_aggregate_w168.sh
```

The wrapper creates a fresh retained scratch root and checks the exact binary
version/build/SHA and separate source pin. Earlier Ruby-2.6, checksum-roster
and NULL-mutant fixture failures are retained but excluded; native-4 is an
earlier green candidate, not the final-source certificate.

Additional independently reconciled EOF evidence:
`/private/tmp/crystal-click-w168.eof-20261005-87263-1y5yuyv`.
Four complete `any/String` parts cover scalar all-empty and nullable all-NULL
three-row data, plus four-row trailing-empty/trailing-NULL marks after a
nonempty mark. Stock accepts each through ATTACH/CHECK and returns exact
types, rows/three marks and full/last-mark/empty RowBinary bytes.
Root recomputes 24 profile literal checks plus two runtime identity checks.
The raw String payload is zero bytes for the first two profiles and 28 bytes
for the latter two; their positive terminal marks respectively point to
compressed EOF 0 and 28 with decompressed offset 0. All 14 selected production
source hashes match before/after and current files. An initial scratch-only
absolute-require compiler failure is excluded. The committed W168 wide spec
also exercises these EOF behaviors through direct/table/offline readers.

Root final reconciliation matches raw summaries, disjoint rosters, source
hashes and native literals. The 341-input union is recorded in
`/private/tmp/crystal-click-w168.pP9nlr/final-inputs.json`, SHA256
`43912a1719b102dbd3c4481ea1edc410b5f968bbfc4edda88433cf00991ae7d1`;
`final-reconciled.json` SHA256 is
`23e505335e1a3158c1a27b975aeab80bf773a83050ad2cf62f99711b3e89f77f`.
Current hashes are rechecked before commit. The retained JSON is an index to
raw evidence, not proof by its field structure.

Scoped adversary result: ROBUST for exact function/child/shape dispatch,
visible staged semantics, whole-intersecting-mark byte budgets and this finite
stock profile. Static Luna review is correlated, not independent model
agreement; root executes and reconciles the runtime/stock/control evidence.
No all-width/layout, complete aggregation, MV/projection, facade-refactor,
speed or memory claim follows from these checks.

## Continuity and decay

Changed admission law, child codec, dispatch, staged selector, source, binary
or gate input reopens its affected certificate. Fresh source and stock runtime
are distinct provenance. Scratch logs, caches and datasets are not committed.
