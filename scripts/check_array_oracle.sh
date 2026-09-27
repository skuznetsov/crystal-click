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

TMP_ROOT="$(mktemp -d /private/tmp/crystal-click-array-oracle.XXXXXX)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

cd "$ROOT"
export CLICKHOUSE_BIN TMP_ROOT
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache"
mkdir -p "$CRYSTAL_CACHE_DIR"

crystal run --link-flags='-fuse-ld=ld' --stdin-filename "$ROOT/scripts/check_array_oracle.cr" <<'CRYSTAL'
require "file_utils"
require "json"
require "../src/crystal_click"

ARRAY_KEYS = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64]
ARRAY_U64_VALUES = [
  [] of UInt64,
  [0_u64],
  [] of UInt64,
  [1_u64, 2_u64, UInt64::MAX],
  [] of UInt64,
  [42_u64],
  [7_u64, 8_u64],
]
ARRAY_STRING_VALUES = [
  [] of String,
  [""],
  ["a", ""],
  [] of String,
  [String.new(Bytes[0x61_u8, 0_u8, 0x62_u8]), String.new(Bytes[0xce_u8, 0xbb_u8])],
  [String.new(Bytes[0_u8])],
  ["tail"],
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
      pk UInt64,
      payload #{type_name}
  )
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

def append_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

def rowbinary_u64_arrays(keys : Array(UInt64), values : Array(Array(UInt64))) : String
  raise "Array(UInt64) RowBinary fixture lengths differ" unless keys.size == values.size
  output = IO::Memory.new
  keys.each_with_index do |key, index|
    append_u64_le(output, key)
    row = values[index]
    append_varuint(output, row.size.to_u64)
    row.each { |value| append_u64_le(output, value) }
  end
  output.to_s
end

def rowbinary_string_arrays(keys : Array(UInt64), values : Array(Array(String))) : String
  raise "Array(String) RowBinary fixture lengths differ" unless keys.size == values.size
  output = IO::Memory.new
  keys.each_with_index do |key, index|
    append_u64_le(output, key)
    row = values[index]
    append_varuint(output, row.size.to_u64)
    row.each do |value|
      append_varuint(output, value.bytesize.to_u64)
      output << value
    end
  end
  output.to_s
end

def u64_bytes(values : Array(UInt64)) : Array(UInt8)
  output = IO::Memory.new
  values.each { |value| append_u64_le(output, value) }
  output.to_slice.to_a
end

def array_u64_streams(keys : Array(UInt64), values : Array(Array(UInt64))) : Hash(String, Array(UInt8))
  size0 = IO::Memory.new
  nested = IO::Memory.new
  key_stream = IO::Memory.new
  keys.each { |key| append_u64_le(key_stream, key) }
  values.each do |row|
    append_u64_le(size0, row.size.to_u64)
    row.each { |value| append_u64_le(nested, value) }
  end
  {
    "pk"            => key_stream.to_slice.to_a,
    "payload.size0" => size0.to_slice.to_a,
    "payload"       => nested.to_slice.to_a,
  }
end

def array_string_streams(keys : Array(UInt64), values : Array(Array(String))) : Hash(String, Array(UInt8))
  size0 = IO::Memory.new
  nested_sizes = IO::Memory.new
  nested = IO::Memory.new
  key_stream = IO::Memory.new
  keys.each { |key| append_u64_le(key_stream, key) }
  values.each do |row|
    append_u64_le(size0, row.size.to_u64)
    row.each do |value|
      append_u64_le(nested_sizes, value.bytesize.to_u64)
      nested << value
    end
  end
  {
    "pk"            => key_stream.to_slice.to_a,
    "payload.size0" => size0.to_slice.to_a,
    "payload.size"  => nested_sizes.to_slice.to_a,
    "payload"       => nested.to_slice.to_a,
  }
end

