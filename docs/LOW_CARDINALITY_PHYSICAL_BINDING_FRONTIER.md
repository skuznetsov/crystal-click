# LowCardinality physical binding frontier (W145)

Document status: implementation, declared spec gates and finite native
qualification passed. No new complete-part capability is admitted here.
Baseline: `49a696c`, 2026-10-03.
Baseline frontier: paired ordinary recursive bulk LC transport, including raw
Float identity, was implemented; generic part-stream binding still rejected LC.
The working implementation removes only that generic binding veto and gives
typed Object an explicit consumer-owned refusal.
Bounded context: role-to-physical-basename planning, then independently
observed ordinary Wide lanes. This is a prerequisite for owned LC parts and
declared Object LC, not a replacement for those final capabilities.

## Intended transition

Bind each already-admitted ordinary LC site to exactly two physical lanes:
`<role>.dictionary` -> `<escaped-prefix>.dict`, and `<role>.indexes` ->
`<escaped-prefix>`. Preserve ancestor Array/Map size levels, Tuple field
escaping, ordinary String profile selection, exact name budgeting and detached
ownership. Source/runtime probes must qualify these predicted names before
the transition is admitted.

The source reference remains the separate shallow checkout
`9007d227b64a3f8b667fc5258ceb2923f3cf477d`. Native execution uses the exact
26.10.1.1201 executable, build `d9bcb5ab007f0f6299f7f973f2642245bab3d028`,
SHA-256 `bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
This executable is not asserted to have been built from that source checkout.

Still rejected: Object/Dynamic LC envelope integration, serializer profiles
already rejected by the shared LC codec, generic whole-part writer dispatch,
Compact parts and arbitrary schema/layout combinations. No existing facade
is widened merely because its shared name planner becomes capable of LC.
MV/projection and performance work remain subsequent objective requirements.

The two-lane prediction is for default LC serialization and BASIC Map, not
specialized LC `.dict_prefix` or Map WITH_BUCKETS. The logical descriptor alone
cannot infer these on-disk serializer profiles; this binder is not an automatic
part-profile detector. `BinaryBulkProfile` selects ordinary String lanes only.
LC always stops child stream enumeration and uses its own dictionary grammar.

## Owned implementation and consumer inventory

The bounded `rg` caller inventory found Object typed and Dynamic alternatives
as consumers of `BinaryBulkPhysicalPlan`. At baseline, typed Object paths
inherited the generic LC refusal, while Dynamic had an independent preflight
guard.
`ObjectDocumentFileReader.inspect` can return a physical descriptor without
codec decoding, so the codec guard alone cannot preserve typed Object refusal.
The implementation adds an explicit typed guard to
`ObjectDocumentPhysicalPlan` before delegation.

- `src/crystal_click/binary_bulk_physical_plan.cr`: paired measurement and
  rendering stop-sites, retaining collision, shared budget and role checks.
- `src/crystal_click/object_document_physical_plan.cr`: typed Object-owned LC
  refusal; existing Dynamic guard remains unchanged.
- `spec/binary_low_cardinality_physical_w145_spec.cr`: new literal mappings,
  budgets, escaping, ownership/collision and independent consumer guards.
- Existing W143/W144 specs: replace only direct generic binder refusal with
  positive binding; retain adjacent Object/Dynamic refusals. W141/W142 guards
  stay unchanged, as do legacy LC(String) facade contracts.
- New `scripts/low_cardinality_physical_binding_fixture.cr` and
  `scripts/check_low_cardinality_physical_binding.sh`: finite ordinary Wide
  runtime matrix; root alone executes native/compiled probes.

Source anchors at the pinned checkout: `SerializationLowCardinality.cpp:72-99`
enumerates LC stop-sites; `ISerialization.cpp:313-347` maps literal dictionary,
Array-level and escaped Tuple suffixes; `SerializationArray.cpp:352-395`
distinguishes parent and flattened child ranges; `SerializationMap.cpp:667-672`
delegates BASIC Map to Array(Tuple(keys, values)). LC Nullable has no `.null`
lane (`SerializationLowCardinality.cpp:673-690`). Optional dict-prefix and
bucketed Map layouts remain outside this two-lane binding certificate.

The Wide writer leaves `use_specialized_prefixes_and_suffixes_substreams`
false (`MergeTreeDataPartWriterWide.cpp:146-158,568-586`); Compact explicitly
sets it true and LC adds `.dict_prefix`. Both Map serialization settings must
be pinned BASIC, including `map_serialization_version_for_zero_level_parts`
for INSERT-created parts. Ordinary String propagation is pinned separately:
`propagate_types_serialization_versions_to_nested_types=1` causes BASIC Map
keys to use the selected String profile (`DataTypeMap.cpp:124-134`); LC still
uses the default dictionary serializer, without a `.dict.size` lane.

Finite native matrix: four ordinary Wide schemas crossed with SingleStream
and WithSizeStream ordinary String settings (eight stock stores, eight separate
borrowed-envelope exchange stores). The witnesses are root LC(Nullable(String))
with LC(UInt64), Array(LC(String)) with varying and empty child rows over three
four-row parent granules, an escaped named Tuple with LC(Nullable(UInt64)), and
BASIC Map(String, LC(String)). Each includes an ordinary top-level String
sibling; the Tuple also contains an ordinary String. Exact per-part rosters,
hashed files, serialization metadata, independent lane grids and values must
match the declared profile. This is a finite sample, not every recursive type.
Stock dictionary choice is not an interoperability requirement: stock lanes
must decode to the authored literals, while library-emitted lanes must match
their copied-part files and decode to the same literals. The raw byte/grid
relation between stock and library encodings is recorded separately; legal
dictionary-order/framing differences do not waive either semantic check.

## Design laws and risk

Risk: CAUTION (physical format binding and shared consumer boundary).
Rollback: exact scoped diff over the clean baseline and one atomic feature
commit after verification; no stock data root or existing fixture is modified.

1. LC owns its dictionary framing. Its logical child does not produce ordinary
   String size/null/data lanes, even for LC(Nullable(String)).
2. Name measurement and materialization use the same two-role grammar. Check
   complete expanded role/name bytes before building the retained roster.
3. Preserve one shared planner and physical LC owner, not per-type/container
   class families. Nested private metadata remains with its cohesive owner.
4. Physical basenames are not SQL type identity or serialized value identity.
   Hash only the fully escaped logical basename; keep literal suffixes and
   escaped Tuple/Object separators distinct.
5. Detect duplicate physical names across roles, including LC versus ordinary
   siblings. Returned maps/names remain detached from retained state.
6. Object/Dynamic guards must be demonstrated on their own consumer boundaries
   rather than relying on the generic LC binding refusal being removed.

Strongest likely failure: a valid logical LC site binds the wrong filename,
or removing the common guard silently opens an unqualified Object consumer.
Guard: native exact roster/lane comparisons plus root/nested Object/Dynamic
refusal tests, including empty inputs and cached descriptor membership.

## Execution order and falsifiers

1. Root observes the current LC physical refusal as RED; Luna inventories
   affected callers/tests and stock substream naming without native execution.
2. Seal literal root/container mappings, exact/one-short name and descriptor
   budgets, raw/escaped/hash/detached ownership, collision and retained-envelope
   guards in a focused spec. Root executes RED before production changes.
3. Remove only the generic LC binding veto; add paired measurement and naming
   branches to `BinaryBulkPhysicalPlan`. Do not alter dictionary algorithms,
   occurrence schedules, transport framing or public whole-part dispatch.
4. Qualify actual stock ordinary Wide basenames, mark grids and logical values
   with fresh isolated stores, including recursive and nullable LC. Where
   modified library lanes use a stock envelope, name that borrowing explicitly;
   ATTACH/CHECK alone cannot qualify an independently owned whole-part writer.
5. Execute focused DEBUG, affected RELEASE, unique complete spec inventory,
   native naming/lane controls and unchanged W143/W144 regressions, then hostile
   review and an atomic local commit. Do not push.

Native controls must include a valid baseline plus an intentionally incorrect
LC value mapping that the comparator rejects despite actual ATTACH/CHECK
success. Exact stock results,
not a self-roundtrip or a hash manifest alone, distinguish compatibility.
If the source/runtime profile disagrees, stop admission and identify the
specialization; do not guess names or substitute a simpler matrix silently.

DoD: root-owned serial resource guard, isolated Crystal caches, single compiler
module/thread, Darwin linker flag; zero failures/errors/pending in the declared
spec gates, exact native rosters/values, actual CHECK success and sensitive
negative controls. Executed commands, source seals and finite matrix will be
recorded below from measurement, not inferred from the proposed roster.

Root's baseline probe at
`/private/tmp/crystal-click-w145.FeVWY3/physical_lc_red.cr` compiled and exited
one at `BinaryBulkPhysicalPlan#build_bindings`, line 50, with the existing
`physical bulk LowCardinality bindings are not admitted` refusal. The probe
requires the literal `root.dictionary -> x.dict`, `root.indexes -> x` roster;
this is a behavioral RED, not an absent-symbol or compilation failure.

