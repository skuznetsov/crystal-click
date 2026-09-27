#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-/Users/sergey/.local/bin/clickhouse}"
FIXTURE="${WIDE_NULLABLE_INTEGER256_FIXTURE:-$ROOT/test/fixtures/public/wide_nullable_integer256}"
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
bash "$ROOT/scripts/verify_stock_wide_nullable_integer256_fixture.sh" "$FIXTURE"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/crystal-click-wide-nullable-integer256-oracle.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT
cd "$ROOT"
export CLICKHOUSE_BIN TMP_ROOT FIXTURE
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache"
mkdir -p "$CRYSTAL_CACHE_DIR"

crystal run --link-flags='-fuse-ld=ld' --stdin-filename "$ROOT/scripts/check_wide_nullable_integer256_oracle.cr" <<'CRYSTAL'
require "file_utils"
require "../src/crystal_click"

W38_KEYS = Array(UInt64).new(13) { |index| index.to_u64 + 1_u64 }
W38_SIGNED_WORDS = [
  {0_u64, 0_u64, 0_u64, 0_u64},
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
  {0x0000000000000000_u64, 0x0000000000000000_u64, 0x0000000000000000_u64, 0x0000000000000000_u64},
  {0xffffffffffffffff_u64, 0xffffffffffffffff_u64, 0xffffffffffffffff_u64, 0x7fffffffffffffff_u64},
]
W38_UNSIGNED_WORDS = [
  {0x0000000000000000_u64, 0x0000000000000000_u64, 0x0000000000000000_u64, 0x0000000000000000_u64},
  {0x0000000000000001_u64, 0x0000000000000000_u64, 0x0000000000000000_u64, 0x0000000000000000_u64},
  {0xffffffffffffffff_u64, 0xffffffffffffffff_u64, 0xffffffffffffffff_u64, 0xffffffffffffffff_u64},
  {0x0000000000000000_u64, 0x0000000000000000_u64, 0x0000000000000000_u64, 0x8000000000000000_u64},
  {0x0000000000000000_u64, 0x0000000000000000_u64, 0x0000000000000000_u64, 0x0000000000000000_u64},
  {0xfffffffffffffffe_u64, 0xffffffffffffffff_u64, 0xffffffffffffffff_u64, 0xffffffffffffffff_u64},
  {0xffffffffffffffff_u64, 0xffffffffffffffff_u64, 0xffffffffffffffff_u64, 0x7fffffffffffffff_u64},
  {0x0000000000000000_u64, 0x0000000000000000_u64, 0x0000000000000000_u64, 0x4000000000000000_u64},
  {0x0000000000000002_u64, 0x0000000000000000_u64, 0x0000000000000000_u64, 0x8000000000000000_u64},
  {0xffffffffffffffff_u64, 0xffffffffffffffff_u64, 0xffffffffffffffff_u64, 0x7fffffffffffffff_u64},
  {0xfffffffffffffffd_u64, 0xffffffffffffffff_u64, 0xffffffffffffffff_u64, 0xffffffffffffffff_u64},
  {0x0000000000000000_u64, 0x0000000000000000_u64, 0x0000000000000000_u64, 0x0000000000000000_u64},
  {0x000000000000002a_u64, 0x0000000000000000_u64, 0x0000000000000000_u64, 0x0000000000000000_u64},
]

W38_SIGNED = Array(CrystalClick::Int256Value?).new(W38_SIGNED_WORDS.size) do |index|
  if index == 0 || index == 11
    nil
  else
    words = W38_SIGNED_WORDS[index]
    CrystalClick::Int256Value.from_words(words[0], words[1], words[2], words[3])
  end
end
W38_UNSIGNED = Array(CrystalClick::UInt256Value?).new(W38_UNSIGNED_WORDS.size) do |index|
  if index == 0 || index == 4 || index == 11
    nil
  else
    words = W38_UNSIGNED_WORDS[index]
    CrystalClick::UInt256Value.from_words(words[0], words[1], words[2], words[3])
  end
end

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
      index_granularity = 2,
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

def assert_shape(binary : String, store : String, table : String, expected_columns : String, expected_rows : Int32 = 13, expected_marks : Int32 = 8) : String
  actual_columns = run_clickhouse(binary, store, "SELECT name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TabSeparated").strip
  raise "#{table}: schema differs: #{actual_columns.inspect}" unless actual_columns == expected_columns
  shape = run_clickhouse(binary, store, "SELECT rows, marks, part_type FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TabSeparated").strip
  expected_shape = "#{expected_rows}\t#{expected_marks}\tWide"
  raise "#{table}: expected #{expected_shape} rows/marks, Wide; got #{shape.inspect}" unless shape == expected_shape
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

def append_u128(io : IO, value : UInt128) : Nil
  16.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u128).to_u8) }
end

def append_int256(io : IO, value : CrystalClick::Int256Value) : Nil
  append_u128(io, value.low)
  append_u128(io, value.high)
