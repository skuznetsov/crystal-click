# Recursive JSON storage frontier

Status: PROPOSED complete storage composition; W185's dedicated normalized
Array(JSON) part/table path and W184's internal paired occurrence-grid foundation
are VERIFIED within their executed scopes below.
Baseline: `4464ef3`. W182 scalar admission remains unchanged. No new generic
Crystal JSON bulk admission or admission beneath every persisted wrapper.
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
6. Target for complete composition: metadata discovery, actual rosters, child
   values and generated names consume one enclosing bounded operation budget.
   A JSON edge cannot reset it. W185 shares a codec budget for parent/child grid,
   statistics and values, but names/rosters, part metadata and compressed
   transport retain separate bounded contexts. It does not close this full
   cross-domain budget law or establish a process-RSS bound.
7. Reuse the current Object structure/value owners behind a site-aware seam.
   Do not globally relax root mark validation to admit empty child groups.
8. Keep schema admission, serialization profiles and runtime state separate.
   In particular, nested Map serialization-info propagation is not the same
   setting as ObjectStructure/shared-data versions.

## W185 implementation seal (VERIFIED within the finite scope below)

Baseline: clean `3ecec3f`. This vertical step composes `Array(JSON)` in
normalized hashed Wide/LZ4 parts with plain adaptive marks, using the existing
Object V3 / one-bucket shared MAP owner. This is an execution step toward the
full type/MV/projection objective, not a replacement objective or a claim that
every JSON layout is supported. Performance remains deferred.

The inner `ObjectDocumentSchema` retains its exact caps and supported typed
field grammar. Existing root codecs, supported typed fields and strict root
nonempty-mark validation must remain intact. Do not add a separate serializer
for each Cartesian product or infer an actual dynamic roster from nominal caps.

Public composition boundary:

- `ArrayObjectColumnWriter.encode`: granules -> parent rows -> Object documents;
  an owned file roster composes outer sizes with the existing child lanes.
- `ArrayObjectColumnReader.open`: exact inner schema plus literal Array wrapper;
  `read_marks` restores one document array per parent row, including empty rows.
- `WidePartWriter.write_uint64_array_object_pair`: full checksummed staged part
  publication, canonical `Array(inner JSON)` metadata and staged reopen.
- Typed table batches expose `array_object_documents_for(column)`; no scalar-reader
  fall-through, projection admission or implicit flattening.

Risk: CAUTION (serialization and public table materialization). Rollback:
one isolated atomic feature commit from the clean baseline; retained stock
parts are read-only and every generated part/store is task-owned temporary data.
Likeliest failure: child counts have the correct sum but are distributed across
the wrong marks/parent rows. Guard: derive the complete child schedule from
checked serialized sizes before value callbacks; attack same-total redistribution,
zero child marks, nonzero origins, truncation, suffixes, caps and path/state collisions.

Execution order / ownership:

1. Root observes an existing-public-API behavioral refusal on a stock-written
   W183 ArrayJSON part before production edits. A probe compilation error is
   not the behavioral RED.
2. Core owners thread site/array level and checked occurrence coordinates through
   existing Object state, statistics, physical plan and reader/writer composition.
3. Part publisher and table adapter consume the composed column rather than
   duplicating its serializers; new owners have their own files.
4. Independent authored row literals drive paired stock/library whole-part tests.

DoD commands: resource-bounded `crystal spec` on W185 core/public/integration
specs plus affected root Object/bulk/table regressions, in DEBUG and RELEASE;
resource-bounded builds of the W185 Crystal oracle helper in both modes;
`ruby scripts/check_array_json_parts_w185.rb` with the pinned stock executable,
built helper and an empty task-owned `/private/tmp` evidence directory. Expected:
all selected specs pass, stock-written mixed/all-empty parts reopen through
Crystal, library-owned parts pass stock ATTACH/CHECK and exact schema/full/middle
reads, and public table batches preserve per-parent arrays. A nonempty shared
MAP witness must prove the nested `size1` path, not only empty file inventories.
The native gate must record actual exit/signal/timeout status under the existing
resource bounds. Root performs diff review and hostile checks before admission.

