require "./spec_helper"

private def w107m_nested_tuple_source(tuple_count : Int32, leaf_type : String = "Bool") : String
  source = "Tuple(value #{leaf_type})"
  (tuple_count - 1).times { source = "Tuple(child #{source})" }
  source
end

private def w107m_array_node_boundary_source(last_group_leaf_count : Int32) : String
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
  "Array(Tuple(#{groups.join(",")}))"
end

describe "W107 Array(Tuple) parser boundaries" do
  it "counts the complete outer Array declaration against the source-byte cap" do
    source_limit = CrystalClick::WideTupleSchemaParser::MAX_SOURCE_BYTES
    tuple = "Tuple(value UInt8)"
    exact_tuple = tuple + (" " * (source_limit - tuple.bytesize))
    CrystalClick::WideTupleTypePlan.for_type(exact_tuple).should_not be_nil

    array = "Array(#{tuple})"
    exact_array = array + (" " * (source_limit - array.bytesize))
    exact_array.bytesize.should eq(source_limit)
    CrystalClick::WideArrayTupleTypePlan.for_type(exact_array).should_not be_nil
    CrystalClick::WideArrayTupleTypePlan.for_type(exact_array + " ").should be_nil

    wrapped_over_limit = "Array(#{exact_tuple})"
    wrapped_over_limit.bytesize.should be > source_limit
    CrystalClick::WideArrayTupleTypePlan.for_type(wrapped_over_limit).should be_nil
  end

  it "charges the outer Array toward the aggregate depth boundary" do
    source_limit = CrystalClick::WideTupleSchemaParser::MAX_SOURCE_BYTES
    exact_depth = "Array(#{w107m_nested_tuple_source(63)})"
    over_depth = "Array(#{w107m_nested_tuple_source(64)})"
    exact_depth.bytesize.should be < source_limit
    over_depth.bytesize.should be < source_limit

    CrystalClick::WideArrayTupleTypePlan.for_type(exact_depth).should_not be_nil
    CrystalClick::WideArrayTupleTypePlan.for_type(over_depth).should be_nil
  end

  it "uses one syntax-node budget across the outer Array, nested Tuples, and leaf parameters" do
    source_limit = CrystalClick::WideTupleSchemaParser::MAX_SOURCE_BYTES
    exact_512_nodes = w107m_array_node_boundary_source(10)
    over_512_nodes = w107m_array_node_boundary_source(11)
    exact_512_nodes.bytesize.should be < source_limit
    over_512_nodes.bytesize.should be < source_limit

    # 1 Array + 1 root Tuple + 32 child Tuples + 475 leaf nodes. The first
    # leaf contributes three additional nodes: Nullable, DateTime64 precision,
    # and timezone parameters. The next field crosses 512 to 513.
    exact_plan = CrystalClick::WideArrayTupleTypePlan.for_type(exact_512_nodes).not_nil!
    exact_plan.tuple_plan.field_count.should eq(475)
    CrystalClick::WideArrayTupleTypePlan.for_type(over_512_nodes).should be_nil
  end
end
