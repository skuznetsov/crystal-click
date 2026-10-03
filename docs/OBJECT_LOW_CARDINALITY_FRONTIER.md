# Object LowCardinality Frontier (W141)

Status: VERIFIED for the bounded nominal row-kernel prerequisite and executed
gates below; IN_PROGRESS for Object physical support. Baseline: `36720ba`
(W140), 2026-10-03. No new Object LowCardinality declaration or physical profile
is admitted.

## Problem and reference boundary

The paired Object path admits recursively bounded Array, String-key Map,
Tuple and legal Nullable fields, but lacks general LowCardinality descriptors
and bulk roles. Existing standalone LowCardinality(String) part support does
not qualify LowCardinality within Object typed lanes. Logical RowBinary alone
cannot certify persisted dictionary/index state, prefix bytes or mark axes.

Source reference: the separate unbuilt shallow ClickHouse checkout at
`/Users/sergey/SrcArchives/clickhouse-2026-10-03-depth1-9007d227`, revision
`9007d227b64a3f8b667fc5258ceb2923f3cf477d`.
Runtime probes separately pin the existing ClickHouse 26.10.1.1201 executable
at `/private/tmp/crystal-click-w112-runtime.u0Jn1f/clickhouse`; it is not built
from that checkout. Source/runtime differences remain explicit.

## Proposed capability and design laws

- Add a nominal LowCardinality node and value corridor to the existing general
  binary type/value and physical-plan owners, rather than one class per
  LowCardinality leaf or container combination.
- Preserve exact nested type identity, including Nullable and all parameters.
  Do not silently erase LowCardinality because row-wise values share a carrier.
- Establish ClickHouse factory and JSON-extraction constraints independently;
  neither implies physical serialization support.
- Resolve dictionary/index stream identities, version/state prefix and mark
  scheduling from source and native parts before widening physical admission.
- Bound descriptor, dictionary, row, byte and recursive-cell work before
  proportional allocations; malformed input must not mutate shared state.
- New cohesive production owners have separate files. Existing standalone
  LowCardinality behavior and facades must not grow per-combination branches.

Declared Variant/Dynamic, unsupported LowCardinality nested types, additional
Object/shared layouts and whole-Object projection children remain rejected.
General MV/projection compatibility remains part of the broad objective;
performance and memory optimization stay parked until compatibility is done.
No finite witness matrix is an exhaustive product or current-master certificate.

## Execution order and falsifiers

Risk: CAUTION (persistent schema and binary formats). Rollback: the clean
`36720ba` baseline and one scoped local commit after executed gates; no push.
Likeliest failure: logical values look correct while dictionary state, null
reservation, index width or flattened mark axes disagree with ClickHouse.

1. Inventory current descriptors/codecs/Object/public consumers and current
   ClickHouse constraints. Capture native independent literal JSON fixtures,
   exact nominal types, actual stream inventory and actual CHECK identities.
2. Record a failing library test for each new representation/transport corridor
   before production changes. Keep cause-specific illegal-shape controls.
3. Implement shared nominal and bulk owners with bounded admission. Review
   changed consumers and reject unsupported profiles before publication or the
   first public callback.
4. Root executes serial focused DEBUG and affected RELEASE specs, a frozen
   complete non-release spec inventory, bidirectional native/library parts,
   independent bytes/type/CHECK checks and unchanged affected regressions.
5. Hostile self-review attacks forged/mutated metadata, dictionary/index
   corruption, null/default/empty rows, later marks/windows, cumulative limits,
   same-carrier nominal drift and false-positive comparators. Fix or narrow
   evidence claims, not the user's broad objective.

Resource protocol: root owns compiler/native execution under
`/Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh`, min-free 50%,
32768 MiB process-tree ceiling, explicit timeout, MacOSX26.5 SDK, isolated
Crystal cache and single-module/single-thread Darwin linker flags.
Concrete selections, commands, source seals and observed signals are added
after the source/inventory discriminator; unexecuted plans are not evidence.

### Required kernel prerequisite

Source discriminator: `DataTypesBinaryEncoding.cpp:449-454` emits LC tag
`0x26` followed by the nested descriptor; `SerializationLowCardinality.cpp:
799-815` delegates per-value binary serialization to the nested serializer.
`SerializationObject.cpp:917` delegates typed-path **bulk** serialization to
that type's bulk serializer. Therefore row-wise LC transport is a necessary
prerequisite, not a substitute for dictionary/index bulk integration.

