# W117 is a paired literal/stock oracle for the generic binary type and value
# codecs. Expected descriptors and payloads below are hand-authored grammar
# vectors; stock output is checked against them, never used to create them.
# The implementation under test is the current crystal-click workspace. The
# ClickHouse grammar reference is source snapshot 935de744, while the stock
# oracle is a distinct runtime build d9bcb5ab; runtime behavior is qualified
# against that binary rather than inferred from source equivalence.
require "../src/crystal_click"

W117_VERSION    = "26.10.1.1201"
W117_BUILD_HASH = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
W117_HEX_DIGITS = "0123456789abcdef".to_slice

class W117Mismatch < Exception
end

struct W117Vector
  getter name : String
  getter type : CrystalClick::BinaryDataType
  getter schema_name : String
  getter descriptor_hex : String
  getter payload_hex : String
  getter sql_expression : String?
  getter value : CrystalClick::BinaryValue

  def initialize(@name : String, @type : CrystalClick::BinaryDataType,
                 @schema_name : String, @descriptor_hex : String,
                 @payload_hex : String, @sql_expression : String?,
                 @value : CrystalClick::BinaryValue)
  end

  def stock_eligible? : Bool
    !@sql_expression.nil?
  end
end

def w117_fail(message : String) : NoReturn
  raise W117Mismatch.new(message)
end

def w117_require(condition : Bool, message : String) : Nil
  w117_fail(message) unless condition
end

def w117_nibble(byte : UInt8) : UInt8
  case byte
  when 48_u8..57_u8  then (byte - 48_u8).to_u8
  when 65_u8..70_u8  then (byte - 55_u8).to_u8
  when 97_u8..102_u8 then (byte - 87_u8).to_u8
  else                    w117_fail("W117 literal contains a non-hex byte")
  end
end

