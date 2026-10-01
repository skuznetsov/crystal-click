require "./spec_helper"

private def w97_plan_leaf_descriptor_charge(base_type_name : String) : UInt64
  instance_sizeof(CrystalClick::WideTupleLeafType).to_u64 +
    instance_sizeof(String).to_u64 + base_type_name.bytesize.to_u64 + 1_u64
end

describe "W97 named Bool Tuple plan" do
  it "preserves Bool identity while deriving its byte stream and shared charge" do
    type_name = "Tuple(flag Bool, byte UInt8, text String)"
    plan = CrystalClick::WideTupleTypePlan.for_type(type_name)
    plan.should_not be_nil

    if plan
      plan.type_name.should eq(type_name)
      plan.fields.map { |field| {field.name, field.type_name} }.should eq([
        {"flag", "Bool"},
        {"byte", "UInt8"},
        {"text", "String"},
      ])
      plan.physical_streams("payload").should eq([
        "payload%2Eflag",
        "payload%2Ebyte",
        "payload%2Etext.size",
        "payload%2Etext",
      ])

      plan.stream_width("payload", "payload%2Eflag").should eq(1)
      plan.stream_width("payload", "payload%2Ebyte").should eq(1)
      plan.stream_width("payload", "payload%2Etext.size").should eq(8)
      plan.stream_width("payload", "payload%2Etext").should eq(1)
      plan.raw_string_stream?("payload", "payload%2Eflag").should be_false
      plan.raw_string_stream?("payload", "payload%2Ebyte").should be_false
      plan.raw_string_stream?("payload", "payload%2Etext").should be_true

      # 64 container + three actual field slots + independently measured leaf
      # owners + 5*(8 row + 1 Bool + 1 UInt8
      # + 16 String slot) + 9 raw String bytes. Empty strings still pay slots.
      fixed_bytes = CrystalClick::WideTupleTypePlan::RESULT_CONTAINER_ACCOUNTING_BYTES +
                    3_u64 * CrystalClick::WideTupleTypePlan::FIELD_CONTAINER_ACCOUNTING_BYTES +
                    w97_plan_leaf_descriptor_charge("Bool") +
                    w97_plan_leaf_descriptor_charge("UInt8") +
                    w97_plan_leaf_descriptor_charge("String")
      row_bytes = CrystalClick::WideTupleTypePlan::RESULT_ROW_ACCOUNTING_BYTES +
                  sizeof(Bool).to_u64 + sizeof(UInt8).to_u64 +
                  CrystalClick::WideTupleTypePlan::STRING_SLOT_ACCOUNTING_BYTES
      plan.materialization_charge(5_u64, 0_u64).should eq(fixed_bytes + 5_u64 * row_bytes)
      plan.materialization_charge(5_u64, 9_u64).should eq(fixed_bytes + 5_u64 * row_bytes + 9_u64)
    end

    uint8 = CrystalClick::WideTupleTypePlan.for_type("Tuple(value UInt8)").not_nil!
    uint8.fields.map(&.type_name).should eq(["UInt8"])
    uint8.stream_width("payload", "payload%2Evalue").should eq(1)
    if plan
      plan.fields.first.type_name.should_not eq(uint8.fields.first.type_name)
    end
  end

  it "admits Nullable Bool and rejects aliases or neighboring recursive and unnamed shapes" do
    nullable = CrystalClick::WideTupleTypePlan.for_type("Tuple(flag Nullable(Bool))").not_nil!
    nullable.fields.first.type_name.should eq("Nullable(Bool)")

    rejected = [
      "Tuple()",
      "Tuple(Bool)",
      "Tuple(flag Bool())",
      "Tuple(flag Bool ( ))",
      "Tuple(flag Array(Bool))",
      "Tuple(flag Tuple(inner Bool))",
    ]

    rejected.each do |type_name|
      CrystalClick::WideTupleTypePlan.for_type(type_name).should be_nil
    end
  end
end
