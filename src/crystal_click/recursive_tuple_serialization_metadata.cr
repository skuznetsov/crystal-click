require "json"
require "set"

module CrystalClick
  # Schema-bound admission for ClickHouse SerializationInfoTuple subcolumns in
  # recursive Tuple readers. Arrays and non-Tuple wrappers remain opaque.
  class RecursiveTupleSerializationMetadata
    private def initialize
    end

    def self.validate_subcolumns!(
      subcolumns : Array(JSON::Any),
      schema : StorageColumnSchema,
      row_count : UInt64,
      limits : BinaryCodecLimits,
    ) : Nil
      unless schema.tuple?
        raise UnsupportedFormatError.new("selected recursive subcolumns require a Tuple schema")
      end
      if row_count > WidePart::MAX_ROWS
        raise CorruptPartError.new("recursive Tuple serializer row count exceeds the part limit")
      end

      budget = BinaryCodecBudget.new(limits)
      budget.visit_node(1)
      validate_storage_tuple_children!(subcolumns, schema, row_count, budget, 1)
      nil
    rescue ex : TypeCastError | OverflowError
      raise CorruptPartError.new("recursive Tuple serializer metadata is malformed")
    end

    private def self.validate_storage_tuple_children!(
      subcolumns : Array(JSON::Any),
      schema : StorageColumnSchema,
      row_count : UInt64,
      budget : BinaryCodecBudget,
      parent_depth : Int32,
    ) : Nil
      arity = schema.child_count
      unless subcolumns.size == arity
        raise UnsupportedFormatError.new("recursive Tuple serializer count differs from the selected schema")
      end
      budget.preflight_children(arity.to_u64)

      arity.times do |index|
        validate_storage_node!(
          subcolumns[index],
          schema.child_at(index),
          row_count,
          budget,
          parent_depth + 1,
        )
      end
      nil
    end

    private def self.validate_storage_node!(
      value : JSON::Any,
      schema : StorageColumnSchema,
      row_count : UInt64,
      budget : BinaryCodecBudget,
      depth : Int32,
    ) : Nil
      budget.visit_node(depth)
      if schema.tuple?
        children = validate_record!(value, row_count, true)
        validate_storage_tuple_children!(children, schema, row_count, budget, depth)
      elsif schema.bulk? && tuple_type?(schema.bulk_type)
        validate_bulk_tuple_node!(value, schema.bulk_type, row_count, budget, depth)
      else
        validate_record!(value, row_count, false)
      end
      nil
    end

    private def self.validate_bulk_tuple_node!(
      value : JSON::Any,
      type : BinaryDataType,
      row_count : UInt64,
      budget : BinaryCodecBudget,
      depth : Int32,
    ) : Nil
      children = validate_record!(value, row_count, true)
      validate_bulk_tuple_children!(children, type, row_count, budget, depth)
      nil
    end

    private def self.validate_bulk_tuple_children!(
      subcolumns : Array(JSON::Any),
      type : BinaryDataType,
      row_count : UInt64,
      budget : BinaryCodecBudget,
      parent_depth : Int32,
    ) : Nil
      arity = type.child_count
      unless subcolumns.size == arity
        raise UnsupportedFormatError.new("recursive BinaryBulk Tuple serializer count differs from its descriptor")
      end
      budget.preflight_children(arity.to_u64)

      arity.times do |index|
        child_type = type.child_at(index)
        child_depth = parent_depth + 1
        budget.visit_node(child_depth)
        if tuple_type?(child_type)
          nested = validate_record!(subcolumns[index], row_count, true)
          validate_bulk_tuple_children!(nested, child_type, row_count, budget, child_depth)
        else
          validate_record!(subcolumns[index], row_count, false)
        end
      end
      nil
    end

    private def self.validate_record!(
      value : JSON::Any,
      row_count : UInt64,
      tuple : Bool,
    ) : Array(JSON::Any)
      entry = value.as_h
      fields = Set{"kind", "num_defaults", "num_rows"}
      fields << "subcolumns" if tuple
      extended_fields = fields.dup
      extended_fields << "exact_num_defaults"
      unless entry.keys.to_set == fields || entry.keys.to_set == extended_fields
        raise UnsupportedFormatError.new("unsupported recursive Tuple serializer fields")
      end

      kind = entry["kind"]?.try(&.as_s) ||
             raise(CorruptPartError.new("recursive Tuple serializer kind is missing or malformed"))
      unless kind == "Default"
        raise UnsupportedFormatError.new("only Default recursive Tuple serializers are supported")
      end
      defaults = entry["num_defaults"]?.try(&.as_i) ||
                 raise(CorruptPartError.new("recursive Tuple default count is missing or malformed"))
      rows = entry["num_rows"]?.try(&.as_i) ||
             raise(CorruptPartError.new("recursive Tuple row count is missing or malformed"))
      unless defaults >= 0 && rows >= 0 && defaults <= rows &&
             rows.to_u64 <= WidePart::MAX_ROWS && rows.to_u64 == row_count
        raise CorruptPartError.new("recursive Tuple serializer counts do not match the parent row domain")
      end
      if exact = entry["exact_num_defaults"]?
        exact.as_bool
      end

      if tuple
        entry["subcolumns"]?.try(&.as_a) ||
          raise(CorruptPartError.new("recursive Tuple child metadata is missing or malformed"))
      else
        [] of JSON::Any
      end
    end

    private def self.tuple_type?(type : BinaryDataType) : Bool
      type.tag == BinaryDataType::TAG_NAMED_TUPLE || type.tag == BinaryDataType::TAG_UNNAMED_TUPLE
    end
  end
end
