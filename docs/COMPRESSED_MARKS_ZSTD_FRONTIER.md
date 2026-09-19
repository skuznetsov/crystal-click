# Compressed Marks and ZSTD Frontier SDD

Document status: verified bounded slice

Current frontier: read a one-column Wide `UInt64` ClickHouse `26.7.1.1315`
part whose adaptive marks are stored in `.cmrk2` and
whose physical data blocks use ZSTD. Preserve the already admitted plain
`.mrk2` + LZ4 behavior.

Bounded context: physical MergeTree compressed-block and adaptive-mark
reading. This is not a compatibility claim for the complete Tokenomics schema
or a SQL execution-engine boundary.

## Factual anchors

- The private Tokenomics Wide part has `60` `.bin`/`.cmrk2` stream pairs.
- Its declared default data codec is `CODEC(LZ4)`, while the observed first
  compressed-block method byte of every `.cmrk2` stream is `0x90` (ZSTD).
- All `60` `.cmrk2` files are one ZSTD block declaring `504` decompressed
  bytes, exactly `21` adaptive mark records of `24` bytes each. Every stream
  has monotonic offsets and a final sentinel; `55` start at `{0, 0}` and `5`
  start at a non-zero stream offset, reinforcing that the multi-column part is
  outside the one-column `WidePart` contract. The part's exact row count is
  `150414`.
- The implementation environment currently provides libzstd `1.5.7` through
  `pkg-config libzstd`; this is an environment fact, not a portable guarantee.
- At ClickHouse source revision
  `066ea77cf4221959f9f8dc615f6ce776521b52ff`, compressed marks are selected by
  the `.cmrk2` extension and decoded through the ordinary method-byte-driven
  compressed-block reader. The writer stores adaptive records as three
  little-endian `UInt64` values and appends one zero-row final mark for a
  non-empty Wide part.
- `default_compression_codec.txt` describes the table default and can disagree
  with a column's physical block codec. Physical method bytes, not that file,
  govern decoder dispatch.

## Admitted surface

- Decode ClickHouse compressed-block methods `0x82` (LZ4) and `0x90` (ZSTD)
  behind one bounded dispatcher.
- Decompress a `.cmrk2` file consisting of one or more valid ClickHouse
  compressed blocks, then parse the exact same adaptive `24`-byte mark records
  admitted for plain `.mrk2`.
- Open original-name or SipHash128-named `.bin` plus `.cmrk2` stream pairs.
- Read a one-column exact `UInt64` public fixture whose physical data blocks
  use ZSTD in full and by mark range.
- Preserve the verified `UInt64 CODEC(LZ4)` plus plain `.mrk2` fixture.
- Surface corrupt or unsupported compressed marks and ZSTD payloads as typed
  CrystalClick errors without returning partial values.

## Rejected surface

- Full Tokenomics-part compatibility; its multi-column schema and composite
  codecs remain unsupported even after its compressed-mark layer is readable.
- ZSTD dictionaries, skippable frames, streaming APIs, compression, or codec
  parameter interpretation beyond the bytes already encoded by ClickHouse.
- Composite codecs such as Delta, Gorilla, T64, DoubleDelta, or multiple codec
  chains.
- New scalar types, nullable/low-cardinality/collection serialization,
  multi-column query execution, filtering, aggregation, or SQL.
- Checksum verification for the outer ClickHouse `16`-byte block checksum.
- Pure-Crystal ZSTD and a dependency-free portability claim.

## Guard-only future

- Keep codec dispatch independent of Wide-part metadata so composite codecs can
  be layered later without duplicating compressed-block framing.
- Keep mark decompression independent of mark-record parsing so later
  `.cmrk3`/`.cmrk4` layouts remain rejected rather than guessed.
- Expose the native ZSTD dependency as a build/link boundary; a future bundled
  or dynamically loaded backend must preserve the same checked decoder
  contract.

## Design laws

1. A compressed file is accepted only when every byte belongs to a complete,
   bounded ClickHouse block and every decoded block has the declared size.
2. ZSTD library errors and output-size mismatches fail closed.
3. Decoded `.cmrk2` bytes must be non-empty and exactly divisible by the active
   mark-record size before records are parsed.
4. Existing mark monotonicity, alignment, row-count, and sentinel checks apply
   identically after decompression.
5. Adding `.cmrk2` must not make `.mrk3`, `.mrk4`, or unknown `.cmrk*`
   extensions admissible.
