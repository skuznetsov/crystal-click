# Caller-run materialized-view transform frontier

Document status: admitted W257; VERIFIED / root adversary ROBUST within the
bounded caller-run transform target (2026-10-10).
Current frontier: one catalog-bound source part, one complete Crystal callback
scan, and exact target-DDL-bound detached Wide publication through existing owners.
Baseline: `84ba802c503f7d9be8fc75e9a7d07cbf8ecfa99c` (W256).
Bounded context: offline Atomic catalog, one resolved source part, a Crystal
callback, and exclusive detached publication into the resolved MV target.

## Purpose and claim boundary

The existing W88 materializer admits only an exact two-column identity SELECT.
The new operation reads a catalog-bound source part and lets caller code filter,
compute, and rekey rows. It binds the returned writer owners to the persisted
target schema before publication. It does not interpret the MV SELECT, prove
callback provenance, fire an MV, attach a part, or establish target freshness.
An identity read/write or precomputed-row publication alone is not its DoD.

## Admitted surface

- `OfflineCatalog#transform_materialized_view_part(database, view_name,
  source_part_name, source_columns, output_part_name, ...)` passes an
  `OfflinePartTransformInput` to one callback, expects a
  `WidePartTransformOutput`, and returns the canonical detached part path.
- Source inventory must be complete with exactly one direct source reference.
  Unqualified references use the declaring database. Target resolution reuses
  the existing UUID-aware named/inner target resolver.
- The selected source must belong to the globally resolved candidate set. Its
  selected columns use existing typed DDL/part preflight, not a raw-path bypass.
  A shared typed-selection admission owner must distinguish exact Object roots,
  canonical JSON-free DynamicBulk declarations, recursive Tuple/Array roots
  containing JSON, existing typed/static routes, and virtual JSON typed paths.
  It reuses the existing bounded declaration parsers and physical readers;
  it does not admit arbitrary type/layout products. Both typed-DDL checks use
  the same selection-aware owner, while virtual paths retain their existing
  leaf-type gate and literal-dotted-name ambiguity refusal.
  The new candidate-scoped transform seam rejects selected ALIAS columns (or
  an ALIAS parent of a selected virtual path) before the outer callback. This
  does not change alias policy for unrelated existing scan APIs.
- Target: persisted ordinary MergeTree, no column modifiers, no projections,
  unpartitioned, first column is its single ascending UInt64 key. Target SETTINGS
  admit only matching `index_granularity` and the paired Wide thresholds
  `min_rows_for_wide_part=0,min_bytes_for_wide_part=0`, without duplicates.
  Both Wide thresholds may be omitted; if one is explicit, both must be zero.
  Omitted granularity means 8192. The target's default insert-format policy does
  not prohibit attaching a compatible Wide part. Unknown layout clauses/settings
  are rejected.
  Explicit writer serialization profiles are validated through existing owners
  and the native witness; target SETTINGS are not a generic compatibility proxy.
- The callback may scan once, to completion. Reentry, a second scan, no scan,
  early exit, and use after the outer callback returns are rejected. Escaped
  handles are invalidated on both success and failure.
- Normal scans carry exact batch `row_count`; the handle counts delivered rows
  and requires normal full-scan return, not just delivery of the last batch.
  Old manually assembled batch constructors remain source-compatible with an
  optional unknown count (`nil`), never a fabricated zero.
- Output uses the existing `WidePartColumn.binary_bulk`, `.dynamic_bulk`,
  `.object`, and `.recursive` owners. Names, ordered roster, and exact canonical
  declarations must match the target. There is no new universal serde layer or
  alias normalization. Equivalent noncanonical spellings can be rejected.
- One writer operation prepares each owner once under its existing shared
  budgets. `WidePartSchemaBinding` validates prepared names/declarations before
  metadata, encoding, staging, or publication. Existing unbound callers retain
  their behavior through an optional final binding argument.
- Destination is derived only from the resolved target's plain existing
  `detached` directory and a canonical unpartitioned `all_*` basename. Existing
  target candidate overlap and occupied destinations are rejected.
- Before publication, re-resolve metadata/UUIDs and the source candidate, then
  recheck destination/target identity. This detects changes to the compared DDL,
  UUID, path, candidate identity/count, and layout fields. It does not certify
  source-stream immutability or detect every same-identity payload rewrite;
  it is not a filesystem transaction against concurrent adversaries.

## Rejected and non-guaranteed surface

