# CrystalClick Modularization Frontier

Current transition (2026-10-03): W134 behavior-preserving Array/Map row-owner
extraction over W133 `2e150f4`, verified within the executed scope below.
Nine existing classes now have one file each; no API, type, codec, limit or
physical-profile admission changed. This is a navigation improvement, not
completion of the larger responsibility-level architecture.
W133 paired bare Date/Date32 Object fields over W132 `e043be7`; its bounded
capability certificate remains in `JSON_GENERAL_STORAGE_FRONTIER.md`.
Catalog Object dispatch has a private materialization owner; W130 separately
owns normalized table admission/accounting. W132 extracts one shared closed
typed-field policy; W133, W135, W136, W137 and W138 extend that policy without
a new codec or class per declaration. W135 reuses fixed-value/bulk and existing Object
writer/consumer owners for bare UUID/IPv4/IPv6; its capability evidence remains
in the JSON frontier, not an architecture-completion claim. W136 adds
bounded FixedString(N) resolution, preflight byte sizing and rendering to the
same policy. Its nested stack-value Resolution carries tag/N/byte count until
the parser charges the budget; the immutable descriptor is constructed only
after that charge. Schema construction similarly preflights before rendering.
There is no new codec, per-width class or physical facade branch. The paired
stock and regression certificate remains in the JSON frontier. W137 adds
canonical Decimal(P, S) resolution and rendering to this same owner; its
stack Resolution carries precision/scale/byte charge before descriptor
materialization. The existing DecimalType selects width and validates SQL
parameters; the wider global BinaryDecimalType transport grammar is not
narrowed. Reader, writer and consumers reuse their existing fixed-value/bulk
owners, without a new per-width codec, class or facade dispatch branch.
W137's schema and stock qualification remain a capability certificate in the
JSON frontier, not completion of the architecture refactor. W138 adds one
cohesive ObjectEnumDeclaration owner/file for canonical Enum map scanning,
budget preflight, materialization and direct name sizing/rendering. Its nested
stack metadata borrows the declaration; the owner rescans tag/count/decoded
bytes/span before entry-array allocation rather than trusting public preflight
metadata. The shared policy dispatches to that owner; existing fixed-value/bulk,
writer, reader and consumer owners remain unchanged. There is no per-map,
per-width codec or new physical facade branch. Root passes 72 focused DEBUG,
197 adjacent RELEASE and 2,280 complete-inventory examples, the eight-cell
stock oracle and five unchanged stock regressions; scoped evidence and logical
budget limitations remain in the JSON frontier. This is not completion of the
legacy facade decomposition. No
MV/projection or performance admission changes are made here.

W124's explicit-path compressed mark transport is verified below with eight
separate owners/files; W123's flattened Object composition has five. Their
historical admission boundaries are recorded in their respective sections.
W126 adds three file-backed Object read owners below, keeping full-grid
validation, physical file resolution and document composition separate from
the unchanged legacy facades.

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
Current navigation counts at W134 are 15,985 reader lines, 25,991 writer lines,
6,786 table lines, 1,560 catalog lines and 3,692 offline-table lines. The table
facade lost exactly 385 lines; code was moved, not eliminated. The next cohesive
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

## Dynamic discriminator and schedule owners (W121, 2026-10-02)

Status: VERIFIED within the normalized discriminator/schedule profile and
executed gates below, over `2e9e0c4`; no whole-Dynamic/JSON admission.
CAUTION: paired discriminator serialization and sparse row coordinates.
Rollback is this slice's exact four-owner/import/spec/oracle/documentation diff;
existing reader/writer/table facades and their admission are unchanged.

Each new concrete owner has one responsibility and its own file:

- `dynamic_discriminator_mark.cr`: absolute decompressed offset and row count.
- `dynamic_discriminator_stream.cr`: detached complete bytes and normalized mark
  grid, plus non-copying size/index access needed for bounded codec preflight.
- `dynamic_mark_schedule.cr`: owned selected tags, local sparse ranks, per-arm
  counts, original mark/outer-row coordinates and selected-window arm offsets.
- `dynamic_discriminator_codec.cr`: paired BASIC/COMPACT grammar, complete-grid
  validation, selected-body parsing and shared logical-budget accounting.

The aggregate `src/crystal_click.cr` adds only four imports. No legacy facade
consumer is rerouted. Physical frame/mark mapping, Dynamic child values and
cardinality, Object document assembly and staged publication remain separate
future responsibilities, rather than being folded into this grammar owner.
See `JSON_GENERAL_STORAGE_FRONTIER.md` for the source/runtime anchors, precise
admission, limits and compatibility DoD.

Ownership caveat: `DynamicDiscriminatorStream.borrowed_slice` is a mutable view
used read-only by convention inside the codec. Detached constructors/getters
do not enforce read-only access through that public convention-internal method.
Do not claim an immutable public stream or concurrent-mutation safety.

This responsibility split is not completion of the large facade decomposition,
or evidence of allocation/throughput improvements. The active return pointer
is paired Dynamic child-lane/cardinality integration after W121 qualification;
general JSON remains refused until complete selected child/shared validation
and paired document assembly have their own executed gates.

Root executed 77 focused DEBUG and 77 RELEASE examples, then 1,996 full
non-release DEBUG examples with symbolic debug information disabled after the
original symbolic compilation hit the unchanged 50% memory-pressure floor.
All executed positives have zero failures/errors/pending. The new stock oracle
qualified fourteen retained streams and four production-encoded BASIC/COMPACT
copied-part ATTACH/actual CHECK=1 cases; unchanged W116-W120 regressions passed.
The seeded removed VarUInt guard was detected and restored before final gates.
Final format/syntax/diff checks passed. Full RELEASE was not executed.

Owners total 553 lines (11/49/43/450); the existing reader/writer/table remain
15,976/26,034/7,080. Their larger decomposition is still open. The executed
certificate, replay commands, temporary evidence roots and coordinate/budget
falsifiers are in the W121 section of `JSON_GENERAL_STORAGE_FRONTIER.md`.
Root's scoped adversary verdict is ROBUST for this codec path; Luna's static
review is correlated, and the mutable borrowed-view caveat remains explicit.
Refresh on owner/import/API, budget/coordinate, consumer, toolchain/runtime or
comparator changes; these tests do not prove future child-lane integration.

## Recursive bulk and Dynamic logical-value owners (W122, 2026-10-02)

