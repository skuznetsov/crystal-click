# LowCardinality Float identity frontier (W144)

Status: implemented and VERIFIED within the scope below, 2026-10-03.
Baseline: `2060382`.

## Boundary

W142's standalone LC codec transports exact scalar bytes. W143 admits
non-floating LC sites in recursive bulk and guards Float32, Float64 and
BFloat16, including empty inputs. This slice first qualifies the boundary
between transporting an already typed LC dictionary and constructing one
from a non-LC column. Equal SQL floating values need not have equal bytes.

The fresh source reference is the separate shallow checkout
`9007d227b64a3f8b667fc5258ceb2923f3cf477d`. The retained executable is
26.10.1.1201, build `d9bcb5ab007f0f6299f7f973f2642245bab3d028`, SHA-256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
It is not a build of that source checkout. Both identities must be recorded.

Admitted by the implementation: raw Float32/Float64/BFloat16 LC transport in
ordinary recursive `BinaryBulkCodec`, using the existing standalone physical
owner and legal Array/Tuple/Map/Nullable composition. This is already-LC-typed
transport, not numerical equality or an INSERT constructor. Object/Dynamic
envelopes, persisted role binding, complete-part writing, Float SQL operators,
performance and RSS are not widened by this slice.

## Competing predictions

1. Plain raw Native into Memory preserves +0, -0 and distinct signed NaN
   payloads; this control must pass before attributing a later difference to
   LC construction.
2. Non-LC Memory to LC MergeTree INSERT SELECT uses range construction:
   default comparison may collapse signed zero and NaNs may become one
   canonical payload. `ColumnUnique.h` has distinct raw-data and range paths.
3. Direct additional-only LC Native may preserve its dictionary bits across
   ingestion and part persistence. It must be measured, not inferred from
   the behavior of non-LC insertion or serializer source alone.

Source inspection predicts that (3) is false for the ordinary Native route:
`SerializationLowCardinality.cpp:702-713` range-inserts additional keys,
and Native rejects global dictionaries (`:185-190`). Part serialization also
compacts and range-inserts keys (`:575-591`). A source prediction is not the
runtime result below. The alternate persisted read boundary at `:663-670`
constructs a unique column over deserialized global keys; the no-additional
branch at `:715-722` binds the shared dictionary without rebuilding its keys.

Two different insertion orders distinguish canonical identity from a
first-observed representative. Full bit vectors, dictionary entries and IDs
are evidence; NaN textual output, a self-roundtrip or row counts alone are
not.

## Probe and decision rules

Risk: CAUTION (serialization identity and native process execution).
Recovery: clean baseline plus new isolated evidence directories; no existing
ClickHouse data or source checkout is modified. Root executes compiler and
native commands serially under the existing memory guard. Luna authors the
new oracle only; root reviews output and owns any admission decision.

Probe owners: `scripts/check_low_cardinality_float_identity_w144.{cr,sh}`.
Use literal raw inputs for Float32/64/BFloat16, twelve rows, fixed outer
granularity four, positive and negative zero, two distinct signed NaNs,
ordinary values and repeats, with two input orders. Preserve native inputs,
SQL, stderr, result bits, part lanes, grids, dictionaries and ID sequences.
Assert the plain Memory control and decoded part logical values against the
stock raw-bit query. Seed a bit/ID mismatch and require comparator rejection.

DoD for the discriminator:

```
COGNI_RUN_SAFE_MIN_FREE_PCT=50 RUN_SAFE_PASSTHROUGH_STDIO=1 \
  /Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh \
  /bin/bash 900 32768 scripts/check_low_cardinality_float_identity_w144.sh
```

The wrapper additionally requires root authorization and a fresh absolute
`W144_CHECK_ROOT`. Expected signal: all declared raw controls and corruption
controls pass, all twelve route/order/type observations reconcile with their
retained part lanes, terminal exit zero. Native BFloat16 rejection is an
unqualified boundary, not permission to substitute Float32 and report success.

Second discriminator: `scripts/check_low_cardinality_float_part_w144.cr`
borrows each stock Wide template into a new isolated
`/private/tmp/crystal-click-low-cardinality-float-part-w144.*` tree. It replaces
only LC dictionary/index lanes and marks with actual W142 raw codec output
and `CompressedMarkWriter`, rebuilds content/frame checksums, and asks stock
to ATTACH, CHECK and query complete and middle raw-bit vectors. All other
metadata is explicitly borrowed. This is a raw persisted dictionary reader
witness, not an independent complete-part writer or Native identity test.
The literal expected bits must include both signs of zero and distinct NaNs;
a valid wrong-bit part and an invalid-hash/frame control qualify the test.

