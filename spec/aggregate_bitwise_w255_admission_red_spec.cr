require "./spec_helper"

describe "W255 AggregateFunction bitwise admission RED" do
  it "admits the literal groupBitOr UInt8 descriptor and fixed-width state" do
    # TAG_AGGREGATE_FUNCTION, version 0, groupBitOr, zero parameters, one UInt8
    # argument. This is intentionally an existing public decoder call: the
    # baseline must fail behaviorally on the unsupported function name.
    wire = Bytes[
      0x25_u8, 0x00, 0x0a,
      0x67, 0x72, 0x6f, 0x75, 0x70, 0x42, 0x69, 0x74, 0x4f, 0x72,
      0x00, 0x01, 0x01,
    ]
    candidate = begin
      CrystalClick::BinaryDataTypeCodec.decode(wire)
    rescue CrystalClick::UnsupportedFormatError
      nil
    end

    candidate.should_not be_nil
    if type = candidate
      type.name.should eq("AggregateFunction(groupBitOr, UInt8)")
      type.child_count.should eq(0)
      CrystalClick::BinaryDataTypeCodec.encode(type).should eq(wire)

      state = Bytes[0xff_u8]
      value = CrystalClick::BinaryValue.aggregate_function_state(type, state)
      restored = CrystalClick::BinaryValueCodec.decode_value(type, state)
      restored.type.should eq(type)
      restored.aggregate_function_state_bytes.should eq(state)
      CrystalClick::BinaryValueCodec.encode_value(value).should eq(state)
    end
  end

  it "keeps the specialized Count VarUInt state route unchanged" do
    wire = Bytes[
      0x25_u8, 0x00, 0x05, 0x63, 0x6f, 0x75, 0x6e, 0x74,
      0x00, 0x00,
    ]
    type = CrystalClick::BinaryDataTypeCodec.decode(wire)
    type.name.should eq("AggregateFunction(count)")
    type.aggregate_count_type.should_not be_nil

    state = Bytes[0x80_u8, 0x01_u8]
    value = CrystalClick::BinaryValueCodec.decode_value(type, state)
    value.count_state.should eq(128_u64)
    CrystalClick::BinaryValueCodec.encode_value(value).should eq(state)
  end
end
