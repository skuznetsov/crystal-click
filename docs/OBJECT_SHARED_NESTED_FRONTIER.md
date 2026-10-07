# Object shared-path Nested composition (W197)

Historical checkpoint: the specialized-child refusals below were retained by
W197/W198. The current W201 kernel replaces that blanket policy with recursive
LC occurrence schedules and explicit Dynamic structure sites; see
[NESTED_SPECIALIZED_BULK_FRONTIER.md](NESTED_SPECIALIZED_BULK_FRONTIER.md).
This does not widen the earlier complete-part corpus to arbitrary schemas.

Status: VERIFIED within the finite internal Data-adapter corpus below.
No complete library-written Nested actual part is qualified by this slice.
Baseline: `4473ed28dde554b7420f77a3b3b9f0310052a0fa`.

## Boundary and source anchor

The change composes existing Array/Tuple bulk owners for an ordinary
nominal Nested actual arm of Dynamic, including an Object shared-path Data
record. It does not introduce another scalar serializer or erase the Nested
descriptor. The existing standalone Nested logical/storage certificates remain
separate from this new specialized context.

Source: clean, unbuilt shallow ClickHouse checkout
`/Users/sergey/SrcArchives/clickhouse-2026-10-05-depth1-ef037e60`, revision
`ef037e60fc7f5654c8c80eefb8be82e3c56f9a67`. In
`src/DataTypes/DataTypesBinaryEncoding.cpp`, Nested has its own binary tag and
field roster. Its bulk serializer uses the Array of named Tuple carrier.
The source inspection is not a native runtime result.

