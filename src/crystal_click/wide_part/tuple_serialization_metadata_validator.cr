module CrystalClick
  # Validates the recursive Default-serializer subtree for one named Tuple
  # column. Envelope, key-column, file-size, and serialization-version checks
  # remain owned by WidePart; this owner only matches recursive child records
  # to the admitted schema tree.
  class TupleSerializationMetadataValidator
    def self.validate_subcolumns!(
      subcolumns : Array(JSON::Any),
      root_fields : Array(WideTupleSchemaNode),
      row_count : UInt64,
      legacy_two_leaf_diagnostic : Bool = false,
    ) : Nil
      unless subcolumns.size == root_fields.size
        message = if legacy_two_leaf_diagnostic
                    "exactly two Tuple child serializers are required"
                  else
                    "Tuple child serializer count does not match schema"
                  end
        raise UnsupportedFormatError.new(message)
      end

      root_fields.each_with_index do |node, index|
        validate_node!(subcolumns[index], node, row_count)
      end
      nil
    end

    private def self.validate_node!(
      value : JSON::Any,
      schema_node : WideTupleSchemaNode,
      row_count : UInt64,
    ) : Nil
      entry = value.as_h
      tuple_node = !schema_node.leaf?
      expected_keys = tuple_node ? Set{"kind", "num_defaults", "num_rows", "subcolumns"} : Set{"kind", "num_defaults", "num_rows"}
      unless entry.keys.to_set == expected_keys
        raise UnsupportedFormatError.new("unsupported Tuple child serializer fields")
      end

      kind = entry["kind"]?.try(&.as_s)
      raise UnsupportedFormatError.new("only Default Tuple child serializers are supported") unless kind == "Default"
      defaults = entry["num_defaults"]?.try(&.as_i) ||
                 raise(CorruptPartError.new("Tuple child default count is missing or malformed"))
      rows = entry["num_rows"]?.try(&.as_i) ||
             raise(CorruptPartError.new("Tuple child row count is missing or malformed"))
      raise CorruptPartError.new("Tuple child row count does not match part") unless rows >= 0 && rows.to_u64 == row_count
      raise CorruptPartError.new("Tuple child default count is invalid") unless defaults >= 0 && defaults <= rows

      if tuple_node
        children = entry["subcolumns"]?.try(&.as_a) ||
                   raise(UnsupportedFormatError.new("Tuple child serializer metadata is required"))
        schema_children = schema_node.children
        unless children.size == schema_children.size
          raise UnsupportedFormatError.new("Tuple child serializer count does not match schema")
        end
        schema_children.each_with_index do |child_node, index|
          validate_node!(children[index], child_node, row_count)
        end
      end
      nil
    end
  end
end
