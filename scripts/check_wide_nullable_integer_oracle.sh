#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/Users/sergey/.local/bin/clickhouse}"
FIXTURE="$ROOT/test/fixtures/public/wide_nullable_integer128"
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
bash "$ROOT/scripts/verify_stock_wide_nullable_integer_fixture.sh" "$FIXTURE"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/crystal-click-wide-nullable-integer-oracle.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT
cd "$ROOT"
export CLICKHOUSE_BIN TMP_ROOT FIXTURE
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache"
mkdir -p "$CRYSTAL_CACHE_DIR"

crystal run --link-flags='-fuse-ld=ld' --stdin-filename "$ROOT/scripts/check_wide_nullable_integer_oracle.cr" <<'CRYSTAL'
require "file_utils"
require "../src/crystal_click"

W36_KEYS = Array(UInt64).new(32) { |index| index.to_u64 + 1_u64 }
W36_SIGNED = [
  nil.as(Int128?), -9_223_372_036_854_775_809_i128, -18_446_744_073_709_551_617_i128, nil.as(Int128?),
  Int128::MIN, Int128::MAX, -1_i128, 0_i128, nil.as(Int128?), 18_446_744_073_709_551_616_i128,
  -170_141_183_460_469_231_731_687_303_715_884_105_727_i128,
  12_345_678_901_234_567_890_123_456_789_012_345_678_i128, 0_i128, nil.as(Int128?), 1_i128, Int128::MAX,
  nil.as(Int128?), -1_267_650_600_228_229_401_496_703_205_376_i128,
  1_267_650_600_228_229_401_496_703_205_376_i128, 42_i128, nil.as(Int128?), -1_i128, 0_i128,
  18_446_744_073_709_551_615_i128, Int128::MIN, nil.as(Int128?),
  -170_141_183_460_469_231_731_687_303_715_884_105_727_i128,
  1_329_227_995_784_915_872_903_807_060_280_344_576_i128, nil.as(Int128?),
  -12_345_678_901_234_567_890_123_456_789_012_345_678_i128,
  12_345_678_901_234_567_890_123_456_789_012_345_678_i128, nil.as(Int128?),
] of Int128?
W36_UNSIGNED = [
  nil.as(UInt128?), 1_u128, UInt64::MAX.to_u128, nil.as(UInt128?), UInt128::MAX,
  170_141_183_460_469_231_731_687_303_715_884_105_728_u128, 18_446_744_073_709_551_616_u128,
  0_u128, nil.as(UInt128?), 18_446_744_073_709_551_617_u128,
  340_282_366_920_938_463_463_374_607_431_768_211_454_u128,
  12_345_678_901_234_567_890_123_456_789_012_345_678_u128, 0_u128, nil.as(UInt128?), 42_u128,
  UInt128::MAX, nil.as(UInt128?), 1_267_650_600_228_229_401_496_703_205_376_u128,
  340_282_366_920_938_463_463_374_607_431_768_211_454_u128, 1_u128, nil.as(UInt128?),
  18_446_744_073_709_551_616_u128, 0_u128, UInt128::MAX,
  170_141_183_460_469_231_731_687_303_715_884_105_728_u128,
  1_267_650_600_228_229_401_496_703_205_377_u128, 0_u128,
  340_282_366_920_938_463_463_374_607_431_768_211_454_u128, nil.as(UInt128?),
  12_345_678_901_234_567_890_123_456_789_012_345_678_u128, 0_u128, nil.as(UInt128?),
] of UInt128?

def run_clickhouse(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse query failed (#{status.exit_code}): #{query}" unless status.success?
  output.to_s
end

def create_table(binary : String, store : String, table : String, columns : String, nullable_version : String = "basic", sparse_ratio : String = "1.0") : Nil
  run_clickhouse(binary, store, <<-SQL)
  CREATE TABLE default.#{table} (#{columns})
  ENGINE = MergeTree
  ORDER BY pk
  SETTINGS
      index_granularity = 4,
      index_granularity_bytes = 10485760,
      enable_mixed_granularity_parts = 1,
      min_rows_for_wide_part = 0,
      min_bytes_for_wide_part = 0,
      compress_marks = 0,
      min_compress_block_size = 0,
      max_compress_block_size = 4096,
      default_compression_codec = 'LZ4',
      nullable_serialization_version = '#{nullable_version}',
      ratio_of_defaults_for_sparse_serialization = #{sparse_ratio};
  SQL
  nil
end

def active_part_name(binary : String, store : String, table : String) : String
  name = run_clickhouse(binary, store, "SELECT name FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw").strip
  raise "#{table}: missing or ambiguous active part #{name.inspect}" if name.empty? || name.includes?('\n')
  name
end

def active_part_path(binary : String, store : String, table : String) : String
  path = run_clickhouse(binary, store, "SELECT path FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw").strip
  raise "#{table}: active part path missing" if path.empty?
  path
end

def assert_shape(binary : String, store : String, table : String, expected_columns : String) : String
  actual_columns = run_clickhouse(binary, store, "SELECT name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TabSeparated").strip
  raise "#{table}: schema differs: #{actual_columns.inspect}" unless actual_columns == expected_columns
  shape = run_clickhouse(binary, store, "SELECT rows, marks, part_type FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TabSeparated").strip
  raise "#{table}: expected 32 rows, 9 marks, Wide; got #{shape.inspect}" unless shape == "32\t9\tWide"
  name = active_part_name(binary, store, table)
  check = run_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "#{table}: CHECK TABLE failed: #{check.inspect}" unless check == "#{name}\t1"
  name
end

def attach_part(binary : String, store : String, table : String, source_path : String) : Nil
  data_path = run_clickhouse(binary, store, "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw").strip
  raise "#{table}: data path missing" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(source_path, File.join(detached, "all_1_1_0"))
  run_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  nil
end

def append_u64(io : IO, value : UInt64) : Nil
  8.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
end

def append_i128(io : IO, value : Int128) : Nil
  bits = value.unsafe_as(UInt128)
  16.times { |index| io.write_byte(((bits >> (index * 8)) & 0xff_u128).to_u8) }
end

def append_u128(io : IO, value : UInt128) : Nil
  16.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u128).to_u8) }