def w117_bytes(hex : String) : Bytes
  source = hex.to_slice
  w117_require(source.size % 2 == 0, "W117 literal hex has an odd number of digits")
  bytes = Bytes.new(source.size // 2, 0_u8)
  bytes.size.times do |index|
    bytes[index] = (w117_nibble(source[index * 2]) << 4) | w117_nibble(source[index * 2 + 1])
  end
  bytes
end

def w117_hex(bytes : Bytes) : String
  String.build do |io|
    bytes.each do |byte|
      io.write_byte(W117_HEX_DIGITS[((byte >> 4) & 0x0f_u8).to_i])
      io.write_byte(W117_HEX_DIGITS[(byte & 0x0f_u8).to_i])
    end
  end
end

def w117_assert_bytes(actual : Bytes, expected : Bytes, label : String) : Nil
  limit = Math.min(actual.size, expected.size)
  offset = 0
  while offset < limit && actual[offset] == expected[offset]
    offset += 1
  end
  return if offset == actual.size && offset == expected.size

  actual_byte = offset < actual.size ? w117_hex(actual[offset, 1]) : "<eof>"
  expected_byte = offset < expected.size ? w117_hex(expected[offset, 1]) : "<eof>"
  w117_fail("W117 #{label}: byte mismatch at offset #{offset} expected #{expected_byte}, got #{actual_byte} (lengths #{expected.size}/#{actual.size})")
end

def w117_raw(type : CrystalClick::BinaryDataType, hex : String) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.fixed(type, w117_bytes(hex))
end

def w117_add(vectors : Array(W117Vector), name : String,
             type : CrystalClick::BinaryDataType, schema_name : String,
             descriptor_hex : String, payload_hex : String,
             sql_expression : String?, value : CrystalClick::BinaryValue) : Nil
  vectors << W117Vector.new(name, type, schema_name, descriptor_hex, payload_hex, sql_expression, value)
end

def w117_vectors : Array(W117Vector)
  vectors = [] of W117Vector

  {
    {"Int8", "07", "ff", "CAST(-1, 'Int8')"},
    {"Int16", "08", "ffff", "CAST(-1, 'Int16')"},
    {"Int32", "09", "ffffffff", "CAST(-1, 'Int32')"},
    {"Int64", "0a", "ffffffffffffffff", "CAST(-1, 'Int64')"},
    {"Int128", "0b", "ffffffffffffffffffffffffffffffff", "CAST('-1', 'Int128')"},
    {"Int256", "0c", "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "CAST('-1', 'Int256')"},
  }.each do |type_name, tag, payload, expression|
    type = CrystalClick::BinaryDataType.primitive(type_name)
    w117_add(vectors, "#{type_name.downcase}_minus_one", type, type_name, tag, payload, expression,
      w117_raw(type, payload))
  end

  {
    {"UInt8", "01", "01", "CAST(1, 'UInt8')"},
    {"UInt16", "02", "0100", "CAST(1, 'UInt16')"},
    {"UInt32", "03", "01000000", "CAST(1, 'UInt32')"},
    {"UInt64", "04", "0100000000000000", "CAST(1, 'UInt64')"},
    {"UInt128", "05", "01000000000000000000000000000000", "CAST('1', 'UInt128')"},
    {"UInt256", "06", "0100000000000000000000000000000000000000000000000000000000000000", "CAST('1', 'UInt256')"},
  }.each do |type_name, tag, payload, expression|
    type = CrystalClick::BinaryDataType.primitive(type_name)
    w117_add(vectors, "#{type_name.downcase}_one", type, type_name, tag, payload, expression,
      w117_raw(type, payload))
  end

  float32 = CrystalClick::BinaryDataType.primitive("Float32")
  w117_add(vectors, "float32_one", float32, "Float32", "0d", "0000803f",
    "reinterpretAsFloat32(toUInt32(1065353216))", CrystalClick::BinaryValue.float32_bits(0x3f800000_u32))
  w117_add(vectors, "float32_negative_zero", float32, "Float32", "0d", "00000080",
    "reinterpretAsFloat32(toUInt32(2147483648))", CrystalClick::BinaryValue.float32_bits(0x80000000_u32))
  w117_add(vectors, "float32_nan_payload", float32, "Float32", "0d", "0100c07f",
    "reinterpretAsFloat32(toUInt32(2143289345))", CrystalClick::BinaryValue.float32_bits(0x7fc00001_u32))

  float64 = CrystalClick::BinaryDataType.primitive("Float64")
  w117_add(vectors, "float64_one", float64, "Float64", "0e", "000000000000f03f",
    "reinterpretAsFloat64(toUInt64(4607182418800017408))", CrystalClick::BinaryValue.float64_bits(0x3ff0000000000000_u64))
  w117_add(vectors, "float64_negative_zero", float64, "Float64", "0e", "0000000000000080",
    "reinterpretAsFloat64(toUInt64(9223372036854775808))", CrystalClick::BinaryValue.float64_bits(0x8000000000000000_u64))
  w117_add(vectors, "float64_nan_payload", float64, "Float64", "0e", "010000000000f87f",
    "reinterpretAsFloat64(toUInt64(9221120237041090561))", CrystalClick::BinaryValue.float64_bits(0x7ff8000000000001_u64))

  bfloat16 = CrystalClick::BinaryDataType.primitive("BFloat16")
  w117_add(vectors, "bfloat16_one", bfloat16, "BFloat16", "31", "803f",
    "CAST(1.0, 'BFloat16')", w117_raw(bfloat16, "803f"))

  string = CrystalClick::BinaryDataType.primitive("String")
  w117_add(vectors, "string_embedded_nul", string, "String", "15", "03610062",
    "unhex('610062')", CrystalClick::BinaryValue.string("a\0b"))
  w117_add(vectors, "string_empty", string, "String", "15", "00",
    "unhex('')", CrystalClick::BinaryValue.string(""))

  fixed_string = CrystalClick::BinaryDataType.fixed_string(3)
  w117_add(vectors, "fixed_string_nul", fixed_string, "FixedString(3)", "1603", "610062",
    "CAST(unhex('610062'), 'FixedString(3)')", w117_raw(fixed_string, "610062"))

  bool = CrystalClick::BinaryDataType.primitive("Bool")
  w117_add(vectors, "bool_true", bool, "Bool", "2d", "01",
    "CAST(1, 'Bool')", CrystalClick::BinaryValue.bool(true))
  w117_add(vectors, "bool_false", bool, "Bool", "2d", "00",
    "CAST(0, 'Bool')", CrystalClick::BinaryValue.bool(false))

  int64 = CrystalClick::BinaryDataType.primitive("Int64")
  nullable_int64 = CrystalClick::BinaryDataType.nullable(int64)
  w117_add(vectors, "nullable_int64_null", nullable_int64, "Nullable(Int64)", "230a", "01",
    "CAST(NULL, 'Nullable(Int64)')", CrystalClick::BinaryValue.nullable(nullable_int64, nil))
  w117_add(vectors, "nullable_int64_value", nullable_int64, "Nullable(Int64)", "230a", "000700000000000000",
    "CAST(toInt64(7), 'Nullable(Int64)')",
    CrystalClick::BinaryValue.nullable(nullable_int64, w117_raw(int64, "0700000000000000")))

  nullable_string = CrystalClick::BinaryDataType.nullable(string)
  w117_add(vectors, "nullable_string_null", nullable_string, "Nullable(String)", "2315", "01",
    "CAST(NULL, 'Nullable(String)')", CrystalClick::BinaryValue.nullable(nullable_string, nil))

  array_nullable_int64 = CrystalClick::BinaryDataType.array(nullable_int64)
  array_nullable_int64_value = CrystalClick::BinaryValue.array(array_nullable_int64, [
    CrystalClick::BinaryValue.nullable(nullable_int64, w117_raw(int64, "0100000000000000")),
    CrystalClick::BinaryValue.nullable(nullable_int64, nil),
    CrystalClick::BinaryValue.nullable(nullable_int64, w117_raw(int64, "0300000000000000")),
  ])
  w117_add(vectors, "array_nullable_int64", array_nullable_int64, "Array(Nullable(Int64))", "1e230a",
    "0300010000000000000001000300000000000000",
    "CAST([toInt64(1), NULL, toInt64(3)], 'Array(Nullable(Int64))')", array_nullable_int64_value)

  array_nullable_string = CrystalClick::BinaryDataType.array(nullable_string)
  array_nullable_string_value = CrystalClick::BinaryValue.array(array_nullable_string, [
    CrystalClick::BinaryValue.nullable(nullable_string, nil),
    CrystalClick::BinaryValue.nullable(nullable_string, CrystalClick::BinaryValue.string("")),
    CrystalClick::BinaryValue.nullable(nullable_string, CrystalClick::BinaryValue.string("a\0b")),
  ])
  w117_add(vectors, "array_nullable_string", array_nullable_string, "Array(Nullable(String))", "1e2315",
    "030100000003610062",
    "CAST([NULL, unhex(''), unhex('610062')], 'Array(Nullable(String))')", array_nullable_string_value)

  array_string = CrystalClick::BinaryDataType.array(string)
  w117_add(vectors, "array_string_empty", array_string, "Array(String)", "1e15", "00",
    "CAST([], 'Array(String)')", CrystalClick::BinaryValue.array(array_string, [] of CrystalClick::BinaryValue))

  tuple_type = CrystalClick::BinaryDataType.tuple([int64, string])
  tuple_value = CrystalClick::BinaryValue.tuple(tuple_type, [
    w117_raw(int64, "0200000000000000"), CrystalClick::BinaryValue.string("a"),
  ])
  w117_add(vectors, "tuple_int64_string", tuple_type, "Tuple(Int64, String)", "1f020a15",
    "02000000000000000161",
    "CAST(tuple(toInt64(2), 'a'), 'Tuple(Int64, String)')", tuple_value)

  named_tuple_type = CrystalClick::BinaryDataType.tuple([int64, string], ["a", "b"])
  named_tuple_value = CrystalClick::BinaryValue.tuple(named_tuple_type, [
    w117_raw(int64, "0200000000000000"), CrystalClick::BinaryValue.string("a"),
  ])
  w117_add(vectors, "named_tuple_int64_string", named_tuple_type, "Tuple(a Int64, b String)",
    "200201610a016215", "02000000000000000161",
    "CAST(tuple(toInt64(2), 'a'), 'Tuple(a Int64, b String)')", named_tuple_value)

  map_string_uint64 = CrystalClick::BinaryDataType.map(string, CrystalClick::BinaryDataType.primitive("UInt64"))
  map_string_uint64_value = CrystalClick::BinaryValue.map(map_string_uint64, [
    CrystalClick::BinaryValue.string("a"), w117_raw(CrystalClick::BinaryDataType.primitive("UInt64"), "0700000000000000"),
  ])
  w117_add(vectors, "map_string_uint64", map_string_uint64, "Map(String, UInt64)", "271504",
    "0101610700000000000000", "map('a', toUInt64(7))", map_string_uint64_value)
  w117_add(vectors, "map_string_uint64_empty", map_string_uint64, "Map(String, UInt64)", "271504",
    "00", "mapFromArrays(CAST([], 'Array(String)'), CAST([], 'Array(UInt64)'))",
    CrystalClick::BinaryValue.map(map_string_uint64, [] of CrystalClick::BinaryValue))

  nullable_tuple_type = CrystalClick::BinaryDataType.nullable(tuple_type)
  nullable_tuple_value = CrystalClick::BinaryValue.nullable(nullable_tuple_type, tuple_value)
  w117_add(vectors, "nullable_tuple_value", nullable_tuple_type, "Nullable(Tuple(Int64, String))",
    "231f020a15", "0002000000000000000161",
    "CAST(tuple(toInt64(2), 'a'), 'Nullable(Tuple(Int64, String))')", nullable_tuple_value)

  array_int64 = CrystalClick::BinaryDataType.array(int64)
  map_array_string = CrystalClick::BinaryDataType.map(array_int64, string)
  map_array_string_value = CrystalClick::BinaryValue.map(map_array_string, [
    CrystalClick::BinaryValue.array(array_int64, [w117_raw(int64, "0100000000000000")]),
    CrystalClick::BinaryValue.string("a"),
  ])
  w117_add(vectors, "map_array_int64_string", map_array_string, "Map(Array(Int64), String)",
    "271e0a15", "010101000000000000000161",
    "CAST(map([toInt64(1)], 'a'), 'Map(Array(Int64), String)')", map_array_string_value)

  nothing = CrystalClick::BinaryDataType.primitive("Nothing")
  w117_add(vectors, "nothing_null_envelope", nothing, "Nothing", "00", "", nil,
    CrystalClick::BinaryValue.null)

  vectors
end

def w117_assert_nominal(vector : W117Vector, value : CrystalClick::BinaryValue) : Nil
  case vector.name
  when "int8_minus_one", "int16_minus_one", "int32_minus_one"
    w117_assert_bytes(value.bytes, w117_bytes(vector.payload_hex), "#{vector.name} raw signed bytes")
  when "int64_minus_one"
    w117_require(value.as_int64 == -1_i64, "#{vector.name}: decoded signed value differs")
  when "uint8_one", "uint16_one", "uint32_one"
    w117_assert_bytes(value.bytes, w117_bytes(vector.payload_hex), "#{vector.name} raw unsigned bytes")
  when "uint64_one"
    w117_require(value.as_uint64 == 1_u64, "#{vector.name}: decoded unsigned value differs")
  when "float32_one"
    w117_require(value.as_float32_bits == 0x3f800000_u32, "Float32 one raw bits differ")
  when "float32_negative_zero"
    w117_require(value.as_float32_bits == 0x80000000_u32, "Float32 negative-zero raw bits differ")
  when "float32_nan_payload"
    w117_require(value.as_float32_bits == 0x7fc00001_u32, "Float32 NaN payload bits differ")
  when "float64_one"
    w117_require(value.as_float64_bits == 0x3ff0000000000000_u64, "Float64 one raw bits differ")
  when "float64_negative_zero"
    w117_require(value.as_float64_bits == 0x8000000000000000_u64, "Float64 negative-zero raw bits differ")
  when "float64_nan_payload"
    w117_require(value.as_float64_bits == 0x7ff8000000000001_u64, "Float64 NaN payload bits differ")
  when "string_embedded_nul"
    w117_require(value.as_string == "a\0b", "String embedded-NUL value differs")
  when "string_empty"
    w117_require(value.as_string.empty?, "empty String is not empty")
  when "fixed_string_nul"
    w117_assert_bytes(value.bytes, w117_bytes("610062"), "FixedString bytes")
  when "bool_true"
    w117_require(value.as_bool, "Bool true decoded false")
  when "bool_false"
    w117_require(!value.as_bool, "Bool false decoded true")
  when "nullable_int64_null", "nullable_string_null"
    w117_require(value.is_null?, "Nullable null flag was lost")
  when "nullable_int64_value"
    w117_require(!value.is_null?, "Nullable non-null flag was lost")
    w117_require(value.elements.size == 1 && value.elements[0].as_int64 == 7_i64,
      "Nullable(Int64) child value differs")
  when "array_nullable_int64"
    elements = value.elements
    w117_require(elements.size == 3, "Array(Nullable(Int64)) element count differs")
    w117_require(!elements[0].is_null? && elements[0].elements[0].as_int64 == 1_i64, "Array first Int64 differs")
    w117_require(elements[1].is_null?, "Array middle Nullable(Int64) is not null")
    w117_require(!elements[2].is_null? && elements[2].elements[0].as_int64 == 3_i64, "Array last Int64 differs")
  when "array_nullable_string"
    elements = value.elements
    w117_require(elements.size == 3 && elements[0].is_null?, "Array Nullable(String) null element differs")
    w117_require(!elements[1].is_null? && elements[1].elements[0].as_string.empty?, "Array empty String differs")
    w117_require(!elements[2].is_null? && elements[2].elements[0].as_string == "a\0b", "Array embedded-NUL String differs")
  when "array_string_empty"
    w117_require(value.elements.empty?, "empty Array(String) has elements")
  when "tuple_int64_string", "named_tuple_int64_string"
    fields = value.elements
    w117_require(fields.size == 2 && fields[0].as_int64 == 2_i64 && fields[1].as_string == "a", "Tuple fields differ")
  when "map_string_uint64"
    entries = value.elements
    w117_require(entries.size == 2 && entries[0].as_string == "a" && entries[1].as_uint64 == 7_u64, "Map entries differ")
  when "map_string_uint64_empty"
    w117_require(value.elements.empty?, "empty Map has entries")
  when "nullable_tuple_value"
    w117_require(!value.is_null?, "Nullable(Tuple) value became null")
    fields = value.elements[0].elements
    w117_require(fields.size == 2 && fields[0].as_int64 == 2_i64 && fields[1].as_string == "a",
      "Nullable(Tuple) child fields differ")
  when "map_array_int64_string"
    entries = value.elements
    w117_require(entries.size == 2 && entries[1].as_string == "a", "Map(Array(Int64), String) value differs")
    w117_require(entries[0].elements.size == 1 && entries[0].elements[0].as_int64 == 1_i64,
      "Map composite Array(Int64) key differs")
  when "nothing_null_envelope"
    w117_require(value.is_null? && value.type.name == "Nothing", "Nothing envelope is not the null sentinel")
  end
end

def w117_assert_local_vectors(vectors : Array(W117Vector)) : Nil
  w117_require(vectors.size >= 30, "W117 literal vector inventory unexpectedly narrowed")
  vectors.each do |vector|
    descriptor = w117_bytes(vector.descriptor_hex)
    payload = w117_bytes(vector.payload_hex)
    w117_require(vector.type.name == vector.schema_name,
      "#{vector.name}: constructed type name differs from literal schema #{vector.schema_name}")
    w117_assert_bytes(CrystalClick::BinaryDataTypeCodec.encode(vector.type), descriptor,
      "#{vector.name} type encode")
    decoded_type = CrystalClick::BinaryDataTypeCodec.decode(descriptor)
    w117_require(decoded_type.name == vector.schema_name, "#{vector.name}: type descriptor decoded to #{decoded_type.name}")
    w117_assert_bytes(CrystalClick::BinaryDataTypeCodec.encode(decoded_type), descriptor,
      "#{vector.name} type decode/encode")

    envelope = descriptor + payload
    w117_assert_bytes(CrystalClick::BinaryValueCodec.encode(vector.value), envelope,
      "#{vector.name} typed-value encode")
    decoded_envelope = CrystalClick::BinaryValueCodec.decode(envelope)
    w117_require(decoded_envelope.type.name == vector.schema_name, "#{vector.name}: envelope type differs")
    w117_assert_bytes(CrystalClick::BinaryValueCodec.encode(decoded_envelope), envelope,
      "#{vector.name} typed-value decode/encode")
    w117_assert_nominal(vector, decoded_envelope)

    if vector.name == "nothing_null_envelope"
      # Nothing is represented only by the envelope's null sentinel; it has no
      # ordinary standalone scalar payload and is not sent to stock as a column.
      w117_require(payload.empty?, "Nothing sentinel unexpectedly has a scalar body")
      next
    end

    w117_assert_bytes(CrystalClick::BinaryValueCodec.encode_value(vector.value), payload,
      "#{vector.name} known-type encode")
    decoded_payload = CrystalClick::BinaryValueCodec.decode_value(vector.type, payload)
    w117_require(decoded_payload.type.name == vector.schema_name, "#{vector.name}: known-type payload type differs")
    w117_assert_bytes(CrystalClick::BinaryValueCodec.encode_value(decoded_payload), payload,
      "#{vector.name} known-type decode/encode")
    w117_assert_nominal(vector, decoded_payload)
  end
  puts "PASS W117 hand-authored literal vectors: #{vectors.size} types/values"
end

def w117_expect_corrupt(label : String, &block : ->) : Nil
  begin
    yield
  rescue error : CrystalClick::CorruptPartError
    puts "PASS W117 corruption control: #{label}"
    return
  end
  w117_fail("W117 corruption control accepted #{label}")
end

def w117_assert_parser_controls(vectors : Array(W117Vector)) : Nil
  bool_type = CrystalClick::BinaryDataType.primitive("Bool")
  noncanonical_true = CrystalClick::BinaryValueCodec.decode_value(bool_type, w117_bytes("02"))
  w117_require(noncanonical_true.as_bool, "Bool reader did not treat nonzero as true")
  w117_assert_bytes(CrystalClick::BinaryValueCodec.encode_value(noncanonical_true), w117_bytes("01"),
    "Bool canonical writer")

  nullable_int64 = CrystalClick::BinaryDataType.nullable(CrystalClick::BinaryDataType.primitive("Int64"))
  w117_expect_corrupt("Nullable flag 02") do
    CrystalClick::BinaryValueCodec.decode_value(nullable_int64, w117_bytes("02"))
  end
  w117_expect_corrupt("truncated Int64 scalar") do
    CrystalClick::BinaryValueCodec.decode_value(CrystalClick::BinaryDataType.primitive("Int64"), w117_bytes("01000000000000"))
  end
  w117_expect_corrupt("nonminimal Array(String) length") do
    CrystalClick::BinaryValueCodec.decode_value(CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.primitive("String")), w117_bytes("8000"))
  end

  int64_vector = vectors.find! { |vector| vector.name == "int64_minus_one" }
  int64_descriptor = w117_bytes(int64_vector.descriptor_hex)
  w117_expect_corrupt("type descriptor trailing byte") do
    CrystalClick::BinaryDataTypeCodec.decode(int64_descriptor + w117_bytes("00"))
  end
  int64_envelope = w117_bytes(int64_vector.descriptor_hex + int64_vector.payload_hex)
  w117_expect_corrupt("typed envelope trailing byte") do
    CrystalClick::BinaryValueCodec.decode(int64_envelope + w117_bytes("00"))
  end

  # These accessors promise snapshots, not aliases into codec state.
  decoded = CrystalClick::BinaryValueCodec.decode_value(int64_vector.type, w117_bytes(int64_vector.payload_hex))
  bytes_snapshot = decoded.bytes
  bytes_snapshot[0] = bytes_snapshot[0] ^ 0x01_u8
  w117_assert_bytes(CrystalClick::BinaryValueCodec.encode_value(decoded), w117_bytes(int64_vector.payload_hex),
    "BinaryValue.bytes snapshot immutability")

  array_vector = vectors.find! { |vector| vector.name == "array_nullable_int64" }
  array_value = CrystalClick::BinaryValueCodec.decode_value(array_vector.type, w117_bytes(array_vector.payload_hex))
  element_snapshot = array_value.elements
  element_snapshot.clear
  w117_require(array_value.elements.size == 3, "BinaryValue.elements snapshot aliased codec state")
  puts "PASS W117 Bool normalization, canonical corruption and snapshot controls"
end

def w117_run(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  error = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: error)
  raise "W117 ClickHouse query failed: #{error.to_s.strip}" unless status.success?
  output.to_s
end

def w117_qualify_runtime(binary : String, store : String) : Nil
  version = w117_run(binary, store, "SELECT version() FORMAT TSVRaw").strip
  w117_require(version == W117_VERSION, "pinned runtime version mismatch: #{version.inspect}")
  hashes = w117_run(binary, store,
    "SELECT value FROM system.build_options WHERE name IN ('GIT_HASH', 'VERSION_GITHASH') ORDER BY name FORMAT TSVRaw").lines.map(&.strip).reject(&.empty?)
  w117_require(!hashes.empty? && hashes.all? { |hash| hash == W117_BUILD_HASH },
    "pinned runtime build hash mismatch: #{hashes.inspect}")
  puts "PASS W117 runtime identity: ClickHouse #{version}, runtime build #{W117_BUILD_HASH}; grammar source snapshot 935de744 is distinct"
end

def w117_stock_write_query(vectors : Array(W117Vector)) : String
  branches = vectors.select(&.stock_eligible?).map do |vector|
    expression = vector.sql_expression || w117_fail("#{vector.name}: missing stock expression")
    "SELECT '#{vector.name}' AS vector, hex(formatRow('RowBinaryWithNamesAndTypes', x)) AS row_hex FROM (SELECT #{expression} AS x)"
  end
  w117_require(!branches.empty?, "W117 has no stock-write vectors")
  "SELECT vector, row_hex FROM (#{branches.join(" UNION ALL ")}) ORDER BY vector SETTINGS output_format_binary_encode_types_in_binary_format=1 FORMAT TSVRaw"
end

def w117_local_row(vector : W117Vector) : Bytes
  header = w117_bytes("010178") # one column, name x
  encoded = CrystalClick::BinaryValueCodec.encode(vector.value)
  row = header + encoded
  expected = w117_bytes("010178#{vector.descriptor_hex}#{vector.payload_hex}")
  w117_assert_bytes(row, expected, "#{vector.name} full one-column row")
  row
end

def w117_stock_read_query(vectors : Array(W117Vector), rows : Hash(String, Bytes)) : String
  branches = vectors.select(&.stock_eligible?).map do |vector|
    row = rows[vector.name]
    row_hex = w117_hex(row)
    "SELECT '#{vector.name}' AS vector, toTypeName(x) AS type_name, hex(formatRow('RowBinaryWithNamesAndTypes', x)) AS row_hex FROM format('RowBinaryWithNamesAndTypes', 'x #{vector.schema_name}', unhex('#{row_hex}'))"
  end
  w117_require(!branches.empty?, "W117 has no stock-read vectors")
  # Request canonical type names so pretty-printed multiline Tuple names do not
  # split a single TSVRaw record across physical lines.
  "SELECT vector, type_name, row_hex FROM (#{branches.join(" UNION ALL ")}) ORDER BY vector SETTINGS input_format_binary_decode_types_in_binary_format=1, output_format_binary_encode_types_in_binary_format=1, print_pretty_type_names=0 FORMAT TSVRaw"
end

def w117_assert_stock_output(output : String, vectors : Array(W117Vector)) : Hash(String, String)
  seen = {} of String => String
  output.lines.each do |line|
    fields = line.split('\t')
    w117_require(fields.size == 2, "malformed stock writer row")
    w117_require(!seen.has_key?(fields[0]), "duplicate stock writer vector #{fields[0]}")
    seen[fields[0]] = fields[1].downcase
  end

  expected_count = vectors.count(&.stock_eligible?)
  w117_require(seen.size == expected_count, "stock writer vector count differs: #{seen.size}/#{expected_count}")
  vectors.each do |vector|
    next unless vector.stock_eligible?
    row = w117_local_row(vector)
    expected_hex = "010178#{vector.descriptor_hex}#{vector.payload_hex}"
    actual_hex = seen[vector.name]? || w117_fail("#{vector.name}: missing stock writer vector")
    w117_require(actual_hex == expected_hex,
      "#{vector.name}: stock writer differed from literal row vector")
    w117_assert_bytes(row, w117_bytes(expected_hex), "#{vector.name} local writer vs stock literal")
  end
  puts "PASS W117 stock writer vs hand-authored row literals: #{expected_count} vectors"
  seen
end

def w117_assert_stock_reader(output : String, vectors : Array(W117Vector), rows : Hash(String, Bytes)) : Nil
  seen = {} of String => {String, String}
  output.lines.each do |line|
    fields = line.split('\t')
    w117_require(fields.size == 3,
      "malformed stock reader row: fields=#{fields.size}, line=#{line.inspect}")
    w117_require(!seen.has_key?(fields[0]), "duplicate stock reader vector #{fields[0]}")
    seen[fields[0]] = {fields[1], fields[2].downcase}
  end

  expected_count = vectors.count(&.stock_eligible?)
  w117_require(seen.size == expected_count, "stock reader vector count differs: #{seen.size}/#{expected_count}")
  vectors.each do |vector|
    next unless vector.stock_eligible?
    record = seen[vector.name]? || w117_fail("#{vector.name}: missing stock reader vector")
    type_name = record[0]
    row_hex = record[1]
    w117_require(type_name == vector.schema_name, "#{vector.name}: stock reader reported type #{type_name.inspect}")
    expected_hex = w117_hex(rows[vector.name])
    w117_require(row_hex == expected_hex, "#{vector.name}: stock reader/re-emitter changed local writer bytes")
  end
  puts "PASS W117 stock reader of local-writer bytes and re-emission: #{expected_count} vectors"
end

def w117_assert_comparator_control(vector : W117Vector) : Nil
  expected = w117_bytes("010178#{vector.descriptor_hex}#{vector.payload_hex}")
  seeded = expected.dup
  seeded[0] = seeded[0] ^ 0x01_u8
  begin
    w117_assert_bytes(seeded, expected, "seeded one-byte perturbation")
  rescue error : W117Mismatch
    w117_require((error.message || "").starts_with?("W117 seeded one-byte perturbation: byte mismatch at offset 0"),
      "W117 one-byte negative control failed for an unrelated reason")
    puts "PASS W117 comparator negative control: rejected one-byte row mutation"
    return
  end
  w117_fail("W117 row comparator accepted a one-byte mutation")
end

def w117_validate_test_store(test_root_arg : String, store_arg : String) : {String, String}
  w117_require(Dir.exists?(test_root_arg) && !File.symlink?(test_root_arg),
    "W117_TEST_ROOT must be an existing non-symlink directory")
  test_root = File.realpath(test_root_arg)
  w117_require(test_root.starts_with?("/private/tmp/"), "W117_TEST_ROOT must resolve beneath /private/tmp")

  expanded_store = File.expand_path(store_arg)
  store_parent = File.realpath(File.dirname(expanded_store))
  store = File.join(store_parent, File.basename(expanded_store))
  w117_require(store_parent == test_root && File.basename(store) == "clickhouse-store" && !File.symlink?(store),
    "W117_STORE must be the isolated clickhouse-store child of W117_TEST_ROOT")
  w117_require(Dir.exists?(store) && Dir.empty?(store), "W117_STORE must be a fresh empty directory")
  {test_root, store}
end

def w117_main : Nil
  binary = ENV["CLICKHOUSE_BIN"]? || w117_fail("CLICKHOUSE_BIN is required")
  store = ENV["W117_STORE"]? || w117_fail("W117_STORE is required")
  test_root = ENV["W117_TEST_ROOT"]? || w117_fail("W117_TEST_ROOT is required")
  test_root, store = w117_validate_test_store(test_root, store)
  w117_qualify_runtime(binary, store)

  vectors = w117_vectors
  w117_assert_local_vectors(vectors)
  w117_assert_parser_controls(vectors)
  w117_assert_comparator_control(vectors.find! { |vector| vector.name == "array_nullable_int64" })

  # Nothing is exercised only as the typed null envelope (00): ClickHouse has
  # no ordinary standalone Nothing column to serve as a stock scalar vector.
  stock_vectors = vectors.select(&.stock_eligible?)
  local_rows = {} of String => Bytes
  stock_vectors.each { |vector| local_rows[vector.name] = w117_local_row(vector) }

  stock_output = w117_run(binary, store, w117_stock_write_query(vectors))
  File.write(File.join(test_root, "stock-writer.tsvraw"), stock_output)
  w117_assert_stock_output(stock_output, vectors)
  stock_input = w117_stock_read_query(vectors, local_rows)
  stock_read_output = w117_run(binary, store, stock_input)
  File.write(File.join(test_root, "stock-reader.tsvraw"), stock_read_output)
  w117_assert_stock_reader(stock_read_output, vectors, local_rows)
  puts "PASS W117 bounded pair: type descriptors, scalar bodies and one-column RowBinaryWithNamesAndTypes"
end

w117_main
