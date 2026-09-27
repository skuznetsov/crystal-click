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
bash "$ROOT/scripts/verify_stock_wide_time_w50_fixture.sh"

TMP_ROOT="$(mktemp -d /private/tmp/crystal-click-time-w50-oracle.XXXXXX)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT
cd "$ROOT"
export CLICKHOUSE_BIN TMP_ROOT
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache"
mkdir -p "$CRYSTAL_CACHE_DIR"

crystal run --link-flags='-fuse-ld=ld' --stdin-filename "$ROOT/scripts/check_wide_time_w50_oracle.cr" <<'CRYSTAL'
require "file_utils"
require "../src/crystal_click"

W50_KEYS = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64]
W50_RANGE_INDEXES = [1, 2, 3, 4, 5]
W50_TIME = [-3723_i32, 0_i32, 1_i32, 59_i32, 60_i32, 52_225_i32, -1_i32]
W50_NULLABLE_TIME = [nil, -3723_i32.as(Int32?), 0_i32, 1_i32, nil, 3600_i32, -1_i32] of Int32?
W50_ARRAY_TIME = [
  [] of Int32, [-1_i32, 0_i32, 1_i32], [52_225_i32], [] of Int32,
  [-2_i32, 59_i32], [3600_i32], [] of Int32,
] of Array(Int32)
W50_ARRAY_NULLABLE_TIME = [
  [] of Int32?, [nil, -1_i32.as(Int32?), 0_i32] of Int32?,
  [nil, nil] of Int32?, [] of Int32?, [59_i32.as(Int32?)],
  [nil, 1_i32.as(Int32?), nil] of Int32?, [] of Int32?,
] of Array(Int32?)
W50_TIME64_0 = [-1_i64, 0_i64, 1_i64, 59_i64, 3600_i64, 3600_i64, -3723_i64]
W50_TIME64_3 = [-1234_i64, 0_i64, 1234_i64, -1_i64, 59_123_i64, 3_600_999_i64, -3_723_456_i64]
W50_TIME64_9 = [
  -1_234_567_891_i64, 0_i64, 1_234_567_891_i64, -1_i64,
  59_123_456_789_i64, 3_600_999_999_999_i64, -3_723_456_789_123_i64,
]
W50_NULLABLE_TIME64_3 = [nil, -1234_i64.as(Int64?), 0_i64, 1234_i64, nil, 3_600_999_i64, -3_723_456_i64] of Int64?
W50_ARRAY_TIME64_3 = [
  [] of Int64, [-1234_i64, 1_i64, 1234_i64], [59_123_i64], [] of Int64,
  [-1_i64, 0_i64], [1234_i64], [] of Int64,
] of Array(Int64)
W50_ARRAY_NULLABLE_TIME64_3 = [
  [] of Int64?, [nil, -1234_i64.as(Int64?), 1_i64] of Int64?,
  [nil, nil] of Int64?, [] of Int64?, [59_123_i64.as(Int64?)],
  [nil, 1234_i64.as(Int64?), nil] of Int64?, [] of Int64?,
] of Array(Int64?)
W50_FIXTURE = File.expand_path("../test/fixtures/public/wide_time_w50/part", __DIR__)

