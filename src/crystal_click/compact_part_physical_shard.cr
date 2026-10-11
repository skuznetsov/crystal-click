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

    def detached_copy : CompactPartPhysicalShard
      CompactPartPhysicalShard.new(
        @slot_index,
        @stream_name,
        @logical_start,
        @logical_end,
        @bytes
      )
    end
  end
end
