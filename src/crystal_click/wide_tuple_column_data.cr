module CrystalClick
  # Owned, row-aligned, declaration-ordered Tuple leaf buffers returned by the
  # compositional reader. Values remain columnar rather than an arity union.
  class WideTupleColumnData
    @plan : WideTupleTypePlan
    @columns : Array(WideTupleLeafColumn)
    @row_count : Int32
    @field_indices : Hash(String, Int32)
    @string_field_indices : Array(Int32)

    def initialize(@plan : WideTupleTypePlan, columns : Array(WideTupleLeafColumn))
      fields = @plan.fields
      raise ArgumentError.new("Tuple result field count does not match schema") unless columns.size == fields.size

      row_count = columns.first?.try(&.size) || 0
      columns.each_with_index do |column, index|
        field = fields[index]
        unless column.name == field.name && column.type_name == field.type_name
          raise ArgumentError.new("Tuple result leaf does not match schema order")
        end
        raise ArgumentError.new("Tuple result leaves are not row-aligned") unless column.size == row_count
      end

      @columns = columns.dup
      @row_count = row_count
      @field_indices = {} of String => Int32
      @string_field_indices = [] of Int32
      fields.each_with_index do |field, index|
        @field_indices[String.new(field.name.to_slice)] = index.to_i32
        @string_field_indices << index.to_i32 if field.type_name == "String"
      end
    end

    def fields : Array(WideTupleField)
      @plan.fields
    end

    def columns : Array(WideTupleLeafColumn)
      @columns.map(&.owned_copy)
    end

    def row_count : Int32
      @row_count
    end

    def type_name : String
      @plan.type_name
    end

    def field_count : Int32
      @field_indices.size
    end

    # Construct a row handle only after checking in the caller's original
    # integer width. WideTupleRow repeats this check at its public constructor
    # boundary before storing an Int32 index.
    def row(index : Int) : WideTupleRow
      raise BoundsError.new("Tuple row index is out of bounds") if index < 0 || index >= @row_count
      WideTupleRow.new(self, index)
    end

    # Scalar named access is O(1) in the field count and copies only the
    # requested String value. It never clones the backing leaf column.
    def value_at(field_name : String, index : Int) : WideTupleLeafColumn::Value
      row_index = checked_row_index(index)
      value_at_field_index(field_index(field_name), row_index)
    end

    # Exact nominal access for consumers that require a concrete scalar type.
    # No same-width conversion is performed.
    def value_as(field_name : String, index : Int, type : T.class) : T forall T
      row_index = checked_row_index(index)
      @columns[field_index(field_name)].value_at(row_index, type)
    end

    private def field_index(field_name : String) : Int32
      @field_indices[field_name]? || raise(KeyError.new("Tuple field not found: #{field_name}"))
    end

    private def value_at_field_index(field_index : Int32, index : Int32) : WideTupleLeafColumn::Value
      raise BoundsError.new("Tuple row index is out of bounds") if index < 0 || index >= @row_count
      raise BoundsError.new("Tuple field index is out of bounds") if field_index < 0 || field_index >= @columns.size
      @columns[field_index].value_at(index)
    end

    # Sum String payload lengths for one row without copying any String bytes.
    def string_bytesize_at(index : Int32) : UInt64
      raise BoundsError.new("Tuple row index is out of bounds") if index < 0 || index >= @row_count
      total = 0_u64
      @string_field_indices.each do |field_index|
        field_bytes = @columns[field_index].string_bytesize_at(index)
        if field_bytes > UInt64::MAX - total
          raise CorruptPartError.new("Tuple String byte count overflows")
        end
        total += field_bytes
      end
      total
    end

    def [](name : String) : WideTupleLeafColumn
      @columns[field_index(name)].owned_copy
    end

    private def checked_row_index(index : Int) : Int32
      raise BoundsError.new("Tuple row index is out of bounds") if index < 0 || index >= @row_count
      index.to_i32
    end
  end
end
