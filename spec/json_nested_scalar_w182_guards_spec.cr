require "./spec_helper"

private def w182_nested_guard_limits(
  max_depth : Int = 64,
  max_nodes : Int = 4_096,
  max_elements : Int = 1_000_000,
  max_bytes : Int = 64 * 1024 * 1024,
) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(
    max_depth: max_depth,
    max_nodes: max_nodes,
    max_elements: max_elements,
    max_bytes: max_bytes,
  )
end

private def w182_guard_empty_json(type : CrystalClick::BinaryDataType) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.json(
    type,
    CrystalClick::BinaryJsonRow.new(type, [] of Tuple(String, CrystalClick::BinaryValue)),
  )
end

private def w182_guard_inner_json(
  uint8 : CrystalClick::BinaryDataType,
  byte : UInt8 = 0x2a_u8,
) : Tuple(CrystalClick::BinaryDataType, CrystalClick::BinaryValue)
  inner_type = CrystalClick::BinaryDataType.json(
    max_dynamic_paths: 0,
    max_dynamic_types: 0,
    typed_paths: {"n" => uint8} of String => CrystalClick::BinaryDataType,
  )
  inner_row = CrystalClick::BinaryJsonRow.new(
    inner_type,
    [{"n", CrystalClick::BinaryValue.fixed(uint8, Bytes[byte])}] of Tuple(String, CrystalClick::BinaryValue),
  )
  {inner_type, CrystalClick::BinaryValue.json(inner_type, inner_row)}
end

