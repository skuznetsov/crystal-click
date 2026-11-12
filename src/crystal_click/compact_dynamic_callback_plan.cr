module CrystalClick
  # Seals one Dynamic-bearing column's actual-site plan and ordered Compact
  # callback events. Recursive callback order comes from the shared prefix
  # traversal grammar rather than a second writer-specific descriptor walk.
  class CompactDynamicCallbackPlan
    getter type : BinaryDataType
    getter profile : BinaryBulkProfile
    getter column_name : String
    getter dynamic_plan : BinaryDynamicBulkPlan
    getter physical_plan : BinaryDynamicBulkPhysicalPlan
    getter variant_discriminator_mode : CompactVariantDiscriminatorMode

    @callback_events : Array(CompactBinaryBulkCallback)
    @structure_sites_by_name : Hash(String, String)
    @prefix_roles_by_name : Hash(String, String)
    @body_roles_by_name : Hash(String, String)
    @dictionary_prefix_roles : Array(String)
    @discriminator_roles : Array(String)
    @initial_array_level : UInt64
    @initial_descriptor_depth : Int32
    @physical_prefix : String?
    @recursive_json_site : Bool

    def initialize(
      input : CompactDynamicColumnInput,
      limits : BinaryCodecLimits,
      budget : BinaryCodecBudget,
      variant_discriminator_mode : CompactVariantDiscriminatorMode = CompactVariantDiscriminatorMode::Compact,
    )
      unless (input.profile.single_stream? || input.profile.with_size_stream?) && input.map_basic?
        raise UnsupportedFormatError.new("Compact Dynamic writer requires a supported String profile and BASIC Map serialization")
      end
      initialize(
        input.type,
        input.name,
        input.profile,
        input.dynamic_context,
        limits,
        budget,
        nil,
        0_u64,
        1_i32,
        nil,
        variant_discriminator_mode,
      )
    end

    # Compose the existing Dynamic callback grammar at one direct recursive
    # JSON Bulk site. The descriptor/site coordinates stay owned by the JSON
    # schema plan; actual Dynamic structures remain rooted at "root".
    def self.for_recursive_json_site(
      site : CompactRecursiveJsonDynamicBulkSite,
      column_name : String,
      context : CompactDynamicWriteContext,
      profile : BinaryBulkProfile,
      limits : BinaryCodecLimits,
      budget : BinaryCodecBudget,
      variant_discriminator_mode : CompactVariantDiscriminatorMode,
    ) : CompactDynamicCallbackPlan
      new(site, column_name, context, profile, limits, budget, variant_discriminator_mode)
    end

    private def initialize(
      site : CompactRecursiveJsonDynamicBulkSite,
      column_name : String,
      context : CompactDynamicWriteContext,
      profile : BinaryBulkProfile,
      limits : BinaryCodecLimits,
      budget : BinaryCodecBudget,
      variant_discriminator_mode : CompactVariantDiscriminatorMode,
    )
      initialize(
        site.type,
        column_name,
        profile,
        context,
        limits,
        budget,
        site.physical_prefix,
        site.initial_array_level,
        site.descriptor_depth,
        site,
        variant_discriminator_mode,
      )
    end

    private def initialize(
      type : BinaryDataType,
      column_name : String,
      profile : BinaryBulkProfile,
      context : CompactDynamicWriteContext,
      limits : BinaryCodecLimits,
      budget : BinaryCodecBudget,
      physical_prefix : String?,
      initial_array_level : UInt64,
      initial_descriptor_depth : Int32,
      recursive_json_site : CompactRecursiveJsonDynamicBulkSite?,
      @variant_discriminator_mode : CompactVariantDiscriminatorMode,
    ) : Nil
      unless budget.writing?
        raise ArgumentError.new("Compact Dynamic callback planning requires a write-direction budget")
      end
      @type = type
      @profile = profile
      @column_name = recursive_json_site ? column_name : String.new(column_name.to_slice)
      # Site strings are immutable schema-owned values; borrow the recursive
      # prefix instead of making another uncharged copy per Dynamic site.
      @physical_prefix = physical_prefix
      @initial_array_level = initial_array_level
      @initial_descriptor_depth = initial_descriptor_depth
      @recursive_json_site = !recursive_json_site.nil?
      @variant_discriminator_mode.wire_value

      unless @type.contains_dynamic?
        raise ArgumentError.new("Compact Dynamic callback plan requires a Dynamic-bearing descriptor")
      end
      unless @profile.single_stream? || @profile.with_size_stream?
        raise UnsupportedFormatError.new("Compact Dynamic writer requires a supported String profile and BASIC Map serialization")
      end
      if @column_name.empty?
        raise ArgumentError.new("Compact Dynamic column name must be nonempty")
      end
      CompactDynamicBulkPrefixTraversal.validate_compact_type_admission!(
        @type, limits, @initial_descriptor_depth,
      )

      if site = recursive_json_site
        if structure = context.structure_at?("root")
          site.validate_actual_roster!(structure, limits)
        end
      end

      @dynamic_plan = BinaryDynamicBulkPlan.new_with_budget(
        @type,
        @recursive_json_site ? copy_context_structures(context, budget) : context.site_structures,
        budget,
        @profile,
      )
      unless @recursive_json_site
        @dynamic_plan.each_site_path do |site_path|
          structure = @dynamic_plan.structure_for(site_path)
          actual_depth64 = @initial_descriptor_depth.to_i64 + @dynamic_plan.depth_for_site(site_path).to_i64
          if actual_depth64 <= 0_i64 || actual_depth64 > limits.max_depth.to_i64 ||
             actual_depth64 > Int32::MAX.to_i64
            raise UnsupportedFormatError.new("Compact Dynamic actual descriptor depth exceeds configured limit")
          end
          actual_depth = actual_depth64.to_i32
          structure.type_count.times do |index|
            CompactDynamicBulkPrefixTraversal.validate_compact_type_admission!(
              structure.type_at(index), limits, actual_depth,
            )
          end
        end
      end
      if prefix = @physical_prefix
        physical_context = PhysicalStreamPlanContext.new(limits)
        @physical_plan = BinaryDynamicBulkPhysicalPlan.from_escaped_prefix(
          @dynamic_plan,
          prefix,
          limits,
          physical_context,
          initial_array_level: @initial_array_level,
          initial_descriptor_depth: @initial_descriptor_depth,
        )
      else
        @physical_plan = BinaryDynamicBulkPhysicalPlan.new(@dynamic_plan, @column_name, limits)
      end
      preflight_recursive_callback_wrappers!(budget) if @recursive_json_site
      traversal = CompactDynamicBulkPrefixTraversal.new(@type, @profile, limits)
      callback_names = traversal.expected_callback_roster(@physical_plan, @dynamic_plan)

      structure_names = Hash(String, String).new(initial_capacity: @dynamic_plan.site_count)
      @dynamic_plan.each_site_path do |site_path|
        name = @physical_plan.structure_name_for(site_path)
        structure_names[name] = String.new(site_path.to_slice)
      end

      prefix_roles = Hash(String, String).new
      dictionary_roles = [] of String
      discriminator_roles = [] of String
      @dynamic_plan.each_data_role do |role|
        prefix_size = @physical_plan.prefix_size_for(role)
        next if prefix_size == 0
        unless prefix_size == BinaryBulkDiscriminatorFramingAdapter::PREFIX_BYTES
          raise UnsupportedFormatError.new("Compact Dynamic writer requires admitted eight-byte state prefixes")
        end
        stream_name = @physical_plan.stream_name_for(role)
        prefix_name = PhysicalStreamName.append_literal(stream_name, "_prefix")
        if prefix_roles.has_key?(prefix_name)
          raise UnsupportedFormatError.new("Compact Dynamic physical prefix names are not unique")
        end
        prefix_roles[prefix_name] = String.new(role.to_slice)
        if role.ends_with?(".dictionary")
          dictionary_roles << String.new(role.to_slice)
        elsif role.ends_with?(".discriminators")
          discriminator_roles << String.new(role.to_slice)
        else
          raise UnsupportedFormatError.new("Compact Dynamic writer does not admit this state-prefix role")
        end
      end

      data_names = Hash(String, String).new(initial_capacity: @dynamic_plan.role_count.to_i)
      @dynamic_plan.each_data_role do |role|
        name = @physical_plan.stream_name_for(role)
        if data_names.has_key?(name)
          raise UnsupportedFormatError.new("Compact Dynamic physical data names are not unique")
        end
        data_names[name] = String.new(role.to_slice)
      end

      @callback_events = Array(CompactBinaryBulkCallback).new(callback_names.size)
      @structure_sites_by_name = Hash(String, String).new(initial_capacity: structure_names.size)
      @prefix_roles_by_name = Hash(String, String).new(initial_capacity: prefix_roles.size)
      @body_roles_by_name = Hash(String, String).new(initial_capacity: data_names.size)
      seen_names = Set(String).new
      callback_names.each do |name|
        unless seen_names.add?(name)
          raise UnsupportedFormatError.new("Compact Dynamic callback schedule repeats a physical callback")
        end
        if site_path = structure_names[name]?
          @structure_sites_by_name[String.new(name.to_slice)] = String.new(site_path.to_slice)
          @callback_events << CompactBinaryBulkCallback.new(name, site_path, 0)
        elsif role = prefix_roles[name]?
          @prefix_roles_by_name[String.new(name.to_slice)] = String.new(role.to_slice)
          @callback_events << CompactBinaryBulkCallback.new(
            name, role, BinaryBulkDiscriminatorFramingAdapter::PREFIX_BYTES
          )
        elsif role = data_names[name]?
          @body_roles_by_name[String.new(name.to_slice)] = String.new(role.to_slice)
          @callback_events << CompactBinaryBulkCallback.new(name, role, 0)
        else
          raise UnsupportedFormatError.new("Compact Dynamic callback is outside its physical role plan")
        end
      end
      unless @structure_sites_by_name.size == structure_names.size &&
             @prefix_roles_by_name.size == prefix_roles.size &&
             @body_roles_by_name.size == data_names.size
        raise UnsupportedFormatError.new("Compact Dynamic callback schedule is incomplete")
      end

      @dictionary_prefix_roles = dictionary_roles
      @discriminator_roles = discriminator_roles
      nil
    end

    def callback_names : Array(String)
      @callback_events.map(&.name)
    end

    def callback_events : Array(CompactBinaryBulkCallback)
      @callback_events.dup
    end

    def callback_event_count : Int32
      @callback_events.size
    end

    def callback_event_at(index : Int) : CompactBinaryBulkCallback
      @callback_events[index]
    end

    def each_callback_event(&block : CompactBinaryBulkCallback -> Nil) : Nil
      @callback_events.each { |event| yield event }
      nil
    end

    def includes_callback_event?(candidate : CompactBinaryBulkCallback) : Bool
      @callback_events.any? do |event|
        event.name == candidate.name && event.role == candidate.role &&
          event.prefix_size == candidate.prefix_size
      end
    end

    def structure_site_for_callback(name : String) : String?
      @structure_sites_by_name[name]?
    end

    def prefix_role_for_callback(name : String) : String?
      @prefix_roles_by_name[name]?
    end

    def body_role_for_callback(name : String) : String?
      @body_roles_by_name[name]?
    end

    def data_roles : Array(String)
      @dynamic_plan.data_roles
    end

    # Borrowed traversal for retained-workspace estimation. The public
    # `data_roles` accessor remains detached; internal read-only consumers avoid
    # allocating one defensive role array per encoded mark.
    def each_data_role(&block : String -> Nil) : Nil
      @dynamic_plan.each_data_role { |role| yield role }
      nil
    end

    def dictionary_prefix_roles : Array(String)
      @dictionary_prefix_roles.map { |role| String.new(role.to_slice) }
    end

    def discriminator_roles : Array(String)
      @discriminator_roles.map { |role| String.new(role.to_slice) }
    end

    def discriminator_role?(role : String) : Bool
      @discriminator_roles.includes?(role)
    end

    def same_context?(context : CompactDynamicWriteContext) : Bool
      return false unless context.site_count == @dynamic_plan.site_count
      @dynamic_plan.each_site_path do |path|
        supplied = context.structure_at?(path)
        return false unless supplied && supplied == @dynamic_plan.structure_for(path)
      end
      context.each_site_structure do |path, _structure|
        return false unless @dynamic_plan.has_site?(path)
      end
      true
    end

    private def copy_context_structures(
      context : CompactDynamicWriteContext,
      budget : BinaryCodecBudget,
    ) : Hash(String, DynamicStructure)
      count = context.site_count.to_u64
      # BinaryDynamicBulkPlan accepts a map. Reserve that temporary adapter
      # before copying immutable site owners from the input context.
      budget.ensure_future_nodes(count + 1_u64)
      budget.ensure_future_elements(count)
      (count + 1_u64).times { budget.charge_node }
      budget.charge_elements(count) if count > 0_u64
      structures = Hash(String, DynamicStructure).new(initial_capacity: context.site_count)
      context.each_site_structure do |path, structure|
        detached_path = String.new(path.to_slice)
        structures[detached_path] = structure
      end
      unless structures.size.to_u64 == count
        raise UnsupportedFormatError.new("Compact Dynamic context changed while its callback plan was bound")
      end
      structures
    end

    # Recursive JSON owns one additional callback wrapper layer beyond the
    # standalone Dynamic writer. Count it from immutable plan cardinalities
    # before the traversal creates its callback array/Set or this owner creates
    # the temporary/final role maps, event array, event objects, and detached
    # role/name strings. Standalone callers intentionally retain W283 charging.
    private def preflight_recursive_callback_wrappers!(budget : BinaryCodecBudget) : Nil
      site_count = @dynamic_plan.site_count.to_u64
      role_count = @dynamic_plan.role_count
      prefix_count = 0_u64
      data_name_bytes = 0_u64
      role_bytes = 0_u64
      prefix_base_name_bytes = 0_u64
      prefix_role_bytes = 0_u64
      @dynamic_plan.each_data_role do |role|
        data_name_bytes = checked_wrapper_add(
          data_name_bytes, @physical_plan.stream_name_byte_size_for(role),
        )
        role_bytes = checked_wrapper_add(role_bytes, role.bytesize.to_u64)
        prefix_size = @physical_plan.prefix_size_for(role)
        next if prefix_size == 0
        unless prefix_size == BinaryBulkDiscriminatorFramingAdapter::PREFIX_BYTES
          raise UnsupportedFormatError.new("Compact Dynamic writer requires admitted eight-byte state prefixes")
        end
        prefix_count = checked_wrapper_add(prefix_count, 1_u64)
        prefix_base_name_bytes = checked_wrapper_add(
          prefix_base_name_bytes, @physical_plan.stream_name_byte_size_for(role),
        )
        prefix_role_bytes = checked_wrapper_add(prefix_role_bytes, role.bytesize.to_u64)
      end

      callback_count = checked_wrapper_add(site_count, checked_wrapper_add(role_count, prefix_count))
      if callback_count > Int32::MAX.to_u64
        raise UnsupportedFormatError.new("recursive Compact Dynamic callback roster exceeds Int32")
      end

      # The expected roster has four proportional containers (callback array,
      # dictionary roles, discriminator roles, events), six maps, two Sets plus
      # their backing Hashes, and one event object per callback. Every detached
      # String is counted as a node; each container reference/slot is an edge.
      # Physical plan binding has its own name-work bound; the duplicate names
      # retained or temporarily rendered by these wrappers are charged below.
      string_copies = checked_wrapper_add(
        checked_wrapper_add(
          checked_wrapper_multiply(callback_count, 5_u64),
          checked_wrapper_multiply(site_count, 2_u64),
        ),
        checked_wrapper_add(
          checked_wrapper_multiply(prefix_count, 4_u64),
          checked_wrapper_multiply(role_count, 2_u64),
        ),
      )

      structure_name_bytes = 0_u64
      @physical_plan.each_structure_name_byte_size do |name_bytes|
        structure_name_bytes = checked_wrapper_add(structure_name_bytes, name_bytes)
      end
      site_path_bytes = 0_u64
      @dynamic_plan.each_site_path do |site_path|
        site_path_bytes = checked_wrapper_add(site_path_bytes, site_path.bytesize.to_u64)
      end

      prefix_suffix_bytes = checked_wrapper_multiply(prefix_count, "_prefix".bytesize.to_u64)
      callback_name_bytes = checked_wrapper_add(
        checked_wrapper_add(structure_name_bytes, data_name_bytes),
        checked_wrapper_add(prefix_base_name_bytes, prefix_suffix_bytes),
      )
      callback_role_bytes = checked_wrapper_add(
        checked_wrapper_add(site_path_bytes, role_bytes), prefix_role_bytes,
      )

      # The expected-roster array retains one copy of every callback name;
      # prefix rendering additionally creates a temporary basename. Temporary
      # role maps own their keys/values, and each final callback map plus event
      # duplicates the complete callback name/role pair. Add one terminator byte
      # per copied String, matching retained-workspace accounting elsewhere.
      wrapper_string_bytes = checked_wrapper_add(
        checked_wrapper_add(callback_name_bytes, prefix_base_name_bytes),
        checked_wrapper_add(structure_name_bytes, site_path_bytes),
      )
      wrapper_string_bytes = checked_wrapper_add(
        wrapper_string_bytes,
        checked_wrapper_add(
          checked_wrapper_add(
            checked_wrapper_multiply(prefix_base_name_bytes, 2_u64),
            checked_wrapper_add(prefix_suffix_bytes, prefix_role_bytes),
          ),
          checked_wrapper_add(data_name_bytes, role_bytes),
        ),
      )
      callback_pair_bytes = checked_wrapper_add(callback_name_bytes, callback_role_bytes)
      wrapper_string_bytes = checked_wrapper_add(
        wrapper_string_bytes, checked_wrapper_multiply(callback_pair_bytes, 2_u64),
      )
      wrapper_bytes = checked_wrapper_add(wrapper_string_bytes, string_copies)

      wrapper_nodes = checked_wrapper_add(
        checked_wrapper_add(14_u64, callback_count),
        string_copies,
      )
      wrapper_elements = checked_wrapper_add(
        checked_wrapper_add(
          checked_wrapper_multiply(callback_count, 8_u64),
          checked_wrapper_multiply(site_count, 2_u64),
        ),
        checked_wrapper_add(
          checked_wrapper_multiply(prefix_count, 3_u64),
          checked_wrapper_multiply(role_count, 2_u64),
        ),
      )
      # Callback names and roles are metadata/package ownership, not encoded
      # wire payload. Charge their copied bytes in the aggregate element domain
      # used for recursive packaging rather than changing logical wire bytes.
      wrapper_elements = checked_wrapper_add(wrapper_elements, wrapper_bytes)

      budget.ensure_future_nodes(wrapper_nodes)
      budget.ensure_future_elements(wrapper_elements)
      wrapper_nodes.times { budget.charge_node }
      budget.charge_elements(wrapper_elements) if wrapper_elements > 0_u64
      nil
    end

    private def checked_wrapper_add(left : UInt64, right : UInt64) : UInt64
      if right > UInt64::MAX - left
        raise UnsupportedFormatError.new("recursive Compact Dynamic callback wrapper bound overflows UInt64")
      end
      left + right
    end

    private def checked_wrapper_multiply(left : UInt64, right : UInt64) : UInt64
      if left > 0_u64 && right > UInt64::MAX // left
        raise UnsupportedFormatError.new("recursive Compact Dynamic callback wrapper bound overflows UInt64")
      end
      left * right
    end
  end
end
