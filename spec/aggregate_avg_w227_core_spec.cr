require "./spec_helper"

private def w227_avg_state(sum : UInt64, count : Bytes) : Bytes
  bytes = Bytes.new(8 + count.size)
  8.times do |index|
    bytes[index] = ((sum >> (index * 8)) & 0xff_u64).to_u8
  end
  count.size.times do |index|
    bytes[8 + index] = count[index]
  end
  bytes
end

private def w227_avg_join(parts : Array(Bytes)) : Bytes
  size = 0
  parts.each { |part| size += part.size }

  bytes = Bytes.new(size)
  offset = 0
  parts.each do |part|
    part.size.times do |index|
      bytes[offset + index] = part[index]
    end
    offset += part.size
  end
  bytes
end

private def w227_avg_limits(max_bytes : Int) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(
    max_depth: 64,
    max_nodes: 4_096,
    max_elements: 1_000_000,
    max_bytes: max_bytes
  )
end

private def w227_avg_leaf_declarations : Array(String)
  [
    "UInt8", "UInt16", "UInt32", "UInt64", "UInt128", "UInt256",
    "Int8", "Int16", "Int32", "Int64", "Int128", "Int256",
    "Float32", "Float64", "BFloat16", "Bool",
    "Decimal(9, 2)", "Decimal(18, 2)", "Decimal(38, 2)", "Decimal(76, 2)",
    "Date", "Date32", "DateTime", "DateTime64(3)", "Time", "Time64(3)",
    "IntervalNanosecond", "IntervalMicrosecond", "IntervalMillisecond",
    "IntervalSecond", "IntervalMinute", "IntervalHour", "IntervalDay",
    "IntervalWeek", "IntervalMonth", "IntervalQuarter", "IntervalYear",
  ] of String
end

private def w227_avg_low_cardinality_leaf_declarations : Array(String)
  [
    "UInt8", "UInt16", "UInt32", "UInt64", "UInt128", "UInt256",
    "Int8", "Int16", "Int32", "Int64", "Int128", "Int256",
    "Float32", "Float64", "BFloat16", "Bool",
    "Date", "Date32", "DateTime", "Time",
    "IntervalNanosecond", "IntervalMicrosecond", "IntervalMillisecond",
    "IntervalSecond", "IntervalMinute", "IntervalHour", "IntervalDay",
    "IntervalWeek", "IntervalMonth", "IntervalQuarter", "IntervalYear",
  ] of String
end

private def w227_avg_varuint(value : UInt64) : Bytes
  bytes = [] of UInt8
  remaining = value
  loop do
    byte = (remaining & 0x7f_u64).to_u8
    remaining >>= 7
    if remaining > 0_u64
      byte |= 0x80_u8
    end
    bytes << byte
    break if remaining == 0_u64
  end
  Bytes.new(bytes.size) { |index| bytes[index] }
end

