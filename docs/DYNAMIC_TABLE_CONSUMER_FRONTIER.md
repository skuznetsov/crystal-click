# Dynamic table consumer frontier

Document status: implemented and verified for the finite W211 slice (2026-10-07).
Current frontier: `WidePartTable` exposes the existing physical Dynamic-bearing
reader through a bounded generic typed-batch adapter. Physical serialization
admission is unchanged; the full project goal remains open.

W212 extension (2026-10-07): the same typed-batch route composes newly bound
wrapped ordinary Dynamic JSON actuals through the existing reader. Exact JSON
leaf identities and complete child schedules are established by the physical
reader, not a separate table codec. Fresh stock/library native table witnesses
and the affected corpus qualify this extension; see
[DYNAMIC_JSON_RECURSIVE_FRONTIER.md](DYNAMIC_JSON_RECURSIVE_FRONTIER.md).
The historical W211 evidence below remains scoped to its original admission.

## Scope and design laws

This slice propagates existing Dynamic bulk storage into `WidePartTable`.
It does not add a new leaf codec or change physical serialization admission.
Use the bounded `ObjectRecursiveDeclaration` parser already used by physical
readers, including its inherited declaration restrictions. A separate table
declaration owner may adapt canonical root Nested through its implicit named
Tuple, with inherited depth/budget and exact nominal render-back. Do not widen
the Object parser or normalize retained Nested identity to Array(Tuple).
A parsed nominal
descriptor must contain Dynamic, contain no nominal JSON, and retain exact
canonical declaration/source identity. Root, Array, Tuple and Nested carriers
compose through the same reader, not product-specific codecs. Nested buried
inside other nominal wrappers remains deferred where the inherited grammar
does not admit it.

The admitted accessor is
`WidePartTableBatch#dynamic_bulk_values_for(column) : Slice(BinaryValue)`.
Its outer slice is callback-borrowed; callers must copy it to retain rows.
Keep `recursive_values_for` under its existing nominal-JSON contract. Preserve
the legacy exact bare `Dynamic` route and its specialized accessors. Selecting
the generic route must fail closed on metadata mismatch or corruption, never
retry a different physical codec.

Each part validates its own actual and physical stream rosters. Across parts,
compare declared type and source identity, not the discovered actual roster:
two immutable parts may legitimately contain different alternatives.

Before any callback, validate every selected reader's complete parent schedule
and bound child roster, even if no candidate marks or rows are selected.
Use the existing full-domain replay where needed for bound JSON/LC children;
do not claim selected-window IO complexity or global callback atomicity.

Retained values share the existing per-mark materialization cap with other
selected columns. Reserve derivable row ownership before decode, then charge
all BinaryValue descendants atomically before exposure. This is logical
ownership accounting, not a transient allocator/RSS bound. Existing codec and
transport limits remain in force during decode.

## Rejected and deferred

- Nominal JSON-bearing BinaryBulk declarations and currently rejected actual
  combinations stay rejected, including inline JSON in SharedVariant and
  unbound JSON inside Object path Dynamic. W212 admits exact bound wrapped
  ordinary JSON leaves, not every wrapper/layout product.
- Numeric-only scans, UInt64-only scans and typed projections cannot silently
  accept this new reader. Projection/MV consumer propagation is separate.
- Owned `OfflineColumn.values` materialization is not admitted by a batch API.
- No live-server system-table, Active-state, filesystem snapshot, whole-file
  checksum-hash, all-layout, memory optimization or performance claim.

## Falsifiers

1. Existing APIs must fail before implementation for a valid canonical root
   Dynamic bulk part; the failure must be executable, not missing-method-only.
2. Read root/Array/Tuple/Nested carriers and nested actual Dynamic trees through
   typed table batches; literal values, row offsets, candidate/middle/final/
   end-empty windows and both String profiles must agree.
3. Same declared schema with different valid actual rosters across parts
   succeeds; declaration/source/mark-grid drift fails before callbacks.
4. An unused bound JSON child's corrupted metadata or payload is rejected even
   for an empty candidate selection; no callback is exposed.
5. Aggregate retained-owner exhaustion prevents exposure of the offending
   mark; atomic budget charging leaves counters unchanged on rejection.
6. Missing column, wrong accessor, non-Dynamic or nominal-JSON declaration,
   wrong value descriptor and row count cannot acquire this batch contract.
7. Exact bare Dynamic accessors and numeric/projection guards retain behavior.
8. Fresh stock-authored fixtures must be consumed through the new table route;
   library parts retain existing direct ATTACH/CHECK witnesses. Self-round-trip
   and source shape alone do not establish interoperability.

## Implementation plan (executed)

Risk: CAUTION (table API/routing and ownership accounting).
Rollback: clean baseline commit `66b7c690ab369b059a53d29e6ee3bf231032213c`;
revert only this coherent local commit after verification. No history rewrite.

1. Add an executable RED spec using existing open/scan APIs, then root runs it
   while production source is frozen.
