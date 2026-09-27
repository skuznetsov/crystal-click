#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
FIXTURE="$ROOT/test/fixtures/public/wide_array_array_nullable_uint64"

if [[ "$#" -gt 1 ]]; then
  printf 'usage: %s [stock-part-directory]\n' "$0" >&2
  exit 2
fi

(cd "$FIXTURE" && shasum -a 256 -c SHA256SUMS)
cmp -s "$FIXTURE/part/columns.txt" <(printf 'columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` Array(Array(Nullable(UInt64)))\n') || {
  printf 'unexpected fixture column metadata\n' >&2
  exit 1
}
cmp -s "$FIXTURE/part/columns_substreams.txt" <(printf 'columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n4 substreams for column `payload`:\n\tpayload.size0\n\tpayload.size1\n\tpayload.null\n\tpayload\n') || {
  printf 'unexpected fixture substreams\n' >&2
  exit 1
}
[[ "$(<"$FIXTURE/part/count.txt")" == 7 ]] || {
  printf 'unexpected fixture row count\n' >&2
  exit 1
}
[[ "$(find "$FIXTURE/part" -maxdepth 1 -type f | wc -l | tr -d ' ')" == 18 ]] || {
  printf 'unexpected fixture file count\n' >&2
  exit 1
}
[[ -z "$(find "$FIXTURE/part" -mindepth 1 -type l -print -quit)" ]] || {
  printf 'fixture contains symlinks\n' >&2
  exit 1
}

if [[ "$#" -eq 1 ]]; then
  [[ -d "$1" && ! -L "$1" ]] || {
    printf 'stock part directory not found: %s\n' "$1" >&2
    exit 2
  }
  diff -qr "$FIXTURE/part" "$1"
  printf 'fixture matches stock part tree: %s\n' "$1"
fi