If this persisted witness succeeds, add
`spec/binary_low_cardinality_float_bulk_w144_spec.cr`, run its existing
recursive Float refusal as RED, then remove only the Float-specific gate in
`BinaryBulkTypePlan`. Existing shared physical owners keep raw-byte identity,
and the old W143 empty-Float refusal example becomes an admission regression.
Do not add a numeric-equality policy to an already LC-typed transport API.
Run focused DEBUG, affected RELEASE, complete unique spec inventory, both
new native probes and unchanged W143 native container regression before an
atomic local commit. Object/Dynamic/physical-plan guards must remain closed.

If direct LC transport preserves bytes, consider admitting recursive Float
LC with explicit raw-dictionary semantics and unchanged standalone behavior.
If it canonicalizes, determine the responsible boundary before choosing a
separate insertion policy. Never silently change raw-byte APIs to numerical
equality. Source or runtime drift invalidates the native certificate; relevant
codec, occurrence, identity or framing edits require rerunning the checks.

## Observed policy and implementation

Root's identity attempt02 passed all six type/order cases. Plain Native into
Memory preserves every authored bit. Both Memory-to-LC INSERT SELECT and
additional-only LC Native ingestion normalize negative zero to positive zero
and both tested signed/distinct NaNs to one positive quiet NaN. The stock
persisted dictionary/index replay reconciles with the normalized query output.
Each case also rejects a seeded bit mismatch. The two orders give the same
canonical representatives, not first-observed representatives.

Root's raw persisted-part attempt02 passed all six cases: borrowed stock
templates, raw W142 global dictionary/index lanes, and valid-hash seeded parts
all ATTACH and pass actual CHECK. Full twelve-row and middle `k=4..7` queries
preserve signed zero and both NaN payloads exactly. A +1 ULP seed changes only
the first occurrence of the fixture's positive-one value (k=4 in order A,
k=3 in order B); comparing its output against the unchanged literal base is
rejected. The Float32/order-A frame control flips only the compressed frame's
checksum byte, rebuilds matching part hashes, attaches successfully, and
receives CHECKSUM_DOESNT_MATCH / a single-bit checksum diagnostic from CHECK.
Other template metadata and file contents are unchanged by explicit checks.

The policy decision is therefore raw-byte identity for already typed LC
transport. Normalizing these APIs to emulate INSERT would destroy information
that stock reads from an existing global dictionary. Only eight Float veto
calls and their helper are removed from `BinaryBulkTypePlan`; no dictionary
algorithm, descriptor policy, role counts, occurrence schedules, budget owner
or persisted guard changes. The old W143 Float refusal becomes a positive
zero-grid/two-empty-mark/nested-empty-Array regression for all three widths.

The eleven W144 examples use literal dictionary bytes/IDs and selected raw
bits, ±infinity/subnormals, repeated -0 and exact/distinct NaNs across marks,
NULL versus +0, Array/Tuple/Map composition, StringWithSize, exact and one-short
budgets, all-empty inputs, unselected invalid IDs and duplicate non-reserved
NaN keys. Object/Dynamic/physical-plan refusal remains tested. Root observed
the pre-change Float refusal as RED (nine examples: one failure, seven errors,
one retained-guard pass), and then 91 focused DEBUG and 266 affected RELEASE
examples passing after the minimal admission change.

An independent root-authored Ruby probe reopens the twelve raw/seeded stores
with 48 fresh stock queries, checking actual CHECK, nominal types, full and
middle bits against separate literal integer vectors. It also checks all 72
retained ingestion rows with exact integer arithmetic, including UInt64 values
above 2^53. This fallback does not call Crystal's expected-vector builder or
decoder. Its first run encountered the system Ruby's unavailable `filter_map`;
replacing it with map/compact gave exit zero. That failed run is not counted.

Initial successful evidence roots (ephemeral, not repository fixtures):

- `/private/tmp/crystal-click-low-cardinality-float-w144.IueXYd-02`:
  `check.log`, `results/{manifest.tsv,vectors.tsv}`, queries and retained lanes.
- `/private/tmp/crystal-click-low-cardinality-float-part-w144.IueXYd-02`:
  `results/{run.txt,assertions.tsv,raw-bits.tsv}`, queries, modified parts/lanes.
- `/private/tmp/crystal-click-w144.IueXYd`: RED, focused/release logs,
  root Ruby fallback source and `root-float-oracle-03` outputs.

