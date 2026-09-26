module CrystalClick
  # The signed 256-bit two's-complement coefficient stored by Decimal256.
  # `low` contains bytes 0..15 and `high` bytes 16..31, both little-endian.
  # Scale is column metadata and is deliberately not part of this raw value.
  struct Decimal256Value
    getter low : UInt128
    getter high : UInt128

    def initialize(@low : UInt128, @high : UInt128)
    end

    def self.from_words(w0 : UInt64, w1 : UInt64, w2 : UInt64, w3 : UInt64) : self
      low = w0.to_u128 | (w1.to_u128 << 64)
      high = w2.to_u128 | (w3.to_u128 << 64)
      new(low, high)
    end

    # Widen a signed Int128 coefficient without changing its two's-complement
    # bit pattern; negative values fill the upper 128 bits with ones.
    def self.from_int128(value : Int128) : self
      high = value < 0 ? UInt128::MAX : 0_u128
      new(value.unsafe_as(UInt128), high)
    end

    def negative? : Bool
      (high >> 127) == 1_u128
    end

    # Render the signed raw coefficient without a BigInt dependency. The
    # four-word long division uses only stack scalars and a fixed digit buffer.
    def to_s(io : IO) : Nil
      w0 = (low & UInt64::MAX.to_u128).to_u64
      w1 = (low >> 64).to_u64
      w2 = (high & UInt64::MAX.to_u128).to_u64
      w3 = (high >> 64).to_u64
      is_negative = negative?

      if is_negative
        carry = 1_u64
        original = w0
        w0 = ~original &+ carry
        carry = original == 0_u64 ? 1_u64 : 0_u64
        original = w1
        w1 = ~original &+ carry
        carry = carry == 1_u64 && original == 0_u64 ? 1_u64 : 0_u64
        original = w2
        w2 = ~original &+ carry
        carry = carry == 1_u64 && original == 0_u64 ? 1_u64 : 0_u64
        w3 = ~w3 &+ carry
      end

      digits = StaticArray(UInt8, 78).new(0_u8)
      digit_count = 0
      loop do
        remainder = 0_u128
        w3, remainder = divide_word_by_ten(remainder, w3)
        w2, remainder = divide_word_by_ten(remainder, w2)
        w1, remainder = divide_word_by_ten(remainder, w1)
        w0, remainder = divide_word_by_ten(remainder, w0)
        digits[digit_count] = '0'.ord.to_u8 + remainder.to_u8
        digit_count += 1
        break if w0 == 0_u64 && w1 == 0_u64 && w2 == 0_u64 && w3 == 0_u64
      end

      io.write_byte('-'.ord.to_u8) if is_negative
      while digit_count > 0
        digit_count -= 1
        io.write_byte(digits[digit_count])
      end
    end

    private def divide_word_by_ten(remainder : UInt128, word : UInt64) : {UInt64, UInt128}
      dividend = (remainder << 64) | word.to_u128
      {(dividend // 10).to_u64, dividend % 10}
    end
  end
end
