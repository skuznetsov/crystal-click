module CrystalClick
  # Closed admission for ordinary, prefix-free BinaryBulk value layouts.
  # Stateful and separately-owned layouts (QBit, Variant, LowCardinality,
  # Dynamic, JSON, AggregateFunction) stay with their dedicated visitors.
  module BinaryPrefixFreeStaticTypeAdmission
    def self.admitted?(
      type : BinaryDataType,
      depth : Int32 = 1_i32,
      limits : BinaryCodecLimits = BinaryCodecLimits.default,
    ) : Bool
      return false if depth <= 0 || depth > limits.max_depth

      case type.tag
      when BinaryDataType::TAG_CUSTOM
        return false unless type.child_count == 1
        custom = type.custom_geo_type || return false
        # Geometry's nominal Custom descriptor hides a source-fixed Variant.
        return false if custom.variant_type_id? || type.geometry_storage_variant?
        admitted?(type.child_at(0), depth + 1, limits)
      when BinaryDataType::TAG_SIMPLE_AGGREGATE
        return false unless type.child_count == 1
        aggregate = type.simple_aggregate_type || return false
        BinarySimpleAggregateAdmission.admitted?(
          aggregate.function,
          aggregate.storage_type,
          aggregate.parameters,
        ) && admitted?(type.child_at(0), depth + 1, limits)
      when BinaryDataType::TAG_STRING
        true
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED
        type.child_count == 1 && admitted?(type.child_at(0), depth + 1, limits)
      when BinaryDataType::TAG_NULLABLE
        return false unless type.child_count == 1
        child = type.child_at(0)
        return false if child.contains_qbit? || child.contains_aggregate_function?
        case child.tag
        when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED,
             BinaryDataType::TAG_MAP, BinaryDataType::TAG_NULLABLE,
             BinaryDataType::TAG_LOW_CARDINALITY, BinaryDataType::TAG_VARIANT,
             BinaryDataType::TAG_DYNAMIC, BinaryDataType::TAG_JSON,
             BinaryDataType::TAG_QBIT, BinaryDataType::TAG_AGGREGATE_FUNCTION
          false
        when BinaryDataType::TAG_CUSTOM
          child.custom_geo_type.try(&.nullable_eligible?) == true &&
            admitted?(child, depth + 1, limits)
        when BinaryDataType::TAG_SIMPLE_AGGREGATE
          aggregate = child.simple_aggregate_type || return false
          BinarySimpleAggregateAdmission.outer_nullable_eligible?(aggregate.storage_type) &&
            admitted?(child, depth + 1, limits)
        else
          admitted?(child, depth + 1, limits)
        end
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        type.child_count.times do |index|
          return false unless admitted?(type.child_at(index), depth + 1, limits)
        end
        true
      when BinaryDataType::TAG_MAP
        type.child_count == 2 &&
          admitted?(type.child_at(0), depth + 1, limits) &&
          admitted?(type.child_at(1), depth + 1, limits)
      when BinaryDataType::TAG_NOTHING
        true
      when BinaryDataType::TAG_BOOL
        !type.fixed_width.nil?
      when BinaryDataType::TAG_QBIT, BinaryDataType::TAG_VARIANT,
           BinaryDataType::TAG_LOW_CARDINALITY, BinaryDataType::TAG_DYNAMIC,
           BinaryDataType::TAG_JSON, BinaryDataType::TAG_AGGREGATE_COUNT,
           BinaryDataType::TAG_AGGREGATE_FUNCTION
        false
      else
        # Fixed-width scalar kinds are admitted by their descriptor contract,
        # not by a duplicated primitive-tag whitelist.
        !type.fixed_width.nil?
      end
    rescue ex : ArgumentError | UnsupportedFormatError
      false
    end
  end
end
