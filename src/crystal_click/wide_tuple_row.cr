module CrystalClick
  # Immutable scalar view of one row in an owned, bounded Tuple mark. Keeping
  # a row may retain the complete WideTupleColumnData mark; scalar String
  # access copies only the requested String bytes.
  struct WideTupleRow
    @data : WideTupleColumnData
    @index : Int32
    @scope_path : Array(String)?

    # Keep the public input wide until bounds have been checked. In
    # particular, never narrow an oversized Int64 index before rejecting it.
    def initialize(data : WideTupleColumnData, index : Int)
      if index < 0 || index >= data.row_count
        raise BoundsError.new("Tuple row index is out of bounds")
      end

      @data = data
      @index = index.to_i32
      @scope_path = nil
    end

    def initialize(data : WideTupleColumnData, index : Int, scope_path : Array(String))
      if index < 0 || index >= data.row_count
        raise BoundsError.new("Tuple row index is out of bounds")
      end
      raise KeyError.new("Tuple path cannot be empty") if scope_path.empty?
      node = data.node_at(scope_path) || raise(KeyError.new("Tuple path not found: #{scope_path.join(".")}"))
      raise ArgumentError.new("Tuple row scope must name a Tuple node") if node.leaf?
      @data = data
      @index = index.to_i32
      @scope_path = scope_path.map { |segment| String.new(segment.to_slice) }
    end

    def fields : Array(WideTupleField)
      if scope_path = @scope_path
        @data.fields_under(scope_path)
      else
        @data.fields
      end
    end

    def type_name : String
      if scope_path = @scope_path
        @data.type_name_at(scope_path) || raise(KeyError.new("Tuple path not found: #{scope_path.join(".")}"))
      else
        @data.type_name
      end
    end

    def field_count : Int32
      if scope_path = @scope_path
        @data.field_count_under(scope_path)
      else
        @data.field_count
      end
    end

    def root_fields : Array(WideTupleSchemaNode)
      if scope_path = @scope_path
        node = @data.node_at(scope_path) || raise(KeyError.new("Tuple path not found: #{scope_path.join(".")}"))
        node.children
      else
        @data.root_fields
      end
    end

    # Return another immutable scope handle over the same owned columnar mark.
    # Path components are local named-Tuple edges; no leaf buffers are copied.
    def tuple(path : String) : WideTupleRow
      segments = path.split('.')
      raise KeyError.new("Tuple path not found: #{path}") if segments.empty? || segments.any?(&.empty?)
      tuple(segments)
    end

    def tuple(path : Array(String)) : WideTupleRow
      raise KeyError.new("Tuple path cannot be empty") if path.empty?
      full_path = if scope_path = @scope_path
                    scope_path + path
                  else
                    path.dup
                  end
      node = @data.node_at(full_path) || raise(KeyError.new("Tuple path not found: #{full_path.join(".")}"))
      raise ArgumentError.new("Tuple row scope must name a Tuple node") if node.leaf?
      WideTupleRow.new(@data, @index, full_path)
    end

    # Logical payload-byte accounting only; no String references or copies
    # escape through this method.
    def string_bytesize : UInt64
      if scope_path = @scope_path
        @data.string_bytesize_at(@index, scope_path)
      else
        @data.string_bytesize_at(@index)
      end
    end

    def [](field_name : String) : WideTupleLeafColumn::Value
      if scope_path = @scope_path
        @data.value_at_scoped(scope_path, field_name, @index)
      else
        @data.value_at(field_name, @index)
      end
    end

    # Exact nominal scalar access; mismatched requested types are rejected
    # rather than widened or numerically converted.
    def value_as(field_name : String, type : T.class) : T forall T
      if scope_path = @scope_path
        @data.value_as_scoped(scope_path, field_name, @index, type)
      else
        @data.value_as(field_name, @index, type)
      end
    end
  end
end
