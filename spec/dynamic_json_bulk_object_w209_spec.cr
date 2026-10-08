require "./spec_helper"

private def w209_json_type(max_dynamic_types : Int = 1) : CrystalClick::BinaryDataType
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  nullable_uint8 = CrystalClick::BinaryDataType.nullable(uint8)
  CrystalClick::BinaryDataType.json(
    max_dynamic_paths: 1,
    max_dynamic_types: max_dynamic_types,
    typed_paths: {
      "id"    => uint8,
      "maybe" => nullable_uint8,
    } of String => CrystalClick::BinaryDataType,
  )
end

private def w209_object_plan(
  json_type : CrystalClick::BinaryDataType,
  dynamic_actual : CrystalClick::BinaryDataType = CrystalClick::BinaryDataType.primitive("UInt64"),
  dynamic_path : String = "counter",
) : CrystalClick::ObjectDocumentPlan
  structures = CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new([dynamic_path] of String),
    {dynamic_path => CrystalClick::DynamicStructure.new([dynamic_actual] of CrystalClick::BinaryDataType)},
  )
  CrystalClick::ObjectDocumentPlan.new(structures, json_type.json_type.not_nil!.typed_paths)
end

private def w209_json_value(
  json_type : CrystalClick::BinaryDataType,
  id : UInt8,
  counter : UInt64,
) : CrystalClick::BinaryValue
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  nullable_uint8 = CrystalClick::BinaryDataType.nullable(uint8)
  row = CrystalClick::BinaryJsonRow.new(
    json_type,
    [
      {"id", CrystalClick::BinaryValue.fixed(uint8, Bytes[id])},
      {"maybe", CrystalClick::BinaryValue.null(nullable_uint8)},
      {"counter", CrystalClick::BinaryValue.uint64(counter)},
    ] of Tuple(String, CrystalClick::BinaryValue),
  )
  CrystalClick::BinaryValue.json(json_type, row)
end

private def w209_plan_inputs(
  site : String,
  used_index : Int32,
  unused_index : Int32,
  used_plan : CrystalClick::ObjectDocumentPlan,
  unused_plan : CrystalClick::ObjectDocumentPlan,
) : Array(Tuple(String, Int32, CrystalClick::ObjectDocumentPlan))
  [
    {site, used_index, used_plan},
    {site, unused_index, unused_plan},
  ] of Tuple(String, Int32, CrystalClick::ObjectDocumentPlan)
end

private def w209_rows(
  array_type : CrystalClick::BinaryDataType,
  dynamic_type : CrystalClick::BinaryDataType,
  json_used : CrystalClick::BinaryDataType,
  uint8 : CrystalClick::BinaryDataType,
) : Array(Array(CrystalClick::BinaryValue))
  empty = CrystalClick::BinaryValue.array(array_type, [] of CrystalClick::BinaryValue)
  mark0_first = empty
  mark0_second = empty
  mark1 = CrystalClick::BinaryValue.array(array_type, [
    CrystalClick::BinaryValue.dynamic(dynamic_type, CrystalClick::BinaryValue.fixed(uint8, Bytes[17_u8])),
    CrystalClick::BinaryValue.dynamic(dynamic_type, CrystalClick::BinaryValue.fixed(uint8, Bytes[18_u8])),
  ] of CrystalClick::BinaryValue)
  mark2 = CrystalClick::BinaryValue.array(array_type, [
    CrystalClick::BinaryValue.dynamic(dynamic_type, w209_json_value(json_used, 41_u8, 401_u64)),
    CrystalClick::BinaryValue.dynamic(dynamic_type, w209_json_value(json_used, 42_u8, 402_u64)),
    CrystalClick::BinaryValue.dynamic(dynamic_type, CrystalClick::BinaryValue.fixed(uint8, Bytes[19_u8])),
  ] of CrystalClick::BinaryValue)
  [
    [mark0_first, mark0_second] of CrystalClick::BinaryValue,
    [mark1] of CrystalClick::BinaryValue,
    [mark2] of CrystalClick::BinaryValue,
  ] of Array(CrystalClick::BinaryValue)
end

private def w209_fixture : Tuple(
  CrystalClick::BinaryDataType,
  Hash(String, CrystalClick::DynamicStructure),
  Array(Array(CrystalClick::BinaryValue)),
  Array(Tuple(String, Int32, CrystalClick::ObjectDocumentPlan)),
  CrystalClick::BinaryDataType,
  CrystalClick::BinaryDataType,
)
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  dynamic_type = CrystalClick::BinaryDataType.dynamic(3)
  array_type = CrystalClick::BinaryDataType.array(dynamic_type)
  json_used = w209_json_type(1)
  json_unused = w209_json_type(2)
  structure = CrystalClick::DynamicStructure.new(
    [json_used, json_unused, uint8] of CrystalClick::BinaryDataType,
  )
  site = "root.elements"
  structures = {site => structure}
  used_index = structure.canonical_index_for(json_used)
  unused_index = structure.canonical_index_for(json_unused)
  plans = w209_plan_inputs(
    site,
    used_index,
    unused_index,
    w209_object_plan(json_used),
    w209_object_plan(json_unused),
  )
  rows = w209_rows(
    array_type,
    dynamic_type,
    json_used,
    uint8,
  )
  {array_type, structures, rows, plans, json_used, json_unused}
