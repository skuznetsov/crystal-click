# Object Advanced Shared Storage Frontier

Document status: W191 verified metadata prerequisite and capture; W192 paired
exact-Copy payload prerequisite qualified against the retained stock corpus.
W193 paired per-path Compact Data/tape prerequisite is qualified against the
retained stock String/NULL corpus; ordinary recursive arms have unit witnesses.
Persisted ADVANCED/CHUNKED storage is not admitted.
Baseline: `c99c9cf` (W190), clean tree at entry, 2026-10-06.
The full read/write types and MV/projections goal remains open. Performance is
deferred until those capabilities are implemented and qualified.

## Required capability and current boundary

Extend the existing recursive Object storage owners to read and write Object
V3 shared ADVANCED (version 2) and ADVANCED_CHUNKED (version 3) in normalized
Wide parts. Preserve the existing MAP and MAP_WITH_BUCKETS bytes and public
APIs. A stock-to-Crystal reader without the corresponding stock-readable writer
is an intermediate result, not completion of this capability.

Currently admitted storage remains W190's finite MAP/MAP_WITH_BUCKETS profiles;
see [OBJECT_SHARED_BUCKETS_FRONTIER.md](OBJECT_SHARED_BUCKETS_FRONTIER.md).
Versions 2/3 remain rejected by the persisted document owners during this
investigation. Compact parts, automatic roster inference, projection envelope
writing, MV dependency execution and performance claims are not added here.

The stock-authored physical capture now provides a discriminator:
root JSON and Array(JSON), explicit ADVANCED versus ADVANCED_CHUNKED, forced
one-row chunks inside two-row physical marks, and empty shared/child controls.
The capture exposes the actual version, bucket count, stream roster,
structure records and whole-shared copy lanes. Chosen settings alone do not
establish the resulting format. This probe prepares the read/write owners; it
does not redefine the requested final state as a stock-only tool.

## Source and runtime anchors

Source: clean shallow checkout
`/Users/sergey/SrcArchives/clickhouse-2026-10-05-depth1-ef037e60`, revision
`ef037e60fc7f5654c8c80eefb8be82e3c56f9a67`.
`SerializationObjectSharedData.h` describes the per-bucket path/substream
metadata and the separate whole-shared copy lanes. `MergeTreeSettings.cpp`
declares `advanced`, `advanced_chunked` and
`object_shared_data_target_chunk_rows`; the executed probe sets the latter
to one. Exact observed layout facts are recorded below.

