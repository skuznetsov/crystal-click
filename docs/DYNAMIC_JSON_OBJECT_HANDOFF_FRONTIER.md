# Direct JSON actuals in Dynamic — W206

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
