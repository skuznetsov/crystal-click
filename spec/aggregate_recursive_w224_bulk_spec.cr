require "./spec_helper"

private def w224_bulk_u64(value : UInt64) : Bytes
  Bytes.new(8) { |index| ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w224_bulk_join(parts : Array(Bytes)) : Bytes
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

private def w224_bulk_record(
  type : CrystalClick::BinaryDataType,
  count_type : CrystalClick::BinaryDataType,
  sum_type : CrystalClick::BinaryDataType,
  count : UInt64,
  sum_bytes : Bytes,
) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.tuple(
    type,
    [
      CrystalClick::BinaryValue.aggregate_count_state(count_type, count),
      CrystalClick::BinaryValue.aggregate_function_state(sum_type, sum_bytes),
    ] of CrystalClick::BinaryValue,
  )
end

private def w224_bulk_malformed_streams(count_bytes : Bytes, sum_bytes : Bytes) : CrystalClick::BinaryBulkStreams
  streams = {
    "root.field.0.data" => CrystalClick::BinaryBulkStream.new(count_bytes, [0_u64, count_bytes.size.to_u64]),
    "root.field.1.data" => CrystalClick::BinaryBulkStream.new(sum_bytes, [0_u64, sum_bytes.size.to_u64]),
  } of String => CrystalClick::BinaryBulkStream
  CrystalClick::BinaryBulkStreams.new(1, streams)
end

describe "W224 recursive AggregateFunction bulk codec" do
  it "preserves nested Array schedules, zero-size rows, and exact Count/Sum leaf lanes" do
    float32 = CrystalClick::BinaryDataType.primitive("Float32")
    count_type = CrystalClick::BinaryDataType.aggregate_count
    sum_type = CrystalClick::BinaryDataType.aggregate_function("sumWithOverflow", float32)
    tuple_type = CrystalClick::BinaryDataType.tuple(
      [count_type, sum_type] of CrystalClick::BinaryDataType,
    )
    inner_array_type = CrystalClick::BinaryDataType.array(tuple_type)
    outer_array_type = CrystalClick::BinaryDataType.array(inner_array_type)

    sum_one = Bytes[0x00_u8, 0x00_u8, 0x80_u8, 0x3f_u8]
    sum_two = Bytes[0x00_u8, 0x00_u8, 0x00_u8, 0x40_u8]
    first = w224_bulk_record(tuple_type, count_type, sum_type, 127_u64, sum_one)
    second = w224_bulk_record(tuple_type, count_type, sum_type, 128_u64, sum_two)
    two_records = CrystalClick::BinaryValue.array(
      inner_array_type,
      [first, second] of CrystalClick::BinaryValue,
    )
    empty_inner = CrystalClick::BinaryValue.array(inner_array_type, [] of CrystalClick::BinaryValue)
    nonempty_outer = CrystalClick::BinaryValue.array(
      outer_array_type,
      [two_records, empty_inner] of CrystalClick::BinaryValue,
    )
    empty_outer = CrystalClick::BinaryValue.array(outer_array_type, [] of CrystalClick::BinaryValue)
    marks = [
      [nonempty_outer, empty_outer] of CrystalClick::BinaryValue,
      [] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)

    streams = CrystalClick::BinaryBulkCodec.encode(outer_array_type, marks)
    streams.mark_count.should eq(2)
    streams.roles.sort.should eq([
      "root.elements.elements.field.0.data",
      "root.elements.elements.field.1.data",
      "root.elements.sizes",
      "root.sizes",
    ])
    streams.stream("root.sizes").bytes.should eq(w224_bulk_join([w224_bulk_u64(2_u64), w224_bulk_u64(0_u64)]))
    streams.stream("root.sizes").offsets.should eq([0_u64, 16_u64, 16_u64])
    streams.stream("root.elements.sizes").bytes.should eq(w224_bulk_join([w224_bulk_u64(2_u64), w224_bulk_u64(0_u64)]))
    streams.stream("root.elements.sizes").offsets.should eq([0_u64, 16_u64, 16_u64])
    streams.stream("root.elements.elements.field.0.data").bytes.should eq(Bytes[0x7f_u8, 0x80_u8, 0x01_u8])
    streams.stream("root.elements.elements.field.0.data").offsets.should eq([0_u64, 3_u64, 3_u64])
    streams.stream("root.elements.elements.field.1.data").bytes.should eq(w224_bulk_join([sum_one, sum_two]))
    streams.stream("root.elements.elements.field.1.data").offsets.should eq([0_u64, 8_u64, 8_u64])

    restored = CrystalClick::BinaryBulkCodec.decode(outer_array_type, streams, [2_u64, 0_u64])
    restored[0].size.should eq(2)
    restored[0][0].element_count.should eq(2)
    restored[0][0].element_at(0).element_count.should eq(2)
    restored[0][0].element_at(0).element_at(0).child_at(0).count_state.should eq(127_u64)
    restored[0][0].element_at(0).element_at(1).child_at(0).count_state.should eq(128_u64)
    restored[0][0].element_at(0).element_at(0).child_at(1).aggregate_function_state_bytes.should eq(sum_one)
    restored[0][0].element_at(0).element_at(1).child_at(1).aggregate_function_state_bytes.should eq(sum_two)
    restored[0][0].element_at(1).element_count.should eq(0)
    restored[0][1].element_count.should eq(0)
    restored[1].size.should eq(0)
  end

  it "rejects truncated, malformed, and trailing recursive state-lane bytes" do
    float32 = CrystalClick::BinaryDataType.primitive("Float32")
    count_type = CrystalClick::BinaryDataType.aggregate_count
    sum_type = CrystalClick::BinaryDataType.aggregate_function("sumWithOverflow", float32)
    tuple_type = CrystalClick::BinaryDataType.tuple(
      [count_type, sum_type] of CrystalClick::BinaryDataType,
    )
    valid_sum = Bytes[0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8]

    [
      {Bytes[0x80_u8], valid_sum},                                          # unterminated Count VarUInt
      {Bytes[0x01_u8, 0x02_u8], valid_sum},                                 # trailing byte after one Count
      {Bytes[0x01_u8], Bytes[0x00_u8, 0x00_u8, 0x00_u8]},                   # truncated SumWithOverflow(Float32)
      {Bytes[0x01_u8], Bytes[0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0xff_u8]}, # trailing Sum byte
    ].each do |count_bytes, sum_bytes|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryBulkCodec.decode(
          tuple_type,
          w224_bulk_malformed_streams(count_bytes, sum_bytes),
          [1_u64],
        )
      end
    end
  end
end
