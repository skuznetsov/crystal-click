require "./spec_helper"

describe "W105 Nullable scalar Tuple admission" do
  it "admits a nullable wrapper for every existing flat scalar leaf family" do
    leaves = %w(Int8 UInt8 Int16 UInt16 Int32 UInt32 Int64 UInt64 Int128 UInt128 Int256 UInt256 Float32 Float64 BFloat16 Bool String UUID IPv4 IPv6 Date Date32 DateTime Time)
    10.times do |precision|
      leaves << "DateTime64(#{precision})"
      leaves << "Time64(#{precision})"
    end
    leaves.concat([
      "DateTime('UTC')", "DateTime64(9, 'America/New_York')",
      "FixedString(5)", "Enum8('negative' = -7, 'positive' = 4)",
      "Enum16('negative' = -300, 'positive' = 400)",
      "Decimal(9, 2)", "Decimal(18, 3)", "Decimal(38, 4)", "Decimal(76, 5)",
    ])

    rejected = [] of String
    leaves.each do |leaf|
      bare = "Tuple(value #{leaf})"
      nullable = "Tuple(value Nullable(#{leaf}))"
      CrystalClick::WideTupleTypePlan.for_type(bare).should_not be_nil
      rejected << nullable unless CrystalClick::WideTupleTypePlan.for_type(nullable)
    end
    rejected.should eq([] of String)
  end

  it "does not admit nullable containers or double-nullable leaves" do
    [
      "Tuple(value Nullable(Array(UInt64)))",
      "Tuple(value Nullable(Tuple(inner UInt64)))",
      "Tuple(value Nullable(Nullable(UInt64)))",
      "Nullable(Tuple(value UInt64))",
    ].each do |type_name|
      CrystalClick::WideTupleTypePlan.for_type(type_name).should be_nil
    end
  end
end