describe "W227 AggregateFunction avg core" do
  it "preserves the canonical root descriptor and literal tag-0x25 bytes" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    type = CrystalClick::BinaryDataType.aggregate_function("avg", uint8)
    literal = Bytes[0x25_u8, 0_u8, 3_u8, 0x61_u8, 0x76_u8, 0x67_u8, 0_u8, 1_u8, 1_u8]

    type.name.should eq("AggregateFunction(avg, UInt8)")
    type.child_count.should eq(0)
    type.fixed_width.should be_nil
    type.contains_aggregate_count?.should be_false
    type.contains_aggregate_function?.should be_true
    type.aggregate_function_type.not_nil!.argument_type.should eq(uint8)
    CrystalClick::BinaryDataTypeCodec.encode(type).should eq(literal)
    CrystalClick::BinaryDataTypeCodec.decode(literal).should eq(type)
    CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(type.name).should eq(type)
  end

  it "preserves exact empty, 127-count, and 128-count states and nominal identity" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    type = CrystalClick::BinaryDataType.aggregate_function("avg", uint8)
    empty = w227_avg_state(0_u64, Bytes[0_u8])
    ones_127 = w227_avg_state(127_u64, Bytes[0x7f_u8])
    ones_128 = w227_avg_state(128_u64, Bytes[0x80_u8, 0x01_u8])

    empty.should eq(Bytes[0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8])
    ones_127.should eq(Bytes[0x7f_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0x7f_u8])
    ones_128.should eq(Bytes[0x80_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0x80_u8, 0x01_u8])

    [empty, ones_127, ones_128].each do |state_bytes|
      value = CrystalClick::BinaryValue.aggregate_function_state(type, state_bytes)
      CrystalClick::BinaryValueCodec.encode_value(value).should eq(state_bytes)
      decoded = CrystalClick::BinaryValueCodec.decode_value(type, state_bytes)
      decoded.type.should eq(type)
      decoded.aggregate_function_state_bytes.should eq(state_bytes)
    end

    wire = CrystalClick::BinaryValueCodec.encode(
      CrystalClick::BinaryValue.aggregate_function_state(type, ones_127)
    )
    wire.should eq(w227_avg_join([
      Bytes[0x25_u8, 0_u8, 3_u8, 0x61_u8, 0x76_u8, 0x67_u8, 0_u8, 1_u8, 1_u8],
      ones_127,
    ]))
    decoded_wire = CrystalClick::BinaryValueCodec.decode(wire)
    decoded_wire.type.should eq(type)
    decoded_wire.type.should_not eq(
      CrystalClick::BinaryDataType.aggregate_function("sum", uint8)
    )
    decoded_wire.aggregate_function_state_bytes.should eq(ones_127)
  end

  it "accepts changing denominator lengths across adjacent bulk rows within exact byte budgets" do
    type = CrystalClick::BinaryDataType.aggregate_function(
      "avg",
      CrystalClick::BinaryDataType.primitive("UInt8")
    )
    ones_127 = w227_avg_state(127_u64, Bytes[0x7f_u8])
    ones_128 = w227_avg_state(128_u64, Bytes[0x80_u8, 0x01_u8])
    state_bytes = [ones_127, ones_128] of Bytes
    values = state_bytes.map do |bytes|
      CrystalClick::BinaryValue.aggregate_function_state(type, bytes)
    end
    exact_limits = w227_avg_limits(19)

    streams = CrystalClick::BinaryBulkCodec.encode(type, [values], exact_limits)
    streams.roles.should eq(["root.data"])
    streams.stream("root.data").bytes.should eq(w227_avg_join(state_bytes))
    decoded = CrystalClick::BinaryBulkCodec.decode(type, streams, [2_u64], limits: exact_limits)
    decoded.first.map(&.aggregate_function_state_bytes).should eq(state_bytes)

    too_small = w227_avg_limits(18)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkCodec.encode(type, [values], too_small)
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkCodec.decode(type, streams, [2_u64], limits: too_small)
    end

    empty = CrystalClick::BinaryValue.aggregate_function_state(
      type,
      w227_avg_state(0_u64, Bytes[0_u8])
    )
    exact_scalar_limits = w227_avg_limits(9)
    CrystalClick::BinaryValueCodec.encode_value(empty, exact_scalar_limits).size.should eq(9)
    CrystalClick::BinaryValueCodec.decode_value(type, w227_avg_state(0_u64, Bytes[0_u8]), exact_scalar_limits).type.should eq(type)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode_value(empty, w227_avg_limits(8))
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode_value(type, w227_avg_state(0_u64, Bytes[0_u8]), w227_avg_limits(8))
    end
  end

  it "rejects trailing, truncated, noncanonical, and overflowing denominators" do
    type = CrystalClick::BinaryDataType.aggregate_function(
      "avg",
      CrystalClick::BinaryDataType.primitive("UInt8")
    )
    zero_sum = Bytes.new(8, 0_u8)
    valid = w227_avg_state(127_u64, Bytes[0x7f_u8])
    malformed = [
      w227_avg_join([valid, Bytes[0_u8]]),
      Bytes.new(8, 0_u8),
      w227_avg_join([zero_sum, Bytes[0x80_u8]]),
      w227_avg_join([zero_sum, Bytes[0x80_u8, 0_u8]]),
      w227_avg_join([
        zero_sum,
        Bytes[0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0x02_u8],
      ]),
    ] of Bytes

    malformed.each do |bytes|
      expect_raises(ArgumentError) do
        CrystalClick::BinaryValue.aggregate_function_state(type, bytes)
      end
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryValueCodec.decode_value(type, bytes)
      end
    end
  end

  it "keeps existing Count and Sum lanes green and rejects malformed nullable presence" do
    count_type = CrystalClick::BinaryDataType.aggregate_count
    count = CrystalClick::BinaryValue.aggregate_count_state(count_type, 128_u64)
    CrystalClick::BinaryValueCodec.encode_value(count).should eq(Bytes[0x80_u8, 0x01_u8])
    CrystalClick::BinaryValueCodec.decode_value(count_type, Bytes[0x80_u8, 0x01_u8]).count_state.should eq(128_u64)

    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    sum_type = CrystalClick::BinaryDataType.aggregate_function("sum", uint8)
    sum_bytes = Bytes[0x80_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8]
    sum_value = CrystalClick::BinaryValue.aggregate_function_state(sum_type, sum_bytes)
    CrystalClick::BinaryValueCodec.encode_value(sum_value).should eq(sum_bytes)
    CrystalClick::BinaryValueCodec.decode_value(sum_type, sum_bytes).aggregate_function_state_bytes.should eq(sum_bytes)

    nullable_sum_type = CrystalClick::BinaryDataType.aggregate_function(
      "sum",
      CrystalClick::BinaryDataType.nullable(uint8)
    )
    expect_raises(ArgumentError) do
      CrystalClick::BinaryValue.aggregate_function_state(nullable_sum_type, Bytes[2_u8])
    end
    malformed_streams = CrystalClick::BinaryBulkStreams.new(1, {
      "root.data" => CrystalClick::BinaryBulkStream.new(Bytes[2_u8], [0_u64, 1_u64]),
    })
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkCodec.decode(nullable_sum_type, malformed_streams, [1_u64])
    end
  end

  it "admits the exact 37-leaf and 136-shell source-valid family" do
    leaves = w227_avg_leaf_declarations
    low_cardinality_leaves = w227_avg_low_cardinality_leaf_declarations
    leaves.size.should eq(37)
    low_cardinality_leaves.size.should eq(31)

    declarations = [] of String
    leaves.each do |leaf|
      declarations << leaf
      declarations << "Nullable(#{leaf})"
    end
    low_cardinality_leaves.each do |leaf|
      declarations << "LowCardinality(#{leaf})"
      declarations << "LowCardinality(Nullable(#{leaf}))"
    end
    declarations.size.should eq(136)
    declarations.uniq.size.should eq(136)

    declarations.each do |declaration|
      argument = CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(declaration).not_nil!
      type = CrystalClick::BinaryDataType.aggregate_function("avg", argument)
      descriptor = type.aggregate_function_type.not_nil!

      descriptor.function_name.should eq("avg")
      descriptor.version.should eq(0_u8)
      descriptor.argument_type.should eq(argument)
      type.child_count.should eq(0)
      CrystalClick::BinaryDataTypeCodec.decode(CrystalClick::BinaryDataTypeCodec.encode(type)).should eq(type)
      CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(type.name).should eq(type)
    end
  end

  it "preserves scale, timezone, and same-carrier nominal distinctions" do
    boundary_declarations = [
      "Decimal(1, 0)", "Decimal(9, 9)", "Decimal(10, 0)", "Decimal(18, 18)",
      "Decimal(19, 0)", "Decimal(38, 38)", "Decimal(39, 0)", "Decimal(76, 76)",
      "DateTime('UTC')", "DateTime('Etc/UTC')",
      "DateTime64(0)", "DateTime64(9)",
      "DateTime64(0, 'UTC')", "DateTime64(9, 'America/New_York')",
      "Time64(0)", "Time64(9)",
    ]
    boundary_declarations.each do |declaration|
      argument = CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(declaration).not_nil!
      type = CrystalClick::BinaryDataType.aggregate_function("avg", argument)
      type.aggregate_function_type.not_nil!.argument_type.not_nil!.name.should eq(argument.name)
      CrystalClick::BinaryDataTypeCodec.decode(CrystalClick::BinaryDataTypeCodec.encode(type)).should eq(type)
    end

    parse_avg = ->(declaration : String) {
      argument = CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(declaration).not_nil!
      CrystalClick::BinaryDataType.aggregate_function("avg", argument)
    }
    parse_avg.call("UInt8").should_not eq(parse_avg.call("Int8"))
    parse_avg.call("Decimal(9, 2)").should_not eq(parse_avg.call("Decimal(9, 1)"))
    parse_avg.call("DateTime('UTC')").should_not eq(parse_avg.call("DateTime('Etc/UTC')"))
    parse_avg.call("DateTime64(3, 'UTC')").should_not eq(parse_avg.call("DateTime64(9, 'UTC')"))
    parse_avg.call("Time64(3)").should_not eq(parse_avg.call("Time64(9)"))
  end

  it "rejects source-invalid leaves, wrapper shells, and descriptor metadata" do
    invalid_leaf_declarations = [
      "Nothing", "String", "FixedString(2)", "UUID", "IPv4", "IPv6",
      "Enum8('x' = 1)", "Enum16('x' = 1)",
      "Array(UInt8)", "Tuple(UInt8)", "Map(UInt8, String)",
      "Variant(String, UInt8)", "Dynamic",
    ]
    invalid_leaf_declarations.each do |declaration|
      argument = CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(declaration).not_nil!
      expect_raises(ArgumentError) do
        CrystalClick::BinaryDataType.aggregate_function("avg", argument)
      end
    end

    invalid_shells = [
      "Nullable(LowCardinality(UInt8))", "Nullable(Nullable(UInt8))",
      "LowCardinality(LowCardinality(UInt8))",
      "LowCardinality(Decimal(9, 2))", "LowCardinality(DateTime64(0))",
      "LowCardinality(Time64(9))",
    ]
    invalid_shells.each do |declaration|
      argument = CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(declaration)
      if argument
        expect_raises(ArgumentError) do
          CrystalClick::BinaryDataType.aggregate_function("avg", argument)
        end
      else
        argument.should be_nil
      end
    end

    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.aggregate_function("avg", uint8, 1_u8)
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.aggregate_function("min", uint8)
    end

    valid_descriptor = Bytes[0x25_u8, 0_u8, 3_u8, 0x61_u8, 0x76_u8, 0x67_u8, 0_u8, 1_u8, 1_u8]
    invalid_leaf_descriptor = valid_descriptor.dup
    invalid_leaf_descriptor[8] = CrystalClick::BinaryDataType::TAG_STRING
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.decode(invalid_leaf_descriptor)
    end

    nonzero_version = valid_descriptor.dup
    nonzero_version[1] = 1_u8
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.decode(nonzero_version)
    end

    parameterized = valid_descriptor.dup
    parameterized[6] = 1_u8
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.decode(parameterized)
    end

    zero_arguments = valid_descriptor.dup
    zero_arguments[7] = 0_u8
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.decode(zero_arguments)
    end
  end

  it "handles the maximum canonical denominator across row and mark boundaries" do
    type = CrystalClick::BinaryDataType.aggregate_function(
      "avg",
      CrystalClick::BinaryDataType.primitive("UInt8")
    )
    denominators = [
      Bytes[0_u8],
      Bytes[0x7f_u8],
      Bytes[0x80_u8, 0x01_u8],
      Bytes[0x80_u8, 0x80_u8, 0x01_u8],
      w227_avg_varuint(UInt64::MAX),
    ] of Bytes
    denominators.last.size.should eq(10)
    denominators.last.should eq(Bytes[
      0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8,
      0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0x01_u8,
    ])

    states = denominators.map { |denominator| w227_avg_state(0_u64, denominator) }
    state_values = states.map do |bytes|
      CrystalClick::BinaryValue.aggregate_function_state(type, bytes)
    end
    total_bytes = 0
    states.each { |bytes| total_bytes += bytes.size }
    exact_limits = w227_avg_limits(total_bytes)
    streams = CrystalClick::BinaryBulkCodec.encode(
      type,
      [state_values[0..1], state_values[2..3], [state_values[4]]],
      exact_limits
    )
    decoded = CrystalClick::BinaryBulkCodec.decode(
      type,
      streams,
      [2_u64, 2_u64, 1_u64],
      limits: exact_limits
    )
    decoded.flatten.map(&.aggregate_function_state_bytes).should eq(states)

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkCodec.encode(
        type,
        [state_values],
        w227_avg_limits(total_bytes - 1)
      )
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkCodec.decode(
        type,
        streams,
        [2_u64, 2_u64, 1_u64],
        limits: w227_avg_limits(total_bytes - 1)
      )
    end

    maximum = state_values.last
    maximum.aggregate_function_state_bytes.size.should eq(18)
    CrystalClick::BinaryValueCodec.encode_value(maximum, w227_avg_limits(18)).size.should eq(18)
    CrystalClick::BinaryValueCodec.decode_value(type, states.last, w227_avg_limits(18)).aggregate_function_state_bytes.should eq(states.last)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode_value(maximum, w227_avg_limits(17))
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode_value(type, states.last, w227_avg_limits(17))
    end

    count_type = CrystalClick::BinaryDataType.aggregate_count
    count_max = CrystalClick::BinaryValue.aggregate_count_state(count_type, UInt64::MAX)
    count_max_bytes = Bytes.new(10, 0xff_u8)
    count_max_bytes[9] = 0x01_u8
    CrystalClick::BinaryValueCodec.encode_value(count_max).should eq(count_max_bytes)
    CrystalClick::BinaryValueCodec.decode_value(count_type, count_max_bytes).count_state.should eq(UInt64::MAX)
  end

  it "keeps nullable Avg absence distinct from a present empty accumulator" do
    argument = CrystalClick::BinaryDataType.nullable(CrystalClick::BinaryDataType.primitive("UInt8"))
    type = CrystalClick::BinaryDataType.aggregate_function("avg", argument)
    absent = Bytes[0_u8]
    present_empty = Bytes[1_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8]

    [absent, present_empty].each do |bytes|
      value = CrystalClick::BinaryValue.aggregate_function_state(type, bytes)
      CrystalClick::BinaryValueCodec.encode_value(value).should eq(bytes)
      CrystalClick::BinaryValueCodec.decode_value(type, bytes).aggregate_function_state_bytes.should eq(bytes)
    end

    malformed = [Bytes[2_u8], Bytes[0_u8, 0_u8], Bytes[1_u8]] of Bytes
    malformed.each do |bytes|
      expect_raises(ArgumentError) do
        CrystalClick::BinaryValue.aggregate_function_state(type, bytes)
      end
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryValueCodec.decode_value(type, bytes)
      end
    end
  end
end
