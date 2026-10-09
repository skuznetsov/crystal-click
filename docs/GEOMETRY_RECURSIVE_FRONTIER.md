# Nominal Geometry recursive composition frontier — W239

Status: VERIFIED within the seven finite native profiles below; root hostile
verdict ROBUST within scope (2026-10-09). The design was sealed before edits.
Baseline `8e109848d8d7d280ee2234b0c4f4b0d78fb0a6c7`.
Overall goal remains ACTIVE: legal compatible read/write types and MV/projections
precede memory/performance optimization. This slice is not full-goal closure.

## Factual anchor and missing behavior

W238 admits seven static Custom Geo aliases through the shared recursive
descriptor/scalar/bulk visitors. It deliberately rejects the name `Geometry`.
Separate legacy bare Geometry reader/writer consumers already exist and must
retain their typed values and admission contracts.

The separately fetched depth-one source is
`/private/tmp/crystal-click-w238.4nQqSo/clickhouse`, revision
`f25eb93a0b890a3b87df05eb34e2af1f933b4089` (October 9, 08:08:30 UTC).
This is a fetched snapshot, not latest-now or runtime build provenance. Native
runtime remains separately pinned to `26.10.1.1201`, build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`.

`DataTypeCustomGeo.cpp:282-302` creates Geometry as a Custom-named Variant with
FixedDiscriminatorOrder. Its exact global arms are:

| Discriminator | Nominal arm |
| --- | --- |
| 0 | LineString |
| 1 | MultiLineString |
| 2 | MultiPolygon |
| 3 | Point |
| 4 | Polygon |
| 5 | Ring |
| 6 | MultiPoint |
| 255 | intrinsic Variant null |

The nominal descriptor remains `0x2c`, VarUInt name length 8, `Geometry`; it
does not transmit a child Variant roster. The ordinary Variant constructor in
`DataTypeVariant.cpp:26-68` rejects direct Variant TypeIds and sorts arms by
name. `:70-90` preserves the fixed-order constructor's input. Reusing the normal
sorting constructor for Geometry would silently change persisted meanings.
Custom Geometry retains Variant TypeId: direct Nullable and direct ordinary
Variant-arm inclusion must not become legal through nominal tag concealment.

## Target boundary and guards

- Admit exact nominal Geometry descriptor/value composition with one closed
  fixed-order storage owner. Existing Variant and Geo child body visitors are
  reused; no per-wrapper-product serializer or caller-selected unsorted roster.
- Account the complete hidden expansion before constructing it, using the
  original shared descriptor budget and depth. Confirmed source model: 50
  total nodes, 49 edges, maximum depth 11 including the Geometry root; exact
  and one-short executable tests confirm the accounting.
- Preserve ordinary Variant sorted construction/strict canonical wire rules.
  Geometry's hidden fixed roster is not admitted as an ordinary noncanonical
  wire descriptor. Discriminators refer to its exact nominal children.
- Keep the hidden storage marker inside its nominal owner: extracting the
  Variant child must not authorize an ordinary wrapper or a standalone bulk
  declaration. Public descriptor, scalar and both facade/raw bulk root serde
  entrypoints must reject the extracted marker. Internal recursive visitors
  still traverse it beneath the nominal owner; planning/default introspection
  is not independently serialized wire data. A native textual reparse would
  otherwise reorder its arms.
- Retain shared ordinary physical roles, array levels, sparse child axes,
  prefixes, defaults and cumulative codec/transport/result budgets. Structural
  census must reject checksum-valid later-mark defects before first/EOF callback.
- Preserve existing bare Geometry typed APIs; direct generic bulk may support
  the bare root. New recursive products use established BinaryValue consumers.
- Qualified finite stock profiles: Geometry, Array(Geometry), Tuple(label String,
  geom Geometry), Map(String, Geometry), Nested(geom Geometry, point Point),
  Nullable(Tuple(geom Geometry)), Variant(String, Tuple(geom Geometry)). Each
  constructor and persisted profile has actual native evidence. Cover all
  seven arms, intrinsic null, empty bodies and asymmetric
  later marks; distinguish intrinsic null from an enclosing Tuple null.
- Keep direct Nullable(Geometry), Variant(Geometry, String), LowCardinality
  Geometry, arbitrary Custom names, mixed Dynamic/JSON/SAF/AF/QBit/LC owners,
  Geo Map keys and unqualified physical versions rejected. Legal but unqualified
  intersections are not described as upstream-illegal.

Physical target: finite quiescent Wide/LZ4/Default/BASIC/plain-mrk2, sorted UInt64
key plus one payload, independent parent/arm/element axes. Compact/sparse/new
versions, general multi-column publication and projection/MV execution are not
closed by this slice. Prior transport reindexing and large-part budget scaling
limitations remain; no cache, RSS or throughput claim is added.

## Execution, risk and rollback

Risk: CAUTION (persistent serialization and shared nominal/type consumers).
Rollback: one exact local working-feature commit from the clean baseline; no
push or original archive mutation. Root serializes all heavy jobs under the
existing run_safe memory-pressure/RSS/time guard. Delegated Luna work is
candidate evidence; root independently executes gates and hostile review.

Strongest likely failure: sorted and fixed-order Variant bodies appear to
round-trip locally but native tags select different arms, or a concealed
Variant TypeId leaks through ordinary direct-arm admission. Guards: independent
literal stock RowBinary across all seven arms, an ordinary sorted Variant
control, and constructor/binary-wire negative controls.

1. Enumerate shared Custom/Variant visitors and legacy consumers before edits.
   Add executable descriptor/scalar/order/budget RED plus direct-arm refusal
   tests; run the unchanged baseline and capture real failures/errors.
2. Implement closed Geometry storage construction and nominal ownership. Keep
   ordinary Variant normalization and runtime-owner admission policies exact.
3. Reuse generic Variant physical planning, structural census, staged publisher
   and recursive consumer dispatch. Add only required bounded adapter/metadata
   handling, with legacy bare Geometry regression coverage.
4. Reuse native capture/audit infrastructure without weakening W238's fixed
   literals, canonical path/sidecar rules or false-success sensitivity. Run
   stock feasibility before declaring candidate products admitted.
5. Run focused and affected broader DEBUG/RELEASE gates, paired native stock
   read and generated ATTACH/CHECK=1/schema/literal RowBinary, separate raw audit,
   actual-byte mode reconciliation, formatting and Ruby syntax. Attack late
   corruption, owner leakage, coherent audit false success and provenance limits.

## Definition of done and continuation

Exact executed commands, input hashes and observations are recorded in the
[W239 evidence index](../.landmark/evidence/geometry-recursive-w239.json).
Expected local signal: zero failures/errors/pending in
the same selected cohort in DEBUG and RELEASE. Native signals: every admitted
profile's actual captured process success, exact CHECK=1 and nominal schema,
independently authored full/middle/empty RowBinary, public values/typed scans/
windows/EOF for recursive forms, and preserved bare typed consumers.

Do not treat a constructor-only success, self round-trip, summary hash, symlink
inventory check or other model's approval as a persisted compatibility proof.
Independently authored semantic trees must also distinguish public coordinates,
ordered Geo-array children and NULL layers; decoder/encoder agreement alone
cannot establish the public value interpretation.
Do not call compiler/call-site plumbing errors capability RED. Raw-auditor
consistency is not immutable cryptographic execution provenance.

Refresh after relevant source/runtime/compiler/codec/admission/consumer/helper/
auditor/oracle changes or loss of temporary captures. Remaining legal runtime
and layout intersections, state grammars, MV/projection analysis/writing and
broad facade decomposition remain live tasks; memory/performance stays deferred.

## Executed qualification and adversary result

Root ran the same 93 affected spec files in DEBUG and RELEASE: 492 examples
per mode, zero failures/errors/pending. Exact hidden-tree bounds, intrinsic
versus enclosing NULL, ordinary sorted Variant controls, all fixed Geometry
arms and direct-owner refusals pass. A checksum-valid later sparse size defect
is rejected before both early and EOF callbacks. Existing bare GeometryRow and
offline typed value contracts remain unchanged.

Root RED lineage exposed real missing behavior: the unchanged baseline had
five Geometry errors among six kernel examples; a candidate leaked extracted
fixed-order bodies through ordinary constructors/declarations, then through four
public scalar/facade bulk roots and two direct raw bulk roots. The final guards
reject those escapes without blocking traversal beneath the nominal owner.
An initial bare-part metadata error identified sorted versus fixed-order legacy
substream presentation; the producer now validates the exact same file roster
before emitting the legacy order. Fixture arithmetic overflow and mistaken
legacy accessor/type-name expectations were plumbing, not capability RED.

Stock captures contain 35 actual native process records: 30 successes and five
expected normal refusals (codes 43, 36, 43, 50, 50). Both final prebuilt helpers
read the seven actual stock parts, publish/read back seven library parts and
retain bare typed Geometry consumers. The six wrapper profiles also pass public
typed full scans, selected windows and EOF. Independently constructed semantic
trees check every coordinate's bits and ordered array topology; a structurally
valid, codec-round-tripping x/y swap fails comparison to that fixture.

Each paired mode runs five fresh native records plus a separately captured
helper. Native ATTACH, exact CHECK=1, nominal schemas and independent full,
middle-key and empty RowBinary agree. Separate raw audits verify argv/SQL,
statuses, captures and generated/detached/attached/snapshot file consistency.
All 446 generated files match by actual relative names and bytes between modes:
61,240 bytes per mode. Formatting checks for all 25 changed Crystal files and
four Ruby syntax checks pass. No whole-suite or performance gate is claimed.

Each audit rejects seven in-memory zero-exit/wrong-byte controls. Both final
auditors additionally reject two isolated copied-evidence mutations: changed
full Geometry RowBinary with coherently updated output witnesses, and a summary
exit status contradicting its raw sidecar. Genuine, disjoint rebased-clone and
restored controls pass; originals remain unchanged. The verdict is ROBUST for
this finite boundary, not cryptographic execution provenance: a coordinated
rewrite of every raw/generated/attached/snapshot copy and every witness can
evade a consistency auditor without an independent immutable anchor.

Continuation: recursive child serde is reusable; a new runtime owner must still
establish its prefix, dictionary/arm state and element/mark schedule. Next
falsifier is one legal JSON/Dynamic/LowCardinality owner intersection against
independent stock bytes, writer ATTACH and selected public reads. Do not widen
physical-version admission from nominal descriptor acceptance alone.
