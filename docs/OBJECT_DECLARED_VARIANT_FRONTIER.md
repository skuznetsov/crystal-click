# Declared Object Variant frontier — W151

Document status: VERIFIED within the bounded W151 declared-Variant profile.
Production baseline: `b071191` (W150); source-reference-only parent: `713e180`.
Risk: CAUTION (persistent serialization).
Rollback: revert the isolated W151 feature commit; retain failed probes in
fresh `/private/tmp` evidence roots. Do not change old fixtures or stores.

## Boundary

The target is paired declared `Variant` in the existing normalized Object
whole-part writer and its file/column/table/catalog readers. Generic logical,
BASIC bulk and ordinary Wide binding already exist in W147–W149; their
borrowed-envelope evidence is not an independent Object part certificate.

Admitted schema surface: canonical `Variant` with 1..255 distinct,
strictly SQL-name-ordered arms over the existing Object recursive intersection.
Ordinary Array, Map(String,V), named/unnamed Tuple and legal Nullable may
contain Variant; Variant arms may contain those legal containers and eligible
LowCardinality leaves. Variant NULL remains a discriminator sentinel, not a
Nullable arm. No per-type-combination facade or guessed filename routing.

Still rejected: Dynamic alternatives containing Variant, typed Dynamic,
direct Nullable(Variant), direct nested Variant/Nullable/LC(Nullable) arms,
noncanonical/duplicate/Nothing declarations, non-String Map keys, Object
BFloat16, unrepresented Object leaves, COMPACT Variant, specialized prefix
files, Compact parts and general Object layouts. Existing Dynamic BASIC/
COMPACT selection is a separate serializer mode, not Variant admission.

