# Crystal Click landmarks

## Offline materialized-view metadata — W228

- Active objective remains ClickHouse-compatible read/write types and MV/
  projection inspection. Memory/performance is deferred; this slice does not
  complete the overall objective.
- Baseline: `6a8a31ee125188363361d50408159341dbb1318a`.
- Scoped result: VERIFIED offline MV declaration inspection and explicit
  resolution against current local physical-table metadata only (adversary
  verdict: ROBUST). Detached declarations preserve exact SELECT/WITH text,
  optional inner engine and tagged named/explicit-inner/implicit-inner target.
  Direct source-reference completeness is conservative and syntactic; unknown
  query shapes have no partial references. Resolution proves identity, not
  target contents.
- Evidence: same 35 affected specs pass 187 examples in DEBUG and RELEASE,
  zero failures/errors/pending. Paired native runs and separate raw audits each
  qualify 11 views, 26 actual metadata files and 20 process records per mode
  (19 successes and one expected stock table-function refusal). Two refresh/
  security guards, two resolver negative controls and an ordinary projection
  metadata control are included. Both audits reject coherent equal-width
  cross-database target-reference forgery in helper JSON and captured raw
  stdout despite green original statuses; exact restoration returns both
  audits to pass.
- Frozen helper SHA-256: DEBUG
  `c6962ed70ac99ecdd0b91ef2ebd8cf391aab1807f1113d8ddbf1f0d2421588c5`;
  RELEASE `105f1d7fe16b50dcbe6328130ae56817816f4580d0b643fdc4ce26a8da2948a2`.
  Native/evidence roots and run logs are indexed by
  [the W228 evidence packet](.landmark/evidence/materialized-view-metadata-w228.json)
  and [the W228 frontier](docs/MATERIALIZED_VIEW_METADATA_FRONTIER.md).
- Refuted routes: ignoring SAMPLE/comma suffixes falsely completed a partial
  relation inventory; discarding table-as-string-literal tokens manufactured
  `lab.AS`. Both are fixed by conservative unknown classification and have
  source-backed regression coverage. A suggested SharedSet/Join inner-target
  restriction was also rejected: that parser guard belongs to table creation,
  while the MV target parser accepts the measured MergeTree form.
- Scope boundary: not full SQL analysis, source existence/dependency graph,
  INSERT-trigger completeness, query execution, Active/freshness state, general
  MV/projection support, full-repository coverage or performance.
- Return pointer: [W228 frontier](docs/MATERIALIZED_VIEW_METADATA_FRONTIER.md).
  Full goal stays active; performance stays deferred; no push authority.
- Type-roadmap correction: child serde already composes recursively; distinguish
  a new leaf codec from per-occurrence physical state/layout, consumer admission,
  missing native qualification and source-invalid trees. Do not count every
  unmeasured recursive product as an unimplemented serializer.
- Next discriminator: qualify the next source-valid MV/projection inspection
  form or a genuine remaining leaf/layout integration gap before widening it;
  retain unknown-versus-empty and declaration-versus-runtime-state boundaries.
- Decay: refresh after parser/analyzer, descriptor/resolver, fixture/helper,
  source or runtime changes. Temporary raw roots are evidence caches and must
  be regenerated if missing; do not interpret their absence as success.

## Aggregate state boundary — W227

- Active objective: ClickHouse-compatible read/write types and MV/projection
  inspection. Memory/performance optimization remains deferred; the overall
  objective is not complete.
- W226 baseline: `0402a6bbfd8512105589acb8b1500a75780dbadc`.
- W227 pairs opaque AggregateFunction(avg,T) states across 37 source-valid leaf
  kinds and eligible argument shells. The numerator is 8/16/32 bytes; the
  denominator is bounded canonical VarUInt, not a fixed stride or blob length.
  Nullable argument absence is one flag byte. Exact argument descriptors remain
  nominal metadata, not child value lanes. One new Avg layout owner has its own
  file; existing static/Variant/Dynamic routes reuse it.
- Refuted route: the non-Count fixed-width assumption does not hold for Avg.
  Adjacent 127/128/16384/max counts and Nullable/sentinel controls distinguish
  boundaries. Logical role root.data and physical column stream v are different
  namespaces; corrected harness expectations preserve both exact checks.
- Evidence: 346 examples in the same 58 affected spec files in DEBUG/RELEASE;
  148 paired native root profiles (136 base + 12 metadata), 13 computed probes
  and 162 audited raw processes per mode (160 successes + two expected Enum
  refusals). All 1,776 generated files agree by actual bytes and inventory.
  Scope is finite quiescent Wide/LZ4/Default/plain-mrk2, not all products,
  aggregate execution, live-part safety or performance.
- Hostile audit: a coherent retained-file forgery initially passed the auditor.
  Independent actual before/after file equality now rejects it; successful-exit
  CHECK-zero also rejects in both modes. Exact restoration returns audits green.
  Inventory covers files, not empty-directory topology; helper provenance comes
  from the externally pinned, root-recorded builds.
- Return pointer: [Avg frontier](docs/AGGREGATE_FUNCTION_AVG_FRONTIER.md)
  and [scoped evidence index](.landmark/evidence/aggregate-function-avg-w227.json).
- Still closed: JSON aggregate actuals, Object shared aggregate envelopes,
  borrowed persisted Dynamic/aggregate states, the legacy fixed-union Dynamic
  API, unsupported aggregate families/versions and source-invalid wrappers.
- Next discriminator: choose the next aggregate state grammar or MV declaration/
  target/dependency inspection slice. Classify leaf, wrapper context/layout,
  consumer integration and source-invalid gaps separately; obtain independent
  stock-authored evidence before widening persisted support. MV/projection
  metadata/explicit child reading is not general execution or writing.
- Standing authority: bounded local implementation, hostile review and atomic
  local commits. This slice does not authorize push, remote history changes,
  production-data mutation or restarting performance work.
- Decay: refresh after codec/admission/layout/fixture/helper/source/runtime
  changes. Temporary raw roots are an evidence cache; regenerate with the
  recorded commands if unavailable. Do not treat their absence as success.
