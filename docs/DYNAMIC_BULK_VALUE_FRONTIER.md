# Generic Dynamic bulk values and complete mark grids (W155)

Status: VERIFIED for paired normalized values/grids and retained consumer
fences only. Baseline: clean `c980c87`. Risk: CAUTION.
Rollback: the baseline commit and one scoped local feature commit; no push.

## Boundary

Admit a separate paired normalized codec for a supplied root descriptor,
per-occurrence Dynamic V3 structures, and logical `BinaryValue` granules.
Return structure streams and exact decompressed data-role lanes together.
The nominal cap is not an actual roster. Equal nominal descriptors at distinct
paths retain independent structures, including empty and unused occurrences.

Select an ordinary arm by exact actual descriptor identity when it occurs in
that site's supplied roster. Otherwise serialize an inline binary descriptor
and scalar-value envelope into the implicit SharedVariant String lane. NULL
uses discriminator 255 and has no child occurrence. Ordinary String and
SharedVariant remain distinct canonical arm identities even though both store
String bytes. This is an explicit stored-roster codec policy, not emulation of
ColumnDynamic insertion, roster promotion, or merge-time type selection.
Logical values do not retain an original ordinary/shared placement hint.
Supplied structure statistics are preserved, not recomputed from the granules.
They are not a certificate that independently changed or selected-window
granules have matching full-part row statistics; a physical writer must own
that separate publication invariant.
Paired logical encode/decode therefore does not imply byte-exact replay of
every valid stored input: encoding applies the stated roster policy. Do not
reject a source-valid shared envelope solely because its type also occurs
in the ordinary roster.
Bulk SharedVariant bytes are opaque to the upstream bulk reader. A decoded
descriptor-only Nothing envelope may normalize to logical Dynamic NULL;
this is not evidence of a normal insertion path storing NULL in SharedVariant.

Admit recursive declared and actual Array, Map, Tuple, static Variant and
Dynamic occurrences within the existing descriptor/structure grammar. Reuse
the paired ordinary bulk and LowCardinality owners. Every data role retains
a complete K+1 mark grid, including unused arms and zero-occurrence child
marks. Selected windows must not lose the full schedule needed by sparse
LowCardinality sites. Prefix-only metadata is not evidence of value support.

Rejected: new physical basename binding, compressed framing, COMPACT mode,
older Dynamic structure versions, declared Object Dynamic, new public part
reader/writer admission, insertion/merge policy, MV/projections and performance
qualification. Normalized discriminator bodies omit the physical BASIC
UInt64 mode prefix, as the existing generic Variant bulk profile does.
Existing APIs without supplied occurrence structures must remain fenced,
including empty input, zero selected rows and cache-hit paths. Existing
qualified legacy Dynamic profiles are not replaced by this new boundary.
Zero-length selected windows still validate structures, role closure, ordinary
grids and the full LC state schedule. They do not semantically parse unselected
ordinary payload bytes; selected-window success is not whole-input validation.

## Design laws

One operation budget covers root and actual-roster descriptors, planning,
structures, all values, SharedVariant envelopes, sparse schedules and marks.
No child/site/mark resets its depth, node, element or byte counters. Rebase
shared descriptor/value depth at the containing occurrence. Preflight
count-derived allocations and metadata before materialization. Limits are
logical-work bounds, not RSS certificates. Preserve detached mutable bytes,
paths and grid ownership.
The shared-envelope temporary reserves minimum framing (one byte for
single-stream String, eight for its separate size stream). Exact framing plus
payload is checked before appending to a lane. A multi-byte VarUInt header can
therefore cause rejection after temporary materialization; this is not an
exact pre-materialization reservation or a temporary-allocation certificate.

Keep one cohesive class or module per file. Do not grow the large reader,
writer or table facades or copy a second scalar/ordinary/LC wire grammar.
The new entry point must own structure pairing explicitly; a nominal type
alone cannot silently manufacture stored occurrence state.

Source reference: unbuilt shallow
`b94acbe318f8459ac88b35647f4e2293d8e225db`.
`SerializationDynamic.cpp:600-615,767-779`,
`SerializationVariant.cpp:454-520`, `ColumnDynamic.h:24-35,432-438`, and
`ColumnDynamic.cpp:73-82,125-165,277-305,789-803` separate stored serialization
from insertion/promotion. Runtime certificates must identify their separately
pinned executable; current-master runtime qualification is not implied.

## First discriminator and execution plan

