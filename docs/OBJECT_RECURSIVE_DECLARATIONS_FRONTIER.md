# Object Recursive Declared Fields Frontier (W140)

Status: VERIFIED within the executed W140 profile, 2026-10-03. Baseline is
`281b0d6` (W139). Focused/adjacent gates, paired stock matrix, independent live
witness, complete inventory and unchanged neighboring stock regressions passed. The
overall paired-types/MV/projections goal remains active, and performance is
parked until that compatibility work is complete.

## Problem and source boundary

The generic BinaryDataType, bulk-value codec, bulk physical-role planner,
Object typed-lane codec and Object file reader already recurse through Array,
Map, named/unnamed Tuple and Nullable descriptors. The paired public path is
blocked by the scalar-only ObjectTypedFieldType policy and the outer JSON
parser's one-level parenthesis guard. Removing those guards alone would admit
descriptor trees without recursive schema preflight and undercount their
retained catalog storage.

The source reference is the separate, unbuilt shallow checkout at
`/Users/sergey/SrcArchives/clickhouse-2026-10-03-depth1-9007d227`, commit
`9007d227b64a3f8b667fc5258ceb2923f3cf477d`. Native probes must separately pin
the existing ClickHouse local executable; it is not a build of that source.
Object typed paths are factory-created types in ClickHouse, not a scalar
allowlist, but factory admission is not JSON serialization admission. Fresh
source permits Nullable(Tuple(...)) and standalone Map with Array keys:
Tuple can be inside Nullable, and Map's constructor rejects nullable/
LowCardinality-nullable keys rather than all composite keys. Object constructs
its JSON extraction tree in `DataTypeObject.cpp:184`; that tree additionally
requires a String Map key (`JSONExtractTree.cpp:2781`), including nested Maps.
The pinned native DDL probe independently rejects non-String Object Map keys.
Keep this narrower rule in Object policy, not BinaryDataType.map. Earlier
scalar-only Nullable and general scalar-Map-key hypotheses are refuted; the
opposite hypothesis that factory admission alone suffices is also refuted.

## Admitted surface and qualification boundary

- Canonical recursive Array, Map(String, V), named/unnamed Tuple and Nullable
  over the already admitted W139 nominal leaves. Every nested Map must have
  exactly String keys; Nullable may wrap Tuple or an admitted leaf, not
  Array, Map or another Nullable.
- Cross-compositions use those same descriptors and codecs, not one class or
  codec per type combination.
- Exact family, parameters, child order, tuple field names, enum maps and
  timezone spelling remain semantic identity. A raw carrier match is not a
  substitute for nominal identity.
- Empty containers, null values, missing-path defaults and empty Tuple need
  explicit native and paired evidence; type-parser success alone is not
  physical-part qualification. Native Tuple() missing-path defaults produce
  checked rows, whereas explicit [] JSON input fails; those are different
  input corridors. This library's typed BinaryValue API need not implement
  JSONEachRow text parsing.

LowCardinality, Variant and Dynamic declared fields remain rejected by this
slice. Their targeted standalone profiles and Object dynamic-path alternative
rosters do not supply generic BinaryDataType nodes or bulk physical roles.
Additional Object versions/shared layouts, Compact/Sparse parts, arbitrary
schema writers, general MV execution and projection planning remain outside
this slice. These are open roadmap items, not removed requirements.

## Design constraints and ownership

Use separate cohesive owners/files for borrowed recursive text grammar,
descriptor measurement/rendering, Tuple field-name spelling and retained
catalog accounting. ObjectRecursiveDeclaration is the small shared entry and
preflight surface. ObjectTypedFieldType remains the shared policy entry point and
delegates existing leaves to their current owners. ObjectDocumentSchemaParser
owns only outer arguments/options/paths. Existing bulk, physical stream,
writer publication, table and catalog owners retain their responsibilities.
Do not grow legacy reader/writer facades or add a Cartesian combination API.

Before proportional type-tree allocation, the borrowed declaration pass must
validate stock-compatible shape and canonical syntax and account cumulatively
for depth, nodes, child/metadata edges, declaration bytes, tuple names, enum
labels and explicit zones. Materialization must revalidate borrowed bytes and
advertised metadata, including mutated or forged public preflight values.
The direct-descriptor constructor needs equivalent bounded traversal before
rendering or retained-path copies; do not call recursive `type.name` during
preflight. Preserve existing leaf charges unless a separately tested defect
requires a change.

