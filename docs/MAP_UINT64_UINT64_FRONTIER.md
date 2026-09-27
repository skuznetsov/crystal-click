# Map(UInt64, UInt64) Wide-Part Frontier

Document status: verified bounded W26 reader/writer implementation on the
pinned ClickHouse 26.7.1.1315 Wide/LZ4/plain-adaptive-mark frontier. This is
one exact Map type, not general Map or Nested support.

## Scope and existing anchor

W25 supports exactly `Map(UInt64, String)` as ordered entry arrays. Its
`size0`, key, String-length, and String-byte streams are independently marked;
the reader checks outer/nested count agreement and the writer validates a
staged part before exclusive publication. W26 seeks the next compositional
step: reuse the size/count and fixed-width stream checks for an exact
`Map(UInt64, UInt64)` payload beside one sorted `UInt64` key. Public values
remain `Array(Tuple(UInt64, UInt64))`, preserving duplicate keys and order.

Risk is CAUTION because accepting a wrong child stream or metadata shape can
silently pair keys with the wrong values, and writing it can persist an
incompatible part. The rollback boundary is one W26-only local feature commit;
no existing part or live ClickHouse directory may be mutated.

## Admission and rejection

Admit only the exact top-level spelling, the pinned Wide/LZ4/plain-adaptive
mark layout, bounded mark-range reads, typed batches, offline catalog-owned
values, and immutable two-column writes. A stock-produced physical probe must
fix the stream names, decoded values, marks, serialization metadata, and
checksums before implementation. The implementation should share existing
Map outer/count validation where that is behavior-preserving; it must not
silently treat `Map` as an arbitrary `Array(Tuple)` stream namespace.

The pinned local ClickHouse 26.7.1.1315 probe generated a Wide part from a
seven-row `MergeTree ORDER BY pk` table with two-row adaptive granules and
plain `.mrk2` marks. It has exactly three Map substreams: `m.size0`,
`m%2Ekeys`, and `m%2Evalues`. The first decodes to per-row entry counts
`[0, 2, 2, 1, 0, 2, 1]`; the child streams decode to flattened
little-endian UInt64 arrays: keys
`[3, 3, 0, UInt64::MAX, 42, 6, 1, 5]` and values
`[0, UInt64::MAX, 0, 42, UInt64::MAX, 8, 9, 5]`. There is no value-length
stream. All four column streams
(including `pk`) have five 24-byte mark records, the last a zero-row
sentinel. Size/key stream mark offsets are respectively
`[0, 16, 32, 48, 56]` and `[0, 16, 40, 56, 64]`; key and value child marks
agree. The observed `serialization.json` has `version: 1`, an empty
`columns` array, nested propagation enabled, and `string: 1` type version;
it does not carry a distinct Map version. The stock part passes `CHECK TABLE`.
These observations apply to the pinned producer and exact settings, not to
every ClickHouse part. The retained
`test/fixtures/stock_map_uint64_uint64_lz4/part` is a byte-for-byte copy
whose file tree is pinned by SHA-256 and compared with the original probe.

Reject implicit support for other key/value types, nested/nullable Map,
`Nested`, Compact parts, alternate serialization versions, or a general
recursive type parser. Guard-only: MV, projections, and performance changes.

## Falsifiers and acceptance gate

- A stock part must retain empty rows, duplicate and nonadjacent duplicate
  keys, zero and maximum UInt64 values, several granules, and a short final
  granule. A Crystal reader must reproduce the ordered entries on full and
  nonzero mark ranges and reject malformed outer/child counts and marks.
- A Crystal-produced part must pass pinned stock `ATTACH PART`, direct Map
  RowBinary equality for full and bounded key ranges, `mapKeys`/`mapValues`
  equality, and `CHECK TABLE`. Include both an all-empty Map part and an
  empty middle granule followed by nonempty entries, to test repeated child
  mark offsets. Self-readback alone does not establish compatibility.
- The bounded typed scan must preflight and account for both flattened
  UInt64 children (16 bytes per entry), not only the value stream. A focused
  RED test observed an 8-byte undercount before this correction.
- Full debug and release Crystal specs, prior pinned stock-oracle scripts,
  fixture/format checks, and `git diff --check` must pass. Expected signal:
  zero failures, byte-exact oracle comparisons, successful stock integrity
  check, and no unrelated diff.

The strongest adversary is a part accepted by our reader but rejected by
stock ClickHouse, or an accepted part whose flattened values are shifted
across rows despite matching total child counts. Probe child marks and
per-mark entry counts, not just aggregate lengths. Evidence decays with a
different stock build, serializer, codec/mark settings, platform, or shared
reader/writer change; repeat the oracle before widening the claim.

## Verification record and residual boundary

The exact-type recognition spec failed before W26 was implemented. A later
RED test exposed an aggregate preflight undercount: it reported eight bytes
per Map entry even though both flattened UInt64 children are materialized.
The corrected preflight and post-read accounting report 16 bytes per entry.
The focused specs additionally check a fully empty middle granule followed
by nonempty data, and reject malformed child marks. The pinned stock writer
oracle attaches mixed, all-empty, and middle-empty parts, compares exact
RowBinary results, and runs `CHECK TABLE`; direct mixed Map results and
`mapKeys`/`mapValues` agree for full and bounded key ranges.

At the W26 diff atop `e92c4d0`, `crystal spec --link-flags='-fuse-ld=ld'`
and its `--release` counterpart each passed 542 examples with no failures.
All 20 `scripts/check_*oracle.sh` scripts passed when invoked through Bash;
one pre-existing script lacks its executable bit, so direct shell execution
is not the supported suite invocation. The fixture verification script
confirmed SHA-256 for every captured file and byte-for-byte equality with
the original stock part. Crystal format, Bash syntax, and diff checks also
passed. This evidence is bounded to the exact producer build, schema,
settings, and tested values; it does not establish recursive Map, Compact
part, MV/projection, or performance compatibility.
