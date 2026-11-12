module CrystalClick
  # Per-parent-mark staging area for one opaque recursive Bulk site. Physical
  # lane and prefix views borrow the parent ledger; COMPACT Variant tags may
  # retain a separately budgeted expansion. Detached BinaryBulkStream copies
  # consume element budget rather than charging the physical input again.
  class CompactRecursiveJsonBulkMark
    @site : CompactRecursiveJsonBulkSite
    @lanes : Array(Bytes)
    @state_prefixes : Array(Bytes?)?
    @built : Bool

    private def initialize(@site : CompactRecursiveJsonBulkSite, role_count : Int32)
      @lanes = Array(Bytes).new(role_count)
      prefix_count = @site.prefix_role_count
      @state_prefixes = prefix_count > 0 ? Array(Bytes?).new(prefix_count) : nil
      @built = false
    end

    # Charge the holder, its borrowed-lane reference array, and one edge per
    # expected lane before allocating either proportional owner.
    def self.open(site : CompactRecursiveJsonBulkSite, budget : BinaryCodecBudget) : CompactRecursiveJsonBulkMark
      role_count = site.role_count
      if role_count < 0
        raise CorruptPartError.new("Compact recursive Bulk role count is negative")
      end
      prefix_count = site.prefix_role_count
      owner_nodes = 2_u64
      owner_elements = role_count.to_u64
      if prefix_count > 0
        owner_nodes += 1_u64
        owner_elements += prefix_count.to_u64
      end
      # Preflight all holder and reference ownership together. A failure in
      # the state-prefix allowance must not leave base mark charges committed.
      budget.ensure_future_nodes(owner_nodes)
      budget.ensure_future_elements(owner_elements)
      owner_nodes.times { budget.charge_node }
      budget.charge_elements(owner_elements) if owner_elements > 0_u64
      new(site, role_count)
    end

    # Prefix bytes remain borrowed from the authenticated parent mark until
    # detached BinaryBulkStream packaging. No intermediate concatenated lane
    # or copied prefix owner is created here.
    def capture_state_prefix!(
      role : String,
      kind : CompactRecursiveJsonBulkSite::StatePrefixKind,
      bytes : Bytes,
    ) : Nil
      if @built
        raise CorruptPartError.new("Compact recursive Bulk mark was already packaged")
      end
      prefixes = @state_prefixes ||
                 raise(CorruptPartError.new("Compact recursive Bulk mark has no state-prefix owner"))
      if prefixes.size >= @site.prefix_role_count
        raise CorruptPartError.new("Compact recursive Bulk prefix capture exceeded its frozen schema roster")
      end
      expected = @site.prefix_role_at(prefixes.size)
      unless @site.role_at(expected.role_index).name == role
        raise CorruptPartError.new("Compact recursive Bulk prefix capture differs from its frozen schema DFS")
      end
      unless expected.kind == kind
        raise CorruptPartError.new("Compact recursive Bulk prefix kind differs from its frozen schema descriptor")
      end
      unless bytes.size == 8
        raise CorruptPartError.new("Compact recursive Bulk state prefix has the wrong extent")
      end
      prefixes << bytes
      nil
    end

    def state_prefix_for_role(
      role : String,
      kind : CompactRecursiveJsonBulkSite::StatePrefixKind,
    ) : Bytes
      prefix_index = @site.prefix_role_index(role) ||
                     raise(CorruptPartError.new("Compact recursive Bulk role has no state-prefix descriptor"))
      prefix_role = @site.prefix_role_at(prefix_index)
      unless prefix_role.kind == kind
        raise CorruptPartError.new("Compact recursive Bulk state-prefix kind differs from its frozen schema descriptor")
      end
      prefixes = @state_prefixes ||
                 raise(CorruptPartError.new("Compact recursive Bulk mark has no state-prefix owner"))
      prefixes[prefix_index]? ||
        raise(CorruptPartError.new("Compact recursive Bulk state prefix is missing from its parent mark"))
    end

    # Keep the captured lanes bound to the site serializer's DFS roster. These
    # slices are borrowed from the authenticated parent mark, not detached
    # stream owners.
    def capture_lane(role : String, bytes : Bytes) : Nil
      if @built
        raise CorruptPartError.new("Compact recursive Bulk mark was already packaged")
      end
      if @lanes.size >= @site.role_count
        raise CorruptPartError.new("Compact recursive Bulk role capture exceeded its frozen serializer DFS")
      end
      expected_role = @site.role_at(@lanes.size).name
      unless role == expected_role
        raise CorruptPartError.new("Compact recursive Bulk role capture differs from its frozen serializer DFS")
      end
      @lanes << bytes
      nil
    end

    # Preflight the complete detached packaging graph before constructing its
    # hashes, copied keys, streams, offset arrays, or copied lane bytes.
    def build_streams(budget : BinaryCodecBudget) : BinaryBulkStreams
      if @built
        raise CorruptPartError.new("Compact recursive Bulk mark was already packaged")
      end
      unless @lanes.size == @site.role_count
        raise CorruptPartError.new("Compact recursive Bulk role capture differs from its frozen serializer DFS")
      end
      prefixes = @state_prefixes
      unless (prefixes.try(&.size) || 0) == @site.prefix_role_count
        raise CorruptPartError.new("Compact recursive Bulk state-prefix capture differs from its frozen schema DFS")
      end

      owned_lane_bytes = 0_u64
      @lanes.each do |bytes|
        owned_lane_bytes = checked_add(owned_lane_bytes, bytes.size.to_u64)
      end
      if prefixes
        prefixes.each_with_index do |bytes, index|
          prefix = bytes || raise(CorruptPartError.new("Compact recursive Bulk state prefix is missing"))
          prefix_role = @site.prefix_role_at(index)
          if prefix_role.kind == CompactRecursiveJsonBulkSite::StatePrefixKind::LowCardinalityDictionaryV1
            owned_lane_bytes = checked_add(owned_lane_bytes, prefix.size.to_u64)
          end
        end
      end
      one_roster_key_bytes = 0_u64
      @site.each_role do |role|
        # String storage includes its trailing NUL, as in the retained-workspace
        # accounting used by the other Compact recursive owners.
        one_roster_key_bytes = checked_add(one_roster_key_bytes, role.name.bytesize.to_u64 + 1_u64)
      end
      self.class.preflight_packaging!(@site.role_count, owned_lane_bytes, one_roster_key_bytes, budget)
      @built = true

      # Output owners: source Hash + BinaryBulkStreams wrapper + its internal
      # Hash (3); per role, source key + BinaryBulkStream + literal offsets +
      # duplicated offsets + detached internal key (5). Output elements: four
      # Hash key/value slots and four offset values per role, copied lane bytes,
      # and both detached role-key byte strings.
      # The separate borrowed-lane staging owner and its N references were
      # charged by open before capture began.
      streams = Hash(String, BinaryBulkStream).new(initial_capacity: @site.role_count)
      @lanes.each_with_index do |bytes, index|
        role = @site.role_at(index).name
        source_key = String.new(role.to_slice)
        if streams.has_key?(source_key)
          raise CorruptPartError.new("Compact recursive Bulk serializer repeated a physical role")
        end
        if prefix_index = @site.prefix_role_index(role)
          prefix_role = @site.prefix_role_at(prefix_index)
          case prefix_role.kind
          when CompactRecursiveJsonBulkSite::StatePrefixKind::LowCardinalityDictionaryV1
            unless bytes.empty?
              raise CorruptPartError.new("Compact recursive Bulk LowCardinality dictionary body is not empty")
            end
            prefix = state_prefix_for_role(role, prefix_role.kind)
            streams[source_key] = BinaryBulkStream.new(prefix, [8_u64, 8_u64])
          when CompactRecursiveJsonBulkSite::StatePrefixKind::VariantDiscriminatorMode
            end_offset = bytes.size.to_u64
            streams[source_key] = BinaryBulkStream.new(bytes, [0_u64, end_offset])
          end
        else
          end_offset = bytes.size.to_u64
          streams[source_key] = BinaryBulkStream.new(bytes, [0_u64, end_offset])
        end
      end
      BinaryBulkStreams.new(1, streams)
    end

    # Public as a narrow, allocation-free seam so exact and one-below limits
    # can independently exercise the guard used by build_streams.
    def self.preflight_packaging!(
      role_count : Int32,
      owned_lane_bytes : UInt64,
      one_roster_key_bytes : UInt64,
      budget : BinaryCodecBudget,
    ) : Nil
      if role_count < 0
        raise CorruptPartError.new("Compact recursive Bulk role count is negative")
      end
      roles = role_count.to_u64
      owner_nodes = checked_add(3_u64, checked_multiply(roles, 5_u64))
      hash_slots_and_offsets = checked_multiply(roles, 8_u64)
      detached_key_bytes = checked_multiply(one_roster_key_bytes, 2_u64)
      owner_elements = checked_add(
        checked_add(hash_slots_and_offsets, owned_lane_bytes), detached_key_bytes
      )

      # Check all dimensions before changing the shared operation budget.
      budget.ensure_future_nodes(owner_nodes)
      budget.ensure_future_elements(owner_elements)
      owner_nodes.to_i64.times { budget.charge_node }
      budget.charge_elements(owner_elements) if owner_elements > 0_u64
      nil
    end

    private def self.checked_add(left : UInt64, right : UInt64) : UInt64
      if right > UInt64::MAX - left
        raise CorruptPartError.new("Compact recursive Bulk packaging budget overflows UInt64")
      end
      left + right
    end

    private def self.checked_multiply(left : UInt64, right : UInt64) : UInt64
      if left > 0_u64 && right > UInt64::MAX // left
        raise CorruptPartError.new("Compact recursive Bulk packaging budget overflows UInt64")
      end
      left * right
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      if right > UInt64::MAX - left
        raise CorruptPartError.new("Compact recursive Bulk lane-byte sum overflows UInt64")
      end
      left + right
    end
  end
end
