# Private Tokenomics fixture

This directory contains a local-only ClickHouse data part copied from the
Tokenomics Viewer database for reader compatibility tests.

- Database/table: `tokenomics.usage_events`
- Part: `all_2737_6088_472`
- Rows: `150414`
- Producer: ClickHouse `26.7.1.1315`, revision `54512`
- Part format: Wide, adaptive compressed marks (`.cmrk2`)
- Payload size at copy time: 9124 KiB
- Streams: 60 `.bin` files and 60 `.cmrk2` files

The table contains usage and cost metadata. It does not contain prompt or
response bodies or credentials, but it does contain personal metadata such as
local source paths, project names, event identifiers, model names, and costs.
The raw part is therefore ignored by Git and must not be published.

`usage_events/schema.sql` is a non-secret copy of the table schema. The raw
part is useful for metadata/checksum/marks tests and later compatibility tests
covering ZSTD, Delta, Gorilla, T64, LowCardinality, Nullable, and String
substreams. It is intentionally beyond the first primitive-reader milestone.
