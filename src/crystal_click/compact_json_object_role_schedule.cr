module CrystalClick
  # Frozen callback schedule for one Compact JSON Object subtree. Root-local
  # bindings remain the normalized-stream authority; flattened events carry
  # exact descendant ownership solely for physical capture and MRK4 naming.
  class CompactJsonObjectRoleSchedule
    alias CallbackPair = ObjectDocumentInlineCallbackOrder::CallbackPair
    alias BodyBinding = ObjectDocumentInlineCallbackOrder::BodyLaneBinding
    alias CallbackOwner = ObjectDocumentInlineCallbackOrder::CallbackOwner
    alias CallbackEvent = ObjectDocumentInlineCallbackOrder::CallbackEvent
    alias EventScheduleContext = ObjectDocumentInlineCallbackOrder::EventScheduleContext

    struct OwnerSchedule
      getter root : String
      getter prefix : ObjectDocumentCallbackPrefix
      getter physical_plan : ObjectDocumentPhysicalPlan
      getter prefix_pairs : Array(CallbackPair)
      getter body_pairs : Array(CallbackPair)
      getter body_bindings : Array(BodyBinding)
      getter parent_typed_path : String?
      getter parent_key : BinaryDynamicJsonLeafKey?
      getter advanced : Bool

      def initialize(
        @root : String,
        @prefix : ObjectDocumentCallbackPrefix,
        @physical_plan : ObjectDocumentPhysicalPlan,
        @prefix_pairs : Array(CallbackPair),
        @body_pairs : Array(CallbackPair),
        @body_bindings : Array(BodyBinding),
        @parent_typed_path : String? = nil,
        @parent_key : BinaryDynamicJsonLeafKey? = nil,
        @advanced : Bool = false,
      )
      end
    end

    getter prefix_pairs : Array(CallbackPair)
    getter body_pairs : Array(CallbackPair)
    getter body_bindings : Array(BodyBinding)
    getter prefix_events : Array(CallbackEvent)
    getter body_events : Array(CallbackEvent)
    getter event_names : Array(String)
    getter advanced : Bool
    getter owner_schedules : Hash(String, OwnerSchedule)

    private def initialize(
      @prefix_pairs : Array(CallbackPair),
      @body_pairs : Array(CallbackPair),
      @body_bindings : Array(BodyBinding),
      @prefix_events : Array(CallbackEvent),
      @body_events : Array(CallbackEvent),
      @event_names : Array(String),
      @advanced : Bool,
      @owner_schedules : Hash(String, OwnerSchedule),
    )
    end

    def self.build(
      prefix : ObjectDocumentCallbackPrefix,
      physical_plan : ObjectDocumentPhysicalPlan,
      profile : BinaryBulkProfile,
      budget : BinaryCodecBudget,
    ) : CompactJsonObjectRoleSchedule
      object = prefix.plan.structures.object
      shared_version = object.shared_data_version
      bucket_count = physical_plan.shared_bucket_count
      advanced = (shared_version == 2_u64 || shared_version == 3_u64) && bucket_count == 2
      map = (shared_version == 0_u64 && bucket_count == 1) || (shared_version == 1_u64 && bucket_count == 2)
      unless advanced || map
        raise UnsupportedFormatError.new("Compact static JSON role schedule admits only root MAP/MAP_WITH_BUCKETS or ADVANCED/CHUNKED shared data with their sealed bucket counts")
      end
      unless physical_plan.shared_profile == BinaryBulkProfile.single_stream
        raise UnsupportedFormatError.new("Compact static JSON role schedule requires the source single-stream profile")
      end

      root_owner : CallbackOwner = {
        ObjectDocumentInlineCallbackOrder.canonical_root_prefix(physical_plan),
        prefix.callback_prefix,
        physical_plan,
        prefix.plan,
      }
      typed_bindings = prefix.plan.typed_dynamic_json_object_leaf_plans(budget)
      # Always ask the bounded owner resolver, even when this Object has no
      # typed-Dynamic JSON leaves: it also validates that root-Dynamic JSON is
      # not bypassing the Compact admission gate through the empty fast path.
      descendants = CompactJsonCallbackOwners.for_owner(
        physical_plan,
        prefix.plan,
        prefix.callback_prefix,
        budget,
      )
      owner_contexts = Hash(String, Tuple(ObjectDocumentCallbackPrefix, ObjectDocumentPhysicalPlan, String?, BinaryDynamicJsonLeafKey?)).new(
        initial_capacity: descendants.size.to_i + 1,
      )
      owner_contexts[root_owner[0]] = {prefix, physical_plan, nil, nil}

      # Resolve the callback owner's admitted typed-Dynamic JSON leaves through
      # their exact key and physical site. No synthetic key or longest-prefix
      # matching is involved.
      typed_bindings.each do |path, bindings|
        nested_prefixes = prefix.typed_dynamic_json_prefixes_for(path)
        dynamic_physical = physical_plan.typed_dynamic(path)
        bindings.each do |entry|
          key = entry[0]
          unless CompactJsonCallbackOwners.admitted_typed_dynamic_json_leaf_key?(
                   prefix.plan.typed_dynamic_for(path), key
                 )
            raise UnsupportedFormatError.new("Compact JSON reader admits only direct JSON or one Array(JSON) typed-Dynamic actual")
          end
          site = dynamic_physical.json_object_site(key)
          child_prefix = nested_prefixes[key]? ||
                         raise(CorruptPartError.new("Compact typed-Dynamic JSON child prefix is missing for its exact leaf key"))
          child_root = ObjectDocumentInlineCallbackOrder.canonical_root_prefix(site.physical_plan)
          unless site.binding.plan.same?(entry[1]) && child_prefix.plan.same?(entry[1]) &&
                 child_prefix.key == key && child_prefix.physical_prefix == child_root &&
                 site.escaped_prefix == child_root
            raise CorruptPartError.new("Compact typed-Dynamic JSON child prefix differs from its exact physical binding")
          end
          if owner_contexts.has_key?(child_root)
            raise CorruptPartError.new("Compact typed-Dynamic JSON callback owner is duplicated")
          end
          owner_contexts[child_root] = {child_prefix, site.physical_plan, path, key}
        end
      end
      unless owner_contexts.size == descendants.size + 1
        raise CorruptPartError.new("Compact typed-Dynamic JSON prefix map differs from its validated callback owners")
      end
      descendants.each do |owner|
        context = owner_contexts[owner[0]]? ||
                  raise(CorruptPartError.new("Compact typed-Dynamic JSON callback owner has no exact parsed child prefix"))
        unless context[1].same?(owner[2]) && context[0].plan.same?(owner[3]) && context[0].callback_prefix == owner[1]
          raise CorruptPartError.new("Compact typed-Dynamic JSON owner registry differs from its parsed child prefix")
        end
      end

      registry = ObjectDocumentInlineCallbackEvents.new(root_owner, descendants, budget)
      owner_contexts.each_key do |owner_root|
        next if owner_root == root_owner[0]
        owner_prefix = owner_contexts[owner_root][0].as?(ObjectDocumentInlinePrefix) ||
                       raise(CorruptPartError.new("Compact typed-Dynamic callback owner lost its keyed inline prefix"))
        owner_prefix.bind_physical_plan!(owner_contexts[owner_root][1])
        owner_prefix.bind_event_schedule_context!(registry, owner_root, budget)
      end
      owner_schedules = Hash(String, OwnerSchedule).new(initial_capacity: owner_contexts.size)
      owner_contexts.each do |owner_root, context|
        owner_prefix = context[0]
        owner_physical = context[1]
        event_context : EventScheduleContext = {registry, owner_root}
        owner_advanced = owner_prefix.plan.structures.object.shared_data_version >= 2_u64
        local_prefix_pairs = ObjectDocumentInlineCallbackOrder.prefix_callback_pairs(
          owner_physical,
          owner_prefix.plan,
          owner_prefix.callback_prefix,
          budget,
          owner_advanced,
          event_context,
          true,
        )
        unless local_prefix_pairs.size == owner_prefix.prefix_callback_count
          raise CorruptPartError.new("Compact Object prefix roster differs from its parsed local plan")
        end
        local_prefix_pairs.each_with_index do |pair, index|
          observed, _bytes = owner_prefix.prefix_callback_at(index, budget)
          unless pair[0] == observed
            raise CorruptPartError.new("Compact Object prefix callback order differs from its parsed local plan")
          end
        end

        local_body_pairs = ObjectDocumentInlineCallbackOrder.body_callback_pairs(
          owner_physical,
          owner_prefix.plan,
          profile,
          owner_prefix.callback_prefix,
          budget,
          owner_advanced,
          true,
          event_context,
          true,
        )
        local_bindings = if owner_advanced
                           ObjectDocumentInlineCallbackOrder.advanced_body_lane_bindings(
                             owner_physical,
                             owner_prefix.plan,
                             profile,
                             budget,
                             event_context,
                             true,
                           )
                         else
                           ObjectDocumentInlineCallbackOrder.body_lane_bindings(
                             owner_physical,
                             owner_prefix.plan,
                             profile,
                             budget,
                             event_context,
                             true,
                           )
                         end
        unless local_body_pairs.size == local_bindings.size
          raise CorruptPartError.new("Compact Object body roles differ from their exact local callback identities")
        end
        local_body_pairs.each_with_index do |pair, index|
          unless pair[0] == local_bindings[index][0]
            raise CorruptPartError.new("Compact Object body callback is not bound to its parsed local role")
          end
        end
        owner_schedules[owner_root] = OwnerSchedule.new(
          owner_root,
          owner_prefix,
          owner_physical,
          local_prefix_pairs,
          local_body_pairs,
          local_bindings,
          context[2],
          context[3],
          owner_advanced,
        )
      end

      prefix_events = ObjectDocumentInlineCallbackOrder.prefix_callback_events(
        physical_plan,
        prefix.plan,
        prefix.callback_prefix,
        budget,
        allow_advanced: advanced,
        descendants: descendants,
      )
      body_events = ObjectDocumentInlineCallbackOrder.body_callback_events(
        physical_plan,
        prefix.plan,
        profile,
        prefix.callback_prefix,
        budget,
        allow_advanced: advanced,
        include_advanced_shared: true,
        descendants: descendants,
      )

      names = [] of String
      seen = Set(String).new
      event_count = prefix_events.size.to_u64 + body_events.size.to_u64
      budget.ensure_future_nodes(event_count)
      budget.ensure_future_elements(event_count)
      event_count.times { budget.charge_node }
      budget.charge_elements(event_count) if event_count > 0_u64
      prefix_events.each do |event|
        unless owner_schedules.has_key?(event[0])
          raise CorruptPartError.new("Compact flattened callback event names an unbound Object owner")
        end
        unless seen.add?(event[1])
          raise CorruptPartError.new("Compact flattened callback schedule duplicates a physical name")
        end
        names << event[2]
      end
      body_events.each do |event|
        unless owner_schedules.has_key?(event[0])
          raise CorruptPartError.new("Compact flattened callback event names an unbound Object owner")
        end
        unless seen.add?(event[1])
          raise CorruptPartError.new("Compact flattened callback schedule duplicates a physical name")
        end
        names << event[2]
      end
      root_schedule = owner_schedules[root_owner[0]]
      new(
        root_schedule.prefix_pairs,
        root_schedule.body_pairs,
        root_schedule.body_bindings,
        prefix_events,
        body_events,
        names,
        advanced,
        owner_schedules,
      )
    end

    def owner_for_root(root : String) : OwnerSchedule
      @owner_schedules[root]? || raise(CorruptPartError.new("Compact callback event names an unknown Object owner"))
    end

    # Return the root-local schedule only when this exact prepared schedule
    # belongs to the supplied physical and parsed root owners. Callers that
    # retain the schedule across capture and publication must not rebuild it:
    # descendant InlinePrefix owners are bound to its one-shot registry.
    def validate_root_owner!(
      prefix : ObjectDocumentCallbackPrefix,
      physical_plan : ObjectDocumentPhysicalPlan,
      budget : BinaryCodecBudget,
    ) : OwnerSchedule
      root = ObjectDocumentInlineCallbackOrder.canonical_root_prefix(physical_plan)
      owner = owner_for_root(root)
      unless owner.root == root && owner.prefix.same?(prefix) && owner.physical_plan.same?(physical_plan)
        raise CorruptPartError.new("Compact callback schedule belongs to a different parsed root owner")
      end
      expected_owner_count = 1_u64
      prefix.plan.typed_dynamic_json_object_leaf_plans(budget).each do |path, bindings|
        nested_prefixes = prefix.typed_dynamic_json_prefixes_for(path)
        dynamic_physical = physical_plan.typed_dynamic(path)
        bindings.each do |entry|
          key = entry[0]
          unless CompactJsonCallbackOwners.admitted_typed_dynamic_json_leaf_key?(
                   prefix.plan.typed_dynamic_for(path), key
                 )
            raise UnsupportedFormatError.new("Compact JSON reader admits only direct JSON or one Array(JSON) typed-Dynamic actual")
          end
          site = dynamic_physical.json_object_site(key)
          child_root = ObjectDocumentInlineCallbackOrder.canonical_root_prefix(site.physical_plan)
          child_prefix = nested_prefixes[key]? ||
                         raise(CorruptPartError.new("Compact typed-Dynamic JSON child prefix is missing for its exact leaf key"))
          child_owner = owner_for_root(child_root)
          unless child_owner.root == child_root && child_owner.prefix.same?(child_prefix) &&
                 child_owner.physical_plan.same?(site.physical_plan) &&
                 child_owner.parent_typed_path == path && child_owner.parent_key == key &&
                 child_owner.prefix.physical_prefix == child_root &&
                 child_owner.prefix.plan.same?(entry[1]) && site.binding.plan.same?(entry[1]) &&
                 site.escaped_prefix == child_root
            raise CorruptPartError.new("Compact typed-Dynamic JSON callback owner differs from its exact parsed binding")
          end
          if expected_owner_count == UInt64::MAX
            raise CorruptPartError.new("Compact callback owner census exceeds UInt64")
          end
          expected_owner_count += 1_u64
        end
      end
      unless @owner_schedules.size.to_u64 == expected_owner_count
        raise CorruptPartError.new("Compact callback owner registry differs from its exact typed-Dynamic JSON bindings")
      end
      owner
    end

    def each_owner(&block : OwnerSchedule -> Nil) : Nil
      @owner_schedules.each_value { |owner| yield owner }
    end

    # Capture each owner independently while consuming one flattened physical
    # schedule. Root bytes stay under the root keyless prefix; descendant
    # callbacks stay under their exact keyed child prefixes.
    def begin_body_capture!(budget : BinaryCodecBudget) : Nil
      owner_count = @owner_schedules.size.to_u64
      budget.preflight_children(owner_count)
      owner_count.times { budget.charge_node }
      each_owner { |owner| owner.prefix.start_body_capture! }
      nil
    end

    def capture_physical_body_events!(source : T, budget : BinaryCodecBudget) : Nil forall T
      @body_events.each do |event|
        owner = owner_for_root(event[0])
        owner.prefix.capture_body_callback_from!(event[1], event[2], budget) do
          source.take_physical_inline_fragment_slice(event[1], event[2])
        end
      end
      nil
    end

    def finish_body_capture!(budget : BinaryCodecBudget) : Nil
      count = @owner_schedules.size.to_u64
      budget.preflight_children(count)
      budget.ensure_future_elements(count)
      budget.charge_elements(count) if count > 0_u64
      count.times { budget.charge_node }
      expected = Hash(String, Int32).new(initial_capacity: @owner_schedules.size)
      @owner_schedules.each_key { |root| expected[root] = 0 }
      @body_events.each do |event|
        count = expected[event[0]]? || raise(CorruptPartError.new("Compact body event has no exact callback owner"))
        if count == Int32::MAX
          raise UnsupportedFormatError.new("Compact callback owner roster exceeds the supported count")
        end
        expected[event[0]] = count + 1
      end
      each_owner do |owner|
        owner.prefix.finish_body_capture!(expected[owner.root])
      end
      nil
    end

    # Physical MRK4 metadata uses canonical physical names; callback readers
    # consume the raw names in `event_names`. Owner-local root pairs remain
    # reserved for normalized parent materialization.
    def physical_event_names(budget : BinaryCodecBudget) : Array(String)
      count = @prefix_events.size.to_u64 + @body_events.size.to_u64
      if count > Int32::MAX.to_u64
        raise UnsupportedFormatError.new("Compact static JSON physical callback roster exceeds its supported size")
      end
      budget.ensure_future_nodes(1_u64)
      budget.ensure_future_elements(count)
      budget.charge_node
      budget.charge_elements(count) if count > 0_u64

      names = Array(String).new(count.to_i)
      @prefix_events.each { |event| names << event[1] }
      @body_events.each { |event| names << event[1] }
      names
    end
  end
end
