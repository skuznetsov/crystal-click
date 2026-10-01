# Compositional Array of named Tuple frontier (W107)

Status: VERIFIED within the bounded profile and executed certificate below.
The clean rollback predecessor is
`63e03b4038258254d64222c37fe97d815cbc3bde` (W106). This is not full recursive
type compatibility or a current-master executable certificate.

## Target and rejected boundary

Extend the three hardcoded W51/W55 Array(Tuple) declarations to one outer
`Array` containing any nonempty recursively named Tuple admitted by W106,
with the same complete scalar/Nullable-scalar leaf surface as W105. Reader
and writer must share admission, schema, paths and row/element cardinality.
This is a necessary compositional edge toward type parity, not the full
recursive-container or ClickHouse compatibility objective.

Preserve existing W51/W55 public return types, declarations and stock gates.
The new generic API exposes columnar leaf buffers and array-row handles, not
a Cartesian set of per-family Crystal Tuple unions. Each array row indexes
owned `WideTupleRow` elements, retaining nominal descriptors, nested scopes,
raw hidden carriers and NULL-first logical access.
The new plan and direct generic range/writer APIs also accept those three
legacy declarations; ordinary typed dispatch must still select their existing
specialized APIs first. A generic writer-admitted declaration cannot be
rejected by its staged generic reader solely because a legacy route exists.

The new paired profile remains Wide/LZ4/String-v1/plain adaptive marks, with
one sorted UInt64 key and one Array(Tuple) payload. Unsupported outer and
inner Array/Map/LowCardinality/Variant/Dynamic/JSON composition, unnamed/empty
Tuple, Nullable containers, double Nullable, Compact/Sparse and unknown
serialization metadata remain rejected. Existing unrelated profiles are not
widened or removed. Performance optimization remains deferred.

## Source anchors and laws to qualify

Reference source is `/Users/sergey/SrcArchives/clickhouse-2026-09-29-depth1`,
revision `a9581941254d6113f3740a8ec125ee7519cb1bda`; runtime oracle is stock
`26.7.1.1315`. Source inspection and pinned executable evidence are separate.

`SerializationArray.cpp:255-294` enumerates outer sizes followed by nested
element streams. Lines 352-394 map an outer row interval to the flattened
element interval, including the zero-element case. `DataTypeArray` does not
override `createSerializationInfo`; `IDataType.cpp:383-386` supplies generic
SerializationInfo. Do not transplant the top-level Tuple's recursive
subcolumns metadata into an Array column without physical qualification.

`ISerialization.h:460` defaults `SerializeBinaryBulkSettings` to position-
independent encoding; `MergeTreeDataPartWriterWide.cpp:560-578` retains that
default. `SerializationArray.cpp:329-348` therefore writes per-row lengths
to physical `.size0`, not the cumulative offsets retained by `ColumnArray`.
Expected leaf consumption at an outer boundary uses the preceding logical
offset (zero at the initial boundary). Confusing either representation is an
oracle defect, not a feature RED.

Two axes are load-bearing: mark row counts describe outer table rows, while
Tuple leaves and null/String-size streams carry flattened elements. `.size0`
sizes must sum to the exact selected leaf cardinality; shared stream marks
must preserve the outer schedule even when a mark has zero elements. String
raw byte cardinality is a third axis. A passing schema parser is not proof of
alignment, serializer admission or frame-boundary correctness.

Use one aggregate source/depth/node parser budget including the outer Array;
do not reset a new parser at its child. Keep W106's schema/path authority and
existing scalar codecs, rather than introducing a second family decoder or
writer-width map. New owners each get one file. Charge retained offsets,
outer handles and flattened Tuple storage under the existing logical 64 MiB
bound; do not claim an RSS ceiling.

## Resolved model and ownership

The source inventory at W106 identifies a reusable `WidePart::TupleReader`
Proc seam, but its existing callbacks equate physical rows and logical leaf
slots. W107 supplies an explicit selected-range schedule: physical marks
are checked against outer rows; decoder byte counts and the inner Tuple
reader's logical rows use the sum of `.size0` elements. Empty element ranges
remain legal, without bypassing any planned child mark check.

