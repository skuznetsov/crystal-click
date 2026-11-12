# Offline projection window frontier (W229)

Status: VERIFIED within the finite quiescent offline child-window scope below
(scoped adversary verdict: ROBUST). Not full projection support.
Baseline: `3eeeb10cda0aabde95cf776b0ff9dc8120a21d45`.
Context: quiescent offline Atomic catalogs and explicitly selected Wide child
parts. The overall types/MV/projection objective remains active; performance
work is deferred.

W287 also verifies each selected child manifest against the parent manifest
before full or window scans. See the
[projection checksum profile](PROJECTION_PUBLICATION_FRONTIER.md#projection-checksum-binding-on-read-w287).

## Boundary and reason

`OfflineTable#scan_projection_typed` already reads explicitly declared
projection children using their physical schemas. The shared `WidePartTable`
projection factory already supports bounded row windows, but the offline table
does not expose that consumer. The change adds
`scan_projection_typed_window(name, columns, start_row, max_rows, &block)`
without a new serializer, projection execution or optimizer.

The existing full-scan and new window facade share a private
`OfflineTable::ProjectionReaderAdmission` owner in its own file. Ordinary
table-DDL selection stays on its existing path. Projection columns are checked
against child physical metadata, not the parent's DDL.

## Design laws

- Keep the materialized-view and exact MergeTree fences at each facade.
- Reuse bounded projection-name, declared-name, selected-column, row-limit,
  resolved-parent and complete-child/schema checks for full and window scans.
- Validate every selected parent's child before any callback, including a
  child outside the requested window and an EOF request. Never substitute
  parent data, counts or marks.
- Window coordinates are concatenated physical child rows in resolved-parent
  order. Batch identity remains the parent; local offsets and marks belong to
  the child. The resolved set is inferred, not server Active state.
- Positive `max_rows` is bounded by the existing table ceiling. EOF yields no
  callbacks; past EOF rejects. An empty resolved set admits only start zero,
  after the same argument and declaration guards.
- Existing reader ownership, per-mark budgets and complete specialized
  schedule validation remain authoritative. A window does not promise zero
  preflight I/O, whole-scan atomicity or a live consistent snapshot.

## Rejected and non-goal surface

Missing/symlink/malformed children, undeclared or unsafe names, unsupported
existing physical profiles, direct MV scans, general MergeTree-family engines,
projection writing, execution, optimizer selection, freshness/provenance and
server lifecycle remain outside this slice. This consumer does not widen
flattened Nested or any existing codec's admission. Full type coverage,
large-facade decomposition and the stock-reader 10-percent speed target remain
unproven.

## Execution and falsifiers

Risk: CAUTION (public storage consumer and shared admission extraction).
Rollback: one exact atomic local commit from the clean baseline; no push.

1. Add `spec/offline_projection_window_w229_spec.cr`; demonstrate behavioral
   RED on the unchanged production code. Keep W87 and ordinary-window controls.
2. Extract only projection admission from `src/crystal_click/offline_table.cr`
   into `src/crystal_click/offline_table/projection_reader_admission.cr`, loaded
   beside the other private offline-table owners in `src/crystal_click.cr`.
   Add the window facade delegating to the existing child window reader.
3. Run the affected catalog/projection/window and specialized-reader guards in
   DEBUG and RELEASE under the unchanged serial min-free-50-percent guard.
4. Build paired native helpers and compare stock-authored child full, middle,
   cross-part, EOF and past-EOF windows against independent fixed expectations.
   Include a grouped Count projection with child axes different from its
   parents, plus existing JSON/recursive/Dynamic projection consumers.
5. Attack parent-grid substitution and bypassed complete-child preflight;
   validate separate raw native evidence rather than trusting helper summaries.
   Update the frontier and evidence index only from observed signals.

Strongest failure: a superficially correct middle window uses parent row
counts or skips an absent child outside its interval. Guard checks use differing
parent/child axes, complete-parent missing-child controls and EOF negatives.

DoD: root-guarded `crystal spec` for the declared affected roster with
`--single-module --threads 1 --link-flags=-fuse-ld=ld --error-trace`, DEBUG and
RELEASE; guarded paired native helper runs and separate raw-artifact audits.
Expected signals: zero failures/errors/pending, actual stock CHECK=1, literal
child row equality and exact boundary refusals. No whole-suite claim.

## Observed result

The same 37 affected spec files pass 200 examples in DEBUG and RELEASE, with
zero failures, errors or pending examples. Six new window examples first
failed behaviorally against unchanged production; 22 retained controls passed.
A first-parent-only defect seed produced three failures and one error in the
six examples. Exact production restoration passed, including an intra-mark
crop with nonzero mark and child-local offsets.

Separate fresh stock fixtures qualify six finite profiles: whole typed JSON,
Array(JSON), Tuple(JSON, UInt64), Dynamic, Array(Dynamic), and Count aggregate
projection children. Each final mode records 62 successful native processes,
30 direct `mergeTreeProjection` window queries and 60 library window results
(low-level and offline consumers). Independent raw audits verify fixed literal
rows, child schemas/axes, CHECK rows, helper coordinates and unchanged actual
physical input files. The Count child has three rows per six-row parent, not
the parent row grid. Native past-EOF reads are empty; library past-EOF reads
intentionally raise BoundsError.

Hostile review exposed an auditor-only false positive: coherent CHECK output
with success `1` and a nonempty failure message passed the original predicate.
The final auditor requires exactly the two three-column success rows with
empty messages. Coherent message forgeries reject in both final modes despite
green process statuses and consistent byte/hash carriers; exact restoration
returns both raw audits to PASS. An earlier scratch attempt lost a terminal
tab and failed byte-count checking, so it was inconclusive, not the semantic
falsifier. Luna review is correlated; root inspected the changes and executed
all serialized verification and attacks.

DEBUG helper SHA-256:
`f058800b91e8ff08a05fada18908fd50207fac310bf99585ce0964f037a3e08f`.
RELEASE helper SHA-256:
`274bae7170a14e93972c7d18755b43435b516dc9b0ef583a2a6b08cd89d8ee03`.
The [scoped evidence index](../.landmark/evidence/projection-window-w229.json)
records commands, source pins, raw roots, compile-time helper repairs and
remaining boundaries. No projection writer, new codec or performance claim
is admitted by this slice.

## Source and refresh

Local anchors: `OfflineTable#scan_projection_typed`,
`WidePartTable.open_selected_projection_typed`, `WidePartTable#scan_typed_window`
and `WidePartTableBatch` coordinate fields. Stock anchors:
`StorageSystemProjectionParts.cpp`, `StorageSystemProjectionPartsColumns.cpp`,
`MergeTreeDataWriter.cpp` and `IMergeTreeDataPart.h` in the pinned shallow
checkout `/Users/sergey/SrcArchives/clickhouse-2026-10-07-depth1`, revision
`0ca8150d9b1d0886edb2e3b4ab65eebb768d0357`.

Stock runtime is separately pinned to 26.10.1.1201, build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`; it is not the source checkout build.
Refresh after facade/admission, child selection/reader, fixture/helper, source
or runtime changes. Temporary raw roots are evidence caches, not durable proof.

## Type-composition continuation

Child serde already composes recursively; do not add a serializer per type
product or confuse missing native qualification with a missing codec. The
source Array serializer transforms row offsets into child-element offsets and
delegates to the nested serializer. Stateful children still need a per-site
physical binding and occurrence schedule, not a different primitive codec.

The next concrete static-layout discriminator is `Array(QBit(BFloat16, 16))`:
the pinned source has a valid Memory-table witness in
`04817_window_partition_by_aggregate_function_state.sql`, but this is not a
MergeTree qualification. Local normal/wire Array descriptors reject QBit and
the static QBit bulk adapter binds only root/Nullable-root planes. Probe a
stock-authored Wide part with empty and uneven arrays across marks before
widening those bindings; reuse the existing QBit leaf on both read and write.

Other AggregateFunction families, such as numeric min/max, require genuinely
new state grammars. Wrapped Avg primarily needs outer-layout native evidence;
its leaf codec already participates in recursive routes. JSON aggregate/shared
envelopes, persisted borrowed Dynamic and the legacy fixed-union APIs retain
their current guards. Source-invalid trees remain rejected. These are separate
obligations, not one undifferentiated list of unimplemented combinations.
