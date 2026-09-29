require "./spec_helper"

describe "W82 Array(Map) String-leaf reader admission" do
  it "admits exactly the four String value declarations" do
    admitted = [
      "Array(Map(UInt64, String))",
      "Array(Map(String, String))",
      "Array(Map(UInt64, Nullable(String)))",
      "Array(Map(String, Nullable(String)))",
    ]
    rejected = [
      "Array(Map(UInt8, String))",
      "Array(Array(Map(String, String)))",
      "Array(Map(UInt64, Nullable(String))) ",
    ]

    admitted.each do |type|
      CrystalClick::WidePart.supports_array_map_type?(type).should be_true
    end
    rejected.each do |type|
      CrystalClick::WidePart.supports_array_map_type?(type).should be_false
    end
  end
end
