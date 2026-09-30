module CrystalClick
  # Signed raw Decimal128 coefficient with exact declared precision and scale.
  struct Decimal128Value
    @raw : Int128
    @precision : Int32
    @scale : Int32

    def initialize(@raw : Int128, @precision : Int32, @scale : Int32)
      raise ArgumentError.new("Decimal128 precision must be between 19 and 38") unless @precision >= 19 && @precision <= 38
      raise ArgumentError.new("Decimal128 scale must be between 0 and precision") unless @scale >= 0 && @scale <= @precision
    end

    def raw : Int128
      @raw
    end

    def precision : Int32
      @precision
    end

    def scale : Int32
      @scale
    end

    def ==(other : self) : Bool
      @raw == other.raw && @precision == other.precision && @scale == other.scale
    end

    def hash(hasher)
      hasher = @raw.hash(hasher)
      hasher = @precision.hash(hasher)
      hasher = @scale.hash(hasher)
      hasher
    end
  end
end
