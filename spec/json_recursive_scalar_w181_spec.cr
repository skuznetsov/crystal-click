require "./spec_helper"

describe "W181 recursive scalar JSON RowBinary admission" do
  it "preserves a typed LowCardinality(String) descriptor and literal scalar row" do
    string_type = CrystalClick::BinaryDataType.primitive("String")
    low_cardinality_type = CrystalClick::BinaryDataType.low_cardinality(string_type)
    json_type = CrystalClick::BinaryDataType.json(
      typed_paths: {"lc" => low_cardinality_type} of String => CrystalClick::BinaryDataType,
    )
    value = CrystalClick::BinaryValue.json(
      json_type,
      CrystalClick::BinaryJsonRow.new(
        json_type,
        [{"lc", CrystalClick::BinaryValue.low_cardinality(
          low_cardinality_type,
          CrystalClick::BinaryValue.string("oak"),
        )}] of Tuple(String, CrystalClick::BinaryValue),
      ),
    )

    descriptor_wire = Bytes[
      0x30_u8, 0x00, 0x80, 0x08, 0x20, 0x01,
      0x02, 0x6c, 0x63, 0x26, 0x15, 0x00, 0x00,
    ]
    row_wire = Bytes[0x01_u8, 0x02, 0x6c, 0x63, 0x03, 0x6f, 0x61, 0x6b]

    CrystalClick::BinaryDataTypeCodec.encode(json_type).should eq(descriptor_wire)
    CrystalClick::BinaryDataTypeCodec.decode(descriptor_wire).should eq(json_type)
    CrystalClick::BinaryValueCodec.encode_value(value).should eq(row_wire)

    decoded = CrystalClick::BinaryValueCodec.decode_value(json_type, row_wire)
    decoded.json_row.path_at(0).should eq("lc")
    decoded.json_row.value_at(0).type.should eq(low_cardinality_type)
    decoded.json_row.value_at(0).type.name.should eq("LowCardinality(String)")
    decoded.json_row.value_at(0).child_at(0).as_string.should eq("oak")
    CrystalClick::BinaryValueCodec.encode_value(decoded).should eq(row_wire)
  end

  it "preserves the selected nominal Variant arm and literal scalar row" do
    string_type = CrystalClick::BinaryDataType.primitive("String")
    uint8_type = CrystalClick::BinaryDataType.primitive("UInt8")
    variant_type = CrystalClick::BinaryDataType.variant(
      [uint8_type, string_type] of CrystalClick::BinaryDataType,
    )
    variant_type.child_at(0).name.should eq("String")
    variant_type.child_at(1).name.should eq("UInt8")
    json_type = CrystalClick::BinaryDataType.json(
      typed_paths: {"variant" => variant_type} of String => CrystalClick::BinaryDataType,
    )
    value = CrystalClick::BinaryValue.json(
      json_type,
      CrystalClick::BinaryJsonRow.new(
        json_type,
        [{"variant", CrystalClick::BinaryValue.variant(
          variant_type,
          0,
          CrystalClick::BinaryValue.string("v"),
        )}] of Tuple(String, CrystalClick::BinaryValue),
      ),
    )

    descriptor_wire = Bytes[
      0x30_u8, 0x00, 0x80, 0x08, 0x20, 0x01,
      0x07, 0x76, 0x61, 0x72, 0x69, 0x61, 0x6e, 0x74,
      0x2a, 0x02, 0x15, 0x01, 0x00, 0x00,
    ]
    row_wire = Bytes[0x01_u8, 0x07, 0x76, 0x61, 0x72, 0x69, 0x61, 0x6e, 0x74, 0x00, 0x01, 0x76]

    CrystalClick::BinaryDataTypeCodec.encode(json_type).should eq(descriptor_wire)
    CrystalClick::BinaryDataTypeCodec.decode(descriptor_wire).should eq(json_type)
    CrystalClick::BinaryValueCodec.encode_value(value).should eq(row_wire)

    decoded = CrystalClick::BinaryValueCodec.decode_value(json_type, row_wire)
    decoded_variant = decoded.json_row.value_at(0)
    decoded_variant.type.should eq(variant_type)
    decoded_variant.variant_index?.should eq(0_u8)
    decoded_variant.variant_child?.not_nil!.type.name.should eq("String")
    decoded_variant.variant_child?.not_nil!.as_string.should eq("v")
    CrystalClick::BinaryValueCodec.encode_value(decoded).should eq(row_wire)
  end

  it "rebases a Dynamic selected Array(Nullable(UInt8)) through the JSON row" do
    uint8_type = CrystalClick::BinaryDataType.primitive("UInt8")
    nullable_type = CrystalClick::BinaryDataType.nullable(uint8_type)
    array_type = CrystalClick::BinaryDataType.array(nullable_type)
    dynamic_type = CrystalClick::BinaryDataType.dynamic
    json_type = CrystalClick::BinaryDataType.json(
      typed_paths: {"dynamic" => dynamic_type} of String => CrystalClick::BinaryDataType,
    )
    selected = CrystalClick::BinaryValue.array(array_type, [
      CrystalClick::BinaryValue.nullable(nullable_type),
      CrystalClick::BinaryValue.nullable(
        nullable_type,
        CrystalClick::BinaryValue.fixed(uint8_type, Bytes[0x07_u8]),
      ),
    ] of CrystalClick::BinaryValue)
    value = CrystalClick::BinaryValue.json(
      json_type,
      CrystalClick::BinaryJsonRow.new(
        json_type,
        [{"dynamic", CrystalClick::BinaryValue.dynamic(dynamic_type, selected)}] of Tuple(String, CrystalClick::BinaryValue),
      ),
    )

    descriptor_wire = Bytes[
      0x30_u8, 0x00, 0x80, 0x08, 0x20, 0x01,
      0x07, 0x64, 0x79, 0x6e, 0x61, 0x6d, 0x69, 0x63,
      0x2b, 0x20, 0x00, 0x00,
    ]
    row_wire = Bytes[
      0x01_u8, 0x07, 0x64, 0x79, 0x6e, 0x61, 0x6d, 0x69, 0x63,
      0x1e, 0x23, 0x01, 0x02, 0x01, 0x00, 0x07,
    ]

    CrystalClick::BinaryDataTypeCodec.encode(json_type).should eq(descriptor_wire)
    CrystalClick::BinaryDataTypeCodec.decode(descriptor_wire).should eq(json_type)
    CrystalClick::BinaryValueCodec.encode_value(value).should eq(row_wire)

    decoded = CrystalClick::BinaryValueCodec.decode_value(json_type, row_wire)
    decoded_dynamic = decoded.json_row.value_at(0)
    decoded_dynamic.type.should eq(dynamic_type)
    decoded_dynamic.is_null?.should be_false
    decoded_array = decoded_dynamic.child_at(0)
    decoded_array.type.should eq(array_type)
    decoded_array.element_count.should eq(2)
    decoded_array.element_at(0).is_null?.should be_true
    decoded_array.element_at(1).is_null?.should be_false
    decoded_array.element_at(1).child_at(0).bytes.should eq(Bytes[0x07_u8])
    CrystalClick::BinaryValueCodec.encode_value(decoded).should eq(row_wire)
  end

  it "retains Nested field names and row accessors in its typed JSON descriptor" do
    string_type = CrystalClick::BinaryDataType.primitive("String")
    uint8_type = CrystalClick::BinaryDataType.primitive("UInt8")
    nested_type = CrystalClick::BinaryDataType.nested(
      [string_type, uint8_type] of CrystalClick::BinaryDataType,
      ["name", "value"] of String,
    )
    tuple_type = CrystalClick::BinaryDataType.tuple(
      [string_type, uint8_type] of CrystalClick::BinaryDataType,
      ["name", "value"] of String,
    )
    nested_value = CrystalClick::BinaryValue.nested(nested_type, [
      CrystalClick::BinaryValue.tuple(tuple_type, [
        CrystalClick::BinaryValue.string("n"),
        CrystalClick::BinaryValue.fixed(uint8_type, Bytes[0x09_u8]),
      ] of CrystalClick::BinaryValue),
    ] of CrystalClick::BinaryValue)
    json_type = CrystalClick::BinaryDataType.json(
      typed_paths: {"nested" => nested_type} of String => CrystalClick::BinaryDataType,
    )
    value = CrystalClick::BinaryValue.json(
      json_type,
      CrystalClick::BinaryJsonRow.new(
        json_type,
        [{"nested", nested_value}] of Tuple(String, CrystalClick::BinaryValue),
      ),
    )

    descriptor_wire = Bytes[
      0x30_u8, 0x00, 0x80, 0x08, 0x20, 0x01,
      0x06, 0x6e, 0x65, 0x73, 0x74, 0x65, 0x64,
      0x2f, 0x02, 0x04, 0x6e, 0x61, 0x6d, 0x65, 0x15,
      0x05, 0x76, 0x61, 0x6c, 0x75, 0x65, 0x01, 0x00, 0x00,
    ]
    row_wire = Bytes[0x01_u8, 0x06, 0x6e, 0x65, 0x73, 0x74, 0x65, 0x64, 0x01, 0x01, 0x6e, 0x09]

    CrystalClick::BinaryDataTypeCodec.encode(json_type).should eq(descriptor_wire)
    CrystalClick::BinaryDataTypeCodec.decode(descriptor_wire).should eq(json_type)
    CrystalClick::BinaryValueCodec.encode_value(value).should eq(row_wire)

    decoded = CrystalClick::BinaryValueCodec.decode_value(json_type, row_wire)
    decoded_nested = decoded.json_row.value_at(0)
    decoded_nested.type.should eq(nested_type)
    decoded_nested.type.name.should eq("Nested(name String, value UInt8)")
    decoded_nested.element_count.should eq(1)
    decoded_tuple = decoded_nested.element_at(0)
    decoded_tuple.type.field_name_at(0).should eq("name")
    decoded_tuple.type.field_name_at(1).should eq("value")
    decoded_tuple.element_at(0).as_string.should eq("n")
    decoded_tuple.element_at(1).bytes.should eq(Bytes[0x09_u8])
    CrystalClick::BinaryValueCodec.encode_value(decoded).should eq(row_wire)
  end

  it "keeps SimpleAggregateFunction(sum, UInt64) nominal over its scalar storage" do
    uint64_type = CrystalClick::BinaryDataType.primitive("UInt64")
    aggregate_type = CrystalClick::BinaryDataType.simple_aggregate(
      CrystalClick::BinarySimpleAggregateType::Function::Sum,
      uint64_type,
    )
    json_type = CrystalClick::BinaryDataType.json(
      typed_paths: {"saf" => aggregate_type} of String => CrystalClick::BinaryDataType,
    )
    value = CrystalClick::BinaryValue.json(
      json_type,
      CrystalClick::BinaryJsonRow.new(
        json_type,
        [{"saf", CrystalClick::BinaryValue.simple_aggregate(
          aggregate_type,
          CrystalClick::BinaryValue.uint64(42_u64),
        )}] of Tuple(String, CrystalClick::BinaryValue),
      ),
    )

    descriptor_wire = Bytes[
      0x30_u8, 0x00, 0x80, 0x08, 0x20, 0x01,
      0x03, 0x73, 0x61, 0x66, 0x2e, 0x03, 0x73, 0x75, 0x6d,
      0x00, 0x01, 0x04, 0x00, 0x00,
    ]
    row_wire = Bytes[
      0x01_u8, 0x03, 0x73, 0x61, 0x66,
      0x2a, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ]

    CrystalClick::BinaryDataTypeCodec.encode(json_type).should eq(descriptor_wire)
    CrystalClick::BinaryDataTypeCodec.decode(descriptor_wire).should eq(json_type)
    CrystalClick::BinaryValueCodec.encode_value(value).should eq(row_wire)

    decoded = CrystalClick::BinaryValueCodec.decode_value(json_type, row_wire)
    decoded_aggregate = decoded.json_row.value_at(0)
    decoded_aggregate.type.should eq(aggregate_type)
    decoded_aggregate.type.name.should eq("SimpleAggregateFunction(sum, UInt64)")
    decoded_aggregate.child_at(0).as_uint64.should eq(42_u64)
    CrystalClick::BinaryValueCodec.encode_value(decoded).should eq(row_wire)
  end
end