Status: VERIFIED within the normalized codec and captured stock profile;
see `JSON_GENERAL_STORAGE_FRONTIER.md`. CAUTION: paired recursive bulk
serialization and sparse Dynamic child cardinalities, over `e71a967`.
Rollback is this slice's exact ten-owner/import/spec/oracle/documentation diff,
plus the additive schedule index queries and borrowed-envelope reservation.
Existing facade behavior and public part admission remain unchanged.

The new responsibilities have separate concrete-owner files:

- `binary_bulk_profile.cr`: explicit uniform String layout selector. Its enum
  is part of this owner's closed profile contract, not another service.
- `binary_bulk_stream.cr`: detached bytes and a decompressed-byte offset grid;
  convention-internal borrowed range access avoids whole-lane copies.
- `binary_bulk_streams.cr`: complete role-to-stream set and outer mark count.
- `binary_bulk_type_plan.cr`: recursive role names and allocation-free role
  counts, called only after bounded descriptor validation by codecs.
- `binary_bulk_default_value.cr`: canonical hidden-NULL defaults and their
  logical cost; its nested cost record remains cohesive with that policy.
- `binary_bulk_encoder.cr`: paired recursive columnar emission and shared
  logical-budget preflight, without legacy facade dispatch.
- `binary_bulk_decoder.cr`: complete grid/role validation and selected-body
  parsing, including empty lanes and exact child-cardinality exhaustion.
- `binary_bulk_codec.cr`: the small paired entry facade, including borrowed
  budget entry points; it does not own a part filesystem/publication policy.
- `dynamic_value_streams.cr`: the discriminator plus complete arm owners.
- `dynamic_value_codec.cr`: nominal arm routing, shared typed envelopes,
  selected W121-derived child counts, and bounded logical-row assembly.

`DynamicMarkSchedule` gains scalar/index accessors rather than exposing its
mutable arrays or creating detached snapshots for every arm/row.
`BinaryValueCodec.encode_borrowed` gains an optional reserved-wire allowance;
its existing callers retain the zero-reservation behavior. Direction is checked
before budget use. The aggregate library file adds ten imports. No legacy
reader/writer/table consumer is silently rerouted to a wider format profile.

At qualification time the ten new owner files total 1,716 lines
(45/61/56/97/95/399/369/72/45/477). The existing schedule becomes 69 lines;
reader/writer/table remain 15,976/26,034/7,080. These are navigation counts,
not coupling, allocation or throughput measurements. The large-facade
decomposition is still open; physical mark adapters, Object document assembly
and staged publication must retain separate responsibilities.

Borrowed byte slices remain mutable by convention. Public detached model
construction/getters are outside codec budgets, and logical node/edge/wire
limits are not RSS limits. Decoder NULL normalization discards hidden nested
bytes, although all selected hidden payloads are validated first. No physical
losslessness, all-CH-type admission, whole-JSON, or speed claim follows.

The source/runtime anchors, exact profiles, falsifiers, DoD and replay evidence
belong to the W122 section of `JSON_GENERAL_STORAGE_FRONTIER.md`. Refresh on
owner/import/API, profile/coordinate/budget, consumer, toolchain/runtime or
comparator changes, not merely when a SQL type name changes.

Root's executed gates: 111 focused DEBUG and 111 focused RELEASE examples;
2,030 full non-release examples with symbolic debug information disabled;
four isolated production-stream copied-part ATTACH/actual CHECK=1 profiles
with full and PK3..6 readback; unchanged W116-W121 stock regressions. All final
positive gates exited0 with no test failures/errors/pending. Full RELEASE was
not executed. A removed final child-consumption guard was detected and restored
before the positives. The new stock comparator's unordered Object-statistics
assumption was corrected without changing production code; independent semantic
qualification plus exact retained bytes remain required. Root's scoped verdict
is ROBUST; Luna's static review is correlated. Full details and temporary
evidence pointers are in the capability frontier rather than duplicated here.

## Flattened Object document owners (W123, 2026-10-02)

Status: VERIFIED within the normalized V3/one-bucket MAP document profile and
two captured-stock profiles in `JSON_GENERAL_STORAGE_FRONTIER.md`.
CAUTION: document-level composition over `3bcdefc`; rollback is the isolated
five-owner/import/metadata-predicate/spec/oracle/documentation diff.
No legacy part/table/catalog facade is rerouted or enlarged.

Each new concrete responsibility has one production file:

- `object_document.cr`: detached, byte-ordered flattened path/value row.
- `object_document_plan.cr`: exact disjoint typed schema and Object/Dynamic
  metadata association; not schema inference or fresh statistics synthesis.
- `object_document_streams.cr`: owned metadata and complete typed/Dynamic/shared
  lane sets with the full outer row grid; not compressed-file acquisition.
- `object_document_shared_codec.cr`: shared named-Tuple Array framing, aggregate
  pending-envelope reservation and strict exact-path/envelope validation.
- `object_document_codec.cr`: paired metadata/child composition, selected-window
  validation and all-or-error document assembly under one logical budget.

ObjectDynamicStructureCodec's additive borrowed-budget entry points preserve
its standalone grammar. ObjectStructure retains its existing detached uniqueness
set and exposes a non-copying raw-byte membership predicate; repeated roster
scans are not delegated to model getters. Equality/hash identity remains the
metadata itself, not this derived index. The two String layout authorities are
explicitly separate: typed/Dynamic profile and shared profile.

The five new files total 915 lines (61/74/136/213/431). The existing legacy
reader/writer/table/catalog/offline-table remain unchanged at
15,976/26,034/7,080/1,560/3,657 lines. These are navigation counts, not a
completed architecture or coupling/performance certificate. Physical lifetime,
compressed-mark adapters, codec dispatch, fresh statistics/staging and
table/catalog responsibilities still need cohesive extraction.

Root executed 131 focused DEBUG and 131 focused RELEASE examples, 2,050 full
non-release examples without symbolic debug info, four W123 authored-stream
isolated ATTACH/CHECK=1 cases and the unchanged W122 oracle. Independent
literal wire/window limits, a detected/restored grid-guard defect and a qualified
32 MiB quadratic-copy allocation RED supplement the correlated Luna review.
The final allocation guard passes below 2 MiB; this is not an RSS/speed claim.
Full RELEASE was not run. The scoped hostile verdict is ROBUST; replay, exact
profiles, source/runtime identities, exclusions, lineage and decay triggers are
recorded in the capability frontier. Public whole-JSON read/write, complete
type/MV/projection coverage and the large-facade refactor remain open.

## Compressed mark transport owners (W124, 2026-10-02)

