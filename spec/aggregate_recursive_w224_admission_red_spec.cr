require "./spec_helper"

private def w224_u64_bytes(value : UInt64) : Bytes
  Bytes.new(8) { |index| ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w224_bytes(parts : Array(Bytes)) : Bytes
  size = parts.sum(&.size)
  result = Bytes.new(size)
  offset = 0
  parts.each do |part|
    part.size.times { |index| result[offset + index] = part[index] }
    offset += part.size
  end
  result
end

private def w224_sum_state(type : CrystalClick::BinaryDataType, value : UInt64) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.aggregate_function_state(type, w224_u64_bytes(value))
end

describe "W224 recursive AggregateFunction admission RED" do
  it "admits the finite static Array, Tuple, Map, eligible Nullable, and Nested roster" do
    declarations = [
      "Array(AggregateFunction(sum, UInt8))",
      "Tuple(AggregateFunction(count), AggregateFunction(sumWithOverflow, Float32))",
      "Map(UInt8, AggregateFunction(count))",
      "Nullable(Tuple(AggregateFunction(count), AggregateFunction(sum, UInt8)))",
      "Nested(count AggregateFunction(count), total AggregateFunction(sum, UInt8))",
    ]

    declarations.each do |source|
      type = CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(source)
      type.should_not be_nil
      if admitted = type
        admitted.name.should eq(source)
        CrystalClick::BinaryDataTypeCodec.decode(
          CrystalClick::BinaryDataTypeCodec.encode(admitted)
        ).should eq(admitted)
        CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(admitted.name).should eq(admitted)
      end
    end
  end

  it "composes Sum leaf state lanes through uneven and empty Array rows" do
    type = CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(
      "Array(AggregateFunction(sum, UInt8))"
    )
    type.should_not be_nil
    if array_type = type
      sum_type = array_type.child_at(0)
      sum_type.child_count.should eq(0)
      sum_type.aggregate_function_type.not_nil!.argument_type.should eq(
        CrystalClick::BinaryDataType.primitive("UInt8")
      )

      states = (1_u64..5_u64).map { |value| w224_sum_state(sum_type, value) }
      rows = [
        CrystalClick::BinaryValue.array(array_type, [states[0], states[1]]),
        CrystalClick::BinaryValue.array(array_type, [] of CrystalClick::BinaryValue),
        CrystalClick::BinaryValue.array(array_type, [states[2], states[3], states[4]]),
      ]
      rows.each do |row|
        decoded = CrystalClick::BinaryValueCodec.decode(CrystalClick::BinaryValueCodec.encode(row))
        decoded.type.should eq(array_type)
        decoded.element_count.should eq(row.element_count)
        row.element_count.times do |index|
          decoded.element_at(index).aggregate_function_state_bytes.should eq(
            row.element_at(index).aggregate_function_state_bytes
          )
        end
      end

      streams = CrystalClick::BinaryBulkCodec.encode(array_type, [rows[0..1], [rows[2]]])
      streams.roles.should eq(["root.elements.data", "root.sizes"])
      streams.stream("root.sizes").bytes.should eq(
        w224_bytes([w224_u64_bytes(2_u64), w224_u64_bytes(0_u64), w224_u64_bytes(3_u64)])
      )
      streams.stream("root.elements.data").bytes.should eq(
        w224_bytes((1_u64..5_u64).map { |value| w224_u64_bytes(value) })
      )
      streams.stream("root.elements.data").offsets.should eq([0_u64, 16_u64, 40_u64])

      decoded = CrystalClick::BinaryBulkCodec.decode(array_type, streams, [2_u64, 1_u64])
      decoded[0][0].element_count.should eq(2)
      decoded[0][1].element_count.should eq(0)
      decoded[1][0].element_count.should eq(3)
      decoded[1][0].element_at(2).aggregate_function_state_bytes.should eq(w224_u64_bytes(5_u64))
    end
  end

  it "keeps Count's exact VarUInt leaf route beside a Sum-family Tuple leaf" do
    type = CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(
      "Tuple(AggregateFunction(count), AggregateFunction(sumWithOverflow, Float32))"
    )
    type.should_not be_nil
    if tuple_type = type
      count_type = tuple_type.child_at(0)
      overflow_type = tuple_type.child_at(1)
      count_type.aggregate_count_type.should_not be_nil
      overflow_type.aggregate_count_type.should be_nil

      value = CrystalClick::BinaryValue.tuple(
        tuple_type,
        [
          CrystalClick::BinaryValue.aggregate_count_state(count_type, 128_u64),
          CrystalClick::BinaryValue.aggregate_function_state(overflow_type, Bytes[0x2a_u8, 0_u8, 0_u8, 0_u8]),
        ]
      )
      decoded_value = CrystalClick::BinaryValueCodec.decode(CrystalClick::BinaryValueCodec.encode(value))
      decoded_value.child_at(0).count_state.should eq(128_u64)
      decoded_value.child_at(1).aggregate_function_state_bytes.should eq(Bytes[0x2a_u8, 0_u8, 0_u8, 0_u8])

      streams = CrystalClick::BinaryBulkCodec.encode(tuple_type, [[value]])
      streams.roles.should eq(["root.field.0.data", "root.field.1.data"])
      streams.stream("root.field.0.data").bytes.should eq(Bytes[0x80_u8, 0x01_u8])
      streams.stream("root.field.1.data").bytes.should eq(Bytes[0x2a_u8, 0_u8, 0_u8, 0_u8])
      decoded = CrystalClick::BinaryBulkCodec.decode(tuple_type, streams, [1_u64]).first.first
      decoded.child_at(0).count_state.should eq(128_u64)
      decoded.child_at(1).aggregate_function_state_bytes.should eq(Bytes[0x2a_u8, 0_u8, 0_u8, 0_u8])
    end
  end

  it "composes Count state through Map values with empty and populated rows" do
    type = CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(
      "Map(UInt8, AggregateFunction(count))"
    )
    type.should_not be_nil
    if map_type = type
      count_type = map_type.child_at(1)
      row = CrystalClick::BinaryValue.map(
        map_type,
        [
          CrystalClick::BinaryValue.fixed(CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[3_u8]),
          CrystalClick::BinaryValue.aggregate_count_state(count_type, 0_u64),
          CrystalClick::BinaryValue.fixed(CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[4_u8]),
          CrystalClick::BinaryValue.aggregate_count_state(count_type, 128_u64),
        ]
      )
      empty = CrystalClick::BinaryValue.map(map_type, [] of CrystalClick::BinaryValue)
      streams = CrystalClick::BinaryBulkCodec.encode(map_type, [[row, empty]])
      streams.roles.should eq([
        "root.elements.field.0.data",
        "root.elements.field.1.data",
        "root.sizes",
      ])
      streams.stream("root.sizes").bytes.should eq(
        w224_bytes([w224_u64_bytes(2_u64), w224_u64_bytes(0_u64)])
      )
      streams.stream("root.elements.field.0.data").bytes.should eq(Bytes[3_u8, 4_u8])
      streams.stream("root.elements.field.1.data").bytes.should eq(Bytes[0_u8, 0x80_u8, 0x01_u8])

      decoded = CrystalClick::BinaryBulkCodec.decode(map_type, streams, [2_u64]).first
      decoded[0].element_at(1).count_state.should eq(0_u64)
      decoded[0].element_at(3).count_state.should eq(128_u64)
      decoded[1].element_count.should eq(0)
    end
  end

  it "allows Nullable only around an eligible Tuple containing state leaves" do
    type = CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(
      "Nullable(Tuple(AggregateFunction(count), AggregateFunction(sum, UInt8)))"
    )
    type.should_not be_nil
    if nullable_type = type
      tuple_type = nullable_type.child_at(0)
      count_type = tuple_type.child_at(0)
      sum_type = tuple_type.child_at(1)
      tuple_value = CrystalClick::BinaryValue.tuple(
        tuple_type,
        [
          CrystalClick::BinaryValue.aggregate_count_state(count_type, 7_u64),
          w224_sum_state(sum_type, 9_u64),
        ]
      )
      values = [
        CrystalClick::BinaryValue.nullable(nullable_type),
        CrystalClick::BinaryValue.nullable(nullable_type, tuple_value),
      ]
      values.each do |value|
        decoded = CrystalClick::BinaryValueCodec.decode(CrystalClick::BinaryValueCodec.encode(value))
        decoded.type.should eq(nullable_type)
        decoded.is_null?.should eq(value.is_null?)
        unless decoded.is_null?
          decoded.child_at(0).child_at(0).count_state.should eq(7_u64)
          decoded.child_at(0).child_at(1).aggregate_function_state_bytes.should eq(w224_u64_bytes(9_u64))
        end
      end

      streams = CrystalClick::BinaryBulkCodec.encode(nullable_type, [values])
      streams.roles.should eq([
        "root.nested.field.0.data",
        "root.nested.field.1.data",
        "root.nulls",
      ])
      decoded = CrystalClick::BinaryBulkCodec.decode(nullable_type, streams, [2_u64]).first
      decoded[0].is_null?.should be_true
      decoded[1].is_null?.should be_false
      decoded[1].child_at(0).child_at(0).count_state.should eq(7_u64)
      decoded[1].child_at(0).child_at(1).aggregate_function_state_bytes.should eq(w224_u64_bytes(9_u64))
    end
  end

  it "composes Count and Sum leaves through the nominal Nested row domain" do
    type = CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(
      "Nested(count AggregateFunction(count), total AggregateFunction(sum, UInt8))"
    )
    type.should_not be_nil
    if nested_type = type
      tuple_type = nested_type.child_at(0)
      count_type = tuple_type.child_at(0)
      sum_type = tuple_type.child_at(1)
      rows = [
        CrystalClick::BinaryValue.tuple(
          tuple_type,
          [CrystalClick::BinaryValue.aggregate_count_state(count_type, 1_u64), w224_sum_state(sum_type, 10_u64)]
        ),
        CrystalClick::BinaryValue.tuple(
          tuple_type,
          [CrystalClick::BinaryValue.aggregate_count_state(count_type, 128_u64), w224_sum_state(sum_type, 11_u64)]
        ),
      ]
      value = CrystalClick::BinaryValue.nested(nested_type, rows)
      decoded_value = CrystalClick::BinaryValueCodec.decode(CrystalClick::BinaryValueCodec.encode(value))
      decoded_value.type.should eq(nested_type)
      decoded_value.element_at(1).child_at(0).count_state.should eq(128_u64)
      decoded_value.element_at(1).child_at(1).aggregate_function_state_bytes.should eq(w224_u64_bytes(11_u64))

      streams = CrystalClick::BinaryBulkCodec.encode(nested_type, [[value]])
      streams.roles.should eq([
        "root.elements.field.0.data",
        "root.elements.field.1.data",
        "root.sizes",
      ])
      decoded = CrystalClick::BinaryBulkCodec.decode(nested_type, streams, [1_u64]).first.first
      decoded.type.should eq(nested_type)
      decoded.element_count.should eq(2)
      decoded.element_at(1).child_at(0).count_state.should eq(128_u64)
      decoded.element_at(1).child_at(1).aggregate_function_state_bytes.should eq(w224_u64_bytes(11_u64))
    end
  end

  it "admits direct Sum state through Dynamic while keeping excluded wrappers closed" do
    [
      "Nullable(AggregateFunction(sum, UInt8))",
      "LowCardinality(AggregateFunction(sum, UInt8))",
      # W225 admits static Variant state arms, but direct Nullable is still
      # forbidden by Variant's source type law.
      "Variant(Nullable(AggregateFunction(sum, UInt8)), UInt8)",
    ].each do |source|
      CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(source).should be_nil
    end

    aggregate_type = CrystalClick::BinaryDataType.aggregate_function(
      "sum",
      CrystalClick::BinaryDataType.primitive("UInt8")
    )
    aggregate_value = w224_sum_state(aggregate_type, 1_u64)
    dynamic_value = CrystalClick::BinaryValue.dynamic(CrystalClick::BinaryDataType.dynamic, aggregate_value)
    dynamic_value.type.should eq(CrystalClick::BinaryDataType.dynamic)
    dynamic_value.child_at(0).type.should eq(aggregate_type)
    dynamic_value.child_at(0).aggregate_function_state_bytes.should eq(w224_u64_bytes(1_u64))
  end
end
