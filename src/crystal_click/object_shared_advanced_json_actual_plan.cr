module CrystalClick
  # Complete descriptor-relative Object child bindings for one JSON-bearing
  # Dynamic actual. Paths identify JSON leaves inside the exact actual type.
  class ObjectSharedAdvancedJsonActualPlan
    getter actual_type : BinaryDataType

    @children : Array(Tuple(Array(Int32), ObjectDocumentPlan))

    def initialize(
      @actual_type : BinaryDataType,
      children : Array(Tuple(Array(Int32), ObjectDocumentPlan)),
    )
      limits = BinaryBulkCodec::DEFAULT_LIMITS
      budget = BinaryCodecBudget.new(limits, true)
      context = BinaryCodecContext.new(limits, nil, true, budget, false, false)
      context.validate_type_tree(@actual_type)
      unless @actual_type.contains_json? && !dynamic_in_json_typed_metadata?(@actual_type)
        raise ArgumentError.new("prepared Dynamic actual must contain JSON and no Dynamic in JSON typed metadata")
      end

      expected = [] of Array(Int32)
      collect_json_paths(@actual_type, [] of Int32, expected)
      unless expected.size == children.size
        raise ArgumentError.new("prepared Dynamic actual must bind every JSON leaf exactly once")
      end

      seen = Set(Array(Int32)).new
      retained = Array(Tuple(Array(Int32), ObjectDocumentPlan)).new(children.size)
      children.each do |entry|
        path = entry[0]
        child_plan = entry[1]
        unless expected.any? { |candidate| candidate == path }
          raise ArgumentError.new("prepared Dynamic actual child path does not identify a JSON leaf")
        end
        if seen.includes?(path)
          raise ArgumentError.new("prepared Dynamic actual JSON child path is duplicated")
        end
        seen.add(path.dup)
        budget.ensure_future_elements(path.size.to_u64 + 1_u64)
        budget.charge_elements(path.size.to_u64 + 1_u64)
        detached_path = path.dup
        retained << {detached_path, child_plan}

        leaf_depth_i64 = 2_i64 + detached_path.size.to_i64
        unless leaf_depth_i64 <= Int32::MAX.to_i64
          raise ArgumentError.new("prepared JSON leaf depth overflows Int32")
        end
        leaf_depth = leaf_depth_i64.to_i32
        budget.ensure_depth(leaf_depth)
        child_plan_depth_i64 = leaf_depth_i64 + 1_i64
        unless child_plan_depth_i64 <= Int32::MAX.to_i64
          raise ArgumentError.new("prepared JSON child depth overflows Int32")
        end
        budget.ensure_depth(child_plan_depth_i64.to_i32)

        # A JSON child Object is itself a prepared schema boundary. Validate
        # every descendant plan, including descriptor-only JSON actuals that
        # have no occurrences in the current value batch. A typed Dynamic
        # declaration inside any such JSON Object remains outside this
        # shared-envelope grammar; root-Dynamic JSON children remain
        # compositional and are traversed through their exact local bindings.
        validate_json_object_plan_tree!(child_plan, budget, child_plan_depth_i64.to_i32)

        # Reuse the established JSON/Object schema binding validator rather
        # than creating a second admission grammar for child plans.
        synthetic = DynamicStructure.new([@actual_type] of BinaryDataType)
        canonical_index = synthetic.canonical_index_for(@actual_type)
        key = BinaryDynamicJsonLeafKey.new("root", canonical_index, detached_path)
        DynamicJsonObjectBinding.new(
          key,
          synthetic,
          child_plan,
          budget,
          depth: leaf_depth,
          descriptor_root_depth: 2,
        )

        # Child Object plans may themselves bind JSON leaves below their root
        # Dynamic paths. Their keys are local to that Object, so recursive
        # readers retain each child plan/prefix scope rather than flattening
        # these keys into the enclosing actual's roster.
      end
      unless seen.size == expected.size && expected.all? { |path| seen.includes?(path) }
        raise ArgumentError.new("prepared Dynamic actual omits a JSON child binding")
      end
      @children = retained
    end

    def child_plan_count : Int32
      @children.size
    end

    def child_descriptor_path_at(index : Int) : Array(Int32)
      @children[index][0].dup
    end

    def child_plan_at(index : Int) : ObjectDocumentPlan
      @children[index][1]
    end

    def child_plan_for(path : Array(Int32)) : ObjectDocumentPlan?
      @children.each do |entry|
        return entry[1] if entry[0] == path
      end
      nil
    end

    private def collect_json_paths(
      type : BinaryDataType,
      path : Array(Int32),
      output : Array(Array(Int32)),
    ) : Nil
      if type.tag == BinaryDataType::TAG_JSON
        output << path.dup
        return nil
      end
      type.child_count.times do |index|
        path << index.to_i32
        collect_json_paths(type.child_at(index), path, output)
        path.pop
      end
      nil
    end

    # Dynamic siblings beside JSON can use the generic Dynamic site plan. A
    # Dynamic descriptor declared inside JSON typed metadata remains outside
    # this shared-envelope slice; runtime JSON paths are fenced by the scoped
    # BinaryCodecContext ancestry check instead.
    private def dynamic_in_json_typed_metadata?(type : BinaryDataType) : Bool
      if type.tag == BinaryDataType::TAG_JSON
        descriptor = type.json_type || return false
        descriptor.typed_path_count.times do |index|
          typed_type = descriptor.typed_type_at(index)
          return true if typed_type.contains_dynamic?
          return true if dynamic_in_json_typed_metadata?(typed_type)
        end
        return false
      end
      type.child_count.times do |index|
        return true if dynamic_in_json_typed_metadata?(type.child_at(index))
      end
      false
    end

    private def validate_json_object_plan_tree!(
      plan : ObjectDocumentPlan,
      budget : BinaryCodecBudget,
      depth : Int32,
    ) : Nil
      budget.visit_node(depth)

      typed_count = plan.typed_path_count.to_u64
      typed_path_bytes = 0_u64
      plan.typed_path_count.times do |index|
        typed_path_bytes = checked_add(typed_path_bytes, plan.typed_path_byte_size_at(index).to_u64)
      end
      if typed_count > 0_u64
        budget.preflight_children(typed_count)
        budget.charge_wire_bytes(typed_path_bytes)
      end

      schema_context = BinaryCodecContext.new(budget.limits, nil, true, budget, false, false)
      plan.typed_path_count.times do |index|
        # Typed path names are detached by this accessor, so reserve their
        # bytes and metadata nodes above before constructing each copy.
        budget.visit_node(depth)
        path = plan.typed_path_at(index)
        type = plan.typed_type_for(path)
        schema_context.validate_type_tree(type, depth + 1)
        if type.contains_dynamic?
          raise ArgumentError.new("Dynamic in JSON-bound Object typed metadata is outside the shared-envelope grammar")
        end
      end

      next_depth = depth.to_i64 + 1_i64
      unless next_depth <= Int32::MAX.to_i64
        raise ArgumentError.new("prepared JSON Object child depth overflows Int32")
      end
      child_depth = next_depth.to_i32
      budget.ensure_depth(child_depth)

      plan.root_dynamic_json_object_leaf_plans(budget).each_value do |bindings|
        bindings.each do |entry|
          validate_json_object_plan_tree!(entry[1], budget, child_depth)
        end
      end
      plan.typed_dynamic_json_object_leaf_plans(budget).each_value do |bindings|
        bindings.each do |entry|
          validate_json_object_plan_tree!(entry[1], budget, child_depth)
        end
      end
      nil
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        raise ArgumentError.new("prepared JSON Object child size overflows UInt64")
      end
      left + right
    end
  end
end
