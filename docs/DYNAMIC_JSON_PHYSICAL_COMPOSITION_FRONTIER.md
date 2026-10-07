# Dynamic JSON physical composition — W210

Document status: finite physical/public composition verified. Baseline:
`6cc06932dd17d864b2442633eb13b3cdd0bb10fa`. W209 admits normalized ordinary
Dynamic JSON arms only. The full types, MV/projections and eventual performance
goal remains active; this slice does not redefine completion of that goal.

## Required capability

Compose a direct ordinary JSON actual with the existing Object physical owner
inside a Dynamic-bearing Wide column. Public complete-part writing accepts an
explicit `(Dynamic site, canonical arm, ObjectDocumentPlan)` binding roster;
offline reading discovers equivalent plans from persisted descriptors and
Object metadata. Root Dynamic and existing recursive Array/Tuple/Nested
carriers must retain their existing ordinary codecs. Recursive storage sites
reuse the same composition rather than a second JSON serializer. Table batch
consumption must expose the recovered values where the declared schema route
admits the column.

Table propagation in this slice uses the existing Tuple/Array-with-nominal-JSON
dispatch route, with a Dynamic-bearing sibling carrying an ordinary JSON arm.
A new generic direct-Dynamic table batch accessor is a separate, still-open
consumer frontier; complete-part column readers are not that table API.

Rejected surface remains: JSON SKIP/SKIP REGEXP descriptors, SharedVariant inline JSON, wrapped/composite JSON
actuals, JSON-containing Object path Dynamic actuals without a child binding,
unsupported physical layouts and live mutation of source parts. Existing
nominal-JSON BinaryBulk guards stay intact. Performance optimization and new
functions/joins are not part of this slice.

## Design laws

- The parent Dynamic roster is read first. JSON descriptors supply typed paths
  and caps; their existing codec rejects nonempty SKIP/SKIP REGEXP rosters.
  Existing Object metadata owners supply dynamic paths and
  their actual rosters. No second metadata parser or per-product serde.
- Preserve P (physical table rows), Q (Dynamic site occurrences) and R (selected
  JSON arm occurrences) independently. Object children receive `(P,R)`, even
  when Q=0 or R=0. Their `.mrk2` third words remain P. Never infer Object plans
  from selected values or statistics. Structural Array/Tuple carriers retain
  the root table P grid too; their flattened tuple count is Q, not a new P.
- Ordinary BinaryBulk roles remain separate from Object child roles. One
  composite physical roster includes all bound arms, including unused arms,
  and validates escaped names, Array levels, hashed aliases and collisions.
- Ordinary typed/Dynamic child String serialization inherits the parent
  profile. Object shared MAP data independently uses `single_stream`, matching
  ClickHouse's default shared-data serialization; do not propagate the ordinary
  profile into that owner. ArrayElements advances the Array level without
  adding an `.elements` component to physical stream names.
- Normalized discriminator bytes are not raw Variant framing. Only the
  existing physical framing owner translates BASIC/COMPACT bytes before the
  normalized census. Bound JSON reads validate/decode all marks before slicing,
  including empty requests; no lazy or selected-window cost claim follows.
- Collection, adaptation, Object serde, inherited depth, names and transport
  borrow the operation's existing budgets. Reuse already collected documents
  or normalized child streams without running a second JSON value serializer.
- Staged validation compares JSON content, not only BinaryValue's ordinary
  byte/child fields. No destination publication or table callback precedes
  required validation.

## Execution and ownership

CAUTION: serialization and public storage capability change. The strongest
false positive is matching writer/reader mistakes in child names or `(Q,R)`
grids. Rollback is the exact scoped diff/local atomic feature commit; no source
part, dependency, remote history or push changes are authorized.

1. Add and execute a failing physical-handoff specification before production edits,
   then extend it to the public part API as its binding argument lands.
   Literal grids include P=[2,2,2], Q=[0,3,2], R=[0,0,2] and a bound unused JSON
   arm. Missing child files/corruption must reject even an empty selection.
2. Physical plan and writer: bind Object child prefixes at the existing ordinary
   arm stop; pass physical P independently of Q; merge child files into part
   rosters; propagate explicit bindings through public writers and staged JSON
   comparison. Reuse `BinaryDynamicBulkJsonObjectWriter` and
   `ObjectDocumentColumnWriter`.
3. Reader: parent-first automatic child discovery through
   `BinaryDynamicBulkPlan` loader, site-name resolver and
   `ObjectDocumentFileReader`; normalize physical framing before census; feed
   validated child documents to the existing generic decoder; preserve eager
   full-domain validation and recursive/table propagation.
4. Root runs focused and inherited affected DEBUG/RELEASE specifications
   serially under `run_safe.sh`; source/spec edits are frozen during workloads.
   Root independently inspects the candidate, attacks schedule/unused-arm and
   staged-content boundaries, then records one coherent verified local commit.

## DoD and independent falsifiers

