# Recursive declared Object Dynamic frontier

## Current composition slice — W216 (2026-10-07)

Status: VERIFIED, scoped ROBUST for bound ordinary JSON leaves at inferred
Object Dynamic paths. Baseline: `ff1cd49`. The full types, MV/projections,
then memory/performance objective remains active. Recursive leaf serializers
are reused; this is not a serializer per type product or all-layout closure.

Admission and ownership:

- Root path values remain bare `BinaryValue` actuals. `DynamicValueCodec`
  owns their legacy discriminator/arm envelope, not the nominal
  `BinaryDynamicBulkCodec` envelope.
- `DynamicJsonObjectBindingRoster` derives the complete census under the
  current operation budget. Every JSON descriptor leaf, including unused arms,
  has exactly one matching child Object plan. Root path, canonical arm and
  descriptor-child path identify the binding. Missing, extra, duplicate and
  wrong-schema bindings reject. Exact whole-arm identity is sealed before a
  root adapter is used; a matching JSON leaf alone is insufficient.
- The generic recursive visitor composes normalized Array/Tuple/Map/Nullable
  wrappers through the existing child Object owner. Legal grammar remains a
  separate admission condition. JSON-bearing Dynamic V3 actual rosters retain
  their recursive-Dynamic, Variant-containing and ordinary LowCardinality
  refusals; supported base types do not authorize forbidden products.
- Parent physical mark rows P and logical child occurrences Q stay distinct,
  including P>0/Q=0 and terminal zero. Complete child domains and persisted
  schemas are validated before selected values or EOF are exposed. Ordinary
  no-JSON selected reads keep their previous route.
- The same operation budget and explicit absolute typed/inferred origins cross
  Object/JSON handoffs. An inferred-root JSON leaf at depth D gives both child
  origins D+1. A declared typed-Dynamic leaf keeps child typed origin D+1;
  its child inferred-actual origin is D+2 only when persisted child Object
  metadata contains inferred Dynamic paths. No phantom edge is charged to a
  child without inferred paths, and no real edge may reset.
- Inferred-root children inherit the enclosing Object shared-data profile;
  the default remains `single_stream`. Existing typed-Dynamic child profile
  policy is unchanged. Public unbound bulk constructors, Dynamic SharedVariant
  defaults and outer Object shared MAP/Copy guards are not widened.
- Statistics, normalized streams, complete-part writing, automatic physical
  discovery, column and typed-table consumers share the checked handoff.
  Five cohesive new owners each have their own source file; broad facade
  decomposition remains open.

Observed final DoD:

1. The same 152 unique affected spec files pass 914 examples in each of DEBUG
   and RELEASE, in 19 serial cohorts per mode. All 38 actual guarded exits are
   zero, with zero failures, errors and pending examples. The five-file
   W215/W216 focused gate passes 34 examples per mode. Source/spec/helper/
   runner bytes are unchanged throughout these final gates.
2. Fresh native probes pass four cells per mode: `single_stream` and
   `with_size_stream` String profiles x BASIC/COMPACT Dynamic discriminators,
   finite Wide/LZ4 parts. COMPACT is not the Compact MergeTree part layout.
   Each mode reads four stock-authored parts and directly ATTACHes four
   independently library-authored parts, with four source CHECKs and eight
   attached source/library CHECKs.
3. Native stock and library declarations are identical:
   parent `JSON(max_dynamic_paths=16, max_dynamic_types=4)`, direct and
   Array-wrapped child `JSON(max_dynamic_types=0, max_dynamic_paths=0, v UInt8)`.
   Eight independent literal Object RowBinary rows exercise sparse sibling
   paths, empty arrays, four marks [2,2,2,2], full/first/later/final windows and
   EOF. This finite matrix does not qualify every normalized wrapper product.
4. The root raw-artifact audit independently checks the literal input bytes,
   exact INSERT paths/types, ordered SELECT predicates/results, empty-window
   framing, actual process records and immutable part contents. It exits zero;
   all 228 generated library-part files reconcile across DEBUG/RELEASE,
   including current modes. The original source snapshot did not record
   permissions, so its pre/post permission preservation is not claimed.
   ATTACH permits only the checked 28-byte, mode-0644
   `_block_offset\n_block_number\n` file addition.
5. Four in-memory raw-auditor mutations are rejected: literal path substitution,
   omitted empty SELECT, changed selected predicate and reversed EOF boundaries.
   These audit-contract tests execute neither native serde nor the library and
   are not source-to-binary build attestation.
6. Unchanged W215 depth coverage first exposed a real typed/inferred-origin
   regression (32 examples, one failure). The paired fix preserves its original
   assertion. A new public root-writer whole-arm witness was observed RED
   before the seal fix (10 examples, one failure). A current production
   inferred-origin-reset seed also fails the unchanged shifted-origin assertion
   (10 examples, one failure); the codec is then restored byte-for-byte.
   Restored focused, broad and native gates pass.
7. Physical corruption witnesses refresh test fixture checksum metadata to
   reach child validation: excluded nonempty direct/Array child bodies with
   trailing bytes and an excluded wrong parent row grid reject even for EOF.
   These prove the exercised full-domain guard, not production checksum-hash
   verification or whole-scan callback atomicity.

