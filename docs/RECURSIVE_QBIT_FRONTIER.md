# Recursive QBit storage frontier

Document status: VERIFIED within the finite W230 scope (2026-10-08).
Scoped adversary verdict: ROBUST; not an all-product qualification.
Baseline: `ac628f8a90c5c50e6ca9bfb204e64f65e9220b8a`.
Current frontier: static Array chains over existing QBit leaf codecs.
Bounded context: quiescent Wide/LZ4/Default/plain-mrk2 parts, exact nominal
type declarations, complete reader/writer and typed consumer integration.
Memory/performance work remains deferred.

## Anchor and admission

The pinned stock executable (26.10.1.1201, build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`, SHA-256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`)
created and checked one six-row `Array(QBit(BFloat16, 16))` Wide part.
Three two-row marks contain 2, 0 and 3 flattened QBit occurrences. Stock
`CHECK TABLE` returned `all_1_1_0\t1\t\n`. Its 18 data/mark pairs have hashed
filenames: the key, Array sizes and sixteen QBit planes. Serialization metadata
is version 1, propagates nested versions, uses String version 1 and has no
custom column serializers.

The source snapshot is independently pinned at
`0ca8150d9b1d0886edb2e3b4ab65eebb768d0357`; it is not that executable's build.
`SerializationArray.cpp:352-397` passes flattened child ranges and invokes the
child even when an Array range is empty. `SerializationQBit.cpp:421-464`
delegates bulk lifecycle to the existing FixedString tuple planes.

Already admitted: bare QBit and direct Nullable(QBit), with their existing
nominal scalar and dedicated part owners. This slice admits Array chains
ending in bare QBit or direct Nullable(QBit), using a static per-site roster in
the existing recursive bulk visitors. It does not create a serializer for
each wrapper product.

Rejected surface remains load-bearing: Tuple/Map/Nested/Variant static QBit,
QBit-bearing Dynamic actual containers, JSON typed/shared container widening,
LowCardinality(QBit), Nullable(Array(...)), borrowed persisted-envelope QBit,
Compact/sparse/custom serializers and unqualified physical versions. Existing
direct Dynamic/Object QBit owners retain their independent closed contracts.
Source-valid wrappers not admitted here remain library guards, not claims of
ClickHouse invalidity. Native MV/projection writing and query execution are
not part of this slice.

## Design laws

1. Reuse QBit's nominal raw-bit leaf and plane transpose codec. Array supplies
   its own sizes and flattened occurrence domain at every level.
2. Static sites are keyed by structural path and exact QBit metadata. Plane
   order is numeric group-major, never lexical filename order.
3. Plane byte counts belong to child occurrences, including Nullable slots,
   not outer rows or only non-null children. All plane lanes at a site must
   agree; sizes must consume exactly those occurrences. Empty child marks and
   an entirely empty child part remain meaningful schedules.
4. Validate and charge role/name/offset grids, selected occurrence bytes and
   per-type scratch before allocation. Frame-relative physical offsets are
   not required to be plane-width aligned; normalized plane deltas are.
5. Keep root/direct-Nullable fast paths and unrelated value identity semantics
   unchanged. Recursive QBit Array equality/hash must handle zero, one and
   multiple children without losing exact nominal type or raw-bit identity.
6. Public typed scans, windows and owned column values use the same exact
   static declaration admission and complete-part reader. No silent fallback
   to primitive Array readers, parent-row schedules or base projection rows.
7. Neutral declaration and DynamicStructure parsing describes metadata; it
   does not grant storage admission. Count's shared argument policy, JSON,
   Object and complete Dynamic readers/writers retain their narrower gates.
8. Complete size preflight must not replay an entire marks/frame index for
   every mark. Read each bounded size lane once, with aggregate transport work
   limits and checked schedule storage, while retaining complete late-mark
   shape checks. The reader's inspection and shape phases must consume the
   same operation budget. This is a structural work bound, not a throughput
   claim.

The shape pass retains bounded complete Array-size windows, not QBit payloads.
Its three UInt64 accounting vectors require 24 bytes per mark within the codec
byte limit. Physical-lane inspection and size-lane reads share one consumptive
transport budget, including repeated file/header work. Aggregate size-lane
full-window results must fit `max_result_bytes` (64 MiB by default), a narrower
boundary than independently resetting that budget for every mark. Detached
transport accessors may transiently copy/overlap buffers; these logical limits
are not an RSS or allocator guarantee.

## Execution order and Definition of Done

Risk: CAUTION (serialization and public recursive admission).
Rollback: exact local atomic commit from the clean baseline; no remote push.
Likeliest failure: a root QBit plane schedule accidentally uses Array parent
row counts, or an empty mark hides incomplete lanes.

1. Add descriptor/RowBinary/value-identity and complete-part consumer RED
   tests before production edits. Root executes the focused roster through the
   unchanged guarded runner, one worker and isolated cache.
2. Add one-file admission/site owners; integrate path-keyed sites into shared
   planning, encoder and decoder while retaining root controls and guards.
