require "./spec_helper"

describe "W161 SimpleAggregateFunction descriptor admission RED" do
  # Literal source grammar: 0x2e, VarUInt String length + function bytes,
  # zero Field parameters, one argument, UInt64 descriptor tag 0x04.
  # All lengths here fit one VarUInt byte; no production encoder is an oracle.
  %w(any anyLast min max sum sumWithOverflow groupBitAnd groupBitOr groupBitXor).each do |function|
    it "admits the exact #{function}(UInt64) wire descriptor" do
      wire = Bytes.new(function.bytesize + 5)
      wire[0] = 0x2e_u8
      wire[1] = function.bytesize.to_u8
      function.to_slice.copy_to(wire[2, function.bytesize])
      wire[function.bytesize + 2] = 0_u8
      wire[function.bytesize + 3] = 1_u8
      wire[function.bytesize + 4] = 0x04_u8
      decoded = CrystalClick::BinaryDataTypeCodec.decode(wire)
      decoded.name.should eq("SimpleAggregateFunction(#{function}, UInt64)")
      CrystalClick::BinaryDataTypeCodec.encode(decoded).should eq(wire)
    end
  end

  it "keeps primitive UInt64 descriptor admission intact" do
    CrystalClick::BinaryDataTypeCodec.decode(Bytes[0x04_u8]).should eq(CrystalClick::BinaryDataType.primitive("UInt64"))
  end
end
