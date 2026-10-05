# CrystalClick project status

Latest capability checkpoint (W168, 2026-10-05): canonical unary, non-parametric
SimpleAggregateFunction(any/anyLast/min/max, String/FixedString(N)) is paired
through descriptor/value/bulk codecs, public scalar/outer-Nullable Wide-part
writer/reader, table batches/windows and offline column `.values`. Exact
function, child width and outer shape remain nominal; ordinary text accessors
and inferred writer admission do not widen. Library FixedString width is
1..65536; finite stock whole-part qualification covers String and widths
1, 3, 130 across all four functions and both shapes, not every width/layout.
Root passes 290 DEBUG and 290 affected RELEASE examples in four disjoint
groups per mode (33 unique specs), plus two actual native-fixture examples.
All counted gates have zero failures/errors/pending and actual child/guard
exit 0. Stock accepts 32 independently library-authored complete parts through
ATTACH/CHECK; root recomputes 216 literal checks and three CHECK-valid negative
controls without importing the worker oracle. Four additional complete String
parts establish all-empty/all-NULL EOF zero and nonzero trailing-empty marks
against stock, with 24 independent profile literal checks. All 341 final
source/spec/support/page/script inputs reconcile with current files.
An intentionally bypassed staged-value comparison fails; exact restoration
passes. Scoped hostile verdict: ROBUST within this stored-value profile.
Staged certification checks visible semantics, marks/metadata and raw lengths,
not content hashes or canonical bytes beneath NULL. Numeric SAF admission is
unchanged; Decimal/temporal SAF, other functions and broader products remain.
The new text storage-plan and staged-validator owners each have their own file;
reader/writer/table facades are still 16,017/25,377/7,015 lines. Architecture
cleanup, remaining paired types and general MV/projections remain open.
Memory/performance stays deferred. Source `e9b645ed` is a clean unbuilt shallow
checkout, separate from executed stock build `d9bcb5ab`. Scope, exact commands,
evidence and decay:
[SIMPLE_AGGREGATE_TEXT_FRONTIER.md](SIMPLE_AGGREGATE_TEXT_FRONTIER.md).

Latest behavior-preserving architecture checkpoint (W167, 2026-10-05): scalar and outer-Nullable
FixedString staged validation now belongs to one private, stateless 127-line
`StagedFixedStringPartValidator` class in its own file. Both private facade
signatures, public call sites, direct virtual WidePart readbacks, exact width,
NULL-map, zero-padding and index checks retain their existing order.
The complete retained writer remainder is byte-identical to `061db28` after
excluding the two sealed definitions; moved bodies are exact after only
the declared synchronous callback substitutions. I/O, staging, metadata,
checksums and publication/cleanup remain with their existing owners.
Root passes 147 DEBUG and 147 affected RELEASE examples (15 unique specs per
mode, two disjoint groups), all with zero failures/errors/pending and actual
child/guard exit 0. Logs, rosters and all 317 current source/spec/support/page
inputs independently reconcile. A temporary comparison-loop bypass produces
two intended trace failures; exact restoration passes. Scoped hostile verdict:
ROBUST within this ownership move. Format/diff checks pass; no new type/API,
native-format, crash recovery or performance claim is admitted.
Reader/writer/table facades remain 15,845/25,241/6,911 lines. The larger
architecture refactor, remaining type/layout products and general MV/projection
support remain open; memory/performance stays deferred. Exact scope, commands,
consumer inventory and refresh conditions:
[MODULARIZATION_FRONTIER.md](MODULARIZATION_FRONTIER.md).

Previous architecture checkpoint (W165, 2026-10-05): scalar and Nullable(String)
staged validation now belongs to one private, stateless 100-line
`StagedTypedStringPartValidator` class in its own file. Same-signature facade
entry points, direct virtual WidePart readbacks, exact nominal guards, mark
comparisons and primary-index checks retain their existing order. The complete
writer remainder is byte-identical to `74c53b1` after excluding the two sealed
method definitions; moved bodies are exact after the three declared callback
substitutions. Staging, I/O ownership, metadata/checksums and publication/cleanup
remain with their existing owners. No new type/API/layout is admitted.
Root passes 44 DEBUG and 189 affected RELEASE examples (16 unique RELEASE
specs, three disjoint groups), all with zero failures/errors/pending and
actual child/guard exit 0. Independent reconciliation matches all 316 current
source/spec/support inputs. Temporary readback and comparison bypasses each
produce two intended trace failures; exact restoration passes. One initially
invalid type-guard fixture was corrected to use valid opposite profiles;
its failed candidate is not counted as positive or seeded-control evidence.
Scoped hostile verdict: ROBUST for this exact behavior-preserving ownership
move and its affected writer/table/MV/projection/catalog consumers. No new
stock or benchmark run was performed. At W165 the reader/writer/table facades
remain 15,845/25,313/6,911 lines; the overall architecture cleanup remains open.
Remaining paired types and general MV/projection support are unchanged;
memory/performance stays deferred. Scope, commands, inventory and decay:
[MODULARIZATION_FRONTIER.md](MODULARIZATION_FRONTIER.md).

