# Wide Part Reader Frontier SDD

Document status: verified bounded slice

Current frontier: read one local immutable ClickHouse Wide part containing a
plain `UInt64` column encoded with `CODEC(LZ4)` and adaptive, uncompressed
`.mrk2` marks. The fixture producer is ClickHouse `26.7.1.1315`, revision
`54512`.

Bounded context: physical MergeTree part reading. This is not a SQL or table
execution engine boundary.

## Admitted surface

- Open a local part directory without modifying it.
- Parse `columns.txt` and `count.txt` for the bounded fixture schema.
- Discover a simple column's original-name or ClickHouse SipHash128-named
  `.bin` and `.mrk2` streams.
- Parse adaptive Wide marks as bounded offset/granularity records.
- Treat a final zero-row mark as the right boundary whether it points inside
  the final decompressed block or to data-file EOF with local offset zero.
- Parse ClickHouse compressed-block framing and decompress LZ4 blocks.
- Decode little-endian `UInt64` values for the full column and a selected mark
  range.
- Reject unsupported or malformed input before returning partial values.

## Rejected surface

- Compact parts and `.mrk3`/`.mrk4` marks.
- Compressed `.cmrk*` marks.
- ZSTD and composite codecs such as Delta, Gorilla, or T64.
- `String`, Nullable, LowCardinality, Array, Map, Tuple, Object, Dynamic, or
  multi-stream serialization.
- Projections, mutations, patch parts, lightweight deletes, remote disks, and
  object storage.
- Checksum verification, `checksums.txt` validation, writes, merges, SQL,
  filtering, aggregation, or query planning.
- Broad compatibility claims for the private Tokenomics fixture.

## Guard-only future

- Codec dispatch is an explicit boundary so ZSTD and composite codecs can be
  added without changing part discovery.
- Checksum bytes are consumed as part of the frame, but this slice must expose
  that they are not verified.
- Type dispatch rejects every type except exact `UInt64`.
- Mark dispatch rejects every extension except exact `.mrk2`.

## Non-goals

- Beating ClickHouse performance in this slice.
- Eliminating Crystal's GC before allocation measurements exist.
- Recovering from corrupt data or guessing an unsupported format.

## Design laws

1. Unknown format, codec, type, size, or offset fails closed.
2. Arithmetic involving on-disk sizes and offsets is bounds-checked.
3. A read returns the declared number of rows or an error; never a silent
   prefix.
4. The private Tokenomics part is a later compatibility/stress fixture and is
   never published.
5. Correctness parity precedes allocation or throughput optimization.

## Execution order

1. Generate and freeze a deterministic public one-column fixture.
2. Establish RED specs for metadata, marks, framing, full scan, range scan, and
   malformed input.
3. Implement the smallest parser and decoder needed to turn those specs green.
4. Compare decoded values and row counts with the ClickHouse producer.
5. Run an adversarial corruption probe before widening the frontier.

## Falsifier roster

- Unknown mark extension is rejected.
- Truncated `.mrk2` record is rejected.
- Mark offsets outside the `.bin` stream are rejected.
- Unknown compression method byte is rejected.
- Truncated header or payload is rejected.
- Declared compressed/decompressed sizes outside configured limits are
  rejected.
- A zero-sized decompressed frame is rejected.
- A valid EOF final sentinel reads both the whole column and the last mark.
- LZ4 output length mismatch is rejected.
- A decompressed byte count not divisible by eight is rejected for `UInt64`.
- Decoded row count different from `count.txt` is rejected.
- A checksum-only mutation is a documented non-guarantee until verification is
  admitted.

## Stop rules

- Do not add another type or codec while any current falsifier is red.
- Do not optimize allocations until the exact-value differential test passes.
- If the generated fixture is not Wide with plain `.mrk2`, change fixture
  settings rather than teaching the reader to accept a broader format.

## Implementation seal

- Slice: Wide `UInt64` + LZ4 + `.mrk2` reader.
- Source/spec: `src/`, `spec/`, this SDD, and the deterministic fixture
  generator.
- Falsifiers: focused Crystal specs plus fixture regeneration comparison.
- Evidence: exact values, row count, mark-range result, and corruption errors.
- Boundary: ClickHouse `26.7.1.1315` fixture; checksum verification rejected.
- Next local track: checksum verification or ZSTD, selected from measured need.

## Verification record

- `21` focused and full Crystal examples pass, including exact `0..199999`
  values, ordinary and EOF final sentinels, final-mark range, and malformed
  frames/marks.
- Two SipHash128 stream-name vectors match files independently produced by
  ClickHouse `26.7.1.1315`.
- The copied Tokenomics Wide part fails closed as unsupported because its
  schema, codecs, and compressed marks are outside this frontier.
- Source lineage was checked against ClickHouse commit
  `066ea77cf4221959f9f8dc615f6ce776521b52ff`; the final adversary verdict is
  `ROBUST` within this slice.
- This evidence becomes stale if the fixture producer version, mark layout,
  compressed-block framing, or supported-format frontier changes. Refresh by
  regenerating the fixture with the pinned producer and rerunning the declared
  Definition of Done plus adversarial corruption specs.
