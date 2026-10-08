require "./spec_helper"

private W221_RESPECT_NULLS_FUNCTIONS = [
  "any_respect_nulls",
  "anyLast_respect_nulls",
]

private def w221_simple_aggregate_descriptor(
  function_name : String,
  leaf_tag : UInt8,
  nullable_child : Bool = false,
  nullable_aggregate : Bool = false,
) : Array(UInt8)
  bytes = [] of UInt8
  bytes << 0x23_u8 if nullable_aggregate
  bytes << 0x2e_u8 # SimpleAggregateFunction
  bytes << function_name.bytesize.to_u8
  bytes.concat(function_name.to_slice.to_a)
  bytes << 0_u8 # no Field parameters
  bytes << 1_u8 # one storage child
  bytes << 0x23_u8 if nullable_child
  bytes << leaf_tag
  bytes
end

private def w221_decode_type(descriptor : Array(UInt8)) : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataTypeCodec.decode(Bytes.new(descriptor.size) { |index| descriptor[index] })
end

private def w221_uint8(value : UInt8) : CrystalClick::BinaryValue
  type = CrystalClick::BinaryDataType.primitive("UInt8")
  CrystalClick::BinaryValue.fixed(type, Bytes[value])
end

describe "W221 SimpleAggregateFunction generic bulk composition" do
  it "preserves exact scalar, inner-Nullable, and legacy outer-Nullable identities" do
    W221_RESPECT_NULLS_FUNCTIONS.each do |function_name|
      scalar_descriptor = w221_simple_aggregate_descriptor(function_name, 0x01_u8)
      scalar = w221_decode_type(scalar_descriptor)
      scalar.name.should eq("SimpleAggregateFunction(#{function_name}, UInt8)")
      CrystalClick::BinaryDataTypeCodec.encode(scalar).to_a.should eq(scalar_descriptor)

      inner_descriptor = w221_simple_aggregate_descriptor(
        function_name,
        0x01_u8,
        nullable_child: true
      )
      inner = w221_decode_type(inner_descriptor)
      inner.name.should eq("SimpleAggregateFunction(#{function_name}, Nullable(UInt8))")
      inner.tag.should eq(CrystalClick::BinaryDataType::TAG_SIMPLE_AGGREGATE)
      inner.child_at(0).tag.should eq(CrystalClick::BinaryDataType::TAG_NULLABLE)
      inner.child_at(0).child_at(0).should eq(CrystalClick::BinaryDataType.primitive("UInt8"))
      CrystalClick::BinaryDataTypeCodec.encode(inner).to_a.should eq(inner_descriptor)

      parsed_inner = CrystalClick::BinarySimpleAggregateType.parse(inner.name).not_nil!
      parsed_inner.type_name.should eq(inner.name)
      parsed_inner.storage_type_name.should eq("Nullable(UInt8)")

      outer_descriptor = w221_simple_aggregate_descriptor(
        function_name,
        0x01_u8,
        nullable_aggregate: true
      )
      outer = w221_decode_type(outer_descriptor)
      outer.name.should eq("Nullable(SimpleAggregateFunction(#{function_name}, UInt8))")
      outer.tag.should eq(CrystalClick::BinaryDataType::TAG_NULLABLE)
      outer.child_at(0).should eq(scalar)
      CrystalClick::BinaryDataTypeCodec.encode(outer).to_a.should eq(outer_descriptor)

      inner.should_not eq(outer)
      CrystalClick::SimpleAggregateColumnType.parse(inner.name).should be_nil
      typed_outer = CrystalClick::SimpleAggregateColumnType.parse(outer.name).not_nil!
      typed_outer.nullable?.should be_true
      CrystalClick::WidePart.supports_typed_type?(inner.name).should be_false
      CrystalClick::WidePart.supports_typed_type?(outer.name).should be_true
    end
  end

  it "composes the existing BinaryBulk child codec for both nullable placements" do
    W221_RESPECT_NULLS_FUNCTIONS.each do |function_name|
      inner = w221_decode_type(
        w221_simple_aggregate_descriptor(function_name, 0x01_u8, nullable_child: true)
      )
      nullable_child_type = inner.child_at(0)
      inner_values = [
        [
          CrystalClick::BinaryValue.simple_aggregate(
            inner,
            CrystalClick::BinaryValue.nullable(nullable_child_type)
          ),
          CrystalClick::BinaryValue.simple_aggregate(
            inner,
            CrystalClick::BinaryValue.nullable(nullable_child_type, w221_uint8(0xa5_u8))
          ),
        ] of CrystalClick::BinaryValue,
      ]

      inner_streams = CrystalClick::BinaryBulkCodec.encode(inner, inner_values)
      inner_streams.roles.should eq(["root.nested.data", "root.nulls"])
      inner_streams.stream("root.nulls").bytes.should eq(Bytes[1_u8, 0_u8])
      inner_streams.stream("root.nested.data").bytes.should eq(Bytes[0_u8, 0xa5_u8])
      inner_physical = CrystalClick::BinaryBulkPhysicalPlan.new(inner, "v")
      inner_physical.stream_names.values.sort.should eq(["v", "v.null"])

      inner_read = CrystalClick::BinaryBulkCodec.decode(inner, inner_streams, [2_u64])[0]
      inner_read.size.should eq(2)
      inner_read.each { |value| value.type.should eq(inner) }
      inner_read[0].as_simple_aggregate.is_null?.should be_true
      inner_read[1].as_simple_aggregate.child_at(0).bytes.should eq(Bytes[0xa5_u8])

      scalar = w221_decode_type(w221_simple_aggregate_descriptor(function_name, 0x01_u8))
      outer = w221_decode_type(
        w221_simple_aggregate_descriptor(function_name, 0x01_u8, nullable_aggregate: true)
      )
      outer_values = [
        [
          CrystalClick::BinaryValue.nullable(outer),
          CrystalClick::BinaryValue.nullable(
            outer,
            CrystalClick::BinaryValue.simple_aggregate(scalar, w221_uint8(0x5a_u8))
          ),
        ] of CrystalClick::BinaryValue,
      ]

      outer_streams = CrystalClick::BinaryBulkCodec.encode(outer, outer_values)
      outer_streams.roles.should eq(["root.nested.data", "root.nulls"])
      outer_streams.stream("root.nulls").bytes.should eq(Bytes[1_u8, 0_u8])
      outer_streams.stream("root.nested.data").bytes.should eq(Bytes[0_u8, 0x5a_u8])
      outer_physical = CrystalClick::BinaryBulkPhysicalPlan.new(outer, "v")
      outer_physical.stream_names.values.sort.should eq(["v", "v.null"])

      outer_read = CrystalClick::BinaryBulkCodec.decode(outer, outer_streams, [2_u64])[0]
      outer_read.size.should eq(2)
      outer_read.each { |value| value.type.should eq(outer) }
      outer_read[0].is_null?.should be_true
      outer_read[1].child_at(0).as_simple_aggregate.bytes.should eq(Bytes[0x5a_u8])
    end
  end

  it "rejects outer Nullable around an already Nullable SAF child" do
    W221_RESPECT_NULLS_FUNCTIONS.each do |function_name|
      inner_descriptor = w221_simple_aggregate_descriptor(
        function_name,
        0x01_u8,
        nullable_child: true
      )
      inner = w221_decode_type(inner_descriptor)

      expect_raises(ArgumentError) do
        CrystalClick::BinaryDataType.nullable(inner)
      end

      double_nullable_descriptor = w221_simple_aggregate_descriptor(
        function_name,
        0x01_u8,
        nullable_child: true,
        nullable_aggregate: true
      )
      expect_raises(CrystalClick::CorruptPartError) do
        w221_decode_type(double_nullable_descriptor)
      end

      # The legacy Nested facade remains nominally guarded even though its
      # implementation delegates to the shared BinaryBulk engine.
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::NestedBulkColumnReader.open("/missing-w221-nested-part", "v", inner)
      end
    end
  end
end
