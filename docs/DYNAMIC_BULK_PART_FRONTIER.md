# Recursive Dynamic bulk complete-part frontier — W203

Status: VERIFIED within the finite public-part and native scope below
(2026-10-07). Baseline: `4106f607f8a3fa0e74f10ec83cedd6fe1374b7cd`.
Risk: CAUTION (public storage API, structure-state discovery and persisted
layout). Rollback: one scoped local commit; no push or stock checkout changes.

## Contract and factual anchor

W201 already composes nominal Nested with LowCardinality, Variant and Dynamic
through BinaryDynamicBulkPlan, BinaryBulkEncoder/Decoder and the Dynamic
physical plan. The nine unchanged W201 tests were executed successfully on
the baseline. W202's public complete-part path instead supplies a nil Dynamic
plan and owns only static lanes. The missing behavior is physical ownership,
not a new leaf serializer for every Cartesian type product.

Public write entry: `WidePartWriter.write_uint64_dynamic_bulk_part(destination,
key_name, keys, value_name, type, structures, granules, rows_per_mark: 8192,
profile: BinaryBulkProfile.single_stream, frame_bytes: 4096,
metadata_version: 0_i64, limits: BinaryBulkCodec::DEFAULT_LIMITS,
transport_limits: CompressedStreamLimits.new)`. Keys are Slice(UInt64), values
are Array(Array(BinaryValue)), and structures is Hash(String, DynamicStructure)
keyed by the existing logical occurrence paths. The descriptor may be any
already-admitted JSON-free Dynamic-bearing root or recursive carrier.

Public read entry: `DynamicBulkColumnReader.open(part_path, column_name,
expected_type, limits, transport_limits)`; `read_marks(first, count)` returns
selected physical marks and BinaryValue rows. The reader discovers structure
streams from the part, including Dynamic sites inside ordinary actual-roster
containers. The caller does not supply a guessed roster to the reader.

Design-sealed surface: existing Dynamic V3/BASIC Variant codec admission,
String single/size-stream profiles, LZ4, hashed stream names, uncompressed
adaptive marks, and a direct two-column UInt64-key Wide part. Preserve nominal
Nested and actual-type identity. SharedVariant overflow values remain owned
by the existing codec; recursive wrappers reuse their existing serializers.

Rejected/guard-only: JSON-containing descriptors and JSON-as-Dynamic-actual,
unsupported structure versions, COMPACT Variant, illegal CH nesting, Compact
parts, legacy/flattened layouts, arbitrary dictionary schedules and automatic
OfflineTable dispatch. This slice is not all-type compatibility, MV/projection
support, a performance qualification or a whole-part memory cap.

## Design laws

- Retain one prepared recursive Dynamic plan, including per-site structures,
  statistics offsets, data roles and structure roles. Child domains are not
  parent row counts: sizes and discriminators drive flattened/sparse values.
- Discover read sites parent-first. An outer Dynamic actual roster can reveal
  another Dynamic site. Bound depth, nodes, names and bytes before each owned
  materialization; do not scan arbitrary files or guess unknown arm names.
- Structure metadata lanes have their own retained statistics boundary and
  mark contract. They are not ordinary value lanes with an eight-byte prefix.
  Data discriminator lanes use the existing physical-prefix adapter.
- Every physical lane agrees on the key's root parent mark grid. Validate the
  exact combined stream roster, source declaration and String profile. Load
  required structure state before decoding any selected data window.
- A present root Tuple serializer entry requires schema-matched recursive
  Default `subcolumns`, exact child arity and bounded child counters/depth/nodes.
  An entirely omitted value entry retains CH's Default fallback. This is an
  explicit Dynamic-reader opt-in; legacy Object metadata admission stays strict.
- Keep complete LowCardinality dictionary replay for selected/empty windows.
  Reuse cumulative codec and transport budgets across the owned column work;
  do not advertise these as bounds for keys, metadata or total process RSS.
- Readers require quiescent parts. Existing stream owners validate declared
  file sizes and consumed compressed-frame checksums; whole unselected-file
  authentication is not newly promised.
- Preflight and encode before staging; validate checksums, grids, keys/index
  and public readback before exclusive publication. Refuse existing targets.
  Failure must leave no destination or stage and preserve existing data.
- Share the existing two-column publication workflow between static Nested
  and Dynamic-bearing columns. Use thin adapters and separate structure,
  column, publication and validation owners, one class per file. Do not clone
  a complete-part writer or implement serializers per carrier combination.

Strongest failure: paired library reader/writer agree on a wrong Dynamic
roster, SharedVariant envelope or mark boundary. Literal stock reads in both
directions, actual-type checks, malformed off-window metadata and a seeded
behavioral defect must discriminate that failure.

