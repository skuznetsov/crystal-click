require "file_utils"
require "../src/crystal_click"

W78_KEYS        = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64, 8_u64]
W78_MARK_ROWS   = [2_u64, 2_u64, 2_u64, 2_u64, 0_u64]
W78_MARK_STARTS = [0, 2, 4, 6, 8]
W78_ALL_ROWS    = [0_i32, 1_i32, 2_i32, 3_i32, 4_i32, 5_i32, 6_i32, 7_i32]
W78_LATER_ROWS  = [4_i32, 5_i32]

private def w78_clickhouse(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse query failed (#{status.exit_code}): #{query}" unless status.success?
  output.to_s
end

private def w78_clickhouse_input(binary : String, store : String, query : String, input : IO) : String
  output = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], input: input, output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse RowBinary insert failed (#{status.exit_code}): #{query}" unless status.success?
  output.to_s
end

private def w78_create_table(binary : String, store : String, table : String, type_name : String) : Nil
  w78_clickhouse(binary, store, <<-SQL)
  CREATE TABLE default.#{table} (`pk` UInt64, `payload` #{type_name})
  ENGINE = MergeTree ORDER BY pk
  SETTINGS index_granularity = 2, index_granularity_bytes = 10485760,
    enable_mixed_granularity_parts = 1, min_rows_for_wide_part = 0,
    min_bytes_for_wide_part = 0, ratio_of_defaults_for_sparse_serialization = 1.0,
    compress_marks = 0, min_compress_block_size = 0, max_compress_block_size = 4096,
    write_final_mark = 1, default_compression_codec = 'LZ4'
  SQL
  nil
end

private def w78_check_table(binary : String, store : String, table : String) : Nil
  result = w78_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "#{table}: CHECK TABLE failed: #{result.inspect}" unless result == "all_1_1_0\t1"
  nil
end

private def w78_u64(io : IO, value : UInt64) : Nil
  io.write_bytes(value, IO::ByteFormat::LittleEndian)
end

private def w78_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w78_key(io : IO, key : K) : Nil forall K
  {% if K == String %}
    w78_varuint(io, key.bytesize.to_u64)
    io.write(key.to_slice)
  {% elsif K == UInt64 %}
    w78_u64(io, key)
  {% else %}
    {% raise "unsupported W78 Map key type" %}
  {% end %}
end

private def w78_number(io : IO, value : T) : Nil forall T
  {% if T == Float32 %}
    io.write_bytes(value.unsafe_as(UInt32), IO::ByteFormat::LittleEndian)
  {% elsif T == Float64 %}
    io.write_bytes(value.unsafe_as(UInt64), IO::ByteFormat::LittleEndian)
  {% elsif T == UInt8 || T == UInt16 || T == UInt32 || T == UInt64 || T == Int8 || T == Int16 || T == Int32 || T == Int64 %}
    io.write_bytes(value, IO::ByteFormat::LittleEndian)
  {% else %}
    {% raise "unsupported W78 primitive numeric type" %}
  {% end %}
end

private def w78_rowbinary_map(io : IO, entries : Array(Tuple(K, Array(T)))) : Nil forall K, T
  w78_varuint(io, entries.size.to_u64)
  entries.each do |key, values|
    w78_key(io, key)
    w78_varuint(io, values.size.to_u64)
    values.each { |value| w78_number(io, value) }
  end
end

private def w78_rowbinary(
  keys : Array(UInt64),
  rows : Array(Array(Tuple(K, Array(T)))),
  indexes : Array(Int32),
) : String forall K, T
  raise "W78 primary-key and Map row counts differ" unless keys.size == rows.size
  io = IO::Memory.new
  indexes.each do |index|
    w78_u64(io, keys[index])
    w78_rowbinary_map(io, rows[index])
  end
  io.to_s
end

private def w78_assert_bytes(actual : String, expected : String, label : String) : Nil
  return if actual.to_slice == expected.to_slice
  common = Math.min(actual.bytesize, expected.bytesize)
  offset = 0
  while offset < common && actual.to_slice[offset] == expected.to_slice[offset]
    offset += 1
  end
  first = Math.max(0, offset - 8)
  last = Math.min(common, offset + 16)
  got = actual.to_slice[first, last - first].hexstring
  wanted = expected.to_slice[first, last - first].hexstring
  raise "#{label}: RowBinary differs at byte #{offset} (#{actual.bytesize} bytes / #{got}; expected #{expected.bytesize} bytes / #{wanted})"
end

private def w78_number_equal?(expected : T, actual : T) : Bool forall T
  {% if T == Float32 %}
    expected.unsafe_as(UInt32) == actual.unsafe_as(UInt32)
  {% elsif T == Float64 %}
    expected.unsafe_as(UInt64) == actual.unsafe_as(UInt64)
  {% else %}
    expected == actual
  {% end %}
end

private def w78_rows_equal?(
  expected : Array(Array(Tuple(K, Array(T)))),
  actual : Array(Array(Tuple(K, Array(T)))),
) : Bool forall K, T
  return false unless expected.size == actual.size
  expected.each_with_index do |row, row_index|
    observed_row = actual[row_index]?
    return false unless observed_row && row.size == observed_row.size
    row.each_with_index do |entry, entry_index|
      observed = observed_row[entry_index]?
      return false unless observed && entry[0] == observed[0] && entry[1].size == observed[1].size
      entry[1].each_with_index do |value, value_index|
        return false unless w78_number_equal?(value, observed[1][value_index])
      end
    end
  end
  true
end

private def w78_number_bytes(values : Array(T)) : Array(UInt8) forall T
  io = IO::Memory.new
  values.each { |value| w78_number(io, value) }
  io.to_slice.to_a
end

private def w78_raw_key_streams(column : String, rows : Array(Array(Tuple(String, Array(T))))) : Hash(String, Array(UInt8)) forall T
  keys = rows.flat_map { |row| row.map(&.[0]) }
  sizes = IO::Memory.new
  keys.each { |key| w78_u64(sizes, key.bytesize.to_u64) }
  {
    "#{column}%2Ekeys.size" => sizes.to_slice.to_a,
    "#{column}%2Ekeys"      => keys.flat_map(&.to_slice.to_a),
  }
end

private def w78_raw_key_streams(column : String, rows : Array(Array(Tuple(UInt64, Array(T))))) : Hash(String, Array(UInt8)) forall T
  io = IO::Memory.new
  rows.each { |row| row.each { |key, _values| w78_u64(io, key) } }
  {"#{column}%2Ekeys" => io.to_slice.to_a}
end

private def w78_expected_streams(rows : Array(Array(Tuple(K, Array(T))))) : Hash(String, Array(UInt8)) forall K, T
  map_sizes = IO::Memory.new
  nested_sizes = IO::Memory.new
  values = IO::Memory.new
  rows.each { |row| w78_u64(map_sizes, row.size.to_u64) }
  rows.each do |row|
    row.each do |_key, elements|
      w78_u64(nested_sizes, elements.size.to_u64)
      elements.each { |element| w78_number(values, element) }
    end
  end
  streams = {
    "payload.size0"          => map_sizes.to_slice.to_a,
    "payload%2Evalues.size1" => nested_sizes.to_slice.to_a,
    "payload%2Evalues"       => values.to_slice.to_a,
  }
  w78_raw_key_streams("payload", rows).each { |name, raw| streams[name] = raw }
  streams
end

private def w78_raw_stream(part : String, stream : String) : Array(UInt8)
  encoded = File.read(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
  encoded.empty? ? [] of UInt8 : CrystalClick::CompressedBlock.decode_all(encoded).to_a
end

private def w78_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

private def w78_marks(part : String, stream : String) : Array(Tuple(UInt64, UInt64, UInt64))
  data = File.read(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")).to_slice
  raise "#{part} #{stream}: malformed .mrk2" unless data.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(Tuple(UInt64, UInt64, UInt64)).new(data.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE
    {w78_read_u64(data, offset), w78_read_u64(data, offset + 8), w78_read_u64(data, offset + 16)}
  end
end

# Each tuple stores compressed start/end followed by absolute raw start/end.
private def w78_frames(part : String, stream : String) : Array(Tuple(UInt64, UInt64, UInt64, UInt64))
  encoded = File.read(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
  raise "#{part} #{stream}: compressed stream is empty" if encoded.empty?
  frames = [] of Tuple(UInt64, UInt64, UInt64, UInt64)
  compressed_offset = 0_i64
  raw_offset = 0_u64
  while compressed_offset < encoded.size.to_i64
    frame = CrystalClick::CompressedBlock.decode_frame(encoded, compressed_offset)
    raw_end = raw_offset + frame.output.size.to_u64
    frames << {compressed_offset.to_u64, frame.end_offset.to_u64, raw_offset, raw_end}
    raw_offset = raw_end
    raise "#{part} #{stream}: compressed frame did not advance" if frame.end_offset <= compressed_offset
    compressed_offset = frame.end_offset
  end
  raise "#{part} #{stream}: compressed framing has trailing bytes" unless compressed_offset == encoded.size.to_i64
  frames
end

private def w78_mark_raw_offset(
  part : String,
  stream : String,
  record : Tuple(UInt64, UInt64, UInt64),
  frames : Array(Tuple(UInt64, UInt64, UInt64, UInt64)),
) : UInt64
  encoded_size = File.size(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_u64
  return frames.last[3] if record[0] == encoded_size && record[1] == 0_u64

  frame = frames.find { |candidate| candidate[0] == record[0] } || raise "#{part} #{stream}: mark does not point to a compressed-frame boundary"
  frame_raw_size = frame[3] - frame[2]
  raise "#{part} #{stream}: mark raw offset exceeds its compressed frame" if record[1] > frame_raw_size
  frame[2] + record[1]
end

private def w78_expected_raw_offset(
  stream : String,
  rows : Array(Array(Tuple(K, Array(T)))),
  start_row : Int32,
  width : Int32,
) : UInt64 forall K, T
  return start_row.to_u64 * 8_u64 if stream == "pk" || stream == "payload.size0"

  entry_count = 0_u64
  key_bytes = 0_u64
  value_bytes = 0_u64
  start_row.times do |row_index|
    rows[row_index].each do |key, elements|
      entry_count += 1_u64
      {% if K == String %}
        key_bytes += key.bytesize.to_u64
      {% end %}
      value_bytes += elements.size.to_u64 * width.to_u64
    end
  end

  case stream
  when "payload%2Ekeys.size", "payload%2Evalues.size1"
    entry_count * 8_u64
  when "payload%2Ekeys"
    {% if K == String %}
      key_bytes
    {% else %}
      entry_count * 8_u64
    {% end %}
  when "payload%2Evalues"
    value_bytes
  else
    raise "unexpected W78 stream #{stream}"
  end
end

private def w78_large_array_interval(
  rows : Array(Array(Tuple(K, Array(T)))),
  width : Int32,
) : Tuple(UInt64, UInt64)? forall K, T
  raw_offset = 0_u64
  rows.each do |row|
    row.each do |_key, elements|
      raw_size = elements.size.to_u64 * width.to_u64
      return {raw_offset, raw_offset + raw_size} if raw_size > 4_096_u64
      raw_offset += raw_size
    end
  end
  nil
end

private def w78_assert_large_array_crosses_frame(
  part : String,
  rows : Array(Array(Tuple(K, Array(T)))),
  width : Int32,
) : Nil forall K, T
  interval = w78_large_array_interval(rows, width) || raise "#{part}: large Array fixture is missing"
  frames = w78_frames(part, "payload%2Evalues")
  crossed = false
  frames.each_with_index do |frame, index|
    next if index == 0
    boundary = frame[2]
    if interval[0] < boundary && boundary < interval[1]
      crossed = true
      break
    end
  end
  raise "#{part}: >4096-byte Array leaf does not cross a compressed block boundary" unless crossed
  nil
end

private def w78_assert_stream(
  part : String,
  stream : String,
  expected_raw : Array(UInt8),
  rows : Array(Array(Tuple(K, Array(T)))),
  width : Int32,
) : Nil forall K, T
  observed_raw = w78_raw_stream(part, stream)
  raise "#{part} #{stream}: raw stream differs (#{observed_raw.size} bytes != #{expected_raw.size})" unless observed_raw == expected_raw
  records = w78_marks(part, stream)
  raise "#{part} #{stream}: expected five marks, got #{records.size}" unless records.size == W78_MARK_ROWS.size
  raise "#{part} #{stream}: row counts differ: #{records.map(&.[2])}" unless records.map(&.[2]) == W78_MARK_ROWS

  frames = w78_frames(part, stream)
  records.each_with_index do |record, index|
    expected = w78_expected_raw_offset(stream, rows, W78_MARK_STARTS[index], width)
    actual = w78_mark_raw_offset(part, stream, record, frames)
    raise "#{part} #{stream}: mark #{index} points to raw offset #{actual}, expected #{expected}" unless actual == expected
  end

  child_stream = stream == "payload%2Ekeys.size" || stream == "payload%2Ekeys" ||
                 stream == "payload%2Evalues.size1" || stream == "payload%2Evalues"
  if child_stream
    final_start = w78_mark_raw_offset(part, stream, records[3], frames)
    raise "#{part} #{stream}: final empty Map mark is not at nonzero child EOF" unless final_start == expected_raw.size.to_u64 && final_start > 0_u64
    middle_start = w78_mark_raw_offset(part, stream, records[1], frames)
    middle_end = w78_mark_raw_offset(part, stream, records[2], frames)
    raise "#{part} #{stream}: empty middle Map mark advances child data" unless middle_start == middle_end
  end
  nil
end

private def w78_assert_inventory(
  part : String,
  type_name : String,
  rows : Array(Array(Tuple(K, Array(T)))),
  stock : Bool,
  large_case : Bool,
  width : Int32,
) : Nil forall K, T
  expected_columns = "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` #{type_name}\n"
  raise "#{part}: columns.txt differs" unless File.read(File.join(part, "columns.txt")) == expected_columns

  columns = if stock
              "[]"
            else
              default_keys = W78_KEYS.count(&.zero?)
              %([{"kind":"Default","name":"pk","num_defaults":#{default_keys},"num_rows":#{W78_KEYS.size}}])
            end
  expected_serialization = %({"columns":#{columns},"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
  observed_serialization = File.read(File.join(part, "serialization.json")).strip
  raise "W78 serialization.json differs" unless observed_serialization == expected_serialization

  stream_names = {% if K == String %}
                   ["payload.size0", "payload%2Ekeys.size", "payload%2Ekeys", "payload%2Evalues.size1", "payload%2Evalues"]
                 {% else %}
                   ["payload.size0", "payload%2Ekeys", "payload%2Evalues.size1", "payload%2Evalues"]
                 {% end %}
  expected_substreams = "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n" +
                        "#{stream_names.size} substreams for column `payload`:\n" + stream_names.map { |stream| "\t#{stream}\n" }.join
  raise "#{part}: columns_substreams.txt differs" unless File.read(File.join(part, "columns_substreams.txt")) == expected_substreams

  expected_streams = w78_expected_streams(rows)
  w78_assert_stream(part, "pk", w78_number_bytes(W78_KEYS), rows, 8)
  stream_names.each do |stream|
    w78_assert_stream(part, stream, expected_streams[stream], rows, width)
  end

  metadata_files = [
    "checksums.txt", "columns.txt", "columns_substreams.txt", "count.txt",
    "default_compression_codec.txt", "metadata_version.txt", stock ? "primary.cidx" : "primary.idx",
    "serialization.json",
  ]
  expected_files = metadata_files + (stream_names + ["pk"]).flat_map do |stream|
    base = CrystalClick::StreamName.hash(stream)
    ["#{base}.bin", "#{base}.mrk2"]
  end
  actual_files = Dir.children(part).sort
  raise "#{part}: part file inventory differs" unless actual_files == expected_files.sort
  raise "#{part}: count.txt differs" unless File.read(File.join(part, "count.txt")) == W78_KEYS.size.to_s
  raise "#{part}: metadata_version.txt differs" unless File.read(File.join(part, "metadata_version.txt")) == "0"
  raise "#{part}: compression codec metadata differs" unless File.read(File.join(part, "default_compression_codec.txt")) == "CODEC(LZ4)"

  checksums = CrystalClick::PartChecksums.open(part)
  expected_checksum_files = expected_files - [
    "checksums.txt", "columns.txt", "columns_substreams.txt",
    "default_compression_codec.txt", "metadata_version.txt",
  ]
  unless checksums.entries.keys.sort == expected_checksum_files.sort
    missing = expected_checksum_files - checksums.entries.keys
    extra = checksums.entries.keys - expected_checksum_files
    raise "W78 checksum inventory differs (missing=#{missing.sort}, extra=#{extra.sort}, observed=#{checksums.entries.keys.sort})"
  end
  checksums.entries.each_key { |name| checksums.validate_selected_entries(part, name) }
  # ClickHouse's 4096-byte producer block can split one large Array leaf.
  # The Crystal writer intentionally emits one frame per mark, so the reverse
  # direction validates the same >4096-byte payload and exact frame/mark
  # layout without requiring an intra-mark split.
  w78_assert_large_array_crosses_frame(part, rows, width) if stock && large_case
  nil
end

{% if flag?(:w78_reader) %}
  private def w78_assert_reader_values(
    part : String,
    rows : Array(Array(Tuple(K, Array(T)))),
    observed : Array(Array(Tuple(K, Array(T)))),
    middle : Array(Array(Tuple(K, Array(T)))),
    later : Array(Array(Tuple(K, Array(T)))),
    final_empty : Array(Array(Tuple(K, Array(T)))),
    spanning : Array(Array(Tuple(K, Array(T)))),
  ) : Nil forall K, T
    raise "#{part}: full typed Map(Array(numeric)) read differs" unless w78_rows_equal?(rows, observed)
    raise "#{part}: empty middle mark differs" unless w78_rows_equal?(rows[2, 2], middle)
    raise "#{part}: later selected mark differs" unless w78_rows_equal?(rows[4, 2], later)
    raise "#{part}: final all-empty mark at nonzero EOF differs" unless w78_rows_equal?(rows[6, 2], final_empty)
    raise "#{part}: selected range spanning empty and later marks differs" unless w78_rows_equal?(rows[2, 4], spanning)
    nil
  end

  private def w78_assert_reader(part : String, rows : Array(Array(Tuple(UInt64, Array(T)))), type : T.class) : Nil forall T
    reader = CrystalClick::WidePart.open_typed(part, "payload")
    observed = reader.read_map_uint64_array_numeric_mark_range("payload", 0, reader.mark_count, type)
    middle = reader.read_map_uint64_array_numeric_mark_range("payload", 1, 1, type)
    later = reader.read_map_uint64_array_numeric_mark_range("payload", 2, 1, type)
    final_empty = reader.read_map_uint64_array_numeric_mark_range("payload", 3, 1, type)
    spanning = reader.read_map_uint64_array_numeric_mark_range("payload", 1, 2, type)
    w78_assert_reader_values(part, rows, observed, middle, later, final_empty, spanning)
  end

  private def w78_assert_reader(part : String, rows : Array(Array(Tuple(String, Array(T)))), type : T.class) : Nil forall T
    reader = CrystalClick::WidePart.open_typed(part, "payload")
    observed = reader.read_map_string_array_numeric_mark_range("payload", 0, reader.mark_count, type)
    middle = reader.read_map_string_array_numeric_mark_range("payload", 1, 1, type)
    later = reader.read_map_string_array_numeric_mark_range("payload", 2, 1, type)
    final_empty = reader.read_map_string_array_numeric_mark_range("payload", 3, 1, type)
    spanning = reader.read_map_string_array_numeric_mark_range("payload", 1, 2, type)
    w78_assert_reader_values(part, rows, observed, middle, later, final_empty, spanning)
  end
{% end %}

private def w78_stock_part(binary : String, store : String, root : String, table : String) : String
  source = w78_clickhouse(binary, store,
    "SELECT path FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw").strip
  raise "#{table}: stock part missing" unless Dir.exists?(source)
  destination = File.join(root, "stock-#{table}")
  FileUtils.cp_r(source, destination)
  destination
end

private def w78_assert_columns(binary : String, store : String, table : String, type_name : String) : Nil
  actual = w78_clickhouse(binary, store,
    "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw")
  expected = "pk UInt64\npayload #{type_name}\n"
  raise "#{table}: exact system.columns mismatch" unless actual == expected
  create = w78_clickhouse(binary, store, "SHOW CREATE TABLE default.#{table} FORMAT TSVRaw").gsub(/\s+/, "")
  raise "#{table}: SHOW CREATE type mismatch" unless create.includes?(type_name.gsub(/\s+/, ""))
  nil
end

private def w78_assert_clickhouse_rows(
  binary : String,
  store : String,
  table : String,
  rows : Array(Array(Tuple(K, Array(T)))),
) : Nil forall K, T
  full = w78_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  w78_assert_bytes(full, w78_rowbinary(W78_KEYS, rows, W78_ALL_ROWS), "#{table} full")
  selected = w78_clickhouse(binary, store,
    "SELECT pk, payload FROM default.#{table} WHERE pk >= 5 AND pk <= 6 ORDER BY pk FORMAT RowBinary")
  w78_assert_bytes(selected, w78_rowbinary(W78_KEYS, rows, W78_LATER_ROWS), "#{table} later selected rows")
  nil
end

private def w78_attach(binary : String, store : String, table : String, part : String, type_name : String) : Nil
  w78_create_table(binary, store, table, type_name)
  data_path = w78_clickhouse(binary, store,
    "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw").strip
  raise "#{table}: ClickHouse data path missing" if data_path.empty? || data_path.includes?('\n')
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  w78_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  w78_check_table(binary, store, table)
  nil
end

private def w78_values(
  first_key : K,
  second_key : K,
  third_key : K,
  later_key : K,
  maximum : T,
  minimum : T,
  later : T,
  large_case : Bool,
) : Array(Array(Tuple(K, Array(T)))) forall K, T
  large_values = if large_case
                   Array(T).new(5_000) { |index| index.even? ? later : minimum }
                 else
                   [] of T
                 end
  row4_values = [minimum, maximum] of T
  row4_values.concat(large_values)

  first_values = [] of T
  later_values = [] of T
  {% if T == Float32 %}
    negative_zero = 0x80000000_u32.unsafe_as(Float32)
    positive_zero = 0_u32.unsafe_as(Float32)
    first_values = [negative_zero, positive_zero, maximum] of T
    later_values = [later] of T
  {% elsif T == Float64 %}
    negative_zero = 0x8000000000000000_u64.unsafe_as(Float64)
    positive_zero = 0_u64.unsafe_as(Float64)
    first_values = [negative_zero, positive_zero, maximum] of T
    later_values = [later] of T
  {% else %}
    first_values = [maximum, minimum] of T
    later_values = [later, minimum] of T
  {% end %}

  [
    [] of Tuple(K, Array(T)),
    [{first_key, [] of T}, {first_key, first_values}] of Tuple(K, Array(T)),
    [] of Tuple(K, Array(T)),
    [] of Tuple(K, Array(T)),
    [{second_key, row4_values}, {third_key, [] of T}] of Tuple(K, Array(T)),
    [{later_key, later_values}] of Tuple(K, Array(T)),
    [] of Tuple(K, Array(T)),
    [] of Tuple(K, Array(T)),
  ] of Array(Tuple(K, Array(T)))
end

private def w78_case(
  binary : String,
  store : String,
  root : String,
  label : String,
  value_type : String,
  first_key : K,
  second_key : K,
  third_key : K,
  later_key : K,
  maximum : T,
  minimum : T,
  later : T,
  type : T.class,
  large_case : Bool = false,
) : Nil forall K, T
  key_type = {% if K == String %}"String"{% else %}"UInt64"{% end %}
  type_name = "Map(#{key_type}, Array(#{value_type}))"
  rows = w78_values(first_key, second_key, third_key, later_key, maximum, minimum, later, large_case)
  indexes = (0...W78_KEYS.size).map(&.to_i32)

  raise "W78 fixture lost its empty middle mark" unless rows[2].empty? && rows[3].empty?
  raise "W78 fixture lost its final all-empty mark" unless rows[6].empty? && rows[7].empty?

  stock_table = "w78_stock_#{label}"
  w78_create_table(binary, store, stock_table, type_name)
  input = IO::Memory.new
  input.write(w78_rowbinary(W78_KEYS, rows, indexes).to_slice)
  input.rewind
  w78_clickhouse_input(binary, store, "INSERT INTO default.#{stock_table} FORMAT RowBinary", input)
  count = w78_clickhouse(binary, store, "SELECT count() FROM default.#{stock_table} FORMAT TSVRaw").strip
  raise "#{stock_table}: inserted row count differs" unless count == W78_KEYS.size.to_s
  w78_check_table(binary, store, stock_table)
  w78_assert_columns(binary, store, stock_table, type_name)
  w78_assert_clickhouse_rows(binary, store, stock_table, rows)

  stock_part = w78_stock_part(binary, store, root, stock_table)
  w78_assert_inventory(stock_part, type_name, rows, true, large_case, sizeof(T))
  {% if flag?(:w78_reader) %}
    w78_assert_reader(stock_part, rows, T)
    puts "PASS stock→Crystal #{type_name}: exact streams, marks, checksums, full/later reads"
  {% else %}
    puts "PASS pinned stock producer #{type_name}: exact streams, marks, checksums, full/later RowBinary"
  {% end %}

  {% if flag?(:w78_writer) %}
    crystal_part = File.join(root, "crystal-#{label}")
    {% if K == String %}
      CrystalClick::WidePartWriter.write_uint64_map_string_array_numeric_pair(
        crystal_part, "pk", W78_KEYS.to_unsafe.to_slice(W78_KEYS.size), "payload",
        rows.to_unsafe.to_slice(rows.size), rows_per_mark: 2
      )
    {% else %}
      CrystalClick::WidePartWriter.write_uint64_map_uint64_array_numeric_pair(
        crystal_part, "pk", W78_KEYS.to_unsafe.to_slice(W78_KEYS.size), "payload",
        rows.to_unsafe.to_slice(rows.size), rows_per_mark: 2
      )
    {% end %}
    w78_assert_inventory(crystal_part, type_name, rows, false, large_case, sizeof(T))
    w78_assert_reader(crystal_part, rows, T)
    crystal_table = "w78_crystal_#{label}"
    w78_attach(binary, store, crystal_table, crystal_part, type_name)
    w78_assert_columns(binary, store, crystal_table, type_name)
    w78_assert_clickhouse_rows(binary, store, crystal_table, rows)
    puts "PASS Crystal→stock #{type_name}: ATTACH/CHECK, checksums, full/later RowBinary"
  {% end %}
  nil
end

binary = ENV.fetch("CLICKHOUSE_BIN")
store = ENV.fetch("CLICKHOUSE_STORE")
root = ENV.fetch("ORACLE_ROOT")

# Existing W73 controls remain in the complete 20-declaration matrix.
w78_case(binary, store, root, "uint64_u8", "UInt8", 0_u64, UInt64::MAX, 42_u64, 7_u64, UInt8::MAX, UInt8::MIN, 17_u8, UInt8)
w78_case(binary, store, root, "string_u8", "UInt8", "dup", "", "binary\u0000key", "tail", UInt8::MAX, UInt8::MIN, 17_u8, UInt8)
w78_case(binary, store, root, "uint64_u16", "UInt16", 0_u64, UInt64::MAX, 42_u64, 7_u64, UInt16::MAX, UInt16::MIN, 17_u16, UInt16)
w78_case(binary, store, root, "string_u16", "UInt16", "dup", "", "binary\u0000key", "tail", UInt16::MAX, UInt16::MIN, 17_u16, UInt16)
w78_case(binary, store, root, "uint64_u32", "UInt32", 0_u64, UInt64::MAX, 42_u64, 7_u64, UInt32::MAX, UInt32::MIN, 17_u32, UInt32)
w78_case(binary, store, root, "string_u32", "UInt32", "dup", "", "binary\u0000key", "tail", UInt32::MAX, UInt32::MIN, 17_u32, UInt32)
w78_case(binary, store, root, "uint64_u64", "UInt64", 0_u64, UInt64::MAX, 42_u64, 7_u64, UInt64::MAX, UInt64::MIN, 17_u64, UInt64)
w78_case(binary, store, root, "string_u64", "UInt64", "dup", "", "binary\u0000key", "tail", UInt64::MAX, UInt64::MIN, 17_u64, UInt64)
w78_case(binary, store, root, "uint64_i8", "Int8", 0_u64, UInt64::MAX, 42_u64, 7_u64, Int8::MAX, Int8::MIN, -1_i8, Int8, true)
w78_case(binary, store, root, "string_i8", "Int8", "dup", "", "binary\u0000key", "tail", Int8::MAX, Int8::MIN, -1_i8, Int8)
w78_case(binary, store, root, "uint64_i16", "Int16", 0_u64, UInt64::MAX, 42_u64, 7_u64, Int16::MAX, Int16::MIN, -1_i16, Int16)
w78_case(binary, store, root, "string_i16", "Int16", "dup", "", "binary\u0000key", "tail", Int16::MAX, Int16::MIN, -1_i16, Int16)
w78_case(binary, store, root, "uint64_i32", "Int32", 0_u64, UInt64::MAX, 42_u64, 7_u64, Int32::MAX, Int32::MIN, -1_i32, Int32)
w78_case(binary, store, root, "string_i32", "Int32", "dup", "", "binary\u0000key", "tail", Int32::MAX, Int32::MIN, -1_i32, Int32)
w78_case(binary, store, root, "uint64_i64", "Int64", 0_u64, UInt64::MAX, 42_u64, 7_u64, Int64::MAX, Int64::MIN, -1_i64, Int64)
w78_case(binary, store, root, "string_i64", "Int64", "dup", "", "binary\u0000key", "tail", Int64::MAX, Int64::MIN, -1_i64, Int64)
w78_case(binary, store, root, "uint64_f32", "Float32", 0_u64, UInt64::MAX, 42_u64, 7_u64, 0x7f7fffff_u32.unsafe_as(Float32), 0xff7fffff_u32.unsafe_as(Float32), 0x7fc01234_u32.unsafe_as(Float32), Float32)
w78_case(binary, store, root, "string_f32", "Float32", "dup", "", "binary\u0000key", "tail", 0x7f7fffff_u32.unsafe_as(Float32), 0xff7fffff_u32.unsafe_as(Float32), 0x7fc01234_u32.unsafe_as(Float32), Float32)
w78_case(binary, store, root, "uint64_f64", "Float64", 0_u64, UInt64::MAX, 42_u64, 7_u64, 0x7fefffffffffffff_u64.unsafe_as(Float64), 0xffefffffffffffff_u64.unsafe_as(Float64), 0x7ff8000000001234_u64.unsafe_as(Float64), Float64)
w78_case(binary, store, root, "string_f64", "Float64", "dup", "", "binary\u0000key", "tail", 0x7fefffffffffffff_u64.unsafe_as(Float64), 0xffefffffffffffff_u64.unsafe_as(Float64), 0x7ff8000000001234_u64.unsafe_as(Float64), Float64, true)
