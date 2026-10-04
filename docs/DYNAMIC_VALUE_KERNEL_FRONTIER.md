# Dynamic logical-value kernel frontier (W153)

Status: VERIFIED within the paired logical kernel and retained guard scope.
Baseline: `f41eeb0`. Risk: CAUTION (recursive serialization and admission).
Rollback: one atomic local feature commit; no push or history rewrite.
This is the next prerequisite for typed Dynamic in Object, not full part support.

W154 separately supersedes the blanket recursive-roster metadata rejection
below with occurrence-specific structure planning; see
[DYNAMIC_BULK_STRUCTURE_FRONTIER.md](DYNAMIC_BULK_STRUCTURE_FRONTIER.md).
DynamicValueCodec still rejects recursive Dynamic/Variant ordinary values,
including empty/zero-window calls. Generic bulk/physical and declared-Object
Dynamic remain closed. Historical W153 execution results are not rerun claims.

## Boundary

Admit paired `BinaryValueCodec.encode/decode` and known-type
`encode_value/decode_value` for nominal Dynamic and legal recursive parents.
`BinaryValue.dynamic(type, child = nil)` retains the nominal cap. No child,
or an explicit Nothing NULL child, represents Dynamic NULL. A selected
Nullable NULL, Variant NULL or nested Dynamic NULL remains a non-NULL outer
wrapper with its selected nominal child. Existing value snapshots stay owned.

The wire body is one actual-type binary descriptor followed by that type's
ordinary scalar body. Nothing is the NULL descriptor and has no payload.
Actual Dynamic descriptors recurse through the same value grammar. The
declaration cap 0..254 is not a logical actual-type whitelist. Selected types
must still satisfy the existing descriptor grammar and parent policies.
Only Dynamic's selected Nothing descriptor is a NULL sentinel without a
scalar body. Ordinary Nothing scalar visitors always refuse, even inside a
selected Array/Tuple. Empty Array(Nothing) invokes no scalar visitor and is
legal; nonempty Array(Nothing) and Tuple(Nothing) remain refused.

All borrowed persisted-envelope entry points retain recursive Dynamic,
Variant and LowCardinality refusals. Dynamic-containing entries in existing
Dynamic V3 rosters/shared envelopes, generic bulk/default/physical routes
and declared Object Dynamic remain rejected, including empty containers and
zero windows. Previously qualified standalone Dynamic profiles are unchanged.
No new part profile, ColumnDynamic slot management, inferred Object policy, Compact,
projection/MV capability or performance claim follows from this kernel.

## Budget and ownership laws

One operation context owns descriptor/value traversal and wire accounting.
The Dynamic value wrapper is visited by the generic dispatcher. Its actual
descriptor starts at wrapper depth + 1 and charges one child edge. A non-NULL
selected payload starts at that same depth and charges a second child edge.
NULL has the descriptor node but no selected payload node. Never recurse via
a public entry point that resets context, depth or aggregate counters.

For known-type Dynamic NULL the exact lower limits are depth=2, nodes=3,
elements=1 and bytes=1; for Dynamic(UInt64(42)) they are depth=2, nodes=4,
elements=2 and bytes=9. Complete envelopes add the two nominal descriptor
bytes, not another nominal descriptor traversal. Count-derived allocations
retain preflight checks. Borrowed precharge/output reserves remain unchanged.
Logical limits are not an RSS bound.

Keep the new actual-envelope grammar in one private cohesive owner/file;
reuse existing leaf/container codecs rather than product-specific facades.
The constructor and generic dispatcher changes remain small. The only old
test admission expectation to replace is the generic rejection in
`spec/dynamic_descriptor_consumer_guards_w152_spec.cr`; its stored/borrowed
refusal witnesses remain load-bearing.

## Anchor, falsifiers and execution order

