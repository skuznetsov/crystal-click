require "./spec_helper"

private def w224_core_join(parts : Array(Bytes)) : Bytes
  size = 0
  parts.each { |part| size += part.size }

  result = Bytes.new(size)
  offset = 0
  parts.each do |part|
    part.size.times do |index|
      result[offset + index] = part[index]
    end
    offset += part.size
  end
  result
end

describe "W224 recursive AggregateFunction core" do
  it "keeps Count and Sum metadata nominal while composing them under Tuple" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    float32 = CrystalClick::BinaryDataType.primitive("Float32")
    count_argument = CrystalClick::BinaryDataType.nullable(uint8)
    count = CrystalClick::BinaryDataType.aggregate_function("count", count_argument)
    sum = CrystalClick::BinaryDataType.aggregate_function("sumWithOverflow", float32)
    type = CrystalClick::BinaryDataType.tuple(
      [count, sum] of CrystalClick::BinaryDataType,
      ["rows", "total"] of String,
    )

    count.should eq(CrystalClick::BinaryDataType.aggregate_count(count_argument))
    type.name.should eq("Tuple(rows AggregateFunction(count, Nullable(UInt8)), total AggregateFunction(sumWithOverflow, Float32))")
    type.child_count.should eq(2)
    count.child_count.should eq(0)
    sum.child_count.should eq(0)
    count.aggregate_count_argument_type.should eq(count_argument)
    count.aggregate_function_argument_type.should eq(count_argument)
    sum.aggregate_function_argument_type.should eq(float32)
    type.contains_aggregate_count?.should be_true
    type.contains_aggregate_function?.should be_true

    descriptor = CrystalClick::BinaryDataTypeCodec.encode(type)
    CrystalClick::BinaryDataTypeCodec.decode(descriptor).should eq(type)
    CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(type.name).should eq(type)

    count_value = CrystalClick::BinaryValue.aggregate_count_state(count, 128_u64)
    sum_bytes = Bytes[0x00_u8, 0x00_u8, 0x80_u8, 0x3f_u8]
    sum_value = CrystalClick::BinaryValue.aggregate_function_state(sum, sum_bytes)
    value = CrystalClick::BinaryValue.tuple(
      type,
      [count_value, sum_value] of CrystalClick::BinaryValue,
    )
    restored = CrystalClick::BinaryValueCodec.decode(CrystalClick::BinaryValueCodec.encode(value))

    restored.type.should eq(type)
    restored.child_at(0).type.should eq(count)
    restored.child_at(0).count_state.should eq(128_u64)
    restored.child_at(1).type.should eq(sum)
    restored.child_at(1).aggregate_function_state_bytes.should eq(sum_bytes)
  end

  it "charges nested AggregateFunction argument metadata to shared descriptor depth and node budgets" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    count = CrystalClick::BinaryDataType.aggregate_count
    sum = CrystalClick::BinaryDataType.aggregate_function("sum", uint8)
    tuple = CrystalClick::BinaryDataType.tuple(
      [count, sum] of CrystalClick::BinaryDataType,
    )
    type = CrystalClick::BinaryDataType.array(tuple)
    wire = CrystalClick::BinaryDataTypeCodec.encode(type)
    exact = CrystalClick::BinaryCodecLimits.new(
      max_depth: 4,
      max_nodes: 5,
      max_elements: 4,
      max_bytes: wire.size,
    )

    CrystalClick::BinaryDataTypeCodec.encode(type, exact).should eq(wire)
    CrystalClick::BinaryDataTypeCodec.decode(wire, exact).should eq(type)

    shallow = CrystalClick::BinaryCodecLimits.new(3, 5, 4, wire.size)
    few_nodes = CrystalClick::BinaryCodecLimits.new(4, 4, 4, wire.size)
    [shallow, few_nodes].each do |limits|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryDataTypeCodec.encode(type, limits)
      end
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryDataTypeCodec.decode(wire, limits)
      end
    end
  end

  it "keeps Map keys, direct Nullable, and LowCardinality state envelopes excluded" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    count = CrystalClick::BinaryDataType.aggregate_count
    sum = CrystalClick::BinaryDataType.aggregate_function("sum", uint8)

    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.map(count, uint8) }
    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.nullable(sum) }
    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.low_cardinality(count) }

    count_wire = CrystalClick::BinaryDataTypeCodec.encode(count)
    uint8_wire = CrystalClick::BinaryDataTypeCodec.encode(uint8)
    sum_wire = CrystalClick::BinaryDataTypeCodec.encode(sum)
    invalid_map_key = w224_core_join([Bytes[CrystalClick::BinaryDataType::TAG_MAP], count_wire, uint8_wire])
    invalid_nullable = w224_core_join([Bytes[CrystalClick::BinaryDataType::TAG_NULLABLE], sum_wire])
    invalid_low_cardinality = w224_core_join([Bytes[CrystalClick::BinaryDataType::TAG_LOW_CARDINALITY], count_wire])

    [invalid_map_key, invalid_nullable, invalid_low_cardinality].each do |wire|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryDataTypeCodec.decode(wire)
      end
    end

    map_value_type = CrystalClick::BinaryDataType.map(uint8, count)
    CrystalClick::BinaryDataTypeCodec.decode(CrystalClick::BinaryDataTypeCodec.encode(map_value_type)).should eq(map_value_type)
  end

  it "does not reject a static AggregateFunction branch because a sibling is LowCardinality" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    count = CrystalClick::BinaryDataType.aggregate_count
    low_cardinality = CrystalClick::BinaryDataType.low_cardinality(uint8)
    type = CrystalClick::BinaryDataType.tuple(
      [count, low_cardinality] of CrystalClick::BinaryDataType,
    )

    CrystalClick::BinaryDataTypeCodec.decode(CrystalClick::BinaryDataTypeCodec.encode(type)).should eq(type)
    value = CrystalClick::BinaryValue.tuple(
      type,
      [
        CrystalClick::BinaryValue.aggregate_count_state(count, 128_u64),
        CrystalClick::BinaryValue.low_cardinality(
          low_cardinality,
          CrystalClick::BinaryValue.fixed(uint8, Bytes[7_u8]),
        ),
      ] of CrystalClick::BinaryValue,
    )
    restored = CrystalClick::BinaryValueCodec.decode(CrystalClick::BinaryValueCodec.encode(value))

    restored.child_at(0).count_state.should eq(128_u64)
    restored.child_at(1).type.should eq(low_cardinality)
    restored.child_at(1).child_at(0).bytes.should eq(Bytes[7_u8])
  end

  it "composes Count and Sum through Map values, Nullable Tuple, and Nested" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    count = CrystalClick::BinaryDataType.aggregate_count
    sum = CrystalClick::BinaryDataType.aggregate_function("sumWithOverflow", uint8)
    fields = [count, sum] of CrystalClick::BinaryDataType
    names = ["rows", "total"] of String
    tuple_type = CrystalClick::BinaryDataType.tuple(fields, names)
    nullable_type = CrystalClick::BinaryDataType.nullable(tuple_type)
    map_type = CrystalClick::BinaryDataType.map(uint8, tuple_type)
    nested_type = CrystalClick::BinaryDataType.nested(fields, names)

    [nullable_type, map_type, nested_type].each do |type|
      CrystalClick::BinaryDataTypeCodec.decode(CrystalClick::BinaryDataTypeCodec.encode(type)).should eq(type)
    end

    record = CrystalClick::BinaryValue.tuple(
      tuple_type,
      [
        CrystalClick::BinaryValue.aggregate_count_state(count, 128_u64),
        CrystalClick::BinaryValue.aggregate_function_state(sum, Bytes[9_u8]),
      ] of CrystalClick::BinaryValue,
    )

    nullable_value = CrystalClick::BinaryValue.nullable(nullable_type, record)
    restored_nullable = CrystalClick::BinaryValueCodec.decode(CrystalClick::BinaryValueCodec.encode(nullable_value))
    restored_nullable.child_at(0).child_at(0).count_state.should eq(128_u64)
    restored_nullable.child_at(0).child_at(1).aggregate_function_state_bytes.should eq(Bytes[9_u8])

    map_value = CrystalClick::BinaryValue.map(
      map_type,
      [CrystalClick::BinaryValue.fixed(uint8, Bytes[7_u8]), record] of CrystalClick::BinaryValue,
    )
    restored_map = CrystalClick::BinaryValueCodec.decode(CrystalClick::BinaryValueCodec.encode(map_value))
    restored_map.child_at(1).child_at(0).count_state.should eq(128_u64)
    restored_map.child_at(1).child_at(1).aggregate_function_state_bytes.should eq(Bytes[9_u8])

    nested_value = CrystalClick::BinaryValue.nested(nested_type, [record] of CrystalClick::BinaryValue)
    restored_nested = CrystalClick::BinaryValueCodec.decode(CrystalClick::BinaryValueCodec.encode(nested_value))
    restored_nested.element_at(0).child_at(0).count_state.should eq(128_u64)
    restored_nested.element_at(0).child_at(1).aggregate_function_state_bytes.should eq(Bytes[9_u8])
  end
end
