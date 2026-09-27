# Stock Map(UInt64, UInt64) Wide part

Captured from local ClickHouse 26.7.1.1315 (official build), using a
`MergeTree ORDER BY pk` table with `pk UInt64, m Map(UInt64, UInt64)`, LZ4,
Wide parts, two-row adaptive granules, uncompressed marks, and 4096-byte
maximum compression blocks. The table's `CHECK TABLE` returned
`all_1_1_0 1` before capture.

Rows in key order:

| pk | Ordered Map entries |
| --- | --- |
| 0 | [] |
| 2 | [(3, 0), (3, UInt64::MAX)] |
| 4 | [(0, 0), (UInt64::MAX, 42)] |
| 6 | [(42, UInt64::MAX)] |
| 9 | [] |
| 11 | [(6, 8), (1, 9)] |
| 13 | [(5, 5)] |

The stock part was copied byte-for-byte from a local `all_1_1_0` part; its
original filesystem path is not a durable input. SHA256SUMS pins every
captured file. This fixture covers one producer build and settings profile,
not all ClickHouse Map serializations.
