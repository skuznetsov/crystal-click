require "file_utils"
require "../src/crystal_click"

def w59_clickhouse(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  result = Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse query failed (#{result.exit_code}): #{query}" unless result.success?
  output.to_s
end

def w59_append_u64(io : IO, value : UInt64) : Nil
  8.times { |byte| io.write_byte(((value >> (byte * 8)) & 0xff_u64).to_u8) }
end

def w59_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

def w59_read_u32(bytes : Bytes, offset : Int) : UInt32
  value = 0_u32
  4.times { |byte| value |= bytes[offset + byte].to_u32 << (byte * 8) }
  value
end

def w59_append_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

def w59_append_array_array_string(io : IO, row : Array(Array(String))) : Nil
  w59_append_varuint(io, row.size.to_u64)
  row.each do |inner|
    w59_append_varuint(io, inner.size.to_u64)
    inner.each do |value|
      bytes = value.to_slice
      w59_append_varuint(io, bytes.size.to_u64)
      io.write(bytes)
    end
  end
end

def w59_expected_rowbinary(
  keys : Array(UInt64),
  rows : Array(Array(Array(String))),
  selected : Array(Int32),
) : Bytes
  io = IO::Memory.new
  selected.each do |index|
    w59_append_u64(io, keys[index])
    w59_append_array_array_string(io, rows[index])
  end
  io.to_slice
end

def w59_assert_rowbinary(actual : String, expected : Bytes, label : String) : Nil
  raise "#{label} RowBinary mismatch: expected #{expected.size} bytes, got #{actual.bytesize}" unless actual.to_slice == expected
end

def w59_mark_position(part : String, stream : String, mark_index : Int) : {UInt64, UInt64}
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  marks = File.read(path).to_slice
  offset = mark_index * CrystalClick::WidePart::MARK_SIZE
  {w59_read_u64(marks, offset), w59_read_u64(marks, offset + 8)}
end

def w59_assert_stream_inventory(part : String) : Nil
  substreams = File.read(File.join(part, "columns_substreams.txt"))
  expected = ["payload.size0", "payload.size1", "payload.size", "payload"]
  cursor = 0
  expected.each do |stream|
    index = substreams.index(stream, cursor)
    raise "missing or out-of-order nested String substream #{stream}" unless index
    cursor = index + stream.bytesize
  end

  serialization = File.read(File.join(part, "serialization.json"))
  raise "nested String serializer version 1 missing from serialization.json" unless serialization.includes?(%("string":1))
  nil
end

def w59_assert_zero_middle_child_mark(part : String) : Nil
  ["payload.size1", "payload.size", "payload"].each do |stream|
    middle = w59_mark_position(part, stream, 1)
    later = w59_mark_position(part, stream, 2)
    raise "#{stream} middle child mark is not zero-byte: #{middle.inspect} != #{later.inspect}" unless middle == later
  end
  nil
end

def w59_assert_stock_string_crosses_lz4_frame(part : String) : Nil
  compressed = File.read(File.join(part, "#{CrystalClick::StreamName.hash("payload")}.bin")).to_slice
  frame_offset = 0
  frame_count = 0
  decompressed_offset = 0_u64
  frame_boundaries = [] of UInt64

  while frame_offset < compressed.size
    remaining = compressed.size - frame_offset
    raise "truncated ClickHouse compressed frame header" if remaining < 25

    method = compressed[frame_offset + 16]
    raise "expected pinned LZ4 frame method 0x82, got 0x#{method.to_s(16)}" unless method == 0x82_u8

    compressed_size = w59_read_u32(compressed, frame_offset + 17).to_u64
    uncompressed_size = w59_read_u32(compressed, frame_offset + 21).to_u64
    raise "invalid ClickHouse compressed frame size #{compressed_size}" if compressed_size < 9_u64
    raise "empty ClickHouse compressed frame" if uncompressed_size == 0_u64

    frame_size = 16_u64 + compressed_size # 16-byte checksum, then the codec header and body.
    raise "ClickHouse compressed frame exceeds payload.bin bounds" if frame_size > remaining.to_u64

    decompressed_offset += uncompressed_size
    frame_boundaries << decompressed_offset
    frame_offset += frame_size.to_i
    frame_count += 1
  end

  string_start = "later".bytesize.to_u64 + w59_binary_string.bytesize.to_u64 + "é".bytesize.to_u64
  string_end = string_start + w59_large_string.bytesize.to_u64
  raise "pinned crossing fixture changed: expected String byte range 10..5010, got #{string_start}..#{string_end}" unless string_start == 10_u64 && string_end == 5010_u64
  raise "pinned payload should contain at least two LZ4 frames, got #{frame_count}" if frame_count < 2
  raise "pinned payload uncompressed length changed: expected 5010, got #{decompressed_offset}" unless decompressed_offset == 5010_u64
  raise "pinned 4096-byte frame boundary missing: #{frame_boundaries.inspect}" unless frame_boundaries.includes?(4096_u64)
  raise "pinned 4096-byte frame boundary does not cut the 5000-byte String" unless string_start < 4096_u64 && 4096_u64 < string_end
  nil
end

def w59_assert_empty_string_layout(part : String, stock_layout : Bool) : Nil
  size1_middle = w59_mark_position(part, "payload.size1", 1)
  size1_later = w59_mark_position(part, "payload.size1", 2)
  if stock_layout
    unless size1_later[0] == size1_middle[0] && size1_later[1] == size1_middle[1] + 8_u64
      raise "stock empty String should contribute one 8-byte inner-array size: #{size1_middle.inspect} -> #{size1_later.inspect}"
    end
  elsif size1_middle == size1_later
    raise "writer empty String should advance the inner-array size stream"
  end

  string_size_middle = w59_mark_position(part, "payload.size", 1)
  string_size_later = w59_mark_position(part, "payload.size", 2)
  if stock_layout
    unless string_size_later[0] == string_size_middle[0] && string_size_later[1] == string_size_middle[1] + 8_u64
      raise "stock empty String should contribute a zero-valued 8-byte String size: #{string_size_middle.inspect} -> #{string_size_later.inspect}"
    end
  elsif string_size_middle == string_size_later
    raise "writer empty String should advance the String size stream"
  end

  raw_middle = w59_mark_position(part, "payload", 1)
  raw_later = w59_mark_position(part, "payload", 2)
  raise "empty String unexpectedly contributed raw payload bytes" unless raw_middle == raw_later
  nil
end

def w59_assert_all_empty_child_streams(part : String) : Nil
  size0 = File.join(part, "#{CrystalClick::StreamName.hash("payload.size0")}.bin")
  raise "outer Array size stream should be nonempty" unless File.size(size0) > 0

  ["payload.size1", "payload.size", "payload"].each do |stream|
    path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")
    raise "all-empty child stream file missing: #{stream}" unless File.file?(path)
    raise "all-empty child stream #{stream} should be zero bytes, got #{File.size(path)}" unless File.size(path) == 0
  end
  nil
end

def w59_binary_string : String
  String.new(Bytes[0x61_u8, 0_u8, 0x62_u8])
end

def w59_large_string : String
  "x" * 5000
end

def w59_gap_rows : Array(Array(Array(String)))
  [
    [] of Array(String),
    [[] of String, [] of String],
    [] of Array(String),
    [] of Array(String),
    [["later", w59_binary_string, "é", w59_large_string]],
  ] of Array(Array(String))
end

def w59_empty_string_rows : Array(Array(Array(String)))
  [
    [] of Array(String),
    [[] of String, [] of String],
    [] of Array(String),
    [[""]],
    [["", "later", w59_binary_string, "é", w59_large_string]],
  ] of Array(Array(String))
end

def w59_all_empty_rows : Array(Array(Array(String)))
  Array(Array(Array(String))).new(5) { [] of Array(String) }
end

def w59_insert_sql(table : String) : String
  cast = "Array(Array(String))"
  case table
  when "gaps"
    <<-SQL
    INSERT INTO default.source_gaps VALUES
      (1, CAST([], '#{cast}')),
      (2, CAST([[], []], '#{cast}')),
      (3, CAST([], '#{cast}')),
      (4, CAST([], '#{cast}')),
      (5, CAST([['later', unhex('610062'), 'é', repeat('x', 5000)]], '#{cast}'))
    SQL
  when "empty_string"
    <<-SQL
    INSERT INTO default.source_empty_string VALUES
      (1, CAST([], '#{cast}')),
      (2, CAST([[], []], '#{cast}')),
      (3, CAST([], '#{cast}')),
      (4, CAST([['']], '#{cast}')),
      (5, CAST([['', 'later', unhex('610062'), 'é', repeat('x', 5000)]], '#{cast}'))
    SQL
  when "all_empty"
    <<-SQL
    INSERT INTO default.source_all_empty VALUES
      (1, CAST([], '#{cast}')),
      (2, CAST([], '#{cast}')),
      (3, CAST([], '#{cast}')),
      (4, CAST([], '#{cast}')),
      (5, CAST([], '#{cast}'))
    SQL
  else
    raise "unknown W59 source case #{table}"
  end
end

def w59_create_stock_source(binary : String, store : String, root : String, name : String) : String
  table = "source_#{name}"
  w59_clickhouse(binary, store, <<-SQL)
  CREATE TABLE default.#{table}
  (
      pk UInt64,
      payload Array(Array(String))
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
      default_compression_codec = 'LZ4'
  SQL
  w59_clickhouse(binary, store, w59_insert_sql(name))

  integrity = w59_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "stock producer CHECK TABLE failed for #{table}: #{integrity.inspect}" unless integrity == "all_1_1_0\t1"

  stock_path = w59_clickhouse(
    binary,
    store,
    "SELECT path FROM system.parts WHERE database = 'default' AND table = '#{table}' AND active FORMAT TSVRaw"
  ).strip
  raise "stock producer part missing for #{table}: #{stock_path.inspect}" unless Dir.exists?(stock_path)

  part = File.join(root, "stock-part-#{name}")
  FileUtils.cp_r(stock_path, part)
  w59_assert_stream_inventory(part)
  part
end

def w59_verify_stock_read(
  binary : String,
  store : String,
  part : String,
  name : String,
  rows : Array(Array(Array(String))),
) : Nil
  keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
  table = "source_#{name}"
  full = w59_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  w59_assert_rowbinary(full, w59_expected_rowbinary(keys, rows, [0_i32, 1_i32, 2_i32, 3_i32, 4_i32]), "stock #{name} full")
  ranged = w59_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} WHERE pk >= 2 AND pk < 5 ORDER BY pk FORMAT RowBinary")
  w59_assert_rowbinary(ranged, w59_expected_rowbinary(keys, rows, [1_i32, 2_i32, 3_i32]), "stock #{name} key range")

  reader = CrystalClick::WidePart.open_typed(part, "payload")
  raise "stock #{name} declared #{reader.column_type}, expected Array(Array(String))" unless reader.column_type == "Array(Array(String))"
  raise "stock #{name} mark rows mismatch: #{reader.mark_row_counts.inspect}" unless reader.mark_row_counts == [2_u64, 2_u64, 1_u64]

  all = reader.read_array_array_string_mark_range("payload", 0, reader.mark_count)
  raise "stock #{name} Crystal values differ" unless all == rows
  later = reader.read_array_array_string_mark_range("payload", 2, 1)
  raise "stock #{name} later-mark-only read differs" unless later == rows[4, 1]
  nil
end

def w59_attach_part(binary : String, store : String, table : String, part : String) : Nil
  w59_clickhouse(binary, store, <<-SQL)
  CREATE TABLE default.#{table}
  (
      pk UInt64,
      payload Array(Array(String))
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
      default_compression_codec = 'LZ4'
  SQL
  data_path = w59_clickhouse(
    binary,
    store,
    "SELECT data_paths[1] FROM system.tables WHERE database = 'default' AND name = '#{table}' FORMAT TSVRaw"
  ).strip
  raise "no ClickHouse data path for #{table}" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  w59_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")

  integrity = w59_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "Crystal writer CHECK TABLE failed for #{table}: #{integrity.inspect}" unless integrity == "all_1_1_0\t1"
  nil
end

def w59_verify_writer(
  binary : String,
  store : String,
  root : String,
  name : String,
  rows : Array(Array(Array(String))),
) : Nil
  keys = [1_u64, 2_u64, 4_u64, 7_u64, 10_u64]
  part = File.join(root, "writer-#{name}")
  CrystalClick::WidePartWriter.write_uint64_array_array_string_pair(
    part,
    "pk",
    keys.to_unsafe.to_slice(keys.size),
    "payload",
    rows.to_unsafe.to_slice(rows.size),
    rows_per_mark: 2
  )
  w59_assert_stream_inventory(part)
  case name
  when "gaps"
    w59_assert_zero_middle_child_mark(part)
  when "empty_string"
    w59_assert_empty_string_layout(part, false)
  when "all_empty"
    w59_assert_all_empty_child_streams(part)
  end

  table = "writer_#{name}"
  w59_attach_part(binary, store, table, part)
  full = w59_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  w59_assert_rowbinary(full, w59_expected_rowbinary(keys, rows, [0_i32, 1_i32, 2_i32, 3_i32, 4_i32]), "writer #{name} full")

  ranged = w59_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} WHERE pk >= 2 AND pk < 10 ORDER BY pk FORMAT RowBinary")
  w59_assert_rowbinary(ranged, w59_expected_rowbinary(keys, rows, [1_i32, 2_i32, 3_i32]), "writer #{name} key range")
  nil
end

binary = ENV.fetch("CLICKHOUSE_BIN")
store = ENV.fetch("CLICKHOUSE_STORE")
root = ENV.fetch("ORACLE_ROOT")
keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]

stock_cases = {
  "gaps"         => w59_gap_rows,
  "empty_string" => w59_empty_string_rows,
  "all_empty"    => w59_all_empty_rows,
}
stock_cases.each do |name, rows|
  part = w59_create_stock_source(binary, store, root, name)
  case name
  when "gaps"
    w59_assert_zero_middle_child_mark(part)
    w59_assert_stock_string_crosses_lz4_frame(part)
  when "empty_string"
    w59_assert_empty_string_layout(part, true)
  when "all_empty"
    w59_assert_all_empty_child_streams(part)
  end
  w59_verify_stock_read(binary, store, part, name, rows)
end

writer_cases = {
  "gaps"         => w59_gap_rows,
  "empty_string" => w59_empty_string_rows,
  "all_empty"    => w59_all_empty_rows,
}
writer_cases.each do |name, rows|
  w59_verify_writer(binary, store, root, name, rows)
end

puts "Array(Array(String)) stock oracle passed: ClickHouse 26.7.1.1315 producer/consumer, binary-safe String values, later-mark read, empty-child layouts, ATTACH PART/CHECK/full/key-range RowBinary"
