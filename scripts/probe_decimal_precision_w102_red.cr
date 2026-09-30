# W102 stock-first RED probe for arbitrary Decimal(P, S) in the six admitted
# scalar/Nullable/Array shapes. Every stock fixture is independently
# qualified before the unchanged typed-reader gate is expected to reject the
# lower-than-maximum precision declarations.
require "json"
require "../src/crystal_click"

W102_STOCK_VERSION = "26.7.1.1315"
W102_EXPECTED_HEAD = "bab43e5924f2807c9bf5902ccc2605f10664d178"
W102_KEYS          = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
W102_MARK_ROWS     = [2_u64, 2_u64, 1_u64, 0_u64]
W102_INTERIOR_PS   = [7, 15, 25, 50]

alias W102Row = Array(Array(String?))
alias W102Rows = Array(W102Row)

struct W102Shape
  getter id : Int32
  getter label : String

  def initialize(@id : Int32, @label : String)
  end

  def type_name(precision : Int32, scale : Int32) : String
    leaf = "Decimal(#{precision}, #{scale})"
    case @id
    when 0 then leaf
    when 1 then "Nullable(#{leaf})"
    when 2 then "Array(#{leaf})"
    when 3 then "Array(Nullable(#{leaf}))"
    when 4 then "Array(Array(#{leaf}))"
    when 5 then "Array(Array(Nullable(#{leaf})))"
    else        raise "unknown W102 shape #{@id}"
    end
  end

  def payload_streams : Array(String)
    case @id
    when 0 then ["payload"]
    when 1 then ["payload.null", "payload"]
    when 2 then ["payload.size0", "payload"]
    when 3 then ["payload.size0", "payload.null", "payload"]
    when 4 then ["payload.size0", "payload.size1", "payload"]
    when 5 then ["payload.size0", "payload.size1", "payload.null", "payload"]
    else        raise "unknown W102 shape #{@id}"
    end
  end

  def nullable_leaf? : Bool
    @id == 1 || @id == 3 || @id == 5
  end

  def depth : Int32
    case @id
    when 0, 1 then 0
    when 2, 3 then 1
    when 4, 5 then 2
    else           raise "unknown W102 shape #{@id}"
    end
  end
end

W102_SHAPES = [
  W102Shape.new(0, "scalar"),
  W102Shape.new(1, "nullable_scalar"),
  W102Shape.new(2, "array"),
  W102Shape.new(3, "array_nullable"),
  W102Shape.new(4, "array_array"),
  W102Shape.new(5, "array_array_nullable"),
]

struct W102Fixture
  getter label : String
  getter shape : W102Shape
  getter precision : Int32
  getter scale : Int32
  getter width : Int32
  getter rows : W102Rows

  def initialize(
    @label : String,
    @shape : W102Shape,
    @precision : Int32,
    @scale : Int32,
    @width : Int32,
    rows : W102Rows,
  )
    raise "#{@label}: fixture needs five rows" unless rows.size == W102_KEYS.size
    @rows = rows.map do |row|
      row.map(&.dup)
    end
  end

  def type_name : String
    @shape.type_name(@precision, @scale)
  end

  def table_name : String
    "w102_#{@label}"
  end

  def streams : Array(String)
    ["pk"] + @shape.payload_streams
  end
end

class W102ByteMismatchError < Exception
end

