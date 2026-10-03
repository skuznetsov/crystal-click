# Recursive LowCardinality bulk frontier (W143)

Status: implemented and VERIFIED within the scope below, 2026-10-03.
Baseline: `5bb9b83`.
The active objective remains paired ClickHouse type coverage, MV/projection
inspection and interoperability, followed by memory/performance work. This
slice does not close that objective or assert complete-part compatibility.

## Current boundary and intended transition

W142 provides the bounded standalone dictionary/index codec described in
[LOW_CARDINALITY_BULK_STORAGE_FRONTIER.md](LOW_CARDINALITY_BULK_STORAGE_FRONTIER.md).
At the baseline, ordinary recursive `BinaryBulkCodec` rejects LC at every
depth. W143 moves that ordinary, decompressed, role-addressed bulk boundary
only.

Paired admission: LC roots and LC leaves inside existing legal
Array, Tuple, Map and Nullable compositions, over W142 eligible represented
non-floating scalar children, including LC(Nullable(T)). LC dictionaries
remain scalar length-prefixed streams independently of the ordinary String
profile. Both ordinary SingleStream and WithSizeStream profiles are tested.
Map keys must remain non-nullable, including through LC.

Float32, Float64 and BFloat16 LC sites remain paired guard-only in this slice,
including empty inputs. Source `ColumnUnique::uniqueInsertRangeFrom` compares
against the default and canonicalizes NaNs, while `uniqueInsertData` uses
raw-byte default comparison and deserialized dictionaries have another
preservation boundary (`ColumnLowCardinality.cpp:432-438`). W142's raw-payload
dictionary identity is not a blanket insertion contract. A native raw-bit
discriminator and a matched writer
policy/part oracle are the next required transition, not an optional omission.
Standalone W142 raw Float transport and the nominal row-value kernel are not
removed or reinterpreted by this guard.

Still rejected: persisted Object/Dynamic envelopes containing LC, generic
part lane binding through `BinaryBulkPhysicalPlan`, complete standalone parts
with these recursive LC declarations, split index records within one mark,
and any profile rejected by W142. Do not infer those capabilities from the
generic role planner or a Native framing conversion.

## Design laws

1. Each syntactic descriptor path owns an independent LC dictionary/index
   state. Reusing the same descriptor object at two Tuple positions must not
   share its dictionary. No per-type/container Cartesian class family.
2. The shared W142 physical owner retains versions, flags, ID widths, reserved
   slots, dictionary updates and corruption checks. Generic traversal does
   not charge or decode an LC value subtree a second time.
3. Root occurrence counts come from rows per mark. Tuple and Nullable preserve
   physical child counts; Array and Map flatten size-lane sums recursively.
   A NULL Tuple still has physical default children; an empty Array does not.
   Validate counts, checked arithmetic, depth and proportional staging limits
   before their count-derived arrays or hidden large defaults. Preflight is
   phase-local: ordinary lanes may already be allocated when the LC site
   owner rejects a later aggregate staging/dictionary bound. These bounded
   failures are not an all-operation-before-any-allocation or RSS guarantee.
4. Decoder restores every LC site's state over all marks and validates all
   required ancestor size lanes, including outside a selected middle window.
   Unrelated ordinary payload remains selected-only. Charge the union of
   inspected structural/LC bytes and selected ordinary payload exactly once.
   This is bounded replay, not lazy storage I/O or an RSS guarantee.
5. Ordinary lane grids start at zero. LC dictionary grids start after their
   version prefix and may repeat. Do not apply ordinary interval slicing to
   dictionary coordinates. Every role and K+1 grid remains exactly bound.
6. Shared budgets distinguish parent container edges, LC logical subtrees,
   dictionary/ID work and staging metadata. Prepaid bytes must never acquire
   another charge when handed to a child context. Conservative extra work
   bounds must be identified rather than described as exact output counts.
   Root LC aliases caller mark/value grids and leaves their accounting to
   W142. Nested encoder staging adds N borrowed value-reference elements and
   K mark-bucket metadata nodes/elements per site. Encoder occurrence census
   adds K count metadata nodes/elements per LC site; decoder shape census
   instead adds K count metadata nodes/elements per distinct Array/Map
   ancestor, with both Map children sharing that ancestor vector. These are
   staging records, not extra
   LC value-tree visits. The literal two-mark [a,a]/[b] root LC witness must
   equal standalone W142 at 19 nodes, 18 elements and 56 lane bytes; wrapping
   one Array row per mark gives 31 nodes, 34 elements and 72 bytes under this
   accounting law. Exact and one-short tests establish these totals below.
