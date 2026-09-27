#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/Users/sergey/.local/bin/clickhouse}"
FIXTURE="${WIDE_INTEGER256_FIXTURE:-$ROOT/test/fixtures/public/wide_integer256}"
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
bash "$ROOT/scripts/verify_stock_wide_integer256_fixture.sh" "$FIXTURE"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/crystal-click-wide-integer256-oracle.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT
cd "$ROOT"
export CLICKHOUSE_BIN TMP_ROOT FIXTURE
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache"
mkdir -p "$CRYSTAL_CACHE_DIR"

crystal run --link-flags='-fuse-ld=ld' --stdin-filename "$ROOT/scripts/check_wide_integer256_oracle.cr" <<'CRYSTAL'
require "file_utils"
require "../src/crystal_click"

W37_KEYS = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64, 8_u64, 9_u64, 10_u64, 11_u64, 12_u64, 13_u64]
W37_SIGNED_WORDS = [
  {0x0000000000000000_u64, 0x0000000000000000_u64, 0x0000000000000000_u64, 0x0000000000000000_u64},
  {0xffffffffffffffff_u64, 0xffffffffffffffff_u64, 0xffffffffffffffff_u64, 0xffffffffffffffff_u64},
  {0x0000000000000001_u64, 0x0000000000000000_u64, 0x0000000000000000_u64, 0x0000000000000000_u64},
  {0x0000000000000000_u64, 0x0000000000000000_u64, 0x0000000000000000_u64, 0x8000000000000000_u64},
  {0xffffffffffffffff_u64, 0xffffffffffffffff_u64, 0xffffffffffffffff_u64, 0x7fffffffffffffff_u64},
  {0xffffffffffffffd6_u64, 0xffffffffffffffff_u64, 0xffffffffffffffff_u64, 0xffffffffffffffff_u64},
  {0x000000000000002a_u64, 0x0000000000000000_u64, 0x0000000000000000_u64, 0x0000000000000000_u64},
  {0x0000000000000000_u64, 0x0000000000000000_u64, 0x0000000000000000_u64, 0xc000000000000000_u64},
  {0x0000000000000000_u64, 0x0000000000000000_u64, 0x0000000000000000_u64, 0x4000000000000000_u64},
  {0x55205cd751c67eeb_u64, 0xa31f165a9fea013a_u64, 0xffffffffffffffff_u64, 0xffffffffffffffff_u64},
  {0xaadfa328ae398115_u64, 0x5ce0e9a56015fec5_u64, 0x0000000000000000_u64, 0x0000000000000000_u64},
  {0x0000000000000000_u64, 0x0000000000000000_u64, 0x0000000000000000_u64, 0x8000000000000000_u64},
  {0xffffffffffffffff_u64, 0xffffffffffffffff_u64, 0xffffffffffffffff_u64, 0x7fffffffffffffff_u64},
]
W37_UNSIGNED_WORDS = [
  {0x0000000000000000_u64, 0x0000000000000000_u64, 0x0000000000000000_u64, 0x0000000000000000_u64},
  {0x0000000000000001_u64, 0x0000000000000000_u64, 0x0000000000000000_u64, 0x0000000000000000_u64},
  {0xffffffffffffffff_u64, 0xffffffffffffffff_u64, 0xffffffffffffffff_u64, 0xffffffffffffffff_u64},
  {0x0000000000000000_u64, 0x0000000000000000_u64, 0x0000000000000000_u64, 0x8000000000000000_u64},
  {0x0000000000000001_u64, 0x0000000000000000_u64, 0x0000000000000000_u64, 0x8000000000000000_u64},
  {0xfffffffffffffffe_u64, 0xffffffffffffffff_u64, 0xffffffffffffffff_u64, 0xffffffffffffffff_u64},
  {0xffffffffffffffff_u64, 0xffffffffffffffff_u64, 0xffffffffffffffff_u64, 0x7fffffffffffffff_u64},
  {0x0000000000000000_u64, 0x0000000000000000_u64, 0x0000000000000000_u64, 0x4000000000000000_u64},
  {0x0000000000000002_u64, 0x0000000000000000_u64, 0x0000000000000000_u64, 0x8000000000000000_u64},
  {0xffffffffffffffff_u64, 0xffffffffffffffff_u64, 0xffffffffffffffff_u64, 0x7fffffffffffffff_u64},
  {0xfffffffffffffffd_u64, 0xffffffffffffffff_u64, 0xffffffffffffffff_u64, 0xffffffffffffffff_u64},
  {0x0000000000000000_u64, 0x0000000000000000_u64, 0x0000000000000000_u64, 0x0000000000000000_u64},
  {0x000000000000002a_u64, 0x0000000000000000_u64, 0x0000000000000000_u64, 0x0000000000000000_u64},
]