Runtime pin: ClickHouse 26.10.1.1201, build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`, SHA-256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
This binary is not a build of the source revision above.

## Admission / retained guards

- Ordinary Nested actual descendants use shared Array row sizes and ordered
  Tuple fields, preserving nominal type names and synthetic Tuple accounting.
- Prefix/body traversal, array nesting levels, zero-child callbacks, selected
  arm cardinality and caller budgets must agree in both directions.
- Nested subtrees containing LowCardinality, Variant or Dynamic remain refused
  until their specialized sibling/site schedules are implemented and tested.
- QBit and JSON actual-path guards remain unchanged. This slice does not admit
  arbitrary recursive products, flattened sibling groups, arbitrary Dynamic
  roster evolution, Compact complete parts, MV/projections or performance.

## Plan and falsifiers

Risk: CAUTION (recursive serialization and persistent-format boundary).
Rollback: one exact-path local feature commit from the clean baseline; no push.
Root owns serialized guarded compiler/native processes; Luna owns candidate
tests/implementation, which are not independent verification.

1. Native diagnostic: inject literal Nested and Array(Tuple) descriptors into
   separate Object paths. Query nominal `dynamicType`, whole Object, and direct
   path values separately. A nominal rewrite or native rejection changes the
   implementation route; do not simply remove the guards.
2. Behavioral RED: the unchanged path codec must reject a legal ordinary
   Nested arm with two records, an empty value and an unselected row.
3. Implementation: extend the existing Dynamic plan walkers and path callback
   walkers with Nested's Array-like carrier. Preserve all qualified child
   codecs and the specialized Nested rejection boundary.
4. Gates: focused DEBUG and the same affected roster in DEBUG/RELEASE (including
   all focused specs), then decode stock-created
   Nested and Array(Tuple) path Data and re-encode it byte-for-byte, including
   callback names/order/offsets. The native input has separate whole-Object,
   nominal-type and direct-path value witnesses. This qualifies the internal
   Data adapter, not publication of a complete library-written part. A future
   complete-part admission needs separate ATTACH/CHECK and direct-path reads.

Strongest failure: an Array(Tuple) self-roundtrip passes while the nominal
descriptor or flattened child count is wrong. Counterchecks use literal sizes,
field bytes/callback order, wrong-nominal substitution, empty rows/marks,
both String profiles, shared-budget exhaustion and retained mixed-type guards.

DoD: actual exits 0 from focused DEBUG and affected DEBUG/RELEASE `crystal spec`
commands (`--single-module --threads 1 --link-flags=-fuse-ld=ld --error-trace`),
format/diff checks, fresh helper builds/runs in both modes, and the stated
pinned native gate. Internal path-only evidence must not be reported as
complete-part qualification. Exact commands and rosters are indexed in
`.landmark/evidence/object-shared-nested-w197.json`.

The certificate decays if the code, child legality, source/runtime pins,
callback names/order, array depth or budget rules change. Missing or altered
captures require refresh; documentation and packet shape alone prove nothing.

## Observed discriminators (2026-10-06)

The stock-only diagnostic ran under the pinned guard at
`/private/tmp/crystal-click-w197.AS5KKc/evidence`. Three isolated imports and
their CHECK, whole-Object, type and independent direct-path queries exited 0:
Nested, Array(named Tuple) control, and QBit(Int8,3). Each contains populated,
missing and empty/default rows in a Wide v3 CHUNKED part. Native preserves
`Nested(n UInt8, s String)` versus `Array(Tuple(n UInt8, s String))`; the
populated direct RowBinary bytes agree (`0107036f6e65`). This establishes
native legality and nominal identity, not new library support for QBit.
Root checked raw argv/SQL/input/stdout/stderr hashes and exact observed values.

The unchanged production failed the first W197 spec at runtime, not compile
time: 1 example, 0 assertion failures, 1 `UnsupportedFormatError`, 0 pending,
actual child/guard exit 1. It rejected ordinary Nested in Dynamic's canonical
actual roster before path serialization. Log:
`/private/tmp/crystal-click-w197.AS5KKc/path-red.log`. The measured boundary is
the intended capability RED, not a passing gate.

The separate physical-name consumer RED also compiled and failed at runtime:
the binding planner rejected Nested with `UnsupportedFormatError` (1 example,
0 assertion failures, 1 error, 0 pending, exit 1). All Array-like walkers in
the logical plan, physical binding plan and path prefix/body owner now carry
Nested through its implicit named Tuple. Specialized-child refusal still runs
before actual-arm name/role construction and at both declared-plan entrances.

## Executed checkpoint (2026-10-06)

- Focused DEBUG: 20 examples, zero failures/errors/pending, actual exit 0.
- Same 129 affected files: 855 examples in DEBUG and 855 in RELEASE, zero
  failures/errors/pending, actual exits 0. The roster includes all focused
  specs; it is not the full repository suite.
- Source/spec identity: 942 regular files, SHA-256
  `cc736372c375e674a7d2d1d17d349395a4fcb9e8bca544969c302872e40c510a`,
  unchanged across the final suites, fresh helper builds and native reads.
- Fresh DEBUG/RELEASE helpers decode two stock Wide CHUNKED v3 parts with
  String profile 1, two buckets and a `[2, 1]` physical mark grid. Each has
  populated, pathless and empty rows. Both modes preserve the exact Nested
  versus Array(named Tuple) actual roster and re-encode four path Data records
  per mode with identical bytes and callback names/order/offsets.
- Root separately reconciles literal descriptors, framing, child bytes,
  row values, physical/logical schedules and missing-path chunks. Four report
  mutations per mode (nominal roster, sparse child size, callback offset and
  scalar byte) are rejected by that literal reconciler. These are report-oracle
  controls, not four new codec rejection tests. DEBUG/RELEASE reports agree
  byte-for-byte; all 86 stock part files remain unchanged.
- Format and diff checks exit 0. Luna's bounded static review found no concrete
  guard bypass; it is correlated review, supplemented by root's actual runs.
  Scoped Adversary verdict: ROBUST for this finite internal adapter corpus.

During verification, one read-depth spec was corrected to the existing
`CorruptPartError` contract (writes use `UnsupportedFormatError`). Production
depth behavior did not change. The helper also needed an eager JSON report
array instead of a lazy iterator; its successful builds were rerun afterward.

Logs and stock captures live under
`/private/tmp/crystal-click-w197.AS5KKc`; they are retained local evidence, not
committed fixtures. The helper is intentionally tied to this evidence root.
Missing captures invalidate this checkpoint until refreshed. A future reusable
fixture harness or broader nested-within-nested/native matrix is separate work.

Next: qualify remaining specialized wrapper/site schedules using shared child
codecs, then qualify complete-part publication separately. No new full-part
ATTACH certificate, broad recursive-product admission, performance result,
MV/projection capability or repository-wide class decomposition is claimed.

## Complete-part qualification (W198)

Status: VERIFIED within the finite corpus below; baseline
`ff00cac5efb7b9a276711bef5d9dc827de482ea1`.
The discriminator uses the public `ObjectColumnReader` and
`WidePartWriter.write_uint64_object_pair`, without replacing lanes after part
publication. It tests ordinary `Nested(n UInt8, s String)` and the nominally
distinct `Array(Tuple(n UInt8, s String))` control, shared ADVANCED v2 and
CHUNKED v3, and String profiles 0 and 1. Authored rows include populated,
pathless, empty, multi-element and empty-string values across mark boundaries.
The column declaration is `JSON(max_dynamic_types=1, max_dynamic_paths=0)`;
this fixture has no declared typed paths or Object dynamic paths. Each part
has eight rows and a `[2, 2, 2, 2]` physical mark grid.

The writer may use an empty actual-type roster and SharedVariant. Matching
ClickHouse's roster-selection policy is not required; preserving nominal type,
values and stock direct-path readability is required. The persisted read
roster is not assumed empty merely because the writer uses `max_types=0`.
No production change is justified before a measured behavioral failure.

Risk: CAUTION (a persistent-format compatibility claim). Rollback: exact-path
local commit from the clean baseline; no push. Root owns serial guarded
compiler/native runs, source inspection and independent literal reconciliation.
Luna owns candidate focused tests and thin helpers; it is correlated evidence.

DoD: focused and affected DEBUG/RELEASE tests exit 0; fresh helper builds and
paired native runs exit 0; stock parts remain unchanged; every profile preserves
the authored type/value literals in public full/middle/zero reads and native
ATTACH/CHECK, whole-Object, nominal-type and independent direct-path queries.
The runner must reject a seeded nominal/value report defect. Native process
failures, missing rows and absent markers are failures, not empty successes.
Use the existing pinned source/runtime and bounded process runner. Exact
commands, coverage and observed outcomes are indexed in the evidence packet.

Retained guards: Nested with LowCardinality/Variant/Dynamic descendants,
QBit/JSON actual-path adapters, arbitrary recursive products and complete
Compact parts are not admitted by this qualification. MV/projections,
performance and broad class decomposition remain separate open tracks.

### Executed complete-part checkpoint (2026-10-06)

No production changes were needed: the W197 recursive child adapters already
compose through public complete-part publication and reads for this corpus.
The writer uses its existing always-spill policy; stock insertion and merge
roster policy are not reproduced or required by this certificate.

- Focused DEBUG: 16 examples, zero failures/errors/pending, actual exit 0.
- The same 130 affected files: 857 DEBUG and 857 RELEASE examples, zero
  failures/errors/pending, actual guarded exits 0; not the full repository suite.
- Source/spec identity: 943 regular files, SHA-256
  `e7ba9f1232ca85c9ddaa160a199c3fae863376bf7091e343f89f3e3dd014797b`,
  unchanged across the final suites, fresh builds and native runs.
- Fresh DEBUG and RELEASE helpers independently create eight Wide parts via
  `WidePartWriter.write_uint64_object_pair`; no lane replacement follows
  publication. Both helpers read all eight stock and all eight library parts
  with public full/middle/zero mark windows. Actual ordinary String metadata
  and decoded shared-data prefix versions are checked, not profile labels.
- Each mode's pinned stock runtime separately ATTACHes/CHECKs eight library
  parts and re-CHECKs eight stock parts. Independent whole-Object, dynamicType
  and direct dynamicElement RowBinary queries authenticate 128 full and 64
  middle rows across both origins, plus explicit zero-window markers. There
  are 192 direct-path result rows per mode. Persisted PKs, nominal Nested versus
  Array(Tuple), absent versus present-empty and authored payload bytes agree.
- Root authenticates raw argv, SQL, stdout/stderr, actual process exits and
  snapshots of all 680 files per mode (344 stock, 336 generated). All generated
  files are byte-identical between modes; normalized helper observations agree.
- Eight root controls per mode reject nominal/payload/version report poison,
  wrong persisted PK, wrong native nominal type, a missing zero marker, an
  extra whole-JSON TSV field and same-length stdout substitution. Separate
  single-capture and duplicate-capture probes are rejected. These are evidence
  oracle controls, not new codec rejection tests.
- Ruby syntax/literal/parser self-tests, Crystal format and diff checks exit 0.
  Luna's static review is correlated; root's native and raw-byte reconciliation
  provide the executed checks. Scoped Adversary verdict: ROBUST for this corpus.

Verification repaired helper/test compiler issues and hardened real-tab
parsing, inventory/CHECK cardinality and the executable/report summary-key
collision. These are harness fixes, not serde regressions or capability REDs.

Exact commands and digests are indexed in
`.landmark/evidence/object-shared-nested-parts-w198.json`. Local captures:
`/private/tmp/crystal-click-w198-native-debug-final.5X0O4f` and
`/private/tmp/crystal-click-w198-native-release.SFzftq`; compiler logs and the
root reconciler are in `/private/tmp/crystal-click-w198.03w0Y3`. They are not
committed fixtures. Missing captures/reconciler or a changed dependent codec
invalidates this checkpoint until refreshed. The separate source checkout is
the clean, unbuilt October 5 depth-1 snapshot; it is not the runtime build.

Next: direct ordinary QBit actual-path planning/binding, followed by its paired
complete-part certificate. Specialized Nested descendants, JSON actual-path
storage, Compact advanced parts and arbitrary recursive products remain open.
No full-types, MV/projection, performance or class-decomposition closure is claimed.
