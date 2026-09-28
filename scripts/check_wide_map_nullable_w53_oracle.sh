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
bash "$ROOT/scripts/verify_stock_wide_map_nullable_w53_fixture.sh"

TMP_ROOT="$(mktemp -d /private/tmp/crystal-click-map-nullable-w53-oracle.XXXXXX)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT
cd "$ROOT"
export CLICKHOUSE_BIN TMP_ROOT
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache"
mkdir -p "$CRYSTAL_CACHE_DIR"

crystal run --link-flags='-fuse-ld=ld' --stdin-filename "$ROOT/scripts/check_wide_map_nullable_w53_oracle.cr" <<'CRYSTAL'
require "file_utils"
require "../src/crystal_click"

W53_ORACLE_FIXTURE = File.expand_path("../test/fixtures/public/wide_map_nullable_w53/part", __DIR__)
W53_ORACLE_KEYS = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64]
W53_ORACLE_BINARY_KEY = String.new(Bytes[0x41_u8, 0_u8, 0x42_u8, 0xff_u8])
W53_ORACLE_MAP_U64 = [
  [] of Tuple(UInt64, UInt64?),
  [{7_u64, nil}, {7_u64, 0_u64}] of Tuple(UInt64, UInt64?),
  [{UInt64::MAX, 42_u64}, {0_u64, nil}] of Tuple(UInt64, UInt64?),
  [{1_u64, 0_u64}] of Tuple(UInt64, UInt64?),
  [] of Tuple(UInt64, UInt64?),
  [{5_u64, nil}, {5_u64, UInt64::MAX}] of Tuple(UInt64, UInt64?),
  [{9_u64, 0_u64}] of Tuple(UInt64, UInt64?),
] of Array(Tuple(UInt64, UInt64?))
W53_ORACLE_MAP_STRING = [
  [] of Tuple(String, UInt64?),
  [{"dup", nil}, {"dup", 0_u64}] of Tuple(String, UInt64?),
  [{W53_ORACLE_BINARY_KEY, UInt64::MAX}, {"雪", nil}] of Tuple(String, UInt64?),
  [{"empty", 0_u64}, {"empty", nil}] of Tuple(String, UInt64?),
  [] of Tuple(String, UInt64?),
  [{"tail", nil}, {"", 0_u64}] of Tuple(String, UInt64?),
  [{"end", 0_u64}] of Tuple(String, UInt64?),
] of Array(Tuple(String, UInt64?))
W53_ORACLE_MAP_STRING_BLANK_KEYS = [
  [{"", nil}] of Tuple(String, UInt64?),
  [{"", 0_u64}] of Tuple(String, UInt64?),
  [{"", nil}, {"", 0_u64}] of Tuple(String, UInt64?),
  [] of Tuple(String, UInt64?),
  [{"", UInt64::MAX}] of Tuple(String, UInt64?),
  [{"", nil}] of Tuple(String, UInt64?),
  [{"", 0_u64}] of Tuple(String, UInt64?),
] of Array(Tuple(String, UInt64?))
W53_ORACLE_RANGE_ROWS = [1_i32, 2_i32, 3_i32, 4_i32, 5_i32]