SQL expressions, joins, functions, automatic refresh/backfill, server triggers,
exact dependency graphs, source/target aliases, target projections, computed or
modified target columns, arbitrary destinations, partitioned targets, general
sorting keys, empty output parts, and concurrent server/catalog mutation remain
rejected or outside this slice. Caller output must already be nondecreasing by
the target key. Block-number identity is not a key-value range.

Late source corruption can occur after earlier callback batches. No part is
published unless the whole scan and callback succeed; arbitrary external side
effects in caller code cannot be rolled back. Writer budgets do not bound caller
accumulation before owner preparation. Exclusive ownership of the catalog and
destination hierarchy is required. Process death after atomic publication can
leave a complete detached artifact requiring reconciliation.

## Execution order

1. Validate arguments, view inventory, resolved source/target identities, target
   layout, and destination; open the selected typed source reader.
2. Invoke the callback with a one-shot handle; require full scan completion;
   invalidate the handle in `ensure`.
3. Refresh catalog identities and layout/destination checks.
4. Prepare output owners once, apply target schema binding, then use the existing
   staged readback and exclusive atomic publisher.

## Falsifiers and DoD

- Behavioral RED on the baseline: healthy W88 identity control, then rejection
  of a valid non-identity filtered view. This does not authorize widening W88 SQL.
- Positive callback fixture filters several source rows, changes keys and
  payloads, retains ragged/empty recursive children, and constructs all four
  owner families. An identity copy must fail its independent value oracle.
- Invalid target UUID, alias, layout, projection/modifier, or source physical
  schema: zero outer callback calls and no destination.
- Callback exception (including after a batch), missing/incomplete scan,
  reentry, second scan, output roster mismatch, and callback
  metadata mutation: refusal with no published destination/stage residue.
- A retained handle rejects post-callback use even after a successful
  publication; retaining a reference is not itself observable misuse and does
  not retroactively roll back a completed detached publication.
- DEBUG and RELEASE focused specs: W257 plus W88, W228, W245, W256 guards.
- Bounded pinned stock ClickHouse witness: source rows inserted before the MV
  exists, empty target, library callback transforms, then native ATTACH/CHECK and
  exact independently constructed RowBinary output comparison. Native thread
  count 1, 512 MiB memory, 10 s timeout plus 2 s kill grace.

Root executes heavy commands serially through `run_safe.sh` with Crystal
`--single-module --threads 1 --link-flags=-fuse-ld=ld --error-trace`, 600 s timeout,
12 GiB ceiling, and 50% free-memory guard. Release adds `--release`.
Expected signals are observed behavioral RED followed by green bounded specs,
native checksum validation, exact transformed rows, and negative publication
controls. Source state/tool pins must be recorded with the evidence.
Recorded gate-packaging history: the combined 29-file RELEASE attempt was terminated by the process-tree memory
guard (12 GiB) before any test result. It is operationally inconclusive, not a
behavioral failure or success. The first fallback plan split the identical
ordered roster into two nonoverlapping serial cohorts (first 14 files, then
the remaining 15), with the same compiler flags and unchanged guard. This
changed only gate packaging, not admission, production code, coverage roster,
or the resource ceiling.
The first 14-file cohort also hit the same memory guard before tests
(`12585056KB > 12288MB` after approximately 269 seconds). This is a second
operationally inconclusive compilation attempt, not a RELEASE test result.
The following packaging probe isolated the two W257 specs, then partitioned
the remaining ordered 27 files into nonoverlapping groups of at most five.
The 29-file coverage roster, source seal, flags and resource guards stayed fixed.

## Implementation plan and ownership

Risk: CAUTION (public callback API and persistent detached publication).
Rollback: clean baseline plus one atomic local feature commit; no remote push.
Strongest failure: a valid part published against the wrong catalog target or
after an incomplete source scan. Guards above are load-bearing.

1. Offline owner: `offline_part_transform_input.cr`,
   `offline_materialized_view_part_transform.cr`, candidate-scoped seam in
   `offline_table.cr`, small facade/layout seam in `offline_catalog.cr`,
   exact scan counts in `wide_part_table.cr` and
   `wide_part_table/wide_part_table_batch.cr`,
   shared typed-selection admission in its own class/file,
   `spec/offline_materialized_view_transform_w257_spec.cr`.
2. Writer owner: `wide_part_transform_output.cr`,
   `wide_part_writer/wide_part_schema_binding.cr`, optional final binding in
   `wide_part_writer.cr` and `wide_part_writer/wide_part_operation.cr`,
   `spec/wide_part_schema_binding_w257_spec.cr`.
