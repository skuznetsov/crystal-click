# Crystal Click landmarks

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