1. Preserve the existing no-structure Dynamic refusal as a guard, not a bug.
   Establish an authorized, compiling new API stub and execute a valid
   nontrivial recursive operation which fails behaviorally at that stub.
   A missing symbol or compiler error is not the feature's RED signal.
2. Implement paired structure-bearing codec/stream owners and the smallest
   occurrence-aware extension to existing bulk/LC owners. Inventory shared
   callers; old default paths retain their previous fences and behavior.
3. Test independent literal role bytes and K+1 coordinates, distinct equal-
   nominal sites, NULL, ordinary String versus shared String envelopes,
   absent-with-room stored shared values, nested actual containers, unused
   child prefixes, LC-bearing sparse arms, both String profiles and windows.
4. Test exact role/site key sets, malformed/trailing envelopes, invalid tags,
   bad offsets, detached inputs/getters and aggregate exact/one-short budgets.
   A valid wrong-site or wrong-value input must decode successfully but fail
   an independent semantic expectation; a process error is not that control.
5. Root alone runs guarded serial Crystal jobs with an isolated cache:
   `crystal spec --single-module --threads 1 --link-flags=-fuse-ld=ld
   --error-trace` (RELEASE adds `--release --no-debug`). Focused and affected
   gates require zero failures/errors/pending; enumerate the affected set and
   reconcile actual executions before any verified claim. Independently
   qualify normalized lanes against a finite stock-produced fixture with
   separately recorded source/runtime identities. Check format and exact diff.

Strongest failure: matching state by nominal type instead of occurrence,
collapsing ordinary String into SharedVariant, or resetting a shared envelope
or LC child's operation budget. Opposite-frame check: a successful normalized
codec does not admit a complete physical part. Refresh after descriptor,
structure, role, schedule, budget, consumer or source/runtime changes.

The first behavioral RED was executed by root against the compiling stubs:
two examples, zero failures, one error, zero pending, exit 1. The new
two-occurrence Tuple(Array(Dynamic), Dynamic) witness raises exactly
`generic Dynamic bulk values are not implemented`; the old no-structure
refusal guard passes. This is not a compiler or missing-symbol failure.
The later gates below supersede this stub, not the retained no-structure guard.

The first compiled candidate gate has 61 examples, five failures and two
errors. The sparse test route incorrectly inserted size records into empty
ordinary-arm marks: complete coordinates do not create payload occurrences.
Other failing witnesses miscounted a two-entry LC dictionary, omitted one
Dynamic child access, and assumed a 27-byte logical-work limit could admit a
14-byte standalone output despite separately charged path/planning work.
These witnesses must be corrected from the admitted grammar, not by relaxing
the independent comparator or treating the failed gate as completion.

The first stock qualifier refuses an incorrect empty-statistics literal.
`SerializationDynamic.cpp:530-550` writes a V3 statistics suffix: the six-row
root has canonical Shared/UInt64 counts `[1, 4]` and shared String count one.
The independent fixture must include those source-derived counts. A separate
String-coordinate assumption is also refuted by `ColumnString.h:40,185-193`
and `SerializationString.cpp:164-168`: stored strings are not zero-terminated;
two two-byte values use six bulk bytes, and the seven-byte shared spill
envelope plus its one-byte frame uses eight. Do not add NUL bytes to match an
assumed in-memory layout. These are oracle-law corrections, not new format
admission or a successful stock qualification.

After the literal-law corrections, the finite stock qualifier passes four
typed columns, six rows and three marks. All seven stock SQL probes pass;
the driver asserts the exact physical roster, per-site suffix bytes, normalized
body bytes and K+1 coordinates before checking independent logical values.
The wire-valid normalized UInt64 `42` to `43` control is accepted by the Crystal
decoder, then rejected by the independent value comparator. ClickHouse does
not re-read or CHECK that mutation. This is a finite single-stream/BASIC/V3
normalized witness, not general physical admission or complete-part writing.

The second focused candidate gate has 61 examples, two failures, zero errors
and zero pending. Both remaining witnesses incorrectly locate the global LC
dictionary in per-mark data: its eight-byte version is a separate prefix and
the existing encoder emits all nonterminal dictionary coordinates as eight,
with the final coordinate at the complete dictionary length. Index records
still contain per-mark UInt64 flags, UInt64 row count and IDs. Correcting this
witness must preserve exact comparison, not change the established LC codec.

