module CrystalClick
  # Shared per-mark logical-shape totals for one recursive QBit census scope.
  # These limits describe shape work, not decoded-value budget consumption.
  class BinaryQBitOccurrenceTotals
    getter mark_count : Int32
    getter workspace_bytes : UInt64

    @element_totals : Array(UInt64)
    @wire_totals : Array(UInt64)
    @max_elements : UInt64
    @max_bytes : UInt64
    @limits : BinaryCodecLimits

    def initialize(mark_count : Int, limits : BinaryCodecLimits, codec_budget : BinaryCodecBudget)
      unless mark_count > 0 && mark_count <= WidePartWriter::MAX_MARKS &&
             !codec_budget.writing? && same_limits?(limits, codec_budget.limits)
        raise CorruptPartError.new("QBit shared occurrence totals have an invalid mark domain or budget")
      end

      @mark_count = mark_count.to_i32
      @limits = limits
      counter_values = checked_multiply(mark_count.to_u64, 2_u64)
      @workspace_bytes = checked_multiply(counter_values, 8_u64)
      unless @workspace_bytes <= limits.max_bytes.to_u64
        raise CorruptPartError.new("QBit shared occurrence workspace exceeds the configured byte limit")
      end
      codec_budget.ensure_future_nodes(counter_values)
      codec_budget.ensure_future_elements(counter_values)

      @max_elements = limits.max_elements.to_u64
      @max_bytes = limits.max_bytes.to_u64
      @element_totals = Array(UInt64).new(mark_count, 0_u64)
      @wire_totals = Array(UInt64).new(mark_count, 0_u64)
    end

    # Account for an occurrence visitor's live mark vectors before it allocates
    # them. The two shared per-mark vectors remain live for the whole owner.
    def preflight_active_vectors!(vector_count : UInt64, codec_budget : BinaryCodecBudget) : Nil
      unless !codec_budget.writing? && same_limits?(codec_budget.limits, @limits)
        raise CorruptPartError.new("QBit occurrence visitor budget differs from its shared totals")
      end
      active_values = checked_multiply(@mark_count.to_u64, vector_count)
      total_values = checked_add(checked_multiply(@mark_count.to_u64, 2_u64), active_values)
      total_bytes = checked_multiply(total_values, 8_u64)
      unless total_bytes <= @max_bytes
        raise CorruptPartError.new("QBit occurrence workspace exceeds the configured byte limit")
      end
      codec_budget.ensure_future_nodes(total_values)
      codec_budget.ensure_future_elements(total_values)
      nil
    end

    def add_elements!(mark : Int, count : UInt64) : Nil
      unless mark >= 0 && mark < @mark_count
        raise CorruptPartError.new("QBit shared element total is outside its mark domain")
      end
      current = @element_totals[mark]
      if current > @max_elements || count > @max_elements - current
        raise CorruptPartError.new("binary codec element limit exceeded")
      end
      @element_totals[mark] = current + count
    end

    def add_wire_bytes!(mark : Int, count : UInt64) : Nil
      unless mark >= 0 && mark < @mark_count
        raise CorruptPartError.new("QBit shared wire total is outside its mark domain")
      end
      current = @wire_totals[mark]
      if current > @max_bytes || count > @max_bytes - current
        raise CorruptPartError.new("binary codec byte limit exceeded")
      end
      @wire_totals[mark] = current + count
    end

    private def same_limits?(left : BinaryCodecLimits, right : BinaryCodecLimits) : Bool
      left.max_depth == right.max_depth && left.max_nodes == right.max_nodes &&
        left.max_elements == right.max_elements && left.max_bytes == right.max_bytes
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        raise CorruptPartError.new("QBit occurrence workspace overflows UInt64")
      end
      left + right
    end

    private def checked_multiply(left : UInt64, right : UInt64) : UInt64
      if right != 0_u64 && left > UInt64::MAX // right
        raise CorruptPartError.new("QBit occurrence workspace overflows UInt64")
      end
      left * right
    end
  end
end
