require "./spec_helper"

private def w237_minmax_prepend(flag : UInt8, bytes : Bytes) : Bytes
  result = Bytes.new(bytes.size + 1)
  result[0] = flag
  bytes.size.times { |index| result[index + 1] = bytes[index] }
  result
end

private def w237_minmax_u8(type : CrystalClick::BinaryDataType, value : UInt8) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.fixed(type, Bytes[value])
end

private def w237_minmax_generic_state(value : CrystalClick::BinaryValue) : Bytes
  w237_minmax_prepend(1_u8, CrystalClick::BinaryValueCodec.encode_value(value))
end

private def w237_minmax_limits(
  depth : Int = 64,
  nodes : Int = 4_096,
  elements : Int = 1_000_000,
  bytes : Int = 64 * 1024 * 1024,
) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(
    max_depth: depth,
    max_nodes: nodes,
    max_elements: elements,
    max_bytes: bytes,
  )
end

describe "W237 AggregateFunction min/max core" do
  it "admits the canonical min/max identity and preserves its argument descriptor" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    min_wire = Bytes[0x25_u8, 0_u8, 3_u8, 0x6d_u8, 0x69_u8, 0x6e_u8, 0_u8, 1_u8, 1_u8]
    max_wire = Bytes[0x25_u8, 0_u8, 3_u8, 0x6d_u8, 0x61_u8, 0x78_u8, 0_u8, 1_u8, 1_u8]

    [{"min", min_wire}, {"max", max_wire}].each do |function, wire|
      type = CrystalClick::BinaryDataType.aggregate_function(function, uint8)
      descriptor = type.aggregate_function_type.not_nil!

      descriptor.function_name.should eq(function)
      descriptor.version.should eq(0_u8)
      descriptor.argument_type.should eq(uint8)
      type.name.should eq("AggregateFunction(#{function}, UInt8)")
      type.child_count.should eq(0)
      type.fixed_width.should be_nil
      type.contains_aggregate_count?.should be_false
      type.contains_aggregate_function?.should be_true
      CrystalClick::BinaryDataTypeCodec.encode(type).should eq(wire)
      CrystalClick::BinaryDataTypeCodec.decode(wire).should eq(type)
      CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(type.name).should eq(type)
    end
  end

  it "writes absent and present numeric states without interpreting the carrier" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    ["min", "max"].each do |function|
      type = CrystalClick::BinaryDataType.aggregate_function(function, uint8)
      absent = Bytes[0_u8]
      present = Bytes[1_u8, 0xff_u8]

      [absent, present].each do |state_bytes|
        state_value = CrystalClick::BinaryValue.aggregate_function_state(type, state_bytes)
        CrystalClick::BinaryValueCodec.encode_value(state_value).should eq(state_bytes)

        decoded = CrystalClick::BinaryValueCodec.decode_value(type, state_bytes)
        decoded.type.should eq(type)
        decoded.aggregate_function_state_bytes.should eq(state_bytes)
      end

      CrystalClick::BinaryAggregateFunctionStatePlan.for_type(type).default_state_bytes.should eq(absent)
      CrystalClick::BinaryBulkDefaultValue.build(type).aggregate_function_state_bytes.should eq(absent)
    end
  end

  it "routes static Array, Tuple, Map, and Nested bodies through recursive value grammar" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    string = CrystalClick::BinaryDataType.primitive("String")

    array_type = CrystalClick::BinaryDataType.array(uint8)
    array_value = CrystalClick::BinaryValue.array(
      array_type,
      [w237_minmax_u8(uint8, 7_u8), w237_minmax_u8(uint8, 9_u8)] of CrystalClick::BinaryValue
    )

    tuple_type = CrystalClick::BinaryDataType.tuple(
      [string, uint8] of CrystalClick::BinaryDataType,
      ["label", "value"] of String
    )
    tuple_value = CrystalClick::BinaryValue.tuple(
      tuple_type,
      [CrystalClick::BinaryValue.string("x"), w237_minmax_u8(uint8, 5_u8)] of CrystalClick::BinaryValue
    )

    map_type = CrystalClick::BinaryDataType.map(string, uint8)
    map_value = CrystalClick::BinaryValue.map(
      map_type,
      [CrystalClick::BinaryValue.string("k"), w237_minmax_u8(uint8, 3_u8)] of CrystalClick::BinaryValue
    )

    nested_type = CrystalClick::BinaryDataType.nested(
      [uint8] of CrystalClick::BinaryDataType,
      ["value"] of String
    )
    nested_row = CrystalClick::BinaryValue.tuple(
      nested_type.child_at(0),
      [w237_minmax_u8(uint8, 11_u8)] of CrystalClick::BinaryValue
    )
    nested_value = CrystalClick::BinaryValue.nested(
      nested_type,
      [nested_row] of CrystalClick::BinaryValue
    )

    cases = [
      {array_type, array_value},
      {tuple_type, tuple_value},
      {map_type, map_value},
      {nested_type, nested_value},
    ] of Tuple(CrystalClick::BinaryDataType, CrystalClick::BinaryValue)

    cases.each do |argument, body|
      type = CrystalClick::BinaryDataType.aggregate_function("min", argument)
      state_bytes = w237_minmax_generic_state(body)
      owned = CrystalClick::BinaryValue.aggregate_function_state(type, state_bytes)

      state_bytes[0] = 0_u8
      owned.aggregate_function_state_bytes[0].should eq(1_u8)
      copied_state = owned.aggregate_function_state_bytes
      copied_state[0] = 0_u8
      owned.aggregate_function_state_bytes[0].should eq(1_u8)

      wire = CrystalClick::BinaryValueCodec.encode(owned)
      decoded = CrystalClick::BinaryValueCodec.decode(wire)
      decoded.type.should eq(type)
      decoded.aggregate_function_state_bytes[0].should eq(1_u8)
    end
  end

  it "reuses normalized recursive serde for LowCardinality below Tuple, Array, and Nested" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    uint16 = CrystalClick::BinaryDataType.primitive("UInt16")
    string = CrystalClick::BinaryDataType.primitive("String")
    nullable_string = CrystalClick::BinaryDataType.nullable(string)
    low_cardinality_uint8 = CrystalClick::BinaryDataType.low_cardinality(uint8)

    nominal_tuple = CrystalClick::BinaryDataType.tuple(
      [low_cardinality_uint8, nullable_string] of CrystalClick::BinaryDataType,
      ["code", "label"] of String,
    )
    dispatched_tuple = CrystalClick::BinaryDataType.tuple(
      [uint8, nullable_string] of CrystalClick::BinaryDataType,
      ["code", "label"] of String,
    )
    nominal_array = CrystalClick::BinaryDataType.array(nominal_tuple)
    dispatched_array = CrystalClick::BinaryDataType.array(dispatched_tuple)
    array_body = CrystalClick::BinaryValue.array(
      dispatched_array,
      [
        CrystalClick::BinaryValue.tuple(
          dispatched_tuple,
          [w237_minmax_u8(uint8, 4_u8), CrystalClick::BinaryValue.nullable(nullable_string, CrystalClick::BinaryValue.string("a"))] of CrystalClick::BinaryValue,
        ),
        CrystalClick::BinaryValue.tuple(
          dispatched_tuple,
          [w237_minmax_u8(uint8, 9_u8), CrystalClick::BinaryValue.nullable(nullable_string)] of CrystalClick::BinaryValue,
        ),
      ] of CrystalClick::BinaryValue,
    )

    nested_nominal = CrystalClick::BinaryDataType.nested(
      [low_cardinality_uint8, uint16] of CrystalClick::BinaryDataType,
      ["code", "version"] of String,
    )
    nested_dispatched = CrystalClick::BinaryDataType.nested(
      [uint8, uint16] of CrystalClick::BinaryDataType,
      ["code", "version"] of String,
    )
    nested_body = CrystalClick::BinaryValue.nested(
      nested_dispatched,
      [
        CrystalClick::BinaryValue.tuple(
          nested_dispatched.child_at(0),
          [w237_minmax_u8(uint8, 7_u8), CrystalClick::BinaryValue.fixed(uint16, Bytes[1_u8, 0_u8])] of CrystalClick::BinaryValue,
        ),
      ] of CrystalClick::BinaryValue,
    )

    [
      {nominal_array, array_body, dispatched_array},
      {nested_nominal, nested_body, nested_dispatched},
    ].each do |nominal, body, dispatched|
      type = CrystalClick::BinaryDataType.aggregate_function("min", nominal)
      plan = CrystalClick::BinaryAggregateFunctionStatePlan.for_type(type)
      plan.argument_type.should eq(nominal)
      plan.input_type.should eq(dispatched)

      state_bytes = w237_minmax_generic_state(body)
      state = CrystalClick::BinaryValue.aggregate_function_state(type, state_bytes)
      wire = CrystalClick::BinaryValueCodec.encode(state)
      decoded = CrystalClick::BinaryValueCodec.decode(wire)
      decoded.type.aggregate_function_type.not_nil!.argument_type.should eq(nominal)
      decoded.aggregate_function_state_bytes.should eq(state_bytes)
    end
  end

  it "allows a present empty Tuple generic body without consuming the next state" do
    empty_tuple = CrystalClick::BinaryDataType.tuple([] of CrystalClick::BinaryDataType)
    nested_empty_tuple = CrystalClick::BinaryDataType.tuple([empty_tuple] of CrystalClick::BinaryDataType)
    nullable_empty_tuple = CrystalClick::BinaryDataType.nullable(empty_tuple)

    cases = [
      {empty_tuple, Bytes[1_u8], Bytes[0_u8]},
      {nested_empty_tuple, Bytes[1_u8], Bytes[0_u8]},
      {nullable_empty_tuple, Bytes[1_u8, 1_u8], Bytes[0_u8]},
    ] of Tuple(CrystalClick::BinaryDataType, Bytes, Bytes)

    cases.each do |argument, present_bytes, absent_bytes|
      type = CrystalClick::BinaryDataType.aggregate_function("max", argument)
      present = CrystalClick::BinaryValue.aggregate_function_state(type, present_bytes)
      absent = CrystalClick::BinaryValue.aggregate_function_state(type, absent_bytes)
      CrystalClick::BinaryValueCodec.decode_value(type, present_bytes).aggregate_function_state_bytes.should eq(present_bytes)
      CrystalClick::BinaryValueCodec.decode_value(type, absent_bytes).aggregate_function_state_bytes.should eq(absent_bytes)
      CrystalClick::BinaryValueCodec.encode_value(present).should eq(present_bytes)
      CrystalClick::BinaryValueCodec.encode_value(absent).should eq(absent_bytes)
      present.aggregate_function_state_bytes.should eq(present_bytes)
      absent.aggregate_function_state_bytes.should eq(absent_bytes)

      with_sentinel = Bytes.new(present_bytes.size + 1) do |index|
        index == present_bytes.size ? 0xa5_u8 : present_bytes[index]
      end
      context = CrystalClick::BinaryCodecContext.new(w237_minmax_limits, with_sentinel)
      CrystalClick::BinaryAggregateFunctionStateCodec.read(type, context, 1).should eq(present_bytes)
      context.read_byte.should eq(0xa5_u8)
    end
  end

  it "preserves nullable presence and LowCardinality dispatch wrappers nominally" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    string = CrystalClick::BinaryDataType.primitive("String")
    nullable_uint8 = CrystalClick::BinaryDataType.nullable(uint8)
    nullable_string = CrystalClick::BinaryDataType.nullable(string)
    low_cardinality_uint8 = CrystalClick::BinaryDataType.low_cardinality(uint8)
    low_cardinality_nullable_uint8 = CrystalClick::BinaryDataType.low_cardinality(nullable_uint8)

    cases = [
      {nullable_uint8, Bytes[0_u8]},
      {nullable_uint8, Bytes[1_u8, 1_u8, 0x2a_u8]},
      {nullable_string, Bytes[0_u8]},
      {nullable_string, Bytes[1_u8, 1_u8, 0_u8, 0_u8, 0_u8, 0_u8]},
      {low_cardinality_uint8, Bytes[1_u8, 0x2a_u8]},
      {low_cardinality_nullable_uint8, Bytes[1_u8, 1_u8, 0x2a_u8]},
    ] of Tuple(CrystalClick::BinaryDataType, Bytes)

    cases.each do |argument, state_bytes|
      type = CrystalClick::BinaryDataType.aggregate_function("max", argument)
      type.aggregate_function_type.not_nil!.argument_type.should eq(argument)
      CrystalClick::BinaryDataTypeCodec.decode(CrystalClick::BinaryDataTypeCodec.encode(type)).should eq(type)

      value = CrystalClick::BinaryValue.aggregate_function_state(type, state_bytes)
      CrystalClick::BinaryValueCodec.encode_value(value).should eq(state_bytes)
      decoded = CrystalClick::BinaryValueCodec.decode_value(type, state_bytes)
      decoded.type.should eq(type)
      decoded.aggregate_function_state_bytes.should eq(state_bytes)
    end
  end

  it "leaves the existing Count, Sum, and Avg state lanes intact" do
    count_type = CrystalClick::BinaryDataType.aggregate_count
    count = CrystalClick::BinaryValue.aggregate_count_state(count_type, 128_u64)
    CrystalClick::BinaryValueCodec.encode_value(count).should eq(Bytes[0x80_u8, 0x01_u8])
    CrystalClick::BinaryValueCodec.decode_value(count_type, Bytes[0x80_u8, 0x01_u8]).count_state.should eq(128_u64)

    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    sum_type = CrystalClick::BinaryDataType.aggregate_function("sum", uint8)
    sum_bytes = Bytes[0x80_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8]
    sum = CrystalClick::BinaryValue.aggregate_function_state(sum_type, sum_bytes)
    CrystalClick::BinaryValueCodec.encode_value(sum).should eq(sum_bytes)
    CrystalClick::BinaryValueCodec.decode_value(sum_type, sum_bytes).aggregate_function_state_bytes.should eq(sum_bytes)

    avg_type = CrystalClick::BinaryDataType.aggregate_function("avg", uint8)
    avg_bytes = Bytes.new(9, 0_u8)
    avg = CrystalClick::BinaryValue.aggregate_function_state(avg_type, avg_bytes)
    CrystalClick::BinaryValueCodec.encode_value(avg).should eq(avg_bytes)
    CrystalClick::BinaryValueCodec.decode_value(avg_type, avg_bytes).aggregate_function_state_bytes.should eq(avg_bytes)
  end
end
