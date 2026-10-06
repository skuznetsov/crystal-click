# Object shared-path LowCardinality frontier (W196)

Status: VERIFIED within the finite four-profile native scope below. The LC
prefix/body tape adapter and explicit additional-keys-only storage policy are
implemented; standalone bulk encoding retains its part-global default.
Baseline: `c8ba1c9953de58471c685b15a4624116190f0989`.
Risk: CAUTION (recursive physical serialization and caller-owned accounting).
Rollback: the baseline and one scoped feature commit; no push authorized.

## Qualified checkpoint (2026-10-06)

The same 117 affected spec files pass 772 examples in both DEBUG and RELEASE,
zero failures/errors/pending, with actual guarded exits 0. The 941-file
source/spec identity is unchanged across those final gates, fresh helper
builds and the two fresh native runs:
`a7b506e1ab71ac728948e278b7206e585dba3aa59a4a818aedd694adaa324536`.
The additional-policy tests cover nullable NULL/default slots, ID width
boundaries, repeated dictionaries across nonempty marks, empty child marks,
exact cumulative wire limits and a second encode with a spent caller budget.

Fresh DEBUG and RELEASE runs independently qualify four root-JSON profiles:
ADVANCED v2/ADVANCED_CHUNKED v3, each with String version 0/1. The fixed stored
actual paths are `p = LowCardinality(String)` and
`a = Array(LowCardinality(UInt8))`; eight rows include missing paths, empty
strings/arrays, default values and two buckets. Each mode ATTACH/CHECKs all
eight stock/library parts, compares 64 full and 32 middle whole-Object rows,
authenticates zero windows, and compares 96 independently selected direct-path
result rows across full/middle windows. Native direct queries do not request
the whole Object and cannot qualify Data by reading the Copy cache alone.

Independent root reconciliation rejects 11 mutations of the real helper
observations in each mode, including policy flags, dictionary values/IDs,
actual-arm bytes, callback order and omitted pathless chunks. Raw argv,
stdin/stdout/stderr, process exits and runtime/helper hashes are authenticated;
a same-length stdout substitution is rejected. Producer summary enrichment
is checked separately from raw process records. All 168 generated files are
byte-identical between modes; normalized helper observations also match.

Scoped hostile-review verdict: ROBUST. Same-lineage static review is correlated
and does not replace these root-executed gates. Candidate scalar-key copying
before its cumulative node/element charge is bounded by a prior complete
key-byte census; this is a transient-accounting caveat, not an RSS guarantee.
No all-types, arbitrary dictionary schedule, insertion/merge policy, Compact
whole-part, MV/projection or performance claim follows.

Evidence roots:
`/private/tmp/crystal-click-w196-policy-native-debug.jIQbji` and
`/private/tmp/crystal-click-w196-policy-native-release.dFagst`.
The curated commands, hashes, refuted route and refresh policy are indexed in
`.landmark/evidence/object-shared-low-cardinality-w196.json`.

Next falsifier: a stock Nested/QBit/JSON-as-Dynamic-actual path with exact stored
roster and callback schedule, followed by a paired writer and separate native
whole-Object/direct-path readback. Reuse child codecs and qualify wrapper
contracts; do not add a serializer for each recursive product.

## Historical checkpoints (not the current admission boundary)

The initial independently authored Array(LC(UInt8)) prefix witness failed
with the existing unsupported-substreams error before the adapter and passed
afterward. At the unchanged candidate hashes, the prior 115 affected spec
files pass 762 examples in each of DEBUG and RELEASE, with zero failures,
errors or pending examples and actual guarded exits 0. A freshly rebuilt
W195 DEBUG helper also passes the existing eight-profile complete-part native
regression. These are regression/prefix witnesses, not W196 native admission.

The corrected six-example W196 focused suite passes in DEBUG and RELEASE,
zero failures/errors/pending and actual guarded exits 0. It includes an
independent additional-only literal, zero-row and empty Array-LC callbacks,
malformed version/ID/event controls, sibling Nullable/Tuple/Map LC sites with
matching String profiles, explicit wrapper identity and cumulative budgets.
Earlier failed runs exposed test-literal/value-tree mistakes, not adapter
changes; production hashes stayed unchanged through these gates.

The final combined 117-file affected suite passes 768 examples in both DEBUG
and RELEASE, with zero failures/errors/pending and actual guarded exits 0.
The production and focused-spec hashes remained unchanged between those runs.