The first implementation transition is limited to the nominal descriptor and
owned nested row-value kernel. It must leave Object and BinaryBulk admission
rejected. Consumers to inspect before the change: BinaryDataType construction,
Nullable/Map guards and equality/name rendering; BinaryDataTypeCodec read/write;
BinaryValue construction/validation/ownership; BinaryValueCodec decode/encode
preflight and value accounting. A shared LC type-policy owner centralizes legal
nested-type selection instead of copying it into each codec.

The RED probe is `spec/binary_low_cardinality_w141_spec.cr` on unchanged
production. It uses literal native `0x26` descriptors and nested payloads so
failure distinguishes missing behavior rather than an undefined new API.
Root runs it via the isolated runner at
`/private/tmp/crystal-click-w141.yzOYgD/run_specs.sh`, under the common resource
guard, and records the first observed RED before authorizing production edits.
Observed RED: 6 examples, 1 failure and 5 errors, exit 1, on unchanged
production. The valid LC tag was recognized but unadmitted. An earlier launch
had a missing shell pipe in the temporary runner and exited before tests;
that runner error is not counted as behavioral RED.
Kernel DoD: the same focused file passes DEBUG/RELEASE; existing binary/type/
bulk/Object/standalone LC regressions and the complete frozen spec inventory
pass; pinned native binary type+row witnesses agree in both directions;
Object/bulk refusal and illegal-child guards remain observed. Physical LC part
qualification remains the next required transition, not a waived requirement.

Native format context discriminator (root observed, guard exit 0):
`toTypeName(x)` for `CAST('λ雪', 'LowCardinality(String)')` is
`LowCardinality(String)`, and RowBinary value bytes are `05CEBBE99BAA`.
With binary type headers enabled, `formatRow('RowBinaryWithNamesAndTypes', x)`
returns `0101781505CEBBE99BAA`: its header carries String tag `0x15`, not LC
tag `0x26`. This output corridor erases LC's representation. Do not treat that
producer as an LC descriptor witness merely because SQL retains the LC name.
The descriptor's source encoding, a native literal-descriptor consumer and a
native producer capable of retaining LC must be qualified separately.

Root pivot, same runtime/settings/store, guard exit 0: direct
`SELECT CAST('λ雪', 'LowCardinality(String)') AS x FORMAT
RowBinaryWithNamesAndTypes` emits `010178261505CEBBE99BAA`. Direct output
preserves LC tag `0x26` plus String tag `0x15`; the SQL `formatRow` helper
corridor does not. The rejected inference is that the helper's type-erased
header proves the direct format also loses nominal LC. Scope the discriminator
to these two executed corridors; neither qualifies persisted bulk streams.

The first sandbox-native launch terminated before SQL with guard exit 75
because `ps` was denied. The same scoped temporary-data probe was rerun with
expanded local execution permission, leaving the resource guard unchanged.

Native discovery, guard exit 0, is retained at
`/private/tmp/crystal-click-object-low-cardinality-w141.JEtCBe`: nine independent
tables admit LC String, Nullable(String), Int64, Date, IPv4, FixedString(3),
Array(LC String), Map(String, LC String) and named Tuple(LC String, UInt32).
Each has nine literal rows, four-row granules, exact nominal/value checks,
stream inventory and an actual successful CHECK row for its active part.
Four cause-specific controls reject LC(Array), Nullable(LC), LC(LC) and
LC(Decimal). This is native discovery, not library persisted-part qualification.
The earlier partial run at `...w141.pczVi8` stopped at Date with error 455;
Date and IPv4 require the suspicious-LC opt-in. Nullable certificate rows
also require explicit ordinal ordering rather than unordered UNION ALL.

Consumer audit found that admitting the general row codec would otherwise
widen six borrowed-envelope call sites in ObjectDocumentSharedCodec,
ObjectSharedMapCodec and DynamicValueCodec. The row-kernel transition keeps
those persisted corridors rejected for recursively LC-containing descriptors.
The guard runs after bounded descriptor traversal and before value transport;
public logical row entry points admit LC independently. BinaryTypeNameBudget
must account for the LC prefix and nested name, not its generic leaf fallback.

