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

TMP_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/crystal-click-bool-enum-decimal-oracle.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

cd "$ROOT"
export CLICKHOUSE_BIN TMP_ROOT
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache"
mkdir -p "$CRYSTAL_CACHE_DIR"

crystal run --link-flags='-fuse-ld=ld' --stdin-filename "$ROOT/scripts/check_bool_enum_decimal_oracle.cr" <<'CRYSTAL'
require "file_utils"
require "json"
require "../src/crystal_click"

W15_KEYS = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64]
W15_MARK_ROWS = [2_u64, 2_u64, 1_u64, 0_u64]
W15_ENUM8 = "Enum8('neg' = -7, 'zero' = 0, 'pos' = 7)"
W15_ENUM16 = "Enum16('neg' = -300, 'zero' = 0, 'pos' = 300)"
W15_ENUM8_ESCAPED = "Enum8('quo\\'te' = -7, 'back\\\\slash' = 7)"

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
      `payload` #{type_name}
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

def append_le(io : IO, bits : UInt64, width : Int32) : Nil
  width.times do |byte_index|
    io.write_byte(((bits >> (byte_index * 8)) & 0xff_u64).to_u8)
  end
end

def raw_value_bits(value : T) : UInt64 forall T
  {% if T == Bool %}
    value ? 1_u64 : 0_u64
  {% elsif T == Int8 %}
    value.unsafe_as(UInt8).to_u64
  {% elsif T == Int16 %}
    value.unsafe_as(UInt16).to_u64
  {% elsif T == Int32 %}
    value.unsafe_as(UInt32).to_u64
  {% elsif T == Int64 %}
    value.unsafe_as(UInt64)
  {% else %}
    {% raise "unsupported Bool/Enum/Decimal raw type" %}
  {% end %}
end

def rowbinary_bare(keys : Array(UInt64), values : Array(T), width : Int32) : String forall T
  raise "RowBinary fixture lengths differ" unless keys.size == values.size
  output = IO::Memory.new
  keys.each_with_index do |key, index|
    append_le(output, key, 8)
    append_le(output, raw_value_bits(values[index]), width)
  end
  output.to_s
end

def rowbinary_nullable(keys : Array(UInt64), values : Array(T?), width : Int32) : String forall T
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

def nullable_map_bytes(values : Array(T?)) : Array(UInt8) forall T
  values.map { |value| value.nil? ? 1_u8 : 0_u8 }
end

def bare_payload_bytes(values : Array(T), width : Int32) : Array(UInt8) forall T
  output = IO::Memory.new
  values.each { |value| append_le(output, raw_value_bits(value), width) }
  output.to_slice.to_a
end

def nullable_payload_bytes(values : Array(T?), width : Int32) : Array(UInt8) forall T
  output = IO::Memory.new
  values.each do |value|
    append_le(output, value.nil? ? 0_u64 : raw_value_bits(value.not_nil!), width)
  end
  output.to_slice.to_a
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
  [
    {0_u64, 0_u64, 2_u64},
    {0_u64, 2_u64 * width.to_u64, 2_u64},
    {0_u64, 4_u64 * width.to_u64, 1_u64},
    {0_u64, 5_u64 * width.to_u64, 0_u64},
  ]
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
  raise "#{logical_name} should have one frame per nonempty mark" unless offsets.size == W15_MARK_ROWS.size
  Array({UInt64, UInt64, UInt64}).new(W15_MARK_ROWS.size) do |index|
    {offsets[index], 0_u64, W15_MARK_ROWS[index]}
  end
end

def assert_equal_bytes(actual : String, expected : String, context : String) : Nil
  return if actual.to_slice == expected.to_slice
  raise "#{context} differs (expected #{expected.bytesize} bytes, got #{actual.bytesize})"
end

def assert_serialization(part : String) : Nil
  path = File.join(part, "serialization.json")
  raise "part is missing serialization.json" unless File.exists?(path)
  metadata = JSON.parse(File.read(path))
  expected = JSON.parse(%({"columns":[],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1}))
  raise "serialization metadata differs: #{metadata}" unless metadata == expected
