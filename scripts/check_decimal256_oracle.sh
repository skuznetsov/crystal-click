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

TMP_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/crystal-click-decimal256-oracle.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

cd "$ROOT"
export CLICKHOUSE_BIN TMP_ROOT
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache"
mkdir -p "$CRYSTAL_CACHE_DIR"

crystal run --link-flags='-fuse-ld=ld' --stdin-filename "$ROOT/scripts/check_decimal256_oracle.cr" <<'CRYSTAL'
require "file_utils"
require "json"
require "../src/crystal_click"

W20_KEYS = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64]
W20_MARK_ROWS = [2_u64, 2_u64, 1_u64, 0_u64]
EXPECTED_POSITIVE_HEX = "efcdab8967452301efcdab8967452301efcdab8967452301efcdab8967452301"
EXPECTED_NEGATIVE_HEX = "1132547698badcfe1032547698badcfe1032547698badcfe1032547698badcfe"
EXPECTED_MINIMUM_HEX = ("00" * 31) + "80"
EXPECTED_MAXIMUM_HEX = ("ff" * 31) + "7f"
EXPECTED_ZERO_HEX = "00" * 32
EXPECTED_ONE_HEX = "01" + ("00" * 31)
EXPECTED_NEGATIVE_ONE_HEX = "ff" * 32
EXPECTED_42_HEX = "2a" + ("00" * 31)
EXPECTED_NEGATIVE_42_HEX = "d6" + ("ff" * 31)

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

def assert_rejected_scale(binary : String, store : String, scale : String, label : String) : Nil
  output = IO::Memory.new
  error = IO::Memory.new
  query = "CREATE TABLE default.w20_rejected_scale_#{label} (payload Decimal256(#{scale})) ENGINE = Memory"
  status = Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: error)
  combined = output.to_s + error.to_s
  raise "ClickHouse unexpectedly accepted Decimal256(#{scale})" if status.success?
  raise "Decimal256(#{scale}) failed for unexpected reason: #{combined}" unless combined.includes?("ARGUMENT_OUT_OF_BOUND")
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

def append_u128_le(io : IO, value : UInt128) : Nil
  16.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u128).to_u8) }
end

def append_decimal256_le(io : IO, value : CrystalClick::Decimal256Value) : Nil
  append_u128_le(io, value.low)
  append_u128_le(io, value.high)
end

