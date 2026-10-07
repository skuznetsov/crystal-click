# CrystalClick project status

Current finite table-consumer component (W211, 2026-10-07): typed table batches
now expose existing Dynamic bulk storage via
`WidePartTableBatch#dynamic_bulk_values_for(column) : Slice(BinaryValue)`.
Root/Array/Tuple/root-Nested carriers and admitted nested actual Dynamic trees
reuse the same reader. Canonical declaration identity, complete parent/child
schedules (including empty selections), and cumulative per-mark logical
ownership are checked before exposing the offending mark. Bare legacy Dynamic
and nominal-JSON accessors retain their contracts. No leaf codec or physical
layout admission is added.

Two cohesive declaration/table adapter owners have separate files. The same
79 affected files pass 374 examples in DEBUG and 374 in RELEASE; final focused
gates pass 13 per mode. Three deliberate defects fail unchanged assertions
before exact restoration. Fresh W203/W210 probes exercise the new consumer on
stock parts and directly ATTACH/CHECK 14 library parts per mode; all 510 part
files agree across DEBUG/RELEASE. Root audits raw invocations and input lineage.
Scoped verdict: ROBUST for this finite component, not all type/layout products,
lazy-read cost, transient RSS, checksum hashes or whole-scan callback atomicity.

Next: remaining contextual composition edges (wrapped JSON actuals,
SharedVariant inline JSON and Object path Dynamic children needing bindings),
owned offline-column values and projection/MV consumer propagation. Other
layouts/types, JSON SKIP/SKIP REGEXP, inherited owner-accounting gaps and broad
class decomposition remain open. Performance is deferred; the overall goal
remains active. Details: [DYNAMIC_TABLE_CONSUMER_FRONTIER.md](DYNAMIC_TABLE_CONSUMER_FRONTIER.md),
`.landmark/evidence/dynamic-table-consumer-w211.json`.

Previous finite physical/public component (W210, 2026-10-07): direct ordinary
Dynamic JSON arms reuse the existing Object physical owner, including unused
bound arms. Complete-part writers accept explicit child bindings; readers
recover bindings from persisted parent/child metadata. Root Dynamic and
Array(Dynamic) have fresh stock-authored/read and library-authored ATTACH/CHECK
witnesses in both String profiles, in DEBUG and RELEASE. Recursive carriers
and the existing nominal-JSON table dispatch route pass focused tests too;
this does not qualify a generic root-Dynamic table batch accessor.

The physical handoff preserves parent P, Dynamic occurrences Q and selected
JSON occurrences R independently. Child marks retain P even when Q or R is
zero. Object shared MAP uses default single-stream String serde while ordinary
typed/Dynamic children inherit the parent profile, matching the pinned source.
Leaf codecs are composed, not duplicated per product of types. Two new physical
site/coordinate owners each have their own file; repository-wide decomposition
is still open.

The same 188-file affected corpus passes 1179 examples per mode: one DEBUG run
and four disjoint RELEASE groups under the unchanged memory cap. Final focused
gates pass 11 per mode. Paired native probes directly ATTACH four library parts
per mode; all 264 generated part files agree across DEBUG/RELEASE. Independent
literal roster assertions exposed and fixed a matching writer/reader profile
mistake. Hostile seeds discriminate positive-but-wrong P, omitted empty-table
validation and both staged JSON-content comparisons before exact restoration.
Scoped verdict: ROBUST for this finite composition, not all CH type/layout
products, lazy-read cost, whole-file checksum verification or fault atomicity.

Next: the generic Dynamic table consumer and remaining contextual composition
edges (wrapped JSON actuals, SharedVariant inline JSON and Object path Dynamic
children needing bindings). JSON SKIP/SKIP REGEXP, additional physical layouts,
inherited owner-accounting gaps, MV/projections and broad class decomposition
remain open. Performance stays deferred and the overall goal remains active.
Details: [DYNAMIC_JSON_PHYSICAL_COMPOSITION_FRONTIER.md](DYNAMIC_JSON_PHYSICAL_COMPOSITION_FRONTIER.md),
`.landmark/evidence/dynamic-json-physical-w210.json`.

Previous finite normalized component (W209, 2026-10-07): explicit ordinary
Dynamic JSON actuals now compose with the existing Object child-site codec in
BinaryDynamicBulk streams. The generic recursive traversal collects/injects
JSON rows through the W208 adapter; two separate writer/reader classes own the
handoff. This reuses leaf/Object serde, not one serializer per type product.
Bindings cover all contextual direct JSON arms, including unused arms.

The complete normalized discriminator census precedes Object child decode;
Object grids retain physical parent P and selected JSON R, not Dynamic-site Q.
All children and all parent marks are decoded before returning a window,
including an empty selection. The finite path is eager, not a lazy-read or
selected-window cost guarantee. Complete actual/path rosters, typed Nullable
NULL, shared budget identity and inherited unused-actual depth are checked.
Nominal JSON-containing Bulk descriptors and unbound lower owners remain
guarded. Physical/public storage admission does not widen.

The same 187 affected files pass 1168 DEBUG and 1168 RELEASE examples; final
focused gates pass 14 per mode, all with zero failures/errors/pending and
actual guarded exit 0. Four final defect seeds reject under the unchanged
focused spec before exact restoration: lost budget identity, premature empty
return, omitted unused-roster identity and typed-depth off-by-one. The depth
seed gives an executed error, not an assertion failure. Root independently
checked the literals, owner/admission boundaries, seeds and guarded results.
Scoped verdict: ROBUST for the normalized component and executed corpus.

A fresh clean shallow ClickHouse reference is pinned to
`0ca8150d9b1d0886edb2e3b4ab65eebb768d0357` (2026-10-07). It is not the stock
runtime build pin, and W209 runs no native interoperability workloads.
Next: physical/public part/column/table propagation and fresh bidirectional
stock Dynamic(JSON) witnesses, CHECK and direct ATTACH. Full types/layouts,
MV/projections, broader owner-accounting gaps and repository-wide decomposition
remain open. Performance stays deferred; the overall goal is active.
Details: [DYNAMIC_JSON_OBJECT_HANDOFF_FRONTIER.md](DYNAMIC_JSON_OBJECT_HANDOFF_FRONTIER.md),
`.landmark/evidence/dynamic-json-bulk-object-w209.json`.

Previous finite logical component (W208, 2026-10-07): an ordinary Dynamic JSON arm
can bind its exact contextual site/canonical index and descriptor to an existing
Object plan. The Object schema comes directly from JSON caps and typed paths,
without rendering/reparsing the descriptor. `BinaryJsonObjectAdapter` borrows
immutable child values in both directions and preserves typed Nullable NULL;
only untyped Nothing NULL is omitted. Each new owner has its own source file.

Borrowed-budget/depth entry points in BinaryJsonRow and ObjectDocumentSchema
keep sibling work cumulative. Typed value descriptors that are equal but owned
by a separate graph are bounded before structural equality; the shared-root
literal is 14 nodes/12 edges, the distinct-root literal 20/16. The old W181 exact
fixture was corrected to account for those distinct graphs, not made unbounded.
Logical work/path-copy bytes are not retained heap or RSS measurements.

The same 186 affected files pass 1154 DEBUG and 1154 RELEASE examples; focused
final gates pass 18 per mode, all with zero failures/errors/pending and actual
guarded exit 0. Four defect seeds reject before exact restoration: wrong site,
missing source owner, dropped typed NULL, and skipped distinct descriptor
preflight. The NULL seed raises an executed error, not an assertion failure.
Root independently checked the literals, owner graph, seeds and guarded results.
Scoped verdict: ROBUST for the logical component and executed profiles.

This is not persisted Dynamic(JSON) admission. Rows carry no enclosing-site
provenance: consumers must select the exact binding and validate its contextual
roster; W208 adds no physical consumer enforcing that obligation. Object codecs
remain the physical admission authority, and existing JSON storage guards stay
closed. At that checkpoint the BinaryBulk ordinary-arm handoff, full P/Q/R
census, public column/table propagation and fresh bidirectional stock
interoperability were the next frontier. W209 now qualifies the normalized
handoff/census only, not physical/public storage interoperability.
Full types/layouts, MV/projections, broader owner-accounting gaps and repository-
wide decomposition remain open. Performance stays deferred; the goal is active.
Details: [DYNAMIC_JSON_OBJECT_HANDOFF_FRONTIER.md](DYNAMIC_JSON_OBJECT_HANDOFF_FRONTIER.md),
`.landmark/evidence/dynamic-json-object-bridge-w208.json`.

Previous finite prerequisite (W207, 2026-10-07): the shared materialization budget
now traverses retained BinaryJsonRow entries and BinaryJsonType typed rosters.
Path Strings are metadata, child values/types inherit depth, and counter
admission remains atomic. Equal-but-distinct row/value descriptor roots are
both charged; a shared root is not counted twice for that JSON edge. This is
logical occurrence accounting, not unique-allocation or RSS accounting.

The same 185 affected files pass 1145 DEBUG and 1145 RELEASE examples; focused
final gates pass nine per mode, all with zero failures/errors/pending and
actual guarded exit 0. Three seeded final defects cause eight, five and one
unchanged-test failures before exact restoration. Root's ownership review
found the distinct-root counterexample after the initial green snapshot; its
ninth test first measured 1354 rather than the independent 1927 logical bytes.
Scoped verdict: ROBUST for the JSON-owner extension and executed profiles.
Inherited Interval/SimpleAggregate sidecar accounting, AggregateCount metadata
outside JSON and the broader QBitValue audit remain open; this is not a
complete generic-owner budget guarantee or new persisted type admission.

At that checkpoint, ordinary Dynamic JSON-arm binding to Object storage was the
next proposed capability; W208 qualifies only its logical component. Full
types/layouts, MV/projections and repository-wide decomposition
remain open; performance is deferred and the overall goal remains active.
Details: [DYNAMIC_JSON_OBJECT_HANDOFF_FRONTIER.md](DYNAMIC_JSON_OBJECT_HANDOFF_FRONTIER.md),
`.landmark/evidence/dynamic-json-materialization-w207.json`.

Previous finite compatibility frontier (W206 checkpoint A, 2026-10-07): direct
JSON actual descriptors are representable through the existing Dynamic V3
full/prefix/paired metadata owner. This is metadata only. Bare Dynamic values
and root Object plans explicitly reject unbound JSON, including unused arms;
wrapped/physical/bulk/typed Object/SharedVariant guards remain. Scalar RowBinary
Dynamic(JSON) is preserved. No per-product leaf serializer was introduced.

The same 184 affected files pass 1136 DEBUG and 1136 RELEASE examples; focused
gates pass 22 per mode, all with zero failures/errors/pending and actual guarded
exit 0. Disabling both new guards causes three unchanged-test failures before
exact restoration. Each final native mode checks one fresh nonempty stock part,
one CHECK, eight independent value/type/shared-state observations and the exact
23-byte metadata literal (statistics offset 19, counts [8,0]). All 27 source
files remain unchanged per mode; part bytes and helper reports agree. Twelve
semantic oracle mutations and a helper-provenance regression are covered.
Root independently audits raw process/SQL/file evidence. Scoped verdict: ROBUST
for metadata only; no JSON-arm value handoff, library part or ATTACH is claimed.

The next active capability is an exact ordinary Dynamic JSON-arm binding to
the existing Object owner, preserving physical P, site Q and selected-arm R
domains and cumulative budgets. Full types, wider layouts/dictionary schedules,
MV/projections and repository-wide class decomposition remain open. Performance
is deferred and the overall goal remains active. Details:
[DYNAMIC_JSON_OBJECT_HANDOFF_FRONTIER.md](DYNAMIC_JSON_OBJECT_HANDOFF_FRONTIER.md),
`.landmark/evidence/dynamic-json-metadata-w206.json`.

Previous finite compatibility frontier (W205, 2026-10-07): whole-part positive
parent P with child Q=0 is now qualified for the existing recursive
Array(Tuple(JSON, Dynamic)) public column/table and complete-part APIs. No
production code or type admission changed. Both String profiles pass fresh
stock-to-library and library-to-stock gates in DEBUG and RELEASE. Stock's
independently empty actual/path roster and the library's unused UInt64 actual
are retained rather than normalized.

The same 182 affected files pass 1125 DEBUG and 1125 RELEASE examples; focused
DEBUG passes 22, all with zero failures/errors/pending and actual guarded exits
0. Per native mode: two direct ATTACHes, six CHECKs, 96 selected-row observations
across repeated windows and 122 unchanged published files. All 62 generated
files and normalized helper reports agree across modes. Nine instrument/oracle
mutations reject per mode. A separate checksum-resealed persisted Array-size
contradiction rejects before a table callback through Dynamic LC census; that
unused LC(String) actual case remains library-only. Scoped verdict: ROBUST.

The next proposed capability at that checkpoint was a direct JSON Dynamic
actual bound to the existing Object owner, reusing the ordinary roster/statistics
owner rather than adding a serializer per product. W206 admits its metadata,
not its value-ready Object handoff. Wider layouts and dictionary schedules,
arbitrary publication/catalog dispatch, full types and
MV/projections, and repository-wide class decomposition remain open.
Performance stays deferred and the overall goal remains active. Details:
[RECURSIVE_ZERO_OCCURRENCE_FRONTIER.md](RECURSIVE_ZERO_OCCURRENCE_FRONTIER.md),
`.landmark/evidence/recursive-zero-occurrence-w205.json`.

Previous finite recursive public-part frontier (W204, 2026-10-07): the existing
Array/Tuple JSON reader, typed table consumer and complete-part writer compose
JSON-free Dynamic-bearing siblings through the shared generic codecs. The
writer takes explicit prepared Dynamic site plans; the reader discovers actual
rosters parent-first and reuses bound physical owners. Physical parent P marks
and child occurrence Q schedules remain distinct, including zero-Q marks.
Inherited Array names, descriptor depth, LC replay and cumulative budgets are
preserved. `DynamicBulkSiteReader` and the descriptor-preflight receipt have
their own files; the standalone Dynamic column facade delegates to the same
site owner. No serializer per Cartesian type product was added.

The same 180 affected files pass 1121 DEBUG and 1121 RELEASE examples; the
focused gate passes 18. All have no failures/errors/pending. Four mixed carriers
under two String profiles pass fresh stock-to-library and library-to-stock
native gates in both modes: eight direct ATTACHes, 24 CHECKs and 384 independent
selected literal/type/state observations per mode. Thirteen oracle mutations
are rejected per mode; a seeded production P/Q defect breaks both positives
before restoration. All 364 generated files and normalized helper reports
match across modes. Scoped verdict: ROBUST.

At the W204 frontier, whole-part all-zero-Q had library-only tests, not a
separate stock witness; W205 qualifies that finite missing native case.
JSON-as-Dynamic-actual, additional wrapper/layout contracts, broader dictionary
schedules, general publication/catalog dispatch, full MV/projections and
repository-wide decomposition remain open. Performance is still deferred and
the overall goal is not complete. Details:
[RECURSIVE_DYNAMIC_JSON_STORAGE_FRONTIER.md](RECURSIVE_DYNAMIC_JSON_STORAGE_FRONTIER.md),
`.landmark/evidence/recursive-dynamic-json-storage-w204.json`.

Previous finite public-part frontier (W203, 2026-10-07): a generic direct
Dynamic-bearing complete-part reader/writer reuses the recursive BinaryBulk
owners. `write_uint64_dynamic_bulk_part` accepts an explicit per-site structure
map; `DynamicBulkColumnReader` discovers persisted sites parent-first, including
sites revealed by an outer actual roster. The existing static Nested API and
the new Dynamic API share one two-column publication workflow. Column, input,
physical site-name and Tuple metadata responsibilities have separate classes.

The same exact 177 affected files pass 1112 DEBUG and 1112 RELEASE examples;
final focused and post-seed restoration gates pass 27 examples. All successful
gates have zero failures/errors/pending and guarded actual exits 0. Fresh native
captures qualify root Dynamic, Array(Dynamic), Tuple(Dynamic, String), nominal
Nested with LC/Variant/Dynamic/String, and a Dynamic actual Tuple revealing an
inner site, under both String profiles and in both directions. Per mode: ten
direct library ATTACHes, thirty CHECKs, 480 selected literal/type/shared-state
observations across overlapping windows, and 504 unchanged published files.
DEBUG/RELEASE generated bytes and normalized reports agree. A seeded wrong LC
selection offset causes one unchanged-test failure; 49 raw/helper/report
mutations per mode are rejected. Scoped verdict: ROBUST.

No leaf serializer per Cartesian product was introduced. Root Tuple metadata
is now recursively schema-validated on an explicit opt-in seam; a present entry
without `subcolumns` is rejected, an omitted entry uses Default, and the old
Object parser stays strict. Generic descriptor composition is distinct from
qualification of all persisted layouts. JSON-containing types/actuals, broader
layouts and dictionary schedules, automatic OfflineTable dispatch, full types
and MV/projections remain open. Performance stays deferred; repository-wide
class decomposition and the overall goal are incomplete. Details:
[DYNAMIC_BULK_PART_FRONTIER.md](DYNAMIC_BULK_PART_FRONTIER.md),
`.landmark/evidence/dynamic-bulk-parts-w203.json`.

Previous finite public-part frontier (W202, 2026-10-06): direct nominal static
Nested complete-part reader/writer now delegates recursively to the shared
BinaryBulk owners. The new `write_uint64_nested_bulk_part` and
`NestedBulkColumnReader` APIs accept BinaryValue granules without a synthetic
JSON sibling. The UInt64 key roots the physical mark grid; Nested fields use
the flattened element domain. Three separate new owners isolate the column
reader, column writer and complete-part publication workflow.

The same exact 153 affected files pass 989 DEBUG and 989 RELEASE examples,
zero failures/errors/pending, guarded actual exits 0. Fresh final native
captures qualify LC(Nullable(String)), Variant(String, UInt64) and String
inside nominal Nested under both String profiles in both directions:
stock parts -> public reader; library parts -> stock ATTACH/CHECK/literal
SELECT. Per mode: two library ATTACHes, six CHECKs, 84 selected-value rows
across overlapping windows, and 106 unchanged published part files. Generated
bytes and normalized helper observations agree across modes. Disabling LC
replay triggers two unchanged-spec failures; 31 capture/report mutations per
mode are rejected. Scoped verdict: ROBUST.

No leaf serializer per Cartesian type product was introduced. Dynamic/JSON
inside this new direct API remain rejected until their structure-site state is
owned; COMPACT Variant and broader dictionary/layout schedules are unqualified.
This is a direct two-column Wide API, not automatic OfflineTable dispatch.
Full types, MV/projections and repository-wide class decomposition remain
open; performance stays deferred and the overall goal is incomplete. Details:
[NESTED_BULK_PART_FRONTIER.md](NESTED_BULK_PART_FRONTIER.md),
`.landmark/evidence/nested-bulk-parts-w202.json`.

Previous finite kernel frontier (W201, 2026-10-06): recursive Nested now reuses
the Array/implicit named Tuple cardinality law for LowCardinality staging and
occurrence census. Eight blanket specialized-Nested call-site guards were
removed; existing illegal child, explicit Dynamic-site, JSON/QBit and budget
boundaries remain. No serializer per Cartesian type product was introduced.