end

def append_uint256(io : IO, value : CrystalClick::UInt256Value) : Nil
  append_u128(io, value.low)
  append_u128(io, value.high)
end

def append_nullable(io : IO, value : CrystalClick::Int256Value?) : Nil
  if present = value
    io.write_byte(0_u8)
    append_int256(io, present)
  else
    io.write_byte(1_u8)
  end
end

def append_nullable(io : IO, value : CrystalClick::UInt256Value?) : Nil
  if present = value
    io.write_byte(0_u8)
    append_uint256(io, present)
  else
    io.write_byte(1_u8)
  end
end

def rowbinary_all(keys : Array(UInt64), signed : Array(CrystalClick::Int256Value?), unsigned : Array(CrystalClick::UInt256Value?)) : String
  raise "W38 fixture vector lengths differ" unless keys.size == signed.size && keys.size == unsigned.size
  output = IO::Memory.new
  keys.each_index do |index|
    append_u64(output, keys[index])
    append_nullable(output, signed[index])
    append_nullable(output, unsigned[index])
  end
  output.to_s
end

def rowbinary_signed(keys : Array(UInt64), values : Array(CrystalClick::Int256Value?)) : String
  raise "W38 signed writer vector lengths differ" unless keys.size == values.size
  output = IO::Memory.new
  keys.each_index do |index|
    append_u64(output, keys[index])
    append_nullable(output, values[index])
  end
  output.to_s
end

def rowbinary_unsigned(keys : Array(UInt64), values : Array(CrystalClick::UInt256Value?)) : String
  raise "W38 unsigned writer vector lengths differ" unless keys.size == values.size
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

binary = ENV.fetch("CLICKHOUSE_BIN")
root = ENV.fetch("TMP_ROOT")
fixture = File.join(ENV.fetch("FIXTURE"), "part")
store = File.join(root, "clickhouse-store")
stock_columns = "pk\tUInt64\ni\tNullable(Int256)\nu\tNullable(UInt256)"
full_expected = rowbinary_all(W38_KEYS, W38_SIGNED, W38_UNSIGNED)
range_keys = W38_KEYS[2, 8]
range_signed = W38_SIGNED[2, 8]
range_unsigned = W38_UNSIGNED[2, 8]

# Stock ClickHouse BASIC part: raw nullable maps and child slots are read by
# Crystal, while independent RowBinary catches NULL omission and 256-bit endian.
create_table(binary, store, "stock_nullable256", "pk UInt64, i Nullable(Int256), u Nullable(UInt256)")
attach_part(binary, store, "stock_nullable256", fixture)
stock_name = assert_shape(binary, store, "stock_nullable256", stock_columns)
stock_path = active_part_path(binary, store, "stock_nullable256")
key_reader = CrystalClick::WidePart.open_typed(stock_path, "pk")
signed_reader = CrystalClick::WidePart.open_typed(stock_path, "i")
unsigned_reader = CrystalClick::WidePart.open_typed(stock_path, "u")
expected_mark_rows = [2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 1_u64]
raise "stock nullable Int256 type/mark shape mismatch" unless signed_reader.column_type == "Nullable(Int256)" && signed_reader.mark_row_counts == expected_mark_rows
raise "stock nullable UInt256 type/mark shape mismatch" unless unsigned_reader.column_type == "Nullable(UInt256)" && unsigned_reader.mark_row_counts == expected_mark_rows
raise "stock Nullable(Int256) full read differs" unless signed_reader.read_nullable_int256_raw_mark_range("i", 0, signed_reader.mark_count) == W38_SIGNED
raise "stock Nullable(UInt256) full read differs" unless unsigned_reader.read_nullable_uint256_raw_mark_range("u", 0, unsigned_reader.mark_count) == W38_UNSIGNED
raise "stock Nullable(Int256) later-mark read differs" unless signed_reader.read_nullable_int256_raw_mark_range("i", 1, 4) == W38_SIGNED[2, 8]
raise "stock Nullable(UInt256) later-mark read differs" unless unsigned_reader.read_nullable_uint256_raw_mark_range("u", 1, 4) == W38_UNSIGNED[2, 8]
raise "stock key mark range differs" unless key_reader.read_uint64_mark_range("pk", 1, 4) == range_keys
full = run_clickhouse(binary, store, "SELECT pk, i, u FROM default.stock_nullable256 ORDER BY pk FORMAT RowBinary")
assert_binary(full, full_expected, "stock BASIC full")
ranged = run_clickhouse(binary, store, "SELECT pk, i, u FROM default.stock_nullable256 WHERE pk >= 3 AND pk <= 10 ORDER BY pk FORMAT RowBinary")
assert_binary(ranged, rowbinary_all(range_keys, range_signed, range_unsigned), "stock BASIC keyed range")
raise "stock part identity changed" unless active_part_name(binary, store, "stock_nullable256") == stock_name
puts "PASS stock BASIC Nullable(Int256/UInt256): ATTACH/CHECK, exact raw full/later-mark reads, independent full/keyed RowBinary"

