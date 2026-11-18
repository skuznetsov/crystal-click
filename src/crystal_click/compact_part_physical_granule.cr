module CrystalClick
  # Detached selected granule with ordered physical callback shards.
  class CompactPartPhysicalGranule
    getter mark : Int32
    getter row_offset : UInt64
    getter row_count : UInt64

    @shards : Array(CompactPartPhysicalShard)

    def initialize(
      @mark : Int32,
      @row_offset : UInt64,
      @row_count : UInt64,
      shards : Array(CompactPartPhysicalShard),
    )
      raise ArgumentError.new("granule mark must be nonnegative") if @mark < 0
      @shards = shards.map(&.detached_copy)
    end

    def shards : Array(CompactPartPhysicalShard)
      @shards.map(&.detached_copy)
    end

    def shard_count : Int32
      @shards.size
    end

    def shard_bytes_at(index : Int) : Bytes
      @shards[index].bytes
    end

    def retained_workspace_bytes : UInt64
      bytes = instance_sizeof(CompactPartPhysicalGranule).to_u64
      bytes = checked_add(bytes, instance_sizeof(Array(CompactPartPhysicalShard)).to_u64)
      bytes = checked_add(bytes,
        checked_multiply(@shards.size.to_u64, sizeof(Pointer(CompactPartPhysicalShard)).to_u64))
      @shards.each { |shard| bytes = checked_add(bytes, shard.retained_workspace_bytes) }
      bytes
    end

    # Exact roster-and-payload comparison that does not return a shard alias
    # from the authenticated window.
    def matches_shards?(shards : Array(CompactPartPhysicalShard)) : Bool
      return false unless shards.size == @shards.size
      @shards.each_with_index do |shard, index|
        return false unless shard.same_detached_value?(shards[index])
      end
      true
    end

    def detached_copy : CompactPartPhysicalGranule
      CompactPartPhysicalGranule.new(@mark, @row_offset, @row_count, @shards)
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      raise CorruptPartError.new("Compact granule workspace estimate overflows UInt64") if right > UInt64::MAX - left
      left + right
    end

    private def checked_multiply(left : UInt64, right : UInt64) : UInt64
      raise CorruptPartError.new("Compact granule workspace estimate overflows UInt64") if left > 0_u64 && right > UInt64::MAX // left
      left * right
    end
  end
end