This finite profile is not a complete-part writer certificate: envelope,
primary index, serialization metadata and other lanes are borrowed from stock.
Nullable and recursive Float LC have paired unit composition evidence, not
exhaustive independent native parts for every nesting/parameter combination.
The frame corruption witness covers one Float32 case only. Neither insertion
canonicalization nor raw dictionary reading proves Float SQL operators,
Object/Dynamic integration, other LC record profiles or performance.

Source/runtime drift, edits to the codec/site planner/identity/framing/guards,
or a changed compiler invalidate dependent certificates. Refresh by rerunning
the focused/release/inventory gates and fresh native probes with explicit pins.
Missing temporary artifacts require new isolated runs, not a claim that old
logs are live evidence. Next: shared persisted LC binding and paired Object LC
fields with independently owned library parts, then remaining type/MV profiles.

## Runtime recovery, 2026-10-03

The earlier `/private/tmp` runtime and W141/W143 evidence directories became
absent during this probe. The cause is unknown. Historical certificates are
not fresh executions and their disappeared artifacts must not be treated as
currently available inputs.

Root recovered the exact expanded executable, without changing any runtime
pin, from the official immutable CI artifact:

`https://clickhouse-builds.s3.us-east-1.amazonaws.com/REFs/master/d9bcb5ab007f0f6299f7f973f2642245bab3d028/masterci/build_arm_darwin/clickhouse`

The full self-extracting carrier is 185,881,266 bytes, SHA-256
`0e91aa9b4aa2ce12b5522d8bc35c99b93d9da6e88dfe5f811f7ad6b3577c45c2`.
Guarded `local --version` expands it to 919,123,095 bytes, SHA-256
`5bb43958f4c0806cc363b84b9858e7206e56ac80263a24acc704271322e531ae`.
The source-defined `programs/CMakeLists.txt:270-275` strip recipe,
`llvm-strip -o <new-output> --strip-debug --remove-section=.comment
--remove-section=.note <expanded-full-input>`, produced 746,226,224 bytes
with the exact pre-existing SHA-256 `bb321871...832a79e2` above. Matching
that hash, rather than assuming strip reproducibility, is the recovery gate.
The recovered file is
`/private/tmp/crystal-click-w144-runtime-recovery.Pm8VNb/clickhouse-stripped`;
a nonsymlink hard link restores the original pinned executable path for
unchanged older oracle drivers. No previous evidence directory was recreated.

The first identity attempt, `...float-w144.IueXYd-01`, passed runtime identity
and the Float32 raw Memory control, then correctly rejected an unintended
non-adaptive `.mrk` template. Its DDL had `index_granularity_bytes=0` despite
requiring `.mrk2`. The corrected profile pins a positive 10 MiB granularity
byte bound and mixed granularity with maximum four rows, retaining the strict
three real adaptive marks plus terminal requirement. A failed partial attempt
is not the six-case certificate.

The first raw-part attempt correctly stopped at stock's numeric LC opt-in
requirement (Code 455). Supplying `allow_suspicious_low_cardinality_types=1`
to each isolated query fixed the harness precondition, not a codec defect;
attempt01 is not counted as a successful part certificate.

## Executed closure certificate

Root ran all compiler/native processes serially with
`COGNI_RUN_SAFE_MIN_FREE_PCT=50`, `RUN_SAFE_PASSTHROUGH_STDIO=1`, the existing
`/Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh` and a 32,768 MiB
guard allowance. Crystal used isolated caches, `--single-module --threads 1`,
`--link-flags=-fuse-ld=ld --error-trace`, and SDKROOT
`/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`.

Executed gates, all exit zero unless explicitly identified as RED above:

- Focused DEBUG: nine spec files, 91 examples, zero failures/errors/pending.
  `.../crystal-click-w144.IueXYd/focused-debug.log`.
- Affected RELEASE: thirty spec files, 266 examples, zero failures/errors/pending.
  `.../crystal-click-w144.IueXYd/affected-release.log`.
- Complete inventory: 371 unique spec files, sixteen serial disjoint
  non-release groups, 2,386 examples, zero failures/errors/pending. The runner
  asserts uniqueness, file count and completed group count. This is not a
  combined-process or RELEASE inventory certificate.
  `.../crystal-click-w144.IueXYd/{full-inventory.log,full-spec-inventory.txt}`.
- Post-review focused DEBUG repeats all 91 examples successfully on the final
  files: `.../crystal-click-w144.IueXYd/final-review-debug.log`.
- Five final Crystal paths pass `crystal tool format --check`; both new shell
  drivers pass `bash -n`; `git diff --check` passes.

