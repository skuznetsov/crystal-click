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

TMP_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/crystal-click-date-oracle.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

cd "$ROOT"
export CLICKHOUSE_BIN TMP_ROOT
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache"
mkdir -p "$CRYSTAL_CACHE_DIR"

crystal run --link-flags='-fuse-ld=ld' --stdin-filename "$ROOT/scripts/check_date_oracle.cr" <<'CRYSTAL'
require "file_utils"
require "json"
require "../src/crystal_click"

DATE_KEYS = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64]
DATE_CODES = [0_u16, 1_u16, 32_767_u16, 32_768_u16, UInt16::MAX]
DATE32_CODES = [Int32::MIN, -1_i32, 0_i32, 1_i32, Int32::MAX]
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

def date_rowbinary(keys : Array(UInt64), values : Array(UInt16)) : IO::Memory
  raise "Date fixture lengths differ" unless keys.size == values.size
  input = IO::Memory.new
  keys.each_with_index do |key, index|
    append_le(input, key, 8)
    append_le(input, values[index].to_u64, 2)
  end
  input.rewind
  input
end

def date32_rowbinary(keys : Array(UInt64), values : Array(Int32)) : IO::Memory
  raise "Date32 fixture lengths differ" unless keys.size == values.size
  input = IO::Memory.new
  keys.each_with_index do |key, index|
    append_le(input, key, 8)
    append_le(input, values[index].unsafe_as(UInt32).to_u64, 4)
  end
  input.rewind
  input
end

def stock_date_part(binary : String, store : String, root : String) : String
  table = "date_stock_source"
  create_table(binary, store, table, "Date")
  run_clickhouse_input(binary, store, "INSERT INTO default.#{table} FORMAT RowBinary", date_rowbinary(DATE_KEYS, DATE_CODES))
  source_path = run_clickhouse(binary, store, "SELECT path FROM system.parts WHERE database = 'default' AND table = '#{table}' AND active FORMAT TSVRaw").strip
  raise "stock Date part path is missing" if source_path.empty?
  part = File.join(root, "stock-date-part")
  FileUtils.cp_r(source_path, part)
  part
end

def stock_date32_part(binary : String, store : String, root : String) : String
  table = "date32_stock_source"
  create_table(binary, store, table, "Date32")
  run_clickhouse_input(binary, store, "INSERT INTO default.#{table} FORMAT RowBinary", date32_rowbinary(DATE_KEYS, DATE32_CODES))
  source_path = run_clickhouse(binary, store, "SELECT path FROM system.parts WHERE database = 'default' AND table = '#{table}' AND active FORMAT TSVRaw").strip
  raise "stock Date32 part path is missing" if source_path.empty?
  part = File.join(root, "stock-date32-part")
  FileUtils.cp_r(source_path, part)
  part
end

def stream_path(part : String, logical_name : String, extension : String = "bin") : String
  File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.#{extension}")
end

def expected_raw_bytes(values : Array(UInt16)) : Array(UInt8)
  bytes = [] of UInt8
  values.each do |value|
    2.times { |byte_index| bytes << ((value >> (byte_index * 8)) & 0xff_u16).to_u8 }
  end
  bytes
end

def expected_raw_bytes(values : Array(Int32)) : Array(UInt8)
  bytes = [] of UInt8
  values.each do |value|
    bits = value.unsafe_as(UInt32)
    4.times { |byte_index| bytes << ((bits >> (byte_index * 8)) & 0xff_u32).to_u8 }
  end
  bytes
end

