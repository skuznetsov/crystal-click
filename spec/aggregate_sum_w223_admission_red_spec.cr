require "./spec_helper"

describe "W223 AggregateFunction sum-state admission" do
  it "admits sum metadata without treating its argument as a value child" do
    # The existing public decoder compiles on the Count-only baseline. Its
    # explicit rejection must become an assertion failure, not a compile RED.
    wire = Bytes[0x25_u8, 0x00, 0x03, 0x73, 0x75, 0x6d, 0x00, 0x01, 0x01]
    candidate = begin
      CrystalClick::BinaryDataTypeCodec.decode(wire)
    rescue CrystalClick::UnsupportedFormatError
      nil
    end
    candidate.should_not be_nil
    type = candidate.not_nil!
    type.name.should eq("AggregateFunction(sum, UInt8)")
    type.child_count.should eq(0)
    CrystalClick::BinaryDataTypeCodec.encode(type).should eq(wire)

    # CH sum(UInt8) owns a UInt64 accumulator; the argument width is not its
    # state width. Preserve the aggregate's nominal type on value readback.
    state = Bytes[0x01_u8, 0, 0, 0, 0, 0, 0, 0]
    value = CrystalClick::BinaryValueCodec.decode_value(type, state)
    value.type.should eq(type)
    CrystalClick::BinaryValueCodec.encode_value(value).should eq(state)
  end

  it "retains Count's distinct VarUInt state contract" do
    type = CrystalClick::BinaryDataType.aggregate_count
    value = CrystalClick::BinaryValue.aggregate_count_state(type, 128_u64)
    CrystalClick::BinaryValueCodec.encode_value(value).should eq(Bytes[0x80_u8, 0x01])
  end
end
