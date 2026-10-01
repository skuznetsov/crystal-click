# Independent ClickHouse 26.7 stock and Crystal writer certificates for
# Nullable scalar leaves in a named-flat Tuple. Run each mode in a fresh store:
#   --green-reader  stock source + ATTACH qualification, then typed reads
#   --green-writer  library part + stock ATTACH/CHECK/RowBinary, then typed read
require "json"
require "file_utils"
require "../src/crystal_click"

W105G_STOCK_VERSION   = "26.7.1.1315"
W105G_KEYS            = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
W105G_MARK_ROWS       = [2_u64, 2_u64, 1_u64, 0_u64]
W105G_MARK_BOUNDARIES = [0, 2, 4, 5]
W105G_NULLS           = [1_u8, 0_u8, 0_u8, 0_u8, 1_u8]
W105G_SETTINGS        = "index_granularity = 2, index_granularity_bytes = 10485760, enable_mixed_granularity_parts = 1, min_rows_for_wide_part = 0, min_bytes_for_wide_part = 0, ratio_of_defaults_for_sparse_serialization = 0.9375, compress_marks = 0, compress_primary_key = 0, min_compress_block_size = 0, max_compress_block_size = 4096, default_compression_codec = 'LZ4'"

class W105GreenByteMismatch < Exception
end

struct W105GreenField
  getter name : String
  getter base_type : String
  getter nullable : Bool
  getter raw_rows : Array(String?)

  def initialize(@name : String, @base_type : String, @nullable : Bool, raw_rows : Array(String?))
    raise "#{name}: expected five fixture rows" unless raw_rows.size == W105G_KEYS.size
    raise "#{name}: bare leaf cannot contain NULL" if !nullable && raw_rows.any?(&.nil?)
    @raw_rows = raw_rows.dup
  end

  def type_name : String
    nullable ? "Nullable(#{base_type})" : base_type
  end

  def string? : Bool
    base_type == "String"
  end

  def width : Int32
    w105g_width(base_type)
  end

  def stream_rows(writer_profile : Bool = false) : Array(String)
    raw_rows.map_with_index do |value, row|
      if writer_profile && nullable && name == "nullable_bool" && row == 3
        w105g_byte(2_u8)
      elsif writer_profile && nullable && value.nil?
        case name
        when "nullable_enum8"
          row == 0 ? w105g_signed_le(127_i64, 1) : w105g_signed_le(-128_i64, 1)
        when "nullable_bool"
          w105g_byte(row == 0 ? 0xfe_u8 : 0xff_u8)
        when "nullable_decimal_9_2"
          w105g_signed_le(row == 0 ? Int32::MIN.to_i64 : Int32::MAX.to_i64, 4)
        else
          w105g_default_fragment(self)
        end
      else
        value || w105g_default_fragment(self)
      end
    end
  end

  def rowbinary_at(row : Int32, writer_profile : Bool = false) : String
    value = raw_rows[row]
    if nullable
      return "\x01" unless value
      if writer_profile && base_type == "Bool" && row == 3
        # The writer fixture deliberately carries a noncanonical true byte.
        # Keep the expected wire byte raw so the pinned server decides whether
        # RowBinary preserves or normalizes it; this certificate currently
        # requires preservation of the independently seeded carrier.
        return "\x00" + w105g_byte(2_u8)
      end
      return "\x00" + (string? ? w105g_varuint(value.bytesize.to_u64) + value : value)
    end
    raw = value.not_nil!
    string? ? w105g_varuint(raw.bytesize.to_u64) + raw : raw
  end
end

def w105g_width(base_type : String) : Int32
  return 1 if base_type.starts_with?("Enum8(")
  return 2 if base_type.starts_with?("Enum16(")
  case base_type
  when "Int8", "UInt8", "Bool"                                                                                                                                                                                                                                                                                                                                                                         then 1
  when "Int16", "UInt16", "BFloat16", "Date"                                                                                                                                                                                                                                                                                                                                                           then 2
  when "Int32", "UInt32", "Float32", "IPv4", "Date32", "DateTime", "DateTime('UTC')", "Time", "Decimal(9, 2)"                                                                                                                                                                                                                                                                                          then 4
  when "Int64", "UInt64", "Float64", "DateTime64(0)", "DateTime64(1)", "DateTime64(2)", "DateTime64(3)", "DateTime64(4)", "DateTime64(5)", "DateTime64(6)", "DateTime64(7)", "DateTime64(8)", "DateTime64(9)", "DateTime64(9, 'America/New_York')", "Time64(0)", "Time64(1)", "Time64(2)", "Time64(3)", "Time64(4)", "Time64(5)", "Time64(6)", "Time64(7)", "Time64(8)", "Time64(9)", "Decimal(18, 3)" then 8
  when "Int128", "UInt128", "UUID", "Decimal(38, 4)"                                                                                                                                                                                                                                                                                                                                                   then 16
  when "IPv6"                                                                                                                                                                                                                                                                                                                                                                                          then 16
  when "Int256", "UInt256", "Decimal(76, 5)"                                                                                                                                                                                                                                                                                                                                                           then 32
  when "FixedString(5)"                                                                                                                                                                                                                                                                                                                                                                                then 5
  else                                                                                                                                                                                                                                                                                                                                                                                                      raise "no independent width for #{base_type}"
  end
end

def w105g_independent_width(base_type : String) : Int32
  return 1 if base_type.starts_with?("Enum8(")
  return 2 if base_type.starts_with?("Enum16(")
  case base_type
  when "Int8", "UInt8", "Bool"                                                                                                                                                                                                                                                                                                                                                                         then 1
  when "Int16", "UInt16", "BFloat16", "Date"                                                                                                                                                                                                                                                                                                                                                           then 2
  when "Int32", "UInt32", "Float32", "IPv4", "Date32", "DateTime", "DateTime('UTC')", "Time", "Decimal(9, 2)"                                                                                                                                                                                                                                                                                          then 4
  when "Int64", "UInt64", "Float64", "DateTime64(0)", "DateTime64(1)", "DateTime64(2)", "DateTime64(3)", "DateTime64(4)", "DateTime64(5)", "DateTime64(6)", "DateTime64(7)", "DateTime64(8)", "DateTime64(9)", "DateTime64(9, 'America/New_York')", "Time64(0)", "Time64(1)", "Time64(2)", "Time64(3)", "Time64(4)", "Time64(5)", "Time64(6)", "Time64(7)", "Time64(8)", "Time64(9)", "Decimal(18, 3)" then 8
  when "Int128", "UInt128", "UUID", "IPv6", "Decimal(38, 4)"                                                                                                                                                                                                                                                                                                                                           then 16
  when "Int256", "UInt256", "Decimal(76, 5)"                                                                                                                                                                                                                                                                                                                                                           then 32
  when "FixedString(5)"                                                                                                                                                                                                                                                                                                                                                                                then 5
  else                                                                                                                                                                                                                                                                                                                                                                                                      raise "no independently enumerated physical width for #{base_type}"
  end
end

def w105g_byte(value : UInt8) : String
  String.new(Bytes[value])
end

