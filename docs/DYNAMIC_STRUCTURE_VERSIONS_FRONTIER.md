# Dynamic persisted structure versions frontier

## W250: verified within the finite persisted-version target

The full objective remains reader/writer type compatibility and MV/projection
support before memory or performance optimization. This slice addresses an
observed persisted-format gap, not another constructor-specific codec.

Baseline: `16983dafadd8175b016ac0df39e519137baf3848` (W249). At that revision,
`DynamicStructureCodec` accepts only wire version 4 (MergeTree Dynamic V3) and
rejects versions 1 and 2 before reading their ordinary alternative rosters.

Source comparison: official shallow checkout
`/private/tmp/clickhouse-w249-upstream-P7bxRQ`, revision
`fe0f91b6c3de9e1efa33a1bce4ca9bcbfb4c509d`, especially
`src/DataTypes/Serializations/SerializationDynamic.cpp`. The source revision is
not the native runtime identity. The separately pinned executable is
ClickHouse `26.10.1.1201`, build `d9bcb5ab007f0f6299f7f973f2642245bab3d028`,
SHA256 `bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.

## Format and ownership

| Wire version | Ordinary alternative metadata | Complete statistics |
| --- | --- | --- |
| 1 | Ignored legacy maximum VarUInt, count, StringBinary SQL names | Mandatory counts and shared-name map, no presence flag |
| 2 | Count, StringBinary SQL names | Mandatory counts and shared-name map, no presence flag |
| 4 / V3 | Count, binary DataType descriptors | Presence byte, then optional counts and shared-name map |

The immutable structure owner must retain its wire version and, for V1, the
legacy maximum field. ClickHouse skips that field on read: it is not a cap to
apply to the actual count, nor must it equal that count. A newly constructed
V1 structure may default it to the ordinary alternative count. Exact source
identity must survive decode, re-encode, and statistics rebuilding.

Prefix-only operations deliberately omit the complete statistics suffix.
They must remain distinct from complete-blob operations for all admitted
versions. Legacy complete writes require explicit statistics; they must not
silently invent a V3 absence flag or misinterpret a missing suffix as zero.

Textual alternative parsing must use an operation-wide bounded budget,
including inherited descriptor depth, metadata, names, and all sites. Reuse
the neutral recursive type-name grammar where possible, with one cohesive
version dispatch adapter. Do not introduce codecs for individual container/type
products. Reject any textual spelling that cannot preserve the admitted
descriptor/layout identity instead of guessing a leaf storage width.

The shared prefix parser is also consumed by the inline Object/shared-path
tape. `StatisticsMode::NONE` omits statistics in the source serializer for all
three admitted versions, not only V3. A finite local legacy-prefix composition
test covers that handoff; it does not qualify new native Compact layouts.
Legacy SQL names in this slice require UTF-8 on both read and write. This is
an explicit admission bound, not proof that every non-UTF-8 ClickHouse Enum
label is invalid. V3's opaque binary descriptor behavior remains unchanged.

## API and recursive composition

`DynamicStructure.new(types, statistics)` remains V3 by default. Explicit
`version: DynamicStructure::VERSION_V1` or `VERSION_V2` selects the persisted
metadata framing; V1 also accepts `legacy_max_dynamic_types:`. The constructor
allows statistics-free prefix ownership, while a complete legacy encode
requires explicit `StructureStatistics`.

`WidePartColumn.dynamic_bulk` accepts those structures through its existing
per-site map. The declared recursive tree, occurrence schedules, value codec,
physical plan and public consumers are unchanged. Different sites can retain
different versions in one local part. Native qualification below uses uniform
V1 or V2 parts, not a mixed-version stock witness.

## Admission and guards

- Admit V1/V2 complete and prefix structure framing, and the existing legal
  alternative and recursive-site mechanisms that the bounded SQL-name parser
  can represent without losing descriptor identity.
- Keep V3 defaults, bytewise vectors, optional-statistics behavior, and shared
  budgets unchanged.
- Keep existing immediate Dynamic, Variant, Nothing, Nullable, and
  LowCardinality(Nullable) alternative fences. This is not an admission change
  for illegal ClickHouse type constructors.
- Keep Native-only FLATTENED version 3 and unknown versions rejected as
  corrupt persisted structures.
- Preserve exact-consumption, count-before-allocation, duplicate-name,
  canonical-name/layout, UTF-8, depth, aggregate-node/edge/byte, metadata-mark,
  no-callback-before-preflight, and exclusive-publication checks.

JSON-specific SQL-name grammar and new aggregate function states are separate
frontiers unless a concrete existing common parser already supports them.
Supporting a version does not certify every legal alternative or layout.
Compact MergeTree parts, general projection publication, MV execution,
server lifecycle, and performance are not closed by this slice.

## Risk, falsifier, and verification plan

Risk: CAUTION (persisted metadata and shared recursive admission). The strongest
failure is treating V1/V2 as V3 after parsing the header: names, statistics
offsets, or inherited site identities then drift while self-round trips pass.
Rollback is the single atomic feature commit; no remote write is authorized.

1. Before production edits, run behavioral literal V1/V2 decode and exact
   re-encode tests against the baseline. The qualifying RED is an unsupported
   valid legacy structure, not a compile failure or invalid fixture.
2. Implement version dispatch into the common roster, retaining the profile
   through complete/prefix codecs and statistics rebuilding.
3. Run DEBUG and RELEASE scoped structure, budget, recursive-plan, physical
   part, and public-consumer regressions with the existing guarded toolchain.
   Exact commands and outcomes belong in the evidence index after execution.
4. Capture reciprocal stock/library Wide parts for V1 and V2. Reuse W249's
   independently authored Nested/container values, empty first mark, NULL,
   library ordinary Int64 and shared String spill, declared schema, direct reader,
   full/window/candidate table scans, and offline values. Assert the actual
   structure version and mandatory statistics framing, not just a setting.
   The stock child site may register String and spill Int64 instead: its
   one-type roster must be present in the independent literal census, with
   exact origin-specific ordinary/shared counts. Do not force the library's
   registration choice onto the stock writer.
5. Hostile checks: mismatched legacy maximum, truncation, trailing bytes,
   aggregate budget exhaustion across names/sites, constructor fences,
   descriptor-name collisions, and malformed metadata marks fail closed.

DoD: the declared scoped DEBUG/RELEASE suites have no failures/errors/pending;
both V1/V2 reciprocal captures produce exact schema and values, native
`CHECK TABLE = 1`, unchanged generated files after permitted ATTACH metadata,
and direct evidence of the retained physical versions. A same-lineage review
is correlated; root must inspect the diff and raw captures independently.

## Current evidence

The qualifying baseline RED compiled and ran five behavioral examples: one
failure and three errors rejected valid legacy metadata; the V3 control passed.
The final same ordered 30-file scoped roster passes 87 + 46 + 60 = 193 examples
in DEBUG and 193 in RELEASE, with zero failures, errors or pending examples.
All four consumer/structure-auditor helper builds pass at the pinned final
source closures. This is scoped regression evidence, not the whole repository
suite. Early compile, fixture and harness diagnostics are not qualifying REDs
or final native evidence.

Four fresh reciprocal native cells pass: V1/single String and V2/sized String,
each in DEBUG and RELEASE. This is not the full eight-cell Cartesian product
of versions and String profiles. Six Dynamic sites in five recursive families
use adaptive Wide/BASIC parts with P=[2,2,1,EOF0]. Sixteen native calls and
sixteen helper calls establish exact ordered schema, literal values and actual
Dynamic types, native ATTACH/CHECK=1, stock re-emission/CHECK=1 and library
direct/full-table/window/candidate-mark/offline reads. Stock registers String
at the recursive child site while the library registers Int64; both exact
origin-specific ordinary/shared censuses are checked.

Root independently reconciles the current source/runtime/helper hashes, raw
process argv/stdin/stdout/stderr/exit, complete part inventories, ATTACH's only
additional source-derived marker and the byte-identical offline copy. The raw
audit decompresses and parses all 48 structure streams independently, checking
V1/V2 headers, SQL names, mandatory unflagged statistics, exact consumption and
all physical `.mrk2` coordinates. Actual library bytes agree across modes:
V1/single 94 files / 14,589 bytes and V2/sized 114 / 17,630, totaling 208 files /
32,219 bytes per mode.

Two semantic negative controls mutate only private copies of library and stock
part metadata after their respective snapshots. The actual probe's final
`stable!` rejects each at its origin-specific guard. Baseline, library-restored
and stock-restored acceptance pass; restoration is checked byte-for-byte.
No qualified capture is mutated. Raw artifacts and outer root-owned guarded
builds provide the qualification, not model agreement or a structurally valid
evidence index alone.

Root adversary verdict: ROBUST within this finite target. Literal V1 maximum
9 with one ordinary alternative, zero/UInt64::MAX preservation, empty rosters,
mixed V1/V2/V3 local sites, statistics rebuilding, shared prefix tapes,
aggregate budgets, inherited depth, UTF-8/opaque-name separation, descriptor
alias rejection and unchanged constructor fences are covered by the scoped
tests. Native qualification does not extend those fixtures to every legal
alternative, mixed-version stock parts or Compact MergeTree.

The [root-owned evidence index](../.landmark/evidence/dynamic-structure-versions-w250.json)
records exact commands, source/build/capture pins and executed controls. Refresh
after parser/codec/budget/consumer/helper/fixture/oracle/compiler/runtime changes
or loss of referenced raw captures. Offline synthetic catalog reads do not
prove stock-root discovery or server Active state; logical budgets do not bound
transient allocations/RSS. Standalone helper hash observations do not certify
arbitrary helper build provenance or a hostile immutable execution environment.

Remaining frontiers include JSON SQL-name grammar and contextual layouts,
additional aggregate states, general projection publication and MV execution,
general keys/partitions and broader facade decomposition. Overall goal ACTIVE;
memory/performance is deferred, with no speed or 10% parity claim and no push.