# The separate stock Sparse control is valid for ClickHouse but outside the
# scalar BASIC admission implemented in W38.
sparse_fixture = File.join(ENV.fetch("FIXTURE"), "sparse", "part")
create_table(binary, store, "sparse_nullable256", "pk UInt64, i Nullable(Int256), u Nullable(UInt256)", "allow_sparse", "0.5")
attach_part(binary, store, "sparse_nullable256", sparse_fixture)
assert_shape(binary, store, "sparse_nullable256", stock_columns, 32, 17)
sparse_path = active_part_path(binary, store, "sparse_nullable256")
{"i", "u"}.each do |column|
  begin
    CrystalClick::WidePart.open_typed(sparse_path, column)
    raise "Crystal accepted Sparse nullable column #{column}"
  rescue CrystalClick::UnsupportedFormatError
  end
end
puts "PASS stock Sparse control: nullable:1/Sparse streams attach and check in ClickHouse, Crystal rejects both columns"

# Same-size corruption changes the attached stock null-map frame in place.
# CHECK TABLE must catch it, restoration must be exact, and both CHECK/RowBinary
# must recover before continuing.
assert_same_size_corruption(
  binary,
  store,
  "stock_nullable256",
  stock_path,
  stock_name,
  CrystalClick::StreamName.hash("i.null"),
  full_expected,
)
puts "PASS stock same-size null-map corruption: checksum rejection and exact recovery"

# Crystal's explicit writers are independently admitted by ClickHouse and then
# checked through its full/keyed RowBinary serialization and Crystal re-read.
[{"signed", "Nullable(Int256)"}, {"unsigned", "Nullable(UInt256)"}].each do |label, type|
  table = "writer_nullable_#{label}256"
  writer_path = File.join(root, "writer-#{label}-part")
  keys_slice = W38_KEYS.to_unsafe.to_slice(W38_KEYS.size)
  if label == "signed"
    CrystalClick::WidePartWriter.write_uint64_nullable_int256_pair(
      writer_path, "pk", keys_slice, "payload", W38_SIGNED.to_unsafe.to_slice(W38_SIGNED.size), 2
    )
  else
    CrystalClick::WidePartWriter.write_uint64_nullable_uint256_pair(
      writer_path, "pk", keys_slice, "payload", W38_UNSIGNED.to_unsafe.to_slice(W38_UNSIGNED.size), 2
    )
  end
  create_table(binary, store, table, "pk UInt64, payload #{type}")
  attach_part(binary, store, table, writer_path)
  writer_name = assert_shape(binary, store, table, "pk\tUInt64\npayload\t#{type}")
  writer_part = active_part_path(binary, store, table)
  condition = " WHERE pk >= 3 AND pk <= 10"
  if label == "signed"
    full_payload = run_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
    assert_binary(full_payload, rowbinary_signed(W38_KEYS, W38_SIGNED), "Crystal Nullable(Int256) full")
    range_payload = run_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table}#{condition} ORDER BY pk FORMAT RowBinary")
    assert_binary(range_payload, rowbinary_signed(range_keys, range_signed), "Crystal Nullable(Int256) keyed range")
    part = CrystalClick::WidePart.open_typed(writer_part, "payload")
    raise "Crystal Nullable(Int256) attached raw read differs" unless part.read_nullable_int256_raw_mark_range("payload", 0, part.mark_count) == W38_SIGNED
    raise "Crystal Nullable(Int256) writer marks differ" unless part.mark_row_counts == expected_mark_rows
  else
    full_payload = run_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
    assert_binary(full_payload, rowbinary_unsigned(W38_KEYS, W38_UNSIGNED), "Crystal Nullable(UInt256) full")
    range_payload = run_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table}#{condition} ORDER BY pk FORMAT RowBinary")
    assert_binary(range_payload, rowbinary_unsigned(range_keys, range_unsigned), "Crystal Nullable(UInt256) keyed range")
    part = CrystalClick::WidePart.open_typed(writer_part, "payload")
    raise "Crystal Nullable(UInt256) attached raw read differs" unless part.read_nullable_uint256_raw_mark_range("payload", 0, part.mark_count) == W38_UNSIGNED
    raise "Crystal Nullable(UInt256) writer marks differ" unless part.mark_row_counts == expected_mark_rows
  end
  raise "writer part identity changed" unless active_part_name(binary, store, table) == writer_name
  puts "PASS Crystal #{type} writer: ATTACH/CHECK, independent full/keyed RowBinary, attached raw reader"
end

puts "PASS W38 nullable raw Int256/UInt256 oracle on ClickHouse #{run_clickhouse(binary, store, "SELECT version()") .strip}"
CRYSTAL

printf 'PASS W38 nullable raw Int256/UInt256 oracle on %s\n' "$ACTUAL_VERSION"
