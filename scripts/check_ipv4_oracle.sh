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

TMP_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/crystal-click-ipv4-oracle.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

cd "$ROOT"
export CLICKHOUSE_BIN TMP_ROOT
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache"
mkdir -p "$CRYSTAL_CACHE_DIR"

crystal run --link-flags='-fuse-ld=ld' --stdin-filename "$ROOT/scripts/check_ipv4_oracle.cr" <<'CRYSTAL'
require "file_utils"
require "json"
require "../src/crystal_click"

W18_KEYS = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64]
W18_MARK_ROWS = [2_u64, 2_u64, 1_u64, 0_u64]
W18_IPV4S = [
  CrystalClick::IPv4Value.from_octets(1_u8, 2_u8, 3_u8, 4_u8),
  CrystalClick::IPv4Value.from_octets(4_u8, 3_u8, 2_u8, 1_u8),
  CrystalClick::IPv4Value.from_octets(0_u8, 0_u8, 0_u8, 0_u8),
  CrystalClick::IPv4Value.from_octets(255_u8, 255_u8, 255_u8, 255_u8),
  CrystalClick::IPv4Value.from_octets(203_u8, 0_u8, 113_u8, 17_u8),
]
W18_IPV4_TEXTS = [
  "1.2.3.4",
  "4.3.2.1",
  "0.0.0.0",
  "255.255.255.255",
  "203.0.113.17",
]
W18_NETWORK_ORDER = [0x01020304_u32, 0x04030201_u32, 0_u32, UInt32::MAX, 0xcb007111_u32]
W18_NULLABLE_IPV4S = [
  nil.as(CrystalClick::IPv4Value?),
  W18_IPV4S[0].as(CrystalClick::IPv4Value?),
  W18_IPV4S[1].as(CrystalClick::IPv4Value?),
  W18_IPV4S[2].as(CrystalClick::IPv4Value?),
  W18_IPV4S[3].as(CrystalClick::IPv4Value?),
]
W18_NULLABLE_IPV4_TEXTS = [
  nil.as(String?),
  W18_IPV4_TEXTS[0].as(String?),
  W18_IPV4_TEXTS[1].as(String?),
  W18_IPV4_TEXTS[2].as(String?),
  W18_IPV4_TEXTS[3].as(String?),
]

