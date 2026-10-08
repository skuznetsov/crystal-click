require "./spec_helper"

private def w224a_u64(value : UInt64) : Bytes
  Bytes.new(8) { |index| ((value >> (8 * index)) & 0xff_u64).to_u8 }
end

describe "W224 recursive AggregateFunction adversarial controls" do
  it "keeps a real parent mark with no child occurrences distinct from an empty parent mark" do
    count = CrystalClick::BinaryDataType.aggregate_count
    inner = CrystalClick::BinaryDataType.array(count)
    outer = CrystalClick::BinaryDataType.array(inner)
    empty_inner = CrystalClick::BinaryValue.array(inner, [] of CrystalClick::BinaryValue)
    empty_outer = CrystalClick::BinaryValue.array(outer, [] of CrystalClick::BinaryValue)
    outer_with_empty_child = CrystalClick::BinaryValue.array(outer, [empty_inner])
    populated_inner = CrystalClick::BinaryValue.array(inner, [
      CrystalClick::BinaryValue.aggregate_count_state(count, 128_u64),
    ])
    populated_outer = CrystalClick::BinaryValue.array(outer, [populated_inner])
    granules = [[populated_outer, empty_outer], [outer_with_empty_child, empty_outer], [populated_outer]]

    streams = CrystalClick::BinaryBulkCodec.encode(outer, granules)
    streams.stream("root.elements.elements.data").bytes.should eq(Bytes[0x80_u8, 1_u8, 0x80_u8, 1_u8])
    streams.stream("root.elements.elements.data").offsets.should eq([0_u64, 2_u64, 2_u64, 4_u64])
    streams.stream("root.elements.sizes").offsets.should eq([0_u64, 8_u64, 16_u64, 24_u64])
    streams.stream("root.sizes").offsets.should eq([0_u64, 16_u64, 32_u64, 40_u64])

    decoded = CrystalClick::BinaryBulkCodec.decode(outer, streams, [2_u64, 2_u64, 1_u64])
    decoded.map(&.size).should eq([2, 2, 1])
    decoded[1][0].element_count.should eq(1)
    decoded[1][0].element_at(0).element_count.should eq(0)
    decoded[1][1].element_count.should eq(0)
    decoded[2][0].element_at(0).element_at(0).count_state.should eq(128_u64)
  end

  it "treats Nullable aggregate arguments as leaf metadata and state presence, not child rows" do
    argument = CrystalClick::BinaryDataType.nullable(CrystalClick::BinaryDataType.primitive("UInt8"))
    state_type = CrystalClick::BinaryDataType.aggregate_function("sum", argument)
    array_type = CrystalClick::BinaryDataType.array(state_type)
    absent = CrystalClick::BinaryValue.aggregate_function_state(state_type, Bytes[0_u8])
    present = CrystalClick::BinaryValue.aggregate_function_state(state_type, Bytes[1_u8, 7_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8])
    row = CrystalClick::BinaryValue.array(array_type, [absent, present])

    state_type.child_count.should eq(0)
    state_type.contains_low_cardinality?.should be_false
    row.element_at(0).is_null?.should be_false
    streams = CrystalClick::BinaryBulkCodec.encode(array_type, [[row]])
    streams.roles.should eq(["root.elements.data", "root.sizes"])
    streams.stream("root.elements.data").bytes.should eq(Bytes[0_u8, 1_u8, 7_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8])
    restored = CrystalClick::BinaryBulkCodec.decode(array_type, streams, [1_u64]).first.first
    restored.element_at(0).aggregate_function_state_bytes.should eq(Bytes[0_u8])
    restored.element_at(1).aggregate_function_state_bytes.should eq(present.aggregate_function_state_bytes)
  end

  it "rejects nominal substitutions even when state payload widths agree" do
    argument = CrystalClick::BinaryDataType.primitive("UInt64")
    sum = CrystalClick::BinaryDataType.aggregate_function("sum", argument)
    overflow = CrystalClick::BinaryDataType.aggregate_function("sumWithOverflow", argument)
    array_type = CrystalClick::BinaryDataType.array(sum)
    wrong_state = CrystalClick::BinaryValue.aggregate_function_state(overflow, w224a_u64(7_u64))
    expect_raises(ArgumentError) { CrystalClick::BinaryValue.array(array_type, [wrong_state]) }

    state = CrystalClick::BinaryValue.aggregate_function_state(sum, w224a_u64(7_u64))
    expect_raises(ArgumentError) { state.count_state }
    array_type.should_not eq(CrystalClick::BinaryDataType.array(overflow))
  end

  it "keeps aggregate state ownership after recursive container construction" do
    type = CrystalClick::BinaryDataType.aggregate_function("sumKahan", CrystalClick::BinaryDataType.primitive("Float64"))
    array_type = CrystalClick::BinaryDataType.array(type)
    raw = Bytes.new(16, 0_u8)
    raw[7] = 0x80_u8
    state = CrystalClick::BinaryValue.aggregate_function_state(type, raw)
    children = [state]
    row = CrystalClick::BinaryValue.array(array_type, children)
    raw.fill(0xff_u8)
    children.clear
    detached = row.element_at(0).aggregate_function_state_bytes
    detached.fill(0xff_u8)

    row.element_count.should eq(1)
    restored = CrystalClick::BinaryValueCodec.decode(CrystalClick::BinaryValueCodec.encode(row))
    restored.element_at(0).aggregate_function_state_bytes.should eq(Bytes.new(16) { |index| index == 7 ? 0x80_u8 : 0_u8 })
  end
end
