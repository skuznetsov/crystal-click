module CrystalClick
  # Owned outer Map schedule, exact key leaf and flattened Tuple entries.
  # Row access remains ordered and never collapses duplicate keys into a Hash.
  class WideMapTupleColumnData
    @plan : WideMapTupleTypePlan
    @key_column : WideTupleLeafColumn
    @tuple_data : WideTupleColumnData
    @row_sizes : Array(UInt64)
    @offsets : Array(UInt64)
    @row_count : Int32
    @entry_count : Int32

    def initialize(
      @plan : WideMapTupleTypePlan,
      key_column : WideTupleLeafColumn,
      @tuple_data : WideTupleColumnData,
      row_sizes : Array(UInt64),
    )
      raise ArgumentError.new("Map(Tuple) result row count exceeds the supported range") if row_sizes.size >= Int32::MAX
      raise ArgumentError.new("Map(Tuple) result exceeds the outer-row limit") if row_sizes.size > WidePart::MAX_ARRAY_MARK_ROWS
      unless key_column.name == "keys" && !key_column.leaf_type.nullable? && key_column.leaf_type == @plan.key_type
        raise ArgumentError.new("Map(Tuple) key leaf does not match its exact schema")
      end
      unless @tuple_data.type_name == @plan.tuple_plan.type_name
        raise ArgumentError.new("Map(Tuple) value data does not match its exact Tuple schema")
      end

      @key_column = key_column.owned_copy_for(@plan.key_type)
      @row_sizes = row_sizes.dup
      @row_count = @row_sizes.size.to_i32
      @entry_count = @tuple_data.row_count
      raise ArgumentError.new("Map(Tuple) result exceeds the entry limit") if @entry_count > WidePart::MAX_ARRAY_MARK_ELEMENTS
      unless @key_column.size == @entry_count
        raise ArgumentError.new("Map(Tuple) key and value entry counts differ")
      end

      @offsets = Array(UInt64).new(@row_sizes.size + 1, 0_u64)
      total = 0_u64
      @row_sizes.each_with_index do |size, index|
        if size > WidePart::MAX_ARRAY_MARK_ELEMENTS.to_u64 - total
          raise ArgumentError.new("Map(Tuple) entry count exceeds the supported range")
        end
        total += size
        @offsets[index + 1] = total
      end
      unless total == @entry_count.to_u64
        raise ArgumentError.new("Map(Tuple) size0 schedule does not match key/value entries")
      end
    end

    def plan : WideMapTupleTypePlan
      @plan
    end

    def key_column : WideTupleLeafColumn
      @key_column.owned_copy_for(@plan.key_type)
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

    def entry_count : Int32
      @entry_count
    end

    def type_name : String
      @plan.column_type
    end

    def row(index : Int) : WideMapTupleRow
      raise BoundsError.new("Map(Tuple) row index is out of bounds") if index < 0 || index >= @row_count
      WideMapTupleRow.new(self, index)
    end

    # Narrow row-handle accessors operate on retained buffers; exported columns
    # and offset arrays remain defensive snapshots.
    def row_size_at(index : Int32) : UInt64
      raise BoundsError.new("Map(Tuple) row index is out of bounds") if index < 0 || index >= @row_count
      @row_sizes[index]? || raise(BoundsError.new("Map(Tuple) row index is out of bounds"))
    end

    def entry_offset_at(index : Int32) : UInt64
      raise BoundsError.new("Map(Tuple) row boundary is out of bounds") if index < 0 || index > @row_count
      @offsets[index]? || raise(BoundsError.new("Map(Tuple) row boundary is out of bounds"))
    end

    def key_value_at(entry_index : Int32) : WideTupleLeafColumn::Value
      raise BoundsError.new("Map(Tuple) entry index is out of bounds") if entry_index < 0 || entry_index >= @entry_count
      @key_column.value_at(entry_index)
    end

    def key_as(entry_index : Int32, type : T.class) : T forall T
      raise BoundsError.new("Map(Tuple) entry index is out of bounds") if entry_index < 0 || entry_index >= @entry_count
      @key_column.value_at(entry_index, type)
    end

    def key_string_bytesize_at(entry_index : Int32) : UInt64
      raise BoundsError.new("Map(Tuple) entry index is out of bounds") if entry_index < 0 || entry_index >= @entry_count
      @key_column.string_bytesize_at(entry_index)
    end

    def key_string_bytesize : UInt64
      key_type = @plan.key_type
      fixed_string = key_type.parameterized_type.is_a?(WideTupleFixedStringType)
      return 0_u64 unless key_type.base_type_name == "String" || fixed_string
      total = 0_u64
      @key_column.each_string_bytesize do |size|
        bytes = size.to_u64
        raise CorruptPartError.new("Map(Tuple) key String byte count overflows") if bytes > UInt64::MAX - total
        total += bytes
        nil
      end
      total
    end

    def value_row_at(entry_index : Int32) : WideTupleRow
      raise BoundsError.new("Map(Tuple) entry index is out of bounds") if entry_index < 0 || entry_index >= @entry_count
      @tuple_data.row(entry_index)
    end
  end
end
