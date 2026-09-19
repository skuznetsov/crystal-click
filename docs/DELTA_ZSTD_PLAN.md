# Delta/ZSTD Multiple Slice Plan

Status: completed and verified on 2026-09-19.

Goal: add the smallest Tokenomics-relevant compatibility slice selected from
metadata without reading private data: one public Wide `UInt64` stream declared
as `CODEC(Delta(8), ZSTD(1))`, with compressed `.cmrk2` marks, exact full/range
reads, and a bounded ClickHouse Multiple parser for physical method list
`[0x92, 0x90]`. Preserve the committed direct LZ4 and direct ZSTD paths.

The implementation stayed within the source, spec, script, public-fixture, and
documentation paths named below.

## Risk, rollback, and pre-mortem

- Risk: CAUTION. This widens an on-disk compatibility boundary and introduces
  stateful Delta reconstruction inside a compressed-frame/range reader.
- Rollback: revert the owned implementation paths listed
  below and these two documents. Do not touch the committed LZ4/ZSTD code or
  the ignored private Tokenomics fixture.
- Likeliest failure: the reader slices a nonzero mark offset before rebuilding
  the Delta accumulator, returning a plausible but wrong suffix. The guard is
  a producer differential fixture with a nonzero local offset and a
  `UInt64::MAX -> 0` transition.
- Secondary failure: a parser treats nested codec headers as outer frames or
  invents nested checksums. The guard is a valid no-nested-checksum fixture plus
  mutation cases for inserted/trailing checksum bytes and stage-size mismatch.

## Evidence and source contract

- Private metadata makes `input UInt64 CODEC(Delta(8), ZSTD(1))` a real scalar
  candidate, but private `.bin` bytes and values are out of scope. The private
  `default_compression_codec.txt` (`CODEC(LZ4)`) and marks-only method `0x90`
  cannot establish the data method.
- ClickHouse source lineage is
  `066ea77cf4221959f9f8dc615f6ce776521b52ff`.
- The physical contract to reproduce is an outer method `0x91` block with a
  payload `count=2 | 0x92 | 0x90 | data`. Compression applies the listed
  codecs in order; decoding applies ZSTD, then Delta.
- Outer file blocks have a 16-byte checksum area followed by a 9-byte codec
  header. Each nested Multiple stage has only the 9-byte codec header. The
  checksum area is never verified.
- Delta width `8` reconstructs little-endian UInt64 differences with modulo
  `2^64` accumulation. The `ZSTD(1)` level is a DDL/producer declaration, not
  something that can be inferred from method byte `0x90` alone.

## Consumer inventory

Run before implementation:

```text
rg -n "CompressedBlock|decode_frame|decode_all|METHOD_|\.cmrk2|read_uint64_mark_range|FRAME_HEADER_SIZE" \
  src spec scripts docs test/fixtures/public --glob '!**/*.bin' \
  --glob '!**/*.mrk2' --glob '!**/*.cmrk2'
```

Current consumers are `CompressedBlock` for physical framing and compressed
marks, `WidePart` for stream discovery/mark ranges, the compressed-block and
Wide-part specs, and the two existing fixture generators. There is no external
compressed-frame API. The integration must keep direct `0x82`/`0x90` dispatch
and `.mrk2`/`.cmrk2` mark behavior intact.

## Owned implementation paths

- `src/crystal_click/compressed_block.cr` and, if separation reduces risk,
  `src/crystal_click/multiple_codec.cr` / `src/crystal_click/delta.cr`
- `src/crystal_click/wide_part.cr`
- `spec/compressed_block_spec.cr`, `spec/wide_part_spec.cr`, and a focused
  `spec/delta_zstd_spec.cr`
- `scripts/generate_delta_zstd_fixture.sh`
- `test/fixtures/public/wide_u64_delta_zstd/part/`
- `docs/DELTA_ZSTD_FRONTIER.md` and `docs/DELTA_ZSTD_PLAN.md`

## Ordered steps

1. **Freeze the public RED fixture.** Add a generator using the pinned
   ClickHouse `26.7.1.1315` producer (revision `54512`) and a Wide table with
   one `UInt64` column whose DDL explicitly says
   `CODEC(Delta(8), ZSTD(1))`. Force multiple compressed data frames, adaptive
   granularity, and `compress_marks = 1`; use a deterministic marks codec
   already supported by the direct ZSTD path. Generate values containing
   repeated/constant runs, a nonmonotone step, and `UInt64::MAX -> 0`.
   Shape-check one `.bin`, one `.cmrk2`, exact metadata, the outer method/list
   bytes for every data frame, Delta width `8` in every Delta stage, and at
   least one nonzero local mark offset. Do not copy any private file.

