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
bash "$ROOT/scripts/verify_stock_wide_map_string_w52_fixture.sh"

TMP_ROOT="$(mktemp -d /private/tmp/crystal-click-map-string-w52-oracle.XXXXXX)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT
cd "$ROOT"
export CLICKHOUSE_BIN TMP_ROOT
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache"
mkdir -p "$CRYSTAL_CACHE_DIR"

crystal run --link-flags='-fuse-ld=ld' --stdin-filename "$ROOT/scripts/check_wide_map_string_w52_oracle.cr" <<'CRYSTAL'
require "file_utils"
require "../src/crystal_click"

W52_ORACLE_FIXTURE = File.expand_path("../test/fixtures/public/wide_map_string_w52/part", __DIR__)
W52_ORACLE_KEYS = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64]
W52_ORACLE_BINARY_KEY = String.new(Bytes[0x41_u8, 0_u8, 0x42_u8, 0xff_u8])
W52_ORACLE_LONG_VALUE = "a longer value crosses the row and mark boundary"
W52_ORACLE_MAP_U64 = [
  [] of Tuple(String, UInt64),
  [{"dup", 0_u64}, {"dup", UInt64::MAX}] of Tuple(String, UInt64),
  [{W52_ORACLE_BINARY_KEY, 42_u64}, {"雪", 7_u64}] of Tuple(String, UInt64),
  [{"empty", UInt64::MAX}] of Tuple(String, UInt64),
  [] of Tuple(String, UInt64),
  [{"tail", 8_u64}, {"", 9_u64}] of Tuple(String, UInt64),
  [{"end", 0_u64}] of Tuple(String, UInt64),
] of Array(Tuple(String, UInt64))
W52_ORACLE_MAP_STRING = [
  [] of Tuple(String, String),
  [{"dup", ""}, {"dup", "second"}] of Tuple(String, String),
  [{W52_ORACLE_BINARY_KEY, "binary\0value"}, {"", ""}] of Tuple(String, String),
  [{"empty-value", ""}, {"nonempty-value", W52_ORACLE_LONG_VALUE}] of Tuple(String, String),
  [] of Tuple(String, String),
  [{"tail", "emoji💥"}, {"tail", "second duplicate"}] of Tuple(String, String),
  [{"end", "final"}] of Tuple(String, String),
] of Array(Tuple(String, String))
W52_ORACLE_RANGE_ROWS = [1_i32, 2_i32, 3_i32, 4_i32, 5_i32]

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
  rest = value
  while rest >= 0x80_u64
    io.write_byte(((rest & 0x7f_u64) | 0x80_u64).to_u8)
    rest >>= 7
  end
  io.write_byte(rest.to_u8)
end

def append_string(io : IO, value : String) : Nil
  append_varuint(io, value.bytesize.to_u64)
  io.write(value.to_slice)
end

def append_map_string_uint64(io : IO, entries : Array(Tuple(String, UInt64))) : Nil
  append_varuint(io, entries.size.to_u64)
  entries.each do |key, value|
    append_string(io, key)
    append_u64_le(io, value)
  end
end

def append_map_string_string(io : IO, entries : Array(Tuple(String, String))) : Nil
  append_varuint(io, entries.size.to_u64)
  entries.each do |key, value|
    append_string(io, key)
    append_string(io, value)
  end
end

def rowbinary_map_string_uint64(keys : Array(UInt64), values : Array(Array(Tuple(String, UInt64))), indexes : Array(Int32)) : String
  raise "Map(String, UInt64) RowBinary lengths differ" unless keys.size == values.size
  io = IO::Memory.new
  indexes.each do |index|
    append_u64_le(io, keys[index])
    append_map_string_uint64(io, values[index])
  end
  io.to_s
end

def rowbinary_map_string_string(keys : Array(UInt64), values : Array(Array(Tuple(String, String))), indexes : Array(Int32)) : String
  raise "Map(String, String) RowBinary lengths differ" unless keys.size == values.size
  io = IO::Memory.new
  indexes.each do |index|
    append_u64_le(io, keys[index])
    append_map_string_string(io, values[index])
  end
  io.to_s
end

def rowbinary_stock_fixture : String
  io = IO::Memory.new
  W52_ORACLE_KEYS.each_with_index do |key, index|
    append_u64_le(io, key)
    append_map_string_uint64(io, W52_ORACLE_MAP_U64[index])
    append_map_string_string(io, W52_ORACLE_MAP_STRING[index])
  end
  io.to_s
end

def assert_bytes(actual : String, expected : String, label : String) : Nil
  return if actual.to_slice == expected.to_slice
  raise "#{label} RowBinary mismatch: got #{actual.bytesize} bytes, expected #{expected.bytesize}"
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

def assert_exact_columns(binary : String, store : String, table : String, expected : String) : Nil
  actual = run_clickhouse(binary, store,
    "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw")
  raise "#{table}: exact system.columns type metadata mismatch: #{actual.inspect}" unless actual == expected
  nil
end

def assert_show_create(binary : String, store : String, table : String, declarations : Array(String)) : Nil
  create = run_clickhouse(binary, store, "SHOW CREATE TABLE default.#{table} FORMAT TSVRaw").gsub(/\s+/, "")
  declarations.each do |declaration|
    normalized = declaration.gsub(/\s+/, "")
    raise "#{table}: SHOW CREATE does not contain #{declaration}" unless create.includes?(normalized)
  end
  nil
