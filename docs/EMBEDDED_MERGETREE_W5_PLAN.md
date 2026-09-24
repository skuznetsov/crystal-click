# Embedded MergeTree W5 Logical Merge Plan

Status: verified locally on Darwin for the bounded W5 contract. Governed by
`EMBEDDED_MERGETREE_FRONTIER.md` W5. The focused suite passed 20 examples;
full debug and release suites each passed 293 examples. Both pinned
ClickHouse physical oracles passed. The pre-marker orphan state was
constructed in a test, not reached by an injected process death.

## Scope and rollback

Risk: CAUTION. W5 changes persistent part visibility, overlap semantics, and
capacity accounting inside `EmbeddedMergeTreeTable` only. The API remains a
separate Crystal-owned root with the W4 `UInt64`/`String` schema and `all`
partition. It does not edit a ClickHouse data root, mutate old parts, delete
history, change `OfflineCatalog`, or modify generic `WidePartTable` overlap
policy. Rollback is one W5 feature commit; user-created table roots remain
untouched. No remote push is in scope.

Bounded consumer inventory:
`rg -n 'EmbeddedMergeTreeTable|\.part_paths|\.orphan_part_names' src spec examples scripts`
found the W4 facade, its focused spec and one example, but no other source
consumer. W5 changes that facade's selected set; existing W4 lifecycle,
read-lock, and writer-race specs are regression consumers. `WidePartTable`
receives only resolved disjoint paths and keeps its own overlap rejection.

## Steps and discriminating checks

1. Add RED cases in `spec/embedded_merge_tree_table_spec.cr`: stable interleaved
   key merge including duplicate, empty, binary, and UTF-8 Strings; source
   paths remain immutable; wrong-order, non-neighbor, stale, and over-limit
   merge requests publish nothing. The missing merge API should be the first
   failure signal, not an unrelated compiler error.
2. In `src/crystal_click/embedded_merge_tree_table.cr`, widen only the W4
   inventory to recognize bounded positive-level merge names. Partition
   physical orphans from marked parts before overlap resolution; choose
   maximal marked intervals and reject partial or equal-range overlaps.
   Pre-mortem: a pre-marker merge orphan poisons reopen or a post-marker
   read double-counts old rows. Guard: explicit old/after snapshots and
   negative overlap tests.
3. Add `merge_adjacent` under the existing exclusive lock. Bound rows and
   payload bytes before publication, perform a stable two-way row merge,
   choose an unused positive output level even after an orphaned attempt,
   use the unchanged W3 writer, then publish one exclusive commit marker.
   Recovery probes must cover an overlapping orphan and retry, post-marker
   reopen, and unchanged historical source directories. Capacity preflight
   must keep both active and historical inventories readable.
4. Add `scripts/check_embedded_merge_oracle.sh` using only synthetic data and
   the pinned stock ClickHouse local build. Attach the merged positive-level
   output in an isolated store, compare exact rows and a key-range result,
   and require `CHECK TABLE`. A Crystal-only readback is insufficient for a
   physical compatibility claim.
5. Extend the embedded-table example and README, then run focused/full debug
   and release specs, old and new physical oracles, format, shell syntax, and
   exact staged diff checks. Independently inspect the final code path and
   attack the recovery and capacity assumptions before one atomic commit.

## Definition of Done

At the final source state, the focused W5 recovery and row-equivalence cases
pass; full debug and release suites pass; both ClickHouse physical oracles
pass; formatting, shell syntax, and diff checks pass. An orphaned merged
part must not change visible rows; the marker must change selection exactly
once; overlapping marked corruption must fail closed. Changing the writer,
reader, manifest/marker layout, filesystem publication behavior, or pinned
ClickHouse version reopens the corresponding evidence.

```sh
CC=/usr/bin/clang CRYSTAL_CACHE_DIR=/private/tmp/crystal-click-w5-cache crystal spec spec/embedded_merge_tree_table_spec.cr
CC=/usr/bin/clang CRYSTAL_CACHE_DIR=/private/tmp/crystal-click-w5-cache crystal spec
CC=/usr/bin/clang CRYSTAL_CACHE_DIR=/private/tmp/crystal-click-w5-cache crystal spec --release
bash scripts/check_wide_part_writer_oracle.sh
bash scripts/check_embedded_merge_oracle.sh
crystal tool format --check src/crystal_click/embedded_merge_tree_table.cr spec/embedded_merge_tree_table_spec.cr examples/embedded_merge_tree_table.cr
bash -n scripts/check_embedded_merge_oracle.sh
git diff --check
```
