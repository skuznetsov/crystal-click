require "./spec_helper"

alias W226DataType = CrystalClick::BinaryDataType
alias W226Value = CrystalClick::BinaryValue
alias W226ValueCodec = CrystalClick::BinaryValueCodec
alias W226TypeCodec = CrystalClick::BinaryDataTypeCodec
alias W226Structure = CrystalClick::DynamicStructure
alias W226LegacyCodec = CrystalClick::DynamicValueCodec
alias W226BulkPlan = CrystalClick::BinaryDynamicBulkPlan
alias W226PhysicalPlan = CrystalClick::BinaryDynamicBulkPhysicalPlan
alias W226BulkCodec = CrystalClick::BinaryDynamicBulkCodec
alias W226Limits = CrystalClick::BinaryCodecLimits
alias W226Budget = CrystalClick::BinaryCodecBudget
alias W226Unsupported = CrystalClick::UnsupportedFormatError
alias W226Corrupt = CrystalClick::CorruptPartError

private def w226_join(parts : Array(Bytes)) : Bytes
  size = 0
  parts.each { |part| size += part.size }

  bytes = Bytes.new(size)
  offset = 0
  parts.each do |part|
    part.copy_to(bytes + offset)
    offset += part.size
  end
  bytes
end

private def w226_limits(
  max_depth : Int = 64,
  max_nodes : Int = 1_000_000,
  max_elements : Int = 3_000_000,
  max_bytes : Int = 64 * 1024 * 1024,
) : W226Limits
  W226Limits.new(
    max_depth: max_depth,
    max_nodes: max_nodes,
    max_elements: max_elements,
    max_bytes: max_bytes,
  )
end