The same 144 affected files, including nine new W201 examples, pass 944 DEBUG
and 944 RELEASE examples, zero failures/errors/pending, actual guarded exits 0.
Fresh helpers in each mode decode four stock-created Wide Nested/Array(Tuple)
LC(Nullable(String))+String profiles, checking full/empty/later/final/zero mark
windows against literals. Root authenticates raw captures and 32 native value
observations per mode; all 80 part files per mode remain unchanged. Both modes
agree. A seeded census defect causes five runtime errors; six mutated reports
and a wrong expected native NULL literal are rejected. Scoped verdict: ROBUST.

This is recursive bulk read/write and stock-to-kernel qualification, not a new
public complete-part writer certificate. At that frontier the top-level Wide
Nested writer remained narrower; native Variant/Dynamic specialized parts, broader dictionary,
legacy/Compact/flattened layouts and JSON-as-Dynamic-actual remain open.
Full types, MV/projections and repository-wide class decomposition remain open;
performance stays deferred. Details:
[NESTED_SPECIALIZED_BULK_FRONTIER.md](NESTED_SPECIALIZED_BULK_FRONTIER.md),
`.landmark/evidence/nested-specialized-bulk-w201.json`.

Previous finite complete-part frontier (W200, 2026-10-06): public writer and
reader compose direct QBit actuals at root JSON shared paths, using existing
scalar/bulk/Object owners. Only two paired direct-QBit admission guards changed;
no serializer per recursive type product or new transpose algorithm was added.

Final focused DEBUG passes 33 examples; the same exact 138 affected files pass
901 DEBUG and 901 RELEASE examples, zero failures/errors/pending, actual serial
guarded exits 0. The final 948-file source/spec identity remains unchanged across
these gates, fresh helper builds and native captures. Each mode qualifies 48
stock/library Wide profile pairs: four carriers, three dimension/stride shapes,
shared versions 2/3 and String 0/1. Persisted empty typed/dynamic rosters prove
the shared-only route. Public full/middle/zero mark reads preserve raw bits,
nominal type and missing versus present-zero values.

Both native modes ATTACH/CHECK all 48 library parts and re-CHECK the stock
parts. Each whole/type/direct family has 864 observations (288 initial stock
plus 576 attached stock/library), not 864 distinct fixture rows. Root checks
raw process/SQL/file provenance, independent literal payloads, 18 semantic
mutations per mode and single/duplicate-capture controls. Normalized helper
reports and all 2016 generated files agree across modes. All 4080 published
stock/generated files remain unchanged. Native ATTACH's only allowed addition
is the exact 28-byte invalidated-system-columns metadata file on library parts;
the full active snapshots remain stable. Scoped verdict: ROBUST.

Recursive composition is the implementation model. Remaining work is legal
container storage contracts and their qualification, not a Cartesian product
of new leaf serializers: specialized wrappers/sites, JSON-as-Dynamic-actual,
broader layouts and MV/projections. Illegal ClickHouse nesting is a different
boundary from a library guard on a legal but unqualified layout. Static QBit
wrappers, declared typed-QBit Object paths and borrowed-envelope guards remain.
Full types, MV/projections and repository-wide class decomposition are still
open; performance stays deferred and the overall goal remains incomplete.
Details: [OBJECT_SHARED_QBIT_PARTS_FRONTIER.md](OBJECT_SHARED_QBIT_PARTS_FRONTIER.md),
`.landmark/evidence/object-shared-qbit-parts-w200.json`.

Previous finite internal-adapter frontier (W199, 2026-10-06): owned direct QBit
Dynamic scalar envelopes and ordinary direct QBit actual arms at admitted
Dynamic sites reuse existing QBit codecs across recursive bulk planning,
physical binding and Object shared-path Data serde. One per-site owner keeps
numeric planes, nominal identity and cumulative admission bounds; no serializer
per recursive product or second bit transposition algorithm was introduced.

Final focused DEBUG passes 29 examples; the same 136 affected files pass 897
DEBUG and 897 RELEASE examples, zero failures/errors/pending, actual serial
guarded exits0. The final 946-file source/spec identity remains unchanged
across these gates, fresh helper builds and native runs. Each mode inspects
48 stock Wide profiles (four QBit carriers, three dimension/stride shapes,
shared versions2/3, String0/1), authenticates 120 path records, 288 bucket/chunk
schedule records and 288 direct typed native rows, and preserves all 2064 source
part files. Independent literal planes, raw process/SQL/file provenance and
11 report/output mutations per mode qualify the finite scope; normalized
DEBUG/RELEASE observations agree. Scoped verdict: ROBUST.

This is not a public library-written QBit-in-JSON complete-part certificate:
no library part ATTACH/CHECK was executed. Direct static QBit wrapper and
borrowed/SharedVariant guards remain. Zero-row selection validates metadata
and shape, not unselected discriminator/value bodies. Next: public complete
QBit actual parts, then remaining recursive physical contracts and
JSON-as-Dynamic-actual storage. Full types, broader MV/projections and
repository-wide class decomposition remain open; performance stays deferred.
Details: [OBJECT_SHARED_QBIT_FRONTIER.md](OBJECT_SHARED_QBIT_FRONTIER.md),
`.landmark/evidence/object-shared-qbit-w199.json`.

Current finite complete-part frontier (W198, 2026-10-06): public writer and
reader compose ordinary Nested actuals and an Array(named Tuple) control in
root JSON shared ADVANCED v2 / CHUNKED v3, String profiles 0/1. No production
change or serializer per recursive product was needed. The existing writer's
always-spill policy preserves nominal type and stock direct-path readability;
it does not reproduce ClickHouse's insertion/merge roster-selection policy.

Focused DEBUG passes 16 examples; the same 130 affected files pass 857 DEBUG
and 857 RELEASE examples, zero failures/errors/pending, actual exits 0. The
943-file source/spec identity remains unchanged across final gates. Fresh
helpers create eight Wide parts per mode with the public writer, without
post-publication lane replacement, then read all stock/library parts through
public full/middle/zero mark windows. Prefix versions and String profiles are
authenticated from persisted metadata, not echoed fixture labels.

Both native modes ATTACH/CHECK eight generated parts, re-CHECK eight stock
parts, compare 128 full / 64 middle whole-Object rows and 192 independent typed
path rows per mode, and authenticate zero selections, persisted PKs and nominal types.
Root reconciles raw process/byte provenance and 680 unchanged files per mode;
all 336 generated files and normalized helper observations agree between modes.
Eight oracle mutations per mode and single/duplicate-capture controls reject.
Scoped verdict: ROBUST for this finite corpus, not all recursive products.

Next after W199's internal QBit adapter: public QBit complete-part certificates,
then remaining specialized wrapper/site schedules and JSON-as-Dynamic-actual
storage. Full types, broader MV/projections and repository-wide one-class-per-file
decomposition remain open. Performance stays deferred; the overall goal is
incomplete. Details: [OBJECT_SHARED_NESTED_FRONTIER.md](OBJECT_SHARED_NESTED_FRONTIER.md),
`.landmark/evidence/object-shared-nested-parts-w198.json`.

Previous finite internal frontier (W197, 2026-10-06): ordinary Nested actual
arms now compose the existing Array/implicit named Tuple owners across Dynamic
bulk planning, physical stream binding and Object shared-path prefix/body
serde. The nominal Nested descriptor is preserved; no serializer per recursive
type product was introduced. Specialized Nested children (LowCardinality,
Variant, Dynamic) and QBit/JSON actual-path guards remain unchanged.

Focused DEBUG passes 20 examples. The same 129 affected files pass 855 DEBUG
and 855 RELEASE examples, zero failures/errors/pending, actual exits 0, with
unchanged 942-file source/spec identity across final gates. Fresh helpers in
both modes read two stock Wide CHUNKED v3 parts (Nested and Array(named Tuple)
control), preserve populated/pathless/empty rows and re-encode four Data/event
records per mode byte-for-byte. Root authenticates literal bytes, callbacks,
nominal identity and schedules; four report mutations per mode are rejected.
Both reports are identical and all 86 source part files remain unchanged.
Separate stock CHECK, whole-Object, dynamicType and direct-path queries pass.
Scoped verdict: ROBUST for this finite internal adapter corpus, not complete
library-written Nested actual parts or all recursive products.

Next: remaining specialized wrapper/site schedules and their complete-part
read/write certificates, including QBit and JSON-as-Dynamic-actual per-path
storage. Full types, broader MV/projections and repository-wide class
decomposition remain open. Performance stays deferred; the overall goal is
incomplete. Details: [OBJECT_SHARED_NESTED_FRONTIER.md](OBJECT_SHARED_NESTED_FRONTIER.md),
`.landmark/evidence/object-shared-nested-w197.json`.

Previous qualified frontier (W196, 2026-10-06): Object shared-path LowCardinality
reuses the recursive bulk/storage codec with explicit prefix/body callbacks
and an additional-keys-only dictionary policy. Standalone bulk encoding keeps
its part-global default; no serializer per recursive type product was added.
The same 117 affected files pass 772 DEBUG and 772 RELEASE examples, zero
failures/errors/pending, with actual guarded exits 0 and unchanged 941-file
source/spec identity across final suites, fresh helper builds and native runs.

Finite native qualification covers root JSON shared ADVANCED v2/CHUNKED v3,
String profiles 0/1, actual LowCardinality(String) and Array(LC(UInt8)) paths,
missing paths, empty strings/arrays and default values. Both modes ATTACH/CHECK
eight stock/library Wide parts, compare 64 full and 32 middle whole-Object
rows, authenticate zero selections, and compare 96 independent direct-path
result rows. All 168 generated files and normalized helper observations agree
between modes. Root checks authenticate process/byte provenance and reject
11 mutations per mode plus same-length stdout substitution. Scoped verdict:
ROBUST for this corpus, not all recursive layouts or arbitrary LC schedules.

The native RED demonstrated why base serde alone is insufficient: Copy and
CHECK passed while direct path reads failed. JSON's aliased Compact-style Data
getter requires LC flags followed by inline additional keys, not concatenated
standalone dictionary/index lanes. The explicit storage policy fixes that
contract while retaining shared scalar encoding, traversal and caller budgets.

The next work at W196 was to qualify remaining recursive physical wrapper
contracts, including Nested, QBit and JSON-as-Dynamic-actual per-path storage.
Its ordinary Object dynamic-path facade guard was a separate boundary, not a
claim that always-spill SharedVariant cannot carry Nested envelopes. Legacy
Dynamic profiles, Compact advanced parts, insertion/merge roster policy, full
types, broader MV/projections and repository-wide class decomposition remained
open. Details: [OBJECT_SHARED_LOW_CARDINALITY_FRONTIER.md](OBJECT_SHARED_LOW_CARDINALITY_FRONTIER.md),
`.landmark/evidence/object-shared-low-cardinality-w196.json`.

Previous qualified frontier (W195, 2026-10-06): paired complete Wide Object
shared ADVANCED/ADVANCED_CHUNKED read/write composes the W192 Copy, W193 path
Data and W194 physical bucket owners. Native qualification is finite: root
JSON and Array(JSON), populated/empty shared storage, versions 2/3, and actual
shared String/NULL values. Both fresh DEBUG and RELEASE runs independently
ATTACH/CHECK 16 parts, compare 128 full and 64 middle rows, verify empty
selections, and compare 192 direct path rows per mode. Whole-object and
independent path reads both pass. All 312 generated files are byte-identical
between modes. The same 106 affected spec files pass 664 examples per mode,
zero failures/errors/pending, actual guarded exits 0.

The native path falsifier exposed a composition defect, not missing String
serde: part metadata advertised String version 0 while child path encoding
used version 1. Explicit profile propagation fixes that boundary without
changing the separate Copy framing selector or blindly bumping typed siblings.
Offline reconciliation now respects exact Object statistics mark boundaries,
stock/library metadata rosters and the producer's two-layer invocation records.
Historical checkpoints below and in the frontier document describe earlier
source states, not the current qualified result.

The next work at W195 was to complete physical wrapper contracts for legal recursive types
and qualify their paired writer/reader branches, including LowCardinality,
Nested, QBit and JSON-as-Dynamic-actual per-path storage. Reuse existing child
codecs; do not enumerate or implement a serializer per type product. Compact
advanced parts, full types, broader MV/projections and repository-wide class
decomposition remain open. Performance is deferred; the overall goal is
incomplete. Details: [OBJECT_SHARED_ADVANCED_FRONTIER.md](OBJECT_SHARED_ADVANCED_FRONTIER.md),
`.landmark/evidence/object-shared-advanced-parts-w195.json`.

Previous internal foundation (W194, 2026-10-06): paired schema-agnostic Wide
six-lane Object shared bucket read/write composes existing path Data/event
tapes, not a scalar serializer per recursive type product. Separate public
owners preserve physical parent rows, logical chunks, paths and actual compressed
coordinates. The named transport position API shares writer frame arithmetic;
query-aware batch preflight, early depth/wire guards, EOF aliases, repeated
callbacks, complete consumption and detached ownership have falsifiers.
The same 100 affected files pass 640 DEBUG and 640 RELEASE examples, zero
failures/errors/pending, actual guard exits 0, with unchanged 927-file src/spec
identity. Fresh helpers authenticate 72 source lanes/eight profiles/12 buckets,
then write and reread two frame schedules under cumulative caller budgets;
all 289 output files per mode are checked and DEBUG equals RELEASE. Independent
pinned native decompression succeeds for all nonempty generated lanes: 208
processes and 1,040 authenticated artifacts. Ruby independently resolves the
recompressed pointers and compares paths, values and callbacks with stock and
authored fixtures. All 33 root controls pass, including same-length native
stdout substitution. Scoped verdict: ROBUST for this finite String/NULL
physical-lane prerequisite, not all recursive products or complete parts.
No full-part ATTACH/CHECK or persisted v2/v3 admission was run; those guards
stay unchanged. Next: combine Copy and physical buckets into paired parts,
then qualify whole-object AND independent path readbacks. Full types, broader
MV/projections and decomposition remain open; performance is deferred and the
overall goal is incomplete. Details: [OBJECT_SHARED_ADVANCED_FRONTIER.md](OBJECT_SHARED_ADVANCED_FRONTIER.md),
`.landmark/evidence/object-shared-physical-w194.json`.

Previous internal foundation (W193, 2026-10-06): paired exact-path Object shared
Data serde composes existing recursive Dynamic/Bulk codecs with an explicit
Compact prefix/body event schedule. Data/tape, getter event, tape reader,
decode result and layout codec have separate files. Named no-statistics-prefix
APIs preserve complete Dynamic metadata and the old public decode arity.
Independent falsifiers cover prefix ordering, ArrayElements levels across
Dynamic arms, escaped BASIC Map TupleElement names, early nested depth guards,
detached ownership and cumulative budgets. The same 95 affected files pass
585 DEBUG and 585 RELEASE examples, zero failures/errors/pending, actual guard
exits 0, with unchanged 911-file source/spec identity across final gates.
Both freshly rebuilt helpers exactly decode/reencode 34 path records from
42 chunks/eight authenticated immutable W191 profiles: 1,347 original Data
bytes, String actual values and NULL, including PLAIN and COMPACT granules.
Ruby separately re-derives values, raw slices and event positions from retained
native evidence, compressed metadata coordinates and W192/authored fixtures.
All 32 final root controls pass, including forged input/output, actual CLI
comparison enforcement and same-length raw SHA substitution. Scoped verdict:
ROBUST for this exact-Data/event prerequisite, not all recursive products.
Wire-work accounting includes intermediate copies and is not file size or RSS.
No new native capture, full-part ATTACH/CHECK or persisted v2/v3 admission was
run. Next: compositional physical lanes and compressed-offset mapping, then
paired complete-part qualification with whole-object AND independent path reads.
Full types, broader MV/projections and decomposition remain open; performance
is deferred and the overall goal remains incomplete. Details and evidence:
[OBJECT_SHARED_ADVANCED_FRONTIER.md](OBJECT_SHARED_ADVANCED_FRONTIER.md),
`.landmark/evidence/object-shared-path-w193.json`.

Previous internal foundation (W192, 2026-10-06): paired exact-chunk Object shared
Copy serde delegates recursive actual values to the existing Dynamic child
codec. Dictionary, detached streams and payload codec have separate files.
Bucket-ordinal dictionaries, per-row UInt64 sizes, implicit index widths,
outer String frames, opaque paths and cumulative caller budgets are checked
before count-derived allocations. Valid-but-unadmitted child types remain
unsupported rather than being mislabeled as corrupt. The same 84 affected
files pass 524 DEBUG and 524 RELEASE examples, zero failures/errors/pending,
actual guard exits 0, with unchanged source/spec identities across both gates.
Fresh helper builds exactly decode/reencode 42 chunks from the authenticated
immutable W191 stock capture: eight profiles, 40 logical rows and 36 entries.
Ruby separately derives chunk slices, binds literals to fixed fixture constants
and authenticated native SQL, and compares both helpers with raw bytes and
authored rows. Read wire is 4,116 bytes including metadata; Copy-only write wire
is 754 bytes. All 26 root controls pass, including mutated raw bytes, reset wire
counters, poisoned values and a real CLI self-test/comparison bypass falsifier.
Scoped verdict: ROBUST for this normalized exact-Copy prerequisite and finite
corpus. Native actual values here are String; recursive unit cases do not
certify every persisted type/layout product. No new native capture or full-part
ATTACH/CHECK was run for W192. Persisted advanced v2/v3 remains rejected.
Next: per-path Data/substream state and compressed-coordinate mapping, then
paired part qualification with whole-object AND independent path reads.
Full types, broader MV/projections and decomposition remain open; performance
is deferred and the overall goal is incomplete. Details and evidence:
[OBJECT_SHARED_ADVANCED_FRONTIER.md](OBJECT_SHARED_ADVANCED_FRONTIER.md),
`.landmark/evidence/object-shared-copy-w192.json`.

Previous internal foundation (W191, 2026-10-06): a detached, byte-ordered Object
shared chunk metadata owner and paired codec compose under one caller-owned
budget. They preserve UInt64 row/transport coordinates, opaque paths, zero-row
records and exact-blob consumption, with count/suffix preflight before path
materialization. Each owner has its own file. The same 82 affected files pass
503 DEBUG and 503 RELEASE examples, zero failures/errors/pending, actual guard
exits 0. Both rebuilt helper modes decode and exactly reencode 64 actual stock
ADVANCED/CHUNKED records across eight root/Array and empty-control profiles.
Root separately reconciles 100 retained invocations, 248 stream-file hashes,
16 available metadata hashes, 92 compressed frames and 3,362 raw structure
bytes against both helper outputs; ten helper controls pass in both modes.
Scoped verdict: ROBUST for this metadata prerequisite and finite capture, not
persisted ADVANCED read/write admission or general part integrity. Other
nonstream metadata is roster/literal checked, not individually hash-certified.
The version-2/3 document guards remain strict. Full paired advanced payload
owners and stock whole-object plus independent path readback are next;
remaining types, broader MV/projections and decomposition stay open.
Performance is deferred and the larger goal remains incomplete. Details:
[OBJECT_SHARED_ADVANCED_FRONTIER.md](OBJECT_SHARED_ADVANCED_FRONTIER.md).

