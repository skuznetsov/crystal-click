# Direct JSON actuals in Dynamic — W206

## W209 finite component — normalized stop-owner handoff

Status: VERIFIED for the finite normalized component, 2026-10-07. Baseline: W208 commit
`867f1b042e8b0ae8c16bc1ba53cb9dfe8b1be205`. This slice implements actual
generic Bulk/Object value composition, not another metadata-only prerequisite.
Checkpoint B still requires physical/public part integration and fresh stock
bidirectional qualification after this finite slice.

The writer and reader select the exact W208 binding at the existing
ordinary Dynamic arm stop, reuse `BinaryJsonObjectAdapter`, and keep Object
child streams separate from ordinary BinaryBulk roles. Explicit bindings cover
every direct JSON actual at every site, including unselected arms. Existing
unbound constructors and physical consumers stay closed; wrapped/composite
JSON, SharedVariant inline JSON and Object-typed Dynamic do not widen.

For normalized streams, census every site's discriminator lane over every mark
before inspecting Object children. Positive root physical rows are P, Dynamic
occurrences are Q, selected JSON occurrences are R; Object child grids are
`(P,R)`. No statistics-derived schedule or `(Q,R)` substitution is permitted.
The finite reader may decode the complete parent and child mark domain before
returning a requested slice, so all Q/shape/consumption checks apply even to an
empty selected window. This is intentionally not a lazy physical-reader claim.
The census must not fabricate placeholder JSON values or add another serde.
The lane census alone does not certify that Q agrees with enclosing Array or
Variant schedules. A valid JSON tag beneath an Array declaring Q=0 must still
fail the final parent and child-cursor consumption checks before any result is
returned. Malformed inputs can therefore incur bounded child work before this
semantic rejection. Eager decoding can also exhaust the full-domain budget for
a small or empty selection; no selected-window cost guarantee is admitted.

Context boundary: normalized BinaryBulk discriminator lanes contain one byte
per Q occurrence. Stock Variant streams may contain BASIC or COMPACT headers
and per-granule framing (`SerializationVariant.cpp:478-501` at the source pin
below). Their discriminator decisions correspond, but their byte layouts do
not. A normalized census cannot be applied to raw part bytes or certify compact
physical decoding; that transfer requires the existing physical framing owner
and fresh witnesses. Changes to either representation reopen this bridge.

CAUTION: the likeliest false positive is a library-only round trip agreeing on
the wrong child schedule. Mandatory literals include Array P != Q, R=0 beside
R>0, an unused JSON arm, and corruption in an unselected mark. Complete child
metadata/plan identity and contextual site/index checks precede value output.
All census, binding, adapter, Object and generic work borrows one operation
budget with inherited depth; a new local budget is not a composition proof.

Ownership: `BinaryDynamicBulkPlan/Codec/Streams` own explicit bindings and the
paired child stream association; `BinaryBulkEncoder/Decoder` retain the sole
ordinary-arm dispatch; separate small JSON composition owners retain census,
collection and injection. `ObjectDocumentCodec` remains the Object serde
authority. Root owns require wiring, documents, compiler/native execution and
Git; Luna owns the implementation candidate and focused specification.

DoD: first execute a focused failing specification, then focused and inherited
affected DEBUG/RELEASE gates serially under `run_safe.sh`, with zero failures,
errors and pending examples and actual guarded exit 0. Attack missing unused
bindings, swapped site/arm, lost typed NULL, wrong P/R census and unselected-mark
corruption using unchanged specifications. Inspect the final intended diff
before one local atomic commit. Rollback is the exact relevant diff; no source
part, dependency, remote history or push changes are authorized.

Fresh reference checkout: `/Users/sergey/SrcArchives/clickhouse-2026-10-07-depth1`,
shallow, clean, commit `0ca8150d9b1d0886edb2e3b4ab65eebb768d0357`.
This source pin is not the separately pinned stock runtime build.

### Executed evidence and residual frontier

