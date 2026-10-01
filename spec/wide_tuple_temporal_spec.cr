require "./spec_helper"

private def w100_temporal_tuple_leaf_cases : Array(Tuple(String, Int32))
  cases = [] of Tuple(String, Int32)
  cases << {"Date", 2}
  cases << {"Date32", 4}
  cases << {"DateTime", 4}
  cases << {"Time", 4}
  (0..9).each do |precision|
    cases << {"DateTime64(#{precision})", 8}
    cases << {"Time64(#{precision})", 8}
  end
  cases
end

private def w100_assert_temporal_singleton_plan(leaf_type : String, width : Int32) : Nil
  type_name = "Tuple(event #{leaf_type})"
  plan = CrystalClick::WideTupleTypePlan.for_type(type_name)

  # This is deliberately an existing-API behavioral RED on the predecessor:
  # it must fail admission assertions, never depend on future temporal classes.
  plan.should_not be_nil
  if plan
    plan.type_name.should eq(type_name)
    plan.fields.map { |field| {field.name, field.type_name} }.should eq([{"event", leaf_type}])
    plan.physical_streams("payload").should eq(["payload%2Eevent"])
    plan.stream_width("payload", "payload%2Eevent").should eq(width)
    plan.raw_string_stream?("payload", "payload%2Eevent").should be_false
  end
end

describe "W100 temporal Tuple plan admission" do
  w100_temporal_tuple_leaf_cases.each do |leaf_type, width|
    it "plans exact #{leaf_type} as its own named leaf with its physical width" do
      w100_assert_temporal_singleton_plan(leaf_type, width)
    end
  end

  it "composes all 24 exact temporal leaves in one ordered declaration" do
    cases = w100_temporal_tuple_leaf_cases
    declarations = cases.map_with_index { |entry, index| "field#{index} #{entry[0]}" }
    type_name = "Tuple(#{declarations.join(", ")})"
    plan = CrystalClick::WideTupleTypePlan.for_type(type_name)

    plan.should_not be_nil
    if plan
      plan.type_name.should eq(type_name)
      plan.fields.size.should eq(24)
      plan.fields.map(&.type_name).should eq(cases.map { |entry| entry[0] })
      plan.physical_streams("payload").should eq((0...24).map { |index| "payload%2Efield#{index}" })
      cases.each_with_index do |entry, index|
        plan.stream_width("payload", "payload%2Efield#{index}").should eq(entry[1])
      end
    end
  end

  it "retains current primitive, identifier, Bool, and String admission controls" do
    [
      {"UInt64", 8},
      {"IPv4", 4},
      {"IPv6", 16},
      {"UUID", 16},
      {"Bool", 1},
    ].each do |leaf_type, width|
      type_name = "Tuple(value #{leaf_type})"
      plan = CrystalClick::WideTupleTypePlan.for_type(type_name).not_nil!
      plan.type_name.should eq(type_name)
      plan.fields.map(&.type_name).should eq([leaf_type])
      plan.physical_streams("payload").should eq(["payload%2Evalue"])
      plan.stream_width("payload", "payload%2Evalue").should eq(width)
    end

    string_plan = CrystalClick::WideTupleTypePlan.for_type("Tuple(value String)").not_nil!
    string_plan.type_name.should eq("Tuple(value String)")
    string_plan.physical_streams("payload").should eq([
      "payload%2Evalue.size",
      "payload%2Evalue",
    ])
    string_plan.stream_width("payload", "payload%2Evalue.size").should eq(8)
    string_plan.stream_width("payload", "payload%2Evalue").should eq(1)
    string_plan.raw_string_stream?("payload", "payload%2Evalue").should be_true
  end

  it "rejects malformed, noncanonical, and unsupported compositions while admitting exact zones" do
    rejected = [
      "Tuple(event DateTime64)",
      "Tuple(event DateTime64())",
      "Tuple(event DateTime64(10))",
      "Tuple(event DateTime64(-1))",
      "Tuple(event DateTime64(03))",
      "Tuple(event DateTime64( 3 ))",
      "Tuple(event DateTime64(3, UTC))",
      "Tuple(event Time64())",
      "Tuple(event Time64(10))",
      "Tuple(event Time64(-1))",
      "Tuple(event Time64(00))",
      "Tuple(event Time64(3 ))",
      "Tuple(event Time64(3, 'UTC'))",
      "Tuple(event Date())",
      "Tuple(event Date32(0))",
      "Tuple(event DateTime(UTC))",
      "Tuple(event DateTime('Definitely/Not_A_Zone'))",
      "Tuple(event Time(0))",
      "Tuple(DateTime)",
      "Tuple(DateTime64(3))",
      "Tuple(event Nullable(Date32))",
      "Tuple(event Nullable(DateTime64(3)))",
      "Tuple(event Array(Time64(3)))",
      "Tuple(event Tuple(value DateTime))",
      "Tuple(event DateTime64(3),)",
    ]

    rejected.each do |type_name|
      CrystalClick::WideTupleTypePlan.for_type(type_name).should be_nil
    end

    CrystalClick::WideTupleTypePlan.for_type("Tuple(event DateTime64(3, 'UTC'))").should_not be_nil
    CrystalClick::WideTupleTypePlan.for_type("Tuple(event DateTime('UTC'))").should_not be_nil
  end
end
