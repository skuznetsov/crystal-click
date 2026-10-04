require "./spec_helper"

private def w154a_limits(
  max_depth : Int = 64,
  max_nodes : Int = 4_096,
  max_elements : Int = 1_000_000,
  max_bytes : Int = 64 * 1024 * 1024,
) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(max_depth, max_nodes, max_elements, max_bytes)
end

private def w154a_empty_structure : Bytes
  # V3, zero ordinary alternatives, no statistics flag payload.
  Bytes[0x04_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8]
end

private def w154a_recursive_dynamic_structure : CrystalClick::DynamicStructure
  dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 0)
  CrystalClick::DynamicStructure.new([
    CrystalClick::BinaryDataType.array(dynamic),
  ] of CrystalClick::BinaryDataType)
end

private def w154a_recursive_variant_structure : CrystalClick::DynamicStructure
  variant = CrystalClick::BinaryDataType.variant([
    CrystalClick::BinaryDataType.primitive("UInt64"),
    CrystalClick::BinaryDataType.primitive("String"),
  ] of CrystalClick::BinaryDataType)
  CrystalClick::DynamicStructure.new([
    CrystalClick::BinaryDataType.array(variant),
  ] of CrystalClick::BinaryDataType)
end

private def w154a_object_plan(structure : CrystalClick::DynamicStructure) : CrystalClick::ObjectDocumentPlan
  set = CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new(["dynamic"] of String),
    {"dynamic" => structure}
  )
  CrystalClick::ObjectDocumentPlan.new(set, {} of String => CrystalClick::BinaryDataType)
end

