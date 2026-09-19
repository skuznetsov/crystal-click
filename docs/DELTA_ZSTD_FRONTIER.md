# Delta/ZSTD Multiple Frontier SDD

Document status: verified bounded slice

Current frontier: the next compatibility slice is one public ClickHouse Wide
part with one `UInt64` column declared as `CODEC(Delta(8), ZSTD(1))`. The data
stream uses a bounded ClickHouse `Multiple` block whose method list is exactly
`[0x92 Delta, 0x90 ZSTD]`; its adaptive marks are compressed as `.cmrk2`.
Full-column and mark-range reads are admitted. The existing direct LZ4 and
direct ZSTD paths remain admitted.

Bounded context: physical MergeTree compressed-block, codec-chain, and
adaptive-mark reading. This is not a claim of complete Tokenomics-part
compatibility, SQL compatibility, or checksum verification.

## Evidence and candidate selection

| Candidate | Metadata evidence allowed by the privacy boundary | Physical conclusion | Decision |
| --- | --- | --- | --- |
| Tokenomics `input` | A real scalar `UInt64` column declared with `CODEC(Delta(8), ZSTD(1))` in the private schema metadata | No private `.bin` bytes may be read, so its physical data method is unknown | Use this as the logical reason for a public reproduction; do not claim private compatibility |
| Tokenomics `line_no` and other regular `UInt64` usage columns | The same declared `Delta(8), ZSTD(1)` chain appears in the private schema metadata | The allowed `.cmrk2` structural probe establishes only compressed-mark framing, not the data codec | Not separate slices; one public scalar fixture is the smallest discriminating probe |

The private part has 38 columns and 60 `.bin`/`.cmrk2` stream-name pairs. Its
`default_compression_codec.txt` says `CODEC(LZ4)`, while the allowed
marks-only probe sees method `0x90` in every `.cmrk2` stream. That disagreement
is evidence that default metadata and physical method bytes answer different
questions. No private `.bin` value, header, checksum, hash, decompressed output,
or physical data codec is used here.

ClickHouse source lineage is pinned to commit
`066ea77cf4221959f9f8dc615f6ce776521b52ff`. That source defines method bytes
`0x91` (`Multiple`), `0x92` (`Delta`), and `0x90` (`ZSTD`), and defines the
`Multiple` payload as:

```text
outer codec block payload = method_count:u8 | method_bytes[method_count] | data
```

Codec methods are applied in listed order during compression and in reverse
order during decompression. Therefore the admitted physical chain is:

| Layer | Bytes / operation | Boundary rule |
| --- | --- | --- |
| Outer file frame | 16-byte ClickHouse checksum area, then 9-byte `0x91` header | Consume the checksum area but leave it unverified; require exact frame size |
| Multiple list | `count = 2`, then `[0x92, 0x90]` | Parse a bounded list; admit no other count, order, or method |
| Inner stage 1 | 9-byte `0x90` ZSTD codec header and payload | Decode first because stage order reverses |
| Inner stage 2 | 9-byte `0x92` Delta codec header and payload | Decode to raw UInt64 bytes; no nested 16-byte checksum exists |
| Delta payload | width byte `8`, canonical compatibility byte `0`, then little-endian UInt64 differences | Accumulate modulo `2^64`; output size must be a multiple of 8 |

The compatibility byte is ignored by ClickHouse's decoder, but its canonical
producer writes `source_size % 8`, which is zero for this aligned UInt64 slice.
Requiring zero is therefore an intentional canonical-producer restriction, not
a claim of accepting every byte sequence that ClickHouse's decoder tolerates.

The `ZSTD(1)` level is a producer declaration, not a level encoded in the
method byte. The reader can establish the physical `0x90` stage and the
Delta width byte, but must not pretend that a block method byte independently
proves the ZSTD level.

## Admitted surface

- One public Wide part, one exact `UInt64` column, and one data stream.
- Data blocks whose outer method is `0x91` and whose parsed Multiple list is
  exactly two methods, `[0x92, 0x90]`.
- Bounded parsing of the ClickHouse Multiple count/list format, with a finite
  method-list limit and no recursive Multiple stage.
- The 9-byte ClickHouse codec header on every nested stage. Nested stage data
  is not treated as a file frame and therefore has no invented nested checksum.
- Delta width `8` only, with ClickHouse-compatible little-endian UInt64
  differences and unsigned wraparound.
- Existing direct `0x82` LZ4 and `0x90` ZSTD data/mark blocks without changing
  their current behavior.
