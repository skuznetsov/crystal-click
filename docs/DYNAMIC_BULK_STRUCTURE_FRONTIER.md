# Dynamic bulk structure/site planning frontier (W154)

Document status: VERIFIED within the metadata/site boundary below.
Baseline: clean `ab2d99f`. Risk: CAUTION (recursive persisted metadata).
Rollback: one atomic local feature commit; no push.

## Boundary

The next prerequisite is an immutable, occurrence-specific plan associating
each Dynamic descriptor with its actual V3 ordinary-type roster. A nominal
`Dynamic(max_types=N)` is not that roster, and reading an existing roster must
not infer its contents or discriminator order from N. The plan recursively
visits declared containers, static Variant arms and actual Dynamic arms.
Every Dynamic occurrence retains a structure site, including sites under
empty Arrays or unused arms. No values are required to establish this plan.

Admit paired complete structure-stream encoding/decoding and an exact
normalized role/site roster. Distinguish ordinary String from implicit
SharedVariant by arm identity; SharedVariant has no ordinary descriptor in
the structure stream. NULL discriminator 255 is not an arm or a structure.
Require an exact caller-supplied structure key set; missing, extra and
misplaced sites refuse rather than borrowing another site's state.

Dynamic V3 ordinary rosters apply the source's direct-arm policy: refuse
Nothing, Nullable, LC(Nullable), direct Variant and direct Dynamic. Legal
containers containing Variant/Dynamic can be represented in metadata and
planned recursively. Keep the existing canonical full-name discriminator
ordering and statistics semantics. Planning is not ColumnDynamic insertion
or a claim that every selected logical Field has a dedicated physical slot.

Rejected: new generic bulk value admission, physical basename/framing binding,
COMPACT/older Dynamic structure profiles, declared Object Dynamic, new public
part readers/writers, general MV/projections and performance qualification.
Existing legacy Dynamic/Object data consumers must still refuse newly
representable recursive rosters before empty or selected-zero operations.
The existing paired logical Dynamic and qualified old part profiles remain.

## Design laws

Use one shared operation budget for the root descriptor, all discovered
actual roster descriptors, site/role metadata and all structure bytes. Nested
operations must not reset depth, nodes, elements or byte counters. Preflight
count-derived allocations and path/name expansion. Limits describe bounded
logical work, not RSS. Detach mutable path Strings and byte snapshots.

Keep one cohesive owner per file: per-occurrence plan, detached structure
streams, and any direct-arm policy helper required by shared metadata owners.
Reuse the existing descriptor/structure codec instead of adding a second
wire grammar. Do not add a class for every container/type product.

Source: unbuilt shallow `b94acbe318f8459ac88b35647f4e2293d8e225db`,
`SerializationDynamic.cpp:182-266,432-474`, `DataTypeVariant.cpp:26-35`,
`ColumnDynamic.cpp:70-76`, `ColumnVariant.h:62-68`, and
`SerializationVariant.cpp:199-230,340-360`. The last anchors require child
prefixes even for empty/unused arms. Runtime qualification must identify its
separately pinned executable; current-master runtime compatibility is not
inferred from source inspection.

## Execution plan and falsifiers

1. Execute an existing-API behavioral RED: literal V3 rosters containing
   Array(Dynamic) and Array(Variant) currently fail the blanket recursive
   refusal. A syntax error or missing new constant is not this RED signal.
2. Implement the direct metadata policy and a separate actual-site plan with
   paired detached structure streams. Inventory and guard all old persisted
   consumers; do not relax BinaryBulkCodec/physical/Object value fences.
3. Characterize independent sites in Tuple(Array(Dynamic), Dynamic), a nested
   Dynamic under an actual Array(Dynamic) arm, empty nested occurrences,
   cap/roster independence, ordinary String versus SharedVariant, exact keys,
   immutable snapshots, malformed bytes and exact/one-short budgets.
