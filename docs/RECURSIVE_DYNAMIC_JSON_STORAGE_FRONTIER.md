# Recursive JSON and Dynamic storage composition — W204

Document status: VERIFIED within the finite W204 library/native corpus;
behavioral RED, independent native gates and adversary checks executed.
Baseline: `5cb6e0cd9f4c0b6974cdf1975dcd48cb466335a6`.

## Boundary and purpose

Compose already-supported JSON Object sites and JSON-free Dynamic-bearing bulk
subtrees beneath the existing recursive Array/Tuple schema. Reuse their value
codecs; do not introduce a serializer for each Cartesian type combination.
The current parser admits declared Dynamic, but the physical planner hands it
to a static BinaryBulk owner without its persisted structure state.

The leaf serde is reused recursively. The composition contract must additionally
carry the escaped site prefix, inherited Array naming level, descriptor depth,
parent/child occurrence schedules and state lifetime. Array changes the child
domain; Variant distributes occurrences across arms; Dynamic/Object reveal
their persisted type/path roster; LowCardinality carries dictionary state.
Missing qualification for a product does not imply a missing leaf serializer.

The full project goal remains all compatible types plus MV/projections, followed
by memory/performance work and a measured stock-relative slowdown of at most
10 percent. This slice does not close that goal or assert performance parity.

## Design-sealed surface

- Existing root Array/Tuple recursive columns with at least one JSON leaf can
  also contain already-admitted JSON-free Dynamic-bearing bulk leaves.
- A Dynamic site retains one prepared `BinaryDynamicBulkPlan` and its physical
  plan, with explicit write plans keyed by stable recursive schema-site paths.
- Reading discovers structures parent-first from persisted lanes; writing uses
  the supplied actual rosters. Both reuse the existing generic bulk codecs.
- Existing complete-part recursive writer, column reader, and typed table
  recursive-value consumer are the public path, not a new one-off facade.
- Existing Object BASIC/COMPACT profiles remain unchanged. Dynamic data keeps
  W203 admission; this slice does not silently widen static Variant modes.

Rejected/guard-only: JSON as a Dynamic actual or Variant arm, JSON beneath new
structural wrapper kinds, flattened Dynamic, unsupported structure versions,
Compact parts, unqualified dictionary schedules, general table publication,
server MV execution, projection optimization, and performance claims.

## Ownership laws

1. Physical marks use the top-level parent P row grid; Dynamic value decoding
   uses the inherited occurrence Q grid, including all-zero intervals. Never
   infer one from the other's data bytes.
2. Scoped physical prefixes are already escaped and inherit Array depth. Do
   not re-escape a site prefix or restart `.sizeN` numbering.
3. Site discovery is bounded and parent-first. Structures, data roles,
   statistics offsets, complete marks, metadata roster, and selected checksum
   names are bound before returning values or invoking a table callback.
4. Object, static bulk, and Dynamic work share operation-local codec and
   transport budgets. A child must not reset limits or double-charge work.
5. LowCardinality-bearing Dynamic sites replay the complete state before a
   middle/end-zero selection. Structure metadata marks are not data offsets.
6. Writer validation/encoding happens before publication; rejected inputs must
   leave no destination or stage. Existing APIs preserve defaults and positional
   arguments; new Dynamic plan mappings are appended named options.
7. Descriptor depth includes every outer Tuple and Array edge plus the resolved
   Dynamic actual tree. Array naming depth is a different coordinate. An unused
   actual roster or an all-zero occurrence grid does not bypass this bound.
8. Reader discovery reuses its already-bound physical sites in the final
   manifest. It must not reset per-site name/codec budgets or rebuild and
   double-charge the same binding. Reused bindings retain exact schema key,
   type, profile, escaped prefix, Array level, and descriptor depth identities.

## Execution, risk, and rollback

Risk: CAUTION (serialization, shared planner and public read/write composition).
Rollback: exact W204 paths can be restored from the clean baseline; no remote
history changes, push, dependency changes, or runtime/source replacement.

1. Capture a behavioral RED for the existing planner/public path on a legal
   mixed JSON/Dynamic schema, before production changes.
2. Add a reusable Dynamic physical-site owner and bind it into the shared
   recursive manifest. Preserve standalone W203 behavior and metadata guards.
3. Wire recursive writer/reader to that owner, with P/Q grids and shared budgets.
4. Add finite mixed Tuple and ragged Array/Tuple cases, stateful actuals,
   full/middle/empty selections, and publication/roster/budget negatives.
