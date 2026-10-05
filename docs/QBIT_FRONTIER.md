# QBit paired part frontier

Status: W103 implemented and verified on 2026-09-30 within the bounded
scalar/Nullable profile below. The verified predecessor is
`ab410a87583838465304a92c4a10aec39c0bdedb` (exact Decimal precision, W102).
The broader types, MV/projection, modularization and later performance goal
remain active; this certificate does not close them.

W179 separately bridges these dedicated owners into the generic nominal
descriptor, scalar RowBinary and normalized bulk kernel for root QBit/direct
Nullable only. It reuses the plane codec and does not broaden this complete-
part envelope. The current 26.10 stock matrix pins the existing W103 Wide/LZ4/
plain-mark and empty-column serializer profile explicitly; newer default
metadata and compressed marks are not admitted by fixture qualification.
Fresh source/runtime identities, final gate status and scope are recorded in
[QBIT_BINARY_KERNEL_FRONTIER.md](QBIT_BINARY_KERNEL_FRONTIER.md). No new
QBit-in-projection or general MV certificate is claimed.

## Source and measured anchor

Source reference: ClickHouse shallow snapshot
`a9581941254d6113f3740a8ec125ee7519cb1bda`, stored separately under
`/Users/sergey/SrcArchives/clickhouse-2026-09-29-depth1`.
Primary owners are `src/DataTypes/DataTypeQBit.{h,cpp}` and
`src/DataTypes/Serializations/SerializationQBit.cpp`.

The pinned oracle runtime is ClickHouse 26.7.1.1315. Root has observed successful
casts for Int8, BFloat16, Float32, Float64 and the strided declaration
`QBit(Float32, 16, 8)`. Separate five-row scratch Wide parts establish:

- `QBit(Float32, 10)`: 32 numbered streams `payload%2E1` through
  `payload%2E32`, without String size streams.
- `Nullable(QBit(Int8, 16, 8))`: one `payload.null` stream and 16 numbered
  streams, including an all-NULL stock insert.
- Both measured fixtures have serialization version 1, propagated nested
  versions, String version 1, and an empty per-column serializer array.

Factory presence and casts are not physical or bidirectional qualification.
The source snapshot is not a tested current-master binary.

A separate 3000-row stock `QBit(Int8, 17)` Wide probe (plane width 3,
granularity 2, maximum compressed-block size 4096) has 818 marks per plane
whose frame-relative decompressed offset is not divisible by 3. A compressed
frame can split a plane row. The QBit path must parse those offsets as bytes
while retaining the actual plane width for resource and exact selected-range
length checks; the generic fixed-width alignment gate is not widened here.

## Admitted implementation target

Paired typed reader/writer for scalar and Nullable QBit with all four exact
element identities. Parameters are dimension and optional stride; exact type
identity includes both and cannot collapse BFloat16 into UInt16. When stride
equals dimension, the canonical declaration omits the third argument, matching
ClickHouse. Explicit non-default strides must divide the dimension and be a
multiple of eight. The source caps stride groups at 1024.

The physical plan has `element_bits * (dimension / stride)` FixedString planes,
each of width `ceil(stride / 8)`. Plan order is group-major, then most-significant
element bit first. In each plane, dimension bytes run in reverse byte order;
within a byte, the local dimension bit is least-significant-bit first. Padding
dimensions are initialized to zero by the writer. Nullable adds a separate
validated 0/1 null map; dense zero placeholders still occupy nested plane rows.

Public rows retain owned exact raw element bits. This is storage fidelity, not
vector arithmetic, SQL casting, distance functions, or a performance claim.
The table batch and offline `column.values` consumers must preserve this
nominal identity and use the existing UInt64 candidate-granule pruning model.

The initial physical envelope is Wide parts, LZ4, uncompressed adaptive `.mrk2`
marks, canonical schema, serialization profile measured above, and existing
bounded file/frame/row/metadata limits. Plan, preflight and range bounds reject
resource-exhausting requests before result allocation or writer staging. These
are resource guards, not proof that every ClickHouse dimension fits in memory.

