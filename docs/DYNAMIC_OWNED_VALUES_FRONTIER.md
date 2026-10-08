# Generic Dynamic owned values frontier

Document status: VERIFIED within the finite declared scope (2026-10-08).
Design baseline: `f0b5df59746a258762d4a37a607b416215c442a2`.
Execution antecedent: `551642a07d3284122d8b0e50d4a16a9f84929c10`
(separate legacy caller-range/budget-regression repair).
Bounded context: owned offline column materialization, not a new physical codec.

## Boundary

The existing `DynamicBulkColumnDeclaration`, `DynamicBulkColumnReader`,
recursive `BinaryValue` owners, and Dynamic table adapter already support a
bounded generic Dynamic-bearing grammar. `OfflineColumnValue` already admits
`BinaryValue`; before W220, `OfflineTable.materialize_selected_values` did not
route that grammar to an owned result. This slice propagates the existing contract;
it does not add a codec for each wrapper product.

Admitted surface:

- `catalog[db][table][column].values` returns owned immutable `BinaryValue`
  roots for declarations admitted by `DynamicBulkColumnDeclaration.parse`.
  Exact legacy `Dynamic` retains its existing specialized value API.
- Existing root, Array, Tuple, root Nested and recursively selected Dynamic
  carriers retain their nominal descriptors and runtime actual types.
  Ordinary bound JSON actual leaves and admitted inline Shared JSON reuse
  their existing physical readers without expanding their layout profiles.
- Complete-result row, String payload and recursive-cell limits accumulate
  across all marks and parts. Existing logical byte/node/element/depth bounds
  apply to the owned result, with logical stream bytes and known reader/replay
  containers included as one active part's workspace.
- Admitted declarations with no parts produce an empty result. This does not
  bypass declaration, ALIAS, materialized-view or hard-limit admission.
- Different actual-type rosters in different immutable parts remain legal;
  exact nominal declaration and row/mark identity remain mandatory.

Rejected/non-guaranteed surface:

- No new nominal JSON grammar, noncanonical spelling, buried Nested grammar,
  physical zero-row Dynamic part, unsupported layout or codec is admitted.
- No fallback to legacy decoding after generic corruption or schema mismatch.
- No public return-union expansion or change to exact legacy `Dynamic`.
- No whole-scan callback atomicity, process-RSS, allocator, performance,
  checksum-payload hash, MV SQL execution or projection-writing claim.
- The existing reader can decode full-part recursive descendants while
  replaying JSON/LowCardinality state. Those transient descendants are not
  exposed for pre-read measurement. Known stream/container workspace checks
  and cumulative retained-owner charges do not establish a full transient
  decoded-owner or 64 MiB peak-memory bound. This remains a later memory track.
- Projection selection retains the selected child's axes and the previously
  established physical-reader identity contract; this does not establish
  projection freshness or semantic provenance.

## Design laws

1. One dedicated materializer owns this handoff in its own file. Physical
   layouts and recursive values continue to belong to existing owners.
2. Admit the declaration before resolving an empty result. Validate every
   candidate's exact declaration, row count, mark grid and required full
   schedule before exposing a result. Reopening repeats identity checks.
3. Reserve the `Array(OfflineColumnValue)` header/union slots and nominal
   descriptor before result allocation. Reuse the shared recursive accounting
   visitor; do not reset the result budget at part or mark boundaries.
4. Check known logical workspace before full-schedule replay and each decode;
   conservatively reserve full-part mark/row containers, not just the requested
   mark. Charge a complete returned mark and its recursive descendants
   transactionally before appending its values. Do not infer a transient
   decoded-descendant bound from stream-byte accounting.
5. Values must be independently usable after the reader/callback lifetime;
   detached payload/element accessor mutations cannot affect retained values.
6. Preserve canonical source identity and runtime actual type independently.
   Never require equal Dynamic actual rosters between immutable parts.

## Executed implementation order

Risk: CAUTION (API/ownership/serialization consumer boundary).
Rollback: exact task-owned changes against the clean baseline; one coherent
local commit after gates pass. No push or history rewrite is authorized here.

1. Add `spec/dynamic_owned_values_w220_spec.cr` using the existing `.values`
   API. Execute a behavioral RED against unchanged production; a compiler
   failure or new missing method is not the expected discriminator.
2. Add `src/crystal_click/offline_table/dynamic_bulk_values_materializer.cr`,
   minimal admission/routing in `offline_table.cr`, and its require in
   `src/crystal_click.cr`. A shared transactional descriptor charge may be
   added to `object_values_materialization_budget.cr` if needed.
