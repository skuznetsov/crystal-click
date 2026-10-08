require "./spec_helper"

private alias W216LeafPlan = Tuple(
  CrystalClick::BinaryDynamicJsonLeafKey,
  CrystalClick::ObjectDocumentPlan,
)

private alias W216LeafMap = Hash(String, Array(W216LeafPlan))

private struct W216DepthFixture
  getter schema : Hash(String, CrystalClick::BinaryDataType)
  getter plan : CrystalClick::ObjectDocumentPlan
  getter documents : Array(Array(CrystalClick::ObjectDocument))
  getter bindings : W216LeafMap

  def initialize(
    @schema : Hash(String, CrystalClick::BinaryDataType),
    @plan : CrystalClick::ObjectDocumentPlan,
    @documents : Array(Array(CrystalClick::ObjectDocument)),
    @bindings : W216LeafMap,
  )
  end
end

private def w216_json_type : CrystalClick::BinaryDataType
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  CrystalClick::BinaryDataType.json(
    max_dynamic_paths: 0,
    max_dynamic_types: 0,
    typed_paths: {"v" => uint8} of String => CrystalClick::BinaryDataType,
  )
end

private def w216_text_json_type : CrystalClick::BinaryDataType
  string = CrystalClick::BinaryDataType.primitive("String")
  CrystalClick::BinaryDataType.json(
    max_dynamic_paths: 0,
    max_dynamic_types: 0,
    typed_paths: {"text" => string} of String => CrystalClick::BinaryDataType,
  )
end

private def w216_child_plan(type : CrystalClick::BinaryDataType) : CrystalClick::ObjectDocumentPlan
  structures = CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new([] of String),
    {} of String => CrystalClick::DynamicStructure,
  )
  CrystalClick::ObjectDocumentPlan.new(structures, type.json_type.not_nil!.typed_paths)
end

private def w216_limits(max_depth : Int32, max_nodes : Int64 = 100_000_i64) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(
    max_depth: max_depth,
    max_nodes: max_nodes,
    max_elements: 100_000,
    max_bytes: 1_000_000,
  )
end

private def w216_depth_fixture(array_leaf : Bool, nested : Bool) : W216DepthFixture
  inner_json = w216_json_type
  outer_json = if nested
                 CrystalClick::BinaryDataType.json(
                   max_dynamic_paths: 1,
                   max_dynamic_types: 1,
                 )
               else
                 inner_json
               end

  child_structures = if nested
                       CrystalClick::ObjectDynamicStructureSet.new(
                         CrystalClick::ObjectStructure.new(["nested"] of String),
                         {"nested" => CrystalClick::DynamicStructure.new([inner_json] of CrystalClick::BinaryDataType)} of String => CrystalClick::DynamicStructure,
                       )
                     else
                       CrystalClick::ObjectDynamicStructureSet.new(
                         CrystalClick::ObjectStructure.new([] of String),
                         {} of String => CrystalClick::DynamicStructure,
                       )
                     end
  nested_bindings = if nested
                      nested_roster = child_structures.dynamic_for("nested")
                      {
                        "nested" => [{
                          CrystalClick::BinaryDynamicJsonLeafKey.new(
                            "root", nested_roster.canonical_index_for(inner_json), [] of Int32,
                          ),
                          w216_child_plan(inner_json),
                        }] of W216LeafPlan,
                      } of String => Array(W216LeafPlan)
                    else
                      {} of String => Array(W216LeafPlan)
                    end
  json_child_plan = CrystalClick::ObjectDocumentPlan.new(
    child_structures,
    outer_json.json_type.not_nil!.typed_paths,
    root_dynamic_json_object_leaf_plans: nested_bindings,
  )

  actual_type = array_leaf ? CrystalClick::BinaryDataType.array(outer_json) : outer_json
  root_roster = CrystalClick::DynamicStructure.new([actual_type] of CrystalClick::BinaryDataType)
  root_structures = CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new(["payload"] of String),
    {"payload" => root_roster} of String => CrystalClick::DynamicStructure,
  )
  root_bindings = {
    "payload" => [{
      CrystalClick::BinaryDynamicJsonLeafKey.new(
        "root",
        root_roster.canonical_index_for(actual_type),
        array_leaf ? [0_i32] of Int32 : [] of Int32,
      ),
      json_child_plan,
    }] of W216LeafPlan,
  } of String => Array(W216LeafPlan)
  plan = CrystalClick::ObjectDocumentPlan.new(
    root_structures,
    {} of String => CrystalClick::BinaryDataType,
    root_dynamic_json_object_leaf_plans: root_bindings,
  )

  json_values = if nested
                  [{
                    "nested",
                    w216_json_value(inner_json, 63_u8),
                  }] of Tuple(String, CrystalClick::BinaryValue)
                else
                  [{
                    "v",
                    CrystalClick::BinaryValue.fixed(
                      CrystalClick::BinaryDataType.primitive("UInt8"),
                      Bytes[63_u8],
                    ),
                  }] of Tuple(String, CrystalClick::BinaryValue)
                end
  outer_value = CrystalClick::BinaryValue.json(
    outer_json,
    CrystalClick::BinaryJsonRow.new(outer_json, json_values),
  )
  payload = if array_leaf
              CrystalClick::BinaryValue.array(actual_type, [outer_value] of CrystalClick::BinaryValue)
            else
              outer_value
            end
  document = CrystalClick::ObjectDocument.new({"payload" => payload} of String => CrystalClick::BinaryValue)
  schema = CrystalClick::ObjectDocumentSchema.new({} of String => CrystalClick::BinaryDataType)
  W216DepthFixture.new(
    schema.typed_paths,
    plan,
    [[document] of CrystalClick::ObjectDocument],
    root_bindings,
  )
