require "./spec_helper"

private def w106_model_string_owner_charge(value : String) : UInt64
  instance_sizeof(String).to_u64 + value.bytesize.to_u64 + 1_u64
end

private def w106_model_node_charge(
  name : String?,
  child_count : Int32,
  descendants : UInt64,
) : UInt64
  instance_sizeof(CrystalClick::WideTupleSchemaNode).to_u64 +
    instance_sizeof(Array(CrystalClick::WideTupleSchemaNode)).to_u64 +
    child_count.to_u64 * sizeof(Pointer(CrystalClick::WideTupleSchemaNode)).to_u64 +
    (name ? w106_model_string_owner_charge(name) : 0_u64) + descendants
end

private def w106_model_path_charge(paths : Array(Array(String))) : UInt64
  paths.sum(0_u64) do |segments|
    instance_sizeof(Array(String)).to_u64 +
      segments.size.to_u64 * sizeof(Pointer(String)).to_u64 +
      segments.sum(0_u64) { |segment| w106_model_string_owner_charge(segment) }
  end
end

private def w106_model_nested_source : String
  "Tuple(left Tuple(inside Tuple(value UInt64), note Nullable(String)), right Tuple(value UInt64))"
end

private def w106_model_nested_data : CrystalClick::WideTupleColumnData
  plan = CrystalClick::WideTupleTypePlan.for_type(w106_model_nested_source).not_nil!
  nullable_note = plan.fields[1].leaf_type
  nulls = CrystalClick::ScalarNullMap.new(Bytes[1_u8], 1_u64)
  columns = [
    CrystalClick::WideTupleLeafColumn.new("left.inside.value", [11_u64] of UInt64),
    CrystalClick::WideTupleLeafColumn.new("left.note", nullable_note, ["hidden"], nulls),
    CrystalClick::WideTupleLeafColumn.new("right.value", [99_u64] of UInt64),
  ] of CrystalClick::WideTupleLeafColumn
  CrystalClick::WideTupleColumnData.new(plan, columns)
end

private def w106_model_mutate_string(value : String, byte : UInt8) : Nil
  value.to_unsafe[0] = byte
end

