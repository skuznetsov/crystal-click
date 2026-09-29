require "file_utils"
require "../src/crystal_click"

W82_KEYS          = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
W82_RANGE_INDICES = [1_i32, 2_i32, 3_i32]
W82_MARK_ROWS     = [2_u64, 2_u64, 1_u64, 0_u64]
W82_BINARY_KEY    = String.new(Bytes[0x41_u8, 0_u8, 0xff_u8])
W82_BINARY_VALUE  = String.new(Bytes[0_u8, 0xff_u8, 0x80_u8])

private def w82_rows_u64_string : Array(Array(Array(Tuple(UInt64, String))))
  [
    [] of Array(Tuple(UInt64, String)),
    [
      [] of Tuple(UInt64, String),
      [{7_u64, ""}, {7_u64, W82_BINARY_VALUE}, {8_u64, "middle"}] of Tuple(UInt64, String),
    ] of Array(Tuple(UInt64, String)),
    [
      [] of Tuple(UInt64, String),
    ] of Array(Tuple(UInt64, String)),
    [] of Array(Tuple(UInt64, String)),
    [
      [{UInt64::MAX, W82_BINARY_VALUE}, {0_u64, "tail"}] of Tuple(UInt64, String),
      [] of Tuple(UInt64, String),
    ] of Array(Tuple(UInt64, String)),
  ] of Array(Array(Tuple(UInt64, String)))
end

private def w82_rows_string_string : Array(Array(Array(Tuple(String, String))))
  [
    [] of Array(Tuple(String, String)),
    [
      [] of Tuple(String, String),
      [{"dup", ""}, {"dup", W82_BINARY_VALUE}, {W82_BINARY_KEY, "middle"}] of Tuple(String, String),
    ] of Array(Tuple(String, String)),
    [
      [] of Tuple(String, String),
    ] of Array(Tuple(String, String)),
    [] of Array(Tuple(String, String)),
    [
      [{W82_BINARY_KEY, W82_BINARY_VALUE}, {"", "tail"}] of Tuple(String, String),
      [] of Tuple(String, String),
    ] of Array(Tuple(String, String)),
  ] of Array(Array(Tuple(String, String)))
end

private def w82_rows_u64_nullable_string : Array(Array(Array(Tuple(UInt64, String?))))
  [
    [] of Array(Tuple(UInt64, String?)),
    [
      [] of Tuple(UInt64, String?),
      [{7_u64, nil}, {7_u64, ""}, {8_u64, W82_BINARY_VALUE}] of Tuple(UInt64, String?),
    ] of Array(Tuple(UInt64, String?)),
    [
      [] of Tuple(UInt64, String?),
    ] of Array(Tuple(UInt64, String?)),
    [] of Array(Tuple(UInt64, String?)),
    [
      [{UInt64::MAX, nil}, {0_u64, "tail"}] of Tuple(UInt64, String?),
      [] of Tuple(UInt64, String?),
    ] of Array(Tuple(UInt64, String?)),
  ] of Array(Array(Tuple(UInt64, String?)))
end

private def w82_rows_string_nullable_string : Array(Array(Array(Tuple(String, String?))))
  [
    [] of Array(Tuple(String, String?)),
    [
      [] of Tuple(String, String?),
      [{"null", nil}, {"empty", ""}, {W82_BINARY_KEY, W82_BINARY_VALUE}] of Tuple(String, String?),
    ] of Array(Tuple(String, String?)),
    [
      [] of Tuple(String, String?),
    ] of Array(Tuple(String, String?)),
    [] of Array(Tuple(String, String?)),
    [
      [{W82_BINARY_KEY, nil}, {"", "tail"}] of Tuple(String, String?),
      [] of Tuple(String, String?),
    ] of Array(Tuple(String, String?)),
  ] of Array(Array(Tuple(String, String?)))
end

