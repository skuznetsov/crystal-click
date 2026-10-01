module CrystalClick
  # An exact two-coordinate Point value. Floats are retained without
  # normalization; callers that need wire identity should use the bit accessors.
  struct WidePointValue
    getter x : Float64
    getter y : Float64

    def initialize(@x : Float64, @y : Float64)
    end

    def self.from_bits(x_bits : UInt64, y_bits : UInt64) : WidePointValue
      new(x_bits.unsafe_as(Float64), y_bits.unsafe_as(Float64))
    end

    def x_bits : UInt64
      @x.unsafe_as(UInt64)
    end

    def y_bits : UInt64
      @y.unsafe_as(UInt64)
    end

    def same_bits?(other : WidePointValue) : Bool
      x_bits == other.x_bits && y_bits == other.y_bits
    end

    def ==(other : WidePointValue) : Bool
      same_bits?(other)
    end

    def hash(hasher)
      hasher = x_bits.hash(hasher)
      y_bits.hash(hasher)
    end
  end
end
