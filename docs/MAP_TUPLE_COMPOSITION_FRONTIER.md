# Map of recursively named Tuple frontier (W108)

Status: VERIFIED within the bounded BASIC profile and executed certificate
below (October 1, 2026). Paired reader/writer and table/catalog consumers pass
focused, regression, split RELEASE, full DEBUG and independent stock gates.
This is not all-type parity, current-master executable parity, a peak-RSS
guarantee or closure of the larger MV/projection/performance objective.
Clean production predecessor:
`46079fe` (catalog owner extraction after W107 `5c291c8`).
The October 1 reference-source and catalog refactor commits remain preserved;
the W108 implementation does not roll them back.

## Target and resolved admission

Add paired reader/writer and typed-table/offline-catalog support for
`Map(K, Tuple(...))`, with recursively named nonempty Tuple values and the
same complete scalar/Nullable-scalar terminal surface as W106/W107. Existing
specialized Map declarations remain unchanged. This is a missing composition
toward the full all-type objective, not a replacement for that objective.

UInt64 and String keys are physical qualification anchors, not a user limit.
The admitted key surface uses the shared closed non-Nullable scalar descriptor
families. The 53 exact declarations in the census pass pinned executable
declaration checks and paired local writer/reader tests; independent physical
stock qualification for this Map composition covers String and UInt64 only.
Other key codecs and arbitrary parameter combinations are not thereby
stock-certified. Unsupported key/container families remain rejected.

Reference source is `/Users/sergey/SrcArchives/clickhouse-2026-10-01-depth1`
at `b762d6d7fe4b201147bdce1bd49b8fc87a8049d3`; runtime oracle remains
`26.7.1.1315`. The source snapshot is not a current-master binary certificate.
The predecessor exact-type dispatcher had no Map(Tuple) branch. Its qualified
stock refusals are recorded below; the current dispatcher delegates the new
branch to dedicated Map owners.

## Laws and rejected boundary

- A Map row is an ordered sequence of key/value entries, not a Crystal Hash.
  Preserve duplicate keys, empty/binary String keys, empty Maps, and NULL
  versus visible defaults inside Tuple values.
- Outer mark row counts describe table rows; key/value leaf streams describe
  flattened entries. String sizes/raw bytes add a separate byte cardinality.
  Zero-entry marks and whole all-empty parts must not bypass stream checks.
- Keep the persisted Map declaration and public Map identity exact. Internal
  reuse of Tuple codecs does not authorize presenting a Map as Array(Tuple)
  to metadata, schema, readback or public APIs.
- Parse Map, its key and its recursive value under one source/depth/node
  budget. Do not translate the source and reset parser counters per child.
- Reuse shared leaf descriptors, physical codecs, raw/mask comparison and
  explicit ragged schedules; no duplicated width table or per-key Cartesian
  union. New concrete owners each have their own file.
- Charge owned keys, masks, offsets, entries, Tuple storage and retained
  schedules together before owned payload materialization and writer staging.
  Parsing, structural preflight scratch and exported defensive snapshots are
  not a peak-allocation certificate. Logical charge is not RSS.
- Preserve exclusive staged publication, complete stage inventory, checksums,
  exact schema/descriptor identity and raw staged readback.

The qualified physical profile is true BASIC Map serialization on
Wide/LZ4/String-v1/plain adaptive marks, one sorted UInt64 table key and one
Map payload. Fresh `SerializationMap` also has WITH_BUCKETS paths with bucket
metadata and insertion-order indexes. Those require their own qualification
and order-restoration implementation toward the full compatibility objective;
they must not be flattened or implicitly accepted by this BASIC increment.
Other recursive containers, Nullable
keys/containers, unnamed/empty Tuple, Compact/Sparse, unknown serializer
metadata, general JSON and performance widening remain outside this slice.
Per-range outer/entry limits and mark-local semantic laziness are exercised
by the W108 tests; they are not inferred solely from W107's certificate.

## Before implementation

Risk: CAUTION (public schema, persisted serialization, two cardinality axes).
Rollback: one coherent W108-only local commit relative to `46079fe`. No push,
dependency update, fixture replacement or existing data mutation.

Root owns this SDD, require integration, serial guarded compiler/stock runs
and hostile verification. Reader/model and writer Luna agents initially own
read-only seam inventory; oracle Luna owns source/fixture inventory. Production
ownership is assigned only after the resolved contract and qualified RED.

