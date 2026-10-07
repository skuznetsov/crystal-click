require "./spec_helper"

private alias W215LeafPlan = Tuple(
  CrystalClick::BinaryDynamicJsonLeafKey,
  CrystalClick::ObjectDocumentPlan,
)

private def w215_json_type : CrystalClick::BinaryDataType
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  CrystalClick::BinaryDataType.json(
    max_dynamic_paths: 0,
    max_dynamic_types: 0,
    typed_paths: {"v" => uint8} of String => CrystalClick::BinaryDataType,
  )
end

private def w215_json_value(type : CrystalClick::BinaryDataType, value : UInt8) : CrystalClick::BinaryValue
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  CrystalClick::BinaryValue.json(
    type,
    CrystalClick::BinaryJsonRow.new(
      type,
      [{"v", CrystalClick::BinaryValue.fixed(uint8, Bytes[value])}] of Tuple(String, CrystalClick::BinaryValue),
    ),
  )
end

private def w215_child_plan(type : CrystalClick::BinaryDataType) : CrystalClick::ObjectDocumentPlan
  structures = CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new([] of String),
    {} of String => CrystalClick::DynamicStructure,
  )
  CrystalClick::ObjectDocumentPlan.new(structures, type.json_type.not_nil!.typed_paths)
end

private def w215_json_leaf(
  site : String,
  structure : CrystalClick::DynamicStructure,
  type : CrystalClick::BinaryDataType,
  path : Array(Int32),
  child : CrystalClick::ObjectDocumentPlan,
) : W215LeafPlan
  {
    CrystalClick::BinaryDynamicJsonLeafKey.new(site, structure.canonical_index_for(type), path),
    child,
  }
end

private def w215_empty_structures : CrystalClick::ObjectDynamicStructureSet
  CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new([] of String),
    {} of String => CrystalClick::DynamicStructure,
  )
end