4. Root executes focused DEBUG, affected RELEASE and a complete unique spec
   inventory in serial disjoint groups. Expected: zero failures/errors/pending.
   Use the isolated-cache guarded Crystal invocation with `--single-module
   --threads 1 --link-flags=-fuse-ld=ld --error-trace`; RELEASE adds
   `--release --no-debug`. Compiler guard: 600 seconds, 12 GiB process tree,
   50-percent system-free-memory threshold. Root alone runs resource jobs.
5. Independently compare a finite set of stock-produced structure streams and
   occurrence identities with the new plan. A valid wrong-site/roster control
   must be rejected for its semantic mismatch, not an unrelated process error.
   Stock checks qualify metadata/site planning only, not new bulk values or
   complete library-owned parts. Format, script syntax and diff checks pass.

Strongest failure: matching two equal Dynamic descriptors by type identity
instead of physical occurrence, losing an empty nested site, or mistaking
the implicit shared String lane for ordinary String. Literal path/role
expectations, distinct per-site rosters and a stock-valid swapped-site control
must discriminate these failures. Refresh after descriptor, structure, role,
budget, consumer guard or source/runtime changes.

Consumer inventory: `rg -n 'DynamicStructure|DynamicStructureCodec' src` names
the structure/discriminator/value codecs and Object metadata, document plan,
statistics, physical plan and file-reader owners. Generic bulk/type/physical
planners have separate cached Dynamic fences. PROJECT_STATUS and this file
are the feature ledgers; root's executed, scoped seal follows below.

## Root execution seal (2026-10-04)

The behavioral RED over unchanged `ab2d99f` has three examples, zero failures,
two errors and zero pending. The two errors reject valid Array(Dynamic) and
Array(Variant) ordinary roster metadata; the direct-arm refusal control passes.
The earlier sandbox process-group refusal is not that behavioral RED.

The implementation uses one 574-line `BinaryDynamicBulkPlan` owner and one
53-line `BinaryDynamicStructureStreams` owner. Private Site/Prepared records
belong to the plan. The reader/writer/table facades remain 15,726/25,466/6,786
lines and are unchanged. This is responsibility separation, not completion of
large-facade modularization or a performance certificate.

Root's final focused DEBUG gate passes 140 examples in 19 unique files, two
serial disjoint groups. The affected RELEASE gate passes 558 examples in 79
unique files, eight serial disjoint groups. Both have zero failures, errors
and pending. The complete inventory passes 2,539 examples in 398 unique files,
40 serial disjoint non-release groups with `--no-debug`, also with zero
failures/errors/pending. Root separately reconstructs the current selected
path sets, checks exact disjoint group membership, compares each recorded
result with observed stdout, verifies guard exits 0 and reconciles all current
source/spec SHA-256 values. These are grouped test executions, not one combined
process or a performance certificate.

The new literal specs cover independent equal-nominal sites, actual nested
rosters, empty/unused children, both String role profiles, statistics bytes,
exact key sets, malformed/trailing input, detached mutable inputs/getters,
and exact/one-short shared depth/node/element/byte limits. A standalone
10-byte empty structure fits its wire budget while the containing operation
correctly refuses at that bound because it also accounts for planning work.
Existing Dynamic/Object value consumers refuse newly representable recursive
rosters before empty/zero-window calls; ordinary Variant remains a positive
neighbor. W141/W147/W149 obsolete blanket metadata assertions are replaced
with metadata positives and retained value/physical refusals. No production
bulk or physical admission fence is relaxed.

The stock-produced fixture passes complete decode/encode of seven Dynamic V3
structure streams, all byte-exact, including two zero-type child prefixes
under an unused Variant arm and an all-empty Array. The Tuple fields use
equal nominal Dynamic descriptors but distinct ordinary rosters. Swapping
their stock-valid blobs still decodes; the independent literal site/roster
expectation rejects the result specifically as a semantic mismatch.
The driver prints `decode=accepted independent-site-roster=REJECTED` and
`PASS sites=7 empty_child_sites=2 swapped_site_control=REJECTED`.

