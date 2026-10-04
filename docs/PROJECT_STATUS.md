# CrystalClick project status

Current capability checkpoint (2026-10-04): W154 adds paired occurrence-specific
Dynamic V3 structure streams and actual-roster/site planning. Equal nominal
Dynamic descriptors can retain different site rosters; empty children and
unused arms retain their own structure prefixes. Ordinary String and implicit
SharedVariant have distinct canonical roles. Root passes 140 focused DEBUG
examples (19 unique files, two serial disjoint groups) and 558 affected RELEASE
examples (79 unique files, eight serial disjoint groups), and 2,539 complete-
inventory examples (398 unique files, 40 serial disjoint non-release groups
with `--no-debug`), all with zero failures/errors/pending. Root independently
reconciles the current inventory paths, source/spec hashes, observed per-group
results and guard exits. These are test gates, not performance measurements.
Seven stock-produced structure streams round-trip byte-exactly, including
two zero-type nested sites. A stock-valid swapped Tuple-site control decodes
but fails the independent literal site/roster check as a semantic mismatch.
One 574-line plan and one 53-line detached-stream owner have separate files;
the large reader/writer/table facades are unchanged. Recursive Dynamic/Variant
metadata no longer suffers blanket refusal, but legacy value/physical/Object
consumers remain closed for it, including empty/zero-window operations.
This is not generic Dynamic bulk values, physical binding, declared Object
Dynamic, complete-part or performance qualification. The source snapshot
and stock executable retain separate identities. Scoped hostile verdict:
ROBUST for metadata/site planning and retained legacy consumer fences only.
Exact boundary, observed
gates and refresh conditions are in
[DYNAMIC_BULK_STRUCTURE_FRONTIER.md](DYNAMIC_BULK_STRUCTURE_FRONTIER.md).
The 2,539-example total is the last complete-inventory capability checkpoint,
before the neutral writer selector extraction below; it is not a fresh full
inventory run of that subsequent refactor.

Previous capability checkpoint (2026-10-04): W153 adds paired generic Dynamic
logical values. Root passes 116 focused DEBUG, 542 affected RELEASE examples
(76 unique files, eight serial disjoint groups), and 2,519 complete-inventory
examples (394 unique files, 40 serial disjoint non-release groups with
`--no-debug`), all with zero failures/errors/pending. Root independently
reconciles the inventory paths, spec hashes and per-group results.
Fourteen owned-value literals
and four independent stock SQL values pass paired nominal-child/value/byte
checks; a stock-valid 42-to-43 mutation fails specifically as a semantic
mismatch. One private 42-line `BinaryDynamicEnvelope` owns framing and shares
the recursive context with the generic dispatcher. Stored/bulk/Object Dynamic
fences remain load-bearing; existing standalone Dynamic profiles are unchanged.
The source audit rejected a proposed ordinary nested Nothing relaxation before
implementation. Scoped hostile verdict: ROBUST for this logical transition
and retained consumer fences, not new physical storage or full compatibility.
No performance work is reopened. Exact boundary and gates are
in [DYNAMIC_VALUE_KERNEL_FRONTIER.md](DYNAMIC_VALUE_KERNEL_FRONTIER.md).

Previous capability checkpoint (2026-10-04): W152 adds paired immutable nominal
`Dynamic(max_types=N)` descriptors for caps 0..254, preserving the cap in
canonical identity and encoding it as `0x2B` plus one byte. Legal recursive
descriptor parents are admitted; at that checkpoint generic Dynamic values,
bulk/physical lanes and declared Object Dynamic remain refused, including empty/NULL/cache-hit
paths. Existing standalone Dynamic support is unchanged. Root passes 123
focused DEBUG examples, 773 affected RELEASE examples (134 unique files in
six serial groups) plus a separate six-example metadata RELEASE regression,
and 2,500 complete-inventory examples (391 unique files in 28 serial disjoint
non-release groups, all with `--no-debug`). Every gate has zero
failures/errors/pending. These are test results, not runtime performance.
A separate literal Ruby/stock oracle qualifies all 255 normal caps and four
finite recursive wrappers from library-generated headers, including actual
input type inference and a valid changed-cap control. Its row body is borrowed
from stock: no Dynamic-value or new part-writer qualification follows. The
local factory-profile refusal of cap 255 is distinguished from upstream's
unchecked raw decoder. Scoped hostile verdict: ROBUST for this descriptor
transition, with the partial/no-op LC-helper limitation explicitly retained.
Exact source/runtime identities, executed gates and next value-kernel frontier
are in [DYNAMIC_DESCRIPTOR_FRONTIER.md](DYNAMIC_DESCRIPTOR_FRONTIER.md).

Previous capability checkpoint (2026-10-04): W151 admits canonical declared
Variant fields in the bounded normalized Object/JSON writer and its public
file/column/table/catalog readers, including legal recursive containers and
eligible LC-bearing arms. A separate 275-line `BinaryBulkPhysicalPrefixAdapter`
owns BASIC physical prefixes and mark rebasing. Root passes 109 focused DEBUG,
756 affected RELEASE examples (131 unique files in six serial groups), and
2,477 complete-inventory examples (387 unique files in 27 successful serial,
disjoint non-release groups). The inventory uses mixed debug-symbol flags;
legacy generic compilation required a 12-GiB guard for some groups. These
are compiler/test results, not runtime memory or performance measurements.
Two stock parts and four independently library-owned parts pass literal
full/middle values, nominal types and actual CHECK; all four library parts
actually ATTACH. Seven declared witnesses cross both String profiles and the
existing Dynamic modes, with typed Variant restricted to BASIC. An independent
Ruby oracle runs 74 fresh queries and rejects a CHECK-valid changed-value part.
Typed COMPACT Variant is a separately tested refusal, not positive admission.
Scoped hostile verdict: ROBUST. Exact gates, source/runtime identities,
zero-window semantics and residual limits are sealed in
[OBJECT_DECLARED_VARIANT_FRONTIER.md](OBJECT_DECLARED_VARIANT_FRONTIER.md).