All resource jobs are serial under the unchanged 50%-free-memory guard.
Exact commands, source/log/artifact pins and observed exits are indexed in
[the W216 evidence packet](../.landmark/evidence/object-inferred-dynamic-json-w216.json).
The packet is an index to executed evidence, not proof by its structure.

Source comparison uses the clean one-commit shallow checkout
`/Users/sergey/SrcArchives/clickhouse-2026-10-07-depth1`, revision
`0ca8150d9b1d0886edb2e3b4ab65eebb768d0357`. Native qualification uses the
separately pinned `26.10.1.1201` executable, build `d9bcb5ab007f0f6299f7f973f2642245bab3d028`;
it is not a build of that source revision. Earlier stock-only direct/tuple
RowBinary probes established fixture routes, not library qualification.
Ruby Range/tag/key-roster and raw-audit manifest-schema mistakes were corrected
as instrumentation errors; their failed runs are not native format successes.

Risk: CAUTION (persisted format and API propagation). Rollback is only the
coherent local feature commit, without push. Strongest attacked failure:
losing inherited depth or confusing sibling leaf/whole-arm physical ownership.

Open: outer Object shared MAP/Copy and advanced layouts/profiles, generic
Dynamic owned offline values, MV/projection propagation and broad facade
decomposition. No all-type/all-layout, RSS or performance claim follows.
Refresh if descriptors, bindings, origins, budgets, physical profiles,
consumers, source/runtime pins or relevant source bytes change. Raw temporary
evidence is not durable storage; if it disappears, re-execute rather than
reconstructing an observed run.

## Previous composition slice — W215 (2026-10-07)

Status: VERIFIED, scoped ROBUST for ordinary JSON actual leaves at declared
Object typed-Dynamic sites. Baseline: `52ff690`. The complete types,
MV/projections, then memory/performance objective remains unchanged; this is
one finite composition handoff, not a reduced completion goal.

Target: ordinary JSON-bearing actual alternatives at declared Object typed
Dynamic sites. Reuse the generic recursive bulk visitor, exact
`BinaryDynamicJsonLeafKey` bindings and existing Object child serializers.
The per-file `ObjectDocumentTypedDynamicJsonPhysical` owner recursively
composes the exact child physical pairs; no codec is introduced for wrapper
products. Explicit bindings associate each JSON descriptor leaf with its child
Object plan. Physical rows P, logical child rows Q and inherited descriptor
depth stay separate, and JSON reads validate the complete parent mark domain
before slicing selected results.

Finite depth contract: supplied origins remain validated. When typed fields
exist, their root depth must fit the configured limit; typed-Dynamic fields
retain a minimum origin of two. An empty Object with no typed fields must
remain admissible at `max_depth=1`, even if the default root origin is two.
Each nested JSON child receives its absolute JSON-leaf depth plus one and the
same operation budget; recursion must not reset depth at the child Object.

Rejected cases include unbound or excessive bindings, invalid descriptor
paths, mismatched child schemas/metadata and illegal Object wrappers. Inferred
root Object Dynamic JSON actuals, outer shared MAP/Copy and advanced JSON
owners, further layouts, owned offline values and MV/projections remain
separate open frontiers.

Risk: CAUTION (persisted serialization and API propagation). Preserve the
clean baseline; rollback is the exact feature diff or its eventual atomic local
commit, without push. Likeliest defect: admitting JSON metadata without routing
every value/physical consumer to the child owner, or confusing sparse child
occurrences with parent mark row counts. Missing/extra bindings and a corrupt
unselected child mark must reject rather than silently yield partial values.
Repeated Object/typed-Dynamic/JSON handoffs must carry the absolute descriptor
depth as well as the shared operation budget; restarting at depth two inside
each child Object would make a finite local limit ineffective globally.

Observed W215 evidence and scope:

1. The same 150 unique spec files pass 898 examples in each of DEBUG and
   RELEASE, partitioned into 18 serial cohorts per mode; the final focused
   gates pass 18 examples per mode. Coverage includes exact leaf bindings,
   inherited budgets/depth, P/Q distinction, full-domain and EOF checks, and
   column, table and Array(Object) consumers. Existing parser probes pass 28
   checks across one- and two-entry metadata rosters. The actual-helper oracle
   rejected a literal mutation from 22 to 222. A depth-origin reset seed was
   caught by the unchanged max-depth assertion. An unconditional root-depth
   upper bound produced three errors for an empty advanced Object at
   `max_depth=1`; the conditional correction passes its six-example gate and
   the corrected-state full gates.
2. Four native cells pass in each mode: `single_stream` and `with_size_stream`
   String profiles crossed with BASIC and COMPACT Dynamic discriminator
   layouts (not the Compact part layout). Each mode has four stock reads, four
   generated direct ATTACHes, four source CHECKs, and eight attached
   source/library CHECKs. Stock actuals are plain JSON/Array(JSON) with
   `v:Int64`; generated library parts use typed JSON/Array(JSON) with
   `v:UInt8`. These intentionally asymmetric fixtures do not establish
   equivalent descriptors. All 188 generated library-part files reconcile
   across modes. The attached copies retain generated files and add the exact
   pinned 28-byte `invalidated_system_columns.txt`; path expectations use the
   independent raw `DATA_PATH`, not pre-ATTACH paths.