First discriminators:

1. Source and pinned-executable census of supported scalar key declarations.
2. Stock-created UInt64/String-key Map(Tuple) parts with nested repeated labels,
   hidden Nullable raw carriers, duplicate keys and zero-entry marks.
3. Exact schema, literal streams, decoded bytes, actual mark tuples,
   serializer metadata, source CHECK and fresh ATTACH/CHECK, independent
   full/PK-selected RowBinary, and a seeded expected-byte defect.
4. Only then, predecessor typed admission/read refusal. A compile, oracle,
   runner or expectation failure is not feature RED.

Resumed October 1 after the catalog extraction: reader/model and writer
agents own read-only seam inventories until the physical contract is resolved.
Oracle Luna owns only `scripts/probe_map_tuple_w108_red.{cr,sh}` and source
investigation. Root owns this SDD, `spec/wide_map_tuple_w108_admission_spec.cr`,
require integration and
all serial heavy gates. Do not add production admission before a qualified
stock fixture and predecessor refusal exist. A name census is not a storage
qualification; dictionary/container keys outside shared scalar leaf storage
remain a later composition obligation even if stock permits their declarations.

## Observed predecessor admission and proposed reuse

On unchanged production source `46079fe`, the focused admission spec ran
through the guarded runner (600 seconds, 8 GiB) with
`crystal spec --single-module --link-flags=-fuse-ld=ld
spec/wide_map_tuple_w108_admission_spec.cr`: three examples, two expected
predicate failures, zero errors/pending, exit 1. String and UInt64 Map keys
both return false from `WidePart.supports_typed_type?`; existing scalar Map,
Array(Tuple) and rejected-container controls pass. The candidate value schema
is `Tuple(left Tuple(code UInt64, note Nullable(String)), right Tuple(code
DateTime64(9, 'America/New_York'), state Nullable(Enum8('negative' = -7,
'positive' = 4))))`. This is an admission-only observation, not qualified
physical-format RED on its own.

The guarded stock probe subsequently qualified the String-key BASIC profile
on unchanged production source. Both Map settings explicitly report `basic`;
the 53 exact Memory key declarations pass and Nullable key admission fails.
Mixed input has nine outer rows and six ordered entries, with row sizes
`[0,0,3,0,0,0,2,1,0]`, outer mark rows `[2,2,2,2,1,0]` and entry counts
`[0,3,0,3,0]`. A separate five-row all-empty part also qualifies. Each source
and fresh ATTACH part passes exact schema, file inventory, checksums, ten
payload streams, independently derived raw bytes/mark tuples/plain PK index,
stock CHECK TABLE and full/PK-selected RowBinary. Seeded wrong-byte comparators
reject defects in the PK and mixed Enum stream. Hidden NULL Enum8 carriers
are observed as zero; mixed raw bytes are `[0,249,4,0,4,249]`.

Observed `serialization.json` has exactly version 1, propagated nested
versions, `{"string":1}`, and one PK Default record with zero defaults and
nine/five rows. There is no Map statistics record. `compress_primary_key=0`
produces `primary.idx`, not `primary.cidx`; the original incorrect inventory
prediction and an iterator-to-Array compiler error were instrument defects,
not feature RED. After all controls passed, the predecessor refused the
qualified Map with `UnsupportedFormatError("unsupported exact typed column")`;
the probe exited 1 as intended. This qualifies String storage only, not all
53 key codecs.

The next guarded execution completed all four profiles: String and UInt64
keys, mixed and all-empty, each with source and fresh ATTACH controls. UInt64
has nine payload streams (no String-key size stream), with duplicate zero and
maximum keys preserved. Its envelope, PK-only statistics and outer/entry mark
axes match the independently predicted BASIC profile. All four exact typed
refusals occur only after every stock control passes; final exit 1 is qualified
feature RED. Command: `bash scripts/probe_map_tuple_w108_red.sh` under the
600-second/8-GiB guarded runner, production source still `46079fe`, oracle
`26.7.1.1315`, Crystal `1.21.0`. This resolves the physical-anchor obligation
for implementation; it does not qualify every parameter or key codec.

Source key gate: `DataTypeMap.cpp:152-155` rejects Nullable or
LowCardinality-Nullable keys, not merely all types other than String/UInt64.
The 53 exact bare declarations in the W105 admission matrix are the current
scalar-descriptor census candidates. A Memory declaration census would prove
admission only, not physical read/write coverage of those families or arbitrary
parameter combinations.

