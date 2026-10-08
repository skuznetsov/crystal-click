require "./spec_helper"

private def w225_variant_join(parts : Array(Bytes)) : Bytes
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

private def w225_variant_count_type : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.aggregate_count
end

private def w225_variant_sum_type : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.aggregate_function(
    "sumWithOverflow",
    CrystalClick::BinaryDataType.primitive("UInt8")
  )
end

private def w225_variant_direct_descriptor : Bytes
  count = Bytes[0x25_u8, 0x00_u8, 0x05_u8, 0x63_u8, 0x6f_u8, 0x75_u8, 0x6e_u8, 0x74_u8, 0x00_u8, 0x00_u8]
  sum = Bytes[
    0x25_u8, 0x00_u8, 0x0f_u8,
    0x73_u8, 0x75_u8, 0x6d_u8, 0x57_u8, 0x69_u8, 0x74_u8, 0x68_u8,
    0x4f_u8, 0x76_u8, 0x65_u8, 0x72_u8, 0x66_u8, 0x6c_u8, 0x6f_u8, 0x77_u8,
    0x00_u8, 0x01_u8, 0x01_u8,
  ]
  w225_variant_join([Bytes[0x2a_u8, 0x02_u8], count, sum] of Bytes)
end

private def w225_try_direct_variant : CrystalClick::BinaryDataType?
  count = w225_variant_count_type
  sum = w225_variant_sum_type
  begin
    # Deliberately reverse the order: normal construction must canonicalize
    # by complete display name after admitting AggregateFunction arms.
    CrystalClick::BinaryDataType.variant([sum, count] of CrystalClick::BinaryDataType)
  rescue ex : ArgumentError
    nil
  end
end