def bytes_from_hex(hex : String) : Array(UInt8)
  raise "hex pattern has an odd number of digits" unless hex.bytesize.even?
  Array(UInt8).new(hex.bytesize // 2) do |index|
    hex.byte_slice(index * 2, 2).to_u8(16)
  end
end

def expected_payload_bytes(patterns : Array(String)) : Array(UInt8)
  output = IO::Memory.new
  patterns.each do |pattern|
    raise "expected a 32-byte Decimal256 hex pattern, got #{pattern.bytesize} hex digits" unless pattern.bytesize == 64
    bytes_from_hex(pattern).each { |byte| output.write_byte(byte) }
  end
  output.to_slice.to_a
end

def decimal256_bytes(value : CrystalClick::Decimal256Value) : Array(UInt8)
  output = IO::Memory.new
  append_decimal256_le(output, value)
  output.to_slice.to_a
end

def decimal256_values_bytes(values : Array(CrystalClick::Decimal256Value)) : Array(UInt8)
  output = IO::Memory.new
  values.each { |value| append_decimal256_le(output, value) }
  output.to_slice.to_a
end

def zero_decimal256 : CrystalClick::Decimal256Value
  CrystalClick::Decimal256Value.new(0_u128, 0_u128)
end

def nullable_values_bytes(values : Array(CrystalClick::Decimal256Value?)) : Array(UInt8)
  zero = zero_decimal256
  output = IO::Memory.new
  values.each { |value| append_decimal256_le(output, value || zero) }
  output.to_slice.to_a
end

def null_map_bytes(values : Array(CrystalClick::Decimal256Value?)) : Array(UInt8)
  values.map { |value| value.nil? ? 1_u8 : 0_u8 }
end

def rowbinary_bare(keys : Array(UInt64), values : Array(CrystalClick::Decimal256Value)) : String
  raise "RowBinary fixture lengths differ" unless keys.size == values.size
  output = IO::Memory.new
  keys.each_with_index do |key, index|
    append_u64_le(output, key)
    append_decimal256_le(output, values[index])
  end
  output.to_s
end

def rowbinary_nullable(keys : Array(UInt64), values : Array(CrystalClick::Decimal256Value?)) : String
  raise "RowBinary fixture lengths differ" unless keys.size == values.size
  output = IO::Memory.new
  keys.each_with_index do |key, index|
    append_u64_le(output, key)
    if value = values[index]
      output.write_byte(0_u8)
      append_decimal256_le(output, value)
    else
      output.write_byte(1_u8)
    end
  end
  output.to_s
end

def scaled_decimal_text(value : CrystalClick::Decimal256Value, scale : Int32) : String
  raw = value.to_s
  return raw if scale == 0 || raw == "0"

  negative = raw.starts_with?("-")
  digits = negative ? raw[1, raw.bytesize - 1] : raw
  whole, fraction = if digits.bytesize <= scale
                      {"0", ("0" * (scale - digits.bytesize)) + digits}
                    else
                      split = digits.bytesize - scale
                      {digits[0, split], digits[split, scale]}
                    end
  "#{negative ? "-" : ""}#{whole}.#{fraction}"
end

def expected_text_rows(keys : Array(UInt64), values : Array(CrystalClick::Decimal256Value), scale : Int32) : String
  keys.each_with_index.map { |key, index| "#{key}\t#{scaled_decimal_text(values[index], scale)}" }.join("\n")
end

def expected_nullable_text_rows(keys : Array(UInt64), values : Array(CrystalClick::Decimal256Value?), scale : Int32) : String
  keys.each_with_index.map do |key, index|
    value = values[index]
    "#{key}\t#{value ? scaled_decimal_text(value, scale) : "NULL"}"
  end.join("\n")
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
  raise "#{logical_name} should have one frame per nonempty mark" unless offsets.size == 4
  Array({UInt64, UInt64, UInt64}).new(W20_MARK_ROWS.size) do |index|
    {offsets[index], 0_u64, W20_MARK_ROWS[index]}
  end
end

def assert_serialization(part : String) : Nil
  metadata = JSON.parse(File.read(File.join(part, "serialization.json")))
  expected = JSON.parse(%({"columns":[],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1}))
  raise "serialization metadata differs: #{metadata}" unless metadata == expected
end

def assert_part_shape(
  part : String,
  canonical_type : String,
  nullable : Bool,
  nested : Array(UInt8),
  nested_hex : Array(String),
  nulls : Array(UInt8)?,
  nulls_hex : String?,
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
  raise "#{canonical_type} compression codec differs" unless File.read(File.join(part, "default_compression_codec.txt")) == "CODEC(LZ4)"
  assert_serialization(part)

  stream_count = nullable ? 3 : 2
  raise "#{canonical_type} .bin stream count differs" unless Dir.glob(File.join(part, "*.bin")).size == stream_count
  raise "#{canonical_type} .mrk2 stream count differs" unless Dir.glob(File.join(part, "*.mrk2")).size == stream_count
  raise "#{canonical_type} unexpectedly uses compressed marks" unless Dir.glob(File.join(part, "*.cmrk2")).empty?
  payload = decoded_stream(part, "payload")
  raise "#{canonical_type} payload stream differs from encoded fixture" unless payload == nested
  independent_payload = expected_payload_bytes(nested_hex)
  raise "#{canonical_type} payload stream differs from hard-coded Decimal256 bytes" unless payload == independent_payload
  if nullable
    null_map = decoded_stream(part, "payload.null")
    raise "#{canonical_type} null map differs from nullable fixture" unless null_map == nulls
    expected_null_map = bytes_from_hex(nulls_hex || raise "#{canonical_type}: missing hard-coded null map")
    raise "#{canonical_type} hard-coded null map has the wrong length" unless expected_null_map.size == W20_KEYS.size
    raise "#{canonical_type} null map differs from hard-coded bytes" unless null_map == expected_null_map
  end

  widths = {"pk" => 8, "payload" => 32}
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
  raise "#{table}: active part changed unexpectedly" unless active_part_name(binary, store, table) == name
end

def assert_check_table(binary : String, store : String, table : String, part_name : String) : Nil
  result = run_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "#{table}: CHECK TABLE failed: #{result.inspect}" unless result == "#{part_name}\t1"
end

def assert_corruption(binary : String, store : String, table : String, part_path : String, part_name : String, logical_name : String) : Nil
  path = stream_path(part_path, logical_name)
  original_size = File.size(path)
  original = File.open(path, "r") { |file| file.read_byte || raise "#{table}: empty #{logical_name}" }
  damaged = ""
  begin
    File.open(path, "r+") do |file|
      file.pos = 0
      file.write_byte(original ^ 1_u8)
    end
    raise "#{table}: #{logical_name} corruption changed stream length" unless File.size(path) == original_size
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
  puts "PASS isolated CHECK TABLE detects same-size corruption in #{logical_name}"
end

def assert_isolated_corruption(
  binary : String,
  root : String,
  label : String,
  type_name : String,
  source_part : String,
  logical_names : Array(String),
) : Nil
  store = File.join(root, "corruption-store-#{label}")
  table = "w20_corruption_#{label.gsub('-', '_')}"
  create_table(binary, store, table, type_name)
  data_path = run_clickhouse(binary, store, "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw").strip
  raise "#{table}: isolated ClickHouse data path missing" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  isolated_part = File.join(detached, "all_1_1_0")
  FileUtils.cp_r(source_part, isolated_part)
  run_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  part_name = active_part_name(binary, store, table)
  part_path = active_part_path(binary, store, table)
  assert_check_table(binary, store, table, part_name)
  logical_names.each do |logical_name|
    assert_corruption(binary, store, table, part_path, part_name, logical_name)
  end
end

def assert_bare_reader(part_path : String, canonical_type : String, scale : Int32, values : Array(CrystalClick::Decimal256Value)) : Nil
  part = CrystalClick::WidePart.open_typed(part_path, "payload")
  raise "bare Decimal256 normalized type differs: #{part.column_type}" unless part.column_type == canonical_type
  raise "bare Decimal256 scale differs" unless CrystalClick::WidePart.decimal256_scale(part.column_type) == scale
  raise "bare Decimal256 row count differs" unless part.row_count == values.size.to_u64
  actual = part.read_decimal256_raw_mark_range("payload", 0, part.mark_count)
  raise "bare Decimal256 full typed read differs" unless decimal256_values_bytes(actual) == decimal256_values_bytes(values)
  values.each_slice(2).with_index do |expected, mark|
    observed = part.read_decimal256_raw_mark_range("payload", mark, 1)
    raise "bare Decimal256 mark #{mark} read differs" unless decimal256_values_bytes(observed) == decimal256_values_bytes(expected)
  end

  table = CrystalClick::WidePartTable.open_selected_typed([part_path], ["payload"])
  batched = Array(CrystalClick::Decimal256Value).new
  table.scan_typed { |batch| batched.concat(batch.decimal256_raw_for("payload").to_a) }
  raise "bare Decimal256 typed batch read differs" unless decimal256_values_bytes(batched) == decimal256_values_bytes(values)
end

def assert_nullable_reader(part_path : String, canonical_type : String, scale : Int32, values : Array(CrystalClick::Decimal256Value?)) : Nil
  part = CrystalClick::WidePart.open_typed(part_path, "payload")
  raise "Nullable Decimal256 normalized type differs: #{part.column_type}" unless part.column_type == canonical_type
  raise "Nullable Decimal256 scale differs" unless CrystalClick::WidePart.nullable_decimal256_scale(part.column_type) == scale
  raise "Nullable Decimal256 row count differs" unless part.row_count == values.size.to_u64
  actual = part.read_nullable_decimal256_raw_mark_range("payload", 0, part.mark_count)
  unless nullable_values_bytes(actual) == nullable_values_bytes(values) && null_map_bytes(actual) == null_map_bytes(values)
    raise "Nullable Decimal256 full typed read differs"
  end
  values.each_slice(2).with_index do |expected, mark|
    observed = part.read_nullable_decimal256_raw_mark_range("payload", mark, 1)
    unless nullable_values_bytes(observed) == nullable_values_bytes(expected) && null_map_bytes(observed) == null_map_bytes(expected)
      raise "Nullable Decimal256 mark #{mark} read differs"
    end
  end

  table = CrystalClick::WidePartTable.open_selected_typed([part_path], ["payload"])
  batched = Array(CrystalClick::Decimal256Value?).new
  table.scan_typed { |batch| batched.concat(batch.nullable_decimal256_raw_for("payload").to_a) }
  unless nullable_values_bytes(batched) == nullable_values_bytes(values) && null_map_bytes(batched) == null_map_bytes(values)
    raise "Nullable Decimal256 typed batch read differs"
  end
end

def exercise_case(
  binary : String,
  store : String,
  root : String,
  label : String,
  scale : Int32,
  nullable : Bool,
  values : Array(CrystalClick::Decimal256Value?),
  expected_nested_hex : Array(String),
  expected_nulls_hex : String?,
) : Nil
  type_name = nullable ? "Nullable(Decimal256(#{scale}))" : "Decimal256(#{scale})"
  canonical_type = nullable ? "Nullable(Decimal(76, #{scale}))" : "Decimal(76, #{scale})"
  table_label = label.gsub('-', '_')
  source = "w20_stock_#{table_label}"
  create_table(binary, store, source, type_name)

  rowbinary = if nullable
                rowbinary_nullable(W20_KEYS, values)
              else
                rowbinary_bare(W20_KEYS, values.map(&.not_nil!))
              end
  run_clickhouse_input(binary, store, "INSERT INTO default.#{source} FORMAT RowBinary", IO::Memory.new(rowbinary))
  source_name = active_part_name(binary, store, source)
  assert_metadata_and_rows(binary, store, source, canonical_type, source_name)
  assert_check_table(binary, store, source, source_name)

  stock_path = File.join(root, "stock-#{label}", "all_1_1_0")
  FileUtils.mkdir_p(File.dirname(stock_path))
  FileUtils.cp_r(active_part_path(binary, store, source), stock_path)
  nested = nullable ? nullable_values_bytes(values) : decimal256_values_bytes(values.map(&.not_nil!))
  nulls = nullable ? null_map_bytes(values) : nil
  assert_part_shape(stock_path, canonical_type, nullable, nested, expected_nested_hex, nulls, expected_nulls_hex, true)
  if nullable
    assert_nullable_reader(stock_path, canonical_type, scale, values)
  else
    assert_bare_reader(stock_path, canonical_type, scale, values.map(&.not_nil!))
  end
  assert_equal_bytes(run_clickhouse(binary, store, "SELECT pk, payload FROM default.#{source} ORDER BY pk FORMAT RowBinary"), rowbinary, "stock #{canonical_type} full RowBinary")
  expected_text = nullable ? expected_nullable_text_rows(W20_KEYS, values, scale) : expected_text_rows(W20_KEYS, values.map(&.not_nil!), scale)
  text_query = nullable ? "SELECT pk, ifNull(toString(payload), 'NULL') FROM default.#{source} ORDER BY pk FORMAT TSVRaw" : "SELECT pk, toString(payload) FROM default.#{source} ORDER BY pk FORMAT TSVRaw"
  actual_text = run_clickhouse(binary, store, text_query).strip
  raise "stock #{canonical_type} signed decimal text differs: actual=#{actual_text.inspect} expected=#{expected_text.inspect}" unless actual_text == expected_text

  range_keys = W20_KEYS[1, 3]
  range_values = values[1, 3]
  range_rowbinary = if nullable
                      rowbinary_nullable(range_keys, range_values)
                    else
                      rowbinary_bare(range_keys, range_values.map(&.not_nil!))
                    end
  range_query = "SELECT pk, payload FROM default.#{source} WHERE pk >= 2 AND pk < 9 ORDER BY pk FORMAT RowBinary"
  assert_equal_bytes(run_clickhouse(binary, store, range_query), range_rowbinary, "stock #{canonical_type} key-range RowBinary")

  writer_path = File.join(root, "writer-#{label}-part")
  keys = W20_KEYS.to_unsafe.to_slice(W20_KEYS.size)
  if nullable
    CrystalClick::WidePartWriter.write_uint64_nullable_decimal256_pair(
      writer_path, "pk", keys, "payload", values.to_unsafe.to_slice(values.size), scale, 2
    )
  else
    bare_values = values.map(&.not_nil!)
    CrystalClick::WidePartWriter.write_uint64_decimal256_pair(
      writer_path, "pk", keys, "payload", bare_values.to_unsafe.to_slice(bare_values.size), scale, 2
    )
  end
  assert_part_shape(writer_path, canonical_type, nullable, nested, expected_nested_hex, nulls, expected_nulls_hex, false)

  target = "w20_writer_#{table_label}"
  create_table(binary, store, target, type_name)
  data_path = run_clickhouse(binary, store, "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{target}' FORMAT TSVRaw").strip
  raise "#{target}: ClickHouse data path missing" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(writer_path, File.join(detached, "all_1_1_0"))
  run_clickhouse(binary, store, "ALTER TABLE default.#{target} ATTACH PART 'all_1_1_0'")
  writer_name = active_part_name(binary, store, target)
  assert_metadata_and_rows(binary, store, target, canonical_type, writer_name)
  assert_check_table(binary, store, target, writer_name)
  attached_path = active_part_path(binary, store, target)
  if nullable
    assert_nullable_reader(attached_path, canonical_type, scale, values)
  else
    assert_bare_reader(attached_path, canonical_type, scale, values.map(&.not_nil!))
  end
  assert_equal_bytes(run_clickhouse(binary, store, "SELECT pk, payload FROM default.#{target} ORDER BY pk FORMAT RowBinary"), rowbinary, "Crystal #{canonical_type} attached full RowBinary")
  assert_equal_bytes(run_clickhouse(binary, store, range_query.gsub(source, target)), range_rowbinary, "Crystal #{canonical_type} attached key-range RowBinary")
  if label == "decimal256-s0-extrema"
    assert_isolated_corruption(binary, root, label, type_name, writer_path, ["payload"])
  elsif label == "nullable-decimal256-s0"
    assert_isolated_corruption(binary, root, label, type_name, writer_path, ["payload.null", "payload"])
  end
  puts "PASS #{canonical_type}: stock and Crystal parts, signed bytes, typed and batch reads, marks, RowBinary, CHECK TABLE"
end

binary = ENV.fetch("CLICKHOUSE_BIN")
root = ENV.fetch("TMP_ROOT")
store = File.join(root, "clickhouse-store")
assert_rejected_scale(binary, store, "-1", "negative")
assert_rejected_scale(binary, store, "77", "above_precision")
positive = CrystalClick::Decimal256Value.from_words(
  0x0123456789abcdef_u64, 0x0123456789abcdef_u64,
  0x0123456789abcdef_u64, 0x0123456789abcdef_u64
)
negative = CrystalClick::Decimal256Value.from_words(
  0xfedcba9876543211_u64, 0xfedcba9876543210_u64,
  0xfedcba9876543210_u64, 0xfedcba9876543210_u64
)
minimum = CrystalClick::Decimal256Value.from_words(0_u64, 0_u64, 0_u64, 0x8000000000000000_u64)
maximum = CrystalClick::Decimal256Value.from_words(UInt64::MAX, UInt64::MAX, UInt64::MAX, 0x7fffffffffffffff_u64)
zero = zero_decimal256
one = CrystalClick::Decimal256Value.from_words(1_u64, 0_u64, 0_u64, 0_u64)
negative_one = CrystalClick::Decimal256Value.from_words(UInt64::MAX, UInt64::MAX, UInt64::MAX, UInt64::MAX)
forty_two = CrystalClick::Decimal256Value.from_words(42_u64, 0_u64, 0_u64, 0_u64)
negative_forty_two = CrystalClick::Decimal256Value.from_words(UInt64::MAX - 41_u64, UInt64::MAX, UInt64::MAX, UInt64::MAX)

exercise_case(binary, store, root, "decimal256-s0-extrema", 0, false, [minimum, positive, negative, zero, maximum].map(&.as(CrystalClick::Decimal256Value?)), [EXPECTED_MINIMUM_HEX, EXPECTED_POSITIVE_HEX, EXPECTED_NEGATIVE_HEX, EXPECTED_ZERO_HEX, EXPECTED_MAXIMUM_HEX], nil)
exercise_case(binary, store, root, "nullable-decimal256-s0", 0, true, [positive.as(CrystalClick::Decimal256Value?), nil, zero.as(CrystalClick::Decimal256Value?), negative.as(CrystalClick::Decimal256Value?), maximum.as(CrystalClick::Decimal256Value?)], [EXPECTED_POSITIVE_HEX, EXPECTED_ZERO_HEX, EXPECTED_ZERO_HEX, EXPECTED_NEGATIVE_HEX, EXPECTED_MAXIMUM_HEX], "0001000000")
exercise_case(binary, store, root, "decimal256-s76", 76, false, [zero, one, negative_one, one, zero].map(&.as(CrystalClick::Decimal256Value?)), [EXPECTED_ZERO_HEX, EXPECTED_ONE_HEX, EXPECTED_NEGATIVE_ONE_HEX, EXPECTED_ONE_HEX, EXPECTED_ZERO_HEX], nil)
exercise_case(binary, store, root, "nullable-decimal256-s76", 76, true, [one.as(CrystalClick::Decimal256Value?), nil, negative_one.as(CrystalClick::Decimal256Value?), zero.as(CrystalClick::Decimal256Value?), one.as(CrystalClick::Decimal256Value?)], [EXPECTED_ONE_HEX, EXPECTED_ZERO_HEX, EXPECTED_NEGATIVE_ONE_HEX, EXPECTED_ZERO_HEX, EXPECTED_ONE_HEX], "0001000000")
exercise_case(binary, store, root, "decimal256-s38", 38, false, [one, forty_two, negative_forty_two, zero, negative_one].map(&.as(CrystalClick::Decimal256Value?)), [EXPECTED_ONE_HEX, EXPECTED_42_HEX, EXPECTED_NEGATIVE_42_HEX, EXPECTED_ZERO_HEX, EXPECTED_NEGATIVE_ONE_HEX], nil)
exercise_case(binary, store, root, "nullable-decimal256-s38", 38, true, [forty_two.as(CrystalClick::Decimal256Value?), nil, negative_forty_two.as(CrystalClick::Decimal256Value?), zero.as(CrystalClick::Decimal256Value?), one.as(CrystalClick::Decimal256Value?)], [EXPECTED_42_HEX, EXPECTED_ZERO_HEX, EXPECTED_NEGATIVE_42_HEX, EXPECTED_ZERO_HEX, EXPECTED_ONE_HEX], "0001000000")
puts "PASS Decimal256 differential oracle on ClickHouse #{run_clickhouse(binary, store, "SELECT version()").strip}"
CRYSTAL

printf 'PASS Decimal256 differential oracle on ClickHouse %s\n' "$ACTUAL_VERSION"