Current architecture checkpoint (2026-10-04): the writer's scalar/nullable
typed staged-readback selectors belong to one private stateless 289-line
`TypedMarkReadback` class/file. Same-signature private facade wrappers retain
generic type inference and the original module/supplied-reader dispatch.
Root passes 17 baseline and post-extraction characterizations/regressions,
then all 143 affected examples in each of DEBUG and RELEASE (21 unique files,
three serial disjoint groups per mode), with zero failures/errors/pending.
A seeded direct-owner bypass fails specifically on missing facade traces;
root restores the candidate before final gates. Exact moved-body/facade/loader
comparison, source/spec hash reconciliation, private visibility and hygiene
pass. Writer/reader/table are 25,202/15,726/6,786 lines. Scoped hostile verdict:
ROBUST for this neutral ownership move only. No new type/profile admission,
stock oracle, full-inventory rerun or performance certificate is claimed.
The execution scope and refresh conditions are in
[MODULARIZATION_FRONTIER.md](MODULARIZATION_FRONTIER.md).

Previous architecture checkpoint (2026-10-04): the reader's four nested
temporal/Decimal payload reconstruction loops share one private stateless
89-line `NestedFixedWidthPayloadDecoder` class/file. All preflight, selected
I/O, type/range checks and resource policy stay in the facade. Inline callbacks
preserve inherited private decoder dispatch and skip every hidden NULL slot.
Root passes the four expanded public characterizations before and after
extraction, then all 361 affected examples in each of DEBUG and RELEASE
(18 unique files, two serial disjoint groups per mode). A seeded callback-under-
NULL mutation leaves values unchanged but fails the offset witness; root
restores the candidate before final gates. Exact moved-body/prefix/facade/loader
comparison, private visibility and hygiene pass. The reader is 15,726 lines;
writer/table remain 25,466/6,786. Scoped hostile verdict: ROBUST for this neutral
move, not broader admission, complete modularization or performance. No stock
oracle or complete-inventory rerun is claimed. Executed scope and refresh
conditions are in [MODULARIZATION_FRONTIER.md](MODULARIZATION_FRONTIER.md).

Previous architecture checkpoint (2026-10-04): pure JSON typed-path declaration
grammar belongs to one private stateless 52-line `JsonTypedPathDeclaration`
class/file. Public lookup stays in the facade; parsing receives the calling
class as a generic policy. Root caught and corrected two inherited-dispatch
regressions in the first extraction, then passes all 182 affected examples
together in each of DEBUG and RELEASE over 21 unique files. The eight public
characterizations plus four integration scans also pass an exact-original
method baseline replay. Root verifies moved bodies, complete facade/loader
remainder, seeded error/pinned-policy refusals, private visibility and hygiene.
The reader is 15,780 lines. Public grammar, errors, base-class type/layout
admission and I/O remain unchanged. Scoped hostile verdict: ROBUST only for
this corrected ownership move; no stock oracle or full-inventory rerun is
claimed. Large-facade modularization remains open. Replay and the refuted
fixed-base-policy route are in
[MODULARIZATION_FRONTIER.md](MODULARIZATION_FRONTIER.md).

Previous architecture checkpoint (2026-10-04): the reader's twelve metadata
text-grammar helpers move unchanged into one private stateless 170-line
`PartMetadataTextParser` class/file. Root verifies exact bodies/signatures,
the complete facade remainder and loader order; six literal characterizations
pass before and after extraction. All 155 affected reader/table/catalog/Object
examples pass together in each of DEBUG and RELEASE. A corrected seeded
mutation control is refused, external access fails on the private constant,
and formatter/diff checks pass. The reader is now 15,820 lines. Public API,
grammar, errors, type/layout admission and I/O policy are unchanged; the
stricter selected-JSON probe stays separate. Scoped hostile verdict: ROBUST
for this ownership move, not full modularization or performance. No stock
oracle or complete-inventory rerun is claimed for this slice. Its executed
boundary and replay inventory are in
[MODULARIZATION_FRONTIER.md](MODULARIZATION_FRONTIER.md).

Previous architecture checkpoint (2026-10-04): W150 moves the existing 67
writer schema/substream/serialization metadata helpers to one private
518-line `PartSchemaMetadata` class/file. Root verifies exact moved bodies,
the facade remainder and loader order; five literal characterizations pass
before and after extraction, and all 574 affected RELEASE examples pass
across 110 unique files together. Seven fresh library-owned parts pass
actual stock ATTACH/CHECK, nominal types and full/selected literal queries;
an independent Ruby checker repeats 30 fresh stock queries. The public API,
emitted metadata and admitted types/layouts are unchanged. Scoped hostile
verdict: ROBUST for the ownership move. The writer is still 25,466 lines;
large-facade decomposition remains open. The execution seal is in
[MODULARIZATION_FRONTIER.md](MODULARIZATION_FRONTIER.md).