def array_u64_segments(values : Array(Array(UInt64))) : Hash(String, Array(UInt64))
  rows = Array(UInt64).new
  nested = Array(UInt64).new
  start = 0
  while start < values.size
    finish = {start + 2, values.size}.min
    element_count = 0_u64
    (start...finish).each do |index|
      element_count += values[index].size.to_u64
    end
    rows << ((finish - start) * 8).to_u64
    nested << element_count * 8_u64
    start = finish
  end
  {
    "pk"            => rows.dup,
    "payload.size0" => rows,
    "payload"       => nested,
  }
end

def array_string_segments(values : Array(Array(String))) : Hash(String, Array(UInt64))
  rows = Array(UInt64).new
  sizes = Array(UInt64).new
  raw = Array(UInt64).new
  start = 0
  while start < values.size
    finish = {start + 2, values.size}.min
    element_count = 0_u64
    raw_bytes = 0_u64
    (start...finish).each do |index|
      values[index].each do |value|
        element_count += 1_u64
        raw_bytes += value.bytesize.to_u64
      end
    end
    rows << ((finish - start) * 8).to_u64
    sizes << element_count * 8_u64
    raw << raw_bytes
    start = finish
  end
  {
    "pk"            => rows.dup,
    "payload.size0" => rows,
    "payload.size"  => sizes,
    "payload"       => raw,
  }
end

def row_mark_counts(row_count : Int32) : Array(UInt64)
  counts = Array(UInt64).new
  start = 0
  while start < row_count
    rows = {2, row_count - start}.min
    counts << rows.to_u64
    start += rows
  end
  counts
end

def stream_path(part : String, logical_name : String, extension : String = "bin") : String
  File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.#{extension}")
end

def decoded_stream(part : String, logical_name : String) : Array(UInt8)
  path = stream_path(part, logical_name)
  raise "#{logical_name} data stream is absent" unless File.exists?(path)
  bytes = File.read(path).to_slice
  return [] of UInt8 if bytes.empty?
  CrystalClick::CompressedBlock.decode_all(bytes).to_a
end

def read_le_u64(bytes : Bytes, offset : Int32) : UInt64
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