describe "W215 ordinary JSON actuals in declared Object Dynamic" do
  it "keeps an unbound ordinary JSON actual outside the Object declaration roster" do
    json = w215_json_type
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    schema = CrystalClick::ObjectDocumentSchema.new({"p" => dynamic})
    json_roster = CrystalClick::DynamicStructure.new([json] of CrystalClick::BinaryDataType)

    expect_raises(ArgumentError, "invalid typed Object Dynamic actual roster") do
      CrystalClick::ObjectDocumentPlan.new(
        w215_empty_structures,
        schema.typed_paths,
        {"p" => json_roster} of String => CrystalClick::DynamicStructure,
      )
    end
  end

  it "round-trips a direct JSON actual only with its exact child Object binding" do
    json = w215_json_type
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    schema = CrystalClick::ObjectDocumentSchema.new({"p" => dynamic})
    actuals = CrystalClick::DynamicStructure.new([json] of CrystalClick::BinaryDataType)
    child = w215_child_plan(json)
    binding = w215_json_leaf("root", actuals, json, [] of Int32, child)
    typed_dynamics = {"p" => actuals} of String => CrystalClick::DynamicStructure
    bindings = {"p" => [binding] of W215LeafPlan} of String => Array(W215LeafPlan)

    # The old constructor call remains an explicit negative, even though the
    # exact same JSON type is admitted when its child Object plan is bound.
    expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentPlan.new(w215_empty_structures, schema.typed_paths, typed_dynamics)
    end
    plan = CrystalClick::ObjectDocumentPlan.new(
      w215_empty_structures,
      schema.typed_paths,
      typed_dynamics,
      typed_dynamic_json_object_leaf_plans: bindings,
    )

    value = CrystalClick::BinaryValue.dynamic(dynamic, w215_json_value(json, 7_u8))
    documents = [[CrystalClick::ObjectDocument.new({"p" => value})] of CrystalClick::ObjectDocument]
    streams = CrystalClick::ObjectDocumentCodec.encode(plan, documents)
    decoded = CrystalClick::ObjectDocumentCodec.decode(
      schema.typed_paths,
      streams,
      typed_dynamic_json_object_leaf_plans: bindings,
    )

    decoded.size.should eq(1)
    decoded[0].size.should eq(1)
    decoded[0][0].value_for("p").child_at(0).json_row.value_for("v").not_nil!.byte_at(0).should eq(7_u8)

    wrong = w215_json_leaf("root", actuals, json, [0_i32] of Int32, child)
    expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentPlan.new(
        w215_empty_structures,
        schema.typed_paths,
        typed_dynamics,
        typed_dynamic_json_object_leaf_plans: {"p" => [wrong] of W215LeafPlan} of String => Array(W215LeafPlan),
      )
    end
  end

  it "rejects incomplete, excess, duplicate, and wrong-schema JSON child bindings" do
    json = w215_json_type
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    schema = CrystalClick::ObjectDocumentSchema.new({"p" => dynamic})
    actuals = CrystalClick::DynamicStructure.new([json] of CrystalClick::BinaryDataType)
    typed_dynamics = {"p" => actuals} of String => CrystalClick::DynamicStructure
    child = w215_child_plan(json)
    exact = w215_json_leaf("root", actuals, json, [] of Int32, child)

    expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentPlan.new(
        w215_empty_structures,
        schema.typed_paths,
        typed_dynamics,
        typed_dynamic_json_object_leaf_plans: {} of String => Array(W215LeafPlan),
      )
    end
    expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentPlan.new(
        w215_empty_structures,
        schema.typed_paths,
        typed_dynamics,
        typed_dynamic_json_object_leaf_plans: {
          "unrelated" => [exact] of W215LeafPlan,
        } of String => Array(W215LeafPlan),
      )
    end
    expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentPlan.new(
        w215_empty_structures,
        schema.typed_paths,
        typed_dynamics,
        typed_dynamic_json_object_leaf_plans: {
          "p" => [exact, exact] of W215LeafPlan,
        } of String => Array(W215LeafPlan),
      )
    end

    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    wrong_json = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 0,
      max_dynamic_types: 0,
      typed_paths: {"v" => uint64} of String => CrystalClick::BinaryDataType,
    )
    wrong_child = w215_child_plan(wrong_json)
    wrong = w215_json_leaf("root", actuals, json, [] of Int32, wrong_child)
    expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentPlan.new(
        w215_empty_structures,
        schema.typed_paths,
        typed_dynamics,
        typed_dynamic_json_object_leaf_plans: {"p" => [wrong] of W215LeafPlan} of String => Array(W215LeafPlan),
      )
    end
  end

  it "propagates a child Object plan's own JSON binding recursively" do
    json = w215_json_type
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    inner_roster = CrystalClick::DynamicStructure.new([json] of CrystalClick::BinaryDataType)
    outer_json = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 0,
      max_dynamic_types: 0,
      typed_paths: {"nested" => dynamic} of String => CrystalClick::BinaryDataType,
    )
    outer_roster = CrystalClick::DynamicStructure.new([outer_json] of CrystalClick::BinaryDataType)
    empty = w215_empty_structures
    inner_plan = w215_child_plan(json)
    # The outer JSON child's own typed Dynamic path has a separate actual
    # roster and binding table; the parent field binding must retain that child
    # plan intact through both encode and decode.
    nested_binding = w215_json_leaf("root", inner_roster, json, [] of Int32, inner_plan)
    child_plan = CrystalClick::ObjectDocumentPlan.new(
      empty,
      outer_json.json_type.not_nil!.typed_paths,
      {"nested" => inner_roster} of String => CrystalClick::DynamicStructure,
      typed_dynamic_json_object_leaf_plans: {
        "nested" => [nested_binding] of W215LeafPlan,
      } of String => Array(W215LeafPlan),
    )
    parent_binding = w215_json_leaf("root", outer_roster, outer_json, [] of Int32, child_plan)
    schema = CrystalClick::ObjectDocumentSchema.new({"p" => dynamic})
    plan = CrystalClick::ObjectDocumentPlan.new(
      empty,
      schema.typed_paths,
      {"p" => outer_roster} of String => CrystalClick::DynamicStructure,
      typed_dynamic_json_object_leaf_plans: {
        "p" => [parent_binding] of W215LeafPlan,
      } of String => Array(W215LeafPlan),
    )
    inner_value = w215_json_value(json, 73_u8)
    outer_value = CrystalClick::BinaryValue.json(
      outer_json,
      CrystalClick::BinaryJsonRow.new(
        outer_json,
        [{"nested", CrystalClick::BinaryValue.dynamic(dynamic, inner_value)}] of Tuple(String, CrystalClick::BinaryValue),
      ),
    )
    documents = [[
      CrystalClick::ObjectDocument.new({
        "p" => CrystalClick::BinaryValue.dynamic(dynamic, outer_value),
      } of String => CrystalClick::BinaryValue),
    ] of CrystalClick::ObjectDocument]

    streams = CrystalClick::ObjectDocumentCodec.encode(plan, documents)
    decoded = CrystalClick::ObjectDocumentCodec.decode(
      schema.typed_paths,
      streams,
      typed_dynamic_json_object_leaf_plans: {
        "p" => [parent_binding] of W215LeafPlan,
      } of String => Array(W215LeafPlan),
    )
    nested_json = decoded[0][0].value_for("p").child_at(0).json_row.value_for("nested").not_nil!
    nested_json.child_at(0).json_row.value_for("v").not_nil!.byte_at(0).should eq(73_u8)
  end

  it "composes the selected JSON child depth and aggregate budget with its Object owner" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    array = CrystalClick::BinaryDataType.array(uint8)
    json = CrystalClick::BinaryDataType.json(max_dynamic_paths: 1, max_dynamic_types: 1)
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    actuals = CrystalClick::DynamicStructure.new([json] of CrystalClick::BinaryDataType)
    json_value = CrystalClick::BinaryValue.json(
      json,
      CrystalClick::BinaryJsonRow.new(
        json,
        [{"items", CrystalClick::BinaryValue.array(array, [CrystalClick::BinaryValue.fixed(uint8, Bytes[9_u8])] of CrystalClick::BinaryValue)}] of Tuple(String, CrystalClick::BinaryValue),
      ),
    )
    child_structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(["items"] of String),
      {"items" => CrystalClick::DynamicStructure.new([array] of CrystalClick::BinaryDataType)} of String => CrystalClick::DynamicStructure,
    )
    child_plan = CrystalClick::ObjectDocumentPlan.new(child_structures, json.json_type.not_nil!.typed_paths)
    binding = w215_json_leaf("root", actuals, json, [] of Int32, child_plan)
    schema = CrystalClick::ObjectDocumentSchema.new({"p" => dynamic})
    bindings = {"p" => [binding] of W215LeafPlan} of String => Array(W215LeafPlan)
    plan = CrystalClick::ObjectDocumentPlan.new(
      w215_empty_structures,
      schema.typed_paths,
      {"p" => actuals} of String => CrystalClick::DynamicStructure,
      typed_dynamic_json_object_leaf_plans: bindings,
    )
    documents = [[CrystalClick::ObjectDocument.new({
      "p" => CrystalClick::BinaryValue.dynamic(dynamic, json_value),
    } of String => CrystalClick::BinaryValue)] of CrystalClick::ObjectDocument]
    limits = ->(max_depth : Int32, max_nodes : Int64) do
      CrystalClick::BinaryCodecLimits.new(
        max_depth: max_depth,
        max_nodes: max_nodes,
        max_elements: 256,
        max_bytes: 4096,
      )
    end

    depth_six = limits.call(6_i32, 256_i64)
    streams = CrystalClick::ObjectDocumentCodec.encode(plan, documents, limits: depth_six)
    decoded = CrystalClick::ObjectDocumentCodec.decode(schema.typed_paths, streams, limits: depth_six,
      typed_dynamic_json_object_leaf_plans: bindings)
    decoded[0][0].value_for("p").child_at(0).json_row.value_for("items").not_nil!.element_at(0).byte_at(0).should eq(9_u8)

    depth_five = limits.call(5_i32, 256_i64)
    expect_raises(CrystalClick::UnsupportedFormatError, "depth") do
      CrystalClick::ObjectDocumentCodec.encode(plan, documents, limits: depth_five)
    end
    expect_raises(CrystalClick::CorruptPartError, "depth") do
      CrystalClick::ObjectDocumentCodec.decode(schema.typed_paths, streams, limits: depth_five,
        typed_dynamic_json_object_leaf_plans: bindings)
    end

    one_node = limits.call(6_i32, 1_i64)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentCodec.encode(plan, documents, limits: one_node)
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectDocumentCodec.decode(schema.typed_paths, streams, limits: one_node,
        typed_dynamic_json_object_leaf_plans: bindings)
    end
  end

  it "binds direct, Array, Tuple, and multiple Array(Dynamic) JSON sites independently" do
    json = w215_json_type
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 2)
    array_json = CrystalClick::BinaryDataType.array(json)
    tuple_json = CrystalClick::BinaryDataType.tuple([json, json] of CrystalClick::BinaryDataType)
    array_dynamic = CrystalClick::BinaryDataType.array(dynamic)
    schema = CrystalClick::ObjectDocumentSchema.new({
      "direct"  => dynamic,
      "wrapped" => dynamic,
      "pair"    => dynamic,
      "sites"   => array_dynamic,
    } of String => CrystalClick::BinaryDataType)

    direct_roster = CrystalClick::DynamicStructure.new([json] of CrystalClick::BinaryDataType)
    array_roster = CrystalClick::DynamicStructure.new([array_json] of CrystalClick::BinaryDataType)
    tuple_roster = CrystalClick::DynamicStructure.new([tuple_json] of CrystalClick::BinaryDataType)
    site_roster = CrystalClick::DynamicStructure.new(
      [json, array_json] of CrystalClick::BinaryDataType,
    )
    child = w215_child_plan(json)
    typed_dynamics = {
      "direct"  => direct_roster,
      "wrapped" => array_roster,
      "pair"    => tuple_roster,
    } of String => CrystalClick::DynamicStructure
    typed_sites = {
      "sites" => {"root.elements" => site_roster} of String => CrystalClick::DynamicStructure,
    } of String => Hash(String, CrystalClick::DynamicStructure)
    bindings = {
      "direct"  => [w215_json_leaf("root", direct_roster, json, [] of Int32, child)] of W215LeafPlan,
      "wrapped" => [w215_json_leaf("root", array_roster, array_json, [0_i32] of Int32, child)] of W215LeafPlan,
      "pair"    => [
        w215_json_leaf("root", tuple_roster, tuple_json, [0_i32] of Int32, child),
        w215_json_leaf("root", tuple_roster, tuple_json, [1_i32] of Int32, child),
      ] of W215LeafPlan,
      "sites" => [
        w215_json_leaf("root.elements", site_roster, json, [] of Int32, child),
        w215_json_leaf("root.elements", site_roster, array_json, [0_i32] of Int32, child),
      ] of W215LeafPlan,
    } of String => Array(W215LeafPlan)
    plan = CrystalClick::ObjectDocumentPlan.new(
      w215_empty_structures,
      schema.typed_paths,
      typed_dynamics,
      typed_dynamic_sites: typed_sites,
      typed_dynamic_json_object_leaf_plans: bindings,
    )

    direct = CrystalClick::BinaryValue.dynamic(dynamic, w215_json_value(json, 11_u8))
    wrapped = CrystalClick::BinaryValue.dynamic(
      dynamic,
      CrystalClick::BinaryValue.array(array_json, [w215_json_value(json, 21_u8), w215_json_value(json, 22_u8)] of CrystalClick::BinaryValue),
    )
    pair = CrystalClick::BinaryValue.dynamic(
      dynamic,
      CrystalClick::BinaryValue.tuple(
        tuple_json,
        [w215_json_value(json, 31_u8), w215_json_value(json, 32_u8)] of CrystalClick::BinaryValue,
      ),
    )
    site_array = CrystalClick::BinaryValue.array(array_dynamic, [
      CrystalClick::BinaryValue.dynamic(dynamic, w215_json_value(json, 41_u8)),
      CrystalClick::BinaryValue.dynamic(dynamic, nil),
      CrystalClick::BinaryValue.dynamic(
        dynamic,
        CrystalClick::BinaryValue.array(array_json, [w215_json_value(json, 42_u8)] of CrystalClick::BinaryValue),
      ),
    ] of CrystalClick::BinaryValue)
    second = CrystalClick::ObjectDocument.new({
      "direct"  => CrystalClick::BinaryValue.dynamic(dynamic, nil),
      "wrapped" => CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.array(array_json, [] of CrystalClick::BinaryValue)),
      "pair"    => CrystalClick::BinaryValue.dynamic(
        dynamic,
        CrystalClick::BinaryValue.tuple(tuple_json, [w215_json_value(json, 33_u8), w215_json_value(json, 34_u8)] of CrystalClick::BinaryValue),
      ),
      "sites" => CrystalClick::BinaryValue.array(array_dynamic, [] of CrystalClick::BinaryValue),
    } of String => CrystalClick::BinaryValue)
    documents = [[
      CrystalClick::ObjectDocument.new({
        "direct"  => direct,
        "wrapped" => wrapped,
        "pair"    => pair,
        "sites"   => site_array,
      } of String => CrystalClick::BinaryValue),
      second,
    ] of CrystalClick::ObjectDocument]

    streams = CrystalClick::ObjectDocumentCodec.encode(plan, documents)
    decoded = CrystalClick::ObjectDocumentCodec.decode(
      schema.typed_paths,
      streams,
      typed_dynamic_json_object_leaf_plans: bindings,
    )
    decoded.size.should eq(1)
    decoded[0].size.should eq(2)
    row = decoded[0][0]
    row.value_for("direct").child_at(0).json_row.value_for("v").not_nil!.byte_at(0).should eq(11_u8)
    array_value = row.value_for("wrapped").child_at(0)
    array_value.element_count.should eq(2)
    array_value.element_at(0).json_row.value_for("v").not_nil!.byte_at(0).should eq(21_u8)
    array_value.element_at(1).json_row.value_for("v").not_nil!.byte_at(0).should eq(22_u8)
    tuple_value = row.value_for("pair").child_at(0)
    tuple_value.child_at(0).json_row.value_for("v").not_nil!.byte_at(0).should eq(31_u8)
    tuple_value.child_at(1).json_row.value_for("v").not_nil!.byte_at(0).should eq(32_u8)
    site_value = row.value_for("sites")
    site_value.element_count.should eq(3)
    site_value.element_at(0).child_at(0).json_row.value_for("v").not_nil!.byte_at(0).should eq(41_u8)
    site_value.element_at(1).is_null?.should be_true
    site_value.element_at(2).child_at(0).element_at(0).json_row.value_for("v").not_nil!.byte_at(0).should eq(42_u8)
    decoded[0][1].value_for("direct").is_null?.should be_true
    decoded[0][1].value_for("wrapped").child_at(0).element_count.should eq(0)
  end

  it "rejects child Object descriptor origins below the minimum before charging caller budgets" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    roster = CrystalClick::DynamicStructure.new([uint8] of CrystalClick::BinaryDataType)
    schema = CrystalClick::ObjectDocumentSchema.new({"p" => dynamic} of String => CrystalClick::BinaryDataType)
    plan = CrystalClick::ObjectDocumentPlan.new(
      w215_empty_structures,
      schema.typed_paths,
      {"p" => roster} of String => CrystalClick::DynamicStructure,
    )
    documents = [[CrystalClick::ObjectDocument.new({
      "p" => CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.fixed(uint8, Bytes[7_u8])),
    } of String => CrystalClick::BinaryValue)] of CrystalClick::ObjectDocument]
    limits = CrystalClick::BinaryCodecLimits.new(
      max_depth: 8,
      max_nodes: 256,
      max_elements: 256,
      max_bytes: 4096,
    )
    write_grid = CrystalClick::StorageOccurrenceGrid.new(
      [1_u64], [1_u64], CrystalClick::BinaryCodecBudget.new(limits, true),
    )
    bad_write = CrystalClick::BinaryCodecBudget.new(limits, true)
    expect_raises(CrystalClick::UnsupportedFormatError, "depth") do
      CrystalClick::ObjectDocumentCodec.encode_child_site_with_budget(
        plan,
        documents,
        write_grid,
        bad_write,
        typed_descriptor_root_depth: 1,
      )
    end
    bad_write.node_count.should eq(0_i64)
    bad_write.element_count.should eq(0_i64)
    bad_write.wire_byte_count.should eq(0_i64)

    streams = CrystalClick::ObjectDocumentCodec.encode_child_site_with_budget(
      plan,
      documents,
      write_grid,
      CrystalClick::BinaryCodecBudget.new(limits, true),
      typed_descriptor_root_depth: 2,
    )
    read_grid = CrystalClick::StorageOccurrenceGrid.new(
      [1_u64], [1_u64], CrystalClick::BinaryCodecBudget.new(limits, true),
    )
    bad_read = CrystalClick::BinaryCodecBudget.new(limits)
    expect_raises(CrystalClick::CorruptPartError, "depth") do
      CrystalClick::ObjectDocumentCodec.decode_child_site_with_budget(
        schema.typed_paths,
        streams,
        read_grid,
        bad_read,
        typed_descriptor_root_depth: 1,
      )
    end
    bad_read.node_count.should eq(0_i64)
    bad_read.element_count.should eq(0_i64)
    bad_read.wire_byte_count.should eq(0_i64)

    decoded = CrystalClick::ObjectDocumentCodec.decode_child_site_with_budget(
      schema.typed_paths,
      streams,
      read_grid,
      CrystalClick::BinaryCodecBudget.new(limits),
      typed_descriptor_root_depth: 2,
    )
    decoded[0][0].value_for("p").child_at(0).byte_at(0).should eq(7_u8)
  end

  it "binds a Nullable JSON leaf inside a legal tuple actual and retains its hidden default row" do
    json = w215_json_type
    nullable_json = CrystalClick::BinaryDataType.nullable(json)
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    tuple = CrystalClick::BinaryDataType.tuple(
      [nullable_json, uint8] of CrystalClick::BinaryDataType,
    )
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    roster = CrystalClick::DynamicStructure.new([tuple] of CrystalClick::BinaryDataType)
    child = w215_child_plan(json)
    binding = {
      CrystalClick::BinaryDynamicJsonLeafKey.new(
        "root", roster.canonical_index_for(tuple), [0_i32, 0_i32] of Int32,
      ),
      child,
    }
    schema = CrystalClick::ObjectDocumentSchema.new({"p" => dynamic} of String => CrystalClick::BinaryDataType)
    bindings = {"p" => [binding] of W215LeafPlan} of String => Array(W215LeafPlan)
    plan = CrystalClick::ObjectDocumentPlan.new(
      w215_empty_structures,
      schema.typed_paths,
      {"p" => roster} of String => CrystalClick::DynamicStructure,
      typed_dynamic_json_object_leaf_plans: bindings,
    )
    selected_null = CrystalClick::BinaryValue.dynamic(
      dynamic,
      CrystalClick::BinaryValue.tuple(tuple, [
        CrystalClick::BinaryValue.nullable(nullable_json),
        CrystalClick::BinaryValue.fixed(uint8, Bytes[8_u8]),
      ] of CrystalClick::BinaryValue),
    )
    selected_value = CrystalClick::BinaryValue.dynamic(
      dynamic,
      CrystalClick::BinaryValue.tuple(tuple, [
        CrystalClick::BinaryValue.nullable(nullable_json, w215_json_value(json, 55_u8)),
        CrystalClick::BinaryValue.fixed(uint8, Bytes[9_u8]),
      ] of CrystalClick::BinaryValue),
    )
    documents = [[
      CrystalClick::ObjectDocument.new({"p" => selected_null} of String => CrystalClick::BinaryValue),
      CrystalClick::ObjectDocument.new({"p" => selected_value} of String => CrystalClick::BinaryValue),
    ] of CrystalClick::ObjectDocument]

    streams = CrystalClick::ObjectDocumentCodec.encode(plan, documents)
    typed_dynamic = streams.typed_dynamic_for("p")
    child_streams = typed_dynamic.json_object_leaf_for(binding[0])
    child_streams.rows_per_mark.should eq([2_u64])
    child_streams.typed_for("v").stream("root.data").bytes.should eq(Bytes[0_u8, 55_u8])

    decoded = CrystalClick::ObjectDocumentCodec.decode(
      schema.typed_paths,
      streams,
      typed_dynamic_json_object_leaf_plans: bindings,
    )
    null_tuple = decoded[0][0].value_for("p").child_at(0)
    null_actual = null_tuple.child_at(0)
    null_actual.type.should eq(nullable_json)
    null_actual.is_null?.should be_true
    null_tuple.child_at(1).byte_at(0).should eq(8_u8)
    value_tuple = decoded[0][1].value_for("p").child_at(0)
    value_actual = value_tuple.child_at(0)
    value_actual.type.should eq(nullable_json)
    value_actual.is_null?.should be_false
    value_actual.child_at(0).json_row.value_for("v").not_nil!.byte_at(0).should eq(55_u8)
    value_tuple.child_at(1).byte_at(0).should eq(9_u8)
  end
end
