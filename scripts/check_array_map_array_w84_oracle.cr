require "file_utils"
require "../src/crystal_click"

W84_KEYS          = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
W84_RANGE_INDICES = [1_i32, 2_i32, 3_i32]
W84_MARK_ROWS     = [2_u64, 2_u64, 1_u64, 0_u64]
W84_BINARY_KEY    = String.new(Bytes[0x41_u8, 0x00_u8, 0xff_u8])
W84_BINARY_VALUE  = String.new(Bytes[0x00_u8, 0xff_u8, 0x80_u8])

private def w84_clickhouse(binary : String, store : String, query : String, input : IO = IO::Memory.new) : String
  output = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], input: input, output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse query failed (#{status.exit_code}): #{query}" unless status.success?
  output.to_s
end

private def w84_u64(io : IO, value : UInt64) : Nil
  io.write_bytes(value, IO::ByteFormat::LittleEndian)
end

private def w84_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w84_string(io : IO, value : String) : Nil
  w84_varuint(io, value.bytesize.to_u64)
  io.write(value.to_slice)
end

private def w84_key(io : IO, key : K) : Nil forall K
  {% if K == UInt64 %}
    w84_u64(io, key)
  {% elsif K == String %}
    w84_string(io, key)
  {% else %}
    {% raise "unsupported W84 Map key type" %}
  {% end %}
end

private def w84_leaf(io : IO, value : V) : Nil forall V
  {% if V == UInt64 %}
    w84_u64(io, value)
  {% elsif V == String %}
    w84_string(io, value)
  {% else %}
    {% raise "unsupported W84 nested Array leaf type" %}
  {% end %}
end

private def w84_rowbinary(
  keys : Array(UInt64),
  rows : Array(Array(Array(Tuple(K, Array(V))))),
  indices : Array(Int32),
) : Bytes forall K, V
  raise "W84 primary-key and Array(Map) row counts differ" unless keys.size == rows.size
  io = IO::Memory.new
  indices.each do |index|
    w84_u64(io, keys[index])
    row_maps = rows[index]
    w84_varuint(io, row_maps.size.to_u64)
    row_maps.each do |entries|
      w84_varuint(io, entries.size.to_u64)
      entries.each do |key, values|
        w84_key(io, key)
        w84_varuint(io, values.size.to_u64)
        values.each { |value| w84_leaf(io, value) }
      end
    end
  end
  io.to_slice
end

private def w84_expected_streams(
  column : String,
  rows : Array(Array(Array(Tuple(K, Array(V))))),
) : Hash(String, Array(UInt8)) forall K, V
  size0 = IO::Memory.new
  size1 = IO::Memory.new
  key_sizes = IO::Memory.new
  key_data = IO::Memory.new
  size2 = IO::Memory.new
  value_sizes = IO::Memory.new
  value_data = IO::Memory.new
  rows.each do |row_maps|
    w84_u64(size0, row_maps.size.to_u64)
    row_maps.each do |entries|
      w84_u64(size1, entries.size.to_u64)
      entries.each do |key, values|
        {% if K == String %}
          w84_u64(key_sizes, key.bytesize.to_u64)
          key_data.write(key.to_slice)
        {% else %}
          w84_u64(key_data, key)
        {% end %}
        w84_u64(size2, values.size.to_u64)
        values.each do |value|
          {% if V == String %}
            w84_u64(value_sizes, value.bytesize.to_u64)
            value_data.write(value.to_slice)
          {% else %}
            w84_u64(value_data, value)
          {% end %}
        end
      end
    end
  end

  streams = {
    "#{column}.size0"          => size0.to_slice.to_a,
    "#{column}.size1"          => size1.to_slice.to_a,
    "#{column}%2Ekeys"         => key_data.to_slice.to_a,
    "#{column}%2Evalues.size2" => size2.to_slice.to_a,
    "#{column}%2Evalues"       => value_data.to_slice.to_a,
  }
  {% if K == String %}
    streams["#{column}%2Ekeys.size"] = key_sizes.to_slice.to_a
  {% end %}
  {% if V == String %}
    streams["#{column}%2Evalues.size"] = value_sizes.to_slice.to_a
  {% end %}
  streams
end

private def w84_stream_names(column : String, key_type : String, value_type : String) : Array(String)
  streams = ["#{column}.size0", "#{column}.size1"] of String
  streams << "#{column}%2Ekeys.size" if key_type == "String"
  streams << "#{column}%2Ekeys" << "#{column}%2Evalues.size2"
  streams << "#{column}%2Evalues.size" if value_type == "String"
  streams << "#{column}%2Evalues"
  streams
end

private def w84_raw_stream(part : String, stream : String) : Array(UInt8)
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")
  encoded = File.read(path).to_slice
  return [] of UInt8 if encoded.empty?
  CrystalClick::CompressedBlock.decode_all(encoded).to_a
end

private def w84_u64_at(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

private def w84_mark_records(part : String, stream : String) : Array(Tuple(UInt64, UInt64, UInt64))
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  bytes = File.read(path).to_slice
  raise "#{part} #{stream} mark file size differs: #{bytes.size}" unless bytes.size == W84_MARK_ROWS.size * CrystalClick::WidePart::MARK_SIZE
  Array(Tuple(UInt64, UInt64, UInt64)).new(W84_MARK_ROWS.size) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE
    {w84_u64_at(bytes, offset), w84_u64_at(bytes, offset + 8), w84_u64_at(bytes, offset + 16)}
  end
end

private def w84_fixture_mark_offsets : Hash(String, Array(UInt64))
  offsets = {} of String => Array(UInt64)
  row_offsets = [0_u64, 16_u64, 32_u64, 40_u64]
  map_offsets = [0_u64, 8_u64, 24_u64, 24_u64]
  entry_offsets = [0_u64, 16_u64, 32_u64, 32_u64]
  nested_value_offsets = [0_u64, 16_u64, 48_u64, 48_u64]
  string_value_offsets = [0_u64, 3_u64, 10_u64, 10_u64]

  offsets["pk"] = row_offsets
  {"p_uu", "p_us", "p_su", "p_ss"}.each do |column|
    offsets["#{column}.size0"] = row_offsets
    offsets["#{column}.size1"] = map_offsets
    offsets["#{column}%2Evalues.size2"] = entry_offsets
    offsets["#{column}%2Evalues"] = column == "p_us" || column == "p_ss" ? string_value_offsets : nested_value_offsets
    if column == "p_su" || column == "p_ss"
      offsets["#{column}%2Ekeys.size"] = entry_offsets
      offsets["#{column}%2Ekeys"] = [0_u64, 2_u64, 4_u64, 4_u64]
    else
      offsets["#{column}%2Ekeys"] = entry_offsets
    end
    if column == "p_us" || column == "p_ss"
      offsets["#{column}%2Evalues.size"] = nested_value_offsets
    end
  end
  offsets
end

private def w84_literal_frame_size(raw_size : Int) : UInt64
  return 0_u64 if raw_size == 0
  extension_size = raw_size < 15 ? 0 : ((raw_size - 15) // 255) + 1
  (26 + extension_size + raw_size).to_u64
end

private def w84_expected_writer_mark_offsets(
  streams : Array(String),
  rows : Array(Array(Array(Tuple(K, Array(V))))),
) : Hash(String, Array(UInt64)) forall K, V
  offsets = {} of String => Array(UInt64)
  (streams + ["pk"]).each do |stream|
    stream_offsets = [0_u64]
    compressed_offset = 0_u64
    start_row = 0
    while start_row < rows.size
      mark_rows = {2, rows.size - start_row}.min
      raw_size = if stream == "pk"
                   mark_rows * 8
                 else
                   mark_rows_data = rows[start_row, mark_rows]
                   w84_expected_streams("payload", mark_rows_data)[stream].size
                 end
      compressed_offset += w84_literal_frame_size(raw_size)
      stream_offsets << compressed_offset
      start_row += mark_rows
    end
    offsets[stream] = stream_offsets
  end
  offsets
end

private def w84_assert_layout(
  part : String,
  streams : Array(String),
  expected_raw : Hash(String, Array(UInt8)),
  stock : Bool,
  writer_mark_offsets : Hash(String, Array(UInt64))? = nil,
) : Nil
  (streams + ["pk"]).each do |stream|
    actual = w84_raw_stream(part, stream)
    expected = expected_raw[stream]
    raise "#{part} #{stream} raw bytes differ (expected=#{expected.size}, actual=#{actual.size})" unless actual == expected
    records = w84_mark_records(part, stream)
    raise "#{part} #{stream} mark row counts differ: #{records.inspect}" unless records.map(&.[2]) == W84_MARK_ROWS
    records.each_cons(2) do |pair|
      left, right = pair[0], pair[1]
      raise "#{part} #{stream} mark offsets are not monotonic" if right[0] < left[0] || (right[0] == left[0] && right[1] < left[1])
    end
    if stock
      raise "#{part} #{stream} terminal raw mark offset differs" unless records.last[1] == expected.size.to_u64
      if File.basename(part) == "stock-w84-matrix"
        fixture_offsets = w84_fixture_mark_offsets[stream]
        observed_offsets = records.map(&.[1])
        raise "#{part} #{stream} pinned stock mark coordinates differ: expected=#{fixture_offsets}, actual=#{records.map { |record| {record[0], record[1]} }}" unless observed_offsets == fixture_offsets && records.all? { |record| record[0] == 0_u64 }
      end
    else
      data_size = File.size(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_u64
      raise "#{part} #{stream} writer terminal mark differs" unless {records.last[0], records.last[1]} == {data_size, 0_u64}
      expected_offsets = writer_mark_offsets.try(&.[stream]) || raise "#{part} #{stream} expected writer mark offsets are missing"
      observed_offsets = records.map(&.[0])
      raise "#{part} #{stream} writer mark coordinates differ: expected=#{expected_offsets}, actual=#{records.inspect}" unless observed_offsets == expected_offsets && records.all? { |record| record[1] == 0_u64 }
    end
    if expected.empty? && stream != "pk"
      raise "#{part} #{stream} empty child marks are not at origin" unless records.all? { |record| {record[0], record[1]} == {0_u64, 0_u64} }
    end
    puts "#{File.basename(part)} #{stream} marks=#{records.inspect} raw_bytes=#{expected.size}"
  end
  nil
end

private def w84_assert_part(
  part : String,
  type_name : String,
  key_type : String,
  value_type : String,
  stock : Bool,
  expected_raw : Hash(String, Array(UInt8)),
  writer_mark_offsets : Hash(String, Array(UInt64))? = nil,
) : Nil
  streams = w84_stream_names("payload", key_type, value_type)
  full_type = "Array(Map(#{key_type}, Array(#{value_type})))"
  expected_columns = "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` #{full_type}\n"
  raise "#{part} columns differ" unless File.read(File.join(part, "columns.txt")) == expected_columns

  expected_substreams = "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n" +
                        "#{streams.size} substreams for column `payload`:\n" + streams.map { |stream| "\t#{stream}\n" }.join
  raise "#{part} substream inventory/order differs" unless File.read(File.join(part, "columns_substreams.txt")) == expected_substreams

  serialization = File.read(File.join(part, "serialization.json")).strip
  expected_serialization = %({"columns":[],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
  raise "#{part} serialization differs: #{serialization}" unless serialization == expected_serialization

  primary_name = stock ? "primary.cidx" : "primary.idx"
  expected_files = ["checksums.txt", "columns.txt", "columns_substreams.txt", "count.txt", "default_compression_codec.txt", "metadata_version.txt", primary_name, "serialization.json"]
  (streams + ["pk"]).each do |stream|
    base = CrystalClick::StreamName.hash(stream)
    expected_files << "#{base}.bin" << "#{base}.mrk2"
  end
  actual_files = Dir.children(part).sort
  raise "#{part} file inventory differs (missing=#{(expected_files - actual_files).sort}, extra=#{(actual_files - expected_files).sort})" unless actual_files == expected_files.sort
  raise "#{part} row count differs" unless File.read(File.join(part, "count.txt")) == W84_KEYS.size.to_s
  raise "#{part} metadata version differs" unless File.read(File.join(part, "metadata_version.txt")) == "0"
  raise "#{part} codec differs" unless File.read(File.join(part, "default_compression_codec.txt")) == "CODEC(LZ4)"

  checksums = CrystalClick::PartChecksums.open(part)
  checksum_files = expected_files - ["checksums.txt", "columns.txt", "columns_substreams.txt", "default_compression_codec.txt", "metadata_version.txt"]
  raise "#{part} checksum inventory differs" unless checksums.entries.keys.sort == checksum_files.sort
  checksums.entries.each_key { |name| checksums.validate_selected_entries(part, name) }
  streams.each do |stream|
    actual = w84_raw_stream(part, stream)
    raise "#{part} #{stream} raw bytes differ" unless actual == expected_raw[stream]
  end
  w84_assert_layout(part, streams, expected_raw, stock, writer_mark_offsets)
  nil
end

private def w84_read_mark(
  reader : CrystalClick::WidePart,
  first_mark : Int32,
  mark_count : Int32,
  rows : Array(Array(Array(Tuple(K, Array(V))))),
) : Array(Array(Array(Tuple(K, Array(V))))) forall K, V
  w84_read_column(reader, "payload", first_mark, mark_count, rows)
end

private def w84_read_column(
  reader : CrystalClick::WidePart,
  column : String,
  first_mark : Int32,
  mark_count : Int32,
  rows : Array(Array(Array(Tuple(K, Array(V))))),
) : Array(Array(Array(Tuple(K, Array(V))))) forall K, V
  {% if K == UInt64 %}
    {% if V == UInt64 %}
      reader.read_array_map_uint64_array_uint64_mark_range(column, first_mark, mark_count)
    {% else %}
      reader.read_array_map_uint64_array_string_mark_range(column, first_mark, mark_count)
    {% end %}
  {% else %}
    {% if V == UInt64 %}
      reader.read_array_map_string_array_uint64_mark_range(column, first_mark, mark_count)
    {% else %}
      reader.read_array_map_string_array_string_mark_range(column, first_mark, mark_count)
    {% end %}
  {% end %}
end

private def w84_write_part(
  destination : String,
  rows : Array(Array(Array(Tuple(K, Array(V))))),
) : String forall K, V
  {% if K == UInt64 %}
    {% if V == UInt64 %}
      CrystalClick::WidePartWriter.write_uint64_array_map_uint64_array_uint64_pair(destination, "pk", W84_KEYS.to_unsafe.to_slice(W84_KEYS.size), "payload", rows.to_unsafe.to_slice(rows.size), rows_per_mark: 2)
    {% else %}
      CrystalClick::WidePartWriter.write_uint64_array_map_uint64_array_string_pair(destination, "pk", W84_KEYS.to_unsafe.to_slice(W84_KEYS.size), "payload", rows.to_unsafe.to_slice(rows.size), rows_per_mark: 2)
    {% end %}
  {% else %}
    {% if V == UInt64 %}
      CrystalClick::WidePartWriter.write_uint64_array_map_string_array_uint64_pair(destination, "pk", W84_KEYS.to_unsafe.to_slice(W84_KEYS.size), "payload", rows.to_unsafe.to_slice(rows.size), rows_per_mark: 2)
    {% else %}
      CrystalClick::WidePartWriter.write_uint64_array_map_string_array_string_pair(destination, "pk", W84_KEYS.to_unsafe.to_slice(W84_KEYS.size), "payload", rows.to_unsafe.to_slice(rows.size), rows_per_mark: 2)
    {% end %}
  {% end %}
end

private def w84_create_table(binary : String, store : String, table : String, type_name : String) : Nil
  w84_clickhouse(binary, store, <<-SQL)
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

private def w84_check_table(binary : String, store : String, table : String) : Nil
  observed = w84_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "#{table} CHECK TABLE failed: #{observed.inspect}" unless observed == "all_1_1_0\t1"
end

private def w84_query_rows(binary : String, store : String, table : String, expected : Bytes, ranged : Bytes) : Nil
  full = w84_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  raise "#{table} full RowBinary differs" unless full.to_slice == expected
  selected = w84_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} WHERE pk >= 2 AND pk < 5 ORDER BY pk FORMAT RowBinary")
  raise "#{table} keyed RowBinary differs" unless selected.to_slice == ranged
  nil
end

private def w84_assert_fixture_rows(
  binary : String,
  store : String,
  column : String,
  rows : Array(Array(Array(Tuple(K, Array(V))))),
) : Nil forall K, V
  full_indices = (0...W84_KEYS.size).map(&.to_i32)
  expected = w84_rowbinary(W84_KEYS, rows, full_indices)
  ranged = w84_rowbinary(W84_KEYS, rows, W84_RANGE_INDICES)
  full = w84_clickhouse(binary, store, "SELECT pk, #{column} FROM default.w84_matrix ORDER BY pk FORMAT RowBinary")
  unless full.to_slice == expected
    actual = full.to_slice
    offset = (0...Math.min(actual.size, expected.size)).find { |index| actual[index] != expected[index] } || Math.min(actual.size, expected.size)
    raise "W84 fixture #{column} full RowBinary differs at byte #{offset} (actual=#{actual.size}, expected=#{expected.size}, actual_prefix=#{actual[0, Math.min(actual.size, offset + 16)].hexstring}, expected_prefix=#{expected[0, Math.min(expected.size, offset + 16)].hexstring})"
  end
  selected = w84_clickhouse(binary, store, "SELECT pk, #{column} FROM default.w84_matrix WHERE pk >= 2 AND pk < 5 ORDER BY pk FORMAT RowBinary")
  raise "W84 fixture #{column} keyed RowBinary differs" unless selected.to_slice == ranged
  nil
end

private def w84_stock_part(binary : String, store : String, root : String, table : String) : String
  path = w84_clickhouse(binary, store, "SELECT path FROM system.parts WHERE database = 'default' AND table = '#{table}' AND active FORMAT TSVRaw").strip
  raise "#{table} source part missing" unless Dir.exists?(path)
  part = File.join(root, "stock-#{table}")
  FileUtils.cp_r(path, part)
  part
end

private def w84_attach_writer_part(
  binary : String,
  store : String,
  root : String,
  label : String,
  type : String,
  part : String,
  expected : Bytes,
  ranged : Bytes,
) : Nil
  table = "w84_writer_#{label}"
  w84_create_table(binary, store, table, type)
  data_path = w84_clickhouse(binary, store, "SELECT data_paths[1] FROM system.tables WHERE database = 'default' AND name = '#{table}' FORMAT TSVRaw").strip
  raise "#{table} data path is missing" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  w84_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  w84_check_table(binary, store, table)
  w84_query_rows(binary, store, table, expected, ranged)
  puts "PASS W84 Crystal-to-stock ATTACH/CHECK/full/keyed RowBinary #{type}"
  nil
end

private def w84_edge_rows_uu : Array(Array(Array(Tuple(UInt64, Array(UInt64)))))
  [
    [] of Array(Tuple(UInt64, Array(UInt64))),
    [
      [] of Tuple(UInt64, Array(UInt64)),
      [{7_u64, [] of UInt64}, {7_u64, [11_u64, 12_u64]}] of Tuple(UInt64, Array(UInt64)),
    ] of Array(Tuple(UInt64, Array(UInt64))),
    [[] of Tuple(UInt64, Array(UInt64))] of Array(Tuple(UInt64, Array(UInt64))),
    [[{8_u64, [] of UInt64}] of Tuple(UInt64, Array(UInt64))] of Array(Tuple(UInt64, Array(UInt64))),
    [[{9_u64, [90_u64]}] of Tuple(UInt64, Array(UInt64))] of Array(Tuple(UInt64, Array(UInt64))),
  ]
end

private def w84_edge_rows_us : Array(Array(Array(Tuple(UInt64, Array(String)))))
  [
    [] of Array(Tuple(UInt64, Array(String))),
    [
      [] of Tuple(UInt64, Array(String)),
      [{7_u64, [] of String}, {7_u64, ["", W84_BINARY_VALUE]}] of Tuple(UInt64, Array(String)),
    ] of Array(Tuple(UInt64, Array(String))),
    [[] of Tuple(UInt64, Array(String))] of Array(Tuple(UInt64, Array(String))),
    [[{8_u64, [] of String}] of Tuple(UInt64, Array(String))] of Array(Tuple(UInt64, Array(String))),
    [[{9_u64, ["tail", ""]}] of Tuple(UInt64, Array(String))] of Array(Tuple(UInt64, Array(String))),
  ]
end

private def w84_edge_rows_su : Array(Array(Array(Tuple(String, Array(UInt64)))))
  [
    [] of Array(Tuple(String, Array(UInt64))),
    [
      [] of Tuple(String, Array(UInt64)),
      [{"dup", [] of UInt64}, {"dup", [11_u64, 12_u64]}] of Tuple(String, Array(UInt64)),
    ] of Array(Tuple(String, Array(UInt64))),
    [[] of Tuple(String, Array(UInt64))] of Array(Tuple(String, Array(UInt64))),
    [[{W84_BINARY_KEY, [] of UInt64}] of Tuple(String, Array(UInt64))] of Array(Tuple(String, Array(UInt64))),
    [[{"", [90_u64]}] of Tuple(String, Array(UInt64))] of Array(Tuple(String, Array(UInt64))),
  ]
end

private def w84_edge_rows_ss : Array(Array(Array(Tuple(String, Array(String)))))
  [
    [] of Array(Tuple(String, Array(String))),
    [
      [] of Tuple(String, Array(String)),
      [{"dup", [] of String}, {"dup", ["", W84_BINARY_VALUE]}] of Tuple(String, Array(String)),
    ] of Array(Tuple(String, Array(String))),
    [[] of Tuple(String, Array(String))] of Array(Tuple(String, Array(String))),
    [[{W84_BINARY_KEY, [] of String}] of Tuple(String, Array(String))] of Array(Tuple(String, Array(String))),
    [[{"", ["tail", ""]}] of Tuple(String, Array(String))] of Array(Tuple(String, Array(String))),
  ]
end

private def w84_all_empty_rows(key_sample : K, value_sample : V) : Array(Array(Array(Tuple(K, Array(V))))) forall K, V
  Array(Array(Array(Tuple(K, Array(V))))).new(W84_KEYS.size) { [] of Array(Tuple(K, Array(V))) }
end

private def w84_fixture_rows_uu : Array(Array(Array(Tuple(UInt64, Array(UInt64)))))
  [
    [[{1_u64, [10_u64, 20_u64]}, {2_u64, [] of UInt64}] of Tuple(UInt64, Array(UInt64))] of Array(Tuple(UInt64, Array(UInt64))),
    [] of Array(Tuple(UInt64, Array(UInt64))),
    [[{3_u64, [30_u64]}] of Tuple(UInt64, Array(UInt64))] of Array(Tuple(UInt64, Array(UInt64))),
    [[{4_u64, [40_u64, 50_u64, 60_u64]}] of Tuple(UInt64, Array(UInt64))] of Array(Tuple(UInt64, Array(UInt64))),
    [] of Array(Tuple(UInt64, Array(UInt64))),
  ]
end

private def w84_fixture_rows_us : Array(Array(Array(Tuple(UInt64, Array(String)))))
  [
    [[{1_u64, ["x", "yy"]}, {2_u64, [] of String}] of Tuple(UInt64, Array(String))] of Array(Tuple(UInt64, Array(String))),
    [] of Array(Tuple(UInt64, Array(String))),
    [[{3_u64, ["z"]}] of Tuple(UInt64, Array(String))] of Array(Tuple(UInt64, Array(String))),
    [[{4_u64, ["m", "nn", "ooo"]}] of Tuple(UInt64, Array(String))] of Array(Tuple(UInt64, Array(String))),
    [] of Array(Tuple(UInt64, Array(String))),
  ]
end

private def w84_fixture_rows_su : Array(Array(Array(Tuple(String, Array(UInt64)))))
  [
    [[{"a", [10_u64, 20_u64]}, {"b", [] of UInt64}] of Tuple(String, Array(UInt64))] of Array(Tuple(String, Array(UInt64))),
    [] of Array(Tuple(String, Array(UInt64))),
    [[{"c", [30_u64]}] of Tuple(String, Array(UInt64))] of Array(Tuple(String, Array(UInt64))),
    [[{"d", [40_u64, 50_u64, 60_u64]}] of Tuple(String, Array(UInt64))] of Array(Tuple(String, Array(UInt64))),
    [] of Array(Tuple(String, Array(UInt64))),
  ]
end

private def w84_fixture_rows_ss : Array(Array(Array(Tuple(String, Array(String)))))
  [
    [[{"a", ["x", "yy"]}, {"b", [] of String}] of Tuple(String, Array(String))] of Array(Tuple(String, Array(String))),
    [] of Array(Tuple(String, Array(String))),
    [[{"c", ["z"]}] of Tuple(String, Array(String))] of Array(Tuple(String, Array(String))),
    [[{"d", ["m", "nn", "ooo"]}] of Tuple(String, Array(String))] of Array(Tuple(String, Array(String))),
    [] of Array(Tuple(String, Array(String))),
  ]
end

private def w84_assert_reader(part : String, rows : Array(Array(Array(Tuple(K, Array(V)))))) : Nil forall K, V
  reader = CrystalClick::WidePart.open_typed(part, "payload")
  actual = w84_read_mark(reader, 0, reader.mark_count, rows)
  raise "#{part} full stock-to-Crystal read differs" unless actual == rows
  raise "#{part} stock mark count differs" unless reader.mark_count == 3
  raise "#{part} middle stock mark read differs" unless w84_read_mark(reader, 1, 1, rows) == rows[2, 2]
  raise "#{part} later stock mark read differs" unless w84_read_mark(reader, 2, 1, rows) == rows[4, 1]
  puts "PASS W84 stock-to-Crystal full/middle/later marks #{reader.column_type}"
  nil
end

private def w84_assert_column_reader(
  part : String,
  column : String,
  rows : Array(Array(Array(Tuple(K, Array(V))))),
) : Nil forall K, V
  reader = CrystalClick::WidePart.open_typed(part, column)
  raise "W84 #{column} full stock-to-Crystal read differs" unless w84_read_column(reader, column, 0, reader.mark_count, rows) == rows
  raise "W84 #{column} stock mark count differs" unless reader.mark_count == 3
  raise "W84 #{column} middle stock mark read differs" unless w84_read_column(reader, column, 1, 1, rows) == rows[2, 2]
  raise "W84 #{column} later stock mark read differs" unless w84_read_column(reader, column, 2, 1, rows) == rows[4, 1]
  puts "PASS W84 stock-to-Crystal #{column} full/middle/later mark reads"
  nil
end

private def w84_assert_table_reader(
  part : String,
  column : String,
  rows : Array(Array(Array(Tuple(K, Array(V))))),
) : Nil forall K, V
  actual_keys = [] of UInt64
  actual_rows = [] of Array(Array(Tuple(K, Array(V))))
  CrystalClick::WidePartTable.open_selected_typed([part], ["pk", column]).scan_typed do |batch|
    actual_keys.concat(batch.values_for("pk", UInt64).to_a)
    actual_rows.concat(batch.array_map_array_leaf_values_for(column, K, V).to_a)
  end
  raise "W84 typed table full scan differs for #{column}" unless actual_keys == W84_KEYS && actual_rows == rows

  selected_keys = [] of UInt64
  selected_rows = [] of Array(Array(Tuple(K, Array(V))))
  CrystalClick::WidePartTable.open_selected_typed([part], ["pk", column]).scan_typed_candidate_marks([[1]]) do |batch|
    selected_keys.concat(batch.values_for("pk", UInt64).to_a)
    selected_rows.concat(batch.array_map_array_leaf_values_for(column, K, V).to_a)
  end
  raise "W84 typed table selected mark differs for #{column}" unless selected_keys == W84_KEYS[2, 2] && selected_rows == rows[2, 2]
  puts "PASS W84 stock typed-table full/selected mark reads #{column}"
  nil
end

private def w84_write_u64_at(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def w84_assert_table_preflight_before_callbacks(part : String, root : String) : Nil
  corrupt_part = File.join(root, "corrupt-table", File.basename(part))
  FileUtils.mkdir_p(File.dirname(corrupt_part))
  FileUtils.cp_r(part, corrupt_part)
  marks_path = File.join(corrupt_part, "#{CrystalClick::StreamName.hash("p_uu%2Evalues.size2")}.mrk2")
  marks = File.read(marks_path).to_slice.dup
  w84_write_u64_at(marks, CrystalClick::WidePart::MARK_SIZE, UInt64::MAX)
  File.write(marks_path, marks)

  callbacks = 0
  rejected = false
  begin
    CrystalClick::WidePartTable.open_selected_typed([corrupt_part], ["pk", "p_uu"]).scan_typed_candidate_marks([[0, 1, 2]]) do |batch|
      callbacks += 1
      batch.array_map_array_leaf_values_for("p_uu", UInt64, UInt64)
    end
  rescue CrystalClick::CorruptPartError
    rejected = true
  end
  raise "W84 corrupted stock table mark was accepted" unless rejected
  raise "W84 corrupted stock table mark reached #{callbacks} callbacks before rejection" unless callbacks == 0
  puts "PASS W84 stock typed-table selected-mark corruption rejected before callbacks"
  nil
end

private def w84_run_case(
  binary : String,
  store : String,
  root : String,
  label : String,
  key_type : String,
  value_type : String,
  rows : Array(Array(Array(Tuple(K, Array(V))))),
) : Nil forall K, V
  type = "Array(Map(#{key_type}, Array(#{value_type})))"
  full_indices = (0...W84_KEYS.size).map(&.to_i32)
  expected = w84_rowbinary(W84_KEYS, rows, full_indices)
  ranged = w84_rowbinary(W84_KEYS, rows, W84_RANGE_INDICES)
  expected_raw = w84_expected_streams("payload", rows)
  pk = IO::Memory.new
  W84_KEYS.each { |key| w84_u64(pk, key) }
  expected_raw["pk"] = pk.to_slice.to_a

  table = "w84_stock_#{label}"
  w84_create_table(binary, store, table, type)
  w84_clickhouse(binary, store, "INSERT INTO default.#{table} FORMAT RowBinary", IO::Memory.new(expected))
  w84_check_table(binary, store, table)
  w84_query_rows(binary, store, table, expected, ranged)
  stock = w84_stock_part(binary, store, root, table)
  w84_assert_part(stock, type, key_type, value_type, true, expected_raw)

  {% if flag?(:w84_reader) %}
    w84_assert_reader(stock, rows)
  {% end %}

  {% if flag?(:w84_writer) %}
    writer_part = File.join(root, "writer-#{label}")
    w84_write_part(writer_part, rows)
    writer_streams = w84_stream_names("payload", key_type, value_type)
    w84_assert_part(writer_part, type, key_type, value_type, false, expected_raw, w84_expected_writer_mark_offsets(writer_streams, rows))
    w84_attach_writer_part(binary, store, root, label, type, writer_part, expected, ranged)
  {% end %}
  puts "PASS W84 stock fixture #{type} full/keyed RowBinary, duplicate/empty/binary edge rows, and exact streams"
  nil
end

private def w84_fixture_streams : Array(String)
  (w84_stream_names("p_uu", "UInt64", "UInt64") +
    w84_stream_names("p_us", "UInt64", "String") +
    w84_stream_names("p_su", "String", "UInt64") +
    w84_stream_names("p_ss", "String", "String"))
end

private def w84_fixture_expected_raw : Hash(String, Array(UInt8))
  raw = {} of String => Array(UInt8)
  raw.merge!(w84_expected_streams("p_uu", w84_fixture_rows_uu))
  raw.merge!(w84_expected_streams("p_us", w84_fixture_rows_us))
  raw.merge!(w84_expected_streams("p_su", w84_fixture_rows_su))
  raw.merge!(w84_expected_streams("p_ss", w84_fixture_rows_ss))
  pk = IO::Memory.new
  W84_KEYS.each { |key| w84_u64(pk, key) }
  raw["pk"] = pk.to_slice.to_a
  raw
end

private def w84_assert_fixture_metadata(part : String) : Nil
  streams = w84_fixture_streams
  columns = "columns format version: 1\n5 columns:\n`pk` UInt64\n" +
            "`p_uu` Array(Map(UInt64, Array(UInt64)))\n" +
            "`p_us` Array(Map(UInt64, Array(String)))\n" +
            "`p_su` Array(Map(String, Array(UInt64)))\n" +
            "`p_ss` Array(Map(String, Array(String)))\n"
  raise "W84 stock fixture columns differ" unless File.read(File.join(part, "columns.txt")) == columns
  substreams = "columns substreams version: 1\n5 columns:\n1 substreams for column `pk`:\n\tpk\n"
  {"p_uu", "p_us", "p_su", "p_ss"}.each do |column|
    own = streams.select { |stream| stream.starts_with?("#{column}.") || stream.starts_with?("#{column}%") }
    substreams += "#{own.size} substreams for column `#{column}`:\n" + own.map { |stream| "\t#{stream}\n" }.join
  end
  raise "W84 stock fixture substream inventory/order differs" unless File.read(File.join(part, "columns_substreams.txt")) == substreams
  expected_serialization = %({"columns":[],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
  raise "W84 stock fixture serialization metadata differs" unless File.read(File.join(part, "serialization.json")).strip == expected_serialization
  nil
end

private def w84_run_fixture(binary : String, fixture_store : String, root : String) : Nil
  table = "w84_matrix"
  w84_check_table(binary, fixture_store, table)
  w84_assert_fixture_rows(binary, fixture_store, "p_uu", w84_fixture_rows_uu)
  w84_assert_fixture_rows(binary, fixture_store, "p_us", w84_fixture_rows_us)
  w84_assert_fixture_rows(binary, fixture_store, "p_su", w84_fixture_rows_su)
  w84_assert_fixture_rows(binary, fixture_store, "p_ss", w84_fixture_rows_ss)
  part_path = w84_clickhouse(binary, fixture_store, "SELECT path FROM system.parts WHERE database = 'default' AND table = '#{table}' AND active FORMAT TSVRaw").strip
  raise "W84 stock fixture part missing" unless Dir.exists?(part_path)
  part = File.join(root, "stock-w84-matrix")
  FileUtils.cp_r(part_path, part)
  w84_assert_fixture_metadata(part)
  w84_assert_layout(part, w84_fixture_streams, w84_fixture_expected_raw, true)

  {% if flag?(:w84_reader) %}
    w84_assert_column_reader(part, "p_uu", w84_fixture_rows_uu)
    w84_assert_column_reader(part, "p_us", w84_fixture_rows_us)
    w84_assert_column_reader(part, "p_su", w84_fixture_rows_su)
    w84_assert_column_reader(part, "p_ss", w84_fixture_rows_ss)
    table_part = File.join(root, "table-fixture", File.basename(part_path))
    FileUtils.mkdir_p(File.dirname(table_part))
    FileUtils.cp_r(part_path, table_part)
    w84_assert_table_reader(table_part, "p_uu", w84_fixture_rows_uu)
    w84_assert_table_reader(table_part, "p_us", w84_fixture_rows_us)
    w84_assert_table_reader(table_part, "p_su", w84_fixture_rows_su)
    w84_assert_table_reader(table_part, "p_ss", w84_fixture_rows_ss)
    w84_assert_table_preflight_before_callbacks(table_part, root)
    puts "PASS W84 stock fixture ClickHouse RowBinary, Crystal reader/table full/selected reads, and exact mark layout"
  {% end %}
  nil
end

binary = ENV.fetch("CLICKHOUSE_BIN")
store = ENV.fetch("CLICKHOUSE_STORE")
root = ENV.fetch("ORACLE_ROOT")
fixture_store = ENV.fetch("W84_STOCK_STORE", "/private/tmp/crystal-click-w84-matrix.TrPW5I/store")
mode = ENV.fetch("W84_ORACLE_MODE", "full")
version = w84_clickhouse(binary, store, "SELECT version() FORMAT TSVRaw").strip
raise "W84 oracle requires ClickHouse 26.7.1.1315, got #{version}" unless version == "26.7.1.1315"

w84_run_fixture(binary, fixture_store, root)
w84_run_case(binary, store, root, "uu", "UInt64", "UInt64", w84_edge_rows_uu)
w84_run_case(binary, store, root, "us", "UInt64", "String", w84_edge_rows_us)
w84_run_case(binary, store, root, "su", "String", "UInt64", w84_edge_rows_su)
w84_run_case(binary, store, root, "ss", "String", "String", w84_edge_rows_ss)
w84_run_case(binary, store, root, "all_empty_uu", "UInt64", "UInt64", w84_all_empty_rows(0_u64, 0_u64))
w84_run_case(binary, store, root, "all_empty_us", "UInt64", "String", w84_all_empty_rows(0_u64, ""))
w84_run_case(binary, store, root, "all_empty_su", "String", "UInt64", w84_all_empty_rows("", 0_u64))
w84_run_case(binary, store, root, "all_empty_ss", "String", "String", w84_all_empty_rows("", ""))

reader_result = mode == "reader" || mode == "full" ? "stock-to-Crystal full/selected reads" : "stock-only"
writer_result = mode == "writer" || mode == "full" ? "Crystal-to-stock ATTACH/CHECK/full/keyed RowBinary" : "writer not requested"
puts "W84 oracle mode=#{mode}: ClickHouse #{version}; supplied fixture; four exact Array(Map(K, Array(V))) types; empty levels, duplicate keys, binary/empty Strings, all-empty child streams, exact substreams/marks; #{reader_result}; #{writer_result}"