### Source eligibility is not physical admission

The source constructor strips one immediate Nullable and asks the nested
type's `canBeInsideLowCardinality()` (`DataTypeLowCardinality.cpp:30-40`).
The kernel policy intersects that source eligibility with the leaf descriptors
already represented by BinaryDataType: integer and floating-point widths,
String/FixedString, Date/Date32/DateTime/Time, UUID/IP, Bool and BFloat16.
Interval is source-eligible (`DataTypeInterval.h:15`,
`DataTypeLowCardinality.cpp:94-95`) and has binary tag `0x22`, but this general
descriptor kernel does not represent it yet. Its omission is a remaining
implementation capability, not a ClickHouse prohibition.

Enum, Decimal, DateTime64/Time64, composites and nested LC are not legal LC
children. Legal Array/Tuple/Map containers can instead contain LC leaves;
LC(Nullable(T)) and Nullable(LC(T)) are not equivalent. The latter is refused,
as are Nullable and LC(Nullable) Map keys. Constructor eligibility, the DDL
suspicious-type opt-in, JSON extraction and persisted layout are separate
boundaries. BFloat16 has a source-eligible LC constructor and literal native
row bytes, but no scalar JSONExtractTree case; Object admission stays closed.

The source's actual bulk protocol enumerates DictionaryKeys and
DictionaryIndexes (`SerializationLowCardinality.cpp:72-100`), writes a key
stream version 1 (`:271-289`) and carries a little-endian UInt64 index
descriptor per granule (`:124-192`). Its width and global/additional/update
flags govern dictionary state. Additional keys, row count and compact indexes
are framed separately (`:596-626`), not as repeated logical row envelopes.
Shared dictionaries can span marks; rewind/state validation (`:331-400`) and
nullable dictionary reconstruction (`:673-745`) are prerequisites for the
next physical transition. The root inspected enumeration, index flags,
bulk framing and Object's typed-bulk delegation directly in the pinned source.

### Adversarial physical-planner correction

The newly represented LC descriptor exposed a second name bound in
ObjectDocumentPhysicalPlan. Its generic 16-byte leaf fallback underestimated
LC wrapper names; the old planner rendered the name before its post-render
refusal. Root observed a focused RED: 15 examples, one failure, no errors,
with the old `Dynamic SQL display name exceeded its metadata preflight bound`
diagnostic instead of the required early physical guard.

The existing bounded recursive descriptor preflight now refuses LC, including
Array(LC(String)) and LC(Nullable(DateTime('America/Argentina/Buenos_Aires'))),
before **this physical planner's** display-name bound/render step. It does not
implement LC dictionaries. DynamicStructure already materializes canonical
names in its constructor; this guard is not a global pre-allocation guarantee.
ColumnWriter and FileReader build this physical plan before bulk lane handling;
the direct logical Object/Dynamic codec routes still meet BinaryBulk refusal.

### Executed row-kernel oracle

Final native discovery and row oracle are retained at
`/private/tmp/crystal-click-object-low-cardinality-w141.tmcuJP`.
The native probe again passes nine admitted tables with actual CHECK and four
cause-specific illegal-shape controls. Root executes the two-way logical oracle
with binary type/name header checks: nine direct native certificates decode
against independent literal descriptors/payloads, and nine library-owned
factory-derived descriptor/value vectors are accepted by pinned stock input.
All nine LC-tag-removal controls fail at ClickHouse's specific type-header
check; the mutated column name fails at its specific unknown-header-field
check with `input_format_skip_unknown_fields=0`.

Root independently verifies the nine native certificates (116 bytes) using
Ruby/manual integer, calendar and UTF-8 byte construction without Crystal
codecs. This finite row matrix is not every eligible leaf or persisted part
qualification. Bool and BFloat16 have additional literal native row witnesses
and focused logical tests, not Object BFloat16 admission.

The first oracle execution at `...w141.JEtCBe/binary-oracle` passed eight cells
and then failed its TSVRaw comparator: named Tuple's native display name is
multiline. A root native discriminator confirmed exact type-name hex and the
correct row payload. The final oracle hex-encodes names and compares the
Tuple's literal multiline bytes, without whitespace normalization. Its earlier
disabled-entrypoint flag and incorrect name-error predicate were caught by
root source review before execution. Exit 0 alone is not the oracle signal:
the final run must report all nine cells and descriptor/name negative controls.

