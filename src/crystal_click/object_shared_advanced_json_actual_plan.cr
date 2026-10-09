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

        # Reuse the established JSON/Object schema binding validator rather
        # than creating a second admission grammar for child plans.
        synthetic = DynamicStructure.new([@actual_type] of BinaryDataType)
        canonical_index = synthetic.canonical_index_for(@actual_type)
        key = BinaryDynamicJsonLeafKey.new("root", canonical_index, detached_path)
        leaf_depth = 2 + detached_path.size
        DynamicJsonObjectBinding.new(
          key,
          synthetic,
          child_plan,
          budget,
          depth: leaf_depth,
          descriptor_root_depth: 2,
        )

        # Inline child discovery currently stops at this Object boundary. Do
        # not prepare a writer binding that would emit a child whose root or
        # typed Dynamic JSON descendants the paired path reader cannot bind.
        # Keep this check on the prepared plan (rather than a generic type
        # summary), since those bindings are the persisted child owner roster.
        unless child_plan.root_dynamic_json_object_leaf_plans(budget).empty? &&
               child_plan.typed_dynamic_json_object_leaf_plans(budget).empty?
          raise ArgumentError.new("prepared JSON child Object cannot contain further JSON-bound Dynamic sites")
        end
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
  end
end
