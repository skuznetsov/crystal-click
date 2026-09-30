module CrystalClick
  # Signed raw Decimal32 coefficient with exact declared precision and scale.
  struct Decimal32Value
    @raw : Int32
    @precision : Int32
    @scale : Int32

    def initialize(@raw : Int32, @precision : Int32, @scale : Int32)
      raise ArgumentError.new("Decimal32 precision must be between 1 and 9") unless @precision >= 1 && @precision <= 9
      raise ArgumentError.new("Decimal32 scale must be between 0 and precision") unless @scale >= 0 && @scale <= @precision
    end

    def raw : Int32
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
