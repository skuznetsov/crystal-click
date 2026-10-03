# LowCardinality Bulk Storage Frontier (W142)

Status: VERIFIED within the bounded standalone physical dictionary/index
codec profile and executed witnesses below; scoped hostile verdict: ROBUST.
Recursive bulk/Object/complete-part integration remains IN_PROGRESS.
Baseline: `a576267`, 2026-10-03. W141's nominal row-kernel certificate is
in [OBJECT_LOW_CARDINALITY_FRONTIER.md](OBJECT_LOW_CARDINALITY_FRONTIER.md).

## Active boundary

The paired storage owner reads and writes actual LowCardinality
dictionary/index lanes, not repeated logical RowBinary envelopes. It is a
shared prerequisite for recursive bulk and Object typed fields. Completing
this prerequisite does not close the all-types, MV/projections or performance
objective. Ordinary BinaryBulk, Object declarations, Dynamic arms and borrowed
persisted envelopes remain rejected for LC until their own integration gates.

Source reference: shallow ClickHouse `9007d227b64a3f8b667fc5258ceb2923f3cf477d`
at `/Users/sergey/SrcArchives/clickhouse-2026-10-03-depth1-9007d227`. Native
witnesses use the separately pinned 26.10.1.1201 executable recorded in W141,
not a build of that source revision.

## Design laws and falsifiers

- One stateful owner per LC descriptor node; no class per leaf/container
  combination and no new branches in the legacy reader/writer facades.
- Two physical roles: dictionary keys map to `<base>.dict`, indexes to
  `<base>`. The dictionary starts with UInt64LE version 1. Index descriptors
  encode width UInt8/16/32/64 and global/additional/update flags.
- A dictionary can span marks. Equal dictionary coordinates are legal; selected
  middle marks must load the referenced dictionary, not an empty per-mark slice.
- Index row counts describe LC occurrences, including flattened container
  elements, rather than necessarily root-table rows. Integration must validate
  this against the recursive occurrence schedule.
- Preserve exact nominal child identity and bytes. Nullable dictionaries have
  implicit NULL semantics at reserved slot zero; that is not a physical null-map
  lane and must not conflate NULL with the default non-NULL value.
- Bound key counts, index counts, byte spans and decoded/output nodes before
  proportional allocations. State is operation-local. Constructors and
  snapshot accessors detach byte/offset buffers; the inherited `borrowed_slice`
  API is read-only by convention, not a runtime-enforced immutable view.
- Attack invalid versions/flags, each index width, missing/updated dictionaries,
  additional-key boundaries, default/NULL slots, empty LC occurrences, truncated
  or trailing records, corrupt grids and selected middle/zero windows.

## Execution and rollback

Risk: CAUTION (persisted binary format). Rollback is one tested atomic commit
on the clean baseline; no push. The strongest expected failure is a correct
full scan that silently returns wrong values after seeking to a later mark.
The guard is native multi-mark dictionary/index witnesses plus a selected-middle
assertion and cause-specific corruption controls.

1. Inspect generic bulk consumers and fresh CH serialization/state/mark code.
   Root runs independent native-lane decompression before authorizing code.
2. Record a RED in `spec/binary_low_cardinality_storage_w142_spec.cr` for the shared
   physical owner, then implement it in cohesive, separate owner files.
3. Root runs focused DEBUG and affected RELEASE specs, the complete unique
   non-release spec inventory, independent native bytes and bidirectional
   physical exchange. Distinguish raw-codec witnesses from standalone part
   writer certificates; borrowed sidecars cannot prove a standalone writer.
4. Hostile review targets state, limits, ownership, marks and comparator
   sensitivity. Keep recursive bulk/Object admission closed until that wiring
   and its public file/column/table/catalog consumers are qualified.

Root owns all compiler/native runs under the existing 50%-free/32768-MiB
resource guard, isolated cache and single-thread Darwin compiler flags.
Executed DoD commands and observed source seals are recorded below;
unexecuted plans are not evidence. This is the first stateful-owner transition,
followed by recursive bulk wiring and paired Object part integration.

## First-transition API and profile

`BinaryLowCardinalityStorageCodec` is a standalone root-LC codec, with ordinary
`encode`/`decode` limit wrappers and explicit `encode_with_budget`/
`decode_with_budget` aggregate-budget entry points. Its paired encoder and
decoder have separate files. It reuses detached `BinaryBulkStreams`, with the
exact roles `root.dictionary` and `root.indexes`; it does not change ordinary
`BinaryBulkCodec` admission. Values retain the nominal LC wrapper.

