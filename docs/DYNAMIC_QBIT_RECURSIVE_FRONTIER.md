# Recursive QBit in Dynamic storage frontier

## W233 — verified finite recursive Dynamic/QBit profiles

Baseline: clean `ae2e97f0f0c77a8b4c847b393eeb0697c1af2c47` (W232).
The overall objective remains all supported ClickHouse storage types and
MV/projection support before memory/performance work. This slice does not
redefine that objective or admit new physical versions.

### Problem and proposed surface

The existing descriptor, scalar and bulk visitors already reuse QBit leaf
serde recursively. Dynamic's value/roster policies nevertheless admit only a
direct QBit actual. Its QBit metadata preflight counts direct arms while role
generation recursively visits products. Removing the guard alone makes those
inventories disagree. A Dynamic leaf also needs a sparse occurrence axis,
possibly followed by Array/Map and Variant axes; equal plane lengths alone do
not establish that axis.

Admit legal static QBit-bearing actual trees through Array, Tuple, BASIC
Map, nominal Nested, and eligible Nullable(Tuple) or Variant below a legal
actual-type wrapper, at existing prepared Dynamic V3/BASIC sites. Immediate
Nullable, Variant and Dynamic alternatives remain rejected by the internal
Variant roster. Reuse ordinary arm bulk
storage and shared scalar envelopes, the staged writer and public consumers.
Use one recursive admission law and one path-keyed shape schedule, not a codec
for each product. Root Dynamic, an outer Array(Dynamic), empty containers,
unused arms and forced shared overflow require native persistence witnesses.

Existing rejection boundaries remain load-bearing: direct Variant or Dynamic
alternatives prohibited by the internal Variant roster, LC(QBit), unsupported
Nullable containers, Object/JSON typed-QBit policies, QBit aggregate arguments,
legacy Dynamic APIs, Compact/sparse/custom and unqualified layout versions.
Source-invalid types are not missing implementation targets. Mixed runtime
owners do not acquire admission merely from neutral descriptor acceptance.
Standalone Dynamic structure encoding transports declarations; contextual
value constructors and prepared bulk plans still own payload admission.

### Design laws and strongest failure

- Preserve exact nominal descriptors, dimensions, strides and canonical arm
  ordering. Tuple/Nullable preserve incoming occurrences; Array/Map sizes and
  Dynamic/Variant discriminators derive child occurrences.
- Metadata preflight and role construction enumerate the same QBit sites and
  plane roles, charging retained path/plane snapshots before allocating them.
  Non-QBit plans retain their prior admission and accounting.
- Ordinary-arm plane deltas must agree with the derived leaf occurrence count
  for every physical mark before publishing the reader or issuing an early/EOF
  callback. Inspect unique shape lanes once, parent-first, using the existing
  operation/inspection transport budget. Preflight retained count workspace.
- Shared overflow is a type-tagged scalar envelope, not a synthetic plane
  stream. Selected payloads retain existing strict child decoding and limits.
  Shape validation is not authentication of every unselected payload.
- Logical workspace and transport bounds are not an RSS/throughput claim.
- Raw audits check semantic consistency, not cryptographic process provenance.
  Helper provenance is the root-observed build command and selected source and
  executable hashes, not reproducible-build or all-transitive-input attestation.
  The fixed synthetic helper is trusted local test code, not a sandbox for an
  arbitrary caller-supplied executable.

The likeliest failure is using parent P or Dynamic-site Q as a nested leaf's
row count. An all-planes-consistent late mark with the wrong arm/element count,
while the first selected mark remains intact, is the strongest cheap guard.

### Execution and Definition of Done

Risk: CAUTION (serialization, runtime rosters and complete physical schedules).
Rollback: exact owned diff from the clean baseline; one atomic local commit
after DoD, no remote push. Root serializes all resource-guarded jobs; Luna owns
disjoint implementation surfaces and never runs jobs or Git operations.

