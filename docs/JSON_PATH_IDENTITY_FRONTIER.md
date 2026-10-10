# JSON path identity frontier (W252)

Status: VERIFIED / root adversary ROBUST within the finite shared raw-path
identity target. This is not a claim that JSON layouts, SKIP, MV/projections,
or the full project goal are done.

## Problem and source anchor

The recursive leaf/container codec already carries JSON typed paths as raw
StringBinary names. Admission is inconsistent: embedded JSON requires plain
ASCII identifiers, root Object schemas require dotted ASCII identifiers, and
their SQL renderers/parsers do not share escaping. A wider SQL parser alone
would leave wire descriptors, rows, and Dynamic-to-Object bindings unusable.

Baseline: `40a347f9ebf966b7cbf74832e721ee5b52483581` (W251), clean before edits.
Reference source: official shallow checkout
`/private/tmp/clickhouse-w249-upstream-P7bxRQ`, revision
`fe0f91b6c3de9e1efa33a1bce4ca9bcbfb4c509d`. This source revision is distinct from
the separately pinned native runtime 26.10.1.1201,
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`.

Source anchors:

- `src/DataTypes/DataTypeObject.cpp:236-297`: raw sorted typed paths are rendered
  by `backQuoteIfNeed`, except case-insensitive SKIP is always quoted.
- `src/IO/WriteHelpers.cpp:95-159`, `src/IO/WriteHelpers.h:340-408`: identifier
  keyword policy and backslash escaping of backticks, backslash, and the
  listed control bytes (including NUL).
- `src/Parsers/ParserDataType.cpp:155-232`,
  `src/Parsers/ExpressionElementParsers.cpp:344-379`,
  `src/Parsers/ASTIdentifier.cpp:283-288`: nonempty identifiers, compound names
  flattened with dots, and quoted names decoded to raw strings.
- `src/DataTypes/DataTypesBinaryEncoding.cpp:514-541,810-871`: raw path strings
  in descriptor metadata, not SQL-quoted strings or path-component arrays.

Root-owned preimplementation native characterization in
`/private/tmp/crystal-click-w252.FU1rs2/name-characterization-retry/` observes
canonical names for dotted/space/SKIP/backtick/backslash/Unicode/control-byte/
percent/reserved-word paths. Empty quoted identifiers fail with code 62.
The first runner attempt failed only while displaying UTF-8 results in Ruby;
it is not rejection evidence. Its captures are preserved separately.

Supplemental root captures admit quoted `.a`, `a.`, `a..b`, `x=y`, and
`a,b(c)` (five native processes, exit 0). A separately captured native query
retains distinct typed values for `a.b`, `a%2Eb`, a backtick-containing name,
and `x=y`, both directly and inside Dynamic. Its explicit
`json_type_escape_dots_in_keys=0` setting fixes the input-normalization context;
the library does not infer that setting from raw path spelling.

## Admitted behavior

1. Raw flattened names remain byte identities. Quoting is SQL presentation;
   `a.b` and `a%2Eb` remain distinct raw names. No JSON text ingestion,
   automatic key escaping, hierarchy reconstruction, or filename decoding is
   inferred from those spellings.
2. A shared `JsonPathSqlName` owns nonempty raw-name validation, canonical
   quoting/escaping, escaped-output measurement, and bounded SQL path-token
   decoding. One class has one file. Leaf serializers remain unchanged.
3. Embedded `BinaryJsonType` keeps its existing 256-byte raw-path cap and
   shared recursive operation budgets. Root `ObjectDocumentSchema` retains its
   existing budget-bound lengths rather than acquiring a new 256-byte cap.
4. `BinaryJsonType`, its canonical recursive name parser, descriptor wire
   codec, `BinaryJsonRow`, root Object schema/parser, and Dynamic binding agree
   on the same raw identity within their declared length/type bounds.
5. Existing public part/table/offline consumers retain the widened names
   through existing context bindings. Physical stream components continue to
   use `PhysicalStreamName` escaping and collision checks, separately from SQL
   escaping. No new physical layout or per-product serializer is introduced.
6. Name-output expansion and decoded raw-name copies are admitted against
   caller-owned budgets before materialization. Quoted punctuation must not
   split JSON argument lists. Malformed/noncanonical recursive SQL names,
   empty/over-limit embedded raw names, wire duplicates, and budget overflow
   stay rejected before output publication or read callbacks.
7. Existing Dynamic V1/V2 UTF-8 SQL-type-name fences remain unchanged. Raw
   descriptor identity does not promote invalid-UTF-8 names to every physical
   context. The native witness covers valid UTF-8 and represented control
   bytes, not arbitrary invalid-UTF-8 metadata.

## Explicitly not admitted by this slice

- SKIP path/REGEXP metadata or insertion normalization. Nonzero wire rosters
  and SQL SKIP clauses remain refused. Quoted raw `SKIP` is an ordinary path.
- Substituting Crystal Regex for RE2; changing upstream dot-key escape rules;
  unifying text-insertion and binary-row SKIP predicates.
- General SQL compound-identifier input syntax. The recursive entry point
  parses only the canonical name printed by the descriptor.
- New serializers/layout versions, Compact writing, stock physical-byte
  re-emission, new aggregate families, general keys/partitions, MV/projection
  materialization, or performance conclusions.

## Plan, ownership, and rollback

Risk: CAUTION (serialization/name identity across retained and physical state).
Likeliest failure: decode/re-encode agrees locally but changes the raw path or
routes it to a different physical lane. Independent stock reads, raw structure
inspection, and escaped-filename/typed-value checks discriminate that failure.

- Luna A: new SQL-path owner; embedded descriptor/name parser/wire admission;
  `BinaryTypeNameBudget` escaped-output preflight. No test/harness ownership.
- Luna B: root Object schema/parser and Dynamic binding adapters. Reuse A's
  owner, preserve public parser overrides and existing length/budget behavior.
- Luna C: existing-API behavioral REDs, affected stale negative expectations,
  reciprocal native helper/runner, and physical/public consumer assertions.
- Root: source/native characterization, bounded design, all heavy gates,
  independent raw-capture/adversary review, status/evidence, exact local commit.

Workers are not alone; no worker runs native processes, compilers, broad
specs, Git writes, or changes another owner's files. Production edits wait for
root-observed behavioral RED. Rollback is the eventual atomic local commit;
until then inspect the exact diff and patch only owned W252 hunks. No push or
history rewrite is authorized by this slice.

## DoD and falsifiers

Root executes serial guarded DEBUG and RELEASE commands for the exact affected
spec roster (recorded in the final evidence packet), with one compiler worker
and `--single-module --threads 1 --link-flags=-fuse-ld=ld --error-trace`.
Expected signal: zero failures/errors/pending, including the existing W251,
JSON scalar/descriptor, Object schema/parser, Dynamic binding/physical, public
table/offline, malformed-input, and whole-roster preflight laws.

Reciprocal native witness: root + Array(Dynamic) JSON arms in the existing
V1/single-stream and V2/sized-stream matrix, both helper build modes. It must
observe stock-generated parts read through direct/public/offline paths and
library-generated parts accepted by stock ATTACH/CHECK=1, exact type names,
raw paths/typed values, and physical structures. A bounded root Object path
witness must exercise the root schema adapter as well, not just constructors.
Pinned binary/helper/harness inputs, actual argv/stdin/output/exit status, and
raw generated files are inspected by root, not promoted solely from a runner
report. Same-lineage Luna review is correlated, not independent.

Required adversaries: quoted backtick/backslash and argument punctuation;
Unicode and NUL/control bytes; distinct dotted and percent spellings; a
reserved raw SKIP name without enabling SKIP policy; empty/overlong paths;
escaped name output at budget boundaries; missing/corrupt unused physical
children; forged native reports. Scope excludes any native case not actually
captured. Formatter, Ruby syntax, and `git diff --check` must also pass.

The final packet records exact commands, source/native/toolchain/helper pins,
observed roster/results, raw inspection, residual exclusions, and the decay
trigger: changes to path ownership, parsing, budgets, binding, stream naming,
or pinned source/runtime invalidate this certificate.

## Observed qualification and continuation

Root observed a behavioral RED before production changes: 5 examples, zero
failures, 3 errors, zero pending, exit 1. Existing constructor/path admission
rejected the authored valid names; this was not a compilation failure.
The final same ordered 43-file roster passes 107 + 179 = 286 examples in each
DEBUG/RELEASE mode, zero failures/errors/pending. A final whitespace-only spec
format correction is followed by 9 passing examples in each mode for that
affected file. Both final helper builds, 18-file Crystal formatting, Ruby
syntax and final diff checks pass.

Four final reciprocal cells qualify V1/single-stream and V2/sized-stream in
both helper modes, with root Dynamic, Array(Dynamic), and root typed-only
Object. Eight native and four helper calls complete cleanly. Library parts
pass stock ATTACH/CHECK=1 with exact schemas, types and typed values; stock
parts pass direct/public candidate/owned Dynamic reads and Object offline
`.values`. The witness retains distinct `a.b`, `a%2Eb`, backtick and equals
names, typed NULL, unused JSON arms, and zero-window boundaries. Native input
uses a nested object for the raw flattened `a.b` typed path under the explicit
dot-key setting; it is not a top-level literal dotted input-key test.

Root separately reconciles all 40 raw Dynamic structures, their type rosters,
mandatory statistics, prefix coordinates and P=[2,2,2] plus EOF marks. It also
reads the typed UInt8 lanes, nullable data/null maps, parent UInt8 lanes and
Array row-size bytes independently. Array wire `size0` stores [0,0,2,1,1,1];
cumulative in-memory offsets are [0,0,2,3,4,5] and child counts per granule are
Q=[0,3,2]. Empty unused arms still require metadata and an eight-byte BASIC
Variant header. Their remaining payload lanes are empty. Root Object structure
metadata is presence/snapshot-bound and consumed by both readers, not fully
independently decoded by the raw auditor. Stream filename identity uses
SipHash2/4, not CityHash. Native CHECK supplies the part checksum acceptance;
the raw auditor does not replace it with a full independent checksum parser.

Actual generated files match across DEBUG/RELEASE: 190 files / 37,896 bytes
for single-stream, 202 / 40,289 for sized-stream, 392 / 78,185 per mode total.
Six in-memory forgeries reject at intended guards: dot/percent identity alias,
native typed-value swap, statistics count, statistics prefix, nonterminal mark,
and terminal EOF coordinate. Baseline and final four-cell acceptance pass;
qualified captures are not mutated. Corrected harness/oracle assumptions are
excluded diagnostics, not native format rejection evidence.

The [root-owned evidence index](../.landmark/evidence/json-path-identity-w252.json)
records the exact roster, commands, final pins, captures, auditor and controls.
It is a curated pointer to observations, not proof from filled fields or model
agreement. Capture loss or relevant source/compiler/helper/oracle/runtime
changes reopen dependent claims. No full suite, all-layout/version products,
invalid-UTF-8 physical names, stock re-emission, general JSON ingestion, SKIP,
MV/projection writes or speed-parity closure is claimed. The next frontier is
remaining physical layout/state handoffs using existing recursive codecs;
broader facade decomposition remains open. Overall goal ACTIVE, performance
deferred, no push.
