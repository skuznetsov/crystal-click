module CrystalClick
  # Immutable state plan for a root non-Count AggregateFunction. Sum-family
  # states remain fixed-width; Avg owns a separate variable-width layout.
  # Both are distinct from scalar result validation: accumulator bytes are raw
  # state, and nullable presence is aggregate framing rather than scalar NULL.
  class BinaryAggregateFunctionStatePlan
    getter type : BinaryDataType
    getter descriptor : BinaryAggregateFunctionType
    getter function_name : String
    getter argument_type : BinaryDataType
    getter input_type : BinaryDataType
    getter avg_layout : BinaryAggregateAvgStateLayout?
    getter? nullable_argument : Bool

    @fixed_state_width : Int32?

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
      BinaryAggregateFunctionAdmission.validate_argument!(@argument_type, @function_name)

      dispatched = @argument_type
      dispatched = dispatched.child_at(0) if dispatched.tag == BinaryDataType::TAG_LOW_CARDINALITY
      @nullable_argument = dispatched.tag == BinaryDataType::TAG_NULLABLE
      @input_type = @nullable_argument ? dispatched.child_at(0) : dispatched
      if @function_name == "avg"
        @avg_layout = BinaryAggregateAvgStateLayout.new(@input_type)
        @fixed_state_width = nil
      else
        @avg_layout = nil
        @fixed_state_width = state_width_for(@function_name, @input_type)
      end
    end

    def self.for_type(type : BinaryDataType) : BinaryAggregateFunctionStatePlan
      new(type)
    end

    def minimum_state_bytes : Int32
      return 1 if @nullable_argument
      if layout = @avg_layout
        layout.minimum_state_bytes
      else
        state_width
      end
    end

    def default_state_bytes : Bytes
      if @nullable_argument
        Bytes[0_u8]
      elsif layout = @avg_layout
        layout.default_state_bytes
      else
        Bytes.new(state_width, 0_u8)
      end
    end

    def validate_state_bytes(bytes : Bytes) : Nil
      if @nullable_argument
        if bytes.size == 1 && bytes[0] == 0_u8
          return nil
        end
        unless bytes.size >= 2 && bytes[0] == 1_u8
          raise ArgumentError.new("AggregateFunction nullable state has invalid presence or body")
        end
        validate_inner_state_bytes(bytes[1, bytes.size - 1])
      else
        validate_inner_state_bytes(bytes)
      end
      nil
    end

    # Kept as the historical fixed-width accessor for Sum-family callers.
    # Avg has no single state width; returning one would invite fixed-stride
    # row traversal and make adjacent states ambiguous.
    def state_width : Int32
      @fixed_state_width || raise(ArgumentError.new("AggregateFunction avg state width is variable"))
    end

    private def validate_inner_state_bytes(bytes : Bytes) : Nil
      if layout = @avg_layout
        layout.validate_state_bytes(bytes)
      elsif bytes.size != state_width
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
