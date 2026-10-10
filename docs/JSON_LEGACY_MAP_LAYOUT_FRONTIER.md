# JSON legacy MAP layout frontier (W254)

Status: VERIFIED / root adversary ROBUST within the finite target. Scope is
root, complete Wide-part JSON Object metadata using MergeTree Object V1/V2 and
their MAP shared-data layout. This is one shared physical-admission change,
not a matrix of serializers for each recursive wrapper.

## Problem and source law

At baseline `e33f4c0453e4ccb2feb54d20599b692ae61f34eb`, Object shared-layout
admission accepts only version 4 (MergeTree V3). That gate is used by schema
validation, physical-plan construction, and
statistics recomputation, even though the full Object structure codec can
decode and encode versions 0, 2, and 4. The public Object writer also rebuilds
statistics, so simply allowing legacy metadata through the reader would not
preserve the requested wire version on write.

Reference source is the official shallow ClickHouse checkout
`/private/tmp/clickhouse-w254-upstream.AqeqyC`, revision
`ed30948f095ecb70679986d7d60e27ad770ae27a` (distinct from the native runtime).

- `src/DataTypes/Serializations/SerializationObject.h:27-44` defines MergeTree
  Object V1 as version 0, V2 as version 2, and V3 as version 4. V1 has a
  legacy maximum-path field; V2 does not. Both legacy versions carry complete
  statistics.
- `src/DataTypes/Serializations/SerializationObject.cpp:299-312` selects MAP
  for V1/V2. Other shared-data encodings are V3-only.
- `SerializationObject.cpp:399-428` writes the actual path count in the V1
  legacy maximum-path slot. It is not the configured JSON cap.
- `SerializationObject.cpp:760-765` reads and discards that V1 field. A local
  decoded descriptor should retain its exact wire value, while a newly
  recomputed writer plan should canonicalize the field to its actual path
  count.
- `SerializationObject.cpp:801-808` makes V1/V2 statistics mandatory; V3
  instead has an explicit statistics-presence flag.
- `src/DataTypes/Serializations/SerializationObjectSharedData.cpp:133-142`
  shows that MAP uses the ordinary Map serializer.

Baseline local boundary:

- `src/crystal_click/object_shared_bucket_layout.cr` rejects every object
  whose version is not 4 before checking the MAP profile.
- `object_document_schema.cr` and `object_document_physical_plan.cr` both
  depend on that shared admission gate.
- `object_document_statistics.cr` also depends on it and currently rebuilds
  version 4 metadata, losing the original V1/V2 selection.
- `object_structure_codec.cr` already handles complete V1/V2 headers and
  mandatory statistics. Its prefix-only parser intentionally admits only V3;
  that local boundary remains closed in this slice. Upstream callbacks can use
  statistics-free serialization modes; this is not an upstream prohibition on
  all legacy inline serialization. The local prefix codec and export contract
  have only qualified the V3 framing.
- `object_document_column_writer.cr` currently gates inline export by shared
  data version. The shared owner/preflight must additionally reject every
  legacy Object structure, including a legacy descendant beneath a V3 root,
  before emitting a truncated prefix.

## Admitted and rejected behavior

Admit complete root Object V1/V2 metadata only when shared-data version is 0,
bucket count is 1, the version-specific legacy field rule is satisfied, and
the complete mandatory statistics roster matches the path roster. Use the
existing MAP shared-value codecs and physical stream owners. Keep the selected
Object version through public schema/physical admission and statistics
recomputation. Preserve exact decoded V1 legacy-field values in immutable
metadata; newly recomputed V1 writes use the actual current path count, as the
stock writer does.

Continue rejecting Object versions 1 and 3 (native-only), non-MAP V1/V2,
incorrect bucket counts, missing/mismatched legacy statistics, and incomplete
V1/V2 prefix-only inline structures. Preserve V3 MAP, buckets, advanced, and
chunked behavior. Do not introduce Compact, native-only layout, serialization
mode, SQL insertion, child-site, or new value codec behavior in this slice.

## Falsifiers, risk, and rollback

Risk is CAUTION: this changes serialized-layout admission and writer metadata
reconstruction. The strongest failure mode is either admitting a legacy header
without its mandatory statistics/MAP coordinates, or silently converting an
explicit V1/V2 writer plan back to V3 during recomputation. A descendant legacy
structure can also be corrupted if an inline exporter truncates its complete
metadata to a V3 prefix.

