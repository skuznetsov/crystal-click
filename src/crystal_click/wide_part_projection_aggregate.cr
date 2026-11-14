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

    # :nodoc:
    # Materializes this immutable UInt64 vector into bounded BinaryValue
    # granules using the shared Wide/Compact AggregateFunction state layout.
    def state_granules(rows_per_mark : Int32, max_marks : Int32) : Array(Array(BinaryValue))
      unless rows_per_mark > 0 && max_marks > 0
        raise ArgumentError.new("aggregate projection mark dimensions must be positive")
      end
      mark_count = (@values.size.to_i64 + rows_per_mark.to_i64 - 1_i64) // rows_per_mark.to_i64
      unless mark_count > 0 && mark_count <= max_marks
        raise ArgumentError.new("#{@descriptor.function_name} projection mark count is outside the writer limit")
      end

      type = @descriptor.type
      unless @descriptor.count?
        plan = BinaryAggregateFunctionStatePlan.for_type(type)
        if @descriptor.sum?
          unless plan.state_width == sizeof(UInt64)
            raise UnsupportedFormatError.new("sum projection requires the fixed UInt64 AggregateFunction state")
          end
        elsif @descriptor.minmax?
          layout = plan.minmax_layout ||
                   raise UnsupportedFormatError.new("min/max projection requires the existing fixed-value state plan")
          unless layout.input_type.tag == BinaryDataType::TAG_UINT64 && layout.state_kind.fixed? && !plan.nullable_argument?
            raise UnsupportedFormatError.new("min/max projection requires the present UInt64 SingleValueData state")
          end
        else
          raise UnsupportedFormatError.new("aggregate projection function is outside the admitted profile")
        end
      end

      granules = Array(Array(BinaryValue)).new(mark_count.to_i32)
      offset = 0
      while offset < @values.size
        rows = Math.min(rows_per_mark, @values.size - offset)
        granule = Array(BinaryValue).new(rows)
        rows.times do |row|
          value = @values[offset + row]
          if @descriptor.count?
            granule << BinaryValue.aggregate_count_state(type, value)
          else
            presence_bytes = @descriptor.minmax? ? 1 : 0
            state_bytes = Bytes.new(presence_bytes + sizeof(UInt64))
            state_bytes[0] = 1_u8 if presence_bytes == 1
            IO::ByteFormat::LittleEndian.encode(value, state_bytes[presence_bytes, sizeof(UInt64)])
            granule << BinaryValue.aggregate_function_state(type, state_bytes)
          end
        end
        granules << granule
        offset += rows
      end
      granules
    end

    private def self.validate_values_size!(size : Int, kind : String) : Nil
      unless size > 0 && size.to_u64 <= WidePart::MAX_ROWS
        raise ArgumentError.new("a #{kind} projection requires a bounded nonempty UInt64 value stream")
      end
      nil
    end
  end
end
