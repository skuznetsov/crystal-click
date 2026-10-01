require "./spec_helper"

describe "W107 compositional Array(Tuple) admission" do
  it "admits one Array around the recursively named W106 scalar-leaf tree" do
    element = "Tuple(id UInt64, left Tuple(details Tuple(state Nullable(Enum8('neg' = -7, 'pos' = 7)), flag Nullable(Bool), note Nullable(String), event DateTime64(3, 'America/New_York'), amount Nullable(Decimal(9, 2))), fixed FixedString(3), count UInt32), right Tuple(details Tuple(state Nullable(Enum8('neg' = -7, 'pos' = 7)), note Nullable(String), event DateTime64(9, 'UTC')), fixed FixedString(3), count UInt64))"
    target = "Array(#{element})"

    CrystalClick::WidePart.supports_typed_type?(target).should be_true
    # The recursive Array grammar belongs to the new compositional plan; the
    # older closed physical plan remains limited to its qualified W51/W55 set.
    CrystalClick::WideTypePlan.admitted(target).should be_nil
  end

  it "preserves legacy controls and rejects unsupported container edges" do
    CrystalClick::WidePart.supports_typed_type?(CrystalClick::WideTypePlan::TYPE_ARRAY_TUPLE_UINT64_STRING).should be_true
    CrystalClick::WidePart.supports_typed_type?(CrystalClick::WideTypePlan::TYPE_ARRAY_TUPLE_UINT64_UINT64).should be_true

    nested = "Tuple(id UInt64, detail Tuple(value Nullable(String)))"
    CrystalClick::WidePart.supports_typed_type?("Array(Nullable(#{nested}))").should be_false
    CrystalClick::WidePart.supports_typed_type?("Array(Array(#{nested}))").should be_false
    CrystalClick::WidePart.supports_typed_type?("Array(Tuple(value Array(UInt64)))").should be_false
  end
end