3. Root's zero-exit raw-artifact audit validates actual process records,
   literal windows, runtime/source pins, input/helper hashes and complete
   manifests. The source is shallow ClickHouse revision
   `0ca8150d9b1d0886edb2e3b4ab65eebb768d0357`; the separate native runtime is
   ClickHouse `26.10.1.1201`, build
   `d9bcb5ab007f0f6299f7f973f2642245bab3d028`. Refresh evidence if either pin,
   grammar, bindings, physical names, budgets or consumers change.
4. The full-domain reader validation and an unused bound-child EOF corruption
   are covered. A separate corrupt mark on a nonempty parent row excluded by a
   selected window was not a fixture; source-level complete-domain validation
   is not that additional behavioral probe. No all-type, other-layout,
   checksum-hash, whole-scan callback-atomicity, MV/projection, RSS or benchmark
   claim follows. Broad facade decomposition remains a separate open frontier.

The root evidence index is
[W215 evidence packet](../.landmark/evidence/object-typed-dynamic-json-w215.json).

Source reference and runtime pins are unchanged from W214 below. Refresh the
evidence after grammar, binding/physical names, metadata, budgets, mark-window
consumers or either pin changes.

## Active composition track — W214 (2026-10-07)

Status: VERIFIED for the finite W214 inline SharedVariant branch below.
Ordinary JSON actual bindings remain guard-only and are the next transition.
Baseline: `8e94d2e79785dd08e1a3d42f929c7c66278b7d1c`, inspected clean.
The full types, MV/projections, and eventual performance goal is unchanged.

Target: compose declared Object Dynamic sites with JSON-bearing actuals using
the existing recursive scalar and Object child serializers, not codecs per
wrapper product. Implement the two independent storage branches in order:
inline SharedVariant JSON first; ordinary actual JSON leaves with exact child
bindings next. Root inferred Object paths, outer Object shared MAP/Copy,
other serialization layouts, and MV/projection consumers remain separate
unimplemented handoffs, not evidence of this track's completion.

Source reference: shallow ClickHouse `0ca8150d9b1d0886edb2e3b4ab65eebb768d0357`.
Typed paths delegate to DataTypeFactory (DataTypeObject.cpp:858-870); Dynamic
actual Object inference uses JSON (FieldToDataType.cpp:213-217). The separately
pinned runtime is build `d9bcb5ab007f0f6299f7f973f2642245bab3d028`.

Risk: CAUTION, serialization admission. Rollback is the exact scoped diff and
then one atomic local commit per verified branch; no push. Likeliest failure:
an opt-in accidentally widens ordinary metadata or Object shared envelopes,
or loses inherited Object depth when borrowing scalar recursion.

Execution and falsifiers:

1. Qualify declared and discovered paths with bounded stock MergeTree fixtures.
   A discovered object is flattened; an array of objects is an Array(JSON)
   actual. Source inspection does not replace persisted runtime qualification.
2. Execute a compiling public-API RED for inline JSON in a declared typed
   Dynamic site before production changes. Reuse W213 scalar recursion and
   preserve the default actual-roster, legacy, Object MAP/Copy, and nominal
   JSON declaration guards. Explicit caller permission is not permission to
   infer or promote ordinary JSON alternatives.
3. Verify normalized, complete-part and table read/write consumers, multiple
   sites, whole/middle/final/EOF windows, NULL versus empty JSON, inherited
   depth/aggregate bounds, malformed envelopes and both String profiles.
   Root runs DEBUG/RELEASE `crystal spec` under the existing serial resource
   guard; expected signal is zero failures/errors/pending. Use stock-authored
   reads and direct ATTACH/CHECK of library-authored parts for native claims.
4. Attack permission leakage and depth/reset defects, restore exact source,
   rerun focused checks, and record only observed evidence. Ordinary JSON
   child bindings stay guard-only until their separate complete-domain
   metadata, occurrence-grid and physical-consumer gates pass.

No performance/RSS, all-products, all-layouts, checksum-hash validation, or
whole-scan callback-atomicity claim is made by this track.

Completed handoff (W214 inline branch):

1. `object_declared_dynamic_declaration.cr`: keep actual-roster validation
   unchanged; opt in only selected JSON-bearing shared values at paired Object
   callers. Preserve bounded descriptor scans and the existing excluded actual
   types. Propagate that permission in `object_document_codec.cr`,
   `object_document_statistics.cr`, and `object_document_file_reader.cr`.
   Consumer inventory: `rg -n 'validate_selected_values!|validate_selected_value!'
   src/crystal_click/object*` found the recursive validator and four paired
   consumers (codec write/read, statistics, physical reader).
