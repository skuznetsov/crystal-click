# Compositional Tuple Frontier

Status: W94 named scalar-leaf Tuple and W95 typed table/catalog integration are
VERIFIED within the bounded Wide-part profile below. W91 neutral payload
ownership, W92 exact-Tuple empty-EOF repair and W93 exact-Tuple Default metadata
profiles retain their separately scoped evidence below. W95 supersedes W94's
next-action capsule without extending its old evidence to additional types.
W96's separate numeric-leaf extension and its current gates are recorded in
`NUMERIC_TUPLE_FRONTIER.md`; older W94/W95 results do not themselves certify
those additional identities. General recursive Tuple admission, semantic
leaf types and arbitrary-table writing remain open.
W97's separate Bool leaf frontier is in `BOOL_TUPLE_FRONTIER.md`; it preserves
one nominal row owner, decodes zero/nonzero truth, and writes canonical 0/1.
Root/Array/container Bool policy parity and other semantic Tuple leaves remain
open rather than inheriting W94-W96 evidence.
Continuation anchor: `3f09429`, with W90 debug/release and W80-W85 oracle
verification recorded in `MODULARIZATION_FRONTIER.md`.

## Confirmed problem

Before W94, the reader, table accessor, and writer supported the exact
`Tuple(a UInt64, b String)` profile. `WidePart.supports_tuple_uint64_string_type?`
and `WidePartTable#tuples_for` are exact-shape APIs; retain their behavior.
Before W95, `OfflineColumnValue` also retained only the exact
`Tuple(UInt64, String)` variant; W95 adds one nominal row type for the W94
compositional profiles, not one native union variant per arity.

The reader's scalar numeric/String methods validate the root column type,
so they cannot directly decode a child of a Tuple. The existing exact Tuple
reader decodes its two physical fields itself. The writer already invokes
private UInt64/String stream writers at `%2Ea` and `%2Eb`. Adding more complete
type-string branches would duplicate codec responsibilities rather than make
Tuple compositional.

Source reference: ClickHouse `a9581941254d6113f3740a8ec125ee7519cb1bda`,
`src/DataTypes/DataTypeTuple.cpp`. Each field delegates to its own serialization
under `SerializationNamed(..., TupleElement)`. Explicit names must be nonempty,
unique, and not `null`; unnamed fields use positional names `1`, `2`, and so on.
The factory accepts an empty Tuple. The pinned 26.7.1.1315 binary also accepted
zero- and one-field type-expression probes; persisted empty-Tuple behavior
has not been tested.

## Original proposed boundary and architecture

The following design preceded W91-W94; their observed results below determine
the currently admitted behavior.

First extract shared UInt64/String payload responsibilities without changing
admission or bytes. Writer leaf owners accept a logical physical prefix. The
reader's numeric bit decoder is already shared; root String and Tuple String
will share a context-free String materialization iterator. Keep root-schema
validation and context-sensitive stream/mark/frame checks in `WidePart` until
an explicit physical-stream context has its own separately verified boundary.
Each concrete owner should have one source file; do not add another full-type
Tuple codec to the existing monoliths.

Only after that seam passes parity checks, propose a named, nonempty Tuple
profile with UInt64/String leaves for both reader and writer. Use the existing
type-expression, stream-count, row, and byte budgets instead of an arbitrary
2-8 field limit. Restrict initial names to the supported simple identifier
grammar and distinguish that library guard from ClickHouse's wider grammar.
Empty, unnamed, recursive, nullable, and other scalar leaf profiles need
separate probes; their rejection does not mean ClickHouse rejects them.

Represent a Tuple as ordered field descriptors and columnar leaf buffers,
not a Cartesian union of `Tuple(T1, ..., Tn)` instantiations. Immutable metadata
records field name, leaf type, and physical prefix. An initially owned buffer
union grows linearly with admitted leaf types. Existing borrowed batches must
not be confused with a retained owned Tuple result; document copies and
lifetimes explicitly. Generic `OfflineColumnValue` row mapping is a separate
expansion, not part of this first profile.

Preflight selected schema/profile and stream/mark metadata before callbacks;
validate alignment and charge all fields of each materialized mark before
that mark's callback. Do not decode future payloads eagerly or promise that
corruption in a later mark prevents earlier callbacks. Validate all writer
fields and row counts before stage creation and retain failure cleanup.

## Next falsifier and verification

The first architecture falsifier is whether the same leaf implementations can
serve scalar and arbitrary Tuple prefixes without relaxing root admission or
copying payload codecs. Preserve the existing pair API's exact results and
bytes after the behavior-neutral extraction, including callback exceptions.

For the later admission slice, use a reordered
`Tuple(c String, a UInt64, b String)` across several marks and a short final
mark, with distinct empty/NUL/binary String values. Test 1, 2, 3, and 9 fields;
nine is a counterexample to an arbitrary cap, not a maximum. Reject unsupported
later fields, duplicate/reserved names, and mismatched vector lengths. An
injected stage-factory call counter must remain zero on invalid writer input;
an empty destination alone is insufficient evidence.

DoD: focused leaf/pair/composition specs, full debug and release suites,
`git diff --check`, format checks, and a pinned binary oracle exercising
stock-created -> Crystal-read and Crystal-written -> stock `ATTACH`/`CHECK`,
with full and ranged RowBinary equality. Passing type-expression probes does
not replace persisted-part evidence. Keep old pair tests and unadmitted-neighbor
guards, and obtain scoped hostile review before a compatibility claim.

Risk: CAUTION. Use separate atomic commits for behavior-neutral leaf ownership
and new type admission; each commit is its rollback boundary. Performance work
remains deferred until type and MV/projection frontiers close. The active goal
also retains the matched ClickHouse slowdown <=10% condition, not yet proven.
In-scope local implementation and tests remain authorized; push, a new binary
installation, and external data mutation are not authorized by this capsule.
Refresh this proposal if leaf consumers, admission, lifetime contracts, the
source reference, or the pinned executable/profile changes.

## W94 named scalar-leaf Tuple execution seal

Anchor: clean `bd6f32a1094b96e88c2de07719d3bbfbdc7cb035`. Source comparison
remains `a9581941254d6113f3740a8ec125ee7519cb1bda`; executable evidence will
remain pinned to ClickHouse 26.7.1.1315. This is CAUTION serialization/API work,
with one atomic W94 commit as rollback. No performance claim is intended.

Admit after verification: a nonempty root Tuple of named, unique, bounded ASCII
identifiers (`[A-Za-z_][A-Za-z0-9_]*`, at most 128 bytes, not `null`), each with
an exact scalar UInt64 or String leaf. Preserve declaration order, even for
repeated leaf types. Existing 4096-byte expression / 512-node parser limits,
metadata/stream/row/frame limits and one aggregate materialization limit govern
arity; do not introduce a small fixed field-count cap. Empty, unnamed, nested,
Nullable and other leaf types, Sparse serialization, Compact parts, and newer
master-only metadata stay rejected. These are library limits, not claims that
ClickHouse rejects those types.

Public contracts, with one concrete type per source file:

- `WideTupleField` and `WideTupleTypePlan`: immutable ordered schema metadata,
  parsed through the syntax-only `WideTypeExpression`, explicit exact leaf
  admission, and plan-derived physical names/roles. Schema parsing alone never
  establishes persisted profile compatibility.
- `WideTupleLeafColumn`: a named owned UInt64 or String buffer, cloning input
  arrays and String bytes. Buffer type is inferred, not caller-tagged. Accessors
  return copies so caller mutations cannot change a prepared writer input or
  retained reader result. This independent leaf input need not be row-aligned
  with its siblings; the writer must check that before stage creation.
- `WideTupleColumnData`: ordered schema plus aligned owned leaf columns, named
  lookup and row count; no Cartesian union of Crystal Tuple instantiations.
- `WidePart#read_tuple_mark_range(column, first_mark, mark_count,
  max_materialized_bytes: ...)`: owned range result after range-wide preflight.
  `each_tuple_mark_range` yields one owned result and mark index after that
  mark's all-field payload/charge validation. The budget may lower, never raise,
  the established 64 MiB limit. It is conservative logical accounting, not RSS.
- `WidePartWriter.write_uint64_tuple_pair(destination, key_name, keys,
  value_name, type_name, columns, rows_per_mark: ...)`: one UInt64 key plus one
  Tuple payload. Match every ordered declared field to its buffer name/type and
  validate all rows, keys, names, hashes, frame/stream/metadata budgets before
  invoking the private injected stage factory. Generate canonical schema from
  the validated plan, never from an unchecked second source of truth.
  The shared logical charge includes modeled row overhead; writer snapshots
  additionally charge eight bytes per UInt64 key, both range-wide and per mark.
  This stricter writer guard is not a claim about peak allocator memory or RSS.

