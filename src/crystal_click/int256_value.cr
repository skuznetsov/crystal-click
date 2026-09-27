module CrystalClick
  # The raw 256-bit two's-complement bits of a primitive Int256 value.
  # `low` contains bytes 0..15 and `high` bytes 16..31, both little-endian.
  # This is deliberately distinct from Decimal256Value and has no decimal
  # scale or numeric conversion semantics.
  struct Int256Value
    getter low : UInt128
    getter high : UInt128

    def initialize(@low : UInt128, @high : UInt128)
    end

    def self.from_words(w0 : UInt64, w1 : UInt64, w2 : UInt64, w3 : UInt64) : self
      low = w0.to_u128 | (w1.to_u128 << 64)
      high = w2.to_u128 | (w3.to_u128 << 64)
      new(low, high)
    end
  end

  # The raw 256-bit bits of a primitive UInt256 value. Kept distinct from
  # Int256Value and Decimal256Value so typed APIs cannot erase signedness or
  # decimal scale semantics.
  struct UInt256Value
    getter low : UInt128
    getter high : UInt128

    def initialize(@low : UInt128, @high : UInt128)
    end

    def self.from_words(w0 : UInt64, w1 : UInt64, w2 : UInt64, w3 : UInt64) : self
      low = w0.to_u128 | (w1.to_u128 << 64)
      high = w2.to_u128 | (w3.to_u128 << 64)
      new(low, high)
    end
  end
end
