# W101 bidirectional oracle. Stock fixtures are independently described in
# terms of canonical schema and raw bytes; this script checks the library
# reader/writer against ClickHouse, then exercises table/catalog consumers.
require "json"
require "file_utils"
require "../src/crystal_click"

W101O_VERSION      = "26.7.1.1315"
W101O_KEYS         = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
W101O_FULL         = [0_i32, 1_i32, 2_i32, 3_i32, 4_i32]
W101O_KEY_RANGE    = [1_i32, 2_i32, 3_i32]
W101O_MARK_RANGE   = [2_i32, 3_i32, 4_i32]
W101O_WINDOW       = [1_i32, 2_i32, 3_i32]
W101O_CANDIDATE    = [2_i32, 3_i32, 4_i32]
W101O_MARK_ROWS    = [2_u64, 2_u64, 1_u64, 0_u64]
W101O_READER_MARKS = [2_u64, 2_u64, 1_u64]

struct W101OracleField
  getter name : String
  getter input_type : String
  getter parameterized_type : CrystalClick::WideTupleParameterizedType
  getter raw_rows : Array(String)
  getter column : CrystalClick::WideTupleLeafColumn

  def initialize(
    @name : String,
    @input_type : String,
    @parameterized_type : CrystalClick::WideTupleParameterizedType,
    raw_rows : Array(String),
  )
    raise "#{@name}: empty field name" if @name.empty?
    raise "#{@name}: fixture needs five rows" unless raw_rows.size == W101O_KEYS.size
    width = w101o_width(@parameterized_type)
    raw_rows.each_with_index do |raw, index|
      raise "#{@name}: row #{index} has #{raw.bytesize} bytes, expected #{width}" unless raw.bytesize == width
    end
    @raw_rows = raw_rows.map { |raw| String.new(raw.to_slice) }
    @column = w101o_column_from_raw(@name, @parameterized_type, @raw_rows)
    raise "#{@name}: owned leaf type differs" unless @column.type_name == canonical_type
  end

  def canonical_type : String
    @parameterized_type.type_name
  end

  def width : Int32
    w101o_width(@parameterized_type)
  end

  def default_count : Int32
    @raw_rows.count { |row| w101o_zero?(row) }
  end

  def zero_like : W101OracleField
    zeros = Array.new(W101O_KEYS.size) { String.new(Bytes.new(width, 0_u8)) }
    W101OracleField.new(@name, @input_type, @parameterized_type, zeros)
  end
end

struct W101OracleProfile
  getter label : String
  getter fields : Array(W101OracleField)
  getter ratio : String

  def initialize(@label : String, fields : Array(W101OracleField), @ratio : String = "1.0")
    raise "#{@label}: Tuple must be nonempty" if fields.empty?
    @fields = fields.dup
  end

  def input_type : String
    "Tuple(#{@fields.map { |field| "#{field.name} #{field.input_type}" }.join(", ")})"
  end

  def canonical_type : String
    "Tuple(#{@fields.map { |field| "#{field.name} #{field.canonical_type}" }.join(", ")})"
  end

  def source_table : String
    "w101o_src_#{@label}"
  end

  def writer_table : String
    "w101o_wr_#{@label}"
  end

  def columns : Array(CrystalClick::WideTupleLeafColumn)
    @fields.map(&.column)
  end

  def streams : Array(String)
    ["pk"] + @fields.map { |field| "payload%2E#{field.name}" }
  end

  def expected_stream(stream : String) : String
    return W101O_KEYS.map { |key| w101o_unsigned_le(key, 8) }.join if stream == "pk"
    field = @fields.find { |entry| "payload%2E#{entry.name}" == stream }
    raise "#{@label}: no expected bytes for stream #{stream.inspect}" unless field
    field.raw_rows.join
  end

  def expected_rowbinary(indexes : Array(Int32)) : String
    output = IO::Memory.new
    indexes.each do |index|
      output << w101o_unsigned_le(W101O_KEYS[index], 8)
      @fields.each { |field| output << field.raw_rows[index] }
    end
    output.to_s
  end

  def expected_payload_rowbinary(indexes : Array(Int32)) : String
    output = IO::Memory.new
    indexes.each { |index| @fields.each { |field| output << field.raw_rows[index] } }
    output.to_s
  end

  def tuple_default_count : Int32
    W101O_FULL.count { |index| @fields.all? { |field| w101o_zero?(field.raw_rows[index]) } }
  end
end

class W101OracleByteMismatchError < Exception
end

def w101o_width(type : CrystalClick::WideTupleParameterizedType) : Int32
  case type
  when CrystalClick::WideTupleFixedStringType
    type.width
  when CrystalClick::WideTupleEnumType
    type.width
  when CrystalClick::WideTupleDecimalType
    type.storage_width
  else
    raise "unsupported W101 parameterized descriptor"
  end
end

def w101o_zero?(raw : String) : Bool
  raw.to_slice.all?(&.==(0_u8))
end

