module CrystalClick
  # Exact scalar Wide-part identity for the admitted SimpleAggregateFunction
  # profile. The function name remains nominal metadata; the stored payload
  # retains the exact child representation and is never aggregated here.
  class SimpleAggregateColumnType
    MAX_TYPE_BYTES = 80

    enum Shape
      Scalar
      Nullable
    end

    getter simple_aggregate_type : BinarySimpleAggregateType
    getter shape : Shape

    def initialize(
      function : BinarySimpleAggregateType::Function,
      nullable : Bool = false,
      storage_type_name : String = BinarySimpleAggregateType::DEFAULT_STORAGE_TYPE_NAME,
    )
      @simple_aggregate_type = BinarySimpleAggregateType.new(function, storage_type_name)
      @shape = nullable ? Shape::Nullable : Shape::Scalar
    end

    def self.simple_aggregate(
      function : BinarySimpleAggregateType::Function,
      storage_type_name : String = BinarySimpleAggregateType::DEFAULT_STORAGE_TYPE_NAME,
    ) : SimpleAggregateColumnType
      new(function, false, storage_type_name)
    end

    def self.nullable_simple_aggregate(
      function : BinarySimpleAggregateType::Function,
      storage_type_name : String = BinarySimpleAggregateType::DEFAULT_STORAGE_TYPE_NAME,
    ) : SimpleAggregateColumnType
      new(function, true, storage_type_name)
    end

    def self.storage_name(type : T.class) : String forall T
      {% if T == UInt8 %}
        "UInt8"
      {% elsif T == UInt16 %}
        "UInt16"
      {% elsif T == UInt32 %}
        "UInt32"
      {% elsif T == UInt64 %}
        "UInt64"
      {% elsif T == UInt128 %}
        "UInt128"
      {% elsif T == Int8 %}
        "Int8"
      {% elsif T == Int16 %}
        "Int16"
      {% elsif T == Int32 %}
        "Int32"
      {% elsif T == Int64 %}
        "Int64"
      {% elsif T == Int128 %}
        "Int128"
      {% elsif T == UInt256Value %}
        "UInt256"
      {% elsif T == Int256Value %}
        "Int256"
      {% elsif T == BFloat16Value %}
        "BFloat16"
      {% elsif T == Float32 %}
        "Float32"
      {% elsif T == Float64 %}
        "Float64"
      {% else %}
        raise ArgumentError.new("SimpleAggregateFunction storage accessor is outside the admitted numeric profile")
      {% end %}
    end

    def self.parse(type_name : String) : SimpleAggregateColumnType?
      return nil if type_name.bytesize > MAX_TYPE_BYTES

      if aggregate_type = BinarySimpleAggregateType.parse(type_name)
        return new(aggregate_type.function, false, aggregate_type.storage_type_name)
      end

      return nil unless type_name.starts_with?("Nullable(") && type_name.ends_with?(")")

      leaf = type_name.byte_slice("Nullable(".bytesize, type_name.bytesize - "Nullable()".bytesize)
      aggregate_type = BinarySimpleAggregateType.parse(leaf) || return nil
      new(aggregate_type.function, true, aggregate_type.storage_type_name)
    end

    def function : BinarySimpleAggregateType::Function
      @simple_aggregate_type.function
    end

    def storage_type_name : String
      @simple_aggregate_type.storage_type_name
    end

    def nullable? : Bool
      @shape == Shape::Nullable
    end

    def string? : Bool
      BinarySimpleAggregateType.string_storage?(storage_type_name)
    end

    def fixed_string_width : Int32?
      BinarySimpleAggregateType.fixed_string_width(storage_type_name)
    end

    def raw_width : Int32
      BinarySimpleAggregateType.storage_width(storage_type_name) ||
        raise ArgumentError.new("SimpleAggregateFunction raw_width requires fixed-width numeric storage")
    end

    def type_name : String
      nullable? ? "Nullable(#{@simple_aggregate_type.type_name})" : @simple_aggregate_type.type_name
    end

    def with_nullable(nullable : Bool) : SimpleAggregateColumnType
      SimpleAggregateColumnType.new(function, nullable, storage_type_name)
    end

    def ==(other : self) : Bool
      @simple_aggregate_type == other.@simple_aggregate_type && @shape == other.@shape
    end

    def hash(hasher)
      hasher = @simple_aggregate_type.hash(hasher)
      @shape.hash(hasher)
    end
  end
end
