# Stock Array(Nullable(UInt64)) Wide part

Captured byte-for-byte from a disposable ClickHouse 26.7.1.1315 (official
build) `MergeTree ORDER BY pk` table with `pk UInt64` and
`payload Array(Nullable(UInt64))`. Settings pinned Wide parts, LZ4,
two-row adaptive granules, uncompressed marks, and a 4096-byte maximum
compression block. `CHECK TABLE` returned `all_1_1_0 1` before capture.

Rows in key order:

| pk | payload |
| --- | --- |
| 0 | `[]` |
| 2 | `[NULL, 0, UInt64::MAX]` |
| 4 | `[42, NULL]` |
| 6 | `[]` |
| 9 | `[NULL]` |
| 11 | `[1, 2]` |
| 13 | `[]` |

The stock part has `payload.size0`, `payload.null`, and `payload` streams.
The flattened null map is `[1, 0, 0, 0, 1, 1, 0, 0]`; the flattened
UInt64 slots are `[0, 0, UInt64::MAX, 42, 0, 0, 1, 2]`. The stock
`serialization.json` records a Default key serializer with one default row
(`pk=0`); this is statistics for serializer selection, not an omitted key
value. `SHA256SUMS` pins every part file. The original disposable path is
not a durable input. This is evidence for one producer build and settings
profile, not arbitrary Array/Nullable serializers.
