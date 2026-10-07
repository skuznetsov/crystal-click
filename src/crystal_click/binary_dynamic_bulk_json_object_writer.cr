module CrystalClick
  # Collects exact Dynamic JSON actual rows during generic bulk preflight, then
  # hands their ObjectDocuments to the existing Object child-site codec.
  class BinaryDynamicBulkJsonObjectWriter
    @plan : BinaryDynamicBulkPlan
    @budget : BinaryCodecBudget
    @physical_rows : Array(UInt64)
    @documents : Hash(BinaryDynamicJsonLeafKey, Array(Array(ObjectDocument)))
    @consumed : Hash(BinaryDynamicJsonLeafKey, Array(Int32))

    def initialize(
      @plan : BinaryDynamicBulkPlan,
      @budget : BinaryCodecBudget,
      granules : Array(Array(BinaryValue)),
      inherited_grid : StorageOccurrenceGrid? = nil,
    )
      unless @budget.writing?
        raise ArgumentError.new("Dynamic JSON Object writer requires a writing budget")
      end
      if grid = inherited_grid
        unless grid.mark_count == granules.size
          raise ArgumentError.new("Dynamic JSON Object writer grid differs from the parent mark count")
        end
      end

      binding_keys = @plan.json_object_leaf_keys(@budget)
      binding_keys.each do |key|
        binding = @plan.json_object_binding(key)
        self.class.preflight_binding!(binding, @budget, @plan.json_object_leaf_depth(key))
      end

      mark_count = granules.size.to_u64
      binding_count = binding_keys.size.to_u64
      # Account before allocating the physical row vector, each binding's
      # mark/document/cursor rows, and both retained key maps. These are
      # logical records, not an estimate of process RSS.
      per_binding_records = checked_add(checked_multiply(mark_count, 3_u64), 4_u64)
      retained_records = checked_add(mark_count, checked_multiply(binding_count, per_binding_records))
      @budget.preflight_children(retained_records) if retained_records > 0_u64
      retained_records.times { @budget.charge_node }
      key_copy_bytes = checked_multiply(@plan.json_object_binding_key_bytesize_total, 2_u64)
      @budget.charge_wire_bytes(key_copy_bytes) if key_copy_bytes > 0_u64

      @physical_rows = Array(UInt64).new(granules.size)
      if grid = inherited_grid
        grid.mark_count.times do |mark|
          @physical_rows << grid.physical_rows_at(mark)
        end
      else
        granules.each do |rows|
          @physical_rows << rows.size.to_u64
        end
      end
      @documents = Hash(BinaryDynamicJsonLeafKey, Array(Array(ObjectDocument))).new(initial_capacity: binding_keys.size)
      @consumed = Hash(BinaryDynamicJsonLeafKey, Array(Int32)).new(initial_capacity: binding_keys.size)

      binding_keys.each do |key|
        marks = Array(Array(ObjectDocument)).new(granules.size) { [] of ObjectDocument }
        cursors = Array(Int32).new(granules.size, 0)
        @documents[key] = marks
        @consumed[key] = cursors
      end
    end

    def matches_operation?(plan : BinaryDynamicBulkPlan, budget : BinaryCodecBudget) : Bool
      @plan.same?(plan) && @budget.same?(budget)
    end

    # Called by BinaryBulkEncoder's whole-input cost pass, before ordinary
    # lane buffers are allocated. Conversion has no second JSON serializer.
    def collect(
      site : String,
      canonical_arm_index : Int,
      row : BinaryJsonRow,
      mark_index : Int,
      depth : Int,
    ) : Nil
      collect(
        BinaryDynamicJsonLeafKey.new(site, canonical_arm_index, [] of Int32),
        row,
        mark_index,
        depth,
      )
    end

    def collect(
      key : BinaryDynamicJsonLeafKey,
      row : BinaryJsonRow,
      mark_index : Int,
      depth : Int,
    ) : Nil
      binding = @plan.json_object_binding(key)
      expected_depth = @plan.json_object_leaf_depth(key)
      unless depth == expected_depth
        raise UnsupportedFormatError.new("Dynamic JSON Object row reached an unexpected inherited depth")
      end
      marks = @documents[key]? || raise(UnsupportedFormatError.new("Dynamic JSON Object writer has no bound child owner"))
      unless 0 <= mark_index < marks.size
        raise UnsupportedFormatError.new("Dynamic JSON Object row is outside the parent mark grid")
      end
      document = BinaryJsonObjectAdapter.to_document(row, binding, @budget, depth)
      marks[mark_index] << document
      nil
    end

    # Nullable NULL serializes its nested default even though the logical
    # child is absent. The matching Object row contains each declared typed
    # path's ordinary default value and no untyped dynamic paths.
    def collect_default(
      key : BinaryDynamicJsonLeafKey,
      mark_index : Int,
      depth : Int,
      profile : BinaryBulkProfile,
    ) : Nil
      binding = @plan.json_object_binding(key)
      descriptor = binding.json_type.json_type ||
                   raise(UnsupportedFormatError.new("bound Dynamic JSON leaf has no descriptor"))
      defaults = Hash(Tuple(UInt64, Bool), BinaryBulkDefaultValue::Cost).new
      total_nodes = 0_u64
      total_edges = 0_u64
      total_wire_bytes = 0_u64
      descriptor.typed_path_count.times do |index|
        type = descriptor.typed_type_at(index)
        cost = BinaryBulkDefaultValue.measure_excluding_low_cardinality(type, profile, defaults, @plan)
        total_nodes = checked_add(total_nodes, cost.nodes)
        total_edges = checked_add(total_edges, cost.edges)
        total_wire_bytes = checked_add(total_wire_bytes, cost.wire_bytes)
      end
      @budget.ensure_future_nodes(total_nodes)
      @budget.ensure_future_elements(total_edges)
      @budget.ensure_wire_bytes(total_wire_bytes)
      @budget.charge_elements(total_edges) if total_edges > 0_u64
      total_nodes.times { @budget.charge_node }
      @budget.charge_wire_bytes(total_wire_bytes) if total_wire_bytes > 0_u64

      values = Array(Tuple(String, BinaryValue)).new(descriptor.typed_path_count)
      descriptor.typed_path_count.times do |index|
        values << {
          descriptor.typed_path_at(index),
          BinaryBulkDefaultValue.build(descriptor.typed_type_at(index), @plan),
        }
      end
      row = BinaryJsonRow.new(binding.json_type, values, @budget, depth: depth)
      collect(key, row, mark_index, depth)
    end

    # Called by the ordinary writer traversal. Per-mark cardinality proves the
    # Dynamic stop-site count matches collection; sequence alignment relies on
    # the encoder's synchronous traversal of the same input granules.
    def consume(site : String, canonical_arm_index : Int, mark_index : Int) : Nil
      consume(BinaryDynamicJsonLeafKey.new(site, canonical_arm_index, [] of Int32), mark_index)
    end

    def consume(key : BinaryDynamicJsonLeafKey, mark_index : Int) : Nil
      @plan.json_object_binding(key)
      marks = @documents[key]? || raise(UnsupportedFormatError.new("Dynamic JSON Object writer has no bound child owner"))
      cursors = @consumed[key]? || raise(UnsupportedFormatError.new("Dynamic JSON Object writer has no child cursor"))
      unless 0 <= mark_index < marks.size
        raise UnsupportedFormatError.new("Dynamic JSON Object child cursor is outside the parent mark grid")
      end
      cursor = cursors[mark_index]
      if cursor >= marks[mark_index].size
        raise UnsupportedFormatError.new("Dynamic JSON Object writer consumed an uncollected child row")
      end
      cursors[mark_index] = cursor + 1
      nil
    end

    def ensure_consumed! : Nil
      @documents.each do |key, marks|
        cursors = @consumed[key]
        marks.each_with_index do |rows, mark_index|
          unless cursors[mark_index] == rows.size
            raise UnsupportedFormatError.new("Dynamic JSON Object writer did not consume the complete child schedule")
          end
        end
      end
      nil
    end

    def finish(profile : BinaryBulkProfile) : Hash(Tuple(String, Int32), ObjectDocumentStreams)
      leaf_streams = finish_leaf_streams(profile)
      if leaf_streams.any? { |key, _| key.descriptor_path_size != 0 }
        raise UnsupportedFormatError.new("legacy Dynamic JSON stream keys cannot represent wrapped JSON leaves")
      end
      output = Hash(Tuple(String, Int32), ObjectDocumentStreams).new(initial_capacity: leaf_streams.size)
      leaf_streams.each do |key, streams|
        output[{key.dynamic_site, key.canonical_arm_index}] = streams
      end
      output
    end

    def finish_leaf_streams(profile : BinaryBulkProfile) : Hash(BinaryDynamicJsonLeafKey, ObjectDocumentStreams)
      ensure_consumed!
      mark_count = @physical_rows.size.to_u64
      binding_count = @documents.size.to_u64
      retained_records = checked_multiply(binding_count, checked_add(mark_count, 1_u64))
      @budget.preflight_children(retained_records) if retained_records > 0_u64
      retained_records.times { @budget.charge_node }
      key_bytes = @plan.json_object_binding_key_bytesize_total
      @budget.charge_wire_bytes(key_bytes) if key_bytes > 0_u64
      output = Hash(BinaryDynamicJsonLeafKey, ObjectDocumentStreams).new(initial_capacity: @documents.size)
      @documents.each do |key, granules|
        binding = @plan.json_object_binding(key)
        logical_rows = Array(UInt64).new(granules.size)
        granules.each { |rows| logical_rows << rows.size.to_u64 }
        grid = StorageOccurrenceGrid.new(@physical_rows, logical_rows, @budget)
        output[key] = ObjectDocumentCodec.encode_child_site_with_budget(
          binding.plan,
          granules,
          grid,
          @budget,
          profile: profile,
          shared_profile: profile,
        )
      end
      output
    end

    # Return the once-decoded ObjectDocuments and a P-by-E child grid for one
    # exact bound arm. P is inherited from the parent storage site when this
    # writer is composed physically; E is the collected Object row cardinality.
    def physical_child_site(
      site : String,
      canonical_arm_index : Int,
    ) : Tuple(Array(Array(ObjectDocument)), StorageOccurrenceGrid)
      physical_child_site(BinaryDynamicJsonLeafKey.new(site, canonical_arm_index, [] of Int32))
    end

    def physical_child_site(
      key : BinaryDynamicJsonLeafKey,
    ) : Tuple(Array(Array(ObjectDocument)), StorageOccurrenceGrid)
      ensure_consumed!
      @plan.json_object_binding(key)
      granules = @documents[key]? ||
                 raise(UnsupportedFormatError.new("Dynamic JSON Object writer has no bound child owner"))
      mark_count = granules.size.to_u64
      grid_records = checked_multiply(mark_count, 2_u64)
      combined_records = checked_add(mark_count, grid_records)
      # The temporary E-count vector and the two detached grid vectors all
      # borrow the operation's aggregate budget. Reserve the combined record
      # domain before allocating the temporary vector; StorageOccurrenceGrid
      # performs its own charge before allocating its pair of arrays.
      @budget.ensure_future_nodes(combined_records)
      @budget.ensure_future_elements(combined_records)
      @budget.preflight_children(mark_count) if mark_count > 0_u64
      mark_count.times { @budget.charge_node }
      logical_rows = Array(UInt64).new(granules.size)
      granules.each { |rows| logical_rows << rows.size.to_u64 }
      grid = StorageOccurrenceGrid.new(@physical_rows, logical_rows, @budget)
      {granules, grid}
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        raise UnsupportedFormatError.new("Dynamic JSON writer record count overflows UInt64")
      end
      left + right
    end

    private def checked_multiply(left : UInt64, right : UInt64) : UInt64
      if right != 0_u64 && left > UInt64::MAX // right
        raise UnsupportedFormatError.new("Dynamic JSON writer record count overflows UInt64")
      end
      left * right
    end

    # Validate every retained descriptor graph under the inherited JSON/Object
    # depth, including actual types below unused root and typed Dynamic rosters.
    # Object metadata is also checked by its own codec; this pass prevents an
    # unused child descriptor from escaping the parent operation's depth cap.
    def self.preflight_binding!(
      binding : DynamicJsonObjectBinding,
      budget : BinaryCodecBudget,
      depth : Int32,
    ) : Nil
      binding.schema.validate_plan(binding.plan, budget, depth: depth)

      context = BinaryCodecContext.new(budget.limits, nil, budget.writing?, budget, false, false)
      binding.plan.typed_path_count.times do |index|
        path = binding.plan.typed_path_at(index)
        context.validate_type_tree(binding.plan.typed_type_for(path), depth + 1)
        next unless binding.plan.has_typed_dynamic?(path)

        binding.plan.typed_dynamic_site_count_for(path).times do |site_index|
          site_path = binding.plan.typed_dynamic_site_path_at(path, site_index)
          structure = binding.plan.typed_dynamic_site_structure_for(path, site_path)
          # object_depth is the Dynamic descriptor's depth from the Object
          # root (Object itself is depth 1). The actual roster starts one edge
          # below that descriptor, so inherited JSON depth contributes directly
          # as D + object_depth.
          actual_depth = depth + binding.plan.typed_dynamic_site_object_depth_for(path, site_path)
          preflight_actual_roster!(structure, budget, actual_depth)
        end
      end

      object = binding.plan.structures.object
      object.dynamic_path_count.times do |path_index|
        structure = binding.plan.structures.dynamic_for(object.dynamic_path_at(path_index))
        preflight_actual_roster!(structure, budget, depth + 2)
      end
      nil
    end

    def self.preflight_actual_roster!(
      structure : DynamicStructure,
      budget : BinaryCodecBudget,
      depth : Int32,
    ) : Nil
      BinaryTypeNameBudget.measure(BinaryDataType.primitive("String"), budget, depth)
      structure.type_count.times do |index|
        BinaryTypeNameBudget.measure(structure.type_at(index), budget, depth)
      end
      nil
    end
  end
end
