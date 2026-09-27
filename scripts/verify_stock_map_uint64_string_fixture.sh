#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_dir="$repo_root/test/fixtures/stock_map_uint64_string_lz4"

if [[ "$#" -gt 1 ]]; then
  echo "usage: $0 [stock-part-directory]" >&2
  exit 2
fi

(cd "$fixture_dir" && shasum -a 256 -c SHA256SUMS)

if [[ "$#" -eq 1 ]]; then
  stock_part="$1"
  if [[ ! -d "$stock_part" ]]; then
    echo "stock part directory not found: $stock_part" >&2
    exit 2
  fi
  diff -qr "$fixture_dir/part" "$stock_part"
  echo "fixture matches stock part tree: $stock_part"
fi
