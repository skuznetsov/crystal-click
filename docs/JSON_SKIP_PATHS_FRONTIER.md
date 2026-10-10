# JSON SKIP paths frontier (W253)

Status: VERIFIED / root adversary ROBUST within the finite declared target.
Overall all-types and MV/projections goal ACTIVE; memory/performance remains
deferred.

## Boundary and factual anchor

Baseline: `05e34b374a1a540785efd398af2965649e156eb4`, clean at entry.
At baseline the v0 JSON descriptor emitted zero SKIP counts and rejected a
nonzero SKIP path roster. SQL identity, root Object schemas and the Dynamic
binding therefore could not preserve it. Recursive leaf/container codecs exist;
this change must not introduce a serializer per wrapper product.

Comparison source: `/private/tmp/clickhouse-w249-upstream-P7bxRQ`, shallow
revision `fe0f91b6c3de9e1efa33a1bce4ca9bcbfb4c509d`. Separate stock runtime:
26.10.1.1201, build `d9bcb5ab007f0f6299f7f973f2642245bab3d028`, executable
SHA-256 `bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.

Root native characterization under `/private/tmp/crystal-click-w253.2QKcny`
establishes sorted/deduplicated SKIP identity, raw-prefix typed-path conflict,
and distinct text/binary predicates. The independently authored binary input
`binary-skip-input.bin` contains JSON(SKIP a, SKIP z) paths a=1, ab=2, b=5,
z=3, zx=4. Stock retains b=5 and zx=4; exact matches drop, the interior
preceding raw prefix drops ab, and the final-prefix lower_bound-end case
retains zx. These are observed compatibility laws, not desirable new policy.

Additional stock edge characterization confirms that the constructor conflict
is directional: typed `secretary` with SKIP `secret` rejects, while typed
`secret` with SKIP `secretary` succeeds. A raw SKIP-path name `SKIP` renders as
`JSON(SKIP SKIP)`; only the typed-path context forces that keyword into
backticks. A quoted raw path `REGEXP` renders as `JSON(SKIP REGEXP)`, but feeding
that emitted name back to the same stock runtime fails with syntax exit 62.
Retain this upstream non-reconstructible wire identity without admitting it
to the SQL-name-dependent schema or legacy Dynamic transport boundary.

## Admitted surface and design laws

- One immutable own-file SKIP-path owner supplies sorted/deduplicated detached
  raw identity, no-copy preflight access, constructor conflict checks and the
  separately named binary-deserialization predicate. Raw names reuse
  JsonPathSqlName; SQL and physical escaping remain separate.
- BinaryJsonType, descriptor wire codec, canonical recursive type-name parser,
  equality/hash and shared operation/name budgets retain SKIP metadata.
  Embedded paths keep the existing 256-byte raw-name fence. Root Object paths
  keep operation-budget-bound lengths rather than gaining that cap.
- Typed-path and SKIP-path presentation use explicit contexts with matching
  no-copy size/write functions. The scalar binary descriptor retains raw
  `REGEXP` names; SQL-name-dependent canonical parsing, Object schemas/bindings
  and legacy Dynamic name transport refuse ASCII case variants of that name
  rather than silently changing stock nominal identity.
- ObjectDocumentSchema/parser and Dynamic-to-Object binding preserve the same
  policy identity through existing physical plans, writer, direct, table,
  candidate/offline consumers. Values and stream layouts are reused.
- Constructor conflicts use raw starts_with for every typed/skip pair, as in
  DataTypeObject.cpp:93-105. Binary input uses SerializationObject.cpp:84-99:
  exact set membership, then lower_bound with both non-begin and non-end
  conditions and the preceding raw prefix. Do not substitute the text parser's
  exact-or-dot-descendant rule or silently fix the final-prefix behavior.
- Skipped binary runtime values must still be completely consumed and charged
  against shared limits; malformed/truncated/unsupported skipped values may
  not bypass validation. Duplicate raw row-path and missing typed-path guards
  remain. Serialization of already-decoded stored rows does not rerun JSON
  text-ingestion normalization or discard persisted paths.
- Charge complete supplied metadata rosters and bytes before proportional
  retained copies, including duplicate SKIP entries before deduplication.
  Canonical name expansion remains preflighted, and empty/malformed names,
  raw typed-prefix conflicts and exhausted budgets reject before publication.

## Rejected surface and non-goals

SKIP REGEXP remains refused until an actual RE2-compatible backend and its
constructor/binary/text context laws are qualified; Crystal Regex is not a
substitute. This slice adds no JSON text-ingestion API, auto key escaping,
invalid-UTF-8 physical profile, new storage layout, Compact part writer,
aggregate family, general keys/partitions, MV/projection materialization or
performance claim. Existing layout/admission guards remain authoritative.
The ordinary raw SKIP-path name REGEXP is not itself a regex clause, but its
stock-generated SQL name is non-reconstructible and remains guard-only at
SQL-name-dependent boundaries. Its scalar descriptor bytes remain admitted.

## Plan, rollback and DoD

Risk: CAUTION (nominal serialization and skip-dependent value consumption).
Likeliest failure: a locally round-tripping descriptor loses policy in a
physical handoff, or a reader treats text and binary skip as interchangeable.
Rollback: one atomic local commit after gates; until then patch only W253-owned
hunks against the clean baseline. No push/history rewrite.

1. Add behavioral REDs using current wire/parser APIs, independent literal
   descriptors/rows and source-backed constructor/binary counterexamples.
   Root runs RED before any production edits.
2. Shared owner, embedded metadata/value/type-name/budget integration; root
   Object schema/parser/binding integration with retained public overrides.
   Enumerate and update exact consumers before widening their admission.
3. Run focused and affected DEBUG/RELEASE specs serially through run_safe,
   min free memory 50%, one compiler worker, unchanged 12 GiB/600s limits.
   Commands: guarded crystal spec with --single-module --threads 1
   --link-flags=-fuse-ld=ld --error-trace, optionally --release --no-debug.
   Expected: zero failures/errors/pending; malformed skipped input, policy
   identity, aliasing, aggregate budget and prior no-SKIP regressions covered.
4. Build paired native helpers and run fresh reciprocal root Object and
   embedded Dynamic/Array(Dynamic) SKIP part witnesses through existing owners.
   Stock ATTACH/CHECK=1, exact schema/literal values and stock-write -> library
   direct/public/owned/offline reads are required. Bind fixture settings and
   source/runtime/helper inputs; no runtime build is inferred from source.
   All three cases use max_dynamic_paths=3 and the existing six UInt8/Nullable
   typed paths. Embedded JSON has counter/secretary/zz Int64 lanes; root Object
   has secretary/zz Int64 lanes (stock text inference). Retained secretary/zz
   prove bulk reads do not reapply the
   scalar prefix rule; native input does not rely on retaining exact secret/z.
5. Root independently inspects raw captured bytes/statuses, exact policy
   rosters, parent/child schedules and generated part bytes. Hostile controls
   attack policy omission/identity substitution, malformed skipped payload,
   typed-prefix conflict, final-prefix behavior and forged success reports.
   The fixed 48-file affected roster is split into ordered 20/14/14 groups
   without changing compiler/process limits. Require restored baseline
   acceptance, formatting, Ruby syntax and diff
   checks before a scoped closure claim and local atomic commit.

Root retains gates/review/integration. Luna workers have disjoint source,
adapter and test/harness ownership, are not alone, and must not revert others,
run heavy gates, change frozen inputs, or write Git. Specific assignments follow
the source/consumer inventories. Same-lineage review is correlated.

Qualification expires on changes to path ownership, serde, parser, budgets,
binding, physical streams or pinned runtime/source/fixture inputs. Temporary
captures are evidence caches; their loss requires refresh. This qualified
W253 does not close REGEXP, all layouts/state families, MV/projections or the
full project objective.

## Observed qualification and continuation

Root observed behavioral RED before production edits: three examples, one
failure and two errors, exit 1. Later explicit SKIP-keyword and raw REGEXP-name
counterexamples also rejected the incomplete implementation. Compilation and
scratch-auditor expectation errors are excluded diagnostics, not compatibility
evidence. The final ordered 48-file affected roster passes 121 + 93 + 115 = 329
examples in each DEBUG/RELEASE mode, zero failures/errors/pending. Both final
helpers build; final formatting, Ruby syntax and diff checks are required for
the atomic local commit.

Four fresh reciprocal cells qualify adaptive Wide/BASIC V1/single-stream and
V2/sized-stream in both modes, with root Dynamic, Array(Dynamic), and root
Object. Eight native and four helper invocations establish library parts passing
stock ATTACH/CHECK=1 with exact schemas, values and actual types, plus stock
parts read through direct/public/owned Dynamic or offline Object APIs. Used
and unused JSON arms retain the same SKIP roster but distinct dynamic caps.
The finite fixture covers six raw typed paths, nullable data, persisted
secretary/zz Int64 lanes, the embedded counter lane, empty first windows,
unused child metadata and EOF. It does not treat the text-ingestion predicate
as the scalar binary or stored bulk-read predicate.

Root independently reconciles all 104 raw Dynamic structures, type rosters,
unflagged statistics and physical mark coordinates across the four cells. It
also checks literal UInt8/Int64/null lanes, complete physical stream/file
rosters, primary keys and Array row sizes. Array wire sizes [0,0,2,1,1,1] are
distinct from cumulative offsets [0,0,2,3,4,5] and Q=[0,3,2]; physical children
retain P=[2,2,2] plus EOF. Object object_structure metadata is presence/roster/
snapshot-bound and consumed by both readers, not fully independently decoded
by the raw auditor. Native CHECK supplies checksum acceptance; raw LZ4 decode
and SipHash filename checks do not replace a full checksum parser.

All 572 generated files / 125,471 bytes per mode match by actual file bytes,
not merely by snapshot hashes. Six in-memory hostile controls reject at their
intended guards: omitted SKIP identity, used-versus-unused JSON cap substitution,
literal Int64 signature forgery, raw-bound Dynamic statistics, raw type-name
roster and a mark/statistics-prefix coordinate. Baseline and restored four-cell
acceptance pass; captures are not mutated. The initially incorrect scratch
W185 harness filename extension was corrected without changing any frozen
production, fixture or capture input.

The [root-owned evidence index](../.landmark/evidence/json-skip-paths-w253.json)
records the commands, pins, captures, raw auditor and controls. It is a curated
index, not proof from fields or model agreement. Refresh after relevant source,
toolchain, helper, oracle, runtime or fixture changes, or temporary capture loss.
SKIP REGEXP/RE2, general JSON text ingestion, arbitrary layouts and recursive
products, Compact writing, remaining aggregate states, native MV/projection
writes and broader facade decomposition remain open. No full-suite, server
Active-state, stock re-emission, performance or all-types closure is claimed.
Next work should compose existing codecs with explicit physical state and
coordinate bindings, not introduce a codec for every type product. Overall
goal ACTIVE; memory/performance deferred; no push.