Previous physical checkpoint: W149 binds ordinary recursive normalized
BASIC Variant lanes to Wide physical names and role-owned combined prefixes.
Root passes 64 focused DEBUG, 533 affected RELEASE examples (68 unique files
together) and 2,452 complete-inventory examples (381 unique files in sixteen
serial disjoint non-release groups, not a combined-process run). Six fresh
stock fixtures and six exchanges with library-emitted lanes pass complete
roster/grid checks, actual ATTACH/CHECK and literal full/middle RowBinary;
a separate Ruby oracle repeats 54 fresh queries, including a valid wrong-value
control. These exchanges borrow stock envelopes: at that checkpoint declared
Object Variant/Dynamic and new public whole-part profiles remained closed.
W151 separately supersedes the bounded typed-Variant refusal. Scoped hostile
verdict: ROBUST. See
[VARIANT_PHYSICAL_BINDING_FRONTIER.md](VARIANT_PHYSICAL_BINDING_FRONTIER.md).

Previous bulk checkpoint: W148 implements paired normalized BASIC
Variant bulk lanes through ordinary recursive containers and eligible LC
sites. Final focused DEBUG passes 50 examples; affected RELEASE passes 517
examples across 66 unique files together. Two fresh stock Wide lane/grid
fixtures and both library-emitted Native payloads pass independent literal
checks, including a valid wrong-value control. Final complete-inventory
passes 2,434 examples across 378 unique files in sixteen serial disjoint
non-release groups, not a combined-process run. Formatter, Ruby syntax and
diff checks pass; the scoped hostile verdict is ROBUST. Physical binding,
declared Object Variant/Dynamic and new public part profiles remain closed.
See [VARIANT_RECURSIVE_BULK_FRONTIER.md](VARIANT_RECURSIVE_BULK_FRONTIER.md).

Separate architecture checkpoint: the existing public writer JSON typed-path
descriptor and alias have moved unchanged to their own 17-line owner. Root
passes two standalone constructor/import examples and 67 adjacent examples
in each of DEBUG and RELEASE, with exact moved-body/facade/loader checks.
No type, physical profile or writer behavior changes; the large facade refactor
remains open. See [MODULARIZATION_FRONTIER.md](MODULARIZATION_FRONTIER.md).

Previous logical checkpoint: W147 adds paired generic Variant
descriptors and owned RowBinary values, with canonical arm identity, NULL and
legal recursive compositions. Root passes 62 focused DEBUG, 503 affected
RELEASE examples (64 unique files together) and 2,420 complete-inventory
examples (376 unique files, sixteen serial disjoint non-release groups, not
a combined-process run). The independent literal stock/library exchange
passes seven rows in each direction plus a valid 42-to-43 wrong-value control.
This is a logical codec prerequisite: generic Variant bulk/physical lanes,
declared Object Variant/Dynamic and new public part profiles remain closed.
The scoped certificate is in
[VARIANT_VALUE_KERNEL_FRONTIER.md](VARIANT_VALUE_KERNEL_FRONTIER.md).

Previous whole-part checkpoint: W146 admits canonical declared
LowCardinality fields in normalized Object/JSON, including legal recursive
compositions and LC(Nullable(T)). The existing independent complete-part
writer and file/column/table/catalog consumers share role-owned dictionary
prefixes and complete-grid replay. Root passes 112 focused DEBUG, 406 affected
RELEASE examples (52 unique files together) and 2,405 complete-inventory
examples (374 unique files, sixteen serial disjoint non-release groups, not
a combined-process run). Eight native/library cells pass actual CHECK,
four independent library-part ATTACH operations, exact nominal types and
full/middle ordered literal RowBinary under both ordinary String profiles
and BASIC/COMPACT Dynamic modes. A separate Ruby checker rechecks all eight
cells and a valid wrong-value store with 74 fresh stock queries. These are
whole library-owned parts, not borrowed stock envelopes. The physical matrix
qualifies seven declared witnesses, not every eligible leaf/product/profile.
Dynamic/shared LC and Object BFloat16 remain refused. Scope and execution
lineage are in
[OBJECT_DECLARED_LOW_CARDINALITY_FRONTIER.md](OBJECT_DECLARED_LOW_CARDINALITY_FRONTIER.md).

The overall objective is still open: paired type/layout coverage and
MV/projection interoperability first, memory/performance afterward. Shared
codec/planner owners have separate files, but the large legacy facades have
not yet been fully decomposed. No stock-reader speed-parity claim is made.

## Earlier checkpoint lineage

W145 binds ordinary recursive LowCardinality bulk roles to physical
dictionary/index filenames, including W144's raw Float transport. Root passes
99 focused DEBUG, 324 affected RELEASE and 2,395 full-inventory examples
(372 unique spec files, 16 disjoint non-release groups). Eight stock Wide parts
and eight exchanges with library-emitted lanes pass roster/grid/value checks
and actual stock ATTACH/CHECK/RowBinary; a separate literal Ruby oracle
rechecks all sixteen tables and the wrong-value control with 51 fresh queries.
Those exchanges borrow stock envelopes. They do not qualify an independent
whole-part writer or public Object facade admission; W146 separately does so
within its declared-field profile. See
[LOW_CARDINALITY_PHYSICAL_BINDING_FRONTIER.md](LOW_CARDINALITY_PHYSICAL_BINDING_FRONTIER.md).

