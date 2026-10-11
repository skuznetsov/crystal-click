require "./compact_typed_w260_fixture"

module CompactDynamicW262Fixture
  extend self

  def dynamic_type(max_types : Int32 = 2) : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.dynamic(max_types: max_types)
  end

  def root_type : CrystalClick::BinaryDataType
    dynamic_type(1)
  end

  def variant_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.variant([
      CrystalClick::BinaryDataType.primitive("String"),
      CrystalClick::BinaryDataType.primitive("UInt64"),
    ] of CrystalClick::BinaryDataType)
  end

  def nested_type : CrystalClick::BinaryDataType
    tuple = CrystalClick::BinaryDataType.tuple(
      [variant_type, root_type] of CrystalClick::BinaryDataType,
      ["choice", "payload"],
    )
    CrystalClick::BinaryDataType.array(tuple)
  end

  def map_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.map(
      CrystalClick::BinaryDataType.primitive("String"),
      root_type,
    )
  end

  def root_values : Array(CrystalClick::BinaryValue)
    type = root_type
    [
      CrystalClick::BinaryValue.dynamic(type, uint8(7_u8)),
      CrystalClick::BinaryValue.dynamic(type, CrystalClick::BinaryValue.string("root-shared-1")),
      CrystalClick::BinaryValue.dynamic(type, CrystalClick::BinaryValue.float64_bits(0x400c_0000_0000_0000_u64)),
      CrystalClick::BinaryValue.dynamic(type),
      CrystalClick::BinaryValue.dynamic(type, CrystalClick::BinaryValue.string("root-shared-2")),
      CrystalClick::BinaryValue.dynamic(type, CrystalClick::BinaryValue.float64_bits(0xc002_0000_0000_0000_u64)),
      CrystalClick::BinaryValue.dynamic(type, CrystalClick::BinaryValue.uint64(99_u64)),
      CrystalClick::BinaryValue.dynamic(type, CrystalClick::BinaryValue.string("root-tail")),
    ] of CrystalClick::BinaryValue
  end

  def nested_values : Array(CrystalClick::BinaryValue)
    array = nested_type
    variant = variant_type
    tuple = array.child_at(0)
    [
      CrystalClick::BinaryValue.array(array, [] of CrystalClick::BinaryValue),
      CrystalClick::BinaryValue.array(array, [] of CrystalClick::BinaryValue),
      CrystalClick::BinaryValue.array(array, [
        nested_item(tuple, variant, 0, CrystalClick::BinaryValue.string("n3"), uint8(31_u8)),
      ] of CrystalClick::BinaryValue),
      CrystalClick::BinaryValue.array(array, [
        nested_item(tuple, variant, 1, CrystalClick::BinaryValue.uint64(44_u64), CrystalClick::BinaryValue.string("nested-shared")),
        nested_item(tuple, variant, 0, CrystalClick::BinaryValue.string("n4b"), CrystalClick::BinaryValue.float64_bits(0x4012_0000_0000_0000_u64)),
      ] of CrystalClick::BinaryValue),
      CrystalClick::BinaryValue.array(array, [] of CrystalClick::BinaryValue),
      CrystalClick::BinaryValue.array(array, [] of CrystalClick::BinaryValue),
      CrystalClick::BinaryValue.array(array, [
        nested_item(tuple, variant, 0, CrystalClick::BinaryValue.string("n7"), uint8(77_u8)),
      ] of CrystalClick::BinaryValue),
      CrystalClick::BinaryValue.array(array, [
        nested_item(tuple, variant, 1, CrystalClick::BinaryValue.uint64(88_u64), CrystalClick::BinaryValue.string("nested-tail")),
        nested_item(tuple, variant, 0, CrystalClick::BinaryValue.string("n8b"), CrystalClick::BinaryValue.float64_bits(0xc021_0000_0000_0000_u64)),
      ] of CrystalClick::BinaryValue),
    ] of CrystalClick::BinaryValue
  end

  def map_values : Array(CrystalClick::BinaryValue)
    type = map_type
    dynamic = root_type
    [
      CrystalClick::BinaryValue.map(type, [] of CrystalClick::BinaryValue),
      CrystalClick::BinaryValue.map(type, [] of CrystalClick::BinaryValue),
      map_row(type, dynamic, [{"a", CrystalClick::BinaryValue.string("map-three")}]),
      map_row(type, dynamic, [
        {"b", uint8(14_u8)},
        {"c", CrystalClick::BinaryValue.float64_bits(0x3ff4_0000_0000_0000_u64)},
      ]),
      CrystalClick::BinaryValue.map(type, [] of CrystalClick::BinaryValue),
      CrystalClick::BinaryValue.map(type, [] of CrystalClick::BinaryValue),
      map_row(type, dynamic, [{"a", uint8(17_u8)}]),
      map_row(type, dynamic, [
        {"z", CrystalClick::BinaryValue.string("map-tail")},
        {"q", CrystalClick::BinaryValue.float64_bits(0xbff8_0000_0000_0000_u64)},
      ]),
    ] of CrystalClick::BinaryValue
  end

  def choice_values : Array(CrystalClick::BinaryValue)
    type = variant_type
    [
      CrystalClick::BinaryValue.variant(type, 0, CrystalClick::BinaryValue.string("v0")),
      CrystalClick::BinaryValue.variant(type, 1, CrystalClick::BinaryValue.uint64(102_u64)),
      CrystalClick::BinaryValue.variant(type, 0, CrystalClick::BinaryValue.string("v2")),
      CrystalClick::BinaryValue.variant(type, 1, CrystalClick::BinaryValue.uint64(104_u64)),
      CrystalClick::BinaryValue.variant(type, 0, CrystalClick::BinaryValue.string("v4")),
      CrystalClick::BinaryValue.variant(type, 1, CrystalClick::BinaryValue.uint64(106_u64)),
      CrystalClick::BinaryValue.variant(type, 0, CrystalClick::BinaryValue.string("v6")),
      CrystalClick::BinaryValue.variant(type, 1, CrystalClick::BinaryValue.uint64(108_u64)),
    ] of CrystalClick::BinaryValue
  end

  def value_signature(value : CrystalClick::BinaryValue) : String
    type = value.type
    return "#{type.name}=NULL" if value.is_null?

    case type.tag
    when CrystalClick::BinaryDataType::TAG_DYNAMIC
      "#{type.name}<#{value_signature(value.child_at(0))}>"
    when CrystalClick::BinaryDataType::TAG_ARRAY
      "#{type.name}[#{value.elements.map { |child| value_signature(child) }.join(";")}]"
    when CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE, CrystalClick::BinaryDataType::TAG_NAMED_TUPLE
      "#{type.name}(#{value.elements.map { |child| value_signature(child) }.join(",")})"
    when CrystalClick::BinaryDataType::TAG_MAP
      elements = value.elements
      pairs = Array(String).new(elements.size // 2) do |index|
        "#{value_signature(elements[index * 2])}=#{value_signature(elements[index * 2 + 1])}"
      end
      "#{type.name}{#{pairs.join(",")}}"
    when CrystalClick::BinaryDataType::TAG_VARIANT
      index = value.variant_index? || raise CrystalClick::CorruptPartError.new("W262 literal Variant lacks an arm index")
      child = value.variant_child? || raise CrystalClick::CorruptPartError.new("W262 literal Variant lacks its arm value")
      "#{type.name}##{index}(#{value_signature(child)})"
    when CrystalClick::BinaryDataType::TAG_STRING
      "String:#{JSON::Any.new(value.as_string).to_json}"
    when CrystalClick::BinaryDataType::TAG_UINT8
      "UInt8:#{value.byte_at(0)}"
    when CrystalClick::BinaryDataType::TAG_UINT64
      "UInt64:#{value.as_uint64}"
    when CrystalClick::BinaryDataType::TAG_FLOAT64
      "Float64:0x#{value.as_float64_bits.to_s(16).rjust(16, '0')}"
    else
      raise CrystalClick::UnsupportedFormatError.new("W262 literal signature lacks #{type.name}")
    end
  end

  def ordinary_types : Array(CrystalClick::BinaryDataType)
    [
      CrystalClick::BinaryDataType.primitive("UInt8"),
      CrystalClick::BinaryDataType.primitive("String"),
    ] of CrystalClick::BinaryDataType
  end

  def statistics(counts : Array(UInt64)) : CrystalClick::StructureStatistics
    CrystalClick::StructureStatistics.new(counts, [] of CrystalClick::StructureStatistic)
  end

  def u64_bytes(value : UInt64) : Bytes
    Bytes.new(sizeof(UInt64)) do |index|
      ((value >> (index * 8)) & 0xff_u64).to_u8
    end
  end

  def structure(
    types : Array(CrystalClick::BinaryDataType) = ordinary_types,
    statistics : CrystalClick::StructureStatistics? = nil,
    version : UInt64 = CrystalClick::DynamicStructure::VERSION_V3,
    legacy_max_dynamic_types : UInt64? = nil,
  ) : CrystalClick::DynamicStructure
    CrystalClick::DynamicStructure.new(
      types,
      statistics,
      version: version,
      legacy_max_dynamic_types: legacy_max_dynamic_types,
    )
  end

  def prepared_context(
    structures : Hash(String, CrystalClick::DynamicStructure),
    type : CrystalClick::BinaryDataType = dynamic_type,
    limits : CrystalClick::BinaryCodecLimits = CrystalClick::BinaryCodecLimits.default,
  ) : CrystalClick::CompactDynamicBulkPreparedContext
    budget = CrystalClick::BinaryCodecBudget.new(limits)
    CrystalClick::CompactDynamicBulkPreparedContext.new(
      type,
      "root",
      CrystalClick::BinaryBulkProfile.single_stream,
      structures,
      budget,
    )
  end

  def open_profile(
    part_path : String,
    selected_column : String,
    selected_type_name : String,
    type_versions : String = "{}",
    propagate_nested_versions : Bool = true,
    include_uint64_column : Bool = false,
  ) : CrystalClick::CompactSerializationProfile
    selected_type = CrystalClick::DynamicBulkColumnDeclaration.parse(selected_type_name) ||
                    CrystalClick::StaticBinaryBulkColumnDeclaration.parse(selected_type_name) ||
                    raise ArgumentError.new("W262 profile fixture type is not an admitted declaration")
    columns = [{selected_column, selected_type.name}] of Tuple(String, String)
    if include_uint64_column
      raise ArgumentError.new("W262 profile fixture has a duplicate UInt64 column") if selected_column == "pk"
      columns << {"pk", "UInt64"}
    end
    records = columns.map do |name, _|
      %({"kind":"Default","name":"#{name}","num_defaults":0,"num_rows":2})
    end
    CompactTypedW260Fixture.write_profile_metadata(
      part_path,
      CompactTypedW260Fixture.profile_envelope(records, type_versions, propagate_nested_versions),
    )
    CrystalClick::CompactSerializationProfile.open(
      part_path,
      columns,
      selected_column,
      selected_type,
      2_u64,
      CrystalClick::CompressedStreamBudget.read_default,
    )
  end

  private def uint8(value : UInt8) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.fixed(
      CrystalClick::BinaryDataType.primitive("UInt8"),
      Bytes[value],
    )
  end

  private def nested_item(
    tuple_type : CrystalClick::BinaryDataType,
    variant_type : CrystalClick::BinaryDataType,
    variant_index : Int32,
    choice : CrystalClick::BinaryValue,
    payload : CrystalClick::BinaryValue,
  ) : CrystalClick::BinaryValue
    dynamic_payload = CrystalClick::BinaryValue.dynamic(root_type, payload)
    CrystalClick::BinaryValue.tuple(
      tuple_type,
      [
        CrystalClick::BinaryValue.variant(variant_type, variant_index, choice),
        dynamic_payload,
      ] of CrystalClick::BinaryValue,
    )
  end

  private def map_row(
    type : CrystalClick::BinaryDataType,
    dynamic_type : CrystalClick::BinaryDataType,
    entries : Array(Tuple(String, CrystalClick::BinaryValue)),
  ) : CrystalClick::BinaryValue
    flat = [] of CrystalClick::BinaryValue
    entries.each do |key, value|
      flat << CrystalClick::BinaryValue.string(key)
      flat << CrystalClick::BinaryValue.dynamic(dynamic_type, value)
    end
    CrystalClick::BinaryValue.map(type, flat)
  end
end
