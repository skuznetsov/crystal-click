# Static BinaryBulk consumer frontier

Document status: W247 VERIFIED; root adversary ROBUST within the finite target
(2026-10-10).
Baseline: `f0bcff46bd3777eae86be0262f9e98c7445cdb3c`.
The full type, MV/projection and subsequent performance goal remains open.

## Problem and intended boundary

The static BinaryBulk writer, descriptor parser and physical reader already
compose admitted recursive types. Public table batches and owned offline
column values previously routed only four specialized static families through
that reader. This was a consumer handoff gap, not a missing leaf serializer.

W247 adds one bounded canonical declaration owner for the generic static
fallback and reuse the existing physical reader, complete mark schedule,
descriptor identity and retained-value budget. Admission follows the existing
recursive static codec and physical-plan laws; the witness types below are
not an exact-product allowlist. Preserve all specialized legacy routes and
their existing value representations. `WidePart.open_typed` is not widened
merely because table batches can return `BinaryValue`.

The generic fallback must exclude JSON, Dynamic and flattened Nested, which
require separate binding, registry or alias owners. Existing AggregateFunction,
SimpleAggregateFunction, QBit and nominal Geo admission must not be bypassed.
Parsing a descriptor establishes syntax, not storage-profile legality. Reuse
the neutral `BinaryRecursiveDataTypeNameReader`, then validate the descriptor
and existing type/physical plans before admitting a selected column.

Both existing String profiles are in scope. Other layouts, serializer kinds,
unknown aggregate states, arbitrary keys/partitions, projection writing and
MV transformation execution are not admitted by this change. Selected
projection reads may inherit the same static fallback, but still require a
declared child, its own physical schema, and the existing parent/child identity
and schedule checks.

## Safety and falsifiers

Risk: CAUTION (public dispatch, ownership accounting and persistent-format
admission). Rollback: revert only the resulting coherent local feature commit;
preserve unrelated changes. No remote push or history rewrite is authorized.

The strongest likely failure is accepting a declaration through a permissive
parser while bypassing its nominal owner, physical profile, complete-grid
validation or retained descendant budget. Fail closed rather than retrying a
different reader after corruption.

1. Root executes an existing-API RED scan on the frozen baseline before any
   production edit. Library write/direct generic read alone must not substitute
   for this public consumer failure.
2. Exact immutable values, declaration identity, row order and offsets agree
   for full, PK-candidate and late-mark scans; empty candidate selection still
   validates the complete selected physical mark grid. An empty selection is
   not a claim that every unselected payload checksum has been authenticated.
3. Ordinary String and legacy static/Dynamic accessors keep their existing
   contracts. Wrong descriptor, row count, accessor or declaration is rejected.
4. Owned offline `.values` and declared selected projection scans use the same
   admission owner without weakening DDL, alias, child or column identity.
5. Missing/corrupt selected streams, grid disagreement and aggregate retained
   budget exhaustion prevent exposure of the offending mark. Logical retained
   ownership is not claimed to bound transient allocations or RSS.
   LC decoding replays its complete lanes when a mark is requested; the table's
   empty-candidate schedule check does not itself request payload decoding.
6. Native stock witnesses use independently fixed schema and expected rows,
   actual subprocess bytes/exits and complete file closure. Self-roundtrip is
   not stock compatibility. Reciprocal stock-write/library-read coverage is
   claimed only for actually executed cells.

## Implementation plan and DoD

1. Add `scripts/support/static_binary_bulk_table_w247_fixture.cr`,
   `spec/static_binary_bulk_table_w247_spec.cr` and
   `scripts/check_static_binary_bulk_table_w247.cr`; root runs RED serially.
2. Add one `src/crystal_click/static_binary_bulk_column_declaration.cr` owner.
   Connect it through the existing BinaryBulk adapter, batch accessor/install,
   table dispatch, offline materializer/admission and a narrow selected-column
   metadata facade. Keep one class per new owner file; do not duplicate codecs.
