require "./spec_helper"

private def w175_count_types : Array(CrystalClick::BinaryDataType)
  uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
  [
    CrystalClick::BinaryDataType.aggregate_count,
    CrystalClick::BinaryDataType.aggregate_count(uint64),
    CrystalClick::BinaryDataType.aggregate_count(CrystalClick::BinaryDataType.nullable(uint64)),
  ] of CrystalClick::BinaryDataType
end

private def w175_count_concat(parts : Array(Bytes)) : Bytes
  size = parts.sum(&.size)
  result = Bytes.new(size)
  offset = 0
  parts.each do |part|
    part.each do |byte|
      result[offset] = byte
      offset += 1
    end
  end
  result
end

private def w175_count_le64(value : UInt64) : Bytes
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

private def w175_count_limits(
  max_depth : Int = 64,
  max_nodes : Int = 4096,
  max_elements : Int = 1_000_000,
  max_bytes : Int = 64 * 1024 * 1024,
) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(
    max_depth: max_depth,
    max_nodes: max_nodes,
    max_elements: max_elements,
    max_bytes: max_bytes,
  )
end

describe "W175 paired AggregateFunction(count) core" do
  it "round-trips the three literal descriptors as nominal leaves" do
    types = w175_count_types
    names = [
      "AggregateFunction(count)",
      "AggregateFunction(count, UInt64)",
      "AggregateFunction(count, Nullable(UInt64))",
    ]
    literals = [
      Bytes[0x25_u8, 0x00, 0x05, 0x63, 0x6f, 0x75, 0x6e, 0x74, 0x00, 0x00],
      Bytes[0x25_u8, 0x00, 0x05, 0x63, 0x6f, 0x75, 0x6e, 0x74, 0x00, 0x01, 0x04],
      Bytes[0x25_u8, 0x00, 0x05, 0x63, 0x6f, 0x75, 0x6e, 0x74, 0x00, 0x01, 0x23, 0x04],
    ]

    types.each_with_index do |type, index|
      type.name.should eq(names[index])
      type.child_count.should eq(0)
      type.children.should be_empty
      CrystalClick::BinaryDataTypeCodec.encode(type).to_a.should eq(literals[index].to_a)

      decoded = CrystalClick::BinaryDataTypeCodec.decode(literals[index])
      decoded.should eq(type)
      decoded.name.should eq(names[index])
      CrystalClick::BinaryDataTypeCodec.encode(decoded).to_a.should eq(literals[index].to_a)
    end

    types[0].should_not eq(CrystalClick::BinaryDataType.primitive("UInt64"))
    types[1].should_not eq(types[2])
    types[0].aggregate_count_argument_type.should be_nil
    types[1].aggregate_count_argument_type.should eq(CrystalClick::BinaryDataType.primitive("UInt64"))
    types[2].aggregate_count_argument_type.should eq(
      CrystalClick::BinaryDataType.nullable(CrystalClick::BinaryDataType.primitive("UInt64"))
    )
    types.each { |type| type.fixed_width.should be_nil }

    # Equal numeric carriers remain distinct values under each nominal
    # AggregateFunction descriptor signature.
    states = types.map { |type| CrystalClick::BinaryValue.aggregate_count_state(type, 7_u64) }
    states.each { |state| state.count_state.should eq(7_u64) }
    states[0].type.should_not eq(states[1].type)
    states[1].type.should_not eq(states[2].type)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkCodec.encode(
        types[0],
        [[states[1]] of CrystalClick::BinaryValue] of Array(CrystalClick::BinaryValue),
      )
    end
  end

  it "owns a nominal UInt64 carrier while emitting canonical VarUInt state bytes" do
    type = w175_count_types[0]
    counts = [0_u64, 1_u64, 127_u64, 128_u64, 16_384_u64, UInt64::MAX]
    states = [
      Bytes[0x00_u8],
      Bytes[0x01_u8],
      Bytes[0x7f_u8],
      Bytes[0x80_u8, 0x01],
      Bytes[0x80_u8, 0x80, 0x01],
      Bytes[0xff_u8, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01],
    ]

    counts.each_with_index do |count, index|
      value = CrystalClick::BinaryValue.aggregate_count_state(type, count)
      value.type.should eq(type)
      value.count_state.should eq(count)
      value.bytes.should eq(w175_count_le64(count))
      value.element_count.should eq(0)
      expect_raises(ArgumentError) { value.as_uint64 }
      CrystalClick::BinaryValueCodec.encode_value(value).to_a.should eq(states[index].to_a)
      CrystalClick::BinaryValueCodec.decode_value(type, states[index]).count_state.should eq(count)

      envelope = w175_count_concat([
        CrystalClick::BinaryDataTypeCodec.encode(type),
        states[index],
      ] of Bytes)
      CrystalClick::BinaryValueCodec.encode(value).to_a.should eq(envelope.to_a)
      CrystalClick::BinaryValueCodec.decode(envelope).count_state.should eq(count)
    end

    expect_raises(ArgumentError) do
      CrystalClick::BinaryValue.aggregate_count_state(CrystalClick::BinaryDataType.primitive("UInt64"), 1_u64)
    end
    expect_raises(ArgumentError) { CrystalClick::BinaryValue.uint64(1_u64).count_state }
  end

  it "rejects malformed or out-of-profile descriptors and noncanonical state integers" do
    base = Bytes[0x25_u8, 0x00, 0x05, 0x63, 0x6f, 0x75, 0x6e, 0x74]
    bad_descriptors = [
      Bytes[0x25_u8, 0x01, 0x05, 0x63, 0x6f, 0x75, 0x6e, 0x74, 0x00, 0x00], # unsupported version
      Bytes[0x25_u8, 0x00, 0x05, 0x75, 0x6e, 0x69, 0x71, 0x58, 0x00, 0x00], # same-length wrong function
      w175_count_concat([base, Bytes[0x01_u8, 0x00]] of Bytes),             # parameterized, zero arguments
      w175_count_concat([base, Bytes[0x00_u8, 0x02, 0x04, 0x04]] of Bytes), # two arguments
      w175_count_concat([base, Bytes[0x00_u8, 0x01, 0x01]] of Bytes),       # UInt8 argument
      w175_count_concat([base, Bytes[0x00_u8, 0x01, 0x23, 0x01]] of Bytes), # Nullable(UInt8)
    ]
    bad_descriptors.each do |wire|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryDataTypeCodec.decode(wire)
      end
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(
        Bytes[0x25_u8, 0x80, 0x00, 0x05, 0x63, 0x6f, 0x75, 0x6e, 0x74, 0x00, 0x00],
      )
    end

    literal = CrystalClick::BinaryDataTypeCodec.encode(w175_count_types[2])
    (0...literal.size).each do |length|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryDataTypeCodec.decode(literal[0, length])
      end
    end

    malformed_states = [
      Bytes.empty,
      Bytes[0x80_u8],
      Bytes[0x80_u8, 0x00],
      Bytes[0xff_u8, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x02],
      Bytes[0x01_u8, 0x00],
    ]
    malformed_states.each do |wire|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryValueCodec.decode_value(w175_count_types[0], wire)
      end
    end
  end

  it "charges argument edges, descriptor nodes, and wire bytes to shared codec budgets" do
    type = w175_count_types[2]
    descriptor = CrystalClick::BinaryDataTypeCodec.encode(type)
    value = CrystalClick::BinaryValue.aggregate_count_state(type, 128_u64)
    envelope = CrystalClick::BinaryValueCodec.encode(value)

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.encode(type, w175_count_limits(max_elements: 0))
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(descriptor, w175_count_limits(max_elements: 0))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.encode(type, w175_count_limits(max_depth: 1))
    end

    [0, 1, 2].each_with_index do |expected_edges, index|
      name_budget = CrystalClick::BinaryCodecBudget.new(w175_count_limits, true)
      name_bounds = CrystalClick::BinaryTypeNameBudget.measure(w175_count_types[index], name_budget)
      name_bounds[0].should eq(w175_count_types[index].name.bytesize.to_u64)
      name_budget.element_count.should eq(expected_edges.to_i64)
      expected_nodes = expected_edges == 0 ? 1 : (index == 2 ? 3 : 2)
      name_budget.node_count.should eq(expected_nodes.to_i64)
      CrystalClick::BinaryTypeNameBudget.materialize(w175_count_types[index], name_budget, name_bounds)
        .should eq(w175_count_types[index].name)
    end

    [
      w175_count_limits(max_depth: 2),
      w175_count_limits(max_nodes: 2),
      w175_count_limits(max_elements: 1),
    ].each do |limits|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryTypeNameBudget.measure(type, CrystalClick::BinaryCodecBudget.new(limits, true))
      end
    end
    name_limits = w175_count_limits(max_bytes: 83)
    name_budget = CrystalClick::BinaryCodecBudget.new(name_limits, true)
    name_bounds = CrystalClick::BinaryTypeNameBudget.measure(type, name_budget)
    name_bounds[0].should eq(42_u64)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryTypeNameBudget.materialize(type, name_budget, name_bounds)
    end

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode(value, w175_count_limits(max_bytes: envelope.size - 1))
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode(envelope, w175_count_limits(max_bytes: envelope.size - 1))
    end
  end

  it "uses one ordinary data lane and decodes selected Count rows across marks" do
    values_by_mark = w175_count_types.map do |type|
      [
        [
          CrystalClick::BinaryValue.aggregate_count_state(type, 0_u64),
          CrystalClick::BinaryValue.aggregate_count_state(type, 127_u64),
        ] of CrystalClick::BinaryValue,
        [CrystalClick::BinaryValue.aggregate_count_state(type, 128_u64)] of CrystalClick::BinaryValue,
        [CrystalClick::BinaryValue.aggregate_count_state(type, UInt64::MAX)] of CrystalClick::BinaryValue,
      ] of Array(CrystalClick::BinaryValue)
    end

    profiles = [
      CrystalClick::BinaryBulkProfile.single_stream,
      CrystalClick::BinaryBulkProfile.with_size_stream,
    ]
    values_by_mark.each do |marks|
      type = marks[0][0].type
      profiles.each do |profile|
        streams = CrystalClick::BinaryBulkCodec.encode(type, marks, profile: profile)
        streams.mark_count.should eq(3)
        streams.roles.should eq(["root.data"])
        lane = streams.stream("root.data")
        lane.bytes.should eq(Bytes[
          0x00_u8, 0x7f, 0x80, 0x01,
          0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01,
        ])
        lane.offsets.should eq([0_u64, 2_u64, 4_u64, 14_u64])

        physical = CrystalClick::BinaryBulkPhysicalPlan.new(type, "count-col", profile)
        physical.stream_names.should eq({"root.data" => "count%2Dcol"})

        selected = CrystalClick::BinaryBulkCodec.decode(
          type,
          streams,
          [2_u64, 1_u64, 1_u64],
          first_mark: 1,
          mark_count: 2,
          profile: profile,
        )
        selected.size.should eq(2)
        selected[0].map(&.count_state).should eq([128_u64])
        selected[1].map(&.count_state).should eq([UInt64::MAX])

        empty = CrystalClick::BinaryBulkCodec.decode(
          type,
          streams,
          [2_u64, 1_u64, 1_u64],
          first_mark: 3,
          mark_count: 0,
          profile: profile,
        )
        empty.should be_empty
        last_mark = CrystalClick::BinaryBulkCodec.decode(
          type,
          streams,
          [2_u64, 1_u64, 1_u64],
          first_mark: 2,
          mark_count: 1,
          profile: profile,
        )
        last_mark.size.should eq(1)
        last_mark[0].map(&.count_state).should eq([UInt64::MAX])
      end
    end

    type = w175_count_types[0]
    canonical = Bytes[
      0x00_u8, 0x7f, 0x80, 0x01,
      0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01,
    ]
    rows_per_mark = [2_u64, 1_u64, 1_u64]
    make_streams = ->(bytes : Bytes, offsets : Array(UInt64)) do
      lanes = Hash(String, CrystalClick::BinaryBulkStream).new
      lanes["root.data"] = CrystalClick::BinaryBulkStream.new(bytes, offsets)
      CrystalClick::BinaryBulkStreams.new(3, lanes)
    end
    short = make_streams.call(canonical[0, 13], [0_u64, 2_u64, 4_u64, 13_u64])
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkCodec.decode(type, short, rows_per_mark)
    end
    trailing = make_streams.call(
      w175_count_concat([canonical, Bytes[0x00_u8]] of Bytes),
      [0_u64, 2_u64, 4_u64, 15_u64],
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkCodec.decode(type, trailing, rows_per_mark)
    end
    overlong = make_streams.call(
      w175_count_concat([Bytes[0x00_u8, 0x7f, 0x80, 0x00], canonical[4, 10]] of Bytes),
      [0_u64, 2_u64, 4_u64, 14_u64],
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkCodec.decode(type, overlong, rows_per_mark, first_mark: 1, mark_count: 1)
    end
    full = make_streams.call(canonical, [0_u64, 2_u64, 4_u64, 14_u64])
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkCodec.decode(
        type,
        full,
        rows_per_mark,
        first_mark: 1,
        mark_count: 1,
        limits: w175_count_limits(max_bytes: 1),
      )
    end
  end

  it "keeps aggregate states out of compositions, Dynamic, borrowed frames, and Object typed fields" do
    count = w175_count_types[0]
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.array(count) }
    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.nullable(count) }
    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.tuple([count] of CrystalClick::BinaryDataType) }
    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.nested([count] of CrystalClick::BinaryDataType, ["c"] of String) }
    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.map(count, uint64) }
    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.map(uint64, count) }
    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.variant([count] of CrystalClick::BinaryDataType) }
    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.low_cardinality(count) }
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.simple_aggregate(CrystalClick::BinarySimpleAggregateType::Function::Sum, count)
    end

    value = CrystalClick::BinaryValue.aggregate_count_state(count, 7_u64)
    dynamic = CrystalClick::BinaryDataType.dynamic
    expect_raises(ArgumentError) { CrystalClick::BinaryValue.dynamic(dynamic, value) }
    expect_raises(ArgumentError) { CrystalClick::DynamicStructure.new([count] of CrystalClick::BinaryDataType) }
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.decode_value(
        dynamic,
        w175_count_concat([CrystalClick::BinaryDataTypeCodec.encode(count), Bytes[0x07_u8]] of Bytes),
      )
    end

    limits = w175_count_limits
    write_budget = CrystalClick::BinaryCodecBudget.new(limits, true)
    read_budget = CrystalClick::BinaryCodecBudget.new(limits)
    descriptor = CrystalClick::BinaryDataTypeCodec.encode(count)
    envelope = w175_count_concat([descriptor, Bytes[0x07_u8]] of Bytes)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode_borrowed(value, write_budget)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.decode_borrowed(envelope, read_budget)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode_dynamic_bulk_child(value, write_budget, 1)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.decode_dynamic_bulk_child(envelope, read_budget, 1)
    end

    CrystalClick::ObjectTypedFieldType.leaf_byte_size_for(count).should be_nil
    count_name = "AggregateFunction(count)".to_slice
    CrystalClick::ObjectTypedFieldType.resolve_leaf_slice(count_name, 0, count_name.size).should be_nil
    expect_raises(ArgumentError) do
      CrystalClick::ObjectTypedFieldType.append_leaf_name(IO::Memory.new, count)
    end

    shared_sizes = w175_count_le64(1_u64)
    shared_paths = Bytes[0x01_u8, 0x78_u8]
    shared_values = w175_count_concat([Bytes[0x0b_u8], envelope] of Bytes)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectSharedMapCodec.decode(shared_sizes, shared_paths, shared_values, 1)
    end
  end

  it "creates Count defaults without widening the descriptor tree" do
    type = w175_count_types[2]
    default = CrystalClick::BinaryBulkDefaultValue.build(type)
    default.type.should eq(type)
    default.count_state.should eq(0_u64)
    CrystalClick::BinaryBulkDefaultValue.measure(
      type,
      CrystalClick::BinaryBulkProfile.single_stream,
    ).wire_bytes.should eq(1_u64)
  end
end
