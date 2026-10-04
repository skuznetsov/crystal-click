# Generic Variant value kernel frontier (W147)

Later transition: W148 implements the separately qualified normalized BASIC
recursive bulk codec in
[VARIANT_RECURSIVE_BULK_FRONTIER.md](VARIANT_RECURSIVE_BULK_FRONTIER.md).
That transition supersedes only the generic bulk refusal below; generic
physical binding, Object Variant/Dynamic and new public part profiles remain
closed. The following execution certificate describes the historical W147
source state, not those later bulk capabilities.

Status: VERIFIED within the paired logical descriptor/RowBinary profile below;
generic bulk, physical binding and Object admission remain closed.
Baseline: `6b9464d`, 2026-10-03. Risk: CAUTION (binary type/value grammar and
recursive nominal identity). Rollback: the exact scoped diff over this clean
baseline; one atomic local feature commit only after the relevant gates pass.
No remote push is authorized by this slice.

## Admitted transition

Add a reusable canonical `Variant` node to `BinaryDataType` and an explicit
arm-aware value surface to `BinaryValue`. Pair descriptor encoding/decoding
and known-type RowBinary value encoding/decoding, including NULL and legal
composition with the existing represented scalar/container grammar. Reuse the
existing recursive owners rather than adding a facade for each arm product.

Normal ClickHouse Variant construction sorts by complete SQL names, removes
duplicate types and elides direct Nothing alternatives. The resulting roster
has 1..255 arms; NULL is discriminator 255, not an additional declared arm.
Direct Nullable, LowCardinality(Nullable), Variant and Dynamic alternatives
are illegal. Arrays/Tuples/Maps containing those types are governed by their
own constructor rules, not a recursive prohibition on every descendant.
Nullable cannot immediately wrap Variant.

The local constructor must reject equal display names for unequal nominal
descriptors rather than silently losing identity. In particular, this library
retains Decimal wire width even when the displayed Decimal(P, S) name is equal.
Bool and UInt8 also remain nominally distinct. Incoming binary Variant rosters
must already be canonical: reordered, duplicated, Nothing-containing or
otherwise illegal rosters are rejected after bounded parsing of the complete
Variant roster (not necessarily its enclosing descriptor). This is a
deliberately stricter profile than upstream's normalizing binary decoder.
Fixed-discriminator-order internal Variant construction is not admitted here.

The owned API is `BinaryDataType.variant(arms, limits: ...)`,
`BinaryValue.variant(type, canonical_index, child)` and
`BinaryValue.variant_null(type)`. `variant_index?` and `variant_child?` return
nil for NULL, which is distinct from an empty selected Array/Map/Tuple arm.
The index refers to the normalized roster, not the caller's original order.

## Preserved boundaries

This is a paired logical codec prerequisite, not new whole-part support.
Generic Variant bulk discriminator/sparse-arm lanes, physical name binding,
declared Object Variant/Dynamic fields, new Dynamic arm profiles, table/catalog
dispatch and independent complete-part writers remain closed until separately
qualified. Existing exact Variant part profiles remain unchanged.
Borrowed Dynamic/shared-value envelope paths must not accidentally widen merely
because the public descriptor/value codecs learn a new tag. Retain explicit
recursive guards there until the storage transition has its own evidence.
Dynamic structure rosters also reject Variant-containing alternatives before
their SQL names are built. A direct Variant arm is source-illegal; rejecting
an Array/Tuple/Map containing Variant is the local deferred-storage profile,
not an asserted upstream constructor rule.

No arbitrary type-product, layout, MV/projection, allocator/RSS or speed-parity
claim follows from this transition. Optimization stays after paired type and
MV/projection compatibility work.

## Source and strongest failure

Source reference: separate unbuilt shallow checkout
`9007d227b64a3f8b667fc5258ceb2923f3cf477d` at
`/Users/sergey/SrcArchives/clickhouse-2026-10-03-depth1-9007d227`.
`DataTypeVariant.cpp:26-107` establishes normal versus fixed-order roster rules;
`:145-167` preserves custom-name equality; `DataTypeVariant.h:43` refuses
Nullable wrapping. `DataTypesBinaryEncoding.cpp:462-480,752-775` encodes the
0x2A roster and uses normalizing construction on decode.
`SerializationVariant.cpp:787-818` writes/reads a UInt8 global discriminator
followed by the chosen arm's value bytes.

