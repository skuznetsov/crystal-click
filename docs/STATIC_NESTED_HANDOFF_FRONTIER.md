# Recursive static nominal Nested handoff frontier

Status: W248 VERIFIED / root adversary ROBUST within the finite static nominal
Nested target. DEBUG/RELEASE, reciprocal native and raw-control DoD passed.
Baseline: `8e7693f1e6bcea4fbf395cb6a808a50af984944d`, initially clean.
The overall legal-type, MV/projection goal and subsequent performance goal remain open.

## Problem and factual anchors

The shared BinaryBulk declaration, recursive type/physical plans and codecs
already recurse through nominal Nested as an outer Array of a named Tuple,
retaining `BinaryValue.nested`. The W248 RED localized the gap to three
over-broad predicates across two admission-owner boundaries, not missing
serializers. The implementation removes only those predicates and reuses
the existing generic static BinaryBulk owner;
there is no per-product codec or new codec class. The legacy simple root-Nested
carrier remains specialized. Rich Nested with LowCardinality/Variant fields
uses the generic `BinaryValue` route. W202's direct writer and its static
LC/Variant/String corpus were useful controls, not public-table or N-column
qualification.

Direct static Nested and Nested recursively inside otherwise-admitted static
types are distinct from Dynamic- or JSON-containing Nested. The latter remain
contextual refusals. W245's Tuple-with-Nested refusal and W247's generic-table
declaration refusal were over-broad; they did not establish missing leaf serde.

Inspected source: separate shallow snapshots
`f25eb93a0b890a3b87df05eb34e2af1f933b4089` (October 9 serializer snapshot)
and `0ca8150d9b1d0886edb2e3b4ab65eebb768d0357` (October 7 full snapshot).
Neither is asserted to be latest-at-completion or the native runtime's source.
`DataTypeNested.cpp:51-75,185-208,234-249` constructs Array(named Tuple),
preserves a custom nominal name and supports recursive nesting with
`flatten_nested=0`. Flattened sibling aliases are a different storage boundary.

## Intended admission laws

Admit static nominal Nested at the root or recursively under an otherwise
admitted static descriptor, using the existing canonical declaration, recursive
type plan, complete physical plan and codec. Witness types are not a product
allowlist. Preserve nominal declarations; do not lower persisted Nested to a
same-shape Array(Tuple) declaration.

- Keep existing Dynamic/JSON lifecycle refusals and the separate
  AggregateFunction, SimpleAggregateFunction, QBit and Geo admission owners.
  Nested is not authority to bypass any child's nominal or illegal-edge guard.
- Preserve specialized legacy consumer routes and their value carriers.
  Generic table batches and owned offline values use `BinaryValue` only for
  the existing generic fallback. Do not widen `WidePart.open_typed`.
- Bind every logical lane to its complete, collision-free physical roster.
  Retain parent mark grids P and recursively derived child occurrence domains
  Q; do not interchange them or reset LC state on a selected later mark.
- N-column writing retains one operation's shared codec/transport accounting,
  preflight, staged typed readback and exclusive publication. Do not call a
  fixed two-column publisher once for each value column.
- Preserve complete selected-grid checks, exact declaration identity,
  retained-value budgets and projection parent/child validation. Empty table
  selection is not full unselected payload authentication.

Guard-only / rejected: flattened sibling offset sharing, Dynamic/JSON-bearing
Nested through the static adapter, unsupported child owners, illegal Nullable
or LC edges, unqualified physical profiles and target overwrite.
No Compact parts, new codecs, arbitrary keys/partitions, MV transformation or
projection writing, memory/RSS/performance or whole-type closure claim.

## Risk, rollback and discriminator

Risk: CAUTION (persisted-format and public consumer admission).
Rollback: discard only owned uncommitted edits, or one verified atomic local
feature commit. No push, history rewrite or native/source-tree mutation.
Strongest failure: a wrapper changes the occurrence domain or nominal name,
but our writer and reader agree on the same mistake. The discriminator is
stock compatibility in both directions with independent literal rows, not
self-roundtrip, `CHECK=1` alone, or a descriptor parser's acceptance.

## Verification and claim limits

The frozen five-example spec first produced behavioral RED at the static N-column
writer and generic declaration boundary; its direct static-Nested control passed.
The final 28-file DEBUG roster is 160 examples, zero failures/errors/pending.
The combined RELEASE compile was killed by the unchanged 12 GiB process-tree
guard before tests, so it is inconclusive rather than a code failure. The same
roster was split without widening limits: batch 0 (4 files) passed 23 examples;
batch 1 (7 files) passed 43; batch 2 (8 files) passed 44; batch 3 (9 files)
passed 50. The same ordered 28-file roster passes 160 RELEASE examples with
zero failures/errors/pending.

