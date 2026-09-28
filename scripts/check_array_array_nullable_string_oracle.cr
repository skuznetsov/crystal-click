require "file_utils"
require "../src/crystal_click"

def w61_oracle_clickhouse(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  result = Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse query failed (#{result.exit_code}): #{query}" unless result.success?
  output.to_s
end

def w61_append_u64(io : IO, value : UInt64) : Nil
  8.times { |byte| io.write_byte(((value >> (byte * 8)) & 0xff_u64).to_u8) }
end

def w61_append_u64_bytes(bytes : Array(UInt8), value : UInt64) : Nil
  8.times { |byte| bytes << ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

def w61_read_u32(bytes : Bytes, offset : Int) : UInt32
  value = 0_u32
  4.times { |byte| value |= bytes[offset + byte].to_u32 << (byte * 8) }
  value
end

def w61_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

def w61_append_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

def w61_append_nullable_string(io : IO, value : String?) : Nil
  if value.nil?
    io.write_byte(1_u8)
  else
    string = value.not_nil!
    io.write_byte(0_u8)
    w61_append_varuint(io, string.bytesize.to_u64)
    io.write(string.to_slice)
  end
end

def w61_append_array_array_nullable_string(io : IO, row : Array(Array(String?))) : Nil
  w61_append_varuint(io, row.size.to_u64)
  row.each do |inner|
    w61_append_varuint(io, inner.size.to_u64)
    inner.each { |value| w61_append_nullable_string(io, value) }
  end
end

def w61_expected_rowbinary(
  keys : Array(UInt64),
  rows : Array(Array(Array(String?))),
  selected : Array(Int32),
) : Bytes
  io = IO::Memory.new
  selected.each do |index|
    w61_append_u64(io, keys[index].to_u64)
    w61_append_array_array_nullable_string(io, rows[index])
  end
  io.to_slice
end

def w61_assert_rowbinary(actual : String, expected : Bytes, label : String) : Nil
  raise "#{label} RowBinary mismatch: expected #{expected.size} bytes, got #{actual.bytesize}" unless actual.to_slice == expected
end

def w61_rows(long_value : String) : Array(Array(Array(String?)))
  values = [] of Array(Array(String?))
  values << [["alpha", nil, ""] of String?]
  values << [] of Array(String?)
  values << [[nil] of String?, [] of String?, [nil, nil] of String?]
  values << [[nil] of String?]
  values << [[] of String?, [] of String?]
  values << [] of Array(String?)
  values << [["a\0b", "é😃", long_value] of String?, [] of String?]
  values << [["", "β"] of String?]
  values << [["tail", nil] of String?]
  values
end

def w61_hex(bytes : Bytes) : String
  digits = "0123456789abcdef"
  String.build do |io|
    bytes.each do |byte|
      io << digits[(byte >> 4).to_i]
      io << digits[(byte & 0x0f).to_i]
    end
  end
end

def w61_array_array_sql(row : Array(Array(String?))) : String
  outer = row.map do |inner|
    leaves = inner.map do |value|
      if value.nil?
        "NULL"
      else
        "unhex('#{w61_hex(value.not_nil!.to_slice)}')"
      end
    end
    "[#{leaves.join(", ")}]"
  end
  "CAST([#{outer.join(", ")}], 'Array(Array(Nullable(String)))')"
end

def w61_expected_streams(rows : Array(Array(Array(String?)))) : {Array(UInt8), Array(UInt8), Array(UInt8), Array(UInt8), Array(UInt8)}
  size0 = [] of UInt8
  size1 = [] of UInt8
  nulls = [] of UInt8
  sizes = [] of UInt8
  raw = [] of UInt8

  rows.each do |row|
    w61_append_u64_bytes(size0, row.size.to_u64)
    row.each do |inner|
      w61_append_u64_bytes(size1, inner.size.to_u64)
      inner.each do |value|
        if value.nil?
          nulls << 1_u8
          w61_append_u64_bytes(sizes, 0_u64)
        else
          string = value.not_nil!
          nulls << 0_u8
          w61_append_u64_bytes(sizes, string.bytesize.to_u64)
          string.to_slice.each { |byte| raw << byte }
        end
      end
    end
  end
  {size0, size1, nulls, sizes, raw}
end

def w61_raw_stream(part : String, stream : String) : Bytes
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")
  raise "missing #{stream}.bin" unless File.file?(path)
  CrystalClick::CompressedBlock.decode_all(File.read(path).to_slice)
end

def w61_mark_record(part : String, stream : String, index : Int) : {UInt64, UInt64, UInt64}
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  raise "missing #{stream}.mrk2" unless File.file?(path)
  bytes = File.read(path).to_slice
  raise "invalid #{stream}.mrk2 length #{bytes.size}" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  record_count = bytes.size // CrystalClick::WidePart::MARK_SIZE
  raise "#{stream} mark #{index} exceeds #{record_count} records" unless index < record_count
  offset = index * CrystalClick::WidePart::MARK_SIZE
  {w61_read_u64(bytes, offset), w61_read_u64(bytes, offset + 8), w61_read_u64(bytes, offset + 16)}
end

def w61_lz4_frames(part : String, stream : String) : Array(Tuple(UInt64, UInt64, UInt64))
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")
  compressed = File.read(path).to_slice
  frames = [] of Tuple(UInt64, UInt64, UInt64)
  file_offset = 0
  raw_offset = 0_u64

  while file_offset < compressed.size
    remaining = compressed.size - file_offset
    raise "truncated ClickHouse LZ4 frame header for #{stream}" if remaining < 25
    method = compressed[file_offset + 16]
    raise "expected #{stream} LZ4 method 0x82, got 0x#{method.to_s(16)}" unless method == 0x82_u8
    compressed_size = w61_read_u32(compressed, file_offset + 17).to_u64
    raw_size = w61_read_u32(compressed, file_offset + 21).to_u64
    raise "invalid #{stream} compressed frame size #{compressed_size}" if compressed_size < 9_u64
    raise "empty #{stream} LZ4 frame" if raw_size == 0_u64
    frame_size = 16_u64 + compressed_size
    raise "#{stream} frame exceeds file bounds" if frame_size > remaining.to_u64
    frames << {file_offset.to_u64, raw_offset, raw_size}
    file_offset += frame_size.to_i
    raw_offset += raw_size
  end
  raise "#{stream} has no LZ4 frames" if frames.empty?
  frames
end

def w61_mark_raw_offset(part : String, stream : String, mark_index : Int, frames : Array(Tuple(UInt64, UInt64, UInt64))) : UInt64
  compressed_offset, decompressed_offset, _rows = w61_mark_record(part, stream, mark_index)
  file_size = File.size(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_u64
  if compressed_offset == file_size
    return frames.sum(&.[2]) + decompressed_offset
  end
  frame = frames.find { |candidate| candidate[0] == compressed_offset }
  raise "#{stream} mark #{mark_index} compressed offset #{compressed_offset} is not an LZ4 frame boundary" unless frame
  raise "#{stream} mark #{mark_index} decompressed offset exceeds its frame" if decompressed_offset > frame[2]
  frame[1] + decompressed_offset
end

def w61_stream_row_bytes(row : Array(Array(String?)), stream : String) : UInt64
  case stream
  when "pk", "payload.size0"
    8_u64
  when "payload.size1"
    row.size.to_u64 * 8_u64
  when "payload.null"
    row.sum(0_u64) { |inner| inner.size.to_u64 }
  when "payload.size"
    row.sum(0_u64) { |inner| inner.size.to_u64 * 8_u64 }
  when "payload"
    row.sum(0_u64) do |inner|
      inner.sum(0_u64) { |value| value.nil? ? 0_u64 : value.not_nil!.bytesize.to_u64 }
    end
  else
    raise "unknown W61 stream #{stream}"
  end
end

def w61_expected_mark_offsets(rows : Array(Array(Array(String?))), stream : String) : Array(UInt64)
  offsets = [0_u64]
  total = 0_u64
  rows.each_with_index do |row, index|
    total += w61_stream_row_bytes(row, stream)
    offsets << total if (index + 1) % 2 == 0 || index == rows.size - 1
  end
  offsets
end

def w61_assert_part_metadata(part : String) : Nil
  expected_columns = "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` Array(Array(Nullable(String)))\n"
  raise "W61 columns.txt differs" unless File.read(File.join(part, "columns.txt")) == expected_columns

  expected_substreams = "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n5 substreams for column `payload`:\n\tpayload.size0\n\tpayload.size1\n\tpayload.null\n\tpayload.size\n\tpayload\n"
  actual_substreams = File.read(File.join(part, "columns_substreams.txt"))
  raise "W61 columns_substreams.txt differs or is not BASIC five-stream order" unless actual_substreams == expected_substreams

  expected_serialization = %({"columns":[],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
  actual_serialization = File.read(File.join(part, "serialization.json")).strip
  raise "W61 serialization.json differs: #{actual_serialization}" unless actual_serialization == expected_serialization
  raise "W61 default codec is not LZ4" unless File.read(File.join(part, "default_compression_codec.txt")).strip == "CODEC(LZ4)"

  ["pk", "payload.size0", "payload.size1", "payload.null", "payload.size", "payload"].each do |stream|
    bin = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")
    mrk2 = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
    raise "missing W61 #{stream}.bin" unless File.file?(bin)
    raise "missing plain W61 #{stream}.mrk2" unless File.file?(mrk2)
    raise "compressed .mrk marks unexpectedly present for #{stream}" if File.file?(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk"))
  end
  nil
end

def w61_assert_streams_and_marks(part : String, rows : Array(Array(Array(String?)))) : Nil
  expected = w61_expected_streams(rows)
  streams = ["payload.size0", "payload.size1", "payload.null", "payload.size", "payload"]
  streams.zip(expected.to_a).each do |stream, expected_bytes|
    actual = w61_raw_stream(part, stream).to_a
    raise "#{stream} decompressed bytes differ: expected #{expected_bytes.size}, got #{actual.size}" unless actual == expected_bytes
  end

  actual_nulls = w61_raw_stream(part, "payload.null").to_a
  actual_sizes = w61_raw_stream(part, "payload.size")
  leaf_index = 0
  null_count = 0
  empty_count = 0
  rows.each do |row|
    row.each do |inner|
      inner.each do |value|
        null_flag = actual_nulls[leaf_index]
        size = w61_read_u64(actual_sizes, leaf_index * 8)
        if value.nil?
          raise "NULL leaf #{leaf_index} is not represented as null=1,size=0" unless null_flag == 1_u8 && size == 0_u64
          null_count += 1
        else
          string = value.not_nil!
          raise "non-NULL leaf #{leaf_index} has a NULL flag" unless null_flag == 0_u8
          raise "leaf #{leaf_index} size differs from String bytes" unless size == string.bytesize.to_u64
          if string.empty?
            raise "empty String leaf unexpectedly has a NULL flag" unless null_flag == 0_u8
            empty_count += 1
          end
        end
        leaf_index += 1
      end
    end
  end
  raise "fixture lost intended NULL/empty coverage" unless null_count > 0 && empty_count > 0

  mark_rows = [2_u64, 2_u64, 2_u64, 2_u64, 1_u64, 0_u64]
  ["pk", *streams].each do |stream|
    frames = w61_lz4_frames(part, stream)
    marks_path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
    mark_bytes = File.size(marks_path)
    expected_size = mark_rows.size * CrystalClick::WidePart::MARK_SIZE
    raise "#{stream} mark count differs: expected #{expected_size} bytes, got #{mark_bytes}" unless mark_bytes == expected_size
    expected_offsets = w61_expected_mark_offsets(rows, stream)
    raise "internal W61 mark expectation count differs" unless expected_offsets.size == mark_rows.size
    mark_rows.each_with_index do |expected_rows, index|
      compressed_offset, decompressed_offset, actual_rows = w61_mark_record(part, stream, index)
      raise "#{stream} mark #{index} has #{actual_rows} rows, expected #{expected_rows}" unless actual_rows == expected_rows
      raw_offset = w61_mark_raw_offset(part, stream, index, frames)
      raise "#{stream} mark #{index} raw offset #{raw_offset}, expected #{expected_offsets[index]} (compressed=#{compressed_offset}, decompressed=#{decompressed_offset})" unless raw_offset == expected_offsets[index]
    end
  end

  # Mark 1 contains only NULL leaf values: .null and .size advance, payload bytes do not.
  w61_assert_mark_advance(part, "payload.size0", 1, 2, "all-NULL mark outer offsets")
  w61_assert_mark_advance(part, "payload.size1", 1, 2, "all-NULL mark inner offsets")
  w61_assert_mark_advance(part, "payload.null", 1, 2, "all-NULL mark null map")
  w61_assert_mark_advance(part, "payload.size", 1, 2, "all-NULL mark String sizes")
  w61_assert_mark_same(part, "payload", 1, 2, "all-NULL mark raw String bytes")

  # Mark 2 contains only empty child arrays: only the two Array size streams advance.
  w61_assert_mark_advance(part, "payload.size0", 2, 3, "all-empty mark outer offsets")
  w61_assert_mark_advance(part, "payload.size1", 2, 3, "all-empty mark inner offsets")
  {"payload.null", "payload.size", "payload"}.each do |stream|
    w61_assert_mark_same(part, stream, 2, 3, "all-empty mark zero-child position")
  end
  nil
end

def w61_assert_mark_advance(part : String, stream : String, before : Int, after : Int, label : String) : Nil
  first = w61_mark_record(part, stream, before)
  second = w61_mark_record(part, stream, after)
  raise "#{label}: #{stream} did not advance" if first[0] == second[0] && first[1] == second[1]
  nil
end

def w61_assert_mark_same(part : String, stream : String, before : Int, after : Int, label : String) : Nil
  first = w61_mark_record(part, stream, before)
  second = w61_mark_record(part, stream, after)
  raise "#{label}: #{stream} moved from #{first.inspect} to #{second.inspect}" unless first[0] == second[0] && first[1] == second[1]
  nil
end

def w61_assert_stock_lz4_crossing(part : String, rows : Array(Array(Array(String?)))) : Nil
  frames = w61_lz4_frames(part, "payload")
  boundaries = frames.map { |frame| frame[1] + frame[2] }
  raw_bytes = w61_raw_stream(part, "payload").size.to_u64
  expected_large_start = 14_u64
  expected_large_end = expected_large_start + rows[6][0][2].not_nil!.bytesize.to_u64
  raise "stock payload raw length changed: expected 5020, got #{raw_bytes}" unless raw_bytes == 5020_u64
  raise "5000-byte stock String no longer crosses the 4096-byte frame boundary" unless expected_large_start < 4096_u64 && 4096_u64 < expected_large_end && boundaries.includes?(4096_u64)
  raise "stock payload did not split into multiple 4096-limited LZ4 frames" if frames.size < 2
  nil
end

def w61_assert_clickhouse_part(binary : String, store : String, table : String, expected_rows : UInt64) : Nil
  integrity = w61_oracle_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "CHECK TABLE failed for #{table}: #{integrity.inspect}" unless integrity == "all_1_1_0\t1"
  info = w61_oracle_clickhouse(binary, store, "SELECT part_type, rows FROM system.parts WHERE database = 'default' AND table = '#{table}' AND active FORMAT TSV").strip
  raise "#{table} is not one Wide part with #{expected_rows} rows: #{info.inspect}" unless info == "Wide\t#{expected_rows}"
  nil
end

def w61_create_stock_source(binary : String, store : String, root : String, rows : Array(Array(Array(String?))), keys : Array(UInt64)) : String
  table = "w61_stock_source"
  inserts = keys.each_index.map { |index| "(#{keys[index]}, #{w61_array_array_sql(rows[index])})" }
  w61_oracle_clickhouse(binary, store, <<-SQL)
  CREATE TABLE default.#{table}
  (
      pk UInt64,
      payload Array(Array(Nullable(String)))
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
      ratio_of_defaults_for_sparse_serialization = 1.0,
      nullable_serialization_version = 'basic',
      default_compression_codec = 'LZ4'
  SQL
  w61_oracle_clickhouse(binary, store, "INSERT INTO default.#{table} VALUES #{inserts.join(", ")}")
  w61_assert_clickhouse_part(binary, store, table, keys.size.to_u64)
  stock_path = w61_oracle_clickhouse(
    binary,
    store,
    "SELECT path FROM system.parts WHERE database = 'default' AND table = '#{table}' AND active FORMAT TSVRaw"
  ).strip
  raise "stock producer part missing for #{table}: #{stock_path.inspect}" unless Dir.exists?(stock_path)
  part = File.join(root, "stock-part")
  FileUtils.cp_r(stock_path, part)
  w61_assert_part_metadata(part)
  w61_assert_streams_and_marks(part, rows)
  w61_assert_stock_lz4_crossing(part, rows)
  part
end

def w61_attach_part(binary : String, store : String, table : String, part : String) : Nil
  w61_oracle_clickhouse(binary, store, <<-SQL)
  CREATE TABLE default.#{table}
  (
      pk UInt64,
      payload Array(Array(Nullable(String)))
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
      ratio_of_defaults_for_sparse_serialization = 1.0,
      nullable_serialization_version = 'basic',
      default_compression_codec = 'LZ4'
  SQL
  data_path = w61_oracle_clickhouse(
    binary,
    store,
    "SELECT data_paths[1] FROM system.tables WHERE database = 'default' AND name = '#{table}' FORMAT TSVRaw"
  ).strip
  raise "no ClickHouse data path for #{table}" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  w61_oracle_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  w61_assert_clickhouse_part(binary, store, table, 9_u64)
  nil
end

def w61_assert_crystal_read(part : String, rows : Array(Array(Array(String?))), label : String) : Nil
  reader = CrystalClick::WidePart.open_typed(part, "payload")
  raise "#{label} declared #{reader.column_type}, expected Array(Array(Nullable(String)))" unless reader.column_type == "Array(Array(Nullable(String)))"
  raise "#{label} row count differs" unless reader.row_count == rows.size.to_u64
  raise "#{label} mark rows differ: #{reader.mark_row_counts.inspect}" unless reader.mark_row_counts == [2_u64, 2_u64, 2_u64, 2_u64, 1_u64]
  observed = reader.read_array_array_nullable_string_mark_range("payload", 0, reader.mark_count)
  raise "#{label} full Crystal read differs" unless observed == rows
  later = reader.read_array_array_nullable_string_mark_range("payload", 3, 2)
  raise "#{label} later-mark Crystal read differs" unless later == rows[6, 3]
  nil
end

def w61_verify_stock(binary : String, store : String, part : String, rows : Array(Array(Array(String?))), keys : Array(UInt64)) : Nil
  w61_assert_crystal_read(part, rows, "stock part")
  full = w61_oracle_clickhouse(binary, store, "SELECT pk, payload FROM default.w61_stock_source ORDER BY pk FORMAT RowBinary")
  w61_assert_rowbinary(full, w61_expected_rowbinary(keys, rows, (0...keys.size).map(&.to_i32)), "stock full")
  range_sql = "SELECT pk, payload FROM default.w61_stock_source WHERE pk >= 2 AND pk < 9 ORDER BY pk FORMAT RowBinary"
  ranged = w61_oracle_clickhouse(binary, store, range_sql)
  selected = keys.each_index.select { |index| keys[index] >= 2_u64 && keys[index] < 9_u64 }.map(&.to_i32).to_a
  w61_assert_rowbinary(ranged, w61_expected_rowbinary(keys, rows, selected), "stock PK range")
  nil
end

def w61_verify_writer(binary : String, store : String, root : String, rows : Array(Array(Array(String?))), keys : Array(UInt64)) : Nil
  part = File.join(root, "writer-part")
  CrystalClick::WidePartWriter.write_uint64_array_array_nullable_string_pair(
    part,
    "pk",
    keys.to_unsafe.to_slice(keys.size),
    "payload",
    rows.to_unsafe.to_slice(rows.size),
    rows_per_mark: 2
  )
  w61_assert_part_metadata(part)
  w61_assert_streams_and_marks(part, rows)
  w61_assert_crystal_read(part, rows, "Crystal writer part")

  table = "w61_writer_source"
  w61_attach_part(binary, store, table, part)
  full = w61_oracle_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  w61_assert_rowbinary(full, w61_expected_rowbinary(keys, rows, (0...keys.size).map(&.to_i32)), "Crystal writer full")
  range_sql = "SELECT pk, payload FROM default.#{table} WHERE pk >= 2 AND pk < 20 ORDER BY pk FORMAT RowBinary"
  ranged = w61_oracle_clickhouse(binary, store, range_sql)
  selected = keys.each_index.select { |index| keys[index] >= 2_u64 && keys[index] < 20_u64 }.map(&.to_i32).to_a
  w61_assert_rowbinary(ranged, w61_expected_rowbinary(keys, rows, selected), "Crystal writer PK range")
  nil
end

binary = ENV.fetch("CLICKHOUSE_BIN")
store = ENV.fetch("CLICKHOUSE_STORE")
root = ENV.fetch("ORACLE_ROOT")
values = w61_rows("z" * 5000)
stock_keys = (1_u64..9_u64).to_a
writer_keys = [1_u64, 2_u64, 4_u64, 7_u64, 10_u64, 11_u64, 15_u64, 18_u64, 20_u64]

stock_part = w61_create_stock_source(binary, store, root, values, stock_keys)
w61_verify_stock(binary, store, stock_part, values, stock_keys)
w61_verify_writer(binary, store, root, values, writer_keys)

puts "Array(Array(Nullable(String))) stock oracle passed: ClickHouse 26.7.1.1315 BASIC/Wide/LZ4/plain-mark producer, five-stream bytes and per-mark offsets, NULL/empty semantics, 4096 crossing, Crystal read, ATTACH PART/CHECK/full/key-range RowBinary"
