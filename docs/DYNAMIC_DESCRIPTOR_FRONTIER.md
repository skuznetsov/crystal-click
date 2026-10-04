# Nominal Dynamic descriptor frontier (W152)

Status: VERIFIED within the nominal descriptor and retained-admission scope
below, after behavioral RED over clean `8ee0777` and root-executed gates.
This is a prerequisite for declared Dynamic inside Object, not a replacement
for that storage transition or the full type/MV/projection objective.
Risk: CAUTION (binary descriptor grammar and recursive consumer admission).
Rollback: one atomic local feature commit, separate from metadata extraction;
no push.

W153 supersedes only this checkpoint's generic logical-value rejection; see
[DYNAMIC_VALUE_KERNEL_FRONTIER.md](DYNAMIC_VALUE_KERNEL_FRONTIER.md). The W152
descriptor identity and retained stored/bulk/physical/Object guards remain the
boundary. Historical W152 execution results below are not rerun claims.

W154 separately admits recursive Dynamic/Variant-containing ordinary roster
metadata and occurrence-specific structure planning; see
[DYNAMIC_BULK_STRUCTURE_FRONTIER.md](DYNAMIC_BULK_STRUCTURE_FRONTIER.md).
It supersedes the historical blanket metadata refusal below, not the legacy
value, bulk, physical or declared-Object fences. Direct Dynamic/Variant,
Nothing, Nullable and LC(Nullable) ordinary arms remain refused.

## Admitted transition

Represent `Dynamic(max_types=N)` as an immutable nominal BinaryDataType leaf,
with 0 <= N <= 254 and default N=32. The canonical name of the default is
`Dynamic`; other caps render as `Dynamic(max_types=N)`. Equality and local
hashing retain N. Pair descriptor encode/decode as exactly `0x2B<uint8 N>`.
The cap is not a concrete arm roster, and Dynamic has no descriptor children.
Legal descriptor parents recurse through existing Array/Tuple/Map policies;
Nullable may contain a legal Tuple containing Dynamic, but not Dynamic
immediately. Direct Variant(Dynamic) and LC(Dynamic) remain illegal.
Name preflight must account for parameterized names, with unchanged aggregate
depth/node/element/byte budgets. Descriptor decode is exact-consumption.

The local normal-type profile rejects cap 255. Source factory bounds and the
raw binary decoder are distinct: upstream's binary decoder constructs a
DataTypeDynamic from its byte without enforcing the factory cap at that point.
Do not claim identical malformed-input acceptance with that decoder.

## Preserved rejected and guard-only surfaces

Generic Dynamic RowBinary values, bulk lanes, recursive Dynamic alternatives
inside existing stored Dynamic rosters/shared envelopes, declared Object
Dynamic and new whole-part profiles remain rejected until paired state/value/
physical evidence exists. Existing standalone Dynamic part/value support is
unchanged. Empty containers must not bypass these guards. Cache an immutable
contains_dynamic composition fact, like the existing LC/Variant facts, and
guard the generic value/bulk and Object admission entry points before the
relevant materialization or name construction.
No Compact/profile/version, MV/projection, allocation or speed claim follows.

The LC site encoder/decoder helpers consume a caller-supplied, already planned
site roster. They are not complete bulk-admission APIs: an empty site roster
still returns an empty sidecar map without inspecting the root descriptor, and
nonempty calls qualify only those LC sidecars. W152 does not promise rejection
from every directly callable helper. The generic BinaryBulkCodec/Encoder/
Decoder routes reject recursive Dynamic through BinaryBulkTypePlan before
using these helpers; their partial/no-op result does not establish a Dynamic
value lane or a complete persistable Dynamic-containing stream set.

## Source anchors and strongest failure

Reference: separate unbuilt shallow `7f568d607755c5dcebd48d8eacb17ad745d34c21`.
`DataTypesBinaryEncoding.h:54,132` and `.cpp:471-480,765-770` give tag/cap
transport. `DataTypeDynamic.h:15-39` and `.cpp:44-54,68-101` give default,
canonical names, equality and factory eligibility. SerializationDynamic's
single-value envelope and its part structure/roster are separate from this
nominal descriptor; neither supplies the declaration cap implicitly.
The local ordinary nominal hash follows equality and retains the cap. It is
not upstream's separate hash-calculation binary encoding, which deliberately
omits the cap suffix; no cross-language hash identity is claimed.

The strongest failure is a legal descriptor being mistaken for a qualified
storage lane, particularly an empty Array/Tuple/Map containing Dynamic.
Another discriminator is cap 128: its suffix is one byte, not VarUInt.
All new guards must have a positive neighboring control and a valid nominal
Dynamic witness, rather than rejecting only malformed descriptor bytes.

## Owner plan, falsifiers and DoD