end

def append_nullable(io : IO, value : Int128?) : Nil
  if present = value
    io.write_byte(0_u8)
    append_i128(io, present)
  else
    io.write_byte(1_u8)
  end
end

def append_nullable(io : IO, value : UInt128?) : Nil
  if present = value
    io.write_byte(0_u8)
    append_u128(io, present)
  else
    io.write_byte(1_u8)
  end
end

def rowbinary_all(keys : Array(UInt64), signed : Array(Int128?), unsigned : Array(UInt128?)) : String
  raise "W36 fixture lengths differ" unless keys.size == signed.size && keys.size == unsigned.size
  output = IO::Memory.new
  keys.each_index do |index|
    append_u64(output, keys[index])
    append_nullable(output, signed[index])
    append_nullable(output, unsigned[index])
  end
  output.to_s
end

def rowbinary_signed(keys : Array(UInt64), values : Array(Int128?)) : String
  raise "W36 signed lengths differ" unless keys.size == values.size
  output = IO::Memory.new
  keys.each_index do |index|
    append_u64(output, keys[index])
    append_nullable(output, values[index])
  end
  output.to_s
end

def rowbinary_unsigned(keys : Array(UInt64), values : Array(UInt128?)) : String
  raise "W36 unsigned lengths differ" unless keys.size == values.size
  output = IO::Memory.new
  keys.each_index do |index|
    append_u64(output, keys[index])
    append_nullable(output, values[index])
  end
  output.to_s
end

def assert_binary(actual : String, expected : String, label : String) : Nil
  raise "#{label}: RowBinary differs (expected #{expected.bytesize} bytes, got #{actual.bytesize})" unless actual.to_slice == expected.to_slice
end

binary = ENV.fetch("CLICKHOUSE_BIN")
root = ENV.fetch("TMP_ROOT")
fixture = File.join(ENV.fetch("FIXTURE"), "part")
store = File.join(root, "clickhouse-store")
stock_columns = "pk\tUInt64\nsigned\tNullable(Int128)\nunsigned\tNullable(UInt128)"

# Stock-created BASIC part: independent RowBinary encoding checks NULL flags,
# signed little-endian values, unsigned >64-bit values, and mark boundaries.
create_table(binary, store, "stock_nullable128", "pk UInt64, signed Nullable(Int128), unsigned Nullable(UInt128)")
attach_part(binary, store, "stock_nullable128", fixture)
stock_name = assert_shape(binary, store, "stock_nullable128", stock_columns)
stock_path = active_part_path(binary, store, "stock_nullable128")
signed_reader = CrystalClick::WidePart.open_typed(stock_path, "signed")
unsigned_reader = CrystalClick::WidePart.open_typed(stock_path, "unsigned")
raise "stock signed type/mark shape mismatch" unless signed_reader.column_type == "Nullable(Int128)" && signed_reader.mark_row_counts == Array(UInt64).new(8, 4_u64)
raise "stock unsigned type/mark shape mismatch" unless unsigned_reader.column_type == "Nullable(UInt128)" && unsigned_reader.mark_row_counts == signed_reader.mark_row_counts
raise "stock signed full raw read differs" unless signed_reader.read_nullable_int128_raw_mark_range("signed", 0, signed_reader.mark_count) == W36_SIGNED
raise "stock unsigned full raw read differs" unless unsigned_reader.read_nullable_uint128_raw_mark_range("unsigned", 0, unsigned_reader.mark_count) == W36_UNSIGNED
raise "stock signed later mark read differs" unless signed_reader.read_nullable_int128_raw_mark_range("signed", 1, 2) == W36_SIGNED[4, 8]
raise "stock unsigned later mark read differs" unless unsigned_reader.read_nullable_uint128_raw_mark_range("unsigned", 1, 2) == W36_UNSIGNED[4, 8]
full = run_clickhouse(binary, store, "SELECT pk, signed, unsigned FROM default.stock_nullable128 ORDER BY pk FORMAT RowBinary")
assert_binary(full, rowbinary_all(W36_KEYS, W36_SIGNED, W36_UNSIGNED), "stock full")
range_keys = W36_KEYS[6, 21]
range_signed = W36_SIGNED[6, 21]
range_unsigned = W36_UNSIGNED[6, 21]
ranged = run_clickhouse(binary, store, "SELECT pk, signed, unsigned FROM default.stock_nullable128 WHERE pk >= 7 AND pk < 28 ORDER BY pk FORMAT RowBinary")
assert_binary(ranged, rowbinary_all(range_keys, range_signed, range_unsigned), "stock keyed range")
raise "stock part identity changed" unless active_part_name(binary, store, "stock_nullable128") == stock_name
puts "PASS stock BASIC Nullable(Int128/UInt128): ATTACH/CHECK, exact raw full/later-mark reads, independent full/keyed RowBinary"

