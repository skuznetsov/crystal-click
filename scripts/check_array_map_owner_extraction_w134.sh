#!/usr/bin/env bash
set -euo pipefail

# A structural move guard, not a runtime/compatibility certificate. The fixed
# checkpoint makes each comparison independent of the current branch HEAD.
w134_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$w134_root"
w134_baseline=2e150f4
git cat-file -e "${w134_baseline}:src/crystal_click/wide_part_table.cr"

w134_names=(
  numeric_slice_base numeric_slice numeric_rows_base numeric_rows
  nullable_numeric_rows string_leaf_rows bool_leaf_rows
  array_leaf_rows_base array_leaf_rows
)
w134_classes=(
  WidePartArrayMapNumericSliceBase WidePartArrayMapNumericSlice
  WidePartArrayMapNumericRowsBase WidePartArrayMapNumericRows
  WidePartArrayMapNullableNumericRows WidePartArrayMapStringLeafRows
  WidePartArrayMapBoolLeafRows WidePartArrayMapArrayLeafRowsBase
  WidePartArrayMapArrayLeafRows
)
w134_first=(80 83 91 99 161 222 302 366 373)
w134_last=(81 89 97 159 220 300 364 371 463)

for w134_index in "${!w134_names[@]}"; do
  w134_path="src/crystal_click/wide_part_table/wide_part_array_map_${w134_names[$w134_index]}.cr"
  if [[ ! -f "$w134_path" ]]; then
    printf 'FAIL W134 missing owner: %s\n' "$w134_path" >&2
    exit 1
  fi
  awk 'NR == 1 { if ($0 != "module CrystalClick") exit 1; next }
       { last = $0 } END { if (last != "end") exit 1 }' "$w134_path"
  w134_declarations=$(rg -c '^  (abstract )?class ' "$w134_path")
  [[ "$w134_declarations" == 1 ]]
  w134_matches=$(rg -l "^  (abstract )?class ${w134_classes[$w134_index]}([ (<]|$)" src -g '*.cr')
  [[ "$w134_matches" == "$w134_path" ]]
  w134_import="require \"./crystal_click/wide_part_table/wide_part_array_map_${w134_names[$w134_index]}\""
  [[ $(rg -F -x -c "$w134_import" src/crystal_click.cr) == 1 ]]
  cmp <(git show "${w134_baseline}:src/crystal_click/wide_part_table.cr" |
        sed -n "${w134_first[$w134_index]},${w134_last[$w134_index]}p") \
      <(awk 'NR == 1 { next } NR > 2 { print previous } { previous = $0 }' "$w134_path")
done

# The loader comparison below removes this prefix; admit exactly the sealed
# nine imports so an unexpected extra import cannot hide behind that filter.
w134_import_count=$(rg -c '^require "\./crystal_click/wide_part_table/wide_part_array_map_' src/crystal_click.cr)
if [[ "$w134_import_count" != 9 ]]; then
  printf 'FAIL W134 expected exactly nine owner imports, got %s\n' "$w134_import_count" >&2
  exit 1
fi

# Removing precisely the sealed contiguous owner region must explain the
# entire facade diff, including the unrelated regular numeric Map helpers.
cmp <(git show "${w134_baseline}:src/crystal_click/wide_part_table.cr" | sed '80,464d') \
    src/crystal_click/wide_part_table.cr
cmp <(git show "${w134_baseline}:src/crystal_click.cr") \
    <(awk '!/^require "\.\/crystal_click\/wide_part_table\/wide_part_array_map_/' src/crystal_click.cr)
printf 'PASS W134 nine single-class owners; exact bodies/comments, unique declarations/imports and unchanged remaining facade/loader\n'