def run_clickhouse(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse query failed (#{status.exit_code}): #{query}" unless status.success?
  output.to_s
end

def create_table(binary : String, store : String, table : String, columns : String) : Nil
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
  raise "#{table}: expected 13 rows, 8 marks, Wide; got #{shape.inspect}" unless shape == "13\t8\tWide"
  name = active_part_name(binary, store, table)
  check = run_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "#{table}: CHECK TABLE failed: #{check.inspect}" unless check == "#{name}\t1"
  name
end

def assert_same_size_corruption(
  binary : String,
  store : String,
  table : String,
  part_path : String,
  part_name : String,
  stream_hash : String,
  expected_full_rowbinary : String,
) : Nil
  path = File.join(part_path, "#{stream_hash}.bin")
  original_size = File.size(path)
  original = File.open(path, "r") { |file| file.read_byte || raise "#{table}: empty stream #{path}" }
  damaged = ""
  begin
    File.open(path, "r+") do |file|
      file.pos = 0
      file.write_byte(original ^ 1_u8)
    end
    raise "#{table}: corruption changed stream length" unless File.size(path) == original_size
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
  raise "#{table}: restored stream length differs" unless File.size(path) == original_size
  check = run_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "#{table}: CHECK TABLE failed after restoring stream: #{check.inspect}" unless check == "#{part_name}\t1"
  actual = run_clickhouse(binary, store, "SELECT pk, i, u FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  assert_binary(actual, expected_full_rowbinary, "#{table} restored full RowBinary")
  nil
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

def append_words(io : IO, words : {UInt64, UInt64, UInt64, UInt64}) : Nil
  words.each do |word|
    8.times { |index| io.write_byte(((word >> (index * 8)) & 0xff_u64).to_u8) }
  end
end

def rowbinary_stock(keys : Array(UInt64), signed_words : Array({UInt64, UInt64, UInt64, UInt64}), unsigned_words : Array({UInt64, UInt64, UInt64, UInt64})) : String
  raise "stock RowBinary vector lengths differ" unless keys.size == signed_words.size && keys.size == unsigned_words.size
  output = IO::Memory.new
  keys.each_index do |index|
    append_u64(output, keys[index])
    append_words(output, signed_words[index])
    append_words(output, unsigned_words[index])
  end
  output.to_s
end

def rowbinary_payload(keys : Array(UInt64), words : Array({UInt64, UInt64, UInt64, UInt64})) : String
  raise "payload RowBinary vector lengths differ" unless keys.size == words.size
  output = IO::Memory.new
  keys.each_index do |index|
    append_u64(output, keys[index])
    append_words(output, words[index])
  end
  output.to_s
end

def assert_binary(actual : String, expected : String, label : String) : Nil
  raise "#{label}: RowBinary differs (expected #{expected.bytesize} bytes, got #{actual.bytesize})" unless actual.to_slice == expected.to_slice
end

def int256_values(words : Array({UInt64, UInt64, UInt64, UInt64})) : Array(CrystalClick::Int256Value)
  Array(CrystalClick::Int256Value).new(words.size) do |index|
    row = words[index]
    CrystalClick::Int256Value.from_words(row[0], row[1], row[2], row[3])
  end
end

def uint256_values(words : Array({UInt64, UInt64, UInt64, UInt64})) : Array(CrystalClick::UInt256Value)
  Array(CrystalClick::UInt256Value).new(words.size) do |index|
    row = words[index]
    CrystalClick::UInt256Value.from_words(row[0], row[1], row[2], row[3])
  end
end

def assert_keyed_reader(table : String, key_reader : CrystalClick::WidePart, value_reader : CrystalClick::WidePart, type_name : String, words : Array({UInt64, UInt64, UInt64, UInt64})) : Nil
  keys = key_reader.read_uint64_mark_range("pk", 1, 4)
  if type_name == "Int256"
    values = value_reader.read_int256_raw_mark_range("payload", 1, 4)
    selected = [] of {UInt64, CrystalClick::Int256Value}
    keys.each_index do |index|
      key = keys[index]
      selected << {key, values[index]} if key >= 4_u64 && key <= 10_u64
    end
    expected_values = int256_values(words)
    expected = Array({UInt64, CrystalClick::Int256Value}).new(7) { |index| {W37_KEYS[index + 3], expected_values[index + 3]} }
    raise "#{table}: Crystal Int256 keyed reader range differs" unless selected == expected
  else
    values = value_reader.read_uint256_raw_mark_range("payload", 1, 4)
    selected = [] of {UInt64, CrystalClick::UInt256Value}
    keys.each_index do |index|
      key = keys[index]
      selected << {key, values[index]} if key >= 4_u64 && key <= 10_u64
    end
    expected_values = uint256_values(words)
    expected = Array({UInt64, CrystalClick::UInt256Value}).new(7) { |index| {W37_KEYS[index + 3], expected_values[index + 3]} }
    raise "#{table}: Crystal UInt256 keyed reader range differs" unless selected == expected
  end
  nil
end

binary = ENV.fetch("CLICKHOUSE_BIN")
root = ENV.fetch("TMP_ROOT")
fixture = File.join(ENV.fetch("FIXTURE"), "part")
store = File.join(root, "clickhouse-store")
keys_slice = W37_KEYS.to_unsafe.to_slice(W37_KEYS.size)
signed_values = int256_values(W37_SIGNED_WORDS)
unsigned_values = uint256_values(W37_UNSIGNED_WORDS)
range_keys = W37_KEYS[3, 7]

# Stock ClickHouse part: attach/check first, then compare raw full/later-mark
# reads and independent full/keyed RowBinary bytes.
create_table(binary, store, "stock_integer256", "pk UInt64, i Int256, u UInt256")
attach_part(binary, store, "stock_integer256", fixture)
stock_name = assert_shape(binary, store, "stock_integer256", "pk\tUInt64\ni\tInt256\nu\tUInt256")
stock_path = active_part_path(binary, store, "stock_integer256")
stock_key_reader = CrystalClick::WidePart.open_typed(stock_path, "pk")
stock_i_reader = CrystalClick::WidePart.open_typed(stock_path, "i")
stock_u_reader = CrystalClick::WidePart.open_typed(stock_path, "u")
raise "stock Int256 type/mark shape mismatch" unless stock_i_reader.column_type == "Int256" && stock_i_reader.mark_row_counts == [2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 1_u64]
raise "stock UInt256 type/mark shape mismatch" unless stock_u_reader.column_type == "UInt256" && stock_u_reader.mark_row_counts == stock_i_reader.mark_row_counts
raise "stock Int256 full raw read differs" unless stock_i_reader.read_int256_raw_mark_range("i", 0, stock_i_reader.mark_count) == signed_values
raise "stock UInt256 full raw read differs" unless stock_u_reader.read_uint256_raw_mark_range("u", 0, stock_u_reader.mark_count) == unsigned_values
raise "stock Int256 later-mark read differs" unless stock_i_reader.read_int256_raw_mark_range("i", 1, 4) == signed_values[2, 8]
raise "stock UInt256 later-mark read differs" unless stock_u_reader.read_uint256_raw_mark_range("u", 1, 4) == unsigned_values[2, 8]
selected_stock_keys = stock_key_reader.read_uint64_mark_range("pk", 1, 4)
selected_stock_i = stock_i_reader.read_int256_raw_mark_range("i", 1, 4)
selected_stock_u = stock_u_reader.read_uint256_raw_mark_range("u", 1, 4)
selected_i = [] of {UInt64, CrystalClick::Int256Value}
selected_u = [] of {UInt64, CrystalClick::UInt256Value}
selected_stock_keys.each_index do |index|
  key = selected_stock_keys[index]
  if key >= 4_u64 && key <= 10_u64
    selected_i << {key, selected_stock_i[index]}
    selected_u << {key, selected_stock_u[index]}
  end
end
expected_i = Array({UInt64, CrystalClick::Int256Value}).new(7) { |index| {range_keys[index], signed_values[index + 3]} }
expected_u = Array({UInt64, CrystalClick::UInt256Value}).new(7) { |index| {range_keys[index], unsigned_values[index + 3]} }
raise "stock Crystal Int256 keyed result differs" unless selected_i == expected_i
raise "stock Crystal UInt256 keyed result differs" unless selected_u == expected_u
full = run_clickhouse(binary, store, "SELECT pk, i, u FROM default.stock_integer256 ORDER BY pk FORMAT RowBinary")
assert_binary(full, rowbinary_stock(W37_KEYS, W37_SIGNED_WORDS, W37_UNSIGNED_WORDS), "stock full")
keyed = run_clickhouse(binary, store, "SELECT pk, i, u FROM default.stock_integer256 WHERE pk >= 4 AND pk <= 10 ORDER BY pk FORMAT RowBinary")
assert_binary(keyed, rowbinary_stock(range_keys, W37_SIGNED_WORDS[3, 7], W37_UNSIGNED_WORDS[3, 7]), "stock keyed")
assert_same_size_corruption(
  binary, store, "stock_integer256", stock_path, stock_name,
  CrystalClick::StreamName.hash("i"), rowbinary_stock(W37_KEYS, W37_SIGNED_WORDS, W37_UNSIGNED_WORDS)
)
raise "stock part identity changed" unless active_part_name(binary, store, "stock_integer256") == stock_name
puts "PASS stock Int256/UInt256: ATTACH/CHECK, exact Crystal full/keyed reads, independent full/keyed RowBinary, same-size corruption detection"

# Crystal-created parts: ClickHouse independently attaches/checks and supplies
# full and keyed RowBinary for each signedness-specific writer entry point.
[{"Int256", "i"}, {"UInt256", "u"}].each do |type_name, label|
  writer_path = File.join(root, "writer-#{label}-part")
  if type_name == "Int256"
    CrystalClick::WidePartWriter.write_uint64_int256_pair(writer_path, "pk", keys_slice, "payload", signed_values.to_unsafe.to_slice(signed_values.size), 2)
    expected_words = W37_SIGNED_WORDS
  else
    CrystalClick::WidePartWriter.write_uint64_uint256_pair(writer_path, "pk", keys_slice, "payload", unsigned_values.to_unsafe.to_slice(unsigned_values.size), 2)
    expected_words = W37_UNSIGNED_WORDS
  end
  table = "writer_integer256_#{label}"
  create_table(binary, store, table, "pk UInt64, payload #{type_name}")
  attach_part(binary, store, table, writer_path)
  name = assert_shape(binary, store, table, "pk\tUInt64\npayload\t#{type_name}")
  attached_path = active_part_path(binary, store, table)
  writer_key_reader = CrystalClick::WidePart.open_typed(attached_path, "pk")
  writer_value_reader = CrystalClick::WidePart.open_typed(attached_path, "payload")
  if type_name == "Int256"
    raise "Crystal Int256 writer attached raw read differs" unless writer_value_reader.read_int256_raw_mark_range("payload", 0, writer_value_reader.mark_count) == signed_values
  else
    raise "Crystal UInt256 writer attached raw read differs" unless writer_value_reader.read_uint256_raw_mark_range("payload", 0, writer_value_reader.mark_count) == unsigned_values
  end
  assert_keyed_reader(table, writer_key_reader, writer_value_reader, type_name, expected_words)
  actual = run_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  assert_binary(actual, rowbinary_payload(W37_KEYS, expected_words), "Crystal #{type_name} writer full")
  actual_keyed = run_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} WHERE pk >= 4 AND pk <= 10 ORDER BY pk FORMAT RowBinary")
  assert_binary(actual_keyed, rowbinary_payload(range_keys, expected_words[3, 7]), "Crystal #{type_name} writer keyed")
  raise "Crystal #{type_name} writer part identity changed" unless active_part_name(binary, store, table) == name
  puts "PASS Crystal #{type_name} writer: ATTACH/CHECK, independent full/keyed RowBinary, attached Crystal full/keyed reads"
end

puts "PASS W37 raw Int256/UInt256 oracle on ClickHouse #{run_clickhouse(binary, store, "SELECT version()").strip}"
CRYSTAL

printf 'PASS W37 raw Int256/UInt256 oracle on %s\n' "$ACTUAL_VERSION"