describe "W106 recursive named Tuple model" do
  it "retains an immutable tree and exposes relative scopes over the flat terminal leaves" do
    data = w106_model_nested_data
    row = data.row(0)

    data.type_name.should eq(w106_model_nested_source)
    data.field_count.should eq(3)
    data.fields.map(&.name).should eq(["left.inside.value", "left.note", "right.value"])
    data.root_fields.map(&.name).should eq(["left", "right"])
    data.root_fields[0].leaf_field?.should be_nil
    data.root_fields[0].children.map(&.name).should eq(["inside", "note"])
    data.root_fields[0].type_name.should eq("Tuple(inside Tuple(value UInt64), note Nullable(String))")

    row.value_as("left.inside.value", UInt64).should eq(11_u64)
    row.value_as("right.value", UInt64).should eq(99_u64)
    row["left.note"].should be_nil
    row.string_bytesize.should eq(6_u64)

    left = row.tuple("left")
    left.type_name.should eq("Tuple(inside Tuple(value UInt64), note Nullable(String))")
    left.field_count.should eq(2)
    left.fields.map(&.name).should eq(["inside.value", "note"])
    left.root_fields.map(&.name).should eq(["inside", "note"])
    left["note"].should be_nil
    left.string_bytesize.should eq(6_u64)

    inner = left.tuple("inside")
    chained = row.tuple("left.inside")
    inner.type_name.should eq("Tuple(value UInt64)")
    inner.fields.map(&.name).should eq(["value"])
    inner.field_count.should eq(1)
    inner.value_as("value", UInt64).should eq(11_u64)
    chained.value_as("value", UInt64).should eq(11_u64)
    chained.type_name.should eq(inner.type_name)
    chained.fields.map(&.name).should eq(inner.fields.map(&.name))

    expect_raises(KeyError) { row.tuple("missing") }
    expect_raises(ArgumentError) { row.tuple("left.note") }
    expect_raises(KeyError) { left.value_as("absent", UInt64) }
  end

  it "detaches constructor paths and every exported tree or flat descriptor snapshot" do
    plan = CrystalClick::WideTupleTypePlan.for_type(w106_model_nested_source).not_nil!
    original_fields = plan.fields
    caller_segments = [
      String.new("left".to_slice),
      String.new("inside".to_slice),
      String.new("value".to_slice),
    ]
    copied_field = CrystalClick::WideTupleField.new(
      "left.inside.value", original_fields.first.leaf_type, caller_segments
    )
    w106_model_mutate_string(caller_segments[0], 'X'.ord.to_u8)
    caller_segments.clear
    copied_field.path_segments.should eq(["left", "inside", "value"])
    w106_model_mutate_string(copied_field.path_segments[0], 'Y'.ord.to_u8)
    copied_field.name.should eq("left.inside.value")

    exported_fields = plan.fields
    exported_segments = exported_fields.first.path_segments
    w106_model_mutate_string(exported_segments[0], 'Z'.ord.to_u8)
    exported_fields.clear
    plan.fields.first.path_segments.should eq(["left", "inside", "value"])

    roots = plan.root_fields
    roots.clear
    plan.root_fields.map(&.name).should eq(["left", "right"])
    exposed_node = plan.root_fields.first
    exposed_name = exposed_node.name
    w106_model_mutate_string(exposed_name, 'Q'.ord.to_u8)
    exposed_children = exposed_node.children
    exposed_children.clear
    exposed_node.name.should eq("left")
    exposed_node.children.map(&.name).should eq(["inside", "note"])
    plan.type_name.should eq(w106_model_nested_source)

    CrystalClick::WideTupleTypePlan.for_type("Tuple(a.b UInt64)").should be_nil
    CrystalClick::WideTupleTypePlan.for_type("Tuple('a' UInt64)").should be_nil
  end

  it "retains tree and path descriptors in an empty copied Tuple result" do
    plan = CrystalClick::WideTupleTypePlan.for_type(w106_model_nested_source).not_nil!
    nulls = CrystalClick::ScalarNullMap.new(Bytes.empty, 0_u64)
    columns = [
      CrystalClick::WideTupleLeafColumn.new("left.inside.value", [] of UInt64),
      CrystalClick::WideTupleLeafColumn.new("left.note", plan.fields[1].leaf_type, [] of String, nulls),
      CrystalClick::WideTupleLeafColumn.new("right.value", [] of UInt64),
    ] of CrystalClick::WideTupleLeafColumn
    data = CrystalClick::WideTupleColumnData.new(plan, columns)
    copy = CrystalClick::WideTupleColumnData.new(plan, data.columns)

    copy.row_count.should eq(0)
    copy.type_name.should eq(w106_model_nested_source)
    copy.fields.map(&.name).should eq(["left.inside.value", "left.note", "right.value"])
    copy.root_fields.map(&.name).should eq(["left", "right"])
    copy.columns[1].leaf_type.type_name.should eq("Nullable(String)")
    copy.columns[1].null_map.not_nil!.bytes.should be_empty
  end

  it "matches the independently itemized tree, path, descriptor, mask, and row budget" do
    plan = CrystalClick::WideTupleTypePlan.for_type(w106_model_nested_source).not_nil!
    paths = [
      ["left", "inside", "value"],
      ["left", "note"],
      ["right", "value"],
    ] of Array(String)

    leaf_string = ->(base : String) {
      instance_sizeof(CrystalClick::WideTupleLeafType).to_u64 +
      w106_model_string_owner_charge(base)
    }
    inside_tree = w106_model_node_charge("inside", 1, w106_model_node_charge("value", 0, 0_u64))
    left_tree = w106_model_node_charge(
      "left", 2,
      inside_tree + w106_model_node_charge("note", 0, 0_u64)
    )
    right_tree = w106_model_node_charge("right", 1, w106_model_node_charge("value", 0, 0_u64))
    # The schema root is synthetic and owns two immediate child references.
    independent_tree = w106_model_node_charge(nil, 2, left_tree + right_tree)
    independent_paths = w106_model_path_charge(paths)
    independent_leaves = leaf_string.call("UInt64") * 2_u64 + leaf_string.call("String")
    independent_mask_owner = instance_sizeof(CrystalClick::ScalarNullMap).to_u64
    fixed = CrystalClick::WideTupleTypePlan::RESULT_CONTAINER_ACCOUNTING_BYTES +
            CrystalClick::WideTupleTypePlan::FIELD_CONTAINER_ACCOUNTING_BYTES * 3_u64 +
            independent_tree + independent_paths + independent_leaves + independent_mask_owner
    row_bytes = CrystalClick::WideTupleTypePlan::RESULT_ROW_ACCOUNTING_BYTES + 8_u64 +
                CrystalClick::WideTupleTypePlan::STRING_SLOT_ACCOUNTING_BYTES + 1_u64 + 8_u64

    plan.materialization_charge(0_u64, 0_u64).should eq(fixed)
    plan.materialization_charge(1_u64, 6_u64).should eq(fixed + row_bytes + 6_u64)
  end

  it "keeps the legacy dotted WideTupleField copy path distinct from parser admission" do
    leaf = CrystalClick::WideTupleLeafType.new("UInt64")
    legacy = CrystalClick::WideTupleField.new("a.b", leaf)
    copy = legacy.owned_copy
    copy.name.should eq("a.b")
    copy.path_segments.should eq(["a.b"])
    copied_segments = copy.path_segments
    w106_model_mutate_string(copied_segments[0], 'X'.ord.to_u8)
    copy.path_segments.should eq(["a.b"])
    legacy.path_segments.should eq(["a.b"])
    CrystalClick::WideTupleTypePlan.for_type("Tuple(a.b UInt64)").should be_nil
  end