Current qualified capability (W190, 2026-10-06): Object-v3 shared
MAP_WITH_BUCKETS reuses the existing Array(Tuple(String,String)) codec with
explicit per-site 1..256 bucket state, zero-key ClickHouse SipHash64 placement,
checked rejoining and complete physical naming/mark ownership. Version-1
reader binding fanout is preflighted against borrowed node/edge and separate
physical-name budgets before snapshots; MAP-0 and wire accounting are preserved.
The same 81 affected files pass 493 DEBUG and 493 RELEASE examples, zero
failures/errors/pending, actual guard exits 0. Both helper modes read stock and
write parts accepted by stock ATTACH/CHECK for root JSON and Array(JSON) with
2/32 buckets, plus an empty-shared one-bucket control. Direct/table consumers
pass full/middle/zero windows. Root reconciles 26 processes, 52 captures,
20 utility inputs, 1,792 stream files, 240 native/480 Crystal literal rows and
60 schema rows; all 488 generated library files match DEBUG versus RELEASE.
Scoped verdict: ROBUST for these finite normalized hashed Wide/LZ4, plain-mrk2
witnesses and guards. Unit 256-bucket admission is not a native part certificate.
ADVANCED/CHUNKED, other unqualified wrapper/layout products, remaining types,
broader MV/projections and decomposition stay open; performance is deferred
and the larger goal is incomplete. Details and continuation:
[OBJECT_SHARED_BUCKETS_FRONTIER.md](OBJECT_SHARED_BUCKETS_FRONTIER.md).

Previous qualified capability (W189, 2026-10-06): declared typed-Dynamic JSON
lanes now compose BASIC/COMPACT physical discriminator framing with the existing
recursive BinaryBulk serde, including declared Array(Dynamic) and the tested
Variant(Array(Dynamic), String) path. A separate one-class/file framing adapter
bounds expansion before allocation; reads discover mode independently per
physical lane, including zero selections. Actual rosters, site identity,
enclosing occurrence schedules and physical parent rows remain distinct.
The same 72 affected files pass 419 DEBUG and 419 RELEASE examples, zero
failures/errors/pending, actual guard exits 0. Both rebuilt helper modes read
stock and write parts accepted by stock ATTACH/CHECK in BASIC and COMPACT for
one/repeated Array(Tuple(JSON,JSON,UInt64)) profiles with direct and array typed
Dynamic paths, independent rosters, NULL and shared spills. Root separately
reconciles each run's 19 process records, 40 capture hashes/sizes, 16 utility
inputs, 276 stream files, 48 native literal rows and 16 discriminator lanes.
All 154 library files per discriminator mode match DEBUG versus RELEASE.
Scoped verdict: ROBUST for finite normalized hashed Wide/LZ4, plain-mrk2,
Object-v3/one-bucket shared-MAP profiles and tested guards; not every recursive
product, layout or the full suite. The legacy BASIC adapter and dedicated W185
writer remain unchanged. Other wrappers/layouts, remaining types, broader
MV/projections and decomposition stay open; performance remains deferred and
the larger goal is incomplete. Details and continuation:
[OBJECT_TYPED_DYNAMIC_COMPACT_FRONTIER.md](OBJECT_TYPED_DYNAMIC_COMPACT_FRONTIER.md).

Previous qualified capability (W188, 2026-10-06): the common recursive Array/Tuple
JSON path admits COMPACT as well as BASIC child Dynamic discriminators, without
a separate serializer per type combination. A shared non-allocating validator
checks mode-specific framing and preserves physical parent rows separately from
logical child counts. Empty child groups emit no body; persisted mode is read
from bytes rather than inferred from the outer schema. Root and declared typed
Dynamic guards remained strict in that slice; W189 supersedes the declared
typed-Dynamic restriction. The dedicated W185 writer remains BASIC-only.
The same 69 affected spec files pass 404 DEBUG and 404 RELEASE examples with
zero failures/errors/pending and actual child/guard exits 0. Both helper modes
read stock and write parts accepted by stock ATTACH/CHECK in COMPACT and BASIC,
with exact schemas, authored rows and full/middle/zero public-table windows.
Root independently reconciles actual process/capture/stream evidence and stock
plus library COMPACT discriminator literals/physical marks. All 126 COMPACT and
114 BASIC generated library files match between DEBUG and RELEASE; BASIC also
matches W187 byte-for-byte. Scoped verdict: ROBUST for finite normalized hashed
Wide/LZ4, plain-mrk2, Object-v3/one-bucket shared-MAP profiles, not every recursive
product or the full suite. Unselected payload authenticity, RSS bounds and
fresh-master runtime compatibility are not claimed. Typed-Dynamic COMPACT was
the next frontier (now addressed in W189); other wrappers/layouts, remaining
types, broader MV/projections and class
decomposition remain open; performance is deferred and the larger goal is
incomplete. Details and continuation:
[JSON_RECURSIVE_STORAGE_FRONTIER.md](JSON_RECURSIVE_STORAGE_FRONTIER.md).

Previous qualified capability (W187, 2026-10-06): a common recursive owner
composes Array and Tuple edges around JSON sites and existing JSON-free Bulk
leaves. Arrays derive checked incoming/child occurrence schedules while all
lanes preserve root physical mark rows and inherited size levels. Equal nominal
JSON siblings retain independent actual state. The writer, staged publisher,
direct reader and typed table path use this plan; W185's dedicated Array(JSON)
API and W186's root Tuple path remain compatible.
The same 66 selected files pass 392 DEBUG and 392 RELEASE examples with zero
failures/errors/pending and actual child/guard exits 0. Both helper modes read
stock one/repeated-Array Tuple(JSON,JSON,UInt64) parts, and stock ATTACH/CHECK
accepts their library-written counterparts with exact schemas and authored
full/middle rows. Root independently reconciles each mode's three processes,
eight captures, 196 stream-file hashes/sizes and 48 native literal row records;
114 library files match between modes. Scoped verdict: ROBUST for these finite
normalized hashed Wide/LZ4, plain-mrk2, Object-v3/shared-MAP BASIC profiles.
Stock-default COMPACT below Array, other enclosing wrappers/layouts, remaining
types, broader MV/projections and full table decomposition stay open. Logical
owner budgets are not RSS limits; the narrower offline UInt64-PK candidate API
is not widened. The larger goal is incomplete and performance remains deferred.
Details and continuation:
[JSON_RECURSIVE_STORAGE_FRONTIER.md](JSON_RECURSIVE_STORAGE_FRONTIER.md).

Current qualified capability (W185, 2026-10-06): canonical `Array(JSON(...))`
composes the existing Object owners in normalized hashed Wide/LZ4 parts with
plain adaptive marks, one-bucket shared MAP and BASIC child Dynamic mode.
Separate parent rows and child occurrences preserve empty arrays and nonzero
read origins. New column reader/writer/files, staged publisher/metadata and
typed table adapter have separate files; root metadata parsing is shared while
its declaration-first error contract remains unchanged. Batches expose
`array_object_documents_for(column)` without implicit flattening.
The same 46 selected specs pass 296 DEBUG and 296 RELEASE examples in six serial
cohorts per mode, all twelve actual child/guard exits 0. Both rebuilt helper
modes read stock mixed/all-empty parts, publish a part accepted by stock
ATTACH/CHECK, and match authored full/middle rows and exact schema. Root
reconciles six process statuses, 134 hashes and identical values plus all 22
generated library files between modes. Scoped verdict: ROBUST for this finite
slice, not every recursive product or the full suite. Logical codec/grid budgets
remain distinct from bounded metadata/name/transport contexts; they do not cap
RSS or decoder workspace. General persisted wrappers/layouts, remaining types,
broader MV/projections and full table decomposition stay open; performance is
deferred. The larger objective is not complete. Details and continuation:
[JSON_RECURSIVE_STORAGE_FRONTIER.md](JSON_RECURSIVE_STORAGE_FRONTIER.md).

Current internal foundation (W184, 2026-10-06): `StorageOccurrenceGrid` separates
positive physical parent rows from nonnegative logical child counts. Explicit
paired Object/Dynamic/discriminator child APIs reuse existing owners and one
borrowed budget; BASIC child groups may be empty while root guards stay strict.
The physical lane seam keeps parent rows in adaptive marks. Root executes 26
selected specs in three serial cohorts per mode: 181 DEBUG and 181 RELEASE
examples, zero failures/errors/pending, six actual child/guard exits 0. Mixed
and all-empty compressed file pairs reopen with exact bytes/coordinates; a
separate authored probe inspects raw mark rows. Scoped verdict: ROBUST for this
foundation only. Caller-supplied counts are not yet derived from enclosing
offsets/selections; structural site/state/profile ownership, names/discovery,
statistics and complete-part/table wiring remain next. No new stock whole-part
qualification or performance claim. Source pins, evidence, retained compile
failures and continuation:
[JSON_RECURSIVE_STORAGE_FRONTIER.md](JSON_RECURSIVE_STORAGE_FRONTIER.md).

Current investigation (W183): three stock Wide ArrayJSON/root JSON profiles
and five primitive-lane decompressions verify the separate outer-row/child-count
contract, including entirely empty child marks. No Crystal storage gate changes.
The site-aware recursive storage design and exact probe boundaries are in
[JSON_RECURSIVE_STORAGE_FRONTIER.md](JSON_RECURSIVE_STORAGE_FRONTIER.md).

Current qualified capability (W182, 2026-10-06): nominal JSON composes through
the existing recursive scalar visitors beneath Array/Tuple/Map/Nullable/
Variant/Nested, inside JSON typed/runtime paths and as a Dynamic actual type.
Nested path metadata and values share enclosing budgets at rebased depths;
repeated shared owners are charged per occurrence. Upstream child-admission
laws and physical/bulk/borrowed/persisted Object guards remain separate.
The same 47 selected specs pass 335 DEBUG and 335 RELEASE examples in six serial
cohorts per mode, with all twelve actual child/guard exits 0 and no failures/
errors/pending. Root reconciles 1,035 immutable Crystal/Ruby inputs and 1,369
fixture files. Thirty actual helper-output files match between modes; pinned
stock passes 15 paired scalar profiles with 32 successful process records and
222 native artifact/input hash checks. Both helper modes consume and re-encode
actual stock captures. A seeded skipped nested preflight fails four unchanged
guards before exact restoration and final gates. Scoped verdict: ROBUST for
these laws and finite witnesses, not every recursive product, the full suite,
new JSON parts, fresh-master runtime or performance. Remaining persisted
layouts/path semantics, types and broader MV/projections stay open; performance
remains deferred. Exact scope, commands, failed attempts, warning and evidence:
[JSON_NESTED_SCALAR_FRONTIER.md](JSON_NESTED_SCALAR_FRONTIER.md).

Previous capability checkpoint (W181, 2026-10-05): JSON structured scalar paths
reuse the existing recursive codec for LC, Variant, Dynamic, Nested and supported
SimpleAggregateFunction wrappers. Static typed-schema admission is distinct
from runtime tagged admission; static Interval/BFloat16/Nullable(Nothing) and
non-String Map keys are corrected from W180 false admissions, without banning
their represented runtime routes. Wrapper values and Dynamic actual descriptors
share constructor and codec budgets/depth; no physical admission is widened.
The same 42 selected specs pass 309 DEBUG and 309 RELEASE examples in six serial
cohorts per mode; all twelve actual child/guard exits are 0 with zero failures/
errors/pending, 1,000 unchanged Crystal inputs and 1,369 fixture files. Actual
DEBUG/RELEASE outputs match across 31 fixture files. Pinned stock passes 15 paired
scalar profiles and ten exactly classified expected refusals; root reconciles
42 actual process statuses and 243 native artifact/input hashes. Both helper
modes consume and re-encode the actual stock captures. A seeded omitted Dynamic
descriptor visit fails two unchanged constructor guards before exact restoration
and final gates. Scoped verdict: ROBUST for these witnesses and budget laws,
not all recursive products, the full suite, new JSON parts or a fresh-master
runtime build. Nested nominal JSON was open at W181 and is superseded by W182;
persisted layout/state work remains open,
as do remaining types and broader MV/projections; performance remains deferred.
Scope, exact gates, failed attempts, source/runtime pins and evidence decay:
[JSON_RECURSIVE_SCALAR_FRONTIER.md](JSON_RECURSIVE_SCALAR_FRONTIER.md).

Previous capability checkpoint (W180, 2026-10-05): a root nominal JSON v0
descriptor and owned flattened structured RowBinary row now have paired codecs.
Four narrow owners have separate files; typed-path metadata remains distinct
from generic value children and from the older persisted ObjectDocument profile.
Caps retain nominal identity, not scalar cardinality limits. Runtime Nothing
NULL becomes absence; typed Nullable NULL is preserved. The closed child grammar,
shared budget laws and parent/Dynamic/borrowed/bulk/Object refusal boundaries are
explicit, including empty values and zero read windows.
The same 33 selected specs pass 245 DEBUG and 245 RELEASE examples in five serial
cohorts per mode, with all ten actual child/guard exits 0 and zero failures/errors/
pending. Root reconciles 996 unchanged Crystal inputs and 1369 fixture files.
Actual DEBUG/RELEASE encoder outputs match across 15 fixture files. The separately
pinned stock runtime passes seven paired descriptor/row profiles, with 23 actual
exit-zero signal/timeout-free processes and 129 reconciled artifact/input hashes;
both helper modes decode and re-encode the captured stock bytes. An executed
early-bulk-guard bypass fails the unchanged negative assertion; exact restoration
and final focused gates pass. Scoped verdict: ROBUST for these laws and finite
witnesses, not the full repository, every recursive child product, whole JSON
parts or a fresh-source runtime build. General JSON layouts/path/SKIP semantics,
remaining types and broader MV/projections remain open; performance is deferred.
Exact API, stock profiles, failed attempts, guard warning, rosters and decay:
[JSON_BINARY_KERNEL_FRONTIER.md](JSON_BINARY_KERNEL_FRONTIER.md).

Current architecture checkpoint (2026-10-05, VERIFIED within the declared slice):
the first table-facade slice moves seven existing numeric Map row/slice owners
and `WidePartTableBatch` into eight owner-named files, plus one alias-only file.
`WidePartTable` falls from 7,312 to 4,930 lines; Batch remains 2,051 lines.
Root verifies nine byte-identical bodies and unchanged aliases against
`85fb22c`, and an executed owner-copy mutation fails five unchanged assertions
before exact restoration. The same 19 selected regression specs pass 111 DEBUG
and 111 RELEASE examples in seven serial cohorts per mode, zero failures/
errors/pending and all fourteen actual child/guard exits 0. Root independently
reconciles 987 immutable live Crystal inputs and 1,407 unchanged fixture files.
The first larger RELEASE cohort exceeds the unchanged 12-GB guard and is not
counted as green; limits are not relaxed. Scoped verdict: ROBUST for this
eight-owner extraction and selected controls. This is behavior-preserving decomposition,
not new type/storage admission, performance evidence or a completed architecture
refactor. Remaining responsibility seams and exact checks are recorded in
[TABLE_CLASS_DECOMPOSITION.md](TABLE_CLASS_DECOMPOSITION.md).

Current qualified capability (W179, 2026-10-05):
QBit now bridges the existing dedicated reader/writer into nominal binary
descriptors, owned exact-bit values, scalar RowBinary and normalized bulk
planes. Int8/BFloat16/Float32/Float64 admit root QBit and direct Nullable(QBit),
including nondefault stride. Three narrow codec owners have separate files;
the existing plane codec remains the only bit-transposition owner. Container,
Dynamic actual, borrowed/typed Object and Count-argument products stay closed,
including empty selections. The typed Object boundary had an executed RED and
now has narrow plan/read-schema guards.
The separately pinned native runtime passes 24 profiles in each direction,
with all 410 process records and 2,208 copied stock-file hashes reconciled by
root. Fixtures explicitly pin the full existing W103 Wide/LZ4/plain-mark
profile; current-server defaults and per-column serializers are not qualified.
The same 78 selected specs pass 694 examples in DEBUG and 694 in RELEASE,
partitioned into six disjoint serial cohorts per mode. All twelve actual
child/guard exits are 0, with zero failures/errors/pending and 977 immutable
code inputs. Both modes reproduce the 24 native-qualified QBit parts and
63 native-qualified Count parts byte-for-byte. An executed physical-metadata
budget bypass fails the unchanged assertion; exact source restoration and
final gates pass. Scoped verdict: ROBUST for this bridge and finite paired
witnesses, not arbitrary recursive QBit, the full repository or performance.
The W179 source snapshot is clean/shallow/unbuilt `29e0e201`, distinct from
executed stock build `d9bcb5ab`; twelve decisive QBit/Count/descriptor files
are hash-identical to its previous source snapshot. A subsequent source-only
refresh now pins public master `ef037e60` in a separate clean depth-1 checkout.
Root compares six bounded directories and independently hash-checks 24 decisive
JSON/Dynamic/QBit/Count/descriptor owners as unchanged. The new `uniq` state
version and Native version-alignment changes are not a new qualified library
capability. Three stock RowBinary probes expose the final-SKIP-prefix boundary
before generic JSON implementation; they do not qualify a fresh-source build.
See [CLICKHOUSE_SOURCE_REFERENCE.md](CLICKHOUSE_SOURCE_REFERENCE.md) for exact
snapshot, scope, source anchors, observed probe values and decay conditions.
Scope, exact roster, failed profile attempts, guard warning and current evidence:
[QBIT_BINARY_KERNEL_FRONTIER.md](QBIT_BINARY_KERNEL_FRONTIER.md).

Previous capability checkpoint (W178, 2026-10-05): ordinary Count now retains a bounded
canonical argument descriptor instead of a closed three-signature discriminator.
The argument is immutable nominal metadata, not a physical value child; Count
keeps one VarUInt state lane. Separate grammar, canonical parse policy and
aggregate admission owners are loaded, and the shared storage-plan gateway
retains full descriptor identity. `Nullable(Nothing)`'s transformed
`nothingUInt64` identity, noncanonical Decimal-width aliases, Count-containing
arguments and unqualified outer/storage products remain refused.
The native component passes 63 canonical profiles in each direction; root
reconciles all 1,325 statuses and input/output hashes, literal values and runtime
pins. The same 64-spec coverage passes 582 examples in DEBUG and 582 in RELEASE,
each partitioned into four disjoint serial cohorts, with zero failures/errors/
pending, child/guard exit 0 and 970 immutable code-input hashes. The combined
RELEASE compiler exceeded the unchanged 12-GB guard; that attempt is not counted.
Root verifies that both modes' 63 generated parts are byte-identical to the
native-qualified inputs. An executed descriptor-equality bypass fails two
unchanged negative assertions; exact restoration and final gates pass. Scoped
verdict: ROBUST for the declared canonical metadata law and finite paired
witnesses, not all recursive argument products or the complete repository suite.
A fresh clean, unbuilt depth-1 source snapshot is pinned to
`29e0e201c786933171818f17c0fefc2bb11ec0a2`, distinct from executed stock
`26.10.1.1201` / `d9bcb5ab`. Root hash-checks Luna's 16-file comparison with no
differences; this is not a fresh-master runtime certificate. The binary header
reserves removed timezone-bearing Time tags 0x33/0x35, so strictly append-only
type definitions are not an invariant. Remaining paired types/layouts, general
MV/projections, large-facade decomposition and arbitrary-schema writing stay
open; memory/performance is deferred. Scope, commands and continuation:
[AGGREGATE_COUNT_ARGUMENTS_FRONTIER.md](AGGREGATE_COUNT_ARGUMENTS_FRONTIER.md).

