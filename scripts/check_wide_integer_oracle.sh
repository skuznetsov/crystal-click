#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/Users/sergey/.local/bin/clickhouse}"
FIXTURE="$ROOT/test/fixtures/public/wide_integer128"
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

"$ROOT/scripts/verify_stock_wide_integer_fixture.sh" "$FIXTURE"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/crystal-click-wide-integer-oracle.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

cd "$ROOT"
export CLICKHOUSE_BIN TMP_ROOT FIXTURE
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache"
mkdir -p "$CRYSTAL_CACHE_DIR"

crystal run --link-flags='-fuse-ld=ld' --stdin-filename "$ROOT/scripts/check_wide_integer_oracle.cr" <<'CRYSTAL'
require "file_utils"
require "../src/crystal_click"

W35_KEYS = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64, 17_u64, 19_u64, 21_u64, 25_u64, 31_u64, 40_u64]
W35_SIGNED = [
  Int128::MIN,
  -9_223_372_036_854_775_809_i128,
  -18_446_744_073_709_551_617_i128,
  -1_i128,
  0_i128,
  1_i128,
  18_446_744_073_709_551_615_i128,
  18_446_744_073_709_551_616_i128,
  -170_141_183_460_469_231_731_687_303_715_884_105_727_i128,
  170_141_183_460_469_231_731_687_303_715_884_105_726_i128,
  12_345_678_901_234_567_890_123_456_789_012_345_678_i128,
  -12_345_678_901_234_567_890_123_456_789_012_345_678_i128,
  Int128::MAX,
]
W35_UNSIGNED = [
  0_u128,
  1_u128,
  18_446_744_073_709_551_615_u128,
  18_446_744_073_709_551_616_u128,
  18_446_744_073_709_551_617_u128,
  170_141_183_460_469_231_731_687_303_715_884_105_727_u128,
  170_141_183_460_469_231_731_687_303_715_884_105_728_u128,
  UInt128::MAX,
  340_282_366_920_938_463_463_374_607_431_768_211_454_u128,
  12_345_678_901_234_567_890_123_456_789_012_345_678_u128,
  18_446_744_073_709_551_616_u128,
  295_147_905_179_352_825_856_u128,
  42_u128,
]

def run_clickhouse(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse query failed (#{status.exit_code}): #{query}" unless status.success?
  output.to_s
end

def run_clickhouse_input(binary : String, store : String, query : String, input : IO) : String
  output = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], input: input, output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse RowBinary insert failed (#{status.exit_code}): #{query}" unless status.success?
  output.to_s
end

def create_table(binary : String, store : String, table : String, type_name : String, include_both : Bool = false) : Nil
  columns = if include_both
             "`pk` UInt64, `signed` Int128, `unsigned` UInt128"
           else
             "`pk` UInt64, `payload` #{type_name}"
           end
  run_clickhouse(binary, store, <<-SQL)
  CREATE TABLE default.#{table} (#{columns})
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
      default_compression_codec = 'LZ4';
  SQL
  nil
end

def append_u64_le(io : IO, value : UInt64) : Nil
  8.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
end

def append_i128_le(io : IO, value : Int128) : Nil
  bits = value.unsafe_as(UInt128)
  16.times { |index| io.write_byte(((bits >> (index * 8)) & 0xff_u128).to_u8) }
end

def append_u128_le(io : IO, value : UInt128) : Nil
  16.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u128).to_u8) }
end

def rowbinary(keys : Array(UInt64), values : Array(Int128)) : String
  raise "RowBinary lengths differ" unless keys.size == values.size
  output = IO::Memory.new
  keys.each_with_index do |key, index|
    append_u64_le(output, key)
    append_i128_le(output, values[index])
  end
  output.to_s
end

def rowbinary(keys : Array(UInt64), values : Array(UInt128)) : String
  raise "RowBinary lengths differ" unless keys.size == values.size
  output = IO::Memory.new
  keys.each_with_index do |key, index|
    append_u64_le(output, key)
    append_u128_le(output, values[index])
  end
  output.to_s
end