end

private def w209_pair_with_data(
  source : CrystalClick::BinaryDynamicBulkStreams,
  data : CrystalClick::BinaryBulkStreams,
) : CrystalClick::BinaryDynamicBulkStreams
  objects = Hash(Tuple(String, Int32), CrystalClick::ObjectDocumentStreams).new
  source.json_object_keys.each do |key|
    objects[key] = source.json_object_for(key[0], key[1])
  end
  CrystalClick::BinaryDynamicBulkStreams.new(source.structures, data, objects)
end

private def w209_pair_with_objects(
  source : CrystalClick::BinaryDynamicBulkStreams,
  objects : Hash(Tuple(String, Int32), CrystalClick::ObjectDocumentStreams),
) : CrystalClick::BinaryDynamicBulkStreams
  CrystalClick::BinaryDynamicBulkStreams.new(source.structures, source.data, objects)
end

private def w209_data_with_stream(
  source : CrystalClick::BinaryBulkStreams,
  role : String,
  bytes : Bytes,
  offsets : Array(UInt64),
) : CrystalClick::BinaryBulkStreams
  lanes = Hash(String, CrystalClick::BinaryBulkStream).new
  source.roles.each do |candidate|
    lane = source.stream(candidate)
    lanes[candidate] = if candidate == role
                         CrystalClick::BinaryBulkStream.new(bytes, offsets)
                       else
                         CrystalClick::BinaryBulkStream.new(lane.bytes, lane.offsets)
                       end
  end
  CrystalClick::BinaryBulkStreams.new(source.mark_count, lanes)
end

private def w209_child_with_wrong_roster(
  child : CrystalClick::ObjectDocumentStreams,
) : CrystalClick::ObjectDocumentStreams
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  wrong_structures = CrystalClick::ObjectDynamicStructureCodec.encode(
    CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(["counter"] of String),
      {"counter" => CrystalClick::DynamicStructure.new([uint8] of CrystalClick::BinaryDataType)},
    ),
  )
  typed = Hash(String, CrystalClick::BinaryBulkStreams).new
  child.typed_paths.each { |path| typed[path] = child.typed_for(path) }
  dynamics = Hash(String, CrystalClick::DynamicValueStreams).new
  child.dynamic_paths.each { |path| dynamics[path] = child.dynamic_for(path) }
  shared = Array(CrystalClick::BinaryBulkStreams).new(child.shared_bucket_count) do |index|
    child.shared_bucket(index)
  end
  CrystalClick::ObjectDocumentStreams.new(
    wrong_structures,
    child.rows_per_mark,
    typed,
    dynamics,
    shared,
  )
end

private def w209_depth_limits(depth : Int) : CrystalClick::BinaryCodecLimits
  limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
  CrystalClick::BinaryCodecLimits.new(
    max_depth: depth,
    max_nodes: limits.max_nodes,
    max_elements: limits.max_elements,
    max_bytes: limits.max_bytes,
  )
end

private def w209_node_limits(max_nodes : Int) : CrystalClick::BinaryCodecLimits
  limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
  CrystalClick::BinaryCodecLimits.new(
    max_depth: limits.max_depth,
    max_nodes: max_nodes,
    max_elements: limits.max_elements,
    max_bytes: limits.max_bytes,
  )
end

private def w209_unsorted_object_plan(
  json_type : CrystalClick::BinaryDataType,
) : CrystalClick::ObjectDocumentPlan
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
  object_statistics = CrystalClick::StructureStatistics.new(
    [7_u64, 9_u64] of UInt64,
    [] of CrystalClick::StructureStatistic,
  )
  dynamic_statistics = CrystalClick::StructureStatistics.new(
    [1_u64, 2_u64, 3_u64] of UInt64,
    [] of CrystalClick::StructureStatistic,
  )
  structures = CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new(
      ["z_path", "a_path"] of String,
      statistics: object_statistics,
    ),
    {
      "z_path" => CrystalClick::DynamicStructure.new([uint64, uint8] of CrystalClick::BinaryDataType, dynamic_statistics),
      "a_path" => CrystalClick::DynamicStructure.new([uint8, uint64] of CrystalClick::BinaryDataType, dynamic_statistics),
    } of String => CrystalClick::DynamicStructure,
  )
  CrystalClick::ObjectDocumentPlan.new(
    structures,
    json_type.json_type.not_nil!.typed_paths,
  )
end

module CrystalClick::W209ObjectChildBudgetProbe
  class_property enabled = false
  class_property entries = [] of Tuple(String, CrystalClick::BinaryCodecBudget, Int64)
  class_property completions = [] of Tuple(String, CrystalClick::BinaryCodecBudget, Int64, Int64)

  def self.begin : Nil
    self.entries = [] of Tuple(String, CrystalClick::BinaryCodecBudget, Int64)
    self.completions = [] of Tuple(String, CrystalClick::BinaryCodecBudget, Int64, Int64)
    self.enabled = true
  end

  def self.finish : Nil
    self.enabled = false
  end

  def self.enter(operation : String, budget : CrystalClick::BinaryCodecBudget) : Int64
    entry_nodes = budget.node_count
    entries << {operation, budget, entry_nodes} if enabled
    entry_nodes
  end

  def self.complete(operation : String, budget : CrystalClick::BinaryCodecBudget, entry_nodes : Int64) : Nil
    completions << {operation, budget, entry_nodes, budget.node_count} if enabled
  end
