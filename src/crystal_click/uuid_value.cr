module CrystalClick
  # A UUID as the two little-endian UInt64 halves used by ClickHouse's UUID
  # RowBinary and Wide-part streams. It is intentionally distinct from an
  # arbitrary 128-bit integer.
  struct UUIDValue
    getter high : UInt64
    getter low : UInt64

    def initialize(@high : UInt64, @low : UInt64)
    end

    def ==(other : self) : Bool
      @high == other.high && @low == other.low
    end

    def hash(hasher)
      @high.hash(hasher)
      @low.hash(hasher)
    end

    def to_s(io : IO) : Nil
      high = @high.to_s(16).rjust(16, '0')
      low = @low.to_s(16).rjust(16, '0')
      io << high.byte_slice(0, 8) << '-'
      io << high.byte_slice(8, 4) << '-'
      io << high.byte_slice(12, 4) << '-'
      io << low.byte_slice(0, 4) << '-'
      io << low.byte_slice(4, 12)
    end
  end
end