Reader ownership: schema/value classes in separate `src/crystal_click/` files;
the private `WidePart::TupleReader` in `wide_part/tuple_reader.cr` owns actual
orchestration, with thin public delegates and narrow closure adapters for
existing private checks. Reopening the giant facade with all new orchestration
would not meet the requested owner-by-class boundary. Root/context policy remains
in `wide_part.cr`, whose exact pair metadata/stream dispatch becomes plan-driven
without relaxing root versions, Default records, physical inventory or EOF
guards. Empty EOF applies only to plan-identified String raw leaves, never to
size/UInt64 streams. Preserve exact pair accessors and table facades unchanged.
Before any iterator callback, check selected schema/profile and all selected
leaf mark schedules/row alignment. Payload checks are per mark: later payload
corruption may follow earlier callbacks. Aggregate read additionally checks
the entire selected range's rows and charge before allocating result buffers.
For this Tuple profile, an exclusive end mark at offset zero in the next
compressed frame must not decode that unselected frame: stop only when the
previous decoded frame's end proves the exact boundary. Do not apply this
change to other type families, interior-frame offsets, or non-EOF sentinels;
retain their existing boundary/trailing-byte guards. Check that an end mark
inside a compressed frame still rejects. Frame checks do not imply CRC
verification; the existing explicit checksum policy remains unchanged.
Bound String-size scratch before allocation or scan it without retaining one
size vector per field. Charge all numeric slots, empty String slots, modeled
container overhead and raw payload with checked sums, not N independent caps.

Writer ownership: separate cohesive `wide_part_writer/tuple_part_writer.cr`
responsibility, reusing W91 leaf stream encoders and existing publication,
checksum and key-index helpers; add only required monolith dispatch/plumbing.
Keep the original exact writer and staged-validator bytes unchanged. Private
factory injection is a test seam, not a new public allocator capability.
Root owns aggregate requires, this document and integration evidence. Reader
and writer own disjoint production/spec paths. Oracle owner owns new
`scripts/check_compositional_tuple_oracle.sh` and `.cr`; existing W93 oracle
remains an unchanged regression control. `WidePartTable` borrowed batches and
`OfflineColumnValue` generic row mapping remain a separately named follow-up,
not silently claimed by W94.

First falsifier before production: compile/run the new focused specs against
the missing public plan/buffer/read/write APIs, record the actual failure,
then implement. Guards include 1/2/3/9 fields, same-type field ordering,
String-first/all-String/UInt64-only shapes, independent marks, short final mark,
binary and all-empty Strings, input/result ownership, exact pair/scalar-root
guards, malformed/unsupported later fields, mark misalignment, per-mark callback
atomicity, checked aggregate slot/payload budget (including empty Strings), and
an injected stage-factory counter staying zero for invalid inputs.

DoD: focused plan/reader/writer specs in debug and release, full debug and
release suites, all with `--link-flags='-fuse-ld=ld'`; format checks,
`git diff --check`, shell syntax checks; unchanged pinned Tuple oracle plus new
persisted composition oracle. New oracle must measure stock -> Crystal and
Crystal -> stock ATTACH/CHECK, full/ranged RowBinary equality and exact physical
inventory for 1/2/3/9-field profiles. Exercise real Default and AlwaysDefault
metadata and inspect UInt64-only version maps rather than inferring them from
String-containing parts. Require scoped hostile review before admission.

Strongest failure mode: generalized dispatch accepts an incompatible physical
role or uncharged empty-String buffers. Guards above must prove rejection at
the intended boundary, not merely checksum failure or an empty destination.
Refresh this seal if API ownership, source/oracle version, stream policy or
admission changes. Full types/MV/projections and matched <=10% slowdown remain
the active goal; push, binary installation and external mutation are not
authorized by W94.

### W94 pre-production discriminator

At the anchor above, the plan-only focused spec was written before production.
Root executed `crystal spec spec/wide_tuple_type_plan_spec.cr
--link-flags='-fuse-ld=ld'` with the macOS 26.5 SDK and isolated W94 cache. It
exited 1 at spec line 16: undefined constant `CrystalClick::WideTupleTypePlan`.
This is a missing-API architecture red, not evidence of a defect in the exact
pair reader. No generic reader/writer runtime behavior was exercised by it.
The model/reader owner may now implement against that contract.

After the four model files and their aggregate imports existed, root executed
`crystal spec spec/wide_part_writer_compositional_tuple_spec.cr
--link-flags='-fuse-ld=ld'` in the same environment. It exited 1 at spec line
95: undefined `WidePartWriter.write_uint64_tuple_pair`. This is the actual
missing-writer-API red, not a runtime serialization failure. The writer owner
may now implement; reader/writer green gates and persisted-profile evidence
remain pending.

Root also created a fresh pinned-stock three-row Wide part with
`Tuple(n0 UInt64, n1 UInt64)` and required a successful `CHECK TABLE`.
Its actual metadata was version 1, propagation true and exactly
`types_serialization_versions: {"string": 1}`, despite having no String
leaf. The top-level records were `[payload, pk]`, with two positional Default
Tuple children. This refutes the inferred need to admit an absent or empty
type-version map for that UInt64-only profile; retain the strict map until an
actual persisted counterexample establishes a separate frontier.

The first hostile ownership review was refuted by root's installed Crystal
1.21.0 source: `String#dup` and `#clone` return `self`. Root then ran
`spec/wide_tuple_column_data_ownership_spec.cr` against the initial model
implementation: four examples failed, zero errors. Unsafe mutation of
test-owned String bytes changed retained payload, field metadata and canonical
plan metadata. This is a behavioral RED, not a missing-API signal. Replace
aliasing `dup` with explicit byte copies and retain these probes before any
ownership claim. `String#to_slice` is read-only, so a probe that writes through
that slice would only test `ReadOnlyError`; the discriminator intentionally
uses `to_unsafe` on fixture-owned bytes.

After explicit String byte copies replaced those aliases, root reran the
plan and ownership specs together: seven examples, zero failures/errors.
This closes the measured initial model alias bug only; generic reader/writer,
additional guards, full suites and stock interoperability remain pending.

The first combined runtime gate executed 36 examples and exposed an exact-pair
diagnostic regression plus an invalid corruption probe: flipping checksum bytes
does not exercise the default decoder's structural corruption checks. Preserve
the old exact-pair diagnostic and replace that probe with a zero decompressed
size in the second frame's header, without adding implicit CRC verification.
The corrected probe then executed 36 examples with zero failures and one error:
even a range selecting only mark zero decoded the corrupt, unselected end frame
one. This is the measured RED for the Tuple-scoped exclusive-boundary repair
above; moving the corrupt frame or weakening the callback assertion would not
close it. Debug/release focused and full suites plus both pinned oracles remain
required after this shared-kernel change.

### W94 observed result (2026-09-30 UTC)

State: VERIFIED for the seal's named UInt64/String-leaf Tuple profile in Wide
parts with exactly one UInt64 key and one Tuple payload. Lineage is clean
`bd6f32a1094b96e88c2de07719d3bbfbdc7cb035` plus this atomic W94 slice;
that commit is the rollback boundary. This does not admit arbitrary N-column
writing, recursive types, Sparse/Compact serialization, or generic table and
catalog value mapping.

The frozen implementation has four public schema/buffer owners, a private
Tuple reader owner, and three private writer/input/infrastructure owners,
each in its own source file. The existing facades delegate orchestration;
the larger reader, writer, table and catalog classes are not fully split.
Input and returned String bytes are explicitly copied rather than aliased by
`String#dup`. Writer preflight scans byte lengths without copying payloads,
then takes snapshots only after aggregate payload/slot/key charges pass.

Root executed the seven-spec focused gate in debug and release: each passed
37 examples, zero failures, errors or pending examples. It includes unsafe
fixture-byte ownership probes, exact-pair metadata/empty-EOF controls, and a
two-field 32 MiB-per-field writer case that passes individual frame limits but
exceeds the combined materialization charge: zero String snapshot calls and
zero stage-factory calls. The corrected lazy-frame probe reads mark zero
successfully, then yields only callback zero before rejecting selected corrupt
frame one. A separate interior-frame end-mark probe rejects. These checks do
not certify the unselected suffix's integrity or enable implicit CRC checks.

The full debug and release suites each passed 1,180 examples, zero failures,
errors or pending examples (test runtimes 34.6 s and 16.2 s, respectively;
these exclude compilation and are not ClickHouse performance comparisons).
All gates use Crystal 1.21.0 / LLVM 22.1.8 on aarch64, macOS 26.5 SDK,
`TMPDIR=/private/tmp`, an isolated W94 Crystal cache, and
`--link-flags='-fuse-ld=ld'`.

Both pinned `26.7.1.1315` Tuple oracles passed on this production/spec state:

