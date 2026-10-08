require "./spec_helper"

describe "W223 root aggregate-state counterexamples" do
  it "keeps same-width Sum out of Count nominal accessors and storage plans" do
    type = CrystalClick::BinaryDataType.aggregate_function("sum", CrystalClick::BinaryDataType.primitive("UInt8"))
    type.contains_aggregate_count?.should be_false
    type.aggregate_count_type.should be_nil
    CrystalClick::WideAggregateCountStoragePlan.for_type(type).should be_nil
    state = CrystalClick::BinaryValue.aggregate_function_state(type, Bytes[128_u8, 0, 0, 0, 0, 0, 0, 0])
    expect_raises(ArgumentError) { state.count_state }
    CrystalClick::BinaryValueCodec.encode_value(state).should eq(Bytes[128_u8, 0, 0, 0, 0, 0, 0, 0])
    count = CrystalClick::BinaryValue.aggregate_count_state(CrystalClick::BinaryDataType.aggregate_count, 128_u64)
    CrystalClick::BinaryValueCodec.encode_value(count).should eq(Bytes[128_u8, 1])
  end

  it "preserves raw accumulator bits instead of Bool or Enum value restrictions" do
    bool_type = CrystalClick::BinaryDataType.aggregate_function("sumWithOverflow", CrystalClick::BinaryDataType.primitive("Bool"))
    bool_state = CrystalClick::BinaryValue.aggregate_function_state(bool_type, Bytes[3_u8])
    CrystalClick::BinaryValueCodec.encode_value(bool_state).should eq(Bytes[3_u8])
    enum_arg = CrystalClick::BinaryDataType.enum8([{"one", 1_i16}, {"two", 2_i16}] of CrystalClick::BinaryEnumDefinition::Entry)
    enum_type = CrystalClick::BinaryDataType.aggregate_function("sumWithOverflow", enum_arg)
    enum_state = CrystalClick::BinaryValue.aggregate_function_state(enum_type, Bytes[3_u8])
    CrystalClick::BinaryValueCodec.encode_value(enum_state).should eq(Bytes[3_u8])
  end

  it "retains NaN payloads and the second Kahan word without numeric conversion" do
    type = CrystalClick::BinaryDataType.aggregate_function("sumKahan", CrystalClick::BinaryDataType.primitive("Float32"))
    raw = Bytes[0x42_u8, 0, 0, 0, 0, 0, 0xf8, 0x7f, 0x01, 0, 0, 0, 0, 0, 0, 0x80]
    value = CrystalClick::BinaryValueCodec.decode_value(type, raw)
    CrystalClick::BinaryValueCodec.encode_value(value).should eq(raw)
    value.aggregate_function_state_bytes.should eq(raw)
  end

  it "distinguishes aggregate presence from row nullability and rejects noncanonical flags" do
    arg = CrystalClick::BinaryDataType.nullable(CrystalClick::BinaryDataType.primitive("UInt8"))
    type = CrystalClick::BinaryDataType.aggregate_function("sum", arg)
    empty = CrystalClick::BinaryValue.aggregate_function_state(type, Bytes[0_u8])
    empty.is_null?.should be_false
    empty.child_count.should eq(0)
    CrystalClick::BinaryValueCodec.encode_value(empty).should eq(Bytes[0_u8])
    [Bytes[2_u8], Bytes[0_u8, 0], Bytes[1_u8], Bytes[1_u8, 0, 0, 0, 0, 0, 0, 0]].each do |raw|
      expect_raises(CrystalClick::CorruptPartError) { CrystalClick::BinaryValueCodec.decode_value(type, raw) }
    end
  end

  it "owns state bytes and returns detached payload copies" do
    type = CrystalClick::BinaryDataType.aggregate_function("sumWithOverflow", CrystalClick::BinaryDataType.primitive("UInt8"))
    raw = Bytes[7_u8]
    value = CrystalClick::BinaryValue.aggregate_function_state(type, raw)
    raw[0] = 99_u8
    copy = value.aggregate_function_state_bytes
    copy[0] = 88_u8
    CrystalClick::BinaryValueCodec.encode_value(value).should eq(Bytes[7_u8])
  end

  it "admits Sum through generic Dynamic while keeping borrowed and default helper closed" do
    type = CrystalClick::BinaryDataType.aggregate_function("sum", CrystalClick::BinaryDataType.primitive("UInt8"))
    value = CrystalClick::BinaryValue.aggregate_function_state(type, Bytes[1_u8, 0, 0, 0, 0, 0, 0, 0])
    limits = CrystalClick::BinaryCodecLimits.default
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode_borrowed(value, CrystalClick::BinaryCodecBudget.new(limits, true))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.decode_borrowed(CrystalClick::BinaryValueCodec.encode(value), CrystalClick::BinaryCodecBudget.new(limits))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode_dynamic_bulk_child(value, CrystalClick::BinaryCodecBudget.new(limits, true), 1)
    end
    dynamic_value = CrystalClick::BinaryValue.dynamic(CrystalClick::BinaryDataType.dynamic, value)
    dynamic_value.type.should eq(CrystalClick::BinaryDataType.dynamic)
    dynamic_value.child_at(0).type.should eq(type)
    dynamic_value.child_at(0).aggregate_function_state_bytes.should eq(Bytes[1_u8, 0, 0, 0, 0, 0, 0, 0])
  end

  it "charges argument metadata depth, nodes and edges without creating value children" do
    argument = CrystalClick::BinaryDataType.nullable(CrystalClick::BinaryDataType.primitive("UInt8"))
    type = CrystalClick::BinaryDataType.aggregate_function("sum", argument)
    type.child_count.should eq(0)
    exact = CrystalClick::BinaryCodecLimits.new(max_depth: 3, max_nodes: 3, max_elements: 2, max_bytes: 1024)
    wire = CrystalClick::BinaryDataTypeCodec.encode(type, exact)
    CrystalClick::BinaryDataTypeCodec.decode(wire, exact).should eq(type)
    [
      CrystalClick::BinaryCodecLimits.new(max_depth: 2, max_nodes: 3, max_elements: 2, max_bytes: 1024),
      CrystalClick::BinaryCodecLimits.new(max_depth: 3, max_nodes: 2, max_elements: 2, max_bytes: 1024),
      CrystalClick::BinaryCodecLimits.new(max_depth: 3, max_nodes: 3, max_elements: 1, max_bytes: 1024),
    ].each do |limits|
      expect_raises(CrystalClick::UnsupportedFormatError) { CrystalClick::BinaryDataTypeCodec.encode(type, limits) }
      expect_raises(CrystalClick::CorruptPartError) { CrystalClick::BinaryDataTypeCodec.decode(wire, limits) }
    end
  end
end
