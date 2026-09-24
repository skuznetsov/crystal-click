# Embedded MergeTree W2 Implementation Plan

Status: W2 implemented and verified within the bounded SDD scope. Governed by
`EMBEDDED_MERGETREE_FRONTIER.md`.

## Scope and risk

Add a `UInt64` primary-key plus `Nullable(UInt64)` payload writer, not a general schema
builder. Reuse W1's staging, exclusive publication, and primary-index path.
Use only deterministic synthetic values in temporary directories. Do not
touch existing parts, private data, live ClickHouse roots, or remote history.

Risk: CAUTION. Nullable has two physical substreams and a versioned metadata
contract; a locally readable part could be rejected by ClickHouse or silently
shift values at a mark boundary. Rollback is one coherent W2 feature commit.

String was considered first, then deferred: the pinned ClickHouse source can
produce a valid zero-byte regular String stream for all-empty values, which
the current Crystal reader rejects. Rejecting that legitimate input to make a
String writer pass would be an incomplete capability. The producer evidence is
`SerializationString.cpp:711-744` (`write(..., 0)`) together with
`CompressedWriteBuffer.cpp:22-26` (no frame for zero buffered bytes), read
from the pinned `v26.7.1.1315-stable` tag. The future String slice first needs
a zero-byte stream reader probe and fail-closed compatibility rule.

## Sequence and discriminating signals

1. Inspect the pinned ClickHouse `v26.7.1.1315-stable` source and a public
   Nullable fixture for null-map/value encoding, stream naming, mark layout, and
   serialization metadata. Add a RED spec for a missing
   `write_uint64_nullable_uint64_pair` API. Its expected failure is only the missing
   entry point.
2. Implement the bounded two-substream writer in
   `src/crystal_click/wide_part_writer.cr`. Validate all sizes before staging,
   then validate checksums, mark row counts, and exact Nullable readback
   before publication. Preserve the W1 entry point and its output.
3. Extend `scripts/check_wide_part_writer_oracle.sh` with an isolated
   ClickHouse-local Nullable table, exact null-vs-zero comparison, PK-range
   query, clean `CHECK TABLE`, and a mutated Nullable-stream negative check.
4. Review the complete diff for input-limit, mark-boundary, stale-stage,
   metadata, and privacy failures. Update the SDD evidence record only after
   observed checks pass.

## Definition of Done

Run focused writer specs, the independent pinned ClickHouse oracle, full debug
and release Crystal suites, formatting, shell syntax, and `git diff --check`
at the final source state. Expected signals: all pass; ClickHouse returns
exact nullable values and filtered rows, passes clean `CHECK TABLE`, then
reports corruption after a byte in the Nullable stream's compressed-frame
checksum is changed. This does not test a decoded null flag with recomputed
checksums. No failed operation publishes a part.
An adversarial review must find no blocker within this narrow compatibility
scope before committing exact W2 paths. No push is part of W2.