- The unchanged exact-pair oracle verifies stock-created Default and
  AlwaysDefault full/ranged reads, retained Sparse rejection controls,
  library-written ATTACH/CHECK and full/key-range RowBinary equality, binary
  and empty Strings, independent marks and zero-byte all-empty raw streams.
- The new composition oracle verifies stock -> Crystal and Crystal -> stock
  ATTACH/CHECK, full/key-range RowBinary equality, and exact schema, stream and
  mark inventories. Its seven profiles exercise one String field, the exact
  pair control, three String-first mixed fields, nine alternating fields,
  three all-String fields, two UInt64-only fields, and three all-empty String
  fields under AlwaysDefault metadata. Stock physical mark row counts are
  `[2, 2, 2, 1, 0]`; public data-mark counts exclude the terminal sentinel.
  The UInt64-only profile independently retained the exact `{"string": 1}`
  type-version map rather than relying on an inference from String leaves.

The new oracle's first invocation failed before runtime because its selected
index helper returned a lazy `compact_map` iterator where `Array(Int32)` was
declared. The script-only repair materializes it with `.to_a`; the retry
passed. No production or spec changes occurred between the full-suite gates
and these oracle runs. This was an oracle compilation error, not a persisted
Tuple serialization failure.

Reproduction commands (the oracle scripts create their own isolated caches):

```sh
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
export CRYSTAL_CACHE_DIR=/private/tmp/crystal-click-w94-tuple-cache
export CLICKHOUSE_BIN=/Users/sergey/.local/bin/clickhouse
export TMPDIR=/private/tmp
crystal spec spec/wide_tuple_type_plan_spec.cr \
  spec/wide_tuple_column_data_ownership_spec.cr \
  spec/wide_part_reader_compositional_tuple_spec.cr \
  spec/wide_part_writer_compositional_tuple_spec.cr \
  spec/wide_part_writer_tuple_spec.cr \
  spec/wide_part_reader_tuple_empty_eof_spec.cr \
  spec/wide_part_reader_tuple_metadata_spec.cr \
  --link-flags='-fuse-ld=ld'
crystal spec spec/wide_tuple_type_plan_spec.cr \
  spec/wide_tuple_column_data_ownership_spec.cr \
  spec/wide_part_reader_compositional_tuple_spec.cr \
  spec/wide_part_writer_compositional_tuple_spec.cr \
  spec/wide_part_writer_tuple_spec.cr \
  spec/wide_part_reader_tuple_empty_eof_spec.cr \
  spec/wide_part_reader_tuple_metadata_spec.cr \
  --release --link-flags='-fuse-ld=ld'
crystal spec --link-flags='-fuse-ld=ld'
crystal spec --release --link-flags='-fuse-ld=ld'
bash scripts/check_tuple_oracle.sh
bash scripts/check_compositional_tuple_oracle.sh
crystal tool format --check src/crystal_click.cr \
  src/crystal_click/wide_part.cr src/crystal_click/wide_part_writer.cr \
  src/crystal_click/wide_tuple_field.cr \
  src/crystal_click/wide_tuple_type_plan.cr \
  src/crystal_click/wide_tuple_leaf_column.cr \
  src/crystal_click/wide_tuple_column_data.cr \
  src/crystal_click/wide_part/tuple_reader.cr \
  src/crystal_click/wide_part_writer/tuple_part_infrastructure.cr \
  src/crystal_click/wide_part_writer/tuple_part_write_input.cr \
  src/crystal_click/wide_part_writer/tuple_part_writer.cr \
  spec/wide_tuple_type_plan_spec.cr \
  spec/wide_tuple_column_data_ownership_spec.cr \
  spec/wide_part_reader_compositional_tuple_spec.cr \
  spec/wide_part_writer_compositional_tuple_spec.cr \
  scripts/check_compositional_tuple_oracle.cr
bash -n scripts/check_tuple_oracle.sh scripts/check_compositional_tuple_oracle.sh
git diff --check
```

Touched-file format, shell syntax and diff whitespace checks passed. Scoped
hostile review is ROBUST for this bounded profile: independent root ownership,
budget and lazy-frame falsifiers, both full suites and persisted pinned-stock
oracles support the result in addition to correlated same-lineage static
review. The exclusive-boundary guard requires an admitted Tuple plan, a
non-sentinel end mark, local offset zero and the exact decoded prior-frame end.
It neither verifies an unselected suffix nor enables implicit CRC checks.
The source snapshot is not an executable master oracle. New master's
`exact_num_defaults` metadata, full JSON and arbitrary recursive compositions
remain rejected or outside this certificate.

Evidence decays when admitted leaves/names, ownership, aggregate accounting,
metadata/stream/mark/frame policy, require order, fixtures, Crystal semantics,
or the pinned executable/profile changes. Refresh affected focused, full and
persisted-oracle gates before extending this result. The evidence-packet
template/validator remains unavailable; this source-linked frontier is the
curated fallback, not a validator-backed packet.

### W94 continuation capsule

Active goal: compatible read/write types and MV/projections before memory and
performance optimization; the matched ClickHouse slowdown <=10% target is
still unproved. Confirmed return pointer: W94's bounded low-level Tuple API
and its observed result above. Next falsifier: a three-field String-first
Tuple accessed through table/catalog column values and ranged scans, without
a Cartesian Crystal Tuple union, while unsupported schema/metadata is rejected
before the first callback. This requires an explicit new high-level value
mapping boundary; W94 does not silently provide it.

Further frontiers: additional scalar and recursive leaf profiles, full JSON,
new-master persisted metadata/layout probes, broader MV/projection support,
and cohesive owner extraction from the remaining reader/writer/table/catalog
monoliths. Do not mistake file splitting, parser acceptance or safe rejection
for completed storage compatibility. Local reversible implementation/tests and
coherent local commits remain authorized; push, new binary installation and
external data mutation still require separate authority.

## W95 high-level Tuple integration frontier

Status: VERIFIED within the W95 observed result below, anchored at clean
`ffc7cc8` plus this atomic integration slice. The following seal preceded
implementation. The full type/MV/projection and matched-performance goal
remains unchanged. W94's persisted profile is the low-level anchor; W95's
executed gates establish its own bounded table/catalog integration evidence.

Problem at `ffc7cc8`: `WidePartTable` and `OfflineColumnValue` still modeled the
exact `Tuple(a UInt64, b String)` row. The new W94 shapes could not yet be
consumed through typed table scans or `catalog[database][table][column].values`.
Increasing the closed union with every field-order/arity combination would
recreate the exact-type proliferation that W94 removed.

Proposed admission: every named UInt64/String-leaf Tuple already admitted by
W94, with the same Wide-part, metadata, name, stream and two-column physical
profile. Preserve the legacy exact-pair accessor/value representation. Route
the additional shapes through one nominal row representation and a cohesive
table adapter, one concrete owner per file. Do not add new low-level leaf
types, recursive compositions, Compact/Sparse or newer-master metadata here.

Proposed ownership: a row handle retains immutable owned columnar mark
backing plus a checked row index. Named value access must return a UInt64 or an
explicit copy of String bytes in O(1) leaf/row access; never clone an entire
column for each row. Retaining one row may retain the complete decoded mark;
this must be documented rather than called detached ownership or zero-copy
materialization. The batch slice remains callback-scoped. Catalog `.values`
returns its own row array and must not retain a borrowed slice.

Risk: CAUTION (public value union, callback and materialization boundaries).
Rollback is one atomic W95 commit, or only this slice's owned edits before
commit. Strongest failure: dispatch admits the schema but discovers a malformed
later field/schedule after callbacks, or omits String leaf/row-handle charges.
All selected parts/schema/leaf schedules must be checked before callbacks;
typed open already compares the complete schedules, including marks outside
a later window/candidate set.
Payloads remain per mark, so later payload corruption may follow earlier
callbacks. Table aggregate materialization limits and catalog row/String
limits must include all admitted leaves. Logical accounting is not peak RSS.

First falsifier: a String-first three-field library-written part, read through
typed batches and catalog column `.values`, with binary/empty Strings,
several marks and a short final mark. Before production changes, execute an
actual missing-API or behavioral RED. Negative controls: incompatible later
schema, equal-total mismatched leaf schedules, unsupported nested/nullable
leaves, returned-value mutation, callback exceptions, String budget across
all leaves, and unchanged exact-pair behavior. Full and selected key-range
results must match independently expected rows.

Guard-only execution plan: finish the bounded table/catalog consumer inventory,
seal the exact row and adapter APIs, write and run the RED specs, implement
through W94 owners without copied codecs, then run focused DEBUG/RELEASE and
full suites, pinned stock Tuple integration oracles, format/shell/diff checks,
and scoped hostile review. Root runs heavy gates serially with the shared
resource coordinator; workers may only inspect/edit their explicitly owned
paths. Source/profile, ownership, budgets or dispatch changes invalidate this
proposal and require an updated seal before implementation.

