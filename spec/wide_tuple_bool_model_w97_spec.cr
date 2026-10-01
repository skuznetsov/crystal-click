require "./spec_helper"

private def w97_mutate_first_byte(value : String) : Nil
  raise "W97 mutation fixture must be non-empty" if value.empty?
  value.to_unsafe[0] = 0x58_u8
end

private def w97_bool_row_after_data_scope : CrystalClick::WideTupleRow
  plan = CrystalClick::WideTupleTypePlan.for_type(
    "Tuple(flag Bool, byte UInt8, text String)"
  ) || raise "W97 Bool Tuple plan is not admitted"
  columns = [
    CrystalClick::WideTupleLeafColumn.new("flag", [false, true]),
    CrystalClick::WideTupleLeafColumn.new("byte", [17_u8, 23_u8]),
    CrystalClick::WideTupleLeafColumn.new("text", ["first", String.new(Bytes[0x61_u8, 0x00_u8, 0xff_u8])]),
  ]
  data = CrystalClick::WideTupleColumnData.new(plan, columns)
  data.row(1)
end

describe "W97 Bool named-Tuple model" do
  it "keeps Bool in its own exact leaf value and buffer unions" do
    {
      {{ CrystalClick::WideTupleLeafColumn::Value.union_types.includes?(Bool) }},
      {{ CrystalClick::WideTupleLeafColumn::Buffer.union_types.includes?(Array(Bool)) }},
    }.should eq({true, true})

    # Equal physical widths do not merge the two nominal schemas.
    CrystalClick::WideTupleNumericType.width("Bool").should be_nil
    CrystalClick::WideTupleNumericType.width("UInt8").should eq(1)
  end

  it "plans bare Bool leaves as one-byte streams and charges one slot per row" do
    type_name = "Tuple(flag Bool, byte UInt8, text String)"
    parsed = CrystalClick::WideTupleTypePlan.for_type(type_name)
    parsed.should_not be_nil
    plan = parsed.not_nil!

    plan.type_name.should eq(type_name)
    plan.fields.map(&.type_name).should eq(["Bool", "UInt8", "String"])
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
    plan.raw_string_stream?("payload", "payload%2Etext").should be_true

    # 64 container + three actual field slots + per row (8 row + 1 Bool +
    # 1 UInt8 + 16 String slots) + three String payload bytes.
    fixed_bytes = CrystalClick::WideTupleTypePlan::RESULT_CONTAINER_ACCOUNTING_BYTES +
                  3_u64 * CrystalClick::WideTupleTypePlan::FIELD_CONTAINER_ACCOUNTING_BYTES
    row_bytes = CrystalClick::WideTupleTypePlan::RESULT_ROW_ACCOUNTING_BYTES +
                sizeof(Bool).to_u64 + sizeof(UInt8).to_u64 +
                CrystalClick::WideTupleTypePlan::STRING_SLOT_ACCOUNTING_BYTES
    plan.materialization_charge(0_u64, 0_u64).should eq(fixed_bytes)
    plan.materialization_charge(2_u64, 3_u64).should eq(fixed_bytes + 2_u64 * row_bytes + 3_u64)
    plan.materialization_charge(UInt64::MAX, 0_u64).should be_nil
    plan.materialization_charge(0_u64, UInt64::MAX).should be_nil
  end

  it "rejects empty-argument Bool aliases and neighboring compositions" do
    [
      "Tuple(flag Bool())",
      "Tuple(flag Bool(UInt8))",
      "Tuple(flag Nullable(Bool))",
      "Tuple(flag Array(Bool))",
      "Tuple(flag Tuple(value Bool))",
      "Tuple(Bool)",
      "Tuple(flag Bool, flag UInt8)",
    ].each do |type_name|
      CrystalClick::WideTupleTypePlan.for_type(type_name).should be_nil
    end
  end

  it "owns Bool inputs and returned snapshots while preserving exact scalar access" do
    input_name = String.new(Bytes[0x66_u8, 0x6c_u8, 0x61_u8, 0x67_u8])
    source = [true, false]
    leaf = CrystalClick::WideTupleLeafColumn.new(input_name, source)

    input_name.to_unsafe[0] = 0x58_u8
    source[0] = false
    leaf.name.should eq("flag")
    leaf.type_name.should eq("Bool")
    leaf.size.should eq(2)
    leaf.values_as(Bool).should eq([true, false])
    leaf.value_at(0, Bool).should be_true
    leaf.value_at(1, Bool).should be_false

    output_name = leaf.name
    w97_mutate_first_byte(output_name)
    output_type_name = leaf.type_name
    w97_mutate_first_byte(output_type_name)
    leaf.name.should eq("flag")
    leaf.type_name.should eq("Bool")

    typed_snapshot = leaf.values_as(Bool)
    typed_snapshot[0] = false
    leaf.values_as(Bool).should eq([true, false])

    {% if CrystalClick::WideTupleLeafColumn::Buffer.union_types.includes?(Array(Bool)) %}
      buffer_snapshot = leaf.values.as(Array(Bool))
      buffer_snapshot[0] = false
      leaf.values_as(Bool).should eq([true, false])
    {% else %}
      raise "Array(Bool) is missing from the owned leaf Buffer union"
    {% end %}

    expect_raises(CrystalClick::UnsupportedFormatError) { leaf.value_at(0, UInt8) }
    expect_raises(CrystalClick::UnsupportedFormatError) { leaf.values_as(UInt8) }
  end

  it "keeps same-width UInt8 access nominally distinct and rejects unsupported buffers" do
    byte_leaf = CrystalClick::WideTupleLeafColumn.new("byte", [1_u8, 0_u8])
    byte_leaf.type_name.should eq("UInt8")
    byte_leaf.value_at(0, UInt8).should eq(1_u8)
    expect_raises(CrystalClick::UnsupportedFormatError) { byte_leaf.value_at(0, Bool) }
    expect_raises(CrystalClick::UnsupportedFormatError) { byte_leaf.values_as(Bool) }

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::WideTupleLeafColumn.new("tag", [:unsupported])
    end
  end

  it "retains mixed Bool rows after the column-data scope ends" do
    row = w97_bool_row_after_data_scope

    row.field_count.should eq(3)
    row.fields.map(&.type_name).should eq(["Bool", "UInt8", "String"])
    row.value_as("flag", Bool).should be_true
    row.value_as("byte", UInt8).should eq(23_u8)
    row["text"].should eq(String.new(Bytes[0x61_u8, 0x00_u8, 0xff_u8]))
    row.string_bytesize.should eq(3_u64)
    expect_raises(CrystalClick::UnsupportedFormatError) { row.value_as("flag", UInt8) }
    expect_raises(CrystalClick::UnsupportedFormatError) { row.value_as("byte", Bool) }

    returned_type_name = row.type_name
    w97_mutate_first_byte(returned_type_name)
    row.type_name.should eq("Tuple(flag Bool, byte UInt8, text String)")

    fields = row.fields
    returned_field_name = fields[0].name
    w97_mutate_first_byte(returned_field_name)
    row.fields[0].name.should eq("flag")
  end
end
