module CrystalClick
  # Bounded cursor for the ordered, decompressed Data substream callback tape.
  # It keeps lane slices borrowed until each lane's detached owner is
  # preflighted and constructed.
  class ObjectSharedPathTapeReader
    @data : Bytes
    @events : Array(ObjectSharedPathSubstreamEvent)
    @budget : BinaryCodecBudget
    @cursor : UInt64
    @event_index : Int32
    @structure_bytes : Hash(String, Bytes)
    @structures : Hash(String, DynamicStructure)
    @discriminator_prefixes : Hash(String, Bytes)
    @lanes : Hash(String, BinaryBulkStream)

    def initialize(
      @data : Bytes,
      @events : Array(ObjectSharedPathSubstreamEvent),
      @budget : BinaryCodecBudget,
    )
      @cursor = 0_u64
      @event_index = 0_i32
      @structure_bytes = Hash(String, Bytes).new
      @structures = Hash(String, DynamicStructure).new
      @discriminator_prefixes = Hash(String, Bytes).new
      @lanes = Hash(String, BinaryBulkStream).new

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
      bytes = @data[@cursor.to_i32, size.to_i32]
      @cursor = following
      @event_index += 1
      bytes
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
      prefix = take(prefix_name)
      unless prefix.size == BinaryBulkDiscriminatorFramingAdapter::PREFIX_BYTES
        raise CorruptPartError.new("Object shared path discriminator prefix is not eight bytes")
      end
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
  end
end
