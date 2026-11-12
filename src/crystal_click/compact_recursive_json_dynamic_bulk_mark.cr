module CrystalClick
  # Per-parent-mark borrowed Dynamic lane staging. Callback identity and order
  # remain owned by the parent ledger; this adapter only binds logical Bulk
  # roles and their eight-byte LC/Variant state prefixes.
  class CompactRecursiveJsonDynamicBulkMark
    alias StatePrefixKind = CompactRecursiveJsonBulkSite::StatePrefixKind

    @plan : CompactRecursiveJsonDynamicBulkCapturePlan
    @lanes : Hash(String, Bytes)
    @lane_order : Array(String)
    @state_prefixes : Hash(String, Tuple(StatePrefixKind, Bytes))
    @prefix_order : Array(String)
    @built : Bool

    def initialize(@plan : CompactRecursiveJsonDynamicBulkCapturePlan, budget : BinaryCodecBudget)
      role_count = @plan.data_role_count
      if role_count > Int32::MAX.to_u64
        raise CorruptPartError.new("recursive Compact Dynamic data-role roster exceeds Int32")
      end
      prefix_count = @plan.prefix_callback_count - 1 # The first callback is the DynamicStructure.
      if prefix_count < 0
        raise CorruptPartError.new("recursive Compact Dynamic prefix roster omits its structure callback")
      end

      # The mark holder and its four proportional containers are charged
      # together before any role-key or callback-key copies are created.
      owner_nodes = 5_u64
      owner_elements = checked_multiply(role_count, 3_u64)
      owner_elements = checked_add(owner_elements, checked_multiply(prefix_count.to_u64, 3_u64))
      detached_key_bytes = 0_u64
      @plan.each_data_role do |role|
        copies = @plan.physical_plan.prefix_size_for(role) > 0 ? 3_u64 : 2_u64
        detached_key_bytes = checked_add(
          detached_key_bytes,
          checked_multiply(role.bytesize.to_u64 + 1_u64, copies),
        )
      end
      (1...@plan.prefix_callback_count).each do |index|
        callback = @plan.prefix_callback_at(index)
        detached_key_bytes = checked_add(detached_key_bytes, callback.bytesize.to_u64 + 1_u64)
      end
      owner_elements = checked_add(owner_elements, detached_key_bytes)
      budget.ensure_future_nodes(owner_nodes)
      budget.ensure_future_elements(owner_elements)
      owner_nodes.times { budget.charge_node }
      budget.charge_elements(owner_elements) if owner_elements > 0_u64
      @lanes = Hash(String, Bytes).new(initial_capacity: role_count.to_i)
      @lane_order = Array(String).new(role_count.to_i)
      @state_prefixes = Hash(String, Tuple(StatePrefixKind, Bytes)).new(initial_capacity: prefix_count)
      @prefix_order = Array(String).new(prefix_count)
      @built = false
    end

    def physical_plan : BinaryDynamicBulkPhysicalPlan
      @plan.physical_plan
    end

    def capture_state_prefix!(role : String, kind : StatePrefixKind, bytes : Bytes) : Nil
      unless !@built && bytes.size == BinaryBulkDiscriminatorFramingAdapter::PREFIX_BYTES
        raise CorruptPartError.new("recursive Compact Dynamic state prefix has an invalid lifecycle or extent")
      end
      unless @plan.physical_plan.prefix_size_for(role) == BinaryBulkDiscriminatorFramingAdapter::PREFIX_BYTES
        raise CorruptPartError.new("recursive Compact Dynamic state prefix is outside its physical plan")
      end
      expected_kind = if role.ends_with?(".dictionary")
                        StatePrefixKind::LowCardinalityDictionaryV1
                      elsif role.ends_with?(".discriminators")
                        StatePrefixKind::VariantDiscriminatorMode
                      else
                        raise CorruptPartError.new("recursive Compact Dynamic prefix role has no admitted kind")
                      end
      unless expected_kind == kind && !@state_prefixes.has_key?(role)
        raise CorruptPartError.new("recursive Compact Dynamic state prefix differs from its role or repeats")
      end
      expected_index = @prefix_order.size + 1
      if expected_index >= @plan.prefix_callback_count
        raise CorruptPartError.new("recursive Compact Dynamic state prefix exceeds its frozen callback roster")
      end
      expected_callback = @plan.prefix_callback_at(expected_index)
      unless @plan.prefix_callback_name_for(role) == expected_callback
        raise CorruptPartError.new("recursive Compact Dynamic prefix capture differs from its frozen serializer DFS")
      end
      if kind == StatePrefixKind::LowCardinalityDictionaryV1
        version = 0_u64
        8.times { |index| version |= bytes[index].to_u64 << (index * 8) }
        unless version == BinaryLowCardinalityStorageStreams::VERSION
          raise UnsupportedFormatError.new("unsupported Compact LowCardinality state-prefix version")
        end
      else
        BinaryBulkDiscriminatorFramingAdapter.validate_header(role, bytes, bytes.size)
      end
      @state_prefixes[String.new(role.to_slice)] = {kind, bytes}
      @prefix_order << String.new(@plan.prefix_callback_name_for(role).to_slice)
      nil
    end

    def state_prefix_for_role(role : String, kind : StatePrefixKind) : Bytes
      captured_kind, bytes = @state_prefixes[role]? ||
                             raise(CorruptPartError.new("recursive Compact Dynamic state prefix is missing"))
      unless captured_kind == kind
        raise CorruptPartError.new("recursive Compact Dynamic state-prefix kind differs from its schema role")
      end
      bytes
    end

    def capture_lane(role : String, bytes : Bytes) : Nil
      unless !@built
        raise CorruptPartError.new("recursive Compact Dynamic mark was already packaged")
      end
      if @lane_order.size.to_u64 >= @plan.data_role_count
        raise CorruptPartError.new("recursive Compact Dynamic lane exceeds its frozen body roster")
      end
      expected_role = @plan.body_role_at(@lane_order.size)
      unless role == expected_role && !@lanes.has_key?(role)
        raise CorruptPartError.new("recursive Compact Dynamic lane capture differs from its frozen serializer DFS")
      end
      @lanes[String.new(role.to_slice)] = bytes
      @lane_order << String.new(role.to_slice)
      nil
    end

    def prefix_callbacks(budget : BinaryCodecBudget) : Array(String)
      count = @plan.prefix_callback_count
      unless @prefix_order.size + 1 == count
        raise CorruptPartError.new("recursive Compact Dynamic prefix capture differs from its canonical serializer DFS")
      end
      budget.ensure_future_nodes(1_u64)
      budget.ensure_future_elements(count.to_u64)
      budget.charge_node
      budget.charge_elements(count.to_u64) if count > 0
      captured = Array(String).new(count)
      count.times do |index|
        name = if index == 0
                 @plan.structure_callback_name
               else
                 @prefix_order[index - 1]
               end
        unless name == @plan.prefix_callback_at(index)
          raise CorruptPartError.new("recursive Compact Dynamic prefix capture differs from its canonical serializer DFS")
        end
        captured << name
      end
      captured
    end

    def body_callbacks(budget : BinaryCodecBudget) : Array(String)
      count = @plan.data_role_count
      unless @lane_order.size.to_u64 == count
        raise CorruptPartError.new("recursive Compact Dynamic body capture differs from its canonical serializer DFS")
      end
      budget.ensure_future_nodes(1_u64)
      budget.ensure_future_elements(count)
      budget.charge_node
      budget.charge_elements(count) if count > 0_u64
      callbacks = Array(String).new(count.to_i)
      count.to_i.times do |index|
        expected_role = @plan.body_role_at(index)
        unless @lane_order[index] == expected_role
          raise CorruptPartError.new("recursive Compact Dynamic body capture differs from its canonical serializer DFS")
        end
        name = @plan.body_callback_at(index)
        unless @plan.callback_name_for(expected_role) == name
          raise CorruptPartError.new("recursive Compact Dynamic body capture differs from its canonical serializer DFS")
        end
        callbacks << name
      end
      callbacks
    end

    def build_streams(budget : BinaryCodecBudget) : BinaryBulkStreams
      unless !@built && @lanes.size.to_u64 == @plan.data_role_count
        raise CorruptPartError.new("recursive Compact Dynamic lanes differ from their frozen body roster")
      end
      expected_prefix_roles = 0_u64
      one_roster_key_bytes = 0_u64
      @plan.each_data_role do |role|
        one_roster_key_bytes = checked_add(one_roster_key_bytes, role.bytesize.to_u64 + 1_u64)
        if @plan.physical_plan.prefix_size_for(role) > 0
          expected_prefix_roles += 1_u64
          unless @state_prefixes.has_key?(role)
            raise CorruptPartError.new("recursive Compact Dynamic state prefix is missing from its frozen roster")
          end
        end
      end
      unless @state_prefixes.size.to_u64 == expected_prefix_roles
        raise CorruptPartError.new("recursive Compact Dynamic state prefixes differ from their frozen roster")
      end

      owned_bytes = 0_u64
      @lanes.each_value { |bytes| owned_bytes = checked_add(owned_bytes, bytes.size.to_u64) }
      @state_prefixes.each_value do |kind, prefix|
        owned_bytes = checked_add(owned_bytes, prefix.size.to_u64) if kind == StatePrefixKind::LowCardinalityDictionaryV1
      end
      role_count = @plan.data_role_count
      unless role_count <= Int32::MAX.to_u64
        raise CorruptPartError.new("recursive Compact Dynamic data-role roster exceeds Int32")
      end
      CompactRecursiveJsonBulkMark.preflight_packaging!(
        role_count.to_i32,
        owned_bytes,
        one_roster_key_bytes,
        budget,
      )

      streams = Hash(String, BinaryBulkStream).new(initial_capacity: role_count.to_i)
      @plan.each_data_role do |role|
        body = @lanes[role]? || raise(CorruptPartError.new("recursive Compact Dynamic body role is missing"))
        key = String.new(role.to_slice)
        if prefix = @state_prefixes[role]?
          kind, prefix_bytes = prefix
          if kind == StatePrefixKind::LowCardinalityDictionaryV1
            unless body.empty?
              raise CorruptPartError.new("recursive Compact Dynamic LowCardinality dictionary body is not empty")
            end
            streams[key] = BinaryBulkStream.new(prefix_bytes, [8_u64, 8_u64])
          else
            end_offset = body.size.to_u64
            streams[key] = BinaryBulkStream.new(body, [0_u64, end_offset])
          end
        else
          end_offset = body.size.to_u64
          streams[key] = BinaryBulkStream.new(body, [0_u64, end_offset])
        end
      end
      @built = true
      BinaryBulkStreams.new(1, streams)
    end

    def retained_workspace_bytes : UInt64
      bytes = instance_sizeof(CompactRecursiveJsonDynamicBulkMark).to_u64
      # Logical owner census for this mark only; callback-plan internals and
      # allocator capacity are maintained by their respective owners.
      bytes = checked_add(bytes, instance_sizeof(Hash(String, Bytes)).to_u64)
      bytes = checked_add(bytes, checked_multiply(@lanes.size.to_u64, sizeof({UInt32, String, Bytes}).to_u64))
      @lanes.each { |role, lane| bytes = checked_add(bytes, role.bytesize.to_u64 + 1_u64 + instance_sizeof(String).to_u64 + lane.size.to_u64) }
      bytes = checked_add(bytes, instance_sizeof(Array(String)).to_u64)
      bytes = checked_add(bytes, checked_multiply(@lane_order.size.to_u64, sizeof(Pointer(String)).to_u64))
      @lane_order.each { |role| bytes = checked_add(bytes, role.bytesize.to_u64 + 1_u64 + instance_sizeof(String).to_u64) }
      bytes = checked_add(bytes, instance_sizeof(Hash(String, Tuple(StatePrefixKind, Bytes))).to_u64)
      bytes = checked_add(bytes, checked_multiply(@state_prefixes.size.to_u64, sizeof({UInt32, String, Tuple(StatePrefixKind, Bytes)}).to_u64))
      @state_prefixes.each { |role, entry| bytes = checked_add(bytes, role.bytesize.to_u64 + 1_u64 + instance_sizeof(String).to_u64 + entry[1].size.to_u64) }
      bytes = checked_add(bytes, instance_sizeof(Array(String)).to_u64)
      bytes = checked_add(bytes, checked_multiply(@prefix_order.size.to_u64, sizeof(Pointer(String)).to_u64))
      @prefix_order.each { |name| bytes = checked_add(bytes, name.bytesize.to_u64 + 1_u64 + instance_sizeof(String).to_u64) }
      bytes
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      if right > UInt64::MAX - left
        raise CorruptPartError.new("recursive Compact Dynamic mark workspace exceeds UInt64")
      end
      left + right
    end

    private def checked_multiply(left : UInt64, right : UInt64) : UInt64
      if left > 0_u64 && right > UInt64::MAX // left
        raise CorruptPartError.new("recursive Compact Dynamic mark workspace exceeds UInt64")
      end
      left * right
    end
  end
end
