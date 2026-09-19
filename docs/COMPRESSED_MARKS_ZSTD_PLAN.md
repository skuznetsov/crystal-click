# Compressed Marks and ZSTD Slice Plan

Status: completed and verified on 2026-09-19.

Plan:

- Risk: CAUTION. This widens an on-disk compatibility boundary and adds a
  native link dependency.
- Rollback: the clean `68f3f61` commit; remove only the owned paths below or
  revert the eventual feature commit. The ignored private fixture is not an
  owned path.
- Pre-mortem: the likeliest dangerous failure is accepting decoded bytes with
  a plausible length but the wrong block or mark boundary. The primary guard
  is exact producer differential plus trailing/truncation/size-mismatch
  falsifiers.

Owned paths:

- `docs/COMPRESSED_MARKS_ZSTD_FRONTIER.md`
- `docs/COMPRESSED_MARKS_ZSTD_PLAN.md`
- `docs/WIDE_PART_READER_FRONTIER.md`
- `scripts/generate_zstd_cmrk2_fixture.sh`
- `src/crystal_click.cr`
- `src/crystal_click/compressed_block.cr`
- `src/crystal_click/zstd.cr`
- `src/crystal_click/wide_part.cr`
- `spec/compressed_block_spec.cr`
- `spec/wide_part_spec.cr`
- `test/fixtures/public/wide_u64_zstd_cmrk2/part/`

Consumer inventory:

```text
rg -n "decode_frame|parse_marks|\\.mrk2|CODEC\\(LZ4\\)|LZ4\\.decode|FRAME_HEADER_SIZE" \
  src spec scripts docs test/fixtures/public --glob '!**/*.bin' --glob '!**/*.mrk2'
```

Observed consumers are private methods in `WidePart`, the existing Wide-part
spec, the LZ4 unit spec, the LZ4 fixture generator, and the two existing design
documents. There is no external public compressed-frame API to preserve.

## Steps

1. `scripts/generate_zstd_cmrk2_fixture.sh` and
   `test/fixtures/public/wide_u64_zstd_cmrk2/part/`
   - Generate with pinned ClickHouse `26.7.1.1315`, forced Wide layout,
     adaptive granularity, `compress_marks = 1`, and exact `UInt64` whose
     physical data blocks use ZSTD.
   - Verify one `.bin`, one `.cmrk2`, no plain mark file, row count, codec text,
     and method byte `0x90` for both streams.
   - Adversary: `--check` must reject a fixture whose extension, codec, method,
     or file counts differ.

2. `spec/wide_part_spec.cr` and `spec/compressed_block_spec.cr`
   - Add the first RED expectations for exact full/range reads and corrupt
     ZSTD/compressed-mark cases before production changes.
   - Expected RED signal: the current reader raises `UnsupportedFormatError`
     for the valid ZSTD/compressed-mark fixture.
   - Adversary: seed unknown method, truncation, decompressed-size mismatch,
     misaligned decoded mark bytes, trailing complete/partial frames, the real
     non-EOF sentinel, and a checksum-only non-guarantee.

3. `src/crystal_click/zstd.cr` and `src/crystal_click/compressed_block.cr`
   - Bind the minimal native libzstd decompression/error ABI.
   - Move checked ClickHouse block framing out of `WidePart`; dispatch only
     method `0x82` to the existing LZ4 decoder and `0x90` to ZSTD.
   - Pass only the `compressed_size - 9` payload beginning at physical offset
     `+25` to ZSTD; enforce both per-frame and aggregate decoded-size limits.
   - Consumers: Wide data-range reads and compressed-mark loading.
   - Verification: focused block specs, including exact output size and full
     compressed-file consumption.

4. `src/crystal_click/wide_part.cr` and `src/crystal_click.cr`
   - Admit known LZ4/ZSTD default-codec metadata and exact `.cmrk2` pairs, while
     treating each physical block method byte as authoritative.
   - Decompress the complete mark file before reusing the existing mark parser
     and validation laws; preserve `.mrk2` and LZ4 behavior.
   - Adversary: unknown/ambiguous mark pairs remain rejected; whole and
     last-mark-range reads preserve a real sentinel inside the last data frame;
     the ignored Tokenomics part still fails at its next explicit unsupported
     boundary.

5. Frontier/verification closure
   - Run focused specs, the full suite, formatter, both fixture checks, and the
     privacy-safe Tokenomics fail-closed probe.
   - Update the SDD from `design-sealed` only to the claim level supported by
     observed evidence and a fresh adversary review.

## Definition of done

```text
CRYSTAL_CACHE_DIR=/private/tmp/crystal_click_zstd_gate \
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
crystal spec --error-trace

crystal tool format --check
scripts/generate_public_fixture.sh --check
scripts/generate_zstd_cmrk2_fixture.sh --check
git diff --check
```

Expected signal: both producer fixtures return exact values and ranges; all
declared corruption cases raise typed errors; no regression in the first
slice; raw private Tokenomics data remains ignored and untracked.