Source checkpoint: shared writer extraction `571dc3c`, sparse-consumer Tuple
correction `9d87293`, W128 normalized whole-part checkpoint `1c5bab4`, and
the W129 bounded Object catalog integration, W130 mixed table delivery
`4b18812`, W131 declared Int64 `02dd99f`, W132 paired numeric declared
fields `e043be7`, W133 paired declared Date/Date32 `2e150f4`, W135
paired bare declared UUID/IPv4/IPv6 `ffa5730`, W136 paired bare
declared FixedString(N) `700d5b8`, W137 canonical bare declared
Decimal(P, S) `73914c8`, W138 canonical bare declared Enum8/Enum16 `0c63c32`,
W139 paired declared DateTime/DateTime64/Time/Time64 `281b0d6` in
[JSON_GENERAL_STORAGE_FRONTIER.md](JSON_GENERAL_STORAGE_FRONTIER.md).
W140 adds recursive Object declared fields over W139; its scoped certificate
is in [OBJECT_RECURSIVE_DECLARATIONS_FRONTIER.md](OBJECT_RECURSIVE_DECLARATIONS_FRONTIER.md).
W134 extracts nine existing Array/Map row/slice owners to separate files,
preserving their exact bodies and API. Root passed 22 focused DEBUG, 37 adjacent
RELEASE and 2,242 complete-inventory examples (353 unique specs, 15 disjoint
non-release groups), plus a fresh unchanged W133 stock regression. This is
bounded behavior-preserving extraction, not full facade modularization.
The executed certificate and responsibility-level owner boundaries are in
[MODULARIZATION_FRONTIER.md](MODULARIZATION_FRONTIER.md).
W136 root gates pass 52 focused DEBUG, 177 adjacent RELEASE and 2,260
complete-inventory examples (357 unique specs in 15 disjoint non-release
groups), plus the eight-cell FixedString stock oracle and fresh unchanged
UUID/IP, Date and numeric regressions. Its scoped hostile verdict is ROBUST
in the JSON frontier; the full-inventory result is not a combined-process run.
W137 root gates pass 61 focused DEBUG, 186 adjacent RELEASE and 2,269
complete-inventory examples (359 unique specs in 15 disjoint non-release
groups). Its fresh eight-cell Decimal stock matrix passes exact nominal
types, scale-preserving text, independent RowBinary, actual CHECK for all
cells and ATTACH for the four library-owned parts. The JSON frontier retains
the complete gate record and residual scope; schema coverage of all 3,002
legal precision/scale pairs is not exhaustive physical part qualification.
W138 root gates pass 72 focused DEBUG, 197 adjacent RELEASE and 2,280
complete-inventory examples (361 unique specs in 16 disjoint non-release
groups). Eight fresh native/library Enum cells pass nominal maps, labels,
literal signed RowBinary, actual CHECK and four library ATTACH operations;
an independent Ruby checker rechecks all eight stores without Crystal codecs.
Five fresh unchanged neighboring stock oracles pass. Full-width map admission
(256/65,536 entries) is schema evidence, not exhaustive physical-map coverage.
W139 root gates pass 83 focused DEBUG, 470 adjacent RELEASE and 2,291
complete-inventory examples (363 unique specs in 16 disjoint non-release
groups). Eight fresh native/library cells cover 37 temporal declarations,
every scale 0..9 and sampled implicit/explicit/alias/fixed zones; all actual
CHECK and four library ATTACH operations pass. An independent arithmetic/Ruby
checker rechecks all eight stores, and six unchanged neighboring stock oracles
pass. This is a bounded temporal Object certificate, not all-zone/recursive
or current-master executable qualification.
W140 root gates pass 109 focused DEBUG, 496 adjacent RELEASE and 2,317
complete-inventory examples (367 unique specs, 16 disjoint non-release groups).
Eight fresh cells qualify 13 Array/Map(String,V)/Tuple/Nullable field witnesses,
with all actual CHECK results and four library ATTACH operations. A manual
Ruby checker independently rechecks all eight live stores and 4,496 RowBinary
bytes; seven unchanged neighboring stock oracles pass. Schema admission over
W139 leaves is broader than this finite physical sample. Separate grammar,
descriptor, Tuple-name and catalog-accounting owners leave legacy facades
unchanged; this is not all types, all layouts or completed modularization.
W141 adds the paired nominal LowCardinality descriptor/owned row-value kernel,
including recursive containers and LC(Nullable(T)) over represented eligible
leaves. It preserves the narrower persisted Object/bulk boundaries rather
than treating RowBinary compatibility as dictionary/index part support.
Root passes 98 focused DEBUG, 206 affected RELEASE and 2,332 complete-inventory
examples (368 unique specs, 16 disjoint non-release groups), plus nine
bidirectional nominal row witnesses and descriptor/name negative controls.
The current transition and independent source/runtime evidence are in
[OBJECT_LOW_CARDINALITY_FRONTIER.md](OBJECT_LOW_CARDINALITY_FRONTIER.md).
W142 adds the standalone shared physical LC dictionary/index prerequisite in
[LOW_CARDINALITY_BULK_STORAGE_FRONTIER.md](LOW_CARDINALITY_BULK_STORAGE_FRONTIER.md).
Root passes 72 focused DEBUG, 241 affected RELEASE and 2,361 complete-inventory
examples (369 unique specs in 16 disjoint non-release groups), plus nine exact
native lane/grid witnesses, nine stock Native consumers and four cause-specific
corruption/comparator controls. Stock consumption converts global framing to
Native additional-only framing; this is not a new library-part ATTACH/CHECK.
It does not widen recursive bulk, Object, Dynamic or complete-part admission.
W143 integrates that shared owner into ordinary recursive `BinaryBulkCodec`
for root LC and legal Array/Tuple/Map/Nullable compositions over eligible
non-floating represented leaves. Root passes 80 focused DEBUG, 255 affected
RELEASE and 2,375 complete-inventory examples (370 unique specs, 16 disjoint
non-release groups), three complete native container lane/grid witnesses and
seven stock Native consumers including a valid wrong-output control. A separate
Ruby comparator checks all 63 stock rows against literal types/RowBinary.
The executed certificate is in
[LOW_CARDINALITY_RECURSIVE_BULK_FRONTIER.md](LOW_CARDINALITY_RECURSIVE_BULK_FRONTIER.md).
In W143, Float LC composition and persisted Object/Dynamic/physical-part
binding remained explicitly closed. W144 supersedes only that Float bulk
guard. W145 subsequently admits generic physical role/name binding, while
keeping Object/Dynamic and existing whole-part facade boundaries closed at
that checkpoint. W146 supersedes only the bounded typed-Object LC refusal.
Neither shared bulk nor filename binding qualifies a new standalone writer.
Reviewed on 2026-10-04. This is a navigation summary, not a new compatibility
certificate; the linked frontier documents retain their tested profiles,
source/runtime identities and executed evidence.

