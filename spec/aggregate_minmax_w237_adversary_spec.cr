require "./spec_helper"

private def w237a_minmax_limits(
  depth : Int = 64,
  nodes : Int = 4_096,
  elements : Int = 1_000_000,
  bytes : Int = 64 * 1024 * 1024,
) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(
    max_depth: depth,
    max_nodes: nodes,
    max_elements: elements,
    max_bytes: bytes,
  )
end

describe "W237 AggregateFunction min/max adversarial controls" do
  it "matches ClickHouse String presence, embedded-NUL, and historical read behavior" do
    string = CrystalClick::BinaryDataType.primitive("String")
    type = CrystalClick::BinaryDataType.aggregate_function("min", string)

    absent = Bytes[0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8]
    empty = Bytes[1_u8, 0_u8, 0_u8, 0_u8, 0_u8]
    embedded_nul = Bytes[4_u8, 0_u8, 0_u8, 0_u8, 0x61_u8, 0_u8, 0x62_u8, 0_u8]

    plan = CrystalClick::BinaryAggregateFunctionStatePlan.for_type(type)
    plan.default_state_bytes.should eq(absent)
    CrystalClick::BinaryBulkDefaultValue.build(type).aggregate_function_state_bytes.should eq(absent)

    # 301 is not a single-byte length: keep the signed Int32 representation
    # explicitly little-endian and preserve embedded zero bytes in content.
    long_state = Bytes.new(305, 0_u8)
    long_state[0] = 0x2d_u8
    long_state[1] = 0x01_u8
    300.times do |index|
      long_state[4 + index] = (index & 0xff).to_u8
    end
    long_state[304] = 0_u8
    long_value = CrystalClick::BinaryValue.aggregate_function_state(type, long_state)
    CrystalClick::BinaryValueCodec.encode_value(long_value).should eq(long_state)
    CrystalClick::BinaryValueCodec.decode_value(type, long_state).aggregate_function_state_bytes.should eq(long_state)

    [absent, empty, embedded_nul].each do |state_bytes|
      value = CrystalClick::BinaryValue.aggregate_function_state(type, state_bytes)
      CrystalClick::BinaryValueCodec.encode_value(value).should eq(state_bytes)
      CrystalClick::BinaryValueCodec.decode_value(type, state_bytes).aggregate_function_state_bytes.should eq(state_bytes)
    end

    # ClickHouse accepts every negative Int32 as absent and accepts zero as a
    # legacy present-empty value. Its current writer canonicalizes both forms.
    legacy_negative = Bytes[0xfe_u8, 0xff_u8, 0xff_u8, 0xff_u8]
    legacy_zero = Bytes[0_u8, 0_u8, 0_u8, 0_u8]
    CrystalClick::BinaryValueCodec.encode_value(
      CrystalClick::BinaryValueCodec.decode_value(type, legacy_negative),
    ).should eq(absent)
    CrystalClick::BinaryValueCodec.encode_value(
      CrystalClick::BinaryValueCodec.decode_value(type, legacy_zero),
    ).should eq(empty)

    # A non-NUL final byte is compatibility-appended as content, not rejected.
    legacy_non_nul = Bytes[2_u8, 0_u8, 0_u8, 0_u8, 0x61_u8, 0x78_u8]
    repaired = Bytes[3_u8, 0_u8, 0_u8, 0_u8, 0x61_u8, 0x78_u8, 0_u8]
    CrystalClick::BinaryValueCodec.encode_value(
      CrystalClick::BinaryValueCodec.decode_value(type, legacy_non_nul),
    ).should eq(repaired)
  end

  it "bounds public raw String state construction by the complete standalone byte size" do
    string = CrystalClick::BinaryDataType.primitive("String")
    type = CrystalClick::BinaryDataType.aggregate_function("min", string)
    state_size = CrystalClick::BinaryCodecLimits::DEFAULT_MAX_BYTES + 1
    encoded_length = (state_size - 4).to_u32
    state_bytes = Bytes.new(state_size, 0_u8)
    state_bytes[0] = (encoded_length & 0xff_u32).to_u8
    state_bytes[1] = ((encoded_length >> 8) & 0xff_u32).to_u8
    state_bytes[2] = ((encoded_length >> 16) & 0xff_u32).to_u8
    state_bytes[3] = ((encoded_length >> 24) & 0xff_u32).to_u8

    expect_raises(ArgumentError) do
      CrystalClick::BinaryValue.aggregate_function_state(type, state_bytes)
    end
  end

  it "counts the complete fixed, String, Generic, and nullable Generic frames against standalone byte limits" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    string = CrystalClick::BinaryDataType.primitive("String")
    array = CrystalClick::BinaryDataType.array(uint8)
    tuple = CrystalClick::BinaryDataType.tuple([uint8] of CrystalClick::BinaryDataType)
    nullable_tuple = CrystalClick::BinaryDataType.nullable(tuple)

    cases = [
      {CrystalClick::BinaryDataType.aggregate_function("min", uint8), Bytes[1_u8, 0x2a_u8]},
      {CrystalClick::BinaryDataType.aggregate_function("max", string), Bytes[1_u8, 0_u8, 0_u8, 0_u8, 0_u8]},
      {CrystalClick::BinaryDataType.aggregate_function("min", array), Bytes[1_u8, 1_u8, 0x2a_u8]},
      {CrystalClick::BinaryDataType.aggregate_function("max", nullable_tuple), Bytes[1_u8, 1_u8, 0x2a_u8]},
    ] of Tuple(CrystalClick::BinaryDataType, Bytes)

    cases.each do |type, state_bytes|
      exact = w237a_minmax_limits(bytes: state_bytes.size)
      CrystalClick::BinaryAggregateFunctionStateCodec.validate_owned_state_bytes(type, state_bytes, exact)

      one_short = w237a_minmax_limits(bytes: state_bytes.size - 1)
      expect_raises(ArgumentError) do
        CrystalClick::BinaryAggregateFunctionStateCodec.validate_owned_state_bytes(type, state_bytes, one_short)
      end
    end
  end

  it "rejects truncated and trailing String and fixed-state bytes without rejecting source-tolerant legacy strings" do
    string = CrystalClick::BinaryDataType.primitive("String")
    string_type = CrystalClick::BinaryDataType.aggregate_function("max", string)
    malformed_string_states = [
      Bytes[0xff_u8, 0xff_u8, 0xff_u8],
      Bytes[2_u8, 0_u8, 0_u8, 0_u8, 0x61_u8],
      Bytes[0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0_u8],
      Bytes[1_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8],
    ] of Bytes

    malformed_string_states.each do |state_bytes|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryValueCodec.decode_value(string_type, state_bytes)
      end
    end

    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    fixed_type = CrystalClick::BinaryDataType.aggregate_function("min", uint8)
    malformed_fixed_states = [Bytes[2_u8], Bytes[1_u8], Bytes[0_u8, 0_u8]] of Bytes
    malformed_fixed_states.each do |state_bytes|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryValueCodec.decode_value(fixed_type, state_bytes)
      end
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryValue.aggregate_function_state(fixed_type, Bytes[2_u8])
    end
  end

  it "keeps nullable outer presence distinct from the generic single-value presence" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    tuple = CrystalClick::BinaryDataType.tuple([uint8] of CrystalClick::BinaryDataType)
    nullable_tuple = CrystalClick::BinaryDataType.nullable(tuple)
    type = CrystalClick::BinaryDataType.aggregate_function("max", nullable_tuple)

    cases = [
      Bytes[0_u8],
      Bytes[1_u8, 0_u8],
      Bytes[1_u8, 1_u8, 0x2a_u8],
    ] of Bytes
    cases.each do |state_bytes|
      value = CrystalClick::BinaryValue.aggregate_function_state(type, state_bytes)
      CrystalClick::BinaryValueCodec.encode_value(value).should eq(state_bytes)
      CrystalClick::BinaryValueCodec.decode_value(type, state_bytes).aggregate_function_state_bytes.should eq(state_bytes)

      with_sentinel = Bytes.new(state_bytes.size + 1) do |index|
        index == state_bytes.size ? 0xa5_u8 : state_bytes[index]
      end
      context = CrystalClick::BinaryCodecContext.new(CrystalClick::BinaryCodecLimits.default, with_sentinel)
      CrystalClick::BinaryAggregateFunctionStateCodec.read(type, context, 1).should eq(state_bytes)
      context.read_byte.should eq(0xa5_u8)
    end
    CrystalClick::BinaryAggregateFunctionStatePlan.for_type(type).default_state_bytes.should eq(Bytes[0_u8])

    [
      Bytes[2_u8],
      Bytes[1_u8],
      Bytes[1_u8, 2_u8],
      Bytes[1_u8, 1_u8],
      Bytes[1_u8, 1_u8, 0x2a_u8, 0_u8],
    ].each do |state_bytes|
      expect_raises(ArgumentError) do
        CrystalClick::BinaryValue.aggregate_function_state(type, state_bytes)
      end
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryValueCodec.decode_value(type, state_bytes)
      end
    end
  end

  it "rejects malformed generic flags, truncated bodies, and trailing child bytes" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    array = CrystalClick::BinaryDataType.array(uint8)
    type = CrystalClick::BinaryDataType.aggregate_function("min", array)
    invalid_states = [
      Bytes[2_u8],
      Bytes[0_u8, 0_u8],
      Bytes[1_u8],
      Bytes[1_u8, 1_u8],
      Bytes[1_u8, 0_u8, 0_u8],
    ] of Bytes

    invalid_states.each do |state_bytes|
      expect_raises(ArgumentError) do
        CrystalClick::BinaryValue.aggregate_function_state(type, state_bytes)
      end
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryValueCodec.decode_value(type, state_bytes)
      end
    end
  end

  it "charges a recursive generic state body against the enclosing operation limits" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    array = CrystalClick::BinaryDataType.array(uint8)
    type = CrystalClick::BinaryDataType.aggregate_function("min", array)
    state_bytes = Bytes[1_u8, 1_u8, 7_u8]
    value = CrystalClick::BinaryValue.aggregate_function_state(type, state_bytes)
    exact = w237a_minmax_limits(3, 6, 3, 3)

    CrystalClick::BinaryValueCodec.encode_value(value, exact).should eq(state_bytes)
    decoded = CrystalClick::BinaryValueCodec.decode_value(type, state_bytes, exact)
    decoded.aggregate_function_state_bytes.should eq(state_bytes)

    one_short = [
      w237a_minmax_limits(2, 6, 4, 3),
      w237a_minmax_limits(3, 5, 4, 3),
      w237a_minmax_limits(3, 6, 2, 3),
      w237a_minmax_limits(3, 6, 4, 2),
    ] of CrystalClick::BinaryCodecLimits
    one_short.each do |limits|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryValueCodec.encode_value(value, limits)
      end
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryValueCodec.decode_value(type, state_bytes, limits)
      end
    end
  end

  it "shares node and element budgets across sibling aggregate states and skips absent bodies" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    argument = CrystalClick::BinaryDataType.array(uint8)
    state_type = CrystalClick::BinaryDataType.aggregate_function("min", argument)
    first_state = CrystalClick::BinaryValue.aggregate_function_state(state_type, Bytes[1_u8, 1_u8, 7_u8])
    second_state = CrystalClick::BinaryValue.aggregate_function_state(state_type, Bytes[1_u8, 1_u8, 9_u8])
    outer_type = CrystalClick::BinaryDataType.array(state_type)
    outer = CrystalClick::BinaryValue.array(outer_type, [first_state, second_state] of CrystalClick::BinaryValue)
    expected = Bytes[2_u8, 1_u8, 1_u8, 7_u8, 1_u8, 1_u8, 9_u8]
    exact = w237a_minmax_limits(4, 11, 7, 7)

    # Each child fits under either aggregate sibling limit by itself.
    sibling_limits = w237a_minmax_limits(4, 10, 8, 7)
    [first_state, second_state].each do |state|
      CrystalClick::BinaryValueCodec.encode_value(state, sibling_limits)
        .should eq(state.aggregate_function_state_bytes)
    end

    CrystalClick::BinaryValueCodec.encode_value(outer, exact).should eq(expected)
    decoded = CrystalClick::BinaryValueCodec.decode_value(outer_type, expected, exact)
    decoded.element_count.should eq(2)
    decoded.element_at(0).aggregate_function_state_bytes.should eq(Bytes[1_u8, 1_u8, 7_u8])
    decoded.element_at(1).aggregate_function_state_bytes.should eq(Bytes[1_u8, 1_u8, 9_u8])

    [
      w237a_minmax_limits(4, 10, 7, 7),
      w237a_minmax_limits(4, 11, 6, 7),
    ].each do |limits|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryValueCodec.encode_value(outer, limits)
      end
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryValueCodec.decode_value(outer_type, expected, limits)
      end
    end

    absent = CrystalClick::BinaryValue.aggregate_function_state(state_type, Bytes[0_u8])
    absent_limits = w237a_minmax_limits(3, 4, 2, 1)
    CrystalClick::BinaryValueCodec.encode_value(absent, absent_limits).should eq(Bytes[0_u8])
    absent_decoded = CrystalClick::BinaryValueCodec.decode_value(state_type, Bytes[0_u8], absent_limits)
    absent_decoded.aggregate_function_state_bytes.should eq(Bytes[0_u8])
  end

  it "shares physical bulk budgets and nested depth across sibling generic states" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    argument = CrystalClick::BinaryDataType.array(uint8)
    state_type = CrystalClick::BinaryDataType.aggregate_function("min", argument)
    outer_type = CrystalClick::BinaryDataType.array(state_type)
    first = CrystalClick::BinaryValue.aggregate_function_state(state_type, Bytes[1_u8, 1_u8, 7_u8])
    second = CrystalClick::BinaryValue.aggregate_function_state(state_type, Bytes[1_u8, 1_u8, 9_u8])
    one = CrystalClick::BinaryValue.array(outer_type, [first] of CrystalClick::BinaryValue)
    siblings = CrystalClick::BinaryValue.array(outer_type, [first, second] of CrystalClick::BinaryValue)
    one_mark = [[one] of CrystalClick::BinaryValue]
    sibling_mark = [[siblings] of CrystalClick::BinaryValue]
    exact_for_one = w237a_minmax_limits(4, 13, 10, 11)

    # One state includes the outer Array's 8-byte size lane and a 3-byte state
    # body. The same bounds reject two siblings, although each body fits alone.
    one_streams = CrystalClick::BinaryBulkCodec.encode(outer_type, one_mark, exact_for_one)
    one_decoded = CrystalClick::BinaryBulkCodec.decode(outer_type, one_streams, [1_u64], limits: exact_for_one)
    one_decoded[0][0].element_count.should eq(1)
    one_decoded[0][0].element_at(0).aggregate_function_state_bytes.should eq(Bytes[1_u8, 1_u8, 7_u8])

    [first, second].each do |state|
      one_value = CrystalClick::BinaryValue.array(outer_type, [state] of CrystalClick::BinaryValue)
      CrystalClick::BinaryBulkCodec.encode(outer_type, [[one_value] of CrystalClick::BinaryValue], exact_for_one)
    end

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkCodec.encode(outer_type, sibling_mark, exact_for_one)
    end
    sibling_streams = CrystalClick::BinaryBulkCodec.encode(outer_type, sibling_mark)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkCodec.decode(outer_type, sibling_streams, [1_u64], limits: exact_for_one)
    end

    # The descriptor tree and mark/offset records account for 9 nodes/8 edges
    # (4/3 plus 5/5). One row with one state adds 4 nodes/2 edges; two sibling
    # states add 7/4, for totals of 13/10 versus 16/12. Keep wire bytes generous
    # here so these failures discriminate traversal only.
    sibling_node_limits = w237a_minmax_limits(4, 13, 64, 64)
    sibling_element_limits = w237a_minmax_limits(4, 64, 10, 64)
    [first, second].each do |state|
      one_value = CrystalClick::BinaryValue.array(outer_type, [state] of CrystalClick::BinaryValue)
      one_mark_for_state = [[one_value] of CrystalClick::BinaryValue]
      CrystalClick::BinaryBulkCodec.encode(outer_type, one_mark_for_state, sibling_node_limits)
      CrystalClick::BinaryBulkCodec.encode(outer_type, one_mark_for_state, sibling_element_limits)
    end

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkCodec.encode(outer_type, sibling_mark, sibling_node_limits)
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkCodec.decode(outer_type, sibling_streams, [1_u64], limits: sibling_node_limits)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkCodec.encode(outer_type, sibling_mark, sibling_element_limits)
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkCodec.decode(outer_type, sibling_streams, [1_u64], limits: sibling_element_limits)
    end

    depth_one_short = w237a_minmax_limits(3, 64, 64, 64)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkCodec.encode(outer_type, one_mark, depth_one_short)
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkCodec.decode(outer_type, one_streams, [1_u64], limits: depth_one_short)
    end
  end

  it "exposes only already-consumed bounded input spans" do
    context = CrystalClick::BinaryCodecContext.new(w237a_minmax_limits, Bytes[0x11_u8, 0x22_u8])
    expect_raises(ArgumentError) { context.consumed_input_slice(-1_i32) }
    expect_raises(ArgumentError) { context.consumed_input_slice(1_i32) }
    context.read_slice(1_u64).should eq(Bytes[0x11_u8])
    offset = context.input_offset
    context.consumed_input_slice(0_i32).should eq(Bytes[0x11_u8])
    context.consumed_input_slice(1_i32).should eq(Bytes.empty)
    context.input_offset.should eq(offset)

    no_input = CrystalClick::BinaryCodecContext.new(w237a_minmax_limits)
    expect_raises(CrystalClick::CorruptPartError) do
      no_input.consumed_input_slice(0_i32)
    end
  end

  it "keeps source-forbidden Dynamic, Variant, and QBit argument owners guarded" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    string = CrystalClick::BinaryDataType.primitive("String")
    dynamic = CrystalClick::BinaryDataType.dynamic(1)
    variant = CrystalClick::BinaryDataType.variant([uint8, string] of CrystalClick::BinaryDataType)
    source_forbidden_arguments = [
      CrystalClick::BinaryDataType.qbit(CrystalClick::QBitType.new("Float32", 8_u64)),
      dynamic,
      variant,
      CrystalClick::BinaryDataType.array(dynamic),
      CrystalClick::BinaryDataType.array(variant),
    ] of CrystalClick::BinaryDataType

    source_forbidden_arguments.each do |argument|
      expect_raises(ArgumentError) do
        CrystalClick::BinaryDataType.aggregate_function("min", argument)
      end
      expect_raises(ArgumentError) do
        CrystalClick::BinaryDataType.aggregate_function("max", argument)
      end
    end
  end

  it "keeps library-unqualified JSON, Nothing, and aggregate-state argument owners guarded" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    nothing = CrystalClick::BinaryDataType.primitive("Nothing")
    simple_aggregate = CrystalClick::BinaryDataType.simple_aggregate(
      CrystalClick::BinarySimpleAggregateType::Function::Min,
      uint8,
    )
    unqualified_arguments = [
      CrystalClick::BinaryDataType.json,
      nothing,
      CrystalClick::BinaryDataType.aggregate_function("sum", uint8),
      simple_aggregate,
    ] of CrystalClick::BinaryDataType

    unqualified_arguments.each do |argument|
      expect_raises(ArgumentError) do
        CrystalClick::BinaryDataType.aggregate_function("min", argument)
      end
      expect_raises(ArgumentError) do
        CrystalClick::BinaryDataType.aggregate_function("max", argument)
      end
    end
  end
end
