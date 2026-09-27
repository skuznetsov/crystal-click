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
bash "$ROOT/scripts/verify_stock_wide_array_tuple_w51_fixture.sh"

TMP_ROOT="$(mktemp -d /private/tmp/crystal-click-array-tuple-w51-oracle.XXXXXX)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT
cd "$ROOT"
export CLICKHOUSE_BIN TMP_ROOT
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache"
mkdir -p "$CRYSTAL_CACHE_DIR"

crystal run --link-flags='-fuse-ld=ld' --stdin-filename "$ROOT/scripts/check_wide_array_tuple_w51_oracle.cr" <<'CRYSTAL'
require "file_utils"
require "../src/crystal_click"

W51_KEYS = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64]
W51_LONG_STRING = "a longer string crosses the row and mark boundary"
W51_NULLABLE_LONG_STRING = "nullable long string crosses the row and mark boundary"
W51_BINARY_STRING = String.new(Bytes[0x41_u8, 0_u8, 0x42_u8, 0xff_u8])
W51_ARRAY_TUPLE_VALUES = [
  [] of Tuple(UInt64, String),
  [{0_u64, ""}, {UInt64::MAX, "small"}] of Tuple(UInt64, String),
  [{42_u64, W51_BINARY_STRING}, {3_u64, "second"}] of Tuple(UInt64, String),
  [] of Tuple(UInt64, String),
  [{7_u64, W51_LONG_STRING}] of Tuple(UInt64, String),
  [{2_u64, "tail"}, {3_u64, "last"}] of Tuple(UInt64, String),
  [] of Tuple(UInt64, String),
] of Array(Tuple(UInt64, String))
W51_EMPTY_STRING_MARK_VALUES = [
  [{1_u64, "before"}] of Tuple(UInt64, String),
  [{2_u64, "before-last"}] of Tuple(UInt64, String),
  [{3_u64, ""}, {4_u64, ""}] of Tuple(UInt64, String),
  [{5_u64, ""}] of Tuple(UInt64, String),
  [{6_u64, "after"}] of Tuple(UInt64, String),
  [{7_u64, "after-last"}] of Tuple(UInt64, String),
  [{8_u64, "tail"}] of Tuple(UInt64, String),
] of Array(Tuple(UInt64, String))
W51_ARRAY_TUPLE_NULLABLE_VALUES = [
  [] of Tuple(UInt64?, String),
  [{nil.as(UInt64?), ""}, {0_u64.as(UInt64?), "zero"}] of Tuple(UInt64?, String),
  [{nil.as(UInt64?), "all null one"}, {nil.as(UInt64?), "all null two"}] of Tuple(UInt64?, String),
  [] of Tuple(UInt64?, String),
  [{9_u64.as(UInt64?), W51_NULLABLE_LONG_STRING}] of Tuple(UInt64?, String),
  [{8_u64.as(UInt64?), "nullable"}, {nil.as(UInt64?), "end"}] of Tuple(UInt64?, String),
  [] of Tuple(UInt64?, String),
] of Array(Tuple(UInt64?, String))
W51_EMPTY_ARRAY_TUPLE_VALUES = Array.new(W51_KEYS.size) { [] of Tuple(UInt64, String) }
W51_ALL_NULL_ARRAY_TUPLE_VALUES = Array.new(W51_KEYS.size) do |index|
  [{nil.as(UInt64?), "only-null-#{index}"}] of Tuple(UInt64?, String)
end

