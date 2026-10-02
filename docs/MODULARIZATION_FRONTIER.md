# CrystalClick Modularization Frontier

The October 2 LowCardinality binary grammar extraction is verified below:
one private concrete owner/file, unchanged physical admission and facade API.

Document status: W89 implemented and verified on the combined W88+W89 source;
W90 Array(Map) plan owners, W91 payload owners and W94 bounded Tuple owners
are verified below. The larger reader/writer modularization remains future work.
W95 high-level Tuple consumers are verified within their bounded profile in
`COMPOSITIONAL_TUPLE_FRONTIER.md`; their three new concrete owners remain
separate from the large existing facades.
The October 1 catalog owner extraction is verified below; it preserves the
existing API and behavior, not a completed responsibility-level architecture.
W113's private staged-stream lifetime owner is verified below for two existing
writer validators; it fixes qualified partial-acquisition leaks without moving
codec or publication policy into the new owner.
W114's Geometry model has separate arm, exact column descriptor, data and
row-handle files. Its later paired physical checkpoint adds eight concrete
owners, each in its own file, for the mark schedule, reader, serialization
profile, writer input/schedule/orchestrator and table/catalog adapters.
The final-source certificate is in `GEO_TYPES_FRONTIER.md`: focused DEBUG and
RELEASE each passed 138 examples, full DEBUG passed 1,886, the independent
stock/Crystal Geometry oracle and ten unchanged regression phases passed.
Exact seven-arm Geometry is now admitted within that profile; wrappers and
generic Variant widening remain rejected. The larger facade refactor remains
open. Source files alone do not prove lower coupling or performance.
Current navigation counts are 16,029 reader lines, 26,034 writer lines, 7,080
table lines, 1,560 catalog lines and 3,657 offline-table lines at W120
(`74a8752`, before the extraction below). The next cohesive
architectural boundaries remain shared type/substream planning, physical-stream
lifetime/validation, leaf codecs, staging orchestration and table/catalog
materialization; do not replace these with a Cartesian set of type combinations.
The October 1 private Variant discriminator extraction is verified below;
physical I/O, limits, marks and type admission remain with their prior owners.
W96 adds one closed numeric identity/width owner and extends the existing
Tuple owners; its compatibility certificate is separate in
`NUMERIC_TUPLE_FRONTIER.md`. It does not close the larger facade refactor.
W97's Bool extension uses those same Tuple owners with separate semantic Bool
dispatch; its bounded compatibility certificate is in `BOOL_TUPLE_FRONTIER.md`.
Bool is not added to the numeric identity owner or a per-combination Tuple class.

W98 reconciles the existing Bool value-domain policies under one shared owner;
its qualified RED and executed bounded compatibility certificate are recorded in
`BOOL_SEMANTICS_FRONTIER.md`. This is not completion of the facade refactor.

W99 extends named flat Tuple leaves to UUID/IPv4/IPv6 through one nominal
identifier owner/file and the existing Tuple reader/writer/model owners.
Focused DEBUG/RELEASE (162 examples each), full DEBUG (1,279 examples), the
new bidirectional stock oracle and seven unchanged regression oracles passed.
Root's scoped adversarial verdict and residual limits are recorded in
`IDENTIFIER_TUPLE_FRONTIER.md`; the larger facade refactor remains open.

W100 extends the same named-flat Tuple contracts to the raw temporal family.
Its six immutable value structs each have their own file, with one cohesive
temporal identity/parameter owner. The compatibility evidence and exclusions
are tracked separately in `TEMPORAL_TUPLE_FRONTIER.md`. Focused DEBUG/RELEASE
(259 examples each), full DEBUG (1,348 examples), the bidirectional temporal
oracle and eight unchanged regression oracles passed. Root's scoped verdict
is ROBUST; this is not completion of the larger facade refactor.

W103 adds paired scalar/Nullable QBit through twelve concrete owners, each
with its own source file. Its type, owned raw value, plane codec, physical
reader/validator, table adapter, writer input/infrastructure/orchestrator and
offline materialization boundaries are described in `QBIT_FRONTIER.md`.
Focused DEBUG and RELEASE each passed 41 combined QBit/PK examples; full DEBUG
passed 1,433 examples. The bidirectional 80-profile QBit stock oracle, its
3000-row split-plane control and five existing regression oracles passed.
Root's scoped verdict is ROBUST in `QBIT_FRONTIER.md`; this is not the full
facade refactor.

W104's timezone-qualified DateTime/DateTime64 extension is verified within its
pinned seven-shape profile: focused DEBUG/RELEASE each passed 431 examples,
full DEBUG passed 1,695, both 297-profile stock-oracle phases and six regression
oracles passed.
Its new declaration and timezone admission owners each have their own file;
the sealed scope, executed gates and residual limits are in
`TIMEZONE_TEMPORAL_FRONTIER.md`.
It does not claim completion of the larger facade refactor.

W105 adds one immutable `WideTupleLeafType` schema owner and one immutable
`ScalarNullMap` storage owner, each in its own file, for nullable scalar fields
inside named-flat Tuple. It preserves the closed raw carriers rather than
adding a per-family Cartesian set of `Array(T?)` buffers. Reader, writer and
table/catalog consumers use the same schema/mask contract. Focused DEBUG and
RELEASE each passed 537 examples; full DEBUG passed 1,719. Bidirectional stock
qualification, both timezone phases and ten unchanged Tuple/temporal/QBit
regression scripts passed. The scoped certificate, accessor migration and
logical-budget/RSS distinction are in `NULLABLE_TUPLE_FRONTIER.md`.
The larger facade decomposition remains open.

W106 introduces an immutable recursive named-Tuple schema node, recursive
serialization-metadata validator, and writer statistics/node-statistics owners,
each in its own file. The existing leaf buffers and codecs remain unchanged;
schema topology and physical path naming have one shared authority. Its paired
qualification and remaining exclusions are recorded in
`NESTED_TUPLE_FRONTIER.md`: focused DEBUG/RELEASE each passed 550 examples,
full DEBUG passed 1,732, and the new bidirectional stock oracle plus W105,
W104 and ten unchanged stock regression gates passed on frozen source.
This is not the full facade decomposition.

W107's bounded paired profile is verified in
`ARRAY_TUPLE_COMPOSITION_FRONTIER.md`. Its twelve new concrete production
owners each have one file: plan, ragged schedule, result/row handles, reader,
table/catalog adapters, writer input/orchestrator, shared leaf-mark schedule,
leaf dispatch and physical-value comparison. Physical outer-row marks are
adapted to flattened Tuple elements without copying scalar decoders; W106 and
W107 share the leaf stream writer. Focused DEBUG passed 581 examples; the
same 55 RELEASE inputs passed in disjoint 24/24/7-file batches (581 total);
full DEBUG passed 1,751. Paired W105/W106/W107 stock phases, all five affected
Tuple family stock scripts and the 297-profile W104 writer phase passed.
This is not a claim that the large facades or resource lifetimes have been
decomposed, nor a combined/full RELEASE certificate.

W108 adds ten concrete production owners, each with one file: Map(Tuple)
plan, ragged schedule, owned column data, row handle, reader, table adapter,
offline materializer, writer input and orchestrator, plus a shared internal
Tuple leaf decoder. The existing Tuple reader and Map keys delegate to that
one decoder; the leaf stream writer exposes one internal explicit-path seam
instead of duplicating a codec/width table. The new Map row identity and
outer/entry axes remain separate from Array(Tuple).

The scoped certificate is in `MAP_TUPLE_COMPOSITION_FRONTIER.md`: focused
DEBUG 25, regression DEBUG 82, the same 22 inputs split into two RELEASE
batches (31 + 51), full DEBUG 1,776, five-profile reader and writer stock
phases, six predecessor phases and five affected leaf-family stock scripts
passed. Root's scoped hostile verdict is ROBUST. This is not a combined/full
RELEASE, current-master executable, RSS or full architecture certificate.
The remaining facade counts are reader 15,585 lines, writer 25,920, table
6,889, catalog 1,560 and extracted OfflineTable 3,637. These are navigation
counts, not evidence of reduced coupling or performance. Cohesive physical
stream lifetime/policy, codec dispatch, staging and table responsibility
decomposition remains open.

W109 adds paired scalar Point through nine concrete owners, each in its own
file: raw value, exact type descriptor, serialization profile, physical reader,
table adapter, offline materializer, writer input, statistics and orchestrator.
It shares Float64 decoding, Tuple leaf framing, checksums and staging authority
instead of introducing a second codec or disguising Point as an unnamed Tuple.
Its bounded certificate is verified in `GEO_TYPES_FRONTIER.md`: final focused
and regression DEBUG/RELEASE each passed 83 examples, full DEBUG passed 1,793,
and both four-profile stock phases passed exact raw-bit/metadata/mark/PK,
fresh ATTACH CHECK=1 and literal full/selected RowBinary checks. Root's scoped
hostile verdict is ROBUST. The facade line counts at this fingerprint are
reader 15,764, writer 25,958, table 6,980, catalog 1,560 and OfflineTable 3,651.
The large facades still need responsibility-level decomposition; one owner
per file does not prove lower coupling or performance.