### W95 API, ownership and verification seal

The initial inventory incorrectly claimed that table-open logical mark counts
do not validate every Tuple child schedule. The integrated falsifier and source
anchor at `WidePart#initialize` refuted this: each physical stream's complete
`mark_rows` is compared with `expected_mark_rows` before typed open returns.
Keep that stronger eager schedule boundary, including unselected marks; do
not add a redundant table-selected schedule pass or read future payloads.

- `WideTupleRow` is an immutable struct in `wide_tuple_row.cr`, retaining owned
  `WideTupleColumnData` and a checked Int32 row index. Both its constructor and
  `WideTupleColumnData#row(index : Int)` reject negative/out-of-range indices
  before narrowing. `fields`, `type_name`, and named `[] : UInt64 | String`
  preserve declaration order and copy exposed metadata/String bytes. Internal
  cached field indices and scalar leaf access must avoid whole-column copies.
  `field_count` and `string_bytesize` expose no-copy accounting, not payload
  references. One retained row can retain its entire bounded decoded mark.
- Narrow `WidePart#tuple_mark_range_materialization_charge` accepts the
  existing checked public mark-range arguments and reuses `TupleReader`
  validation and charge calculation. It does not copy codecs or widen
  physical admission.
- Private `WidePartTable::TupleColumnAdapter`, one file under
  `wide_part_table/`, handles non-exact W94 shapes only. The existing typed-open
  owner validates complete schedules before any callback; no second
  table-selected schedule pass is needed.
  Its per-mark charge is W94's checked column charge plus a checked 64-byte
  row-array overhead and `rows * sizeof(WideTupleRow)`. Combine this with the
  existing selected-column aggregate before allocation/callback, and recheck
  observed charge before exposure. `WidePartTableBatch#tuple_rows_for` returns
  a borrowed callback slice; copying a row struct retains owned backing.
  Keep exact `tuples_for` and native pair values unchanged.
- Private `OfflineTable::TupleValuesMaterializer`, one separate file under
  `offline_table/`, handles non-exact Tuple values and all-leaf accounting.
  Add only `WideTupleRow` to `OfflineColumnValue`; do not enumerate arities.
  `.values(max_tuple_cells: ...)` and `materialize_selected_values` gain an
  optional tightening-only limit, default/hard cap 1,000,000 scalar Tuple
  cells. Check `expected_rows * field_count` before allocating the result;
  count empty String and numeric cells too. Existing 100,000 row and 64 MiB
  cumulative String-payload limits still apply across all Tuple String leaves.
  Validate all hard-limit options even for synthetic catalog selections.
  A tighter catalog String limit bounds accumulated returned payload, not
  transient memory: the current mark is decoded before catalog accumulation.

Ownership: row/model, TupleReader delegates and row specs belong to the model
worker; table facade/adapter and table specs to the table worker; catalog facade,
materializer and catalog spec to the catalog worker. Root owns aggregate imports,
frontier/evidence documents, heavy gates and integration. Workers are not alone
in the shared tree; no worker may build, stage, commit or overwrite others.
After model implementation, its worker may own the high-level oracle extension
in the existing compositional Tuple script, without changing its low-level
inventory or stock/library byte controls.

DoD is focused row/table/catalog plus W94 regression specs in DEBUG and RELEASE,
the full DEBUG suite, the pinned stock compositional Tuple oracle extended
through high-level full/window/candidate table and catalog APIs, format, shell
syntax and diff checks, plus scoped hostile source/counterexample review.
Commands use the existing macOS 26.5 SDK and `--link-flags='-fuse-ld=ld'`.
This integration slice declares no full RELEASE gate: W94's full RELEASE
evidence is not transferred, and focused RELEASE must be executed anew.
Root runs each gate only after actual resource release and a fresh >=55%
free-memory admission check; the running gate's safety floor is 50%.
The focused/oracle gates use polled free memory and have no watchdog/RSS
certificate. The larger full DEBUG gate additionally uses the inspected
host `cogni-ml/scripts/run_safe.sh` wrapper: 1,800-second watchdog, 32,768 MiB
process-tree RSS cap and `COGNI_RUN_SAFE_MIN_FREE_PCT=50`. These are kill guards,
not measured peak-memory results; the watchdog excludes deliberate daemonization.

The first catalog spec deliberately uses only existing APIs, so a missing new
row constant cannot mask its behavioral RED. The separate row API spec then
records a missing-API RED. Production remains frozen until those actual
outcomes are observed. Strong guards are later child schedule mismatch rejected
at typed open with zero callbacks, lazy later payload corruption with earlier
valid callbacks,
combined materialization charge, retained-row ownership, aggregate empty-cell
and String budgets, multi-part schema mismatch, exact-pair compatibility, and
independently expected full/window/sparse candidate rows. Callback exceptions
must propagate without extra callbacks. No benchmark or complete-type claim
is admitted by these gates.

Run the frozen gates serially after fresh resource admission; every GREEN
command must exit zero with no failed/error/pending examples or oracle
exception. These execution times are not matched benchmarks.

```sh
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
export TMPDIR=/private/tmp
export CRYSTAL_CACHE_DIR=/private/tmp/crystal-click-w95-cache
crystal spec spec/wide_tuple_row_w95_spec.cr \
  spec/wide_part_table_w95_tuple_spec.cr \
  spec/offline_catalog_w95_tuple_values_spec.cr \
  spec/wide_tuple_type_plan_spec.cr \
  spec/wide_tuple_column_data_ownership_spec.cr \
  spec/wide_part_reader_compositional_tuple_spec.cr \
  spec/wide_part_writer_compositional_tuple_spec.cr \
  spec/wide_part_reader_tuple_empty_eof_spec.cr \
  spec/wide_part_reader_tuple_metadata_spec.cr \
  spec/wide_part_writer_tuple_spec.cr --link-flags='-fuse-ld=ld'
# Run the same focused paths again with --release.
CRYSTAL_CACHE_DIR=/private/tmp/crystal-click-w88-cache \
COGNI_RUN_SAFE_MIN_FREE_PCT=50 \
  bash /Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh \
  /opt/homebrew/bin/crystal 1800 32768 spec --link-flags='-fuse-ld=ld'
crystal build --no-codegen examples/read_offline_column_values.cr \
  --link-flags='-fuse-ld=ld'
CLICKHOUSE_BIN=/Users/sergey/.local/bin/clickhouse \
  bash scripts/check_compositional_tuple_oracle.sh
CLICKHOUSE_BIN=/Users/sergey/.local/bin/clickhouse \
  bash scripts/check_tuple_oracle.sh
bash -n scripts/check_compositional_tuple_oracle.sh scripts/check_tuple_oracle.sh
# crystal tool format --check: all W95-owned Crystal paths, including imports.
git diff --check
```

### W95 pre-production observations

With production frozen at `ffc7cc8`, root executed the existing-API catalog
falsifier using the sealed SDK/linker and isolated W95 RED cache. The low-level
control passed: seven rows, four marks `[2, 2, 2, 1]`, and exact binary/empty
leaf values. The catalog call then raised `UnsupportedFormatError` with
`unsupported numeric column type` through `WidePartTable#read_numeric_values`.
The process exited 1: one example, zero assertion failures, one error,
25.34 ms execution. This is a measured missing-dispatch behavioral RED.

Root separately executed the row API spec in the same environment. It exited
1 at line 22 on undefined `CrystalClick::WideTupleRow`; no row runtime behavior
was exercised. Both processes are terminal. These signals authorize the sealed
integration implementation, not high-level compatibility or closure.

The first integrated DEBUG attempt exited 1 during test compilation on an
undefined local `type_name` in the new catalog spec; no runtime was exercised.
After the spec-only correction, a separate whitespace falsifier established
a second behavioral RED: matching DDL/physical `Tuple( a UInt64, b String )`
passed the low-level three-row control, but catalog `.values` raised
`selected table column type is unsupported` in its value dispatch. The plan
canonicalized the type while the legacy accessor required the exact raw
literal. Root observed one example, zero assertion failures, one error,
zero pending, exit 1 (21.37 ms). The correction must keep the raw canonical
literal on the legacy path and route other admitted spellings consistently
through the row API; this does not widen physical admission.

The first integrated runtime gate exited 1 (53 examples, two failures, one
error, zero pending). Two guards were invalid fixtures: overlapping part names
masked the schema mismatch, and a first-row expectation was repeated across
later callbacks. The schedule fixture also refuted the initial inventory:
typed open already rejected the later non-reference child mismatch at
`selected substreams have different mark row counts`, before scanning. The
smallest pivot removes the redundant new schedule delegate/adapter/table pass
and tests the existing eager rejection rather than relaxing it to admit an
unaffected window. Payload laziness remains a separate per-mark contract.