The fixture is one four-row Wide part, `all_1_1_0`, block range 1..1, level 0,
in an isolated stock store. Eight fresh stock queries qualify its runtime,
types, row identities and single active-part identity. Root Dynamic cap 4
admits all four selected ordinary types. Ordinary String and implicit
SharedVariant retain distinct canonical arms; this fixture does not claim a
selected root spill value. The manual fixture site/escaped-stream bindings
are test instruments, not a new production physical binder.

The separately pinned stock runtime is 26.10.1.1201, build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`, executable SHA-256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
The unbuilt shallow source is `b94acbe318f8459ac88b35647f4e2293d8e225db`.
The tested driver SHA-256 is
`3c8a4f2b193fcd0c4f1aaee82cf5a1d5255a9f2c99aca208d7a50646bf89bb3b`.
Source and runtime identities are deliberately separate.

An initial cap-3 fixture assumed that the first three input types would own
ordinary slots after UNION. Stock refuted that assumption: String spilled,
not the expected UInt64. The final fixture admits all four types and checks
each root shared-data flag as UInt8 zero. It does not change expected rosters
to fit arbitrary slot selection. A missing row-4 flag update and unescaped
expected substream labels were later corrected in the instrument only.
Failed stores are retained separately, not reused as positive evidence.

Root's scoped hostile verdict is ROBUST for paired occurrence-specific
metadata/role planning and the retained legacy consumer fences. The attack
covers equal nominal types with distinct site state, empty/unused children,
ordinary String versus SharedVariant, exact site sets, mutable snapshots,
malformed/trailing input and shared exact/one-short budgets. The stock-valid
swapped-site control establishes the independent expected association; it
does not pretend that an otherwise valid blob embeds its physical site.
No generic Dynamic bulk values, physical binder, new complete parts or
current-master executable compatibility are admitted by this seal.

Reproduction uses the guarded spec flags above. Focused selection uses spec
basenames beginning `binary_dynamic_`, `dynamic_`, `bulk_dynamic_` or
`object_dynamic_structure_`, plus the changed W141/W147/W149 neighbor specs.
RELEASE selection uses `binary_`, `dynamic_`, `bulk_dynamic_`, `object_`,
`physical_stream_plan`, `json_typed_` or `wide_part_metadata_`. Sort unique
paths and split into disjoint groups of ten; only RELEASE adds `--release`.
Complete inventory selects every `rg --files -g '*_spec.cr' spec` path and
uses non-release `--no-debug` groups. Capture source/spec hashes before each
gate and check them afterward; group totals are not a combined-process run.

Build `scripts/check_dynamic_bulk_structure_w154.cr` with the same isolated
guarded compiler, then run:

```text
ruby scripts/check_dynamic_bulk_structure_w154.rb --driver DRIVER --scratch EMPTY_DIR
```

EMPTY_DIR must be an existing empty canonical direct child of a fresh
`/private/tmp/crystal-click-w154-*` root. Root runs the Ruby wrapper under a
600-second, 4-GiB process-tree guard; each stock query sets one thread and
512-MiB query memory. The compiler uses the 600-second/12-GiB guard. These are execution
guards, not runtime memory/performance measurements. Root scratch is
`/private/tmp/crystal-click-w154-root.gOan8Y`; `focused-v5`, `release-v3`
and `inventory` retain exact group inventories/hashes/results, and `native-v4`
retains the stock manifest, literal summary and driver stdout/stderr.
Temporary logs are aids; after removal, refresh by rerunning, not by treating
this summary or a structural manifest as proof.

Residual boundary: metadata and logical roles only. Generic Dynamic bulk
values, complete mark grids, physical basename/prefix binding, declared
Object Dynamic and new complete library-owned parts need separate paired
qualification. Current-master runtime compatibility, arbitrary type/layout
products, general MV/projections and performance remain unqualified. Logical
budgets do not guarantee RSS, one-copy output or allocation-free planning.
The explicit detached-stream constructor is caller-side snapshot work before
decode's budgeted operation. Refresh on descriptor/structure/role/budget,
consumer guard, source or runtime changes.
