# Compact part writer frontier

Document status: W264 VERIFIED / root adversary ROBUST within the bounded
static/plain-MRK3 witness and exact affected-consumer cohort (2026-10-12).
Baseline: `b91dafb547ba77e0667e936cd86ec5ae3687bbb3`.
Risk: CAUTION (persistent file format and exclusive publication).
Rollback: exact W264-owned paths; preserve the three unrelated untracked W263
specs. No push, history rewrite, original capture mutation, or native-store
reuse is authorized by this slice.

## Current boundary

The reader has a separately qualified finite MRK3/MRK4 frontier. There is no
Compact writer at the baseline. W264 adds the first physical backend, not a
new logical serde implementation and not completion of the full types,
MV/projection, or subsequent memory/performance objective. Those tracks remain
active; no throughput or <=10% parity claim is part of this slice.

Qualified entry point and local admission:

- `CompactPartColumn.binary_bulk(name, type, granules)` snapshots caller-owned
  name and granule arrays.
- `CompactPartWriter.write_uint64_columns(destination, key_name, keys,
  columns, rows_per_mark: 8192, frame_bytes: 4096, limits: ..., transport_limits:
  ..., reader_limits: ...)` writes one bounded nonempty part, with a synthesized
  UInt64 key column followed by static value columns in declaration order.
- Fixed plain MRK3, one LZ4 codec-owned stream, ordinary String version 0 and
  BASIC Map. Admit only stateless descriptors with an existing static
  declaration, typed carrier, physical plan, and callback schedule. Local
  admission is broader than any finite native witness; report the tested
  declarations separately rather than promoting the whole grammar.
- Complete the exact `Map(String, UInt64)` Compact batch-carrier bridge
  required by that finite witness. Reuse its established batch accessor, with
  descriptor/row/child checks and existing materialization accounting; do not
  bypass typed admission or label every legacy Map carrier supported.
- Common fixed parent grid, with a short final granule allowed, sorted keys,
  complete terminal mark, exact metadata/checksum roster, staged readback and
  atomic exclusive publication on the existing supported Darwin platform.

Rejected / guard-only future: LowCardinality, Variant, Dynamic, JSON/Object,
nominal serializers without a qualified static owner, non-BASIC Map,
String-v1, MRK4, compressed marks, mixed codecs, sparse/default-null-map
profiles, Compact projection/MV composition, incremental append and arbitrary
table metadata. Do not accept ignored Wide writer options or opaque
`WidePartColumn` carriers. Later slices must widen these boundaries with
matching falsifiers, not silently change the original goal.

## Design laws

1. Logical codecs and role plans stay shared. Completed Wide `.bin`/`.mrk2`
   pairs are not Compact output and may not be concatenated or relabeled.
2. Assemble **granule -> column -> callback**. Use the ordered existing
   Compact callback roster and physical role binding; sorted logical-role
   keys are not a serializer schedule. Preserve zero-byte child callbacks.
3. The stateless first backend may encode logical lanes once and slice them
   by mark. It must not use that shortcut for stateful serializers: upstream
   creates state and calls prefix/body/suffix for each column of each granule;
   Tuple phase ordering and first-granule-only Object/Dynamic statistics are
   load-bearing later laws.
4. Flush each granule's shared LZ4 segment. A segment can span several frames;
   each real column mark names its actual global compressed coordinate plus
   offset within that frame. MRK3 row width is `16 * column_count + 8`.
   All terminal pairs are `(data.bin size, 0)` and terminal rows are zero.
5. Use one write codec budget and one write transport budget across the whole
   operation. Logical lane encoding is owned by `BinaryCodecBudget`;
   transport decoded-byte limits cover the assembled tape/decoded frames,
   not those separately bounded logical lanes or RSS. Preflight the shared
   transport output and detached input containers before their allocations
   and before staging. Staged validation uses separate read-direction budgets,
   shared across selected columns. Preflight the potentially large persisted
   mark/frame grid before each context open, then charge the actual retained
   census once; bounded non-grid owners are censused after open. This is not
   a guarantee that every allocation or allocator peak is precharged. No
   per-column budget reset or caller input alias publication.
