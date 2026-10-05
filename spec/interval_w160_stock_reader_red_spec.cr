require "./spec_helper"

if stock_part = ENV["W160_INTERVAL_STOCK_WIDE_PART"]?
  describe "W160 stock-authored Interval Wide reader admission RED" do
    it "opens an exact stock IntervalSecond Wide column without a new API dependency" do
      part = stock_part
      column = ENV["W160_INTERVAL_STOCK_VALUE_COLUMN"]? || "v"
      reader = CrystalClick::WidePart.open_typed(part, column)

      reader.column_type.should eq("IntervalSecond")
      reader.row_count.should eq(6_u64)
      reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64])
      reader.read_interval_counts_mark_range(column, 0, reader.mark_count).should eq([7_i64, -3_i64, 0_i64, 42_i64, -1_i64, 11_i64])
      reader.read_interval_counts_mark_range(column, 1, 1).should eq([0_i64, 42_i64])
      expect_raises(CrystalClick::BoundsError) do
        reader.read_interval_counts_mark_range(column, 0, 0)
      end
    end
  end
end
