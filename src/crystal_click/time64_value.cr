module CrystalClick
  # Raw signed Time64 ticks paired with the exact declared precision.
  # The wrapper never rescales, rounds, or clamps its raw payload.
  struct Time64Value
    getter raw : Int64
    getter precision : UInt8

    def initialize(@raw : Int64, precision : Int)
      raise ArgumentError.new("Time64 precision must be between 0 and 9") if precision < 0 || precision > 9
      @precision = precision.to_u8
    end

    def initialize(@raw : Int64, precision : UInt8)
      raise ArgumentError.new("Time64 precision must be between 0 and 9") if precision > 9_u8
      @precision = precision
    end

    def ==(other : self) : Bool
      @raw == other.raw && @precision == other.precision
    end

    def hash(hasher)
      hasher = @raw.hash(hasher)
      @precision.hash(hasher)
    end
  end
end
