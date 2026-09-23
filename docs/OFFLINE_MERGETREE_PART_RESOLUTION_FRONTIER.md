# Offline MergeTree Part Resolution Frontier

Document status: implemented and verified for the bounded physical-row scope
below. This is not a ClickHouse server-state or logical-query certificate.

Current frontier: for an immutable, single-disk Atomic table whose engine is
exactly `MergeTree`, resolve physical part candidates to one unambiguous set of
parts for an offline scan of stored physical rows. This is an inferred scan
set, not ClickHouse server `Active` state, a logical `SELECT` result, or a live
snapshot. The original catalog boundary is recorded
in [OFFLINE_CATALOG_FRONTIER.md](OFFLINE_CATALOG_FRONTIER.md).

## Factual anchor

The pinned ClickHouse checkout at `066ea77c` builds a part-loading tree from
part names, selects top-level covering parts for the initial Active load, and
loads covered descendants as Outdated. `MergeTreePartInfo::contains` requires
the same partition, enclosing block range, nondecreasing level and mutation,
and a strictly higher level for a strictly wider block range (except MAX_LEVEL).
`MergeTreeData::loadDataPart` also consults transaction metadata and handles
broken and duplicate parts; this offline slice does not reproduce that recovery.

Before this slice, `OfflineTable#part_candidates` was physical inventory and
its scan methods sent every candidate to `WidePartTable`, which rejected any
overlap. That was safe but could not read a table whose covering merge result
and older source parts coexist on disk.

## Admitted surface

- Preserve `part_candidates` as a full physical inventory. Add
  `resolved_scan_parts : Array(OfflinePartCandidate)` as an explicitly inferred,
  deterministic scan selection. All `OfflineTable#scan_*` entry points use the
  same resolver before opening selected Wide parts.
- Select maximal covering regular parts using the pinned ClickHouse containment
  relation. Keep disjoint parts in different or identical partitions. A covered
  part remains visible in `part_candidates` but is not scanned.
- Reject equal-info duplicates and overlapping pairs where neither part
  contains the other. Reject transactional metadata (`txn_version.txt` or its
  temporary form) on any candidate before returning a scan set or invoking a
  callback. Reject selected parts with a `_row_exists` lightweight-delete
  column or `delete_bitmap_*.rbm` sidecar before a row callback: the raw Wide
  reader does not apply those masks. Preserve existing bounded paths and
  selected-column checks.
- A selected covering part that fails to open or decode is an error. Do not
  silently fall back to covered children. Metadata and topology rejection is
  pre-callback, but later payload corruption can fail after earlier batches
  have been yielded because block decoding is lazy. Empty tables resolve to an
  empty set.

## Rejected and guard-only surface

- No claim that `resolved_scan_parts` equals server `Active`: replicated/Keeper
  expectations, transaction log and version visibility, concurrent changes,
  multi-disk policies, broken-part child fallback, and duplicate checksum
  reconciliation remain outside this scope.
- No interpretation of table-level pending mutations or on-read mutation
  steps. The caller must not equate the scanned physical rows with the
  server's current logical rows even when part-name selection is unambiguous.
- No partition/primary-key/skip-index pruning, predicate pushdown, SQL, or
  granule selection by key. This slice selects parts, not marks within them.
- No automatic support for lightweight-delete masks, patch parts, Compact
  parts, projections, or other unsupported reader formats. The mask guard
  above is fail-closed, not mask interpretation. Existing reader guards still
  apply.

## Falsifiers and stop rules

1. A copied public fixture under one part plus a containing name: inventory
   reports both, resolver selects only the containing part, and every scan
   variant yields one part's rows with no duplicate callbacks.
2. Mutation replacement with equal block range and higher mutation selects
   the replacement; a wider equal-level interval does not imply containment.
3. Partial overlap, equal-info duplicate spelling, and transaction metadata on
   a selected or covered candidate fail before any callback. A selected
   `_row_exists` column or delete-bitmap sidecar also fails before a callback.
4. Disjoint same-partition and cross-partition parts all remain selected;
   empty tables yield no callbacks.
5. A corrupt selected covering part errors rather than falling back to the
   covered part. A late payload error need not retract batches already yielded.

Observed DoD: focused catalog specs were red before implementation (16
examples, 2 failures and 1 error) and pass afterward (24 examples). Full
debug and release Crystal specs pass (212 examples each), as do formatting
and diff checks. A source-bound adversarial review found no blocker for this
physical-row scope after the late-payload atomicity claim was narrowed.

Rollback is one scoped feature commit. Evidence decays when part-name
containment, transaction metadata, or the offline catalog/reader contract
changes. Refresh with current ClickHouse source and fixture probes before
widening to logical snapshots or other MergeTree families.