describe "W154 Dynamic actual-roster budget and legacy-consumer adversaries" do
  it "budgets generated path and role bytes beyond the literal structure blob" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    empty = CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)
    limits = w154a_limits(max_bytes: 10)
    literal = w154a_empty_structure

    CrystalClick::DynamicStructureCodec.encode(empty, limits).should eq(literal)
    literal.size.should eq(10)

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDynamicBulkPlan.new(dynamic, {"root" => empty}, limits: limits)
    end

    plan = CrystalClick::BinaryDynamicBulkPlan.new(dynamic, {"root" => empty})
    expect_raises(CrystalClick::UnsupportedFormatError) do
      plan.encode_structure_streams(CrystalClick::BinaryCodecBudget.new(limits, true))
    end

    streams = CrystalClick::BinaryDynamicStructureStreams.new({"root" => literal})
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDynamicBulkPlan.decode_structure_streams(
        dynamic, streams, CrystalClick::BinaryCodecBudget.new(limits)
      )
    end
  end

  it "uses one exact shared budget for root descriptors, nested sites, and all structure bytes" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    declared = CrystalClick::BinaryDataType.array(
      CrystalClick::BinaryDataType.array(dynamic)
    )
    empty = CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)
    path = "root.elements.elements"
    plan = CrystalClick::BinaryDynamicBulkPlan.new(declared, {path => empty})

    measured_write = CrystalClick::BinaryCodecBudget.new(w154a_limits, true)
    streams = plan.encode_structure_streams(measured_write)
    streams.site_paths.should eq([path] of String)
    measured_write.node_count.should be > 0
    measured_write.element_count.should be > 0
    measured_write.wire_byte_count.should be > 0

    exact_limits = w154a_limits(
      # The declared descriptor reaches this site at depth three; its
      # implicit SharedVariant String lane is one level below the Dynamic.
      max_depth: 4,
      max_nodes: measured_write.node_count,
      max_elements: measured_write.element_count,
      max_bytes: measured_write.wire_byte_count,
    )
    exact_write = CrystalClick::BinaryCodecBudget.new(exact_limits, true)
    exact_streams = plan.encode_structure_streams(exact_write)
    exact_streams.structure_bytes_for(path).should eq(streams.structure_bytes_for(path))
    exact_write.node_count.should eq(measured_write.node_count)
    exact_write.element_count.should eq(measured_write.element_count)
    exact_write.wire_byte_count.should eq(measured_write.wire_byte_count)

    expect_raises(CrystalClick::UnsupportedFormatError) do
      plan.encode_structure_streams(CrystalClick::BinaryCodecBudget.new(
        w154a_limits(max_depth: 3, max_nodes: measured_write.node_count,
          max_elements: measured_write.element_count, max_bytes: measured_write.wire_byte_count), true
      ))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      plan.encode_structure_streams(CrystalClick::BinaryCodecBudget.new(
        w154a_limits(max_depth: 4, max_nodes: measured_write.node_count - 1,
          max_elements: measured_write.element_count, max_bytes: measured_write.wire_byte_count), true
      ))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      plan.encode_structure_streams(CrystalClick::BinaryCodecBudget.new(
        w154a_limits(max_depth: 4, max_nodes: measured_write.node_count,
          max_elements: measured_write.element_count - 1, max_bytes: measured_write.wire_byte_count), true
      ))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      plan.encode_structure_streams(CrystalClick::BinaryCodecBudget.new(
        w154a_limits(max_depth: 4, max_nodes: measured_write.node_count,
          max_elements: measured_write.element_count, max_bytes: measured_write.wire_byte_count - 1), true
      ))
    end

    measured_read = CrystalClick::BinaryCodecBudget.new(w154a_limits)
    decoded = CrystalClick::BinaryDynamicBulkPlan.decode_structure_streams(
      declared, streams, measured_read
    )
    decoded.structure_for(path).should eq(empty)
    exact_read_limits = w154a_limits(
      max_depth: 4,
      max_nodes: measured_read.node_count,
      max_elements: measured_read.element_count,
      max_bytes: measured_read.wire_byte_count,
    )
    exact_read = CrystalClick::BinaryCodecBudget.new(exact_read_limits)
    CrystalClick::BinaryDynamicBulkPlan.decode_structure_streams(declared, streams, exact_read)
      .structure_for(path).should eq(empty)
    exact_read.node_count.should eq(measured_read.node_count)
    exact_read.element_count.should eq(measured_read.element_count)
    exact_read.wire_byte_count.should eq(measured_read.wire_byte_count)

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDynamicBulkPlan.decode_structure_streams(
        declared, streams,
        CrystalClick::BinaryCodecBudget.new(w154a_limits(
          max_depth: 3, max_nodes: measured_read.node_count,
          max_elements: measured_read.element_count, max_bytes: measured_read.wire_byte_count
        ))
      )
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDynamicBulkPlan.decode_structure_streams(
        declared, streams,
        CrystalClick::BinaryCodecBudget.new(w154a_limits(
          max_depth: 4, max_nodes: measured_read.node_count - 1,
          max_elements: measured_read.element_count, max_bytes: measured_read.wire_byte_count
        ))
      )
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDynamicBulkPlan.decode_structure_streams(
        declared, streams,
        CrystalClick::BinaryCodecBudget.new(w154a_limits(
          max_depth: 4, max_nodes: measured_read.node_count,
          max_elements: measured_read.element_count - 1, max_bytes: measured_read.wire_byte_count
        ))
      )
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDynamicBulkPlan.decode_structure_streams(
        declared, streams,
        CrystalClick::BinaryCodecBudget.new(w154a_limits(
          max_depth: 4, max_nodes: measured_read.node_count,
          max_elements: measured_read.element_count, max_bytes: measured_read.wire_byte_count - 1
        ))
      )
    end
  end

  it "charges paired metadata cumulatively across independently valid site blobs" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    empty = CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)
    one_site = CrystalClick::BinaryDynamicBulkPlan.new(dynamic, {"root" => empty})
    one_budget = CrystalClick::BinaryCodecBudget.new(w154a_limits, true)
    one_streams = one_site.encode_structure_streams(one_budget)
    one_streams.structure_bytes_for("root").size.should be > 0

    declared = CrystalClick::BinaryDataType.tuple([
      dynamic,
      dynamic,
    ] of CrystalClick::BinaryDataType)
    two_site = CrystalClick::BinaryDynamicBulkPlan.new(declared, {
      "root.field.0" => empty,
      "root.field.1" => empty,
    })
    two_budget = CrystalClick::BinaryCodecBudget.new(w154a_limits, true)
    two_streams = two_site.encode_structure_streams(two_budget)
    two_streams.total_input_byte_size.should eq(
      two_streams.structure_bytes_for("root.field.0").size.to_u64 +
      two_streams.structure_bytes_for("root.field.1").size.to_u64
    )
    two_budget.wire_byte_count.should be > one_budget.wire_byte_count

    exact_total = w154a_limits(
      max_nodes: two_budget.node_count,
      max_elements: two_budget.element_count,
      max_bytes: two_budget.wire_byte_count,
    )
    exact_replay = CrystalClick::BinaryCodecBudget.new(exact_total, true)
    two_site.encode_structure_streams(exact_replay).total_input_byte_size
      .should eq(two_streams.total_input_byte_size)

    # Each 10-byte empty Dynamic V3 structure independently fits this bound;
    # the two-site operation must account for their sum under one budget.
    each_blob_fits = two_streams.structure_bytes_for("root.field.0").size
    two_streams.structure_bytes_for("root.field.1").size.should eq(each_blob_fits)
    CrystalClick::DynamicStructureCodec.encode(empty, w154a_limits(max_bytes: each_blob_fits))
      .size.should eq(each_blob_fits)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      two_site.encode_structure_streams(CrystalClick::BinaryCodecBudget.new(
        w154a_limits(max_nodes: 4_096, max_elements: 1_000_000, max_bytes: each_blob_fits), true
      ))
    end
  end

  it "does not reset descriptor depth when entering an actual nested roster" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    array_dynamic = CrystalClick::BinaryDataType.array(dynamic)
    outer = CrystalClick::DynamicStructure.new([array_dynamic] of CrystalClick::BinaryDataType)
    deep_inner_arm = CrystalClick::BinaryDataType.array(
      CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.primitive("UInt64"))
    )
    inner = CrystalClick::DynamicStructure.new([deep_inner_arm] of CrystalClick::BinaryDataType)
    plan = CrystalClick::BinaryDynamicBulkPlan.new(dynamic, {
      "root"                => outer,
      "root.arm.0.elements" => inner,
    })

    plan.encode_structure_streams(CrystalClick::BinaryCodecBudget.new(w154a_limits(max_depth: 6), true))
      .site_count.should eq(2)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      plan.encode_structure_streams(CrystalClick::BinaryCodecBudget.new(w154a_limits(max_depth: 5), true))
    end

    streams = plan.encode_structure_streams(CrystalClick::BinaryCodecBudget.new(w154a_limits(max_depth: 6), true))
    CrystalClick::BinaryDynamicBulkPlan.decode_structure_streams(
      dynamic, streams, CrystalClick::BinaryCodecBudget.new(w154a_limits(max_depth: 6))
    ).structure_for("root.arm.0.elements").should eq(inner)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDynamicBulkPlan.decode_structure_streams(
        dynamic, streams, CrystalClick::BinaryCodecBudget.new(w154a_limits(max_depth: 5))
      )
    end
  end

  it "keeps old Dynamic values and Object physical consumers closed for recursive rosters" do
    [w154a_recursive_dynamic_structure, w154a_recursive_variant_structure].each do |structure|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::DynamicValueCodec.encode(structure, [] of Array(CrystalClick::BinaryValue))
      end

      discriminator = CrystalClick::DynamicDiscriminatorCodec.encode(
        structure, [] of Array(UInt8)
      )
      no_arms = CrystalClick::DynamicValueStreams.new(
        discriminator,
        {} of String => CrystalClick::BinaryBulkStreams
      )
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::DynamicValueCodec.decode(structure, no_arms, first_mark: 0, mark_count: 0)
      end

      plan = w154a_object_plan(structure)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentCodec.encode(plan, [] of Array(CrystalClick::ObjectDocument))
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentPhysicalPlan.new("payload", plan)
      end

      metadata = CrystalClick::ObjectDynamicStructureCodec.encode(plan.structures)
      object_zero_window = CrystalClick::ObjectDocumentStreams.new(
        metadata,
        [] of UInt64,
        {} of String => CrystalClick::BinaryBulkStreams,
        {"dynamic" => no_arms},
        CrystalClick::BinaryBulkStreams.new(0, {} of String => CrystalClick::BinaryBulkStream)
      )
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentCodec.decode(
          {} of String => CrystalClick::BinaryDataType,
          object_zero_window,
          first_mark: 0,
          mark_count: 0
        )
      end
    end
  end

  it "keeps recursive Dynamic fenced in generic bulk/default/physical paths but plain Variant admitted" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    array_dynamic = CrystalClick::BinaryDataType.array(dynamic)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkTypePlan.new(array_dynamic, CrystalClick::BinaryBulkProfile.single_stream)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkCodec.encode(array_dynamic, [] of Array(CrystalClick::BinaryValue))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkCodec.decode(
        array_dynamic,
        CrystalClick::BinaryBulkStreams.new(0, {} of String => CrystalClick::BinaryBulkStream),
        [] of UInt64,
        first_mark: 0,
        mark_count: 0
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkDefaultValue.measure(array_dynamic, CrystalClick::BinaryBulkProfile.single_stream)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkDefaultValue.measure_excluding_low_cardinality(
        array_dynamic, CrystalClick::BinaryBulkProfile.single_stream
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkDefaultValue.build(array_dynamic)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkPhysicalPlan.new(array_dynamic, "payload")
    end

    variant = CrystalClick::BinaryDataType.variant([
      CrystalClick::BinaryDataType.primitive("UInt64"),
      CrystalClick::BinaryDataType.primitive("String"),
    ] of CrystalClick::BinaryDataType)
    array_variant = CrystalClick::BinaryDataType.array(variant)
    CrystalClick::BinaryBulkTypePlan.new(array_variant, CrystalClick::BinaryBulkProfile.single_stream)
      .roles.should_not be_empty
    CrystalClick::BinaryBulkDefaultValue.build(array_variant).type.should eq(array_variant)
    generic_variant_streams = CrystalClick::BinaryBulkCodec.encode(
      array_variant, [] of Array(CrystalClick::BinaryValue)
    )
    CrystalClick::BinaryBulkCodec.decode(
      array_variant, generic_variant_streams, [] of UInt64, first_mark: 0, mark_count: 0
    ).should be_empty

    # Object typed Variant remains a separate admitted profile; this is not an
    # actual Dynamic roster and does not widen Object Dynamic-value support.
    object_set = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure
    )
    typed_plan = CrystalClick::ObjectDocumentPlan.new(object_set, {"typed" => variant})
    row = CrystalClick::ObjectDocument.new({
      "typed" => CrystalClick::BinaryValue.variant_null(variant),
    } of String => CrystalClick::BinaryValue)
    typed_streams = CrystalClick::ObjectDocumentCodec.encode(
      typed_plan, [[row]] of Array(CrystalClick::ObjectDocument)
    )
    typed_decoded = CrystalClick::ObjectDocumentCodec.decode(
      {"typed" => variant} of String => CrystalClick::BinaryDataType,
      typed_streams
    )
    typed_decoded[0][0].value_for("typed").is_null?.should be_true
    typed_decoded[0][0].value_for("typed").type.should eq(variant)
  end
end