The caller supplies flattened LC occurrence counts per mark. Dictionary grids
contain K real coordinates plus terminal EOF, can begin at byte 8 after the
version prefix, and can repeat. A single global dictionary witness therefore
has `[8, 8, 8, 36]`, not three independent dictionary slices. Index grids begin
at zero and terminate at EOF. Scalar String's measured index grid is
`[0, 20, 40, 57]`; Array(String)'s flattened LC grid is `[0, 21, 42, 59]`.

This transition admits only mark-aligned index records: one record per
nonempty occurrence mark, or no bytes for an empty occurrence mark. A record
split across marks, multiple index records within a mark, or an unindexed
dictionary boundary inside a mark remains outside this profile. Explicit
global dictionary updates must refer to exact dictionary record coordinates.
Additional-only keys and global-plus-additional keys are decoder obligations;
the initial writer emits one global dictionary for the operation.

The first global record can bootstrap its dictionary without the update bit;
a later changed coordinate without an update is refused. The decoder accepts
additional-only `0x600` framing. For Nullable global dictionaries, slots zero
and one represent NULL and the non-NULL default and both physically contain
the underlying default. In additional-only Nullable mode only slot zero is
implicitly NULL: slot one need not be the default. Global-plus-additional
keys are all non-NULL, including additional slot zero.

This is a canonical dictionary profile, narrower than the stock parser:
global reserved slots must contain default bytes, non-reserved keys must be
unique by decoded scalar payload, and inherited VarUInt parsing requires
minimal spelling. Payload comparison is raw-bit comparison except for Bool,
whose decoded nonzero values canonicalize to true.
Refusal of noncanonical dictionaries is not evidence that ClickHouse refuses
the same bytes. Bool retains inherited nonzero-is-true semantics; writes emit
canonical byte 1. Float signed-zero and NaN payloads remain raw bits.

Raw float-bit preservation is a codec-level statement, not stock insertion
parity. Fresh `ColumnUnique.h:735-762` compares defaults and canonicalizes NaN
keys during dictionary insertion; `SerializationLowCardinality.cpp:704-722`
distinguishes additional-only insertion from binding an existing global
dictionary. The nine Native consumers below do not include float witnesses.
Do not infer their insertion semantics or Float Native bit parity from the
literal Float32 storage-decoder test.

Meaning bridge: "canonical" here names the local wire/default-slot and decoded
payload-uniqueness profile. In CH ColumnUnique insertion it also involves
default comparison and NaN normalization. These senses overlap but are not
identical; source inspection establishes that distinction, not equivalent
execution semantics. Allowed use: qualification of the bounded raw codec and
the witnessed key/ID payloads. Disallowed use: automatic integrated Float LC
write admission or stock dictionary-uniqueness semantics from raw-bit tests.
Before that admission, separately falsify signed-zero/default and distinct-NaN
insertion behavior with actual stock consumers and library-owned parts, or
keep those write profiles closed. Refresh after equality/default rules, codec
admission or source/runtime changes.

Selected decoding validates and replays every mark and charges the complete
physical input. It materializes required global and all additional keys,
including keys at unselected marks; only selected row outputs are retained.
This is not lazy file I/O, a selected-wire-only budget, or a performance claim.
`max_bytes` separately caps cumulative logical key inspection/copy work as
well as the shared physical wire counter. Thus a cap equal to the physical
lane length can still reject a larger scan/copy-work estimate. Decoder
Nullable output accounting conservatively reserves three nodes and two edges
per selected row, including NULL rows. Encoder input accounting distinguishes
NULL from non-NULL rows and charges reserved/distinct dictionary keys
incrementally. These logical counters do not bound RSS, allocator capacity,
or transient copies. Empty operations avoid constructing unused large
FixedString defaults; nonempty reserved payloads are wire-preflighted first.

