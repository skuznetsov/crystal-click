require "./spec_helper"

private def w223_bulk_u64_bytes(value : UInt64) : Bytes
  Bytes.new(8) { |index| ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w223_bulk_join(parts : Array(Bytes)) : Bytes
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

private def w223_bulk_state(
  type : CrystalClick::BinaryDataType,
  bytes : Bytes,
) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.aggregate_function_state(type, bytes)
end

describe "W223 AggregateFunction shared bulk codec" do
  it "roundtrips promoted state bytes and keeps Count's VarUInt lane distinct" do
    sum_type = CrystalClick::BinaryDataType.aggregate_function(
      "sum",
      CrystalClick::BinaryDataType.primitive("UInt8")
    )
    sum_values = [
      [w223_bulk_state(sum_type, w223_bulk_u64_bytes(0_u64)), w223_bulk_state(sum_type, w223_bulk_u64_bytes(128_u64))] of CrystalClick::BinaryValue,
      [w223_bulk_state(sum_type, w223_bulk_u64_bytes(UInt64::MAX))] of CrystalClick::BinaryValue,
    ]
    sum_streams = CrystalClick::BinaryBulkCodec.encode(sum_type, sum_values)
    sum_streams.roles.should eq(["root.data"])
    sum_streams.stream("root.data").offsets.should eq([0_u64, 16_u64, 24_u64])
    sum_streams.stream("root.data").bytes.should eq(
      w223_bulk_join([
        w223_bulk_u64_bytes(0_u64),
        w223_bulk_u64_bytes(128_u64),
        w223_bulk_u64_bytes(UInt64::MAX),
      ])
    )
    decoded_sum = CrystalClick::BinaryBulkCodec.decode(sum_type, sum_streams, [2_u64, 1_u64])
    decoded_sum.flatten.map(&.aggregate_function_state_bytes).should eq(
      [w223_bulk_u64_bytes(0_u64), w223_bulk_u64_bytes(128_u64), w223_bulk_u64_bytes(UInt64::MAX)]
    )

    count_type = CrystalClick::BinaryDataType.aggregate_count
    count_values = [
      [
        CrystalClick::BinaryValue.aggregate_count_state(count_type, 0_u64),
        CrystalClick::BinaryValue.aggregate_count_state(count_type, 128_u64),
      ] of CrystalClick::BinaryValue,
    ]
    count_streams = CrystalClick::BinaryBulkCodec.encode(count_type, count_values)
    count_streams.stream("root.data").bytes.should eq(Bytes[0_u8, 0x80_u8, 0x01_u8])
    CrystalClick::BinaryBulkCodec.decode(count_type, count_streams, [2_u64]).flatten.map(&.count_state).should eq([0_u64, 128_u64])
  end

  it "keeps Bool overflow and Kahan accumulator bytes opaque" do
    bool_type = CrystalClick::BinaryDataType.aggregate_function(
      "sumWithOverflow",
      CrystalClick::BinaryDataType.primitive("Bool")
    )
    bool_streams = CrystalClick::BinaryBulkCodec.encode(
      bool_type,
      [[w223_bulk_state(bool_type, Bytes[3_u8])] of CrystalClick::BinaryValue]
    )
    bool_streams.stream("root.data").bytes.should eq(Bytes[3_u8])
    bool_value = CrystalClick::BinaryBulkCodec.decode(bool_type, bool_streams, [1_u64]).first.first
    bool_value.aggregate_function_state_bytes.should eq(Bytes[3_u8])

    kahan_type = CrystalClick::BinaryDataType.aggregate_function(
      "sumKahan",
      CrystalClick::BinaryDataType.primitive("Float64")
    )
    kahan = Bytes[
      0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0xf8_u8, 0x7f_u8,
      0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x80_u8,
    ]
    kahan_streams = CrystalClick::BinaryBulkCodec.encode(
      kahan_type,
      [[w223_bulk_state(kahan_type, kahan)] of CrystalClick::BinaryValue]
    )
    kahan_streams.stream("root.data").bytes.should eq(kahan)
    CrystalClick::BinaryBulkCodec.decode(kahan_type, kahan_streams, [1_u64]).first.first.aggregate_function_state_bytes.should eq(kahan)
  end

  it "stores Nullable argument presence in the opaque state, not in the ordinary null lane" do
    argument = CrystalClick::BinaryDataType.nullable(
      CrystalClick::BinaryDataType.primitive("UInt64")
    )
    type = CrystalClick::BinaryDataType.aggregate_function("sum", argument)
    states = [
      Bytes[0_u8],
      Bytes[1_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8],
      Bytes[1_u8, 42_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8],
    ]
    values = states.map { |bytes| w223_bulk_state(type, bytes) }
    streams = CrystalClick::BinaryBulkCodec.encode(type, [values])
    streams.roles.should eq(["root.data"])
    streams.stream("root.data").bytes.should eq(w223_bulk_join([states[0], states[1], states[2]]))

    decoded = CrystalClick::BinaryBulkCodec.decode(type, streams, [3_u64]).first
    decoded.map(&.is_null?).should eq([false, false, false])
    decoded.map(&.type).should eq([type, type, type])
    decoded.map(&.aggregate_function_state_bytes).should eq(states)
    CrystalClick::BinaryBulkDefaultValue.build(type).aggregate_function_state_bytes.should eq(Bytes[0_u8])
  end

  it "rejects malformed presence, truncation, trailing bytes, and wrong state widths" do
    type = CrystalClick::BinaryDataType.aggregate_function(
      "sum",
      CrystalClick::BinaryDataType.nullable(CrystalClick::BinaryDataType.primitive("UInt8"))
    )
    [
      Bytes[2_u8],
      Bytes[1_u8],
      Bytes[0_u8, 0_u8],
    ].each do |lane|
      streams = CrystalClick::BinaryBulkStreams.new(1, {
        "root.data" => CrystalClick::BinaryBulkStream.new(lane, [0_u64, lane.size.to_u64]),
      })
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryBulkCodec.decode(type, streams, [1_u64])
      end
    end

    expect_raises(ArgumentError) do
      CrystalClick::BinaryValue.aggregate_function_state(type, Bytes[1_u8, 0_u8])
    end
  end

  it "refuses Sum declaration parse when any shared name or metadata budget is insufficient" do
    type = CrystalClick::BinaryDataType.aggregate_function(
      "sum",
      CrystalClick::BinaryDataType.primitive("UInt8")
    )
    declaration = type.name
    exact = CrystalClick::BinaryCodecLimits.new(max_depth: 2, max_nodes: 2, max_elements: 1, max_bytes: 128)
    CrystalClick::BinaryAggregateFunctionBulkColumnDeclaration.parse(declaration, exact).should eq(type)

    [
      CrystalClick::BinaryCodecLimits.new(max_depth: 1, max_nodes: 2, max_elements: 1, max_bytes: 128),
      CrystalClick::BinaryCodecLimits.new(max_depth: 2, max_nodes: 1, max_elements: 1, max_bytes: 128),
      CrystalClick::BinaryCodecLimits.new(max_depth: 2, max_nodes: 2, max_elements: 0, max_bytes: 128),
      CrystalClick::BinaryCodecLimits.new(max_depth: 2, max_nodes: 2, max_elements: 1, max_bytes: declaration.bytesize - 1),
    ].each do |limits|
      CrystalClick::BinaryAggregateFunctionBulkColumnDeclaration.parse(declaration, limits).should be_nil
    end
  end
end
