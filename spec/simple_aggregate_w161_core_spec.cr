require "./spec_helper"
require "./support/simple_aggregate_w161_types"

private def w161_simple_type(
  function : CrystalClick::BinarySimpleAggregateType::Function,
) : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.simple_aggregate(
    function,
    CrystalClick::BinaryDataType.primitive("UInt64")
  )
end

describe "W161 SimpleAggregateFunction nominal descriptor and UInt64 value" do
  it "round-trips all nine exact unary zero-parameter descriptor identities" do
    W161_SIMPLE_AGGREGATE_TYPES.each do |name, _suffix, function|
      expected = W161SimpleAggregateTestSupport.descriptor(name)
      type = w161_simple_type(function)

      type.tag.should eq(CrystalClick::BinaryDataType::TAG_SIMPLE_AGGREGATE)
      type.name.should eq("SimpleAggregateFunction(#{name}, UInt64)")
      type.simple_aggregate_type.not_nil!.function.should eq(function)
      type.child_count.should eq(1)
      type.child_at(0).should eq(CrystalClick::BinaryDataType.primitive("UInt64"))
      CrystalClick::BinaryDataTypeCodec.encode(type).to_a.should eq(expected)

      decoded = CrystalClick::BinaryDataTypeCodec.decode(Bytes.new(expected.size) { |i| expected[i] })
      decoded.should eq(type)
      decoded.name.should eq("SimpleAggregateFunction(#{name}, UInt64)")
      CrystalClick::BinaryDataTypeCodec.encode(decoded).to_a.should eq(expected)
    end
  end

  it "uses UInt64 as the allowed default storage argument without erasing the function" do
    W161_SIMPLE_AGGREGATE_TYPES.each do |name, _suffix, function|
      explicit = w161_simple_type(function)
      defaulted = CrystalClick::BinaryDataType.simple_aggregate(function)
      defaulted.should eq(explicit)
      defaulted.name.should eq("SimpleAggregateFunction(#{name}, UInt64)")
    end
  end

  it "keeps equal-width, equal-payload functions nominally unequal in values and hashes" do
    minimum = w161_simple_type(CrystalClick::BinarySimpleAggregateType::Function::Min)
    maximum = w161_simple_type(CrystalClick::BinarySimpleAggregateType::Function::Max)
    child = CrystalClick::BinaryValue.uint64(0xffff_ffff_ffff_ffff_u64)
    min_value = CrystalClick::BinaryValue.simple_aggregate(minimum, child)
    max_value = CrystalClick::BinaryValue.simple_aggregate(maximum, child)

    minimum.name.should eq("SimpleAggregateFunction(min, UInt64)")
    maximum.name.should eq("SimpleAggregateFunction(max, UInt64)")
    minimum.should_not eq(maximum)
    {minimum => "min", maximum => "max"}.size.should eq(2)
    min_value.type.should eq(minimum)
    max_value.type.should eq(maximum)
    min_value.type.should_not eq(max_value.type)
    min_value.as_simple_aggregate.bytes.should eq(max_value.as_simple_aggregate.bytes)
    min_value.as_simple_aggregate.should eq(child)
    max_value.as_simple_aggregate.should eq(child)
    min_value.as_simple_aggregate.as_uint64.should eq(UInt64::MAX)
    expect_raises(ArgumentError) { min_value.as_uint64 }
    expect_raises(ArgumentError) { CrystalClick::BinaryValue.uint64(UInt64::MAX).as_simple_aggregate }
  end

  it "uses the child UInt64 little-endian payload for single values and typed envelopes" do
    values = [
      0_u64,
      1_u64,
      0x0123_4567_89ab_cdef_u64,
      0x8000_0000_0000_0000_u64,
      0xffff_ffff_ffff_fffe_u64,
      0xffff_ffff_ffff_ffff_u64,
    ]
    literal_edge_bytes = [
      0x00_u8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x01_u8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0xef_u8, 0xcd, 0xab, 0x89, 0x67, 0x45, 0x23, 0x01,
      0x00_u8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80,
      0xfe_u8, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
      0xff_u8, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    ]
    W161SimpleAggregateTestSupport.u64_rows_le(values).should eq(literal_edge_bytes)

    W161_SIMPLE_AGGREGATE_TYPES.each do |name, _suffix, function|
      type = w161_simple_type(function)
      descriptor = W161SimpleAggregateTestSupport.descriptor(name)
      values.each do |value|
        child = CrystalClick::BinaryValue.uint64(value)
        wrapped = CrystalClick::BinaryValue.simple_aggregate(type, child)
        raw = W161SimpleAggregateTestSupport.u64_le(value)

        CrystalClick::BinaryValueCodec.encode_value(wrapped).to_a.should eq(raw)
        decoded_value = CrystalClick::BinaryValueCodec.decode_value(type, Bytes.new(raw.size) { |i| raw[i] })
        decoded_value.type.should eq(type)
        decoded_value.as_simple_aggregate.type.should eq(CrystalClick::BinaryDataType.primitive("UInt64"))
        decoded_value.as_simple_aggregate.as_uint64.should eq(value)

        envelope = descriptor + raw
        encoded_envelope = CrystalClick::BinaryValueCodec.encode(wrapped).to_a
        encoded_envelope.should eq(envelope)
        decoded_envelope = CrystalClick::BinaryValueCodec.decode(Bytes.new(envelope.size) { |i| envelope[i] })
        decoded_envelope.type.should eq(type)
        decoded_envelope.as_simple_aggregate.as_uint64.should eq(value)
        expect_raises(ArgumentError) { decoded_envelope.as_uint64 }
      end
    end
  end
end