end

private def w216_json_value(type : CrystalClick::BinaryDataType, value : UInt8) : CrystalClick::BinaryValue
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  CrystalClick::BinaryValue.json(
    type,
    CrystalClick::BinaryJsonRow.new(
      type,
      [{"v", CrystalClick::BinaryValue.fixed(uint8, Bytes[value])}] of Tuple(String, CrystalClick::BinaryValue),
    ),
  )
end

private def w216_text_json_value(type : CrystalClick::BinaryDataType, value : String) : CrystalClick::BinaryValue
  string = CrystalClick::BinaryDataType.primitive("String")
  CrystalClick::BinaryValue.json(
    type,
    CrystalClick::BinaryJsonRow.new(
      type,
      [{"text", CrystalClick::BinaryValue.string(value)}] of Tuple(String, CrystalClick::BinaryValue),
    ),
  )
end

describe "W216 root inferred Dynamic JSON actuals" do
  it "keeps the default unbound root Dynamic JSON roster rejected" do
    json = w216_json_type
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(["payload"] of String),
      {"payload" => CrystalClick::DynamicStructure.new([json] of CrystalClick::BinaryDataType)} of String => CrystalClick::DynamicStructure,
    )

    expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentPlan.new(
        structures,
        {} of String => CrystalClick::BinaryDataType,
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError, "JSON") do
      CrystalClick::DynamicValueCodec.encode(
        structures.dynamic_for("payload"),
        [[w216_json_value(json, 1_u8)] of CrystalClick::BinaryValue],
      )
    end

    empty_streams = CrystalClick::DynamicValueStreams.new(
      CrystalClick::DynamicDiscriminatorStream.new(
        Bytes.empty,
        [] of CrystalClick::DynamicDiscriminatorMark,
      ),
      {} of String => CrystalClick::BinaryBulkStreams,
    )
    expect_raises(CrystalClick::UnsupportedFormatError, "JSON") do
      CrystalClick::DynamicValueCodec.decode(structures.dynamic_for("payload"), empty_streams)
    end
  end

  it "seals root JSON writers to the roster's exact arm and inherited origin" do
    json = w216_json_type
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    string = CrystalClick::BinaryDataType.primitive("String")
    actual_arm = CrystalClick::BinaryDataType.tuple(
      [uint8, json] of CrystalClick::BinaryDataType,
    )
    substituted_arm = CrystalClick::BinaryDataType.tuple(
      [string, json] of CrystalClick::BinaryDataType,
    )
    structure = CrystalClick::DynamicStructure.new([actual_arm] of CrystalClick::BinaryDataType)
    arm_index = structure.canonical_index_for(actual_arm)
    leaf_key = CrystalClick::BinaryDynamicJsonLeafKey.new("root", arm_index, [1_i32] of Int32)
    seed_key = CrystalClick::BinaryDynamicJsonLeafKey.new("root", arm_index, [] of Int32)
    leaf_plans = [{leaf_key, w216_child_plan(json)}] of W216LeafPlan

    budget = CrystalClick::BinaryCodecBudget.new(w216_limits(8), true)
    roster = CrystalClick::DynamicJsonObjectBindingRoster.for_root(
      structure,
      leaf_plans,
      budget,
      inferred_actual_root_depth: 1,
    )
    writer = CrystalClick::BinaryDynamicBulkJsonObjectWriter.for_root(
      roster,
      budget,
      [] of Array(CrystalClick::BinaryValue),
      actual_arm,
      arm_index,
      initial_descriptor_depth: 1,
    )
    writer.matches_root_operation?(actual_arm, seed_key, budget, 1).should be_true

    # Keeping the same canonical index and JSON leaf position must not let a
    # caller substitute the non-JSON tuple field outside the complete roster.
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDynamicBulkJsonObjectWriter.for_root(
        roster,
        budget,
        [] of Array(CrystalClick::BinaryValue),
        substituted_arm,
        arm_index,
        initial_descriptor_depth: 1,
      )
    end

    # A roster discovered at D=2 cannot authorize a writer shifted to D=3,
    # even when the actual arm and JSON leaf key remain unchanged.
    shifted_budget = CrystalClick::BinaryCodecBudget.new(w216_limits(8), true)
    shifted_roster = CrystalClick::DynamicJsonObjectBindingRoster.for_root(
      structure,
      leaf_plans,
      shifted_budget,
      inferred_actual_root_depth: 2,
    )
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDynamicBulkJsonObjectWriter.for_root(
        shifted_roster,
        shifted_budget,
        [] of Array(CrystalClick::BinaryValue),
        actual_arm,
        arm_index,
        initial_descriptor_depth: 3,
      )
    end
  end

  it "requires the normalized child stream keys to exactly match every bound JSON leaf" do
    json = w216_json_type
    structure = CrystalClick::DynamicStructure.new([json] of CrystalClick::BinaryDataType)
    key = CrystalClick::BinaryDynamicJsonLeafKey.new(
      "root", structure.canonical_index_for(json), [] of Int32,
    )
    bindings = [{key, w216_child_plan(json)}] of W216LeafPlan
    encoded = CrystalClick::DynamicValueCodec.encode(
      structure,
      [[w216_json_value(json, 33_u8)] of CrystalClick::BinaryValue],
      json_object_leaf_plans: bindings,
    )
    arms = Hash(String, CrystalClick::BinaryBulkStreams).new
    encoded.arm_names.each { |name| arms[name] = encoded.arm(name) }

    missing = CrystalClick::DynamicValueStreams.new(encoded.discriminators, arms)
    expect_raises(CrystalClick::CorruptPartError, "exactly match") do
      CrystalClick::DynamicValueCodec.decode(
        structure,
        missing,
        json_object_leaf_plans: bindings,
      )
    end

    extra_key = CrystalClick::BinaryDynamicJsonLeafKey.new(
      "root", structure.canonical_index_for(json), [0_i32] of Int32,
    )
    surplus_children = {
      key       => encoded.json_object_leaf_for(key),
      extra_key => encoded.json_object_leaf_for(key),
    } of CrystalClick::BinaryDynamicJsonLeafKey => CrystalClick::ObjectDocumentStreams
    surplus = CrystalClick::DynamicValueStreams.new(
      encoded.discriminators,
      arms,
      json_object_leaf_streams: surplus_children,
    )
    expect_raises(CrystalClick::CorruptPartError, "exactly match") do
      CrystalClick::DynamicValueCodec.decode(
        structure,
        surplus,
        json_object_leaf_plans: bindings,
      )
    end
  end

  it "requires bindings for every JSON actual arm even when an arm has no rows" do
    json = w216_json_type
    array_json = CrystalClick::BinaryDataType.array(json)
    structure = CrystalClick::DynamicStructure.new([json, array_json] of CrystalClick::BinaryDataType)
    direct_key = CrystalClick::BinaryDynamicJsonLeafKey.new(
      "root", structure.canonical_index_for(json), [] of Int32,
    )
    array_key = CrystalClick::BinaryDynamicJsonLeafKey.new(
      "root", structure.canonical_index_for(array_json), [0_i32] of Int32,
    )
    child = w216_child_plan(json)
    complete_bindings = [
      {direct_key, child},
      {array_key, child},
    ] of W216LeafPlan
    direct_only = [[w216_json_value(json, 34_u8)] of CrystalClick::BinaryValue]

    encoded = CrystalClick::DynamicValueCodec.encode(
      structure,
      direct_only,
      json_object_leaf_plans: complete_bindings,
    )
    decoded = CrystalClick::DynamicValueCodec.decode(
      structure,
      encoded,
      json_object_leaf_plans: complete_bindings,
    )
    decoded[0][0].json_row.value_for("v").not_nil!.byte_at(0).should eq(34_u8)

    # The Array(JSON) arm is absent from every discriminator row, but its
    # descriptor leaf still belongs to the exact bound roster on both sides.
    expect_raises(ArgumentError, "exactly cover") do
      CrystalClick::DynamicValueCodec.encode(
        structure,
        direct_only,
        json_object_leaf_plans: [{direct_key, child}] of W216LeafPlan,
      )
    end
    expect_raises(CrystalClick::CorruptPartError, "exactly cover") do
      CrystalClick::DynamicValueCodec.decode(
        structure,
        encoded,
        json_object_leaf_plans: [{direct_key, child}] of W216LeafPlan,
      )
    end
  end

  it "round-trips direct and Array(JSON) actuals beside a sparse ordinary sibling" do
    json = w216_json_type
    array_json = CrystalClick::BinaryDataType.array(json)
    string = CrystalClick::BinaryDataType.primitive("String")
    schema = CrystalClick::ObjectDocumentSchema.new({} of String => CrystalClick::BinaryDataType)
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(["payload", "label"] of String),
      {
        "payload" => CrystalClick::DynamicStructure.new([json, array_json] of CrystalClick::BinaryDataType),
        "label"   => CrystalClick::DynamicStructure.new([string] of CrystalClick::BinaryDataType),
      } of String => CrystalClick::DynamicStructure,
    )

    payload_roster = structures.dynamic_for("payload")
    child_plan = w216_child_plan(json)
    bindings = {
      "payload" => [
        {
          CrystalClick::BinaryDynamicJsonLeafKey.new(
            "root", payload_roster.canonical_index_for(json), [] of Int32,
          ),
          child_plan,
        },
        {
          CrystalClick::BinaryDynamicJsonLeafKey.new(
            "root", payload_roster.canonical_index_for(array_json), [0_i32] of Int32,
          ),
          child_plan,
        },
      ] of W216LeafPlan,
    } of String => Array(W216LeafPlan)
    plan = CrystalClick::ObjectDocumentPlan.new(
      structures,
      {} of String => CrystalClick::BinaryDataType,
      root_dynamic_json_object_leaf_plans: bindings,
    )
    array_value = ->(values : Array(UInt8)) {
      CrystalClick::BinaryValue.array(
        array_json,
        values.map { |value| w216_json_value(json, value) },
      )
    }
    rows = [
      [
        CrystalClick::ObjectDocument.new({
          "payload" => w216_json_value(json, 7_u8),
          "label"   => CrystalClick::BinaryValue.string("ordinary-first"),
        } of String => CrystalClick::BinaryValue),
        CrystalClick::ObjectDocument.new({
          "payload" => array_value.call([8_u8, 9_u8] of UInt8),
        } of String => CrystalClick::BinaryValue),
      ] of CrystalClick::ObjectDocument,
      [
        CrystalClick::ObjectDocument.new({
          "payload" => CrystalClick::BinaryValue.null,
          "label"   => CrystalClick::BinaryValue.string("null-parent"),
        } of String => CrystalClick::BinaryValue),
        CrystalClick::ObjectDocument.new({
          "payload" => array_value.call([] of UInt8),
        } of String => CrystalClick::BinaryValue),
      ] of CrystalClick::ObjectDocument,
      [
        CrystalClick::ObjectDocument.new({
          "payload" => w216_json_value(json, 10_u8),
        } of String => CrystalClick::BinaryValue),
        CrystalClick::ObjectDocument.new({
          "payload" => array_value.call([11_u8] of UInt8),
        } of String => CrystalClick::BinaryValue),
        CrystalClick::ObjectDocument.new({
          "label" => CrystalClick::BinaryValue.string("payload-absent"),
        } of String => CrystalClick::BinaryValue),
      ] of CrystalClick::ObjectDocument,
    ] of Array(CrystalClick::ObjectDocument)

    streams = CrystalClick::ObjectDocumentCodec.encode(plan, rows)
    decoded = CrystalClick::ObjectDocumentCodec.decode(
      schema.typed_paths,
      streams,
      root_dynamic_json_object_leaf_plans: bindings,
    )

    decoded.size.should eq(3)
    decoded.map(&.size).should eq([2, 2, 3])
    direct = decoded[0][0].value_for("payload")
    direct.type.should eq(json)
    direct.json_row.value_for("v").not_nil!.byte_at(0).should eq(7_u8)
    decoded[0][0].value_for("label").as_string.should eq("ordinary-first")
    decoded[0][1].has_path?("label").should be_false

    array = decoded[0][1].value_for("payload")
    array.type.should eq(array_json)
    array.element_count.should eq(2)
    array.element_at(0).json_row.value_for("v").not_nil!.byte_at(0).should eq(8_u8)
    array.element_at(1).json_row.value_for("v").not_nil!.byte_at(0).should eq(9_u8)
    # Root Object assembly intentionally represents Dynamic Nothing/NULL as
    # omission; it does not preserve a separate explicit-null path state.
    decoded[1][0].has_path?("payload").should be_false
    decoded[1][1].value_for("payload").type.should eq(array_json)
    decoded[1][1].value_for("payload").element_count.should eq(0)
    decoded[2][0].value_for("payload").json_row.value_for("v").not_nil!.byte_at(0).should eq(10_u8)
    decoded[2][1].value_for("payload").element_at(0).json_row.value_for("v").not_nil!.byte_at(0).should eq(11_u8)
    decoded[2][2].has_path?("payload").should be_false
    decoded[2][2].value_for("label").as_string.should eq("payload-absent")
    decoded[1][0].value_for("label").as_string.should eq("null-parent")
    decoded[1][1].has_path?("label").should be_false
    decoded[2][0].has_path?("label").should be_false
    decoded[2][1].has_path?("label").should be_false
  end

  it "binds root paths and sibling JSON leaves by exact path, arm, and descriptor position" do
    json = w216_json_type
    array_json = CrystalClick::BinaryDataType.array(json)
    text_json = w216_text_json_type
    pair_json = CrystalClick::BinaryDataType.tuple([json, text_json] of CrystalClick::BinaryDataType)
    string = CrystalClick::BinaryDataType.primitive("String")
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(["payload", "pair", "label"] of String),
      {
        "payload" => CrystalClick::DynamicStructure.new([json, array_json] of CrystalClick::BinaryDataType),
        "pair"    => CrystalClick::DynamicStructure.new([pair_json] of CrystalClick::BinaryDataType),
        "label"   => CrystalClick::DynamicStructure.new([string] of CrystalClick::BinaryDataType),
      } of String => CrystalClick::DynamicStructure,
    )
    payload_roster = structures.dynamic_for("payload")
    pair_roster = structures.dynamic_for("pair")
    child = w216_child_plan(json)
    payload_bindings = [
      {
        CrystalClick::BinaryDynamicJsonLeafKey.new(
          "root", payload_roster.canonical_index_for(json), [] of Int32,
        ),
        child,
      },
      {
        CrystalClick::BinaryDynamicJsonLeafKey.new(
          "root", payload_roster.canonical_index_for(array_json), [0_i32] of Int32,
        ),
        child,
      },
    ] of W216LeafPlan
    pair_bindings = [
      {
        CrystalClick::BinaryDynamicJsonLeafKey.new(
          "root", pair_roster.canonical_index_for(pair_json), [0_i32] of Int32,
        ),
        child,
      },
      {
        CrystalClick::BinaryDynamicJsonLeafKey.new(
          "root", pair_roster.canonical_index_for(pair_json), [1_i32] of Int32,
        ),
        w216_child_plan(text_json),
      },
    ] of W216LeafPlan
    bindings = {
      "payload" => payload_bindings,
      "pair"    => pair_bindings,
    } of String => Array(W216LeafPlan)
    schema = CrystalClick::ObjectDocumentSchema.new({} of String => CrystalClick::BinaryDataType)
    plan = CrystalClick::ObjectDocumentPlan.new(
      structures,
      schema.typed_paths,
      root_dynamic_json_object_leaf_plans: bindings,
    )
    tuple = ->(left : UInt8, right : UInt8) {
      CrystalClick::BinaryValue.tuple(
        pair_json,
        [w216_json_value(json, left), w216_text_json_value(text_json, "text-#{right}")] of CrystalClick::BinaryValue,
      )
    }
    document = CrystalClick::ObjectDocument.new({
      "payload" => CrystalClick::BinaryValue.array(
        array_json,
        [w216_json_value(json, 41_u8), w216_json_value(json, 42_u8)] of CrystalClick::BinaryValue,
      ),
      "pair"  => tuple.call(51_u8, 52_u8),
      "label" => CrystalClick::BinaryValue.string("independent-sibling"),
    } of String => CrystalClick::BinaryValue)
    streams = CrystalClick::ObjectDocumentCodec.encode(plan, [[document]] of Array(CrystalClick::ObjectDocument))
    decoded = CrystalClick::ObjectDocumentCodec.decode(
      schema.typed_paths,
      streams,
      root_dynamic_json_object_leaf_plans: bindings,
    )
    payload = decoded[0][0].value_for("payload")
    payload.element_count.should eq(2)
    payload.element_at(0).json_row.value_for("v").not_nil!.byte_at(0).should eq(41_u8)
    payload.element_at(1).json_row.value_for("v").not_nil!.byte_at(0).should eq(42_u8)
    pair = decoded[0][0].value_for("pair")
    pair.child_at(0).json_row.value_for("v").not_nil!.byte_at(0).should eq(51_u8)
    pair.child_at(1).type.should eq(text_json)
    pair.child_at(1).json_row.value_for("text").not_nil!.as_string.should eq("text-52")

    duplicate = {
      "pair"    => [pair_bindings[0], pair_bindings[0], pair_bindings[1]] of W216LeafPlan,
      "payload" => payload_bindings,
    } of String => Array(W216LeafPlan)
    expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentPlan.new(
        structures,
        schema.typed_paths,
        root_dynamic_json_object_leaf_plans: duplicate,
      )
    end
    expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentPlan.new(
        structures,
        schema.typed_paths,
        root_dynamic_json_object_leaf_plans: {
          "payload" => payload_bindings,
          "pair"    => [pair_bindings[0]] of W216LeafPlan,
        } of String => Array(W216LeafPlan),
      )
    end
    expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentPlan.new(
        structures,
        schema.typed_paths,
        root_dynamic_json_object_leaf_plans: {"unknown" => payload_bindings} of String => Array(W216LeafPlan),
      )
    end
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    wrong_json = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 0,
      max_dynamic_types: 0,
      typed_paths: {"v" => uint64} of String => CrystalClick::BinaryDataType,
    )
    wrong_schema = {
      "payload" => [
        {payload_bindings[0][0], w216_child_plan(wrong_json)},
        payload_bindings[1],
      ] of W216LeafPlan,
      "pair" => pair_bindings,
    } of String => Array(W216LeafPlan)
    expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentPlan.new(
        structures,
        schema.typed_paths,
        root_dynamic_json_object_leaf_plans: wrong_schema,
      )
    end
    swapped_pair_schemas = {
      "payload" => payload_bindings,
      "pair"    => [
        {pair_bindings[0][0], w216_child_plan(text_json)},
        {pair_bindings[1][0], child},
      ] of W216LeafPlan,
    } of String => Array(W216LeafPlan)
    expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentPlan.new(
        structures,
        schema.typed_paths,
        root_dynamic_json_object_leaf_plans: swapped_pair_schemas,
      )
    end
    wrong_leaf = {
      "payload" => [
        payload_bindings[0],
        {
          CrystalClick::BinaryDynamicJsonLeafKey.new(
            "root", payload_roster.canonical_index_for(array_json), [] of Int32,
          ),
          child,
        },
      ] of W216LeafPlan,
      "pair" => pair_bindings,
    } of String => Array(W216LeafPlan)
    expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentPlan.new(
        structures,
        schema.typed_paths,
        root_dynamic_json_object_leaf_plans: wrong_leaf,
      )
    end
  end

  it "keeps JSON descriptor grammar depth independent from physical Object lanes" do
    structures = w216_depth_fixture(false, false).plan.structures
    streams = CrystalClick::ObjectDynamicStructureCodec.encode_with_budget(
      structures,
      CrystalClick::BinaryCodecBudget.new(w216_limits(2), true),
      inferred_actual_root_depth: 1,
    )
    decoded = CrystalClick::ObjectDynamicStructureCodec.decode_with_budget(
      streams,
      CrystalClick::BinaryCodecBudget.new(w216_limits(2)),
      inferred_actual_root_depth: 1,
    )
    decoded.dynamic_for("payload").type_at(0).should eq(w216_json_type)

    # JSON(v UInt8) reaches the descriptor's typed child at depth 2. This
    # metadata-only probe excludes ObjectDocument's physical shared Array.
    expect_raises(CrystalClick::UnsupportedFormatError, "depth") do
      CrystalClick::ObjectDynamicStructureCodec.encode_with_budget(
        structures,
        CrystalClick::BinaryCodecBudget.new(w216_limits(1), true),
        inferred_actual_root_depth: 1,
      )
    end
    expect_raises(CrystalClick::CorruptPartError, "depth") do
      CrystalClick::ObjectDynamicStructureCodec.decode_with_budget(
        streams,
        CrystalClick::BinaryCodecBudget.new(w216_limits(1)),
        inferred_actual_root_depth: 1,
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError, "depth") do
      CrystalClick::ObjectDynamicStructureCodec.encode_with_budget(
        structures,
        CrystalClick::BinaryCodecBudget.new(w216_limits(2), true),
        inferred_actual_root_depth: 2,
      )
    end
    expect_raises(CrystalClick::CorruptPartError, "depth") do
      CrystalClick::ObjectDynamicStructureCodec.decode_with_budget(
        streams,
        CrystalClick::BinaryCodecBudget.new(w216_limits(2)),
        inferred_actual_root_depth: 2,
      )
    end
  end

  it "carries absolute depth through standalone, Array-leaf, and repeated inferred-JSON Object origins" do
    direct = w216_depth_fixture(false, false)
    array_leaf = w216_depth_fixture(true, false)
    nested = w216_depth_fixture(false, true)
    # Every end-to-end fixture includes the existing Object shared physical
    # Array floor at depth 3. The direct actual is deliberately shifted to
    # origin 2; its JSON(v UInt8) typed child is at 3. Array and nested actuals
    # start at origin 1 and reach the same typed-child depth through one edge.
    physical_floor = 3_i32

    [
      {direct, 2_i32, "standalone"},
      {array_leaf, 1_i32, "Array leaf"},
      {nested, 1_i32, "nested inferred JSON"},
    ].each do |entry|
      fixture = entry[0]
      origin = entry[1]
      streams = CrystalClick::ObjectDocumentCodec.encode(
        fixture.plan,
        fixture.documents,
        limits: w216_limits(physical_floor),
        inferred_actual_root_depth: origin,
      )
      decoded = CrystalClick::ObjectDocumentCodec.decode(
        fixture.schema,
        streams,
        limits: w216_limits(physical_floor),
        root_dynamic_json_object_leaf_plans: fixture.bindings,
        inferred_actual_root_depth: origin,
      )
      decoded[0][0].has_path?("payload").should be_true

      expect_raises(CrystalClick::UnsupportedFormatError, "depth") do
        CrystalClick::ObjectDocumentCodec.encode(
          fixture.plan,
          fixture.documents,
          limits: w216_limits(2),
          inferred_actual_root_depth: origin,
        )
      end
      expect_raises(CrystalClick::CorruptPartError, "depth") do
        CrystalClick::ObjectDocumentCodec.decode(
          fixture.schema,
          streams,
          limits: w216_limits(2),
          root_dynamic_json_object_leaf_plans: fixture.bindings,
          inferred_actual_root_depth: origin,
        )
      end

      shifted_origin = origin + 1
      expect_raises(CrystalClick::UnsupportedFormatError, "depth") do
        CrystalClick::ObjectDocumentCodec.encode(
          fixture.plan,
          fixture.documents,
          limits: w216_limits(physical_floor),
          inferred_actual_root_depth: shifted_origin,
        )
      end
      expect_raises(CrystalClick::CorruptPartError, "depth") do
        CrystalClick::ObjectDocumentCodec.decode(
          fixture.schema,
          streams,
          limits: w216_limits(physical_floor),
          root_dynamic_json_object_leaf_plans: fixture.bindings,
          inferred_actual_root_depth: shifted_origin,
        )
      end
    end
  end

  it "charges an unused nested JSON child binding at the inherited metadata depth" do
    leaf_json = w216_json_type
    outer_json = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 1,
      max_dynamic_types: 1,
    )
    nested_structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(["nested"] of String),
      {"nested" => CrystalClick::DynamicStructure.new([leaf_json] of CrystalClick::BinaryDataType)} of String => CrystalClick::DynamicStructure,
    )
    nested_roster = nested_structures.dynamic_for("nested")
    nested_bindings = {
      "nested" => [{
        CrystalClick::BinaryDynamicJsonLeafKey.new(
          "root", nested_roster.canonical_index_for(leaf_json), [] of Int32,
        ),
        w216_child_plan(leaf_json),
      }] of W216LeafPlan,
    } of String => Array(W216LeafPlan)
    nested_child = CrystalClick::ObjectDocumentPlan.new(
      nested_structures,
      outer_json.json_type.not_nil!.typed_paths,
      root_dynamic_json_object_leaf_plans: nested_bindings,
    )
    outer_roster = CrystalClick::DynamicStructure.new([outer_json] of CrystalClick::BinaryDataType)
    root_structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(["payload"] of String),
      {"payload" => outer_roster} of String => CrystalClick::DynamicStructure,
    )
    root_bindings = {
      "payload" => [{
        CrystalClick::BinaryDynamicJsonLeafKey.new(
          "root", outer_roster.canonical_index_for(outer_json), [] of Int32,
        ),
        nested_child,
      }] of W216LeafPlan,
    } of String => Array(W216LeafPlan)
    schema = CrystalClick::ObjectDocumentSchema.new({} of String => CrystalClick::BinaryDataType)
    plan = CrystalClick::ObjectDocumentPlan.new(
      root_structures,
      schema.typed_paths,
      root_dynamic_json_object_leaf_plans: root_bindings,
    )
    # The row carries no nested value at all. Only the child plan's unused
    # nested JSON roster/binding contributes the descendant metadata depth.
    empty_outer = CrystalClick::BinaryValue.json(
      outer_json,
      CrystalClick::BinaryJsonRow.new(outer_json, [] of Tuple(String, CrystalClick::BinaryValue)),
    )
    documents = [[CrystalClick::ObjectDocument.new({
      "payload" => empty_outer,
    } of String => CrystalClick::BinaryValue)] of CrystalClick::ObjectDocument]

    # Outer JSON is a direct root leaf at depth 1. Its child Object starts at
    # depth 2; the nested inferred Dynamic actual is rooted there, so its JSON
    # typed field reaches depth 3 even though the row carries no nested value.
    minimum = 3_i32
    streams = CrystalClick::ObjectDocumentCodec.encode(
      plan,
      documents,
      limits: w216_limits(minimum),
      inferred_actual_root_depth: 1,
    )
    decoded = CrystalClick::ObjectDocumentCodec.decode(
      schema.typed_paths,
      streams,
      limits: w216_limits(minimum),
      root_dynamic_json_object_leaf_plans: root_bindings,
      inferred_actual_root_depth: 1,
    )
    decoded[0][0].value_for("payload").json_row.path_count.should eq(0)
    expect_raises(CrystalClick::UnsupportedFormatError, "depth") do
      CrystalClick::ObjectDocumentCodec.encode(
        plan,
        documents,
        limits: w216_limits(minimum - 1),
        inferred_actual_root_depth: 1,
      )
    end
    expect_raises(CrystalClick::CorruptPartError, "depth") do
      CrystalClick::ObjectDocumentCodec.decode(
        schema.typed_paths,
        streams,
        limits: w216_limits(minimum - 1),
        root_dynamic_json_object_leaf_plans: root_bindings,
        inferred_actual_root_depth: 1,
      )
    end
  end

  it "charges sibling inferred JSON child Objects to one operation budget" do
    json = w216_json_type
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(["left", "right"] of String),
      {
        "left"  => CrystalClick::DynamicStructure.new([json] of CrystalClick::BinaryDataType),
        "right" => CrystalClick::DynamicStructure.new([json] of CrystalClick::BinaryDataType),
      } of String => CrystalClick::DynamicStructure,
    )
    child = w216_child_plan(json)
    bindings = {
      "left" => [{
        CrystalClick::BinaryDynamicJsonLeafKey.new(
          "root", structures.dynamic_for("left").canonical_index_for(json), [] of Int32,
        ),
        child,
      }] of W216LeafPlan,
      "right" => [{
        CrystalClick::BinaryDynamicJsonLeafKey.new(
          "root", structures.dynamic_for("right").canonical_index_for(json), [] of Int32,
        ),
        child,
      }] of W216LeafPlan,
    } of String => Array(W216LeafPlan)
    schema = CrystalClick::ObjectDocumentSchema.new({} of String => CrystalClick::BinaryDataType)
    plan = CrystalClick::ObjectDocumentPlan.new(
      structures,
      schema.typed_paths,
      root_dynamic_json_object_leaf_plans: bindings,
    )
    one_child = CrystalClick::ObjectDocument.new({
      "left"  => w216_json_value(json, 71_u8),
      "right" => CrystalClick::BinaryValue.null,
    } of String => CrystalClick::BinaryValue)
    two_children = CrystalClick::ObjectDocument.new({
      "left"  => w216_json_value(json, 71_u8),
      "right" => w216_json_value(json, 72_u8),
    } of String => CrystalClick::BinaryValue)
    high_limits = w216_limits(32)
    one_budget = CrystalClick::BinaryCodecBudget.new(high_limits, true)
    CrystalClick::ObjectDocumentCodec.encode_with_budget(
      plan,
      [[one_child] of CrystalClick::ObjectDocument],
      one_budget,
      inferred_actual_root_depth: 1,
    )
    two_budget = CrystalClick::BinaryCodecBudget.new(high_limits, true)
    two_streams = CrystalClick::ObjectDocumentCodec.encode_with_budget(
      plan,
      [[two_children] of CrystalClick::ObjectDocument],
      two_budget,
      inferred_actual_root_depth: 1,
    )
    two_budget.node_count.should be > one_budget.node_count

    exact_one_limits = w216_limits(32, one_budget.node_count)
    exact_one_write = CrystalClick::BinaryCodecBudget.new(exact_one_limits, true)
    CrystalClick::ObjectDocumentCodec.encode_with_budget(
      plan,
      [[one_child] of CrystalClick::ObjectDocument],
      exact_one_write,
      inferred_actual_root_depth: 1,
    )
    one_streams = CrystalClick::ObjectDocumentCodec.encode(plan, [[one_child] of CrystalClick::ObjectDocument])
    one_read_budget = CrystalClick::BinaryCodecBudget.new(high_limits)
    CrystalClick::ObjectDocumentCodec.decode_with_budget(
      schema.typed_paths,
      one_streams,
      one_read_budget,
      root_dynamic_json_object_leaf_plans: bindings,
      inferred_actual_root_depth: 1,
    )
    two_read_budget = CrystalClick::BinaryCodecBudget.new(high_limits)
    CrystalClick::ObjectDocumentCodec.decode_with_budget(
      schema.typed_paths,
      two_streams,
      two_read_budget,
      root_dynamic_json_object_leaf_plans: bindings,
      inferred_actual_root_depth: 1,
    )
    two_read_budget.node_count.should be > one_read_budget.node_count
    exact_one_read_limits = w216_limits(32, one_read_budget.node_count)

    bounded_write = CrystalClick::BinaryCodecBudget.new(exact_one_limits, true)
    expect_raises(CrystalClick::UnsupportedFormatError, "node") do
      CrystalClick::ObjectDocumentCodec.encode_with_budget(
        plan,
        [[two_children] of CrystalClick::ObjectDocument],
        bounded_write,
        inferred_actual_root_depth: 1,
      )
    end
    bounded_read = CrystalClick::BinaryCodecBudget.new(exact_one_read_limits)
    expect_raises(CrystalClick::CorruptPartError, "node") do
      CrystalClick::ObjectDocumentCodec.decode_with_budget(
        schema.typed_paths,
        two_streams,
        bounded_read,
        root_dynamic_json_object_leaf_plans: bindings,
        inferred_actual_root_depth: 1,
      )
    end
  end
end
