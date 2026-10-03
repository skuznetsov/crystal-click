#!/usr/bin/env bash
set -euo pipefail

# Bidirectional W141 logical-row oracle. Root owns runtime and compiler
# execution through its resource guard; this wrapper intentionally has no
# self-created/deleted evidence root.
[[ "${W141_EXECUTE_AS_ROOT:-}" == YES ]] || {
  printf 'refusing W141 binary oracle without root-owned W141_EXECUTE_AS_ROOT=YES\n' >&2
  exit 1
}

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
PROBE_ROOT_ARG="${W141_PROBE_ROOT:-}"
CRYSTAL_BIN="${CRYSTAL_BIN:-$(command -v crystal || true)}"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/private/tmp/crystal-click-w112-runtime.u0Jn1f/clickhouse}"
SOURCE_REVISION='9007d227b64a3f8b667fc5258ceb2923f3cf477d'
EXPECTED_VERSION='ClickHouse local version 26.10.1.1201 (official build).'
EXPECTED_EXECUTABLE_SHA256='bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2'

[[ -n "$PROBE_ROOT_ARG" && "$PROBE_ROOT_ARG" == /* && -d "$PROBE_ROOT_ARG" && ! -L "$PROBE_ROOT_ARG" ]] || {
  printf 'W141_PROBE_ROOT must be an existing absolute non-symlink retained probe directory\n' >&2
  exit 2
}
PROBE_ROOT="$(CDPATH= cd -- "$PROBE_ROOT_ARG" && pwd -P)"
case "$PROBE_ROOT" in
  /private/tmp/crystal-click-object-low-cardinality-w141.*) ;;
  *) printf 'refusing unexpected W141 probe evidence root: %s\n' "$PROBE_ROOT" >&2; exit 2 ;;
esac

[[ -x "$CLICKHOUSE_BIN" ]] || {
  printf 'pinned ClickHouse executable is unavailable: %s\n' "$CLICKHOUSE_BIN" >&2
  exit 1
}
[[ -n "$CRYSTAL_BIN" && -x "$CRYSTAL_BIN" ]] || {
  printf 'Set CRYSTAL_BIN to the Crystal executable\n' >&2
  exit 1
}
actual_sha="$(shasum -a 256 "$CLICKHOUSE_BIN" | awk '{print $1}')"
[[ "$actual_sha" == "$EXPECTED_EXECUTABLE_SHA256" ]] || {
  printf 'W141 ClickHouse executable SHA mismatch: %s\n' "$actual_sha" >&2
  exit 1
}
actual_version="$(TZ=UTC "$CLICKHOUSE_BIN" local --version)"
[[ "$actual_version" == "$EXPECTED_VERSION" ]] || {
  printf 'W141 requires %s, got %s\n' "$EXPECTED_VERSION" "$actual_version" >&2
  exit 1
}

record="$PROBE_ROOT/results/run.txt"
[[ -f "$record" && ! -L "$record" ]] || {
  printf 'missing W141 retained native run record\n' >&2
  exit 1
}
rg -q -F "source_reference_revision=$SOURCE_REVISION" "$record" || {
  printf 'retained W141 source revision does not match the pinned ClickHouse source\n' >&2
  exit 1
}
rg -q -F "runtime_sha256=$EXPECTED_EXECUTABLE_SHA256" "$record" || {
  printf 'retained W141 runtime SHA does not match this oracle\n' >&2
  exit 1
}
rg -q -F "runtime_version=$EXPECTED_VERSION" "$record" || {
  printf 'retained W141 runtime version does not match this oracle\n' >&2
  exit 1
}

CHECK_ROOT="$PROBE_ROOT/binary-oracle"
[[ ! -e "$CHECK_ROOT" && ! -L "$CHECK_ROOT" ]] || {
  printf 'refusing to overwrite W141 binary oracle output: %s\n' "$CHECK_ROOT" >&2
  exit 1
}
mkdir "$CHECK_ROOT" "$CHECK_ROOT/library-writer" "$CHECK_ROOT/stores" "$CHECK_ROOT/crystal-cache"

cd "$ROOT"
export CLICKHOUSE_BIN W141_PROBE_ROOT="$PROBE_ROOT" W141_CHECK_ROOT="$CHECK_ROOT"
export CRYSTAL_CACHE_DIR="$CHECK_ROOT/crystal-cache" TZ=UTC
printf 'W141 binary row oracle root=%s source-reference=%s runtime=%s\n' \
  "$CHECK_ROOT" "$SOURCE_REVISION" "$actual_sha"
# Root owns any serial resource guard. On failure, retain all inputs and
# outputs so the bytes and decoder diagnostics remain inspectable.
"$CRYSTAL_BIN" run --single-module --threads 1 --error-trace --link-flags='-fuse-ld=ld' \
  -D w117_library "$ROOT/scripts/check_binary_low_cardinality_w141.cr" 2>&1 | tee "$CHECK_ROOT/check.log"
