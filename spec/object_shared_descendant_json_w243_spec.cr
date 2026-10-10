require "./spec_helper"

private alias W243LeafBinding = Tuple(
  CrystalClick::BinaryDynamicJsonLeafKey,
  CrystalClick::ObjectDocumentPlan,
)
private alias W243LeafBindings = Array(W243LeafBinding)
private alias W243CallbackOwner = Tuple(
  String,
  String,
  CrystalClick::ObjectDocumentPhysicalPlan,
  CrystalClick::ObjectDocumentPlan,
)

private struct W243Fixture
  getter outer_json : CrystalClick::BinaryDataType
  getter leaf_json : CrystalClick::BinaryDataType
  getter great_json : CrystalClick::BinaryDataType
  getter item_array : CrystalClick::BinaryDataType
  getter item_structure : CrystalClick::DynamicStructure
  getter next_array : CrystalClick::BinaryDataType
  getter next_structure : CrystalClick::DynamicStructure
  getter child_structures : CrystalClick::ObjectDynamicStructureSet
  getter child_plan : CrystalClick::ObjectDocumentPlan
  getter actual : CrystalClick::BinaryDataType
  getter outer_type : CrystalClick::BinaryDataType
  getter structures : Hash(String, CrystalClick::DynamicStructure)
  getter nested_site : String
  getter leaf_bindings : W243LeafBindings
  getter rows : Array(CrystalClick::BinaryValue)

  def initialize
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    string = CrystalClick::BinaryDataType.primitive("String")
    @leaf_json = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 1,
      max_dynamic_types: 2,
      typed_paths: {"v" => uint8} of String => CrystalClick::BinaryDataType,
    )
    @great_json = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 0,
      max_dynamic_types: 0,
      typed_paths: {"v" => string} of String => CrystalClick::BinaryDataType,
    )
    @next_array = CrystalClick::BinaryDataType.array(@great_json)
    @next_structure = CrystalClick::DynamicStructure.new(
      [@next_array, string] of CrystalClick::BinaryDataType,
    )
    @outer_json = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 1,
      max_dynamic_types: 2,
      typed_paths: {"v" => uint8} of String => CrystalClick::BinaryDataType,
    )
    @item_array = CrystalClick::BinaryDataType.array(@leaf_json)
    @item_structure = CrystalClick::DynamicStructure.new(
      [@item_array, CrystalClick::BinaryDataType.primitive("String")] of CrystalClick::BinaryDataType,
    )

    great_grandchild_structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    )
    great_grandchild_plan = CrystalClick::ObjectDocumentPlan.new(
      great_grandchild_structures,
      @great_json.json_type.not_nil!.typed_paths,
    )
    next_key = CrystalClick::BinaryDynamicJsonLeafKey.new(
      "root",
      @next_structure.canonical_index_for(@next_array),
      [0_i32] of Int32,
    )
    grandchild_structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(["next_field"] of String),
      {"next_field" => @next_structure} of String => CrystalClick::DynamicStructure,
    )
    grandchild_plan = CrystalClick::ObjectDocumentPlan.new(
      grandchild_structures,
      @leaf_json.json_type.not_nil!.typed_paths,
      root_dynamic_json_object_leaf_plans: {
        "next_field" => [{next_key, great_grandchild_plan}] of Tuple(
          CrystalClick::BinaryDynamicJsonLeafKey,
          CrystalClick::ObjectDocumentPlan,
        ),
      } of String => Array(Tuple(CrystalClick::BinaryDynamicJsonLeafKey, CrystalClick::ObjectDocumentPlan)),
    )
    item_key = CrystalClick::BinaryDynamicJsonLeafKey.new(
      "root",
      @item_structure.canonical_index_for(@item_array),
      [0_i32] of Int32,
    )
    @child_structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(["items"] of String),
      {"items" => @item_structure} of String => CrystalClick::DynamicStructure,
    )
    child_leaf_plans = {
      "items" => [{item_key, grandchild_plan}] of Tuple(
        CrystalClick::BinaryDynamicJsonLeafKey,
        CrystalClick::ObjectDocumentPlan,
      ),
    } of String => Array(Tuple(CrystalClick::BinaryDynamicJsonLeafKey, CrystalClick::ObjectDocumentPlan))
    @child_plan = CrystalClick::ObjectDocumentPlan.new(
      @child_structures,
      @outer_json.json_type.not_nil!.typed_paths,
      root_dynamic_json_object_leaf_plans: child_leaf_plans,
    )

    nested_dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    @actual = CrystalClick::BinaryDataType.tuple(
      [@outer_json, CrystalClick::BinaryDataType.array(nested_dynamic)] of CrystalClick::BinaryDataType,
    )
    @outer_type = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    outer_structure = CrystalClick::DynamicStructure.new([@actual] of CrystalClick::BinaryDataType)
    outer_arm = outer_structure.canonical_index_for(@actual)
    @nested_site = "root.arm.#{outer_arm}.field.1.elements"
    @structures = {
      "root"       => outer_structure,
      @nested_site => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType),
    } of String => CrystalClick::DynamicStructure
    @leaf_bindings = [{
      CrystalClick::BinaryDynamicJsonLeafKey.new("root", outer_arm, [0_i32] of Int32),
      @child_plan,
    }] of Tuple(CrystalClick::BinaryDynamicJsonLeafKey, CrystalClick::ObjectDocumentPlan)

    @rows = [
      w243_outer_value(
        @actual,
        @outer_json,
        @item_array,
        10_u8,
        [w243_leaf_value(
          @leaf_json,
          31_u8,
          @next_array,
          [w243_json_element_value(@great_json, CrystalClick::BinaryValue.string("nested-31"))] of CrystalClick::BinaryValue,
        )] of CrystalClick::BinaryValue,
      ),
      w243_outer_value(@actual, @outer_json, @item_array, 20_u8, [] of CrystalClick::BinaryValue),
      w243_outer_value(@actual, @outer_json, @item_array, 30_u8, [] of CrystalClick::BinaryValue),
      w243_outer_value(
        @actual,
        @outer_json,
        @item_array,
        40_u8,
        [
          w243_leaf_value(@leaf_json, 71_u8, @next_array),
          w243_leaf_value(
            @leaf_json,
            72_u8,
            @next_array,
            [w243_json_element_value(@great_json, CrystalClick::BinaryValue.string("late-72"))] of CrystalClick::BinaryValue,
          ),
        ] of CrystalClick::BinaryValue,
      ),
    ].map do |value|
      CrystalClick::BinaryValue.dynamic(@outer_type, value)
    end
    @rows << CrystalClick::BinaryValue.dynamic(@outer_type)
  end
