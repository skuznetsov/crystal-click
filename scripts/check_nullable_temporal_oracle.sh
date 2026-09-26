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

TMP_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/crystal-click-nullable-temporal-oracle.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

cd "$ROOT"
export CLICKHOUSE_BIN TMP_ROOT
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache"
mkdir -p "$CRYSTAL_CACHE_DIR"

crystal run --link-flags='-fuse-ld=ld' --stdin-filename "$ROOT/scripts/check_nullable_temporal_oracle.cr" <<'CRYSTAL'
require "file_utils"
require "json"
require "../src/crystal_click"

TEMPORAL_KEYS = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64]
TEMPORAL_MARK_ROWS = [2_u64, 2_u64, 1_u64, 0_u64]

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

def create_table(binary : String, store : String, table : String, type_name : String) : Nil
  run_clickhouse(binary, store, <<-SQL)
  CREATE TABLE default.#{table}
  (
      `pk` UInt64,
      `payload` Nullable(#{type_name})
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

def append_le(io : IO, bits : UInt64, width : Int32) : Nil
  width.times do |byte_index|
    io.write_byte(((bits >> (byte_index * 8)) & 0xff_u64).to_u8)
  end
end

def raw_value_bits(value : T) : UInt64 forall T
  {% if T == UInt16 || T == UInt32 || T == UInt64 %}
    value.to_u64
  {% elsif T == Int32 %}
    value.unsafe_as(UInt32).to_u64
  {% elsif T == Int64 %}
    value.unsafe_as(UInt64)
  {% else %}
    {% raise "unsupported nullable temporal raw type" %}
  {% end %}
end

def nullable_temporal_rowbinary(keys : Array(UInt64), values : Array(T?), width : Int32) : String forall T
  raise "RowBinary fixture lengths differ" unless keys.size == values.size
  output = IO::Memory.new
  keys.each_with_index do |key, index|
    append_le(output, key, 8)
    value = values[index]
    if value.nil?
      output.write_byte(1_u8)
    else
      output.write_byte(0_u8)
      append_le(output, raw_value_bits(value.not_nil!), width)
    end
  end
  output.to_s
end

def nullable_nested_bytes(values : Array(T?), width : Int32) : Array(UInt8) forall T
  output = IO::Memory.new
  values.each do |value|
    append_le(output, value.nil? ? 0_u64 : raw_value_bits(value.not_nil!), width)
  end
  output.to_slice.to_a
end

def nullable_map_bytes(values : Array(T?)) : Array(UInt8) forall T
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

def expected_stock_marks(width : Int32) : Array({UInt64, UInt64, UInt64})
  [{0_u64, 0_u64, 2_u64}, {0_u64, 2_u64 * width.to_u64, 2_u64}, {0_u64, 4_u64 * width.to_u64, 1_u64}, {0_u64, 5_u64 * width.to_u64, 0_u64}]
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
  raise "#{logical_name} should have one frame per nonempty mark" unless offsets.size == TEMPORAL_MARK_ROWS.size
  Array({UInt64, UInt64, UInt64}).new(TEMPORAL_MARK_ROWS.size) do |index|
    {offsets[index], 0_u64, TEMPORAL_MARK_ROWS[index]}
  end
end

def assert_equal_bytes(actual : String, expected : String, context : String) : Nil
  return if actual.to_slice == expected.to_slice
  raise "#{context} differs (expected #{expected.bytesize} bytes, got #{actual.bytesize})"
end

def assert_serialization(part : String, stock : Bool, row_count : Int32) : Nil
  path = File.join(part, "serialization.json")
  raise "part is missing serialization.json" unless File.exists?(path)
  metadata = JSON.parse(File.read(path)).as_h
  raise "serialization metadata version differs" unless metadata["version"]?.try(&.as_i) == 1
  raise "nested serialization propagation flag differs" unless metadata["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool) == true
  raise "serialization type versions differ" unless metadata["types_serialization_versions"]?.try(&.as_h) == {"string" => JSON::Any.new(1_i64)}
  columns = metadata["columns"]?.try(&.as_a) || raise "serialization columns are missing"
  if stock
    expected_column = JSON.parse(%({"kind":"Default","name":"pk","num_defaults":0,"num_rows":#{row_count}}))
    raise "stock serialization default-column metadata differs: #{columns.map(&.to_json).inspect}" unless columns == [expected_column]
  else
    raise "Crystal serialization unexpectedly lists default columns" unless columns.empty?
  end
end

def assert_part_shape(part : String, type_name : String, values : Array(T?), width : Int32, stock : Bool) : Nil forall T
  expected_columns = "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` Nullable(#{type_name})\n"
  raise "#{type_name} columns metadata differs" unless File.read(File.join(part, "columns.txt")) == expected_columns
  expected_substreams = "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n2 substreams for column `payload`:\n\tpayload.null\n\tpayload\n"
  raise "#{type_name} substream metadata differs" unless File.read(File.join(part, "columns_substreams.txt")) == expected_substreams
  raise "#{type_name} part is not CODEC(LZ4)" unless File.read(File.join(part, "default_compression_codec.txt")) == "CODEC(LZ4)"
  assert_serialization(part, stock, values.size)

  bin_files = Dir.glob(File.join(part, "*.bin"))
  raise "#{type_name} part must have key, null, and nested streams" unless bin_files.size == 3
  mark_files = Dir.glob(File.join(part, "*.mrk2"))
  raise "#{type_name} part must have three plain adaptive .mrk2 streams" unless mark_files.size == 3
  raise "#{type_name} part unexpectedly uses compressed marks" unless Dir.glob(File.join(part, "*.cmrk2")).empty?
  raise "#{type_name} part unexpectedly has legacy marks" unless Dir.glob(File.join(part, "*.mrk")).empty?

  expected_nulls = nullable_map_bytes(values)
  expected_nested = nullable_nested_bytes(values, width)
  raise "#{type_name} null-map bytes differ" unless decoded_stream(part, "payload.null") == expected_nulls
  raise "#{type_name} nested bytes/placeholders differ" unless decoded_stream(part, "payload") == expected_nested

  widths = {"pk" => 8, "payload.null" => 1, "payload" => width}
  widths.each do |logical_name, stream_width|
    observed = mark_entries(part, logical_name)
    expected = stock ? expected_stock_marks(stream_width) : expected_writer_marks(part, logical_name)
    raise "#{type_name} #{logical_name} mark layout differs: #{observed.inspect}" unless observed == expected
  end
end

def read_nullable_temporal(
  part : CrystalClick::WidePart,
  column : String,
  first_mark : Int,
  mark_count : Int,
  type_name : String,
  values : Array(T?),
) : Array(T?) forall T
  {% if T == UInt16 %}
    part.read_nullable_date_codes_mark_range(column, first_mark, mark_count)
  {% elsif T == Int32 %}
    part.read_nullable_date32_codes_mark_range(column, first_mark, mark_count)
  {% elsif T == UInt32 %}
    part.read_nullable_datetime_seconds_mark_range(column, first_mark, mark_count)
  {% elsif T == Int64 %}
    part.read_nullable_datetime64_ticks_mark_range(column, first_mark, mark_count)
  {% else %}
    {% raise "unsupported nullable temporal reader type" %}
  {% end %}
end

def assert_reader_ranges(part : CrystalClick::WidePart, type_name : String, values : Array(T?)) : Nil forall T
  full = read_nullable_temporal(part, "payload", 0, part.mark_count, type_name, values)
  raise "#{type_name} full typed read differs: #{full.inspect}" unless full == values
  values.each_slice(2).with_index do |expected, mark_index|
    observed = read_nullable_temporal(part, "payload", mark_index, 1, type_name, values)
    raise "#{type_name} mark #{mark_index} read differs" unless observed == expected
  end
end

def active_part_name(binary : String, store : String, table : String) : String
  part_name = run_clickhouse(binary, store, "SELECT name FROM system.parts WHERE database = 'default' AND table = '#{table}' AND active FORMAT TSVRaw").strip
  raise "#{table}: expected exactly one active part, got #{part_name.inspect}" if part_name.empty? || part_name.includes?('\n')
  part_name
end

def attached_part_path(binary : String, store : String, table : String) : String
  path = run_clickhouse(binary, store, "SELECT path FROM system.parts WHERE database = 'default' AND table = '#{table}' AND active FORMAT TSVRaw").strip
  raise "#{table}: active part path is missing" if path.empty?
  path
end

def assert_check_table(binary : String, store : String, table : String, part_name : String) : Nil
  result = run_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "#{table}: CHECK TABLE failed: #{result.inspect}" unless result == "#{part_name}\t1"
end

def stock_part(binary : String, store : String, root : String, type_name : String, values : Array(T?)) : String forall T
  label = type_name.downcase.gsub(/[()]/, "_")
  table = "nullable_temporal_stock_#{label}"
  create_table(binary, store, table, type_name)
  input = IO::Memory.new
  input << nullable_temporal_rowbinary(TEMPORAL_KEYS, values, type_name == "Date" ? 2 : (type_name == "Date32" || type_name == "DateTime" ? 4 : 8))
  input.rewind
  run_clickhouse_input(binary, store, "INSERT INTO default.#{table} FORMAT RowBinary", input)
  name = active_part_name(binary, store, table)
  shape = run_clickhouse(binary, store, "SELECT rows, marks, part_type FROM system.parts WHERE database = 'default' AND table = '#{table}' AND active FORMAT TabSeparated").strip
  raise "#{table}: unexpected stock part shape #{shape.inspect}" unless shape == "5\t4\tWide"
  source_path = attached_part_path(binary, store, table)
  part = File.join(root, "stock-#{label}-part")
  FileUtils.cp_r(source_path, part)

  expected = nullable_temporal_rowbinary(TEMPORAL_KEYS, values, type_name == "Date" ? 2 : (type_name == "Date32" || type_name == "DateTime" ? 4 : 8))
  full = run_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  assert_equal_bytes(full, expected, "stock #{type_name} full RowBinary")
  ranged = run_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} WHERE pk >= 2 AND pk < 9 ORDER BY pk FORMAT RowBinary")
  assert_equal_bytes(ranged, nullable_temporal_rowbinary(TEMPORAL_KEYS[1, 3], values[1, 3], type_name == "Date" ? 2 : (type_name == "Date32" || type_name == "DateTime" ? 4 : 8)), "stock #{type_name} key-range RowBinary")
  assert_check_table(binary, store, table, name)
  part
end

def verify_stock_reader(binary : String, store : String, part_path : String, type_name : String, values : Array(T?), width : Int32) : Nil forall T
  assert_part_shape(part_path, type_name, values, width, true)
  reader = CrystalClick::WidePart.open_typed(part_path, "payload")
  expected_type = "Nullable(#{type_name})"
  raise "stock #{type_name} reader type differs: #{reader.column_type}" unless reader.column_type == expected_type
  raise "stock #{type_name} row count differs" unless reader.row_count == TEMPORAL_KEYS.size.to_u64
  raise "stock #{type_name} mark rows differ: #{reader.mark_row_counts.inspect}" unless reader.mark_row_counts == [2_u64, 2_u64, 1_u64]
  assert_reader_ranges(reader, type_name, values)
  puts "PASS stock #{expected_type}: metadata, null/nested streams, .mrk2 rows, Crystal full/per-mark reads, RowBinary ranges, CHECK TABLE"
end

def write_nullable_temporal_part(part : String, type_name : String, keys : Array(UInt64), values : Array(T?), precision : Int32) : Nil forall T
  key_slice = keys.to_unsafe.to_slice(keys.size)
  value_slice = values.to_unsafe.to_slice(values.size)
  {% if T == UInt16 %}
    CrystalClick::WidePartWriter.write_uint64_nullable_date_pair(part, "pk", key_slice, "payload", value_slice, 2)
  {% elsif T == Int32 %}
    CrystalClick::WidePartWriter.write_uint64_nullable_date32_pair(part, "pk", key_slice, "payload", value_slice, 2)
  {% elsif T == UInt32 %}
    CrystalClick::WidePartWriter.write_uint64_nullable_datetime_pair(part, "pk", key_slice, "payload", value_slice, 2)
  {% elsif T == Int64 %}
    CrystalClick::WidePartWriter.write_uint64_nullable_datetime64_pair(part, "pk", key_slice, "payload", value_slice, precision, 2)
  {% else %}
    {% raise "unsupported nullable temporal writer type" %}
  {% end %}
  nil
end

def assert_attached_corruption(binary : String, store : String, table : String, part_path : String, part_name : String, logical_name : String) : Nil
  path = stream_path(part_path, logical_name)
  original = File.open(path, "r") { |file| file.read_byte || raise "#{table}: #{logical_name} stream is empty" }
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

def verify_writer_to_stock(binary : String, store : String, root : String, part : String, type_name : String, values : Array(T?), width : Int32, precision : Int32) : Nil forall T
  assert_part_shape(part, type_name, values, width, false)
  table = "nullable_temporal_writer_#{type_name.downcase.gsub(/[()]/, "_")}"
  create_table(binary, store, table, type_name)
  data_path = run_clickhouse(binary, store, "SELECT data_paths[1] FROM system.tables WHERE database = 'default' AND name = '#{table}' FORMAT TSVRaw").strip
  raise "#{table}: ClickHouse returned no data path" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  run_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")

  part_name = active_part_name(binary, store, table)
  raise "#{table}: attached part has an unexpected row/mark shape" unless run_clickhouse(binary, store, "SELECT rows, marks, part_type FROM system.parts WHERE database = 'default' AND table = '#{table}' AND active FORMAT TabSeparated").strip == "5\t4\tWide"
  attached_path = attached_part_path(binary, store, table)
  expected = nullable_temporal_rowbinary(TEMPORAL_KEYS, values, width)
  full = run_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  assert_equal_bytes(full, expected, "Crystal #{type_name} attached full RowBinary")
  ranged = run_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} WHERE pk >= 2 AND pk < 9 ORDER BY pk FORMAT RowBinary")
  assert_equal_bytes(ranged, nullable_temporal_rowbinary(TEMPORAL_KEYS[1, 3], values[1, 3], width), "Crystal #{type_name} attached key-range RowBinary")
  assert_check_table(binary, store, table, part_name)
  assert_attached_corruption(binary, store, table, attached_path, part_name, "payload.null")
  assert_attached_corruption(binary, store, table, attached_path, part_name, "payload")
  puts "PASS Crystal #{type_name} writer: ATTACH, exact RowBinary/range, CHECK TABLE, independent null/nested corruption"
end

def verify_type(binary : String, store : String, root : String, label : String, type_name : String, values : Array(T?), width : Int32, precision : Int32 = 0) : Nil forall T
  source = stock_part(binary, store, root, type_name, values)
  table = "nullable_temporal_stock_#{type_name.downcase.gsub(/[()]/, "_")}"
  verify_stock_reader(binary, store, source, type_name, values, width)

  writer_part = File.join(root, "writer-#{label}-part")
  write_nullable_temporal_part(writer_part, type_name, TEMPORAL_KEYS, values, precision)
  verify_writer_to_stock(binary, store, root, writer_part, type_name, values, width, precision)
end

binary = ENV.fetch("CLICKHOUSE_BIN")
root = ENV.fetch("TMP_ROOT")
store = File.join(root, "clickhouse-store")

verify_type(binary, store, root, "date", "Date", [nil, 0_u16.as(UInt16?), UInt16::MAX.as(UInt16?), nil, 1_u16.as(UInt16?)], 2)
verify_type(binary, store, root, "date32", "Date32", [nil, Int32::MIN.as(Int32?), 0_i32.as(Int32?), Int32::MAX.as(Int32?), nil], 4)
verify_type(binary, store, root, "datetime", "DateTime", [nil, 0_u32.as(UInt32?), UInt32::MAX.as(UInt32?), nil, 1_u32.as(UInt32?)], 4)
{0, 3, 9}.each do |precision|
  verify_type(binary, store, root, "datetime64-#{precision}", "DateTime64(#{precision})", [nil, Int64::MIN.as(Int64?), 0_i64.as(Int64?), Int64::MAX.as(Int64?), nil], 8, precision)
end

puts "PASS Nullable temporal differential oracle on ClickHouse #{binary}"
CRYSTAL

printf 'PASS Nullable Date/Date32/DateTime/DateTime64 differential oracle on ClickHouse %s\n' "$ACTUAL_VERSION"