def run_clickhouse(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  status = Process.run(
    binary,
    ["local", "--path", store, "--query", query],
    output: output,
    error: Process::Redirect::Inherit
  )
  raise "ClickHouse query failed (status #{status.exit_code}): #{query}" unless status.success?
  output.to_s
end

def create_table(binary : String, store : String, table : String, payload_type : String) : Nil
  run_clickhouse(binary, store, <<-SQL)
  CREATE TABLE default.#{table}
  (
      `pk` UInt64,
      `payload` #{payload_type}
  )
  ENGINE = MergeTree
  ORDER BY pk
  SETTINGS
      index_granularity = 2,
      enable_mixed_granularity_parts = 1,
      min_rows_for_wide_part = 0,
      min_bytes_for_wide_part = 0,
      ratio_of_defaults_for_sparse_serialization = 1.0,
      compress_marks = 0,
      min_compress_block_size = 0,
      max_compress_block_size = 4096;
  SQL
  nil
end

def insert_stock_values(binary : String, store : String, table : String, values : Array(String?)) : Nil
  raise "W18 IPv4 fixture lengths differ" unless values.size == W18_KEYS.size
  rows = values.each_with_index.map do |value, index|
    literal = value ? "toIPv4('#{value}')" : "NULL"
    "(#{W18_KEYS[index]}, #{literal})"
  end
  run_clickhouse(binary, store, "INSERT INTO default.#{table} VALUES #{rows.join(", ")}")
  nil
end

def append_u64_le(io : IO, value : UInt64) : Nil
  8.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
end

def append_ipv4(io : IO, value : CrystalClick::IPv4Value) : Nil
  # ClickHouse stores IPv4's network-order uint32 in little-endian bytes.
  address = value.network_order
  4.times { |index| io.write_byte(((address >> (index * 8)) & 0xff_u32).to_u8) }
end

def rowbinary_bare(keys : Array(UInt64), values : Array(CrystalClick::IPv4Value)) : String
  raise "W18 IPv4 fixture lengths differ" unless keys.size == values.size
  output = IO::Memory.new
  keys.each_with_index do |key, index|
    append_u64_le(output, key)
    append_ipv4(output, values[index])
  end
  output.to_s
end

def rowbinary_nullable(keys : Array(UInt64), values : Array(CrystalClick::IPv4Value?)) : String
  raise "W18 Nullable(IPv4) fixture lengths differ" unless keys.size == values.size
  output = IO::Memory.new
  keys.each_with_index do |key, index|
    append_u64_le(output, key)
    if value = values[index]
      output.write_byte(0_u8)
      append_ipv4(output, value)
    else
      # RowBinary NULL has a flag only; the physical nested slot is checked separately.
      output.write_byte(1_u8)
    end
  end
  output.to_s
end

def uint64_bytes(values : Array(UInt64)) : Array(UInt8)
  output = IO::Memory.new
  values.each { |value| append_u64_le(output, value) }
  output.to_slice.to_a
end

def payload_bytes(values : Array(CrystalClick::IPv4Value)) : Array(UInt8)
  output = IO::Memory.new
  values.each { |value| append_ipv4(output, value) }
  output.to_slice.to_a
end

def nullable_payload_bytes(values : Array(CrystalClick::IPv4Value?)) : Array(UInt8)
  output = IO::Memory.new
  zero = CrystalClick::IPv4Value.from_octets(0_u8, 0_u8, 0_u8, 0_u8)
  values.each { |value| append_ipv4(output, value || zero) }
  output.to_slice.to_a
end

def null_map_bytes(values : Array(CrystalClick::IPv4Value?)) : Array(UInt8)
  values.map { |value| value.nil? ? 1_u8 : 0_u8 }
end

def stream_path(part : String, logical_name : String, extension : String = "bin") : String
  File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.#{extension}")
end

def decoded_stream(part : String, logical_name : String) : Array(UInt8)
  CrystalClick::CompressedBlock.decode_all(File.read(stream_path(part, logical_name)).to_slice).to_a
end

def read_le_u64(bytes : Bytes, offset : Int32) : UInt64
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

def mark_entries(part : String, logical_name : String) : Array({UInt64, UInt64, UInt64})
  bytes = File.read(stream_path(part, logical_name, "mrk2")).to_slice
  mark_size = CrystalClick::WidePart::MARK_SIZE
  raise "#{logical_name} has truncated .mrk2 records" unless bytes.size % mark_size == 0
  Array({UInt64, UInt64, UInt64}).new(bytes.size // mark_size) do |index|
    offset = index * mark_size
    {read_le_u64(bytes, offset), read_le_u64(bytes, offset + 8), read_le_u64(bytes, offset + 16)}
  end
end

def stock_mark_entries(width : Int32) : Array({UInt64, UInt64, UInt64})
  offsets = [0_u64, 2_u64 * width.to_u64, 4_u64 * width.to_u64, 5_u64 * width.to_u64]
  Array({UInt64, UInt64, UInt64}).new(W18_MARK_ROWS.size) do |index|
    {0_u64, offsets[index], W18_MARK_ROWS[index]}
  end
end

def writer_mark_entries(part : String, logical_name : String) : Array({UInt64, UInt64, UInt64})
  data = File.read(stream_path(part, logical_name)).to_slice
  offsets = [0_u64]
  offset = 0_i64
  while offset < data.size.to_i64
    frame = CrystalClick::CompressedBlock.decode_frame(data, offset)
    raise "#{logical_name} compressed frame did not advance" if frame.end_offset <= offset
    offset = frame.end_offset
    offsets << offset.to_u64
  end
  raise "#{logical_name} stream has trailing compressed bytes" unless offset == data.size.to_i64
  raise "#{logical_name} should have one LZ4 frame per mark" unless offsets.size == W18_MARK_ROWS.size
  Array({UInt64, UInt64, UInt64}).new(W18_MARK_ROWS.size) do |index|
    {offsets[index], 0_u64, W18_MARK_ROWS[index]}
  end
end

def serialization_metadata : JSON::Any
  JSON.parse(%({"columns":[],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1}))
end

def assert_part_shape(
  part : String,
  canonical_type : String,
  nullable : Bool,
  keys : Array(UInt64),
  nested : Array(UInt8),
  nulls : Array(UInt8)?,
  stock : Bool,
) : Nil
  expected_columns = "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` #{canonical_type}\n"
  raise "#{canonical_type} columns metadata differs" unless File.read(File.join(part, "columns.txt")) == expected_columns

  expected_substreams = if nullable
                         "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n2 substreams for column `payload`:\n\tpayload.null\n\tpayload\n"
                       else
                         "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n1 substreams for column `payload`:\n\tpayload\n"
                       end
  raise "#{canonical_type} substream metadata differs" unless File.read(File.join(part, "columns_substreams.txt")) == expected_substreams
  raise "#{canonical_type} default codec differs" unless File.read(File.join(part, "default_compression_codec.txt")) == "CODEC(LZ4)"

  serialization_path = File.join(part, "serialization.json")
  raise "#{canonical_type} serialization metadata is missing" unless File.file?(serialization_path)
  raise "#{canonical_type} serialization metadata differs" unless JSON.parse(File.read(serialization_path)) == serialization_metadata

  logical_streams = nullable ? ["pk", "payload.null", "payload"] : ["pk", "payload"]
  logical_streams.each do |logical_name|
    raise "#{canonical_type} missing #{logical_name}.bin" unless File.file?(stream_path(part, logical_name))
    raise "#{canonical_type} missing #{logical_name}.mrk2" unless File.file?(stream_path(part, logical_name, "mrk2"))
  end
  raise "#{canonical_type} has unexpected extra .mrk2 streams" unless Dir.glob(File.join(part, "*.mrk2")).size == logical_streams.size
  raise "#{canonical_type} unexpectedly uses compressed marks" unless Dir.glob(File.join(part, "*.cmrk2")).empty?
  raise "#{canonical_type} has unexpected extra .bin streams" unless Dir.glob(File.join(part, "*.bin")).size == logical_streams.size

  raise "#{canonical_type} primary-key bytes differ" unless decoded_stream(part, "pk") == uint64_bytes(keys)
  raise "#{canonical_type} payload bytes differ" unless decoded_stream(part, "payload") == nested
  if nullable
    expected_nulls = nulls || raise "#{canonical_type} null-map expectation is missing"
    raise "#{canonical_type} null-map bytes differ" unless decoded_stream(part, "payload.null") == expected_nulls
  end

  widths = {"pk" => 8, "payload" => 4}
  widths["payload.null"] = 1 if nullable
  widths.each do |logical_name, width|
    expected = stock ? stock_mark_entries(width) : writer_mark_entries(part, logical_name)
    observed = mark_entries(part, logical_name)
    raise "#{canonical_type} #{logical_name} marks differ: #{observed.inspect}" unless observed == expected
  end
end

def assert_equal_bytes(actual : String, expected : String, context : String) : Nil
  return if actual.to_slice == expected.to_slice
  raise "#{context} differs (expected #{expected.bytesize} bytes, got #{actual.bytesize})"
end

def active_part_name(binary : String, store : String, table : String) : String
  value = run_clickhouse(binary, store, "SELECT name FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw").strip
  raise "#{table}: missing/ambiguous active part name #{value.inspect}" if value.empty? || value.includes?('\n')
  value
end

def active_part_path(binary : String, store : String, table : String) : String
  value = run_clickhouse(binary, store, "SELECT path FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw").strip
  raise "#{table}: active part path missing" if value.empty?
  value
end

def assert_metadata_and_rows(binary : String, store : String, table : String, canonical_type : String, part_name : String) : Nil
  type = run_clickhouse(binary, store, "SELECT type FROM system.columns WHERE database='default' AND table='#{table}' AND name='payload' FORMAT TSVRaw").strip
  raise "#{table}: normalized payload type #{type.inspect}, expected #{canonical_type}" unless type == canonical_type
  shape = run_clickhouse(binary, store, "SELECT rows, marks, part_type FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TabSeparated").strip
  raise "#{table}: expected five-row Wide part with four adaptive marks, got #{shape.inspect}" unless shape == "5\t4\tWide"
  raise "#{table}: active part name changed" unless active_part_name(binary, store, table) == part_name
end

def assert_check_table(binary : String, store : String, table : String, part_name : String) : Nil
  result = run_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "#{table}: CHECK TABLE failed: #{result.inspect}" unless result == "#{part_name}\t1"
end

def assert_bare_reader(part_path : String, values : Array(CrystalClick::IPv4Value)) : Nil
  part = CrystalClick::WidePart.open_typed(part_path, "payload")
  raise "IPv4 reader type differs: #{part.column_type.inspect}" unless part.column_type == "IPv4"
  raise "IPv4 reader row count differs" unless part.row_count == W18_KEYS.size.to_u64
  raise "IPv4 reader data marks differ" unless part.mark_row_counts == [2_u64, 2_u64, 1_u64]
  actual = part.read_ipv4s_mark_range("payload", 0, part.mark_count)
  raise "IPv4 full typed read differs" unless actual == values
  values.each_slice(2).with_index do |expected, mark|
    raise "IPv4 mark #{mark} typed read differs" unless part.read_ipv4s_mark_range("payload", mark, 1) == expected
  end

  table = CrystalClick::WidePartTable.open_selected_typed([part_path], ["payload"])
  observed = [] of CrystalClick::IPv4Value
  batches = [] of Int32
  table.scan_typed(batch_rows: 3) do |batch|
    batch_values = batch.ipv4s_for("payload")
    observed.concat(batch_values)
    batches << batch_values.size.to_i32
    begin
      batch.values_for("payload", UInt32)
      raise "IPv4 batch was exposed through the UInt32 numeric alias"
    rescue CrystalClick::UnsupportedFormatError
    end
  end
  raise "IPv4 batch accessor values differ" unless observed == values
  raise "IPv4 batch boundaries differ: #{batches.inspect}" unless batches == [2_i32, 2_i32, 1_i32]
end

def assert_nullable_reader(part_path : String, values : Array(CrystalClick::IPv4Value?)) : Nil
  part = CrystalClick::WidePart.open_typed(part_path, "payload")
  raise "Nullable(IPv4) reader type differs: #{part.column_type.inspect}" unless part.column_type == "Nullable(IPv4)"
  raise "Nullable(IPv4) reader row count differs" unless part.row_count == W18_KEYS.size.to_u64
  raise "Nullable(IPv4) reader data marks differ" unless part.mark_row_counts == [2_u64, 2_u64, 1_u64]
  actual = part.read_nullable_ipv4s_mark_range("payload", 0, part.mark_count)
  raise "Nullable(IPv4) full typed read differs" unless actual == values
  values.each_slice(2).with_index do |expected, mark|
    unless part.read_nullable_ipv4s_mark_range("payload", mark, 1) == expected
      raise "Nullable(IPv4) mark #{mark} typed read differs"
    end
  end

  table = CrystalClick::WidePartTable.open_selected_typed([part_path], ["payload"])
  observed = [] of CrystalClick::IPv4Value?
  batches = [] of Int32
  table.scan_typed(batch_rows: 3) do |batch|
    batch_values = batch.nullable_ipv4s_for("payload")
    observed.concat(batch_values)
    batches << batch_values.size.to_i32
    begin
      batch.nullable_values_for("payload", UInt32)
      raise "Nullable(IPv4) batch was exposed through the Nullable(UInt32) numeric alias"
    rescue CrystalClick::UnsupportedFormatError
    end
  end
  raise "Nullable(IPv4) batch accessor values differ" unless observed == values
  raise "Nullable(IPv4) batch boundaries differ: #{batches.inspect}" unless batches == [2_i32, 2_i32, 1_i32]
end

def attach_part(binary : String, store : String, writer_part : String, table : String, payload_type : String) : {String, String}
  create_table(binary, store, table, payload_type)
  data_path = run_clickhouse(binary, store, "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw").strip
  raise "#{table}: ClickHouse table data path missing" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(writer_part, File.join(detached, "all_1_1_0"))
  run_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  name = active_part_name(binary, store, table)
  path = active_part_path(binary, store, table)
  assert_metadata_and_rows(binary, store, table, payload_type, name)
  {name, path}
end

def assert_corruption(binary : String, store : String, table : String, part : String, part_name : String, logical_name : String) : Nil
  path = stream_path(part, logical_name)
  original = File.open(path, "r") { |file| file.read_byte || raise "#{table}: empty #{logical_name} stream" }
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
    raise "#{table}: CHECK TABLE missed same-size #{logical_name} corruption: #{damaged.inspect}"
  end
  assert_check_table(binary, store, table, part_name)
end

def assert_ordinary_display(binary : String, store : String, table : String, values : Array(String?)) : Nil
  expected = values.map { |value| value || "\\N" }.join("\n")
  observed = run_clickhouse(binary, store, "SELECT payload FROM default.#{table} ORDER BY pk FORMAT TSVRaw").strip
  raise "#{table}: ordinary IPv4 display differs: #{observed.inspect}" unless observed == expected
end

def exercise_shape(
  binary : String,
  store : String,
  root : String,
  label : String,
  nullable : Bool,
) : Nil
  type_name = nullable ? "Nullable(IPv4)" : "IPv4"
  values = nullable ? W18_NULLABLE_IPV4S : W18_IPV4S.map(&.as(CrystalClick::IPv4Value?))
  texts = nullable ? W18_NULLABLE_IPV4_TEXTS : W18_IPV4_TEXTS.map(&.as(String?))
  nested = nullable ? nullable_payload_bytes(values) : payload_bytes(values.map(&.not_nil!))
  nulls = nullable ? null_map_bytes(values) : nil
  stock_table = "w18_stock_#{label}"

  W18_IPV4S.each_with_index do |value, index|
    raise "IPv4 from_octets/display mismatch at #{index}" unless value.to_s == W18_IPV4_TEXTS[index]
    raise "IPv4 network-order mismatch at #{index}: #{value.network_order.to_s(16)}" unless value.network_order == W18_NETWORK_ORDER[index]
  end

  create_table(binary, store, stock_table, type_name)
  insert_stock_values(binary, store, stock_table, texts)
  stock_name = active_part_name(binary, store, stock_table)
  assert_metadata_and_rows(binary, store, stock_table, type_name, stock_name)
  stock_path = File.join(root, "stock-#{label}", "all_1_1_0")
  FileUtils.mkdir_p(File.dirname(stock_path))
  FileUtils.cp_r(active_part_path(binary, store, stock_table), stock_path)
  assert_part_shape(stock_path, type_name, nullable, W18_KEYS, nested, nulls, true)
  if nullable
    assert_nullable_reader(stock_path, values)
  else
    assert_bare_reader(stock_path, values.map(&.not_nil!))
  end
  assert_ordinary_display(binary, store, stock_table, texts)

  full_rowbinary = nullable ? rowbinary_nullable(W18_KEYS, values) : rowbinary_bare(W18_KEYS, values.map(&.not_nil!))
  assert_equal_bytes(
    run_clickhouse(binary, store, "SELECT pk, payload FROM default.#{stock_table} ORDER BY pk FORMAT RowBinary"),
    full_rowbinary,
    "stock #{type_name} full RowBinary"
  )
  range_rowbinary = nullable ? rowbinary_nullable(W18_KEYS[1, 3], values[1, 3]) : rowbinary_bare(W18_KEYS[1, 3], values[1, 3].map(&.not_nil!))
  assert_equal_bytes(
    run_clickhouse(binary, store, "SELECT pk, payload FROM default.#{stock_table} WHERE pk >= 2 AND pk < 9 ORDER BY pk FORMAT RowBinary"),
    range_rowbinary,
    "stock #{type_name} key-range RowBinary"
  )
  assert_check_table(binary, store, stock_table, stock_name)

  writer_part = File.join(root, "writer-#{label}-part")
  keys = W18_KEYS.to_unsafe.to_slice(W18_KEYS.size)
  if nullable
    CrystalClick::WidePartWriter.write_uint64_nullable_ipv4_pair(
      writer_part, "pk", keys, "payload", values.to_unsafe.to_slice(values.size), 2
    )
  else
    bare_values = values.map(&.not_nil!)
    CrystalClick::WidePartWriter.write_uint64_ipv4_pair(
      writer_part, "pk", keys, "payload", bare_values.to_unsafe.to_slice(bare_values.size), 2
    )
  end
  assert_part_shape(writer_part, type_name, nullable, W18_KEYS, nested, nulls, false)
  target_table = "w18_writer_#{label}"
  writer_name, writer_path = attach_part(binary, store, writer_part, target_table, type_name)
  if nullable
    assert_nullable_reader(writer_path, values)
  else
    assert_bare_reader(writer_path, values.map(&.not_nil!))
  end
  assert_equal_bytes(
    run_clickhouse(binary, store, "SELECT pk, payload FROM default.#{target_table} ORDER BY pk FORMAT RowBinary"),
    full_rowbinary,
    "Crystal #{type_name} attached full RowBinary"
  )
  assert_equal_bytes(
    run_clickhouse(binary, store, "SELECT pk, payload FROM default.#{target_table} WHERE pk >= 2 AND pk < 9 ORDER BY pk FORMAT RowBinary"),
    range_rowbinary,
    "Crystal #{type_name} attached key-range RowBinary"
  )
  assert_check_table(binary, store, target_table, writer_name)

  # Corruption is applied only to a fresh attached copy inside this oracle's
  # disposable local store, then restored and rechecked before cleanup.
  corrupt_table = "w18_corrupt_#{label}"
  corrupt_name, corrupt_path = attach_part(binary, store, writer_part, corrupt_table, type_name)
  assert_check_table(binary, store, corrupt_table, corrupt_name)
  assert_corruption(binary, store, corrupt_table, corrupt_path, corrupt_name, "payload")
  assert_corruption(binary, store, corrupt_table, corrupt_path, corrupt_name, "payload.null") if nullable

  puts "PASS #{type_name}: stock and Crystal directions, exact streams/marks, full+key-range RowBinary, CHECK TABLE, and isolated corruption rejection"
end

binary = ENV.fetch("CLICKHOUSE_BIN")
root = ENV.fetch("TMP_ROOT")
store = File.join(root, "clickhouse-store")

exercise_shape(binary, store, root, "ipv4", false)
exercise_shape(binary, store, root, "nullable_ipv4", true)
puts "PASS IPv4 differential oracle on ClickHouse #{run_clickhouse(binary, store, "SELECT version()").strip}"
CRYSTAL

printf 'PASS IPv4 differential oracle on ClickHouse %s\n' "$ACTUAL_VERSION"
