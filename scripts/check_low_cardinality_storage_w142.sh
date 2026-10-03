#!/usr/bin/env bash
set -euo pipefail

# Root owns all compiler/native execution through its serial resource guard.
[[ "${W142_EXECUTE_AS_ROOT:-}" == YES ]] || {
  printf 'refusing W142 storage oracle without root-owned W142_EXECUTE_AS_ROOT=YES\n' >&2
  exit 1
}

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
PROBE_ROOT_ARG="${W141_PROBE_ROOT:-}"
CHECK_ROOT_ARG="${W142_CHECK_ROOT:-}"
CRYSTAL_BIN="${CRYSTAL_BIN:-$(command -v crystal || true)}"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/private/tmp/crystal-click-w112-runtime.u0Jn1f/clickhouse}"
CLICKHOUSE_SOURCE_ROOT="${CLICKHOUSE_SOURCE_ROOT:-/Users/sergey/SrcArchives/clickhouse-2026-10-03-depth1-9007d227}"
SOURCE_REVISION='9007d227b64a3f8b667fc5258ceb2923f3cf477d'
EXPECTED_VERSION='ClickHouse local version 26.10.1.1201 (official build).'
EXPECTED_EXECUTABLE_SHA256='bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2'

[[ -n "$PROBE_ROOT_ARG" && "$PROBE_ROOT_ARG" == /* && -d "$PROBE_ROOT_ARG" && ! -L "$PROBE_ROOT_ARG" ]] || {
  printf 'W141_PROBE_ROOT must be an existing absolute non-symlink retained native fixture\n' >&2
  exit 2
}
PROBE_ROOT="$(CDPATH= cd -- "$PROBE_ROOT_ARG" && pwd -P)"
case "$PROBE_ROOT" in
  /private/tmp/crystal-click-object-low-cardinality-w141.*) ;;
  *) printf 'refusing unexpected W141 evidence root: %s\n' "$PROBE_ROOT" >&2; exit 2 ;;
esac

[[ -n "$CHECK_ROOT_ARG" && "$CHECK_ROOT_ARG" == /* && "$CHECK_ROOT_ARG" == /private/tmp/crystal-click-object-low-cardinality-w142.* ]] || {
  printf 'W142_CHECK_ROOT must be a new absolute /private/tmp/crystal-click-object-low-cardinality-w142.* path\n' >&2
  exit 2
}
[[ ! -e "$CHECK_ROOT_ARG" && ! -L "$CHECK_ROOT_ARG" ]] || {
  printf 'refusing to overwrite W142 evidence output: %s\n' "$CHECK_ROOT_ARG" >&2
  exit 1
}

[[ -x "$CLICKHOUSE_BIN" ]] || {
  printf 'pinned ClickHouse executable is unavailable: %s\n' "$CLICKHOUSE_BIN" >&2
  exit 1
}
[[ -n "$CRYSTAL_BIN" && -x "$CRYSTAL_BIN" ]] || {
  printf 'Set CRYSTAL_BIN to the Crystal executable\n' >&2
  exit 1
}
[[ -d "$CLICKHOUSE_SOURCE_ROOT" && ! -L "$CLICKHOUSE_SOURCE_ROOT" ]] || {
  printf 'pinned ClickHouse source checkout is unavailable or symlinked: %s\n' "$CLICKHOUSE_SOURCE_ROOT" >&2
  exit 1
}
actual_source_revision="$(git -C "$CLICKHOUSE_SOURCE_ROOT" rev-parse HEAD)"
[[ "$actual_source_revision" == "$SOURCE_REVISION" ]] || {
  printf 'W142 source revision mismatch: %s\n' "$actual_source_revision" >&2
  exit 1
}
actual_sha="$(shasum -a 256 "$CLICKHOUSE_BIN" | awk '{print $1}')"
[[ "$actual_sha" == "$EXPECTED_EXECUTABLE_SHA256" ]] || {
  printf 'W142 ClickHouse executable SHA mismatch: %s\n' "$actual_sha" >&2
  exit 1
}
actual_version="$(TZ=UTC "$CLICKHOUSE_BIN" local --version)"
[[ "$actual_version" == "$EXPECTED_VERSION" ]] || {
  printf 'W142 requires %s, got %s\n' "$EXPECTED_VERSION" "$actual_version" >&2
  exit 1
}

record="$PROBE_ROOT/results/run.txt"
[[ -f "$record" && ! -L "$record" ]] || {
  printf 'missing retained W141 native run identity record\n' >&2
  exit 1
}
rg -q -F "source_reference_revision=$SOURCE_REVISION" "$record" || {
  printf 'retained W141 source reference does not match the pinned ClickHouse source\n' >&2
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

mkdir "$CHECK_ROOT_ARG"
CHECK_ROOT="$(CDPATH= cd -- "$CHECK_ROOT_ARG" && pwd -P)"
case "$CHECK_ROOT" in
  /private/tmp/crystal-click-object-low-cardinality-w142.*) ;;
  *) printf 'refusing unexpected canonical W142 output root: %s\n' "$CHECK_ROOT" >&2; exit 2 ;;
esac
mkdir "$CHECK_ROOT/native-input" "$CHECK_ROOT/lanes" "$CHECK_ROOT/stores" "$CHECK_ROOT/results" "$CHECK_ROOT/crystal-cache"

cd "$ROOT"
export CLICKHOUSE_BIN CLICKHOUSE_SOURCE_ROOT W141_PROBE_ROOT="$PROBE_ROOT" W142_CHECK_ROOT="$CHECK_ROOT"
export CRYSTAL_CACHE_DIR="$CHECK_ROOT/crystal-cache" TZ=UTC
printf 'W142 physical LowCardinality oracle root=%s source=%s runtime_sha256=%s\n' \
  "$CHECK_ROOT" "$actual_source_revision" "$actual_sha"
printf 'Scope: compare nine authored LC root vectors to retained decompressed dictionary/index lanes, then consume library key/ID payloads through Native additional-only framing; no direct global-Native or standalone-part-writer claim.\n'

# The caller owns the single serial resource guard. Do not execute this wrapper
# in parallel or recursively; preserve all evidence on success or failure.
"$CRYSTAL_BIN" run --single-module --threads 1 --error-trace --link-flags='-fuse-ld=ld' \
  -D w117_library "$ROOT/scripts/check_low_cardinality_storage_w142.cr" 2>&1 | tee "$CHECK_ROOT/check.log"