Root DoD uses `run_safe.sh` with `COGNI_RUN_SAFE_MIN_FREE_PCT=50`, a 32768-MiB
ceiling, and `/private/tmp/crystal-click-w142.TeQhbW/run_specs.sh` for focused
DEBUG, affected RELEASE and the frozen unique inventory. The physical oracle
is `scripts/check_low_cardinality_storage_w142.sh`, invoked explicitly with
Bash under the same guard. Expected signals are terminal zero, literal native
key/index agreement, selected-middle correctness, actual stock consumption of
library-produced bytes, and cause-specific corruption/comparator rejection.
The first root run of the authored spec exits 1 at line 145 with an undefined
`BinaryLowCardinalityStorageCodec` constant, recorded in
`/private/tmp/crystal-click-w142.TeQhbW/red.log`. This is a missing-API compile
RED, not behavioral failure evidence. Production implementation was authorized
only after this observation. An earlier temporary probe failed to resolve an
absolute Crystal require; that harness failure is not counted as the RED.
The root's first DEBUG attempt then found the dictionary duplicate-set index
type mismatch (`UInt64` versus `Int32`); the bounded index conversion was
corrected. The rerun passes 72 examples across seven files with zero failures,
errors or pending cases. Affected RELEASE passes 241 examples across 28 files.
Both terminate with exit 0. Initial logs are `debug-r2.log` and `release.log` under
`/private/tmp/crystal-click-w142.TeQhbW`.

After the initial passing full inventory, a root formatting check finds changes
only in the new spec and oracle driver. Mechanical formatting leaves production
unchanged. The root reruns DEBUG (`debug-final.log`: 72 examples), RELEASE
(`release-final.log`: 241 examples) and the oracle in fresh `...-03`; all pass.
The final full inventory also exits 0 with the same 2,361 examples/369 files
before the atomic commit. Final formatting, shell syntax and diff checks pass.
The first full-run
log and inventory remain as `full-inventory-before-format.log` and
`full-spec-inventory-before-format.txt`, rather than silently disappearing.

Executed spec invocations, using the guarded runner above:

```sh
runner=/private/tmp/crystal-click-w142.TeQhbW/run_specs.sh
/bin/bash "$runner" debug-final \
  spec/binary_low_cardinality_storage_w142_spec.cr \
  spec/binary_low_cardinality_w141_spec.cr \
  spec/binary_bulk_w122_spec.cr \
  spec/bulk_dynamic_w122_adversary_spec.cr \
  spec/dynamic_values_w122_adversary_spec.cr \
  spec/object_recursive_w140_root_spec.cr \
  spec/object_recursive_consumers_w140_spec.cr
/bin/bash "$runner" release-final --release \
  spec/binary_low_cardinality_storage_w142_spec.cr \
  spec/binary_low_cardinality_w141_spec.cr \
  spec/binary_value_codec_w117_spec.cr \
  spec/binary_parameter_owners_w119_spec.cr \
  spec/binary_scalar_types_w119_spec.cr \
  spec/binary_bulk_w122_spec.cr \
  spec/bulk_budget_w122_adversary_spec.cr \
  spec/bulk_dynamic_w122_adversary_spec.cr \
  spec/bulk_nominal_w122_spec.cr \
  spec/bulk_string_size_w122_spec.cr \
  spec/dynamic_discriminator_w121_budget_spec.cr \
  spec/dynamic_discriminator_w121_spec.cr \
  spec/dynamic_schedule_accessors_w122_spec.cr \
  spec/dynamic_values_w122_adversary_spec.cr \
  spec/dynamic_values_w122_spec.cr \
  spec/object_recursive_w140_root_spec.cr \
  spec/object_recursive_consumers_w140_spec.cr \
  spec/object_schema_logical_usage_w140_spec.cr \
  spec/object_document_schema_w140_spec.cr \
  spec/object_documents_w123_adversary_spec.cr \
  spec/object_documents_w123_root_spec.cr \
  spec/object_documents_w123_spec.cr \
  spec/object_file_reader_w126_root_spec.cr \
  spec/object_column_writer_w127_root_spec.cr \
  spec/object_part_writer_w128_root_spec.cr \
  spec/object_column_reader_w129_spec.cr \
  spec/object_catalog_w129_root_spec.cr \
  spec/object_table_w130_root_spec.cr
```

The runner invokes Crystal 1.21.0 with `--single-module --threads 1
--link-flags=-fuse-ld=ld --error-trace`, the macOS 26.5 SDK, and an isolated
cache. Root wraps each invocation in `run_safe.sh /bin/bash TIMEOUT 32768`;
the free-memory floor remains 50%. The complete inventory exits 0 with 2,361
examples, zero failures/errors/pending, and 369 unique spec files in 16 serial
disjoint non-release groups. The runner freezes the sorted inventory, verifies
its unique count, and reports success only after every group exits 0. This is
not a combined-process or full-inventory RELEASE certificate.