Full reads retain bounded selected outer offsets. Lazy iteration instead
reads `.size0` mark-at-a-time, retaining only checked per-mark counts/prefixes;
the sum across individually bounded marks is not subject to the full-read
65,536-row/element cap. Structural fixed-width and String size/raw boundaries
are checked per selected mark before the first callback, including a shifted
later boundary with unchanged aggregate counts. Actual null-byte/value
semantics remain mark-local. Existing boundary validators can decompress
selected raw frames during this guard, so this is a retained-memory/semantic
laziness contract, not a guarantee of no selected-wide payload I/O.
The temporary schedule charge is bounded separately and included while it is
retained; result charges include outer storage and inner Tuple storage through
one combined charge callback, rather than two independent 64 MiB allowances.

The shared plan is `WideArrayTupleTypePlan`, retaining one authoritative
`WideTupleTypePlan` and adding only the outer `.size0` stream. Parsing must
include the Array syntax node and start the Tuple at depth two within the same
parser instance/counters. Public owned results are
`WideArrayTupleColumnData#row_count/#element_count/#row(i)` and
`WideArrayTupleRow#size/#[](i)/#each`; element indexing returns the existing
`WideTupleRow`. Zero flat elements do not change the outer row count.
`read_array_tuple_mark_range` returns one `WideArrayTupleColumnData`;
`each_array_tuple_mark_range` yields one such result and its Int32 mark index.
Table batches expose `array_tuple_rows_for(column)`. `tuple_data` retains the
single owned flattened Tuple result; exported outer sizes/offsets are detached.

Writer entry point:

```crystal
write_uint64_array_tuple_part(destination, key_name, keys, value_name,
  type_name, row_sizes : Slice(UInt64), columns : Array(WideTupleLeafColumn),
  rows_per_mark)
```

The keys and owned outer sizes must have the same nonzero length, and the
checked size sum must equal every element-aligned leaf and null-map length.
All-empty outer rows are legal. Input fields use W106 flattened paths in
schema order. This writer uses whole-part staged readback, so both total outer
rows and total flattened elements are capped at 65,536 before staging, in
addition to the 64 MiB combined logical charge. Lazy reader selections across
more individually bounded marks are a separate capability. Every leaf mark
retains the outer-row count; its raw payload
spans the scheduled element interval. Reuse existing scalar leaf codecs,
not a second closed width/family dispatch. Array-root default counts describe
empty arrays, never the inner Tuple's per-element conjunction.

The writer's reusable seam is one shared Tuple leaf dispatch with an explicit
`TupleLeafMarkSchedule` of outer row counts and leaf start/count intervals.
W106 supplies a row-aligned schedule; W107 supplies a ragged schedule with
legal zero-element marks. Keep W107 preflight/publication in its own
`ArrayTuplePartWriter`: W106's whole preflight equates key/leaf cardinalities
and cannot be reused unchanged. The qualified stock RED resolves the persisted
Array JSON envelope for this profile: version 1, propagated nested versions,
String version 1 and only the PK statistics record. Sparse eligibility omits
the Array record entirely. Logical empty-array defaults do not authorize
inventing counters or recursive Tuple subcolumns in metadata.
The reader also retains the existing flat Array validator's `columns: []`
two-column admission policy, with the same mandatory physical streams and
exact one-UInt64-key/payload schema check. That inherited empty envelope is
not certified by W107's PK-record stock fixture; distinguish local admission
controls from the bidirectional stock certificate. Payload/recursive
statistics and unknown fields remain rejected.

Disjoint implementation ownership after the qualified RED:

- Reader/model Luna: shared parser/plan, new result and schedule owners;
  `wide_part.cr`, narrow owners under `wide_part/`, `wide_part_table.cr`,
  `offline_catalog.cr`, narrow consumer adapters and W107 reader/model tests.
- Writer Luna: `wide_part_writer.cr`, new concrete owners under
  `wide_part_writer/`, and W107 writer tests. Coordinate shared model API
  changes through root; do not edit reader/model files.
- Oracle Luna: W107 RED/GREEN `.cr`/`.sh` probes and admission spec only;
  independently encoded expected data, not reader/writer implementation.
