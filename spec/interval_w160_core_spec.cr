require "./spec_helper"
require "./support/interval_w160_types"

private def w160_le_i64(value : Int64) : Array(UInt8)
  W160IntervalTestSupport.i64_le(value)
end

private def w160_codec_limits(
  depth : Int = 1,
  nodes : Int = 1,
  elements : Int = 0,
  bytes : Int = 2,
) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(
    max_depth: depth,
    max_nodes: nodes,
    max_elements: elements,
    max_bytes: bytes
  )
end

describe "W160 nominal Interval descriptor and scalar value compatibility" do
  it "maps each exact kind to its canonical name, width, and two-byte descriptor" do
    W160_INTERVAL_TYPES.each do |name, kind, code|
      interval = CrystalClick::BinaryIntervalType.new(kind)
      interval.kind.should eq(kind)
      interval.kind_code.should eq(code)
      interval.type_name.should eq(name)
      interval.name_byte_size.should eq(name.bytesize.to_u64)
      CrystalClick::BinaryIntervalType.parse(name).should eq(interval)
      CrystalClick::BinaryIntervalType.parse("#{name} ").should be_nil

      type = CrystalClick::BinaryDataType.interval(kind)
      type.tag.should eq(CrystalClick::BinaryDataType::TAG_INTERVAL)
      type.name.should eq(name)
      type.type_name.should eq(name)
      type.interval_type.should eq(interval)
      type.fixed_width.should eq(8)
      CrystalClick::BinaryDataTypeCodec.encode(type).should eq(Bytes[0x22_u8, code])
      CrystalClick::BinaryDataTypeCodec.decode(Bytes[0x22_u8, code]).should eq(type)
    end
  end

  it "keeps Month and Second nominally distinct despite equal width and payload" do
    month = CrystalClick::BinaryDataType.interval(CrystalClick::BinaryIntervalType::Kind::Month)
    second = CrystalClick::BinaryDataType.interval(CrystalClick::BinaryIntervalType::Kind::Second)
    int64 = CrystalClick::BinaryDataType.primitive("Int64")

    month.should_not eq(second)
    month.should_not eq(int64)
    {month => "month", second => "second", int64 => "int64"}.size.should eq(3)

    month_value = CrystalClick::BinaryValue.interval(month, 7_i64)
    second_value = CrystalClick::BinaryValue.interval(second, 7_i64)
    month_value.type.should_not eq(second_value.type)
    month_value.bytes.should eq(second_value.bytes)
    month_value.as_interval_count.should eq(7_i64)
    expect_raises(ArgumentError) { month_value.as_int64 }
    expect_raises(ArgumentError) { CrystalClick::BinaryValue.int64(7_i64).as_interval_count }
    expect_raises(ArgumentError) { CrystalClick::BinaryValue.interval(int64, 7_i64) }
  end

  it "round-trips all signed Int64 boundary patterns as raw little-endian counts" do
    counts = [Int64::MIN, -1_i64, 0_i64, 1_i64, Int64::MAX]
    W160_INTERVAL_TYPES.each do |name, kind, code|
      type = CrystalClick::BinaryDataType.interval(kind)
      counts.each do |count|
        value = CrystalClick::BinaryValue.interval(type, count)
        payload = w160_le_i64(count)
        value.bytes.to_a.should eq(payload)
        CrystalClick::BinaryValueCodec.encode_value(value).to_a.should eq(payload)
        CrystalClick::BinaryValueCodec.decode_value(type, Bytes.new(payload.size) { |i| payload[i] }).as_interval_count.should eq(count)

        expected_envelope = [0x22_u8, code] + payload
        encoded = CrystalClick::BinaryValueCodec.encode(value)
        encoded.to_a.should eq(expected_envelope)
        decoded = CrystalClick::BinaryValueCodec.decode(encoded)
        decoded.type.name.should eq(name)
        decoded.type.should eq(type)
        decoded.as_interval_count.should eq(count)
      end
    end
  end

  it "composes Nullable and LowCardinality descriptors without claiming physical LC support" do
    W160_INTERVAL_TYPES.each do |name, kind, code|
      interval = CrystalClick::BinaryDataType.interval(kind)
      nullable = CrystalClick::BinaryDataType.nullable(interval)
      low_cardinality = CrystalClick::BinaryDataType.low_cardinality(interval)

      CrystalClick::BinaryDataTypeCodec.encode(nullable).should eq(Bytes[0x23_u8, 0x22_u8, code])
      CrystalClick::BinaryDataTypeCodec.decode(Bytes[0x23_u8, 0x22_u8, code]).should eq(nullable)
      nullable.name.should eq("Nullable(#{name})")

      CrystalClick::BinaryDataTypeCodec.encode(low_cardinality).should eq(Bytes[0x26_u8, 0x22_u8, code])
      CrystalClick::BinaryDataTypeCodec.decode(Bytes[0x26_u8, 0x22_u8, code]).should eq(low_cardinality)
      low_cardinality.name.should eq("LowCardinality(#{name})")
    end
  end

  it "rejects invalid or truncated kind descriptors and preserves unsupported-tag distinction" do
    [
      Bytes[0x22_u8],
      Bytes[0x22_u8, 0x0b_u8],
      Bytes[0x22_u8, 0xff_u8],
      Bytes[0x22_u8, 0x00_u8, 0x00_u8],
    ].each do |wire|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryDataTypeCodec.decode(wire)
      end
    end
    expect_raises(ArgumentError) do
      forged = CrystalClick::BinaryIntervalType::Kind.new(0x0b_u8)
      CrystalClick::BinaryIntervalType.new(forged)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.decode(Bytes[0x37_u8])
    end
  end

  it "rejects truncation, trailing payload, and insufficient descriptor budgets" do
    W160_INTERVAL_TYPES.each do |_name, _kind, code|
      descriptor = Bytes[0x22_u8, code]
      exact = w160_codec_limits
      CrystalClick::BinaryDataTypeCodec.encode(
        CrystalClick::BinaryDataTypeCodec.decode(descriptor), exact
      ).should eq(descriptor)

      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryDataTypeCodec.decode(descriptor, w160_codec_limits(bytes: 1))
      end
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryDataTypeCodec.decode(descriptor, w160_codec_limits(nodes: 0))
      end
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryDataTypeCodec.decode(descriptor, w160_codec_limits(depth: 0))
      end
    end

    month = CrystalClick::BinaryDataType.interval(CrystalClick::BinaryIntervalType::Kind::Month)
    [0, 1, 2, 3, 4, 5, 6, 7].each do |payload_bytes|
      truncated = Bytes.new(payload_bytes) { |index| index.to_u8 }
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryValueCodec.decode_value(month, truncated)
      end
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode_value(month, Bytes.new(9) { |index| index.to_u8 })
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode(Bytes[0x22_u8, 0x03_u8])
    end
  end

  it "preflights the longest canonical names, including a one-byte-short budget" do
    longest = CrystalClick::BinaryDataType.interval(CrystalClick::BinaryIntervalType::Kind::Microsecond)
    bounds = CrystalClick::BinaryTypeNameBudget.measure(
      longest,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true)
    )
    bounds[0].should eq("IntervalMicrosecond".bytesize.to_u64)

    exact = CrystalClick::BinaryCodecBudget.new(
      CrystalClick::BinaryCodecLimits.new(max_depth: 1, max_nodes: 1, max_elements: 0, max_bytes: bounds[1].to_i),
      true
    )
    CrystalClick::BinaryTypeNameBudget.materialize(longest, exact, bounds).should eq("IntervalMicrosecond")

    one_short = CrystalClick::BinaryCodecBudget.new(
      CrystalClick::BinaryCodecLimits.new(max_depth: 1, max_nodes: 1, max_elements: 0, max_bytes: bounds[1].to_i - 1),
      true
    )
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryTypeNameBudget.materialize(longest, one_short, bounds)
    end
  end
end