Previous capability checkpoint (W164, 2026-10-05): the five remaining raw numeric
SimpleAggregateFunction carriers are paired in the finite canonical-function
matrix: UInt128, Int128, UInt256, Int256 and BFloat16. This adds 41 scalar pairs /
82 with outer Nullable; the combined admitted matrix is 118 scalar pairs /
236 scalar-and-Nullable profiles. Exact function, child carrier and outer shape
survive the descriptor, value/bulk/physical, public Wide writer/reader,
table-window/batch and offline column-value paths. BFloat16 sum and bitwise
functions remain refused. Ordinary primitive accessors and inferred typed-writer
admission do not silently widen; exact SAF preflight is separate from inference.
Root passes 60 focused DEBUG and 873 affected RELEASE examples (82 unique specs,
eleven disjoint groups), plus two actual native-fixture examples. All final
counted gates have zero failures/errors/pending and actual child/guard exit 0.
Pinned stock ATTACH/CHECK accepts all 82 newly library-authored complete parts.
Root independently recomputes 246 library and three native literal RowBinary
windows, 83 native type descriptors and two CHECK-valid negative controls.
The 1,121 source/spec/script inputs reconcile with the final code. An exact
reader-carrier bypass yields four expected failures; restoration passes.
The earlier inferred-writer regression was fixed without revising its legacy
refusal tests. Scoped hostile verdict: ROBUST within this finite stored-value
profile, not aggregation execution or all SimpleAggregateFunction types.
The separate shallow source checkout is clean at `41b7bd50` and unbuilt;
executed stock build remains separately pinned at `d9bcb5ab`.
At W164 the reader/writer/table facades have 15,845/25,362/6,911 lines;
overall architecture cleanup, additional type/layout profiles and general
MV/projection coverage remain open. Memory/performance stays deferred.
Exact evidence, inventory and decay conditions:
[SIMPLE_AGGREGATE_EXTENDED_NUMERIC_FRONTIER.md](SIMPLE_AGGREGATE_EXTENDED_NUMERIC_FRONTIER.md).

Previous capability checkpoint (W163, 2026-10-04 local / 2026-10-05 UTC):
the numeric SimpleAggregateFunction paired frontier is VERIFIED within its
finite stored-value profile. Ten standard carriers now retain
exact canonical function/carrier/shape identity through descriptors, values,
bulk/physical codecs, scalar/outer Nullable public part writers/readers,
table batches/windows and offline column values. The finite ClickHouse law
admits 77 scalar pairs, 154 including outer Nullable; invalid narrow `sum`
and floating bitwise pairs are not silently converted.
Root passes 62 focused DEBUG and 785 affected RELEASE examples (68 unique
specs in nine disjoint groups), with zero failures/errors/pending and exit 0.
Two additional native-fixture examples pass. Actual log summaries, membership
and all 738 source/spec/script inputs reconcile with the final code; separate
scalar/Nullable carrier bypasses each fail and exact restoration passes.
Pinned stock accepts all 154 independently library-authored complete parts
through ATTACH/CHECK. Root separately confirms 462 literal library RowBinary
windows, three native windows, all 155 native binary type descriptors and
two CHECK-valid nominal/value mutants rejected by the unchanged oracle.
Scoped hostile verdict: ROBUST within this finite matrix. Fresh shallow source
`41b7bd50` is unbuilt, distinct from executed pinned stock build `d9bcb5ab`.
Raw wide integers, BFloat16, additional functions/carriers, inner Nullable
children and broader wrapper/layout products remain separate. This is
stored-value interoperability, not aggregation execution. It reuses the
existing cohesive owners rather than adding a class per function/type pair.
The current reader/writer/table facades have 15,829/25,288/6,901 lines;
overall architecture cleanup, general MV/projections and all-type completion
remain open. Memory/performance stays deferred. Exact evidence and exclusions:
[SIMPLE_AGGREGATE_NUMERIC_FRONTIER.md](SIMPLE_AGGREGATE_NUMERIC_FRONTIER.md).