The executed complete-inventory command is:

```sh
env COGNI_RUN_SAFE_MIN_FREE_PCT=50 \
  /bin/bash /Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh \
  /bin/bash 1800 32768 /private/tmp/crystal-click-w142.TeQhbW/run_specs.sh full 369
```

Root independently sums the 16 passing example totals in `full-inventory.log`
and checks the 369-line `full-spec-inventory.txt`. Frozen `src` + `spec` seal:
`4bd7b7b31ac9db3792f40b57bf271649f854869241c5452c45c4a847fa820215`.
Frozen `src` + `spec` + `scripts` seal:
`b776283f8f43d1e1d1d2ae65f205b89cbdcb6d73c3f8e8427d5fe53f59039fe8`.
Each seal is SHA-256 of the sorted `rg --files` per-file SHA-256 output.
The oracle-only nil-safe message correction changes the script seal, not
production/spec contents. Subsequent mechanical formatting changes only the
new spec and oracle driver; every gate above is repeated on the final seals.

Retained evidence SHA-256 values:

| Artifact | SHA-256 |
| --- | --- |
| `debug-final.log` | `cd7858eb69a483bb94e767dee9de261a31f97214cfc6eb12c85510637ee2600e` |
| `release-final.log` | `fc8735d494ec8fdc2c6b8102bf3b9cd9f05a8ffdbb12d2b2e59ab2101510ba1b` |
| `full-inventory.log` | `0a55e4606a33b6a3abe73ac232021556637e696e8818fac1ee75f0cd9c0cf1ae` |
| `full-spec-inventory.txt` | `8d60f69f8b08857cb0744b35578e558509c0d1f55da874d8155868fc21c34972` |
| oracle `check.log` | `406d83fd80aea51b014bcb2553289bca9587fd5a0aee1354114d93be4b08fcc3` |
| oracle `results/run.txt` | `87070c0a6648369f1e5a7074db25d596da2866bf7300c8faa83c1de401d2fce1` |

Spec artifacts are under `/private/tmp/crystal-click-w142.TeQhbW`; oracle
artifacts are under `/private/tmp/crystal-click-object-low-cardinality-w142.TeQhbW-03`.
These local temporary paths are a curated evidence index, not portable proof
or committed fixtures. Missing artifacts require reproduction, not assumed
continued validity.

### Executed physical exchange

Root runs the oracle with the same guard:

```sh
env COGNI_RUN_SAFE_MIN_FREE_PCT=50 W142_EXECUTE_AS_ROOT=YES \
  SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  TMPDIR=/private/tmp CRYSTAL_BIN=/opt/homebrew/bin/crystal \
  W141_PROBE_ROOT=/private/tmp/crystal-click-object-low-cardinality-w141.tmcuJP \
  W142_CHECK_ROOT=/private/tmp/crystal-click-object-low-cardinality-w142.TeQhbW-03 \
  /bin/bash /Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh \
  /bin/bash 360 32768 scripts/check_low_cardinality_storage_w142.sh
```

Terminal exit 0 reports all nine exact dictionary/index byte and K+1-grid
matches, all nine stock Native consumers, every authored row and selected
middle mark. Witness leaves are String, Nullable(String), Int64, Date, IPv4
and FixedString(3); three more witnesses extract LC(String) lanes below Array,
Map and Tuple. These leaf-lane extractions do not qualify recursive bulk
integration. Scope: uncompressed physical lanes, with one aligned index
record per nonempty mark. Library output is checked against retained native
parts and literal nominal values, not merely round-tripped through itself.

For actual stock consumption the oracle packs one Native block, preserving
the library's dictionary body, ID widths and IDs while converting global
flags to additional/update `0x600` framing. Native forbids global dictionary
flags. This proves that stock consumes those key/ID payloads; it is not
direct Native-global consumption, a per-mark Native state certificate,
standalone part synthesis, or a new library-part ATTACH/CHECK result.
The original native-part CHECK evidence remains W141's certificate.

