module CrystalClick
  # Collects exact Dynamic JSON actual rows during generic bulk preflight, then
  # hands their ObjectDocuments to the existing Object child-site codec.
  class BinaryDynamicBulkJsonObjectWriter
    @plan : BinaryDynamicBulkPlan?
    @root_roster : DynamicJsonObjectBindingRoster?
    @root_arm_type : BinaryDataType?
    @canonical_arm_index : Int32
    @budget : BinaryCodecBudget
    @initial_descriptor_depth : Int32
    @physical_rows : Array(UInt64)
    @documents : Hash(BinaryDynamicJsonLeafKey, Array(Array(ObjectDocument)))
    @consumed : Hash(BinaryDynamicJsonLeafKey, Array(Int32))

    def initialize(
      plan : BinaryDynamicBulkPlan,
      @budget : BinaryCodecBudget,
      granules : Array(Array(BinaryValue)),
      inherited_grid : StorageOccurrenceGrid? = nil,
      initial_descriptor_depth : Int32 = 1,
    )
      @plan = plan
      @root_roster = nil
      @root_arm_type = nil
      @canonical_arm_index = -1_i32
      # Assign every non-nilable owner field in each initializer. Crystal does
      # not treat assignments performed by a later private helper as definite
      # initialization of the instance variables.
      @physical_rows = [] of UInt64
      @documents = Hash(BinaryDynamicJsonLeafKey, Array(Array(ObjectDocument))).new
      @consumed = Hash(BinaryDynamicJsonLeafKey, Array(Int32)).new
      unless @budget.writing?
        raise ArgumentError.new("Dynamic JSON Object writer requires a writing budget")
      end
      @budget.ensure_depth(initial_descriptor_depth)
      @initial_descriptor_depth = initial_descriptor_depth
      initialize_documents(granules, inherited_grid, plan.json_object_leaf_keys(@budget))
    end

    def initialize(
      roster : DynamicJsonObjectBindingRoster,
      @budget : BinaryCodecBudget,
      granules : Array(Array(BinaryValue)),
      root_arm_type : BinaryDataType,
      canonical_arm_index : Int32,
      inherited_grid : StorageOccurrenceGrid? = nil,
      initial_descriptor_depth : Int32 = 1,
    )
      @plan = nil
      @root_roster = roster
      @root_arm_type = root_arm_type
      @canonical_arm_index = canonical_arm_index
      @physical_rows = [] of UInt64
      @documents = Hash(BinaryDynamicJsonLeafKey, Array(Array(ObjectDocument))).new
      @consumed = Hash(BinaryDynamicJsonLeafKey, Array(Int32)).new
      unless @budget.writing?
        raise ArgumentError.new("inferred Dynamic JSON Object writer requires a writing budget")
      end
      unless roster.matches_operation?(roster, @budget)
        raise ArgumentError.new("inferred Dynamic JSON Object roster belongs to a different operation budget")
      end
      unless roster.matches_root_json_arm_operation?(canonical_arm_index, root_arm_type, @budget)
        raise ArgumentError.new("inferred Dynamic JSON Object writer arm does not match its complete binding roster")
      end
      unless initial_descriptor_depth == roster.inferred_actual_root_depth
        raise ArgumentError.new("inferred Dynamic JSON Object writer origin differs from its binding roster")
      end
      @budget.ensure_depth(initial_descriptor_depth)
      @initial_descriptor_depth = initial_descriptor_depth
      unless root_arm_type.contains_json?
        raise ArgumentError.new("inferred Dynamic JSON Object writer arm has no JSON leaf")
      end
      initialize_documents(
        granules,
        inherited_grid,
        roster.json_object_leaf_keys_for_arm(canonical_arm_index, @budget),
      )
    end

    def self.for_root(
      roster : DynamicJsonObjectBindingRoster,
      budget : BinaryCodecBudget,
      granules : Array(Array(BinaryValue)),
      arm_type : BinaryDataType,
      canonical_arm_index : Int32,
      inherited_grid : StorageOccurrenceGrid? = nil,
      initial_descriptor_depth : Int32 = 1,
    ) : BinaryDynamicBulkJsonObjectWriter
      new(roster, budget, granules, arm_type, canonical_arm_index, inherited_grid, initial_descriptor_depth)
    end

    private def initialize_documents(
      granules : Array(Array(BinaryValue)),
      inherited_grid : StorageOccurrenceGrid?,
      binding_keys : Array(BinaryDynamicJsonLeafKey),
    ) : Nil
      if grid = inherited_grid
        unless grid.mark_count == granules.size
          raise ArgumentError.new("Dynamic JSON Object writer grid differs from the parent mark count")
        end
      end

      if binding_keys.empty?
        raise ArgumentError.new("Dynamic JSON Object writer arm has no bound JSON leaf")
      end
      binding_keys.each do |key|
        binding = json_object_binding(key)
        if @root_roster
          self.class.preflight_root_binding!(binding, @budget, json_object_leaf_depth(key))
        else
          self.class.preflight_binding!(binding, @budget, json_object_leaf_depth(key))
        end
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
      key_copy_bytes = checked_multiply(binding_key_bytesize_total(binding_keys), 2_u64)
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
      nil
    end

    def matches_operation?(plan : BinaryDynamicBulkPlan, budget : BinaryCodecBudget) : Bool
      @plan.try(&.same?(plan)) == true && @budget.same?(budget)
    end

    def matches_root_operation?(roster : DynamicJsonObjectBindingRoster, budget : BinaryCodecBudget) : Bool
      @root_roster.try(&.matches_operation?(roster, budget)) == true && @budget.same?(budget)
    end

    # Generic bulk root entry point for one ordinary actual arm. The seed key
    # is the explicit authority to route root JSON leaves without wrapping the
    # descriptor in a nominal Dynamic plan.
    def matches_root_operation?(
      arm_type : BinaryDataType,
      leaf_key : BinaryDynamicJsonLeafKey,
      budget : BinaryCodecBudget,
      shared_value_depth_origin : Int = 1,
    ) : Bool
      roster = @root_roster
      return false unless roster
      @plan.nil? && @budget.same?(budget) && @root_arm_type == arm_type &&
        roster.matches_root_json_arm_operation?(@canonical_arm_index, arm_type, budget) &&
        @canonical_arm_index == leaf_key.canonical_arm_index &&
        leaf_key.dynamic_site == "root" && leaf_key.descriptor_path_size == 0 &&
        @initial_descriptor_depth == shared_value_depth_origin &&
        @initial_descriptor_depth == roster.inferred_actual_root_depth &&
        @documents.keys.any? { |key| key.canonical_arm_index == leaf_key.canonical_arm_index }
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
      binding = json_object_binding(key)
      absolute_depth = absolute_json_depth(depth)
      expected_depth = json_object_leaf_depth(key)
      unless absolute_depth == expected_depth
        raise UnsupportedFormatError.new("Dynamic JSON Object row reached an unexpected inherited depth")
      end
      marks = @documents[key]? || raise(UnsupportedFormatError.new("Dynamic JSON Object writer has no bound child owner"))
      unless 0 <= mark_index < marks.size
        raise UnsupportedFormatError.new("Dynamic JSON Object row is outside the parent mark grid")
      end
      document = BinaryJsonObjectAdapter.to_document(row, binding, @budget, absolute_depth)
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
      binding = json_object_binding(key)
      descriptor = binding.json_type.json_type ||
                   raise(UnsupportedFormatError.new("bound Dynamic JSON leaf has no descriptor"))
      absolute_depth = absolute_json_depth(depth)
      defaults = Hash(Tuple(UInt64, Bool), BinaryBulkDefaultValue::Cost).new
      total_nodes = 0_u64
      total_edges = 0_u64
      total_wire_bytes = 0_u64
      descriptor.typed_path_count.times do |index|
        type = descriptor.typed_type_at(index)
        cost = BinaryBulkDefaultValue.measure_excluding_low_cardinality(type, profile, defaults, @plan, true)
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
      row = BinaryJsonRow.new(binding.json_type, values, @budget, depth: absolute_depth)
      collect(key, row, mark_index, depth)
    end

    # Called by the ordinary writer traversal. Per-mark cardinality proves the
    # Dynamic stop-site count matches collection; sequence alignment relies on
    # the encoder's synchronous traversal of the same input granules.
    def consume(site : String, canonical_arm_index : Int, mark_index : Int) : Nil
      consume(BinaryDynamicJsonLeafKey.new(site, canonical_arm_index, [] of Int32), mark_index)
    end

    def consume(key : BinaryDynamicJsonLeafKey, mark_index : Int) : Nil
      json_object_binding(key)
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

    def finish_leaf_streams(
      profile : BinaryBulkProfile,
      child_shared_profile : BinaryBulkProfile = profile,
    ) : Hash(BinaryDynamicJsonLeafKey, ObjectDocumentStreams)
      ensure_consumed!
      mark_count = @physical_rows.size.to_u64
      binding_count = @documents.size.to_u64
      retained_records = checked_multiply(binding_count, checked_add(mark_count, 1_u64))
      @budget.preflight_children(retained_records) if retained_records > 0_u64
      retained_records.times { @budget.charge_node }
      key_bytes = binding_key_bytesize_total(@documents.keys)
      @budget.charge_wire_bytes(key_bytes) if key_bytes > 0_u64
      output = Hash(BinaryDynamicJsonLeafKey, ObjectDocumentStreams).new(initial_capacity: @documents.size)
      @documents.each do |key, granules|
        binding = json_object_binding(key)
        logical_rows = Array(UInt64).new(granules.size)
        granules.each { |rows| logical_rows << rows.size.to_u64 }
        grid = StorageOccurrenceGrid.new(@physical_rows, logical_rows, @budget)
        json_depth = json_object_leaf_depth(key)
        child_root_depth64 = json_depth.to_i64 + 1_i64
        @budget.ensure_depth(child_root_depth64)
        child_root_depth = child_root_depth64.to_i32
        child_inferred_offset = if @plan.nil? || binding.plan.structures.object.dynamic_path_count == 0
                                  1_i64
                                else
                                  2_i64
                                end
        child_inferred_root_depth64 = json_depth.to_i64 + child_inferred_offset
        @budget.ensure_depth(child_inferred_root_depth64)
        child_inferred_root_depth = child_inferred_root_depth64.to_i32
        output[key] = ObjectDocumentCodec.encode_child_site_with_budget(
          binding.plan,
          granules,
          grid,
          @budget,
          profile: profile,
          shared_profile: child_shared_profile,
          typed_descriptor_root_depth: child_root_depth,
          inferred_actual_root_depth: child_inferred_root_depth,
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
      json_object_binding(key)
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

    private def binding_key_bytesize_total(keys : Array(BinaryDynamicJsonLeafKey)) : UInt64
      total = 0_u64
      keys.each do |key|
        path_bytes = checked_multiply(key.descriptor_path_size.to_u64, 4_u64)
        total = checked_add(total, key.dynamic_site_bytesize.to_u64)
        total = checked_add(total, path_bytes)
      end
      total
    end

    private def absolute_json_depth(relative_depth : Int) : Int32
      depth = @initial_descriptor_depth.to_i64 - 1_i64 + relative_depth.to_i64
      @budget.ensure_depth(depth)
      depth.to_i32
    end

    private def json_object_binding(key : BinaryDynamicJsonLeafKey) : DynamicJsonObjectBinding
      if plan = @plan
        plan.json_object_binding(key)
      else
        @root_roster.not_nil!.json_object_binding(key)
      end
    end

    private def json_object_leaf_depth(key : BinaryDynamicJsonLeafKey) : Int32
      if plan = @plan
        plan.json_object_leaf_depth(key, @initial_descriptor_depth)
      else
        @root_roster.not_nil!.json_object_leaf_depth(key, @initial_descriptor_depth)
      end
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
      self.preflight_binding_with_actual_root_offset!(binding, budget, depth, 2_i64)
    end

    # An inferred-root JSON child has no enclosing nominal Dynamic descriptor;
    # its child Object actuals begin one edge below the JSON descriptor.
    def self.preflight_root_binding!(
      binding : DynamicJsonObjectBinding,
      budget : BinaryCodecBudget,
      depth : Int32,
    ) : Nil
      self.preflight_binding_with_actual_root_offset!(binding, budget, depth, 1_i64)
    end

    private def self.preflight_binding_with_actual_root_offset!(
      binding : DynamicJsonObjectBinding,
      budget : BinaryCodecBudget,
      depth : Int32,
      actual_root_offset : Int64,
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
      if object.dynamic_path_count > 0
        actual_root_depth64 = depth.to_i64 + actual_root_offset
        budget.ensure_depth(actual_root_depth64)
        actual_root_depth = actual_root_depth64.to_i32
        object.dynamic_path_count.times do |path_index|
          structure = binding.plan.structures.dynamic_for(object.dynamic_path_at(path_index))
          preflight_actual_roster!(structure, budget, actual_root_depth)
        end
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
