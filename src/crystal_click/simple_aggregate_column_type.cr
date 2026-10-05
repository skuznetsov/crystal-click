module CrystalClick
  # Exact scalar Wide-part identity for the admitted SimpleAggregateFunction
  # UInt64 profile. The function name remains nominal metadata; the stored
  # payload is the raw UInt64 child and is never aggregated by this layer.
  class SimpleAggregateColumnType
    MAX_TYPE_BYTES = 80

    enum Shape
      Scalar
      Nullable
    end

    getter simple_aggregate_type : BinarySimpleAggregateType
    getter shape : Shape

    def initialize(function : BinarySimpleAggregateType::Function, nullable : Bool = false)
      @simple_aggregate_type = BinarySimpleAggregateType.new(function)
      @shape = nullable ? Shape::Nullable : Shape::Scalar
    end

    def self.simple_aggregate(function : BinarySimpleAggregateType::Function) : SimpleAggregateColumnType
      new(function)
    end

    def self.nullable_simple_aggregate(function : BinarySimpleAggregateType::Function) : SimpleAggregateColumnType
      new(function, true)
    end

    def self.parse(type_name : String) : SimpleAggregateColumnType?
      return nil if type_name.bytesize > MAX_TYPE_BYTES

      if aggregate_type = BinarySimpleAggregateType.parse(type_name)
        return new(aggregate_type.function)
      end

      return nil unless type_name.starts_with?("Nullable(") && type_name.ends_with?(")")

      leaf = type_name.byte_slice("Nullable(".bytesize, type_name.bytesize - "Nullable()".bytesize)
      aggregate_type = BinarySimpleAggregateType.parse(leaf) || return nil
      new(aggregate_type.function, true)
    end

    def function : BinarySimpleAggregateType::Function
      @simple_aggregate_type.function
    end

    def nullable? : Bool
      @shape == Shape::Nullable
    end

    def raw_width : Int32
      8
    end

    def type_name : String
      nullable? ? "Nullable(#{@simple_aggregate_type.type_name})" : @simple_aggregate_type.type_name
    end

    def with_nullable(nullable : Bool) : SimpleAggregateColumnType
      SimpleAggregateColumnType.new(function, nullable)
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
