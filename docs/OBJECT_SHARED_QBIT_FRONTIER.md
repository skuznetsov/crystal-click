# Object shared QBit frontier (W199)

Status: VERIFIED within the executed finite internal-adapter scope. Baseline
`579e088` (2026-10-06). This is a type-composition slice, not a
full-types, MV/projection, performance or overall-goal completion claim.

## Contract

Admit owned direct QBit children in `BinaryValue.dynamic` and their paired
owned scalar Dynamic RowBinary envelopes, and direct ordinary QBit actual arms
at already admitted Dynamic sites in
the normalized bulk planner, physical binding and Object shared-path Data
prefix/body adapter. Preserve element identity, dimension and effective
stride. Reuse `QBitPlaneCodec` and the existing binary QBit bridge: scalar
RowBinary is not a physical bulk lane. Logical planes use zero-based numeric
`qbit_plane.i`; physical tuple planes use escaped one-based `%2E(i+1)` names,
in group-major, MSB-first order, independently of lexical role sorting.

Retain existing root/Nullable QBit behavior and all caller depth, node,
element, wire and materialization admission bounds. Actual sites need their
own plane traversal context; the root-only `qbit_column` cannot describe a
Dynamic roster or two distinct QBit occurrences. Preflight count-derived
role metadata and retained raw values before allocation. Empty rows still
validate metadata and callback topology; they cannot authenticate a nominal
type from absent values alone.

Selected-range validation checks the descriptor, stream grid and plane widths
at every real mark, but traverses discriminator/value bodies only in selected
marks. A zero-row window is therefore a metadata/shape check, not a full-body
corruption audit of unselected marks. Do not strengthen that certificate into
an eager validation promise.

Still rejected here: QBit inside direct Array/Tuple/Map/LowCardinality/Variant
descriptors, Object declared typed-QBit paths, QBit SharedVariant/borrowed
envelopes. A direct QBit actual at an already admitted nested Dynamic site
uses the same per-site adapter; this does not qualify arbitrary recursive
products or change the scalar API's preexisting Dynamic-of-Dynamic policy.
JSON-as-Dynamic-actual,
Compact advanced complete parts, stock roster promotion/merge policy and
public library-written QBit-in-JSON complete parts remain subsequent work.
Those boundaries are not a substitute for eventually implementing legal
ClickHouse type combinations.

## Recursive composition, not a Cartesian serializer matrix

Base value serde is reusable. A wrapper owns the child occurrence grid,
stream names, prefix/body state and admission accounting, then delegates its
leaves to the existing codecs. Array maps parent rows to flattened child
occurrences; Nullable adds its null map; LowCardinality binds dictionary and
index schedules; Dynamic and Object bind actual-type/path rosters. These are
physical storage contracts, not a reason to duplicate each leaf serializer.

The pinned ClickHouse source follows the same pattern: `DataTypeQBit.cpp`
constructs a nested Tuple of FixedString planes, and `SerializationQBit.cpp`
delegates stream enumeration, bulk prefix/suffix and bulk bodies to that
nested serialization. RowBinary and multiple-stream part storage still have
different representations.

W199 adds one per-site `BinaryDynamicQBitSite` owner, not another transpose
algorithm. It reuses `BinaryQBitBulkCodec`/`QBitPlaneCodec` and threads the
prepared site context through the existing recursive visitor. The remaining
work is to admit and qualify missing wrapper contracts and public part
composition; it is not a serializer for every combination of base types.

## Risk and execution plan

Risk: CAUTION, shared recursive codecs and persistent stream contracts.
Rollback: revert only the exact eventual atomic local W199 commit; no push,
no unrelated changes. Root owns serial compiler/native execution and Git;
Luna owns the bounded candidate implementation and harness.

Strongest failure: a self-roundtrip hides wrong plane order, group stride,
nominal metadata or absent per-site scratch/materialization preflight.
Independent literal planes, native path Data and direct typed native reads
are the discriminators. Preserve refusal tests for excluded owners.
In particular, two QBit actual arms must share one retained-byte admission
bound; Array(Dynamic) child occurrences are not the parent's root row count.
Tuple dots become `%2E1`, not `.%2E1`, and zero-byte callbacks for unselected
arms remain part of the exact callback tape.

1. Add `spec/binary_dynamic_qbit_w199_spec.cr` and
   `spec/object_shared_path_qbit_w199_spec.cr`; execute baseline assertion RED
   plus a passing primitive control before production edits.
2. Update QBit branches in `binary_dynamic_bulk_plan.cr`,
   `binary_dynamic_bulk_physical_plan.cr`, `object_shared_path_codec.cr` and
   `binary_value.cr`/`binary_dynamic_envelope.cr`'s direct owned Dynamic child
   admission and the shared bulk traversal context as required. Qualify owned
   scalar Dynamic RowBinary composition explicitly; borrowed/SharedVariant
   guards stay.
   Keep a cohesive new owner
   in one file; do not implement a second bit transposition algorithm.
3. Run focused specs, then the exact affected union of W198's 130 specs,
   dedicated QBit specs and W199 specs, in DEBUG and RELEASE. Use isolated
   caches and the unchanged 600s/12288MiB/minimum-free50% guard, serially.
   Expected: nonzero examples, zero failures/errors/pending, actual exit0,
   identical rosters and immutable source/spec inputs across successful gates.