1. `scripts/recheck_recursive_qbit_dynamic_w233.rb`: stock-only persistence probe
   at the separately pinned source/runtime. Expected: real Wide parts, exact
   CHECK success, independently authored full/middle/zero RowBinary, and
   ordinary-versus-shared roster witnesses. Constructor acceptance is weaker
   than persistence qualification. Stop/narrow if stock rejects a proposed
   shape; never relabel metadata or alter retained raw output into a pass.
2. Run new `spec/dynamic_qbit_recursive_kernel_w233_spec.cr`,
   `spec/dynamic_qbit_recursive_parts_w233_spec.cr`, and
   `spec/dynamic_qbit_recursive_transport_w233_spec.cr` on unchanged production.
   Expected RED: executed missing-capability assertions, not compiler errors.
3. Kernel ownership: shared actual-profile admission and the value/envelope
   gates in `binary_value.cr`, `binary_dynamic_envelope.cr`,
   `binary_value_codec.cr`; recursive site preflight in
   `binary_dynamic_bulk_plan.cr`. Physical ownership: a dedicated occurrence
   schedule and integration at `dynamic_bulk_site_reader.cr`. Existing leaf
   codec visitors remain unchanged unless an executed falsifier requires it.
4. Execute focused and affected DEBUG/RELEASE specs under `run_safe.sh` with
   `CRYSTAL_WORKERS=1`, `--single-module --threads 1
   --link-flags=-fuse-ld=ld --error-trace`; RELEASE adds `--release --no-debug`.
   Expected GREEN: nonzero examples, zero failures/errors/pending, including
   direct-QBit/non-QBit, owner/nominal/budget and public-consumer controls.
5. Paired native stock-to-library and library-to-stock witnesses must exercise
   public full/window/zero/EOF reads, staged publication/readback, direct native
   ATTACH/CHECK and literal RowBinary. Separately audit raw process results and
   inventories; attack the auditor with coherent CHECK/status forgery. Seed an
   omitted shape-schedule defect and require a behavioral failure followed by
   an exact restoration pass. Compare generated files across build modes.
6. Review final owned diff, source/helper hashes and evidence scope; update
   status/frontier/landmarks and a curated evidence packet before local commit.

### Evidence and continuation

Read-only inventory at the baseline establishes the direct-only admission and
metadata mismatch. It does not establish stock persistence, a reader bug, or
new capability; the stock and behavioral RED signals below authorize this
bounded implementation. Performance, broader types/layouts, MV/projection writing
and execution, and responsibility-level facade decomposition remain open.

The first stock SQL-CAST capture at
`/private/tmp/crystal-click-w233-stock.T7UnuJ` preserved the other proposed
actuals and passed CHECK, but persisted the Map actual as
`Map(String, Tuple(String, String, String, String, String, String, String, String))`.
Its exact-roster gate refused that result. This rejects that fixture ingestion
route, not Map/QBit storage compatibility. No metadata was relabelled.
A separate exact-descriptor RowBinary ingestion capture at
`/private/tmp/crystal-click-w233-stock.87OidV` then preserved
`Map(String, QBit(Int8, 9))` in ordinary and forced-shared Dynamic fields;
CHECK and independently authored output literals passed in nine raw processes.
The six-row exact-descriptor combined capture at
`/private/tmp/crystal-click-w233-stock.T54Wve` passed in thirteen raw processes:
four exact recursive actuals in ordinary arms, forced shared overflow and an
outer Array(Dynamic), one six-row Wide part, CHECK, and independently authored
full/middle/zero RowBinary literals. The separately retained SQL-CAST probe is
diagnostic only; it does not replace the exact-descriptor fixture.

