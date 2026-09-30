module CrystalClick
  # Immutable scalar view of one row in an owned, bounded Tuple mark. Keeping
  # a row may retain the complete WideTupleColumnData mark; scalar String
  # access copies only the requested String bytes.
  struct WideTupleRow
    @data : WideTupleColumnData
    @index : Int32

    # Keep the public input wide until bounds have been checked. In
    # particular, never narrow an oversized Int64 index before rejecting it.
    def initialize(data : WideTupleColumnData, index : Int)
      if index < 0 || index >= data.row_count
        raise BoundsError.new("Tuple row index is out of bounds")
      end

      @data = data
      @index = index.to_i32
    end

    def fields : Array(WideTupleField)
      @data.fields
    end

    def type_name : String
      @data.type_name
    end

    def field_count : Int32
      @data.field_count
    end

    # Logical payload-byte accounting only; no String references or copies
    # escape through this method.
    def string_bytesize : UInt64
      @data.string_bytesize_at(@index)
    end

    def [](field_name : String) : UInt64 | String
      @data.value_at(field_name, @index)
    end
  end
end