- Root: `src/crystal_click.cr` require wiring, this SDD, existing frontier
  pointers, command/certificate recording and independent hostile checks.

New classes each occupy one file; the facades expose entry points/adapters
only. A broad stage-lifecycle/facade refactor stays separate from W107.
Regression anchors include `wide_part_reader_w51_spec.cr`,
`wide_part_reader_w55_spec.cr` and their unchanged stock oracles, plus W106,
W105 and W104. Catalog cell limits use flattened elements times inner leaf
count, not outer row count times leaves.

## Qualification and implementation order

Risk: CAUTION (public schema, ragged cardinality and persisted serialization).
Rollback is one coherent W107-only local commit relative to W106; no remote
push, dependency update, existing fixture replacement or performance widening.
Root owns the SDD, integration, require wiring, serial heavy gates and hostile
review. Luna owns disjoint reader/model, writer, and independent-oracle work.

1. Inventory live reader/writer/table/catalog consumers and reusable owner
   seams. Resolve the public model/API before production edits.
2. Add `scripts/probe_array_tuple_w107_red.{cr,sh}` and a target-admission
   spec. Qualify stock exact schema, literal stream inventory, raw bytes,
   actual mark offsets/row counts, actual serializer envelope, fresh
   ATTACH/CHECK and independently encoded full/PK-selected RowBinary.
   Include zero-element marks before, between and after populated marks,
   repeated disjoint nested labels, NULL/empty/default distinctions, and a
   seeded expected-byte defect. Only the final predecessor admission/read
   rejection is feature RED; compiler/oracle/runner failure is not RED.
3. After qualified RED, implement shared bounded plan and owned row model;
   reuse Tuple leaf orchestration through an explicit cardinality adapter.
   Validate selected outer schedules before the first lazy callback, then
   payload/cardinality/budget per materialized mark.
4. Implement paired immutable writer with full preflight before staging,
   ragged leaf/frame/mark schedules, stock-qualified Array metadata, raw/mask
   staged readback and exclusive publication. Empty-array defaults must not
   be confused with nonempty arrays of default Tuple elements.
5. Add table/catalog full/window/lazy consumers and independent bidirectional
   GREEN plus complete admitted scalar-family regression, including hidden
   raw Nullable payloads. Keep legacy Array(Tuple) routes unchanged.
6. Run focused DEBUG/RELEASE, W106/W105/W104 and relevant legacy stock gates,
   full DEBUG, format/syntax/diff hygiene and hostile review. Record exact
   commands, source lineage, scopes and observed signals before local commit.

Heavy gates use `/Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh`,
600 seconds, 8 GiB (32 GiB full DEBUG), 50% free-memory floor, isolated cache,
and Crystal single-module linking with `-fuse-ld=ld`. Root runs these serially.
Expected GREEN is exit 0, zero test failures/errors/pending, exact independent
stock physical/logical agreement in both directions, and intended-only diff.

Strongest falsifier: equal total element counts but a shifted per-mark child
boundary silently associates a valid Tuple with the wrong outer row. Attack
that case, zero-element repeated boundaries, all-empty parts, shared global
parser limits, owned offsets/masks, exact-budget thresholds, hidden Enum/Bool
carriers, wrong Array metadata, and rejection before callback/publication.

## Predecessor evidence (not feature GREEN)

At `63e03b4` with no tracked production diff, the guarded single-module
admission spec executed: 2 examples, 1 failure, 0 errors, 0 pending, exit 1.
The sole failure is the expected `supports_typed_type?(target)` false-versus-
true assertion; legacy controls and rejected container edges pass. This is
an admission RED, not a stock-format qualification or a feature certificate.
The subsequently corrected stock probe qualified source and fresh ATTACH:
exact declarations, 23 physical streams, independently encoded bytes, ragged
mark tuples, the observed serializer envelope, CHECK TABLE, and full and
PK-selected RowBinary all passed. Only then did the predecessor fail with
`UnsupportedFormatError: unsupported exact typed column`, producing the
expected exit 1 after about two seconds. The guard observed 75% free memory.
An earlier probe compile failure was an instrument defect, not feature RED.

