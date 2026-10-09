module CrystalClick
  # Resolves one Dynamic structure lane before the complete actual-roster
  # physical plan exists. The prepared site roster may itself reveal another
  # Dynamic site, so this resolver follows only the requested root-to-site
  # path and consults already-parsed ancestor structures.
  class BinaryDynamicBulkSiteNameResolver
    private struct DynamicSitePosition
      getter prefix : String
      getter callback_prefix : String
      getter array_level : UInt64

      def initialize(@prefix : String, @callback_prefix : String, @array_level : UInt64)
      end
    end

    private struct EscapedPrefix
      getter value : String

      private def initialize(value : String)
        PhysicalStreamName.validate_escaped_prefix(value)
        @value = String.new(value.to_slice)
      end

      def self.validated(value : String) : EscapedPrefix
        new(value)
      end
    end

    @type : BinaryDataType
    @root_prefix : String
    @callback_root_prefix : String
    @initial_array_level : UInt64
    @initial_descriptor_depth : Int32
    @limits : BinaryCodecLimits
    @context : PhysicalStreamPlanContext
    @type_name_budget : BinaryCodecBudget
    @descriptor_preflight : BinaryDynamicBulkDescriptorPreflight?

    def descriptor_preflight : BinaryDynamicBulkDescriptorPreflight
      @descriptor_preflight || raise ArgumentError.new("Dynamic resolver has no shared descriptor preflight")
    end

    def initialize(type : BinaryDataType, column_name : String, @limits : BinaryCodecLimits)
      # Public discovery must not call recursive summary predicates or render a
      # path before the complete caller descriptor has a bounded name walk.
      budget = BinaryCodecBudget.new(@limits)
      @descriptor_preflight = BinaryDynamicBulkDescriptorPreflight.admit(type, budget)
      @context = PhysicalStreamPlanContext.new(@limits)
      escaped_size = PhysicalStreamName.escaped_size(column_name)
      @context.preflight_name_bytes(escaped_size)
      @root_prefix = PhysicalStreamName.escape(column_name, @context)
      @context.charge_name_bytes(escaped_size)
      @callback_root_prefix = String.new(@root_prefix.to_slice)
      @initial_array_level = 0_u64
      @initial_descriptor_depth = 1_i32
      # This resolver is used while reading persisted structure lanes. Keep
      # malformed source metadata in the corruption domain rather than
      # reporting a caller-side write rejection.
      @type_name_budget = BinaryCodecBudget.new(@limits)
      @type = type
    end

    # Composition entry point for a schema site whose outer physical prefix
    # is already escaped and whose Array numbering is inherited from the
    # recursive storage tree.
    def self.from_escaped_prefix(
      type : BinaryDataType,
      escaped_prefix : String,
      initial_array_level : UInt64,
      limits : BinaryCodecLimits,
      codec_budget : BinaryCodecBudget? = nil,
      context : PhysicalStreamPlanContext? = nil,
      initial_descriptor_depth : Int32 = 1,
      callback_prefix : String? = nil,
    ) : BinaryDynamicBulkSiteNameResolver
      selected_context = context || PhysicalStreamPlanContext.new(limits)
      selected_budget = codec_budget || BinaryCodecBudget.new(limits)
      unless selected_budget.limits.max_depth == limits.max_depth &&
             selected_budget.limits.max_nodes == limits.max_nodes &&
             selected_budget.limits.max_elements == limits.max_elements &&
             selected_budget.limits.max_bytes == limits.max_bytes
        raise ArgumentError.new("Dynamic resolver codec budget differs from its limits")
      end
      unless selected_context.limits.max_depth == limits.max_depth &&
             selected_context.limits.max_nodes == limits.max_nodes &&
             selected_context.limits.max_elements == limits.max_elements &&
             selected_context.limits.max_bytes == limits.max_bytes
        raise ArgumentError.new("Dynamic resolver physical context differs from its limits")
      end
      if initial_descriptor_depth <= 0 || initial_descriptor_depth > limits.max_depth
        raise UnsupportedFormatError.new("Dynamic resolver initial descriptor depth exceeds the configured limit")
      end
      if initial_array_level > UInt64::MAX - limits.max_depth.to_u64
        raise UnsupportedFormatError.new("Dynamic resolver initial Array level overflows the name coordinate")
      end

      # The site prefix is already escaped. Bound and charge its retained copy
      # before validating/materializing the detached resolver token.
      selected_context.preflight_name_bytes(escaped_prefix.bytesize.to_u64)
      PhysicalStreamName.validate_escaped_prefix(escaped_prefix)
      selected_context.charge_name_bytes(escaped_prefix.bytesize.to_u64)
      selected_callback_prefix = callback_prefix || escaped_prefix
      selected_context.preflight_name_bytes(selected_callback_prefix.bytesize.to_u64)
      selected_context.charge_name_bytes(selected_callback_prefix.bytesize.to_u64)
      descriptor_preflight = BinaryDynamicBulkDescriptorPreflight.admit(
        type, selected_budget, initial_descriptor_depth
      )
      new(
        type, EscapedPrefix.validated(escaped_prefix), selected_callback_prefix, initial_array_level,
        initial_descriptor_depth, limits, selected_context, selected_budget,
        descriptor_preflight
      )
    end

    private def initialize(
      type : BinaryDataType,
      escaped_prefix : EscapedPrefix,
      @callback_root_prefix : String,
      @initial_array_level : UInt64,
      @initial_descriptor_depth : Int32,
      @limits : BinaryCodecLimits,
      @context : PhysicalStreamPlanContext,
      @type_name_budget : BinaryCodecBudget,
      @descriptor_preflight : BinaryDynamicBulkDescriptorPreflight,
    )
      if @initial_descriptor_depth <= 0 || @initial_descriptor_depth > @limits.max_depth
        raise UnsupportedFormatError.new("Dynamic resolver initial descriptor depth exceeds the configured limit")
      end
      # The token already owns the single charged copy made by EscapedPrefix.
      @root_prefix = escaped_prefix.value
      @callback_root_prefix = String.new(@callback_root_prefix.to_slice)
      @type = type
    end

    # Returns the unhashed logical stream name expected in
    # columns_substreams.txt. `structures` contains only sites already loaded
    # in parent-first order; no unknown arm name is guessed.
    def structure_stream_name(target_path : String, structures : Hash(String, DynamicStructure)) : String
      resolved = find_dynamic_site_position(
        @type, "root", @root_prefix, @callback_root_prefix, @initial_array_level, target_path, structures,
        @context, @initial_descriptor_depth
      )
      position = resolved || raise(CorruptPartError.new("Dynamic structure site has no physical name"))
      append_literal(position.prefix, ".dynamic_structure", @context)
    end

    # Resolve one direct ordinary JSON actual arm from the exact Dynamic site
    # path and already-parsed ancestor rosters. The arm component is rendered
    # from the same canonical roster used by DynamicBulkPhysicalPlan.
    def json_object_arm_site(
      target_path : String,
      canonical_arm_index : Int,
      structures : Hash(String, DynamicStructure),
    ) : DynamicJsonObjectSiteCoordinates
      resolved = find_dynamic_site_position(
        @type, "root", @root_prefix, @callback_root_prefix, @initial_array_level, target_path, structures,
        @context, @initial_descriptor_depth
      )
      position = resolved || raise(CorruptPartError.new("Dynamic JSON site has no physical prefix"))
      structure = structures[target_path]? ||
                  raise(CorruptPartError.new("Dynamic JSON site structure is unavailable for prefix discovery"))
      # This direct-target path bypasses the parent-first traversal's roster
      # accounting. Reserve both the temporary bounds table and retained
      # canonical arm table before canonical_arms allocates either one.
      temporary_bound_slots = structure.type_count.to_u64
      canonical_arm_slots = structure.canonical_variant_count.to_u64
      @context.record_elements(temporary_bound_slots) if temporary_bound_slots > 0_u64
      @context.record_elements(canonical_arm_slots) if canonical_arm_slots > 0_u64
      arm = canonical_arms(structure)[canonical_arm_index]?
      unless arm && arm[1].tag == BinaryDataType::TAG_JSON
        raise CorruptPartError.new("Dynamic JSON physical site does not identify a direct JSON actual arm")
      end
      escaped_prefix = append_component(position.prefix, arm[0], @context)
      callback_prefix = append_raw_component(position.callback_prefix, arm[0], @context)
      @context.preflight_name_bytes(escaped_prefix.bytesize.to_u64)
      @context.charge_name_bytes(escaped_prefix.bytesize.to_u64)
      DynamicJsonObjectSiteCoordinates.new(escaped_prefix, callback_prefix, position.array_level, arm[1])
    end

    # Resolve one JSON leaf inside a Dynamic actual descriptor. The child path
    # is a sequence of BinaryDataType child ordinals from the selected actual
    # arm root; unlike a rendered logical stream path, it is stable across
    # metadata ordering and can be checked against the exact descriptor tree.
    def json_object_leaf_site(
      key : BinaryDynamicJsonLeafKey,
      structures : Hash(String, DynamicStructure),
    ) : DynamicJsonObjectSiteCoordinates
      resolved = find_dynamic_site_position(
        @type, "root", @root_prefix, @callback_root_prefix, @initial_array_level, key.dynamic_site, structures,
        @context, @initial_descriptor_depth
      )
      position = resolved || raise(CorruptPartError.new("Dynamic JSON leaf has no physical prefix"))
      structure = structures[key.dynamic_site]? ||
                  raise(CorruptPartError.new("Dynamic JSON leaf structure is unavailable for prefix discovery"))

      temporary_bound_slots = structure.type_count.to_u64
      canonical_arm_slots = structure.canonical_variant_count.to_u64
      @context.record_elements(temporary_bound_slots) if temporary_bound_slots > 0_u64
      @context.record_elements(canonical_arm_slots) if canonical_arm_slots > 0_u64
      arm = canonical_arms(structure)[key.canonical_arm_index]?
      unless arm
        raise CorruptPartError.new("Dynamic JSON leaf canonical arm is outside the actual roster")
      end

      escaped_prefix = append_component(position.prefix, arm[0], @context)
      callback_prefix = append_raw_component(position.callback_prefix, arm[0], @context)
      leaf_type = arm[1]
      array_level = position.array_level
      key.descriptor_child_path.each do |child_index|
        unless child_index >= 0 && child_index < leaf_type.child_count
          raise CorruptPartError.new("Dynamic JSON leaf path is outside its actual descriptor")
        end
        child = leaf_type.child_at(child_index)
        escaped_prefix, callback_prefix, array_level = child_site_coordinates(
          leaf_type, child_index, child, escaped_prefix, callback_prefix, array_level
        )
        leaf_type = child
      end
      unless leaf_type.tag == BinaryDataType::TAG_JSON
        raise CorruptPartError.new("Dynamic JSON leaf path does not identify a JSON descriptor")
      end
      @context.preflight_name_bytes(escaped_prefix.bytesize.to_u64)
      @context.charge_name_bytes(escaped_prefix.bytesize.to_u64)
      DynamicJsonObjectSiteCoordinates.new(escaped_prefix, callback_prefix, array_level, leaf_type)
    rescue ex : ArgumentError | IndexError
      raise CorruptPartError.new("Dynamic JSON leaf descriptor coordinates are invalid")
    end

    private def child_site_coordinates(
      parent : BinaryDataType,
      child_index : Int32,
      child : BinaryDataType,
      prefix : String,
      callback_prefix : String,
      array_level : UInt64,
    ) : Tuple(String, String, UInt64)
      case parent.tag
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED
        unless child_index == 0
          raise CorruptPartError.new("Dynamic JSON Array leaf path selects an invalid child")
        end
        {prefix, callback_prefix, checked_array_level(array_level)}
      when BinaryDataType::TAG_NULLABLE, BinaryDataType::TAG_SIMPLE_AGGREGATE
        unless child_index == 0
          raise CorruptPartError.new("Dynamic JSON wrapper leaf path selects an invalid child")
        end
        {prefix, callback_prefix, array_level}
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        field = parent.named_tuple? ? parent.field_name_at(child_index) : (child_index + 1).to_s
        {append_field(prefix, field, @context), append_field(callback_prefix, field, @context), array_level}
      when BinaryDataType::TAG_MAP
        unless child_index == 0 || child_index == 1
          raise CorruptPartError.new("Dynamic JSON Map leaf path selects an invalid child")
        end
        field = child_index == 0 ? "keys" : "values"
        {append_field(prefix, field, @context), append_field(callback_prefix, field, @context), checked_array_level(array_level)}
      when BinaryDataType::TAG_VARIANT
        component = type_name(child)
        {append_component(prefix, component, @context), append_raw_component(callback_prefix, component, @context), array_level}
      when BinaryDataType::TAG_LOW_CARDINALITY
        raise CorruptPartError.new("Dynamic JSON leaf cannot cross a LowCardinality physical stop-site")
      else
        raise CorruptPartError.new("Dynamic JSON leaf path crosses a non-composite descriptor")
      end
    end

    private def find_dynamic_site_position(
      type : BinaryDataType,
      path : String,
      prefix : String,
      callback_prefix : String,
      array_level : UInt64,
      target_path : String,
      structures : Hash(String, DynamicStructure),
      context : PhysicalStreamPlanContext,
      depth : Int32,
    ) : DynamicSitePosition?
      return nil unless path_is_ancestor_or_equal?(target_path, path)
      context.record_type_node(depth)

      case type.tag
      when BinaryDataType::TAG_DYNAMIC
        if path == target_path
          return DynamicSitePosition.new(prefix, callback_prefix, array_level)
        end
        structure = structures[path]? ||
                    raise CorruptPartError.new("Dynamic ancestor structure is unavailable for site-name discovery")
        arm_count = structure.canonical_variant_count
        # canonical_arms allocates a nullable work array and a detached final
        # array. Charge the maximum retained element count before either one
        # exists, including the implicit SharedVariant arm.
        context.record_elements(arm_count.to_u64) if arm_count > 0
        arms = canonical_arms(structure)
        arms.each_with_index do |arm, index|
          child = generated_path(path, ".arm.", index, context)
          next unless path_is_ancestor_or_equal?(target_path, child)
          arm_prefix = append_component(prefix, arm[0], context)
          callback_arm_prefix = append_raw_component(callback_prefix, arm[0], context)
          if result = find_dynamic_site_position(
               arm[1], child, arm_prefix, callback_arm_prefix, array_level, target_path,
               structures, context, depth + 1
             )
            return result
          end
        end
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED
        context.record_elements(1_u64)
        child = generated_path(path, ".elements", nil, context)
        return find_dynamic_site_position(
          type.child_at(0), child, prefix, callback_prefix, checked_array_level(array_level),
          target_path, structures, context, depth + 1
        ) if path_is_ancestor_or_equal?(target_path, child)
      when BinaryDataType::TAG_NULLABLE
        context.record_elements(1_u64)
        child = generated_path(path, ".nested", nil, context)
        return find_dynamic_site_position(
          type.child_at(0), child, prefix, callback_prefix, array_level, target_path,
          structures, context, depth + 1
        ) if path_is_ancestor_or_equal?(target_path, child)
      when BinaryDataType::TAG_SIMPLE_AGGREGATE
        context.record_elements(1_u64)
        return find_dynamic_site_position(
          type.child_at(0), path, prefix, callback_prefix, array_level, target_path,
          structures, context, depth + 1
        )
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        context.record_elements(type.child_count.to_u64) if type.child_count > 0
        type.child_count.times do |index|
          child = generated_path(path, ".field.", index, context)
          next unless path_is_ancestor_or_equal?(target_path, child)
          field = type.named_tuple? ? type.field_name_at(index) : (index + 1).to_s
          field_prefix = append_field(prefix, field, context)
          callback_field_prefix = append_field(callback_prefix, field, context)
          return find_dynamic_site_position(
            type.child_at(index), child, field_prefix, callback_field_prefix, array_level,
            target_path, structures, context, depth + 1
          )
        end
      when BinaryDataType::TAG_MAP
        context.record_elements(2_u64)
        2.times do |child_index|
          field = child_index == 0 ? "keys" : "values"
          suffix = child_index == 0 ? ".elements.field.0" : ".elements.field.1"
          child = generated_path(path, suffix, nil, context)
          next unless path_is_ancestor_or_equal?(target_path, child)
          field_prefix = append_field(prefix, field, context)
          callback_field_prefix = append_field(callback_prefix, field, context)
          return find_dynamic_site_position(
            type.child_at(child_index), child, field_prefix, callback_field_prefix,
            checked_array_level(array_level), target_path, structures,
            context, depth + 1
          )
        end
      when BinaryDataType::TAG_VARIANT
        context.record_elements(type.child_count.to_u64) if type.child_count > 0
        type.child_count.times do |index|
          child = generated_path(path, ".arm.", index, context)
          next unless path_is_ancestor_or_equal?(target_path, child)
          component = type_name(type.child_at(index))
          arm_prefix = append_component(prefix, component, context)
          callback_arm_prefix = append_raw_component(callback_prefix, component, context)
          return find_dynamic_site_position(
            type.child_at(index), child, arm_prefix, callback_arm_prefix, array_level,
            target_path, structures, context, depth + 1
          )
        end
      end
      nil
    end

    private def canonical_arms(structure : DynamicStructure) : Array(Tuple(String, BinaryDataType))
      # `DynamicStructure#canonical_index_for` calls `type.name`, recursively
      # rendering every arm without this reader's retained type-name budget.
      # The caller already charged the canonical roster slots before entering
      # this allocation. Measure every ordinary arm first, preflight the
      # aggregate name copies before rendering any one name, and avoid a second
      # arm array.
      canonical_count = structure.canonical_variant_count
      measured = Array(Tuple(BinaryDataType, BinaryTypeNameBudget::Bounds)).new(structure.type_count)
      total_name_bytes = 0_u64
      structure.type_count.times do |index|
        type = structure.type_at(index)
        bounds = BinaryTypeNameBudget.measure(type, @type_name_budget)
        if total_name_bytes > UInt64::MAX - bounds[1]
          raise CorruptPartError.new("Dynamic ancestor canonical type-name size overflows UInt64")
        end
        total_name_bytes += bounds[1]
        measured << {type, bounds}
      end
      @type_name_budget.ensure_wire_bytes(total_name_bytes)

      arms = Array(Tuple(String, BinaryDataType)).new(canonical_count)
      arms << {"SharedVariant", BinaryDataType.primitive("String")}
      measured.each do |entry|
        name = BinaryTypeNameBudget.materialize(entry[0], @type_name_budget, entry[1])
        arms << {name, entry[0]}
      end
      arms.sort! { |left, right| left[0] <=> right[0] }
      unless arms.size == canonical_count && arms[structure.shared_index][0] == "SharedVariant"
        raise CorruptPartError.new("Dynamic ancestor canonical arm mapping is invalid")
      end
      arms
    rescue ex : ArgumentError | IndexError
      raise CorruptPartError.new("Dynamic ancestor canonical arm mapping is invalid")
    end

    private def type_name(type : BinaryDataType) : String
      bounds = BinaryTypeNameBudget.measure(type, @type_name_budget)
      BinaryTypeNameBudget.materialize(type, @type_name_budget, bounds)
    end

    private def path_is_ancestor_or_equal?(target : String, candidate : String) : Bool
      return true if target == candidate
      return false if target.bytesize <= candidate.bytesize
      return false unless target.starts_with?(candidate)
      target.byte_at(candidate.bytesize) == '.'.ord.to_u8
    end

    private def generated_path(path : String, suffix : String, index : Int32?, context : PhysicalStreamPlanContext) : String
      size = path.bytesize.to_u64 + suffix.bytesize.to_u64
      size += index.to_s.bytesize.to_u64 if index
      if size > UInt64::MAX // 2_u64
        raise CorruptPartError.new("Dynamic site path size overflows UInt64")
      end
      context.preflight_name_bytes(size * 2_u64)
      context.charge_name_bytes(size * 2_u64)
      String.build do |builder|
        builder << path << suffix
        builder << index if index
      end
    end

    private def append_literal(prefix : String, suffix : String, context : PhysicalStreamPlanContext) : String
      size = prefix.bytesize.to_u64 + suffix.bytesize.to_u64
      context.preflight_name_bytes(size)
      context.charge_name_bytes(size)
      PhysicalStreamName.append_literal(prefix, suffix)
    end

    private def append_component(prefix : String, component : String, context : PhysicalStreamPlanContext) : String
      size = prefix.bytesize.to_u64 + 1_u64 + PhysicalStreamName.escaped_size(component)
      context.preflight_name_bytes(size)
      context.charge_name_bytes(size)
      PhysicalStreamName.append_escaped_component(prefix, component)
    end

    private def append_raw_component(prefix : String, component : String, context : PhysicalStreamPlanContext) : String
      size = prefix.bytesize.to_u64 + 1_u64 + component.bytesize.to_u64
      context.preflight_name_bytes(size)
      context.charge_name_bytes(size)
      PhysicalStreamName.append_literal(prefix, ".#{component}")
    end

    private def append_field(prefix : String, field : String, context : PhysicalStreamPlanContext) : String
      size = prefix.bytesize.to_u64 + 3_u64 + PhysicalStreamName.escaped_size(field)
      context.preflight_name_bytes(size)
      context.charge_name_bytes(size)
      PhysicalStreamName.append_escaped_field(prefix, field)
    end

    private def checked_array_level(level : UInt64) : UInt64
      if level == UInt64::MAX
        raise CorruptPartError.new("Dynamic physical Array level overflows UInt64")
      end
      level + 1_u64
    end
  end
end