private def w102_le_u64(value : UInt64) : String
  output = IO::Memory.new
  8.times { |index| output.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
  output.to_s
end

private def w102_append_u64(io : IO, value : UInt64) : Nil
  8.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
end

private def w102_append_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w102_string_from_bytes(bytes : Array(UInt8)) : String
  return "" if bytes.empty?
  String.new(bytes.to_unsafe, bytes.size)
end

private def w102_decimal_max_bytes(precision : Int32, width : Int32) : Array(UInt8)
  bytes = Array(UInt8).new(width, 0_u8)
  precision.times do
    carry = 9_u16
    bytes.each_index do |index|
      value = bytes[index].to_u16 * 10_u16 + carry
      bytes[index] = (value & 0xff_u16).to_u8
      carry = value >> 8
    end
    raise "W102 P=#{precision} does not fit #{width} bytes" unless carry == 0
  end
  bytes
end

private def w102_decimal_digits(bytes : Array(UInt8)) : String
  quotient = bytes.dup
  digits = ""
  loop do
    remainder = 0_u32
    index = quotient.size - 1
    while index >= 0
      current = (remainder << 8) | quotient[index].to_u32
      quotient[index] = (current // 10_u32).to_u8
      remainder = current % 10_u32
      index -= 1
    end
    digits = remainder.to_s + digits
    break if quotient.all?(&.==(0_u8))
  end
  digits
end

private def w102_negate(positive : Array(UInt8)) : Array(UInt8)
  negative = positive.map { |byte| ~byte }
  carry = 1_u16
  negative.each_index do |index|
    value = negative[index].to_u16 + carry
    negative[index] = (value & 0xff_u16).to_u8
    carry = value >> 8
  end
  raise "W102 two's-complement negation overflow" unless carry == 0
  negative
end

private def w102_coefficients(precision : Int32, width : Int32) : Array(String)
  maximum = w102_decimal_max_bytes(precision, width)
  raise "W102 maximum coefficient decimal conversion differs" unless w102_decimal_digits(maximum) == "9" * precision
  negative_maximum = w102_negate(maximum)
  negative_one = Array(UInt8).new(width, 0xff_u8)
  zero = Array(UInt8).new(width, 0_u8)
  positive_one = Array(UInt8).new(width, 0_u8)
  positive_one[0] = 1_u8
  raise "W102 negative-one byte control differs" unless negative_one.all?(&.==(0xff_u8))
  raise "W102 zero byte control differs" unless zero.all?(&.==(0_u8))
  raise "W102 positive-one byte control differs" unless positive_one[0] == 1_u8 && positive_one[1..].all?(&.==(0_u8))
  [negative_maximum, negative_one, zero, positive_one, maximum].map { |bytes| w102_string_from_bytes(bytes) }
end

private def w102_build_rows(shape : W102Shape, coefficients : Array(String)) : W102Rows
  negative_maximum, negative_one, zero, positive_one, maximum = coefficients
  rows = [] of W102Row
  case shape.id
  when 0
    rows << [[negative_maximum.as(String?)]]
    rows << [[negative_one.as(String?)]]
    rows << [[zero.as(String?)]]
    rows << [[positive_one.as(String?)]]
    rows << [[maximum.as(String?)]]
  when 1
    rows << [[negative_maximum.as(String?)]]
    rows << [[nil] of String?]
    rows << [[zero.as(String?)]]
    rows << [[positive_one.as(String?)]]
    rows << [[maximum.as(String?)]]
  when 2
    rows << [[] of String?]
    rows << [[negative_maximum.as(String?), maximum.as(String?)]]
    rows << [[zero.as(String?)]]
    rows << [[positive_one.as(String?)]]
    rows << [[negative_one.as(String?), maximum.as(String?)]]
  when 3
    rows << [[] of String?]
    rows << [[negative_maximum.as(String?), nil, maximum.as(String?)]]
    rows << [[nil, nil] of String?]
    rows << [[zero.as(String?)]]
    rows << [[positive_one.as(String?), negative_one.as(String?)]]
  when 4
    rows << ([] of Array(String?))
    rows << [([] of String?), [negative_maximum.as(String?), maximum.as(String?)]]
    rows << [([] of String?)]
    rows << [[zero.as(String?)], ([] of String?)]
    rows << [[positive_one.as(String?), negative_one.as(String?)]]
  when 5
    rows << ([] of Array(String?))
    rows << [([] of String?), [negative_maximum.as(String?), nil, maximum.as(String?)]]
    rows << [([] of String?)]
    rows << [[nil, nil] of String?, [zero.as(String?)]]
    rows << [[positive_one.as(String?), negative_one.as(String?)]]
  else
    raise "unknown W102 shape #{shape.id}"
  end
  rows
end

private def w102_width(precision : Int32) : Int32
  case precision
  when 1..9   then 4
  when 10..18 then 8
  when 19..38 then 16
  when 39..76 then 32
  else             raise "invalid W102 precision #{precision}"
  end
end

private def w102_scale(precision : Int32, shape : W102Shape) : Int32
  case shape.id % 3
  when 0 then 0
  when 1 then precision // 2
  else        precision
  end
end

private def w102_fixture(shape : W102Shape, precision : Int32, label : String) : W102Fixture
  width = w102_width(precision)
  scale = w102_scale(precision, shape)
  coefficients = w102_coefficients(precision, width)
  W102Fixture.new(label, shape, precision, scale, width, w102_build_rows(shape, coefficients))
end

private def w102_required(value : String?, label : String) : String
  value || raise "#{label}: unexpected NULL in non-null Decimal profile"
end

private def w102_append_nullable_input(io : IO, value : String?) : Nil
  if value.nil?
    io.write_byte(1_u8)
  else
    io.write_byte(0_u8)
    io << value.not_nil!
  end
end

private def w102_append_insert_payload(io : IO, fixture : W102Fixture, row : W102Row) : Nil
  case fixture.shape.id
  when 0
    io << w102_required(row[0][0], fixture.label)
  when 1
    w102_append_nullable_input(io, row[0][0])
  when 2
    leaves = row[0]
    w102_append_varuint(io, leaves.size.to_u64)
    leaves.each { |value| io << w102_required(value, fixture.label) }
  when 3
    leaves = row[0]
    w102_append_varuint(io, leaves.size.to_u64)
    leaves.each { |value| w102_append_nullable_input(io, value) }
  when 4
    w102_append_varuint(io, row.size.to_u64)
    row.each do |inner|
      w102_append_varuint(io, inner.size.to_u64)
      inner.each { |value| io << w102_required(value, fixture.label) }
    end
  when 5
    w102_append_varuint(io, row.size.to_u64)
    row.each do |inner|
      w102_append_varuint(io, inner.size.to_u64)
      inner.each { |value| w102_append_nullable_input(io, value) }
    end
  else
    raise "unknown W102 shape #{fixture.shape.id}"
  end
end

private def w102_rowbinary_input(fixture : W102Fixture) : String
  output = IO::Memory.new
  W102_KEYS.each_with_index do |key, index|
    w102_append_u64(output, key)
    w102_append_insert_payload(output, fixture, fixture.rows[index])
  end
  output.to_s
end

private def w102_append_expected_nullable(io : IO, value : String?) : Nil
  if value.nil?
    io.write_byte(1_u8)
  else
    io.write_byte(0_u8)
    io << value.not_nil!
  end
end

private def w102_append_expected_value(io : IO, fixture : W102Fixture, row : W102Row) : Nil
  case fixture.shape.id
  when 0
    io << row[0][0].not_nil!
  when 1
    w102_append_expected_nullable(io, row[0][0])
  when 2
    values = row[0]
    w102_append_varuint(io, values.size.to_u64)
    values.each { |value| io << value.not_nil! }
  when 3
    values = row[0]
    w102_append_varuint(io, values.size.to_u64)
    values.each { |value| w102_append_expected_nullable(io, value) }
  when 4
    w102_append_varuint(io, row.size.to_u64)
    row.each do |inner|
      w102_append_varuint(io, inner.size.to_u64)
      inner.each { |value| io << value.not_nil! }
    end
  when 5
    w102_append_varuint(io, row.size.to_u64)
    row.each do |inner|
      w102_append_varuint(io, inner.size.to_u64)
      inner.each { |value| w102_append_expected_nullable(io, value) }
    end
  else
    raise "unknown W102 shape #{fixture.shape.id}"
  end
end

private def w102_expected_rowbinary(fixture : W102Fixture, indexes : Array(Int32)) : String
  output = IO::Memory.new
  indexes.each do |index|
    w102_append_u64(output, W102_KEYS[index])
    w102_append_expected_value(output, fixture, fixture.rows[index])
  end
  output.to_s
end

private def w102_append_zero_coefficient(io : IO, width : Int32) : Nil
  width.times { io.write_byte(0_u8) }
end

private def w102_append_physical_value(io : IO, value : String?, width : Int32) : Nil
  if value.nil?
    w102_append_zero_coefficient(io, width)
  else
    io << value.not_nil!
  end
end

private def w102_expected_physical_streams(fixture : W102Fixture) : Hash(String, String)
  streams = Hash(String, String).new
  streams["pk"] = W102_KEYS.map { |key| w102_le_u64(key) }.join
  payload = IO::Memory.new
  null_map = IO::Memory.new
  size0 = IO::Memory.new
  size1 = IO::Memory.new

  case fixture.shape.id
  when 0
    fixture.rows.each { |row| payload << w102_required(row[0][0], fixture.label) }
  when 1
    fixture.rows.each do |row|
      value = row[0][0]
      null_map.write_byte(value.nil? ? 1_u8 : 0_u8)
      w102_append_physical_value(payload, value, fixture.width)
    end
  when 2
    fixture.rows.each do |row|
      leaves = row[0]
      # Position-independent ArraySizes streams store one cardinality per row,
      # not cumulative offsets (SerializationArray.cpp's sizes encoding).
      w102_append_u64(size0, leaves.size.to_u64)
      leaves.each { |value| payload << w102_required(value, fixture.label) }
    end
  when 3
    fixture.rows.each do |row|
      leaves = row[0]
      w102_append_u64(size0, leaves.size.to_u64)
      leaves.each do |value|
        null_map.write_byte(value.nil? ? 1_u8 : 0_u8)
        w102_append_physical_value(payload, value, fixture.width)
      end
    end
  when 4
    fixture.rows.each do |row|
      w102_append_u64(size0, row.size.to_u64)
      row.each do |inner|
        w102_append_u64(size1, inner.size.to_u64)
        inner.each { |value| payload << w102_required(value, fixture.label) }
      end
    end
  when 5
    fixture.rows.each do |row|
      w102_append_u64(size0, row.size.to_u64)
      row.each do |inner|
        w102_append_u64(size1, inner.size.to_u64)
        inner.each do |value|
          null_map.write_byte(value.nil? ? 1_u8 : 0_u8)
          w102_append_physical_value(payload, value, fixture.width)
        end
      end
    end
  else
    raise "unknown W102 shape #{fixture.shape.id}"
  end

  case fixture.shape.id
  when 1
    streams["payload.null"] = null_map.to_s
  when 2
    streams["payload.size0"] = size0.to_s
  when 3
    streams["payload.size0"] = size0.to_s
    streams["payload.null"] = null_map.to_s
  when 4
    streams["payload.size0"] = size0.to_s
    streams["payload.size1"] = size1.to_s
  when 5
    streams["payload.size0"] = size0.to_s
    streams["payload.size1"] = size1.to_s
    streams["payload.null"] = null_map.to_s
  end
  streams["payload"] = payload.to_s
  streams
end

private def w102_expected_substreams(fixture : W102Fixture) : String
  payload_streams = fixture.shape.payload_streams
  lines = [
    "columns substreams version: 1",
    "2 columns:",
    "1 substreams for column `pk`:",
    "\tpk",
    "#{payload_streams.size} substreams for column `payload`:",
  ]
  payload_streams.each { |stream| lines << "\t#{stream}" }
  lines.join("\n") + "\n"
end

private def w102_check_bytes(actual : String, expected : String, label : String) : Nil
  return if actual == expected
  limit = Math.min(actual.bytesize, expected.bytesize)
  difference = 0
  while difference < limit && actual.to_slice[difference] == expected.to_slice[difference]
    difference += 1
  end
  got = difference < actual.bytesize ? actual.to_slice[difference].to_s(16).rjust(2, '0') : "<eof>"
  wanted = difference < expected.bytesize ? expected.to_slice[difference].to_s(16).rjust(2, '0') : "<eof>"
  raise W102ByteMismatchError.new("#{label}: expected #{expected.bytesize} bytes, got #{actual.bytesize}; first difference #{difference}: expected #{wanted}, got #{got}")
end

private def w102_seeded_comparator_check(actual : String, expected : String, label : String) : Nil
  w102_check_bytes(actual, expected, "#{label} baseline")
  raise "#{label}: cannot seed an empty comparison" if expected.empty?
  wrong = String.new(expected.to_slice)
  wrong.to_unsafe[0] = wrong.to_slice[0] ^ 0x01_u8
  begin
    w102_check_bytes(actual, wrong, "#{label} seeded defect")
    raise "#{label}: comparator accepted the seeded wrong byte"
  rescue ex : W102ByteMismatchError
  end
  puts "PASS #{label}: comparator rejects a seeded one-byte defect"
end

private def w102_attempt_clickhouse(binary : String, store : String, query : String, input : IO? = nil) : {Bool, String, String}
  output = IO::Memory.new
  error = IO::Memory.new
  result = Process.run(binary, ["local", "--path", store, "--query", query], input: input || Process::Redirect::Close, output: output, error: error)
  {result.success?, output.to_s, error.to_s}
end

private def w102_clickhouse(binary : String, store : String, query : String, input : IO? = nil) : String
  succeeded, output, error = w102_attempt_clickhouse(binary, store, query, input)
  raise "ClickHouse query failed: #{query}\n#{error}\n#{output}" unless succeeded
  output
end

private def w102_settings : String
  "index_granularity = 2, index_granularity_bytes = 10485760, enable_mixed_granularity_parts = 1, min_rows_for_wide_part = 0, min_bytes_for_wide_part = 0, compress_marks = 0, compress_primary_key = 0, min_compress_block_size = 0, max_compress_block_size = 4096, ratio_of_defaults_for_sparse_serialization = 1.0, default_compression_codec = 'LZ4'"
end

private def w102_create_table(binary : String, store : String, fixture : W102Fixture) : Nil
  w102_clickhouse(binary, store, "CREATE TABLE default.#{fixture.table_name} (pk UInt64, payload #{fixture.type_name}) ENGINE = MergeTree ORDER BY pk SETTINGS #{w102_settings}")
  nil
end

private def w102_part_path(binary : String, store : String, fixture : W102Fixture) : String
  lines = w102_clickhouse(binary, store, "SELECT path, part_type, rows FROM system.parts WHERE database='default' AND table='#{fixture.table_name}' AND active FORMAT TSVRaw").lines.map(&.strip).reject(&.empty?)
  raise "#{fixture.label}: expected exactly one active part, got #{lines.inspect}" unless lines.size == 1
  columns = lines[0].split('\t')
  raise "#{fixture.label}: malformed active-part row #{lines[0].inspect}" unless columns.size == 3
  raise "#{fixture.label}: expected a Wide part, got #{columns[1]}" unless columns[1] == "Wide"
  raise "#{fixture.label}: expected five rows, got #{columns[2]}" unless columns[2] == W102_KEYS.size.to_s
  path = columns[0]
  raise "#{fixture.label}: part path is absent" unless Dir.exists?(path)
  path
end

private def w102_mark_rows(part : String, stream : String, label : String) : Array(UInt64)
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  raise "#{label}: missing mark file for #{stream}" unless File.file?(path)
  bytes = File.read(path).to_slice
  raise "#{label}: partial .mrk2 record for #{stream}" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  rows = Array(UInt64).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |mark_index|
    offset = mark_index * CrystalClick::WidePart::MARK_SIZE + 16
    8.times.reduce(0_u64) { |value, byte| value | (bytes[offset + byte].to_u64 << (byte * 8)) }
  end
  raise "#{label}: #{stream} logical mark rows #{rows.inspect}, expected #{W102_MARK_ROWS.inspect}" unless rows == W102_MARK_ROWS
  rows
end

private def w102_assert_metadata_envelope(part : String, fixture : W102Fixture) : Nil
  info = JSON.parse(File.read(File.join(part, "serialization.json"))).as_h
  expected_keys = [
    "columns",
    "propagate_types_serialization_versions_to_nested_types",
    "types_serialization_versions",
    "version",
  ].sort
  raise "#{fixture.label}: serialization.json top-level keys differ: #{info.keys.sort.inspect}" unless info.keys.sort == expected_keys
  raise "#{fixture.label}: serialization.json version differs" unless info["version"]?.try(&.as_i) == 1
  raise "#{fixture.label}: nested version propagation is false" unless info["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool) == true
  info["types_serialization_versions"]?.try(&.as_h) || raise "#{fixture.label}: type-version map missing"
  records = info["columns"]?.try(&.as_a) || raise "#{fixture.label}: serialization columns are not an array"
  unless records.empty?
    names = records.map { |record| record.as_h["name"]?.try(&.as_s) || raise "#{fixture.label}: serialization column name absent" }.sort
    raise "#{fixture.label}: serialization roots differ: #{names.inspect}" unless names == ["payload", "pk"]
  else
    puts "OBSERVED #{fixture.label}: ratio-1 serialization metadata has columns=[]; no default-counter claim"
  end
  nil
end

private def w102_assert_part(fixture : W102Fixture, part : String) : Nil
  expected_columns = "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` #{fixture.type_name}\n"
  actual_columns = File.read(File.join(part, "columns.txt"))
  raise "#{fixture.label}: columns.txt differs: #{actual_columns.inspect}" unless actual_columns == expected_columns

  substreams = File.read(File.join(part, "columns_substreams.txt"))
  expected_substreams = w102_expected_substreams(fixture)
  raise "#{fixture.label}: columns_substreams.txt differs: #{substreams.inspect}" unless substreams == expected_substreams
  w102_assert_metadata_envelope(part, fixture)

  expected_streams = w102_expected_physical_streams(fixture)
  expected_names = expected_streams.keys.map { |stream| "#{CrystalClick::StreamName.hash(stream)}.bin" }.sort
  expected_marks = expected_streams.keys.map { |stream| "#{CrystalClick::StreamName.hash(stream)}.mrk2" }.sort
  entries = Dir.children(part)
  bins = entries.select(&.ends_with?(".bin")).sort
  marks = entries.select(&.ends_with?(".mrk2")).sort
  raise "#{fixture.label}: complete data-stream inventory differs: #{bins.inspect}" unless bins == expected_names
  raise "#{fixture.label}: complete mark inventory differs: #{marks.inspect}" unless marks == expected_marks
  raise "#{fixture.label}: unsupported compressed marks present" unless Dir.glob(File.join(part, "*.cmrk*")).empty?
  raise "#{fixture.label}: unexpected mark encoding present" unless Dir.glob(File.join(part, "*.mrk")).empty? && Dir.glob(File.join(part, "*.mrk3")).empty?
  raise "#{fixture.label}: LZ4 codec declaration differs" unless File.read(File.join(part, "default_compression_codec.txt")) == "CODEC(LZ4)"

  expected_streams.each do |stream, expected|
    path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")
    encoded = File.read(path).to_slice
    actual = CrystalClick::CompressedBlock.decode_all(encoded)
    w102_check_bytes(String.new(actual), expected, "#{fixture.label} #{stream} physical bytes")
    w102_mark_rows(part, stream, fixture.label)
  end
  puts "PASS #{fixture.label}: exact canonical declaration/substreams, complete #{expected_streams.size}-stream bytes and logical marks"
  nil
end

private def w102_check_table(binary : String, store : String, fixture : W102Fixture, part : String) : Nil
  actual = w102_clickhouse(binary, store, "CHECK TABLE default.#{fixture.table_name} FORMAT TabSeparated").strip
  expected = "#{File.basename(part.chomp("/"))}\t1"
  raise "#{fixture.label}: CHECK TABLE differs: #{actual.inspect}, expected #{expected.inspect}" unless actual == expected
  nil
end

private def w102_expected_indexes : Array(Int32)
  (0...W102_KEYS.size).map(&.to_i32)
end

private def w102_key_range_indexes : Array(Int32)
  W102_KEYS.each_with_index.compact_map { |key, index| index.to_i32 if key >= 2_u64 && key < 5_u64 }.to_a
end

private def w102_select(binary : String, store : String, fixture : W102Fixture, key_range : Bool = false) : String
  predicate = key_range ? " WHERE pk >= 2 AND pk < 5" : ""
  w102_clickhouse(binary, store, "SELECT pk, payload FROM default.#{fixture.table_name}#{predicate} ORDER BY pk FORMAT RowBinary")
end

private def w102_qualify_stock_fixture(binary : String, store : String, fixture : W102Fixture) : String
  w102_create_table(binary, store, fixture)
  input = IO::Memory.new(w102_rowbinary_input(fixture).to_slice)
  input.rewind
  w102_clickhouse(binary, store, "INSERT INTO default.#{fixture.table_name} FORMAT RowBinary", input)
  part = w102_part_path(binary, store, fixture)
  w102_assert_part(fixture, part)

  columns = w102_clickhouse(binary, store, "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{fixture.table_name}' ORDER BY position FORMAT TSVRaw").lines.map(&.strip)
  expected_columns = ["pk UInt64", "payload #{fixture.type_name}"]
  raise "#{fixture.label}: system.columns differs: #{columns.inspect}" unless columns == expected_columns

  w102_check_table(binary, store, fixture, part)
  actual_full = w102_select(binary, store, fixture)
  expected_full = w102_expected_rowbinary(fixture, w102_expected_indexes)
  w102_check_bytes(actual_full, expected_full, "#{fixture.label} independent full stock RowBinary")
  actual_keyed = w102_select(binary, store, fixture, true)
  expected_keyed = w102_expected_rowbinary(fixture, w102_key_range_indexes)
  w102_check_bytes(actual_keyed, expected_keyed, "#{fixture.label} independent key-range stock RowBinary")
  puts "PASS #{fixture.label}: system.columns, CHECK, full and selected-key RowBinary"
  part
end

private def w102_to_i32(value : String) : Int32
  raise "W102 positive control coefficient is not four bytes" unless value.bytesize == 4
  bytes = value.to_slice
  bits = bytes[0].to_u32 | (bytes[1].to_u32 << 8) | (bytes[2].to_u32 << 16) | (bytes[3].to_u32 << 24)
  bits.unsafe_as(Int32)
end

private def w102_expected_i32(fixture : W102Fixture) : Array(Int32)
  fixture.rows.map { |row| w102_to_i32(w102_required(row[0][0], fixture.label)) }
end

private def w102_expected_nullable_i32(fixture : W102Fixture) : Array(Int32?)
  fixture.rows.map { |row| row[0][0].try { |value| w102_to_i32(value) } }
end

private def w102_expected_array_i32(fixture : W102Fixture) : Array(Array(Int32))
  fixture.rows.map { |row| row[0].map { |value| w102_to_i32(w102_required(value, fixture.label)) } }
end

private def w102_expected_array_nullable_i32(fixture : W102Fixture) : Array(Array(Int32?))
  fixture.rows.map { |row| row[0].map { |value| value.try { |entry| w102_to_i32(entry) } } }
end

private def w102_expected_array_array_i32(fixture : W102Fixture) : Array(Array(Array(Int32)))
  fixture.rows.map { |row| row.map { |inner| inner.map { |value| w102_to_i32(w102_required(value, fixture.label)) } } }
end

private def w102_expected_array_array_nullable_i32(fixture : W102Fixture) : Array(Array(Array(Int32?)))
  fixture.rows.map { |row| row.map { |inner| inner.map { |value| value.try { |entry| w102_to_i32(entry) } } } }
end

private def w102_check_supported_reader_control(part : String, fixture : W102Fixture) : Nil
  reader = CrystalClick::WidePart.open_typed(part, "payload")
  raise "#{fixture.label}: positive-control canonical type differs: #{reader.column_type.inspect}" unless reader.column_type == fixture.type_name
  raise "#{fixture.label}: positive-control mark rows differ: #{reader.mark_row_counts.inspect}" unless reader.mark_row_counts == [2_u64, 2_u64, 1_u64]
  count = reader.mark_count
  raise "#{fixture.label}: positive-control mark count differs: #{count}" unless count == 3

  case fixture.shape.id
  when 0
    all = reader.read_decimal32_raw_mark_range("payload", 0, count)
    raise "#{fixture.label}: scalar reader values differ" unless all == w102_expected_i32(fixture)
    middle = reader.read_decimal32_raw_mark_range("payload", 1, 1)
    raise "#{fixture.label}: scalar selected mark differs" unless middle == w102_expected_i32(fixture)[2, 2]
  when 1
    all = reader.read_nullable_decimal32_raw_mark_range("payload", 0, count)
    raise "#{fixture.label}: nullable scalar reader values differ" unless all == w102_expected_nullable_i32(fixture)
    middle = reader.read_nullable_decimal32_raw_mark_range("payload", 1, 1)
    raise "#{fixture.label}: nullable scalar selected mark differs" unless middle == w102_expected_nullable_i32(fixture)[2, 2]
  when 2
    all = reader.read_array_decimal32_raw_mark_range("payload", 0, count)
    raise "#{fixture.label}: Array reader values differ" unless all == w102_expected_array_i32(fixture)
    middle = reader.read_array_decimal32_raw_mark_range("payload", 1, 1)
    raise "#{fixture.label}: Array selected mark differs" unless middle == w102_expected_array_i32(fixture)[2, 2]
  when 3
    all = reader.read_array_nullable_decimal32_raw_mark_range("payload", 0, count)
    raise "#{fixture.label}: Nullable Array reader values differ" unless all == w102_expected_array_nullable_i32(fixture)
    middle = reader.read_array_nullable_decimal32_raw_mark_range("payload", 1, 1)
    raise "#{fixture.label}: Nullable Array selected mark differs" unless middle == w102_expected_array_nullable_i32(fixture)[2, 2]
  when 4
    all = reader.read_array_array_decimal32_mark_range("payload", 0, count)
    raise "#{fixture.label}: two-level Array reader values differ" unless all == w102_expected_array_array_i32(fixture)
    middle = reader.read_array_array_decimal32_mark_range("payload", 1, 1)
    raise "#{fixture.label}: two-level Array selected mark differs" unless middle == w102_expected_array_array_i32(fixture)[2, 2]
  when 5
    all = reader.read_array_array_nullable_decimal32_mark_range("payload", 0, count)
    raise "#{fixture.label}: two-level Nullable Array reader values differ" unless all == w102_expected_array_array_nullable_i32(fixture)
    middle = reader.read_array_array_nullable_decimal32_mark_range("payload", 1, 1)
    raise "#{fixture.label}: two-level Nullable Array selected mark differs" unless middle == w102_expected_array_array_nullable_i32(fixture)[2, 2]
  else
    raise "unknown W102 positive-control shape #{fixture.shape.id}"
  end
  puts "PASS #{fixture.label}: existing max-P typed reader and selected-mark path"
  nil
end

private def w102_expected_rejection(part : String, fixture : W102Fixture) : Nil
  begin
    CrystalClick::WidePart.open_typed(part, "payload")
  rescue ex : CrystalClick::UnsupportedFormatError
    raise "#{fixture.label}: unsupported reader reason changed: #{ex.message.inspect}" unless ex.message == "unsupported exact typed column"
    puts "OBSERVED expected UnsupportedFormatError for #{fixture.label}: #{ex.message}"
    return
  end
  raise "#{fixture.label}: unchanged reader unexpectedly admitted #{fixture.type_name}"
end

private def w102_check_source_guard : Nil
  head_output = IO::Memory.new
  head_status = Process.run("git", ["rev-parse", "HEAD"], output: head_output)
  raise "cannot read W102 predecessor HEAD" unless head_status.success?
  raise "W102 RED requires predecessor #{W102_EXPECTED_HEAD}, got #{head_output.to_s.strip}" unless head_output.to_s.strip == W102_EXPECTED_HEAD
  source_status = Process.run("git", ["diff", "--quiet", "HEAD", "--", "src"])
  raise "W102 RED requires unchanged production source" unless source_status.success?
  nil
end

binary = ENV.fetch("CLICKHOUSE_BIN")
store = ENV.fetch("W102_STORE")
w102_check_source_guard
version = w102_clickhouse(binary, store, "SELECT version() FORMAT TSVRaw").strip
raise "W102 requires ClickHouse #{W102_STOCK_VERSION}, got #{version}" unless version == W102_STOCK_VERSION

interior_fixtures = W102_SHAPES.flat_map do |shape|
  W102_INTERIOR_PS.map { |precision| w102_fixture(shape, precision, "#{shape.label}_p#{precision}") }
end
raise "W102 expected exactly 24 lower-than-maximum stock profiles" unless interior_fixtures.size == 24

# Fully qualify every lower-P stock profile before any RED observation.
qualified_parts = Hash(String, String).new
interior_fixtures.each do |fixture|
  qualified_parts[fixture.label] = w102_qualify_stock_fixture(binary, store, fixture)
end

# Existing max-P Decimal32 accessors provide a positive control for each of
# the six physical shapes, including exact marks and selected-mark reads.
positive_controls = W102_SHAPES.map do |shape|
  w102_fixture(shape, 9, "#{shape.label}_maxp_control")
end
positive_parts = Hash(String, String).new
positive_controls.each do |fixture|
  positive_parts[fixture.label] = w102_qualify_stock_fixture(binary, store, fixture)
end
positive_controls.each do |fixture|
  w102_check_supported_reader_control(positive_parts[fixture.label], fixture)
end

comparator_fixture = interior_fixtures.first
comparator_full = w102_select(binary, store, comparator_fixture)
w102_seeded_comparator_check(
  comparator_full,
  w102_expected_rowbinary(comparator_fixture, w102_expected_indexes),
  "W102 independent full RowBinary comparator",
)

# Only now ask the old typed-reader admission gates to reject lower P.
interior_fixtures.each do |fixture|
  w102_expected_rejection(qualified_parts[fixture.label], fixture)
end

puts "EXPECTED RED: all 24 lower-than-maximum Decimal(P,S) fixtures across six shapes and four storage bands passed independent metadata, complete stream-byte/mark, CHECK, full/key RowBinary, and seeded-comparator qualification; six matching max-P reader controls passed; unchanged typed admission rejected each interior precision."
exit 1
