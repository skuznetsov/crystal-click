require "./spec_helper"

describe "W152 nominal Dynamic descriptor behavioral RED" do
  it "decodes and exactly re-encodes the canonical default Dynamic descriptor" do
    descriptor = Bytes[0x2b_u8, 0x20_u8]
    type = CrystalClick::BinaryDataTypeCodec.decode(descriptor)

    type.name.should eq("Dynamic")
    CrystalClick::BinaryDataTypeCodec.encode(type).should eq(descriptor)
  end

  it "recurses through the existing Array descriptor policy for Dynamic" do
    descriptor = Bytes[0x1e_u8, 0x2b_u8, 0x20_u8]
    type = CrystalClick::BinaryDataTypeCodec.decode(descriptor)

    type.name.should eq("Array(Dynamic)")
    CrystalClick::BinaryDataTypeCodec.encode(type).should eq(descriptor)
  end
end