def w101o_unsigned_le(value : UInt64, width : Int32) : String
  output = IO::Memory.new
  width.times { |index| output.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
  output.to_s
end

def w101o_signed_le(value : Int128, width : Int32) : String
  bits = value.unsafe_as(UInt128)
  output = IO::Memory.new
  width.times do |index|
    output.write_byte(((bits >> (index * 8)) & 0xff_u128).to_u8)
  end
  output.to_s
end

def w101o_read_unsigned_le(raw : String) : UInt128
  bits = 0_u128
  raw.to_slice.each_with_index do |byte, index|
    bits |= byte.to_u128 << (index * 8)
  end
  bits
end

def w101o_read_signed_le(raw : String) : Int128
  bits = w101o_read_unsigned_le(raw)
  width_bits = raw.bytesize * 8
  if width_bits < 128 && (bits & (1_u128 << (width_bits - 1))) != 0
    bits |= UInt128::MAX << width_bits
  end
  bits.unsafe_as(Int128)
end

def w101o_decimal256(raw : String) : CrystalClick::Decimal256Value
  raise "Decimal256 raw field is not 32 bytes" unless raw.bytesize == 32
  words = Array(UInt64).new(4) do |word_index|
    8.times.reduce(0_u64) do |value, byte_index|
      value | (raw.to_slice[word_index * 8 + byte_index].to_u64 << (byte_index * 8))
    end
  end
  CrystalClick::Decimal256Value.from_words(words[0], words[1], words[2], words[3])
end

def w101o_decimal256_bytes(raw : CrystalClick::Decimal256Value) : String
  words = [
    (raw.low & UInt64::MAX.to_u128).to_u64,
    (raw.low >> 64).to_u64,
    (raw.high & UInt64::MAX.to_u128).to_u64,
    (raw.high >> 64).to_u64,
  ]
  words.map { |word| w101o_unsigned_le(word, 8) }.join
end

def w101o_column_from_raw(
  name : String,
  type : CrystalClick::WideTupleParameterizedType,
  raw_rows : Array(String),
) : CrystalClick::WideTupleLeafColumn
  case type
  when CrystalClick::WideTupleFixedStringType
    values = raw_rows.map { |raw| CrystalClick::FixedStringValue.from_raw(type.width, raw.to_slice) }
    CrystalClick::WideTupleLeafColumn.new(name, type, values)
  when CrystalClick::WideTupleEnumType
    enum_type = type.as(CrystalClick::WideTupleEnumType)
    if enum_type.width == 1
      values = raw_rows.map { |raw| CrystalClick::Enum8Value.new(enum_type.definition, w101o_read_signed_le(raw).to_i8) }
      CrystalClick::WideTupleLeafColumn.new(name, type, values)
    else
      values = raw_rows.map { |raw| CrystalClick::Enum16Value.new(enum_type.definition, w101o_read_signed_le(raw).to_i16) }
      CrystalClick::WideTupleLeafColumn.new(name, type, values)
    end
  when CrystalClick::WideTupleDecimalType
    decimal_type = type.as(CrystalClick::WideTupleDecimalType)
    precision = decimal_type.precision
    scale = decimal_type.scale
    case decimal_type.storage_width
    when 4
      values = raw_rows.map { |raw| CrystalClick::Decimal32Value.new(w101o_read_signed_le(raw).to_i32, precision, scale) }
      CrystalClick::WideTupleLeafColumn.new(name, type, values)
    when 8
      values = raw_rows.map { |raw| CrystalClick::Decimal64Value.new(w101o_read_signed_le(raw).to_i64, precision, scale) }
      CrystalClick::WideTupleLeafColumn.new(name, type, values)
    when 16
      values = raw_rows.map { |raw| CrystalClick::Decimal128Value.new(w101o_read_signed_le(raw), precision, scale) }
      CrystalClick::WideTupleLeafColumn.new(name, type, values)
    when 32
      values = raw_rows.map { |raw| CrystalClick::Decimal256TupleValue.new(w101o_decimal256(raw), precision, scale) }
      CrystalClick::WideTupleLeafColumn.new(name, type, values)
    else
      raise "#{name}: unsupported Decimal width #{decimal_type.storage_width}"
    end
  else
    raise "#{name}: unsupported W101 parameterized descriptor"
  end
end

def w101o_actual_raw(field : W101OracleField, column : CrystalClick::WideTupleLeafColumn, row : Int32) : String
  unless column.type_name == field.canonical_type
    raise "#{field.name}: exact nominal type differs: #{column.type_name} vs #{field.canonical_type}"
  end
  case field.parameterized_type
  when CrystalClick::WideTupleFixedStringType
    value = column.value_at(row).as(CrystalClick::FixedStringValue)
    raise "#{field.name}: FixedString width lost" unless value.width == field.parameterized_type.as(CrystalClick::WideTupleFixedStringType).width
    String.new(value.raw_bytes)
  when CrystalClick::WideTupleEnumType
    enum_type = field.parameterized_type.as(CrystalClick::WideTupleEnumType)
    if enum_type.width == 1
      value = column.value_at(row).as(CrystalClick::Enum8Value)
      raise "#{field.name}: Enum8 descriptor changed" unless value.definition.entries == enum_type.definition.entries
      w101o_signed_le(value.code.to_i128, 1)
    else
      value = column.value_at(row).as(CrystalClick::Enum16Value)
      raise "#{field.name}: Enum16 descriptor changed" unless value.definition.entries == enum_type.definition.entries
      w101o_signed_le(value.code.to_i128, 2)
    end
  when CrystalClick::WideTupleDecimalType
    decimal_type = field.parameterized_type.as(CrystalClick::WideTupleDecimalType)
    case decimal_type.storage_width
    when 4
      value = column.value_at(row).as(CrystalClick::Decimal32Value)
      w101o_assert_decimal_descriptor(field, value.precision, value.scale)
      w101o_signed_le(value.raw.to_i128, 4)
    when 8
      value = column.value_at(row).as(CrystalClick::Decimal64Value)
      w101o_assert_decimal_descriptor(field, value.precision, value.scale)
      w101o_signed_le(value.raw.to_i128, 8)
    when 16
      value = column.value_at(row).as(CrystalClick::Decimal128Value)
      w101o_assert_decimal_descriptor(field, value.precision, value.scale)
      w101o_signed_le(value.raw, 16)
    when 32
      value = column.value_at(row).as(CrystalClick::Decimal256TupleValue)
      w101o_assert_decimal_descriptor(field, value.precision, value.scale)
      w101o_decimal256_bytes(value.raw)
    else
      raise "#{field.name}: unsupported Decimal width"
    end
  else
    raise "#{field.name}: unsupported W101 parameterized descriptor"
  end
end

def w101o_assert_decimal_descriptor(field : W101OracleField, precision : Int32, scale : Int32) : Nil
  type = field.parameterized_type.as(CrystalClick::WideTupleDecimalType)
  raise "#{field.name}: Decimal precision changed" unless precision == type.precision
  raise "#{field.name}: Decimal scale changed" unless scale == type.scale
end

def w101o_field_from_rows(name : String, input_type : String, type : CrystalClick::WideTupleParameterizedType, raws : Array(String)) : W101OracleField
  W101OracleField.new(name, input_type, type, raws)
end

def w101o_fixed(name : String, width : Int32, values : Array(String)) : W101OracleField
  type = CrystalClick::WideTupleFixedStringType.new(width)
  raws = values.map do |value|
    raise "#{name}: input wider than FixedString(#{width})" if value.bytesize > width
    output = IO::Memory.new
    output << value
    (width - value.bytesize).times { output.write_byte(0_u8) }
    output.to_s
  end
  w101o_field_from_rows(name, "FixedString(#{width})", type, raws)
end

def w101o_quote_label(label : String) : String
  String.build do |output|
    output << '\''
    label.to_slice.each do |byte|
      case byte
      when '\''.ord.to_u8 then output << "\\'"
      when '\\'.ord.to_u8 then output << "\\\\"
      when 0x08_u8        then output << "\\b"
      when 0x0c_u8        then output << "\\f"
      when 0x0a_u8        then output << "\\n"
      when 0x0d_u8        then output << "\\r"
      when 0x09_u8        then output << "\\t"
      when 0x00_u8        then output << "\\0"
      else                     output.write_byte(byte)
      end
    end
    output << '\''
  end
end

def w101o_enum_type_name(kind : String, order : Array(Tuple(String, Int16))) : String
  body = order.map { |label, code| "#{w101o_quote_label(label)} = #{code}" }.join(", ")
  "#{kind}(#{body})"
end

def w101o_enum(name : String, kind : String, entries : Array(Tuple(String, Int16)), codes : Array(Int32), shuffled : Bool = true) : W101OracleField
  symbol = case kind
           when "Enum8"  then :enum8
           when "Enum16" then :enum16
           else
             raise "#{name}: unsupported Enum kind #{kind.inspect}"
           end
  definition = CrystalClick::WideTupleEnumDefinition.new(symbol, entries)
  type = CrystalClick::WideTupleEnumType.new(definition)
  width = case kind
          when "Enum8"  then 1
          when "Enum16" then 2
          else
            raise "#{name}: unsupported Enum kind #{kind.inspect}"
          end
  sorted = entries.sort_by(&.[1])
  order = shuffled ? entries.reverse : entries
  input_type = w101o_enum_type_name(kind, order)
  raise "#{name}: Enum definition changed canonical map" unless type.type_name == w101o_enum_type_name(kind, sorted)
  raws = codes.map do |code|
    raise "#{name}: row uses undeclared Enum code #{code}" unless entries.any? { |entry| entry[1].to_i32 == code }
    w101o_signed_le(code.to_i128, width)
  end
  w101o_field_from_rows(name, input_type, type, raws)
end

def w101o_decimal(name : String, precision : Int32, scale : Int32, input_type : String, raws_i128 : Array(Int128)) : W101OracleField
  type = CrystalClick::WideTupleDecimalType.new(precision, scale)
  raws = raws_i128.map { |raw| w101o_signed_le(raw, type.storage_width) }
  w101o_field_from_rows(name, input_type, type, raws)
end

def w101o_small_decimal_values(precision : Int32) : Array(Int128)
  bound = precision == 1 ? 9_i128 : 1_i128
  [-bound, -1_i128, 0_i128, 1_i128, bound]
end

def w101o_decimal_matrix : Array(W101OracleField)
  fields = [] of W101OracleField
  [1, 9, 10, 18, 19, 38, 39, 76].each do |precision|
    [0, precision].uniq.each do |scale|
      fields << w101o_decimal("d_p#{precision}_s#{scale}", precision, scale, "Decimal(#{precision}, #{scale})", w101o_small_decimal_values(precision))
    end
  end
  [{"d_p3_s1", 3, 1}, {"d_p14_s7", 14, 7}, {"d_p32_s16", 32, 16}, {"d_p60_s30", 60, 30}].each do |name, precision, scale|
    fields << w101o_decimal(name, precision, scale, "Decimal(#{precision}, #{scale})", w101o_small_decimal_values(precision))
  end
  [{"Decimal32", 9, 9}, {"Decimal64", 18, 18}, {"Decimal128", 38, 38}, {"Decimal256", 76, 76}].each do |family, precision, max_scale|
    [0, max_scale].uniq.each do |scale|
      fields << w101o_decimal("a_#{family.downcase}_s#{scale}", precision, scale, "#{family}(#{scale})", w101o_small_decimal_values(precision))
    end
  end
  fields << w101o_decimal("d_p9_implicit_s0", 9, 0, "Decimal(9)", w101o_small_decimal_values(9))
  fields << w101o_decimal("d_bare_s0", 10, 0, "Decimal", w101o_small_decimal_values(10))
  raise "W101 boundary matrix drift: expected 30 Decimal leaves, got #{fields.size}" unless fields.size == 30
  fields
end

W101O_ENUM8 = [
  {"minimum8", -128_i16}, {"quote'x", -127_i16}, {"back\\slash", -126_i16},
  {"b\b", -125_i16}, {"f\f", -124_i16}, {"n\n", -123_i16}, {"r\r", -122_i16},
  {"t\t", -121_i16}, {"z\0", -120_i16}, {"", -119_i16}, {"café", -118_i16},
  {",=(x)", -117_i16}, {"SELECT", -116_i16}, {"negative-seven", -7_i16},
  {"negative-one", -1_i16}, {"zero8", 0_i16}, {"maximum8", 127_i16},
] of Tuple(String, Int16)

W101O_ENUM16 = [
  {"minimum16", -32768_i16}, {"quote'x16", -30000_i16}, {"back\\slash16", -20000_i16},
  {"b\b16", -10000_i16}, {"f\f16", -5000_i16}, {"n\n16", -1000_i16},
  {"r\r16", -100_i16}, {"t\t16", -10_i16}, {"negative-one16", -1_i16},
  {"zero16", 0_i16}, {"z\0", 1_i16}, {"", 2_i16}, {"café16", 3_i16},
  {"a,b=(c)", 42_i16}, {"SELECT16", 30000_i16}, {"maximum16", 32767_i16},
] of Tuple(String, Int16)

def w101o_singletons_and_mixed : Array(W101OracleProfile)
  fixed1 = w101o_fixed("value", 1, ["", "\0", "A", "\xff", "z"] of String)
  fixed4 = w101o_fixed("value", 4, ["a", "x\0yZ", "é", "\0\xff", "ABCD"] of String)
  enum8 = w101o_enum("value", "Enum8", W101O_ENUM8, [-128, -1, 0, 127, -7])
  enum16 = w101o_enum("value", "Enum16", W101O_ENUM16, [-32768, -30000, 0, 32767, 42])
  d32 = w101o_decimal("value", 9, 9, "Decimal(9, 9)", w101o_small_decimal_values(9))
  d64 = w101o_decimal("value", 18, 18, "Decimal(18, 18)", w101o_small_decimal_values(18))
  d128 = w101o_decimal("value", 38, 38, "Decimal(38, 38)", w101o_small_decimal_values(38))
  d256 = w101o_decimal("value", 76, 76, "Decimal(76, 76)", w101o_small_decimal_values(76))
  profiles = [
    W101OracleProfile.new("fixed1", [fixed1] of W101OracleField),
    W101OracleProfile.new("fixed4", [fixed4] of W101OracleField),
    W101OracleProfile.new("enum8", [enum8] of W101OracleField),
    W101OracleProfile.new("enum16", [enum16] of W101OracleField),
    W101OracleProfile.new("decimal32", [d32] of W101OracleField),
    W101OracleProfile.new("decimal64", [d64] of W101OracleField),
    W101OracleProfile.new("decimal128", [d128] of W101OracleField),
    W101OracleProfile.new("decimal256", [d256] of W101OracleField),
  ] of W101OracleProfile
  fields = [] of W101OracleField
  fields << w101o_fixed("fixed1", 1, ["", "\0", "A", "\xff", "z"] of String)
  fields << w101o_fixed("fixed4", 4, ["a", "x\0yZ", "é", "\0\xff", "ABCD"] of String)
  fields << w101o_enum("enum8", "Enum8", W101O_ENUM8, [-128, -1, 0, 127, -7])
  fields << w101o_enum("enum16", "Enum16", W101O_ENUM16, [-32768, -30000, 0, 32767, 42])
  fields.concat(w101o_decimal_matrix)
  raise "W101 mixed fixture drift: expected 34 leaves, got #{fields.size}" unless fields.size == 34
  profiles << W101OracleProfile.new("mixed", fields)
  profiles
end

def w101o_clickhouse(binary : String, store : String, query : String, input : IO? = nil) : String
  output = IO::Memory.new
  error = IO::Memory.new
  status = if input
             Process.run(binary, ["local", "--path", store, "--query", query], input: input, output: output, error: error)
           else
             Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: error)
           end
  raise "ClickHouse command failed (#{status.exit_code}): #{error}\n#{query}" unless status.success?
  output.to_s
