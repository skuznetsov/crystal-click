# Object declared LowCardinality frontier (W146)

Document status: implemented and verified within the bounded profile and
executed gates below. The overall type/layout and MV/projection objective
remains open.
Baseline: `bb1b783`, 2026-10-03. Risk: CAUTION (persisted format and public
reader/writer admission). Rollback: the exact scoped diff over that clean
baseline, then one atomic local commit after the gates; no remote push.

## Transition and constraints

Admit canonical declared Object LC fields over the intersection of the
existing Object leaf grammar and the source-eligible LC child grammar,
including LC(Nullable(T)), inside the existing legal Array/Tuple/Map(String,V)
compositions. Reuse the shared LC storage codec and physical binder. Do not
add per-leaf or per-composition facade methods. Direct low-level Object plans
must preserve the same LC field policy, not bypass it through descriptor APIs.

Still rejected: LC(BFloat16) Object fields, illegal LC children (composites,
Decimal, Enum, DateTime64/Time64 and nested LC), Nullable(LC), LC in Dynamic
alternatives or shared-value envelopes, other Object/shared layouts, specialized
LC dict-prefix serialization, bucketed Maps and Compact parts. The source's
retention of type names is not a guarantee of immutable serializer profiles.

Existing writer scope remains one UInt64 key plus one normalized Object column,
hashed Wide streams, Object/Dynamic V3, one shared MAP bucket, LZ4 and plain
adaptive marks. General schema/partition/lifecycle, MV and projection work
remain open. Performance is not widened by this slice.

Source pin: separate unbuilt shallow checkout
`9007d227b64a3f8b667fc5258ceb2923f3cf477d`. Native oracle pin:
26.10.1.1201, build `d9bcb5ab007f0f6299f7f973f2642245bab3d028`, SHA-256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
The executable is not asserted to be built from the source pin.

## Strongest failure and falsifiers

Removing schema/codec guards alone can create parts whose LC dictionary prefix
is wrong or whose selected middle granules have lost earlier dictionary state.
The current Object file reader cuts every ordinary lane to its selected window;
LC storage instead validates/replays its full dictionary/index grid and all
ancestor Array/Map occurrence schedules. Qualify the actual read strategy and
its byte/transport budget before admitting selected public reads. A conservative
full-Object physical replay is permissible before the later optimization stage,
but must remain explicit and materialize only selected document rows.

Required signals:

1. Fresh native declared-JSON LC probe, exact nominal/RowBinary values and actual
   raw three-field CHECK results; illegal constructor and JSON extraction controls.
2. Behavioral RED before production edits, then focused paired schema/codec/
   complete-writer/public-reader tests. Exact/one-short depth, nodes, elements
   and bytes; shared-field budgets; forged/mutated text preflight; nominal mismatch.
3. Whole independent library-generated parts (no stock envelope or sidecar copy)
   pass stock ATTACH, CHECK, full/middle ordered RowBinary, with both ordinary
   String profiles and BASIC/COMPACT Dynamic discriminator modes.
4. Library file/column/table/catalog consumers agree for full/middle/zero
   windows, recursive empty/null/default cases and UInt64 PK candidate residuals.
5. Seed a valid wrong LC value with recomputed valid checksums: CHECK may pass,
   but the independent literal comparator must reject it. Corruption and retained
   Dynamic/shared-envelope/BFloat16 guards must also remain effective.
6. Affected RELEASE and complete unique spec inventory in serial disjoint
   non-release groups, unchanged neighboring native regressions, format/syntax/
   diff checks and a scoped hostile review. Grouped tests are not a combined
   process run, and a finite native matrix is not every legal type product.

## Owned plan and evidence

### Native admission discriminator (before production edits)

Root's fresh Ruby/stock probe passes under the serial resource guard at
`/private/tmp/crystal-click-object-low-cardinality-w146.UPjcaW-native-04`.
Seven literal rows qualify seven declared fields: LC(String),
LC(Nullable(String)), LC(UInt64), LC(Float32), Array(LC(String)),
Map(String, LC(String)) and a named Tuple containing LC(Nullable(UInt64)).
Exact complete `system.columns` declaration and path type names, 290
independent literal RowBinary bytes, one Wide part
and raw `all_1_1_0\t1\t\n` CHECK output agree. Its real row grid is
`[2, 2, 2, 1]`; `system.parts.marks=5` includes the terminal adaptive-mark
record, not a fifth row granule. Nullable(LC) and LC(Decimal) retain exact
constructor rejection controls.

The BFloat16 control fails at DDL construction with code 43 and
`JSON serialization doesn't support the return type schema: BFloat16.`
This is the Object/JSON serialization boundary, not a claim that generic LC
rejects numeric BFloat16. Discovery remains narrower than paired whole-part
admission. Earlier fresh attempts exposed two harness assumptions: Ruby text
encoding equality despite byte-identical RowBinary, and conflation of real
granules with total mark records. A separate root read-only Ruby discriminator
confirmed equal byte arrays, unequal text/binary Strings and equal binary
Strings; `cmp` independently agrees. Neither attempted failure is attributed
to the library, which was unchanged.

