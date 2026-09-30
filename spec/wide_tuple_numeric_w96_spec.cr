require "./spec_helper"

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

    fixed_bytes = CrystalClick::WideTupleTypePlan::RESULT_CONTAINER_ACCOUNTING_BYTES +
                  CrystalClick::WideTupleTypePlan::FIELD_CONTAINER_ACCOUNTING_BYTES
    bytes_per_row = CrystalClick::WideTupleTypePlan::RESULT_ROW_ACCOUNTING_BYTES + width.to_u64
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

    fixed_bytes = CrystalClick::WideTupleTypePlan::RESULT_CONTAINER_ACCOUNTING_BYTES +
                  2_u64 * CrystalClick::WideTupleTypePlan::FIELD_CONTAINER_ACCOUNTING_BYTES
    bytes_per_row = CrystalClick::WideTupleTypePlan::RESULT_ROW_ACCOUNTING_BYTES +
                    CrystalClick::WideTupleTypePlan::UINT64_SLOT_ACCOUNTING_BYTES +
                    CrystalClick::WideTupleTypePlan::STRING_SLOT_ACCOUNTING_BYTES
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

    # 64 bytes of result container + five 24-byte field descriptors; per row
    # 8-byte row + 1+4+2+32-byte numeric slots + one 16-byte String slot;
    # raw String payload bytes are added only once after all fields.
    plan.materialization_charge(3_u64, 5_u64).should eq(378_u64)
  end

  it "rejects neighboring semantic, recursive, unnamed, and empty-argument types" do
    rejected = [
      "Tuple()",
      "Tuple(Int8)",
      "Tuple(value Nullable(Bool))",
      "Tuple(value Date)",
      "Tuple(value DateTime64(3))",
      "Tuple(value Decimal(9, 2))",
      "Tuple(value Nullable(Int8))",
      "Tuple(value Array(Int8))",
      "Tuple(value Tuple(inner Int8))",
      "Tuple(value Enum8('a' = 1))",
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
  end
end
