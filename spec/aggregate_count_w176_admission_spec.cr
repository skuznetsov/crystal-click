require "./spec_helper"

describe "W176 Count Wide-part public admission" do
  {
    "none"     => "AggregateFunction(count)",
    "uint64"   => "AggregateFunction(count, UInt64)",
    "nullable" => "AggregateFunction(count, Nullable(UInt64))",
  }.each do |label, type_name|
    it "admits exact #{type_name} without aliasing UInt64" do
      CrystalClick::WidePart.supports_typed_type?(type_name).should be_true
      if stock_root = ENV["W176_STOCK_ROOT"]?
        part = CrystalClick::WidePart.open_typed(File.join(stock_root, "part-#{label}"), "c")
        part.column_type.should eq(type_name)
        part.row_count.should eq(5_u64)
        part.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
      end
    end
  end

  if stock_root = ENV["W176_STOCK_ROOT"]?
    it "retains the independent primitive UInt64 key control" do
      reader = CrystalClick::WidePart.open(File.join(stock_root, "part-none"), "pk")
      reader.read_uint64_mark_range("pk", 0, reader.mark_count).should eq([7_u64, 13_u64, 22_u64, 31_u64, 50_u64])
    end
  end
end
