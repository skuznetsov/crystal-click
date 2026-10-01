module CrystalClick
  # Allocation-light handle for one ordered Map row. Duplicate keys remain
  # distinct entries; values are scoped WideTupleRow handles over shared data.
  struct WideMapTupleRow
    @data : WideMapTupleColumnData
    @index : Int32

    def initialize(@data : WideMapTupleColumnData, index : Int)
      raise BoundsError.new("Map(Tuple) row index is out of bounds") if index < 0 || index >= @data.row_count
      @index = index.to_i32
    end

    def type_name : String
      @data.type_name
    end

    def size : Int32
      @data.row_size_at(@index).to_i32
    end

    def key_at(index : Int) : WideTupleLeafColumn::Value
      entry = checked_entry_index(index)
      @data.key_value_at(entry)
    end

    def key_as(index : Int, type : T.class) : T forall T
      entry = checked_entry_index(index)
      @data.key_as(entry, type)
    end

    def key_string_bytesize_at(index : Int) : UInt64
      @data.key_string_bytesize_at(checked_entry_index(index))
    end

    def value_at(index : Int) : WideTupleRow
      @data.value_row_at(checked_entry_index(index))
    end

    def entry_at(index : Int) : {WideTupleLeafColumn::Value, WideTupleRow}
      {key_at(index), value_at(index)}
    end

    # Ordered pair access mirrors Map's entry sequence without collapsing
    # duplicate keys into a Hash.
    def [](index : Int) : {WideTupleLeafColumn::Value, WideTupleRow}
      entry_at(index)
    end

    # Logical String payload bytes for this row, including value bytes hidden
    # beneath Nullable NULLs. No key or value String escapes this accounting
    # helper.
    def string_bytesize : UInt64
      total = 0_u64
      size.times do |index|
        key_bytes = key_string_bytesize_at(index)
        value_bytes = value_at(index).string_bytesize
        if key_bytes > UInt64::MAX - total
          raise CorruptPartError.new("Map(Tuple) row String byte count overflows")
        end
        total += key_bytes
        if value_bytes > UInt64::MAX - total
          raise CorruptPartError.new("Map(Tuple) row String byte count overflows")
        end
        total += value_bytes
      end
      total
    end

    def each(& : WideTupleLeafColumn::Value, WideTupleRow -> Nil) : Nil
      count = size
      count.times do |index|
        yield key_at(index), value_at(index)
        nil
      end
      nil
    end

    private def checked_entry_index(index : Int) : Int32
      row_size = size
      raise BoundsError.new("Map(Tuple) entry index is out of bounds") if index < 0 || index >= row_size
      absolute = @data.entry_offset_at(@index) + index.to_u64
      raise BoundsError.new("Map(Tuple) entry index exceeds the supported range") if absolute > Int32::MAX
      absolute.to_i32
    end
  end
end
