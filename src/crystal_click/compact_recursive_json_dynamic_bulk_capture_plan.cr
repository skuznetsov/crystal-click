module CrystalClick
  # One mark-independent Dynamic callback plan at a recursive JSON schema
  # site. The root structure is learned from the parent prefix transaction;
  # all actual arms are then frozen to the existing bounded static Bulk
  # grammar. This deliberately does not admit another Dynamic or JSON arm.
  class CompactRecursiveJsonDynamicBulkCapturePlan
    getter site : CompactRecursiveJsonDynamicBulkSite
    getter dynamic_plan : BinaryDynamicBulkPlan
    getter physical_plan : BinaryDynamicBulkPhysicalPlan
    getter profile : BinaryBulkProfile

    @prefix_callbacks : Array(String)
    @body_callbacks : Array(String)
    @prefix_callbacks_by_role : Hash(String, String)

    def initialize(
      @site : CompactRecursiveJsonDynamicBulkSite,
      structure : DynamicStructure,
      @profile : BinaryBulkProfile,
      limits : BinaryCodecLimits,
      budget : BinaryCodecBudget,
    )
      unless !budget.writing?
        raise ArgumentError.new("recursive Compact Dynamic capture planning requires a read-direction budget")
      end

      # Admit the actual roster before the shared planner looks up structures
      # for nested Dynamic sites. The implicit SharedVariant arm is String.
      @site.validate_actual_roster!(structure, limits)

      structures = Hash(String, DynamicStructure).new(initial_capacity: 1)
      structures["root"] = structure
      @dynamic_plan = BinaryDynamicBulkPlan.decode_structure_prefixes_without_statistics_from_structures(
        @site.type,
        structures,
        budget,
        @profile,
        initial_depth: @site.descriptor_depth,
      )
      unless @dynamic_plan.site_count == 1 && @dynamic_plan.has_site?("root")
        raise UnsupportedFormatError.new("recursive Compact Dynamic capture requires one direct root Dynamic site")
      end

      physical_context = PhysicalStreamPlanContext.new(limits)
      @physical_plan = BinaryDynamicBulkPhysicalPlan.from_escaped_prefix(
        @dynamic_plan,
        @site.physical_prefix,
        limits,
        physical_context,
        initial_array_level: @site.initial_array_level,
        initial_descriptor_depth: @site.descriptor_depth,
      )
      preflight_callback_owners!(budget)
      traversal = CompactDynamicBulkPrefixTraversal.new(@site.type, @profile, limits)
      callbacks = traversal.expected_callback_roster(@physical_plan, @dynamic_plan)

      prefix_callbacks_by_role = Hash(String, String).new
      discriminator_name = PhysicalStreamName.append_literal(
        @physical_plan.stream_name_for("root.discriminators"),
        "_prefix",
      )
      prefix_callbacks_by_role["root.discriminators"] = discriminator_name
      @dynamic_plan.each_data_role do |role|
        next if @physical_plan.prefix_size_for(role) == 0
        callback = PhysicalStreamName.append_literal(@physical_plan.stream_name_for(role), "_prefix")
        if previous = prefix_callbacks_by_role[role]?
          unless previous == callback
            raise CorruptPartError.new("recursive Compact Dynamic prefix callback binding changed")
          end
        else
          prefix_callbacks_by_role[role] = callback
        end
      end

      structure_callbacks = Set(String).new
      @dynamic_plan.each_site_path do |path|
        structure_callbacks << @physical_plan.structure_name_for(path)
      end
      prefix_callbacks = Set(String).new
      structure_callbacks.each { |name| prefix_callbacks << name }
      prefix_callbacks_by_role.each_value { |name| prefix_callbacks << name }

      @prefix_callbacks = [] of String
      @body_callbacks = [] of String
      callbacks.each do |name|
        if prefix_callbacks.includes?(name)
          @prefix_callbacks << String.new(name.to_slice)
        else
          @body_callbacks << String.new(name.to_slice)
        end
      end
      unless @prefix_callbacks.size == structure_callbacks.size + prefix_callbacks_by_role.size &&
             @body_callbacks.size.to_u64 == @dynamic_plan.role_count
        raise CorruptPartError.new("recursive Compact Dynamic callback plan is not a complete prefix/body roster")
      end
      @prefix_callbacks_by_role = prefix_callbacks_by_role
      nil
    end

    def callback_name_for(role : String) : String
      @physical_plan.stream_name_for(role)
    rescue ex : KeyError
      raise CorruptPartError.new("recursive Compact Dynamic role is outside its prepared physical plan")
    end

    def prefix_callback_name_for(role : String) : String
      @prefix_callbacks_by_role[role]? ||
        raise(CorruptPartError.new("recursive Compact Dynamic role has no admitted state-prefix callback"))
    end

    def structure_callback_name : String
      @physical_plan.structure_name_for("root")
    end

    def root_discriminator_mode_callback : String
      prefix_callback_name_for("root.discriminators")
    end

    def prefix_callbacks : Array(String)
      @prefix_callbacks.map { |name| String.new(name.to_slice) }
    end

    def body_callbacks : Array(String)
      @body_callbacks.map { |name| String.new(name.to_slice) }
    end

    def prefix_callback_count : Int32
      @prefix_callbacks.size
    end

    def body_callback_count : Int32
      @body_callbacks.size
    end

    def prefix_callback_at(index : Int) : String
      if index < 0 || index >= @prefix_callbacks.size
        raise CorruptPartError.new("recursive Compact Dynamic prefix callback index is outside its frozen roster")
      end
      @prefix_callbacks[index]
    end

    def body_callback_at(index : Int) : String
      if index < 0 || index >= @body_callbacks.size
        raise CorruptPartError.new("recursive Compact Dynamic body callback index is outside its frozen roster")
      end
      @body_callbacks[index]
    end

    def body_role_at(index : Int) : String
      callback = body_callback_at(index)
      found = nil.as(String?)
      @dynamic_plan.each_data_role do |role|
        if @physical_plan.stream_name_for(role) == callback
          if found
            raise CorruptPartError.new("recursive Compact Dynamic physical callback is bound to multiple data roles")
          end
          found = role
        end
      end
      found || raise(CorruptPartError.new("recursive Compact Dynamic body callback is outside its data-role roster"))
    end

    def each_data_role(&block : String ->) : Nil
      @dynamic_plan.each_data_role { |role| yield role }
      nil
    end

    def data_role_count : UInt64
      @dynamic_plan.role_count
    end

    def data_role_at(index : Int) : String
      if index < 0 || index.to_u64 >= @dynamic_plan.role_count
        raise IndexError.new("recursive Compact Dynamic data-role index is outside the frozen roster")
      end
      found = nil.as(String?)
      current = 0
      @dynamic_plan.each_data_role do |role|
        if current == index
          found = role
          break
        end
        current += 1
      end
      found || raise(CorruptPartError.new("recursive Compact Dynamic data-role roster changed during lookup"))
    end

    def same_structure_roster?(structure : DynamicStructure) : Bool
      expected = @dynamic_plan.structure_for("root")
      return false unless expected.version == structure.version &&
                          expected.legacy_max_dynamic_types == structure.legacy_max_dynamic_types &&
                          expected.type_count == structure.type_count &&
                          expected.shared_index == structure.shared_index
      expected.type_count.times do |index|
        return false unless expected.type_at(index) == structure.type_at(index)
      end
      true
    end

    def size_lane_count : Int32
      count = 0_u64
      @dynamic_plan.arm_count("root").times do |index|
        count = checked_add(
          count,
          size_lane_count_for(@dynamic_plan.arm_type("root", index)),
        )
      end
      if count > Int32::MAX.to_u64
        raise CorruptPartError.new("recursive Compact Dynamic actual-arm Array-size schedule exceeds Int32")
      end
      count.to_i32
    end

    def arm_type(index : Int) : BinaryDataType
      @dynamic_plan.arm_type("root", index)
    end

    def arm_count : Int32
      @dynamic_plan.arm_count("root")
    end

    def retained_workspace_bytes : UInt64
      # Logical callback/site owner census only. Dynamic and physical plans
      # retain their own internal owners, and allocator capacities are not an
      # RSS bound or included by this local estimate.
      bytes = instance_sizeof(CompactRecursiveJsonDynamicBulkCapturePlan).to_u64
      bytes = checked_add(bytes, @site.retained_workspace_bytes)
      bytes = checked_add(bytes, string_array_bytes(@prefix_callbacks))
      bytes = checked_add(bytes, string_array_bytes(@body_callbacks))
      bytes = checked_add(bytes, instance_sizeof(Hash(String, String)).to_u64)
      bytes = checked_add(
        bytes,
        checked_multiply(@prefix_callbacks_by_role.size.to_u64, sizeof({UInt32, String, String}).to_u64),
      )
      @prefix_callbacks_by_role.each do |role, callback|
        bytes = checked_add(bytes, role.bytesize.to_u64 + 1_u64 + instance_sizeof(String).to_u64)
        bytes = checked_add(bytes, callback.bytesize.to_u64 + 1_u64 + instance_sizeof(String).to_u64)
      end
      bytes
    end

    private def string_array_bytes(values : Array(String)) : UInt64
      bytes = instance_sizeof(Array(String)).to_u64
      bytes = checked_add(bytes, checked_multiply(values.size.to_u64, sizeof(Pointer(String)).to_u64))
      values.each { |value| bytes = checked_add(bytes, value.bytesize.to_u64 + 1_u64 + instance_sizeof(String).to_u64) }
      bytes
    end

    private def size_lane_count_for(type : BinaryDataType) : UInt64
      case type.tag
      when BinaryDataType::TAG_CUSTOM, BinaryDataType::TAG_SIMPLE_AGGREGATE,
           BinaryDataType::TAG_NULLABLE
        size_lane_count_for(type.child_at(0))
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED
        checked_add(1_u64, size_lane_count_for(type.child_at(0)))
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE,
           BinaryDataType::TAG_MAP, BinaryDataType::TAG_VARIANT
        total = 0_u64
        type.child_count.times do |index|
          total = checked_add(total, size_lane_count_for(type.child_at(index)))
        end
        total
      else
        0_u64
      end
    end

    # The shared callback traversal returns detached names and builds its
    # callback/uniqueness rosters without an operation-budget parameter. Bound
    # this recursive-only layer first from the already-sealed role census and
    # physical-name extents, before asking it to materialize those rosters.
    private def preflight_callback_owners!(budget : BinaryCodecBudget) : Nil
      role_count = @dynamic_plan.role_count
      structure_count = @dynamic_plan.site_count.to_u64
      prefix_role_count = 0_u64
      data_name_bytes = 0_u64
      prefix_name_bytes = 0_u64
      @dynamic_plan.each_data_role do |role|
        name_bytes = @physical_plan.stream_name_byte_size_for(role)
        data_name_bytes = checked_add(data_name_bytes, name_bytes)
        if @physical_plan.prefix_size_for(role) > 0
          prefix_role_count = checked_add(prefix_role_count, 1_u64)
          prefix_name_bytes = checked_add(prefix_name_bytes, checked_add(name_bytes, 7_u64))
        end
      end
      structure_name_bytes = 0_u64
      observed_structures = 0_u64
      @physical_plan.each_structure_name_byte_size do |name_bytes|
        structure_name_bytes = checked_add(structure_name_bytes, name_bytes)
        observed_structures = checked_add(observed_structures, 1_u64)
      end
      unless observed_structures == structure_count && structure_count == 1_u64
        raise CorruptPartError.new("recursive Compact Dynamic callback preflight has an unexpected structure roster")
      end

      callback_count = checked_add(checked_add(role_count, prefix_role_count), structure_count)
      if callback_count > Int32::MAX.to_u64 || prefix_role_count > Int32::MAX.to_u64
        raise UnsupportedFormatError.new("recursive Compact Dynamic callback roster exceeds Int32")
      end

      # Roster copies: callback array + retained split arrays; the structure
      # callback is also owned by the structure Set, while prefixed callback
      # names are separately derived for the role map (each derivation has a
      # temporary base name and a final suffixed name).
      string_headers = checked_add(
        checked_multiply(role_count, 2_u64),
        checked_add(checked_multiply(structure_count, 3_u64), checked_multiply(prefix_role_count, 5_u64)),
      )
      string_bytes = checked_add(
        checked_multiply(data_name_bytes, 2_u64),
        checked_add(checked_multiply(structure_name_bytes, 3_u64), checked_multiply(prefix_name_bytes, 5_u64)),
      )
      string_bytes = checked_add(
        string_bytes,
        checked_multiply(string_headers, instance_sizeof(String).to_u64 + 1_u64),
      )

      # One traversal, one expected-name roster, one duplicate-detection Set
      # and Hash, one role-prefix Hash, two prefix Sets and their Hashes, two
      # retained callback arrays, and each copied String header.
      owner_nodes = checked_add(
        11_u64,
        string_headers,
      )
      owner_elements = checked_add(
        checked_multiply(callback_count, 2_u64),
        checked_add(
          prefix_role_count,
          checked_add(checked_multiply(structure_count, 2_u64), string_bytes),
        ),
      )
      budget.ensure_future_nodes(owner_nodes)
      budget.ensure_future_elements(owner_elements)
      owner_nodes.times { budget.charge_node }
      budget.charge_elements(owner_elements) if owner_elements > 0_u64
      nil
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      if right > UInt64::MAX - left
        raise CorruptPartError.new("recursive Compact Dynamic capture workspace exceeds UInt64")
      end
      left + right
    end

    private def checked_multiply(left : UInt64, right : UInt64) : UInt64
      if left > 0_u64 && right > UInt64::MAX // left
        raise CorruptPartError.new("recursive Compact Dynamic capture workspace exceeds UInt64")
      end
      left * right
    end
  end
end
