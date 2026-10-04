# Generic Variant Physical Binding Frontier

Document status: W149 implemented and verified within the execution seal below.
Current frontier: W148 normalized BASIC Variant bulk roles now have ordinary
recursive Wide physical binding; declared Object Variant/Dynamic and new public
whole-part writer profiles remain closed.
Baseline: clean `d8087d8`. Risk: CAUTION (persistent-format binding).

## Bounded context

This slice binds the existing ordinary recursive bulk grammar to explicit
Wide physical basenames and role-owned combined prefixes. It is not an
arbitrary-part reader, a new public writer profile, or declared Object Variant.
The independent source snapshot and runtime retain their distinct identities
in [CLICKHOUSE_SOURCE_REFERENCE.md](CLICKHOUSE_SOURCE_REFERENCE.md).

## Admitted surface and boundaries

- Admit BASIC Variant discriminator and canonical sparse-arm names within
  ordinary Array, Map, Tuple and legal Nullable compositions; retain default
  LowCardinality stop-sites and both explicit ordinary String profiles.
- Each Variant discriminator owns an eight-byte combined-mode prefix. Each
  LC dictionary owns its existing eight-byte prefix. Payload roles own zero.
- Preserve raw versus escaped prefix entry points, whole-basename hashing,
  collision rejection, detached exported Strings and shared operation budgets.
- Keep Object declared Variant/Dynamic, Dynamic extension rosters, specialized
  prefix files, COMPACT Variant, Compact parts and new public part facades
  rejected. Inspect all consumers before removing the common planner veto.
- Filename/mark qualification and borrowed stock envelope exchanges do not
  qualify an independent whole-part writer. No performance claim is made.

## Design laws

1. Canonical arm identity comes from the descriptor roster, not runtime values
   or arm counts. An empty arm remains a physical schema participant.
2. A Variant arm suffix is a literal dot followed by bytewise escaped SQL
   type spelling; it is not a Tuple field separator (`%2E`). Array nesting
   level is preserved across VariantElement: the snapshot's
   `ISerialization.cpp:309-362` increments only on ArrayElements, with no
   VariantElement reset. The stock nested-Array witness must corroborate it.
3. Validate descriptor and metadata budgets before proportional rosters.
   Preflight arm SQL spelling work before materializing names, then preflight
   the aggregate retained physical roster. Do not call unbounded `type.name`
   while pretending to perform allocation-free name sizing. W149 uses the
   existing conservative `BinaryTypeNameBudget` grammar for Variant-only
   SQL work rather than rewriting the generic descriptor renderer. Its
   auxiliary traversal and per-occurrence metadata are bounded; this is not
   an allocation-free or RSS certificate. Non-Variant W145 costs stay exact.
   `BinaryBulkVariantNamePlan` is an implementation helper, not a separately
   admitted public operation. Its direct-construction defensive checks do
   not aggregate descriptor/name-walk nodes across multiple direct helper
   instances or charge arbitrary repeated returned-prefix copies. The
   admitted `BinaryBulkPhysicalPlan` owns the shared descriptor accounting
   and final physical roster; do not transfer that certificate to direct
   helper calls.
4. Prefix ownership follows roles. Compressed file offsets, decompressed
   offsets and normalized bulk offsets are different coordinates. Capture the
   physical mark grid before prefix normalization; qualify their conversion.
5. Existing consumer boundaries remain explicit even when a shared planner
   becomes more capable. A successful logical codec is not facade admission.

## Execution order and Definition of Done

Root alone runs compiler, native ClickHouse and resource probes serially.
Luna authors bounded candidate changes; root independently inspects and tests.
Rollback is the exact atomic local commit; no remote push in this slice.

1. Source/consumer inventory, then focused literal specs on the unchanged
   production baseline. Observe behavioral RED from the existing Variant veto.
2. Implement the shared binder/prefix owner and necessary persisted-consumer
   guards without new per-arm or per-container class families.
3. Run focused DEBUG specs and affected RELEASE specs with the existing serial
   guarded compiler flags; require zero failures/errors/pending. Preserve the
   exact W145 non-Variant budget gates.
4. Execute fresh pinned-stock physical name/lane/complete-grid witnesses for
   recursive cases, both String profiles and LC-bearing sparse arms. Consume
   library-emitted physical lanes in fresh borrowed envelopes with actual
   stock ATTACH/CHECK and independent literal values plus a valid wrong-value
   control. If this gate is not executed, narrow the implementation seal.
5. Run complete recursive spec inventory in unique disjoint serial groups,
   formatter and diff checks; record that grouping is not a combined run.