Both helper builds, seven-file Crystal formatting and three Ruby checks pass.
Four fresh native cells (DEBUG/RELEASE x single/sized String profile) have
independent root raw audits: 16 stock SQL calls qualify library-to-stock
ATTACH/CHECK=1, exact six-column order/schema/values and inner Variant types,
plus stock-to-library direct, public-table and offline reads. Per mode, single
profile produced 68 files / 10,914 bytes and sized produced 88 / 14,153; the
combined 156 files / 25,067 bytes match exactly across modes. Nine root raw
semantic controls reject at intended guards, the exact typed 272-entry capture
inventory is restored, and the final independent root baseline audit passed.
The final auditor self-test recheck passes all 10 rejection controls; all 19
source pins were refreshed. Same-lineage model review is correlated, not
independent evidence.

The only persisted metadata addition observed on stock ATTACH is the
source-derived `invalidated_system_columns.txt`, exactly
`_block_offset\n_block_number\n`; every original generated-file identity is
unchanged. This is not a blanket extra-file allowance or generic virtual-system
column compatibility. Native projection interoperability is not tested; the
selected-projection evidence is local spec coverage only. `Variant(Nested)` is
declaration-only, not a native product qualification. The native runtime pin is
ClickHouse `26.10.1.1201`, build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`, executable SHA-256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`;
the October 7/9 source snapshots below are separate source comparisons, not
runtime/source-identity claims.

Root executed the final gates and maintains the exact-command evidence index:
[`static-nested-handoff-w248.json`](../.landmark/evidence/static-nested-handoff-w248.json).
The index is a curated pointer, not proof by itself. Its JSON/pin/roster checks
are the fallback because the skill-referenced graph validator is absent.
The broader legal-type, MV/projection-write, key/partition and performance goals
remain open; no push is authorized.

Stop if a stock schema or physical observation disproves recursive nominal
Nested admission; retain the narrower refusal until the named gap is resolved.
Never weaken declaration, profile, collision, budget, grid, metadata or
publication checks to make the corpus pass. Requalify after relevant admission,
owner, compiler, profile, fixture/helper, runtime or physical-format changes.

## Observations before production changes

Before implementation, root enumerated the shared predicate's consumers with
`rg -n 'StaticBinaryBulkColumnDeclaration|supports_generic_static_binary_bulk_type\?'
src spec`: WidePart selected-column admission, the table BinaryBulk adapter and
batch accessors, OfflineTable schema/admission/projection routes and owned-value
materialization. These already share the same static fallback; legacy typed
Nested keeps its earlier route. The old W247 declaration-refusal and W245
Tuple-with-Nested writer-refusal assertions were updated with this boundary;
the mixed JSON/Nested writer refusal and W174 flattened-context guards remain.

A root-executed guarded stock schema probe passed (actual exit 0) with
`flatten_nested=0`, all three intended Nested declarations plus two String
columns and a UInt64 key in one MergeTree table. `system.columns` returned the
exact canonical declarations for rich root Nested, Tuple/Array-contained
Nested and a Nested field containing Nested plus Array(String).
Runtime: `26.10.1.1201`, build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`, executable SHA-256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
This is schema legality only: no inserted rows, public consumer qualification
or reciprocal storage compatibility is claimed by that probe.

The initial frozen five-example run exited 1 with five errors and zero
failures/pending after 44 guarded seconds. Its direct static Nested control
passed; the N-column refusal reached `StaticWidePartColumnInput`'s old root-plan
guard and the generic declaration refusal reached its flattened-alias guard.
One separate error was the fixture's too-small UInt64 budget success-control,
later corrected without changing production limits. This history confirms the
RED cause; it is superseded by the final DEBUG and split-RELEASE signals above.

Refutations retained: no per-product codec was needed; three predicates at two
admission-owner boundaries were over-broad. A direct rich-Nested round trip does not qualify the
public consumer. The actual first recursive child mark has zero occurrences
before later populated marks. The ATTACH metadata sidecar is one exact
source-derived invalidation artifact, not permission for arbitrary extras.
The feature remains bounded to static nominal Nested; Dynamic/JSON-containing
Nested, `Variant(Nested)`, arbitrary layouts, MV/projection writes and full
type closure remain unqualified.