Previous architecture checkpoint (W162 at `c0d4c51`, 2026-10-04 local / 2026-10-05 UTC):
scalar and nullable typed-numeric staged validation now has one private,
stateless `StagedTypedNumericPartValidator` owner in its own 150-line file.
Same-signature facade entry points and shared helpers retain semantic-reader
dispatch, bit-exact comparison, canonical Bool guards and validation order.
Scalar primary-index validation remains inline; nullable validation calls the
existing shared helper. The writer remainder is byte-identical to `acae96b`
after excluding the two sealed method definitions, and the moved bodies are
exact after the declared callback substitutions.
Root passes 9 DEBUG and 179 RELEASE examples (27 unique RELEASE specs in five
disjoint groups), with actual exit 0 and zero failures/errors/pending.
A temporary selector bypass produces six failures; exact restoration passes.
All 324 final source/spec/support inputs reconcile with the executed gates.
Scoped hostile verdict: ROBUST for this behavior-preserving ownership move.
The reader/writer/table facades remain 15,798/25,247/6,852 lines; this is not
completion of the architecture cleanup. No new type, API, physical layout,
native compatibility or performance claim is admitted by this extraction.
Exact scope, commands, evidence and refresh conditions:
[MODULARIZATION_FRONTIER.md](MODULARIZATION_FRONTIER.md).

Previous capability checkpoint (W161 at `acae96b`, 2026-10-04 local /
2026-10-05 UTC): W161 pairs
nine canonical unary, non-parametric `SimpleAggregateFunction` identities with
exact UInt64 storage: any, anyLast, min, max, sum, sumWithOverflow, groupBitAnd,
groupBitOr and groupBitXor. The descriptor/value/bulk/physical codecs and
scalar/outer Nullable public Wide-part writer/reader, table windows/batches
and offline column values retain nominal identity; primitive UInt64 APIs do
not silently accept the wrapper. This is stored-value compatibility, not
aggregate execution or AggregatingMergeTree lifecycle support.
Root passes 31 focused DEBUG examples (six unique specs) and 748 affected
RELEASE examples (64 unique specs, eight disjoint groups), all counted groups
with exit 0 and zero failures/errors/pending. Root independently reconciles
actual logs, membership and all 360 then-current source/spec inputs. The
incomplete aggregate attempt is not counted; its final eighth group passes separately.
The opt-in stock reader executes two additional actual native-fixture examples.
Pinned stock qualification passes a native-authored nineteen-column Wide/LZ4
source, eighteen library-authored scalar/Nullable complete parts, actual
ATTACH/CHECK, exact types and 54 literal full/middle/empty RowBinary windows.
Two additional CHECK-valid mutant copies are rejected by the unchanged oracle:
metadata-only min-to-max identity drift and a first-value 0-to-1 change.
Root independently checks native output bytes and confirms the type mutant
changes only columns.txt. All 363 native source/spec/script inputs match the
final gate state. Scoped hostile verdict: ROBUST for this finite profile only.
Three cohesive new owners have separate files, while the reader/writer/table
facades at W161 remain 15,798/25,316/6,852 lines. The subsequent behavior-neutral
W162 staged-validator extraction is recorded above. Fresh clean shallow source
`41b7bd50` is unbuilt and distinct from executed stock build `d9bcb5ab`. Wider type/layout products,
general MV/projections and architecture cleanup remain open; memory/performance
work stays deferred. Exact scope, inventory, commands and refresh conditions:
[SIMPLE_AGGREGATE_FRONTIER.md](SIMPLE_AGGREGATE_FRONTIER.md).

Previous capability checkpoint (2026-10-04): W160 pairs all eleven exact
`Interval` kinds in the general descriptor/value/bulk/physical codecs and
scalar/Nullable public Wide-part readers and writers. Kind identity remains
distinct from primitive Int64 and from other same-width Interval kinds.
`WidePartTable` batches/windows and offline catalog column `.values` share
that admission; Object/JSON Interval fields and actual arms remain refused.
Root passes 31 focused DEBUG examples (six unique specs) and 701 affected
RELEASE examples (57 unique specs, eight disjoint groups), all with zero
failures/errors/pending and exit 0. Root independently reconciles log counts,
membership and current source/spec hashes. These are affected gates, not a
fresh complete-inventory run or a performance measurement.
Pinned-stock qualification passes a native-authored all-kind Wide/LZ4 table,
22 independently library-authored complete parts, actual ATTACH/CHECK, exact
types and independent full/middle/empty RowBinary comparisons. Two CHECK-valid
mutants fail the unchanged original oracle: a metadata-only Second-to-Month
change with identical count bytes, and a one-count value change. Direct
zero-mark reads retain BoundsError; empty SQL/table windows are separate
contracts. Scoped hostile verdict: ROBUST for this finite scalar/Nullable
profile. Generic container/LC codec evidence does not qualify all public
whole-part products, Compact layouts or per-column serializer versions.
Three cohesive Interval owners have separate files, but the large facades
remain; the next staged-validator extraction is only proposed. Fresh shallow
source `41b7bd50` is unbuilt and separate from executable build `d9bcb5ab`.
Broader type/layout products, MV/projections and overall modularization remain
open, with performance deferred. Exact scope, commands, inventory and refresh
conditions are in [INTERVAL_FRONTIER.md](INTERVAL_FRONTIER.md).

