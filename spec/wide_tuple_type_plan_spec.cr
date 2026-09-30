require "./spec_helper"

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
      "Tuple(a Nullable(UInt64))",
      "Tuple(a Bool())",
      "Tuple(a Array(String))",
      "Tuple(a Tuple(x UInt64))",
      "Tuple(a UInt64, b String) trailing",
    ]

    rejected.each do |type_name|
      CrystalClick::WideTupleTypePlan.for_type(type_name).should be_nil
    end
  end

  it "charges empty String slots, ordered fields and checked overflow through the shared budget model" do
    single = CrystalClick::WideTupleTypePlan.for_type("Tuple(value UInt64)").not_nil!
    single.materialization_charge(0_u64, 0_u64).should eq(88_u64)
    single.materialization_charge(1_u64, 0_u64).should eq(104_u64)
    single.materialization_charge(UInt64::MAX, 0_u64).should be_nil
    single.materialization_charge(0_u64, UInt64::MAX).should be_nil

    nine_strings = CrystalClick::WideTupleTypePlan.for_type(
      "Tuple(a String, b String, c String, d String, e String, f String, g String, h String, i String)"
    ).not_nil!
    # 64 container + 9*24 field overhead + 8 row + 9*16 String slots;
    # empty payloads still consume a slot for every field.
    nine_strings.materialization_charge(1_u64, 0_u64).should eq(432_u64)
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
