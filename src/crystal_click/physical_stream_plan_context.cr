module CrystalClick
  # Operation-local budget shared by every plan contributing to one physical
  # roster. Counters describe bounded logical work and retained name bytes;
  # they are not an allocator or RSS guarantee.
  class PhysicalStreamPlanContext
    getter limits : BinaryCodecLimits

    @nodes : UInt64 = 0_u64
    @elements : UInt64 = 0_u64
    @name_bytes : UInt64 = 0_u64

    def initialize(@limits : BinaryCodecLimits)
    end

    def record_type_node(depth : Int) : Nil
      if depth > @limits.max_depth
        raise UnsupportedFormatError.new("physical stream type depth exceeds configured limit")
      end
      @nodes = checked_add(@nodes, 1_u64, "physical stream type count")
      if @nodes > @limits.max_nodes.to_u64
        raise UnsupportedFormatError.new("physical stream type count exceeds configured limit")
      end
      nil
    end

    def record_elements(count : UInt64) : Nil
      @elements = checked_add(@elements, count, "physical stream element count")
      if @elements > @limits.max_elements.to_u64
        raise UnsupportedFormatError.new("physical stream element count exceeds configured limit")
      end
      nil
    end

    # Validate prospective descriptor work without consuming its counters.
    # Dynamic Object names need this check before their SQL rendering; the
    # nested binary plan performs the actual charge when it is constructed.
    def preflight_type_budget(nodes : UInt64, elements : UInt64) : Nil
      prospective_nodes = checked_add(@nodes, nodes, "physical stream type count")
      prospective_elements = checked_add(@elements, elements, "physical stream element count")
      if prospective_nodes > @limits.max_nodes.to_u64
        raise UnsupportedFormatError.new("physical stream type count exceeds configured limit")
      end
      if prospective_elements > @limits.max_elements.to_u64
        raise UnsupportedFormatError.new("physical stream element count exceeds configured limit")
      end
      nil
    end

    # Check prospective retained bytes before constructing an expanded name.
    def preflight_name_bytes(count : UInt64) : Nil
      total = checked_add(@name_bytes, count, "physical stream name bytes")
      if total > @limits.max_bytes.to_u64
        raise UnsupportedFormatError.new("physical stream names exceed configured byte limit")
      end
      nil
    end

    def charge_name_bytes(count : UInt64) : Nil
      preflight_name_bytes(count)
      @name_bytes += count
      nil
    end

    def remaining_name_bytes : UInt64
      @limits.max_bytes.to_u64 - @name_bytes
    end

    private def checked_add(left : UInt64, right : UInt64, description : String) : UInt64
      if left > UInt64::MAX - right
        raise UnsupportedFormatError.new("#{description} overflows UInt64")
      end
      left + right
    end
  end
end
