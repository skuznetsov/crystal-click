module CrystalClick
  # Source-backed logical admission for the immutable AggregateFunction
  # families currently carried by the binary state codec. This is descriptor
  # admission only; physical consumers apply their own root-column policy.
  class BinaryAggregateFunctionAdmission
    MAX_FUNCTION_NAME_BYTES = "sumWithOverflow".bytesize

    def self.canonical_function_name(function_name : String, argument_type : BinaryDataType) : String
      if function_name == "min" || function_name == "max"
        validate_argument!(argument_type, function_name)
        return function_name
      end

      if function_name == "avg"
        validate_argument!(argument_type, "avg")
        return "avg"
      end

      unless function_name == "sum" || function_name == "sumWithOverflow" || function_name == "sumKahan"
        raise ArgumentError.new("AggregateFunction is outside the admitted Sum-family profile")
      end

      input_type = dispatched_input_type(argument_type)
      case input_type.tag
      when BinaryDataType::TAG_UINT8, BinaryDataType::TAG_UINT16,
           BinaryDataType::TAG_UINT32, BinaryDataType::TAG_UINT64,
           BinaryDataType::TAG_UINT128, BinaryDataType::TAG_UINT256,
           BinaryDataType::TAG_INT8, BinaryDataType::TAG_INT16,
           BinaryDataType::TAG_INT32, BinaryDataType::TAG_INT64,
           BinaryDataType::TAG_INT128, BinaryDataType::TAG_INT256,
           BinaryDataType::TAG_FLOAT32, BinaryDataType::TAG_FLOAT64,
           BinaryDataType::TAG_BFLOAT16, BinaryDataType::TAG_BOOL,
           BinaryDataType::TAG_ENUM8, BinaryDataType::TAG_ENUM16
        function_name
      when BinaryDataType::TAG_DECIMAL32, BinaryDataType::TAG_DECIMAL64,
           BinaryDataType::TAG_DECIMAL128, BinaryDataType::TAG_DECIMAL256,
           BinaryDataType::TAG_INTERVAL
        function_name == "sumKahan" ? "sum" : function_name
      else
        raise ArgumentError.new("AggregateFunction Sum argument is outside the admitted numeric profile")
      end
    end

    def self.require!(function_name : String, argument_type : BinaryDataType, version : UInt8) : String
      unless version == 0_u8
        raise ArgumentError.new("AggregateFunction version is outside the admitted profile")
      end
      if function_name == "min" || function_name == "max"
        validate_argument!(argument_type, function_name)
        return function_name
      end
      validate_argument!(argument_type, function_name == "avg" ? "avg" : "sum")
      canonical_function_name(function_name, argument_type)
    end

    def self.validate_argument!(argument_type : BinaryDataType, function_name : String = "sum") : Nil
      if function_name == "min" || function_name == "max"
        BinaryAggregateMinMaxArgumentPolicy.require!(argument_type)
        return nil
      end

      if function_name == "avg"
        validate_avg_argument!(argument_type)
        return nil
      end

      current = argument_type
      low_cardinality = false

      if current.tag == BinaryDataType::TAG_LOW_CARDINALITY
        low_cardinality = true
        current = current.child_at(0)
      end

      if current.tag == BinaryDataType::TAG_NULLABLE
        current = current.child_at(0)
      end

      # The only supported LC spelling is LC(T) or LC(Nullable(T)); in
      # particular Nullable(LC(T)), nested wrappers, and repeated shells are
      # not inferred from the display name.
      unless current.tag != BinaryDataType::TAG_LOW_CARDINALITY &&
             current.tag != BinaryDataType::TAG_NULLABLE &&
             current.tag != BinaryDataType::TAG_AGGREGATE_FUNCTION
        raise ArgumentError.new("AggregateFunction argument wrappers are outside the admitted profile")
      end

      admitted_leaf = case current.tag
                      when BinaryDataType::TAG_UINT8, BinaryDataType::TAG_UINT16,
                           BinaryDataType::TAG_UINT32, BinaryDataType::TAG_UINT64,
                           BinaryDataType::TAG_UINT128, BinaryDataType::TAG_UINT256,
                           BinaryDataType::TAG_INT8, BinaryDataType::TAG_INT16,
                           BinaryDataType::TAG_INT32, BinaryDataType::TAG_INT64,
                           BinaryDataType::TAG_INT128, BinaryDataType::TAG_INT256,
                           BinaryDataType::TAG_FLOAT32, BinaryDataType::TAG_FLOAT64,
                           BinaryDataType::TAG_BFLOAT16, BinaryDataType::TAG_BOOL,
                           BinaryDataType::TAG_ENUM8, BinaryDataType::TAG_ENUM16,
                           BinaryDataType::TAG_DECIMAL32, BinaryDataType::TAG_DECIMAL64,
                           BinaryDataType::TAG_DECIMAL128, BinaryDataType::TAG_DECIMAL256,
                           BinaryDataType::TAG_INTERVAL
                        true
                      else
                        false
                      end
      unless admitted_leaf
        raise ArgumentError.new("AggregateFunction Sum argument is outside the admitted numeric profile")
      end

      if current.tag == BinaryDataType::TAG_DECIMAL32 || current.tag == BinaryDataType::TAG_DECIMAL64 ||
         current.tag == BinaryDataType::TAG_DECIMAL128 || current.tag == BinaryDataType::TAG_DECIMAL256
        decimal = current.decimal_type || raise ArgumentError.new("AggregateFunction Decimal argument metadata is missing")
        canonical_width = case decimal.precision
                          when 1..9   then 32
                          when 10..18 then 64
                          when 19..38 then 128
                          else             256
                          end
        unless decimal.width_bits == canonical_width && decimal.scale <= decimal.precision
          raise ArgumentError.new("AggregateFunction Decimal argument is not canonical for its SQL name")
        end
      end

      if low_cardinality
        lc_eligible = case current.tag
                      when BinaryDataType::TAG_UINT8, BinaryDataType::TAG_UINT16,
                           BinaryDataType::TAG_UINT32, BinaryDataType::TAG_UINT64,
                           BinaryDataType::TAG_UINT128, BinaryDataType::TAG_UINT256,
                           BinaryDataType::TAG_INT8, BinaryDataType::TAG_INT16,
                           BinaryDataType::TAG_INT32, BinaryDataType::TAG_INT64,
                           BinaryDataType::TAG_INT128, BinaryDataType::TAG_INT256,
                           BinaryDataType::TAG_FLOAT32, BinaryDataType::TAG_FLOAT64,
                           BinaryDataType::TAG_BFLOAT16, BinaryDataType::TAG_BOOL,
                           BinaryDataType::TAG_INTERVAL
                        true
                      else
                        false
                      end
        unless lc_eligible
          raise ArgumentError.new("AggregateFunction argument type is not LowCardinality-eligible")
        end
      end

      nil
    end

    private def self.validate_avg_argument!(argument_type : BinaryDataType) : Nil
      current = argument_type
      low_cardinality = false

      if current.tag == BinaryDataType::TAG_LOW_CARDINALITY
        low_cardinality = true
        current = current.child_at(0)
      end
      current = current.child_at(0) if current.tag == BinaryDataType::TAG_NULLABLE

      # Only bare T, Nullable(T), LC(T), and LC(Nullable(T)) are admitted.
      # Parsing these shells structurally also rejects repeated or reversed
      # wrappers instead of guessing from the rendered type name.
      unless current.tag != BinaryDataType::TAG_LOW_CARDINALITY &&
             current.tag != BinaryDataType::TAG_NULLABLE &&
             current.tag != BinaryDataType::TAG_AGGREGATE_FUNCTION
        raise ArgumentError.new("AggregateFunction avg argument wrappers are outside the admitted profile")
      end

      admitted_leaf = case current.tag
                      when BinaryDataType::TAG_UINT8, BinaryDataType::TAG_UINT16,
                           BinaryDataType::TAG_UINT32, BinaryDataType::TAG_UINT64,
                           BinaryDataType::TAG_UINT128, BinaryDataType::TAG_UINT256,
                           BinaryDataType::TAG_INT8, BinaryDataType::TAG_INT16,
                           BinaryDataType::TAG_INT32, BinaryDataType::TAG_INT64,
                           BinaryDataType::TAG_INT128, BinaryDataType::TAG_INT256,
                           BinaryDataType::TAG_FLOAT32, BinaryDataType::TAG_FLOAT64,
                           BinaryDataType::TAG_BFLOAT16, BinaryDataType::TAG_BOOL,
                           BinaryDataType::TAG_DECIMAL32, BinaryDataType::TAG_DECIMAL64,
                           BinaryDataType::TAG_DECIMAL128, BinaryDataType::TAG_DECIMAL256,
                           BinaryDataType::TAG_DATE, BinaryDataType::TAG_DATE32,
                           BinaryDataType::TAG_DATETIME, BinaryDataType::TAG_DATETIME_ZONE,
                           BinaryDataType::TAG_DATETIME64, BinaryDataType::TAG_DATETIME64_ZONE,
                           BinaryDataType::TAG_TIME, BinaryDataType::TAG_TIME64,
                           BinaryDataType::TAG_INTERVAL
                        true
                      else
                        false
                      end
      unless admitted_leaf
        raise ArgumentError.new("AggregateFunction avg argument is outside the admitted numeric, Decimal, temporal, and Interval profile")
      end

      if current.tag == BinaryDataType::TAG_DECIMAL32 || current.tag == BinaryDataType::TAG_DECIMAL64 ||
         current.tag == BinaryDataType::TAG_DECIMAL128 || current.tag == BinaryDataType::TAG_DECIMAL256
        decimal = current.decimal_type || raise ArgumentError.new("AggregateFunction Decimal argument metadata is missing")
        canonical_width = case decimal.precision
                          when 1..9   then 32
                          when 10..18 then 64
                          when 19..38 then 128
                          else             256
                          end
        unless decimal.width_bits == canonical_width && decimal.scale <= decimal.precision
          raise ArgumentError.new("AggregateFunction Decimal argument is not canonical for its SQL name")
        end
      end

      if low_cardinality
        lc_eligible = case current.tag
                      when BinaryDataType::TAG_UINT8, BinaryDataType::TAG_UINT16,
                           BinaryDataType::TAG_UINT32, BinaryDataType::TAG_UINT64,
                           BinaryDataType::TAG_UINT128, BinaryDataType::TAG_UINT256,
                           BinaryDataType::TAG_INT8, BinaryDataType::TAG_INT16,
                           BinaryDataType::TAG_INT32, BinaryDataType::TAG_INT64,
                           BinaryDataType::TAG_INT128, BinaryDataType::TAG_INT256,
                           BinaryDataType::TAG_FLOAT32, BinaryDataType::TAG_FLOAT64,
                           BinaryDataType::TAG_BFLOAT16, BinaryDataType::TAG_BOOL,
                           BinaryDataType::TAG_DATE, BinaryDataType::TAG_DATE32,
                           BinaryDataType::TAG_DATETIME, BinaryDataType::TAG_DATETIME_ZONE,
                           BinaryDataType::TAG_TIME, BinaryDataType::TAG_INTERVAL
                        true
                      else
                        false
                      end
        unless lc_eligible
          raise ArgumentError.new("AggregateFunction avg argument type is not LowCardinality-eligible")
        end
      end

      nil
    end

    # Remove only dispatch wrappers. The nominal argument descriptor itself is
    # retained by BinaryAggregateFunctionType for exact equality and metadata.
    def self.dispatched_input_type(argument_type : BinaryDataType) : BinaryDataType
      current = argument_type
      current = current.child_at(0) if current.tag == BinaryDataType::TAG_LOW_CARDINALITY
      current = current.child_at(0) if current.tag == BinaryDataType::TAG_NULLABLE
      current
    end
  end
end
