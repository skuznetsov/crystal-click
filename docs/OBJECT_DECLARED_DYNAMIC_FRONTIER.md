# Declared Object Dynamic frontier — W158

Status: VERIFIED for the bounded direct declared-Dynamic profile below.
Root hostile verdict: ROBUST within the executed specs and finite stock fixture;
not general JSON/Dynamic compatibility or overall goal completion.
Baseline: `6dc7ed9` (clean before the new RED spec).
Risk: CAUTION (persistent serialization and public storage consumers).
Rollback: one isolated feature commit, exact paths only; do not overwrite old
fixtures, stores, unrelated changes, or remote history.

## Boundary

Target: paired direct declared `Dynamic` JSON paths in the existing normalized
Object V3 whole-part writer and file/column/table readers. Generic Dynamic
W152–157 plans, streams and physical binding are prerequisites, not a public
Object qualification. Existing inferred Object Dynamic paths stay separate.

The admission is a typed path whose descriptor is exactly Dynamic,
with nominal cap 0..254 and an explicit root-site actual roster. No automatic
insertion promotion or roster inference. Equal nominal types on different
paths may have different stored rosters. Ordinary alternatives use the existing
Object recursive intersection, excluding Variant, LowCardinality and any
contained Dynamic. The shared arm is an independent typed-value envelope, not
the ordinary String arm, and NULL is a separate sentinel.

Still rejected: declared containers containing Dynamic, nested Dynamic actual
arms, Variant/LC actual arms or spills, cap 255, COMPACT declared-Dynamic
serialization, Compact parts, specialized prefixes, old Object/Dynamic
versions, multi-bucket/advanced shared data, and arbitrary Object layouts.
Existing inferred Dynamic modes are not widened or silently coupled to the
new BASIC typed-child profile. Callers of `ObjectDocumentCodec.encode` or
`WidePartWriter.write_uint64_object_pair` must pass `mode: 0_u64` for this
profile; the legacy inferred-path default remains COMPACT and is not silently
changed for a declared Dynamic child. No performance work or complete-engine
claim.

## Source anchor

