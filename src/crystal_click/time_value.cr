module CrystalClick
  # The raw signed Int32 seconds value stored by a ClickHouse Time.
  struct TimeValue
    getter raw : Int32

    def initialize(@raw : Int32)
    end

    def ==(other : self) : Bool
      @raw == other.raw
    end

    def hash(hasher)
      @raw.hash(hasher)
    end
  end
end
