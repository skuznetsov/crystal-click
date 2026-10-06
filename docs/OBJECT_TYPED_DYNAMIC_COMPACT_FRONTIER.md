# Object typed-Dynamic COMPACT frontier — W189

Status: VERIFIED within the finite executed scope below. The larger type,
MV/projection and later performance objective remains incomplete.
Baseline: clean `7635854` (W188). The full type, MV/projection and later
performance objective remains unchanged and incomplete.

## Boundary and reason

Declared Dynamic paths, including the recursive declaration grammar already
admitted by W159, use normalized BinaryBulk discriminator streams. These
streams contain one tag per logical occurrence. At the baseline, their physical
adapter added/removed only the BASIC UInt64 mode prefix, so Object encoding
refused COMPACT when a declared typed-Dynamic path existed.

This feature composes BASIC/COMPACT physical framing with those existing
normalized streams. It does not replace leaf serde or change nominal type
admission, Dynamic actual rosters, shared-arm identity, structure versions,
Object layouts or bulk codec semantics. Existing non-Dynamic consumers of the
legacy BASIC prefix adapter retain their admission boundary.

Risk: CAUTION (persistent serialization, shared budgets and selected reads).
Rollback: one atomic local commit of exact owned paths after the DoD passes;
before that, retain the baseline and inspect the scoped diff. No remote push,
source-data mutation, performance rewrite or Compact-part admission.

## Design laws

- Keep normalized logical tags separate from physical mode/framing. Do not
  interpret a COMPACT byte extent as a row count or infer mode from a schema.
- Each discriminator lane owns exactly one UInt64 mode prefix. Empty logical
  mark groups have no body in either mode. COMPACT positive frames have a
  bounded positive VarUInt count, format 0 row tags or format 1 uniform tag.
- A writer may emit one canonical frame per nonempty normalized mark. A reader
  must account for multiple positive frames inside a selected physical mark;
  a serialization call is not automatically identical to an adaptive mark.
- Derive write-side logical occurrences from validated normalized tag extents.
  Read-side frame counts only bound normalization: the existing BulkDecoder
  must still validate the enclosing Array/Variant schedule, exact tag/arm
  consumption and actual roster. Framing alone is not a schedule certificate.
- Preserve physical root rows, logical child counts, full structural site
  identity, inherited Array level and independent actual rosters at equal
  nominal sites. Never reset state or budgets at a wrapper edge.
- Validate complete physical grids and discriminator headers before exposing
  selected values, including zero selections. Retain selected-only payload
  authentication; do not claim that empty selection validates all arm bodies.
- Bound and preflight expanded tags, adapted byte buffers and detached
  coordinates under the operation's borrowed budget before allocating.
  Preserve BASIC accounting/output and all existing aggregate contributors.
  New COMPACT writes charge the complete adapted output buffer, in addition
  to the already charged normalized input tags; BASIC keeps its legacy
  header-only adaptation cost. COMPACT reads charge expanded tags before
  allocation, without repeating caller-owned header/coordinate charges; the
  enclosing BulkDecoder still accounts for its owned normalized input.
  Logical codec budgets are not RSS or decoder-workspace guarantees.
- Keep cohesive new framing ownership in its own class/file. Do not add a
  serializer for each nominal container combination.

Likeliest failure: uniform COMPACT frames encode huge logical counts in a few
bytes, bypassing budget preflight or the enclosing occurrence schedule.
Cheapest discriminators: exact/one-short expansion budgets and a checksum-valid
frame whose count disagrees with an enclosing Array schedule. Multiple frames,
empty child marks and nonzero read origins are additional guard controls.

## Execution plan and DoD

1. Author `spec/object_typed_dynamic_compact_w189_spec.cr` using existing public
   APIs. Root executes it against unchanged production and records runtime
   BASIC-profile refusals, with a BASIC positive control. A missing symbol or
   test-authoring compilation error is not the behavioral RED.
2. Implement a separate mode-aware physical discriminator owner and direct
   literal/malformed/budget tests. Reuse W188's structural validation where
   applicable; retain normalized BinaryBulk semantics and the old BASIC adapter.
3. Bridge Object encoding, detached stream mode ownership, column lane binding
   and file-reader header/selected-payload adaptation. Enumerate affected
   consumers before changing shared APIs. Preserve typed child metadata,
   statistics offsets, roster/cap laws and non-qualified layout guards.
4. Root runs focused then affected DEBUG/RELEASE specs serially under the
   existing `cogni-ml/scripts/run_safe.sh` guard: 600 seconds, 12 GiB,
   >=50% free-memory preflight, isolated cache, one compiler thread and the
   existing linker/SDK flags. Freeze production/test/helper inputs for final
   paired gates. Expected: zero failures/errors/pending and actual guard exits 0.
5. A bounded native runner creates independently stock-authored and completely
   library-owned Wide/LZ4/plain-mrk2/Object-v3/shared-MAP parts in fresh task-owned
   `/private/tmp` roots. Read stock through Crystal; require stock ATTACH/CHECK,
   exact schemas and independently authored full/middle values for library
   output. Inspect actual mode/framing bytes and physical mark rows: native
   acceptance alone cannot prove that the writer emitted COMPACT.
6. Attack NULL versus empty, uniform/plain frames, malformed/nonminimal counts,
   unknown modes/formats, inexact extents, multiple frames, expansion budgets,
   equal nominal sites with independent rosters, unselected corrupt grids,
   zero selections and unsupported layouts. Root hostile review and exact
   source/artifact reconciliation precede a scoped verification claim.