Root separately executed the rebased scalar-helper guard: two examples,
zero failures/errors/pending, exit 0. An isolated scratch-copy mutation
replaces the supplied budget with a fresh one in each helper. Both examples
then fail specifically on the independent literal two-node expectation
(observed zero), with zero errors/pending, exit 1. The production helper
remains unchanged. This is a shared-context discriminator, not a bulk,
physical-part or full-suite completion certificate.

The later shared decoder edge hook is separately tested: four helper examples
pass with zero failures/errors/pending. A zero-edge limit rejects after the
literal Bool descriptor visit but before its scalar visit (one node), while
the Nothing sentinel has no requested value edge. Root's isolated delayed-edge
mutation still rejects the exhausted limit but fails exactly the visit-order
assertion (expected one node, observed two): four examples, one failure, zero
errors/pending, exit 1. The working helper is unchanged. This certifies the
tested logical visit ordering, not allocator/RSS behavior.
Root also refreshes the fresh-budget mutation against all four current helper
guards: four failures on independent caller node counters (observed zero),
zero errors/pending, exit 1. Neither mutation touched the working source.

## Scoped implementation plan

The shared-boundary inventory command is
`rg -n 'BinaryBulk(TypePlan|Encoder|Decoder|Codec)|encode_borrowed|decode_borrowed' src/crystal_click`.
It identifies the ordinary public facade, physical plan, Object document and
shared-map codecs, legacy DynamicValueCodec, and LC site/census owners.
Those callers keep their default/no-structure behavior and are guard-test
consumers, not newly admitted Dynamic storage callers.

1. New `binary_dynamic_bulk_codec.cr` and `binary_dynamic_bulk_streams.cr`
   own the explicit public pairing. `encode` accepts `(type, structures,
   granules, limits, profile)`; `decode` accepts `(type, paired_streams,
   rows_per_mark, first_mark, mark_count, limits, profile)`. Internal budget
   overloads retain one supplied operation budget. Compiling stubs precede
   the executed behavioral RED in
   `spec/binary_dynamic_bulk_values_w155_red_spec.cr`.
2. `binary_dynamic_bulk_plan.cr` gains same-budget construction and bounded
   occurrence arm access. `binary_bulk_type_plan.cr`, `binary_bulk_encoder.cr`
   and `binary_bulk_decoder.cr` get an internal occurrence-plan opt-in, never
   an implicit fallback. Existing no-plan entry points retain their fences.
3. `binary_bulk_low_cardinality_site_encoder.cr`,
   `binary_bulk_low_cardinality_site_decoder.cr` and
   `binary_bulk_low_cardinality_occurrence_schedule.cr` propagate that same
   plan through actual-arm discovery, sparse routing and full-mark census.
   Internal Dynamic-aware default/minimum work may extend
   `binary_bulk_default_value.cr`, but existing default/cache APIs must still
   refuse Dynamic without an occurrence plan.
4. `binary_value_codec.cr` exposes a narrowly scoped internal rebased envelope
   path using its existing scalar grammar and shared budget. Its older
   persisted borrowed APIs retain Dynamic/LC fences. Add a separate cohesive
   Dynamic value helper only if routing/envelope ownership warrants it.
5. Root owns docs, source-state reconciliation and runtime qualification.
   The main implementation worker owns the plan, bulk, default and LC files;
   the stock-oracle worker also owns the isolated rebased scalar helpers in
   `binary_value_codec.cr`. The test worker owns W155 specs. These ownership
   sets are disjoint. No worker runs resource jobs or modifies another's files.
   Root runs the RED before authorizing production implementation, then
   focused DEBUG, affected RELEASE and complete unique spec inventory in
   serial disjoint groups; all require zero failures/errors/pending.
   Stock checks qualify finite normalized body/prefix/grid witnesses only.
   Format and exact staged-diff checks precede one atomic local commit.

The strongest pre-mortem is a Dynamic occurrence hiding LC from nominal
`contains_low_cardinality?` checks. Guard with an actual Array(Dynamic) arm
containing an LC site across selected and unselected sparse marks, alongside
an unused nested site. No nominal-only cache may bypass actual-arm discovery.

## Executed certificate (2026-10-04)

Root observes 120 focused DEBUG examples in 16 unique files/two disjoint
serial groups, and 554 affected RELEASE examples in 80 unique files/eight
disjoint serial groups. Every observed exit is zero, with zero failures,
errors or pending. Reconciliation independently matches the selected paths,
group membership, stdout counts, outer guard exits and current source/spec
SHA-256 hashes. Root also observes 2,569 full-inventory examples in 403 unique
specs/41 disjoint non-release groups with `--no-debug`, all with zero failures,
errors or pending and exit zero. Root independently reconciles the complete
inventory and current source/spec hashes as well. This is not the earlier
398-file W154 inventory or a presumed 402 files.

