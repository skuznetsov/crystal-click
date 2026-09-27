require "file_utils"
require "../src/crystal_click"

alias W48_I8_ROWS = Array(Array(Int8))
alias W48_NI8_ROWS = Array(Array(Int8?))
alias W48_I16_ROWS = Array(Array(Int16))
alias W48_NI16_ROWS = Array(Array(Int16?))

W48_ORACLE_KEYS                     = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64]
W48_ALL_ROWS                        = [0_i32, 1_i32, 2_i32, 3_i32, 4_i32, 5_i32, 6_i32]
W48_KEYED_ROWS                      = [2_i32, 3_i32, 4_i32]
W48_ORACLE_ENUM8                    = "Enum8('min' = -128, 'neg' = -7, 'zero' = 0, 'pos' = 7, 'max' = 127)"
W48_ORACLE_ENUM16                   = "Enum16('min' = -32768, 'neg' = -300, 'zero' = 0, 'pos' = 300, 'max' = 32767)"
W48_ORACLE_ENUM8_NO_ZERO            = "Enum8('pos' = 7, 'neg' = -7)"
W48_ORACLE_ENUM16_NO_ZERO           = "Enum16('pos' = 300, 'neg' = -300)"
W48_ORACLE_ENUM8_NO_ZERO_CANONICAL  = "Enum8('neg' = -7, 'pos' = 7)"
W48_ORACLE_ENUM16_NO_ZERO_CANONICAL = "Enum16('neg' = -300, 'pos' = 300)"

W48_ORACLE_I8_ROWS = [
  [] of Int8, [-128_i8, -7_i8, 0_i8, 7_i8, 127_i8], [0_i8], [] of Int8,
  [0_i8, -7_i8], [127_i8], [] of Int8,
] of Array(Int8)
W48_ORACLE_NI8_ROWS = [
  [] of Int8?,
  [nil, 0_i8.as(Int8?), -128_i8.as(Int8?), 127_i8.as(Int8?), 7_i8.as(Int8?)] of Int8?,
  [nil, nil] of Int8?, [] of Int8?,
  [7_i8.as(Int8?), nil, 127_i8.as(Int8?)], [0_i8.as(Int8?), nil], [] of Int8?,
] of Array(Int8?)
W48_ORACLE_I16_ROWS = [
  [] of Int16, [-32_768_i16, -300_i16, 0_i16, 300_i16, 32_767_i16], [0_i16], [] of Int16,
  [0_i16, -300_i16], [32_767_i16], [] of Int16,
] of Array(Int16)
W48_ORACLE_NI16_ROWS = [
  [] of Int16?,
  [nil, 0_i16.as(Int16?), -32_768_i16.as(Int16?), 32_767_i16.as(Int16?), 300_i16.as(Int16?)] of Int16?,
  [nil, nil] of Int16?, [] of Int16?,
  [300_i16.as(Int16?), nil, 32_767_i16.as(Int16?)], [0_i16.as(Int16?), nil], [] of Int16?,
] of Array(Int16?)
W48_ORACLE_NO_ZERO_NI8_ROWS = [
  [] of Int8?, [nil, -7_i8.as(Int8?), 7_i8.as(Int8?)] of Int8?,
  [nil] of Int8?, [] of Int8?, [7_i8.as(Int8?), nil], [] of Int8?, [] of Int8?,
] of Array(Int8?)
W48_ORACLE_NO_ZERO_NI16_ROWS = [
  [] of Int16?, [nil, -300_i16.as(Int16?), 300_i16.as(Int16?)] of Int16?,
  [nil] of Int16?, [] of Int16?, [300_i16.as(Int16?), nil], [] of Int16?, [] of Int16?,
] of Array(Int16?)

# Literal ClickHouse signed little-endian leaf streams, separately duplicated
# from the spec and not derived from a writer or a server query result.
W48_ORACLE_I8_LEAVES   = [0x80_u8, 0xf9_u8, 0x00_u8, 0x07_u8, 0x7f_u8, 0x00_u8, 0x00_u8, 0xf9_u8, 0x7f_u8]
W48_ORACLE_NI8_LEAVES  = [0x80_u8, 0x00_u8, 0x80_u8, 0x7f_u8, 0x07_u8, 0x80_u8, 0x80_u8, 0x07_u8, 0x80_u8, 0x7f_u8, 0x00_u8, 0x80_u8]
W48_ORACLE_I16_LEAVES  = [0x00_u8, 0x80_u8, 0xd4_u8, 0xfe_u8, 0x00_u8, 0x00_u8, 0x2c_u8, 0x01_u8, 0xff_u8, 0x7f_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0xd4_u8, 0xfe_u8, 0xff_u8, 0x7f_u8]
W48_ORACLE_NI16_LEAVES = [0x00_u8, 0x80_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x80_u8, 0xff_u8, 0x7f_u8, 0x2c_u8, 0x01_u8, 0x00_u8, 0x80_u8, 0x00_u8, 0x80_u8, 0x2c_u8, 0x01_u8, 0x00_u8, 0x80_u8, 0xff_u8, 0x7f_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x80_u8]
W48_ORACLE_NULL_MAP    = [0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x01_u8, 0x01_u8, 0x00_u8, 0x01_u8, 0x00_u8, 0x00_u8, 0x01_u8]

