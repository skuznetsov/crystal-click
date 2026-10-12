module CrystalClick
  # Piecewise authenticated Compact Object path over original whole-data
  # intervals. Saved pairs are never rebased; callback offsets exist only in
  # the detached path assembled from the ordered physical shards.
  class CompactObjectSharedInlineCoordinateContext < ObjectSharedInlineCoordinateContext
    @physical : CompactPartPhysicalContext
    @shards : Array(CompactPartPhysicalShard)
    @path_starts : Array(UInt64)
    @path_data_size : Int64
    @site_identity : String

    def initialize(
      @physical : CompactPartPhysicalContext,
      site_identity : String,
      shards : Array(CompactPartPhysicalShard),
    )
      if site_identity.empty?
        raise ArgumentError.new("Compact inline coordinate context requires an explicit site identity")
      end
      if shards.empty? || shards.size > Int32::MAX
        raise CorruptPartError.new("Compact inline path has no physical shards or exceeds its descriptor bound")
      end
      @site_identity = String.new(site_identity.to_slice)

      # Authenticate exact slot intervals and detached payload bytes against
      # this part before retaining callback provenance. A caller-constructed
      # shard cannot gain authority from coordinates alone.
      @physical.validate_shard_provenance!(shards)

      @shards = shards.dup
      @path_starts = Array(UInt64).new(shards.size)
      path_size = 0_u64
      shards.each do |shard|
        @path_starts << path_size
        size = (shard.logical_end - shard.logical_start).to_u64
        if size > UInt64::MAX - path_size
          raise CorruptPartError.new("Compact inline path byte extent overflows UInt64")
        end
        path_size += size
      end
      if path_size > Int32::MAX.to_u64
        raise CorruptPartError.new("Compact inline path exceeds the supported logical byte domain")
      end
      @path_data_size = path_size.to_i64
    end

    # String is mutable, so callers receive an owned snapshot rather than the
    # identity retained by this provenance context.
    def site_identity : String
      String.new(@site_identity.to_slice)
    end

    def path_data_size : Int64
      @path_data_size
    end

    # Bind a prepared MRK3 Object site to this exact retained whole-column
    # shard and its selected mark-grid interval without rereading payload data.
    def validate_mrk3_site!(column_name : String, physical_prefix : String, mark_index : Int) : Nil
      @physical.validate_mrk3_site!(column_name, physical_prefix, mark_index, @shards)
    end

    # Verifies a callback payload against the authenticated, piecewise shard
    # view without concatenating the original source intervals.
    def validate_path_bytes!(relative_start : UInt64, bytes : Bytes, budget : BinaryCodecBudget) : Nil
      if budget.writing?
        raise ArgumentError.new("inline byte provenance requires a read-direction budget")
      end
      path_size = @path_data_size.to_u64
      if relative_start > path_size || bytes.size.to_u64 > path_size - relative_start
        raise CorruptPartError.new("inline bytes exceed their authenticated Compact path interval")
      end

      byte_count = bytes.size.to_u64
      budget.ensure_wire_bytes(byte_count)
      budget.charge_wire_bytes(byte_count) if byte_count > 0_u64
      bytes.each_with_index do |byte, index|
        path_offset = relative_start + index.to_u64
        shard_index, shard_offset = locate_path_byte(path_offset)
        unless @shards[shard_index].byte_at(shard_offset) == byte
          raise CorruptPartError.new("inline bytes differ from their authenticated Compact shard intervals")
        end
      end
      nil
    end

    # Resolves a persisted pair in the original Compact data.bin domain, then
    # narrows it to this callback's path-relative interval. Interior bytes may
    # start a later callback; source endpoints and empty points may only be
    # consumed as the designated final callback terminal.
    def callback_position(
      pair : Tuple(UInt64, UInt64),
      relative_start : UInt64,
      relative_end : UInt64,
      allow_terminal : Bool,
    ) : Int64?
      if relative_end < relative_start || relative_end > @path_data_size.to_u64
        raise CorruptPartError.new("Compact inline callback interval is outside its authenticated path")
      end
      source_position = @physical.logical_position(pair)
      selected = nil.as(UInt64?)
      @shards.each_with_index do |shard, index|
        candidate, source_endpoint = path_position_for_source(shard, @path_starts[index], source_position)
        next unless candidate
        # A whole-source interval end (including an empty interval) must not
        # alias the next callback's path-relative start. Only the designated
        # final callback may consume such a point, and only as its terminal.
        next if source_endpoint && (!allow_terminal || candidate != relative_end)
        next if candidate < relative_start || candidate > relative_end
        next if candidate == relative_end && !allow_terminal

        if previous = selected
          unless previous == candidate
            raise CorruptPartError.new("Compact inline coordinate is ambiguous across repeated shard intervals")
          end
        else
          selected = candidate
        end
      end
      if position = selected
        local = position - relative_start
        return nil if local > Int64::MAX.to_u64
        local.to_i64
      else
        nil
      end
    end

    def same_path?(other : ObjectSharedInlineCoordinateContext) : Bool
      return false unless other.is_a?(CompactObjectSharedInlineCoordinateContext)
      compact = other.as(CompactObjectSharedInlineCoordinateContext)
      return false unless @physical.same?(compact.@physical)
      return false unless @site_identity == compact.@site_identity
      return false unless @shards.size == compact.@shards.size

      @shards.each_with_index do |shard, index|
        candidate = compact.@shards[index]
        return false unless shard.slot_index == candidate.slot_index &&
                            shard.stream_name == candidate.stream_name &&
                            shard.logical_start == candidate.logical_start &&
                            shard.logical_end == candidate.logical_end
      end
      true
    end

    # Logical retained-owner census for this piecewise path. The context keeps
    # shard references alive, so count each retained shard object and its
    # copied byte/name storage even if the caller drops the physical window.
    # This is based on logical sizes, not allocator capacity or RSS; the
    # physical context's transitive source/grid graph remains accounted by its
    # own owner and is not traversed here.
    def retained_workspace_bytes : UInt64
      bytes = instance_sizeof(CompactObjectSharedInlineCoordinateContext).to_u64
      bytes = checked_add(bytes, instance_sizeof(String).to_u64)
      bytes = checked_add(bytes, @site_identity.bytesize.to_u64)
      bytes = checked_add(bytes, 1_u64)
      bytes = checked_add(bytes, instance_sizeof(Array(CompactPartPhysicalShard)).to_u64)
      bytes = checked_add(
        bytes,
        checked_multiply(@shards.size.to_u64, sizeof(Pointer(CompactPartPhysicalShard)).to_u64),
      )
      @shards.each do |shard|
        bytes = checked_add(bytes, shard.retained_workspace_bytes)
      end
      bytes = checked_add(bytes, instance_sizeof(Array(UInt64)).to_u64)
      checked_add(bytes, checked_multiply(@path_starts.size.to_u64, sizeof(UInt64).to_u64))
    end

    private def locate_path_byte(path_offset : UInt64) : Tuple(Int32, Int32)
      @shards.each_with_index do |shard, index|
        start = @path_starts[index]
        finish = start + (shard.logical_end - shard.logical_start).to_u64
        if path_offset >= start && path_offset < finish
          return {index, (path_offset - start).to_i}
        end
      end
      raise CorruptPartError.new("Compact inline byte offset has no authenticated shard owner")
    end

    private def path_position_for_source(
      shard : CompactPartPhysicalShard,
      path_start : UInt64,
      source_position : Int64,
    ) : Tuple(UInt64?, Bool)
      start = shard.logical_start
      finish = shard.logical_end
      if source_position >= start && source_position < finish
        return {path_start + (source_position - start).to_u64, false}
      end
      if start == finish && source_position == start
        return {path_start, true}
      end
      if source_position == finish
        {path_start + (finish - start).to_u64, true}
      else
        {nil, false}
      end
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      raise CorruptPartError.new("Compact inline context workspace estimate overflows UInt64") if right > UInt64::MAX - left
      left + right
    end

    private def checked_multiply(left : UInt64, right : UInt64) : UInt64
      if left > 0_u64 && right > UInt64::MAX // left
        raise CorruptPartError.new("Compact inline context workspace estimate overflows UInt64")
      end
      left * right
    end
  end
end