Previous capability checkpoint (W177, 2026-10-05): the three exact Count state
signatures now reach ordinary typed table scans, physical-row windows,
whole candidate granules and offline column `.values`. Batches and retained
values preserve the exact nominal BinaryValue descriptor; numeric aliases and
Count projection payloads stay closed. Count-only selection eagerly checks
the hidden UInt64 sibling's name and complete row/mark axes across all parts,
before callbacks. Offline consumers bind the catalog's exact bare two-column
MergeTree DDL and simple UInt64 ORDER BY key, even when no candidates exist.
This is not server Active-state proof, generic aggregate execution/finalization,
a new TUI renderer or whole-scan payload-error callback atomicity.
Root passes 254 DEBUG and 254 RELEASE examples across the same 31 selected
specs, zero failures/errors/pending, actual child/guard exit 0 and immutable
inputs. The independent stock literal oracle checks all three profiles and
165 two-part windows; paired library parts with different mark grids also
pass. A seeded cross-part sibling-name bypass fails exactly the unchanged
negative assertion; exact restoration, source/log and 39-file stock inventory
hash reconciliation pass. Scoped verdict: ROBUST within the declared consumer
profiles, not all AggregateFunction states/layouts. Four responsibility owners
have separate files; large-facade decomposition remains unfinished. Memory/
performance remains deferred. Fresh source `095fae58` is unbuilt and distinct
from the reused executed stock `d9bcb5ab`; no new native writer run is counted.
Exact API, scope, rosters, evidence, decay and continuation:
[AGGREGATE_COUNT_CONSUMERS_FRONTIER.md](AGGREGATE_COUNT_CONSUMERS_FRONTIER.md).

Previous capability checkpoint (W176, 2026-10-05): the three W175 nominal Count
profiles now have paired complete Wide/LZ4 parts with one sorted UInt64 key.
The dedicated reader consumes canonical VarUInt states independently per mark,
verifies bounded Count frame checksums before decoding and limits one public
call to 65,536 rows. The writer checks input identity/order/limits, then staged
metadata, key/index axes and nominal/value readback before exclusive publication.
Five cohesive Count owners have separate files (storage plan, state decoder,
serialization profile, stream writer, staged validator); existing facade
visibility and other aggregate refusal boundaries remain intact.
Root passes 89 DEBUG and 89 RELEASE examples across the same ten selected specs,
zero failures/errors/pending, actual child/guard exit 0 and immutable inputs.
Two fresh native runs reconcile 142 actual pinned-stock statuses and exact
full/middle/empty values/schema/part axes; DEBUG/RELEASE output parts are
byte-identical. CHECK-valid 128-to-129 values fail the unchanged literal oracle.
Executed staged nominal/value and mark-boundary bypasses fail unchanged guards;
exact restoration passes. Scoped verdict: ROBUST for the explicit profiles,
not all AggregateFunction states, arbitrary schemas/layouts or reader key
provenance. Whole-file checksum verification is not generally implemented by
the existing size-check API; the new integrity guard is Count-frame-specific.
Count table/catalog consumers remain refused. Other aggregate states, recursive
type/layout products, broader SAF, general MV/projections and large-facade
decomposition remain open. Memory/performance remains deferred. Fresh clean
depth-1 source `095fae58` is unbuilt, separate from executed stock `d9bcb5ab`.
Exact commands, scope, evidence, decay and next frontier:
[AGGREGATE_COUNT_WIDE_FRONTIER.md](AGGREGATE_COUNT_WIDE_FRONTIER.md).

Previous capability checkpoint (W175, 2026-10-05): paired logical
`AggregateFunction(count)`, `AggregateFunction(count, UInt64)` and
`AggregateFunction(count, Nullable(UInt64))` now retain nominal identity
through descriptor, known-type scalar/envelope and ordinary normalized bulk
codecs. Version 0/no parameters is the explicit profile; Count's state is
VarUInt, not fixed-width UInt64 or a finalized-column alias. Descriptor
arguments have separate budgeted metadata edges, not physical value children.
Composition, borrowed JSON/shared and Dynamic products remain refused.
Root passes 191 DEBUG and 191 RELEASE examples across the same 31 selected
specs, zero failures/errors/pending and actual child/guard exit 0. Reciprocal
pinned-stock RowBinary checks cover all three profiles and UInt64::MAX; two
executed nominal/borrowed guard bypasses fail unchanged assertions, and exact
restoration/input/log-hash reconciliation passes. Scoped verdict: ROBUST for
canonical logical bytes, not all stock-accepted malformed inputs or complete
parts. The 49-line nominal and 37-line state owners each have their own file.
Count Wide parts/writer, table/catalog consumers and other aggregate states
are next; broader recursive/layout types, general MV/projections and arbitrary
schema writing remain open. Overall modularization is unfinished and memory/
performance stays deferred. Fresh source `095fae58` is unbuilt and separate
from the executed stock build `d9bcb5ab`. Exact boundary, roster, evidence,
decay and continuation:
[AGGREGATE_COUNT_FRONTIER.md](AGGREGATE_COUNT_FRONTIER.md).

