# AggregateFunction Variant composition frontier

Document status: VERIFIED within the seven finite W225 profiles (2026-10-08;
scoped verdict: ROBUST).
Baseline: `ba269a50a0978b7097b6c507237b0e78689807fa` (W224).
Current frontier: static Variant alternatives containing already-admitted
Count/Sum states reuse ordinary recursive child codecs and physical schedules.
This closes only the bounded W225 profiles, not arbitrary type products or the
full storage goal. No new serializer or public leaf union is proposed for a
type product.

## Boundary and factual anchor

The source comparison checkout is
`/Users/sergey/SrcArchives/clickhouse-2026-10-07-depth1` at
`0ca8150d9b1d0886edb2e3b4ab65eebb768d0357`. The executable oracle is separately
pinned ClickHouse `26.10.1.1201`, build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`, SHA-256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
These are not the same build and are not a claim about current upstream HEAD.

`DataTypeVariant.cpp:26-63` admits AggregateFunction alternatives, sorts complete
type names, and rejects direct Nullable, LowCardinality(Nullable), Variant and
Dynamic alternatives. `SerializationVariant.cpp:787-815` writes a UInt8 global
discriminator followed by the selected child serializer; its bulk serializer
enumerates child substreams under VariantElements/VariantElement.

The library already composes selected child values, sparse arm row domains,
roles and physical bindings. Before W225, the static admission visitor and
normal descriptor/wire constructors blanket-rejected aggregate-bearing
alternatives. Constructor legality, scalar recursion, bulk schedules and
physical qualification are separate claims; none implies another.
Generic static BinaryBulk public readers, writer, callback batches and owned
`.values` already exist; the legacy fixed Variant unions need no widening.

Source characterization and instrumentation were developed alongside
production work after the descriptor RED was established; stock capture did
not precede all production changes as the planned sequence below proposed.
After DEBUG native qualification, an auditor-only sorted-key fix was made; the
untouched raw evidence tree was separately re-audited. Keep this actual lineage
distinct from the plan. The pinned source checkout and executable runtime are
different builds, as recorded above.

## Design boundary (sealed; seven finite profiles qualified)

- Traverse each AF-containing static Variant alternative in the shared
  contextual AggregateFunction admission owner. AF-free siblings remain
  neutral and are skipped, not recursively walked by this visitor.
- Allow normal and binary-wire Variant construction when every AF-containing
  path satisfies that owner; preserve direct-arm roster rules and canonical
  name ordering, including strict wire order.
- Reuse exact Count and Sum leaf dispatch, ordinary recursive scalar/bulk
  codecs and existing static physical publication/consumer owners.
- Qualify finite quiescent Wide/LZ4/Default/plain-mrk2 BASIC-discriminator parts
  for root Variant, Array(Variant), Variant(Array(AF)) and Variant(Tuple(AF,...)),
  including both existing String profiles where relevant.
- Use `binary_bulk_values_for` for callback-scoped values and detached
  `BinaryValue` for owned column `.values`; do not alter fixed typed aliases.

## Rejected / guard-only / non-goals

- Direct Nullable(AF), LC(AF), direct Variant(Variant), Variant(Dynamic),
  Variant(Nullable) and existing QBit arm restrictions remain rejected.
  Existing JSON physical/context guards remain; this is not a blanket claim
  that CH or the logical library roster prohibits every JSON alternative.
- Map AggregateFunction keys remain a library guard, not a universal CH
  constructor prohibition. Count/Sum arguments remain metadata, never lanes.
- Dynamic known/runtime/shared alternatives and JSON typed/runtime paths are
  separate future contexts. No guard on those paths is relaxed in W225.
- The Object-declaration delayed Variant constructor remains in its narrower
  JSON context. CH's JSON extraction-tree builder rejects AF at serializer
  construction despite accepting some type declarations; constructor legality
  is not physical or JSON serde compatibility.
- No new Compact parts, COMPACT discriminator mode, sparse serializers,
  mutable-part safety, aggregate execution, projection/MV writing, PK candidate
  whitelist expansion, memory/performance optimization, or full-type claim.

## Plan and execution order

Risk: CAUTION (persistent format/admission boundary). Rollback: remove only
W225-owned edits from the clean baseline, or revert the eventual atomic commit;
never discard another worker's edits. Root alone executes serialized guarded
compiler/native jobs; workers edit only owned files, without jobs or git.

1. Add a compiling behavioral RED for normal/canonical/wire construction and
   selected state values before changing production admission.
2. Capture stock construction/RowBinary/Wide profile evidence from independent
   fixtures; distinguish process failure, constructor refusal and serializer
   refusal. Pin source/runtime/helper artifacts and exact nominal declarations.
3. Change only the shared admission visitor and normal/wire Variant gates.
   Preserve the narrower Object constructor and all other envelope guards.
4. Test scalar and bulk exact bytes, sparse/empty arm schedules and old rejection
   rules; paired-write/read public values, callbacks/windows and projection-child
   contexts without a new facade union.
5. Run affected regression cohorts in DEBUG and RELEASE; qualify stock reads and
   library ATTACH/CHECK/exact RowBinary on both fresh helper artifacts. Audit raw
   statuses, outputs and inventories, then execute a coherent CHECK-zero seed.

DoD commands (all compiler/native work under `run_safe.sh`, one worker,
`COGNI_RUN_SAFE_MIN_FREE_PCT=50`; exact executed paths recorded at closure):

- `crystal spec spec/aggregate_variant_w225_*_spec.cr` and affected W224/Variant/
  Dynamic/JSON/static-physical/public-consumer cohorts, in both modes.
- Build `scripts/check_aggregate_variant_w225.cr` in both modes, then run
  `scripts/recheck_aggregate_variant_w225.rb` with an externally measured helper
  SHA-256 and fresh isolated stores/evidence roots.
- Run `scripts/check_aggregate_variant_evidence_w225.rb` separately, including
  CHECK-zero rejection and exact restoration; formatter and diff checks pass.

Expected signals: zero test failures/errors/pending, exact fixture state bytes
and canonical descriptors, complete parent and sparse-arm mark grids, no callback
before format/nominal rejection, configurable owned-values budget rejection,
stock and library CHECK=1 and exact independent
RowBinary, unchanged inputs and independently audited raw process records.

## Falsifiers and strongest failure

The likeliest failure is confusing the parent row/mark domain with the sparse
selected-arm domain, or routing every tag `0x25` to Count. Use differing arm
counts, an all-NULL mark, a globally unused arm, Count VarUInt width boundaries,
and Sum(UInt8) states above UInt8 range. Retain every empty child mark and terminal
offset; no Sum argument-data lane may appear.

Other falsifiers: unsorted/duplicate wire roster; invalid direct arm; nested
illegal Map-key path; malformed/truncated discriminator or leaf bytes; wrong
nominal declaration; configurable retained-owner budget exhaustion before
owned-values return; Dynamic/shared and JSON guards; legacy exact Count and fixed Variant
routes. Raw audit must reject CHECK result zero even with process exit zero and
unchanged green summary. Fixture re-encoding is not disk-lane extraction and
logical budget accounting is not peak RSS.

The fixed 64 MiB table callback budget is inherited and regression-tested, not
newly qualified at its exact boundary with a large W225 fixture.

Stop rule: a failed native layout or process is investigated without widening
profile guards or treating an unsuccessful command as a semantic refusal.
Full-goal completion remains open after this slice; performance is deferred.

## Implementation seal

Slice: W225, VERIFIED within the seven finite profiles (scoped verdict:
ROBUST); the full AggregateFunction storage goal remains active.
Source/spec: anchors and finite boundary above; public specs are
`spec/aggregate_variant_w225_consumers_spec.cr` and
`spec/aggregate_variant_w225_adversary_spec.cr`; the paired helper is
`scripts/check_aggregate_variant_w225.cr`.
Executed evidence:

- The same unique 76-file roster passes 433 examples with zero
  failures/errors/pending in both DEBUG and RELEASE. RELEASE used eleven serial
  cohorts with counts `32,30,25,52,43,45,36,23,37,59,51`.
- Final `format --check` covers eight affected Crystal files; the final source
  freeze check covers all 1,311 entries.
- Fresh native helpers in both modes qualify seven stock reads and seven
  library ATTACH/CHECK witnesses per mode, including exact full/middle/empty
  RowBinary. Each mode records 136 `success_exit0` raw process records.
  Separate final raw audits pass in both modes. DEBUG helper SHA-256:
  `bd5165752d7dbece307fff28bd934a4513c9e4eca6db7e1d0e28423cfa448933`;
  RELEASE helper SHA-256:
  `6495e8397c56a8eb8304705e61004c91b9ad4e7e26f1b73dc3d64bd58cccdec8`.
- CHECK-zero and trailing-literal controls pass in both modes with exact
  restoration and no generated-file changes. The separately executed scratch
  reference/hash/count comparison finds all 130 generated files agree across
  the seven profiles and with attached records; this inventory comparison is
  not behavioral proof.
- The auditor-only sorted-key correction followed DEBUG native qualification;
  production and the raw evidence tree were untouched, then the raw tree was
  separately re-audited.

Boundary: these witnesses cover only the finite Wide/LZ4/Default/plain-mrk2,
BASIC-discriminator profile, five parent rows and marks `[2,2,1]` plus terminal
zero. Only the root Variant with String has both existing String profiles;
other profiles use SingleStream. Wrapped Count still uses Count VarUInt and
Sum remains an opaque nominal state lane; arguments are metadata. Unit-level
projection-child and synthetic offline catalog consumers are not native
full-catalog or native projection integration.
Direct Nullable(AF) and LC(AF) remain rejected. Dynamic/JSON AF envelopes,
other state families and physical layouts, MV/projection writing/semantics,
broad facade cleanup and performance remain outside this qualification. The
exact inherited 64 MiB callback budget boundary was not measured with a large
W225 fixture. Full-type compatibility is not claimed.
Next local track: Dynamic state runtime/known/shared context, subject to a new
source-backed frontier; MV/projection writer semantics remain separate.
Evidence packet: [aggregate-function-variant-w225.json](../.landmark/evidence/aggregate-function-variant-w225.json).