Fresh source reference: separate unbuilt shallow
`b94acbe318f8459ac88b35647f4e2293d8e225db`.
`SerializationDynamic.cpp:718-780,862-897` distinguishes Field envelopes
from physical ColumnDynamic insertion. `ColumnDynamic.cpp:144-166` checks
slot availability before constructing the Variant roster;
`DataTypeVariant.cpp:26-62` rejects direct Nullable/Variant/Dynamic arms.
The stock executable is separately pinned to 26.10.1.1201, build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`; it is not asserted to build this
source snapshot. Its cap=0/cap=1 column admission probe is a prerequisite
observation, not evidence that every logical Field value inserts into every
physical cap/state.

1. Root observed behavioral RED on unchanged baseline: three existing-API
   examples, three UnsupportedFormatError errors explicitly refusing Dynamic.
2. Root runs the literal stock prerequisite and reconciles acceptance,
   dynamicType and emitted bytes, including a valid wrong-value control.
3. Test owner covers paired cap extremes/all caps, selected NULL identity,
   recursive containers and retained ordinary Nothing refusals, exact/one-short
   aggregate budgets, malformed
   descriptors/payloads/trailing bytes and retained consumer fences.
4. Production owner implements only the boundary above. Native owner authors
   independent literal/stock-to-library and library-to-stock qualification.
   All compiler/ClickHouse jobs run serially under the root resource guard.
5. DoD: focused DEBUG and affected RELEASE zero failures/errors/pending;
   complete unique spec inventory in bounded disjoint groups; paired native
   checks plus a valid wrong-value mutation that the semantic check rejects;
   formatter, Ruby syntax and diff checks; root hostile review within scope.

Strongest failure: resetting budgets at an embedded descriptor, or mistaking
generic logical admission for a stored Dynamic lane. One-short nested limits
and positive-neighbor borrowed/bulk/Object refusals discriminate these faults.
Source-shape checks support, but never replace, behavioral/stock evidence.
Refresh this certificate after source, runtime, grammar, budget or guard changes.

The source adversary refuted an initial proposed zero-byte nested Nothing
scalar rule: `SerializationNothing.h:18-21` explicitly throws, while Array
and Tuple scalar serializers invoke it for each present child. The admitted
sentinel is Dynamic's own early-return branch only. No contextual Nothing
relaxation may be added to the generic scalar visitor.

Root observed the twelve-case prerequisite in a fresh store per query.
At cap=0, UInt64, Nullable(UInt64), Variant(UInt64) and nested Dynamic values
all occupy shared data and preserve the exact literal typed envelopes;
NULL is `None`, not shared, with body `00`. At cap=1, UInt64 occupies a
dedicated lane and preserves its bytes. Direct Nullable, Variant and Dynamic
actual types fail with code 36 BAD_ARGUMENTS and the specific Variant-roster
messages. A valid 42-to-43 mutation is accepted with its distinct emitted
bytes. This supports the logical/physical distinction; it does not qualify
the new library codec or any complete part.

## Root-executed qualification

At the implemented feature state over `f41eeb0`, the 16-file focused DEBUG
command passed 116 examples. The affected RELEASE inventory passed 542
examples across 76 unique files in eight serial disjoint groups. The complete
inventory passed 2,519 examples across 394 unique files in 40 serial disjoint
non-release groups with `--no-debug`. All three GREEN gates have zero failures,
errors and pending cases. Root independently reconciled both inventory
manifests against current unique spec paths, per-file SHA-256 and per-group
results; no omitted/duplicate paths or spec drift were found. This is not a
combined-process inventory run or a runtime performance measurement.

The root rebuilt `scripts/check_dynamic_value_w153.cr` and ran the Ruby
qualifier against that driver. Driver SHA-256 is
`4c4f0c4e47e355cc76d92b52f6d5331708d9b99de60b73ec9e8c2da6158508e0`.
The separately pinned stock executable SHA-256 is
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
Fourteen owned-value emissions match independently authored Ruby type/body
literals, stock parse/dynamicType/exact re-encode, and the Crystal decoder's
expected semantic tree and exact re-encode. They cover Dynamic NULL, explicit
Nothing NULL normalization, UInt64 at caps 0/1/254, NUL-containing String,
Nullable NULL/non-NULL, Variant NULL/non-NULL, nested Dynamic NULL/non-NULL,
mixed Array(Dynamic) and empty Array(Nothing). Four SQL-generated values
(NULL, UInt64, String and mixed Array(Dynamic)) independently run in the
stock-to-library direction. Every positive driver verifier must emit the
exact expected VERIFIED TSV, not merely exit successfully.

The stock accepts and re-encodes a valid UInt64 43 envelope; the Crystal
verifier expecting 42 rejects it with the specific semantic mismatch marker
and reports decoded=43. This distinguishes wrong values from malformed bytes
or unrelated process failures. Ordinary nonempty Array(Nothing) also retains
its explicit scalar refusal. Root inspected the literal summary and negative
control stderr; model agreement is not the qualification signal.
The final native repeat after correcting only the negative-control summary
label passed the same 21 stock queries, including two runtime-identity queries.

External type-check probes admit the public Dynamic constructor and reject
the private `CrystalClick::BinaryDynamicEnvelope` constant specifically.
The first absolute-require probe did not load the library and was inconclusive;
the corrected relative-require positive and negative probes are the evidence.
The private actual-envelope owner is one 42-line class/file. Scalar visitors
retain ordinary Nothing semantics and recurse through the same context.

All resource jobs run sequentially with a 600-second/12-GiB compiler guard,
50-percent host-free preflight, isolated cache, SDK 26.5, `--single-module`,
`--threads 1` and `--link-flags=-fuse-ld=ld`. Native qualification uses a
600-second/4-GiB guard and a fresh local store per stock query. These are
compiler/test guards, not measurements or guarantees of runtime memory.

The root's scratch is `/private/tmp/crystal-click-w153-run.AaUYyt`:
`release/inventory.json`, `inventory/inventory.json` and per-group stdout/stderr
identify both disjoint source-hashed inventories;
`paired-native-seal/results/manifest.txt`,
`summary.tsv` and per-query/driver files identify the native certificate.
These temporary logs may be removed later; their absence requires rerunning
the gate, not trusting this summary as proof.

Reproduction uses the guarded compiler prefix above: compile the driver with
`crystal build scripts/check_dynamic_value_w153.cr --no-debug -o DRIVER`, then
`ruby scripts/check_dynamic_value_w153.rb --driver DRIVER --scratch EMPTY_DIR`.
The prerequisite is the separate `--probe-only --scratch EMPTY_DIR` mode.
Each EMPTY_DIR must already exist, be empty, and be a new canonical direct
child of a caller-created `/private/tmp/crystal-click-w153-*` root.
RELEASE inventory selects spec
basenames beginning with `binary_`, `dynamic_`, `bulk_dynamic_`, `object_`,
`physical_stream_plan`, `json_typed_` or `wide_part_metadata_`; complete inventory
selects every unique `rg --files -g '*_spec.cr' spec` path, sorted and split
into disjoint groups of ten. Both use `--no-debug`; only RELEASE adds
`--release`. `run_gates.rb` in the scratch implements this bounded traversal.

## Consumer inventory

`rg -n 'BinaryValueCodec\.' src scripts examples` finds the three persisted
codec callers: DynamicValueCodec, ObjectSharedMapCodec and
ObjectDocumentSharedCodec. All use borrowed entry points. Script callers use
ordinary paired logical APIs. Existing cached `contains_dynamic?` guards in
bulk/default/physical/Object and stored Dynamic owners remain unchanged.
This file and PROJECT_STATUS are the slice ledgers.

## Scoped adversary verdict

ROBUST for the paired logical Dynamic transition and retained consumer fences.
Root inspected the production diff and counterexamples, observed the unchanged
three-example baseline refusal and the GREEN gates, checked exact/one-short
recursive budgets and typed NULL neighbors, and independently executed the
literal native exchange and stock-valid wrong-value control. External probes
verify public constructor admission and private helper visibility. Same-lineage
review is supporting evidence, not an independent compatibility oracle.

Physical Dynamic state/roster admission, complete parts, Object declarations,
all selected-type/physical products and performance remain outside this seal.
The certificate applies to this atomic feature state over `f41eeb0`; relevant
source/runtime, grammar, budget, consumer-guard or implementation changes
reopen the affected claims and require the corresponding gates to rerun.

## Next track

After the kernel seal, separately qualify Dynamic structure/actual-roster bulk
planning and physical binding, then declared Object Dynamic read/write with
independent complete parts and stock CHECK. Do not substitute cap identity
or this logical kernel for that physical evidence.