Previous capability checkpoint (2026-10-04): W159 extends declared Object/JSON
Dynamic to explicit recursive Array/Tuple/Map sites, with paired codec,
statistics, physical binding and public complete-part reading/writing. Site
rosters are explicit and exact; actual arms and SharedVariant spills retain
the narrower Object arm domain and true Object depth. Each typed field keeps
its first parsed site plan and per-site statistics offsets. Full metadata,
BASIC headers and K+1 grids are checked before full/middle/zero body selection.
Borrowed budgets cover recursive selected-value work and metadata-name copies;
logical budget evidence is not an allocator-RSS certificate.
Root passes 127 focused DEBUG examples (22 unique specs, three disjoint groups)
and 572 affected RELEASE examples (77 unique specs, ten disjoint groups), all
with zero failures/errors/pending and exit 0. Current source/spec hashes match
both gate manifests. Two temporary depth/name-work guard bypasses fail their
intended assertions; source hashes match exactly after restoration. Formatter,
shell/Ruby syntax and hygiene pass. These are affected gates, not a fresh
complete-inventory run or performance measurement.
Pinned-stock qualification passes stock-authored and independently
library-authored complete Wide parts, actual ATTACH/CHECK, explicit per-site
metadata/rosters and independent full/middle literal/type queries. A CHECK-valid
42-to-43 mutant fails the unchanged original value oracle. This native profile
is declared Array/Tuple/Map/direct Dynamic with Int64/String actual rosters,
String/Bool spills, empty collections and NULL, single-stream/BASIC,
Dynamic V3/Object V3 MAP, six rows and three real plus one terminal mark.
Legal Nullable/Tuple, Variant/Array, LC siblings, cap 0 and other actual arms
have spec evidence here, not new general native-product qualification.
Scoped hostile verdict: ROBUST for this slice. Broader JSON/type/layout
products, MV/projections and overall modularization remain open; performance
stays deferred. Source snapshot `895d13ea` is still separate from executable
build `d9bcb5ab`. Exact scope, evidence and refresh conditions are in
[OBJECT_RECURSIVE_DYNAMIC_FRONTIER.md](OBJECT_RECURSIVE_DYNAMIC_FRONTIER.md).

Previous capability checkpoint (2026-10-04): W158 adds paired direct declared
`Dynamic` paths to bounded Object/JSON plans, whole-part writing and public
file/column/table reading. Each path has an explicit actual roster; equal
nominal caps may retain different rosters. The file reader retains the first
validated child plan and exact statistics boundary, validates full metadata
and K+1 grids before selected bodies, and refuses shared-path collisions.
Supplied stale child statistics are omitted, not republished. Callers must
select BASIC explicitly (`mode: 0_u64`); legacy inferred defaults are unchanged.
Root passes 103 focused DEBUG examples (19 unique specs, three disjoint groups)
and 272 affected RELEASE examples (43 unique specs, six disjoint groups), all
with zero failures/errors/pending and exit 0. Root independently reconciles
current source/spec hashes, formatter/syntax/hygiene and a collision-guard
bypass that fails its intended assertion. These are affected gates, not a
new complete-inventory run or performance measurement.
Fresh pinned-stock qualification passes both a stock-authored part and
independently library-authored complete parts, actual ATTACH/CHECK and literal
full/middle/type/shared-arm checks. A CHECK-valid 42-to-43 part fails the same
original literal oracle. The finite native profile is one direct
`Dynamic(max_types=1)` path, Int64 and a shared `Array(Nullable(Int64))` spill,
Wide/single-stream/BASIC/Dynamic V3/Object V3 MAP. Multiple per-path rosters,
NULL, cap 0 and unused arms have spec evidence only here. Scoped hostile verdict:
ROBUST for this slice, not arbitrary JSON/Dynamic compatibility. The source
snapshot `895d13ea` remains separate from executable build `d9bcb5ab`.
Recursive Dynamic, broader physical/type products, MV/projections, overall
modularization and later performance work remain open. Exact boundary,
commands, inventory and refresh conditions are in
[OBJECT_DECLARED_DYNAMIC_FRONTIER.md](OBJECT_DECLARED_DYNAMIC_FRONTIER.md).

