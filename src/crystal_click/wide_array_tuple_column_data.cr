module CrystalClick
  # Owned ragged outer-row schedule plus one flattened, declaration-ordered
  # Tuple leaf payload. Size/offset arrays are copied on input and export.
  class WideArrayTupleColumnData
    @plan : WideArrayTupleTypePlan
    @tuple_data : WideTupleColumnData
    @row_sizes : Array(UInt64)
    @offsets : Array(UInt64)
    @row_count : Int32
    @element_count : Int32

    def initialize(
      @plan : WideArrayTupleTypePlan,
      row_sizes : Array(UInt64),
      @tuple_data : WideTupleColumnData,
    )
      raise ArgumentError.new("Array(Tuple) result schema does not match its leaf data") unless @tuple_data.type_name == @plan.tuple_plan.type_name
      # The offsets array needs row_count + 1 slots. Reject the maximum Int32
      # row count before that addition can overflow its native Int32 size.
      raise ArgumentError.new("Array(Tuple) row count exceeds the supported range") if row_sizes.size >= Int32::MAX

      @row_sizes = row_sizes.dup
      @row_count = @row_sizes.size.to_i32
      @element_count = @tuple_data.row_count
      @offsets = Array(UInt64).new(@row_sizes.size + 1, 0_u64)

      total = 0_u64
      @row_sizes.each_with_index do |size, index|
        if size > UInt64::MAX - total
          raise ArgumentError.new("Array(Tuple) element count overflows")
        end
        total += size
        if total > Int32::MAX.to_u64
          raise ArgumentError.new("Array(Tuple) element count exceeds the supported range")
        end
        @offsets[index + 1] = total
      end
      unless total == @element_count.to_u64
        raise ArgumentError.new("Array(Tuple) sizes do not match the flattened leaf count")
      end
    end

    def plan : WideArrayTupleTypePlan
      @plan
    end

    def tuple_data : WideTupleColumnData
      @tuple_data
    end

    def row_sizes : Array(UInt64)
      @row_sizes.dup
    end

    def offsets : Array(UInt64)
      @offsets.dup
    end

    def row_count : Int32
      @row_count
    end

    def element_count : Int32
      @element_count
    end

    def type_name : String
      @plan.type_name
    end

    def row(index : Int) : WideArrayTupleRow
      raise BoundsError.new("Array(Tuple) row index is out of bounds") if index < 0 || index >= @row_count
      WideArrayTupleRow.new(self, index)
    end

    # Narrow scalar accessors used by the row handle; public callers receive
    # detached whole-array snapshots from #row_sizes and #offsets.
    def row_size_at(index : Int32) : UInt64
      raise BoundsError.new("Array(Tuple) row index is out of bounds") if index < 0 || index >= @row_count
      @row_sizes[index]? || raise(BoundsError.new("Array(Tuple) row index is out of bounds"))
    end

    def element_offset_at(index : Int32) : UInt64
      raise BoundsError.new("Array(Tuple) row boundary is out of bounds") if index < 0 || index > @row_count
      @offsets[index]? || raise(BoundsError.new("Array(Tuple) row index is out of bounds"))
    end
  end
end
