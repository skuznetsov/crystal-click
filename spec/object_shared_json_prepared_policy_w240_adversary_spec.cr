require "./spec_helper"

private def w240p_json_type(paths : Int32 = 1) : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.json(
    max_dynamic_paths: paths,
    max_dynamic_types: 1,
    typed_paths: {"v" => CrystalClick::BinaryDataType.primitive("UInt8")},
  )
end

private def w240p_child_plan(type : CrystalClick::BinaryDataType) : CrystalClick::ObjectDocumentPlan
  structures = CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new([] of String),
    {} of String => CrystalClick::DynamicStructure,
  )
  CrystalClick::ObjectDocumentPlan.new(structures, type.json_type.not_nil!.typed_paths)
end

private def w240p_prepared(paths : Int32 = 1) : CrystalClick::ObjectSharedAdvancedJsonActualPlan
  json = w240p_json_type(paths)
  CrystalClick::ObjectSharedAdvancedJsonActualPlan.new(
    CrystalClick::BinaryDataType.array(json),
    [{[0_i32], w240p_child_plan(json)}] of Tuple(Array(Int32), CrystalClick::ObjectDocumentPlan),
  )
end

private def w240p_budget : CrystalClick::BinaryCodecBudget
  CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true)
end

describe "W240 prepared shared JSON policy adversary" do
  it "detaches constructor and returned descriptor paths without losing the child binding" do
    json = w240p_json_type
    type = CrystalClick::BinaryDataType.array(json)
    child = w240p_child_plan(json)
    path = [0_i32]
    children = [{path, child}] of Tuple(Array(Int32), CrystalClick::ObjectDocumentPlan)
    actual = CrystalClick::ObjectSharedAdvancedJsonActualPlan.new(type, children)
    path[0] = 9
    children.clear
    exposed = actual.child_descriptor_path_at(0)
    exposed[0] = 7

    actual.child_plan_count.should eq(1)
    actual.child_descriptor_path_at(0).should eq([0_i32])
    actual.child_plan_for([0_i32]).should be(child)
    actual.child_plan_for([7_i32]).should be_nil

    roster = [actual] of CrystalClick::ObjectSharedAdvancedJsonActualPlan
    policy = CrystalClick::ObjectSharedAdvancedJsonWritePolicy.new(roster)
    roster.clear
    policy.actual_count.should eq(1)
    policy.actual_at(0).should be(actual)
  end

  it "requires complete unique descriptor-relative coverage even for an unused JSON leaf" do
    json = w240p_json_type
    child = w240p_child_plan(json)
    tuple = CrystalClick::BinaryDataType.tuple([json, json] of CrystalClick::BinaryDataType)
    expect_raises(ArgumentError) do
      CrystalClick::ObjectSharedAdvancedJsonActualPlan.new(
        tuple,
        [{[0_i32], child}] of Tuple(Array(Int32), CrystalClick::ObjectDocumentPlan),
      )
    end
    expect_raises(ArgumentError) do
      CrystalClick::ObjectSharedAdvancedJsonActualPlan.new(
        tuple,
        [{[0_i32], child}, {[0_i32], child}] of Tuple(Array(Int32), CrystalClick::ObjectDocumentPlan),
      )
    end
    expect_raises(ArgumentError) do
      CrystalClick::ObjectSharedAdvancedJsonActualPlan.new(
        CrystalClick::BinaryDataType.array(json),
        [{[1_i32], child}] of Tuple(Array(Int32), CrystalClick::ObjectDocumentPlan),
      )
    end
    complete = CrystalClick::ObjectSharedAdvancedJsonActualPlan.new(
      tuple,
      [{[0_i32], child}, {[1_i32], child}] of Tuple(Array(Int32), CrystalClick::ObjectDocumentPlan),
    )
    complete.child_plan_count.should eq(2)
  end

  it "does not bind an Object child whose typed schema differs from the JSON descriptor" do
    json = w240p_json_type
    wrong_json = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 1,
      max_dynamic_types: 1,
      typed_paths: {"v" => CrystalClick::BinaryDataType.primitive("UInt16")},
    )
    expect_raises(ArgumentError) do
      CrystalClick::ObjectSharedAdvancedJsonActualPlan.new(
        CrystalClick::BinaryDataType.array(json),
        [{[0_i32], w240p_child_plan(wrong_json)}] of Tuple(Array(Int32), CrystalClick::ObjectDocumentPlan),
      )
    end
  end

  it "rebinds the exact descriptor to the current canonical arm instead of retaining a prior chunk index" do
    actual = w240p_prepared
    policy = CrystalClick::ObjectSharedAdvancedJsonWritePolicy.new([actual])
    first = CrystalClick::DynamicStructure.new([actual.actual_type])
    before = CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.primitive("Int8"))
    shifted = CrystalClick::DynamicStructure.new([actual.actual_type, before])
    first_key = policy.leaf_bindings_for("root", first, w240p_budget)[0][0]
    shifted_binding = policy.leaf_bindings_for("root", shifted, w240p_budget)[0]

    first.canonical_index_for(actual.actual_type).should_not eq(shifted.canonical_index_for(actual.actual_type))
    first_key.canonical_arm_index.should eq(first.canonical_index_for(actual.actual_type))
    shifted_binding[0].canonical_arm_index.should eq(shifted.canonical_index_for(actual.actual_type))
    shifted_binding[0].descriptor_child_path.should eq([0_i32])
    shifted_binding[1].should be(actual.child_plan_at(0))
  end

  it "does not emit unobserved prepared types or stale child plans in empty and primitive-only chunks" do
    policy = CrystalClick::ObjectSharedAdvancedJsonWritePolicy.new([w240p_prepared, w240p_prepared(2)])
    primitive = CrystalClick::BinaryDataType.primitive("UInt8")
    policy.ordinary_types_for([] of CrystalClick::BinaryDataType, w240p_budget).should be_empty
    policy.ordinary_types_for([primitive], w240p_budget).should be_empty
    policy.leaf_bindings_for("root", CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType), w240p_budget).should be_empty
    policy.leaf_bindings_for("root", CrystalClick::DynamicStructure.new([primitive]), w240p_budget).should be_empty
  end

  it "rejects an unprepared JSON descriptor and a prepared roster exceeding the ordinary-type cap" do
    first = w240p_prepared
    late = w240p_prepared(2)
    policy = CrystalClick::ObjectSharedAdvancedJsonWritePolicy.new([first])
    expect_raises(CrystalClick::UnsupportedFormatError) do
      policy.ordinary_types_for([late.actual_type], w240p_budget)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      policy.leaf_bindings_for("root", CrystalClick::DynamicStructure.new([late.actual_type]), w240p_budget)
    end
    capped = CrystalClick::ObjectSharedAdvancedJsonWritePolicy.new([first, late], 1)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      capped.ordinary_types_for([first.actual_type, late.actual_type], w240p_budget)
    end
    capped.ordinary_types_for([first.actual_type, first.actual_type], w240p_budget).should eq([first.actual_type])
  end

  it "rejects duplicate policies and invalid preparation caps" do
    actual = w240p_prepared
    expect_raises(ArgumentError) do
      CrystalClick::ObjectSharedAdvancedJsonWritePolicy.new([actual, actual])
    end
    expect_raises(ArgumentError) do
      CrystalClick::ObjectSharedAdvancedJsonWritePolicy.new([] of CrystalClick::ObjectSharedAdvancedJsonActualPlan)
    end
    [0, 255].each do |cap|
      expect_raises(ArgumentError) do
        CrystalClick::ObjectSharedAdvancedJsonWritePolicy.new([actual], cap)
      end
    end
  end

  it "separates the writer directive from a reader which only knows persisted chunk sizes" do
    profile = CrystalClick::BinaryBulkProfile.single_stream
    write = CrystalClick::ObjectSharedNestedSerializationContext.for_write(3_u64, 4, profile)
    read = CrystalClick::ObjectSharedNestedSerializationContext.for_read(3_u64, profile)
    write.writing?.should be_true
    write.target_chunk_rows.should eq(4)
    read.writing?.should be_false
    read.shared_data_version.should eq(3_u64)
    read.profile.should eq(profile)
    expect_raises(ArgumentError) { read.target_chunk_rows }
    expect_raises(ArgumentError) do
      CrystalClick::ObjectSharedNestedSerializationContext.for_write(3_u64, 0, profile)
    end
    expect_raises(ArgumentError) do
      CrystalClick::ObjectSharedNestedSerializationContext.for_read(4_u64, profile)
    end
  end
end