3. Route recursive static declarations through the existing complete-part
   publication and typed-reader adapter, including offline owned values.
4. Root runs the focused and enumerated affected rosters in DEBUG and RELEASE.
   Expected signal: zero failures/errors/pending; unchanged dedicated QBit,
   Dynamic/Object QBit and ordinary Array controls remain green.
5. Build native helpers in both modes and qualify eight finite stock/library
   profiles: four carriers at dimension 9, BFloat16 explicit stride 16/8,
   Array(Nullable(QBit)), Array(Array(QBit)) and wholly empty Array(QBit).
   Expected signal: literal exact full/middle/empty/EOF RowBinary, nominal
   declarations, stock reads, library publication and native ATTACH/CHECK
   success. Separate raw audit reconstructs expectations and re-inventories
   actual part files; a coherent successful-exit CHECK forgery must reject.
6. Inspect final diff, execute strongest hostile schedule/nominal/budget
   controls, update status/landmarks/evidence, then commit exact relevant paths
   only if the declared signals pass.

Concrete executed commands, frozen source hashes, the complete affected roster
and temporary evidence paths are indexed in
[the W230 evidence packet](../.landmark/evidence/recursive-qbit-w230.json).

## Falsifier roster and stop rules

- Literal Array descriptor and RowBinary round trips, signed zero/NaN payloads,
  empty/multi-element equality and consistent hashes.
- Parent rows [2,2,2] versus child counts [2,0,3], all-empty middle mark,
  entirely empty child parts and two independent Array-size levels.
- Nullable null slots retain child planes; hidden defaults remain bounded.
- Missing/truncated/extra plane or sizes, cross-plane count disagreement,
  shape/occurrence mismatch and wrong nominal carrier/dimension/stride reject.
- Small metadata/payload/depth budgets reject before unbounded allocations.
- Existing root/Nullable QBit, Array(UInt64), Dynamic/Object and rejected-wrapper
  controls preserve their contracts.
- Direct Count nominal constructors must retain the same QBit prohibition as
  its DataType factory after the neutral recursive name parser is widened.
- No callback on malformed complete schedules, including EOF windows.
- A counting transport falsifier distinguishes one complete read per size
  lane from per-mark full-index replay; a small retention budget rejects
  before the corresponding allocation/read. An exact inspection-byte cap
  rejects subsequent size reads instead of silently resetting the budget.
- Raw native CHECK result zero or nonempty failure message rejects even after
  coherent capture hashes and green summary fields are rewritten.

If stock persistence disagrees with the source-derived wrapper contract, do
not relax a production guard to make the harness green. Diagnose the physical
envelope and narrow or pivot the proposed admission. All-product, full-suite,
latest-master and performance claims remain outside this qualification.

## Observed qualification and continuation

The same 54 affected spec files pass 353 examples in DEBUG and RELEASE, with
zero failures, errors or pending examples. The final focused DEBUG roster
passes 92 examples. All 33 changed Crystal files pass formatting checks and
the 35-file code/spec/helper/harness freeze matches after qualification.

Both fresh native captures qualify eight profiles: Int8/BFloat16/Float32/
Float64 at dimension 9, BFloat16 dimension 16 with explicit stride 8,
Array(Nullable(QBit(BFloat16, 16))), two Array levels over QBit(Int8, 3), and
wholly empty Array(QBit(BFloat16, 16)). Each mode records 74 stock-source and
81 evidence processes. Separate raw audits pass exact CHECK success, literal
full/middle/empty/EOF RowBinary, nominal declarations and actual part files.
All 484 generated files match across modes by name, size, SHA-256 and bytes.

Root-observed falsifiers rejected per-mark complete-index replay (five reads
instead of two) and the open-time transport-budget reset (a byte cap that
inspection alone exhausted still admitted shape rereads). Direct Count
constructors also needed their retained QBit guard after neutral metadata
parsing widened. The final controls are green. A temporary omitted-schedule
seed fails the first-window late-corruption test; exact source restoration
precedes final evidence. Both final audits reject CHECK-zero and nonempty
CHECK-message forgeries for stock and library-attached parts, then pass after
exact raw-file restoration.

This qualifies wrapper composition, not new QBit leaf serde or execution.
The native witness covers one and two Array levels and these finite metadata
choices, not every admitted depth/parameter/layout. Opening validates complete
shape, not unselected QBit payload integrity. Transient buffer overlap remains
possible; no memory or throughput improvement is claimed. Temporary raw roots
are regenerable caches, not proof when absent. Refresh dependent claims after
owner, consumer, fixture, harness, source or runtime changes.

Next work should qualify a concrete remaining leaf or physical-state boundary,
not manufacture a codec for every recursive product. Multi-site Tuple/Map/
Nested/Variant QBit admission, broader runtime JSON/Dynamic/LC layouts and
remaining AggregateFunction states remain separate open frontiers. MV/projection
writing/execution and broad facade decomposition are also open; performance
remains deferred.
