module CrystalClick
  # Caller-materialized aggregate states for a bounded Wide projection child.
  # Each constructor retains its own UInt64 snapshot; the aggregate state bytes
  # are generated only when the child writer prepares its physical column.
  class WidePartProjectionAggregate
    @argument_name : String?
    @values : Array(UInt64)
    @count_total : UInt128?

    private def initialize(
      @argument_name : String?,
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
      new(nil, values, total)
    end

    def self.sum_uint64(argument_name : String, sums : Slice(UInt64)) : WidePartProjectionAggregate
      validate_column_name!(argument_name)
      validate_values_size!(sums.size, "sum")
      values = Array(UInt64).new(sums.size)
      sums.each { |sum| values << sum }
      new(String.new(argument_name.to_slice), values, nil)
    end

    def argument_name : String?
      @argument_name.try { |name| String.new(name.to_slice) }
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
      @argument_name.nil?
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

    private def self.validate_column_name!(name : String) : Nil
      unless name.bytesize > 0 && name.bytesize <= WidePartWriter::MAX_COLUMN_NAME_BYTES &&
             /\A[A-Za-z_][A-Za-z0-9_]*\z/.matches?(name)
        raise ArgumentError.new("aggregate projection argument must be a bounded ASCII identifier")
      end
      nil
    end
  end
end
