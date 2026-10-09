module CrystalClick
  # Bridges an ordinary Dynamic JSON leaf to the existing nested Object
  # callback owners. This class owns no value grammar: it only binds the
  # descriptor-relative leaf to the child Object's inline callback roster.
  class ObjectSharedPathJsonTapeCodec
    alias Callback = Tuple(String, Bytes)
    alias FragmentMap = Hash(BinaryDynamicJsonLeafKey, ObjectSharedAdvancedInlineRawLayout)
    alias PrefixMap = Hash(BinaryDynamicJsonLeafKey, ObjectDocumentInlinePrefix)

    def self.write_fragments(
      type : BinaryDataType,
      structures : Hash(String, DynamicStructure),
      plan : BinaryDynamicBulkPlan,
      writer : BinaryDynamicBulkJsonObjectWriter,
      child_streams : Hash(BinaryDynamicJsonLeafKey, ObjectDocumentStreams),
      nested_context : ObjectSharedNestedSerializationContext,
      profile : BinaryBulkProfile,
      budget : BinaryCodecBudget,
      shared_json_policy : ObjectSharedAdvancedJsonWritePolicy? = nil,
    ) : FragmentMap
      unless budget.writing? && nested_context.writing?
        raise ArgumentError.new("inline JSON child export requires write-direction contexts")
      end
      unless nested_context.profile == profile
        raise ArgumentError.new("inline JSON child profile differs from its inherited context")
      end

      keys = plan.json_object_leaf_keys(budget)
      unless keys.size == child_streams.size && keys.size > 0
        raise UnsupportedFormatError.new("inline JSON child stream roster differs from the prepared leaf plan")
      end

      resolver = BinaryDynamicBulkSiteNameResolver.from_escaped_prefix(
        type,
        "root",
        0_u64,
        budget.limits,
        budget,
        initial_descriptor_depth: 1,
        callback_prefix: "",
      )
      output = FragmentMap.new(initial_capacity: keys.size)
      keys.each do |key|
        streams = child_streams[key]? || raise(UnsupportedFormatError.new("inline JSON child stream is missing"))
        binding = plan.json_object_binding(key)
        _granules, grid = writer.physical_child_site(key)
        stream_rows = streams.rows_per_mark
        unless stream_rows.size == grid.mark_count
          raise UnsupportedFormatError.new("inline JSON child stream grid differs from the writer occurrence grid")
        end
        grid.mark_count.times do |mark|
          unless stream_rows[mark] == grid.logical_occurrences_at(mark)
            raise UnsupportedFormatError.new("inline JSON child stream grid differs from the writer occurrence grid")
          end
        end

        coordinates = resolver.json_object_leaf_site(key, structures)
        depth = plan.json_object_leaf_depth(key)
        child_root_depth = checked_depth_add(depth, 1, budget)
        child_inferred_offset = binding.plan.structures.object.dynamic_path_count == 0 ? 1_i32 : 2_i32
        child_inferred_depth = checked_depth_add(depth, child_inferred_offset, budget)
        physical_plan = ObjectDocumentPhysicalPlan.from_escaped_prefix(
          coordinates.escaped_prefix,
          binding.plan,
          profile,
          BinaryBulkProfile.single_stream,
          budget.limits,
          coordinates.array_level,
          typed_descriptor_root_depth: child_root_depth,
          inferred_actual_root_depth: child_inferred_depth,
          root_dynamic_json_budget: budget,
        )
        fragments = ObjectDocumentColumnWriter.inline_raw_layout_at_child_site(
          physical_plan,
          binding.plan,
          streams,
          grid,
          budget,
          nested_context,
          shared_json_policy,
          coordinates.callback_prefix,
        )
        if output.has_key?(key)
          raise UnsupportedFormatError.new("inline JSON child leaf was exported more than once")
        end
        output[key] = fragments
      end
      output
    end

    def self.capture_body!(
      prefix : ObjectDocumentInlinePrefix,
      tape : ObjectSharedPathTapeReader,
      profile : BinaryBulkProfile,
      budget : BinaryCodecBudget,
    ) : Nil
      physical_plan = physical_plan_for_prefix(prefix, budget)
      prefix.capture_json_leaf_body!(tape, physical_plan, profile, budget)
    end

    def self.decode_child(
      key : BinaryDynamicJsonLeafKey,
      binding : DynamicJsonObjectBinding,
      grid : StorageOccurrenceGrid,
      prefixes : PrefixMap,
      profile : BinaryBulkProfile,
      budget : BinaryCodecBudget,
    ) : Array(Array(ObjectDocument))
      prefix = prefixes[key]? || raise(CorruptPartError.new("inline JSON child prefix is missing for a bound Dynamic leaf"))
      unless prefix.key == key && prefix.plan.structures.object.shared_data_version == binding.plan.structures.object.shared_data_version
        raise CorruptPartError.new("inline JSON child prefix differs from its bound plan")
      end
      physical_plan = physical_plan_for_prefix(prefix, budget)
      streams = ObjectDocumentInlineBodyMaterializer.materialize(prefix, physical_plan, grid, budget)
      schema = prefix.typed_schema_for(budget)
      context = prefix.nested_context
      unless profile == context.profile
        raise CorruptPartError.new("inline JSON child read profile differs from its inherited context")
      end
      ObjectDocumentCodec.decode_child_site_with_inline_metadata_and_budget(
        schema,
        streams,
        grid,
        budget,
        prefix,
        context,
        profile,
      )
    end

    def self.physical_plan_for_prefix(
      prefix : ObjectDocumentInlinePrefix,
      budget : BinaryCodecBudget,
    ) : ObjectDocumentPhysicalPlan
      context = prefix.nested_context
      ObjectDocumentPhysicalPlan.from_escaped_prefix(
        prefix.physical_prefix,
        prefix.plan,
        context.profile,
        BinaryBulkProfile.single_stream,
        budget.limits,
        prefix.array_level,
        typed_descriptor_root_depth: prefix.typed_descriptor_root_depth,
        inferred_actual_root_depth: prefix.inferred_actual_root_depth,
        root_dynamic_json_budget: budget,
      )
    end

    private def self.checked_depth_add(depth : Int32, offset : Int32, budget : BinaryCodecBudget) : Int32
      value = depth.to_i64 + offset.to_i64
      budget.ensure_depth(value)
      value.to_i32
    end
  end
end