W111 adds paired depth-aware Geo arrays through eleven concrete owners, each
with one file: exact nominal/depth plan, immutable topology, owned data and
row handle, selected logical mark schedule, serialization envelope, reader,
table adapter, offline materializer, writer input and writer orchestrator.
It reuses Float64 codecs, physical framing, checksums and exclusive publication.
The shared internal `TupleLeafMarkSchedule.from_intervals` validates one
stream's contiguous interval schedule, not cross-depth topology; the Geo
owners retain that separate authority.

The executed bounded certificate is in `GEO_TYPES_FRONTIER.md`: final focused
DEBUG/RELEASE each passed 41 examples, full DEBUG passed 1,817, both W111
stock phases passed fifteen reader and ten writer profiles with forty asserted
CHECK=1 results, and six affected predecessor stock phases passed. Root's
scoped hostile verdict is ROBUST; full RELEASE, current-master executable,
RSS and performance are not certified.

The remaining navigation counts are reader 15,895 lines, writer 25,996,
table 7,026, catalog 1,560 and OfflineTable 3,654. Adding owner files has not
completed the requested responsibility-level decomposition. Shared recursive
type/substream planning, physical stream lifetimes and policy, codec dispatch,
staging, and table/materializer orchestration are still the relevant seams;
adding a separate class for every container/leaf combination is not the goal.
Any widening from today's exact plans needs its own storage-profile falsifier
and paired reader/writer evidence, not a name-only registration check.

W115 begins a general Object/Dynamic/shared-data track in
`JSON_GENERAL_STORAGE_FRONTIER.md`. The capture-only checkpoint changes no
production admission. Its proposed responsibility owners separate metadata,
binary type/value decoding, lane schedules, shared layouts and document
reader/staged writer orchestration; the larger facade decomposition is still
open and must not be replaced with one class per JSON declaration.

W117 implements the first reusable binary descriptor/scalar kernel under
that frontier. Six concrete owners each have their own file: nominal
type, owned value, limits, bounded codec context, descriptor codec and value
codec. Recursive Array/Nullable/Tuple/Map dispatch uses those owners rather than
one owner per type combination. Bulk streams, Dynamic schedules, Object shared
layouts, part admission and writer publication stay outside this kernel.
The owners range from 39 to 290 lines; recursive combinations share the same
dispatch rather than multiplying classes. Root executed 14 focused examples
in each of DEBUG/RELEASE, 1,921 full DEBUG examples, 36 pinned stock-writer and
36 stock-reader/re-emission vectors, and the unchanged six-part W116 regression
gate. All passed. The scoped hostile verdict is ROBUST for the default-bounded
scalar profile; full RELEASE, arbitrary type parameters, whole JSON/MergeTree,
RSS/performance and caller-raised stack limits remain unqualified. Exact
provenance, REDs, commands and certificate decay are in
`JSON_GENERAL_STORAGE_FRONTIER.md`. This implementation does not claim that
the large facades have been decomposed.

W118 adds five concrete responsibility owners, each in its own file: aggregate
binary-codec budget, detached MAP entry, ordered MAP row, three-lane snapshot
and paired decompressed shared-MAP codec. They range from 24 to 200 lines.
W117 delegates its logical counters to the shared budget and provides a narrow,
convention-internal borrowed-envelope seam; the ordinary APIs retain their
contract. There is no new owner per JSON declaration or nested combination.
Root executed 24 focused DEBUG and 24 RELEASE examples, 1,931 full DEBUG
examples, a three-profile/six-part exact stock lane comparison, and unchanged
W117/W116 regression gates. The scoped certificate and qualified budget,
allocation and comparator attacks are in `JSON_GENERAL_STORAGE_FRONTIER.md`.
Whole-document JSON, physical I/O, Object/Dynamic metadata and publication
remain outside these owners. The large facades and their line counts above
are unchanged; this is not completion of the requested architecture refactor.

W119 adds four concrete owners, each in its own file: immutable temporal
parameters, width-preserving Decimal parameters, detached Enum definitions,
and the scalar leaf descriptor codec. They range from 53 to 167 lines.
Recursive composition stays in `BinaryDataType`/`BinaryDataTypeCodec`; the
shared context owns preallocation and aggregate-budget checks. No owner is
created per container/leaf combination, and SQL-name normalization does not
replace binary nominal identity. Root executed 36 focused DEBUG and RELEASE
examples, 1,943 full DEBUG examples, 22 stock vectors in each direction and
the unchanged W117/W118/W116 gates. Three separately seeded allocation-guard
defects were detected and restored before final gates. The bounded certificate,
noncanonical Decimal inference falsifier and residual compatibility boundaries
are in `JSON_GENERAL_STORAGE_FRONTIER.md`. These owners extend only the binary
kernel, not table dispatch or whole-part writing. The large facade decomposition
is still open; file counts alone do not establish lower coupling or speed.

W120 adds ten concrete metadata responsibility owners, each in its own file:
one immutable shared statistic, positional/unordered-map statistics, Object
and Dynamic structures, three bounded codecs, paired owned models/streams,
and a shared-budget batch codec. They range from 46 to 171 lines. The existing
binary kernel is reused for recursive descriptors; no class is created per
JSON spelling or nested combination. Preallocation guards, raw-name ownership,
path/count alignment and permutation-independent shared-map equality/hash
have separate falsifiers. Root executed 54 focused examples in each of DEBUG
and RELEASE, 1,961 full DEBUG examples, all 20 retained stock structures and
three isolated authored-metadata ATTACH/CHECK=1 copies, plus unchanged W116-W119
regressions. These are complete decompressed metadata owners, not physical
value lanes, general JSON or a production part writer. Source/local-only legacy
and bucketed metadata boundaries, the qualified REDs and exact certificate are
in `JSON_GENERAL_STORAGE_FRONTIER.md`. The large reader/writer/table facades
are still open decomposition work; these additions do not certify lower
coupling, allocation footprint or speed for the overall engine.

## Variant discriminator owner extraction (2026-10-01)

Status: VERIFIED within the behavior-neutral extraction and executed gates
below over `fea5047`; no new type or storage-profile admission.
The user-requested facade decomposition starts with one bounded responsibility:
decoding an already-bounded Variant discriminator payload and canonical VarUInt.
Keep filesystem access, LZ4/mmap policy, mode-prefix validation, physical marks,
selected byte/row limits, child cardinalities and publication in their existing
owners. Geometry physical I/O remains the capability return pointer in
`GEO_TYPES_FRONTIER.md`, not an admitted consequence of sharing this decoder.

Plan (CAUTION; rollback is the isolated owner/require/delegation diff):

1. Characterize the existing VarUInt helper before source movement using
   `spec/wide_variant_discriminator_varuint_spec.cr`. Preserve its canonical,
   overflow, truncation and offset behavior, including existing error labels.
2. Add one private `WidePart::VariantDiscriminatorDecoder` owner in
   `src/crystal_click/wide_part/variant_discriminator_decoder.cr`. Move the
   existing bounded-payload tag decoding and VarUInt method bodies without
   policy changes. Keep the old facade helpers as delegation seams; the
   compatibility entry point must load the new owner itself.
3. Add a standalone owner-import test with only its declared prerequisites,
   so the aggregate library import cannot hide a missing dependency. Check
   BASIC, COMPACT mixed/uniform/NULL tags and malformed framing. Compare the
   moved bodies against the anchor in addition to behavioral checks.
4. Run focused DEBUG/RELEASE, full DEBUG and the unchanged W56/W57/W74/W75
   stock oracles serially through the existing memory guard, then inspect
   the frozen diff before one atomic local commit. No push is authorized.

Consumer inventory: `rg -n 'variant_read_var_uint|read_variant_discriminator_mark|variant_discriminator_mode' src spec scripts`
finds two Variant family consumers and fourteen Dynamic structure/mark
VarUInt call sites in `wide_part.cr`. The latter remain on their existing
COMPACT-only Dynamic policies; no generic Variant or Geometry admission is
implied. The strongest failure is a changed canonical VarUInt/error or tag
policy masked by valid fixture reads; standalone malformed-byte checks and
the existing checksum-consistent corruption tests are the guard.

DoD: the four `wide_part_reader_w{56,57,74,75}_spec.cr` inputs plus the new
characterization and standalone owner specs in DEBUG and RELEASE; full DEBUG;
`check_wide_variant_w{56,57}_oracle.sh` and `check_dynamic_w{74,75}_oracle.sh`;
formatter, exact-body reconstruction and diff checks. Focused/stock gates use
600 seconds / 8 GiB, full DEBUG 600 seconds / 32 GiB, always retaining the
50% free-memory floor. Success means unchanged values, rejection policies,
physical profiles and callback boundaries, not lower RSS, higher speed or
completion of the architecture refactor. Refresh after owner bodies,
prerequisites, facade delegation, admission or compiler changes.

### Executed discriminator checkpoint (2026-10-01)

Luna implemented the owner and standalone spec; root reviewed the frozen diff
and ran the gates independently. Before production movement, the four reader
inputs passed 36 examples in both DEBUG and RELEASE, and the new facade VarUInt
characterization passed five DEBUG examples against the unchanged anchor.

Observed after extraction, using Crystal 1.21.0 / LLVM 22.1.8 on arm64 macOS:

- The six focused inputs named above passed 50 examples in DEBUG and 50 in
  RELEASE, no failures/errors/pending.
- The standalone entrypoint alone passed nine examples in each mode. It
  imports only `spec` and the new owner, not the aggregate library.
