module CrystalClick
  # The raw UInt16 day code stored by a ClickHouse Date value.
  struct DateValue
    getter raw : UInt16

    def initialize(@raw : UInt16)
    end

    def ==(other : self) : Bool
      @raw == other.raw
    end

    def hash(hasher)
      @raw.hash(hasher)
    end
  end
end
