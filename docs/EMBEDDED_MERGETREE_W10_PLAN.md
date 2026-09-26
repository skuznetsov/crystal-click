# W10 FixedString reader/writer plan

Status: verified within the stated pinned W10 scope. Contract:
`EMBEDDED_MERGETREE_FRONTIER.md`, W10.
Risk: CAUTION (new selected-column grammar, physical serialization, public
writer entry point). Rollback: one W10 feature commit after verification; before
commit, revert only W10-owned paths. Preserve existing W9 parts and APIs.

Factual anchor: W9 accepts exact primitive numerics, String, and their
Nullable forms; `FixedString(N)` currently fails typed selection. Local
ClickHouse `SerializationFixedString` writes `N` bytes per row in one stream.
The high-risk assumption is that this stream has the same adaptive mark and
serialization metadata shape as other bare fixed-width values in the pinned
26.7.1.1315 producer. The external oracle must test that assumption, not
merely a Crystal writer/reader round trip.

1. Add a focused failing reader spec for a pinned ClickHouse-generated
   `FixedString(N)` part and a failing writer spec for an explicit-width API.
   Distinguish short byte strings, exact width, trailing and embedded zeros,
   multi-byte text, mark boundaries, and malformed/zero/over-65,536 `N` or
   overwidth payload inputs.
2. Extend `WidePart`, `WidePartTable`, and `OfflineCatalog` typed selection for
   canonical plain `FixedString(N)` only. Treat values as exact byte strings;
   bound mark bytes before materialization and reject extra/missing streams.
3. Extend `WidePartWriter` with explicit width. Reuse stage, checksums, marks,
   self-read and exclusive publish; reject overwidth values and pad shorter
   ones with zero bytes without changing the `String` writer mapping.
4. Add a synthetic pinned ClickHouse differential oracle: stock-generated
   reader fixture plus Crystal-generated writer part, full/key-range hex
   comparison, `ATTACH PART`, `CHECK TABLE`, and corruption control. No private
   data fixtures. Inspect exact diff and classify the residual compatibility
   scope before commit.

DoD: focused reader/writer specs, full debug and release Crystal suites,
`crystal tool format --check`, shell syntax check, pinned differential oracle,
and `git diff --check` all pass. Expected oracle output names `FixedString(N)`
and every checked shape; corruption is detected. If the pinned binary or
filesystem prevents an independent oracle, keep status in progress and do
not claim ClickHouse-readable output.

Adversarial closure: the initial implementation omitted global serialization
metadata validation for FixedString and emitted no `serialization.json`; the
reader now rejects invalid global String enum values and the writer checksums
that file. Direct reads additionally cap returned value count at 65,536, with
an oversized-mark negative test. The external stock oracle covers `N=3` only.

Next distinct type slices: `Nullable(FixedString(N))`; date/time and Enum/IP
fixed-width semantic wrappers; UUID/Decimal widths and representations;
then LowCardinality and nested/JSON object structural streams.
