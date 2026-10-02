module CrystalClick
  # Aggregate logical visit/edge/wire-byte budget shared by paired binary
  # codec contexts. Counts are operation-local; callers may borrow this owner
  # across several exact scalar envelopes without resetting recursive limits.
  class BinaryCodecBudget
    getter limits : BinaryCodecLimits
    getter node_count : Int64
    getter element_count : Int64
    getter wire_byte_count : Int64

    @writing : Bool

    def initialize(@limits : BinaryCodecLimits, @writing : Bool = false)
      @node_count = 0_i64
      @element_count = 0_i64
      @wire_byte_count = 0_i64
    end

    def writing? : Bool
      @writing
    end

    # Outer owners can account for rows/records that are logical nodes but do
    # not belong to a recursive type/value depth tree.
    def charge_node : Nil
      ensure_future_nodes(1_u64)
      @node_count += 1_i64
    end

    def visit_node(depth : Int) : Nil
      ensure_depth(depth)
      charge_node
    end

    def ensure_depth(depth : Int) : Nil
      if depth <= 0 || depth > @limits.max_depth
        fail_budget("depth")
      end
    end

    def ensure_future_nodes(count : UInt64) : Nil
      remaining = (@limits.max_nodes - @node_count).to_u64
      fail_budget("node") if count > remaining
    end

    def ensure_future_elements(count : UInt64) : Nil
      remaining = (@limits.max_elements - @element_count).to_u64
      fail_budget("element") if count > remaining
    end

    def charge_elements(count : UInt64) : Nil
      ensure_future_elements(count)
      @element_count += count.to_i64
    end

    # Descriptor/container child edges and their lower-bound nodes are
    # charged/preflighted together. Node visits are charged by recursion.
    def preflight_children(count : UInt64) : Nil
      charge_elements(count)
      ensure_future_nodes(count)
    end

    def ensure_wire_bytes(additional : UInt64) : Nil
      remaining = (@limits.max_bytes - @wire_byte_count).to_u64
      fail_budget("byte") if additional > remaining
    end

    def charge_wire_bytes(count : UInt64) : Nil
      ensure_wire_bytes(count)
      @wire_byte_count += count.to_i64
    end

    def remaining_wire_bytes : UInt64
      (@limits.max_bytes - @wire_byte_count).to_u64
    end

    private def fail_budget(kind : String) : NoReturn
      message = "binary codec #{kind} limit exceeded"
      if @writing
        raise UnsupportedFormatError.new(message)
      else
        raise CorruptPartError.new(message)
      end
    end
  end
end
