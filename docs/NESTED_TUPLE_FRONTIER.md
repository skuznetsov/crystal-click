# Recursive named Tuple frontier (W106)

Status: VERIFIED within the bounded W106 profile on 2026-10-01. The clean
predecessor is `aa7d13a8748c1139383d0a6dfb49115858e46a73` (W105).
The executed certificate below qualifies paired recursive named Tuple parts,
not arbitrary recursive types or a newer ClickHouse binary.

## Boundary and discriminating evidence

The next compatibility gap is recursive composition, not another scalar carrier.
Target nonempty named `Tuple` nodes containing other nonempty named `Tuple`
nodes or any scalar/Nullable scalar leaf already admitted by W105. Reader and
writer must use the same schema plan and admit the same declarations.

Preserve the existing Wide/LZ4/String-v1, one UInt64 key plus one Tuple payload
profile. Do not widen unrelated Array(Tuple) profiles. Reject unnamed or empty
Tuples, Nullable containers, double Nullable, Array/Map/LowCardinality/Variant/
Dynamic/JSON children, Compact, Sparse, and unsupported metadata versions.
An empty Tuple is a separate physical profile in ClickHouse, not zero leaves
that can be silently admitted by flattening.

Reference source is the separate shallow checkout
`/Users/sergey/SrcArchives/clickhouse-2026-09-29-depth1`, revision
`a9581941254d6113f3740a8ec125ee7519cb1bda`. Runtime qualification remains
stock `26.7.1.1315`; the source date does not certify a newer runtime.
`SerializationTuple::enumerateStreams` delegates in child order, and the bulk
reader enforces the common row axis. `ISerialization` escapes each named Tuple
path component for file names. `SerializationInfoTuple` retains a recursive
child metadata tree. These source observations need physical runtime evidence.

Before production edits, the independent stock probe must establish one mixed
two-level nested declaration, exact schema, streams, raw bytes, mark records,
recursive Default metadata, fresh ATTACH/CHECK, and independently expected
full and PK-selected RowBinary. The current public reader must then reject
that qualified part. A compiler, runner, fixture or oracle failure is not RED.
The admission spec must separately show nested schemas rejected while W105
flat controls remain admitted.

## Accepted ownership direction

Keep `WideTupleField` a scalar descriptor with a nonoptional `leaf_type`.
Introduce one immutable schema-tree owner in its own file, with named scalar
and Tuple nodes; do not introduce Cartesian buffers or a recursive scalar
Value union. A shared plan retains exact nested canonical schema and a
declaration-order flattened scalar projection. Logical leaf paths use dots;
physical paths escape every Tuple boundary as `%2E`. Retain the path segments
in the plan and centralize physical naming in `leaf_stream_name`; do not let
codec callers reinterpret a joined path. Identifier-only names
make this representation unambiguous. Quoted/dotted names remain rejected.

Existing flat APIs and return types must remain unchanged. `plan.fields`,
ColumnData fields/columns, writer leaf input, and leaf `[]` use flattened scalar
paths; old flat names therefore retain their meaning. Expose a separate
schema-tree accessor rather than pretending scalar fields represent containers.
Add explicit scoped Tuple-row access for nested nodes, retaining the original
owned mark without copying its leaf buffers. Scalar access remains nominal and
NULL-first. A container cannot masquerade as a scalar leaf. Row `field_count`
continues to count flattened scalar cells, preserving the offline materializer's
cell guard; root arity is available through the schema tree.

The parser must enforce one aggregate source-size, depth and node budget across
the entire recursive declaration, including scalar parameters and Nullable
wrappers. Do not reset counters by invoking a new public parser for each child.
Every node is nonempty; duplicate names are rejected within a node, while the
same name in disjoint branches is legal. Reserve `null` at every Tuple level.
Materialization accounting includes the new retained tree descriptors once and
all leaf slots, masks, and String/FixedString bytes under the existing logical
64 MiB bound. This remains a logical result budget, not an RSS ceiling.

Accepted API seam: `plan.root_fields` exposes the ordered immediate logical
children. `WideTupleSchemaNode#leaf_field?` returns an optional local-name
scalar descriptor; Tuple nodes return nil. `plan.fields` exposes absolute
dot-separated terminal paths in declaration order. `row.tuple("details")`
and chained relative `tuple("metadata")` scope the existing `WideTupleRow`
handle to the same owned mark, with relative fields, subtree type and terminal
cell count. Root row counts and flat callers retain their old meaning. Leaf
input to the writer remains the same flattened column array, not recursive
Ruby/Crystal tuples or new Cartesian buffers.

