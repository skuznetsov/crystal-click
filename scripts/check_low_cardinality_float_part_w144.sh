#!/usr/bin/env bash
set -euo pipefail

[[ "${W144_EXECUTE_AS_ROOT:-}" == YES ]] || {
  printf 'refusing W144 Float part oracle without root-owned W144_EXECUTE_AS_ROOT=YES\n' >&2
  exit 1
}
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/private/tmp/crystal-click-w112-runtime.u0Jn1f/clickhouse}"
CLICKHOUSE_SOURCE_ROOT="${CLICKHOUSE_SOURCE_ROOT:-/Users/sergey/SrcArchives/clickhouse-2026-10-03-depth1-9007d227}"
CRYSTAL_BIN="${CRYSTAL_BIN:-/opt/homebrew/bin/crystal}"
SOURCE_REVISION='9007d227b64a3f8b667fc5258ceb2923f3cf477d'
RUNTIME_SHA256='bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2'
RUNTIME_VERSION='ClickHouse local version 26.10.1.1201 (official build).'

[[ -x "$CLICKHOUSE_BIN" && ! -L "$CLICKHOUSE_BIN" && -x "$CRYSTAL_BIN" ]] || {
  printf 'pinned ClickHouse/Crystal executable unavailable\n' >&2; exit 1;
}
[[ -d "$CLICKHOUSE_SOURCE_ROOT" && ! -L "$CLICKHOUSE_SOURCE_ROOT" ]] || {
  printf 'pinned source checkout unavailable\n' >&2; exit 1;
}
[[ "$(git -C "$CLICKHOUSE_SOURCE_ROOT" rev-parse HEAD)" == "$SOURCE_REVISION" ]] || {
  printf 'W144 source reference mismatch\n' >&2; exit 1;
}
[[ "$(shasum -a 256 "$CLICKHOUSE_BIN" | awk '{print $1}')" == "$RUNTIME_SHA256" ]] || {
  printf 'W144 runtime SHA mismatch\n' >&2; exit 1;
}
[[ "$(TZ=UTC "$CLICKHOUSE_BIN" local --version)" == "$RUNTIME_VERSION" ]] || {
  printf 'W144 runtime version mismatch\n' >&2; exit 1;
}
[[ "${W144_INGEST_ROOT:-}" == /private/tmp/crystal-click-low-cardinality-float-w144.* && -d "$W144_INGEST_ROOT" && ! -L "$W144_INGEST_ROOT" ]] || {
  printf 'W144_INGEST_ROOT must name retained isolated W144 ingestion evidence\n' >&2; exit 2;
}
[[ "${W144_PART_ROOT:-}" == /private/tmp/crystal-click-low-cardinality-float-part-w144.* && ! -e "$W144_PART_ROOT" && ! -L "$W144_PART_ROOT" ]] || {
  printf 'W144_PART_ROOT must name a new isolated W144 part evidence path\n' >&2; exit 2;
}
export CLICKHOUSE_BIN CLICKHOUSE_SOURCE_ROOT TZ=UTC
export CRYSTAL_CACHE_DIR="${CRYSTAL_CACHE_DIR:-$(mktemp -d /private/tmp/crystal-click-float-part-cache-w144.XXXXXX)}"
mkdir -p "$CRYSTAL_CACHE_DIR"
cd "$ROOT"
"$CRYSTAL_BIN" run --single-module --threads 1 --error-trace --link-flags=-fuse-ld=ld \
  "$ROOT/scripts/check_low_cardinality_float_part_w144.cr"