2. `binary_bulk_encoder.cr` / `binary_bulk_decoder.cr`: borrow the same scalar
   helpers and operation budget, with an explicit inherited shared-value depth
   origin. Standalone defaults remain one; Object typed owners pass two. Keep
   ordinary JSON leaf-key depths relative to the existing Dynamic plan.
3. New `object_typed_dynamic_shared_json_w214` unit/physical specs and paired
   native helper/probe: check literal values, multiple sites, distinct row and
   occurrence grids, both String profiles and discriminator layouts, selected
   windows, malformed payloads, depth and aggregate limits. DoD is guarded
   focused and affected DEBUG/RELEASE specs with zero failures/errors/pending,
   stock-authored part reads and direct ATTACH/CHECK of library-authored parts,
   followed by permission/depth adversary checks. No all-layout claim follows
   from these bounded fixtures. Root owns resource jobs and final review;
   delegated code is candidate evidence until those checks execute.

## Observed W214 gates (2026-10-07)

Declared typed Dynamic sites explicitly admit selected JSON, Array(JSON), and
Tuple(JSON, JSON) scalar envelopes through the existing W213 recursive visitor.
Legal Object wrappers and scalar siblings reuse their existing owners; JSON's
own metadata/value grammar remains the scalar JSON owner's responsibility.
Ordinary actual rosters remain strict. Outside terminal JSON metadata, selected
actual trees still exclude Dynamic/Variant/LowCardinality, QBit/count leaves
and non-String Map keys. This is not an all-wrapper-products native claim.

The four selected-value opt-ins are paired codec write/read, statistics and
physical-reader validation. Public default helpers remain strict. The existing
generic W213 shared-envelope API intentionally admits JSON; a standalone
ObjectSharedPathCodec inherits that low-level contract. Outer Object shared
MAP/Copy/advanced document owners retain their separate guards.

`BinaryBulkEncoder`/`BinaryBulkDecoder` validate and propagate the trailing
shared-value depth origin: standalone one, Object typed owner two. Selected
scalar depth is summed in Int64, checked, then narrowed; no budget is reset.
Ordinary JSON bindings retain their relative descriptor-child coordinates.
The deeper W212 bridge walks runtime contents at the inherited row depth before
returning a row. Its intermediate Object documents may exist before that final
row check; this is not a transient allocation/CPU bound. A standalone selected
validator is not a complete operation-budget certificate.

- The same 88 affected spec files pass 539 examples per mode, zero failures,
  errors or pending, in ten serial guarded cohorts. The final DEBUG cohort ten
  supersedes its earlier 44-example run with 45 examples. Final focused unit/
  physical gates pass 11 in DEBUG and 11 in RELEASE. Formatter and Ruby syntax
  checks pass. Apple ld is used; default-lld linker failure is not a RED.
- Normalized tests cover both String profiles and BASIC/COMPACT discriminator
  modes, multiple typed sites and parent P / Dynamic Q / SharedVariant R grids.
  Physical writer, file reader, column reader and table witnesses cover whole,
  middle, final and EOF windows with literal values, NULL and empty arrays.
  Malformed descriptor/trailing-envelope and one-short aggregate-node guards
  reject. Runtime depth passes at four for generic versus five for Object;
  an outer bound JSON bridge passes at six and rejects at five in both directions.
- Three separate production seeds (Object encode origin one, decode origin one,
  default selected JSON permission true) each fail an unchanged assertion.
  Each seeded run reports nine examples, one failure and no errors/pending;
  exact production/core restoration precedes the later deeper-owner test.
- Fresh paired native matrices qualify `JSON(p Dynamic(max_types=0))` with an
  empty ordinary roster, both String profiles and BASIC/COMPACT discriminators:
  four stock reads and four direct library-part ATTACH/CHECKs per mode, eight
  rows/four data marks each. Raw system.parts reports five marks including the
  terminal. Native full/first/later/final/zero projections and helper full/first/
  middle/final/EOF windows match. All 100 generated library-part files match
  across DEBUG/RELEASE. Native empty [] is inferred Array(Nullable(String)), not
  an empty Array(JSON) native witness; the explicit latter has library tests.
  Missing and NULL both normalize to the same `payload.p` value.
- A changed expected JSON projection, with unchanged native SQL input, fails
  after stock process exit zero. The runner hash is restored exactly. Root
  independently decodes raw TSV projections against a separate literal matrix,
  verifies argv/stdin/stdout/stderr hashes and process status, executable pins,
  helper input/part identities, immutable snapshots and byte parity. The runner's
  native expectations themselves share the Ruby input roster; do not call them
  independently authored. Harness mistakes (output root/profile, query
  settings/window mapping) were corrected and fresh final matrices supersede
  the failed runs. The failed empty-array prediction was narrowed, not promoted.

Scoped adversary verdict: ROBUST for this paired finite transition. Delegated
source review is correlated; observed root executions and the raw literal
audit supply behavioral evidence. No full type/product/layout, whole-file
checksum-hash validation, RSS/performance or whole-scan callback atomicity claim.
Curated lineage and exact commands:
`.landmark/evidence/object-typed-dynamic-shared-json-w214.json`.

