require "./spec_helper"

describe CrystalClick::WideTupleSchemaParser do
  it "rejects unrelated scalar and JSON roots at every aggregate entry point" do
    ["UInt64", "String", "JSON(record String)"].each do |source|
      CrystalClick::WideTupleSchemaParser.parse_tree(source).should be_nil
      CrystalClick::WideTupleSchemaParser.parse_array_tuple_tree(source).should be_nil
      CrystalClick::WideTupleSchemaParser.parse_nested_tree(source).should be_nil
      CrystalClick::WideTupleSchemaParser.parse_map_tuple_tree(source).should be_nil
    end
  end

  it "keeps whitespace after each root keyword within the admitted grammar" do
    CrystalClick::WideTupleSchemaParser.parse_tree("Tuple \t(value UInt64 )").should_not be_nil
    CrystalClick::WideTupleSchemaParser.parse_array_tuple_tree("Array \t( Tuple \t(value UInt64 ) )").should_not be_nil
    CrystalClick::WideTupleSchemaParser.parse_nested_tree("Nested \t(value UInt64 )").should_not be_nil
    CrystalClick::WideTupleSchemaParser.parse_map_tuple_tree("Map \t(UInt64, Tuple \t(value UInt64 ) )").should_not be_nil
  end

  it "retains rejection for keyword lookalikes, malformed roots, and trailing bytes" do
    CrystalClick::WideTupleSchemaParser.parse_tree("TupleLike(value UInt64)").should be_nil
    CrystalClick::WideTupleSchemaParser.parse_tree("Tuple(value UInt64) trailing").should be_nil

    CrystalClick::WideTupleSchemaParser.parse_array_tuple_tree("ArrayLike(Tuple(value UInt64))").should be_nil
    CrystalClick::WideTupleSchemaParser.parse_array_tuple_tree("Array(Tuple(value UInt64)) trailing").should be_nil

    CrystalClick::WideTupleSchemaParser.parse_nested_tree("NestedLike(value UInt64)").should be_nil
    CrystalClick::WideTupleSchemaParser.parse_nested_tree("Nested(value UInt64) trailing").should be_nil

    CrystalClick::WideTupleSchemaParser.parse_map_tuple_tree("MapLike(UInt64, Tuple(value UInt64))").should be_nil
    CrystalClick::WideTupleSchemaParser.parse_map_tuple_tree("Map(UInt64, Tuple(value UInt64)) trailing").should be_nil
  end
end