end

def assert_empty_raw_streams(part : String, streams : Array(String)) : Nil
  streams.each do |stream|
    path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")
    raise "#{stream}: expected zero-byte raw stream, got #{File.size(path)} bytes" unless File.size(path) == 0
  end
  nil
end

def verify_writer(binary : String, store : String, table : String, type_name : String, part : String, full_expected : String, range_expected : String) : Nil
  create_table(binary, store, table, "`payload` #{type_name}")
  attach_part(binary, store, table, part)
  assert_exact_columns(binary, store, table, "pk UInt64\npayload #{type_name}\n")
  assert_show_create(binary, store, table, ["`payload` #{type_name}"])
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

create_table(binary, store, "w52_stock", "`map_u64` Map(String, UInt64), `map_string` Map(String, String)")
attach_part(binary, store, "w52_stock", W52_ORACLE_FIXTURE)
assert_exact_columns(binary, store, "w52_stock",
  "pk UInt64\nmap_u64 Map(String, UInt64)\nmap_string Map(String, String)\n")
assert_show_create(binary, store, "w52_stock", ["`map_u64` Map(String, UInt64)", "`map_string` Map(String, String)"])
stock = run_clickhouse(binary, store, "SELECT pk, map_u64, map_string FROM default.w52_stock ORDER BY pk FORMAT RowBinary")
assert_bytes(stock, rowbinary_stock_fixture, "stock W52 fixture full")
puts "PASS stock W52 fixture: ATTACH/CHECK, exact metadata, independent full RowBinary"

u64_part = CrystalClick::WidePartWriter.write_uint64_map_string_uint64_pair(
  File.join(root, "writer-map-string-u64"), "pk",
  W52_ORACLE_KEYS.to_unsafe.to_slice(W52_ORACLE_KEYS.size), "payload",
  W52_ORACLE_MAP_U64.to_unsafe.to_slice(W52_ORACLE_MAP_U64.size), rows_per_mark: 2
)
string_part = CrystalClick::WidePartWriter.write_uint64_map_string_string_pair(
  File.join(root, "writer-map-string-string"), "pk",
  W52_ORACLE_KEYS.to_unsafe.to_slice(W52_ORACLE_KEYS.size), "payload",
  W52_ORACLE_MAP_STRING.to_unsafe.to_slice(W52_ORACLE_MAP_STRING.size), rows_per_mark: 2
)
empty_u64_maps = Array.new(W52_ORACLE_KEYS.size) { [] of Tuple(String, UInt64) }
empty_string_children = Array.new(W52_ORACLE_KEYS.size) { [{"", ""}] of Tuple(String, String) }
empty_u64_part = CrystalClick::WidePartWriter.write_uint64_map_string_uint64_pair(
  File.join(root, "writer-map-string-u64-empty"), "pk",
  W52_ORACLE_KEYS.to_unsafe.to_slice(W52_ORACLE_KEYS.size), "payload",
  empty_u64_maps.to_unsafe.to_slice(empty_u64_maps.size), rows_per_mark: 2
)
empty_string_part = CrystalClick::WidePartWriter.write_uint64_map_string_string_pair(
  File.join(root, "writer-map-string-string-empty-children"), "pk",
  W52_ORACLE_KEYS.to_unsafe.to_slice(W52_ORACLE_KEYS.size), "payload",
  empty_string_children.to_unsafe.to_slice(empty_string_children.size), rows_per_mark: 2
)
assert_empty_raw_streams(empty_u64_part, ["payload%2Ekeys", "payload%2Evalues"])
assert_empty_raw_streams(empty_string_part, ["payload%2Ekeys", "payload%2Evalues"])

verify_writer(binary, store, "w52_writer_u64", "Map(String, UInt64)", u64_part,
  rowbinary_map_string_uint64(W52_ORACLE_KEYS, W52_ORACLE_MAP_U64, (0...W52_ORACLE_KEYS.size).map(&.to_i32)),
  rowbinary_map_string_uint64(W52_ORACLE_KEYS, W52_ORACLE_MAP_U64, W52_ORACLE_RANGE_ROWS))
verify_writer(binary, store, "w52_writer_string", "Map(String, String)", string_part,
  rowbinary_map_string_string(W52_ORACLE_KEYS, W52_ORACLE_MAP_STRING, (0...W52_ORACLE_KEYS.size).map(&.to_i32)),
  rowbinary_map_string_string(W52_ORACLE_KEYS, W52_ORACLE_MAP_STRING, W52_ORACLE_RANGE_ROWS))
verify_writer(binary, store, "w52_writer_u64_empty_maps", "Map(String, UInt64)", empty_u64_part,
  rowbinary_map_string_uint64(W52_ORACLE_KEYS, empty_u64_maps, (0...W52_ORACLE_KEYS.size).map(&.to_i32)),
  rowbinary_map_string_uint64(W52_ORACLE_KEYS, empty_u64_maps, W52_ORACLE_RANGE_ROWS))
verify_writer(binary, store, "w52_writer_string_empty_children", "Map(String, String)", empty_string_part,
  rowbinary_map_string_string(W52_ORACLE_KEYS, empty_string_children, (0...W52_ORACLE_KEYS.size).map(&.to_i32)),
  rowbinary_map_string_string(W52_ORACLE_KEYS, empty_string_children, W52_ORACLE_RANGE_ROWS))
CRYSTAL
