require "./spec_helper"

describe "paired QBit type admission" do
  it "admits all four exact element identities and their nullable forms" do
    %w(Int8 BFloat16 Float32 Float64).each do |element|
      ["QBit(#{element}, 10)", "QBit(#{element}, 16, 8)"].each do |type|
        CrystalClick::WidePart.supports_typed_type?(type).should be_true
        CrystalClick::WidePart.supports_typed_type?("Nullable(#{type})").should be_true
      end
    end
  end

  it "admits only Array chains ending in QBit or direct Nullable(QBit)" do
    scalar = "QBit(Float32, 9)"
    CrystalClick::WidePart.supports_typed_type?("Array(#{scalar})").should be_true
    CrystalClick::WidePart.supports_typed_type?("Array(Array(#{scalar}))").should be_true
    CrystalClick::WidePart.supports_typed_type?("Array(Nullable(#{scalar}))").should be_true
    CrystalClick::WidePart.supports_typed_type?("Array(Array(Nullable(#{scalar})))").should be_true
    CrystalClick::WidePart.supports_typed_type?("Nullable(Array(#{scalar}))").should be_false
    CrystalClick::WidePart.supports_typed_type?("Array(Tuple(#{scalar}))").should be_false
    CrystalClick::WidePart.supports_typed_type?("Array(Map(UInt8, #{scalar}))").should be_false
  end

  it "does not admit unsupported elements, illegal strides, or adjacent compositions" do
    ["QBit(UInt8, 8)", "QBit(Float32, 0)", "QBit(Float32, 16, 3)",
     "QBit(Float32, 16, 0)", "QBit(Float32, 16, 32)",
     "QBit(Float32, 08)"].each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end
  end
end
