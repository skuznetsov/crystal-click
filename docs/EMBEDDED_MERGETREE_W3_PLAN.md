# Embedded MergeTree W3 Implementation Plan

Status: active. Governed by `EMBEDDED_MERGETREE_FRONTIER.md`.

## Scope, risk, and rollback

W3 has two ordered changes: (a) read valid zero-byte regular String data
streams without weakening other stream validation; (b) write a bounded
`UInt64` primary key plus `String` payload Wide part. Each is a coherent
commit after its own checks. No private fixture, existing part mutation, live
ClickHouse data-root write, table-level insert, merge, or push is in scope.

Risk: CAUTION. A synthetic empty read could mask corrupt marks, and a writer
could produce a part that self-reads but stock ClickHouse rejects. Rollback is
the corresponding W3 commit. The compatibility authority is official pinned
ClickHouse local `26.7.1.1315`, not Crystal self-readback alone.

## Sequence and falsifiers

1. Generate a tiny synthetic stock Wide part with sparse serialization off,
   five all-empty String rows, marks of `[2, 2, 1]`, and a zero-byte regular
   data stream. Prove the current reader rejects it; retain a public fixture
   or a deterministic fixture recipe. Independently reject a size-stream or
   mark mutation implying bytes in the empty stream. Implement the narrow
   reader fix and run focused/full specs before the first commit.
2. Add a RED spec for the missing bounded String writer API. Test all-empty,
   mixed empty/nonempty, binary/NUL, multibyte UTF-8, multiple marks, a short
   final mark, and failed publication. Preserve W1/W2 output paths and
   preflight limits. Implement the smallest new serialization path.
3. Attach at least the mixed and all-empty synthetic writer outputs to an
   isolated pinned ClickHouse-local table. Compare exact bytes and key-range
   reads, require clean `CHECK TABLE`, then alter one selected physical stream
   without changing file size and require `CHECK TABLE` failure.
4. Review mark/frame boundaries, zero-byte guard, unchecked size arithmetic,
   staging cleanup, and privacy. Record only observed signals in the SDD and
   commit the second feature with exact paths; do not push.

## Definition of Done

Focused reader and writer specs, full debug and release Crystal suites,
formatting, shell syntax, and `git diff --check` pass at the committed source
states. The stock-reader fixture has expected rows and a zero-byte regular
stream, a contradictory fixture fails closed, and both writer shapes pass
independent attach/query/`CHECK TABLE` with a corruption negative control.
This establishes only normal String Wide-part compatibility on this host and
pinned version, not arbitrary String variants or performance.

The concrete local gates are:

```sh
bash scripts/generate_empty_string_fixture.sh --check
CC=/usr/bin/clang CRYSTAL_CACHE_DIR=/private/tmp/crystal-click-w3-cache crystal spec spec/string_nullable_scan_spec.cr
CC=/usr/bin/clang CRYSTAL_CACHE_DIR=/private/tmp/crystal-click-w3-cache crystal spec spec/wide_part_writer_spec.cr
bash scripts/check_wide_part_writer_oracle.sh
CC=/usr/bin/clang CRYSTAL_CACHE_DIR=/private/tmp/crystal-click-w3-cache crystal spec
CC=/usr/bin/clang CRYSTAL_CACHE_DIR=/private/tmp/crystal-click-w3-cache crystal spec --release
crystal tool format --check src/crystal_click/wide_part.cr src/crystal_click/wide_part_writer.cr spec/string_nullable_scan_spec.cr spec/wide_part_writer_spec.cr
bash -n scripts/generate_empty_string_fixture.sh scripts/check_wide_part_writer_oracle.sh
git diff --check
```