Resolved ownership after physical qualification:

- `WideMapTupleTypePlan`: actual Map declaration, one-budget key/value parse,
  nonnullable scalar key descriptor, recursive value plan, physical path and
  combined allocation-charge authority.
- `WideMapTupleSchedule`, `WideMapTupleColumnData`, `WideMapTupleRow`: separate
  outer/entry axes, exact row-size vector, retained key leaf and value Tuple
  buffers, ordered entry views. Key storage reuses `WideTupleLeafColumn`, not
  a per-key Cartesian union or Hash.
- Map-specific reader, table adapter and offline materializer, sharing existing
  scalar/Nullable decoding without exposing Array(Tuple) as Map identity.
- A shared internal `TupleLeafDecoder` owns the existing descriptor-to-codec
  switch for Tuple values and Map keys. Build the value Tuple plan only through
  a bounded complete-Map source factory, analogous to `for_array_type`; never
  expose a caller-built schema-root plan factory or reparse the value fragment.
  Retain the owned key leaf and returned value Tuple data once, rather than
  permanently retaining a combined Tuple payload and copied projections.
- `wide_part_writer/map_tuple_part_write_input.cr` and
  `map_tuple_part_writer.cr`: exact schema/cardinality preflight, snapshots,
  stage inventory/metadata/readback and exclusive publication.
- `TupleLeafStreamWriter.write_leaf`: proposed explicit-stream-name seam for
  keys and value leaves. Existing W106/W107 batch writing delegates to that
  one codec authority and retains regression tests. No duplicate width or
  physical-value comparison table is introduced.

The strongest writer falsifier is `[1,2]` becoming `[2,1]`: equal total entry
counts do not preserve row association. Staged readback must compare the exact
row-size vector, ordered key raws and every Tuple leaf raw/null mask before
publication. Reader preflight separately checks selected per-mark cardinality;
both assertions require the implementation and negative gates below before
being treated as qualified.

The public model retains one immutable key leaf named `keys` and one owned
value Tuple result. `WideMapTupleRow` exposes `size`, `key_at`, exact `key_as`,
`value_at`, indexed pairs and ordered `each`; its full type remains Map while
value row type remains Tuple. Raw String accounting includes keys and all
value payload, including Nullable-hidden bytes. The plan's one checked charge
accepts outer rows, entries, key String bytes, value String bytes and retained
schedule charge together. Full/charge-preview APIs use that same authority;
lazy iteration charges the selected schedule plus the current mark. Selected
physical boundaries fail before the first callback; semantic validation stays
mark-local. Table-owned row containers add their own aggregate charge.

Reader Luna owns parser/model/reader/table/offline adapters and reader specs.
Writer Luna owns writer facade, Map input/writer owners, the shared explicit
leaf-stream seam and writer specs. Oracle Luna owns only independent GREEN
stock probes. Root owns aggregate requires, this frontier, integration and
serial heavy execution. No agent runs concurrent compiler/ClickHouse jobs,
changes Git history, or edits another owner's files.

Planned probe paths are `scripts/probe_map_tuple_w108_red.{cr,sh}` and
`spec/wide_map_tuple_w108_admission_spec.cr`; GREEN paths and concrete owner
APIs must follow the resolved physical/model contract. Root runs heavy gates
serially through `cogni-ml/scripts/run_safe.sh`, 600 seconds, 8 GiB (32 GiB
full DEBUG), 50% free memory, isolated cache and single-module system linking.

Implementation DoD must include the qualified RED turning GREEN, every
admitted key/leaf family in a local ragged matrix, independent bidirectional
stock witnesses, typed full/window/lazy/catalog consumers, corruption and
pre-stage failures, W107/W106/W105 regressions, focused DEBUG/RELEASE, full
DEBUG, format/shell/staged-diff hygiene and scoped root adversarial review.

Strongest falsifier: equal aggregate entry counts with a shifted later key or
value leaf boundary silently associates a valid key with the wrong Tuple or
outer row. Fail before callbacks for selected structural corruption; state
explicitly whether semantic null/value checks remain mark-local.

## Qualified zero-PK boundary correction