def run_clickhouse(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse query failed (status #{status.exit_code}): #{query}" unless status.success?
  output.to_s
end

def time_columns : String
  "`t` Time, `nt` Nullable(Time), `a` Array(Time), `an` Array(Nullable(Time)), " +
    "`t64_0` Time64(0), `t64_3` Time64(3), `t64_9` Time64(9), " +
    "`nt64_3` Nullable(Time64(3)), `a64_3` Array(Time64(3)), " +
    "`an64_3` Array(Nullable(Time64(3)))"
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
      index_granularity_bytes = 10485760,
      enable_mixed_granularity_parts = 1,
      min_rows_for_wide_part = 0,
      min_bytes_for_wide_part = 0,
      ratio_of_defaults_for_sparse_serialization = 1.0,
      compress_marks = 0,
      min_compress_block_size = 0,
      max_compress_block_size = 4096,
      default_compression_codec = 'LZ4';
  SQL
  nil
end

def append_u64_le(io : IO, value : UInt64) : Nil
  8.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
end

def append_i32_le(io : IO, value : Int32) : Nil
  4.times { |index| io.write_byte(((value.unsafe_as(UInt32) >> (index * 8)) & 0xff_u32).to_u8) }
end

def append_i64_le(io : IO, value : Int64) : Nil
  8.times { |index| io.write_byte(((value.unsafe_as(UInt64) >> (index * 8)) & 0xff_u64).to_u8) }
end

def append_varuint(io : IO, value : UInt64) : Nil
  rest = value
  while rest >= 0x80_u64
    io.write_byte(((rest & 0x7f_u64) | 0x80_u64).to_u8)
    rest >>= 7
  end
  io.write_byte(rest.to_u8)
end

def append_nullable_i32(io : IO, value : Int32?) : Nil
  if nested = value
    io.write_byte(0_u8)
    append_i32_le(io, nested)
  else
    io.write_byte(1_u8)
  end
end

def append_nullable_i64(io : IO, value : Int64?) : Nil
  if nested = value
    io.write_byte(0_u8)
    append_i64_le(io, nested)
  else
    io.write_byte(1_u8)
  end
end

def append_array_i32(io : IO, values : Array(Int32)) : Nil
  append_varuint(io, values.size.to_u64)
  values.each { |value| append_i32_le(io, value) }
end

def append_array_nullable_i32(io : IO, values : Array(Int32?)) : Nil
  append_varuint(io, values.size.to_u64)
  values.each { |value| append_nullable_i32(io, value) }
end

def append_array_i64(io : IO, values : Array(Int64)) : Nil
  append_varuint(io, values.size.to_u64)
  values.each { |value| append_i64_le(io, value) }
end

def append_array_nullable_i64(io : IO, values : Array(Int64?)) : Nil
  append_varuint(io, values.size.to_u64)
  values.each { |value| append_nullable_i64(io, value) }
end

def rowbinary(keys : Array(UInt64), values : Array(Int32)) : String
  raise "Time RowBinary lengths differ" unless keys.size == values.size
  io = IO::Memory.new
  keys.each_with_index { |key, index| append_u64_le(io, key); append_i32_le(io, values[index]) }
  io.to_s
end

def rowbinary(keys : Array(UInt64), values : Array(Int32?)) : String
  raise "Nullable(Time) RowBinary lengths differ" unless keys.size == values.size
  io = IO::Memory.new
  keys.each_with_index { |key, index| append_u64_le(io, key); append_nullable_i32(io, values[index]) }
  io.to_s
end

def rowbinary(keys : Array(UInt64), values : Array(Array(Int32))) : String
  raise "Array(Time) RowBinary lengths differ" unless keys.size == values.size
  io = IO::Memory.new
  keys.each_with_index { |key, index| append_u64_le(io, key); append_array_i32(io, values[index]) }
  io.to_s
end

def rowbinary(keys : Array(UInt64), values : Array(Array(Int32?))) : String
  raise "Array(Nullable(Time)) RowBinary lengths differ" unless keys.size == values.size
  io = IO::Memory.new
  keys.each_with_index { |key, index| append_u64_le(io, key); append_array_nullable_i32(io, values[index]) }
  io.to_s
end

def rowbinary(keys : Array(UInt64), values : Array(Int64)) : String
  raise "Time64 RowBinary lengths differ" unless keys.size == values.size
  io = IO::Memory.new
  keys.each_with_index { |key, index| append_u64_le(io, key); append_i64_le(io, values[index]) }
  io.to_s
end

def rowbinary(keys : Array(UInt64), values : Array(Int64?)) : String
  raise "Nullable(Time64) RowBinary lengths differ" unless keys.size == values.size
  io = IO::Memory.new
  keys.each_with_index { |key, index| append_u64_le(io, key); append_nullable_i64(io, values[index]) }
  io.to_s
end

def rowbinary(keys : Array(UInt64), values : Array(Array(Int64))) : String
  raise "Array(Time64) RowBinary lengths differ" unless keys.size == values.size
  io = IO::Memory.new
  keys.each_with_index { |key, index| append_u64_le(io, key); append_array_i64(io, values[index]) }
  io.to_s
end

def rowbinary(keys : Array(UInt64), values : Array(Array(Int64?))) : String
  raise "Array(Nullable(Time64)) RowBinary lengths differ" unless keys.size == values.size
  io = IO::Memory.new
  keys.each_with_index { |key, index| append_u64_le(io, key); append_array_nullable_i64(io, values[index]) }
  io.to_s
end

def full_stock_rowbinary : String
  io = IO::Memory.new
  W50_KEYS.each_with_index do |key, index|
    append_u64_le(io, key)
    append_i32_le(io, W50_TIME[index])
    append_nullable_i32(io, W50_NULLABLE_TIME[index])
    append_array_i32(io, W50_ARRAY_TIME[index])
    append_array_nullable_i32(io, W50_ARRAY_NULLABLE_TIME[index])
    append_i64_le(io, W50_TIME64_0[index])
    append_i64_le(io, W50_TIME64_3[index])
    append_i64_le(io, W50_TIME64_9[index])
    append_nullable_i64(io, W50_NULLABLE_TIME64_3[index])
    append_array_i64(io, W50_ARRAY_TIME64_3[index])
    append_array_nullable_i64(io, W50_ARRAY_NULLABLE_TIME64_3[index])
  end
  io.to_s
end

def range_keys : Array(UInt64)
  W50_RANGE_INDEXES.map { |index| W50_KEYS[index] }
end

def range_values(values : Array(T)) : Array(T) forall T
  W50_RANGE_INDEXES.map { |index| values[index] }
end

def assert_bytes(actual : String, expected : String, label : String) : Nil
  return if actual.to_slice == expected.to_slice
  raise "#{label} RowBinary mismatch: got #{actual.bytesize} bytes, expected #{expected.bytesize}"
end

def assert_argument_error(label : String, &block : ->) : Nil
  begin
    yield
  rescue ArgumentError
    return nil
  end
  raise "#{label}: expected ArgumentError"
end

def data_path(binary : String, store : String, table : String) : String
  path = run_clickhouse(binary, store, "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw").strip
  raise "#{table}: data path missing" if path.empty? || path.includes?('\n')
  path
end

def attach_part(binary : String, store : String, table : String, part : String) : Nil
  detached = File.join(data_path(binary, store, table), "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  run_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  result = run_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "#{table}: reverse ATTACH/CHECK TABLE failed: #{result.inspect}" unless result == "all_1_1_0\t1"
  nil
end

def verify_stock(binary : String, store : String) : Nil
  table = "w50_stock_fixture"
  create_table(binary, store, table, time_columns)
  attach_part(binary, store, table, W50_FIXTURE)

  expected_columns =
    "pk UInt64\n" +
    "t Time\nnt Nullable(Time)\na Array(Time)\nan Array(Nullable(Time))\n" +
    "t64_0 Time64(0)\nt64_3 Time64(3)\nt64_9 Time64(9)\n" +
    "nt64_3 Nullable(Time64(3))\na64_3 Array(Time64(3))\n" +
    "an64_3 Array(Nullable(Time64(3)))\n"
  actual_columns = run_clickhouse(binary, store,
    "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw")
  raise "stock fixture metadata types differ:\n#{actual_columns.inspect}" unless actual_columns == expected_columns
  show_create = run_clickhouse(binary, store, "SHOW CREATE TABLE default.#{table} FORMAT TSVRaw")
  raise "SHOW CREATE lost Time64(0)" unless show_create.includes?("`t64_0` Time64(0)")

  query = "SELECT pk, t, nt, a, an, t64_0, t64_3, t64_9, nt64_3, a64_3, an64_3 FROM default.#{table} ORDER BY pk FORMAT RowBinary"
  assert_bytes(run_clickhouse(binary, store, query), full_stock_rowbinary, "stock fixture full eleven-column")

  ranged = run_clickhouse(binary, store,
    "SELECT pk, t, nt, a, an, t64_0, t64_3, t64_9, nt64_3, a64_3, an64_3 FROM default.#{table} WHERE pk >= 2 AND pk < 12 ORDER BY pk FORMAT RowBinary")
  range = IO::Memory.new
  W50_RANGE_INDEXES.each do |index|
    append_u64_le(range, W50_KEYS[index])
    append_i32_le(range, W50_TIME[index])
    append_nullable_i32(range, W50_NULLABLE_TIME[index])
    append_array_i32(range, W50_ARRAY_TIME[index])
    append_array_nullable_i32(range, W50_ARRAY_NULLABLE_TIME[index])
    append_i64_le(range, W50_TIME64_0[index])
    append_i64_le(range, W50_TIME64_3[index])
    append_i64_le(range, W50_TIME64_9[index])
    append_nullable_i64(range, W50_NULLABLE_TIME64_3[index])
    append_array_i64(range, W50_ARRAY_TIME64_3[index])
    append_array_nullable_i64(range, W50_ARRAY_NULLABLE_TIME64_3[index])
  end
  assert_bytes(ranged, range.to_s, "stock fixture key-range [2,12)")
  puts "PASS stock W50 fixture: reverse ATTACH/CHECK, exact metadata including Time64(0), full and key-range RowBinary"
end

def verify_writer(binary : String, store : String, table : String, type_name : String, part : String, expected_full : String, expected_range : String) : Nil
  create_table(binary, store, table, "`payload` #{type_name}")
  attach_part(binary, store, table, part)
  show_create = run_clickhouse(binary, store, "SHOW CREATE TABLE default.#{table} FORMAT TSVRaw")
  raise "#{table}: SHOW CREATE lost exact type #{type_name}" unless show_create.includes?("`payload` #{type_name}")

  full = run_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  assert_bytes(full, expected_full, "Crystal writer #{type_name} full")
  ranged = run_clickhouse(binary, store,
    "SELECT pk, payload FROM default.#{table} WHERE pk >= 2 AND pk < 12 ORDER BY pk FORMAT RowBinary")
  assert_bytes(ranged, expected_range, "Crystal writer #{type_name} key-range")
  puts "PASS Crystal writer #{type_name}: reverse ATTACH/CHECK and exact full/key-range RowBinary"
end

binary = ENV.fetch("CLICKHOUSE_BIN")
root = ENV.fetch("TMP_ROOT")
store = File.join(root, "clickhouse-store")
keys = W50_KEYS.to_unsafe.to_slice(W50_KEYS.size)
range_keys = range_keys()
verify_stock(binary, store)

time_part = CrystalClick::WidePartWriter.write_uint64_time_pair(
  File.join(root, "writer-time"), "pk", keys, "payload", W50_TIME.to_unsafe.to_slice(W50_TIME.size), 2
)
nullable_time_part = CrystalClick::WidePartWriter.write_uint64_nullable_time_pair(
  File.join(root, "writer-nullable-time"), "pk", keys, "payload", W50_NULLABLE_TIME.to_unsafe.to_slice(W50_NULLABLE_TIME.size), 2
)
array_time_part = CrystalClick::WidePartWriter.write_uint64_array_time_pair(
  File.join(root, "writer-array-time"), "pk", keys, "payload", W50_ARRAY_TIME.to_unsafe.to_slice(W50_ARRAY_TIME.size), 2
)
array_nullable_time_part = CrystalClick::WidePartWriter.write_uint64_array_nullable_time_pair(
  File.join(root, "writer-array-nullable-time"), "pk", keys, "payload", W50_ARRAY_NULLABLE_TIME.to_unsafe.to_slice(W50_ARRAY_NULLABLE_TIME.size), 2
)
time64_0_part = CrystalClick::WidePartWriter.write_uint64_time64_pair(
  File.join(root, "writer-time64-p0"), "pk", keys, "payload", W50_TIME64_0.to_unsafe.to_slice(W50_TIME64_0.size), 0, 2
)
time64_3_part = CrystalClick::WidePartWriter.write_uint64_time64_pair(
  File.join(root, "writer-time64-p3"), "pk", keys, "payload", W50_TIME64_3.to_unsafe.to_slice(W50_TIME64_3.size), 3, 2
)
time64_9_part = CrystalClick::WidePartWriter.write_uint64_time64_pair(
  File.join(root, "writer-time64-p9"), "pk", keys, "payload", W50_TIME64_9.to_unsafe.to_slice(W50_TIME64_9.size), 9, 2
)
nullable_time64_part = CrystalClick::WidePartWriter.write_uint64_nullable_time64_pair(
  File.join(root, "writer-nullable-time64"), "pk", keys, "payload", W50_NULLABLE_TIME64_3.to_unsafe.to_slice(W50_NULLABLE_TIME64_3.size), 3, 2
)
array_time64_part = CrystalClick::WidePartWriter.write_uint64_array_time64_pair(
  File.join(root, "writer-array-time64"), "pk", keys, "payload", W50_ARRAY_TIME64_3.to_unsafe.to_slice(W50_ARRAY_TIME64_3.size), 3, 2
)
array_nullable_time64_part = CrystalClick::WidePartWriter.write_uint64_array_nullable_time64_pair(
  File.join(root, "writer-array-nullable-time64"), "pk", keys, "payload", W50_ARRAY_NULLABLE_TIME64_3.to_unsafe.to_slice(W50_ARRAY_NULLABLE_TIME64_3.size), 3, 2
)

verify_writer(binary, store, "w50_writer_time", "Time", time_part,
  rowbinary(W50_KEYS, W50_TIME), rowbinary(range_keys, range_values(W50_TIME)))
verify_writer(binary, store, "w50_writer_nullable_time", "Nullable(Time)", nullable_time_part,
  rowbinary(W50_KEYS, W50_NULLABLE_TIME), rowbinary(range_keys, range_values(W50_NULLABLE_TIME)))
verify_writer(binary, store, "w50_writer_array_time", "Array(Time)", array_time_part,
  rowbinary(W50_KEYS, W50_ARRAY_TIME), rowbinary(range_keys, range_values(W50_ARRAY_TIME)))
verify_writer(binary, store, "w50_writer_array_nullable_time", "Array(Nullable(Time))", array_nullable_time_part,
  rowbinary(W50_KEYS, W50_ARRAY_NULLABLE_TIME), rowbinary(range_keys, range_values(W50_ARRAY_NULLABLE_TIME)))
verify_writer(binary, store, "w50_writer_time64_p0", "Time64(0)", time64_0_part,
  rowbinary(W50_KEYS, W50_TIME64_0), rowbinary(range_keys, range_values(W50_TIME64_0)))
verify_writer(binary, store, "w50_writer_time64_p3", "Time64(3)", time64_3_part,
  rowbinary(W50_KEYS, W50_TIME64_3), rowbinary(range_keys, range_values(W50_TIME64_3)))
verify_writer(binary, store, "w50_writer_time64_p9", "Time64(9)", time64_9_part,
  rowbinary(W50_KEYS, W50_TIME64_9), rowbinary(range_keys, range_values(W50_TIME64_9)))
verify_writer(binary, store, "w50_writer_nullable_time64", "Nullable(Time64(3))", nullable_time64_part,
  rowbinary(W50_KEYS, W50_NULLABLE_TIME64_3), rowbinary(range_keys, range_values(W50_NULLABLE_TIME64_3)))
verify_writer(binary, store, "w50_writer_array_time64", "Array(Time64(3))", array_time64_part,
  rowbinary(W50_KEYS, W50_ARRAY_TIME64_3), rowbinary(range_keys, range_values(W50_ARRAY_TIME64_3)))
verify_writer(binary, store, "w50_writer_array_nullable_time64", "Array(Nullable(Time64(3)))", array_nullable_time64_part,
  rowbinary(W50_KEYS, W50_ARRAY_NULLABLE_TIME64_3), rowbinary(range_keys, range_values(W50_ARRAY_NULLABLE_TIME64_3)))

bad_scale_root = File.join(root, "writer-bad-scale")
Dir.mkdir(bad_scale_root)
[-1_i32, 10_i32].each do |scale|
  destination = File.join(bad_scale_root, "scale-#{scale}")
  assert_argument_error("invalid Time64 scale #{scale}") do
    CrystalClick::WidePartWriter.write_uint64_time64_pair(
      destination, "pk", ([] of UInt64).to_unsafe.to_slice(0), "payload",
      ([] of Int64).to_unsafe.to_slice(0), scale, 1
    )
  end
  raise "invalid Time64 scale #{scale} created output" if File.exists?(destination)
end
raise "invalid Time64 scale validation published output" unless Dir.children(bad_scale_root).empty?

puts "PASS W50 writer precision gate: scales -1 and 10 rejected before output publication"
CRYSTAL
