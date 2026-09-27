#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/Users/sergey/.local/bin/clickhouse}"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/crystal-click-tuple-oracle.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

if [[ ! -x "$CLICKHOUSE_BIN" ]]; then
  printf 'ClickHouse executable not found or not executable: %s\n' "$CLICKHOUSE_BIN" >&2
  exit 1
fi

EXPECTED_VERSION='ClickHouse local version 26.7.1.1315 (official build).'
ACTUAL_VERSION="$("$CLICKHOUSE_BIN" local --version)"
if [[ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]]; then
  printf 'oracle requires %s, got %s\n' "$EXPECTED_VERSION" "$ACTUAL_VERSION" >&2
  exit 1
fi

cd "$ROOT"
export CLICKHOUSE_BIN
export CLICKHOUSE_STORE="$TMP_ROOT/clickhouse-store"
export TUPLE_PART="$TMP_ROOT/writer-part"
export EMPTY_TUPLE_PART="$TMP_ROOT/all-empty-writer-part"
export INVALID_PARENT="$TMP_ROOT/invalid"
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache"
mkdir -p "$CRYSTAL_CACHE_DIR" "$INVALID_PARENT"

crystal run --link-flags='-fuse-ld=ld' --stdin-filename "$ROOT/scripts/check_tuple_oracle.cr" <<'CRYSTAL'
require "../src/crystal_click"

def run_clickhouse(binary : String, store : String, query : String) : String
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

def append_tuple_u64(io : IO::Memory, value : UInt64) : Nil
  8.times { |offset| io.write_byte(((value >> (offset * 8)) & 0xff_u64).to_u8) }
end

