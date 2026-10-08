module CrystalClick
  # Eagerly validates the normalized Dynamic JSON census and all bound Object
  # child streams before the generic decoder traverses any selected window.
  class BinaryDynamicBulkJsonObjectReader
    @plan : BinaryDynamicBulkPlan?
    @root_roster : DynamicJsonObjectBindingRoster?
    @root_type : BinaryDataType?
    @root_canonical_arm_index : Int32
    @budget : BinaryCodecBudget
    @profile : BinaryBulkProfile
    @initial_descriptor_depth : Int32
    @documents : Hash(BinaryDynamicJsonLeafKey, Array(Array(ObjectDocument)))
    @cursors : Hash(BinaryDynamicJsonLeafKey, Array(Int32))
    @active_mark : Int32

    def initialize(
      plan : BinaryDynamicBulkPlan,
      streams : BinaryDynamicBulkStreams,
      rows_per_mark : Array(UInt64),
      @budget : BinaryCodecBudget,
      profile : BinaryBulkProfile,
      physical_rows_per_mark : Array(UInt64)? = nil,
      physical_child_loader : Proc(
        BinaryDynamicJsonLeafKey, DynamicJsonObjectBinding, StorageOccurrenceGrid, BinaryCodecBudget,
        Array(Array(ObjectDocument)),
      )? = nil,
      @initial_descriptor_depth : Int32 = 1,
      child_shared_profile : BinaryBulkProfile = profile,
    )
      @plan = plan
      @root_roster = nil
      @root_type = nil
      @root_canonical_arm_index = -1_i32
      @profile = profile
      @documents = Hash(BinaryDynamicJsonLeafKey, Array(Array(ObjectDocument))).new
      @cursors = Hash(BinaryDynamicJsonLeafKey, Array(Int32)).new
      @active_mark = -1
      unless !@budget.writing?
        raise ArgumentError.new("Dynamic JSON Object reader requires a read-direction budget")
      end
      unless @initial_descriptor_depth > 0 && @initial_descriptor_depth <= @budget.limits.max_depth
        raise ArgumentError.new("Dynamic JSON Object reader initial descriptor depth exceeds the configured limit")
      end

      binding_keys = plan.json_object_leaf_keys(@budget)
      if physical_loader = physical_child_loader
        unless streams.json_object_count == 0
          corrupt!("physical Dynamic JSON child reader cannot mix normalized and physical Object streams")
        end
      else
        validate_child_keys!(streams, binding_keys)
      end
      physical_rows = validate_parent_grid!(
        streams.data,
        rows_per_mark,
        physical_rows_per_mark,
        plan.type,
        profile,
        plan,
      )
      census = BinaryDynamicJsonObjectSchedule.build(
        plan, streams.data, rows_per_mark.size, binding_keys, @budget, @initial_descriptor_depth,
      )

      mark_count = rows_per_mark.size.to_u64
      binding_count = binding_keys.size.to_u64
      # The child result map, cursor map, and one cursor per mark are retained
      # by this owner. Preflight them under the borrowed budget before either
      # map or any child Object decode can allocate its result.
      retained_records = checked_multiply(binding_count, checked_add(mark_count, 2_u64))
      @budget.preflight_children(retained_records) if retained_records > 0_u64
      retained_records.times { @budget.charge_node }
      key_copy_bytes = checked_multiply(plan.json_object_binding_key_bytesize_total, 2_u64)
      @budget.charge_wire_bytes(key_copy_bytes) if key_copy_bytes > 0_u64

      @documents = Hash(BinaryDynamicJsonLeafKey, Array(Array(ObjectDocument))).new(initial_capacity: binding_keys.size)
      @cursors = Hash(BinaryDynamicJsonLeafKey, Array(Int32)).new(initial_capacity: binding_keys.size)

      binding_keys.each do |key|
        binding = plan.json_object_binding(key)
        logical_rows = census[key]
        grid = StorageOccurrenceGrid.new(physical_rows, logical_rows, @budget)
        documents = if physical_loader = physical_child_loader
                      physical_loader.call(key, binding, grid, @budget).tap do |loaded|
                        validate_physical_documents!(loaded, logical_rows)
                      end
                    else
                      child_streams = streams.json_object_leaf_for(key)
                      unless child_streams.rows_per_mark == logical_rows
                        corrupt!("Dynamic JSON Object child row grid differs from the discriminator census")
                      end

                      depth = plan.json_object_leaf_depth(key, @initial_descriptor_depth)
                      BinaryDynamicBulkJsonObjectWriter.preflight_binding!(binding, @budget, depth)
                      validate_object_metadata!(binding, child_streams, depth)
                      validate_typed_dynamic_metadata!(binding, child_streams, depth, @profile)
                      child_root_depth64 = depth.to_i64 + 1_i64
                      @budget.ensure_depth(child_root_depth64)
                      child_root_depth = child_root_depth64.to_i32
                      child_inferred_root_depth = child_inferred_actual_root_depth(depth, binding.plan)
                      child_json_leaf_plans = binding.plan.typed_dynamic_json_object_leaf_plans(@budget)
                      child_root_json_leaf_plans = binding.plan.root_dynamic_json_object_leaf_plans(@budget)
                      ObjectDocumentCodec.decode_child_site_with_budget(
                        binding.schema.typed_paths,
                        child_streams,
                        grid,
                        @budget,
                        first_mark: 0,
                        mark_count: rows_per_mark.size,
                        profile: @profile,
                        shared_profile: child_shared_profile,
                        typed_dynamic_json_object_leaf_plans: child_json_leaf_plans,
                        root_dynamic_json_object_leaf_plans: child_root_json_leaf_plans,
                        typed_descriptor_root_depth: child_root_depth,
                        inferred_actual_root_depth: child_inferred_root_depth,
                      )
                    end
        @documents[key] = documents
        @cursors[key] = Array(Int32).new(documents.size, 0)
      end
    end

    def self.for_root(
      roster : DynamicJsonObjectBindingRoster,
      budget : BinaryCodecBudget,
      arm_type : BinaryDataType,
      canonical_arm_index : Int32,
      streams : BinaryBulkStreams,
      rows_per_mark : Array(UInt64),
      child_streams : Hash(BinaryDynamicJsonLeafKey, ObjectDocumentStreams),
      profile : BinaryBulkProfile,
      physical_rows_per_mark : Array(UInt64)? = nil,
      physical_child_loader : Proc(
        BinaryDynamicJsonLeafKey, DynamicJsonObjectBinding, StorageOccurrenceGrid, Int32, BinaryCodecBudget,
        Array(Array(ObjectDocument)),
      )? = nil,
      initial_descriptor_depth : Int32 = 1_i32,
      child_shared_profile : BinaryBulkProfile = profile,
    ) : BinaryDynamicBulkJsonObjectReader
      new(
        roster,
        budget,
        arm_type,
        canonical_arm_index,
        streams,
        rows_per_mark,
        child_streams,
        profile,
        physical_rows_per_mark,
        physical_child_loader,
        initial_descriptor_depth,
        child_shared_profile,
      )
    end

    private def initialize(
      roster : DynamicJsonObjectBindingRoster,
      @budget : BinaryCodecBudget,
      arm_type : BinaryDataType,
      canonical_arm_index : Int32,
      streams : BinaryBulkStreams,
      rows_per_mark : Array(UInt64),
      child_streams : Hash(BinaryDynamicJsonLeafKey, ObjectDocumentStreams),
      profile : BinaryBulkProfile,
      physical_rows_per_mark : Array(UInt64)?,
      physical_child_loader : Proc(
        BinaryDynamicJsonLeafKey, DynamicJsonObjectBinding, StorageOccurrenceGrid, Int32, BinaryCodecBudget,
        Array(Array(ObjectDocument)),
      )?,
      @initial_descriptor_depth : Int32,
      child_shared_profile : BinaryBulkProfile,
    )
      @plan = nil
      @root_roster = roster
      @root_type = arm_type
      @root_canonical_arm_index = canonical_arm_index
      @profile = profile
      @documents = Hash(BinaryDynamicJsonLeafKey, Array(Array(ObjectDocument))).new
      @cursors = Hash(BinaryDynamicJsonLeafKey, Array(Int32)).new
      @active_mark = -1
      unless !@budget.writing?
        raise ArgumentError.new("inferred Dynamic JSON Object reader requires a read-direction budget")
      end
      unless roster.matches_operation?(roster, @budget)
        corrupt!("inferred Dynamic JSON Object roster belongs to a different operation budget")
      end
      unless @initial_descriptor_depth > 0 && @initial_descriptor_depth <= @budget.limits.max_depth
        raise ArgumentError.new("inferred Dynamic JSON Object reader initial descriptor depth exceeds the configured limit")
      end
      unless roster.inferred_actual_root_depth == @initial_descriptor_depth &&
             roster.matches_arm_type?(canonical_arm_index, arm_type) && arm_type.contains_json?
        corrupt!("inferred Dynamic JSON Object reader arm does not match its complete binding roster")
      end

      type_context = BinaryCodecContext.new(@budget.limits, nil, false, @budget, false, false)
      type_context.validate_type_tree(arm_type, @initial_descriptor_depth)
      binding_keys = roster.json_object_leaf_keys_for_arm(canonical_arm_index, @budget)
      unless !binding_keys.empty?
        corrupt!("inferred Dynamic JSON Object reader arm has no bound JSON leaf")
      end
      if physical_loader = physical_child_loader
        unless child_streams.empty?
          corrupt!("physical inferred Dynamic JSON reader cannot mix normalized and physical Object streams")
        end
      else
        validate_root_child_keys!(child_streams, binding_keys)
      end

      physical_rows = validate_parent_grid!(
        streams,
        rows_per_mark,
        physical_rows_per_mark,
        arm_type,
        profile,
        nil,
        true,
      )
      census = BinaryDynamicJsonObjectSchedule.build_root(
        arm_type,
        streams,
        rows_per_mark,
        binding_keys,
        @budget,
        @initial_descriptor_depth,
      )

      mark_count = rows_per_mark.size.to_u64
      binding_count = binding_keys.size.to_u64
      retained_records = checked_multiply(binding_count, checked_add(mark_count, 2_u64))
      @budget.preflight_children(retained_records) if retained_records > 0_u64
      retained_records.times { @budget.charge_node }
      key_bytes = root_binding_key_bytes(binding_keys)
      key_copy_bytes = checked_multiply(key_bytes, 2_u64)
      @budget.charge_wire_bytes(key_copy_bytes) if key_copy_bytes > 0_u64

      @documents = Hash(BinaryDynamicJsonLeafKey, Array(Array(ObjectDocument))).new(initial_capacity: binding_keys.size)
      @cursors = Hash(BinaryDynamicJsonLeafKey, Array(Int32)).new(initial_capacity: binding_keys.size)
      binding_keys.each do |key|
        binding = roster.json_object_binding(key)
        logical_rows = census[key]? || corrupt!("inferred Dynamic JSON leaf has no occurrence census")
        grid = StorageOccurrenceGrid.new(physical_rows, logical_rows, @budget)
        documents = if physical_loader = physical_child_loader
                      json_depth = roster.json_object_leaf_depth(key, @initial_descriptor_depth)
                      physical_loader.call(key, binding, grid, json_depth, @budget).tap do |loaded|
                        validate_physical_documents!(loaded, logical_rows)
                      end
                    else
                      child = child_streams[key]? || corrupt!("inferred Dynamic JSON Object child stream is missing")
                      unless child.rows_per_mark == logical_rows
                        corrupt!("inferred Dynamic JSON child row grid differs from the root occurrence census")
                      end
                      depth = roster.json_object_leaf_depth(key, @initial_descriptor_depth)
                      BinaryDynamicBulkJsonObjectWriter.preflight_root_binding!(binding, @budget, depth)
                      validate_object_metadata!(binding, child, depth)
                      validate_typed_dynamic_metadata!(binding, child, depth, profile)
                      child_root_depth64 = depth.to_i64 + 1_i64
                      @budget.ensure_depth(child_root_depth64)
                      child_root_depth = child_root_depth64.to_i32
                      child_inferred_root_depth = child_inferred_actual_root_depth(depth, binding.plan)
                      child_json_leaf_plans = binding.plan.typed_dynamic_json_object_leaf_plans(@budget)
                      child_root_json_leaf_plans = binding.plan.root_dynamic_json_object_leaf_plans(@budget)
                      ObjectDocumentCodec.decode_child_site_with_budget(
                        binding.schema.typed_paths,
                        child,
                        grid,
                        @budget,
                        first_mark: 0,
                        mark_count: rows_per_mark.size,
                        profile: profile,
                        shared_profile: child_shared_profile,
                        typed_dynamic_json_object_leaf_plans: child_json_leaf_plans,
                        root_dynamic_json_object_leaf_plans: child_root_json_leaf_plans,
                        typed_descriptor_root_depth: child_root_depth,
                        inferred_actual_root_depth: child_inferred_root_depth,
                      )
                    end
        @documents[key] = documents
        @cursors[key] = Array(Int32).new(documents.size, 0)
      end
    end

    def matches_operation?(plan : BinaryDynamicBulkPlan, budget : BinaryCodecBudget) : Bool
      @plan.try(&.same?(plan)) == true && @budget.same?(budget)
    end

    def matches_root_operation?(
      arm_type : BinaryDataType,
      leaf_key : BinaryDynamicJsonLeafKey,
      budget : BinaryCodecBudget,
      shared_value_depth_origin : Int = 1,
    ) : Bool
      roster = @root_roster
      if root = roster
        root.matches_operation?(root, budget) && @budget.same?(budget) &&
          @root_type == arm_type && @root_canonical_arm_index == leaf_key.canonical_arm_index &&
          leaf_key.dynamic_site == "root" && leaf_key.descriptor_path_size == 0 &&
          @initial_descriptor_depth == shared_value_depth_origin &&
          @initial_descriptor_depth == root.inferred_actual_root_depth &&
          @documents.keys.any? { |key| key.canonical_arm_index == leaf_key.canonical_arm_index }
      else
        false
      end
    end

    def begin_mark(mark_index : Int) : Nil
      @active_mark = mark_index.to_i32
      nil
    end

    def next_row(site : String, canonical_arm_index : Int, depth : Int) : BinaryJsonRow
      next_row(BinaryDynamicJsonLeafKey.new(site, canonical_arm_index, [] of Int32), depth)
    end

    def next_row(key : BinaryDynamicJsonLeafKey, depth : Int) : BinaryJsonRow
      binding = json_object_binding(key)
      # The generic decoder always starts at relative depth one. Inherited
      # descriptor depth belongs only to the Object adapter/physical metadata
      # boundary and must be applied exactly once after this comparison.
      expected_depth = json_object_leaf_depth(key)
      unless depth == expected_depth
        corrupt!("Dynamic JSON Object row reached an unexpected inherited depth")
      end
      documents = @documents[key]? || corrupt!("Dynamic JSON Object child stream is missing")
      cursors = @cursors[key]? || corrupt!("Dynamic JSON Object child cursor is missing")
      unless 0 <= @active_mark < documents.size
        corrupt!("Dynamic JSON Object reader has no active parent mark")
      end
      cursor = cursors[@active_mark]
      if cursor >= documents[@active_mark].size
        corrupt!("Dynamic JSON discriminator exceeds its Object child rows")
      end
      document = documents[@active_mark][cursor]
      cursors[@active_mark] = cursor + 1
      absolute_depth = @initial_descriptor_depth.to_i64 - 1_i64 + depth.to_i64
      if absolute_depth <= 0_i64 || absolute_depth > Int32::MAX.to_i64
        corrupt!("Dynamic JSON Object value depth exceeds Int32")
      end
      BinaryJsonObjectAdapter.to_json_row(document, binding, @budget, absolute_depth.to_i)
    end

    def ensure_consumed! : Nil
      @documents.each do |key, marks|
        cursors = @cursors[key]
        marks.each_with_index do |rows, mark_index|
          unless cursors[mark_index] == rows.size
            corrupt!("Dynamic JSON parent traversal did not consume the complete Object child schedule")
          end
        end
      end
      nil
    end

    private def validate_child_keys!(
      streams : BinaryDynamicBulkStreams,
      expected : Array(BinaryDynamicJsonLeafKey),
    ) : Nil
      actual = streams.json_object_leaf_keys(@budget)
      unless actual.size == expected.size && expected.all? { |key| actual.includes?(key) }
        corrupt!("Dynamic JSON Object child keys do not exactly match the bound actual arms")
      end
      nil
    end

    private def validate_root_child_keys!(
      streams : Hash(BinaryDynamicJsonLeafKey, ObjectDocumentStreams),
      expected : Array(BinaryDynamicJsonLeafKey),
    ) : Nil
      unless streams.size == expected.size && expected.all? { |key| streams.has_key?(key) }
        corrupt!("inferred Dynamic JSON Object child keys do not exactly match the bound actual arm")
      end
      nil
    end

    private def validate_parent_grid!(
      streams : BinaryBulkStreams,
      rows_per_mark : Array(UInt64),
      physical_rows_per_mark : Array(UInt64)?,
      type : BinaryDataType? = nil,
      profile : BinaryBulkProfile? = nil,
      dynamic_plan : BinaryDynamicBulkPlan? = nil,
      allow_bound_json : Bool = false,
    ) : Array(UInt64)
      real_marks = streams.mark_count
      if real_marks < 0 || rows_per_mark.size != real_marks
        corrupt!("binary bulk row-count grid does not match its mark domain")
      end
      physical_child_mode = !physical_rows_per_mark.nil?
      rows_per_mark.each do |rows|
        unless rows <= Int32::MAX.to_u64 && (physical_child_mode || rows > 0_u64)
          corrupt!("paired Dynamic JSON logical mark count is outside its admitted domain")
        end
      end
      physical_rows = physical_rows_per_mark || rows_per_mark
      unless physical_rows.size == real_marks
        corrupt!("Dynamic JSON parent P grid does not match its mark domain")
      end
      physical_rows.each do |rows|
        unless rows > 0_u64 && rows <= Int32::MAX.to_u64
          corrupt!("paired Dynamic JSON parent physical marks must contain positive Int32 rows")
        end
      end

      selected_type = type || @plan.try(&.type) || corrupt!("Dynamic JSON parent type plan is missing")
      selected_profile = profile || @plan.try(&.profile) || corrupt!("Dynamic JSON parent profile is missing")
      json_bound = allow_bound_json || (dynamic_plan.try(&.has_json_object_bindings?) == true)
      type_plan = BinaryBulkTypePlan.new(
        selected_type,
        selected_profile,
        dynamic_plan,
        @budget.limits,
        false,
        json_bound,
      )
      expected_role_count = type_plan.role_count
      unless streams.role_count.to_u64 == expected_role_count
        corrupt!("binary bulk role set does not exactly match the JSON actual descriptor")
      end

      offset_count = real_marks.to_i64 + 1_i64
      role_records = checked_multiply(expected_role_count, offset_count.to_u64)
      @budget.preflight_children(role_records) if role_records > 0_u64
      role_records.times { @budget.charge_node }
      type_plan.roles.each do |role|
        unless streams.has_role?(role)
          corrupt!("binary bulk role set does not exactly match the JSON actual descriptor")
        end
        lane = streams.stream(role)
        unless lane.mark_count == real_marks && lane.offset_count.to_i64 == offset_count
          corrupt!("binary bulk lane has an invalid mark-grid length")
        end
        unless lane.offset_at(0) == 0_u64
          corrupt!("binary bulk lane does not begin at offset zero")
        end
        previous = 0_u64
        1.upto(real_marks) do |mark|
          current = lane.offset_at(mark)
          if current < previous || current > lane.byte_size.to_u64
            corrupt!("binary bulk lane offsets are not monotone within the byte domain")
          end
          previous = current
        end
        unless previous == lane.byte_size.to_u64
          corrupt!("binary bulk lane terminal offset does not match its byte size")
        end
      end
      physical_rows
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
        plan.json_object_leaf_depth(key)
      else
        @root_roster.not_nil!.json_object_leaf_depth(key, 1)
      end
    end

    private def root_binding_key_bytes(keys : Array(BinaryDynamicJsonLeafKey)) : UInt64
      bytes = 0_u64
      keys.each do |key|
        bytes = checked_add(bytes, key.dynamic_site_bytesize.to_u64)
        bytes = checked_add(bytes, checked_multiply(key.descriptor_path_size.to_u64, 4_u64))
      end
      bytes
    end

    private def validate_physical_documents!(
      documents : Array(Array(ObjectDocument)),
      expected_rows : Array(UInt64),
    ) : Nil
      unless documents.size == expected_rows.size
        corrupt!("physical Dynamic JSON Object reader returned the wrong mark count")
      end
      documents.each_with_index do |mark_documents, mark|
        unless mark_documents.size.to_u64 == expected_rows[mark]
          corrupt!("physical Dynamic JSON Object rows differ from the discriminator census")
        end
      end
      nil
    end

    private def validate_object_metadata!(
      binding : DynamicJsonObjectBinding,
      streams : ObjectDocumentStreams,
      depth : Int32,
    ) : Nil
      child_root_depth = child_inferred_actual_root_depth(depth, binding.plan)
      actual = ObjectDynamicStructureCodec.decode_with_budget(
        streams.structures,
        @budget,
        inferred_actual_root_depth: child_root_depth,
      )
      expected = binding.plan.structures
      actual.object.dynamic_path_count.times do |index|
        path = actual.object.dynamic_path_at(index)
        BinaryDynamicBulkJsonObjectWriter.preflight_actual_roster!(
          actual.dynamic_for(path),
          @budget,
          child_root_depth,
        )
      end
      unless same_object_roster?(actual.object, expected.object)
        corrupt!("Dynamic JSON Object child metadata differs from the supplied plan")
      end
      actual.object.dynamic_path_count.times do |index|
        path = actual.object.dynamic_path_at(index)
        unless same_dynamic_roster?(actual.dynamic_for(path), expected.dynamic_for(path))
          corrupt!("Dynamic JSON Object actual roster differs from the supplied plan")
        end
      end
      nil
    end

    # Typed Dynamic JSON sites retain their nominal Dynamic envelope. Bare
    # inferred-root JSON sites do not: their child Object actual origin is the
    # next descriptor depth after the JSON leaf.
    private def child_inferred_actual_root_depth(
      json_depth : Int32,
      child_plan : ObjectDocumentPlan,
    ) : Int32
      offset = if !@plan.nil? && child_plan.structures.object.dynamic_path_count > 0
                 2_i64
               else
                 1_i64
               end
      depth64 = json_depth.to_i64 + offset
      @budget.ensure_depth(depth64)
      depth64.to_i32
    end

    private def validate_typed_dynamic_metadata!(
      binding : DynamicJsonObjectBinding,
      streams : ObjectDocumentStreams,
      depth : Int32,
      profile : BinaryBulkProfile,
    ) : Nil
      plan = binding.plan
      plan.typed_path_count.times do |index|
        path = plan.typed_path_at(index)
        next unless plan.has_typed_dynamic?(path)

        json_leaf_plans = plan.typed_dynamic_json_object_leaf_plans_for(path, @budget)
        decoded = BinaryDynamicBulkPlan.decode_structure_streams(
          plan.typed_type_for(path),
          streams.typed_dynamic_for(path).structures,
          @budget,
          profile,
          nil,
          json_leaf_plans.empty? ? nil : json_leaf_plans,
        )
        child_root_depth64 = depth.to_i64 + 1_i64
        @budget.ensure_depth(child_root_depth64)
        decoded.validate_inherited_depth!(child_root_depth64.to_i32, @budget)
        expected_site_count = plan.typed_dynamic_site_count_for(path)
        unless decoded.site_count == expected_site_count
          corrupt!("typed Dynamic Object child sites differ from the supplied plan")
        end
        expected_site_count.times do |site_index|
          site_path = plan.typed_dynamic_site_path_at(path, site_index)
          unless decoded.has_site?(site_path) &&
                 decoded.type_for_site(site_path) == plan.typed_dynamic_site_type_for(path, site_path) &&
                 same_dynamic_roster?(decoded.structure_for(site_path), plan.typed_dynamic_site_structure_for(path, site_path))
            corrupt!("typed Dynamic Object actual roster differs from the supplied plan")
          end
        end
      end
      nil
    end

    # Object path order and positional statistics are serialization details:
    # the codec sorts paths and reorders statistics with them. Schema identity
    # is the version/caps plus the complete raw-path set.
    private def same_object_roster?(actual : ObjectStructure, expected : ObjectStructure) : Bool
      return false unless actual.version == expected.version &&
                          actual.shared_data_version == expected.shared_data_version &&
                          actual.bucket_count == expected.bucket_count &&
                          actual.legacy_max_dynamic_paths == expected.legacy_max_dynamic_paths &&
                          actual.dynamic_path_count == expected.dynamic_path_count
      actual.dynamic_path_count.times do |index|
        return false unless expected.has_dynamic_path?(actual.dynamic_path_at(index))
      end
      true
    end

    # Dynamic actual descriptors are an unordered canonical roster and the
    # statistics vector is only a hint. Compare the complete descriptor set by
    # canonical names after both graphs have been depth-preflighted.
    private def same_dynamic_roster?(actual : DynamicStructure, expected : DynamicStructure) : Bool
      return false unless actual.type_count == expected.type_count && actual.shared_index == expected.shared_index
      actual.type_count.times do |actual_index|
        actual_type = actual.type_at(actual_index)
        found = false
        expected.type_count.times do |expected_index|
          expected_type = expected.type_at(expected_index)
          if actual_type.name == expected_type.name && actual_type == expected_type
            found = true
            break
          end
        end
        return false unless found
      end
      true
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        corrupt!("Dynamic JSON reader count overflows UInt64")
      end
      left + right
    end

    private def checked_multiply(left : UInt64, right : UInt64) : UInt64
      if right != 0_u64 && left > UInt64::MAX // right
        corrupt!("Dynamic JSON lane-grid count overflows UInt64")
      end
      left * right
    end

    private def corrupt!(message : String) : NoReturn
      raise CorruptPartError.new(message)
    end
  end
end
