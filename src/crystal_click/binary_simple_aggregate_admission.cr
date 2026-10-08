module CrystalClick
  # Logical result/storage admission for SimpleAggregateFunction. This is a
  # conservative source-qualified policy, not a physical Bulk profile. Child
  # codecs remain the sole owners of recursive storage serialization.
  module BinarySimpleAggregateAdmission
    MAX_STORAGE_DEPTH =    64
    MAX_STORAGE_NODES = 4_096

    def self.admitted?(
      function : BinarySimpleAggregateType::Function,
      storage_type : BinaryDataType,
      parameters : BinarySimpleAggregateParameters = BinarySimpleAggregateParameters.empty,
    ) : Bool
      return false unless bounded_tree?(storage_type)
      return false unless parameter_count_allowed?(function, parameters.count.to_u64)

      case function
      when BinarySimpleAggregateType::Function::Any
        legacy_leaf?(function, storage_type) || identity_storage?(storage_type, allow_direct_low_cardinality: true)
      when BinarySimpleAggregateType::Function::AnyLast,
           BinarySimpleAggregateType::Function::AnyRespectNulls,
           BinarySimpleAggregateType::Function::AnyLastRespectNulls
        legacy_leaf?(function, storage_type) || identity_storage?(storage_type)
      when BinarySimpleAggregateType::Function::Min,
           BinarySimpleAggregateType::Function::Max
        legacy_leaf?(function, storage_type) || comparable_storage?(storage_type)
      when BinarySimpleAggregateType::Function::Sum,
           BinarySimpleAggregateType::Function::SumWithOverflow,
           BinarySimpleAggregateType::Function::GroupBitAnd,
           BinarySimpleAggregateType::Function::GroupBitOr,
           BinarySimpleAggregateType::Function::GroupBitXor
        legacy_leaf?(function, storage_type)
      when BinarySimpleAggregateType::Function::SumMap
        mapped_sum_storage?(storage_type)
      when BinarySimpleAggregateType::Function::MinMap,
           BinarySimpleAggregateType::Function::MaxMap
        mapped_extrema_storage?(storage_type)
      when BinarySimpleAggregateType::Function::GroupArrayArray,
           BinarySimpleAggregateType::Function::GroupUniqArrayArray
        array_aggregate_storage?(storage_type)
      when BinarySimpleAggregateType::Function::GroupArrayLastArray
        array_aggregate_storage?(storage_type)
      when BinarySimpleAggregateType::Function::GroupUniqArrayArrayMap
        map_array_aggregate_storage?(storage_type)
      when BinarySimpleAggregateType::Function::TimeSeriesGroupArray
        time_series_storage?(storage_type)
      else
        false
      end
    rescue ex : ArgumentError | UnsupportedFormatError
      false
    end

    # The Field arity is a function property, independent of storage admission.
    # The wire decoder uses this before reserving metadata or reading Field
    # payloads so a forbidden count cannot be misreported as truncated input.
    def self.parameter_count_allowed?(
      function : BinarySimpleAggregateType::Function,
      count : UInt64,
    ) : Bool
      case function
      when BinarySimpleAggregateType::Function::GroupArrayLastArray
        count == 1_u64
      when BinarySimpleAggregateType::Function::GroupArrayArray,
           BinarySimpleAggregateType::Function::GroupUniqArrayArray,
           BinarySimpleAggregateType::Function::GroupUniqArrayArrayMap
        count <= 1_u64
      else
        count == 0_u64
      end
    end

    # ClickHouse's Nullable wrapper asks the direct storage DataType whether
    # it can be nested under Nullable. In the source-qualified recursive
    # profile Tuple can; Array/Map/Nested and the dynamic/custom wrappers do
    # not. Unknown nominal/custom types fail closed.
    def self.outer_nullable_eligible?(storage_type : BinaryDataType) : Bool
      case storage_type.tag
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED,
           BinaryDataType::TAG_MAP, BinaryDataType::TAG_NULLABLE,
           BinaryDataType::TAG_LOW_CARDINALITY, BinaryDataType::TAG_VARIANT,
           BinaryDataType::TAG_DYNAMIC, BinaryDataType::TAG_JSON,
           BinaryDataType::TAG_QBIT, BinaryDataType::TAG_AGGREGATE_COUNT,
           BinaryDataType::TAG_SIMPLE_AGGREGATE, BinaryDataType::TAG_NOTHING
        false
      else
        true
      end
    end

    private def self.legacy_leaf?(
      function : BinarySimpleAggregateType::Function,
      storage_type : BinaryDataType,
    ) : Bool
      leaf = storage_type
      if leaf.tag == BinaryDataType::TAG_NULLABLE
        return false if leaf.child_count != 1 || leaf.child_at(0).tag == BinaryDataType::TAG_NULLABLE
        leaf = leaf.child_at(0)
      end
      return false unless legacy_scalar_tag?(leaf.tag) && canonical_leaf_metadata?(leaf)
      BinarySimpleAggregateType.admitted_function_storage?(function, storage_type.name)
    end

    private def self.legacy_scalar_tag?(tag : UInt8) : Bool
      case tag
      when BinaryDataType::TAG_UINT8, BinaryDataType::TAG_UINT16,
           BinaryDataType::TAG_UINT32, BinaryDataType::TAG_UINT64,
           BinaryDataType::TAG_UINT128, BinaryDataType::TAG_UINT256,
           BinaryDataType::TAG_INT8, BinaryDataType::TAG_INT16,
           BinaryDataType::TAG_INT32, BinaryDataType::TAG_INT64,
           BinaryDataType::TAG_INT128, BinaryDataType::TAG_INT256,
           BinaryDataType::TAG_FLOAT32, BinaryDataType::TAG_FLOAT64,
           BinaryDataType::TAG_BFLOAT16, BinaryDataType::TAG_STRING,
           BinaryDataType::TAG_FIXED_STRING, BinaryDataType::TAG_DATE,
           BinaryDataType::TAG_DATE32, BinaryDataType::TAG_DATETIME,
           BinaryDataType::TAG_DATETIME_ZONE, BinaryDataType::TAG_DATETIME64,
           BinaryDataType::TAG_DATETIME64_ZONE, BinaryDataType::TAG_TIME,
           BinaryDataType::TAG_TIME64, BinaryDataType::TAG_DECIMAL32,
           BinaryDataType::TAG_DECIMAL64, BinaryDataType::TAG_DECIMAL128,
           BinaryDataType::TAG_DECIMAL256
        true
      else
        false
      end
    end

    private def self.identity_storage?(type : BinaryDataType, allow_direct_low_cardinality : Bool = false) : Bool
      if allow_direct_low_cardinality && type.tag == BinaryDataType::TAG_LOW_CARDINALITY
        return type.child_count == 1 && type.child_at(0).tag == BinaryDataType::TAG_STRING
      end

      case type.tag
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NULLABLE
        identity_storage?(type.child_at(0))
      when BinaryDataType::TAG_MAP
        identity_storage?(type.child_at(0)) && identity_storage?(type.child_at(1))
      when BinaryDataType::TAG_NAMED_TUPLE, BinaryDataType::TAG_UNNAMED_TUPLE
        type.child_count.times.all? { |index| identity_storage?(type.child_at(index)) }
      when BinaryDataType::TAG_LOW_CARDINALITY, BinaryDataType::TAG_NESTED,
           BinaryDataType::TAG_VARIANT, BinaryDataType::TAG_DYNAMIC,
           BinaryDataType::TAG_JSON, BinaryDataType::TAG_QBIT,
           BinaryDataType::TAG_AGGREGATE_COUNT, BinaryDataType::TAG_SIMPLE_AGGREGATE,
           BinaryDataType::TAG_NOTHING, BinaryDataType::TAG_BOOL,
           BinaryDataType::TAG_INTERVAL
        false
      else
        ordinary_leaf?(type)
      end
    end

    private def self.comparable_storage?(type : BinaryDataType) : Bool
      case type.tag
      when BinaryDataType::TAG_ARRAY
        comparable_storage?(type.child_at(0))
      when BinaryDataType::TAG_MAP
        map_key?(type.child_at(0)) && comparable_storage?(type.child_at(1))
      when BinaryDataType::TAG_NAMED_TUPLE, BinaryDataType::TAG_UNNAMED_TUPLE
        type.child_count.times.all? { |index| comparable_storage?(type.child_at(index)) }
      when BinaryDataType::TAG_LOW_CARDINALITY, BinaryDataType::TAG_NULLABLE,
           BinaryDataType::TAG_NESTED, BinaryDataType::TAG_VARIANT,
           BinaryDataType::TAG_DYNAMIC, BinaryDataType::TAG_JSON,
           BinaryDataType::TAG_QBIT, BinaryDataType::TAG_AGGREGATE_COUNT,
           BinaryDataType::TAG_SIMPLE_AGGREGATE, BinaryDataType::TAG_NOTHING,
           BinaryDataType::TAG_BOOL, BinaryDataType::TAG_INTERVAL
        false
      else
        ordinary_leaf?(type)
      end
    end

    private def self.ordinary_leaf?(type : BinaryDataType) : Bool
      case type.tag
      when BinaryDataType::TAG_UINT8, BinaryDataType::TAG_UINT16,
           BinaryDataType::TAG_UINT32, BinaryDataType::TAG_UINT64,
           BinaryDataType::TAG_UINT128, BinaryDataType::TAG_UINT256,
           BinaryDataType::TAG_INT8, BinaryDataType::TAG_INT16,
           BinaryDataType::TAG_INT32, BinaryDataType::TAG_INT64,
           BinaryDataType::TAG_INT128, BinaryDataType::TAG_INT256,
           BinaryDataType::TAG_FLOAT32, BinaryDataType::TAG_FLOAT64,
           BinaryDataType::TAG_BFLOAT16, BinaryDataType::TAG_DATE,
           BinaryDataType::TAG_DATE32, BinaryDataType::TAG_DATETIME,
           BinaryDataType::TAG_DATETIME_ZONE, BinaryDataType::TAG_DATETIME64,
           BinaryDataType::TAG_DATETIME64_ZONE, BinaryDataType::TAG_TIME,
           BinaryDataType::TAG_TIME64, BinaryDataType::TAG_STRING,
           BinaryDataType::TAG_FIXED_STRING, BinaryDataType::TAG_ENUM8,
           BinaryDataType::TAG_ENUM16, BinaryDataType::TAG_DECIMAL32,
           BinaryDataType::TAG_DECIMAL64, BinaryDataType::TAG_DECIMAL128,
           BinaryDataType::TAG_DECIMAL256, BinaryDataType::TAG_UUID,
           BinaryDataType::TAG_IPV4, BinaryDataType::TAG_IPV6
        canonical_leaf_metadata?(type)
      else
        false
      end
    end

    # A BinaryDataType can intentionally retain wire-valid Decimal coordinates
    # that do not correspond to a valid/canonical SQL Decimal leaf. Recursive
    # SAF admission must preserve the old width/precision/scale and fixed-string
    # limits without rendering and reparsing the immutable child tree.
    private def self.canonical_leaf_metadata?(type : BinaryDataType) : Bool
      case type.tag
      when BinaryDataType::TAG_DECIMAL32, BinaryDataType::TAG_DECIMAL64,
           BinaryDataType::TAG_DECIMAL128, BinaryDataType::TAG_DECIMAL256
        decimal = type.decimal_type || return false
        return false if decimal.scale > decimal.precision
        expected_width_bits = if decimal.precision <= 9
                                32
                              elsif decimal.precision <= 18
                                64
                              elsif decimal.precision <= 38
                                128
                              else
                                256
                              end
        decimal.width_bits == expected_width_bits
      when BinaryDataType::TAG_FIXED_STRING
        width = type.fixed_size || return false
        width > 0 && width <= BinarySimpleAggregateType::MAX_FIXED_STRING_WIDTH
      else
        true
      end
    end

    private def self.map_key?(type : BinaryDataType) : Bool
      admitted_tag = case type.tag
                     when BinaryDataType::TAG_UINT8, BinaryDataType::TAG_UINT16,
                          BinaryDataType::TAG_UINT32, BinaryDataType::TAG_UINT64,
                          BinaryDataType::TAG_UINT128, BinaryDataType::TAG_UINT256,
                          BinaryDataType::TAG_INT8, BinaryDataType::TAG_INT16,
                          BinaryDataType::TAG_INT32, BinaryDataType::TAG_INT64,
                          BinaryDataType::TAG_INT128, BinaryDataType::TAG_INT256,
                          BinaryDataType::TAG_DATE, BinaryDataType::TAG_DATETIME,
                          BinaryDataType::TAG_DATETIME_ZONE, BinaryDataType::TAG_STRING,
                          BinaryDataType::TAG_FIXED_STRING, BinaryDataType::TAG_UUID,
                          BinaryDataType::TAG_IPV4, BinaryDataType::TAG_IPV6,
                          BinaryDataType::TAG_ENUM8, BinaryDataType::TAG_ENUM16
                       true
                     else
                       false
                     end
      admitted_tag && canonical_leaf_metadata?(type)
    end

    private def self.mapped_sum_storage?(type : BinaryDataType) : Bool
      if type.tag == BinaryDataType::TAG_MAP && type.child_count == 2
        return map_key?(type.child_at(0)) && sum_fixed_point_value?(type.child_at(1))
      end

      mapped_arrays?(type) { |value| sum_fixed_point_value?(value) }
    end

    private def self.mapped_extrema_storage?(type : BinaryDataType) : Bool
      if type.tag == BinaryDataType::TAG_MAP && type.child_count == 2
        return map_key?(type.child_at(0)) && comparable_storage?(type.child_at(1))
      end

      mapped_arrays?(type) { |value| comparable_storage?(value) }
    end

    private def self.mapped_arrays?(type : BinaryDataType, &block : BinaryDataType -> Bool) : Bool
      # ClickHouse's sumMap/minMap/maxMap aggregate state uses a Tuple as a
      # positional carrier and returns an unnamed Tuple. Named Tuple equality
      # includes field names, so accepting one here would claim a result type
      # that the factory does not produce. Other identity-result aggregates
      # retain their independent named-Tuple admission law.
      unless type.tag == BinaryDataType::TAG_UNNAMED_TUPLE
        return false
      end
      return false if type.child_count < 2

      type.child_count.times do |index|
        array = type.child_at(index)
        return false unless array.tag == BinaryDataType::TAG_ARRAY && array.child_count == 1
        value = array.child_at(0)
        if index == 0
          return false unless map_key?(value)
        else
          return false unless yield value
        end
      end
      true
    end

    private def self.sum_fixed_point_value?(type : BinaryDataType) : Bool
      return false unless legacy_scalar_tag?(type.tag) && canonical_leaf_metadata?(type)
      BinarySimpleAggregateType.admitted_function_storage?(
        BinarySimpleAggregateType::Function::Sum,
        type.name,
      )
    end

    private def self.array_aggregate_storage?(type : BinaryDataType) : Bool
      return false unless type.tag == BinaryDataType::TAG_ARRAY && type.child_count == 1

      child = type.child_at(0)
      return true if ordinary_leaf?(child)

      # The source-qualified recursive array witness is one nested Array shell
      # over the already admitted leaf family: Array(Array(UInt64)). Keep this
      # explicit rather than recursively admitting arbitrary container trees.
      child.tag == BinaryDataType::TAG_ARRAY && child.child_count == 1 &&
        ordinary_leaf?(child.child_at(0))
    end

    private def self.map_array_aggregate_storage?(type : BinaryDataType) : Bool
      type.tag == BinaryDataType::TAG_MAP && type.child_count == 2 &&
        map_key?(type.child_at(0)) && array_aggregate_storage?(type.child_at(1))
    end

    private def self.time_series_storage?(type : BinaryDataType) : Bool
      return false unless type.tag == BinaryDataType::TAG_ARRAY && type.child_count == 1
      tuple = type.child_at(0)
      return false unless tuple.tag == BinaryDataType::TAG_NAMED_TUPLE || tuple.tag == BinaryDataType::TAG_UNNAMED_TUPLE
      return false unless tuple.child_count == 2

      timestamp = tuple.child_at(0).tag
      value = tuple.child_at(1).tag
      timestamp_ok = timestamp == BinaryDataType::TAG_UINT32 ||
                     timestamp == BinaryDataType::TAG_DATETIME ||
                     timestamp == BinaryDataType::TAG_DATETIME_ZONE ||
                     timestamp == BinaryDataType::TAG_DATETIME64 ||
                     timestamp == BinaryDataType::TAG_DATETIME64_ZONE
      value_ok = value == BinaryDataType::TAG_FLOAT32 || value == BinaryDataType::TAG_FLOAT64
      timestamp_ok && value_ok
    end

    private def self.bounded_tree?(root : BinaryDataType) : Bool
      pending = [{root, 1}] of Tuple(BinaryDataType, Int32)
      visited = 0
      until pending.empty?
        type, depth = pending.pop
        return false if depth > MAX_STORAGE_DEPTH
        visited += 1
        return false if visited > MAX_STORAGE_NODES
        return false if type.child_count > MAX_STORAGE_NODES - visited - pending.size
        type.child_count.times do |index|
          pending << {type.child_at(index), depth + 1}
        end
      end
      true
    end
  end
end
