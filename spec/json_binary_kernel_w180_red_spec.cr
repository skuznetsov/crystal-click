require "./spec_helper"

# These admission probes use only APIs that existed before W180. They must
# fail behaviorally on the clean baseline, not because a new API is missing.
describe "W180 JSON binary descriptor admission" do
  it "decodes the default nominal JSON v0 descriptor" do
    wire = Bytes[0x30_u8, 0x00, 0x80, 0x08, 0x20, 0x00, 0x00, 0x00]
    type = CrystalClick::BinaryDataTypeCodec.decode(wire)
    type.name.should eq("JSON")
    CrystalClick::BinaryDataTypeCodec.encode(type).should eq(wire)
  end

  it "decodes a typed-path descriptor without substituting a Tuple or Map" do
    # JSON(max_dynamic_paths=1, max_dynamic_types=1, n UInt8).
    wire = Bytes[0x30_u8, 0x00, 0x01, 0x01, 0x01, 0x01, 0x6e, 0x01, 0x00, 0x00]
    type = CrystalClick::BinaryDataTypeCodec.decode(wire)
    type.name.should eq("JSON(max_dynamic_types=1, max_dynamic_paths=1, n UInt8)")
    CrystalClick::BinaryDataTypeCodec.encode(type).should eq(wire)
  end
end
