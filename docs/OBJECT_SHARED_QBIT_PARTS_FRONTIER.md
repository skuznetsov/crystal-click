# Public Object shared QBit parts frontier (W200)

Status: VERIFIED within the executed finite corpus; scoped adversary verdict
ROBUST. Baseline
`6b6144c` (2026-10-06). Previous internal-adapter evidence is in
[OBJECT_SHARED_QBIT_FRONTIER.md](OBJECT_SHARED_QBIT_FRONTIER.md). The overall
objective remains all legal supported ClickHouse types and MV/projections,
then memory/performance optimization and a measured reader gap of at most 10%.
This slice does not redefine that completion condition.

## Public contract

Qualify the public `WidePartWriter.write_uint64_object_pair` and
`ObjectColumnReader` for complete Wide root
`JSON(max_dynamic_types=1, max_dynamic_paths=0)` parts containing a direct
ordinary QBit actual at shared path `q`. Reuse existing value/bulk/Copy/path
owners. No alternate writer, post-publication lane replacement, new transpose
algorithm or serializer per recursive type product is admitted.

Recursive composition is the implementation model, not a missing capability
in principle. Leaf value codecs are reused; container owners supply cardinality,
offset/null-map/discriminator streams, dictionary lifetime and prefix/body
state. The same child can require scalar serde in a SharedVariant envelope
and bulk serde in a dedicated Data stream. Remaining combinations therefore
mean legal storage contracts and independently qualified layouts, not a new
serializer for every Cartesian product. Guards on unqualified legal layouts
are library limits; ClickHouse's illegal nesting rules are a separate boundary.

The finite executable matrix has four carriers (Int8, BFloat16, Float32,
Float64), three shapes (dimension3/default stride3, dimension9/default
stride9, dimension16/stride8), shared versions2/3 and String profiles0/1:
48 profiles. Each has four authored rows, two real marks `[2,2]`, two shared
buckets and target stock chunk rows1. Rows are literal QBit bytes, missing
path, present all-zero QBit, then different literal QBit bytes. Preserve
nominal type, dimension, effective stride and raw signed-zero/NaN payloads.

Both stock and public library-written origins must pass public full marks
`(0,2)`, middle `(1,1)` (PK3,4) and zero `(2,0)` reads. Authenticate persisted
shared/String profiles and actual mark grids, not echoed fixture labels.
Native ATTACH/CHECK of library parts, re-CHECK of stock parts, whole-Object
source/library readback and independently authored direct typed path reads
must all pass. A JSON text representation alone cannot authenticate floating
point raw payloads; direct QBit RowBinary observations must compare raw bytes.

Always-spill is a legal writer policy only if those native consumers accept
it; matching stock insertion/merge roster-selection policy is not required.
No production change is justified if existing public owners already compose
the requested direct QBit actual. If an executable refusal exists, admit only
the needed paired child-codec boundary after observing it, with the same
caller budget/depth/materialization checks and negative guard width.

The initial public-part spec produced an actual guarded runtime exit1:
one example, zero assertion failures, one error and zero pending. The public
writer reached `ObjectSharedCopyCodec` and refused direct QBit in
`BinaryValueCodec.encode_dynamic_bulk_child`. The paired decode helper has
the same blanket guard. Only `src/crystal_click/binary_value_codec.cr` is
admitted for the production change: permit the direct QBit tag, retain
QBit-containing wrapper refusal and all borrowed/JSON/aggregate guards.
`BinaryQBitValueCodec` already owns the required scalar dimension/raw bytes;
no envelope, value construction or plane algorithm change is needed.

## Remaining rejected/non-qualified surface

This slice does not widen direct static QBit wrappers, Object declared typed
QBit paths, arbitrary borrowed/SharedVariant APIs, JSON-as-Dynamic-actual,
Compact advanced parts or arbitrary dictionary/roster/chunk schedules without
matching evidence. Existing guards remain unless a specific public complete-
part falsifier demonstrates that a narrow paired admission is necessary.
Zero selection is not a full-body audit of unselected data. Full types,
broader MV/projections and repository-wide class decomposition remain open;
performance work stays deferred.

## Observed qualification

The final focused DEBUG gate passes 33 examples. The same exact 138 affected
spec files pass 901 DEBUG and 901 RELEASE examples, with zero failures,
errors or pending and actual serial guarded exits 0. The 948-file source/spec
identity is unchanged across the final gates, fresh helper builds and native
captures: `9930ddec3d421f9a4b36aeb95b3a26ece884abd132f95ea303272202c94b774b`.
An earlier affected DEBUG run was invalidated when formatting changed this
identity; it is not the final certificate.

Fresh DEBUG and RELEASE helpers and native runs each qualify all 48 profiles.
Each capture contains nine supervised invocations: four source batches, the
public helper and four ATTACH/read batches. All 48 library-written parts pass
native ATTACH/CHECK; all 48 stock parts are re-CHECKed. Each native family
(whole Object bytes, nominal type and direct nullable typed bytes) has 864
observations: 288 initial stock rows plus 576 attached stock/library rows,
including full and middle selections. These are observations, not 864 distinct
input rows. The public helper performs 288 full/middle/zero selected mark-window
reads, preserving 576 selected rows. Persisted typed paths, Object dynamic paths
and Dynamic structure rosters are empty on both sides, authenticating the
shared-only route rather than merely accepting echoed profile labels.

