# QBit binary-kernel bridge (W179)

Status: VERIFIED within the root/direct-Nullable profile below. Baseline
`cc761d4` (2026-10-05). Dedicated QBit
reader/writer/table/offline APIs already exist. This slice implements their
bridge into recursive binary descriptors, values and normalized bulk, without
claiming new arbitrary-schema part products. The same 78 selected specs pass
694 examples in DEBUG and 694 in RELEASE; the finite native matrix passes
24 profiles in each direction. This is not a complete-repository certificate.
Memory/performance work remains deferred until types and MV/projections.

## Contract and admission

Admit paired QBit descriptors and bit-exact owned values for Int8, BFloat16,
Float32 and Float64 using the existing bounded `QBitType` shape law. Preserve
element identity, dimension and effective stride in equality, hash and display
names. Initially admit only a scalar root and a Nullable(QBit) root across the
logical and normalized bulk APIs. Array/Tuple/Map/Nested/Variant/Dynamic actual
placement remains explicitly refused, including empty/container metadata.
Reuse the existing QBit plane codec rather than deriving a second bit
transposition implementation. An element descriptor is nominal metadata, not
a recursive physical value child.

The descriptor uses tag 0x36 plus the element descriptor and dimension for
default stride; tag 0x37 additionally contains stride. The local canonical-wire
profile rejects redundant 0x37 with stride equal to dimension; ClickHouse's
constructor acceptance is not claimed to require that restriction.
Scalar RowBinary is
VarUInt dimension followed by raw little-endian element bytes. Bulk storage is
different: group-major, MSB-first FixedString bit planes, with the existing
reverse-byte/LSB-bit packing. Nullable adds its normal null lane. Normalized
roles and physical bindings must match the dedicated QBit part representation.
Nonempty selected mark windows retain exact nominal value identity. An empty
selection validates the supplied descriptor and returns no typed values; it
cannot independently attest an original type from absent values.
`BinaryBulkStreams` itself is an untyped role/byte owner. Its decode caller
supplies the descriptor authority; a physically equal plane shape cannot prove
the original nominal type from bytes alone. Mismatch refusal is qualified at
typed-value/encoder and part-schema/binding boundaries, not claimed for a
lane-only decoder supplied with a different otherwise-valid descriptor.

Keep the existing 64-MiB raw-row materialization restriction explicit: it is
a library admission bound, not a ClickHouse nominal dimension limit or an RSS
certificate. The aggregate codec budget counts logical descriptor edges,
role/grid metadata and wire bytes. Separate materialization/name preflights
bound each generated role-name roster, retained raw rows and default buffers
before count-derived allocation; they are not total String-copy, allocator or
RSS accounting. Public sorted, numeric-traversal and detached output rosters
can coexist. Their copy overhead is residual deferred performance work, not
an aggregate heap-byte certificate. Hidden plane
roles must not become an unbudgeted tuple expansion.

Still rejected unless separately qualified: QBit inside borrowed persisted
Object/shared envelopes; new persisted Dynamic/Variant/LowCardinality products;
Count argument-name admission; arbitrary-schema or container-QBit complete
parts; alternate serialization versions; Compact/sparse formats; general MV
execution and projection planning/writing. Existing dedicated scalar/Nullable
QBit consumers and explicit selected projection reads remain in scope for
regression checks. General descriptor support must not silently widen another
owner's persisted profile.

## Evidence anchors

Fresh clean shallow source snapshot, unbuilt:
`/Users/sergey/SrcArchives/clickhouse-2026-10-05-depth1-29e0e201`, commit
`29e0e201c786933171818f17c0fefc2bb11ec0a2`.
`DataTypesBinaryEncoding.cpp:411-425,688-719` specifies the two descriptor
forms and hidden-stream complexity charging; `DataTypeQBit.cpp:25-70` specifies
the four element identities and stride/group law. `SerializationQBit.cpp:319-369`
specifies scalar dimension/raw-element encoding, independently of the bulk
nested-plane serialization at `:433-464`.

