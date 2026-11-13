module CrystalClick
  # Caller-materialized aggregate states for a bounded Wide projection child.
  # Each constructor retains its own UInt64 snapshot; the aggregate state bytes
  # are generated only when the child writer prepares its physical column.
  class WidePartProjectionAggregate
    # :nodoc:
    getter descriptor : WidePartProjectionAggregateDescriptor

    @values : Array(UInt64)
    @count_total : UInt128?

    private def initialize(
      @descriptor : WidePartProjectionAggregateDescriptor,
      @values : Array(UInt64),
      @count_total : UInt128?,
    )
    end

    def self.count(counts : Slice(UInt64)) : WidePartProjectionAggregate
      validate_values_size!(counts.size, "count")
      values = Array(UInt64).new(counts.size)
      total = 0_u128
      counts.each do |count|
        if count == 0_u64
          raise ArgumentError.new("count projection values must be positive")
        end
        values << count
        total += count.to_u128
      end
      new(WidePartProjectionAggregateDescriptor.count, values, total)
    end

    def self.sum_uint64(argument_name : String, sums : Slice(UInt64)) : WidePartProjectionAggregate
      descriptor = WidePartProjectionAggregateDescriptor.sum(argument_name)
      validate_values_size!(sums.size, "sum")
      values = Array(UInt64).new(sums.size)
      sums.each { |sum| values << sum }
      new(descriptor, values, nil)
    end

    def self.min_uint64(argument_name : String, minima : Slice(UInt64)) : WidePartProjectionAggregate
      descriptor = WidePartProjectionAggregateDescriptor.min(argument_name)
      validate_values_size!(minima.size, "min")
      values = Array(UInt64).new(minima.size)
      minima.each { |minimum| values << minimum }
      new(descriptor, values, nil)
    end

    def self.max_uint64(argument_name : String, maxima : Slice(UInt64)) : WidePartProjectionAggregate
      descriptor = WidePartProjectionAggregateDescriptor.max(argument_name)
      validate_values_size!(maxima.size, "max")
      values = Array(UInt64).new(maxima.size)
      maxima.each { |maximum| values << maximum }
      new(descriptor, values, nil)
    end

    def argument_name : String?
      @descriptor.argument_name
    end

    # Returns a detached snapshot of the caller-computed UInt64 values.
    def values : Array(UInt64)
      @values.dup
    end

    # :nodoc:
    def value_count : Int32
      @values.size.to_i32
    end

    def count? : Bool
      @descriptor.count?
    end

    # :nodoc:
    def count_total : UInt128
      @count_total.not_nil!
    end

    private def self.validate_values_size!(size : Int, kind : String) : Nil
      unless size > 0 && size.to_u64 <= WidePart::MAX_ROWS
        raise ArgumentError.new("a #{kind} projection requires a bounded nonempty UInt64 value stream")
      end
      nil
    end
  end
end
