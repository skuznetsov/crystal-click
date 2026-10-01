module CrystalClick
  # Immutable view of one outer Array row. Element access returns existing
  # WideTupleRow handles over the shared flattened leaf buffers.
  struct WideArrayTupleRow
    @data : WideArrayTupleColumnData
    @index : Int32

    def initialize(@data : WideArrayTupleColumnData, index : Int)
      if index < 0 || index >= @data.row_count
        raise BoundsError.new("Array(Tuple) row index is out of bounds")
      end
      @index = index.to_i32
    end

    def size : Int32
      row_size.to_i32
    end

    def [](element_index : Int) : WideTupleRow
      row_length = row_size
      if element_index < 0 || element_index >= row_length
        raise BoundsError.new("Array(Tuple) element index is out of bounds")
      end
      tuple_index = @data.element_offset_at(@index) + element_index.to_u64
      @data.tuple_data.row(tuple_index.to_i32)
    end

    def each(&block : WideTupleRow ->) : Nil
      index = 0_i32
      count = size
      while index < count
        yield self[index]
        index += 1
      end
      nil
    end

    def row_index : Int32
      @index
    end

    private def row_size : UInt64
      @data.row_size_at(@index)
    end
  end
end
