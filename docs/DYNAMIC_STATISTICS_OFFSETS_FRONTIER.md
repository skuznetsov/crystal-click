# Dynamic structure statistics offsets (W157)

Status: VERIFIED for per-site offset retention within the admitted structure
grammar and finite retained stock fixture; hostile verdict ROBUST in that scope.
Baseline: `db99a52bc2acc2416b1d7a96f5188b7e0e4a7d6c`.
Risk: CAUTION (metadata positions for persisted structure streams).
Rollback: one exact-path local commit; no remote mutation.

## Boundary

Retain the relative statistics-suffix position on each already validated
`BinaryDynamicBulkPlan` site. Existing writer discovery already serializes the
structure under its operation budget; reader discovery already parses it.
Capture their existing offset-returning codec entry points, without a second
grammar, reparsing, or a fresh budget. Expose a strict per-occurrence lookup.
The raw `BinaryDynamicStructureStreams` envelope remains unvalidated input;
it neither accepts nor certifies caller-supplied offsets.

The offset is relative to the beginning of that site's complete structure
blob, immediately before the statistics flag, including when the flag is zero.
It is not the blob's EOF, an aggregate dry-write position, a data mark, an
offset relative to a compressed frame, or proof that supplied counts are true.
Present statistics change suffix length, not the descriptor-prefix boundary.

Rejected: declared Object Dynamic admission, metadata-mark consumer migration,
new parts/profiles, statistics recomputation, MV/projections and performance
claims. Existing Dynamic/Object consumer fences remain load-bearing. This is
a prerequisite for typed Object integration, not that integration itself.

## Source and design laws

Source reference: unbuilt shallow ClickHouse revision
`db9010c9dd7cc78968fb077c967b915fc6166a7b` in
`/Users/sergey/SrcArchives/clickhouse-2026-10-04-depth1-db9010c9`.
Root's recursive comparison confirms `src/DataTypes` and `src/Columns` are
identical to the previous `b94acbe3` source. MergeTree has changed; directory
equality is not assumed for it. The bounded audit found no mark-law change:
`MergeTreeDataPartWriterWide.cpp` is unchanged. New ColumnsCache/reader paths
are not qualified by this source inspection.
Runtime certificates, if reused, retain their separately pinned identities.

`SerializationDynamic.cpp:245-268,270-320,529-553` writes the descriptor
prefix followed by the statistics flag/payload, including explicit flag zero
for V3 PREFIX_EMPTY. `MergeTreeDataPartWriterWide.cpp:584,654-685,857-872,963-967`
chooses SUFFIX statistics, records real marks before granules, and writes the
final zero-row mark after the suffix. Physical marks are compressed-file/block
coordinates; W157 exposes only the per-structure decompressed relative byte
position used to bind those marks, not their physical coordinate pair.

Root independently read the current Dynamic suffix and Wide suffix-before-
final-mark ordering. Source review accepts the existing plan's bounded scalar
as the smallest trustworthy owner. Future Object integration must retain the
first parse result rather than parse those same bytes twice or reconstruct a
read boundary by reserializing under a reset budget. Offsets are trustworthy
only for exact decoded bytes or bytes emitted by that same immutable plan.

Store one scalar on the existing bounded site record; do not create an
unbounded auxiliary offset map or change logical resource units merely to
count fields inside an existing metadata entity. Retain aggregate descriptor,
site/role, path/name, depth and wire budgets. No caller-owned mutable snapshot
may change retained positions. Unknown paths raise `KeyError`.

Consumer inventory: `rg -n 'BinaryDynamicStructureStreams|encode_structure_streams|decode_structure_streams|statistics_offset' src spec scripts`
identifies paired bulk codec/streams, structure-plan tests and qualifiers;
Object's existing structure codec, column writer and file reader independently
use offsets. W157 changes the plan only; those raw envelopes and Object
consumers do not gain a new trust contract or relaxed guard.

## Execution and falsifiers

1. Root runs new literal tests against the baseline. A capability-detecting
   adapter yields a missing metadata value for comparison; the expected RED
   is an assertion mismatch, never a compiler error or missing symbol.
2. Luna changes only the plan and its direct specs after RED. Capture write
   and read offsets at the existing codec call, never infer EOF or parse twice.
3. Root checks absent/present statistics, empty/nested/unused sites, different
   descriptor widths on equal nominal Dynamic sites, relative multi-site
   offsets, immutable snapshots, unknown paths and both String profiles.
4. Root runs focused DEBUG and affected RELEASE specs serially under
   `cogni-ml/scripts/run_safe.sh`, using an isolated Crystal cache,
   `--single-module --threads 1 --link-flags=-fuse-ld=ld --error-trace`.
   RELEASE adds `--release --no-debug`; compiler guard is 600 seconds,
   12 GiB, 50-percent system-free-memory threshold. Expected: zero failures,
   errors or pending cases, observed exit zero. Format and diff hygiene pass.
5. A stock-derived offset check compares the new plan against literal expected
   positions or independently decoded native metadata marks, not against its
   own round trip alone. If native verification is unavailable, narrow the
   qualification to the actually executed literal/source checks.
6. Hostile review attacks EOF substitution, cumulative positions, site reuse,
   missing-statistics erasure, invalid trailing bytes, and budget resets. An
   isolated seeded wrong-offset control must fail the intended witness.

Refresh after descriptor/structure encoding, site discovery, codec budget,
immutable-owner, consumer mark contract, or upstream source changes.
Next track: typed Dynamic Object metadata/lane integration with a separate
admission and native falsifier; keep all current guards until then.