The unchanged-production parts probe executed two examples and raised the
composite-QBit admission error in both. The combined unchanged-production probe
then executed twelve examples: scalar-envelope, roster-plan and persistence
paths failed on recursive-QBit admission. This authorizes the kernel change.
Test-only Slice/initializer plumbing errors do not count as RED. The first
direct all-mark selector/plane-count assertions stopped at an invalid fixture
part name, so they did not establish a schedule defect. Corrected direct
falsifiers at `/private/tmp/crystal-click-w233.PSTZBl/direct-shape-red2.log`
then executed two examples with two assertion failures and no errors: neither
the early window nor the empty EOF window rejected late selector/plane count
drift. This authorizes the physical shape-schedule change. The failed explicit
`--location` forwarding attempt is runner plumbing, not a behavioral signal.

The first post-change kernel probe found a real missing default-plane path for
QBit inside an actual `Array(Nullable(Tuple(...)))`; it now reuses the prepared
Dynamic site and per-type scratch just like a nondefault leaf. Test assertions
were corrected to compare nominal types and encoded values rather than changing
Dynamic's existing identity equality, and an invalid SimpleAggregate fixture
was corrected without changing its function/storage law. The repeated focused
DEBUG probe at `kernel-green2-debug.log` passed 22 examples with zero failures,
errors or pending tests. This is a kernel result, not physical/native closure.
The public native helper records scalar RowBinary through `encode_value`, while
its nominal equality checks retain the full type-tagged encoding.

The first complete physical DEBUG probe passed 32 examples. The complete
schedule is a dedicated owner and traverses the prepared QBit site roster,
including a declared root Dynamic whose actual Array exposes another Dynamic
selector. Its exact workspace test uses 128 physical marks: five UInt64 count
vectors require 5120 bytes, while 5119 rejects before a positive shape read.
The earlier 2560-byte fixture exhausted ordinary role-name metadata first;
that was not an occurrence-workspace falsifier and did not relax production
accounting. A source-only adversary then found a stronger BASIC-selector
pre-read obligation: the header mode is already validated, so inspected
per-mark byte deltas can be checked against parent occurrences before reading
tags. The new counting-source probe executed one example with one assertion
failure and no errors: rejection happened only after a full tag read. Retaining
the validated header mode now permits BASIC mark/total preflight before that
read, and revalidation rejects a changed mode on the full window. The focused
DEBUG roster then passed 33 examples with zero failures/errors/pending.
COMPACT tag expansion remains bounded by existing codec limits but is not
newly qualified by this BASIC-profile slice.

The initial ten-file JSON regression cohort stops before examples at an
identically printed Proc-alias mismatch. Omitting the new schedule hook does
not remove it. The exact cohort also fails on an isolated Git archive of clean
`ae2e97f0f0c77a8b4c847b393eeb0697c1af2c47`, so this symptom is not attributed to
W233. All ten JSON files pass separately (67 examples in each of DEBUG and
RELEASE). Explicit nullable
Proc-alias assignment and alias `.new` block construction both still fail in
the isolated clean baseline; neither is applied to production. The installed
Crystal 1.21 source virtualizes Proc-literal arguments but devirtualizes them
when printing, while compatibility compares the underlying types. W212 adds
a `BinaryDynamicJsonLeafKey` subclass, providing a concrete candidate for the
combined-context interaction, not a proven attribution. Exception effects
are not a Proc signature dimension. The matched regression certificate runs
these files individually; grouped compilation remains open, with no
whole-suite or compiler-fix claim.

The initial schedule-omission seed executed five controls with four assertion
failures. Its Variant/Array payload mutations did not write compression-frame
CityHash checksums, so their rejection cannot establish the intended semantic
guard. The checksum-independent direct mark-grid and BASIC pre-read probes
remain behavioral evidence. The fixture now writes valid frame checksums,
checks successful early/EOF reads before mutation, and requires precise
occurrence/selector diagnostics. The corrected focused DEBUG gate passes nine
examples. Omitting only the new hook then executes six late-corruption
controls: all six fail with no expected corruption exception, zero runtime
errors or pending tests. This includes valid Variant-arm/Array-size count drift
and invalid embedded-Variant tags. The production site-reader source restores
byte-for-byte before final matched regression gates.