private def w82_rows_u64_string_all_empty : Array(Array(Array(Tuple(UInt64, String))))
  [
    [] of Array(Tuple(UInt64, String)),
    [[] of Tuple(UInt64, String)] of Array(Tuple(UInt64, String)),
    [] of Array(Tuple(UInt64, String)),
    [[] of Tuple(UInt64, String)] of Array(Tuple(UInt64, String)),
    [] of Array(Tuple(UInt64, String)),
  ] of Array(Array(Tuple(UInt64, String)))
end

private def w82_rows_string_string_all_empty : Array(Array(Array(Tuple(String, String))))
  [
    [] of Array(Tuple(String, String)),
    [[] of Tuple(String, String)] of Array(Tuple(String, String)),
    [] of Array(Tuple(String, String)),
    [[] of Tuple(String, String)] of Array(Tuple(String, String)),
    [] of Array(Tuple(String, String)),
  ] of Array(Array(Tuple(String, String)))
end

private def w82_rows_u64_nullable_string_all_empty : Array(Array(Array(Tuple(UInt64, String?))))
  [
    [] of Array(Tuple(UInt64, String?)),
    [[] of Tuple(UInt64, String?)] of Array(Tuple(UInt64, String?)),
    [] of Array(Tuple(UInt64, String?)),
    [[] of Tuple(UInt64, String?)] of Array(Tuple(UInt64, String?)),
    [] of Array(Tuple(UInt64, String?)),
  ] of Array(Array(Tuple(UInt64, String?)))
end

private def w82_rows_string_nullable_string_all_empty : Array(Array(Array(Tuple(String, String?))))
  [
    [] of Array(Tuple(String, String?)),
    [
      [] of Tuple(String, String?),
    ] of Array(Tuple(String, String?)),
    [] of Array(Tuple(String, String?)),
    [
      [] of Tuple(String, String?),
    ] of Array(Tuple(String, String?)),
    [] of Array(Tuple(String, String?)),
  ] of Array(Array(Tuple(String, String?)))
end