Next falsifier: ordinary JSON-bearing actuals at declared Object Dynamic sites
must receive exact Object child bindings, complete-domain metadata and distinct
parent/occurrence grids before their roster guard opens. Inferred root Object
paths, outer shared data, owned offline values and MV/projections remain open.
Refresh these claims when grammar, wrapper/budget handoffs, physical names,
selected marks, runtime/source pins or consumers change. No push is authorized.

## Initial W214 anchors (retained history)

- `spec/object_typed_dynamic_shared_json_w214_spec.cr` uses the existing public
  Object APIs with a declared zero-cap Dynamic and an explicit empty ordinary
  roster. The guarded DEBUG run compiled, then reported one example and one
  `UnsupportedFormatError` in selected-child validation, before scalar output.
  Command suffix: `spec spec/object_typed_dynamic_shared_json_w214_spec.cr
  --single-module --threads 1 --link-flags=-fuse-ld=ld --error-trace`.
  The earlier default-lld attempt failed to link against the macOS SDK and is
  not behavioral evidence. Logs remain session-local under
  `/private/tmp/crystal-click-w214.AcjESJ/`.
- The pinned native process wrote and queried four isolated MergeTree tables
  (15 rows). Declared zero-cap Dynamic stores JSON and Array(JSON) through
  SharedVariant; the one-cap fixture retains JSON ordinarily and spills
  Array(JSON). The exact-output qualifier passes after correcting its initial
  NULL and inferred-descriptor predictions. NULL/missing report `None` and TSV
  `\N`; discovered Array(JSON) reports zero JSON dynamic caps. The original
  mismatching record is retained alongside
  `qualifier_69474_a65c8fb234ae.json`. This is stock-runtime qualification, not
  a library part interoperability or fresh-source runtime claim.
- The initial next falsifier was inherited Object depth inside shared JSON.
  It is now exercised above; ordinary child bindings still follow separately.

## Historical W159 slice

Status: VERIFIED for the bounded paired slice below. Baseline: `032c515`
(clean at inspection). Risk: CAUTION; this changes recursive schema admission and paired
serialization. Rollback: keep the implementation in one isolated local feature
commit touching only the owners below; revert that commit if a gate fails.

## Boundary

W159 extends the verified W158 direct-declared-Dynamic slice to the next useful
paired transition: a caller-declared Object/JSON field may contain Dynamic at
one or more recursive descriptor sites admitted by Object's existing recursive
declaration grammar. The generic W154–157 `BinaryDynamicBulkPlan` remains the
site/codec/physical authority. Site rosters are explicit; W159 must not infer,
promote, or discover actual types from row values.

Admit direct Dynamic unchanged and recursive declared sites such as
`Array(Dynamic)`, `Tuple(x Dynamic, y Dynamic)`, and `Map(String, Dynamic)`.
Also preserve already-legal surrounding wrappers: for example a nullable tuple
containing Dynamic, a Variant arm whose contained wrapper contains Dynamic, and
a legal LowCardinality sibling beside a Dynamic site. Each Dynamic site's
actual ordinary alternatives and selected SharedVariant spills remain inside
the W158 Object recursive arm domain: no contained Dynamic, Variant, or
LowCardinality actual arm/spill. The actual-roster domain does not inherit the
declared descriptor's recursive permission.

Do not relax upstream/Object grammar while threading recursive permission:
`Nullable(Dynamic)`, `Variant(Dynamic)` as a direct arm, a Dynamic Map key, and
Dynamic beneath a LowCardinality wrapper remain rejected. Keep W158's cap,
statistics, BASIC profile, V3/Object layout, and Wide-only boundaries. Compact,
advanced shared-data layouts, general ClickHouse JSON compatibility, MV or
projection consumers, and performance work are outside this transition.

## Baseline anchors and fences

These anchors describe the inspected W158 baseline, not the widened source.

- `src/crystal_click/object_recursive_declaration.cr:303-400` measures typed
  descriptors. It currently passes `allow_declared_dynamic: false` through
  Array/Nullable/Map/Tuple recursion and rejects a direct Dynamic Nullable
  child; Variant arm rules are separately stricter.
- `src/crystal_click/object_recursive_declaration_text.cr:146-247` performs
  allocation-bounded declaration scanning, and `:520-562` resolves tags and
  keeps Variant/LowCardinality arm boundaries. `ObjectDocumentSchema` renders
  through `ObjectTypedFieldType.append_name` at `:205-220`; both parse and
  render must agree on the same recursive admission.
- `src/crystal_click/binary_dynamic_bulk_plan.cr:302-405` parses or prepares an
  exact site set; `:408-505` discovers paths through nominal wrappers and
  actual roster arms. The generated path grammar includes Array `.elements`,
  Nullable `.nested`, Tuple `.field.<index>`, Map
  `.elements.field.{0,1}`, and Variant `.arm.<index>`, all rooted at `root`.
  The plan retains `statistics_offset_for(site)` and exact per-site structure
  roles. `binary_dynamic_bulk_codec.cr:15-59` is the paired generic path.