Previous capability checkpoint (2026-10-04): W157 retains each validated Dynamic
site's relative statistics-flag offset in `BinaryDynamicBulkPlan`, captured
during the existing writer/parser pass under its shared budget. The strict
getter distinguishes the per-site boundary from EOF and cumulative dry-write
positions; raw structure envelopes do not certify supplied offsets. Root
passes 90 focused DEBUG examples (17 unique specs, two disjoint groups) and
246 affected RELEASE examples (37 unique specs, four disjoint groups), and
2,590 complete-inventory examples (408 unique specs, 41 disjoint non-release
groups with `--no-debug`), all with zero failures/errors/pending and exit 0.
Root independently reconciles observed logs/counts, inventory and current
source/spec hashes; formatter and hygiene pass. Scoped hostile verdict:
ROBUST for retained offsets and the finite stock fixture only.
A read-only check over five original W156 stock metadata streams
passes literal bytes/rosters/names/hashes, paired offsets and three real plus
one terminal mark. Independent Ruby decoding confirms the native mark triples;
two scratch-only wrong-offset controls fail their intended assertions. This
is finite retained-fixture evidence, not a new server run or complete-part
qualification. The refreshed comparison source is `895d13ea` (unbuilt;
DataTypes/Serializations match the previous `db9010c9` snapshot); the separately
pinned stock producer remains build `d9bcb5ab`. Typed Object Dynamic, broader
MV/projection coverage, overall modularization and performance remain open.
The getter is not a provenance-certifying envelope; Object integration must
bind its exact stream and preserve the first parse result. Scope and refresh
conditions are in
[DYNAMIC_STATISTICS_OFFSETS_FRONTIER.md](DYNAMIC_STATISTICS_OFFSETS_FRONTIER.md).

Previous capability checkpoint (2026-10-04): W156 adds an explicit
`BinaryDynamicBulkPhysicalPlan` for prepared per-occurrence actual rosters.
It separates structure/data names and data-prefix ownership, preserves
recursive Array levels and LC stop-site accounting, and refuses physical
collisions and mismatched shared-context limits. Default no-roster consumers
remain closed. Final focused DEBUG passes 109 examples (18 unique specs,
two disjoint groups) and affected RELEASE passes 567 examples (83 unique specs,
nine disjoint groups), plus 2,582 complete-inventory examples (406 unique specs,
41 disjoint non-release groups with `--no-debug`), all with zero
failures/errors/pending and exit 0. Root independently reconciles exact
inventory membership, observed counts, guard exits and current source/spec
hashes; formatter, Ruby syntax and hygiene pass. These are test gates, not
performance measurements.
The finite pinned stock fixture passes four typed columns, six rows and three
real marks. All planner-mapped Dynamic files are re-encoded inside borrowed
stock Wide envelopes; library and CHECK-valid 42-to-43 mutant parts actually
ATTACH and pass CHECK. A separate literal Ruby oracle distinguishes the mutant
and verifies nominal/full/middle results. This is single-stream/BASIC/Dynamic V3
native evidence, not other String/LC products or independently authored
complete parts. Two scratch-only wrong-method controls each fail one of six
adversary examples as intended. The new physical owner has one 712-line file;
the 25,202/15,726/6,786-line writer/reader/table facades are unchanged.
Scoped hostile verdict: ROBUST for this explicit physical-binding boundary and
finite stock fixture, not general compatibility or overall goal completion.
Declared Object Dynamic, general complete parts, broader MV/projection support,
overall modularization and performance remain open. The next prerequisite
preserves structure statistics offsets for metadata marks before typed Object
integration. Exact scope, evidence and refresh conditions are in
[DYNAMIC_PHYSICAL_BINDING_FRONTIER.md](DYNAMIC_PHYSICAL_BINDING_FRONTIER.md).

