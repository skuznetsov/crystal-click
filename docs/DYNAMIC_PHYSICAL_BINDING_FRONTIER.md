# Generic Dynamic physical binding frontier (W156)

Status: VERIFIED within the declared W156 scope below.
Baseline: `ebe1f8c31b65b3d59f51cfac917314470228cf95`.
This prerequisite advances the type-compatibility goal; it does not close the
remaining complete-part, declared Object Dynamic, MV/projection, architecture
or later performance work.

## Boundary and reason

W155 pairs occurrence-specific Dynamic V3 structures, normalized data lanes
and K+1 grids. Its stock qualifier manually binds physical filenames. The
ordinary `BinaryBulkPhysicalPlan` still rejects `contains_dynamic?`, which is
correct for callers that supply no stored occurrence roster. W156 adds a
separate explicit owner, not an implicit relaxation of those callers.

Risk: CAUTION (persistent-format mapping). Rollback: one atomic local commit,
with exact relevant paths; no changes to existing default consumers or remote
history. The strongest failure is a plausible but wrong arm/site binding that
round-trips internally while reading the wrong stock bytes. Literal stock
names, rosters, values and a valid changed-value control must discriminate it.

## Admitted surface

- `BinaryDynamicBulkPhysicalPlan` accepts an already validated
  `BinaryDynamicBulkPlan` and a raw column name, or a separately validated
  escaped prefix. Actual stored rosters, not nominal caps, determine arms.
- Separate detached data and structure role/name maps, a combined map, per-data
  role prefix ownership, and whole-basename hashing for `.bin` / `.mrk2` names.
  Structure files have no normalized value-grid interpretation.
- Wide / Dynamic V3 / BASIC Variant, default LC stop-sites, BASIC Map and the
  two existing String profiles. Static Variant and actual Dynamic arms recurse
  through admitted containers without resetting Array nesting levels.
- Ordinary String and implicit `SharedVariant` String have distinct physical
  components. Missing, zero-type and unused occurrences are not inferred away.
- One shared physical-name context aggregates descriptor nodes, metadata/
  child/roster elements, and conservative retained role/name plus SQL rendering
  bytes across contributors before materialization. Each binder has one local
  formatter budget, not one fresh budget per arm; formatter node visits are
  capped locally, not tallied as a cross-contributor SQL-visit counter.
  Temporary traversal paths are individually byte-preflighted and their
  count/depth is bounded, but their allocation bytes are not summed against
  `max_bytes`. These are declared logical-work units, not total transient-byte
  or allocator/RSS guarantees, and are separate from the codec operation that
  prepared the supplied plan.
- Collision refusal covers this binder's combined data/structure maps. The
  shared context aggregates resource counters, not a global name registry;
  a later composing storage owner must reconcile names across contributors.

## Rejected / guard-only / non-goals

No change to `BinaryBulkPhysicalPlan`'s no-roster Dynamic veto, legacy generic
bulk facades, cached/borrowed admission, declared Object Dynamic, public whole-
part writer/reader, COMPACT serialization or Compact parts. No inferred
insertion promotion or merge policy; no certification of supplied statistics.
No performance work. Existing physical prefix adapter is a reusable mechanism,
not positive Dynamic qualification by name similarity alone.

## Source law and identities