The frozen nine-example W145 spec also compiled and ran against the baseline:
eight examples errored at the same exact generic veto and the retained
Object/Dynamic guard example passed. Root command (guard resource cap 32768
MiB, minimum system-free threshold 50%):

```sh
COGNI_RUN_SAFE_MIN_FREE_PCT=50 RUN_SAFE_PASSTHROUGH_STDIO=1 \
bash /Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh \
  /bin/bash 900 32768 /private/tmp/crystal-click-w145.FeVWY3/run_specs.sh \
  focused-red spec/binary_low_cardinality_physical_w145_spec.cr
```

Observed exit one: `9 examples, 0 failures, 8 errors, 0 pending`.
Log: `/private/tmp/crystal-click-w145.FeVWY3/focused-red.log`.
An earlier malformed guard invocation selected Crystal instead of bash and
stopped with `unknown command: bash`; it ran no tests and is not RED evidence.

Root's first focused GREEN executes the W145 spec plus W125 physical planning,
W141 nominal LC, W142 storage, W143 recursive bulk and W144 raw Float:
`99 examples, 0 failures, 0 errors, 0 pending`, exit zero.
Log: `/private/tmp/crystal-click-w145.FeVWY3/focused-debug.log`.
The affected RELEASE roster is independently enumerated by the runner's
`rg --files spec -g '*_spec.cr'` filter across binary, physical planning,
Object/document/file/part consumers, Dynamic and compressed-mark transport;
its exact 37 paths are retained in `affected-release-inventory.txt`.
Root executed that RELEASE roster: `324 examples, 0 failures, 0 errors,
0 pending`, exit zero; `affected-release.log`. The subsequent full gate passed
2,395 examples, zero failures/errors/pending, across 372 unique spec files and
sixteen serial disjoint non-release groups; exit zero. This is not
combined-process or RELEASE full-suite evidence. Log/roster:
`full-inventory.log` and `full-spec-inventory.txt` under the same root-owned
W145 directory. A separate `find spec -type f -name '*_spec.cr'` enumeration,
sorted with `LC_ALL=C`, matched the runner's retained roster with `diff` exit
zero.
These gates identify source/spec state with
`rg --files src spec | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256`:
`43b133782af29a6f54af441641b0d06b705ca101125d61e038b56bcea103791e`.
This seal excludes fixture scripts authored concurrently; no production or
spec changes are permitted during the gate without invalidating this seal.