- Full DEBUG passed 1,862 examples, no failures/errors/pending. Non-fatal
  duplicate-library and deprecated `blocking` test-hook warnings were observed.
- All four unchanged stock oracles exited 0 on pinned ClickHouse
  26.7.1.1315: W56/W57 Variant and W74/W75 Dynamic, with asserted ATTACH/CHECK,
  independent full/selected RowBinary, and each script's physical-profile
  checks. The scripts, predecessor reader specs and type-plan file remain
  unchanged against `fea5047`; these results do not upgrade the executable
  certificate to the fresh master source.
- Exact facade reconstruction matched `fea5047` after restoring the two old
  helpers and removing the new require. Moved bodies matched after normalizing
  indentation/blank lines and the one internal VarUInt method rename. A seeded
  error-label mutation was rejected by the comparison. All fourteen Dynamic
  call sites still use their original facade helper.
- Root's formatter and diff checks passed. The frozen four-file fingerprint is
  `7a7550ee2e81a22115c8975f17f0f847276d44f43bcbf445c283cca636789e81`:
  SHA-256 of ordered `shasum -a 256` output for `src/crystal_click/wide_part.cr`,
  `src/crystal_click/wide_part/variant_discriminator_decoder.cr`,
  `spec/wide_variant_discriminator_varuint_spec.cr`, then
  `spec/wide_variant_discriminator_decoder_entrypoint_spec.cr`.

Root's scoped hostile verdict is ROBUST: the existing canonical integer,
tag/framing errors, physical prefix/mark/row limits and publication/callback
boundaries are preserved by the reconstruction and executed tests. Direct
private-decoder calls assume already-bounded input and validated mode; the
facade remains that authority, not a new public decoder API. Full RELEASE,
peak RSS, throughput, all-type compatibility and the complete facade refactor
are not certified. The next capability frontier remains physical Geometry;
remaining architecture seams include bounded stream lifetimes, codec dispatch,
writer preflight/staging/publication and table/materializer orchestration.

## Active type-plan owner extraction (2026-10-01)

Status: VERIFIED within the mechanical extraction and executed gates below
over `951b5d7`; this is a behavior-preserving source-owner
extraction, not the proposed authoritative physical-plan migration below.
W114 Geometry qualification remains the capability return pointer.

Keep `WideTypePlan`, its exact admission helpers and enums in
`src/crystal_click/wide_type_plan.cr`. Move its existing nested concrete owners
without method-body changes into these files, preserving their constant paths:

- `wide_type_plan/physical_substream.cr`
- `wide_type_plan/wide_physical_plan_shadow.cr`
- `wide_type_plan/wide_physical_plan_shadow/axis.cr`
- `wide_type_plan/wide_physical_plan_shadow/stream.cr`
- `wide_type_plan/wide_physical_plan_shadow/builder.cr`

The original file remains the compatibility entry point and loads the extracted
owners. Reopening namespaces must retain lexical constant lookup and the
Builder's private visibility. No type, codec, stream naming, mark/cardinality
axis, buffer policy or public API changes are admitted by this extraction.

Risk: CAUTION (source movement and require/visibility boundaries). Rollback is
the isolated owner/require diff over the Git anchor. The likeliest failure is
a changed lexical lookup or dropped method masked by an aggregate require.
Guard by reconstructing every moved declaration against the anchor, checking
the old entry point under its existing prerequisite imports, and retaining
exact unsupported-neighbor admission tests. Parsing and shadow success must
not become codec authority.

DoD: baseline and extracted focused DEBUG/RELEASE runs of the thirteen
`wide_type_plan_w{67,69,70,71,73,78,79,80,81,82,83,84,85}_spec.cr` inputs,
`wide_array_tuple_w107_admission_spec.cr` and `wide_part_reader_w51_spec.cr`,
plus the standalone `wide_type_plan_entrypoint_spec.cr` without the aggregate
require, full DEBUG, formatter and diff checks. Execute compiler gates serially
through the existing 600-second memory guard: 8 GiB for focused/entry-point
runs and the established W113 32-GiB limit for full DEBUG, with the 50% free
memory floor retained. A source reconstruction
match and entry-point check are required in addition to green behavioral
tests. A stock serialization rerun becomes necessary if reconstruction finds
any substantive method change; do not silently treat that as mechanical work.
Root independently reviews the frozen diff and executed signals before the
atomic local commit. No smaller file count, coupling or performance claim
follows from this navigation improvement alone.

Executed certificate on the frozen October 1 source:

- Baseline focused DEBUG and RELEASE each passed 36 examples. The new
  standalone entry-point regression also passed its two examples before
  extraction, with only the historical prerequisite imports.
- Extracted focused DEBUG and RELEASE each passed 38 examples (the same
  fifteen inputs plus the new entry-point spec). Standalone entry-point
  DEBUG and RELEASE each independently passed two examples, without
  `spec_helper` or the aggregate library import.
- Full combined DEBUG passed 1,839 examples, no failures/errors/pending,
  under the established 32-GiB guard. Two initial 8-GiB attempts terminated
  during compilation, before tests; removing symbolic debug information
  did not resolve that limit. These are not failed tests or a reader-memory
  result. The successful command restored W113's existing full-suite recipe.
- Root reconstructed all five moved declarations and the retained entry
  declarations against `951b5d7`, ignoring only leading indentation and
  blank lines: six exact matches. PhysicalSubstream is the anchor's lines
  29-52; Axis 81-87; Stream 89-119; private Builder 364-557. The remaining
  shadow is lines 54-558 minus those nested owners. The entry point retains
  every other declaration and adds only the five trailing imports.
- Formatting and diff checks passed. The frozen six-source-file fingerprint
  is `256da02399ec2254ec84945cb058da2d20a8a8f905b848de15b44538e2738a35`:
  SHA-256 of ordered `shasum -a 256` output for the entry point followed by
  the five paths above. The new spec SHA-256 is
  `7896b052d32992964f37e8b8dee449b9ba37c34547d6ef82a7a2bbaeb7bc4215`.

Replay the standalone checks and full DEBUG serially using the SDK/cache/free
floor environment from W113; focused replay uses the fifteen inputs named
above plus `spec/wide_type_plan_entrypoint_spec.cr`, once without and once
with `--release`:

```sh
/bin/bash "$guard" "$compiler" 600 8192 spec --single-module --link-flags=-fuse-ld=ld spec/wide_type_plan_entrypoint_spec.cr
/bin/bash "$guard" "$compiler" 600 8192 spec --release --single-module --link-flags=-fuse-ld=ld spec/wide_type_plan_entrypoint_spec.cr
/bin/bash "$guard" "$compiler" 600 32768 spec --single-module --link-flags=-fuse-ld=ld
```

Root's scoped hostile verdict is ROBUST: declarations and lexical namespaces
are preserved; a separate import check prevents the aggregate require from
masking missing owners; exact shadow-only and unsupported-neighbor controls
remain closed. This is not full RELEASE, new serializer admission, a shared
authoritative plan, facade decomposition, reduced coupling, RSS or performance
evidence. Refresh on owner bodies, namespace/import graph, admission or compiler
changes. W114 stock qualification remains the next capability falsifier.

## Proposed shared physical-plan boundary (2026-10-01)

Status: PROPOSED after source inspection at `3e36d5c`; not implementation or
broader type admission. W114 Geometry qualification remains the active return
pointer in `GEO_TYPES_FRONTIER.md`. Do not replace that frontier with a generic
recursive-type rewrite before its stock controls and public refusal are sealed.

`wide_type_plan.cr` already separates syntax parsing, five exact legacy
admissions and a correctness-only `WidePhysicalPlanShadow`. The shadow models
storage/cardinality/mark-row axes and stream widths, but explicitly does not
authorize codecs. Tuple, Array(Tuple) and Map(Tuple) plans have overlapping
stream responsibilities. `WidePart` independently classifies typed support,
open-time inventory and empty EOF rules, primary streams, widths and selected
range handling. Table preflight and catalog materializers separately choose
semantic consumers. These observed repetitions motivate one physical authority;
they do not prove that the current shadow can become that authority unchanged.

Candidate dependency direction: syntax node -> explicit admitted nominal
schema/profile -> immutable physical plan -> stream/range readers and writers.
Row/value semantics, aggregate budgets and publication remain separate owners.
Each concrete owner belongs in one file; do not introduce a class for every
container/leaf combination or make parsing success mean physical support.

Before migration, pin the following discriminators:

- A parseable neighbor such as `Array(Tuple(a UInt8))` still fails typed
  admission and any authoritative physical-plan factory until separately
  qualified. The syntax parser may continue to accept it.
- For one existing qualified composition, the new plan must match ordered
  streams, widths, storage/cardinality axes and true physical mark-row axes.
  The same descriptor must drive open-time inventory, primary stream, empty
  EOF classification and selected validation; absent child streams are a
  required counterexample rather than a skipped boundary.
- Full, selected, lazy and catalog consumers must retain nominal value
  semantics and one aggregate budget. A shared physical descriptor alone
  cannot certify these higher-level contracts.

First migrate one already-qualified composition end to end, preserving old
dispatch/accessors as regression controls; require focused DEBUG/RELEASE,
affected stock read/write and hostile neighbor/empty-stream checks before
removing duplicated classification. Risk is CAUTION; rollback is the isolated
owner and consumer diff over its then-current Git anchor. Exact files, APIs
and execution commands must be sealed in that migration's own frontier before
production edits. This proposal does not certify lower coupling, RSS or speed.

