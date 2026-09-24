# Offline `system.part_candidates` Column Values Frontier

Status: implemented for the bounded scope below. This extends
`OFFLINE_CATALOG_FRONTIER.md` only for a synthetic, read-only `system.part_candidates`
projection. It does not connect to a ClickHouse server or claim to reproduce
the complete server `system` database.

## Admitted API and meaning

- `catalog["system"]["part_candidates"][column_name]` selects one named column without
  reading all its values. `.values` returns every selected value in a new,
  owned collection, or raises without returning a partial collection.
- The first columns are `database`, `table`, `name`, `partition_id`, and `rows`.
  They come respectively from validated Atomic metadata, the parsed part
  directory name, and bounded `count.txt`. The rows are physical part
  *candidates*, not server Active parts. There is deliberately no `active`
  column. The projection is ordered by database, table, then part name.
- Keep existing concrete `OfflineDatabase` and `OfflineTable` return types for
  the first two bracket operations; do not force existing callers into new
  union-type handling. The virtual handles must not manufacture UUIDs: asking
  for their UUID raises a typed unsupported error. Existing physical catalog
  enumeration remains physical-only for compatibility.
- `.values` may use a closed union of `String | UInt64` for this first
  runtime-selected projection. It is a full, owned materialization, not a
  borrowed batch. Bound the total projected parts at 100,000 and fail rather
  than silently truncating. Database and table names are traversed in sorted
  order, with each table opened incrementally; discovery checks the remaining
  capacity before reading an over-cap candidate's `count.txt`. A later
  streaming API may avoid this allocation.
- Preserve the existing targeted physical database/table lookups and scans.
  Physical `table[column_name].values` is outside this slice and follows its
  separate reader-backed frontier.

## Exclusions and failure policy

- Reject any overlap among physical candidates for one table, including a
  covering pair, before returning column values. Do not use the scan resolver,
  which selects maximal covering parts. Reject malformed metadata, missing or
  corrupt part counts, unsupported source layouts, and output-cap overflow
  rather than omitting rows. No result is returned if any source fails.
- Never infer `active`, `total_rows` of a live table, transaction state, or
  snapshot consistency. The root must be immutable and quiescent during a
  read. A physical database named `system` must not be silently shadowed.
- This slice does not expose `system.tables`, `system.columns`, or arbitrary
  physical data columns. Physical values are governed separately by
  [`OFFLINE_PHYSICAL_COLUMN_VALUES_FRONTIER.md`](OFFLINE_PHYSICAL_COLUMN_VALUES_FRONTIER.md).

## Verification and rollback

Risk: CAUTION, because a virtual table under `system` can be mistaken for a
server-authoritative view. The cheapest discriminators are a one-part fixture
with known `rows`, a covering-overlap fixture that must fail, and a fixture
with bad later metadata that must not return a partial collection. Also verify
the physical `catalog["lab"]["events"]` scan path remains unchanged and
`system.part_candidates` exposes no `active` column. The DoD is focused catalog specs,
full debug and release specs, format and diff checks, and one runnable example.
Observed at this source state: focused catalog specs passed (35 examples),
including a tiny-cap early-stop regression; full debug and release specs passed
(235 examples each); format and diff checks passed; and the example compiled
and returned `17001` from a one-part fixture.
This does not establish equivalence with live ClickHouse `system.parts` or
snapshot consistency. Rollback is the scoped feature commit; no remote state
is changed.