3. Execute focused tests in DEBUG and RELEASE, then affected Dynamic/offline
   catalog, legacy Dynamic, Object budget and projection consumer guards in
   serial resource-bounded cohorts.
4. Qualify owned `.values` on fresh stock-authored parts for the original
   W203 five carriers/two String profiles and existing Dynamic JSON profile
   witnesses. Compare exact literal values, nominal declarations and actual
   descriptors; do not accept library-only round trips as stock compatibility.
5. Perform hostile source review and an executed cumulative-budget falsifier,
   restore the seed, rerun its guard, then record actual evidence and update
   the project status before the atomic local commit.

Consumer inventory: `rg -n 'materialize_selected_values|dynamic_bulk_values_for|DynamicBulkColumnDeclaration|OfflineColumnValue' src spec scripts` identifies
the selection facade, offline materializer, generic batch adapter, existing
physical/native Dynamic consumers, and the already-admitted result union.
No CLI, writer profile or public accessor rename is planned.

## Falsifier roster and DoD

- Representative carriers/two String profiles retain exact values and types,
  including empty Array marks, nested Dynamic, LC/Variant siblings and NULL.
- Cross-mark and cross-part String/cell bounds fail cumulatively; exact
  sufficient bounds pass. Row and hard-limit checks retain prior precedence.
- Reader lifetime and detached-accessor mutation do not invalidate ownership.
- Nominal drift, corruption, unsupported empty selections, aliases and MV
  data access fail; different actual rosters do not fail.
- Runtime JSON actual payloads/metadata are charged and retained recursively.
- Full-schedule validation cannot be skipped for empty or unused child lanes.

Commands (ROOT only; serial `run_safe.sh`, minimum free memory 50 percent):

```text
crystal spec spec/dynamic_owned_values_w220_spec.cr --single-module --threads 1 --link-flags=-fuse-ld=ld --error-trace
crystal spec spec/dynamic_owned_values_w220_spec.cr --single-module --threads 1 --link-flags=-fuse-ld=ld --error-trace --release
```

Observed signals and exact broader cohorts, native commands/raw roots, source
hashes and executed seeds are indexed in the evidence packet below. These
are finite gates, not the repository-wide test suite or all-type qualification.
The full goal remains active.

## Implementation seal

The implementation has one private `DynamicBulkValuesMaterializer` owner in
its own file, a minimal facade route, and shared transactional descriptor/value
accounting. Complete schedules are preflighted; immutable part reopens retain
their own actual rosters; final union slots and retained data/structure grids
are charged. Exact legacy bare `Dynamic` dispatch remains unchanged.

The focused file passes 10 examples in each mode; the same seven regression
cohorts (40 unique files) pass 271 examples in each mode, all with zero
failures/errors/pending. The pre-implementation behavioral RED and actual
grid-zero/missing-mark-charge seeds discriminate their intended defects.

Fresh native DEBUG and RELEASE runs each cover 34 stock-authored source
parts through public `OfflineTable[column].values`, plus the existing 34
library direct ATTACH/CHECK witnesses. Source-side owned values are compared
by exact recursive encoding against independently constructed Crystal fixtures
and the low-level read. These native checks construct an `OfflineTable`
directly; full catalog/database discovery is exercised by Crystal specs, not
by the native helper. Library-side owned `.values` is not qualified here.

The separate Ruby audit passes both raw evidence matrices using externally
measured SHA256 pins of the observed helper builds. It checks reported
signatures, declarations, grids, census, raw CHECKs and source file/manifest
identity. W212/W213 signatures omit `maybe` and nested JSON descriptor details;
those details rely on the pinned helper's executed exact-encoding comparison,
not an independent decode by the audit. W210 hashes are recomputed without a
runner snapshot baseline. Eight actual clean controls pass and 66 in-memory
payload/type/grid/census/identity/CHECK/pin mutants are rejected; no raw
evidence files are modified. Scoped hostile verdict: ROBUST under these
explicit evidence boundaries, not all-layout compatibility or a peak-memory
certificate.

Evidence and decay policy:
[W220 evidence packet](../.landmark/evidence/dynamic-owned-values-w220.json).
Raw temporary artifacts are not durable; if unavailable, rerun the recorded
gates rather than treating this index as proof. Reader/writer type/layout
gaps, MV/projection support and broad facade extraction remain open.
Memory/performance follows those requirements; the original <=10 percent
speed-gap objective is unchanged.
