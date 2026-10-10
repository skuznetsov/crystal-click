require "./spec_helper"
require "./support/aggregate_bitwise_w255_values"

describe "W255 AggregateFunction bitwise core" do
  it "covers all three functions over the exact twelve bare integer widths" do
    AggregateBitwiseW255Values::FUNCTIONS.each do |function_name|
      AggregateBitwiseW255Values::INTEGER_TYPES.each_with_index do |(type_name, width), index|
        argument = CrystalClick::BinaryDataType.primitive(type_name)
        type = CrystalClick::BinaryDataType.aggregate_function(function_name, argument)
        descriptor = type.aggregate_function_type.not_nil!
        plan = CrystalClick::BinaryAggregateFunctionStatePlan.for_type(type)

        type.name.should eq("AggregateFunction(#{function_name}, #{type_name})")
        type.child_count.should eq(0)
        descriptor.function_name.should eq(function_name)
        descriptor.argument_type.should eq(argument)
        descriptor.version.should eq(0_u8)
        plan.state_width.should eq(width)
        expected_default = if function_name == "groupBitAnd"
                             Bytes.new(width, 0xff_u8)
                           else
                             Bytes.new(width, 0_u8)
                           end
        plan.default_state_bytes.should eq(expected_default)

        wire = CrystalClick::BinaryDataTypeCodec.encode(type)
        CrystalClick::BinaryDataTypeCodec.decode(wire).should eq(type)
        CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(type.name).should eq(type)
        CrystalClick::BinaryAggregateFunctionBulkColumnDeclaration.parse(type.name).should eq(type)

        state_bytes = AggregateBitwiseW255Values.pattern(width, (index + 1).to_u8)
        value = CrystalClick::BinaryValue.aggregate_function_state(type, state_bytes)
        encoded = CrystalClick::BinaryValueCodec.encode_value(value)
        encoded.should eq(state_bytes)
        restored = CrystalClick::BinaryValueCodec.decode_value(type, encoded)
        restored.type.should eq(type)
        restored.aggregate_function_state_bytes.should eq(state_bytes)
        expect_raises(ArgumentError) { restored.count_state }
      end
    end
  end

  it "preserves asymmetric signed 128-bit and 256-bit state bytes without integer normalization" do
    int128 = CrystalClick::BinaryDataType.primitive("Int128")
    int256 = CrystalClick::BinaryDataType.primitive("Int256")
    type128 = CrystalClick::BinaryDataType.aggregate_function("groupBitXor", int128)
    type256 = CrystalClick::BinaryDataType.aggregate_function("groupBitAnd", int256)
    state128 = AggregateBitwiseW255Values.pattern(16, 0x13_u8)
    state256 = AggregateBitwiseW255Values.pattern(32, 0x29_u8)
    state128[15] |= 0x80_u8
    state256[31] |= 0x80_u8

    [
      {type128, state128},
      {type256, state256},
    ].each do |type, expected|
      decoded = CrystalClick::BinaryValueCodec.decode_value(type, expected)
      decoded.aggregate_function_state_bytes.should eq(expected)
      CrystalClick::BinaryValueCodec.encode_value(decoded).should eq(expected)
    end
    state128.should_not eq(Bytes.new(16, state128[0]))
    state256.should_not eq(Bytes.new(32, state256[0]))
  end

  it "rejects wrappers and non-integer leaves while retaining strict wire signature guards" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    array_argument = CrystalClick::BinaryDataType.array(uint8)
    tuple_argument = CrystalClick::BinaryDataType.tuple([uint8] of CrystalClick::BinaryDataType)
    map_argument = CrystalClick::BinaryDataType.map(uint8, uint8)
    variant_argument = CrystalClick::BinaryDataType.variant(
      [uint8, CrystalClick::BinaryDataType.primitive("String")] of CrystalClick::BinaryDataType,
    )
    dynamic_argument = CrystalClick::BinaryDataType.dynamic(1)
    nested_argument = CrystalClick::BinaryDataType.nested(
      [uint8] of CrystalClick::BinaryDataType,
      ["value"] of String,
    )
    rejected_arguments = [
      CrystalClick::BinaryDataType.primitive("String"),
      CrystalClick::BinaryDataType.primitive("Float32"),
      CrystalClick::BinaryDataType.primitive("Bool"),
      CrystalClick::BinaryDataType.decimal(32, 5, 2),
      CrystalClick::BinaryDataType.enum8([{"one", 1_i16}] of CrystalClick::BinaryEnumDefinition::Entry),
      CrystalClick::BinaryDataType.nullable(uint8),
      CrystalClick::BinaryDataType.low_cardinality(uint8),
      array_argument,
      tuple_argument,
      map_argument,
      variant_argument,
      dynamic_argument,
      nested_argument,
    ] of CrystalClick::BinaryDataType
    rejected_arguments.each do |argument|
      expect_raises(ArgumentError) do
        CrystalClick::BinaryDataType.aggregate_function("groupBitOr", argument)
      end
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.aggregate_function("groupBitOr", uint8, 1_u8)
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.aggregate_function("groupBitOrCombinator", uint8)
    end

    valid_argument_wire = CrystalClick::BinaryDataTypeCodec.encode(uint8)
    invalid_version = AggregateBitwiseW255Values.function_wire(
      "groupBitOr", valid_argument_wire, version: 1_u64)
    parameterized = AggregateBitwiseW255Values.function_wire(
      "groupBitOr", valid_argument_wire, parameter_count: 1_u64)
    zero_arguments = AggregateBitwiseW255Values.function_wire(
      "groupBitOr", valid_argument_wire, argument_count: 0_u64)
    two_arguments = AggregateBitwiseW255Values.function_wire(
      "groupBitOr", valid_argument_wire, argument_count: 2_u64)
    nullable_argument_wire = AggregateBitwiseW255Values.join([
      Bytes[CrystalClick::BinaryDataType::TAG_NULLABLE],
      valid_argument_wire,
    ] of Bytes)
    nullable_argument = AggregateBitwiseW255Values.function_wire("groupBitOr", nullable_argument_wire)

    # Descriptor-version, arity, parameter and function-profile refusals each
    # take the named unsupported-format path. The Nullable node itself is
    # valid wire; its use as a bitwise argument is refused by that same policy.
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.decode(invalid_version)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.decode(parameterized)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.decode(zero_arguments)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.decode(two_arguments)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.decode(nullable_argument)
    end
  end

  it "rejects truncated and trailing fixed-state bytes and keeps Count's getter separate" do
    type = CrystalClick::BinaryDataType.aggregate_function(
      "groupBitXor",
      CrystalClick::BinaryDataType.primitive("UInt128"),
    )
    valid = AggregateBitwiseW255Values.pattern(16, 0x41_u8)
    expect_raises(ArgumentError) do
      CrystalClick::BinaryValue.aggregate_function_state(type, valid[0, 15])
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode_value(type, valid[0, 15])
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode_value(
        type,
        AggregateBitwiseW255Values.join([valid, Bytes[0x99_u8]] of Bytes),
      )
    end

    count = CrystalClick::BinaryDataType.aggregate_count
    expect_raises(ArgumentError) do
      CrystalClick::BinaryValue.aggregate_function_state(count, Bytes.new(8, 0_u8))
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryValue.aggregate_count_state(type, 7_u64)
    end
  end

  it "charges descriptor bytes, nodes, edges, and depth through existing bounded codec paths" do
    type = CrystalClick::BinaryDataType.aggregate_function(
      "groupBitOr",
      CrystalClick::BinaryDataType.primitive("UInt8"),
    )
    wire = CrystalClick::BinaryDataTypeCodec.encode(type)
    exact = CrystalClick::BinaryCodecLimits.new(2, 2, 1, wire.size)
    # Type-name work charges the output plus bounded temporary allocations,
    # not just the final SQL spelling's byte length. For this aggregate the
    # independent source-derived allocation bound is 126 bytes.
    exact_name = CrystalClick::BinaryCodecLimits.new(2, 2, 1, 126)
    CrystalClick::BinaryDataTypeCodec.encode(type, exact).should eq(wire)
    CrystalClick::BinaryDataTypeCodec.decode(wire, exact).should eq(type)
    CrystalClick::BinaryAggregateFunctionBulkColumnDeclaration.parse(type.name, exact_name).should eq(type)

    too_shallow = CrystalClick::BinaryCodecLimits.new(1, 2, 1, wire.size)
    too_few_nodes = CrystalClick::BinaryCodecLimits.new(2, 1, 1, wire.size)
    too_few_edges = CrystalClick::BinaryCodecLimits.new(2, 2, 0, wire.size)
    too_few_bytes = CrystalClick::BinaryCodecLimits.new(2, 2, 1, wire.size - 1)
    [too_shallow, too_few_nodes, too_few_edges, too_few_bytes].each do |limits|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryDataTypeCodec.encode(type, limits)
      end
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryDataTypeCodec.decode(wire, limits)
      end
    end

    too_shallow_name = CrystalClick::BinaryCodecLimits.new(1, 2, 1, 126)
    too_few_name_nodes = CrystalClick::BinaryCodecLimits.new(2, 1, 1, 126)
    too_few_name_edges = CrystalClick::BinaryCodecLimits.new(2, 2, 0, 126)
    too_few_name_bytes = CrystalClick::BinaryCodecLimits.new(2, 2, 1, 125)
    [too_shallow_name, too_few_name_nodes, too_few_name_edges, too_few_name_bytes].each do |limits|
      CrystalClick::BinaryAggregateFunctionBulkColumnDeclaration.parse(type.name, limits).should be_nil
    end
  end
end
