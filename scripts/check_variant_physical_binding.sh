#!/usr/bin/env bash
set -euo pipefail

# Root owns all ClickHouse and Crystal execution for the bounded W149 probe.
[[ "${W149_EXECUTE_AS_ROOT:-}" == YES ]] || {
  printf 'refusing W149 physical-binding oracle without root-owned W149_EXECUTE_AS_ROOT=YES\n' >&2
  exit 1
}

REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
CHECK_ROOT_ARG="${W149_CHECK_ROOT:-}"
CRYSTAL_BIN="${CRYSTAL_BIN:-$(command -v crystal || true)}"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/private/tmp/crystal-click-w144-runtime-recovery.Pm8VNb/clickhouse-stripped}"
CLICKHOUSE_SOURCE_ROOT="${CLICKHOUSE_SOURCE_ROOT:-/Users/sergey/SrcArchives/clickhouse-2026-10-03-depth1-9007d227}"
SOURCE_REVISION='9007d227b64a3f8b667fc5258ceb2923f3cf477d'
EXPECTED_VERSION='ClickHouse local version 26.10.1.1201 (official build).'
EXPECTED_EXECUTABLE_SHA256='bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2'

[[ -n "$CHECK_ROOT_ARG" && "$CHECK_ROOT_ARG" =~ ^/private/tmp/crystal-click-variant-physical-w149\.[A-Za-z0-9_-]+$ ]] || {
  printf 'W149_CHECK_ROOT must be a new direct /private/tmp child matching crystal-click-variant-physical-w149.<safe-suffix>\n' >&2
  exit 2
}
[[ ! -e "$CHECK_ROOT_ARG" && ! -L "$CHECK_ROOT_ARG" ]] || {
  printf 'refusing to overwrite W149 evidence output: %s\n' "$CHECK_ROOT_ARG" >&2
  exit 1
}
[[ -x "$CLICKHOUSE_BIN" && ! -L "$CLICKHOUSE_BIN" ]] || {
  printf 'pinned ClickHouse executable is unavailable or symlinked: %s\n' "$CLICKHOUSE_BIN" >&2
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
  printf 'W149 source revision mismatch: %s\n' "$actual_source_revision" >&2
  exit 1
}
actual_sha="$(shasum -a 256 "$CLICKHOUSE_BIN" | awk '{print $1}')"
[[ "$actual_sha" == "$EXPECTED_EXECUTABLE_SHA256" ]] || {
  printf 'W149 ClickHouse executable SHA mismatch: %s\n' "$actual_sha" >&2
  exit 1
}
actual_version="$(TZ=UTC "$CLICKHOUSE_BIN" local --version)"
[[ "$actual_version" == "$EXPECTED_VERSION" ]] || {
  printf 'W149 requires %s, got %s\n' "$EXPECTED_VERSION" "$actual_version" >&2
  exit 1
}

mkdir "$CHECK_ROOT_ARG"
CHECK_ROOT="$(CDPATH= cd -- "$CHECK_ROOT_ARG" && pwd -P)"
case "$CHECK_ROOT" in
  /private/tmp/crystal-click-variant-physical-w149.*) ;;
  *) printf 'refusing unexpected canonical W149 output root: %s\n' "$CHECK_ROOT" >&2; exit 2 ;;
esac
mkdir "$CHECK_ROOT/cases" "$CHECK_ROOT/controls" "$CHECK_ROOT/crystal-cache" \
  "$CHECK_ROOT/evidence" "$CHECK_ROOT/parts" "$CHECK_ROOT/results" "$CHECK_ROOT/stores"

cd "$REPO_ROOT"
export CLICKHOUSE_BIN CLICKHOUSE_SOURCE_ROOT CLICKHOUSE_SOURCE_REVISION="$actual_source_revision"
export W149_CHECK_ROOT="$CHECK_ROOT" CRYSTAL_CACHE_DIR="$CHECK_ROOT/crystal-cache" TZ=UTC
printf 'W149 physical-binding oracle root=%s source=%s runtime_sha256=%s\n' \
  "$CHECK_ROOT" "$actual_source_revision" "$actual_sha"
printf 'Scope: finite stock Wide Variant bindings and borrowed-envelope ATTACH/CHECK; not an independent complete-part writer.\n'

"$CRYSTAL_BIN" run --single-module --threads 1 --error-trace --link-flags=-fuse-ld=ld \
  "$REPO_ROOT/scripts/variant_physical_binding_fixture.cr" 2>&1 | tee "$CHECK_ROOT/check.log"
