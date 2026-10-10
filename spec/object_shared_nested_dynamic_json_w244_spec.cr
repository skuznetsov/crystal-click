require "./spec_helper"

private alias W244LeafBinding = Tuple(
  CrystalClick::BinaryDynamicJsonLeafKey,
  CrystalClick::ObjectDocumentPlan,
)

private struct W244Fixture
  getter outer_json : CrystalClick::BinaryDataType
  getter inner_json : CrystalClick::BinaryDataType
  getter nested_actual : CrystalClick::BinaryDataType
  getter outer_actual : CrystalClick::BinaryDataType
  getter nested_dynamic : CrystalClick::BinaryDataType
  getter outer_dynamic : CrystalClick::BinaryDataType
  getter nested_site : String
  getter outer_child_plan : CrystalClick::ObjectDocumentPlan
  getter inner_child_plan : CrystalClick::ObjectDocumentPlan
  getter policy : CrystalClick::ObjectSharedAdvancedJsonWritePolicy

  def initialize
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    int64 = CrystalClick::BinaryDataType.primitive("Int64")
    @outer_json = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 1,
      max_dynamic_types: 2,
      typed_paths: {"v" => uint8} of String => CrystalClick::BinaryDataType,
    )
    @inner_json = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 0,
      max_dynamic_types: 0,
      typed_paths: {"v" => int64} of String => CrystalClick::BinaryDataType,
    )
    @nested_actual = CrystalClick::BinaryDataType.tuple(
      [@inner_json, uint8] of CrystalClick::BinaryDataType,
    )
    @nested_dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    @outer_actual = CrystalClick::BinaryDataType.tuple(
      [@outer_json, CrystalClick::BinaryDataType.array(@nested_dynamic)] of CrystalClick::BinaryDataType,
    )
    @outer_dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    outer_structure = CrystalClick::DynamicStructure.new([@outer_actual] of CrystalClick::BinaryDataType)
    outer_arm = outer_structure.canonical_index_for(@outer_actual)
    @nested_site = "root.arm.#{outer_arm}.field.1.elements"

    @outer_child_plan = w244_child_plan(@outer_json)
    @inner_child_plan = w244_child_plan(@inner_json)
    outer_prepared = CrystalClick::ObjectSharedAdvancedJsonActualPlan.new(
      @outer_actual,
      [{[0_i32] of Int32, @outer_child_plan}] of Tuple(Array(Int32), CrystalClick::ObjectDocumentPlan),
    )
    inner_prepared = CrystalClick::ObjectSharedAdvancedJsonActualPlan.new(
      @nested_actual,
      [{[0_i32] of Int32, @inner_child_plan}] of Tuple(Array(Int32), CrystalClick::ObjectDocumentPlan),
    )
    @policy = CrystalClick::ObjectSharedAdvancedJsonWritePolicy.new(
      [outer_prepared, inner_prepared] of CrystalClick::ObjectSharedAdvancedJsonActualPlan,
      16,
    )
  end

  def outer_value(nested_values : Array(CrystalClick::BinaryValue)) : CrystalClick::BinaryValue
    array_type = @outer_actual.child_at(1)
    CrystalClick::BinaryValue.tuple(
      @outer_actual,
      [
        w244_json_value(@outer_json, CrystalClick::BinaryValue.fixed(
          CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[7_u8],
        )),
        CrystalClick::BinaryValue.array(array_type, nested_values),
      ] of CrystalClick::BinaryValue,
    )
  end

  def nested_value : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.tuple(
      @nested_actual,
      [
        w244_json_value(@inner_json, CrystalClick::BinaryValue.int64(7_i64)),
        CrystalClick::BinaryValue.fixed(CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[9_u8]),
      ] of CrystalClick::BinaryValue,
    )
  end

  def nested_dynamic_value(child : CrystalClick::BinaryValue? = nil) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.dynamic(@nested_dynamic, child)
  end