The first guarded GREEN reader phase passed all four original physical
anchors, including table/catalog consumers (exit 0, October 1). Root then
found a paired boundary mismatch: the writer accepts an external UInt64 PK
equal to zero and emits its actual positive `num_defaults`, while the reused
Map metadata validator admits only zero defaults. A UInt64 table key is not
restricted to nonzero values by this slice. A fifth independent stock fixture
with one zero PK qualified source and fresh ATTACH files, actual PK statistics
(`num_defaults: 1`), bytes/marks and CHECK/RowBinary, then produced the typed
refusal on unchanged production (guarded reader phase, exit 1, October 1).
The four original profiles remained GREEN in the same run. The local writer
regression also produced the same staged refusal (nine examples, one error,
exit 1). The narrow correction admits Default PK counts in `0..num_rows`
for Map(Tuple) only;
negative/excess counts, wrong row counts and extra serializer fields stay
rejected. After the correction, focused DEBUG passed 25 examples, including
the duplicate-zero writer's exact emitted statistics and row association.
The two fresh-store stock GREEN phases then passed all five profiles each,
including source/fresh ATTACH CHECK and independent RowBinary/bytes/marks,
full/selected/nonzero-origin/lazy reads and table/catalog consumers (exit 0).
This is not WITH_BUCKETS admission.

## Executed certificate (October 1, 2026)

Root independently ran all compiler and ClickHouse workloads serially on the
W108 source relative to `46079fe`, using Crystal `1.21.0` and the pinned
ClickHouse `26.7.1.1315` executable. Source comparison used the separate clean,
one-commit shallow checkout `b762d6d7fe4b201147bdce1bd49b8fc87a8049d3`;
that source is not the executable used for physical qualification.

The guarded runner is
`/Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh` with
`COGNI_RUN_SAFE_MIN_FREE_PCT=50`, `RUN_SAFE_PASSTHROUGH_STDIO=1`, the isolated
`/private/tmp/crystal-click-w108-cache`, and
`SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`.
Compiler commands use `--single-module --link-flags=-fuse-ld=ld`.
Focused/regression and stock commands use 600 seconds / 8 GiB; full DEBUG
uses the same timeout / 32 GiB. These are workload bounds, not performance
measurements. The observed nonfatal duplicate `-lc` linker warning does not
change the test results.

Observed gates:

- Five W108 spec files, DEBUG: 25 examples, zero failures/errors/pending.
- The exact 22-file W105-W108 plus W101 budget regression set below, DEBUG:
  82 examples, zero failures/errors/pending.
- The same sorted set in two disjoint 11-file RELEASE invocations: 31 and
  51 examples, zero failures/errors/pending. This is 82 RELEASE examples,
  not a combined-module or full-suite RELEASE certificate.
- `crystal spec --single-module --link-flags=-fuse-ld=ld`: full DEBUG,
  1,776 examples, zero failures/errors/pending.
- `bash scripts/probe_map_tuple_w108_green.sh --green-reader` and
  `--green-writer`: five profiles each, separate fresh stores, exit 0.
- Both reader/writer modes of `probe_array_tuple_w107_green.sh`,
  `probe_nested_tuple_w106_green.sh` and `probe_nullable_tuple_w105_green.sh`:
  six predecessor stock gates, exit 0.
- `bash scripts/check_numeric_tuple_oracle.sh`,
  `check_bool_tuple_oracle.sh`, `check_identifier_tuple_oracle.sh`,
  `check_temporal_tuple_oracle.sh` and `check_parameterized_tuple_oracle.sh`:
  five affected leaf-family stock gates, exit 0. Observation-only Sparse
  controls in the temporal oracle do not admit Sparse decoding.
- `crystal tool format --check` on affected Crystal files, `bash -n` on the
  two W108 shell wrappers, and `git diff --check`: exit 0.

Exact sorted regression inputs (DEBUG uses all; RELEASE uses the first eleven
and last eleven separately, adding `--release` to the compiler command):