6. Hostile review: escaping versus Tuple separators, nested array boundaries,
   empty arm marks, prefix/LC replay, shared budget one-short cases, name
   collision and mutation isolation. Seal only the observed scope.

## Falsifier roster

- Literal root and Array(Variant(LC(String), UInt64)) names/prefix ownership.
- Recursive Array/Map/Tuple/Nullable arm names and array-level boundary.
- Reserved/escaped named Tuple, Enum opaque labels and temporal type spelling.
- Exact-fit versus one-short depth/node/element/name budgets; shared contexts.
- Hashed whole names, raw percent, escaped-prefix validation and collisions.
- Public Object/Dynamic refusal after the common veto is removed.
- Stock full/selected values and complete physical mark coordinates; valid
  wrong-value sensitivity. No round-trip-only closure.

## Stop rules and next track

Do not widen to separate specialized prefix streams or COMPACT merely because
source enumeration mentions them. A discrepant physical fixture requires
attribution or a narrower explicit profile, not hiding a lane or offset.
After this prerequisite, separately qualify declared Object Variant and its
library-owned whole parts. Continue responsibility-level facade decomposition;
MV/projection and broader type/layout work remain in the overall goal.

## Implementation seals

Root behavioral RED on unchanged `d8087d8`: the new three-example literal
spec compiles and reports three `UnsupportedFormatError` errors at the
existing recursive Variant veto, with no unrelated failure. Command:
guarded `run_specs.sh red spec/binary_variant_physical_w149_spec.cr`;
scratch log `/private/tmp/crystal-click-w149.P105yD/red.log`.

Final root gates on 2026-10-04, over clean `d8087d8`:

- Focused DEBUG: 64 examples across nine files, zero failures/errors/pending.
- Affected RELEASE: 533 examples across 68 unique files together, zero
  failures/errors/pending.
- Complete recursive inventory: 2,452 examples across 381 unique files in
  sixteen serial disjoint non-release groups, zero failures/errors/pending.
  This is not a combined-process result. Group example counts are
  200/181/120/165/184/38/438/131/184/141/128/76/155/86/131/94.
- Final formatting check of ten affected Crystal files, shell syntax, Ruby
  syntax and `git diff --check` pass. Production/spec owners were unchanged
  between the spec gates and final stock execution; fixture-only corrections
  below preceded its final execution.

The source/spec/script fingerprint is
`84b532d635bded5db565542e5fa12b2ddb95206e5d4f947e1fe37e5ac86a9a65`.
It hashes twelve sorted relative paths as `path<TAB>file-SHA256<LF>`;
documentation is excluded. A fingerprint identifies evidence input, not proof.