### W95 observed result (2026-09-30 UTC)

State: VERIFIED for high-level consumption of the existing W94 named
UInt64/String-leaf Tuple profile. Lineage is `ffc7cc8` plus the atomic W95
commit containing these owners, consumers, specs and oracle extension; that
commit is the rollback boundary. Physical admission and writer bytes are not
widened by this slice.

Three new concrete owners each have one file: public immutable `WideTupleRow`,
private `WidePartTable::TupleColumnAdapter`, and private
`OfflineTable::TupleValuesMaterializer`. Named scalar access uses cached field
indices and copies only the requested String bytes, not a whole leaf column.
Typed full, partial-row window and sparse candidate-mark scans expose row
handles. Catalog column `.values` retains its own array of those handles.
The exact raw `Tuple(a UInt64, b String)` keeps its native pair API; other
admitted spellings/shapes use the nominal row API consistently. The whitespace
fixture is a library dispatch guard, not a newly stock-persisted version claim.

Root observed the final frozen production/spec state pass all declared gates:

- Ten focused spec paths: 53 examples each in DEBUG and RELEASE, zero failures,
  errors or pending examples (test execution 435.69 ms and 321.92 ms).
- Full DEBUG: 1,196 examples, zero failures, errors or pending examples; test
  execution 33.84 seconds. The inspected external watchdog completed with
  `[EXIT: 0]` after approximately 128 seconds including compilation. Fresh
  admission was 76% free memory; the 1,800-second, 32,768 MiB process-tree RSS
  and 50% free-memory kill guards did not fire. No peak-RSS result is inferred.
  Full RELEASE was not declared or run for W95.
- Both pinned ClickHouse 26.7.1.1315 Tuple oracles exited zero. The composition
  oracle retains the seven W94 stock/library profiles, independent expected
  RowBinary, stream/schema/mark inventories and stock ATTACH/CHECK controls.
  It now also checks high-level full/window/sparse scans and catalog payload
  values on both stock-created and library-written attached parts. The
  unchanged pair oracle retains Default/AlwaysDefault, binary/empty/EOF and
  Sparse rejection controls.
- The column-values example passed `crystal build --no-codegen`. All 16 owned
  Crystal paths passed format checks; both shell scripts passed syntax checks;
  `git diff --check` passed. Production/specs stayed frozen between these gates.

The commands above use Crystal 1.21.0 / LLVM 22.1.8 on aarch64 Darwin, the
macOS 26.5 SDK and the explicit linker. Focused gates use the isolated W95
cache, full DEBUG the existing W88 cache, and oracles their temporary caches.
None of these execution times is a matched ClickHouse performance benchmark.

Scoped hostile verdict: ROBUST for this bounded high-level integration.
Root's actual whitespace RED, corrected runtime falsifiers, final source/diff
review and executed suites/oracles supplement correlated same-lineage static
reviews. Counterexamples cover oversized indices before narrowing, returned
String/metadata mutation, later child schedule mismatch with zero callbacks,
lazy later payload failure after an earlier valid callback, callback exception
termination, later-part schema mismatch, checked row/column charge overflow,
all-leaf String accumulation and empty/numeric Tuple cell limits. The removed
schedule pass is not needed: typed open already validates every complete
physical leaf schedule, including marks outside later selections.

Residual limits: a retained row can retain its entire owned decoded mark; a
tighter catalog String budget is checked after the current mark is decoded.
The limits bound modeled materialization/returned logical payload, not
transient allocation or RSS. The physical profile remains exactly one UInt64
key plus one Tuple payload in the admitted Wide Default/AlwaysDefault layout.
Nested/unnamed/empty Tuples, other leaves, Compact/Sparse and newer-master
metadata are not admitted. The large existing reader/writer/table/catalog
facades are not fully modularized. No complete-type or <=10% slowdown claim
follows from these results.

Evidence decays on changes to admitted plans or raw/canonical dispatch,
ownership/lifetime, row/cell/String/aggregate accounting, typed-open schedule
checks, mark/frame policy, require order, fixtures, compiler semantics or the
pinned executable/profile. Refresh affected focused, full DEBUG and persisted
oracles before extending this certificate. The evidence-packet skill's
template/validator is unavailable; this curated frontier is the fallback,
not a validator-backed packet.

### W95 continuation capsule

Active goal: complete compatible read/write types and MV/projections before
memory/performance optimization; the matched ClickHouse slowdown <=10% target
remains unproved. Confirmed return pointer: the W95 observed result above and
`examples/read_offline_column_values.cr`. The previous high-level three-field
Tuple falsifier is closed within W94's physical profile.

Next proposed boundary: extend a shared Tuple leaf contract to an additional
already supported scalar type for both reader and writer, rather than add
more exact whole-type branches. First discriminator: a stock-created and
library-written mixed Tuple with a non-UInt64 numeric leaf, multiple marks,
binary/empty String siblings and full/window/catalog equality; retain strict
rejection of unsupported recursive and physical neighbors. Inventory and
seal that leaf's codec/serialization/admission responsibility before editing.
This is a proposal, not an admitted new type or an authorized master binary
installation. Full JSON, wider compositions, current-master metadata/layout
probes, broader MV/projection support and remaining cohesive owner extraction
are still open. Local reversible implementation/tests and coherent local
commits remain authorized; push and external data mutation require separate
authority. Resource scheduling grants expire with their reported batch release.

## W91 behavior-neutral execution seal

The inventory falsified the assumption that physical stream decoding can move
to a context-free leaf owner: `WidePart#each_mark_range_bytes` derives empty-EOF
and frame/profile admission from the selected root type and physical stream
names. Do not copy or relax that logic. This slice owns payload assembly and
encoding only; generic Tuple admission and physical-stream-context extraction
remain PROPOSED.

Ownership and paths:

- Reader: `wide_part/string_payload_decoder.cr`, private
  `WidePart::StringPayloadDecoder.each`, and its callers in `wide_part.cr`.
  Yield Strings and indices directly into existing scalar/Tuple result arrays;
  do not add intermediate String/UInt64 arrays. Tuple uses the existing
  `decode_numeric_value(..., UInt64)` bit decoder. Preserve root admission,
  row alignment, budgets, selected-range validation and error ordering.
- Writer: `wide_part_writer/leaf_stream_writer.cr`, private
  `WidePartWriter::LeafStreamWriter`; move the actual UInt64/String payload
  method bodies, not just a wrapper. Extract private `ChecksumRecord` and shared
  `StreamEncoding` into their own files if required, preserving nominal record
  identity. Existing private writer entrypoints remain delegates. Schema
  preflight, stage lifecycle, checksum aggregation and staged validation stay
  in the writer.
- Root integration: aggregate requires, this frontier, and
  `scripts/check_tuple_oracle.sh`. Worker-specific specs are
  `wide_part_reader_payload_seam_spec.cr` and
  `wide_part_writer_leaf_seam_spec.cr`.

Pre-change discriminator: establish the missing-owner architecture red before
production changes. Reader seam compile-red exited 1 on the undefined private
owner; writer owner-file existence probe exited 1 while Crystal builds were
held for the user-requested Qwen memory slot. No pre-change writer seam compile
was executed; the later green gate must not be presented as that red. These
are architecture-existence probes, not evidence of a pre-existing behavioral
defect. Negative controls cover exact Tuple/scalar-root admission and wrong
escaped physical prefixes. Existing
scalar/String/Tuple specs establish decoded bytes, independent marks, empty
streams, short final granules and failure cleanup.

DoD commands: the two seam specs plus existing fixed numeric, String/nullable,
W23 reader and writer scalar/typed/Tuple specs (including
`wide_part_writer_typed_spec.cr` for mixed/all-null `Nullable(String)`); full
`crystal spec` and `crystal spec --release`, each with
`--link-flags='-fuse-ld=ld'`; format checks
for touched Crystal files and `git diff --check`; pinned
`bash scripts/check_tuple_oracle.sh`, `bash scripts/check_typed_writer_oracle.sh`
and `bash scripts/check_wide_part_writer_oracle.sh`. Expected signal is zero
failures and byte-exact pinned oracle checks, not improved performance.

Strongest failure modes: root admission accidentally becomes child admission;
escaped String `.size` prefixes, terminal marks or all-empty frames change;
writer cleanup/checksums change through helper extraction. Guard with negative
root/prefix tests, exact raw-byte and mark assertions, binary/all-empty String
oracles, and full-suite coverage of the shared UInt64 writer's consumers.
Rollback is one atomic neutral-seam commit. The declared neutral-seam DoD
passed below; it does not certify new type or metadata admission.

### Stock-created metadata counterexamples (pre-extraction)

The new pinned 26.7.1.1315 stock-created Tuple probe read the admitted mixed
`id UInt64, payload Tuple(a UInt64, b String)` profile at sparse ratio 0.9375,
including full and mark-range binary equality. It then falsified broader
reader compatibility on three independently stock-created profiles:

