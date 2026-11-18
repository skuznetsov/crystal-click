module CrystalClick
  # One borrowed Object path column in a Compact Advanced JSON output batch.
  # Only present cells are retained; row indexes distinguish absence from a
  # present nullable BinaryValue without allocating a dense rows-by-paths grid.
  class CompactJsonColumnarColumn
    getter path : String
    getter fallback_type : BinaryDataType?

    @row_indexes : Array(Int32)
    @values : Array(BinaryValue)
    @window_start : Int32
    @window_count : Int32
    @dense_prefix : Bool
    @accounted_buffer_cells : UInt64

    def initialize(@path : String, @fallback_type : BinaryDataType? = nil)
      @row_indexes = [] of Int32
      @values = [] of BinaryValue
      @window_start = 0_i32
      @window_count = 0_i32
      @dense_prefix = true
      @accounted_buffer_cells = 0_u64
    end

    def row_count : Int32
      @window_count
    end

    # Returns nil for an absent path at this row. A present NULL remains a
    # BinaryValue with its exact descriptor and `is_null?` state.
    def value_at(row : Int) : BinaryValue?
      absolute_row = absolute_row!(row)
      if @dense_prefix && absolute_row < @values.size
        return @values[absolute_row]
      end
      index = lower_bound(absolute_row)
      return nil unless index < @row_indexes.size && @row_indexes[index] == absolute_row
      @values[index]
    end

    def present_at?(row : Int) : Bool
      !value_at(row).nil?
    end

    # :nodoc:
    # Visit present cells in one mark-relative row range in sorted order. This
    # lets sparse cross-representation checks handle absent gaps with a single
    # monotone pass instead of binary-searching once per row.
    def each_cell_in_range(start : Int32, count : Int32, &block : Int32, BinaryValue -> Nil) : Nil
      window_finish = @window_start + @window_count
      if count < 0 || start < @window_start || start > Int32::MAX - count
        raise IndexError.new("Compact JSON column row range is outside the active batch window")
      end
      finish = start + count
      if finish > window_finish
        raise IndexError.new("Compact JSON column row range is outside the active batch window")
      end
      index = lower_bound(start)
      while index < @row_indexes.size && @row_indexes[index] < finish
        yield @row_indexes[index], @values[index]
        index += 1
      end
      nil
    end

    # :nodoc:
    # Appends are row-monotonic, so duplicate ownership (when the established
    # Object assembly precedence permits it) can only touch the final cell.
    def last_value_at(row : Int32) : BinaryValue?
      if !@row_indexes.empty? && @row_indexes[-1] == row
        @values[-1]
      else
        nil
      end
    end

    def type_at(row : Int) : BinaryDataType?
      value_at(row).try(&.type) || @fallback_type
    end

    def nullable_at?(row : Int) : Bool
      if value = value_at(row)
        value.type.tag == BinaryDataType::TAG_NULLABLE || value.is_null?
      else
        @fallback_type.try(&.tag) == BinaryDataType::TAG_NULLABLE
      end
    end

    # :nodoc:
    def reset! : Nil
      @row_indexes.clear
      @values.clear
      @window_start = 0_i32
      @window_count = 0_i32
      @dense_prefix = true
      nil
    end

    # :nodoc:
    def append!(row : Int32, value : BinaryValue) : Bool
      if !@row_indexes.empty? && @row_indexes[-1] == row
        # Preserve ObjectDocument assembly precedence if two admitted owners
        # write the same path for one row: later writes replace earlier ones.
        @values[@values.size - 1] = value
        return false
      end
      if !@row_indexes.empty? && @row_indexes[-1] > row
        raise CorruptPartError.new("Compact JSON column cells are not in row order")
      end
      @dense_prefix = false unless row == @row_indexes.size
      @row_indexes << row
      @values << value
      true
    end

    # :nodoc:
    def set_window!(start : Int32, count : Int32) : Nil
      if start < 0 || count < 0 || start > Int32::MAX - count
        raise CorruptPartError.new("Compact JSON column window is invalid")
      end
      @window_start = start
      @window_count = count
      nil
    end

    # :nodoc:
    def each_active_cell(&block : Int32, BinaryValue -> Nil) : Nil
      each_cell_in_range(@window_start, @window_count) { |row, value| yield row, value }
    end

    # :nodoc:
    # `clear` retains these backing arrays, so their high-water logical slots
    # stay charged to the reusable batch after prior cells are dropped. Crystal
    # does not expose Array capacity, so account for the high-water cell count.
    def account_buffer_high_water_cells! : UInt64
      unless @row_indexes.size == @values.size
        raise CorruptPartError.new("Compact JSON column buffers have different cell counts")
      end
      current = @row_indexes.size.to_u64
      return 0_u64 if current <= @accounted_buffer_cells
      delta_cells = current - @accounted_buffer_cells
      @accounted_buffer_cells = current
      delta_cells * (sizeof(Int32).to_u64 + sizeof(Pointer(BinaryValue)).to_u64)
    end

    private def absolute_row!(row : Int) : Int32
      if row < 0 || row >= @window_count
        raise IndexError.new("Compact JSON column row is outside the active batch window")
      end
      @window_start + row
    end

    private def lower_bound(target : Int32) : Int32
      low = 0
      high = @row_indexes.size
      while low < high
        middle = low + (high - low) // 2
        if @row_indexes[middle] < target
          low = middle + 1
        else
          high = middle
        end
      end
      low
    end
  end
end
