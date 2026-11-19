require "./spec_helper"

private def w122_u64_le(value : UInt64) : Bytes
  Bytes[
    (value & 0xff_u64).to_u8,
    ((value >> 8) & 0xff_u64).to_u8,
    ((value >> 16) & 0xff_u64).to_u8,
    ((value >> 24) & 0xff_u64).to_u8,
    ((value >> 32) & 0xff_u64).to_u8,
    ((value >> 40) & 0xff_u64).to_u8,
    ((value >> 48) & 0xff_u64).to_u8,
    ((value >> 56) & 0xff_u64).to_u8,
  ]
end

private def w122_concat(parts : Array(Bytes)) : Bytes
  bytes = [] of UInt8
  parts.each do |part|
    part.each { |byte| bytes << byte }
  end
  Bytes.new(bytes.size) { |index| bytes[index] }
end

private def w122_exact_read_limits(nodes : Int, elements : Int, bytes : Int) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(
    max_depth: 8,
    max_nodes: nodes,
    max_elements: elements,
    max_bytes: bytes,
  )
end

private def w122_single_lane_streams(mark_count : Int, role : String, bytes : Bytes, offsets : Array(UInt64)) : CrystalClick::BinaryBulkStreams
  CrystalClick::BinaryBulkStreams.new(
    mark_count,
    {role => CrystalClick::BinaryBulkStream.new(bytes, offsets)} of String => CrystalClick::BinaryBulkStream,
  )
end

private def w122_sized_string_streams(data : Bytes, data_offsets : Array(UInt64)) : CrystalClick::BinaryBulkStreams
  sizes = w122_concat([w122_u64_le(1_u64), w122_u64_le(2_u64), w122_u64_le(0_u64)] of Bytes)
  CrystalClick::BinaryBulkStreams.new(3, {
    "root.string_sizes" => CrystalClick::BinaryBulkStream.new(sizes, [0_u64, 8_u64, 16_u64, 24_u64]),
    "root.data"         => CrystalClick::BinaryBulkStream.new(data, data_offsets),
  } of String => CrystalClick::BinaryBulkStream)
end

private def w122_decode_scalar_window(
  type : CrystalClick::BinaryDataType,
  streams : CrystalClick::BinaryBulkStreams,
  limits : CrystalClick::BinaryCodecLimits,
  profile : CrystalClick::BinaryBulkProfile = CrystalClick::BinaryBulkProfile.single_stream,
) : Tuple(Array(Array(CrystalClick::BinaryValue)), CrystalClick::BinaryCodecBudget)
  budget = CrystalClick::BinaryCodecBudget.new(limits)
  values = CrystalClick::BinaryBulkCodec.decode_with_budget(
    type,
    streams,
    [1_u64, 1_u64, 1_u64],
    budget,
    first_mark: 1,
    mark_count: 2,
    profile: profile,
  )
  {values, budget}
end

