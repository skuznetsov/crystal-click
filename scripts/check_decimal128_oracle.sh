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

TMP_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/crystal-click-decimal128-oracle.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

cd "$ROOT"
export CLICKHOUSE_BIN TMP_ROOT
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache"
mkdir -p "$CRYSTAL_CACHE_DIR"

crystal run --link-flags='-fuse-ld=ld' --stdin-filename "$ROOT/scripts/check_decimal128_oracle.cr" <<'CRYSTAL'
require "file_utils"
require "json"
require "../src/crystal_click"

W16_KEYS = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64]
W16_MARK_ROWS = [2_u64, 2_u64, 1_u64, 0_u64]
W16_DECIMAL_MAX = ("9" * 38).to_i128

def run_clickhouse(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse query failed (status #{status.exit_code}): #{query}" unless status.success?
  output.to_s
end

def run_clickhouse_input(binary : String, store : String, query : String, input : IO) : String
  output = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], input: input, output: output, error: Process::Redirect::Inherit)
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

def append_u64_le(io : IO, value : UInt64) : Nil
  8.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
end

def append_i128_le(io : IO, value : Int128) : Nil
  bits = value.unsafe_as(UInt128)
  16.times { |index| io.write_byte(((bits >> (index * 8)) & 0xff_u128).to_u8) }
end

def rowbinary_bare(keys : Array(UInt64), values : Array(Int128)) : String
  raise "RowBinary fixture lengths differ" unless keys.size == values.size
  output = IO::Memory.new
  keys.each_with_index do |key, index|
    append_u64_le(output, key)
    append_i128_le(output, values[index])
  end
  output.to_s
end

def rowbinary_nullable(keys : Array(UInt64), values : Array(Int128?)) : String
  raise "RowBinary fixture lengths differ" unless keys.size == values.size
  output = IO::Memory.new
  keys.each_with_index do |key, index|
    append_u64_le(output, key)
    if value = values[index]
      output.write_byte(0_u8)
      append_i128_le(output, value)
    else
      output.write_byte(1_u8)
    end
  end
  output.to_s
end

def payload_bytes(values : Array(Int128)) : Array(UInt8)
  output = IO::Memory.new
  values.each { |value| append_i128_le(output, value) }
  output.to_slice.to_a
end

def nullable_payload_bytes(values : Array(Int128?)) : Array(UInt8)
  output = IO::Memory.new
  values.each { |value| append_i128_le(output, value || 0_i128) }
  output.to_slice.to_a
end

def null_map_bytes(values : Array(Int128?)) : Array(UInt8)
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

def stock_marks(width : Int32) : Array({UInt64, UInt64, UInt64})
  [
    {0_u64, 0_u64, 2_u64},
    {0_u64, 2_u64 * width.to_u64, 2_u64},
    {0_u64, 4_u64 * width.to_u64, 1_u64},
    {0_u64, 5_u64 * width.to_u64, 0_u64},
  ]
end

def writer_mark_entries(part : String, logical_name : String) : Array({UInt64, UInt64, UInt64})
  data = File.read(stream_path(part, logical_name)).to_slice
  offsets = [0_u64]
  offset = 0_i64
  while offset < data.size.to_i64
    frame = CrystalClick::CompressedBlock.decode_frame(data, offset)
    raise "#{logical_name} frame did not advance" if frame.end_offset <= offset
    offset = frame.end_offset
    offsets << offset.to_u64
  end
  raise "#{logical_name} has trailing frame bytes" unless offset == data.size.to_i64
  raise "#{logical_name} should have one frame per data mark" unless offsets.size == W16_MARK_ROWS.size
  Array({UInt64, UInt64, UInt64}).new(W16_MARK_ROWS.size) do |index|
    {offsets[index], 0_u64, W16_MARK_ROWS[index]}
  end
end