end

def assert_part_shape(part : String, type_name : String, width : Int32, nullable : Bool, nested : Array(UInt8), nulls : Array(UInt8)?) : Nil
  expected_columns = "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` #{type_name}\n"
  raise "#{type_name} columns metadata differs" unless File.read(File.join(part, "columns.txt")) == expected_columns
  expected_substreams = if nullable
                         "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n2 substreams for column `payload`:\n\tpayload.null\n\tpayload\n"
                       else
                         "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n1 substreams for column `payload`:\n\tpayload\n"
                       end
  raise "#{type_name} substream metadata differs" unless File.read(File.join(part, "columns_substreams.txt")) == expected_substreams
  raise "#{type_name} part is not CODEC(LZ4)" unless File.read(File.join(part, "default_compression_codec.txt")) == "CODEC(LZ4)"
  assert_serialization(part)

  expected_streams = nullable ? 3 : 2
  raise "#{type_name} part has unexpected .bin stream count" unless Dir.glob(File.join(part, "*.bin")).size == expected_streams
  raise "#{type_name} part has unexpected .mrk2 stream count" unless Dir.glob(File.join(part, "*.mrk2")).size == expected_streams
  raise "#{type_name} part unexpectedly uses compressed marks" unless Dir.glob(File.join(part, "*.cmrk2")).empty?
  raise "#{type_name} part unexpectedly has legacy marks" unless Dir.glob(File.join(part, "*.mrk")).empty?
  raise "#{type_name} payload bytes differ" unless decoded_stream(part, "payload") == nested
  if nullable
    raise "#{type_name} null-map bytes differ" unless decoded_stream(part, "payload.null") == nulls
  end

  widths = {"pk" => 8}
  if nullable
    widths["payload.null"] = 1
  end
  widths["payload"] = width
  widths.each do |logical_name, stream_width|
    observed = mark_entries(part, logical_name)
    expected = expected_stock_marks(stream_width)
    raise "#{type_name} #{logical_name} stock mark layout differs: #{observed.inspect}" unless observed == expected
  end
end

def assert_writer_part_shape(part : String, type_name : String, width : Int32, nullable : Bool, nested : Array(UInt8), nulls : Array(UInt8)?) : Nil
  assert_part_shape_without_stock_marks(part, type_name, width, nullable, nested, nulls)
  logical_names = nullable ? ["pk", "payload.null", "payload"] : ["pk", "payload"]
  logical_names.each do |logical_name|
    observed = mark_entries(part, logical_name)
    expected = expected_writer_marks(part, logical_name)
    raise "#{type_name} #{logical_name} writer mark layout differs: #{observed.inspect}" unless observed == expected
  end
end

def assert_part_shape_without_stock_marks(part : String, type_name : String, width : Int32, nullable : Bool, nested : Array(UInt8), nulls : Array(UInt8)?) : Nil
  expected_columns = "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` #{type_name}\n"
  raise "#{type_name} columns metadata differs" unless File.read(File.join(part, "columns.txt")) == expected_columns
  expected_substreams = if nullable
                         "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n2 substreams for column `payload`:\n\tpayload.null\n\tpayload\n"
                       else
                         "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n1 substreams for column `payload`:\n\tpayload\n"
                       end
  raise "#{type_name} substream metadata differs" unless File.read(File.join(part, "columns_substreams.txt")) == expected_substreams
  raise "#{type_name} part is not CODEC(LZ4)" unless File.read(File.join(part, "default_compression_codec.txt")) == "CODEC(LZ4)"
  assert_serialization(part)

  expected_streams = nullable ? 3 : 2
  raise "#{type_name} part has unexpected .bin stream count" unless Dir.glob(File.join(part, "*.bin")).size == expected_streams
  raise "#{type_name} part has unexpected .mrk2 stream count" unless Dir.glob(File.join(part, "*.mrk2")).size == expected_streams
  raise "#{type_name} part unexpectedly uses compressed marks" unless Dir.glob(File.join(part, "*.cmrk2")).empty?
  raise "#{type_name} part unexpectedly has legacy marks" unless Dir.glob(File.join(part, "*.mrk")).empty?
  raise "#{type_name} payload bytes differ" unless decoded_stream(part, "payload") == nested
  if nullable
    raise "#{type_name} null-map bytes differ" unless decoded_stream(part, "payload.null") == nulls
  end