Observed `serialization.json` has version 1, nested version propagation true,
String version 1 and one Default PK statistics record (9 rows, 0 defaults).
There is no Array payload record or recursive Tuple statistics subtree. The
qualified mixed fixture has 9 outer rows and 4 flattened elements; empty
marks precede, separate and follow populated marks. It does not certify a
whole all-empty part; that remains an explicit GREEN obligation.

```text
spec/wide_array_tuple_w107_admission_spec.cr
SHA256 984529519f516a465f8adf83cbe8d418ee585620d2a8355f965d603245a71aa4
tracked src SHA256 aggregate
91f20ed15031de42400c2d52109e66246b58b6f0ae4b0bd2eeda87df1d097e86
```

Command (cwd repository root):

```sh
env CLICKHOUSE=/Users/sergey/.local/bin/clickhouse \
  CLICKHOUSE_BIN=/Users/sergey/.local/bin/clickhouse \
  COGNI_RUN_SAFE_MIN_FREE_PCT=50 RUN_SAFE_PASSTHROUGH_STDIO=1 \
  SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  TMPDIR=/private/tmp CRYSTAL_CACHE_DIR=/private/tmp/crystal-click-w107-cache \
  PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin \
  bash /Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh \
  /opt/homebrew/bin/crystal 600 8192 spec --single-module \
  --link-flags='-fuse-ld=ld' spec/wide_array_tuple_w107_admission_spec.cr
```

The guard observed 74% free memory, above the 50% floor, and reported exit 1
after about 2 seconds. Root runs all compiler/stock gates serially.

The qualified stock command uses the same environment and guard above, with
the guarded workload replaced by:

```sh
/bin/bash 600 8192 scripts/probe_array_tuple_w107_red.sh
```

Qualified probe SHA256:

```text
scripts/probe_array_tuple_w107_red.cr
6e035aeb1d90ebd96e975923c8783f183e58460777a279f2136570b1d04d42ee
scripts/probe_array_tuple_w107_red.sh
9818e591a9720fac048c60b09af87168a6558d865be5d80cb3dc0efaec03c597
```

## Qualified integration falsifier

The 55-file focused DEBUG run executed 579 examples with 6 failures, 0
errors and 0 pending on production/oracle aggregate SHA256
`88ced42ffa8423f3140cf31ced6f9b8a5d9bf26f0aedfe6e77393e9e35b71829`.
The shared staged comparator accepted a forged Enum label/code map with
unchanged codes; the same test also requires rejection of changed Decimal
precision with unchanged coefficients. This invalidates the claim that raw
carrier equality alone preserves the prior nominal readback contract. Restore
descriptor-aware comparison in the shared owner without erasing hidden raw
Nullable carriers. Existing malicious-input assertions must remain intact.
Two prior family-specific diagnostics also changed. The other failures are
test expectations for intentionally widened global W51 admission, the shared
Tuple budget diagnostic, and the mandatory final zero mark sentinel.

Earlier stock GREEN runs do not close this integration regression. Refresh
the affected writer oracles after the comparator repair, then rerun focused
DEBUG/RELEASE and full DEBUG on one frozen production state. No commit is
authorized by partial GREEN.

The repaired shared comparator preserves nominal Enum map and Decimal
precision/scale identity, exact empty numeric carrier identity and prior
family-specific diagnostics; hidden Nullable carriers remain raw. The repaired
55-file DEBUG set passed 581 examples, zero failures/errors/pending. Its combined
RELEASE compilation was stopped by the unchanged 8 GiB process-tree guard at
8,396,416 KiB, before test execution. This is a compiler-resource stop, not a
feature falsifier or a RELEASE certificate. The subsequent discriminator
partitioned the same ordered 55 inputs into disjoint 24/24/7-file RELEASE
batches under the same guard, without removing a test or increasing the
resource allowance. All three batches passed, as recorded below.

## Executed certificate (2026-10-01)

The admitted W107 profile is verified against the pinned ClickHouse
`26.7.1.1315` executable, not against an executable built from current master.
All final affected gates used this frozen production/oracle aggregate:

