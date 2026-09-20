# Multi-column UInt64 Wide-part Frontier

Status: verified for the admitted public slice.

Current frontier: select one exact `UInt64` column from a local ClickHouse
Wide part while leaving unsupported neighbor columns unread. The implemented
slice preserves the existing one-column `WidePart.open(path)` behavior and adds
`WidePart.open(path, column)`. The public target is the scalar column named
`input`, with exactly one physical substream and data frames produced by the
`Multiple[Delta(8), ZSTD(1)]` chain.

This is a bounded reader slice, not a complete ClickHouse type or
serialization reader. It is not a claim that a private Tokenomics part is
physically compatible, and it does not verify outer ClickHouse checksums.

## Implemented API and selection rules

```crystal
WidePart.open(path : String) : WidePart
WidePart.open(path : String, column : String) : WidePart
```

`open(path)` continues to select the only column in a one-column part and
rejects a multi-column part unless a column is supplied. `open(path, "input")`
selects the named target. `read_uint64` and
`read_uint64_mark_range` remain scoped to the selected column; a different
per-call column is rejected.

The selected surface is deliberately narrow:

- the selected type text must be exactly `UInt64`;
- the selected column must have exactly one physical substream, named exactly
  as the selected column; the public fixture selects `input`;
- only the selected data/mark pair is opened;
- supported target marks are `.mrk2` and `.cmrk2`;
- both original and SipHash128 physical names are accepted, but ambiguity and
  partial pairs fail closed;
- the selected physical stream name must be one flat filename component, and
  selected data/mark symlinks fail closed before any read;
- `CODEC(LZ4)` and `CODEC(ZSTD(1))` remain the accepted default-codec metadata
  guards; default-codec text does not prove the selected data codec.

For a legacy one-column part, a missing `columns_substreams.txt` still falls
back to the column name. A multi-column part must provide
`columns_substreams.txt`; the reader never guesses a stream from directory
order.

## Metadata boundary

`columns.txt` is parsed to exact EOF with bounded counts, final-LF and line
checks, decoded backquoted identifiers, duplicate-name rejection, and opaque
neighbor type text. The selected decoded name must occur once with type text
exactly `UInt64`. Neighbor types are structurally consumed; no type or
serialization factory is invoked for them.

`columns_substreams.txt` is required for multi-column parts. Its count and
decoded column order must match `columns.txt`; duplicate/reordered/missing
blocks, malformed records, trailing bytes, duplicate physical names, and
invalid bounded names are rejected. Neighbor substream names are consumed as
opaque text only. The selected block must contain one physical stream equal to
the selected column name.

`count.txt`, metadata sizes, column/substream counts, and frame/mark sizes are
bounded. Metadata is parsed before any target stream is opened. A malformed,
truncated, count-mismatched, duplicate, reordered, or trailing metadata record
is an error rather than a best-effort read.

## Target-scoped physical resolution

For selected `input`, the resolver probes:

1. `input.bin` with `input.mrk2` or `input.cmrk2`;
2. `40e9692b249087848c5984b3e27b0514.bin` with its `.mrk2` or `.cmrk2`
   counterpart.

It accepts one complete pair only. It rejects both mark forms for one name,
two complete exact/hash candidates, a complete candidate plus a partial
alternate, and any data-only or mark-only candidate. Unsupported mark
extensions are checked only for these target names. Unrelated neighbor files,
including a neighbor `.mrk3`, are ignored and no neighbor data or marks are
opened.

The decoder accepts the admitted outer ClickHouse compression frame and the
target `Multiple` method list `[0x92 Delta, 0x90 ZSTD]`. Delta is limited to
width 8 and modulo-`2^64` accumulation. Mark parsing supports the existing
plain and compressed paths, including the public target's `.cmrk2` marks.

## Public producer fixture

The deterministic fixture is generated and shape-checked by:

```text
scripts/generate_multicolumn_input_fixture.sh --check
```

Its path is:

```text
test/fixtures/public/wide_multi_input_delta_zstd/part/
```

The pinned producer is ClickHouse local `26.7.1.1315 (official build)`. The
table shape and order are:

```sql
`prefix` String,
`input` UInt64 CODEC(Delta(8), ZSTD(1)),
`suffix` Array(Nullable(String))
```

The fixture has 4096 rows, 16 target marks at 256 rows each, eight target data
frames, compressed ZSTD marks, and hashed target files
`40e9692b249087848c5984b3e27b0514.{bin,cmrk2}`. Prefix has two physical
substreams and suffix has four. Shape checks assert the exact metadata, target
placement, target method list and Delta width, compressed mark framing, and
neighbor stream counts. They do not make the neighbor payloads part of the
reader contract.