- Compressed adaptive `.cmrk2` marks through the existing bounded mark parser.
- Full reads and mark-range reads. A range beginning at a nonzero local mark
  offset decodes its complete physical frame first, then slices the reconstructed
  UInt64 bytes.
- Fail-closed frame, stage, output, mark, row-count, and range bounds.

## Rejected surface

- Any Multiple count other than two; any order other than `[0x92, 0x90]`;
  duplicate, missing, unknown, direct Delta, nested Multiple, or other stage
  methods.
- Delta widths `1`, `2`, or `4`, malformed width/skip headers, non-UInt64
  output, unaligned stage sizes, or a chain whose declared sizes do not consume
  exactly the available bytes.
- T64, Gorilla, DoubleDelta, GCD, FPC, encryption, dictionaries, skippable
  ZSTD frames, compression, or arbitrary codec-parameter interpretation.
- More than one column, any Tokenomics serialization (including Sparse,
  Nullable, LowCardinality, String, or Float64), compact parts, or SQL/query
  execution.
- Checksum verification. The outer 16-byte area is consumed but deliberately
  untrusted; nested codec stages have no checksum area to verify.
- Reading, publishing, or claiming compatibility for private Tokenomics `.bin`
  data. Metadata-only declarations do not promote a private physical codec
  claim.

## Guard-only future

- Keep the Multiple parser generic over a bounded method list so a later,
  separately admitted chain does not require rewriting outer framing. Runtime
  admission in this slice remains the exact two-method list above.
- Keep nested-stage framing separate from outer file framing. This preserves the
  distinction between ClickHouse codec headers and the outer checksum wrapper.
- Keep codec dispatch independent from `WidePart` metadata. Metadata can select
  a candidate, but physical method bytes and stage headers govern decoding.
- Keep the Delta accumulator and ZSTD decoder behind checked size limits so a
  later type/codec slice cannot bypass the current aggregate guards.

## Design laws

1. A file frame is accepted only when its outer header, declared compressed
   size, and physical end agree exactly.
2. A Multiple payload is accepted only after its count and method bytes fit the
   payload. The count is bounded before allocation, and the admitted list is
   exactly `[0x92, 0x90]`.
3. Nested stages are codec blocks with 9-byte headers. A nested stage is not a
   25-byte outer frame and does not contain a nested 16-byte checksum.
4. Stages are decoded in reverse list order, and every stage's declared size
   must match the stage buffer consumed by that step; trailing stage bytes are
   not ignored.
5. Delta width `8` reconstructs unsigned UInt64 values with modulo-`2^64`
   accumulation. A legitimate wraparound is data, not corruption.
6. A frame is reconstructed from its beginning before a nonzero local mark
   offset is applied. No range path may begin Delta decoding from the middle of
   a difference stream.
7. Per-frame and aggregate compressed/decompressed/output limits are checked
   before allocation or append. No partial values are returned after a failed
   limit, truncation, trailing-byte, or size check.
8. Existing direct LZ4/ZSTD full and range reads remain behaviorally unchanged.
9. The outer checksum remains explicitly unverified; a checksum-only mutation
   is observable only as the documented non-guarantee, not as successful
   integrity validation.

## Falsifier roster and RED fixture requirements

The first implementation must begin with a public fixture and RED specs. The
fixture must be generated by the pinned ClickHouse producer with one Wide
`UInt64` column, a column DDL declaring `CODEC(Delta(8), ZSTD(1))`, compressed
`.cmrk2` marks, multiple data frames, and deterministic values that include
constant/repeated values, a nonmonotone transition, and an explicit
`UInt64::MAX -> 0` wraparound. Its marks must include at least one nonzero
local decompressed offset inside a data frame. No private file is copied.

| Falsifier | Required result |
| --- | --- |
| Valid nested headers with no nested checksum | The exact fixture decodes; inserting or requiring a 16-byte checksum between nested stages fails as a stage-size/trailing/header error |
| Multiple method list | Count `1`, count `3`, count overflow, reversed `[0x90,0x92]`, duplicate/missing methods, unknown methods, and nested `0x91` all fail closed |
| Order and stage headers | A valid outer `0x91` with a wrong inner method byte, absent 9-byte stage header, or stage order mismatch never returns a plausible prefix |
| Truncation/trailing/size mismatch | Truncated outer/list/stage headers, truncated payloads, trailing outer bytes, trailing stage bytes, compressed-size mismatch, and decompressed-size mismatch all fail closed |
| Delta width/alignment | Width `1/2/4`, invalid width, nonzero incompatible skip, and non-8-byte declared output all fail before values are returned |
| UInt64 wraparound | A fixture transition across `2^64-1 -> 0` round-trips exactly; checked arithmetic must not reject valid modulo accumulation |
| Nonzero mark local offsets | Full and selected ranges beginning/ending inside a composite frame match producer values; decoding only the selected delta suffix is a RED failure |
| Aggregate limits | Per-frame and aggregate decoded/output limits reject oversized streams and cannot be bypassed with many small frames or stage expansions |
| Existing paths | The committed plain `.mrk2` + LZ4 fixture and compressed `.cmrk2` + direct ZSTD fixture retain exact full/range behavior |
| Checksum boundary | Mutating only the outer checksum does not become checksum verification; `checksum_verification` stays explicitly unverified |
| Privacy boundary | No test or generator reads private Tokenomics `.bin` files or emits private values; successful public reads do not change the Tokenomics compatibility claim |