end

private def w244_child_plan(json_type : CrystalClick::BinaryDataType) : CrystalClick::ObjectDocumentPlan
  structures = CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new([] of String),
    {} of String => CrystalClick::DynamicStructure,
  )
  CrystalClick::ObjectDocumentPlan.new(
    structures,
    json_type.json_type.not_nil!.typed_paths,
  )
end

private def w244_json_value(
  type : CrystalClick::BinaryDataType,
  value : CrystalClick::BinaryValue,
) : CrystalClick::BinaryValue
  row = CrystalClick::BinaryJsonRow.new(
    type,
    [{"v", value}] of Tuple(String, CrystalClick::BinaryValue),
  )
  CrystalClick::BinaryValue.json(type, row)
end

private def w244_census(
  fixture : W244Fixture,
  values : Array(CrystalClick::BinaryValue),
) : CrystalClick::ObjectSharedDynamicSiteCensus
  w244_census(fixture, values, fixture.policy)
end

private def w244_census(
  fixture : W244Fixture,
  values : Array(CrystalClick::BinaryValue),
  policy : CrystalClick::ObjectSharedAdvancedJsonWritePolicy,
) : CrystalClick::ObjectSharedDynamicSiteCensus
  CrystalClick::ObjectSharedDynamicSiteCensus.build(
    values.map { |value| value.as(CrystalClick::BinaryValue?) },
    [fixture.outer_actual] of CrystalClick::BinaryDataType,
    policy,
    CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
  )
end

private def w244_wire_equal!(actual : CrystalClick::BinaryValue, expected : CrystalClick::BinaryValue) : Nil
  CrystalClick::BinaryValueCodec.encode(actual).should eq(CrystalClick::BinaryValueCodec.encode(expected))
end

