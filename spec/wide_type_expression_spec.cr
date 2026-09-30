require "./spec_helper"

describe CrystalClick::WideTypePlan do
  it "preserves the public AST node type and tuple field structure" do
    node = CrystalClick::WideTypePlan.parse("Array(Tuple(a UInt64, b String))").not_nil!

    typeof(node).should eq(CrystalClick::WideTypePlan::Node)
    node.name.should eq("Array")
    node.child(0).field_names.should eq(["a", "b"])
    node.child(0).child(1).name.should eq("String")

    parser_node = CrystalClick::WideTypePlan::Parser.new("UInt64").parse.not_nil!
    typeof(parser_node).should eq(CrystalClick::WideTypePlan::Node)
    CrystalClick::WideTypePlan::Node.name.should eq("CrystalClick::WideTypePlan::Node")
    CrystalClick::WideTypePlan::Parser.name.should eq("CrystalClick::WideTypePlan::Parser")

    expression_node = CrystalClick::WideTypeExpression.parse("Array(Tuple(a UInt64, b String))").not_nil!
    typeof(expression_node).should eq(CrystalClick::WideTypeExpression::Node)
    typeof(expression_node).should eq(CrystalClick::WideTypePlan::Node)
    typeof(CrystalClick::WideTypePlan::Parser.new("UInt64")).should eq(CrystalClick::WideTypeExpression::Parser)
  end
end
