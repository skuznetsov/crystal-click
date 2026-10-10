module CrystalClick
  # Recursively validates and collects the exact Object owners represented by
  # JSON leaves in one inline write operation.
  class ObjectDocumentInlineWriteOwners
    alias Owner = Tuple(
      String,
      String,
      ObjectDocumentPhysicalPlan,
      ObjectDocumentPlan,
      ObjectDocumentStreams,
      StorageOccurrenceGrid,
    )

    @owners : Array(Owner)
    @nested_context : ObjectSharedNestedSerializationContext

    def initialize(root_owner : Owner, nested_context : ObjectSharedNestedSerializationContext, budget : BinaryCodecBudget)
      validate_inline_object_version!(root_owner[3])
      @owners = [root_owner] of Owner
      @nested_context = nested_context
      validate_inline_owner_grid!(root_owner, budget)
      collect_inline_write_descendants!(root_owner, budget)
    end

    def size : Int32
      @owners.size
    end

    def each(&block : Owner ->)
      @owners.each { |owner| yield owner }
    end

    def callback_owners(budget : BinaryCodecBudget) : Array(ObjectDocumentInlineCallbackOrder::CallbackOwner)
      count = @owners.size - 1
      if count > 0
        budget.ensure_future_nodes(count.to_u64)
        budget.ensure_future_elements(count.to_u64)
        count.times { budget.charge_node }
        budget.charge_elements(count.to_u64)
      end
      result = [] of ObjectDocumentInlineCallbackOrder::CallbackOwner
      @owners.each_with_index do |owner, index|
        next if index == 0
        result << {owner[0], owner[1], owner[2], owner[3]}
      end
      result
    end

    private def validate_inline_object_version!(plan : ObjectDocumentPlan) : Nil
      unless plan.structures.object.version == 4_u64
        raise UnsupportedFormatError.new("inline child Object prefixes require Object V3 metadata")
      end
      nil
    end

    private def validate_inline_owner_grid!(owner : Owner, budget : BinaryCodecBudget) : Nil
      streams = owner[4]
      grid = owner[5]
      grid.validate_for!(streams.mark_count, budget)
      streams.mark_count.times do |mark|
        unless grid.logical_occurrences_at(mark) == streams.row_count_at(mark)
          raise UnsupportedFormatError.new("inline child Object occurrence grid differs from its stream census")
        end
      end
      nil
    end

    private def collect_inline_write_descendants!(owner : Owner, budget : BinaryCodecBudget) : Nil
      physical_plan = owner[2]
      plan = owner[3]
      streams = owner[4]

      unless physical_plan.shared_profile == @owners[0][2].shared_profile &&
             plan.structures.object.shared_data_version == @nested_context.shared_data_version
        raise UnsupportedFormatError.new("inline JSON descendant changed its inherited shared layout or profile")
      end
      unless streams.typed_dynamic_path_count == plan.typed_dynamic_count
        raise UnsupportedFormatError.new("inline typed Dynamic streams differ from the prepared Object paths")
      end
      plan.typed_dynamic_count.times do |index|
        path = plan.typed_dynamic_path_at(index)
        unless plan.has_typed_dynamic?(path) && streams.has_typed_dynamic_path?(path)
          raise UnsupportedFormatError.new("inline typed Dynamic path is missing from its stream owner")
        end
        collect_typed_dynamic_json_children!(owner, path, budget)
      end

      object = plan.structures.object
      unless streams.dynamic_path_count == object.dynamic_path_count
        raise UnsupportedFormatError.new("inline root Dynamic streams differ from the prepared Object paths")
      end
      object.dynamic_path_count.times do |index|
        path = object.dynamic_path_at(index)
        unless streams.has_dynamic_path?(path)
          raise UnsupportedFormatError.new("inline root Dynamic path is missing from its stream owner")
        end
        collect_root_dynamic_json_children!(owner, path, budget)
      end
      nil
    end

    private def collect_typed_dynamic_json_children!(owner : Owner, path : String, budget : BinaryCodecBudget) : Nil
      physical_plan = owner[2]
      plan = owner[3]
      streams = owner[4]
      dynamic_streams = streams.typed_dynamic_for(path)
      dynamic_physical = physical_plan.typed_dynamic(path)
      bindings = plan.typed_dynamic_json_object_leaf_plans_for(path, budget)
      keys = dynamic_streams.json_object_leaf_keys(budget)
      site_count = dynamic_physical.json_object_site_count
      unless bindings.size == keys.size && keys.size == site_count
        raise UnsupportedFormatError.new("inline typed Dynamic JSON plans, streams, and physical sites differ")
      end

      expected = Hash(BinaryDynamicJsonLeafKey, ObjectDocumentPlan).new(initial_capacity: bindings.size)
      bindings.each do |binding|
        if expected.has_key?(binding[0])
          raise UnsupportedFormatError.new("inline typed Dynamic JSON binding is duplicated")
        end
        expected[binding[0]] = binding[1]
      end
      unless expected.size == keys.size
        raise UnsupportedFormatError.new("inline typed Dynamic JSON binding roster is incomplete")
      end

      structures = plan.typed_dynamic_sites_for(path, budget)
      resolver = BinaryDynamicBulkSiteNameResolver.from_escaped_prefix(
        plan.typed_type_for(path),
        PhysicalStreamName.append_escaped_component(owner[0], path),
        physical_plan.initial_array_level,
        budget.limits,
        budget,
        initial_descriptor_depth: physical_plan.typed_descriptor_root_depth,
        callback_prefix: PhysicalStreamName.append_escaped_component(owner[1], path),
      )
      keys.each do |key|
        child_plan = expected[key]? ||
                     raise(UnsupportedFormatError.new("inline typed Dynamic JSON stream has no declared child plan"))
        site = dynamic_physical.json_object_site(key)
        unless site.leaf_key == key && site.binding.leaf_key == key &&
               site.binding.plan.same?(child_plan) && dynamic_streams.has_json_object_leaf?(key)
          raise UnsupportedFormatError.new("inline typed Dynamic JSON child differs from its exact physical site")
        end
        structure = structures[key.dynamic_site]? ||
                    raise(UnsupportedFormatError.new("inline typed Dynamic JSON site has no complete actual structure"))
        json_depth = dynamic_physical.json_object_leaf_depth(key)
        begin
          site.binding.validate_for!(key, structure, budget, json_depth)
        rescue ex : ArgumentError
          raise UnsupportedFormatError.new(ex.message || "inline typed Dynamic JSON binding changed")
        end
        coordinates = resolver.json_object_leaf_site(key, structures)
        unless coordinates.escaped_prefix == site.escaped_prefix &&
               coordinates.array_level == site.array_level &&
               coordinates.json_type == site.binding.json_type && site.json_depth == json_depth
          raise UnsupportedFormatError.new("inline typed Dynamic JSON site coordinates differ from its descriptor walk")
        end
        append_inline_json_owner!(
          owner,
          key,
          child_plan,
          dynamic_streams.json_object_leaf_for(key),
          site.physical_plan,
          site.escaped_prefix,
          coordinates.callback_prefix,
          site.array_level,
          json_depth,
          true,
          budget,
        )
      end
      nil
    end

    private def collect_root_dynamic_json_children!(owner : Owner, path : String, budget : BinaryCodecBudget) : Nil
      physical_plan = owner[2]
      plan = owner[3]
      streams = owner[4]
      dynamic_streams = streams.dynamic_for(path)
      structure = plan.structures.dynamic_for(path)
      bindings = plan.root_dynamic_json_object_leaf_plans_for(path, budget)
      roster = DynamicJsonObjectBindingRoster.for_root_if_json(
        structure,
        bindings,
        budget,
        physical_plan.inferred_actual_root_depth,
      )
      keys = dynamic_streams.json_object_leaf_keys(budget)
      has_physical = physical_plan.has_root_dynamic_json?(path)
      if roster.nil?
        unless bindings.empty? && keys.empty? && !has_physical
          raise UnsupportedFormatError.new("inline non-JSON root Dynamic path acquired JSON child owners")
        end
        return nil
      end
      unless has_physical
        raise UnsupportedFormatError.new("inline root Dynamic JSON bindings have no exact physical owner")
      end
      dynamic_physical = physical_plan.root_dynamic_json(path)
      unless keys.size == bindings.size && keys.size == dynamic_physical.json_object_site_count
        raise UnsupportedFormatError.new("inline root Dynamic JSON plans, streams, and physical sites differ")
      end

      expected = Hash(BinaryDynamicJsonLeafKey, ObjectDocumentPlan).new(initial_capacity: bindings.size)
      bindings.each do |binding|
        if expected.has_key?(binding[0])
          raise UnsupportedFormatError.new("inline root Dynamic JSON binding is duplicated")
        end
        expected[binding[0]] = binding[1]
      end
      unless expected.size == keys.size
        raise UnsupportedFormatError.new("inline root Dynamic JSON binding roster is incomplete")
      end
      keys.each do |key|
        child_plan = expected[key]? ||
                     raise(UnsupportedFormatError.new("inline root Dynamic JSON stream has no declared child plan"))
        site = dynamic_physical.json_object_site(key)
        unless site.leaf_key == key && site.binding.leaf_key == key &&
               site.binding.plan.same?(child_plan) && dynamic_streams.has_json_object_leaf?(key)
          raise UnsupportedFormatError.new("inline root Dynamic JSON child differs from its exact physical site")
        end
        json_depth = roster.json_object_leaf_depth(key)
        begin
          site.binding.validate_for!(
            key,
            structure,
            budget,
            json_depth,
            physical_plan.inferred_actual_root_depth,
          )
        rescue ex : ArgumentError
          raise UnsupportedFormatError.new(ex.message || "inline root Dynamic JSON binding changed")
        end
        unless site.json_depth == json_depth
          raise UnsupportedFormatError.new("inline root Dynamic JSON site depth differs from its descriptor roster")
        end
        raw_root = ObjectDocumentInlineCallbackOrder.callback_prefix_for_exact_site(
          physical_plan,
          plan,
          owner[1],
          site.escaped_prefix,
          budget,
        )
        append_inline_json_owner!(
          owner,
          key,
          child_plan,
          dynamic_streams.json_object_leaf_for(key),
          site.physical_plan,
          site.escaped_prefix,
          raw_root,
          site.array_level,
          json_depth,
          false,
          budget,
        )
      end
      nil
    end

    private def append_inline_json_owner!(
      parent : Owner,
      key : BinaryDynamicJsonLeafKey,
      child_plan : ObjectDocumentPlan,
      child_streams : ObjectDocumentStreams,
      child_physical : ObjectDocumentPhysicalPlan,
      canonical_root : String,
      raw_root : String,
      array_level : UInt64,
      json_depth : Int32,
      typed_scope : Bool,
      budget : BinaryCodecBudget,
    ) : Nil
      validate_inline_object_version!(child_plan)
      expected_canonical = ObjectDocumentInlineCallbackOrder.canonical_root_prefix(child_physical)
      unless expected_canonical == canonical_root && child_physical.initial_array_level == array_level
        raise UnsupportedFormatError.new("inline JSON child physical root differs from its inherited site coordinates")
      end
      unless child_plan.structures.object.shared_data_version == @nested_context.shared_data_version &&
             child_physical.shared_profile == parent[2].shared_profile
        raise UnsupportedFormatError.new("inline JSON child changed its inherited shared context or profile")
      end
      unless child_streams.mark_count == parent[4].mark_count
        raise UnsupportedFormatError.new("inline JSON child stream differs from its parent mark grid")
      end

      typed_offset = 1_i64
      # Typed-Dynamic children can retain a nominal descriptor envelope; root-Dynamic children bind the bare actual root.
      inferred_offset = if typed_scope && child_plan.structures.object.dynamic_path_count > 0
                          2_i64
                        else
                          1_i64
                        end
      expected_typed_depth = json_depth.to_i64 + typed_offset
      expected_inferred_depth = json_depth.to_i64 + inferred_offset
      budget.ensure_depth(expected_typed_depth)
      budget.ensure_depth(expected_inferred_depth)
      unless child_physical.typed_descriptor_root_depth == expected_typed_depth.to_i32 &&
             child_physical.inferred_actual_root_depth == expected_inferred_depth.to_i32
        raise UnsupportedFormatError.new("inline JSON child lost its inherited descriptor depths")
      end

      physical_rows = physical_rows_from_grid(parent[5], budget)
      count = child_streams.mark_count.to_u64
      records = count * 2_u64
      budget.ensure_future_nodes(records)
      budget.ensure_future_elements(records)
      logical_rows = Array(UInt64).new(child_streams.mark_count)
      child_streams.mark_count.times do |mark|
        logical_rows << child_streams.row_count_at(mark)
        budget.charge_node
      end
      budget.charge_elements(count) if count > 0_u64
      child_grid = StorageOccurrenceGrid.new(physical_rows, logical_rows, budget)
      child_owner : Owner = {
        canonical_root,
        raw_root,
        child_physical,
        child_plan,
        child_streams,
        child_grid,
      }
      validate_inline_owner_grid!(child_owner, budget)
      @owners.each do |existing|
        if existing[0] == canonical_root
          raise UnsupportedFormatError.new("inline JSON physical child owner is duplicated")
        end
      end
      budget.ensure_future_nodes(1_u64)
      budget.ensure_future_elements(1_u64)
      budget.charge_node
      budget.charge_elements(1_u64)
      budget.charge_wire_bytes(canonical_root.bytesize.to_u64 + raw_root.bytesize.to_u64)
      @owners << child_owner
      collect_inline_write_descendants!(child_owner, budget)
      nil
    end

    private def physical_rows_from_grid(grid : StorageOccurrenceGrid, budget : BinaryCodecBudget) : Array(UInt64)
      count = grid.mark_count.to_u64
      budget.ensure_future_nodes(count)
      budget.ensure_future_elements(count)
      rows = Array(UInt64).new(grid.mark_count)
      grid.mark_count.times do |index|
        rows << grid.physical_rows_at(index)
        budget.charge_node
      end
      budget.charge_elements(count)
      rows
    end
  end
end