6. Compact's `data.bin` uncompressed checksum is the codec-stream fold, not
   simply the raw tape digest. For the single-codec slice, little-endian encode
   the incremental FileHasher digest, then apply CityHash128WithSeed with seed
   `(0, 0)`. Native `CHECK TABLE` explicitly skips this uncompressed fold for
   Compact; a passing CHECK is not fold proof. Qualify the finite witness
   against an independently inserted native writer part with the same decoded
   tape, raw size and saved folded hash. A fold-only mutation records the
   native checker's sensitivity gap, not an expected CHECK rejection.
7. Reuse the existing checksum, primary-index and exclusive-publish mechanics
   through neutral helpers and compatible Wide aliases/wrappers. Preserve old
   wire bytes, stage prefix, failpoints and refusal behavior. No weaker second
   rename path. The destination must have an existing parent and must not
   already exist or be a symlink; race-time collision also refuses.
8. A published part is visible only after exact physical/metadata validation
   and value readback. Any late error cleans only that operation's validated
   stage; an existing destination remains untouched.

Primary-source pins:

- `/private/tmp/clickhouse-w254-upstream.AqeqyC`, revision
  `ed30948f095ecb70679986d7d60e27ad770ae27a`,
  `MergeTreeDataPartWriterCompact.cpp:174-205,306-397,424-440,533-557`.
