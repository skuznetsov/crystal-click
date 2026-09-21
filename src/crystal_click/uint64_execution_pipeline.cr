module CrystalClick
  struct UInt64AggregateResult
    getter count : UInt64
    getter sum : UInt64
    getter min : UInt64?
    getter max : UInt64?

    def initialize(@count : UInt64, @sum : UInt64, @min : UInt64?, @max : UInt64?)
    end

    def empty? : Bool
      @count == 0_u64
    end
  end

  class WidePartSet
    def aggregate_uint64(scratch : Slice(UInt64)) : UInt64AggregateResult
      aggregate_uint64(scratch) { |_| true }
    end

    def aggregate_uint64(
      scratch : Slice(UInt64),
      & : UInt64 -> Bool
    ) : UInt64AggregateResult
      count = 0_u64
      sum = 0_u64
      minimum : UInt64? = nil
      maximum : UInt64? = nil

      scan_into(scratch) do |batch|
        batch.values.each do |value|
          next unless yield value
          raise BoundsError.new("aggregate count overflow") if count == UInt64::MAX

          count += 1_u64
          sum = sum &+ value
          if minimum_value = minimum
            minimum = value if value < minimum_value
            maximum_value = maximum.not_nil!
            maximum = value if value > maximum_value
          else
            minimum = value
            maximum = value
          end
        end
      end

      UInt64AggregateResult.new(count, sum, minimum, maximum)
    end
  end
end
