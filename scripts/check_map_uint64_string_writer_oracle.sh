#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/Users/sergey/.local/bin/clickhouse}"

if ! command -v "$CLICKHOUSE_BIN" >/dev/null 2>&1; then
  printf 'ClickHouse executable not found: %s\n' "$CLICKHOUSE_BIN" >&2
  exit 1
fi

EXPECTED_VERSION='ClickHouse local version 26.7.1.1315 (official build).'
ACTUAL_VERSION="$("$CLICKHOUSE_BIN" local --version)"
if [[ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]]; then
  printf 'oracle requires %s, got %s\n' "$EXPECTED_VERSION" "$ACTUAL_VERSION" >&2
  exit 1
fi

TMP_ROOT="$(mktemp -d /private/tmp/crystal-click-map-writer-oracle.XXXXXX)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

cd "$ROOT"
export CLICKHOUSE_BIN
export CLICKHOUSE_STORE="$TMP_ROOT/clickhouse-store"
export MAP_PART="$TMP_ROOT/writer-part"
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache"
mkdir -p "$CRYSTAL_CACHE_DIR"

crystal run --link-flags='-fuse-ld=ld' --stdin-filename "$ROOT/scripts/check_map_uint64_string_writer_oracle.cr" <<'CRYSTAL'
require "file_utils"
require "../src/crystal_click"