Reference: fresh unbuilt shallow ClickHouse source
`b94acbe318f8459ac88b35647f4e2293d8e225db` in
`/Users/sergey/SrcArchives/clickhouse-2026-10-04-depth1-b94acbe3`.
Separately pinned stock runtime: 26.10.1.1201, build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`, executable SHA-256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
No source-to-runtime build lineage is asserted.

`src/DataTypes/Serializations/ISerialization.cpp:309-370` defines the filename
walk; `SerializationDynamic.cpp:323-327` enters the filename-transparent
DynamicData path before the underlying Variant state prefix. The
DynamicStructure path contributes `.dynamic_structure`; DynamicData is
filename-transparent. BASIC discriminator contributes `.variant_discr` and an
eight-byte zero mode header; arm names use structural `.` plus escaped SQL
component, including literal `SharedVariant`. Tuple field separators are
escaped `%2E`, unlike Variant's structural dot. Only ArrayElements increases
the Array nesting level. LC dictionary version-one prefix is retained, not
stripped/replayed. Source anchors and the finite executable qualification below
are separate evidence, not a source-to-runtime build attestation.

`SerializationLowCardinality.cpp:79-99,271-313` and
`DataTypeLowCardinality.cpp:158` distinguish default dictionary-prefix
ownership from specialized-prefix layouts; LC dictionary inner String uses
its default serializer, not the enclosing String version.
`DataTypeDynamic.cpp:61-66`, `SerializationDynamic.cpp:124-135,323`,
`ColumnDynamic.cpp:70-76` and `IDataType.cpp:432-439` establish that the custom-
named SharedVariant String inherits propagated String settings. Its size lane
is therefore `.SharedVariant.size` under WITH_SIZE_STREAM, distinct from
`.String.size`. This source-backed name law is not runtime qualification of
every product. A zero-arm WITH_SIZE_STREAM no-op concern at
`SerializationString.cpp:728-768` did not reproduce in the pinned runtime:
an isolated six-row UInt64-only Dynamic(max_types=1) part enumerated
`d.SharedVariant.size` and returned the exact six values (root serial guard,
exit 0). This narrows that hypothesis only for the tested runtime and fixture;
the fresh source is unbuilt and no general WITH_SIZE_STREAM certificate follows.

Array sizes are sibling streams, not path ancestors of elements. In particular,
a Map value Dynamic structure is `<m>%2Evalues.dynamic_structure`, not
`<m>.size0%2Evalues.dynamic_structure`. This source-law counterexample corrected
the first audit hypothesis before implementation.

## Executable plan and falsifiers

1. New `spec/binary_dynamic_physical_w156_red_spec.cr`: root executes literal
   root/recursive/unused binding cases against the baseline veto, then switches
   to the explicit new owner. A missing-symbol compiler error is not RED.
2. New small-class files under `src/crystal_click/binary_dynamic_*physical*`;
   explicit loader entries only. Implement measured names, prefix ownership,
   deep-copy boundaries, collision refusal and aggregate/rebased limits.
   Guard adversaries: equal nominal sites with different rosters, ordinary vs
   shared String, nested Arrays through arms, LC prefix retention, malformed
   escaped prefixes, conflicting physical basenames, exhausted shared context.
3. Focused DEBUG then affected RELEASE gates under the serial host guard;
   retained no-roster fences run alongside the new behavior. Reconcile exact
   paths, observed examples, exits and source/spec hashes independently.
4. Finite stock Wide qualifier: compare complete literal names and selected
   structures/lanes/grids/values; exchange library-emitted lanes into borrowed
   stock envelopes, rebuild checksums, actually ATTACH/CHECK and compare literal
   values. A CHECK-valid changed-value control must fail the value oracle.
   Borrowed envelopes are not independent whole-part authorship.
5. Complete current spec inventory, formatter, Ruby syntax and diff hygiene;
   scoped hostile review, then atomic local commit. If any required signal is
   absent, keep this frontier IN_PROGRESS rather than manufacture closure.

Consumer inventory at baseline: bounded
`rg -n 'BinaryBulkPhysicalPlan|from_escaped_prefix|PhysicalPrefixAdapter' src spec scripts`
finds Object file-reader/column-writer composition, old physical specs and
finite qualifier scripts. None migrates implicitly. The new owner has no
external consumer yet; the W156 qualifier is its first storage consumer.

## Observed pre-implementation evidence

The retained baseline physical/consumer fences passed 13 DEBUG examples under
the root-owned serial guard (exit 0). The corrected W156 behavioral RED compiled
and ran three examples: all three reached the existing runtime Dynamic veto
(three errors, exit 1), rather than a missing-symbol compiler failure. Two test
assumptions were corrected first: the prepared Variant includes synthetic
SharedVariant in its canonical arm indexes/count, while the stored Dynamic
structure's type count excludes it. Production implementation was admitted only
after this corrected RED.

## Root review and discriminating controls

Root rejected two candidate implementation shortcuts before the final gates:

- Appending one parent's arm entry and immediately recursing interleaved the
  parent's flat span with child-site entries. A later UInt64 arm could then
  resolve to the nested SharedVariant basename. Measurement now reserves the
  complete parent span before descending, while sites retain DFS preorder.
- Treating LC as a descriptor stop-site bypassed depth/node accounting for its
  child descriptors. LC remains a physical stop-site only; hidden descriptors
  consume the shared context without generating dictionary-internal roles.

Two isolated scratch-only method reopens restore these errors. Root executes
each under the serial guard: both compile and run six final adversary examples,
with exactly one failure, no errors/pending, and exit 1. The first fails on the
missing LC depth refusal; the second fails on the literal UInt64-versus-
SharedVariant basename. Production files are never mutated by these controls.
An initial absolute `require` compiler error was corrected and is not counted
as a successful mutant. Final scratch results also reconcile unchanged
production/adversary-spec hashes. The corrected final candidate passes all
109 focused DEBUG examples over 18 unique specs in two disjoint groups, exit 0,
including direct physical-name collision and context/limits-mismatch guards.

The first expanded DEBUG gate also caught a fixture omission: a WithSize
Nullable/Tuple expected map lacked the shared String size lane. Source law and
the separately covered WithSize shared arm require `.SharedVariant.size`; only
that expected map was corrected. No production relaxation followed.

## Final candidate evidence

The final formatted production/spec state passes 109 focused DEBUG examples
over 18 unique specs in two serial disjoint groups, and 567 affected RELEASE
examples over 83 unique specs in nine serial disjoint groups. Both have zero
failures/errors/pending, exit 0 and unchanged source/spec hashes. Earlier
107-example DEBUG and 565-example RELEASE passes predate the two added guard
examples and are not substituted for these final gates. The complete current
inventory passes 2,582 examples over 406 unique specs in 41 serial disjoint
non-release groups with `--no-debug`, zero failures/errors/pending and exit 0.
Root independently reconciles every gate's fresh inventory membership, exact
group paths, observed stdout counts, guard exit markers and unchanged current
source/spec hashes. Final labels are `focused-debug-final`,
`affected-release-final` and `full-inventory-final` under
`/private/tmp/crystal-click-w156.mU8AyS`; the retained root runner's command
`ruby /private/tmp/crystal-click-w156.mU8AyS/gates.rb reconcile <labels...>`
returns exit 0 and matching counts for all three.

The final root-built qualifier and literal Ruby recheck pass under the serial
guard (exit 0): four typed columns, six rows and three real marks. Five actual
Dynamic sites produce 18 data lanes and five structure lanes, plus the id lane.
The planner consumes and re-encodes every structure/data file inside a copied
stock Wide envelope. Both the library result and the 42-to-43 mutant actually
ATTACH and pass stock CHECK; the independent full-value oracle distinguishes
the CHECK-valid mutant, while its unmodified middle rows remain exact. Supplied
statistics are not recomputed; this count-preserving change leaves them intact.
No independently authored complete-part certificate follows.

Root independently reconciles all 31 recorded process exits and 27 query
output/error digests and status files, plus the separate Ruby oracle's 19 fresh
query statuses. The oracle uses its own literal names/types/values rather than
the driver, decoded bytes or manifest as the expected result. Stock native
qualification is SINGLE_STREAM/BASIC/Dynamic V3 for this fixture only;
WITH_SIZE_STREAM and LC products retain source/spec evidence, not native
certification here.

Final scratch evidence is retained at
`/private/tmp/crystal-click-w156-native-final.a5TmEj/child/results`;
the compiled driver SHA-256 is
`a9725701b26022454c5f0082f396bd721988d957dddb356b064b3ea5d13bf89e`.
The production physical owner SHA-256 is
`4b0edb6fe067fb011c5ce9aa43d1c5927e45698ff0a7c5f2117e6a11bad2053e`;
the independently rechecked Ruby oracle SHA-256 is
`8e32ff7fe021783f60b7bf31014a58197efdda9ea661488eb47b17eaa121ea6f`.
These identify the observed state, not durable availability of temporary files.

DoD uses the root-owned `cogni-ml/scripts/run_safe.sh` serial host guard with
600-second / 12-GiB Crystal bounds, one compiler thread, the isolated W156 cache
and `--link-flags=-fuse-ld=ld`. Focused and affected gates execute every selected
spec exactly once per mode. The complete inventory uses non-release
`--no-debug`, not a performance benchmark. Final guarded
`crystal tool format --check` passes all six owned Crystal paths without
modifying them; `ruby -c` passes both new Ruby scripts. Exact-path diff,
secret-pattern and new-file size hygiene pass before the atomic local commit.
The finite native DoD builds
`scripts/check_dynamic_physical_binding_w156.cr`, then runs
`scripts/check_dynamic_physical_binding_w156.rb --scratch <fresh-owned-child>
--driver <root-built-executable>` with `W156_EXECUTE_AS_ROOT=YES` under the guard;
it invokes `scripts/recheck_dynamic_physical_binding_w156.rb` as a separate
literal oracle. Expected signal: exit 0 plus actual stock/library/mutant
CHECK, library/mutant ATTACH and exact nominal/full/middle values, including
the intentional 43-versus-42 distinction. None of these signals measures read
performance.

Scoped hostile verdict: ROBUST for explicit actual-roster physical binding,
the declared resource/name guards, retained default-consumer fences and this
finite pinned stock fixture. Root inspected the implementation, corrected the
parent-span/hidden-LC accounting errors, executed their discriminating mutants
and reconciled independent literal stock evidence. Luna's final read-only
closure review found no remaining contradiction within that boundary; it is
correlated review, not independent-model replication. Wider serializer products,
cross-contributor name reconciliation, independent complete-part authorship,
declared Object Dynamic and performance are not closed by this verdict.

## Refresh / failure policy

Certificates are scoped to the declared source state, exact pinned executable
and finite fixtures. Changes to roster order, filename escaping, prefix/grid
ownership, codec profiles, source/runtime identity or consumers reopen the
dependent checks. Fail closed on unsupported profiles, mismatched rosters or
budgets; never promote a passing internal round-trip to stock compatibility.

## Confirmed next boundary

Declared Object/JSON Dynamic is still closed. Its plan/stream owners distinguish
ordinary typed `BinaryBulkStreams` from untyped Object Dynamic; its codecs and
physical planner explicitly reject `contains_dynamic?` on declared typed paths.
Admission requires per-typed-path actual occurrence plans, their structure/data
ownership and reader discovery before physical binding, rather than deleting
those guards or applying the Object inferred-path policy to typed fields.

One prerequisite is the structure metadata mark boundary. Root checks
`BinaryDynamicBulkPlan.encode_structure_streams` and
`BinaryDynamicStructureStreams`: they currently retain blobs only.
`DynamicStructureCodec.write_to` discards the relative statistics offset that
`write_with_statistics_offset` already returns. In contrast,
`ObjectDocumentColumnWriter.bind_lanes` requires metadata offsets and
`ObjectDocumentFileReader.validate_metadata_grid!` requires every real metadata
mark at that boundary and the terminal mark at complete EOF. The next paired
owner must preserve that boundary under the same operation budget; ordinary
data K+1 grids are not a substitute.

After that prerequisite, use the existing separate Object schema, codec,
physical-plan, column reader/writer and complete-part orchestrator seams. The
new certificate must exchange both stock-created and independently library-
authored complete parts, with actual ATTACH/CHECK, full/middle literal values
and a CHECK-valid wrong-value control. Keep default no-roster consumers,
untyped Object namespaces and unqualified profiles fenced. This section is a
source-backed continuation pointer, not implementation or qualification of the
next boundary.