3. Root independently inspects the candidate and runs the focused spec plus
   the enumerated affected regression corpus in DEBUG and RELEASE, under the
   unchanged `run_safe.sh` guard (`MIN_FREE_PCT=50`, one Crystal worker,
   12 GiB limit). Expected signal: executed examples pass, no pending cases.
4. Build both native helper modes under the same guard; run isolated stock
   ATTACH/CHECK/exact-row witnesses in both String profiles and inspect raw
   evidence using `scripts/probe_static_binary_bulk_table_w247.rb` and
   `scripts/audit_static_binary_bulk_table_w247.rb`. Root also executes negative
   controls rather than trusting a report's validation labels.
5. Record the scoped Adversary result, actual commands/results, source and
   runtime identities, residual gaps and decay trigger. Commit only exact
   relevant paths after the DoD passes; no whole-suite or all-product claim.

## Evidence anchors before implementation

Stock ClickHouse accepted these declarations together in an actual guarded
CREATE TABLE / system.columns probe (exit 0, 2026-10-10):

- `Variant(Array(UInt16), String)`
- `Array(Variant(LowCardinality(String), UInt64))`
- `Tuple(arr Array(Nullable(Int32)), labels LowCardinality(Nullable(String)), choice Variant(Array(UInt16), String))`

The finite fixture uses five sorted UInt64 keys, three marks (2/2/1 rows),
empty and nonempty arrays, nullable values, LC occurrences and Variant arms,
plus two ordinary String side columns. Both ordinary columns follow the chosen
single-stream or with-size profile; their names do not select different versions.
Legality of this schema is established;
payload and public-reader compatibility still require the gates above.

Root executed the frozen existing-API baseline spec under the declared guard:
`crystal spec spec/static_binary_bulk_table_w247_spec.cr --single-module
--threads 1 --link-flags=-fuse-ld=ld --error-trace --verbose` returned exit 1,
4 examples, 0 failures, 3 errors, 0 pending. Exact direct BinaryBulk values and
mark grids passed; full table and selected-projection dispatch then rejected
the valid column as `unsupported exact typed column`, and offline `.values`
rejected it as `selected table column type is unsupported`. Production edits
were authorized only after this observed RED. Earlier fixture syntax/signature
errors were corrected and are not counted as behavioral evidence.

The candidate regression gate exposed the legacy exact-String path's explicit
version-0 rejection and its size-stream-only byte preflight. A bounded fix
preserves the public String carrier while reusing BinaryBulk decoding for
single-stream payloads; raw-byte accounting excludes length prefixes and does
not promise allocation-free preflight. The sized-profile witness exposed
the static writer's sorted name order versus the legacy String reader's
size-first order. Exact root String rosters now compare by unique name and then
retain the legacy reader order; all other type rosters stay order-strict.
A tail LC checksum falsifier rejected a requested
scan, but not an empty table selection: narrow that assertion to requested
payload reads and test empty selections against complete mark-grid corruption.
Do not change the empty-selection contract merely to make a stronger checksum
assertion pass.

The focused DEBUG and RELEASE gates each pass 17 examples, including a mutated
recursive mark grid, requested LC tail corruption, String0 payload accounting,
descriptor/accessor refusals and retained descendant budgets. The first affected
regression run found a stale W95 expectation: `Tuple(s Array(String))` is now
admitted, so a part declared as `Tuple(s String)` must fail nominal identity with
`CorruptPartError`, not an unsupported-type error. The updated test also keeps
illegal `Tuple(s Nullable(Array(String)))` outside generic admission and rejects
it before materialization. The corrected affected DEBUG and RELEASE gates each
pass 108 examples. Both helper builds pass. The final reciprocal native gates
and root raw-capture attacks below also pass.

The first native coordinator attempt stopped before any stock invocation:
the helper's physical-profile `type` means the whole column declaration, while
the coordinator had compared it to the narrower Variant-site declaration.
The helper's named Tuple stream also uses the escaped field component
`named_recursive%2Echoice.variant_discr`, not a literal dot after the column.
Keep the whole-column descriptor and exact site role/logical name as separate
identities; neither equality implies the other or establishes the BASIC mode.
This is an evidence-reader refutation, not a production-serde refusal.