- Object's current direct-only gates are `object_document_plan.cr:11-64`,
  `object_document_codec.cr:34-56,263-295,339-388`,
  `object_document_physical_plan.cr:29-38,100-134`,
  `object_document_column_writer/lane_binder.cr:80-129,220-265`, and
  `object_document_file_reader.cr:195-230,254-261,338-499,528-571`.
- W158 stats copying/rebuild currently handles one structure per typed path at
  `object_document_statistics.cr:45-50,183-193,196-265`. Every recursive site
  needs fresh absent V3 statistics; copying stale supplied counts is not a
  valid alternative.
- Public declared-schema boundaries are
  `object_document_column_writer.cr:7-45`,
  `object_document_file_reader.cr:82-134`,
  `object_column_reader.cr:31-36,149-179`,
  `wide_part_writer.cr:25-45`, and
  `wide_part_table/object_column_adapter.cr:5-13,28-57`.

In particular, W158's one-site root-only stream check and `root.discriminators`
header exception cannot simply be deleted. They must become exact per-field,
per-site checks. Descriptor roster entries (field path → Dynamic-site path →
`DynamicStructure`) are the explicit logical input. Physical metadata blobs,
value-role names, and discriminator grids are then derived and checked from
that descriptor plus the declared type; they are not caller-promoted roster
entries. The Object physical owner must collision-check the complete generated
physical filename set before proportional value output.

## Public API contract

Keep the three-argument-compatible plan surface:

```crystal
ObjectDocumentPlan.new(structures, typed_paths, typed_dynamics = {})
ObjectDocumentPlan.new(
  structures,
  typed_paths,
  typed_dynamics,
  typed_dynamic_sites: Hash(String, Hash(String, DynamicStructure)),
)
```

The existing third argument stays root-only for direct Dynamic fields and is
normalized internally to site key `"root"`. The new fourth keyword supports
any declared type containing Dynamic, including direct Dynamic. Supplying both
forms for one field, using the legacy form for a composite type, or omitting,
adding, or duplicating a declared field/site key is an error. The exact site
set is validated by the generic plan against the declared type and all
explicit actual rosters. No site map is inferred from values.

`has_typed_dynamic?(field)` and the typed-Dynamic field roster cover every
typed descriptor with `contains_dynamic?`. Add
`typed_dynamic_sites_for(field) : Hash(String, DynamicStructure)` as a detached
site-map accessor. Keep `typed_dynamic_for(field)` as a root-only compatibility
accessor and reject calls for a composite descriptor; it must not return an
arbitrary nested site. Ordinary `typed_for` and `streams.typed_for` continue to
cover only fields without Dynamic. Keep typed Dynamic lanes in their separate
`BinaryDynamicBulkStreams` map, now with exact site-keyed structure streams.
Expose per-site statistics offsets (for example
`typed_dynamic_statistics_offset(field, site)`); the old one-argument root
accessor remains direct-only.

## Paired invariants

1. Parse and render use the same recursive descriptor walk. The walk carries a
   declared-schema permission through legal wrappers, but keeps the explicit
   direct-child exclusions for Nullable, Variant, Map keys, and LowCardinality.
   It also carries the Object root depth so site actual-arm and SharedVariant
   spill checks use the true depth through Array/Tuple/Map/Variant ancestors.
   A wrapper that fits while its site actual arm exceeds the configured depth
   must fail before names or lanes are materialized.
2. Before copying caller maps or allocating child/role tables, bound the whole
   schema, field/site counts, descriptor visits, type-name bytes, and metadata
   copies under the shared codec budget. Prepare all per-field generic plans
   from explicit rosters before physical planning or value-lane allocation.
   One codec budget covers parent Object metadata, all typed sites, stats
   normalization, ordinary/shared siblings, and values; one shared physical
   context covers every field/site filename and collision. Do not restart a
   budget per field or site. Nominal schema and actual-roster descriptor walks
   must be bounded before recursive presence predicates. Schema-only metadata
   discovery charges intermediate physical prefix copies as well as final
   names before materialization; a borrowed discovery budget accumulates
   across fields. Logical bounds do not certify allocator RSS.
3. Write validates each typed root against its descriptor, then validates the
   selected concrete type at every Dynamic site, including SharedVariant
   spills, against the W158 actual-arm rule and true Object depth. Generic
   Dynamic bulk encoding receives the prepared per-field plan; it never
   discovers a roster from row values. Statistics recomputation preserves the
   exact explicit site map while rebuilding each site's child structure with
   absent stats. The recursive selected-value policy borrows the operation
   budget and admits child counts before visiting collection elements; stats
   normalization cannot defer that work bound to a later encoder.
4. Physical planning derives every Dynamic role and every per-site
   `.dynamic_structure` physical lane from the prepared generic plan, checks
   all names for collisions globally, and applies the BASIC eight-byte prefix
   only to each site discriminator role. Site structure lanes carry that
   site's own statistics offset. Ordinary variant prefixes and Object's
   inferred Dynamic lanes remain separate.
5. Read parses every typed Dynamic structure stream exactly once into a
   retained `BinaryDynamicBulkPlan` per typed field. That plan supplies the
   exact site map and statistics offsets used to validate each metadata grid
   and to decode selected values; do not reparse to recover offsets and do not
   add a public trusted-plan parameter. A private prepared-read seam may pass
   the first plan into the generic bulk decoder.
