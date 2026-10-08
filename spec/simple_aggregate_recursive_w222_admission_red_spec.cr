require "./spec_helper"

private def w222_try_build_simple_aggregate(
  function : CrystalClick::BinarySimpleAggregateType::Function,
  storage_type : CrystalClick::BinaryDataType,
) : CrystalClick::BinaryDataType?
  begin
    CrystalClick::BinaryDataType.simple_aggregate(function, storage_type)
  rescue ex : ArgumentError
    nil
  end
end

private def w222_simple_aggregate_wire(
  function_name : String,
  child_wire : Bytes,
) : Array(UInt8)
  bytes = [] of UInt8
  bytes << CrystalClick::BinaryDataType::TAG_SIMPLE_AGGREGATE
  bytes << function_name.bytesize.to_u8
  bytes.concat(function_name.to_slice.to_a)
  bytes << 0_u8 # zero function parameters
  bytes << 1_u8 # exactly one storage type
  bytes.concat(child_wire.to_a)
  bytes
end

describe "W222 recursive SimpleAggregateFunction admission RED" do
  it "composes the existing Array child codec for the stock AnyLast(Array(Int16)) type" do
    int16_type = CrystalClick::BinaryDataType.primitive("Int16")
    array_type = CrystalClick::BinaryDataType.array(int16_type)
    aggregate = w222_try_build_simple_aggregate(
      CrystalClick::BinarySimpleAggregateType::Function::AnyLast,
      array_type,
    )

    aggregate.should_not be_nil
    if type = aggregate
      type.tag.should eq(CrystalClick::BinaryDataType::TAG_SIMPLE_AGGREGATE)
      type.name.should eq("SimpleAggregateFunction(anyLast, Array(Int16))")
      type.child_at(0).should eq(array_type)

      descriptor = CrystalClick::BinaryDataTypeCodec.encode(type)
      decoded_type = CrystalClick::BinaryDataTypeCodec.decode(descriptor)
      decoded_type.should eq(type)
      decoded_type.name.should eq(type.name)

      values = CrystalClick::BinaryValue.array(array_type, [
        CrystalClick::BinaryValue.fixed(int16_type, Bytes[0x01_u8, 0x00_u8]),
        CrystalClick::BinaryValue.fixed(int16_type, Bytes[0xfe_u8, 0xff_u8]),
      ])
      wrapped = CrystalClick::BinaryValue.simple_aggregate(type, values)
      encoded_value = CrystalClick::BinaryValueCodec.encode(wrapped)
      decoded_value = CrystalClick::BinaryValueCodec.decode(encoded_value)
      decoded_value.type.should eq(type)
      decoded_value.as_simple_aggregate.type.should eq(array_type)
      decoded_value.as_simple_aggregate.element_count.should eq(2)
      decoded_value.as_simple_aggregate.element_at(0).bytes.should eq(Bytes[0x01_u8, 0x00_u8])
      decoded_value.as_simple_aggregate.element_at(1).bytes.should eq(Bytes[0xfe_u8, 0xff_u8])
    end

    # Recursive generic admission must not widen the legacy scalar facade.
    CrystalClick::SimpleAggregateColumnType.parse(
      "SimpleAggregateFunction(anyLast, Array(Int16))",
    ).should be_nil
    CrystalClick::WidePart.supports_typed_type?(
      "SimpleAggregateFunction(anyLast, Array(Int16))",
    ).should be_false
  end

  it "parses the stock recursive-storage declarations with exact nominal child trees" do
    declarations = [
      {"sumMap", "Tuple(Array(Int32), Array(Int64))"},
      {"minMap", "Tuple(Array(Int32), Array(Int64))"},
      {"maxMap", "Tuple(Array(Int32), Array(Int64))"},
      {"groupArrayArray", "Array(Int32)"},
      {"groupArrayArray", "Array(Array(UInt64))"},
      {"groupUniqArrayArray", "Array(Int32)"},
      {"groupUniqArrayArrayMap", "Map(Int32, Array(Int64))"},
    ] of Tuple(String, String)

    declarations.each do |function_name, child_name|
      source = "SimpleAggregateFunction(#{function_name}, #{child_name})"
      parsed = CrystalClick::SimpleAggregateBulkColumnDeclaration.parse(source)
      parsed.should_not be_nil
      if type = parsed
        type.tag.should eq(CrystalClick::BinaryDataType::TAG_SIMPLE_AGGREGATE)
        type.name.should eq(source)
        type.simple_aggregate_type.not_nil!.function_name.should eq(function_name)
        type.child_count.should eq(1)

        encoded = CrystalClick::BinaryDataTypeCodec.encode(type)
        decoded = CrystalClick::BinaryDataTypeCodec.decode(encoded)
        decoded.should eq(type)
        decoded.name.should eq(source)
      end
    end
  end

  it "preserves the unnamed mapped result identity without widening it to Named Tuple" do
    int32_type = CrystalClick::BinaryDataType.primitive("Int32")
    int64_type = CrystalClick::BinaryDataType.primitive("Int64")
    named_tuple = CrystalClick::BinaryDataType.tuple(
      [
        CrystalClick::BinaryDataType.array(int32_type),
        CrystalClick::BinaryDataType.array(int64_type),
      ] of CrystalClick::BinaryDataType,
      ["a", "b"] of String,
    )
    named_tuple.tag.should eq(CrystalClick::BinaryDataType::TAG_NAMED_TUPLE)

    # These three factories construct an unnamed positional tuple result.
    [
      {"sumMap", CrystalClick::BinarySimpleAggregateType::Function::SumMap},
      {"minMap", CrystalClick::BinarySimpleAggregateType::Function::MinMap},
      {"maxMap", CrystalClick::BinarySimpleAggregateType::Function::MaxMap},
    ].each do |function_name, function|
      source = "SimpleAggregateFunction(#{function_name}, #{named_tuple.name})"
      CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(source).should be_nil
      CrystalClick::SimpleAggregateBulkColumnDeclaration.parse(source).should be_nil

      expect_raises(ArgumentError) do
        CrystalClick::BinaryDataType.simple_aggregate(function, named_tuple)
      end

      malformed_wire = w222_simple_aggregate_wire(
        function_name,
        CrystalClick::BinaryDataTypeCodec.encode(named_tuple),
      )
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryDataTypeCodec.decode(Bytes.new(malformed_wire.size) { |index| malformed_wire[index] })
      end
    end

    # Standalone Tuple and identity-result AnyLast preserve names nominally.
    CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(named_tuple.name).should eq(named_tuple)
    any_last = CrystalClick::BinaryDataType.simple_aggregate(
      CrystalClick::BinarySimpleAggregateType::Function::AnyLast,
      named_tuple,
    )
    any_last.child_at(0).should eq(named_tuple)
    CrystalClick::BinaryDataTypeCodec.decode(
      CrystalClick::BinaryDataTypeCodec.encode(any_last),
    ).should eq(any_last)

    # TimeSeriesGroupArray returns its sole argument type verbatim; it does not
    # share the mapped functions' unnamed-result constraint.
    timeseries_tuple = CrystalClick::BinaryDataType.tuple(
      [
        CrystalClick::BinaryDataType.primitive("UInt32"),
        CrystalClick::BinaryDataType.primitive("Float64"),
      ] of CrystalClick::BinaryDataType,
      ["timestamp", "value"] of String,
    )
    timeseries_storage = CrystalClick::BinaryDataType.array(timeseries_tuple)
    timeseries = CrystalClick::BinaryDataType.simple_aggregate(
      CrystalClick::BinarySimpleAggregateType::Function::TimeSeriesGroupArray,
      timeseries_storage,
    )
    timeseries.child_at(0).should eq(timeseries_storage)
    timeseries_source = "SimpleAggregateFunction(timeSeriesGroupArray, #{timeseries_storage.name})"
    CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(timeseries_source).should eq(timeseries)
    CrystalClick::BinaryDataTypeCodec.decode(
      CrystalClick::BinaryDataTypeCodec.encode(timeseries),
    ).should eq(timeseries)
  end

  it "retains the exact positive parameter in the stock groupArrayLastArray declaration" do
    source = "SimpleAggregateFunction(groupArrayLastArray(5), Array(UInt64))"
    parsed = CrystalClick::SimpleAggregateBulkColumnDeclaration.parse(source)

    parsed.should_not be_nil
    if type = parsed
      type.name.should eq(source)
      type.child_at(0).name.should eq("Array(UInt64)")

      encoded = CrystalClick::BinaryDataTypeCodec.encode(type)
      decoded = CrystalClick::BinaryDataTypeCodec.decode(encoded)
      decoded.should eq(type)
      decoded.name.should eq(source)
    end

    exact_parameter_limits = CrystalClick::BinaryCodecLimits.new(
      max_depth: 3,
      max_nodes: 4,
      max_elements: 3,
      max_bytes: 1024,
    )
    CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(
      source,
      exact_parameter_limits,
    ).should_not be_nil

    no_parameter_node = CrystalClick::BinaryCodecLimits.new(
      max_depth: 3,
      max_nodes: 3,
      max_elements: 3,
      max_bytes: 1024,
    )
    no_parameter_edge = CrystalClick::BinaryCodecLimits.new(
      max_depth: 3,
      max_nodes: 4,
      max_elements: 2,
      max_bytes: 1024,
    )
    CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(source, no_parameter_node).should be_nil
    CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(source, no_parameter_edge).should be_nil
  end

  it "keeps existing scalar admission as a positive control and rejects malformed or unproved forms" do
    scalar_name = "SimpleAggregateFunction(min, UInt64)"
    scalar = CrystalClick::BinarySimpleAggregateType.parse(scalar_name)
    scalar.should_not be_nil
    if descriptor = scalar
      descriptor.type_name.should eq(scalar_name)
    end
    built_scalar = CrystalClick::BinaryDataType.simple_aggregate(
      CrystalClick::BinarySimpleAggregateType::Function::Min,
      CrystalClick::BinaryDataType.primitive("UInt64"),
    )
    CrystalClick::BinaryDataTypeCodec.decode(
      CrystalClick::BinaryDataTypeCodec.encode(built_scalar),
    ).should eq(built_scalar)

    rejected = [
      # Case-altered spellings are not silently normalized by this profile.
      "SimpleAggregateFunction(ANYLAST, Array(Int16))",
      # The array-returning factory does not have the scalar storage result.
      "SimpleAggregateFunction(groupArrayArray, UInt64)",
      # Wrong arity or malformed/unbounded parameter text.
      "SimpleAggregateFunction(groupArrayArray, Array(Int32), UInt8)",
      "SimpleAggregateFunction(groupArrayLastArray(), Array(UInt64))",
      "SimpleAggregateFunction(groupArrayLastArray(5, 6), Array(UInt64))",
      "SimpleAggregateFunction(groupArrayLastArray(18446744073709551616), Array(UInt64))",
      "SimpleAggregateFunction(groupArrayLastArray(05), Array(UInt64))",
      # Unbalanced child and repeated Nullable must fail closed.
      "SimpleAggregateFunction(sumMap, Tuple(Array(Int32), Array(Int64))",
      "SimpleAggregateFunction(anyLast, Nullable(Nullable(String)))",
      # Nullable placement remains nominal; outer plus inner is not admitted.
      "Nullable(SimpleAggregateFunction(anyLast, Nullable(String)))",
      # LC is stock-valid but stays behind its separate dictionary/replay owner.
      "SimpleAggregateFunction(anyLast, LowCardinality(Nullable(String)))",
    ]

    rejected.each do |source|
      CrystalClick::SimpleAggregateBulkColumnDeclaration.parse(source).should be_nil
    end

    expect_raises(ArgumentError) do
      repeated_nullable = CrystalClick::BinaryDataType.nullable(
        CrystalClick::BinaryDataType.nullable(CrystalClick::BinaryDataType.primitive("String")),
      )
      CrystalClick::BinaryDataType.simple_aggregate(
        CrystalClick::BinarySimpleAggregateType::Function::AnyLast,
        repeated_nullable,
      )
    end
  end

  it "enforces recursive descriptor depth before aggregate admission" do
    int16_type = CrystalClick::BinaryDataType.primitive("Int16")
    recursive_child = CrystalClick::BinaryDataType.array(
      CrystalClick::BinaryDataType.array(int16_type),
    )
    child_wire = CrystalClick::BinaryDataTypeCodec.encode(recursive_child)
    descriptor = w222_simple_aggregate_wire("anyLast", child_wire)
    tight_limits = CrystalClick::BinaryCodecLimits.new(
      max_depth: 2,
      max_nodes: 16,
      max_elements: 16,
      max_bytes: 1024,
    )

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(Bytes.new(descriptor.size) { |index| descriptor[index] }, tight_limits)
    end

    # The existing parser's byte limit remains an independent early guard.
    one_byte_limit = CrystalClick::BinaryCodecLimits.new(
      max_depth: 8,
      max_nodes: 16,
      max_elements: 16,
      max_bytes: 1,
    )
    CrystalClick::SimpleAggregateBulkColumnDeclaration.parse(
      "SimpleAggregateFunction(min, UInt64)",
      one_byte_limit,
    ).should be_nil
  end
end
