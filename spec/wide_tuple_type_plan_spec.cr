require "./spec_helper"

private def w94_leaf_descriptor_charge(base_type_name : String) : UInt64
  instance_sizeof(CrystalClick::WideTupleLeafType).to_u64 +
    instance_sizeof(String).to_u64 + base_type_name.bytesize.to_u64 + 1_u64
end

private def w106_flat_tree_and_path_charge(names : Array(String)) : UInt64
  node_bytes = instance_sizeof(CrystalClick::WideTupleSchemaNode).to_u64 +
               instance_sizeof(Array(CrystalClick::WideTupleSchemaNode)).to_u64
  string_owner_bytes = instance_sizeof(String).to_u64
  total = node_bytes + names.size.to_u64 * sizeof(Pointer(CrystalClick::WideTupleSchemaNode)).to_u64
  names.each do |name|
    total += node_bytes + string_owner_bytes + name.bytesize.to_u64 + 1_u64
    total += instance_sizeof(Array(String)).to_u64 + sizeof(Pointer(String)).to_u64
    total += string_owner_bytes + name.bytesize.to_u64 + 1_u64
  end
  total
end

describe "W94 named scalar-leaf Tuple type plan" do
  it "plans ordered UInt64 and String leaves without a fixed arity whitelist" do
    types = {
      "Tuple(only UInt64)"                                                                              => ["only"],
      "Tuple(a UInt64, b String)"                                                                       => ["a", "b"],
      "Tuple(text String, count UInt64, note String)"                                                   => ["text", "count", "note"],
      "Tuple(a UInt64, b String, c UInt64, d String, e UInt64, f String, g UInt64, h String, i UInt64)" => ["a", "b", "c", "d", "e", "f", "g", "h", "i"],
      "Tuple(first String, second String)"                                                              => ["first", "second"],
      "Tuple(first UInt64, second UInt64)"                                                              => ["first", "second"],
    }

    types.each do |type_name, expected_names|
      plan = CrystalClick::WideTupleTypePlan.for_type(type_name).not_nil!

      plan.type_name.should eq(type_name)
      plan.fields.map(&.name).should eq(expected_names)
      plan.fields.size.should eq(expected_names.size)
    end
  end

  it "derives stream order, widths, and raw String roles from declaration order" do
    type_name = "Tuple(text String, count UInt64, note String)"
    plan = CrystalClick::WideTupleTypePlan.for_type(type_name).not_nil!

    plan.physical_streams("payload").should eq([
      "payload%2Etext.size",
      "payload%2Etext",
      "payload%2Ecount",
      "payload%2Enote.size",
      "payload%2Enote",
    ])

    plan.stream_width("payload", "payload%2Etext.size").should eq(8)
    plan.stream_width("payload", "payload%2Etext").should eq(1)
    plan.stream_width("payload", "payload%2Ecount").should eq(8)
    plan.raw_string_stream?("payload", "payload%2Etext.size").should be_false
    plan.raw_string_stream?("payload", "payload%2Etext").should be_true
    plan.raw_string_stream?("payload", "payload%2Ecount").should be_false
    plan.raw_string_stream?("payload", "payload%2Enote").should be_true
  end

  it "accepts the bounded identifier grammar and rejects unsupported Tuple compositions" do
    max_name = "a" * 128
    CrystalClick::WideTupleTypePlan.for_type("Tuple(_valid9 String)").should_not be_nil
    CrystalClick::WideTupleTypePlan.for_type("Tuple(#{max_name} UInt64)").should_not be_nil

    rejected = [
      "UInt64",
      "Tuple()",
      "Tuple(UInt64, String)",
      "Tuple(a UInt64(), b String)",
      "Tuple(a UInt64, b String ( ))",
      "Tuple(a UInt64, a String)",
      "Tuple(null String)",
      "Tuple(#{"a" * 129} String)",
      "Tuple(1field UInt64)",
      "Tuple(a Bool())",
      "Tuple(a Array(String))",
      "Tuple(a Tuple())",
      "Tuple(a Tuple(x Array(String)))",
      "Tuple(a UInt64, b String) trailing",
    ]

    rejected.each do |type_name|
      CrystalClick::WideTupleTypePlan.for_type(type_name).should be_nil
    end

    nullable = CrystalClick::WideTupleTypePlan.for_type("Tuple(a Nullable(UInt64))").not_nil!
    nullable.fields.first.type_name.should eq("Nullable(UInt64)")
    nullable.fields.first.leaf_type.nullable?.should be_true
  end

  it "keeps nested Tuple edges in the tree while preserving the flat leaf projection" do
    source = "Tuple(left Tuple(value UInt64, note String), right Tuple(value UInt64))"
    plan = CrystalClick::WideTupleTypePlan.for_type(source).not_nil!

    plan.type_name.should eq(source)
    plan.fields.map(&.name).should eq(["left.value", "left.note", "right.value"])
    plan.fields.map(&.path_segments).should eq([
      ["left", "value"], ["left", "note"], ["right", "value"],
    ])
    plan.field_count.should eq(3)
    roots = plan.root_fields
    roots.map(&.name).should eq(["left", "right"])
    roots.first.leaf_field?.should be_nil
    roots.first.children.map(&.name).should eq(["value", "note"])
    roots.first.type_name.should eq("Tuple(value UInt64, note String)")
    plan.leaf_stream_name("payload", plan.fields.first).should eq("payload%2Eleft%2Evalue")
    plan.physical_streams("payload").should eq([
      "payload%2Eleft%2Evalue",
      "payload%2Eleft%2Enote.size",
      "payload%2Eleft%2Enote",
      "payload%2Eright%2Evalue",
    ])

    # The per-member 128-byte limit is local, not a limit on the flattened
    # logical path. Source and depth remain the global guards.
    outer = "a" * 128
    inner = "b" * 128
    long_path = "Tuple(#{outer} Tuple(#{inner} UInt8))"
    CrystalClick::WideTupleTypePlan.for_type(long_path).not_nil!.fields.first.name.bytesize.should eq(257)
  end

  it "charges empty String slots, ordered fields and checked overflow through the shared budget model" do
    single = CrystalClick::WideTupleTypePlan.for_type("Tuple(value UInt64)").not_nil!
    fixed_bytes = CrystalClick::WideTupleTypePlan::RESULT_CONTAINER_ACCOUNTING_BYTES +
                  CrystalClick::WideTupleTypePlan::FIELD_CONTAINER_ACCOUNTING_BYTES +
                  w106_flat_tree_and_path_charge(["value"]) +
                  w94_leaf_descriptor_charge("UInt64")
    single.materialization_charge(0_u64, 0_u64).should eq(fixed_bytes)
    single.materialization_charge(1_u64, 0_u64).should eq(
      fixed_bytes + CrystalClick::WideTupleTypePlan::RESULT_ROW_ACCOUNTING_BYTES +
      CrystalClick::WideTupleTypePlan::UINT64_SLOT_ACCOUNTING_BYTES
    )
    single.materialization_charge(UInt64::MAX, 0_u64).should be_nil
    single.materialization_charge(0_u64, UInt64::MAX).should be_nil

    nine_strings = CrystalClick::WideTupleTypePlan.for_type(
      "Tuple(a String, b String, c String, d String, e String, f String, g String, h String, i String)"
    ).not_nil!
    names = ["a", "b", "c", "d", "e", "f", "g", "h", "i"]
    # Independently count the synthetic root and leaf nodes, owned local
    # names, and one path array/string per flat field. The row portion remains
    # 8 row bytes plus 9*16 String slots.
    # empty payloads still consume a slot for every field.
    nine_string_fixed_bytes = CrystalClick::WideTupleTypePlan::RESULT_CONTAINER_ACCOUNTING_BYTES +
                              9_u64 * CrystalClick::WideTupleTypePlan::FIELD_CONTAINER_ACCOUNTING_BYTES +
                              w106_flat_tree_and_path_charge(names) +
                              9_u64 * w94_leaf_descriptor_charge("String")
    nine_string_row_bytes = CrystalClick::WideTupleTypePlan::RESULT_ROW_ACCOUNTING_BYTES +
                            9_u64 * CrystalClick::WideTupleTypePlan::STRING_SLOT_ACCOUNTING_BYTES
    nine_strings.materialization_charge(1_u64, 0_u64).should eq(nine_string_fixed_bytes + nine_string_row_bytes)
  end

  it "iterates String byte sizes without exposing payload String buffers" do
    strings = CrystalClick::WideTupleLeafColumn.new(
      "text",
      ["", "é", String.new(Bytes[0xff_u8, 0x00_u8])] of String
    )
    byte_sizes = [] of Int32
    strings.each_string_bytesize do |byte_size|
      byte_sizes << byte_size
      nil
    end
    byte_sizes.should eq([0, 2, 2])

    numbers = CrystalClick::WideTupleLeafColumn.new("n", [1_u64])
    expect_raises(CrystalClick::UnsupportedFormatError) do
      numbers.each_string_bytesize { |_byte_size| nil }
    end
  end
end
