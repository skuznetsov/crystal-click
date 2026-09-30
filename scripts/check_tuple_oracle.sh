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

# This direction must not use a Crystal-written part: generate the physical
# streams with the pinned stock binary and read them through the public API.
def create_stock_tuple_part(binary : String, store : String, table : String, keys : Array(UInt64), values : Array(Tuple(UInt64, String)), key_name : String, sparse_ratio : String) : String
  stock_sql = tuple_table_sql(table)
    .sub("pk UInt64", "#{key_name} UInt64")
    .sub("ORDER BY pk", "ORDER BY #{key_name}")
    .sub("ratio_of_defaults_for_sparse_serialization = 1.0", "ratio_of_defaults_for_sparse_serialization = #{sparse_ratio}")
  run_clickhouse(binary, store, stock_sql)
  rows = keys.map_with_index do |key, index|
    value = values[index]
    "(#{key}, tuple(toUInt64(#{value[0]}), unhex('#{value[1].to_slice.hexstring}')))"
  end.join(", ")
  run_clickhouse(binary, store, "INSERT INTO default.#{table} VALUES #{rows}")
  paths = run_clickhouse(binary, store, "SELECT path FROM system.parts WHERE database = 'default' AND table = '#{table}' AND active FORMAT TSVRaw").lines.map(&.strip).reject(&.empty?)
  raise "#{table} must have exactly one stock-created active part" unless paths.size == 1
  paths[0]
end

def check_stock_tuple_reader(binary : String, store : String, table : String, keys : Array(UInt64), values : Array(Tuple(UInt64, String))) : Nil
  # The admitted profile has explicit Default serializer records in the same
  # order as columns.txt. The stock key name `id` satisfies that narrow guard.
  path = create_stock_tuple_part(binary, store, table, keys, values, "id", "0.9375")
  key_reader = CrystalClick::WidePart.open_typed(path, "id")
  tuple_reader = CrystalClick::WidePart.open_typed(path, "payload")
  expected_mark_rows = keys.each_slice(2).map { |mark| mark.size.to_u64 }.to_a
  raise "#{table} key mark rows differ" unless key_reader.mark_row_counts == expected_mark_rows
  raise "#{table} Tuple mark rows differ" unless tuple_reader.mark_row_counts == expected_mark_rows
  actual_keys = key_reader.read_uint64_mark_range("id", 0, key_reader.mark_count)
  actual_values = tuple_reader.read_tuple_uint64_string_mark_range("payload", 0, tuple_reader.mark_count)
  assert_tuple_bytes(String.new(tuple_rowbinary(actual_keys, actual_values)), tuple_rowbinary(keys, values), "#{table} stock -> Crystal full")

  first_mark = 1
  count = tuple_reader.mark_count - first_mark
  range_keys = key_reader.read_uint64_mark_range("id", first_mark, count)
  range_values = tuple_reader.read_tuple_uint64_string_mark_range("payload", first_mark, count)
  assert_tuple_bytes(String.new(tuple_rowbinary(range_keys, range_values)), tuple_rowbinary(keys[2, keys.size - 2], values[2, values.size - 2]), "#{table} stock -> Crystal mark range")

  begin
    tuple_reader.read_string_mark_range("payload", 0, 1)
    raise "#{table} Tuple root was admitted by scalar String reader"
  rescue CrystalClick::UnsupportedFormatError
  end
  begin
    tuple_reader.read_uint64_mark_range("payload", 0, 1)
    raise "#{table} Tuple root was admitted by scalar UInt64 reader"
  rescue CrystalClick::UnsupportedFormatError
  end
end

def check_stock_tuple_profile_rejection(binary : String, store : String, table : String, keys : Array(UInt64), values : Array(Tuple(UInt64, String)), key_name : String, sparse_ratio : String, expected_error : String) : Nil
  path = create_stock_tuple_part(binary, store, table, keys, values, key_name, sparse_ratio)
  begin
    CrystalClick::WidePart.open_typed(path, "payload")
    raise "#{table} unexpectedly admitted an unsealed Tuple metadata profile"
  rescue error : CrystalClick::UnsupportedFormatError
    raise "#{table} rejected for an unexpected reason: #{error.message}" unless error.message.try(&.includes?(expected_error))
  end
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
check_stock_tuple_reader(binary, store, "tuple_stock", keys, values)
check_stock_tuple_profile_rejection(binary, store, "tuple_stock_reordered_records", keys, values, "pk", "0.9375", "Tuple serializer order does not match columns.txt")
check_stock_tuple_profile_rejection(binary, store, "tuple_stock_omitted_records", keys, values, "id", "1.0", "Tuple serialization requires exact key and payload entries")
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
check_stock_tuple_profile_rejection(binary, store, "tuple_stock_all_empty_sparse", empty_keys, empty_values, "id", "0.9375", "only Default Tuple child serializers are supported")
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

# Stock acceptance of a library-written part does not imply that the library
# can read it. Exercise the exact zero-byte raw stream after stock ATTACH too.
empty_reader = CrystalClick::WidePart.open_typed(File.join(empty_data_path, "all_1_1_0"), "payload")
raise "all-empty Crystal mark rows differ" unless empty_reader.mark_row_counts == [2_u64, 2_u64, 1_u64]
raise "all-empty Crystal full raw-byte preflight differs" unless empty_reader.tuple_uint64_string_mark_range_raw_bytes("payload", 0, 3) == 0_u64
raise "all-empty Crystal full Tuple values differ" unless empty_reader.read_tuple_uint64_string_mark_range("payload", 0, 3) == empty_values
[{0, 1, 0, 2}, {1, 1, 2, 2}, {2, 1, 4, 1}, {1, 2, 2, 3}].each do |first_mark, mark_count, first_row, row_count|
  raise "all-empty Crystal ranged raw-byte preflight differs" unless empty_reader.tuple_uint64_string_mark_range_raw_bytes("payload", first_mark, mark_count) == 0_u64
  actual_values = empty_reader.read_tuple_uint64_string_mark_range("payload", first_mark, mark_count)
  raise "all-empty Crystal ranged Tuple values differ" unless actual_values == empty_values[first_row, row_count]
end

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

puts "PASS Tuple reader/writer: admitted stock-created -> Crystal full/mark-range RowBinary, strict scalar roots and rejected reordered/omitted/sparse metadata profiles; Crystal-written -> stock attached full/key-range RowBinary, binary and empty strings, independent [2,2,2,1] marks, zero-byte all-empty stream read full/ranged by Crystal after ATTACH, CHECK TABLE, and malformed-input no-publication"
CRYSTAL

printf 'PASS Tuple reader/writer oracle on ClickHouse %s\n' "$ACTUAL_VERSION"