7. Existing no-LC behavior and the explicit Object/Dynamic/part guards remain
   unchanged. Role-plan widening is not persisted-layout widening.

## Execution plan and recovery

Risk: CAUTION (recursive serialization and shared accounting).
Recovery: preserve the clean `5bb9b83` baseline and make one atomic local
commit only after root-owned gates pass. No remote push or history rewrite.
Root owns this document, review, compiler/native execution and the commit.
Luna owns bounded spec, implementation and oracle subtasks with disjoint
paths. All edits use apply_patch; execution is serial and memory guarded.

1. Add black-box falsifiers in
   `spec/binary_low_cardinality_bulk_w143_spec.cr`; observe the existing LC
   refusal as RED before production changes.
2. Extend `BinaryBulkTypePlan`, `BinaryBulkDefaultValue`, the recursive
   encoder/decoder and cohesive per-operation LC occurrence/state owners.
   Keep the W142 physical grammar centralized. Update the loader explicitly.
3. Update only obsolete ordinary-bulk refusal assertions in W141/W142 tests;
   preserve Object/Dynamic/physical binding refusals and Float guard tests.
4. Add a full-container oracle in
   `scripts/check_low_cardinality_bulk_w143.{cr,sh}` using retained W141
   native Array/Map/Tuple witnesses and literal complete logical vectors.
   Compare ordinary structural/sibling bytes as well as LC bytes and grids.
   Stock consumption is separately framed and cannot be relabeled ATTACH.
5. Format, freeze implementation/specs, run focused DEBUG, affected RELEASE,
   all unique spec files in disjoint serial groups, and native/comparator
   controls. Root reviews the highest-risk count/budget/ownership paths.

## Definition of done and falsifiers

Root command family (isolated cache, Darwin linker, one compilation thread):

```
COGNI_RUN_SAFE_MIN_FREE_PCT=50 RUN_SAFE_PASSTHROUGH_STDIO=1 \
  /Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh \
  /bin/bash 900 32768 <isolated-runner> <phase> <spec-paths...>
```

Expected: terminal exit zero, declared inventory counts reconciled, no
failures/errors. Full-inventory grouping is not a combined-process certificate.
Native source reference is fresh shallow checkout
`9007d227b64a3f8b667fc5258ceb2923f3cf477d`; executable provenance remains
the separately pinned W142 runtime, not that unbuilt checkout.

Required discriminators: root and recursive LC; repeated descriptor at
distinct paths; flattened counts unlike root counts; nested/all-empty marks;
LC nullable values and legal LC keys; nullable Tuple hidden defaults; both
String profiles; selected-window state replay; corruption in an unselected
LC/ancestor lane; irrelevant unselected ordinary payload preservation; missing,
extra and cross-bound roles; UInt64 maximum size/count overflow; aggregate
one-short shared limits; detached outputs; no duplicate LC logical charges;
Float guard even with no occurrences; inherited Object/Dynamic/physical-plan
guards. Native comparisons require literal vectors and a seeded mismatch
that the comparator actually rejects.

The likeliest failure is binding LC counts to outer rows, or counting a child
again during composition. The cheapest checks are unequal Array/Map sizes,
two independent Tuple sites and a shared-budget exact/one-short boundary.
No green self-roundtrip can replace the native structural/LC byte comparison.

## Evidence and continuation

Initial RED: `red-r2.log` under `/private/tmp/crystal-click-w143.6rBxiD`
records the Array(LC(String)) probe failing with `unsupported binary bulk
DataType`, terminal exit 1, before production changes. The earlier `red.log`
was a `crystal eval` command-line error and is not feature evidence.
The subsequent `guard-diagnostic-r1.log` records one cached-membership and
Dynamic/Object/physical-guard example passing, terminal exit 0. It is a
diagnostic before recursive implementation, not the final W143 certificate.
Evidence decays if occurrence rules, shared
budget ownership, W142 grammar or the pinned native fixture/runtime change.
Refresh with the focused adversaries and full recursive native oracle.

### Implemented ownership boundary

`BinaryBulkTypePlan` owns syntactic LC sites and distinct Array/Map ancestor
size-role rosters. `BinaryBulkLowCardinalitySiteEncoder` and
`BinaryBulkLowCardinalitySiteDecoder` each have their own file and own the
write occurrence staging and read shape census respectively. They delegate
all dictionary/index grammar to W142. The existing generic encoder/decoder
visit ordinary parents and siblings only; no new branch is added to the large
legacy WidePart reader/writer/table/catalog facades.
The W142 owners' `*_prevalidated` methods are internal composition seams:
their caller must already have validated and charged the complete descriptor
tree under the same budget. Public codec entrypoints retain that validation;
direct use of an internal seam is not the public bounded-codec contract.

