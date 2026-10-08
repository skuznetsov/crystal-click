module CrystalClick
  # Exact root Dynamic JSON-leaf roster for the ordinary inferred Object
  # actuals. It shares W215's binding/adapter contract without inventing a
  # nominal Dynamic DataType or a second JSON serializer.
  class DynamicJsonObjectBindingRoster
    @structure : DynamicStructure
    @bindings : Hash(BinaryDynamicJsonLeafKey, DynamicJsonObjectBinding)
    @keys : Array(BinaryDynamicJsonLeafKey)
    @depths : Hash(BinaryDynamicJsonLeafKey, Int32)
    @key_bytes : UInt64
    @inferred_actual_root_depth : Int32
    @budget : BinaryCodecBudget

    def self.json_leaf_types_for_root(
      structure : DynamicStructure,
      budget : BinaryCodecBudget,
      inferred_actual_root_depth : Int32 = 1_i32,
    ) : Array(Tuple(BinaryDynamicJsonLeafKey, BinaryDataType, Int32))
      if inferred_actual_root_depth <= 0 || inferred_actual_root_depth > budget.limits.max_depth
        raise budget.writing? ? UnsupportedFormatError.new("inferred Dynamic actual root depth exceeds the configured limit") : CorruptPartError.new("inferred Dynamic actual root depth exceeds the configured limit")
      end

      type_count = structure.type_count.to_u64
      budget.visit_node(inferred_actual_root_depth)
      budget.preflight_children(type_count) if type_count > 0_u64

      context = BinaryCodecContext.new(budget.limits, nil, budget.writing?, budget, false, false)
      structure.type_count.times do |index|
        type = structure.type_at(index)
        # Bound every complete actual descriptor before recursive summary
        # predicates or JSON-leaf discovery inspect it.
        context.validate_type_tree(type, inferred_actual_root_depth)
      end

      has_json = false
      structure.type_count.times do |index|
        has_json ||= structure.type_at(index).contains_json?
      end
      # Preserve the legacy no-JSON path: it needs bounded descriptors, but it
      # does not need canonical names, JSON leaf keys, or a retained roster.
      return [] of Tuple(BinaryDynamicJsonLeafKey, BinaryDataType, Int32) unless has_json

      structure.type_count.times do |index|
        type = structure.type_at(index)
        if type.contains_dynamic?
          reject_actual!(budget, "recursive Dynamic alternatives are not admitted in Dynamic V3")
        end
        if type.contains_variant?
          reject_actual!(budget, "Variant-containing alternatives are not admitted in Dynamic V3")
        end
        if BinaryLowCardinalityTypePolicy.contains_low_cardinality?(type)
          reject_actual!(budget, "Dynamic ordinary LowCardinality alternatives are not admitted")
        end
      end

      # Materialize the canonical ordinary arm table under the same operation
      # budget. The implicit SharedVariant has a canonical index but is never
      # a JSON binding candidate.
      names = Array(Tuple(String, BinaryDataType)).new(structure.type_count)
      structure.type_count.times do |index|
        type = structure.type_at(index)
        bounds = BinaryTypeNameBudget.measure(type, budget, inferred_actual_root_depth)
        names << {BinaryTypeNameBudget.materialize(type, budget, bounds), type}
      end
      names.sort! { |left, right| left[0] <=> right[0] }

      leaf_count = 0_u64
      path_elements = 0_u64
      names.each do |entry|
        type = entry[1]
        next unless type.contains_json?
        counts = count_json_leaves(type, inferred_actual_root_depth, 0_u64, budget)
        leaf_count = checked_add(leaf_count, counts[0], budget)
        path_elements = checked_add(path_elements, counts[1], budget)
      end

      if leaf_count > Int32::MAX.to_u64
        reject_actual!(budget, "inferred Dynamic JSON binding roster exceeds the in-memory domain")
      end
      budget.preflight_children(leaf_count) if leaf_count > 0_u64
      budget.ensure_future_elements(path_elements)
      site_bytes = checked_multiply(leaf_count, "root".bytesize.to_u64, budget)
      path_bytes = checked_multiply(path_elements, 4_u64, budget)
      budget.charge_wire_bytes(checked_add(site_bytes, path_bytes, budget)) if leaf_count > 0_u64
      leaf_count.times { budget.charge_node }
      budget.charge_elements(path_elements) if path_elements > 0_u64

      rows = Array(Tuple(BinaryDynamicJsonLeafKey, BinaryDataType, Int32)).new(leaf_count.to_i)
      names.each do |entry|
        type = entry[1]
        next unless type.contains_json?
        collect_json_leaves(
          type,
          structure.canonical_index_for(type).to_i32,
          [] of Int32,
          inferred_actual_root_depth,
          budget,
          rows,
        )
      end
      unless rows.size.to_u64 == leaf_count
        reject_actual!(budget, "inferred Dynamic JSON binding roster changed during discovery")
      end
      rows
    end

    private def initialize(
      structure : DynamicStructure,
      leaf_plans : Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan)),
      @budget : BinaryCodecBudget,
      inferred_actual_root_depth : Int32,
      expected : Array(Tuple(BinaryDynamicJsonLeafKey, BinaryDataType, Int32)),
    )
      # Never accept a caller-supplied census here. It is an authorization
      # boundary: only a complete descriptor walk under this operation's
      # budget can establish which unused JSON leaves must be bound.
      unless leaf_plans.size == expected.size
        reject_binding!(budget, "inferred Dynamic JSON bindings must exactly cover every JSON actual leaf")
      end

      expected_keys = Hash(BinaryDynamicJsonLeafKey, Tuple(BinaryDataType, Int32)).new(initial_capacity: expected.size)
      expected.each do |entry|
        expected_keys[entry[0]] = {entry[1], entry[2]}
      end
      @structure = structure
      @inferred_actual_root_depth = inferred_actual_root_depth
      @bindings = Hash(BinaryDynamicJsonLeafKey, DynamicJsonObjectBinding).new(initial_capacity: expected.size)
      @depths = Hash(BinaryDynamicJsonLeafKey, Int32).new(initial_capacity: expected.size)
      leaf_plans.each do |entry|
        key = entry[0]
        descriptor = expected_keys[key]?
        unless descriptor
          reject_binding!(budget, "inferred Dynamic JSON binding contains an unknown leaf")
        end
        if @bindings.has_key?(key)
          reject_binding!(budget, "inferred Dynamic JSON binding leaf keys must be unique")
        end
        binding = begin
          DynamicJsonObjectBinding.new(
            key,
            structure,
            entry[1],
            budget,
            depth: descriptor.not_nil![1],
            descriptor_root_depth: inferred_actual_root_depth,
          )
        rescue ex : ArgumentError
          reject_binding!(budget, ex.message || "invalid inferred Dynamic JSON binding")
        end
        @bindings[key] = binding
        @depths[key] = descriptor.not_nil![1]
      end
      unless @bindings.size == expected.size
        reject_binding!(budget, "inferred Dynamic JSON bindings omit a JSON actual leaf")
      end
      @keys = expected.map { |entry| entry[0] }
      @key_bytes = 0_u64
      @keys.each do |key|
        @key_bytes = checked_add(@key_bytes, key.dynamic_site_bytesize.to_u64, budget)
        @key_bytes = checked_add(@key_bytes, checked_multiply(key.descriptor_path_size.to_u64, 4_u64, budget), budget)
      end
    end

    def self.for_root(
      structure : DynamicStructure,
      leaf_plans : Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan)),
      budget : BinaryCodecBudget,
      inferred_actual_root_depth : Int32 = 1_i32,
    ) : DynamicJsonObjectBindingRoster
      expected = json_leaf_types_for_root(structure, budget, inferred_actual_root_depth)
      new(structure, leaf_plans, budget, inferred_actual_root_depth, expected)
    end

    # Bounded probe used by Object plans to preserve the no-JSON route without
    # retaining a nominal roster or materializing canonical actual names.
    # JSON-bearing roots still derive their complete census here under the
    # borrowed operation budget; callers cannot supply or cache that census.
    def self.for_root_if_json(
      structure : DynamicStructure,
      leaf_plans : Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan)),
      budget : BinaryCodecBudget,
      inferred_actual_root_depth : Int32 = 1_i32,
    ) : DynamicJsonObjectBindingRoster?
      expected = json_leaf_types_for_root(structure, budget, inferred_actual_root_depth)
      return nil if expected.empty?
      new(structure, leaf_plans, budget, inferred_actual_root_depth, expected)
    end

    def has_json_object_bindings? : Bool
      !@keys.empty?
    end

    def inferred_actual_root_depth : Int32
      @inferred_actual_root_depth
    end

    def matches_arm_type?(canonical_arm_index : Int, type : BinaryDataType) : Bool
      return false if canonical_arm_index == @structure.shared_index
      @structure.type_count.times do |index|
        candidate = @structure.type_at(index)
        return true if @structure.canonical_index_for(candidate) == canonical_arm_index && candidate == type
      end
      false
    end

    # Sealed admission check for an ordinary physical arm whose JSON leaves
    # are stopped here and emitted by their bound child Object plans. A roster
    # is an authorization only for the exact operation budget, canonical arm,
    # and type from its complete root census.
    def matches_root_json_arm_operation?(
      canonical_arm_index : Int,
      type : BinaryDataType,
      budget : BinaryCodecBudget,
    ) : Bool
      return false unless matches_operation?(self, budget)
      return false unless matches_arm_type?(canonical_arm_index, type)
      @keys.any? { |key| key.canonical_arm_index == canonical_arm_index }
    end

    def json_object_leaf_keys(budget : BinaryCodecBudget) : Array(BinaryDynamicJsonLeafKey)
      count = @keys.size.to_u64
      path_elements = 0_u64
      @keys.each do |key|
        path_elements = checked_add(path_elements, key.descriptor_path_size.to_u64, budget)
      end
      budget.preflight_children(count) if count > 0_u64
      budget.ensure_future_elements(path_elements)
      budget.charge_wire_bytes(@key_bytes) if count > 0_u64
      count.times { budget.charge_node }
      budget.charge_elements(path_elements) if path_elements > 0_u64
      @keys.map { |key| BinaryDynamicJsonLeafKey.new(key.dynamic_site, key.canonical_arm_index, key.descriptor_child_path) }
    end

    # Detached exact leaf keys owned by one canonical ordinary arm. This is
    # the narrow visitor view used while BinaryBulkCodec processes that arm;
    # the enclosing DynamicValueCodec still validates the complete roster.
    def json_object_leaf_keys_for_arm(
      canonical_arm_index : Int,
      budget : BinaryCodecBudget,
    ) : Array(BinaryDynamicJsonLeafKey)
      count = 0_u64
      path_elements = 0_u64
      key_bytes = 0_u64
      @keys.each do |key|
        next unless key.canonical_arm_index == canonical_arm_index
        count = checked_add(count, 1_u64, budget)
        path_elements = checked_add(path_elements, key.descriptor_path_size.to_u64, budget)
        key_bytes = checked_add(key_bytes, key.dynamic_site_bytesize.to_u64, budget)
        key_bytes = checked_add(key_bytes, checked_multiply(key.descriptor_path_size.to_u64, 4_u64, budget), budget)
      end
      budget.preflight_children(count) if count > 0_u64
      budget.ensure_future_elements(path_elements)
      budget.charge_wire_bytes(key_bytes) if key_bytes > 0_u64
      count.times { budget.charge_node }
      budget.charge_elements(path_elements) if path_elements > 0_u64
      keys = Array(BinaryDynamicJsonLeafKey).new(count.to_i)
      @keys.each do |key|
        next unless key.canonical_arm_index == canonical_arm_index
        keys << BinaryDynamicJsonLeafKey.new(key.dynamic_site, key.canonical_arm_index, key.descriptor_child_path)
      end
      keys
    end

    def json_object_binding(key : BinaryDynamicJsonLeafKey) : DynamicJsonObjectBinding
      @bindings[key]? || raise(KeyError.new("inferred Dynamic JSON binding not found"))
    end

    def json_object_leaf_depth(key : BinaryDynamicJsonLeafKey) : Int32
      json_object_leaf_depth(key, @inferred_actual_root_depth)
    end

    def json_object_leaf_depth(key : BinaryDynamicJsonLeafKey, initial_depth : Int) : Int32
      unless @bindings.has_key?(key)
        raise KeyError.new("inferred Dynamic JSON binding not found")
      end
      depth64 = initial_depth.to_i64 + key.descriptor_path_size.to_i64
      if depth64 <= 0_i64 || depth64 > Int32::MAX.to_i64
        raise UnsupportedFormatError.new("inferred Dynamic JSON descriptor depth exceeds Int32")
      end
      depth64.to_i32
    end

    def matches_operation?(roster : DynamicJsonObjectBindingRoster, budget : BinaryCodecBudget) : Bool
      self.same?(roster) && @budget.same?(budget)
    end

    def json_object_binding_key_bytesize_total : UInt64
      @key_bytes
    end

    # Instance entry points keep budget-error direction for retained-key
    # accounting. The class-side counterparts below are used during the
    # descriptor census before this roster exists.
    private def checked_add(left : UInt64, right : UInt64, budget : BinaryCodecBudget) : UInt64
      if left > UInt64::MAX - right
        message = "inferred Dynamic JSON binding budget overflows UInt64"
        raise budget.writing? ? UnsupportedFormatError.new(message) : CorruptPartError.new(message)
      end
      left + right
    end

    private def checked_multiply(left : UInt64, right : UInt64, budget : BinaryCodecBudget) : UInt64
      if right != 0_u64 && left > UInt64::MAX // right
        message = "inferred Dynamic JSON binding budget overflows UInt64"
        raise budget.writing? ? UnsupportedFormatError.new(message) : CorruptPartError.new(message)
      end
      left * right
    end

    private def self.count_json_leaves(
      type : BinaryDataType,
      depth : Int32,
      path_depth : UInt64,
      budget : BinaryCodecBudget,
    ) : Tuple(UInt64, UInt64)
      budget.visit_node(depth)
      case type.tag
      when BinaryDataType::TAG_JSON
        {1_u64, path_depth}
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED, BinaryDataType::TAG_NULLABLE, BinaryDataType::TAG_SIMPLE_AGGREGATE
        unless type.child_count == 1
          reject_actual!(budget, "inferred Dynamic JSON wrapper has an invalid child count")
        end
        count_json_leaves(
          type.child_at(0), checked_depth(depth, budget), checked_add(path_depth, 1_u64, budget), budget
        )
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE, BinaryDataType::TAG_MAP
        leaf_count = 0_u64
        path_elements = 0_u64
        type.child_count.times do |index|
          child_counts = count_json_leaves(
            type.child_at(index), checked_depth(depth, budget), checked_add(path_depth, 1_u64, budget), budget
          )
          leaf_count = checked_add(leaf_count, child_counts[0], budget)
          path_elements = checked_add(path_elements, child_counts[1], budget)
        end
        {leaf_count, path_elements}
      else
        if type.contains_json?
          reject_actual!(budget, "inferred Dynamic JSON leaf crosses an unsupported actual wrapper")
        end
        {0_u64, 0_u64}
      end
    end

    private def self.collect_json_leaves(
      type : BinaryDataType,
      canonical_index : Int32,
      path : Array(Int32),
      depth : Int32,
      budget : BinaryCodecBudget,
      output : Array(Tuple(BinaryDynamicJsonLeafKey, BinaryDataType, Int32)),
    ) : Nil
      case type.tag
      when BinaryDataType::TAG_JSON
        output << {BinaryDynamicJsonLeafKey.new("root", canonical_index, path), type, depth}
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED, BinaryDataType::TAG_NULLABLE, BinaryDataType::TAG_SIMPLE_AGGREGATE
        path << 0_i32
        collect_json_leaves(type.child_at(0), canonical_index, path, checked_depth(depth, budget), budget, output)
        path.pop
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE, BinaryDataType::TAG_MAP
        type.child_count.times do |index|
          path << index.to_i32
          collect_json_leaves(type.child_at(index), canonical_index, path, checked_depth(depth, budget), budget, output)
          path.pop
        end
      end
      nil
    end

    private def self.checked_depth(depth : Int32, budget : BinaryCodecBudget) : Int32
      child_depth = depth.to_i64 + 1_i64
      budget.ensure_depth(child_depth)
      child_depth.to_i32
    end

    private def self.checked_add(left : UInt64, right : UInt64, budget : BinaryCodecBudget) : UInt64
      if left > UInt64::MAX - right
        reject_actual!(budget, "inferred Dynamic JSON binding budget overflows UInt64")
      end
      left + right
    end

    private def self.checked_multiply(left : UInt64, right : UInt64, budget : BinaryCodecBudget) : UInt64
      if right != 0_u64 && left > UInt64::MAX // right
        reject_actual!(budget, "inferred Dynamic JSON binding budget overflows UInt64")
      end
      left * right
    end

    private def self.reject_actual!(budget : BinaryCodecBudget, message : String) : NoReturn
      raise budget.writing? ? UnsupportedFormatError.new(message) : CorruptPartError.new(message)
    end

    private def reject_binding!(budget : BinaryCodecBudget, message : String) : NoReturn
      if budget.writing?
        raise ArgumentError.new(message)
      else
        raise CorruptPartError.new(message)
      end
    end
  end
end
