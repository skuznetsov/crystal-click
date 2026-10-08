# Crystal Click landmarks

## Storage composition boundary — W226

- Active objective: ClickHouse-compatible read/write types and MV/projection
  inspection. Memory/performance optimization remains deferred; the overall
  objective is not complete.
- W225 baseline: `6e3d94432ddf94eaaea85f6b095f52740900d0bd`.
- W226 reuses the existing Count and finite Sum-family leaf codecs inside
  generic Dynamic scalar/V3 known/shared routes. Wrapper composition also
  carries stream names, child row domains, prefix/state and mark grids.
  AggregateFunction argument descriptors are metadata, not child value lanes.
- Refuted route: widening only the scalar/physical visitor was insufficient.
  The first candidate compiled but produced three bulk/writer errors because
  four Dynamic logical role visitors did not recognize the aggregate leaf.
  Each now treats it as one data role; no product serializer was added.
- Evidence: 327 examples in the same 55 affected spec files in DEBUG and
  RELEASE; eight paired native profiles and 171 audited raw processes per
  mode. A coherent successful-exit CHECK-zero seed is rejected. This is
  finite quiescent Wide/LZ4/Default/plain-mrk2 Dynamic V3 compatibility, not
  all types, all recursive combinations, live-part safety or performance.
- Return pointer: [Dynamic frontier](docs/AGGREGATE_FUNCTION_DYNAMIC_FRONTIER.md)
  and [scoped evidence index](.landmark/evidence/aggregate-function-dynamic-w226.json).
- Still closed: JSON aggregate actuals, Object shared aggregate envelopes,
  borrowed persisted Dynamic/aggregate states, the legacy fixed-union Dynamic
  API, unsupported aggregate families/versions and source-invalid wrappers.
- Next discriminator: classify each remaining gap as leaf codec, wrapper
  context/layout, consumer integration or source-invalid composition; obtain
  an independent stock-authored fixture before widening the boundary.
- Standing authority: bounded local implementation, hostile review and atomic
  local commits. This slice does not authorize push, remote history changes,
  production-data mutation or restarting performance work.
- Decay: refresh after codec/admission/layout/fixture/helper/source/runtime
  changes. Temporary raw roots are an evidence cache; regenerate with the
  recorded commands if unavailable. Do not treat their absence as success.