The final native root is
`/private/tmp/crystal-click-variant-physical-w149.native-20261004-g`.
Six finite stock Wide fixtures cover `Variant(String, UInt64)`,
`Array(Variant(LowCardinality(String), UInt64))` and
`Array(Variant(Array(UInt8), UInt64))`, each under ordinary String 0/1.
The pin is runtime 26.10.1.1201, build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`, executable SHA-256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
The separate shallow source is `9007d227b64a3f8b667fc5258ceb2923f3cf477d`;
the runtime was not built from that checkout. No current-master executable
qualification is claimed.

Every fixture pins BASIC Variant, escaped subcolumn filenames, default LC
max dictionary 8192/single-dictionary false, UTC, one thread and adaptive
two-row marks. Root captures the complete `.bin`/`.mrk2` roster and every
physical mark before normalization: three real marks with rows 2/2/2 plus
the distinct terminal record. Root compares ordinary names/lane bytes and
coordinates, then binds role-owned prefixes: Variant mode-zero u64 is removed
once with mark offsets shifted by eight; the LC dictionary's existing u64
version-one prefix is retained, not prepended twice. Empty arms remain in the
roster with their actual empty/prefix-only lanes and complete marks. The
stock nested-array witness corroborates `size1` below a Variant versus
outer `size0`.

Library-emitted lanes replace the typed streams in six borrowed stock
envelopes; checksums are rebuilt and fresh stock ATTACH/CHECK succeeds.
All six stock and six exchanged stores pass exact nominal types and ordered
literal full/middle RowBinary. A separate root-owned Ruby oracle uses no
Crystal codec or manifest-derived expectation: 54 fresh stock queries recheck
those twelve tables and a valid wrong-value store. The 42-to-43 mutant passes
stock CHECK but differs from the original literals in both windows. This
establishes comparator sensitivity, not exhaustive corruption resistance.
The exchanges do not qualify an independently authored whole part or a new
public writer facade.

Fixture development failures are retained under fresh roots `a` through `f`:
two instrumentation compile errors (Digest API and nilable Bool), an artifact
stem containing `/`, legitimate zero-byte unused-arm handling in the checksum
bridge, and Ruby's overly narrow successful CHECK-output spelling. All were
instrument corrections, not production admission changes. The empty bridge
exception requires `.bin` and declared uncompressed size zero; nonempty lanes
retain strict decoding. Roots `f` and final formatted `g` pass native and Ruby
checks. Earlier failed roots are not counted as compatibility successes.

Scoped hostile verdict: ROBUST for the admitted planner and persisted-consumer
guards, based on root inspection and executed literal/budget/mutation/stock
falsifiers. Luna's review is correlated assistance, not the independent oracle.
Object physical plan, codec and file reader explicitly refuse declared
Variant/Dynamic after the shared planner veto is removed. W145 non-Variant
costs remain unchanged. Flat Variant exact admission 247/246 and shared
410/409, auxiliary walk 7/6, prefix mutation and name collisions discriminate
the intended accounting. The internal-helper limitation in design law 3
remains outside this certificate. No allocation-free, RSS, performance or
universal type-product claim is made.

Replay focused files: W145 physical LC; W147 Variant value and adversary;
W148 Variant bulk and adversary; both W149 specs; W146 declared Object LC
and consumers. Scratch `run_specs.sh` uses `--single-module --threads 1
--link-flags=-fuse-ld=ld --error-trace`, adds `--release --no-debug` for the
affected set, and partitions the complete sorted inventory by 24 files.
For native replay, set `W149_EXECUTE_AS_ROOT=YES`, `CLICKHOUSE_BIN`,
`CLICKHOUSE_SOURCE_ROOT`, `CRYSTAL_BIN`, and `W149_CHECK_ROOT` (a fresh absolute
`/private/tmp/crystal-click-variant-physical-w149.<suffix>` path), then invoke
`bash scripts/check_variant_physical_binding.sh`. Keep the root guard and run
`ruby scripts/recheck_variant_physical_binding.rb <root>`; its source/runtime
identities are pinned in the script, not supplied as positional arguments.
Both instruments refuse overwriting their existing output directories.

Scratch gate logs in `/private/tmp/crystal-click-w149.P105yD/` have SHA-256:

- `red.log`: `ca21bbf1d6d76516e7b51887fcceb38ce53d3abf1a30bb373302e0cd624b648f`;
- `green.log`: `c4bd4719beda7556f7ee4fd0449661d097cbd0d367ed4c474899a1d1776c6323`;
- `release.log`: `c3b8c4f96ee141275742eff804d1580501fd7dde61031b2994e19c29979292b6`;
- `full.log`: `9efba59b76cafc5a99f94fadad8d34878c6a2db12a623f6994d51a6a31795fef`;
- `format.log` (successful silent check): `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`;
- `native.log`: `8e898f122d1ff54261996799af8154f1edd10a7cb62db653d08e1ee29a264739`;
- `ruby.log`: `b0c261293c620381e512918423f13d2db69cfd88550d231056d637ffdbc6027f`;
- `release-inventory.txt`: `7256afde6984ac6b23e8da19bd35367619739b9d69924d601ffcf48f394f9c84`;
- `full-inventory.txt`: `19072264d7982a45eb3807092be2e97335be7701ac3a4223ee9566bd345acc0d`.

Within the final native root, curated result hashes are:

- `results/summary.txt`: `9415efb8be3b81ea942060ee95793d3d90cf5740c036fb1c78c584558ac49356`;
- `results/summary.tsv`: `3c3c1cf5e93e04ac383faddc731338f55e641e326750ddcfdbcb33619f3d1ef0`;
- `results/lane-grid.tsv`: `a59c38327fc04f9baa7dac7d27c8a05bc978d34c0ca1ec128394af5b7643c1af`;
- `results/lane-comparisons.tsv`: `fa492b25e2209c7d53625002f46b8975d58a76097ed6a62018f303c90b21024c`;
- `ruby-recheck/summary.txt`: `83012ca9c97abfd3a912394e1a0e270fbb06b3293d2b8dfa182a104d0bdf8d9c`.

Rollback by reverting the exact W149 atomic local commit. Evidence decays on
changes to descriptor/role naming, prefix ownership, budgets, consumers,
stock pin/profile or fixture expectations. Refresh the affected literal and
stock gates before widening the claim. Temporary logs/stores may disappear;
their hashes are an index, and reproducible committed instruments are the
refresh path. Next separately qualify declared Object Variant/whole parts,
while continuing behavior-preserving legacy facade extraction.
