module CrystalClick
  # Detached logical window of Compact physical shards; this is not a decoded
  # column value or a serializer result.
  class CompactPartPhysicalWindow
    getter mode : CompactMarkFormat
    getter column : String
    getter first_mark : Int32
    getter row_offset : UInt64

    @granules : Array(CompactPartPhysicalGranule)

    def initialize(
      @mode : CompactMarkFormat,
      column : String,
      @first_mark : Int32,
      @row_offset : UInt64,
      granules : Array(CompactPartPhysicalGranule),
    )
      raise ArgumentError.new("first mark must be nonnegative") if @first_mark < 0
      @column = String.new(column.to_slice)
      @granules = granules.map(&.detached_copy)
    end

    def granules : Array(CompactPartPhysicalGranule)
      @granules.map(&.detached_copy)
    end

    # Nonallocating descriptor count for workspace preflight before asking for
    # an owned granule snapshot.
    def mark_count : Int32
      @granules.size
    end

    # Checks a caller's detached shards against the private captured granule
    # without returning the trusted shard owners.
    def matches_shards_at?(mark : Int, shards : Array(CompactPartPhysicalShard)) : Bool
      return false if mark < @first_mark || mark - @first_mark >= @granules.size
      granule = @granules[(mark - @first_mark).to_i]?
      granule.try(&.matches_shards?(shards)) || false
    end
  end
end