end

describe "W106 nested parser budgets" do
  it "keeps source bytes, Tuple nesting, leaf parentheses, and Nullable nodes on global boundaries" do
    parser = CrystalClick::WideTupleSchemaParser
    base = "Tuple(value UInt8)"
    exact_source = base + (" " * (CrystalClick::WideTupleSchemaParser::MAX_SOURCE_BYTES - base.bytesize))
    (exact_source.bytesize <= CrystalClick::WideTupleSchemaParser::MAX_SOURCE_BYTES).should be_true
    parser.parse_tree(exact_source).should_not be_nil
    parser.parse_tree(exact_source + " ").should be_nil

    nested = ->(tuple_depth : Int32, leaf : String) {
      source = "Tuple(value #{leaf})"
      (tuple_depth - 1).times { source = "Tuple(child #{source})" }
      source
    }
    parser.parse_tree(nested.call(64, "Bool")).should_not be_nil
    parser.parse_tree(nested.call(63, "Nullable(UInt8)")).should_not be_nil
    parser.parse_tree(nested.call(63, "FixedString(1)")).should_not be_nil
    parser.parse_tree(nested.call(64, "Nullable(UInt8)")).should be_nil
    parser.parse_tree(nested.call(64, "FixedString(1)")).should be_nil
  end

  it "rejects the 513th aggregate syntax node below source and depth limits" do
    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_".chars.map(&.to_s)
    outer_names = alphabet[0, 32]
    inner_names = alphabet[0, 15]
    source_for = ->(last_group_leaf_count : Int32) {
      groups = [] of String
      outer_names.each_with_index do |group_name, group_index|
        leaf_count = group_index == outer_names.size - 1 ? last_group_leaf_count : inner_names.size
        leaves = inner_names[0, leaf_count].map_with_index do |leaf_name, leaf_index|
          leaf_type = if group_index == 0 && leaf_index == 0
                        "Nullable(DateTime64(3, 'UTC'))"
                      else
                        "Bool"
                      end
          "#{leaf_name} #{leaf_type}"
        end
        groups << "#{group_name} Tuple(#{leaves.join(",")})"
      end
      "Tuple(#{groups.join(",")})"
    }
    exactly_512_nodes = source_for.call(11)
    over_512_nodes = source_for.call(12)
    exactly_512_nodes.bytesize.should be < CrystalClick::WideTupleSchemaParser::MAX_SOURCE_BYTES
    over_512_nodes.bytesize.should be < CrystalClick::WideTupleSchemaParser::MAX_SOURCE_BYTES
    CrystalClick::WideTupleSchemaParser.parse_tree(exactly_512_nodes).not_nil!.flattened_fields.size.should eq(476)
    CrystalClick::WideTupleSchemaParser.parse_tree(over_512_nodes).should be_nil
  end
end