2. **Write RED specs before decoder changes.** Add valid full/range expectations
   and malformed copies for the following: nested 9-byte headers with no
   nested checksum; list count/order/duplicate/missing/unknown methods;
   truncation, trailing bytes, and compressed/decompressed size mismatch;
   Delta width/skip/alignment errors; UInt64 wraparound; nonzero local mark
   offsets; and per-frame/aggregate limits. Keep existing direct LZ4/ZSTD
   regression specs in the same run.

   Expected RED signal before production changes: the valid public fixture is
   rejected at the unsupported `0x91` Multiple boundary, while the current
   direct fixtures remain green.

3. **Implement bounded Multiple parsing.** Extend the compressed-block surface
   to recognize outer method `0x91`, parse a count byte and bounded method list,
   and reject a count beyond a small fixed cap before allocation. Admit only
   count `2` with bytes `[0x92, 0x90]`; reject recursion, alternative order,
   and all other methods. For each reverse-decoded stage, require a complete
   9-byte codec header, a declared compressed size equal to the stage buffer,
   a bounded decompressed size, and no trailing bytes. Keep the outer 16-byte
   checksum area consumed but unverified.

4. **Implement Delta width 8.** Decode the inner `0x92` block only after the
   `0x90` stage has produced it. Require Delta width `8`, an UInt64-aligned
   declared output, little-endian differences, and exact stage consumption.
   Accumulate with explicit modulo-`2^64` arithmetic. Apply the existing
   per-frame and aggregate output limits to intermediate and final buffers.

5. **Integrate full/range reads.** Keep `WidePart` stream discovery and mark
   parsing unchanged except for admitting data frames with outer `0x91`. For a
   range whose start or end mark has a nonzero local offset, decode the entire
   containing composite frame first, then slice raw UInt64 bytes and enforce
   the exact requested byte count. Preserve the existing direct LZ4/ZSTD and
   plain/compressed mark paths.

6. **Run the adversary and close only at the supported claim level.** Exercise
   all SDD falsifiers, regenerate the fixture, run the full suite and formatter,
   and run a marks-only private probe if needed. A passing public fixture proves
   only the public slice. It does not promote private Tokenomics compatibility,
   physical private `.bin` codec identity, ZSTD level identity, or checksum
   verification.

## Falsifier matrix

| Probe | Expected signal | Claim protected |
| --- | --- | --- |
| Valid `[0x92,0x90]` with nested headers and no nested checksum | Full and ranges match producer | Correct stage framing/order |
| Count `0/1/3`, over-cap count, reversed/duplicate/missing/unknown list, nested `0x91` | Typed fail-closed error, no partial values | Exact method list/order/count |
| Inserted 16-byte nested checksum or omitted 9-byte stage header | Typed stage-size/header/trailing error | No invented nested checksum |
| Outer/list/stage truncation; trailing outer or stage bytes; compressed/decompressed size mismatch | Typed fail-closed error | Exact consumption and size checks |
| Delta width `1/2/4`, invalid width/skip, non-8-byte output | Typed fail-closed error | UInt64-only Delta width 8 |
| Max-to-zero UInt64 transition | Exact wraparound values | Modulo accumulator semantics |
| Mark starts/ends inside a composite frame at nonzero local offsets | Exact full/range result | Decode-from-frame-start before slicing |
| Many small frames or large intermediate stage | Aggregate/per-frame limit error | Allocation/output bounds |
| Existing LZ4/plain `.mrk2` and direct ZSTD/`.cmrk2` fixtures | No regression | Preservation requirement |
| Checksum-only mutation | Still explicitly unverified; no checksum claim | Integrity boundary |
| Private `.bin` access attempt | Not part of generator, specs, or gate | Privacy boundary |

## Definition of done

```text
CRYSTAL_CACHE_DIR=/private/tmp/crystal_click_delta_zstd_gate \
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
crystal spec --error-trace

crystal tool format --check
scripts/generate_public_fixture.sh --check
scripts/generate_zstd_cmrk2_fixture.sh --check
scripts/generate_delta_zstd_fixture.sh --check
git diff --check
```

Expected signal: exact public full/range values, exact physical chain shape,
green direct-fixture regressions, typed rejection of every malformed/limit
case, and no private `.bin` reads. The frontier SDD is promoted only to the
narrower claim supported by that evidence and the adversary review.

## Stop and recovery rules

- Stop at the first failing falsifier; do not add another codec, width, type,
  or Tokenomics column to make the fixture pass.
- If the producer does not emit the documented Multiple layout, preserve the
  RED fixture and revise the SDD before changing source.
- If native libzstd is unavailable, report the dependency blocker; do not shell
  out to ClickHouse or silently replace ZSTD semantics.
- If a later refresh is partial, downgrade the status to in progress and do
  not preserve the verified claim.