Executed commands (with the common resource guard and SDK environment):

```sh
W141_EXECUTE_AS_ROOT=YES scripts/probe_object_low_cardinality_w141.sh
W141_EXECUTE_AS_ROOT=YES \
  W141_PROBE_ROOT=/private/tmp/crystal-click-object-low-cardinality-w141.tmcuJP \
  scripts/check_binary_low_cardinality_w141.sh
ruby /private/tmp/crystal-click-w141.yzOYgD/verify_native_bytes.rb \
  /private/tmp/crystal-click-object-low-cardinality-w141.tmcuJP
```

Each oracle requires a new retained output directory; the shown completed root
cannot be reused to overwrite evidence. Runtime SHA-256 remains
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`,
build `d9bcb5ab007f0f6299f7f973f2642245bab3d028`, separately from the unbuilt
source reference. Root executed the final focused DEBUG: 98 examples in
11 files, and affected RELEASE: 206 examples in 27 files, no failures/errors.
The final frozen complete inventory passed 2,332 examples in 368 unique spec
files, executed serially in 16 disjoint non-release groups, with no failures,
errors or pending examples. This is not a combined-process or full-RELEASE
certificate. The runner verifies the unique file count and completed group
coverage before its final PASS; root independently summed the 16 results.

Final gate logs are retained under `/private/tmp/crystal-click-w141.yzOYgD`:
`focused-debug-frozen.log`, `focused-release-frozen.log`,
`full-final-inventory.log` and `full-final-spec-inventory.txt`. Root observed
guard exit 0 for the full gate after approximately 379 seconds:

```sh
env COGNI_RUN_SAFE_MIN_FREE_PCT=50 \
  /bin/bash /Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh \
  /bin/bash 1800 32768 \
  /private/tmp/crystal-click-w141.yzOYgD/run_specs.sh full-final 368
```

The W141 atomic commit on baseline `36720ba` is the source lineage for these
gates. All 13 changed production/spec/oracle files remained unchanged between
the final focused gates, native oracle, complete inventory and root's
pre-commit SHA-256 recheck. Representative sealed files:

| File | SHA-256 |
| --- | --- |
| `src/crystal_click/binary_low_cardinality_type_policy.cr` | `b24591c88a9e0c8117ca2182384de052cc062b6178e6bd52bb7b80cd81e52a0f` |
| `src/crystal_click/object_document_physical_plan.cr` | `907aca54962f608be22e1faa4a5855c00f040fa285a6f5a85ed0ac3a39ba682d` |
| `spec/binary_low_cardinality_w141_spec.cr` | `6657ae3fc36e93b0d56aa348c804351bbdc2ebc07d8afad12f63780fbe7dd78a` |

Refresh these gates after changes to descriptors, value ownership/accounting,
borrowed envelope admission or physical planner admission. Relevant upstream
source or executable changes require refreshing the source comparison/native
oracle before consuming this certificate for a wider compatibility claim.
On a failed refresh, retain the physical refusal and reopen the affected claim.

Hostile review verdict: ROBUST within nominal row-kernel identity, bounded
descriptor/value transport and retained fail-closed physical admission.
Luna's same-lineage read-only review is correlated, not an independent runtime
certificate; root's executed specs/native exchange/manual byte checker provide
the separate discriminating evidence. Ordinary Dynamic empty-LC-arm and
zero-selected-window refusal were traced through the unconditional bulk-plan
construction, not directly tested by new W141 assertions. Direct Dynamic
name routing and DynamicStructure constructor name allocations remain outside
the physical planner's narrowed early-render guard.

## Continuation

Previous goal turn made progress: W140 implementation and paired evidence were
committed as `36720ba`; the working tree was clean before W141.
Active return pointer: paired types, then MV/projections, then performance
qualification against original ClickHouse with at most 10% speed deficit.
Next physical signal: resolve and qualify LC dictionary/index roles, prefix
state, index widths, null/default reservation and cross-mark dictionaries,
then a library bulk RED and independent paired persisted parts. W141's nominal
row kernel is the prerequisite, not closure of Object/LC storage or the broad
types/MV/projection objective. Performance remains parked.