def w48_clickhouse(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  result = Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse query failed (#{result.exit_code}): #{query}" unless result.success?
  output.to_s
end

def w48_append_u64_le(io : IO, value : UInt64) : Nil
  8.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
end

def w48_append_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

def w48_append_i8(io : IO, value : Int8) : Nil
  io.write_byte(value.unsafe_as(UInt8))
end

def w48_append_i16(io : IO, value : Int16) : Nil
  bits = value.unsafe_as(UInt16)
  io.write_byte((bits & 0xff_u16).to_u8)
  io.write_byte((bits >> 8).to_u8)
end

def w48_append_array_i8(io : IO, values : Array(Int8)) : Nil
  w48_append_varuint(io, values.size.to_u64)
  values.each { |value| w48_append_i8(io, value) }
end

def w48_append_nullable_i8(io : IO, values : Array(Int8?)) : Nil
  w48_append_varuint(io, values.size.to_u64)
  values.each do |value|
    if value.nil?
      io.write_byte(1_u8)
    else
      io.write_byte(0_u8)
      w48_append_i8(io, value.not_nil!)
    end
  end
end

def w48_append_array_i16(io : IO, values : Array(Int16)) : Nil
  w48_append_varuint(io, values.size.to_u64)
  values.each { |value| w48_append_i16(io, value) }
end

def w48_append_nullable_i16(io : IO, values : Array(Int16?)) : Nil
  w48_append_varuint(io, values.size.to_u64)
  values.each do |value|
    if value.nil?
      io.write_byte(1_u8)
    else
      io.write_byte(0_u8)
      w48_append_i16(io, value.not_nil!)
    end
  end
end

def w48_expected_stock_rows(selected : Array(Int32)) : Bytes
  io = IO::Memory.new
  selected.each do |row|
    w48_append_u64_le(io, W48_ORACLE_KEYS[row])
    w48_append_array_i8(io, W48_ORACLE_I8_ROWS[row])
    w48_append_nullable_i8(io, W48_ORACLE_NI8_ROWS[row])
    w48_append_array_i16(io, W48_ORACLE_I16_ROWS[row])
    w48_append_nullable_i16(io, W48_ORACLE_NI16_ROWS[row])
  end
  io.to_slice
end

def w48_expected_i8(keys : Array(UInt64), rows : W48_I8_ROWS, selected : Array(Int32)) : Bytes
  io = IO::Memory.new
  selected.each do |row|
    w48_append_u64_le(io, keys[row])
    w48_append_array_i8(io, rows[row])
  end
  io.to_slice
end

def w48_expected_ni8(keys : Array(UInt64), rows : W48_NI8_ROWS, selected : Array(Int32)) : Bytes
  io = IO::Memory.new
  selected.each do |row|
    w48_append_u64_le(io, keys[row])
    w48_append_nullable_i8(io, rows[row])
  end
  io.to_slice
end

def w48_expected_i16(keys : Array(UInt64), rows : W48_I16_ROWS, selected : Array(Int32)) : Bytes
  io = IO::Memory.new
  selected.each do |row|
    w48_append_u64_le(io, keys[row])
    w48_append_array_i16(io, rows[row])
  end
  io.to_slice
end

def w48_expected_ni16(keys : Array(UInt64), rows : W48_NI16_ROWS, selected : Array(Int32)) : Bytes
  io = IO::Memory.new
  selected.each do |row|
    w48_append_u64_le(io, keys[row])
    w48_append_nullable_i16(io, rows[row])
  end
  io.to_slice
end

def w48_assert_rowbinary(actual : String, expected : Bytes, label : String) : Nil
  got = actual.to_slice
  return if got == expected
  common = Math.min(got.size, expected.size)
  offset = 0
  while offset < common && got[offset] == expected[offset]
    offset += 1
  end
  wanted = offset < expected.size ? expected[offset].to_s(16).rjust(2, '0') : "<eof>"
  observed = offset < got.size ? got[offset].to_s(16).rjust(2, '0') : "<eof>"
  raise "#{label} RowBinary differs: expected #{expected.size} bytes, got #{got.size}; first difference at #{offset}: expected #{wanted}, got #{observed}"
end

def w48_decoded_stream(part : String, logical_name : String) : Array(UInt8)
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.bin")
  raise "missing stream #{logical_name}" unless File.file?(path)
  encoded = File.read(path).to_slice
  encoded.empty? ? [] of UInt8 : CrystalClick::CompressedBlock.decode_all(encoded).to_a
end

def w48_size_bytes(counts : Array(Int32)) : Array(UInt8)
  output = [] of UInt8
  counts.each do |count|
    size = count.to_u64
    8.times { |index| output << ((size >> (index * 8)) & 0xff_u64).to_u8 }
  end
  output
end

def w48_mark_rows(part : String, logical_name : String) : Array(UInt64)
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.mrk2")
  raw = File.read(path).to_slice
  raise "truncated marks for #{logical_name}" unless raw.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(UInt64).new(raw.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE + 16
    value = 0_u64
    8.times { |byte| value |= raw[offset + byte].to_u64 << (byte * 8) }
    value
  end
end

def w48_assert_equal(actual, expected, label : String) : Nil
  raise "#{label} differs: expected #{expected.inspect}, got #{actual.inspect}" unless actual == expected
end

def w48_attach_part(binary : String, store : String, table : String, schema : String, part : String) : Nil
  w48_clickhouse(binary, store, <<-SQL)
  CREATE TABLE default.#{table}
  (
      `pk` UInt64,
      #{schema}
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
      default_compression_codec = 'LZ4';
  SQL
  data_path = w48_clickhouse(binary, store, "SELECT data_paths[1] FROM system.tables WHERE database = 'default' AND name = '#{table}' FORMAT TSVRaw").strip
  raise "no ClickHouse data path for #{table}" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  w48_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  check = w48_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "CHECK TABLE failed for #{table}: #{check.inspect}" unless check == "all_1_1_0\t1"
  puts "CHECK TABLE #{table}: all_1_1_0\t1"
end

def w48_check_full_keyed(binary : String, store : String, table : String, columns : String, full : Bytes, keyed : Bytes) : Nil
  all = w48_clickhouse(binary, store, "SELECT pk, #{columns} FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  w48_assert_rowbinary(all, full, "#{table} full")
  keyed_actual = w48_clickhouse(binary, store, "SELECT pk, #{columns} FROM default.#{table} WHERE pk >= 4 AND pk < 11 ORDER BY pk FORMAT RowBinary")
  w48_assert_rowbinary(keyed_actual, keyed, "#{table} keyed")
  puts "RowBinary #{table}: full #{full.size} bytes exact; keyed #{keyed.size} bytes exact"
end

def w48_verify_stock_streams(part : String) : Nil
  expected_sizes_plain = w48_size_bytes([0, 5, 1, 0, 2, 1, 0])
  expected_sizes_nullable = w48_size_bytes([0, 5, 2, 0, 3, 2, 0])
  w48_assert_equal(w48_decoded_stream(part, "plain8.size0"), expected_sizes_plain, "Enum8 size0")
  w48_assert_equal(w48_decoded_stream(part, "maybe8.size0"), expected_sizes_nullable, "nullable Enum8 size0")
  w48_assert_equal(w48_decoded_stream(part, "plain16.size0"), expected_sizes_plain, "Enum16 size0")
  w48_assert_equal(w48_decoded_stream(part, "maybe16.size0"), expected_sizes_nullable, "nullable Enum16 size0")
  w48_assert_equal(w48_decoded_stream(part, "plain8"), W48_ORACLE_I8_LEAVES, "Enum8 signed LE leaf bytes")
  w48_assert_equal(w48_decoded_stream(part, "maybe8"), W48_ORACLE_NI8_LEAVES, "nullable Enum8 physical child bytes")
  w48_assert_equal(w48_decoded_stream(part, "plain16"), W48_ORACLE_I16_LEAVES, "Enum16 signed LE leaf bytes")
  w48_assert_equal(w48_decoded_stream(part, "maybe16"), W48_ORACLE_NI16_LEAVES, "nullable Enum16 physical child bytes")
  w48_assert_equal(w48_decoded_stream(part, "maybe8.null"), W48_ORACLE_NULL_MAP, "nullable Enum8 null map")
  w48_assert_equal(w48_decoded_stream(part, "maybe16.null"), W48_ORACLE_NULL_MAP, "nullable Enum16 null map")

  logical_streams = [
    "pk", "plain8.size0", "plain8", "maybe8.size0", "maybe8.null", "maybe8",
    "plain16.size0", "plain16", "maybe16.size0", "maybe16.null", "maybe16",
  ]
  logical_streams.each do |logical_name|
    w48_assert_equal(w48_mark_rows(part, logical_name), [2_u64, 2_u64, 2_u64, 1_u64, 0_u64], "#{logical_name} .mrk2 topology")
  end
  puts "Stock streams: literal signed LE Enum8/16 leaves, 12 NULL flags, and 16/24-byte nested slots verified"
end

def w48_stock_case(binary : String, store : String, fixture : String) : Nil
  w48_verify_stock_streams(fixture)
  schema = "plain8 Array(#{W48_ORACLE_ENUM8}), " +
           "maybe8 Array(Nullable(#{W48_ORACLE_ENUM8})), " +
           "plain16 Array(#{W48_ORACLE_ENUM16}), " +
           "maybe16 Array(Nullable(#{W48_ORACLE_ENUM16}))"
  w48_attach_part(binary, store, "w48_stock_four_shapes", schema, fixture)
  w48_check_full_keyed(
    binary, store, "w48_stock_four_shapes", "plain8, maybe8, plain16, maybe16",
    w48_expected_stock_rows(W48_ALL_ROWS), w48_expected_stock_rows(W48_KEYED_ROWS)
  )
end

def w48_stock_no_zero_control(binary : String, store : String) : String
  enum8_cast = "Enum8(\\'pos\\' = 7, \\'neg\\' = -7)"
  enum16_cast = "Enum16(\\'pos\\' = 300, \\'neg\\' = -300)"
  w48_clickhouse(binary, store, <<-SQL)
  CREATE TABLE default.w48_stock_no_zero_source
  (
      `pk` UInt64,
      `payload8` Array(Nullable(#{W48_ORACLE_ENUM8_NO_ZERO})),
      `payload16` Array(Nullable(#{W48_ORACLE_ENUM16_NO_ZERO}))
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
      default_compression_codec = 'LZ4';
  SQL

  w48_clickhouse(binary, store, <<-SQL)
  INSERT INTO default.w48_stock_no_zero_source VALUES
      (1, CAST([], 'Array(Nullable(#{enum8_cast}))'), CAST([], 'Array(Nullable(#{enum16_cast}))')),
      (2, CAST([NULL, 'neg', 'pos'], 'Array(Nullable(#{enum8_cast}))'), CAST([NULL, 'neg', 'pos'], 'Array(Nullable(#{enum16_cast}))')),
      (4, CAST([NULL], 'Array(Nullable(#{enum8_cast}))'), CAST([NULL], 'Array(Nullable(#{enum16_cast}))')),
      (6, CAST([], 'Array(Nullable(#{enum8_cast}))'), CAST([], 'Array(Nullable(#{enum16_cast}))')),
      (9, CAST(['pos', NULL], 'Array(Nullable(#{enum8_cast}))'), CAST(['pos', NULL], 'Array(Nullable(#{enum16_cast}))')),
      (11, CAST([], 'Array(Nullable(#{enum8_cast}))'), CAST([], 'Array(Nullable(#{enum16_cast}))')),
      (13, CAST([], 'Array(Nullable(#{enum8_cast}))'), CAST([], 'Array(Nullable(#{enum16_cast}))'));
  SQL

  part = w48_clickhouse(
    binary, store,
    "SELECT path FROM system.parts WHERE table = 'w48_stock_no_zero_source' AND active FORMAT TSVRaw"
  ).strip
  raise "ClickHouse stock no-zero part is absent" if part.empty?
  check = w48_clickhouse(binary, store, "CHECK TABLE default.w48_stock_no_zero_source FORMAT TabSeparated").strip
  w48_assert_equal(check, "all_1_1_0\t1", "stock no-zero CAST CHECK TABLE")

  columns = File.read(File.join(part, "columns.txt"))
  w48_assert_equal(columns.includes?("`payload8` Array(Nullable(Enum8('neg' = -7, 'pos' = 7)))"), true, "stock Enum8 numeric canonical order")
  w48_assert_equal(columns.includes?("`payload16` Array(Nullable(Enum16('neg' = -300, 'pos' = 300)))"), true, "stock Enum16 numeric canonical order")

  expected_enum8 = [0xf9_u8, 0xf9_u8, 0x07_u8, 0xf9_u8, 0x07_u8, 0xf9_u8]
  expected_enum16 = [0xd4_u8, 0xfe_u8, 0xd4_u8, 0xfe_u8, 0x2c_u8, 0x01_u8, 0xd4_u8, 0xfe_u8, 0x2c_u8, 0x01_u8, 0xd4_u8, 0xfe_u8]
  null_map = [1_u8, 0_u8, 0_u8, 1_u8, 0_u8, 1_u8]
  size_bytes = w48_size_bytes([0, 3, 1, 0, 2, 0, 0])
  w48_assert_equal(w48_decoded_stream(part, "payload8.size0"), size_bytes, "stock no-zero Enum8 sizes")
  w48_assert_equal(w48_decoded_stream(part, "payload8.null"), null_map, "stock no-zero Enum8 null map")
  stock_enum8 = w48_decoded_stream(part, "payload8")
  w48_assert_equal(stock_enum8, expected_enum8, "stock no-zero Enum8 physical hidden child bytes")
  w48_assert_equal(w48_decoded_stream(part, "payload16.size0"), size_bytes, "stock no-zero Enum16 sizes")
  w48_assert_equal(w48_decoded_stream(part, "payload16.null"), null_map, "stock no-zero Enum16 null map")
  stock_enum16 = w48_decoded_stream(part, "payload16")
  w48_assert_equal(stock_enum16, expected_enum16, "stock no-zero Enum16 physical hidden child bytes")

  logical_streams = ["pk", "payload8.size0", "payload8.null", "payload8", "payload16.size0", "payload16.null", "payload16"]
  logical_streams.each do |logical_name|
    w48_assert_equal(w48_mark_rows(part, logical_name), [2_u64, 2_u64, 2_u64, 1_u64, 0_u64], "stock no-zero #{logical_name} .mrk2 topology")
  end
  w48_check_full_keyed(
    binary, store, "w48_stock_no_zero_source", "payload8",
    w48_expected_ni8(W48_ORACLE_KEYS, W48_ORACLE_NO_ZERO_NI8_ROWS, W48_ALL_ROWS),
    w48_expected_ni8(W48_ORACLE_KEYS, W48_ORACLE_NO_ZERO_NI8_ROWS, W48_KEYED_ROWS)
  )
  w48_check_full_keyed(
    binary, store, "w48_stock_no_zero_source", "payload16",
    w48_expected_ni16(W48_ORACLE_KEYS, W48_ORACLE_NO_ZERO_NI16_ROWS, W48_ALL_ROWS),
    w48_expected_ni16(W48_ORACLE_KEYS, W48_ORACLE_NO_ZERO_NI16_ROWS, W48_KEYED_ROWS)
  )
  puts "Stock no-zero CAST control: Enum8 NULL child f9; Enum16 NULL child d4 fe; canonical declarations sort by numeric code"
  part
end

def w48_writer_part(root : String, name : String) : String
  part = File.join(root, name, "all_1_1_0")
  FileUtils.mkdir_p(File.dirname(part))
  part
end

def w48_write_plain8(part : String, keys : Array(UInt64), rows : W48_I8_ROWS) : String
  CrystalClick::WidePartWriter.write_uint64_array_enum8_pair(
    part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", rows.to_unsafe.to_slice(rows.size),
    W48_ORACLE_ENUM8, rows_per_mark: 2
  )
  part
end

def w48_write_nullable8(part : String, keys : Array(UInt64), rows : W48_NI8_ROWS, enum_type : String = W48_ORACLE_ENUM8) : String
  CrystalClick::WidePartWriter.write_uint64_array_nullable_enum8_pair(
    part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", rows.to_unsafe.to_slice(rows.size),
    enum_type, rows_per_mark: 2
  )
  part
end

def w48_write_plain16(part : String, keys : Array(UInt64), rows : W48_I16_ROWS) : String
  CrystalClick::WidePartWriter.write_uint64_array_enum16_pair(
    part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", rows.to_unsafe.to_slice(rows.size),
    W48_ORACLE_ENUM16, rows_per_mark: 2
  )
  part
end

def w48_write_nullable16(part : String, keys : Array(UInt64), rows : W48_NI16_ROWS) : String
  CrystalClick::WidePartWriter.write_uint64_array_nullable_enum16_pair(
    part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", rows.to_unsafe.to_slice(rows.size),
    W48_ORACLE_ENUM16, rows_per_mark: 2
  )
  part
end

def w48_assert_writer_marks(part : String) : Nil
  ["pk", "payload.size0", "payload", "payload.null"].each do |logical_name|
    next if logical_name == "payload.null" && !File.file?(File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.mrk2"))
    w48_assert_equal(w48_mark_rows(part, logical_name), [2_u64, 2_u64, 2_u64, 1_u64, 0_u64], "writer #{logical_name} .mrk2 topology")
  end
end

def w48_attach_writer_plain8(binary : String, store : String, table : String, part : String, keys : Array(UInt64), rows : W48_I8_ROWS, indices : Array(Int32)) : Nil
  w48_attach_part(binary, store, table, "payload Array(#{W48_ORACLE_ENUM8})", part)
  w48_check_full_keyed(binary, store, table, "payload", w48_expected_i8(keys, rows, W48_ALL_ROWS), w48_expected_i8(keys, rows, indices))
  w48_assert_equal(w48_decoded_stream(part, "payload"), rows == W48_ORACLE_I8_ROWS ? W48_ORACLE_I8_LEAVES : rows.flat_map { |row| row.map { |v| v.unsafe_as(UInt8) } }, "writer Enum8 leaves")
  w48_assert_writer_marks(part)
end

def w48_attach_writer_nullable8(binary : String, store : String, table : String, part : String, keys : Array(UInt64), rows : W48_NI8_ROWS, indices : Array(Int32)) : Nil
  w48_attach_part(binary, store, table, "payload Array(Nullable(#{W48_ORACLE_ENUM8}))", part)
  w48_check_full_keyed(binary, store, table, "payload", w48_expected_ni8(keys, rows, W48_ALL_ROWS), w48_expected_ni8(keys, rows, indices))
  w48_assert_writer_marks(part)
end

def w48_attach_writer_plain16(binary : String, store : String, table : String, part : String, keys : Array(UInt64), rows : W48_I16_ROWS, indices : Array(Int32)) : Nil
  w48_attach_part(binary, store, table, "payload Array(#{W48_ORACLE_ENUM16})", part)
  w48_check_full_keyed(binary, store, table, "payload", w48_expected_i16(keys, rows, W48_ALL_ROWS), w48_expected_i16(keys, rows, indices))
  w48_assert_writer_marks(part)
end

def w48_attach_writer_nullable16(binary : String, store : String, table : String, part : String, keys : Array(UInt64), rows : W48_NI16_ROWS, indices : Array(Int32)) : Nil
  w48_attach_part(binary, store, table, "payload Array(Nullable(#{W48_ORACLE_ENUM16}))", part)
  w48_check_full_keyed(binary, store, table, "payload", w48_expected_ni16(keys, rows, W48_ALL_ROWS), w48_expected_ni16(keys, rows, indices))
  w48_assert_writer_marks(part)
end

def w48_writer_cases(binary : String, store : String, root : String) : Nil
  plain8_part = w48_write_plain8(w48_writer_part(root, "plain8"), W48_ORACLE_KEYS, W48_ORACLE_I8_ROWS)
  w48_attach_writer_plain8(binary, store, "w48_writer_plain8", plain8_part, W48_ORACLE_KEYS, W48_ORACLE_I8_ROWS, W48_KEYED_ROWS)

  maybe8_part = w48_write_nullable8(w48_writer_part(root, "maybe8"), W48_ORACLE_KEYS, W48_ORACLE_NI8_ROWS)
  w48_attach_writer_nullable8(binary, store, "w48_writer_nullable8", maybe8_part, W48_ORACLE_KEYS, W48_ORACLE_NI8_ROWS, W48_KEYED_ROWS)
  w48_assert_equal(w48_decoded_stream(maybe8_part, "payload.null"), W48_ORACLE_NULL_MAP, "writer nullable Enum8 null map")
  w48_assert_equal(w48_decoded_stream(maybe8_part, "payload"), W48_ORACLE_NI8_LEAVES, "writer nullable Enum8 child slots")

  plain16_part = w48_write_plain16(w48_writer_part(root, "plain16"), W48_ORACLE_KEYS, W48_ORACLE_I16_ROWS)
  w48_attach_writer_plain16(binary, store, "w48_writer_plain16", plain16_part, W48_ORACLE_KEYS, W48_ORACLE_I16_ROWS, W48_KEYED_ROWS)
  w48_assert_equal(w48_decoded_stream(plain16_part, "payload"), W48_ORACLE_I16_LEAVES, "writer Enum16 leaves")

  maybe16_part = w48_write_nullable16(w48_writer_part(root, "maybe16"), W48_ORACLE_KEYS, W48_ORACLE_NI16_ROWS)
  w48_attach_writer_nullable16(binary, store, "w48_writer_nullable16", maybe16_part, W48_ORACLE_KEYS, W48_ORACLE_NI16_ROWS, W48_KEYED_ROWS)
  w48_assert_equal(w48_decoded_stream(maybe16_part, "payload.null"), W48_ORACLE_NULL_MAP, "writer nullable Enum16 null map")
  w48_assert_equal(w48_decoded_stream(maybe16_part, "payload"), W48_ORACLE_NI16_LEAVES, "writer nullable Enum16 child slots")

  empty8 = Array.new(W48_ORACLE_KEYS.size) { [] of Int8 }
  empty8_part = w48_write_plain8(w48_writer_part(root, "empty8"), W48_ORACLE_KEYS, empty8)
  w48_attach_writer_plain8(binary, store, "w48_empty8", empty8_part, W48_ORACLE_KEYS, empty8, W48_KEYED_ROWS)
  w48_assert_equal(w48_decoded_stream(empty8_part, "payload").empty?, true, "all-empty Enum8 child stream")

  empty_nullable8 = Array.new(W48_ORACLE_KEYS.size) { [] of Int8? }
  empty_nullable8_part = w48_write_nullable8(w48_writer_part(root, "empty-nullable8"), W48_ORACLE_KEYS, empty_nullable8)
  w48_attach_writer_nullable8(binary, store, "w48_empty_nullable8", empty_nullable8_part, W48_ORACLE_KEYS, empty_nullable8, W48_KEYED_ROWS)
  w48_assert_equal(w48_decoded_stream(empty_nullable8_part, "payload").empty?, true, "all-empty nullable Enum8 child stream")
  w48_assert_equal(w48_decoded_stream(empty_nullable8_part, "payload.null").empty?, true, "all-empty nullable Enum8 null stream")

  empty16 = Array.new(W48_ORACLE_KEYS.size) { [] of Int16 }
  empty16_part = w48_write_plain16(w48_writer_part(root, "empty16"), W48_ORACLE_KEYS, empty16)
  w48_attach_writer_plain16(binary, store, "w48_empty16", empty16_part, W48_ORACLE_KEYS, empty16, W48_KEYED_ROWS)
  w48_assert_equal(w48_decoded_stream(empty16_part, "payload").empty?, true, "all-empty Enum16 child stream")

  empty_nullable16 = Array.new(W48_ORACLE_KEYS.size) { [] of Int16? }
  empty_nullable16_part = w48_write_nullable16(w48_writer_part(root, "empty-nullable16"), W48_ORACLE_KEYS, empty_nullable16)
  w48_attach_writer_nullable16(binary, store, "w48_empty_nullable16", empty_nullable16_part, W48_ORACLE_KEYS, empty_nullable16, W48_KEYED_ROWS)
  w48_assert_equal(w48_decoded_stream(empty_nullable16_part, "payload").empty?, true, "all-empty nullable Enum16 child stream")
  w48_assert_equal(w48_decoded_stream(empty_nullable16_part, "payload.null").empty?, true, "all-empty nullable Enum16 null stream")

  all_null8 = Array.new(W48_ORACLE_KEYS.size) { [nil, nil] of Int8? }
  all_null8_part = w48_write_nullable8(w48_writer_part(root, "all-null8"), W48_ORACLE_KEYS, all_null8)
  w48_attach_writer_nullable8(binary, store, "w48_all_null8", all_null8_part, W48_ORACLE_KEYS, all_null8, W48_KEYED_ROWS)
  w48_assert_equal(w48_decoded_stream(all_null8_part, "payload.null"), Array.new(W48_ORACLE_KEYS.size * 2, 1_u8), "all-NULL Enum8 null map")
  w48_assert_equal(w48_decoded_stream(all_null8_part, "payload"), Array.new(W48_ORACLE_KEYS.size * 2, 0x80_u8), "all-NULL Enum8 physical children")

  all_null16 = Array.new(W48_ORACLE_KEYS.size) { [nil, nil] of Int16? }
  all_null16_part = w48_write_nullable16(w48_writer_part(root, "all-null16"), W48_ORACLE_KEYS, all_null16)
  w48_attach_writer_nullable16(binary, store, "w48_all_null16", all_null16_part, W48_ORACLE_KEYS, all_null16, W48_KEYED_ROWS)
  w48_assert_equal(w48_decoded_stream(all_null16_part, "payload.null"), Array.new(W48_ORACLE_KEYS.size * 2, 1_u8), "all-NULL Enum16 null map")
  all_null16_defaults = Array.new(W48_ORACLE_KEYS.size * 2) { [0x00_u8, 0x80_u8] }.flatten
  w48_assert_equal(w48_decoded_stream(all_null16_part, "payload"), all_null16_defaults, "all-NULL Enum16 physical children")

  # Zero is deliberately absent and declarations are deliberately unsorted.
  # Stock canonicalizes by numeric code and uses the minimum code under NULL.
  stock_no_zero_part = w48_stock_no_zero_control(binary, store)
  no_zero_rows = W48_ORACLE_NO_ZERO_NI8_ROWS
  no_zero_part = w48_write_nullable8(w48_writer_part(root, "no-zero-enum8"), W48_ORACLE_KEYS, no_zero_rows, W48_ORACLE_ENUM8_NO_ZERO)
  no_zero_columns = File.read(File.join(no_zero_part, "columns.txt"))
  w48_assert_equal(no_zero_columns.includes?("`payload` Array(Nullable(#{W48_ORACLE_ENUM8_NO_ZERO_CANONICAL}))"), true, "Crystal no-zero Enum8 canonical columns.txt")
  w48_attach_part(binary, store, "w48_writer_no_zero_enum8", "payload Array(Nullable(#{W48_ORACLE_ENUM8_NO_ZERO}))", no_zero_part)
  w48_check_full_keyed(
    binary, store, "w48_writer_no_zero_enum8", "payload",
    w48_expected_ni8(W48_ORACLE_KEYS, no_zero_rows, W48_ALL_ROWS),
    w48_expected_ni8(W48_ORACLE_KEYS, no_zero_rows, W48_KEYED_ROWS)
  )
  w48_assert_equal(w48_decoded_stream(no_zero_part, "payload.null"), [1_u8, 0_u8, 0_u8, 1_u8, 0_u8, 1_u8], "no-zero nullable Enum8 null map")
  no_zero_leaf = w48_decoded_stream(no_zero_part, "payload")
  w48_assert_equal(no_zero_leaf, [0xf9_u8, 0xf9_u8, 0x07_u8, 0xf9_u8, 0x07_u8, 0xf9_u8], "no-zero nullable Enum8 minimum-code child slots")
  w48_assert_equal(no_zero_leaf, w48_decoded_stream(stock_no_zero_part, "payload8"), "no-zero Enum8 stock physical byte parity")
  w48_assert_writer_marks(no_zero_part)

  no_zero16_rows = W48_ORACLE_NO_ZERO_NI16_ROWS
  no_zero16_part = w48_writer_part(root, "no-zero-enum16")
  CrystalClick::WidePartWriter.write_uint64_array_nullable_enum16_pair(
    no_zero16_part, "pk", W48_ORACLE_KEYS.to_unsafe.to_slice(W48_ORACLE_KEYS.size), "payload",
    no_zero16_rows.to_unsafe.to_slice(no_zero16_rows.size), W48_ORACLE_ENUM16_NO_ZERO, rows_per_mark: 2
  )
  no_zero16_columns = File.read(File.join(no_zero16_part, "columns.txt"))
  w48_assert_equal(no_zero16_columns.includes?("`payload` Array(Nullable(#{W48_ORACLE_ENUM16_NO_ZERO_CANONICAL}))"), true, "Crystal no-zero Enum16 canonical columns.txt")
  w48_attach_part(binary, store, "w48_writer_no_zero_enum16", "payload Array(Nullable(#{W48_ORACLE_ENUM16_NO_ZERO}))", no_zero16_part)
  w48_check_full_keyed(
    binary, store, "w48_writer_no_zero_enum16", "payload",
    w48_expected_ni16(W48_ORACLE_KEYS, no_zero16_rows, W48_ALL_ROWS),
    w48_expected_ni16(W48_ORACLE_KEYS, no_zero16_rows, W48_KEYED_ROWS)
  )
  no_zero16_leaf = w48_decoded_stream(no_zero16_part, "payload")
  w48_assert_equal(no_zero16_leaf, [0xd4_u8, 0xfe_u8, 0xd4_u8, 0xfe_u8, 0x2c_u8, 0x01_u8, 0xd4_u8, 0xfe_u8, 0x2c_u8, 0x01_u8, 0xd4_u8, 0xfe_u8], "no-zero nullable Enum16 minimum-code child slots")
  w48_assert_equal(no_zero16_leaf, w48_decoded_stream(stock_no_zero_part, "payload16"), "no-zero Enum16 stock physical byte parity")
  w48_assert_writer_marks(no_zero16_part)
  puts "Crystal controls: four all-empty parts, both-width all-NULL parts, and no-zero Enum8/16 passed stock checks"
end

binary = ENV["CLICKHOUSE_BIN"]? || "/Users/sergey/.local/bin/clickhouse"
store = ENV["TMP_ROOT"]? || raise "TMP_ROOT is required"
fixture = File.expand_path("../test/fixtures/public/wide_array_enum_w48/part", __DIR__)
unless File.file?(fixture + "/columns.txt")
  raise "W48 fixture is absent; run scripts/generate_public_wide_array_enum_w48_fixture.sh"
end
expected_version = "ClickHouse local version 26.7.1.1315 (official build)."
version_output = IO::Memory.new
version_status = Process.run(binary, ["local", "--version"], output: version_output, error: Process::Redirect::Inherit)
raise "unable to inspect ClickHouse version" unless version_status.success?
raise "oracle requires #{expected_version}, got #{version_output}" unless version_output.to_s.strip == expected_version

stock_store = File.join(store, "stock-store")
writer_store = File.join(store, "writer-store")
writer_root = File.join(store, "writer-parts")
FileUtils.mkdir_p(writer_root)
w48_stock_case(binary, stock_store, fixture)
w48_writer_cases(binary, writer_store, writer_root)
puts "W48 bidirectional stock oracle passed: pinned fixture, stock no-zero CAST control, and twelve Crystal parts"
