module CrystalClick
  # One borrowed Object path column in a Compact Advanced JSON output batch.
  # Only present cells are retained; row indexes distinguish absence from a
  # present nullable BinaryValue without allocating a dense rows-by-paths grid.
  class CompactJsonColumnarColumn
    getter path : String
    getter fallback_type : BinaryDataType?

    @row_indexes : Array(Int32)
    @values : Array(CompactJsonColumnarCell)
    @window_start : Int32
    @window_count : Int32
    @dense_prefix : Bool
    @accounted_buffer_cells : UInt64
    @nullable_uint32_type : BinaryDataType?
    @nullable_uint32_values : Slice(UInt32)?
    @nullable_uint32_nulls : Slice(UInt8)?
    @nullable_uint32_active : Bool
    @nullable_uint32_filling : Bool

    def initialize(@path : String, @fallback_type : BinaryDataType? = nil, max_rows : Int? = nil)
      @row_indexes = [] of Int32
      @values = [] of CompactJsonColumnarCell
      @window_start = 0_i32
      @window_count = 0_i32
      @dense_prefix = true
      @accounted_buffer_cells = 0_u64
      @nullable_uint32_type = nil
      @nullable_uint32_values = nil
      @nullable_uint32_nulls = nil
      @nullable_uint32_active = false
      @nullable_uint32_filling = false
      if type = @fallback_type
        if self.class.nullable_uint32_type?(type) && (capacity = max_rows)
          if capacity <= 0 || capacity > WidePartTable::MAX_MARK_ROWS
            raise BoundsError.new("Compact JSON Nullable(UInt32) lane capacity is out of range")
          end
          @nullable_uint32_type = type
          @nullable_uint32_values = Slice(UInt32).new(capacity)
          @nullable_uint32_nulls = Slice(UInt8).new(capacity)
        end
      end
    end

    def self.nullable_uint32_type?(type : BinaryDataType) : Bool
      type.tag == BinaryDataType::TAG_NULLABLE && type.child_count == 1 &&
        type.child_at(0).tag == BinaryDataType::TAG_UINT32 && type.child_at(0).child_count == 0
    end

    # True when this column owns the exact reusable native Nullable(UInt32)
    # representation selected by its sealed fallback type.
    def has_nullable_uint32_lane? : Bool
      !@nullable_uint32_values.nil? && !@nullable_uint32_nulls.nil? && !@nullable_uint32_type.nil?
    end

    # True only after the current mark has been completely decoded into the
    # reusable native lane. An inactive lane does not imply path presence.
    def nullable_uint32_lane_active? : Bool
      @nullable_uint32_active
    end

    # Borrowed, read-only values for the active callback window. This accessor
    # never constructs BinaryValue objects.
    def nullable_uint32_values : Slice(UInt32)
      raise KeyError.new("Compact JSON Nullable(UInt32) lane is not active") unless @nullable_uint32_active
      values = @nullable_uint32_values || raise(KeyError.new("Compact JSON Nullable(UInt32) lane is unavailable"))
      Slice.new(values.to_unsafe + @window_start, @window_count, read_only: true)
    end

    # Borrowed, read-only null map for the active callback window. Each byte
    # matches the Nullable physical lane: 1 is NULL and 0 is present.
    def nullable_uint32_nulls : Slice(UInt8)
      raise KeyError.new("Compact JSON Nullable(UInt32) lane is not active") unless @nullable_uint32_active
      nulls = @nullable_uint32_nulls || raise(KeyError.new("Compact JSON Nullable(UInt32) lane is unavailable"))
      Slice.new(nulls.to_unsafe + @window_start, @window_count, read_only: true)
    end

    # :nodoc:
    # Prepare the full-mark direct decoder destination without publishing its
    # contents through the established cell API until decode validation ends.
    def begin_nullable_uint32_fill!(type : BinaryDataType, rows : Int) : Tuple(Slice(UInt32), Slice(UInt8))?
      return nil unless has_nullable_uint32_lane? && @nullable_uint32_type == type
      if @nullable_uint32_active || @nullable_uint32_filling
        raise CorruptPartError.new("Compact JSON Nullable(UInt32) fill is already active")
      end
      unless rows == @window_count && @window_start == 0 && @row_indexes.empty? && @values.empty?
        return nil
      end
      if rows < 0
        raise CorruptPartError.new("Compact JSON Nullable(UInt32) fill has a negative row count")
      end
      values = @nullable_uint32_values.not_nil!
      nulls = @nullable_uint32_nulls.not_nil!
      if rows > values.size || rows > nulls.size
        raise CorruptPartError.new("Compact JSON Nullable(UInt32) fill exceeds its retained mark capacity")
      end
      @nullable_uint32_filling = true
      {Slice.new(values.to_unsafe, rows), Slice.new(nulls.to_unsafe, rows)}
    end

    # :nodoc:
    def complete_nullable_uint32_fill!(rows : Int) : Nil
      unless has_nullable_uint32_lane? && @nullable_uint32_filling && rows == @window_count && @window_start == 0 &&
             @row_indexes.empty? && @values.empty?
        raise CorruptPartError.new("Compact JSON Nullable(UInt32) fill differs from its dense mark")
      end
      @nullable_uint32_filling = false
      @nullable_uint32_active = true
      nil
    end

    # :nodoc:
    # Compact a fully validated source Nullable(UInt32) lane into the selected
    # callback rows without constructing BinaryValue instances.
    def retain_nullable_uint32_rows!(destination_rows : Slice(Int32), source_rows : Int) : Nil
      unless @nullable_uint32_active && @window_start == 0 && source_rows == @window_count && destination_rows.size >= source_rows
        raise CorruptPartError.new("Compact JSON selected Nullable(UInt32) lane differs from its source mark")
      end
      values = @nullable_uint32_values || raise(CorruptPartError.new("active Nullable(UInt32) lane lost its values"))
      nulls = @nullable_uint32_nulls || raise(CorruptPartError.new("active Nullable(UInt32) lane lost its null map"))
      destination_count = 0
      source_rows.times do |source_row|
        destination_row = destination_rows[source_row]
        if destination_row >= 0
          unless destination_row == destination_count
            raise CorruptPartError.new("Compact JSON selected Nullable(UInt32) rows are unordered or out of range")
          end
          values[destination_row] = values[source_row]
          nulls[destination_row] = nulls[source_row]
          destination_count += 1
        end
      end
      @window_count = destination_count.to_i32
      nil
    end

    def row_count : Int32
      @window_count
    end

    # Returns nil for an absent path at this row. A present NULL remains an
    # owned BinaryValue with its exact descriptor and `is_null?` state.
    def value_at(row : Int) : BinaryValue?
      return nullable_uint32_value_at(row) if @nullable_uint32_active
      cell = cell_at(row)
      cell.try(&.materialize)
    end

    def present_at?(row : Int) : Bool
      if @nullable_uint32_active
        absolute_row!(row)
        return true
      end
      !cell_at(row).nil?
    end

    # :nodoc:
    # Borrow one cell for the duration of a callback. `borrowed_string_bytes?`
    # is read-only and valid while the batch remains on this callback's mark.
    def with_cell_at(row : Int, &block : CompactJsonColumnarCell -> T) : Bool forall T
      if cell = cell_at(row)
        yield cell
        true
      else
        false
      end
    end

    # :nodoc:
    # Visit present cells in one mark-relative row range in sorted order. This
    # legacy view materializes borrowed Strings, preserving its BinaryValue
    # callback contract for callers that explicitly request it.
    def each_cell_in_range(start : Int32, count : Int32, &block : Int32, BinaryValue -> Nil) : Nil
      each_cell_representation_in_range(start, count) { |row, cell| yield row, cell.materialize }
    end

    # :nodoc:
    # Internal borrowed-cell walk for direct verification and snapshots.
    def each_cell_representation_in_range(
      start : Int32,
      count : Int32,
      &block : Int32, CompactJsonColumnarCell -> Nil
    ) : Nil
      window_finish = @window_start + @window_count
      if count < 0 || start < @window_start || start > Int32::MAX - count
        raise IndexError.new("Compact JSON column row range is outside the active batch window")
      end
      finish = start + count
      if finish > window_finish
        raise IndexError.new("Compact JSON column row range is outside the active batch window")
      end
      if @nullable_uint32_active
        row = start
        while row < finish
          yield row, CompactJsonColumnarCell.owned(nullable_uint32_value_at(row - @window_start))
          row += 1
        end
        return nil
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
      last_cell_at(row).try(&.materialize)
    end

    # :nodoc:
    def last_cell_at(row : Int32) : CompactJsonColumnarCell?
      if @nullable_uint32_active
        return nil unless row == @window_start + @window_count - 1 && row >= @window_start
        return CompactJsonColumnarCell.owned(nullable_uint32_value_at(row - @window_start))
      end
      if !@row_indexes.empty? && @row_indexes[-1] == row
        @values[-1]
      else
        nil
      end
    end

    def type_at(row : Int) : BinaryDataType?
      if @nullable_uint32_active
        absolute_row!(row)
        return @nullable_uint32_type
      end
      cell_at(row).try(&.type) || @fallback_type
    end

    def nullable_at?(row : Int) : Bool
      if @nullable_uint32_active
        absolute_row!(row)
        return true
      end
      if cell = cell_at(row)
        cell.type.tag == BinaryDataType::TAG_NULLABLE || cell.is_null?
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
      @nullable_uint32_active = false
      @nullable_uint32_filling = false
      nil
    end

    # :nodoc:
    def append!(row : Int32, value : BinaryValue) : Bool
      append_cell!(row, CompactJsonColumnarCell.owned(value))
    end

    # :nodoc:
    def append_cell!(row : Int32, value : CompactJsonColumnarCell) : Bool
      if @nullable_uint32_active
        raise CorruptPartError.new("Compact JSON cell append conflicts with its active dense Nullable(UInt32) lane")
      end
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
      if values = @nullable_uint32_values
        if start > values.size || count > values.size - start
          raise CorruptPartError.new("Compact JSON Nullable(UInt32) window exceeds its retained capacity")
        end
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
      delta_cells * (sizeof(Int32).to_u64 + sizeof(CompactJsonColumnarCell).to_u64)
    end

    # :nodoc:
    # Copy only the active window into an independent reusable owner. This is
    # used by snapshots so they do not retain the original callback buffers.
    def copy_nullable_uint32_window_to!(destination : CompactJsonColumnarColumn) : Bool
      return false unless @nullable_uint32_active
      type = @nullable_uint32_type || raise(CorruptPartError.new("active Nullable(UInt32) lane lost its type"))
      source_values = nullable_uint32_values
      source_nulls = nullable_uint32_nulls
      target = destination.begin_nullable_uint32_fill!(type, @window_count) ||
               raise(CorruptPartError.new("snapshot Nullable(UInt32) destination differs from its source"))
      target[0].copy_from(source_values)
      target[1].copy_from(source_nulls)
      destination.complete_nullable_uint32_fill!(@window_count)
      true
    end

    private def cell_at(row : Int) : CompactJsonColumnarCell?
      return CompactJsonColumnarCell.owned(nullable_uint32_value_at(row)) if @nullable_uint32_active
      absolute_row = absolute_row!(row)
      if @dense_prefix && absolute_row < @values.size
        return @values[absolute_row]
      end
      index = lower_bound(absolute_row)
      return nil unless index < @row_indexes.size && @row_indexes[index] == absolute_row
      @values[index]
    end

    private def nullable_uint32_value_at(row : Int) : BinaryValue
      absolute_row = absolute_row!(row)
      type = @nullable_uint32_type || raise(CorruptPartError.new("active Nullable(UInt32) lane lost its type"))
      nulls = @nullable_uint32_nulls || raise(CorruptPartError.new("active Nullable(UInt32) lane lost its null map"))
      return BinaryValue.null(type) if nulls[absolute_row] == 1_u8
      child_type = type.child_at(0)
      child_bytes = Slice(UInt8).new(sizeof(UInt32))
      bits = (@nullable_uint32_values || raise(CorruptPartError.new("active Nullable(UInt32) lane lost its values")))[absolute_row]
      4.times do |index|
        child_bytes[index] = ((bits >> (index * 8)) & 0xff_u32).to_u8
      end
      child = BinaryValue.fixed(child_type, child_bytes)
      BinaryValue.nullable(type, child)
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
