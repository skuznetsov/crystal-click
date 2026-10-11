module CrystalClick
  # Parsed, statistics-free prefix state for one inline Object child. The
  # callback bytes remain borrowed from the parent Data tape; the tape owner
  # keeps that input alive through the later body materialization phase.
  class ObjectDocumentInlinePrefix < ObjectDocumentCallbackPrefix
    getter key : BinaryDynamicJsonLeafKey
    @event_schedule_context : ObjectDocumentInlineCallbackOrder::EventScheduleContext?

    def initialize(
      key : BinaryDynamicJsonLeafKey,
      descriptor : BinaryDataType,
      json_descriptor_depth : Int32,
      typed_descriptor_root_depth : Int32,
      inferred_actual_root_depth : Int32,
      physical_prefix : String,
      callback_prefix : String,
      array_level : UInt64,
      nested_context : ObjectSharedNestedSerializationContext,
      object_structure_statistics_offset : Int32,
      plan : ObjectDocumentPlan,
      structures : ObjectDynamicStructureSet,
      prefix_callbacks : Array(Tuple(String, Bytes)),
      typed_dynamic_sites : Hash(String, Hash(String, DynamicStructure)),
      root_dynamic_sites : Hash(String, Hash(String, DynamicStructure)),
      typed_dynamic_plans : Hash(String, BinaryDynamicBulkPlan),
      root_dynamic_plans : Hash(String, BinaryDynamicBulkPlan),
      root_dynamic_json_prefixes : Hash(String, ObjectSharedPathJsonTapeCodec::PrefixMap),
      statistics_context : ObjectDocumentCallbackPrefix::StatisticsContext = ObjectDocumentCallbackPrefix::StatisticsContext::PrefixOnly,
    )
      super(
        descriptor,
        json_descriptor_depth,
        typed_descriptor_root_depth,
        inferred_actual_root_depth,
        physical_prefix,
        callback_prefix,
        array_level,
        nested_context,
        object_structure_statistics_offset,
        statistics_context,
        plan,
        structures,
        prefix_callbacks,
        typed_dynamic_sites,
        root_dynamic_sites,
        typed_dynamic_plans,
        root_dynamic_plans,
        root_dynamic_json_prefixes,
      )
      @key = key
      @event_schedule_context = nil
    end

    # Consumes the source-ordered Object body callbacks after all header,
    # typed-prefix, and Dynamic-prefix metadata has produced this exact plan.
    # The byte slices remain borrowed from the parent tape; the occurrence
    # grid is intentionally not inferred here and is supplied later by census.
    def capture_json_leaf_body!(
      tape : T,
      physical_plan : ObjectDocumentPhysicalPlan,
      profile : BinaryBulkProfile,
      budget : BinaryCodecBudget,
    ) : Nil forall T
      preflight_body_capture!
      validate_physical_owner!(physical_plan)
      if budget.writing? || @nested_context.writing?
        raise ArgumentError.new("inline Object body capture requires read-direction contexts")
      end
      unless profile == @nested_context.profile
        raise CorruptPartError.new("inline Object body profile differs from its inherited context")
      end
      unless physical_plan.shared_profile == BinaryBulkProfile.single_stream
        raise UnsupportedFormatError.new("inline Object shared MAP callbacks require the source single-stream profile")
      end

      callback_pairs = ObjectDocumentInlineCallbackOrder.body_callback_pairs(
        physical_plan,
        @plan,
        profile,
        @callback_prefix,
        budget,
        @nested_context.shared_data_version >= 2_u64,
      )
      count = callback_pairs.size.to_u64
      if count > 0_u64
        budget.preflight_children(count)
        count.times { budget.charge_node }
      end
      callbacks = Array(Tuple(String, Bytes)).new(callback_pairs.size)
      slices = Array(ObjectSharedInlineCallbackReadSlice).new(callback_pairs.size)
      callback_pairs.each do |canonical_name, callback_name|
        slice = tape.take_inline_fragment_slice(canonical_name, callback_name)
        callbacks << {canonical_name, slice.bytes}
        slices << slice
      end
      bindings = if @nested_context.shared_data_version >= 2_u64
                   ObjectDocumentInlineCallbackOrder.advanced_body_lane_bindings(
                     physical_plan,
                     @plan,
                     profile,
                     budget,
                     @event_schedule_context,
                     true,
                   )
                 else
                   ObjectDocumentInlineCallbackOrder.body_lane_bindings(
                     physical_plan,
                     @plan,
                     profile,
                     budget,
                     @event_schedule_context,
                     true,
                   )
                 end
      bind_body_schedule!(bindings, callback_pairs)
      bind_body_callbacks!(callbacks, slices)
      nil
    end

    def capture_json_leaf_body_start! : Nil
      start_body_capture!
    end

    # Callback roster and authenticated slices are inherited from the common
    # keyless owner.

    # Budgeted detached callback-name snapshot; payload bytes remain borrowed
    # from the parent Data tape and are never copied by this accessor.
    # `body_callback_at` is inherited.

    # Exact captured callback intervals are retained separately from the
    # legacy name/bytes view. Advanced inline lane readers require these
    # authenticated intervals to translate enclosing Data coordinates.
    # Slice accessors are inherited.

    # Exact child Object prefix states for JSON leaves nested under one root
    # Dynamic path. The map is scoped to this Object field; local Dynamic leaf
    # keys are not globally unique across sibling Object owners.
    # Child Dynamic JSON prefix lookup is inherited.

    # Retains the validated recursive owner registry used by the one-shot tape
    # capture. Later materializers must request owner-local schedules from
    # this same registry; reconstructing a schedule from a plan alone would
    # lose the exact descendant binding/callback ownership proof.
    def bind_event_schedule_context!(
      schedule : ObjectDocumentInlineCallbackEvents,
      owner_root : String,
      budget : BinaryCodecBudget,
    ) : Nil
      unless owner_root == @physical_prefix
        raise CorruptPartError.new("inline callback schedule belongs to a different canonical Object owner")
      end
      owner = schedule.owner_for_root(owner_root, budget)
      unless owner[0] == @physical_prefix &&
             owner[1] == @callback_prefix &&
             owner[2].same?(physical_plan) &&
             owner[3].same?(@plan)
        raise CorruptPartError.new("inline callback schedule owner differs from the retained Object prefix")
      end
      if existing = @event_schedule_context
        unless existing[0].same?(schedule) && existing[1] == owner_root
          raise CorruptPartError.new("inline callback schedule owner was rebound to a different registry")
        end
        return nil
      end
      @event_schedule_context = {schedule, owner_root}
      nil
    end

    def event_schedule_context : ObjectDocumentInlineCallbackOrder::EventScheduleContext
      @event_schedule_context || raise(UnsupportedFormatError.new("inline Object has no validated recursive callback owner registry"))
    end

    # Iterates direct child Objects without flattening their local leaf keys.
    # The Dynamic path and leaf key are both required to locate the exact
    # parent physical site when building the recursive owner registry.
    def each_root_dynamic_json_prefix_entry(
      budget : BinaryCodecBudget,
      &block : String, BinaryDynamicJsonLeafKey, ObjectDocumentInlinePrefix -> Nil
    ) : Nil
      count = 0_u64
      @root_dynamic_json_prefixes.each_value do |prefixes|
        count = checked_add(count, prefixes.size.to_u64)
      end
      budget.preflight_children(count) if count > 0_u64
      count.times { budget.charge_node }
      @root_dynamic_json_prefixes.each do |path, prefixes|
        prefixes.each do |key, prefix|
          yield path, key, prefix
        end
      end
      nil
    end

    # Capture one recursively scheduled body callback for this exact Object
    # owner. The parent tape has already authenticated the callback interval;
    # siblings are routed to their own prefix states.
    def capture_json_leaf_body_event!(
      canonical_name : String,
      callback_name : String,
      tape : T,
      budget : BinaryCodecBudget,
    ) : Nil forall T
      preflight_and_charge_body_callback!(canonical_name, budget)
      slice = tape.take_inline_fragment_slice(canonical_name, callback_name)
      append_precharged_body_callback!(canonical_name, slice)
      nil
    end

    def capture_json_leaf_body_finish!(expected_count : Int32) : Nil
      finish_body_capture!(expected_count)
      nil
    end

    def nested_json_prefixes(budget : BinaryCodecBudget) : Array(ObjectDocumentInlinePrefix)
      count = 0_u64
      @root_dynamic_json_prefixes.each_value do |prefixes|
        count = checked_add(count, prefixes.size.to_u64)
      end
      budget.preflight_children(count) if count > 0_u64
      budget.ensure_future_elements(count)
      count.times { budget.charge_node }
      budget.charge_elements(count) if count > 0_u64
      nested = Array(ObjectDocumentInlinePrefix).new(count.to_i)
      @root_dynamic_json_prefixes.each_value do |prefixes|
        prefixes.each_value { |prefix| nested << prefix }
      end
      nested
    end

    # Visits direct nested JSON Object owners without constructing an
    # intermediate array. The callback can recursively walk the child while
    # preserving its field-local leaf-key map.
    def each_nested_json_prefix(budget : BinaryCodecBudget, &block : ObjectDocumentInlinePrefix ->) : Nil
      count = 0_u64
      @root_dynamic_json_prefixes.each_value do |prefixes|
        count = checked_add(count, prefixes.size.to_u64)
      end
      budget.preflight_children(count) if count > 0_u64
      count.times { budget.charge_node }
      @root_dynamic_json_prefixes.each_value do |prefixes|
        prefixes.each_value { |prefix| yield prefix }
      end
      nil
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        raise UnsupportedFormatError.new("inline Object state work size overflows UInt64")
      end
      left + right
    end
  end
end