Root's pre-edit behavioral RED command was the resource-guarded
`run_specs.sh red-schema spec/object_declared_low_cardinality_w146_spec.cr`.
It compiled and executed four examples: zero assertion failures, three
behavioral errors, zero pending. The recursive declaration/schema and borrowed
preflight positives hit the existing LC refusal/nil preflight; the retained
Object/illegal-wrapper negative example passed. Log:
`/private/tmp/crystal-click-w146.UPjcaW/red-schema.log`. This licenses the
bounded production transition, not a completion claim.

The production owner is the Luna inventory/implementation agent. Its exact
surface is `ObjectRecursiveDeclaration` and `ObjectRecursiveDeclarationText`
for bounded declaration policy; `ObjectDocumentCodec` and
`ObjectDocumentPhysicalPlan` for direct-plan admission; `BinaryBulkPhysicalPlan`
for role-owned prefix metadata; and `ObjectDocumentColumnWriter` and
`ObjectDocumentFileReader` for persisted prefix and replay integration. Any
new policy or selection owner has its own file. Schema parser, table/catalog
facades and `ObjectSchemaLogicalUsage` inherit these owners and are not changed
without a discriminating failing test.

A separate Luna test owner authors new W146 schema/accounting and public
consumer specs, then updates only superseded typed-LC refusals in W140–W145
after root observes behavioral RED. Another Luna owns the literal native
discovery and complete-part interoperability harness. Existing Dynamic,
shared-envelope, illegal-constructor and Object BFloat16 guards remain tests.

The first accepted physical strategy replays every Object value lane on the
complete outer grid when any declared field contains LC; ordinary non-LC
Object reads retain cropped windows. Every role's prefix comes from its
physical plan, not a filename guess. All replay bytes remain subject to codec
and transport admission, including zero selections. Catalog `.values` may
therefore replay LC state once per mark: correctness is admitted, selective
I/O and performance are not.

The physical binder also preflights the new dictionary-prefix lookup and its
temporary LC-site roster before materializing those names. That logical-work
accounting changes the exact LC physical-plan budget relative to W145; paired
exact/one-short and shared-context tests must qualify the change. It is not an
allocator, peak transient-memory or RSS guarantee.

Root alone executes Crystal and native commands serially under the host resource
guard; Luna authors the heavy implementation and tests in disjoint paths.
Native structural admission is not paired complete-part compatibility.

### Paired complete-part evidence

Root executed `scripts/check_object_low_cardinality_w146.sh` with
`W146_EXECUTE_AS_ROOT=YES` through the serial resource guard. The passing run is
`/private/tmp/crystal-click-object-low-cardinality-w146-paired.UPjcaW-02`.
Eight cells cross stock-origin JSONEachRow and independently library-written
parts with both ordinary String profiles and BASIC/COMPACT Dynamic modes.
Each cell passes exact nominal types, raw CHECK output, full/middle ordered
RowBinary and library file/column/table/catalog full/middle/zero consumers.
The seven declared fields are the native probe's finite witness; the wider
schema grammar is not an exhaustive physical product certificate. Present
dynamic Int64 and shared String spill values are independently checked by
stock SQL on rows 1 and 7.

Library-origin cells use `WidePartWriter.write_uint64_object_pair` to create
the entire part from owned keys, schema, rosters and documents. No stock part
envelope or sidecar is borrowed. A valid wrong UInt64 LC value (999 in the first
row), with recomputed checksums, passes ATTACH and CHECK; its modified literal
RowBinary matches, while the original literal comparator rejects it. CHECK is
therefore not substituted for semantic value evidence.

Root then executed the separately authored and root-reviewed Ruby checker
`/private/tmp/crystal-click-w146.UPjcaW/independent_recheck.rb`. It derives
RowBinary directly from literal values and primitive Ruby packing, without
Crystal codecs or helper-produced expected files. Seventy-four fresh queries
recheck all eight cells and the valid wrong-value store, including runtime
identity, exact full/middle/zero bytes, declarations, raw CHECK and present
dynamic/shared witnesses. The passing evidence is under the paired run's
`results/independent_recheck/` directory.
The separately executed Ruby checker's SHA-256 is
`4541f006dd5a66327001abe07ac7a63826a3fb268362f0a97d7f9451590db319`.

The String axis qualifies ordinary String lanes only. LC(String) dictionary
keys use the default inner serialization in the pinned source; the axis does
not establish a WithSizeStream dictionary profile. The Object Map grammar
still requires exact String keys, even though upstream JSON can accept some
LowCardinality(String) keys. Neither limitation is silently widened here.

### Root regression and review record

