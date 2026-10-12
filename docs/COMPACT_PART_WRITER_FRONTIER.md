# Compact part writer frontier

## Current transition: context-owned Compact Dynamic writer — W268

Status: W268 VERIFIED / root adversary ROBUST within the finite context-owned
Dynamic witness, plain-MRK3/MRK4 modes and exact affected cohorts (2026-10-12).
Baseline: `8007cf0d1f2f5c610e0552ee2968224879e0a799` (W267).
Explicitly context-bound Dynamic columns now join the existing static/LC/
Variant columns in the same physical assembler. Unbound Dynamic and declared
JSON/Object column/path layouts remain executable refusals. Native qualification
is the measured witness below, not every recursively admitted descriptor. The
full objective stays ACTIVE.

Risk: CAUTION (persistent recursive serialization and public context binding).
Rollback: revert only W268-owned changes; preserve the three user-owned W263
specs, original native captures and W264-W267 byte/native regression oracles.
Do not change the existing Wide policy, common scalar codecs or static output
bytes to make the new witness pass.

Target: bind each declared Dynamic site's immutable part-wide actual roster
and serialization version before encoding Compact granules. Reuse the existing
`BinaryDynamicBulkPlan`, `DynamicStructureCodec`, recursive `BinaryBulkEncoder`
and Variant framing adapter; retain one physical Compact assembler. Public
input must explicitly carry the structure context rather than infer a new
ordinary roster from every mark. Multiple recursive sites remain independent.
Keep the current LZ4, single-stream String, BASIC Map, sorted UInt64 key and
plain MRK3/MRK4 contract. Existing source-valid shared-owner admission gates
remain authoritative; qualification is no wider than actual falsifiers.

Primary source: upstream `ed30948f095ecb70679986d7d60e27ad770ae27a`,
`MergeTreeDataPartWriterOnDisk.cpp:634-687`,
`MergeTreeDataPartWriterCompact.cpp:174-205`,
`SerializationDynamic.cpp:182-328,529-558,600-615` and
`SerializationVariant.cpp:199-228,326-340`. The source and native executable
are distinct pinned revisions. No latest-version or all-version claim follows.

Design laws:

1. Part/column structure and ordered callback roster stay bound across marks.
   Each granule gets fresh prefix/body/suffix state; prefixes use the bound
   sample structure, bodies use the actual slice. Unseen types use the implicit
   SharedVariant lane under the existing Dynamic selector, not a new stream.
2. Dynamic statistics are full in the first prefix and empty in later prefixes.
   Version-specific framing remains owned by `DynamicStructureCodec`; Dynamic
   V3 wire value 4 is not the Native-only FLATTENED wire value 3. Preserve nested
   Variant and LC prefix/body phases and callbacks for zero-occurrence arms.
3. Logical roles, physical callback names and MRK4 slots are different owners.
   Validate their exact ordered mapping before assembly. MRK3 records the first
   callback for a whole column; MRK4 records every source-requested callback.
   Retain EOF coordinates, all parent/child counts, one operation budget and
   detached immutable caller inputs before staged publication.
4. Run an existing-public-API positive against the baseline and observe the
   current Dynamic refusal before production changes. Compiler, fixture and
   resource-guard failures do not qualify as behavioral RED.
5. Qualify stock INSERT-to-Crystal and Crystal-to-stock ATTACH/CHECK/literal
   SELECT, including late roster changes, NULL-only and empty nested marks,
   independent sites and full/middle/last/empty windows. A copy-only resealed
   structure-version defect must fail selected semantic reads; CHECK alone is
   not a value oracle. Literal values and callback/mark audits must not derive
   their expected truth from the candidate encoder.

Rejected / guard-only: declared JSON/Object columns and ordinary actual-arm
Object/path callback layouts, Native-only FLATTENED Dynamic, unknown versions
or mismatched/missing site contexts, compressed marks, other String/Map
profiles, arbitrary metadata/keys/partition lifecycles and Compact MV/projection
composition. JSON retains its own path/layout/statistics context and is the
next writer transition, not a relaxed Dynamic guard. No speed, granule-only-I/O,
all-types or full-suite completion claim.

The Compact callback-profile validator applies to declared descriptors and
ordinary actual arms, not to every SharedVariant payload. Unrostered values
retain the common single-String scalar-envelope codec and its existing
JSON/AggregateFunction/recursive-QBit admission gates; these values do not add
Object path callbacks. W268 native qualification covers only String/UInt64
shared payloads, not JSON/AggregateFunction/QBit envelopes. Its mixed assembly
witness combines an inserted static UInt64 key with Dynamic value columns;
arbitrary user-declared static-value/Dynamic interleavings remain unqualified.

Falsifiers and DoD: baseline focused Dynamic writer RED; focused positive and
hostile tests; exact affected writer/Dynamic/LC/Variant consumer cohorts in
DEBUG and actual RELEASE; stock-first Dynamic witness and raw callback/mark/
version audit; selected checksum-resealed mutant with clean/locality controls;
fresh W267 Variant, W266 LC and W265 static native/byte guards. Root records
expanded commands, exact pins/counts/seals and residual coverage. All compilers,
tests and native probes are root-only and serial with one worker/thread, the
unchanged 12 GiB process-tree and 50%-free guard. No original capture mutations.

