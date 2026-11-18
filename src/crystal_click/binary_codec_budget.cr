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
    @replayed_preparation : Tuple(BinaryCodecBudget, Int64, Int64, Int64)?

    def initialize(@limits : BinaryCodecLimits, @writing : Bool = false)
      @node_count = 0_i64
      @element_count = 0_i64
      @wire_byte_count = 0_i64
      @replayed_preparation = nil
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

    # Replay one completed preparation operation into this independent read
    # operation. Counts are copied from the exact source budget used to build
    # prepared owners, and the provenance is recorded only after every bound
    # has passed and all counters have been charged.
    def replay_preparation_from!(source : BinaryCodecBudget) : Nil
      if @writing || source.writing?
        raise ArgumentError.new("binary codec preparation replay requires read-direction budgets")
      end
      return nil if same?(source)
      if prior = @replayed_preparation
        unless prior[0].same?(source)
          raise ArgumentError.new("binary codec budget already contains a different preparation receipt")
        end
        unless prior[1] == source.node_count && prior[2] == source.element_count && prior[3] == source.wire_byte_count
          raise ArgumentError.new("binary codec preparation source changed after its receipt was replayed")
        end
        return nil
      end
      unless @limits == source.limits
        raise ArgumentError.new("binary codec preparation replay requires matching limits")
      end

      source_nodes = source.node_count
      source_elements = source.element_count
      source_wire_bytes = source.wire_byte_count
      nodes = source_nodes.to_u64
      elements = source_elements.to_u64
      wire_bytes = source_wire_bytes.to_u64
      ensure_future_nodes(nodes)
      ensure_future_elements(elements)
      ensure_wire_bytes(wire_bytes)
      unless source.node_count == source_nodes && source.element_count == source_elements && source.wire_byte_count == source_wire_bytes
        raise ArgumentError.new("binary codec preparation source changed during receipt replay")
      end
      @node_count += nodes.to_i64
      @element_count += elements.to_i64
      @wire_byte_count += wire_bytes.to_i64
      @replayed_preparation = {source, source_nodes, source_elements, source_wire_bytes}
      nil
    end

    # Read-only provenance query used by retained prepared owners. A true
    # result means this budget already paid the source operation's exact
    # counters through `replay_preparation_from!`.
    def includes_preparation_from?(source : BinaryCodecBudget) : Bool
      if receipt = @replayed_preparation
        receipt[0].same?(source) && receipt[1] == source.node_count &&
          receipt[2] == source.element_count && receipt[3] == source.wire_byte_count
      else
        false
      end
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