def assert_serialization(part : String) : Nil
  metadata = JSON.parse(File.read(File.join(part, "serialization.json")))
  expected = JSON.parse(%({"columns":[],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1}))
  raise "serialization metadata differs: #{metadata}" unless metadata == expected
end

def assert_part_shape(part : String, canonical_type : String, nullable : Bool, nested : Array(UInt8), nulls : Array(UInt8)?, stock : Bool) : Nil
  expected_columns = "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` #{canonical_type}\n"
  raise "#{canonical_type} columns metadata differs" unless File.read(File.join(part, "columns.txt")) == expected_columns
  expected_substreams = if nullable
                         "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n2 substreams for column `payload`:\n\tpayload.null\n\tpayload\n"
                       else
                         "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n1 substreams for column `payload`:\n\tpayload\n"
                       end
  raise "#{canonical_type} substream metadata differs" unless File.read(File.join(part, "columns_substreams.txt")) == expected_substreams
  raise "#{canonical_type} compression codec differs" unless File.read(File.join(part, "default_compression_codec.txt")) == "CODEC(LZ4)"
  assert_serialization(part)

  stream_count = nullable ? 3 : 2
  raise "#{canonical_type} .bin stream count differs" unless Dir.glob(File.join(part, "*.bin")).size == stream_count
  raise "#{canonical_type} .mrk2 stream count differs" unless Dir.glob(File.join(part, "*.mrk2")).size == stream_count
  raise "#{canonical_type} unexpectedly uses compressed marks" unless Dir.glob(File.join(part, "*.cmrk2")).empty?
  raise "#{canonical_type} payload stream differs" unless decoded_stream(part, "payload") == nested
  if nullable
    raise "#{canonical_type} null map differs" unless decoded_stream(part, "payload.null") == nulls
  end

  widths = {"pk" => 8, "payload" => 16}
  widths["payload.null"] = 1 if nullable
  widths.each do |logical_name, width|
    expected_marks = stock ? stock_marks(width) : writer_mark_entries(part, logical_name)
    observed = mark_entries(part, logical_name)
    raise "#{canonical_type} #{logical_name} marks differ: #{observed.inspect}" unless observed == expected_marks
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

def assert_metadata_and_rows(binary : String, store : String, table : String, canonical_type : String, name : String) : Nil
  type = run_clickhouse(binary, store, "SELECT type FROM system.columns WHERE database='default' AND table='#{table}' AND name='payload' FORMAT TSVRaw").strip
  raise "#{table}: normalized payload type #{type.inspect}, expected #{canonical_type}" unless type == canonical_type
  shape = run_clickhouse(binary, store, "SELECT rows, marks, part_type FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TabSeparated").strip
  raise "#{table}: unexpected rows/marks/type #{shape.inspect}" unless shape == "5\t4\tWide"
  actual_name = active_part_name(binary, store, table)
  raise "#{table}: active part changed unexpectedly" unless actual_name == name
end

def assert_check_table(binary : String, store : String, table : String, part_name : String) : Nil
  result = run_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "#{table}: CHECK TABLE failed: #{result.inspect}" unless result == "#{part_name}\t1"
end

def assert_corruption(binary : String, store : String, table : String, part_path : String, part_name : String, logical_name : String) : Nil
  path = stream_path(part_path, logical_name)
  original = File.open(path, "r") { |file| file.read_byte || raise "#{table}: empty #{logical_name}" }
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

def read_bare(part_path : String, values : Array(Int128)) : Nil
  part = CrystalClick::WidePart.open_typed(part_path, "payload")
  raise "bare Decimal128 normalized type differs: #{part.column_type}" unless part.column_type.starts_with?("Decimal(38, ")
  raise "bare Decimal128 row count differs" unless part.row_count == values.size.to_u64
  actual = part.read_decimal128_raw_mark_range("payload", 0, part.mark_count)
  raise "bare Decimal128 full typed read differs" unless actual == values
  values.each_slice(2).with_index do |expected, mark|
    raise "bare Decimal128 mark #{mark} read differs" unless part.read_decimal128_raw_mark_range("payload", mark, 1) == expected
  end