end

def w101o_settings(ratio : String) : String
  "index_granularity = 2, index_granularity_bytes = 10485760, enable_mixed_granularity_parts = 1, min_rows_for_wide_part = 0, min_bytes_for_wide_part = 0, ratio_of_defaults_for_sparse_serialization = #{ratio}, compress_marks = 0, compress_primary_key = 0, min_compress_block_size = 0, max_compress_block_size = 4096, default_compression_codec = 'LZ4'"
end

def w101o_create_table(binary : String, store : String, table : String, profile : W101OracleProfile) : Nil
  w101o_clickhouse(binary, store, "CREATE TABLE default.#{table} (pk UInt64, payload #{profile.input_type}) ENGINE = MergeTree ORDER BY pk SETTINGS #{w101o_settings(profile.ratio)}")
  nil
end

def w101o_insert_input(profile : W101OracleProfile, indexes : Array(Int32) = W101O_FULL) : IO::Memory
  IO::Memory.new(profile.expected_rowbinary(indexes).to_slice).tap(&.rewind)
end

def w101o_part_path(binary : String, store : String, table : String) : String
  lines = w101o_clickhouse(binary, store, "SELECT path, part_type, rows FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw").lines.map(&.strip).reject(&.empty?)
  raise "#{table}: expected one active part, got #{lines.inspect}" unless lines.size == 1
  fields = lines[0].split('\t')
  raise "#{table}: malformed active part row" unless fields.size == 3
  raise "#{table}: expected Wide part" unless fields[1] == "Wide"
  raise "#{table}: expected five rows" unless fields[2] == W101O_KEYS.size.to_s
  fields[0]
