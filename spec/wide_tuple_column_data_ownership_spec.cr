require "./spec_helper"

# String's public dup/clone preserve identity. These intentional unsafe writes
# discriminate the stronger byte-ownership contract of the Tuple models.
private def w94_mutate_string_byte(value : String, byte : UInt8) : Nil
  value.to_unsafe[0] = byte
end

describe "W94 Tuple model byte ownership" do
  it "copies String inputs and each exposed String payload" do
    source = String.new(Bytes[0x41_u8, 0x42_u8])
    input = [source]
    leaf = CrystalClick::WideTupleLeafColumn.new("s", input)
    w94_mutate_string_byte(source, 0x5a_u8)
    input[0] = "replaced"
    leaf.string_values.should eq(["AB"])

    exposed = leaf.string_values
    w94_mutate_string_byte(exposed[0], 0x59_u8)
    leaf.string_values.should eq(["AB"])
  end

  it "copies leaf metadata and UInt64 containers on input and exposure" do
    name = String.new("n".to_slice)
    values = [7_u64]
    leaf = CrystalClick::WideTupleLeafColumn.new(name, values)
    w94_mutate_string_byte(name, 0x78_u8)
    values[0] = 9_u64
    w94_mutate_string_byte(leaf.name, 0x79_u8)
    w94_mutate_string_byte(leaf.type_name, 0x58_u8)
    exposed_values = leaf.uint64_values
    exposed_values[0] = 11_u64
    leaf.name.should eq("n")
    leaf.type_name.should eq("UInt64")
    leaf.uint64_values.should eq([7_u64])
  end

  it "copies field metadata inputs and getters" do
    name = String.new(Bytes[0x6e_u8])
    type_name = String.new("String".to_slice)
    field = CrystalClick::WideTupleField.new(name, type_name)
    w94_mutate_string_byte(name, 0x78_u8)
    w94_mutate_string_byte(type_name, 0x58_u8)
    field.name.should eq("n")
    field.type_name.should eq("String")

    w94_mutate_string_byte(field.name, 0x79_u8)
    w94_mutate_string_byte(field.type_name, 0x59_u8)
    field.name.should eq("n")
    field.type_name.should eq("String")
  end

  it "protects canonical plan metadata from exposed byte mutation" do
    plan = CrystalClick::WideTupleTypePlan.for_type("Tuple(s String)").not_nil!
    exposed_type = plan.type_name
    w94_mutate_string_byte(exposed_type, 0x58_u8)
    field = plan.fields[0]
    w94_mutate_string_byte(field.name, 0x78_u8)
    plan.type_name.should eq("Tuple(s String)")
    plan.fields.map(&.name).should eq(["s"])
    plan.physical_streams("v").should eq(["v%2Es.size", "v%2Es"])
  end

  it "protects retained column results from input and getter byte mutation" do
    plan = CrystalClick::WideTupleTypePlan.for_type("Tuple(s String)").not_nil!
    source = String.new("retained".to_slice)
    leaf = CrystalClick::WideTupleLeafColumn.new("s", [source])
    data = CrystalClick::WideTupleColumnData.new(plan, [leaf])
    w94_mutate_string_byte(source, 0x58_u8)
    w94_mutate_string_byte(data["s"].string_values[0], 0x59_u8)
    w94_mutate_string_byte(data.columns[0].string_values[0], 0x5a_u8)
    data["s"].string_values.should eq(["retained"])
    data.row_count.should eq(1)
  end
end