The same 187 affected files pass 1168 DEBUG and 1168 RELEASE examples. The
final focused gates pass 14 examples per mode. All four gates have zero
failures/errors/pending and actual guarded exit 0. The restored source/spec
identity is 981 files, SHA256
`d8d4978ff0ccd291f2c5a396919791dc017e4ed606347702c8b2b451bd620c5d`.
Scoped format and diff checks pass; no native workload was run in W209.

Literal normalized witnesses retain P=[2,1,1], Q=[0,2,3], used JSON R=[0,0,2]
and unused JSON R=[0,0,0], discriminator bytes [3,3,0,0,3] and offsets
[0,0,2,5]. Typed Nullable NULL, distinct per-site values under one immutable
Object plan, canonical unordered metadata identity and unused typed actual
depth 7/one-short depth 6 are exercised. W209 focused coverage uses the default
single-stream String profile, not every profile or Cartesian type product.

Four final production defect seeds reject with the focused specification
unchanged: losing budget identity gives two assertion failures; returning an
empty window before parent consumption gives one; accepting only equal roster
counts gives one; the typed-depth off-by-one gives one executed error. All nine
scoped source/spec hashes restore exactly; focused DEBUG/RELEASE gates execute
after restoration. Earlier compile failures and the invalid positive JSON-cap
fixture are recorded separately from behavioral evidence in the packet.

The inherited suite caught nominal JSON-containing Bulk descriptors slipping
past their old admission guard. Write and read plans now distinguish nominal
JSON from explicitly bound actual JSON before role planning. The W182 guard
specification is unchanged. Legacy 3/4-argument structure decoding and the
explicit 5-argument binding overload share one internal parser; the old W158
test-only hook is exactly restored rather than weakened. Census lookup uses
the existing site/arm map directly, not a binding scan for each discriminator;
no measured CPU, allocation or RSS improvement follows from that source fix.

Root independently inspected the P/Q/R literals, contextual owner association,
budget/depth preflight and final guarded results, including all four final
seeds. Luna implementation/reviews are correlated candidate evidence. Scoped
Adversary verdict: ROBUST for the normalized component and executed corpus.
Full checkpoint B remains IN_PROGRESS: physical framing/stream ownership,
public part/column/table propagation and fresh stock bidirectional witnesses
with CHECK/direct ATTACH still need qualification. Existing physical/public,
wrapped JSON and SharedVariant guards remain closed. The broader inherited
owner-accounting gaps, full types/layouts and MV/projections remain open;
performance is deferred.

Evidence index: `.landmark/evidence/dynamic-json-bulk-object-w209.json`. It is
an index to source identity, commands and observed logs, not proof by itself.
Changes to descriptors/rosters, occurrence schedules, budget/depth owners,
representation or source/runtime pins reopen the corresponding claims and
require their relevant gates. Rollback is the scoped atomic W209 commit.

## W206–W208 established frontier

Status: IN_PROGRESS. Checkpoint A is VERIFIED for metadata only; checkpoint B
is the next active capability. Baseline: `6fc5edcc7431522a39f250df784d06c62c313e7a`.
The overall types and MV/projections goal remains active; performance work is
deferred. Descriptor representability is not value-ready storage admission.

## Boundary and design

The existing scalar `BinaryValue.json` and `BinaryJsonRow` codecs own JSON
values. `DynamicStructure` owns the actual roster, canonical arm indices and
statistics. Persisted JSON streams belong to the existing Object owner. Reuse
those owners; do not introduce a second roster parser or per-product serde.

The next complete capability is an explicit ordinary Dynamic JSON arm handed
off to Object storage, including recursive Array/Tuple carriers. SharedVariant
inline JSON, Object-typed Dynamic, wrapped/composite JSON actuals and new
layouts remain rejected until separately qualified.