Previous capability checkpoint (2026-10-04): W155 adds paired generic Dynamic
normalized bulk values and complete per-role K+1 mark grids from explicit
occurrence structures. Equal nominal sites keep distinct stored rosters;
ordinary arms and SharedVariant typed envelopes remain separate. Recursive
containers, unused sites, sparse LC schedules and selected windows share one
operation budget. Root passes 120 focused DEBUG examples (16 unique files,
two disjoint groups), 554 affected RELEASE examples (80 unique files, eight
disjoint groups), and 2,569 complete-inventory examples (403 unique files,
41 disjoint non-release groups with `--no-debug`). Every gate has zero
failures/errors/pending and exit zero; root independently reconciles exact
inventory membership, observed results, guard exits and current source/spec
hashes. A finite stock fixture passes four typed columns, six rows, three
marks and seven SQL probes. Its wire-valid 42-to-43 normalized mutation is
accepted by the Crystal decoder and rejected by an independent value oracle,
not CHECKed by ClickHouse. Stock evidence is single-stream/BASIC/Dynamic V3;
other String/LC products have spec evidence only here. New paired owners have
separate files; the actual-roster plan is 1,186 lines and the large facades
remain unchanged. Scoped hostile verdict: ROBUST for normalized values/grids
and retained legacy consumer fences. No new physical binder, declared Object
Dynamic, complete-part, overall architecture or performance qualification
follows. The source snapshot and pinned executable keep separate identities.
Exact boundary, observed gates and refresh conditions are in
[DYNAMIC_BULK_VALUE_FRONTIER.md](DYNAMIC_BULK_VALUE_FRONTIER.md).

Previous capability checkpoint (2026-10-04): W154 adds paired occurrence-specific
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
The historical 2,539-example total predates the neutral writer selector
extraction. W155's fresh 403-file complete gate above includes that refactor
and supersedes this inventory count, without widening its compatibility scope.

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

Current architecture checkpoint (2026-10-04): Object column physical lane
binding belongs to one private stateless 178-line `LaneBinder` class/file.
The column facade is 123 lines, down from 278; same-signature private delegates
preserve the original prefix-before-binding dispatch and shared operation
budget. Statistics/codec/transport orchestration and buffer lifetimes stay
unchanged. Root passes 23 baseline and post-extraction examples, then all 94
affected examples in each of DEBUG and RELEASE (16 unique files, two serial
disjoint groups per mode), with zero failures/errors/pending and four guard
exits 0. Exact moved-body/facade/loader comparison, final source/spec hash
reconciliation, private visibility, formatting and hygiene pass. A seeded
direct-owner bypass loses the facade trace and fails its intended assertion;
root restores it before final gates. Scoped hostile verdict: ROBUST for this
neutral ownership move only. The general writer/reader/table remain
25,202/15,726/6,786 lines; overall modularization is still open. No new declared
Dynamic, complete-part, native oracle, full-inventory or performance
qualification follows. W158 declared Object Dynamic is the capability return
point; exact scope and refresh conditions are in
[MODULARIZATION_FRONTIER.md](MODULARIZATION_FRONTIER.md).

Previous architecture checkpoint (2026-10-04): the writer's scalar/nullable
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
  logical role rosters are available under shared operation budgets. See
  [the W154 frontier](DYNAMIC_BULK_STRUCTURE_FRONTIER.md).
  W157's `statistics_offset_for(path)` retains the relative pre-statistics-flag
  position for exact decoded bytes or the same plan's emitted structure,
  including an absent-statistics flag. It does not itself certify arbitrary
  stream binding. See
  [the W157 frontier](DYNAMIC_STATISTICS_OFFSETS_FRONTIER.md).
- `BinaryDynamicBulkCodec` and `BinaryDynamicBulkStreams` pair those structures
  with normalized generic Dynamic values and complete per-role mark grids.
  Exact stored-site rosters control ordinary versus SharedVariant selection;
  actual LC-bearing arms keep full sparse schedules across selected windows.
  Supplied statistics are preserved, not recomputed as a publication
  certificate. This API does not itself bind physical files or admit a new
  whole-part writer. See
  [the W155 frontier](DYNAMIC_BULK_VALUE_FRONTIER.md).