Source oracle: separate shallow checkout
`/Users/sergey/SrcArchives/clickhouse-2026-10-04-depth1-37a251ff`, revision
`37a251ffa2805b33201486306db980bfa96d73e7`. Root's recursive comparison
against `9007d227` finds all serializer sources and Object/Variant declarations
unchanged; this is bounded source continuity, not executable qualification.
Executable oracle: pinned CH `26.10.1.1201`, build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`, SHA256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
It is not a build of the shallow checkout. Neither source inspection nor a
finite native witness matrix implies all type/profile products.

Source anchors in that checkout: `DataTypeObject.cpp:185-231,852-895` binds
typed declarations through DataTypeFactory and each child's serializer;
`DataTypeVariant.cpp:27-82` supplies direct-arm exclusions, normal roster
canonicalization and fixed discriminator order; `ColumnVariant.h:67-68`
pins UInt8/NULL=255/max255. `SerializationVariant.cpp:120-170,199-213` owns
discriminator/arm enumeration and UInt64 mode prefixes. `ISerialization.cpp:
308-322,349-367,395-410` carries Array levels, escaped Variant arm names and
Object typed-path prefixes. Advanced/chunked Object shared layouts override
their nested settings; they are not the admitted one-bucket MAP profile.

Root constructor discriminator (before production changes): seven admitted
JSON declarations and four direct-arm/wrapper exclusions pass on the pinned
runtime. This proves constructor eligibility only, not persisted lanes. Stock
SQL may normalize duplicates/order/Nothing; the library's borrowed declaration
grammar requires the resulting strict canonical form instead.

## Design laws and falsifiers

- Schema descriptor and borrowed-text paths share the same Object/Variant
  intersection. Reject noncanonical arm order before proportional copies;
  preserve nominal Enum/temporal/name identity and aggregate depth/node/edge/
  byte bounds. Forged/mutated borrowed preflights must be revalidated.
- Physical roles/names/prefixes come from the existing shared binder. Strip
  each role-owned prefix once, including an empty sparse arm. Collisions and
  unsupported layouts fail before filesystem access/publication.
- BASIC Variant without LC is stateless between marks and retains selected-only
  physical body reads. LC anywhere in the typed tree requires complete outer-
  grid replay and ancestor discriminator/size census. Middle/zero windows
  materialize only selected documents, charge the required replay and always
  validate every physical grid. No selected-only LC reset or zero-window grid
  validation bypass; no invented all-body validation promise for plain Variant.
- The shared name plan is not a physical byte binder: ordinary bulk Variant
  discriminators start at zero without a header; physical combined lanes carry
  UInt64 BASIC=0 and offsets shifted by eight. A paired bounded prefix owner
  must prepend/strip exactly once, distinguish LC's retained eight-byte header,
  and reject malformed modes before composing a logical lane.
- Whole library parts own every file, metadata, marks and checksums. Literal
  stock full/middle queries and actual ATTACH/CHECK must pass; a valid changed
  value with recomputed checksums must pass CHECK yet fail the literal oracle.

## Execution plan / DoD lineage

1. Root native constructor eligibility probe with accepted and forbidden
   controls, before production edits. A JSON-specific format override or
   constructor refusal pivots this design rather than silently narrowing it.
2. New `spec/object_declared_variant_w151_spec.cr` and consumer/adversary
   falsifiers: RED on baseline for schema, codec, physical/file consumers;
   exact/one-short budgets, full/middle/zero, NULL/unused arm and recursive
   Array/Map/Tuple/LC cases. Retain Dynamic rejection separately.
3. Extend `object_recursive_declaration.cr` and its borrowed-text owner;
   integrate typed admission in `object_document_codec.cr`,
   `object_document_physical_plan.cr`, `object_document_file_reader.cr`, and
   `object_document_column_writer.cr`. Add a separate shared prefix owner;
   the W149 script-only raw-lane normalization cannot serve production IO.
   Existing writer and table/catalog adapters must use these owners unchanged
   or receive a consumer-specific correction backed by a failing test.
4. Root focused DEBUG and affected RELEASE specs, serial root-owned native
   whole-part writer/stock-reader exchanges under both String profiles and
   existing Dynamic modes, independent literal checker and complete unique
   spec inventory in disjoint serial groups. Formatter and diff checks pass.
5. Hostile review of prefix/state/budget/nominal/consumer counterexamples;
   seal evidence and limits here and in `PROJECT_STATUS.md`; atomic local
   commit only after DoD. No push or performance/complete-engine claim.

Consumer inventory: `rg` for `contains_variant`, `reject_variant_typed_field`,
`ObjectRecursiveDeclaration`, `replay_complete` and `ObjectColumnReader`
finds the three explicit typed guards, shared declaration policy/parser,
existing Object whole-part metadata/writer, file reader, column reader,
table Object adapter and catalog materializer. W149's typed refusal assertion
must be superseded only for the admitted intersection; its Dynamic guard
remains executable. Schema-only tests are not persisted consumer evidence.

Stop rule: a failing source/runtime eligibility probe, unbound role, incorrect
sparse schedule, uncharged replay or native value mismatch prevents admission
and the working commit. Keep the broad all-types/MV/projection goal active.

## Implementation seal

Root executed the following gates on 2026-10-04. This seal supersedes the
typed-Variant refusal only within the boundary above, not typed Dynamic,
arbitrary Object layouts or every eligible type/profile product.

### Ownership and falsifiers

`BinaryBulkPhysicalPrefixAdapter` is a separate 275-line class/file. It owns
the role-to-prefix law: Variant discriminator lanes have eight-byte UInt64
BASIC=0 headers stripped before logical decode; LC dictionary version headers
remain in their logical payloads; ordinary roles remain unshifted. Complete
first/terminal/monotonic grids, unused sparse arms, coordinate overflow and
aggregate header/coordinate budgets are checked before adaptation or selected
body reads. A temporary read slice is borrowed only until `BinaryBulkStream`
makes its owned copy. Equal logical roles on distinct typed paths are legal.

Descriptor and borrowed-text owners preserve aggregate budgets, nominal arm
identity and canonical rosters. An internal protected Variant factory avoids
restarting budgets in nested declarations. Root's external-caller probe fails
compilation specifically because that factory is protected; this is visibility,
not a security boundary against privileged code in the Crystal namespace.

The baseline root probe was RED before production edits: three examples,
zero assertion failures and two errors. Final specs additionally attack
forged/mutated preflights, sibling aggregate budgets, unused nested arms,
nonzero COMPACT headers and corrupt unselected marks. A plain non-LC Variant
permits a valid middle/zero window despite an invalid tag in an unselected
body; selecting that body rejects it. LC-bearing trees reject that unselected
corruption because complete replay is required. Bad physical grids are rejected
even for middle/zero windows. There is no invented all-body validation promise.

### Root test execution

- Focused DEBUG: 109 examples across 18 unique files; zero failures, errors or
  pending examples, on the final formatted code.
- Affected RELEASE: 756 examples across 131 unique files in six serial,
  disjoint groups; all pass. This was before a final whitespace-only formatter
  change in two production files and one spec; final DEBUG, inventory and
  native gates use the formatted code.
- Complete inventory: 2,477 examples across all 387 unique spec files in 27
  successful serial, disjoint non-release groups; all pass. The first 275
  files retain debug symbols; the remaining 112 use `--no-debug`. This is not
  a combined-process or uniform-compiler-flag run.
- Formatter, shell/Ruby syntax and diff whitespace checks pass. Interrupted
  groups and compiler-memory guard failures are not counted as green tests.

Root alone ran jobs under `run_safe.sh`, with at least 50% free memory and one
job at a time. The compile guard was initially 8 GiB, raised to 12 GiB for the
legacy generic table inventory after smaller groups still hit the guard.
These are compiler limits, not reader/writer runtime memory or speed results.

Exact group inventories, successful summaries and logs are retained in
`/private/tmp/crystal-click-w151-root.ua8bdI`: `debug.log`,
`affected-grouped-summary.tsv`, `inventory-combined-summary.tsv`, `suites.rb`,
`resume_inventory.rb`, `tail_inventory.rb` and `small_inventory.rb`.
The executed focused command was root-owned `run.sh debug` with 18 explicit
files, wrapped by the guard with a 240-second/8-GiB limit. Its compiler command
is `crystal spec --single-module --threads 1 --link-flags=-fuse-ld=ld
--error-trace <explicit files>`. RELEASE adds `--release --no-debug`; inventory
uses the successful partitions above.

### Independent complete-part interoperability

The successful fresh native root is
`/private/tmp/crystal-click-object-variant-w151.20261004-root-r3`.
`scripts/check_object_variant_w151.sh` creates retained stores without
overwriting an existing root. Root ran it under the serial guard with
`W151_EXECUTE_AS_ROOT=YES`, the pinned `CLICKHOUSE_BIN`, explicit Crystal/Ruby
executables and a 600-second/8-GiB limit. It exits zero only after the Crystal
exchange and `scripts/recheck_object_variant_w151.rb` both pass.

Six positive cells comprise two stock parts and four independently
library-owned complete parts: both String profiles crossed with BASIC/COMPACT
Dynamic for the library parts. Each has six rows and three real two-row
granules plus the terminal mark. Seven declared witnesses are:

```text
aav    Array(Array(Variant(Array(UInt8), UInt64)))
av     Array(Variant(LowCardinality(String), UInt64))
mv     Map(String, Variant(String, UInt64))
nested Variant(Array(Variant(String, UInt64)), UInt64)
ntv    Nullable(Tuple(v Variant(String, UInt64), note String))
tv     Variant(Tuple(label String, score UInt32), UInt64)
v      Variant(Array(UInt8), String, UInt64)
```

Library parts own every data file, metadata, marks and checksums; no stock
envelopes are borrowed. All four actually ATTACH. Exact nominal types, literal
full/middle ordered RowBinary and actual CHECK pass. File/column readers cover
full/middle/explicit zero-mark windows; table/catalog consumers cover full/
middle and EOF with `limit: 1` producing no rows, not a zero-count API.
Catalog `["lab"]["events"]["j"].values` matches the complete literal document set.

Two additional stores discriminate guards and value correctness. Stock accepts
a typed COMPACT Variant part; the library refuses its nonzero BASIC header.
A fifth library-owned part changes row 2's Variant value from 42 to 43 and
recomputes checksums: actual ATTACH/CHECK passes but the original literal oracle
rejects it. Eight stores undergo actual CHECK/type/value checks altogether:
six positives, the COMPACT guard and the mutant. The independent Ruby oracle
issues 74 fresh SQL queries without Crystal value codecs and rejects the
CHECK-valid wrong-value control.

The separate Object-path witness requires `JSONDynamicPaths(j) = ['d']` on
every row and `JSONSharedDataPaths(j) = ['spill']` on rows 2/4/6 only.
`dynamicType(j.spill)` is String there, but its local Dynamic
`isDynamicElementInSharedData` flag is false. Object shared-path placement is
not that element's shared discriminator. The first oracle conflated them and
failed; root's actual SQL and `dynamicType.cpp:102-128` / `JSONPaths.cpp:143-176`
distinguished the contexts. Both independent oracles now require the separate
exact path-layout witness. No production serializer repair was needed. An
earlier checker compile failure was an abstract-Int/Int32 annotation issue,
also not a persisted-format failure. W146 did not establish the disputed flag.

### Identity, verdict and refresh

Source revision `37a251ff` and the separately pinned executable above remain
distinct. No current-master binary was built or qualified. The final 21
production/spec/script paths are SHA256-bound by
`/private/tmp/crystal-click-w151-root.ua8bdI/verified-code-files.sha256`, digest
`9e3c761cf7dd96d57e0839b810f8d669cdfd2b1e3001a7a1acf621279220684a`.
Docs are excluded to avoid self-reference. Root rechecks all files against
this manifest before the commit; it is an evidence index, not proof by itself.

Scoped hostile verdict: ROBUST for this bounded admission. Luna's static
review is correlated evidence; root independently ran the gates and attacked
prefix, sparse state, visibility, budget, grid and wrong-value boundaries.
Touched compressed frames are authenticated; window inspection/selection does
not authenticate untouched payload frames. LC still requires full replay and
may repeat it per catalog mark. No selective-I/O, RSS ceiling, performance
parity or exhaustive compatibility claim follows.

This seal decays when a declaration/codec/prefix/consumer owner, source/runtime
identity or physical profile changes. Refresh by rerunning affected specs and
the fresh complete-part script under an explicit guard. If temporary artifacts
are unavailable, rerun rather than reconstructing green results from prose.
The broad paired-types, MV/projection, architecture and later performance
objective remains open.
