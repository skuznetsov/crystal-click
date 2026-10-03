module CrystalClick
  # Source-bounded rules for the LowCardinality wrapper and its nullable
  # interactions. This policy is separate from Object declaration admission
  # and from the physical dictionary/index stream profile.
  module BinaryLowCardinalityTypePolicy
    def self.admitted_child?(type : BinaryDataType) : Bool
      child = if type.tag == BinaryDataType::TAG_NULLABLE
                type.child_at(0)
              else
                type
              end
      admitted_leaf?(child)
    end

    def self.nullable_map_key?(type : BinaryDataType) : Bool
      type.tag == BinaryDataType::TAG_NULLABLE ||
        (type.tag == BinaryDataType::TAG_LOW_CARDINALITY && type.child_at(0).tag == BinaryDataType::TAG_NULLABLE)
    end

    # Call only after the full type tree has passed its bounded descriptor or
    # value-tree traversal. Borrowed persisted-envelope owners use this to
    # retain their narrower admission boundary without another unbounded walk.
    def self.contains_low_cardinality?(type : BinaryDataType) : Bool
      return true if type.tag == BinaryDataType::TAG_LOW_CARDINALITY
      type.child_count.times.any? { |index| contains_low_cardinality?(type.child_at(index)) }
    end

    private def self.admitted_leaf?(type : BinaryDataType) : Bool
      # This is the source constructor's admitted-leaf set intersected with
      # descriptor leaves represented by BinaryDataType. Interval is
      # constructor-eligible upstream but has no tag in this grammar yet.
      tag = type.tag
      (tag >= BinaryDataType::TAG_UINT8 && tag <= BinaryDataType::TAG_FLOAT64) ||
        case tag
        when BinaryDataType::TAG_STRING,
             BinaryDataType::TAG_FIXED_STRING,
             BinaryDataType::TAG_DATE,
             BinaryDataType::TAG_DATE32,
             BinaryDataType::TAG_DATETIME,
             BinaryDataType::TAG_DATETIME_ZONE,
             BinaryDataType::TAG_UUID,
             BinaryDataType::TAG_IPV4,
             BinaryDataType::TAG_IPV6,
             BinaryDataType::TAG_TIME,
             BinaryDataType::TAG_BOOL,
             BinaryDataType::TAG_BFLOAT16
          true
        else
          false
        end
    end
  end
end
