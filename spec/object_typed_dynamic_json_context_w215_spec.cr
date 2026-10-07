require "./spec_helper"

private def w215_context_limits(
  max_nodes : Int = 256,
  max_elements : Int = 256,
  max_bytes : Int = 16_384,
) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(
    max_depth: 32,
    max_nodes: max_nodes,
    max_elements: max_elements,
    max_bytes: max_bytes,
  )
end

private def w215_context_depth_one_limits : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(
    max_depth: 1,
    max_nodes: 256,
    max_elements: 256,
    max_bytes: 16_384,
  )
end

private def w215_context_empty_structures : CrystalClick::ObjectDynamicStructureSet
  CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new([] of String),
    {} of String => CrystalClick::DynamicStructure,
  )
end

private def w215_context_empty_v2_structures : CrystalClick::ObjectDynamicStructureSet
  CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new(
      [] of String,
      shared_data_version: 2_u64,
      bucket_count: 1_u64,
    ),
    {} of String => CrystalClick::DynamicStructure,
  )
end

private def w215_context_empty_v2_plan : CrystalClick::ObjectDocumentPlan
  CrystalClick::ObjectDocumentPlan.new(
    w215_context_empty_v2_structures,
    {} of String => CrystalClick::BinaryDataType,
  )
end

private def w215_context_empty_documents : Array(Array(CrystalClick::ObjectDocument))
  [[CrystalClick::ObjectDocument.new({} of String => CrystalClick::BinaryValue)] of CrystalClick::ObjectDocument]
end

private def w215_context_typed_dynamic_plan : CrystalClick::ObjectDocumentPlan
  dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  schema = CrystalClick::ObjectDocumentSchema.new({"p" => dynamic} of String => CrystalClick::BinaryDataType)
  roster = CrystalClick::DynamicStructure.new([uint8] of CrystalClick::BinaryDataType)
  CrystalClick::ObjectDocumentPlan.new(
    w215_context_empty_structures,
    schema.typed_paths,
    {"p" => roster} of String => CrystalClick::DynamicStructure,
  )
end

describe "W215 physical Object context boundaries" do
  it "rejects a typed Dynamic Object origin below two before consuming context" do
    plan = w215_context_typed_dynamic_plan
    limits = w215_context_limits

    expect_raises(CrystalClick::UnsupportedFormatError, "depth") do
      CrystalClick::ObjectDocumentPhysicalPlan.new(
        "payload",
        plan,
        limits: limits,
        typed_descriptor_root_depth: 1,
      )
    end

    context = CrystalClick::PhysicalStreamPlanContext.new(limits)
    expect_raises(CrystalClick::UnsupportedFormatError, "depth") do
      CrystalClick::ObjectDocumentPhysicalPlan.from_escaped_prefix(
        "payload",
        plan,
        limits: limits,
        context: context,
        typed_descriptor_root_depth: 1,
      )
    end
    # Each full-limit preflight succeeds only if the failed construction left
    # node, element, and retained-name counters untouched.
    context.preflight_type_budget(limits.max_nodes.to_u64, limits.max_elements.to_u64)
    context.preflight_name_bytes(limits.max_bytes.to_u64)

    valid = CrystalClick::ObjectDocumentPhysicalPlan.from_escaped_prefix(
      "payload",
      plan,
      limits: limits,
      typed_descriptor_root_depth: 2,
    )
    valid.typed_descriptor_root_depth.should eq(2)
    valid.stream_count.should be > 0

    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    standalone = CrystalClick::BinaryDynamicBulkPlan.new(dynamic, {
      "root" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType),
    } of String => CrystalClick::DynamicStructure)
    CrystalClick::BinaryDynamicBulkPhysicalPlan.new(standalone, "dynamic").initial_descriptor_depth.should eq(1)
  end

  it "preflights budgeted child-lane binding before consuming short budgets" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    schema = CrystalClick::ObjectDocumentSchema.new({"v" => uint8} of String => CrystalClick::BinaryDataType)
    plan = CrystalClick::ObjectDocumentPlan.new(w215_context_empty_structures, schema.typed_paths)
    documents = [[CrystalClick::ObjectDocument.new({
      "v" => CrystalClick::BinaryValue.fixed(uint8, Bytes[7_u8]),
    } of String => CrystalClick::BinaryValue)] of CrystalClick::ObjectDocument]
    streams = CrystalClick::ObjectDocumentCodec.encode(plan, documents)
    physical = CrystalClick::ObjectDocumentPhysicalPlan.new("payload", plan)
    lane_bound = physical.stream_count.to_i64
    lane_bound.should be > 0

    node_short = CrystalClick::BinaryCodecBudget.new(
      w215_context_limits(max_nodes: lane_bound - 1, max_elements: lane_bound), true
    )
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentColumnWriter.bind_child_site_lanes(physical, plan, streams, node_short)
    end
    {node_short.node_count, node_short.element_count, node_short.wire_byte_count}.should eq({0_i64, 0_i64, 0_i64})

    element_short = CrystalClick::BinaryCodecBudget.new(
      w215_context_limits(max_nodes: lane_bound, max_elements: lane_bound - 1), true
    )
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentColumnWriter.bind_child_site_lanes(physical, plan, streams, element_short)
    end
    {element_short.node_count, element_short.element_count, element_short.wire_byte_count}.should eq({0_i64, 0_i64, 0_i64})

    ample = CrystalClick::BinaryCodecBudget.new(
      w215_context_limits(max_nodes: lane_bound, max_elements: lane_bound), true
    )
    lanes = CrystalClick::ObjectDocumentColumnWriter.bind_child_site_lanes(physical, plan, streams, ample)
    lanes.map(&.name).sort.should eq(physical.stream_names)
    {ample.node_count, ample.element_count, ample.wire_byte_count}.should eq({lane_bound, lane_bound, 0_i64})
  end