## Catalog owner decomposition (2026-10-01)

Status: VERIFIED within the source-owner extraction and executed gates below.
Baseline is `5c291c8117a3cec72cb51f84dde73ac0d73a6e77`.
The original `offline_catalog.cr` has 5,395 lines and combines column-value
aliases, three public metadata structs, table access, column selection,
database navigation and catalog discovery/DDL parsing. The first extraction
separates those existing owners; it does not introduce new types, change
serialization, or claim that the table/catalog responsibilities are fully
decomposed.

Risk: CAUTION (large mechanical move and aggregate require integration).
Rollback is the exact owner-file extraction and require changes; no data,
dependency, publication or remote-history operation is involved. Preserve the
separate proposed Map(Tuple) frontier rather than mixing it into this commit.

Plan:

1. Keep `OfflineCatalog` in `offline_catalog.cr`; move its private
   `DatabaseLocation` model to `offline_catalog/database_location.cr` with
   identical namespace and visibility.
2. Give `OfflineColumn`, `OfflineProjection`, `OfflinePartCandidate`,
   `OfflineTable`, `OfflineColumnSelection`, and `OfflineDatabase` one file
   each under `src/crystal_click/`. Move aliases to `offline_column_value.cr`.
3. Preserve declarations, comments and method bodies, allowing only enclosing
   namespace/require integration and boundary blank lines. Keep metadata-only
   lookup, lazy scans, owned value materialization, candidate-versus-Active
   semantics and all bounds unchanged.
4. Integrate the aggregate require graph, then compare the reconstructed
   owners with the baseline. The strongest failure mode is a dropped private
   method, visibility change or missing require hidden by a focused test.
5. Execute the seven focused catalog/MV/projection/TUI specs in DEBUG and
   RELEASE, full DEBUG, and the W86/W87/W88 stock oracles. Check format and
   staged diff hygiene, inspect the exact diff, and make one local commit.

The original aggregate import in `src/crystal_click.cr` is unchanged.
`offline_catalog.cr` remains the compatibility entry point and requires the
seven public/alias owners plus the private nested `DatabaseLocation` owner.
`OfflineCatalog` now occupies 1,560 lines; the moved `OfflineTable` still
occupies 3,615 lines and is not a responsibility-level decomposition.

Executed certificate (2026-10-01, Crystal 1.21.0, ClickHouse 26.7.1.1315):

- Baseline seven-file DEBUG: 113 examples, zero failures/errors/pending.
- Post-extraction same seven files in DEBUG and RELEASE: 113 examples each,
  zero failures/errors/pending, exit 0.
- Full DEBUG: 1,751 examples, zero failures/errors/pending, exit 0. The linker
  emitted a non-fatal duplicate `-lc` warning. Full RELEASE was not executed.
- W86 stock metadata oracle: persisted MV/table kinds, exact DDL and named
  projection metadata agree with stock-generated files, exit 0.
- W87 stock projection oracle: both child parts and the four-row catalog scan
  agree with ClickHouse; the incomplete projection set rejects before
  callbacks, exit 0. Stock `CHECK TABLE` returned 1 for both source parts.
- W88 stock MV oracle: stock trigger control and Crystal detached identity
  recomputation pass; the generated part passes stock `ATTACH PART`,
  `CHECK TABLE` and exact source/target row comparison, exit 0.
- Complete source reconstruction from all eight extracted files and the
  remaining catalog matches every nonblank baseline line, including comments,
  constants, declarations and visibility. A seeded identifier drift is
  rejected by that guard. Blank-line normalization is not a behavioral proof.
- `crystal tool format --check` on all nine source files and diff hygiene pass.

The focused inputs are `spec/offline_catalog_spec.cr`,
`spec/offline_catalog_w86_spec.cr`,
`spec/offline_catalog_projection_w87_spec.cr`,
`spec/wide_part_table_projection_w87_spec.cr`,
`spec/offline_mv_materialization_w88_spec.cr`,
`spec/offline_catalog_w95_tuple_values_spec.cr`, and
`spec/offline_tui_page_source_spec.cr`. From the repository root, the executed
commands used `crystal spec --single-module --link-flags=-fuse-ld=ld` with
those inputs, then the same invocation with `--release`, and finally the
DEBUG invocation without explicit spec paths. Stock commands were
`bash scripts/check_offline_schema_w86_oracle.sh`,
`bash scripts/check_projection_w87_oracle.sh`, and
`bash scripts/check_mv_materialization_w88_oracle.sh`.

Heavy gates ran serially through
`/Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh`, with a 600-second
limit, 8 GiB focused/stock limit (32 GiB full DEBUG), and a 50% free-memory
floor. Both `CLICKHOUSE` and `CLICKHOUSE_BIN` selected
`/Users/sergey/.local/bin/clickhouse`; Crystal was
`/opt/homebrew/bin/crystal`. The isolated cache was
`/private/tmp/crystal-click-catalog-refactor-cache`; stock scripts used their
own temporary caches. The host SDK was MacOSX26.5 and the system linker
override above was retained. No current-master binary qualification is claimed.

Frozen source fingerprint: SHA-256 of the newline-terminated
`shasum -a 256` manifest, in the plan order (catalog, aliases, column,
projection, candidate, table, selection, database, private location), is
`5fc3cdf73efc848fc9fd769a3856f94f5b56ee6779f4de6b9d4d784d98b6076b`.
All nine paths are under `src/crystal_click/`; the remaining catalog and
eight owner files are the complete production scope of this extraction.

Root's scoped adversarial verdict is ROBUST: reconstruction and its seeded
negative control address lost bodies/declarations; aggregate compilation,
runtime tests and stock probes address require integration and observable
regressions. A Luna read-only static review also found no visibility or import
widening; that correlated review alone is not independent runtime evidence.
This certificate expires on affected source, require graph, compiler, binary
or fixture/profile changes; rerun the affected identity and behavioral gates.

Further responsibility extraction remains open: offline DDL parsing,
selected-value materialization, physical-stream lifetimes, leaf codecs and
reader/writer orchestration. One owner per file alone does not prove lower
coupling, lower memory use, better throughput or full ClickHouse compatibility.

## W104 ownership boundary

`DateTimeColumnType` owns exact temporal family, precision, timezone provenance
and the six existing scalar/Nullable/Array shapes. `TimezoneName` owns a copied
admitted token; the private `ClickHouseTimezoneCatalog26_7_1_1315` owns the
versioned pinned name manifest. Each concrete class has one source file.
Persisted parsing is strict, while catalog-only parameter normalization is a
separate entry point. No host timezone lookup or duplicate temporal codec is
introduced.

Named-flat Tuple field/plan/leaf owners retain the scalar descriptor and
share it through owned row/column snapshots. Raw DateTime value structs are
unchanged: timezone provenance belongs to the schema, not each raw value.
The plan bills the actual field slot and retained descriptor independently
of physical width. This logical budget is not a peak-RSS certificate.

Reader, writer and high-level consumer facades use the shared recognizers;
their existing mark/checksum/stream-lifetime and publication infrastructure
remain in place. The new owners and Tuple snapshots defend their String
exports, but older facade String exports are not universally hardened here.
Whole-facade decomposition, generic recursive types and performance remain
open. Adding three class files is not evidence of lower coupling or faster
execution.

## W113 verified staged-stream lifecycle extraction

Status: VERIFIED within the two-validator lifecycle scope below on the isolated
W113 diff over `4cb8d02` (2026-10-01). The remaining facades contain 15,895
reader, 25,998 writer, 7,026 table and 1,560 catalog lines; extracted
`offline_table.cr` contains 3,654. These navigation counts do not measure
coupling or performance and do not close the larger facade refactor.

The narrow responsibility is staged stream-file lifetime, not another codec
or a mechanical relocation of whole facades. At the qualified predecessor,
`WidePartWriter.validate_staged_array_map_array_numeric_part` opened data and
mark files before the cleanup region. In
`validate_staged_array_map_bool_leaf_streams`, the values pair and optional
null pair were likewise acquired before `begin/ensure`. A later open error
could therefore bypass explicit closure of earlier acquired handles. Root ran
`scripts/probe_staged_stream_lifetime_w113.cr qualify` against the writer code
retained at `4cb8d02`: exit 0, six earlier real handles remained open on the
numeric path and three on the Nullable(Bool) path. The injection intercepts
one exact stage-local `.mrk2` open; both public writer calls propagated the
same original sentinel exception and left no destination or stage. The probe
counts actual handles before closing its own retained handles in `ensure`.
The separate `red` mode expected zero open handles and intentionally exited 1,
with the same qualified six/three counts. No missing future class or compiler
error was used as the behavioral RED.

Sealed owner: one `StagedStreamFileSet` class in
`src/crystal_click/wide_part_writer/staged_stream_file_set.cr`. It owns only
ordered acquisition and closure, including partial acquisition and a failing
validation block. Validators depend on this owner; the owner depends only on
standard file I/O, not the writer, reader, table or catalog. Path/hash selection,
stream order, frame/mark/sentinel checks, metadata, staged readback and exclusive
publication stay with their existing owners. Cleanup must attempt every owned
handle and must not mask the original open or validation error. Construction
is private and the only consumer access is ordered `file_at`; no mutable
array of owned handles is exported. On successful validation a cleanup error
may be reported only after attempting every close. On open/body failure the
original exception identity has precedence over any cleanup failure.

