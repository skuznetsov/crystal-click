# Specialized projection readers frontier

Document status: VERIFIED within the declared finite scope (W217/W218/W219,
2026-10-08); scoped verdict ROBUST.
Baseline: `b2a06eec9b73745c87941f060f29d40b70cc0a28`.

## Current boundary

At the baseline, W87 opens explicitly selected, completely covered Wide projection children.
Each child has its own schema, row count and marks; callbacks retain the
selected parent identity. Primitive typed readers are admitted. Whole Object,
Array(JSON), recursive JSON, recognized generic Dynamic bulk and the exact
AggregateFunction(count) pair are explicitly refused by `WidePartTable`, even
though their lower readers already accept a supplied child directory.

The W217 candidate reuses those existing owners wherever the child satisfies their
existing physical admission laws. This is consumer propagation, not a new
serializer, a new layout, or one codec per wrapper product.

## Design laws

- Validate every selected parent's declared child coverage before opening a
  reader; missing children never fall back to parent data.
- All column declarations, checksums, serialization profiles, row counts,
  physical stream rosters and schedules come from the child directory.
- Child row/mark axes are independent of the parent. Retain parent identity in
  callbacks, without substituting parent counts for child counts.
- Reuse ObjectColumnAdapter, ArrayObjectColumnAdapter,
  RecursiveColumnAdapter, DynamicBulkColumnAdapter and
  WideAggregateCountPairAdmission without weakening their admission checks,
  budgets, ownership rules or complete-schedule validation.
- Count continues to require exactly its admitted state column and UInt64
  sibling, with matching child row/mark axes. No other aggregate states are
  admitted by this change.
- Keep direct `.proj` opening, symlink children, unsafe names, flattened
  context plus projections, unsupported metadata and layouts rejected.

## Rejected and non-goal surfaces

Uncovered or malformed children, unsupported existing reader profiles,
Compact parts, projection definition execution, optimizer selection,
projection writing, MV SQL evaluation, freshness and provenance are not
admitted. Generic owned Dynamic `.values` is a separate remaining consumer.
Production checksum hashing and whole-scan callback atomicity are not claimed.
The overall types/MV/projections goal remains open; performance work is deferred.

## Execution and falsifiers

Risk: CAUTION (public storage admission). Rollback: exact owned diff against
the clean baseline; no remote mutation.

1. Add `spec/projection_specialized_consumers_w217_spec.cr`; run it on the
   unchanged production gates and observe behavioral RED, not a compiler error.
2. Remove only demonstrated projection-specific vetoes in
   `src/crystal_click/wide_part_table.cr`. Existing owners remain authoritative.
   Replace historical refusal assertions only after actual RED establishes the
   new expected behavior.
3. Run focused DEBUG and RELEASE specs, W87 projection and W88 MV guards, and
   relevant direct Object/Array/recursive/Dynamic/Count reader regressions.
   Root alone runs serial jobs under the unchanged min-free 50% guard.
4. Build and run `scripts/check_projection_specialized_w217_oracle.cr` in both
   modes against the pinned stock runtime. Require fresh stock-authored
   `.proj` children, actual CHECK results, exact child declarations and literal
   stock/library row equality through low-level and catalog consumers. Count
   must witness a different child/parent row domain. Audit raw SQL, process
   records, outputs and unchanged physical inputs independently.
5. Attack missing child coverage, malformed/excluded schedules, wrong Count
   sibling and parent-grid substitution. Keep the guarantee bounded to the
   checks actually executed; update this frontier and project status before a
   local atomic commit. Do not push.

DoD commands: root guarded `crystal spec` on the new corpus and affected
regression cohorts, with `--single-module --threads 1 --link-flags=-fuse-ld=ld`
and optional `--release`; guarded build/run of the native probe. Expected:
zero failures/errors/pending in both modes, stock CHECK result 1, exact
literal row equality, and behavioral rejection for each retained guard.

Source anchors: `WidePartTable.open_selected_projection_typed`, its child
coverage preflight and five projection vetoes; `ObjectColumnPartMetadata.open`
reads the supplied directory; Count pair admission opens the UInt64 sibling
from the same directory. Native fixtures, not source shape alone, decide
whether a stock child's physical profile is compatible.

Evidence expires on changes to child selection, those owner admission laws,
serializer profiles, stock runtime identity or fixture inputs. Refresh the
affected behavioral and native gates; do not infer wider layouts from this
consumer change.

## Observed qualification and refuted routes

The original six-example consumer corpus first failed behaviorally on five
projection vetoes. Removing only those 15 production lines reuses existing
specialized owners. An actual parent-path substitution seed then fails with
wrong child values and missing selected columns; the seed was restored.

