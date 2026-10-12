require "../../src/crystal_click"

module CompactPartWriterW267Fixture
  extend self

  KEY_NAME      = "pk"
  ROW_COUNT     =  8
  ROWS_PER_MARK =  2
  MARK_COUNT    =  4
  FRAME_BYTES   = 32
  KEYS          = [101_u64, 102_u64, 103_u64, 104_u64, 105_u64, 106_u64, 107_u64, 108_u64]
  COLUMN_NAMES  = ["payload", "ctx"]

  def types : Hash(String, CrystalClick::BinaryDataType)
    string_type = CrystalClick::BinaryDataType.primitive("String")
    uint8_type = CrystalClick::BinaryDataType.primitive("UInt8")
    uint64_type = CrystalClick::BinaryDataType.primitive("UInt64")
    low_string_type = CrystalClick::BinaryDataType.low_cardinality(string_type)

    payload_type = CrystalClick::BinaryDataType.variant([
      CrystalClick::BinaryDataType.array(low_string_type),
      string_type,
      CrystalClick::BinaryDataType.tuple(
        [low_string_type, uint64_type] of CrystalClick::BinaryDataType
      ),
    ] of CrystalClick::BinaryDataType)

    direct_type = CrystalClick::BinaryDataType.variant([
      CrystalClick::BinaryDataType.array(uint8_type),
      string_type,
      uint64_type,
    ] of CrystalClick::BinaryDataType)
    context_type = CrystalClick::BinaryDataType.tuple(
      [low_string_type, direct_type, CrystalClick::BinaryDataType.array(direct_type)] of CrystalClick::BinaryDataType,
      ["label", "direct", "lists"],
    )

    {
      "payload" => payload_type,
      "ctx"     => context_type,
    } of String => CrystalClick::BinaryDataType
  end

  def columns : Array(CrystalClick::CompactPartColumn)
    schema = types
    COLUMN_NAMES.map do |name|
      CrystalClick::CompactPartColumn.binary_bulk(name, schema[name], granules_for(name))
    end
  end

  def keys : Slice(UInt64)
    Slice(UInt64).new(KEYS.size) { |index| KEYS[index] }
  end

  def values_for(name : String) : Array(CrystalClick::BinaryValue)
    schema = types
    case name
    when "payload"
      payload_values(schema[name])
    when "ctx"
      context_values(schema[name])
    else
      raise ArgumentError.new("unknown W267 column: #{name}")
    end
  end

  def granules_for(name : String) : Array(Array(CrystalClick::BinaryValue))
    values_for(name).each_slice(ROWS_PER_MARK).map(&.to_a).to_a
  end

  def expected_signatures(name : String) : Array(String)
    type = types[name]?
    raise ArgumentError.new("unknown W267 column: #{name}") unless type
    values_for(name).map { |value| signature(type, value) }
  end

  def read_signatures(name : String, marks : Array(Array(CrystalClick::BinaryValue))) : Array(String)
    type = types[name]?
    raise ArgumentError.new("unknown W267 column: #{name}") unless type
    marks.flatten.map { |value| signature(type, value) }
  end

  private def payload_values(type : CrystalClick::BinaryDataType) : Array(CrystalClick::BinaryValue)
    string_type = CrystalClick::BinaryDataType.primitive("String")
    uint64_type = CrystalClick::BinaryDataType.primitive("UInt64")
    low_string_type = CrystalClick::BinaryDataType.low_cardinality(string_type)
    array_type = CrystalClick::BinaryDataType.array(low_string_type)
    tuple_type = CrystalClick::BinaryDataType.tuple(
      [low_string_type, uint64_type] of CrystalClick::BinaryDataType
    )

    [
      variant(type, array_type, array(array_type, [
        low_string(low_string_type, raw_string(Bytes[0x61_u8, 0x00_u8, 0x62_u8])),
        low_string(low_string_type, raw_string(Bytes[0xff_u8, 0x80_u8, 0x41_u8])),
      ] of CrystalClick::BinaryValue)),
      variant(type, array_type, array(array_type, [
        low_string(low_string_type, raw_string(Bytes[0xff_u8, 0x80_u8, 0x41_u8])),
        low_string(low_string_type, ""),
      ] of CrystalClick::BinaryValue)),
      variant(type, array_type, array(array_type, [
        low_string(low_string_type, raw_string(Bytes[0xff_u8, 0x80_u8, 0x41_u8])),
        low_string(low_string_type, ""),
      ] of CrystalClick::BinaryValue)),
      CrystalClick::BinaryValue.variant_null(type),
      variant(type, tuple_type, tuple(tuple_type, low_string(low_string_type, "north"), CrystalClick::BinaryValue.uint64(10_u64))),
      variant(type, string_type, CrystalClick::BinaryValue.string(raw_string(Bytes[0x00_u8, 0xff_u8, 0x41_u8]))),
      CrystalClick::BinaryValue.variant_null(type),
      CrystalClick::BinaryValue.variant_null(type),
    ] of CrystalClick::BinaryValue
  end

  private def context_values(type : CrystalClick::BinaryDataType) : Array(CrystalClick::BinaryValue)
    label_type = type.child_at(0)
    direct_type = type.child_at(1)
    lists_type = type.child_at(2)
    uint8_type = CrystalClick::BinaryDataType.primitive("UInt8")
    string_type = CrystalClick::BinaryDataType.primitive("String")
    uint64_type = CrystalClick::BinaryDataType.primitive("UInt64")
    bytes_type = CrystalClick::BinaryDataType.array(uint8_type)

    [
      context_row(type, raw_string(Bytes[0x61_u8, 0x00_u8, 0x62_u8]), variant(direct_type, string_type, CrystalClick::BinaryValue.string(raw_string(Bytes[0x63_u8, 0x00_u8, 0x64_u8]))), [
        variant(direct_type, string_type, CrystalClick::BinaryValue.string(raw_string(Bytes[0x6c_u8, 0x30_u8, 0x00_u8]))),
      ] of CrystalClick::BinaryValue, label_type, lists_type),
      context_row(type, raw_string(Bytes[0x61_u8, 0x00_u8, 0x62_u8]), variant(direct_type, uint64_type, CrystalClick::BinaryValue.uint64(7_u64)), [
        variant(direct_type, string_type, CrystalClick::BinaryValue.string("l1")),
      ] of CrystalClick::BinaryValue, label_type, lists_type),
      context_row(type, "l2", variant(direct_type, bytes_type, byte_array(bytes_type, [0_u8, 255_u8, 128_u8])), [] of CrystalClick::BinaryValue, label_type, lists_type),
      context_row(type, "l3", variant(direct_type, bytes_type, byte_array(bytes_type, [255_u8, 0_u8])), [] of CrystalClick::BinaryValue, label_type, lists_type),
      context_row(type, "", variant(direct_type, uint64_type, CrystalClick::BinaryValue.uint64(UInt64::MAX)), [
        variant(direct_type, uint64_type, CrystalClick::BinaryValue.uint64(33_u64)),
      ] of CrystalClick::BinaryValue, label_type, lists_type),
      context_row(type, raw_string(Bytes[0x61_u8, 0x00_u8, 0x62_u8]), variant(direct_type, string_type, CrystalClick::BinaryValue.string(raw_string(Bytes[0xff_u8, 0x80_u8, 0x41_u8]))), [
        variant(direct_type, bytes_type, byte_array(bytes_type, [0_u8, 255_u8])),
      ] of CrystalClick::BinaryValue, label_type, lists_type),
      context_row(type, "lz", CrystalClick::BinaryValue.variant_null(direct_type), [
        CrystalClick::BinaryValue.variant_null(direct_type),
      ] of CrystalClick::BinaryValue, label_type, lists_type),
      context_row(type, "lz", CrystalClick::BinaryValue.variant_null(direct_type), [
        CrystalClick::BinaryValue.variant_null(direct_type),
      ] of CrystalClick::BinaryValue, label_type, lists_type),
    ] of CrystalClick::BinaryValue
  end

  private def context_row(
    type : CrystalClick::BinaryDataType,
    label : String,
    direct : CrystalClick::BinaryValue,
    nested_values : Array(CrystalClick::BinaryValue),
    label_type : CrystalClick::BinaryDataType,
    lists_type : CrystalClick::BinaryDataType,
  ) : CrystalClick::BinaryValue
    label_value = low_string(label_type, label)
    nested_array = array(lists_type, nested_values)
    CrystalClick::BinaryValue.tuple(type, [label_value, direct, nested_array] of CrystalClick::BinaryValue)
  end

  private def low_string(type : CrystalClick::BinaryDataType, value : String) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.low_cardinality(type, CrystalClick::BinaryValue.string(value))
  end

  private def raw_string(bytes : Bytes) : String
    String.new(bytes)
  end

  private def array(
    type : CrystalClick::BinaryDataType,
    values : Array(CrystalClick::BinaryValue),
  ) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.array(type, values)
  end

  private def byte_array(
    type : CrystalClick::BinaryDataType,
    values : Array(UInt8),
  ) : CrystalClick::BinaryValue
    uint8_type = type.child_at(0)
    elements = values.map do |value|
      CrystalClick::BinaryValue.fixed(uint8_type, Bytes[value])
    end
    array(type, elements)
  end

  private def tuple(
    type : CrystalClick::BinaryDataType,
    first : CrystalClick::BinaryValue,
    second : CrystalClick::BinaryValue,
  ) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.tuple(type, [first, second] of CrystalClick::BinaryValue)
  end

  private def variant(
    type : CrystalClick::BinaryDataType,
    arm_type : CrystalClick::BinaryDataType,
    child : CrystalClick::BinaryValue,
  ) : CrystalClick::BinaryValue
    arm_index = 0
    while arm_index < type.child_count && type.child_at(arm_index) != arm_type
      arm_index += 1
    end
    if arm_index >= type.child_count
      raise ArgumentError.new("W267 selected Variant arm is outside the canonical roster")
    end
    CrystalClick::BinaryValue.variant(type, arm_index, child)
  end

  private def signature(
    type : CrystalClick::BinaryDataType,
    value : CrystalClick::BinaryValue,
  ) : String
    case type.tag
    when CrystalClick::BinaryDataType::TAG_LOW_CARDINALITY
      signature(type.child_at(0), value.child_at(0))
    when CrystalClick::BinaryDataType::TAG_ARRAY
      "[#{value.elements.map { |child| signature(type.child_at(0), child) }.join(",")}]"
    when CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE, CrystalClick::BinaryDataType::TAG_NAMED_TUPLE
      fields = Array(String).new(type.child_count)
      type.child_count.times do |index|
        fields << signature(type.child_at(index), value.child_at(index))
      end
      "(#{fields.join(",")})"
    when CrystalClick::BinaryDataType::TAG_VARIANT
      if value.is_null?
        "VNULL"
      else
        index = value.variant_index?.not_nil!.to_i
        "V#{index}:#{signature(type.child_at(index), value.variant_child?.not_nil!)}"
      end
    when CrystalClick::BinaryDataType::TAG_STRING
      "S:#{value.as_string.to_slice.hexstring}"
    when CrystalClick::BinaryDataType::TAG_UINT64
      "U:#{value.as_uint64}"
    when CrystalClick::BinaryDataType::TAG_UINT8
      "B:#{value.byte_at(0)}"
    else
      raise ArgumentError.new("W267 signature does not admit #{type.name}")
    end
  end
end
