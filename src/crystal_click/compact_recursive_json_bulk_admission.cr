module CrystalClick
  # Adds the one stateful subtree owned by the recursive JSON-free Bulk
  # visitor without changing the shared prefix-free admission contract.
  module CompactRecursiveJsonBulkAdmission
    def self.admitted?(type : BinaryDataType, depth : Int32, limits : BinaryCodecLimits) : Bool
      return false if depth <= 0 || depth > limits.max_depth
      return BinaryPrefixFreeStaticTypeAdmission.admitted?(type, depth, limits) unless type.contains_low_cardinality?

      case type.tag
      when BinaryDataType::TAG_LOW_CARDINALITY
        type.child_count == 1 &&
          BinaryLowCardinalityTypePolicy.admitted_child?(type.child_at(0)) &&
          BinaryPrefixFreeStaticTypeAdmission.admitted?(type.child_at(0), depth + 1, limits)
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED
        type.child_count == 1 && admitted?(type.child_at(0), depth + 1, limits)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        type.child_count.times.all? { |index| admitted?(type.child_at(index), depth + 1, limits) }
      when BinaryDataType::TAG_MAP
        type.child_count == 2 &&
          admitted?(type.child_at(0), depth + 1, limits) &&
          admitted?(type.child_at(1), depth + 1, limits)
      when BinaryDataType::TAG_NULLABLE
        # Nullable(LC(...)) and structural Nullable wrappers are not in this
        # slice. LC(Nullable(scalar)) is admitted by the LC branch above.
        false
      else
        false
      end
    rescue ex : ArgumentError | UnsupportedFormatError
      false
    end
  end
end