end

private struct W243CollisionFixture
  getter json_type : CrystalClick::BinaryDataType
  getter root_type : CrystalClick::BinaryDataType
  getter structures : Hash(String, CrystalClick::DynamicStructure)
  getter left_key : CrystalClick::BinaryDynamicJsonLeafKey
  getter right_key : CrystalClick::BinaryDynamicJsonLeafKey
  getter leaf_bindings : W243LeafBindings
  getter policy : CrystalClick::ObjectSharedAdvancedJsonWritePolicy
  getter populated_rows : Array(CrystalClick::BinaryValue)
  getter empty_rows : Array(CrystalClick::BinaryValue)

  def initialize
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    string = CrystalClick::BinaryDataType.primitive("String")
    left_json = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 0,
      max_dynamic_types: 0,
      typed_paths: {"v" => uint8} of String => CrystalClick::BinaryDataType,
    )
    right_json = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 0,
      max_dynamic_types: 0,
      typed_paths: {"v" => string} of String => CrystalClick::BinaryDataType,
    )
    left_array = CrystalClick::BinaryDataType.array(left_json)
    right_array = CrystalClick::BinaryDataType.array(right_json)
    left_structure = CrystalClick::DynamicStructure.new([left_array] of CrystalClick::BinaryDataType)
    right_structure = CrystalClick::DynamicStructure.new([right_array] of CrystalClick::BinaryDataType)
    @left_key = CrystalClick::BinaryDynamicJsonLeafKey.new(
      "root", left_structure.canonical_index_for(left_array), [0_i32] of Int32,
    )
    @right_key = CrystalClick::BinaryDynamicJsonLeafKey.new(
      "root", right_structure.canonical_index_for(right_array), [0_i32] of Int32,
    )
    left_child = w243_empty_child_plan(left_json)
    right_child = w243_empty_child_plan(right_json)
    child_structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(["left", "right"] of String),
      {
        "left"  => left_structure,
        "right" => right_structure,
      } of String => CrystalClick::DynamicStructure,
    )
    child_plan = CrystalClick::ObjectDocumentPlan.new(
      child_structures,
      {} of String => CrystalClick::BinaryDataType,
      root_dynamic_json_object_leaf_plans: {
        "left"  => [{@left_key, left_child}] of Tuple(CrystalClick::BinaryDynamicJsonLeafKey, CrystalClick::ObjectDocumentPlan),
        "right" => [{@right_key, right_child}] of Tuple(CrystalClick::BinaryDynamicJsonLeafKey, CrystalClick::ObjectDocumentPlan),
      } of String => Array(Tuple(CrystalClick::BinaryDynamicJsonLeafKey, CrystalClick::ObjectDocumentPlan)),
    )
    @json_type = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 2,
      max_dynamic_types: 1,
    )
    @root_type = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    root_structure = CrystalClick::DynamicStructure.new([@json_type] of CrystalClick::BinaryDataType)
    root_index = root_structure.canonical_index_for(@json_type)
    root_key = CrystalClick::BinaryDynamicJsonLeafKey.new("root", root_index, [] of Int32)
    @structures = {"root" => root_structure} of String => CrystalClick::DynamicStructure
    @leaf_bindings = [{root_key, child_plan}] of W243LeafBinding
    prepared = CrystalClick::ObjectSharedAdvancedJsonActualPlan.new(
      @json_type,
      [{[] of Int32, child_plan}] of Tuple(Array(Int32), CrystalClick::ObjectDocumentPlan),
    )
    @policy = CrystalClick::ObjectSharedAdvancedJsonWritePolicy.new(
      [prepared] of CrystalClick::ObjectSharedAdvancedJsonActualPlan,
      16,
    )

    left_value = w243_json_element_value(left_json, CrystalClick::BinaryValue.fixed(uint8, Bytes[7_u8]))
    right_value = w243_json_element_value(right_json, CrystalClick::BinaryValue.string("right-7"))
    right_late = w243_json_element_value(right_json, CrystalClick::BinaryValue.string("right-late"))
    populated = [
      w243_collision_parent_value(@json_type, left_array, right_array, [left_value] of CrystalClick::BinaryValue, [right_value] of CrystalClick::BinaryValue),
      w243_collision_parent_value(@json_type, left_array, right_array, [] of CrystalClick::BinaryValue, [right_late] of CrystalClick::BinaryValue),
      w243_collision_parent_value(@json_type, left_array, right_array, [] of CrystalClick::BinaryValue, [] of CrystalClick::BinaryValue),
    ] of CrystalClick::BinaryValue
    @populated_rows = populated.map { |value| CrystalClick::BinaryValue.dynamic(@root_type, value) }
    @populated_rows << CrystalClick::BinaryValue.dynamic(@root_type)

    empty_parent = w243_collision_parent_value(
      @json_type,
      left_array,
      right_array,
      [] of CrystalClick::BinaryValue,
      [] of CrystalClick::BinaryValue,
    )
    @empty_rows = [
      CrystalClick::BinaryValue.dynamic(@root_type, empty_parent),
      CrystalClick::BinaryValue.dynamic(@root_type, empty_parent),
      CrystalClick::BinaryValue.dynamic(@root_type),
    ] of CrystalClick::BinaryValue
  end