Status: VERIFIED within the explicit-path/plain-adaptive-mark profile recorded
in `JSON_GENERAL_STORAGE_FRONTIER.md`. CAUTION: frame/mark coordinate grammar
and mapped-file lifetime over `80ab0c2`; rollback is the isolated eight-owner,
import, spec, oracle/wrapper and living-document diff. No old facade dispatch
or publication policy changes.

Each concrete responsibility has one production file:

- `compressed_stream_limits.cr`: immutable transport limit configuration.
- `compressed_stream_budget.cr`: direction-checked consumptive operation counts.
- `compressed_frame_descriptor.cr`: immutable outer frame coordinate/value.
- `compressed_frame_index.cr`: bounded header indexing and logical mark lookup.
- `compressed_mark_window.cr`: detached selected bytes/grid and window identity.
- `compressed_mark_files.cr`: detached unpublished data/mark output pair.
- `compressed_mark_reader.cr`: mapped acquisition, full-grid validation,
  selected-frame checksum/decode and owned result assembly.
- `compressed_mark_writer.cr`: preflight sizing, literal-LZ4 frame encoding and
  paired physical mark emission, without filesystem publication.

The eight files total 1,099 lines (56/75/28/112/44/20/452/312). Existing
reader/writer/table/catalog/offline-table remain unchanged at
15,976/26,034/7,080/1,560/3,657 lines. These are navigation counts, not a claim
that the requested architectural decomposition is complete. New codecs keep
physical lifetime, normalized document composition and publication separate;
legacy shared type/substream planning, leaf dispatch, stage orchestration and
table/catalog materialization still need responsibility-level extraction.
One class per combination would not close that coupling boundary.

Root executed 201 focused DEBUG and RELEASE examples, 2,081 full non-release
examples, four production-reframed stock ATTACH/actual CHECK=1/readback cases,
and the unchanged W123 oracle. The first full run hit the unchanged FD guard;
single-thread/single-module replay passed without weakening guards. Root's
independent literal falsifiers and scoped ROBUST verdict are recorded in the
capability frontier, together with exact identities, replay and exclusions.
Full RELEASE, general JSON part binding/writing, all layouts/types, expanded
MV/projection coverage, allocator/RSS and performance remain unclaimed.

## Generic physical stream binding owners (W125, 2026-10-02)

Status: VERIFIED within the explicit naming/profile certificate in
`JSON_GENERAL_STORAGE_FRONTIER.md`. CAUTION: role/name binding over `99b47d6`;
rollback is the isolated four-owner/import/spec/oracle/living-document diff.
Existing facades and W124 transport owners are unchanged.

Each concrete production responsibility has one file:

- `physical_stream_name.cr`: bytewise ClickHouse escaping and bounded rendered-
  name construction, with raw versus escaped syntax explicitly separated.
- `physical_stream_plan_context.cr`: shared consumptive descriptor/record/name
  counters, not payload transport or allocation/RSS accounting.
- `binary_bulk_physical_plan.cr`: recursive logical-role to exact physical-
  basename binding under an explicit String profile. Its private escaped-
  prefix value token is cohesive with that constructor invariant, not an
  additional public planning responsibility.
- `object_document_physical_plan.cr`: typed/Dynamic/shared-MAP composition and
  Object-wide physical-name collision refusal over an explicit logical plan.

The four files total 775 lines (131/75/289/280). The actual unchanged legacy
owners are `wide_part.cr` 15,976, `wide_part_writer.cr` 26,034,
`wide_part_table.cr` 7,080, `offline_catalog.cr` 1,560 and `offline_table.cr`
3,657. `embedded_merge_tree_table.cr` is a separate 810-line owner, not the
7,080-line table facade. Counts aid navigation; they do not certify reduced
coupling, completed decomposition, memory savings or speed.

Root's 21 independent literal/negative examples supplement Luna implementation
and correlated static review. Focused DEBUG and RELEASE each passed 210
examples. Four W125 production-bound copied-part ATTACH/actual CHECK=1/full+PK
readback cases and the unchanged four-case W124 oracle passed. Full non-release
passed 2,102 examples with symbolic debug information disabled; exact-path
formatting, shell syntax and diff hygiene passed. Root's scoped hostile verdict
is ROBUST. Full source, runtime, profile, repair, replay and exclusion details are in
`JSON_GENERAL_STORAGE_FRONTIER.md`. The next responsibility is metadata/grid
discovery and complete file-backed Object assembly, then fresh metadata and
staged publication. Old facade planning/dispatch/orchestration and table/catalog
materialization still require extraction. No public whole-JSON part, all-type,
expanded MV/projection, full RELEASE or performance claim follows.

## File-backed Object read owners (W126, 2026-10-02)

Status: VERIFIED within the explicit Wide/SUFFIX V3/one-bucket MAP certificate
in `JSON_GENERAL_STORAGE_FRONTIER.md`. CAUTION: complete physical-grid discovery,
metadata suffix coordinates and selected acquisition over `9e3ec4b`.
Rollback is the isolated three-owner/import/transport/metadata-codec/spec/oracle
and living-document diff. No legacy facade dispatch or publication changes.

Each concrete production responsibility has one file:

- `compressed_mark_grid.cr`: detached complete outer-row grid and normalized
  logical positions, including prefix and terminal EOF.
- `part_stream_source.cr`: checksums-sized physical file resolver and transport
  adapter for a trusted quiescent part directory. It refuses missing, changed-
  size, symlink or unsafe-basename inputs; it does not verify whole-file hashes.
- `object_document_file_reader.cr`: explicit-schema/profile Object and Dynamic
  metadata discovery, complete cross-lane row alignment and selected-window
  document assembly. Private binding DTOs belong to this owner; they are not
  additional public responsibilities or per-type-combination classes.

The three files total 743 lines (73/125/545). The existing compressed mark
reader is now 550 lines: header/grid inspection and selected payload acquisition
share full-grid validation. Structure codecs add parser-measured, relative
before-statistics offsets without changing their existing grammar. Owned grids,
mapped physical lifetimes, recursive logical codecs and document composition
remain distinct boundaries.

The unchanged legacy owners still have 15,976 reader, 26,034 writer, 7,080 table,
1,560 catalog and 3,657 offline-table lines. This slice does not complete the
requested architecture refactor or prove reduced RSS, lower allocation or
greater speed. Shared facade planning/dispatch, leaf codecs, staging and
table/catalog materialization still need responsibility-level extraction.