3. Native witness owner: `scripts/support/materialized_view_transform_w257_fixture.cr`,
   `scripts/check_materialized_view_transform_w257.cr`,
   `scripts/verify_materialized_view_transform_w257.rb`.
4. Root: central requires, serialized gates, independent hostile review,
   evidence/ledger update and exact-path atomic commit after DoD.

Consumer inventory: bounded `rg -n 'write_uint64_columns|open_typed_reader|materialize_view_part'
src spec scripts` plus Luna's W257 source inventories. Existing N-column callers
in W245-W256 remain source compatible; the new schema binding is optional and
does not weaken their physical/type guards.
Batch count inventory: `rg -n 'WidePartTableBatch.new' src spec scripts` found
three normal scan sites and three manual test constructors (W76, fixed numeric,
nullable String). All normal sites receive exact counts; the manual constructors
retain their former argument contracts. These three specs join the guard suite.
Typed-selection inventory: `resolve_typed_ddl_selection` also serves the
materialized-value, public selection-identity, QBit, and projected scan paths.
Their existing `allow_unsupported_exact` and specialized downstream guards
remain intact; the new admission owner is not authority to bypass them.

## Implementation seal

Behavioral baseline observed through the guarded root probe: identity control
returned `{1, "alpha"}, {2, ""}, {3, "omega"}`; the non-identity view was rejected
by the exact W88 identity-projection guard without publication (exit 1).
Scratch probe: `/private/tmp/crystal-click-w257.nd5Urx/probe_w257.cr`.
The sandbox could not supply process-group inspection; guarded execution required
escalation. Initial require/Atomic-fixture failures were inconclusive, not RED.
The initial design seal admitted no capability. The final observed qualification
below supersedes that intermediate state, not the rejected surface above.
The initial 121-example DEBUG guard suite passed, but the native fixture then
exposed a typed-DDL handoff gap: offline selection rejected parameterized
Dynamic and a mixed Array/Tuple JSON+Dynamic column. A read-only root control on
the same physical part opened both through `WidePartTable.open_selected_typed`.
The next sealed move is a regression for that exact handoff and selected-source
ALIAS refusal, followed by the shared admission owner above. The failed native
cell is not a compatibility certificate; no fixture type may be dropped to
manufacture a green witness.
The guarded handoff regression then produced a behavioral RED: the positive
Dynamic/recursive-JSON selection failed in the offline DDL gate before callback,
and the DDL/part mismatch control hit that same gate before the intended exact
physical-identity check. Fixture errors about recursive shared profiles were
corrected to the existing single-stream contract and are not behavioral RED.
`OfflineTypedSelectionAdmission` now delegates to the existing owner grammars.
At that intermediate handoff repair, final qualification was still pending.
The virtual-path ALIAS control uses the
old admitted `JSON(t UInt8)` grammar; parameterized Object roots do not imply
wider virtual-path parsing. The native fixture retains all five column types.
Native ATTACH is a separate identity context: the fresh target assigns active
`all_1_1_0` to generated detached `all_9_9_0`. The raw CHECK capture must contain
exactly one completed CHECK per table; duplicate completed blocks are rejected,
including a raw zero followed by a forged green block. A root behavioral RED
demonstrated that the former parser overwrote the zero; replay now rejects it.
The next native attempt passed ATTACH/CHECK but failed whole-directory equality.
The measured delta is exactly one server-created
`invalidated_system_columns.txt` containing `_block_offset\n_block_number\n`
(28 bytes, SHA256 `7409424ab45090c1261e622f7423393905102e7e8cba36a6db88eb513ce1e06c`).
All generated files were unchanged. The sealed harness repair admits only this
exact absent-before/present-after addition, not arbitrary exclusions, file
changes, or payload normalization. Native RowBinary was not qualified by that
attempt; these failed cells are harness diagnostics, not compatibility evidence.
The fresh final-source DEBUG native cell
`/private/tmp/crystal-click-w257-native-debug-green.2AV10d` subsequently passed
ATTACH, CHECK and exact source/target RowBinary comparison (outer exit 0).
The root independently compared actual captures with a literal little-endian
encoder and rejected 25 finite value, truncation, process-exit, duplicate-CHECK
and ATTACH-snapshot controls; the 24 capture files were unchanged. This qualifies
only that pinned five-column DEBUG witness. At that intermediate point RELEASE,
final one-shot protocol probes and generated-byte equivalence were still pending.
The final qualification below closes those gates. Logs are under
`/private/tmp/crystal-click-w257.nd5Urx/` (`native-debug-green.log` and
`native-root-audit-debug.log`).