- Native runtime `/private/tmp/crystal-click-w263-runtime-recovery.B9uAPX/clickhouse-stripped`,
  26.10.1.1201, SHA-256
  `bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
  Source and runtime revisions are distinct pins, not asserted identical or
  latest. Native calls use fresh canonical temporary stores only.
- At the source pin, `checkDataPart.cpp:255-261` checks only the compressed
  Compact file and sets `check_uncompressed = false`. Root tool `c066cf`
  refutes the earlier assumption that native CHECK can qualify the raw fold.

## Observed W264 qualification

The exact 92-path affected-consumer cohort passes 620 examples in the final
serial DEBUG run (`106dfe`). Actual RELEASE passes the same disjoint union in
two executables: 29 paths / 194 examples (`1a17a5`) and 63 paths / 426 examples
(`12abc6`), all zero failures/errors/pending. The overlapping W264/W260 public
boundary also passes 37 actual-RELEASE examples (`ecaff8`); do not add them to
620. The combined 92-path RELEASE compile hit the unchanged 12 GiB process-tree
RSS guard before tests (`a85561`); it is not GREEN or reader/writer runtime
memory evidence. No memory/free-floor/thread guard was relaxed. An earlier
180-second DEBUG attempt had only partial output; only the final 360-second
run qualifies. Exact commands, paths and source seals are indexed in
[the curated evidence](../.landmark/evidence/compact-part-writer-w264.json).
The 63-path RELEASE subset retains its earlier W263 order, not its relative
order in the combined DEBUG command. These two executables do not certify all
cross-subset optimized interactions or combined test-order effects; the
37-example public boundary is an explicit additional check, not equivalence
proof for the combined RELEASE executable.

The final native probe (`13b17e`, exit 0) retains 33 bounded raw invocations in
`/private/tmp/crystal-click-w264-native.RyQZdG`. Its independently authored
eight-column witness contains UInt64 key/value, String, Nullable(UInt64), two
Array(Nullable(UInt64)) columns, positional Tuple(String, Nullable(UInt64))
and Map(String, UInt64). Eight rows form four two-row marks plus EOF. Cases
include MAX UInt64, integers above 2^53, UTF-8/NUL/non-UTF-8 String bytes, a
long String, NULL/ragged/zero-child callbacks and ordered Map associations.

- A separately INSERTed stock Compact part passes native CHECK and exact
  full/middle/last/empty reads, then the Crystal public typed reader. Both
  writers produce the same 8970-byte decoded callback tape SHA-256 and the
  same saved uncompressed checksum-fold words. Both independently match the
  computed upstream fold. Compression frame counts differ (Crystal 282,
  stock 32); physical byte equality or performance is not claimed.
- The generated part passes native ATTACH, active `system.parts` Compact /
  eight-row / five-mark observation, exact three-field CHECK=1 and literal
  full/middle/last/empty reads (8/4/1/0). ATTACH preserves `data.bin` and
  `data.mrk3`; the separately recorded `invalidated_system_columns.txt`
  metadata addition is not falsely reported as complete inventory identity.
- A stale compressed checksum copy attaches but returns native CHECK=0.
  A fold-only checksum copy attaches, returns CHECK=1 and unchanged values,
  measuring the checker's documented sensitivity gap. An independently
  checksummed malformed-mark copy attaches and passes CHECK=1, but public
  inspection raises CorruptPartError and native SELECT refuses with code 33.
  ATTACH, CHECK and SELECT are distinct observations, not interchangeable
  corruption proofs. Original native witnesses are unchanged.

Two earlier native attempts are INCONCLUSIVE, not format failures or GREEN:
the first used a nonexistent nullable setting; the second expected a two-field
CHECK row instead of the observed three-field TSV row with empty message.
The final DDL explicitly disables per-substream Compact marks: the current
native default otherwise writes MRK4, outside this writer slice. The exact
CHECK oracle still rejects flag=0, nonempty message, missing field and extra
field controls. Helper compiler-only API fixes and UTF-8 JSON report/fallback
fixes do not change production/spec/fixture sources; final helper build and
fresh native qualification follow those changes.

Root adversary verdict: ROBUST within these finite native, publication,
association and checked-budget obligations. This is not qualification of all
locally admitted declarations, arbitrary parts, MRK4/stateful writers, full
RSS bounds, full-suite GREEN or the active performance objective. Same-lineage
Luna review is correlated; actual native raw records and root source/falsifier
checks supply the discriminating evidence. Refresh after source/test/profile/
capture/compiler/consumer drift or scope widening.

## Implementation plan and ownership

1. Backend Luna: `compact_static_callback_plan.cr`,
   `compact_static_mrk3_writer.cr`, and one-class-per-file internal output
   carrier. Reuse `BinaryBulkCodec`, `BinaryBulkStream`, existing callback
   roster, `CompressedMarkWriter.encode_all/plan_literal_positions`, and
   CityHash. Change existing shared transport/normalizer only if an actual
   missing seam is demonstrated and the consumer cohort expands accordingly.
2. Publication Luna: `compact_part_column.cr`, `compact_part_writer.cr`,
   `compact_part_writer/{compact_part_operation,compact_part_metadata}.cr`,
   the checked `compact_mrk3_readback_grid.cr` preflight helper,
   the single `compact_static_column_input.cr` carrier, and neutral
   shared infrastructure plus old Wide-compatible wrappers. Enumerate affected
   helper consumers before extraction; legacy call sites should remain intact.
   The demonstrated Map bridge also owns the exact admission/install branch
   in `binary_value_typed_batch_adapter.cr` and its matching
   `wide_part_table/wide_part_table_batch.cr` Compact installer, with no generic
   gate removal or other carrier expansion.
3. Test Luna: `spec/compact_part_writer_w264_spec.cr`, owned support fixture,
   `scripts/compact_part_writer_w264_helper.cr`,
   `scripts/probe_compact_part_writer_w264.rb` and an offline auditor if needed.
   Independently authored Ruby/native values must not come from helper output.
4. Root: entrypoint requires, SDD/status/evidence, all serial formatter/build/
   test/native invocations, hostile review, exact staging and atomic local
   feature commit after DoD. No agent owns the protected W263 specs.

## Falsifiers and DoD

Observed pre-production anchor: the initial owned spec fails at the missing
`CrystalClick::CompactPartWriter` constant (root tool `2242a2`, exit 1).
This is API-absence RED only, not behavioral or native format evidence.
An initial sandbox run aborted at the process-group guard (exit 75); rerunning
the identical guarded command outside that sandbox produced the compiler RED.
Memory/time limits were not relaxed.

Subsequent behavioral REDs distinguish two production gaps: the public bridge
exposed retained caller snapshots (root `456f0f`, marks reduced to one and
first value changed), and a capped staged read allocated the grid before
refusing (root `5ce911`, two grid reads rather than zero). The same isolated
bridge source passes after detached containers (`18e069`). The first complete
writer positive also fails at the exact `Map(String, UInt64)` Compact batch
admission (`5ce911`); its codec accepts the type, but the legacy adapter lacks
the corresponding installer. Keep these observations distinct from compiler
failures and from later native evidence.

The calibrated workspace guard is independently RED under the old calculation
(`420091`, 19 examples / one failure): subtracting reader-base bytes from the
observer's full physical workspace reaches callback three instead of refusing
at callback two before opening the value window. The unchanged calibrated
spec passes with the full-workspace preflight (`2cdd57`, 19 examples / zero
failures/errors/pending). The cap is based on each run's retained census and
half of the observed physical workspace; a brittle one-byte cross-path cap
was rejected during calibration. This distinguishes the actual guard from
an apparent refusal caused only by a different temporary path length.

DoD commands run serially through `cogni-ml/scripts/run_safe.sh`, Crystal 1.21.0,
one compiler/thread, 12 GiB cap and 50%-free floor:

- Principal seam cohort (expanded to the exact 92 affected paths in the final
  DEBUG run and actual-RELEASE partition above):
  `crystal spec spec/compact_part_writer_w264_spec.cr
  spec/writer_infrastructure_refactor_root_spec.cr
  spec/multi_column_part_writer_w245_spec.cr
  spec/multi_column_tuple_dynamic_w246_spec.cr
  spec/static_binary_bulk_table_w247_spec.cr
  spec/wide_part_writer_leaf_seam_spec.cr
  spec/wide_part_writer_typed_mark_readback_spec.cr
  spec/compressed_literal_position_plan_w240_spec.cr
  spec/compressed_mark_positions_w194_spec.cr
  spec/compressed_mark_transport_w124_root_spec.cr
  --single-module --threads 1 --link-flags=-fuse-ld=ld --error-trace --no-color`.
  Expected: no failures/errors/pending; expand by affected consumers if shared
  helpers change beyond these tested seams.
- Owned paths only: `crystal tool format --check <exact changed .cr paths>`.
- Guarded build of the new helper, followed by the new Ruby probe with pinned
  binary/helper and fresh evidence root. Reuse W241's bounded raw-process
  owner; retain argv/stdin/stdout/stderr/status and executable hashes.
  Expected: actual `data.bin`/plain `data.mrk3`, multiple frames/granules,
  exact schema and rows, native `ATTACH`, `CHECK TABLE = 1`,
  `system.parts.part_type = Compact`, full/middle/last exact typed values, and
  stable generated/copied part snapshots. Compare decoded tape SHA, raw size
  and saved checksum-fold to a separately INSERTed stock Compact reference;
  CHECK alone cannot qualify that field. Self-roundtrip is not sufficient.
- Sensitivity / adversaries: Wide-layout impostor is not a Compact positive;
  stale checksum and independently resealed malformed-mark disposable copies
  refuse at their intended boundaries; empty callbacks/EOF/short tail retain
  association; shared budget exhaustion and staged/rename failures publish
  nothing and never replace a destination. No original witness mutation.
  Keep ATTACH/CHECK/SELECT outcomes separate: the checksum-fold-only poison is
  expected to pass CHECK and preserve rows; a resealed malformed mark may pass
  checksum-only CHECK but must fail public structural validation and affected
  native value reads.

Strongest likely failure: correct-looking self-roundtrip bytes with wrong
shared-stream coordinates or uncompressed hash accepted by our own readers.
Native cross-read and independently literal value/shape checks discriminate it.
Before a verified claim, root reviews helper extraction consumers, corrupt
counterexamples, exact source seals and the finite native oracle scope.

## Continuation

After this physical MRK3 backend: MRK4, stateful leaf/recursive serializer
lifecycles, context-owned Dynamic/JSON, remaining type combinations,
MV/projections, then measured memory/performance work. The full active
objective is unchanged; this document is a current compatibility boundary,
not a substitute completion definition.
