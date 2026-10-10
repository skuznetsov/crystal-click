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
      unless physical_plan.shared_profile == BinaryBulkProfile.single_stream
        raise UnsupportedFormatError.new("inline Object shared MAP callbacks require the source single-stream profile")
      end
      unless prefix.nested_context.profile == profile
        raise CorruptPartError.new("inline JSON child read profile differs from its inherited context")
      end

      root_owner = ObjectDocumentInlineCallbackOrder.canonical_root_prefix(physical_plan)
      unless root_owner == prefix.physical_prefix
        raise CorruptPartError.new("inline JSON child physical owner differs from its canonical prefix")
      end
      owner_prefixes = Hash(String, ObjectDocumentInlinePrefix).new
      descendants = [] of ObjectDocumentInlineCallbackOrder::CallbackOwner
      owner_prefixes[root_owner] = prefix
      collect_callback_owners!(prefix, physical_plan, owner_prefixes, descendants, budget)

      root_callback_owner : ObjectDocumentInlineCallbackOrder::CallbackOwner = {
        root_owner,
        prefix.callback_prefix,
        physical_plan,
        prefix.plan,
      }
      owner_schedule = ObjectDocumentInlineCallbackEvents.new(root_callback_owner, descendants, budget)
      owner_prefixes.each do |owner_root, owner_prefix|
        owner_prefix.bind_event_schedule_context!(owner_schedule, owner_root, budget)
      end

      allow_advanced = prefix.nested_context.shared_data_version >= 2_u64
      validate_prefix_event_schedule!(
        physical_plan,
        prefix,
        descendants,
        owner_prefixes,
        allow_advanced,
        budget,
      )
      body_events = ObjectDocumentInlineCallbackOrder.body_callback_events(
        physical_plan,
        prefix.plan,
        profile,
        prefix.callback_prefix,
        budget,
        allow_advanced: allow_advanced,
        include_advanced_shared: true,
        descendants: descendants,
      )

      expected_counts = Hash(String, Int32).new(initial_capacity: owner_prefixes.size)
      owner_prefixes.each_key { |owner_root| expected_counts[owner_root] = 0 }
      body_events.each do |event|
        owner_root = event[0]
        unless owner_prefixes.has_key?(owner_root)
          raise CorruptPartError.new("inline callback schedule names an unbound Object owner")
        end
        count = expected_counts[owner_root]
        if count == Int32::MAX
          raise UnsupportedFormatError.new("inline callback owner roster exceeds the supported count")
        end
        expected_counts[owner_root] = count + 1
      end

      owner_prefixes.each_value { |owner_prefix| owner_prefix.capture_json_leaf_body_start! }
      body_events.each do |event|
        owner_prefix = owner_prefixes[event[0]]?
        unless owner_prefix
          raise CorruptPartError.new("inline callback schedule lost its Object owner during capture")
        end
        owner_prefix.capture_json_leaf_body_event!(event[1], event[2], tape, budget)
      end
      owner_prefixes.each do |owner_root, owner_prefix|
        owner_prefix.capture_json_leaf_body_finish!(expected_counts[owner_root])
      end
      nil
    end

    def self.decode_child(
      key : BinaryDynamicJsonLeafKey,
      binding : DynamicJsonObjectBinding,
      grid : StorageOccurrenceGrid,
      prefixes : PrefixMap,
      profile : BinaryBulkProfile,
      budget : BinaryCodecBudget,
      json_descriptor_depth : Int32? = nil,
    ) : Array(Array(ObjectDocument))
      prefix = prefixes[key]? || raise(CorruptPartError.new("inline JSON child prefix is missing for a bound Dynamic leaf"))
      unless binding.leaf_key == key
        raise CorruptPartError.new("inline JSON child binding belongs to a different descriptor-relative leaf")
      end
      descriptor_context = BinaryCodecContext.new(budget.limits, nil, false, budget, false, false)
      descriptor_context.validate_type_tree(prefix.descriptor, prefix.json_descriptor_depth)
      descriptor_context.validate_type_tree(binding.json_type, prefix.json_descriptor_depth)
      unless prefix.descriptor == binding.json_type
        raise CorruptPartError.new("inline JSON child prefix descriptor differs from its prepared actual binding")
      end
      if expected_depth = json_descriptor_depth
        unless expected_depth == prefix.json_descriptor_depth
          raise CorruptPartError.new("inline JSON child prefix depth differs from its prepared descriptor path")
        end
      end
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
      begin
        return prefix.physical_plan
      rescue ex : ArgumentError
        # The first body capture for this owner has no retained physical plan.
        # Construct it once, bind it, and share this exact instance recursively.
      end
      context = prefix.nested_context
      physical_plan = ObjectDocumentPhysicalPlan.from_escaped_prefix(
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
      prefix.bind_physical_plan!(physical_plan)
      physical_plan
    end

    private def self.collect_callback_owners!(
      owner_prefix : ObjectDocumentInlinePrefix,
      owner_physical_plan : ObjectDocumentPhysicalPlan,
      owner_prefixes : Hash(String, ObjectDocumentInlinePrefix),
      descendants : Array(ObjectDocumentInlineCallbackOrder::CallbackOwner),
      budget : BinaryCodecBudget,
    ) : Nil
      owner_prefix.each_root_dynamic_json_prefix_entry(budget) do |path, key, child_prefix|
        unless child_prefix.key == key && child_prefix.nested_context.shared_data_version == owner_prefix.nested_context.shared_data_version && child_prefix.nested_context.profile == owner_prefix.nested_context.profile
          raise CorruptPartError.new("inline JSON descendant context or leaf key differs from its owning Object")
        end
        site = owner_physical_plan.root_dynamic_json(path).json_object_site(key)
        binding = site.binding
        unless site.leaf_key == key && binding.leaf_key == key && binding.json_type == child_prefix.descriptor
          raise CorruptPartError.new("inline JSON descendant differs from its descriptor-relative physical site")
        end
        unless binding.plan.same?(child_prefix.plan)
          raise CorruptPartError.new("inline JSON descendant plan differs from its prepared physical binding")
        end
        unless site.array_level == child_prefix.array_level && site.json_depth == child_prefix.json_descriptor_depth
          raise CorruptPartError.new("inline JSON descendant depth differs from its physical site")
        end
        canonical_root = ObjectDocumentInlineCallbackOrder.canonical_root_prefix(site.physical_plan)
        unless canonical_root == site.escaped_prefix && canonical_root == child_prefix.physical_prefix
          raise CorruptPartError.new("inline JSON descendant physical prefix differs from its parent site")
        end
        budget.ensure_depth(child_prefix.json_descriptor_depth)
        child_prefix.bind_physical_plan!(site.physical_plan)
        if owner_prefixes.has_key?(canonical_root)
          raise CorruptPartError.new("inline JSON descendant callback owner is duplicated")
        end

        callback_owner = {
          canonical_root,
          child_prefix.callback_prefix,
          site.physical_plan,
          binding.plan,
        }
        descendants << callback_owner
        owner_prefixes[canonical_root] = child_prefix
        collect_callback_owners!(child_prefix, site.physical_plan, owner_prefixes, descendants, budget)
      end
      nil
    end

    private def self.validate_prefix_event_schedule!(
      physical_plan : ObjectDocumentPhysicalPlan,
      root_prefix : ObjectDocumentInlinePrefix,
      descendants : Array(ObjectDocumentInlineCallbackOrder::CallbackOwner),
      owner_prefixes : Hash(String, ObjectDocumentInlinePrefix),
      allow_advanced : Bool,
      budget : BinaryCodecBudget,
    ) : Nil
      events = ObjectDocumentInlineCallbackOrder.prefix_callback_events(
        physical_plan,
        root_prefix.plan,
        root_prefix.callback_prefix,
        budget,
        allow_advanced: allow_advanced,
        descendants: descendants,
      )
      indices = Hash(String, Int32).new(initial_capacity: owner_prefixes.size)
      owner_prefixes.each_key { |owner_root| indices[owner_root] = 0 }
      events.each do |event|
        owner_root = event[0]
        owner_prefix = owner_prefixes[owner_root]?
        unless owner_prefix
          raise CorruptPartError.new("inline prefix schedule names an unbound Object owner")
        end
        index = indices[owner_root]
        if index >= owner_prefix.prefix_callback_count
          raise CorruptPartError.new("inline prefix callback schedule exceeds its parsed owner prefix")
        end
        actual_name, _bytes = owner_prefix.prefix_callback_at(index, budget)
        unless actual_name == event[1]
          raise CorruptPartError.new("inline prefix callback schedule differs from parsed owner metadata")
        end
        indices[owner_root] = index + 1
      end
      owner_prefixes.each do |owner_root, owner_prefix|
        unless indices[owner_root] == owner_prefix.prefix_callback_count
          raise CorruptPartError.new("inline parsed prefix has callbacks outside its recursive owner schedule")
        end
      end
      nil
    end

    private def self.checked_depth_add(depth : Int32, offset : Int32, budget : BinaryCodecBudget) : Int32
      value = depth.to_i64 + offset.to_i64
      budget.ensure_depth(value)
      value.to_i32
    end
  end
end