end

private def w243_empty_child_plan(type : CrystalClick::BinaryDataType) : CrystalClick::ObjectDocumentPlan
  structures = CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new([] of String),
    {} of String => CrystalClick::DynamicStructure,
  )
  CrystalClick::ObjectDocumentPlan.new(structures, type.json_type.not_nil!.typed_paths)
end

private def w243_json_element_value(
  json_type : CrystalClick::BinaryDataType,
  value : CrystalClick::BinaryValue,
) : CrystalClick::BinaryValue
  json = CrystalClick::BinaryValue.json(
    json_type,
    CrystalClick::BinaryJsonRow.new(
      json_type,
      [{"v", value}] of Tuple(String, CrystalClick::BinaryValue),
    ),
  )
  json
end

private def w243_collision_parent_value(
  json_type : CrystalClick::BinaryDataType,
  left_array_type : CrystalClick::BinaryDataType,
  right_array_type : CrystalClick::BinaryDataType,
  left_values : Array(CrystalClick::BinaryValue),
  right_values : Array(CrystalClick::BinaryValue),
) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.json(
    json_type,
    CrystalClick::BinaryJsonRow.new(
      json_type,
      [
        {"left", CrystalClick::BinaryValue.array(left_array_type, left_values)},
        {"right", CrystalClick::BinaryValue.array(right_array_type, right_values)},
      ] of Tuple(String, CrystalClick::BinaryValue),
    ),
  )
end

private def w243_leaf_value(
  type : CrystalClick::BinaryDataType,
  byte : UInt8,
  next_array_type : CrystalClick::BinaryDataType,
  next_values : Array(CrystalClick::BinaryValue) = [] of CrystalClick::BinaryValue,
) : CrystalClick::BinaryValue
  value_type = CrystalClick::BinaryDataType.primitive("UInt8")
  row = CrystalClick::BinaryJsonRow.new(
    type,
    [
      {"v", CrystalClick::BinaryValue.fixed(value_type, Bytes[byte])},
      {"next_field", CrystalClick::BinaryValue.array(next_array_type, next_values)},
    ] of Tuple(String, CrystalClick::BinaryValue),
  )
  CrystalClick::BinaryValue.json(type, row)
end

private def w243_outer_value(
  actual_type : CrystalClick::BinaryDataType,
  json_type : CrystalClick::BinaryDataType,
  item_array_type : CrystalClick::BinaryDataType,
  byte : UInt8,
  items : Array(CrystalClick::BinaryValue),
) : CrystalClick::BinaryValue
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  json_row = CrystalClick::BinaryJsonRow.new(
    json_type,
    [
      {"v", CrystalClick::BinaryValue.fixed(uint8, Bytes[byte])},
      {"items", CrystalClick::BinaryValue.array(item_array_type, items)},
    ] of Tuple(String, CrystalClick::BinaryValue),
  )
  CrystalClick::BinaryValue.tuple(
    actual_type,
    [
      CrystalClick::BinaryValue.json(json_type, json_row),
      CrystalClick::BinaryValue.array(actual_type.child_at(1), [] of CrystalClick::BinaryValue),
    ] of CrystalClick::BinaryValue,
  )
end

private def w243_wire_equal!(actual : CrystalClick::BinaryValue, expected : CrystalClick::BinaryValue) : Nil
  CrystalClick::BinaryValueCodec.encode(actual).should eq(CrystalClick::BinaryValueCodec.encode(expected))
end

private def w243_limits(max_depth : Int32) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(
    max_depth: max_depth,
    max_nodes: 100_000,
    max_elements: 100_000,
    max_bytes: 1_000_000,
  )
end

private def w243_paired_roundtrip(
  fixture : W243Fixture,
  rows : Array(CrystalClick::BinaryValue),
  profile : CrystalClick::BinaryBulkProfile,
) : Array(CrystalClick::BinaryValue)
  encoded = CrystalClick::ObjectSharedPathCodec.encode_with_json_children_with_budget(
    fixture.outer_type,
    fixture.structures,
    rows,
    CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
    fixture.leaf_bindings,
    CrystalClick::ObjectSharedNestedSerializationContext.for_write(0_u64, 1, profile),
    profile,
    CrystalClick::ObjectSharedAdvancedJsonWritePolicy.new(
      [CrystalClick::ObjectSharedAdvancedJsonActualPlan.new(
        fixture.actual,
        [{[0_i32] of Int32, fixture.child_plan}] of Tuple(Array(Int32), CrystalClick::ObjectDocumentPlan),
      )] of CrystalClick::ObjectSharedAdvancedJsonActualPlan,
      16,
    ),
  )
  decoded = CrystalClick::ObjectSharedPathCodec.decode_with_json_children_with_budget(
    encoded.data,
    encoded.events,
    rows.size,
    fixture.outer_type,
    CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
    CrystalClick::ObjectSharedNestedSerializationContext.for_read(0_u64, profile),
    profile,
  )
  decoded.rows
end

private def w243_read_prefixes(
  type : CrystalClick::BinaryDataType,
  streams : CrystalClick::ObjectSharedPathStreams,
  profile : CrystalClick::BinaryBulkProfile,
  budget : CrystalClick::BinaryCodecBudget,
) : CrystalClick::ObjectSharedPathJsonTapeCodec::PrefixMap
  tape = CrystalClick::ObjectSharedPathTapeReader.new(streams.data, streams.events, budget)
  prefixes = CrystalClick::ObjectSharedPathJsonTapeCodec::PrefixMap.new
  observer = ->(_path : String, _bytes : Bytes, _structure : CrystalClick::DynamicStructure) { nil }
  CrystalClick::ObjectSharedPathCodec.decode_prefix_type_with_observer(
    type,
    "root",
    "",
    "",
    0_u64,
    1_i32,
    tape,
    budget,
    observer,
    false,
    nil,
    true,
    nil,
    CrystalClick::ObjectSharedNestedSerializationContext.for_read(0_u64, profile),
    prefixes,
  )
  prefixes