end

def read_bare(part : CrystalClick::WidePart, values : Array(T)) : Nil forall T
  actual = {% if T == Bool %}
             part.read_bool_mark_range("payload", 0, part.mark_count)
           {% elsif T == Int8 %}
             part.read_enum8_codes_mark_range("payload", 0, part.mark_count)
           {% elsif T == Int16 %}
             part.read_enum16_codes_mark_range("payload", 0, part.mark_count)
           {% elsif T == Int32 %}
             part.read_decimal32_raw_mark_range("payload", 0, part.mark_count)
           {% elsif T == Int64 %}
             part.read_decimal64_raw_mark_range("payload", 0, part.mark_count)
           {% else %}
             {% raise "unsupported bare W15 reader type" %}
           {% end %}
  raise "full typed payload read differs: #{actual.inspect}" unless actual == values
  values.each_slice(2).with_index do |expected, mark_index|
    mark = {% if T == Bool %}
             part.read_bool_mark_range("payload", mark_index, 1)
           {% elsif T == Int8 %}
             part.read_enum8_codes_mark_range("payload", mark_index, 1)
           {% elsif T == Int16 %}
             part.read_enum16_codes_mark_range("payload", mark_index, 1)
           {% elsif T == Int32 %}
             part.read_decimal32_raw_mark_range("payload", mark_index, 1)
           {% elsif T == Int64 %}
             part.read_decimal64_raw_mark_range("payload", mark_index, 1)
           {% end %}
    raise "mark #{mark_index} typed payload read differs" unless mark == expected
  end
end

def read_nullable(part : CrystalClick::WidePart, values : Array(T?)) : Nil forall T
  actual = {% if T == Bool %}
             part.read_nullable_bool_mark_range("payload", 0, part.mark_count)
           {% elsif T == Int8 %}
             part.read_nullable_enum8_codes_mark_range("payload", 0, part.mark_count)
           {% elsif T == Int16 %}
             part.read_nullable_enum16_codes_mark_range("payload", 0, part.mark_count)
           {% elsif T == Int32 %}
             part.read_nullable_decimal32_raw_mark_range("payload", 0, part.mark_count)
           {% elsif T == Int64 %}
             part.read_nullable_decimal64_raw_mark_range("payload", 0, part.mark_count)
           {% else %}
             {% raise "unsupported Nullable W15 reader type" %}
           {% end %}
  raise "full nullable typed payload read differs: #{actual.inspect}" unless actual == values
  values.each_slice(2).with_index do |expected, mark_index|
    mark = {% if T == Bool %}
             part.read_nullable_bool_mark_range("payload", mark_index, 1)
           {% elsif T == Int8 %}
             part.read_nullable_enum8_codes_mark_range("payload", mark_index, 1)
           {% elsif T == Int16 %}
             part.read_nullable_enum16_codes_mark_range("payload", mark_index, 1)
           {% elsif T == Int32 %}
             part.read_nullable_decimal32_raw_mark_range("payload", mark_index, 1)
           {% elsif T == Int64 %}
             part.read_nullable_decimal64_raw_mark_range("payload", mark_index, 1)
           {% end %}
    raise "mark #{mark_index} nullable typed payload read differs" unless mark == expected
  end
end

