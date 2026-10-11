require "./spec_helper"

private def w263_lifecycle_inline_prefix
  budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
  # Independently authored Object V3 prefix: no Dynamic paths, MAP, NONE
  # statistics. This is the existing inline lifecycle, not Compact admission.
  bytes = Bytes[4, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  tape = CrystalClick::ObjectSharedPathTapeReader.new(
    bytes,
    [CrystalClick::ObjectSharedPathSubstreamEvent.new(".child.object_structure", 0_u64)],
    budget,
  )
  prefix = CrystalClick::ObjectDocumentInlinePlanReader.read_json_leaf_prefix(
    tape,
    CrystalClick::BinaryDataType.json(max_dynamic_paths: 0, max_dynamic_types: 1),
    CrystalClick::BinaryDynamicJsonLeafKey.new("outer", 0, [] of Int32),
    1_i32,
    ".child",
    ".child",
    0_u64,
    CrystalClick::ObjectSharedNestedSerializationContext.for_read(0_u64, CrystalClick::BinaryBulkProfile.single_stream),
    budget,
  )
  tape.finish!
  {prefix, budget}
end

private def w263_lifecycle_body_tape(bytes : Bytes, offsets : Array(UInt64), budget)
  events = offsets.map do |offset|
    CrystalClick::ObjectSharedPathSubstreamEvent.new(".child.value", offset)
  end
  CrystalClick::ObjectSharedPathTapeReader.new(bytes, events, budget)
end

private def w263_lifecycle_physical_plan(prefix, budget)
  CrystalClick::ObjectDocumentPhysicalPlan.from_escaped_prefix(
    prefix.physical_prefix,
    prefix.plan,
    prefix.nested_context.profile,
    CrystalClick::BinaryBulkProfile.single_stream,
    budget.limits,
    prefix.array_level,
    typed_descriptor_root_depth: prefix.typed_descriptor_root_depth,
    inferred_actual_root_depth: prefix.inferred_actual_root_depth,
    root_dynamic_json_budget: budget,
  )
end

private def w263_lifecycle_bind_owner(prefix, physical, budget)
  prefix.bind_physical_plan!(physical)
  schedule = CrystalClick::ObjectDocumentInlineCallbackEvents.new(
    {prefix.physical_prefix, prefix.callback_prefix, physical, prefix.plan},
    [] of CrystalClick::ObjectDocumentInlineCallbackOrder::CallbackOwner,
    budget,
  )
  prefix.bind_event_schedule_context!(schedule, prefix.physical_prefix, budget)
end

private def w263_lifecycle_scheduled_body_tape(prefix, physical, budget)
  pairs = CrystalClick::ObjectDocumentInlineCallbackOrder.body_callback_pairs(
    physical,
    prefix.plan,
    prefix.nested_context.profile,
    prefix.callback_prefix,
    budget,
  )
  bytes = Bytes.new(pairs.size, 0x61_u8)
  events = pairs.map_with_index do |pair, index|
    CrystalClick::ObjectSharedPathSubstreamEvent.new(pair[1], index.to_u64)
  end
  {CrystalClick::ObjectSharedPathTapeReader.new(bytes, events, budget), pairs}
end

describe "W263 shared Object prefix lifecycle preserves inline guards" do
  it "does not expose body callbacks before capture is complete" do
    prefix, budget = w263_lifecycle_inline_prefix
    prefix.capture_json_leaf_body_start!
    expect_raises(ArgumentError, /completely captured/) do
      prefix.body_callback_at(0, budget)
    end
    prefix.capture_json_leaf_body_finish!(0)
    prefix.body_callback_count.should eq(0)
  end

  it "rejects a callback before capture starts without advancing its source" do
    prefix, budget = w263_lifecycle_inline_prefix
    tape = w263_lifecycle_body_tape(Bytes[0x11], [0_u64], budget)
    expect_raises(CrystalClick::CorruptPartError, /capture phase/) do
      prefix.capture_json_leaf_body_event!(".child.value", ".child.value", tape, budget)
    end
    tape.take_exact(".child.value", 1).should eq(Bytes[0x11])
    tape.finish!
  end

  it "rejects a callback after capture finishes without advancing its source" do
    prefix, budget = w263_lifecycle_inline_prefix
    prefix.capture_json_leaf_body_start!
    prefix.capture_json_leaf_body_finish!(0)
    tape = w263_lifecycle_body_tape(Bytes[0x22], [0_u64], budget)
    expect_raises(CrystalClick::CorruptPartError, /capture phase/) do
      prefix.capture_json_leaf_body_event!(".child.value", ".child.value", tape, budget)
    end
    tape.take_exact(".child.value", 1).should eq(Bytes[0x22])
    tape.finish!
  end

  it "rejects a duplicate owner callback before advancing its source" do
    prefix, budget = w263_lifecycle_inline_prefix
    tape = w263_lifecycle_body_tape(Bytes[0x31, 0x32], [0_u64, 1_u64], budget)
    prefix.capture_json_leaf_body_start!
    prefix.capture_json_leaf_body_event!(".child.value", ".child.value", tape, budget)
    expect_raises(CrystalClick::CorruptPartError, /duplicated/) do
      prefix.capture_json_leaf_body_event!(".child.value", ".child.value", tape, budget)
    end
    tape.take_exact(".child.value", 1).should eq(Bytes[0x32])
    tape.finish!
    prefix.capture_json_leaf_body_finish!(1)
    prefix.body_callback_count.should eq(1)
    prefix.body_callback_at(0, budget)[1].should eq(Bytes[0x31])
  end

  it "rejects a repeated whole-body capture before advancing its source" do
    prefix, budget = w263_lifecycle_inline_prefix
    physical = w263_lifecycle_physical_plan(prefix, budget)
    prefix.capture_json_leaf_body_finish!(0)
    tape = w263_lifecycle_body_tape(Bytes[0x41], [0_u64], budget)
    expect_raises(CrystalClick::CorruptPartError, /more than once/) do
      prefix.capture_json_leaf_body!(tape, physical, prefix.nested_context.profile, budget)
    end
    tape.take_exact(".child.value", 1).should eq(Bytes[0x41])
    tape.finish!
  end

  it "preflights an exhausted capture budget before advancing its source" do
    prefix, source_budget = w263_lifecycle_inline_prefix
    tape = w263_lifecycle_body_tape(Bytes[0x51], [0_u64], source_budget)
    capture_budget = CrystalClick::BinaryCodecBudget.new(
      CrystalClick::BinaryCodecLimits.new(64, 0, 16, 64),
    )
    prefix.capture_json_leaf_body_start!
    expect_raises(CrystalClick::CorruptPartError, /node limit/) do
      prefix.capture_json_leaf_body_event!(".child.value", ".child.value", tape, capture_budget)
    end
    tape.take_exact(".child.value", 1).should eq(Bytes[0x51])
    tape.finish!
    prefix.capture_json_leaf_body_finish!(0)
  end

  it "rejects a distinct physical plan with the same canonical root before consuming callbacks" do
    prefix, budget = w263_lifecycle_inline_prefix
    owner = w263_lifecycle_physical_plan(prefix, budget)
    other = w263_lifecycle_physical_plan(prefix, budget)
    owner.same?(other).should be_false
    w263_lifecycle_bind_owner(prefix, owner, budget)
    tape, pairs = w263_lifecycle_scheduled_body_tape(prefix, other, budget)
    pairs.should_not be_empty
    expect_raises(CrystalClick::CorruptPartError, /physical owner/) do
      prefix.capture_json_leaf_body!(tape, other, prefix.nested_context.profile, budget)
    end
    pairs.each do |pair|
      tape.take_exact(pair[1], 1).should eq(Bytes[0x61])
    end
    tape.finish!
    prefix.capture_json_leaf_body_finish!(0)
  end

  it "captures a whole body using its exact retained physical owner" do
    prefix, budget = w263_lifecycle_inline_prefix
    physical = w263_lifecycle_physical_plan(prefix, budget)
    w263_lifecycle_bind_owner(prefix, physical, budget)
    tape, pairs = w263_lifecycle_scheduled_body_tape(prefix, physical, budget)
    pairs.should_not be_empty
    prefix.capture_json_leaf_body!(tape, physical, prefix.nested_context.profile, budget)
    prefix.body_callback_count.should eq(pairs.size)
    prefix.body_role_bindings.size.should eq(pairs.size)
    prefix.body_callback_pairs.should eq(pairs)
    pairs.each_with_index do |pair, index|
      prefix.body_callback_at(index, budget).should eq({pair[0], Bytes[0x61]})
    end
    tape.finish!
  end
end