end

# Disabled-by-default exact-signature probes show that the normalized W209
# writer and reader pass their original operation budget into the Object child
# owner. The fixture does not use W184's separately loaded probe module.
module CrystalClick::ObjectDocumentCodec
  def self.encode_child_site_with_budget(
    plan : ObjectDocumentPlan,
    granules : Array(Array(ObjectDocument)),
    grid : StorageOccurrenceGrid,
    budget : BinaryCodecBudget,
    mode : UInt64 = DynamicDiscriminatorCodec::BASIC_MODE,
    profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
    shared_profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
    typed_descriptor_root_depth : Int32 = 2,
    inferred_actual_root_depth : Int32? = nil,
  ) : ObjectDocumentStreams
    entry_nodes = W209ObjectChildBudgetProbe.enter("encode", budget)
    result = previous_def(
      plan, granules, grid, budget, mode: mode, profile: profile,
      shared_profile: shared_profile, typed_descriptor_root_depth: typed_descriptor_root_depth,
      inferred_actual_root_depth: inferred_actual_root_depth,
    )
    W209ObjectChildBudgetProbe.complete("encode", budget, entry_nodes)
    result
  end

  def self.decode_child_site_with_budget(
    typed_schema : Hash(String, BinaryDataType),
    streams : ObjectDocumentStreams,
    grid : StorageOccurrenceGrid,
    budget : BinaryCodecBudget,
    first_mark : Int = 0,
    mark_count : Int? = nil,
    profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
    shared_profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
    typed_dynamic_json_object_leaf_plans : Hash(String, Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan))) = Hash(String, Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan))).new,
    typed_descriptor_root_depth : Int32 = 2,
    root_dynamic_json_object_leaf_plans : RootDynamicJsonLeafPlans = RootDynamicJsonLeafPlans.new,
    inferred_actual_root_depth : Int32 = 1_i32,
    physical_root_dynamic_json_object_leaf_loader : PhysicalRootDynamicJsonObjectLeafLoader? = nil,
  ) : Array(Array(ObjectDocument))
    entry_nodes = W209ObjectChildBudgetProbe.enter("decode", budget)
    result = previous_def(
      typed_schema,
      streams,
      grid,
      budget,
      first_mark: first_mark,
      mark_count: mark_count,
      profile: profile,
      shared_profile: shared_profile,
      typed_dynamic_json_object_leaf_plans: typed_dynamic_json_object_leaf_plans,
      typed_descriptor_root_depth: typed_descriptor_root_depth,
      root_dynamic_json_object_leaf_plans: root_dynamic_json_object_leaf_plans,
      inferred_actual_root_depth: inferred_actual_root_depth,
      physical_root_dynamic_json_object_leaf_loader: physical_root_dynamic_json_object_leaf_loader,
    )
    W209ObjectChildBudgetProbe.complete("decode", budget, entry_nodes)
    result
  end
end

private def w209_unused_typed_dynamic_depth_fixture : Tuple(
  CrystalClick::BinaryDataType,
  Hash(String, CrystalClick::DynamicStructure),
  Array(Array(CrystalClick::BinaryValue)),
  Array(Tuple(String, Int32, CrystalClick::ObjectDocumentPlan)),
)
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  actual = CrystalClick::BinaryDataType.array(
    CrystalClick::BinaryDataType.array(uint8),
  )
  typed_dynamic = CrystalClick::BinaryDataType.dynamic(1)
  json_type = CrystalClick::BinaryDataType.json(
    max_dynamic_paths: 1,
    max_dynamic_types: 1,
    typed_paths: {"nested" => typed_dynamic} of String => CrystalClick::BinaryDataType,
  )
  parent_dynamic = CrystalClick::BinaryDataType.dynamic(1)
  parent_type = CrystalClick::BinaryDataType.array(parent_dynamic)
  structure = CrystalClick::DynamicStructure.new([json_type] of CrystalClick::BinaryDataType)
  site = "root.elements"
  structures = {site => structure}
  index = structure.canonical_index_for(json_type)
  empty_objects = CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new([] of String),
    {} of String => CrystalClick::DynamicStructure,
  )
  object_plan = CrystalClick::ObjectDocumentPlan.new(
    empty_objects,
    json_type.json_type.not_nil!.typed_paths,
    {"nested" => CrystalClick::DynamicStructure.new([actual] of CrystalClick::BinaryDataType)},
  )
  plans = [{site, index, object_plan}] of Tuple(String, Int32, CrystalClick::ObjectDocumentPlan)
  empty_array = CrystalClick::BinaryValue.array(parent_type, [] of CrystalClick::BinaryValue)
  rows = [[empty_array] of CrystalClick::BinaryValue] of Array(CrystalClick::BinaryValue)
  {parent_type, structures, rows, plans}