def write_bare(part : String, values : Array(T), canonical_type : String, scale : Int32) : String forall T
  keys = W15_KEYS.to_unsafe.to_slice(W15_KEYS.size)
  payload = values.to_unsafe.to_slice(values.size)
  {% if T == Bool %}
    CrystalClick::WidePartWriter.write_uint64_bool_pair(part, "pk", keys, "payload", payload, 2)
  {% elsif T == Int8 %}
    CrystalClick::WidePartWriter.write_uint64_enum8_pair(part, "pk", keys, "payload", payload, canonical_type, 2)
  {% elsif T == Int16 %}
    CrystalClick::WidePartWriter.write_uint64_enum16_pair(part, "pk", keys, "payload", payload, canonical_type, 2)
  {% elsif T == Int32 %}
    CrystalClick::WidePartWriter.write_uint64_decimal32_pair(part, "pk", keys, "payload", payload, scale, 2)
  {% elsif T == Int64 %}
    CrystalClick::WidePartWriter.write_uint64_decimal64_pair(part, "pk", keys, "payload", payload, scale, 2)
  {% else %}
    {% raise "unsupported bare W15 writer type" %}
  {% end %}
end

def write_nullable(part : String, values : Array(T?), canonical_type : String, scale : Int32) : String forall T
  keys = W15_KEYS.to_unsafe.to_slice(W15_KEYS.size)
  payload = values.to_unsafe.to_slice(values.size)
  {% if T == Bool %}
    CrystalClick::WidePartWriter.write_uint64_nullable_bool_pair(part, "pk", keys, "payload", payload, 2)
  {% elsif T == Int8 %}
    CrystalClick::WidePartWriter.write_uint64_nullable_enum8_pair(part, "pk", keys, "payload", payload, canonical_type, 2)
  {% elsif T == Int16 %}
    CrystalClick::WidePartWriter.write_uint64_nullable_enum16_pair(part, "pk", keys, "payload", payload, canonical_type, 2)
  {% elsif T == Int32 %}
    CrystalClick::WidePartWriter.write_uint64_nullable_decimal32_pair(part, "pk", keys, "payload", payload, scale, 2)
  {% elsif T == Int64 %}
    CrystalClick::WidePartWriter.write_uint64_nullable_decimal64_pair(part, "pk", keys, "payload", payload, scale, 2)
  {% else %}
    {% raise "unsupported Nullable W15 writer type" %}
  {% end %}
end

def active_part_name(binary : String, store : String, table : String) : String
  name = run_clickhouse(binary, store, "SELECT name FROM system.parts WHERE database = 'default' AND table = '#{table}' AND active FORMAT TSVRaw").strip
  raise "#{table}: expected exactly one active part, got #{name.inspect}" if name.empty? || name.includes?('\n')
  name
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

def assert_part_row_shape(binary : String, store : String, table : String) : Nil
  shape = run_clickhouse(binary, store, "SELECT rows, marks, part_type FROM system.parts WHERE database = 'default' AND table = '#{table}' AND active FORMAT TabSeparated").strip
  raise "#{table}: unexpected part row/mark/type shape #{shape.inspect}" unless shape == "5\t4\tWide"
end

