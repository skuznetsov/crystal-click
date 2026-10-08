module CrystalClick
  # The bounded Field parameter profile admitted for SimpleAggregateFunction.
  # ClickHouse supports arbitrary Field values; this owner intentionally keeps
  # only the measured zero-or-one positive UInt64 cap used by the array-family
  # functions.
  class BinarySimpleAggregateParameters
    MAX_FIELDS = 1

    @values : Array(UInt64)

    def initialize(values : Array(UInt64) = [] of UInt64)
      unless values.size <= MAX_FIELDS && values.all? { |value| value > 0_u64 }
        raise ArgumentError.new("SimpleAggregateFunction parameters require zero or one positive UInt64 Field")
      end
      @values = values.dup
    end

    def self.empty : BinarySimpleAggregateParameters
      new
    end

    def self.one(value : UInt64) : BinarySimpleAggregateParameters
      new([value] of UInt64)
    end

    def count : Int32
      @values.size
    end

    def empty? : Bool
      @values.empty?
    end

    def values : Array(UInt64)
      @values.dup
    end

    def value_at(index : Int) : UInt64
      @values[index]
    end

    def ==(other : BinarySimpleAggregateParameters) : Bool
      @values == other.@values
    end

    def_hash @values
  end
end
