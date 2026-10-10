module CrystalClick
  # Parsed, statistics-free prefix state for one inline Object child. The
  # callback bytes remain borrowed from the parent Data tape; the tape owner
  # keeps that input alive through the later body materialization phase.
  class ObjectDocumentInlinePrefix
    getter key : BinaryDynamicJsonLeafKey
    getter descriptor : BinaryDataType
    getter json_descriptor_depth : Int32
    getter typed_descriptor_root_depth : Int32
    getter inferred_actual_root_depth : Int32
    getter physical_prefix : String
    getter callback_prefix : String
    getter array_level : UInt64
    getter nested_context : ObjectSharedNestedSerializationContext
    getter object_structure_statistics_offset : Int32
    getter plan : ObjectDocumentPlan
    getter structures : ObjectDynamicStructureSet

    @prefix_callbacks : Array(Tuple(String, Bytes))
    @typed_dynamic_sites : Hash(String, Hash(String, DynamicStructure))
    @root_dynamic_sites : Hash(String, Hash(String, DynamicStructure))
    @typed_dynamic_plans : Hash(String, BinaryDynamicBulkPlan)
    @root_dynamic_plans : Hash(String, BinaryDynamicBulkPlan)
    @root_dynamic_json_prefixes : Hash(String, ObjectSharedPathJsonTapeCodec::PrefixMap)
    @physical_plan : ObjectDocumentPhysicalPlan?
    @event_schedule_context : ObjectDocumentInlineCallbackOrder::EventScheduleContext?
    @body_callbacks : Array(Tuple(String, Bytes))?
    @body_callback_slices : Array(ObjectSharedInlineCallbackReadSlice)?
    @body_capture_started : Bool
    @body_capture_finished : Bool

    def initialize(
      @key : BinaryDynamicJsonLeafKey,
      @descriptor : BinaryDataType,
      @json_descriptor_depth : Int32,
      @typed_descriptor_root_depth : Int32,
      @inferred_actual_root_depth : Int32,
      @physical_prefix : String,
      @callback_prefix : String,
      @array_level : UInt64,
      @nested_context : ObjectSharedNestedSerializationContext,
      @object_structure_statistics_offset : Int32,
      @plan : ObjectDocumentPlan,
      @structures : ObjectDynamicStructureSet,
      prefix_callbacks : Array(Tuple(String, Bytes)),
      typed_dynamic_sites : Hash(String, Hash(String, DynamicStructure)),
      root_dynamic_sites : Hash(String, Hash(String, DynamicStructure)),
      typed_dynamic_plans : Hash(String, BinaryDynamicBulkPlan),
      root_dynamic_plans : Hash(String, BinaryDynamicBulkPlan),
      root_dynamic_json_prefixes : Hash(String, ObjectSharedPathJsonTapeCodec::PrefixMap),
    )
      # The reader transfers ownership of this array; copying it here would
      # duplicate the retained callback roster without operation-budget work.
      @prefix_callbacks = prefix_callbacks
      @typed_dynamic_sites = typed_dynamic_sites
      @root_dynamic_sites = root_dynamic_sites
      @typed_dynamic_plans = typed_dynamic_plans
      @root_dynamic_plans = root_dynamic_plans
      @root_dynamic_json_prefixes = root_dynamic_json_prefixes
      @physical_plan = nil
      @event_schedule_context = nil
      @body_callbacks = nil
      @body_callback_slices = nil
      @body_capture_started = false
      @body_capture_finished = false
    end

    def prefix_callback_count : Int32
      @prefix_callbacks.size
    end

    def prefix_callback_at(index : Int, budget : BinaryCodecBudget) : Tuple(String, Bytes)
      callback = @prefix_callbacks[index]
      budget.preflight_children(1_u64)
      budget.charge_wire_bytes(callback[0].bytesize.to_u64)
      budget.charge_node
      {String.new(callback[0].to_slice), callback[1]}
    end

    # Consumes the source-ordered Object body callbacks after all header,
    # typed-prefix, and Dynamic-prefix metadata has produced this exact plan.
    # The byte slices remain borrowed from the parent tape; the occurrence
    # grid is intentionally not inferred here and is supplied later by census.
    def capture_json_leaf_body!(
      tape : ObjectSharedPathTapeReader,
      physical_plan : ObjectDocumentPhysicalPlan,
      profile : BinaryBulkProfile,
      budget : BinaryCodecBudget,
    ) : Nil
      if @body_capture_started
        raise CorruptPartError.new("inline Object body callbacks were captured more than once")
      end
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
      @body_capture_started = true
      callback_pairs.each do |canonical_name, callback_name|
        slice = tape.take_inline_fragment_slice(canonical_name, callback_name)
        callbacks << {canonical_name, slice.bytes}
        slices << slice
      end
      @body_callbacks = callbacks
      @body_callback_slices = slices
      @body_capture_finished = true
      nil
    end

    def capture_json_leaf_body_start! : Nil
      if @body_capture_started || @body_capture_finished
        raise CorruptPartError.new("inline Object body callbacks were captured more than once")
      end
      @body_capture_started = true
      @body_callbacks = [] of Tuple(String, Bytes)
      @body_callback_slices = [] of ObjectSharedInlineCallbackReadSlice
      nil
    end

    def body_callback_count : Int32
      unless @body_capture_finished
        raise ArgumentError.new("inline Object body callbacks are not completely captured")
      end
      @body_callbacks.try(&.size) || raise(ArgumentError.new("inline Object body callbacks have not been captured"))
    end

    # Budgeted detached callback-name snapshot; payload bytes remain borrowed
    # from the parent Data tape and are never copied by this accessor.
    def body_callback_at(index : Int, budget : BinaryCodecBudget) : Tuple(String, Bytes)
      callbacks = @body_callbacks || raise(ArgumentError.new("inline Object body callbacks have not been captured"))
      unless @body_capture_finished
        raise ArgumentError.new("inline Object body callbacks are not completely captured")
      end
      callback = callbacks[index]
      budget.preflight_children(1_u64)
      budget.charge_wire_bytes(callback[0].bytesize.to_u64)
      budget.charge_node
      {String.new(callback[0].to_slice), callback[1]}
    end

    # Exact captured callback intervals are retained separately from the
    # legacy name/bytes view. Advanced inline lane readers require these
    # authenticated intervals to translate enclosing Data coordinates.
    def body_callback_slice_count : Int32
      unless @body_capture_finished
        raise ArgumentError.new("inline Object body callbacks are not completely captured")
      end
      @body_callback_slices.try(&.size) || raise(ArgumentError.new("inline Object body callbacks have not been captured"))
    end

    def body_callback_slice_at(index : Int) : ObjectSharedInlineCallbackReadSlice
      unless @body_capture_finished
        raise ArgumentError.new("inline Object body callbacks are not completely captured")
      end
      slices = @body_callback_slices || raise(ArgumentError.new("inline Object body callbacks have not been captured"))
      slices[index]
    end

    def typed_dynamic_plan_for(path : String) : BinaryDynamicBulkPlan
      @typed_dynamic_plans[path]? || raise(KeyError.new("inline typed Dynamic plan not found: #{path.inspect}"))
    end

    def root_dynamic_plan_for(path : String) : BinaryDynamicBulkPlan
      @root_dynamic_plans[path]? || raise(KeyError.new("inline root Dynamic plan not found: #{path.inspect}"))
    end

    # Exact child Object prefix states for JSON leaves nested under one root
    # Dynamic path. The map is scoped to this Object field; local Dynamic leaf
    # keys are not globally unique across sibling Object owners.
    def root_dynamic_json_prefixes_for(path : String) : ObjectSharedPathJsonTapeCodec::PrefixMap
      @root_dynamic_json_prefixes[path]? || raise(KeyError.new("inline root Dynamic JSON prefixes not found: #{path.inspect}"))
    end

    # Retains the exact physical-plan instance selected by the parent JSON
    # site. Recursive callback schedules use plan identity to bind owner-local
    # leaf keys, so descendants must not independently reconstruct this plan.
    def bind_physical_plan!(physical_plan : ObjectDocumentPhysicalPlan) : Nil
      canonical_root = ObjectDocumentInlineCallbackOrder.canonical_root_prefix(physical_plan)
      unless canonical_root == @physical_prefix
        raise CorruptPartError.new("inline Object physical plan belongs to a different canonical prefix")
      end
      if existing = @physical_plan
        unless existing.same?(physical_plan)
          raise CorruptPartError.new("inline Object physical plan was rebound to a different owner")
        end
        return nil
      end
      @physical_plan = physical_plan
      nil
    end

    def physical_plan : ObjectDocumentPhysicalPlan
      @physical_plan || raise(ArgumentError.new("inline Object prefix has not been bound to its physical owner"))
    end

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
      tape : ObjectSharedPathTapeReader,
      budget : BinaryCodecBudget,
    ) : Nil
      unless @body_capture_started && !@body_capture_finished
        raise CorruptPartError.new("inline Object body callback arrived outside its owner capture phase")
      end
      callbacks = @body_callbacks.not_nil!
      slices = @body_callback_slices.not_nil!
      if callbacks.any? { |entry| entry[0] == canonical_name }
        raise CorruptPartError.new("inline Object body callback is duplicated in its owner scope")
      end
      budget.preflight_children(1_u64)
      budget.charge_node
      slice = tape.take_inline_fragment_slice(canonical_name, callback_name)
      callbacks << {canonical_name, slice.bytes}
      slices << slice
      nil
    end

    def capture_json_leaf_body_finish!(expected_count : Int32) : Nil
      unless @body_capture_started
        if expected_count == 0
          @body_callbacks = [] of Tuple(String, Bytes)
          @body_callback_slices = [] of ObjectSharedInlineCallbackReadSlice
          @body_capture_started = true
          @body_capture_finished = true
          return nil
        end
        raise CorruptPartError.new("inline Object body callbacks were not captured for their owner")
      end
      if @body_capture_finished
        raise CorruptPartError.new("inline Object body capture was finished more than once")
      end
      callbacks = @body_callbacks.not_nil!
      unless callbacks.size == expected_count && @body_callback_slices.try(&.size) == expected_count
        raise CorruptPartError.new("inline Object body callback count differs from its owner schedule")
      end
      @body_capture_finished = true
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

    # Budgeted typed-schema snapshot for the plan-fed Object decoder. This
    # avoids ObjectDocumentPlan#typed_paths' legacy unbudgeted detached copy.
    def typed_schema_for(budget : BinaryCodecBudget) : Hash(String, BinaryDataType)
      count = @plan.typed_path_count.to_u64
      byte_count = 0_u64
      @plan.typed_path_count.times do |index|
        byte_count = checked_add(byte_count, @plan.typed_path_byte_size_at(index).to_u64)
      end
      if count > 0_u64
        budget.preflight_children(count)
        budget.charge_wire_bytes(byte_count)
        count.times { budget.charge_node }
      end
      typed = Hash(String, BinaryDataType).new(initial_capacity: count.to_i)
      @plan.typed_path_count.times do |index|
        path = @plan.typed_path_at(index)
        typed[path] = @plan.typed_type_for(path)
      end
      typed
    end

    # Operation-budgeted detached snapshot for the plan-fed child decoder.
    def typed_dynamic_sites_for(path : String, budget : BinaryCodecBudget) : Hash(String, DynamicStructure)
      copy_sites(@typed_dynamic_sites[path]? || raise(KeyError.new("inline typed Dynamic sites not found: #{path.inspect}")), budget)
    end

    # Operation-budgeted detached snapshot for one root Object Dynamic path.
    def root_dynamic_sites_for(path : String, budget : BinaryCodecBudget) : Hash(String, DynamicStructure)
      copy_sites(@root_dynamic_sites[path]? || raise(KeyError.new("inline root Dynamic sites not found: #{path.inspect}")), budget)
    end

    private def copy_sites(
      sites : Hash(String, DynamicStructure),
      budget : BinaryCodecBudget,
    ) : Hash(String, DynamicStructure)
      count = sites.size.to_u64
      byte_count = 0_u64
      sites.each_key do |path|
        byte_count = checked_add(byte_count, path.bytesize.to_u64)
      end
      budget.preflight_children(count) if count > 0_u64
      budget.charge_wire_bytes(byte_count) if byte_count > 0_u64
      count.times { budget.charge_node }
      copied = Hash(String, DynamicStructure).new(initial_capacity: sites.size)
      sites.each do |path, structure|
        copied[path] = structure
      end
      copied
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        raise UnsupportedFormatError.new("inline Object state work size overflows UInt64")
      end
      left + right
    end
  end
end