Root's nineteen literal-wire examples supplement the Luna implementation and
correlated static reviews. Focused DEBUG and RELEASE each passed 229 examples.
Three qualified seeded guard failures distinguish early unhashed-name bounds,
full-source logical roster charging and exact later-metadata coordinates; all
production guards were restored. The unchanged W125 oracle passed four fresh
copied-part ATTACH/actual CHECK=1 cases. W126 separately reopened those stores
and matched production file-reader full/middle/zero windows against independent
documents and stock full/PK readback. BASIC/COMPACT here mean discriminator
encoding, not part layout; all four parts are Wide. No fresh metadata synthesis
or another W126 ATTACH is claimed.

Final full non-release after strengthening the metadata falsifier passed 2,121
examples with zero failures/errors/pending and symbolic debug information
disabled. Exact-path formatting, shell syntax and diff hygiene passed. Root's
scoped hostile verdict is ROBUST; no full RELEASE or general-layout claim follows.

Exact source/runtime identities, limits, replay, evidence paths and exclusions
are in `JSON_GENERAL_STORAGE_FRONTIER.md`. Next are fresh paired metadata and
schema sidecars, then staged publication without borrowed metadata. Catalog/
facade routing, older or advanced JSON layouts, broader type/MV/projection
coverage, full RELEASE and performance remain open.

## Fresh Object statistics and column-file owners (W127, 2026-10-02)

Status: VERIFIED within the unpublished Wide/V3/one-bucket MAP contract in
`JSON_GENERAL_STORAGE_FRONTIER.md`. CAUTION: fresh metadata identity and
complete file-pair composition over `4632f59`. Rollback is the isolated owner,
transport/metadata extension, import, spec, oracle and living-document diff.
No legacy facade admission, filesystem publication or catalog route changed.

Five cohesive responsibilities have their own files:

- `binary_type_name_budget.cr`: recursive descriptor/name sizing before SQL
  display-name materialization, including escaped metadata.
- `object_document_statistics.cr`: fresh counts over an explicit plan and
  flattened documents; no roster inference or serialized-file ownership.
- `object_document_column_writer.cr`: logical-to-physical lane composition,
  aggregate preflight and compressed-pair orchestration; no part publication.
- `object_document_column_lane.cr`: internal borrowed generated-lane adapter,
  not an additional public format/profile dispatcher.
- `object_document_column_files.cr`: owned exact unpublished filename/pair
  roster and detached bytes, not an on-disk part or table.

These owners total 931 lines (134/413/228/75/81). W125's physical plan now
caches the collision-checked scalar stream count; paired metadata codecs expose
writer-measured before-statistics offsets. W124's transport has a separate
multi-frame metadata grammar and aggregate nonmutating preflight; its ordinary
prefix grammar remains unchanged. The Dynamic encoder and fresh statistics
share nominal routing while retaining the old encoder accounting contract.
Sizing and copy work use the same consumptive logical ledger. Limits bound
logical work/retained bytes, not total transient copies or allocator/RSS.

Root's thirteen independent examples plus six owner/probe examples passed:
248 focused DEBUG and RELEASE examples each, 2,140 full non-release examples,
four fresh matching-shell W127 stock ATTACH/actual CHECK=1/full+PK cases with
W126 full/middle/zero reads, and unchanged W125/W126 regressions. Qualified RED
probes forced correction of uncharged sizing and late roster admission; the
restored guards pass. Root's scoped hostile verdict is ROBUST, with correlated
Luna review only supporting it. Exact identities, repairs, scheduling caveat,
replay, evidence paths and decay triggers are in the capability frontier.

The existing legacy owners remain 15,976 reader, 26,034 writer, 7,080 table,
1,560 catalog and 3,657 offline-table lines. This does not complete the large-
facade refactor or prove less coupling, memory or time. Shared facade planning,
leaf dispatch, staging and table/catalog materialization still need extraction.
Next are fresh schema sidecars and normalized whole-part staging without any
borrowed metadata, then facade/catalog integration. General JSON layouts,
all-type admission, wider MV/projection execution and full RELEASE remain
open; optimization stays parked. One file per cohesive owner, not one class per
type combination, is the maintained architecture boundary.

## Shared writer infrastructure extraction (2026-10-02)

Status: VERIFIED within the unchanged shared-writer contract below.
Risk: CAUTION (persisted checksum bytes and atomic publication).
Anchor: `wide_part_writer.cr` owns stage allocation, UInt64 primary-index and
metadata file writing, checksums serialization and Darwin exclusive rename.
The existing Tuple/QBit/Geometry adapters reach the same private helpers.
Rollback: revert only this extraction's exact-path commit/diff over `9ca6a6b`.

Admitted behavior stays unchanged: same filename roster, checksum ordering and
wire bytes, UInt64 primary-index EOF entry, LZ4 frame limits, private facade
signatures, stage prefix/retries, failpoint names/timing, exclusive rename and
caller-owned cleanup. New owners are private, with one cohesive responsibility
per file. This is not a new generic part writer, Linux publication support,
crash/power-loss durability or the complete facade refactor.

Concrete owners: `PartChecksumsWriter` owns the v4 checksum envelope,
`PrimaryIndexWriter` owns the existing UInt64 index bytes, and
`PartDirectoryPublisher` owns stage allocation and exclusive rename. Each
private class has its own source file under `wide_part_writer/`. The existing
`StreamEncoding` owns the one shared VarUInt implementation; both the old
facade helper and checksum owner delegate to it. Caller cleanup and specialized
metadata/validation remain unmoved.

Execution plan:

1. Root adds private-helper/public-writer characterization tests and runs them
   against the existing implementation before moving production code.
2. Luna extracts narrowly scoped shared owners, retaining delegation from the
   facade and existing infrastructure adapters. Schema-specific metadata and
   staged validation stay with their current owners.
3. Root independently reviews the diff, executes literal checksum/index and
   existing-target/symlink/failed-publication controls, focused DEBUG/RELEASE,
   failpoint crash-window specs, the unchanged stock writer oracle, and the
   broader non-release suite serially under the 50% free-memory guard.

DoD: all declared commands pass, exact-path formatting and `git diff --check`
pass, no unrelated changes, and the resulting diff preserves the contract.
Strongest failure mode: moving a private helper changes exception/errno or
failpoint timing, or rewrites persisted bytes while roundtrip tests still pass.
Guard: independent literal bytes plus destination collision and SIGKILL windows;
no production refactor before the baseline characterization is green.

Architecture direction after this slice: shared schema/physical planning,
leaf stream codecs, staged validation/publication orchestration, then table and
catalog materialization. Keep facade compatibility while removing ownership,
not merely reopening the same giant module across many files. The existing
JSON capability return pointer remains fresh schema sidecars and normalized
whole-part staging, followed by facade/catalog integration.

