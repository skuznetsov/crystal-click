# Generic Variant recursive bulk frontier

Document status: VERIFIED within the normalized BASIC bulk boundary below;
paired implementation, stock exchange and final source-state gates executed.
Baseline: `af4c7fd` (W147 paired descriptor/RowBinary kernel).
Current frontier: paired normalized BASIC discriminator and sparse arm lanes.
The overall types, MV/projections and eventual performance objective remains open.

## Boundary

The `BinaryBulkCodec` surface composes the W147 canonical Variant
descriptor through existing ordinary containers and eligible LowCardinality
sites. Logical ordinary lanes start at offset zero; the eight-byte stock
Variant mode prefix is transport framing, not a row or an arm value. Stock
specialized-prefix settings determine whether it shares the discriminator lane
or resides in a separate `variant_discr_prefix` stream; adapters must observe
the emitted layout before normalizing offsets.
Discriminator role: `<path>.discriminators`; arm path: `<path>.arm.<index>`.
Indices are the canonical complete SQL-name order, not descriptor-tag order.
`FF` is NULL and consumes no arm occurrence. Selected empty containers remain
selected values, distinct from NULL. All static arms retain roles and K+1
offset grids even when no values occur in a mark.

Rejected: COMPACT discriminator framing in this generic codec, generic physical
basename/prefix binding, new public part profiles, declared Object Variant or
Dynamic, and Dynamic/JSON generic descriptors. Existing exact public part
profiles remain unchanged. Logical or normalized lane evidence does not qualify
an independent complete-part writer. Performance work remains deferred.

## Design laws and likely failure

The highest-risk failure is using root/flattened row counts as sparse arm counts,
especially for an LC arm after an empty mark. The LC occurrence schedule follows
all ancestor Array/Map sizes and Variant discriminators across all marks; NULL
contributes no child. Only LC-bearing arms allocate census grids. Dictionary
replay is complete; ordinary value materialization remains selected-window-only.
Shared operation budgets preflight every generated schedule grid and shape byte
before allocation/replay, without double charging selected shape bytes.
The direct scheduler seam must reject caller-supplied grid/shape metadata that
differs from the descriptor plan before charging or allocating census grids.
Nullable composite defaults use Variant NULL, not an arbitrary selected arm.

The budgets count logical codec work, not allocator/RSS usage. The parent
decoder validates the type tree before planning; the direct scheduler is not a
separate descriptor-depth/node budget validator. Its early descriptor-plan
comparison guards census metadata, not every allocation in type projection.

One cohesive owner per responsibility: type/role planning, occurrence schedule,
LC replay dispatch, ordinary writer and reader. Do not add facade classes for
every product of parent, arm and leaf type.

Source anchor: separate unbuilt depth-one checkout
`/Users/sergey/SrcArchives/clickhouse-2026-10-03-depth1-9007d227`,
`9007d227b64a3f8b667fc5258ceb2923f3cf477d`.
`SerializationVariant.cpp:301-414` visits even empty arms;
`:538-642` reads discriminators before deriving each arm's occurrence limit.
Stock runtime qualification must identify its different build separately.

## Implementation plan and rollback

Risk: CAUTION (serialization and recursive scheduling). Clean-tree baseline;
atomic feature commit only after the declared gates pass. Revert that commit to
restore the baseline; preserve unrelated work and do not push.

1. New `spec/binary_variant_bulk_w148*_spec.cr`: execute behavioral RED on the
   baseline, with literal role/grid/byte expectations before production edits.
2. `binary_bulk_type_plan.cr`, `binary_bulk_default_value.cr`, and a separate
   `binary_bulk_low_cardinality_occurrence_schedule.cr`: add sparse shape
   dependencies, counted grids and NULL default; keep existing size-only API
   meaning. Thin `binary_bulk_low_cardinality_site_decoder.cr` delegates census.
3. `binary_bulk_encoder.cr`, `binary_bulk_decoder.cr` and
   `binary_bulk_low_cardinality_site_encoder.cr`: traverse only the selected
   canonical arm, share budgets and exact per-mark consumption.
4. Keep `binary_bulk_physical_plan.cr` fail-closed and update W147's superseded
   bulk guard without relaxing Object/shared-MAP/legacy part guards.
5. New stock/checker scripts: direct Wide `.bin/.mrk2` lane extraction and
   library-emitted Native consumers, complete literal comparison and a valid
   wrong-value sensitivity control. Native-only round trips cannot establish
   physical lane and mark-grid identity.

