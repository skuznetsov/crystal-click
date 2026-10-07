module CrystalClick
  # Narrow schema-bound admission for ClickHouse Default serializer
  # subcolumns on a Dynamic-bearing Tuple value column. The ordinary Object
  # metadata parser remains strict unless this validator is explicitly passed
  # by DynamicBulkColumnReader.
  class DynamicTupleSerializationMetadataValidator
    private def initialize
    end

    def self.validate_subcolumns!(
      subcolumns : Array(JSON::Any),
      type : BinaryDataType,
      row_count : UInt64,
      limits : BinaryCodecLimits,
    ) : Nil
      unless tuple_type?(type)
        raise UnsupportedFormatError.new("Tuple subcolumns metadata does not match the selected Dynamic descriptor")
      end

      budget = BinaryCodecBudget.new(limits)
      budget.visit_node(1)
      validate_children!(subcolumns, type, row_count, budget, 1)
      nil
    rescue ex : TypeCastError | OverflowError
      raise CorruptPartError.new("Tuple serializer metadata is malformed")
    end

    private def self.validate_children!(
      subcolumns : Array(JSON::Any),
      tuple_type : BinaryDataType,
      row_count : UInt64,
      budget : BinaryCodecBudget,
      parent_depth : Int32,
    ) : Nil
      arity = tuple_type.child_count
      budget.preflight_children(arity.to_u64)
      unless subcolumns.size == arity
        raise UnsupportedFormatError.new("Tuple child serializer count does not match the selected Dynamic descriptor")
      end

      arity.times do |index|
        child = tuple_type.child_at(index)
        validate_node!(subcolumns[index], child, row_count, budget, parent_depth + 1)
      end
      nil
    end

    private def self.validate_node!(
      value : JSON::Any,
      type : BinaryDataType,
      row_count : UInt64,
      budget : BinaryCodecBudget,
      depth : Int32,
    ) : Nil
      budget.visit_node(depth)
      entry = value.as_h
      tuple = tuple_type?(type)
      fields = Set{"kind", "num_defaults", "num_rows"}
      fields << "subcolumns" if tuple
      extended_fields = fields.dup
      extended_fields << "exact_num_defaults"
      unless entry.keys.to_set == fields || entry.keys.to_set == extended_fields
        raise UnsupportedFormatError.new("unsupported Dynamic Tuple child serializer fields")
      end

      kind = entry["kind"]?.try(&.as_s)
      raise UnsupportedFormatError.new("only Default Dynamic Tuple child serializers are supported") unless kind == "Default"
      defaults = entry["num_defaults"]?.try(&.as_i) ||
                 raise(CorruptPartError.new("Dynamic Tuple child default count is missing or malformed"))
      rows = entry["num_rows"]?.try(&.as_i) ||
             raise(CorruptPartError.new("Dynamic Tuple child row count is missing or malformed"))
      unless rows >= 0 && rows.to_u64 == row_count
        raise CorruptPartError.new("Dynamic Tuple child row count does not match the part")
      end
      unless defaults >= 0 && defaults <= rows
        raise CorruptPartError.new("Dynamic Tuple child default count is invalid")
      end
      if exact = entry["exact_num_defaults"]?
        unless exact.as_bool
          raise UnsupportedFormatError.new("Dynamic Tuple exact-default flags must be true when present")
        end
      end

      if tuple
        children = entry["subcolumns"]?.try(&.as_a) ||
                   raise(UnsupportedFormatError.new("Dynamic Tuple child serializer metadata is required"))
        validate_children!(children, type, row_count, budget, depth)
      elsif entry.has_key?("subcolumns")
        raise UnsupportedFormatError.new("non-Tuple Dynamic child has unexpected serializer subcolumns")
      end
      nil
    end

    private def self.tuple_type?(type : BinaryDataType) : Bool
      type.tag == BinaryDataType::TAG_NAMED_TUPLE || type.tag == BinaryDataType::TAG_UNNAMED_TUPLE
    end
  end
end
