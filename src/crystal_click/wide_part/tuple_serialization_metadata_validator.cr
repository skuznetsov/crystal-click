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
      prevalidate_subcolumns_common_fields!(subcolumns, root_fields, row_count)

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

    # Check only common fields on children whose positions have a known schema
    # node. This bounded pass runs before record kind/shape classification so
    # an unsupported earlier sibling cannot hide corruption in a later one.
    # It deliberately walks at most the existing schema tree, never arbitrary
    # JSON descendants.
    def self.prevalidate_subcolumns_common_fields!(
      subcolumns : Array(JSON::Any),
      root_fields : Array(WideTupleSchemaNode),
      row_count : UInt64,
    ) : Nil
      prevalidate_known_children!(subcolumns, root_fields, row_count)
      nil
    end

    private def self.prevalidate_known_children!(
      values : Array(JSON::Any),
      schema_nodes : Array(WideTupleSchemaNode),
      row_count : UInt64,
    ) : Nil
      schema_nodes.each_with_index do |schema_node, index|
        next if index >= values.size
        prevalidate_node_common_fields!(values[index], schema_node, row_count)
      end
      nil
    end

    private def self.prevalidate_node_common_fields!(
      value : JSON::Any,
      schema_node : WideTupleSchemaNode,
      row_count : UInt64,
    ) : Nil
      entry = value.as_h
      validate_common_fields!(entry, row_count)

      unless schema_node.leaf?
        if child_value = entry["subcolumns"]?
          children = child_value.as_a
          prevalidate_known_children!(children, schema_node.children, row_count)
        end
      end
      nil
    end

    private def self.validate_node!(
      value : JSON::Any,
      schema_node : WideTupleSchemaNode,
      row_count : UInt64,
    ) : Nil
      entry = value.as_h
      kind = validate_common_fields!(entry, row_count)

      tuple_node = !schema_node.leaf?
      expected_keys = tuple_node ? Set{"kind", "num_defaults", "num_rows", "subcolumns"} : Set{"kind", "num_defaults", "num_rows"}
      extended_keys = expected_keys.dup
      extended_keys << "exact_num_defaults"
      unless entry.keys.to_set == expected_keys || entry.keys.to_set == extended_keys
        raise UnsupportedFormatError.new("unsupported Tuple child serializer fields")
      end

      raise UnsupportedFormatError.new("only Default Tuple child serializers are supported") unless kind == "Default"

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

    private def self.validate_common_fields!(
      entry : Hash(String, JSON::Any),
      row_count : UInt64,
    ) : String
      kind = entry["kind"]?.try(&.as_s) ||
             raise(CorruptPartError.new("Tuple child serializer kind is missing or malformed"))
      defaults = entry["num_defaults"]?.try(&.as_i) ||
                 raise(CorruptPartError.new("Tuple child default count is missing or malformed"))
      rows = entry["num_rows"]?.try(&.as_i) ||
             raise(CorruptPartError.new("Tuple child row count is missing or malformed"))
      raise CorruptPartError.new("Tuple child row count does not match part") unless rows >= 0 && rows.to_u64 == row_count
      raise CorruptPartError.new("Tuple child default count is invalid") unless defaults >= 0 && defaults <= rows

      if exact = entry["exact_num_defaults"]?
        exact.as_bool
      end
      kind
    end
  end
end
