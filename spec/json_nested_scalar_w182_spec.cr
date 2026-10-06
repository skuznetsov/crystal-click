require "./spec_helper"

private def w182_json_zero_caps : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.json(max_dynamic_paths: 0, max_dynamic_types: 0)
end

private def w182_empty_json_value(type : CrystalClick::BinaryDataType) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.json(
    type,
    CrystalClick::BinaryJsonRow.new(type, [] of Tuple(String, CrystalClick::BinaryValue)),
  )
end

private def w182_runtime_json_value(
  type : CrystalClick::BinaryDataType,
  path : String,
  value : CrystalClick::BinaryValue,
) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.json(
    type,
    CrystalClick::BinaryJsonRow.new(type, [{path, value}] of Tuple(String, CrystalClick::BinaryValue)),
  )
end

describe "W182 nested nominal JSON RowBinary values" do
  it "retains JSON as the nominal element of Array(JSON) with independent empty and populated rows" do
    json_type = w182_json_zero_caps
    array_type = CrystalClick::BinaryDataType.array(json_type)
    uint8_type = CrystalClick::BinaryDataType.primitive("UInt8")
    populated_json = w182_runtime_json_value(
      json_type,
      "n",
      CrystalClick::BinaryValue.fixed(uint8_type, Bytes[0x2a_u8]),
    )
    value = CrystalClick::BinaryValue.array(array_type, [
      w182_empty_json_value(json_type),
      populated_json,
    ] of CrystalClick::BinaryValue)

    descriptor_wire = Bytes[0x1e_u8, 0x30, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
    row_wire = Bytes[0x02_u8, 0x00, 0x01, 0x01, 0x6e, 0x01, 0x2a]
    full_wire = Bytes[
      0x1e_u8, 0x30, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x02, 0x00, 0x01, 0x01, 0x6e, 0x01, 0x2a,
    ]

    CrystalClick::BinaryDataTypeCodec.encode(array_type).should eq(descriptor_wire)
    CrystalClick::BinaryDataTypeCodec.decode(descriptor_wire).should eq(array_type)
    array_type.name.should eq("Array(JSON(max_dynamic_types=0, max_dynamic_paths=0))")
    array_type.child_at(0).should eq(json_type)
    array_type.child_at(0).name.should eq("JSON(max_dynamic_types=0, max_dynamic_paths=0)")
    CrystalClick::BinaryValueCodec.encode_value(value).should eq(row_wire)
    CrystalClick::BinaryValueCodec.encode(value).should eq(full_wire)

    decoded = CrystalClick::BinaryValueCodec.decode(full_wire)
    decoded.type.should eq(array_type)
    decoded.element_count.should eq(2)
    decoded.element_at(0).type.should eq(json_type)
    decoded.element_at(0).json_row.empty?.should be_true
    decoded_json = decoded.element_at(1)
    decoded_json.type.name.should eq("JSON(max_dynamic_types=0, max_dynamic_paths=0)")
    decoded_json.json_row.path_at(0).should eq("n")
    decoded_json.json_row.value_at(0).type.name.should eq("UInt8")
    decoded_json.json_row.value_at(0).bytes.should eq(Bytes[0x2a_u8])
    CrystalClick::BinaryValueCodec.encode_value(decoded).should eq(row_wire)
  end

  it "keeps JSON and UInt8 as distinct nominal Tuple fields" do
    json_type = w182_json_zero_caps
    uint8_type = CrystalClick::BinaryDataType.primitive("UInt8")
    tuple_type = CrystalClick::BinaryDataType.tuple([json_type, uint8_type] of CrystalClick::BinaryDataType)
    value = CrystalClick::BinaryValue.tuple(tuple_type, [
      w182_empty_json_value(json_type),
      CrystalClick::BinaryValue.fixed(uint8_type, Bytes[0x07_u8]),
    ] of CrystalClick::BinaryValue)

    descriptor_wire = Bytes[
      0x1f_u8, 0x02, 0x30, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
    ]
    row_wire = Bytes[0x00_u8, 0x07]
    full_wire = Bytes[
      0x1f_u8, 0x02, 0x30, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
      0x00, 0x07,
    ]

    CrystalClick::BinaryDataTypeCodec.encode(tuple_type).should eq(descriptor_wire)
    CrystalClick::BinaryDataTypeCodec.decode(descriptor_wire).should eq(tuple_type)
    tuple_type.name.should eq("Tuple(JSON(max_dynamic_types=0, max_dynamic_paths=0), UInt8)")
    tuple_type.child_at(0).should eq(json_type)
    tuple_type.child_at(1).name.should eq("UInt8")
    CrystalClick::BinaryValueCodec.encode_value(value).should eq(row_wire)
    CrystalClick::BinaryValueCodec.encode(value).should eq(full_wire)

    decoded = CrystalClick::BinaryValueCodec.decode(full_wire)
    decoded.type.should eq(tuple_type)
    decoded.element_at(0).type.should eq(json_type)
    decoded.element_at(0).json_row.empty?.should be_true
    decoded.element_at(1).type.name.should eq("UInt8")
    decoded.element_at(1).bytes.should eq(Bytes[0x07_u8])
    CrystalClick::BinaryValueCodec.encode_value(decoded).should eq(row_wire)
  end

  it "retains JSON typed-path metadata inside a named Nested sibling row" do
    uint8_type = CrystalClick::BinaryDataType.primitive("UInt8")
    json_type = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 1,
      max_dynamic_types: 1,
      typed_paths: {"n" => uint8_type} of String => CrystalClick::BinaryDataType,
    )
    nested_type = CrystalClick::BinaryDataType.nested(
      [json_type, uint8_type] of CrystalClick::BinaryDataType,
      ["j", "u"] of String,
    )
    tuple_type = nested_type.child_at(0)
    json_value = CrystalClick::BinaryValue.json(
      json_type,
      CrystalClick::BinaryJsonRow.new(
        json_type,
        [{"n", CrystalClick::BinaryValue.fixed(uint8_type, Bytes[0x2a_u8])}] of Tuple(String, CrystalClick::BinaryValue),
      ),
    )
    tuple_value = CrystalClick::BinaryValue.tuple(tuple_type, [
      json_value,
      CrystalClick::BinaryValue.fixed(uint8_type, Bytes[0x07_u8]),
    ] of CrystalClick::BinaryValue)
    value = CrystalClick::BinaryValue.nested(nested_type, [tuple_value] of CrystalClick::BinaryValue)

    descriptor_wire = Bytes[
      0x2f_u8, 0x02, 0x01, 0x6a,
      0x30, 0x00, 0x01, 0x01, 0x01, 0x01, 0x6e, 0x01, 0x00, 0x00,
      0x01, 0x75, 0x01,
    ]
    row_wire = Bytes[0x01_u8, 0x01, 0x01, 0x6e, 0x2a, 0x07]
    full_wire = Bytes[
      0x2f_u8, 0x02, 0x01, 0x6a,
      0x30, 0x00, 0x01, 0x01, 0x01, 0x01, 0x6e, 0x01, 0x00, 0x00,
      0x01, 0x75, 0x01,
      0x01, 0x01, 0x01, 0x6e, 0x2a, 0x07,
    ]

    CrystalClick::BinaryDataTypeCodec.encode(nested_type).should eq(descriptor_wire)
    CrystalClick::BinaryDataTypeCodec.decode(descriptor_wire).should eq(nested_type)
    nested_type.name.should eq("Nested(j JSON(max_dynamic_types=1, max_dynamic_paths=1, n UInt8), u UInt8)")
    nested_type.child_count.should eq(1)
    nested_type.child_at(0).field_name_at(0).should eq("j")
    nested_type.child_at(0).child_at(0).should eq(json_type)
    nested_type.child_at(0).field_name_at(1).should eq("u")
    CrystalClick::BinaryValueCodec.encode_value(value).should eq(row_wire)
    CrystalClick::BinaryValueCodec.encode(value).should eq(full_wire)

    decoded = CrystalClick::BinaryValueCodec.decode(full_wire)
    decoded.type.should eq(nested_type)
    decoded.element_count.should eq(1)
    decoded_tuple = decoded.element_at(0)
    decoded_tuple.type.field_name_at(0).should eq("j")
    decoded_tuple.type.field_name_at(1).should eq("u")
    decoded_json = decoded_tuple.element_at(0)
    decoded_json.type.should eq(json_type)
    decoded_json.json_row.path_at(0).should eq("n")
    decoded_json.json_row.value_at(0).bytes.should eq(Bytes[0x2a_u8])
    decoded_tuple.element_at(1).bytes.should eq(Bytes[0x07_u8])
    CrystalClick::BinaryValueCodec.encode_value(decoded).should eq(row_wire)
  end

  it "preserves Map(String, JSON) pair framing and JSON runtime-path data" do
    json_type = w182_json_zero_caps
    string_type = CrystalClick::BinaryDataType.primitive("String")
    uint8_type = CrystalClick::BinaryDataType.primitive("UInt8")
    map_type = CrystalClick::BinaryDataType.map(string_type, json_type)
    value = CrystalClick::BinaryValue.map(map_type, [
      CrystalClick::BinaryValue.string("k"),
      w182_runtime_json_value(
        json_type,
        "n",
        CrystalClick::BinaryValue.fixed(uint8_type, Bytes[0xff_u8]),
      ),
    ] of CrystalClick::BinaryValue)

    descriptor_wire = Bytes[0x27_u8, 0x15, 0x30, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
    row_wire = Bytes[0x01_u8, 0x01, 0x6b, 0x01, 0x01, 0x6e, 0x01, 0xff]
    full_wire = Bytes[
      0x27_u8, 0x15, 0x30, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x01, 0x01, 0x6b, 0x01, 0x01, 0x6e, 0x01, 0xff,
    ]

    CrystalClick::BinaryDataTypeCodec.encode(map_type).should eq(descriptor_wire)
    CrystalClick::BinaryDataTypeCodec.decode(descriptor_wire).should eq(map_type)
    map_type.name.should eq("Map(String, JSON(max_dynamic_types=0, max_dynamic_paths=0))")
    map_type.child_at(0).name.should eq("String")
    map_type.child_at(1).should eq(json_type)
    CrystalClick::BinaryValueCodec.encode_value(value).should eq(row_wire)
    CrystalClick::BinaryValueCodec.encode(value).should eq(full_wire)

    decoded = CrystalClick::BinaryValueCodec.decode(full_wire)
    decoded.type.should eq(map_type)
    decoded.element_count.should eq(2)
    decoded.element_at(0).as_string.should eq("k")
    decoded_json = decoded.element_at(1)
    decoded_json.type.should eq(json_type)
    decoded_json.json_row.path_at(0).should eq("n")
    decoded_json.json_row.value_at(0).bytes.should eq(Bytes[0xff_u8])
    CrystalClick::BinaryValueCodec.encode_value(decoded).should eq(row_wire)
  end

  it "reuses the JSON scalar codec in the mixed Array(Tuple(JSON, UInt8)) product" do
    json_type = w182_json_zero_caps
    uint8_type = CrystalClick::BinaryDataType.primitive("UInt8")
    tuple_type = CrystalClick::BinaryDataType.tuple([json_type, uint8_type] of CrystalClick::BinaryDataType)
    array_type = CrystalClick::BinaryDataType.array(tuple_type)
    value = CrystalClick::BinaryValue.array(array_type, [
      CrystalClick::BinaryValue.tuple(tuple_type, [
        w182_empty_json_value(json_type),
        CrystalClick::BinaryValue.fixed(uint8_type, Bytes[0x09_u8]),
      ] of CrystalClick::BinaryValue),
    ] of CrystalClick::BinaryValue)

    descriptor_wire = Bytes[
      0x1e_u8, 0x1f, 0x02, 0x30, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
    ]
    row_wire = Bytes[0x01_u8, 0x00, 0x09]
    full_wire = Bytes[
      0x1e_u8, 0x1f, 0x02, 0x30, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
      0x01, 0x00, 0x09,
    ]

    CrystalClick::BinaryDataTypeCodec.encode(array_type).should eq(descriptor_wire)
    CrystalClick::BinaryDataTypeCodec.decode(descriptor_wire).should eq(array_type)
    array_type.name.should eq("Array(Tuple(JSON(max_dynamic_types=0, max_dynamic_paths=0), UInt8))")
    array_type.child_at(0).should eq(tuple_type)
    array_type.child_at(0).child_at(0).should eq(json_type)
    CrystalClick::BinaryValueCodec.encode_value(value).should eq(row_wire)
    CrystalClick::BinaryValueCodec.encode(value).should eq(full_wire)

    decoded = CrystalClick::BinaryValueCodec.decode(full_wire)
    decoded_tuple = decoded.element_at(0)
    decoded_tuple.type.should eq(tuple_type)
    decoded_tuple.element_at(0).type.should eq(json_type)
    decoded_tuple.element_at(0).json_row.empty?.should be_true
    decoded_tuple.element_at(1).bytes.should eq(Bytes[0x09_u8])
    CrystalClick::BinaryValueCodec.encode_value(decoded).should eq(row_wire)
  end

  it "retains a JSON child descriptor and typed-path values in JSON typed-path metadata" do
    uint8_type = CrystalClick::BinaryDataType.primitive("UInt8")
    child_json_type = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 0,
      max_dynamic_types: 0,
      typed_paths: {"n" => uint8_type} of String => CrystalClick::BinaryDataType,
    )
    outer_json_type = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 0,
      max_dynamic_types: 0,
      typed_paths: {"child" => child_json_type} of String => CrystalClick::BinaryDataType,
    )
    child_value = CrystalClick::BinaryValue.json(
      child_json_type,
      CrystalClick::BinaryJsonRow.new(
        child_json_type,
        [{"n", CrystalClick::BinaryValue.fixed(uint8_type, Bytes[0x2a_u8])}] of Tuple(String, CrystalClick::BinaryValue),
      ),
    )
    value = CrystalClick::BinaryValue.json(
      outer_json_type,
      CrystalClick::BinaryJsonRow.new(
        outer_json_type,
        [{"child", child_value}] of Tuple(String, CrystalClick::BinaryValue),
      ),
    )

    descriptor_wire = Bytes[
      0x30_u8, 0x00, 0x00, 0x00, 0x01, 0x05, 0x63, 0x68, 0x69, 0x6c, 0x64,
      0x30, 0x00, 0x00, 0x00, 0x01, 0x01, 0x6e, 0x01, 0x00, 0x00,
      0x00, 0x00,
    ]
    row_wire = Bytes[0x01_u8, 0x05, 0x63, 0x68, 0x69, 0x6c, 0x64, 0x01, 0x01, 0x6e, 0x2a]
    full_wire = Bytes[
      0x30_u8, 0x00, 0x00, 0x00, 0x01, 0x05, 0x63, 0x68, 0x69, 0x6c, 0x64,
      0x30, 0x00, 0x00, 0x00, 0x01, 0x01, 0x6e, 0x01, 0x00, 0x00,
      0x00, 0x00,
      0x01, 0x05, 0x63, 0x68, 0x69, 0x6c, 0x64, 0x01, 0x01, 0x6e, 0x2a,
    ]

    CrystalClick::BinaryDataTypeCodec.encode(outer_json_type).should eq(descriptor_wire)
    decoded_type = CrystalClick::BinaryDataTypeCodec.decode(descriptor_wire)
    decoded_type.should eq(outer_json_type)
    decoded_type.name.should eq("JSON(max_dynamic_types=0, max_dynamic_paths=0, child JSON(max_dynamic_types=0, max_dynamic_paths=0, n UInt8))")
    outer_json_type.child_count.should eq(0)
    outer_metadata = decoded_type.json_type.not_nil!
    outer_metadata.typed_path_at(0).should eq("child")
    decoded_child_type = outer_metadata.typed_type_for("child").not_nil!
    decoded_child_type.tag.should eq(CrystalClick::BinaryDataType::TAG_JSON)
    decoded_child_type.name.should eq("JSON(max_dynamic_types=0, max_dynamic_paths=0, n UInt8)")
    decoded_child_metadata = decoded_child_type.json_type.not_nil!
    decoded_child_metadata.typed_path_at(0).should eq("n")
    decoded_child_metadata.typed_type_for("n").not_nil!.name.should eq("UInt8")
    CrystalClick::BinaryValueCodec.encode_value(value).should eq(row_wire)
    CrystalClick::BinaryValueCodec.encode(value).should eq(full_wire)

    decoded = CrystalClick::BinaryValueCodec.decode(full_wire)
    decoded.json_row.path_at(0).should eq("child")
    decoded_nested_json = decoded.json_row.value_at(0)
    decoded_nested_json.type.should eq(child_json_type)
    decoded_nested_json.json_row.path_at(0).should eq("n")
    decoded_nested_json.json_row.value_at(0).bytes.should eq(Bytes[0x2a_u8])
    CrystalClick::BinaryValueCodec.encode_value(decoded).should eq(row_wire)
  end

  it "wraps JSON in Nullable while preserving both a present empty object and NULL" do
    json_type = w182_json_zero_caps
    nullable_json_type = CrystalClick::BinaryDataType.nullable(json_type)
    present = CrystalClick::BinaryValue.nullable(nullable_json_type, w182_empty_json_value(json_type))
    null = CrystalClick::BinaryValue.null(nullable_json_type)

    descriptor_wire = Bytes[0x23_u8, 0x30, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
    present_row_wire = Bytes[0x00_u8, 0x00]
    null_row_wire = Bytes[0x01_u8]
    present_full_wire = Bytes[
      0x23_u8, 0x30, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x00, 0x00,
    ]
    null_full_wire = Bytes[
      0x23_u8, 0x30, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x01,
    ]

    CrystalClick::BinaryDataTypeCodec.encode(nullable_json_type).should eq(descriptor_wire)
    CrystalClick::BinaryDataTypeCodec.decode(descriptor_wire).should eq(nullable_json_type)
    nullable_json_type.name.should eq("Nullable(JSON(max_dynamic_types=0, max_dynamic_paths=0))")
    nullable_json_type.child_at(0).should eq(json_type)
    CrystalClick::BinaryValueCodec.encode_value(present).should eq(present_row_wire)
    CrystalClick::BinaryValueCodec.encode_value(null).should eq(null_row_wire)
    CrystalClick::BinaryValueCodec.encode(present).should eq(present_full_wire)
    CrystalClick::BinaryValueCodec.encode(null).should eq(null_full_wire)

    decoded_present = CrystalClick::BinaryValueCodec.decode(present_full_wire)
    decoded_present.is_null?.should be_false
    decoded_present.child_at(0).type.should eq(json_type)
    decoded_present.child_at(0).json_row.empty?.should be_true
    decoded_null = CrystalClick::BinaryValueCodec.decode(null_full_wire)
    decoded_null.type.should eq(nullable_json_type)
    decoded_null.is_null?.should be_true
    CrystalClick::BinaryValueCodec.encode_value(decoded_present).should eq(present_row_wire)
    CrystalClick::BinaryValueCodec.encode_value(decoded_null).should eq(null_row_wire)
  end

  it "keeps a selected JSON actual descriptor and typed data under Dynamic" do
    uint8_type = CrystalClick::BinaryDataType.primitive("UInt8")
    json_type = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 0,
      max_dynamic_types: 0,
      typed_paths: {"n" => uint8_type} of String => CrystalClick::BinaryDataType,
    )
    dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    json_value = CrystalClick::BinaryValue.json(
      json_type,
      CrystalClick::BinaryJsonRow.new(
        json_type,
        [{"n", CrystalClick::BinaryValue.fixed(uint8_type, Bytes[0xff_u8])}] of Tuple(String, CrystalClick::BinaryValue),
      ),
    )
    dynamic_value = CrystalClick::BinaryValue.dynamic(dynamic_type, json_value)

    dynamic_descriptor_wire = Bytes[0x2b_u8, 0x00]
    row_wire = Bytes[
      0x30_u8, 0x00, 0x00, 0x00, 0x01, 0x01, 0x6e, 0x01, 0x00, 0x00,
      0x01, 0x01, 0x6e, 0xff,
    ]
    full_wire = Bytes[
      0x2b_u8, 0x00,
      0x30, 0x00, 0x00, 0x00, 0x01, 0x01, 0x6e, 0x01, 0x00, 0x00,
      0x01, 0x01, 0x6e, 0xff,
    ]

    CrystalClick::BinaryDataTypeCodec.encode(dynamic_type).should eq(dynamic_descriptor_wire)
    CrystalClick::BinaryDataTypeCodec.decode(dynamic_descriptor_wire).should eq(dynamic_type)
    dynamic_type.name.should eq("Dynamic(max_types=0)")
    CrystalClick::BinaryValueCodec.encode_value(dynamic_value).should eq(row_wire)
    CrystalClick::BinaryValueCodec.encode(dynamic_value).should eq(full_wire)

    decoded = CrystalClick::BinaryValueCodec.decode(full_wire)
    decoded.type.should eq(dynamic_type)
    decoded.is_null?.should be_false
    decoded_json = decoded.child_at(0)
    decoded_json.type.should eq(json_type)
    decoded_json.type.name.should eq("JSON(max_dynamic_types=0, max_dynamic_paths=0, n UInt8)")
    decoded_json.json_row.path_at(0).should eq("n")
    decoded_json.json_row.value_at(0).bytes.should eq(Bytes[0xff_u8])
    CrystalClick::BinaryValueCodec.encode_value(decoded).should eq(row_wire)
  end
end