def exercise_case(
  binary : String,
  store : String,
  root : String,
  label : String,
  create_type : String,
  canonical_type : String,
  width : Int32,
  nullable : Bool,
  rowbinary : String,
  range_rowbinary : String,
  nested : Array(UInt8),
  nulls : Array(UInt8)?,
  reader : Proc(CrystalClick::WidePart, Nil),
  writer : Proc(String, String),
) : Nil
  logical_type = nullable ? "Nullable(#{canonical_type})" : canonical_type
  table_type = nullable ? "Nullable(#{create_type})" : create_type
  table_label = label.gsub('-', '_')
  source_table = "w15_stock_#{table_label}"
  create_table(binary, store, source_table, table_type)
  input = IO::Memory.new(rowbinary)
  run_clickhouse_input(binary, store, "INSERT INTO default.#{source_table} FORMAT RowBinary", input)
  source_name = active_part_name(binary, store, source_table)
  assert_part_row_shape(binary, store, source_table)
  source_path = attached_part_path(binary, store, source_table)
  stock_part = File.join(root, "stock-#{label}-part")
  FileUtils.cp_r(source_path, stock_part)

  assert_part_shape(stock_part, logical_type, width, nullable, nested, nulls)
  stock_reader = CrystalClick::WidePart.open_typed(stock_part, "payload")
  raise "stock #{logical_type} reader type differs: #{stock_reader.column_type}" unless stock_reader.column_type == logical_type
  raise "stock #{logical_type} row count differs" unless stock_reader.row_count == W15_KEYS.size.to_u64
  raise "stock #{logical_type} mark rows differ: #{stock_reader.mark_row_counts.inspect}" unless stock_reader.mark_row_counts == [2_u64, 2_u64, 1_u64]
  reader.call(stock_reader)
  full = run_clickhouse(binary, store, "SELECT pk, payload FROM default.#{source_table} ORDER BY pk FORMAT RowBinary")
  assert_equal_bytes(full, rowbinary, "stock #{logical_type} full RowBinary")
  ranged = run_clickhouse(binary, store, "SELECT pk, payload FROM default.#{source_table} WHERE pk >= 2 AND pk < 9 ORDER BY pk FORMAT RowBinary")
  assert_equal_bytes(ranged, range_rowbinary, "stock #{logical_type} key-range RowBinary")
  assert_check_table(binary, store, source_table, source_name)

  writer_part = File.join(root, "writer-#{label}-part")
  writer.call(writer_part)
  assert_writer_part_shape(writer_part, logical_type, width, nullable, nested, nulls)

  target_table = "w15_writer_#{table_label}"
  create_table(binary, store, target_table, table_type)
  data_path = run_clickhouse(binary, store, "SELECT data_paths[1] FROM system.tables WHERE database = 'default' AND name = '#{target_table}' FORMAT TSVRaw").strip
  raise "#{target_table}: ClickHouse returned no data path" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(writer_part, File.join(detached, "all_1_1_0"))
  run_clickhouse(binary, store, "ALTER TABLE default.#{target_table} ATTACH PART 'all_1_1_0'")
  writer_name = active_part_name(binary, store, target_table)
  assert_part_row_shape(binary, store, target_table)
  writer_reader = CrystalClick::WidePart.open_typed(attached_part_path(binary, store, target_table), "payload")
  raise "attached writer #{logical_type} reader type differs" unless writer_reader.column_type == logical_type
  reader.call(writer_reader)
  full = run_clickhouse(binary, store, "SELECT pk, payload FROM default.#{target_table} ORDER BY pk FORMAT RowBinary")
  assert_equal_bytes(full, rowbinary, "Crystal #{logical_type} attached full RowBinary")
  ranged = run_clickhouse(binary, store, "SELECT pk, payload FROM default.#{target_table} WHERE pk >= 2 AND pk < 9 ORDER BY pk FORMAT RowBinary")
  assert_equal_bytes(ranged, range_rowbinary, "Crystal #{logical_type} attached key-range RowBinary")
  assert_check_table(binary, store, target_table, writer_name)
  if {"bool", "nullable-enum8", "nullable-decimal32-s2", "decimal64-s4"}.includes?(label)
    attached_path = attached_part_path(binary, store, target_table)
    assert_attached_corruption(binary, store, target_table, attached_path, writer_name, "payload")
    if nullable
      assert_attached_corruption(binary, store, target_table, attached_path, writer_name, "payload.null")
    end
  end
  puts "PASS #{logical_type}: stock read + Crystal writer ATTACH, exact RowBinary/range, physical streams/marks, CHECK TABLE"
end

def verify_bare(
  binary : String, store : String, root : String, label : String,
  type_name : String, width : Int32, values : Array(T), scale : Int32 = 0,
  canonical_type : String? = nil,
) : Nil forall T
  logical_type = canonical_type || type_name
  rowbinary = rowbinary_bare(W15_KEYS, values, width)
  range_rowbinary = rowbinary_bare(W15_KEYS[1, 3], values[1, 3], width)
  reader = ->(part : CrystalClick::WidePart) { read_bare(part, values) }
  writer = ->(path : String) { write_bare(path, values, type_name, scale) }
  exercise_case(binary, store, root, label, type_name, logical_type, width, false, rowbinary, range_rowbinary, bare_payload_bytes(values, width), nil, reader, writer)
