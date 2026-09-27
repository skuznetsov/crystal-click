# Map(UInt64, String) Wide-Part Frontier

Document status: verified W25 bounded implementation on the pinned
ClickHouse 26.7.1.1315 Wide/LZ4/plain-adaptive-mark frontier. This is one
exact Map type, not general Map or Nested support.

## Factual anchor and admitted surface

The stock probe used a `Map(UInt64, String)` column with empty, singleton,
multi-entry, duplicate-key, empty-string, NUL-byte, and UTF-8 values. It
returned duplicate keys in insertion order. The active stock part was Wide,
contained seven rows, and passed `CHECK TABLE`. Decoded streams were:

| Logical stream | Decoded content |
| --- | --- |
| `m.size0` | One little-endian UInt64 entry count per row. |
| `m%2Ekeys` | Flattened little-endian UInt64 keys. |
| `m%2Evalues.size` | One little-endian UInt64 byte length per flattened String. |
| `m%2Evalues` | Concatenated String bytes. |

The source `ColumnArray` offsets are cumulative in memory, but this stock
MergeTree part uses position-independent encoding: `SerializationArray.cpp`
serializes each current-minus-previous offset as one row's size. The
observed on-disk `m.size0` values are `[0, 3, 2, 1, 0, 2, 1]`, not cumulative
offsets. This source/fixture distinction is a required reader and writer
falsifier.

The spelling is intentional: `m%2Ekeys` and `m%2Evalues` are Map substream
names, not `Array(Tuple)` names. The stock part's metadata reports the
ordinary default serialization, `CODEC(LZ4)`, and String serialization
version 1. The project targets independent plain adaptive `.mrk2` streams
and hashed Wide filenames. Each stock `.mrk2` stream has data-granule row
counts `[2, 2, 2, 1]` and a zero-row sentinel. Mark records are triples of
compressed-file offset, decompressed-stream offset, and row count, each a
little-endian UInt64. The outer-size offsets are `[0, 16, 32, 48, 56]`,
the flattened-key and value-length offsets are `[0, 24, 48, 64, 72]`, and
the String-byte offsets are `[0, 16, 29, 37, 40]`. This stock fixture puts
all compressed offsets at zero; that is not an invariant of arbitrary parts.
The Map streams' decoded bytes match the corresponding `Array(Tuple)`
streams in this fixture, but their logical names differ.

W25 admits only one `UInt64` sorting key and one exact top-level
`Map(UInt64, String)` payload, with sorted key rows and configurable positive
rows per mark. The public Crystal row value should be an ordered
`Array(Tuple(UInt64, String))`, not a `Hash`: duplicate keys and entry order
are observable ClickHouse behavior. The reader, typed batch, offline catalog
materialization, and writer must agree on that representation.

## Falsifiers and Definition of Done

The initial failing tests proved that the exact type was unavailable before
implementation. The acceptance gate required a stock-generated fixture read
with exact row values, order, duplicates, and binary String bytes; a
Crystal-generated part passing pinned ClickHouse `ATTACH PART`, exact full
and bounded-range reads, and `CHECK TABLE`; and physical metadata, decoded
stream-byte, mark, and checksum checks. The tests cover empty streams, a
short final granule, malformed metadata/marks, and per-mark entry and
String-byte limits. Self-readback alone is not a compatibility oracle.

The strongest counterexample is a part that our reader accepts but stock
ClickHouse rejects or interprets differently because a child stream mark,
name, metadata entry, or checksum is wrong. The writer must validate staged
files and refuse invalid input before exclusive publication. The reader must
reject incompatible shapes before exposing partial values.

The hostile reader pass also found a path-confinement defect in common
metadata loading: a copied stock part with `columns.txt` symlinked outside
the part was accepted. A RED regression test established the defect, then
explicit symlink checks were added for columns, substreams, codec, and count
metadata. These checks assume part directories are not concurrently mutated;
they do not close a filesystem race against an adversarial writer.

Risk is CAUTION: the change crosses serialization and persistent format
boundaries. Rollback is one W25-only local commit, with no writes into an
existing server data root. Evidence expires when the ClickHouse producer
version, Map serialization, codec/mark settings, or relevant Crystal
reader/writer changes. General `Map`, `Nested`, recursive compositions,
Compact parts, MV, projections, and performance remain outside W25.