end

def w101o_u64_at(bytes : Bytes, offset : Int32) : UInt64
  8.times.reduce(0_u64) { |value, index| value | (bytes[offset + index].to_u64 << (index * 8)) }
end

def w101o_mark_records(part : String, stream : String) : Array(Tuple(UInt64, UInt64, UInt64))
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  bytes = File.read(path).to_slice
  raise "#{stream}: truncated mark row" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(Tuple(UInt64, UInt64, UInt64)).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE
    {w101o_u64_at(bytes, offset), w101o_u64_at(bytes, offset + 8), w101o_u64_at(bytes, offset + 16)}
  end
end

def w101o_assert_bytes(actual : String, expected : String, label : String) : Nil
  return if actual == expected
  limit = Math.min(actual.bytesize, expected.bytesize)
  index = 0
  while index < limit && actual.to_slice[index] == expected.to_slice[index]
    index += 1
  end
  got = index < actual.bytesize ? actual.to_slice[index].to_s(16).rjust(2, '0') : "<eof>"
  want = index < expected.bytesize ? expected.to_slice[index].to_s(16).rjust(2, '0') : "<eof>"
  raise W101OracleByteMismatchError.new("#{label}: expected #{expected.bytesize} bytes, got #{actual.bytesize}; first difference #{index}: expected #{want}, got #{got}")
end

def w101o_seeded_wrong_expectation_rejected(actual : String, expected : String, label : String) : Nil
  w101o_assert_bytes(actual, expected, "#{label} comparator control")
  raise "#{label}: empty comparison payload" if expected.empty?
  damaged = String.new(expected.to_slice)
  damaged.to_unsafe[0] = damaged.to_slice[0] ^ 0x01_u8
  begin
    w101o_assert_bytes(actual, damaged, label)
    raise "#{label}: seeded one-byte mutation was accepted"
  rescue ex : W101OracleByteMismatchError
  end
  puts "PASS #{label}: byte comparator rejects a seeded one-byte mismatch"
end

def w101o_expected_substreams(profile : W101OracleProfile) : String
  lines = ["columns substreams version: 1", "2 columns:", "1 substreams for column `pk`:", "\tpk", "#{profile.fields.size} substreams for column `payload`:"]
  profile.fields.each { |field| lines << "\tpayload%2E#{field.name}" }
  lines.join("\n") + "\n"
end