- Ratio 1.0 omits per-column serializer records; the reader demands two.
- `pk` before `payload` in `columns.txt` differs from stock serializer-record
  ordering; the reader incorrectly treats record order as a format boundary.
- All-empty child String values at ratio 0.9375 select Sparse child metadata;
  the reader admits only Default child serialization and physical streams.

Keep those explicit rejection controls in W91. Reordered/omitted Default
metadata needs a separate admission fix before generic Tuple expansion;
Sparse child serialization needs its own physical-stream plan. A negative
control certifies safe rejection, not closure of the requested compatibility.
The final edited oracle and full release suite passed after extraction, with
these rejection controls retained. Do not infer newer-master binary support
from these pinned 26.7 runtime observations.

### Separate next boundaries (source inventory only)

The smallest metadata admission proposal is to validate the exact top-level
serializer-name set rather than record order. Preserve uniqueness, completeness,
per-role field/count/kind checks, and positional Tuple child order. An exact
empty `columns` list is a distinct stock AlwaysDefault metadata profile; do
not infer it from an arbitrary missing or partial list. At the reference
commit, `SerializationInfoByName` is a `std::map` in
`SerializationInfo.h`, its `writeJSON` iterates by name, and its constructor
omits entries when `settings.isAlwaysDefault()` in `SerializationInfo.cpp`.
Both proposals retain the current outer metadata/version and exact physical
stream checks. Duplicate, partial, unexpected, and Sparse records are the
negative controls. This is not yet an admission design seal or implementation.

Source inventory also found two different existing EOF policies:
`parse_marks` allows the exact Tuple `%2Eb` raw stream's positive-row marks at
EOF, but `each_mark_range_bytes` has no corresponding Tuple empty-payload
case. Both the exact Tuple read and raw-byte preflight call that range reader,
even for zero expected bytes. The writer omits empty String frames, and its
staged validator deliberately skips empty raw-frame readback. The cheapest
next runtime falsifier was therefore a library-written one-row
`Tuple(a UInt64, b String)` with `{7_u64, ""}`, followed by full/ranged reads
and raw-byte preflight. This was a source-only prediction in W91; W92's
public-path red and bounded repair are recorded below.

A future neutral physical-stream owner must derive and retain separate
mark-EOF and range-EOF rules at admission, rather than silently unify them.
It also needs the existing frame-profile/error-order policy: unrestricted,
Variant LZ4, Dynamic LZ4, or Array(Map) LZ4 with its checksum-first corruption
guard. Re-stat the file per operation, retain callback-scoped mmap/chunks and
an operation-local decode workspace, and reuse checksum/bit helpers. Fixing
the Tuple EOF mismatch is a separate compatibility action before or after
that extraction, not an unannounced part of W91. Both routes remain PROPOSED.

### W92 exact-Tuple empty-EOF execution seal

At source `5c8b850`, `spec/wide_part_reader_tuple_empty_eof_spec.cr` ran through
the public writer -> `open_typed` -> raw-byte preflight path. The command
`crystal spec spec/wide_part_reader_tuple_empty_eof_spec.cr
--link-flags='-fuse-ld=ld'` exited 1: four examples, three errors and the
nonempty control passed. One empty row, five all-empty rows with a short final
mark, and trailing empty marks after nonempty data all reached
`empty payload range at EOF must select zero expected bytes`. Each test first
verified published raw-file size and physical raw-mark offsets/row counts.
This confirms the range-policy mismatch, not a generic Tuple admission gap.
Those three red examples stopped at preflight, before their value-read
assertions; source inspection showed both methods use the same range walker.

Admitted change: in `WidePart#each_mark_range_bytes`, recognize only
`#{@column}%2Eb` for the already admitted exact `Tuple(a UInt64, b String)`
root as an empty payload stream, matching its existing mark admission.
Keep the zero expected-byte requirement, zero decompressed offsets, exact EOF
boundary, numeric/size-stream rules, root admission and metadata rejection.
No writer bytes, public API, generic Tuple shape, Sparse serialization,
metadata order or omitted-record policy changes belong to this slice.

Risk: CAUTION (a shared corruption guard). Strongest failure: accidentally
admitting a zero-byte stream when its size leaf demands nonzero bytes, or
exempting the numeric/size leaves. Add a valid-frame-checksum counterexample
with nonzero declared String bytes and empty raw data; both preflight and read
must still raise `CorruptPartError`. Keep exact physical-file/mark assertions,
the nonempty control and existing scalar-root/metadata rejection checks.

Plan and ownership: production owner changes only the exact Tuple branch in
`src/crystal_click/wide_part.cr`; spec owner adds the negative guard and gives
the spec/helper names W92 identity. Root integrates Crystal all-empty reads
into `scripts/check_tuple_oracle.sh` and records observed evidence here.
Consumer inventory: `rg -n 'tuple_uint64_string_mark_range_raw_bytes|
read_tuple_uint64_string_mark_range' src spec scripts` finds the exact reader
methods and the table batch preflight/materialization consumers, W23 specs,
and Tuple oracle. Both exact reader methods call the shared range walker;
all other leaf readers retain their existing predicates. The corresponding
mark policy already recognizes this exact raw stream.
Do not extract the physical-stream owner in this bugfix.

DoD: focused EOF, reader seam, W23 and writer Tuple specs in debug and release;
full debug `crystal spec`; pinned `bash scripts/check_tuple_oracle.sh` with
Crystal full/ranged all-empty equality as well as stock ATTACH/CHECK;
touched-file format, shell syntax and `git diff --check`; scoped hostile
review of the shared-guard change. Expected signal: all green, including
nonzero-size/empty-raw rejection. W91's earlier full release run is not
post-W92 verification. Rollback: one atomic bugfix commit, or discard only
this slice's owned edits before commit. Evidence decays on range/mark policy,
Tuple consumers/metadata, fixture, compiler or pinned-binary changes.

A separate writer inventory found 170 public `write_*` entrypoints, all
constrained to a UInt64 key and one top-level payload column, including the
generic typed-pair and multi-path JSON facades. More Tuple fields do not make
this an arbitrary-table writer. The smallest future lifecycle boundary is a
private schema-driven staged-part owner: ordered column/stream descriptors,
common row/mark layout, an explicit index profile, per-column validation,
metadata/checksum/index production, exclusive publication and cleanup. An
initial UInt64 index profile would still be constrained N-column writing;
other primary keys need separate admission. Existing validators do not
uniformly assert complete file inventories or every recorded hash, so the
new contract must not silently upgrade those guarantees. This inventory
does not authorize that refactor inside W91 or admit a new writer API.

## W91 observed result (2026-09-30 UTC)

State: VERIFIED within the aggregate `require "./crystal_click"` boundary.
The frozen source is `015fa2f` plus this neutral extraction. Four concrete
owners each have one file: private reader `StringPayloadDecoder`, writer
`LeafStreamWriter` and `StreamEncoding`, and the original private
`ChecksumRecord` struct. The reader yields owned Strings directly into the
existing result arrays, without intermediate leaf arrays. Root admission,
physical stream/range rules, budgets, stage preflight, validation, publication
and cleanup remain with their previous owners. No new Tuple shape is admitted.

Root mechanically compared ten moved declarations/bodies, including the
checksum record, with `015fa2f`: they were identical after indentation,
private-method visibility and helper qualifier normalization. The 13 new
examples cover owned binary/empty/multibyte Strings, UInt64 bounds, callback
exceptions, exact root rejection, arbitrary escaped physical prefixes,
independent marks, terminal offsets, checksums and zero-byte String streams.

Observed DoD: 72 focused examples, 1,145 full debug examples and 1,145 full
release examples, each with zero failures/errors/pending. Debug test execution
took 37.94 seconds and release 18.65 seconds; compilation is excluded, and
neither timing is a matched reader benchmark. All three pinned
`26.7.1.1315` oracles passed:

- Tuple: stock-created mixed Default profile -> Crystal full/mark-range
  RowBinary equality and strict scalar-root rejection; reordered, omitted and
  Sparse metadata remain explicit negative controls. Crystal-written parts
  -> stock ATTACH/CHECK and full/key-range RowBinary equality, including
  binary/empty Strings, independent marks and a zero-byte all-empty raw stream.
- Typed writer: 22 scalar/Nullable shapes plus all-null/all-empty controls,
  exact stock rows/key ranges, ATTACH/CHECK and independent corruption checks
  for nonempty selected streams.
- Basic writer: UInt64, Nullable and mixed/all-empty String parts, exact stock
  full/key-range results, ATTACH/CHECK, and index/null-map/raw/size-stream
  corruption detection.

Execution environment and commands:

