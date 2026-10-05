module CrystalClick
  # Exact typed admission for Decimal children stored by
  # SimpleAggregateFunction. This stays separate from numeric raw-width
  # accessors: function, P/S, outer nullability and signed carrier width all
  # remain required at every consumer boundary.
  class SimpleAggregateDecimalStoragePlan
    getter aggregate_type : SimpleAggregateColumnType
    getter decimal_type : DecimalType

    def self.for_type_name(type_name : String) : SimpleAggregateDecimalStoragePlan?
      aggregate_type = SimpleAggregateColumnType.parse(type_name) || return nil
      decimal_type = aggregate_type.decimal_type || return nil
      new(aggregate_type, decimal_type)
    end

    def self.type_name(
      function : BinarySimpleAggregateType::Function,
      precision : Int32,
      scale : Int32,
      nullable : Bool = false,
    ) : String
      decimal_type = DecimalType.new(precision, scale)
      SimpleAggregateColumnType.new(function, nullable, decimal_type.type_name).type_name
    end

    def self.require(
      type_name : String,
      function : BinarySimpleAggregateType::Function,
      precision : Int32,
      scale : Int32,
      nullable : Bool = false,
    ) : SimpleAggregateDecimalStoragePlan
      plan = for_type_name(type_name) ||
             raise(UnsupportedFormatError.new("Decimal SimpleAggregateFunction accessor requires an admitted Decimal child"))
      unless plan.function == function && plan.precision == precision && plan.scale == scale && plan.nullable? == nullable
        raise UnsupportedFormatError.new("Decimal SimpleAggregateFunction accessor requires exact function, P/S, and outer-nullable metadata")
      end
      plan
    end

    private def initialize(@aggregate_type : SimpleAggregateColumnType, @decimal_type : DecimalType)
      unless @aggregate_type.decimal_type == @decimal_type
        raise ArgumentError.new("Decimal SimpleAggregateFunction plan does not match its exact child")
      end
    end

    def function : BinarySimpleAggregateType::Function
      @aggregate_type.function
    end

    def precision : Int32
      @decimal_type.precision
    end

    def scale : Int32
      @decimal_type.scale
    end

    def storage_width : Int32
      @decimal_type.storage_width
    end

    def nullable? : Bool
      @aggregate_type.nullable?
    end

    def type_name : String
      @aggregate_type.type_name
    end

    def validate_carrier!(type : T.class) : Nil forall T
      carrier_width = {% if T == Int32 %}
                        4
                      {% elsif T == Int64 %}
                        8
                      {% elsif T == Int128 %}
                        16
                      {% elsif T == Decimal256Value %}
                        32
                      {% else %}
                        raise UnsupportedFormatError.new("Decimal SimpleAggregateFunction requires its exact signed coefficient carrier")
                      {% end %}
      unless carrier_width == storage_width
        raise UnsupportedFormatError.new("Decimal SimpleAggregateFunction child width does not match the selected coefficient carrier")
      end
      nil
    end

    def validate_payload!(values : Slice(T), expected_nullable : Bool) : Nil forall T
      {% if T == Int32 %}
        validate_payload_shape!(false, expected_nullable, Int32)
      {% elsif T == Int32? %}
        validate_payload_shape!(true, expected_nullable, Int32)
      {% elsif T == Int64 %}
        validate_payload_shape!(false, expected_nullable, Int64)
      {% elsif T == Int64? %}
        validate_payload_shape!(true, expected_nullable, Int64)
      {% elsif T == Int128 %}
        validate_payload_shape!(false, expected_nullable, Int128)
      {% elsif T == Int128? %}
        validate_payload_shape!(true, expected_nullable, Int128)
      {% elsif T == Decimal256Value %}
        validate_payload_shape!(false, expected_nullable, Decimal256Value)
      {% elsif T == Decimal256Value? %}
        validate_payload_shape!(true, expected_nullable, Decimal256Value)
      {% else %}
        raise UnsupportedFormatError.new("Decimal SimpleAggregateFunction requires its exact signed coefficient carrier")
      {% end %}
    end

    private def validate_payload_shape!(actual_nullable : Bool, expected_nullable : Bool, carrier_type : T.class) : Nil forall T
      unless nullable? == expected_nullable && actual_nullable == expected_nullable
        raise UnsupportedFormatError.new("Decimal SimpleAggregateFunction payload outer-nullable shape does not match its exact declaration")
      end
      validate_carrier!(carrier_type)
      nil
    end
  end
end