Executed final-source certificate (macOS AArch64, Crystal 1.21 / LLVM 22):

- Focused DEBUG and RELEASE: 50 examples each, no failures/errors. The six
  root-owned characterizations include literal checksum bytes, UInt64 VarUInt
  boundaries, primary-index EOF bytes, stage isolation, destination collision
  and dangling-symlink rejection. The original five characterizations also
  passed before the extraction.
- Explicit failpoint/cleanup/lifetime set: 53 examples, no failures/errors,
  with `-Dcrystal_click_test_failpoints`; includes SIGKILL publication windows.
- Full non-release suite: 2,146 examples, no failures/errors.
- Unchanged `scripts/check_wide_part_writer_oracle.sh`: four cases passed on
  pinned ClickHouse 26.7.1.1315, including exact full/PK reads, actual
  `CHECK TABLE` success and one-byte corruption rejection.
- Exact-path `crystal tool format --check` and `git diff --check` passed.

Replay: `crystal spec --single-module --threads 1 --link-flags=-fuse-ld=ld
--error-trace` for the full suite (add `--release` for the focused set). The
focused inputs are `writer_infrastructure_refactor_root_spec.cr`,
`wide_part_writer_spec.cr`, `wide_part_writer_compositional_tuple_spec.cr`,
`qbit_writer_w103_spec.cr`, `geometry_w114_writer_spec.cr` and
`part_checksums_spec.cr` under `spec/`. The failpoint set adds
`embedded_merge_tree_fault_spec.cr`, `embedded_merge_tree_table_spec.cr`,
`staged_stream_file_set_w113_spec.cr` and `point_w109_writer_spec.cr` to the
root/geometry inputs. All heavy jobs ran serially with the 50% free-memory
guard. Local ephemeral evidence is in
`/private/tmp/crystal-click-refactor-root.KjBrat/final-{debug,release,failpoints,full,stock-writer}.log`.

Additional adverse probe: the unchanged compositional Tuple stock oracle
failed compilation at `wide_tuple_leaf_column.cr:690` (impossible identifier
buffer cast for an UInt64 consumer). An isolated `git archive 9ca6a6b` replay
failed identically; the affected source was unchanged by this extraction.
At this extraction checkpoint, the preexisting sparse-consumer defect was
reserved for a separate fix, not a green Tuple stock certificate.
Evidence: `final-stock-tuple.log` and
`baseline-stock-tuple.log` in the same temporary root.
The subsequent separate inference correction and qualified Tuple stock replay
are recorded in [COMPOSITIONAL_TUPLE_FRONTIER.md](COMPOSITIONAL_TUPLE_FRONTIER.md);
they do not retroactively change this extraction's original evidence.

Root verdict: ROBUST for the moved infrastructure contract, with literal and
stock checks independent of Luna's correlated static review. It does not
qualify Linux publication, every type-specific consumer graph, full RELEASE,
latest-master runtime compatibility or the complete architectural refactor.
Refresh this certificate when the helpers, their callers, publication flags,
compiler/platform or pinned runtime change; rerun the affected guards rather
than inheriting the claim from file layout.

## Normalized Object whole-part owners (W128, 2026-10-02)

Status: VERIFIED only within the sealed W128 contract in
`JSON_GENERAL_STORAGE_FRONTIER.md`. Three cohesive production owners have
separate files:

- `object_document_schema.cr`: explicit declared capacities, detached typed
  paths, canonical bounded declaration and exact schema/plan agreement.
- `wide_part_writer/object_part_metadata.cr`: owned plain metadata composed
  from that schema, the physical roster and authored key/default counts.
- `wide_part_writer/object_part_writer.cr`: preflight, W127 column composition,
  shared key/index/checksum writing, staged semantic validation and exclusive
  publication. Its private plan/lane DTOs do not create new public authorities.

These owners total 1,150 lines (320/189/641). The public writer adds a thin
delegating method; shared encoding, leaf I/O, checksums, primary index and
publication policy remain with their existing owners. No new class per JSON
type combination or copy of a logical codec is introduced.

Root executed 55 focused DEBUG and 55 RELEASE examples, 2,163 full non-release
examples, and five library-only stock ATTACH/actual CHECK=1/full/PK cases with
independent metadata/checksum/mark expectations and W126 full/middle/zero reads.
The standalone example also passed. Root's scoped hostile verdict is ROBUST;
the Luna implementation/static review is correlated supporting evidence, not
an independent runtime certificate. The capability frontier records exact
commands, identities, earlier oracle-only errors, evidence paths and decay.

This does not complete the requested large-facade decomposition or prove
lower coupling, RSS or runtime cost. Shared legacy type/substream planning,
physical I/O/validation and leaf dispatch, then thin table/catalog adapters,
remain the responsibility-level seams. Full Object facade dispatch, additional
paired types/profiles and broader MV/projections remain open; optimization is
still parked.

## Normalized Object catalog owners (W129, 2026-10-02)

Status: VERIFIED only for the W129 bounded admission/materialization contract
and executed gates in `JSON_GENERAL_STORAGE_FRONTIER.md`, over `1c5bab4`.
This is a CAUTION shared-reader refactor and a catalog capability addition,
not completion of the larger architecture or general Object table dispatch.

Five cohesive production owners each have one source file:

- `object_document_schema_parser.cr`: bounded declaration parsing and semantic
  canonicalization, independent of the old scalar virtual-path grammar.
- `object_document_file_descriptor.cr`: immutable plan/grid/name/work-size
  description, with detached arrays and String views.
- `object_column_reader.cr`: selected-column DDL/count/roster/profile binding,
  complete-grid inspection and bounded mark delivery. Recognized selected
  compressed marks are refused rather than silently falling back.
- `object_values_materialization_budget.cr`: shared logical accounting of
  result owners and reader workspace, with atomic whole-mark admission and
  independent String/cell/node/element limits.
- `offline_table/object_values_materializer.cr`: private catalog orchestration;
  validate every candidate first, reserve the aggregate base, then reopen and
  consume one part at a time. The large `OfflineTable` retains only thin dispatch.

`ObjectDocumentFileReader.inspect` and `read` now share their existing metadata
and grid preflight through a private prepared-read struct. Inspection does not
decode value windows; it does not authenticate value hashes. The existing
schema owner exposes a bounded parser factory and enforces the stock 1,000-
typed-path ceiling for writer inputs as well. No owner per JSON declaration
or nested type combination is introduced.

