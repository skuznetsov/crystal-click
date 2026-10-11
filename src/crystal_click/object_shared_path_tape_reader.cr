module CrystalClick
  OBJECT_SHARED_PATH_LOW_CARDINALITY_VERSION_BYTES = 8_i32

  # Bounded cursor for the ordered, decompressed Data substream callback tape.
  # It keeps lane slices borrowed until each lane's detached owner is
  # preflighted and constructed.
  class ObjectSharedPathTapeReader < ObjectSharedPathCallbackSource
    @data : Bytes
    @events : Array(ObjectSharedPathSubstreamEvent)
    @budget : BinaryCodecBudget
    @coordinate_context : ObjectSharedInlineCoordinateContext?
    @cursor : UInt64
    @event_index : Int32
    @structure_bytes : Hash(String, Bytes)
    @structures : Hash(String, DynamicStructure)
    @discriminator_prefixes : Hash(String, Bytes)
    @low_cardinality_prefixes : Hash(String, Bytes)
    @lanes : Hash(String, BinaryBulkStream)

    def initialize(
      @data : Bytes,
      @events : Array(ObjectSharedPathSubstreamEvent),
      @budget : BinaryCodecBudget,
      @coordinate_context : ObjectSharedInlineCoordinateContext? = nil,
    )
      @cursor = 0_u64
      @event_index = 0_i32
      @structure_bytes = Hash(String, Bytes).new
      @structures = Hash(String, DynamicStructure).new
      @discriminator_prefixes = Hash(String, Bytes).new
      @low_cardinality_prefixes = Hash(String, Bytes).new
      @lanes = Hash(String, BinaryBulkStream).new
      if context = @coordinate_context
        unless context.path_data_size == @data.size
          raise CorruptPartError.new("Object shared path tape coordinate context does not match its Data extent")
        end
        context.validate_path_bytes!(0_u64, @data, @budget)
      end

      previous = 0_u64
      name_work = 0_u64
      @events.each_with_index do |event, index|
        offset = event.relative_offset
        if offset > @data.size.to_u64 || offset < previous
          raise CorruptPartError.new("Object shared path event offsets are outside or reorder the Data slice")
        end
        if index == 0 && offset != 0_u64
          raise CorruptPartError.new("Object shared path event tape does not start at byte zero")
        end
        previous = offset
        name_size = event.name_byte_size.to_u64
        if name_size > UInt64::MAX - name_work
          raise CorruptPartError.new("Object shared path event-name work overflows UInt64")
        end
        name_work += name_size
      end

      event_count = @events.size.to_u64
      if event_count > UInt64::MAX - name_work
        raise CorruptPartError.new("Object shared path event work overflows UInt64")
      end
      total_event_work = event_count + name_work
      @budget.ensure_future_nodes(event_count)
      @budget.ensure_future_elements(total_event_work)
      @budget.charge_elements(total_event_work)
      event_count.times { @budget.charge_node }
    end

    def take(expected_name : String) : Bytes
      ensure_no_active_parser!
      _event, following, bytes = current_event(expected_name)
      commit_event!(following)
      bytes
    end

    protected def borrow_self_delimited(expected_name : String) : Bytes
      current_event(expected_name)[2]
    end

    protected def commit_self_delimited(expected_name : String, consumed : Int32) : Nil
      _event, following, bytes = current_event(expected_name)
      unless consumed == bytes.size
        raise CorruptPartError.new("Object shared path parser did not consume its exact callback interval")
      end
      commit_event!(following)
      nil
    end

    # Fixed-size callbacks are validated before the event cursor is advanced.
    # This keeps discriminator and LowCardinality prefixes exact even when a
    # malformed event is followed by an otherwise valid callback.
    def take_exact(expected_name : String, size : Int32) : Bytes
      ensure_no_active_parser!
      if size < 0
        raise CorruptPartError.new("Object shared path fixed callback size is negative")
      end
      _event, following, bytes = current_event(expected_name)
      unless bytes.size == size
        raise CorruptPartError.new("Object shared path fixed callback has the wrong byte extent")
      end
      commit_event!(following)
      bytes
    end

    # Consumes one named inline child Object callback from this same ordered
    # Data tape. This is deliberately only an alias: inline fragments do not
    # get a secondary cursor or a relaxed name/offset check.
    def take_inline_fragment(expected_name : String) : Bytes
      take(expected_name)
    end

    # Takes one exact callback event and retains its verified path-relative
    # interval plus the canonical/raw callback-name pairing. The payload is a
    # borrowed view into this tape's authenticated Data slice.
    def take_inline_fragment_slice(
      canonical_name : String,
      callback_name : String,
    ) : ObjectSharedInlineCallbackReadSlice
      if canonical_name.empty? || callback_name.empty?
        raise CorruptPartError.new("inline callback slice name is empty")
      end
      start = @cursor
      bytes = take(callback_name)
      finish = @cursor
      name_work = canonical_name.bytesize.to_u64 + callback_name.bytesize.to_u64
      @budget.preflight_children(1_u64)
      @budget.charge_wire_bytes(name_work)
      @budget.charge_node
      ObjectSharedInlineCallbackReadSlice.new(
        canonical_name,
        callback_name,
        start,
        finish,
        bytes,
        @coordinate_context,
        @budget,
      )
    end

    def add_structure(path : String, bytes : Bytes, structure : DynamicStructure) : Nil
      if @structure_bytes.has_key?(path) || @structures.has_key?(path)
        raise CorruptPartError.new("Object shared path Dynamic structure site is duplicated")
      end
      path_work = path.bytesize.to_u64
      @budget.ensure_future_elements(path_work + 1_u64)
      @budget.charge_elements(path_work + 1_u64)
      @structure_bytes[path] = bytes
      @structures[path] = structure
      nil
    end

    def add_discriminator_prefix(role : String, prefix_name : String) : Nil
      if @discriminator_prefixes.has_key?(role)
        raise CorruptPartError.new("Object shared path discriminator prefix is duplicated")
      end
      prefix = take_exact(prefix_name, BinaryBulkDiscriminatorFramingAdapter::PREFIX_BYTES)
      @discriminator_prefixes[role] = prefix
      nil
    end

    def add_discriminator_body(role : String, body_name : String) : Nil
      prefix = @discriminator_prefixes.delete(role) || raise(CorruptPartError.new("Object shared path discriminator body has no prefix"))
      body = take(body_name)
      if body.size > Int32::MAX - prefix.size
        raise CorruptPartError.new("Object shared path discriminator lane exceeds the supported byte domain")
      end
      physical_size = prefix.size + body.size
      @budget.ensure_wire_bytes(physical_size.to_u64)
      @budget.ensure_future_elements(physical_size.to_u64 + 2_u64)
      @budget.charge_wire_bytes(physical_size.to_u64)
      @budget.charge_elements(physical_size.to_u64 + 2_u64)
      physical = Bytes.new(physical_size) do |index|
        index < prefix.size ? prefix[index] : body[index - prefix.size]
      end

      mode = BinaryBulkDiscriminatorFramingAdapter.validate_header(
        role,
        physical,
        BinaryBulkDiscriminatorFramingAdapter::PREFIX_BYTES,
      )
      unless mode == DynamicDiscriminatorBodyValidator::COMPACT_MODE
        raise CorruptPartError.new("Object shared path discriminator mode is not COMPACT")
      end

      # The adapter consumes one bounded mark. This path is one exact chunk,
      # so the interval is all remaining COMPACT frames after the UInt64 mode.
      @budget.ensure_wire_bytes(BinaryBulkDiscriminatorFramingAdapter::PREFIX_BYTES.to_u64)
      @budget.ensure_future_elements(2_u64)
      @budget.charge_wire_bytes(BinaryBulkDiscriminatorFramingAdapter::PREFIX_BYTES.to_u64)
      @budget.charge_elements(2_u64)
      offsets = Array(UInt64).new(2)
      offsets << BinaryBulkDiscriminatorFramingAdapter::PREFIX_BYTES.to_u64
      offsets << physical_size.to_u64
      logical = BinaryBulkDiscriminatorFramingAdapter.read_lane(
        role,
        physical,
        offsets,
        BinaryBulkDiscriminatorFramingAdapter::PREFIX_BYTES,
        @budget,
      )
      add_lane(role, logical[0], logical[1])
      nil
    end

    def add_low_cardinality_dictionary_prefix(role : String, prefix_name : String) : Nil
      if @low_cardinality_prefixes.has_key?(role)
        raise CorruptPartError.new("Object shared path LowCardinality dictionary prefix is duplicated")
      end
      if @lanes.has_key?(role)
        raise CorruptPartError.new("Object shared path LowCardinality dictionary lane is duplicated")
      end

      prefix = take_exact(prefix_name, OBJECT_SHARED_PATH_LOW_CARDINALITY_VERSION_BYTES)

      # Retain only the borrowed eight-byte prefix. Bound the pending-site
      # table and role key before making the entry visible to the body pass.
      retained_work = role.bytesize.to_u64 + 1_u64
      @budget.ensure_future_nodes(1_u64)
      @budget.ensure_future_elements(retained_work)
      @budget.charge_node
      @budget.charge_elements(retained_work)
      @low_cardinality_prefixes[role] = prefix
      nil
    end

    def add_low_cardinality_dictionary_body(role : String, body_name : String) : Nil
      prefix = @low_cardinality_prefixes[role]? || raise(CorruptPartError.new("Object shared path LowCardinality dictionary body has no prefix"))
      if @lanes.has_key?(role)
        raise CorruptPartError.new("Object shared path LowCardinality dictionary lane is duplicated")
      end

      body = take(body_name)
      if body.size > Int32::MAX - prefix.size
        raise CorruptPartError.new("Object shared path LowCardinality dictionary lane exceeds the supported byte domain")
      end
      physical_size = prefix.size + body.size
      physical_bytes = physical_size.to_u64
      lane_work = physical_bytes + 2_u64
      total_wire_work = physical_bytes * 2_u64
      total_element_work = lane_work * 2_u64

      # The join buffer and BinaryBulkStream's detached owner are both
      # proportional allocations. Preflight both before constructing either;
      # add_lane performs the second charge after the first buffer exists.
      @budget.ensure_wire_bytes(total_wire_work)
      @budget.ensure_future_elements(total_element_work)
      @budget.charge_wire_bytes(physical_bytes)
      @budget.charge_elements(lane_work)

      physical = Bytes.new(physical_size) do |index|
        index < prefix.size ? prefix[index] : body[index - prefix.size]
      end
      offsets = [OBJECT_SHARED_PATH_LOW_CARDINALITY_VERSION_BYTES.to_u64, physical_size.to_u64] of UInt64
      add_lane(role, physical, offsets)
      @low_cardinality_prefixes.delete(role)
      nil
    end

    def add_lane(role : String, bytes : Bytes) : Nil
      if @lanes.has_key?(role)
        raise CorruptPartError.new("Object shared path lane role is duplicated")
      end
      add_lane(role, bytes, [0_u64, bytes.size.to_u64] of UInt64)
      nil
    end

    def finish! : Nil
      unless @event_index == @events.size && @cursor == @data.size.to_u64
        raise CorruptPartError.new("Object shared path event tape does not consume the complete Data slice")
      end
      unless @discriminator_prefixes.empty?
        raise CorruptPartError.new("Object shared path discriminator prefix has no matching body")
      end
      unless @low_cardinality_prefixes.empty?
        raise CorruptPartError.new("Object shared path LowCardinality dictionary prefix has no matching body")
      end
      nil
    end

    def build_structure_streams : BinaryDynamicStructureStreams
      total_bytes = 0_u64
      path_bytes = 0_u64
      @structure_bytes.each do |path, bytes|
        size = bytes.size.to_u64
        if size > UInt64::MAX - total_bytes || path.bytesize.to_u64 > UInt64::MAX - path_bytes
          raise CorruptPartError.new("Object shared path structure-copy work overflows UInt64")
        end
        total_bytes += size
        path_bytes += path.bytesize.to_u64
      end
      @budget.ensure_wire_bytes(total_bytes)
      @budget.ensure_future_elements(path_bytes + @structure_bytes.size.to_u64)
      @budget.charge_wire_bytes(total_bytes)
      @budget.charge_elements(path_bytes + @structure_bytes.size.to_u64)
      BinaryDynamicStructureStreams.new(@structure_bytes)
    end

    def structures : Hash(String, DynamicStructure)
      @structures
    end

    def structure_for(path : String) : DynamicStructure
      @structures[path]? || raise(CorruptPartError.new("Object shared path Dynamic structure site is missing"))
    end

    def bulk_streams : BinaryBulkStreams
      role_count = @lanes.size.to_u64
      path_work = 0_u64
      @lanes.each_key do |role|
        size = role.bytesize.to_u64
        if size > UInt64::MAX - path_work
          raise CorruptPartError.new("Object shared path role-copy work overflows UInt64")
        end
        path_work += size
      end
      @budget.ensure_future_elements(path_work + role_count)
      @budget.charge_elements(path_work + role_count)
      BinaryBulkStreams.new(1, @lanes)
    end

    private def add_lane(role : String, bytes : Bytes, offsets : Array(UInt64)) : Nil
      if @lanes.has_key?(role)
        raise CorruptPartError.new("Object shared path lane role is duplicated")
      end
      byte_count = bytes.size.to_u64
      @budget.ensure_wire_bytes(byte_count)
      @budget.ensure_future_elements(byte_count + offsets.size.to_u64)
      @budget.charge_wire_bytes(byte_count)
      @budget.charge_elements(byte_count + offsets.size.to_u64)
      @lanes[role] = BinaryBulkStream.new(bytes, offsets)
      nil
    end

    private def current_event(expected_name : String) : Tuple(ObjectSharedPathSubstreamEvent, UInt64, Bytes)
      event = @events[@event_index]? || raise(CorruptPartError.new("Object shared path event tape is truncated"))
      unless event.matches_name?(expected_name)
        raise CorruptPartError.new("Object shared path event name or order is invalid")
      end
      unless event.relative_offset == @cursor
        raise CorruptPartError.new("Object shared path event offset disagrees with the consumed Data cursor")
      end

      following = if next_event = @events[@event_index + 1]?
                    next_event.relative_offset
                  else
                    @data.size.to_u64
                  end
      if following < @cursor || following > @data.size.to_u64
        raise CorruptPartError.new("Object shared path event interval is outside the Data slice")
      end
      size = following - @cursor
      if size > Int32::MAX.to_u64
        raise CorruptPartError.new("Object shared path event interval exceeds the supported byte domain")
      end
      {event, following, @data[@cursor.to_i32, size.to_i32]}
    end

    private def commit_event!(following : UInt64) : Nil
      @cursor = following
      @event_index += 1
      nil
    end
  end
end