def mark_entries(part : String, logical_name : String) : Array({UInt64, UInt64, UInt64})
  path = stream_path(part, logical_name, "mrk2")
  raise "#{logical_name} marks are absent" unless File.exists?(path)
  bytes = File.read(path).to_slice
  mark_size = CrystalClick::WidePart::MARK_SIZE
  raise "#{logical_name} has truncated .mrk2 records" unless bytes.size % mark_size == 0
  Array({UInt64, UInt64, UInt64}).new(bytes.size // mark_size) do |index|
    offset = index * mark_size
    {read_le_u64(bytes, offset), read_le_u64(bytes, offset + 8), read_le_u64(bytes, offset + 16)}
  end
end

def stock_mark_entries(segment_sizes : Array(UInt64), row_counts : Array(UInt64)) : Array({UInt64, UInt64, UInt64})
  raise "stock segment/mark counts differ" unless segment_sizes.size == row_counts.size
  result = Array({UInt64, UInt64, UInt64}).new
  decompressed_offset = 0_u64
  segment_sizes.each_with_index do |size, index|
    result << {0_u64, decompressed_offset, row_counts[index]}
    decompressed_offset += size
  end
  result << {0_u64, decompressed_offset, 0_u64}
  result
end

def frame_offsets(part : String, logical_name : String) : Array(UInt64)
  data = File.read(stream_path(part, logical_name)).to_slice
  offsets = [0_u64]
  offset = 0_i64
  while offset < data.size.to_i64
    frame = CrystalClick::CompressedBlock.decode_frame(data, offset)
    raise "#{logical_name} compressed frame did not advance" if frame.end_offset <= offset
    offset = frame.end_offset
    offsets << offset.to_u64
  end
  raise "#{logical_name} has trailing compressed bytes" unless offset == data.size.to_i64
  offsets
end

def writer_mark_entries(
  part : String,
  logical_name : String,
  segment_sizes : Array(UInt64),
  row_counts : Array(UInt64),
) : Array({UInt64, UInt64, UInt64})
  raise "writer segment/mark counts differ" unless segment_sizes.size == row_counts.size
  offsets = frame_offsets(part, logical_name)
  frame_index = 0
  compressed_offset = 0_u64
  result = Array({UInt64, UInt64, UInt64}).new
  segment_sizes.each_with_index do |size, index|
    result << {compressed_offset, 0_u64, row_counts[index]}
    if size > 0
      frame_index += 1
      raise "#{logical_name} has fewer frames than nonempty mark payloads" if frame_index >= offsets.size
      compressed_offset = offsets[frame_index]
    end
  end
  raise "#{logical_name} frame count differs from nonempty marks" unless frame_index == offsets.size - 1
  result << {compressed_offset, 0_u64, 0_u64}
  result
end

def assert_part_metadata(
  part : String,
  type_name : String,
  row_count : Int32,
  streams : Hash(String, Array(UInt8)),
  writer : Bool,
) : Nil
  expected_columns = "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` #{type_name}\n"
  actual_columns = File.read(File.join(part, "columns.txt"))
  raise "#{type_name} columns metadata differs: #{actual_columns.inspect}" unless actual_columns == expected_columns
  expected_substreams = if type_name == "Array(UInt64)"
                         "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n2 substreams for column `payload`:\n\tpayload.size0\n\tpayload\n"
                       else
                         "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n3 substreams for column `payload`:\n\tpayload.size0\n\tpayload.size\n\tpayload\n"
                       end
  raise "#{type_name} substream metadata differs" unless File.read(File.join(part, "columns_substreams.txt")) == expected_substreams
  raise "#{type_name} compression codec differs" unless File.read(File.join(part, "default_compression_codec.txt")) == "CODEC(LZ4)"

  metadata = JSON.parse(File.read(File.join(part, "serialization.json")))
  columns = writer ? "[]" : "[{\"kind\":\"Default\",\"name\":\"pk\",\"num_defaults\":0,\"num_rows\":#{row_count}}]"
  expected_metadata = JSON.parse(%({"columns":#{columns},"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1}))
  raise "#{type_name} serialization metadata differs: #{metadata}" unless metadata == expected_metadata

  stream_count = streams.size
  raise "#{type_name} .bin stream count differs" unless Dir.glob(File.join(part, "*.bin")).size == stream_count
  raise "#{type_name} .mrk2 stream count differs" unless Dir.glob(File.join(part, "*.mrk2")).size == stream_count
  raise "#{type_name} unexpectedly uses compressed marks" unless Dir.glob(File.join(part, "*.cmrk2")).empty?
end

def assert_stock_shape(
  part : String,
  type_name : String,
  row_count : Int32,
  streams : Hash(String, Array(UInt8)),
  segments : Hash(String, Array(UInt64)),
) : Nil
  assert_part_metadata(part, type_name, row_count, streams, false)
  rows = row_mark_counts(row_count)
  streams.each do |name, expected|
    observed = decoded_stream(part, name)
    raise "#{type_name} #{name} decoded bytes differ" unless observed == expected
    expected_marks = stock_mark_entries(segments[name], rows)
    actual_marks = mark_entries(part, name)
    raise "stock #{type_name} #{name} marks differ: #{actual_marks.inspect}" unless actual_marks == expected_marks
  end
end

def assert_writer_shape(
  part : String,
  type_name : String,
  row_count : Int32,
  streams : Hash(String, Array(UInt8)),
  segments : Hash(String, Array(UInt64)),
) : Nil
  assert_part_metadata(part, type_name, row_count, streams, true)
  rows = row_mark_counts(row_count)
  streams.each do |name, expected|
    observed = decoded_stream(part, name)
    raise "Crystal writer #{type_name} #{name} decoded bytes differ" unless observed == expected
    expected_marks = writer_mark_entries(part, name, segments[name], rows)
    actual_marks = mark_entries(part, name)
    raise "Crystal writer #{type_name} #{name} marks differ: #{actual_marks.inspect}" unless actual_marks == expected_marks
  end
end

def assert_u64_reader(part_path : String, expected : Array(Array(UInt64))) : Nil
  reader = CrystalClick::WidePart.open_typed(part_path, "payload")
  raise "Array(UInt64) reader type differs: #{reader.column_type}" unless reader.column_type == "Array(UInt64)"
  raise "Array(UInt64) reader row count differs" unless reader.row_count == expected.size.to_u64
  rows = row_mark_counts(expected.size)
  raise "Array(UInt64) data mark count differs" unless reader.mark_count == rows.size
  raise "Array(UInt64) data mark rows differ: #{reader.mark_row_counts.inspect}" unless reader.mark_row_counts == rows
  full = reader.read_array_uint64_mark_range("payload", 0, reader.mark_count)
  raise "Array(UInt64) full mark-range read differs" unless full == expected

  start = 0
  rows.each_with_index do |count, mark|
    expected_mark = expected[start, count.to_i]
    actual_mark = reader.read_array_uint64_mark_range("payload", mark, 1)
    raise "Array(UInt64) mark #{mark} read differs" unless actual_mark == expected_mark
    start += count.to_i
  end

end

def assert_string_reader(part_path : String, expected : Array(Array(String))) : Nil
  reader = CrystalClick::WidePart.open_typed(part_path, "payload")
  raise "Array(String) reader type differs: #{reader.column_type}" unless reader.column_type == "Array(String)"
  raise "Array(String) reader row count differs" unless reader.row_count == expected.size.to_u64
  rows = row_mark_counts(expected.size)
  raise "Array(String) data mark count differs" unless reader.mark_count == rows.size
  raise "Array(String) data mark rows differ: #{reader.mark_row_counts.inspect}" unless reader.mark_row_counts == rows
  full = reader.read_array_string_mark_range("payload", 0, reader.mark_count)
  raise "Array(String) full mark-range read differs" unless full == expected

  start = 0
  rows.each_with_index do |count, mark|
    expected_mark = expected[start, count.to_i]
    actual_mark = reader.read_array_string_mark_range("payload", mark, 1)
    raise "Array(String) mark #{mark} read differs" unless actual_mark == expected_mark
    start += count.to_i
  end

end

def active_part_name(binary : String, store : String, table : String) : String
  name = run_clickhouse(binary, store, "SELECT name FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw").strip
  raise "#{table}: missing/ambiguous active part name #{name.inspect}" if name.empty? || name.includes?('\n')
  name
end

def active_part_path(binary : String, store : String, table : String) : String
  path = run_clickhouse(binary, store, "SELECT path FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw").strip
  raise "#{table}: active part path missing" if path.empty?
  path
end

def assert_check_table(binary : String, store : String, table : String, part_name : String) : Nil
  result = run_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "#{table}: CHECK TABLE failed: #{result.inspect}" unless result == "#{part_name}\t1"
end

def assert_rowbinary(binary : String, store : String, table : String, full : String, ranged : String) : Nil
  actual_full = run_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  raise "#{table}: full RowBinary output differs" unless actual_full.to_slice == full.to_slice
  actual_range = run_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} WHERE pk >= 2 AND pk < 7 ORDER BY pk FORMAT RowBinary")
  raise "#{table}: key-range RowBinary output differs" unless actual_range.to_slice == ranged.to_slice
end

def attach_part(binary : String, store : String, table : String, type_name : String, part : String) : {String, String}
  create_table(binary, store, table, type_name)
  data_path = run_clickhouse(binary, store, "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw").strip
  raise "#{table}: ClickHouse data path is missing" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  run_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  name = active_part_name(binary, store, table)
  {name, active_part_path(binary, store, table)}
end

def assert_same_size_corruption(
  binary : String,
  root : String,
  label : String,
  type_name : String,
  source_part : String,
  logical_name : String,
) : Nil
  store = File.join(root, "corruption-store-#{label}-#{logical_name.gsub('.', '_')}")
  table = "array_corruption_#{label}_#{logical_name.gsub('.', '_')}"
  part_name, attached_path = attach_part(binary, store, table, type_name, source_part)
  assert_check_table(binary, store, table, part_name)

  path = stream_path(attached_path, logical_name)
  original_size = File.size(path)
  original = File.open(path, "r") { |file| file.read_byte || raise "#{table}: empty #{logical_name} stream" }
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
  unless fields.size == 3 &&
         fields[0] == part_name &&
         fields[1] == "0" &&
         fields[2].includes?("CHECKSUM_DOESNT_MATCH")
    raise "#{table}: CHECK TABLE missed same-size #{logical_name} corruption: #{damaged.inspect}"
  end
  assert_check_table(binary, store, table, part_name)
  puts "PASS #{type_name} same-size #{logical_name} corruption detected and restored"
end

def stock_u64_case(
  binary : String,
  store : String,
  root : String,
  label : String,
  keys : Array(UInt64),
  values : Array(Array(UInt64)),
) : String
  table = "stock_array_u64_#{label}"
  type_name = "Array(UInt64)"
  rowbinary = rowbinary_u64_arrays(keys, values)
  create_table(binary, store, table, type_name)
  run_clickhouse_input(binary, store, "INSERT INTO default.#{table} FORMAT RowBinary", IO::Memory.new(rowbinary))
  name = active_part_name(binary, store, table)
  path = active_part_path(binary, store, table)
  assert_check_table(binary, store, table, name)

  range_keys = keys.select { |key| key >= 2_u64 && key < 7_u64 }
  range_values = Array(Array(UInt64)).new
  keys.each_with_index do |key, index|
    range_values << values[index] if key >= 2_u64 && key < 7_u64
  end
  range_rowbinary = rowbinary_u64_arrays(range_keys, range_values)
  assert_rowbinary(binary, store, table, rowbinary, range_rowbinary)

  stock_path = File.join(root, "stock-u64-#{label}", "all_1_1_0")
  FileUtils.mkdir_p(File.dirname(stock_path))
  FileUtils.cp_r(path, stock_path)
  streams = array_u64_streams(keys, values)
  segments = array_u64_segments(values)
  assert_stock_shape(stock_path, type_name, keys.size, streams, segments)
  assert_u64_reader(stock_path, values)
  puts "PASS stock Array(UInt64) #{label}: exact substreams, adaptive .mrk2, mark reads, RowBinary, CHECK TABLE"
  stock_path
end

def stock_string_case(
  binary : String,
  store : String,
  root : String,
  label : String,
  keys : Array(UInt64),
  values : Array(Array(String)),
) : String
  table = "stock_array_string_#{label}"
  type_name = "Array(String)"
  rowbinary = rowbinary_string_arrays(keys, values)
  create_table(binary, store, table, type_name)
  run_clickhouse_input(binary, store, "INSERT INTO default.#{table} FORMAT RowBinary", IO::Memory.new(rowbinary))
  name = active_part_name(binary, store, table)
  path = active_part_path(binary, store, table)
  assert_check_table(binary, store, table, name)

  range_keys = keys.select { |key| key >= 2_u64 && key < 7_u64 }
  range_values = Array(Array(String)).new
  keys.each_with_index do |key, index|
    range_values << values[index] if key >= 2_u64 && key < 7_u64
  end
  range_rowbinary = rowbinary_string_arrays(range_keys, range_values)
  assert_rowbinary(binary, store, table, rowbinary, range_rowbinary)

  stock_path = File.join(root, "stock-string-#{label}", "all_1_1_0")
  FileUtils.mkdir_p(File.dirname(stock_path))
  FileUtils.cp_r(path, stock_path)
  streams = array_string_streams(keys, values)
  segments = array_string_segments(values)
  assert_stock_shape(stock_path, type_name, keys.size, streams, segments)
  assert_string_reader(stock_path, values)
  puts "PASS stock Array(String) #{label}: exact substreams, adaptive .mrk2, mark reads, binary strings, RowBinary, CHECK TABLE"
  stock_path
end

def writer_u64_roundtrip(binary : String, store : String, root : String, values : Array(Array(UInt64))) : Nil
  part = File.join(root, "writer-array-u64-part")
  CrystalClick::WidePartWriter.write_uint64_array_uint64_pair(
    part,
    "pk",
    ARRAY_KEYS.to_unsafe.to_slice(ARRAY_KEYS.size),
    "payload",
    values.to_unsafe.to_slice(values.size),
    rows_per_mark: 2
  )
  streams = array_u64_streams(ARRAY_KEYS, values)
  segments = array_u64_segments(values)
  assert_writer_shape(part, "Array(UInt64)", values.size, streams, segments)
  assert_u64_reader(part, values)

  table = "writer_array_u64"
  name, attached_path = attach_part(binary, store, table, "Array(UInt64)", part)
  assert_check_table(binary, store, table, name)
  full = rowbinary_u64_arrays(ARRAY_KEYS, values)
  range_keys = ARRAY_KEYS[1, 5]
  range_values = values[1, 5]
  assert_rowbinary(binary, store, table, full, rowbinary_u64_arrays(range_keys, range_values))
  assert_same_size_corruption(binary, root, "u64", "Array(UInt64)", part, "payload.size0")
  assert_same_size_corruption(binary, root, "u64", "Array(UInt64)", part, "payload")
  raise "writer attached path is missing" if attached_path.empty?
  puts "PASS Crystal writer Array(UInt64): exact streams and marks, self-reader, ClickHouse ATTACH/CHECK, full/range RowBinary"
end

def writer_string_roundtrip(binary : String, store : String, root : String, values : Array(Array(String))) : Nil
  part = File.join(root, "writer-array-string-part")
  CrystalClick::WidePartWriter.write_uint64_array_string_pair(
    part,
    "pk",
    ARRAY_KEYS.to_unsafe.to_slice(ARRAY_KEYS.size),
    "payload",
    values.to_unsafe.to_slice(values.size),
    rows_per_mark: 2
  )
  streams = array_string_streams(ARRAY_KEYS, values)
  segments = array_string_segments(values)
  assert_writer_shape(part, "Array(String)", values.size, streams, segments)
  assert_string_reader(part, values)

  table = "writer_array_string"
  name, attached_path = attach_part(binary, store, table, "Array(String)", part)
  assert_check_table(binary, store, table, name)
  full = rowbinary_string_arrays(ARRAY_KEYS, values)
  range_keys = ARRAY_KEYS[1, 5]
  range_values = values[1, 5]
  assert_rowbinary(binary, store, table, full, rowbinary_string_arrays(range_keys, range_values))
  assert_same_size_corruption(binary, root, "string", "Array(String)", part, "payload.size0")
  assert_same_size_corruption(binary, root, "string", "Array(String)", part, "payload.size")
  assert_same_size_corruption(binary, root, "string", "Array(String)", part, "payload")
  raise "writer attached path is missing" if attached_path.empty?
  puts "PASS Crystal writer Array(String): exact streams and marks, NUL/UTF-8 bytes, self-reader, ClickHouse ATTACH/CHECK, full/range RowBinary"
end

binary = ENV.fetch("CLICKHOUSE_BIN")
root = ENV.fetch("TMP_ROOT")
store = File.join(root, "clickhouse-store")

stock_u64_case(binary, store, root, "mixed", ARRAY_KEYS, ARRAY_U64_VALUES)
stock_string_case(binary, store, root, "mixed", ARRAY_KEYS, ARRAY_STRING_VALUES)

empty_u64_keys = [1_u64, 2_u64, 3_u64]
empty_u64_values = [[] of UInt64, [] of UInt64, [] of UInt64]
stock_u64_case(binary, store, root, "all_empty", empty_u64_keys, empty_u64_values)

empty_string_keys = [1_u64, 2_u64, 3_u64, 4_u64]
empty_string_values = [[] of String, [""], ["" , ""], [] of String]
stock_string_case(binary, store, root, "zero_nested_bytes", empty_string_keys, empty_string_values)

writer_u64_roundtrip(binary, store, root, ARRAY_U64_VALUES)
writer_string_roundtrip(binary, store, root, ARRAY_STRING_VALUES)
puts "PASS pinned ClickHouse stock/Crystal Array(UInt64) and Array(String) physical oracle"
CRYSTAL
