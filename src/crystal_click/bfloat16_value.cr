module CrystalClick
  # The raw 16-bit BFloat16 storage bits, distinct from IEEE binary16. This
  # remains distinct from UInt16 and does not pass through Float32 arithmetic.
  struct BFloat16Value
    getter bits : UInt16

    def initialize(@bits : UInt16)
    end

    def ==(other : self) : Bool
      @bits == other.bits
    end

    def hash(hasher)
      @bits.hash(hasher)
    end

    def to_s(io : IO) : Nil
      io << "BFloat16(0x" << @bits.to_s(16).upcase.rjust(4, '0') << ")"
    end
  end
end
