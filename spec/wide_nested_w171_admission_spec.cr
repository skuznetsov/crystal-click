require "./spec_helper"

describe "W171 unflattened Nested admission" do
  it "admits the exact Nested witness while preserving the Array(Tuple) control" do
    nested = "Nested(a UInt64, b String, c Nullable(Int32))"

    CrystalClick::WidePart.supports_typed_type?(nested).should be_true
    CrystalClick::WidePart.supports_typed_type?("Array(Tuple(a UInt64, b String, c Nullable(Int32)))").should be_true
  end

  it "rejects malformed declarations and unsupported child containers" do
    CrystalClick::WidePart.supports_typed_type?("Nested(a UInt64, b String").should be_false
    CrystalClick::WidePart.supports_typed_type?("Nested(a UInt64, a String)").should be_false
    CrystalClick::WidePart.supports_typed_type?("Nested(a Array(UInt64), b String)").should be_false
  end
end
