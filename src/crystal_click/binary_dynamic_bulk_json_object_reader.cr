module CrystalClick
  # Eagerly validates the normalized Dynamic JSON census and all bound Object
  # child streams before the generic decoder traverses any selected window.
  class BinaryDynamicBulkJsonObjectReader
    @plan : BinaryDynamicBulkPlan
    @budget : BinaryCodecBudget
    @documents : Hash(Tuple(String, Int32), Array(Array(ObjectDocument)))
    @cursors : Hash(Tuple(String, Int32), Array(Int32))
    @active_mark : Int32

    def initialize(
      @plan : BinaryDynamicBulkPlan,
      streams : BinaryDynamicBulkStreams,
      rows_per_mark : Array(UInt64),
      @budget : BinaryCodecBudget,
      profile : BinaryBulkProfile,
    )
      unless !@budget.writing?
        raise ArgumentError.new("Dynamic JSON Object reader requires a read-direction budget")
      end

      binding_keys = @plan.json_object_binding_keys(@budget)
      validate_child_keys!(streams, binding_keys)
      physical_rows = validate_parent_grid!(streams.data, rows_per_mark)
      census = validate_and_census_lanes!(streams.data, rows_per_mark.size, profile, binding_keys)

      mark_count = rows_per_mark.size.to_u64
      binding_count = binding_keys.size.to_u64
      # The child result map, cursor map, and one cursor per mark are retained
      # by this owner. Preflight them under the borrowed budget before either
      # map or any child Object decode can allocate its result.
      retained_records = checked_multiply(binding_count, checked_add(mark_count, 2_u64))
      @budget.preflight_children(retained_records) if retained_records > 0_u64
      retained_records.times { @budget.charge_node }
      key_copy_bytes = checked_multiply(@plan.json_object_binding_key_bytesize_total, 2_u64)
      @budget.charge_wire_bytes(key_copy_bytes) if key_copy_bytes > 0_u64

      @documents = Hash(Tuple(String, Int32), Array(Array(ObjectDocument))).new(initial_capacity: binding_keys.size)
      @cursors = Hash(Tuple(String, Int32), Array(Int32)).new(initial_capacity: binding_keys.size)
      @active_mark = -1

      binding_keys.each do |key|
        binding = @plan.json_object_binding(key[0], key[1])
        child_streams = streams.json_object_for(key[0], key[1])
        logical_rows = census[key]
        unless child_streams.rows_per_mark == logical_rows
          corrupt!("Dynamic JSON Object child row grid differs from the discriminator census")
        end

        depth = @plan.depth_for_site(key[0]) + 1
        BinaryDynamicBulkJsonObjectWriter.preflight_binding!(binding, @budget, depth)
        validate_object_metadata!(binding, child_streams, depth)
        validate_typed_dynamic_metadata!(binding, child_streams, depth, profile)

        grid = StorageOccurrenceGrid.new(physical_rows, logical_rows, @budget)
        documents = ObjectDocumentCodec.decode_child_site_with_budget(
          binding.schema.typed_paths,
          child_streams,
          grid,
          @budget,
          first_mark: 0,
          mark_count: rows_per_mark.size,
          profile: profile,
          shared_profile: profile,
        )
        @documents[key] = documents
        @cursors[key] = Array(Int32).new(documents.size, 0)
      end
    end

    def matches_operation?(plan : BinaryDynamicBulkPlan, budget : BinaryCodecBudget) : Bool
      @plan.same?(plan) && @budget.same?(budget)
    end

    def begin_mark(mark_index : Int) : Nil
      @active_mark = mark_index.to_i32
      nil
    end

    def next_row(site : String, canonical_arm_index : Int, depth : Int) : BinaryJsonRow
      key = {site, canonical_arm_index.to_i32}
      binding = @plan.json_object_binding(site, canonical_arm_index)
      expected_depth = @plan.depth_for_site(site) + 1
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
      BinaryJsonObjectAdapter.to_json_row(document, binding, @budget, depth)
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
      expected : Array(Tuple(String, Int32)),
    ) : Nil
      actual = streams.json_object_keys(@budget)
      unless actual.size == expected.size && expected.all? { |key| actual.includes?(key) }
        corrupt!("Dynamic JSON Object child keys do not exactly match the bound actual arms")
      end
      nil
    end

    private def validate_parent_grid!(
      streams : BinaryBulkStreams,
      rows_per_mark : Array(UInt64),
    ) : Array(UInt64)
      real_marks = streams.mark_count
      if real_marks < 0 || rows_per_mark.size != real_marks
        corrupt!("binary bulk row-count grid does not match its mark domain")
      end
      rows_per_mark.each do |rows|
        unless rows > 0_u64 && rows <= Int32::MAX.to_u64
          corrupt!("paired Dynamic JSON parent marks must contain positive Int32 rows")
        end
      end

      expected_role_count = BinaryBulkTypePlan.new(
        @plan.type,
        @plan.profile,
        @plan,
        @budget.limits,
        false,
      ).role_count
      unless streams.role_count.to_u64 == expected_role_count
        corrupt!("binary bulk role set does not exactly match the Dynamic plan")
      end

      offset_count = real_marks.to_i64 + 1_i64
      role_records = checked_multiply(expected_role_count, offset_count.to_u64)
      @budget.preflight_children(role_records) if role_records > 0_u64
      role_records.times { @budget.charge_node }
      @plan.each_data_role do |role|
        unless streams.has_role?(role)
          corrupt!("binary bulk role set does not exactly match the Dynamic plan")
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
      rows_per_mark
    end

    private def validate_and_census_lanes!(
      streams : BinaryBulkStreams,
      mark_count : Int,
      _profile : BinaryBulkProfile,
      binding_keys : Array(Tuple(String, Int32)),
    ) : Hash(Tuple(String, Int32), Array(UInt64))
      mark_records = mark_count.to_u64
      binding_records = binding_keys.size.to_u64
      retained_records = checked_multiply(binding_records, checked_add(mark_records, 1_u64))
      @budget.preflight_children(retained_records) if retained_records > 0_u64
      retained_records.times { @budget.charge_node }
      key_bytes = @plan.json_object_binding_key_bytesize_total
      @budget.charge_wire_bytes(key_bytes) if key_bytes > 0_u64

      counts = Hash(Tuple(String, Int32), Array(UInt64)).new(initial_capacity: binding_keys.size)
      binding_keys.each do |key|
        counts[key] = Array(UInt64).new(mark_count, 0_u64)
      end

      discriminator_bytes = 0_u64
      @plan.each_site_path do |site|
        role = @plan.discriminator_role_for(site)
        lane = streams.stream(role)
        discriminator_bytes = checked_add(discriminator_bytes, lane.byte_size.to_u64)
      end
      @budget.charge_wire_bytes(discriminator_bytes)

      @plan.each_site_path do |site|
        lane = streams.stream(@plan.discriminator_role_for(site))
        mark_count.times do |mark|
          start_offset = lane.offset_at(mark)
          end_offset = lane.offset_at(mark + 1)
          cursor = start_offset
          while cursor < end_offset
            discriminator = lane.byte_at(cursor.to_i32)
            unless discriminator == 0xff_u8 || discriminator.to_i < @plan.arm_count(site)
              corrupt!("Dynamic bulk discriminator is outside its actual arm roster")
            end
            if discriminator != 0xff_u8
              if mark_counts = counts[{site, discriminator.to_i32}]?
                mark_counts[mark] = checked_add(mark_counts[mark], 1_u64)
              end
            end
            cursor += 1_u64
          end
        end
      end
      counts
    end

    private def validate_object_metadata!(
      binding : DynamicJsonObjectBinding,
      streams : ObjectDocumentStreams,
      depth : Int32,
    ) : Nil
      actual = ObjectDynamicStructureCodec.decode_with_budget(streams.structures, @budget)
      expected = binding.plan.structures
      actual.object.dynamic_path_count.times do |index|
        path = actual.object.dynamic_path_at(index)
        BinaryDynamicBulkJsonObjectWriter.preflight_actual_roster!(
          actual.dynamic_for(path),
          @budget,
          depth + 2,
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

        decoded = BinaryDynamicBulkPlan.decode_structure_streams(
          plan.typed_type_for(path),
          streams.typed_dynamic_for(path).structures,
          @budget,
          profile,
        )
        decoded.validate_inherited_depth!(depth + 1, @budget)
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
