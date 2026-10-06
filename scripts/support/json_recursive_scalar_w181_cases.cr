require "digest/sha256"
require "json"
require "../../src/crystal_click"

module W181JSONRecursiveScalarCases
  ORACLE_BINARY_SHA256 = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
  ORACLE_VERSION       = "26.10.1.1201"
  ORACLE_BUILD_HASH    = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
  BASELINE_REVISION    = "f2c2e17"

  struct Profile
    getter id : String
    getter type : CrystalClick::BinaryDataType
    getter type_name : String
    getter child_type : CrystalClick::BinaryDataType
    getter child_type_name : String
    getter descriptor : Bytes
    getter row : Bytes
    getter value : CrystalClick::BinaryValue
    getter typed_path : Bool

    def initialize(
      @id : String,
      @type : CrystalClick::BinaryDataType,
      @type_name : String,
      @child_type : CrystalClick::BinaryDataType,
      @child_type_name : String,
      @descriptor : Bytes,
      @row : Bytes,
      @value : CrystalClick::BinaryValue,
      @typed_path : Bool,
    )
    end
  end

  def self.require!(condition : Bool, message : String) : Nil
    raise message unless condition
  end

  def self.bytes_from_hex(hex : String) : Bytes
    unless hex.bytesize.even?
      raise ArgumentError.new("W181 hex literal has an odd byte count")
    end
    source = hex.to_slice
    Bytes.new(source.size // 2) do |index|
      (hex_nibble(source[index * 2]) << 4) | hex_nibble(source[index * 2 + 1])
    end
  end

  private def self.hex_nibble(byte : UInt8) : UInt8
    case byte
    when 0x30_u8..0x39_u8 then byte - 0x30_u8
    when 0x41_u8..0x46_u8 then byte - 0x41_u8 + 10_u8
    when 0x61_u8..0x66_u8 then byte - 0x61_u8 + 10_u8
    else
      raise ArgumentError.new("W181 hex literal contains a non-hex digit")
    end
  end

  def self.concat_bytes(parts : Array(Bytes)) : Bytes
    size = parts.sum(&.size)
    output = Bytes.new(size)
    offset = 0
    parts.each do |part|
      part.each_with_index do |byte, index|
        output[offset + index] = byte
      end
      offset += part.size
    end
    output
  end

  def self.path_prefix : Bytes
    Bytes[0x01_u8, 0x04_u8, 0x69_u8, 0x74_u8, 0x65_u8, 0x6d_u8]
  end

  def self.typed_json_descriptor(child_descriptor : Bytes) : Bytes
    concat_bytes([
      Bytes[0x30_u8, 0x00_u8, 0x80_u8, 0x08_u8, 0x20_u8, 0x01_u8],
      Bytes[0x04_u8, 0x69_u8, 0x74_u8, 0x65_u8, 0x6d_u8],
      child_descriptor,
      Bytes[0x00_u8, 0x00_u8],
    ] of Bytes)
  end

  def self.runtime_json_descriptor : Bytes
    Bytes[0x30_u8, 0x00_u8, 0x80_u8, 0x08_u8, 0x20_u8, 0x00_u8, 0x00_u8, 0x00_u8]
  end

  def self.typed_profile(
    id : String,
    child_type : CrystalClick::BinaryDataType,
    child_type_name : String,
    child_descriptor_hex : String,
    child_row_hex : String,
    child_value : CrystalClick::BinaryValue,
  ) : Profile
    type = CrystalClick::BinaryDataType.json(
      typed_paths: {"item" => child_type} of String => CrystalClick::BinaryDataType,
    )
    type_name = "JSON(item #{child_type_name})"
    value = CrystalClick::BinaryValue.json(
      type,
      CrystalClick::BinaryJsonRow.new(
        type,
        [{"item", child_value}] of Tuple(String, CrystalClick::BinaryValue),
      ),
    )
    descriptor = typed_json_descriptor(bytes_from_hex(child_descriptor_hex))
    row = concat_bytes([path_prefix, bytes_from_hex(child_row_hex)] of Bytes)
    Profile.new(id, type, type_name, child_type, child_type_name, descriptor, row, value, true)
  end

  def self.runtime_profile(
    id : String,
    child_type : CrystalClick::BinaryDataType,
    child_type_name : String,
    child_descriptor_hex : String,
    child_row_hex : String,
    child_value : CrystalClick::BinaryValue,
  ) : Profile
    type = CrystalClick::BinaryDataType.json
    value = CrystalClick::BinaryValue.json(
      type,
      CrystalClick::BinaryJsonRow.new(
        type,
        [{"item", child_value}] of Tuple(String, CrystalClick::BinaryValue),
      ),
    )
    descriptor = runtime_json_descriptor
    row = concat_bytes([
      path_prefix,
      bytes_from_hex(child_descriptor_hex),
      bytes_from_hex(child_row_hex),
    ] of Bytes)
    Profile.new(id, type, "JSON", child_type, child_type_name, descriptor, row, value, false)
  end

  def self.build_profiles : Array(Profile)
    string = CrystalClick::BinaryDataType.primitive("String")
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")

    low_string = CrystalClick::BinaryDataType.low_cardinality(string)
    low_string_value = CrystalClick::BinaryValue.low_cardinality(
      low_string,
      CrystalClick::BinaryValue.string("a"),
    )

    variant = CrystalClick::BinaryDataType.variant([uint8, string] of CrystalClick::BinaryDataType)
    variant_value = CrystalClick::BinaryValue.variant(
      variant,
      1,
      CrystalClick::BinaryValue.fixed(uint8, Bytes[0x2a_u8]),
    )
    variant_null = CrystalClick::BinaryValue.variant_null(variant)

    nullable_uint8 = CrystalClick::BinaryDataType.nullable(uint8)
    array_nullable_uint8 = CrystalClick::BinaryDataType.array(nullable_uint8)
    dynamic = CrystalClick::BinaryDataType.dynamic
    dynamic_selected = CrystalClick::BinaryValue.array(array_nullable_uint8, [
      CrystalClick::BinaryValue.nullable(nullable_uint8),
      CrystalClick::BinaryValue.nullable(
        nullable_uint8,
        CrystalClick::BinaryValue.fixed(uint8, Bytes[0x2a_u8]),
      ),
      CrystalClick::BinaryValue.nullable(
        nullable_uint8,
        CrystalClick::BinaryValue.fixed(uint8, Bytes[0x07_u8]),
      ),
    ] of CrystalClick::BinaryValue)
    dynamic_value = CrystalClick::BinaryValue.dynamic(dynamic, dynamic_selected)

    nested = CrystalClick::BinaryDataType.nested(
      [string, uint8] of CrystalClick::BinaryDataType,
      ["n", "v"] of String,
    )
    tuple = CrystalClick::BinaryDataType.tuple(
      [string, uint8] of CrystalClick::BinaryDataType,
      ["n", "v"] of String,
    )
    nested_value = CrystalClick::BinaryValue.nested(nested, [
      CrystalClick::BinaryValue.tuple(tuple, [
        CrystalClick::BinaryValue.string("a"),
        CrystalClick::BinaryValue.fixed(uint8, Bytes[0x07_u8]),
      ] of CrystalClick::BinaryValue),
      CrystalClick::BinaryValue.tuple(tuple, [
        CrystalClick::BinaryValue.string(""),
        CrystalClick::BinaryValue.fixed(uint8, Bytes[0x00_u8]),
      ] of CrystalClick::BinaryValue),
    ] of CrystalClick::BinaryValue)

    saf = CrystalClick::BinaryDataType.simple_aggregate(
      CrystalClick::BinarySimpleAggregateType::Function::Sum,
      uint64,
    )
    saf_value = CrystalClick::BinaryValue.simple_aggregate(saf, CrystalClick::BinaryValue.uint64(42_u64))

    nullable_string = CrystalClick::BinaryDataType.nullable(string)
    low_nullable_string = CrystalClick::BinaryDataType.low_cardinality(nullable_string)
    array_low_nullable_string = CrystalClick::BinaryDataType.array(low_nullable_string)
    array_low_nullable_value = CrystalClick::BinaryValue.array(array_low_nullable_string, [
      CrystalClick::BinaryValue.low_cardinality(
        low_nullable_string,
        CrystalClick::BinaryValue.nullable(nullable_string, CrystalClick::BinaryValue.string("")),
      ),
      CrystalClick::BinaryValue.low_cardinality(
        low_nullable_string,
        CrystalClick::BinaryValue.nullable(nullable_string),
      ),
      CrystalClick::BinaryValue.low_cardinality(
        low_nullable_string,
        CrystalClick::BinaryValue.nullable(nullable_string, CrystalClick::BinaryValue.string("a")),
      ),
    ] of CrystalClick::BinaryValue)

    map_string = CrystalClick::BinaryDataType.map(string, uint8)
    map_string_value = CrystalClick::BinaryValue.map(map_string, [
      CrystalClick::BinaryValue.string("a"),
      CrystalClick::BinaryValue.fixed(uint8, Bytes[0x2a_u8]),
    ] of CrystalClick::BinaryValue)
    map_low_string = CrystalClick::BinaryDataType.map(low_string, uint8)
    map_low_string_value = CrystalClick::BinaryValue.map(map_low_string, [
      CrystalClick::BinaryValue.low_cardinality(low_string, CrystalClick::BinaryValue.string("a")),
      CrystalClick::BinaryValue.fixed(uint8, Bytes[0x2a_u8]),
    ] of CrystalClick::BinaryValue)

    interval = CrystalClick::BinaryDataType.interval(CrystalClick::BinaryIntervalType::Kind::Second)
    interval_value = CrystalClick::BinaryValue.interval(interval, 42_i64)
    bfloat16 = CrystalClick::BinaryDataType.primitive("BFloat16")
    bfloat16_value = CrystalClick::BinaryValue.fixed(bfloat16, Bytes[0x80_u8, 0x3f_u8])
    map_uint8 = CrystalClick::BinaryDataType.map(uint8, uint8)
    map_uint8_value = CrystalClick::BinaryValue.map(map_uint8, [
      CrystalClick::BinaryValue.fixed(uint8, Bytes[0x2a_u8]),
      CrystalClick::BinaryValue.fixed(uint8, Bytes[0x07_u8]),
    ] of CrystalClick::BinaryValue)

    [
      typed_profile("lc_string", low_string, "LowCardinality(String)", "2615", "0161", low_string_value),
      typed_profile("variant_uint8", variant, "Variant(String, UInt8)", "2a021501", "012a", variant_value),
      typed_profile("variant_null", variant, "Variant(String, UInt8)", "2a021501", "ff", variant_null),
      typed_profile("dynamic_array_nullable", dynamic, "Dynamic", "2b20", "1e23010301002a0007", dynamic_value),
      typed_profile("nested", nested, "Nested(n String, v UInt8)", "2f02016e15017601", "020161070000", nested_value),
      typed_profile("saf_sum", saf, "SimpleAggregateFunction(sum, UInt64)", "2e0373756d000104", "2a00000000000000", saf_value),
      typed_profile("array_lc_nullable", array_low_nullable_string,
        "Array(LowCardinality(Nullable(String)))", "1e262315", "03000001000161", array_low_nullable_value),
      typed_profile("map_string", map_string, "Map(String, UInt8)", "271501", "0101612a", map_string_value),
      typed_profile("map_lc_string", map_low_string,
        "Map(LowCardinality(String), UInt8)", "27261501", "0101612a", map_low_string_value),
      runtime_profile("runtime_lc_string", low_string, "LowCardinality(String)", "2615", "0161", low_string_value),
      runtime_profile("runtime_nested", nested, "Nested(n String, v UInt8)", "2f02016e15017601", "020161070000", nested_value),
      runtime_profile("runtime_saf_sum", saf, "SimpleAggregateFunction(sum, UInt64)", "2e0373756d000104", "2a00000000000000", saf_value),
      runtime_profile("runtime_interval", interval, "IntervalSecond", "2203", "2a00000000000000", interval_value),
      runtime_profile("runtime_bfloat16", bfloat16, "BFloat16", "31", "803f", bfloat16_value),
      runtime_profile("runtime_numeric_map", map_uint8, "Map(UInt8, UInt8)", "270101", "012a07", map_uint8_value),
    ] of Profile
  end

  def self.verify_value!(profile : Profile, value : CrystalClick::BinaryValue) : Nil
    require!(value.type == profile.type, "#{profile.id}: decoded JSON type differs")
    require!(value.type.name == profile.type_name, "#{profile.id}: decoded JSON name differs")
    row = value.json_row
    require!(row.type == profile.type && row.path_count == 1 && row.path_at(0) == "item",
      "#{profile.id}: decoded JSON path differs")
    actual = row.value_at(0)
    require!(actual.type == profile.child_type && actual.type.name == profile.child_type_name,
      "#{profile.id}: decoded child nominal type differs")

    case profile.id
    when "lc_string", "runtime_lc_string"
      require!(actual.child_at(0).as_string == "a", "#{profile.id}: LowCardinality value differs")
    when "variant_uint8"
      require!(actual.variant_index? == 1_u8, "Variant selected arm differs")
      child = actual.variant_child? || raise "Variant selected child is missing"
      require!(child.type.name == "UInt8" && child.bytes == Bytes[0x2a_u8], "Variant selected scalar differs")
    when "variant_null"
      require!(actual.is_null? && actual.variant_index?.nil? && actual.variant_child?.nil?,
        "Variant NULL discriminator differs")
    when "dynamic_array_nullable"
      require!(!actual.is_null?, "Dynamic unexpectedly decoded as NULL")
      array = actual.child_at(0)
      require!(array.type.name == "Array(Nullable(UInt8))" && array.element_count == 3,
        "Dynamic selected Array descriptor/count differs")
      require!(array.element_at(0).is_null?, "Dynamic selected NULL element differs")
      require!(array.element_at(1).child_at(0).bytes == Bytes[0x2a_u8] &&
               array.element_at(2).child_at(0).bytes == Bytes[0x07_u8],
        "Dynamic selected scalar elements differ")
    when "nested", "runtime_nested"
      require!(actual.element_count == 2 && actual.type.name == "Nested(n String, v UInt8)",
        "Nested row count or descriptor differs")
      first = actual.element_at(0)
      second = actual.element_at(1)
      require!(first.type.field_name_at(0) == "n" && first.type.field_name_at(1) == "v",
        "Nested field names differ")
      require!(first.element_at(0).as_string == "a" && first.element_at(1).bytes == Bytes[0x07_u8],
        "Nested first row differs")
      require!(second.element_at(0).as_string.empty? && second.element_at(1).bytes == Bytes[0x00_u8],
        "Nested second row differs")
    when "saf_sum", "runtime_saf_sum"
      require!(actual.child_at(0).as_uint64 == 42_u64, "SimpleAggregateFunction storage value differs")
    when "array_lc_nullable"
      require!(actual.element_count == 3, "Array(LowCardinality(Nullable(String))) count differs")
      first = actual.element_at(0).child_at(0)
      second = actual.element_at(1).child_at(0)
      third = actual.element_at(2).child_at(0)
      require!(!first.is_null? && first.child_at(0).as_string.empty?, "empty String element differs")
      require!(second.is_null?, "Nullable NULL element differs")
      require!(!third.is_null? && third.child_at(0).as_string == "a", "String element differs")
    when "map_string", "map_lc_string"
      require!(actual.element_count == 2, "String Map entry count differs")
      key = actual.element_at(0)
      key = key.child_at(0) if profile.id == "map_lc_string"
      require!(key.as_string == "a" && actual.element_at(1).bytes == Bytes[0x2a_u8],
        "String Map key/value differs")
    when "runtime_interval"
      require!(actual.bytes == Bytes[0x2a_u8, 0, 0, 0, 0, 0, 0, 0], "IntervalSecond payload differs")
    when "runtime_bfloat16"
      require!(actual.bytes == Bytes[0x80_u8, 0x3f_u8], "BFloat16 payload differs")
    when "runtime_numeric_map"
      require!(actual.element_count == 2 && actual.element_at(0).bytes == Bytes[0x2a_u8] &&
               actual.element_at(1).bytes == Bytes[0x07_u8], "numeric Map entry differs")
    else
      raise "unknown W181 positive profile #{profile.id}"
    end
  end

  def self.verify_profile_codecs!(profile : Profile, descriptor : Bytes, row_bytes : Bytes) : Nil
    require!(descriptor == profile.descriptor, "#{profile.id}: descriptor differs from independent literal")
    decoded_type = CrystalClick::BinaryDataTypeCodec.decode(descriptor)
    require!(decoded_type == profile.type, "#{profile.id}: decoded descriptor differs from constructed type")
    require!(decoded_type.name == profile.type_name, "#{profile.id}: decoded type name differs")
    require!(CrystalClick::BinaryDataTypeCodec.encode(decoded_type) == profile.descriptor,
      "#{profile.id}: decoded descriptor does not re-encode byte-exactly")
    require!(CrystalClick::BinaryDataTypeCodec.encode(profile.type) == profile.descriptor,
      "#{profile.id}: constructed descriptor differs from independent literal")
    require!(CrystalClick::BinaryValueCodec.encode_value(profile.value) == profile.row,
      "#{profile.id}: constructed row differs from independent literal")
    require!(row_bytes == profile.row, "#{profile.id}: supplied row differs from independent literal")

    decoded_value = CrystalClick::BinaryValueCodec.decode_value(decoded_type, row_bytes)
    verify_value!(profile, decoded_value)
    require!(CrystalClick::BinaryValueCodec.encode_value(decoded_value) == profile.row,
      "#{profile.id}: decoded row does not re-encode byte-exactly")
  end
end