def w101o_validate_metadata_envelope(info : Hash(String, JSON::Any), label : String) : Nil
  keys = ["columns", "propagate_types_serialization_versions_to_nested_types", "types_serialization_versions", "version"].sort
  raise "#{label}: serialization top-level keys differ: #{info.keys.sort.inspect}" unless info.keys.sort == keys
  raise "#{label}: serialization version differs" unless info["version"]?.try(&.as_i) == 1
  raise "#{label}: nested type-version propagation differs" unless info["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool) == true
  versions = info["types_serialization_versions"]?.try(&.as_h) || raise "#{label}: type-version map absent"
  raise "#{label}: type-version map differs: #{versions.to_json}" unless versions.size == 1 && versions["string"]?.try(&.as_i) == 1
  nil
end

def w101o_validate_counter(row : Hash(String, JSON::Any), defaults : Int32, label : String, expected_kind : String = "Default") : Nil
  kind = row["kind"]?.try(&.as_s) || raise "#{label}: serializer kind missing"
  raise "#{label}: expected #{expected_kind} serializer, got #{kind}" unless kind == expected_kind
  raise "#{label}: num_rows missing or not five" unless row["num_rows"]?.try(&.as_i) == W101O_KEYS.size.to_i64
  raise "#{label}: num_defaults mismatch" unless row["num_defaults"]?.try(&.as_i) == defaults.to_i64
  nil
end

def w101o_validate_metadata(profile : W101OracleProfile, part : String, stats_only : Bool = false, require_counters : Bool = false, stats_kind : String = "Sparse") : Nil
  info = JSON.parse(File.read(File.join(part, "serialization.json"))).as_h
  w101o_validate_metadata_envelope(info, profile.label)
  records = info["columns"]?.try(&.as_a) || raise "#{profile.label}: columns key not an array"
  unless records.empty?
    names = records.map { |row| row.as_h["name"]?.try(&.as_s) || raise "#{profile.label}: record name missing" }
    raise "#{profile.label}: serializer roots/order differ: #{names.inspect}" unless names == ["payload", "pk"]
    payload = records[0].as_h
    children = payload["subcolumns"]?.try(&.as_a) || raise "#{profile.label}: Tuple child metadata absent"
    raise "#{profile.label}: Tuple child count differs" unless children.size == profile.fields.size
    if stats_only
      profile.fields.each_with_index do |field, index|
        w101o_validate_counter(children[index].as_h, field.default_count, "#{profile.label} #{field.name}", stats_kind)
      end
    else
      profile.fields.each_with_index do |field, index|
        w101o_validate_counter(children[index].as_h, field.default_count, "#{profile.label} #{field.name}")
      end
      w101o_validate_counter(payload, profile.tuple_default_count, "#{profile.label} Tuple root")
      w101o_validate_counter(records[1].as_h, 0, "#{profile.label} primary key")
    end
    puts "OBSERVED #{profile.label} serialization=#{info.to_json}"
  else
    raise "#{profile.label}: empty columns metadata is not admitted here" if stats_only || require_counters || profile.ratio.to_f < 1.0
    puts "OBSERVED #{profile.label}: legal columns=[] at ratio 1; no source counter claim"
  end
  nil
end

def w101o_assert_plain_layout(profile : W101OracleProfile, part : String, label : String, require_counters : Bool = false) : Nil
  expected_columns = ["columns format version: 1", "2 columns:", "`pk` UInt64", "`payload` #{profile.canonical_type}"]
  actual_columns = File.read(File.join(part, "columns.txt")).lines.map(&.strip)
  raise "#{label}: columns.txt differs: #{actual_columns.inspect}" unless actual_columns == expected_columns
  actual_substreams = File.read(File.join(part, "columns_substreams.txt"))
  raise "#{label}: columns_substreams.txt differs" unless actual_substreams == w101o_expected_substreams(profile)
  streams = profile.streams
  expected_bins = streams.map { |stream| "#{CrystalClick::StreamName.hash(stream)}.bin" }.sort
  expected_marks = streams.map { |stream| "#{CrystalClick::StreamName.hash(stream)}.mrk2" }.sort
  entries = Dir.children(part)
  bins = entries.select(&.ends_with?(".bin")).sort
  marks = entries.select(&.ends_with?(".mrk2")).sort
  raise "#{label}: complete .bin inventory differs" unless bins == expected_bins
  raise "#{label}: complete .mrk2 inventory differs" unless marks == expected_marks
  streams.each do |stream|
    actual_records = w101o_mark_records(part, stream)
    raise "#{label} #{stream}: mark rows differ" unless actual_records.map(&.[2]) == W101O_MARK_ROWS
    encoded = File.read(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
    decoded = CrystalClick::CompressedBlock.decode_all(encoded)
    w101o_assert_bytes(String.new(decoded), profile.expected_stream(stream), "#{label} #{stream} physical bytes")
  end
  w101o_validate_metadata(profile, part, require_counters: require_counters)
  nil
end

def w101o_check(binary : String, store : String, table : String, part : String) : Nil
  result = w101o_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  expected = "#{File.basename(part.chomp("/"))}\t1"
  raise "#{table}: CHECK TABLE failed: #{result.inspect}" unless result == expected
  nil
end

def w101o_query_rowbinary(binary : String, store : String, profile : W101OracleProfile, table : String, indexes : Array(Int32), key_range : Bool = false) : Nil
  selection = (["pk"] + profile.fields.map { |field| "payload.#{field.name}" }).join(", ")
  predicate = key_range ? " WHERE pk >= 2 AND pk < 5" : ""
  actual = w101o_clickhouse(binary, store, "SELECT #{selection} FROM default.#{table}#{predicate} ORDER BY pk FORMAT RowBinary")
  w101o_assert_bytes(actual, profile.expected_rowbinary(indexes), "#{table} stock #{key_range ? "key-range" : "full"} RowBinary")
end

def w101o_create_stock_profile(binary : String, store : String, profile : W101OracleProfile) : String
  w101o_create_table(binary, store, profile.source_table, profile)
  input = w101o_insert_input(profile)
  w101o_clickhouse(binary, store, "INSERT INTO default.#{profile.source_table} FORMAT RowBinary", input)
  part = w101o_part_path(binary, store, profile.source_table)
  actual = w101o_clickhouse(binary, store, "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{profile.source_table}' ORDER BY position FORMAT TSVRaw").lines.map(&.strip)
  expected = ["pk UInt64", "payload #{profile.canonical_type}"]
  raise "#{profile.label}: stock system.columns differs: #{actual.inspect}" unless actual == expected
  w101o_assert_plain_layout(profile, part, "stock #{profile.label}")
  w101o_check(binary, store, profile.source_table, part)
  w101o_query_rowbinary(binary, store, profile, profile.source_table, W101O_FULL)
  w101o_query_rowbinary(binary, store, profile, profile.source_table, W101O_KEY_RANGE, true)
  puts "PASS stock #{profile.label}: schema, all streams/marks/bytes, CHECK and full/key-range RowBinary"
  part
end

def w101o_assert_stock_stats_layout(profile : W101OracleProfile, part : String) : Nil
  actual = File.read(File.join(part, "columns.txt")).lines.map(&.strip)
  expected = ["columns format version: 1", "2 columns:", "`pk` UInt64", "`payload` #{profile.canonical_type}"]
  raise "#{profile.label}: stats columns.txt differs" unless actual == expected
  names = Dir.children(part)
  bins = names.select(&.ends_with?(".bin")).sort
  marks = names.select(&.ends_with?(".mrk2")).sort
  key_bin = "#{CrystalClick::StreamName.hash("pk")}.bin"
  key_mark = "#{CrystalClick::StreamName.hash("pk")}.mrk2"
  raise "#{profile.label}: primary-key streams absent" unless bins.includes?(key_bin) && marks.includes?(key_mark)
  # Sparse child streams, stream inventory and offset packing are deliberately
  # observed only; the statistics fixture does not admit the Sparse decoder.
  puts "OBSERVED #{profile.label}: stats stream inventory bins=#{bins.inspect} marks=#{marks.inspect}; payload stream layout unconstrained"
  key_marks = w101o_mark_records(part, "pk")
  raise "#{profile.label}: primary-key marks differ" unless key_marks.map(&.[2]) == W101O_MARK_ROWS
  decoded = CrystalClick::CompressedBlock.decode_all(File.read(File.join(part, key_bin)).to_slice)
  w101o_assert_bytes(String.new(decoded), W101O_KEYS.map { |key| w101o_unsigned_le(key, 8) }.join, "#{profile.label} primary-key physical bytes")
  stats_kind = profile.fields.all? { |field| field.default_count == 0 } ? "Default" : "Sparse"
  w101o_validate_metadata(profile, part, stats_only: true, stats_kind: stats_kind)
  nil
end

def w101o_stats_profile(binary : String, store : String, profile : W101OracleProfile, sql_default : Bool = false) : Nil
  w101o_create_table(binary, store, profile.source_table, profile)
  if sql_default
    w101o_clickhouse(binary, store, "INSERT INTO default.#{profile.source_table} (pk) SELECT toUInt64(number + 1) FROM numbers(5)")
  else
    w101o_clickhouse(binary, store, "INSERT INTO default.#{profile.source_table} FORMAT RowBinary", w101o_insert_input(profile))
  end
  part = w101o_part_path(binary, store, profile.source_table)
  actual = w101o_clickhouse(binary, store, "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{profile.source_table}' ORDER BY position FORMAT TSVRaw").lines.map(&.strip)
  raise "#{profile.label}: stats system.columns differs" unless actual == ["pk UInt64", "payload #{profile.canonical_type}"]
  w101o_assert_stock_stats_layout(profile, part)
  w101o_check(binary, store, profile.source_table, part)
  w101o_query_rowbinary(binary, store, profile, profile.source_table, W101O_FULL)
  w101o_query_rowbinary(binary, store, profile, profile.source_table, W101O_KEY_RANGE, true)
  origin = sql_default ? "SQL DEFAULT" : "explicit RowBinary"
  puts "PASS stock stats #{profile.label}: #{origin}; exact child default counter + CHECK and independent RowBinary; no Sparse payload decode"
end

def w101o_check_source_reader(part : String, profile : W101OracleProfile) : {CrystalClick::WideTupleColumnData, Array(UInt64)}
  key_reader = CrystalClick::WidePart.open_typed(part, "pk")
  tuple_reader = CrystalClick::WidePart.open_typed(part, "payload")
  raise "#{profile.label}: source key marks differ" unless key_reader.mark_row_counts == W101O_READER_MARKS
  raise "#{profile.label}: source Tuple marks differ" unless tuple_reader.mark_row_counts == W101O_READER_MARKS
  keys = key_reader.read_uint64_mark_range("pk", 0, key_reader.mark_count)
  data = tuple_reader.read_tuple_mark_range("payload", 0, tuple_reader.mark_count)
  raise "#{profile.label}: read type differs" unless data.type_name == profile.canonical_type
  raise "#{profile.label}: row count differs" unless data.row_count == W101O_KEYS.size
  profile.fields.each_with_index do |field, field_index|
    column = data.columns[field_index]
    raise "#{profile.label}: leaf order/name/type differs" unless data.fields[field_index].name == field.name && data.fields[field_index].type_name == field.canonical_type
    W101O_FULL.each do |row|
      actual = w101o_actual_raw(field, column, row)
      w101o_assert_bytes(actual, field.raw_rows[row], "#{profile.label} reader #{field.name} row #{row}")
    end
  end
  w101o_assert_bytes(w101o_rowbinary_from_reader(data, keys, profile, W101O_FULL), profile.expected_rowbinary(W101O_FULL), "#{profile.label} stock->reader full RowBinary")
  selected_keys = key_reader.read_uint64_mark_range("pk", 1, 2)
  selected = tuple_reader.read_tuple_mark_range("payload", 1, 2)
  w101o_assert_bytes(w101o_rowbinary_from_reader(selected, selected_keys, profile, W101O_MARK_RANGE), profile.expected_rowbinary(W101O_MARK_RANGE), "#{profile.label} reader physical mark range RowBinary")
  {data, keys}
end

def w101o_rowbinary_from_reader(data : CrystalClick::WideTupleColumnData, keys : Array(UInt64), profile : W101OracleProfile, source_indexes : Array(Int32)) : String
  raise "#{profile.label}: rowbinary key count mismatch" unless keys.size == source_indexes.size
  output = IO::Memory.new
  data.columns.each_with_index do |column, field_index|
    # Shape validation below is independent of buffer value access. The loop
    # is intentionally row-major for ClickHouse RowBinary.
    raise "#{profile.label}: unused reader column #{column.name}" unless column.name == profile.fields[field_index].name
  end
  keys.each_with_index do |key, index|
    output << w101o_unsigned_le(key, 8)
    profile.fields.each_with_index { |field, field_index| output << w101o_actual_raw(field, data.columns[field_index], index.to_i32) }
  end
  output.to_s
end

def w101o_assert_writer_frames(profile : W101OracleProfile, part : String) : Nil
  profile.streams.each do |stream|
    encoded = File.read(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
    records = w101o_mark_records(part, stream)
    raw = profile.expected_stream(stream)
    offset = 0_u64
    row_offset = 0
    records[0...-1].each_with_index do |record, mark_index|
      compressed_offset, decompressed_offset, row_count = record
      raise "#{profile.label} #{stream}: mark #{mark_index} is not at a compressed-frame boundary" unless compressed_offset == offset
      raise "#{profile.label} #{stream}: writer mark has nonzero local decompressed offset" unless decompressed_offset == 0
      raise "#{profile.label} #{stream}: writer mark row count differs" unless row_count == W101O_MARK_ROWS[mark_index]
      width = stream == "pk" ? 8 : profile.fields.find { |field| "payload%2E#{field.name}" == stream }.not_nil!.width
      byte_count = row_count.to_i * width
      frame = CrystalClick::CompressedBlock.decode_frame(encoded, compressed_offset.to_i64)
      expected = raw.byte_slice(row_offset, byte_count)
      w101o_assert_bytes(String.new(frame.output), expected, "#{profile.label} #{stream} frame #{mark_index}")
      # Frame.end_offset is already absolute in the encoded stream.
      offset = frame.end_offset.to_u64
      row_offset += byte_count
    end
    sentinel = records.last
    raise "#{profile.label} #{stream}: writer EOF sentinel differs" unless sentinel == {offset, 0_u64, 0_u64} && offset == encoded.size.to_u64 && row_offset == raw.bytesize
  end
  puts "PASS #{profile.label}: writer marks point at independently decoded frame boundaries"
end

def w101o_write_profile(writer_root : String, profile : W101OracleProfile, data : CrystalClick::WideTupleColumnData, keys : Array(UInt64)) : String
  path = File.join(writer_root, profile.label, "all_1_1_0")
  FileUtils.mkdir_p(File.dirname(path))
  CrystalClick::WidePartWriter.write_uint64_tuple_pair(
    path,
    "pk",
    keys.to_unsafe.to_slice(keys.size),
    "payload",
    profile.input_type,
    data.columns,
    2
  )
  w101o_assert_plain_layout(profile, path, "writer #{profile.label}", require_counters: true)
  w101o_assert_writer_frames(profile, path)
  reader_data, reader_keys = w101o_check_source_reader(path, profile)
  w101o_assert_bytes(w101o_rowbinary_from_reader(reader_data, reader_keys, profile, W101O_FULL), profile.expected_rowbinary(W101O_FULL), "writer #{profile.label} re-read full RowBinary")
  puts "PASS writer #{profile.label}: complete bytes/marks/schema/serialization and exact typed re-read"
  if profile.input_type != profile.canonical_type
    puts "PASS writer #{profile.label}: noncanonical input declaration normalizes to exact persisted schema"
  end
  path
end

def w101o_attach_writer(binary : String, store : String, profile : W101OracleProfile, part : String) : String
  table = profile.writer_table
  w101o_create_table(binary, store, table, profile)
  data_path = w101o_clickhouse(binary, store, "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw").strip
  raise "#{table}: ClickHouse table path absent" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  w101o_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  attached = w101o_part_path(binary, store, table)
  actual = w101o_clickhouse(binary, store, "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw").lines.map(&.strip)
  raise "#{table}: attached type schema differs" unless actual == ["pk UInt64", "payload #{profile.canonical_type}"]
  w101o_check(binary, store, table, attached)
  w101o_query_rowbinary(binary, store, profile, table, W101O_FULL)
  w101o_query_rowbinary(binary, store, profile, table, W101O_KEY_RANGE, true)
  puts "PASS #{table}: ATTACH, canonical schema, stock CHECK, full/key-range RowBinary"
  attached
end

def w101o_actual_row(field : W101OracleField, row : CrystalClick::WideTupleRow) : String
  case field.parameterized_type
  when CrystalClick::WideTupleFixedStringType
    fixed_type = field.parameterized_type.as(CrystalClick::WideTupleFixedStringType)
    value = row[field.name].as(CrystalClick::FixedStringValue)
    raise "#{field.name}: table FixedString width lost" unless value.width == fixed_type.width
    String.new(value.raw_bytes)
  when CrystalClick::WideTupleEnumType
    enum_type = field.parameterized_type.as(CrystalClick::WideTupleEnumType)
    if enum_type.width == 1
      value = row[field.name].as(CrystalClick::Enum8Value)
      raise "#{field.name}: table Enum8 descriptor changed" unless value.definition.entries == enum_type.definition.entries
      w101o_signed_le(value.code.to_i128, 1)
    else
      value = row[field.name].as(CrystalClick::Enum16Value)
      raise "#{field.name}: table Enum16 descriptor changed" unless value.definition.entries == enum_type.definition.entries
      w101o_signed_le(value.code.to_i128, 2)
    end
  when CrystalClick::WideTupleDecimalType
    decimal_type = field.parameterized_type.as(CrystalClick::WideTupleDecimalType)
    case decimal_type.storage_width
    when 4
      value = row[field.name].as(CrystalClick::Decimal32Value)
      w101o_assert_decimal_descriptor(field, value.precision, value.scale)
      w101o_signed_le(value.raw.to_i128, 4)
    when 8
      value = row[field.name].as(CrystalClick::Decimal64Value)
      w101o_assert_decimal_descriptor(field, value.precision, value.scale)
      w101o_signed_le(value.raw.to_i128, 8)
    when 16
      value = row[field.name].as(CrystalClick::Decimal128Value)
      w101o_assert_decimal_descriptor(field, value.precision, value.scale)
      w101o_signed_le(value.raw, 16)
    when 32
      value = row[field.name].as(CrystalClick::Decimal256TupleValue)
      w101o_assert_decimal_descriptor(field, value.precision, value.scale)
      w101o_decimal256_bytes(value.raw)
    else
      raise "#{field.name}: bad Decimal width"
    end
  else
    raise "#{field.name}: unsupported W101 parameterized descriptor"
  end
end

def w101o_table_consumers(part : String, profile : W101OracleProfile, label : String) : Nil
  table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
  full = IO::Memory.new
  seen = [] of Int32
  table.scan_typed do |batch|
    keys = batch.values_for("pk")
    rows = batch.tuple_rows_for("payload")
    raise "#{label}: table batch key/row mismatch" unless keys.size == rows.size
    keys.each_with_index do |key, offset|
      index = (key - 1_u64).to_i32
      seen << index
      full << w101o_unsigned_le(key, 8)
      profile.fields.each do |field|
        actual = w101o_actual_row(field, rows[offset])
        w101o_assert_bytes(actual, field.raw_rows[index], "#{label} table #{field.name} row #{index}")
        full << actual
      end
    end
    nil
  end
  raise "#{label}: table full order differs" unless seen == W101O_FULL
  w101o_assert_bytes(full.to_s, profile.expected_rowbinary(W101O_FULL), "#{label} table full scan")

  window = IO::Memory.new
  window_seen = [] of Int32
  table.scan_typed_window(1_u64, 3) do |batch|
    keys = batch.values_for("pk")
    rows = batch.tuple_rows_for("payload")
    keys.each_with_index do |key, offset|
      index = (key - 1_u64).to_i32
      window_seen << index
      window << w101o_unsigned_le(key, 8)
      profile.fields.each { |field| window << w101o_actual_row(field, rows[offset]) }
    end
    nil
  end
  raise "#{label}: table positional window differs" unless window_seen == W101O_WINDOW
  w101o_assert_bytes(window.to_s, profile.expected_rowbinary(W101O_WINDOW), "#{label} table window")

  candidates = IO::Memory.new
  candidate_seen = [] of Int32
  table.scan_typed_candidate_marks([[1_i32, 2_i32]]) do |batch|
    keys = batch.values_for("pk")
    rows = batch.tuple_rows_for("payload")
    keys.each_with_index do |key, offset|
      index = (key - 1_u64).to_i32
      candidate_seen << index
      candidates << w101o_unsigned_le(key, 8)
      profile.fields.each { |field| candidates << w101o_actual_row(field, rows[offset]) }
    end
    nil
  end
  raise "#{label}: table candidate marks differ" unless candidate_seen == W101O_CANDIDATE
  w101o_assert_bytes(candidates.to_s, profile.expected_rowbinary(W101O_CANDIDATE), "#{label} table candidate marks")
  puts "PASS #{label}: table full/window/candidate scans preserve exact nominal values"
  nil
end

def w101o_catalog_root(root : String, part : String, profile : W101OracleProfile) : String
  database_uuid = "10100000-0000-4000-8000-000000000001"
  table_uuid = "10100000-0000-4000-8000-000000000002"
  metadata = File.join(root, "metadata")
  database = File.join(root, "store", database_uuid[0, 3], database_uuid)
  table = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(metadata)
  FileUtils.mkdir_p(database)
  FileUtils.mkdir_p(table)
  File.write(File.join(metadata, "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  File.write(File.join(database, "events.sql"), "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `pk` UInt64,\n    `payload` #{profile.canonical_type}\n)\nENGINE = MergeTree\nORDER BY pk\n")
  File.write(File.join(table, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table, "detached"))
  copied = File.join(table, "all_1_1_0")
  FileUtils.cp_r(part, copied)
  copied
end

def w101o_catalog_consumers(root : String, part : String, profile : W101OracleProfile) : Nil
  copied = w101o_catalog_root(root, part, profile)
  table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")
  resolved = table.resolved_scan_parts
  raise "catalog: copied writer part not resolved" unless resolved.size == 1 && File.realpath(resolved[0].path) == File.realpath(copied)
  values = table["payload"].values(max_tuple_cells: 1_000_u64)
  raise "catalog: value count differs" unless values.size == W101O_KEYS.size
  payload = IO::Memory.new
  values.each_with_index do |value, row_index|
    row = value.as(CrystalClick::WideTupleRow)
    raise "catalog: Tuple schema differs" unless row.type_name == profile.canonical_type
    profile.fields.each do |field|
      actual = w101o_actual_row(field, row)
      w101o_assert_bytes(actual, field.raw_rows[row_index], "catalog value #{field.name} row #{row_index}")
      payload << actual
    end
  end
  w101o_assert_bytes(payload.to_s, profile.expected_payload_rowbinary(W101O_FULL), "catalog materialized values")

  full = IO::Memory.new
  table.scan_typed(["pk", "payload"]) do |batch|
    keys = batch.values_for("pk")
    rows = batch.tuple_rows_for("payload")
    keys.each_with_index do |key, offset|
      index = (key - 1_u64).to_i32
      full << w101o_unsigned_le(key, 8)
      profile.fields.each { |field| full << w101o_actual_row(field, rows[offset]) }
      raise "catalog full scan row out of range" unless W101O_FULL.includes?(index)
    end
    nil
  end
  w101o_assert_bytes(full.to_s, profile.expected_rowbinary(W101O_FULL), "catalog full scan")

  window = IO::Memory.new
  window_seen = [] of Int32
  table.scan_typed_window(["pk", "payload"], 1_u64, 3) do |batch|
    keys = batch.values_for("pk")
    rows = batch.tuple_rows_for("payload")
    keys.each_with_index do |key, offset|
      index = (key - 1_u64).to_i32
      window_seen << index
      window << w101o_unsigned_le(key, 8)
      profile.fields.each { |field| window << w101o_actual_row(field, rows[offset]) }
    end
    nil
  end
  raise "catalog positional window differs" unless window_seen == W101O_WINDOW
  w101o_assert_bytes(window.to_s, profile.expected_rowbinary(W101O_WINDOW), "catalog positional window")

  # Catalog's supported UInt64 primary-key candidate path selects conservative
  # whole granules and materializes only the requested key column. Apply the
  # exact inclusive predicate to candidate rows at the caller boundary.
  candidate_keys = [] of UInt64
  table.scan_uint64_pk_candidates(["pk"], 3_u64, 5_u64) do |batch|
    candidate_keys.concat(batch.values_for("pk"))
    nil
  end
  raise "catalog UInt64 candidate granules differ" unless candidate_keys == [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
  exact_keys = candidate_keys.select { |key| key >= 3_u64 && key <= 5_u64 }
  raise "catalog UInt64 candidate predicate differs" unless exact_keys == [3_u64, 4_u64, 5_u64]
  puts "PASS catalog: nominal values, full/window Tuple scans and supported UInt64-key candidates"
  nil
end

def w101o_stat_profiles : Array(Tuple(W101OracleProfile, Bool))
  enum_zero = w101o_enum("value", "Enum8", W101O_ENUM8, Array.new(W101O_KEYS.size, 0))
  enum_min = w101o_enum("value", "Enum8", W101O_ENUM8, Array.new(W101O_KEYS.size, -128))
  fixed_type = CrystalClick::WideTupleFixedStringType.new(4)
  fixed_zero = W101OracleField.new("value", "FixedString(4)", fixed_type, Array.new(W101O_KEYS.size) { String.new(Bytes.new(4, 0_u8)) })
  profiles = [
    {W101OracleProfile.new("enum_raw_zero_stats", [enum_zero] of W101OracleField, "0.9375"), false},
    {W101OracleProfile.new("enum_sql_min_stats", [enum_min] of W101OracleField, "0.9375"), true},
    {W101OracleProfile.new("fixed_zero_stats", [fixed_zero] of W101OracleField, "0.9375"), true},
  ] of Tuple(W101OracleProfile, Bool)
  [{"decimal32", 9}, {"decimal64", 18}, {"decimal128", 38}, {"decimal256", 76}].each do |name, precision|
    decimal_type = CrystalClick::WideTupleDecimalType.new(precision, 0)
    field = W101OracleField.new("value", "Decimal(#{precision}, 0)", decimal_type, Array.new(W101O_KEYS.size) { String.new(Bytes.new(decimal_type.storage_width, 0_u8)) })
    profiles << {W101OracleProfile.new("#{name}_raw_zero_stats", [field] of W101OracleField, "0.9375"), false}
  end
  profiles
end

def w101o_carrier_profile(width : Int32, precision : Int32) : W101OracleProfile
  minimum = Array(UInt8).new(width, 0_u8)
  maximum = Array(UInt8).new(width, 0xff_u8)
  minimum[width - 1] = 0x80_u8
  maximum[width - 1] = 0x7f_u8
  negative_one = Array(UInt8).new(width, 0xff_u8)
  zero = Array(UInt8).new(width, 0_u8)
  positive_one = Array(UInt8).new(width, 0_u8)
  positive_one[0] = 1_u8
  raws = [minimum, negative_one, zero, positive_one, maximum].map { |bytes| String.new(bytes.to_unsafe, bytes.size) }
  type = CrystalClick::WideTupleDecimalType.new(precision, 0)
  field = W101OracleField.new("value", "Decimal(#{precision}, 0)", type, raws)
  W101OracleProfile.new("carrier_#{width * 8}", [field] of W101OracleField)
end

binary = ENV["CLICKHOUSE_BIN"]? || raise "set CLICKHOUSE_BIN to pinned ClickHouse 26.7.1.1315"
store = ENV["W101O_STORE"]? || raise "set W101O_STORE to a fresh temporary ClickHouse store"
writer_root = ENV["W101O_WRITER_ROOT"]? || raise "set W101O_WRITER_ROOT to an empty temporary directory"
catalog_root = ENV["W101O_CATALOG_ROOT"]? || raise "set W101O_CATALOG_ROOT to an empty temporary directory"
unless store.starts_with?("/private/tmp/") || store.starts_with?("/tmp/")
  raise "refusing non-temporary ClickHouse store path: #{store}"
end
raise "ClickHouse store must be fresh and empty" unless Dir.exists?(store) && Dir.empty?(store)
raise "writer root must be empty" unless Dir.exists?(writer_root) && Dir.empty?(writer_root)
raise "catalog root must be empty" unless Dir.exists?(catalog_root) && Dir.empty?(catalog_root)
actual_version = w101o_clickhouse(binary, store, "SELECT version() FORMAT TSVRaw").strip
raise "W101 oracle requires ClickHouse #{W101O_VERSION}, got #{actual_version}" unless actual_version == W101O_VERSION

profiles = w101o_singletons_and_mixed
source_parts = Hash(String, String).new
profiles.each { |profile| source_parts[profile.label] = w101o_create_stock_profile(binary, store, profile) }

stats_profiles = w101o_stat_profiles
stats_profiles.each { |profile, sql_default| w101o_stats_profile(binary, store, profile, sql_default) }

mixed = profiles.last
normalization_fields = mixed.fields.select { |field| field.input_type != field.canonical_type }
raise "W101 writer normalization control drift: expected 12 noncanonical leaves" unless normalization_fields.size == 12
mixed_part = source_parts[mixed.label]
mixed_full = w101o_clickhouse(binary, store, "SELECT pk, #{mixed.fields.map { |field| "payload.#{field.name}" }.join(", ")} FROM default.#{mixed.source_table} ORDER BY pk FORMAT RowBinary")
w101o_seeded_wrong_expectation_rejected(mixed_full, mixed.expected_rowbinary(W101O_FULL), "W101 mixed source full RowBinary")

# Reader-to-writer round trips use the independently qualified stock parts,
# never the original in-memory constructor buffers.
writer_targets = profiles.dup
writer_targets.concat([w101o_carrier_profile(4, 9), w101o_carrier_profile(8, 18), w101o_carrier_profile(16, 38), w101o_carrier_profile(32, 76)])
writer_targets.each do |profile|
  source_profile = if profile.label == "mixed"
                     mixed
                   else
                     profile
                   end
  source_part = source_parts[profile.label]?
  unless source_part
    # Raw carrier extrema are separate stock controls because they exceed the
    # declared Decimal(P,S) value range, while retaining the native width bits.
    source_profile = profile
    source_table = profile.source_table
    w101o_create_table(binary, store, source_table, profile)
    w101o_clickhouse(binary, store, "INSERT INTO default.#{source_table} FORMAT RowBinary", w101o_insert_input(profile))
    source_part = w101o_part_path(binary, store, source_table)
    actual = w101o_clickhouse(binary, store, "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{source_table}' ORDER BY position FORMAT TSVRaw").lines.map(&.strip)
    expected = ["pk UInt64", "payload #{profile.canonical_type}"]
    raise "#{profile.label}: carrier stock system.columns differs: #{actual.inspect}" unless actual == expected
    w101o_assert_plain_layout(profile, source_part, "stock #{profile.label}")
    w101o_check(binary, store, source_table, source_part)
    w101o_query_rowbinary(binary, store, profile, source_table, W101O_FULL)
    w101o_query_rowbinary(binary, store, profile, source_table, W101O_KEY_RANGE, true)
  end
  data, keys = w101o_check_source_reader(source_part, source_profile)
  writer_part = w101o_write_profile(writer_root, profile, data, keys)
  attached_part = w101o_attach_writer(binary, store, profile, writer_part)
  w101o_table_consumers(attached_part, profile, profile.label)
  if profile.label == "mixed"
    FileUtils.mkdir_p(File.join(catalog_root, "mixed"))
    catalog_subroot = File.join(catalog_root, "mixed")
    w101o_catalog_consumers(catalog_subroot, attached_part, profile)
  end
end

# Writer-produced all-zero leaves make the library's own root/child default
# counters explicit. This is separate from stock's guard-only all-zero part.
zero_fields = mixed.fields.map(&.zero_like)
zero_profile = W101OracleProfile.new("mixed_writer_all_zero", zero_fields)
zero_columns = zero_profile.columns
zero_part = File.join(writer_root, "mixed_writer_all_zero", "all_1_1_0")
FileUtils.mkdir_p(File.dirname(zero_part))
CrystalClick::WidePartWriter.write_uint64_tuple_pair(
  zero_part, "pk", W101O_KEYS.to_unsafe.to_slice(W101O_KEYS.size), "payload", zero_profile.canonical_type, zero_columns, 2
)
w101o_assert_plain_layout(zero_profile, zero_part, "writer all-zero profile", require_counters: true)
w101o_assert_writer_frames(zero_profile, zero_part)
zero_info = JSON.parse(File.read(File.join(zero_part, "serialization.json"))).as_h
records = zero_info["columns"]?.try(&.as_a) || raise "writer all-zero profile: columns absent"
raise "writer all-zero profile: explicit root/child counters missing" if records.empty?
payload = records.find { |record| record.as_h["name"]?.try(&.as_s) == "payload" }.try(&.as_h) || raise "writer all-zero profile: Tuple root absent"
children = payload["subcolumns"]?.try(&.as_a) || raise "writer all-zero profile: child counters absent"
raise "writer all-zero profile: child count differs" unless children.size == zero_profile.fields.size
w101o_validate_counter(payload, 5, "writer all-zero Tuple root")
zero_profile.fields.each_with_index { |field, index| w101o_validate_counter(children[index].as_h, 5, "writer all-zero #{field.name}") }
w101o_check_source_reader(zero_part, zero_profile)
w101o_attach_writer(binary, store, zero_profile, zero_part)
puts "PASS writer all-zero profile: explicit library root/child default metadata"

puts "PASS W101 bidirectional oracle on ClickHouse #{actual_version}: 8 singleton + 34-leaf stock/read/write/attach profiles, 7 storage-default controls, four Decimal carrier-width controls, and table/catalog consumers"
