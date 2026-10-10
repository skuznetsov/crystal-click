require "./spec_helper"

describe "W255 root adversary" do
  it "writes all-ones AND defaults beneath a NULL Tuple rather than scalar zero" do
    state_type = CrystalClick::BinaryDataType.aggregate_function(
      "groupBitAnd", CrystalClick::BinaryDataType.primitive("Int128"),
    )
    tuple_type = CrystalClick::BinaryDataType.tuple([state_type] of CrystalClick::BinaryDataType)
    nullable_type = CrystalClick::BinaryDataType.nullable(tuple_type)
    rows = [[CrystalClick::BinaryValue.nullable(nullable_type)]] of Array(CrystalClick::BinaryValue)
    streams = CrystalClick::BinaryBulkCodec.encode(nullable_type, rows)
    streams.stream("root.nulls").bytes.should eq(Bytes[1_u8])
    streams.stream("root.nested.field.0.data").bytes.should eq(Bytes.new(16, 0xff_u8))
    CrystalClick::BinaryBulkCodec.decode(nullable_type, streams, [1_u64])[0][0].is_null?.should be_true
  end

  it "detaches input and getter bytes and refuses nominal same-width substitution" do
    argument = CrystalClick::BinaryDataType.primitive("UInt16")
    and_type = CrystalClick::BinaryDataType.aggregate_function("groupBitAnd", argument)
    or_type = CrystalClick::BinaryDataType.aggregate_function("groupBitOr", argument)
    input = Bytes[0x3c_u8, 0xa5_u8]
    state = CrystalClick::BinaryValue.aggregate_function_state(and_type, input)
    input[0] = 0_u8
    detached = state.aggregate_function_state_bytes
    detached[1] = 0_u8
    state.aggregate_function_state_bytes.should eq(Bytes[0x3c_u8, 0xa5_u8])

    tuple_type = CrystalClick::BinaryDataType.tuple([or_type] of CrystalClick::BinaryDataType)
    expect_raises(ArgumentError) do
      CrystalClick::BinaryValue.tuple(tuple_type, [state] of CrystalClick::BinaryValue)
    end
  end

  it "refuses fixed-width nominal aliases and aggregate-state Map keys" do
    ["IPv4", "IPv6", "UUID", "Date", "Date32", "BFloat16"].each do |name|
      argument = CrystalClick::BinaryDataType.primitive(name)
      expect_raises(ArgumentError) do
        CrystalClick::BinaryDataType.aggregate_function("groupBitXor", argument)
      end
    end
    state_type = CrystalClick::BinaryDataType.aggregate_function(
      "groupBitOr", CrystalClick::BinaryDataType.primitive("UInt8"),
    )
    value_type = CrystalClick::BinaryDataType.primitive("UInt8")
    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.map(state_type, value_type) }
  end
end
