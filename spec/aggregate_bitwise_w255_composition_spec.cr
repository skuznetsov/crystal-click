require "./spec_helper"
require "./support/aggregate_bitwise_w255_values"

private def w255_comp_u8(type : CrystalClick::BinaryDataType, value : UInt8) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.fixed(type, Bytes[value])
end

private def w255_comp_u64_bytes(value : UInt64) : Bytes
  Bytes.new(8) { |index| ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w255_comp_join(parts : Array(Bytes)) : Bytes
  AggregateBitwiseW255Values.join(parts)
end

private def w255_assert_recursive_descriptor(type : CrystalClick::BinaryDataType) : Nil
  wire = CrystalClick::BinaryDataTypeCodec.encode(type)
  CrystalClick::BinaryDataTypeCodec.decode(wire).should eq(type)
  CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(type.name).should eq(type)
  CrystalClick::BinaryAggregateFunctionBulkColumnDeclaration.parse(type.name).should eq(type)
end

describe "W255 recursive AggregateFunction bitwise composition" do
  it "roundtrips ragged and empty Array(Tuple) rows with a sibling LowCardinality lane" do
    state_type = CrystalClick::BinaryDataType.aggregate_function(
      "groupBitAnd",
      CrystalClick::BinaryDataType.primitive("Int128"),
    )
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    low_cardinality = CrystalClick::BinaryDataType.low_cardinality(uint8)
    tuple_type = CrystalClick::BinaryDataType.tuple(
      [state_type, low_cardinality] of CrystalClick::BinaryDataType,
    )
    array_type = CrystalClick::BinaryDataType.array(tuple_type)

    first_state = AggregateBitwiseW255Values.state(state_type, 0x11_u8)
    second_state = AggregateBitwiseW255Values.state(state_type, 0x47_u8)
    third_state = AggregateBitwiseW255Values.state(state_type, 0x83_u8)
    tuple_one = CrystalClick::BinaryValue.tuple(
      tuple_type,
      [
        first_state,
        CrystalClick::BinaryValue.low_cardinality(low_cardinality, w255_comp_u8(uint8, 7_u8)),
      ] of CrystalClick::BinaryValue,
    )
    tuple_two = CrystalClick::BinaryValue.tuple(
      tuple_type,
      [
        second_state,
        CrystalClick::BinaryValue.low_cardinality(low_cardinality, w255_comp_u8(uint8, 9_u8)),
      ] of CrystalClick::BinaryValue,
    )
    tuple_three = CrystalClick::BinaryValue.tuple(
      tuple_type,
      [
        third_state,
        CrystalClick::BinaryValue.low_cardinality(low_cardinality, w255_comp_u8(uint8, 11_u8)),
      ] of CrystalClick::BinaryValue,
    )
    row_one = CrystalClick::BinaryValue.array(array_type, [tuple_one, tuple_two])
    row_empty = CrystalClick::BinaryValue.array(array_type, [] of CrystalClick::BinaryValue)
    row_three = CrystalClick::BinaryValue.array(array_type, [tuple_three])
    marks = [
      [row_one, row_empty] of CrystalClick::BinaryValue,
      [row_three] of CrystalClick::BinaryValue,
      [] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)

    w255_assert_recursive_descriptor(array_type)

    streams = CrystalClick::BinaryBulkCodec.encode(array_type, marks)
    streams.roles.should eq([
      "root.elements.field.0.data",
      "root.elements.field.1.dictionary",
      "root.elements.field.1.indexes",
      "root.sizes",
    ].sort)
    streams.stream("root.elements.field.0.data").bytes.should eq(
      w255_comp_join([
        first_state.aggregate_function_state_bytes,
        second_state.aggregate_function_state_bytes,
        third_state.aggregate_function_state_bytes,
      ] of Bytes)
    )
    streams.stream("root.sizes").bytes.should eq(
      w255_comp_join([w255_comp_u64_bytes(2_u64), w255_comp_u64_bytes(0_u64), w255_comp_u64_bytes(1_u64)] of Bytes)
    )
    # Offsets are mark boundaries plus the terminal position, not one entry
    # per parent row. The three marks contain 2, 1, and 0 parent rows.
    streams.stream("root.elements.field.0.data").offsets.should eq([0_u64, 32_u64, 48_u64, 48_u64])
    streams.stream("root.sizes").offsets.should eq([0_u64, 16_u64, 24_u64, 24_u64])

    decoded = CrystalClick::BinaryBulkCodec.decode(array_type, streams, [2_u64, 1_u64, 0_u64])
    decoded[0][0].element_count.should eq(2)
    decoded[0][0].element_at(0).child_at(0).aggregate_function_state_bytes.should eq(
      first_state.aggregate_function_state_bytes
    )
    decoded[0][0].element_at(1).child_at(0).aggregate_function_state_bytes.should eq(
      second_state.aggregate_function_state_bytes
    )
    decoded[0][0].element_at(0).child_at(1).child_at(0).bytes.should eq(Bytes[7_u8])
    decoded[0][1].element_count.should eq(0)
    decoded[1][0].element_at(0).child_at(0).aggregate_function_state_bytes.should eq(
      third_state.aggregate_function_state_bytes
    )
    decoded[2].should be_empty
  end

  it "preserves AggregateFunction states as Variant arms and Map values" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    variant_state = CrystalClick::BinaryDataType.aggregate_function(
      "groupBitXor",
      CrystalClick::BinaryDataType.primitive("UInt256"),
    )
    variant_type = CrystalClick::BinaryDataType.variant(
      [variant_state, uint8] of CrystalClick::BinaryDataType,
    )
    w255_assert_recursive_descriptor(variant_type)
    variant_index = variant_type.children.index(variant_state).not_nil!
    variant_state_value = AggregateBitwiseW255Values.state(variant_state, 0x25_u8)
    variant_value = CrystalClick::BinaryValue.variant(variant_type, variant_index, variant_state_value)
    variant_plain_value = CrystalClick::BinaryValue.variant(variant_type, 1 - variant_index, w255_comp_u8(uint8, 42_u8))
    variant_null = CrystalClick::BinaryValue.variant_null(variant_type)
    variant_streams = CrystalClick::BinaryBulkCodec.encode(
      variant_type,
      [[variant_value, variant_null], [variant_plain_value]] of Array(CrystalClick::BinaryValue),
    )
    variant_streams.stream("root.arm.#{variant_index}.data").bytes.should eq(
      variant_state_value.aggregate_function_state_bytes
    )
    variant_decoded = CrystalClick::BinaryBulkCodec.decode(variant_type, variant_streams, [2_u64, 1_u64])
    variant_decoded[0][0].variant_child?.not_nil!.aggregate_function_state_bytes.should eq(
      variant_state_value.aggregate_function_state_bytes
    )
    variant_decoded[0][1].is_null?.should be_true
    variant_decoded[1][0].variant_child?.not_nil!.bytes.should eq(Bytes[42_u8])

    map_state = CrystalClick::BinaryDataType.aggregate_function(
      "groupBitOr",
      CrystalClick::BinaryDataType.primitive("Int64"),
    )
    map_type = CrystalClick::BinaryDataType.map(uint8, map_state)
    w255_assert_recursive_descriptor(map_type)
    first_map_state = AggregateBitwiseW255Values.state(map_state, 0x39_u8)
    second_map_state = AggregateBitwiseW255Values.state(map_state, 0x71_u8)
    first_map = CrystalClick::BinaryValue.map(
      map_type,
      [w255_comp_u8(uint8, 3_u8), first_map_state, w255_comp_u8(uint8, 8_u8), second_map_state] of CrystalClick::BinaryValue,
    )
    empty_map = CrystalClick::BinaryValue.map(map_type, [] of CrystalClick::BinaryValue)
    map_streams = CrystalClick::BinaryBulkCodec.encode(map_type, [[first_map, empty_map]] of Array(CrystalClick::BinaryValue))
    map_streams.stream("root.sizes").bytes.should eq(
      w255_comp_join([w255_comp_u64_bytes(2_u64), w255_comp_u64_bytes(0_u64)] of Bytes)
    )
    map_decoded = CrystalClick::BinaryBulkCodec.decode(map_type, map_streams, [2_u64]).first
    map_decoded[0].child_at(1).aggregate_function_state_bytes.should eq(
      first_map_state.aggregate_function_state_bytes
    )
    map_decoded[0].child_at(3).aggregate_function_state_bytes.should eq(
      second_map_state.aggregate_function_state_bytes
    )
    map_decoded[1].element_count.should eq(0)
  end

  it "composes Nested and Nullable(Tuple) state rows without relaxing sibling guards" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    int256_state = CrystalClick::BinaryDataType.aggregate_function(
      "groupBitAnd",
      CrystalClick::BinaryDataType.primitive("Int256"),
    )
    nested_type = CrystalClick::BinaryDataType.nested(
      [int256_state, uint8] of CrystalClick::BinaryDataType,
      ["state", "tag"] of String,
    )
    w255_assert_recursive_descriptor(nested_type)
    nested_tuple_type = nested_type.child_at(0)
    nested_first = CrystalClick::BinaryValue.tuple(
      nested_tuple_type,
      [AggregateBitwiseW255Values.state(int256_state, 0x51_u8), w255_comp_u8(uint8, 5_u8)] of CrystalClick::BinaryValue,
    )
    nested_second = CrystalClick::BinaryValue.tuple(
      nested_tuple_type,
      [AggregateBitwiseW255Values.state(int256_state, 0x91_u8), w255_comp_u8(uint8, 6_u8)] of CrystalClick::BinaryValue,
    )
    nested_value = CrystalClick::BinaryValue.nested(nested_type, [nested_first, nested_second])
    nested_empty = CrystalClick::BinaryValue.nested(nested_type, [] of CrystalClick::BinaryValue)
    nested_streams = CrystalClick::BinaryBulkCodec.encode(nested_type, [[nested_value, nested_empty]] of Array(CrystalClick::BinaryValue))
    nested_streams.stream("root.sizes").bytes.should eq(
      w255_comp_join([w255_comp_u64_bytes(2_u64), w255_comp_u64_bytes(0_u64)] of Bytes)
    )
    nested_decoded = CrystalClick::BinaryBulkCodec.decode(nested_type, nested_streams, [2_u64]).first
    nested_decoded[0].element_at(1).child_at(0).aggregate_function_state_bytes.should eq(
      nested_second.child_at(0).aggregate_function_state_bytes
    )
    nested_decoded[1].element_count.should eq(0)

    int128_state = CrystalClick::BinaryDataType.aggregate_function(
      "groupBitXor",
      CrystalClick::BinaryDataType.primitive("UInt128"),
    )
    low_cardinality = CrystalClick::BinaryDataType.low_cardinality(uint8)
    inner_tuple_type = CrystalClick::BinaryDataType.tuple(
      [int128_state, low_cardinality] of CrystalClick::BinaryDataType,
    )
    nullable_tuple_type = CrystalClick::BinaryDataType.nullable(inner_tuple_type)
    w255_assert_recursive_descriptor(nullable_tuple_type)
    tuple_value = CrystalClick::BinaryValue.tuple(
      inner_tuple_type,
      [
        AggregateBitwiseW255Values.state(int128_state, 0x63_u8),
        CrystalClick::BinaryValue.low_cardinality(low_cardinality, w255_comp_u8(uint8, 77_u8)),
      ] of CrystalClick::BinaryValue,
    )
    nullable_values = [
      CrystalClick::BinaryValue.nullable(nullable_tuple_type),
      CrystalClick::BinaryValue.nullable(nullable_tuple_type, tuple_value),
    ] of CrystalClick::BinaryValue
    nullable_streams = CrystalClick::BinaryBulkCodec.encode(nullable_tuple_type, [nullable_values])
    nullable_decoded = CrystalClick::BinaryBulkCodec.decode(nullable_tuple_type, nullable_streams, [2_u64]).first
    nullable_decoded[0].is_null?.should be_true
    nullable_decoded[1].child_at(0).child_at(0).aggregate_function_state_bytes.should eq(
      tuple_value.child_at(0).aggregate_function_state_bytes
    )
    nullable_decoded[1].child_at(0).child_at(1).child_at(0).bytes.should eq(Bytes[77_u8])
  end

  it "keeps AggregateFunction recursive budgets bounded across the enclosing tree" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    state_type = CrystalClick::BinaryDataType.aggregate_function("groupBitOr", uint8)
    tuple_type = CrystalClick::BinaryDataType.tuple(
      [state_type, CrystalClick::BinaryDataType.low_cardinality(uint8)] of CrystalClick::BinaryDataType,
    )
    type = CrystalClick::BinaryDataType.array(tuple_type)
    wire = CrystalClick::BinaryDataTypeCodec.encode(type)
    ample = CrystalClick::BinaryCodecLimits.new(16, 16, 16, wire.size)
    # Recursive type-name budgeting includes temporary child/output copies;
    # the source-derived allocation bound for this tree is 588 bytes.
    ample_name = CrystalClick::BinaryCodecLimits.new(16, 16, 16, 588)
    CrystalClick::BinaryDataTypeCodec.encode(type, ample).should eq(wire)
    CrystalClick::BinaryDataTypeCodec.decode(wire, ample).should eq(type)
    CrystalClick::BinaryAggregateFunctionBulkColumnDeclaration.parse(type.name, ample_name).should eq(type)

    state = AggregateBitwiseW255Values.state(state_type, 0x33_u8)
    tuple_value = CrystalClick::BinaryValue.tuple(
      tuple_type,
      [
        state,
        CrystalClick::BinaryValue.low_cardinality(
          tuple_type.child_at(1),
          w255_comp_u8(uint8, 4_u8),
        ),
      ] of CrystalClick::BinaryValue,
    )
    rows = [[CrystalClick::BinaryValue.array(type, [tuple_value])]] of Array(CrystalClick::BinaryValue)
    streams = CrystalClick::BinaryBulkCodec.encode(type, rows)
    decoded = CrystalClick::BinaryBulkCodec.decode(type, streams, [1_u64])
    decoded[0][0].element_at(0).child_at(0).aggregate_function_state_bytes.should eq(
      state.aggregate_function_state_bytes
    )

    too_small = CrystalClick::BinaryCodecLimits.new(1, 1, 0, wire.size - 1)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.encode(type, too_small)
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(wire, too_small)
    end
    too_small_name_bytes = CrystalClick::BinaryCodecLimits.new(16, 16, 16, 587)
    CrystalClick::BinaryAggregateFunctionBulkColumnDeclaration.parse(type.name, too_small_name_bytes).should be_nil
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkCodec.encode(type, rows, too_small)
    end
  end
end
