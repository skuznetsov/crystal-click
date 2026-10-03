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

    # The descriptor caches this immutable composition fact at construction.
    # Guards may query it before a bounded descriptor traversal, including for
    # manually supplied Object schemas with no materialized row values.
    def self.contains_low_cardinality?(type : BinaryDataType) : Bool
      type.contains_low_cardinality?
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