Risk: CAUTION (resource lifetime and exception propagation). Rollback: the
isolated new owner, two call sites, aggregate require and related tests/docs;
the W84 oracle fixture repair has no production dependency. Path selection,
acquisition order, physical checks and publication retain their existing
contracts. The strongest anticipated failure was an owner that closed only
after complete acquisition, masked the original exception, or stopped cleanup
at the first close failure.

Root executed the following gates on frozen production and spec source:

- The focused owner plus W83/W84/W85 writer specs passed DEBUG and RELEASE:
  14 examples in each configuration, no failures/errors/pending. The six
  owner examples test each acquisition position, successful ordered reads,
  body failure, genuine `break` exit, close-error continuation, and original
  exception identity/first-cleanup-error precedence.
- The same public writer probe in `red` mode now exits 0: zero earlier real
  handles remain open on either path (qualified predecessor: six and three),
  with exactly one injected open error, unchanged exception identity, and
  no destination or stage after either failure.
- Pinned ClickHouse 26.7.1.1315 stock writer oracles W83 (eight populated/
  all-empty Bool-family cases), W84 (four populated and four all-empty exact
  types plus the matrix fixture), and W85 (twenty exact numeric leaf types)
  exited 0. They retain literal raw-stream/mark expectations, fresh
  `ATTACH PART`, actual tab-separated successful `CHECK TABLE` contents,
  and full/keyed RowBinary comparisons. W84 `full` also exited 0 on a second
  fresh store, including direct/typed-table selected reads and the seeded
  selected-mark rejection before callbacks. Its fixture lifecycle repair is
  recorded in `EMBEDDED_MERGETREE_FRONTIER.md`.
- Full DEBUG passed 1,837 examples, no failures/errors/pending. This is not a
  full RELEASE certificate. Formatting, shell syntax and diff checks passed.
  The test-only File interception produces a deprecated `blocking` argument
  warning on Crystal 1.21; it is not a production API change.

Replay commands (run serially from the repository under the existing memory
guard; the local SDK and compiler paths describe the executed host):

```sh
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
export TMPDIR=/private/tmp
export CRYSTAL_CACHE_DIR=/private/tmp/crystal-click-w113-cache
export COGNI_RUN_SAFE_MIN_FREE_PCT=50
guard=/Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh
compiler=/opt/homebrew/bin/crystal
/bin/bash "$guard" "$compiler" 600 8192 spec --single-module --link-flags=-fuse-ld=ld spec/staged_stream_file_set_w113_spec.cr spec/wide_part_writer_w83_spec.cr spec/wide_part_writer_w84_spec.cr spec/wide_part_writer_w85_spec.cr
/bin/bash "$guard" "$compiler" 600 8192 spec --release --single-module --link-flags=-fuse-ld=ld spec/staged_stream_file_set_w113_spec.cr spec/wide_part_writer_w83_spec.cr spec/wide_part_writer_w84_spec.cr spec/wide_part_writer_w85_spec.cr
/bin/bash "$guard" "$compiler" 600 8192 run --single-module --link-flags=-fuse-ld=ld scripts/probe_staged_stream_lifetime_w113.cr -- red
/bin/bash "$guard" "$compiler" 600 32768 spec --single-module --link-flags=-fuse-ld=ld
W83_ORACLE_MODE=writer /bin/bash "$guard" /bin/bash 600 8192 scripts/check_array_map_bool_values_w83_oracle.sh
W84_ORACLE_MODE=writer /bin/bash "$guard" /bin/bash 600 8192 scripts/check_array_map_array_w84_oracle.sh
W84_ORACLE_MODE=full /bin/bash "$guard" /bin/bash 600 8192 scripts/check_array_map_array_w84_oracle.sh
W85_ORACLE_MODE=writer /bin/bash "$guard" /bin/bash 600 8192 scripts/check_array_map_array_w85_oracle.sh
```

Root's scoped adversarial verdict is ROBUST: independently observed real
handle closure, exception identity, all-close attempts, early exit and the
unchanged physical stock contracts support this narrow lifecycle claim.
Luna supplied implementation and a correlated read-only static review;
their agreement is not independent runtime evidence. The close-error test
shim raises only after real native closure: it proves continuation and error
precedence, not that an actual OS close failure releases its descriptor.
No universal writer lifetime, arbitrary block escape, artifact inventory,
serialization widening, memory/RSS or throughput certificate follows.
Evidence expires on the affected owner, call sites, require graph, File I/O
semantics/compiler, fixture expectations or pinned runtime/profile changes;
rerun the corresponding failure probes and stock gates before reuse.

Adjacent artifact-integrity residual observed during W107 static review:
`wide_part_writer/tuple_part_writer.cr#validate_staged_part` verifies the exact
checksums entry set and expected metadata contents, but does not compare the
complete `Dir.children(stage)` inventory. This is also present at predecessor
`63e03b4`; W107's `ArrayTuplePartWriter` does perform that complete comparison.
No ordinary extra-file injection path or payload/mask/schema-check bypass was
found. A separate hardening slice must first seed an unexpected unchecksummed
stage file, establish its observed disposition, then qualify rejection and
scratch-only cleanup before changing that publication boundary.

Physical reader lifetime, leaf codecs, table scan adapters and catalog
parsing/navigation remain separate larger responsibility extractions.

## W103 ownership boundary

`QBitType` owns the closed element identity and dimension/stride grammar;
`QBitColumnType` owns bounded physical planning and logical materialization
charges. `QBitValue` owns exact raw element bytes, with defensive export and
raw-bit equality. `QBitPlaneCodec` alone owns transpose/untranspose bit order.
These are four separate files, not a new per-carrier class hierarchy.

`QBitSerializationProfile`, `QBitStreamValidator` and
`WidePart::QBitReader` own physical profile admission, metadata-only schedule
validation and selected-range decoding in three files under `wide_part/`.
The lower reader never depends on a table adapter. The separate
`QBitColumnAdapter` consumes that lower-layer contract, and
`QBitValuesMaterializer` bounds the actual offline union slot
charge before allocating `.values`. Neither adapter owns a second plane codec.

The writer's `QBitPartWriteInput`, `QBitPartInfrastructure` and
`QBitPartWriter` each have one file under `wide_part_writer/`. Input capture,
physical callbacks and stage orchestration remain separate. The writer uses
the existing bounded frame/marks/checksum/exclusive-publication helpers via
narrow facade delegates and validates real staged bytes before publish; the
test seam cannot replace its validator. QBit does not enter the named-Tuple
leaf union or imply arbitrary recursive compositions.

The existing four facades still own shared infrastructure and orchestration.
Physical-stream lifetime/validation ownership, cohesive leaf-codec extraction,
table/catalog orchestration and the older Array(Map) intermediate-file-open
cleanup concern remain open. New owner files and shorter navigation paths do
not establish reduced coupling, lower peak RSS or improved throughput.

## W100 ownership boundary

`DateValue`, `Date32Value`, `DateTimeValue`, `DateTime64Value`, `TimeValue`
and `Time64Value` retain nominal identity rather than relabeling UInt16,
Int32, UInt32 or Int64. Scaled values carry validated precision with their
raw ticks. `src/crystal_click/wide_tuple_temporal_type.cr` owns the closed
declarations, exact parameters, physical widths, actual owned slot sizes,
raw/precision equality, buffer compatibility and qualified raw-zero storage
default predicate. Calendar conversion and byte encoding do not belong to
this owner; temporal values do not enter `WideTupleNumericType`.

`WideTupleLeafColumn` retains exact metadata even for empty temporal buffers;
the existing plan owns streams and aggregate charges. `TupleReader` and
`TuplePartWriter` receive one temporal callback each and reuse the existing
primitive LE codecs through narrow facade adapters. The writer takes one
owned values snapshot, validates every row/precision before staging and
checks exact nominal values during staged readback. Table/catalog continue
through `WideTupleColumnData` and the single `WideTupleRow`; no production
table/catalog edits, per-arity class or Cartesian combination union are added.

At the frozen W100 production source, reader/writer facades contain 15,301
and 25,359 lines, with table/catalog at 6,638 and 5,309. These navigation
counts are not evidence of lower coupling, lower memory or faster execution.
The larger facade decomposition, physical-stream lifetime/validation owner,
cohesive leaf-codec extraction and table/catalog orchestration remain open.
The older Array(Map) intermediate-file-open cleanup concern and bounded
Tuple readback allocation are unchanged. Each future extraction still needs
a behavior-preserving contract and one concrete owner per file.

## W99 ownership boundary

`src/crystal_click/wide_tuple_identifier_type.cr` owns the closed UUID/IPv4/
IPv6 identity set, exact widths, raw-bit equality and zero-default predicate.
The nominal wrappers do not enter `WideTupleNumericType`. The root require
graph loads their shared owner after scalar wrappers and before Tuple plan/
value owners. Leaf buffers retain exact wrapper arrays; the existing plan
owns streams/charges and the existing reader/writer orchestrators keep their
separate identifier callbacks. Scalar payload encoding and LE/BE primitives
remain the original physical owners, not duplicated Tuple serializers.