Native oracle: 26.10.1.1201, build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`, SHA-256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
The executable is not asserted to be built from the source reference.
The source tag table is not monotonically additive: timezone-bearing Time
and Time64 descriptors were removed, leaving 0x33/0x35 reserved
(`DataTypesBinaryEncoding.h:62-77`). Existing source/runtime certificates
therefore remain versioned rather than assuming every former descriptor is
accepted by current master.
The native similar-numeric-arm witness requires
`allow_suspicious_variant_types=1`; the first default-setting DDL probe returned
Code 44 for UInt8/UInt64 ambiguity. Logical descriptor support does not imply
that default table DDL admits every represented roster.

The likeliest failure is canonicalization changing a discriminator's nominal
meaning, or allocating SQL names before aggregate admission. Reuse
`BinaryTypeNameBudget` for bounded recursive name work; constructor/decode
preflight and codec traversal must not reset an enclosing operation's budget.
Malformed tags, same-name unequal Decimal widths and same-width Bool/UInt8
are stronger discriminators than a self-roundtrip alone.

## Owner and consumer plan

1. Root executes a fresh literal stock probe and a behavioral RED before
   production edits. Luna authors tests and native probes without executing
   Crystal or ClickHouse. Source/runtime identities stay separate.
2. One Luna owns the generic descriptor/value production transition:
   `binary_data_type.cr`, `binary_data_type_codec.cr`, `binary_value.cr`,
   `binary_value_codec.cr`, `binary_type_name_budget.cr`, bounded context
   plumbing in `binary_codec_context.cr`, and only the necessary require in
   `src/crystal_click.cr`. A new cohesive roster-policy owner, if required,
   has its own file. Root first reviews its exact interface and consumer map.
3. A separate test owner adds W147 kernel/adversary specs and updates only
   superseded 0x2A unsupported-tag expectations. Bulk, borrowed-envelope,
   Object and public-part guards must remain executable tests.
4. The native owner supplies independently derived literal binary type headers
   and RowBinary values, stock consumption of library bytes and a valid
   wrong-value comparator control. An Object part discovery probe informs the
   next storage transition but is not substituted for library-part evidence.
5. Root independently reviews the production diff and actual outputs, executes
   affected RELEASE and the complete unique spec inventory in serial disjoint
   groups, format/syntax/diff checks and a scoped hostile review. Root alone
   executes resource-heavy commands under the host serial resource guard.

Bounded consumer inventory before production changes must cover descriptor
name/equality/hash/child traversal, type and value codecs, name budgets,
typed/borrowed envelopes, Dynamic structure/value owners, bulk role/default
owners and Object declaration/physical/public dispatch boundaries. Existing
bulk switches should refuse the new non-fixed-width node, not guess a lane.

## Required falsifiers and DoD

- Native canonical sorting/dedup/Nothing-elision and Bool/UInt8 type-header
  witnesses with literal expected bytes; NULL and at least two non-NULL arms.
- Behavioral RED, then paired descriptor/value tests for recursive arms and
  parents, absent arms, illegal wrappers, detached state, altered tags, invalid
  count/order/duplicates/Nothing, trailing/truncated and nonminimal input.
- Exact/one-short depth, nodes, elements and bytes, plus shared nested budgets
  and bounded name materialization before sorting or nominal equality.
- Independently literal stock RowBinary consumption in both directions;
  comparator sensitivity demonstrated with a valid wrong value, not just a
  malformed input rejected by an unrelated guard.
- Retained borrowed-envelope, generic bulk, Object and exact part-profile
  boundaries; source-reserved 0x33/0x35 tags remain rejected.
- Focused DEBUG, affected RELEASE and complete unique spec inventory pass
  with zero failures/errors/pending; formatting, syntax and diff checks pass.
  Grouped full-inventory execution is not combined-process verification.

The executed gates below qualify only the admitted logical profile.
Reopen the certificate if the roster policy, type/value/name owner,
source constructor/serializer, runtime identity or consumer contract changes.
Refresh with the same discriminating tests and fresh independent stock oracle.

## Executed prerequisite evidence (not kernel closure)

Root observed baseline behavioral RED: one example, zero failures, one error,
zero pending, with the old valid-but-unadmitted 0x2A refusal. The bounded runner
and log are under `/private/tmp/crystal-click-w147.TuAn7O`.

A separate minimal stock CAST probe normalized UInt64/String/Nothing/duplicate
UInt64 to Variant(String, UInt64), and matched all 20 literal binary-header and
NULL/String/UInt64 row bytes. Actual/expected files and SQL are in that same
root; byte SHA-256 is
`c6d33d81d0c7e2d9d4f9c7dc1a351308f72d521a8b5c8c5dfa61d4e008221ee3`.
An initial Ruby string-encoding comparison was corrected after independent
binary file comparison showed equal bytes; the final guarded run passed.

The fresh native discovery probe passed at
`/private/tmp/crystal-click-w147.TuAn7O-native03`: eight rows, four real
two-row granules, five system.parts marks including the terminal record, one
Wide part, an exact three-field CHECK TABLE success, six declared Variant
arms, nominal Bool/UInt8, NULL, nested Variant and Dynamic shared spill.
Actual and independent expected RowBinaryWithNamesAndTypes bytes have SHA-256
`e841cc0d94740dd21fe18b471dcd420b6623eeae91aa9441f8239ca339ed3d2e`.
Three source-backed direct-arm constructor rejection controls passed.
The earlier discovery failures exposed table-policy opt-in and incorrect test
expectations about Dynamic inference, not a library implementation regression.
These temporary artifacts are evidence pointers, not committed fixtures or a
claim of durability. They establish the stock format prerequisite only; the
paired library exchange is separately qualified below.

## Executed kernel certificate (2026-10-03)

Root executed all heavy commands serially through the host resource guard
(`COGNI_RUN_SAFE_MIN_FREE_PCT=50`, 32,768 MiB cap), over baseline `6b9464d`
and the exact production/test diff committed with this certificate:

- Focused DEBUG: 62 examples, zero failures/errors/pending, in the two W147
  specs plus W117 value, W141 LC and both W120 structure/budget specs.
- Final affected RELEASE: 503 examples, zero failures/errors/pending;
  64 unique files together in one process. The frozen inventory selects
  `binary|dynamic|object|variant|physical_stream|compressed_mark|part_stream`
  from all `spec/**/*_spec.cr` paths, then sorts uniquely.
- Complete inventory: 2,420 examples, zero failures/errors/pending;
  376 unique files in sixteen serial disjoint non-release groups of at most
  24 files. This is not combined-process verification. Root separately
  compared both executed inventories to the final file inventories.
- Formatting checks of all affected Crystal source/spec/checker files,
  Ruby syntax checks of both native drivers and `git diff --check` pass.

The bounded root runner/logs and inventories are under
`/private/tmp/crystal-click-w147.TuAn7O`: `run_specs.sh focused-final` with
the six spec paths below,
`run_specs.sh release 64` and `run_specs.sh full 376`. The runner uses
`crystal spec --single-module --threads 1 --link-flags=-fuse-ld=ld
--error-trace`; RELEASE adds `--release --no-debug`, grouped full execution
adds `--no-debug`. The full inventory is sorted from `rg --files spec
-g '*_spec.cr'`. Expected signals are the exact counts and zero failures,
errors and pending recorded above, not merely successful compilation.

```text
spec/binary_variant_value_w147_spec.cr
spec/binary_variant_value_w147_adversary_spec.cr
spec/binary_value_codec_w117_spec.cr
spec/binary_low_cardinality_w141_spec.cr
spec/object_dynamic_structure_w120_budget_spec.cr
spec/object_dynamic_structure_w120_spec.cr
```

Root built `scripts/check_variant_value_w147.cr` separately, then executed
`scripts/probe_variant_value_w147.rb` with `W147_EXECUTE_AS_ROOT=YES`, the
explicit `W147_VARIANT_CHECKER` path and a fresh `W147_VARIANT_OUTPUT` root.
The final exchange root is `/private/tmp/crystal-click-w147-kernel.Qf6tmK`.
Both the driver and checker pass: seven stock rows, seven rows consumed from
library-owned encoded descriptors/values and one valid UInt64 42-to-43 mutant.
The three profiles cover canonical String/UInt64, nominal Bool/UInt8 and
recursive Array/Map/named-Tuple arms and parents, including LC inside Tuple,
NULL, an empty selected Array, UInt16/UInt32 extrema and Unicode.
All four complete library inputs and fifteen complete stock outputs match
independently authored literal headers and value bytes. The checker parses
the actual captured descriptor, checks recursive nominal values and re-encodes
the payload. NULL Variant has neither selected index nor child. The stock
accepts the 43 mutant; its literal output differs from the independently
asserted 42 output, and the typed comparator rejects 43 as 42.

Root independently rechecked the final evidence census: 160 input/result
files, 13,563 bytes and 44 stock queries, excluding scratch table stores.
Canonical/nominal/recursive library-input SHA-256 values are respectively:

```text
0d6b8555cf9c0555952b499e99f9a123d9d0af49c3757d689e3b73cfd2444755
39fe612cd4fe4355bde993b37be451b98d44e9150dd1af5e0a408872c1aad4d5
60d14ccea984ef631b6a7fa3ba3ac9084d5eeae25a9cca200d6bf8b1bad49065
```

The original/mutant stock bytes are exactly
`0101762a021504012a00000000000000` /
`0101762a021504012b00000000000000`. The committed probes/literals support a
fresh replay; temporary captures are not a durable-fixture guarantee.

Harness corrections are confined to the oracle: scratch MergeTree instead of
Memory for separate local processes; exact named-Tuple CAST before Variant
conversion; canonical one-line type formatting; explicit return of already
literal-checked output bytes. A stock-only cause probe reproduces Code 70 for
the original unnamed Tuple and accepts the exact named arm. Pinned source
`FunctionsConversion.cpp:2220-2227` selects arms by the source type's name.
No library codec or expected wire literal was changed to accommodate these
harness failures.

Root's hostile verdict is ROBUST within this logical profile: full literal
wire comparison, the valid wrong-value control, 255-arm/NULL separation,
nominal collisions, truncations and shared-budget boundaries discriminate
the highest-risk errors. Recursive borrowed/shared-MAP, Dynamic structure,
generic bulk and Object declaration refusal tests pass; the existing exact
public part profiles remain unchanged. Luna's static reviews are correlated
candidate evidence, not independent execution or another native oracle.
This certificate does not qualify physical LC lanes, arbitrary Variant parts,
Object Variant/Dynamic, MV/projections, performance or the unbuilt fresh source
as an executable. The decay/refresh rules above retain those boundaries.

## Next storage transition (not admitted by W147)

Qualify generic bulk discriminator and sparse-arm scheduling before physical
binding or declared Object Variant/Dynamic admission. The pinned source's
`SerializationVariant.cpp:301-370,538-650` separates BASIC/COMPACT discriminator
framing, counts each non-NULL arm's occurrences and consumes that arm's nested
streams by its own count. Ordinary parent row counts cannot be applied to all
arms. LC dictionaries inside an arm must follow that sparse schedule, including
empty arms and mark-window replay; RowBinary's single selected child does not
establish that behavior. Keep the existing generic bulk and persisted-envelope
guards until their own paired native falsifiers pass.

The missing shared responsibility is a per-mark occurrence schedule, not a
class per arm/container product: Array/Map shape lanes transform parent
counts; Tuple/Nullable preserve them; Variant discriminators split them by
arm, with NULL assigned to no arm. The LC all-mark census must consume that
same schedule even when ordinary values select only a mark window.

Proposed native falsifier, not executed or admitted here: BASIC Wide storage
for `Array(Variant(LowCardinality(String), UInt64))`, two rows per granule.
Rows `[LC("A"), UInt64(7)]`, `[NULL]`,
`[UInt64(9), LC("B"), LC("A")]`, `[LC("A")]` yield flattened counts 3/4,
UInt64 sparse counts 1/1 and LC sparse counts 1/3. These counts discriminate
parent-row offsets from flattened/compact-arm offsets. Add an empty-arm mark
and a selected middle-window control before widening physical admission;
COMPACT discriminator framing remains a separate qualification.