`BinaryDataType` caches immutable LC membership at construction. This cheap
membership check does not replace bounded descriptor validation. Explicit
ObjectDocumentCodec, DynamicValueCodec and BinaryBulkPhysicalPlan guards
prevent recursive bulk admission from leaking into unqualified persisted
consumers, including manually constructed schemas and empty selections.

### Executed root certificate

All Crystal/ClickHouse execution was serial and root-owned through
`run_safe.sh`, with a 50% free-memory floor, 32,768 MiB tree RSS cap, isolated
cache, macOS 26.5 SDK, `--single-module --threads 1`, and Darwin linker
`--link-flags=-fuse-ld=ld`. No worker executed a compiler or native process.

Evidence root: `/private/tmp/crystal-click-w143.6rBxiD`.

| Gate | Observed result |
| --- | --- |
| Focused DEBUG, 8 files | 80 examples, zero failures/errors/pending, exit 0 (`focused-debug-final.log`) |
| Affected RELEASE, 29 files | 255 examples, zero failures/errors/pending, exit 0 (`affected-release-final.log`) |
| Complete inventory | 2,375 examples, 370 unique spec files, 16 disjoint serial non-release groups, exit 0 (`full-inventory.log`) |
| Post-review focused DEBUG | Same 80 examples, exit 0 (`focused-debug-post-review-r2.log`) |
| Recursive native oracle | Three full container lane/grid matches, six baseline/profile Native consumers and one valid wrong-output control, exit 0 |
| Independent Ruby output check | Seven retained stock outputs / 63 exact literal type and RowBinary rows, empty stock stderr, exit 0 |

The complete inventory's sorted `full-spec-inventory.txt` has 370 unique
entries, matches the live inventory, and the 16 observed example totals sum
to 2,375. This is neither a combined-process nor full-inventory RELEASE
certificate. Focused files are W143, W142 storage, W141, binary bulk W122,
bulk budget W122 adversary, bulk nominal W122, bulk String size W122, and bulk
Dynamic W122 adversary. The RELEASE set is the exact 28-file W142 RELEASE
set listed in [LOW_CARDINALITY_BULK_STORAGE_FRONTIER.md](LOW_CARDINALITY_BULK_STORAGE_FRONTIER.md)
plus `spec/binary_low_cardinality_bulk_w143_spec.cr`.

Executed full and post-review commands (under the guard family above):

```sh
runner=/private/tmp/crystal-click-w143.6rBxiD/run_specs.sh
/bin/bash "$runner" full 370
/bin/bash "$runner" focused-debug-post-review-r2 \
  spec/binary_low_cardinality_bulk_w143_spec.cr \
  spec/binary_low_cardinality_storage_w142_spec.cr \
  spec/binary_low_cardinality_w141_spec.cr \
  spec/binary_bulk_w122_spec.cr \
  spec/bulk_budget_w122_adversary_spec.cr \
  spec/bulk_nominal_w122_spec.cr \
  spec/bulk_string_size_w122_spec.cr \
  spec/bulk_dynamic_w122_adversary_spec.cr
```

The full invocation used `run_safe.sh /bin/bash 900 32768`; its terminal
guard returned exit 0 after approximately 404 seconds. Exact budget tests
establish root LC/W142 parity at 19 nodes / 18 elements / 56 bytes and nested
Array encode at 31 / 34 / 72; independent one-short node, element and byte
limits fail closed on encode and decode. Other falsifiers cover repeated
descriptor paths, two independent Map LC sites sharing one ancestor vector,
zero/all-empty selections, nested Array schedules, hidden nullable Tuple
defaults, UInt64-max sizes, unselected LC corruption and unaffected
unselected ordinary payload.

The implementation/spec seal during DEBUG, RELEASE and full inventory was
`26e257506c44880bb11bebbaa42bd3882078c4d61a4a64e1e66d1f396b5bf3a5`.
After those gates, root changed only the encoder's preflight comment, not
production behavior or specs. It now states phase-local ordinary/LC
preflight instead of falsely promising complete preflight before every
allocation. The post-review DEBUG and successful native oracle use final
`src` + `spec` seal
`d01bbb546e1f299a107b580f019c1470496f245afacac922c07011f41cd4333a`;
final `src` + `spec` + `scripts` seal is
`0954f79f0887f629e7b7611b142d0157da3fb2d4d7d9e3b6e9b26a8640b33b6e`.
These are SHA-256 of sorted `rg --files` per-file SHA-256 output, excluding
documentation. Earlier script seals are retained but not final certificates.
Final `crystal tool format --check` on every changed Crystal file, shell syntax
checks for the runner/oracle, and `git diff --check` all return exit 0.

