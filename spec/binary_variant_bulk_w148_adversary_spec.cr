require "./spec_helper"

private def w148a_variant_string_uint64 : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.variant([
    CrystalClick::BinaryDataType.primitive("UInt64"),
    CrystalClick::BinaryDataType.primitive("String"),
  ] of CrystalClick::BinaryDataType)
end

private def w148a_replace_stream(
  streams : CrystalClick::BinaryBulkStreams,
  role : String,
  bytes : Bytes,
  offsets : Array(UInt64),
) : CrystalClick::BinaryBulkStreams
  lanes = Hash(String, CrystalClick::BinaryBulkStream).new
  streams.roles.each do |name|
    if name == role
      lanes[name] = CrystalClick::BinaryBulkStream.new(bytes, offsets)
    else
      lanes[name] = streams.stream(name)
    end
  end
  CrystalClick::BinaryBulkStreams.new(mark_count: streams.mark_count, streams: lanes)
end

describe "W148 sparse Variant bulk adversarial boundaries" do
  it "rejects forged direct schedule metadata before any budget charge" do
    string = CrystalClick::BinaryDataType.primitive("String")
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    low_string = CrystalClick::BinaryDataType.low_cardinality(string)
    low_uint8 = CrystalClick::BinaryDataType.low_cardinality(uint8)
    type = CrystalClick::BinaryDataType.variant([low_uint8, low_string] of CrystalClick::BinaryDataType)
    rows = [[CrystalClick::BinaryValue.variant_null(type)]] of Array(CrystalClick::BinaryValue)

    [CrystalClick::BinaryBulkProfile.single_stream, CrystalClick::BinaryBulkProfile.with_size_stream].each do |profile|
      streams = CrystalClick::BinaryBulkCodec.encode(type, rows, profile: profile)
      plan = CrystalClick::BinaryBulkTypePlan.new(type, profile)
      [
        {plan.low_cardinality_shape_roles, 1_u64},
        {[] of String, plan.low_cardinality_schedule_grid_count},
      ].each do |roles, count|
        budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
        expect_raises(CrystalClick::CorruptPartError, "metadata differs from its descriptor plan") do
          CrystalClick::BinaryBulkLowCardinalityOccurrenceSchedule.build(
            type, roles, count, streams, [1_u64], budget
          )
        end
        {budget.node_count, budget.element_count, budget.wire_byte_count}.should eq({0_i64, 0_i64, 0_i64})
      end

      # A valid caller may permute the role list. Exercise two distinct
      # structural roles so sorting is not a vacuous one-role check.
      array_type = CrystalClick::BinaryDataType.array(type)
      array_rows = [[CrystalClick::BinaryValue.array(
        array_type, [CrystalClick::BinaryValue.variant_null(type)] of CrystalClick::BinaryValue
      )]] of Array(CrystalClick::BinaryValue)
      array_streams = CrystalClick::BinaryBulkCodec.encode(array_type, array_rows, profile: profile)
      array_plan = CrystalClick::BinaryBulkTypePlan.new(array_type, profile)
      array_plan.low_cardinality_shape_roles.size.should eq(2)
      schedule = CrystalClick::BinaryBulkLowCardinalityOccurrenceSchedule.build(
        array_type,
        array_plan.low_cardinality_shape_roles.reverse,
        array_plan.low_cardinality_schedule_grid_count,
        array_streams,
        [1_u64],
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
      )
      schedule.keys.sort.should eq(["root.elements.arm.0", "root.elements.arm.1"] of String)
      schedule.values.each { |counts| counts.should eq([0_u64]) }
    end
  end

  it "preserves descriptor depth and selected-window bounds for sparse arms" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    array = CrystalClick::BinaryDataType.array(uint8)
    type = CrystalClick::BinaryDataType.variant([array] of CrystalClick::BinaryDataType)
    rows = [[CrystalClick::BinaryValue.variant_null(type)]] of Array(CrystalClick::BinaryValue)
    exact = CrystalClick::BinaryCodecLimits.new(3, 4_096, 1_000_000, 1_024)
    short = CrystalClick::BinaryCodecLimits.new(2, 4_096, 1_000_000, 1_024)
    streams = CrystalClick::BinaryBulkCodec.encode(type, rows, limits: exact)
    CrystalClick::BinaryBulkCodec.decode(type, streams, [1_u64], limits: exact)[0][0].is_null?.should be_true

    # Even an inactive deep arm must pass descriptor validation; NULL cannot
    # conceal a depth violation or turn an invalid range into an empty result.
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkCodec.encode(type, rows, limits: short)
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkCodec.decode(type, streams, [1_u64], limits: short)
    end
    [{-1, 1}, {2, 0}, {0, -1}, {0, 2}].each do |first, count|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryBulkCodec.decode(type, streams, [1_u64], first_mark: first, mark_count: count)
      end
    end
    CrystalClick::BinaryBulkCodec.decode(type, streams, [1_u64], first_mark: 1, mark_count: 0).should be_empty
  end

  it "accounts separate LC-arm schedules when one discriminator shape serves two grids" do
    string = CrystalClick::BinaryDataType.primitive("String")
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    low_string = CrystalClick::BinaryDataType.low_cardinality(string)
    low_uint8 = CrystalClick::BinaryDataType.low_cardinality(uint8)
    type = CrystalClick::BinaryDataType.variant([low_uint8, low_string] of CrystalClick::BinaryDataType)
    type.children.map(&.name).should eq(["LowCardinality(String)", "LowCardinality(UInt8)"] of String)

    rows = [
      [CrystalClick::BinaryValue.variant(
        type,
        0,
        CrystalClick::BinaryValue.low_cardinality(type.child_at(0), CrystalClick::BinaryValue.string("red"))
      )],
      [CrystalClick::BinaryValue.variant(
        type,
        1,
        CrystalClick::BinaryValue.low_cardinality(
          type.child_at(1),
          CrystalClick::BinaryValue.fixed(uint8, Bytes[0x2a_u8])
        )
      )],
      [CrystalClick::BinaryValue.variant_null(type)],
    ] of Array(CrystalClick::BinaryValue)
    rows_per_mark = [1_u64, 1_u64, 1_u64]

    [CrystalClick::BinaryBulkProfile.single_stream, CrystalClick::BinaryBulkProfile.with_size_stream].each do |profile|
      plan = CrystalClick::BinaryBulkTypePlan.new(type, profile)
      plan.low_cardinality_shape_roles.should eq(["root.discriminators"] of String)
      plan.low_cardinality_schedule_grid_count.should eq(2_u64)
      plan.low_cardinality_sites.map(&.path).should eq(["root.arm.0", "root.arm.1"] of String)

      encoded = CrystalClick::BinaryBulkCodec.encode(type, rows, profile: profile)
      encoded.roles.should eq([
        "root.arm.0.dictionary",
        "root.arm.0.indexes",
        "root.arm.1.dictionary",
        "root.arm.1.indexes",
        "root.discriminators",
      ] of String)
      encoded.stream("root.discriminators").bytes.should eq(Bytes[0x00_u8, 0x01_u8, 0xff_u8])
      encoded.stream("root.discriminators").offsets.should eq([0_u64, 1_u64, 2_u64, 3_u64])
      [
        "root.arm.0.dictionary",
        "root.arm.0.indexes",
        "root.arm.1.dictionary",
        "root.arm.1.indexes",
      ].each do |role|
        encoded.stream(role).offset_count.should eq(4)
      end

      decoded = CrystalClick::BinaryBulkCodec.decode(type, encoded, rows_per_mark, profile: profile)
      decoded.size.should eq(3)
      decoded[0][0].variant_index?.should eq(0_u8)
      decoded[0][0].variant_child?.not_nil!.child_at(0).as_string.should eq("red")
      decoded[1][0].variant_index?.should eq(1_u8)
      decoded[1][0].variant_child?.not_nil!.child_at(0).bytes.should eq(Bytes[0x2a_u8])
      decoded[2][0].is_null?.should be_true

      selected = CrystalClick::BinaryBulkCodec.decode(
        type,
        encoded,
        rows_per_mark,
        first_mark: 1,
        mark_count: 1,
        profile: profile
      )
      selected.size.should eq(1)
      selected[0][0].variant_index?.should eq(1_u8)
      selected[0][0].variant_child?.not_nil!.child_at(0).bytes.should eq(Bytes[0x2a_u8])

      exact_schedule_budget = CrystalClick::BinaryCodecBudget.new(
        CrystalClick::BinaryCodecLimits.new(max_depth: 64, max_nodes: 6, max_elements: 6, max_bytes: 3)
      )
      schedule = CrystalClick::BinaryBulkLowCardinalityOccurrenceSchedule.build(
        type,
        plan.low_cardinality_shape_roles,
        plan.low_cardinality_schedule_grid_count,
        encoded,
        rows_per_mark,
        exact_schedule_budget
      )
      schedule["root.arm.0"].should eq([1_u64, 0_u64, 0_u64])
      schedule["root.arm.1"].should eq([0_u64, 1_u64, 0_u64])
      {exact_schedule_budget.node_count, exact_schedule_budget.element_count, exact_schedule_budget.wire_byte_count}.should eq(
        {6_i64, 6_i64, 3_i64}
      )

      [
        CrystalClick::BinaryCodecLimits.new(max_depth: 64, max_nodes: 5, max_elements: 6, max_bytes: 3),
        CrystalClick::BinaryCodecLimits.new(max_depth: 64, max_nodes: 6, max_elements: 5, max_bytes: 3),
        CrystalClick::BinaryCodecLimits.new(max_depth: 64, max_nodes: 6, max_elements: 6, max_bytes: 2),
      ].each do |short_limits|
        short_schedule_budget = CrystalClick::BinaryCodecBudget.new(short_limits)
        expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::BinaryBulkLowCardinalityOccurrenceSchedule.build(
            type,
            plan.low_cardinality_shape_roles,
            plan.low_cardinality_schedule_grid_count,
            encoded,
            rows_per_mark,
            short_schedule_budget
          )
        end
        {short_schedule_budget.node_count, short_schedule_budget.element_count, short_schedule_budget.wire_byte_count}.should eq(
          {0_i64, 0_i64, 0_i64}
        )
      end

      empty = CrystalClick::BinaryBulkCodec.encode(type, [] of Array(CrystalClick::BinaryValue), profile: profile)
      empty.mark_count.should eq(0)
      empty.stream("root.discriminators").offsets.should eq([0_u64])
      CrystalClick::BinaryBulkCodec.decode(type, empty, [] of UInt64, profile: profile).should be_empty

      zero_row_streams = CrystalClick::BinaryBulkCodec.encode(
        type,
        [
          [] of CrystalClick::BinaryValue,
          [CrystalClick::BinaryValue.variant_null(type)],
        ] of Array(CrystalClick::BinaryValue),
        profile: profile
      )
      zero_row_streams.stream("root.discriminators").bytes.should eq(Bytes[0xff_u8])
      zero_row_streams.stream("root.discriminators").offsets.should eq([0_u64, 0_u64, 1_u64])
      zero_rows_decoded = CrystalClick::BinaryBulkCodec.decode(
        type,
        zero_row_streams,
        [0_u64, 1_u64],
        profile: profile
      )
      zero_rows_decoded[0].should be_empty
      zero_rows_decoded[1][0].is_null?.should be_true
      nil
    end
  end

  it "keeps bulk active arm 254 distinct from NULL 255 at the 255-arm boundary" do
    arms = Array(CrystalClick::BinaryDataType).new(255) do |index|
      CrystalClick::BinaryDataType.fixed_string(index + 1)
    end
    type = CrystalClick::BinaryDataType.variant(arms)
    selected_arm = type.child_at(254)
    selected_bytes = Bytes.new(selected_arm.fixed_width.not_nil!) { 0x2a_u8 }
    selected = CrystalClick::BinaryValue.variant(
      type,
      254,
      CrystalClick::BinaryValue.fixed(selected_arm, selected_bytes)
    )
    rows = [[selected, CrystalClick::BinaryValue.variant_null(type)]] of Array(CrystalClick::BinaryValue)

    streams = CrystalClick::BinaryBulkCodec.encode(type, rows)
    streams.stream("root.discriminators").bytes.should eq(Bytes[0xfe_u8, 0xff_u8])
    streams.stream("root.discriminators").offsets.should eq([0_u64, 2_u64])
    streams.stream("root.arm.254.data").bytes.should eq(selected_bytes)
    streams.stream("root.arm.254.data").offsets.should eq([0_u64, selected_bytes.size.to_u64])
    streams.stream("root.arm.253.data").bytes.should be_empty
    streams.stream("root.arm.253.data").offsets.should eq([0_u64, 0_u64])

    decoded = CrystalClick::BinaryBulkCodec.decode(type, streams, [2_u64])
    decoded[0][0].variant_index?.should eq(254_u8)
    decoded[0][0].variant_child?.not_nil!.type.should eq(selected_arm)
    decoded[0][0].variant_child?.not_nil!.bytes.should eq(selected_bytes)
    decoded[0][1].is_null?.should be_true
    decoded[0][1].variant_index?.should be_nil
    decoded[0][1].variant_child?.should be_nil
  end

  it "validates every LC-bearing Variant discriminator outside an empty or selected window" do
    string = CrystalClick::BinaryDataType.primitive("String")
    low_string = CrystalClick::BinaryDataType.low_cardinality(string)
    type = CrystalClick::BinaryDataType.variant([string, low_string] of CrystalClick::BinaryDataType)
    type.children.map(&.name).should eq(["LowCardinality(String)", "String"] of String)
    rows = [
      [CrystalClick::BinaryValue.variant(
        type,
        0,
        CrystalClick::BinaryValue.low_cardinality(type.child_at(0), CrystalClick::BinaryValue.string("dictionary"))
      )],
      [CrystalClick::BinaryValue.variant(type, 1, CrystalClick::BinaryValue.string("ordinary"))],
      [CrystalClick::BinaryValue.variant_null(type)],
    ] of Array(CrystalClick::BinaryValue)
    valid = CrystalClick::BinaryBulkCodec.encode(type, rows)
    valid.stream("root.discriminators").bytes.should eq(Bytes[0x00_u8, 0x01_u8, 0xff_u8])

    # The middle mark selects a non-LC String arm in the valid stream. Replace
    # its tag with an impossible arm index. Neither selecting only mark zero
    # nor selecting an empty suffix may hide corruption from the full-mark LC
    # occurrence census.
    invalid_unselected_mark = w148a_replace_stream(
      valid,
      "root.discriminators",
      Bytes[0x00_u8, 0x02_u8, 0xff_u8],
      [0_u64, 1_u64, 2_u64, 3_u64]
    )
    [
      {0, 1},
      {3, 0},
    ].each do |first_mark, selected_marks|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryBulkCodec.decode(
          type,
          invalid_unselected_mark,
          [1_u64, 1_u64, 1_u64],
          first_mark: first_mark,
          mark_count: selected_marks
        )
      end
    end
  end

  it "rejects malformed discriminator, arm lanes, role sets, and offset grids" do
    type = w148a_variant_string_uint64
    valid = CrystalClick::BinaryBulkCodec.encode(
      type,
      [[CrystalClick::BinaryValue.variant(type, 0, CrystalClick::BinaryValue.string("x"))]] of Array(CrystalClick::BinaryValue)
    )

    invalid_discriminator = w148a_replace_stream(
      valid,
      "root.discriminators",
      Bytes[0x02_u8],
      [0_u64, 1_u64]
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkCodec.decode(type, invalid_discriminator, [1_u64])
    end

    truncated_discriminator = w148a_replace_stream(
      valid,
      "root.discriminators",
      Bytes.empty,
      [0_u64, 0_u64]
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkCodec.decode(type, truncated_discriminator, [1_u64])
    end

    truncated_active_string = w148a_replace_stream(valid, "root.arm.0.data", Bytes[0x01_u8], [0_u64, 1_u64])
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkCodec.decode(type, truncated_active_string, [1_u64])
    end

    trailing_active_string = w148a_replace_stream(
      valid,
      "root.arm.0.data",
      Bytes[0x01_u8, 0x78_u8, 0x00_u8],
      [0_u64, 3_u64]
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkCodec.decode(type, trailing_active_string, [1_u64])
    end

    trailing_inactive_uint64 = w148a_replace_stream(valid, "root.arm.1.data", Bytes[0x00_u8], [0_u64, 1_u64])
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkCodec.decode(type, trailing_inactive_uint64, [1_u64])
    end

    malformed_grid = w148a_replace_stream(
      valid,
      "root.discriminators",
      Bytes[0x00_u8],
      [1_u64, 0_u64]
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkCodec.decode(type, malformed_grid, [1_u64])
    end

    missing_role_lanes = Hash(String, CrystalClick::BinaryBulkStream).new
    valid.roles.each do |role|
      next if role == "root.arm.1.data"
      missing_role_lanes[role] = valid.stream(role)
    end
    missing_role = CrystalClick::BinaryBulkStreams.new(mark_count: 1, streams: missing_role_lanes)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkCodec.decode(type, missing_role, [1_u64])
    end

    extra_role_lanes = Hash(String, CrystalClick::BinaryBulkStream).new
    valid.roles.each { |role| extra_role_lanes[role] = valid.stream(role) }
    extra_role_lanes["root.unexpected.data"] = CrystalClick::BinaryBulkStream.new(Bytes.empty, [0_u64, 0_u64])
    extra_role = CrystalClick::BinaryBulkStreams.new(mark_count: 1, streams: extra_role_lanes)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkCodec.decode(type, extra_role, [1_u64])
    end

    mismatched_domain = CrystalClick::BinaryBulkStreams.new(mark_count: 2, streams: begin
      lanes = Hash(String, CrystalClick::BinaryBulkStream).new
      valid.roles.each { |role| lanes[role] = valid.stream(role) }
      lanes
    end)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkCodec.decode(type, mismatched_domain, [1_u64, 0_u64])
    end
  end
end