Four cause-specific controls pass: a valid dictionary-key mutation changes
`red` to `bed`; a valid in-range ID mutation changes `red` to `blue`; reserved
`0x1500` flags fail specifically at the flag guard; and the actual stock
consumer returns the mutated literal `blue` with unchanged nominal type and
remaining rows. Decoder self-roundtrip alone would not detect these faults.
The first launch at `...w142.TeQhbW-01` fails compilation on nullable
Exception.message predicates. Its log is retained; two nil-safe locals fix
that harness error before the successful `...-02` execution. No production
or spec change accompanies that oracle-only correction.

Fresh source pin: `9007d227b64a3f8b667fc5258ceb2923f3cf477d`. Actual runtime:
26.10.1.1201, build `d9bcb5ab007f0f6299f7f973f2642245bab3d028`, executable
SHA-256 `bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
The wrapper checks source HEAD, runtime SHA/version and the retained fixture
identity; the executable reports its build hash. This runtime is not a build
of the fresh shallow source. Evidence includes emitted/retained lanes, grids,
Native inputs, stock outputs/errors and scope/identity under `...-03`.
The successful pre-format oracle evidence under `...-02` is also retained.
The current decompressor does not independently validate CH compressed-frame
checksums, so exact decompressed-lane agreement is not that certificate.

## Evidence and continuation

Root's scoped hostile verdict is ROBUST for this standalone mark-aligned
profile, not for arbitrary ClickHouse LC layouts or integrated parts. The
falsifiers cover initial bootstrap and later dictionary replacement, wrong
IDs/flags/counts, nullable global versus additional-only reservations, a
selected middle mark, all index widths, zero occurrences, constructor/snapshot
detachment, one-short logical/wire limits, and UInt64::MAX preflight. The
independent native bytes and actual stock wrong-output comparator controls
distinguish transport errors from a self-consistent encoder/decoder roundtrip.
Root verifies the observed terminal results, complete inventory count and
source seals rather than promoting a model report to executed evidence.

Luna's final fresh read-only review finds no concrete lifecycle or unsafe
preflight defect within that profile. It calls any recursive-container or
general Object/bulk closure claim VULNERABLE; those admissions remain closed.
This is a correlated same-lineage review, not another independent runtime
execution. Neither test count nor structural owner separation establishes
all-family compatibility, RSS bounds or speed parity.

The previous goal turn made progress: implementation commit `5f85543` and
documentation correction `a576267` landed after W141's executed gates.
The tree was clean before W142. Root's retained Ruby/LZ4/ZSTD inspection at
`/private/tmp/crystal-click-w142.TeQhbW/native-lane-dump-final2.log` exits 0
for all nine W141 native stores. It shows version-1 dictionary prefixes and
repeated dictionary mark coordinates at byte 8, with global-index flags and
separate per-mark index records. Native CHECK identities remain in W141.
The instrument does not independently verify compressed checksums. Its first
two launches failed on missing ZSTD support and a system-Ruby Fiddle constant,
not on a ClickHouse storage rejection; those logs are retained separately.

Refresh this evidence after changes to the codec, mark/state routing, source
reference, native executable or toolchain. On failed refresh, reopen affected
claims. Source inspection and the independently pinned stock runtime remain
different certificates; shallow current-master source is not a current-master
runtime certificate.

Continuation capsule:

- Active objective: paired types and general JSON storage, then MV/projections,
  then memory/performance qualification with at most a 10% CH speed deficit.
- Confirmed boundary: standalone mark-aligned LC physical codec; no recursive
  BinaryBulk/Object/Dynamic/public-part admission follows from leaf extraction.
- Next falsifier: root/container LC through ordinary `BinaryBulkCodec` remains
  refused, even for empty input. Record that RED before integrating role
  binding, flattened occurrence schedules and per-descriptor dictionary state.
- After bulk qualification, add declared Object LC with library-owned complete
  parts and public file/column/table/catalog consumers, including selected
  middle windows and actual stock ATTACH/CHECK. Do not infer Float LC dictionary
  insertion compatibility from raw-bit preservation; qualify its uniqueness
  semantics separately before integrated write admission. Variant/Dynamic, unrepresented
  Interval descriptors, remaining timezone/layout/type profiles and broader
  MV/projections remain open.
- Retained limitations: conservative Nullable node reservation, whole-input
  replay, canonical dictionary refusals, borrowed views mutable by convention,
  no Float Native insertion-parity witness, no compressed-checksum certificate,
  no new standalone part-writer or performance qualification.
- Standing authority: reversible local implementation, root-only serialized
  guarded execution and tested atomic local commits. No push/history rewrite;
  recheck scope and source seals before the next transition.
