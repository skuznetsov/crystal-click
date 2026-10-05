module CrystalClick
  # Narrow invariants for the nominal Nested shape shared by descriptor,
  # logical-value and ordinary bulk consumers. Nested's implicit Tuple is
  # visible in the recursive child graph but is not a wire-level Tuple tag.
  module BinaryNestedType
    def self.tuple_for(type : BinaryDataType) : BinaryDataType
      unless type.tag == BinaryDataType::TAG_NESTED && type.child_count == 1
        raise ArgumentError.new("Nested descriptor must contain exactly one implicit Tuple")
      end
      tuple = type.child_at(0)
      unless tuple.tag == BinaryDataType::TAG_NAMED_TUPLE && tuple.child_count > 0
        raise ArgumentError.new("Nested descriptor must contain a non-empty named Tuple")
      end
      tuple
    end

    # Specialized LC/Variant/Dynamic walkers do not yet own Nested's shared
    # sibling-row cardinality. Reject the whole mixed product before any role,
    # site or path roster is materialized.
    def self.reject_unqualified_specialized_bulk!(type : BinaryDataType) : Nil
      return unless type.contains_nested?

      if type.contains_low_cardinality?
        raise UnsupportedFormatError.new("Nested with LowCardinality is outside the admitted bulk profile")
      end
      if type.contains_variant?
        raise UnsupportedFormatError.new("Nested with Variant is outside the admitted bulk profile")
      end
      if type.contains_dynamic?
        raise UnsupportedFormatError.new("Nested with Dynamic is outside the admitted bulk profile")
      end
    end
  end
end
