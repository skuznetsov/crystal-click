# Recursive JSON storage frontier

Status: PROPOSED storage composition; W182 scalar admission remains unchanged.
Baseline: `48c1be0`. No new Crystal bulk, part or table-reader admission.
W183's finite stock physical discriminator is verified below; it does not
complete the storage-admission DoD.

## Why scalar recursion is not the missing abstraction

The shared descriptor/value visitors already compose nominal JSON through
Array, Tuple, Map, Nullable, Variant, Nested and selected Dynamic values.
W182's finite paired scalar evidence is in
[JSON_NESTED_SCALAR_FRONTIER.md](JSON_NESTED_SCALAR_FRONTIER.md).
An implementation per Cartesian product of types is neither required nor
the intended design.

Persisted recursion needs a child serializer plus its occurrence-specific
state and physical context. Existing Object owners already encode/decode
typed, dynamic and shared lanes, but represent a root Object column:

- `ObjectDocumentPlan` supplies explicit actual Object/Dynamic rosters.
- `ObjectDocumentCodec` requires a nonempty real row group at every mark.
- `ObjectDocumentPhysicalPlan` binds Object lanes to physical stream names.
- `ObjectColumnReader` checks a root-column outer row/mark grid.

Consequently an Array wrapper cannot simply pass flattened JSON elements
to these root APIs. A real outer mark may contain only empty arrays and have
zero JSON elements. Parent mark row counts and child value counts are different
quantities. A root `BinaryJsonRow`/`ObjectDocument` representation adapter alone
does not implement this storage composition.

## Design laws

1. Use one recursive operation per wrapper, not one codec per composite type.
2. A JSON site retains its exact nominal descriptor/caps, explicit actual
   Object/Dynamic rosters and a full structural occurrence address. Equal
   nominal types at different sites do not imply equal actual state.
3. Prefix, data and suffix share a site's state. A structure prefix belongs
   to the nested column/site for the part, not to each array element or row.
4. Keep the physical outer mark grid separate from the number of values
   reaching a child. Array/Map offsets and Variant/Dynamic selections determine
   those child counts; empty child ranges are legal when the parent is real.
5. Physical stream naming must receive the enclosing path and array level.
   Concatenating a root Object filename prefix is not sufficient evidence.
6. Metadata discovery, actual rosters, child values and generated names consume
   one enclosing bounded operation budget. A JSON edge cannot reset it.
7. Reuse the current Object structure/value owners behind a site-aware seam.
   Do not globally relax root mark validation to admit empty child groups.
8. Keep schema admission, serialization profiles and runtime state separate.
   In particular, nested Map serialization-info propagation is not the same
   setting as ObjectStructure/shared-data versions.

Risk for production widening: CAUTION (serialization and mark/state ownership).
Rollback: an isolated atomic feature commit; no source parts or remote changes.
Likeliest failure: conflating outer rows with flattened child occurrences, or
sharing a structure state between two sites with the same nominal type.

## Admitted and rejected surfaces

Existing normalized root Object V3 / one-bucket shared MAP remains separately
qualified. Existing W182 nominal scalar composition remains qualified only
within its own evidence. Generic bulk planners, persisted Object declarations,
borrowed Dynamic and unqualified consumers retain their recursive JSON guards.

Guard-only next physical slice: `Array(JSON(..., t UInt8))` in normalized Wide
parts, with a real all-empty mark, mixed zero/one/multiple child counts and an
empty trailing mark. This is a discriminator and first implementation target,
not a restriction of the overall full-type/MV/projection objective.

No new Compact, bucketed/ADVANCED shared JSON, SKIP/REGEXP, Map version, projection,
MV execution or performance claim follows from this probe.

## Source anchors and runtime distinction

Source-only reference: clean shallow, unbuilt
`ef037e60fc7f5654c8c80eefb8be82e3c56f9a67` at
`/Users/sergey/SrcArchives/clickhouse-2026-10-05-depth1-ef037e60`.

- `SerializationArray.cpp:297-327,352-395`: child prefix/suffix/data use the
  enclosing settings under ArrayElements; the empty-range branch still invokes
  nested serialization.
- `SerializationObject.cpp:712-842`: ObjectStructure prefix state is cached
  using the current full substream path, before typed/dynamic/shared recursion.
- `MergeTreeDataPartWriterWide.cpp:568-585,590-615,864-868`: runtime Object/Dynamic
  settings, prefix and suffix are part of the Wide write context.
- `DataTypeArray.cpp:59-64`, `DataTypeDynamic.cpp:62-67`,
  `DataTypeVariant.cpp:203-220`, `DataTypeObject.cpp:185-194`: type-level Map
  serialization-info propagation is conditional. `MergeTreeSettings.cpp:425-428`
  and `MergeTreeDataWriter.cpp:1004-1015` govern its default and persisted info.

Executed stock is separate:
26.10.1.1201 / `d9bcb5ab007f0f6299f7f973f2642245bab3d028`, executable SHA-256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
The source audit alone does not qualify runtime filenames, marks or Crystal I/O.

## W183 executed physical discriminator

Three stock-written normalized Wide parts each contain eight outer rows,
four real two-row marks and one final zero-row mark. Exact authored schema,
ordered rows and `CHECK TABLE` output match in every profile. Five separately
supervised stock compressor invocations match primitive bytes to authored
literals; no Crystal codec produced those expected bytes.