Necessary checkpoint A admits a direct `TAG_JSON` descriptor in Dynamic
metadata only, through the existing full/prefix/paired metadata codecs. It
retains exact descriptor parameters, canonical ordering, statistics and common
budgets. Every value-ready consumer without an Object binding must reject it,
including an unused arm. Metadata-only Object/Dynamic pairs remain metadata.

Checkpoint B requires an exact binding by Dynamic site and canonical ordinary
arm to an Object schema/plan. Its descriptor, caps, typed paths, inherited depth,
escaped prefix and physical streams must agree. Reader discovery is parent
first; writer bindings are explicit, never inferred from selected values.
Dynamic discriminators determine selected-arm order and counts. The Object
child receives physical parent P and selected-arm R, not site occurrences Q.
Shared codec/transport/name/materialization budgets cover the entire operation,
including owned JSON rows. No callback or publication precedes preflight.

Existing display-name work preflight remains opt-in at the internal metadata
context. W206 tests its exact conservative bounds with that mode enabled; it
does not introduce a default standalone-decode name-budget guarantee. A
malformed explicit child occurrence grid can reject before an unbound JSON
descriptor; no value lane is inspected by that earlier grid validation.

## Plan, risk and rollback

CAUTION: metadata widening can accidentally admit an unbound unused JSON arm.
Rollback is the exact relevant diff from the clean baseline; no dependency,
runtime, remote history or source-part mutation is authorized.

1. Add red checkpoint-A metadata and consumer-guard tests. Root executes the
   compiler once before production changes; Luna candidates execute no heavy
   workloads.
2. Narrow the common metadata gates to direct JSON only; add explicit missing
   value-ready guards. Keep physical/value admission guards intact.
3. Create a fresh stock-authored nonempty Dynamic JSON part with explicit casts.
   Read its actual metadata through the common codec and assert independent
   descriptor/statistics literals plus byte-exact re-encoding. This witness
   qualifies metadata only, not JSON Dynamic value interoperability.
4. Root runs the affected DEBUG/RELEASE gates serially under `run_safe.sh`,
   attacks unused-arm and wrapped-arm admission, checks the intended diff and
   records a local atomic checkpoint-A commit without pushing.
5. Implement checkpoint B with the existing Object child-site APIs, a bounded
   row adapter and the common occurrence traversal. Qualify nonempty and sparse
   arms through public part/column/table APIs and fresh stock interoperability.

## DoD and strongest falsifiers

Checkpoint A: focused tests first fail on representability, then focused and
exact affected tests pass DEBUG/RELEASE with zero failures/errors/pending and
guarded exit 0. Tests cover full/prefix/paired metadata, canonical names/indices,
statistics, exact/one-short budgets, direct versus wrapped JSON and unused-arm
rejection in bare Dynamic values and root/typed Object plans. A fresh native
metadata witness passes literal and byte checks; no full-value claim follows.

Checkpoint B: public complete-part writer, recursive reader and table callback
recover exact JSON rows and descriptors with mixed JSON/non-JSON/NULL values,
Array nesting, full/later/middle/final/zero windows, and P>0,Q>0,R=0. Both
directions against the pinned stock runtime pass independent stream/value/type
literals, CHECK and direct ATTACH of library-written parts. Missing/wrong
bindings, depth/budget failures, stream collisions and SharedVariant JSON reject
without publication/callback. Whole-part zero-Q qualification remains intact.

Strongest failure: metadata acceptance silently bypasses storage admission, or
both library owners agree on a wrong selected-arm grid. Unused-arm rejection
distinguishes the first; independently authored stock parts and stock reads of
library parts distinguish the second. Model agreement is not execution evidence.

## Checkpoint A evidence — 2026-10-07

The new two-file tests first reached six metadata-representability errors on
unchanged production (10 examples; no assertion failures). An earlier compile
error in the test's nested Array annotation was repaired before production GO
and is not counted as behavioral RED. The common Dynamic metadata owner now
admits only direct JSON. Bare Dynamic values and root Object plans explicitly
reject unbound JSON actuals, including unused arms. The existing typed Object,
physical/bulk, wrapper and SharedVariant guards remain; scalar RowBinary
Dynamic(JSON) is unchanged.