private def w82_clickhouse(binary : String, store : String, query : String, input : IO = IO::Memory.new) : String
  output = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], input: input, output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse query failed (#{status.exit_code}): #{query}" unless status.success?
  output.to_s
end

private def w82_u64(io : IO, value : UInt64) : Nil
  io.write_bytes(value, IO::ByteFormat::LittleEndian)
end

private def w82_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w82_string(io : IO, value : String) : Nil
  w82_varuint(io, value.bytesize.to_u64)
  io.write(value.to_slice)
end

private def w82_key(io : IO, key : K) : Nil forall K
  {% if K == String %}
    w82_string(io, key)
  {% elsif K == UInt64 %}
    w82_u64(io, key)
  {% else %}
    {% raise "unsupported W82 Map key type" %}
  {% end %}
end

private def w82_rowbinary(
  keys : Array(UInt64),
  rows : Array(Array(Array(Tuple(K, V)))),
  indices : Array(Int32),
) : Bytes forall K, V
  raise "W82 primary-key and Array(Map) row counts differ" unless keys.size == rows.size
  io = IO::Memory.new
  indices.each do |index|
    w82_u64(io, keys[index])
    maps = rows[index]
    w82_varuint(io, maps.size.to_u64)
    maps.each do |entries|
      w82_varuint(io, entries.size.to_u64)
      entries.each do |key, value|
        w82_key(io, key)
        {% if V.union_types.size == 2 && V.union_types.includes?(Nil) %}
          if value.nil?
            io.write_byte(1_u8)
          else
            io.write_byte(0_u8)
            w82_string(io, value.not_nil!)
          end
        {% else %}
          w82_string(io, value)
        {% end %}
      end
    end
  end
  io.to_slice
end

private def w82_expected_streams(rows : Array(Array(Array(Tuple(K, V))))) : Hash(String, Array(UInt8)) forall K, V
  outer_sizes = IO::Memory.new
  map_sizes = IO::Memory.new
  key_sizes = IO::Memory.new
  keys = IO::Memory.new
  value_nulls = IO::Memory.new
  value_sizes = IO::Memory.new
  values = IO::Memory.new
  rows.each do |row|
    w82_u64(outer_sizes, row.size.to_u64)
    row.each do |entries|
      w82_u64(map_sizes, entries.size.to_u64)
      entries.each do |key, value|
        {% if K == String %}
          w82_u64(key_sizes, key.bytesize.to_u64)
          keys.write(key.to_slice)
        {% else %}
          w82_u64(keys, key)
        {% end %}
        {% if V.union_types.size == 2 && V.union_types.includes?(Nil) %}
          if value.nil?
            value_nulls.write_byte(1_u8)
            w82_u64(value_sizes, 0_u64)
          else
            value_nulls.write_byte(0_u8)
            w82_u64(value_sizes, value.not_nil!.bytesize.to_u64)
            values.write(value.not_nil!.to_slice)
          end
        {% else %}
          w82_u64(value_sizes, value.bytesize.to_u64)
          values.write(value.to_slice)
        {% end %}
      end
    end
  end

  result = {
    "payload.size0"         => outer_sizes.to_slice.to_a,
    "payload.size1"         => map_sizes.to_slice.to_a,
    "payload%2Ekeys"        => keys.to_slice.to_a,
    "payload%2Evalues.size" => value_sizes.to_slice.to_a,
    "payload%2Evalues"      => values.to_slice.to_a,
  }
  {% if K == String %}
    result["payload%2Ekeys.size"] = key_sizes.to_slice.to_a
  {% end %}
  {% if V.union_types.size == 2 && V.union_types.includes?(Nil) %}
    result["payload%2Evalues.null"] = value_nulls.to_slice.to_a
  {% end %}
  result
end

private def w82_stream_names(key_type : String, nullable : Bool) : Array(String)
  names = ["payload.size0", "payload.size1"] of String
  names << "payload%2Ekeys.size" if key_type == "String"
  names << "payload%2Ekeys"
  names << "payload%2Evalues.null" if nullable
  names << "payload%2Evalues.size"
  names << "payload%2Evalues"
  names
end

private def w82_raw_stream(part : String, stream : String) : Array(UInt8)
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")
  encoded = File.read(path).to_slice
  return [] of UInt8 if encoded.empty?
  CrystalClick::CompressedBlock.decode_all(encoded).to_a
end

private def w82_u64_at(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

private def w82_mark_records(part : String, stream : String) : Array(Tuple(UInt64, UInt64, UInt64))
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  bytes = File.read(path).to_slice
  raise "#{part} #{stream} mark file size differs: #{bytes.size}" unless bytes.size == W82_MARK_ROWS.size * CrystalClick::WidePart::MARK_SIZE
  Array(Tuple(UInt64, UInt64, UInt64)).new(W82_MARK_ROWS.size) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE
    {w82_u64_at(bytes, offset), w82_u64_at(bytes, offset + 8), w82_u64_at(bytes, offset + 16)}
  end
end

private def w82_create_table(binary : String, store : String, table : String, type_name : String) : Nil
  w82_clickhouse(binary, store, <<-SQL)
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

private def w82_check_table(binary : String, store : String, table : String) : Nil
  observed = w82_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "#{table} CHECK TABLE failed: #{observed.inspect}" unless observed == "all_1_1_0\t1"
end

private def w82_query_rows(binary : String, store : String, table : String, expected : Bytes, ranged : Bytes) : Nil
  full = w82_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  raise "#{table} full RowBinary differs" unless full.to_slice == expected
  selected = w82_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} WHERE pk >= 2 AND pk < 5 ORDER BY pk FORMAT RowBinary")
  raise "#{table} keyed RowBinary differs" unless selected.to_slice == ranged
  nil
end

private def w82_stock_part(binary : String, store : String, root : String, table : String) : String
  path = w82_clickhouse(binary, store, "SELECT path FROM system.parts WHERE database = 'default' AND table = '#{table}' AND active FORMAT TSVRaw").strip
  raise "#{table} source part missing" unless Dir.exists?(path)
  part = File.join(root, "stock-#{table}")
  FileUtils.cp_r(path, part)
  part
end

private def w82_assert_stock_part(
  part : String,
  type_name : String,
  key_type : String,
  nullable : Bool,
  stock : Bool,
  expected_raw : Hash(String, Array(UInt8)),
) : Nil
  value_type = nullable ? "Nullable(String)" : "String"
  full_type = "Array(Map(#{key_type}, #{value_type}))"
  streams = w82_stream_names(key_type, nullable)
  expected_columns = "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` #{full_type}\n"
  raise "#{part} columns differ" unless File.read(File.join(part, "columns.txt")) == expected_columns

  expected_substreams = "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n" +
                        "#{streams.size} substreams for column `payload`:\n" + streams.map { |stream| "\t#{stream}\n" }.join
  raise "#{part} substream inventory/order differs" unless File.read(File.join(part, "columns_substreams.txt")) == expected_substreams

  serialization = File.read(File.join(part, "serialization.json")).strip
  expected_serialization = %({"columns":[],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
  raise "#{part} serialization differs: #{serialization}" unless serialization == expected_serialization

  expected_files = [
    "checksums.txt", "columns.txt", "columns_substreams.txt", "count.txt",
    "default_compression_codec.txt", "metadata_version.txt", stock ? "primary.cidx" : "primary.idx",
    "serialization.json",
  ]
  (streams + ["pk"]).each do |stream|
    base = CrystalClick::StreamName.hash(stream)
    expected_files << "#{base}.bin" << "#{base}.mrk2"
  end
  actual_files = Dir.children(part).sort
  missing = expected_files - actual_files
  extra = actual_files - expected_files
  raise "#{part} file inventory differs (missing=#{missing.sort}, extra=#{extra.sort})" unless actual_files == expected_files.sort
  raise "#{part} row count differs" unless File.read(File.join(part, "count.txt")) == W82_KEYS.size.to_s
  raise "#{part} metadata version differs" unless File.read(File.join(part, "metadata_version.txt")) == "0"
  raise "#{part} codec differs" unless File.read(File.join(part, "default_compression_codec.txt")) == "CODEC(LZ4)"

  checksums = CrystalClick::PartChecksums.open(part)
  checksum_files = expected_files - [
    "checksums.txt", "columns.txt", "columns_substreams.txt", "default_compression_codec.txt", "metadata_version.txt",
  ]
  raise "#{part} checksum inventory differs" unless checksums.entries.keys.sort == checksum_files.sort
  checksums.entries.each_key { |name| checksums.validate_selected_entries(part, name) }

  expected_raw.each do |stream, bytes|
    actual = w82_raw_stream(part, stream)
    raise "#{part} #{stream} raw bytes differ (expected=#{bytes.size}, actual=#{actual.size})" unless actual == bytes
  end

  (streams + ["pk"]).each do |stream|
    records = w82_mark_records(part, stream)
    raise "#{part} #{stream} mark row counts differ: #{records.inspect}" unless records.map(&.[2]) == W82_MARK_ROWS
    raw_size = expected_raw[stream].size.to_u64
    records.each_cons(2) do |pair|
      left, right = pair[0], pair[1]
      raise "#{part} #{stream} mark offsets are not monotonic" if right[0] < left[0] || (right[0] == left[0] && right[1] < left[1])
    end
    if stock
      raise "#{part} #{stream} terminal mark raw offset differs" unless records.last[1] == raw_size
    else
      data_size = File.size(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_u64
      raise "#{part} #{stream} writer terminal compressed offset differs" unless records.last[0] == data_size && records.last[1] == 0_u64
    end
    if streams.includes?(stream) && stream != "payload.size0" && stream != "payload.size1"
      raise "#{part} #{stream} empty child mark advanced" unless {records[1][0], records[1][1]} == {records[2][0], records[2][1]}
      if raw_size == 0_u64
        raise "#{part} #{stream} zero-byte child marks are not all at origin" unless records.all? { |record| {record[0], record[1]} == {0_u64, 0_u64} }
      end
    end
    puts "#{File.basename(part)} #{stream} marks=#{records.inspect} raw_bytes=#{raw_size}"
  end
  nil
end

private def w82_read_mark(
  reader : CrystalClick::WidePart,
  first_mark : Int32,
  mark_count : Int32,
  rows : Array(Array(Array(Tuple(K, V)))),
) : Array(Array(Array(Tuple(K, V)))) forall K, V
  {% if K == UInt64 %}
    {% if V.union_types.size == 2 && V.union_types.includes?(Nil) %}
      reader.read_array_map_uint64_nullable_string_mark_range("payload", first_mark, mark_count)
    {% else %}
      reader.read_array_map_uint64_string_mark_range("payload", first_mark, mark_count)
    {% end %}
  {% else %}
    {% if V.union_types.size == 2 && V.union_types.includes?(Nil) %}
      reader.read_array_map_string_nullable_string_mark_range("payload", first_mark, mark_count)
    {% else %}
      reader.read_array_map_string_string_mark_range("payload", first_mark, mark_count)
    {% end %}
  {% end %}
end

private def w82_table_values(
  batch : CrystalClick::WidePartTableBatch,
  rows : Array(Array(Array(Tuple(K, V)))),
) : Slice(Array(Array(Tuple(K, V)))) forall K, V
  {% if K == UInt64 %}
    {% if V.union_types.size == 2 && V.union_types.includes?(Nil) %}
      batch.array_map_uint64_nullable_strings_for("payload")
    {% else %}
      batch.array_map_uint64_strings_for("payload")
    {% end %}
  {% else %}
    {% if V.union_types.size == 2 && V.union_types.includes?(Nil) %}
      batch.array_map_string_nullable_strings_for("payload")
    {% else %}
      batch.array_map_string_strings_for("payload")
    {% end %}
  {% end %}
end

private def w82_assert_table_reads(
  part : String,
  root : String,
  rows : Array(Array(Array(Tuple(K, V)))),
  expected : Bytes,
  ranged : Bytes,
) : Nil forall K, V
  table_part = File.join(root, "typed-table-read-#{File.basename(part)}", "all_1_1_0")
  FileUtils.mkdir_p(File.dirname(table_part))
  FileUtils.cp_r(part, table_part)
  table = CrystalClick::WidePartTable.open_selected_typed([table_part], ["pk", "payload"])
  observed_keys = [] of UInt64
  observed_rows = [] of Array(Array(Tuple(K, V)))
  table.scan_typed(batch_rows: 2) do |batch|
    observed_keys.concat(batch.values_for("pk").to_a)
    observed_rows.concat(w82_table_values(batch, rows).to_a)
  end
  raise "W82 typed-table full payload differs" unless observed_rows == rows
  all_indices = (0...observed_keys.size).map(&.to_i32)
  unless w82_rowbinary(observed_keys, observed_rows, all_indices) == expected
    raise "W82 typed-table full RowBinary differs"
  end

  range_keys = [] of UInt64
  range_rows = [] of Array(Array(Tuple(K, V)))
  table.scan_typed_window(1_u64, max_rows: 3) do |batch|
    range_keys.concat(batch.values_for("pk").to_a)
    range_rows.concat(w82_table_values(batch, rows).to_a)
  end
  raise "W82 typed-table keyed payload differs" unless range_rows == rows[1, 3]
  range_indices = (0...range_keys.size).map(&.to_i32)
  unless w82_rowbinary(range_keys, range_rows, range_indices) == ranged
    raise "W82 typed-table keyed RowBinary differs"
  end
  puts "PASS W82 stock-to-Crystal typed table full/keyed accessors and RowBinary"
  nil
end

private def w82_write_u64_at(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def w82_assert_later_mark_corruption_rejected(
  part : String,
  root : String,
  rows : Array(Array(Array(Tuple(K, V)))),
) : Nil forall K, V
  corrupt_part = File.join(root, "corrupt-w82-later-child-mark")
  FileUtils.cp_r(part, corrupt_part)
  marks_path = File.join(corrupt_part, "#{CrystalClick::StreamName.hash("payload.size1")}.mrk2")
  marks = File.read(marks_path).to_slice.dup
  w82_write_u64_at(marks, 2 * CrystalClick::WidePart::MARK_SIZE + 8, UInt64::MAX)
  File.write(marks_path, marks)

  rejected = false
  begin
    corrupt_reader = CrystalClick::WidePart.open_typed(corrupt_part, "payload")
    w82_read_mark(corrupt_reader, 2, 1, rows)
  rescue ex : CrystalClick::CorruptPartError
    rejected = true
  end
  raise "reader accepted a malformed later W82 Map-size mark" unless rejected
  puts "PASS W82 corruption guard: rejects an out-of-extent later Map-size mark"
  nil
end

private def w82_write_part(
  destination : String,
  rows : Array(Array(Array(Tuple(K, V)))),
) : String forall K, V
  {% if K == UInt64 %}
    {% if V.union_types.size == 2 && V.union_types.includes?(Nil) %}
      CrystalClick::WidePartWriter.write_uint64_array_map_uint64_nullable_string_pair(
        destination, "pk", W82_KEYS.to_unsafe.to_slice(W82_KEYS.size), "payload", rows.to_unsafe.to_slice(rows.size), rows_per_mark: 2
      )
    {% else %}
      CrystalClick::WidePartWriter.write_uint64_array_map_uint64_string_pair(
        destination, "pk", W82_KEYS.to_unsafe.to_slice(W82_KEYS.size), "payload", rows.to_unsafe.to_slice(rows.size), rows_per_mark: 2
      )
    {% end %}
  {% else %}
    {% if V.union_types.size == 2 && V.union_types.includes?(Nil) %}
      CrystalClick::WidePartWriter.write_uint64_array_map_string_nullable_string_pair(
        destination, "pk", W82_KEYS.to_unsafe.to_slice(W82_KEYS.size), "payload", rows.to_unsafe.to_slice(rows.size), rows_per_mark: 2
      )
    {% else %}
      CrystalClick::WidePartWriter.write_uint64_array_map_string_string_pair(
        destination, "pk", W82_KEYS.to_unsafe.to_slice(W82_KEYS.size), "payload", rows.to_unsafe.to_slice(rows.size), rows_per_mark: 2
      )
    {% end %}
  {% end %}
end

private def w82_attach_writer_part(
  binary : String,
  store : String,
  root : String,
  label : String,
  type : String,
  part : String,
  expected : Bytes,
  ranged : Bytes,
) : Nil
  table = "w82_writer_#{label}"
  w82_create_table(binary, store, table, type)
  data_path = w82_clickhouse(binary, store, "SELECT data_paths[1] FROM system.tables WHERE database = 'default' AND name = '#{table}' FORMAT TSVRaw").strip
  raise "#{table} data path is missing" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  w82_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  w82_check_table(binary, store, table)
  w82_query_rows(binary, store, table, expected, ranged)
  puts "PASS W82 Crystal-to-stock ATTACH/CHECK/full/keyed RowBinary #{type}"
  nil
end

private def w82_run_case(
  binary : String,
  store : String,
  root : String,
  label : String,
  type_name : String,
  key_type : String,
  nullable : Bool,
  rows : Array(Array(Array(Tuple(K, V)))),
) : Nil forall K, V
  table = "w82_stock_#{label}"
  type = "Array(Map(#{key_type}, #{nullable ? "Nullable(String)" : "String"}))"
  full_indices = (0...W82_KEYS.size).map(&.to_i32)
  expected = w82_rowbinary(W82_KEYS, rows, full_indices)
  ranged = w82_rowbinary(W82_KEYS, rows, W82_RANGE_INDICES)
  expected_raw = w82_expected_streams(rows)
  pk = IO::Memory.new
  W82_KEYS.each { |key| w82_u64(pk, key) }
  expected_raw["pk"] = pk.to_slice.to_a

  w82_create_table(binary, store, table, type)
  w82_clickhouse(binary, store, "INSERT INTO default.#{table} FORMAT RowBinary", IO::Memory.new(expected))
  w82_check_table(binary, store, table)
  w82_query_rows(binary, store, table, expected, ranged)
  part = w82_stock_part(binary, store, root, table)
  w82_assert_stock_part(part, type_name, key_type, nullable, true, expected_raw)

  {% if flag?(:w82_reader) %}
    reader = CrystalClick::WidePart.open_typed(part, "payload")
    stock_values = w82_read_mark(reader, 0, reader.mark_count, rows)
    middle_values = w82_read_mark(reader, 1, 1, rows)
    later_values = w82_read_mark(reader, 2, 1, rows)
    raise "#{table} full stock-to-Crystal read differs" unless stock_values == rows
    raise "#{table} middle empty-child mark read differs" unless middle_values == rows[2, 2]
    raise "#{table} later-mark read differs" unless later_values == rows[4, 1]
    puts "PASS W82 stock-to-Crystal full/middle/later marks #{type}"
    w82_assert_table_reads(part, root, rows, expected, ranged)
    if label == "u64_string"
      w82_assert_later_mark_corruption_rejected(part, root, rows)
    end
  {% end %}

  {% if flag?(:w82_writer) %}
    writer_part = File.join(root, "writer-#{label}")
    w82_write_part(writer_part, rows)
    w82_assert_stock_part(writer_part, type_name, key_type, nullable, false, expected_raw)
    w82_attach_writer_part(binary, store, root, label, type, writer_part, expected, ranged)
  {% end %}

  puts "PASS W82 stock fixture #{type} full/keyed RowBinary and exact substreams"
  nil
end

binary = ENV.fetch("CLICKHOUSE_BIN")
store = ENV.fetch("CLICKHOUSE_STORE")
root = ENV.fetch("ORACLE_ROOT")

w82_run_case(binary, store, root, "u64_string", "String", "UInt64", false, w82_rows_u64_string)
w82_run_case(binary, store, root, "string_string", "String", "String", false, w82_rows_string_string)
w82_run_case(binary, store, root, "u64_nullable_string", "String", "UInt64", true, w82_rows_u64_nullable_string)
w82_run_case(binary, store, root, "string_nullable_string", "String", "String", true, w82_rows_string_nullable_string)
w82_run_case(binary, store, root, "u64_string_empty", "String", "UInt64", false, w82_rows_u64_string_all_empty)
w82_run_case(binary, store, root, "string_string_empty", "String", "String", false, w82_rows_string_string_all_empty)
w82_run_case(binary, store, root, "u64_nullable_string_empty", "String", "UInt64", true, w82_rows_u64_nullable_string_all_empty)
w82_run_case(binary, store, root, "string_nullable_string_empty", "String", "String", true, w82_rows_string_nullable_string_all_empty)

puts "W82 oracle mode=#{ENV.fetch("W82_ORACLE_MODE")}: ClickHouse 26.7.1.1315; four exact Array(Map) String declarations; full/keyed RowBinary; exact substream order, contents, and four-mark layout; all-empty child streams"