def append_tuple_var_uint(io : IO::Memory, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

def tuple_rowbinary(keys : Array(UInt64), values : Array(Tuple(UInt64, String))) : Bytes
  raise "tuple row counts differ" unless keys.size == values.size
  output = IO::Memory.new
  keys.each_with_index do |key, index|
    value = values[index]
    append_tuple_u64(output, key)
    append_tuple_u64(output, value[0])
    append_tuple_var_uint(output, value[1].bytesize.to_u64)
    output.write(value[1].to_slice)
  end
  output.to_slice
end

def assert_tuple_bytes(actual : String, expected : Bytes, label : String) : Nil
  unless actual.to_slice == expected
    raise "#{label} RowBinary differs: expected #{expected.size} bytes, got #{actual.bytesize}"
  end
end

def tuple_table_sql(name : String) : String
  <<-SQL
  CREATE TABLE default.#{name}
  (
      pk UInt64,
      payload Tuple(a UInt64, b String)
  )
  ENGINE = MergeTree
  ORDER BY pk
  SETTINGS
      index_granularity = 2,
      enable_mixed_granularity_parts = 1,
      min_rows_for_wide_part = 0,
      min_bytes_for_wide_part = 0,
      compress_marks = 0,
      min_compress_block_size = 0,
      max_compress_block_size = 4096,
      ratio_of_defaults_for_sparse_serialization = 1.0
  SQL
end

def attach_tuple_part(binary : String, store : String, table : String, part : String) : String
  run_clickhouse(binary, store, tuple_table_sql(table))
  data_path = run_clickhouse(
    binary,
    store,
    "SELECT data_paths[1] FROM system.tables WHERE database = 'default' AND name = '#{table}' FORMAT TSVRaw"
  ).strip
  raise "ClickHouse returned no data path for #{table}" if data_path.empty?

  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  run_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  data_path
end

def check_tuple_rows(binary : String, store : String, table : String, keys : Array(UInt64), values : Array(Tuple(UInt64, String)), range_keys : Array(UInt64), range_values : Array(Tuple(UInt64, String))) : Nil
  query = "SELECT pk, payload.1, payload.2 FROM default.#{table} ORDER BY pk FORMAT RowBinary"
  actual = run_clickhouse(binary, store, query)
  assert_tuple_bytes(actual, tuple_rowbinary(keys, values), "#{table} full")

  range_query = "SELECT pk, payload.1, payload.2 FROM default.#{table} WHERE pk >= 2 AND pk < 11 ORDER BY pk FORMAT RowBinary"
  ranged = run_clickhouse(binary, store, range_query)
  assert_tuple_bytes(ranged, tuple_rowbinary(range_keys, range_values), "#{table} key range")

  integrity = run_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "#{table} CHECK TABLE failed: #{integrity.inspect}" unless integrity == "all_1_1_0\t1"
end

binary = ENV.fetch("CLICKHOUSE_BIN")
store = ENV.fetch("CLICKHOUSE_STORE")

# Exercise byte strings (including invalid UTF-8), an empty field, four marks,
# and a one-row short final granule.
keys = [0_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64]
values = [
  {0_u64, ""},
  {8_u64, "a\0b"},
  {9_u64, String.new(Bytes[0xff_u8, 0_u8])},
  {10_u64, "é"},
  {11_u64, ""},
  {12_u64, "last"},
  {13_u64, "z"},
]
CrystalClick::WidePartWriter.write_uint64_tuple_string_pair(
  ENV.fetch("TUPLE_PART"),
  "pk",
  keys.to_unsafe.to_slice(keys.size),
  "payload",
  values,
  rows_per_mark: 2
)

data_path = attach_tuple_part(binary, store, "tuple_writer", ENV.fetch("TUPLE_PART"))
range_keys = [] of UInt64
range_values = [] of Tuple(UInt64, String)
keys.each_with_index do |key, index|
  if key >= 2_u64 && key < 11_u64
    range_keys << key
    range_values << values[index]
  end
end
check_tuple_rows(binary, store, "tuple_writer", keys, values, range_keys, range_values)

expected_mark_rows = [2_u64, 2_u64, 2_u64, 1_u64, 0_u64]
{"pk", "payload%2Ea", "payload%2Eb.size", "payload%2Eb"}.each do |logical_name|
  base = CrystalClick::StreamName.hash(logical_name)
  mark_bytes = File.read(File.join(data_path, "all_1_1_0", "#{base}.mrk2")).to_slice
  raise "#{logical_name} mark count differs" unless mark_bytes.size == expected_mark_rows.size * CrystalClick::WidePart::MARK_SIZE
  observed_rows = expected_mark_rows.map_with_index do |_, index|
    offset = index * CrystalClick::WidePart::MARK_SIZE + 16
    8.times.reduce(0_u64) { |value, byte| value | (mark_bytes[offset + byte].to_u64 << (byte * 8)) }
  end
  raise "#{logical_name} independent mark rows differ: #{observed_rows.inspect}" unless observed_rows == expected_mark_rows
end

# Every String is empty: the raw `b` stream must remain zero bytes while its
# independent marks repeat byte offset zero for every data granule and sentinel.
empty_keys = [1_u64, 3_u64, 5_u64, 7_u64, 9_u64]
empty_values = [{1_u64, ""}, {2_u64, ""}, {3_u64, ""}, {4_u64, ""}, {5_u64, ""}]
CrystalClick::WidePartWriter.write_uint64_tuple_string_pair(
  ENV.fetch("EMPTY_TUPLE_PART"),
  "pk",
  empty_keys.to_unsafe.to_slice(empty_keys.size),
  "payload",
  empty_values,
  rows_per_mark: 2
)
empty_data_path = attach_tuple_part(binary, store, "tuple_writer_all_empty", ENV.fetch("EMPTY_TUPLE_PART"))
empty_base = CrystalClick::StreamName.hash("payload%2Eb")
empty_stream = File.join(empty_data_path, "all_1_1_0", "#{empty_base}.bin")
raise "all-empty Tuple String stream is not zero bytes" unless File.size(empty_stream) == 0
empty_mark_bytes = File.read(File.join(empty_data_path, "all_1_1_0", "#{empty_base}.mrk2")).to_slice
raise "all-empty Tuple String mark file has wrong size" unless empty_mark_bytes.size == 4 * CrystalClick::WidePart::MARK_SIZE
empty_offsets = [0, 1, 2, 3].map do |index|
  offset = index * CrystalClick::WidePart::MARK_SIZE
  8.times.reduce(0_u64) { |value, byte| value | (empty_mark_bytes[offset + byte].to_u64 << (byte * 8)) }
end
raise "all-empty Tuple String marks did not repeat offset zero: #{empty_offsets.inspect}" unless empty_offsets == [0_u64, 0_u64, 0_u64, 0_u64]
check_tuple_rows(binary, store, "tuple_writer_all_empty", empty_keys, empty_values, empty_keys[1, 4], empty_values[1, 4])

# Rejected malformed input must not publish either a destination or leftover
# sibling staging directory.
invalid_part = File.join(ENV.fetch("INVALID_PARENT"), "unsorted")
begin
  CrystalClick::WidePartWriter.write_uint64_tuple_string_pair(
    invalid_part,
    "pk",
    [2_u64, 1_u64].to_unsafe.to_slice(2),
    "payload",
    [{1_u64, "x"}, {2_u64, "y"}],
    rows_per_mark: 1
  )
  raise "writer accepted unsorted Tuple keys"
rescue error : ArgumentError
  raise "malformed Tuple writer published a part" if File.exists?(invalid_part)
  raise "malformed Tuple writer left staged artifacts" unless Dir.children(ENV.fetch("INVALID_PARENT")).empty?
end

puts "PASS Tuple writer: exact attached RowBinary/full+range, binary and empty strings, independent [2,2,2,1] marks, zero-byte all-empty stream, CHECK TABLE, and malformed-input no-publication"
CRYSTAL

printf 'PASS Tuple writer oracle on ClickHouse %s\n' "$ACTUAL_VERSION"