Rejected surface remains: other JSON physical layouts, Compact parts, compressed
marks, generic persisted JSON under every wrapper, unqualified projections and
MV execution. The existing root supported grammar is not narrowed to make the
first finite native witness easier. Unexecuted or partial gates leave W185 open.

## W185 executed scope and continuation

Root executes the same 46 selected specs in six serial cohorts per mode:
296 DEBUG and 296 RELEASE examples, zero failures/errors/pending, all twelve
actual child/guard exits 0. The nine new examples cover public publication and
typed batches, full/middle/zero windows, all-empty child groups, unchanged
overwrite targets, exact schema caps, wrapper depth, Unicode type labels,
rebased typed/shared names, retained LowCardinality dictionary state and two
separately bound runtime Dynamic paths. A same-total `.size0` redistribution
with refreshed checksums is rejected before a callback for a late selected
mark; this is not whole-scan atomic validation of every inner payload.

Both helper modes consume newly stock-written mixed/all-empty ArrayJSON parts
and a root JSON control. Mixed child counts are `1,0,2,0` while every stream's
physical mark rows remain `2,2,2,2,0`. Nonempty shared String values prove
`a.object_shared_data.size1`, not merely an empty filename inventory. Each
mode writes its own complete library part; pinned stock ATTACH/CHECK, exact
schema, full rows and a middle PK range match independently authored literals.
All six recorded native/helper processes exit 0 without signal, timeout or
capture error. Root reconciles 134 captured/runtime/stream hashes and compares
actual helper values plus all 22 library files byte-for-byte between modes.
This is a finite stock compatibility witness, not every typed/runtime product.

The final 1,053 Crystal/Ruby inputs have aggregate SHA-256
`4040dc35c5455f83d201fc426dba29a0df8969d506421f1803d1aa3c8bb0efce`
(sorted relative-path/SHA-256 pairs, JSON encoding). The 600-second/12-GiB
guard and 50% free-memory preflight are unchanged; heavy jobs run serially
with one compiler thread. The new example builds and reads all eight stock
rows with the correct per-parent child counts. Formatter, Ruby syntax and
diff-whitespace checks pass. No full-repository suite or benchmark was run.

The behavioral baseline compiled and refused the stock ArrayJSON through the
old typed table path. Retained failed attempts include an invalid initial probe,
Crystal compile/test errors during integration, a Ruby 2.6 `filter_map` runner
error and a real root-reader error-precedence regression caused by metadata
extraction. The latter is fixed by validating the source declaration before
parsing the substream roster; the old W129 assertion is unchanged. These failed
runs are not counted as green. Final gates were repeated after formatting.

Architecture: separate Array reader/writer/files, part metadata/publisher and
table adapter owners compose existing Object serializers. The shared
`ObjectColumnPartMetadata` parser is extracted without changing root admission.
This does not complete the larger table-facade decomposition.

Read/materialization limits count logical work and containers, not peak RSS,
transient decoder workspace or caller retention. A selected read still checks
the complete parent-size schedule and may hit whole-part logical caps. The
table adapter uses its default schema caps; this is not an unbounded lazy
reader. Parts must be immutable throughout selection and reading.

Scoped hostile verdict: ROBUST for this normalized BASIC ArrayJSON slice,
selected regression guards and finite paired stock witnesses. Luna's read-only
review is correlated same-lineage evidence; root's executed native oracle and
literal/hash reconciliation provide the external discriminator.
Curated evidence: [json-array-parts-w185.json](evidence/json-array-parts-w185.json).
Usage: [read_array_json_w185.cr](../examples/read_array_json_w185.cr).