## Root execution seal (2026-10-04)

Before production changes, the four initial capability-adapted cases compile
and fail their offset/unknown-site assertions (four examples, four failures,
zero errors/pending, exit 1). A separate literal reader witness successfully
decodes the structure, then fails on the absent offset (one example, one
failure, zero errors/pending, exit 1). The adapters are removed from the final
direct API specs. These are observed assertion REDs, not missing-symbol errors.

The final tests cover eight new examples in two files, including exact retained
node/element/wire-byte deltas against an uncharged baseline on borrowed,
precharged budgets. Repeated offset lookups leave all three counters unchanged.
Earlier W154 exact/one-short budget tests are also included in the focused gate.
Root's serial guarded runner selects a fresh sorted inventory in disjoint
groups of at most ten specs, hashes every production source plus selected
specs, and requires one observed zero-failure/error/pending result and exit 0
per group, with unchanged source/spec hashes:

- Focused DEBUG: 90 examples, 17 unique specs, two groups, exit 0.
- Affected RELEASE: 246 examples, 37 unique specs, four groups, exit 0.
- Complete inventory: 2,590 examples, 408 unique specs, 41 groups, exit 0;
  this is freshly executed, not inferred from the W156 checkpoint.

All three gates have zero failures/errors/pending. Root independently
reconciles fresh inventory membership, disjoint groups, observed log counts,
guard exits and current source/spec hashes (exit 0). The exact four changed
Crystal paths pass the guarded formatter check (exit 0); Ruby runner syntax
and exact-path diff/secret hygiene pass. These are test and metadata-position
results, not RSS or performance measurements.

Focused selection is `w157|binary_dynamic_|dynamic_descriptor_consumer|dynamic_structure_roster`.
Affected selection is anchored at `spec/`, with prefixes `binary_dynamic_`,
`dynamic_`, `bulk_dynamic_`, `object_dynamic_structure_`, `object_documents_`,
`object_column_writer_`, `object_file_reader_`, `object_recursive_consumers_`,
`object_variant_consumers_`, `object_low_cardinality_consumers_`,
`binary_bulk_w122` and `compressed_mark_transport_`.
Complete selection is every current `spec/**/*_spec.cr` exactly once; its
non-release compilation uses `--no-debug`.

The observed gate records and execution commands are local and transient:

```text
ruby /private/tmp/crystal-click-w157.SlUPxQ/gates.rb focused debug focused-debug-final
ruby /private/tmp/crystal-click-w157.SlUPxQ/gates.rb affected release affected-release-final
ruby /private/tmp/crystal-click-w157.SlUPxQ/gates.rb all full full-inventory-final
ruby /private/tmp/crystal-click-w157.SlUPxQ/gates.rb reconcile focused-debug-final affected-release-final full-inventory-final
```

These labels are write-once; reruns require fresh labels/scratch and a current
inventory. Lost logs/fixtures require fresh execution, not inference from the
recorded totals. The result records are an evidence index, not proof by shape.

Two independently seeded scratch-only production errors fail their intended
witnesses without changing the repository:

- Reader offset replaced with blob EOF: expected 10, got 11; one example,
  one assertion failure, zero errors/pending, exit 1.
- Writer offset increased by the preceding dry-output size, while preserving
  the first site's pre-flag boundary: nested site expected 9, got 22; one
  example, one assertion failure, zero errors/pending, exit 1.

Root additionally runs the read-only RELEASE qualifier
`scripts/check_dynamic_statistics_offsets_w157.cr --part STOCK_PART` under the
same compiler guard. It passes all five original W156 stock-generated metadata
streams: root `(offset 10, EOF 22)`, left/right Tuple sites and Array child
`(10, 14)`, unused nested Dynamic site `(9, 12)`. Each has three real marks
with two rows and one terminal zero-row mark. Literal bytes, ordinary and
canonical rosters, physical names/hashes, read-plan offsets and writer-owned
re-encoding are checked separately. Root's independent Ruby `Q<*` decoding of
the 96-byte `.mrk2` files also matches the literal physical records: real
`(0, offset, 2)` triples and terminal `(0, EOF, 0)`.

This reuses the original stock part at
`/private/tmp/crystal-click-w156-native-final.a5TmEj/child/stores/w156_stock/store/3e4/3e4ebfe9-1814-44ad-be13-a43fc2a0cb1b/all_1_1_0`.
It is not a fresh server run, new ATTACH/CHECK, or independently authored part
qualification. Its separately pinned producer is ClickHouse 26.10.1.1201,
build `d9bcb5ab007f0f6299f7f973f2642245bab3d028`, executable SHA-256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`,
not the unbuilt current `db9010c9` source. Native scope remains finite,
single-stream/BASIC/Dynamic V3. Other String profiles and absent statistics
have literal/spec evidence here, not an added native certificate.

Root independently inspected the codec calls, shared contexts, immutable site
owner and literal witnesses. Luna's bounded read-only hostile review found no
concrete blocker; that review is correlated supporting evidence, not a second
independent runtime certificate. The scalar getter cannot enforce downstream
pairing with its exact stream and is not a provenance-certifying envelope.
The future Object consumer must establish that binding and preserve the first
parse result. No statistics recomputation or general compatibility claim is
admitted by these tests.

Scoped root hostile verdict: ROBUST for retained relative offsets under the
existing grammar/shared-budget contract and the five-site stock fixture.
Declared Object Dynamic, new profiles/parts, full modularization, MV/projection
coverage and the overall performance goal are not complete. Refresh this
certificate on any of the boundary changes listed above.