describe "W244 JSON-bearing actual at a real nested Dynamic site" do
  it "binds exact owner-local leaves and roundtrips populated, empty, NULL, and spilled occurrences" do
    fixture = W244Fixture.new
    nested_value = fixture.nested_value
    string_spill = CrystalClick::BinaryValue.string("outside-json")
    outer_values = [
      fixture.outer_value([
        fixture.nested_dynamic_value(nested_value),
        fixture.nested_dynamic_value(nested_value),
      ] of CrystalClick::BinaryValue),
      fixture.outer_value([] of CrystalClick::BinaryValue),
      fixture.outer_value([
        fixture.nested_dynamic_value,
        fixture.nested_dynamic_value(string_spill),
        fixture.nested_dynamic_value(nested_value),
      ] of CrystalClick::BinaryValue),
    ] of CrystalClick::BinaryValue
    census = w244_census(fixture, outer_values)

    census.structures.keys.sort.should eq(["root", fixture.nested_site] of String)
    outer_structure = census.structures["root"]
    outer_structure.type_count.should eq(1)
    outer_structure.type_at(0).should eq(fixture.outer_actual)
    outer_structure.shared_index.should eq(0)
    outer_structure.canonical_variant_names[0].should eq("SharedVariant")
    outer_structure.canonical_index_for(fixture.outer_actual).should eq(1)

    nested_structure = census.structures[fixture.nested_site]
    nested_structure.type_count.should eq(1)
    nested_structure.type_at(0).should eq(fixture.nested_actual)
    nested_structure.type_at(0).should_not eq(string_spill.type)
    nested_structure.shared_index.should eq(0)
    nested_structure.canonical_variant_names[0].should eq("SharedVariant")
    nested_structure.canonical_index_for(fixture.nested_actual).should eq(1)

    census.leaf_bindings.size.should eq(2)
    outer_binding = census.leaf_bindings.find { |entry| entry[0].dynamic_site == "root" }.not_nil!
    nested_binding = census.leaf_bindings.find { |entry| entry[0].dynamic_site == fixture.nested_site }.not_nil!
    outer_binding[0].canonical_arm_index.should eq(1)
    outer_binding[0].descriptor_child_path.should eq([0_i32] of Int32)
    nested_binding[0].canonical_arm_index.should eq(1)
    nested_binding[0].descriptor_child_path.should eq([0_i32] of Int32)
    outer_binding[0].should_not eq(nested_binding[0])
    outer_binding[1].typed_type_for("v").should eq(CrystalClick::BinaryDataType.primitive("UInt8"))
    nested_binding[1].typed_type_for("v").should eq(CrystalClick::BinaryDataType.primitive("Int64"))

    rows = outer_values.map do |value|
      CrystalClick::BinaryValue.dynamic(fixture.outer_dynamic, value)
    end
    rows << CrystalClick::BinaryValue.dynamic(fixture.outer_dynamic)
    profile = CrystalClick::ObjectSharedPathCodec::COMPACT_PROFILE
    encoded = CrystalClick::ObjectSharedPathCodec.encode_with_json_children_with_budget(
      fixture.outer_dynamic,
      census.structures,
      rows,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
      census.leaf_bindings,
      CrystalClick::ObjectSharedNestedSerializationContext.for_write(0_u64, 1, profile),
      profile,
      fixture.policy,
    )
    decoded = CrystalClick::ObjectSharedPathCodec.decode_with_json_children_with_budget(
      encoded.data,
      encoded.events,
      rows.size,
      fixture.outer_dynamic,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
      CrystalClick::ObjectSharedNestedSerializationContext.for_read(0_u64, profile),
      profile,
    )
    decoded.structures[fixture.nested_site].type_at(0).should eq(fixture.nested_actual)
    rows.each_with_index { |expected, index| w244_wire_equal!(decoded.rows[index], expected) }
  end

  it "keeps empty-array-only and NULL-only nested census domains at zero ordinary actuals" do
    fixture = W244Fixture.new
    empty_array_values = [fixture.outer_value([] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue
    null_only_values = [
      fixture.outer_value([fixture.nested_dynamic_value] of CrystalClick::BinaryValue),
    ] of CrystalClick::BinaryValue

    [empty_array_values, null_only_values].each do |values|
      census = w244_census(fixture, values)
      census.structures[fixture.nested_site].type_count.should eq(0)
      # Only the observed outer Tuple owns a JSON leaf binding; the prepared
      # inner plan does not invent a nested ordinary arm or child prefix.
      census.leaf_bindings.size.should eq(1)
      census.leaf_bindings[0][0].dynamic_site.should eq("root")
    end
  end

  it "rejects an observed nested JSON actual without its prepared child plan" do
    fixture = W244Fixture.new
    outer_prepared = CrystalClick::ObjectSharedAdvancedJsonActualPlan.new(
      fixture.outer_actual,
      [{[0_i32] of Int32, fixture.outer_child_plan}] of Tuple(Array(Int32), CrystalClick::ObjectDocumentPlan),
    )
    policy = CrystalClick::ObjectSharedAdvancedJsonWritePolicy.new(
      [outer_prepared] of CrystalClick::ObjectSharedAdvancedJsonActualPlan,
      16,
    )
    values = [fixture.outer_value([fixture.nested_dynamic_value(fixture.nested_value)] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue

    error = expect_raises(CrystalClick::UnsupportedFormatError) do
      w244_census(fixture, values, policy)
    end
    error.message.to_s.should contain("no prepared child plan")
  end

  it "rejects a same-value UInt8 JSON type mutation against the prepared Int64 actual" do
    fixture = W244Fixture.new
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    wrong_inner_json = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 0,
      max_dynamic_types: 0,
      typed_paths: {"v" => uint8} of String => CrystalClick::BinaryDataType,
    )
    wrong_nested_actual = CrystalClick::BinaryDataType.tuple(
      [wrong_inner_json, uint8] of CrystalClick::BinaryDataType,
    )
    wrong_nested_value = CrystalClick::BinaryValue.tuple(
      wrong_nested_actual,
      [
        w244_json_value(wrong_inner_json, CrystalClick::BinaryValue.fixed(uint8, Bytes[7_u8])),
        CrystalClick::BinaryValue.fixed(uint8, Bytes[9_u8]),
      ] of CrystalClick::BinaryValue,
    )
    values = [
      fixture.outer_value([fixture.nested_dynamic_value(wrong_nested_value)] of CrystalClick::BinaryValue),
    ] of CrystalClick::BinaryValue

    error = expect_raises(CrystalClick::UnsupportedFormatError) do
      w244_census(fixture, values)
    end
    error.message.to_s.should contain("no prepared child plan")
  end

  it "rejects a wrong child schema and a nested leaf flattened onto the root owner" do
    fixture = W244Fixture.new
    wrong_inner_json_plan = w244_child_plan(fixture.outer_json)
    expect_raises(ArgumentError) do
      CrystalClick::ObjectSharedAdvancedJsonActualPlan.new(
        fixture.nested_actual,
        [{[0_i32] of Int32, wrong_inner_json_plan}] of Tuple(Array(Int32), CrystalClick::ObjectDocumentPlan),
      )
    end

    values = [fixture.outer_value([fixture.nested_dynamic_value(fixture.nested_value)] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue
    census = w244_census(fixture, values)
    flattened = [] of W244LeafBinding
    census.leaf_bindings.each do |entry|
      key, plan = entry
      if key.dynamic_site == fixture.nested_site
        flattened << {
          CrystalClick::BinaryDynamicJsonLeafKey.new("root", key.canonical_arm_index, key.descriptor_child_path),
          plan,
        }
      else
        flattened << entry
      end
    end

    # The outer and nested local keys would both be (root, arm 1, child [0]);
    # retaining the nested site is what keeps the two typed plans distinct.
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDynamicBulkPlan.new_with_prefix_without_statistics(
        fixture.outer_dynamic,
        census.structures,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
        CrystalClick::ObjectSharedPathCodec::COMPACT_PROFILE,
        flattened,
      )
    end
  end

  it "retains typed-schema and runtime-JSON Dynamic guards" do
    dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    array_type = CrystalClick::BinaryDataType.array(dynamic_type)
    guarded_json = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 0,
      max_dynamic_types: 0,
      typed_paths: {"nested" => array_type} of String => CrystalClick::BinaryDataType,
    )
    guarded_actual = CrystalClick::BinaryDataType.tuple([guarded_json] of CrystalClick::BinaryDataType)
    expect_raises(ArgumentError, "Dynamic") do
      CrystalClick::ObjectSharedAdvancedJsonActualPlan.new(
        guarded_actual,
        [{[0_i32] of Int32, w244_child_plan(guarded_json)}] of Tuple(Array(Int32), CrystalClick::ObjectDocumentPlan),
      )
    end

    runtime_value = CrystalClick::BinaryValue.array(
      array_type,
      [CrystalClick::BinaryValue.dynamic(dynamic_type, CrystalClick::BinaryValue.fixed(
        CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[7_u8],
      ))] of CrystalClick::BinaryValue,
    )
    runtime_json = CrystalClick::BinaryDataType.json
    runtime_row = CrystalClick::BinaryJsonRow.new(
      runtime_json,
      [{"runtime", runtime_value}] of Tuple(String, CrystalClick::BinaryValue),
    )
    value = CrystalClick::BinaryValue.json(runtime_json, runtime_row)
    ordinary_wire = CrystalClick::BinaryValueCodec.encode(value)

    write_error = expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode_shared_json_envelope(
        value,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
      )
    end
    write_error.message.to_s.should contain("Dynamic")
    read_error = expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.decode_shared_json_envelope(
        ordinary_wire,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
      )
    end
    read_error.message.to_s.should contain("Dynamic")
  end
end
