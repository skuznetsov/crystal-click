require "./spec_helper"

private def w240_inline_depth_prefix_tape(has_dynamic_path : Bool)
  object_prefix = if has_dynamic_path
                    # Object V3, one path `x`, MAP shared version, no statistics.
                    Bytes[4, 0, 0, 0, 0, 0, 0, 0, 1, 1, 120, 0]
                  else
                    # Object V3, no paths, MAP shared version, no statistics.
                    Bytes[4, 0, 0, 0, 0, 0, 0, 0, 0, 0]
                  end
  chunks = [object_prefix] of Bytes
  events = [
    CrystalClick::ObjectSharedPathSubstreamEvent.new(".child.object_structure", 0_u64),
  ]

  if has_dynamic_path
    # Dynamic V3 prefix with one String arm, followed by its Compact discriminator prefix.
    dynamic_prefix = Bytes[4, 0, 0, 0, 0, 0, 0, 0, 1, CrystalClick::BinaryDataType::TAG_STRING]
    compact_discriminator_prefix = Bytes[1, 0, 0, 0, 0, 0, 0, 0]
    chunks << dynamic_prefix
    chunks << compact_discriminator_prefix
    events << CrystalClick::ObjectSharedPathSubstreamEvent.new(
      ".child.x.dynamic_structure",
      object_prefix.size.to_u64,
    )
    events << CrystalClick::ObjectSharedPathSubstreamEvent.new(
      ".child.x.variant_discr_prefix",
      (object_prefix.size + dynamic_prefix.size).to_u64,
    )
  end

  total_size = chunks.sum(&.size)
  data = Bytes.new(total_size)
  cursor = 0
  chunks.each do |chunk|
    chunk.each do |byte|
      data[cursor] = byte
      cursor += 1
    end
  end
  {data, events}
end

private def w240_read_inline_depth_prefix(
  has_dynamic_path : Bool,
  profile : CrystalClick::BinaryBulkProfile,
  max_depth : Int32 = 32_i32,
  json_depth : Int32 = 3_i32,
  array_level : UInt64 = 2_u64,
)
  data, events = w240_inline_depth_prefix_tape(has_dynamic_path)
  limits = CrystalClick::BinaryCodecLimits.new(max_depth, 4_096, 1_000_000, 4_096)
  budget = CrystalClick::BinaryCodecBudget.new(limits, false)
  tape = CrystalClick::ObjectSharedPathTapeReader.new(data, events, budget)
  json_type = CrystalClick::BinaryDataType.json(
    max_dynamic_paths: 1,
    max_dynamic_types: 1,
    typed_paths: {"number" => CrystalClick::BinaryDataType.primitive("UInt8")},
  )
  nested_context = CrystalClick::ObjectSharedNestedSerializationContext.for_read(0_u64, profile)
  prefix = CrystalClick::ObjectDocumentInlinePlanReader.read_json_leaf_prefix(
    tape,
    json_type,
    CrystalClick::BinaryDynamicJsonLeafKey.new("outer", 0, [] of Int32),
    json_depth,
    ".child",
    ".child",
    array_level,
    nested_context,
    budget,
  )
  tape.finish!
  {prefix, budget}
end