Separate, unbuilt shallow source:
`/Users/sergey/SrcArchives/clickhouse-2026-10-04-depth1-895d13ea`,
`895d13ea4ce8abb811b3b1b3d51b23a466a342a9`.
Pinned executable is independently identified as CH `26.10.1.1201`, build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`, SHA-256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
No source-to-executable build lineage is asserted.

`DataTypeObject.cpp:865-877` delegates declared paths to DataTypeFactory;
`tests/queries/0_stateless/03214_json_typed_dynamic_path.sql:3-17` exercises
`JSON(a Dynamic)` with scalar and array-valued rows in Wide and Compact parts.
That source fixture is not an executed runtime certificate here.
`ISerialization.cpp:369-408` and `SerializationObject.cpp:971-1007` distinguish
the parent Object structure from each typed child's Dynamic structure.
`SerializationDynamic.cpp:460-554` owns the V3 statistics-presence flag and
per-child suffix. The absent-statistics policy has the finite native whole-part
witness below, not a general profile certificate. Supplied stale counts must not be published as
fresh statistics; recompute them under the shared write budget or explicitly
emit absent statistics and qualify that bounded policy.

## Design laws

- Plan API: an optional `typed_dynamics : Hash(String,
  DynamicStructure)` on `ObjectDocumentPlan`, root site only. Keys must match
  direct Dynamic typed paths exactly, caps must cover stored ordinary arms,
  and inferred/typed namespaces remain disjoint. Legacy non-Dynamic callers
  keep their existing APIs and refusal behavior.
- Keep Dynamic typed streams/plans in separate owners/maps rather than make
  ordinary typed accessors silently return incompatible unions. New cohesive
  owners each have their own file; no additions to the large legacy facades
  unless an observed public-consumer failure requires them.
- Physical planning uses actual rosters before proportional value output.
  Global Object collision checks cover every typed-child data/structure name,
  including empty and unused arms. Shared codec and physical contexts aggregate
  contributor work; do not restart a budget for each child.
- Reader discovery parses each typed child once, retains that exact prepared
  plan and its relative statistics offset, validates every metadata/value K+1
  grid even for zero/middle windows, then decodes selected bodies with that
  same plan. No second parse to reconstruct an offset, EOF-as-boundary shortcut,
  or public untrusted cache that skips metadata validation.
- BASIC normalized discriminator bytes acquire/lose exactly one eight-byte
  physical mode prefix. Ordinary String and SharedVariant streams remain
  distinct; prefix adaptation and coordinate copies consume the parent budget.
- Plain admitted arms permit selected-only body reads. This is not a promise
  to validate unselected value bodies. Metadata and all grids remain complete.
- Whole library parts own every file, metadata, marks and checksums; internal
  round trips and borrowed stock envelopes are not native qualification.

## Execution plan and DoD

1. Root executes `spec/object_declared_dynamic_w158_red_spec.cr` against the
   baseline. Expected: three runtime refusal errors, not missing-symbol RED.
2. Extend the explicit plan/schema grammar, typed stream association, paired
   Object codec, physical planner, lane binder and file-reader preparation.
   Owners: `object_document_plan.cr`, `object_recursive_declaration*.cr`, new
   `object_declared_dynamic*.cr`, `object_document_streams.cr`,
   `object_document_codec.cr`, `object_document_statistics.cr`,
   `object_document_physical_plan.cr`,
   `object_document_column_writer/lane_binder.cr`,
   `object_document_file_reader.cr`, and explicit loader entries.
   Preserve old ordinary typed APIs. Read-only consumer inventory searches
   `contains_dynamic?`, `typed_for`, `physical.typed`, `ObjectDocumentPlan`,
   `ObjectRecursiveDeclaration` and public Object adapters across src/spec/scripts.
3. Root DEBUG and affected RELEASE gates: direct/schema caps, exact rosters,
   different per-path rosters, NULL/spills/Array/unused arms, full/middle/zero
   selection, shared-budget limits, malformed modes, metadata suffix offsets,
   corrupt unselected grids, and retained recursive/no-roster refusals.
4. New finite native qualifier: stock-created public readback and independently
   library-authored complete parts; actual ATTACH and CHECK; independent literal
   full/middle values/types. A checksum-valid wrong-value control must pass
   CHECK and fail that value oracle. Root runs all resource jobs serially under
   `cogni-ml/scripts/run_safe.sh` with isolated cache, one compiler thread,
   600-second/12-GiB bounds and `--link-flags=-fuse-ld=ld`.
5. Hostile root review, formatter/diff checks and exact affected inventory
   reconciliation. Update this seal and `PROJECT_STATUS.md`; atomic local commit
   only after required DoD. No push authorization is inferred.

Reopen W158 on missing metadata ownership, a stale/mismatched roster, bypassed
budget, incorrect sparse schedule, missing native readback or literal value
mismatch. A failed required gate leaves the slice IN_PROGRESS. The all-types,
MV/projections, modularization and later <=10% performance goal remains open.

## Certificate refresh policy

Baseline RED was independently executed at `6dc7ed9` with the new
`spec/object_declared_dynamic_w158_red_spec.cr`: 3 examples, 0 assertion
failures, 3 runtime refusal errors, exit 1. Constructor and parser reached their
existing unsupported-type guards; compilation succeeded. The guarded command
used `crystal spec --single-module --threads 1 --link-flags=-fuse-ld=ld
--error-trace spec/object_declared_dynamic_w158_red_spec.cr`, an isolated W158
cache, and the 600-second/12-GiB resource bounds. This is a discriminating
pre-implementation signal, not reader/writer or native qualification.

## Executed certificate (2026-10-04)

Root independently inspected the production/qualifier changes and executed:

- 16 new public and adversarial examples, zero failures/errors/pending.
- Focused DEBUG: 103 examples, 19 unique specs, three disjoint groups of at
  most eight files; every guard exits 0.
- Affected RELEASE: 272 examples, 43 unique specs, six disjoint groups of at
  most eight files; every guard exits 0. This is not a new whole-project gate.
- Exact source/spec SHA-256 reconciliation across DEBUG, RELEASE and the final
  checkout. DEBUG is an exact subset of the RELEASE inputs; the manifests also
  cover all 286 `src/**/*.cr` files. Eighteen changed Crystal files pass format
  checks; Ruby and Bash syntax and diff hygiene pass.

The source manifests and logs were independently reconciled at
`/private/tmp/crystal-click-w158.9WHzH0/final-{debug,release}.summary` and the
corresponding numbered logs. These temporary aids may expire. Reproduce using
the sorted affected inventory below, in consecutive groups of eight, with the
recorded guard arguments. DEBUG uses the Dynamic W152/W154-W158 specs plus the
binder, declared LC/Variant, schema W140, recursive consumers and logical usage
specs (19 total); RELEASE uses all 43 and adds `--release --no-debug`.

Coverage includes different actual rosters under equal nominal caps, ordinary
typed neighbors, NULL and SharedVariant spills, an unused Array arm, exact
columns/substreams, full/middle/zero file/column reads, public table batches,
canonical caps, exact metadata/value associations, absent stale statistics,
shared node/element/byte budgets and one-short refusals. A test-only opt-in
counter observes exactly one child structure-plan decode per file read.
Invalid BASIC headers, corrupt unselected metadata/value grids and a
checksummed shared path colliding with the declared path refuse. A generic
Dynamic-admitted non-String-key Map spill remains rejected by Object's narrower
arm grammar. Recursive Dynamic and unqualified profiles remain fenced.

Root temporarily removes only the selected shared-path collision guard. The
targeted example fails specifically because no `CorruptPartError` is raised
(one example, one failure, zero errors/pending), proving the test distinguishes
silent overwrite from a refusal. The guard is restored to the exact pre-control
SHA-256 before the final RELEASE gate:
`c2f90f3398782b60a95bda3331125ede0223ca8a209e35b09dedfbca17e1a364`.

Native command: run `bash scripts/check_object_dynamic_w158.sh` under the
600-second/12-GiB guard, with the isolated-cache/linker/SDK settings above and
`W158_EXECUTE_AS_ROOT=YES` (agent execution ownership, not Unix sudo). It exits
0 and invokes the separate Ruby oracle. Retained evidence:
`/private/tmp/crystal-click-object-dynamic-w158.RP3QoI`.
The scripts independently verify both runtime pins and the separate source
revision. Three isolated stores contain one six-row Wide part each, three real
marks plus one terminal mark, single-stream/BASIC/Dynamic V3 and Object V3 MAP.
The native producer uses unchanged natural JSONEachRow input. Stock SQL proves
the concrete per-row roster is Int64 and SharedVariant-spilled
`Array(Nullable(Int64))`; the nominal declaration is `Dynamic(max_types=1)`.
An initial Array(Int64) oracle assumption failed and was corrected only after
that independent SQL discriminator, without changing production/input/settings.

The Crystal reader matches literal full/middle values for the native part and
the library parts. The library authors every pre-ATTACH part file through
`WidePartWriter.write_uint64_object_pair`; no stock envelope or data files are
copied. Both complete library parts actually ATTACH. Stock CHECK, nominal type,
per-row concrete type/shared marker, full JSONEachRow values and keys 3-4
middle values pass the independent literal Ruby oracle. The valid 42-to-43
library mutant passes stock CHECK but raises specifically
`LiteralOracleMismatch` against the same original 42 oracle; its separate 43
literal check passes. Root reads the retained raw CHECK/type/value outputs,
not only the generated PASS summary.

Native qualification is finite: one direct path, cap 1, Int64 and the Nullable
Array spill, default/single-stream/BASIC/Wide/MAP. Multiple per-path rosters,
NULL, cap 0 and unused arms have spec evidence here, not a native certificate.
No Compact, recursive Dynamic, alternative profile, performance or general
complete-part claim follows. The new 219-line declaration/policy owner has its
own file; FileReader is 1,018 lines and LaneBinder 282. The Object column writer
remains 123 lines; the general writer/reader/table remain
25,202/15,726/6,786 lines. Overall decomposition remains unfinished.

Sorted affected RELEASE inventory:

```text
spec/binary_bulk_physical_prefix_w151_spec.cr
spec/binary_dynamic_bulk_plan_w154_adversary_spec.cr
spec/binary_dynamic_bulk_plan_w154_spec.cr
spec/binary_dynamic_bulk_shared_context_w155_spec.cr
spec/binary_dynamic_bulk_values_w155_adversary_spec.cr
spec/binary_dynamic_bulk_values_w155_spec.cr
spec/binary_dynamic_physical_w156_adversary_spec.cr
spec/binary_dynamic_physical_w156_spec.cr
spec/binary_dynamic_statistics_offsets_w157_adversary_spec.cr
spec/binary_dynamic_statistics_offsets_w157_spec.cr
spec/dynamic_descriptor_consumer_guards_w152_spec.cr
spec/object_catalog_w129_root_spec.cr
spec/object_catalog_w129_spec.cr
spec/object_column_lane_binder_refactor_spec.cr
spec/object_column_reader_w129_spec.cr
spec/object_column_writer_w127_root_spec.cr
spec/object_column_writer_w127_spec.cr
spec/object_declared_dynamic_w158_adversary_spec.cr
spec/object_declared_dynamic_w158_red_spec.cr
spec/object_declared_dynamic_w158_spec.cr
spec/object_declared_low_cardinality_w146_spec.cr
spec/object_declared_variant_w151_spec.cr
spec/object_document_schema_w139_spec.cr
spec/object_document_schema_w140_spec.cr
spec/object_documents_w123_adversary_spec.cr
spec/object_documents_w123_root_spec.cr
spec/object_documents_w123_spec.cr
spec/object_dynamic_structure_w120_budget_spec.cr
spec/object_dynamic_structure_w120_spec.cr
spec/object_file_reader_w126_root_spec.cr
spec/object_low_cardinality_consumers_w146_spec.cr
spec/object_offline_table_w130_spec.cr
spec/object_part_writer_w128_root_spec.cr
spec/object_part_writer_w128_spec.cr
spec/object_recursive_consumers_w140_spec.cr
spec/object_recursive_w140_root_spec.cr
spec/object_schema_logical_usage_w140_spec.cr
spec/object_statistics_w127_spec.cr
spec/object_table_w130_root_spec.cr
spec/object_table_w130_spec.cr
spec/object_variant_consumers_w151_spec.cr
spec/object_variant_prefix_w151_adversary_spec.cr
spec/object_variant_w151_root_probe_spec.cr
```

Evidence is scoped to exact source/spec state, independently pinned runtime
and finite fixtures. Changes to roster order, type policy, name escaping,
statistics/prefix/grid ownership, profiles or consumers reopen dependent gates.
Fail closed on unsupported profiles and malformed persisted input.