describe "W225 AggregateFunction Variant core" do
  it "admits a canonical Count/Sum roster and exact scalar state discriminators" do
    type = w225_try_direct_variant
    type.should_not be_nil
    if admitted = type
      count = w225_variant_count_type
      sum = w225_variant_sum_type
      admitted.children.map(&.name).should eq([
        "AggregateFunction(count)",
        "AggregateFunction(sumWithOverflow, UInt8)",
      ] of String)

      descriptor = w225_variant_direct_descriptor
      CrystalClick::BinaryDataTypeCodec.encode(admitted).should eq(descriptor)
      CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(admitted.name).should eq(admitted)

      count_value = CrystalClick::BinaryValue.variant(
        admitted,
        0,
        CrystalClick::BinaryValue.aggregate_count_state(count, 128_u64)
      )
      sum_value = CrystalClick::BinaryValue.variant(
        admitted,
        1,
        CrystalClick::BinaryValue.aggregate_function_state(sum, Bytes[0x2a_u8])
      )

      CrystalClick::BinaryValueCodec.encode_value(count_value).should eq(Bytes[0x00_u8, 0x80_u8, 0x01_u8])
      CrystalClick::BinaryValueCodec.encode_value(sum_value).should eq(Bytes[0x01_u8, 0x2a_u8])
      CrystalClick::BinaryValueCodec.decode_value(admitted, Bytes[0x00_u8, 0x80_u8, 0x01_u8])
        .variant_child?.not_nil!.count_state.should eq(128_u64)
      CrystalClick::BinaryValueCodec.decode_value(admitted, Bytes[0x01_u8, 0x2a_u8])
        .variant_child?.not_nil!.aggregate_function_state_bytes.should eq(Bytes[0x2a_u8])
      CrystalClick::BinaryValueCodec.encode(count_value).should eq(
        w225_variant_join([descriptor, Bytes[0x00_u8, 0x80_u8, 0x01_u8]] of Bytes)
      )
    end
  end

  it "decodes the independently literal canonical Variant descriptor with Count and Sum arms" do
    descriptor = w225_variant_direct_descriptor
    decoded = begin
      CrystalClick::BinaryDataTypeCodec.decode(descriptor)
    rescue ex : CrystalClick::CorruptPartError
      nil
    end
    decoded.should_not be_nil
    if admitted = decoded
      admitted.name.should eq("Variant(AggregateFunction(count), AggregateFunction(sumWithOverflow, UInt8))")
      CrystalClick::BinaryDataTypeCodec.encode(admitted).should eq(descriptor)
      CrystalClick::BinaryValueCodec.decode_value(admitted, Bytes[0x00_u8, 0x80_u8, 0x01_u8])
        .variant_child?.not_nil!.count_state.should eq(128_u64)
    end
  end

  it "keeps sparse bulk discriminator and Count/Sum lanes exact across empty marks" do
    count = w225_variant_count_type
    sum = w225_variant_sum_type
    unused = CrystalClick::BinaryDataType.primitive("UInt8")
    admitted = CrystalClick::BinaryDataType.variant([count, sum, unused] of CrystalClick::BinaryDataType)
    count = admitted.child_at(0)
    sum = admitted.child_at(1)
    rows = [
      [
        CrystalClick::BinaryValue.variant(admitted, 0, CrystalClick::BinaryValue.aggregate_count_state(count, 127_u64)),
        CrystalClick::BinaryValue.variant(admitted, 1, CrystalClick::BinaryValue.aggregate_function_state(sum, Bytes[0x2a_u8])),
      ] of CrystalClick::BinaryValue,
      [
        CrystalClick::BinaryValue.variant_null(admitted),
        CrystalClick::BinaryValue.variant_null(admitted),
      ] of CrystalClick::BinaryValue,
      [
        CrystalClick::BinaryValue.variant(admitted, 1, CrystalClick::BinaryValue.aggregate_function_state(sum, Bytes[0xfa_u8])),
        CrystalClick::BinaryValue.variant(admitted, 0, CrystalClick::BinaryValue.aggregate_count_state(count, 128_u64)),
      ] of CrystalClick::BinaryValue,
      [] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)

    streams = CrystalClick::BinaryBulkCodec.encode(admitted, rows)
    streams.roles.should eq([
      "root.arm.0.data",
      "root.arm.1.data",
      "root.arm.2.data",
      "root.discriminators",
    ] of String)
    streams.stream("root.discriminators").bytes.should eq(Bytes[0x00_u8, 0x01_u8, 0xff_u8, 0xff_u8, 0x01_u8, 0x00_u8])
    streams.stream("root.discriminators").offsets.should eq([0_u64, 2_u64, 4_u64, 6_u64, 6_u64])
    streams.stream("root.arm.0.data").bytes.should eq(Bytes[0x7f_u8, 0x80_u8, 0x01_u8])
    streams.stream("root.arm.0.data").offsets.should eq([0_u64, 1_u64, 1_u64, 3_u64, 3_u64])
    streams.stream("root.arm.1.data").bytes.should eq(Bytes[0x2a_u8, 0xfa_u8])
    streams.stream("root.arm.1.data").offsets.should eq([0_u64, 1_u64, 1_u64, 2_u64, 2_u64])
    streams.stream("root.arm.2.data").bytes.should be_empty
    streams.stream("root.arm.2.data").offsets.should eq([0_u64, 0_u64, 0_u64, 0_u64, 0_u64])

    decoded = CrystalClick::BinaryBulkCodec.decode(admitted, streams, [2_u64, 2_u64, 2_u64, 0_u64])
    decoded[0][0].variant_child?.not_nil!.count_state.should eq(127_u64)
    decoded[0][1].variant_child?.not_nil!.aggregate_function_state_bytes.should eq(Bytes[0x2a_u8])
    decoded[1][0].is_null?.should be_true
    decoded[1][1].is_null?.should be_true
    decoded[2][0].variant_child?.not_nil!.aggregate_function_state_bytes.should eq(Bytes[0xfa_u8])
    decoded[2][1].variant_child?.not_nil!.count_state.should eq(128_u64)
    decoded[3].should be_empty
  end

  it "keeps Count arguments as descriptor metadata and preserves their nominal state type" do
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    count = CrystalClick::BinaryDataType.aggregate_count(uint64)
    sum = w225_variant_sum_type
    type = CrystalClick::BinaryDataType.variant([sum, count] of CrystalClick::BinaryDataType)

    type.children.map(&.name).should eq([
      "AggregateFunction(count, UInt64)",
      "AggregateFunction(sumWithOverflow, UInt8)",
    ] of String)
    type.child_at(0).child_count.should eq(0)
    type.child_at(0).aggregate_count_argument_type.should eq(uint64)

    count_value = CrystalClick::BinaryValue.variant(
      type,
      0,
      CrystalClick::BinaryValue.aggregate_count_state(count, 128_u64)
    )
    decoded_type = CrystalClick::BinaryDataTypeCodec.decode(CrystalClick::BinaryDataTypeCodec.encode(type))
    decoded_type.child_at(0).aggregate_count_argument_type.should eq(uint64)
    decoded = CrystalClick::BinaryValueCodec.decode_value(type, Bytes[0x00_u8, 0x80_u8, 0x01_u8])
    decoded.variant_child?.not_nil!.type.should eq(count)
    decoded.variant_child?.not_nil!.count_state.should eq(128_u64)
    CrystalClick::BinaryValueCodec.encode_value(count_value).should eq(Bytes[0x00_u8, 0x80_u8, 0x01_u8])
  end

  it "admits only static AF-bearing paths while preserving direct-arm and envelope guards" do
    count = w225_variant_count_type
    sum = w225_variant_sum_type
    string = CrystalClick::BinaryDataType.primitive("String")
    low_cardinality_string = CrystalClick::BinaryDataType.low_cardinality(string)
    tuple = CrystalClick::BinaryDataType.tuple([count, sum] of CrystalClick::BinaryDataType)
    nullable_tuple = CrystalClick::BinaryDataType.nullable(tuple)
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    map_value = CrystalClick::BinaryDataType.map(uint8, count)
    nested = CrystalClick::BinaryDataType.nested([count, sum] of CrystalClick::BinaryDataType, ["count_state", "sum_state"] of String)
    plain_variant = CrystalClick::BinaryDataType.variant([string, uint8] of CrystalClick::BinaryDataType)
    wrapped = CrystalClick::BinaryDataType.variant([
      CrystalClick::BinaryDataType.array(nullable_tuple),
      low_cardinality_string,
      map_value,
      nested,
      CrystalClick::BinaryDataType.array(plain_variant),
    ] of CrystalClick::BinaryDataType)
    CrystalClick::BinaryAggregateFunctionRecursiveAdmission.admitted_static_tree?(wrapped).should be_true

    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.nullable(count) }
    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.low_cardinality(count) }
    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.map(count, string) }
    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.variant([nullable_tuple] of CrystalClick::BinaryDataType) }
    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.variant([CrystalClick::BinaryDataType.dynamic] of CrystalClick::BinaryDataType) }
    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.variant([CrystalClick::BinaryDataType.nullable(string)] of CrystalClick::BinaryDataType) }

    inner = CrystalClick::BinaryDataType.variant([string, CrystalClick::BinaryDataType.primitive("UInt8")] of CrystalClick::BinaryDataType)
    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.variant([inner, count] of CrystalClick::BinaryDataType) }
    qbit = CrystalClick::BinaryDataType.qbit(CrystalClick::QBitType.new("Int8", 2_u64))
    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.variant([count, qbit] of CrystalClick::BinaryDataType) }

    dynamic = CrystalClick::BinaryDataType.dynamic
    state = CrystalClick::BinaryValue.variant(
      CrystalClick::BinaryDataType.variant([count, sum] of CrystalClick::BinaryDataType),
      0,
      CrystalClick::BinaryValue.aggregate_count_state(count, 7_u64)
    )
    dynamic_value = CrystalClick::BinaryValue.dynamic(dynamic, state)
    dynamic_value.type.should eq(dynamic)
    dynamic_value.child_at(0).type.should eq(state.type)
    expect_raises(ArgumentError) { CrystalClick::DynamicStructure.new([state.type] of CrystalClick::BinaryDataType) }
    envelope = w225_variant_join([
      CrystalClick::BinaryDataTypeCodec.encode(state.type),
      CrystalClick::BinaryValueCodec.encode_value(state),
    ] of Bytes)
    decoded_dynamic_value = CrystalClick::BinaryValueCodec.decode_value(dynamic, envelope)
    decoded_dynamic_value.type.should eq(dynamic)
    decoded_dynamic_value.child_at(0).variant_child?.not_nil!.count_state.should eq(7_u64)
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.json(typed_paths: {"state" => state.type})
    end
  end

  it "keeps the wire roster strictly canonical after admitting static AF arms" do
    count = Bytes[0x25_u8, 0x00_u8, 0x05_u8, 0x63_u8, 0x6f_u8, 0x75_u8, 0x6e_u8, 0x74_u8, 0x00_u8, 0x00_u8]
    sum = Bytes[
      0x25_u8, 0x00_u8, 0x0f_u8,
      0x73_u8, 0x75_u8, 0x6d_u8, 0x57_u8, 0x69_u8, 0x74_u8, 0x68_u8,
      0x4f_u8, 0x76_u8, 0x65_u8, 0x72_u8, 0x66_u8, 0x6c_u8, 0x6f_u8, 0x77_u8,
      0x00_u8, 0x01_u8, 0x01_u8,
    ]
    unsorted = w225_variant_join([Bytes[0x2a_u8, 0x02_u8], sum, count] of Bytes)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(unsorted)
    end
  end

  it "rejects malformed selected Count/Sum payloads and trailing scalar bytes" do
    type = CrystalClick::BinaryDataTypeCodec.decode(w225_variant_direct_descriptor)

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode_value(type, Bytes[0x02_u8])
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode_value(type, Bytes[0x00_u8, 0x80_u8])
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode_value(type, Bytes[0x01_u8])
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode_value(type, Bytes[0x01_u8, 0x2a_u8, 0x00_u8])
    end
  end
end