The executed stock GREEN uses one representative multi-family nested schema with
repeated local `state`/`note`/`event` labels in disjoint left/right branches,
Nullable Enum8/Bool/String/Decimal, zoned DateTime64, FixedString and UInt
leaves. Fully-default rows and hidden masked writer carriers separate logical
defaults from physical storage. The unchanged W105 53-Nullable stock matrix
is flat regression evidence, not an all-family nested stock certificate.

## Accepted implementation plan and rollback

Risk: CAUTION (shared public schema, persistent serialization, ownership).
Rollback anchor: the clean W105 predecessor. Finish one atomic local feature
commit only after the runtime gates pass; no remote push is authorized.
Root owns this specification, integration, serial runtime verification and
final hostile review. Luna owns disjoint schema/reader, writer, and oracle work.
No concurrent heavy runtimes or unrelated process operations are authorized.
Root alone owns `src/crystal_click.cr` require wiring. Reader ownership is the
schema/model/parser/reader, its narrow facade delegation, and reader/model/
consumer specs. Writer ownership is the Tuple writer, statistics owner, and
writer specs. Oracle ownership is the independent admission and stock probes.

Consumer inventory: bounded `rg` found only TypePlan calling the production
`WideTupleSchemaParser.parse`; ownership/node-limit specs also inspect its
flattened return. Four production stream construction sites plus one staged
Bool readback site must use the common naming authority. Serializer validation
at `wide_part.cr` currently matches a flat child list to `plan.fields.size`.
Offline catalog's preflight counts `plan.fields.size`, and its Tuple materializer
compares `row.field_count`; both retain terminal-cell semantics.

1. Oracle files: `scripts/probe_nested_tuple_w106_red.{cr,sh}` and
   `spec/wide_tuple_nested_w106_admission_spec.cr`. Qualify stock topology and
   genuine baseline RED before admitting any recursive production schema.
2. Schema/model: `wide_tuple_schema_parser.cr`, `wide_tuple_type_plan.cr`,
   a dedicated schema-tree owner, `wide_tuple_column_data.cr` and
   `wide_tuple_row.cr`. Keep scalar codecs and physical buffers unchanged.
   Guard global parser bounds, ambiguous names, ownership, nested scoped
   access, nominal metadata, and exact-budget thresholds.
3. Reader: `wide_part/tuple_reader.cr`, `wide_part.cr`, and a dedicated
   recursive Tuple serialization-metadata validator. All selected stream
   schedules must agree before the first callback; masks and payload remain
   validated per materialized mark. Reject a flat child-metadata list that
   contradicts the nested declaration, extra keys, missing children, Sparse,
   malformed counters, and unsupported exact-counter metadata.
4. Writer: `wide_part_writer/tuple_part_writer.cr` and a dedicated recursive
   Tuple serialization-statistics owner if needed. Emit the same leaf streams,
   but recursive `subcolumns` records. Each Tuple default count is the rowwise
   conjunction of its direct children, recursively; Nullable defaults depend
   on masks, not hidden payload. Validate every raw hidden slot and exact
   schema before exclusive publication.
5. Public consumers and oracles: table, offline catalog, lazy/selected reads,
   reader-to-writer copies and stock writer ATTACH/CHECK/full/PK RowBinary.
   Seed a comparator/topology defect so a false positive is observable.
6. Focused DEBUG/RELEASE specs, unchanged W105 and older Tuple/temporal stock
   regressions, full DEBUG, formatting/syntax/diff checks, and hostile review.

Baseline command: guarded `crystal spec --single-module
--link-flags='-fuse-ld=ld' spec/wide_tuple_nested_w106_admission_spec.cr`.
The original boundary-control version passed one example with zero failures/
errors/pending: flat admitted, nested rejected. Migrate it to target admission
before the feature RED; its original passing result is not itself target RED.
The target admission version failed exactly at nested admission: one example,
one failure, zero errors/pending, exit 1. Flat Nullable/zoned controls remained
admitted and Nullable(Tuple) remained rejected. Production was still unchanged.
Stock baseline command: guarded `bash scripts/probe_nested_tuple_w106_red.sh`.
It returned the explicit qualified RED marker and exit 1 only after all stock
and freshly attached-copy checks passed: three Tuple levels, six terminal
fields, ten literal streams, raw hidden Nullable Enum slots, every mark record,
strict recursive metadata, schema, CHECK TABLE, independently constructed full
and PK-selected RowBinary, and a seeded comparator rejection. The public typed
reader then raised `UnsupportedFormatError` for the nested declaration.