describe "W182 nested nominal JSON RowBinary guards" do
  it "uses each wrapper's child law while keeping JSON outside the narrower profiles" do
    json = CrystalClick::BinaryDataType.json(max_dynamic_paths: 0, max_dynamic_types: 0)
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")

    array = CrystalClick::BinaryDataType.array(json)
    tuple = CrystalClick::BinaryDataType.tuple([json, uint8] of CrystalClick::BinaryDataType)
    nullable = CrystalClick::BinaryDataType.nullable(json)
    nullable_tuple = CrystalClick::BinaryDataType.nullable(tuple)
    map = CrystalClick::BinaryDataType.map(json, json)
    variant = CrystalClick::BinaryDataType.variant([json, uint8] of CrystalClick::BinaryDataType)
    nested = CrystalClick::BinaryDataType.nested([json, uint8] of CrystalClick::BinaryDataType, ["j", "u"] of String)

    array.child_at(0).should eq(json)
    tuple.child_at(0).should eq(json)
    nullable.child_at(0).should eq(json)
    nullable_tuple.child_at(0).should eq(tuple)
    map.child_at(0).should eq(json)
    map.child_at(1).should eq(json)
    variant.children.should contain(json)
    nested.child_at(0).child_at(0).should eq(json)

    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.nullable(array) }
    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.low_cardinality(json) }
    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.aggregate_count(json) }
    expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentSchema.new({"nested" => array})
    end
    direct_json_structure = CrystalClick::DynamicStructure.new([json] of CrystalClick::BinaryDataType)
    direct_json_structure.type_at(0).should eq(json)
    # Recursive JSON metadata became representable in W212. The ordinary
    # value lane still requires an exact Object leaf binding.
    wrapped_structure = CrystalClick::DynamicStructure.new([array] of CrystalClick::BinaryDataType)
    wrapped_structure.type_at(0).should eq(array)
    expect_raises(CrystalClick::UnsupportedFormatError, "JSON") do
      CrystalClick::BinaryDynamicBulkPlan.new_with_budget(
        CrystalClick::BinaryDataType.dynamic(max_types: 1),
        {"root" => wrapped_structure},
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, true),
      )
    end
  end

  it "keeps JSON out of typed Object Dynamic actual rosters" do
    json = CrystalClick::BinaryDataType.json(max_dynamic_paths: 0, max_dynamic_types: 0)
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    )

    error = expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentPlan.new(
        structures,
        {"typed" => dynamic},
        {"typed" => CrystalClick::DynamicStructure.new([json] of CrystalClick::BinaryDataType)},
      )
    end
    error.message.to_s.should contain("JSON")
  end

  it "charges a nested typed JSON child once across construction and scalar codec visits" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    inner_type, inner_value = w182_guard_inner_json(uint8)
    outer_type = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 0,
      max_dynamic_types: 0,
      typed_paths: {"child" => inner_type} of String => CrystalClick::BinaryDataType,
    )
    entries = [{"child", inner_value}] of Tuple(String, CrystalClick::BinaryValue)
    exact_constructor_limits = w182_nested_guard_limits(max_depth: 3, max_nodes: 10, max_elements: 8, max_bytes: 8)
    row = CrystalClick::BinaryJsonRow.new(outer_type, entries, exact_constructor_limits)
    row.path_count.should eq(1)
    row.path_at(0).should eq("child")
    row.value_at(0).type.should eq(inner_type)

    constructor_one_short = [
      w182_nested_guard_limits(max_depth: 2, max_nodes: 10, max_elements: 8, max_bytes: 8),
      w182_nested_guard_limits(max_depth: 3, max_nodes: 9, max_elements: 8, max_bytes: 8),
      w182_nested_guard_limits(max_depth: 3, max_nodes: 10, max_elements: 7, max_bytes: 8),
      w182_nested_guard_limits(max_depth: 3, max_nodes: 10, max_elements: 8, max_bytes: 7),
    ] of CrystalClick::BinaryCodecLimits
    constructor_one_short.each do |limits|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryJsonRow.new(outer_type, entries, limits)
      end
    end

    outer_value = CrystalClick::BinaryValue.json(outer_type, row)
    row_wire = Bytes[0x01_u8, 0x05, 0x63, 0x68, 0x69, 0x6c, 0x64, 0x01, 0x01, 0x6e, 0x2a]
    exact_codec_limits = w182_nested_guard_limits(max_depth: 3, max_nodes: 10, max_elements: 8, max_bytes: row_wire.size)
    CrystalClick::BinaryValueCodec.encode_value(outer_value, exact_codec_limits).should eq(row_wire)
    decoded = CrystalClick::BinaryValueCodec.decode_value(outer_type, row_wire, exact_codec_limits)
    decoded.json_row.value_at(0).type.should eq(inner_type)
    decoded.json_row.value_at(0).json_row.value_at(0).bytes.should eq(Bytes[0x2a_u8])

    codec_one_short = [
      w182_nested_guard_limits(max_depth: 2, max_nodes: 10, max_elements: 8, max_bytes: row_wire.size),
      w182_nested_guard_limits(max_depth: 3, max_nodes: 9, max_elements: 8, max_bytes: row_wire.size),
      w182_nested_guard_limits(max_depth: 3, max_nodes: 10, max_elements: 7, max_bytes: row_wire.size),
      w182_nested_guard_limits(max_depth: 3, max_nodes: 10, max_elements: 8, max_bytes: row_wire.size - 1),
    ] of CrystalClick::BinaryCodecLimits
    codec_one_short.each do |limits|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryValueCodec.encode_value(outer_value, limits)
      end
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryValueCodec.decode_value(outer_type, row_wire, limits)
      end
    end

    descriptor_wire = Bytes[
      0x30_u8, 0x00, 0x00, 0x00, 0x01, 0x05, 0x63, 0x68, 0x69, 0x6c, 0x64,
      0x30, 0x00, 0x00, 0x00, 0x01, 0x01, 0x6e, 0x01, 0x00, 0x00, 0x00, 0x00,
    ]
    full_wire = descriptor_wire + row_wire
    descriptor_wire.size.should eq(23)
    full_wire.size.should eq(34)
    full_limits = w182_nested_guard_limits(max_depth: 3, max_nodes: 10, max_elements: 8, max_bytes: 34)
    CrystalClick::BinaryValueCodec.encode(outer_value, full_limits).should eq(full_wire)
    CrystalClick::BinaryValueCodec.decode(full_wire, full_limits).json_row.value_at(0).type.should eq(inner_type)
    full_one_short = [
      w182_nested_guard_limits(max_depth: 2, max_nodes: 10, max_elements: 8, max_bytes: 34),
      w182_nested_guard_limits(max_depth: 3, max_nodes: 9, max_elements: 8, max_bytes: 34),
      w182_nested_guard_limits(max_depth: 3, max_nodes: 10, max_elements: 7, max_bytes: 34),
      w182_nested_guard_limits(max_depth: 3, max_nodes: 10, max_elements: 8, max_bytes: 33),
    ] of CrystalClick::BinaryCodecLimits
    full_one_short.each do |limits|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryValueCodec.encode(outer_value, limits)
      end
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryValueCodec.decode(full_wire, limits)
      end
    end
  end

  it "does not deduplicate shared nested JSON siblings in constructor or codec budgets" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    inner_type, inner_value = w182_guard_inner_json(uint8)
    outer_type = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 0,
      max_dynamic_types: 0,
      typed_paths: {
        "a" => inner_type,
        "b" => inner_type,
      } of String => CrystalClick::BinaryDataType,
    )
    entries = [{"a", inner_value}, {"b", inner_value}] of Tuple(String, CrystalClick::BinaryValue)
    exact_limits = w182_nested_guard_limits(max_depth: 3, max_nodes: 18, max_elements: 16, max_bytes: 8)
    row = CrystalClick::BinaryJsonRow.new(outer_type, entries, exact_limits)
    row.path_count.should eq(2)
    row.path_at(0).should eq("a")
    row.path_at(1).should eq("b")

    constructor_one_short = [
      w182_nested_guard_limits(max_depth: 2, max_nodes: 18, max_elements: 16, max_bytes: 8),
      w182_nested_guard_limits(max_depth: 3, max_nodes: 17, max_elements: 16, max_bytes: 8),
      w182_nested_guard_limits(max_depth: 3, max_nodes: 18, max_elements: 15, max_bytes: 8),
      w182_nested_guard_limits(max_depth: 3, max_nodes: 18, max_elements: 16, max_bytes: 7),
    ] of CrystalClick::BinaryCodecLimits
    constructor_one_short.each do |limits|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryJsonRow.new(outer_type, entries, limits)
      end
    end

    value = CrystalClick::BinaryValue.json(outer_type, row)
    row_wire = Bytes[
      0x02_u8,
      0x01, 0x61, 0x01, 0x01, 0x6e, 0x2a,
      0x01, 0x62, 0x01, 0x01, 0x6e, 0x2a,
    ]
    codec_limits = w182_nested_guard_limits(max_depth: 3, max_nodes: 18, max_elements: 16, max_bytes: row_wire.size)
    CrystalClick::BinaryValueCodec.encode_value(value, codec_limits).should eq(row_wire)
    decoded = CrystalClick::BinaryValueCodec.decode_value(outer_type, row_wire, codec_limits)
    decoded.json_row.path_count.should eq(2)
    decoded.json_row.value_at(0).json_row.value_at(0).bytes.should eq(Bytes[0x2a_u8])
    decoded.json_row.value_at(1).json_row.value_at(0).bytes.should eq(Bytes[0x2a_u8])

    codec_one_short = [
      w182_nested_guard_limits(max_depth: 2, max_nodes: 18, max_elements: 16, max_bytes: row_wire.size),
      w182_nested_guard_limits(max_depth: 3, max_nodes: 17, max_elements: 16, max_bytes: row_wire.size),
      w182_nested_guard_limits(max_depth: 3, max_nodes: 18, max_elements: 15, max_bytes: row_wire.size),
      w182_nested_guard_limits(max_depth: 3, max_nodes: 18, max_elements: 16, max_bytes: row_wire.size - 1),
    ] of CrystalClick::BinaryCodecLimits
    codec_one_short.each do |limits|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryValueCodec.encode_value(value, limits)
      end
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryValueCodec.decode_value(outer_type, row_wire, limits)
      end
    end
  end

  it "keeps selected Dynamic JSON descriptor and value recursion in the enclosing shared budget" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    inner_type, inner_value = w182_guard_inner_json(uint8)
    dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    selected = CrystalClick::BinaryValue.dynamic(dynamic_type, inner_value)
    outer_type = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 0,
      max_dynamic_types: 0,
      typed_paths: {"child" => dynamic_type} of String => CrystalClick::BinaryDataType,
    )
    entries = [{"child", selected}] of Tuple(String, CrystalClick::BinaryValue)
    exact_constructor_limits = w182_nested_guard_limits(max_depth: 4, max_nodes: 12, max_elements: 10, max_bytes: 8)
    row = CrystalClick::BinaryJsonRow.new(outer_type, entries, exact_constructor_limits)
    row.value_at(0).child_at(0).type.should eq(inner_type)

    constructor_one_short = [
      w182_nested_guard_limits(max_depth: 3, max_nodes: 12, max_elements: 10, max_bytes: 8),
      w182_nested_guard_limits(max_depth: 4, max_nodes: 11, max_elements: 10, max_bytes: 8),
      w182_nested_guard_limits(max_depth: 4, max_nodes: 12, max_elements: 9, max_bytes: 8),
      w182_nested_guard_limits(max_depth: 4, max_nodes: 12, max_elements: 10, max_bytes: 7),
    ] of CrystalClick::BinaryCodecLimits
    constructor_one_short.each do |limits|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryJsonRow.new(outer_type, entries, limits)
      end
    end

    value = CrystalClick::BinaryValue.json(outer_type, row)
    row_wire = Bytes[
      0x01_u8, 0x05, 0x63, 0x68, 0x69, 0x6c, 0x64,
      0x30, 0x00, 0x00, 0x00, 0x01, 0x01, 0x6e, 0x01, 0x00, 0x00,
      0x01, 0x01, 0x6e, 0x2a,
    ]
    row_wire.size.should eq(21)
    exact_codec_limits = w182_nested_guard_limits(max_depth: 4, max_nodes: 12, max_elements: 10, max_bytes: 21)
    CrystalClick::BinaryValueCodec.encode_value(value, exact_codec_limits).should eq(row_wire)
    decoded = CrystalClick::BinaryValueCodec.decode_value(outer_type, row_wire, exact_codec_limits)
    decoded_dynamic = decoded.json_row.value_at(0)
    decoded_dynamic.type.should eq(dynamic_type)
    decoded_dynamic.child_at(0).type.should eq(inner_type)
    decoded_dynamic.child_at(0).json_row.path_at(0).should eq("n")
    decoded_dynamic.child_at(0).json_row.value_at(0).bytes.should eq(Bytes[0x2a_u8])

    codec_one_short = [
      w182_nested_guard_limits(max_depth: 3, max_nodes: 12, max_elements: 10, max_bytes: row_wire.size),
      w182_nested_guard_limits(max_depth: 4, max_nodes: 11, max_elements: 10, max_bytes: row_wire.size),
      w182_nested_guard_limits(max_depth: 4, max_nodes: 12, max_elements: 9, max_bytes: row_wire.size),
      w182_nested_guard_limits(max_depth: 4, max_nodes: 12, max_elements: 10, max_bytes: row_wire.size - 1),
    ] of CrystalClick::BinaryCodecLimits
    codec_one_short.each do |limits|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryValueCodec.encode_value(value, limits)
      end
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryValueCodec.decode_value(outer_type, row_wire, limits)
      end
    end
  end

  it "rejects malformed nested path boundaries and exact nominal mismatches" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    inner_type, inner_value = w182_guard_inner_json(uint8)
    outer_type = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 0,
      max_dynamic_types: 0,
      typed_paths: {"child" => inner_type} of String => CrystalClick::BinaryDataType,
    )

    expect_raises(ArgumentError) do
      CrystalClick::BinaryJsonRow.new(outer_type, [] of Tuple(String, CrystalClick::BinaryValue))
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryJsonRow.new(
        outer_type,
        [{"child", CrystalClick::BinaryValue.fixed(uint8, Bytes[0x2a_u8])}] of Tuple(String, CrystalClick::BinaryValue),
      )
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryJsonRow.new(inner_type, [] of Tuple(String, CrystalClick::BinaryValue))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.decode_value(inner_type, Bytes[0x00_u8])
    end

    value = CrystalClick::BinaryValue.json(
      outer_type,
      CrystalClick::BinaryJsonRow.new(
        outer_type,
        [{"child", inner_value}] of Tuple(String, CrystalClick::BinaryValue),
      ),
    )
    row_wire = CrystalClick::BinaryValueCodec.encode_value(value)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode_value(outer_type, row_wire[0, row_wire.size - 1])
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode_value(outer_type, row_wire + Bytes[0xff_u8])
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.decode_value(outer_type, Bytes[0_u8])
    end

    duplicate_nested = Bytes[
      0x02_u8,
      0x05, 0x63, 0x68, 0x69, 0x6c, 0x64, 0x01, 0x01, 0x6e, 0x2a,
      0x05, 0x63, 0x68, 0x69, 0x6c, 0x64, 0x01, 0x01, 0x6e, 0x2b,
    ]
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode_value(outer_type, duplicate_nested)
    end
    duplicate_construction = expect_raises(ArgumentError) do
      CrystalClick::BinaryJsonRow.new(outer_type, [
        {"child", inner_value},
        {"child", inner_value},
      ] of Tuple(String, CrystalClick::BinaryValue))
    end
    duplicate_construction.message.to_s.should contain("duplicate")
  end

  it "keeps JSON-containing products out of physical, borrowed, and DynamicBulk envelopes" do
    json = CrystalClick::BinaryDataType.json(max_dynamic_paths: 0, max_dynamic_types: 0)
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    array_type = CrystalClick::BinaryDataType.array(json)
    tuple_type = CrystalClick::BinaryDataType.tuple([json, uint8] of CrystalClick::BinaryDataType)
    nullable_type = CrystalClick::BinaryDataType.nullable(json)
    map_type = CrystalClick::BinaryDataType.map(json, json)
    map_json_uint8_type = CrystalClick::BinaryDataType.map(json, uint8)
    variant_type = CrystalClick::BinaryDataType.variant([json, uint8] of CrystalClick::BinaryDataType)
    nested_type = CrystalClick::BinaryDataType.nested([json, uint8] of CrystalClick::BinaryDataType, ["j", "u"] of String)
    nullable_tuple_type = CrystalClick::BinaryDataType.nullable(tuple_type)
    values = [
      array_type,
      tuple_type,
      nullable_type,
      nullable_tuple_type,
      map_json_uint8_type,
      map_type,
      variant_type,
      nested_type,
    ] of CrystalClick::BinaryDataType

    values.each do |type|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryBulkTypePlan.new(type, CrystalClick::BinaryBulkProfile.single_stream)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryBulkCodec.encode(type, [] of Array(CrystalClick::BinaryValue))
      end

      empty_value = case type.tag
                    when CrystalClick::BinaryDataType::TAG_ARRAY
                      CrystalClick::BinaryValue.array(type, [] of CrystalClick::BinaryValue)
                    when CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE, CrystalClick::BinaryDataType::TAG_NAMED_TUPLE
                      CrystalClick::BinaryValue.tuple(type, [w182_guard_empty_json(json), CrystalClick::BinaryValue.fixed(uint8, Bytes[0x07_u8])] of CrystalClick::BinaryValue)
                    when CrystalClick::BinaryDataType::TAG_NULLABLE
                      CrystalClick::BinaryValue.null(type)
                    when CrystalClick::BinaryDataType::TAG_MAP
                      CrystalClick::BinaryValue.map(type, [] of CrystalClick::BinaryValue)
                    when CrystalClick::BinaryDataType::TAG_VARIANT
                      CrystalClick::BinaryValue.variant_null(type)
                    else
                      tuple = type.child_at(0)
                      row_tuple = CrystalClick::BinaryValue.tuple(tuple, [w182_guard_empty_json(json), CrystalClick::BinaryValue.fixed(uint8, Bytes[0x07_u8])] of CrystalClick::BinaryValue)
                      CrystalClick::BinaryValue.nested(type, [row_tuple] of CrystalClick::BinaryValue)
                    end
      wire = CrystalClick::BinaryValueCodec.encode(empty_value)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryValueCodec.encode_borrowed(
          empty_value,
          CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
        )
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryValueCodec.decode_borrowed(
          wire,
          CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
        )
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryValueCodec.encode_dynamic_bulk_child(
          empty_value,
          CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, true),
          1,
        )
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryValueCodec.decode_dynamic_bulk_child(
          CrystalClick::BinaryDataTypeCodec.encode(type),
          CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS),
          1,
        )
      end
    end

    # Keep the DynamicBulk zero-row/window probes behind a valid Dynamic site.
    # The control stream is independently produced by the same real plan for a
    # legal Tuple(UInt8, Dynamic) declaration; the guarded tuple changes only
    # the first field to JSON, which must be rejected before the empty data
    # window can make it appear irrelevant.
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    guarded_type = CrystalClick::BinaryDataType.tuple([json, dynamic] of CrystalClick::BinaryDataType)
    control_type = CrystalClick::BinaryDataType.tuple([uint8, dynamic] of CrystalClick::BinaryDataType)
    structures = {
      "root.field.1" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType),
    }
    empty_granules = [] of Array(CrystalClick::BinaryValue)
    control_streams = CrystalClick::BinaryDynamicBulkCodec.encode(control_type, structures, empty_granules)

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDynamicBulkCodec.encode(guarded_type, structures, empty_granules)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDynamicBulkCodec.decode(
        guarded_type,
        control_streams,
        [0_u64],
        first_mark: 0,
        mark_count: 0,
      )
    end
  end
end
