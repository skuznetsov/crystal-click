require "./spec_helper"

describe "W153 Dynamic logical-value behavioral RED" do
  it "decodes Dynamic NULL from the Nothing descriptor without a payload" do
    type = CrystalClick::BinaryDataType.dynamic(max_types: 17)
    value = CrystalClick::BinaryValueCodec.decode_value(type, Bytes[0x00_u8])

    value.type.should eq(type)
    value.type.dynamic_max_types.should eq(17_u8)
    value.is_null?.should be_true
    CrystalClick::BinaryValueCodec.encode_value(value).should eq(Bytes[0x00_u8])
  end

  it "decodes and re-encodes a Dynamic UInt64 typed envelope" do
    type = CrystalClick::BinaryDataType.dynamic(max_types: 17)
    # UInt64 descriptor 0x04 followed by the eight-byte little-endian payload 42.
    wire = Bytes[0x04_u8, 0x2a_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8]
    value = CrystalClick::BinaryValueCodec.decode_value(type, wire)

    value.type.should eq(type)
    value.type.dynamic_max_types.should eq(17_u8)
    value.is_null?.should be_false
    value.child_at(0).type.name.should eq("UInt64")
    value.child_at(0).as_uint64.should eq(42_u64)
    CrystalClick::BinaryValueCodec.encode_value(value).should eq(wire)
  end

  it "round-trips a complete Dynamic descriptor with its embedded String envelope" do
    # Dynamic(max_types=7), then String descriptor, one-byte length, and "x".
    wire = Bytes[0x2b_u8, 0x07_u8, 0x15_u8, 0x01_u8, 0x78_u8]
    value = CrystalClick::BinaryValueCodec.decode(wire)

    value.type.name.should eq("Dynamic(max_types=7)")
    value.type.dynamic_max_types.should eq(7_u8)
    value.child_at(0).type.name.should eq("String")
    value.child_at(0).as_string.should eq("x")
    CrystalClick::BinaryValueCodec.encode(value).should eq(wire)
  end
end
