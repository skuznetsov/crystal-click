module CrystalClick
  # Width-preserving Decimal parameters for the binary descriptor grammar.
  # This intentionally does not use DecimalType, whose SQL width is inferred
  # from precision and whose scale must not exceed precision.
  class BinaryDecimalType
    getter width_bits : Int32
    getter precision : Int32
    getter scale : Int32

    def initialize(width_bits : Int, precision : Int, scale : Int)
      maximum = case width_bits
                when  32 then 9
                when  64 then 18
                when 128 then 38
                when 256 then 76
                else
                  raise ArgumentError.new("binary Decimal width must be 32, 64, 128, or 256 bits")
                end
      unless precision >= 1 && precision <= maximum
        raise ArgumentError.new("binary Decimal precision is outside its width-specific range")
      end
      unless scale >= 0 && scale <= maximum
        raise ArgumentError.new("binary Decimal scale is outside its width-specific range")
      end

      @width_bits = width_bits.to_i32
      @precision = precision.to_i32
      @scale = scale.to_i32
    end

    def fixed_width : Int32
      @width_bits // 8
    end

    # The conventional display omits the wire-width tag. Equality and hash
    # retain width, so equal display names do not alias distinct descriptors.
    def type_name : String
      "Decimal(#{@precision}, #{@scale})"
    end

    def ==(other : self) : Bool
      @width_bits == other.@width_bits &&
        @precision == other.@precision &&
        @scale == other.@scale
    end

    def hash(hasher)
      hasher = @width_bits.hash(hasher)
      hasher = @precision.hash(hasher)
      @scale.hash(hasher)
    end
  end
end