On the frozen production diff, root executes all Crystal and stock commands
serially using `cogni-ml/scripts/run_safe.sh`, a 50% free-memory preflight,
32,768 MiB process limit, one Crystal compiler thread, an isolated cache and
the Darwin linker. The final focused command is
`run_specs.sh focused-green-final` over the eleven W140-W146 affected schema,
logical-budget, recursive codec and physical-consumer files: 112 examples,
zero failures/errors/pending. Log:
`/private/tmp/crystal-click-w146.UPjcaW/focused-green-final.log`.
The one-process `run_specs.sh release 52` gate passes 406 examples with zero
failures/errors/pending. Its exact unique-file roster and log are
`affected-release-inventory.txt` and `affected-release.log` in that evidence
root. `run_specs.sh full 374` passes 2,405 examples with zero failures/errors/
pending over 374 unique files in sixteen serial disjoint non-release groups
(fifteen groups of 24 files and one of 14). This is not combined-process
verification. Its exact roster and log are `full-spec-inventory.txt` and
`full-inventory.log`. The grouped run exits 0 after approximately 390 seconds;
that is verification time, not a reader performance measurement. Existing
duplicate-libc and W113 deprecated-blocking warnings are non-fatal.
The complete inventory SHA-256 is
`d662461d4ddefbe721d39701de99105005994c0bfb0f91a63b1ebba0425d531c`;
the full result log SHA-256 is
`bcc8ec64ab9eeb1d32c83421b0590d31e7db20c5f271c0a24f085b771d7827a4`.
These hashes identify retained evidence, not additional behavioral proof.

The focused falsifiers include exact/one-short depth, nodes, elements and
bytes; shared-field/context charging; mutated and forged borrowed-text
preflight; same-width UInt8/Bool LC mismatch; NULL Tuple hidden defaults;
empty-then-nonempty nested Array occurrences; full/middle/zero windows; and a
corrupted last LC index mark rejected even for zero selected marks. File-byte
pressure uses an isolated part with a >24 KiB ordinary String sibling: a
limit one byte below the descriptor's complete logical-read size fails
specifically on codec bytes for both middle and zero selections. This avoids
confusing physical-name admission with full-replay byte accounting.

Harness corrections did not change production: role IDs containing `.elements`
do not imply that suffix in physical LC basenames; positive Object fixtures
require a complete shared-role roster; conservative PK candidates require an
explicit caller residual before comparing matching rows. The passing catalog
test retains rows 3/4, prunes final granule rows 5/6, then applies that residual.

Three fresh unchanged neighboring native gates pass on the same pinned runtime:

- `check_object_recursive_w140.sh`:
  `/private/tmp/crystal-click-object-recursive-w140.8Mp7EV`.
- `check_low_cardinality_physical_binding.sh`:
  `/private/tmp/crystal-click-low-cardinality-physical-w145.UPjcaW-w146-regression`.
- `check_low_cardinality_bulk_w143.sh`:
  `/private/tmp/crystal-click-object-low-cardinality-w143.UPjcaW-w146-regression`.

Separate Luna source/helper and ownership/consumer reviews found no production
blocker within this slice. They are correlated model reviews, not independent
compatibility evidence. Root independently inspects the diff and actual
execution outputs; the literal stock oracle and failure controls discriminate
the material claims. The late-index corruption falsifier is in-memory; this
slice does not add a tampered physical-Object-part corruption certificate.

Root's final scoped Adversary verdict is **ROBUST**: prefix ownership and LC
history are exercised by independent stock consumption, complete owned parts,
middle/zero public reads, ancestor empty/null cases and cause-specific failure
controls. An invalid schema guard is not counted as implemented support, and
CHECK-pass alone does not close semantic value correctness. This verdict does
not expand the seven-witness matrix to every legal schema or physical profile.

Final `crystal tool format --check` passes on all sixteen changed/new Crystal
paths; Ruby and shell syntax checks and `git diff --check` also pass. The seven
production paths' exact `git diff` over `bb1b783` has SHA-256
`916956461d950593643cdd623123aaac6aa63eff7f28c03a22eed51a71c2d00e`, unchanged
through the final focused, RELEASE and full-inventory gates. Git history owns
the final rollback; exact source/tests/scripts/docs form one local feature
commit, with no remote push authorized by this slice.

The certificate assumes immutable offline parts and the pinned default-LC,
BASIC-Map, Object/Dynamic V3, single-bucket shared-MAP, hashed Wide/LZ4/adaptive
mark profiles. Filesystem size/roster checks are not content-hash protection.
Full physical replay buffers unselected ordinary siblings; repeated catalog
mark reads can repeat that work. Peak RSS, selective I/O and speed parity are
not qualified. Declared Variant/Dynamic, LC keys in Object Maps, unqualified
LC leaves/products, other layouts, general writers and broader MV/projection
work remain open.

Reopen affected claims when their policy, prefix/replay owner, source grammar,
runtime binary/profile or consumer contract changes. Refresh by rerunning the
focused/RELEASE/unique-inventory gates and fresh native/library plus independent
literal comparisons. If retained temporary oracle evidence is unavailable,
generate fresh evidence before relying on it for a new compatibility claim.
