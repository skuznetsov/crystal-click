# Recursive JSON actuals inside Dynamic — W212

Document status: implemented and verified within the finite W212 scope
(2026-10-07). Baseline:
`eedc19138d9aa4744ddd6eb6bcdd9565b588b801`. The full type compatibility,
MV/projection support and eventual performance objective remains active.

## Boundary

W210/W211 reuse the Object owner for a direct ordinary JSON actual and expose
generic Dynamic values through table batches. The recursive BinaryBulk walker
already owns Array/Tuple/Map/Nullable structure, but the JSON binding identity
stops at `(Dynamic site, canonical arm)`. It cannot address two JSON leaves in
one Tuple actual or the elements of an Array actual.

Required capability: compose the existing Object serializer at every exact
JSON leaf in a legal, ordinary Dynamic actual descriptor, through normalized
bulk codecs, physical complete-part writing/automatic reading and the existing
generic table batch route. Preserve the direct binding API. Do not invent a
codec for each wrapper product or a second wrapper traversal for value serde.

Admitted: wrapped ordinary JSON leaf composition in the existing normalized
bulk, Wide physical/public part and W211 typed table routes. The existing
wrapper and Object owners retain their admitted layouts; the finite native
matrix below does not qualify every wrapper product or layout. Still rejected:
nominal JSON bulk declarations, SharedVariant inline
JSON, unbound JSON actuals within Object path Dynamic, JSON SKIP/SKIP REGEXP,
CH-illegal type combinations and unsupported layout/version domains.

Non-guarantees: live Active snapshots, checksums of every source byte, lazy
validation cost, memory/RSS performance and whole-project completion. No
functions, joins, optimization or unrelated consumer refactor in this slice.

## Design laws

- A leaf identity includes its owning Dynamic site, canonical actual arm and
  exact descriptor path. Existing direct bindings resolve to the arm root.
  Separate Tuple JSON leaves remain distinct even with equal descriptors.
- The common recursive descriptor traversal owns wrappers. JSON leaf hooks
  delegate adaptation and serde to the existing Object child owner. Metadata
  discovery is parent-first and includes unused leaves; never infer a roster
  from selected data, statistics or a nonempty result window.