## Observed qualification

- The sealed ordered 29-file guard roster passed 159 examples in DEBUG and 159
  in RELEASE, with zero failures/errors/pending. RELEASE's final serial cohorts
  contain `[2,5,5,5,5,5,2]` files and `[14,48,25,37,18,15,2]` examples. Their
  ordered, nonoverlapping union is the same DEBUG roster. The two earlier
  memory-guard kills remain operationally inconclusive, not test results.
- Both final helpers built. Fresh native cells are
  `/private/tmp/crystal-click-w257-native-debug-green.2AV10d` and
  `/private/tmp/crystal-click-w257-native-release-green.CxCowI`. Each observed
  actual ATTACH, source/target CHECK=1, exact schema and exact RowBinary values.
  All four native process records per cell report exit 0, no signal and no
  timeout. The runtime is ClickHouse 26.10.1.1201/build
  `d9bcb5ab007f0f6299f7f973f2642245bab3d028`, distinct from the clean shallow
  comparison source `ed30948f095ecb70679986d7d60e27ad770ae27a`.
- The finite native fixture has UInt64 key/score, parameterized Dynamic, a
  typed-only Object document, and ragged Array(Tuple(JSON, Dynamic)). Six source
  rows become four rows, with filtering and changed keys, scalar values,
  Dynamic values, document fields and recursive children. NULL, empty children,
  NUL and UTF-8 are retained. Source marks are `[2,2,2]+EOF`; output marks are
  `[2,2]+EOF`. The admitted witness uses ordinary with-size String streams,
  single-stream shared profile and BASIC discriminators; it is not an inferred
  Object shared-data or every-version/profile certificate.
- Root's final independent protocol probe passed six controls in each mode:
  no scan, break after the only batch despite receiving all rows, swallowed
  second scan, swallowed reentry, swallowed batch exception, and healthy
  transformed rows followed by escaped-handle refusal without deleting the
  successful publication. Aborted controls leave no detached/stage residue.
- Root's literal little-endian encoder agrees with actual source (257 bytes)
  and transformed target (184 bytes) captures. Twenty-five finite value,
  truncation, ATTACH-snapshot, raw CHECK, duplicate CHECK and process-exit
  controls per mode reject. Acceptance is rechecked; 24 capture files per cell
  remain unchanged. These are auditor controls, not exhaustive production
  corruption coverage or independent model replication.
- Actual generated DEBUG/RELEASE bytes agree in all 58 regular files, 7,358
  bytes per mode; the actual files also match their recorded snapshots. The
  server-created active-part marker is not a generated-file normalization.
- Final SHA256/size recheck found no drift in 66 records: 44 sealed source/spec/
  harness files, eleven tool/root-probe pins, eight comparison-source files,
  the byte-comparison probe and two helpers. Formatting, Ruby syntax and
  exact-path hygiene are checked separately before the atomic local commit.

Return pointers: [root-owned evidence](../.landmark/evidence/materialized-view-transform-w257.json),
[project status](PROJECT_STATUS.md), [modularization frontier](MODULARIZATION_FRONTIER.md)
and [landmarks](../LANDMARKS.md). The curated packet is an index to executed
commands/captures, not proof by its structure. The standard packet template and
validator are absent; root uses explicit shape/path/digest checks as a fallback.

## Remaining frontier and evidence lifetime

Owner-specific bounded appenders, general keys/partitions, transform-to-projection
publication, projection-parent manifest authentication on read, other aggregate
state grammars and remaining physical context/layout handoffs remain open.
Existing nested Object Compact-like callback tapes and coordinate contexts are
reusable; their bridge into top-level part framing is not a missing recursive
codec for each type product. No new Compact part capability is admitted here.
The full types/MV/projections/performance goal remains ACTIVE; memory/performance
is deferred and no speed-parity claim follows from these gates.

Refresh after relevant admission/input/schema/owner/publisher/profile/fixture/
helper/compiler/native runtime changes or capture loss. Existing temporary
captures can decay; rerun the referenced bounded commands before reusing a
dependent compatibility claim. Exclusive catalog/destination ownership and the
non-guarantees above remain prerequisites.
