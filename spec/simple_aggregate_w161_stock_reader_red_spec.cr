require "./spec_helper"
require "./support/simple_aggregate_w161_types"

if stock_part = ENV["W161_SIMPLE_AGGREGATE_STOCK_WIDE_PART"]?
  describe "W161 stock-authored SimpleAggregateFunction Wide reader admission RED" do
    it "reads all nine scalar and outer Nullable profiles from the independently authored Wide part" do
      W161_SIMPLE_AGGREGATE_TYPES.each do |function_name, suffix, _function|
        scalar_column = "s_#{suffix}"
        scalar_type = "SimpleAggregateFunction(#{function_name}, UInt64)"
        scalar = CrystalClick::WidePart.open_typed(stock_part, scalar_column)
        scalar.column_type.should eq(scalar_type)
        scalar.row_count.should eq(6_u64)
        scalar.mark_row_counts.should eq([2_u64, 2_u64, 2_u64])
        scalar.read_simple_aggregate_uint64_mark_range(scalar_column, 0, scalar.mark_count).should eq(
          W161_SIMPLE_AGGREGATE_STOCK_VALUES
        )
        scalar.read_simple_aggregate_uint64_mark_range(scalar_column, 1, 1).should eq(
          W161_SIMPLE_AGGREGATE_STOCK_VALUES[2, 2]
        )
        expect_raises(CrystalClick::BoundsError) do
          scalar.read_simple_aggregate_uint64_mark_range(scalar_column, 0, 0)
        end
        expect_raises(CrystalClick::UnsupportedFormatError) do
          scalar.read_numeric_mark_range(scalar_column, 0, scalar.mark_count, UInt64)
        end

        nullable_column = "n_#{suffix}"
        nullable_type = "Nullable(#{scalar_type})"
        nullable = CrystalClick::WidePart.open_typed(stock_part, nullable_column)
        nullable.column_type.should eq(nullable_type)
        nullable.row_count.should eq(6_u64)
        nullable.mark_row_counts.should eq([2_u64, 2_u64, 2_u64])
        nullable.read_nullable_simple_aggregate_uint64_mark_range(nullable_column, 0, nullable.mark_count).should eq(
          W161_SIMPLE_AGGREGATE_STOCK_NULLABLE_VALUES
        )
        nullable.read_nullable_simple_aggregate_uint64_mark_range(nullable_column, 1, 1).should eq(
          W161_SIMPLE_AGGREGATE_STOCK_NULLABLE_VALUES[2, 2]
        )
        expect_raises(CrystalClick::BoundsError) do
          nullable.read_nullable_simple_aggregate_uint64_mark_range(nullable_column, 0, 0)
        end
        expect_raises(CrystalClick::UnsupportedFormatError) do
          nullable.read_nullable_numeric_mark_range(nullable_column, 0, nullable.mark_count, UInt64)
        end
      end
    end

    it "preserves every native scalar and Nullable value through selected table batches" do
      W161_SIMPLE_AGGREGATE_TYPES.each do |_function_name, suffix, _function|
        scalar_column = "s_#{suffix}"
        nullable_column = "n_#{suffix}"
        table = CrystalClick::WidePartTable.open_selected_typed(
          [stock_part], ["pk", scalar_column, nullable_column]
        )
        observed_keys = [] of UInt64
        observed_scalar = [] of UInt64
        observed_nullable = [] of UInt64?
        observed_marks = [] of Int32

        table.scan_typed(batch_rows: 2) do |batch|
          keys = batch.values_for("pk", UInt64)
          observed_keys.concat(keys.to_a)
          observed_scalar.concat(batch.simple_aggregate_uint64s_for(scalar_column).to_a)
          observed_nullable.concat(batch.nullable_simple_aggregate_uint64s_for(nullable_column).to_a)
          observed_marks.concat(Array(Int32).new(keys.size, batch.mark_index))
        end

        observed_keys.should eq(W161_SIMPLE_AGGREGATE_KEYS)
        observed_scalar.should eq(W161_SIMPLE_AGGREGATE_STOCK_VALUES)
        observed_nullable.should eq(W161_SIMPLE_AGGREGATE_STOCK_NULLABLE_VALUES)
        observed_marks.should eq([0, 0, 1, 1, 2, 2])

        empty_callbacks = 0
        table.scan_typed_window(table.total_row_count, 1) { |_batch| empty_callbacks += 1; nil }
        empty_callbacks.should eq(0)
      end
    end
  end
end
