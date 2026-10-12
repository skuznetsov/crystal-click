module CrystalClick
  # Piecewise source coordinates for one JSON site inside a recursive Compact
  # parent mark. A site's callback path can be non-contiguous in the parent
  # tape (Tuple prefixes are emitted before any sibling body), so this owner
  # maps only the exact extents consumed by that site back to the original
  # whole-data.bin coordinates. Persisted pairs are never rebased.
  class CompactRecursiveObjectSharedInlineCoordinateContext < ObjectSharedInlineCoordinateContext
    private struct Extent
      getter path_start : UInt64
      getter path_end : UInt64
      getter shard : CompactPartPhysicalShard
      getter source_start : Int64

      def initialize(@path_start : UInt64, @path_end : UInt64, @shard : CompactPartPhysicalShard, @source_start : Int64)
      end
    end

    @physical : CompactPartPhysicalContext
    @parent_shards : Array(CompactPartPhysicalShard)
    @extents : Array(Extent)
    @site_identity : String
    @path_data_size : UInt64

    def initialize(
      @physical : CompactPartPhysicalContext,
      site_identity : String,
      parent_shards : Array(CompactPartPhysicalShard),
    )
      if site_identity.empty?
        raise ArgumentError.new("recursive Compact inline context requires an explicit site identity")
      end
      if parent_shards.empty? || parent_shards.size > Int32::MAX
        raise CorruptPartError.new("recursive Compact inline context has no authenticated parent shards")
      end
      @physical.validate_shard_provenance!(parent_shards)
      @site_identity = String.new(site_identity.to_slice)
      @parent_shards = parent_shards.dup
      @extents = [] of Extent
      @path_data_size = 0_u64
    end

    def path_data_size : Int64
      unless @path_data_size <= Int64::MAX.to_u64
        raise CorruptPartError.new("recursive Compact inline path exceeds the supported coordinate domain")
      end
      @path_data_size.to_i64
    end

    def site_identity : String
      String.new(@site_identity.to_slice)
    end

    # Capture-time append: the bytes came from the shared parent cursor, while
    # the supplied shard and local offset retain their authenticated source
    # identity. This operation deliberately does not require parent completion;
    # ObjectSharedInlineCallbackReadSlice validates bytes as each callback is
    # captured. Publication uses the separate completed-ledger validator.
    def append_authenticated_extent!(
      shard : CompactPartPhysicalShard,
      shard_offset : Int32,
      bytes : Bytes,
    ) : Tuple(UInt64, UInt64)
      owned_shard = authenticated_parent_shard(shard) ||
                    raise(CorruptPartError.new("recursive Compact callback shard is not owned by its authenticated parent mark"))
      shard_size = owned_shard.logical_end - owned_shard.logical_start
      offset = shard_offset.to_i64
      byte_size = bytes.size.to_i64
      if shard_offset < 0 || offset > shard_size || byte_size > shard_size - offset
        raise CorruptPartError.new("recursive Compact callback extent exceeds its authenticated shard")
      end
      source_start = owned_shard.logical_start + offset
      source_end = source_start + byte_size
      if source_start < owned_shard.logical_start || source_end > owned_shard.logical_end
        raise CorruptPartError.new("recursive Compact callback source coordinates overflow their shard")
      end
      if previous = @extents.last?
        if source_start < previous.source_start + (previous.path_end - previous.path_start).to_i64
          raise CorruptPartError.new("recursive Compact site extents overlap or move backwards in whole-data coordinates")
        end
      end
      path_start = @path_data_size
      path_end = checked_add(path_start, bytes.size.to_u64)
      if path_end > Int32::MAX.to_u64
        raise CorruptPartError.new("recursive Compact inline site path exceeds the supported logical byte domain")
      end
      # Keep the shard object that was authenticated at context construction,
      # never the caller's metadata-equivalent candidate.
      @extents << Extent.new(path_start, path_end, owned_shard, source_start)
      @path_data_size = path_end
      {path_start, path_end}
    end

    def validate_path_bytes!(relative_start : UInt64, bytes : Bytes, budget : BinaryCodecBudget) : Nil
      if budget.writing?
        raise ArgumentError.new("recursive inline byte provenance requires a read-direction budget")
      end
      if relative_start > @path_data_size || bytes.size.to_u64 > @path_data_size - relative_start
        raise CorruptPartError.new("recursive inline bytes exceed their captured callback extents")
      end
      budget.ensure_wire_bytes(bytes.size.to_u64)
      budget.charge_wire_bytes(bytes.size.to_u64) if bytes.size > 0
      bytes.each_with_index do |byte, index|
        extent, local = locate_path_byte(relative_start + index.to_u64)
        unless extent.shard.byte_at((extent.source_start - extent.shard.logical_start + local.to_i64).to_i) == byte
          raise CorruptPartError.new("recursive inline bytes differ from their authenticated whole-data source")
        end
      end
      nil
    end

    def callback_position(
      pair : Tuple(UInt64, UInt64),
      relative_start : UInt64,
      relative_end : UInt64,
      allow_terminal : Bool,
    ) : Int64?
      if relative_end < relative_start || relative_end > @path_data_size
        raise CorruptPartError.new("recursive inline callback interval exceeds its captured site path")
      end
      source_position = @physical.logical_position(pair)
      selected = nil.as(UInt64?)
      @extents.each do |extent|
        candidate, source_endpoint = path_position_for_source(extent, source_position)
        next unless candidate
        next if source_endpoint && (!allow_terminal || candidate != relative_end)
        next if candidate < relative_start || candidate > relative_end
        next if candidate == relative_end && !allow_terminal
        if previous = selected
          unless previous == candidate
            raise CorruptPartError.new("recursive inline pair is ambiguous across site extents")
          end
        else
          selected = candidate
        end
      end
      if position = selected
        local = position - relative_start
        return nil if local > Int64::MAX.to_u64
        local.to_i64
      end
    end

    def same_path?(other : ObjectSharedInlineCoordinateContext) : Bool
      return false unless other.is_a?(CompactRecursiveObjectSharedInlineCoordinateContext)
      candidate = other.as(CompactRecursiveObjectSharedInlineCoordinateContext)
      return false unless @physical.same?(candidate.@physical) && @site_identity == candidate.@site_identity
      return false unless @extents.size == candidate.@extents.size
      @extents.each_with_index do |extent, index|
        other_extent = candidate.@extents[index]
        return false unless extent.path_start == other_extent.path_start &&
                            extent.path_end == other_extent.path_end &&
                            extent.source_start == other_extent.source_start &&
                            extent.shard.slot_index == other_extent.shard.slot_index &&
                            extent.shard.stream_name == other_extent.shard.stream_name &&
                            extent.shard.logical_start == other_extent.shard.logical_start &&
                            extent.shard.logical_end == other_extent.shard.logical_end
      end
      true
    end

    # Extent payload is borrowed from the authenticated parent shards; this
    # census counts the per-site mapping, not the shared physical source bytes.
    def retained_workspace_bytes : UInt64
      bytes = instance_sizeof(CompactRecursiveObjectSharedInlineCoordinateContext).to_u64
      bytes = checked_add(bytes, instance_sizeof(String).to_u64)
      bytes = checked_add(bytes, @site_identity.bytesize.to_u64 + 1_u64)
      bytes = checked_add(bytes, instance_sizeof(Array(CompactPartPhysicalShard)).to_u64)
      bytes = checked_add(bytes, checked_multiply(@parent_shards.size.to_u64, sizeof(Pointer(CompactPartPhysicalShard)).to_u64))
      bytes = checked_add(bytes, instance_sizeof(Array(Extent)).to_u64)
      checked_add(bytes, checked_multiply(@extents.size.to_u64, sizeof(Extent).to_u64))
    end

    private def authenticated_parent_shard(candidate : CompactPartPhysicalShard) : CompactPartPhysicalShard?
      @parent_shards.find do |shard|
        next false unless shard.slot_index == candidate.slot_index &&
                          shard.stream_name == candidate.stream_name &&
                          shard.logical_start == candidate.logical_start &&
                          shard.logical_end == candidate.logical_end
        next false unless shard.logical_end - shard.logical_start == candidate.logical_end - candidate.logical_start

        index = 0
        same = true
        while index.to_i64 < shard.logical_end - shard.logical_start
          unless shard.byte_at(index) == candidate.byte_at(index)
            same = false
            break
          end
          index += 1
        end
        same
      end
    end

    private def locate_path_byte(path_offset : UInt64) : Tuple(Extent, UInt64)
      @extents.each do |extent|
        if path_offset >= extent.path_start && path_offset < extent.path_end
          return {extent, path_offset - extent.path_start}
        end
      end
      raise CorruptPartError.new("recursive inline byte offset has no captured callback extent")
    end

    private def path_position_for_source(extent : Extent, source_position : Int64) : Tuple(UInt64?, Bool)
      source_end = extent.source_start + (extent.path_end - extent.path_start).to_i64
      if source_position >= extent.source_start && source_position < source_end
        return {extent.path_start + (source_position - extent.source_start).to_u64, false}
      end
      if source_position == source_end
        return {extent.path_end, true}
      end
      {nil, false}
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      if right > UInt64::MAX - left
        raise CorruptPartError.new("recursive Compact coordinate workspace overflows UInt64")
      end
      left + right
    end

    private def checked_multiply(left : UInt64, right : UInt64) : UInt64
      if left > 0_u64 && right > UInt64::MAX // left
        raise CorruptPartError.new("recursive Compact coordinate workspace overflows UInt64")
      end
      left * right
    end
  end
end