Root executed the same 184 affected files in DEBUG and RELEASE: 1136 examples
per mode, zero failures/errors/pending and guarded actual exit 0. Focused gates
pass 22 examples in each mode. Temporarily disabling both new guards causes
three unchanged-test failures (including an accepted root Object plan); exact
hash restoration and the focused DEBUG gate pass again. This is a guard
falsifier, not persisted JSON-value interoperability.

Each final native mode creates one fresh eight-row Wide Dynamic part, with
four two-row marks plus the terminal mark. Stock CHECK and eight independent
JSON/type/shared-state literals establish source provenance. The prebuilt
helper compares independently authored 23-byte Dynamic V3 metadata, statistics
offset 19, counts [8,0], exact JSON caps/typed path and canonical indices, then
performs byte-exact common-codec re-encoding. All 27 source files remain
unchanged per mode; reports and part bytes agree between modes. The selected
Object-arm stream roster is observed, not independently qualified by W206.
There is no library-written part or ATTACH in this metadata-only witness.

Root repaired and retained two oracle defects before final qualification:
the helper's expected input-key list was not sorted; a report merge overwrote
the helper executable identity. The latter has a red/green Ruby regression.
Exact native stdin is now retained alongside its hash. Twelve semantic oracle
mutations reject, and the independent root audit checks raw invocation, pin,
SQL, literal, helper and unchanged-file records. Final formatting and
`git diff --check` pass. Luna reviews remain correlated candidate evidence.