```sh
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
export CRYSTAL_CACHE_DIR=/private/tmp/crystal-click-w88-cache
export CLICKHOUSE_BIN=/Users/sergey/.local/bin/clickhouse
export TMPDIR=/private/tmp
crystal spec spec/wide_part_reader_payload_seam_spec.cr \
  spec/wide_part_writer_leaf_seam_spec.cr \
  spec/wide_part_reader_w23_spec.cr spec/wide_part_writer_tuple_spec.cr \
  spec/wide_part_writer_spec.cr spec/wide_part_writer_typed_spec.cr \
  spec/string_nullable_scan_spec.cr spec/fixed_numeric_scan_spec.cr \
  --link-flags='-fuse-ld=ld'
crystal spec --link-flags='-fuse-ld=ld'
crystal spec --release --link-flags='-fuse-ld=ld'
bash scripts/check_tuple_oracle.sh
bash scripts/check_typed_writer_oracle.sh
bash scripts/check_wide_part_writer_oracle.sh
```

The focused gate used a separate `crystal-click-w91-focus-cache`; each oracle
creates its own temporary cache. Crystal is 1.21.0, LLVM 22.1.8, on aarch64
Darwin. Touched-file Crystal format, Tuple shell syntax and diff whitespace
checks passed. The evidence-packet skill's referenced template and validator
are absent from its installed directory and this repository; this frontier
is the curated fallback, not a validator-backed JSON packet.

Scoped hostile source review returned ROBUST for neutral ownership at the
aggregate import boundary. Same-lineage reviews are correlated; root's
mechanical comparison and executed suites/oracles are the additional evidence.
Direct internal-file imports, mutable caller inputs during synchronous writes,
generic Tuple admission, Sparse/omitted/reordered metadata compatibility and
current-master runtime compatibility are outside that verdict. At W91 closure
the predicted all-empty Tuple reader EOF mismatch was still unexecuted;
the empty-payload seam tests and stock writer acceptance did not close it.
W92 subsequently reproduced that counterexample as recorded above.

Evidence decays if owner bodies, root admission/range policy, require order,
Crystal semantics, fixtures or the pinned executable/profile change. Re-run
the affected focused/full/oracle checks rather than transferring this result
to new types. The full type/MV/projection goal and matched slowdown <=10%
condition remain open. The W91 return pointer was the exact Tuple empty-EOF
counterexample; after its separate W92 verification, next is to admit stock
Default metadata profiles separately before generic Tuple expansion. Push
still requires new authority.

## W92 observed result (2026-09-30 UTC)

State: VERIFIED for the existing exact `Tuple(a UInt64, b String)` profile.
Lineage is `5c8b850` plus the two-line range-policy change, the six-example
public-path EOF spec and the oracle's post-ATTACH Crystal read checks. Only
the raw `%2Eb` leaf gains empty-EOF recognition; zero expected bytes, zero
decompressed offsets, exact EOF, root/metadata admission, numeric/size leaves
and writer bytes remain unchanged. All-empty and trailing-empty selected
ranges now return their exact values and zero-byte preflight results.

The first expanded debug attempt did not establish the corruption guards:
two fixture setup errors occurred because its checksum refresh tried to
decode a legal zero-byte compressed stream. That invalid probe was corrected
in the spec only. Empty compressed entries must declare zero uncompressed
bytes and use the empty raw hash without decompression; nonempty entries are
still decoded. The corrected fixture changes the first String size from 0
to 1, re-encodes a valid CityHash-protected frame with unchanged file/frame
length, refreshes part checksum records, and retains the zero-byte raw file
and marks. Both public preflight and value read then reject with the precise
EOF guard error. Separate numeric/size mark mutations reject at mark parsing;
they do not dynamically test a numeric exemption in the range walker.

Observed DoD on frozen production/spec/oracle source:

- Focused debug: 23 examples, zero failures/errors/pending (61.62 ms test
  execution). Focused release: the same 23 examples, zero failures/errors/
  pending (48.61 ms). Compilation is excluded; these are not benchmarks.
- Full debug: 1,151 examples, zero failures/errors/pending (35.46 s test
  execution). The linker emitted the existing duplicate `-lc` warning.
- Pinned `26.7.1.1315` Tuple oracle passed: stock-created admitted Default
  full/mark-range reads, retained reordered/omitted/Sparse rejection controls,
  stock ATTACH/CHECK and full/key-range byte equality for library-written
  parts, plus Crystal full/ranged all-empty reads after stock ATTACH.
- Touched Crystal format, shell syntax and diff whitespace checks passed.
  No post-W92 full release suite was declared or run; W91's full release
  evidence is not transferred to this changed range policy.

Commands (SDK/temporary directory are as in W91):

```sh
export CRYSTAL_CACHE_DIR=/private/tmp/crystal-click-w92-tuple-empty-red-cache
crystal spec spec/wide_part_reader_tuple_empty_eof_spec.cr \
  spec/wide_part_reader_payload_seam_spec.cr \
  spec/wide_part_reader_w23_spec.cr spec/wide_part_writer_tuple_spec.cr \
  --link-flags='-fuse-ld=ld'
crystal spec spec/wide_part_reader_tuple_empty_eof_spec.cr \
  spec/wide_part_reader_payload_seam_spec.cr \
  spec/wide_part_reader_w23_spec.cr spec/wide_part_writer_tuple_spec.cr \
  --release --link-flags='-fuse-ld=ld'
CRYSTAL_CACHE_DIR=/private/tmp/crystal-click-w88-cache \
  crystal spec --link-flags='-fuse-ld=ld'
bash scripts/check_tuple_oracle.sh
crystal tool format --check src/crystal_click/wide_part.cr \
  spec/wide_part_reader_tuple_empty_eof_spec.cr
bash -n scripts/check_tuple_oracle.sh
git diff --check
```

Scoped hostile source review returned ROBUST for the exact EOF exception,
not for broader types. Same-lineage review is correlated; root independently
inspected the exact diff and executed the regression/oracle gates. A selected
range does not promise to validate payload corruption confined to unselected
marks. Stock-created all-empty Sparse remains rejected; library-written
Default acceptance does not prove stock all-empty Default compatibility.
The evidence decays on the W92 seal's range/mark/admission/compiler/fixture/
binary changes and must be refreshed at those boundaries.

### Continuation capsule

Active goal: complete type read/write compatibility and MV/projection
frontiers before performance work; the matched <=10% slowdown condition is
still open. W92 closes only the exact Tuple EOF mismatch. The next local
frontier is W93 Default metadata admission, still PROPOSED: two unique records
matched by the exact key/payload name set regardless of top-level order, and
exact `columns: []` as a separate AlwaysDefault profile. Missing, partial,
duplicate, unexpected and Sparse profiles remain rejected. Preserve root
fields/version, nested String version, schema, child count/order and physical
streams. Anonymous Tuple child records carry no names: swapping identical
records is not a meaningful detectable child-order falsifier; reversed schema
is. Start with real stock reordered/ratio-1.0 parts and full/ranged byte
equality, not hand-edited positive metadata. The strongest new negative is
a stock Sparse part with its records erased and valid checksum refresh,
which must still fail the exact Default physical-stream inventory.

Next source/spec pointers: `validate_tuple_uint64_string_serialization` in
`wide_part.cr`, the current stock-profile rejection helpers in
`check_tuple_oracle.sh`, and the fresh source's
`SerializationInfoByName::writeJSON`/AlwaysDefault constructor in
`SerializationInfo.cpp`. Fresh master can emit optional
`exact_num_defaults: true` (`SerializationInfo::writeJSONFields`); the current
exact metadata-key sets reject it. That is a separate unadmitted profile,
not evidence that W93's pinned binary covers master. No W93 edits or probes
have been executed. In-scope local implementation/tests/atomic commits remain
authorized; push, binary installation and external data mutation do not.
All W92 heavy processes are terminal. Check the latest explicit Qwen resource
release before each next heavy launch; the historical release is not a lease.

## W93 exact Tuple Default metadata execution seal

Status: VERIFIED within the observed DoD below; pre-change anchor `99f9d6b`.
The fresh source
anchor is `a9581941254d6113f3740a8ec125ee7519cb1bda`, not the pinned executable.
`SerializationInfoByName` is a `std::map` and `writeJSON` iterates its name
order; that order is not the column declaration order. Its constructor returns
without records when `isAlwaysDefault()` is true (sparse threshold >= 1.0);
Sparse selection requires a default ratio strictly above that threshold.

Admit only two metadata profiles for the existing exact
`Tuple(a UInt64, b String)` plus one UInt64 key schema:

- Exactly two uniquely named Default records, whose names are the exact
  key/payload set. Match by name, not array position; retain exact record
  fields, child count, row counts and default-count bounds.
- Exactly `columns: []`, as a separate AlwaysDefault profile. This is not a
  missing/partial-record fallback. Retain every root/version/propagation gate
  and the exact Default physical-stream inventory.