def assert_bytes(actual : String, expected : String, label : String) : Nil
  return if actual.to_slice == expected.to_slice
  raise "#{label}: RowBinary differs (expected #{expected.bytesize} bytes, got #{actual.bytesize})"
end

def active_part_name(binary : String, store : String, table : String) : String
  value = run_clickhouse(binary, store, "SELECT name FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw").strip
  raise "#{table}: missing/ambiguous part name #{value.inspect}" if value.empty? || value.includes?('\n')
  value
end

def active_part_path(binary : String, store : String, table : String) : String
  value = run_clickhouse(binary, store, "SELECT path FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw").strip
  raise "#{table}: part path missing" if value.empty?
  value
end

def assert_metadata(binary : String, store : String, table : String, expected_types : String, part_name : String) : Nil
  types = run_clickhouse(binary, store, "SELECT name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TabSeparated").strip
  raise "#{table}: column metadata differs: #{types.inspect}" unless types == expected_types
  shape = run_clickhouse(binary, store, "SELECT rows, marks, part_type FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TabSeparated").strip
  # ClickHouse system.parts counts the sentinel row in this pinned part.
  raise "#{table}: expected 13 rows, 8 mark records, Wide; got #{shape.inspect}" unless shape == "13\t8\tWide"
  raise "#{table}: active part changed" unless active_part_name(binary, store, table) == part_name
end

def assert_check(binary : String, store : String, table : String, part_name : String) : Nil
  output = run_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "#{table}: CHECK TABLE failed: #{output.inspect}" unless output == "#{part_name}\t1"
end

def assert_same_size_corruption(binary : String, store : String, table : String, part_path : String, part_name : String, stream_hash : String) : Nil
  path = File.join(part_path, "#{stream_hash}.bin")
  original = File.open(path, "r") { |file| file.read_byte || raise "empty stream #{path}" }
  damaged = ""
  begin
    File.open(path, "r+") do |file|
      file.pos = 0
      file.write_byte(original ^ 1_u8)
    end
    damaged = run_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  ensure
    File.open(path, "r+") do |file|
      file.pos = 0
      file.write_byte(original)
    end
  end
  fields = damaged.split('\t', 3)
  unless fields.size == 3 && fields[0] == part_name && fields[1] == "0" && fields[2].includes?("CHECKSUM_DOESNT_MATCH")
    raise "#{table}: CHECK TABLE missed same-size stream corruption: #{damaged.inspect}"
  end
  assert_check(binary, store, table, part_name)
end

def attach_part(binary : String, store : String, table : String, source_path : String) : Nil
  data_path = run_clickhouse(binary, store, "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw").strip
  raise "#{table}: ClickHouse data path missing" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(source_path, File.join(detached, "all_1_1_0"))
  run_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  nil
end

binary = ENV.fetch("CLICKHOUSE_BIN")
root = ENV.fetch("TMP_ROOT")
fixture = File.join(ENV.fetch("FIXTURE"), "part")
store = File.join(root, "clickhouse-store")
expected_types = "pk\tUInt64\nsigned\tInt128\nunsigned\tUInt128"