6. Before any selected value window, validate exact field/site metadata
   rosters, every metadata suffix/EOF, every complete K+1 value/discriminator
   grid, BASIC discriminator headers, and global physical names. These checks
   also run for `inspect`, middle selection, and zero selection. Bodies remain
   selected-only; unselected body bytes are not promised to be semantically
   decoded. Reassembled documents fail closed on any typed/shared field-name
   collision; a Dynamic field must never overwrite an ordinary/shared field.

## RED and transition DoD

Baseline evidence at `032c515`: root ran four public recursive-schema
examples. Compilation succeeded, and all four raised the existing unsupported
recursive-Object `ArgumentError`; this is a schema-admission RED only. It does
not establish paired-codec or complete-part RED coverage. After the schema
fence is implemented, add and run the paired-codec and public complete-part
falsifiers below before widening the implementation claim:

- `Array(Dynamic)`, a named tuple with two Dynamic sites, and
  `Map(String, Dynamic)`; assert canonical type rendering and exact site paths.
- legal Nullable/Tuple and Variant/wrapper-containing-Dynamic cases, plus a
  legal LowCardinality neighbor; retain RED for `Nullable(Dynamic)`, direct
  `Variant(Dynamic)` arm, Map Dynamic key, and Dynamic-under-LC.
- missing/extra/overlapping site maps; different rosters at same-cap sites;
  explicit-only behavior when values could suggest an unprovided arm; and
  selected illegal actual arms and SharedVariant spills.

Implementation owners: `object_recursive_declaration*.cr`,
`object_document_plan.cr`, `object_document_streams.cr`,
`object_document_codec.cr`, `object_document_statistics.cr`,
`object_document_physical_plan.cr`,
`object_document_column_writer/lane_binder.cr`,
`object_document_file_reader.cr`, and `crystal_click.cr` for any new owner.
Keep historical W158 certificates unchanged. Current spec assertions may
replace intentionally obsolete admission fences, while retaining unsupported
profiles and malformed-input refusals. Use a cohesive new helper owner
for recursive declared-site policy/provenance if doing so avoids broadening the
large generic or legacy facades.

The first useful completion is one public paired Object V3 MAP / Wide slice
that parses and renders recursive descriptors, writes full parts, inspects
them, and reads full/middle/zero marks with one retained site plan per field.
It is not a producer-by-producer partial type gate. Require DEBUG and affected
RELEASE coverage plus root's finite stock public round-trip before calling it
verified. Do not claim Compact, arbitrary engine compatibility, MV/projection,
or performance closure.

RED/adversary matrix must include malformed or missing/extra site metadata,
bad per-site statistics suffix, wrong/missing physical role, invalid BASIC
header on a nested site, an unselected corrupt K+1 grid, and every one-short
shared-budget dimension for a nested-site plan. Strongest counterexample:
the wrapper and nominal descriptor fit the depth limit, but a nested actual
arm or spilled selected type exceeds it; that must be rejected before
publication. Also attack zero-window reads: they must still parse all site
metadata, validate each header and every complete grid, yet decode no selected
body. If any guard is removed and its negative case still passes, the test
does not distinguish the boundary and needs a narrower falsifier.

Small-limit work falsifiers also cover a long column prefix copied through
nested named tuples, cumulative metadata discovery across individually fitting
fields, maximal legal Int32 depth arithmetic, and recursive selected-value
work in both the borrowed validator and standalone statistics recomputation.

Reopen this seal if source-runtime legality disagrees with an admitted wrapper,
the generic plan emits a site set outside the declared grammar, a child/site
budget can be bypassed, a physical collision escapes, or zero-window selection
skips metadata/header/grid validation. The pre-implementation design is
superseded only within the scoped executed certificate below.

## Executed certificate (2026-10-04)

Root's scoped hostile verdict is ROBUST for recursive declared Dynamic in the
existing normalized Wide/Object V3 MAP/BASIC profile. This is not general
JSON compatibility, a new complete-inventory gate, MV/projection closure or
performance evidence. Existing W158 actual-arm restrictions are preserved;
constructor preflight now rejects an invalid explicit actual roster before
an encoder can consume it. Historical certificates are not rewritten.

One `ObjectDeclaredDynamicSites` module/file owns nominal site provenance,
preflight shape and true Object-depth coordinates. Existing generic Dynamic
bulk/physical owners remain authoritative. Public plan construction accepts
the exact fourth site-map keyword, preserves the legacy direct-root form and
rejects overlaps, missing/extra sites, wrong caps and undeclared fields. Site
accessors detach keys; indexed walks retain a cached canonical site order.
Prepared per-field plans, absent child statistics and exact offset maps flow
through the codec, statistics, lane binder and private FileReader preparation
seam. There is no public caller-certified prepared-read parameter.