Reject missing, partial, duplicate, unexpected, malformed and Sparse records;
retain exact root fields/version 1, nested String version 1, true propagation,
schema and physical stream order. Optional master `exact_num_defaults` remains
unadmitted. Anonymous child records have no child names: swapping identical
records is not an observable child-order guard; reversed schema is. No generic
Tuple shape, new writer bytes, physical-stream extraction, or benchmark is
included in this slice.

Risk: CAUTION (serialization admission). Strongest failure: accepting an empty
record list as permission to decode Sparse bytes as Default. The guard probe
is a stock-created Sparse part copied locally, with records erased and valid
part checksums refreshed; admission must still reject its physical inventory.
Local temporary parts only; no external data mutation or binary installation.
Rollback is one coherent local atomic commit; do not mix the next architectural
owner or generic Tuple admission into it.

Owned paths: `src/crystal_click/wide_part.cr` (minimal validator change),
`spec/wide_part_reader_tuple_metadata_spec.cr` (public API profile/guard tests),
`scripts/check_tuple_oracle.sh` (real stock positives and Sparse bypass probe),
and this frontier document. First freeze and execute red profile tests on the
unchanged production source. Stock positive metadata must be produced by the
pinned binary, not edited into existence. Unit metadata mutations must refresh
checksums so their failure discriminates metadata/physical guards.

DoD: focused metadata, W92 EOF, payload seam, W23 reader and Tuple writer specs
in debug and release; full debug suite; pinned 26.7.1.1315 Tuple oracle with
stock-created full/ranged byte equality and stock CHECK plus retained
library-written ATTACH/CHECK/full/key-range equality; format/shell/diff checks;
scoped hostile review. No full release suite is declared for this bounded
metadata slice; prior full release evidence is not transferred. Root owns the
heavy execution window and alternates it with the Qwen diagnostic thread.
The latest explicit release before preparation was 04:06 UTC on 2026-09-30.

Refresh evidence on admission, schema, stream inventory, count/mark policy,
fixture/checksum helper, compiler or pinned-binary changes. Passing these gates
will close these two exact metadata profiles, not generic Tuple, master-wide
compatibility, all types/MV/projections, or the <=10% slowdown objective.

### W93 pre-change observations

Production remained byte-for-byte unchanged at `99f9d6b` for these probes.
The first oracle attempt was invalid as a reader falsifier: its fixture
asserted Tuple name formatting without the space after the comma, whereas the
stock binary emitted `Tuple(a UInt64, b String)`. Only that assertion changed.
The first focused attempt additionally expected a missing `columns` field to
reach the missing-array guard; the exact root-key guard correctly rejected it
earlier. Only the expected rejection message changed, not production.

The corrected focused command ran eight examples: six guard groups passed,
and the two positive profiles failed precisely at the order and required-two-
records gates (zero assertion failures, two errors, 82.84 ms execution). The
corrected pinned stock oracle then passed its original id/.9375 profile,
full/ranged reads and CHECK, asserted the reordered pk/.9375 profile, and
failed at `Tuple serializer order does not match columns.txt` through the
public reader. The stock empty-record positive was not reached in this red
oracle; its actual persisted behavior still requires the post-change oracle.
These observations authorize the minimal validator change, not its closure.

Both red processes are terminal. Root released the heavy window after them
for the Qwen thread's separately reviewed, bounded one-block CPU diagnostic;
only light implementation/static work is allowed until its explicit release.

### W93 DoD commands

Use the declared SDK, temporary directory and isolated focused cache. Run
these heavy commands sequentially, only in a freshly released resource window;
each green gate must exit zero with no failed/error/pending examples or oracle
exception. The oracle asserts real stock metadata before reading it.

```sh
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
export TMPDIR=/private/tmp
export CRYSTAL_CACHE_DIR=/private/tmp/crystal-click-w93-tuple-metadata-cache
crystal spec spec/wide_part_reader_tuple_metadata_spec.cr \
  spec/wide_part_reader_tuple_empty_eof_spec.cr \
  spec/wide_part_reader_payload_seam_spec.cr \
  spec/wide_part_reader_w23_spec.cr spec/wide_part_writer_tuple_spec.cr \
  --link-flags='-fuse-ld=ld'
crystal spec spec/wide_part_reader_tuple_metadata_spec.cr \
  spec/wide_part_reader_tuple_empty_eof_spec.cr \
  spec/wide_part_reader_payload_seam_spec.cr \
  spec/wide_part_reader_w23_spec.cr spec/wide_part_writer_tuple_spec.cr \
  --release --link-flags='-fuse-ld=ld'
CRYSTAL_CACHE_DIR=/private/tmp/crystal-click-w88-cache \
  crystal spec --link-flags='-fuse-ld=ld'
CLICKHOUSE_BIN=/Users/sergey/.local/bin/clickhouse \
  bash scripts/check_tuple_oracle.sh
crystal tool format --check src/crystal_click/wide_part.cr \
  spec/wide_part_reader_tuple_metadata_spec.cr
bash -n scripts/check_tuple_oracle.sh
git diff --check
```

### W93 post-change observations and closure

The production diff changes only `validate_tuple_uint64_string_serialization`:
an empty array returns after all root gates; nonempty metadata requires two
unique names and the exact schema name set before running the preserved record
validation by name. Physical stream parsing, child order, marks/ranges,
payload decoding, writer bytes and other type paths are unchanged.

The frozen five-file focused debug gate passed 31 examples with zero failures,
errors or pending examples (146.07 ms execution). Focused release passed the
same 31 examples with zero failures/errors/pending (134.3 ms). Full debug
passed 1,159 examples with zero failures/errors/pending (35.72 s). The linker
emitted the existing duplicate `-lc` warning. These are test execution times,
excluding compilation, not benchmarks. No full release suite was declared or
run for W93; older full release evidence is not transferred. The pinned
Tuple oracle passed all four stock positives: id/.9375 explicit Default,
pk/.9375 name-reordered Default, mixed id/1.0 exact empty records, and all-empty
id/1.0 exact empty records. Each asserted actual stock metadata, full/ranged
values and stock CHECK. The Sparse child profile remained rejected; its copied
part with erased serializer records and refreshed checksums reached precisely
the physical-stream inventory rejection. Existing library-written stock
ATTACH/CHECK/full/key-range byte equality and W92 EOF controls remained green.

The initial hostile review identified a real coverage gap, not a static
production bypass: the retained key-record exact-field guard had no extra-field
test. A key-only `exact_num_defaults: true` mutation now refreshes checksums and
asserts the precise key-field rejection. Its bounded static re-review was
ROBUST; runtime was included in the focused debug/release gates. The final
whole-slice hostile source review returned ROBUST within the pinned profiles.
Review is same-lineage/correlated and includes spec/oracle authorship, not
independent runtime evidence. Root independently inspected the frozen diff and
executed all declared runtime gates. Touched format, shell syntax and diff
whitespace checks passed. The evidence-packet template/validator remain absent;
this source-linked frontier is the curated fallback, not a validated packet.

Scope of closure: only the two Default metadata profiles for the exact
UInt64-key / named UInt64-String Tuple schema, including stock all-empty
Default. Declared Sparse and erased-record stock Sparse remain rejected.
The inventory guard is not authentication of arbitrarily rewritten data;
selected reads still do not validate corruption confined to unselected marks.
Fresh-master optional `exact_num_defaults` and wider versions/layouts remain
unadmitted. Refresh this certificate on the W93 seal's admission, schema,
stream/count/mark policy, fixture, compiler or pinned-binary decay triggers.

### W93 continuation capsule

Active goal remains full type read/write compatibility and MV/projection
frontiers before performance work; matched <=10% slowdown is not proven.
W93 closes exact Tuple Default metadata only, not a new Tuple shape. The next
frontier remains compositional Tuple with named nonempty UInt64/String leaves:
ordered descriptors and owned columnar buffers, separate cohesive owners with
one concrete class/type per file, preserved exact pair APIs. Generic admission
and an explicit physical-stream context are still PROPOSED, not implemented.
Revisit the seam falsifier and freeze that separate API/profile seal before
production: scalar root guards must survive while the same leaf owners serve
arbitrary Tuple prefixes; persisted 1/2/3/9-field stock/writer parts must agree
full/ranged, and invalid writer schemas must never invoke stage creation.

Return pointers: the proposed boundary and next-falsifier sections above,
W91 neutral payload owners, `validate_tuple_uint64_string_serialization`, and
the pinned Tuple oracle. Local implementation/tests/atomic commits remain
authorized; push, binary installation and external data mutation do not.
All W93 heavy processes are terminal; root released the Qwen resource slot
after the final full-debug gate. Check its latest explicit terminal/release
before the next heavy launch, not this historical release as an ongoing lease.