Selections are the sorted unique `spec/**/*_spec.cr` inventory, filtered for
focused work by
`w155|binary_dynamic_|dynamic_descriptor_consumer|binary_variant_bulk_w148|binary_low_cardinality_storage_w142|bulk_low_cardinality_w143|dynamic_values_w122`,
or for affected work by
`\Aspec/(binary_|dynamic_|bulk_dynamic_|object_|bool_semantics_)`.
Root runs groups of ten with the recorded Crystal flags under the isolated
cache guard: 600 seconds, 12 GiB process-tree RSS and a 50-percent system-free
memory floor. These bounds and elapsed times are not performance evidence.
The local commands are `run_gates.rb focused debug focused-debug-c`,
`run_gates.rb affected release affected-release-a`, and
`run_gates.rb all full full-inventory-a`, followed by `reconcile.rb` with those
labels in `/private/tmp/crystal-click-w155.Pp9kUw`. Those scratch scripts/logs
are temporary aids; refresh by re-enumerating the selections and independently
executing them at the candidate revision, not by trusting this prose.

The independently built stock driver has SHA-256
`25d27070d3e698fc1a4600939171411e58b9b03486a59aaedc25ba41faf19094`.
The qualifier is
`scripts/check_dynamic_bulk_values_w155.rb --scratch <empty-canonical-w155-child> --driver <freshly-built-driver>`;
its driver source is `scripts/check_dynamic_bulk_values_w155.cr`.
Root's observed command used `stock-b` inside
`/private/tmp/crystal-click-w155-native.mY83Oj` and `driver-candidate-b` inside
the gate scratch above, under the same 600-second/12-GiB serial guard.
The pinned executable is
`/private/tmp/crystal-click-w144-runtime-recovery.Pm8VNb/clickhouse-stripped`,
version `26.10.1.1201`, build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`, SHA-256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
The qualifier checks that identity separately from the unbuilt source
reference. A replacement executable needs a new explicit certificate.

The native fixture covers root ordinary UInt64/shared String spill/NULL,
equal-nominal Tuple sites with separate UInt64/String rosters, sparse
Array(Dynamic), and an unused Variant(Array(Dynamic(max_types=0))) child.
Seven SQL probes and 24 hashed physical data/mark files pass exact roster,
structure, normalized body, coordinate and independent logical-value checks.
Manual fixture role binding and existing compressed reads/prefix stripping
do not implement a production Dynamic physical binder. LC-bearing Dynamic
and the separate String size-stream profile have literal/spec evidence here,
not new stock-product qualification from this finite native fixture.

New paired entry-point and detached-stream owners have separate 61-line and
12-line files. The actual-roster plan grows from 574 to 1,186 lines; it reuses
existing scalar, ordinary bulk and LC grammars. Reader/writer/table facades
remain 15,726/25,202/6,786 lines. This is not overall modularization closure.

Root's scoped hostile verdict is ROBUST for the explicit actual-roster
normalized value/grid API, shared logical-work budget and retained default,
borrowed, physical and Object fences. Independent literal role/value checks,
valid swapped-site and wrong-value controls, delayed-edge/fresh-budget helper
mutations and the reconciled full gate support that scope. Luna's source
review is correlated supporting evidence, not independent execution. Format
checks on all 17 affected Crystal files, Ruby syntax and diff hygiene pass.
Do not promote this certificate to arbitrary physical parts, every type/layout
product, current-master runtime compatibility, RSS bounds or speed parity.
Refresh after descriptor, structure, actual-roster policy, role binding,
scheduling, budget, consumer or source/runtime profile changes. Git history
retains the tested implementation; missing temporary logs require fresh
execution rather than a claim based on their former presence.

Proposed next neutral architecture slice: a private stateless
`BinaryBulkMarkGridValidator` owning the common K+1 predicate sequence now in
`BinaryBulkDecoder.validate_grids` and
`BinaryBulkLowCardinalityOccurrenceSchedule.validate_shape_grid`. Preserve
caller-specific error text and length -> zero origin -> monotone byte domain
-> exact terminal precedence, including competing faults; do not move I/O,
budget charging or call preflight. This is not implemented in W155. Do not
unify Dynamic child-path helpers merely because they look similar: their
owners currently have different preflight/charge timing and logical-work
accounting, so that would be a behavioral rather than a neutral extraction.