The first public/static regression cohort executes 73 examples with one
failure in W231's obsolete recursive-QBit Dynamic rejection assertion. That
control is migrated to prepared-plan acceptance and empty bulk round-trip
for admitted actuals, while Count/JSON/Object, immediate Nullable and mixed
Dynamic-sibling guards remain intact. Missing-role forged streams still reject
as malformed data rather than unsupported admitted descriptors.

The additional late valid embedded-Variant arm-change control initially passed
with and without the hook, but the same invalid compression checksum makes
that result nondiscriminating about selector/plane semantics. Neither run
establishes an existing semantic guard; the corrected six-control seed above
supersedes them. Exact byte restoration of the site reader is independently
checked. A zero-example name-filter attempt supplies no test evidence. Repeated
`--example` options select only the last filter in Crystal 1.21; that probe is
an EOF-only failure, not a six-example certificate. The final single `late`
filter executes all six intended controls.

Native harness plumbing is checked separately from serialization: NamedTuple
key access, nominal/encoded Dynamic equality, a duplicate self-forwarding Ruby
method and unqualified module-helper calls are corrected without widening the
library. The stock-only recovery validates thirteen raw records and 187 part
files. The paired runner and separate auditor now prune only exact local Atomic
directory aliases; generated/part/file/external/missing/chained aliases remain
rejected. Fixed synthetic alias pressure tests pass 18 positive checks and
reject 162 negative checks. A Ripper probe examines 28 bare calls against 25
module helpers and 15 Probe methods before fresh captures. This structural
scope check is not itself native compatibility evidence.

Fresh final DEBUG and RELEASE paired captures each qualify three profiles,
thirteen shared immutable stock records and thirty new helper/native records.
The distinct process total across the two modes is 73, not 86. Both independent
raw audits pass, reject six coherent CHECK/status-label forgeries apiece, and
pass after every exact capture restoration. Actual generated part file names,
sizes, SHA-256 and bytes agree across modes: 206 files and 30,770 bytes per mode
(root 94/14,259; carrier 96/14,615; forced-shared 16/1,896). Native ATTACH retains
every generated file and adds only the already-audited invalidated system
columns file. These are fixed-profile native persistence witnesses, not an
all-layout, all-parameter, performance or process-provenance claim.

### Final scoped result and return pointer

VERIFIED within the finite quiescent Wide/LZ4/Default/plain-mrk2 prepared
Dynamic V3/BASIC profiles; root adversary verdict ROBUST within that scope.
The same 52 affected spec files pass 345 examples in each of DEBUG and RELEASE:
kernel/rosters 81, Dynamic transport 65, owner guards 59, JSON controls 67 and
public/static controls 73. JSON files run individually for the baseline compiler
limitation above. Corrected six-control omission/restoration, exact workspace,
unique-lane and native/raw-audit controls support the declared shape boundary.
Final formatting passes for 18 owned Crystal files; all three Ruby harnesses
pass host Ruby 2.6 syntax. Selected source/spec/harness and both helper hashes
are frozen, not an all-transitive compiler-input attestation.

Evidence index: [W233 packet](../.landmark/evidence/recursive-qbit-dynamic-w233.json).
Refresh after admission/plan/schedule/consumer, fixture/helper/auditor,
source/runtime or profile changes. Temporary raw roots are regenerable caches;
an absent root requires replay, not trust in a summary or packet.

Next discriminator: one concrete JSON/Dynamic path, dictionary ownership or
physical version boundary, reusing existing child codecs and native persistence
witnesses. LC(QBit), runtime-owned mixed siblings and unqualified serializer
profiles remain guarded. General MV/projection writing/execution and broad
facade decomposition remain open. Memory/performance stays deferred and the
overall goal remains active. Local atomic commit authority does not authorize
remote push, production mutation or resumed optimization.