Next frontier: general persisted site/state/profile composition beneath the
remaining wrappers; nested JSON physical layouts, full cross-domain accounting,
Compact/compressed marks, additional JSON shared-data/path semantics and broader
MV/projection compatibility remain open. Performance is deferred. Refresh the
affected gates after codec, naming, metadata, state/grid or runtime-profile
changes; deleting retained temporary evidence also invalidates its file links.

Risk for future production widening: CAUTION (serialization and mark/state ownership).
Rollback: an isolated atomic feature commit; no source parts or remote changes.
Likeliest failure: conflating outer rows with flattened child occurrences, or
sharing a structure state between two sites with the same nominal type.

## Admitted and rejected surfaces

Existing normalized root Object V3 / one-bucket shared MAP remains separately
qualified. Existing W182 nominal scalar composition remains qualified only
within its own evidence. Generic bulk planners, persisted Object declarations,
borrowed Dynamic and unqualified consumers retain their recursive JSON guards.

W185 admits the dedicated canonical `Array(JSON(...))` typed column path in
normalized hashed Wide/LZ4 parts with plain adaptive marks, Object V3,
one-bucket shared MAP, BASIC child Dynamic mode and the existing supported
inner Object grammar. Its finite stock witness uses typed `t UInt8` and shared
String values; it does not restrict the overall full-type/MV/projection
objective or qualify every recursive product.

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

### W184 paired occurrence-grid foundation (2026-10-06)

The implemented foundation separates physical outer rows from logical child
occurrences in one immutable `StorageOccurrenceGrid` owner. Its complete real
mark grid has positive Int32 physical row counts and nonnegative Int32 child
counts; the terminal record is implicit. A child count may exceed its physical
row count (Array fan-out). It is not a nominal type descriptor or a complete
structural site/state plan, and counts supplied by a caller do not prove their
derivation from Array offsets or Variant selections.

Explicit borrowed-budget child entry points reuse Object, Dynamic and
discriminator owners. They validate the complete grid even for an empty
selected window, admit zero child groups only through this explicit context,
and retain the existing root API's nonempty-real-mark behavior. Child
discriminators are BASIC-only for this step: zero children emit no body bytes,
but their mode prefix and all mark coordinates remain present. COMPACT child
composition stays refused; root BASIC/COMPACT behavior stays unchanged.

The paired physical lane seam validates discriminator rows against child
counts while emitting adaptive mark row fields from positive physical counts.
Repeated offsets are legal for zero child ranges. A mismatch, a nonempty body
for zero BASIC children, an invalid terminal, or a backward offset is rejected.
This seam does not admit root-named Object lanes as ArrayJSON filenames.
Ordinary bulk lanes must come from the codec's checked row groups. Their
generic byte offsets alone cannot prove a type-specific number of values in
each range; this seam is not an arbitrary fabricated-payload validator.

Implementation ownership: `src/crystal_click/storage_occurrence_grid.cr`,
the explicit child entry points in `object_document_codec.cr`,
`dynamic_value_codec.cr` and `dynamic_discriminator_codec.cr`, the lane seam in
`object_document_column_lane.cr`, and registration in `src/crystal_click.cr`.
Focused tests live in `spec/storage_occurrence_grid_w184_spec.cr` and
`spec/object_child_occurrences_w184_spec.cr`. Existing part/table/schema guards
are not widened. Rollback is one atomic local feature commit.

First behavioral falsifier: run the stock-observed `0,1,3,0` child grid through
the pre-existing root owner on baseline `4464ef3`; it must expose the current
nonempty-group refusal rather than a missing-method compilation error. The
permanent child tests must then admit that grid through the explicit new seam
while the original root rejection tests still pass.