# Stock-created three-column part: this is the compatibility authority for both readers.
create_table(binary, store, "stock_raw128", "", true)
attach_part(binary, store, "stock_raw128", fixture)
stock_name = active_part_name(binary, store, "stock_raw128")
assert_metadata(binary, store, "stock_raw128", expected_types, stock_name)
assert_check(binary, store, "stock_raw128", stock_name)
stock_path = active_part_path(binary, store, "stock_raw128")
signed_part = CrystalClick::WidePart.open_typed(stock_path, "signed")
unsigned_part = CrystalClick::WidePart.open_typed(stock_path, "unsigned")
raise "stock Int128 metadata differs" unless signed_part.column_type == "Int128" && signed_part.row_count == 13_u64
raise "stock UInt128 metadata differs" unless unsigned_part.column_type == "UInt128" && unsigned_part.row_count == 13_u64
raise "stock raw Int128 rows differ" unless signed_part.read_int128_raw_mark_range("signed", 0, signed_part.mark_count) == W35_SIGNED
raise "stock raw UInt128 rows differ" unless unsigned_part.read_uint128_raw_mark_range("unsigned", 0, unsigned_part.mark_count) == W35_UNSIGNED
full_signed = rowbinary(W35_KEYS, W35_SIGNED)
full_unsigned = rowbinary(W35_KEYS, W35_UNSIGNED)
assert_bytes(run_clickhouse(binary, store, "SELECT pk, signed FROM default.stock_raw128 ORDER BY pk FORMAT RowBinary"), full_signed, "stock Int128 full read")
assert_bytes(run_clickhouse(binary, store, "SELECT pk, unsigned FROM default.stock_raw128 ORDER BY pk FORMAT RowBinary"), full_unsigned, "stock UInt128 full read")
range_keys = W35_KEYS[2, 8]
range_signed = W35_SIGNED[2, 8]
range_unsigned = W35_UNSIGNED[2, 8]
assert_bytes(run_clickhouse(binary, store, "SELECT pk, signed FROM default.stock_raw128 WHERE pk >= 4 AND pk < 25 ORDER BY pk FORMAT RowBinary"), rowbinary(range_keys, range_signed), "stock Int128 keyed read")
assert_bytes(run_clickhouse(binary, store, "SELECT pk, unsigned FROM default.stock_raw128 WHERE pk >= 4 AND pk < 25 ORDER BY pk FORMAT RowBinary"), rowbinary(range_keys, range_unsigned), "stock UInt128 keyed read")
assert_same_size_corruption(binary, store, "stock_raw128", stock_path, stock_name, CrystalClick::StreamName.hash("signed"))
puts "PASS stock Int128/UInt128: exact schema, ATTACH/CHECK, raw reader, full/keyed RowBinary, corruption detection"

# Crystal-created parts are attached independently for the two explicit APIs.
[{"int128", "Int128"}, {"uint128", "UInt128"}].each do |label, type_name|
  table = "writer_#{label}"
  writer_path = File.join(root, "writer-#{label}-part")
  keys_slice = W35_KEYS.to_unsafe.to_slice(W35_KEYS.size)
  if label == "int128"
    values = W35_SIGNED
    CrystalClick::WidePartWriter.write_uint64_int128_pair(writer_path, "pk", keys_slice, "payload", values.to_unsafe.to_slice(values.size), 2)
  else
    values = W35_UNSIGNED
    CrystalClick::WidePartWriter.write_uint64_uint128_pair(writer_path, "pk", keys_slice, "payload", values.to_unsafe.to_slice(values.size), 2)
  end

  create_table(binary, store, table, type_name)
  attach_part(binary, store, table, writer_path)
  part_name = active_part_name(binary, store, table)
  assert_metadata(binary, store, table, "pk\tUInt64\npayload\t#{type_name}", part_name)
  assert_check(binary, store, table, part_name)
  attached_path = active_part_path(binary, store, table)
  expected = rowbinary(W35_KEYS, values)
  actual = run_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  assert_bytes(actual, expected, "Crystal #{type_name} full read")
  range_values = values[2, 8]
  actual_range = run_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} WHERE pk >= 4 AND pk < 25 ORDER BY pk FORMAT RowBinary")
  assert_bytes(actual_range, rowbinary(range_keys, range_values), "Crystal #{type_name} keyed read")

  reader = CrystalClick::WidePart.open_typed(attached_path, "payload")
  if label == "int128"
    raise "writer Int128 reader mismatch" unless reader.read_int128_raw_mark_range("payload", 0, reader.mark_count) == W35_SIGNED
  else
    raise "writer UInt128 reader mismatch" unless reader.read_uint128_raw_mark_range("payload", 0, reader.mark_count) == W35_UNSIGNED
  end
  assert_same_size_corruption(binary, store, table, attached_path, part_name, CrystalClick::StreamName.hash("payload"))
  puts "PASS Crystal #{type_name}: explicit writer, ATTACH/CHECK, full/keyed RowBinary, raw reader, corruption detection"
end

puts "PASS W35 raw wide integer oracle on ClickHouse #{run_clickhouse(binary, store, "SELECT version()").strip}"
CRYSTAL

printf 'PASS W35 raw Int128/UInt128 oracle on %s\n' "$ACTUAL_VERSION"
