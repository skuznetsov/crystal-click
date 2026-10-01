require "./spec_helper"

private def w96_leaf_descriptor_charge(base_type_name : String) : UInt64
  instance_sizeof(CrystalClick::WideTupleLeafType).to_u64 +
    instance_sizeof(String).to_u64 + base_type_name.bytesize.to_u64 + 1_u64
end

private def w96_flat_tree_and_path_charge(field_names : Array(String)) : UInt64
  node_bytes = instance_sizeof(CrystalClick::WideTupleSchemaNode).to_u64
  node_children_bytes = instance_sizeof(Array(CrystalClick::WideTupleSchemaNode)).to_u64
  name_header_bytes = instance_sizeof(String).to_u64
  node_reference_bytes = sizeof(Pointer(CrystalClick::WideTupleSchemaNode)).to_u64
  path_header_bytes = instance_sizeof(Array(String)).to_u64
  path_reference_bytes = sizeof(Pointer(String)).to_u64

  total = node_bytes + node_children_bytes + field_names.size.to_u64 * node_reference_bytes
  field_names.each do |name|
    owned_name_bytes = name_header_bytes + name.bytesize.to_u64 + 1_u64
    total += node_bytes + node_children_bytes + owned_name_bytes
    total += path_header_bytes + path_reference_bytes + owned_name_bytes
  end
  total
end

private def w96_assert_numeric_plan(type_name : String, width : Int32) : Nil
  full_type = "Tuple(value #{type_name})"
  plan = CrystalClick::WideTupleTypePlan.for_type(full_type)
  plan.should_not be_nil

  if plan
    plan.type_name.should eq(full_type)
    plan.fields.map { |field| {field.name, field.type_name} }.should eq([{"value", type_name}])
    plan.physical_streams("payload").should eq(["payload%2Evalue"])
    plan.stream_width("payload", "payload%2Evalue").should eq(width)
    plan.raw_string_stream?("payload", "payload%2Evalue").should be_false

    fixed_bytes = 64_u64 + sizeof(CrystalClick::WideTupleField).to_u64 +
                  w96_flat_tree_and_path_charge(["value"] of String) +
                  w96_leaf_descriptor_charge(type_name)
    bytes_per_row = 8_u64 + width.to_u64
    expected_charge = fixed_bytes + 3_u64 * bytes_per_row
    plan.materialization_charge(3_u64, 0_u64).should eq(expected_charge)
  end

  nil
end