`WideTupleColumnData` and the single `WideTupleRow` already consume the owned
leaf contract. Table/catalog need no parallel identifier dispatch, new
per-arity class, Cartesian combination union or production edits. This is a
bounded owner-contract extension, not general recursive type admission.

At the frozen W99 production source, reader/writer facades contain 15,244 and
25,326 lines; table/catalog remain at 6,638 and 5,309. The facades grew through
narrow adapters and are not decomposed by this slice. Navigation counts do
not prove performance or lower coupling. Physical-stream lifetime/validation,
cohesive leaf-codec ownership and table/catalog orchestration remain open,
with one concrete owner per file and behavioral gates for each extraction.
The older Array(Map) intermediate-file-open cleanup concern and bounded
Tuple readback allocation are unchanged.

## W98 ownership boundary

`src/crystal_click/bool_value_codec.cr` owns UInt8-to-Bool semantic decoding,
canonical Bool-to-UInt8 encoding, and owned bulk decoding. Root, nullable,
Array, Array(Map), Variant and named-Tuple consumers delegate to this one
module/file; null-map and discriminator policies remain with their structural
owners. Bool stays outside the numeric identity owner.

The writer reuses bounded per-mark frame/mark/sentinel validation rather than
adding whole-stream reads. Tuple orchestration receives the actual Bool raw
validator through its existing infrastructure owner. Those staging helpers
still live in the large writer facade; they are not a new decomposed physical
stream subsystem. File-size reduction and independent ownership of the full
reader/writer/table/catalog remain open, separately from W98's value-domain
compatibility certificate. Focused DEBUG/RELEASE (168 examples each), full
DEBUG (1,259 examples), the new nine-profile bidirectional oracle and five
unchanged stock oracles passed; root's scoped adversarial review is ROBUST.
These gates and residual risks are recorded in `BOOL_SEMANTICS_FRONTIER.md`.

At the frozen W98 source, the reader/writer facades still have 15,195 and
25,295 lines, with table/catalog at 6,638 and 5,309. These navigation counts
do not establish performance or lower coupling. The next architectural slices
remain physical-stream lifetime/validation ownership, cohesive leaf codecs and
table/catalog orchestration, one concrete owner per file with behavior-preserving
contracts. In particular, W98 does not close the older Array(Map) validator's
intermediate-file-open cleanup concern or Tuple's bounded readback allocation.

## W97 ownership boundary

`WideTupleLeafColumn` owns native Bool buffers alongside, but nominally separate
from, numeric and String buffers. `WideTupleTypePlan` owns one-byte Bool stream
planning and logical charges. `TupleReader` and `TuplePartWriter` orchestrate
their existing bounded stream infrastructure, while narrow private facade
delegates provide nonzero-aware reading and the existing canonical Bool codec.
`WideTupleRow` remains the single table/catalog row representation. No new
production class or import-order change is needed for this extension.

At the historical W97 source, reader/writer facades contain 15,223 and 25,134 lines; table
and catalog remain at 6,638 and 5,309. W97 does not claim to have decomposed
these facades. A next compatibility slice should reconcile root/Array/container
Bool's strict 0/1 read policy with the stock-supported nonzero domain, then
give the shared Bool leaf policy a cohesive owner with its own file. Broader
leaf-codec, physical-stream-context, metadata and table orchestration ownership
remains open. File counts and shorter files alone do not prove lower coupling.

## W96 ownership boundary

`src/crystal_click/wide_tuple_numeric_type.cr` owns the exact primitive numeric
identity set, widths, raw-bit equality and bounded default predicate in one
module/file. It is not a second byte codec. `WideTupleTypePlan` consumes that
contract, `WideTupleLeafColumn` owns concrete typed buffers, and the existing
`TupleReader`/`TuplePartWriter` owners orchestrate them through narrow private
delegates to existing scalar payload codecs. `WideTupleRow` remains one nominal
row representation for table and catalog consumers rather than an arity/type
Cartesian union.

The root require graph loads the numeric owner after the primitive wrapper
types and before Tuple plan/value owners. Legacy UInt64/String overloads and
exact-pair APIs remain guarded. Source ownership and shared payload dispatch
are architectural facts; only W96's executed tests/oracles establish its
bounded behavioral compatibility. Same-lineage static reviews are correlated.

The final W96 reader and writer facades still have 15,200 and 25,122 lines;
table and catalog have 6,638 and 5,309. These counts expose the remaining
navigation burden, not a performance metric or proof of coupling. Continue
with owner-by-contract slices and one concrete type per source file; do not
replace them with a mechanical multi-class file split or mix deferred memory
optimization into compatible-type admission.

## Problem and boundary

At `26ab2a2`, `wide_part_writer.cr` has 25,905 lines, `wide_part.cr` 14,989,
`wide_part_table.cr` 6,583, and `offline_catalog.cr` 5,283. File count alone
does not establish modularity: extraction must give each class one source file
and separate a responsibility with an independently checkable contract.
The committed W88 MV materializer owns `offline_catalog.cr` and its tests;
W89 must not mix with that storage behavior change.

## W89 admitted design

Move the bounded ClickHouse type-expression grammar out of the body of
`wide_type_plan.cr`. Create one source file each for `WideTypePlan::Node`,
`WideTypePlan::Parser`, and the new `WideTypeExpression` facade. Retain the
original nominal Node/Parser identities, not just aliases: public reflection
and diagnostics can observe their canonical names. The parser handles syntax,
parse limits, and AST construction only. `WideTypePlan` continues to own
physical substreams and exact admission policy, and keeps its existing
`.parse` method as a delegate to `WideTypeExpression`. The facade may expose
aliases back to the original Node/Parser types. Require node, parser, facade,
then `wide_type_plan.cr` in `src/crystal_click.cr`. Each concrete type owns its
methods in one file; the `WideTypePlan` namespace is reopened only to declare
its nested types.

Reject for W89: newly admitted ClickHouse types, changed parse trees or
limits, generic codec dispatch, changed on-disk bytes, changed public typed
table accessors, performance claims, and a mechanical redistribution of the
large reader/writer modules into multi-class files. These need separate
behavioral and compatibility slices.

Guard-only next boundary: the W80-W85 `Array(Map)` physical-plan builders in
`wide_part_writer.cr`: `array_map_string_uint64_physical_plan`,
`array_map_string_physical_plan`, `array_map_numeric_physical_plan`,
`array_map_array_physical_plan`, and
`array_map_array_numeric_physical_plan`. They form a roughly 661-line cluster
of private plan descriptors, builders, and axis comparison, separate from the
public writer facade and byte serializers. Extracting cohesive builders into
one class per file could remove plan ownership from the 25,905-line writer
without changing on-disk bytes. This needs its own exact stream/role/axis
falsifiers, W80-W85 writer/type-plan specs, available stock ClickHouse oracles,
and a separate commit; it is not admitted by W89's green parser tests. Moving
the already-small map-row adapters out of `wide_part_table.cr` is lower risk but
mostly improves navigation, not class responsibility. The borrowed batch
view, reader leaf codecs, and writer serializers need later owner-by-contract
slices. Do not treat lower lines-per-file as proof of lower coupling.

## Falsifiers and execution plan

Risk: CAUTION. The strongest failure is a changed AST nominal identity or
require order that silently changes exact admission. A first implementation
that moved the definitions under `WideTypeExpression` passed 35 focused and
1,115 debug examples, but hostile review found its aliases changed canonical
type names. That route is rejected despite green tests; preserve the original
`WideTypePlan::Node` and `::Parser` definitions in separate files. Rollback is
the isolated W89 commit; do not bundle W88 behavior with W89 refactoring.

Before editing, compare the W67/W69-W71 parse and admission specs on the
same source state. The bounded consumer search found no external use of
`WideTypePlan::Node` or `::Parser` in `src/`, `spec/`, or `scripts/`;
`WideTypePlan.parse` has one production call in its shadow plan and five
spec callers. Retain nominal names because absence of in-repo callers does
not prove public API freedom. After extraction, run the same focused specs,
the relevant reader spec, full debug and release suites, Crystal format,
and `git diff --check`. A no-codegen compile and direct AST type-identity plus
canonical-name checks are additional guards; neither replaces runtime specs.
The expected signal is identical parser output and admission, no new supported types,
and zero regression failures. Review the final diff specifically for
accidental semantics edits or circular requires before an atomic commit.

This evidence decays if Crystal's parser/reflection semantics, the type plan,
its callers, or the root require graph changes.

## W89 observed result

The syntax tree and parser now each have their own file; the new
`WideTypeExpression` facade has a third file. `WideTypePlan.parse` delegates
without changing the parser's 4,096-byte, 64-depth, or 512-node limits. A
hostile review found and rejected an initial implementation that changed the
canonical `WideTypePlan::Node` and `::Parser` names despite green tests. The
corrected implementation retains those nominal identities, guarded by the
new spec. The final adversarial verdict was ROBUST within the aggregate
`require "./crystal_click"` API. Direct internal-file imports were not found
in this repository and are outside that verdict.

The isolated worktree passed 35 focused examples and 1,115 full debug and
release examples, all with zero failures. After integrating over W88, full
debug and release each passed 1,125 examples with zero failures or errors;
the pinned ClickHouse MV part oracle also passed. Crystal format and staged
diff checks passed. These are regression and compatibility signals, not a
performance result, generic type-admission proof, or evidence that the larger
reader/writer classes have been modularized.