end

def verify_nullable(
  binary : String, store : String, root : String, label : String,
  create_type : String, canonical_type : String, width : Int32, values : Array(T?), scale : Int32 = 0,
) : Nil forall T
  logical_type = "Nullable(#{canonical_type})"
  writer_type = T == Int8 || T == Int16 ? create_type : canonical_type
  rowbinary = rowbinary_nullable(W15_KEYS, values, width)
  range_rowbinary = rowbinary_nullable(W15_KEYS[1, 3], values[1, 3], width)
  reader = ->(part : CrystalClick::WidePart) { read_nullable(part, values) }
  writer = ->(path : String) { write_nullable(path, values, writer_type, scale) }
  exercise_case(binary, store, root, label, create_type, canonical_type, width, true, rowbinary, range_rowbinary, nullable_payload_bytes(values, width), nullable_map_bytes(values), reader, writer)
end

binary = ENV.fetch("CLICKHOUSE_BIN")
root = ENV.fetch("TMP_ROOT")
store = File.join(root, "clickhouse-store")

verify_bare(binary, store, root, "bool", "Bool", 1, [false, true, false, true, true])
verify_nullable(binary, store, root, "nullable-bool", "Bool", "Bool", 1, [nil, false.as(Bool?), true.as(Bool?), nil, true.as(Bool?)])
verify_bare(binary, store, root, "enum8", W15_ENUM8, 1, [-7_i8, 0_i8, 7_i8, -7_i8, 7_i8])
verify_nullable(binary, store, root, "nullable-enum8", W15_ENUM8, W15_ENUM8, 1, [nil, -7_i8.as(Int8?), 0_i8.as(Int8?), nil, 7_i8.as(Int8?)])
verify_bare(binary, store, root, "enum8-escaped", W15_ENUM8_ESCAPED, 1, [-7_i8, 7_i8, -7_i8, 7_i8, -7_i8])
verify_bare(binary, store, root, "enum16", W15_ENUM16, 2, [-300_i16, 0_i16, 300_i16, -300_i16, 300_i16])
verify_nullable(binary, store, root, "nullable-enum16", W15_ENUM16, W15_ENUM16, 2, [nil, -300_i16.as(Int16?), 0_i16.as(Int16?), nil, 300_i16.as(Int16?)])

{0, 2, 9}.each do |scale|
  values = [Int32::MIN, -1_i32, 0_i32, 1_i32, Int32::MAX]
  verify_bare(binary, store, root, "decimal32-s#{scale}", "Decimal32(#{scale})", 4, values, scale, "Decimal(9, #{scale})")
  nullable_values = [nil, Int32::MIN.as(Int32?), -1_i32.as(Int32?), nil, Int32::MAX.as(Int32?)]
  verify_nullable(binary, store, root, "nullable-decimal32-s#{scale}", "Decimal32(#{scale})", "Decimal(9, #{scale})", 4, nullable_values, scale)
end

{0, 4, 18}.each do |scale|
  values = [Int64::MIN, -1_i64, 0_i64, 1_i64, Int64::MAX]
  verify_bare(binary, store, root, "decimal64-s#{scale}", "Decimal64(#{scale})", 8, values, scale, "Decimal(18, #{scale})")
  nullable_values = [nil, Int64::MIN.as(Int64?), -1_i64.as(Int64?), nil, Int64::MAX.as(Int64?)]
  verify_nullable(binary, store, root, "nullable-decimal64-s#{scale}", "Decimal64(#{scale})", "Decimal(18, #{scale})", 8, nullable_values, scale)
end

puts "PASS Bool/Enum/Decimal differential oracle on ClickHouse #{binary}"
CRYSTAL

printf 'PASS Bool/Enum/Decimal differential oracle on ClickHouse %s\n' "$ACTUAL_VERSION"
