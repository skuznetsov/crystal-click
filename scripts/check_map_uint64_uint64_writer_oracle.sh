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

TMP_ROOT="$(mktemp -d /private/tmp/crystal-click-map-u64-writer-oracle.XXXXXX)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

cd "$ROOT"
export CLICKHOUSE_BIN
export CLICKHOUSE_STORE="$TMP_ROOT/clickhouse-store"
export MAP_PART="$TMP_ROOT/writer-part"
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache"
mkdir -p "$CRYSTAL_CACHE_DIR"

crystal run --link-flags='-fuse-ld=ld' --stdin-filename "$ROOT/scripts/check_map_uint64_uint64_writer_oracle.cr" <<'CRYSTAL'
require "file_utils"
require "../src/crystal_click"

def run_clickhouse(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  result = Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse query failed (#{result.exit_code}): #{query}" unless result.success?
  output.to_s
end

def append_u64(io : IO, value : UInt64) : Nil
  8.times { |byte| io.write_byte(((value >> (byte * 8)) & 0xff_u64).to_u8) }
end

def append_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

def direct_rowbinary(keys : Array(UInt64), maps : Array(Array(Tuple(UInt64, UInt64))), selected : Array(Int32)) : Bytes
  io = IO::Memory.new
  selected.each do |row|
    append_u64(io, keys[row])
    append_varuint(io, maps[row].size.to_u64)
    maps[row].each do |key, value|
      append_u64(io, key)
      append_u64(io, value)
    end
  end
  io.to_slice
end

def keys_values_rowbinary(keys : Array(UInt64), maps : Array(Array(Tuple(UInt64, UInt64))), selected : Array(Int32)) : Bytes
  io = IO::Memory.new
  selected.each do |row|
    append_u64(io, keys[row])
    append_varuint(io, maps[row].size.to_u64)
    maps[row].each { |entry| append_u64(io, entry[0]) }
    append_varuint(io, maps[row].size.to_u64)
    maps[row].each { |entry| append_u64(io, entry[1]) }
  end
  io.to_slice
end

def attach_part(binary : String, store : String, table : String, part : String) : Nil
  run_clickhouse(binary, store, <<-SQL)
  CREATE TABLE default.#{table}
  (
      pk UInt64,
      m Map(UInt64, UInt64)
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
  data_path = run_clickhouse(binary, store, "SELECT data_paths[1] FROM system.tables WHERE database = 'default' AND name = '#{table}' FORMAT TSVRaw").strip
  raise "no ClickHouse data path for #{table}" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  run_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  integrity = run_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "CHECK TABLE failed: #{integrity.inspect}" unless integrity == "all_1_1_0\t1"
  nil
end

def assert_rowbinary(actual : String, expected : Bytes, label : String) : Nil
  raise "#{label} RowBinary mismatch: expected #{expected.size} bytes, got #{actual.bytesize}" unless actual.to_slice == expected
end

binary = ENV.fetch("CLICKHOUSE_BIN")
store = ENV.fetch("CLICKHOUSE_STORE")
keys = [0_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64]
maps = [
  [] of Tuple(UInt64, UInt64),
  [{3_u64, 0_u64}, {3_u64, UInt64::MAX}],
  [{0_u64, 0_u64}, {UInt64::MAX, 42_u64}],
  [{42_u64, UInt64::MAX}],
  [] of Tuple(UInt64, UInt64),
  [{6_u64, 8_u64}, {1_u64, 9_u64}],
  [{5_u64, 5_u64}],
] of Array(Tuple(UInt64, UInt64))
CrystalClick::WidePartWriter.write_uint64_map_uint64_uint64_pair(
  ENV.fetch("MAP_PART"), "pk", keys.to_unsafe.to_slice(keys.size), "m", maps.to_unsafe.to_slice(maps.size), rows_per_mark: 2
)
attach_part(binary, store, "map_uint64_uint64_writer", ENV.fetch("MAP_PART"))

full = (0...keys.size).map(&.to_i32)
selected = keys.each_with_index.compact_map { |key, index| index.to_i32 if key >= 2_u64 && key < 11_u64 }.to_a
[
  {"full", full, ""},
  {"bounded", selected, " WHERE pk >= 2 AND pk < 11"},
].each do |label, rows, condition|
  direct = run_clickhouse(binary, store, "SELECT pk, m FROM default.map_uint64_uint64_writer#{condition} ORDER BY pk FORMAT RowBinary")
  assert_rowbinary(direct, direct_rowbinary(keys, maps, rows), "direct Map #{label}")
  split = run_clickhouse(binary, store, "SELECT pk, mapKeys(m), mapValues(m) FROM default.map_uint64_uint64_writer#{condition} ORDER BY pk FORMAT RowBinary")
  assert_rowbinary(split, keys_values_rowbinary(keys, maps, rows), "Map keys/values #{label}")
end

empty_keys = [1_u64, 2_u64, 3_u64]
empty_maps = [
  [] of Tuple(UInt64, UInt64),
  [] of Tuple(UInt64, UInt64),
  [] of Tuple(UInt64, UInt64),
]
empty_part = File.join(File.dirname(ENV.fetch("MAP_PART")), "all-empty-part")
CrystalClick::WidePartWriter.write_uint64_map_uint64_uint64_pair(
  empty_part, "pk", empty_keys.to_unsafe.to_slice(empty_keys.size), "m", empty_maps.to_unsafe.to_slice(empty_maps.size), rows_per_mark: 2
)
attach_part(binary, store, "map_uint64_uint64_all_empty", empty_part)
actual_empty = run_clickhouse(binary, store, "SELECT pk, m FROM default.map_uint64_uint64_all_empty ORDER BY pk FORMAT RowBinary")
assert_rowbinary(actual_empty, direct_rowbinary(empty_keys, empty_maps, [0_i32, 1_i32, 2_i32]), "all-empty Map")

middle_keys = [1_u64, 2_u64, 3_u64]
middle_maps = [
  [{7_u64, 8_u64}],
  [] of Tuple(UInt64, UInt64),
  [{9_u64, 10_u64}],
]
middle_part = File.join(File.dirname(ENV.fetch("MAP_PART")), "middle-empty-part")
CrystalClick::WidePartWriter.write_uint64_map_uint64_uint64_pair(
  middle_part, "pk", middle_keys.to_unsafe.to_slice(middle_keys.size),
  "m", middle_maps.to_unsafe.to_slice(middle_maps.size), rows_per_mark: 1
)
attach_part(binary, store, "map_uint64_uint64_middle_empty", middle_part)
actual_middle = run_clickhouse(binary, store, "SELECT pk, m FROM default.map_uint64_uint64_middle_empty ORDER BY pk FORMAT RowBinary")
assert_rowbinary(actual_middle, direct_rowbinary(middle_keys, middle_maps, [0_i32, 1_i32, 2_i32]), "empty middle granule")
puts "Map(UInt64, UInt64) stock writer oracle passed"
CRYSTAL