## W90 design and execution boundary

Move the five existing private `WidePartWriter::ArrayMap*PhysicalPlan` structs
into one file per struct under `src/crystal_click/wide_part_writer/`. Each
struct owns a `.build` factory and the exact stream, role, semantic path,
width, storage mode, cardinality, and mark-axis checks previously performed
by its writer helper. Retain the structs' nominal identities and value
semantics. The public writer facades call these factories, and the existing
serializers continue consuming the same descriptors. Numeric factories take
the expected leaf width computed by the existing writer width policy; they
must compare it with the planned stream width. A two-line axis comparator
may remain private in each owner rather than adding a shared base class.

Admitted change: responsibility and source-file ownership only. Rejected:
new types, relaxed admission, changed serializer bytes, new public accessors,
codec dispatch, performance claims, or replacing the structs with heap objects.
Risk is CAUTION; rollback is the atomic W90 commit. The strongest failure is
a check disappearing during extraction while ordinary round-trip tests stay
green. Guard it with role/order/width/axis negative cases at the owner boundary,
in addition to the existing W80-W85 exact-byte and admission tests. All five
builder helpers and descriptors have only writer-local consumers at `bff96b5`;
`numeric_width` is shared with other writer families and remains in place.

Execution order:

1. Record the W80-W85 writer/type-plan baseline and identify negative cases
   for altered stream order, role, leaf width, and count/mark axes.
2. Extract the five descriptor/factory files, update the aggregate require
   graph and writer-local calls, and remove the old helpers from the writer.
3. Run the focused specs, pinned stock ClickHouse oracles for the affected
   families, full debug and release suites, Crystal format, and diff checks.
   Expected signal: unchanged exact bytes and admission, rejection of malformed
   plans, and zero regressions. Review every moved predicate before committing.

The source inventory and certificates decay when physical-plan construction,
writer admission, serializer consumers, Crystal type semantics, or the pinned
ClickHouse profile changes. Reader codecs, serializers, and table adapters
remain separate future responsibility slices.

## W90 observed result

The five private plan structs now own their factories and validation in five
separate files. Their canonical names and struct value semantics are retained.
The public writer delegates to those factories; the byte serializers are
unchanged. Numeric leaf-width policy remains in the writer and is passed to
the relevant factory rather than duplicated. The writer decreased from
25,905 to 25,241 lines; this is an ownership/navigation result, not a measure
of performance or proof that the entire writer is modular.

The frozen implementation passed 37 focused W80-W85 writer/type-plan/owner
examples and full debug and release suites of 1,132 examples each, with zero
failures or errors. The release suite completed on 2026-09-30 UTC; its test
execution took 20.35 seconds, excluding compilation, and is not a reader
benchmark. New negative tests reject changed stream count/order, role, storage
mode/axis, leaf width, mark-row axis, and nested cardinality axes. A compiler
reflection check guards the nominal names and struct semantics without
exposing a production test hook.

All six pinned `26.7.1.1315` W80-W85 oracles passed in full reader+writer mode,
including stock-produced reads, exact selected streams/marks, full/key-range
RowBinary, and Crystal-produced parts checked/attached by ClickHouse. The
new W83 shell wrapper defaults to full mode and rejects an invalid mode or
an unpinned executable. W80 and W82 default to stock-only mode, so their full
checks require explicit mode flags; W85 is invoked through Bash because its
tracked wrapper is not executable.

Scoped hostile review found no removed validation predicate or changed
serializer and returned ROBUST for the aggregate import boundary. Direct
imports of internal files and future factories supplied with an incorrect
numeric width are outside that verdict. Root independently reviewed the
source diff and ran full debug, release, and stock-oracle checks. Same-lineage
review is correlated evidence, not an independent compatibility proof.

Observed checks use the following environment on this host:

```sh
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
export CRYSTAL_CACHE_DIR=/private/tmp/crystal-click-w88-cache
export CLICKHOUSE_BIN=/Users/sergey/.local/bin/clickhouse
export TMPDIR=/private/tmp
crystal spec --link-flags='-fuse-ld=ld'
crystal spec --release --link-flags='-fuse-ld=ld'
W80_ORACLE_MODE=full bash scripts/check_array_map_string_uint64_w80_oracle.sh
W81_ORACLE_MODE=full bash scripts/check_array_map_numeric_w81_oracle.sh
W82_ORACLE_MODE=full bash scripts/check_array_map_string_values_w82_oracle.sh
W83_ORACLE_MODE=full bash scripts/check_array_map_bool_values_w83_oracle.sh
W84_ORACLE_MODE=full bash scripts/check_array_map_array_w84_oracle.sh
W85_ORACLE_MODE=full bash scripts/check_array_map_array_w85_oracle.sh
```

Crystal format, shell syntax, and `git diff --check` passed. These checks do
not admit new types, prove compatibility with September master, establish
matched ClickHouse performance, or close the larger class-architecture task.
Evidence decays under the W90 source/profile changes listed above.

## W91 payload-owner result

The next neutral slice extracted four private concrete owners, one file each:
reader `WidePart::StringPayloadDecoder`, writer `WidePartWriter::LeafStreamWriter`
and `::StreamEncoding`, and the existing `::ChecksumRecord` struct. String
assembly is shared by the exact Tuple and scalar reader; actual UInt64/String
payload method bodies moved out of the writer, whose old entrypoints delegate.
Schema/physical admission, range policy, budgets and stage lifecycle remain
in place. The writer is still 25,045 lines and reader 14,982; this is a small
ownership improvement, not closure of the larger architecture task.

The frozen source passed 72 focused and 1,145 full debug/release examples, with
zero failures/errors, plus the pinned Tuple, typed and basic writer oracles.
Scoped hostile review returned ROBUST at the aggregate import boundary; root
also checked mechanical body parity and executed the runtime checks. Exact
commands, source/profile lineage, residual Tuple metadata/EOF gaps and evidence
decay are recorded in [the W91 seal and result](COMPOSITIONAL_TUPLE_FRONTIER.md).

## W94 bounded Tuple owners

The new named UInt64/String-leaf Tuple path has eight concrete owners, one
file each: `WideTupleField`, `WideTupleTypePlan`, `WideTupleLeafColumn`,
`WideTupleColumnData`, private `WidePart::TupleReader`, and private
`WidePartWriter::TuplePartWriter`, `::TuplePartWriteInput` and
`::TuplePartInfrastructure`. Schema metadata and owned columnar buffers are
separate from reader orchestration, write preflight/staging and narrow adapters
to existing infrastructure. The existing facades retain root physical-policy
checks and old public APIs; the new path delegates actual orchestration rather
than reopening the facade with another large method body.

This is a new bounded admission slice, not a behavior-neutral extraction or
closure of the modularization task. The reader is still 15,135 lines, writer
25,101, table 6,583 and catalog 5,283. Existing type-specific serializers,
physical-stream policy and table/catalog adapters need later cohesive owner
boundaries; moving their text alone would not reduce coupling.

Root executed 37 focused examples in debug and release and 1,180 full examples
in each mode, all with zero failures/errors/pending. The unchanged pair and new
composition oracles passed against ClickHouse 26.7.1.1315, including stock reads
and stock ATTACH/CHECK of library-written parts. Scoped ownership, aggregate
budget and lazy-frame adversary checks are ROBUST within this profile, not for
all types or current master. Exact APIs, paths, commands, measured refutations,
ownership/lifetime policy, evidence decay and the next high-level value-mapping
boundary are recorded in [the W94 seal and result](COMPOSITIONAL_TUPLE_FRONTIER.md).
No new type, metadata profile, public generic Tuple API, arbitrary-table writer
or performance claim is admitted by this extraction.

## W95 high-level Tuple consumer owners

The high-level integration adds three concrete owners, one file each:
`WideTupleRow` retains an owned columnar mark and checked row index;
private `WidePartTable::TupleColumnAdapter` owns mark charge and row conversion;
private `OfflineTable::TupleValuesMaterializer` owns row accumulation and
all-leaf cell/String accounting. The facades contain dispatch and delegate
calls, not another copy of the Tuple codec or one native union per arity.

The initial selected-schedule adapter pass was removed after its premise was
refuted: the existing typed-open owner already compares every physical
stream's complete mark-row schedule. Preserve that eager metadata boundary
and the separate lazy per-mark payload contract. This is a bounded API
expansion, not completion of the one-class-per-file architecture for the
older reader, writer, table batch or catalog definitions. Verification,
refutations, ownership limits and evidence decay are recorded in
[the W95 seal and results](COMPOSITIONAL_TUPLE_FRONTIER.md).

Observed gates: 53 focused DEBUG and RELEASE examples each, 1,196 full DEBUG
examples, both pinned Tuple oracles (including high-level scans and catalog
values for seven stock/library profiles), example no-codegen, format, shell
syntax and diff checks all passed. Full RELEASE was not run for this slice.
The scoped hostile verdict is ROBUST for the new owners and bounded consumer
contract, not for full type support, all monolith extraction or performance.

## W101 parameterized Tuple owner boundaries

