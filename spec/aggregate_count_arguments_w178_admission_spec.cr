require "./spec_helper"

describe "W178 Count argument metadata admission" do
  cases = [
    {CrystalClick::BinaryDataType.primitive("UInt8"), "AggregateFunction(count, UInt8)", Bytes[0x01_u8]},
    {CrystalClick::BinaryDataType.primitive("String"), "AggregateFunction(count, String)", Bytes[0x15_u8]},
    {CrystalClick::BinaryDataType.nullable(CrystalClick::BinaryDataType.primitive("String")), "AggregateFunction(count, Nullable(String))", Bytes[0x23_u8, 0x15]},
    {CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.primitive("UInt64")), "AggregateFunction(count, Array(UInt64))", Bytes[0x1e_u8, 0x04]},
  ]

  cases.each do |argument, name, argument_bytes|
    it "admits #{name} without adding physical value children" do
      # The baseline factory's explicit out-of-profile refusal becomes an
      # assertion RED, rather than a compiler failure or uncaught exception.
      candidate = begin
        CrystalClick::BinaryDataType.aggregate_count(argument)
      rescue ArgumentError
        nil
      end
      candidate.should_not be_nil
      type = candidate.not_nil!
      type.name.should eq(name)
      type.child_count.should eq(0)
      type.aggregate_count_argument_type.should eq(argument)
      literal_io = IO::Memory.new
      literal_io.write(Bytes[0x25_u8, 0x00, 0x05, 0x63, 0x6f, 0x75, 0x6e, 0x74, 0x00, 0x01])
      literal_io.write(argument_bytes)
      literal = literal_io.to_slice
      CrystalClick::BinaryDataTypeCodec.encode(type).should eq(literal)
      CrystalClick::BinaryDataTypeCodec.decode(literal).should eq(type)
      value = CrystalClick::BinaryValue.aggregate_count_state(type, 128_u64)
      CrystalClick::BinaryValueCodec.encode_value(value).should eq(Bytes[0x80_u8, 0x01])
      decoded = CrystalClick::BinaryValueCodec.decode_value(type, Bytes[0x80_u8, 0x01])
      decoded.type.should eq(type)
      decoded.count_state.should eq(128_u64)
      plan = CrystalClick::WideAggregateCountStoragePlan.for_type_name(name)
      plan.should_not be_nil
      plan.not_nil!.data_type.should eq(type)
      plan.not_nil!.physical_streams("c").should eq(["c"])
    end
  end

  it "keeps all three legacy signatures admitted" do
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    [
      CrystalClick::BinaryDataType.aggregate_count,
      CrystalClick::BinaryDataType.aggregate_count(uint64),
      CrystalClick::BinaryDataType.aggregate_count(CrystalClick::BinaryDataType.nullable(uint64)),
    ].each do |type|
      value = CrystalClick::BinaryValue.aggregate_count_state(type, 128_u64)
      CrystalClick::BinaryValueCodec.encode_value(value).should eq(Bytes[0x80_u8, 0x01])
      CrystalClick::WideAggregateCountStoragePlan.require(type).data_type.should eq(type)
    end
  end
end
