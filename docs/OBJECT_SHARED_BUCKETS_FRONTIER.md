# Object Shared Buckets Frontier

Document status: W190 VERIFIED within the finite executed scope (2026-10-06).
Baseline: `c9d637d` (W189). Performance remains deferred; the larger goal is open.

## Boundary

Extend the existing Object V3 (wire version 4) shared MAP owner to
MAP_WITH_BUCKETS (shared-data version 1, explicit 1..256 buckets). Reuse the
existing `Array(Tuple(paths String, values String))` serde and borrowed scalar
value envelopes; do not add a codec for each enclosing type combination.

Source anchor: separate clean shallow checkout
`/Users/sergey/SrcArchives/clickhouse-2026-10-05-depth1-ef037e60`, revision
`ef037e60fc7f5654c8c80eefb8be82e3c56f9a67`. Its
`SerializationObjectHelpers.cpp:144-150` assigns a path to `SipHash(path) % N`;
`SerializationObjectSharedData.cpp:648-660` pushes a Bucket component before
delegating to the same map serializer. `ISerialization.cpp:318-376` owns naming.
`SerializationObject.cpp:420-428` collapses Wide empty shared data to one bucket.
This source snapshot is not the separately pinned executable used by tests.

## Design laws

- Preserve existing MAP-0 bytes, stream names, public signatures and refusal
  boundaries. Existing singular shared accessors must not silently expose only
  bucket zero of a multi-bucket layout.
- Name each version-1 lane `<escaped-site>.object_shared_data.<bucket>` before
  ordinary map substream suffixes. Bucket does not increment the inherited
  Array level and is not another row axis.
- Every bucket has the same Object logical occurrence grid and physical parent
  mark-row grid; bucket-local entry counts affect only map sizes. Empty bucket
  rows and entirely empty child marks remain represented.
- Retain explicit layout metadata per Object site. Equal nominal JSON schemas
  do not imply equal bucket counts or state. Admit version 1 with one bucket
  too; do not reinterpret it as version 0 or silently canonicalize caller state.
- Rejoin rows into the original byte-sorted unique path union. Reject a path in
  the wrong bucket, duplicates, typed/dynamic overlap, a missing bucket, schema
  or complete mark-grid drift before exposing assembled data.
- Charge bucket-derived row/entry/role/name allocations to the inherited
  operation budget before allocation. Do not restart a budget per bucket.
  Codec limits are logical resource bounds, not an RSS guarantee.
  Binding/container visits and edges use the borrowed BinaryCodecBudget;
  filename-copy bytes use the physical-name context. The same `max_bytes`
  configuration does not make name bytes and serialized wire bytes equivalent.
  Name copying must not increment `wire_byte_count`.
- A separate one-class/file zero-key ClickHouse SipHash-2-4 owner supplies path
  hashing. Its 64-bit result is not stream-name hashing or reference SipHash128.

## Admitted, rejected and qualification scope

Already admitted: W189's finite normalized hashed Wide/LZ4, plain `.mrk2`,
Object-v3 shared MAP-0 profiles with independent typed/Dynamic state.

Implemented: explicit version-1 1..256-bucket composition through the same
logical codec, physical plan, file reader/binder, complete part writers and
existing typed table consumers. Native-qualified witnesses are root JSON and
Array(JSON), two and 32 buckets, plus stock's empty-shared one-bucket control;
their declaration is `JSON(max_dynamic_types=0, max_dynamic_paths=0, t UInt8)`
with shared String paths. The 256 boundary and independent sibling counts have
unit evidence, not whole-part native qualification. Finite witnesses do not
qualify every schema product. The writer preserves an explicit caller count;
it does not automatically collapse an empty explicit 32-bucket plan to one.

Still rejected: ADVANCED/CHUNKED shared layouts (versions 2/3), legacy Object
structures, Compact parts and all inherited unqualified type/layout products.
No automatic roster inference, SQL execution, projection envelope writer, MV
dependency graph or performance claim in this slice.

## Execution and falsifiers

Risk: CAUTION (persisted serialization). Rollback: exact scoped commit after
DoD; clean baseline and no changes to existing user data or runtime source.

1. Luna writes focused RED specs first; root runs the missing capability.
2. Luna implements the shared SipHash owner and bucket layout composition in
   separate responsibilities/files. Root owns all serial guarded compilation
   and native processes; workers do not run heavy jobs or Git operations.
3. Root runs focused DEBUG and RELEASE specs and relevant inherited Object,
   Array/recursive storage, grid, budget and transport guards. Expected signal:
   zero failures/errors/pending and actual child/guard exits 0.
4. A paired helper reads independently stock-authored parts and creates
   library-owned parts from separate authored literals. Stock must ATTACH and
   CHECK the latter, preserve exact schema, rows and queried literal values.
   Execute root/Array profiles, full/middle/zero reads, inspect actual metadata,
   bucket stream rosters and physical marks. Pin runtime SHA/build independently
   of the source snapshot. Compare generated DEBUG/RELEASE outputs.

Strongest falsifier: move a valid entry to the wrong bucket while preserving
combined entry count, byte lengths and the outer mark grid. It must be rejected;
total-only reconciliation is insufficient. Also test wrong bucket count,
missing/trailing roles, per-bucket row-grid drift, duplicate paths, adversarial
limits before bucket-derived allocation, one-bucket version 1, empty child
groups and independent sibling site counts. Fresh native evidence must match
the actual on-disk layout, not merely the chosen settings.

