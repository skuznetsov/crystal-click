module CrystalClick
  # Signed raw Decimal256 coefficient with exact precision and scale, distinct
  # from the existing scale-free Decimal256Value API.
  struct Decimal256TupleValue
    @raw : Decimal256Value
    @precision : Int32
    @scale : Int32

    def initialize(@raw : Decimal256Value, @precision : Int32, @scale : Int32)
      raise ArgumentError.new("Decimal256 precision must be between 39 and 76") unless @precision >= 39 && @precision <= 76
      raise ArgumentError.new("Decimal256 scale must be between 0 and precision") unless @scale >= 0 && @scale <= @precision
    end

    def raw : Decimal256Value
      @raw
    end

    def precision : Int32
      @precision
    end

    def scale : Int32
      @scale
    end

    def ==(other : self) : Bool
      @raw.low == other.raw.low && @raw.high == other.raw.high &&
        @precision == other.precision && @scale == other.scale
    end

    def hash(hasher)
      hasher = @raw.low.hash(hasher)
      hasher = @raw.high.hash(hasher)
      hasher = @precision.hash(hasher)
      hasher = @scale.hash(hasher)
      hasher
    end
  end
end