describe "W122 reusable binary bulk values" do
  it "matches authored Array(Nullable(String)) lanes and decodes a nonzero-origin mark window" do
    string_type = CrystalClick::BinaryDataType.primitive("String")
    nullable_string_type = CrystalClick::BinaryDataType.nullable(string_type)
    array_type = CrystalClick::BinaryDataType.array(nullable_string_type)

    skip = CrystalClick::BinaryValue.array(array_type, [
      CrystalClick::BinaryValue.nullable(nullable_string_type, CrystalClick::BinaryValue.string("skip")),
    ] of CrystalClick::BinaryValue)
    empty_array = CrystalClick::BinaryValue.array(array_type, [] of CrystalClick::BinaryValue)
    null_and_x = CrystalClick::BinaryValue.array(array_type, [
      CrystalClick::BinaryValue.nullable(nullable_string_type),
      CrystalClick::BinaryValue.nullable(nullable_string_type, CrystalClick::BinaryValue.string("x")),
    ] of CrystalClick::BinaryValue)
    one_empty_string = CrystalClick::BinaryValue.array(array_type, [
      CrystalClick::BinaryValue.nullable(nullable_string_type, CrystalClick::BinaryValue.string("")),
    ] of CrystalClick::BinaryValue)

    granules = [
      [skip] of CrystalClick::BinaryValue,
      [empty_array, null_and_x] of CrystalClick::BinaryValue,
      [one_empty_string] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)

    # Authored physical-role bytes: Array lengths [1], [0, 2], [1];
    # Nullable flags [0], [1, 0], [0]; String payloads "skip", default-empty
    # for NULL, "x", and the distinct empty string.
    expected_sizes = w122_concat([
      w122_u64_le(1_u64),
      w122_u64_le(0_u64),
      w122_u64_le(2_u64),
      w122_u64_le(1_u64),
    ] of Bytes)
    expected_nulls = Bytes[0x00_u8, 0x01_u8, 0x00_u8, 0x00_u8]
    expected_string_data = Bytes[
      0x04_u8, 0x73_u8, 0x6b_u8, 0x69_u8, 0x70_u8,
      0x00_u8,
      0x01_u8, 0x78_u8,
      0x00_u8,
    ]

    expected_streams = {
      "root.sizes"                => CrystalClick::BinaryBulkStream.new(expected_sizes, [0_u64, 8_u64, 24_u64, 32_u64]),
      "root.elements.nulls"       => CrystalClick::BinaryBulkStream.new(expected_nulls, [0_u64, 1_u64, 3_u64, 4_u64]),
      "root.elements.nested.data" => CrystalClick::BinaryBulkStream.new(expected_string_data, [0_u64, 5_u64, 8_u64, 9_u64]),
    } of String => CrystalClick::BinaryBulkStream
    expected = CrystalClick::BinaryBulkStreams.new(mark_count: 3, streams: expected_streams)

    encoded = CrystalClick::BinaryBulkCodec.encode(array_type, granules)
    encoded.mark_count.should eq(3)
    encoded.roles.sort.should eq(expected.roles.sort)
    expected.roles.each do |role|
      actual_stream = encoded.stream(role)
      expected_stream = expected.stream(role)
      actual_stream.bytes.should eq(expected_stream.bytes)
      actual_stream.offsets.should eq(expected_stream.offsets)
      actual_stream.mark_count.should eq(3)
    end

    selected = CrystalClick::BinaryBulkCodec.decode(
      array_type,
      streams: expected,
      rows_per_mark: [1_u64, 2_u64, 1_u64],
      first_mark: 1,
      mark_count: 2
    )
    selected.size.should eq(2)
    selected[0].size.should eq(2)
    selected[0][0].element_count.should eq(0)
    selected[0][1].element_count.should eq(2)
    selected[0][1].element_at(0).is_null?.should be_true
    selected[0][1].element_at(1).is_null?.should be_false
    selected[0][1].element_at(1).child_at(0).as_string.should eq("x")
    selected[1].size.should eq(1)
    selected[1][0].element_count.should eq(1)
    selected[1][0].element_at(0).is_null?.should be_false
    selected[1][0].element_at(0).child_at(0).as_string.should eq("")
  end

  it "decodes root Bool bytes across a selected window with canonical bytes and the frozen receipt" do
    bool_type = CrystalClick::BinaryDataType.primitive("Bool")
    streams = w122_single_lane_streams(
      4, "root.data", Bytes[0x01_u8, 0x00_u8, 0x7f_u8, 0xff_u8], [0_u64, 1_u64, 2_u64, 3_u64, 4_u64],
    )
    budget = CrystalClick::BinaryCodecBudget.new(w122_exact_read_limits(13, 9, 3))

    selected = CrystalClick::BinaryBulkCodec.decode_with_budget(
      bool_type,
      streams,
      [1_u64, 1_u64, 1_u64, 1_u64],
      budget,
      first_mark: 1,
      mark_count: 3,
    )

    selected.size.should eq(3)
    first = selected[0][0]
    second = selected[1][0]
    third = selected[2][0]
    first.as_bool.should be_false
    second.as_bool.should be_true
    third.as_bool.should be_true
    first.bytes.should eq(Bytes[0x00_u8])
    second.bytes.should eq(Bytes[0x01_u8])
    second.same?(third).should be_false
    (second == third).should be_false

    exposed = second.bytes
    detached = second.bytes
    exposed.to_unsafe.should_not eq(detached.to_unsafe)
    exposed[0] = 0x00_u8
    second.as_bool.should be_true
    third.bytes.should eq(Bytes[0x01_u8])
    second.bytes.should eq(Bytes[0x01_u8])

    encoded = CrystalClick::BinaryBulkCodec.encode(bool_type, selected)
    encoded.stream("root.data").bytes.should eq(Bytes[0x00_u8, 0x01_u8, 0x01_u8])
    {budget.node_count, budget.element_count, budget.wire_byte_count}.should eq({13_i64, 9_i64, 3_i64})

    # Bulk decoding must reuse the validated descriptor without pooling values.
    second.type.same?(bool_type).should be_true
  end

  it "rejects truncated or trailing root Bool bytes" do
    bool_type = CrystalClick::BinaryDataType.primitive("Bool")
    [
      {Bytes.empty, [0_u64, 0_u64]},
      {Bytes[0x7f_u8, 0x00_u8], [0_u64, 2_u64]},
    ].each do |bytes, offsets|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryBulkCodec.decode(
          bool_type,
          w122_single_lane_streams(1, "root.data", bytes, offsets),
          [1_u64],
        )
      end
    end
  end

  it "keeps Nullable Bool null-map validation strict at zero or one" do
    bool_type = CrystalClick::BinaryDataType.primitive("Bool")
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkCodec.decode(
        CrystalClick::BinaryDataType.nullable(bool_type),
        CrystalClick::BinaryBulkStreams.new(1, {
          "root.nulls"       => CrystalClick::BinaryBulkStream.new(Bytes[0x02_u8], [0_u64, 1_u64]),
          "root.nested.data" => CrystalClick::BinaryBulkStream.new(Bytes[0x01_u8], [0_u64, 1_u64]),
        } of String => CrystalClick::BinaryBulkStream),
        [1_u64],
      )
    end
  end

  it "decodes inline root Strings across a selected mark window with the frozen budget receipt" do
    string_type = CrystalClick::BinaryDataType.primitive("String")
    streams = w122_single_lane_streams(
      3, "root.data", Bytes[0x01_u8, 0x61_u8, 0x02_u8, 0x62_u8, 0x63_u8, 0x00_u8],
      [0_u64, 2_u64, 5_u64, 6_u64],
    )
    selected, budget = w122_decode_scalar_window(
      string_type,
      streams,
      w122_exact_read_limits(10, 7, 4),
    )

    first = selected[0][0]
    second = selected[1][0]
    first.as_string.should eq("bc")
    second.as_string.should eq("")

    {budget.node_count, budget.element_count, budget.wire_byte_count}.should eq({10_i64, 7_i64, 4_i64})
  end

  it "decodes sized root Strings across a selected mark window with the frozen budget receipt" do
    string_type = CrystalClick::BinaryDataType.primitive("String")
    streams = w122_sized_string_streams(Bytes[0x61_u8, 0x62_u8, 0x63_u8], [0_u64, 1_u64, 3_u64, 3_u64])
    selected, budget = w122_decode_scalar_window(
      string_type,
      streams,
      w122_exact_read_limits(14, 11, 18),
      CrystalClick::BinaryBulkProfile.with_size_stream,
    )

    first = selected[0][0]
    second = selected[1][0]
    first.as_string.should eq("bc")
    second.as_string.should eq("")
    {budget.node_count, budget.element_count, budget.wire_byte_count}.should eq({14_i64, 11_i64, 18_i64})

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkCodec.decode(
        string_type,
        w122_sized_string_streams(Bytes[0x61_u8, 0x62_u8], [0_u64, 1_u64, 2_u64, 2_u64]),
        [1_u64, 1_u64, 1_u64],
        first_mark: 1,
        mark_count: 2,
        profile: CrystalClick::BinaryBulkProfile.with_size_stream,
      )
    end
  end

  it "decodes fixed-width root values across a selected mark window with the frozen budget receipt" do
    uint16_type = CrystalClick::BinaryDataType.primitive("UInt16")
    streams = w122_single_lane_streams(
      3, "root.data", Bytes[0x34_u8, 0x12_u8, 0x78_u8, 0x56_u8, 0xbc_u8, 0x9a_u8],
      [0_u64, 2_u64, 4_u64, 6_u64],
    )
    selected, budget = w122_decode_scalar_window(
      uint16_type,
      streams,
      w122_exact_read_limits(10, 7, 4),
    )

    first = selected[0][0]
    second = selected[1][0]
    first.bytes.should eq(Bytes[0x78_u8, 0x56_u8])
    second.bytes.should eq(Bytes[0xbc_u8, 0x9a_u8])
    {budget.node_count, budget.element_count, budget.wire_byte_count}.should eq({10_i64, 7_i64, 4_i64})
  end
end