Source-only reference remains the clean shallow unbuilt ClickHouse snapshot
`ef037e60fc7f5654c8c80eefb8be82e3c56f9a67`; the executed stock oracle is separately
pinned to 26.10.1.1201 / `d9bcb5ab007f0f6299f7f973f2642245bab3d028`, executable
SHA-256 `bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
Neither source inspection nor a parser/unit round trip qualifies whole parts.

## Executed evidence (2026-10-06)

The unchanged-production RED is two Object examples: the BASIC control passes
and the COMPACT call raises the existing BASIC-only runtime refusal. The actual
guard exit is 1. The first sandbox guard attempt could not isolate the workload
process group and exited 75; the same guard ran with the platform permission
required for isolation. Its limits were not weakened.

`BinaryBulkDiscriminatorFramingAdapter` now owns physical framing in one
class/file. It preserves the existing normalized recursive BinaryBulk serde.
File reads discover and retain mode by physical filename, not a single Object
wide mode; independent BASIC/COMPACT lanes can coexist. The old BASIC-only
adapter and W185's dedicated writer retain their previous boundaries.

Root executes 72 affected spec files: **419 DEBUG and 419 RELEASE examples**,
zero failures/errors/pending, actual guard exits 0. Tests cover direct declared
Dynamic, Array(Dynamic), Variant(Array(Dynamic), String), independent actual
rosters, empty child groups, full/middle/zero selections, concatenated positive
frames, minimal counts, malformed grids and exact/one-short borrowed budgets.
Root-authored adversarial controls reject a valid Int32::MAX uniform count
before expansion under a small byte budget, share accounting across two lanes,
and reject both excess and missing tags relative to an enclosing Array schedule.
These are selected regression gates, not the full repository suite.

Retained unsuccessful attempts are distinguishable from positive gates:

- A mixed-mode test changed the compressed file size without refreshing its
  owned fixture manifest; the file-size guard correctly refused it. Refreshing
  the fixture manifest, without bypassing production checks, makes all 27
  focused Object examples pass.
- The first helper build named a nonexistent batch class; using the actual
  `WidePartTableBatch` class fixes the test helper compilation.
- The first native expectation did not use stock's canonical typed-path order.
  The fixture also inferred UInt8 for integer Array(Dynamic) values where stock
  chose Int64. Exact schema and roster expectations now reflect stock output.
- A second strict native check exposed an incorrect constant shared-arm index.
  Canonical actual names determine global tags: Int64 sorts before SharedVariant,
  while SharedVariant sorts before String. The literal expectations were fixed;
  no production guard or value serializer was relaxed.

The two finite native schemas wrap `Tuple(l JSON(...), r JSON(...), n UInt64)`
under one and repeated Array edges. JSON uses max_dynamic_types=1,
max_dynamic_paths=0, direct Dynamic(max_types=1) and
array Array(Dynamic(max_types=1)) typed paths. Each sibling owns independent
direct and array rosters, genuine typed NULL, shared spills and nonempty shared
MAP data. Physical parent rows remain `P=[2,2,2,2]`; the Object and nested
Dynamic occurrence counts in this fixture are `C=[0,1,3,0]`.

DEBUG and RELEASE both qualify stock read and library write/ATTACH/CHECK for BASIC and COMPACT,
with exact schemas and independently authored native full/middle values plus
Crystal direct/public-table full/middle/zero windows. Root independently checks
each run's 19 process records, 40 capture hashes/sizes, 16 utility inputs,
276 stream files, 48 native literal row records and 16 discriminator lanes.
Actual decompressed BASIC offsets are `[8,8,9,12,12]`; COMPACT offsets are
`[8,8,11,16,16]`, with zero body bytes for empty groups, uniform format 1 for
the singleton NULL and plain format 0 for the mixed positive group. All 154
generated library files match byte-for-byte between DEBUG and RELEASE for
COMPACT; all 154 BASIC files also match between those two builds. This is not
a comparison with the different W188 fixture.

The final native gate's 1,091 Crystal/Ruby inputs (364 production files) have
identical pre/post fingerprints. The affected production/spec inputs were not
edited after their 419-example gates; only native fixture helpers were corrected
after those gates and then rebuilt and executed. Root's separate Ruby parser /
synthetic two-frame coordinate probe passes and rejects seven adversarial cases.
Synthetic frame headers are not an actual native multi-frame compression witness.

The inherited runner pins native executables before/after each native process.
It does not pin the helper executable in its process record; root separately
records the owned build command, successful exit and observed helper hash.
Utility decompression has no query-memory setting: input is bounded to 64 KiB
and aggregate header-declared decoded output to 1 MiB before launching, under
the 12 GiB outer guard and ten-second process deadline. Parts must remain
immutable during reads.

Scoped adversary verdict: **ROBUST** for the finite admitted/qualified profiles
and tested failure guards. No assertion of every recursive type product,
arbitrary cross-mark frame cuts, other JSON layouts, Compact part format, full
repository coverage, all unselected payload authentication, RSS/workspace bounds,
complete MV/projections, performance, or a runtime built from the fresh source
reference. Exact commands, input/record hashes and retained failures are indexed
in [object-typed-dynamic-compact-w189.json](../.landmark/evidence/object-typed-dynamic-compact-w189.json).

## Continuation and decay

The paired DoD is complete for this slice; commit the exact owned paths locally
without pushing. Next, identify an unsupported persisted wrapper or layout with
a stock-authored part, reuse existing leaf serde, and extend only the missing
context/framing owner with a failing guard and paired qualification. Other JSON
layouts, enclosing wrappers, types, MV/projections, modularization and the later
<=10% native performance target stay open.

Reopen affected evidence when framing, structural schedules, budgets, site
binding, serializer settings, source/runtime pins or public consumers change.
Removing temporary evidence invalidates its links. Keep the current immutable
source/runtime references separate; never promote source-only review into
whole-part execution compatibility.