- `BinaryDynamicBulkPhysicalPlan` explicitly binds the prepared actual-roster
  plan to separate Dynamic structure/data names and data-prefix ownership.
  It preserves recursive Array levels, ordinary versus SharedVariant String,
  LC stop-site budgets and whole-basename hashing. Default no-roster physical
  consumers remain closed. The finite W156 stock certificate is limited to
  the pinned single-stream/BASIC/Dynamic V3 fixture in borrowed Wide envelopes;
  it is not independently authored complete-part or declared Object Dynamic
  support. See [the W156 frontier](DYNAMIC_PHYSICAL_BINDING_FRONTIER.md).
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
   parts. W158 adds direct declared Dynamic with exact per-path actual rosters,
   retained first-parse metadata and independently authored complete parts in
   its finite BASIC profile. W159 extends explicit declared Dynamic rosters
   through legal recursive wrappers, with separate Array/Tuple/Map whole-part
   qualification. Unqualified Dynamic/Variant/LC leaves/products, Map LC keys, and
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
   W154 adds actual per-occurrence structure/roster planning and W155 pairs it
   with normalized bulk values and complete mark grids. W156 adds explicit
   physical binding with a finite single-stream/BASIC/Dynamic V3 stock
   certificate in borrowed Wide envelopes. W157 retains the per-site
   statistics-flag boundary needed by metadata marks. W158 binds exact child
   streams to those offsets and integrates direct declared Object Dynamic with
   a finite independently authored whole-part certificate. Other physical
   products and independently authored general complete parts remain open.
   W159 binds recursive declared Object Dynamic sites in its separate finite
   paired profile; that is not qualification of every admitted schema product.
   Equal nominal Dynamic types do not imply
   equal per-part or per-site state.
   Shared Nested offsets, AggregateFunction state serialization and broader
   SimpleAggregateFunction carriers/functions/parameters/aliases remain
   unqualified; aggregate states and ordinary stored values are not
   interchangeable capabilities. W163 extends W161's nine canonical unary,
   non-parametric SimpleAggregateFunction identities to ten standard numeric
   carriers under the exact 77-pair eligibility law, with scalar/outer Nullable
   Wide readers/writers and their table/catalog consumers. W164 adds raw wide
   integers and BFloat16 in 41 more scalar pairs, 82 with outer Nullable,
   through those same owners. W168 adds any/anyLast/min/max with String and
   FixedString(N), scalar or outer Nullable, with finite stock width witnesses.
   Inner Nullable children, Decimal/temporal carriers and other
   functions/parameters/aliases remain outside the current certificate.
   The latest finite gate state is recorded in
   [SIMPLE_AGGREGATE_TEXT_FRONTIER.md](SIMPLE_AGGREGATE_TEXT_FRONTIER.md), not a claim of
   complete SimpleAggregateFunction or AggregatingMergeTree execution support.
   W160 now pairs Interval descriptors, values,
   normalized bulk and generic physical composition plus independently authored
   scalar/Nullable whole parts. Recursive and LC Interval codec admission is
   not a public whole-part certificate for every composition.
   The general descriptor kernel still lacks AggregateFunction, Nested,
   Custom, JSON and QBit/QBitWithStride tags. SimpleAggregateFunction's tag is
   now paired only within the W163/W164 numeric and W168 text profiles.
   This is not an inventory of wholly absent physical types: dedicated Object,
   geometry and QBit owners already cover narrower persisted profiles. Set and
   Function descriptors are also absent, but the current ClickHouse source
   makes them IDataTypeDummy expression intermediates that cannot be stored in
   tables; they are not outstanding MergeTree column serializers. See
   `src/DataTypes/{DataTypesBinaryEncoding.h,IDataTypeDummy.h,DataTypeSet.h,
   DataTypeFunction.h}` in the pinned source checkout. Ordinary type aliases
   likewise do not automatically introduce new wire families.
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
   was 6,911 lines at W167; W168 reader/writer/table facades are now
   16,017/25,377/7,015 lines.
   Pure metadata text and JSON typed-path grammar have separate private owners.
   Nested fixed-width temporal/Decimal payload reconstruction now has one
   private owner, with unchanged preflight and inherited private dispatch.
   JSON parsing preserves caller-policy and public-parser overrides; the next
   larger seams are staged validation and physical stream binding, followed
   by reader granule orchestration and table adapters. Each is a separately
   characterized ownership move, not a class per type combination.
   The first writer seam is now executed: the two private generic selectors
   `read_typed_numeric_mark` and `read_typed_nullable_numeric_mark` delegate to
   one private `TypedMarkReadback` owner. W162 now extracts the scalar and
   nullable numeric staged-validator cohort to a separate private owner,
   retaining same-signature facade entry points. W165 extracts scalar/Nullable
   String staged validation into its own private owner; W167 does the same for
   scalar/outer-Nullable FixedString, preserving direct virtual WidePart
   readbacks without moving the I/O/publication lifecycle. W168 adds separate
   text SAF storage-plan and staged-validator owners, reusing PartSchemaMetadata
   for rendering rather than embedding another metadata owner in the facade.
   Other validator
   cohorts and physical stream binding remain separate next seams.
   `Slice(T)`/`forall T`, module reopen overrides and
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
   thin table/catalog adapters. W160 adds exact Interval kind, column-grammar
   and semantic reader-gate owners; W161 adds three cohesive nominal-function,
   scalar/Nullable grammar and semantic-gate owners, each in its own file.
   W163 extends those same owners with one centralized function/carrier law
   and semantic numeric gates, not a new hierarchy per pair. Physical I/O stays
   with the checked fixed-width reader and staging stays
   with the existing typed writer. The qualified W162 numeric, W165 String and
   W167 FixedString staged-validator boundaries, dispatch/lifetime/publication guards and the remaining
   validator cohorts are recorded in
   [MODULARIZATION_FRONTIER.md](MODULARIZATION_FRONTIER.md). Keep one
   cohesive class per file rather than one new class per type combination.
