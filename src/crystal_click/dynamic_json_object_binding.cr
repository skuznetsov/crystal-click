module CrystalClick
  # Exact logical association between one Dynamic site/canonical ordinary JSON
  # arm and the existing Object child plan. This does not admit any Object
  # physical lane; those remain owned by ObjectDocumentCodec.
  class DynamicJsonObjectBinding
    getter leaf_key : BinaryDynamicJsonLeafKey
    getter site_key : String
    getter canonical_arm_index : Int32
    getter json_type : BinaryDataType
    getter schema : ObjectDocumentSchema
    getter plan : ObjectDocumentPlan

    @structure : DynamicStructure
    @arm_name : String

    def initialize(
      site_key : String,
      structure : DynamicStructure,
      canonical_arm_index : Int,
      @plan : ObjectDocumentPlan,
      budget : BinaryCodecBudget,
      depth : Int = 1,
    )
      initialize(
        BinaryDynamicJsonLeafKey.new(site_key, canonical_arm_index, [] of Int32),
        structure,
        @plan,
        budget,
        depth,
      )
    end

    def initialize(
      @leaf_key : BinaryDynamicJsonLeafKey,
      structure : DynamicStructure,
      @plan : ObjectDocumentPlan,
      budget : BinaryCodecBudget,
      depth : Int = 1,
      descriptor_root_depth : Int? = nil,
    )
      budget.visit_node(depth)
      site_key_bytes = @leaf_key.dynamic_site_bytesize.to_u64
      budget.ensure_wire_bytes(site_key_bytes)
      budget.charge_wire_bytes(site_key_bytes)
      @site_key = @leaf_key.dynamic_site

      actual_root_depth = descriptor_root_depth || depth - @leaf_key.descriptor_path_size
      if actual_root_depth <= 0
        raise ArgumentError.new("Dynamic JSON binding descriptor root depth must be positive")
      end
      json_type, arm_name = resolve_json_arm(structure, @leaf_key, budget, actual_root_depth)
      @structure = structure
      @canonical_arm_index = @leaf_key.canonical_arm_index
      @arm_name = arm_name
      @json_type = json_type

      descriptor = @json_type.json_type || raise(ArgumentError.new("bound Dynamic arm has no JSON descriptor"))
      if descriptor.skip_path_owner.has_regexp_path?
        if budget.writing?
          raise UnsupportedFormatError.new("Dynamic JSON SKIP REGEXP path has no reparsable canonical SQL name")
        else
          raise CorruptPartError.new("Dynamic JSON SKIP REGEXP path has no reparsable canonical SQL name")
        end
      end
      validate_plan_dynamic_paths!(@plan, descriptor, budget, depth)
      typed_paths = copy_typed_paths(descriptor, budget)
      skip_paths = copy_skip_paths(descriptor, budget, depth + 1)
      @schema = ObjectDocumentSchema.new(
        typed_paths,
        descriptor.max_dynamic_paths,
        descriptor.max_dynamic_types.to_i,
        budget,
        depth: depth,
        skip_paths: skip_paths,
      )
      @schema.validate_plan(@plan, budget, depth: depth)
    end

    # Revalidate the contextual association without using statistics as roster
    # identity. Both complete descriptor rosters are charged before structural
    # equality walks them; canonical arm indices are not actual-array offsets.
    def validate_for!(
      site_key : String,
      structure : DynamicStructure,
      canonical_arm_index : Int,
      budget : BinaryCodecBudget,
      depth : Int = 1,
    ) : Nil
      validate_for!(
        BinaryDynamicJsonLeafKey.new(site_key, canonical_arm_index, [] of Int32),
        structure,
        budget,
        depth,
      )
    end

    def validate_for!(
      leaf_key : BinaryDynamicJsonLeafKey,
      structure : DynamicStructure,
      budget : BinaryCodecBudget,
      depth : Int = 1,
      descriptor_root_depth : Int? = nil,
    ) : Nil
      budget.charge_wire_bytes(leaf_key.dynamic_site_bytesize.to_u64)
      unless @leaf_key == leaf_key
        raise ArgumentError.new("Dynamic JSON binding belongs to a different JSON leaf")
      end

      actual_root_depth = descriptor_root_depth || depth - leaf_key.descriptor_path_size
      if actual_root_depth <= 0
        raise ArgumentError.new("Dynamic JSON binding descriptor root depth must be positive")
      end
      expected_types = canonical_descriptors(@structure, budget, actual_root_depth)
      actual_types = canonical_descriptors(structure, budget, actual_root_depth)
      expected_names = canonical_names(expected_types)
      actual_names = canonical_names(actual_types)
      unless expected_names == actual_names && expected_types.size == actual_types.size
        raise ArgumentError.new("Dynamic JSON binding roster differs from the requested site")
      end

      expected_types.each_with_index do |entry, index|
        unless entry[1] == actual_types[index][1]
          raise ArgumentError.new("Dynamic JSON binding roster differs from the requested site")
        end
      end
      unless actual_names[@canonical_arm_index]? == @arm_name
        raise ArgumentError.new("Dynamic JSON binding canonical arm no longer identifies its actual descriptor")
      end
      actual_arm = actual_types.find { |entry| entry[0] == @arm_name } ||
                   raise(ArgumentError.new("Dynamic JSON binding canonical arm no longer exists"))
      unless @leaf_key.resolve_json_type(actual_arm[1]) == @json_type
        raise ArgumentError.new("Dynamic JSON binding leaf path no longer identifies its JSON descriptor")
      end
      nil
    end

    # The row visitor covers the input descriptor and all retained child trees
    # without copying paths. Charge this captured descriptor too before `==`;
    # callers may supply an equal-but-distinct BinaryJsonType owner.
    def validate_row!(row : BinaryJsonRow, budget : BinaryCodecBudget, depth : Int = 1) : Nil
      row.preflight_for_object!(budget, depth)
      context = BinaryCodecContext.new(budget.limits, nil, budget.writing?, budget, false, false)
      context.validate_type_tree(@json_type, depth)
      unless row.type == @json_type
        raise ArgumentError.new("JSON row descriptor differs from the bound Dynamic arm")
      end
      nil
    end

    private def resolve_json_arm(
      structure : DynamicStructure,
      leaf_key : BinaryDynamicJsonLeafKey,
      budget : BinaryCodecBudget,
      depth : Int,
    ) : Tuple(BinaryDataType, String)
      descriptors = canonical_descriptors(structure, budget, depth)
      names = canonical_names(descriptors)
      canonical_arm_index = leaf_key.canonical_arm_index
      unless 0 <= canonical_arm_index < names.size
        raise ArgumentError.new("Dynamic JSON canonical arm index is outside the ordinary roster")
      end
      name = names[canonical_arm_index]? || raise(ArgumentError.new("Dynamic JSON canonical arm index is outside the ordinary roster"))
      if name == DynamicStructure::SHARED_VARIANT_NAME
        raise ArgumentError.new("SharedVariant is not an ordinary Dynamic JSON arm")
      end

      selected = descriptors.find { |entry| entry[0] == name } ||
                 raise(ArgumentError.new("Dynamic JSON canonical arm is absent from the ordinary roster"))
      {leaf_key.resolve_json_type(selected[1]), name}
    end

    private def canonical_descriptors(
      structure : DynamicStructure,
      budget : BinaryCodecBudget,
      depth : Int,
    ) : Array(Tuple(String, BinaryDataType))
      count = structure.type_count.to_u64
      budget.visit_node(depth)
      # Include the implicit SharedVariant name in the bounded canonical table;
      # actual descriptors remain a separate roster with actual-order indices.
      budget.preflight_children(count + 1_u64)
      bounds = Array(BinaryTypeNameBudget::Bounds).new(structure.type_count)
      structure.type_count.times do |index|
        bounds << BinaryTypeNameBudget.measure(structure.type_at(index), budget, depth)
      end

      entries = Array(Tuple(String, BinaryDataType)).new(structure.type_count)
      structure.type_count.times do |index|
        entries << {
          BinaryTypeNameBudget.materialize(structure.type_at(index), budget, bounds[index]),
          structure.type_at(index),
        }
      end
      entries.sort! { |left, right| left[0] <=> right[0] }
      entries
    end

    private def canonical_names(entries : Array(Tuple(String, BinaryDataType))) : Array(String)
      names = Array(String).new(entries.size + 1)
      names << DynamicStructure::SHARED_VARIANT_NAME
      entries.each { |entry| names << entry[0] }
      names.sort!
      names
    end

    private def copy_typed_paths(
      descriptor : BinaryJsonType,
      budget : BinaryCodecBudget,
    ) : Hash(String, BinaryDataType)
      count = descriptor.typed_path_count.to_u64
      budget.preflight_children(count) if count > 0_u64
      path_bytes = 0_u64
      descriptor.typed_path_count.times do |index|
        size = descriptor.typed_path_byte_size(index).to_u64
        if path_bytes > UInt64::MAX - size
          raise budget.writing? ? UnsupportedFormatError.new("JSON binding path size overflows UInt64") : CorruptPartError.new("JSON binding path size overflows UInt64")
        end
        path_bytes += size
      end
      budget.charge_wire_bytes(path_bytes) if path_bytes > 0_u64

      typed_paths = Hash(String, BinaryDataType).new(initial_capacity: descriptor.typed_path_count)
      descriptor.typed_path_count.times do |index|
        typed_paths[descriptor.typed_path_at(index)] = descriptor.typed_type_at(index)
      end
      typed_paths
    end

    private def copy_skip_paths(
      descriptor : BinaryJsonType,
      budget : BinaryCodecBudget,
      depth : Int,
    ) : Array(String)
      count = descriptor.skip_path_count.to_u64
      budget.ensure_depth(depth) if count > 0_u64
      budget.preflight_children(count) if count > 0_u64
      path_bytes = 0_u64
      descriptor.skip_path_count.times do |index|
        size = descriptor.skip_path_byte_size(index).to_u64
        if path_bytes > UInt64::MAX - size
          raise budget.writing? ? UnsupportedFormatError.new("JSON binding SKIP path size overflows UInt64") : CorruptPartError.new("JSON binding SKIP path size overflows UInt64")
        end
        path_bytes += size
      end
      budget.charge_wire_bytes(path_bytes) if path_bytes > 0_u64

      skip_paths = Array(String).new(descriptor.skip_path_count)
      descriptor.skip_path_count.times do |index|
        skip_paths << descriptor.skip_path_at(index)
      end
      skip_paths
    end

    # The Object plan can represent raw names outside the scalar JSON path
    # grammar. Validate its root dynamic roster without materializing path
    # Strings, using the same caller-owned budget before schema binding.
    private def validate_plan_dynamic_paths!(
      plan : ObjectDocumentPlan,
      descriptor : BinaryJsonType,
      budget : BinaryCodecBudget,
      depth : Int,
    ) : Nil
      object = plan.structures.object
      count = object.dynamic_path_count.to_u64
      if count > descriptor.max_dynamic_paths.to_u64
        raise ArgumentError.new("Object plan exceeds JSON max_dynamic_paths")
      end
      return nil if count == 0_u64

      budget.preflight_children(count)
      budget.ensure_depth(depth + 1)
      object.dynamic_path_count.times { budget.visit_node(depth + 1) }

      path_bytes = 0_u64
      object.dynamic_path_count.times do |index|
        size = object.dynamic_path_byte_size(index).to_u64
        if path_bytes > UInt64::MAX - size
          raise budget.writing? ? UnsupportedFormatError.new("JSON binding Object path bytes overflow UInt64") : CorruptPartError.new("JSON binding Object path bytes overflow UInt64")
        end
        path_bytes += size
      end
      budget.charge_wire_bytes(path_bytes)

      object.dynamic_path_count.times do |index|
        unless valid_plan_path_bytes?(object, index)
          raise ArgumentError.new("Object plan Dynamic path is outside the embedded JSON raw-name bounds")
        end
      end
      nil
    end

    # Preserve BinaryJsonType's embedded path-length cap while delegating raw
    # name identity to the shared SQL path owner. Read Object bytes through a
    # fixed scratch buffer so admission does not allocate a path String.
    private def valid_plan_path_bytes?(object : ObjectStructure, path_index : Int) : Bool
      size = object.dynamic_path_byte_size(path_index)
      return false if size <= 0 || size > BinaryJsonType::MAX_PATH_BYTES

      bytes = StaticArray(UInt8, BinaryJsonType::MAX_PATH_BYTES).new(0_u8)
      size.times do |byte_index|
        bytes[byte_index] = object.dynamic_path_byte_at(path_index, byte_index)
      end
      JsonPathSqlName.valid_raw_bytes?(bytes.to_slice[0, size])
    end
  end
end