end

private def w243_great_grandchild_prefix(
  fixture : W243Fixture,
  streams : CrystalClick::ObjectSharedPathStreams,
  profile : CrystalClick::BinaryBulkProfile,
  budget : CrystalClick::BinaryCodecBudget,
) : CrystalClick::ObjectDocumentInlinePrefix
  prefixes = w243_read_prefixes(fixture.outer_type, streams, profile, budget)
  child_prefix = prefixes[fixture.leaf_bindings[0][0]]
  item_structure = child_prefix.plan.structures.dynamic_for("items")
  item_key = CrystalClick::BinaryDynamicJsonLeafKey.new(
    "root",
    item_structure.canonical_index_for(fixture.item_array),
    [0_i32] of Int32,
  )
  grandchild_prefix = child_prefix.root_dynamic_json_prefixes_for("items")[item_key]
  next_structure = grandchild_prefix.plan.structures.dynamic_for("next_field")
  next_key = CrystalClick::BinaryDynamicJsonLeafKey.new(
    "root",
    next_structure.canonical_index_for(fixture.next_array),
    [0_i32] of Int32,
  )
  grandchild_prefix.root_dynamic_json_prefixes_for("next_field")[next_key]
end

private def w243_callback_owner_tree(
  prefix : CrystalClick::ObjectDocumentInlinePrefix,
  budget : CrystalClick::BinaryCodecBudget,
  descendants : Array(W243CallbackOwner),
) : W243CallbackOwner
  physical_plan = CrystalClick::ObjectSharedPathJsonTapeCodec.physical_plan_for_prefix(prefix, budget)
  prefix.bind_physical_plan!(physical_plan)
  prefix.each_root_dynamic_json_prefix_entry(budget) do |path, key, child_prefix|
    site = physical_plan.root_dynamic_json(path).json_object_site(key)
    unless site.leaf_key == key && site.binding.leaf_key == key && site.binding.plan.same?(child_prefix.plan)
      raise CrystalClick::CorruptPartError.new("test owner tree did not follow an exact retained JSON site")
    end
    child_physical_plan = site.physical_plan
    child_prefix.bind_physical_plan!(child_physical_plan)
    child_root = CrystalClick::ObjectDocumentInlineCallbackOrder.canonical_root_prefix(child_physical_plan)
    descendants << {
      child_root,
      child_prefix.callback_prefix,
      child_physical_plan,
      site.binding.plan,
    }
    w243_callback_owner_tree(child_prefix, budget, descendants)
  end
  {
    CrystalClick::ObjectDocumentInlineCallbackOrder.canonical_root_prefix(physical_plan),
    prefix.callback_prefix,
    physical_plan,
    prefix.plan,
  }
end