Consumer inventory: `rg -n 'ancestor_size_role|BinaryBulkTypePlan' src spec`
finds the encoder, decoder, LC site owners and physical binder. New shape-role
and grid-count APIs propagate only to the decoder/schedule owner; the physical
binder remains explicitly refused for descriptors containing Variant.

## Falsifiers and Definition of Done

Root alone executes resource-guarded Crystal and stock processes, serially.
Expected signals:

- focused DEBUG specs: zero failures/errors/pending, literal BASIC lanes,
  sparse LC replay, both String profiles, full/middle/empty selection;
- adversary specs: malformed discriminator, grid, role set, trailing/truncated
  arm data, budget/depth boundaries and 254-active versus 255-NULL rejected or
  handled exactly as specified; forged direct-scheduler metadata rejects before
  any budget charge;
- affected RELEASE and complete unique spec inventory in serial disjoint
  non-release groups: zero failures/errors/pending, not a combined-process claim;
- fresh native probe/checker: exact source/runtime identity, lane/grid witnesses
  and stock consumption of library-emitted bulk payload, independent literal
  values/types and valid wrong-output rejection;
- affected formatter check, Ruby syntax and `git diff --check`: pass.

No production widening before behavioral RED. Failure of native framing or an
arm-count control prevents promotion of its compatibility claim; debug the
instrument/implementation instead of substituting RowBinary-only evidence.
Hostile review must attack arm-count, window-replay and guard propagation.

## Execution seal

Root execution on 2026-10-03 local / 2026-10-04 UTC, over clean `af4c7fd`:

- Baseline behavioral RED rejects the first Variant bulk fixture as unsupported;
  it is not a syntax/instrument failure. The separate schedule-metadata RED
  observes `{nodes, elements, bytes} = {1, 1, 1}` instead of zero before refusal.
  Two earlier scratch-probe compile errors do not count as behavioral RED.
- Final focused DEBUG: 50 examples, zero failures/errors/pending, seven files.
  Both String profiles include forged grid/role rejection before charge and a
  valid two-role permutation. Exact and one-short sparse-LC budgets, unselected
  invalid discriminators, selected empty containers, NULL and 254/255 boundaries
  are exercised by literal expectations.
- Final affected RELEASE: 517 examples, zero failures/errors/pending; 66 unique
  files together, with `--release --single-module --threads 1 --no-debug`.
- Final complete unique inventory: 2,434 examples, zero failures/errors/pending,
  across 378 files in sixteen serial disjoint non-release groups. The earlier
  pre-hardening run passed 2,433 examples; it is not substituted for this final
  source-state gate. Neither run is combined-process verification.
- Final affected `crystal tool format --check`, Ruby syntax and
  `git diff --check` pass. The formatter check does not alter the source state.
- Fresh stock discovery and exchange pass in
  `/private/tmp/crystal-click-w148.20261003-65012-1owgici`:
  two actual Wide parts, CHECK=1, six independently compared rows each, three
  adaptive granules and EOF. Every normalized role/K+1 grid compares; ordinary
  bytes compare exactly. LC dictionary/index bytes need not match the library's
  canonical dictionary: stock decode must match independent full/middle/last
  literals. Both observed discriminator prefixes are combined BASIC mode 0;
  the source-backed separate-prefix adapter branch is not physically qualified.
- Stock Native consumers accept the two library-emitted six-row payloads and
  match separately authored Ruby type/RowBinary literals. A valid UInt64
  `42 -> 43` mutation is accepted by both codecs and stock Native input, matches
  the mutant literal, and is rejected against the original output. Native
  payload framing is a finite adapter, not a new complete library-owned part.
- The first stock fixture mistakenly requested fixed `.mrk` using
  `index_granularity_bytes=0`; the final fixture explicitly requests adaptive
  marks and EOF. Atomic database aliases are allowed only at named stock alias
  paths with canonical targets inside that store, and are not traversed or
  counted twice. Root's separate guard probe rejects escaping, unexpected and
  dangling aliases. Final evidence: 220 regular files, 35,847 bytes.