Evidence index: `.landmark/evidence/dynamic-json-metadata-w206.json`. Temporary
raw captures are referenced by path and digest, not durable storage guarantees.
The source archive is the clean shallow Oct 5 snapshot
`ef037e60fc7f5654c8c80eefb8be82e3c56f9a67`, not Oct 7 latest or the runtime's
build source. Native pin: 26.10.1.1201 / build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`. Scoped verdict: ROBUST for checkpoint
A; the overall goal and checkpoint B remain incomplete. A changed descriptor,
roster, budget/admission owner, layout, runtime pin or source invalidates the
affected certificate and requires rerunning its gates.

## Checkpoint B prerequisite — W207 retained JSON owners

Status: VERIFIED for the scoped JSON-owner extension. Baseline: `19ae216`.
The existing `ObjectValuesMaterializationBudget` public storage/document
visitors inspect `BinaryValue.element_count`, but a structured JSON value owns
its entries through `BinaryJsonRow`, not that generic children array. Its
nominal typed paths likewise live in `BinaryJsonType`. Both owners therefore
require explicit accounting before persisted Dynamic JSON values can be
returned through the shared materialization boundary.

CAUTION: a missed owner admits excess retained data; restarting depth at a JSON
row or descriptor permits nested callers to bypass the limit. This is a typed
logical accounting model, not a process RSS or allocator guarantee. Rollback
is the exact scoped diff/local commit; no storage admission, dependency or
runtime change belongs to this prerequisite.

Plan and ownership:

1. `spec/dynamic_json_materialization_w207_spec.cr`: establish RED through the
   current public storage/document charge APIs. Use independently counted
   String payloads plus exact/one-short retained bytes, nodes, elements, cells,
   inherited depth, typed NULL and unused typed descriptor cases.
2. `src/crystal_click/object_values_materialization_budget.cr`: visit the
   immutable row entries and nominal typed roster under the same Usage
   accumulator and inherited depth. Charge path String owners as metadata,
   not String value payload. Preserve all-or-nothing counter admission. The
   row and value descriptors may be equal but distinct owners; charge both
   trees in that case, but do not charge the same root reference twice.
3. Root executes focused and affected DEBUG/RELEASE gates under `run_safe.sh`,
   seeds the missing JSON visitor to falsify the guards, and reviews the diff
   before an atomic local commit. Expected signal: all declared gates have
   zero failures/errors/pending and actual guarded exit 0; the seed rejects.

DoD command shape: the guarded Crystal `spec` command with the W206 ordered
affected roster plus the new W207 spec, `--single-module --threads 1
--link-flags=-fuse-ld=ld --error-trace`, repeated with `--release`. The focused
gate includes the existing Object catalog and recursive-storage budget specs.
Checkpoint B still requires exact arm binding, Object child P/R schedules,
public reader/writer propagation and stock interoperability in both directions.
This prerequisite cannot certify or admit those missing capabilities.

The spec-only guarded reproduction reached eight assertion failures in eight
examples, with zero errors/pending and actual exit 1 on unchanged production.
Empty JSON owners measured 488 rather than the independent 584-byte logical
model; two nested String values measured zero rather than four payload bytes.
Both inherited row depth and unused typed descriptor depth were admitted past
their limits. This behavioral RED, not an invalid test or compilation failure,
authorized the scoped visitor change.

Root's hostile pass then found a feature-local counterexample:
`BinaryValue.json(type, row)` requires structural equality, not reference
identity, and retains both supplied descriptors. The ninth spec constructs
equal-but-distinct JSON roots and their typed rosters; it first fails with
1354 rather than the independently calculated 1927 logical bytes. The JSON
branch now charges `row.type` at the same inherited depth when its root owner
differs from `value.type`. Shared-root exact formulas remain unchanged.

The inherited generic model is not complete for every admitted child:
untyped runtime JSON can contain an Interval descriptor whose sidecar header
is not measured; typed/runtime SimpleAggregate children retain an unmeasured
sidecar and copied storage-name String. AggregateCount's separate argument
descriptor is also unmeasured outside JSON (JSON rejects that tag). QBitType
is an inline struct, not another heap owner; QBitValue needs its own broader
audit. W207 covers the new JSON owners and tested profiles, not a complete
generic-owner, unique-allocation or RSS bound. Those residuals must be audited
before a broader materialization guarantee or expanding the binding profile.

Final qualification supersedes the initial eight-example green snapshot. The
same 185 affected files pass 1145 DEBUG and 1145 RELEASE examples; focused final
gates pass all nine examples per mode. All have zero failures/errors/pending
and actual guarded exit 0. Independently disabling the JSON row branch, JSON
typed-roster visitor and distinct row-descriptor charge produces eight, five
and one failures respectively in the unchanged nine-example suite. Canonical
source/spec hashes were restored before the final affected and focused gates.
An earlier no-op mutation failed compilation and is excluded from behavioral
evidence. Final formatting and `git diff --check` pass.

Evidence index: `.landmark/evidence/dynamic-json-materialization-w207.json`.
Scoped verdict: ROBUST for the explicit JSON-owner extension and tested logical
profiles; inherited generic-owner completeness remains open as listed above.
Root checked the live ownership graph, independent formulas, REDs, mutations
and raw guarded results; Luna's implementation/review are correlated evidence.
No native workload, wire-layout or storage-admission change belongs to W207.
Changes to owner representation, visitor/depth rules, descriptor grammar or the
tested source reopen this certificate. The overall goal and checkpoint B are
still incomplete; performance remains deferred.

## Checkpoint B continuation — distinct schedules

Keep physical mark rows P, logical Dynamic occurrences Q, and selected JSON-arm
occurrences R separate. Even below Array, every Wide `.mrk2` third word remains
the part's P; Array/Variant serializer offset/limit transformations govern Q/R
payload counts, not persisted mark rows. The pinned source establishes this in
`MergeTreeDataPartWriterWide.cpp:677-685,474-483`; the existing recursive reader
checks Object child physical rows against the root mark schedule. An initial
candidate proposal that substituted Q for child physical P was refuted by these
source/consumer anchors before implementation.

Proposed bindings are exact `(Dynamic site, canonical ordinary JSON arm)`
identities, derived from the prepared actual roster and paired with an existing
Object plan. Reader discovery needs a complete per-mark discriminator census
before inspecting Object children with `(P,R)`; aggregate structure statistics
cannot recover R. Array's site uses `(P,Q)`, followed by discriminator selection
Q to R. The generic bulk stop-owner integration, actual-only JSON dispatch,
public reader/writer propagation and fresh two-way stock qualification are
still proposed, not admitted by W207. A mixed witness must include positive
P/Q with R=0 and a case where Array Q differs from P.

The physical hook belongs to `BinaryBulkEncoder.write_value` and
`BinaryBulkDecoder.decode_value` after selecting the exact ordinary arm. Do not
create a second lane/grid owner in the separate paired `DynamicValueCodec`
path. Static `StorageColumnSchema.has_json?` cannot infer actual JSON from a
nominal Dynamic type; actual-only recursive/table dispatch needs parent-first
roster discovery and a validated union of Object stream owners. JSON below
internal BinaryBulk Array/Tuple sites requires the census to traverse those
parent schedules too, rather than silently using a root-only tag count.

## Checkpoint B first component — W208 binding and logical row bridge

Status: VERIFIED for this finite logical component. Baseline: `5536097`. This is an implementation step toward
checkpoint B, not a replacement for its public-part and stock interoperability
DoD. Existing physical and paired value-ready JSON guards remain unchanged.

The binding must associate an exact raw Dynamic site key and canonical ordinary
JSON arm with its immutable descriptor and the existing Object plan. Derive the
Object schema directly from BinaryJsonType caps and typed descriptors, without
rendering and reparsing a type name. Validate the complete plan, including an
unused arm, before returning a binding. A shared arm, absent ordinary descriptor,
wrong canonical index, mismatched caps/typed paths or unsupported declaration
must not become a logical binding. The binding establishes identity and schema
association only; the existing Object codecs remain the physical admission
authority for each row and lane. It does not certify universal value readiness.
Rows and documents have no outer Dynamic-site provenance. The adapter cannot
infer which enclosing site produced them: its caller must select the binding
by exact site/canonical arm and call `validate_for!` against the contextual
roster. W208 exposes that check but introduces no physical consumer which
enforces the obligation; such enforcement belongs to checkpoint B integration.

The logical adapter borrows immutable BinaryValue children while copying the
row's path collection into the other owner. It preserves exact typed values,
including typed Nullable NULL; only an untyped Nothing NULL is omitted. Object
paths outside BinaryJsonType's admitted raw-path grammar and missing typed
values reject. No textual JSON conversion, second serializer or inferred schema
belongs to this bridge. This logical step has no physical layout certificate.

CAUTION: an apparently lossless row conversion can erase nominal schema or
restart a recursive allowance. One caller-owned BinaryCodecBudget and inherited
depth must govern descriptor/value work and path copies across sibling rows.
The new borrowed-budget entry points accept either direction: a reader may
discover a binding from actual metadata, rather than reuse a writer's schema.
Read-side budget failures remain corruption; existing convenience constructors
retain their write-direction defaults. No unchecked preflight receipt is public.
Rollback is the exact local diff or atomic commit; no dependencies, native
runtime, source parts or remote state change.

Component plan (steps 1-3 executed; step 4 remains open):

1. Establish missing-API RED before production changes, then save the focused
   `spec/dynamic_json_object_bridge_w208_spec.cr` before implementation;
   distinguish absent API compilation from executed assertion failures. Cover
   exact identity, typed NULL/absence,
   immutable child reuse, invalid raw paths, wrong/unused arm and schema-plan
   mismatch, inherited depth and aggregate limits in both directions.
2. New `DynamicJsonObjectBinding` and `BinaryJsonObjectAdapter` owners, one class
   per file: implement only the exact binding and logical conversion. Shared
   codec-budget accounting is logical work/copy accounting, not retained-owner
   RSS; W207's inherited generic sidecar gaps remain open.
3. Root runs focused and relevant affected specs in DEBUG/RELEASE serially under
   `run_safe.sh`, seeds a bridge defect and checks restored canonical sources.
   DoD signal: zero failures/errors/pending and actual guarded exit 0; the seed
   must reject. Format and scoped diff checks precede an atomic local commit.
4. Continue checkpoint B by consuming these owners at the BinaryBulk ordinary
   JSON stop-owner hook, full-grid P/Q/R census and public reader/writer/table
   propagation, then execute fresh stock interoperability in both directions.

The strongest falsifier is a bridge that agrees with itself after discarding a
typed NULL, cap, nominal child descriptor or inherited depth. Independent
expected row/schema literals and an unchanged-test defect seed target that
failure; a bridge roundtrip alone is insufficient. Physical parts, ATTACH,
SharedVariant JSON, nested JSON owners and arbitrary layouts remain unqualified
by this component.

### W208 observed qualification

The exact ordinary-arm binding and logical adapter are implemented in separate
files. Existing BinaryJsonRow and ObjectDocumentSchema expose caller-owned
budget/depth entry points in both directions; the adapter borrows child values
instead of converting textual JSON or introducing a product serializer.

The final focused pair contains nine W208 examples and nine W181 guard examples.
All 18 pass DEBUG and RELEASE; the same 186 affected files pass all 1154 examples
in each mode. Every final gate has zero failures/errors/pending and actual
guarded exit 0. Final seven-file `format --check` and scoped `git diff --check`
pass. The 978-file src/spec identity is
`ce03712f1ecbee910e6998f69823a98e1a6650ebdd88603b96d3ae19dc2300e3`;
the evidence index records its encoding, exact file hashes and ordered roster.

The first RED was absent API compilation, not an executed behavioral failure.
Initial constructor compilation and an executed second-sibling budget error
were fixed before the initial eight-example green result. The affected corpus
then exposed an old exact-counter fixture: equal Array(Nullable(UInt8)) values
retained a separate descriptor graph. Independent accounting is 14 nodes/12
edges with a shared root and 20/16 with the two distinct runtime traversals.
The fixture and its one-short limits now use 20/16; a ninth W208 literal test
compares both ownership cases. No bound was removed to make the corpus pass.

Four unchanged-test defect seeds discriminate wrong site, omitted reverse
ObjectDocument source owner, dropped typed Nullable NULL and omitted distinct
descriptor preflight. They cause one assertion failure, one assertion failure,
one executed missing-key error and two assertion failures respectively. The
first three seeds used the original eight-example spec; the fourth used the
later nine-example spec plus the nine W181 guards. Canonical source/spec hashes
were exactly restored after each phase. A subsequent comment-only correction
preceded all final focused/affected gates; the packet preserves these phases
instead of claiming every seed ran against the final spec hash.

Independent one-path literals measure seven logical nodes/three edges in both
adapter directions, with 22 forward and 15 reverse logical bytes. These bytes
include path metadata and temporary/detached key copies, not allocator/RSS
accounting; the UInt64 child is borrowed. Nested JSON can cross this logical
bridge while the existing persisted SharedVariant owner still rejects it.

Evidence index: `.landmark/evidence/dynamic-json-object-bridge-w208.json`.
Root inspected the live graphs, formulas, contextual preconditions, REDs,
mutations and raw guarded exits. Luna's implementation/review are correlated
candidate evidence. Scoped verdict: ROBUST for this logical bridge and tested
profiles. No native workload, physical layout/admission, complete part, ATTACH
or CHECK belongs to W208. Changes to contextual binding/consumer use, descriptor
grammar, owner representation, accounting/depth rules or tested source reopen
this certificate. Full checkpoint B still needs exact binding collections,
parent-first stream/roster discovery, P/Q/R census and public-part stock gates;
performance remains deferred and the overall goal remains active.
