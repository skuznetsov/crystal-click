# Multi-column UInt64 Wide-part Slice Plan

Status: implemented and verified for the admitted public slice.

## Goal and scope

Deliver the smallest public compatibility slice for selecting the second
`UInt64` column from a multi-column ClickHouse Wide part. Keep the existing
one-column API behavior, parse unsupported neighbor metadata structurally, and
open only the selected physical stream. The slice is limited to exact
`UInt64`, one physical substream, and the producer-pinned
`Multiple[Delta(8), ZSTD(1)]` data path.

This plan does not admit general type/serialization decoding, checksum
verification, compact parts, or private Tokenomics compatibility.

## Current implementation

The implementation is in `src/crystal_click/wide_part.cr`:

- `WidePart.open(path, column)` is available alongside the legacy overload;
- `columns.txt` and `columns_substreams.txt` are bounded, exact-EOF parsed;
- neighbor type and physical-substream text is consumed opaquely;
- the selected type is exact `UInt64` and the selected physical stream is one
  stream named after the selected column;
- target resolution probes the original and SipHash128 names and rejects
  ambiguity or partial pairs;
- selected physical names are restricted to one flat filename component and
  selected data/mark symlinks fail closed before any read;
- unrelated neighbor payloads and mark extensions are ignored;
- existing LZ4/ZSTD frame, Delta, and plain/compressed mark readers are reused.

The implementation intentionally retains a target-only unsupported-mark-
extension guard. It is not a global scan of unrelated neighbor files.

## Public artifact and test surface

The producer and public fixture are now named:

```text
scripts/generate_multicolumn_input_fixture.sh
test/fixtures/public/wide_multi_input_delta_zstd/part/
spec/multicolumn_wide_part_spec.cr
```

The producer is pinned to ClickHouse local `26.7.1.1315 (official build)` and
creates `prefix String`, `input UInt64 CODEC(Delta(8), ZSTD(1))`, and
`suffix Array(Nullable(String))` in that order. Its shape gate checks 4096
rows, 16 marks, eight target data frames, compressed target marks, exact
`[0x92, 0x90]` target methods, Delta width 8, and all neighbor substream
counts.

The focused spec covers:

- full and mark-range reads of the selected second column;
- exact physical-name fallback and hash-name selection;
- legacy `open(path)` rejection for multi-column parts;
- default-codec syntax/size guards;
- poisoned, missing, and unsupported-extension neighbors;
- escaped neighbor identifiers;
- malformed, trailing, duplicate, reordered, or count-inconsistent metadata;
- wrong selected type and multiple selected substreams;
- complete exact/hash ambiguity and complete-plus-partial alternates;
- path-like selected stream names and selected target symlinks.

## Verification gate

The focused spec, complete Crystal suite, all public fixture shape checks,
formatting, generator shell syntax, and repository diff check were run on the
final source state:

```text
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
CRYSTAL_CACHE_DIR=/private/tmp/crystal_click_multicolumn_gate \
crystal spec --error-trace

crystal spec spec/multicolumn_wide_part_spec.cr --error-trace
crystal tool format --check
scripts/generate_public_fixture.sh --check
scripts/generate_zstd_cmrk2_fixture.sh --check
scripts/generate_delta_zstd_fixture.sh --check
scripts/generate_multicolumn_input_fixture.sh --check
git diff --check
```

Observed signals were 14/14 focused examples, 55/55 full debug examples, and
55/55 full release examples. All four public fixture shape checks passed. A
fresh Luna adversarial review returned `ROBUST` with no closure blocker.

This evidence proves only the bounded public slice. It does not prove private
physical codec identity, private values, ZSTD-level identity in a private
payload, checksum validity, or general Tokenomics-part compatibility.

## Optional private integration gate

Only under explicit authorization, a local-only gate may read the selected
private Tokenomics `input` pair. It must not read any other private payload and
must not emit or commit private values, aggregates, hashes/digests, or
diagnostics. The only permitted durable result is `matched` or `not matched`;
no private result, payload, or diagnostic is committed to the repository.
There is no committed private fixture or private-gate output in this slice.
The gate decays whenever the private part changes and must then be rerun or
invalidated.

## Adversary checks and stop conditions

Before closure, attack the highest-risk assumptions:

1. A poisoned or missing neighbor must not affect a target read. If it does,
   narrow resolution before changing codecs or metadata policy.
2. A complete exact/hash pair or a complete pair plus a partial alternate must
   reject; never prefer a filename by order.
3. A target wrong type or multiple target substreams must reject even when
   neighbor metadata is valid.
4. Metadata with extra bytes, missing LF, duplicate names, reordered blocks,
   or malformed escapes must reject before stream opening.
5. A path-like selected physical name or selected data/mark symlink must reject
   before target reading.
6. A changed producer version or target method layout invalidates the fixture
   assumption; update the frontier before changing the reader.
7. If the private gate needs anything beyond the selected `input` pair, stop
   and report the privacy boundary rather than widening access.

Residual boundaries remain explicit: exact UInt64/one physical substream only;
neighbor types/substreams are structurally parsed but payloads are ignored;
outer checksums are unverified; general complex-type selection is not admitted;
decoded buffers are bounded but potentially large; selected target symlinks
fail closed without claiming complete metadata-path or part-directory symlink
isolation; `count.txt` tolerates one trailing LF; the producer version is
pinned; and private-gate evidence decays when the private part changes.

## Rollback and ownership

The coherent implementation change consists of the source/spec/generator/public
fixture plus these two docs. Rollback is by reverting that coherent change;
do not overwrite unrelated working-tree changes. These docs own only the
frontier and plan; they do not authorize private data access or additional
type/serialization support.
