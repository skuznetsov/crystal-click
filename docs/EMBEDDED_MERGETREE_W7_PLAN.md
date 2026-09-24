# Embedded MergeTree W7 Typed PK Candidate-Granule Plan

Status: implemented and verified at the W7 diff on parent `a50e640`.
Governed by the W7 section of `EMBEDDED_MERGETREE_FRONTIER.md`.

## Scope, risk, and rollback

Risk: CAUTION. A wrong mark schedule silently omits rows, while a malformed
index could otherwise fail only after some callbacks. This slice is limited
to the Crystal-owned `EmbeddedMergeTreeTable` with its one ascending `UInt64`
key and regular `String` payload. It does not change stored part bytes or
reclaim data. Rollback is the single W7 feature commit; the original
`scan_typed` path remains available.

At W6 HEAD `a50e640`, `PrimaryKeyIndex#candidate_marks` selects conservative
marks for a raw index. `WidePartTable#scan_candidate_marks` exposes complete
marks but accepts only exact `UInt64` selected columns; `scan_typed` supports
`String` but visits every mark and splits batches at 4,096 rows. The offline
catalog's namesake candidate API is an algorithmic reference, not authority
for the embedded active-part set.

## Implementation steps and discriminators

1. Add RED tests using only synthetic table roots: compare caller-filtered
   candidate rows with a full typed scan for inclusive, one-sided, duplicate
   boundary, no-match, multi-part, and post-merge cases. Assert whole-mark
   callback shape and unchanged physical offsets. A stronger skip probe makes
   an unselected String mark unreadable while the selected mark remains valid,
   so eager materialization is distinguishable from actual pruning.
2. Add a typed candidate-mark path in `WidePartTable`, validating the complete
   per-part schedule before callbacks. Reuse the existing typed per-mark
   materialization and byte bounds, but skip unselected marks before reads
   and expose full selected marks. Keep the legacy UInt64-only candidate and
   ordinary typed scan contracts unchanged.
3. Add the embedded facade API. Validate bounds and selected schema, acquire
   the shared lock, resolve active parts, open the typed reader, preflight all
   active indexes and schedules, then call the typed candidate path while
   retaining the lock. An index failure in a later active part must result in
   zero callbacks. Do not silently fall back to a full scan.
4. Add a small example showing String payload access and the mandatory exact
   residual key predicate. Document that candidate batches are not final
   query results and that multiple active parts need not be globally sorted.
5. Run focused and full debug/release specs, W6 fault specs, pinned W3/W5
   physical oracles, formatting, and diff checks. Inspect the final diff for
   user-data access, accidental writer changes, and unsupported claims.

## Definition of Done

For writer-produced, immutable bounded parts, all tested exact residual rows
equal a full typed scan; every selected callback refers to one original mark
with correct offsets; pruned marks are not materialized; all indexes and
requests are checked before the first callback; the original typed and
UInt64-only candidate APIs retain their behavior. The strongest remaining
counterexample is a same-size monotone index whose content no longer matches
the payload; W7 does not detect or correct it. A future hash-authentication
slice would be needed to strengthen that claim.

```sh
CC=/usr/bin/clang CRYSTAL_CACHE_DIR=/private/tmp/crystal-click-w7-cache crystal spec spec/embedded_merge_tree_pk_range_spec.cr
CC=/usr/bin/clang CRYSTAL_CACHE_DIR=/private/tmp/crystal-click-w7-cache crystal spec -D crystal_click_test_failpoints spec/embedded_merge_tree_table_spec.cr spec/embedded_merge_tree_fault_spec.cr
CC=/usr/bin/clang CRYSTAL_CACHE_DIR=/private/tmp/crystal-click-w7-cache crystal spec
CC=/usr/bin/clang CRYSTAL_CACHE_DIR=/private/tmp/crystal-click-w7-cache crystal spec --release
bash scripts/check_wide_part_writer_oracle.sh
bash scripts/check_embedded_merge_oracle.sh
crystal tool format --check src/crystal_click/embedded_merge_tree_table.cr src/crystal_click/wide_part_table.cr spec/embedded_merge_tree_pk_range_spec.cr examples/scan_embedded_merge_tree_pk_range.cr
git diff --check
```

Expected signal: each command exits zero; focused tests include an index
failure in a later active part before any callback and an actual pruned-mark
I/O discriminator. Any change to the index algorithm, writer, lock lifetime,
reader selection, or part format reopens the corresponding evidence.

Observed signal: focused W7 10/10; combined W7, typed-scan, legacy-candidate,
and embedded-table regression 75/75; full debug and release 309/309 each;
W6 fault-flag regression 30/30; both pinned ClickHouse physical oracles
passed. The new example typechecked without code generation, and formatting
and diff checks passed. A read-only adversarial review found no in-scope
candidate omission, offset, or index-order defect. W7-specific callback-vs-GC
process coverage remains a test gap; existing W6 shared-lock regression and
source inspection support the bounded lock claim. No content-hash or speedup
claim is made.