The first fresh DEBUG native run is retained as a diagnostic, not erased:
stock processes and CHECKs succeeded for all six cases, but the library read
only four. Tuple(JSON, UInt64) was refused for unsupported serializer
subcolumns; Count was refused for escaped expression names. SQL aliases do
not avoid the physical-name gap. The initial raw-artifact audit proved the
six stock inputs, not library support. The fixture roster and original
native DoD were kept unchanged.

W218 adds a bounded schema-bound Default Tuple metadata owner. W219 propagates
canonical escaped names through Count and ordinary UInt64 reads. Their REDs
compile and fail behaviorally. ROOT also caught a remaining raw UInt64
mark-range lookup and historical filename-validation error precedence before
final qualification. Existing JSON typed-path names and ASCII writer output
remain unchanged. The Tuple validator-bypass seed makes the unchanged corpus
fail with one assertion failure and five errors before exact restoration.

Final serial guarded gates pass the same 48 spec files and 252 examples per
mode: 26 focused, then 38/39/31/37/81 regression examples, DEBUG and RELEASE.
Conditional native branches in historical Count specs are not counted as
stock witnesses. Fresh original six-family native runs pass all six cases in
each mode: whole JSON, Array(JSON), Tuple(JSON, UInt64), root Dynamic,
Array(Dynamic) and the exact grouped Count pair. Low-level and OfflineTable
consumers agree with literal stock expectations. Every stock process exits
zero; CHECK returns 1 for both source parts and optimizer-off EOF reports 12
source rows. Count consumes two child parts with three rows/[2,1] each, versus
six rows/[2,2,2] in each parent. Other native families use equal parent/child
axes; their divergent-axis tests remain synthetic.

The separate read-only auditor in
`scripts/audit_projection_specialized_w217.rb` checks BOTH raw evidence trees:
exact case/SQL/process roster, literal stock rows, source/child declarations,
plain mark grids, executable pin, complete live parent-file rosters/hashes
and pre/post immutability. Library result.json is supplementary only; actual
library equality assertions belong to the executed Crystal oracle. Both source
manifests equal SHA-256
`5e92a7bee76607a2e849182874df55a1b8eff5c04c0a4d3482a40ab9a1b8ae7a`.
No new leaf codec or writer profile is added.

Stock runtime: 26.10.1.1201, build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`, executable SHA-256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
Comparison source is the separate shallow checkout
`/Users/sergey/SrcArchives/clickhouse-2026-10-07-depth1`, revision
`0ca8150d9b1d0886edb2e3b4ab65eebb768d0357`; it is not this runtime's build.

## Recursive composition and remaining frontier

Value serde is already recursive. Physical composition additionally carries
stream roles/names, descriptor positions, row/element/dictionary domains,
granule schedules, serializer state, metadata and inherited budgets.
Array(LowCardinality(String)), for example, has outer-row offsets, element
keys and a separate dictionary domain. Reuse the String codec, not one codec
per complete product. Tuple serializer-info recurses; Array/Nullable info
does not acquire a Tuple tree merely because value decoding recurses.

Keep base codecs, wrapper-local composition rules, physical plans and consumer
adapters separate. A shared physical-layout visitor is a future architectural
direction, not an implemented repository-wide refactor. Some current refusals
are explicit CrystalClick admission restrictions rather than CH type laws:
BinaryDataType rejects Array(QBit), while the pinned CH source and
04817_window_partition_by_aggregate_function_state.sql contain that type.
Removing a local guard still requires its physical path and tests to be added.

Owned generic Dynamic offline values, other JSON/shared profiles, wrapper
admission gaps, projection writing/optimizer/freshness/provenance and MV SQL
evaluation remain open. One new owner file does not close broad facade
decomposition. No checksum-hash, whole-scan callback-atomicity, benchmark or RSS
claim is made. The overall goal stays active; no push or performance work.

## Evidence and refresh

[W217 evidence packet](../.landmark/evidence/specialized-projection-readers-w217.json)
indexes the commands, refutations, source pins and limits. Temporary raw roots:
`/private/tmp/crystal-click-w217-final-debug.u1Wc0M` and
`/private/tmp/crystal-click-w217-final-release.Ewce71`.
Logs: `/private/tmp/crystal-click-w218-w219.ll3syL/`.
Earlier diagnostic: `/private/tmp/crystal-click-w217-native-debug.GuJybt/`.
Temporary artifacts are not durable storage. If missing, or if selection,
owner admission, metadata/name binding, runtime or inputs change, rerun the
affected specs and both fresh native roots/audits. Do not widen claims from the
packet's structure or from a previous green run.
