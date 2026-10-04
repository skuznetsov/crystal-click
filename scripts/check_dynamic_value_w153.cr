require "../src/crystal_click"

W153_HEX_DIGITS = "0123456789abcdef".to_slice
alias W153Type = CrystalClick::BinaryDataType
alias W153Value = CrystalClick::BinaryValue

class W153Mismatch < Exception
end

def w153_fail(message : String) : NoReturn
  raise W153Mismatch.new(message)
end

def w153_require(condition : Bool, message : String) : Nil
  w153_fail(message) unless condition
end

def w153_nibble(byte : UInt8) : UInt8
  case byte
  when 48_u8..57_u8  then (byte - 48_u8).to_u8
  when 65_u8..70_u8  then (byte - 55_u8).to_u8
  when 97_u8..102_u8 then (byte - 87_u8).to_u8
  else                    w153_fail("W153 literal contains a non-hex byte")
  end
end

def w153_bytes(hex : String) : Bytes
  source = hex.to_slice
  w153_require(source.size % 2 == 0, "W153 literal hex has an odd number of digits")
  bytes = Bytes.new(source.size // 2, 0_u8)
  bytes.size.times do |index|
    bytes[index] = (w153_nibble(source[index * 2]) << 4) | w153_nibble(source[index * 2 + 1])
  end
  bytes
end

def w153_hex(bytes : Bytes) : String
  String.build do |io|
    bytes.each do |byte|
      io.write_byte(W153_HEX_DIGITS[((byte >> 4) & 0x0f_u8).to_i])
      io.write_byte(W153_HEX_DIGITS[(byte & 0x0f_u8).to_i])
    end
  end
end

def w153_specs : Array(Tuple(String, Int32))
  [
    {"null", 0},
    {"null-explicit-nothing", 0},
    {"u64-42", 0},
    {"u64-42", 1},
    {"u64-42", 254},
    {"string-nul", 0},
    {"nullable-null", 0},
    {"nullable-u64-42", 0},
    {"variant-null", 0},
    {"variant-u64-42", 0},
    {"nested-dynamic-null", 0},
    {"nested-dynamic-u64-42", 0},
    {"array-dynamic-mixed", 0},
    {"array-nothing-empty", 0},
  ] of Tuple(String, Int32)
end

def w153_value(label : String, cap : Int32) : CrystalClick::BinaryValue
  dynamic_type = W153Type.dynamic(cap)
  nothing = W153Type.primitive("Nothing")
  uint64 = W153Type.primitive("UInt64")

  case label
  when "null"
    W153Value.dynamic(dynamic_type)
  when "null-explicit-nothing"
    W153Value.dynamic(dynamic_type, W153Value.null(nothing))
  when "u64-42"
    W153Value.dynamic(dynamic_type, W153Value.uint64(42_u64))
  when "string-nul"
    W153Value.dynamic(dynamic_type, W153Value.string("a\0b"))
  when "nullable-null"
    nullable_type = W153Type.nullable(uint64)
    W153Value.dynamic(dynamic_type, W153Value.nullable(nullable_type))
  when "nullable-u64-42"
    nullable_type = W153Type.nullable(uint64)
    child = W153Value.nullable(nullable_type, W153Value.uint64(42_u64))
    W153Value.dynamic(dynamic_type, child)
  when "variant-null"
    variant_type = W153Type.variant([uint64] of W153Type)
    W153Value.dynamic(dynamic_type, W153Value.variant_null(variant_type))
  when "variant-u64-42"
    variant_type = W153Type.variant([uint64] of W153Type)
    arm = W153Value.variant(variant_type, 0, W153Value.uint64(42_u64))
    W153Value.dynamic(dynamic_type, arm)
  when "nested-dynamic-null"
    nested_type = W153Type.dynamic
    W153Value.dynamic(dynamic_type, W153Value.dynamic(nested_type))
  when "nested-dynamic-u64-42"
    nested_type = W153Type.dynamic
    nested = W153Value.dynamic(nested_type, W153Value.uint64(42_u64))
    W153Value.dynamic(dynamic_type, nested)
  when "array-dynamic-mixed"
    nested_type = W153Type.dynamic
    array_type = W153Type.array(nested_type)
    values = [
      W153Value.dynamic(nested_type, W153Value.uint64(42_u64)),
      W153Value.dynamic(nested_type, W153Value.string("x")),
      W153Value.dynamic(nested_type),
    ] of W153Value
    W153Value.dynamic(dynamic_type, W153Value.array(array_type, values))
  when "array-nothing-empty"
    array_type = W153Type.array(nothing)
    W153Value.dynamic(dynamic_type, W153Value.array(array_type, [] of W153Value))
  else
    w153_fail("unknown W153 fixture #{label.inspect}")
  end
end

def w153_actual_type(value : CrystalClick::BinaryValue) : String
  return "None" if value.is_null?
  value.child_at(0).type.name
end

def w153_semantic_equal?(left : CrystalClick::BinaryValue, right : CrystalClick::BinaryValue) : Bool
  return false unless left.type == right.type
  return false unless left.is_null? == right.is_null?
  return true if left.is_null?

  case left.type.tag
  when CrystalClick::BinaryDataType::TAG_ARRAY,
       CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE,
       CrystalClick::BinaryDataType::TAG_NAMED_TUPLE,
       CrystalClick::BinaryDataType::TAG_MAP,
       CrystalClick::BinaryDataType::TAG_NULLABLE,
       CrystalClick::BinaryDataType::TAG_VARIANT,
       CrystalClick::BinaryDataType::TAG_DYNAMIC,
       CrystalClick::BinaryDataType::TAG_LOW_CARDINALITY
    return false unless left.element_count == right.element_count
    if left.type.tag == CrystalClick::BinaryDataType::TAG_VARIANT
      return false unless left.variant_index? == right.variant_index?
    end
    left.element_count.times do |index|
      return false unless w153_semantic_equal?(left.element_at(index), right.element_at(index))
    end
    true
  else
    left.bytes.to_a == right.bytes.to_a
  end
end

def w153_summary(value : CrystalClick::BinaryValue) : String
  return "#{value.type.name}(NULL)" if value.is_null?
  if value.type.tag == CrystalClick::BinaryDataType::TAG_DYNAMIC
    child = value.child_at(0)
    if child.type.tag == CrystalClick::BinaryDataType::TAG_UINT64
      return "Dynamic(#{child.type.name}=#{child.as_uint64})"
    end
    return "Dynamic(#{child.type.name})"
  end
  value.type.name
end

def w153_verify(label : String, cap : Int32, bytes : Bytes) : CrystalClick::BinaryValue
  expected = w153_value(label, cap)
  decoded = CrystalClick::BinaryValueCodec.decode_value(expected.type, bytes)
  unless w153_semantic_equal?(decoded, expected)
    w153_fail("W153 semantic mismatch [#{label}] nominal=#{expected.type.name} expected=#{w153_summary(expected)} decoded=#{w153_summary(decoded)}")
  end
  reencoded = CrystalClick::BinaryValueCodec.encode_value(decoded)
  unless reencoded.to_a == bytes.to_a
    w153_fail("W153 re-encode mismatch [#{label}] expected=#{w153_hex(bytes)} actual=#{w153_hex(reencoded)}")
  end
  decoded
end

def w153_check_nothing_refusal : Nil
  nothing = CrystalClick::BinaryDataType.primitive("Nothing")
  array_type = CrystalClick::BinaryDataType.array(nothing)
  nonempty = CrystalClick::BinaryValue.array(array_type, [CrystalClick::BinaryValue.null(nothing)] of CrystalClick::BinaryValue)
  begin
    CrystalClick::BinaryValueCodec.encode_value(nonempty)
  rescue ex : CrystalClick::UnsupportedFormatError
    message = ex.message || ""
    unless message.includes?("Nothing has no ordinary non-NULL scalar representation")
      w153_fail("W153 Nothing guard raised an unexpected refusal: #{message.inspect}")
    end
    return
  end
  w153_fail("W153 ordinary nonempty Array(Nothing) unexpectedly encoded")
end

def w153_emit : Nil
  w153_specs.each do |label, cap|
    value = w153_value(label, cap)
    bytes = CrystalClick::BinaryValueCodec.encode_value(value)
    decoded = CrystalClick::BinaryValueCodec.decode_value(value.type, bytes)
    unless w153_semantic_equal?(decoded, value)
      w153_fail("W153 emitter self-check semantic mismatch [#{label}] cap=#{cap}")
    end
    reencoded = CrystalClick::BinaryValueCodec.encode_value(decoded)
    unless reencoded.to_a == bytes.to_a
      w153_fail("W153 emitter self-check re-encode mismatch [#{label}] cap=#{cap}")
    end
    puts ["VALUE", label, cap, value.type.name, w153_actual_type(value), w153_hex(bytes)].join("\t")
  end
  w153_check_nothing_refusal
  puts "GUARD\tarray-nothing-nonempty\trefused\tNothing has no ordinary non-NULL scalar representation"
end

def w153_main : Nil
  if ARGV.size == 1 && ARGV[0] == "--emit"
    w153_emit
  elsif ARGV.size == 4 && ARGV[0] == "--verify"
    label = ARGV[1]
    cap = ARGV[2].to_i?
    cap_value = cap || w153_fail("--verify cap must be between 0 and 254")
    w153_require(0 <= cap_value && cap_value <= 254, "--verify cap must be between 0 and 254")
    bytes = w153_bytes(ARGV[3])
    decoded = w153_verify(label, cap_value, bytes)
    puts ["VERIFIED", label, cap_value, decoded.type.name, w153_actual_type(decoded), w153_hex(bytes)].join("\t")
  else
    w153_fail("usage: check_dynamic_value_w153.cr --emit | --verify CASE CAP HEX")
  end
end

begin
  w153_main
rescue ex : W153Mismatch
  STDERR.puts ex.message
  exit(1)
end