The initial behavioral RED admitted a valid V2 schema/physical plan and used
the public Wide Object writer to show V1/V2 selection must survive statistics
recomputation. The focused W254 spec now also distinguishes exact decode of an
arbitrary V1 legacy maximum (9) from the writer's canonical recomputation to
the actual path count (1). It rejects native-only versions 1/3, V1/V2 shared
layouts other than MAP/one bucket, invalid V3 shared-version/bucket headers,
missing mandatory V1/V2 statistics, and malformed/mismatched legacy fields or
statistics rosters. Inline cases require both public exporters to refuse V1/V2
root metadata and a legacy JSON descendant under a V3 root. The adjacent W125
physical-plan assertion now treats V2 MAP as admitted while retaining its
advanced-layout controls.

Root ran the guarded focused commands:

```text
crystal spec spec/object_legacy_map_layout_w254_spec.cr
crystal spec spec/physical_stream_plan_w125_spec.cr
```

Expected result: zero failures, errors, and pending examples; a valid complete
legacy writer round-trips its version, V1 decoded field values are preserved,
recomputed V1 uses the actual path count, malformed metadata remains rejected,
and inline V1/V2 remain refused. Root owns compiler/native execution. Rollback
is one atomic local commit; no history rewrite or push. No source, runtime, or
captured part is mutated by these unit tests.

The native fixture contains six rows in three two-row marks, plus a distinct
EOF sentinel: typed `title String` and `tags Array(String)`, an inferred
`counter` Dynamic slot with four Int64 values, one shared String, and one
Nothing, plus three shared MAP `spill` entries. Native and Crystal expectations
are independently authored. Stored inferred Nothing/absence is not claimed
to be distinguishable; native `isNull(counter)` checks its value semantics.
The global `merge_tree_use_v1_object_and_dynamic_serialization` override is
disabled explicitly so the chosen table Object version is actually exercised.

## Observed qualification

The focused gate passes 28 examples. The ordered 48-file affected roster passes
170 + 81 + 70 = 321 examples in each DEBUG/RELEASE mode, with zero failures,
errors or pending examples. Both final helpers build. This is an affected
regression roster, not the full repository suite.

Four fresh reciprocal cells (Object V1/V2 x DEBUG/RELEASE) execute eight pinned
ClickHouse calls and four helper calls. Stock-generated parts pass direct
Object reads, public `WidePartTable` scans and offline column `.values`;
Crystal-generated parts pass stock ATTACH, CHECK=1, exact nominal schema and
independently authored six-row value/type queries. The fixture uses explicit
Object plans, not a new writer version selector or a changed default.

Root independently decompresses and parses 16 complete Object/Dynamic
structure streams in eight original stock/library parts, resolves their hashed
filenames, and checks structure marks, statistics offsets, logical EOF and
literal UInt64 keys. Native EOF may point inside the last compressed frame;
the library's EOF may point to the next frame boundary. Both normalize to the
same logical end. Generated DEBUG/RELEASE bytes agree for all 76 files /
10,713 bytes per mode (V1: 38 / 5,357; V2: 38 / 5,356).

Thirty-six in-memory wire/coordinate controls reject at their intended guards
(wrong Object version, stale V1 capacity, missing mandatory statistics and
shifted Object/Dynamic marks). Eight successful-exit but CHECK=0 stdout
forgeries reject at the actual native-result guard; unmodified baseline checks
pass again. These are auditor/oracle controls, not claims of injected on-disk
corruption or additional production-code fuzz coverage. Root also reconciles
all actual retained native literals and unchanged snapshots of 12 source,
generated and attached-copy parts. Captures are not edited.

The native oracle is separately pinned ClickHouse 26.10.1.1201 / build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`; it is not a build of the fresh
comparison tree. Initial fixture/return-type/Ruby compatibility diagnostics,
a sandbox process-group refusal and corrected root-auditor expectations are
excluded from format qualification. Serial workloads keep the existing
50% free-memory, 12 GiB RSS and 600-second outer guard; native calls retain
512 MiB, one thread and a 10-second deadline.

The [root-owned evidence index](../.landmark/evidence/json-legacy-map-layout-w254.json)
records exact commands, finite scope, source/tool/helper pins, capture paths
and root checks. Filled fields and correlated Luna reviews are not proof.
Refresh after serialization/admission/statistics/inline/stream/compiler/helper/
oracle/runtime changes or capture loss. Overall goal ACTIVE; memory/performance
remains deferred.

No claim is made for native-only versions 1/3, V1/V2 inline prefixes, Compact,
recursive child layout interoperability, all JSON path products, materialized
views/projections, or performance. Those require separate source-backed
frontiers and falsifiers.