2. Add one cohesive adapter in
   `src/crystal_click/wide_part_table/dynamic_bulk_column_adapter.cr`; bounded
   declaration admission, identity checks, complete schedule and per-mark
   ownership are its responsibility. Keep declaration adaptation in its own
   `src/crystal_click/dynamic_bulk_column_declaration.cr` owner; reuse the
   existing grammar and serializers rather than adding carrier codecs.
   A minimal guarded `BinaryDataType.nested(tuple)` overload reuses the
   already-admitted implicit named Tuple rather than duplicating its graph.
3. Propagate through `src/crystal_click/wide_part_table.cr`,
   `src/crystal_click/wide_part_table/wide_part_table_batch.cr` and the require
   roster. Reuse the bounded selected-declaration probe through a minimal
   facade in `src/crystal_click/wide_part.cr` and
   `src/crystal_click/wide_part/selected_json_metadata_probe.cr`; preserve
   exact-name versus virtual JSON-path ambiguity rejection. Do not eagerly
   validate unrelated physical codecs merely to select a declaration.
   Inventory of recursive readers/values and complete-schedule validation
   identified constructor, three narrow
   scan guards, preflight/materialization, callback installation and schedule
   validation. Preserve those existing consumers.
4. Reuse the BinaryValue visitor in
   `src/crystal_click/object_values_materialization_budget.cr` through a typed
   transactional charge method. Expose only minimal necessary delegates in
   `src/crystal_click/dynamic_bulk_column_reader.cr`.
5. Add `spec/dynamic_table_consumer_w211_spec.cr`,
   `spec/dynamic_table_budget_w211_spec.cr`, budget/guard tests and table
   witnesses to existing W203/W210 native helpers. Workers never run builds,
   native processes, network or Git; root runs workloads serially.
6. Root inspects the candidate and runs focused DEBUG/RELEASE specs and the
   affected table/Dynamic/recursive/budget/projection regression corpus with
   the unchanged guarded runner. Native helper modes must pass literal table
   assertions on fresh isolated stock-authored parts.
7. Root attacks empty-selection validation and aggregate charging with seeded
   defects, restores exact source, reruns gates, records scoped evidence and
   commits exact relevant paths. No push is authorized by this slice.

DoD commands: guarded `crystal spec` for the W211 focused specs and enumerated
affected corpus, DEBUG and RELEASE; guarded builds/runs of W203/W210 native
helpers and probes against the pinned stock runtime. Expected signal: executed
tests and native literal assertions pass with exit 0; seeded violations fail.

## Executed evidence and claim boundary

The same 79 affected spec files pass 374 examples in each mode, with zero
failures/errors/pending and actual guarded exit 0. DEBUG uses five disjoint
cohorts; RELEASE uses sixteen. Three larger compiler invocations exceeded the
unchanged 12 GiB guard, executed no tests, and are excluded from these passes.
Final focused gates pass 13 examples per mode. No repository-wide suite claim
is made.

Fresh W203 witnesses cover five Dynamic-bearing carriers in both String
profiles; W210 covers root/Array direct Dynamic(JSON) in both profiles. The new
table path checks stock-authored values, candidate scans, offsets and empty
selections. Stock ClickHouse directly ATTACHes and CHECKs 14 library parts per
mode. All 510 generated part files match across DEBUG/RELEASE. Root checked
raw invocation bytes/hashes, actual exits and unchanged executable identities.
Source reference `0ca8150d9b1d0886edb2e3b4ab65eebb768d0357` is distinct from
runtime 26.10.1.1201, build `d9bcb5ab007f0f6299f7f973f2642245bab3d028`.

Three executed defects are rejected by unchanged assertions: skipping complete
empty-selection validation (two failures), dropping cumulative Dynamic column
charges (one failure), and omitting the Nested prefix-width charge (one
failure). Exact source restoration precedes final gates. A native helper's
Iterator-to-Array argument correction affects only two helper sites; an
in-memory reconstruction recovers the exact earlier 1,155-file input hash.
Production/spec inputs are identical across the unit corpus and final native
gates. The correction is not counted as a failed interoperability observation.

Scoped Adversary verdict: ROBUST for these admitted declarations, executed
profiles and guards. Delegated source review is correlated; root independently
ran the semantic gates, defect seeds and native probes. Logical mark ownership
is not transient allocator/RSS control. Full-domain JSON/LC replay is not lazy
selected-window I/O, and earlier callbacks are not globally transactional.

The curated index, exact commands, rosters, input lineage and local raw evidence
roots are in `.landmark/evidence/dynamic-table-consumer-w211.json`. Refresh
after changes to admission, scheduling, budget visitors, helper assertions,
String profiles or the runtime pin; re-run affected gates and fresh native
probes. Caller-quiescent part files remain an assumption, not a snapshot proof.

## Continuation

The full project goal remains open: remaining CH types/layouts, writer parity,
MV/projections, repository class decomposition, then memory/performance work
and the requested comparison to original ClickHouse. This slice closes only
an existing reader's table consumer, not that objective.