Rejected: Array/Map/Tuple/LowCardinality QBit compositions, Compact parts,
Sparse/alternate metadata profiles, arbitrary-schema table writing,
live-server state claims, general MV or projection execution. Rejection must
remain explicit, never a fallback to an Array or numeric-width codec.

## Implemented owner and public API contracts

The twelve new concrete owners each have a source file; the require graph and
lower-reader/table dependency boundary are recorded in
`MODULARIZATION_FRONTIER.md`. Descriptor identity is closed and immutable;
row construction copies raw little-endian element bytes, and exporting
`raw_bytes` returns a defensive copy. Raw equality preserves NaN payloads and
distinguishes signed zero. Only the shared plane codec owns bit transposition.

`WidePart` exposes `read_qbit_mark_range`,
`read_nullable_qbit_mark_range`, `read_qbit_dense_mark_range` and
`qbit_mark_range_materialization_charge`. Range checks use the actual stream
schedule before narrowing a public `Int` argument; negative and oversized
unsigned ranges cannot wrap into a selected callback. Metadata-only preflight
checks all plane/null schedules before selected payload reads. Null maps must
contain 0/1. Selected plane lengths must equal the exact logical row charge,
including ranges whose byte segments split across compressed frames.

Typed table batches expose `qbits_for` and `nullable_qbits_for`. Offline
`scan_qbit` and `column.values` preserve exact nominal QBit identity.
`scan_uint64_pk_candidates` now also selects canonical QBit/Nullable payloads
beside its required simple ascending UInt64 key. Candidate callbacks still
receive whole granules, not exact filtered rows. All candidate indexes are
verified against their recorded physical hash before any callback; exact key
residual predicates remain the caller's responsibility.

`WidePartWriter.write_uint64_qbit_pair` and
`write_uint64_nullable_qbit_pair` accept owned `QBitValue` row slices and an
exact canonical declared type, with the existing sorted UInt64 key contract.
Shape, type, resource and key checks run before input snapshots or staging.
NULLs retain zero-filled dense nested rows. The real stage validator checks
exact schema/serialization metadata, expected checksum inventory and records,
per-mark raw values, null maps, dense placeholders, keys and EOF marks before
exclusive publication. Bounded physical hashing also binds the entire
serialized `checksums.txt` envelope, including its uncompressed hash fields
which `PartChecksums::Entry` does not expose. A test hook runs before this
validator, not instead of it. Failure removes only the owned stage.

The 64 MiB cap is a checked logical materialization charge, not a measured
peak-RSS or throughput guarantee. It includes QBit result slots, owned raw
rows, plane buffers and descriptor overhead; the writer adds key/input slots.
Offline `.values` separately charges the actual `OfflineColumnValue` union
slot size before allocation. Legal ClickHouse dimensions/stride groups can
still exceed this library's bounded stream-count or charge profile.

## Execution plan and rollback

Risk: CAUTION (new persisted type and shared admission boundaries).
Rollback: exact-path local commit, preserving the clean W102 parent `ab410a8`.

1. Run `spec/qbit_admission_spec.cr` on the unchanged production baseline and
   retain the expected missing-admission failure.
2. Introduce separate type, owned value, physical plane codec, selected-range
   reader and writer orchestration owners, one concrete owner per file.
   Reuse existing frame, checksums, primary index and exclusive publication
   helpers through small adapters; do not add QBit to Tuple leaf unions.
3. Wire typed part, table batch and offline catalog consumers, keeping each
   facade change narrow and preserving all prior APIs.
4. Run focused DEBUG and RELEASE specs; run a pinned stock-to-reader and
   writer-to-stock oracle with independent physical bytes, RowBinary and mark
   boundaries, then the full DEBUG suite and relevant Tuple/FixedString gates.
5. Hostile review, record actual evidence and remaining broad goal, then make
   an atomic local commit only after the declared signals pass. No push.

## Falsifier roster