| Profile | Decoded per-row Array sizes | Decoded `a.t` UInt8 values | `a.t` mark addresses |
|---|---|---|---|
| mixed ArrayJSON | `0,0,0,1,2,1,0,0` | `7,11,13,17` | `(0,0),(0,0),(0,1),(0,4),(0,4)` |
| all-empty ArrayJSON | eight zeroes | empty | five `(0,0)` addresses |
| root JSON control | not applicable | `1,2,3,4,5,6,7,8` | `(0,0),(0,2),(0,4),(0,6),(0,8)` |

Addresses are `(compressed-block offset, decompressed offset)` observations
for these small single-block lanes, not a universal packing rule. The mixed
child counts per real outer mark are `0,1,3,0`, derived from decoded lengths
and checked against typed-lane addresses. Mark row fields remain the outer
`2,2,2,2,0` grid; they must not be read as JSON element counts.

The ArrayJSON roster includes `a.object_structure`, `a.size0`, `a.t`,
`a.object_shared_data.size1`, and escaped shared-path/value lanes. Root JSON
uses shared `size0` instead. The all-empty part retains the structure and
five marks per stream while its typed/shared value files are empty. Structure
and shared-data payloads are inventoried only; they are not decoded by this
probe. Requested table settings are recorded, not an effective-settings audit.
The root control qualifies its own primitive lanes and provides a shared-size
array-level naming comparison. It does not prove Object state independence:
the full-path state law above is source-derived, and a runtime test with two
equal nominal sites and different rosters remains open.

Executed command (use a new empty direct child of `/private/tmp` to repeat):

```sh
env COGNI_RUN_SAFE_MIN_FREE_PCT=50 RUN_SAFE_PASSTHROUGH_STDIO=1 \
  TMPDIR=/private/tmp \
  SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk \
  /Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh \
  /usr/bin/ruby 600 12288 scripts/probe_json_array_storage_w183.rb \
  --evidence-root /private/tmp/crystal-click-json-array-storage-w183.BAXu3S
```

Actual guard exit 0; all eight native processes exit 0 without signal,
timeout or captured I/O error. Local queries use one thread and 512 MiB;
compressor calls use one thread and at most 64 KiB of captured compressed input,
without claiming a query-memory setting. The outer runner uses 600 seconds,
12 GiB and the unchanged 50% system-free-memory preflight (observed 83%).

Root independently reconciles 72 captured native/stream hashes, five decoded
literal payloads, typed/size mark addresses and rebased shared-stream names.
Eight seeded controls reject empty/wrong/malformed marks, duplicate stream
names, cross-profile paths, evidence overwrite, a successful utility returning
wrong bytes, and post-run executable hash drift. These do not mutate native
parts or invoke native processes. Ruby syntax and these checks pass; no Crystal
source changed, so no Crystal regression suite was rerun.

The curated index is [evidence/json-array-storage-w183.json](evidence/json-array-storage-w183.json).
Native summary SHA-256:
`50a3a03f7fda921d62ec66db943ad4bceff66f494c93cbd18b53ce20bea7d47f`.
Root receipt is `/private/tmp/crystal-click-w183-root-checks.UUegmb/receipt.json`
(`4322c1909730848a11bc02e89ecbcd4f07cadd50eba7311c62046f14951cfade`).
Its verifier is `check.rb` in the same directory, SHA-256
`8c1dcb814bcbbeb458ceeb381670076adc86e71188a655cad445781c741e88ad`.

Two failed runner attempts are retained: `PkA7Z3` ran one successful CH query
but exposed Ruby 2.6's missing `filter_map` and a legitimate catalog symlink;
`kWa3P9` ran three successful queries but exposed a nil prefix read on empty
stream files. The final probe fixes those runner errors. They are not evidence
of unsupported ClickHouse types. Scoped hostile verdict: ROBUST for the finite
native layout discriminator and probe guards, not Crystal storage support.

## Execution order and falsifiers

1. Run `scripts/probe_json_array_storage_w183.rb` against a fresh isolated
   evidence directory under the unchanged serial resource guard. Require exact
   authored rows/schema, successful CHECK TABLE, real Wide metadata/stream and
   plain mark observations for mixed/all-empty ArrayJSON and a root JSON control.
2. Use the observed names/grids to specify a site plan and child-count seam.
   Preserve early storage guards until that seam has an actual baseline RED.
3. Implement paired site-aware bulk recursion, then binding/transport and
   complete-part reader/writer integration. Keep owners in separate files.
4. Qualify library-owned parts with stock ATTACH/CHECK and literal full/middle
   reads; independently stock-written parts must reopen through Crystal.
5. Attack zero children, mismatched offsets/counts, truncated/suffixed lanes,
   two equal nominal JSON sites with different actual rosters, caps, shared
   budgets and unsupported layouts. Include part/table consumers, not only a
   scalar re-encode or a role-name plan.

DoD for storage admission: paired complete parts and actual table reads,
relevant DEBUG/RELEASE regressions, preservation of rejected consumers and a
scoped hostile review. The native probe alone cannot satisfy this DoD.

Decay: wrapper paths, Object/Dynamic state ownership, mark interpretation,
serialization settings, runtime pins or consumer admission changes require
refreshing the affected source/probe and paired I/O evidence.