def run_clickhouse(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse query failed (status #{status.exit_code}): #{query}" unless status.success?
  output.to_s
end

def create_table(binary : String, store : String, table : String, type_name : String) : Nil
  run_clickhouse(binary, store, <<-SQL)
  CREATE TABLE default.#{table}
  (
      `pk` UInt64,
      `payload` #{type_name}
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

def read_u64_le(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
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

def append_array_tuple_uint64_string(io : IO, values : Array(Tuple(UInt64, String))) : Nil
  append_varuint(io, values.size.to_u64)
  values.each do |number, string_value|
    append_u64_le(io, number)
    append_string(io, string_value)
  end
end

def append_array_tuple_nullable_uint64_string(io : IO, values : Array(Tuple(UInt64?, String))) : Nil
  append_varuint(io, values.size.to_u64)
  values.each do |number, string_value|
    if present = number
      io.write_byte(0_u8)
      append_u64_le(io, present)
    else
      io.write_byte(1_u8)
    end
    append_string(io, string_value)
  end
end

def rowbinary(keys : Array(UInt64), values : Array(Array(Tuple(UInt64, String)))) : String
  raise "Array(Tuple(UInt64, String)) RowBinary lengths differ" unless keys.size == values.size
  io = IO::Memory.new
  keys.each_with_index do |key, index|
    append_u64_le(io, key)
    append_array_tuple_uint64_string(io, values[index])
  end
  io.to_s
end

def rowbinary(keys : Array(UInt64), values : Array(Array(Tuple(UInt64?, String)))) : String
  raise "Array(Tuple(Nullable(UInt64), String)) RowBinary lengths differ" unless keys.size == values.size
  io = IO::Memory.new
  keys.each_with_index do |key, index|
    append_u64_le(io, key)
    append_array_tuple_nullable_uint64_string(io, values[index])
  end
  io.to_s
end

def range_values(values : Array(T)) : Array(T) forall T
  [values[1], values[2], values[3], values[4], values[5]]
end

def range_keys : Array(UInt64)
  [W51_KEYS[1], W51_KEYS[2], W51_KEYS[3], W51_KEYS[4], W51_KEYS[5]]
end

def assert_bytes(actual : String, expected : String, label : String) : Nil
  return if actual.to_slice == expected.to_slice
  raise "#{label} RowBinary mismatch: got #{actual.bytesize} bytes, expected #{expected.bytesize}"
end

def assert_empty_string_mark_has_repeated_raw_boundary(part : String) : Nil
  marks_path = File.join(part, "#{CrystalClick::StreamName.hash("payload%2Eb")}.mrk2")
  bytes = File.read(marks_path).to_slice
  first_boundary = CrystalClick::WidePart::MARK_SIZE
  after_boundary = 2 * CrystalClick::WidePart::MARK_SIZE
  raise "empty-String mark fixture has truncated marks" if bytes.size < 5 * CrystalClick::WidePart::MARK_SIZE
  unless read_u64_le(bytes, first_boundary) == read_u64_le(bytes, after_boundary) &&
         read_u64_le(bytes, first_boundary + 8) == read_u64_le(bytes, after_boundary + 8) &&
         read_u64_le(bytes, first_boundary + 16) == 2_u64 &&
         read_u64_le(bytes, after_boundary + 16) == 2_u64
    raise "empty-String mark did not preserve repeated raw-stream boundaries"
  end
  nil
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

def verify_writer(binary : String, store : String, table : String, type_name : String, part : String, full_expected : String, range_expected : String) : Nil
  create_table(binary, store, table, type_name)
  attach_part(binary, store, table, part)
  columns = run_clickhouse(binary, store,
    "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw")
  expected_columns = "pk UInt64\npayload #{type_name}\n"
  raise "#{table}: exact type metadata differs: #{columns.inspect}" unless columns == expected_columns

  show_create = run_clickhouse(binary, store, "SHOW CREATE TABLE default.#{table} FORMAT TSVRaw")
  # ClickHouse pretty-prints nested Tuple members over multiple lines here;
  # system.columns above supplies the exact canonical type comparison.
  normalized_create = show_create.gsub(/\s+/, "")
  normalized_declaration = "`payload`#{type_name.gsub(/\s+/, "")}"
  raise "#{table}: SHOW CREATE lost nested type #{type_name}" unless normalized_create.includes?(normalized_declaration)
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
keys = W51_KEYS.to_unsafe.to_slice(W51_KEYS.size)
range = range_keys

plain_part = CrystalClick::WidePartWriter.write_uint64_array_tuple_uint64_string_pair(
  File.join(root, "writer-array-tuple"), "pk", keys, "payload",
  W51_ARRAY_TUPLE_VALUES.to_unsafe.to_slice(W51_ARRAY_TUPLE_VALUES.size), rows_per_mark: 2
)
nullable_part = CrystalClick::WidePartWriter.write_uint64_array_tuple_nullable_uint64_string_pair(
  File.join(root, "writer-array-tuple-nullable"), "pk", keys, "payload",
  W51_ARRAY_TUPLE_NULLABLE_VALUES.to_unsafe.to_slice(W51_ARRAY_TUPLE_NULLABLE_VALUES.size), rows_per_mark: 2
)
empty_part = CrystalClick::WidePartWriter.write_uint64_array_tuple_uint64_string_pair(
  File.join(root, "writer-array-tuple-empty"), "pk", keys, "payload",
  W51_EMPTY_ARRAY_TUPLE_VALUES.to_unsafe.to_slice(W51_EMPTY_ARRAY_TUPLE_VALUES.size), rows_per_mark: 2
)
empty_string_mark_part = CrystalClick::WidePartWriter.write_uint64_array_tuple_uint64_string_pair(
  File.join(root, "writer-array-tuple-empty-string-mark"), "pk", keys, "payload",
  W51_EMPTY_STRING_MARK_VALUES.to_unsafe.to_slice(W51_EMPTY_STRING_MARK_VALUES.size), rows_per_mark: 2
)
assert_empty_string_mark_has_repeated_raw_boundary(empty_string_mark_part)
all_null_part = CrystalClick::WidePartWriter.write_uint64_array_tuple_nullable_uint64_string_pair(
  File.join(root, "writer-array-tuple-all-null"), "pk", keys, "payload",
  W51_ALL_NULL_ARRAY_TUPLE_VALUES.to_unsafe.to_slice(W51_ALL_NULL_ARRAY_TUPLE_VALUES.size), rows_per_mark: 2
)

verify_writer(binary, store, "w51_writer_array_tuple", "Array(Tuple(a UInt64, b String))", plain_part,
  rowbinary(W51_KEYS, W51_ARRAY_TUPLE_VALUES), rowbinary(range, range_values(W51_ARRAY_TUPLE_VALUES)))
verify_writer(binary, store, "w51_writer_array_tuple_nullable", "Array(Tuple(a Nullable(UInt64), b String))", nullable_part,
  rowbinary(W51_KEYS, W51_ARRAY_TUPLE_NULLABLE_VALUES), rowbinary(range, range_values(W51_ARRAY_TUPLE_NULLABLE_VALUES)))
verify_writer(binary, store, "w51_writer_array_tuple_empty", "Array(Tuple(a UInt64, b String))", empty_part,
  rowbinary(W51_KEYS, W51_EMPTY_ARRAY_TUPLE_VALUES), rowbinary(range, range_values(W51_EMPTY_ARRAY_TUPLE_VALUES)))
verify_writer(binary, store, "w51_writer_array_tuple_empty_string_mark", "Array(Tuple(a UInt64, b String))", empty_string_mark_part,
  rowbinary(W51_KEYS, W51_EMPTY_STRING_MARK_VALUES), rowbinary(range, range_values(W51_EMPTY_STRING_MARK_VALUES)))
verify_writer(binary, store, "w51_writer_array_tuple_all_null", "Array(Tuple(a Nullable(UInt64), b String))", all_null_part,
  rowbinary(W51_KEYS, W51_ALL_NULL_ARRAY_TUPLE_VALUES), rowbinary(range, range_values(W51_ALL_NULL_ARRAY_TUPLE_VALUES)))

puts "PASS W51 paired Array(Tuple) writer oracle"
CRYSTAL