Strongest likely failure: a later or empty granule silently rebuilding a site's
ordinary roster, statistics or callbacks; another is confusing a structure
prefix with an eight-byte Variant/LC prefix. Freeze two independent sites whose
active values change between marks, inspect literal prefix and MRK4 order, and
use an invalid persisted-version mutant. Stop and revisit context ownership if
stock output contradicts this contract; do not narrow the full objective or
weaken existing profile/carrier/resource gates.

### Executed W268 qualification

- Final serial DEBUG and actual RELEASE each pass the same disjoint 66 paths /
  478 examples: writer 32 / 202, LC 11 / 108, Variant nine / 59 and Dynamic
  14 / 109. All have zero failures/errors/pending. Production and source/spec/
  script seals remain held; no combined-executable or full-suite claim.
- Fresh native root `/private/tmp/crystal-click-w268-native.dfVKhU` (`b2623b`):
  79 bounded invocations / 316 authenticated raw files. Two independently
  INSERTed stock MRK4 modes read in Crystal; all four generated MRK3/MRK4 x
  BASIC/COMPACT cells ATTACH/CHECK=1 and literal 12/4/2/0-row windows pass.
  Source and runtime are distinct pins; native build is
  `d9bcb5ab007f0f6299f7f973f2642245bab3d028` (26.10.1.1201).
- Root independent LZ4/callback/mark/literal audit (`bfcb65`) checks identical
  decoded BASIC 629 / COMPACT 645 bytes and all 406 coordinates across the six
  parts. The 13-slot MRK4 roster retains separate structure and Variant
  prefixes, late shared values, NULL-only root and empty nested marks. Stock
  and generated compression frames differ (18 vs six); no physical/speed parity.
- A copy-only nested mark-two wire-version 4 -> 3 defect changes only decoded
  byte 291. Unsealed ATTACH succeeds, but CHECK reports exactly one data.bin
  checksum failure (code 40). Resealed ATTACH/CHECK=1 succeed; selected middle
  reads fail semantically: native code 117, local `CorruptPartError`. Native
  key/root middle and nested last/empty controls remain literal-exact, as do
  local key/root middle controls. Empty native selection is not EOF traversal;
  whole-grid local preparation prevents an outside-window locality claim.
- A separately observed actual-arm guard RED exposed admission of a Compact-
  unsupported AggregateFunction(count) actual type. The fix reuses the existing
  recursive Compact validator at each ordinary actual arm's site depth. Both count and
  SimpleAggregateFunction negatives pass now; there is no separate measured
  SimpleAggregateFunction RED. Nominal max_types does not replace the existing
  Dynamic physical roster limit.
- Fresh previous native guards and independent root audits pass: Variant
  69 / 276 raw files (`0f367b` / `8ef175`), LC 33 / 132 (`aab86e` / `c79cf8`),
  static 68 / 272 (`e777ef` / `5fba60`). All nine frozen W264 files are identical
  (17902 bytes). Three protected W263 specs and original 52 parts / 544 files /
  756378 bytes are unchanged and outside staging. Tooling/fixture corrections
  are not behavioral format REDs.
- Return pointer: [W268 evidence](../.landmark/evidence/compact-part-writer-w268.json).
  Refresh after relevant source/test/profile/compiler/runtime/capture drift,
  temporary-evidence loss or widening. Next: context-owned JSON writing,
  remaining layouts/combinations and Compact MV/projections, then optimization.
  Full goal ACTIVE; local atomic commit only, no push.

### W268 accepted implementation plan and baseline RED