## Executed native and adversary certificate

Root executed the guarded native command with SDKROOT
`/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`, the exact runtime
and source paths above, and a fresh output root:

```sh
COGNI_RUN_SAFE_MIN_FREE_PCT=50 RUN_SAFE_PASSTHROUGH_STDIO=1 \
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
W145_EXECUTE_AS_ROOT=YES \
W145_CHECK_ROOT=/private/tmp/crystal-click-low-cardinality-physical-w145.FeVWY3-03 \
CLICKHOUSE_BIN=/private/tmp/crystal-click-w144-runtime-recovery.Pm8VNb/clickhouse-stripped \
CLICKHOUSE_SOURCE_ROOT=/Users/sergey/SrcArchives/clickhouse-2026-10-03-depth1-9007d227 \
bash /Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh \
  /bin/bash 900 32768 scripts/check_low_cardinality_physical_binding.sh
```

Observed exit zero: all eight stock and eight separate borrowed-envelope
library cells passed exact physical rosters, frame-aware lane grids, literal
bulk decoding, nominal columns, actual CHECK and ordered RowBinary; all
eight exchanged parts passed ATTACH. The helper replaces every planned
column lane, including keys and ordinary String siblings, then rebuilds all
checksum records. It does not generate the stock metadata/sidecar envelope.
The retained `results/cells.tsv` has sixteen unique cells. `lanes.tsv` and
`lane-relations.tsv` contain 100 observations each; all 100 byte/grid relations
were exact in this finite sample. Exact stock encoding is an observation,
not a required dictionary-order invariant for future profiles.
`results/assertions.tsv` contains eight positive schema/profile assertions
and the negative control. Runtime version, SHA and actual VERSION_GITHASH
are retained alongside the complete SQL and command outputs.

The negative control changes only LC(UInt64) `n[0]` from 10 to 999, rewrites
its dictionary/index lanes and rebuilds valid checksums. Actual ATTACH and
CHECK pass, while the original full RowBinary comparator rejects the result.
This demonstrates that valid checksums and attachment alone cannot establish
correct logical values.

