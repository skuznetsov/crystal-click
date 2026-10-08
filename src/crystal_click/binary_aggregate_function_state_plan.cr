module CrystalClick
  # Immutable fixed-state layout for a root Sum-family AggregateFunction.
  # This is deliberately separate from BinaryDataType#fixed_width and from
  # ordinary scalar result validation: Bool/Enum states are raw accumulator
  # bytes, and nullable presence is aggregate-state framing rather than NULL.
  class BinaryAggregateFunctionStatePlan
    getter type : BinaryDataType
    getter descriptor : BinaryAggregateFunctionType
    getter function_name : String
    getter argument_type : BinaryDataType
    getter input_type : BinaryDataType
    getter state_width : Int32
    getter? nullable_argument : Bool

    def initialize(@type : BinaryDataType)
      unless @type.tag == BinaryDataType::TAG_AGGREGATE_FUNCTION
        raise ArgumentError.new("aggregate state plan requires an AggregateFunction type")
      end
      @descriptor = @type.aggregate_function_type || raise ArgumentError.new("AggregateFunction metadata is missing")
      if @descriptor.function_name == "count"
        raise ArgumentError.new("Count state is owned by its compatibility codec")
      end
      @function_name = @descriptor.function_name
      @argument_type = @descriptor.argument_type || raise ArgumentError.new("Sum-family AggregateFunction requires an argument")
      BinaryAggregateFunctionAdmission.validate_argument!(@argument_type)

      dispatched = @argument_type
      dispatched = dispatched.child_at(0) if dispatched.tag == BinaryDataType::TAG_LOW_CARDINALITY
      @nullable_argument = dispatched.tag == BinaryDataType::TAG_NULLABLE
      @input_type = @nullable_argument ? dispatched.child_at(0) : dispatched
      @state_width = state_width_for(@function_name, @input_type)
    end

    def self.for_type(type : BinaryDataType) : BinaryAggregateFunctionStatePlan
      new(type)
    end

    def minimum_state_bytes : Int32
      @nullable_argument ? 1 : @state_width
    end

    def default_state_bytes : Bytes
      if @nullable_argument
        Bytes[0_u8]
      else
        Bytes.new(@state_width, 0_u8)
      end
    end

    def validate_state_bytes(bytes : Bytes) : Nil
      if @nullable_argument
        if bytes.size == 1 && bytes[0] == 0_u8
          return nil
        end
        unless bytes.size == @state_width + 1 && bytes[0] == 1_u8
          raise ArgumentError.new("AggregateFunction nullable state has invalid presence or width")
        end
      elsif bytes.size != @state_width
        raise ArgumentError.new("AggregateFunction state width does not match its descriptor")
      end
      nil
    end

    private def state_width_for(function_name : String, input_type : BinaryDataType) : Int32
      case function_name
      when "sumKahan"
        16
      when "sumWithOverflow"
        input_type.fixed_width || raise ArgumentError.new("AggregateFunction overflow input has no fixed width")
      when "sum"
        case input_type.tag
        when BinaryDataType::TAG_UINT8, BinaryDataType::TAG_UINT16, BinaryDataType::TAG_UINT32,
             BinaryDataType::TAG_INT8, BinaryDataType::TAG_INT16, BinaryDataType::TAG_INT32,
             BinaryDataType::TAG_FLOAT32, BinaryDataType::TAG_BFLOAT16, BinaryDataType::TAG_BOOL,
             BinaryDataType::TAG_ENUM8, BinaryDataType::TAG_ENUM16
          8
        when BinaryDataType::TAG_UINT64, BinaryDataType::TAG_INT64, BinaryDataType::TAG_FLOAT64,
             BinaryDataType::TAG_INTERVAL
          8
        when BinaryDataType::TAG_UINT128, BinaryDataType::TAG_INT128,
             BinaryDataType::TAG_DECIMAL32, BinaryDataType::TAG_DECIMAL64, BinaryDataType::TAG_DECIMAL128
          16
        when BinaryDataType::TAG_UINT256, BinaryDataType::TAG_INT256, BinaryDataType::TAG_DECIMAL256
          32
        else
          raise ArgumentError.new("AggregateFunction Sum input has no admitted state width")
        end
      else
        raise ArgumentError.new("AggregateFunction function has no state layout")
      end
    end
  end
end