The focused behavioral coverage is in
`spec/multicolumn_wide_part_spec.cr`. It exercises full and mark-range target
reads, exact-name fallback, explicit-column legacy behavior, default-codec
guards, escaped neighbor identifiers, malformed/trailing/duplicate/reordered
metadata, wrong selected type, multiple target substreams, poisoned or
missing neighbors, unsupported neighbor mark extensions, complete exact/hash
ambiguity, complete-plus-partial alternates, path-like selected stream names,
and selected target symlinks.

## Privacy boundary

The public fixture and repository tests contain no private Tokenomics payload.
Under explicit authorization, an optional local-only integration gate may read
only the selected private Tokenomics `input` pair. It may not read any other
private payload, and may not emit or commit private values, aggregates,
hashes/digests, or diagnostics. Its only permitted durable result is the
scalar `matched` or `not matched`; no private gate result is recorded in this
document or committed to the repository. The gate is stale and must be rerun
or invalidated if the private part changes.

## Admitted, rejected, and residual surface

### Admitted

- one-column `open(path)` compatibility;
- explicit selection with `open(path, "input")`;
- exact scalar `UInt64` with one physical `input` substream;
- opaque structural parsing of unsupported neighbor types and substreams;
- target original-name/SipHash resolution with fail-closed pair checks;
- flat selected physical names and fail-closed target symlink checks;
- direct LZ4/ZSTD and `.mrk2`/`.cmrk2` frame handling already in the reader;
- full and mark-range reads with existing bounds.

### Rejected

- implicit first-column selection for a multi-column part;
- selected types other than exact `UInt64`;
- selected columns with more than one physical substream;
- neighbor payload decoding or general serialization construction;
- directory-order or missing-stream guessing;
- malformed/truncated/duplicate/reordered/trailing metadata;
- ambiguous or partial target pairs;
- compact parts, SQL, checksum verification, and general complex-type
  selection;
- any private Tokenomics physical-compatibility claim from public evidence.

### Residual boundaries

- The selected frontier is exact `UInt64` and one physical substream only.
- Neighbor types and substreams are structurally parsed, but their payloads
  are ignored.
- The outer 16-byte ClickHouse frame checksum remains unverified;
  `checksum_verification` remains `Unverified`.
- Full decoded data and result buffers are bounded, but may still be large.
- Selected data/mark symlinks fail closed; this slice does not claim complete
  isolation from symlinks on fixed metadata paths or on the part directory.
- `count.txt` accepts the canonical integer with one trailing LF; columns and
  substreams metadata retain strict final-LF and exact-EOF checks.
- There is no general complex-type or serialization-derived target selection.
- The public producer version is pinned to ClickHouse `26.7.1.1315`.
- Any private local gate decays when the private part changes.

## Falsifier roster

| Probe | Required signal |
| --- | --- |
| Valid target in second column | Exact full and range values are returned |
| Exact-name-only or hash-name-only target pair | The selected target is readable |
| Corrupt, missing, or unsupported-extension neighbor | Target still reads; neighbor is not opened |
| Unknown/complex neighbor type or multiple neighbor substreams | Target still reads |
| Metadata count/order/duplicate/trailing/truncation mutation | Typed rejection |
| Malformed or escaped identifier mutation | Valid decoding works; malformed input rejects |
| Wrong selected type or target substream count | Typed rejection |
| Complete exact and hash pairs | Ambiguity rejection |
| Complete pair plus partial alternate | Corruption rejection |
| Path-like selected stream or target symlink | Rejection before target read |
| Invalid frame, method list, Delta width, or mark | Fail-closed rejection without a prefix |
| Existing one-column and direct LZ4/ZSTD fixtures | No regression |

## Verification and stop rules

The complete public gate was run on the final source state:

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
55/55 full release examples. Crystal formatting, all four public fixture shape
checks, generator shell syntax, and the repository diff check passed. A fresh
Luna adversarial review returned `ROBUST` for the admitted public slice, with
no closure blocker.

These checks prove only the declared public boundary. Stop if a neighbor
corruption probe opens a neighbor, if the producer version or physical method
list changes, or if the optional private gate needs any private input outside
the selected `input` pair. Revert the implementation/spec/fixture change and
these docs as one coherent change if rollback is required; do not widen the
frontier to complex serialization or private compatibility to satisfy a
probe.

## Local anchors

- `src/crystal_click/wide_part.cr:21-70` — public API and initialization;
- `src/crystal_click/wide_part.cr:73-185` — bounded metadata selection;
- `src/crystal_click/wide_part.cr:330-370` — target-scoped pair resolution;
- `src/crystal_click/compressed_block.cr:21-148` — frame, Multiple, Delta, and
  ZSTD decoding;
- `scripts/generate_multicolumn_input_fixture.sh` — producer and shape gate;
- `spec/multicolumn_wide_part_spec.cr` — focused falsifiers.