def w105g_unsigned_le(value : UInt64, width : Int32) : String
  raise "negative fixed-width integer size: #{width}" if width < 0
  low_width = Math.min(width, 8)
  String.build do |output|
    low_width.times { |index| output.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
    (width - low_width).times { output.write_byte(0_u8) }
  end
end

def w105g_signed_le(value : Int64, width : Int32) : String
  raise "negative fixed-width integer size: #{width}" if width < 0
  low_width = Math.min(width, 8)
  low = w105g_unsigned_le(value.unsafe_as(UInt64), low_width)
  extension = value < 0 ? 0xff_u8 : 0_u8
  low + String.new(Bytes.new(width - low_width, extension))
end

def w105g_unsigned128_le(value : UInt128) : String
  low = (value & UInt64::MAX.to_u128).to_u64
  high = (value >> 64).to_u64
  w105g_unsigned_le(low, 8) + w105g_unsigned_le(high, 8)
end

def w105g_signed128_le(value : Int128) : String
  w105g_unsigned128_le(value.unsafe_as(UInt128))
end

def w105g_uint256_le(low : UInt128, high : UInt128) : String
  w105g_unsigned128_le(low) + w105g_unsigned128_le(high)
end

def w105g_assert_encoder_vectors : Nil
  zero15 = String.new(Bytes.new(15, 0_u8))
  zero31 = String.new(Bytes.new(31, 0_u8))
  ff8 = String.new(Bytes.new(8, 0xff_u8))
  ff16 = String.new(Bytes.new(16, 0xff_u8))
  raise "UInt128 little-endian zero extension differs" unless w105g_unsigned_le(1_u64, 16) == "\x01" + zero15
  raise "UInt256 little-endian zero extension differs" unless w105g_unsigned_le(1_u64, 32) == "\x01" + zero31
  raise "Int128 little-endian sign extension differs" unless w105g_signed_le(-1_i64, 16) == ff16
  raise "Int256 little-endian sign extension differs" unless w105g_signed_le(-1_i64, 32) == ff16 + ff16
  raise "UInt64 little-endian vector differs" unless w105g_unsigned_le(0x0102_0304_0506_0708_u64, 8) == "\x08\x07\x06\x05\x04\x03\x02\x01"
  raise "Int64 negative little-endian vector differs" unless w105g_signed_le(-1_i64, 8) == ff8
  ipv6 = w105g_rows("nullable_ipv6", "IPv6", true)[2].not_nil!
  expected_ipv6 = "\x20\x01\x0d\xb8\x85\xa3\x00\x00\x00\x00\x8a\x2e\x03\x70\x73\x34"
  raise "IPv6 fixture must be exactly 16 network-order bytes" unless w105g_width("IPv6") == 16 && ipv6 == expected_ipv6
  puts "PASS W105 independent fixture vectors: LE 8/16/32-byte extension and 16-byte IPv6"
end

def w105g_unsigned_be(value : UInt64, width : Int32) : String
  String.build do |output|
    width.times do |index|
      shift = (width - index - 1) * 8
      output.write_byte(((value >> shift) & 0xff_u64).to_u8)
    end
  end
end

def w105g_varuint(value : UInt64) : String
  String.build do |output|
    remaining = value
    while remaining >= 0x80_u64
      output.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
      remaining >>= 7
    end
    output.write_byte(remaining.to_u8)
  end
end

def w105g_default_fragment(field : W105GreenField) : String
  field.string? ? "" : String.new(Bytes.new(field.width, 0_u8))
end

def w105g_float_rows(base_type : String) : Array(String?)
  case base_type
  when "Float32"
    [nil, w105g_unsigned_le(0_u64, 4), w105g_unsigned_le(0x3f80_0000_u64, 4), w105g_unsigned_le(0x4000_0000_u64, 4), nil] of String?
  when "Float64"
    [nil, w105g_unsigned_le(0_u64, 8), w105g_unsigned_le(0x3ff0_0000_0000_0000_u64, 8), w105g_unsigned_le(0x4000_0000_0000_0000_u64, 8), nil] of String?
  when "BFloat16"
    [nil, w105g_unsigned_le(0_u64, 2), w105g_unsigned_le(0x3f80_u64, 2), w105g_unsigned_le(0x4000_u64, 2), nil] of String?
  else
    raise "unsupported float fixture #{base_type}"
  end
end

def w105g_rows(name : String, base_type : String, nullable : Bool) : Array(String?)
  if base_type == "String"
    return nullable ? [nil, "", "a\0b", "tail", nil] of String? : ["keep", "", "x", "y", ""] of String?
  end

  if base_type.starts_with?("Enum8")
    return [nil, w105g_signed_le(-7_i64, 1), w105g_signed_le(4_i64, 1), w105g_signed_le(-7_i64, 1), nil] of String?
  elsif base_type.starts_with?("Enum16")
    return [nil, w105g_signed_le(-300_i64, 2), w105g_signed_le(400_i64, 2), w105g_signed_le(-300_i64, 2), nil] of String?
  elsif base_type == "UUID"
    zero = String.new(Bytes.new(16, 0_u8))
    one = w105g_unsigned_le(1_u64, 8) + w105g_unsigned_le(2_u64, 8)
    two = w105g_unsigned_le(3_u64, 8) + w105g_unsigned_le(4_u64, 8)
    return nullable ? [nil, zero, one, two, nil] of String? : [one, zero, one, two, zero] of String?
  elsif base_type == "IPv4"
    zero = String.new(Bytes.new(4, 0_u8))
    one = w105g_unsigned_le(0x0102_0304_u64, 4)
    two = w105g_unsigned_le(0xaabb_ccdd_u64, 4)
    return nullable ? [nil, zero, one, two, nil] of String? : [one, zero, one, two, zero] of String?
  elsif base_type == "IPv6"
    zero = String.new(Bytes.new(16, 0_u8))
    one = w105g_unsigned_be(0x2001_0db8_85a3_0000_u64, 8) + w105g_unsigned_be(0x0000_8a2e_0370_7334_u64, 8)
    two = w105g_unsigned_be(1_u64, 8) + w105g_unsigned_be(2_u64, 8)
    return nullable ? [nil, zero, one, two, nil] of String? : [one, zero, one, two, zero] of String?
  elsif base_type == "FixedString(5)"
    return [nil, String.new(Bytes.new(5, 0_u8)), "abcde", "xyz12", nil] of String?
  elsif base_type == "Bool"
    return [nil, w105g_byte(0_u8), w105g_byte(1_u8), w105g_byte(0_u8), nil] of String?
  elsif base_type.starts_with?("Float") || base_type == "BFloat16"
    return w105g_float_rows(base_type)
  end

  width = w105g_width(base_type)
  zero = w105g_unsigned_le(0_u64, width)
  one = w105g_unsigned_le(1_u64, width)
  two = w105g_unsigned_le(2_u64, width)
  if nullable
    [nil, zero, one, two, nil] of String?
  else
    [w105g_unsigned_le(99_u64, width), zero, one, two, zero] of String?
  end
end

def w105g_nullable_base_types : Array(String)
  types = [
    "Int8", "UInt8", "Int16", "UInt16", "Int32", "UInt32", "Int64", "UInt64",
    "Int128", "UInt128", "Int256", "UInt256", "Float32", "Float64", "BFloat16", "Bool",
    "String", "UUID", "IPv4", "IPv6", "Date", "Date32", "DateTime", "Time",
  ]
  10.times { |precision| types << "DateTime64(#{precision})" }
  10.times { |precision| types << "Time64(#{precision})" }
  types.concat([
    "DateTime('UTC')", "DateTime64(9, 'America/New_York')", "FixedString(5)",
    "Enum8('negative' = -7, 'positive' = 4)", "Enum16('negative' = -300, 'positive' = 400)",
    "Decimal(9, 2)", "Decimal(18, 3)", "Decimal(38, 4)", "Decimal(76, 5)",
  ])
  raise "W105 green declaration set differs: #{types.size}, expected 53" unless types.size == 53
  types
end

def w105g_assert_fixture_widths(fields : Array(W105GreenField)) : Nil
  fields.each do |field|
    next if field.string?
    expected_width = w105g_independent_width(field.base_type)
    raise "#{field.name}: instrument width table differs from independent width" unless field.width == expected_width
    [false, true].each do |writer_profile|
      field.stream_rows(writer_profile).each_with_index do |fragment, row|
        raise "#{field.name} row #{row}: expected #{expected_width} physical bytes, got #{fragment.bytesize}" unless fragment.bytesize == expected_width
      end
    end
  end
  puts "PASS W105 independent width census: all fixed-width nullable and bare fixture fragments"
end

def w105g_fields : Array(W105GreenField)
  fields = [
    W105GreenField.new("bare_u64", "UInt64", false, [
      w105g_unsigned_le(99_u64, 8), w105g_unsigned_le(0_u64, 8), w105g_unsigned_le(1_u64, 8),
      w105g_unsigned_le(2_u64, 8), w105g_unsigned_le(0_u64, 8),
    ] of String?),
    W105GreenField.new("bare_string", "String", false, ["keep", "", "x", "y", ""] of String?),
  ] of W105GreenField
  w105g_nullable_base_types.each_with_index do |base_type, index|
    name = "nullable_#{index.to_s.rjust(2, '0')}"
    # Stable names for the deliberate masked-payload writer controls.
    name = "nullable_enum8" if base_type.starts_with?("Enum8")
    name = "nullable_bool" if base_type == "Bool"
    name = "nullable_decimal_9_2" if base_type == "Decimal(9, 2)"
    fields << W105GreenField.new(name, base_type, true, w105g_rows(name, base_type, true))
  end
  raise "W105 green profile must contain two bare leaves and all 53 Nullable declarations" unless fields.size == 55
  fields
end

def w105g_physical_bytes_at(
  buffer : CrystalClick::WideTupleLeafColumn::Buffer,
  base_type : String,
  row : Int32,
) : String
  if base_type.starts_with?("Enum8(")
    return w105g_signed_le(buffer.as(Array(Int8))[row].to_i64, 1)
  elsif base_type.starts_with?("Enum16(")
    return w105g_signed_le(buffer.as(Array(Int16))[row].to_i64, 2)
  elsif base_type.starts_with?("Decimal(")
    case base_type
    when "Decimal(9, 2)"  then return w105g_signed_le(buffer.as(Array(Int32))[row].to_i64, 4)
    when "Decimal(18, 3)" then return w105g_signed_le(buffer.as(Array(Int64))[row], 8)
    when "Decimal(38, 4)" then return w105g_signed128_le(buffer.as(Array(Int128))[row])
    when "Decimal(76, 5)"
      value = buffer.as(Array(CrystalClick::Int256Value))[row]
      return w105g_uint256_le(value.low, value.high)
    else
      raise "#{base_type}: no independent Decimal raw-buffer encoder"
    end
  elsif base_type == "String"
    return String.new(buffer.as(Array(String))[row].to_slice)
  elsif base_type == "FixedString(5)"
    return String.new(buffer.as(Array(CrystalClick::FixedStringValue))[row].raw_bytes)
  elsif base_type == "Bool"
    return w105g_byte(buffer.as(Array(UInt8))[row])
  elsif base_type == "UUID"
    value = buffer.as(Array(CrystalClick::UUIDValue))[row]
    return w105g_unsigned_le(value.high, 8) + w105g_unsigned_le(value.low, 8)
  elsif base_type == "IPv4"
    return w105g_unsigned_le(buffer.as(Array(CrystalClick::IPv4Value))[row].network_order.to_u64, 4)
  elsif base_type == "IPv6"
    value = buffer.as(Array(CrystalClick::IPv6Value))[row]
    return w105g_unsigned_be(value.high, 8) + w105g_unsigned_be(value.low, 8)
  elsif base_type.starts_with?("DateTime64(")
    return w105g_signed_le(buffer.as(Array(CrystalClick::DateTime64Value))[row].raw, 8)
  elsif base_type.starts_with?("Time64(")
    return w105g_signed_le(buffer.as(Array(CrystalClick::Time64Value))[row].raw, 8)
  elsif base_type == "Date"
    return w105g_unsigned_le(buffer.as(Array(CrystalClick::DateValue))[row].raw.to_u64, 2)
  elsif base_type == "Date32"
    return w105g_signed_le(buffer.as(Array(CrystalClick::Date32Value))[row].raw.to_i64, 4)
  elsif base_type.starts_with?("DateTime")
    return w105g_unsigned_le(buffer.as(Array(CrystalClick::DateTimeValue))[row].raw.to_u64, 4)
  elsif base_type == "Time"
    return w105g_signed_le(buffer.as(Array(CrystalClick::TimeValue))[row].raw.to_i64, 4)
  end

  case base_type
  when "Int8"    then w105g_signed_le(buffer.as(Array(Int8))[row].to_i64, 1)
  when "UInt8"   then w105g_unsigned_le(buffer.as(Array(UInt8))[row].to_u64, 1)
  when "Int16"   then w105g_signed_le(buffer.as(Array(Int16))[row].to_i64, 2)
  when "UInt16"  then w105g_unsigned_le(buffer.as(Array(UInt16))[row].to_u64, 2)
  when "Int32"   then w105g_signed_le(buffer.as(Array(Int32))[row].to_i64, 4)
  when "UInt32"  then w105g_unsigned_le(buffer.as(Array(UInt32))[row].to_u64, 4)
  when "Int64"   then w105g_signed_le(buffer.as(Array(Int64))[row], 8)
  when "UInt64"  then w105g_unsigned_le(buffer.as(Array(UInt64))[row], 8)
  when "Int128"  then w105g_signed128_le(buffer.as(Array(Int128))[row])
  when "UInt128" then w105g_unsigned128_le(buffer.as(Array(UInt128))[row])
  when "Int256"
    value = buffer.as(Array(CrystalClick::Int256Value))[row]
    w105g_uint256_le(value.low, value.high)
  when "UInt256"
    value = buffer.as(Array(CrystalClick::UInt256Value))[row]
    w105g_uint256_le(value.low, value.high)
  when "Float32"
    w105g_unsigned_le(buffer.as(Array(Float32))[row].unsafe_as(UInt32).to_u64, 4)
  when "Float64"
    w105g_unsigned_le(buffer.as(Array(Float64))[row].unsafe_as(UInt64), 8)
  when "BFloat16"
    w105g_unsigned_le(buffer.as(Array(CrystalClick::BFloat16Value))[row].bits.to_u64, 2)
  else
    raise "#{base_type}: no independent physical-buffer encoder"
  end
end

def w105g_logical_bytes(value : CrystalClick::WideTupleLeafColumn::Value, base_type : String) : String
  if base_type.starts_with?("Enum8(")
    enum_value = value.as?(CrystalClick::Enum8Value) || raise "#{base_type}: expected Enum8Value"
    return w105g_signed_le(enum_value.code.to_i64, 1)
  elsif base_type.starts_with?("Enum16(")
    enum_value = value.as?(CrystalClick::Enum16Value) || raise "#{base_type}: expected Enum16Value"
    return w105g_signed_le(enum_value.code.to_i64, 2)
  elsif base_type.starts_with?("Decimal(")
    case base_type
    when "Decimal(9, 2)"
      decimal = value.as?(CrystalClick::Decimal32Value) || raise "Decimal32 value required"
      return w105g_signed_le(decimal.raw.to_i64, 4)
    when "Decimal(18, 3)"
      decimal = value.as?(CrystalClick::Decimal64Value) || raise "Decimal64 value required"
      return w105g_signed_le(decimal.raw, 8)
    when "Decimal(38, 4)"
      decimal = value.as?(CrystalClick::Decimal128Value) || raise "Decimal128 value required"
      return w105g_signed128_le(decimal.raw)
    when "Decimal(76, 5)"
      decimal = value.as?(CrystalClick::Decimal256TupleValue) || raise "Decimal256TupleValue required"
      return w105g_uint256_le(decimal.raw.low, decimal.raw.high)
    else
      raise "#{base_type}: no independent logical Decimal encoder"
    end
  elsif base_type == "String"
    string = value.as?(String) || raise "String value required"
    return String.new(string.to_slice)
  elsif base_type == "FixedString(5)"
    return String.new((value.as?(CrystalClick::FixedStringValue) || raise "FixedStringValue required").raw_bytes)
  elsif base_type == "Bool"
    raise "Bool value required" unless value.is_a?(Bool)
    return w105g_byte(value.as(Bool) ? 1_u8 : 0_u8)
  elsif base_type == "UUID"
    uuid = value.as?(CrystalClick::UUIDValue) || raise "UUIDValue required"
    return w105g_unsigned_le(uuid.high, 8) + w105g_unsigned_le(uuid.low, 8)
  elsif base_type == "IPv4"
    return w105g_unsigned_le((value.as?(CrystalClick::IPv4Value) || raise "IPv4Value required").network_order.to_u64, 4)
  elsif base_type == "IPv6"
    ipv6 = value.as?(CrystalClick::IPv6Value) || raise "IPv6Value required"
    return w105g_unsigned_be(ipv6.high, 8) + w105g_unsigned_be(ipv6.low, 8)
  elsif base_type.starts_with?("DateTime64(")
    return w105g_signed_le((value.as?(CrystalClick::DateTime64Value) || raise "DateTime64Value required").raw, 8)
  elsif base_type.starts_with?("Time64(")
    return w105g_signed_le((value.as?(CrystalClick::Time64Value) || raise "Time64Value required").raw, 8)
  elsif base_type == "Date"
    return w105g_unsigned_le((value.as?(CrystalClick::DateValue) || raise "DateValue required").raw.to_u64, 2)
  elsif base_type == "Date32"
    return w105g_signed_le((value.as?(CrystalClick::Date32Value) || raise "Date32Value required").raw.to_i64, 4)
  elsif base_type.starts_with?("DateTime")
    return w105g_unsigned_le((value.as?(CrystalClick::DateTimeValue) || raise "DateTimeValue required").raw.to_u64, 4)
  elsif base_type == "Time"
    return w105g_signed_le((value.as?(CrystalClick::TimeValue) || raise "TimeValue required").raw.to_i64, 4)
  end

  case base_type
  when "Int8"
    integer = value.as?(Int8) || raise "Int8 value required"
    w105g_signed_le(integer.to_i64, 1)
  when "UInt8"
    integer = value.as?(UInt8) || raise "UInt8 value required"
    w105g_unsigned_le(integer.to_u64, 1)
  when "Int16"
    integer = value.as?(Int16) || raise "Int16 value required"
    w105g_signed_le(integer.to_i64, 2)
  when "UInt16"
    integer = value.as?(UInt16) || raise "UInt16 value required"
    w105g_unsigned_le(integer.to_u64, 2)
  when "Int32"
    integer = value.as?(Int32) || raise "Int32 value required"
    w105g_signed_le(integer.to_i64, 4)
  when "UInt32"
    integer = value.as?(UInt32) || raise "UInt32 value required"
    w105g_unsigned_le(integer.to_u64, 4)
  when "Int64"
    integer = value.as?(Int64) || raise "Int64 value required"
    w105g_signed_le(integer, 8)
  when "UInt64"
    integer = value.as?(UInt64) || raise "UInt64 value required"
    w105g_unsigned_le(integer, 8)
  when "Int128"
    w105g_signed128_le(value.as?(Int128) || raise "Int128 value required")
  when "UInt128"
    w105g_unsigned128_le(value.as?(UInt128) || raise "UInt128 value required")
  when "Int256"
    integer = value.as?(CrystalClick::Int256Value) || raise "Int256Value required"
    w105g_uint256_le(integer.low, integer.high)
  when "UInt256"
    integer = value.as?(CrystalClick::UInt256Value) || raise "UInt256Value required"
    w105g_uint256_le(integer.low, integer.high)
  when "Float32"
    w105g_unsigned_le((value.as?(Float32) || raise "Float32 value required").unsafe_as(UInt32).to_u64, 4)
  when "Float64"
    w105g_unsigned_le((value.as?(Float64) || raise "Float64 value required").unsafe_as(UInt64), 8)
  when "BFloat16"
    w105g_unsigned_le((value.as?(CrystalClick::BFloat16Value) || raise "BFloat16Value required").bits.to_u64, 2)
  else
    raise "#{base_type}: no independent logical value encoder"
  end
end

def w105g_assert_logical_metadata(value : CrystalClick::WideTupleLeafColumn::Value, base_type : String, row : Int32, expected_raw : String) : Nil
  if base_type.starts_with?("Enum8(")
    enum_value = value.as?(CrystalClick::Enum8Value) || raise "#{base_type}: decoded value is not Enum8Value"
    code = row == 2 ? 4_i8 : -7_i8
    label = code == -7_i8 ? "negative" : "positive"
    raise "#{base_type}: Enum8 code/label differs" unless enum_value.code == code && enum_value.label == label
  elsif base_type.starts_with?("Enum16(")
    enum_value = value.as?(CrystalClick::Enum16Value) || raise "#{base_type}: decoded value is not Enum16Value"
    code = row == 2 ? 400_i16 : -300_i16
    label = code == -300_i16 ? "negative" : "positive"
    raise "#{base_type}: Enum16 code/label differs" unless enum_value.code == code && enum_value.label == label
  elsif base_type.starts_with?("Decimal(")
    match = /\ADecimal\(([0-9]+), ([0-9]+)\)\z/.match(base_type) || raise "#{base_type}: Decimal precision/scale parse failed"
    precision = match[1].to_i
    scale = match[2].to_i
    decimal = value.as?(CrystalClick::Decimal32Value | CrystalClick::Decimal64Value | CrystalClick::Decimal128Value | CrystalClick::Decimal256TupleValue) || raise "#{base_type}: decoded value is not a Decimal wrapper"
    raise "#{base_type}: Decimal precision/scale differs" unless decimal.precision == precision && decimal.scale == scale
  elsif base_type.starts_with?("DateTime64(")
    match = /\ADateTime64\(([0-9])/.match(base_type) || raise "#{base_type}: precision parse failed"
    temporal = value.as?(CrystalClick::DateTime64Value) || raise "#{base_type}: decoded value is not DateTime64Value"
    raise "#{base_type}: raw ticks/precision differ" unless w105g_signed_le(temporal.raw, 8) == expected_raw && temporal.precision == match[1].to_u8
  elsif base_type.starts_with?("Time64(")
    match = /\ATime64\(([0-9])\)\z/.match(base_type) || raise "#{base_type}: precision parse failed"
    temporal = value.as?(CrystalClick::Time64Value) || raise "#{base_type}: decoded value is not Time64Value"
    raise "#{base_type}: raw ticks/precision differ" unless w105g_signed_le(temporal.raw, 8) == expected_raw && temporal.precision == match[1].to_u8
  end
end

def w105g_type_name(fields : Array(W105GreenField)) : String
  "Tuple(#{fields.map { |field| "#{field.name} #{field.type_name}" }.join(", ")})"
end

def w105g_expected_streams(fields : Array(W105GreenField), writer_profile : Bool = false) : Array({String, Array(String)})
  streams = [{"pk", W105G_KEYS.map { |key| w105g_unsigned_le(key, 8) }}]
  fields.each do |field|
    if field.nullable
      streams << {"payload%2E#{field.name}.null", W105G_NULLS.map { |value| w105g_byte(value) }}
    end
    payload = field.stream_rows(writer_profile)
    if field.string?
      sizes = payload.map { |value| w105g_unsigned_le(value.bytesize.to_u64, 8) }
      streams << {"payload%2E#{field.name}.size", sizes}
    end
    streams << {"payload%2E#{field.name}", payload}
  end
  streams
end

def w105g_expected_substreams(fields : Array(W105GreenField)) : String
  children = fields.flat_map do |field|
    names = [] of String
    names << "payload%2E#{field.name}.null" if field.nullable
    names << "payload%2E#{field.name}.size" if field.string?
    names << "payload%2E#{field.name}"
    names
  end
  lines = [
    "columns substreams version: 1", "2 columns:",
    "1 substreams for column `pk`:", "\tpk", "#{children.size} substreams for column `payload`:",
  ]
  children.each { |name| lines << "\t#{name}" }
  lines.join("\n") + "\n"
end

def w105g_inventory_context(lines : Array(String), index : Int32) : String
  first = index > 0 ? index - 1 : 0
  last = index + 2 < lines.size ? index + 2 : lines.size
  context = [] of String
  (first...last).each do |line_index|
    context << "#{line_index + 1}:#{lines[line_index].chomp}"
  end
  context << "#{index + 1}:<eof>" if index >= lines.size
  context.join(" | ")
end

def w105g_assert_substreams(actual : String, expected : String, label : String) : Nil
  return if actual == expected
  actual_lines = actual.lines
  expected_lines = expected.lines
  limit = Math.min(actual_lines.size, expected_lines.size)
  index = 0
  while index < limit && actual_lines[index] == expected_lines[index]
    index += 1
  end
  raise "#{label}: substream inventory/order differs at line #{index + 1} (expected #{expected_lines.size} lines, got #{actual_lines.size}); expected context [#{w105g_inventory_context(expected_lines, index)}], actual context [#{w105g_inventory_context(actual_lines, index)}]"
end

def w105g_expected_columns(type_name : String) : String
  "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` #{type_name}\n"
end

def w105g_expected_rowbinary(fields : Array(W105GreenField), indexes : Array(Int32), writer_profile : Bool = false) : String
  String.build do |output|
    indexes.each do |row|
      output << w105g_unsigned_le(W105G_KEYS[row], 8)
      fields.each { |field| output << field.rowbinary_at(row, writer_profile) }
    end
  end
end

def w105g_assert_bytes(actual : String, expected : String, label : String) : Nil
  return if actual == expected
  limit = Math.min(actual.bytesize, expected.bytesize)
  offset = 0
  while offset < limit && actual.to_slice[offset] == expected.to_slice[offset]
    offset += 1
  end
  got = offset < actual.bytesize ? actual.to_slice[offset].to_s(16).rjust(2, '0') : "<eof>"
  wanted = offset < expected.bytesize ? expected.to_slice[offset].to_s(16).rjust(2, '0') : "<eof>"
  raise W105GreenByteMismatch.new("#{label}: expected #{expected.bytesize} bytes, got #{actual.bytesize}; first difference #{offset}: expected #{wanted}, got #{got}")
end

def w105g_seeded_comparator_check(actual : String, expected : String, label : String) : Nil
  w105g_assert_bytes(actual, expected, "#{label} baseline")
  raise "#{label}: cannot seed an empty expectation" if expected.empty?
  damaged = String.new(expected.to_slice)
  damaged.to_unsafe[0] = damaged.to_slice[0] ^ 0x01_u8
  rejected = false
  begin
    w105g_assert_bytes(actual, damaged, "#{label} seeded mismatch")
  rescue ex : W105GreenByteMismatch
    rejected = true
  end
  raise "#{label}: seeded mismatch was accepted" unless rejected
end

def w105g_clickhouse(binary : String, store : String, query : String, input : IO? = nil) : String
  output = IO::Memory.new
  error = IO::Memory.new
  status = if input
             Process.run(binary, ["local", "--path", store, "--query", query], input: input, output: output, error: error)
           else
             Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: error)
           end
  raise "ClickHouse failed: #{error}\n#{query}" unless status.success?
  output.to_s
end

def w105g_insert(binary : String, store : String, table : String, fields : Array(W105GreenField)) : Nil
  input = IO::Memory.new(w105g_expected_rowbinary(fields, [0, 1, 2, 3, 4]).to_slice)
  w105g_clickhouse(binary, store, "INSERT INTO default.#{table} FORMAT RowBinary", input)
  nil
end

def w105g_create_table(binary : String, store : String, table : String, type_name : String) : Nil
  w105g_clickhouse(binary, store, "CREATE TABLE default.#{table} (pk UInt64, payload #{type_name}) ENGINE = MergeTree ORDER BY pk SETTINGS #{W105G_SETTINGS}")
  nil
end

def w105g_part_path(binary : String, store : String, table : String) : String
  rows = w105g_clickhouse(binary, store, "SELECT path, part_type, rows FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw").lines.map(&.strip).reject(&.empty?)
  raise "#{table}: expected one five-row Wide part, got #{rows.inspect}" unless rows.size == 1
  parts = rows[0].split('\t')
  raise "#{table}: malformed system.parts record" unless parts.size == 3 && parts[1] == "Wide" && parts[2] == "5"
  parts[0]
end

def w105g_schema(binary : String, store : String, table : String, type_name : String) : Nil
  actual = w105g_clickhouse(binary, store, "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw").lines.map(&.strip)
  expected = ["pk UInt64", "payload #{type_name}"]
  raise "#{table}: exact system.columns declarations differ" unless actual == expected
  nil
end

def w105g_check(binary : String, store : String, table : String, part : String) : Nil
  actual = w105g_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  expected = "#{File.basename(part.chomp("/"))}\t1"
  raise "#{table}: CHECK TABLE differs: #{actual.inspect}" unless actual == expected
  nil
end

def w105g_attach(binary : String, store : String, table : String, type_name : String, source_part : String) : String
  w105g_create_table(binary, store, table, type_name)
  data_path = w105g_clickhouse(binary, store, "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw").strip
  raise "#{table}: ClickHouse data path is empty" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(source_part, File.join(detached, "all_1_1_0"))
  w105g_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  w105g_part_path(binary, store, table)
end

def w105g_select(binary : String, store : String, table : String, fields : Array(W105GreenField), selected : Bool = false) : String
  projection = ["pk"] + fields.map { |field| "payload.#{field.name}" }
  predicate = selected ? " WHERE pk >= 2 AND pk < 5" : ""
  w105g_clickhouse(binary, store, "SELECT #{projection.join(", ")} FROM default.#{table}#{predicate} ORDER BY pk FORMAT RowBinary")
end

def w105g_read_marks(part : String, stream : String) : Array({UInt64, UInt64, UInt64})
  bytes = File.read(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")).to_slice
  size = CrystalClick::WidePart::MARK_SIZE
  raise "#{stream}: partial mark record" unless bytes.size % size == 0
  Array({UInt64, UInt64, UInt64}).new(bytes.size // size) do |index|
    offset = index * size
    values = Array(UInt64).new(3) do |field|
      start = offset + field * 8
      8.times.reduce(0_u64) { |value, byte| value | (bytes[start + byte].to_u64 << (byte * 8)) }
    end
    {values[0], values[1], values[2]}
  end
end

def w105g_lz4_literal_frame_size(raw_size : Int32) : UInt64
  raise "writer frame must be nonempty" if raw_size <= 0
  extension_bytes = raw_size < 15 ? 0 : ((raw_size - 15) // 255) + 1
  (25 + 1 + raw_size + extension_bytes).to_u64
end

def w105g_expected_stock_marks(fragments : Array(String)) : Array({UInt64, UInt64, UInt64})
  W105G_MARK_BOUNDARIES.each_with_index.map do |boundary, index|
    decompressed = fragments[0, boundary].sum(&.bytesize).to_u64
    {0_u64, decompressed, W105G_MARK_ROWS[index]}
  end.to_a
end

def w105g_expected_writer_marks(fragments : Array(String)) : Array({UInt64, UInt64, UInt64})
  marks = [] of {UInt64, UInt64, UInt64}
  compressed_offset = 0_u64
  (W105G_MARK_ROWS.size - 1).times do |mark_index|
    first = W105G_MARK_BOUNDARIES[mark_index]
    after_last = W105G_MARK_BOUNDARIES[mark_index + 1]
    row_count = after_last - first
    raw_chunk = fragments[first, row_count].join
    marks << {compressed_offset, 0_u64, row_count.to_u64}
    compressed_offset += w105g_lz4_literal_frame_size(raw_chunk.bytesize) unless raw_chunk.empty?
  end
  marks << {compressed_offset, 0_u64, 0_u64}
  marks
end

def w105g_expected_serialization_defaults(field : W105GreenField) : Int32
  return W105G_NULLS.count(1_u8).to_i32 if field.nullable
  if field.string?
    field.raw_rows.count { |value| value == "" }.to_i32
  else
    zero = w105g_default_fragment(field)
    field.raw_rows.count { |value| value == zero }.to_i32
  end
end

def w105g_assert_serialization(part : String, fields : Array(W105GreenField), label : String) : Nil
  info = JSON.parse(File.read(File.join(part, "serialization.json"))).as_h
  expected_keys = ["columns", "propagate_types_serialization_versions_to_nested_types", "types_serialization_versions", "version"].sort
  raise "#{label}: serialization.json envelope differs: #{info.keys.sort.inspect}" unless info.keys.sort == expected_keys
  raise "#{label}: serialization.json version differs" unless info["version"]?.try(&.as_i) == 1
  raise "#{label}: nested type propagation differs" unless info["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool) == true
  versions = info["types_serialization_versions"]?.try(&.as_h) || raise "#{label}: type-version map missing"
  raise "#{label}: exact String serialization version differs" unless versions.size == 1 && versions["string"]?.try(&.as_i) == 1
  records = info["columns"]?.try(&.as_a) || raise "#{label}: columns metadata missing"
  record_names = records.map { |record| record.as_h["name"]?.try(&.as_s) || raise "#{label}: serializer record name missing" }
  raise "#{label}: tuple/key serializer record order differs" unless record_names == ["payload", "pk"]
  payload = records[0].as_h
  raise "#{label}: root kind/row/default stats differ" unless payload["kind"]?.try(&.as_s) == "Default" && payload["num_rows"]?.try(&.as_i) == 5_i64 && payload["num_defaults"]?.try(&.as_i) == 1_i64
  children = payload["subcolumns"]?.try(&.as_a) || raise "#{label}: child serializer records missing"
  raise "#{label}: child serializer count differs" unless children.size == fields.size
  fields.each_with_index do |field, index|
    record = children[index].as_h
    expected_defaults = w105g_expected_serialization_defaults(field)
    raise "#{label}: child #{field.name} serializer stats differ" unless record["kind"]?.try(&.as_s) == "Default" && record["num_rows"]?.try(&.as_i) == 5_i64 && record["num_defaults"]?.try(&.as_i) == expected_defaults.to_i64
  end
  key = records[1].as_h
  raise "#{label}: key serializer stats differ" unless key["kind"]?.try(&.as_s) == "Default" && key["num_rows"]?.try(&.as_i) == 5_i64 && key["num_defaults"]?.try(&.as_i) == 0_i64
  puts "PASS #{label}: exact serializer envelope, 55 child counters, and mixed Tuple root-default count 1"
end

def w105g_assert_layout(part : String, fields : Array(W105GreenField), writer_profile : Bool, label : String) : Nil
  type_name = w105g_type_name(fields)
  raise "#{label}: columns.txt differs" unless File.read(File.join(part, "columns.txt")) == w105g_expected_columns(type_name)
  w105g_assert_substreams(File.read(File.join(part, "columns_substreams.txt")), w105g_expected_substreams(fields), label)
  raise "#{label}: compression codec differs" unless File.read(File.join(part, "default_compression_codec.txt")) == "CODEC(LZ4)"
  raise "#{label}: metadata version differs" unless File.read(File.join(part, "metadata_version.txt")) == "0"
  raise "#{label}: checksums.txt missing" unless File.file?(File.join(part, "checksums.txt"))

  streams = w105g_expected_streams(fields, writer_profile)
  expected_bins = streams.map { |(name, _)| "#{CrystalClick::StreamName.hash(name)}.bin" }.sort
  expected_marks = streams.map { |(name, _)| "#{CrystalClick::StreamName.hash(name)}.mrk2" }.sort
  entries = Dir.children(part)
  raise "#{label}: complete .bin inventory differs" unless entries.select(&.ends_with?(".bin")).sort == expected_bins
  raise "#{label}: complete .mrk2 inventory differs" unless entries.select(&.ends_with?(".mrk2")).sort == expected_marks
  raise "#{label}: unexpected alternate mark files" if entries.any? { |entry| entry.ends_with?(".cmrk2") || entry.ends_with?(".mrk") }
  streams.each do |name, fragments|
    encoded = File.read(File.join(part, "#{CrystalClick::StreamName.hash(name)}.bin")).to_slice
    observed = String.new(CrystalClick::CompressedBlock.decode_all(encoded))
    expected = fragments.join
    w105g_assert_bytes(observed, expected, "#{label} #{name} raw bytes")
    actual_marks = w105g_read_marks(part, name)
    expected_marks = writer_profile ? w105g_expected_writer_marks(fragments) : w105g_expected_stock_marks(fragments)
    raise "#{label}: #{name} exact mark tuples differ: #{actual_marks.inspect} vs #{expected_marks.inspect}" unless actual_marks == expected_marks
  end
  w105g_assert_serialization(part, fields, label)
  if enum_field = fields.find { |field| field.name == "nullable_enum8" }
    stream = "payload%2E#{enum_field.name}"
    observed = String.new(CrystalClick::CompressedBlock.decode_all(File.read(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice))
    w105g_seeded_comparator_check(observed, streams.find { |entry| entry[0] == stream }.not_nil![1].join, "#{label} Enum hidden-slot stream")
  end
  puts "PASS #{label}: exact schema, #{streams.size} streams, independent raw bytes, marks, and serialization metadata"
end

def w105g_check_rowbinary(binary : String, store : String, table : String, fields : Array(W105GreenField), label : String, writer_profile : Bool = false) : Nil
  full = w105g_select(binary, store, table, fields)
  w105g_assert_bytes(full, w105g_expected_rowbinary(fields, [0, 1, 2, 3, 4], writer_profile), "#{label} full RowBinary")
  selected = w105g_select(binary, store, table, fields, true)
  w105g_assert_bytes(selected, w105g_expected_rowbinary(fields, [1, 2, 3], writer_profile), "#{label} selected RowBinary")
  puts "PASS #{label}: independent full and selected RowBinary bytes"
end

def w105g_writer_columns(source_columns : Array(CrystalClick::WideTupleLeafColumn)) : Array(CrystalClick::WideTupleLeafColumn)
  source_columns.map do |column|
    case column.name
    when "nullable_enum8"
      raw = column.physical_values.as(Array(Int8))
      raw[0] = 127_i8
      raw[4] = Int8::MIN
      CrystalClick::WideTupleLeafColumn.new(column.name, column.leaf_type, raw, column.null_map.not_nil!)
    when "nullable_bool"
      raw = column.physical_values.as(Array(UInt8))
      raw[0] = 0xfe_u8
      raw[3] = 2_u8
      raw[4] = 0xff_u8
      CrystalClick::WideTupleLeafColumn.new(column.name, column.leaf_type, raw, column.null_map.not_nil!)
    when "nullable_decimal_9_2"
      raw = column.physical_values.as(Array(Int32))
      raw[0] = Int32::MIN
      raw[4] = Int32::MAX
      CrystalClick::WideTupleLeafColumn.new(column.name, column.leaf_type, raw, column.null_map.not_nil!)
    else
      column.owned_copy
    end
  end
end

def w105g_assert_typed(part_path : String, fields : Array(W105GreenField), label : String, writer_profile : Bool = false) : Nil
  reader = CrystalClick::WidePart.open_typed(part_path, "payload")
  data = reader.read_tuple_mark_range("payload", 0, reader.mark_count)
  raise "#{label}: typed reader row/field count differs" unless data.row_count == W105G_KEYS.size && data.columns.size == fields.size
  data.fields.each_with_index do |field, index|
    expected = fields[index]
    raise "#{label}: exact typed field identity differs at #{index}" unless field.name == expected.name && field.type_name == expected.type_name
    column = data.columns[index]
    raise "#{label}: leaf declaration differs for #{expected.name}" unless column.type_name == expected.type_name
    if expected.base_type.starts_with?("DateTime")
      datetime = column.datetime_type || raise "#{label}: DateTime leaf lost its exact descriptor for #{expected.name}"
      raise "#{label}: DateTime exact leaf spelling differs for #{expected.name}" unless datetime.leaf_type_name == expected.base_type
    end
    expected_fragments = expected.stream_rows(writer_profile)
    physical = column.physical_values
    if expected.nullable
      raise "#{label}: NULL map differs for #{expected.name}" unless column.null_map.not_nil!.bytes == W105G_NULLS
      values = column.values.as(Array(CrystalClick::WideTupleLeafColumn::Value))
      raise "#{label}: NULL logical view size differs for #{expected.name}" unless values.size == W105G_KEYS.size
    else
      raise "#{label}: bare leaf acquired NULL metadata" unless column.null_map.nil?
    end
    W105G_KEYS.size.times do |row|
      actual_physical = w105g_physical_bytes_at(physical, expected.base_type, row)
      w105g_assert_bytes(actual_physical, expected_fragments[row], "#{label} #{expected.name} row #{row} physical carrier")
      value = column.value_at(row)
      if expected.nullable && W105G_NULLS[row] == 1_u8
        raise "#{label}: row #{row} must be logically NULL for #{expected.name}" unless value.nil?
        next
      end
      raise "#{label}: row #{row} must be non-NULL for #{expected.name}" if value.nil?
      if expected.base_type == "Bool"
        expected_truth = expected_fragments[row].to_slice[0] != 0_u8
        raise "#{label}: Bool false/true/nonzero semantics differ at row #{row}" unless value.is_a?(Bool) && value.as(Bool) == expected_truth
      else
        logical_bytes = w105g_logical_bytes(value, expected.base_type)
        w105g_assert_bytes(logical_bytes, expected_fragments[row], "#{label} #{expected.name} row #{row} typed-to-wire value")
      end
      w105g_assert_logical_metadata(value, expected.base_type, row, expected_fragments[row])
    end
    copy = column.owned_copy
    raise "#{label}: detached copy lost exact declaration for #{expected.name}" unless copy.type_name == column.type_name
    copied_physical = copy.physical_values
    W105G_KEYS.size.times do |row|
      copied_raw = w105g_physical_bytes_at(copied_physical, expected.base_type, row)
      w105g_assert_bytes(copied_raw, expected_fragments[row], "#{label} #{expected.name} row #{row} copied physical carrier")
    end
    if expected.nullable
      raise "#{label}: detached copy lost exact mask for #{expected.name}" unless copy.null_map.not_nil!.bytes == W105G_NULLS
    end
  end

  selected = reader.read_tuple_mark_range("payload", 1, 1)
  raise "#{label}: selected typed range row count differs" unless selected.row_count == 2
  raise "#{label}: selected exact field identities differ" unless selected.fields.map { |field| {field.name, field.type_name} } == data.fields.map { |field| {field.name, field.type_name} }
  selected.columns.each_with_index do |column, index|
    expected = fields[index]
    if expected.nullable
      raise "#{label}: selected mask is not row-exact for #{column.name}" unless column.null_map.not_nil!.bytes == [0_u8, 0_u8]
    end
    selected_physical = column.physical_values
    selected_rows = [2, 3]
    selected_rows.each_with_index do |source_row, selected_row|
      actual_raw = w105g_physical_bytes_at(selected_physical, expected.base_type, selected_row)
      w105g_assert_bytes(actual_raw, expected.stream_rows(writer_profile)[source_row], "#{label} selected #{expected.name} row #{source_row} physical carrier")
    end
  end
  puts "PASS #{label}: all 53 Nullable descriptors, every-row typed-to-wire values, hidden raw carriers, copies, masks, full and selected reads"
end

def w105g_run_reader(binary : String, store : String, fields : Array(W105GreenField)) : Nil
  type_name = w105g_type_name(fields)
  w105g_create_table(binary, store, "w105g_stock_source", type_name)
  w105g_insert(binary, store, "w105g_stock_source", fields)
  source_part = w105g_part_path(binary, store, "w105g_stock_source")
  w105g_schema(binary, store, "w105g_stock_source", type_name)
  w105g_assert_layout(source_part, fields, false, "W105 green stock source")
  w105g_check(binary, store, "w105g_stock_source", source_part)
  w105g_check_rowbinary(binary, store, "w105g_stock_source", fields, "W105 green stock source")

  attached_part = w105g_attach(binary, store, "w105g_stock_attached", type_name, source_part)
  w105g_schema(binary, store, "w105g_stock_attached", type_name)
  w105g_assert_layout(attached_part, fields, false, "W105 green stock ATTACH")
  w105g_check(binary, store, "w105g_stock_attached", attached_part)
  w105g_check_rowbinary(binary, store, "w105g_stock_attached", fields, "W105 green stock ATTACH")
  w105g_assert_typed(attached_part, fields, "W105 green stock typed reader")
  puts "PASS W105 green reader phase: 53 Nullable declarations plus bare UInt64/String mixed controls qualified"
end

def w105g_run_writer(binary : String, store : String, fields : Array(W105GreenField)) : Nil
  type_name = w105g_type_name(fields)
  w105g_create_table(binary, store, "w105g_writer_seed", type_name)
  w105g_insert(binary, store, "w105g_writer_seed", fields)
  seed_part = w105g_part_path(binary, store, "w105g_writer_seed")
  w105g_schema(binary, store, "w105g_writer_seed", type_name)
  w105g_assert_layout(seed_part, fields, false, "W105 green writer input seed")
  w105g_check(binary, store, "w105g_writer_seed", seed_part)
  w105g_check_rowbinary(binary, store, "w105g_writer_seed", fields, "W105 green writer input seed")
  seed_attached = w105g_attach(binary, store, "w105g_writer_seed_attached", type_name, seed_part)
  w105g_schema(binary, store, "w105g_writer_seed_attached", type_name)
  w105g_assert_layout(seed_attached, fields, false, "W105 green writer input seed ATTACH")
  w105g_check(binary, store, "w105g_writer_seed_attached", seed_attached)
  w105g_check_rowbinary(binary, store, "w105g_writer_seed_attached", fields, "W105 green writer input seed ATTACH")
  seed_reader = CrystalClick::WidePart.open_typed(seed_attached, "payload")
  seed_data = seed_reader.read_tuple_mark_range("payload", 0, seed_reader.mark_count)
  columns = w105g_writer_columns(seed_data.columns)
  writer_type = "Tuple(#{columns.map { |column| "#{column.name} #{column.type_name}" }.join(", ")})"
  raise "W105 writer type identity differs" unless writer_type == type_name

  writer_root = File.join(File.dirname(store), "w105-green-writer")
  raise "refusing writer fixture outside temporary root" unless writer_root.starts_with?("/private/tmp/") || writer_root.starts_with?("/tmp/")
  FileUtils.mkdir_p(writer_root)
  writer_part = File.join(writer_root, "all_1_1_0")
  raise "writer output path already exists" if File.exists?(writer_part)
  CrystalClick::WidePartWriter.write_uint64_tuple_pair(
    writer_part, "pk", W105G_KEYS.to_unsafe.to_slice(W105G_KEYS.size), "payload", writer_type, columns, 2
  )

  w105g_assert_layout(writer_part, fields, true, "W105 green library writer")
  attached_part = w105g_attach(binary, store, "w105g_writer_attached", type_name, writer_part)
  w105g_schema(binary, store, "w105g_writer_attached", type_name)
  w105g_assert_layout(attached_part, fields, true, "W105 green writer ATTACH")
  w105g_check(binary, store, "w105g_writer_attached", attached_part)
  w105g_check_rowbinary(binary, store, "w105g_writer_attached", fields, "W105 green writer ATTACH", true)
  w105g_assert_typed(attached_part, fields, "W105 green writer typed reader", true)
  puts "PASS W105 green writer phase: 53 Nullable declarations, mixed bare controls, and masked Enum/Bool/Decimal raw slots qualified"
end

binary = ENV["CLICKHOUSE_BIN"]? || raise "set CLICKHOUSE_BIN to pinned ClickHouse 26.7.1.1315"
store = ENV["W105_STORE"]? || raise "set W105_STORE to a fresh temporary ClickHouse store directory"
unless store.starts_with?("/private/tmp/") || store.starts_with?("/tmp/")
  raise "refusing non-temporary W105_STORE path: #{store}"
end
if Dir.exists?(store)
  raise "W105_STORE must be empty: #{store}" unless Dir.empty?(store)
else
  Dir.mkdir_p(store)
end

mode = ARGV.shift? || raise "usage: --green-reader | --green-writer"
raise "unknown W105 green mode: #{mode}" unless {"--green-reader", "--green-writer"}.includes?(mode)
version_output = IO::Memory.new
version_status = Process.run(binary, ["local", "--version"], output: version_output)
raise "could not read stock ClickHouse version" unless version_status.success?
expected_version = "ClickHouse local version #{W105G_STOCK_VERSION} (official build)."
raise "W105 green oracle requires #{expected_version}, got #{version_output.to_s.strip}" unless version_output.to_s.strip == expected_version
puts "Stock oracle: #{version_output.to_s.strip}"

w105g_assert_encoder_vectors
fields = w105g_fields
w105g_assert_fixture_widths(fields)
raise "W105 Nullable matrix count differs" unless fields.count(&.nullable) == 53
if mode == "--green-reader"
  w105g_run_reader(binary, store, fields)
else
  w105g_run_writer(binary, store, fields)
end
