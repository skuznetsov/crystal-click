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
      granule = retained_granule_at(mark)
      granule.try(&.matches_shards?(shards)) || false
    end

    def granule_at(mark : Int) : CompactPartPhysicalGranule
      retained_granule_at(mark).detached_copy
    end

    def shard_count_at(mark : Int) : Int32
      retained_granule_at(mark).shard_count
    end

    def shard_bytes_at(mark : Int, slot_index : Int) : Bytes
      retained_granule_at(mark).shard_bytes_at(slot_index)
    end

    def row_offset_at(mark : Int) : UInt64
      retained_granule_at(mark).row_offset
    end

    def retained_workspace_bytes : UInt64
      bytes = instance_sizeof(CompactPartPhysicalWindow).to_u64
      bytes = checked_add(bytes, string_owner_bytes(@column))
      bytes = checked_add(bytes, instance_sizeof(Array(CompactPartPhysicalGranule)).to_u64)
      bytes = checked_add(bytes,
        checked_multiply(@granules.size.to_u64, sizeof(Pointer(CompactPartPhysicalGranule)).to_u64))
      @granules.each { |granule| bytes = checked_add(bytes, granule.retained_workspace_bytes) }
      bytes
    end

    private def retained_granule_at(mark : Int) : CompactPartPhysicalGranule
      unless mark >= @first_mark && mark - @first_mark < @granules.size
        raise ArgumentError.new("Compact window mark is outside its captured grid")
      end
      @granules[(mark - @first_mark).to_i]
    end

    private def string_owner_bytes(value : String) : UInt64
      checked_add(instance_sizeof(String).to_u64, value.bytesize.to_u64 + 1_u64)
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      raise CorruptPartError.new("Compact physical window workspace overflows") if right > UInt64::MAX - left
      left + right
    end

    private def checked_multiply(left : UInt64, right : UInt64) : UInt64
      raise CorruptPartError.new("Compact physical window workspace overflows") if left > 0_u64 && right > UInt64::MAX // left
      left * right
    end
  end
end
