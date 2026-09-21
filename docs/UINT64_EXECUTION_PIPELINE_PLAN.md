# UInt64 Execution Pipeline Implementation Plan

Implementation status: **completed + VERIFIED** within the declared scalar
UInt64 aggregate scope. Final adversary verdict: **ROBUST**.

Plan risk: **CAUTION** — this adds the first execution API and freezes aggregate
semantics that future query layers may consume.

Rollback: revert the one atomic pipeline commit. No persistent data or fixture
format changes are admitted.

## Definition of done

Commands:

```text
CRYSTAL_CACHE_DIR=/private/tmp/crystal_click_uint64_pipeline_focused \
  crystal spec spec/uint64_execution_pipeline_spec.cr \
  --link-flags="-fuse-ld=ld" --error-trace

CRYSTAL_CACHE_DIR=/private/tmp/crystal_click_uint64_pipeline_relevant \
  crystal spec spec/uint64_execution_pipeline_spec.cr \
  spec/multipart_uint64_scan_spec.cr spec/streaming_scan_spec.cr \
  spec/delta_zstd_spec.cr --link-flags="-fuse-ld=ld" --error-trace

CRYSTAL_CACHE_DIR=/private/tmp/crystal_click_uint64_pipeline_debug \
  crystal spec --link-flags="-fuse-ld=ld" --error-trace

CRYSTAL_CACHE_DIR=/private/tmp/crystal_click_uint64_pipeline_release \
  crystal spec --release --link-flags="-fuse-ld=ld" --error-trace

crystal tool format --check
git diff --check
```

Expected signals:

- Initial focused compile-time RED for absent `aggregate_uint64`.
- Focused GREEN for exact all/selective/empty/zero/overflow results, predicate
  order, scratch shapes, error atomicity, and structural non-retention.
- Relevant and full debug/release suites retain zero failures.
- Formatting and diff checks pass.

These gates prove the declared scalar aggregate semantics and lifetime route.
They do not prove SQL compatibility beyond named UInt64 sum behavior, nor a
latency, GC, RSS, or throughput advantage.

Observed signals:

- Initial missing-API RED for `aggregate_uint64`.
- Focused pipeline suite: **8/0**.
- Relevant pipeline/multipart/streaming/Delta suite: **37/0**.
- Full debug suite: **137/0**.
- Full release suite: **137/0**.
- Formatter and diff checks: pass.

## Steps

### 1. RED aggregate contract

Path: `spec/uint64_execution_pipeline_spec.cr`.

Built expected aggregates independently from public fixture sequences. The
spec covers shuffled part-directory entries with a discriminating Delta-to-LZ4
boundary, tiny/non-dividing scratch, all-row, selective, all-false, zero-only,
and UInt64-wrap cases. The missing-API failure was recorded before production
edits.

Adversary: expected results must not be produced by the new reducer itself, and
directory order must not accidentally equal logical part order.

### 2. Constant-state reducer

Path: `src/crystal_click/uint64_execution_pipeline.cr`.

Added the owning result struct and implemented one scalar loop over
`WidePartSet#scan_into`. Use explicit checked count increment, explicit modular
sum, first-match extrema initialization, and no retained batch/slice.

Adversary: test `UInt64::MAX`, repeated extrema, no matches, and matching zeroes.
Inspect source for materialization or hidden long-lived state.

### 3. Error and ownership boundary

Path: focused spec plus existing lower-level specs.

The focused suite proves invalid scratch is rejected before predicate
evaluation; predicate errors
propagate unchanged; later decoder corruption produces no returned result.
The existing scan aliasing specs remain authoritative for the borrowed batch
lifetime.

Adversary: a local accumulator mutated before an error is acceptable only
because it is unreachable after the exception; no partial result or shared
state may escape.

### 4. Gates, adversary review, and atomic commit

The DoD commands pass. Inspect exact diff and public requires, then attack sum
semantics, empty extrema, evaluation order, retention, and error paths. Update
the SDD/plan with observed evidence, stage exact owned paths, and commit one
feature.

The strongest likely failure is a friendly-looking widened or checked sum that
cannot be compared to ClickHouse `sum(UInt64)`, followed by accidental retention
of borrowed batch storage. Either makes the declared pipeline **BROKEN**.

Initial adversary verdict: **VULNERABLE**, because identical sequences made the
cross-part order test non-discriminating. The corrected Delta-to-LZ4 boundary
test observes `[4093, 4094, 4095, 0, 1, 2]`. Final adversary verdict:
**ROBUST** within the sealed frontier. The source route establishes
synchronous scalar-only consumption, not a measured allocation or throughput
claim.