describe "W96 named numeric Tuple plan red" do
  it "keeps the admitted UInt64/String plan as a positive control" do
    type_name = "Tuple(a UInt64, b String)"
    plan = CrystalClick::WideTupleTypePlan.for_type(type_name).not_nil!

    plan.type_name.should eq(type_name)
    plan.fields.map { |field| {field.name, field.type_name} }.should eq([{"a", "UInt64"}, {"b", "String"}])
    plan.physical_streams("payload").should eq([
      "payload%2Ea",
      "payload%2Eb.size",
      "payload%2Eb",
    ])
    plan.stream_width("payload", "payload%2Ea").should eq(8)
    plan.stream_width("payload", "payload%2Eb.size").should eq(8)
    plan.stream_width("payload", "payload%2Eb").should eq(1)

    fixed_bytes = 64_u64 + 2_u64 * sizeof(CrystalClick::WideTupleField).to_u64 +
                  w96_flat_tree_and_path_charge(["a", "b"] of String) +
                  w96_leaf_descriptor_charge("UInt64") + w96_leaf_descriptor_charge("String")
    bytes_per_row = 8_u64 + 8_u64 + 16_u64
    plan.materialization_charge(3_u64, 5_u64).should eq(fixed_bytes + 3_u64 * bytes_per_row + 5_u64)
  end

  it("plans an Int8 leaf with exact width and accounting") { w96_assert_numeric_plan("Int8", 1) }
  it("plans an Int16 leaf with exact width and accounting") { w96_assert_numeric_plan("Int16", 2) }
  it("plans an Int32 leaf with exact width and accounting") { w96_assert_numeric_plan("Int32", 4) }
  it("plans an Int64 leaf with exact width and accounting") { w96_assert_numeric_plan("Int64", 8) }
  it("plans an Int128 leaf with exact width and accounting") { w96_assert_numeric_plan("Int128", 16) }
  it("plans an Int256 leaf with exact width and accounting") { w96_assert_numeric_plan("Int256", 32) }

  it("plans a UInt8 leaf with exact width and accounting") { w96_assert_numeric_plan("UInt8", 1) }
  it("plans a UInt16 leaf with exact width and accounting") { w96_assert_numeric_plan("UInt16", 2) }
  it("plans a UInt32 leaf with exact width and accounting") { w96_assert_numeric_plan("UInt32", 4) }
  it("plans a UInt64 leaf with exact width and accounting") { w96_assert_numeric_plan("UInt64", 8) }
  it("plans a UInt128 leaf with exact width and accounting") { w96_assert_numeric_plan("UInt128", 16) }
  it("plans a UInt256 leaf with exact width and accounting") { w96_assert_numeric_plan("UInt256", 32) }

  it("plans a Float32 leaf with exact width and accounting") { w96_assert_numeric_plan("Float32", 4) }
  it("plans a Float64 leaf with exact width and accounting") { w96_assert_numeric_plan("Float64", 8) }
  it("plans a BFloat16 leaf with exact width and accounting") { w96_assert_numeric_plan("BFloat16", 2) }

  it "preserves declaration-order streams and charges heterogeneous leaf widths together" do
    type_name = "Tuple(signed Int8, ratio Float32, bf BFloat16, wide Int256, text String)"
    plan = CrystalClick::WideTupleTypePlan.for_type(type_name).not_nil!

    plan.fields.map { |field| {field.name, field.type_name} }.should eq([
      {"signed", "Int8"},
      {"ratio", "Float32"},
      {"bf", "BFloat16"},
      {"wide", "Int256"},
      {"text", "String"},
    ])
    plan.physical_streams("payload").should eq([
      "payload%2Esigned",
      "payload%2Eratio",
      "payload%2Ebf",
      "payload%2Ewide",
      "payload%2Etext.size",
      "payload%2Etext",
    ])
    [1, 4, 2, 32, 8, 1].each_with_index do |width, index|
      plan.stream_width("payload", plan.physical_streams("payload")[index]).should eq(width)
    end
    plan.raw_string_stream?("payload", "payload%2Etext").should be_true
    plan.raw_string_stream?("payload", "payload%2Ewide").should be_false

    # 64 bytes of result container + five actual field slots and independent
    # schema-tree/path metadata; per row
    # 8-byte row + 1+4+2+32-byte numeric slots + one 16-byte String slot;
    # raw String payload bytes are added only once after all fields.
    leaf_descriptor_bytes = 0_u64
    ["Int8", "Float32", "BFloat16", "Int256", "String"].each do |base_type_name|
      leaf_descriptor_bytes += w96_leaf_descriptor_charge(base_type_name)
    end
    fixed_bytes = 64_u64 + 5_u64 * sizeof(CrystalClick::WideTupleField).to_u64 +
                  w96_flat_tree_and_path_charge(["signed", "ratio", "bf", "wide", "text"] of String) +
                  leaf_descriptor_bytes
    row_bytes = 8_u64 + 1_u64 + 4_u64 + 2_u64 + 32_u64 + 16_u64
    plan.materialization_charge(3_u64, 5_u64).should eq(fixed_bytes + 3_u64 * row_bytes + 5_u64)
  end

  it "admits Nullable scalar and nested leaves while rejecting malformed and unsupported recursive types" do
    [
      "Tuple(value Nullable(Bool))",
      "Tuple(value Nullable(Int8))",
      "Tuple(value Nullable(Enum8('a' = 1)))",
      "Tuple(value Nullable(Decimal(9, 2)))",
    ].each do |type_name|
      CrystalClick::WideTupleTypePlan.for_type(type_name).should_not be_nil
    end

    # Flat Decimal(P, S) and Enum8 leaves are admitted by W101; only malformed
    # precision or unsupported nullable/nested placements remain negative.
    rejected = [
      "Tuple()",
      "Tuple(Int8)",
      "Tuple(value Decimal(0, 2))",
      "Tuple(value Array(Int8))",
      "Tuple(value Tuple())",
      "Tuple(value Array(Tuple(inner Int8)))",
      "Tuple(value String())",
      "Tuple(value UInt8())",
      "Tuple(value UInt16())",
      "Tuple(value UInt32())",
      "Tuple(value UInt64())",
      "Tuple(value UInt128())",
      "Tuple(value UInt256())",
      "Tuple(value Int8())",
      "Tuple(value Int16())",
      "Tuple(value Int32())",
      "Tuple(value Int64())",
      "Tuple(value Int128())",
      "Tuple(value Int256())",
      "Tuple(value Float32())",
      "Tuple(value Float64())",
      "Tuple(value BFloat16())",
    ]

    rejected.each do |type_name|
      CrystalClick::WideTupleTypePlan.for_type(type_name).should be_nil
    end

    nested = CrystalClick::WideTupleTypePlan.for_type("Tuple(value Tuple(inner Int8))").not_nil!
    nested.fields.map { |field| {field.name, field.type_name} }.should eq([{"value.inner", "Int8"}])
    nested.physical_streams("payload").should eq(["payload%2Evalue%2Einner"])
  end
end