Feature DoD: guarded `bash scripts/probe_nested_tuple_w106_green.sh`, reader
and writer stock qualification including independently computed writer frame
offsets, exact recursive counters and a row-correlation negative control;
guarded DEBUG and RELEASE `crystal spec --single-module
--link-flags='-fuse-ld=ld'` over the changed Tuple/parser/consumer specs and W105
scalar controls; unchanged Tuple/temporal/timezone stock regression scripts;
and guarded full DEBUG `crystal spec --single-module
--link-flags='-fuse-ld=ld'`. Exact focused paths and observed signals are
recorded in the final certificate below. No full RELEASE suite is promised.
Runtime gates use the established guarded single-module route,
600 s, 8 GiB (full suite 32 GiB), and 50% system free-memory floor. Expected
signals are exit 0, zero test failures/errors/pending, stock byte/mark/schema
and logical agreement in both directions, and a clean intended-only diff.

Strongest failure mode: flattening streams correctly but flattening serializer
metadata or resetting parser counters at each nested node. The adversary must
attack that mismatch, aggregate depth/node limits, same-named disjoint paths,
hidden invalid Enum payload under NULL, node default conjunction, selected
mark schedules and publication cleanup. Architecture agreement alone is not
an independent compatibility certificate.

## Metadata trust boundary

The reader validates recursive topology, Default kind, row counts and
`0 <= num_defaults <= num_rows`. It does not rederive default counts from
physical values or enforce exact parent/child conjunction counts. It never
uses these estimates for result cardinality, trivial COUNT, or pruning.
The writer computes rowwise conjunctions exactly for its owned input, and the
small stock oracle fixtures compare every emitted count independently.
Those writer/fixture checks are not a universal reader counter-integrity claim.

The pinned reference source makes this distinction explicit:
`SerializationInfo.cpp:77-95` samples when exact counting is disabled;
`SerializationInfo.h:45-53` requires exact provenance for consumers whose
results would otherwise depend on an estimate. New `exact_num_defaults` keys
remain rejected by the existing closed envelope. No newer-binary or exact-count
consumer is admitted here.

The inherited `columns: []` AlwaysDefault envelope policy also remains
unchanged. Its existing flat W93 regression does not constitute direct stock
qualification of an empty nested serializer array. This is an explicit
compatibility-policy residual, not proof of a newer physical profile.

## Executed compatibility certificate

All final runtime gates passed on the same frozen production/oracle source.
Root executed the gates serially and checked the source hashes again afterward.
Luna's implementation and static review are correlated candidate evidence;
the independently constructed physical oracle and observed runtime signals
support the scoped result.

| Gate | Observed result |
| --- | --- |
| Focused DEBUG, exact 46-file set below | 550 examples, zero failures/errors/pending, exit 0 |
| Focused RELEASE, same set | 550 examples, zero failures/errors/pending, exit 0 |
| Full DEBUG | 1,732 examples, zero failures/errors/pending, exit 0 |
| W106 stock reader and writer | Both exit 0; three Tuple levels, 13 leaves, 22 streams, five rows |
| W105 nullable Tuple reader and writer | Both exit 0; 53 Nullable declarations and bare controls |
| W104 timezone reader and writer | Both exit 0; 297 profiles in each direction |
| Ten unchanged stock regression scripts below | All exit 0 |

Stock runtime is `26.7.1.1315`; Crystal is `1.21.0` on this macOS host.
No full RELEASE result is claimed. The stock source snapshot remains the
separate depth-1 reference revision stated above, not a claim of latest HEAD.
All heavy commands used this guard function, a 600-second deadline, an 8 GiB
per-process limit (32 GiB for full DEBUG), and a 50% free-memory floor:

```bash
w106_guard() {
  env CLICKHOUSE=/Users/sergey/.local/bin/clickhouse \
    CLICKHOUSE_BIN=/Users/sergey/.local/bin/clickhouse \
    COGNI_RUN_SAFE_MIN_FREE_PCT=50 RUN_SAFE_PASSTHROUGH_STDIO=1 \
    SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
    TMPDIR=/private/tmp CRYSTAL_CACHE_DIR=/private/tmp/crystal-click-w106-cache \
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
)
w106_guard /opt/homebrew/bin/crystal 600 8192 spec --single-module \
  --link-flags='-fuse-ld=ld' "${focused_specs[@]}"
w106_guard /opt/homebrew/bin/crystal 600 8192 spec --single-module --release \
  --link-flags='-fuse-ld=ld' "${focused_specs[@]}"
w106_guard /opt/homebrew/bin/crystal 600 32768 spec --single-module \
  --link-flags='-fuse-ld=ld'
w106_guard bash 600 8192 scripts/probe_nested_tuple_w106_green.sh --green-reader
w106_guard bash 600 8192 scripts/probe_nested_tuple_w106_green.sh --green-writer
w106_guard bash 600 8192 scripts/probe_nullable_tuple_w105_green.sh --green-reader
w106_guard bash 600 8192 scripts/probe_nullable_tuple_w105_green.sh --green-writer
w106_guard bash 600 8192 scripts/check_timezone_temporal_oracle.sh --green-reader
w106_guard bash 600 8192 scripts/check_timezone_temporal_oracle.sh --green-writer
```

