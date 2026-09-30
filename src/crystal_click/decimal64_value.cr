module CrystalClick
  # Signed raw Decimal64 coefficient with exact declared precision and scale.
  struct Decimal64Value
    @raw : Int64
    @precision : Int32
    @scale : Int32

    def initialize(@raw : Int64, @precision : Int32, @scale : Int32)
      raise ArgumentError.new("Decimal64 precision must be between 10 and 18") unless @precision >= 10 && @precision <= 18
      raise ArgumentError.new("Decimal64 scale must be between 0 and precision") unless @scale >= 0 && @scale <= @precision
    end

    def raw : Int64
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