```text
c46d8f1ff4655c82d234bca8185230f0e3bf6a53b39d830e557041b61f20f936
```

The aggregate is SHA256 of the sorted per-file SHA256 output for every
`.cr` and `.sh` file under `src` and `scripts`. Documentation-only edits
do not change it; the atomic W107 commit contains the final tests and docs.

The final staged whitespace check found one surplus blank line at EOF in
`scripts/probe_array_tuple_w107_red.sh`, which the unstaged check had not
inspected while that file was untracked. The only post-gate hashed-root edit
removes that blank line; the complete diff changes no shell statement.
`bash -n` passed afterward. Production and all GREEN oracles are unchanged.
The final aggregate is
`63b22d03aad6d2ab52789277fb831dfc87c49316387dc25486f8290f25463b57`; the RED shell file's final
SHA256 is `a83123b8a567d13ad4b3fc336b9225e6edf8a92d0465582ccf78d2a4ae8505dc`.
Runtime results in this certificate belong to the frozen aggregate, not a rerun after this
inert historical-RED-script whitespace edit.

| Executed gate | Observed signal |
| --- | --- |
| Focused DEBUG, the exact 55-file set below | 581 examples; zero failures, errors or pending; exit 0 |
| Focused RELEASE, disjoint 24/24/7-file batches | 434 + 128 + 19 = 581 examples; zero failures, errors or pending; all three exit 0 |
| Full DEBUG | 1,751 examples; zero failures, errors or pending; exit 0 |
| W105 reader and writer stock phases | Both exit 0; 53 Nullable leaf declarations and bare controls |
| W106 reader and writer stock phases | Both exit 0; 13 nested leaves and 22 physical streams |
| W107 reader and writer stock phases | Both exit 0; mixed and whole all-empty parts, 13 nested leaves and 23 streams |
| Parameterized, numeric, Bool, identifier and temporal Tuple stock scripts | All five exit 0 after the shared comparator repair |
| W104 timezone writer stock phase | 297 writer profiles, 14 table/catalog consumer controls and seven seeded shape checks; exit 0 |
| `examples/write_array_tuple_part.cr` | Three outer rows and three elements; NULL, empty array and empty String remain distinct; exit 0 |

The 55 RELEASE file inputs are an exact ordered partition of the DEBUG
inputs; no spec was dropped. This certifies those three RELEASE executions,
not a combined RELEASE process or a full RELEASE suite. The earlier combined
compile's resource stop remains recorded above. Full DEBUG emitted the
pre-existing duplicate `-lc` linker warning without a test failure.

The W107 stock probe independently qualifies schema, literal stream inventory,
decoded raw bytes, both cardinality axes in mark tuples, serializer metadata,
checksums, fresh stock ATTACH/CHECK and exact full/PK-selected RowBinary.
A seeded expected-byte defect is rejected. The all-empty part is a separate
executed witness, not an inference from one empty mark. The local ragged matrix
exercises all admitted bare and Nullable terminal families; it is not a stock
Cartesian certificate for every leaf parameter and every recursive topology.
The inherited `columns: []` envelope is checked by local controls; the stock
certificate uses the observed PK-only statistics envelope.

Before the nominal comparator repair, seven unaffected stock scripts (legacy
W51/W55, standalone DateTime/Nullable temporal, Array temporal, Array(Array)
temporal and QBit), plus the 297-profile W104 reader phase, passed on aggregate
`88ced42ffa8423f3140cf31ced6f9b8a5d9bf26f0aedfe6e77393e9e35b71829`.
Those are separate earlier certificates for unchanged paths, not reruns on the
final aggregate. All five affected Tuple family scripts and the W104 writer
phase were refreshed on the final aggregate; W105/W106/W107 were refreshed in
both directions.

Root's proportionate adversarial verdict is ROBUST within this declared
profile. Root inspected the shared comparator and both staged call sites,
checked independent stock evidence, and reviewed ownership, parser/global
budget, all-empty schedules, shifted-later-boundary rejection and before-stage
failure tests. The highest-risk nominal comparator falsifier was observed and
repaired before this verdict. Luna's same-lineage review is corroboration,
not independent proof.