```text
spec/wide_array_tuple_w107_admission_spec.cr
spec/wide_array_tuple_w107_consumer_spec.cr
spec/wide_array_tuple_w107_leaf_matrix_spec.cr
spec/wide_array_tuple_w107_metadata_spec.cr
spec/wide_array_tuple_w107_model_spec.cr
spec/wide_array_tuple_w107_reader_spec.cr
spec/wide_map_tuple_w108_admission_spec.cr
spec/wide_map_tuple_w108_consumer_spec.cr
spec/wide_map_tuple_w108_model_spec.cr
spec/wide_map_tuple_w108_reader_spec.cr
spec/wide_part_reader_nested_tuple_w106_spec.cr
spec/wide_part_writer_array_tuple_w107_spec.cr
spec/wide_part_writer_map_tuple_w108_spec.cr
spec/wide_part_writer_nested_tuple_w106_spec.cr
spec/wide_part_writer_nullable_tuple_w105_spec.cr
spec/wide_tuple_nested_w106_admission_spec.cr
spec/wide_tuple_nested_w106_model_spec.cr
spec/wide_tuple_nullable_w105_admission_spec.cr
spec/wide_tuple_nullable_w105_consumers_spec.cr
spec/wide_tuple_nullable_w105_lazy_spec.cr
spec/wide_tuple_nullable_w105_model_spec.cr
spec/wide_tuple_parameterized_reader_budget_spec.cr
```

The five focused files are the four `wide_map_tuple_w108_*` inputs and
`wide_part_writer_map_tuple_w108_spec.cr` in that list. The two older private
TupleReader spec factories were adapted to wrap their unchanged seven
decoder callbacks in the shared `TupleLeafDecoder`; no public compatibility
shim or weakened assertion was added.

The stock profiles cover String/UInt64 keys with mixed and all-empty rows,
plus String keys with an external PK zero. Every source and fresh ATTACH
profile checks exact declaration, inventory/checksums, literal decoded bytes,
actual mark tuples, plain PK index, serializer envelope, actual
`CHECK TABLE` result equal to 1, and independently encoded full/selected
RowBinary. Seeded wrong-byte comparisons reject controls. Typed full,
selected, nonzero-origin and lazy reads, table scans/windows and offline
catalog `.values`/scans/windows are checked in both directions. The local
paired matrix separately covers all 53 bare keys and all 53 bare plus
Nullable value-leaf descriptors, including hidden hostile raw carriers;
it is not an independent stock certificate for those 53 Map key families.

The predecessor four-profile RED probe remains frozen, with SHA-256:

```text
58e035aad6280a435a218428face3e594a803569ea5c2718ae04f9dfb3ce484a  scripts/probe_map_tuple_w108_red.cr
28dfba5a519c1dcf967cec9fb73a860e5f61ef913747d0c4118a3f5a4d56c65d  scripts/probe_map_tuple_w108_red.sh
```

Root hostile verdict: ROBUST within this bounded profile, after executable
negative checks and source review, not from Luna agreement. The strongest
attacks exercised equal-entry row reassociation (`[1,2]` versus `[2,1]`),
later selected key/value-boundary corruption before callbacks, all-empty
stream validation, whole-source parser budgets, hidden Nullable bytes and
raw NaN-bit preservation, combined materialization charges before payload
ownership, invalid metadata, and staged cleanup/exclusive publication.
The independently qualified zero-PK defect was found and corrected before
closure. The writer also has an exact duplicate-zero metadata/association
witness; reader statistics validation bounds counts but does not recount
stock-sampled default statistics.

## Residual frontier and evidence decay

The writer is still an exact two-column Wide/LZ4 profile: one nondecreasing
UInt64 external PK and one Map payload. It is not an arbitrary-schema table
writer. Caller inputs/root must remain immutable during operations; concurrent
mutation, fsync durability and shared server-directory mutation are not
qualified. Selected structural validation can decompress frames; it is not
a no-payload-I/O guarantee. Semantic checks are mark-local, and retained lazy
row handles keep their decoded backing alive. Logical materialization charge
is not peak RSS or a throughput improvement.

WITH_BUCKETS order restoration, metadata version 2/missing columns or
`exact_num_defaults`, Compact/Sparse, arbitrary recursive containers,
broader JSON/Variant/Dynamic/custom-domain and aggregate-state coverage,
general MV/projection semantics, facade decomposition and the eventual <=10%
performance objective remain unfinished. Existing specialized container and
MV/projection capabilities are not erased by these narrower exclusions.
No further feature or remote push is authorized by this certificate.

Evidence decays on source, binary, physical profile, parser, schedule,
codec ownership, consumer charging or publication changes. Rerun the affected
source/stock/negative checks before relying on the certificate in a new
context; this document is a curated evidence index, not proof by itself.
