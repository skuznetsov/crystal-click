#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/Users/sergey/.local/bin/clickhouse}"
EXPECTED_VERSION='ClickHouse local version 26.7.1.1315 (official build).'

[[ -x "$CLICKHOUSE_BIN" ]] || { printf 'ClickHouse executable not found: %s\n' "$CLICKHOUSE_BIN" >&2; exit 1; }
ACTUAL_VERSION="$("$CLICKHOUSE_BIN" local --version)"
[[ "$ACTUAL_VERSION" == "$EXPECTED_VERSION" ]] || {
  printf 'oracle requires %s, got %s\n' "$EXPECTED_VERSION" "$ACTUAL_VERSION" >&2
  exit 1
}
bash "$ROOT/scripts/verify_stock_wide_bfloat16_w49_fixture.sh"

TMP_ROOT="$(mktemp -d /private/tmp/crystal-click-bfloat16-w49-oracle.XXXXXX)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT
cd "$ROOT"
export CLICKHOUSE_BIN TMP_ROOT
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache"
mkdir -p "$CRYSTAL_CACHE_DIR"

crystal run --link-flags='-fuse-ld=ld' --stdin-filename "$ROOT/scripts/check_wide_bfloat16_w49_oracle.cr" <<'CRYSTAL'
require "file_utils"
require "../src/crystal_click"

W49_KEYS = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64]
W49_SCALAR = [0x0000_u16, 0x8000_u16, 0x3f80_u16, 0x0001_u16, 0x7f7f_u16, 0x7fc1_u16, 0xffe2_u16]
W49_MAYBE = [nil, 0x8000_u16.as(UInt16?), 0x7fc2_u16.as(UInt16?), nil, 0x8001_u16.as(UInt16?), nil, 0x7fc1_u16.as(UInt16?)]
W49_ARRAY = [
  [] of UInt16,
  [0x8000_u16, 0x7fc1_u16, 0xffe2_u16],
  [0x0001_u16],
  [] of UInt16,
  [0x7f7f_u16, 0xff80_u16, 0x0080_u16],
  [0x7fe2_u16],
  [] of UInt16,
] of Array(UInt16)
W49_NULLABLE_ARRAY = [
  [] of UInt16?,
  [nil, 0x8000_u16.as(UInt16?), 0x7fc1_u16.as(UInt16?)] of UInt16?,
  [nil, nil] of UInt16?,
  [] of UInt16?,
  [0x7fe2_u16.as(UInt16?), nil, 0x3f80_u16.as(UInt16?)] of UInt16?,
  [nil, 0x8001_u16.as(UInt16?), nil] of UInt16?,
  [] of UInt16?,
] of Array(UInt16?)
W49_FIXTURE = File.expand_path("../test/fixtures/public/wide_bfloat16_w49/part", __DIR__)