Catalog logical schema accounting must walk descriptor children and owned
tuple/leaf metadata even for zero rows, without allocating an uncharged type
name. Preserve the distinction between retained logical bytes and transient
allocation/RSS. Table document charging remains post-decode retention
accounting, not a new pre-decode or caller-retention guarantee.

## Risk, rollback and discriminators

Risk: CAUTION (persisted schema and paired physical-format admission).
Rollback: the clean `281b0d6` baseline and one coherent local implementation
commit after the declared gates pass; no remote push or history rewrite.

Strongest likely failure: text admission succeeds while a nested physical
role, SQL constraint or cumulative schema budget is wrong. The guard is a
fresh stock-produced and library-produced part with independent literal
values/types, actual stream inventory, actual CHECK=1, and budget negative
controls. No positive gate may be weakened to fit observed output.

The native declaration/layout discriminator has produced 18 positive actual
CHECK=1 cases and nine cause-specific negative cases, using the separately
pinned 26.10.1.1201 executable. These default native parts use compressed
marks/primary-index files and are discovery evidence, not qualification of
the library's normalized plain-mark profile. LowCardinality/Variant/Dynamic
positives are native structural admission observations only, not newly
admitted library types or exact alternative-value witnesses.

The unchanged baseline compiled and executed
`spec/object_document_schema_w140_spec.cr`: seven examples, one failure and
three errors, with three existing rejection guards passing. This is semantic
RED, not a compiler failure. Production implementation was delegated under
the bounded surface above. Required
implementation gates:

1. Canonical parse/render and direct-descriptor schema equality for recursive
   compositions; distinguish named from unnamed Tuple and exact leaf types.
2. Exact/one-short depth, node, edge and byte thresholds, aggregate fields,
   tuple/enum/zone metadata and forged/stale preflight refusal.
3. Paired Object writer/reader values and physical roles; file full/middle/
   zero windows, table batches/PK granules and owned catalog materialization.
4. Recursive catalog schema charging with zero rows; pre-publication and
   pre-callback refusal for schema drift, including unselected later parts.
5. Fresh native/library parts, ATTACH and nonempty CHECK=1, independently
   expected nominal types and RowBinary; seeded comparator negatives.
6. Affected W139 and neighboring Object stock regressions, focused DEBUG,
   adjacent RELEASE and complete disjoint spec inventory, then scoped hostile
   review. Resource-guarded compiler/native work is serial and root-owned.

Observed baseline command (serial root-owned resource guard, SDK pinned):

```sh
crystal spec spec/object_document_schema_w140_spec.cr --single-module --threads 1 --link-flags=-fuse-ld=ld --error-trace
bash scripts/probe_object_recursive_w140.sh
```

Expected implementation signal: the RED spec becomes green without weakening
its guards, followed by the paired normalized-profile gates above. Both signals
were observed in the implementation gates below. Discovery
outputs from the tightened required-inventory/cause-check probe are retained
under `/private/tmp/crystal-click-object-recursive-w140.X4rklc`;
baseline RED is `/private/tmp/crystal-click-w140-root.Zs50se/schema-red-v2.log`.
These paths are ephemeral evidence references, not committed fixtures. This
baseline probe/checklist alone is not a capability certificate. An independent
source/native falsifier found that empty Tuple emits zero RowBinary bytes,
whereas its Wide bulk stream emits ASCII `0`. The paired oracle was corrected
before execution; bulk and row-oriented representations are not interchangeable.
Source/runtime, owner/policy/codec,
limits, comparator, publication or retained-evidence changes invalidate the
corresponding future claims and require replay before reuse.

## Bounded implementation plan

1. Implement the recursive declaration owners and integrate shared policy,
   outer parser and direct schema preflight. Ownership: implementation Luna;
   files `src/crystal_click/object_recursive_declaration.cr`, the existing
   Object typed policy/schema/parser plus focused W140 specs. A separate
   accounting Luna owns ObjectSchemaLogicalUsage and the catalog Object
   materializer/tests. Root alone integrates loader requires. Do not alter
   generic Map admission.
