require "./spec_helper"

describe "W156 Dynamic physical-plan adversaries" do
  it "rejects distinct Dynamic sites whose escaped Tuple paths collide physically" do
    first_dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    nested_dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    nested_tuple = CrystalClick::BinaryDataType.tuple(
      [nested_dynamic] of CrystalClick::BinaryDataType,
      ["b"] of String,
    )
    tuple = CrystalClick::BinaryDataType.tuple(
      [first_dynamic, nested_tuple] of CrystalClick::BinaryDataType,
      ["a.b", "a"] of String,
    )
    prepared = CrystalClick::BinaryDynamicBulkPlan.new(tuple, {
      "root.field.0"         => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType),
      "root.field.1.field.0" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType),
    })

    error = expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDynamicBulkPhysicalPlan.new(prepared, "x")
    end
    error.message.should eq("Dynamic physical roles collide on a physical stream name")
  end

  it "rejects explicit limits that differ from the supplied physical context" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    prepared = CrystalClick::BinaryDynamicBulkPlan.new(dynamic, {
      "root" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType),
    })
    supplied_limits = CrystalClick::BinaryCodecLimits.new(64, 64, 64, 4096)
    context_limits = CrystalClick::BinaryCodecLimits.new(63, 64, 64, 4096)
    context = CrystalClick::PhysicalStreamPlanContext.new(context_limits)

    error = expect_raises(ArgumentError) do
      CrystalClick::BinaryDynamicBulkPhysicalPlan.new(
        prepared, "x", limits: supplied_limits, context: context)
    end
    error.message.should eq("Dynamic physical plan and physical context limits differ")
  end

  it "keeps a nested first-arm roster contiguous before a distinct later arm" do
    nested_dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 8)
    nested_tuple = CrystalClick::BinaryDataType.tuple(
      [nested_dynamic] of CrystalClick::BinaryDataType,
    )
    later_uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    static_variant = CrystalClick::BinaryDataType.variant(
      [nested_tuple, later_uint64] of CrystalClick::BinaryDataType,
    )
    actual_array_arm = CrystalClick::BinaryDataType.array(static_variant)
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    nested_path = "root.arm.0.elements.arm.0.field.0"
    prepared = CrystalClick::BinaryDynamicBulkPlan.new(dynamic, {
      "root"      => CrystalClick::DynamicStructure.new([actual_array_arm] of CrystalClick::BinaryDataType),
      nested_path => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType),
    })

    array_arm_prefix = "v.Array%28Variant%28Tuple%28Dynamic%28max_types%3D8%29%29%2C%20UInt64%29%29"
    nested_dynamic_prefix = "#{array_arm_prefix}.Tuple%28Dynamic%28max_types%3D8%29%29%2E1"
    physical = CrystalClick::BinaryDynamicBulkPhysicalPlan.new(prepared, "v")
    physical.stream_name_for("root.arm.0.elements.arm.1.data").should eq(
      "#{array_arm_prefix}.UInt64"
    )
    physical.structure_name_for(nested_path).should eq(
      "#{nested_dynamic_prefix}.dynamic_structure"
    )
    physical.stream_name_for("root.arm.0.elements.arm.0.field.0.arm.0.data").should eq(
      "#{nested_dynamic_prefix}.SharedVariant"
    )
  end

  it "counts descriptors hidden below LC against the global depth limit" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    low_cardinality = CrystalClick::BinaryDataType.low_cardinality(
      CrystalClick::BinaryDataType.nullable(CrystalClick::BinaryDataType.primitive("UInt64")),
    )
    tuple = CrystalClick::BinaryDataType.tuple(
      [dynamic, low_cardinality] of CrystalClick::BinaryDataType,
    )
    prepared = CrystalClick::BinaryDynamicBulkPlan.new(tuple, {
      "root.field.0" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType),
    })
    tight_depth = CrystalClick::BinaryCodecLimits.new(
      max_depth: 2,
      max_nodes: 32,
      max_elements: 64,
      max_bytes: 4096,
    )

    # Tuple is depth 0; the LC child Nullable is depth 2 and its UInt64 child
    # is depth 3. LC remains a physical stop-site, not a descriptor stop-site.
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDynamicBulkPhysicalPlan.new(prepared, "x", limits: tight_depth)
    end
  end

  it "aggregates node, element, and name bytes across contributors in one context" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    prepared = CrystalClick::BinaryDynamicBulkPlan.new(dynamic, {
      "root" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType),
    })

    node_limits = CrystalClick::BinaryCodecLimits.new(64, 3, 64, 4096)
    node_context = CrystalClick::PhysicalStreamPlanContext.new(node_limits)
    CrystalClick::BinaryDynamicBulkPhysicalPlan.new(prepared, "x", context: node_context)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDynamicBulkPhysicalPlan.new(prepared, "x", context: node_context)
    end

    element_limits = CrystalClick::BinaryCodecLimits.new(64, 64, 13, 4096)
    element_context = CrystalClick::PhysicalStreamPlanContext.new(element_limits)
    CrystalClick::BinaryDynamicBulkPhysicalPlan.new(prepared, "x", context: element_context)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDynamicBulkPhysicalPlan.new(prepared, "x", context: element_context)
    end

    # One minimal zero-roster Dynamic binding charges 125 conservative logical
    # role/name bytes for this one-byte prefix. 249 admits the first plan and
    # rejects the second at the aggregate preflight (250 required).
    byte_limits = CrystalClick::BinaryCodecLimits.new(64, 64, 64, 249)
    byte_context = CrystalClick::PhysicalStreamPlanContext.new(byte_limits)
    CrystalClick::BinaryDynamicBulkPhysicalPlan.new(prepared, "x", context: byte_context)
    byte_context.remaining_name_bytes.should eq(124_u64)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDynamicBulkPhysicalPlan.new(prepared, "x", context: byte_context)
    end
  end

  it "rejects a traversal path larger than the remaining byte budget before expansion" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    prepared = CrystalClick::BinaryDynamicBulkPlan.new(dynamic, {
      "root" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType),
    })
    tiny = CrystalClick::BinaryCodecLimits.new(64, 64, 64, 8)

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDynamicBulkPhysicalPlan.new(prepared, "x", limits: tiny)
    end
  end
end