Root revalidated the unchanged baseline with
`crystal spec spec/compact_part_writer_w268_spec.cr --single-module --threads 1
--link-flags=-fuse-ld=ld --error-trace --no-color`, wrapped in the unchanged
12 GiB / 50%-free guard. Tool `69eaac`, exit 1: one example, zero assertion
failures, one `UnsupportedFormatError` at
`compact_static_callback_plan.cr:34` ("Compact static writer does not admit
Dynamic state"). Compilation completed and the intended format guard ran.
This positive used the existing unbound `binary_bulk` API: it demonstrates
missing Dynamic writing, not the correctness of a not-yet-existent explicit
context API. After introducing that API, keep unbound Dynamic refusal as a
negative and move positive fixtures to explicit context binding.

- Public API: `CompactDynamicWriteContext.new(site_structures : Hash(String,
  DynamicStructure))` snapshots exact canonical site paths and immutable
  structures; `CompactPartColumn.dynamic_bulk(name, type, granules,
  dynamic_context)` creates a distinct Dynamic input. Existing `binary_bulk`
  and static input/plan gates remain strict. Every site must supply full first
  prefix statistics, including V3; these are the frozen first-block sample's
  statistics, not a recomputation over final-part values. V1/V2 later prefixes
  carry canonical zero counts and empty shared statistics; V3 later prefixes
  carry the absent-statistics flag. Reject missing/extra/mismatched context.
- Production worker owns new own-file context, Dynamic input/callback/encoded
  column and mixed `CompactPartWritePlan` owners under `src/crystal_click/`;
  existing owned seams are `src/crystal_click.cr`, `compact_part_column.cr`,
  `compact_static_writer.cr`, `compact_part_writer/compact_part_operation.cr`
  and `compact_part_writer/compact_part_metadata.cr`. A minimal context-neutral
  `compact_dynamic_bulk_prefix_traversal.cr` roster overload is also approved:
  accept the common Dynamic physical/logical plans and keep the current reader
  prepared-context overload delegating unchanged. The only extra static-owner
  seam is `compact_encoded_column.cr#each_callback_event`, forwarding its
  existing plan traversal unchanged so static and Dynamic encoded columns feed
  the same assembler without a second callback grammar. Request root approval
  before changing additional production owners. Static callers retain their
  current strict plans and bytes; the mixed plan feeds the existing single
  physical assembler and metadata roster. Staged validation dispatches Dynamic
  to the existing selected Dynamic reader, with operation-scoped budgets.
- Consumer inventory: root `rg` over these owners and W264-W267 specs/support
  found public `.static_input` snapshot callers in W264, direct static plan/
  encoder consumers in W265-W267 and the MRK3 convenience wrapper, metadata
  bound to `CompactStaticWritePlan`, and operation workspace/selected-readback
  seams. Preserve these signatures or introduce explicit compatible overloads.
  The separate Dynamic reader and shared Dynamic codec consumers form an
  additional regression cohort; do not reuse read-direction prepared context
  as writer authority or create another logical recursive serializer.
- Test worker owns only `spec/compact_part_writer_w268_spec.cr`,
  `spec/compact_part_writer_w268_adversary_spec.cr` and
  `spec/support/compact_part_writer_w268_fixture.cr`. Oracle worker owns only
  `scripts/compact_part_writer_w268_helper.cr` and
  `scripts/probe_compact_part_writer_w268.rb`. Root owns docs/evidence and all
  serial runtime checks. No worker may run a compiler, test, native probe,
  formatter or network command; preserve other workers' and user edits.
- Native fixture: 12 rows, six two-row marks plus EOF; `pk UInt64`,
  `root Dynamic(max_types=1)`,
  `ctx Tuple(label String, items Array(Dynamic(max_types=1)))`. Independently
  supplied root/nested UInt8/UInt16 rosters exercise late String/UInt64 shared
  values, NULL-only/empty marks and independent site state. Parse the native
  callback inventory rather than deriving expected truth from the helper.
- DoD: focused positive/hostile specs; exact disjoint affected writer, LC,
  Variant and Dynamic cohorts in DEBUG and actual RELEASE; fresh helper build,
  `ruby scripts/probe_compact_part_writer_w268.rb --clickhouse PINNED_BINARY
  --crystal-helper PREBUILT_HELPER --evidence-root FRESH_ROOT`; fresh previous
  Variant/LC/static native and default-byte guards. Expected: zero scoped
  failures, stock/candidate literal and callback/mark agreement in both
  discriminator modes and plain mark formats, and selected semantic rejection
  of a checksum-resealed copy-only middle structure-version mutant while clean
  locality controls pass. Record exact expanded commands, pins and seals.

## Previous extension: recursive Compact Variant lifecycle — W267

Status: W267 VERIFIED / root adversary ROBUST within the finite recursive
BASIC/COMPACT Variant, plain-MRK3/MRK4 witness and exact affected cohorts
(2026-10-12). Baseline behavioral RED: one example, one
`UnsupportedFormatError` at the existing Variant-state refusal.
Baseline: `260599cd2ad058a602824f65f6ddcbbccd8a1677`.
Risk: CAUTION (persistent recursive serialization, physical framing and public
input binding). Rollback: revert only W267-owned changes; preserve the three
user-owned W263 specs, all original captures and W264-W266 byte oracles.
The full types/MV/projection/performance goal remains ACTIVE.

Target: author BASIC and COMPACT Variant discriminator layouts through the
existing recursive static declaration/value/codec owners, under the current
LZ4, String-v0, BASIC Map, sorted UInt64 key and plain MRK3/MRK4 part contract.
An explicit part-level discriminator mode selects every recursive Variant site;
COMPACT is the default, matching the pinned native Compact setting. Do not
introduce another logical Variant serializer or duplicate the physical writer.
Root Variant, eligible recursive containers, multiple independent sites,
unused arms, NULL-only/uniform marks, empty nested marks and LC-containing
alternatives are part of the test target, subject to the existing declaration
and typed-carrier gates. Native qualification is limited to measured cells,
not inferred for every descriptor admitted by those shared owners.

Source anchor: pinned upstream `ed30948f095ecb70679986d7d60e27ad770ae27a`,
`MergeTreeDataPartWriterCompact.cpp:174-228`,
`MergeTreeSettings.cpp:298-303` and
`SerializationVariant.cpp:199-246,326-415,454-523`. Each column/granule gets
fresh prefix/body/suffix state. Every Variant emits an eight-byte LE mode
prefix before all recursive child prefixes. BASIC emits one tag per
occurrence; COMPACT emits a VarUInt occurrence count, format byte and uniform
tag or plain tag vector. A zero-occurrence arm still participates in the
callback schedule, but an empty Variant body emits no frame.

Design laws and execution order (retained qualification contract):

1. First run `spec/compact_part_writer_w267_spec.cr` against the baseline and
   retain an actual failure on the current Variant rejection. Compiler or
   fixture defects are not format REDs. Only then widen production admission.
2. Reuse `BinaryBulkEncoder` for logical per-granule tags/arms and the existing
   `BinaryBulkDiscriminatorFramingAdapter` for BASIC/COMPACT physical framing.
   Prefix and body remain distinct callbacks/mark slots over the same role;
   preserve every empty arm, nested prefix, EOF pair and declared phase order.
3. Bind the part-level mode immutably through public input, callback plan and encoded
   column. Reject mismatched plans, unknown modes, malformed role/prefix grids
   and exhausted cumulative budgets before publication. LC validation remains
   dictionary-specific rather than treating every state prefix as LC.
4. Native INSERT-to-Crystal and Crystal-to-native ATTACH/CHECK/literal SELECT
   must cover both discriminator modes and MRK3/MRK4, including full/middle/
   last/empty windows. A copy-only, checksum-resealed framing defect must be
   detected by selected value reading; CHECK alone is not a semantic oracle.
5. Root runs focused and exact affected DEBUG/actual-RELEASE cohorts, followed
   by the old static and LC native/byte-oracle guards. All compiler/probe/native
   commands remain serial with one worker/thread, 12 GiB process-tree and
   50%-free limits. No full-suite, all-version, large-part or performance claim.

Rejected / guard-only: Dynamic/JSON writer state, compressed marks, other
String/Map profiles, arbitrary source-valid declaration/carrier combinations,
general key/partition metadata and Compact MV/projection composition. Do not
widen these gates to make a fixture pass. The current LC reader still requires
whole-grid preparation; no granule-only-I/O or single-prepare optimization.

Strongest likely failure: correct logical tags paired with the wrong physical
prefix/body boundary or Q_i child count, particularly an unused LC arm inside
an empty nested Variant mark. The discriminators' exact raw framing, all MRK4
slots, independently literal values and cumulative budget refusal are the
guard checks. Reopen the candidate on a contradictory stock witness.

Accepted bounded implementation plan (2026-10-12):

- Add `src/crystal_click/compact_variant_discriminator_mode.cr`, one enum
  owner with `Basic`/`Compact`; append `variant_discriminator_mode` to the
  public writer and propagate it through the operation and immutable write/
  callback plans. Preserve existing positional arguments and default MRK3.
- Extend only `CompactEncodedColumn`'s per-mark state path to Variant:
  shared-budget logical encoding, aggregate discriminator adaptation preflight,
  existing framing adapter, role-specific prefix validation. Keep the one
  `CompactStaticWriter` physical assembler and all non-Variant byte behavior.
- Local worker owns the minimal production paths, W267 fixture/focused/
  adversary specs and only W264's obsolete Variant-refusal assertion. Oracle
  worker owns `scripts/compact_part_writer_w267_helper.cr` and
  `scripts/probe_compact_part_writer_w267.rb`. Root owns docs/evidence and
  serial checks; source worker stays read-only. Production authorization
  was withheld until the existing-API focused spec produced behavioral RED.
- Native witness: `pk UInt64`,
  `payload Variant(Array(LowCardinality(String)), String, Tuple(LowCardinality(String), UInt64))`,
  `ctx Tuple(label LowCardinality(String), direct Variant(Array(UInt8), String, UInt64), lists Array(Variant(Array(UInt8), String, UInt64)))`.
  Eight rows in four two-row marks exercise mixed/uniform/NULL-only tags,
  binary Strings, changing LC keys, a wholly empty middle `ctx.lists` mark,
  three independent Variant sites and all inactive-arm callbacks. Mode
  prefixes are per site per real mark, not one whole-column prefix.
- DoD commands: focused `crystal spec spec/compact_part_writer_w267_spec.cr
  spec/compact_part_writer_w267_adversary_spec.cr`, exact disjoint affected
  writer/LC/Variant cohorts in DEBUG and actual `--release`, a `--release`
  build of the W267 helper, then `ruby scripts/probe_compact_part_writer_w267.rb
  --clickhouse PINNED_BINARY --crystal-helper PREBUILT_HELPER --evidence-root FRESH_ROOT`.
  Root records exact expanded paths/flags and wraps every heavy command with
  `run_safe.sh`, one worker/thread, 12 GiB tree limit and 50%-free guard.
  Expected signals: zero scoped spec failures, stock/candidate literal
  agreement for every admitted mode/mark cell, exact framing/slot/EOF audits,
  and selected rejection of the resealed copy-only middle-prefix mutant.
- Regression guards: fresh W265 static and W266 LC native probes, exact
  frozen W264 default-MRK3 file oracle, protected W263 SHA checks and preserved
  capture inventories. No broad staging, no push, no combined-suite claim.

### Observed W267 scope and qualification

`CompactVariantDiscriminatorMode` is the own-file mode owner. The appended
public argument defaults to COMPACT and is bound through the operation, write
plan, callback plan and encoded column; default mark format remains MRK3.
LC-only and Variant-only maps remain distinct. Stateful columns use existing
one-granule logical encoding, then the existing discriminator framing adapter;
all sites and marks are preflighted cumulatively on both byte and element axes
before adaptation charges. Stateless encoding, shared logical codecs, reader
grammar, Wide policy and the single physical assembler remain unchanged.

Final disjoint affected union: 32 writer/consumer paths / 202 examples,
11 LC paths / 108 and nine Variant paths / 59 in each serial DEBUG and actual
RELEASE run, zero failures/errors/pending. This is 52 paths / 369 examples per
mode, not combined-executable, full-suite or fresh-clone qualification. The
seven focused examples overlap that union. Production seal:
`67d46371841ac699a13ab8a46f591bc10b814bbfde9b3e8fb0fa0efc2d7608cd`
(594 files); source/test/script seal:
`1fabd0a3da3127cb0575b52021addbc2c211fbfe65908e988617a75425ba1eaa`
(1974 files), held across final tests and native regression checks.

Native evidence: `/private/tmp/crystal-click-w267-native.HpgrTG`, 69 bounded
invocations / 276 authenticated raw files. Separately INSERTed stock MRK4 in
both modes reads in Crystal; four generated mode/mark cells ATTACH, CHECK=1
and return independently literal full/middle/last/empty 8/4/2/0-row windows.
No stock-MRK3 capture is claimed. Independent root LZ4/mark/value audit finds
the same stock/generated decoded tape per mode: BASIC 673 bytes, COMPACT
689. All 140 MRK4 coordinates per part, including EOF, match stock output;
the 15 generated MRK3 coordinates select the three whole-column positions.
There are 28 callback slots: all column prefixes precede bodies, all inactive
arms participate, and an empty nested Variant mark retains its prefix but
emits no discriminator body. Stock/generated compressed frame counts differ;
neither compressed-byte parity nor performance follows from decoded equality.

Copy-only, checksum-resealed COMPACT middle-prefix mutation 1 -> 2 changes
only decoded byte 209. Native ATTACH/CHECK=1 still pass, but full/middle SELECT
raise code 117 / invalid SerializationVariant discriminator version. Native
last/empty values remain exact; the local unselected `pk` window stays 103/104.
Local full/middle and late payload reads reject: LC whole-grid preparation
also visits the poisoned prefix. Do not claim selected-only preparation or
granule-only I/O. Local adversaries additionally cover independent LC/Variant
roles, detached mode-bound plans, counterfeit callbacks, unknown modes,
empty/NULL/uniform marks and pre-adaptation cumulative budget refusal.

Fresh previous-layout regression roots:
`/private/tmp/crystal-click-w267-lc-native.jGITcE` (33 invocations / 132 raw
files; same 601-byte decoded tape, 55 MRK4 and 20 MRK3 coordinates) and
`/private/tmp/crystal-click-w267-static-native.BaaLJ4` (68 / 272; all nine
frozen W264 default-MRK3 files equal, 17902 bytes). Original 52 captures /
544 files / 756378 bytes and three user-owned W263 specs remain unchanged.
The protected specs are outside this commit; two remain local prerequisites
of the exact consumer cohort.

Source checkout and native build remain distinct pinned revisions. Root
executes serial checks and independently dereferences raw evidence; Luna's
source/candidate review is correlated, not independent verification. Tooling
and test-oracle defects were corrected before final qualification, without
weakening production/profile/resource guards. Exact commands, pins, results
and corrections: [W267 evidence](../.landmark/evidence/compact-part-writer-w267.json).
Next: context-owned Dynamic/JSON writer lifecycle, remaining combinations/
profiles and Compact MV/projections; optimization remains deferred. Refresh
dependent claims after relevant source/test/profile/compiler/runtime/capture
drift, evidence loss or scope widening. Rollback: revert W267 only; no push.

## Previous extension: Compact LowCardinality lifecycle — W266

Status: W266 VERIFIED / root adversary ROBUST within the finite LC/plain
MRK3/MRK4 witness and exact affected cohorts (2026-10-12).
Baseline: `1b113ed1c8c1c0a3cd458e1d0dbbab64ef079d44` (2026-10-12).
Risk: CAUTION (persistent recursive serialization and shared physical assembly).
Rollback: revert only W266-owned changes; preserve the three user-owned W263
specs, all original captures, and the already committed W265 byte oracle.
The full types/MV/projection/performance goal remains ACTIVE.

Source anchor: pinned upstream `ed30948f095ecb70679986d7d60e27ad770ae27a`,
`MergeTreeDataPartWriterCompact.cpp:180-205,210-229`. Each column/granule
constructs fresh serializer state and executes prefix/body/suffix; Compact sets
`low_cardinality_max_dictionary_size = 0` and specialized prefix/suffix streams.
The ordinary PartGlobalDictionary policy stages a whole-grid dictionary and
reuses UPDATE state. AdditionalKeysOnly also stages a whole-grid key union,
but writes UPDATE on every nonempty record. Neither whole-grid call is the
source-owned Compact per-granule contract; calling the existing additional-key
encoder with one granule preserves its semantics while resetting the key set.

Delta: admit recursively located LowCardinality sites under the
existing ordinary declaration/carrier gates, with source-owned per-granule
prefix and self-contained additional-key body records. Reuse logical codec
semantics and one physical assembler, not parallel writer implementations.
Retain every empty callback, exact MRK4 prefix/body names, actual slot counts,
MRK3 whole-column positions, cumulative budgets and staged publication checks.
Do not change ordinary Wide dictionary policy or silently widen Variant,
Dynamic/JSON, arbitrary profiles, compressed marks, table metadata or Compact
MV/projection composition. Those remain separate unqualified boundaries.

Falsifiers and execution order (retained as the slice's qualification contract):

1. Run `spec/compact_part_writer_w266_spec.cr` against the current writer:
   its owned multi-granule LC positive must fail on the existing rejection,
   not on a compiler or fixture defect. Test-only preparation precedes code.
2. Independently INSERT a stock native Compact part with root LC String,
   nullable LC keys and a recursive Array LC site whose complete middle child
   granule is empty. Inspect real prefix/body names, flags, coordinates and
   literal full/middle/last/empty values; source shape alone is not qualification.
3. Bind the callback lifecycle explicitly and encode each LC-containing
   granule with a fresh logical additional-keys operation. Preserve the old
   stateless path/default MRK3 bytes and original refusal/profile boundaries.
4. Require native ATTACH/CHECK and literal SELECT of both generated mark
   formats, plus stock-to-Crystal reads. A copy-only poisoned middle prefix or
   dictionary/index association must be detected by the selected reader.
5. Run focused and exact affected DEBUG/actual-RELEASE cohorts and old static
   native/byte-oracle guards serially, with one worker/thread, 12 GiB
   process-tree and 50%-free limits unchanged. Partitioned optimized runs do
   not establish combined-RELEASE or full-suite qualification.

Candidate implementation ownership after the owned LC RED: backend Luna owns
`compact_static_callback_plan.cr`, `compact_static_writer.cr` and new own-file
`CompactBinaryBulkCallback` / `CompactEncodedColumn` owners. Root owns their
requires, this frontier, verification and the atomic commit. Test Luna owns
the new W266 fixture/spec and the narrow old W264 LC-refusal expectation;
native-tooling Luna owns only the new W266 helper/probe. No worker executes
compilers, tests or native commands, and no shared LC/String codec is changed.

Keep the body's logical-role roster separate from ordered physical callback
events: an LC prefix and dictionary body bind the same dictionary role, but
are distinct MRK4 slots. For an LC-containing column, use the same operation
budget for one-granule AdditionalKeysOnly calls; emit each eight-byte prefix
once and preserve its empty dictionary-body callback. For stateless columns,
retain the existing whole-grid encoding and bytes. One physical assembler
consumes both event schedules. The normalizer remains bounded to the existing
self-contained Compact additional-key grammar; do not add part-global replay
semantics to mimic the Wide writer.

The native capture can run alongside candidate construction once the owned
RED is observed; any contradictory stock lifecycle witness reopens the
candidate before publication. Native acceptance remains mandatory for closure.

### Observed W266 scope and qualification

`CompactBinaryBulkCallback` owns each prefix/body event separately from its
logical role. `CompactEncodedColumn` binds one-granule AdditionalKeysOnly
operations to a common cumulative budget for LC-containing columns, retaining
the original whole-grid path for stateless columns. The existing single
physical assembler consumes both schedules; no shared LC or String codec,
Wide dictionary policy, publication primitive or reader grammar changed.
Each LC site emits its eight-byte version prefix on every parent granule,
including an empty child granule, and retains the zero-byte dictionary body
as a distinct MRK4 slot. Default MRK3 remains unchanged.

Final serial DEBUG and actual RELEASE each pass two disjoint executables:
32 writer/consumer paths / 202 examples and 11 LC/reader/adversary paths / 108,
all zero failures/errors/pending. Production and source/test/script seals are
held across the final runs. This is a 43-path union, not combined-executable,
full-suite, all-type or fresh-clone qualification. The unchanged single-worker/
thread, 12 GiB process-tree and 50%-free guards remain in force. Exact commands,
revisions and scope: [W266 evidence](../.landmark/evidence/compact-part-writer-w266.json).

The independent native fixture has eight rows, four real marks, root
`LowCardinality(String)`, `LowCardinality(Nullable(String))` and
`Array(LowCardinality(Nullable(String)))`; the complete middle Array child
granule is empty. The final probe retains 33 bounded invocations / 132
authenticated raw files in `/private/tmp/crystal-click-w266-full.mK58ZB`.
Stock-to-Crystal reads and generated MRK3/MRK4 native ATTACH, exact schema/
active Compact eight-row/five-mark census, CHECK=1 and literal full/middle/
last/empty values pass (8/4/2/0 rows).

Root independently decodes LZ4 and headerless marks, checks LC key/index
associations, Array UInt64 deltas, repeated prefix/empty callbacks and every
EOF pair. Stock and generated parts share the exact 601-byte decoded tape;
all 55 MRK4 logical coordinates and 20 whole-column MRK3 coordinates agree.
Stock/generated compression frames differ (16/20), not a physical-byte or
speed claim. Local adversaries cover two LC sites inside a named Tuple,
all-empty Array children, raw/NUL/empty/NULL Strings and repeated-prefix budgets
(141-byte success / 140-byte refusal).

A copy-only middle root prefix version 1 -> 2 changes exactly decoded byte
173; frame extents/marks stay fixed and checksums are resealed. Local selected
reading raises `UnsupportedFormatError`; unselected `pk` retains 103/104.
Native ATTACH and CHECK=1 succeed, full/middle SELECT fail with code 117
(`INCORRECT_DATA`, invalid LC version), and last/empty stay exact. CHECK alone
does not prove serializer-state semantics. The original part stays unchanged.

The fresh static W265 regression probe adds 68 bounded invocations / 272
authenticated raw files in `/private/tmp/crystal-click-w266-static-native.lEPMj3`.
Prior native values/guards and all 85 static logical positions remain intact;
default MRK3 matches all nine frozen W264 files exactly (17902 bytes).
The first full W266 run stopped on a Ruby inventory string/symbol key mismatch,
after positive native reads; correcting only that probe and rerunning in a
fresh root closes the tooling failure, not a native format RED.

Remaining: Variant/Dynamic/JSON Compact writer lifecycle and context-owned
layouts, further recursive/key/profile qualification, compressed marks and
Compact MV/projection composition. The current reader still replays whole-grid
lifecycle preparation for LC windows; no granule-only-I/O, single-prepare,
large-part, RSS or performance claim. Prior bounded reader/Wide/metadata work
remains separately qualified. The full goal stays ACTIVE; no push. Refresh
after source/test/profile/capture/compiler/consumer drift, evidence loss or
scope widening; revert only the W266 commit for rollback.

## Previous extension: static plain MRK4 — W265

This checkpoint describes W265's own qualification revision. Its LC exclusion
is superseded only within W266's bounded scope above.

Status: W265 VERIFIED / root adversary ROBUST within the finite static/plain
MRK3/MRK4 witness, declared publication/budget guards and exact affected cohort
(2026-10-12).
Baseline: `ba6fbf46b5344e48d7cb5896a9cb4e3d893d35dd`.
Risk: CAUTION (persistent layout, shared backend and staged validation).
Rollback: revert only W265-owned changes; preserve protected W263 specs and
all original capture inventories. The full types/MV/projection/performance
goal remains ACTIVE; a static MRK4 slice does not replace its completion gate.

Extension: append `mark_format: CompactMarkFormat::Mrk3` to the
existing public writer API and admit `Mrk4` explicitly. Keep MRK3 as the
backward-compatible default. Reuse stateless recursive codecs, single LZ4,
String-v0/BASIC Map, sorted UInt64 key and complete-part publication. Do not
widen stateful, serializer-profile, compressed-mark or table-metadata gates.

Design laws:

- Plain MRK4 has no binary header. Each adaptive record has `16 * S + 8`
  bytes, where `S` is the checked total substream count, not the column count.
  Preserve every zero-byte callback slot, followed by the parent row count.
  All terminal pairs name `(data.bin size, 0)` and terminal rows are zero.
- `columns_substreams.txt` uses the source-owned version-1 text envelope,
  schema column order, and each column's exact physical callback order/names.
  Its roster and byte limits are checked before staging. It belongs to the
  exact persisted file census but not to `checksums.txt`: native treats this
  sidecar as metadata without a checksum. Staged validation compares its exact
  bytes with the immutable planned roster before publication.
- One format-neutral physical assembler owns tape, compression positions and
  fold. MRK3 queries the first callback per column; MRK4 queries every
  callback. Do not duplicate logical serde or infer order from lexical roles.
- Staged context and every value-reader grid preflight use the actual `S`.
  Check selected mark format, complete roster, parent rows, metadata,
  checksums and values before the unchanged exclusive publication operation.
  Preserve cumulative budgets and full physical-workspace preflight.

Source anchor: upstream `ed30948f095ecb70679986d7d60e27ad770ae27a`,
`ColumnsSubstreams.cpp:207-225` and
`MergeTreeDataPartWriterCompact.cpp:306-397,424-440`. The metadata exception is
`IMergeTreeDataPart.cpp:1872-1886` and `checkDataPart.cpp:349`.
The pinned native runtime
is distinct from this source revision; no latest/all-version claim is made.

Falsifiers and intended DoD:

1. Run an owned missing-MRK4 API/format test before production changes. This
   compiler/API RED is not physical interoperability evidence.
2. Qualify the existing recursive eight-column witness at 17 substream slots,
   including empty Array children, long/raw Strings, UInt64 edge values and
   NULL/ragged associations. Independently compare callback roster, complete
   marks/EOF, decoded tape and saved fold to native INSERT output, then native
   ATTACH/CHECK and exact full/middle/last/empty reads.
3. A resealed wrong non-first substream coordinate, or an altered unchecked
   roster with unchanged checksums, must be detected by
   structural/value validation, even if native checksum-only CHECK passes.
   Retain native ATTACH, CHECK and SELECT observations separately.
4. Exercise a mark-byte cap that permits the old eight-slot MRK3 grid but
   rejects the 17-slot MRK4 grid, cumulative readback workspace exhaustion,
   default-MRK3 bytes/refusals, destination collision and owned-stage cleanup.
5. Run exact changed-file formatter checks, focused and affected-consumer
   DEBUG/actual-RELEASE tests, and fresh native MRK4 plus default-MRK3 tooling
   regression probes. Root owns serial commands under the unchanged one-thread,
   12 GiB process-tree/50%-free guards. Do not raise guards or promote a
   partitioned compiler run to combined-executable qualification.

Implementation ownership: backend Luna owns format-neutral static assembly
and callback-plan/output carriers; publication Luna owns public format selection,
metadata and staged/readback validation; test Luna owns new W265 specs and
bounded native tooling. Root owns requires, this frontier, exact consumer
cohorts, all execution, hostile review, evidence and the atomic local commit.
First implement only after the RED and review the strongest counterexample:
self-roundtrip with a valid checksum but a wrong child-slot association.

Observed native RED: the first complete MRK4 ATTACH succeeds, but CHECK returns
code 226 when the generated `checksums.txt` includes `columns_substreams.txt`.
The file exists on disk; it is missing only from the recomputed checksum map.
The independently INSERTed stock part omits that entry. This refutes the
initial sidecar-checksum design; do not weaken CHECK or infer format failure
from the earlier numeric-versus-string probe comparison.

### Observed W265 scope and qualification

The public entry point is `CompactPartWriter.write_uint64_columns`, with
`mark_format: CompactMarkFormat::Mrk3` as the appended backward-compatible
default and explicit `CompactMarkFormat::Mrk4`. It writes one nonempty part
with a sorted UInt64 key and stateless recursive value columns, one LZ4 stream,
String-v0/BASIC Map, a complete common grid, staged typed readback and exclusive
publication. MRK4 does not admit a new logical type or serializer profile.
LowCardinality/Variant/Dynamic/JSON writers, compressed marks, other profiles,
incremental append, arbitrary table metadata and Compact MV/projection
composition remain rejected or unqualified. The separate bounded reader
frontier and prior Wide/metadata MV/projection work are not erased by these
writer exclusions. Performance remains deferred.

Final exact 95-path DEBUG passes 628 examples (`061657`). Actual RELEASE passes
the same disjoint union in two executables: 32 writer/consumer paths / 202
examples (`4aca62`) and 63 reader paths / 426 (`1f1a18`), all zero failures/
errors/pending. Do not call this a combined-RELEASE or full-suite result; two
executables do not certify all cross-subset optimized/order interactions.
Final production and source/test/script seals match across these runs under
the unchanged single-worker/thread, 12 GiB process-tree and 50%-free guards.
The exact commands, paths, pins and residual scope are indexed in
[W265 evidence](../.landmark/evidence/compact-part-writer-w265.json).

The final fresh native probe (`cd5ab2`, exit 0) retains 68 bounded invocations
in `/private/tmp/crystal-click-w265-native.BXzRsT`. Root rechecks all 272 raw
argv/stdin/stdout/stderr files and the five source pins (`b6de56`), then checks
the raw positive/negative outcomes separately (`54fff4`, `372359`):

- Generated default MRK3 and explicit MRK4 both ATTACH, expose an active
  Compact part with eight rows/five marks, return exact CHECK=1 and literal
  full/middle/last/empty logical rows (8/4/1/0). Native `clickhouse-local`
  exercises the pinned MergeTree storage paths; this is not a deployed-server
  or all-version claim.
- The separately INSERTed stock MRK4 and both generated formats have the
  same 8970-byte decoded tape SHA-256 and saved/computed fold words. Root
  independently reconstructs the headerless five-record/17-slot/1400-byte
  MRK4 tape and all 85 logical positions (`057ae7`), including both empty
  child starts and complete EOF. The sidecar is byte-equal to stock.
  Compression frames differ (Crystal 282, stock 32); compressed-byte identity
  is not required or claimed.
- Root compares all nine generated default-MRK3 files (17902 bytes) with the
  authenticated frozen W264 output, exactly equal (`80be4c`). This finite
  backward-compatibility oracle is stronger than comparing default and explicit
  calls to the new backend, but does not certify every static declaration.
- A stale `data.bin` copy is rejected on the selected corrupted `pk` frame;
  unselected `gap` still reads. Native ATTACH succeeds, CHECK executes but
  returns flag 0/code 40, full/middle SELECT raise, and last/empty remain exact.
  Selected-frame authentication is not whole-file eager validation.
- Fold-only poison is accepted locally and by native CHECK/SELECT. Resealed
  non-first-child coordinates and a swapped unchecked sidecar are rejected
  locally, but native ATTACH/CHECK and all value windows still pass on this
  runtime. Preserve these measured sensitivity gaps: native CHECK alone does
  not prove fold, callback association or sidecar integrity, and these mutants
  are not evidence that native SELECT rejects them.

The publication cap initially failed in actual RELEASE (`f73a9b`). Repeating
the diagnostic binary reproduces the cause (`43122c`, attempt 9): a staging
path one byte longer adds exactly 26 retained bytes for the initial two path
owners and three path owners per each of eight readers. Crystal 1.21.0
`File.tempname` uses an unpadded base36 UInt32 suffix (1-7 bytes); the test-only
cap now allows the source-derived maximum six-byte difference times those
26 owners. The exact matched-cap eight-slot-pass/17-slot-fail discriminator
and all production limits stay unchanged. The final RELEASE publication
binary passes 32 repeated executions of its two examples (`f4afbf`), not
64 independently counted cases. The cumulative refusal additionally records
real earlier successful preflights, more than one opened reader, the actual
17-slot grid, and operation-owned cleanup. This is logical retained-budget
evidence, not a complete allocator/RSS guarantee.

Earlier native stops remain preserved: numeric-versus-string fold comparison
was an inconclusive tool error; including the sidecar in checksums produced
the source-confirmed code-226 RED; selecting uncorrupted `gap` for the stale
frame test was a wrong tool oracle, corrected to `pk` with an explicit
unselected-frame positive control. None is silently promoted to GREEN.

Root adversary verdict: ROBUST within this finite native witness, checked
callback association, MRK3 byte oracle, publication/budget guards and exact
cohort. Same-lineage Luna review is correlated; root actual source, raw native
records and independently authored stock values supply the discriminators.
All 52 original parts / 544 recorded files / 756378 bytes and the three
protected user-owned specs remain unchanged. The two protected specs included
in the exact cohort remain local reproduction prerequisites, not committed
fixtures. No arbitrary types/profiles, full writer parity, RSS, combined
RELEASE, full-suite or speed claim follows.

Next: per-granule stateful prefix/body/suffix ownership, then context-owned
Dynamic/JSON and remaining type/profile combinations, followed by Compact
MV/projection composition and measured optimization. Refresh qualification
after source/test/profile/capture/compiler/consumer drift or scope widening.

## Qualified static plain MRK3 — W264

Document status: W264 VERIFIED / root adversary ROBUST within the bounded
static/plain-MRK3 witness and exact affected-consumer cohort (2026-10-12).
Baseline: `b91dafb547ba77e0667e936cd86ec5ae3687bbb3`.
Risk: CAUTION (persistent file format and exclusive publication).
Rollback: exact W264-owned paths; preserve the three unrelated untracked W263
specs. No push, history rewrite, original capture mutation, or native-store
reuse is authorized by this slice.

## W264 revision-scoped boundary

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

## W264 revision-scoped continuation

After this physical MRK3 backend: MRK4, stateful leaf/recursive serializer
lifecycles, context-owned Dynamic/JSON, remaining type combinations,
MV/projections, then measured memory/performance work. The full active
objective is unchanged; this document is a current compatibility boundary,
not a substitute completion definition.
