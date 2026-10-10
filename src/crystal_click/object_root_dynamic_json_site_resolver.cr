module CrystalClick
  # Resolves a root-only inferred Object Dynamic JSON key to the physical
  # prefix used by the ordinary Object plan. It deliberately does not invent
  # a nominal Dynamic descriptor or use DynamicStructure's unbounded name
  # helpers.
  class ObjectRootDynamicJsonSiteResolver
    @root_prefix : String
    @structure : DynamicStructure
    @budget : BinaryCodecBudget
    @initial_array_level : UInt64
    @inferred_actual_root_depth : Int32
    @name_context : PhysicalStreamPlanContext
    @canonical_arms : Array(Tuple(String, BinaryDataType))

    def self.for_write(
      escaped_object_path_prefix : String,
      structure : DynamicStructure,
      budget : BinaryCodecBudget,
      name_context : PhysicalStreamPlanContext,
      initial_array_level : UInt64 = 0_u64,
      inferred_actual_root_depth : Int32 = 1_i32,
    ) : ObjectRootDynamicJsonSiteResolver
      new(
        escaped_object_path_prefix,
        structure,
        budget,
        name_context,
        initial_array_level,
        inferred_actual_root_depth,
        true,
      )
    end

    def initialize(
      escaped_object_path_prefix : String,
      @structure : DynamicStructure,
      @budget : BinaryCodecBudget,
      @name_context : PhysicalStreamPlanContext,
      initial_array_level : UInt64 = 0_u64,
      inferred_actual_root_depth : Int32 = 1_i32,
      writing_plan : Bool = false,
    )
      unless @budget.writing? == writing_plan
        direction = writing_plan ? "write" : "read"
        raise ArgumentError.new("inferred Object Dynamic JSON resolver requires a #{direction}-direction budget")
      end
      unless same_limits?(@budget.limits, @name_context.limits)
        raise ArgumentError.new("inferred Object Dynamic JSON resolver budgets differ")
      end
      unless inferred_actual_root_depth > 0 && inferred_actual_root_depth <= @budget.limits.max_depth
        raise CorruptPartError.new("inferred Dynamic actual root depth exceeds the configured limit")
      end
      if initial_array_level > UInt64::MAX - @budget.limits.max_depth.to_u64
        raise CorruptPartError.new("inferred Dynamic JSON initial Array level overflows its coordinate")
      end

      escaped_bytes = escaped_object_path_prefix.bytesize.to_u64
      @name_context.preflight_name_bytes(escaped_bytes)
      begin
        PhysicalStreamName.validate_canonical_escaped_prefix(escaped_object_path_prefix)
      rescue ex : ArgumentError
        raise CorruptPartError.new(ex.message || "inferred Dynamic Object path prefix is invalid")
      end
      @name_context.charge_name_bytes(escaped_bytes)
      @root_prefix = String.new(escaped_object_path_prefix.to_slice)
      @initial_array_level = initial_array_level
      @inferred_actual_root_depth = inferred_actual_root_depth
      @canonical_arms = canonical_arms
    end

    # The exact key must identify a JSON leaf under one ordinary root actual.
    # Child paths use the same physical grammar as typed Dynamic JSON sites.
    def resolve_json_leaf(key : BinaryDynamicJsonLeafKey) : ObjectRootDynamicJsonCoordinates
      unless key.dynamic_site == "root"
        raise CorruptPartError.new("inferred Object Dynamic JSON key is not rooted at the Dynamic site")
      end
      arm = @canonical_arms[key.canonical_arm_index]?
      unless arm && arm[0] != DynamicStructure::SHARED_VARIANT_NAME
        raise CorruptPartError.new("inferred Object Dynamic JSON key is outside the ordinary actual roster")
      end

      prefix = append_component(@root_prefix, arm[0])
      selected = arm[1]
      array_level = @initial_array_level
      depth64 = @inferred_actual_root_depth.to_i64
      key.descriptor_path_size.times do |path_index|
        child_index = key.descriptor_child_at(path_index)
        unless 0 <= child_index && child_index < selected.child_count
          raise CorruptPartError.new("inferred Object Dynamic JSON path is outside its actual descriptor")
        end
        child = selected.child_at(child_index)
        depth64 += 1_i64
        if depth64 > Int32::MAX.to_i64 || depth64 > @budget.limits.max_depth.to_i64
          raise CorruptPartError.new("inferred Dynamic JSON descriptor depth exceeds the configured limit")
        end
        prefix, array_level = child_site_coordinates(
          selected,
          child_index,
          child,
          prefix,
          array_level,
          depth64.to_i32,
        )
        selected = child
      end

      unless selected.tag == BinaryDataType::TAG_JSON
        raise CorruptPartError.new("inferred Object Dynamic JSON path does not identify a JSON descriptor")
      end
      @budget.ensure_depth(depth64.to_i)
      ObjectRootDynamicJsonCoordinates.new(
        prefix,
        array_level,
        selected,
        depth64.to_i32,
        @name_context,
      )
    rescue ex : ArgumentError | IndexError
      raise CorruptPartError.new("inferred Object Dynamic JSON descriptor coordinates are invalid")
    end

    private def canonical_arms : Array(Tuple(String, BinaryDataType))
      type_count = @structure.type_count.to_u64
      arm_count = @structure.canonical_variant_count.to_u64
      unless arm_count == type_count + 1_u64 && arm_count <= Int32::MAX.to_u64
        raise CorruptPartError.new("inferred Dynamic canonical arm count is invalid")
      end

      records = type_count + arm_count
      @budget.preflight_children(records) if records > 0_u64
      measured = Array(Tuple(BinaryDataType, BinaryTypeNameBudget::Bounds)).new(@structure.type_count)
      total_name_work = 0_u64
      @structure.type_count.times do |index|
        type = @structure.type_at(index)
        bounds = BinaryTypeNameBudget.measure(type, @budget, @inferred_actual_root_depth)
        total_name_work = checked_add(total_name_work, bounds[1])
        measured << {type, bounds}
      end
      @budget.ensure_wire_bytes(total_name_work)

      arms = Array(Tuple(String, BinaryDataType)).new(arm_count.to_i)
      arms << {String.new(DynamicStructure::SHARED_VARIANT_NAME.to_slice), BinaryDataType.primitive("String")}
      measured.each do |entry|
        name = BinaryTypeNameBudget.materialize(entry[0], @budget, entry[1])
        arms << {name, entry[0]}
      end
      arms.sort! { |left, right| left[0] <=> right[0] }
      shared_arm = arms[@structure.shared_index]?
      unless arms.size.to_u64 == arm_count && shared_arm &&
             shared_arm[0] == DynamicStructure::SHARED_VARIANT_NAME
        raise CorruptPartError.new("inferred Dynamic canonical arm mapping is invalid")
      end
      arms
    rescue ex : ArgumentError | IndexError
      raise CorruptPartError.new("inferred Dynamic canonical arm mapping is invalid")
    end

    private def child_site_coordinates(
      parent : BinaryDataType,
      child_index : Int32,
      child : BinaryDataType,
      prefix : String,
      array_level : UInt64,
      child_depth : Int32,
    ) : Tuple(String, UInt64)
      case parent.tag
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED
        unless child_index == 0
          raise CorruptPartError.new("inferred Dynamic JSON Array path selects an invalid child")
        end
        {prefix, checked_array_level(array_level)}
      when BinaryDataType::TAG_NULLABLE, BinaryDataType::TAG_SIMPLE_AGGREGATE
        unless child_index == 0
          raise CorruptPartError.new("inferred Dynamic JSON wrapper path selects an invalid child")
        end
        {prefix, array_level}
      when BinaryDataType::TAG_UNNAMED_TUPLE
        unless child_index < parent.child_count
          raise CorruptPartError.new("inferred Dynamic JSON Tuple path selects an invalid child")
        end
        {append_field(prefix, (child_index + 1).to_s), array_level}
      when BinaryDataType::TAG_NAMED_TUPLE
        unless child_index < parent.child_count
          raise CorruptPartError.new("inferred Dynamic JSON NamedTuple path selects an invalid child")
        end
        {append_named_field(prefix, parent, child_index), array_level}
      when BinaryDataType::TAG_MAP
        unless child_index == 0 || child_index == 1
          raise CorruptPartError.new("inferred Dynamic JSON Map path selects an invalid child")
        end
        field = child_index == 0 ? "keys" : "values"
        {append_field(prefix, field), checked_array_level(array_level)}
      when BinaryDataType::TAG_VARIANT
        {append_component(prefix, type_name(child, child_depth)), array_level}
      when BinaryDataType::TAG_LOW_CARDINALITY
        raise CorruptPartError.new("inferred Dynamic JSON path cannot cross a LowCardinality physical stop-site")
      else
        raise CorruptPartError.new("inferred Dynamic JSON path crosses a non-composite descriptor")
      end
    end

    private def append_component(prefix : String, component : String) : String
      size = checked_add(prefix.bytesize.to_u64, checked_add(1_u64, PhysicalStreamName.escaped_size(component)))
      @name_context.preflight_name_bytes(size)
      @name_context.charge_name_bytes(size)
      PhysicalStreamName.append_escaped_component(prefix, component)
    end

    private def append_field(prefix : String, field : String) : String
      size = checked_add(prefix.bytesize.to_u64, checked_add(3_u64, PhysicalStreamName.escaped_size(field)))
      @name_context.preflight_name_bytes(size)
      @name_context.charge_name_bytes(size)
      PhysicalStreamName.append_escaped_field(prefix, field)
    end

    private def append_named_field(prefix : String, parent : BinaryDataType, child_index : Int32) : String
      field_size = PhysicalStreamName.escaped_size(parent.field_name_byte_size(child_index)) do |index|
        parent.field_name_byte_at(child_index, index)
      end
      size = checked_add(prefix.bytesize.to_u64, checked_add(3_u64, field_size))
      @name_context.preflight_name_bytes(size)
      field = parent.field_name_at(child_index)
      @name_context.charge_name_bytes(size)
      PhysicalStreamName.append_escaped_field(prefix, field)
    end

    private def type_name(type : BinaryDataType, depth : Int32) : String
      bounds = BinaryTypeNameBudget.measure(type, @budget, depth)
      BinaryTypeNameBudget.materialize(type, @budget, bounds)
    end

    private def checked_array_level(level : UInt64) : UInt64
      if level == UInt64::MAX
        raise CorruptPartError.new("inferred Dynamic JSON Array level overflows UInt64")
      end
      level + 1_u64
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        raise CorruptPartError.new("inferred Dynamic JSON name work overflows UInt64")
      end
      left + right
    end

    private def same_limits?(left : BinaryCodecLimits, right : BinaryCodecLimits) : Bool
      left.max_depth == right.max_depth && left.max_nodes == right.max_nodes &&
        left.max_elements == right.max_elements && left.max_bytes == right.max_bytes
    end
  end
end