end

describe "W209 normalized Dynamic JSON Object stop-owner" do
  it "consumes exact direct JSON arms, preserving the complete P/Q/R grid and typed NULLs" do
    type, structures, rows, plans, json_used, json_unused = w209_fixture
    structure = structures["root.elements"]
    used_index = structure.canonical_index_for(json_used)
    unused_index = structure.canonical_index_for(json_unused)

    streams = CrystalClick::BinaryDynamicBulkCodec.encode(
      type,
      structures,
      rows,
      json_object_plans: plans,
    )

    # P is the parent mark row count, Q is the Array element schedule, and R
    # is one exact Dynamic JSON arm's selected child-document count.
    streams.data.mark_count.should eq(3)
    streams.data.roles.should eq([
      "root.elements.arm.#{structure.shared_index}.data",
      "root.elements.arm.#{structure.canonical_index_for(CrystalClick::BinaryDataType.primitive("UInt8"))}.data",
      "root.elements.discriminators",
      "root.sizes",
    ].sort)
    streams.data.stream("root.elements.discriminators").bytes.should eq(Bytes[
      3_u8, 3_u8, 0_u8, 0_u8, 3_u8,
    ])
    streams.data.stream("root.elements.discriminators").offsets.should eq([
      0_u64, 0_u64, 2_u64, 5_u64,
    ])
    streams.json_object_for("root.elements", used_index).rows_per_mark.should eq([
      0_u64, 0_u64, 2_u64,
    ])
    streams.json_object_for("root.elements", unused_index).rows_per_mark.should eq([
      0_u64, 0_u64, 0_u64,
    ])

    decoded = CrystalClick::BinaryDynamicBulkCodec.decode(
      type,
      streams,
      [2_u64, 1_u64, 1_u64],
      json_object_plans: plans,
    )
    decoded.size.should eq(3)
    decoded.map(&.size).should eq([2, 1, 1])
    decoded[0].each { |parent| parent.element_count.should eq(0) }
    decoded[1][0].element_count.should eq(2)
    decoded[2][0].element_count.should eq(3)

    first_json = decoded[2][0].element_at(0).child_at(0).json_row
    second_json = decoded[2][0].element_at(1).child_at(0).json_row
    first_json.value_for("id").not_nil!.byte_at(0).should eq(41_u8)
    second_json.value_for("id").not_nil!.byte_at(0).should eq(42_u8)
    first_json.value_for("maybe").not_nil!.is_null?.should be_true
    second_json.value_for("maybe").not_nil!.is_null?.should be_true
    first_json.value_for("counter").not_nil!.as_uint64.should eq(401_u64)
    second_json.value_for("counter").not_nil!.as_uint64.should eq(402_u64)

    partial = CrystalClick::BinaryDynamicBulkCodec.decode(
      type,
      streams,
      [2_u64, 1_u64, 1_u64],
      first_mark: 2,
      mark_count: 1,
      json_object_plans: plans,
    )
    partial.size.should eq(1)
    partial[0][0].element_count.should eq(3)
  end

  it "requires a binding for every direct JSON arm, including an unused arm" do
    type, structures, rows, plans, _, _ = w209_fixture
    site = "root.elements"

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDynamicBulkCodec.encode(type, structures, rows)
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDynamicBulkCodec.encode(
        type,
        structures,
        rows,
        json_object_plans: [plans[0]] of Tuple(String, Int32, CrystalClick::ObjectDocumentPlan),
      )
    end

    expect_raises(ArgumentError) do
      CrystalClick::BinaryDynamicBulkCodec.encode(
        type,
        structures,
        rows,
        json_object_plans: [plans[0], plans[0]] of Tuple(String, Int32, CrystalClick::ObjectDocumentPlan),
      )
    end
    expect_raises(ArgumentError) do
      wrong_site_plans = [
        {"root.other", plans[0][1], plans[0][2]},
        plans[1],
      ] of Tuple(String, Int32, CrystalClick::ObjectDocumentPlan)
      CrystalClick::BinaryDynamicBulkCodec.encode(
        type,
        structures,
        rows,
        json_object_plans: wrong_site_plans,
      )
    end
    expect_raises(ArgumentError) do
      extra_plans = plans + [plans[0]]
      CrystalClick::BinaryDynamicBulkCodec.encode(
        type,
        structures,
        rows,
        json_object_plans: extra_plans,
      )
    end
  end

  it "keeps nominal wrapped JSON rejected and requires an exact leaf Object binding for Dynamic actuals" do
    json_type = w209_json_type
    wrapped = CrystalClick::BinaryDataType.array(json_type)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkTypePlan.new(wrapped, CrystalClick::BinaryBulkProfile.single_stream)
    end

    # Dynamic metadata accepts the ordinary wrapped actual roster; physical
    # planning still requires a binding for its exact JSON leaf path [0].
    structure = CrystalClick::DynamicStructure.new([wrapped] of CrystalClick::BinaryDataType)
    structure.types.should eq([wrapped] of CrystalClick::BinaryDataType)
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    parent_type = CrystalClick::BinaryDataType.array(dynamic)
    site = "root.elements"
    error = expect_raises(ArgumentError) do
      CrystalClick::BinaryDynamicBulkPlan.new_with_budget(
        parent_type,
        {site => structure} of String => CrystalClick::DynamicStructure,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, true),
        json_object_leaf_plans: [] of Tuple(
          CrystalClick::BinaryDynamicJsonLeafKey, CrystalClick::ObjectDocumentPlan,
        ),
      )
    end
    error.message.to_s.should contain("exactly cover every JSON leaf")
  end

  it "validates every parent mark before returning an empty window" do
    type, structures, rows, plans, _, _ = w209_fixture
    streams = CrystalClick::BinaryDynamicBulkCodec.encode(type, structures, rows, json_object_plans: plans)

    selected_none = CrystalClick::BinaryDynamicBulkCodec.decode(
      type,
      streams,
      [2_u64, 1_u64, 1_u64],
      first_mark: 3,
      mark_count: 0,
      json_object_plans: plans,
    )
    selected_none.should eq([] of Array(CrystalClick::BinaryValue))

    role = "root.elements.discriminators"
    original = streams.data.stream(role)
    original_bytes = original.bytes
    bad_bytes = Bytes.new(original_bytes.size + 1) do |index|
      index == 0 ? 0xfe_u8 : original_bytes[index - 1]
    end
    # Mark zero gains one invalid byte; later mark offsets move by one and the
    # terminal offset still exactly matches the byte lane.
    bad_data = w209_data_with_stream(streams.data, role, bad_bytes, [0_u64, 1_u64, 3_u64, 6_u64])
    bad_streams = w209_pair_with_data(streams, bad_data)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDynamicBulkCodec.decode(
        type,
        bad_streams,
        [2_u64, 1_u64, 1_u64],
        first_mark: 3,
        mark_count: 0,
        json_object_plans: plans,
      )
    end
  end

  it "charges the eager partial-window copy under the same borrowed decode budget" do
    type, structures, rows, plans, _, _ = w209_fixture
    streams = CrystalClick::BinaryDynamicBulkCodec.encode(type, structures, rows, json_object_plans: plans)
    rows_per_mark = [2_u64, 1_u64, 1_u64]

    full_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS)
    CrystalClick::BinaryDynamicBulkCodec.decode_with_budget(
      type,
      streams,
      rows_per_mark,
      full_budget,
      json_object_plans: plans,
    )

    partial_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS)
    partial = CrystalClick::BinaryDynamicBulkCodec.decode_with_budget(
      type,
      streams,
      rows_per_mark,
      partial_budget,
      first_mark: 1,
      mark_count: 1,
      json_object_plans: plans,
    )
    partial.size.should eq(1)
    partial_budget.node_count.should eq(full_budget.node_count + 1)
    partial_budget.element_count.should eq(full_budget.element_count + 1)

    one_short_budget = CrystalClick::BinaryCodecBudget.new(
      w209_node_limits((partial_budget.node_count - 1).to_i),
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDynamicBulkCodec.decode_with_budget(
        type,
        streams,
        rows_per_mark,
        one_short_budget,
        first_mark: 1,
        mark_count: 1,
        json_object_plans: plans,
      )
    end
  end

  it "requires every unused child key and validates its metadata even for an empty selection" do
    type, structures, rows, plans, _, json_unused = w209_fixture
    streams = CrystalClick::BinaryDynamicBulkCodec.encode(type, structures, rows, json_object_plans: plans)
    unused_index = plans[1][1]
    site = plans[1][0]

    missing = Hash(Tuple(String, Int32), CrystalClick::ObjectDocumentStreams).new
    streams.json_object_keys.each do |key|
      next if key == {site, unused_index}
      missing[key] = streams.json_object_for(key[0], key[1])
    end
    missing_streams = w209_pair_with_objects(streams, missing)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDynamicBulkCodec.decode(
        type,
        missing_streams,
        [2_u64, 1_u64, 1_u64],
        first_mark: 3,
        mark_count: 0,
        json_object_plans: plans,
      )
    end

    wrong_metadata = Hash(Tuple(String, Int32), CrystalClick::ObjectDocumentStreams).new
    streams.json_object_keys.each do |key|
      child = streams.json_object_for(key[0], key[1])
      wrong_metadata[key] = key == {site, unused_index} ? w209_child_with_wrong_roster(child) : child
    end
    wrong_streams = w209_pair_with_objects(streams, wrong_metadata)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDynamicBulkCodec.decode(
        type,
        wrong_streams,
        [2_u64, 1_u64, 1_u64],
        first_mark: 3,
        mark_count: 0,
        json_object_plans: plans,
      )
    end

    # The serialized child remains internally valid. The supplied, unused
    # plan alone is wrong, so only exact child-metadata/plan association can
    # reject this zero-row arm before any adapter value check.
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    wrong_unused_plan = w209_object_plan(json_unused, uint8)
    wrong_plans = [
      plans[0],
      {site, unused_index, wrong_unused_plan},
    ] of Tuple(String, Int32, CrystalClick::ObjectDocumentPlan)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDynamicBulkCodec.decode(
        type,
        streams,
        [2_u64, 1_u64, 1_u64],
        first_mark: 3,
        mark_count: 0,
        json_object_plans: wrong_plans,
      )
    end
  end

  it "rejects a valid JSON child census hidden behind an Array Q=0 schedule" do
    type, structures, rows, plans, json_used, _ = w209_fixture
    dynamic_type = type.child_at(0)
    empty = CrystalClick::BinaryValue.array(type, [] of CrystalClick::BinaryValue)
    hidden_json = CrystalClick::BinaryValue.dynamic(
      dynamic_type,
      w209_json_value(json_used, 40_u8, 400_u64),
    )
    rows[0] = [
      CrystalClick::BinaryValue.array(type, [hidden_json] of CrystalClick::BinaryValue),
      empty,
    ] of CrystalClick::BinaryValue
    streams = CrystalClick::BinaryDynamicBulkCodec.encode(type, structures, rows, json_object_plans: plans)

    streams.json_object_for(plans[0][0], plans[0][1]).rows_per_mark.should eq([1_u64, 0_u64, 2_u64])
    discriminator = streams.data.stream("root.elements.discriminators")
    discriminator.offsets.should eq([0_u64, 1_u64, 3_u64, 6_u64])

    # The parent Array size says zero while the discriminator and corresponding
    # child stream retain a valid JSON row. Eager census alone cannot certify Q;
    # full parent consumption must reject before even an empty window returns.
    size_lane = streams.data.stream("root.sizes")
    size_bytes = size_lane.bytes
    8.times { |index| size_bytes[index] = 0_u8 }
    bad_data = w209_data_with_stream(streams.data, "root.sizes", size_bytes, size_lane.offsets)
    bad_streams = w209_pair_with_data(streams, bad_data)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDynamicBulkCodec.decode(
        type,
        bad_streams,
        [2_u64, 1_u64, 1_u64],
        first_mark: 3,
        mark_count: 0,
        json_object_plans: plans,
      )
    end
  end

  it "keeps bound JSON plans guarded at lower owners even when no JSON row is selected" do
    type, structures, _, plans, _, _ = w209_fixture
    empty_array = CrystalClick::BinaryValue.array(type, [] of CrystalClick::BinaryValue)
    rows = [
      [empty_array, empty_array] of CrystalClick::BinaryValue,
      [empty_array] of CrystalClick::BinaryValue,
      [empty_array] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)
    write_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, true)
    bound_write_plan = CrystalClick::BinaryDynamicBulkPlan.new_with_budget(type, structures, write_budget, json_object_plans: plans)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkEncoder.encode(
        type,
        rows,
        write_budget,
        CrystalClick::BinaryBulkProfile.single_stream,
        bound_write_plan,
      )
    end

    streams = CrystalClick::BinaryDynamicBulkCodec.encode(type, structures, rows, json_object_plans: plans)
    read_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS)
    bound_read_plan = CrystalClick::BinaryDynamicBulkPlan.decode_structure_streams(
      type,
      streams.structures,
      read_budget,
      CrystalClick::BinaryBulkProfile.single_stream,
      plans,
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkDecoder.decode(
        type,
        streams.data,
        [2_u64, 1_u64, 1_u64],
        read_budget,
        3,
        0,
        CrystalClick::BinaryBulkProfile.single_stream,
        bound_read_plan,
      )
    end
  end

  it "rejects a lower encoder owner when its paired JSON writer has another budget" do
    type, structures, rows, plans, _, _ = w209_fixture
    writer_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, true)
    operation_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, true)
    bound_write_plan = CrystalClick::BinaryDynamicBulkPlan.new_with_budget(
      type,
      structures,
      writer_budget,
      json_object_plans: plans,
    )
    writer = CrystalClick::BinaryDynamicBulkJsonObjectWriter.new(bound_write_plan, writer_budget, rows)
    expect_raises(ArgumentError) do
      CrystalClick::BinaryBulkEncoder.encode(
        type,
        rows,
        operation_budget,
        CrystalClick::BinaryBulkProfile.single_stream,
        bound_write_plan,
        json_object_writer: writer,
      )
    end
  end

  it "rejects a lower decoder owner when its paired JSON reader has another budget" do
    type, structures, rows, plans, _, _ = w209_fixture
    streams = CrystalClick::BinaryDynamicBulkCodec.encode(type, structures, rows, json_object_plans: plans)
    reader_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS)
    operation_read_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS)
    bound_read_plan = CrystalClick::BinaryDynamicBulkPlan.decode_structure_streams(
      type,
      streams.structures,
      reader_budget,
      CrystalClick::BinaryBulkProfile.single_stream,
      plans,
    )
    reader = CrystalClick::BinaryDynamicBulkJsonObjectReader.new(
      bound_read_plan,
      streams,
      [2_u64, 1_u64, 1_u64],
      reader_budget,
      CrystalClick::BinaryBulkProfile.single_stream,
    )
    expect_raises(ArgumentError) do
      CrystalClick::BinaryBulkDecoder.decode(
        type,
        streams.data,
        [2_u64, 1_u64, 1_u64],
        operation_read_budget,
        0,
        nil,
        CrystalClick::BinaryBulkProfile.single_stream,
        bound_read_plan,
        reader,
      )
    end
  end

  it "preflights unused typed Dynamic actuals at inherited JSON depth" do
    type, structures, rows, plans = w209_unused_typed_dynamic_depth_fixture

    # root Array=1, Dynamic=2, JSON row=3, typed Dynamic=4, actual Array=5,
    # nested Array=6, UInt8 leaf=7. The actual is metadata-only and unused.
    streams = CrystalClick::BinaryDynamicBulkCodec.encode(
      type,
      structures,
      rows,
      w209_depth_limits(7),
      json_object_plans: plans,
    )
    decoded = CrystalClick::BinaryDynamicBulkCodec.decode(
      type,
      streams,
      [1_u64],
      limits: w209_depth_limits(7),
      json_object_plans: plans,
    )
    decoded[0][0].element_count.should eq(0)

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDynamicBulkCodec.encode(
        type,
        structures,
        rows,
        w209_depth_limits(6),
        json_object_plans: plans,
      )
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDynamicBulkCodec.decode(
        type,
        streams,
        [1_u64],
        limits: w209_depth_limits(6),
        json_object_plans: plans,
      )
    end
  end

  it "matches complete Object metadata by canonical path and actual rosters, not order or statistics hints" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    nullable_uint8 = CrystalClick::BinaryDataType.nullable(uint8)
    json_type = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 2,
      max_dynamic_types: 2,
      typed_paths: {
        "id"    => uint8,
        "maybe" => nullable_uint8,
      } of String => CrystalClick::BinaryDataType,
    )
    dynamic_type = CrystalClick::BinaryDataType.dynamic(1)
    type = CrystalClick::BinaryDataType.array(dynamic_type)
    structure = CrystalClick::DynamicStructure.new([json_type] of CrystalClick::BinaryDataType)
    site = "root.elements"
    structures = {site => structure}
    arm = structure.canonical_index_for(json_type)
    plan = w209_unsorted_object_plan(json_type)
    plans = [{site, arm, plan}] of Tuple(String, Int32, CrystalClick::ObjectDocumentPlan)

    first_row = CrystalClick::BinaryJsonRow.new(json_type, [
      {"id", CrystalClick::BinaryValue.fixed(uint8, Bytes[41_u8])},
      {"maybe", CrystalClick::BinaryValue.null(nullable_uint8)},
      {"z_path", CrystalClick::BinaryValue.uint64(401_u64)},
      {"a_path", CrystalClick::BinaryValue.fixed(uint8, Bytes[7_u8])},
    ] of Tuple(String, CrystalClick::BinaryValue))
    second_row = CrystalClick::BinaryJsonRow.new(json_type, [
      {"id", CrystalClick::BinaryValue.fixed(uint8, Bytes[42_u8])},
      {"maybe", CrystalClick::BinaryValue.null(nullable_uint8)},
      {"z_path", CrystalClick::BinaryValue.uint64(402_u64)},
      {"a_path", CrystalClick::BinaryValue.fixed(uint8, Bytes[8_u8])},
    ] of Tuple(String, CrystalClick::BinaryValue))
    rows = [[CrystalClick::BinaryValue.array(type, [
      CrystalClick::BinaryValue.dynamic(dynamic_type, CrystalClick::BinaryValue.json(json_type, first_row)),
      CrystalClick::BinaryValue.dynamic(dynamic_type, CrystalClick::BinaryValue.json(json_type, second_row)),
    ] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue] of Array(CrystalClick::BinaryValue)

    streams = CrystalClick::BinaryDynamicBulkCodec.encode(
      type,
      structures,
      rows,
      json_object_plans: plans,
    )
    decoded = CrystalClick::BinaryDynamicBulkCodec.decode(
      type,
      streams,
      [1_u64],
      json_object_plans: plans,
    )
    decoded[0][0].element_count.should eq(2)
    decoded[0][0].element_at(0).child_at(0).json_row.value_for("id").not_nil!.byte_at(0).should eq(41_u8)
    decoded[0][0].element_at(0).child_at(0).json_row.value_for("z_path").not_nil!.as_uint64.should eq(401_u64)
    decoded[0][0].element_at(0).child_at(0).json_row.value_for("a_path").not_nil!.byte_at(0).should eq(7_u8)
    decoded[0][0].element_at(1).child_at(0).json_row.value_for("z_path").not_nil!.as_uint64.should eq(402_u64)
    decoded[0][0].element_at(1).child_at(0).json_row.value_for("a_path").not_nil!.byte_at(0).should eq(8_u8)
  end

  it "keeps per-site collectors independent when one immutable Object plan is shared" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    dynamic_type = CrystalClick::BinaryDataType.dynamic(1)
    tuple_type = CrystalClick::BinaryDataType.tuple([dynamic_type, dynamic_type] of CrystalClick::BinaryDataType)
    json_type = w209_json_type
    structure = CrystalClick::DynamicStructure.new([json_type] of CrystalClick::BinaryDataType)
    sites = ["root.field.0", "root.field.1"] of String
    structures = {
      sites[0] => structure,
      sites[1] => structure,
    } of String => CrystalClick::DynamicStructure
    arm = structure.canonical_index_for(json_type)
    shared_plan = w209_object_plan(json_type)
    plans = [
      {sites[0], arm, shared_plan},
      {sites[1], arm, shared_plan},
    ] of Tuple(String, Int32, CrystalClick::ObjectDocumentPlan)
    value = CrystalClick::BinaryValue.tuple(tuple_type, [
      CrystalClick::BinaryValue.dynamic(dynamic_type, w209_json_value(json_type, 61_u8, 601_u64)),
      CrystalClick::BinaryValue.dynamic(dynamic_type, w209_json_value(json_type, 62_u8, 602_u64)),
    ] of CrystalClick::BinaryValue)
    rows = [[value] of CrystalClick::BinaryValue] of Array(CrystalClick::BinaryValue)

    streams = CrystalClick::BinaryDynamicBulkCodec.encode(tuple_type, structures, rows, json_object_plans: plans)
    streams.json_object_for(sites[0], arm).rows_per_mark.should eq([1_u64])
    streams.json_object_for(sites[1], arm).rows_per_mark.should eq([1_u64])
    decoded = CrystalClick::BinaryDynamicBulkCodec.decode(tuple_type, streams, [1_u64], json_object_plans: plans)
    decoded[0][0].element_at(0).child_at(0).json_row.value_for("id").not_nil!.byte_at(0).should eq(61_u8)
    decoded[0][0].element_at(1).child_at(0).json_row.value_for("id").not_nil!.byte_at(0).should eq(62_u8)
  end

  it "borrows one operation budget into both Object child codecs and rejects cumulative one-short budgets there" do
    type, structures, rows, plans, _, _ = w209_fixture
    write_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, true)
    CrystalClick::W209ObjectChildBudgetProbe.begin
    begin
      CrystalClick::BinaryDynamicBulkCodec.encode_with_budget(
        type,
        structures,
        rows,
        write_budget,
        json_object_plans: plans,
      )
    ensure
      CrystalClick::W209ObjectChildBudgetProbe.finish
    end
    encode_entry = CrystalClick::W209ObjectChildBudgetProbe.entries.find { |event| event[0] == "encode" }.not_nil!
    encode_completion = CrystalClick::W209ObjectChildBudgetProbe.completions.find { |event| event[0] == "encode" }.not_nil!
    encode_entry[1].should be(write_budget)
    (encode_completion[3] - encode_completion[2]).should be > 0

    write_precharge = 3
    write_limit = encode_entry[2] + write_precharge + 1
    tight_write_budget = CrystalClick::BinaryCodecBudget.new(w209_node_limits(write_limit), true)
    write_precharge.times { tight_write_budget.charge_node }
    CrystalClick::W209ObjectChildBudgetProbe.begin
    begin
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryDynamicBulkCodec.encode_with_budget(
          type,
          structures,
          rows,
          tight_write_budget,
          json_object_plans: plans,
        )
      end
    ensure
      CrystalClick::W209ObjectChildBudgetProbe.finish
    end
    tight_encode_entry = CrystalClick::W209ObjectChildBudgetProbe.entries.find { |event| event[0] == "encode" }.not_nil!
    tight_encode_entry[1].should be(tight_write_budget)
    tight_encode_entry[2].should eq(encode_entry[2] + write_precharge)

    read_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS)
    CrystalClick::W209ObjectChildBudgetProbe.begin
    begin
      CrystalClick::BinaryDynamicBulkCodec.decode_with_budget(
        type,
        CrystalClick::BinaryDynamicBulkCodec.encode(type, structures, rows, json_object_plans: plans),
        [2_u64, 1_u64, 1_u64],
        read_budget,
        json_object_plans: plans,
      )
    ensure
      CrystalClick::W209ObjectChildBudgetProbe.finish
    end
    decode_entry = CrystalClick::W209ObjectChildBudgetProbe.entries.find { |event| event[0] == "decode" }.not_nil!
    decode_completion = CrystalClick::W209ObjectChildBudgetProbe.completions.find { |event| event[0] == "decode" }.not_nil!
    decode_entry[1].should be(read_budget)
    (decode_completion[3] - decode_completion[2]).should be > 0

    read_precharge = 3
    read_limit = decode_entry[2] + read_precharge + 1
    tight_read_budget = CrystalClick::BinaryCodecBudget.new(w209_node_limits(read_limit))
    read_precharge.times { tight_read_budget.charge_node }
    encoded = CrystalClick::BinaryDynamicBulkCodec.encode(type, structures, rows, json_object_plans: plans)
    CrystalClick::W209ObjectChildBudgetProbe.begin
    begin
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryDynamicBulkCodec.decode_with_budget(
          type,
          encoded,
          [2_u64, 1_u64, 1_u64],
          tight_read_budget,
          json_object_plans: plans,
        )
      end
    ensure
      CrystalClick::W209ObjectChildBudgetProbe.finish
    end
    tight_decode_entry = CrystalClick::W209ObjectChildBudgetProbe.entries.find { |event| event[0] == "decode" }.not_nil!
    tight_decode_entry[1].should be(tight_read_budget)
    tight_decode_entry[2].should eq(decode_entry[2] + read_precharge)
  end
end