describe "W240 inline child inherited JSON depth adversary" do
  it "keeps the typed descriptor at JSON depth plus one and uses plus one for an empty inferred roster" do
    [
      CrystalClick::BinaryBulkProfile.single_stream,
      CrystalClick::BinaryBulkProfile.with_size_stream,
    ].each do |profile|
      prefix, _budget = w240_read_inline_depth_prefix(false, profile)
      prefix.json_descriptor_depth.should eq(3_i32)
      prefix.typed_descriptor_root_depth.should eq(4_i32)
      prefix.inferred_actual_root_depth.should eq(4_i32)
      prefix.array_level.should eq(2_u64)
      prefix.nested_context.profile.should eq(profile)
      prefix.structures.object.dynamic_path_count.should eq(0)
      prefix.plan.typed_path_count.should eq(1)
    end
  end

  it "keeps typed fields at plus one but moves inferred actual sites to plus two when the child has Dynamic paths" do
    # BinaryDynamicBulkJsonObjectWriter#finish_leaf_streams_internal and
    # BinaryDynamicBulkJsonObjectReader#child_inferred_actual_root_depth use
    # this child-layout distinction. String0/1 is inherited independently;
    # Object and Dynamic prefixes here are raw mode-NONE bytes, with the
    # Dynamic discriminator prefix retaining Compact framing.
    [
      CrystalClick::BinaryBulkProfile.single_stream,
      CrystalClick::BinaryBulkProfile.with_size_stream,
    ].each do |profile|
      prefix, _budget = w240_read_inline_depth_prefix(true, profile)
      prefix.json_descriptor_depth.should eq(3_i32)
      prefix.typed_descriptor_root_depth.should eq(4_i32)
      prefix.inferred_actual_root_depth.should eq(5_i32)
      prefix.array_level.should eq(2_u64)
      prefix.nested_context.profile.should eq(profile)
      prefix.structures.object.dynamic_paths.should eq(["x"])
      # Canonical Dynamic rosters include the implicit SharedVariant arm in
      # addition to this observed String arm.
      prefix.root_dynamic_plan_for("x").arm_count("root").should eq(2)
    end
  end

  it "carries the inferred actual origin through the physical plan at its depth boundary" do
    # The synthetic String arm itself is at depth 5, not depth 6. Therefore a
    # depth-5 limit should accept this prefix; the discriminating assertion is
    # that both stored plans retain the +2 inherited origin, not that the
    # primitive arm is spuriously rejected.
    [
      CrystalClick::BinaryBulkProfile.single_stream,
      CrystalClick::BinaryBulkProfile.with_size_stream,
    ].each do |profile|
      prefix, budget = w240_read_inline_depth_prefix(true, profile, max_depth: 5_i32)
      prefix.inferred_actual_root_depth.should eq(5_i32)
      prefix.plan.inferred_actual_root_depth.should eq(5_i32)

      physical_plan = CrystalClick::ObjectSharedPathJsonTapeCodec.physical_plan_for_prefix(prefix, budget)
      physical_plan.inferred_actual_root_depth.should eq(5_i32)
      physical_plan.initial_array_level.should eq(2_u64)

      prefix_names = CrystalClick::ObjectDocumentInlineCallbackOrder.prefix_names(
        physical_plan,
        prefix.plan,
        budget,
      )
      body_names = CrystalClick::ObjectDocumentInlineCallbackOrder.body_names(
        physical_plan,
        prefix.plan,
        profile,
        budget,
      )
      prefix_names.should contain(physical_plan.dynamic_structure_stream("x"))
      body_names.should contain(physical_plan.discriminator_stream("x"))
    end
  end

  it "keeps nested typed JSON descendants outside this inline child frontier" do
    data, events = w240_inline_depth_prefix_tape(false)
    budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, false)
    tape = CrystalClick::ObjectSharedPathTapeReader.new(data, events, budget)
    nested_json = CrystalClick::BinaryDataType.json(max_dynamic_paths: 0, max_dynamic_types: 0)
    json_type = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 0,
      max_dynamic_types: 0,
      typed_paths: {"child" => CrystalClick::BinaryDataType.array(nested_json)},
    )
    context = CrystalClick::ObjectSharedNestedSerializationContext.for_read(
      0_u64,
      CrystalClick::BinaryBulkProfile.single_stream,
    )

    expect_raises(CrystalClick::UnsupportedFormatError, "nested JSON typed fields are outside the inline child-plan frontier") do
      CrystalClick::ObjectDocumentInlinePlanReader.read_json_leaf_prefix(
        tape,
        json_type,
        CrystalClick::BinaryDynamicJsonLeafKey.new("outer", 0, [] of Int32),
        3_i32,
        ".child",
        ".child",
        2_u64,
        context,
        budget,
      )
    end
  end
end