2. Prepare a separate paired oracle in
   `scripts/check_object_recursive_w140.{sh,cr}`. Ownership: oracle Luna;
   source/SDD and native discovery script remain root-owned. The oracle uses
   explicit plain marks/index settings and literal independent values/bytes.
3. Root runs focused DEBUG (including the unchanged RED guards), adjacent
   RELEASE, stock paired gates and complete disjoint specs serially with
   `COGNI_RUN_SAFE_MIN_FREE_PCT=50`, a 32768 MiB process-tree ceiling, explicit
   timeout, SDKROOT `/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`,
   and fresh retained Crystal cache directories. No parallel compilers/native
   runs; agents prepare work but do not execute those workloads.
4. Root inspects the actual diff, type identity and budget counterexamples;
   Luna's output is correlated hypothesis until independently exercised.
   A coherent feature receives one local atomic commit only after its gates
   pass. No push is authorized. Failed gates leave this slice IN_PROGRESS.

## Executed implementation gates

Root owns compiler/native execution, with the serial guard and SDK described
above. Luna prepared grammar, accounting, consumer falsifiers and the paired
oracle; same-lineage static review is correlated, not independent evidence.
The root-authored semantic/budget tests and manual Ruby witness provide
separate executable checks rather than promoting model agreement.

- Focused DEBUG: 109 examples, zero failures/errors.
- Adjacent RELEASE: 496 examples, zero failures/errors, including existing
  Object catalog/table/writer, lazy windows, projection and temporal consumers.
- Paired stock matrix: eight complete cells, four native JSONEachRow parts
  read by the library and four library-owned parts attached by stock. Every
  cell has one active seven-row Wide part, exact returned CHECK part name,
  result `1` and empty message. String single/with-size profiles cross Dynamic
  BASIC/COMPACT. Actual hashed stream inventory, plain `.mrk2`/`primary.idx`,
  four marks `[2,2,2,1]`, full/middle/zero file/column windows, table PK=6
  candidate `[5,6]` and application residual `[6]` all pass.
- Independent manual Ruby checker: all eight live stores have the exact 13
  nominal field types and SQL declaration, active rows and actual CHECK.
  Literal VarUInt, little-endian UInt16, String, Nullable, ordered Tuple/Map,
  Enum8 and independent UTC DateTime64 arithmetic reproduce 426 full and 136
  middle RowBinary bytes per cell: 4,496 checked bytes total. It does not call
  Crystal descriptors or codecs, or derive expected bytes from the oracle's
  expected output. Empty Tuple contributes zero row-oriented bytes.
- Complete inventory: 2,317 examples, zero failures/errors, across all 367
  unique spec files in 16 frozen disjoint non-release groups. The runner checks
  both unique inventory and total selected files. No combined-process or full
  RELEASE certificate is claimed.
- Seven unchanged neighboring stock oracles passed freshly: W132 numeric,
  W133 Date/Date32, W135 UUID/IP, W136 FixedString, W137 Decimal, W138 Enum and
  W139 temporal. Each retains its original finite fixture/profile scope;
  their old "no wrappers" captions describe those regression fixtures, not
  a current blanket W140 schema refusal.

The physical certificate is bounded to the 13 witness fields in
`scripts/check_object_recursive_w140.cr`: Array/Map/Tuple/Nullable compositions
over UInt16, String, Enum8 and DateTime64(3, 'UTC'), including empty containers,
nulls, missing defaults, named/unnamed/empty Tuple and nested Map/Array/Tuple.
Recursive schema admission over W139 leaves is broader than this finite
physical sample; it does not qualify every leaf/composition/profile product.
Quoted Tuple-name stock CAST/render probes are spelling evidence, not extra
physical Object cells. Existing Dynamic/shared paths are retained in the
matrix, not a new generic Dynamic declared-field admission.