Source reference: `9007d227b64a3f8b667fc5258ceb2923f3cf477d`, shallow
checkout named above. Separately pinned executable:
`/private/tmp/crystal-click-w144-runtime-recovery.Pm8VNb/clickhouse-stripped`,
version `26.10.1.1201`, build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`, SHA-256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
It was not built from the current source reference.

Root independently reviewed sparse-arm counts, shared-shape versus generated
grid accounting, selected/full replay and persisted guard propagation. Luna's
source reviews helped find risks but are correlated assistance, not independent
runtime evidence. Root's hostile verdict is ROBUST within this finite scope:
forged schedule metadata rejects before charge, sparse/empty/NULL arm counts
and full versus selected replay have literal and budget controls, invalid
unselected discriminators are rejected, persisted-profile guards remain
closed, and the valid wrong-value stock control discriminates value identity.
This verdict does not qualify the generic physical binder, every recursive
product, separate-prefix stock framing, complete parts or performance.
The installed evidence-packet skill has no template/validator assets; this
existing repository Frontier execution seal is the durable evidence index,
not proof generated by a structural validator.

Final code/spec/script lineage: the 14 affected paths in the feature diff over
`af4c7fd`, sorted by relative path, each encoded as
`relative-path + TAB + file-SHA256 + LF`, have aggregate SHA-256
`07cbd8fba2619dfe51b0404a3cb5e03c36edc2cf9dfb951fcb884d408b5596ce`.
Documentation is excluded to avoid a self-referential seal. Root rechecked
this fingerprint after final verification. Curated temporary evidence hashes:

| Evidence | SHA-256 |
| --- | --- |
| `w148.r9IBwB/schedule-red3.log` | `af7243bda5ff15b97f056e4ee1b156d38da3e3b4529e42ce59b4fbaf3ee98990` |
| `w148.r9IBwB/focused-hardened-final.log` | `f0fae5a0d3273b5646f306a3abc5c7e288246523051d414424983686891d76f1` |
| `w148.r9IBwB/release.log` | `9683e1207b909e972b5ec261cee45f957724402ee80e424564dbf95b16f66acc` |
| `w148.r9IBwB/full.log` | `75efc076cb8218fcf83dd424079667fb29d796d9310b71cc83667488db46e252` |
| `w148.r9IBwB/discovery.log` | `38c1be033ed28e3727a66c720c77d3b29ad99423702058f4d87d39d0251e6585` |
| `w148.r9IBwB/exchange.log` | `711f4879479bca702768c9e325f809b1f89f8987edfe3c23f40ffcecbdfb009e` |
| Fresh root `inputs/basic/manifest.json` | `28e26a3b0b5f55cca220c28b19e6ee895e0f79c6cd7fef5028c99a8baf456acd` |
| Fresh root `inputs/array_lc/manifest.json` | `fd348f47866e0c34df3a0e5822558b569f6510cb0aa55d28d9c4c5edf6505ab2` |

Log paths above abbreviate `/private/tmp/crystal-click-w148.r9IBwB/`; the fresh
root is the separately named stock directory above. Hashes identify captured
evidence, not a structural proof of its contents.

Replay: run `crystal spec --single-module --threads 1 --link-flags=-fuse-ld=ld
--error-trace` with these seven files:
`spec/binary_variant_bulk_w148_spec.cr`,
`spec/binary_variant_bulk_w148_adversary_spec.cr`,
`spec/binary_variant_value_w147_spec.cr`,
`spec/binary_variant_value_w147_adversary_spec.cr`,
`spec/binary_low_cardinality_bulk_w143_spec.cr`,
`spec/binary_bulk_w122_spec.cr`, and
`spec/bulk_budget_w122_adversary_spec.cr`; then the
affected inventory matching
`binary|dynamic|object|variant|physical_stream|compressed_mark|part_stream`,
then all recursively enumerated, sorted unique `*_spec.cr` under `spec/`
in disjoint groups of 24. Root alone
runs compiler/stock jobs serially through the existing guarded runner (32 GiB
process-tree ceiling, 50% free-memory threshold, 900-second per-job limit).
With `W148_EXECUTE_AS_ROOT=YES`, run
`ruby scripts/probe_variant_bulk_w148.rb discovery`, compile
`scripts/check_variant_bulk_w148.cr`, and run
`ruby scripts/probe_variant_bulk_w148.rb exchange <fresh-root> <absolute-checker>`.
The probe pins source/runtime separately and refuses existing output artifacts.
Temporary evidence may disappear; the reproducible scripts and this scoped
record remain, and missing runtime pins require renewed qualification.

Refresh on changes to descriptor canonicalization, path/role planning,
Variant/LC serialization, operation budgets, profiles, native adapters or the
source/runtime pins. Next track is separately qualified physical binding,
then declared Object Variant/Dynamic and the remaining types/MV/projection
frontier, before optimization. No generic binder, COMPACT generic bulk,
new public part profile, Object Variant/Dynamic, MV/projection, allocator or
performance admission is claimed.