Runtime: the separately pinned 26.10.1.1201 executable, build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`, SHA-256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
It is not a build of the source snapshot. Native failures are inconclusive
runtime/probe failures, not evidence that a format is illegal.

## Design laws and strongest failure

- Logical Object occurrences, chunk rows and physical parent mark rows are
  distinct axes. Empty Array children do not remove their physical marks.
- Bucket structures must agree on the chunk-row layout used by shared copy
  decoding. Per-chunk dictionaries cannot be replaced by a part-global roster.
- Whole-document copy lanes and per-path data/metadata are two representations
  of the same shared values. A writer must not populate only the copy and leave
  stock path reads wrong or empty.
- Compressed-file marks are transport coordinates, not logical byte offsets.
  Validate both components against their actual target streams.
- Reuse existing scalar/Dynamic serde behind explicit layout owners rather than
  introduce a serializer for each enclosing schema product.
- All new chunk/path/index/name work inherits the caller's budgets. Do not
  reset budgets per bucket or chunk, and do not interpret logical limits as RSS.
- Zero/middle selections retain metadata and complete mark-grid validation;
  selected data must be reconstructed in the original Object occurrence grid.

Likeliest failure: a whole-document round trip passes while stock's independent
path read consumes inconsistent path/substream marks. The paired writer gate
must query both representations, not just `toJSONString` of the whole Object.

## Execution and stop rules

Risk: CAUTION (persistent serialization); initial capture is non-mutating with
respect to user data and creates only task-local stock tables and artifacts.
Rollback: exact scoped Git commit after the declared gates; retain failed
capture roots rather than overwrite them.

1. Source and existing-owner inventories identify the field sequences and
   affected consumers. Luna owns heavy analysis/implementation; root owns
   guarded serial compilation, native execution and independent reconciliation.
2. Add a bounded stock capture with a clean positive control and a seeded
   mismatched field/roster/row-layout check. Run it in a fresh empty root using
   the existing pinned process supervisor and outer `run_safe.sh` guard.
3. Record actual v2/v3 bytes and decide the reusable ownership seam. Write the
   first RED behavioral specs before any production admission change.
4. Implement reader and writer owners, then affected DEBUG/RELEASE regressions
   and paired stock reads / library ATTACH-CHECK / whole and path readbacks.
5. Run hostile review, independently reconcile evidence, and qualify only the
   executed schema/layout witnesses. The larger goal remains active.

Do not relax a version guard to manufacture a passing probe. Stop and
investigate any pin, process, literal, stream-roster or mark-grid disagreement.
Evidence expires when implementation inputs, source/runtime pins, settings or
fixture profiles change; refresh in a new empty root and preserve old failures.

## W191 prerequisite plan

The next implementation is a reusable single-bucket, single-chunk metadata
owner, not a new serializer for each enclosing Array/Tuple/JSON combination.
`ObjectSharedChunkStructure` and `ObjectSharedChunkStructureCodec` each live in
their own file. A record contains a UInt64-domain row count encoded as VarUInt,
a strictly byte-ordered
unique list of opaque path strings, and three pairs of UInt64 compressed and
decoded transport offsets encoded as fixed little-endian UInt64 values.
The path count and each path length also use VarUInt.
Zero-row/zero-path records and nonzero offsets are
valid metadata; actual target-stream bounds belong to the eventual storage
owner. The record owns detached path bytes. Context-based read/write entry
points inherit one caller budget; complete-blob entry points reject trailing
bytes. No persisted layout guard changes in this prerequisite.

Exact files and checks:

1. `spec/object_shared_chunk_structure_w191_spec.cr`: execute the missing-API
   RED before production edits, then exact literals, truncation/trailing input,
   unsorted/duplicate paths, opaque bytes, count limits, shared-context budgets,
   detached ownership and full-width transport pairs in DEBUG and RELEASE.
2. `scripts/probe_object_shared_advanced_w191.rb`,
   `scripts/object_shared_advanced_layout_w191.rb` and
   `scripts/stock_part_probe_support_w191.rb`:
   `ruby scripts/probe_object_shared_advanced_w191.rb --self-test` must accept a
   clean control and reject seeded row-layout and dictionary-index corruption.
   A fresh-root stock capture must retain its raw process records and immutable
   part inventory, and decode actual structure/copy streams for root/Array v2
   and v3 plus empty-shared and all-empty-child controls.
3. `scripts/validate_object_shared_chunk_structure_w191.cr`: prebuild in DEBUG
   and RELEASE; decode the native structure records and return field values
   plus exactly reencoded bytes. Independently compare both helpers with the
   Ruby decoder and original bytes, not merely their exit codes.
4. Rerun the inherited 81 affected W190 specs plus the new spec in both modes.
   Existing version-2/3 schema/document/physical refusal tests must still pass.
5. `scripts/reconcile_object_shared_advanced_w191.rb` independently extracts
   records from actual decoded streams, authenticates retained process and part
   artifacts, and compares raw bytes/fields with both helper modes. Summary
   fields and a helper exit code alone do not establish stock provenance.

All compiler and native work runs serially under the existing `run_safe.sh`
guard (600 seconds, 12288 MiB tree RSS, at least 50 percent reported system
memory free); native child processes additionally retain their existing
10-second deadline and two-second TERM grace. The commit gate requires actual
terminal exit codes, independent raw-capture reconciliation, and hostile review
of this bounded metadata/probe claim. Full advanced read/write and stock path
readback remain subsequent work, not success inferred from this prerequisite.

## Observed physical facts

The fresh stock capture at
`/private/tmp/crystal-click-w191-native-final.BxiDQd` returned exit 0 with eight
successful profiles and 100 captured native/decompressor invocations. It
contains 64 combined structure records: 44 in profiles with shared paths and
20 in empty controls. Positive profiles use two buckets; empty controls have
one actual bucket despite the two-bucket setting.

Root ADVANCED has four two-row chunks per bucket; CHUNKED has eight one-row
chunks. Mixed Array(JSON) has logical chunk rows `[0,1,3,0]` in ADVANCED and
`[0,1,1,1,1,0]` in CHUNKED, while every physical lane retains parent `.mrk2`
rows `[2,2,2,2,0]`. All-empty Array controls still contain four zero-row,
zero-path records. Empty-root controls contain four two-row or eight one-row
pathless records. Empty logical data is not absence of structure metadata.

Whole-shared Copy-values are an outer binary String containing a scalar
Dynamic envelope; String values inside that envelope have their own length
prefix. The initial capture failed because the Ruby parser omitted the outer
length, not because the stock format was rejected. The failed capture at
`/private/tmp/crystal-click-w191-native.i3WMOB` is retained; the corrected parser
has literal, opaque-byte, truncation and trailing-inner-byte checks.

These are fixture observations, not admission of persisted ADVANCED storage.
Per-path payloads are captured but not semantically decoded here. Full paired
reader/writer ownership and stock whole-object plus independent path readback
remain required.

## Executed prerequisite qualification and continuation

The missing-API RED returned exit 1 before production implementation. The final
focused DEBUG gate passes 10 examples. The inherited 81 affected W190 spec
files plus the new spec pass 503 examples in each DEBUG and RELEASE run, with
zero failures/errors/pending and actual guard exits 0. Production/spec inputs
are unchanged across those final gates. The later selective helper parser and
Ruby evidence-check repairs do not alter production or spec inputs; both final
helper modes are rebuilt from the repaired source.

The two helpers consume the same 64 native records under cumulative read/write
budgets and produce identical field values and exactly reencoded bytes. Root's
separate reconciler derives those records from actual decoded streams, not the
summary's copied record fields. It authenticates the 100 retained invocation
records and their 500 artifacts, matches all 320 physical filename entries to
the actual part directories, checks 248 `.bin`/`.mrk2` size/SHA pairs plus 16
available checksums/serialization hashes and captured metadata literals, and
reconciles 92 compressed frames and 3,362 structure bytes. Of the 64 records,
27 contain paths and 37 are pathless. `primary.idx` and `statistics.packed` are
roster checked, not individually hash-certified here. This is not a general
part-integrity certificate.

Root also runs both helper modes against mismatched manifest rows, nonminimal
VarUInt, no-record and absent-profile inputs: all reject with the expected
nonzero exit and no stdout. A full-UInt64 metadata fixture with unrelated
large JSON hash numbers passes, preserving every coordinate and reencoded
byte. These ten controls produce identical mode-specific bytes/diagnostics.
The Ruby parser/reconciler seeded controls pass, including the 256/257 path
dictionary index-width boundary.

Retained failed routes distinguish harness defects from format defects:

- The first stock parser missed the outer String envelope around shared
  Dynamic values; the failed native capture remains separately available.
- The first helper used `JSON::Any` and failed on an unrelated unsigned hash
  above Int64::MAX. Selective `JSON::PullParser` skips unrelated fields and
  reads relevant numeric fields as UInt64; full-width controls now pass.
- The first reconciler conflated complete physical filenames with the smaller
  stream-file inventory. The corrected check preserves both namespaces and
  verifies the available metadata hashes/literals separately.

Scoped hostile verdict: ROBUST for the metadata-codec prerequisite after
root's executed raw-provenance reconciliation. The same-lineage source review
is correlated support, not an independent rerun. Commands, input identities,
failed routes and digest-indexed temporary artifacts are recorded in
`.landmark/evidence/object-shared-advanced-w191.json`. The repository does not
provide the standard Landmark packet template/graph validator; JSON parsing,
default-deny changed-path checks and actual reference-digest dereferencing are
the local fallback, not proof of command execution by themselves.

Next frontier: reuse the existing Dynamic/BinaryBulk codecs behind explicit
advanced chunk/bucket payload and copy-layout owners. Add reader and writer
together, retain separate physical-parent/logical-child/chunk coordinates and
caller budgets, then qualify stock-authored reads and library-authored
ATTACH/CHECK with whole-object AND independent path readback. Do not widen the
persisted version guard on the strength of this metadata prerequisite alone.

## W192 paired Copy payload plan

Baseline: clean `b6af51c`, 2026-10-06. This is the next production dependency
of the complete advanced layout, not a substitute for per-path payloads or a
relaxation of persisted admission. Reuse scalar envelopes; do not duplicate
their recursive serde for each enclosing schema.

The exact local API consumes one chunk's already decoded bucket structures
and three fully decompressed, exactly bounded Copy slices. A dictionary owner
validates equal logical row counts across buckets, byte-sorted unique paths
within each bucket, unique combined paths and deterministic bucket placement.
Dictionary order is bucket ordinal followed by each bucket's path order, not
global lexical order. Rows remain in their original byte-sorted path order.
The Copy owner uses position-independent UInt64 per-row entry counts, implicit
dictionary-size-dependent UInt8/UInt16/UInt32 indexes, and outer binary Strings
containing the existing scalar Dynamic envelopes. Cumulative Array offsets
and other serialization profiles are not admitted by this API.

An initial source-inventory claim confused reconstructed Array offsets with
physical sizes. Root read the retained stock decompressor output directly:
`invocations/decompress_root_advanced_v2_2b2b60b9885bd841f8fc17c78f094c03.stdout`
has SHA-256 `493c238f320b0c861040b1c683dd4f3ba02617e92db016df26d8bf1d01991a8a`
and UInt64 values `[1,2,1,2,2,1,1,3]`, not cumulative offsets. The source
`SerializationArray.cpp:329-349` selects sizes when
`position_independent_encoding` is true; `ISerialization.h` defaults it to
true. Preserve the contradicted route as an explicit framing falsifier.

New owners each have a separate file:
`object_shared_copy_dictionary.cr`, `object_shared_copy_streams.cr`, and
`object_shared_copy_codec.cr`. The paired exact-slice and caller-budget APIs
reuse `ObjectSharedMapRow`/`ObjectSharedMapEntry` and
`BinaryValueCodec.encode_dynamic_bulk_child`/`decode_dynamic_bulk_child`.
The inherited Dynamic actual-type restrictions remain explicit; this does
not claim arbitrary JSON/QBit/aggregate-state envelopes. Bucket, path, row,
entry, recursive value and wire work all share the caller's budget, including
consecutive chunks. Count and byte lower bounds must precede count-derived
allocations. Zero-child chunks keep their metadata slot, and pathless positive
rows still have zero-valued size records. Physical parent marks are outside
this exact-slice codec, not replaced by logical row counts.

The Copy wire budget charges only its three lanes: already decoded structure
bytes belong to the enclosing owner. Dictionary and repeated per-entry path
bytes are charged as logical element work before copies or count-derived
collections. This prevents tiny Copy bodies from amplifying repeated large
paths without falsely describing the logical budget as an RSS measurement.

Risk is CAUTION (paired persistent payload framing). Rollback is the scoped
atomic Git commit after gates. The strongest local failure is an apparently
valid index sequence bound to the wrong dictionary or using cumulative counts.
The unchanged v2/v3 document/physical refusal is the guard against mistaking a
Copy-only implementation for complete advanced support.

The recursive child codec's error distinction is part of composition:
valid-but-unadmitted actual types retain `UnsupportedFormatError`; malformed
descriptors and broken framing retain `CorruptPartError`. A broad conversion
from unsupported to corrupt failed a root-authored valid-JSON-envelope RED and
was removed. This preserves the child contract rather than changing admission.

Execution and DoD:

1. `spec/object_shared_copy_w192_spec.cr` and root-authored
   `spec/object_shared_copy_w192_adversary_spec.cr`: run the missing-API RED before
   production edits. Then exact stock-derived literals, recursive scalar
   children, dictionary/row disagreement, misplaced/duplicate paths, index
   overflow, truncation/trailing bytes, opaque ownership, zero/empty rows,
   shared budget exhaustion and 256/257 plus 65536/65537 width boundaries.
2. `src/crystal_click.cr` requires the three new owners. Do not edit persisted
   Object admission or existing MAP serde. Both new methods are paired and
   direction checked; they create no fresh budget in compositional calls.
3. `scripts/validate_object_shared_copy_w192.cr` is freshly compiled in DEBUG
   and RELEASE. `scripts/reconcile_object_shared_copy_w192.rb` derives chunks,
   dictionaries and exact Copy slices from authenticated retained W191 raw
   streams, compares logical rows against authored literals, and compares both
   helper reencodings with original bytes. It must detect seeded framing,
   dictionary/index and raw-artifact mutations. Reusing immutable stock input
   is declared; this is not a new full-part ATTACH/CHECK witness.
4. Run the inherited 82 affected W191 specs and both new specs in DEBUG and
   RELEASE under the same serial 600-second/12288-MiB/50-percent-free guard.
   Require actual terminal exit 0, no pending examples, root-authored adversary
   controls, independently checked source/input digests and hostile review.

After this dependency, complete the per-path Data/substream metadata owner and
paired compressed-coordinate transport mapping. Only the combined advanced
reader/writer with stock whole-object AND independent path readback may widen
the persisted version guard. Full type coverage, MV/projections and the final
performance target remain open.

## W192 executed qualification and continuation

The missing-API RED precedes production implementation. A separate
root-authored RED demonstrates that a valid scalar JSON envelope was wrongly
reported as corrupt by the enclosing Copy decoder; removing the broad rescue
restores the child's unsupported-versus-corrupt contract without admitting JSON
actual values. The final 84 affected files pass 524 examples in DEBUG and 524
in RELEASE, with zero failures/errors/pending and actual guard exits 0.
All 903 source/spec files have the same input fingerprint across both gates.
These are affected regressions, not a full repository-suite result.

Both newly built helper modes consume the same 42 combined chunks derived
from the immutable W191 capture. The independently re-derived manifest agrees
with the implementation worker's manifest exactly. Ruby authenticates the
retained process/part/stream evidence, independently parses the outer and inner
String frames, and binds authored literals to fixed probe constants AND the
authenticated captured SQL stdin. It then compares decoded values and exact
reencoded Copy slices with original raw bytes, not just helper agreement.
There are eight profiles, 40 logical rows and 36 entries: 320 size bytes,
36 index bytes and 398 value bytes. The shared read budget includes 3,362
metadata bytes plus 754 Copy bytes; the shared write budget charges only the
754 Copy bytes. Empty child and pathless chunk slots remain in the corpus.
Native actual values in this capture are String. Recursive non-String cases
are unit witnesses, not native qualification of all combinations.

Root's 26 controls pass: nine malformed-input cases in each helper mode,
five poisoned helper-output cases, a real CLI check that `--self-test` cannot
bypass missing compare inputs, substantive positive-report inspection, and
same-length raw-byte substitution at the file-read seam. The last check
executes the actual provenance verifier and rejects the changed stdout hash;
the original capture remains unchanged. No new native capture or full-part
ATTACH/CHECK was performed in W192.

Retained failed routes:

- Crystal helper arguments needed parentheses around `value || raise ...`
  inside another call. This helper-only repair leaves production/spec gates
  unchanged; both final helpers were built afterward.
- The CLI initially treated consumed `ARGV` plus `--self-test` as a self-test-only
  request, returning exit 0 even for a nonexistent DEBUG output. Root observed
  that bypass and fixed dispatch to distinguish the supplied option set. The
  final actual report contains `reconciled_observation_only`, eight profiles,
  42 chunks and raw/authored checks; the same malformed CLI now exits 1 with
  no stdout. Exit 0 alone was never accepted as raw reconciliation evidence.
- Logical UInt64-domain structure row counts are VarUInt on the wire in both
  source and runtime capture. Only transport pairs and Copy sizes use fixed
  little-endian UInt64. Do not infer an encoding difference from API types.

Scoped hostile verdict: ROBUST for the exact-Copy prerequisite and executed
fixtures, not complete advanced storage. Source/runtime pins are still
different revisions; fresh-master binary compatibility is not claimed.
Commands, digests, failures and controls are indexed in
`.landmark/evidence/object-shared-copy-w192.json`. As in W191, packet JSON and
path/digest checks are a curated evidence index, not proof by field presence.
Evidence decays if production/spec/helper/reconciliation inputs, the immutable
capture, pins or fixtures change; rerun the corresponding actual gates.

Continuation: retain the active full paired-types/MV/projections goal. Start
the per-path Data/substream owner from authenticated captured bytes and existing
Dynamic bulk serde; keep physical-parent rows, logical occurrences, chunks,
dictionary state and compressed/decompressed marks distinct. The next decisive
falsifier is a library-written advanced part whose whole Object reads correctly
but whose independent stock path read does not. Do not widen v2/v3 admission
until that paired reader/writer boundary is actually qualified.

## W193 per-path Compact payload contract and plan

Baseline: clean `53f0852`, 2026-10-06. The next dependency owns one path in one
already bounded bucket/chunk. Its paired API consumes the nominal Dynamic type,
explicit actual-type structures, logical rows and the caller's codec budget;
it produces or reads exactly one decompressed Data slice plus ordered
`{name, relative_offset}` substream-getter events. These relative offsets are
not compressed-file marks. Duplicate names are retained in event order;
ClickHouse's eventual name-to-mark lookup is last-wins. Physical parent rows,
chunk selection, file compression and persisted version admission stay outside
this dependency.

The source profile is position-independent, specialized prefixes/suffixes,
Compact Variant discriminators, Dynamic V3 and Object V3 with statistics NONE.
NONE omits the statistics flag itself; it is not PREFIX_EMPTY's zero flag.
The layout owner orders structure, discriminator and recursively selected
child prefix/body/suffix events while reusing existing BinaryDynamic/BinaryBulk
value serde. Sorted logical lane names are not a physical event schedule.
Existing complete Dynamic-structure APIs must retain byte-identical framing.
Any new no-statistics prefix API is explicitly named and does not strip or
inject bytes after encoding with a new budget.

The callback-name profile is not the ordinary physical-file-name profile.
`SerializationObjectSharedData.cpp:393-394,1384-1385` explicitly disables
Variant arm escaping on both sides: `.Array(Int64)` remains literal, not
`.Array%28Int64%29`. `ISerialization.cpp:335-359` still escapes the leading
Tuple field dot together with the field name; `a.b` and `a%2Eb` must remain
distinct `%2Ea%2Eb` and `%2Ea%252Eb` suffixes. Reuse bounded name builders with
these explicit settings; do not change the ordinary physical-plan grammar.
BASIC Map uses an internal Array(Tuple) whose `keys` and `values` are named
TupleElement children (`DataTypeMap.cpp:137-140`), so the same rule yields
`%2Ekeys` and `%2Evalues`, not `.keys` and `.values`. The array level follows
the complete substream path across Dynamic/Variant arms; entering an arm does
not reset it. This contract does not admit bucketed Map serialization.

Read-side plans assembled from decoded structures must validate and charge
the original read-direction budget, preserving unsupported-versus-corrupt
errors. Nested Dynamic sites require explicit actual-type rosters, not an
inference from nominal capacity. Unsupported layouts remain explicit refusals.
No v2/v3 persisted guard changes are permitted from this dependency alone.

Risk: CAUTION (paired serialization and ordered physical events). Rollback is
an exact scoped atomic commit after gates. The strongest local failure is a
successful value round trip with a wrong prefix/event position, causing an
independent path/subcolumn consumer to seek the wrong bytes.

Execution and DoD:

1. Luna owns `src/crystal_click/object_shared_path_*.cr`,
   `spec/object_shared_path_w193_spec.cr`, minimal paired seams in
   `dynamic_structure_codec.cr` and `binary_dynamic_bulk_plan.cr`, and their
   main require lines. Write the missing-API RED before production edits;
   root executes it under the existing serial compiler guard.
2. Root owns this contract, independent adversary checks, guarded serial
   compilation/native execution and reconciliation coordination. Source/raw
   inventory must resolve exact getter names/order and no-statistics bytes.
3. Focused tests cover exact prefixes/events, recursive scalar lanes,
   absent/empty/null values, malformed/trailing bodies, duplicate-name lookup,
   detached ownership, caller-budget exhaustion and explicit nested rosters.
   Preserve ordinary complete-structure and persisted refusal regressions.
4. Rerun the inherited 84 affected files plus new specs in DEBUG and RELEASE
   with actual exit 0 and no pending examples. Fresh helper modes must decode
   authenticated retained stock Data slices, compare values with authored
   inputs and Copy, and reencode exact original bytes and event positions.
   Helper agreement alone is insufficient. Pin implementation/spec inputs.
5. Attack prefix modes, counts, event offsets/names and budget directions with
   independent negative controls. Reconcile raw provenance before recording
   a bounded hostile verdict and evidence index.

Shared-seam consumer inventory: `rg -n 'DynamicStructureCodec\\.|BinaryDynamicBulkPlan\\.(new_with_budget|decode_structure_streams)' src spec scripts --glob '*.cr'`
finds the ordinary bulk plan/codec, Object dynamic/declared/document owners and
physical reader, plus direct structure/plan/statistics/descriptor suites.
Therefore the inherited 84 files are supplemented by
`dynamic_structure_roster_w154_red_spec.cr`,
`binary_dynamic_bulk_plan_w154_spec.cr`,
`binary_dynamic_bulk_plan_w154_adversary_spec.cr`,
`binary_dynamic_statistics_offsets_w157_spec.cr`,
`binary_dynamic_statistics_offsets_w157_adversary_spec.cr`,
`dynamic_descriptor_consumer_guards_w152_spec.cr`,
`binary_nested_w172_guards_spec.cr` and
`binary_variant_value_w147_adversary_spec.cr`. The corresponding gate is
`run_safe.sh /opt/homebrew/bin/crystal 600 12288 spec <affected files>
--single-module --threads 1 --link-flags=-fuse-ld=ld --error-trace`, repeated
with `--release --no-debug`; expected signal is zero failures/errors/pending
and actual exit 0 at identical production/spec inputs.

Budget pivot: an implementation proposal introduced accounting-suppression
flags into shared Bulk encode/decode and discriminator framing, to force the
counter to equal final file bytes. That is not the requested contract and can
remove preallocation guards while normalized lanes are materialized. Keep
those shared owners unchanged instead. Charge existing recursive logical and
normalized/framed work cumulatively, plus enclosing physical slices/copies;
the measured wire-work counter is neither final file size nor RSS. Tight
aggregate-limit tests use actually measured operation work, not an equality
to Data size. LowCardinality accounting is not silently bypassed; layouts
without a sourced event schedule remain explicitly unsupported.

Compressed-coordinate mapping and complete paired physical assembly follow
this exact-slice owner. Only stock-authored reads plus library-authored
ATTACH/CHECK, whole-object AND independent path/subcolumn readback can admit
the combined ADVANCED/CHUNKED implementation. This dependency is not a
replacement for that final discriminator or the larger types/MV/projections
goal. No memory/performance optimization is introduced here.

## W193 executed qualification and continuation

The paired exact-path codec delegates actual value serialization to the existing
recursive Dynamic/Bulk owners. Data/event streams, immutable getter events,
tape cursor, decode result and layout codec each have their own file. A named
no-statistics-prefix seam preserves the complete Dynamic metadata API and its
statistics offsets. The no-statistics plan refuses a statistics-offset lookup
rather than inventing one. The old public three/four-argument structure decode
method remains unchanged, including existing test instrumentation consumers.

The missing-API RED precedes production changes. Independent source-derived
falsifiers exposed incorrect prefix/body interleaving, ArrayElements levels
reset at Dynamic arms, and literal Map `.keys`/`.values` names. The corrected
walk runs all recursive prefixes before bodies, carries the full array level
through arms, and uses escaped TupleElement Map names. The read-side depth
guard runs before nested structure parsing/materialization. These are layout
repairs over shared value serde, not per-schema serializers.

The final 95 affected files pass 585 DEBUG and 585 RELEASE examples, zero
failures/errors/pending, with actual terminal and guard exits 0. All 911
source/spec inputs retain fingerprint
`36a729f3b769ed75593cbf546174e048b89ff156e3cc3d133a94c7bf9f29b422`
before and after both gates and helper/control execution. The focused final
gate passes 20 examples. This is not a full repository-suite claim.

Both fresh helper modes decode and exactly reencode the same 34 per-path Data
records, including NULL values, derived from 42 chunks across eight immutable
W191 profiles. Original Data contributes 1,347 bytes: 14 PLAIN and 20 COMPACT
SharedVariant records. Fourteen paths include NULL and there are sixteen NULL
rows. Ruby independently resolves compressed metadata coordinates to original
decompressed slices and ordered getter events, authenticates retained process
and physical stream evidence, and binds values to the W192/authored fixtures.
Actual raw bytes, decoded values, structure rosters and reencoded events match
both helper modes. This is a retained stock String-actual witness; recursive
ordinary-arm unit cases are not native interoperability certificates.

One read and one write budget span all path records. Measured wire work is
27,904 read bytes and 22,765 write bytes, including recursive/normalized/framed
and physical-copy work, not merely the 1,347 output bytes. These counters are
neither an RSS bound nor a performance result. Accounting-suppression flags
were rejected; shared Bulk/framing owners retain their existing accounting.

All 32 final root controls pass: eleven input mutations in each helper mode,
seven poisoned-output cases, actual missing-helper CLI rejection, substantive
positive-report inspection, and same-length raw-file substitution detected by
the original stdout SHA verifier. The original capture remains unchanged.
No new native capture, full-part ATTACH/CHECK or persisted admission was run.

Retained failed routes and test corrections:

- An optional fifth argument on the public structure decoder broke existing
  instrumented consumers at compile time. A private shared implementation plus
  separately named prefix API preserves the original public arity; the final
  affected gates run after that repair.
- Root initially compared recursive BinaryValue objects by identity. Explicit
  type/shape/value assertions corrected those tests without changing equality.
- Fresh helper compilation found Int32 `JSON::Any#as_i` used in an Int64
  validator and Ruby-style one-argument Hash fetch calls. Helper-only repairs
  use `as_i64` and checked lookups; both final helpers were rebuilt afterward.
