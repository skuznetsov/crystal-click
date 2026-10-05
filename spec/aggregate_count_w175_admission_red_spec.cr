require "./spec_helper"

describe "W175 AggregateFunction(count) descriptor admission" do
  it "round-trips independently authored stock descriptor literals" do
    descriptors = [
      {"AggregateFunction(count)", Bytes[0x25_u8, 0x00, 0x05, 0x63, 0x6f, 0x75, 0x6e, 0x74, 0x00, 0x00]},
      {"AggregateFunction(count, UInt64)", Bytes[0x25_u8, 0x00, 0x05, 0x63, 0x6f, 0x75, 0x6e, 0x74, 0x00, 0x01, 0x04]},
      {"AggregateFunction(count, Nullable(UInt64))", Bytes[0x25_u8, 0x00, 0x05, 0x63, 0x6f, 0x75, 0x6e, 0x74, 0x00, 0x01, 0x23, 0x04]},
      {"AggregateFunction(count, UInt8)", Bytes[0x25_u8, 0x00, 0x05, 0x63, 0x6f, 0x75, 0x6e, 0x74, 0x00, 0x01, 0x01]},
    ]

    descriptors.each do |name, literal|
      decoded = begin
        CrystalClick::BinaryDataTypeCodec.decode(literal)
      rescue CrystalClick::UnsupportedFormatError
        nil
      end
      decoded.try(&.name).should eq(name)
      decoded = decoded.not_nil!
      CrystalClick::BinaryDataTypeCodec.encode(decoded).to_a.should eq(literal.to_a)
    end
  end

  it "retains the existing primitive UInt64 descriptor control" do
    literal = Bytes[0x04_u8]
    decoded = CrystalClick::BinaryDataTypeCodec.decode(literal)

    decoded.name.should eq("UInt64")
    CrystalClick::BinaryDataTypeCodec.encode(decoded).to_a.should eq(literal.to_a)
  end
end