Focused public writer/reader tests cover root and recursive carriers, full,
middle, final and EOF-zero reads, typed nullable JSON values, unused arms,
P!=Q, R=0, exact child file/checksum rosters, budget/depth failures, wrong or
missing bindings and rejection without publication/callback. Existing W209
normalized, W203 Dynamic parts and W204/W205 recursive zero-Q guards remain
green. Commands are guarded `crystal spec <exact affected roster>
--single-module --threads 1 --link-flags=-fuse-ld=ld --error-trace`, in DEBUG and
RELEASE. Expected signal: zero failures/errors/pending and actual guarded exit 0.

Fresh stock-authored parts must be read without supplying child plans; stock
ClickHouse must directly ATTACH and CHECK library-written parts. Independent
literal values/types/stream names and P/Q/R schedules distinguish native
compatibility from a self-roundtrip. Source reference is the clean shallow
checkout `/Users/sergey/SrcArchives/clickhouse-2026-10-07-depth1`, commit
`0ca8150d9b1d0886edb2e3b4ab65eebb768d0357`; runtime is separately pinned to
26.10.1.1201 build `d9bcb5ab007f0f6299f7f973f2642245bab3d028`.

Initial evidence: the focused physical-handoff RED executed against the baseline:
2 examples, 0 failures, 1 runtime error rejecting the actual JSON arm in
`BinaryDynamicBulkPhysicalPlan.scan_type`, guarded exit 1. The unbound
no-publication control passed. The candidate's focused DEBUG gate now passes
11 examples. Fresh paired native DEBUG and RELEASE probes both observe root
Dynamic and Array(Dynamic) across both String profiles, direct library part
ATTACH/CHECK and literal values/types. The final 188-file affected DEBUG corpus
passes 1179 examples. The same exact 188-file RELEASE corpus passes 1179
examples across four disjoint 47-file groups (334, 303, 284 and 258 examples).
The initial monolithic RELEASE build exceeded the unchanged 12288 MiB guard;
the partitioned gate preserves the roster and resource cap, not a claim that
the monolithic build fits. Final focused DEBUG and RELEASE gates pass 11 each.
Changes to rosters, depth/budget owners, framing, occurrence grids or
source/runtime pins reopen the associated claims.

Hostile defect seeds run against unchanged focused assertions. Removing the
empty-table validation produces two failures; removing either staged JSON
content comparator produces one failure. A positive but wrong physical grid
P+1 produces one literal mark assertion failure and seven executed errors,
including rejection before part publication. An earlier P=R seed produces
eight errors at the positive-grid guard; it is not the nonzero-grid witness.
All temporary defects are restored byte-for-byte before final focused gates.
The full 984-file src/spec identity is
`f22dbf8fd3079960b5eb05aa5fe1d06c03f474dfe7caf78365c1b36fb3e66fc6`.
Scoped Adversary verdict: ROBUST for this finite composition and its executed
corpus/native profiles, not whole-project compatibility or performance.

The native profile probe exposed a matching reader/writer mistake: ordinary
`with_size_stream` was also passed into Object shared MAP, inventing paths/value
size lanes absent from stock parts. A new independent literal roster assertion
first failed (11 examples, one failure); the four physical Object call sites now
keep the ordinary profile but use `single_stream` for shared MAP. Pinned source
`SerializationObjectSharedData.cpp:43-49` constructs that MAP with default
serialization. The independent native fixture also corrected two oracle errors:
stock JSON integer inference gives counter Int64, and ArrayElements does not
render as `.elements` (`ISerialization.cpp:318-321`). File, checksum and exact
roster checks remain strict. These observations are not whole-project closure.

Both native modes directly attach four library parts. The 264 generated part
files agree byte-for-byte across modes, and helper reports agree after removing
only their absolute output paths. Value observations include repeated windows,
not distinct-row counts. The native shared MAP fixture is empty: its profile
and physical roster are witnessed, not every nonempty shared-data layout.
PartStreamSource verifies declared file names and physical sizes, not every
whole-file checksum hash; source parts must remain quiescent. Staged comparator
negative tests and publication ordering are checked, but this slice does not
fault-inject every staged I/O/publication failure or prove global callback
atomicity. Curated commands, pins, hashes and scope are recorded in
`.landmark/evidence/dynamic-json-physical-w210.json`.

## Composition is not a Cartesian-product serializer

Leaf codecs are reused recursively. Array owns sizes and transforms the row
domain; Variant owns discriminators and per-arm domains; Dynamic owns actual
type metadata and delegates through Variant; Object owns path metadata and
delegates typed/Dynamic children. LowCardinality owns dictionary/index state
and delegates its dictionary keys. Nested retains its Array/Tuple and naming
contract. A missing composition edge needs a contextual handoff and a native
compatibility witness, not a fresh serializer for each pair of types.

Type products are not all legal in ClickHouse. Its LowCardinality constructor
checks the inner type's `canBeInsideLowCardinality()` capability. Leaf support
does not admit every container, physical version, mark schedule or API consumer.
In particular this slice does not establish generic wrapped JSON actuals,
SharedVariant inline JSON or the adjacent non-JSON outer SharedVariant
inherited-depth path. Those claims remain separate from the mandatory absolute
depth validation of reconstructed bound JSON rows.