Residual boundaries remain explicit: lazy structural schedules are guarded
before callbacks, but null/value semantics are mark-local; the 64 MiB charge
is logical retained storage, not an RSS ceiling; writer/full-reader outer and
flattened caps are 65,536. The older W106 Tuple staged validator's absence of
a complete directory-inventory check is pre-existing and outside this W107
artifact certificate, as recorded in `MODULARIZATION_FRONTIER.md`. No claim
covers arbitrary recursive containers, current-master metadata, Compact,
Sparse, general JSON, general MV/projection execution or performance parity.

Commands (cwd repository root; Bash array slicing is required):

```bash
w107_guard() {
  env CLICKHOUSE=/Users/sergey/.local/bin/clickhouse \
    CLICKHOUSE_BIN=/Users/sergey/.local/bin/clickhouse \
    COGNI_RUN_SAFE_MIN_FREE_PCT=50 RUN_SAFE_PASSTHROUGH_STDIO=1 \
    SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
    TMPDIR=/private/tmp CRYSTAL_CACHE_DIR=/private/tmp/crystal-click-w107-cache \
    PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin \
    bash /Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh "$@"
}
focused_specs=(
  spec/timezone_temporal_admission_w104_spec.cr
  spec/timezone_temporal_model_w104_spec.cr
  spec/timezone_temporal_writer_w104_spec.cr
  spec/timezone_temporal_consumers_w104_spec.cr
  spec/datetime_scan_spec.cr
  spec/nullable_temporal_scan_spec.cr
  spec/wide_part_writer_datetime_spec.cr
  spec/wide_part_writer_nullable_temporal_spec.cr
  spec/wide_tuple_temporal_model_spec.cr
  spec/wide_tuple_temporal_spec.cr
  spec/wide_part_writer_temporal_tuple_spec.cr
  spec/temporal_tuple_consumers_spec.cr
  spec/wide_part_reader_w40_spec.cr
  spec/wide_part_reader_w65_spec.cr
  spec/wide_part_reader_w66_spec.cr
  spec/wide_part_writer_w65_spec.cr
  spec/wide_part_writer_w66_spec.cr
  spec/wide_tuple_bool_model_w97_spec.cr
  spec/wide_tuple_bool_w97_spec.cr
  spec/wide_tuple_identifier_w99_spec.cr
  spec/wide_tuple_numeric_w96_spec.cr
  spec/wide_tuple_type_plan_spec.cr
  spec/wide_part_reader_compositional_tuple_spec.cr
  spec/wide_tuple_nullable_w105_admission_spec.cr
  spec/wide_tuple_nullable_w105_model_spec.cr
  spec/wide_part_writer_nullable_tuple_w105_spec.cr
  spec/wide_tuple_parameterized_w101_spec.cr
  spec/wide_part_writer_parameterized_tuple_spec.cr
  spec/wide_tuple_column_data_ownership_spec.cr
  spec/wide_tuple_parameterized_ownership_spec.cr
  spec/wide_tuple_parameterized_reader_budget_spec.cr
  spec/wide_tuple_parameterized_consumers_w101_spec.cr
  spec/wide_part_reader_tuple_metadata_spec.cr
  spec/wide_part_reader_tuple_empty_eof_spec.cr
  spec/wide_part_writer_numeric_tuple_w96_spec.cr
  spec/wide_part_writer_bool_tuple_w97_spec.cr
  spec/wide_part_writer_identifier_tuple_w99_spec.cr
  spec/wide_part_writer_bool_canonical_w98_spec.cr
  spec/wide_tuple_nullable_w105_consumers_spec.cr
  spec/wide_tuple_nullable_w105_lazy_spec.cr
  spec/offline_catalog_w95_tuple_values_spec.cr
  spec/wide_part_writer_compositional_tuple_spec.cr
  spec/wide_tuple_nested_w106_admission_spec.cr
  spec/wide_tuple_nested_w106_model_spec.cr
  spec/wide_part_writer_nested_tuple_w106_spec.cr
  spec/wide_part_reader_nested_tuple_w106_spec.cr
  spec/wide_part_reader_w51_spec.cr
  spec/wide_part_reader_w55_spec.cr
  spec/wide_array_tuple_w107_admission_spec.cr
  spec/wide_part_writer_array_tuple_w107_spec.cr
  spec/wide_array_tuple_w107_reader_spec.cr
  spec/wide_array_tuple_w107_consumer_spec.cr
  spec/wide_array_tuple_w107_metadata_spec.cr
  spec/wide_array_tuple_w107_leaf_matrix_spec.cr
  spec/wide_array_tuple_w107_model_spec.cr
)
w107_guard /opt/homebrew/bin/crystal 600 8192 spec --single-module \
  --link-flags='-fuse-ld=ld' "${focused_specs[@]}"
# Exact disjoint 24/24/7-file coverage; the combined RELEASE compile hit 8 GiB.
w107_guard /opt/homebrew/bin/crystal 600 8192 spec --single-module --release \
  --link-flags='-fuse-ld=ld' "${focused_specs[@]:0:24}"
w107_guard /opt/homebrew/bin/crystal 600 8192 spec --single-module --release \
  --link-flags='-fuse-ld=ld' "${focused_specs[@]:24:24}"
w107_guard /opt/homebrew/bin/crystal 600 8192 spec --single-module --release \
  --link-flags='-fuse-ld=ld' "${focused_specs[@]:48:7}"
w107_guard /opt/homebrew/bin/crystal 600 32768 spec --single-module \
  --link-flags='-fuse-ld=ld'
w107_guard /bin/bash 600 8192 -c '
  crystal() { /opt/homebrew/bin/crystal "$1" --single-module "${@:2}"; }
  export -f crystal
  for script in scripts/probe_nullable_tuple_w105_green.sh \
    scripts/probe_nested_tuple_w106_green.sh scripts/probe_array_tuple_w107_green.sh; do
    for mode in --green-reader --green-writer; do
      bash "$script" "$mode" || exit "$?"
    done
  done
'
w107_guard /bin/bash 600 8192 -c '
  crystal() { /opt/homebrew/bin/crystal "$1" --single-module "${@:2}"; }
  export -f crystal
  for script in scripts/check_parameterized_tuple_oracle.sh \
    scripts/check_numeric_tuple_oracle.sh scripts/check_bool_tuple_oracle.sh \
    scripts/check_identifier_tuple_oracle.sh scripts/check_temporal_tuple_oracle.sh; do
    bash "$script" || exit "$?"
  done
'
w107_guard /bin/bash 600 8192 -c '
  crystal() { /opt/homebrew/bin/crystal "$1" --single-module "${@:2}"; }
  export -f crystal
  bash scripts/check_timezone_temporal_oracle.sh --green-writer
'
```

