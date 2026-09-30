require "./spec_helper"

describe CrystalClick::BoolValueCodec do
  it "decodes all byte values with zero-false and nonzero-true semantics" do
    bytes = Bytes.new(256) { |index| index.to_u8 }
    values = CrystalClick::BoolValueCodec.decode_values(bytes)

    values.size.should eq(256)
    bytes.each_with_index do |byte, index|
      expected = byte != 0_u8
      CrystalClick::BoolValueCodec.decode(byte).should eq(expected)
      values[index].should eq(expected)
      CrystalClick::BoolValueCodec.encode(expected).should eq(expected ? 1_u8 : 0_u8)
    end
  end

  it "returns an owned Bool array and emits only canonical bytes" do
    bytes = Bytes[0_u8, 2_u8, 255_u8]
    values = CrystalClick::BoolValueCodec.decode_values(bytes)
    3.times { |index| bytes[index] = 0_u8 }

    values.should eq([false, true, true])
    values[1] = false
    CrystalClick::BoolValueCodec.decode_values(Bytes[2_u8]).should eq([true])

    CrystalClick::BoolValueCodec.encode(false).should eq(0_u8)
    CrystalClick::BoolValueCodec.encode(true).should eq(1_u8)
  end
end