The strongest likely defect is a mutually consistent but wrong transposition
or stride order in reader and writer. The independent oracle must derive plane
bytes from raw element bytes without calling the production plan/codec, compare
stock physical bytes and every mark's logical position, and ask stock CH to
ATTACH/CHECK/read writer output. Seed a wrong expected plane byte to establish
comparator sensitivity.

Other required checks: dimensions 1/7/8/9/10 and strided 16/8 and 24/8; all four
carriers; negative zero and non-finite raw floating patterns; nullable mixed,
all-zero and all-NULL rows; default stride canonicalization; type/row/dimension
mismatches; invalid or oversized parameters; missing plane/null streams;
null bytes outside 0/1; unequal mark schedules; frame-relative logical EOF;
budget rejection before selected payload callbacks or staging; and no publish
after staged readback/schema failure.

Baseline RED executed on unchanged production code with the RSS/time watchdog:
`crystal spec spec/qbit_admission_spec.cr --link-flags=-fuse-ld=ld` produced
2 examples, 1 failure, 0 errors. The positive assertion rejected the first
supported declaration (`expected true, got false`); the negative guard example
passed. This establishes the missing admission, not a payload qualification.

The stock oracle also reproduced a separate primary-index failure on the
initial W103 implementation: after eight passing stock profiles,
`int8_d10_scalar` accepted a same-size monotone stale-hash `primary.idx`.
The owned fixture changed `[1, 3, 5, 5]` into `[5, 5, 5, 5]`, silently pruning
the key-4 candidate instead of rejecting it. The offline candidate facade now
sets `verify_recorded_hash: true`. The same counterexample passes only if
`CorruptPartError` occurs before any callback; original fixture bytes are
restored in `ensure`.

Initial focused DEBUG and RELEASE each passed 26 examples with zero failures,
errors or pending examples. Their four spec files cover admission, independent
bit controls, ownership, bounds/charges, selected-range and high-level
consumers, and writer no-publish guards. The staged-schema guard changes
`QBit(Float32, 32, 8)` into `QBit(Float64, 16, 8)`: both have 128 raw bytes,
128 one-byte planes, identical physical stream names and equal declaration
lengths, but exact nominal schema identity differs. It requires the real
content/schema validator's rejection rather than only a size mismatch,
no destination and no leftover stage. Callback-only malformed-stream/null
controls establish their narrow helper contracts, not every physical corrupt
part or concurrent-change scenario.

A later hostile-stage probe ran ten writer examples against unchanged
production code and produced three failures. Replacing `metadata_version.txt`
with a symlink to a separately owned exact `0` file raised no error: the part
was published. The private before-validation hook made this mutation possible;
public writer entry points supply a no-op hook. In contrast, a matching
`columns.txt` symlink was already rejected by the downstream part reader, so
that initial publication hypothesis was refuted. The writer nevertheless
followed and fully read it first. A one-byte metadata append also reached the
content comparison before an exact-size guard. The implemented repair rejects
symlinks and mismatched sizes before a bounded expected-length read. These
controls do not establish peak-RSS bounds or race-free concurrent publication.

After the repair, focused DEBUG and RELEASE each passed 41 examples with zero
failures, errors or pending examples: 29 QBit examples and 12 primary-key
candidate examples. The metadata-version control checks the exact early guard
diagnostic, no destination, stage cleanup and the external file's unchanged
content. The equal-size schema control still reaches content comparison.
Historical malformed-index fixtures now refresh only their recorded physical
hash when they intend to reach monotonicity or codec checks; separate stale-hash
controls require rejection before any candidate callback. No production guard
was relaxed to restore those tests.

The final bidirectional stock oracle rerun on the guarded source passed all
72 canonical profiles (four carriers, nine dimension/stride shapes, scalar and
Nullable), eight
all-zero/all-NULL controls, and all 80 corresponding writer profiles.
Independent raw source-bit expectations compare every plane/null byte and
every logical data/sentinel mark, without calling the production plane plan
or codec. Stock parts pass CHECK and full/key RowBinary comparisons; stock CH
ATTACHes writer parts, checks exact metadata and CHECK, and reads full/key
RowBinary values. Sixteen representative profiles additionally exercise typed
batches, selected windows, catalog `.values`, candidate QBit payloads and
caller-side key residuals. A seeded wrong expected plane byte is rejected.