Stop/narrow on a runtime/profile mismatch; do not loosen ADVANCED/CHUNKED guards
to manufacture parity. Native process failure is inconclusive, not a format
rejection. The certificate below covers only observed profiles.

## Executed evidence and retained failures

Root observes the missing SipHash constant RED, then the corrected bucket spec
RED on the missing `ObjectDocumentStreams.shared_bucket_count` API. A first
bucket test used the existing encoded structure bytes as a decoded structure;
the test was corrected without changing the production API.

The standalone zero-key SipHash owner passes five focused DEBUG examples.
Root additionally compares 515 independently captured native vectors (258
repeated-a lengths and 257 nonuniform byte-prefix lengths) with one-shot and
seven incremental chunkings: zero mismatches, actual guard exit 0. Native
capture processes also exit 0, report the pinned executable/build, and have no
stderr or process errors. Raw decimal vectors expose and correct four manual
transcription errors in the first repeated-a test; no hash behavior was changed
to fit those errors. This is 64-bit hash evidence only, not persisted bucket
compatibility or a performance result.

Root-authored adversaries add exact escaped-site/bucket/Array-level names, one
misplaced map entry with preserved totals and grids, and equal nominal JSON
siblings with distinct one/32-bucket physical plans. The focused DEBUG rerun
passes 13 examples, including a positive 256-bucket boundary. The first compile
caught an exhaustive union `case` inferred as nullable; an explicit type branch
corrected it. The first 81-file DEBUG regression run executes 492 examples with
one remaining historical version-1 refusal fixture failure. That fixture is
updated with a version-1 positive and version-2 refusal control.

Hostile review identifies a reader allocation-order gap: shared
bucket bindings and copied names are materialized before the selected-read
codec preflight. The repaired version-1-only preflight measures scalar role
counts/name-copy work without detached snapshots immediately before collection.
It checks borrowed codec nodes/edges and physical-name bytes before charging;
it never charges those name bytes as wire bytes. The borrowed-budget test
distinguishes exact fresh fit from a previously charged owner and checks no
further counter mutation on refusal. MAP-0 is a no-op. Same-lineage hostile
recheck and root inspection return ROBUST for this repair. An exact-fit/one-byte-
short physical-name-budget test remains a coverage gap; source accounting was
reviewed for hashed and unhashed filename construction. No RSS claim follows.

The final same 81 affected spec files execute 493 DEBUG and 493 RELEASE examples,
zero failures/errors/pending, actual child/guard exits 0. Production/spec inputs
remain unchanged through final native qualification. Ruby fixture-only fixes
follow the spec gates; the Crystal helper is unchanged by them.

The first native runner attempt fails before any native invocation because its
fixture methods were not in Probe's scope. The next stock process succeeds but
exposes a copied expected remainder: native `sipHash64('aa')` is
566436307820060636, whose remainder modulo 32 is 28, not 12. Only the expected
literal changes; production hashing does not. Pure fixture/hash-modulus smoke
passes before fresh final roots are used. Failed roots and logs are retained.

Final DEBUG and RELEASE helpers each read all five independently stock-authored
profiles, publish five independently literal-authored library parts, and pass
stock ATTACH/CHECK with exact schemas and authored full/middle rows. Direct
readers and typed table consumers pass full/middle/zero windows, including
Array physical parent rows `[2,2,2,2]` and logical child counts `[0,1,3,0]`.
Stock configured with 32 buckets for empty shared data actually emits one; the
library control explicitly writes one. Actual versioned ObjectStructure
captures and hashed stream rosters are inspected, not inferred from settings.

Root separately reconciles the two runs' 26 process records, 52 stdout/stderr
captures, 20 utility inputs, 1,792 stream-file hashes/sizes and raw `.mrk2` rows,
240 native and 480 Crystal literal row records, and 60 native schema rows.
All 488 generated library files match DEBUG versus RELEASE. Expected per-key
bucket membership in runner inventories is native-hash-derived expectation,
not an independent decoder of every raw path lane. Wrong-bucket placement has
the separate codec adversary above; returned values have paired native evidence.

Scoped verdict: ROBUST for these normalized hashed Wide/LZ4, plain-mrk2,
Object-v3 MAP_WITH_BUCKETS witnesses and executed guards, not every type/layout
product or the full suite. Source-only master is not the tested runtime build.
Exact commands, pins, log/artifact hashes, retained failures and residual limits:
[object-shared-buckets-w190.json](../.landmark/evidence/object-shared-buckets-w190.json).

## Continuation and decay

Next storage frontier: source-grounded ADVANCED/CHUNKED (versions 2/3) shared
owners and remaining legal enclosing wrapper layouts. Begin with an actual
versioned stock capture and a discriminating RED before changing admission;
do not replace stateful physical serde with nominal type recursion alone.
Broader MV/projections and remaining type compatibility stay open. Performance
work remains deferred until that compatibility frontier closes.

Evidence becomes stale if production/spec/helper inputs, profile assumptions,
source pin or executable change. Refresh with the packet's guarded spec/build
commands and new empty native roots, then reconcile raw captures and compare
outputs. Preserve the old roots; a runner/process failure stays inconclusive.