Two later coordinator diagnostics reached successful reciprocal stock/helper
reads but did not qualify complete captures. Stock emits `statistics.packed`
by default on INSERT; the finite strict file roster now disables only
`materialize_statistics_on_insert` before reciprocal INSERT rather than
ignoring an unknown extra file. Native `hex` output is uppercase, so the raw
mutation control must match that exact representation. Neither correction
changes production serde or weakens its file roster.

The native store inventory also rejected legitimate Atomic catalog aliases.
The bounded harness correction admits only the two captured
`data/default/<table>` links and one `metadata/default` link, validates raw
relative link text and contained direct UUID targets, and binds the metadata
directory's exact two SQL files to the frozen declarations and table UUIDs.
Retain typed link records without traversing the aliases; every other symlink
or special entry still rejects. Actual part trees remain entirely link-free.
The serializer snapshot and separate Atomic/settings source snapshot are not
asserted to be the runtime's source revision.

Root's independent review caught a further harness coordinate mismatch:
the adversary's complete inventory is capture-relative, but the alias roles
are native-store-relative. Normalize only the exact `stores/native/` prefix
for role lookup/validation, retain the full capture-relative inventory name,
and require exactly all three full link records. Final captures use the
corrected frozen source, not any of the diagnostic captures.

## Final finite qualification

The focused three-file corpus passes 17 examples per mode and the nineteen-file
affected corpus passes 108 per mode (125 total, no failures/errors/pending).
Both helpers build, the twelve-file Crystal formatting check and three Ruby
syntax checks pass, and the auditor's twelve literal/parser controls pass.
This is an affected-corpus qualification, not the whole test suite.

Four fresh DEBUG/RELEASE x String single-stream/with-size cells pass. Each
executes four isolated stock SQL processes, two Crystal helper processes and
six stock decompressor processes. Sixteen stock SQL calls qualify generated
ATTACH/CHECK=1/exact schema and rows, stock INSERT/re-emission/CHECK=1, and
library reads of the stock part through direct BinaryBulk, public typed table
and owned OfflineTable values. Three Variant sites are independently bound to
their whole column declaration, physical role, escaped stream name and BASIC
discriminator mode in both generated and stock-written parts. Four externally
pinned raw audits pass with twelve self-tests each.

Root executed six capture mutations on the final DEBUG/single capture:
summary-only row, successful-exit CHECK0, rebound raw stock value, rebound
helper late-window key, whole-column-vs-inner-Variant type, and an un-rebound
generated stream byte. Each rejects at its intended check, acceptance is
restored, and complete typed file/link inventories match before/after. The
stream mutation proves integrity binding, not a deeper semantic corruption
decoder. This does not provide immutable execution provenance or certify a
fully forged capture. Actual bytes of all 108 generated files / 16,293 bytes
per mode agree (single: 50 / 7,522; sized: 58 / 8,771).

Native projection interoperability is not tested: the projection witness is
a local declared synthetic child only. The offline helper uses an explicitly
declared OfflineTable/candidate, not discovery of the stock server root.
Helper physical mark windows are not native SQL pruning evidence. No new
JSON/Dynamic/Nested owner, Compact/Sparse layout, aggregate-state family,
general key/partition metadata, MV/projection writer or performance guarantee
is admitted. The generic static admission follows existing recursive plan
laws; passing these witnesses is not proof of every accepted product.

Commands, hashes, capture locations, refuted routes and refresh policy are in
[the W247 evidence index](../.landmark/evidence/static-binary-bulk-consumer-w247.json).

Comparison source: shallow serializer checkout
`f25eb93a0b890a3b87df05eb34e2af1f933b4089` (not a runtime-build identity).
Separate shallow Atomic/settings source:
`0ca8150d9b1d0886edb2e3b4ab65eebb768d0357`.
Stock runtime: 26.10.1.1201, build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`, SHA-256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
Evidence becomes stale after relevant admission/reader/profile changes or a
runtime change; refresh the affected specs and finite native cells then.