2. Extend paired Object declared fields beyond numeric primitives/Bool/String,
   bare Date/Date32, UUID/IPv4/IPv6, FixedString(N), Decimal(P, S), Enum8/Enum16
   and canonical DateTime/DateTime64/Time/Time64. W140 now admits canonical
   recursive Array/Map(String,V)/Tuple/legal Nullable schemas, with separately
   bounded physical witnesses. W151 adds bounded declared Variant, W158 adds
   direct declared Dynamic and W159 adds recursive declared Dynamic sites;
   remaining lanes include the timezone profile gap and
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
   shared public consumers. W152 preserves the nominal `Dynamic(max_types=N)` cap; W153 adds
   the paired generic logical actual-type/value grammar. W154 adds paired
   actual per-occurrence structure streams and normalized role/site planning.
   W155 now pairs generic Dynamic normalized bulk values and complete mark-grid
   scheduling over that actual state. W156 adds a separate actual-roster
   physical binder and finite borrowed-envelope qualification. W157 now
   preserves statistics offsets in the paired structure owner for metadata
   marks; ordinary value K+1 grids cannot replace that boundary. W158 binds
   exact metadata streams and retains their first parse results, integrating
   direct per-typed-path actual plans with paired storage ownership and
   independently authored complete parts plus stock ATTACH/CHECK/full/middle
   literal tests. W159 extends that retained-site law to recursive declared
   Dynamic with independent complete Array/Tuple/Map parts. Next characterize
   broader JSON physical products before widening those consumers. Keep default
   no-roster consumers and unqualified profiles closed.
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
   W164 closes the raw UInt128/256, Int128/256 and BFloat16 numeric lane.
   W168 closes the bounded String/FixedString lane for four canonical functions
   with scalar/outer Nullable shape. Next proposed SimpleAggregateFunction
   lanes are Decimal and temporal carriers. Their function/result-type laws need separate
   stock construction probes and paired physical qualification before admission.
   AggregateFunction state serialization and shared Nested offsets are separate
   unresolved families; a stored-value wrapper does not certify either.
   For MV/projections, prioritize declaration/dependency/TO-target inspection
   and compatible projection storage, not adding a SQL functions/joins engine.
4. Only then reopen memory/performance work. No current claim of stock-reader
   speed parity or a quantified percentage of complete ClickHouse support.

## Source reference

The newest separate shallow checkout is
`/Users/sergey/SrcArchives/clickhouse-2026-10-05-depth1`, revision
`e9b645ed83ad3c07b64f09fbd014e8f770d8691b` (2026-10-05).
[CLICKHOUSE_SOURCE_REFERENCE.md](CLICKHOUSE_SOURCE_REFERENCE.md) records the
comparison and earlier identities. Against the previous `41b7bd50` snapshot,
six files differ in the bounded DataTypes/Columns/MergeTree roster: Dynamic
recursion guards, Object statistics reuse, empty part-metadata recovery and
current-only merge/fetch cancellation. Compression, Formats, AggregateFunctions
and binary descriptor owners are unchanged. No wire encoding change was found
in that bounded comparison. Unchanged serializers
do not imply unchanged framing, metadata or lifecycle behavior. This is
source evidence only: no executable from this checkout has been built or
qualified. Source identity and the separately pinned executable oracle must
not be conflated. Type families persisting across releases also does not
imply immutable binary descriptors or physical layouts.

This summary becomes stale when source admission, facade dispatch, the tested
runtime/profile or the architecture boundary changes. Refresh it from the
linked owners/frontiers and rerun the affected gates; do not promote a guard or
logical codec into full part support based on this summary alone.