describe "W243 further JSON-bound Dynamic actuals in a prepared Object child" do
  it "keeps inferred JSON site resolution direction-explicit" do
    fixture = W243Fixture.new
    structure = fixture.structures["root"]
    key = fixture.leaf_bindings[0][0]
    limits = CrystalClick::BinaryCodecLimits.default

    expect_raises(ArgumentError) do
      CrystalClick::ObjectRootDynamicJsonSiteResolver.new(
        "payload.items",
        structure,
        CrystalClick::BinaryCodecBudget.new(limits, true),
        CrystalClick::PhysicalStreamPlanContext.new(limits),
      )
    end
    expect_raises(ArgumentError) do
      CrystalClick::ObjectRootDynamicJsonSiteResolver.for_write(
        "payload.items",
        structure,
        CrystalClick::BinaryCodecBudget.new(limits),
        CrystalClick::PhysicalStreamPlanContext.new(limits),
      )
    end

    read_coordinates = CrystalClick::ObjectRootDynamicJsonSiteResolver.new(
      "payload.items",
      structure,
      CrystalClick::BinaryCodecBudget.new(limits),
      CrystalClick::PhysicalStreamPlanContext.new(limits),
    ).resolve_json_leaf(key)
    write_coordinates = CrystalClick::ObjectRootDynamicJsonSiteResolver.for_write(
      "payload.items",
      structure,
      CrystalClick::BinaryCodecBudget.new(limits, true),
      CrystalClick::PhysicalStreamPlanContext.new(limits),
    ).resolve_json_leaf(key)

    write_coordinates.escaped_prefix.should eq(read_coordinates.escaped_prefix)
    write_coordinates.array_level.should eq(read_coordinates.array_level)
    write_coordinates.json_type.should eq(read_coordinates.json_type)
    write_coordinates.json_depth.should eq(read_coordinates.json_depth)
  end

  it "prepares the descendant plan and roundtrips its late and empty JSON arrays" do
    fixture = W243Fixture.new
    prepared = CrystalClick::ObjectSharedAdvancedJsonActualPlan.new(
      fixture.actual,
      [{[0_i32] of Int32, fixture.child_plan}] of Tuple(Array(Int32), CrystalClick::ObjectDocumentPlan),
    )
    policy = CrystalClick::ObjectSharedAdvancedJsonWritePolicy.new(
      [prepared] of CrystalClick::ObjectSharedAdvancedJsonActualPlan,
      16,
    )
    profile = CrystalClick::ObjectSharedPathCodec::COMPACT_PROFILE
    encoded = CrystalClick::ObjectSharedPathCodec.encode_with_json_children_with_budget(
      fixture.outer_type,
      fixture.structures,
      fixture.rows,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
      fixture.leaf_bindings,
      CrystalClick::ObjectSharedNestedSerializationContext.for_write(0_u64, 1, profile),
      profile,
      policy,
    )
    decoded = CrystalClick::ObjectSharedPathCodec.decode_with_json_children_with_budget(
      encoded.data,
      encoded.events,
      fixture.rows.size,
      fixture.outer_type,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
      CrystalClick::ObjectSharedNestedSerializationContext.for_read(0_u64, profile),
      profile,
    )

    decoded.rows.size.should eq(fixture.rows.size)
    fixture.rows.each_with_index do |expected, index|
      w243_wire_equal!(decoded.rows[index], expected)
    end
    decoded.structures[fixture.nested_site].type_count.should eq(0)

    # Re-read only the prefix phase with the ordinary recursive parser. This
    # proves the child retained the unused String arm from the emitted
    # descriptor roster, rather than merely checking the writer's input plan.
    read_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
    prefixes = w243_read_prefixes(fixture.outer_type, encoded, profile, read_budget)
    child_prefix = prefixes[fixture.leaf_bindings[0][0]]
    retained = child_prefix.plan.structures.dynamic_for("items")
    retained.type_count.should eq(2)
    retained.types.map(&.name).should contain(fixture.item_array.name)
    retained.types.map(&.name).should contain("String")

    nested_key = CrystalClick::BinaryDynamicJsonLeafKey.new(
      "root",
      retained.canonical_index_for(fixture.item_array),
      [0_i32] of Int32,
    )
    nested_prefix = child_prefix.root_dynamic_json_prefixes_for("items")[nested_key]
    nested_prefix.descriptor.should eq(fixture.leaf_json)
    nested_structure = nested_prefix.plan.structures.dynamic_for("next_field")
    nested_structure.type_count.should eq(2)
    nested_structure.types.map(&.name).should contain(fixture.next_array.name)
    nested_structure.types.map(&.name).should contain("String")
    great_key = CrystalClick::BinaryDynamicJsonLeafKey.new(
      "root",
      nested_structure.canonical_index_for(fixture.next_array),
      [0_i32] of Int32,
    )
    great_prefix = nested_prefix.root_dynamic_json_prefixes_for("next_field")[great_key]
    great_prefix.descriptor.should eq(fixture.great_json)

    # The Array(JSON) size callback is emitted by the parent Object's Dynamic
    # actual, even though its canonical name shares the grandchild Object
    # prefix. Ownership must therefore come from the descriptor schedule,
    # not longest-prefix matching.
    descendants = [] of W243CallbackOwner
    parent_owner = w243_callback_owner_tree(child_prefix, read_budget, descendants)
    descendants.size.should eq(2)
    grandchild_owner = descendants.find! { |owner| owner[3].same?(nested_prefix.plan) }
    great_grandchild_owner = descendants.find! { |owner| owner[3].same?(great_prefix.plan) }
    prefix_events = CrystalClick::ObjectDocumentInlineCallbackOrder.prefix_callback_events(
      parent_owner[2],
      parent_owner[3],
      parent_owner[1],
      read_budget,
      descendants: descendants,
    )
    body_events = CrystalClick::ObjectDocumentInlineCallbackOrder.body_callback_events(
      parent_owner[2],
      parent_owner[3],
      profile,
      parent_owner[1],
      read_budget,
      descendants: descendants,
    )
    grandchild_structure = prefix_events.find! do |event|
      event[1] == "#{grandchild_owner[0]}.object_structure"
    end
    grandchild_structure[0].should eq(grandchild_owner[0])
    great_grandchild_structure = prefix_events.find! do |event|
      event[1] == "#{great_grandchild_owner[0]}.object_structure"
    end
    great_grandchild_structure[0].should eq(great_grandchild_owner[0])

    array_size_name = parent_owner[2].dynamic_arm("items", fixture.item_array.name).stream_name_for("root.sizes")
    array_size = body_events.find! { |event| event[1] == array_size_name }
    array_size[0].should eq(parent_owner[0])

    nested_array_size_name = grandchild_owner[2].dynamic_arm("next_field", fixture.next_array.name).stream_name_for("root.sizes")
    nested_array_size = body_events.find! { |event| event[1] == nested_array_size_name }
    nested_array_size[0].should eq(grandchild_owner[0])
    nested_array_size_name.should contain("next_field")
    nested_array_size[2].should contain("next_field")

    longest_prefix_registry = CrystalClick::ObjectDocumentInlineCallbackEvents.new(
      parent_owner,
      descendants,
      read_budget,
    )
    longest_prefix_registry.root_for_canonical_name(array_size[1]).should eq(grandchild_owner[0])
  end

  it "rejects a JSON-bearing descendant actual when its exact child binding is missing" do
    fixture = W243Fixture.new
    error = expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentPlan.new(
        fixture.child_structures,
        fixture.outer_json.json_type.not_nil!.typed_paths,
      )
    end
    error.message.not_nil!.should contain("JSON")
  end

  it "keeps child Array(JSON) occurrences independent of one-row parent marks" do
    fixture = W243Fixture.new
    profile = CrystalClick::ObjectSharedPathCodec::COMPACT_PROFILE
    # encode_with_json_children_with_budget wraps its complete input row list
    # as one parent granule ([rows]); the child grid therefore has P=1 here.
    # Inspect the exact runtime Array payload to establish Q=2 independently
    # of the write-context chunk target.
    q_greater_rows = [fixture.rows[3]] of CrystalClick::BinaryValue
    q_greater_rows.size.should eq(1)
    q_greater = q_greater_rows[0].child_at(0).child_at(0).json_row.value_for("items").not_nil!
    q_greater.element_count.should eq(2)
    q_greater_decoded = w243_paired_roundtrip(fixture, q_greater_rows, profile)
    q_greater_decoded.size.should eq(1)
    w243_wire_equal!(q_greater_decoded[0], q_greater_rows[0])

    # Separately exercise the same one-parent-mark grid with E=0. This keeps
    # the empty occurrence control distinct from the P=1,Q=2 witness above.
    empty_rows = [fixture.rows[2]] of CrystalClick::BinaryValue
    empty_rows.size.should eq(1)
    empty = empty_rows[0].child_at(0).child_at(0).json_row.value_for("items").not_nil!
    empty.element_count.should eq(0)
    empty_decoded = w243_paired_roundtrip(fixture, empty_rows, profile)
    empty_decoded.size.should eq(1)
    w243_wire_equal!(empty_decoded[0], empty_rows[0])
  end

  it "retains the deeper JSON owner when its registered arrays are empty" do
    fixture = W243Fixture.new
    profile = CrystalClick::ObjectSharedPathCodec::COMPACT_PROFILE
    rows = [fixture.rows[2]] of CrystalClick::BinaryValue
    policy = CrystalClick::ObjectSharedAdvancedJsonWritePolicy.new(
      [CrystalClick::ObjectSharedAdvancedJsonActualPlan.new(
        fixture.actual,
        [{[0_i32] of Int32, fixture.child_plan}] of Tuple(Array(Int32), CrystalClick::ObjectDocumentPlan),
      )] of CrystalClick::ObjectSharedAdvancedJsonActualPlan,
      16,
    )
    encoded = CrystalClick::ObjectSharedPathCodec.encode_with_json_children_with_budget(
      fixture.outer_type,
      fixture.structures,
      rows,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
      fixture.leaf_bindings,
      CrystalClick::ObjectSharedNestedSerializationContext.for_write(0_u64, 1, profile),
      profile,
      policy,
    )
    decoded = CrystalClick::ObjectSharedPathCodec.decode_with_json_children_with_budget(
      encoded.data,
      encoded.events,
      rows.size,
      fixture.outer_type,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
      CrystalClick::ObjectSharedNestedSerializationContext.for_read(0_u64, profile),
      profile,
    )
    w243_wire_equal!(decoded.rows[0], rows[0])

    # Even without any leaf occurrences, the declared nested owner chain must
    # retain the complete Dynamic arm and child Object prefix schedule.
    structure_names = encoded.events.select { |event| event.name.ends_with?(".object_structure") }
    structure_names.size.should eq(3)
    structure_names.any? { |event| event.name.includes?("next_field") }.should be_true

    read_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
    prefixes = w243_read_prefixes(fixture.outer_type, encoded, profile, read_budget)
    child_prefix = prefixes[fixture.leaf_bindings[0][0]]
    nested_prefixes = child_prefix.root_dynamic_json_prefixes_for("items")
    nested_prefixes.size.should eq(1)
    nested_prefix = nested_prefixes.values.first
    retained = nested_prefix.plan.structures.dynamic_for("next_field")
    retained.type_count.should eq(2)
    retained.types.map(&.name).should contain(fixture.next_array.name)
    retained.types.map(&.name).should contain("String")
    great_key = CrystalClick::BinaryDynamicJsonLeafKey.new(
      "root",
      retained.canonical_index_for(fixture.next_array),
      [0_i32] of Int32,
    )
    great_prefix = nested_prefix.root_dynamic_json_prefixes_for("next_field")[great_key]
    great_prefix.descriptor.should eq(fixture.great_json)
  end

  it "enforces the deepest prepared great-grandchild descriptor boundary" do
    fixture = W243Fixture.new
    profile = CrystalClick::ObjectSharedPathCodec::COMPACT_PROFILE
    reference = CrystalClick::ObjectSharedPathCodec.encode_with_json_children_with_budget(
      fixture.outer_type,
      fixture.structures,
      fixture.rows,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
      fixture.leaf_bindings,
      CrystalClick::ObjectSharedNestedSerializationContext.for_write(0_u64, 1, profile),
      profile,
      CrystalClick::ObjectSharedAdvancedJsonWritePolicy.new(
        [CrystalClick::ObjectSharedAdvancedJsonActualPlan.new(
          fixture.actual,
          [{[0_i32] of Int32, fixture.child_plan}] of Tuple(Array(Int32), CrystalClick::ObjectDocumentPlan),
        )] of CrystalClick::ObjectSharedAdvancedJsonActualPlan,
        16,
      ),
    )
    deepest_prefix = w243_great_grandchild_prefix(
      fixture,
      reference,
      profile,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
    )
    fitting_depth = deepest_prefix.typed_descriptor_root_depth
    fitting_depth.should eq(deepest_prefix.json_descriptor_depth + 1)
    rejecting_depth = deepest_prefix.json_descriptor_depth

    # The outer descriptors fit at the rejecting bound; only the great-
    # grandchild's typed root needs the next level.
    accepted = CrystalClick::ObjectSharedPathCodec.encode_with_json_children_with_budget(
      fixture.outer_type,
      fixture.structures,
      fixture.rows,
      CrystalClick::BinaryCodecBudget.new(w243_limits(fitting_depth), true),
      fixture.leaf_bindings,
      CrystalClick::ObjectSharedNestedSerializationContext.for_write(0_u64, 1, profile),
      profile,
      CrystalClick::ObjectSharedAdvancedJsonWritePolicy.new(
        [CrystalClick::ObjectSharedAdvancedJsonActualPlan.new(
          fixture.actual,
          [{[0_i32] of Int32, fixture.child_plan}] of Tuple(Array(Int32), CrystalClick::ObjectDocumentPlan),
        )] of CrystalClick::ObjectSharedAdvancedJsonActualPlan,
        16,
      ),
    )
    accepted.events.size.should be > 0

    expect_raises(CrystalClick::UnsupportedFormatError, "depth") do
      CrystalClick::ObjectSharedPathCodec.encode_with_json_children_with_budget(
        fixture.outer_type,
        fixture.structures,
        fixture.rows,
        CrystalClick::BinaryCodecBudget.new(w243_limits(rejecting_depth), true),
        fixture.leaf_bindings,
        CrystalClick::ObjectSharedNestedSerializationContext.for_write(0_u64, 1, profile),
        profile,
        CrystalClick::ObjectSharedAdvancedJsonWritePolicy.new(
          [CrystalClick::ObjectSharedAdvancedJsonActualPlan.new(
            fixture.actual,
            [{[0_i32] of Int32, fixture.child_plan}] of Tuple(Array(Int32), CrystalClick::ObjectDocumentPlan),
          )] of CrystalClick::ObjectSharedAdvancedJsonActualPlan,
          16,
        ),
      )
    end
  end

  it "roundtrips sibling child Objects whose local JSON leaf keys collide" do
    fixture = W243CollisionFixture.new
    fixture.left_key.should eq(fixture.right_key)
    left = fixture.structures["root"]
    left.type_count.should eq(1)
    fixture.leaf_bindings.size.should eq(1)
    # Both child Object paths deliberately use the same local key:
    # (root, canonical arm 0, descriptor child [0]). Their schemas and values
    # differ, so a flat leaf-key map would substitute UInt8 for String or lose
    # one owner.
    profile = CrystalClick::ObjectSharedPathCodec::COMPACT_PROFILE
    encoded = CrystalClick::ObjectSharedPathCodec.encode_with_json_children_with_budget(
      CrystalClick::BinaryDataType.dynamic(max_types: 1),
      fixture.structures,
      fixture.populated_rows,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
      fixture.leaf_bindings,
      CrystalClick::ObjectSharedNestedSerializationContext.for_write(0_u64, 1, profile),
      profile,
      fixture.policy,
    )
    decoded = CrystalClick::ObjectSharedPathCodec.decode_with_json_children_with_budget(
      encoded.data,
      encoded.events,
      fixture.populated_rows.size,
      CrystalClick::BinaryDataType.dynamic(max_types: 1),
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
      CrystalClick::ObjectSharedNestedSerializationContext.for_read(0_u64, profile),
      profile,
    )
    decoded.rows.size.should eq(fixture.populated_rows.size)
    fixture.populated_rows.each_with_index do |expected, index|
      w243_wire_equal!(decoded.rows[index], expected)
    end
  end

  it "retains registered JSON child owners when every nested array is empty" do
    fixture = W243CollisionFixture.new
    profile = CrystalClick::ObjectSharedPathCodec::COMPACT_PROFILE
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    encoded = CrystalClick::ObjectSharedPathCodec.encode_with_json_children_with_budget(
      dynamic,
      fixture.structures,
      fixture.empty_rows,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
      fixture.leaf_bindings,
      CrystalClick::ObjectSharedNestedSerializationContext.for_write(0_u64, 1, profile),
      profile,
      fixture.policy,
    )
    decoded = CrystalClick::ObjectSharedPathCodec.decode_with_json_children_with_budget(
      encoded.data,
      encoded.events,
      fixture.empty_rows.size,
      dynamic,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
      CrystalClick::ObjectSharedNestedSerializationContext.for_read(0_u64, profile),
      profile,
    )
    decoded.rows.size.should eq(fixture.empty_rows.size)
    fixture.empty_rows.each_with_index do |expected, index|
      w243_wire_equal!(decoded.rows[index], expected)
    end
    names = encoded.events.map(&.name)
    names.any? { |name| name.includes?("left") }.should be_true
    names.any? { |name| name.includes?("right") }.should be_true
    names.count { |name| name.ends_with?(".object_structure") }.should eq(3)
  end

  it "rejects malformed recursive callback owner rosters" do
    fixture = W243CollisionFixture.new
    profile = CrystalClick::ObjectSharedPathCodec::COMPACT_PROFILE
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    encoded = CrystalClick::ObjectSharedPathCodec.encode_with_json_children_with_budget(
      dynamic,
      fixture.structures,
      fixture.populated_rows,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
      fixture.leaf_bindings,
      CrystalClick::ObjectSharedNestedSerializationContext.for_write(0_u64, 1, profile),
      profile,
      fixture.policy,
    )
    read_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
    prefixes = w243_read_prefixes(dynamic, encoded, profile, read_budget)
    root_prefix = prefixes[fixture.leaf_bindings[0][0]]
    descendants = [] of W243CallbackOwner
    root_owner = w243_callback_owner_tree(root_prefix, read_budget, descendants)
    descendants.size.should eq(2)

    valid_registry = CrystalClick::ObjectDocumentInlineCallbackEvents.new(
      root_owner,
      descendants,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
    )
    valid_registry.owner_count.should eq(3)

    # The subtree result owns detached copies of each descendant's canonical
    # and raw callback roots. Exact byte fit must succeed once, without a
    # second per-owner ensure against the already-consumed aggregate budget.
    descendant_name_bytes = 0_i64
    descendants.each do |owner|
      descendant_name_bytes += owner[0].bytesize.to_i64
      descendant_name_bytes += owner[1].bytesize.to_i64
    end
    descendant_name_bytes.should be > 0
    exact_budget = CrystalClick::BinaryCodecBudget.new(
      CrystalClick::BinaryCodecLimits.new(
        max_depth: 64,
        max_nodes: 100_000,
        max_elements: 100_000,
        max_bytes: descendant_name_bytes.to_i,
      ),
    )
    exact_descendants = valid_registry.descendants_for(root_owner[0], exact_budget)
    exact_descendants.size.should eq(descendants.size)
    exact_name_bytes = 0_i64
    exact_descendants.each do |owner|
      exact_name_bytes += owner[0].bytesize.to_i64
      exact_name_bytes += owner[1].bytesize.to_i64
    end
    exact_name_bytes.should eq(descendant_name_bytes)
    exact_budget.wire_byte_count.should eq(descendant_name_bytes)

    short_budget = CrystalClick::BinaryCodecBudget.new(
      CrystalClick::BinaryCodecLimits.new(
        max_depth: 64,
        max_nodes: 100_000,
        max_elements: 100_000,
        max_bytes: descendant_name_bytes.to_i - 1,
      ),
    )
    expect_raises(CrystalClick::CorruptPartError) do
      valid_registry.descendants_for(root_owner[0], short_budget)
    end

    missing = descendants.dup
    missing.pop
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentInlineCallbackEvents.new(
        root_owner,
        missing,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
      )
    end

    duplicated = descendants.dup
    duplicated << descendants.first
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentInlineCallbackEvents.new(
        root_owner,
        duplicated,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
      )
    end

    left_prefix = root_prefix.root_dynamic_json_prefixes_for("left").values.first
    right_prefix = root_prefix.root_dynamic_json_prefixes_for("right").values.first
    left_descendants = [] of W243CallbackOwner
    right_descendants = [] of W243CallbackOwner
    left_owner = w243_callback_owner_tree(left_prefix, read_budget, left_descendants)
    right_owner = w243_callback_owner_tree(right_prefix, read_budget, right_descendants)
    left_descendants.empty?.should be_true
    right_descendants.empty?.should be_true
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentInlineCallbackEvents.new(
        left_owner,
        [right_owner] of W243CallbackOwner,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
      )
    end
  end

  it "retains the JSON typed-Dynamic guard at a prepared grandchild actual" do
    fixture = W243Fixture.new
    nested_dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    nested_array = CrystalClick::BinaryDataType.array(nested_dynamic)
    guarded_json = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 0,
      max_dynamic_types: 0,
      typed_paths: {
        "nested" => nested_array,
      } of String => CrystalClick::BinaryDataType,
    )

    grandchild_structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    )
    grandchild_plan = CrystalClick::ObjectDocumentPlan.new(
      grandchild_structures,
      guarded_json.json_type.not_nil!.typed_paths,
      typed_dynamic_sites: {
        "nested" => {
          "root.elements" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType),
        } of String => CrystalClick::DynamicStructure,
      } of String => Hash(String, CrystalClick::DynamicStructure),
    )

    # This JSON actual is a descendant of the already prepared outer JSON
    # actual's Object Dynamic path. Its immediate parent descriptor remains
    # ordinary JSON(v UInt8), so the ancestor's guard cannot reject by itself.
    guarded_actual = CrystalClick::BinaryDataType.array(guarded_json)
    nested_structure = CrystalClick::DynamicStructure.new([guarded_actual] of CrystalClick::BinaryDataType)
    nested_key = CrystalClick::BinaryDynamicJsonLeafKey.new(
      "root",
      nested_structure.canonical_index_for(guarded_actual),
      [0_i32] of Int32,
    )
    child_structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(["items"] of String),
      {"items" => nested_structure} of String => CrystalClick::DynamicStructure,
    )
    child_plan = CrystalClick::ObjectDocumentPlan.new(
      child_structures,
      fixture.outer_json.json_type.not_nil!.typed_paths,
      root_dynamic_json_object_leaf_plans: {
        "items" => [{nested_key, grandchild_plan}] of Tuple(
          CrystalClick::BinaryDynamicJsonLeafKey,
          CrystalClick::ObjectDocumentPlan,
        ),
      } of String => Array(Tuple(CrystalClick::BinaryDynamicJsonLeafKey, CrystalClick::ObjectDocumentPlan)),
    )

    # Keep the outer prepared actual's JSON descriptor ordinary (v: UInt8).
    # The forbidden Dynamic is visible only after following the child Object's
    # `items` actual into the grandchild JSON schema.
    actual = CrystalClick::BinaryDataType.tuple(
      [fixture.outer_json, CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.dynamic(max_types: 1))] of CrystalClick::BinaryDataType,
    )
    actual_index = fixture.structures["root"].canonical_index_for(actual)
    actual_key = CrystalClick::BinaryDynamicJsonLeafKey.new("root", actual_index, [0_i32] of Int32)
    outer_child_bindings = [{actual_key, child_plan}] of W243LeafBinding

    # There are no runtime elements to trigger the guard. The exact registered
    # Array(JSON) actual and its prepared grandchild plan must still be
    # validated from the descriptor/binding roster.
    guarded_array_value = CrystalClick::BinaryValue.array(guarded_actual, [] of CrystalClick::BinaryValue)
    outer_row = CrystalClick::BinaryJsonRow.new(
      fixture.outer_json,
      [
        {"v", CrystalClick::BinaryValue.fixed(CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[9_u8])},
        {"items", guarded_array_value},
      ] of Tuple(String, CrystalClick::BinaryValue),
    )
    outer_value = CrystalClick::BinaryValue.tuple(
      actual,
      [
        CrystalClick::BinaryValue.json(fixture.outer_json, outer_row),
        CrystalClick::BinaryValue.array(actual.child_at(1), [] of CrystalClick::BinaryValue),
      ] of CrystalClick::BinaryValue,
    )
    outer_rows = [CrystalClick::BinaryValue.dynamic(fixture.outer_type, outer_value)] of CrystalClick::BinaryValue
    profile = CrystalClick::ObjectSharedPathCodec::COMPACT_PROFILE

    begin
      prepared = CrystalClick::ObjectSharedAdvancedJsonActualPlan.new(
        actual,
        [{[0_i32] of Int32, child_plan}] of Tuple(Array(Int32), CrystalClick::ObjectDocumentPlan),
      )
      policy = CrystalClick::ObjectSharedAdvancedJsonWritePolicy.new(
        [prepared] of CrystalClick::ObjectSharedAdvancedJsonActualPlan,
        16,
      )
      CrystalClick::ObjectSharedPathCodec.encode_with_json_children_with_budget(
        fixture.outer_type,
        fixture.structures,
        outer_rows,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
        outer_child_bindings,
        CrystalClick::ObjectSharedNestedSerializationContext.for_write(0_u64, 1, profile),
        profile,
        policy,
      )
      fail("paired parent encode admitted Dynamic inside the grandchild JSON typed schema")
    rescue error : ArgumentError
      error.message.not_nil!.should contain("Dynamic")
    rescue error : CrystalClick::UnsupportedFormatError
      error.message.not_nil!.should contain("Dynamic")
    end
  end
end