end

def read_nullable(part_path : String, values : Array(Int128?)) : Nil
  part = CrystalClick::WidePart.open_typed(part_path, "payload")
  raise "Nullable Decimal128 normalized type differs: #{part.column_type}" unless part.column_type.starts_with?("Nullable(Decimal(38, ")
  raise "Nullable Decimal128 row count differs" unless part.row_count == values.size.to_u64
  actual = part.read_nullable_decimal128_raw_mark_range("payload", 0, part.mark_count)
  raise "Nullable Decimal128 full typed read differs" unless actual == values
  values.each_slice(2).with_index do |expected, mark|
    raise "Nullable Decimal128 mark #{mark} read differs" unless part.read_nullable_decimal128_raw_mark_range("payload", mark, 1) == expected
  end
end

def exercise_case(binary : String, store : String, root : String, label : String, scale : Int32, nullable : Bool, values : Array(Int128?)) : Nil
  type_name = nullable ? "Nullable(Decimal128(#{scale}))" : "Decimal128(#{scale})"
  canonical_type = nullable ? "Nullable(Decimal(38, #{scale}))" : "Decimal(38, #{scale})"
  table_label = label.gsub('-', '_')
  source = "w16_stock_#{table_label}"
  create_table(binary, store, source, type_name)
  rowbinary = if nullable
                rowbinary_nullable(W16_KEYS, values)
              else
                rowbinary_bare(W16_KEYS, values.map(&.not_nil!))
              end
  run_clickhouse_input(binary, store, "INSERT INTO default.#{source} FORMAT RowBinary", IO::Memory.new(rowbinary))
  source_name = active_part_name(binary, store, source)
  assert_metadata_and_rows(binary, store, source, canonical_type, source_name)
  stock_path = File.join(root, "stock-#{label}-part")
  FileUtils.cp_r(active_part_path(binary, store, source), stock_path)
  nested = nullable ? nullable_payload_bytes(values) : payload_bytes(values.map(&.not_nil!))
  nulls = nullable ? null_map_bytes(values) : nil
  assert_part_shape(stock_path, canonical_type, nullable, nested, nulls, true)
  if nullable
    read_nullable(stock_path, values)
  else
    read_bare(stock_path, values.map(&.not_nil!))
  end
  assert_equal_bytes(run_clickhouse(binary, store, "SELECT pk, payload FROM default.#{source} ORDER BY pk FORMAT RowBinary"), rowbinary, "stock #{canonical_type} full RowBinary")
  range = values[1, 3]
  range_keys = W16_KEYS[1, 3]
  range_rowbinary = nullable ? rowbinary_nullable(range_keys, range) : rowbinary_bare(range_keys, range.map(&.not_nil!))
  assert_equal_bytes(run_clickhouse(binary, store, "SELECT pk, payload FROM default.#{source} WHERE pk >= 2 AND pk < 9 ORDER BY pk FORMAT RowBinary"), range_rowbinary, "stock #{canonical_type} key-range RowBinary")
  assert_check_table(binary, store, source, source_name)

  writer_path = File.join(root, "writer-#{label}-part")
  if nullable
    nullable_values = values
    keys = W16_KEYS.to_unsafe.to_slice(W16_KEYS.size)
    CrystalClick::WidePartWriter.write_uint64_nullable_decimal128_pair(writer_path, "pk", keys, "payload", nullable_values.to_unsafe.to_slice(nullable_values.size), scale, 2)
  else
    bare_values = values.map(&.not_nil!)
    keys = W16_KEYS.to_unsafe.to_slice(W16_KEYS.size)
    CrystalClick::WidePartWriter.write_uint64_decimal128_pair(writer_path, "pk", keys, "payload", bare_values.to_unsafe.to_slice(bare_values.size), scale, 2)
  end
  assert_part_shape(writer_path, canonical_type, nullable, nested, nulls, false)

  target = "w16_writer_#{table_label}"
  create_table(binary, store, target, type_name)
  data_path = run_clickhouse(binary, store, "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{target}' FORMAT TSVRaw").strip
  raise "#{target}: ClickHouse data path missing" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(writer_path, File.join(detached, "all_1_1_0"))
  run_clickhouse(binary, store, "ALTER TABLE default.#{target} ATTACH PART 'all_1_1_0'")
  writer_name = active_part_name(binary, store, target)
  assert_metadata_and_rows(binary, store, target, canonical_type, writer_name)
  attached_path = active_part_path(binary, store, target)
  if nullable
    read_nullable(attached_path, values)
  else
    read_bare(attached_path, values.map(&.not_nil!))
  end
  assert_equal_bytes(run_clickhouse(binary, store, "SELECT pk, payload FROM default.#{target} ORDER BY pk FORMAT RowBinary"), rowbinary, "Crystal #{canonical_type} attached full RowBinary")
  assert_equal_bytes(run_clickhouse(binary, store, "SELECT pk, payload FROM default.#{target} WHERE pk >= 2 AND pk < 9 ORDER BY pk FORMAT RowBinary"), range_rowbinary, "Crystal #{canonical_type} attached key-range RowBinary")
  assert_check_table(binary, store, target, writer_name)
  if label == "decimal128-s0"
    assert_corruption(binary, store, target, attached_path, writer_name, "payload")
  elsif label == "nullable-decimal128-s38"
    assert_corruption(binary, store, target, attached_path, writer_name, "payload")
    assert_corruption(binary, store, target, attached_path, writer_name, "payload.null")
  end
  puts "PASS #{canonical_type}: stock and Crystal directions, bytes/marks, full+key RowBinary, CHECK TABLE"