A freshly built read-only inspector decodes the retained stock four-row,
two-mark Wide ADVANCED-v2 witness. External root reconciliation authenticates
the authored RowBinary input and retained native stdin/stdout/stderr/argv,
then requires the exact four ordinary path rosters: `p = LowCardinality(String)`
and `a = Array(LowCardinality(UInt8))`. It compares literal typed values,
complete callback order, UInt64 LC version 1, empty `.dict` callbacks,
additional-only UInt8-ID headers and empty SharedVariant payloads. An executed
forged-roster control is rejected; the unchanged positive rerun passes.
This establishes a finite stock read discriminator, not library-global-dictionary
native acceptance, whole-Copy/path agreement, CHUNKED-v3 or all recursive
products. Those paired full-part gates remain pending. Source and native pins
below remain distinct; no full-goal completion is claimed.

The frozen paired helper builds successfully in both DEBUG and RELEASE
(actual guarded exits 0). Its retained four-row inspection mode emits
byte-identical JSON in both modes; independent root reconciliation accepts
the exact typed values, additional-only LC records and callback coordinates,
and rejects a forged stored arm roster. Paired eight-row part generation and
native GLOBAL-dictionary acceptance are still pending. The String0/String1
LC fixtures qualify accepted metadata profiles, not ordinary String-profile
propagation: LC dictionary strings have their own scalar framing. The separate
W195 ordinary-String regression remains the propagation discriminator.

A separate pinned native file-import query now establishes the finite direct
function/result framing discriminator. `dynamicElement(j.p,
'LowCardinality(String)')` returns `LowCardinality(Nullable(String))`:
`red`, absent, empty and `blue` serialize to `0003726564`, `01`, `0000` and
`0004626C7565`. The Array-LC result retains its Array descriptor; absent and
present-empty both have RowBinary `00`, while `dynamicType` distinguishes them.
Root independently authenticates the raw invocation, input and binary pins,
compares all four rows to literals, and rejects a substituted value. The native
process and positive reconciliation exit 0; the seeded-value control exits 1.
This is in-memory function framing only, not persisted Data-stream admission.

Hostile review found that path records alone could not prove the CHUNKED
schedule for rows with no paths. The paired helper now reports every decoded
bucket/parent/chunk, including pathless chunks, with row counts and ordered path
names. Native paired reconciliation must require that full schedule rather
than infer it from the visible path records or logical empty rows.

The first fresh eight-row paired checkpoint created and CHECKed all four stock
profiles, then passed their whole-object full/middle/zero reads and separate
full direct-path literal checks. It stopped in the Crystal generation helper:
the write-side Copy encoder received a default read-direction transport budget.
This is a verification-helper failure, not native rejection of a library part.
The helper now uses one shared `CompressedStreamBudget.write_default` for Copy
and both bucket encodes; production adapter hashes are unchanged. Final paired
native admission still requires a fresh run after that correction.

Hostile review also found verifier-only gaps: direct-path middle/zero windows
were not queried, zero-query boundary markers were not authenticated, and the
helper executable had no before/after hash binding. These checks must be added
before the paired checkpoint can support its declared window/provenance scope.

The corrected fresh paired DEBUG checkpoint at
`/private/tmp/crystal-click-w196-qualified-debug.TTa9JW` passes stock creation,
all eight ATTACH/CHECK results, and whole-Object full/middle/zero reads, but
the separate native `j.p` read of `library_v2_string0` exits 117 with
`No additional keys found`. This rejects the current concatenation of a
global dictionary body before its index record. CHECK and Copy readback did
not exercise the incompatible Data representation. No W196 admission follows
from the preceding unit or whole-Object gates.

Source inspection separates the cause: Object shared-path writing sets
`low_cardinality_max_dictionary_size = 0`, and its Compact getters alias the
dictionary and index callbacks to one sequential Data buffer. LC writes index
flags before dictionary keys; independently concatenating standalone global
dictionary/index lanes therefore changes that order. The next bounded move is
an explicit additional-keys-only write policy in the existing LC storage
owner, propagated through recursive bulk encoding only for Object paths.
Standalone encoding keeps its current global policy and budgets. Scalar key
serialization, the occurrence walker and decoding remain shared. A runtime
RED must assert an empty dictionary body and an inline additional-key record
before the production policy is changed.

## Boundary and purpose

The full objective remains paired ClickHouse type coverage, MV/projection
support, then measured memory/performance work. This transition connects the
existing recursive LC bulk owner to Object shared-path physical callbacks; it
does not introduce serializers for a Cartesian product of container types.

Implemented composition contract: LC sites under legal ordinary actual arms of a
supplied Dynamic V3 roster in an ADVANCED/ADVANCED_CHUNKED Object path. Reuse
the existing eligible LC child grammar, occurrence schedule, dictionary/index
validation and logical value reconstruction. Preserve recursive Array, Tuple,
Map and supported Nullable ancestor semantics and both existing String
profiles. A supplied roster is stored state, not insertion-policy emulation.