Root independently executed 86 focused DEBUG, 133 focused RELEASE and 2,194
full non-release examples; eight fresh bidirectional native/library stock
cases; five fresh whole-part writer regressions; four retained-stock reader
profiles; the example; and format/syntax/diff checks. The bounded hostile
verdict is ROBUST. Luna implementation and static review remain correlated
supporting evidence, not independent runtime verification. Exact identities,
commands, qualified REDs, failed-route corrections and decay conditions are
recorded in the capability frontier.

The accounting policy includes complete pending document owners before any
are retained, but measures them after decoding the current mark. It does not
establish allocator/RSS or decoder-transient peak bounds. Quiescent input is
required; per-mark metadata/grid work may repeat. Performance stays parked.
Mixed Object/scalar table batches, windows and PK candidate delivery remain
the next adapter. Large legacy shared type/substream planning, physical I/O
and leaf-codec responsibilities still need decomposition. Refresh the affected
gates after owner/dispatch/profile/budget/runtime/toolchain changes rather
than inferring behavior preservation from file count alone.

## Normalized Object table owners (W130, 2026-10-02)

Status: VERIFIED only for the W130 bounded table-delivery contract and executed
gates in `JSON_GENERAL_STORAGE_FRONTIER.md`, over `2097a88`. This CAUTION
dispatch/ownership addition does not complete the larger facade refactor.

Two cohesive private class owners each have a separate source file:

- `wide_part/selected_json_metadata_probe.cr` (153 lines): bounded metadata-only
  literal-Object dispatch, preserving the old dotted-name/virtual-path guard.
  It does not invoke unrelated physical codecs or semantically parse every
  unselected JSON declaration. The legacy scalar parser was not widened.
- `wide_part_table/object_column_adapter.cr` (60 lines): strict normalized
  Object opening and current-mark document-owner accounting, reusing
  `ObjectValuesMaterializationBudget` instead of a second recursive calculator.
  Complete pending documents are measured atomically after decoding.

The table facade retains the part/grid lifecycle, separate scalar/Object reader
entries, caller ordering and borrowed batch views. Object owners participate
in the existing shared remaining variable-sized mark budget; a whole-part
descriptor is not charged as the current mark. Offline-table dispatch binds
canonical whole-Object DDL without weakening the old virtual-path identity.
Whole-Object projection child delivery is explicitly refused pending its own
stock qualification. The native oracle covers two selected Object roots;
the existing writer still authors only one Object root beside a UInt64 key.

Root independently executed 16 final DEBUG, 133 focused RELEASE and all 2,210
non-release examples in 15 disjoint serial groups covering 346 spec files;
four fresh two-Object native profiles and one library-written stock ATTACH/
CHECK/read route; eight W129 and five W128 fresh regressions; the example;
and format/syntax/diff checks. Two combined-suite compilations were refused by
the unchanged resource guard, so grouped execution is not a combined-process
certificate. Root's bounded hostile verdict is ROBUST; Luna's static review
is correlated support, and its missed oracle NamedTuple access was corrected
from root's actual compiler failure. Exact commands and profile corrections
are in the capability frontier.

The remaining reader/writer/table/catalog facades have 15,985 / 25,991 / 7,171 /
3,692 lines. These counts make the unfinished decomposition visible, not an
architecture metric or a coupling/performance result. Shared legacy schema/
substream planning, I/O/validation, leaf dispatch and thin table/catalog
adapters still need responsibility-level extraction. Current-mark accounting
does not bound decode workspace, transients, RSS or caller retention;
metadata probing may repeat. Paired declared JSON typed-field expansion and
broader MV/projections remain open; optimization stays parked. Refresh the
affected gates after owner, dispatch, profile, budget, runtime or toolchain
changes.

## Reused normalized Object schema owners (W131, 2026-10-02)

Status: VERIFIED only for the declared Int64 profile in
`JSON_GENERAL_STORAGE_FRONTIER.md`, over W130 `4b18812`.
`ObjectDocumentSchema` and `ObjectDocumentSchemaParser` retain one cohesive
class/file each. Their nominal whitelist and exact canonical byte accounting
now include Int64. The shared fixed-width bulk owners and existing writer,
file/column reader, catalog materializer and table adapter are reused unchanged.
No per-type/per-declaration production class or duplicated facade codec was
introduced. Separate owners do not imply zero coupling or complete refactoring.

Root executed 18 focused DEBUG and 143 adjacent RELEASE examples, all 348
spec files in 15 disjoint non-release groups (2,220 examples), eight fresh
bidirectional stock matrix cells and the unchanged W128/W129/W130 stock
regressions. Root's scoped verdict is ROBUST. The initial oracle rejected
implicit Default metadata, then required a provenance correction and two
additional writer matrix cells; the measured route and final fingerprints
are preserved in the capability frontier. Static Luna agreement is correlated,
not the stock certificate. The grouped inventory is not a combined suite.

Large facades are unchanged at 15,985 reader / 25,991 writer / 7,171 table /
3,692 offline-table lines. Legacy schema/substream planning, I/O/validation,
leaf dispatch and thin adapters still need responsibility-level extraction.
Other declared typed families/layouts and broader MV/projection compatibility
remain open; performance stays parked. Refresh after schema, bulk, dispatch,
profile, limit, runtime, source or toolchain changes.

## Shared Object typed-field policy (W132, 2026-10-03)

Status: VERIFIED only for the paired numeric declared-field profile in
`JSON_GENERAL_STORAGE_FRONTIER.md`, over W131 `02dd99f`.
`object_typed_field_type.cr` contains one stateless cohesive module with a
closed tuple of nominal tags and canonical static names. Schema construction,
parser token resolution and canonical declaration sizing consume that same
policy. Token resolution compares a bounded byte slice without allocating a
general type/name before the existing budget charge. Unsupported tags have no
sizing fallback. Numeric field admission does not add a bulk codec or another
conditional branch to the legacy reader/writer/table facades.

Root executed 26 focused DEBUG and 151 adjacent RELEASE examples and all 350
spec files in 15 designated disjoint non-release groups (2,228 examples).
An interrupted guarded inventory was recovered by stopping only its validated
orphan process group and resuming from group 6; the capability certificate
records which completed groups count. It is not a combined-process certificate.
Eight fresh W132 stock matrix cells and fresh W131/W130/W129/W128 regressions
passed. The oracle's unquoted synthetic metadata fixture was corrected to
match stock's quoted column definitions; production catalog grammar was not
widened. Root's bounded hostile verdict is ROBUST; Luna's static work is
correlated support, not the runtime certificate.