The ten regression commands used `w106_guard bash 600 8192 SCRIPT`, with:

```text
scripts/check_parameterized_tuple_oracle.sh
scripts/check_numeric_tuple_oracle.sh
scripts/check_bool_tuple_oracle.sh
scripts/check_identifier_tuple_oracle.sh
scripts/check_datetime_oracle.sh
scripts/check_nullable_temporal_oracle.sh
scripts/check_array_temporal_oracle.sh
scripts/check_array_array_temporal_oracle.sh
scripts/check_temporal_tuple_oracle.sh
scripts/check_qbit_oracle.sh
```

The final ordered production/oracle SHA-256 aggregate is
`300cf75a10aefa8ddda39e91fab62a5820f29c7c17f2de1d0e425c32fb438e10`.
Reproduce it from the repository root, retaining this order:

```bash
shasum -a 256 \
  src/crystal_click.cr \
  src/crystal_click/wide_part.cr \
  src/crystal_click/wide_part/tuple_reader.cr \
  src/crystal_click/wide_part/tuple_serialization_metadata_validator.cr \
  src/crystal_click/wide_part_writer/tuple_part_writer.cr \
  src/crystal_click/wide_part_writer/tuple_serialization_statistics.cr \
  src/crystal_click/wide_part_writer/tuple_serialization_node_statistics.cr \
  src/crystal_click/wide_tuple_schema_node.cr \
  src/crystal_click/wide_tuple_schema_parser.cr \
  src/crystal_click/wide_tuple_type_plan.cr \
  src/crystal_click/wide_tuple_field.cr \
  src/crystal_click/wide_tuple_column_data.cr \
  src/crystal_click/wide_tuple_row.cr \
  scripts/probe_nested_tuple_w106_green.cr \
  scripts/probe_nested_tuple_w106_green.sh | shasum -a 256
```

Root's adversarial verdict is ROBUST within the declared profile. Discriminators
include exact aggregate parser limits, disjoint repeated path labels, detached
schema/path/raw/mask exports, hidden invalid Enum and noncanonical Bool under
NULL, shared selected-mark schedules, exact-budget/one-byte-below guards, and
preflight rejection without publication residue. A writer counterexample with
equal leaf default marginals but different rowwise correlation distinguishes
recursive conjunction from incorrectly combining marginal counts. Independent
stock checks cover literal stream names, raw bytes, mark/frame offsets, recursive
metadata, fresh ATTACH/CHECK, full and PK-selected RowBinary, and read-to-write
byte identity. Comparator seeds alter an expected snapshot; they are not an
on-disk staged-tampering or universal fault-injection certificate.

The reader's metadata-counter scope is exactly the trust boundary above, not
semantic recomputation of sampled counts. All-family flat W105 regression is
not all-family nested stock coverage. Parser depth admission is not a stock
qualification at every admitted depth. Logical 64 MiB accounting is not peak
RSS, allocator overhead, transient-allocation or concurrent-input-mutation
qualification. Compact/Sparse, new metadata versions, unnamed/empty Tuples,
Nullable containers and arbitrary recursive containers remain rejected.

This certificate assumes the frozen source, pinned binary, physical settings,
schema and ownership contracts, and guard route. It decays when any of these
changes: refresh affected bidirectional physical oracles, focused gates and
full DEBUG before extending the claim. Unknown physical profiles continue to
fail closed. The atomic feature commit carries this document, the executed
probes, tests and implementation together; it does not close the whole roadmap.

## Continuation

W106 closes this bounded paired recursive named Tuple slice. Preserve its
certificate and W105 APIs while continuing recursive container parity and
general JSON, followed by MV/projection semantics and finally the like-for-like
memory/performance comparison with at most 10% slowdown. The next proposed
cohesive lifecycle extraction is separately described in
`MODULARIZATION_FRONTIER.md`; broad facade decomposition remains open. This
slice does not authorize remote push or claim the performance target achieved.