## What is usable now

- `BinaryDataType.dynamic` and `BinaryValue.dynamic` provide nominal-cap
  identity and paired generic logical Dynamic values. W153 preserves selected
  type/value identity, recursive containers and typed NULL distinctions;
  borrowed persisted consumers and unqualified bulk/physical/Object lanes
  remain fenced. A logical envelope is not a ColumnDynamic slot/roster plan
  or a new complete-part writer.
- `BinaryDynamicBulkPlan` pairs actual Dynamic rosters with immutable
  occurrence paths, including declared containers, static Variant arms and
  nested Dynamic inside actual arms. `BinaryDynamicStructureStreams` provides
  detached complete structure blobs. Paired structure decode/encode and
  logical role rosters are available under shared operation budgets, not
  generic bulk values or physical part binding. See
  [the W154 frontier](DYNAMIC_BULK_STRUCTURE_FRONTIER.md).
- `BinaryDataType.variant`, `BinaryValue.variant` and `variant_null` provide
  the shared canonical logical Variant kernel. Paired descriptor/value codecs
  retain nominal arm identity, recursive values and explicit NULL. W148 adds
  normalized BASIC discriminator/sparse-arm bulk lanes, ordinary containers
  and eligible LC replay. W149 adds shared ordinary recursive physical names
  and combined prefixes, not a new public whole-part facade; see W147-W149
  certificates. W151 separately admits declared Variant in the existing
  bounded complete-Object writer and public consumers, not an arbitrary-schema
  standalone Variant part writer.
- `WidePart` and `WidePartTable`: selected-column and typed reads, including
  windowed delivery. The public contracts admit explicit physical profiles,
  not arbitrary ClickHouse parts or recursive type combinations.
- Paired part readers/writers cover broad primitive, String/FixedString,
  Nullable, Enum, Decimal, identifier, temporal, container and geometry
  families, including QBit and several LowCardinality/Variant/Dynamic profiles.
  Exact supported declarations, wrappers and layouts are in
  [EMBEDDED_MERGETREE_FRONTIER.md](EMBEDDED_MERGETREE_FRONTIER.md) and its
  linked family frontiers. A supported scalar does not imply every container
  or serialization profile containing it.