Root executed that baseline discriminator before production edits. The existing
UInt8 bulk codec emits authored bytes `7,11,13,17` and offsets `0,0,1,4,4` for
the same groups; the root Object owner then raises
`Object document real marks must contain at least one row`. Actual guard/child
exit is 1 in
`/private/tmp/crystal-click-w184-occurrences.i3E4Ar/baseline-red3.log`.
The root API is supposed to retain this refusal after the child seam is added.
The two earlier attempts failed at probe authoring (absolute Crystal require,
then private `BinaryValue.new`), not at the behavioral boundary; their logs
are retained and do not count as the RED signal.

Foundation DoD: actual guarded DEBUG and RELEASE execution of the two new
specs together with W121 discriminator/budget, W122 Dynamic/adversary, W123
Object/root/adversary and W127 column/lane regressions. Require exact authored
typed/discriminator bytes and coordinates, full/nonzero-origin/empty windows,
all-empty children, detached grids, shared budget exhaustion, mismatches and
malformed lane guards. Hostile review must distinguish this internal paired
foundation from generic recursive JSON part/table admission. Physical tests
must reopen compressed lanes with the existing reader; in-memory round trips
alone do not close this foundation DoD.

The pinned source corroborates the finite BASIC rule:
`SerializationVariant.cpp:199-223,314-345` writes the mode prefix, then returns
from a zero-size child bulk range before emitting any discriminator body.
This is source corroboration, not a new executed stock Dynamic witness.

Root executed 26 selected specs in three disjoint serial cohorts per mode:
foundation 64, physical 52 and composition 65 examples. All 181 DEBUG and 181
RELEASE examples pass with zero failures/errors/pending and six actual
child/guard exits 0. Runs use Crystal 1.21.0, the unchanged 600-second/12-GiB
guard and >=50% free-memory preflight (83% observed), isolated caches,
`--single-module --threads 1 --link-flags=-fuse-ld=ld --error-trace`, and
`--release --no-debug` only in RELEASE. No native runtime is executed in W184.

The tests reopen both mixed and all-empty compressed typed/discriminator file
pairs, inspect complete physical grids and check literal bytes/offsets. They
also reject equal-total redistributed counts, malformed terminals and child
COMPACT mode, preserve the root refusal, observe one budget identity across
Object -> Dynamic -> discriminator, and prove a low transport budget rejects
before the Variant prefix adapter is called (with a positive control).
Root's separate authored probe checks NULL versus empty groups, a nonzero-origin
window, an empty-selection mismatch, literal discriminator bytes and manually
decoded `.mrk2` row fields `2,2,2,2,0`, then reopens the compressed files.

After formatter normalization of one conditional's indentation, root repeats
all six final cohorts and the separate authored probe. One complete immutable
manifest contains 847 source/spec files and 1,192 fixture files, with no excluded
child spec. It matches after every final cohort and the final probe; all
production inputs are identical across these final gates. Earlier successful
runs and their manifests remain historical evidence, not extra final examples.
The format check passes for all eight changed/new code and spec files.
Two foundation attempts failed at test-authoring compilation only
(module/class observer declaration, then nonexistent `File.binwrite`); neither
counts as behavioral evidence. Their logs remain alongside the successful gates.
Scoped hostile verdict: ROBUST for this internal BASIC foundation. Luna's
same-lineage static review is correlated; root's actual executions and separate
literal/raw-mark probe supply behavioral checks. This is not the complete
repository suite, stock whole-part interoperability or performance evidence.
Exact roster, commands, hashes, failed attempts and scope:
[json-child-occurrences-w184.json](evidence/json-child-occurrences-w184.json).

Continuation:

1. Derive child grids from checked Array offsets/Variant selections instead
   of trusting caller-supplied counts; bind each full structural site to its
   nominal caps, actual rosters, state and serialization profile.
2. Add site-aware names/array levels, metadata discovery and binding. Adapt
   whole-column statistics, whose root nonempty-grid rule is still intact.
3. Integrate paired complete-part reader/writer and table consumers while
   retaining unqualified early storage guards. Keep owners in separate files.
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