Executed stock is separately pinned to version `26.10.1.1201`, build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`, executable SHA256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
It is not a build of the fresh source snapshot. Root's prerequisite diagnostic
in `/private/tmp/crystal-click-qbit-w179-diagnostic.XeveQn` checked pins and
literal Dynamic RowBinary output for Int8/dimension 3 and Float32/dimension 16/
stride 8. All three native processes and the 12-GB/600-s guard exited 0.
This is a format prerequisite, not a paired kernel/part certificate.

## Risk, rollback and qualification order

Risk: CAUTION (shared recursive codecs and persistent-format naming). Rollback:
the exact local diff against `cc761d4`, then an atomic local commit only after
the declared checks pass; no push. Root owns specification, admission RED,
all compiler/native jobs, independent audit and Git. Luna owns bounded code
implementation and inventory. Workers must not overwrite each other's changes.

Strongest failure: confusing scalar raw bytes with physical bit planes, or
losing nominal element/dimension/stride identity between physically equal
shapes. Also attack unbounded hidden-role materialization, budget bypass before
allocation, padding differences, partial-lane consumption, and accidental
borrowed/other-owner admission.

1. Run `spec/qbit_binary_kernel_w179_admission_spec.cr` against the unchanged
   implementation; require explicit missing-admission assertion failures and
   a passing legacy control, not compilation errors.
2. Inventory and seal all shared descriptor/value/name/default/role/binding
   visitors before production changes. Keep cohesive QBit owners one per file.
3. Implement paired descriptors, scalar/envelopes, normalized bulk planes and
   exact physical bindings; retain dedicated public consumer compatibility.
4. Qualify all four carriers, default and nondefault stride, bit-preserving
   payloads, nullable/empty/nonzero windows, malformed/truncated/nominal mismatch
   cases and preallocation budget guards. Execute independent native-authored
   and library-authored witnesses; self-roundtrip alone is insufficient.
5. Run the exact affected roster in DEBUG and RELEASE serially under the
   unchanged 50%-free, 12-GB/600-s guard, isolated cache and macOS linker flags.
   Expected signal: nonzero examples, zero failures/errors/pending, child and
   guard exit 0, unchanged code inputs, exact paired rosters. Execute a seeded
   strongest-guard bypass, restore exact source, and rerun green.
6. Root performs hostile review, calibrates the scoped claim, synchronizes
   current frontiers/status and commits exact relevant paths locally.

The executed roster, native process provenance, literal hashes, observed
commands and scoped adversary result are recorded below. The plan itself is
not evidence of successful execution.

## Sealed shared-owner inventory and admission RED

Core ownership: `BinaryDataType`, `BinaryDataTypeCodec`, `BinaryCodecContext`,
`BinaryTypeNameBudget`, `BinaryValue`, `BinaryValueCodec`, `BinaryVariantRoster`
and the top-level loader. New narrow QBit metadata/value/admission owners may
live in their own files. API: `BinaryDataType.qbit(QBitType)`, optional
`qbit_type`, cached `contains_qbit?`, and `BinaryValue.qbit(QBitValue)` with
`qbit_value`; descriptor children remain empty and `fixed_width` remains nil.

Bulk ownership: `BinaryBulkTypePlan`'s count/materialization/site/schedule/shape
visitors, `BinaryBulkEncoder`'s cost/write/default visitors,
`BinaryBulkDecoder`'s minimum/decode visitors, `BinaryBulkDefaultValue` and
`BinaryBulkPhysicalPlan`'s validation/count/name/binding visitors. Logical
planes use zero-based `root.qbit_plane.i`, physical basenames use one-based
`prefix%2E(i+1)`; Nullable preserves `root.nulls` / `prefix.null`. Existing
QBit reader/writer/table/offline owners remain the part boundary, reached via
owned `QBitValue` conversion rather than a duplicated serializer.

Root's baseline run `w179-qbit-admission-red-3` observed six examples, five
explicit missing-admission assertion failures, zero errors/pending, and a
passing UInt64 control. Child and guard exited 1 with no changed inputs among
971 source/spec/script/example files. Admission spec SHA256
`a782a36ef33ed030e22b2e108d8652c1efcaa1f454e6f16b75cc691e95430c3a`;
log SHA256 `e6265bb4e6d2e2a93313f294d77d77c668a807592cad333a56a2a7853a3961b7`.
Record: `/private/tmp/crystal-click-architecture-r1.shwDws/w179-qbit-admission-red-3.json`.
Earlier root test-harness mistakes (nonexistent envelope method, then an
incomplete refusal rescue) were corrected; those runs are not the assertion
RED certificate.

Root's additional `w179-composition-boundary-red` runs ten examples with four
assertion failures and zero errors/pending: Array and unnamed Tuple descriptor
and envelope decoders leak constructor `ArgumentError` instead of a codec
refusal. Child/guard exit 1, 976 immutable inputs; log SHA256
`5d9404748d9f41e1c787d6ec657250d0ff538402b5e495373469dde317c8ca67`.
The narrow fix adds QBit checks before those two factories and preserves the
excluded composition boundary. This RED is not a green certificate.

The final review traces caller-declared typed Object paths through the ordinary
BinaryBulk codec. The existing borrowed shared-envelope guard already rejects
QBit in both directions; root independently checks that path rather than
counting the worker's initial shared-path suspicion as a new leak. Typed schema
plan construction and direct decode schema admission did bypass that boundary.
`w179-object-boundary-red` observes four examples, three assertion failures,
zero errors/pending and child/guard exit 1, with 977 immutable code inputs. Each
failing example stops at its first failed assertion; later subcases are not
claimed RED. The ordinary scalar/shared positive control passes. Spec SHA256
`28c48fed365b47affb1916323c0574e9b7c322fce0ef8a0982d189411394ff39`;
log SHA256 `929d96b7d50274319d0d2494a3ac2d38cb9608526be969c755572a28a02c0efb`.
The narrow fix refuses QBit after bounded schema traversal in
`ObjectDocumentPlan` and `ObjectDocumentCodec.decode`, before stream assignment
or selection. Tests also cover empty mark selections, zero-mark and null-only
schemas. No persisted QBit-in-Object capability is admitted by this correction.

Oracle review corrected two test-side assumptions before qualification:
BFloat16 quiet NaN payloads are little-endian `c1 7f` / `c2 7f`, not finite
`41 7f` / `42 7f`; dimension-nine plane padding is the first reversed plane
byte's high seven bits (`& 0xfe`), not the final byte's low seven bits.
Stock-enabled bulk tests must additionally compare normalized generic lane
bytes against observed native FixedString plane output for every profile.

The corrected bootstrap `w179-bootstrap-qbit-2` passes 62 examples, zero
failures/errors/pending, child/guard exit 0 and 976 immutable inputs. It exports
all 24 library parts into
`/private/tmp/crystal-click-w179-bootstrap-library.Rntg7x`; log SHA256
`930fd488f180439fb0200d50f137cd949c0528c6c2bc6b285f1741582ca68173`.
This run does not execute the stock-enabled fixture branch and is not the
final paired certificate. The earlier bootstrap compiler failure used a
nonexistent `File.read_bytes` test API; no assertion summary was produced.

Next JSON boundary remains nominal v0 descriptor plus structured root JSON
RowBinary read/write, not just tag 0x30 or JSON text. The live schema lacks SKIP
and SKIP REGEXP metadata. Typed-path descriptor children, effective Dynamic
caps, skipped-value consumption and overflow/shared-path behavior require
their own paired qualification. Persisted Object layout versions and MV/
projection integration are separate products and remain open.

## Qualification roster sealed before execution

Replay the exact C1-C4 rosters (64 specs) listed in
[AGGREGATE_COUNT_ARGUMENTS_FRONTIER.md](AGGREGATE_COUNT_ARGUMENTS_FRONTIER.md),
without dropping their enabled fixture assertions. Add these two disjoint
cohorts, for the same 78-spec union in both DEBUG and RELEASE:

C5 (QBit logical, dedicated consumers and Object boundary, eight specs):

```text
spec/qbit_binary_kernel_w179_admission_spec.cr
spec/qbit_binary_kernel_spec.cr
spec/qbit_binary_kernel_parts_spec.cr
spec/qbit_binary_kernel_object_boundary_spec.cr
spec/qbit_admission_spec.cr
spec/qbit_hostile_spec.cr
spec/qbit_reader_consumers_w103_spec.cr
spec/qbit_writer_w103_spec.cr
```

C6 (Variant refusal and shared physical visitors, six specs):

```text
spec/binary_variant_value_w147_spec.cr
spec/binary_variant_value_w147_adversary_spec.cr
spec/binary_variant_bulk_w148_spec.cr
spec/binary_variant_bulk_w148_adversary_spec.cr
spec/binary_variant_physical_w149_spec.cr
spec/binary_variant_physical_w149_adversary_spec.cr
```

Use the existing root-owned `run_gate.rb` with unique `w179-qualified-cN-MODE`
labels, isolated caches, the declared flags and serial resource guard. Keep
W176/W177 fixtures at `/private/tmp/crystal-click-w176-release-native.KH635o`
and W178 fixtures at
`/private/tmp/crystal-click-w178-canonical-stock.AAovER`; generate W178 and
W179 library parts into separate fresh empty roots per mode. W179 stock roots
must be produced by the new pinned native runner before the C5 gates. Native
fixture assertions are mandatory, not an optional green path. Code-input
snapshots must be immutable in every successful run.

Native fixtures explicitly disable sparse eligibility
(`ratio_of_defaults_for_sparse_serialization=1`) and exact default counting
(`compute_exact_num_defaults_for_sparse_columns=0`). Every stock part must
have the unchanged W103 version-1/propagated String-1/empty-column serializer
metadata profile. The runner reuses the complete W103 CREATE settings from
`scripts/check_qbit_oracle.cr:367`: mixed/adaptive granularity, granularity 2,
forced Wide parts, plain marks and primary index, LZ4 and the existing 4096-byte
maximum compression block. It checks that exact JSON object, codec metadata,
substream topology, paired `.bin`/plain `.mrk2` inventory, plain `primary.idx`
and the three-row fixture's `[2,1,0]` mark grid. The grid is a fixture constraint,
not a universal ClickHouse packing law. This does not
qualify current-server default metadata, per-column serializers or sparse
storage. Source anchors: `SerializationInfoSettings.h:45`,
`SerializationInfo.cpp:432-442,551-575`, and
`MergeTreeSettings.cpp:97-113,208-217,2626-2635` in the fresh checkout.

Earlier native attempts do not close the part-reader certificate: disabling
exact counting alone leaves sparse-eligible Default-column metadata; disabling
sparse eligibility additionally makes the literal 24+24 oracle pass, but the
first stock-enabled C5 gate then observes compressed `.cmrk2` refusal. Root
pivots to the full existing W103 profile rather than changing the reader or
rewriting generated native files. The failed `w179-final-c5-debug` record has
67 examples, zero assertion failures, one fixture-format error, zero pending
and child/guard exit 1. It is preserved, not counted as a passing final gate.

The finite native matrix is four carriers times dimension 3/default stride,
dimension 9/default stride and dimension 16/stride 8, each bare and Nullable:
24 exact profiles. Independent authored raw bytes include floating NaN
payloads and signed zero without decimal conversion. Require exact descriptor,
RowBinary and plane outputs in the stock direction, stock parts read through
the generic-to-dedicated bridge, and library parts attached/read by the pinned
stock runtime with exact type and literal values. Require complete per-process
argv/SQL/stdin/stdout/stderr provenance, actual exit/signal/timeout and pin
checks. This matrix does not claim all nominal dimensions or recursive
products. Compare DEBUG/RELEASE library-part file inventories and bytes;
requalify any differing output natively instead of assuming parity.

## Executed physical-metadata guard falsifier

Root temporarily disables the QBit branch in the physical plan's bounded
descriptor traversal. `w179-physical-metadata-bypass` then observes five
examples, one unchanged assertion failure, zero errors/pending and child/guard
exit 1, with 976 immutable inputs. The depth assertion fires first; the later
node-budget assertion in that example is not claimed as an executed seeded
falsifier. Log SHA256
`0cf7b9e74161fc4bb33b683be11b72c857b08bdc9e35453e705b3fb0cb5befd3`.
Exact restoration of `binary_bulk_physical_plan.cr` yields SHA256
`f2f18a91b1336f4b40bc34a64540504c141394c15a84143a4a90c92961b97074`.
`w179-physical-metadata-restored` then passes all five examples with zero
failures/errors/pending, unchanged inputs and child/guard exit 0; log SHA256
`b0d489bebdc37dcf1ca8297e1bfd08a2523a166b55b042058808f9cd56577952`.
The final source still has this exact restored hash. The subsequent Object
schema guard adds the 977th code input; it does not change this owner.

## Final execution ledger

| Cohort | DEBUG | RELEASE |
| --- | --- | --- |
| C1 | 207; zero failures/errors/pending | 207; zero failures/errors/pending |
| C2 | 106; zero failures/errors/pending | 106; zero failures/errors/pending |
| C3 | 120; zero failures/errors/pending | 120; zero failures/errors/pending |
| C4 | 149; zero failures/errors/pending | 149; zero failures/errors/pending |
| C5 | 67; zero failures/errors/pending | 67; zero failures/errors/pending |
| C6 | 45; zero failures/errors/pending | 45; zero failures/errors/pending |
| Total | 694 | 694 |

Root reconciles the exact same 78-spec union in both modes, every child and
all twelve actual guard exits/signals, all current 977 code-input SHA256s and
each observed assertion summary/log hash. Every child and guard exits 0 with
no signal or changed code inputs. Cohort log SHA256s (retained as
`/private/tmp/crystal-click-architecture-r1.shwDws/w179-qualified-cN-MODE.log`):

```text
C1 DEBUG   ff58b1e9dcf32d09312130ba6649a9677d4508b570226fd1a17136c36867acd2
C1 RELEASE 7fa22ac9b72246cbc783185bf6483ba9616302fe7331055bc28e1a7910732bb2
C2 DEBUG   f71e780492700e6d74ab2ab574edcf465a4cee99bcd14f0982bcaa6d1d5dede2
C2 RELEASE bbc94be9bc00446d8297ffc485272049d4b37848758e861a0b4152200152dc31
C3 DEBUG   b62cdbdb722a3b75a9562f6d9be2aac7cfbb60a97e92183a78f4cb8964cc4324
C3 RELEASE 11902bc57da63c8002ef214b679d824be04b6aa1b9c4a0cac887bea9c48bb8e4
C4 DEBUG   334ec8dd6520c672c896fc67a9742068e54a481c77a8d7f77e3e41a854519f13
C4 RELEASE a885811acf4c6a29ceb9d7438639f5a5cb9a6931d1b22df62664920c1ae7285a
C5 DEBUG   2e480d853069fdf952f342a26687ea7140088a0b8b302a642e6c76fd0bbcb9c7
C5 RELEASE b36dc09bc5423b593b537cdd7fc8841163e668ded4ce027a275ee6108f7f220e
C6 DEBUG   dfcf12b8d9f85b3d93a379974bc139e10b7ebde47d08a7c5c82eb931e1e99795
C6 RELEASE e29f190ebacf3b795da5eb1355215b6b87d33d863e60a8e0ec13a21e4f1eddab
```

C4 RELEASE emits a Bash `setpgid` warning but completes after approximately
30 seconds with guard exit 0. Root inspects the unchanged guard: it checks
the observed child PGID against the child PID and wrapper PGID, and aborts
75 if isolation cannot be established; its loop retains the 600-s/12-GB and
50%-free limits. No guard is bypassed or relaxed. The passing assertions are
not an engine RSS, heap-allocation or throughput measurement.

The complete W103-profile native run in
`/private/tmp/crystal-click-w179-native-w103-profile.lXp0Tl` passes 24 stock-
authored and 24 library-authored profiles, zero native process failures and
guard exit 0. Root audits all 410 actual status/provenance records, literal
bytes, both runtime pins and all 2,208 stock-part copied file paths/hashes.
Summary SHA256
`18f7ddc109d1e7aff8a9b0b01b467753231e613a1d4b9c50a4eba2b8a36063c8`;
runner SHA256
`ea3a7ccf7be2bb00402848ecd5c715f31b9ac5ce87298a3d32ea0c8d9a2ef056`.
The runner attaches and reads literal library values/planes; it does not
claim a CHECK TABLE command or a build of the fresh source snapshot.
Final C5 DEBUG and RELEASE consume these fixtures and each pass 67 examples.
Their 24 exported parts and manifest match all 2,185 file paths/hashes in the
native-qualified bootstrap library root, and both modes match each other.
Final C1 DEBUG and RELEASE each pass 207 examples and reproduce all 756 file
paths/hashes of the 63 W178 native-qualified Count parts. All observed final
gates have 977 immutable code inputs and actual child/guard exit 0. The exports
are retained separately under
`/private/tmp/crystal-click-w179-qualified-exports.mrVg5U` in
`qbit-debug`, `qbit-release`, `count-debug` and `count-release`.

Scoped hostile verdict: ROBUST for these nominal descriptors, bit-exact
scalar/bulk laws, bounded admission/refusal boundaries and finite paired
witnesses. Root independently checks source dispatch/identity, native literal
observations, fixture metadata and the executed guard falsifier. Luna's review
is corroboration, not independent verification by model agreement. Physical
shape alone does not supply nominal provenance; generated-role budgets do
not supply total heap accounting; empty windows do not carry typed values.
No arbitrary recursive QBit, current-server default profile, general JSON,
MV/projection or performance claim is promoted by this verdict.

## Observed commands and refresh boundary

Root runs the final serial driver from the repository cwd:

```sh
/usr/bin/ruby /private/tmp/crystal-click-architecture-r1.shwDws/run_w179_final.rb
```

The retained driver contains the exact six rosters, fixture/export roots and
per-child environment. It invokes each cohort with the unchanged
`run_safe.sh /usr/bin/ruby 600 12288 run_gate.rb LABEL MODE SPEC...`, a 50%-free
preflight and an isolated Crystal cache. Each compiler command uses
`--single-module --threads 1 --link-flags=-fuse-ld=ld --error-trace`, the Xcode
macOS SDK, and `--release --no-debug` only in RELEASE. Labels are
`w179-qualified-cN-debug` / `w179-qualified-cN-release`; modes share the exact
78-spec union. The driver JSON retains actual guard exits/signals separately
from each child result. It is an index to executed evidence, not a substitute
for assertions or literal native observations.

The independent pinned native matrix is executed with:

```sh
env COGNI_RUN_SAFE_MIN_FREE_PCT=50 RUN_SAFE_PASSTHROUGH_STDIO=1 TMPDIR=/private/tmp \
  W179_LIBRARY_PART_ROOT=/private/tmp/crystal-click-w179-bootstrap-library.Rntg7x \
  /bin/bash /Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh \
  /usr/bin/ruby 600 12288 scripts/check_qbit_binary_kernel_w179.rb \
  /private/tmp/crystal-click-w179-native-w103-profile.lXp0Tl
```

These are observed commands with retained run identities, not instructions to
overwrite a witness root. A refresh must allocate new empty output roots and
new gate labels, bootstrap owned library parts, run the native runner and then
run the mandatory stock-enabled rosters in both modes. If source, compiler,
runtime, admission/profile settings or fixtures change, refresh the affected
certificate before consuming it as current. If temporary records disappear,
their hashes remain historical lineage only; regenerate the witnesses and
repeat qualification rather than treating a hash or this document as proof.

Next frontier: paired nominal JSON v0 descriptors and structured root RowBinary
with bounded SKIP/SKIP REGEXP metadata and effective Dynamic caps. General
persisted Object layouts, other AggregateFunction states, arbitrary-schema
parts, MV/projection planning/writing and large-facade decomposition are open.
Memory/performance and the eventual ClickHouse throughput comparison remain
deferred and unmeasured. Standing authority is in-scope reversible local work
and atomic qualified local commits; remote push is not authorized.