end

describe "W215 empty Object descriptor depth compatibility" do
  it "encodes an empty advanced Object at max depth one" do
    streams = CrystalClick::ObjectDocumentCodec.encode(
      w215_context_empty_v2_plan,
      w215_context_empty_documents,
      limits: w215_context_depth_one_limits,
    )

    streams.mark_count.should eq(1)
    streams.typed_path_count.should eq(0)
  end

  it "decodes an empty advanced Object at max depth one" do
    plan = w215_context_empty_v2_plan
    streams = CrystalClick::ObjectDocumentCodec.encode(plan, w215_context_empty_documents)

    decoded = CrystalClick::ObjectDocumentCodec.decode(
      {} of String => CrystalClick::BinaryDataType,
      streams,
      limits: w215_context_depth_one_limits,
    )

    decoded.size.should eq(1)
    decoded.first.size.should eq(1)
    decoded.first.first.path_count.should eq(0)
  end

  it "builds an empty advanced physical Object plan at max depth one with the default typed origin" do
    physical = CrystalClick::ObjectDocumentPhysicalPlan.new(
      "payload",
      w215_context_empty_v2_plan,
      limits: w215_context_depth_one_limits,
    )

    physical.stream_count.should be > 0
  end

  it "continues to reject a declared UInt8 field whose depth is two" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    plan = CrystalClick::ObjectDocumentPlan.new(
      w215_context_empty_v2_structures,
      {"v" => uint8} of String => CrystalClick::BinaryDataType,
    )
    documents = [[CrystalClick::ObjectDocument.new({
      "v" => CrystalClick::BinaryValue.fixed(uint8, Bytes[7_u8]),
    } of String => CrystalClick::BinaryValue)] of CrystalClick::ObjectDocument]
    streams = CrystalClick::ObjectDocumentCodec.encode(plan, documents)
    limits = w215_context_depth_one_limits

    expect_raises(CrystalClick::UnsupportedFormatError, "depth") do
      CrystalClick::ObjectDocumentCodec.encode(plan, documents, limits: limits)
    end
    expect_raises(CrystalClick::CorruptPartError, "depth") do
      CrystalClick::ObjectDocumentCodec.decode(
        {"v" => uint8} of String => CrystalClick::BinaryDataType,
        streams,
        limits: limits,
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError, "depth") do
      CrystalClick::ObjectDocumentPhysicalPlan.new("payload", plan, limits: limits)
    end
  end
end