1. Root inventories descriptor/value/name, borrowed envelopes, Dynamic
   structure/value, generic bulk/physical/default and Object consumers with
   `rg -n 'contains_variant|contains_low_cardinality|case type.tag' src`.
   Luna reports the exact consumer map before production edits.
2. A test owner adds `spec/binary_dynamic_descriptor_w152_red_spec.cr` using
   only existing decode/encode/name APIs. Root observes behavioral RED for
   literal `2B 20`, not a missing constructor method. Separate kernel/guard
   specs cover every cap, identity, wrappers, truncation/trailing/255,
   byte-vs-VarUInt, exact/one-short limits and bounded names.
3. Production owner updates `binary_data_type.cr`, `binary_data_type_codec.cr`,
   `binary_type_name_budget.cr`, `binary_variant_roster.cr` and only inventoried
   necessary consumer guards. Do not embed physical state in the descriptor
   or add a facade for each product. New cohesive owners get separate files.
4. Native owner authors `scripts/check_dynamic_descriptor_w152.rb` and a small
   Crystal descriptor-emission driver. Root alone executes resource jobs.
   Independent literal stock headers qualify all 255 normal caps; stock must
   consume library-generated descriptor headers, and a valid wrong-cap
   mutation must be detected. Source/executable identities stay separate.
5. Root independently inspects the diff and gates, runs focused DEBUG, affected
   RELEASE and the complete unique spec inventory in serial bounded groups,
   formatter/Ruby syntax/diff checks and hostile review. Expected signal:
   zero failures/errors/pending; legal descriptor positives and explicit
   retained-storage refusals; stock/library bytes and nominal types agree.

The baseline RED ran under the root resource guard: two examples, two
UnsupportedFormatError errors, both reporting valid-but-not-admitted `0x2B`.
The source/consumer audit distinguished cached composition facts from payload
support. Its minimal guard owners are BinaryValueCodec entry points,
BinaryBulkTypePlan construction, DynamicStructure construction/decode,
DynamicValueCodec borrowed trees, and the Object codec/physical/file-reader
typed preflights. The closed Object schema/parser whitelist remains unchanged.
`spec/dynamic_descriptor_consumer_guards_w152_spec.cr` owns empty-container,
NULL, borrowed-envelope and manually supplied Object-schema refusal witnesses,
with supported neighboring controls.

Root uses the serial `cogni-ml/scripts/run_safe.sh` guard, at least 50% free
memory, isolated cache and `--single-module --threads 1 --link-flags=-fuse-ld=ld`.
No peer compilers/ClickHouse jobs are authorized. This spec and PROJECT_STATUS
are the slice ledgers; no TODO/CHANGELOG/LANDMARKS file was found in the root
inventory. Refresh on descriptor/guard/budget/runtime/source changes.

## Execution seal (2026-10-04)

The existing-API RED has two examples, zero failures, two errors and zero
pending on the unchanged baseline. Both errors identify valid but unsupported
tag `0x2B`; this is not a missing-factory compilation failure.

Final focused DEBUG passes 123 examples together over these sixteen files,
with zero failures/errors/pending:

```text
spec/binary_dynamic_descriptor_w152_red_spec.cr
spec/binary_dynamic_descriptor_w152_spec.cr
spec/dynamic_descriptor_consumer_guards_w152_spec.cr
spec/binary_value_codec_w117_spec.cr
spec/binary_scalar_types_w119_spec.cr
spec/object_dynamic_structure_w120_spec.cr
spec/object_dynamic_structure_w120_budget_spec.cr
spec/dynamic_values_w122_spec.cr
spec/dynamic_values_w122_adversary_spec.cr
spec/binary_bulk_w122_spec.cr
spec/bulk_dynamic_w122_adversary_spec.cr
spec/physical_stream_plan_w125_spec.cr
spec/object_documents_w123_spec.cr
spec/object_documents_w123_adversary_spec.cr
spec/object_declared_variant_w151_spec.cr
spec/binary_bulk_physical_prefix_w151_spec.cr
```

Replay these paths with `crystal spec --single-module --threads 1
--link-flags=-fuse-ld=ld --error-trace` under the serial root resource guard.
The new kernel/guard specs cover all 255 normal caps, canonical names,
identity, recursive composition, exact and one-short budgets, malformed
wire forms and cause-specific retained-storage refusals with supported
neighboring controls. Empty Array/Map, NULL-containing Tuple/Variant, borrowed
values, zero-window bulk/Object and a forged default-cost cache hit cannot
admit a Dynamic lane. The default-value guard runs before cache lookup.
Object file-reader typed validation precedes per-path names and part lookup,
but unrelated column-prefix preflight still happens earlier; no global
zero-allocation claim is made.