The 3000-row `QBit(Int8, 17)` stock control also passed: all eight three-byte
planes contain unaligned frame-relative marks, logical mark positions and
late selected ranges are exact, and one selected range crosses a 4096-byte
frame as segments of 4 and 20 bytes. This qualifies byte-based frame slicing,
not arbitrary compression profiles or a performance claim.

Full DEBUG passed 1,433 examples with zero failures, errors or pending examples
under the 600-second/32-GiB watchdog and `--single-module`. The final QBit
bidirectional oracle rerun exited 0 after approximately 121 seconds. Five
unchanged regression oracles passed: exact Decimal precision, parameterized
Tuple, compositional
Tuple, FixedString and Nullable(FixedString). The Decimal run includes 76
stock-backed profiles, four separate statistics-only raw-zero controls and
16 direct writer guards; these are not all stock-backed value profiles.
Types, arbitrary compositions, MV/projection breadth, facade decomposition,
and the later memory/performance goal remain open.

The stage certificate assumes the shared public `create_stage` factory and
no concurrent mutation. The private hostile hooks exercised here replace or
modify files inside the still-owned directory; arbitrary replacement of the
stage root itself (including a directory symlink) is not certified. A future
path-security slice needs directory-handle-relative no-follow operations,
not an inference from these file guards.

## Executed DoD and certificate boundary

Root executed these commands serially under `cogni-ml/scripts/run_safe.sh`
with a 600-second timeout and a 50-percent system-free-memory floor. Focused
and oracle runs used an 8-GiB process envelope; full DEBUG used 32 GiB.
The host was Crystal 1.21.0 / LLVM 22.1.8 / arm64 macOS, SDK 26.5, with an
isolated temporary Crystal cache. `CLICKHOUSE` and `CLICKHOUSE_BIN` selected
the pinned 26.7.1.1315 binary. No current-master executable was built.

```sh
crystal spec spec/qbit_admission_spec.cr spec/qbit_hostile_spec.cr spec/qbit_writer_w103_spec.cr spec/qbit_reader_consumers_w103_spec.cr spec/pk_candidates_spec.cr --link-flags=-fuse-ld=ld
crystal spec spec/qbit_admission_spec.cr spec/qbit_hostile_spec.cr spec/qbit_writer_w103_spec.cr spec/qbit_reader_consumers_w103_spec.cr spec/pk_candidates_spec.cr --release --link-flags=-fuse-ld=ld
crystal spec --single-module --link-flags=-fuse-ld=ld
bash scripts/check_qbit_oracle.sh
bash scripts/check_decimal_precision_oracle.sh
bash scripts/check_parameterized_tuple_oracle.sh
bash scripts/check_compositional_tuple_oracle.sh
bash scripts/check_fixed_string_oracle.sh
bash scripts/check_nullable_fixed_string_oracle.sh
```

All declared DoD commands exited 0. Format, shell syntax, diff whitespace and
exact-path private-key/token-pattern hygiene checks also passed. These hygiene
checks are not a comprehensive secret or security audit.

Root's proportionate adversarial verdict is ROBUST for the admitted public
profile and the executed file-tamper controls. This rests on root's source
inspection, the qualified RED/GREEN counterexamples and independently derived
stock physical bytes/marks/RowBinary, not on agreement with Luna Max. Luna's
static assistance is same-lineage and correlated. The source state is the
implementation commit containing this certificate, derived from the exact
predecessor above; documentation-only sealing did not change tested code.

Refresh affected gates when the ClickHouse binary/serializer, metadata,
codec/mark layout, nominal identity, plane codec, shared frame/primary-index
path, table/catalog adapters or publication helpers change. Unsupported
profiles remain fail-closed. Arbitrary recursive types, Compact/alternate
profiles, current-master metadata additions, MV/projection breadth, facade
decomposition, stage-root/path-race security and memory/performance parity
remain unqualified; no whole-engine completion claim follows from this slice.