- `WidePartWriter.write_uint64_object_pair`: a complete standalone normalized
  JSON/Object part from library-owned keys, explicit schema/rosters and
  documents, without borrowed stock sidecars. W128 qualifies hashed Wide,
  Object V3/Dynamic V3, one-bucket shared MAP, LZ4 and plain adaptive marks;
  W128 declared typed fields are UInt64/String. Five fresh parts passed actual
  stock ATTACH/CHECK=1/full/PK SQL and explicit file-reader full/middle/zero windows.
  W129 adds bounded catalog Object materialization; W130 adds the separately
  qualified mixed typed-table reader. Neither widens the writer to multiple
  Object columns or arbitrary schemas. W132 admits declared UInt8/16/32/64/128/256,
  Int8/16/32/64/128/256, Float32/64, Bool and String through those same owners.
  Four fresh native and four library-owned parts pass actual CHECK/full/PK SQL,
  independent numeric RowBinary and file/column/catalog/table consumer checks,
  including float signed zero, infinity and NaN payloads. Bool is nominally
  distinct from UInt8; logical writes canonicalize true to byte 1. BFloat16 is
  excluded by the measured stock Object schema gate. String 0/1 × BASIC/COMPACT
  is qualified in both directions; this is still normalized Object V3/MAP,
  not arbitrary JSON. W133 adds bare declared Date/Date32 through the same
  writer and public consumers: eight fresh native/library matrix cells pass
  calendar/day-code/type/byte checks, actual CHECK and exact RowBinary; two
  separate raw Date32 extrema cases qualify transport only, not calendar range.
  W135 adds bare declared UUID/IPv4/IPv6 through the same fixed-value and
  bulk owners. Eight fresh native/library cells pass actual CHECK (and
  ATTACH for library-owned parts), canonical text, nominal SQL types,
  independent literal RowBinary and public file/column/catalog/table consumers.
  Twelve seeded comparator
  controls reject byte/order, same-width nominal, serializer, grid and CHECK
  mismatches. UUID remains distinct from UInt128/IPv6, and IPv4 from UInt32.
  W136 adds canonical bare declared FixedString(N), retaining N as nominal
  identity and using existing exact-width payload/bulk owners. The schema
  admits N=1..16777215; stock part qualification covers N=1/3/16/17/31/257
  across eight fresh native/library cells, with exact bytes, padding, UTF-8
  byte lengths, actual CHECK and public consumer/PK checks. N>256 requires
  the server's suspicious-type opt-in; maximum-N evidence is schema-only.
  Library raw inputs require exactly N bytes, without implicit text padding.
  W137 adds canonical bare Decimal(P, S), P=1..76 and S=0..P, through the same
  fixed-value/bulk, writer and public consumers. All 3,002 legal schema pairs
  pass constructor/parser checks; independent stock qualification samples
  nine P/S witnesses across all four storage widths in eight fresh cells.
  Raw signed coefficients, precision, scale and width stay exact; this is
  storage interoperability, not Decimal arithmetic/conversion/rounding.
  W138 adds canonical bare Enum8/Enum16 with exact width and complete
  label/code-map identity, all eight canonical escapes and opaque label bytes.
  Existing fixed-value/bulk owners provide paired writer/reader transport;
  stock part evidence covers seven-entry maps with signed extrema across the
  same eight cells. Same-width integer aliases and changed maps are not equal.
  Full 256/65,536-entry maps remain eligible with sufficient logical budgets.
  The shared declared-field policy now admits 21 static nominal types plus
  the FixedString, Decimal and Enum families. W139 adds canonical DateTime/
  DateTime64/Time/Time64 through one declaration owner and the same paired
  transport/consumer paths. Scale and exact implicit/explicit/alias/fixed zone
  identity are retained; eight cells qualify every scale and sampled zones.
  Default-scale aliases remain refused. W140 adds canonical recursive Array,
  Map(String,V), named/unnamed Tuple (including Tuple()) and legal Nullable
  fields over the W139 leaves through the same paired writer/reader/consumer
  paths. Nested Maps require exact String keys; Nullable cannot immediately
  wrap Array, Map or Nullable. Thirteen recursive witnesses are physically
  qualified across the eight cells; every recursive leaf/product is not.
  W146 adds declared LC over the eligible represented Object leaf intersection,
  including LC(Nullable(T)) within those compositions. Seven field witnesses
  are physically qualified across eight native/library cells. Selected reads
  replay all Object physical lanes if any typed field contains LC; only the
  requested documents are materialized. Catalog `.values` may repeat replay
  per mark. This is correctness admission, not selective I/O or a performance
  certificate. Dynamic/shared LC remains outside the Object profile. See
  [the declared LC frontier](OBJECT_DECLARED_LOW_CARDINALITY_FRONTIER.md).
  W151 adds canonical declared Variant through the same complete-part and
  public consumer owners. Seven recursive witnesses have independent stock
  and library-owned part evidence, including NULL, unused arms and LC keys
  reused across marks. Plain non-LC Variant preserves selected body reads;
  LC anywhere in a typed tree requires complete replay. Every physical grid
  is checked, including zero windows; untouched body frames are not all
  authenticated by a selected read. Typed Dynamic, COMPACT Variant and general
  Object layouts remain refused. See
  [the declared Variant frontier](OBJECT_DECLARED_VARIANT_FRONTIER.md).
  The inherited timezone manifest still lacks runtime-added America/Coyhaique.
  See
  [the example](../examples/write_object_document_part.cr) and
  [the qualified frontier](JSON_GENERAL_STORAGE_FRONTIER.md).
- `OfflineCatalog`: disk-based Atomic metadata discovery, database/table/
  column objects and part candidates. `catalog[db][table][column].values`
  explicitly materializes a bounded owned column; it is not a lazy result.
  Normalized whole-JSON columns now return owned `ObjectDocument` values
  within the W129 declaration/layout profile, with aggregate cross-part
  logical, row, String and recursive-cell limits. That accounting is not an
  RSS or pre-decode transient-memory ceiling. See
  [read_object_catalog.cr](../examples/read_object_catalog.cr).
  W130 separately admits selected normalized Object roots, alone or mixed
  with existing typed columns, through full batches, physical windows and
  bounded UInt64-PK candidate delivery. More than one selected Object root
  is kept separately bound. `batch.object_documents_for(column)` exposes
  callback-scoped slices of immutable retainable document handles. See
  [read_object_table.cr](../examples/read_object_table.cr).
  Synthetic `catalog["system"]["part_candidates"]["rows"].values` is supported;
  these are candidates, not server-proven Active parts or the real `system.*`
  tables. See [OFFLINE_CATALOG_FRONTIER.md](OFFLINE_CATALOG_FRONTIER.md) and
  [OFFLINE_PART_CANDIDATE_VALUES_FRONTIER.md](OFFLINE_PART_CANDIDATE_VALUES_FRONTIER.md).
- Primary-index granule pruning is available for the bounded UInt64 key
  profile. Candidate scans deliver complete selected granules; application
  code must apply the exact residual predicate. See
  [PRIMARY_KEY_GRANULE_PRUNING_FRONTIER.md](PRIMARY_KEY_GRANULE_PRUNING_FRONTIER.md).
