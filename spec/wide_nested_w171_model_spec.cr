require "./spec_helper"

private def w171m_nested_tuple_body(tuple_count : Int32) : String
  body = "value UInt8"
  (tuple_count - 1).times { body = "child Tuple(#{body})" }
  body
end

private def w171m_nested_node_boundary_source(last_group_leaf_count : Int32) : String
  alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_".chars.map(&.to_s)
  outer_names = alphabet[0, 32]
  inner_names = alphabet[0, 15]
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
  "Nested(#{groups.join(",")})"
end

describe "W171 Nested nominal model and parser boundaries" do
  it "keeps Nested, Array(Tuple), and scalar Tuple admission nominally distinct" do
    nested_source = "Nested(a UInt64, b Nullable(DateTime64(3, 'UTC')))"
    array_source = "Array(Tuple(a UInt64, b Nullable(DateTime64(3, 'UTC'))))"
    tuple_source = "Tuple(a UInt64, b Nullable(DateTime64(3, 'UTC')))"

    CrystalClick::WidePart.supports_nested_type?(nested_source).should be_true
    CrystalClick::WidePart.supports_named_scalar_tuple_type?(nested_source).should be_false
    CrystalClick::WidePart.supports_named_array_tuple_type?(nested_source).should be_false
    CrystalClick::WidePart.supports_typed_type?(nested_source).should be_true

    nested_plan = CrystalClick::WideNestedTypePlan.for_type(nested_source).not_nil!
    nested_plan.type_name.should eq(nested_source)
    nested_storage = CrystalClick::WideArrayTupleTypePlan.for_storage_type(nested_source).not_nil!
    nested_storage.nested?.should be_true
    nested_storage.type_name.should eq(nested_source)
    CrystalClick::WideArrayTupleTypePlan.for_type(nested_source).should be_nil
    CrystalClick::WideTupleTypePlan.for_type(nested_source).should be_nil

    CrystalClick::WidePart.supports_named_array_tuple_type?(array_source).should be_true
    CrystalClick::WidePart.supports_nested_type?(array_source).should be_false
    array_plan = CrystalClick::WideArrayTupleTypePlan.for_type(array_source).not_nil!
    array_plan.nested?.should be_false
    array_plan.type_name.should eq(array_source)

    CrystalClick::WidePart.supports_named_scalar_tuple_type?(tuple_source).should be_true
    CrystalClick::WidePart.supports_nested_type?(tuple_source).should be_false
    CrystalClick::WideTupleTypePlan.for_type(tuple_source).not_nil!.type_name.should eq(tuple_source)
    CrystalClick::WideArrayTupleTypePlan.for_storage_type(tuple_source).should be_nil
  end

  it "retains legal parser whitespace while returning canonical plan identities" do
    nested = CrystalClick::WideNestedTypePlan.for_type("Nested (a UInt64, b String )").not_nil!
    nested.type_name.should eq("Nested(a UInt64, b String)")

    array_source = "Array \t( Tuple (a UInt64, b String ) )"
    array = CrystalClick::WideArrayTupleTypePlan.for_type(array_source).not_nil!
    array.type_name.should eq("Array(Tuple(a UInt64, b String))")
    storage = CrystalClick::WideArrayTupleTypePlan.for_storage_type(array_source).not_nil!
    storage.nested?.should be_false
    storage.type_name.should eq(array.type_name)

    nested_storage = CrystalClick::WideArrayTupleTypePlan.for_storage_type("Nested (a UInt64, b String )").not_nil!
    nested_storage.nested?.should be_true
    nested_storage.type_name.should eq(nested.type_name)
  end

  it "counts the complete nominal Nested source against the 4096-byte cap" do
    source_limit = CrystalClick::WideTupleSchemaParser::MAX_SOURCE_BYTES
    declaration = "Nested(value UInt8)"
    exact_nested = declaration + (" " * (source_limit - declaration.bytesize))
    exact_nested.bytesize.should eq(source_limit)

    CrystalClick::WideNestedTypePlan.for_type(exact_nested).should_not be_nil
    CrystalClick::WideArrayTupleTypePlan.for_storage_type(exact_nested).should_not be_nil
    CrystalClick::WideNestedTypePlan.for_type(exact_nested + " ").should be_nil
    CrystalClick::WideArrayTupleTypePlan.for_storage_type(exact_nested + " ").should be_nil
  end

  it "charges the implicit Array and root Tuple toward structural depth 64" do
    source_limit = CrystalClick::WideTupleSchemaParser::MAX_SOURCE_BYTES
    exact_depth = "Nested(#{w171m_nested_tuple_body(63)})"
    depth_65 = "Nested(#{w171m_nested_tuple_body(64)})"
    exact_depth.bytesize.should be < source_limit
    depth_65.bytesize.should be < source_limit

    CrystalClick::WideNestedTypePlan.for_type(exact_depth).should_not be_nil
    CrystalClick::WideNestedTypePlan.for_type(depth_65).should be_nil
  end

  it "charges the implicit Array and Tuple plus Nullable and DateTime64 parameters to one 512-node budget" do
    source_limit = CrystalClick::WideTupleSchemaParser::MAX_SOURCE_BYTES
    exact_512_nodes = w171m_nested_node_boundary_source(10)
    over_512_nodes = w171m_nested_node_boundary_source(11)
    exact_512_nodes.bytesize.should be < source_limit
    over_512_nodes.bytesize.should be < source_limit

    # 1 implicit Array + 1 root Tuple + 32 child Tuples + 475 leaf nodes,
    # with three additional nodes for Nullable, DateTime64 precision and zone.
    exact_plan = CrystalClick::WideNestedTypePlan.for_type(exact_512_nodes).not_nil!
    exact_plan.tuple_plan.field_count.should eq(475)
    CrystalClick::WideNestedTypePlan.for_type(over_512_nodes).should be_nil
  end

  it "fails closed for malformed Nested declarations and unsupported child containers" do
    [
      "Nested(a UInt64, b String",
      "Nested(a UInt64, a String)",
      "Nested(a Array(UInt64), b String)",
      "Nested()",
    ].each do |source|
      CrystalClick::WideNestedTypePlan.for_type(source).should be_nil
      CrystalClick::WideArrayTupleTypePlan.for_storage_type(source).should be_nil
      CrystalClick::WidePart.supports_nested_type?(source).should be_false
      CrystalClick::WidePart.supports_typed_type?(source).should be_false
    end
  end
end
