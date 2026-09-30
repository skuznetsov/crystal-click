module CrystalClick
  # The raw UInt32 epoch-seconds value stored by a ClickHouse DateTime.
  struct DateTimeValue
    getter raw : UInt32

    def initialize(@raw : UInt32)
    end

    def ==(other : self) : Bool
      @raw == other.raw
    end

    def hash(hasher)
      @raw.hash(hasher)
    end
  end
end