The named-flat Tuple extension adds twelve concrete owners, one file each:
`FixedStringValue`, `Enum8Value`, `Enum16Value`, `Decimal32Value`,
`Decimal64Value`, `Decimal128Value`, `Decimal256TupleValue`,
`WideTupleEnumDefinition`, `WideTupleFixedStringType`, `WideTupleEnumType`,
`WideTupleDecimalType` and `WideTupleSchemaParser`. The separate
`wide_tuple_parameterized_type.cr` file contains their closed descriptor alias,
not another concrete class. Existing Tuple field, leaf, column, row and
consumer owners retain their responsibilities; exact schema identity does not
belong to the primitive numeric owner or one union per Tuple arity.

The parser owns bounded named-flat source extraction and quoted Enum syntax.
Type owners retain exact N, map or P/S metadata. Nominal structs own detached
values, and the immutable Enum definition is shared once per leaf. Reader
orchestration aggregates descriptor/slot/FixedString-payload charges before
fixed-width range validation can decompress data. The writer shares the
existing fixed-width stream framing through a typed block, not a new per-row
callback object. These are bounded new capability owners, not a wholesale
behavior-neutral facade extraction or a memory/performance claim.

The reader remains 15,385 lines, writer 25,516, table 6,638 and catalog 5,309.
The old facade decomposition, recursive/nullable composition and broader
physical profiles remain open. Exact tests, source/binary lineage, hostile
review scope and evidence decay are recorded in
[the W101 frontier and result](PARAMETERIZED_TUPLE_FRONTIER.md).

Observed W101 gates: 222 focused DEBUG and RELEASE examples each, 1,384 full
DEBUG examples and fourteen pinned oracle launchers passed, with final
format/syntax/diff checks. Scoped hostile review is ROBUST for the new owners
and admitted profile. Full RELEASE, current-master runtime and the larger
facade architecture are not established by these results.

## W102 shared Decimal descriptor owners

The standalone Decimal precision extension adds two concrete struct owners,
one file each: `DecimalType` owns exact P/S identity, bounded canonical leaf
parsing and the four physical-width bands; `DecimalColumnType` owns only the
six admitted column shapes and catalog-only DDL normalization. The existing
`WideTupleDecimalType` embeds the same immutable leaf descriptor and retains
its public nominal-value, buffer and cached-name contract. This removes a
duplicate precision/width law without forcing Tuple wrappers into raw scalar
or Array APIs.

Reader, writer, typed-table and offline-catalog facades delegate schema
identity to these owners. Physical codecs, stream lifetime, selected-mark
policy, budgets and staging remain under their existing owners. The new
descriptor stores P/S only and derives width/name; this does not establish
allocation, RSS or throughput improvement. Full facade decomposition and
arbitrary recursive type composition remain open.

Root executed 144 focused DEBUG and RELEASE examples each, 1,404 full DEBUG
examples, the 72-core-profile bidirectional Decimal oracle with separate raw,
statistics and empty/null controls, and ten unchanged regression oracles.
All passed within the pinned physical profile; scoped hostile review is
ROBUST. Full RELEASE and current-master executable parity remain unqualified.
Exact source/runtime lineage, RED evidence, commands and residual boundaries
are tracked in [the Decimal precision frontier](DECIMAL_PRECISION_FRONTIER.md).

The reader is still 15,206 lines, writer 25,582, table 6,616 and catalog 5,315.
Those are navigation counts, not coupling or performance measurements. The
next cohesive extraction boundaries remain physical-stream lifetime/validation,
leaf codecs, staging/read-write orchestration and table/catalog adapters, one
concrete owner per file with behavior-preserving gates. This bounded W102
change does not complete that larger architectural work.

## LowCardinality binary grammar owner (2026-10-02)

Status: VERIFIED within the behavior-neutral extraction and gates below.
The implementation anchor is `74a8752`; executed final source is the isolated
four-file owner/import/delegation/spec/documentation diff over `0626874`.
CAUTION: moving private serialization helpers can silently change bounds,
exception classification, dictionary ownership or absolute row coordinates.
Rollback is the exact owner/import/delegation/spec diff and its isolated commit;
the unrelated uncommitted W121 JSON design draft is outside this change.

The existing reader/writer/cache characterization passed 16 DEBUG examples
before movement (`wide_part_reader_w22_spec.cr`, `wide_part_writer_w22_spec.cr`,
`wide_part_table_low_cardinality_cache_spec.cr`). Extract one private concrete
class, `WidePart::LowCardinalityBinaryCodec`, into
`src/crystal_click/wide_part/low_cardinality_binary_codec.cr`. It owns only
index-mark grammar, dictionary records, little-endian UInt64, binary Strings
and canonical VarUInt. Preserve all five existing private facade signatures as
delegates and copy the exact private bounded UInt64 primitive. The reader
requires the owner beside its existing private Variant decoder import.

Consumer inventory is limited to selected-range/full-state mark parsing,
shared/per-mark dictionary parsing and their nested primitive reads in
`wide_part.cr`. Compression/frame decoding, absolute mark mapping, cache/state
lifetime, serialization metadata, type admission, limits and materialization
remain with their existing owners. This does not admit broader LowCardinality
index widths, Nullable, dictionary updates, new types or new physical layouts.

DoD: qualify the missing-owner RED using
`spec/low_cardinality_binary_codec_spec.cr`, then pass that spec plus the three
existing LC specs in DEBUG and RELEASE; pass full DEBUG and the unchanged
`scripts/check_lowcard_string_oracle.sh` against its pinned 26.7.1.1315 runtime.
Root checks source-body parity (only owner qualification/internal call renames),
existing delegate signatures, format and diff hygiene. The strongest guard is
a deliberately removed dictionary-state header check: direct negative tests
must detect it, then the guard must be restored before all final gates.
Tests cover global/local dictionary ownership, absolute offsets, binary bytes,
counts, defaults, duplicates, selected boundaries and malformed VarUInt.

This is one responsibility-level extraction, not completion of the large
reader/writer/table decomposition or evidence of lower allocations or speed.
The active capability return pointer remains W121 in
`JSON_GENERAL_STORAGE_FRONTIER.md`; memory/performance follow paired types and
MV/projection compatibility rather than being inferred from this refactor.

### Executed result and replay

Root independently normalized each of the five original method bodies against
the moved static methods: only indentation, owner/internal-call qualification
and explicit parent constant names differ. The private bounded UInt64 primitive
is also an exact copy. All five original facade signatures are preserved.
The new owner is 104 lines; the reader is 15,976, writer 26,034 and table 7,080.
These are navigation counts, not coupling or performance measurements.

Observed gates on the restored, frozen production/spec source:

- Qualified missing-owner RED: the direct spec exited 1 solely because
  `LowCardinalityBinaryCodec` did not yet exist, after the 16-example existing
  DEBUG baseline passed. This establishes the new seam, not a pre-existing bug.
- Final focused DEBUG and RELEASE: 28 examples each, no failures/errors/pending.
- Full DEBUG: 1,973 examples, no failures/errors/pending. The existing W113
  test-only deprecated `blocking` warning and duplicate `-lc` linker warning
  remain; full RELEASE was not executed.
- A temporary `false && header != expected_header` instrument made the direct
  spec fail (12 examples, one failure: expected UnsupportedFormatError but
  nothing was raised). The original guard was restored before all final gates.
- The unchanged stock LC oracle exited 0 against pinned ClickHouse 26.7.1.1315:
  stock shared/local dictionaries, exact streams/marks, full/key-range reads,
  authored-part ATTACH/actual CHECK=1 and RowBinary checks passed. Both same-size
  dictionary/index corruption controls were detected and restored by the script.
- Final format checks, diff hygiene and restored source-body parity passed.

Luna's static review is correlated, not independent runtime evidence. Root's
scoped adversarial verdict is ROBUST for behavior preservation, backed by the
body comparison, seeded guard detection and independently executed gates.
No general LowCardinality, whole-JSON, allocation or throughput claim follows.

Logs are `/private/tmp/crystal-click-architecture-20261002.VOBfQV/`:
`baseline-focused-debug.log`, `owner-missing-red.log`,
`header-guard-seeded-red.log`, `final-focused-debug.log`,
`final-focused-release.log`, `final-full-debug.log`, `final-stock-lowcard.log`.
Replay from the repository, serially under the existing `run_safe.sh` memory
guard (50% minimum free; 600 seconds; focused/oracle 8,192 MiB, full 32,768 MiB):

```sh
crystal spec spec/low_cardinality_binary_codec_spec.cr spec/wide_part_reader_w22_spec.cr spec/wide_part_writer_w22_spec.cr spec/wide_part_table_low_cardinality_cache_spec.cr --single-module --link-flags=-fuse-ld=ld --error-trace
# Repeat the focused command with --release.
crystal spec --single-module --link-flags=-fuse-ld=ld --error-trace
CLICKHOUSE_BIN=/Users/sergey/.local/bin/clickhouse bash scripts/check_lowcard_string_oracle.sh
crystal tool format --check src/crystal_click/wide_part.cr src/crystal_click/wide_part/low_cardinality_binary_codec.cr spec/low_cardinality_binary_codec_spec.cr
git diff --check
```

Executed compiler: `/opt/homebrew/bin/crystal` 1.21.0, LLVM 22.1.8, AArch64;
`SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`,
`TMPDIR=/private/tmp`, isolated cache directories under the log root.
The current 31d2addb source snapshot is not the stock executable's provenance.
Refresh this certificate when a moved body, delegation, limits, consumer,
require graph, toolchain or tested runtime changes. Source continuity does not
widen admission: re-run focused/full/oracle gates before reusing that claim.