Specs cover Array, distinct same-cap Tuple sites, Map(String, Dynamic), legal
Nullable/Tuple and Variant/Array wrappers, LC neighbors/replay, NULL/empty,
cap 0 and unused ordinary arms. The main mixed fixture reaches codec,
physical-plan, whole writer, inspect, full/middle/late/zero file and column
reads, table windows and catalog `.values`. Negative cases retain illegal
direct-child positions and actual-arm domains, and attack exact metadata
rosters, statistics EOF, misnamed physical roles, nested BASIC headers,
unselected K+1 grids and shared collisions. Small-limit cases distinguish
true actual-arm depth, borrowed nodes/elements/bytes, intermediate prefix
copies, cumulative fields, maximal Int32 depth arithmetic and standalone
statistics selected-value work.

### Observed gates and source lineage

- Focused DEBUG: 127 examples, 22 unique specs, three disjoint groups; all
  zero failures/errors/pending and guard exit 0.
- Affected RELEASE: 572 examples, 77 unique specs, ten disjoint groups; all
  zero failures/errors/pending and guard exit 0.
- Root reconciled every captured source/spec SHA256 against the final files.
  No source/spec input changed during either final gate.
- Two temporary source-only controls each run one exact adversary example:
  replacing `SiteSpec.actual_root_depth` with 3 makes row-free nested roster
  preparation escape the depth-5 refusal; replacing `prefix_copy_factor`
  with 1 makes long-prefix discovery escape the byte limit. Both fail the
  intended `expect_raises` assertion, not compilation or an unrelated check.
  Both owners were restored SHA256-identically before RELEASE.
- Exact changed-file formatter check, shell syntax, Ruby syntax, diff and
  source hygiene checks pass. Logical counters do not certify physical RSS.

The retained gate runner is
`/private/tmp/crystal-click-w159.huxO5J/run_spec_gates.rb`; commands were
`ruby .../run_spec_gates.rb debug debug-final-4` and
`ruby .../run_spec_gates.rb release release-final-1`.
Each runs Crystal 1.21.0 serially through the existing resource guard with
600 seconds/12288 MiB, `--single-module --threads 1`, host `ld`, an isolated
cache and the configured macOS SDK. RELEASE adds `--release --no-debug`.
Logs and exact inventories are retained beside that runner. Manifest hashes:

| Manifest | SHA256 |
| --- | --- |
| `debug-final-4.summary` | `9b2a2f6b65e61bc8ec8e8b1c259bba6a538a5a817eb7be05d1d52051a0d9873d` |
| `release-final-1.summary` | `3a42e362098ee7c0368e8ac557036f83df93a40f9b0957a622792ceaee28464d` |

The focused inventory is the three W159 specs plus W158's three specs,
W140 schema/recursive-consumer/logical-usage, W146 declared LC, W151 declared
Variant, lane-binder refactor, W157 offsets pair, W156 physical pair, W154 plan
pair, W155 values pair/shared-context and W152 descriptor-consumer guards.
The affected inventory is the deduplicated sorted union of that inventory,
all `spec/object_*spec.cr`, `binary_bulk_physical_prefix_w151_spec.cr` and specs
matching `ObjectDocument|ObjectRecursiveDeclaration|ObjectDeclaredDynamic|ObjectColumn|object_documents|JSONTypedPath|json_typed_path`.
Groups contain at most eight files; totals come from observed example results,
not file-count proxies. The manifests record exact membership, not merely
these selection rules.

### Finite independent stock qualification

Root ran `scripts/check_object_recursive_dynamic_w159.sh` through the guard
with 900 seconds/12288 MiB and `W159_EXECUTE_AS_ROOT=YES`, explicit Crystal/Ruby
executables and SDK. Both stages exit 0; evidence is retained at
`/private/tmp/crystal-click-object-recursive-dynamic-w159.lL5TDe`.
The producer executable is 26.10.1.1201, build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`, SHA256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
Source comparison remains the separate unbuilt shallow `895d13ea` checkout.

The stock-authored and independently library-authored complete parts use six
rows, three real marks plus a terminal mark, declared Array/Tuple/Map/direct
Dynamic, explicit Int64/String site rosters, single-stream String and BASIC
Dynamic/Map with Dynamic V3/Object V3 MAP. Array/Map String spills, a Tuple-right
Bool spill, empty arrays/maps and NULL are literal witnesses. Exact metadata
basenames/site keys and absent-statistics offset 10 are independently pinned.
Crystal public full/middle/zero reads pass; actual stock ATTACH, one active Wide
part, CHECK, nominal/runtime types and full/middle literal values pass.
Ruby independently rechecks retained raw stdout/stderr/SQL. A complete
library-authored 42-to-43 mutant ATTACHes and CHECKs, but fails the unchanged
original value oracle and passes only its separately mutant-aware control.

Other legal wrapper/actual-type combinations have spec evidence in this slice,
not new general stock-product qualification. Compact, COMPACT Variant,
bucketed/advanced shared data, other structure versions, unrestricted actual
arms, general MV/projection consumers and reader speed parity remain open.
Refresh after declaration policy, site/offset provenance, parser/codec,
statistics, binding/grid selection, budget, runtime/settings or toolchain
changes. Missing retained logs require rerunning gates, not promoting these
manifest hashes into substantive evidence. Keep unsupported profiles closed.
