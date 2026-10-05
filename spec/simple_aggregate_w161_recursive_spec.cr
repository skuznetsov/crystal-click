require "./spec_helper"
require "./support/simple_aggregate_w161_types"

private def w161_sa_type(function : CrystalClick::BinarySimpleAggregateType::Function) : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.simple_aggregate(function)
end

private def w161_sa_value(type : CrystalClick::BinaryDataType, value : UInt64) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.simple_aggregate(type, CrystalClick::BinaryValue.uint64(value))
end

describe "W161 recursive generic SimpleAggregateFunction composition" do
  it "keeps the UInt64 lane through Array, Tuple, Map-value, and Nullable bulk plans" do
    minimum = w161_sa_type(CrystalClick::BinarySimpleAggregateType::Function::Min)
    maximum = w161_sa_type(CrystalClick::BinarySimpleAggregateType::Function::Max)
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    array = CrystalClick::BinaryDataType.array(minimum)
    array_value = CrystalClick::BinaryValue.array(array, [
      w161_sa_value(minimum, 0x0123_4567_89ab_cdef_u64),
      w161_sa_value(minimum, UInt64::MAX),
    ] of CrystalClick::BinaryValue)
    array_bulk = CrystalClick::BinaryBulkCodec.encode(array, [[array_value] of CrystalClick::BinaryValue])
    array_bulk.roles.should eq(["root.elements.data", "root.sizes"] of String)
    array_bulk.stream("root.elements.data").bytes.to_a.should eq(
      W161SimpleAggregateTestSupport.u64_rows_le([0x0123_4567_89ab_cdef_u64, UInt64::MAX])
    )
    array_bulk.stream("root.sizes").bytes.should eq(Bytes[2_u8, 0, 0, 0, 0, 0, 0, 0])
    array_decoded = CrystalClick::BinaryBulkCodec.decode(array, array_bulk, [1_u64])
    array_decoded[0][0].child_at(0).as_simple_aggregate.as_uint64.should eq(0x0123_4567_89ab_cdef_u64)
    array_decoded[0][0].child_at(1).as_simple_aggregate.as_uint64.should eq(UInt64::MAX)
    CrystalClick::BinaryBulkPhysicalPlan.new(array, "sa").stream_names.should eq({
      "root.sizes"         => "sa.size0",
      "root.elements.data" => "sa",
    })

    nullable_max = CrystalClick::BinaryDataType.nullable(maximum)
    tuple = CrystalClick::BinaryDataType.tuple([minimum, nullable_max] of CrystalClick::BinaryDataType)
    tuple_value = CrystalClick::BinaryValue.tuple(tuple, [
      w161_sa_value(minimum, 0x8000_0000_0000_0000_u64),
      CrystalClick::BinaryValue.nullable(nullable_max),
    ] of CrystalClick::BinaryValue)
    tuple_bulk = CrystalClick::BinaryBulkCodec.encode(tuple, [[tuple_value] of CrystalClick::BinaryValue])
    tuple_bulk.roles.should eq([
      "root.field.0.data",
      "root.field.1.nested.data",
      "root.field.1.nulls",
    ] of String)
    tuple_bulk.stream("root.field.0.data").bytes.to_a.should eq(
      W161SimpleAggregateTestSupport.u64_le(0x8000_0000_0000_0000_u64)
    )
    tuple_bulk.stream("root.field.1.nulls").bytes.should eq(Bytes[1_u8])
    tuple_bulk.stream("root.field.1.nested.data").bytes.should eq(Bytes[0_u8, 0, 0, 0, 0, 0, 0, 0])
    tuple_decoded = CrystalClick::BinaryBulkCodec.decode(tuple, tuple_bulk, [1_u64])
    tuple_decoded[0][0].child_at(0).as_simple_aggregate.as_uint64.should eq(0x8000_0000_0000_0000_u64)
    tuple_decoded[0][0].child_at(1).is_null?.should be_true
    CrystalClick::BinaryBulkPhysicalPlan.new(tuple, "sa").stream_names.should eq({
      "root.field.0.data"        => "sa%2E1",
      "root.field.1.nulls"       => "sa%2E2.null",
      "root.field.1.nested.data" => "sa%2E2",
    })

    mapping = CrystalClick::BinaryDataType.map(CrystalClick::BinaryDataType.primitive("String"), minimum)
    mapping_value = CrystalClick::BinaryValue.map(mapping, [
      CrystalClick::BinaryValue.string("k"),
      w161_sa_value(minimum, UInt64::MAX),
    ] of CrystalClick::BinaryValue)
    map_bulk = CrystalClick::BinaryBulkCodec.encode(mapping, [[mapping_value] of CrystalClick::BinaryValue])
    map_bulk.roles.should eq([
      "root.elements.field.0.data",
      "root.elements.field.1.data",
      "root.sizes",
    ] of String)
    map_bulk.stream("root.elements.field.0.data").bytes.should eq(Bytes[1_u8, 0x6b_u8])
    map_bulk.stream("root.elements.field.1.data").bytes.to_a.should eq(
      W161SimpleAggregateTestSupport.u64_le(UInt64::MAX)
    )
    map_bulk.stream("root.sizes").bytes.should eq(Bytes[1_u8, 0, 0, 0, 0, 0, 0, 0])
    map_decoded = CrystalClick::BinaryBulkCodec.decode(mapping, map_bulk, [1_u64])
    map_decoded[0][0].child_at(1).as_simple_aggregate.as_uint64.should eq(UInt64::MAX)
    uint64.name.should eq("UInt64")
  end

  it "keeps min and max as distinct Variant arms and physical SQL names" do
    minimum = w161_sa_type(CrystalClick::BinarySimpleAggregateType::Function::Min)
    maximum = w161_sa_type(CrystalClick::BinarySimpleAggregateType::Function::Max)
    choice = CrystalClick::BinaryDataType.variant([minimum, maximum] of CrystalClick::BinaryDataType)
    choice.child_at(0).name.should eq("SimpleAggregateFunction(max, UInt64)")
    choice.child_at(1).name.should eq("SimpleAggregateFunction(min, UInt64)")

    value = CrystalClick::BinaryValue.variant(choice, 1, w161_sa_value(minimum, 0x8000_0000_0000_0000_u64))
    encoded = CrystalClick::BinaryBulkCodec.encode(choice, [[value] of CrystalClick::BinaryValue])
    encoded.roles.should eq([
      "root.arm.0.data",
      "root.arm.1.data",
      "root.discriminators",
    ] of String)
    encoded.stream("root.arm.0.data").bytes.should be_empty
    encoded.stream("root.arm.1.data").bytes.to_a.should eq(
      W161SimpleAggregateTestSupport.u64_le(0x8000_0000_0000_0000_u64)
    )
    encoded.stream("root.discriminators").bytes.should eq(Bytes[1_u8])

    decoded = CrystalClick::BinaryBulkCodec.decode(choice, encoded, [1_u64])
    decoded_value = decoded[0][0]
    decoded_value.variant_index?.should eq(1_u8)
    decoded_value.variant_child?.not_nil!.type.should eq(minimum)
    decoded_value.variant_child?.not_nil!.as_simple_aggregate.as_uint64.should eq(0x8000_0000_0000_0000_u64)

    physical = CrystalClick::BinaryBulkPhysicalPlan.new(choice, "sa")
    physical.stream_names.should eq({
      "root.discriminators" => "sa.variant_discr",
      "root.arm.0.data"     => "sa.SimpleAggregateFunction%28max%2C%20UInt64%29",
      "root.arm.1.data"     => "sa.SimpleAggregateFunction%28min%2C%20UInt64%29",
    })
  end

  it "keeps a selected SimpleAggregateFunction Dynamic arm transparent in bulk and physical plans" do
    minimum = w161_sa_type(CrystalClick::BinarySimpleAggregateType::Function::Min)
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    array = CrystalClick::BinaryDataType.array(dynamic)
    roster = CrystalClick::DynamicStructure.new([minimum] of CrystalClick::BinaryDataType)
    value = CrystalClick::BinaryValue.array(array, [
      CrystalClick::BinaryValue.dynamic(dynamic, w161_sa_value(minimum, 0x0123_4567_89ab_cdef_u64)),
    ] of CrystalClick::BinaryValue)

    encoded = CrystalClick::BinaryDynamicBulkCodec.encode(
      array,
      {"root.elements" => roster},
      [[value] of CrystalClick::BinaryValue]
    )
    encoded.structures.site_paths.should eq(["root.elements"] of String)
    encoded.data.roles.should eq([
      "root.elements.arm.0.data",
      "root.elements.arm.1.data",
      "root.elements.discriminators",
      "root.sizes",
    ] of String)
    encoded.data.stream("root.elements.arm.0.data").bytes.should be_empty
    encoded.data.stream("root.elements.arm.1.data").bytes.to_a.should eq(
      W161SimpleAggregateTestSupport.u64_le(0x0123_4567_89ab_cdef_u64)
    )
    encoded.data.stream("root.elements.discriminators").bytes.should eq(Bytes[1_u8])

    decoded = CrystalClick::BinaryDynamicBulkCodec.decode(array, encoded, [1_u64])
    selected = decoded[0][0].child_at(0).child_at(0)
    selected.type.should eq(minimum)
    selected.as_simple_aggregate.as_uint64.should eq(0x0123_4567_89ab_cdef_u64)

    prepared = CrystalClick::BinaryDynamicBulkPlan.new(array, {"root.elements" => roster})
    physical = CrystalClick::BinaryDynamicBulkPhysicalPlan.new(prepared, "d")
    physical.stream_names.should eq({
      "root.sizes"                      => "d.size0",
      "root.elements.discriminators"    => "d.variant_discr",
      "root.elements.arm.0.data"        => "d.SharedVariant",
      "root.elements.arm.1.data"        => "d.SimpleAggregateFunction%28min%2C%20UInt64%29",
      "root.elements.dynamic_structure" => "d.dynamic_structure",
    })
  end

  it "keeps LC(SAF) closed while legal UInt64 LC siblings still compose" do
    minimum = w161_sa_type(CrystalClick::BinarySimpleAggregateType::Function::Min)
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.low_cardinality(minimum) }

    low_uint64 = CrystalClick::BinaryDataType.low_cardinality(uint64)
    tuple = CrystalClick::BinaryDataType.tuple([low_uint64, minimum] of CrystalClick::BinaryDataType)
    value = CrystalClick::BinaryValue.tuple(tuple, [
      CrystalClick::BinaryValue.low_cardinality(low_uint64, CrystalClick::BinaryValue.uint64(7_u64)),
      w161_sa_value(minimum, UInt64::MAX),
    ] of CrystalClick::BinaryValue)
    encoded = CrystalClick::BinaryBulkCodec.encode(tuple, [[value] of CrystalClick::BinaryValue])
    encoded.roles.should contain("root.field.0.dictionary")
    encoded.roles.should contain("root.field.0.indexes")
    encoded.roles.should contain("root.field.1.data")

    decoded = CrystalClick::BinaryBulkCodec.decode(tuple, encoded, [1_u64])
    decoded[0][0].child_at(0).child_at(0).as_uint64.should eq(7_u64)
    decoded[0][0].child_at(1).as_simple_aggregate.as_uint64.should eq(UInt64::MAX)
  end
end