## Execution plan and falsifiers

1. `spec/dynamic_bulk_part_w203_spec.cr`: capture public API absence before
   production edits; root records actual guarded compiler exit 1. Keep W201
   and W202 baseline tests separate from the new RED signal.
2. Generic Dynamic column/structure owners and minimal Dynamic plan discovery
   callback/factory: discover actual-dependent sites using the existing type
   grammar, retain the plan and bind data/metadata lanes. Reuse existing bulk
   codecs, physical names and Object metadata-lane transport, not Object's
   narrower typed-path admission policy.
3. `src/crystal_click/wide_part_writer/`: share publication and validation
   infrastructure with W202; preserve its public static API and behavior.
   Add only the new facade/requires in `wide_part_writer.cr`/`crystal_click.cr`.
4. Root runs focused tests and the exact affected regression roster serially
   in DEBUG and RELEASE. Expected signal: zero failures/errors/pending and
   actual exit 0; formatting and diff checks are separate.
5. `scripts/check_dynamic_bulk_part_w203.cr` and
   `scripts/probe_dynamic_bulk_part_w203.rb`: fresh stock-created root Dynamic,
   Array(Dynamic), Tuple(Dynamic, String), nominal Nested with LC/Variant/
   Dynamic/String, and a Dynamic actual container revealing an inner Dynamic
   site. Both String profiles, first-empty/ragged/NULL/ordinary/shared values,
   full/later/final/end-zero windows. Stock CREATE may falsify an assumed
   legal combination; record that evidence rather than substituting a fake
   JSON sibling or silently changing the requested carrier.
6. Library-written parts must be directly ATTACHed and read by stock, without
   stock rewriting their payload. CHECK is not a value oracle. Root audits
   literal values/types, raw process provenance, source/runtime pins and file
   snapshots, then attacks the unchanged behavioral/report oracles.

Negative roster: missing/extra/swapped structure sites; corrupted version or
statistics boundary; inconsistent parent grids; absent/extra physical lanes;
wrong declaration/profile; malformed unselected LC/shape state; value/type
mismatch; budgets; existing destination and no residue on failed publication.
Coverage is combined: the new public tests exercise Tuple metadata, nominal
declarations, selected roster/window guards, plan identity, budgets and failed
publication; unchanged recursive-codec/transport tests cover their retained
state/layout guards. Every malformed case is not separately instantiated as a
new public complete part.

Root owns all compiler/native execution, serially through the unchanged
`/Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh` resource guard:
50 percent minimum free memory, 600 seconds, 12288 MiB, isolated cache/TMPDIR,
Xcode SDK, Crystal `--single-module --threads 1 --link-flags=-fuse-ld=ld
--error-trace`; RELEASE adds `--release`. Workers do not launch workloads.