Root's read-only reconciliation authenticates raw process/SQL/file provenance,
separately authored literal envelopes and payloads, nominal type, presence and
PK/window rosters. It rejects 18 semantic report/output mutations per mode and
single/duplicate-capture controls. Root also checks hand-authored Float32
signed-zero/NaN and missing-path byte sentinels directly in both captures.
Normalized helper reports and all 2016 generated files agree between modes.
Each mode retains all 4080 stock/generated published files unchanged and
authenticates the 4128 files in the active native part snapshots. Snapshot
counts overlap stock paths and must not be added as distinct physical files.

The first native DEBUG attempt stopped at an overly strict attached-copy
invariant, not a format rejection: ATTACH added only
`invalidated_system_columns.txt`; no published file was removed or changed.
The clean source's `MergeTreeData.cpp:9035-9045` explicitly writes this metadata
on ATTACH. `IMergeTreeDataPart.cpp:1911-1918,1932-1938` supplies the ordinary
system-column names and newline encoding. The repaired runner allows only
that one root-level addition on a library ATTACH part when absent from its
published snapshot, with exact 28 bytes `_block_offset\n_block_number\n` and
SHA256 `7409424ab45090c1261e622f7423393905102e7e8cba36a6db88eb513ce1e06c`.
The byte order is pinned-runtime observed, not guaranteed by the unordered
source name set. All retained published entries and full active before/after
snapshots remain exact; wrong contents, unknown additions and source-scope
allowances are rejected. Fresh final captures execute this repaired rule.

Only two paired direct-QBit admission guards changed in production. Scalar
QBit and existing recursive Object/Dynamic owners are reused; no new value
serializer or transpose algorithm was introduced. Native whole/direct readback
qualifies the typed column route, not nominal preservation through arbitrary
ClickHouse Field inference. Commands, exact rosters, hashes and raw evidence
pointers are indexed in `.landmark/evidence/object-shared-qbit-parts-w200.json`.

## Risk, rollback and execution

Risk: CAUTION, persistent-format/public compatibility evidence. Rollback:
revert only the exact scoped atomic local W200 commit. No push, unrelated
changes, new dependency or ClickHouse build. Luna owns candidate source/test/
harness work; root owns all serial compiler/native executions and Git.

Strongest failure: library roundtrip or native CHECK succeeds while direct
path reads lose nominal QBit metadata, row presence or exact raw bits. Guard
with independent authored raw values, paired whole/direct queries, actual PK
and persisted profiles, immutable source/generated snapshots and seeded
oracle/report failures. Do not treat correlated model agreement as proof.

1. Enumerate public writer/reader child-codec consumers and source boundaries.
   Run the existing W199 focused control and the new
   `spec/object_shared_qbit_parts_w200_spec.cr` (plus a targeted shared-envelope
   spec only if needed). Capture an actual runtime refusal before production
   edits, or retain an already-green implementation and qualify native parts.
2. Candidate changes, if needed, stay in the exact inventoried codec owners;
   reuse recursive visitors and caller budgets. New owners have one class per
   file. Root checks the diff and excluded owner/materialization falsifiers.
3. Run focused specs and W199's exact 136-file affected roster plus W200 specs
   in DEBUG and RELEASE, using isolated caches and the unchanged
   600s/12288MiB/minimum-free50% guard. Require nonzero examples, zero failures/
   errors/pending, actual exit0, identical rosters and source/spec identity
   before/after the final successful gates. Compiler/native jobs are serial.
4. Fresh builds of `scripts/check_object_shared_qbit_parts_w200.cr` and its
   supervised Ruby runner create/reopen parts through public APIs and execute
   all48 profiles in each mode. Preserve actual SQL before execution, raw
   binary/argv/stdin/stdout/stderr records and source/generated file hashes;
   require complete global observation cardinality and strict failure on
   extra, duplicate or missing records. Reconcile normalized modes and paired
   generated files without confusing chunk records with selected mark windows.
5. Root hostile self-review attacks raw bit identity, nominal type, missing
   versus present-zero, numeric plane order, profile propagation, multi-mark
   selection, budgets, ownership and failure-sensitivity. Update project
   status/evidence only after actual gates; make one scoped local commit.

DoD commands are the guarded `crystal spec` invocations over the exact roster,
fresh guarded DEBUG/RELEASE helper builds, and the guarded Ruby runner with a
fresh canonical empty `/private/tmp` root per mode. Exact commands, rosters,
exit signals and observed hashes will be retained in the execution evidence;
the index alone is not proof.

## Reference, continuity and decay

The clean unbuilt depth1 source is
`/Users/sergey/SrcArchives/clickhouse-2026-10-05-depth1-ef037e60`, HEAD
`ef037e60fc7f5654c8c80eefb8be82e3c56f9a67`; it is not claimed latest October6
or the runtime build. Native runtime is `26.10.1.1201`, build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`, SHA256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
Root independently rechecked these pins at W200 entry. Compiler is
Crystal1.21.0/LLVM22.1.8/aarch64. Native supervisor retains10s/grace2s,
max_threads1 and512MiB per ClickHouse process under the outer guard.

Current scratch root: `/private/tmp/crystal-click-w200.Vrbgic`. The initial
runtime refusal is retained in `red-public-qbit.log`. Final captures are
`/private/tmp/crystal-click-w200-native-debug-final.0axxxh` and
`/private/tmp/crystal-click-w200-native-release-final.KkBRgR`; root reconciliation
is in `reconciled-final.json`. Changed dependent source,
compiler/runtime, profiles or missing temporary evidence requires refresh;
reopen dependent claims and retain unsupported guards on failure. After this
slice, return to remaining legal recursive storage contracts and JSON actual
paths, then the full-types/MV/projection frontier; do not advance to performance
on the strength of this finite corpus.