The first focused invocation after that comment correction named a missing
spec file and did not execute tests; `focused-debug-post-review.log` is not
feature evidence. Initial failed DEBUG's Array-size assertion was corrected
from [1,1] to the independently required [2,1] flattened counts. These harness
and expectation corrections are not stock storage incompatibilities.

### Native qualification and adversary

Fresh output root:
`/private/tmp/crystal-click-object-low-cardinality-w143.6rBxiD-03`.
The driver `scripts/check_low_cardinality_bulk_w143.sh` ran with
`W143_EXECUTE_AS_ROOT=YES`, retained
`W141_PROBE_ROOT=/private/tmp/crystal-click-object-low-cardinality-w141.tmcuJP`
and that new `W143_CHECK_ROOT`, under the same serial guard. It preserves
`check.log`, role bytes and grids, Native inputs, identity record and seven
stock TSV/stderr outputs. Retained native outer row counts are [4,4,1];
Array/Map LC occurrences are [5,5,1], Tuple LC occurrences [4,4,1]. Ordinary
size/sibling lanes and both dictionary/index roles match literal bytes and
retained native decompressed lanes; dictionary coordinates repeat at byte 8.
Full and selected-middle reads match independent complete logical vectors.
Recursive schema/value admission is broader than these three finite native
witnesses. In particular, two LC Map key/value sites are covered by codec and
budget specs; the exact native Map witness uses an ordinary String key and
an LC String value. This is not exhaustive stock qualification of every
admitted leaf/container combination.

The Native adapter consumes actual encoded lanes, not regenerated logical
payload. It converts per-row Array/Map sizes to cumulative Native offsets,
ordinary WithSize String lanes to VarUInt strings, and global LC records to
one additional-only Native dictionary/index record, retaining recursive
prefix order. Six baseline/profile consumers return exact nominal types and
RowBinary. A valid LC ID 1->2 mutation changes precisely the first authored
array item (`red` to `blue`) and stock returns that exact changed vector;
the unmodified-vector comparator rejects it. Three corruption controls
reject missing LC index roles, index occurrence/payload mismatch and ancestor
size/flattened-count mismatch. All-empty nested middle selection retains its
two parent rows despite zero index bytes.

Runtime is ClickHouse 26.10.1.1201, build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`, executable SHA-256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
The source reference is the separate shallow checkout at
`9007d227b64a3f8b667fc5258ceb2923f3cf477d`, not this executable's build
provenance. Root traced Native prefix/body behavior in NativeWriter and
LowCardinality/Array/Tuple/Map serializations. This oracle does not bind
retained Object sidecars, directly send global framing to Native, independently
validate compressed checksums, or perform new part ATTACH/CHECK operations.

Attempts `...-01` and `...-02` remain retained: the first rejected its own
now-populated compiler-cache directory; the second's comparator mistakenly
treated an empty Array as scalar bytes. Neither reached a stock Native
consumer. Correcting the fresh-output guard and matching by explicit container
tags produced `...-03`; these failed attempts are not native admission evidence.
Root's separate Ruby checker at
`/private/tmp/crystal-click-w143.6rBxiD/manual_rowbinary_check.rb` rechecks all
63 stock rows from independent literal vectors without any Crystal codec;
`manual-rowbinary-check.log` records exit-zero output.

Hostile verdict: ROBUST for this non-floating ordinary recursive bulk
composition and its explicit fail-closed persisted guards. Luna's static
review is correlated, not an independent runtime certificate. Root's actual
gates, native asymmetric byte/vector checks, controlled mismatches and separate
Ruby comparator supply the discriminating evidence. An all-operation
allocation preflight, complete part, arbitrary Object/Dynamic, Float insertion
identity or performance closure claim remains VULNERABLE and is not made.

Next after this slice: qualify stock Float LC insertion identity, then integrate
the recursive LC owner into persisted normalized Object and complete parts;
continue remaining types/layouts and MV/projection inspection before speed
optimization. User-requested modularity remains a responsibility-level rule,
not a count of generated files.