Inspected unbuilt shallow source: `clickhouse-2026-10-05-depth1-ef037e60`,
revision `ef037e60fc7f5654c8c80eefb8be82e3c56f9a67`. Source anchors:
SerializationArray.cpp:297-325,352-394; SerializationVariant.cpp:199-223,
454-520; SerializationDynamic.cpp:182-328,377-506;
SerializationLowCardinality.cpp:271-340; DataTypeNested.cpp:51-75.
The separately pinned native runtime is 26.10.1.1201, build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`, SHA256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
Neither source inspection nor a runtime version proves an unexecuted build.

## Stop rules and continuity

Do not erase nominal declarations, skip required site state, weaken existing
guards or change literal expectations to manufacture green. Pivot if stock
or independent metadata observations contradict the assumed carrier law.
Update this banner, PROJECT_STATUS and the evidence index only after executed
qualification. Overall types, MV/projections and the later performance target
remain active and incomplete. No remote push is authorized by this slice.

## Executed preimplementation probes

The new focused spec on unchanged production fails with actual guarded exit
1: undefined `write_uint64_dynamic_bulk_part` at line 101. This is API-absence
RED, not evidence of a broken leaf serializer. The unchanged W201 and W202
specs separately pass 18 examples, zero failures/errors/pending, actual exit 0.

An independent bounded stock legality probe creates the four declared
carriers above, writes an empty nominal Nested row, and writes an actual
`Tuple(Dynamic(max_types=1))` into a root Dynamic. Stock reports that exact
actual type and `(7)` value; both written parts pass CHECK. The process exits
0 without diagnostics under the pinned runtime SHA. Capture:
`/private/tmp/crystal-click-w203-carrier-legality.hykyBU/invocations/`.
These observations establish legal carrier requirements, not library part
compatibility. SQL `buildId()` reports binary ID
`DB3524E5F34139BEA7B1D573C45D031F`; it is distinct from the VERSION_GITHASH
source revision used by the existing native harness.

A subsequent stock-only five-carrier/two-profile fixture invocation exits 0
and creates ten Wide parts, before any library helper is invoked. Its raw
observations reveal an important origin-specific state: stock Array(Dynamic)
chooses String as its ordinary actual and UInt64 as SharedVariant, whereas the
explicit library fixture plans UInt64 ordinary and String shared. The other
fixture rosters match that library choice. Equal semantic values do not require
equal ordinary/shared placement. The reader must discover the persisted
roster; the native oracle must model each origin without changing the literal
values. Capture: `/private/tmp/crystal-click-w203-stock-fixtures.FB6DIy/`.
At this observation the first parser attempt rejects because system Ruby 2.6
lacks Array#filter_map; parser/NULL-wire handling and the origin-aware oracle
are being corrected. This is not yet a paired library compatibility result.

After origin-aware roster and JSON NULL wire corrections, a fresh guarded
stock-only invocation passes the full independent literal/type/shared-state
oracle: ten parts, ten successful CHECKs and 160 selected-row observations
across overlapping windows, actual exit 0, no stderr, unchanged pinned binary
SHA. Capture: `/private/tmp/crystal-click-w203-stock-fixtures.4ZqYkY/`.
The fixture assertions also pass under system Ruby 2.6.10. No Crystal column
reader or library-written part is exercised by this stock-only certificate.

The first paired helper invocation fails with actual exit 1 at stock root
Tuple metadata, not at leaf serde. Root Dynamic and Array(Dynamic) cases in
both profiles have already published library parts and passed their stock
reader checks. The next stock `Tuple(Dynamic, String)` serialization entry
contains two unnamed `subcolumns`; the existing Object metadata parser accepts
only flat Default entries. Stock root Dynamic and the library's corresponding
metadata agree, refuting the initial root-Dynamic suspicion. Source
`SerializationInfoTuple.cpp:177-220` emits this recursive array and checks its
arity on read. Capture:
`/private/tmp/crystal-click-w203-native-debug-first.tCECSu/`. A schema-bound
recursive metadata validator must preserve the old Object parser's strict
default admission and reject incorrect child counts/kinds before widening.
This failure is not a native format rejection or a paired success certificate.

## Executed qualification and remaining frontier

Final focused DEBUG passes 27 examples. The exact 177 affected files pass
1112 DEBUG and 1112 RELEASE examples, zero failures/errors/pending, actual
serial guarded exits 0. The 965-file src/spec identity is unchanged across
these gates, final helper builds, native qualification and seed restoration:
`c52a9fc6b14091a89d90fec23e2cb48c6518e6a6186c9a38e7a9ffaaed714a67`.

Fresh final captures exercise five carriers under both String profiles in
both directions. In each mode: ten library parts directly ATTACH, thirty CHECKs,
480 literal/type/shared-state observations across overlapping windows, and
504 unchanged published stock/library files. Root binds raw process records,
argv/stdin/output hashes, helper input and source paths, independently fixed
logical roles and columns_substreams names, and part snapshots. This does not
independently reimplement physical filename hashing. DEBUG/RELEASE generated
bytes and normalized helper reports agree. Captures:
`/private/tmp/crystal-click-w203-native-debug-final.v1KvR0/` and
`/private/tmp/crystal-click-w203-native-release-final.Sodhn2/`.

The unchanged accepted raw/helper/report oracles reject 49 mutations per mode,
including separate valid-form declared-type, actual-type and shared-state
mutations plus input/source provenance forgeries. Temporarily replacing the
production selected LC decoder offset with zero causes one unchanged focused
failure: a later Nested window expects three elements but returns the first
empty mark. Exact reader SHA restoration is checked; all 27 focused tests pass
again. Scoped verdict: ROBUST; correlated Luna source review is supplemented
by root-executed behavioral and raw evidence checks. Evidence index:
`.landmark/evidence/dynamic-bulk-parts-w203.json`.

The public writer/reader is generic over already-admitted JSON-free recursive
descriptors; qualification is finite, not a proof for every legal product or
dictionary schedule. JSON-containing descriptors/actuals, broader specialized
layouts, automatic OfflineTable dispatch and MV/projections remain open.
Performance and repository-wide class decomposition stay deferred/incomplete.
The new column, site-name, Tuple-metadata, input and shared publication owners
are separate classes; this does not decompose the entire old WidePartWriter.
The overall goal remains active and incomplete. No remote push was performed.

This certificate decays when relevant source/specs, helper/executor behavior,
source/runtime pins, profiles or fixture laws change. Refresh with the recorded
guarded gates and fresh captures; report the new scope rather than inheriting
this result. Temporary raw captures are a reproducibility aid, not durable proof
by the presence of an evidence packet.