- `EmbeddedMergeTreeTable`: a Crystal-owned experimental table with one
  UInt64 key, one String value and the `all` partition; insert, reopen, merge,
  candidate scans and explicit reclamation. Its process-atomic commit-marker
  protocol is not a ClickHouse server data-root lifecycle or power-loss
  durability guarantee. See [examples/README.md](../examples/README.md).

## Important remaining boundaries

1. **General JSON compatibility.** W117-W151 provide
   reusable type/value, bulk, structure, binding, transport, normalized Object
   reader, column writer and complete normalized whole-part owners. W128
   generates every pre-ATTACH file from owned inputs and has fresh stock
   qualification; W127's older shell-based oracle is not the whole-part
   certificate. The catalog now dispatches whole normalized JSON through
   `ObjectColumnReader`, and W130 integrates that bounded profile into public
   mixed `WidePartTable` batches/windows and UInt64 PK candidates. W132 admits
   the numeric primitive family, Bool and String declared fields with paired
   stock evidence; W133 adds bare Date/Date32 with independent calendar and
   signed raw-carrier checks; W135 adds bare UUID/IPv4/IPv6 with independent
   text, nominal and byte-order evidence; W136 adds canonical bare
   FixedString(N) with bounded parameter grammar and independent fixed-byte
   evidence; W137 adds canonical bare Decimal(P, S) with exact persisted P/S
   identity and independent signed coefficients; W138 adds canonical bare
   Enum8/Enum16 with nominal full-map and independent label/signed-byte checks.
   W139 adds canonical DateTime/DateTime64/Time/Time64 with exact scale/zone
   identity and independent ticks/text checks. W140 adds recursively bounded
   Array/Map/Tuple/Nullable declared fields and catalog descriptor-tree charging.
   W146 adds bounded canonical declared LC with shared physical state replay
   and an independent whole-part certificate. W151 adds bounded canonical
   declared Variant with a paired prefix owner and independently owned whole
   parts. Typed Dynamic, unqualified Variant/LC leaves/products, Map LC keys, and
   the inherited timezone-profile gap remain open within Object,
   even where standalone part support exists. The older scalar typed-path behavior is
   unchanged. Neither adapter implies arbitrary
   JSON schemas or physical layouts; Default serialization metadata is still
   required, and whole-Object projection child reads remain refused. See
   [JSON_GENERAL_STORAGE_FRONTIER.md](JSON_GENERAL_STORAGE_FRONTIER.md).
   W140's finite physical profile and executed gates are in
   [OBJECT_RECURSIVE_DECLARATIONS_FRONTIER.md](OBJECT_RECURSIVE_DECLARATIONS_FRONTIER.md).
2. **Additional physical profiles and recursive composition.** Normalized
   Wide/SUFFIX Object V3 with explicit rosters and one-bucket MAP is not general
   JSON/Dynamic compatibility. Bucketed/advanced layouts, other structure
   versions, Compact parts and unqualified wrapper/container combinations need
   their own paired evidence. Existing logical binary codecs alone do not
   widen public part admission. W147 qualifies the generic Variant logical
   kernel; W148 implements normalized BASIC discriminator/sparse-arm bulk,
   and W149 qualifies generic Wide physical binding with combined prefixes
   and finite stock witnesses, not a standalone general writer. Specialized
   prefix streams and COMPACT Variant remain unqualified by that binder.
   W151 qualifies the separate declared-Object BASIC Variant profile, not
   every physical product admitted by its schema grammar.
   W152/W153 qualify nominal Dynamic descriptors and generic logical values;
   W154 adds actual per-occurrence structure/roster planning, not generic
   Dynamic bulk values, complete mark grids or new physical binding. Equal
   nominal Dynamic types do not imply equal per-part or per-site state.
   Shared Nested offsets,
   AggregateFunction state serialization and SimpleAggregateFunction alias
   canonicalization remain unqualified; aggregate states and aliases are not
   interchangeable capabilities. The general binary descriptor kernel still
   lacks Interval descriptors; source eligibility for LC(Interval) is not
   equivalent to represented values or qualified physical parts.
3. **MV/projection coverage.** Offline declaration metadata and explicit reads
   of fully covered physical Wide projection child parts are available. The
   persisted MV materializer is one explicit-TO identity projection over
   unpartitioned `k UInt64, v String`. General MV execution, projection
   planning/writing and arbitrary MV transformations are not implemented.
4. **General table writing.** The detached-part writers and small
   `EmbeddedMergeTreeTable` are not an arbitrary-schema, arbitrary-partition
   MergeTree writer with compound keys and a server lifecycle.
5. **Responsibility-level architecture.** The reader/writer/table facades remain
   large. Individual new owners have separate files, but the overall refactor
   is unfinished. File count alone does not prove lower coupling.

## Next implementation order