def run_clickhouse(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse query failed (status #{status.exit_code}): #{query}" unless status.success?
  output.to_s
end

def create_table(binary : String, store : String, table : String, columns : String) : Nil
  run_clickhouse(binary, store, <<-SQL)
  CREATE TABLE default.#{table}
  (
      `pk` UInt64,
      #{columns}
  )
  ENGINE = MergeTree
  ORDER BY pk
  SETTINGS
      index_granularity = 2,
      enable_mixed_granularity_parts = 1,
      min_rows_for_wide_part = 0,
      min_bytes_for_wide_part = 0,
      ratio_of_defaults_for_sparse_serialization = 1.0,
      compress_marks = 0,
      min_compress_block_size = 0,
      max_compress_block_size = 4096;
  SQL
  nil
end

def append_u64_le(io : IO, value : UInt64) : Nil
  8.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
end

def append_bfloat16_le(io : IO, bits : UInt16) : Nil
  io.write_byte((bits & 0xff_u16).to_u8)
  io.write_byte((bits >> 8).to_u8)
end

def append_varuint(io : IO, value : UInt64) : Nil
  rest = value
  while rest >= 0x80_u64
    io.write_byte(((rest & 0x7f_u64) | 0x80_u64).to_u8)
    rest >>= 7
  end
  io.write_byte(rest.to_u8)
end

def append_nullable_bfloat16(io : IO, value : UInt16?) : Nil
  if bits = value
    io.write_byte(0_u8)
    append_bfloat16_le(io, bits)
  else
    # RowBinary Nullable encodes only the null flag for NULL; the physical
    # MergeTree leaf has a separate map plus a two-byte nested slot.
    io.write_byte(1_u8)
  end
end

def rowbinary_scalar(keys : Array(UInt64), values : Array(UInt16)) : String
  raise "BFloat16 fixture lengths differ" unless keys.size == values.size
  output = IO::Memory.new
  keys.each_with_index do |key, index|
    append_u64_le(output, key)
    append_bfloat16_le(output, values[index])
  end
  output.to_s
end

def rowbinary_nullable(keys : Array(UInt64), values : Array(UInt16?)) : String
  raise "Nullable(BFloat16) fixture lengths differ" unless keys.size == values.size
  output = IO::Memory.new
  keys.each_with_index do |key, index|
    append_u64_le(output, key)
    append_nullable_bfloat16(output, values[index])
  end
  output.to_s
end

def rowbinary_array(keys : Array(UInt64), values : Array(Array(UInt16))) : String
  raise "Array(BFloat16) fixture lengths differ" unless keys.size == values.size
  output = IO::Memory.new
  keys.each_with_index do |key, index|
    append_u64_le(output, key)
    row = values[index]
    append_varuint(output, row.size.to_u64)
    row.each { |bits| append_bfloat16_le(output, bits) }
  end
  output.to_s
end

def rowbinary_nullable_array(keys : Array(UInt64), values : Array(Array(UInt16?))) : String
  raise "Array(Nullable(BFloat16)) fixture lengths differ" unless keys.size == values.size
  output = IO::Memory.new
  keys.each_with_index do |key, index|
    append_u64_le(output, key)
    row = values[index]
    append_varuint(output, row.size.to_u64)
    row.each { |bits| append_nullable_bfloat16(output, bits) }
  end
  output.to_s
end

def full_stock_rowbinary : String
  output = IO::Memory.new
  W49_KEYS.each_with_index do |key, index|
    append_u64_le(output, key)
    append_bfloat16_le(output, W49_SCALAR[index])
    append_nullable_bfloat16(output, W49_MAYBE[index])
    append_varuint(output, W49_ARRAY[index].size.to_u64)
    W49_ARRAY[index].each { |bits| append_bfloat16_le(output, bits) }
    append_varuint(output, W49_NULLABLE_ARRAY[index].size.to_u64)
    W49_NULLABLE_ARRAY[index].each { |bits| append_nullable_bfloat16(output, bits) }
  end
  output.to_s
end

def key_range_indices : Array(Int32)
  W49_KEYS.each_with_index.compact_map { |key, index| index if key >= 2_u64 && key < 9_u64 }.to_a
end

def subset_keys(indices : Array(Int32)) : Array(UInt64)
  indices.map { |index| W49_KEYS[index] }
end

def subset_values(values : Array(UInt16), indices : Array(Int32)) : Array(UInt16)
  indices.map { |index| values[index] }
end

def subset_nullable_values(values : Array(UInt16?), indices : Array(Int32)) : Array(UInt16?)
  indices.map { |index| values[index] }
end

def subset_array_values(values : Array(Array(UInt16)), indices : Array(Int32)) : Array(Array(UInt16))
  indices.map { |index| values[index] }
end

def subset_nullable_array_values(values : Array(Array(UInt16?)), indices : Array(Int32)) : Array(Array(UInt16?))
  indices.map { |index| values[index] }
end

def assert_bytes(actual : String, expected : String, label : String) : Nil
  return if actual.to_slice == expected.to_slice
  raise "#{label} RowBinary mismatch: got #{actual.bytesize} bytes, expected #{expected.bytesize}"
end

def active_part_path(binary : String, store : String, table : String) : String
  path = run_clickhouse(binary, store, "SELECT path FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw").strip
  raise "#{table}: active part path missing or ambiguous" if path.empty? || path.includes?('\n')
  path
end

def attach_part(binary : String, store : String, table : String, part : String) : String
  data_path = run_clickhouse(binary, store, "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw").strip
  raise "#{table}: data path missing" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  run_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  active_path = active_part_path(binary, store, table)
  result = run_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "#{table}: reverse ATTACH/CHECK TABLE failed: #{result.inspect}" unless result == "all_1_1_0\t1"
  active_path
end

def check_stock(binary : String, store : String) : Nil
  table = "w49_stock_attach"
  create_table(binary, store, table,
    "`scalar` BFloat16, `maybe` Nullable(BFloat16), `plain` Array(BFloat16), `nullable_array` Array(Nullable(BFloat16))")
  attach_part(binary, store, table, W49_FIXTURE)
  full = run_clickhouse(binary, store, "SELECT pk, scalar, maybe, plain, nullable_array FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  assert_bytes(full, full_stock_rowbinary, "stock fixture full five-column")

  indices = key_range_indices
  keys = subset_keys(indices)
  range_expected = IO::Memory.new
  indices.each do |index|
    append_u64_le(range_expected, W49_KEYS[index])
    append_bfloat16_le(range_expected, W49_SCALAR[index])
    append_nullable_bfloat16(range_expected, W49_MAYBE[index])
    append_varuint(range_expected, W49_ARRAY[index].size.to_u64)
    W49_ARRAY[index].each { |bits| append_bfloat16_le(range_expected, bits) }
    append_varuint(range_expected, W49_NULLABLE_ARRAY[index].size.to_u64)
    W49_NULLABLE_ARRAY[index].each { |bits| append_nullable_bfloat16(range_expected, bits) }
  end
  ranged = run_clickhouse(binary, store, "SELECT pk, scalar, maybe, plain, nullable_array FROM default.#{table} WHERE pk >= 2 AND pk < 9 ORDER BY pk FORMAT RowBinary")
  assert_bytes(ranged, range_expected.to_s, "stock fixture key-range [2,9)")
  puts "PASS stock five-column fixture: reverse ATTACH/CHECK, exact full/key RowBinary"
end

def check_writer(binary : String, store : String, root : String, table : String, type_name : String, part : String, expected_full : String, expected_range : String) : Nil
  create_table(binary, store, table, "`payload` #{type_name}")
  attach_part(binary, store, table, part)
  full = run_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  assert_bytes(full, expected_full, "Crystal writer #{type_name} full")
  ranged = run_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} WHERE pk >= 2 AND pk < 9 ORDER BY pk FORMAT RowBinary")
  assert_bytes(ranged, expected_range, "Crystal writer #{type_name} key-range")
  puts "PASS Crystal writer #{type_name}: reverse ATTACH/CHECK, exact full/key RowBinary"
end

binary = ENV.fetch("CLICKHOUSE_BIN")
root = ENV.fetch("TMP_ROOT")
store = File.join(root, "clickhouse-store")
range_indices = key_range_indices
range_keys = subset_keys(range_indices)

check_stock(binary, store)

scalar_values = W49_SCALAR.map { |bits| CrystalClick::BFloat16Value.new(bits) }
nullable_values = W49_MAYBE.map { |bits| bits.try { |value| CrystalClick::BFloat16Value.new(value) } }
array_values = W49_ARRAY.map { |row| row.map { |bits| CrystalClick::BFloat16Value.new(bits) } }
nullable_array_values = W49_NULLABLE_ARRAY.map do |row|
  row.map { |bits| bits.try { |value| CrystalClick::BFloat16Value.new(value) } }
end
keys = W49_KEYS.to_unsafe.to_slice(W49_KEYS.size)

scalar_part = CrystalClick::WidePartWriter.write_uint64_bfloat16_pair(
  File.join(root, "writer-scalar"), "pk", keys, "payload", scalar_values.to_unsafe.to_slice(scalar_values.size), 2
)
nullable_part = CrystalClick::WidePartWriter.write_uint64_nullable_bfloat16_pair(
  File.join(root, "writer-nullable"), "pk", keys, "payload", nullable_values.to_unsafe.to_slice(nullable_values.size), 2
)
array_part = CrystalClick::WidePartWriter.write_uint64_array_bfloat16_pair(
  File.join(root, "writer-array"), "pk", keys, "payload", array_values.to_unsafe.to_slice(array_values.size), 2
)
nullable_array_part = CrystalClick::WidePartWriter.write_uint64_array_nullable_bfloat16_pair(
  File.join(root, "writer-nullable-array"), "pk", keys, "payload", nullable_array_values.to_unsafe.to_slice(nullable_array_values.size), 2
)

check_writer(binary, store, root, "w49_writer_scalar", "BFloat16", scalar_part,
  rowbinary_scalar(W49_KEYS, W49_SCALAR), rowbinary_scalar(range_keys, subset_values(W49_SCALAR, range_indices)))
check_writer(binary, store, root, "w49_writer_nullable", "Nullable(BFloat16)", nullable_part,
  rowbinary_nullable(W49_KEYS, W49_MAYBE), rowbinary_nullable(range_keys, subset_nullable_values(W49_MAYBE, range_indices)))
check_writer(binary, store, root, "w49_writer_array", "Array(BFloat16)", array_part,
  rowbinary_array(W49_KEYS, W49_ARRAY), rowbinary_array(range_keys, subset_array_values(W49_ARRAY, range_indices)))
check_writer(binary, store, root, "w49_writer_nullable_array", "Array(Nullable(BFloat16))", nullable_array_part,
  rowbinary_nullable_array(W49_KEYS, W49_NULLABLE_ARRAY), rowbinary_nullable_array(range_keys, subset_nullable_array_values(W49_NULLABLE_ARRAY, range_indices)))

puts "PASS BFloat16 W49 stock/Crystal differential oracle on ClickHouse #{run_clickhouse(binary, store, "SELECT version()").strip}"
CRYSTAL

printf 'PASS W49 BFloat16 differential oracle on ClickHouse %s\n' "$ACTUAL_VERSION"