end

binary = ENV.fetch("CLICKHOUSE_BIN")
root = ENV.fetch("TMP_ROOT")
store = File.join(root, "clickhouse-store")
endpoint = W16_DECIMAL_MAX
wide = -9_223_372_036_854_775_809_i128

exercise_case(binary, store, root, "decimal128-s0", 0, false, [-endpoint, wide, -1_i128, 0_i128, endpoint].map { |value| value.as(Int128?) })
exercise_case(binary, store, root, "decimal128-raw-backing-s0", 0, false, [Int128::MIN, -1_i128, 0_i128, 1_i128, Int128::MAX].map { |value| value.as(Int128?) })
exercise_case(binary, store, root, "nullable-decimal128-s0", 0, true, [nil, (-endpoint).as(Int128?), 0_i128.as(Int128?), wide.as(Int128?), endpoint.as(Int128?)])
exercise_case(binary, store, root, "decimal128-s2", 2, false, [-endpoint, -1_i128, 0_i128, 1_i128, endpoint].map { |value| value.as(Int128?) })
exercise_case(binary, store, root, "nullable-decimal128-s2", 2, true, [nil, (-endpoint).as(Int128?), 0_i128.as(Int128?), 1_i128.as(Int128?), endpoint.as(Int128?)])
exercise_case(binary, store, root, "decimal128-s38", 38, false, [-endpoint, -1_i128, 0_i128, 1_i128, endpoint].map { |value| value.as(Int128?) })
exercise_case(binary, store, root, "nullable-decimal128-s38", 38, true, [nil, (-endpoint).as(Int128?), 0_i128.as(Int128?), 1_i128.as(Int128?), endpoint.as(Int128?)])
puts "PASS Decimal128 differential oracle on ClickHouse #{run_clickhouse(binary, store, "SELECT version()").strip}"
CRYSTAL

printf 'PASS Decimal128 differential oracle on ClickHouse %s\n' "$ACTUAL_VERSION"