- The first 30-control matrix had 28 passes: UInt64::MAX was rejected by the
  helper's JSON Int64 parser before the expected Data-offset check. The final
  matrix separately checks JSON integer overflow and an Int64-domain offset
  beyond Data. This corrects the probe, not production behavior. Failed logs
  and copies are retained separately from the final 32-control root.

Scoped hostile verdict: ROBUST for the declared exact-Data/event prerequisite
and executed fixtures. Commands, source/input digests, failures and controls
are indexed in `.landmark/evidence/object-shared-path-w193.json`. Structural
packet validation is an index check, not execution proof. Evidence decays when
code/spec/helper/reconciler inputs, retained capture, source/runtime pins or
fixture settings change; refresh the affected actual gates.

Continuation: the full paired-types/MV/projections goal remains active, with
performance deferred. Next compose path Data/events, chunk structures and
PathsMarks/Substreams/SubstreamsMarks/PathsSubstreamsMetadata in one
schema-agnostic physical-lane owner. Keep physical-parent rows, chunks, bucket
identity and logical paths distinct. Reuse CompressedMarkWriter framing and
return internal-offset coordinates from that same calculation rather than
duplicate its private physical_position arithmetic; CompressedFrameIndex is
the read-side resolver. The next falsifier places a path/getter at a compressed
frame boundary, including equal-offset callbacks and legal frame-end aliases.
Only the assembled paired reader/writer, stock ATTACH/CHECK and whole-object
AND independent path readbacks can admit persisted versions 2/3. LowCardinality,
Nested, QBit and JSON-as-Dynamic-actual per-path layouts remain explicit guards.
