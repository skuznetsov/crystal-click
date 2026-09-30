module CrystalClick
  # Owned, row-aligned, declaration-ordered Tuple leaf buffers returned by the
  # compositional reader. Values remain columnar rather than an arity union.
  class WideTupleColumnData
    @plan : WideTupleTypePlan
    @columns : Array(WideTupleLeafColumn)
    @row_count : Int32

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

    def [](name : String) : WideTupleLeafColumn
      index = @plan.fields.index { |field| field.name == name } || raise(KeyError.new("Tuple field not found: #{name}"))
      @columns[index].owned_copy
    end
  end
end