Affected RELEASE passes 773 examples across 134 unique files in six serial,
disjoint groups. A separately executed metadata-extraction RELEASE regression
passes six examples in `spec/wide_part_metadata_parser_refactor_spec.cr`.
The total is therefore 779 examples across 135 unique files in seven
disjoint processes, not 779 in the six-group batch. RELEASE adds
`--release --no-debug` to the focused flags. The complete current inventory
passes 2,500 examples across all 391 unique spec files in 28 serial, disjoint
non-release groups, each using `--no-debug`. Every gate reports zero
failures/errors/pending. This is not a combined-process test run, nor a
runtime allocation or speed measurement.

Root's wx-only suite runner checks exact inventory coverage, no overlap,
successful exit and reported counts, and rechecks the unchanged source state
before/after every group. The SHA-256 of all sorted `src`/`spec` file paths
and bytes, each NUL-separated, is
`626e09a62439b0ff16d2ec905fc91f38dbf7311d2a35c14753a65fece35dfcd9`.
The captured evidence root is `/private/tmp/crystal-click-w152-root.gZOck7/`:
`run_suites.rb`, `suite-source.sha256`, `affected-groups.tsv`,
`affected-summary.tsv`, `affected-01.log` through `affected-06.log`,
`inventory-groups.tsv`, `inventory-summary.tsv`, and `inventory-01.log`
through `inventory-28.log`. Root independently recomputes coverage, counts
against those logs and the source fingerprint after the final group. Focused
DEBUG and the separate metadata RELEASE result are observed tool outputs;
no persisted log is asserted for them.

### Independent native descriptor witness

Root executes `ruby scripts/check_dynamic_descriptor_w152.rb --scratch
/private/tmp/crystal-click-w152-root.gZOck7/native.EZd9IU` under the same
serial guard. The checked-in Crystal driver calls the actual factory and
descriptor encoder/decoder for every cap and wrapper; Ruby supplies independent
literal wire expectations. Six fresh stock queries pass all 255 normal caps
and four finite Array/Tuple/Map/Nullable-Tuple wrappers. Stock writes exact
headers and infers exact nominal types from both stock and library headers
via `file(..., RowBinaryWithNamesAndTypes)`, without an explicit input schema.
A valid library-generated cap-32-to-cap-33 mutation changes exactly the
observed `d32` type. The successful evidence is in that scratch root's
`results/summary.txt`, `results/pins.txt`, emitter outputs and `results/stock/`
query SQL/stdout/stderr. The row body is borrowed from stock's typed NULL
witness. This qualifies descriptors, not library Dynamic values, bulk lanes,
whole-part writing, ATTACH or CHECK. Variant recursive composition has local
factory/cache/encode/decode witnesses, not this four-wrapper native witness.

Runtime: ClickHouse `26.10.1.1201`, build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`, executable SHA-256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
The executable is
`/private/tmp/crystal-click-w144-runtime-recovery.Pm8VNb/clickhouse-stripped`.
The separate unbuilt shallow source is
`/Users/sergey/SrcArchives/clickhouse-2026-10-04-depth1-7f568d60` at
`7f568d607755c5dcebd48d8eacb17ad745d34c21`; its checkout remains clean.
It is not asserted to be the executable's build provenance.

The Ruby and Crystal oracle scripts respectively have SHA-256
`8da773aa37ba49f8a3add47416d10e2960e8957d2b1b61625c1e5c1de3cad0fd` and
`4592fc45f07ff45ce2070e77cbb44fbc6452266426246bb7a548cfc55024ed3b`.
The initial scratch `native.fyIYVK` failed on unsupported
`--user_files_path` before inferred-input qualification. It is preserved as
an instrument failure, not a compatibility result. The corrected runner uses
escaped absolute file paths; root checks `LocalServer.cpp`'s local context and
the TableFunctionFile/StorageFile absolute-path route. Replay requires a new,
caller-created empty canonical direct child of a fresh
`/private/tmp/crystal-click-w152-*` root; do not overwrite either evidence root.

### Scoped adversary and continuation

Scoped hostile verdict: ROBUST for nominal descriptors and the documented
generic whole-admission guards. Luna authors and supplies a correlated
read-only review, not independent replication. Root separately inspects fresh
upstream source and final production diff and executes the behavioral RED,
literal/negative gates, native oracle and all regression groups. Review's
empty/partial LC-helper counterexample narrows the claim as stated above;
it is not silently promoted to a complete persisted stream set. Final
Crystal formatting, Ruby syntax and `git diff --check` pass.

The next transition is a paired generic Dynamic value/RowBinary kernel with
actual typed-value witnesses, before declaring Object Dynamic or opening its
bulk/physical/whole-part paths. Declared Object Dynamic, remaining type/layout
coverage, MV/projections, facade modularization and the eventual performance
objective remain open. Refresh this certificate on descriptor, parent policy,
consumer guard, budget, source/runtime or host-toolchain changes. Temporary
logs may decay; their hashes are evidence indexes, not proof by themselves.