The example was executed separately, serially, under the same guard:

```bash
w107_guard /bin/bash 600 8192 -c '
  example_root=$(mktemp -d /private/tmp/crystal-click-w107-example.XXXXXX)
  /opt/homebrew/bin/crystal run --single-module --link-flags="-fuse-ld=ld" \
    examples/write_array_tuple_part.cr -- "$example_root/part"
'
```

Format checking of all 40 changed Crystal files, shell syntax of both new
probe scripts, `git diff --check`, and a narrow credential-pattern check of
the 46 intended paths also passed. Generated stock parts and scratch caches
are not included in the commit.

## Continuation and decay

W107's paired bounded composition is closed by the executed certificate, not
by implementation existence alone. It introduces twelve concrete production
owners, each in one file; the wider stage-lifecycle/facade refactor remains
separate. The next proposed lifecycle and older Tuple artifact-inventory
hardening slices in `MODULARIZATION_FRONTIER.md` each require a discriminating
failure probe before production edits. Broader type admission likewise needs
its own source/stock qualification rather than inheriting this certificate.
Evidence decays if the source, binary, physical settings, parser/axis contract
or owner changes; rerun affected bidirectional oracles and broader gates.
Unknown physical profiles fail closed. Recursive container parity/general
JSON, MV/projection semantics, facade decomposition and the final <=10%
performance comparison all remain part of the larger active objective.