The ordinary Object dynamic-path facade guard, standalone legacy Dynamic
codec guards, recursive Nested/QBit/JSON actual-arm guards, Compact whole-part
publication, insertion/merge roster policy, MV/projections and performance
claims remain outside this transition. Do not remove them to make a test pass.

## Physical laws and strongest failure

1. The prefix pass owns a distinct `.dict_prefix` callback containing the
   UInt64 little-endian dictionary version. It precedes every body callback.
   The body calls `.dict`, then the indexes basename, even when no bytes are
   written. Do not confuse the physical prefix event with the dictionary body.
2. One LC occurrence owns one independent state. The tape adapter slices and
   reconstructs the existing dictionary lane; it never implements a second
   key/index grammar. Its dictionary grid starts after the eight-byte prefix.
3. Stock shared-path writing uses additional keys in the indexes lane with
   dictionary-size zero. Object paths must select that policy: the native
   direct-path falsifier rejects concatenated standalone global-dictionary
   lanes. An explicit storage write policy must preserve standalone global
   bytes and accounting while sharing the scalar grammar. Decoder tests must
   retain independently authored additional-only bytes.
4. Missing, duplicate, reordered, oversized and truncated prefix/body events
   must fail before an invalid dictionary can reach value reconstruction.
   Zero-byte callbacks, empty Arrays, unused arms and NULL rows are distinct.
5. Prefix retention, recombination, grids, names and values share the caller's
   budget. Check count-derived allocation bounds before allocating; no fresh
   child/site budget and no dictionary-internal ordinary physical lanes.

Likeliest false positive: scalar LC bytes survive a SharedVariant envelope,
but the probe never exercises an ordinary LC bulk arm. The native discriminator
must inspect the stored Dynamic roster and `.dict_prefix`/`.dict`/indexes
callbacks, not only `dynamicType`, query output or a self-roundtrip.
Native path queries must be separate SELECTs that do not request the whole
Object or whole-Object functions: shared deserialization can otherwise obtain
the path from the Copy cache without exercising the bucket Data lanes.

## Execution and Definition of Done

1. Write and execute a behavioral RED for independently authored LC path
   bytes/events through `ObjectSharedPathCodec`; leave production unchanged
   until the observed failure identifies the current missing boundary.
2. Connect prefix/body LC roles in `object_shared_path_codec.cr` and
   `object_shared_path_tape_reader.cr`, adding a separate helper file only if
   ownership becomes clearer. Do not duplicate the storage codec.
3. Qualify stock RowBinary JSON ingestion preserving LC actual descriptors:
   `JSON(max_dynamic_paths=0, max_dynamic_types=1)` forces shared-path overflow
   without forcing the flattened Dynamic value into SharedVariant. Inspect
   complete stock Wide ADVANCED v2/CHUNKED v3 parts and native readback of
   independently authored library parts. A failed native constructor requires
   a new discriminator, not qualification by scalar CAST alone.
4. Execute focused positive/negative specs, relevant recursive LC/Dynamic/
   Object regression suites in DEBUG and RELEASE, fresh helper builds and
   native part checks under the serial resource guard. Expected signals:
   zero failures/errors/pending; pinned runtime process exit zero; exact
   typed values, callback coordinates, full/middle/zero-window results and
   checksum/mark validation. Capture whole-Object and direct-only path queries
   separately. Record commands and actual source hashes.
5. Attack the result with malformed prefix/version/order/index coordinates,
   source additional-only keys, and a native stored-roster sensitivity control.
   Update this frontier and project status only to the observed scope, then
   create one exact-path atomic local commit. No full-goal completion claim.

## Source anchors and consumers

Unbuilt source: `ef037e60fc7f5654c8c80eefb8be82e3c56f9a67`.
Runtime oracle: 26.10.1.1201, build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`; it is not that source build.
`SerializationLowCardinality.cpp:271-289,534-626` owns prefix/body order;
`SerializationObjectSharedData.cpp:375-420` configures the path profile;
`SerializationObject.cpp:1333-1410` and
`SerializationObjectHelpers.cpp:18-72` support binary-preserving shared-path
injection. Compatibility evidence decays when these source/runtime pins or
the library adapter/storage owner change.

Consumer inventory: `rg -n 'ObjectSharedPathCodec|ObjectSharedPathTapeReader|
ObjectDocumentPhysicalPlan' src/crystal_click spec scripts --glob '*.cr'`.
Direct path consumers are `ObjectSharedAdvancedChunkCodec` and W193 validators;
chunk consumers include physical bucket/document codecs and public Object/
recursive part readers/writers. Existing W193/W195 tests and native fixtures
are required regression checks. The separate physical-plan facade guard is
not an incidental consumer to widen without its own behavior witness.