5. Root runs compiler and native workloads serially under the existing guarded
   execution policy. Delegated source work is candidate evidence only.

## DoD and falsifiers

- Guarded focused `crystal spec` for W204 plus affected W186-W189/W203 owners:
  green with no failures/errors/pending; repeat in RELEASE before qualification.
- Guarded native helper built from the exact tested source, then fresh pinned
  stock-authored parts -> library reader/table and library-authored parts ->
  stock ATTACH/CHECK, with independently authored literals and exact declarations.
- Tuple and ragged Array/Tuple profiles include zero-occurrence marks, unequal
  P/Q counts, later windows, null/shared Dynamic values, and inherited names.
- Reject missing/extra/mismatched prepared site plans, malformed structures,
  mismatched marks/rosters, wrong budgets, and invalid selections; no callback
  or publication may occur on failed preflight.
- Test an entirely-zero child-site occurrence grid, not just empty windows or
  a JSON-free bulk Array value whose outer site still has one value per parent.
  W204 native carriers have empty marks but not a whole-part all-zero Q site;
  that separate stock interoperability obligation remains open even when the
  library-only all-zero-Q tests pass.
- Reject resolved actual descriptors exceeding inherited depth, including
  unused actual arms and zero-window reads.
- Strongest likely failure: paired library reader/writer agree on incorrect
  occurrence coordinates. Independent stock literal observations and a seeded
  P/Q or replay defect must distinguish it; model agreement is not proof.

Baseline RED (root-executed, guarded, 2026-10-07):
`crystal spec spec/recursive_dynamic_json_w204_red_spec.cr --single-module
--threads 1 --link-flags=-fuse-ld=ld --error-trace` exited 1, with one example
and one error: `Dynamic is outside the admitted physical bulk storage profile`
from `BinaryBulkPhysicalPlan.from_escaped_prefix`, reached through
`RecursiveStorageColumnPlan.build_sites`. The legal mixed schema parsed first.
The successor positive test must supply its explicit prepared Dynamic write
plan; missing plans remain a rejection, not an inferred roster.

## Executed qualification (2026-10-07)

- Final focused gate: 18 examples. The identical 180-file affected roster passes
  1121 DEBUG and 1121 RELEASE examples, with no failures, errors or pending tests.
- Fresh native captures in both modes exercise root Tuple(JSON, Dynamic),
  Array(Tuple(JSON, Dynamic)), ragged Array(Array(Tuple(JSON, Dynamic))), and an
  Array/Tuple carrier whose JSON-free sibling Tuple contains LowCardinality,
  Dynamic, String and another Array(Dynamic). Both String profiles are tested.
- Per mode, eight library parts are attached directly by the pinned stock
  runtime; 24 CHECKs supplement 384 independent selected value/type/state
  observations. Exact payload stream counts are 13/16, 14/17, 15/18 and 22/27.
  Source and published library trees remain unchanged across native reads.
- Root audits raw process-record hashes and reruns literal reader/native
  assertions. Thirteen targeted oracle mutations are rejected per mode.
  DEBUG/RELEASE normalized helper reports and all 364 generated part files
  are identical.
- A deliberately seeded production P-for-Q decode schedule breaks both positive
  fixtures. It was restored before the final gates. A separate read-budget RED
  exposes an overly permissive public site-read seam; mismatched transport
  limits or write-direction budgets now reject before charges or source reads.
- Dynamic physical-site ownership and bounded descriptor-preflight receipt are
  separate classes/files. The standalone column reader delegates to the site
  owner. This is not repository-wide modularization.

Scoped adversary verdict: ROBUST for these executed fixtures and guards, not
all legal recursive products or all persisted layouts. All-zero-Q whole-part
stock interoperability, JSON-as-Dynamic-actual, additional structural wrappers,
selected root Tuple metadata forms not emitted by these fixtures and broader
dictionary schedules remain open. The read-discovery plan seam does not independently
bind source identity; the actual column reader constructs its owners internally
from one source. Re-audit if that construction path or seam visibility widens.

Commands, source identities, runtime/source pins, raw-evidence locations and
refresh/decay rules are indexed in
`.landmark/evidence/recursive-dynamic-json-storage-w204.json`. The source archive
is the clean shallow October 5 snapshot, not a latest-October-7 claim or the
native runtime's build source. The overall project goal remains active.