def run_map_clickhouse(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  result = Process.run(
    binary,
    ["local", "--path", store, "--query", query],
    output: output,
    error: Process::Redirect::Inherit
  )
  raise "ClickHouse local query failed (status #{result.exit_code}): #{query}" unless result.success?
  output.to_s
end

def append_map_u64(io : IO, value : UInt64) : Nil
  8.times { |byte| io.write_byte(((value >> (byte * 8)) & 0xff_u64).to_u8) }
end

def append_map_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

def map_keys_values_rowbinary(
  row_keys : Array(UInt64),
  row_maps : Array(Array(Tuple(UInt64, String))),
  selected_rows : Array(Int32),
) : Bytes
  output = IO::Memory.new
  selected_rows.each do |row_index|
    append_map_u64(output, row_keys[row_index])
    entries = row_maps[row_index]
    append_map_varuint(output, entries.size.to_u64)
    entries.each { |entry| append_map_u64(output, entry[0]) }
    append_map_varuint(output, entries.size.to_u64)
    entries.each do |entry|
      append_map_varuint(output, entry[1].bytesize.to_u64)
      output.write(entry[1].to_slice)
    end
  end
  output.to_slice
end

def map_direct_rowbinary(
  row_keys : Array(UInt64),
  row_maps : Array(Array(Tuple(UInt64, String))),
  selected_rows : Array(Int32),
) : Bytes
  output = IO::Memory.new
  selected_rows.each do |row_index|
    append_map_u64(output, row_keys[row_index])
    entries = row_maps[row_index]
    append_map_varuint(output, entries.size.to_u64)
    entries.each do |entry|
      append_map_u64(output, entry[0])
      append_map_varuint(output, entry[1].bytesize.to_u64)
      output.write(entry[1].to_slice)
    end
  end
  output.to_slice
end

def create_map_table(binary : String, store : String, table : String) : Nil
  run_map_clickhouse(binary, store, <<-SQL)
  CREATE TABLE default.#{table}
  (
      pk UInt64,
      m Map(UInt64, String)
  )
  ENGINE = MergeTree
  ORDER BY pk
  SETTINGS
      index_granularity = 2,
      index_granularity_bytes = 10485760,
      enable_mixed_granularity_parts = 1,
      min_rows_for_wide_part = 0,
      min_bytes_for_wide_part = 0,
      compress_marks = 0,
      min_compress_block_size = 0,
      max_compress_block_size = 4096,
      ratio_of_defaults_for_sparse_serialization = 1.0,
      default_compression_codec = 'LZ4';
  SQL
  nil
end

def attach_map_part(binary : String, store : String, table : String, part : String) : String
  create_map_table(binary, store, table)
  data_path = run_map_clickhouse(
    binary,
    store,
    "SELECT data_paths[1] FROM system.tables WHERE database = 'default' AND name = '#{table}' FORMAT TSVRaw"
  ).strip
  raise "ClickHouse returned no data path for #{table}" if data_path.empty?

  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  run_map_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  data_path
end

def assert_map_rowbinary(actual : String, expected : Bytes, label : String) : Nil
  unless actual.to_slice == expected
    raise "#{label} RowBinary differs: expected #{expected.size} bytes, got #{actual.bytesize}"
  end
end

binary = ENV.fetch("CLICKHOUSE_BIN")
store = ENV.fetch("CLICKHOUSE_STORE")
keys = [0_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64]
binary_value = String.new(Bytes[0x61_u8, 0_u8, 0x62_u8])
invalid_utf8 = String.new(Bytes[0xff_u8, 0_u8])
maps = [
  [] of Tuple(UInt64, String),
  [{3_u64, "a"}, {3_u64, ""}],
  [{0_u64, binary_value}, {UInt64::MAX, "é"}],
  [{42_u64, ""}],
  [] of Tuple(UInt64, String),
  [{6_u64, "tail"}],
  [{5_u64, invalid_utf8}],
] of Array(Tuple(UInt64, String))

CrystalClick::WidePartWriter.write_uint64_map_uint64_string_pair(
  ENV.fetch("MAP_PART"),
  "pk",
  keys.to_unsafe.to_slice(keys.size),
  "m",
  maps.to_unsafe.to_slice(maps.size),
  rows_per_mark: 2
)

attach_map_part(binary, store, "map_uint64_string_writer", ENV.fetch("MAP_PART"))
full_rows = (0...keys.size).map(&.to_i32)
range_rows = keys.each_with_index.compact_map do |key, index|
  index.to_i32 if key >= 2_u64 && key < 11_u64
end.to_a
query = "SELECT pk, mapKeys(m), mapValues(m) FROM default.map_uint64_string_writer ORDER BY pk FORMAT RowBinary"
assert_map_rowbinary(
  run_map_clickhouse(binary, store, query),
  map_keys_values_rowbinary(keys, maps, full_rows),
  "full table"
)
range_query = "SELECT pk, mapKeys(m), mapValues(m) FROM default.map_uint64_string_writer WHERE pk >= 2 AND pk < 11 ORDER BY pk FORMAT RowBinary"
assert_map_rowbinary(
  run_map_clickhouse(binary, store, range_query),
  map_keys_values_rowbinary(keys, maps, range_rows),
  "bounded key range"
)

direct_query = "SELECT pk, m FROM default.map_uint64_string_writer ORDER BY pk FORMAT RowBinary"
assert_map_rowbinary(
  run_map_clickhouse(binary, store, direct_query),
  map_direct_rowbinary(keys, maps, full_rows),
  "direct Map full table"
)
direct_range_query = "SELECT pk, m FROM default.map_uint64_string_writer WHERE pk >= 2 AND pk < 11 ORDER BY pk FORMAT RowBinary"
assert_map_rowbinary(
  run_map_clickhouse(binary, store, direct_range_query),
  map_direct_rowbinary(keys, maps, range_rows),
  "direct Map bounded key range"
)

integrity = run_map_clickhouse(binary, store, "CHECK TABLE default.map_uint64_string_writer FORMAT TabSeparated").strip
raise "CHECK TABLE failed: #{integrity.inspect}" unless integrity == "all_1_1_0\t1"

empty_map_keys = [1_u64, 2_u64, 3_u64]
empty_maps = [
  [] of Tuple(UInt64, String),
  [] of Tuple(UInt64, String),
  [] of Tuple(UInt64, String),
]
empty_map_part = File.join(File.dirname(ENV.fetch("MAP_PART")), "all-empty-maps-part")
CrystalClick::WidePartWriter.write_uint64_map_uint64_string_pair(
  empty_map_part,
  "pk",
  empty_map_keys.to_unsafe.to_slice(empty_map_keys.size),
  "m",
  empty_maps.to_unsafe.to_slice(empty_maps.size),
  rows_per_mark: 2
)
attach_map_part(binary, store, "map_uint64_string_all_empty_maps", empty_map_part)
empty_map_query = "SELECT pk, m FROM default.map_uint64_string_all_empty_maps ORDER BY pk FORMAT RowBinary"
assert_map_rowbinary(
  run_map_clickhouse(binary, store, empty_map_query),
  map_direct_rowbinary(empty_map_keys, empty_maps, [0_i32, 1_i32, 2_i32]),
  "direct Map all-empty maps"
)
empty_map_integrity = run_map_clickhouse(binary, store, "CHECK TABLE default.map_uint64_string_all_empty_maps FORMAT TabSeparated").strip
raise "all-empty maps CHECK TABLE failed: #{empty_map_integrity.inspect}" unless empty_map_integrity == "all_1_1_0\t1"

empty_value_keys = [10_u64, 20_u64, 30_u64]
empty_value_maps = [
  [{9_u64, ""}, {9_u64, ""}],
  [{0_u64, ""}, {UInt64::MAX, ""}],
  [] of Tuple(UInt64, String),
] of Array(Tuple(UInt64, String))
empty_value_part = File.join(File.dirname(ENV.fetch("MAP_PART")), "all-empty-string-values-part")
CrystalClick::WidePartWriter.write_uint64_map_uint64_string_pair(
  empty_value_part,
  "pk",
  empty_value_keys.to_unsafe.to_slice(empty_value_keys.size),
  "m",
  empty_value_maps.to_unsafe.to_slice(empty_value_maps.size),
  rows_per_mark: 2
)
attach_map_part(binary, store, "map_uint64_string_all_empty_values", empty_value_part)
empty_value_query = "SELECT pk, m FROM default.map_uint64_string_all_empty_values ORDER BY pk FORMAT RowBinary"
assert_map_rowbinary(
  run_map_clickhouse(binary, store, empty_value_query),
  map_direct_rowbinary(empty_value_keys, empty_value_maps, [0_i32, 1_i32, 2_i32]),
  "direct Map all-empty string values with duplicate keys"
)
empty_value_integrity = run_map_clickhouse(binary, store, "CHECK TABLE default.map_uint64_string_all_empty_values FORMAT TabSeparated").strip
raise "all-empty string values CHECK TABLE failed: #{empty_value_integrity.inspect}" unless empty_value_integrity == "all_1_1_0\t1"

puts "PASS Map(UInt64, String) writer oracle: pinned ClickHouse ATTACH PART, full/ranged direct and keys/values RowBinary, all-empty maps/strings, binary/UTF-8, duplicate key order, and CHECK TABLE"
CRYSTAL

printf 'PASS Map(UInt64, String) writer oracle on ClickHouse %s\n' "$ACTUAL_VERSION"
