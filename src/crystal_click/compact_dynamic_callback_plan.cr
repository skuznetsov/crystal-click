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

    def initialize(
      input : CompactDynamicColumnInput,
      limits : BinaryCodecLimits,
      budget : BinaryCodecBudget,
      @variant_discriminator_mode : CompactVariantDiscriminatorMode = CompactVariantDiscriminatorMode::Compact,
    )
      unless budget.writing?
        raise ArgumentError.new("Compact Dynamic callback planning requires a write-direction budget")
      end
      @type = input.type
      @profile = input.profile
      @column_name = String.new(input.name.to_slice)
      @variant_discriminator_mode.wire_value

      unless @type.contains_dynamic?
        raise ArgumentError.new("Compact Dynamic callback plan requires a Dynamic-bearing descriptor")
      end
      unless (@profile.single_stream? || @profile.with_size_stream?) && input.map_basic?
        raise UnsupportedFormatError.new("Compact Dynamic writer requires a supported String profile and BASIC Map serialization")
      end
      if @column_name.empty?
        raise ArgumentError.new("Compact Dynamic column name must be nonempty")
      end
      CompactDynamicBulkPrefixTraversal.validate_compact_type_admission!(@type, limits)

      @dynamic_plan = BinaryDynamicBulkPlan.new_with_budget(
        @type,
        input.dynamic_context.site_structures,
        budget,
        @profile,
      )
      @dynamic_plan.each_site_path do |site_path|
        structure = @dynamic_plan.structure_for(site_path)
        actual_depth = @dynamic_plan.depth_for_site(site_path) + 1
        structure.type_count.times do |index|
          CompactDynamicBulkPrefixTraversal.validate_compact_type_admission!(
            structure.type_at(index), limits, actual_depth
          )
        end
      end
      @physical_plan = BinaryDynamicBulkPhysicalPlan.new(@dynamic_plan, @column_name, limits)
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
      @dynamic_plan.data_roles.each do |role|
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

      data_names = Hash(String, String).new(initial_capacity: @dynamic_plan.data_roles.size)
      @dynamic_plan.data_roles.each do |role|
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
    end

    def callback_names : Array(String)
      @callback_events.map(&.name)
    end

    def callback_events : Array(CompactBinaryBulkCallback)
      @callback_events.dup
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
      structures = context.site_structures
      return false unless structures.size == @dynamic_plan.site_count
      @dynamic_plan.each_site_path do |path|
        supplied = structures[path]?
        return false unless supplied && supplied == @dynamic_plan.structure_for(path)
      end
      structures.each_key do |path|
        return false unless @dynamic_plan.has_site?(path)
      end
      true
    end
  end
end
