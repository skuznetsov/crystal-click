#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/Users/sergey/.local/bin/clickhouse}"
EXPECTED_VERSION='ClickHouse local version 26.7.1.1315 (official build).'

if [[ ! -x "$CLICKHOUSE_BIN" ]]; then
  printf 'ClickHouse executable not found: %s\n' "$CLICKHOUSE_BIN" >&2
  exit 1
fi
ACTUAL_VERSION="$("$CLICKHOUSE_BIN" local --version)"
if [[ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]]; then
  printf 'oracle requires %s, got %s\n' "$EXPECTED_VERSION" "$ACTUAL_VERSION" >&2
  exit 1
fi

TMP_ROOT="$(mktemp -d /private/tmp/crystal-click-array-array-oracle.XXXXXX)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

cd "$ROOT"
scripts/verify_stock_array_array_uint64_fixture.sh >/dev/null
export CLICKHOUSE_BIN
export CLICKHOUSE_STORE="$TMP_ROOT/clickhouse-store"
export WRITER_PART="$TMP_ROOT/writer-part"
export STOCK_PART="$ROOT/test/fixtures/public/wide_array_array_uint64/part"
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache"
mkdir -p "$CRYSTAL_CACHE_DIR"

crystal run --link-flags='-fuse-ld=ld' --stdin-filename "$ROOT/scripts/check_array_array_uint64_oracle.cr" <<'CRYSTAL'
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

def expected_rowbinary(keys : Array(UInt64), arrays : Array(Array(Array(UInt64))), selected : Array(Int32)) : Bytes
  io = IO::Memory.new
  selected.each do |row|
    append_u64(io, keys[row])
    append_varuint(io, arrays[row].size.to_u64)
    arrays[row].each do |inner|
      append_varuint(io, inner.size.to_u64)
      inner.each { |value| append_u64(io, value) }
    end
  end
  io.to_slice
end

def attach_part(binary : String, store : String, table : String, part : String) : Nil
  run_clickhouse(binary, store, <<-SQL)
  CREATE TABLE default.#{table}
  (
      pk UInt64,
      payload Array(Array(UInt64))
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

def check_written(binary : String, store : String, table : String, part : String,
                  keys : Array(UInt64), arrays : Array(Array(Array(UInt64))),
                  selected : Array(Int32), condition : String = "") : Nil
  attach_part(binary, store, table, part)
  actual = run_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table}#{condition} ORDER BY pk FORMAT RowBinary")
  assert_rowbinary(actual, expected_rowbinary(keys, arrays, selected), table)
end

binary = ENV.fetch("CLICKHOUSE_BIN")
store = ENV.fetch("CLICKHOUSE_STORE")
keys = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64]
arrays = [
  [] of Array(UInt64),
  [[] of UInt64, [0_u64, UInt64::MAX], [] of UInt64],
  [[42_u64], [] of UInt64],
  [] of Array(UInt64),
  [[] of UInt64, [] of UInt64],
  [[1_u64, 2_u64, 3_u64]],
  [] of Array(UInt64),
] of Array(Array(UInt64))

stock = CrystalClick::WidePart.open_typed(ENV.fetch("STOCK_PART"), "payload")
raise "stock Array(Array(UInt64)) type mismatch" unless stock.column_type == "Array(Array(UInt64))"
raise "stock full read mismatch" unless stock.read_array_array_uint64_mark_range("payload", 0, stock.mark_count) == arrays
raise "stock later-mark read mismatch" unless stock.read_array_array_uint64_mark_range("payload", 1, 2) == arrays[2, 4]
check_written(binary, store, "array_array_stock", ENV.fetch("STOCK_PART"), keys, arrays, (0...keys.size).map(&.to_i32))

CrystalClick::WidePartWriter.write_uint64_array_array_uint64_pair(
  ENV.fetch("WRITER_PART"), "pk", keys.to_unsafe.to_slice(keys.size),
  "payload", arrays.to_unsafe.to_slice(arrays.size), rows_per_mark: 2
)
check_written(binary, store, "array_array_writer", ENV.fetch("WRITER_PART"), keys, arrays, (0...keys.size).map(&.to_i32))
selected = keys.each_with_index.compact_map { |key, index| index.to_i32 if key >= 2_u64 && key < 11_u64 }.to_a
bounded = run_clickhouse(binary, store, "SELECT pk, payload FROM default.array_array_writer WHERE pk >= 2 AND pk < 11 ORDER BY pk FORMAT RowBinary")
assert_rowbinary(bounded, expected_rowbinary(keys, arrays, selected), "writer bounded")

empty_keys = [1_u64, 2_u64, 3_u64]
empty_arrays = [
  [] of Array(UInt64),
  [] of Array(UInt64),
  [] of Array(UInt64),
] of Array(Array(UInt64))
empty_path = File.join(File.dirname(ENV.fetch("WRITER_PART")), "all-empty-part")
CrystalClick::WidePartWriter.write_uint64_array_array_uint64_pair(
  empty_path, "pk", empty_keys.to_unsafe.to_slice(empty_keys.size),
  "payload", empty_arrays.to_unsafe.to_slice(empty_arrays.size), rows_per_mark: 2
)
check_written(binary, store, "array_array_all_empty", empty_path, empty_keys, empty_arrays, [0_i32, 1_i32, 2_i32])

middle_keys = [1_u64, 2_u64, 3_u64]
middle_arrays = [
  [[5_u64]],
  [[] of UInt64, [] of UInt64],
  [[0_u64, UInt64::MAX]],
] of Array(Array(UInt64))
middle_path = File.join(File.dirname(ENV.fetch("WRITER_PART")), "empty-middle-part")
CrystalClick::WidePartWriter.write_uint64_array_array_uint64_pair(
  middle_path, "pk", middle_keys.to_unsafe.to_slice(middle_keys.size),
  "payload", middle_arrays.to_unsafe.to_slice(middle_arrays.size), rows_per_mark: 1
)
check_written(binary, store, "array_array_middle_empty", middle_path, middle_keys, middle_arrays, [0_i32, 1_i32, 2_i32])
puts "Array(Array(UInt64)) bidirectional stock oracle passed"
CRYSTAL
