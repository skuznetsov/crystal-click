require "./spec_helper"

describe "W179 QBit binary kernel admission" do
  cases = [
    {"QBit(Int8, 3)", Bytes[0x36_u8, 0x07, 0x03], Bytes[0x03_u8, 0xff, 0x00, 0x80]},
    {"QBit(BFloat16, 3)", Bytes[0x36_u8, 0x31, 0x03], Bytes[0x03_u8, 0x80, 0x3f, 0x00, 0x80, 0xc1, 0x7f]},
    {"QBit(Float32, 3)", Bytes[0x36_u8, 0x0d, 0x03], Bytes[0x03_u8, 0x00, 0x00, 0x80, 0x3f, 0x00, 0x00, 0x00, 0x80, 0x01, 0x00, 0xc0, 0x7f]},
    {"QBit(Float64, 3)", Bytes[0x36_u8, 0x0e, 0x03], Bytes[0x03_u8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf0, 0x3f, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf8, 0x7f]},
    {"QBit(Int8, 16, 8)", Bytes[0x37_u8, 0x07, 0x10, 0x08], Bytes[0x10_u8, 0xff, 0x00, 0x80, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d]},
  ]

  cases.each do |name, descriptor, scalar|
    it "admits #{name} without treating it as Array or Tuple" do
      # Missing baseline descriptor admission is an assertion RED rather than
      # a missing-method compiler failure or an uncaught decode exception.
      candidate = begin
        CrystalClick::BinaryDataTypeCodec.decode(descriptor)
      rescue CrystalClick::CorruptPartError | CrystalClick::UnsupportedFormatError
        nil
      end
      candidate.should_not be_nil
      type = candidate.not_nil!
      type.name.should eq(name)
      CrystalClick::BinaryDataTypeCodec.encode(type).should eq(descriptor)
      value = CrystalClick::BinaryValueCodec.decode_value(type, scalar)
      value.type.should eq(type)
      CrystalClick::BinaryValueCodec.encode_value(value).should eq(scalar)
      envelope = IO::Memory.new
      envelope.write(descriptor)
      envelope.write(scalar)
      CrystalClick::BinaryValueCodec.encode(value).should eq(envelope.to_slice)
      CrystalClick::BinaryValueCodec.decode(envelope.to_slice).should eq(value)
    end
  end

  it "retains the existing UInt64 descriptor and scalar control" do
    type = CrystalClick::BinaryDataType.primitive("UInt64")
    CrystalClick::BinaryDataTypeCodec.decode(Bytes[0x04_u8]).should eq(type)
    scalar = Bytes[0x80_u8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
    value = CrystalClick::BinaryValueCodec.decode_value(type, scalar)
    CrystalClick::BinaryValueCodec.encode_value(value).should eq(scalar)
  end

  it "admits the exact static Array(QBit) descriptor and empty row envelope" do
    descriptor = Bytes[0x1e_u8, 0x36, 0x07, 0x03]
    type = CrystalClick::BinaryDataTypeCodec.decode(descriptor)
    type.name.should eq("Array(QBit(Int8, 3))")
    CrystalClick::BinaryDataTypeCodec.encode(type).should eq(descriptor)
  end

  it "round trips an empty Array(QBit) value without inventing a leaf row" do
    envelope = Bytes[0x1e_u8, 0x36, 0x07, 0x03, 0x00]
    value = CrystalClick::BinaryValueCodec.decode(envelope)
    value.type.name.should eq("Array(QBit(Int8, 3))")
    value.element_count.should eq(0)
    CrystalClick::BinaryValueCodec.encode(value).should eq(envelope)
  end

  it "classifies an unqualified unnamed Tuple(QBit) wire descriptor" do
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.decode(Bytes[0x1f_u8, 0x01, 0x36, 0x07, 0x03])
    end
  end

  it "classifies a Tuple(QBit) envelope before reading its stored value" do
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.decode(Bytes[0x1f_u8, 0x01, 0x36, 0x07, 0x03, 0x03, 1, 2, 3])
    end
  end
end