The remaining large facades are unchanged at 15,985 / 25,991 / 7,171 / 3,692
lines (reader, writer, table and offline table). These are navigation counts,
not coupling or performance metrics. Legacy schema/substream planning,
I/O/validation, leaf dispatch and thin adapters still need decomposition.
Other Object typed families, recursive/physical profiles and broader
MV/projection compatibility remain open. Optimization stays parked. Refresh
the affected positives and negatives after policy, schema, bulk, dispatch,
profile, limit, runtime, source or toolchain changes.

## Reused Object policy and owners (W133, 2026-10-03)

Status: VERIFIED only for the bare Date/Date32 declared-field profile in
`JSON_GENERAL_STORAGE_FRONTIER.md`, over W132 `e043be7`. Production adds two
nominal entries to the existing shared policy. The fixed-width bulk, writer,
file/column reader, catalog and table owners remain unchanged. Date is not
UInt16 and Date32 is not Int32 despite identical carrier widths. No calendar
API, parameterized temporal grammar or new physical layout is admitted.

Root executed 34 focused DEBUG and 159 adjacent RELEASE examples; all 352
unique spec files passed in 15 disjoint non-release groups (2,236 examples)
in one completed runner invocation, not a combined-process suite. Eight fresh
native/library stock matrix cells and two separate raw Date32 transport cases
passed. Fresh unchanged W132/W130 stock regressions passed 8/5 cells. Root's
bounded hostile verdict is ROBUST. The failed first oracle fixture, its direct
typed-payload correction and final source/evidence fingerprints are retained
in the capability frontier. Luna's static work is correlated support.

The large facades remain unchanged at 15,985 / 25,991 / 7,171 / 3,692 lines
(reader, writer, table and offline table). Shared schema/substream planning,
I/O/validation, leaf dispatch and thin adapters still need decomposition.
Other Object declarations/layouts and broader MV/projections remain open;
performance stays parked. Refresh after policy, schema, bulk, dispatch,
profile, limits, runtime, source or toolchain changes.

The historical next-slice proposal (executed and qualified as W134 below)
extracts the nine existing Array/Map
slice/row classes at `wide_part_table.cr:80-463` into nine files under
`wide_part_table/`, with explicit aggregate imports. Preserve namespace,
names, visibility, generics, comments, budgets and retained slice ownership;
do not introduce new per-combination classes or change regular numeric Map
helpers. Exact class-body comparison and existing W80-W85 table/catalog tests
must guard against duplicate/omitted declarations and generic/lifetime drift.
This would improve navigation, not close responsibility-level orchestration
or prove lower coupling/performance. Its executed gates are recorded below.

## Array/Map row-owner extraction (W134) — pre-implementation design seal

Anchor: clean W133 `2e150f4`. Nine existing Array/Map slice/row classes occupy
`wide_part_table.cr:80-463`, including their W82/W83/W84 accounting comments.
The user requests readable, smaller class owners with one file per class.
This slice moves those existing classes without changing their responsibilities
or multiplying classes per type combination. Larger orchestration remains open.

Risk: CAUTION (generic type loading and borrowed slice lifetime). Rollback is
one atomic local commit over `2e150f4`, no push. Strongest failure: a declaration
is omitted/duplicated, a generic signature/visibility changes, or retained
array ownership/accounting diverges while shallow file-count checks pass.
Keep namespace, names, generics, bodies, comments, errors and limits exact.
Regular numeric Map helpers, aliases, adapters, codecs, type/profile admission,
serialization, dependency files and performance policy are outside scope.

Owners: Luna moves only the nine existing classes to separate
`wide_part_table/wide_part_array_map_*.cr` files and adds nine explicit imports
to `src/crystal_click.cr`; root owns the design/structural guard, all serial
compiler/stock checks, hostile review, navigation and scoped local commit.
No agent may execute compiler/ClickHouse jobs or stage/commit. Namespace
forward references are not assumed to have a parse-time require-order rule.

DoD: first `bash scripts/check_array_map_owner_extraction_w134.sh` must fail
only because the new owner files do not yet exist. After extraction it must
compare all nine class bodies/comments against the fixed checkpoint, verify
one unique declaration/file and one import each, and compare the remaining
facade and loader exactly. This structural check alone cannot prove runtime
ownership, generic instantiation or part compatibility.

Root then runs the six existing W80-W85 table specs in DEBUG and the same
six plus W80-W85 catalog, W83/W84 reader and W79 table specs in RELEASE.
A second Luna owns only a small direct public-owner W134 spec for independently
expected counters/payload accounting and retained slice-owner identity after
the row-owner's lexical scope ends and GC runs; include it in both focused
gates. This guards lifetime/generic behavior, not a new ownership API.
Use the recorded Crystal/macOS toolchain, isolated caches and single-module,
one-thread, `--link-flags=-fuse-ld=ld --error-trace` flags under the serial
resource guard (600 seconds, 32,768 MiB, minimum free memory 50%). These
exercise numeric/nullable/String/Bool/nested Array leaves, batch/window reads,
budgets and selected corruption guards; root reviews slice-owner retention.
Finally run all unique non-release specs in disjoint groups of at most 24
(`--no-debug`, guarded runner 900 seconds), a fresh unchanged W133 stock oracle,
formatter check, wrapper shell syntax, exact intended diff and hostile review.
Expected signals are zero failures/errors/outer exit 0, preserved rejection
guards, exact structural equality and clean hygiene. No capability widening
or performance inference follows from this refactor certificate.

## W134 executed extraction certificate (2026-10-03)

Status: VERIFIED only for the sealed behavior-preserving nine-class extraction.
Root's bounded hostile verdict is ROBUST. The fixed production baseline is
`2e150f4e4096d9a46e9f5654aa76390c9a139c70`; the intervening `de53620` commit
updates only the isolated ClickHouse source-reference document. Luna's static
implementation and spec work are correlated support, not the runtime evidence.

The numeric slice/base, numeric rows/base, nullable numeric rows, String rows,
Bool rows and nested Array rows/base each have a separate file under
`src/crystal_click/wide_part_table/`. The aggregate loader adds exactly nine
explicit imports. The structural guard compares every original class body and
comment byte-for-byte against its sealed baseline span, then compares the
entire remaining facade and loader. Names, generics, public visibility,
retained backing arrays, budgets, errors and unrelated numeric Map helpers
are unchanged. No class per newly admitted type combination was introduced.

Root executed the following on frozen production/spec source:

- Structural RED before extraction: exit 1 solely for the first missing owner.
  Final `bash scripts/check_array_map_owner_extraction_w134.sh`: exit 0.
  Two isolated-copy tamper controls rejected a changed row counter and an
  unexpected tenth owner import; production files were not mutated for them.
- Focused DEBUG: direct W134 owner spec plus six W80-W85 table specs,
  **22 examples**, zero failures/errors, outer exit 0. An earlier table-only
  exploratory check passed 16 examples but is not substituted for this gate.
- Adjacent RELEASE: those seven files plus six W80-W85 catalog specs,
  W83/W84 reader specs and W79 table spec: **37 examples**, zero failures/errors,
  outer exit 0. Direct fixtures independently exercise numeric/nullable,
  String/Bool and nested Array accounting, empty/NUL/Unicode/nil payloads and
  concrete generic/base interfaces. A numeric slice retains its backing-array
  identity and payload after the original row-owner scope ends and GC runs;
  this is not a universal GC/lifetime or memory ceiling certificate.
- Complete unique inventory: **353 spec files / 2,242 examples**, 15 disjoint
  serial non-release groups of at most 24 files, one completed guarded runner
  invocation, outer exit 0. Not a combined-process or full-RELEASE certificate.
  Existing duplicate `-lc` and deprecated `blocking` warnings were emitted;
  there were no failures/errors/pending examples.
- Fresh unchanged `scripts/check_object_dates_w133.sh`: four native and four
  fully library-owned String 0/1 × BASIC/COMPACT cells passed actual stock
  ATTACH/CHECK=1, full/PK calendar SQL, nominal/day-code/exact RowBinary and
  file/column/catalog/table consumers. Two separate raw Date32 Int32 extrema
  transport cases and seven seeded comparator failures passed. Temporary
  parts were fresh, retained at
  `/private/tmp/crystal-click-object-dates-w133.yyiNeY`; no existing server root
  or fixture part was modified. This rechecks W133's existing normalized
  Wide Object V3/Dynamic V3/MAP profile, not new type/layout compatibility.
- Formatter check for the loader/facade/nine owners/direct spec, shell syntax
  for both guards and `git diff --check`: exit 0.

Runtime gates use Crystal 1.21.0 / LLVM 22.1.8 on AArch64 macOS, SDK 26.5,
isolated caches, `--single-module --threads 1 --link-flags=-fuse-ld=ld
--error-trace`; inventory adds `--no-debug`, RELEASE adds `--release`.
Root alone runs compiler/stock jobs serially under `cogni-ml/scripts/run_safe.sh`,
minimum free memory 50%, 32,768 MiB, 600-second focused and 900-second
inventory/stock wrappers. The guard's FD/resource controls do not prove library
memory bounds or absence of leaks. Stock remains ClickHouse `26.10.1.1201`,
build `d9bcb5ab007f0f6299f7f973f2642245bab3d028`, executable SHA-256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
The new `f86ca42b` source checkout was not built or runtime-qualified.

Evidence index: `/private/tmp/crystal-click-w134-root.UyqLjy/`.
Temporary logs may expire; these hashes are identifiers, not substitute proof:

| File | SHA-256 |
| --- | --- |
| `focused-debug.log` | `61d1e9459f03949e14506c6b352447856bd15363b7281fd05a9281ce5fe44266` |
| `adjacent-release.log` | `83bdae6aaa61c24d57ce948a409f4b35df47732dfea743ca257db9d9fc9d7799` |
| `full-nonrelease-shards.log` | `a4929eeb3bb4c1db9bc6709f90c34602cb251fa9db64e51510bd368f06c7c01c` |
| `stock-w133-regression.log` | `ab1ae8747ec91e5bb0c4695c0f86d4b995cee102c22931a6c4ba4a5148651ec8` |
| `structural-red.log` | `0613358a476bb3efc2b0e69bed099b3cb0058a937eef3de92dc419cbbb15a917` |
| `structural-green-final.log` | `852fd4b02411b005eb6b6b8342c26eedb0ca4c2476b308ca03e2f88e6ebbb0f6` |
| `structural-seeded-body-final.log` | `a2cc84714ad8f2e34aaff67c96ec595c417d2fb77fcb72a4a46d3ff008de608e` |
| `structural-seeded-import-final.log` | `743880499dfee56fcdb8c1539d3681b394c3137ad78c501e239f1166bceb5d98` |
| `run_full_shards.sh` | `19408b515c7981dc6f79e47fee41f683f0ca69868b773406dba740e3b2e98a99` |

Frozen source fingerprints:

| File | SHA-256 |
| --- | --- |
| `src/crystal_click.cr` | `a91a8491ab0338745c723175ba8fc7d75d42725c739274999dede44b6498fd36` |
| `src/crystal_click/wide_part_table.cr` | `817050f5d8093c568e6cf494ee62357802f99157df3dfef0e13c8fe61062cd68` |
| `spec/wide_part_array_map_owner_w134_spec.cr` | `b053958a2506459ee141a1a4e8b3bc4064b86ae57d4543daddc2f099965fa851` |
| `scripts/check_array_map_owner_extraction_w134.sh` | `c2961f469cc18a2ee70fb947b705893797892d6973d00204918be94389f42e97` |

Each of the nine owner bodies is reproducibly anchored to the fixed baseline
by the guard's exact span comparisons. The unchanged stock driver fingerprints
are `73a35cf0d352d75f24efe3821e6c6ea8a5fb0ad5a7035c12b818848e031591a3`
(`check_object_dates_w133.sh`) and
`2c0dd6477b2a5addf1d29ca011a4d2cfc1adafbc2788e0f793a0d604d7603d61`
(`check_object_dates_w133.cr`). Reproduce focused gates with the selected files
above and the recorded flags/guard; inventory uses all unique sorted
`rg --files spec -g '*_spec.cr'` files in disjoint groups. Reproduce stock with
`CRYSTAL_BIN=/opt/homebrew/bin/crystal`, the pinned `CLICKHOUSE_BIN`,
`W133_KEEP_TMP=1` and `bash scripts/check_object_dates_w133.sh` under that guard.

Residuals and decay: table orchestration is still 6,786 lines, the reader
15,985 and writer 25,991. This does not establish lower coupling, speed parity,
all generic instantiations, arbitrary type composition or full MV/projection
support. Optimization remains parked. Refresh exact positives and tamper
negatives after loader, owner, generic, accounting, adapter, limit, profile,
runtime, baseline/source or toolchain changes. A missing or failed refresh
reopens this bounded certificate; it does not silently widen admission.
