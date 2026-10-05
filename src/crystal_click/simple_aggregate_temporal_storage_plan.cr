module CrystalClick
  # Exact temporal identity for a SimpleAggregateFunction child. This remains
  # separate from the primitive numeric raw-width profile: the canonical leaf,
  # function, nullability, and exact signed/unsigned carrier are all required.
  class SimpleAggregateTemporalStoragePlan
    getter aggregate_type : SimpleAggregateColumnType
    getter temporal_type : TemporalStorageType

    def self.for_type_name(type_name : String) : SimpleAggregateTemporalStoragePlan?
      aggregate_type = SimpleAggregateColumnType.parse(type_name) || return nil
      temporal_type = TemporalStorageType.parse(aggregate_type.storage_type_name) || return nil
      return nil unless admits_function?(aggregate_type.function)
      new(aggregate_type, temporal_type)
    end

    def self.type_name(
      function : BinarySimpleAggregateType::Function,
      storage_type_name : String,
      nullable : Bool = false,
    ) : String
      temporal_type = TemporalStorageType.parse(storage_type_name) ||
                      raise(UnsupportedFormatError.new("temporal SimpleAggregateFunction requires an exact canonical temporal leaf"))
      raise UnsupportedFormatError.new("temporal SimpleAggregateFunction function is outside the admitted profile") unless admits_function?(function)

      result = SimpleAggregateColumnType.new(function, nullable, temporal_type.type_name).type_name
      if result.bytesize > SimpleAggregateColumnType::MAX_TYPE_BYTES
        raise UnsupportedFormatError.new("temporal SimpleAggregateFunction type exceeds the admitted name limit")
      end
      result
    end

    def self.require(
      type_name : String,
      function : BinarySimpleAggregateType::Function,
      storage_type_name : String,
      nullable : Bool = false,
    ) : SimpleAggregateTemporalStoragePlan
      plan = for_type_name(type_name) ||
             raise(UnsupportedFormatError.new("temporal SimpleAggregateFunction accessor requires an admitted temporal child"))
      unless plan.function == function && plan.storage_type_name == storage_type_name && plan.nullable? == nullable
        raise UnsupportedFormatError.new("temporal SimpleAggregateFunction accessor requires exact function, leaf, and outer-nullable metadata")
      end
      plan
    end

    private def initialize(@aggregate_type : SimpleAggregateColumnType, @temporal_type : TemporalStorageType)
      parsed_type = TemporalStorageType.parse(@aggregate_type.storage_type_name)
      unless parsed_type && parsed_type.type_name == @temporal_type.type_name
        raise ArgumentError.new("temporal SimpleAggregateFunction plan does not match its exact child")
      end
      unless self.class.admits_function?(@aggregate_type.function)
        raise ArgumentError.new("temporal SimpleAggregateFunction function is outside the admitted profile")
      end
    end

    def function : BinarySimpleAggregateType::Function
      @aggregate_type.function
    end

    def storage_type_name : String
      @temporal_type.type_name
    end

    def storage_width : Int32
      @temporal_type.storage_width
    end

    def nullable? : Bool
      @aggregate_type.nullable?
    end

    def type_name : String
      @aggregate_type.type_name
    end

    # A temporal child is selected by an exact leaf token, never width alone.
    # These checks additionally enforce the physical carrier's signedness.
    def validate_carrier!(type : T.class) : Nil forall T
      matches = {% if T == UInt16 %}
                  @temporal_type.family == TemporalStorageType::Family::Date
                {% elsif T == Int32 %}
                  @temporal_type.family == TemporalStorageType::Family::Date32 ||
                    @temporal_type.family == TemporalStorageType::Family::Time
                {% elsif T == UInt32 %}
                  @temporal_type.family == TemporalStorageType::Family::DateTime
                {% elsif T == Int64 %}
                  @temporal_type.family == TemporalStorageType::Family::DateTime64 ||
                    @temporal_type.family == TemporalStorageType::Family::Time64
                {% else %}
                  false
                {% end %}
      unless matches
        raise UnsupportedFormatError.new("temporal SimpleAggregateFunction requires its exact raw temporal carrier")
      end
      nil
    end

    def validate_payload!(values : Slice(T), expected_nullable : Bool) : Nil forall T
      {% if T == UInt16 %}
        validate_payload_shape!(false, expected_nullable, UInt16)
      {% elsif T == UInt16? %}
        validate_payload_shape!(true, expected_nullable, UInt16)
      {% elsif T == Int32 %}
        validate_payload_shape!(false, expected_nullable, Int32)
      {% elsif T == Int32? %}
        validate_payload_shape!(true, expected_nullable, Int32)
      {% elsif T == UInt32 %}
        validate_payload_shape!(false, expected_nullable, UInt32)
      {% elsif T == UInt32? %}
        validate_payload_shape!(true, expected_nullable, UInt32)
      {% elsif T == Int64 %}
        validate_payload_shape!(false, expected_nullable, Int64)
      {% elsif T == Int64? %}
        validate_payload_shape!(true, expected_nullable, Int64)
      {% else %}
        raise UnsupportedFormatError.new("temporal SimpleAggregateFunction requires an exact raw temporal carrier")
      {% end %}
    end

    private def validate_payload_shape!(actual_nullable : Bool, expected_nullable : Bool, carrier_type : T.class) : Nil forall T
      unless nullable? == expected_nullable && actual_nullable == expected_nullable
        raise UnsupportedFormatError.new("temporal SimpleAggregateFunction payload shape does not match its exact declaration")
      end
      validate_carrier!(carrier_type)
      nil
    end

    def self.admits_function?(function : BinarySimpleAggregateType::Function) : Bool
      case function
      when BinarySimpleAggregateType::Function::Any,
           BinarySimpleAggregateType::Function::AnyLast,
           BinarySimpleAggregateType::Function::Min,
           BinarySimpleAggregateType::Function::Max
        true
      else
        false
      end
    end
  end
end
