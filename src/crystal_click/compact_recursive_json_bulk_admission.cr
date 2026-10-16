module CrystalClick
  # Adds the existing LowCardinality and Variant state-prefix owners to the
  # recursive JSON-free Bulk visitor without changing shared admission.
  module CompactRecursiveJsonBulkAdmission
    def self.admitted?(type : BinaryDataType, depth : Int32, limits : BinaryCodecLimits) : Bool
      return false if depth <= 0 || depth > limits.max_depth
      unless type.contains_low_cardinality? || type.contains_variant?
        return BinaryPrefixFreeStaticTypeAdmission.admitted?(type, depth, limits)
      end

      case type.tag
      when BinaryDataType::TAG_LOW_CARDINALITY
        if type.child_count != 1
          false
        else
          child = type.child_at(0)
          BinaryLowCardinalityTypePolicy.admitted_child?(child) &&
            admitted?(child, depth + 1, limits)
        end
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
      when BinaryDataType::TAG_VARIANT
        type.child_count > 0 && type.child_count.times.all? do |index|
          arm = type.child_at(index)
          # Match BinaryVariantRoster's direct-arm exclusions while allowing
          # the existing recursively admitted Array/Tuple/Map descendants.
          next false if arm.tag == BinaryDataType::TAG_NOTHING ||
                        arm.tag == BinaryDataType::TAG_DYNAMIC ||
                        arm.tag == BinaryDataType::TAG_NULLABLE ||
                        arm.tag == BinaryDataType::TAG_VARIANT
          next false if arm.tag == BinaryDataType::TAG_LOW_CARDINALITY &&
                        arm.child_count == 1 && arm.child_at(0).tag == BinaryDataType::TAG_NULLABLE
          next false if arm.contains_qbit? && !BinaryDataType.admitted_qbit_static_composition?(arm)
          admitted?(arm, depth + 1, limits)
        end
      else
        false
      end
    rescue ex : ArgumentError | UnsupportedFormatError
      false
    end
  end
end
