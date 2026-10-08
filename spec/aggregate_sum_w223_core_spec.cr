require "./spec_helper"

private def w223_core_case(
  type : CrystalClick::BinaryDataType,
  sum_width : Int32,
  overflow_width : Int32,
  kahan_name : String = "sumKahan",
  kahan_width : Int32 = 16,
) : Tuple(CrystalClick::BinaryDataType, Int32, Int32, String, Int32)
  {type, sum_width, overflow_width, kahan_name, kahan_width}
end

describe "W223 AggregateFunction Sum core" do
  it "preserves the canonical root descriptor and literal tag-0x25 bytes" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    type = CrystalClick::BinaryDataType.aggregate_function("sum", uint8)
    literal = Bytes[0x25_u8, 0x00_u8, 0x03_u8, 0x73_u8, 0x75_u8, 0x6d_u8, 0x00_u8, 0x01_u8, 0x01_u8]

    type.name.should eq("AggregateFunction(sum, UInt8)")
    type.child_count.should eq(0)
    type.fixed_width.should be_nil
    type.contains_aggregate_count?.should be_false
    type.contains_aggregate_function?.should be_true
    type.aggregate_function_type.not_nil!.argument_type.should eq(uint8)
    CrystalClick::BinaryDataTypeCodec.encode(type).should eq(literal)
    CrystalClick::BinaryDataTypeCodec.decode(literal).should eq(type)
    CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(type.name).should eq(type)
  end

  it "keeps Count routed to its exact legacy descriptor and codec" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    count = CrystalClick::BinaryDataType.aggregate_count(uint8)
    generic_constructor = CrystalClick::BinaryDataType.aggregate_function("count", uint8)

    generic_constructor.should eq(count)
    generic_constructor.aggregate_count_type.should eq(count.aggregate_count_type)
    CrystalClick::BinaryDataTypeCodec.decode(CrystalClick::BinaryDataTypeCodec.encode(count)).should eq(count)
    CrystalClick::BinaryValueCodec.encode_value(
      CrystalClick::BinaryValue.aggregate_count_state(count, 128_u64)
    ).should eq(Bytes[0x80_u8, 0x01_u8])
  end

  it "covers the numeric, Bool, Enum, Decimal, and Interval state-width laws" do
    cases = [] of Tuple(CrystalClick::BinaryDataType, Int32, Int32, String, Int32)
    [
      {"UInt8", 8, 1}, {"UInt16", 8, 2}, {"UInt32", 8, 4},
      {"UInt64", 8, 8}, {"UInt128", 16, 16}, {"UInt256", 32, 32},
      {"Int8", 8, 1}, {"Int16", 8, 2}, {"Int32", 8, 4},
      {"Int64", 8, 8}, {"Int128", 16, 16}, {"Int256", 32, 32},
      {"Float32", 8, 4}, {"Float64", 8, 8}, {"BFloat16", 8, 2},
    ].each do |name, sum_width, overflow_width|
      cases << w223_core_case(
        CrystalClick::BinaryDataType.primitive(name),
        sum_width.to_i32,
        overflow_width.to_i32
      )
    end

    bool = CrystalClick::BinaryDataType.primitive("Bool")
    cases << w223_core_case(bool, 8, 1)
    enum8 = CrystalClick::BinaryDataType.enum8(
      [{"one", 1_i16}, {"two", 2_i16}] of CrystalClick::BinaryEnumDefinition::Entry
    )
    enum16 = CrystalClick::BinaryDataType.enum16(
      [{"one", 1_i16}, {"two", 2_i16}] of CrystalClick::BinaryEnumDefinition::Entry
    )
    cases << w223_core_case(enum8, 8, 1)
    cases << w223_core_case(enum16, 8, 2)

    cases << w223_core_case(CrystalClick::BinaryDataType.decimal(32, 9, 2), 16, 4, "sum", 16)
    cases << w223_core_case(CrystalClick::BinaryDataType.decimal(64, 18, 2), 16, 8, "sum", 16)
    cases << w223_core_case(CrystalClick::BinaryDataType.decimal(128, 24, 2), 16, 16, "sum", 16)
    cases << w223_core_case(CrystalClick::BinaryDataType.decimal(256, 40, 2), 32, 32, "sum", 32)

    [
      CrystalClick::BinaryIntervalType::Kind::Nanosecond,
      CrystalClick::BinaryIntervalType::Kind::Microsecond,
      CrystalClick::BinaryIntervalType::Kind::Millisecond,
      CrystalClick::BinaryIntervalType::Kind::Second,
      CrystalClick::BinaryIntervalType::Kind::Minute,
      CrystalClick::BinaryIntervalType::Kind::Hour,
      CrystalClick::BinaryIntervalType::Kind::Day,
      CrystalClick::BinaryIntervalType::Kind::Week,
      CrystalClick::BinaryIntervalType::Kind::Month,
      CrystalClick::BinaryIntervalType::Kind::Quarter,
      CrystalClick::BinaryIntervalType::Kind::Year,
    ].each do |kind|
      cases << w223_core_case(CrystalClick::BinaryDataType.interval(kind), 8, 8, "sum", 8)
    end

    cases.each do |leaf, sum_width, overflow_width, kahan_name, kahan_width|
      sum = CrystalClick::BinaryDataType.aggregate_function("sum", leaf)
      sum.name.should eq("AggregateFunction(sum, #{leaf.name})")
      sum.child_count.should eq(0)
      sum.fixed_width.should be_nil
      sum.aggregate_function_type.not_nil!.argument_type.should eq(leaf)
      CrystalClick::BinaryAggregateFunctionStatePlan.for_type(sum).state_width.should eq(sum_width)

      overflow = CrystalClick::BinaryDataType.aggregate_function("sumWithOverflow", leaf)
      overflow.name.should eq("AggregateFunction(sumWithOverflow, #{leaf.name})")
      overflow.aggregate_function_type.not_nil!.argument_type.should eq(leaf)
      CrystalClick::BinaryAggregateFunctionStatePlan.for_type(overflow).state_width.should eq(overflow_width)

      kahan = CrystalClick::BinaryDataType.aggregate_function("sumKahan", leaf)
      kahan_function = kahan.aggregate_function_type.not_nil!.function_name
      kahan_function.should eq(kahan_name)
      kahan.name.should eq("AggregateFunction(#{kahan_name}, #{leaf.name})")
      kahan.aggregate_function_type.not_nil!.argument_type.should eq(leaf)
      CrystalClick::BinaryAggregateFunctionStatePlan.for_type(kahan).state_width.should eq(kahan_width)
    end
  end

  it "preserves legal argument wrappers as metadata and rejects unsupported shapes" do
    leaves = [
      CrystalClick::BinaryDataType.primitive("UInt8"),
      CrystalClick::BinaryDataType.primitive("Float32"),
      CrystalClick::BinaryDataType.primitive("Bool"),
      CrystalClick::BinaryDataType.interval(CrystalClick::BinaryIntervalType::Kind::Hour),
    ] of CrystalClick::BinaryDataType

    leaves.each do |leaf|
      nullable = CrystalClick::BinaryDataType.nullable(leaf)
      low_cardinality = CrystalClick::BinaryDataType.low_cardinality(leaf)
      low_cardinality_nullable = CrystalClick::BinaryDataType.low_cardinality(nullable)
      [leaf, nullable, low_cardinality, low_cardinality_nullable].each do |argument|
        type = CrystalClick::BinaryDataType.aggregate_function("sum", argument)
        type.aggregate_function_type.not_nil!.argument_type.should eq(argument)
        CrystalClick::BinaryDataTypeCodec.decode(CrystalClick::BinaryDataTypeCodec.encode(type)).should eq(type)
      end
    end

    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.aggregate_function("sum", CrystalClick::BinaryDataType.array(uint8))
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.aggregate_function("sum", CrystalClick::BinaryDataType.primitive("String"))
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.nullable(CrystalClick::BinaryDataType.low_cardinality(uint8))
    end

    enum8 = CrystalClick::BinaryDataType.enum8(
      [{"one", 1_i16}] of CrystalClick::BinaryEnumDefinition::Entry
    )
    decimal32 = CrystalClick::BinaryDataType.decimal(32, 5, 2)
    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.low_cardinality(enum8) }
    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.low_cardinality(decimal32) }

    canonical_decimal = CrystalClick::BinaryDataType.decimal(32, 5, 2)
    same_name_other_width = CrystalClick::BinaryDataType.decimal(64, 5, 2)
    same_name_other_width.name.should eq(canonical_decimal.name)
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.aggregate_function("sum", same_name_other_width)
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.aggregate_function(
        "sum",
        CrystalClick::BinaryDataType.nullable(same_name_other_width)
      )
    end
  end

  it "canonicalizes only source-defined function identities and rejects bad signatures" do
    decimal = CrystalClick::BinaryDataType.decimal(128, 24, 2)
    interval = CrystalClick::BinaryDataType.interval(CrystalClick::BinaryIntervalType::Kind::Day)
    decimal_kahan = CrystalClick::BinaryDataType.aggregate_function("sumKahan", decimal)
    interval_kahan = CrystalClick::BinaryDataType.aggregate_function("sumKahan", interval)
    decimal_kahan.aggregate_function_type.not_nil!.function_name.should eq("sum")
    interval_kahan.aggregate_function_type.not_nil!.function_name.should eq("sum")
    CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(decimal_kahan.name).should eq(decimal_kahan)
    CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical("AggregateFunction(sumKahan, Decimal(24, 2))").should be_nil

    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.aggregate_function("avg", uint8) }
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.aggregate_function("sum", uint8, 1_u8)
    end
    sum = CrystalClick::BinaryDataType.aggregate_function("sum", uint8)
    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.aggregate_count(sum) }
    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.aggregate_function("count", sum) }

    [
      Bytes[0x25_u8, 0x01_u8, 0x03_u8, 0x73_u8, 0x75_u8, 0x6d_u8, 0_u8, 1_u8, 1_u8],
      Bytes[0x25_u8, 0_u8, 0x03_u8, 0x73_u8, 0x75_u8, 0x6d_u8, 1_u8],
      Bytes[0x25_u8, 0_u8, 0x03_u8, 0x73_u8, 0x75_u8, 0x6d_u8, 0_u8, 0_u8],
      Bytes[0x25_u8, 0_u8, 0x03_u8, 0x73_u8, 0x75_u8, 0x6d_u8, 0_u8, 2_u8],
    ].each do |wire|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryDataTypeCodec.decode(wire)
      end
    end
  end

  it "preflights argument metadata against depth, node, edge, and byte limits" do
    type = CrystalClick::BinaryDataType.aggregate_function(
      "sum",
      CrystalClick::BinaryDataType.primitive("UInt8")
    )
    wire = Bytes[0x25_u8, 0_u8, 3_u8, 0x73_u8, 0x75_u8, 0x6d_u8, 0_u8, 1_u8, 1_u8]
    exact = CrystalClick::BinaryCodecLimits.new(max_depth: 2, max_nodes: 2, max_elements: 1, max_bytes: 9)
    CrystalClick::BinaryDataTypeCodec.encode(type, exact).should eq(wire)
    CrystalClick::BinaryDataTypeCodec.decode(wire, exact).should eq(type)

    [
      CrystalClick::BinaryCodecLimits.new(max_depth: 1, max_nodes: 2, max_elements: 1, max_bytes: 9),
      CrystalClick::BinaryCodecLimits.new(max_depth: 2, max_nodes: 1, max_elements: 1, max_bytes: 9),
      CrystalClick::BinaryCodecLimits.new(max_depth: 2, max_nodes: 2, max_elements: 0, max_bytes: 9),
      CrystalClick::BinaryCodecLimits.new(max_depth: 2, max_nodes: 2, max_elements: 1, max_bytes: 8),
    ].each do |limits|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryDataTypeCodec.encode(type, limits)
      end
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryDataTypeCodec.decode(wire, limits)
      end
    end
  end
end
