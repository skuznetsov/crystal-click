# Bounded Physical Column Values Frontier

Status: admitted for the bounded physical-column surface below. This extends
the named-column selector introduced by
`OFFLINE_PART_CANDIDATE_VALUES_FRONTIER.md` to physical `MergeTree` tables. It
is a convenience materialization over the existing typed scanner, not a query
executor or a substitute for streaming.

## Admitted API and meaning

- `catalog[database][table][column].values` returns a new, owned array of all
  values for one stored column, or raises without returning a partial result.
  Selection itself reads metadata only; values are read on `.values`.
- `values(max_rows: ..., max_string_bytes: ...)` may tighten, but never raise,
  the hard 100,000-row and 64 MiB returned-String ceilings. The same budgets
  apply to the synthetic `system.part_candidates` projection.
- Support the exact numeric primitives `UInt8/16/32/64`, `Int8/16/32/64`,
  `Float32/64`, `String`, their supported `Nullable(...)` forms, and scalar
  typed JSON paths that the existing `scan_typed` reader already supports.
  The runtime-selected result has one closed `OfflineColumnValue` union,
  including `Nil` for nulls. The existing scanner decodes Strings into owned
  `String` objects; the returned array does not retain its borrowed batch slices.
  Widening the prior synthetic `Array(String | UInt64)` return type is a
  compile-time API break for explicitly annotated callers, admitted for the
  pre-release `0.1.0` library.
- Reuse `resolved_scan_parts` and `scan_typed`. The returned order is resolved
  candidate order, then mark/row order within each part; it is not SQL
  `ORDER BY` or ClickHouse server Active state. A quiescent immutable root is
  required throughout the read.
- Preflight at most 100,000 candidate rows and cap cumulative returned String
  payload at 64 MiB. This is not an aggregate I/O or CPU budget: a
  `Nullable(String)` scan still consumes nested bytes beneath NULL rows.
  Also check observed row count against preflight count. On a limit error,
  keep `scan_typed` as the streaming escape hatch.

## Rejected and guarded behavior

- Reject computed `ALIAS` columns, unsupported on-disk types, whole JSON
  objects, ambiguous literal dotted names versus JSON typed paths, non-exact
  MergeTree engines, incompatible DDL/part types, unsupported delete or
  transaction sidecars, and malformed later marks. Do not return a prefix of
  results after any failure.
- Do not claim snapshot isolation, predicate pushdown, server `system.*`
  equivalence, or unlimited materialization. Do not change the existing
  borrowed-batch scanner's behavior.

## Verification and rollback

Risk: CAUTION, because `.values` allocates by row count and could accidentally
retain borrowed strings or return partial data. Start with a red spec for a
physical UInt64 column; then exercise numeric, String, Nullable, and JSON
typed-path values, ordering across parts/marks, alias and dotted-name guards,
row/string limits, and later-read failure. DoD: focused specs, full debug and
release specs, format/diff checks, and a compiled/smoked example. Rollback is
the scoped feature commit; no external state is changed.

Observed on the implementation worktree with Crystal 1.21: 42 focused catalog
specs and 242 full specs in each debug and release mode passed; format and diff
checks passed; the example read 17,001 values from the public fixture. A
spec-only `OfflineTable` subclass used to shrink the limits caused a Crystal
code-generation error only in the combined suite; the tests now exercise
smaller per-call budgets through the public API. These checks do not establish
snapshot isolation, aggregate I/O limits, or ClickHouse server Active state.