def physical_mark_row_counts(part : String, logical_name : String) : Array(UInt64)
  bytes = File.read(stream_path(part, logical_name, "mrk2")).to_slice
  mark_size = CrystalClick::WidePart::MARK_SIZE
  raise "#{logical_name} mark stream has a truncated .mrk2 record" unless bytes.size % mark_size == 0
  Array(UInt64).new(bytes.size // mark_size) do |mark_index|
    offset = mark_index * mark_size + 16
    value = 0_u64
    8.times { |byte_index| value |= bytes[offset + byte_index].to_u64 << (byte_index * 8) }
    value
  end
end

def assert_part_shape(part : String, type_name : String, expected_codes : Array(T), stock_metadata : Bool = false) : Nil forall T
  expected_columns = "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` #{type_name}\n"
  raise "#{type_name} columns metadata differs" unless File.read(File.join(part, "columns.txt")) == expected_columns
  expected_substreams = "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n1 substreams for column `payload`:\n\tpayload\n"
  raise "#{type_name} substream metadata differs" unless File.read(File.join(part, "columns_substreams.txt")) == expected_substreams
  raise "#{type_name} part is not CODEC(LZ4)" unless File.read(File.join(part, "default_compression_codec.txt")) == "CODEC(LZ4)"
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
      unless details["kind"].as_s == "Default" && details["num_rows"].as_i == expected_codes.size
        raise "stock #{type_name} serialization column record differs: #{details.inspect}"
      end
    end
  else
    raise "Crystal #{type_name} part unexpectedly has serialization metadata" if File.exists?(serialization_path)
  end

  bin_files = Dir.glob(File.join(part, "*.bin"))
  raise "#{type_name} part must have exactly the key and one payload stream; saw #{bin_files.map { |path| File.basename(path) }.inspect}" unless bin_files.size == 2
  mark_files = Dir.glob(File.join(part, "*.mrk2"))
  raise "#{type_name} part must have exactly two plain adaptive .mrk2 streams; saw #{mark_files.map { |path| File.basename(path) }.inspect}" unless mark_files.size == 2
  raise "#{type_name} part unexpectedly uses compressed marks" unless Dir.glob(File.join(part, "*.cmrk2")).empty?
  {"payload.null", "payload.size"}.each do |logical_name|
    raise "#{type_name} part has an unexpected #{logical_name} stream" if File.exists?(stream_path(part, logical_name)) || File.exists?(stream_path(part, logical_name, "mrk2"))
  end

  expected_marks = EXPECTED_PHYSICAL_MARK_ROWS
  {"pk", "payload"}.each do |logical_name|
    observed = physical_mark_row_counts(part, logical_name)
    raise "#{type_name} #{logical_name} adaptive mark rows differ: #{observed.inspect}" unless observed == expected_marks
  end

  raw_payload = CrystalClick::CompressedBlock.decode_all(File.read(stream_path(part, "payload")).to_slice).to_a
  raise "#{type_name} physical payload bytes differ" unless raw_payload == expected_raw_bytes(expected_codes)
end

def verify_stock_date_reader(part : String) : Nil
  assert_part_shape(part, "Date", DATE_CODES, stock_metadata: true)
  reader = CrystalClick::WidePart.open_typed(part, "payload")
  raise "stock Date reader metadata differs: #{reader.column_type}" unless reader.column_type == "Date"
  raise "stock Date row count differs: #{reader.row_count}" unless reader.row_count == DATE_KEYS.size.to_u64
  raise "stock Date data marks differ: #{reader.mark_row_counts.inspect}" unless reader.mark_row_counts == EXPECTED_MARK_ROWS
  values = reader.read_date_codes_mark_range("payload", 0, reader.mark_count)
  raise "stock Date raw day codes differ: #{values.inspect}" unless values == DATE_CODES
  middle = reader.read_date_codes_mark_range("payload", 1, 1)
  raise "stock Date middle mark differs: #{middle.inspect}" unless middle == DATE_CODES[2, 2]
  tail = reader.read_date_codes_mark_range("payload", 2, 1)
  raise "stock Date short final granule differs: #{tail.inspect}" unless tail == [UInt16::MAX]
  puts "PASS stock Date reader: one payload stream, adaptive marks [2, 2, 1], and exact raw codes including 65535"
end

def verify_stock_date32_reader(part : String) : Nil
  assert_part_shape(part, "Date32", DATE32_CODES, stock_metadata: true)
  reader = CrystalClick::WidePart.open_typed(part, "payload")
  raise "stock Date32 reader metadata differs: #{reader.column_type}" unless reader.column_type == "Date32"
  raise "stock Date32 row count differs: #{reader.row_count}" unless reader.row_count == DATE_KEYS.size.to_u64
  raise "stock Date32 data marks differ: #{reader.mark_row_counts.inspect}" unless reader.mark_row_counts == EXPECTED_MARK_ROWS
  values = reader.read_date32_codes_mark_range("payload", 0, reader.mark_count)
  raise "stock Date32 raw day codes differ: #{values.inspect}" unless values == DATE32_CODES
  middle = reader.read_date32_codes_mark_range("payload", 1, 1)
  raise "stock Date32 middle mark differs: #{middle.inspect}" unless middle == DATE32_CODES[2, 2]
  tail = reader.read_date32_codes_mark_range("payload", 2, 1)
  raise "stock Date32 short final granule differs: #{tail.inspect}" unless tail == [Int32::MAX]
  puts "PASS stock Date32 reader: one payload stream, adaptive marks [2, 2, 1], and exact raw codes including Int32 extrema"
end

def expected_rows(keys : Array(UInt64), values : Array(T), range_only : Bool) : String forall T
  output = IO::Memory.new
  keys.each_with_index do |key, index|
    next if range_only && (key < 2_u64 || key >= 9_u64)
    output << key.to_s << '\t' << values[index].to_s << '\n'
  end
  output.to_s
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

def assert_payload_corruption(binary : String, store : String, table : String, part : String, part_name : String) : Nil
  path = stream_path(part, "payload")
  original = File.open(path, "r") { |file| file.read_byte || raise "#{table}: Date payload stream is empty" }
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

def verify_writer_to_stock(binary : String, store : String, part : String, type_name : String, codes : Array(T), table : String) : Nil forall T
  assert_part_shape(part, type_name, codes)
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

  value_expression = type_name == "Date" ? "toUInt16(payload)" : "toInt32(payload)"
  full = run_clickhouse(binary, store, "SELECT pk, #{value_expression} FROM default.#{table} ORDER BY pk FORMAT TabSeparatedRaw")
  expected_full = expected_rows(DATE_KEYS, codes, false)
  raise "#{table}: full raw-code rows differ; expected #{expected_full.inspect}, got #{full.inspect}" unless full == expected_full
  ranged = run_clickhouse(binary, store, "SELECT pk, #{value_expression} FROM default.#{table} WHERE pk >= 2 AND pk < 9 ORDER BY pk FORMAT TabSeparatedRaw")
  expected_range = expected_rows(DATE_KEYS, codes, true)
  raise "#{table}: key-range raw-code rows differ; expected #{expected_range.inspect}, got #{ranged.inspect}" unless ranged == expected_range

  assert_check_table(binary, store, table, active_part_name)
  assert_payload_corruption(binary, store, table, attached_path, active_part_name)
  puts "PASS Crystal #{type_name} writer: ATTACH PART, exact full/key-range raw codes, clean CHECK TABLE, and same-size payload corruption rejection"
end

binary = ENV.fetch("CLICKHOUSE_BIN")
root = ENV.fetch("TMP_ROOT")
store = File.join(root, "clickhouse-store")
date_writer_part = File.join(root, "writer-date-part")
CrystalClick::WidePartWriter.write_uint64_date_pair(
  date_writer_part,
  "pk",
  DATE_KEYS.to_unsafe.to_slice(DATE_KEYS.size),
  "payload",
  DATE_CODES.to_unsafe.to_slice(DATE_CODES.size),
  rows_per_mark: 2
)
date32_writer_part = File.join(root, "writer-date32-part")
CrystalClick::WidePartWriter.write_uint64_date32_pair(
  date32_writer_part,
  "pk",
  DATE_KEYS.to_unsafe.to_slice(DATE_KEYS.size),
  "payload",
  DATE32_CODES.to_unsafe.to_slice(DATE32_CODES.size),
  rows_per_mark: 2
)

verify_stock_date_reader(stock_date_part(binary, store, root))
verify_stock_date32_reader(stock_date32_part(binary, store, root))
verify_writer_to_stock(binary, store, date_writer_part, "Date", DATE_CODES, "date_writer_target")
verify_writer_to_stock(binary, store, date32_writer_part, "Date32", DATE32_CODES, "date32_writer_target")
CRYSTAL

printf 'PASS Date/Date32 differential oracle on ClickHouse %s\n' "$ACTUAL_VERSION"
