module CrystalClick
  # Exact scalar Wide-part identity for Interval columns. The physical payload
  # is always a signed Int64 count; the kind remains nominal metadata.
  class IntervalColumnType
    MAX_TYPE_BYTES = 29

    enum Shape
      Scalar
      Nullable
    end

    getter interval_type : BinaryIntervalType
    getter shape : Shape

    def initialize(kind : BinaryIntervalType::Kind, nullable : Bool = false)
      @interval_type = BinaryIntervalType.new(kind)
      @shape = nullable ? Shape::Nullable : Shape::Scalar
    end

    def self.interval(kind : BinaryIntervalType::Kind) : IntervalColumnType
      new(kind)
    end

    def self.nullable_interval(kind : BinaryIntervalType::Kind) : IntervalColumnType
      new(kind, true)
    end

    def self.parse(type_name : String) : IntervalColumnType?
      return nil if type_name.bytesize > MAX_TYPE_BYTES

      if interval_type = BinaryIntervalType.parse(type_name)
        return new(interval_type.kind)
      end

      return nil unless type_name.starts_with?("Nullable(") && type_name.ends_with?(")")

      leaf = type_name.byte_slice("Nullable(".bytesize, type_name.bytesize - "Nullable()".bytesize)
      interval_type = BinaryIntervalType.parse(leaf) || return nil
      new(interval_type.kind, true)
    end

    def kind : BinaryIntervalType::Kind
      @interval_type.kind
    end

    def nullable? : Bool
      @shape == Shape::Nullable
    end

    def raw_width : Int32
      @interval_type.fixed_width
    end

    def type_name : String
      nullable? ? "Nullable(#{@interval_type.type_name})" : @interval_type.type_name
    end

    def with_nullable(nullable : Bool) : IntervalColumnType
      IntervalColumnType.new(kind, nullable)
    end

    def ==(other : self) : Bool
      @interval_type == other.@interval_type && @shape == other.@shape
    end

    def hash(hasher)
      hasher = @interval_type.hash(hasher)
      @shape.hash(hasher)
    end
  end
end