- Preserve P (root physical rows per mark), Q (Dynamic-site occurrences),
  R (selected actual-arm occurrences) and E (one JSON leaf's occurrences).
  Direct JSON has E=R; Array children can have E=0 or E>R. Object children
  receive `(P,E)`; `.mrk2` third words stay P. Empty and unselected leaf domains
  retain metadata and the complete parent mark grid.
- Nullable positions that have a serialized child require its default row;
  null does not automatically remove that child's occurrence. Only Array
  flattening and discriminator routing change the corresponding domains.
- Physical name resolution preserves escaped tuple components and inherited
  Array levels. ArrayElements is not a literal `.elements` filename component.
  Ordinary String profile and Object shared MAP profile remain separate.
- Descriptor depth, node/name/transport allowances and child grids borrow the
  existing operation context. Do not restart budgets by using a root-only
  RecursiveStorageColumn API at an actual-arm child site.
- Validate every bound leaf schedule before publication or table callbacks,
  including zero selections. Staged comparison must inspect JSON content at
  arbitrary wrapper depth, not only ordinary BinaryValue bytes/children.

## Execution and DoD

CAUTION: serialization and public storage boundary. Rollback: the exact scoped
diff/atomic local feature commit from the clean baseline; no remote action or
source data mutation. Most likely false positive: matching reader/writer
mistakes in leaf identity, physical names or P/E mark accounting.

1. Qualify explicit stock Array(JSON) and Tuple(JSON,JSON) actuals and ordinary
   rather than SharedVariant storage. Add a compiling public RED on baseline
   before any production edits. Root alone executes serial guarded workloads.
2. Generalize binding identity/metadata/normalized leaf hooks and census, then
   compose physical child plans/loaders and public writer arguments. Inventory
   shared API consumers before editing. Keep one source file per new owner.
3. Execute focused and affected inherited DEBUG/RELEASE specs with unchanged
   guard limits and exact disjoint rosters if compiler resources require it.
4. Fresh stock-authored parts must read automatically; stock must directly
   ATTACH/CHECK library parts. Observe independent literal values, actual types,
   stream/checksum rosters, full/middle/final/EOF windows and mark counts across
   both existing String profiles.
5. Hostile review and executed defect seeds must detect leaf collisions,
   incorrect nonzero P, unused/empty-leaf validation bypass and hidden JSON
   staged-content corruption. Restore exact source bytes, rerun focused gates,
   record scoped evidence and commit only after DoD passes.

Focused command: guarded `crystal spec spec/dynamic_json_recursive_w212_spec.cr
spec/dynamic_json_recursive_physical_w212_spec.cr --single-module --threads 1
--link-flags=-fuse-ld=ld --error-trace`, plus
`--release`. Expected final signal: actual exit 0 and zero failures/errors/
pending. RED must be an executed missing-capability error, not a compiler error.
Affected roster is derived from binding, codec, metadata, physical, public and
table consumers at the final source state; it must be recorded explicitly.

Required falsifiers: selected empty and multi-element Array(JSON); two JSON
leaves in one Tuple; deeper legal wrapper recursion; different P/Q/R/E; unused
leaf; missing/extra/duplicate/wrong-path bindings; malformed child schedules
and metadata on empty reads; inherited depth and aggregate allowance failures;
no destination publication or callback on validation failure; legacy direct
bindings unchanged. Changes to these owners, occurrence domains, source/runtime
pins or tested layouts reopen associated evidence. Implementation and native
results will update this banner rather than silently widening it.

## Executed entry evidence

The baseline public RED compiled and executed on `eedc191`: two examples,
zero failures, two runtime errors (`JSON is not admitted as Dynamic actual
type`). This is missing-capability evidence, not a compiler failure.

Pinned stock runtime qualification observed six literal SQL values outside
SharedVariant: empty and populated Array(JSON), Tuple(JSON,JSON),
Array(Tuple(String,Nullable(JSON))), Map(String,JSON), and
Array(Variant(JSON,UInt8)). These are legal value/type qualifications only;
they do not establish physical-part interoperability.

The sealed optional `json_object_leaf_plans` API keys each Object plan by
`BinaryDynamicJsonLeafKey(dynamic_site, canonical_arm_index,
descriptor_child_path)`. A detached descriptor path prevents mutable caller
state from changing key identity. Legacy `json_object_plans` direct bindings
normalize to the empty path and retain their non-lossy direct accessors.

Entry evidence root: `/private/tmp/crystal-click-w212.0T4qUa` (ephemeral).
Runtime SHA-256: `bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
Source reference: ClickHouse `0ca8150d9b1d0886edb2e3b4ab65eebb768d0357`;
runtime build: `d9bcb5ab007f0f6299f7f973f2642245bab3d028`. They are distinct
pins.

## Executed implementation evidence

The common BinaryBulk wrapper walker now carries an exact JSON leaf key and
delegates only that leaf to the existing Object adapter. The physical resolver
uses the same descriptor path to retain escaped tuple components and Array
levels. `BinaryDynamicJsonLeafKey` and `BinaryDynamicJsonObjectSchedule` each
have their own source file: immutable identity and complete-domain shape/
discriminator census are separate responsibilities, not per-product codecs.
Legacy direct bindings retain their non-lossy API; a wrapped binding cannot be
silently projected onto the old `(site, arm)` identity.

Root executed the same 62 affected spec files in seven disjoint cohorts per
mode: 388 DEBUG and 388 RELEASE examples, zero failures/errors/pending and
actual guarded exit 0. Final focused gates pass 17 examples per mode. A prior
executed four-failure RED distinguishes allocation-free key ordering and site
copy preflight; its production correction retains exactly one detached site
string only after budget admission. This is not an RSS/performance claim.

Four deliberate production seeds are detected before exact source restoration:
leaf-path erasure (three executed errors), P replaced by E (four executed
errors), unused-leaf validation bypass (two assertion failures), and omitted
deep staged JSON comparison (one assertion failure). The latter guards both
content and raw-path identity within an equal-but-distinct owner tree. A fifth
Ruby oracle seed disabling unfamiliar-child rejection fails its unchanged
self-test. The restored core and full source hashes match the final unit/build/
native state recorded in `.landmark/evidence/dynamic-json-recursive-w212.json`.

Fresh paired stock/library witnesses cover six families in each String profile
(`single_stream`, `with_size_stream`), in both DEBUG and RELEASE:

- root Dynamic ordinary `Array(JSON)`;
- root Dynamic ordinary named `Tuple(JSON,JSON)`;
- root Dynamic ordinary `Array(Tuple(String,Nullable(JSON)))`;
- root Dynamic ordinary `Map(String,JSON)`;
- root Dynamic ordinary `Array(Variant(JSON,UInt8))`;
- outer `Array(Dynamic)` containing ordinary `Array(JSON)` actuals.

Each mode reads 12 fresh stock parts and directly ATTACH/CHECKs 12 library
parts. Literal actual types, values, binding paths, full/middle/final/EOF/table
windows, parent P and all child mark third words are checked. The independent
on-disk manifest census rejects missing/unfamiliar Object descendants, allowing
only the source-derived physical wrapper siblings. VariantElementNullMap is a
virtual subcolumn, not a persisted lane admission. All `.bin`/`.mrk2` filename
hashes agree with the complete manifest; selected checksum rosters agree too.

Root reconciled raw invocation argv/stdin/stdout/stderr bytes and hashes,
executed process status, pinned executables and unchanged full source/library
part snapshots. All 874 library-part files are byte-identical across modes.
Actual outer guards were unchanged: Crystal 600s/12288 MiB, Ruby 120s/1024 MiB,
minimum free memory 50%; the bounded native executor uses 10s plus 2s termination
grace, and ClickHouse uses one thread/512 MiB. Runner outer-guard fields are
explicitly `declared_not_measured`; root guard execution is separate evidence.

Scoped Adversary verdict: ROBUST for this component and the executed corpus.
Earlier compiler/obsolete-guard/oracle failures and pre-review passes are not
counted as final evidence. Native layout remains Wide/LZ4/plain `.mrk2`, BASIC
Map, sparse Variant, Dynamic/Object v3 and Object shared MAP. No all-layout,
all-product, checksum-hash, transient RSS, selected-window complexity or global
callback-atomicity claim is made.

Next: SharedVariant inline JSON and Object path Dynamic binding composition;
owned offline-column values and projection/MV consumer propagation; remaining
physical layouts and JSON SKIP/SKIP REGEXP. Repository-wide class decomposition
and inherited owner-accounting gaps remain open. The overall goal stays active;
performance remains deferred. Raw evidence is ephemeral under `/private/tmp`:
refresh by the recorded build/spec/probe commands after source, descriptor,
occurrence, budget, layout, runtime or consumer boundaries change.
