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

TMP_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/crystal-click-datetime-oracle.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

cd "$ROOT"
export CLICKHOUSE_BIN TMP_ROOT
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache"
mkdir -p "$CRYSTAL_CACHE_DIR"

crystal run --link-flags='-fuse-ld=ld' --stdin-filename "$ROOT/scripts/check_datetime_oracle.cr" <<'CRYSTAL'
require "file_utils"
require "json"
require "../src/crystal_click"

DATETIME_KEYS = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64]
DATETIME_SECONDS = [0_u32, 1_u32, 1_700_000_000_u32, 2_000_000_000_u32, UInt32::MAX]
DATETIME64_TICKS = [Int64::MIN, -1_i64, 0_i64, 1_i64, Int64::MAX]
EXPECTED_MARK_ROWS = [2_u64, 2_u64, 1_u64]
EXPECTED_PHYSICAL_MARK_ROWS = [2_u64, 2_u64, 1_u64, 0_u64]

def run_clickhouse(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  status = Process.run(
    binary,
    ["local", "--path", store, "--query", query],
    output: output,
    error: Process::Redirect::Inherit
  )
  raise "ClickHouse local query failed (status #{status.exit_code}): #{query}" unless status.success?
  output.to_s
end

def run_clickhouse_input(binary : String, store : String, query : String, input : IO) : String
  output = IO::Memory.new
  status = Process.run(
    binary,
    ["local", "--path", store, "--query", query],
    input: input,
    output: output,
    error: Process::Redirect::Inherit
  )
  raise "ClickHouse RowBinary insert failed (status #{status.exit_code}): #{query}" unless status.success?
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
      compress_marks = 0,
      min_compress_block_size = 0,
      max_compress_block_size = 4096;
  SQL
  nil
end

def append_le(io : IO, value : UInt64, width : Int) : Nil
  width.times do |byte_index|
    io.write_byte(((value >> (byte_index * 8)) & 0xff_u64).to_u8)
  end
end

def datetime_rowbinary(keys : Array(UInt64), values : Array(UInt32)) : String
  raise "DateTime fixture lengths differ" unless keys.size == values.size
  output = IO::Memory.new
  keys.each_with_index do |key, index|
    append_le(output, key, 8)
    append_le(output, values[index].to_u64, 4)
  end
  output.to_s
end

def datetime64_rowbinary(keys : Array(UInt64), values : Array(Int64)) : String
  raise "DateTime64 fixture lengths differ" unless keys.size == values.size
  output = IO::Memory.new
  keys.each_with_index do |key, index|
    append_le(output, key, 8)
    append_le(output, values[index].unsafe_as(UInt64), 8)
  end
  output.to_s
end

def datetime_payload_bytes(values : Array(UInt32)) : Array(UInt8)
  bytes = [] of UInt8
  values.each do |value|
    4.times { |index| bytes << ((value >> (index * 8)) & 0xff_u32).to_u8 }
  end
  bytes
end

def datetime64_payload_bytes(values : Array(Int64)) : Array(UInt8)
  bytes = [] of UInt8
  values.each do |value|
    bits = value.unsafe_as(UInt64)
    8.times { |index| bytes << ((bits >> (index * 8)) & 0xff_u64).to_u8 }
  end
  bytes
end

def stream_path(part : String, logical_name : String, extension : String = "bin") : String
  File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.#{extension}")
end

def read_le_u64(bytes : Bytes, offset : Int32) : UInt64
  value = 0_u64
  8.times do |byte_index|
    value |= bytes[offset + byte_index].to_u64 << (byte_index * 8)
  end
  value
end

def mark_entries(part : String, logical_name : String) : Array({UInt64, UInt64, UInt64})
  bytes = File.read(stream_path(part, logical_name, "mrk2")).to_slice
  mark_size = CrystalClick::WidePart::MARK_SIZE
  raise "#{logical_name} mark stream has a truncated .mrk2 record" unless bytes.size % mark_size == 0
  Array({UInt64, UInt64, UInt64}).new(bytes.size // mark_size) do |mark_index|
    offset = mark_index * mark_size
    {read_le_u64(bytes, offset), read_le_u64(bytes, offset + 8), read_le_u64(bytes, offset + 16)}
  end
end

def frame_boundary_offsets(part : String, logical_name : String) : Array(UInt64)
  data = File.read(stream_path(part, logical_name)).to_slice
  offsets = [0_u64]
  offset = 0_i64
  while offset < data.size.to_i64
    frame = CrystalClick::CompressedBlock.decode_frame(data, offset)
    raise "#{logical_name} compressed frame did not advance" if frame.end_offset <= offset
    offset = frame.end_offset
    offsets << offset.to_u64
  end
  raise "#{logical_name} compressed stream has trailing bytes" unless offset == data.size.to_i64
  offsets
end

def expected_writer_marks(part : String, logical_name : String) : Array({UInt64, UInt64, UInt64})
  offsets = frame_boundary_offsets(part, logical_name)
  raise "#{logical_name} stream should have one frame per data mark" unless offsets.size == EXPECTED_PHYSICAL_MARK_ROWS.size
  Array({UInt64, UInt64, UInt64}).new(EXPECTED_PHYSICAL_MARK_ROWS.size) do |index|
    {offsets[index], 0_u64, EXPECTED_PHYSICAL_MARK_ROWS[index]}
  end
end

def assert_part_shape(
  part : String,
  type_name : String,
  expected_payload : Array(UInt8),
  payload_width : Int32,
  stock_metadata : Bool = false,
  writer_marks : Bool = false,
) : Nil
  expected_columns = "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` #{type_name}\n"
  raise "#{type_name} columns metadata differs" unless File.read(File.join(part, "columns.txt")) == expected_columns
  expected_substreams = "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n1 substreams for column `payload`:\n\tpayload\n"
  raise "#{type_name} substream metadata differs" unless File.read(File.join(part, "columns_substreams.txt")) == expected_substreams
  raise "#{type_name} part is not CODEC(LZ4)" unless File.read(File.join(part, "default_compression_codec.txt")) == "CODEC(LZ4)"
  raise "#{type_name} payload width differs" unless expected_payload.size == DATETIME_KEYS.size * payload_width

  serialization_path = File.join(part, "serialization.json")
  if stock_metadata
    raise "stock #{type_name} part is missing serialization metadata" unless File.exists?(serialization_path)
    metadata = JSON.parse(File.read(serialization_path)).as_h
    raise "stock #{type_name} serialization version differs" unless metadata["version"]?.try(&.as_i) == 1
    columns = metadata["columns"]?.try(&.as_a) || raise "stock #{type_name} serialization columns are missing"
    names = columns.map { |column| column.as_h["name"].as_s }.sort
    raise "stock #{type_name} serialization column names differ: #{names.inspect}" unless names == ["payload", "pk"]
    columns.each do |column|
      details = column.as_h
      unless details["kind"].as_s == "Default" && details["num_rows"].as_i == DATETIME_KEYS.size
        raise "stock #{type_name} serialization column record differs: #{details.inspect}"
      end
    end
  else
    raise "Crystal #{type_name} part unexpectedly has serialization metadata" if File.exists?(serialization_path)
  end

  bin_files = Dir.glob(File.join(part, "*.bin"))
  raise "#{type_name} part must have exactly the key and payload stream; saw #{bin_files.map { |path| File.basename(path) }.inspect}" unless bin_files.size == 2
  mark_files = Dir.glob(File.join(part, "*.mrk2"))
  raise "#{type_name} part must have exactly two plain adaptive .mrk2 streams; saw #{mark_files.map { |path| File.basename(path) }.inspect}" unless mark_files.size == 2
  raise "#{type_name} part unexpectedly uses compressed marks" unless Dir.glob(File.join(part, "*.cmrk2")).empty?
  {"payload.null", "payload.size"}.each do |logical_name|
    raise "#{type_name} part has an unexpected #{logical_name} stream" if File.exists?(stream_path(part, logical_name)) || File.exists?(stream_path(part, logical_name, "mrk2"))
  end

  expected_key_marks = [{0_u64, 0_u64, 2_u64}, {0_u64, 16_u64, 2_u64}, {0_u64, 32_u64, 1_u64}, {0_u64, 40_u64, 0_u64}]
  payload_offsets = [0, 2, 4, 5]
  expected_payload_marks = Array({UInt64, UInt64, UInt64}).new(4) do |index|
    {0_u64, payload_offsets[index].to_u64 * payload_width.to_u64, EXPECTED_PHYSICAL_MARK_ROWS[index]}
  end
  {"pk", "payload"}.each do |logical_name|
    observed = mark_entries(part, logical_name)
    expected = if writer_marks
                 expected_writer_marks(part, logical_name)
               else
                 logical_name == "pk" ? expected_key_marks : expected_payload_marks
               end
    raise "#{type_name} #{logical_name} adaptive marks differ: #{observed.inspect}" unless observed == expected
  end

  raw_payload = CrystalClick::CompressedBlock.decode_all(File.read(stream_path(part, "payload")).to_slice).to_a
  raise "#{type_name} physical payload bytes differ" unless raw_payload == expected_payload
end

def stock_datetime_part(binary : String, store : String, root : String) : String
  table = "datetime_stock_source"
  create_table(binary, store, table, "DateTime")
  input = IO::Memory.new
  input << datetime_rowbinary(DATETIME_KEYS, DATETIME_SECONDS)
  input.rewind
  run_clickhouse_input(binary, store, "INSERT INTO default.#{table} FORMAT RowBinary", input)
  source_path = run_clickhouse(binary, store, "SELECT path FROM system.parts WHERE database = 'default' AND table = '#{table}' AND active FORMAT TSVRaw").strip
  raise "stock DateTime part path is missing" if source_path.empty?
  part = File.join(root, "stock-datetime-part")
  FileUtils.cp_r(source_path, part)
  part
end

def stock_datetime64_part(binary : String, store : String, root : String, precision : Int32) : String
  table = "datetime64_stock_source_#{precision}"
  create_table(binary, store, table, "DateTime64(#{precision})")
  input = IO::Memory.new
  input << datetime64_rowbinary(DATETIME_KEYS, DATETIME64_TICKS)
  input.rewind
  run_clickhouse_input(binary, store, "INSERT INTO default.#{table} FORMAT RowBinary", input)
  source_path = run_clickhouse(binary, store, "SELECT path FROM system.parts WHERE database = 'default' AND table = '#{table}' AND active FORMAT TSVRaw").strip
  raise "stock DateTime64(#{precision}) part path is missing" if source_path.empty?
  part = File.join(root, "stock-datetime64-#{precision}-part")
  FileUtils.cp_r(source_path, part)
  part
end

def verify_stock_datetime_reader(part : String) : Nil
  assert_part_shape(part, "DateTime", datetime_payload_bytes(DATETIME_SECONDS), 4, stock_metadata: true)
  reader = CrystalClick::WidePart.open_typed(part, "payload")
  raise "stock DateTime reader metadata differs: #{reader.column_type}" unless reader.column_type == "DateTime"
  raise "stock DateTime row count differs: #{reader.row_count}" unless reader.row_count == DATETIME_KEYS.size.to_u64
  raise "stock DateTime data marks differ: #{reader.mark_row_counts.inspect}" unless reader.mark_row_counts == EXPECTED_MARK_ROWS
  values = reader.read_datetime_seconds_mark_range("payload", 0, reader.mark_count)
  raise "stock DateTime raw seconds differ: #{values.inspect}" unless values == DATETIME_SECONDS
  raise "stock DateTime middle mark differs" unless reader.read_datetime_seconds_mark_range("payload", 1, 1) == DATETIME_SECONDS[2, 2]
  raise "stock DateTime short tail mark differs" unless reader.read_datetime_seconds_mark_range("payload", 2, 1) == [UInt32::MAX]

  full = run_clickhouse(ENV.fetch("CLICKHOUSE_BIN"), ENV.fetch("TMP_ROOT") + "/clickhouse-store", "SELECT pk, payload FROM default.datetime_stock_source ORDER BY pk FORMAT RowBinary")
  assert_raw_equal(full, datetime_rowbinary(DATETIME_KEYS, DATETIME_SECONDS), "stock DateTime full RowBinary")
  ranged = run_clickhouse(ENV.fetch("CLICKHOUSE_BIN"), ENV.fetch("TMP_ROOT") + "/clickhouse-store", "SELECT pk, payload FROM default.datetime_stock_source WHERE pk >= 2 AND pk < 9 ORDER BY pk FORMAT RowBinary")
  assert_raw_equal(ranged, datetime_rowbinary(DATETIME_KEYS[1, 3], DATETIME_SECONDS[1, 3]), "stock DateTime key range RowBinary")
  assert_stock_table_check(ENV.fetch("CLICKHOUSE_BIN"), ENV.fetch("TMP_ROOT") + "/clickhouse-store", "datetime_stock_source")
  puts "PASS stock DateTime reader: UInt32 raw seconds, one stream, exact marks, full/key-range RowBinary, and clean CHECK TABLE"
end

def verify_stock_datetime64_reader(part : String, precision : Int32) : Nil
  type_name = "DateTime64(#{precision})"
  assert_part_shape(part, type_name, datetime64_payload_bytes(DATETIME64_TICKS), 8, stock_metadata: true)
  reader = CrystalClick::WidePart.open_typed(part, "payload")
  raise "stock #{type_name} reader metadata differs: #{reader.column_type}" unless reader.column_type == type_name
  raise "stock #{type_name} row count differs: #{reader.row_count}" unless reader.row_count == DATETIME_KEYS.size.to_u64
  raise "stock #{type_name} data marks differ: #{reader.mark_row_counts.inspect}" unless reader.mark_row_counts == EXPECTED_MARK_ROWS
  values = reader.read_datetime64_ticks_mark_range("payload", 0, reader.mark_count)
  raise "stock #{type_name} raw ticks differ: #{values.inspect}" unless values == DATETIME64_TICKS
  raise "stock #{type_name} middle mark differs" unless reader.read_datetime64_ticks_mark_range("payload", 1, 1) == DATETIME64_TICKS[2, 2]
  raise "stock #{type_name} short tail mark differs" unless reader.read_datetime64_ticks_mark_range("payload", 2, 1) == [Int64::MAX]

  table = "datetime64_stock_source_#{precision}"
  full = run_clickhouse(ENV.fetch("CLICKHOUSE_BIN"), ENV.fetch("TMP_ROOT") + "/clickhouse-store", "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  assert_raw_equal(full, datetime64_rowbinary(DATETIME_KEYS, DATETIME64_TICKS), "stock #{type_name} full RowBinary")
  ranged = run_clickhouse(ENV.fetch("CLICKHOUSE_BIN"), ENV.fetch("TMP_ROOT") + "/clickhouse-store", "SELECT pk, payload FROM default.#{table} WHERE pk >= 2 AND pk < 9 ORDER BY pk FORMAT RowBinary")
  assert_raw_equal(ranged, datetime64_rowbinary(DATETIME_KEYS[1, 3], DATETIME64_TICKS[1, 3]), "stock #{type_name} key range RowBinary")
  assert_stock_table_check(ENV.fetch("CLICKHOUSE_BIN"), ENV.fetch("TMP_ROOT") + "/clickhouse-store", table)
  puts "PASS stock #{type_name} reader: signed Int64 raw ticks, one stream, exact marks, full/key-range RowBinary, and clean CHECK TABLE"
end

def assert_raw_equal(actual : String, expected : String, context : String) : Nil
  return if actual.to_slice == expected.to_slice
  raise "#{context} differs (expected #{expected.bytesize} bytes, got #{actual.bytesize})"
end

def attached_part_path(binary : String, store : String, table : String) : String
  path = run_clickhouse(binary, store, "SELECT path FROM system.parts WHERE database = 'default' AND table = '#{table}' AND active FORMAT TSVRaw").strip
  raise "#{table}: attached part path is missing" if path.empty?
  path
end

def assert_check_table(binary : String, store : String, table : String, expected_part_name : String) : Nil
  result = run_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "#{table}: CHECK TABLE failed: #{result.inspect}" unless result == "#{expected_part_name}\t1"
end

def assert_stock_table_check(binary : String, store : String, table : String) : Nil
  part_name = run_clickhouse(binary, store, "SELECT name FROM system.parts WHERE database = 'default' AND table = '#{table}' AND active FORMAT TSVRaw").strip
  raise "#{table}: stock table does not have exactly one active part: #{part_name.inspect}" if part_name.empty? || part_name.includes?('\n')
  assert_check_table(binary, store, table, part_name)
end

def assert_payload_corruption(binary : String, store : String, table : String, part : String, part_name : String) : Nil
  path = stream_path(part, "payload")
  original = File.open(path, "r") { |file| file.read_byte || raise "#{table}: DateTime payload stream is empty" }
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
    raise "#{table}: CHECK TABLE missed same-size payload corruption: #{damaged.inspect}"
  end
  assert_check_table(binary, store, table, part_name)
end

def verify_writer_to_stock(
  binary : String,
  store : String,
  part : String,
  type_name : String,
  payload_bytes : Array(UInt8),
  full_rowbinary : String,
  range_rowbinary : String,
  table : String,
  payload_width : Int32,
) : Nil
  assert_part_shape(part, type_name, payload_bytes, payload_width, writer_marks: true)
  create_table(binary, store, table, type_name)
  data_path = run_clickhouse(binary, store, "SELECT data_paths[1] FROM system.tables WHERE database = 'default' AND name = '#{table}' FORMAT TSVRaw").strip
  raise "#{table}: ClickHouse returned no data path" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  run_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")

  active_part_name = run_clickhouse(binary, store, "SELECT name FROM system.parts WHERE database = 'default' AND table = '#{table}' AND active FORMAT TSVRaw").strip
  raise "#{table}: ClickHouse did not expose one attached active part: #{active_part_name.inspect}" if active_part_name.empty? || active_part_name.includes?('\n')
  attached_path = attached_part_path(binary, store, table)
  full = run_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  assert_raw_equal(full, full_rowbinary, "Crystal #{type_name} attached full RowBinary")
  ranged = run_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} WHERE pk >= 2 AND pk < 9 ORDER BY pk FORMAT RowBinary")
  assert_raw_equal(ranged, range_rowbinary, "Crystal #{type_name} attached key-range RowBinary")

  assert_check_table(binary, store, table, active_part_name)
  assert_payload_corruption(binary, store, table, attached_path, active_part_name)
  puts "PASS Crystal #{type_name} writer: ATTACH PART, exact full/key-range RowBinary, clean CHECK TABLE, and same-size corruption rejection"
end

binary = ENV.fetch("CLICKHOUSE_BIN")
root = ENV.fetch("TMP_ROOT")
store = File.join(root, "clickhouse-store")

stock_datetime = stock_datetime_part(binary, store, root)
verify_stock_datetime_reader(stock_datetime)
{0, 3, 9}.each do |precision|
  stock_datetime64 = stock_datetime64_part(binary, store, root, precision)
  verify_stock_datetime64_reader(stock_datetime64, precision)
end

datetime_writer_part = File.join(root, "writer-datetime-part")
CrystalClick::WidePartWriter.write_uint64_datetime_pair(
  datetime_writer_part,
  "pk",
  DATETIME_KEYS.to_unsafe.to_slice(DATETIME_KEYS.size),
  "payload",
  DATETIME_SECONDS.to_unsafe.to_slice(DATETIME_SECONDS.size),
  rows_per_mark: 2
)
verify_writer_to_stock(
  binary,
  store,
  datetime_writer_part,
  "DateTime",
  datetime_payload_bytes(DATETIME_SECONDS),
  datetime_rowbinary(DATETIME_KEYS, DATETIME_SECONDS),
  datetime_rowbinary(DATETIME_KEYS[1, 3], DATETIME_SECONDS[1, 3]),
  "datetime_writer_target",
  4
)

{0, 3, 9}.each do |precision|
  datetime64_writer_part = File.join(root, "writer-datetime64-#{precision}-part")
  CrystalClick::WidePartWriter.write_uint64_datetime64_pair(
    datetime64_writer_part,
    "pk",
    DATETIME_KEYS.to_unsafe.to_slice(DATETIME_KEYS.size),
    "payload",
    DATETIME64_TICKS.to_unsafe.to_slice(DATETIME64_TICKS.size),
    precision,
    2
  )
  verify_writer_to_stock(
    binary,
    store,
    datetime64_writer_part,
    "DateTime64(#{precision})",
    datetime64_payload_bytes(DATETIME64_TICKS),
    datetime64_rowbinary(DATETIME_KEYS, DATETIME64_TICKS),
    datetime64_rowbinary(DATETIME_KEYS[1, 3], DATETIME64_TICKS[1, 3]),
    "datetime64_writer_target_#{precision}",
    8
  )
end
CRYSTAL

printf 'PASS DateTime/DateTime64 differential oracle on ClickHouse %s\n' "$ACTUAL_VERSION"