6. Correctness parity and corruption handling precede allocation or throughput
   optimization.
7. The aggregate decoded size of a multi-frame compressed-mark stream is
   bounded independently of each frame's size.
8. A valid final mark may name the last physical data frame rather than the
   physical EOF. In that form its local offset must equal the decoded frame
   length; only the special physical-EOF form uses local offset zero.
9. Selected `.bin` output is bounded by the exact byte count implied by the
   requested marks before any decoded slice is appended.

## Falsifier roster

- The new public fixture is not exactly one Wide `UInt64 CODEC(ZSTD)` stream
  with one `.cmrk2` and no plain mark file.
- A valid ZSTD data block or compressed-mark block fails to decode to the
  producer's exact values/mark range.
- Unknown compression method bytes pass the dispatcher.
- Truncated block headers or payloads, invalid compressed sizes, zero or
  oversized output declarations, ZSTD error results, and decoded-size
  mismatches are accepted.
- Trailing bytes after the final compressed block are silently ignored.
- Decoded mark bytes not divisible by `24`, invalid offsets, invalid sentinel,
  or `count.txt` mismatch are accepted.
- A trailing complete mark record, trailing complete compressed frame, or
  trailing partial compressed frame is ignored.
- The real non-EOF final sentinel fails either a whole read or a range of the
  last data mark.
- A non-EOF final sentinel stops before the decoded end of its last frame, or
  selected frame bytes exceed the exact requested row-byte count before the
  final equality check.
- The existing LZ4/plain-mark fixture regresses.
- The private Tokenomics part advances beyond the first still-rejected schema
  or composite-codec boundary without an explicit frontier widening.

## Stop rules

- Do not add another type or composite codec while any current falsifier is
  red.
- Do not claim Tokenomics compatibility from successful `.cmrk2` decoding.
- If the native ZSTD ABI is unavailable, fail the build/link explicitly; do
  not shell out to ClickHouse or another decompressor.
- If source inspection shows a different mark-record contract, revise this SDD
  and the fixture before production code.

## Implementation seal

- Slice: generic LZ4/ZSTD ClickHouse block decoding plus compressed adaptive
  `.cmrk2` for exact one-column Wide `UInt64`.
- Source/spec: new bounded compression component, `WidePart` integration,
  focused specs, deterministic fixture generator, and this SDD.
- Falsifiers: exact full/range differential plus malformed frames, compressed
  marks, and regression tests.
- Dependency boundary: native libzstd C ABI; no shard dependency and no
  process invocation.
- Boundary: fixture producer ClickHouse `26.7.1.1315`; outer checksum remains
  unverified. Header/payload/size corruption is in scope; a checksum-only
  mutation is an explicit non-guarantee and must remain observable in tests.
- Next local track: a Tokenomics-relevant composite numeric codec selected from
  observed schema/stream need, not broad multi-column support.

## Definition of done

```text
crystal spec
crystal tool format --check
scripts/generate_public_fixture.sh --check
scripts/generate_zstd_cmrk2_fixture.sh --check
```

Expected signal: exact `0..199999` values and selected mark ranges match the
pinned ClickHouse producer for both public fixtures; malformed ZSTD blocks and
compressed marks fail closed; the existing LZ4/plain-mark behavior remains
green.

## Verification record

- Debug and release Crystal suites each pass `32` examples, including exact
  `0..199999` full reads, bounded ranges, malformed framing/payloads, aggregate
  output limits, and both valid final-sentinel forms.
- Both fixture shape checks pass. Regenerating the ZSTD fixture with the pinned
  ClickHouse producer reproduced the same SHA-256 for all nine files.
- A privacy-safe local probe decoded all `60` ignored Tokenomics `.cmrk2`
  streams into `30240` bytes / `1260` adaptive records and validated monotonic
  offsets plus final sentinels. It did not read private `.bin` values; the
  complete multi-column part remains rejected at the schema boundary.
- Source lineage was checked against ClickHouse commit
  `066ea77cf4221959f9f8dc615f6ce776521b52ff`. A fresh Luna adversary review
  first found missing aggregate-data and logical-sentinel guards; both gained
  discriminating regression specs and the follow-up verdict is `ROBUST` within
  this bounded slice.
- This evidence becomes stale if the ClickHouse fixture producer, compressed
  block or adaptive-mark layouts, libzstd ABI, or supported-format frontier
  changes. Refresh by regenerating both fixtures and rerunning the declared
  Definition of Done plus the private marks-only probe.