4. Fresh `scripts/check_object_shared_qbit_w199.cr` builds and the supervised
   Ruby runner qualify actual stock Data/event tapes. Include all four
   carriers, padding at default dimension9, and group order at dimension16/
   stride8, ordinary String0/1 and shared versions2/3. Require independently
   authored raw bytes, persisted PK/type/direct native observations, complete
   lane consumption and unchanged part-file snapshots. Record the executed
   finite matrix rather than inferring untested products.
5. Root hostile review attacks nominal identity, numeric-vs-lexical plane
   order, multiple sites, empty/missing/default rows, truncated/trailing tapes
   and budget bypass. Synchronize status and evidence only after actual gates;
   make a scoped atomic local commit. No remote action is authorized.

Reference: clean unbuilt depth1 source
`/Users/sergey/SrcArchives/clickhouse-2026-10-05-depth1-ef037e60`, revision
`ef037e60fc7f5654c8c80eefb8be82e3c56f9a67`. The separate native runtime is
`26.10.1.1201`, build `d9bcb5ab007f0f6299f7f973f2642245bab3d028`, SHA256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
Neither is claimed to be the other's build or latest upstream revision.

## Continuation and decay

Baseline observation (2026-10-06): the eight existing dedicated QBit spec
files passed 66 examples, zero failures/errors/pending, actual exit0. The
two new W199 spec files compiled and produced five assertion failures,
zero errors/pending, actual exit1: owned construction, literal owned envelope,
Dynamic role planning, independent bulk lanes and Object path tape each
demonstrate a separate current refusal. Logs are retained under
`/private/tmp/crystal-click-w199.unDs8K/{baseline-qbit,red-qbit}.log`.
The initial sandbox attempt aborted with exit75 because `ps` was denied;
the unchanged guard was rerun with process-monitoring permission, not bypassed.

Dynamic value equality retains its preexisting identity semantics; tests
authenticate nominal identity, selected raw bytes and re-encoded envelopes,
not a new structural equality API. An incorrect Float32 oracle initially
packed two independent row planes together; the expected literal bytes were
corrected, without a production change.

Final focused DEBUG passes 29 examples. The exact same 136 affected spec
files pass 897 DEBUG and 897 RELEASE examples, zero failures/errors/pending,
actual guarded exits0. After formatting, the 946-file source/spec identity
is unchanged across final serial suites, fresh helper builds and native
requalification: SHA256
`5cd91f054d03f5e1aaa256faa1b35d6fd829ed01b8db2c0e002fd5557007de37`.
Logs: `focused-final-formatted.log`, `affected-debug-final-serial.log`,
`affected-release-final-serial.log` under the scratch root above. A detected
accidental DEBUG/RELEASE overlap was stopped at the newly started RELEASE
compiler; that exit143 and overlapping gates are excluded from the certificate.

Fresh DEBUG and RELEASE helpers each inspect 48 stock Wide parts: four
carriers, three dimension/stride shapes, shared versions2/3 and String0/1.
Each mode authenticates 120 path Data/event records, 288 bucket/chunk
schedule records and 288 full/middle direct typed native rows, plus native
zero-window markers. Separate native CHECK,
schema, part inventory, PK, missing/zero values and nominal identity pass;
all 2064 source part files per mode remain unchanged. Normalized observations
agree between modes. No library-written part ATTACH/CHECK was executed here.

Root independently reconstructs literal raw bytes and group-major MSB-first
plane bodies, checks numeric callbacks and padding, and rejects three seeded
mutations per mode (callback swap, changed plane byte, wrong nominal type).
Separate provenance checks authenticate five process records and 73 retained
artifacts per mode, including actual SQL bytes, executable hashes, argv,
stdout/stderr, helper manifest and 48 literal RowBinary inputs; eight extra/
duplicate native-output mutations per mode reject. The initial captures had
referenced unsaved SQL files; the runner now saves sent bytes and the final
captures were rerun in fresh roots, rather than promoting incomplete evidence.

Final captures:
`/private/tmp/crystal-click-w199-native-debug-formatted.FKMKQN` and
`/private/tmp/crystal-click-w199-native-release-formatted.JBT9JT`.
Root reconciliation logs: `provenance-formatted.log` and
`planes-formatted.log`. Ruby syntax/self-test, Crystal format checks and
`git diff --check` pass. Scoped adversary verdict: ROBUST for the declared
internal adapter and finite corpus, not all recursive products or public
complete-part compatibility. The evidence index is
`.landmark/evidence/object-shared-qbit-w199.json`; it is not proof by itself.

The previous goal turn was progress: W198 added a native-qualified public
Nested complete-part corpus at `579e088`. The active frontier is now QBit
actual-path composition. After its internal adapter qualification, return to
public complete-part QBit read/write, then JSON actual-path and remaining
legal recursive layouts. Full types and broader MV/projections remain open;
memory/performance work remains deferred.

This certificate is scoped to its pinned source/runtime/fixtures; changed
dependent codecs, helper/runner, runtime, profile settings, compiler or missing
temporary observations require refresh. Temporary binaries, logs, parts and
root reconciler scripts are not committed. Reopen dependent claims if the
certificate decays; the overall goal remains incomplete.
