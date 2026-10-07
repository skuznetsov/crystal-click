module CrystalClick
  # Resolves one Dynamic structure lane before the complete actual-roster
  # physical plan exists. The prepared site roster may itself reveal another
  # Dynamic site, so this resolver follows only the requested root-to-site
  # path and consults already-parsed ancestor structures.
  class BinaryDynamicBulkSiteNameResolver
    @type : BinaryDataType
    @root_prefix : String
    @limits : BinaryCodecLimits
    @context : PhysicalStreamPlanContext
    @type_name_budget : BinaryCodecBudget

    def initialize(type : BinaryDataType, column_name : String, @limits : BinaryCodecLimits)
      # Public discovery must not call recursive summary predicates or render a
      # path before the complete caller descriptor has a bounded name walk.
      budget = BinaryCodecBudget.new(@limits)
      bounds = BinaryTypeNameBudget.measure(type, budget)
      BinaryTypeNameBudget.materialize(type, budget, bounds)
      @context = PhysicalStreamPlanContext.new(@limits)
      escaped_size = PhysicalStreamName.escaped_size(column_name)
      @context.preflight_name_bytes(escaped_size)
      @root_prefix = PhysicalStreamName.escape(column_name, @context)
      @context.charge_name_bytes(escaped_size)
      # This resolver is used while reading persisted structure lanes. Keep
      # malformed source metadata in the corruption domain rather than
      # reporting a caller-side write rejection.
      @type_name_budget = BinaryCodecBudget.new(@limits)
      @type = type
    end

    # Returns the unhashed logical stream name expected in
    # columns_substreams.txt. `structures` contains only sites already loaded
    # in parent-first order; no unknown arm name is guessed.
    def structure_stream_name(target_path : String, structures : Hash(String, DynamicStructure)) : String
      resolved = find_structure_name(
        @type, "root", @root_prefix, 0_u64, target_path, structures,
        @context, 1
      )
      resolved || raise(CorruptPartError.new("Dynamic structure site has no physical name"))
    end

    private def find_structure_name(
      type : BinaryDataType,
      path : String,
      prefix : String,
      array_level : UInt64,
      target_path : String,
      structures : Hash(String, DynamicStructure),
      context : PhysicalStreamPlanContext,
      depth : Int32,
    ) : String?
      return nil unless path_is_ancestor_or_equal?(target_path, path)
      context.record_type_node(depth)

      case type.tag
      when BinaryDataType::TAG_DYNAMIC
        if path == target_path
          return append_literal(prefix, ".dynamic_structure", context)
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
          if result = find_structure_name(
               arm[1], child, arm_prefix, array_level, target_path,
               structures, context, depth + 1
             )
            return result
          end
        end
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED
        context.record_elements(1_u64)
        child = generated_path(path, ".elements", nil, context)
        return find_structure_name(
          type.child_at(0), child, prefix, checked_array_level(array_level),
          target_path, structures, context, depth + 1
        ) if path_is_ancestor_or_equal?(target_path, child)
      when BinaryDataType::TAG_NULLABLE
        context.record_elements(1_u64)
        child = generated_path(path, ".nested", nil, context)
        return find_structure_name(
          type.child_at(0), child, prefix, array_level, target_path,
          structures, context, depth + 1
        ) if path_is_ancestor_or_equal?(target_path, child)
      when BinaryDataType::TAG_SIMPLE_AGGREGATE
        context.record_elements(1_u64)
        return find_structure_name(
          type.child_at(0), path, prefix, array_level, target_path,
          structures, context, depth + 1
        )
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        context.record_elements(type.child_count.to_u64) if type.child_count > 0
        type.child_count.times do |index|
          child = generated_path(path, ".field.", index, context)
          next unless path_is_ancestor_or_equal?(target_path, child)
          field = type.named_tuple? ? type.field_name_at(index) : (index + 1).to_s
          field_prefix = append_field(prefix, field, context)
          return find_structure_name(
            type.child_at(index), child, field_prefix, array_level,
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
          return find_structure_name(
            type.child_at(child_index), child, field_prefix,
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
          return find_structure_name(
            type.child_at(index), child, arm_prefix, array_level,
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
