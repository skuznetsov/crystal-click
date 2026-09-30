module CrystalClick
  # The raw signed Int32 day code stored by a ClickHouse Date32 value.
  struct Date32Value
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