# Stock Sparse control remains valid for ClickHouse but outside Crystal's BASIC reader.
sparse_fixture = File.join(ENV.fetch("FIXTURE"), "sparse", "part")
create_table(binary, store, "sparse_nullable128", "pk UInt64, signed Nullable(Int128), unsigned Nullable(UInt128)", "allow_sparse", "0.5")
attach_part(binary, store, "sparse_nullable128", sparse_fixture)
assert_shape(binary, store, "sparse_nullable128", stock_columns)
{"signed", "unsigned"}.each do |column|
  begin
    CrystalClick::WidePart.open_typed(active_part_path(binary, store, "sparse_nullable128"), column)
    raise "Crystal accepted Sparse nullable column #{column}"
  rescue CrystalClick::UnsupportedFormatError
  end
end
puts "PASS stock Sparse control: nullable:1/.sparse.idx attaches and checks in ClickHouse, Crystal rejects both columns"

# Each explicit Crystal writer is checked by the independent pinned reader.
[{"signed", "Nullable(Int128)"}, {"unsigned", "Nullable(UInt128)"}].each do |label, type|
  table = "writer_nullable_#{label}"
  writer_path = File.join(root, "writer-#{label}-part")
  keys_slice = W36_KEYS.to_unsafe.to_slice(W36_KEYS.size)
  if label == "signed"
    CrystalClick::WidePartWriter.write_uint64_nullable_int128_pair(writer_path, "pk", keys_slice, "payload", W36_SIGNED.to_unsafe.to_slice(W36_SIGNED.size), 4)
  else
    CrystalClick::WidePartWriter.write_uint64_nullable_uint128_pair(writer_path, "pk", keys_slice, "payload", W36_UNSIGNED.to_unsafe.to_slice(W36_UNSIGNED.size), 4)
  end
  create_table(binary, store, table, "pk UInt64, payload #{type}")
  attach_part(binary, store, table, writer_path)
  name = assert_shape(binary, store, table, "pk\tUInt64\npayload\t#{type}")
  path = active_part_path(binary, store, table)
  condition = " WHERE pk >= 7 AND pk < 28"
  if label == "signed"
    actual = run_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
    assert_binary(actual, rowbinary_signed(W36_KEYS, W36_SIGNED), "Crystal Nullable(Int128) full")
    actual_range = run_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table}#{condition} ORDER BY pk FORMAT RowBinary")
    assert_binary(actual_range, rowbinary_signed(range_keys, range_signed), "Crystal Nullable(Int128) keyed range")
    raise "Crystal Nullable(Int128) attached read differs" unless CrystalClick::WidePart.open_typed(path, "payload").read_nullable_int128_raw_mark_range("payload", 0, 8) == W36_SIGNED
  else
    actual = run_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
    assert_binary(actual, rowbinary_unsigned(W36_KEYS, W36_UNSIGNED), "Crystal Nullable(UInt128) full")
    actual_range = run_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table}#{condition} ORDER BY pk FORMAT RowBinary")
    assert_binary(actual_range, rowbinary_unsigned(range_keys, range_unsigned), "Crystal Nullable(UInt128) keyed range")
    raise "Crystal Nullable(UInt128) attached read differs" unless CrystalClick::WidePart.open_typed(path, "payload").read_nullable_uint128_raw_mark_range("payload", 0, 8) == W36_UNSIGNED
  end
  raise "writer part identity changed" unless active_part_name(binary, store, table) == name
  puts "PASS Crystal #{type} writer: ATTACH/CHECK, independent full/keyed RowBinary, attached raw reader"
end

puts "PASS W36 nullable raw 128-bit oracle on ClickHouse #{run_clickhouse(binary, store, "SELECT version()").strip}"
CRYSTAL

printf 'PASS W36 nullable raw Int128/UInt128 oracle on %s\n' "$ACTUAL_VERSION"