## Stop rules

- Do not admit another type, Delta width, chain, or codec while one listed
  falsifier is red.
- Do not infer the private data codec from `default_compression_codec.txt`,
  private marks, filenames, or schema declarations alone.
- Do not claim the private Tokenomics part is compatible until a separately
  authorized slice establishes its multi-column and physical-stream behavior.
- Do not add checksum verification, SQL, or performance work to this slice.
- If ClickHouse source or the public fixture shows a different Multiple or
  nested-header contract, stop and revise this SDD before implementation.

## Implementation seal

- Slice: one public Wide UInt64 data stream with exact Multiple
  `[0x92 Delta(8), 0x90 ZSTD]`, compressed `.cmrk2`, full/range reads.
- Source/spec paths: the existing compressed-block and Wide-part readers, a
  bounded Multiple/Delta decoder surface, focused specs, and a deterministic
  public fixture generator. The current design task edits only this SDD and
  its companion plan.
- Dependency boundary: existing native libzstd ABI; no process invocation and
  no new dependency.
- Integrity boundary: outer checksum bytes are consumed but not verified;
  nested stage payloads have no checksum wrapper.
- Rollback: revert the owned implementation paths and these two
  design documents; preserve the already committed LZ4/ZSTD slice and the
  ignored private fixture.
- Status gate: this document is verified only for the canonical public slice;
  the rejected surfaces and private-data boundary remain unchanged.

## Definition of done

```text
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
CRYSTAL_CACHE_DIR=/private/tmp/crystal_click_delta_zstd_gate \
crystal spec --error-trace

SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
CRYSTAL_CACHE_DIR=/private/tmp/crystal_click_delta_zstd_release \
crystal spec --release --error-trace

crystal tool format --check
scripts/generate_public_fixture.sh --check
scripts/generate_zstd_cmrk2_fixture.sh --check
scripts/generate_delta_zstd_fixture.sh --check
git diff --check
```

Expected signal: the public producer fixture's exact full values and selected
mark ranges match, all chain/framing/size/limit falsifiers fail closed, the
wraparound and nonzero-local-offset cases pass, and the two committed direct
LZ4/ZSTD slices remain green. No private `.bin` is read by the gate.

## Verification record

- Debug and release suites each pass `41` examples, including all `4096`
  producer values, modulo-UInt64 wraparound, ranges starting and ending at
  nonzero local offsets, malformed lists/stages/Delta payloads, and bounds.
- All three public fixture shape checks pass; the new fixture contains eight
  outer `0x91` data frames with exact method list `[0x92, 0x90]` and two direct
  ZSTD `.cmrk2` frames.
- Formatter and `git diff --check` pass. The outer checksum remains explicitly
  unverified, and no private Tokenomics `.bin` was read by this slice.
- A fresh Luna adversary compared the implementation with the pinned
  ClickHouse source and returned `ROBUST` within the canonical public scope.
  It confirmed whole-frame reconstruction before mark slicing and identified
  the zero compatibility byte as an intentional strictness, not a blocker.
- Evidence becomes stale if the fixture producer, ClickHouse Multiple/Delta
  layout, libzstd ABI, or supported-format frontier changes. Refresh by
  regenerating the public fixture and rerunning the declared gate.

## Blocker and refresh boundary

There is no blocker to designing or implementing the public slice. There is a
deliberate blocker to a private Tokenomics physical-codec claim: establishing
the method/list and Delta payload in a private `.bin` would cross the stated
privacy boundary. The narrowest safe next probe is the public fixture above,
whose DDL and physical method-list bytes can be checked independently. Refresh
this SDD if the ClickHouse producer revision, Multiple layout, nested codec
headers, adaptive marks, native ZSTD ABI, or admitted compatibility frontier
changes.
