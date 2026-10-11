module CrystalClick
  # One detached logical interval belonging to a physical Compact mark slot.
  class CompactPartPhysicalShard
    getter slot_index : Int32
    getter stream_name : String?
    getter logical_start : Int64
    getter logical_end : Int64

    @bytes : Bytes

    def initialize(
      @slot_index : Int32,
      stream_name : String?,
      @logical_start : Int64,
      @logical_end : Int64,
      bytes : Bytes,
    )
      raise ArgumentError.new("physical shard slot index must be nonnegative") if @slot_index < 0
      if @logical_start < 0 || @logical_end < @logical_start
        raise ArgumentError.new("physical shard interval is invalid")
      end
      @stream_name = stream_name.try { |name| String.new(name.to_slice) }
      expected_size = @logical_end - @logical_start
      unless expected_size == bytes.size.to_i64
        raise CorruptPartError.new("Compact shard byte count differs from its logical interval")
      end
      @bytes = bytes.dup
    end

    # Bytes are mutable in Crystal, so callers receive an owned snapshot.
    def bytes : Bytes
      @bytes.dup
    end

    # Non-copying read-only byte access for authenticated provenance checks.
    def byte_at(index : Int) : UInt8
      @bytes[index]
    end

    def matches_bytes?(other : Bytes) : Bool
      return false unless other.size == @bytes.size
      other.each_with_index do |byte, index|
        return false unless byte == @bytes[index]
      end
      true
    end

    # Logical retained-owner census for this detached shard. It counts the
    # shard object and its copied byte/name storage by logical size, not
    # allocator capacity or RSS; callers must not obtain copies through the
    # public snapshot getters to calculate it.
    def retained_workspace_bytes : UInt64
      bytes = instance_sizeof(CompactPartPhysicalShard).to_u64
      bytes = checked_add(bytes, @bytes.size.to_u64)
      if name = @stream_name
        bytes = checked_add(bytes, instance_sizeof(String).to_u64)
        bytes = checked_add(bytes, name.bytesize.to_u64)
        bytes = checked_add(bytes, 1_u64)
      end
      bytes
    end

    def detached_copy : CompactPartPhysicalShard
      CompactPartPhysicalShard.new(
        @slot_index,
        @stream_name,
        @logical_start,
        @logical_end,
        @bytes
      )
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      if right > UInt64::MAX - left
        raise CorruptPartError.new("Compact shard workspace estimate overflows UInt64")
      end
      left + right
    end
  end
end
