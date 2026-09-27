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

TMP_ROOT="$(mktemp -d /private/tmp/crystal-click-lowcard-w22.XXXXXX)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

cd "$ROOT"
export CLICKHOUSE_BIN TMP_ROOT
export CRYSTAL_CACHE_DIR="$TMP_ROOT/crystal-cache"
mkdir -p "$CRYSTAL_CACHE_DIR"

crystal run --link-flags='-fuse-ld=ld' --stdin-filename "$ROOT/scripts/check_lowcard_string_oracle.cr" <<'CRYSTAL'
require "file_utils"
require "json"
require "../src/crystal_click"

LC_KEYS = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64, 8_u64]
LC_BINARY = String.new(Bytes[0x61_u8, 0_u8, 0xff_u8])
LC_VALUES = ["", "repeat", LC_BINARY, "repeat", "tail", "", "repeat", "z\0"]
LC_WRITER_VALUES = ["writer-alpha", "writer-beta", LC_BINARY, "writer-alpha", "tail", "writer-beta", "z\0", "tail"]
LC_ROWS_PER_MARK = 3
LC_ROW_COUNTS = [3_u64, 3_u64, 2_u64]

def run_clickhouse(binary : String, store : String, query : String, no_global : Bool = false) : String
  args = ["local"]
  args << "--low_cardinality_max_dictionary_size=0" if no_global
  args.concat(["--path", store, "--query", query])
  output = IO::Memory.new
  status = Process.run(binary, args, output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse query failed (status #{status.exit_code}): #{query}" unless status.success?
  output.to_s
end

def run_clickhouse_input(binary : String, store : String, query : String, input : IO, no_global : Bool = false) : String
  args = ["local"]
  args << "--low_cardinality_max_dictionary_size=0" if no_global
  args.concat(["--path", store, "--query", query])
  output = IO::Memory.new
  status = Process.run(binary, args, input: input, output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse RowBinary insert failed (status #{status.exit_code}): #{query}" unless status.success?
  output.to_s
end

def create_table(binary : String, store : String, table : String, no_global : Bool = false) : Nil
  run_clickhouse(binary, store, <<-SQL, no_global)
  CREATE TABLE default.#{table}
  (
      pk UInt64,
      payload LowCardinality(String)
  )
  ENGINE = MergeTree
  ORDER BY pk
  SETTINGS
      index_granularity = #{LC_ROWS_PER_MARK},
      index_granularity_bytes = 10485760,
      enable_mixed_granularity_parts = 1,
      min_rows_for_wide_part = 0,
      min_bytes_for_wide_part = 0,
      compress_marks = 1,
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

def append_string(io : IO, value : String) : Nil
  append_varuint(io, value.bytesize.to_u64)
  io << value
end

def rowbinary_rows(keys : Array(UInt64), values : Array(String)) : String
  raise "LowCardinality RowBinary fixture lengths differ" unless keys.size == values.size
  output = IO::Memory.new
  keys.each_with_index do |key, index|
    append_u64_le(output, key)
    append_string(output, values[index])
  end
  output.to_s
end

def rowbinary_range(keys : Array(UInt64), values : Array(String)) : String
  selected_keys = Array(UInt64).new
  selected_values = Array(String).new
  keys.each_with_index do |key, index|
    next unless key >= 2_u64 && key < 7_u64
    selected_keys << key
    selected_values << values[index]
  end
  rowbinary_rows(selected_keys, selected_values)
end

def row_mark_counts(row_count : Int32) : Array(UInt64)
  counts = Array(UInt64).new
  start = 0
  while start < row_count
    rows = {LC_ROWS_PER_MARK, row_count - start}.min
    counts << rows.to_u64
    start += rows
  end
  counts
end

def mark_ranges(values : Array(String)) : Array(Tuple(Int32, Int32))
  ranges = Array(Tuple(Int32, Int32)).new
  start = 0
  while start < values.size
    finish = {start + LC_ROWS_PER_MARK, values.size}.min
    ranges << {start, finish}
    start = finish
  end
  ranges
end

def unique_strings(values : Array(String), reserve_empty : Bool = false) : Array(String)
  result = Array(String).new
  result << "" if reserve_empty
  values.each do |value|
    result << value unless result.includes?(value)
  end
  result
end

def lowcard_streams(values : Array(String), keys : Array(UInt64), no_global : Bool) : Hash(String, Array(UInt8))
  raise "LowCardinality fixture lengths differ" unless keys.size == values.size
  dictionary = IO::Memory.new
  index_stream = IO::Memory.new
  key_stream = IO::Memory.new
  keys.each { |key| append_u64_le(key_stream, key) }

  if no_global
    append_u64_le(dictionary, 1_u64)
    mark_ranges(values).each do |_start, _finish|
      # Stock retains one empty/default record in .dict per mark when global
      # dictionaries are disabled; the actual mark keys live in the ID stream.
      append_u64_le(dictionary, 1_u64)
      append_string(dictionary, "")
    end
  else
    dictionary_keys = unique_strings(values, reserve_empty: true)
    append_u64_le(dictionary, 1_u64)
    append_u64_le(dictionary, dictionary_keys.size.to_u64)
    dictionary_keys.each { |value| append_string(dictionary, value) }
  end

  mark_ranges(values).each_with_index do |(start, finish), mark_index|
    mark_values = values[start, finish - start]
    if no_global
      mark_keys = unique_strings(mark_values, reserve_empty: true)
      append_u64_le(index_stream, 0x600_u64)
      append_u64_le(index_stream, mark_keys.size.to_u64)
      mark_keys.each { |value| append_string(index_stream, value) }
      append_u64_le(index_stream, mark_values.size.to_u64)
      mark_values.each { |value| index_stream.write_byte(mark_keys.index(value).not_nil!.to_u8) }
    else
      dictionary_keys = unique_strings(values, reserve_empty: true)
      append_u64_le(index_stream, mark_index == 0 ? 0x500_u64 : 0x100_u64)
      append_u64_le(index_stream, mark_values.size.to_u64)
      mark_values.each { |value| index_stream.write_byte(dictionary_keys.index(value).not_nil!.to_u8) }
    end
  end

  {
    "pk"          => key_stream.to_slice.to_a,
    "payload.dict" => dictionary.to_slice.to_a,
    "payload"       => index_stream.to_slice.to_a,
  }
end

def stream_path(part : String, logical_name : String, extension : String = "bin") : String
  File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.#{extension}")
end

def decoded_stream(part : String, logical_name : String) : Array(UInt8)
  path = stream_path(part, logical_name)
  raise "#{logical_name} data stream is absent" unless File.file?(path)
  bytes = File.read(path).to_slice
  return [] of UInt8 if bytes.empty?
  CrystalClick::CompressedBlock.decode_all(bytes).to_a
end

def read_le_u64(bytes : Bytes, offset : Int32) : UInt64
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

def mark_entries(part : String, logical_name : String) : Array(Tuple(UInt64, UInt64, UInt64))
  plain = stream_path(part, logical_name, "mrk2")
  compressed = stream_path(part, logical_name, "cmrk2")
  raise "#{logical_name} mark representation is ambiguous" if File.file?(plain) && File.file?(compressed)
  path = File.file?(compressed) ? compressed : plain
  raise "#{logical_name} marks are absent" unless File.file?(path)
  bytes = if path == compressed
            CrystalClick::CompressedBlock.decode_all(File.read(path).to_slice)
          else
            File.read(path).to_slice
          end
  mark_size = CrystalClick::WidePart::MARK_SIZE
  raise "#{logical_name} has truncated mark records" if bytes.empty? || bytes.size % mark_size != 0
  Array(Tuple(UInt64, UInt64, UInt64)).new(bytes.size // mark_size) do |index|
    offset = index * mark_size
    {read_le_u64(bytes, offset), read_le_u64(bytes, offset + 8), read_le_u64(bytes, offset + 16)}
  end
end

def expected_stock_data_marks(part : String, logical_name : String, segment_sizes : Array(UInt64), rows : Array(UInt64)) : Array(Tuple(UInt64, UInt64, UInt64))
  raise "#{logical_name} stock segment/mark counts differ" unless segment_sizes.size == rows.size
  result = Array(Tuple(UInt64, UInt64, UInt64)).new
  offset = 0_u64
  segment_sizes.each_with_index do |size, index|
    result << {0_u64, offset, rows[index]}
    offset += size
  end
  # This fixture fits in one compressed frame; stock marks raw EOF within it.
  result << {0_u64, offset, 0_u64}
  result
end

def expected_shared_dict_marks(part : String, rows : Array(UInt64)) : Array(Tuple(UInt64, UInt64, UInt64))
  result = rows.map { |count| {0_u64, 8_u64, count} }
  result << {0_u64, decoded_stream(part, "payload.dict").size.to_u64, 0_u64}
  result
end

def expected_local_dict_marks(part : String, rows : Array(UInt64)) : Array(Tuple(UInt64, UInt64, UInt64))
  result = Array(Tuple(UInt64, UInt64, UInt64)).new
  offset = 8_u64
  rows.each do |count|
    result << {0_u64, offset, count}
    offset += 9_u64 # UInt64 count 1 and VarUInt zero-length default String.
  end
  result << {0_u64, offset, 0_u64}
  result
end

def assert_part_metadata(part : String, stock : Bool) : Nil
  expected_columns = "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` LowCardinality(String)\n"
  raise "LowCardinality columns metadata differs" unless File.read(File.join(part, "columns.txt")) == expected_columns
  expected_substreams = "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n2 substreams for column `payload`:\n\tpayload.dict\n\tpayload\n"
  raise "LowCardinality substream metadata differs" unless File.read(File.join(part, "columns_substreams.txt")) == expected_substreams
  raise "LowCardinality codec metadata differs" unless File.read(File.join(part, "default_compression_codec.txt")) == "CODEC(LZ4)"

  columns = stock ? "[{\"kind\":\"Default\",\"name\":\"pk\",\"num_defaults\":0,\"num_rows\":#{LC_KEYS.size}}]" : "[]"
  expected = JSON.parse(%({"columns":#{columns},"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1}))
  actual = JSON.parse(File.read(File.join(part, "serialization.json")))
  raise "LowCardinality serialization metadata differs: #{actual}" unless actual == expected
end

def assert_stock_shape(part : String, values : Array(String), no_global : Bool) : Nil
  streams = lowcard_streams(values, LC_KEYS, no_global)
  assert_part_metadata(part, true)
  raise "stock LowCardinality .bin stream count differs" unless Dir.glob(File.join(part, "*.bin")).size == 3
  raise "stock LowCardinality must use compressed .cmrk2 marks" unless Dir.glob(File.join(part, "*.cmrk2")).size == 3
  raise "stock LowCardinality unexpectedly uses plain .mrk2 marks" unless Dir.glob(File.join(part, "*.mrk2")).empty?

  segments = {
    "pk"      => LC_ROW_COUNTS.map { |count| count * 8_u64 },
    "payload" => [] of UInt64,
  }
  index = IO::Memory.new
  # The exact index bytes were checked above; recover mark lengths from their
  # offsets by re-encoding one mark at a time to avoid trusting stock metadata.
  if no_global
    mark_ranges(values).each do |start, finish|
      local = values[start, finish - start]
      keys = unique_strings(local, reserve_empty: true)
      segment = IO::Memory.new
      append_u64_le(segment, 0x600_u64)
      append_u64_le(segment, keys.size.to_u64)
      keys.each { |value| append_string(segment, value) }
      append_u64_le(segment, local.size.to_u64)
      local.each { |value| segment.write_byte(keys.index(value).not_nil!.to_u8) }
      segments["payload"] << segment.size.to_u64
      index.write(segment.to_slice)
    end
  else
    dictionary_keys = unique_strings(values, reserve_empty: true)
    mark_ranges(values).each_with_index do |(start, finish), mark_index|
      local = values[start, finish - start]
      segment = IO::Memory.new
      append_u64_le(segment, mark_index == 0 ? 0x500_u64 : 0x100_u64)
      append_u64_le(segment, local.size.to_u64)
      local.each { |value| segment.write_byte(dictionary_keys.index(value).not_nil!.to_u8) }
      segments["payload"] << segment.size.to_u64
      index.write(segment.to_slice)
    end
  end
  raise "internal LowCardinality fixture index mismatch" unless index.to_slice.to_a == streams["payload"]

  streams.each do |name, expected|
    actual_bytes = decoded_stream(part, name)
    raise "stock LowCardinality #{name} decoded bytes differ" unless actual_bytes == expected
    expected_marks = case name
                     when "payload.dict"
                       no_global ? expected_local_dict_marks(part, LC_ROW_COUNTS) : expected_shared_dict_marks(part, LC_ROW_COUNTS)
                     else
                       expected_stock_data_marks(part, name, segments[name], LC_ROW_COUNTS)
                     end
    actual_marks = mark_entries(part, name)
    raise "stock LowCardinality #{name} marks differ: #{actual_marks.inspect}" unless actual_marks == expected_marks
  end
end

def active_part_name(binary : String, store : String, table : String, no_global : Bool = false) : String
  name = run_clickhouse(binary, store, "SELECT name FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw", no_global).strip
  raise "#{table}: missing/ambiguous active part name #{name.inspect}" if name.empty? || name.includes?('\n')
  name
end

def active_part_path(binary : String, store : String, table : String, no_global : Bool = false) : String
  path = run_clickhouse(binary, store, "SELECT path FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw", no_global).strip
  raise "#{table}: active part path is missing" if path.empty?
  path
end

def assert_check_table(binary : String, store : String, table : String, part_name : String, no_global : Bool = false) : Nil
  result = run_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated", no_global).strip
  raise "#{table}: CHECK TABLE failed: #{result.inspect}" unless result == "#{part_name}\t1"
end

def assert_rowbinary(binary : String, store : String, table : String, full : String, ranged : String, no_global : Bool = false) : Nil
  actual_full = run_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary", no_global)
  raise "#{table}: full RowBinary output differs" unless actual_full.to_slice == full.to_slice
  actual_range = run_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} WHERE pk >= 2 AND pk < 7 ORDER BY pk FORMAT RowBinary", no_global)
  raise "#{table}: key-range RowBinary output differs" unless actual_range.to_slice == ranged.to_slice
end

def attach_part(binary : String, store : String, table : String, part : String) : {String, String}
  create_table(binary, store, table)
  data_path = run_clickhouse(binary, store, "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw").strip
  raise "#{table}: ClickHouse data path is missing" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  run_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  {active_part_name(binary, store, table), active_part_path(binary, store, table)}
end

def assert_crystal_reader(part : String, values : Array(String), keys : Array(UInt64)) : Nil
  reader = CrystalClick::WidePart.open_typed(part, "payload")
  raise "Crystal LowCardinality type differs: #{reader.column_type}" unless reader.column_type == "LowCardinality(String)"
  raise "Crystal LowCardinality row count differs" unless reader.row_count == values.size.to_u64
  rows = row_mark_counts(values.size)
  raise "Crystal LowCardinality mark rows differ" unless reader.mark_row_counts == rows
  raise "Crystal LowCardinality full read differs" unless reader.read_low_cardinality_string_mark_range("payload", 0, reader.mark_count) == values

  cursor = 0
  rows.each_with_index do |count, mark|
    expected = values[cursor, count.to_i]
    actual = reader.read_low_cardinality_string_mark_range("payload", mark, 1)
    raise "Crystal LowCardinality mark #{mark} read differs" unless actual == expected
    cursor += count.to_i
  end

  checksums = CrystalClick::PartChecksums.open(part)
  primary = CrystalClick::PrimaryKeyIndex.open(part, reader.mark_count, checksums)
  candidates = primary.candidate_marks(2_u64, 6_u64)
  table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
  observed_keys = Array(UInt64).new
  observed_values = Array(String).new
  table.scan_typed_candidate_marks([candidates]) do |batch|
    batch_keys = batch.values_for("pk", UInt64)
    batch_values = batch.low_cardinality_strings_for("payload")
    batch_keys.each_with_index do |key, index|
      if key >= 2_u64 && key < 7_u64
        observed_keys << key
        observed_values << batch_values[index]
      end
    end
  end
  expected_keys = Array(UInt64).new
  expected_values = Array(String).new
  keys.each_with_index do |key, index|
    if key >= 2_u64 && key < 7_u64
      expected_keys << key
      expected_values << values[index]
    end
  end
  raise "Crystal LowCardinality candidate range differs" unless observed_keys == expected_keys && observed_values == expected_values
end

def writer_mark_entries(part : String, logical_name : String, segment_sizes : Array(UInt64), rows : Array(UInt64)) : Array(Tuple(UInt64, UInt64, UInt64))
  raise "#{logical_name} writer segment/mark counts differ" unless segment_sizes.size == rows.size
  data = File.read(stream_path(part, logical_name)).to_slice
  offsets = [0_u64]
  offset = 0_i64
  while offset < data.size.to_i64
    frame = CrystalClick::CompressedBlock.decode_frame(data, offset)
    raise "#{logical_name} writer compression frame did not advance" if frame.end_offset <= offset
    offset = frame.end_offset
    offsets << offset.to_u64
  end
  raise "#{logical_name} writer stream has trailing compressed bytes" unless offset == data.size.to_i64

  result = Array(Tuple(UInt64, UInt64, UInt64)).new
  frame_index = 0
  compressed_offset = 0_u64
  segment_sizes.each_with_index do |size, index|
    result << {compressed_offset, 0_u64, rows[index]}
    if size > 0
      frame_index += 1
      raise "#{logical_name} writer has fewer frames than data marks" if frame_index >= offsets.size
      compressed_offset = offsets[frame_index]
    end
  end
  raise "#{logical_name} writer frame count differs from data marks" unless frame_index == offsets.size - 1
  result << {compressed_offset, 0_u64, 0_u64}
  result
end

def assert_writer_shape(part : String, values : Array(String), keys : Array(UInt64)) : Nil
  streams = lowcard_streams(values, keys, false)
  assert_part_metadata(part, false)
  raise "Crystal writer LowCardinality .bin stream count differs" unless Dir.glob(File.join(part, "*.bin")).size == 3
  raise "Crystal writer LowCardinality .mrk2 stream count differs" unless Dir.glob(File.join(part, "*.mrk2")).size == 3
  raise "Crystal writer LowCardinality unexpectedly uses .cmrk2" unless Dir.glob(File.join(part, "*.cmrk2")).empty?

  segments = {"pk" => LC_ROW_COUNTS.map { |count| count * 8_u64 }, "payload" => [] of UInt64}
  payload = IO::Memory.new
  dictionary_keys = unique_strings(values, reserve_empty: true)
  mark_ranges(values).each_with_index do |(start, finish), mark_index|
    local = values[start, finish - start]
    segment = IO::Memory.new
    append_u64_le(segment, mark_index == 0 ? 0x500_u64 : 0x100_u64)
    append_u64_le(segment, local.size.to_u64)
    local.each { |value| segment.write_byte(dictionary_keys.index(value).not_nil!.to_u8) }
    segments["payload"] << segment.size.to_u64
    payload.write(segment.to_slice)
  end
  raise "Crystal writer LowCardinality index fixture mismatch" unless payload.to_slice.to_a == streams["payload"]

  streams.each do |name, expected|
    raise "Crystal writer LowCardinality #{name} decoded bytes differ" unless decoded_stream(part, name) == expected
    expected_marks = if name == "payload.dict"
                       LC_ROW_COUNTS.map { |count| {0_u64, 8_u64, count} }.tap do |marks|
                         marks << {File.size(stream_path(part, name)).to_u64, 0_u64, 0_u64}
                       end
                     else
                       writer_mark_entries(part, name, segments[name], LC_ROW_COUNTS)
                     end
    actual_marks = mark_entries(part, name)
    raise "Crystal writer LowCardinality #{name} marks differ: #{actual_marks.inspect}" unless actual_marks == expected_marks
  end
end

def assert_same_size_corruption(binary : String, root : String, source_part : String, logical_name : String) : Nil
  label = logical_name.gsub('.', '_')
  store = File.join(root, "corruption-#{label}-store")
  table = "lc_corruption_#{label}"
  part_name, attached_path = attach_part(binary, store, table, source_part)
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
    raise "#{table}: corruption changed stream size" unless File.size(path) == original_size
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
  puts "PASS Crystal writer same-size #{logical_name} corruption detected and restored"
end

def stock_case(binary : String, root : String, label : String, no_global : Bool, values : Array(String)) : String
  store = File.join(root, "stock-#{label}-store")
  table = "stock_lc_#{label}"
  create_table(binary, store, table, no_global)
  run_clickhouse_input(binary, store, "INSERT INTO default.#{table} FORMAT RowBinary", IO::Memory.new(rowbinary_rows(LC_KEYS, values)), no_global)

  name = active_part_name(binary, store, table, no_global)
  part = active_part_path(binary, store, table, no_global)
  assert_check_table(binary, store, table, name, no_global)
  assert_rowbinary(binary, store, table, rowbinary_rows(LC_KEYS, values), rowbinary_range(LC_KEYS, values), no_global)

  stock_copy = File.join(root, "stock-#{label}-part", "all_1_1_0")
  FileUtils.mkdir_p(File.dirname(stock_copy))
  FileUtils.cp_r(part, stock_copy)
  assert_stock_shape(stock_copy, values, no_global)
  assert_crystal_reader(stock_copy, values, LC_KEYS)
  puts "PASS pinned ClickHouse stock LowCardinality(String) #{label}: exact streams/marks, Crystal full/key range, RowBinary, CHECK TABLE"
  stock_copy
end

binary = ENV.fetch("CLICKHOUSE_BIN")
root = ENV.fetch("TMP_ROOT")
shared_root = File.join(root, "stock-shared-global")
no_global_root = File.join(root, "stock-no-global")
writer_root = File.join(root, "crystal-writer")
Dir.mkdir(shared_root)
Dir.mkdir(no_global_root)
Dir.mkdir(writer_root)

stock_case(binary, shared_root, "shared", false, LC_VALUES)
stock_case(binary, no_global_root, "no_global", true, LC_VALUES)

writer_part = File.join(writer_root, "all_1_1_0")
CrystalClick::WidePartWriter.write_uint64_low_cardinality_string_pair(
  writer_part,
  "pk",
  LC_KEYS.to_unsafe.to_slice(LC_KEYS.size),
  "payload",
  LC_WRITER_VALUES.to_unsafe.to_slice(LC_WRITER_VALUES.size),
  rows_per_mark: LC_ROWS_PER_MARK.to_i32
)
assert_writer_shape(writer_part, LC_WRITER_VALUES, LC_KEYS)
assert_crystal_reader(writer_part, LC_WRITER_VALUES, LC_KEYS)

writer_store = File.join(writer_root, "stock-writer-store")
writer_table = "crystal_writer_lc"
writer_name, writer_attached_part = attach_part(binary, writer_store, writer_table, writer_part)
assert_check_table(binary, writer_store, writer_table, writer_name)
assert_rowbinary(
  binary,
  writer_store,
  writer_table,
  rowbinary_rows(LC_KEYS, LC_WRITER_VALUES),
  rowbinary_range(LC_KEYS, LC_WRITER_VALUES)
)
assert_same_size_corruption(binary, writer_root, writer_part, "payload.dict")
assert_same_size_corruption(binary, writer_root, writer_part, "payload")
raise "Crystal writer attached part path is missing" if writer_attached_part.empty?
puts "PASS Crystal LowCardinality(String) writer: reserved empty ID 0 with all-nonempty values, stock ATTACH/CHECK, full/range RowBinary"
puts "PASS pinned ClickHouse stock/Crystal LowCardinality(String) bidirectional oracle"
CRYSTAL
