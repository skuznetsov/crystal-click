require "./spec_helper"

describe "W106 nested named Tuple admission" do
  it "admits the stock-qualified three-level declaration without widening nullable containers" do
    nested = "Tuple(id UInt64, details Tuple(state Nullable(Enum8('neg' = -7, 'pos' = 7)), metadata Tuple(note Nullable(String), event DateTime64(3, 'America/New_York')), fixed FixedString(3), count UInt32))"
    flat_control = "Tuple(id UInt64, state Nullable(Enum8('neg' = -7, 'pos' = 7)), note Nullable(String), event DateTime64(3, 'America/New_York'), fixed FixedString(3), count UInt32)"

    CrystalClick::WideTupleTypePlan.for_type(flat_control).should_not be_nil
    plan = CrystalClick::WideTupleTypePlan.for_type(nested)
    plan.should_not be_nil
    plan.not_nil!.type_name.should eq(nested)
    CrystalClick::WideTupleTypePlan.for_type("Tuple(value Nullable(Tuple(inner UInt64)))").should be_nil
  end
end