def run_clickhouse(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse query failed (status #{status.exit_code}): #{query}" unless status.success?
  output.to_s
end

def append_u64_le(io : IO, value : UInt64) : Nil
  8.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
end

def append_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

def append_string(io : IO, value : String) : Nil
  append_varuint(io, value.bytesize.to_u64)
  io.write(value.to_slice)
end

def append_nullable_u64(io : IO, value : UInt64?) : Nil
  if value.nil?
    io.write_byte(1_u8)
  else
    io.write_byte(0_u8)
    append_u64_le(io, value)
  end
end

def append_map_u64_nullable_u64(io : IO, entries : Array(Tuple(UInt64, UInt64?))) : Nil
  append_varuint(io, entries.size.to_u64)
  entries.each do |key, value|
    append_u64_le(io, key)
    append_nullable_u64(io, value)
  end
end

def append_map_string_nullable_u64(io : IO, entries : Array(Tuple(String, UInt64?))) : Nil
  append_varuint(io, entries.size.to_u64)
  entries.each do |key, value|
    append_string(io, key)
    append_nullable_u64(io, value)
  end
end

def rowbinary_map_u64_nullable_u64(keys : Array(UInt64), values : Array(Array(Tuple(UInt64, UInt64?))), indexes : Array(Int32)) : String
  raise "UInt64-key Map RowBinary input lengths differ" unless keys.size == values.size
  io = IO::Memory.new
  indexes.each do |index|
    append_u64_le(io, keys[index])
    append_map_u64_nullable_u64(io, values[index])
  end
  io.to_s
end

def rowbinary_map_string_nullable_u64(keys : Array(UInt64), values : Array(Array(Tuple(String, UInt64?))), indexes : Array(Int32)) : String
  raise "String-key Map RowBinary input lengths differ" unless keys.size == values.size
  io = IO::Memory.new
  indexes.each do |index|
    append_u64_le(io, keys[index])
    append_map_string_nullable_u64(io, values[index])
  end
  io.to_s
end

def rowbinary_stock_fixture : String
  io = IO::Memory.new
  W53_ORACLE_KEYS.each_with_index do |key, index|
    append_u64_le(io, key)
    append_map_u64_nullable_u64(io, W53_ORACLE_MAP_U64[index])
    append_map_string_nullable_u64(io, W53_ORACLE_MAP_STRING[index])
  end
  io.to_s
end

def assert_bytes(actual : String, expected : String, label : String) : Nil
  return if actual.to_slice == expected.to_slice
  got = actual.to_slice[0, Math.min(actual.bytesize, 40)].hexstring
  wanted = expected.to_slice[0, Math.min(expected.bytesize, 40)].hexstring
  raise "#{label} RowBinary mismatch (got #{actual.bytesize} bytes / #{got}; expected #{expected.bytesize} bytes / #{wanted})"
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

def attach_part(binary : String, store : String, table : String, part : String) : Nil
  data_path = run_clickhouse(binary, store,
    "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw").strip
  raise "#{table}: ClickHouse returned no data path" if data_path.empty? || data_path.includes?('\n')
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  run_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  result = run_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "#{table}: ATTACH/CHECK TABLE failed: #{result.inspect}" unless result == "all_1_1_0\t1"
  nil
end

def assert_metadata(binary : String, store : String, table : String, type_name : String) : Nil
  actual = run_clickhouse(binary, store,
    "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw")
  expected = "pk UInt64\npayload #{type_name}\n"
  raise "#{table}: exact system.columns mismatch: #{actual.inspect}" unless actual == expected
  create = run_clickhouse(binary, store, "SHOW CREATE TABLE default.#{table} FORMAT TSVRaw").gsub(/\s+/, "")
  raise "#{table}: SHOW CREATE type mismatch" unless create.includes?(type_name.gsub(/\s+/, ""))
  nil
end

def verify_writer(binary : String, store : String, table : String, type_name : String, part : String, full_expected : String, range_expected : String) : Nil
  create_table(binary, store, table, "`payload` #{type_name}")
  attach_part(binary, store, table, part)
  assert_metadata(binary, store, table, type_name)
  full = run_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  assert_bytes(full, full_expected, "Crystal writer #{type_name} full")
  ranged = run_clickhouse(binary, store,
    "SELECT pk, payload FROM default.#{table} WHERE pk >= 2 AND pk < 12 ORDER BY pk FORMAT RowBinary")
  assert_bytes(ranged, range_expected, "Crystal writer #{type_name} key-range")
  puts "PASS Crystal writer #{type_name}: ATTACH/CHECK, exact metadata, full and key-range RowBinary"
end

binary = ENV.fetch("CLICKHOUSE_BIN")
root = ENV.fetch("TMP_ROOT")
store = File.join(root, "clickhouse-store")
all_indexes = (0...W53_ORACLE_KEYS.size).map(&.to_i32)

create_table(binary, store, "w53_stock", "`map_u64` Map(UInt64, Nullable(UInt64)), `map_string` Map(String, Nullable(UInt64))")
attach_part(binary, store, "w53_stock", W53_ORACLE_FIXTURE)
stock_columns = run_clickhouse(binary, store,
  "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='w53_stock' ORDER BY position FORMAT TSVRaw")
raise "stock fixture exact system.columns mismatch: #{stock_columns.inspect}" unless stock_columns ==
  "pk UInt64\nmap_u64 Map(UInt64, Nullable(UInt64))\nmap_string Map(String, Nullable(UInt64))\n"
stock = run_clickhouse(binary, store, "SELECT pk, map_u64, map_string FROM default.w53_stock ORDER BY pk FORMAT RowBinary")
assert_bytes(stock, rowbinary_stock_fixture, "stock W53 fixture full")
stock_range = run_clickhouse(binary, store,
  "SELECT pk, map_u64, map_string FROM default.w53_stock WHERE pk >= 2 AND pk < 12 ORDER BY pk FORMAT RowBinary")
expected_stock_range = IO::Memory.new
W53_ORACLE_RANGE_ROWS.each do |index|
  append_u64_le(expected_stock_range, W53_ORACLE_KEYS[index])
  append_map_u64_nullable_u64(expected_stock_range, W53_ORACLE_MAP_U64[index])
  append_map_string_nullable_u64(expected_stock_range, W53_ORACLE_MAP_STRING[index])
end
assert_bytes(stock_range, expected_stock_range.to_s, "stock W53 fixture key-range")
puts "PASS stock W53 fixture: ATTACH/CHECK, exact columns, full and key-range independent RowBinary"

u64_part = CrystalClick::WidePartWriter.write_uint64_map_uint64_nullable_uint64_pair(
  File.join(root, "writer-map-u64-nullable"), "pk",
  W53_ORACLE_KEYS.to_unsafe.to_slice(W53_ORACLE_KEYS.size), "payload",
  W53_ORACLE_MAP_U64.to_unsafe.to_slice(W53_ORACLE_MAP_U64.size), rows_per_mark: 2
)
string_part = CrystalClick::WidePartWriter.write_uint64_map_string_nullable_uint64_pair(
  File.join(root, "writer-map-string-nullable"), "pk",
  W53_ORACLE_KEYS.to_unsafe.to_slice(W53_ORACLE_KEYS.size), "payload",
  W53_ORACLE_MAP_STRING.to_unsafe.to_slice(W53_ORACLE_MAP_STRING.size), rows_per_mark: 2
)
blank_string_part = CrystalClick::WidePartWriter.write_uint64_map_string_nullable_uint64_pair(
  File.join(root, "writer-map-string-nullable-blank-keys"), "pk",
  W53_ORACLE_KEYS.to_unsafe.to_slice(W53_ORACLE_KEYS.size), "payload",
  W53_ORACLE_MAP_STRING_BLANK_KEYS.to_unsafe.to_slice(W53_ORACLE_MAP_STRING_BLANK_KEYS.size), rows_per_mark: 2
)
verify_writer(binary, store, "w53_writer_u64", "Map(UInt64, Nullable(UInt64))", u64_part,
  rowbinary_map_u64_nullable_u64(W53_ORACLE_KEYS, W53_ORACLE_MAP_U64, all_indexes),
  rowbinary_map_u64_nullable_u64(W53_ORACLE_KEYS, W53_ORACLE_MAP_U64, W53_ORACLE_RANGE_ROWS))
verify_writer(binary, store, "w53_writer_string", "Map(String, Nullable(UInt64))", string_part,
  rowbinary_map_string_nullable_u64(W53_ORACLE_KEYS, W53_ORACLE_MAP_STRING, all_indexes),
  rowbinary_map_string_nullable_u64(W53_ORACLE_KEYS, W53_ORACLE_MAP_STRING, W53_ORACLE_RANGE_ROWS))
raise "blank String keys unexpectedly produced raw key bytes" unless
  File.size(File.join(blank_string_part, "#{CrystalClick::StreamName.hash("payload%2Ekeys")}.bin")) == 0
verify_writer(binary, store, "w53_writer_string_blank_keys", "Map(String, Nullable(UInt64))", blank_string_part,
  rowbinary_map_string_nullable_u64(W53_ORACLE_KEYS, W53_ORACLE_MAP_STRING_BLANK_KEYS, all_indexes),
  rowbinary_map_string_nullable_u64(W53_ORACLE_KEYS, W53_ORACLE_MAP_STRING_BLANK_KEYS, W53_ORACLE_RANGE_ROWS))

empty_u64 = Array.new(W53_ORACLE_KEYS.size) { [] of Tuple(UInt64, UInt64?) }
empty_string = Array.new(W53_ORACLE_KEYS.size) { [] of Tuple(String, UInt64?) }
empty_u64_part = CrystalClick::WidePartWriter.write_uint64_map_uint64_nullable_uint64_pair(
  File.join(root, "writer-map-u64-nullable-empty"), "pk",
  W53_ORACLE_KEYS.to_unsafe.to_slice(W53_ORACLE_KEYS.size), "payload",
  empty_u64.to_unsafe.to_slice(empty_u64.size), rows_per_mark: 2
)
empty_string_part = CrystalClick::WidePartWriter.write_uint64_map_string_nullable_uint64_pair(
  File.join(root, "writer-map-string-nullable-empty"), "pk",
  W53_ORACLE_KEYS.to_unsafe.to_slice(W53_ORACLE_KEYS.size), "payload",
  empty_string.to_unsafe.to_slice(empty_string.size), rows_per_mark: 2
)
verify_writer(binary, store, "w53_writer_u64_empty", "Map(UInt64, Nullable(UInt64))", empty_u64_part,
  rowbinary_map_u64_nullable_u64(W53_ORACLE_KEYS, empty_u64, all_indexes),
  rowbinary_map_u64_nullable_u64(W53_ORACLE_KEYS, empty_u64, W53_ORACLE_RANGE_ROWS))
verify_writer(binary, store, "w53_writer_string_empty", "Map(String, Nullable(UInt64))", empty_string_part,
  rowbinary_map_string_nullable_u64(W53_ORACLE_KEYS, empty_string, all_indexes),
  rowbinary_map_string_nullable_u64(W53_ORACLE_KEYS, empty_string, W53_ORACLE_RANGE_ROWS))
CRYSTAL