Two implementation failures were exercised before repair. Passing a mutable
ScanTotals struct by value silently lost descendant charges; one reference
accumulator now preserves cumulative metrics, with exact mixed Tuple/Enum/zone
counts and one-short direct/parser limits. Public accounting/materialization
bridges could trust forged metrics or bypass aggregate limits; a root-run
108-example suite produced exactly two failures, then became green after
borrowed-byte/metric revalidation and checked public bridges. An early slice
byte guard now rejects oversized malformed input before scanning. All fields
are accounted before descriptor-tree allocation; custom limits and schema
root depth 2 remain attached through materialization. Same-canonical,
same-metric edits read current borrowed bytes, not an immutable snapshot or
concurrent mutation contract.

Catalog accounting charges descriptor tree positions and tuple/leaf metadata,
including zero rows; shared descriptor references may be conservatively
counted more than once. This is a retained logical estimate, not allocator
bytes, process RSS or pre-decode transient allocation. Direct writer mismatch
fails before publication; a later unselected part's nested same-width nominal
drift fails before the first table callback. Old blanket wrapper refusals were
replaced only for newly legal shapes; malformed/unsupported guards remain.

The new oracle initially had iterator/Array and String#split overload errors;
those were fixed before the successful stock run. A deprecated
File.executable? warning remains in the test script, not a failed gate.
Successful paired evidence is retained at
`/private/tmp/crystal-click-object-recursive-w140.ftnuie`; earlier compiler-only
attempts are retained separately, without being counted as compatibility
results. Final focused/RELEASE logs, public-bridge RED and independent checker
are under `/private/tmp/crystal-click-w140-final.DFI67m`. These temporary paths
can decay; replay the committed gates when unavailable. Policy, parser,
accounting, codec, physical profile, runtime/source or comparator changes
reopen the affected certificate.

## Final seal and continuation

Root's scoped adversarial verdict is ROBUST: borrowed/forged metadata and
public bridge bypasses, cumulative mixed metadata, one-short resource bounds,
same-carrier nested nominal drift, empty-Tuple row/bulk conflation and
independent byte/type/CHECK comparisons all have executed discriminators.
This verdict is not universal type/layout compatibility, an independent-model
consensus certificate, performance parity or completed facade modularization.

The stock executable is 26.10.1.1201, build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`, SHA-256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
It is not built from the shallow source reference. Root uses Crystal 1.21.0,
LLVM 22.1.8, AArch64 and the pinned MacOSX26.5 SDK. All compiler/native gates
are serial, min-free 50%, process-tree ceiling 32768 MiB; spec/stock timeout
900 seconds, independent witness timeout 120 seconds.

Executed DoD commands (the retained runners hold exact selections and flags):

```sh
bash /private/tmp/crystal-click-w140-final.DFI67m/run_specs.sh focused
bash /private/tmp/crystal-click-w140-final.DFI67m/run_specs.sh release
W140_TMP_ROOT=/private/tmp/crystal-click-object-recursive-w140.ftnuie bash /private/tmp/crystal-click-w140-final.DFI67m/run_stock.sh recursive
ruby /private/tmp/crystal-click-w140-final.DFI67m/verify_w140.rb /private/tmp/crystal-click-object-recursive-w140.ftnuie
bash /private/tmp/crystal-click-w140-final.DFI67m/run_specs.sh full 367
bash /private/tmp/crystal-click-w140-final.DFI67m/run_stock.sh neighbors
```

The stock command is a historical fresh-root invocation, not an overwrite
instruction: the committed wrapper refuses reuse of populated evidence roots.
For replay, use fresh mktemp storage or omit W140_TMP_ROOT. The full runner
sorts `rg --files spec -g '*_spec.cr'`, asserts count/uniqueness and selects
disjoint batches of at most 24 files. No phase shares a concurrent compiler.
The tested recursive text owner SHA-256 is
`9783c54292bded3297f7e6a6482e80ac40794aa588013bee32cfceaa3006c67f`;
paired oracle SHA-256 is
`f53b7a667709848cb4f24c24d08eb3034b321ca72232e8f8e24dfc6d20ae407b`.
Only documentation changed after these final source gates.

The next capability frontier is declared LowCardinality/Variant/Dynamic and
the inherited timezone-profile gap, followed by separately qualified layouts
and MV/projection work. Begin with a source/native admission discriminator,
then paired descriptor/role support; standalone targeted profiles do not
automatically supply generic Object nodes. Performance remains parked.