describe "W226 Dynamic AggregateFunction core" do
  it "round trips Count, Sum, scalar literals, and static AF wrappers through generic Dynamic" do
    count_type = W226DataType.aggregate_count
    sum_type = W226DataType.aggregate_function(
      "sumWithOverflow",
      W226DataType.primitive("UInt8")
    )
    array_sum_type = W226DataType.array(sum_type)
    dynamic_type = W226DataType.dynamic(max_types: 3)

    count_value = W226Value.aggregate_count_state(count_type, 42_u64)
    sum_value = W226Value.aggregate_function_state(sum_type, Bytes[0x2a])
    array_sum_value = W226Value.array(array_sum_type, [sum_value] of W226Value)
    bool_value = W226Value.bool(true)

    values = [count_value, sum_value, array_sum_value, bool_value] of W226Value
    decoded_values = [] of W226Value

    values.each do |value|
      dynamic_value = W226Value.dynamic(dynamic_type, value)
      encoded_value = W226ValueCodec.encode_value(dynamic_value)
      expected_value = w226_join([
        W226TypeCodec.encode(value.type),
        W226ValueCodec.encode_value(value),
      ] of Bytes)
      encoded_value.should eq(expected_value)

      decoded = W226ValueCodec.decode_value(dynamic_type, encoded_value)
      decoded.type.should eq(dynamic_type)
      decoded.child_at(0).type.should eq(value.type)
      decoded_values << decoded.child_at(0)

      full_round_trip = W226ValueCodec.decode(W226ValueCodec.encode(dynamic_value))
      full_round_trip.child_at(0).type.should eq(value.type)
    end

    decoded_values[0].count_state.should eq(42_u64)
    decoded_values[1].aggregate_function_state_bytes.should eq(Bytes[0x2a])
    decoded_values[2].element_at(0).aggregate_function_state_bytes.should eq(Bytes[0x2a])
    decoded_values[3].as_bool.should be_true
  end

  it "admits static AF trees in DynamicStructure while the legacy DynamicValue codec stays closed" do
    count_type = W226DataType.aggregate_count
    sum_type = W226DataType.aggregate_function(
      "sumWithOverflow",
      W226DataType.primitive("UInt8")
    )
    array_sum_type = W226DataType.array(sum_type)

    structure = W226Structure.new([count_type, sum_type, array_sum_type] of W226DataType)
    structure.types.should eq([count_type, sum_type, array_sum_type])

    count_value = W226Value.aggregate_count_state(count_type, 42_u64)
    expect_raises(W226Unsupported) do
      W226LegacyCodec.encode(structure, [[count_value] of W226Value])
    end

    array_sum_value = W226Value.array(
      array_sum_type,
      [W226Value.aggregate_function_state(sum_type, Bytes[0x2a])] of W226Value
    )
    wrapped_structure = W226Structure.new([array_sum_type] of W226DataType)
    expect_raises(W226Unsupported) do
      W226LegacyCodec.encode(wrapped_structure, [[array_sum_value] of W226Value])
    end
  end

  it "round trips known and shared AF bulk arms and preserves unused known physical lanes" do
    count_type = W226DataType.aggregate_count
    sum_type = W226DataType.aggregate_function(
      "sumWithOverflow",
      W226DataType.primitive("UInt8")
    )
    array_sum_type = W226DataType.array(sum_type)
    dynamic_type = W226DataType.dynamic(max_types: 3)

    count_value = W226Value.aggregate_count_state(count_type, 42_u64)
    sum_value = W226Value.aggregate_function_state(sum_type, Bytes[0x2a])
    array_sum_value = W226Value.array(array_sum_type, [sum_value] of W226Value)
    bool_value = W226Value.bool(true)
    structure = W226Structure.new([count_type, sum_type, array_sum_type] of W226DataType)
    structures = {"root" => structure}

    plan = W226BulkPlan.new(dynamic_type, structures)
    count_index = structure.canonical_index_for(count_type)
    sum_index = structure.canonical_index_for(sum_type)
    array_sum_index = structure.canonical_index_for(array_sum_type)
    physical = W226PhysicalPlan.new(plan, "aggregate")

    count_role = "root.arm.#{count_index}.data"
    sum_role = "root.arm.#{sum_index}.data"
    array_sum_role = "root.arm.#{array_sum_index}.elements.data"
    physical.data_stream_names.has_key?(count_role).should be_true
    physical.data_stream_names.has_key?(sum_role).should be_true
    physical.data_stream_names.has_key?(array_sum_role).should be_true
    physical.stream_name_for(count_role).should eq("aggregate.AggregateFunction%28count%29")
    physical.stream_name_for(sum_role).should eq("aggregate.AggregateFunction%28sumWithOverflow%2C%20UInt8%29")
    physical.stream_name_for(array_sum_role).should eq("aggregate.Array%28AggregateFunction%28sumWithOverflow%2C%20UInt8%29%29")

    known_rows = [[
      W226Value.dynamic(dynamic_type, count_value),
      W226Value.dynamic(dynamic_type, sum_value),
      W226Value.dynamic(dynamic_type, array_sum_value),
      W226Value.dynamic(dynamic_type, bool_value),
    ] of W226Value] of Array(W226Value)
    known_streams = W226BulkCodec.encode(dynamic_type, structures, known_rows)
    known_streams.data.stream("root.discriminators").bytes.should eq(Bytes[
      count_index.to_u8,
      sum_index.to_u8,
      array_sum_index.to_u8,
      structure.shared_index.to_u8,
    ])

    known_decoded = W226BulkCodec.decode(
      dynamic_type,
      known_streams,
      [4_u64]
    )
    known_decoded[0][0].child_at(0).count_state.should eq(42_u64)
    known_decoded[0][1].child_at(0).aggregate_function_state_bytes.should eq(Bytes[0x2a])
    known_decoded[0][2].child_at(0).element_at(0).aggregate_function_state_bytes.should eq(Bytes[0x2a])
    known_decoded[0][3].child_at(0).as_bool.should be_true

    unused_known_streams = W226BulkCodec.encode(
      dynamic_type,
      structures,
      [[W226Value.dynamic(dynamic_type, bool_value)] of W226Value]
    )
    [count_role, sum_role, array_sum_role].each do |role|
      lane = unused_known_streams.data.stream(role)
      lane.bytes.should be_empty
      lane.offsets.should eq([0_u64, 0_u64])
    end

    shared_structure = W226Structure.new([] of W226DataType)
    shared_structures = {"root" => shared_structure}
    shared_dynamic_type = W226DataType.dynamic(max_types: 0)
    shared_rows = [[
      W226Value.dynamic(shared_dynamic_type, count_value),
      W226Value.dynamic(shared_dynamic_type, sum_value),
      W226Value.dynamic(shared_dynamic_type, array_sum_value),
      W226Value.dynamic(shared_dynamic_type, bool_value),
    ] of W226Value] of Array(W226Value)
    shared_streams = W226BulkCodec.encode(shared_dynamic_type, shared_structures, shared_rows)
    shared_decoded = W226BulkCodec.decode(
      shared_dynamic_type,
      shared_streams,
      [4_u64]
    )
    shared_decoded[0][0].child_at(0).count_state.should eq(42_u64)
    shared_decoded[0][1].child_at(0).aggregate_function_state_bytes.should eq(Bytes[0x2a])
    shared_decoded[0][2].child_at(0).element_at(0).aggregate_function_state_bytes.should eq(Bytes[0x2a])
    shared_decoded[0][3].child_at(0).as_bool.should be_true
  end

  it "rejects nested runtime AF in the default shared helper despite a clean parent descriptor" do
    dynamic_type = W226DataType.dynamic
    tuple_type = W226DataType.tuple([dynamic_type] of W226DataType)
    tuple_type.contains_aggregate_function?.should be_false

    count_type = W226DataType.aggregate_count
    count_value = W226Value.aggregate_count_state(count_type, 42_u64)
    nested_value = W226Value.dynamic(dynamic_type, count_value)
    tuple_value = W226Value.tuple(tuple_type, [nested_value] of W226Value)
    envelope = W226ValueCodec.encode(tuple_value)

    write_budget = W226Budget.new(W226Limits.default, true)
    expect_raises(W226Unsupported) do
      W226ValueCodec.encode_dynamic_bulk_child(tuple_value, write_budget, 1)
    end

    read_budget = W226Budget.new(W226Limits.default)
    expect_raises(W226Unsupported) do
      W226ValueCodec.decode_dynamic_bulk_child(envelope, read_budget, 1)
    end
  end

  it "enforces one-short shared depth and element-edge budgets" do
    dynamic_type = W226DataType.dynamic(max_types: 0)
    sum_type = W226DataType.aggregate_function(
      "sumWithOverflow",
      W226DataType.primitive("UInt8")
    )
    sum_value = W226Value.aggregate_function_state(sum_type, Bytes[0x2a])
    shared_value = W226Value.dynamic(dynamic_type, sum_value)
    structure = W226Structure.new([] of W226DataType)
    structures = {"root" => structure}
    rows = [[shared_value] of W226Value] of Array(W226Value)

    streams = W226BulkCodec.encode(dynamic_type, structures, rows)
    decoded = W226BulkCodec.decode(dynamic_type, streams, [1_u64])
    decoded[0][0].child_at(0).aggregate_function_state_bytes.should eq(Bytes[0x2a])

    one_short_depth = w226_limits(max_depth: 2)
    expect_raises(W226Unsupported) do
      W226BulkCodec.encode(dynamic_type, structures, rows, limits: one_short_depth)
    end
    expect_raises(W226Corrupt) do
      W226BulkCodec.decode(dynamic_type, streams, [1_u64], limits: one_short_depth)
    end

    write_budget = W226Budget.new(W226Limits.default, true)
    W226BulkCodec.encode_with_budget(dynamic_type, structures, rows, write_budget)
    write_budget.element_count.should be > 0
    one_short_write_edges = w226_limits(max_elements: (write_budget.element_count - 1).to_i)
    expect_raises(W226Unsupported) do
      W226BulkCodec.encode(dynamic_type, structures, rows, limits: one_short_write_edges)
    end

    read_budget = W226Budget.new(W226Limits.default)
    W226BulkCodec.decode_with_budget(dynamic_type, streams, [1_u64], read_budget)
    read_budget.element_count.should be > 0
    one_short_read_edges = w226_limits(max_elements: (read_budget.element_count - 1).to_i)
    expect_raises(W226Corrupt) do
      W226BulkCodec.decode(dynamic_type, streams, [1_u64], limits: one_short_read_edges)
    end
  end
end