The full/RELEASE gates ran with the `src/spec/scripts` seal
`f10a9f6e8133fd6aab71a8cb109e84dea3bf95bb012b51d4b53b8cdb527542bb`.
The only subsequent change within those directories corrected one Array test
title from "selected middle mark" to "selected later mark"; its body was not
changed. The post-review focused gate and final native probes ran with seal
`95c08d80404e1c7e1ba77a3db945d2ef67d4f39ced1e74d03d26fc56ca3f2aa0`.
Both seals use `rg --files src spec scripts | LC_ALL=C sort |
xargs shasum -a 256 | shasum -a 256`; documentation is excluded.
Baseline `2060382` plus the scoped diff and these seals identifies the tested
source state without treating a metadata field as execution evidence.

Fresh post-format native roots:

- `/private/tmp/crystal-click-low-cardinality-float-w144.IueXYd-03`:
  all six identity cases, raw Memory controls, both LC ingestion routes,
  physical dictionary/index reconciliation and six seeded comparator refusals.
  Outputs are `check.log` and `results/{run.txt,manifest.tsv,vectors.tsv}`.
- `/private/tmp/crystal-click-low-cardinality-float-part-w144.IueXYd-03`:
  all six stock-template/raw/seeded cases, actual CHECK results, full/middle
  bits and one cause-specific frame-checksum rejection. Outputs are
  `results/{run.txt,assertions.tsv,raw-bits.tsv}`, stores, queries and lanes.
- `/private/tmp/crystal-click-w144.IueXYd/root-float-oracle-04`:
  separate root-authored Ruby literal checker, 48 fresh stock queries and
  exact integer recheck of all 72 ingestion rows from attempt03. It invokes
  no Crystal decoder/expected-vector builder. The Ruby source is retained at
  `.../crystal-click-w144.IueXYd/root_float_oracle.rb`, not a permanent fixture.
- `/private/tmp/crystal-click-object-low-cardinality-w141.c27Ms3`:
  freshly regenerated unchanged native fixtures; nine admitted/check-passing
  declarations and four cause-specific wrapper/type refusals.
- `/private/tmp/crystal-click-object-low-cardinality-w143.IueXYd-01`:
  fresh unchanged recursive container regression, three complete native
  lane/grid matches, six baseline/profile stock Native consumers and one
  valid wrong-output control (63 returned rows), plus role/occurrence/ancestor
  mismatch and selected/all-empty checks. No Object/whole-part admission.

Native DoD checks use the permanent drivers below under the guard above,
with `W144_EXECUTE_AS_ROOT=YES`, the exact recovered `CLICKHOUSE_BIN`, and
new output directories. The part probe additionally takes the successful
identity root via `W144_INGEST_ROOT`. All were actually executed with the
attempt03 roots listed above. These are argument vectors passed to
`run_safe.sh`, not standalone `/bin/bash` or Ruby command lines:

```
/bin/bash 900 32768 scripts/check_low_cardinality_float_identity_w144.sh
/bin/bash 900 32768 scripts/check_low_cardinality_float_part_w144.sh
/usr/bin/ruby 180 32768 /private/tmp/crystal-click-w144.IueXYd/root_float_oracle.rb \
  /private/tmp/crystal-click-low-cardinality-float-part-w144.IueXYd-03 \
  /private/tmp/crystal-click-low-cardinality-float-w144.IueXYd-03 \
  /private/tmp/crystal-click-w144.IueXYd/root-float-oracle-04
```

The unchanged W141/W143 drivers ran under the same guard with their own
root-execution opt-ins and the fresh roots above. Full and post-review spec
commands are retained in `.../crystal-click-w144.IueXYd/run_specs.sh`; the full
guard argument vector is `/bin/bash 1200 32768 <runner> full 371`. Temporary evidence
paths are not durable fixtures. Their loss requires regeneration, not a
claim that a historical run remains independently inspectable.

Hostile verdict: ROBUST for raw Float LC ordinary recursive bulk transport
and its unchanged persisted guards, within the pinned finite profile. Luna's
static review is correlated; root's executed RED/green gates, stock bit
vectors, valid wrong-bit parts, frame corruption and separate Ruby literals
provide the discriminating evidence. Generic whole-part/Object/Dynamic LC,
exhaustive recursive physical combinations, insertion-equivalence or speed
parity claims remain VULNERABLE and are not made. The next capability is
shared persisted LC binding followed by paired normalized Object LC fields
and independently owned whole parts; the overall goal remains active.