Latest architecture checkpoint (R1, 2026-10-05): staged scalar/nullable numeric
Array validation now has one private stateless 106-line class/file. Both
private writer signatures and public calls remain unchanged; the retained
writer remainder is byte-identical to `7251c05`, with only three helper-call
substitutions in the moved bodies and one loader require. Root passes 225
DEBUG and 225 RELEASE examples across 25 selected specs, zero failures/errors/
pending and actual child/guard exit 0. An executed comparison-bypass control
fails both negative mark-readback assertions; exact restoration, input-hash
reconciliation, formatting and diff checks pass. Scoped verdict: ROBUST for
this ownership move, not new type/runtime or performance qualification.
Writer/reader/table/offline facades were 25,662/16,284/7,222/1,560 lines;
overall decomposition is unfinished. The W175 AggregateFunction admission
RED spec was excluded from R1; its later qualification is recorded above.
Fresh source `095fae58` is separately cloned, clean/shallow and unbuilt;
source comparison is not a new stock-runtime certificate. Memory/performance
remains deferred. Scope, rosters, commands and decay:
[MODULARIZATION_FRONTIER.md](MODULARIZATION_FRONTIER.md#active-architecture-cleanup--r1).

Previous capability checkpoint (W174, 2026-10-05): W173's explicit flattened
`Nested` profile now has typed table and separate offline DDL-bound consumers.
The caller-bound UInt64 key and nominal root/type are validated across every
selected part, including group-only and key-only selection. Full/window scans,
bounded owned column `.values` and conservative UInt64-PK candidate granules
reuse existing kernels; legacy numeric scans explicitly refuse the bound view.
Ordinary unbound APIs and W173's paired part writer are unchanged. Exact
two-column MergeTree DDL admission is not implicit Nested provenance or proof
of server Active state; concurrent rewrites and general schema writing are not
qualified.
Root passes 212 DEBUG and 212 RELEASE examples across the same 37 unique specs,
zero failures/errors/pending and actual child/guard exit 0. The independent
literal consumer oracle checks 255 values/metadata/window/candidate relations
on the unchanged 23-file stock-authored part. A one-field numeric control first
fails before the entry guard is added; ordinary numeric and contextual typed
positive controls pass afterward. A seeded expected-key bypass fails the
unchanged assertion and exact source restoration passes. Scoped verdict:
ROBUST within the explicit consumer boundary and finite three-leaf stock
witness, not every leaf/layout product. No new native writer run is counted.
The 57/46-line context/DDL owners each have their own file; physical parsing
and materialization remain with existing owners. Reader/writer/table/offline
facades remain 16,284/25,705/7,222/4,049 lines; overall architecture cleanup is
unfinished. Implicit discovery, specialized Nested products, broader JSON/
Dynamic/Variant layouts, AggregateFunction states, broader SAF, general MV/
projection execution/storage and arbitrary-schema writing remain open.
Memory/performance stays deferred. Fresh source `e9b645ed` is clean/shallow/
unbuilt; the stock fixture was authored by separately pinned build `d9bcb5ab`.
Exact scope, commands, evidence and decay:
[FLATTENED_NESTED_CONSUMERS_FRONTIER.md](FLATTENED_NESTED_CONSUMERS_FRONTIER.md).

Previous capability checkpoint (W173, 2026-10-05): explicit flattened `Nested`
part reading/writing is paired for one UInt64 key and one group of direct
scalar/Nullable leaves in Wide/LZ4. The caller supplies the root and nominal
type; exact physical sibling order and shared size0 references are validated
before constructing an in-memory view. PK-only opening validates the full
group envelope and key/root mark axes; ordinary readers are not widened.
The existing ragged codecs, bounded preflight, staged semantic readback and
exclusive publication are reused. This is not implicit Nested provenance,
arbitrary-table admission or a concurrent-rewrite snapshot guarantee.
Root passes 99 DEBUG and 99 RELEASE examples across 24 focused specs, zero
failures/errors/pending and actual child/guard exit 0. The pinned stock
runtime accepts the stock control, independent library base and CHECK-valid
value mutant through ATTACH/CHECK. Root independently reconciles 66 actual
native statuses, 50 exact sibling/reconstructed binary windows and three
CHECK results. The unchanged unflattened mode also passes: 41 statuses,
25 binary windows and three CHECK results. A seeded key/root axis bypass
fails the unchanged guard; exact source restoration passes. Scoped verdict:
ROBUST for this declared part profile, with a finite three-leaf native witness,
not every inherited leaf/layout product. All-empty element marks and an empty
first mark followed by a nonempty mark retain library-only evidence.
One 249-line storage-plan owner keeps flattened metadata policy separate;
reader/writer/table facades remain 16,284/25,705/7,175 lines. Overall
modularization is unfinished. Explicit table/offline group-context mapping is
next; general JSON/Dynamic/Variant products, AggregateFunction states, broader
SAF, general MV/projection execution/storage and arbitrary-schema complete-part/
table writing remain open. Memory/performance stays deferred. Fresh source
`e9b645ed` is clean, shallow and unbuilt; executed stock is separately pinned
to `d9bcb5ab`. Exact scope, commands, evidence and decay:
[FLATTENED_NESTED_STORAGE_FRONTIER.md](FLATTENED_NESTED_STORAGE_FRONTIER.md).

Previous capability checkpoint (W172, 2026-10-05): nominal `Nested(...)` is
paired through the reusable binary descriptor, known-type row/envelope,
ordinary logical bulk and physical-name APIs. Exact field metadata and the
implicit named-Tuple child stay distinct from Array(Tuple); synthetic graph
nodes/edges share descriptor and envelope limits. Both String profiles,
ordinary recursive Nested/Array/Tuple/Map products, hidden Nullable Tuple
defaults and nonzero/empty mark windows have library coverage. Products
combining Nested with LC/Variant/Dynamic bulk remain explicitly refused,
including actual Nested Dynamic rosters in both directions. The bounded
W171 complete-part writer profile is unchanged.
Root passes 286 DEBUG and 286 RELEASE examples across 39 focused specs,
zero failures/errors/pending and actual child/guard exit 0. Root reconciles
nine pinned stock processes, six exact native input/output buffers and two
distinct descriptors against library-authored bytes and decoded values.
Six stock-created payload lanes, K+1 offsets and four mark windows match.
A seeded synthetic-node budget bypass fails an unchanged assertion; exact
restoration passes. Scoped verdict: ROBUST within the ordinary logical
profile and finite three-leaf native witnesses, not every native child/layout
product. Entirely empty marks and recursive products retain library-only
evidence. Flattened shared Nested offsets remain open.
The 34-line invariant owner has its own file; existing leaf/carrier codecs
are reused. Reader/writer/table facades stay 16,221/25,676/7,175 lines;
overall modularization is unfinished. JSON/Dynamic/Variant layout widening,
AggregateFunction states, broader SAF, general MV/projection execution/storage
and arbitrary-schema complete-part/table writing remain open. Memory and
performance stay deferred. Fresh source `e9b645ed` is clean, shallow and
unbuilt; executed stock remains separately pinned to `d9bcb5ab`.
Exact commands, scope, evidence and decay:
[NESTED_BINARY_FRONTIER.md](NESTED_BINARY_FRONTIER.md).

Previous capability checkpoint (W171, 2026-10-05): nominal unflattened
`Nested(...)` is paired for one sorted UInt64 key and one payload in Wide/LZ4
parts. The inherited named recursive Tuple/scalar-leaf profile reuses the
existing ragged physical reader/writer; exact Nested identity is retained
instead of presenting it as Array(Tuple). Explicit part reader/writer,
table full/window batches and offline column `.values` are available.
Array(Tuple)-only and scalar Tuple accessors remain separate. One aggregate
source/depth/node budget includes the implicit Array/Tuple nodes; existing
row/element/logical-byte limits, child axes and staged exclusive publication
remain enforced.
Root passes 86 DEBUG and 86 RELEASE examples across 22 focused specs, with
zero failures/errors/pending. The stock-only source law captures all three
Nested flatten=0/1 and Array(Tuple) profiles; actual public paired admission
remains flatten=0 only. Stock ATTACH/CHECK accepts the independently authored
library base and CHECK-valid value mutant, plus a stock control; root
independently reconciles 41 native statuses and 25 exact binary windows.
Actual pre-fix nominal-consumer RED and seeded nominal/value staged-comparison
failures qualify the refusal gates. Scoped verdict: ROBUST within the finite
three-leaf whole-part witness, not every inherited schema/profile product.
Empty rows have native evidence; entirely empty marks/children have library
spec evidence only. Flattened shared-offset groups and general Nested logical
binary descriptor/value/bulk support remain open.
The nominal plan and metadata profile each have their own 30/64-line file;
the explicit reader seam is a 58-line extension. They reuse the existing
physical kernel rather than adding per-child classes. Reader/writer/table
facades remain 16,221/25,676/7,175 lines: overall architecture cleanup is
unfinished. The next neutral candidate remains Array-numeric staged validation.
General JSON/Dynamic/Variant profiles, AggregateFunction states, broader SAF,
general MV/projection execution/storage and arbitrary-schema table writing
remain open; memory/performance is deferred. Fresh source `e9b645ed` remains
clean, shallow and unbuilt, distinct from executed stock build `d9bcb5ab`.
Exact scope, commands, evidence and decay:
[NESTED_STORAGE_FRONTIER.md](NESTED_STORAGE_FRONTIER.md).

Previous capability checkpoint (W170, 2026-10-05): canonical unary, non-parametric
SimpleAggregateFunction(any/anyLast/min/max, temporal leaf) is paired across
descriptor/value/bulk/physical codecs, explicit scalar/outer-Nullable Wide
writers/readers, table batches/windows and offline column `.values`.
The six families are Date, Date32, DateTime, DateTime64, Time and Time64;
function, exact leaf/scale/timezone token, signed raw carrier and shape remain
nominal. Ordinary temporal/primitive accessors and inferred writers stay
closed to SAF. The other five canonical functions refuse temporal children
under an independently measured stock construction law, not width inference.
Scales 0..9 and the inherited bounded timezone grammar are admitted; native
witnesses cover 36 finite leaf forms, four functions and two shapes (288
profiles), not every timezone/layout. This is raw stored-value access, not
calendar conversion or aggregation execution.
Root passes 503 DEBUG and 503 RELEASE examples in three disjoint groups per
mode (43 unique specs), plus two actual native examples. All positive
children/guards exit 0 with zero failures/errors/pending. Stock accepts all
288 independently library-authored complete parts through ATTACH/CHECK;
864 literal full/middle/empty RowBinary windows and all 289 native descriptors
match. Three CHECK-valid timezone/scale/value mutants fail the unchanged
original oracle. Independent native reconciliation matches 10,360 checks over
322 raw processes; the separate construction law reconciles 650 checks over
368 processes (288 accepted descriptors, 360 classified refusals and two
forbidden-Time-timezone controls). Root independently reconciles final gate
rosters/logs and all 358 current source/spec/support/page/script inputs.
Separate scalar/Nullable staged-comparison bypasses each fail as intended;
exact restoration passes five runtime examples. Scoped hostile verdict:
ROBUST within this canonical logical stored-value profile. Size/presence
checks do not certify content hashes; canonical bytes under NULL and
whole-scan atomicity are not claimed.
Shared temporal leaf, storage-plan and private stateless staged-validator
owners have separate 108/140/167-line files. Reader/writer/table facades remain
16,174/25,647/7,152 lines; overall architecture cleanup is unfinished. The
next bounded neutral extraction candidate is the Array-numeric validator
cohort. Broader SAF products, AggregateFunction states, shared Nested offsets,
additional JSON/Dynamic/Variant layouts and general MV/projections remain
open; memory/performance stays deferred. Fresh source `e9b645ed` is clean,
shallow and unbuilt; executed stock remains separately pinned to `d9bcb5ab`.
Exact scope, commands, evidence and decay:
[SIMPLE_AGGREGATE_TEMPORAL_FRONTIER.md](SIMPLE_AGGREGATE_TEMPORAL_FRONTIER.md).

Previous capability checkpoint (W169, 2026-10-05): canonical unary, non-parametric
SimpleAggregateFunction with Decimal32/64/128/256 storage is paired through
descriptor/value/bulk/physical codecs, explicit scalar/outer-Nullable Wide
writers/readers, table batches/windows and offline column `.values`.
Original precision/scale, carrier, function and shape remain exact; ordinary
Decimal/primitive accessors and inferred writer admission stay closed to SAF.
Any/anyLast/min/max/sumWithOverflow admit all four carriers; sum admits only
Decimal128/256. The API accepts canonical P=1..76, S=0..P; native witnesses
cover 23 finite P/S coordinates at width/precision boundaries, not every P/S.
Root passes 206 DEBUG and 206 affected RELEASE examples in three disjoint
groups per mode (33 unique specs), plus two actual native examples. All
positive children/guards exit 0 with zero failures/errors/pending. Stock
ATTACH/CHECK accepts all 254 independently library-authored complete parts;
762 literal full/middle/empty RowBinary windows and all 255 native descriptors
match. Three CHECK-valid nominal/value mutants fail the original oracle.
Independent root reconciliation matches 7,778 checks over 2,319 raw statuses,
and all 344 final source/spec/support/page/script inputs match current files.
Separate scalar/Nullable staged-comparison bypasses each fail as intended;
exact restoration passes six runtime examples. Scoped hostile verdict:
ROBUST within this canonical stored-value profile, not aggregation execution.
Raw signed coefficients retain their complete carrier bits; no text-domain
10^P magnitude guarantee or canonical bytes beneath NULL is claimed.
The Decimal plan and private staged validator have separate 119/171-line
owner files. At W169 the reader/writer/table facades were 16,134/25,536/7,095
lines; overall architecture cleanup, temporal/broader SAF profiles,
AggregateFunction states, shared Nested offsets, additional JSON/Dynamic
layouts and general MV/projections remained open. Memory/performance remains
deferred. Fresh source
`e9b645ed` is clean, shallow and unbuilt; executed stock is separately pinned
to `d9bcb5ab`. Exact scope, commands, evidence and decay:
[SIMPLE_AGGREGATE_DECIMAL_FRONTIER.md](SIMPLE_AGGREGATE_DECIMAL_FRONTIER.md).

Previous capability checkpoint (W168, 2026-10-05): canonical unary, non-parametric
SimpleAggregateFunction(any/anyLast/min/max, String/FixedString(N)) is paired
through descriptor/value/bulk codecs, public scalar/outer-Nullable Wide-part
writer/reader, table batches/windows and offline column `.values`. Exact
function, child width and outer shape remain nominal; ordinary text accessors
and inferred writer admission do not widen. Library FixedString width is
1..65536; finite stock whole-part qualification covers String and widths
1, 3, 130 across all four functions and both shapes, not every width/layout.
Root passes 290 DEBUG and 290 affected RELEASE examples in four disjoint
groups per mode (33 unique specs), plus two actual native-fixture examples.
All counted gates have zero failures/errors/pending and actual child/guard
exit 0. Stock accepts 32 independently library-authored complete parts through
ATTACH/CHECK; root recomputes 216 literal checks and three CHECK-valid negative
controls without importing the worker oracle. Four additional complete String
parts establish all-empty/all-NULL EOF zero and nonzero trailing-empty marks
against stock, with 24 independent profile literal checks. All 341 final
source/spec/support/page/script inputs reconcile with current files.
An intentionally bypassed staged-value comparison fails; exact restoration
passes. Scoped hostile verdict: ROBUST within this stored-value profile.
Staged certification checks visible semantics, marks/metadata and raw lengths,
not content hashes or canonical bytes beneath NULL. Numeric SAF admission is
unchanged; at that checkpoint Decimal/temporal SAF, other functions and broader
products remained open.
The new text storage-plan and staged-validator owners each have their own file;
reader/writer/table facades are still 16,017/25,377/7,015 lines. Architecture
cleanup, remaining paired types and general MV/projections remain open.
Memory/performance stays deferred. Source `e9b645ed` is a clean unbuilt shallow
checkout, separate from executed stock build `d9bcb5ab`. Scope, exact commands,
evidence and decay:
[SIMPLE_AGGREGATE_TEXT_FRONTIER.md](SIMPLE_AGGREGATE_TEXT_FRONTIER.md).

Latest behavior-preserving architecture checkpoint (W167, 2026-10-05): scalar and outer-Nullable
FixedString staged validation now belongs to one private, stateless 127-line
`StagedFixedStringPartValidator` class in its own file. Both private facade
signatures, public call sites, direct virtual WidePart readbacks, exact width,
NULL-map, zero-padding and index checks retain their existing order.
The complete retained writer remainder is byte-identical to `061db28` after
excluding the two sealed definitions; moved bodies are exact after only
the declared synchronous callback substitutions. I/O, staging, metadata,
checksums and publication/cleanup remain with their existing owners.
Root passes 147 DEBUG and 147 affected RELEASE examples (15 unique specs per
mode, two disjoint groups), all with zero failures/errors/pending and actual
child/guard exit 0. Logs, rosters and all 317 current source/spec/support/page
inputs independently reconcile. A temporary comparison-loop bypass produces
two intended trace failures; exact restoration passes. Scoped hostile verdict:
ROBUST within this ownership move. Format/diff checks pass; no new type/API,
native-format, crash recovery or performance claim is admitted.
Reader/writer/table facades remain 15,845/25,241/6,911 lines. The larger
architecture refactor, remaining type/layout products and general MV/projection
support remain open; memory/performance stays deferred. Exact scope, commands,
consumer inventory and refresh conditions:
[MODULARIZATION_FRONTIER.md](MODULARIZATION_FRONTIER.md).

Previous architecture checkpoint (W165, 2026-10-05): scalar and Nullable(String)
staged validation now belongs to one private, stateless 100-line
`StagedTypedStringPartValidator` class in its own file. Same-signature facade
entry points, direct virtual WidePart readbacks, exact nominal guards, mark
comparisons and primary-index checks retain their existing order. The complete
writer remainder is byte-identical to `74c53b1` after excluding the two sealed
method definitions; moved bodies are exact after the three declared callback
substitutions. Staging, I/O ownership, metadata/checksums and publication/cleanup
remain with their existing owners. No new type/API/layout is admitted.
Root passes 44 DEBUG and 189 affected RELEASE examples (16 unique RELEASE
specs, three disjoint groups), all with zero failures/errors/pending and
actual child/guard exit 0. Independent reconciliation matches all 316 current
source/spec/support inputs. Temporary readback and comparison bypasses each
produce two intended trace failures; exact restoration passes. One initially
invalid type-guard fixture was corrected to use valid opposite profiles;
its failed candidate is not counted as positive or seeded-control evidence.
Scoped hostile verdict: ROBUST for this exact behavior-preserving ownership
move and its affected writer/table/MV/projection/catalog consumers. No new
stock or benchmark run was performed. At W165 the reader/writer/table facades
remain 15,845/25,313/6,911 lines; the overall architecture cleanup remains open.
Remaining paired types and general MV/projection support are unchanged;
memory/performance stays deferred. Scope, commands, inventory and decay:
[MODULARIZATION_FRONTIER.md](MODULARIZATION_FRONTIER.md).

Previous capability checkpoint (W164, 2026-10-05): the five remaining raw numeric
SimpleAggregateFunction carriers are paired in the finite canonical-function
matrix: UInt128, Int128, UInt256, Int256 and BFloat16. This adds 41 scalar pairs /
82 with outer Nullable; the combined admitted matrix is 118 scalar pairs /
236 scalar-and-Nullable profiles. Exact function, child carrier and outer shape
survive the descriptor, value/bulk/physical, public Wide writer/reader,
table-window/batch and offline column-value paths. BFloat16 sum and bitwise
functions remain refused. Ordinary primitive accessors and inferred typed-writer
admission do not silently widen; exact SAF preflight is separate from inference.
Root passes 60 focused DEBUG and 873 affected RELEASE examples (82 unique specs,
eleven disjoint groups), plus two actual native-fixture examples. All final
counted gates have zero failures/errors/pending and actual child/guard exit 0.
Pinned stock ATTACH/CHECK accepts all 82 newly library-authored complete parts.
Root independently recomputes 246 library and three native literal RowBinary
windows, 83 native type descriptors and two CHECK-valid negative controls.
The 1,121 source/spec/script inputs reconcile with the final code. An exact
reader-carrier bypass yields four expected failures; restoration passes.
The earlier inferred-writer regression was fixed without revising its legacy
refusal tests. Scoped hostile verdict: ROBUST within this finite stored-value
profile, not aggregation execution or all SimpleAggregateFunction types.
The separate shallow source checkout is clean at `41b7bd50` and unbuilt;
executed stock build remains separately pinned at `d9bcb5ab`.
At W164 the reader/writer/table facades have 15,845/25,362/6,911 lines;
overall architecture cleanup, additional type/layout profiles and general
MV/projection coverage remain open. Memory/performance stays deferred.
Exact evidence, inventory and decay conditions:
[SIMPLE_AGGREGATE_EXTENDED_NUMERIC_FRONTIER.md](SIMPLE_AGGREGATE_EXTENDED_NUMERIC_FRONTIER.md).

Previous capability checkpoint (W163, 2026-10-04 local / 2026-10-05 UTC):
the numeric SimpleAggregateFunction paired frontier is VERIFIED within its
finite stored-value profile. Ten standard carriers now retain
exact canonical function/carrier/shape identity through descriptors, values,
bulk/physical codecs, scalar/outer Nullable public part writers/readers,
table batches/windows and offline column values. The finite ClickHouse law
admits 77 scalar pairs, 154 including outer Nullable; invalid narrow `sum`
and floating bitwise pairs are not silently converted.
Root passes 62 focused DEBUG and 785 affected RELEASE examples (68 unique
specs in nine disjoint groups), with zero failures/errors/pending and exit 0.
Two additional native-fixture examples pass. Actual log summaries, membership
and all 738 source/spec/script inputs reconcile with the final code; separate
scalar/Nullable carrier bypasses each fail and exact restoration passes.
Pinned stock accepts all 154 independently library-authored complete parts
through ATTACH/CHECK. Root separately confirms 462 literal library RowBinary
windows, three native windows, all 155 native binary type descriptors and
two CHECK-valid nominal/value mutants rejected by the unchanged oracle.
Scoped hostile verdict: ROBUST within this finite matrix. Fresh shallow source
`41b7bd50` is unbuilt, distinct from executed pinned stock build `d9bcb5ab`.
Raw wide integers, BFloat16, additional functions/carriers, inner Nullable
children and broader wrapper/layout products remain separate. This is
stored-value interoperability, not aggregation execution. It reuses the
existing cohesive owners rather than adding a class per function/type pair.
The current reader/writer/table facades have 15,829/25,288/6,901 lines;
overall architecture cleanup, general MV/projections and all-type completion
remain open. Memory/performance stays deferred. Exact evidence and exclusions:
[SIMPLE_AGGREGATE_NUMERIC_FRONTIER.md](SIMPLE_AGGREGATE_NUMERIC_FRONTIER.md).

Previous architecture checkpoint (W162 at `c0d4c51`, 2026-10-04 local / 2026-10-05 UTC):
scalar and nullable typed-numeric staged validation now has one private,
stateless `StagedTypedNumericPartValidator` owner in its own 150-line file.
Same-signature facade entry points and shared helpers retain semantic-reader
dispatch, bit-exact comparison, canonical Bool guards and validation order.
Scalar primary-index validation remains inline; nullable validation calls the
existing shared helper. The writer remainder is byte-identical to `acae96b`
after excluding the two sealed method definitions, and the moved bodies are
exact after the declared callback substitutions.
Root passes 9 DEBUG and 179 RELEASE examples (27 unique RELEASE specs in five
disjoint groups), with actual exit 0 and zero failures/errors/pending.
A temporary selector bypass produces six failures; exact restoration passes.
All 324 final source/spec/support inputs reconcile with the executed gates.
Scoped hostile verdict: ROBUST for this behavior-preserving ownership move.
The reader/writer/table facades remain 15,798/25,247/6,852 lines; this is not
completion of the architecture cleanup. No new type, API, physical layout,
native compatibility or performance claim is admitted by this extraction.
Exact scope, commands, evidence and refresh conditions:
[MODULARIZATION_FRONTIER.md](MODULARIZATION_FRONTIER.md).

Previous capability checkpoint (W161 at `acae96b`, 2026-10-04 local /
2026-10-05 UTC): W161 pairs
nine canonical unary, non-parametric `SimpleAggregateFunction` identities with
exact UInt64 storage: any, anyLast, min, max, sum, sumWithOverflow, groupBitAnd,
groupBitOr and groupBitXor. The descriptor/value/bulk/physical codecs and
scalar/outer Nullable public Wide-part writer/reader, table windows/batches
and offline column values retain nominal identity; primitive UInt64 APIs do
not silently accept the wrapper. This is stored-value compatibility, not
aggregate execution or AggregatingMergeTree lifecycle support.
Root passes 31 focused DEBUG examples (six unique specs) and 748 affected
RELEASE examples (64 unique specs, eight disjoint groups), all counted groups
with exit 0 and zero failures/errors/pending. Root independently reconciles
actual logs, membership and all 360 then-current source/spec inputs. The
incomplete aggregate attempt is not counted; its final eighth group passes separately.
The opt-in stock reader executes two additional actual native-fixture examples.
Pinned stock qualification passes a native-authored nineteen-column Wide/LZ4
source, eighteen library-authored scalar/Nullable complete parts, actual
ATTACH/CHECK, exact types and 54 literal full/middle/empty RowBinary windows.
Two additional CHECK-valid mutant copies are rejected by the unchanged oracle:
metadata-only min-to-max identity drift and a first-value 0-to-1 change.
Root independently checks native output bytes and confirms the type mutant
changes only columns.txt. All 363 native source/spec/script inputs match the
final gate state. Scoped hostile verdict: ROBUST for this finite profile only.
Three cohesive new owners have separate files, while the reader/writer/table
facades at W161 remain 15,798/25,316/6,852 lines. The subsequent behavior-neutral
W162 staged-validator extraction is recorded above. Fresh clean shallow source
`41b7bd50` is unbuilt and distinct from executed stock build `d9bcb5ab`. Wider type/layout products,
general MV/projections and architecture cleanup remain open; memory/performance
work stays deferred. Exact scope, inventory, commands and refresh conditions:
[SIMPLE_AGGREGATE_FRONTIER.md](SIMPLE_AGGREGATE_FRONTIER.md).

Previous capability checkpoint (2026-10-04): W160 pairs all eleven exact
`Interval` kinds in the general descriptor/value/bulk/physical codecs and
scalar/Nullable public Wide-part readers and writers. Kind identity remains
distinct from primitive Int64 and from other same-width Interval kinds.
`WidePartTable` batches/windows and offline catalog column `.values` share
that admission; Object/JSON Interval fields and actual arms remain refused.
Root passes 31 focused DEBUG examples (six unique specs) and 701 affected
RELEASE examples (57 unique specs, eight disjoint groups), all with zero
failures/errors/pending and exit 0. Root independently reconciles log counts,
membership and current source/spec hashes. These are affected gates, not a
fresh complete-inventory run or a performance measurement.
Pinned-stock qualification passes a native-authored all-kind Wide/LZ4 table,
22 independently library-authored complete parts, actual ATTACH/CHECK, exact
types and independent full/middle/empty RowBinary comparisons. Two CHECK-valid
mutants fail the unchanged original oracle: a metadata-only Second-to-Month
change with identical count bytes, and a one-count value change. Direct
zero-mark reads retain BoundsError; empty SQL/table windows are separate
contracts. Scoped hostile verdict: ROBUST for this finite scalar/Nullable
profile. Generic container/LC codec evidence does not qualify all public
whole-part products, Compact layouts or per-column serializer versions.
Three cohesive Interval owners have separate files, but the large facades
remain; the next staged-validator extraction is only proposed. Fresh shallow
source `41b7bd50` is unbuilt and separate from executable build `d9bcb5ab`.
Broader type/layout products, MV/projections and overall modularization remain
open, with performance deferred. Exact scope, commands, inventory and refresh
conditions are in [INTERVAL_FRONTIER.md](INTERVAL_FRONTIER.md).

Previous capability checkpoint (2026-10-04): W159 extends declared Object/JSON
Dynamic to explicit recursive Array/Tuple/Map sites, with paired codec,
statistics, physical binding and public complete-part reading/writing. Site
rosters are explicit and exact; actual arms and SharedVariant spills retain
the narrower Object arm domain and true Object depth. Each typed field keeps
its first parsed site plan and per-site statistics offsets. Full metadata,
BASIC headers and K+1 grids are checked before full/middle/zero body selection.
Borrowed budgets cover recursive selected-value work and metadata-name copies;
logical budget evidence is not an allocator-RSS certificate.
Root passes 127 focused DEBUG examples (22 unique specs, three disjoint groups)
and 572 affected RELEASE examples (77 unique specs, ten disjoint groups), all
with zero failures/errors/pending and exit 0. Current source/spec hashes match
both gate manifests. Two temporary depth/name-work guard bypasses fail their
intended assertions; source hashes match exactly after restoration. Formatter,
shell/Ruby syntax and hygiene pass. These are affected gates, not a fresh
complete-inventory run or performance measurement.
Pinned-stock qualification passes stock-authored and independently
library-authored complete Wide parts, actual ATTACH/CHECK, explicit per-site
metadata/rosters and independent full/middle literal/type queries. A CHECK-valid
42-to-43 mutant fails the unchanged original value oracle. This native profile
is declared Array/Tuple/Map/direct Dynamic with Int64/String actual rosters,
String/Bool spills, empty collections and NULL, single-stream/BASIC,
Dynamic V3/Object V3 MAP, six rows and three real plus one terminal mark.
Legal Nullable/Tuple, Variant/Array, LC siblings, cap 0 and other actual arms
have spec evidence here, not new general native-product qualification.
Scoped hostile verdict: ROBUST for this slice. Broader JSON/type/layout
products, MV/projections and overall modularization remain open; performance
stays deferred. Source snapshot `895d13ea` is still separate from executable
build `d9bcb5ab`. Exact scope, evidence and refresh conditions are in
[OBJECT_RECURSIVE_DYNAMIC_FRONTIER.md](OBJECT_RECURSIVE_DYNAMIC_FRONTIER.md).

Previous capability checkpoint (2026-10-04): W158 adds paired direct declared
`Dynamic` paths to bounded Object/JSON plans, whole-part writing and public
file/column/table reading. Each path has an explicit actual roster; equal
nominal caps may retain different rosters. The file reader retains the first
validated child plan and exact statistics boundary, validates full metadata
and K+1 grids before selected bodies, and refuses shared-path collisions.
Supplied stale child statistics are omitted, not republished. Callers must
select BASIC explicitly (`mode: 0_u64`); legacy inferred defaults are unchanged.
Root passes 103 focused DEBUG examples (19 unique specs, three disjoint groups)
and 272 affected RELEASE examples (43 unique specs, six disjoint groups), all
with zero failures/errors/pending and exit 0. Root independently reconciles
current source/spec hashes, formatter/syntax/hygiene and a collision-guard
bypass that fails its intended assertion. These are affected gates, not a
new complete-inventory run or performance measurement.
Fresh pinned-stock qualification passes both a stock-authored part and
independently library-authored complete parts, actual ATTACH/CHECK and literal
full/middle/type/shared-arm checks. A CHECK-valid 42-to-43 part fails the same
original literal oracle. The finite native profile is one direct
`Dynamic(max_types=1)` path, Int64 and a shared `Array(Nullable(Int64))` spill,
Wide/single-stream/BASIC/Dynamic V3/Object V3 MAP. Multiple per-path rosters,
NULL, cap 0 and unused arms have spec evidence only here. Scoped hostile verdict:
ROBUST for this slice, not arbitrary JSON/Dynamic compatibility. The source
snapshot `895d13ea` remains separate from executable build `d9bcb5ab`.
Recursive Dynamic, broader physical/type products, MV/projections, overall
modularization and later performance work remain open. Exact boundary,
commands, inventory and refresh conditions are in
[OBJECT_DECLARED_DYNAMIC_FRONTIER.md](OBJECT_DECLARED_DYNAMIC_FRONTIER.md).

Previous capability checkpoint (2026-10-04): W157 retains each validated Dynamic
site's relative statistics-flag offset in `BinaryDynamicBulkPlan`, captured
during the existing writer/parser pass under its shared budget. The strict
getter distinguishes the per-site boundary from EOF and cumulative dry-write
positions; raw structure envelopes do not certify supplied offsets. Root
passes 90 focused DEBUG examples (17 unique specs, two disjoint groups) and
246 affected RELEASE examples (37 unique specs, four disjoint groups), and
2,590 complete-inventory examples (408 unique specs, 41 disjoint non-release
groups with `--no-debug`), all with zero failures/errors/pending and exit 0.
Root independently reconciles observed logs/counts, inventory and current
source/spec hashes; formatter and hygiene pass. Scoped hostile verdict:
ROBUST for retained offsets and the finite stock fixture only.
A read-only check over five original W156 stock metadata streams
passes literal bytes/rosters/names/hashes, paired offsets and three real plus
one terminal mark. Independent Ruby decoding confirms the native mark triples;
two scratch-only wrong-offset controls fail their intended assertions. This
is finite retained-fixture evidence, not a new server run or complete-part
qualification. The refreshed comparison source is `895d13ea` (unbuilt;
DataTypes/Serializations match the previous `db9010c9` snapshot); the separately
pinned stock producer remains build `d9bcb5ab`. Typed Object Dynamic, broader
MV/projection coverage, overall modularization and performance remain open.
The getter is not a provenance-certifying envelope; Object integration must
bind its exact stream and preserve the first parse result. Scope and refresh
conditions are in
[DYNAMIC_STATISTICS_OFFSETS_FRONTIER.md](DYNAMIC_STATISTICS_OFFSETS_FRONTIER.md).

Previous capability checkpoint (2026-10-04): W156 adds an explicit
`BinaryDynamicBulkPhysicalPlan` for prepared per-occurrence actual rosters.
It separates structure/data names and data-prefix ownership, preserves
recursive Array levels and LC stop-site accounting, and refuses physical
collisions and mismatched shared-context limits. Default no-roster consumers
remain closed. Final focused DEBUG passes 109 examples (18 unique specs,
two disjoint groups) and affected RELEASE passes 567 examples (83 unique specs,
nine disjoint groups), plus 2,582 complete-inventory examples (406 unique specs,
41 disjoint non-release groups with `--no-debug`), all with zero
failures/errors/pending and exit 0. Root independently reconciles exact
inventory membership, observed counts, guard exits and current source/spec
hashes; formatter, Ruby syntax and hygiene pass. These are test gates, not
performance measurements.
The finite pinned stock fixture passes four typed columns, six rows and three
real marks. All planner-mapped Dynamic files are re-encoded inside borrowed
stock Wide envelopes; library and CHECK-valid 42-to-43 mutant parts actually
ATTACH and pass CHECK. A separate literal Ruby oracle distinguishes the mutant
and verifies nominal/full/middle results. This is single-stream/BASIC/Dynamic V3
native evidence, not other String/LC products or independently authored
complete parts. Two scratch-only wrong-method controls each fail one of six
adversary examples as intended. The new physical owner has one 712-line file;
the 25,202/15,726/6,786-line writer/reader/table facades are unchanged.
Scoped hostile verdict: ROBUST for this explicit physical-binding boundary and
finite stock fixture, not general compatibility or overall goal completion.
Declared Object Dynamic, general complete parts, broader MV/projection support,
overall modularization and performance remain open. The next prerequisite
preserves structure statistics offsets for metadata marks before typed Object
integration. Exact scope, evidence and refresh conditions are in
[DYNAMIC_PHYSICAL_BINDING_FRONTIER.md](DYNAMIC_PHYSICAL_BINDING_FRONTIER.md).

Previous capability checkpoint (2026-10-04): W155 adds paired generic Dynamic
normalized bulk values and complete per-role K+1 mark grids from explicit
occurrence structures. Equal nominal sites keep distinct stored rosters;
ordinary arms and SharedVariant typed envelopes remain separate. Recursive
containers, unused sites, sparse LC schedules and selected windows share one
operation budget. Root passes 120 focused DEBUG examples (16 unique files,
two disjoint groups), 554 affected RELEASE examples (80 unique files, eight
disjoint groups), and 2,569 complete-inventory examples (403 unique files,
41 disjoint non-release groups with `--no-debug`). Every gate has zero
failures/errors/pending and exit zero; root independently reconciles exact
inventory membership, observed results, guard exits and current source/spec
hashes. A finite stock fixture passes four typed columns, six rows, three
marks and seven SQL probes. Its wire-valid 42-to-43 normalized mutation is
accepted by the Crystal decoder and rejected by an independent value oracle,
not CHECKed by ClickHouse. Stock evidence is single-stream/BASIC/Dynamic V3;
other String/LC products have spec evidence only here. New paired owners have
separate files; the actual-roster plan is 1,186 lines and the large facades
remain unchanged. Scoped hostile verdict: ROBUST for normalized values/grids
and retained legacy consumer fences. No new physical binder, declared Object
Dynamic, complete-part, overall architecture or performance qualification
follows. The source snapshot and pinned executable keep separate identities.
Exact boundary, observed gates and refresh conditions are in
[DYNAMIC_BULK_VALUE_FRONTIER.md](DYNAMIC_BULK_VALUE_FRONTIER.md).

Previous capability checkpoint (2026-10-04): W154 adds paired occurrence-specific
Dynamic V3 structure streams and actual-roster/site planning. Equal nominal
Dynamic descriptors can retain different site rosters; empty children and
unused arms retain their own structure prefixes. Ordinary String and implicit
SharedVariant have distinct canonical roles. Root passes 140 focused DEBUG
examples (19 unique files, two serial disjoint groups) and 558 affected RELEASE
examples (79 unique files, eight serial disjoint groups), and 2,539 complete-
inventory examples (398 unique files, 40 serial disjoint non-release groups
with `--no-debug`), all with zero failures/errors/pending. Root independently
reconciles the current inventory paths, source/spec hashes, observed per-group
results and guard exits. These are test gates, not performance measurements.
Seven stock-produced structure streams round-trip byte-exactly, including
two zero-type nested sites. A stock-valid swapped Tuple-site control decodes
but fails the independent literal site/roster check as a semantic mismatch.
One 574-line plan and one 53-line detached-stream owner have separate files;
the large reader/writer/table facades are unchanged. Recursive Dynamic/Variant
metadata no longer suffers blanket refusal, but legacy value/physical/Object
consumers remain closed for it, including empty/zero-window operations.
This is not generic Dynamic bulk values, physical binding, declared Object
Dynamic, complete-part or performance qualification. The source snapshot
and stock executable retain separate identities. Scoped hostile verdict:
ROBUST for metadata/site planning and retained legacy consumer fences only.
Exact boundary, observed
gates and refresh conditions are in
[DYNAMIC_BULK_STRUCTURE_FRONTIER.md](DYNAMIC_BULK_STRUCTURE_FRONTIER.md).
The historical 2,539-example total predates the neutral writer selector
extraction. W155's fresh 403-file complete gate above includes that refactor
and supersedes this inventory count, without widening its compatibility scope.

Previous capability checkpoint (2026-10-04): W153 adds paired generic Dynamic
logical values. Root passes 116 focused DEBUG, 542 affected RELEASE examples
(76 unique files, eight serial disjoint groups), and 2,519 complete-inventory
examples (394 unique files, 40 serial disjoint non-release groups with
`--no-debug`), all with zero failures/errors/pending. Root independently
reconciles the inventory paths, spec hashes and per-group results.
Fourteen owned-value literals
and four independent stock SQL values pass paired nominal-child/value/byte
checks; a stock-valid 42-to-43 mutation fails specifically as a semantic
mismatch. One private 42-line `BinaryDynamicEnvelope` owns framing and shares
the recursive context with the generic dispatcher. Stored/bulk/Object Dynamic
fences remain load-bearing; existing standalone Dynamic profiles are unchanged.
The source audit rejected a proposed ordinary nested Nothing relaxation before
implementation. Scoped hostile verdict: ROBUST for this logical transition
and retained consumer fences, not new physical storage or full compatibility.
No performance work is reopened. Exact boundary and gates are
in [DYNAMIC_VALUE_KERNEL_FRONTIER.md](DYNAMIC_VALUE_KERNEL_FRONTIER.md).

Previous capability checkpoint (2026-10-04): W152 adds paired immutable nominal
`Dynamic(max_types=N)` descriptors for caps 0..254, preserving the cap in
canonical identity and encoding it as `0x2B` plus one byte. Legal recursive
descriptor parents are admitted; at that checkpoint generic Dynamic values,
bulk/physical lanes and declared Object Dynamic remain refused, including empty/NULL/cache-hit
paths. Existing standalone Dynamic support is unchanged. Root passes 123
focused DEBUG examples, 773 affected RELEASE examples (134 unique files in
six serial groups) plus a separate six-example metadata RELEASE regression,
and 2,500 complete-inventory examples (391 unique files in 28 serial disjoint
non-release groups, all with `--no-debug`). Every gate has zero
failures/errors/pending. These are test results, not runtime performance.
A separate literal Ruby/stock oracle qualifies all 255 normal caps and four
finite recursive wrappers from library-generated headers, including actual
input type inference and a valid changed-cap control. Its row body is borrowed
from stock: no Dynamic-value or new part-writer qualification follows. The
local factory-profile refusal of cap 255 is distinguished from upstream's
unchecked raw decoder. Scoped hostile verdict: ROBUST for this descriptor
transition, with the partial/no-op LC-helper limitation explicitly retained.
Exact source/runtime identities, executed gates and next value-kernel frontier
are in [DYNAMIC_DESCRIPTOR_FRONTIER.md](DYNAMIC_DESCRIPTOR_FRONTIER.md).

Previous capability checkpoint (2026-10-04): W151 admits canonical declared
Variant fields in the bounded normalized Object/JSON writer and its public
file/column/table/catalog readers, including legal recursive containers and
eligible LC-bearing arms. A separate 275-line `BinaryBulkPhysicalPrefixAdapter`
owns BASIC physical prefixes and mark rebasing. Root passes 109 focused DEBUG,
756 affected RELEASE examples (131 unique files in six serial groups), and
2,477 complete-inventory examples (387 unique files in 27 successful serial,
disjoint non-release groups). The inventory uses mixed debug-symbol flags;
legacy generic compilation required a 12-GiB guard for some groups. These
are compiler/test results, not runtime memory or performance measurements.
Two stock parts and four independently library-owned parts pass literal
full/middle values, nominal types and actual CHECK; all four library parts
actually ATTACH. Seven declared witnesses cross both String profiles and the
existing Dynamic modes, with typed Variant restricted to BASIC. An independent
Ruby oracle runs 74 fresh queries and rejects a CHECK-valid changed-value part.
Typed COMPACT Variant is a separately tested refusal, not positive admission.
Scoped hostile verdict: ROBUST. Exact gates, source/runtime identities,
zero-window semantics and residual limits are sealed in
[OBJECT_DECLARED_VARIANT_FRONTIER.md](OBJECT_DECLARED_VARIANT_FRONTIER.md).

Current architecture checkpoint (2026-10-04): Object column physical lane
binding belongs to one private stateless 178-line `LaneBinder` class/file.
The column facade is 123 lines, down from 278; same-signature private delegates
preserve the original prefix-before-binding dispatch and shared operation
budget. Statistics/codec/transport orchestration and buffer lifetimes stay
unchanged. Root passes 23 baseline and post-extraction examples, then all 94
affected examples in each of DEBUG and RELEASE (16 unique files, two serial
disjoint groups per mode), with zero failures/errors/pending and four guard
exits 0. Exact moved-body/facade/loader comparison, final source/spec hash
reconciliation, private visibility, formatting and hygiene pass. A seeded
direct-owner bypass loses the facade trace and fails its intended assertion;
root restores it before final gates. Scoped hostile verdict: ROBUST for this
neutral ownership move only. The general writer/reader/table remain
25,202/15,726/6,786 lines; overall modularization is still open. No new declared
Dynamic, complete-part, native oracle, full-inventory or performance
qualification follows. W158 declared Object Dynamic is the capability return
point; exact scope and refresh conditions are in
[MODULARIZATION_FRONTIER.md](MODULARIZATION_FRONTIER.md).

Previous architecture checkpoint (2026-10-04): the writer's scalar/nullable
typed staged-readback selectors belong to one private stateless 289-line
`TypedMarkReadback` class/file. Same-signature private facade wrappers retain
generic type inference and the original module/supplied-reader dispatch.
Root passes 17 baseline and post-extraction characterizations/regressions,
then all 143 affected examples in each of DEBUG and RELEASE (21 unique files,
three serial disjoint groups per mode), with zero failures/errors/pending.
A seeded direct-owner bypass fails specifically on missing facade traces;
root restores the candidate before final gates. Exact moved-body/facade/loader
comparison, source/spec hash reconciliation, private visibility and hygiene
pass. Writer/reader/table are 25,202/15,726/6,786 lines. Scoped hostile verdict:
ROBUST for this neutral ownership move only. No new type/profile admission,
stock oracle, full-inventory rerun or performance certificate is claimed.
The execution scope and refresh conditions are in
[MODULARIZATION_FRONTIER.md](MODULARIZATION_FRONTIER.md).

Previous architecture checkpoint (2026-10-04): the reader's four nested
temporal/Decimal payload reconstruction loops share one private stateless
89-line `NestedFixedWidthPayloadDecoder` class/file. All preflight, selected
I/O, type/range checks and resource policy stay in the facade. Inline callbacks
preserve inherited private decoder dispatch and skip every hidden NULL slot.
Root passes the four expanded public characterizations before and after
extraction, then all 361 affected examples in each of DEBUG and RELEASE
(18 unique files, two serial disjoint groups per mode). A seeded callback-under-
NULL mutation leaves values unchanged but fails the offset witness; root
restores the candidate before final gates. Exact moved-body/prefix/facade/loader
comparison, private visibility and hygiene pass. The reader is 15,726 lines;
writer/table remain 25,466/6,786. Scoped hostile verdict: ROBUST for this neutral
move, not broader admission, complete modularization or performance. No stock
oracle or complete-inventory rerun is claimed. Executed scope and refresh
conditions are in [MODULARIZATION_FRONTIER.md](MODULARIZATION_FRONTIER.md).

Previous architecture checkpoint (2026-10-04): pure JSON typed-path declaration
grammar belongs to one private stateless 52-line `JsonTypedPathDeclaration`
class/file. Public lookup stays in the facade; parsing receives the calling
class as a generic policy. Root caught and corrected two inherited-dispatch
regressions in the first extraction, then passes all 182 affected examples
together in each of DEBUG and RELEASE over 21 unique files. The eight public
characterizations plus four integration scans also pass an exact-original
method baseline replay. Root verifies moved bodies, complete facade/loader
remainder, seeded error/pinned-policy refusals, private visibility and hygiene.
The reader is 15,780 lines. Public grammar, errors, base-class type/layout
admission and I/O remain unchanged. Scoped hostile verdict: ROBUST only for
this corrected ownership move; no stock oracle or full-inventory rerun is
claimed. Large-facade modularization remains open. Replay and the refuted
fixed-base-policy route are in
[MODULARIZATION_FRONTIER.md](MODULARIZATION_FRONTIER.md).

Previous architecture checkpoint (2026-10-04): the reader's twelve metadata
text-grammar helpers move unchanged into one private stateless 170-line
`PartMetadataTextParser` class/file. Root verifies exact bodies/signatures,
the complete facade remainder and loader order; six literal characterizations
pass before and after extraction. All 155 affected reader/table/catalog/Object
examples pass together in each of DEBUG and RELEASE. A corrected seeded
mutation control is refused, external access fails on the private constant,
and formatter/diff checks pass. The reader is now 15,820 lines. Public API,
grammar, errors, type/layout admission and I/O policy are unchanged; the
stricter selected-JSON probe stays separate. Scoped hostile verdict: ROBUST
for this ownership move, not full modularization or performance. No stock
oracle or complete-inventory rerun is claimed for this slice. Its executed
boundary and replay inventory are in
[MODULARIZATION_FRONTIER.md](MODULARIZATION_FRONTIER.md).

Previous architecture checkpoint (2026-10-04): W150 moves the existing 67
writer schema/substream/serialization metadata helpers to one private
518-line `PartSchemaMetadata` class/file. Root verifies exact moved bodies,
the facade remainder and loader order; five literal characterizations pass
before and after extraction, and all 574 affected RELEASE examples pass
across 110 unique files together. Seven fresh library-owned parts pass
actual stock ATTACH/CHECK, nominal types and full/selected literal queries;
an independent Ruby checker repeats 30 fresh stock queries. The public API,
emitted metadata and admitted types/layouts are unchanged. Scoped hostile
verdict: ROBUST for the ownership move. The writer is still 25,466 lines;
large-facade decomposition remains open. The execution seal is in
[MODULARIZATION_FRONTIER.md](MODULARIZATION_FRONTIER.md).

Previous physical checkpoint: W149 binds ordinary recursive normalized
BASIC Variant lanes to Wide physical names and role-owned combined prefixes.
Root passes 64 focused DEBUG, 533 affected RELEASE examples (68 unique files
together) and 2,452 complete-inventory examples (381 unique files in sixteen
serial disjoint non-release groups, not a combined-process run). Six fresh
stock fixtures and six exchanges with library-emitted lanes pass complete
roster/grid checks, actual ATTACH/CHECK and literal full/middle RowBinary;
a separate Ruby oracle repeats 54 fresh queries, including a valid wrong-value
control. These exchanges borrow stock envelopes: at that checkpoint declared
Object Variant/Dynamic and new public whole-part profiles remained closed.
W151 separately supersedes the bounded typed-Variant refusal. Scoped hostile
verdict: ROBUST. See
[VARIANT_PHYSICAL_BINDING_FRONTIER.md](VARIANT_PHYSICAL_BINDING_FRONTIER.md).

Previous bulk checkpoint: W148 implements paired normalized BASIC
Variant bulk lanes through ordinary recursive containers and eligible LC
sites. Final focused DEBUG passes 50 examples; affected RELEASE passes 517
examples across 66 unique files together. Two fresh stock Wide lane/grid
fixtures and both library-emitted Native payloads pass independent literal
checks, including a valid wrong-value control. Final complete-inventory
passes 2,434 examples across 378 unique files in sixteen serial disjoint
non-release groups, not a combined-process run. Formatter, Ruby syntax and
diff checks pass; the scoped hostile verdict is ROBUST. Physical binding,
declared Object Variant/Dynamic and new public part profiles remain closed.
See [VARIANT_RECURSIVE_BULK_FRONTIER.md](VARIANT_RECURSIVE_BULK_FRONTIER.md).

Separate architecture checkpoint: the existing public writer JSON typed-path
descriptor and alias have moved unchanged to their own 17-line owner. Root
passes two standalone constructor/import examples and 67 adjacent examples
in each of DEBUG and RELEASE, with exact moved-body/facade/loader checks.
No type, physical profile or writer behavior changes; the large facade refactor
remains open. See [MODULARIZATION_FRONTIER.md](MODULARIZATION_FRONTIER.md).

Previous logical checkpoint: W147 adds paired generic Variant
descriptors and owned RowBinary values, with canonical arm identity, NULL and
legal recursive compositions. Root passes 62 focused DEBUG, 503 affected
RELEASE examples (64 unique files together) and 2,420 complete-inventory
examples (376 unique files, sixteen serial disjoint non-release groups, not
a combined-process run). The independent literal stock/library exchange
passes seven rows in each direction plus a valid 42-to-43 wrong-value control.
This is a logical codec prerequisite: generic Variant bulk/physical lanes,
declared Object Variant/Dynamic and new public part profiles remain closed.
The scoped certificate is in
[VARIANT_VALUE_KERNEL_FRONTIER.md](VARIANT_VALUE_KERNEL_FRONTIER.md).

Previous whole-part checkpoint: W146 admits canonical declared
LowCardinality fields in normalized Object/JSON, including legal recursive
compositions and LC(Nullable(T)). The existing independent complete-part
writer and file/column/table/catalog consumers share role-owned dictionary
prefixes and complete-grid replay. Root passes 112 focused DEBUG, 406 affected
RELEASE examples (52 unique files together) and 2,405 complete-inventory
examples (374 unique files, sixteen serial disjoint non-release groups, not
a combined-process run). Eight native/library cells pass actual CHECK,
four independent library-part ATTACH operations, exact nominal types and
full/middle ordered literal RowBinary under both ordinary String profiles
and BASIC/COMPACT Dynamic modes. A separate Ruby checker rechecks all eight
cells and a valid wrong-value store with 74 fresh stock queries. These are
whole library-owned parts, not borrowed stock envelopes. The physical matrix
qualifies seven declared witnesses, not every eligible leaf/product/profile.
Dynamic/shared LC and Object BFloat16 remain refused. Scope and execution
lineage are in
[OBJECT_DECLARED_LOW_CARDINALITY_FRONTIER.md](OBJECT_DECLARED_LOW_CARDINALITY_FRONTIER.md).

The overall objective is still open: paired type/layout coverage and
MV/projection interoperability first, memory/performance afterward. Shared
codec/planner owners have separate files, but the large legacy facades have
not yet been fully decomposed. No stock-reader speed-parity claim is made.

## Earlier checkpoint lineage

W145 binds ordinary recursive LowCardinality bulk roles to physical
dictionary/index filenames, including W144's raw Float transport. Root passes
99 focused DEBUG, 324 affected RELEASE and 2,395 full-inventory examples
(372 unique spec files, 16 disjoint non-release groups). Eight stock Wide parts
and eight exchanges with library-emitted lanes pass roster/grid/value checks
and actual stock ATTACH/CHECK/RowBinary; a separate literal Ruby oracle
rechecks all sixteen tables and the wrong-value control with 51 fresh queries.
Those exchanges borrow stock envelopes. They do not qualify an independent
whole-part writer or public Object facade admission; W146 separately does so
within its declared-field profile. See
[LOW_CARDINALITY_PHYSICAL_BINDING_FRONTIER.md](LOW_CARDINALITY_PHYSICAL_BINDING_FRONTIER.md).

Source checkpoint: shared writer extraction `571dc3c`, sparse-consumer Tuple
correction `9d87293`, W128 normalized whole-part checkpoint `1c5bab4`, and
the W129 bounded Object catalog integration, W130 mixed table delivery
`4b18812`, W131 declared Int64 `02dd99f`, W132 paired numeric declared
fields `e043be7`, W133 paired declared Date/Date32 `2e150f4`, W135
paired bare declared UUID/IPv4/IPv6 `ffa5730`, W136 paired bare
declared FixedString(N) `700d5b8`, W137 canonical bare declared
Decimal(P, S) `73914c8`, W138 canonical bare declared Enum8/Enum16 `0c63c32`,
W139 paired declared DateTime/DateTime64/Time/Time64 `281b0d6` in
[JSON_GENERAL_STORAGE_FRONTIER.md](JSON_GENERAL_STORAGE_FRONTIER.md).
W140 adds recursive Object declared fields over W139; its scoped certificate
is in [OBJECT_RECURSIVE_DECLARATIONS_FRONTIER.md](OBJECT_RECURSIVE_DECLARATIONS_FRONTIER.md).
W134 extracts nine existing Array/Map row/slice owners to separate files,
preserving their exact bodies and API. Root passed 22 focused DEBUG, 37 adjacent
RELEASE and 2,242 complete-inventory examples (353 unique specs, 15 disjoint
non-release groups), plus a fresh unchanged W133 stock regression. This is
bounded behavior-preserving extraction, not full facade modularization.
The executed certificate and responsibility-level owner boundaries are in
[MODULARIZATION_FRONTIER.md](MODULARIZATION_FRONTIER.md).
W136 root gates pass 52 focused DEBUG, 177 adjacent RELEASE and 2,260
complete-inventory examples (357 unique specs in 15 disjoint non-release
groups), plus the eight-cell FixedString stock oracle and fresh unchanged
UUID/IP, Date and numeric regressions. Its scoped hostile verdict is ROBUST
in the JSON frontier; the full-inventory result is not a combined-process run.
W137 root gates pass 61 focused DEBUG, 186 adjacent RELEASE and 2,269
complete-inventory examples (359 unique specs in 15 disjoint non-release
groups). Its fresh eight-cell Decimal stock matrix passes exact nominal
types, scale-preserving text, independent RowBinary, actual CHECK for all
cells and ATTACH for the four library-owned parts. The JSON frontier retains
the complete gate record and residual scope; schema coverage of all 3,002
legal precision/scale pairs is not exhaustive physical part qualification.
W138 root gates pass 72 focused DEBUG, 197 adjacent RELEASE and 2,280
complete-inventory examples (361 unique specs in 16 disjoint non-release
groups). Eight fresh native/library Enum cells pass nominal maps, labels,
literal signed RowBinary, actual CHECK and four library ATTACH operations;
an independent Ruby checker rechecks all eight stores without Crystal codecs.
Five fresh unchanged neighboring stock oracles pass. Full-width map admission
(256/65,536 entries) is schema evidence, not exhaustive physical-map coverage.
W139 root gates pass 83 focused DEBUG, 470 adjacent RELEASE and 2,291
complete-inventory examples (363 unique specs in 16 disjoint non-release
groups). Eight fresh native/library cells cover 37 temporal declarations,
every scale 0..9 and sampled implicit/explicit/alias/fixed zones; all actual
CHECK and four library ATTACH operations pass. An independent arithmetic/Ruby
checker rechecks all eight stores, and six unchanged neighboring stock oracles
pass. This is a bounded temporal Object certificate, not all-zone/recursive
or current-master executable qualification.
W140 root gates pass 109 focused DEBUG, 496 adjacent RELEASE and 2,317
complete-inventory examples (367 unique specs, 16 disjoint non-release groups).
Eight fresh cells qualify 13 Array/Map(String,V)/Tuple/Nullable field witnesses,
with all actual CHECK results and four library ATTACH operations. A manual
Ruby checker independently rechecks all eight live stores and 4,496 RowBinary
bytes; seven unchanged neighboring stock oracles pass. Schema admission over
W139 leaves is broader than this finite physical sample. Separate grammar,
descriptor, Tuple-name and catalog-accounting owners leave legacy facades
unchanged; this is not all types, all layouts or completed modularization.
W141 adds the paired nominal LowCardinality descriptor/owned row-value kernel,
including recursive containers and LC(Nullable(T)) over represented eligible
leaves. It preserves the narrower persisted Object/bulk boundaries rather
than treating RowBinary compatibility as dictionary/index part support.
Root passes 98 focused DEBUG, 206 affected RELEASE and 2,332 complete-inventory
examples (368 unique specs, 16 disjoint non-release groups), plus nine
bidirectional nominal row witnesses and descriptor/name negative controls.
The current transition and independent source/runtime evidence are in
[OBJECT_LOW_CARDINALITY_FRONTIER.md](OBJECT_LOW_CARDINALITY_FRONTIER.md).
W142 adds the standalone shared physical LC dictionary/index prerequisite in
[LOW_CARDINALITY_BULK_STORAGE_FRONTIER.md](LOW_CARDINALITY_BULK_STORAGE_FRONTIER.md).
Root passes 72 focused DEBUG, 241 affected RELEASE and 2,361 complete-inventory
examples (369 unique specs in 16 disjoint non-release groups), plus nine exact
native lane/grid witnesses, nine stock Native consumers and four cause-specific
corruption/comparator controls. Stock consumption converts global framing to
Native additional-only framing; this is not a new library-part ATTACH/CHECK.
It does not widen recursive bulk, Object, Dynamic or complete-part admission.
W143 integrates that shared owner into ordinary recursive `BinaryBulkCodec`
for root LC and legal Array/Tuple/Map/Nullable compositions over eligible
non-floating represented leaves. Root passes 80 focused DEBUG, 255 affected
RELEASE and 2,375 complete-inventory examples (370 unique specs, 16 disjoint
non-release groups), three complete native container lane/grid witnesses and
seven stock Native consumers including a valid wrong-output control. A separate
Ruby comparator checks all 63 stock rows against literal types/RowBinary.
The executed certificate is in
[LOW_CARDINALITY_RECURSIVE_BULK_FRONTIER.md](LOW_CARDINALITY_RECURSIVE_BULK_FRONTIER.md).
In W143, Float LC composition and persisted Object/Dynamic/physical-part
binding remained explicitly closed. W144 supersedes only that Float bulk
guard. W145 subsequently admits generic physical role/name binding, while
keeping Object/Dynamic and existing whole-part facade boundaries closed at
that checkpoint. W146 supersedes only the bounded typed-Object LC refusal.
Neither shared bulk nor filename binding qualifies a new standalone writer.
Reviewed on 2026-10-04. This is a navigation summary, not a new compatibility
certificate; the linked frontier documents retain their tested profiles,
source/runtime identities and executed evidence.

## What is usable now

- `BinaryDataType.qbit(QBitType)` and `BinaryValue.qbit(QBitValue)` bridge
  dedicated QBit owners into descriptor/scalar/envelope and normalized bulk
  codecs for root QBit/direct Nullable(QBit). `qbit_type`, `qbit_value` and exact
  element/dimension/stride identity remain nominal, not numeric or Array
  aliases. `BinaryBulkPhysicalPlan` binds zero-based logical plane roles to
  one-based `payload%2E1` physical names; bulk planes are not scalar raw-element
  bytes. Existing dedicated part/table/offline consumers remain unchanged.
  Arbitrary-schema/container-QBit parts and QBit-in-Object remain refused.
  Final paired gate status is in
  [the W179 frontier](QBIT_BINARY_KERNEL_FRONTIER.md).
- W178 pairs ordinary Count with bounded canonical argument metadata through
  logical codecs, complete two-column Wide/LZ4 parts, typed table/window/
  candidate scans and exact DDL-bound offline `.values`. The native certificate
  covers 63 canonical argument profiles plus inherited no-argument controls,
  not every recursive argument product or 63 new physical serializers. Use
  `batch.aggregate_count_states_for(column, expected_type)` for nominal
  BinaryValue states; the batch Slice is callback-borrowed, copied state
  handles and `.values` are owned. Transformed `nothingUInt64`, other aggregate
  functions, unqualified outer/storage products and Count projection payloads
  remain refused. See
  [the W178 frontier](AGGREGATE_COUNT_ARGUMENTS_FRONTIER.md).
- `BinaryDataType.dynamic` and `BinaryValue.dynamic` provide nominal-cap
  identity and paired generic logical Dynamic values. W153 preserves selected
  type/value identity, recursive containers and typed NULL distinctions;
  borrowed persisted consumers and unqualified bulk/physical/Object lanes
  remain fenced. A logical envelope is not a ColumnDynamic slot/roster plan
  or a new complete-part writer.
- `BinaryDynamicBulkPlan` pairs actual Dynamic rosters with immutable
  occurrence paths, including declared containers, static Variant arms and
  nested Dynamic inside actual arms. `BinaryDynamicStructureStreams` provides
  detached complete structure blobs. Paired structure decode/encode and
  logical role rosters are available under shared operation budgets. See
  [the W154 frontier](DYNAMIC_BULK_STRUCTURE_FRONTIER.md).
  W157's `statistics_offset_for(path)` retains the relative pre-statistics-flag
  position for exact decoded bytes or the same plan's emitted structure,
  including an absent-statistics flag. It does not itself certify arbitrary
  stream binding. See
  [the W157 frontier](DYNAMIC_STATISTICS_OFFSETS_FRONTIER.md).
- `BinaryDynamicBulkCodec` and `BinaryDynamicBulkStreams` pair those structures
  with normalized generic Dynamic values and complete per-role mark grids.
  Exact stored-site rosters control ordinary versus SharedVariant selection;
  actual LC-bearing arms keep full sparse schedules across selected windows.
  Supplied statistics are preserved, not recomputed as a publication
  certificate. This API does not itself bind physical files or admit a new
  whole-part writer. See
  [the W155 frontier](DYNAMIC_BULK_VALUE_FRONTIER.md).
- `BinaryDynamicBulkPhysicalPlan` explicitly binds the prepared actual-roster
  plan to separate Dynamic structure/data names and data-prefix ownership.
  It preserves recursive Array levels, ordinary versus SharedVariant String,
  LC stop-site budgets and whole-basename hashing. Default no-roster physical
  consumers remain closed. The finite W156 stock certificate is limited to
  the pinned single-stream/BASIC/Dynamic V3 fixture in borrowed Wide envelopes;
  it is not independently authored complete-part or declared Object Dynamic
  support. See [the W156 frontier](DYNAMIC_PHYSICAL_BINDING_FRONTIER.md).
- `BinaryDataType.variant`, `BinaryValue.variant` and `variant_null` provide
  the shared canonical logical Variant kernel. Paired descriptor/value codecs
  retain nominal arm identity, recursive values and explicit NULL. W148 adds
  normalized BASIC discriminator/sparse-arm bulk lanes, ordinary containers
  and eligible LC replay. W149 adds shared ordinary recursive physical names
  and combined prefixes, not a new public whole-part facade; see W147-W149
  certificates. W151 separately admits declared Variant in the existing
  bounded complete-Object writer and public consumers, not an arbitrary-schema
  standalone Variant part writer.
- `WidePart` and `WidePartTable`: selected-column and typed reads, including
  windowed delivery. The public contracts admit explicit physical profiles,
  not arbitrary ClickHouse parts or recursive type combinations.
- Paired part readers/writers cover broad primitive, String/FixedString,
  Nullable, Enum, Decimal, identifier, temporal, container and geometry
  families, including QBit and several LowCardinality/Variant/Dynamic profiles.
  Exact supported declarations, wrappers and layouts are in
  [EMBEDDED_MERGETREE_FRONTIER.md](EMBEDDED_MERGETREE_FRONTIER.md) and its
  linked family frontiers. A supported scalar does not imply every container
  or serialization profile containing it.
- `WidePartWriter.write_uint64_object_pair`: a complete standalone normalized
  JSON/Object part from library-owned keys, explicit schema/rosters and
  documents, without borrowed stock sidecars. W128 qualifies hashed Wide,
  Object V3/Dynamic V3, one-bucket shared MAP, LZ4 and plain adaptive marks;
  W128 declared typed fields are UInt64/String. Five fresh parts passed actual
  stock ATTACH/CHECK=1/full/PK SQL and explicit file-reader full/middle/zero windows.
  W129 adds bounded catalog Object materialization; W130 adds the separately
  qualified mixed typed-table reader. Neither widens the writer to multiple
  Object columns or arbitrary schemas. W132 admits declared UInt8/16/32/64/128/256,
  Int8/16/32/64/128/256, Float32/64, Bool and String through those same owners.
  Four fresh native and four library-owned parts pass actual CHECK/full/PK SQL,
  independent numeric RowBinary and file/column/catalog/table consumer checks,
  including float signed zero, infinity and NaN payloads. Bool is nominally
  distinct from UInt8; logical writes canonicalize true to byte 1. BFloat16 is
  excluded by the measured stock Object schema gate. String 0/1 × BASIC/COMPACT
  is qualified in both directions; this is still normalized Object V3/MAP,
  not arbitrary JSON. W133 adds bare declared Date/Date32 through the same
  writer and public consumers: eight fresh native/library matrix cells pass
  calendar/day-code/type/byte checks, actual CHECK and exact RowBinary; two
  separate raw Date32 extrema cases qualify transport only, not calendar range.
  W135 adds bare declared UUID/IPv4/IPv6 through the same fixed-value and
  bulk owners. Eight fresh native/library cells pass actual CHECK (and
  ATTACH for library-owned parts), canonical text, nominal SQL types,
  independent literal RowBinary and public file/column/catalog/table consumers.
  Twelve seeded comparator
  controls reject byte/order, same-width nominal, serializer, grid and CHECK
  mismatches. UUID remains distinct from UInt128/IPv6, and IPv4 from UInt32.
  W136 adds canonical bare declared FixedString(N), retaining N as nominal
  identity and using existing exact-width payload/bulk owners. The schema
  admits N=1..16777215; stock part qualification covers N=1/3/16/17/31/257
  across eight fresh native/library cells, with exact bytes, padding, UTF-8
  byte lengths, actual CHECK and public consumer/PK checks. N>256 requires
  the server's suspicious-type opt-in; maximum-N evidence is schema-only.
  Library raw inputs require exactly N bytes, without implicit text padding.
  W137 adds canonical bare Decimal(P, S), P=1..76 and S=0..P, through the same
  fixed-value/bulk, writer and public consumers. All 3,002 legal schema pairs
  pass constructor/parser checks; independent stock qualification samples
  nine P/S witnesses across all four storage widths in eight fresh cells.
  Raw signed coefficients, precision, scale and width stay exact; this is
  storage interoperability, not Decimal arithmetic/conversion/rounding.
  W138 adds canonical bare Enum8/Enum16 with exact width and complete
  label/code-map identity, all eight canonical escapes and opaque label bytes.
  Existing fixed-value/bulk owners provide paired writer/reader transport;
  stock part evidence covers seven-entry maps with signed extrema across the
  same eight cells. Same-width integer aliases and changed maps are not equal.
  Full 256/65,536-entry maps remain eligible with sufficient logical budgets.
  The shared declared-field policy now admits 21 static nominal types plus
  the FixedString, Decimal and Enum families. W139 adds canonical DateTime/
  DateTime64/Time/Time64 through one declaration owner and the same paired
  transport/consumer paths. Scale and exact implicit/explicit/alias/fixed zone
  identity are retained; eight cells qualify every scale and sampled zones.
  Default-scale aliases remain refused. W140 adds canonical recursive Array,
  Map(String,V), named/unnamed Tuple (including Tuple()) and legal Nullable
  fields over the W139 leaves through the same paired writer/reader/consumer
  paths. Nested Maps require exact String keys; Nullable cannot immediately
  wrap Array, Map or Nullable. Thirteen recursive witnesses are physically
  qualified across the eight cells; every recursive leaf/product is not.
  W146 adds declared LC over the eligible represented Object leaf intersection,
  including LC(Nullable(T)) within those compositions. Seven field witnesses
  are physically qualified across eight native/library cells. Selected reads
  replay all Object physical lanes if any typed field contains LC; only the
  requested documents are materialized. Catalog `.values` may repeat replay
  per mark. This is correctness admission, not selective I/O or a performance
  certificate. Dynamic/shared LC remains outside the Object profile. See
  [the declared LC frontier](OBJECT_DECLARED_LOW_CARDINALITY_FRONTIER.md).
  W151 adds canonical declared Variant through the same complete-part and
  public consumer owners. Seven recursive witnesses have independent stock
  and library-owned part evidence, including NULL, unused arms and LC keys
  reused across marks. Plain non-LC Variant preserves selected body reads;
  LC anywhere in a typed tree requires complete replay. Every physical grid
  is checked, including zero windows; untouched body frames are not all
  authenticated by a selected read. Typed Dynamic, COMPACT Variant and general
  Object layouts remain refused. See
  [the declared Variant frontier](OBJECT_DECLARED_VARIANT_FRONTIER.md).
  The inherited timezone manifest still lacks runtime-added America/Coyhaique.
  See
  [the example](../examples/write_object_document_part.cr) and
  [the qualified frontier](JSON_GENERAL_STORAGE_FRONTIER.md).
- `OfflineCatalog`: disk-based Atomic metadata discovery, database/table/
  column objects and part candidates. `catalog[db][table][column].values`
  explicitly materializes a bounded owned column; it is not a lazy result.
  Normalized whole-JSON columns now return owned `ObjectDocument` values
  within the W129 declaration/layout profile, with aggregate cross-part
  logical, row, String and recursive-cell limits. That accounting is not an
  RSS or pre-decode transient-memory ceiling. See
  [read_object_catalog.cr](../examples/read_object_catalog.cr).
  W130 separately admits selected normalized Object roots, alone or mixed
  with existing typed columns, through full batches, physical windows and
  bounded UInt64-PK candidate delivery. More than one selected Object root
  is kept separately bound. `batch.object_documents_for(column)` exposes
  callback-scoped slices of immutable retainable document handles. See
  [read_object_table.cr](../examples/read_object_table.cr).
  Synthetic `catalog["system"]["part_candidates"]["rows"].values` is supported;
  these are candidates, not server-proven Active parts or the real `system.*`
  tables. See [OFFLINE_CATALOG_FRONTIER.md](OFFLINE_CATALOG_FRONTIER.md) and
  [OFFLINE_PART_CANDIDATE_VALUES_FRONTIER.md](OFFLINE_PART_CANDIDATE_VALUES_FRONTIER.md).
- Primary-index granule pruning is available for the bounded UInt64 key
  profile. Candidate scans deliver complete selected granules; application
  code must apply the exact residual predicate. See
  [PRIMARY_KEY_GRANULE_PRUNING_FRONTIER.md](PRIMARY_KEY_GRANULE_PRUNING_FRONTIER.md).
- `EmbeddedMergeTreeTable`: a Crystal-owned experimental table with one
  UInt64 key, one String value and the `all` partition; insert, reopen, merge,
  candidate scans and explicit reclamation. Its process-atomic commit-marker
  protocol is not a ClickHouse server data-root lifecycle or power-loss
  durability guarantee. See [examples/README.md](../examples/README.md).

## Important remaining boundaries

1. **General JSON compatibility.** W117-W151 provide
   reusable type/value, bulk, structure, binding, transport, normalized Object
   reader, column writer and complete normalized whole-part owners. W128
   generates every pre-ATTACH file from owned inputs and has fresh stock
   qualification; W127's older shell-based oracle is not the whole-part
   certificate. The catalog now dispatches whole normalized JSON through
   `ObjectColumnReader`, and W130 integrates that bounded profile into public
   mixed `WidePartTable` batches/windows and UInt64 PK candidates. W132 admits
   the numeric primitive family, Bool and String declared fields with paired
   stock evidence; W133 adds bare Date/Date32 with independent calendar and
   signed raw-carrier checks; W135 adds bare UUID/IPv4/IPv6 with independent
   text, nominal and byte-order evidence; W136 adds canonical bare
   FixedString(N) with bounded parameter grammar and independent fixed-byte
   evidence; W137 adds canonical bare Decimal(P, S) with exact persisted P/S
   identity and independent signed coefficients; W138 adds canonical bare
   Enum8/Enum16 with nominal full-map and independent label/signed-byte checks.
   W139 adds canonical DateTime/DateTime64/Time/Time64 with exact scale/zone
   identity and independent ticks/text checks. W140 adds recursively bounded
   Array/Map/Tuple/Nullable declared fields and catalog descriptor-tree charging.
   W146 adds bounded canonical declared LC with shared physical state replay
   and an independent whole-part certificate. W151 adds bounded canonical
   declared Variant with a paired prefix owner and independently owned whole
   parts. W158 adds direct declared Dynamic with exact per-path actual rosters,
   retained first-parse metadata and independently authored complete parts in
   its finite BASIC profile. W159 extends explicit declared Dynamic rosters
   through legal recursive wrappers, with separate Array/Tuple/Map whole-part
   qualification. Unqualified Dynamic/Variant/LC leaves/products, Map LC keys, and
   the inherited timezone-profile gap remain open within Object,
   even where standalone part support exists. The older persisted scalar
   typed-path behavior is unchanged. W180 separately admits a root nominal JSON
   v0 descriptor and structured scalar RowBinary row, with a closed child grammar
   and seven paired witnesses; it does not widen these physical Object owners.
   See [JSON_BINARY_KERNEL_FRONTIER.md](JSON_BINARY_KERNEL_FRONTIER.md).
   Neither adapter implies arbitrary
   JSON schemas or physical layouts; Default serialization metadata is still
   required, and whole-Object projection child reads remain refused. See
   [JSON_GENERAL_STORAGE_FRONTIER.md](JSON_GENERAL_STORAGE_FRONTIER.md).
   W140's finite physical profile and executed gates are in
   [OBJECT_RECURSIVE_DECLARATIONS_FRONTIER.md](OBJECT_RECURSIVE_DECLARATIONS_FRONTIER.md).
2. **Additional physical profiles and recursive composition.** Normalized
   Wide/SUFFIX Object V3 with explicit rosters and one-bucket MAP is not general
   JSON/Dynamic compatibility. Bucketed/advanced layouts, other structure
   versions, Compact parts and unqualified wrapper/container combinations need
   their own paired evidence. Existing logical binary codecs alone do not
   widen public part admission. W147 qualifies the generic Variant logical
   kernel; W148 implements normalized BASIC discriminator/sparse-arm bulk,
   and W149 qualifies generic Wide physical binding with combined prefixes
   and finite stock witnesses, not a standalone general writer. Specialized
   prefix streams and COMPACT Variant remain unqualified by that binder.
   W151 qualifies the separate declared-Object BASIC Variant profile, not
   every physical product admitted by its schema grammar.
   W152/W153 qualify nominal Dynamic descriptors and generic logical values;
   W154 adds actual per-occurrence structure/roster planning and W155 pairs it
   with normalized bulk values and complete mark grids. W156 adds explicit
   physical binding with a finite single-stream/BASIC/Dynamic V3 stock
   certificate in borrowed Wide envelopes. W157 retains the per-site
   statistics-flag boundary needed by metadata marks. W158 binds exact child
   streams to those offsets and integrates direct declared Object Dynamic with
   a finite independently authored whole-part certificate. Other physical
   products and independently authored general complete parts remain open.
   W159 binds recursive declared Object Dynamic sites in its separate finite
   paired profile; that is not qualification of every admitted schema product.
   Equal nominal Dynamic types do not imply
   equal per-part or per-site state.
   W171 pairs nominal unflattened Nested through the inherited recursive
   Tuple/scalar storage plan and explicit part/table/offline entrypoints.
   Its native whole-part witness is one three-leaf profile, not every schema
   product. W173 pairs an explicit flattened shared-offset part view/writer for
   direct scalar/Nullable leaves. W174 qualifies explicit typed table/offline
   context mapping for the exact two-column DDL profile; implicit discovery and
   general context mapping remain unqualified. W178 extends W175-W177's ordinary
   Count state to bounded canonical argument metadata through logical codecs,
   explicit Wide/LZ4 part readers/writers, typed table/window/candidate scans
   and exact DDL-bound offline `.values`. Its finite native matrix covers 63
   canonical argument profiles, not every recursive argument product. Other
   AggregateFunction states and unqualified outer/storage products/layouts
   remain outside the certificate. Broader
   SimpleAggregateFunction carriers/functions/parameters/aliases remain
   unqualified; aggregate states and ordinary stored values are not
   interchangeable capabilities. W163 extends W161's nine canonical unary,
   non-parametric SimpleAggregateFunction identities to ten standard numeric
   carriers under the exact 77-pair eligibility law, with scalar/outer Nullable
   Wide readers/writers and their table/catalog consumers. W164 adds raw wide
   integers and BFloat16 in 41 more scalar pairs, 82 with outer Nullable,
   through those same owners. W168 adds any/anyLast/min/max with String and
   FixedString(N), scalar or outer Nullable, with finite stock width witnesses.
   W169 adds canonical Decimal(P, S) carriers under their separate five-function
   all-width / sum-only-128/256 law, with exact function/P/S/width/shape through
   the same public consumers. W170 adds Date/Date32/DateTime/DateTime64/Time/
   Time64 for any/anyLast/min/max, scalar or outer Nullable, retaining exact
   temporal leaf/scale/zone and raw carrier identity. Inner Nullable children,
   broader products and other functions/parameters/aliases remain outside the
   current certificate; the other five canonical functions refuse temporal
   children under the separately measured stock construction law.
   The latest finite gate state is recorded in
   [SIMPLE_AGGREGATE_TEMPORAL_FRONTIER.md](SIMPLE_AGGREGATE_TEMPORAL_FRONTIER.md), not a claim of
   complete SimpleAggregateFunction or AggregatingMergeTree execution support.
   W160 now pairs Interval descriptors, values,
   normalized bulk and generic physical composition plus independently authored
   scalar/Nullable whole parts. Recursive and LC Interval codec admission is
   not a public whole-part certificate for every composition.
   W172 pairs the nominal Nested descriptor and ordinary logical value/bulk
   kernel; specialized Nested LC/Variant/Dynamic products remain refused.
   The general descriptor kernel admits AggregateFunction only for W178's
   ordinary Count canonical-argument profile; other aggregate states and Custom
   remain outside it. W180 now admits root JSON v0 descriptors and structured
   scalar RowBinary values, not parent products, SKIP/regexp or general persisted
   JSON. Its finite native witnesses do not qualify every recursive child type.
   W179 now pairs QBit/QBitWithStride tags,
   scalar RowBinary and normalized bulk for root/direct Nullable only; its
   finite native matrix does not admit container, borrowed Object or arbitrary
   complete-part products. SimpleAggregateFunction's tag is
   now paired only within the W163/W164 numeric, W168 text, W169 Decimal and
   W170 temporal profiles.
   This is not an inventory of wholly absent physical types: dedicated Object,
   geometry and QBit owners already cover narrower persisted profiles. Set and
   Function descriptors are also absent, but the current ClickHouse source
   makes them IDataTypeDummy expression intermediates that cannot be stored in
   tables; they are not outstanding MergeTree column serializers. See
   `src/DataTypes/{DataTypesBinaryEncoding.h,IDataTypeDummy.h,DataTypeSet.h,
   DataTypeFunction.h}` in the pinned source checkout. Ordinary type aliases
   likewise do not automatically introduce new wire families.
3. **MV/projection coverage.** Offline declaration metadata and explicit reads
   of fully covered physical Wide projection child parts are available. The
   persisted MV materializer is one explicit-TO identity projection over
   unpartitioned `k UInt64, v String`. General MV execution, projection
   planning/writing and arbitrary MV transformations are not implemented.
4. **General table writing.** The detached-part writers and small
   `EmbeddedMergeTreeTable` are not an arbitrary-schema, arbitrary-partition
   MergeTree writer with compound keys and a server lifecycle.
5. **Responsibility-level architecture.** The reader/writer/table facades remain
   large. Individual new owners have separate files, but the overall refactor
   is unfinished. File count alone does not prove lower coupling.

## Next implementation order

1. Continue behavior-preserving decomposition. Shared VarUInt/checksums,
   primary index and staging/publication have separate owners; the new Object
   schema, metadata, whole-part orchestrator and catalog materialization
   owners also have separate files.
   W134 moved the nine existing inline Array/Map payload/row classes from
   `wide_part_table.cr` into nine separate files, preserving public names,
   generic signatures, retained ownership and limits. The remaining facade
   was 6,911 lines at W167; at W171 reader/writer/table facade sizes were
   16,221/25,676/7,175 lines.
   The current table extraction leaves reader/writer/table facades at
   16,357/25,781/4,930 lines and a separate 2,051-line Batch. These are sizes,
   not a coupling or performance certificate. The next proposed Batch seam
   is compositional row-handle storage, preserving the injected Tuple store
   and shared Array(Tuple)/Nested store; it is not yet implemented.
   Pure metadata text and JSON typed-path grammar have separate private owners.
   Nested fixed-width temporal/Decimal payload reconstruction now has one
   private owner, with unchanged preflight and inherited private dispatch.
   JSON parsing preserves caller-policy and public-parser overrides; the next
   larger seams are staged validation and physical stream binding, followed
   by reader granule orchestration and table adapters. Each is a separately
   characterized ownership move, not a class per type combination.
   The first writer seam is now executed: the two private generic selectors
   `read_typed_numeric_mark` and `read_typed_nullable_numeric_mark` delegate to
   one private `TypedMarkReadback` owner. W162 now extracts the scalar and
   nullable numeric staged-validator cohort to a separate private owner,
   retaining same-signature facade entry points. W165 extracts scalar/Nullable
   String staged validation into its own private owner; W167 does the same for
   scalar/outer-Nullable FixedString, preserving direct virtual WidePart
   readbacks without moving the I/O/publication lifecycle. W168 adds separate
   text SAF storage-plan and staged-validator owners, reusing PartSchemaMetadata
   for rendering rather than embedding another metadata owner in the facade.
   W169 adds cohesive Decimal SAF declaration/carrier admission and staged
   semantic readback owners in separate files, retaining the existing
   fixed-width codecs and publication lifecycle.
   Other validator
   cohorts and physical stream binding remain separate next seams.
   `Slice(T)`/`forall T`, module reopen overrides and
   supplied-reader virtual dispatch remain pinned. Numeric/nullable and
   temporal readbacks supply positive witnesses; a direct-owner bypass fails
   the selector trace. Metadata tampering remains a separate validator guard,
   not proof that the selector itself ran. Larger validator/I/O seams remain.
   W148 separates the full-mark LC occurrence scheduler from its thin replay
   dispatcher. The existing public `WidePartWriter::JSONTypedPathColumn`
   and associated value alias now have their own owner with exact constructor
   semantics. W150 separately extracts the existing writer metadata renderer
   with exact-move, literal and stock regression evidence. W151 adds one
   role-owned physical-prefix adapter class/file instead of embedding its
   coordinate law in the large facades. The reader metadata text grammar
   now has a separate private owner, without merging the selected-JSON policy.
   Next remain
   shared schema/substream planning, physical I/O/validation, leaf codecs and
   thin table/catalog adapters. W160 adds exact Interval kind, column-grammar
   and semantic reader-gate owners; W161 adds three cohesive nominal-function,
   scalar/Nullable grammar and semantic-gate owners, each in its own file.
   W163 extends those same owners with one centralized function/carrier law
   and semantic numeric gates, not a new hierarchy per pair. Physical I/O stays
   with the checked fixed-width reader and staging stays
   with the existing typed writer. The qualified W162 numeric, W165 String and
   W167 FixedString staged-validator boundaries, dispatch/lifetime/publication guards and the remaining
   validator cohorts are recorded in
   [MODULARIZATION_FRONTIER.md](MODULARIZATION_FRONTIER.md). Keep one
   cohesive class per file rather than one new class per type combination.
   W168/W169/W170 add separate text/Decimal/temporal declaration/storage-plan
   and staged-validation capability owners; these are not neutral extraction
   certificates. The next bounded ownership candidate is the existing scalar
   and Nullable Array-numeric staged-validator cohort, with unchanged facade,
   virtual readback, borrowed lifetime and publication boundaries.
2. Extend paired Object declared fields beyond numeric primitives/Bool/String,
   bare Date/Date32, UUID/IPv4/IPv6, FixedString(N), Decimal(P, S), Enum8/Enum16
   and canonical DateTime/DateTime64/Time/Time64. W140 now admits canonical
   recursive Array/Map(String,V)/Tuple/legal Nullable schemas, with separately
   bounded physical witnesses. W151 adds bounded declared Variant, W158 adds
   direct declared Dynamic and W159 adds recursive declared Dynamic sites;
   remaining lanes include the timezone profile gap and
   separately qualified physical products. W141 establishes the logical
   LowCardinality prerequisite;
   W142 adds the separately qualified standalone dictionary/index codec.
   W143 qualifies recursive non-floating bulk role binding, flattened
   occurrence schedules and dictionary state integration. W144 qualifies
   raw Float LC transport and measures the distinct INSERT normalization
   boundary. W145 now qualifies shared physical LC role binding under explicit
   default-LC/BASIC-Map profiles. W146 admits declared Object LC with independent
   complete parts and selected public consumers within its finite certificate.
   W147 adds the paired logical Variant prerequisite without widening these
   persisted consumers. W148 implements generic BASIC bulk discriminator/
   sparse-arm scheduling, LC occurrence counts and empty-arm mark replay;
   its separate stock count/lane falsifier is executed within the W148 scope.
   W149 qualifies ordinary recursive physical binding, both String profiles
   and LC-bearing sparse arms using borrowed stock envelopes. W151 separately
   qualifies declared Object Variant with independent complete parts and
   shared public consumers. W152 preserves the nominal `Dynamic(max_types=N)` cap; W153 adds
   the paired generic logical actual-type/value grammar. W154 adds paired
   actual per-occurrence structure streams and normalized role/site planning.
   W155 now pairs generic Dynamic normalized bulk values and complete mark-grid
   scheduling over that actual state. W156 adds a separate actual-roster
   physical binder and finite borrowed-envelope qualification. W157 now
   preserves statistics offsets in the paired structure owner for metadata
   marks; ordinary value K+1 grids cannot replace that boundary. W158 binds
   exact metadata streams and retains their first parse results, integrating
   direct per-typed-path actual plans with paired storage ownership and
   independently authored complete parts plus stock ATTACH/CHECK/full/middle
   literal tests. W159 extends that retained-site law to recursive declared
   Dynamic with independent complete Array/Tuple/Map parts. Next characterize
   broader JSON physical products before widening those consumers. Keep default
   no-roster consumers and unqualified profiles closed.
   Neither the cap nor Object's inferred-path policy substitutes for that roster.
   Broader layout/type products remain separate.
   Reuse existing leaf owners only
   after bounded declaration parsing, semantic parameter identity and
   independent physical qualification.
   Require independent native and library parts, asymmetric bytes/RowBinary
   and actual stock CHECK.
   Address parameterized/recursive field grammar and semantic identity, then
   widen layouts with their own stock-generated and library-owned evidence.
   Object declarations retain the stock maximum of 1,000 typed paths.
3. Expand remaining paired type/profile and MV/projection frontiers.
   W164 closes the raw UInt128/256, Int128/256 and BFloat16 numeric lane.
   W168 closes the bounded String/FixedString lane for four canonical functions
   with scalar/outer Nullable shape. W169 closes the canonical Decimal lane
   under its separately measured function/result-type law. W170 closes the
   canonical six-family temporal lane for any/anyLast/min/max under its separate
   construction law and finite paired physical witnesses. Other SAF functions,
   children, parameters, aliases and recursive products require their own
   source/result-type laws and independent complete-part qualification.
   W171 closes the bounded unflattened nominal Nested storage lane using
   existing ragged Tuple/scalar owners, including explicit table/offline
   consumers. W172 pairs nominal Nested binary descriptors/values/ordinary
   bulk with explicit specialized-product guards. W173 pairs explicit flattened
   shared-offset part reading/writing for direct leaves. W174 closes the explicit
   typed table/offline consumer lane for that exact profile; implicit discovery,
   specialized Nested products and general schema binding remain unresolved.
   W175-W177 close the three exact scalar Count state signatures through
   logical codecs, parts and consumers, not the broader AggregateFunction
   state family. A stored-value wrapper does not certify aggregate execution.
   For MV/projections, prioritize declaration/dependency/TO-target inspection
   and compatible projection storage, not adding a SQL functions/joins engine.
4. Only then reopen memory/performance work. No current claim of stock-reader
   speed parity or a quantified percentage of complete ClickHouse support.

## Source reference

The newest separate shallow checkout is
`/Users/sergey/SrcArchives/clickhouse-2026-10-05-depth1-ef037e60`, revision
`ef037e60fc7f5654c8c80eefb8be82e3c56f9a67` (2026-10-05).
[CLICKHOUSE_SOURCE_REFERENCE.md](CLICKHOUSE_SOURCE_REFERENCE.md) records the
six-directory comparison and earlier identities. Root independently
hash-checks 24 decisive JSON/Dynamic/QBit/Count/descriptor owners against
`29e0e201`; all are content-identical. Aggregate state-version propagation and
`uniq` v1 are separate changed consumers, not newly qualified library types.
This is not an audit of every upstream change. Unchanged serializers do not
imply unchanged framing, settings,
metadata or lifecycle behavior. This is
source evidence only: no executable from this checkout has been built or
qualified. Source identity and the separately pinned executable oracle must
not be conflated. Type families persisting across releases also does not
imply immutable binary descriptors or physical layouts.

This summary becomes stale when source admission, facade dispatch, the tested
runtime/profile or the architecture boundary changes. Refresh it from the
linked owners/frontiers and rerun the affected gates; do not promote a guard or
logical codec into full part support based on this summary alone.
