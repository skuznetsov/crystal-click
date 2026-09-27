# Stock Array(Array(UInt64)) Wide part

Generated from synthetic rows by
`scripts/generate_public_array_array_uint64_fixture.sh` using ClickHouse
26.7.1.1315 (official build) in a disposable local store. The table has
`pk UInt64`, `payload Array(Array(UInt64))`, `MergeTree ORDER BY pk`, forced
Wide parts, LZ4, two-row adaptive granules, and uncompressed marks.
`CHECK TABLE` returned `all_1_1_0 1` before capture. `SHA256SUMS` pins all
16 captured part files.

| pk | payload |
| --- | --- |
| 1 | `[]` |
| 2 | `[[], [0, UInt64::MAX], []]` |
| 4 | `[[42], []]` |
| 6 | `[]` |
| 9 | `[[], []]` |
| 11 | `[[1, 2, 3]]` |
| 13 | `[]` |

The stock substreams are `payload.size0`, `payload.size1`, and `payload`.
Their logical flattened contents are respectively `[0, 3, 2, 0, 2, 1, 0]`,
`[0, 2, 0, 1, 0, 0, 0, 3]`, and `[0, UInt64::MAX, 42, 1, 2, 3]`.
This captures one producer build and settings profile; it is not evidence
for arbitrary recursive array serializers or part formats.
