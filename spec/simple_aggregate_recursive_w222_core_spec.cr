require "./spec_helper"

private def w222_core_descriptor_wire(
  function_name : String,
  parameter_count : UInt8,
  parameter_fields : Array(UInt8),
  child_wire : Bytes,
) : Bytes
  bytes = [] of UInt8
  bytes << CrystalClick::BinaryDataType::TAG_SIMPLE_AGGREGATE
  bytes << function_name.bytesize.to_u8
  bytes.concat(function_name.to_slice.to_a)
  bytes << parameter_count
  bytes.concat(parameter_fields)
  bytes << 1_u8 # unary storage argument count
  bytes.concat(child_wire.to_a)
  Bytes.new(bytes.size) { |index| bytes[index] }
end

private def w222_core_descriptor_prefix(function_name : String, parameter_count : UInt8) : Bytes
  bytes = [] of UInt8
  bytes << CrystalClick::BinaryDataType::TAG_SIMPLE_AGGREGATE
  bytes << function_name.bytesize.to_u8
  bytes.concat(function_name.to_slice.to_a)
  bytes << parameter_count
  Bytes.new(bytes.size) { |index| bytes[index] }
end

describe "W222 recursive SimpleAggregateFunction core" do
  it "preserves all canonical function identities and the preexisting enum ordinals" do
    functions = [
      {"any", CrystalClick::BinarySimpleAggregateType::Function::Any, 0, "UInt64", nil},
      {"anyLast", CrystalClick::BinarySimpleAggregateType::Function::AnyLast, 1, "Array(Int16)", nil},
      {"min", CrystalClick::BinarySimpleAggregateType::Function::Min, 2, "UInt64", nil},
      {"max", CrystalClick::BinarySimpleAggregateType::Function::Max, 3, "UInt64", nil},
      {"sum", CrystalClick::BinarySimpleAggregateType::Function::Sum, 4, "Decimal(24, 2)", nil},
      {"sumWithOverflow", CrystalClick::BinarySimpleAggregateType::Function::SumWithOverflow, 5, "UInt64", nil},
      {"groupBitAnd", CrystalClick::BinarySimpleAggregateType::Function::GroupBitAnd, 6, "UInt64", nil},
      {"groupBitOr", CrystalClick::BinarySimpleAggregateType::Function::GroupBitOr, 7, "UInt64", nil},
      {"groupBitXor", CrystalClick::BinarySimpleAggregateType::Function::GroupBitXor, 8, "UInt64", nil},
      {"any_respect_nulls", CrystalClick::BinarySimpleAggregateType::Function::AnyRespectNulls, 9, "UInt64", nil},
      {"anyLast_respect_nulls", CrystalClick::BinarySimpleAggregateType::Function::AnyLastRespectNulls, 10, "String", nil},
      {"sumMap", CrystalClick::BinarySimpleAggregateType::Function::SumMap, 11, "Tuple(Array(Int32), Array(Int64))", nil},
      {"minMap", CrystalClick::BinarySimpleAggregateType::Function::MinMap, 12, "Tuple(Array(Int32), Array(Int64))", nil},
      {"maxMap", CrystalClick::BinarySimpleAggregateType::Function::MaxMap, 13, "Tuple(Array(Int32), Array(Int64))", nil},
      {"groupArrayArray", CrystalClick::BinarySimpleAggregateType::Function::GroupArrayArray, 14, "Array(Int32)", 1_u64},
      {"groupArrayLastArray", CrystalClick::BinarySimpleAggregateType::Function::GroupArrayLastArray, 15, "Array(UInt64)", 5_u64},
      {"groupUniqArrayArray", CrystalClick::BinarySimpleAggregateType::Function::GroupUniqArrayArray, 16, "Array(Int32)", 1_u64},
      {"groupUniqArrayArrayMap", CrystalClick::BinarySimpleAggregateType::Function::GroupUniqArrayArrayMap, 17, "Map(Int32, Array(Int64))", 1_u64},
      {"timeSeriesGroupArray", CrystalClick::BinarySimpleAggregateType::Function::TimeSeriesGroupArray, 18, "Array(Tuple(UInt32, Float64))", nil},
    ] of Tuple(String, CrystalClick::BinarySimpleAggregateType::Function, Int32, String, UInt64?)

    functions.each do |function_name, function, old_ordinal, child_name, cap|
      function.value.to_i32.should eq(old_ordinal)
      CrystalClick::BinarySimpleAggregateType.function_from_name(function_name).should eq(function)

      child = CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(child_name)
      child.should_not be_nil
      if storage = child
        parameters = cap ? CrystalClick::BinarySimpleAggregateParameters.one(cap) : CrystalClick::BinarySimpleAggregateParameters.empty
        descriptor = CrystalClick::BinarySimpleAggregateType.from_storage(function, storage, parameters)
        source = "SimpleAggregateFunction(#{descriptor.function_signature}, #{child_name})"
        expected = CrystalClick::BinaryDataType.simple_aggregate(function, storage, parameters)

        parsed = CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(source)
        parsed.should eq(expected)
        if type = parsed
          nominal = type.simple_aggregate_type.not_nil!
          nominal.function.should eq(function)
          nominal.function_name.should eq(function_name)
          nominal.storage_type.should eq(storage)
          nominal.parameters.should eq(parameters)
          type.child_count.should eq(1)
          type.child_at(0).should eq(storage)
          type.name.should eq(source)

          decoded = CrystalClick::BinaryDataTypeCodec.decode(CrystalClick::BinaryDataTypeCodec.encode(type))
          decoded.should eq(type)
          decoded.simple_aggregate_type.not_nil!.storage_type.should eq(storage)
        end
      end
    end

    # Canonical lookup is exact rather than alias-normalizing.
    ["ANYLAST", "anyRespectNulls", "anyLastRespectNulls", "any_last_respect_nulls"].each do |alias_name|
      CrystalClick::BinarySimpleAggregateType.function_from_name(alias_name).should be_nil
      source = "SimpleAggregateFunction(#{alias_name}, UInt64)"
      CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(source).should be_nil
    end
  end

  it "admits only zero or one positive UInt64 Field and preserves both cap boundaries" do
    child = CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical("Array(UInt8)").not_nil!
    function = CrystalClick::BinarySimpleAggregateType::Function::GroupArrayLastArray

    [1_u64, UInt64::MAX].each do |cap|
      parameters = CrystalClick::BinarySimpleAggregateParameters.one(cap)
      type = CrystalClick::BinaryDataType.simple_aggregate(function, child, parameters)
      source = "SimpleAggregateFunction(groupArrayLastArray(#{cap}), Array(UInt8))"

      parsed = CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(source)
      parsed.should eq(type)
      if descriptor = parsed
        descriptor.simple_aggregate_type.not_nil!.parameters.value_at(0).should eq(cap)
        descriptor.simple_aggregate_type.not_nil!.storage_type.should eq(child)
      end
      CrystalClick::BinaryDataTypeCodec.decode(CrystalClick::BinaryDataTypeCodec.encode(type)).should eq(type)
    end

    expect_raises(ArgumentError) do
      CrystalClick::BinarySimpleAggregateParameters.new([0_u64])
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinarySimpleAggregateParameters.new([1_u64, 2_u64])
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.simple_aggregate(
        function,
        child,
        CrystalClick::BinarySimpleAggregateParameters.empty,
      )
    end

    child_wire = Bytes[0x1e_u8, 0x01_u8] # Array(UInt8)
    malformed = [
      # This function requires exactly one parameter, not the zero-Field form.
      w222_core_descriptor_wire("groupArrayLastArray", 0_u8, [] of UInt8, child_wire),
      # Two Fields are outside this bounded parameter profile.
      w222_core_descriptor_wire("groupArrayLastArray", 2_u8, [0x01_u8, 0x01_u8, 0x01_u8, 0x02_u8] of UInt8, child_wire),
      # Field tag 2 is Int64, not the admitted UInt64.
      w222_core_descriptor_wire("groupArrayLastArray", 1_u8, [0x02_u8, 0x01_u8] of UInt8, child_wire),
      # A UInt64 Field is still required to be strictly positive.
      w222_core_descriptor_wire("groupArrayLastArray", 1_u8, [0x01_u8, 0x00_u8] of UInt8, child_wire),
    ]
    malformed.each do |wire|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryDataTypeCodec.decode(wire)
      end
    end
  end

  it "rejects forbidden parameter counts before reading a truncated Field payload" do
    # `any` has a zero-parameter law. Stop immediately after its parameter
    # count so this distinguishes the function/count guard from a failed
    # attempt to decode the absent Field tag.
    forbidden_count = w222_core_descriptor_prefix("any", 1_u8)
    forbidden_count.size.should eq(6)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.decode(forbidden_count)
    end

    # The same truncated payload is reached for a function that admits one
    # UInt64 Field; that path must report truncation instead of the count guard.
    admitted_count = w222_core_descriptor_prefix("groupArrayLastArray", 1_u8)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(admitted_count)
    end

    # Permit the root node and all six prefix bytes, but leave no budget for
    # parameter metadata. The forbidden-count policy is checked before that
    # metadata preflight, so it must remain the observed failure.
    prefix_budget = CrystalClick::BinaryCodecLimits.new(
      max_depth: 1,
      max_nodes: 1,
      max_elements: 0,
      max_bytes: forbidden_count.size,
    )
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.decode(forbidden_count, prefix_budget)
    end
  end

  it "matches an independent literal wire fixture for the UInt64 maximum cap" do
    child = CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.primitive("UInt8"))
    type = CrystalClick::BinaryDataType.simple_aggregate(
      CrystalClick::BinarySimpleAggregateType::Function::GroupArrayLastArray,
      child,
      CrystalClick::BinarySimpleAggregateParameters.one(UInt64::MAX),
    )

    # Independently specified wire bytes: SAF tag/name, one UInt64 Field,
    # canonical ten-byte LEB128 UInt64::MAX, unary arity, Array(UInt8).
    literal = Bytes[
      0x2e_u8, 0x13_u8,
      0x67_u8, 0x72_u8, 0x6f_u8, 0x75_u8, 0x70_u8,
      0x41_u8, 0x72_u8, 0x72_u8, 0x61_u8, 0x79_u8,
      0x4c_u8, 0x61_u8, 0x73_u8, 0x74_u8,
      0x41_u8, 0x72_u8, 0x72_u8, 0x61_u8, 0x79_u8,
      0x01_u8, 0x01_u8,
      0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8,
      0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0x01_u8,
      0x01_u8, 0x1e_u8, 0x01_u8,
    ]

    literal.size.should eq(36)
    CrystalClick::BinaryDataTypeCodec.encode(type).should eq(literal)
    CrystalClick::BinaryDataTypeCodec.decode(literal).should eq(type)
    type.name.should eq("SimpleAggregateFunction(groupArrayLastArray(18446744073709551615), Array(UInt8))")
  end

  it "charges SAF parameter metadata in paired node, edge, and byte budgets" do
    child = CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.primitive("UInt8"))
    type = CrystalClick::BinaryDataType.simple_aggregate(
      CrystalClick::BinarySimpleAggregateType::Function::GroupArrayLastArray,
      child,
      CrystalClick::BinarySimpleAggregateParameters.one(1_u64),
    )
    literal = Bytes[
      0x2e_u8, 0x13_u8,
      0x67_u8, 0x72_u8, 0x6f_u8, 0x75_u8, 0x70_u8,
      0x41_u8, 0x72_u8, 0x72_u8, 0x61_u8, 0x79_u8,
      0x4c_u8, 0x61_u8, 0x73_u8, 0x74_u8,
      0x41_u8, 0x72_u8, 0x72_u8, 0x61_u8, 0x79_u8,
      0x01_u8, 0x01_u8, 0x01_u8,
      0x01_u8, 0x1e_u8, 0x01_u8,
    ]
    literal.size.should eq(27)

    exact = CrystalClick::BinaryCodecLimits.new(
      max_depth: 3,
      max_nodes: 4,
      max_elements: 3,
      max_bytes: literal.size,
    )
    CrystalClick::BinaryDataTypeCodec.encode(type, exact).should eq(literal)
    CrystalClick::BinaryDataTypeCodec.decode(literal, exact).should eq(type)

    no_metadata_node = CrystalClick::BinaryCodecLimits.new(
      max_depth: 3,
      max_nodes: 3,
      max_elements: 3,
      max_bytes: literal.size,
    )
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.encode(type, no_metadata_node)
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(literal, no_metadata_node)
    end

    no_metadata_edge = CrystalClick::BinaryCodecLimits.new(
      max_depth: 3,
      max_nodes: 4,
      max_elements: 2,
      max_bytes: literal.size,
    )
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.encode(type, no_metadata_edge)
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(literal, no_metadata_edge)
    end

    one_byte_short = CrystalClick::BinaryCodecLimits.new(
      max_depth: 3,
      max_nodes: 4,
      max_elements: 3,
      max_bytes: literal.size - 1,
    )
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.encode(type, one_byte_short)
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(literal, one_byte_short)
    end
  end

  it "retains recursive Decimal and FixedString profile guards and the old Count scalar gate" do
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.simple_aggregate(
        CrystalClick::BinarySimpleAggregateType::Function::Sum,
        CrystalClick::BinaryDataType.decimal(32, 8, 2),
      )
    end

    noncanonical_width = CrystalClick::BinaryDataType.array(
      CrystalClick::BinaryDataType.decimal(64, 8, 2),
    )
    noncanonical_width.child_at(0).name.should eq("Decimal(8, 2)")
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.simple_aggregate(
        CrystalClick::BinarySimpleAggregateType::Function::AnyLast,
        noncanonical_width,
      )
    end

    noncanonical_scale = CrystalClick::BinaryDataType.array(
      CrystalClick::BinaryDataType.decimal(32, 5, 6),
    )
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.simple_aggregate(
        CrystalClick::BinarySimpleAggregateType::Function::AnyLast,
        noncanonical_scale,
      )
    end

    max_fixed_string = CrystalClick::BinaryDataType.array(
      CrystalClick::BinaryDataType.fixed_string(CrystalClick::BinarySimpleAggregateType::MAX_FIXED_STRING_WIDTH),
    )
    admitted = CrystalClick::BinaryDataType.simple_aggregate(
      CrystalClick::BinarySimpleAggregateType::Function::AnyLast,
      max_fixed_string,
    )
    admitted.child_at(0).should eq(max_fixed_string)
    CrystalClick::BinaryDataTypeCodec.decode(CrystalClick::BinaryDataTypeCodec.encode(admitted)).should eq(admitted)

    over_limit_fixed_string = CrystalClick::BinaryDataType.array(
      CrystalClick::BinaryDataType.fixed_string(CrystalClick::BinarySimpleAggregateType::MAX_FIXED_STRING_WIDTH + 1),
    )
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.simple_aggregate(
        CrystalClick::BinarySimpleAggregateType::Function::AnyLast,
        over_limit_fixed_string,
      )
    end

    old_scalar = CrystalClick::BinaryAggregateCountArgumentNameParser.parse_canonical(
      "SimpleAggregateFunction(min, UInt64)",
    )
    old_scalar.should_not be_nil
    old_scalar.not_nil!.simple_aggregate_type.not_nil!.function.should eq(
      CrystalClick::BinarySimpleAggregateType::Function::Min,
    )

    [
      "SimpleAggregateFunction(anyLast, Array(Int16))",
      "SimpleAggregateFunction(groupArrayLastArray(5), Array(UInt64))",
    ].each do |source|
      CrystalClick::BinaryAggregateCountArgumentNameParser.parse_canonical(source).should be_nil
    end
  end
end
