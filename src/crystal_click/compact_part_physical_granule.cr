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

    def detached_copy : CompactPartPhysicalGranule
      CompactPartPhysicalGranule.new(@mark, @row_offset, @row_count, @shards)
    end
  end
end