Root's separate Ruby checker at
`/private/tmp/crystal-click-w145.FeVWY3/root_binding_oracle.rb` constructs
RowBinary from literal arrays, nullable flags, VarUInt String lengths, ordered
Map entries and little-endian UInt64 arithmetic, without Crystal codecs.
Executed through the same guard with `/usr/bin/ruby 300 32768`, the native
evidence root above and fresh output
`/private/tmp/crystal-click-w145.FeVWY3/root-binding-oracle-04`, it passes
51 fresh stock queries: exact RowBinary, exact ordered `system.columns`
name/type declarations and actual CHECK for sixteen cells plus the control.
It covers 192 baseline rows and twelve control rows, verifies that the
control has exactly the intended changed value, and rejects the unmodified
literal expectation. CHECK requires the exact three-field success response
`all_1_1_0\t1\t\n`, including an empty message.

Failed attempts are preserved, not positive evidence: native root `-01`
stopped during compilation because Tuple INSERT expressions were an Iterator
rather than the constructor's Array(String). Explicit materialization fixes
that script-only error; native `-02` runs the complete matrix. Independent
checker roots `-01` and `-02` exposed incorrect test expectations for CHECK's
empty message field and `toTypeName`'s multiline Tuple display. The final
checker uses exact catalog declarations rather than stripping quotes or
normalizing type identity. These fixes do not change production or specs.

Luna's subsequent static oracle review found two hardening gaps: whitespace
trimming hid the raw CHECK response shape, and the wrapper canonicalized the
output path only after mkdir. The frozen helper now requires untrimmed
three-field CHECK success, and the wrapper admits only a safe direct
`/private/tmp` child before runtime checks or mkdir. Root's
`/private/tmp/crystal-click-w145.FeVWY3/check_wrapper_guard.sh` passes six
slash/dot/traversal suffix refusals plus a safe-suffix discriminator without
creating an output directory or invoking native execution. The final native
root `-03` and independent checker `-04` rerun the complete matrix after
these script-only fixes; both exit zero. The source worktree pin is observed
clean by root, but not cryptographically linked to the separately pinned build.
Parent-literal recursive decoding exercises child occurrence schedules; this
is not a separate exhaustive certificate for all flattened LC counts.

Root also reran the unchanged W143 recursive exchange, W144 floating identity
and W144 borrowed-part gates against the pinned executable; each exited zero.
Their fresh evidence roots are
`/private/tmp/crystal-click-object-low-cardinality-w143.FeVWY3-01`,
`/private/tmp/crystal-click-low-cardinality-float-w144.FeVWY3-01`, and
`/private/tmp/crystal-click-low-cardinality-float-part-w144.FeVWY3-01`.
The separate W144 integer/raw-bit oracle also passed 48 fresh stock queries
under `/private/tmp/crystal-click-w145.FeVWY3/root-float-oracle-01`.
This retains selected-middle/all-empty recursive marks and raw Float identity
regressions without promoting their earlier borrowed parts to owned writing.

Root's scoped adversary verdict is ROBUST for the explicit default-LC/BASIC-Map
binding seam: source inspection and literal tests retain descriptor validation,
exact/shared budgets, escaping, collision detection, detached ownership and
independent Object/Dynamic guards; native stock consumption and the valid
wrong-LC-value control attack the physical/semantic seam. Luna's static source
review is correlated supporting evidence, not an independent runtime oracle.
No profile detector, Compact/WITH_BUCKETS support, new Object LC capability,
general owned writer or performance conclusion follows.

Root format `--check` over the exact two production, three spec and fixture
files, shell syntax, Ruby syntax and `git diff --check` all exit zero.
Frozen production/spec/scripts seal (same sorted `rg`/SHA pipeline with
`scripts` included):
`7eedd2935e0b068a225310958e44a9c97459c5815dc7ee1bb3c403ea9be97054`.
The wrapper SHA is
`297a010ea47ab044727fd227f9c0eb380a1b7b5bfa905832283095eff68b9cc2`;
fixture SHA is
`3fef63a619423a6cc3dc993d86a63adfd2390ea11b3df1be628b52d6ce191a15`;
independent Ruby checker SHA is
`878afeee5fa11a6e4b1a592172ae339dc1413f6b35263323bdf46767799c1653`.
Evidence is stale after changing those sources, relevant serializer code,
runtime identity, settings, marks/layout or consumer dispatch. Refresh the
affected specs and native probes before widening admission; unavailable or
contradictory evidence preserves the bounded guards rather than guessing.

Next local track after binding: paired declared Object LC fields and complete
independently owned LC parts using the shared planner/codec, followed by other
remaining type/layout and MV/projection requirements before optimization.