1. Continue behavior-preserving decomposition. Shared VarUInt/checksums,
   primary index and staging/publication have separate owners; the new Object
   schema, metadata, whole-part orchestrator and catalog materialization
   owners also have separate files.
   W134 moved the nine existing inline Array/Map payload/row classes from
   `wide_part_table.cr` into nine separate files, preserving public names,
   generic signatures, retained ownership and limits. The remaining facade
   is 6,786 lines; the reader/writer are now 15,726/25,202 lines.
   Pure metadata text and JSON typed-path grammar have separate private owners.
   Nested fixed-width temporal/Decimal payload reconstruction now has one
   private owner, with unchanged preflight and inherited private dispatch.
   JSON parsing preserves caller-policy and public-parser overrides; the next
   larger seams are staged validation and physical stream binding, followed
   by reader granule orchestration and table adapters. Each is a separately
   characterized ownership move, not a class per type combination.
   The first writer seam is now executed: the two private generic selectors
   `read_typed_numeric_mark` and `read_typed_nullable_numeric_mark` delegate to
   one private `TypedMarkReadback` owner, while staged-validation orchestration
   remains in the facade. `Slice(T)`/`forall T`, module reopen overrides and
   supplied-reader virtual dispatch remain pinned. Numeric/nullable and
   temporal readbacks supply positive witnesses; a direct-owner bypass fails
   the selector trace. Metadata tampering remains a separate validator guard,
   not proof that the selector itself ran. Larger validator/I/O seams remain.
   W148 separates the full-mark LC occurrence scheduler from its thin replay
   dispatcher. The existing public `WidePartWriter::JSONTypedPathColumn`
   and associated value alias now have their own owner with exact constructor
   semantics. W150 separately extracts the existing writer metadata renderer
   with exact-move, literal and stock regression evidence. W151 adds one
   role-owned physical-prefix adapter class/file instead of embedding its
   coordinate law in the large facades. The reader metadata text grammar
   now has a separate private owner, without merging the selected-JSON policy.
   Next remain
   shared schema/substream planning, physical I/O/validation, leaf codecs and
   thin table/catalog adapters. Keep one
   cohesive class per file rather than one new class per type combination.
2. Extend paired Object declared fields beyond numeric primitives/Bool/String,
   bare Date/Date32, UUID/IPv4/IPv6, FixedString(N), Decimal(P, S), Enum8/Enum16
   and canonical DateTime/DateTime64/Time/Time64. W140 now admits canonical
   recursive Array/Map(String,V)/Tuple/legal Nullable schemas, with separately
   bounded physical witnesses. W151 adds bounded declared Variant; the next
   proposed lane is typed Dynamic, alongside the timezone profile gap and
   separately qualified physical products. W141 establishes the logical
   LowCardinality prerequisite;
   W142 adds the separately qualified standalone dictionary/index codec.
   W143 qualifies recursive non-floating bulk role binding, flattened
   occurrence schedules and dictionary state integration. W144 qualifies
   raw Float LC transport and measures the distinct INSERT normalization
   boundary. W145 now qualifies shared physical LC role binding under explicit
   default-LC/BASIC-Map profiles. W146 admits declared Object LC with independent
   complete parts and selected public consumers within its finite certificate.
   W147 adds the paired logical Variant prerequisite without widening these
   persisted consumers. W148 implements generic BASIC bulk discriminator/
   sparse-arm scheduling, LC occurrence counts and empty-arm mark replay;
   its separate stock count/lane falsifier is executed within the W148 scope.
   W149 qualifies ordinary recursive physical binding, both String profiles
   and LC-bearing sparse arms using borrowed stock envelopes. W151 separately
   qualifies declared Object Variant with independent complete parts and
   shared public consumers. Typed Dynamic remains the next distinct storage
   frontier. W152 preserves the nominal `Dynamic(max_types=N)` cap; W153 adds
   the paired generic logical actual-type/value grammar. W154 adds paired
   actual per-occurrence structure streams and normalized role/site planning.
   The next transition is generic Dynamic bulk values and complete mark-grid
   scheduling over that actual state, then separately qualified physical
   binding before declared Object Dynamic and complete-part tests.
   Neither the cap nor Object's inferred-path policy substitutes for that roster.
   Broader layout/type products remain separate.
   Reuse existing leaf owners only
   after bounded declaration parsing, semantic parameter identity and
   independent physical qualification.
   Require independent native and library parts, asymmetric bytes/RowBinary
   and actual stock CHECK.
   Address parameterized/recursive field grammar and semantic identity, then
   widen layouts with their own stock-generated and library-owned evidence.
   Object declarations retain the stock maximum of 1,000 typed paths.
3. Expand remaining paired type/profile and MV/projection frontiers.
   For MV/projections, prioritize declaration/dependency/TO-target inspection
   and compatible projection storage, not adding a SQL functions/joins engine.
4. Only then reopen memory/performance work. No current claim of stock-reader
   speed parity or a quantified percentage of complete ClickHouse support.

## Source reference

The newest separate shallow checkout is
`/Users/sergey/SrcArchives/clickhouse-2026-10-04-depth1-b94acbe3`, revision
`b94acbe318f8459ac88b35647f4e2293d8e225db`.
[CLICKHOUSE_SOURCE_REFERENCE.md](CLICKHOUSE_SOURCE_REFERENCE.md) records the
comparison and earlier identities. Against the previous `7f568d60` snapshot,
DataTypes, Columns, Formats, MergeTree and Compression are exactly identical
in five separate recursive content comparisons. Unchanged serializers
do not imply unchanged framing, metadata or lifecycle behavior. This is
source evidence only: no executable from this checkout has been built or
qualified. Source identity and the separately pinned executable oracle must
not be conflated. Type families persisting across releases also does not
imply immutable binary descriptors or physical layouts.

This summary becomes stale when source admission, facade dispatch, the tested
runtime/profile or the architecture boundary changes. Refresh it from the
linked owners/frontiers and rerun the affected gates; do not promote a guard or
logical codec into full part support based on this summary alone.
