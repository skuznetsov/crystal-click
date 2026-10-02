#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd -- "${script_dir}/.." && pwd -P)"
crystal_bin="${CRYSTAL_BIN:-/opt/homebrew/bin/crystal}"
clickhouse_bin="${CLICKHOUSE_BIN:-/private/tmp/crystal-click-w112-runtime.u0Jn1f/clickhouse}"
keep_tmp="${W114_KEEP_TMP:-0}"

if [[ "$keep_tmp" != "0" && "$keep_tmp" != "1" ]]; then
  printf 'W114_KEEP_TMP must be 0 or 1\n' >&2
  exit 2
fi
if [[ ! -x "$crystal_bin" ]]; then
  printf 'Crystal executable is unavailable: %s\n' "$crystal_bin" >&2
  exit 2
fi
if [[ ! -x "$clickhouse_bin" ]]; then
  printf 'Pinned ClickHouse executable is unavailable: %s\n' "$clickhouse_bin" >&2
  exit 2
fi

green_root="$(mktemp -d /private/tmp/crystal-click-w114-green.XXXXXX)"
green_root="$(cd -- "$green_root" && pwd -P)"
case "$green_root" in
  /private/tmp/crystal-click-w114-green.*) ;;
  *)
    printf 'Refusing unexpected W114 temporary root: %s\n' "$green_root" >&2
    exit 2
    ;;
esac
if [[ -L "$green_root" || ! -d "$green_root" ]]; then
  printf 'W114 temporary root must be a real directory: %s\n' "$green_root" >&2
  exit 2
fi

store_path="${green_root}/store"
cache_path="${green_root}/crystal-cache"
mkdir -- "$cache_path"
export CLICKHOUSE_BIN="$clickhouse_bin"
export W114_STORE="$store_path"
export W114_GREEN_ROOT="$green_root"
export CRYSTAL_CACHE_DIR="$cache_path"

cleanup() {
  status=$?
  if [[ "$keep_tmp" == "1" || "$status" != "0" ]]; then
    printf 'W114 temporary root retained for inspection: %s\n' "$green_root" >&2
  else
    case "$green_root" in
      /private/tmp/crystal-click-w114-green.*)
        rm -rf -- "$green_root"
        ;;
      *)
        printf 'Refusing cleanup outside the fresh W114 temporary root: %s\n' "$green_root" >&2
        return 2
        ;;
    esac
  fi
}
trap cleanup EXIT

printf 'W114 GREEN root: %s\n' "$green_root"
printf 'Pinned stock runtime qualification follows; this wrapper assumes the caller owns the serial resource guard.\n'
"$crystal_bin" run --single-module --link-flags='-fuse-ld=ld' --error-trace \
  "${repo_root}/scripts/probe_geometry_w114.cr" -- qualify
"$crystal_bin" run --single-module --link-flags='-fuse-ld=ld' --error-trace \
  "${repo_root}/scripts/check_geometry_w114_oracle.cr"
