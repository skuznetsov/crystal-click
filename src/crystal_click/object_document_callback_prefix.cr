module CrystalClick
  # Keyless owner for parsed Object callback-prefix state. Dynamic JSON leaf
  # keys remain inside the existing per-path PrefixMaps; this owner represents
  # the Object site itself and therefore has no BinaryDynamicJsonLeafKey.
  class ObjectDocumentCallbackPrefix
    enum StatisticsContext
      PrefixOnly
      Complete
    end

    alias Callback = Tuple(String, Bytes)
    alias CallbackPair = ObjectDocumentInlineCallbackOrder::CallbackPair
    alias BodyBinding = ObjectDocumentInlineCallbackOrder::BodyLaneBinding

    getter descriptor : BinaryDataType
    getter json_descriptor_depth : Int32
    getter typed_descriptor_root_depth : Int32
    getter inferred_actual_root_depth : Int32
    getter physical_prefix : String
    getter callback_prefix : String
    getter array_level : UInt64
    getter nested_context : ObjectSharedNestedSerializationContext
    getter object_structure_statistics_offset : Int32
    getter statistics_context : StatisticsContext
    getter plan : ObjectDocumentPlan
    getter structures : ObjectDynamicStructureSet

    @prefix_callbacks : Array(Callback)
    @typed_dynamic_sites : Hash(String, Hash(String, DynamicStructure))
    @root_dynamic_sites : Hash(String, Hash(String, DynamicStructure))
    @typed_dynamic_plans : Hash(String, BinaryDynamicBulkPlan)
    @root_dynamic_plans : Hash(String, BinaryDynamicBulkPlan)
    @root_dynamic_json_prefixes : Hash(String, ObjectSharedPathJsonTapeCodec::PrefixMap)
    @physical_plan : ObjectDocumentPhysicalPlan?
    @body_callbacks : Array(Callback)?
    @body_callback_slices : Array(ObjectSharedInlineCallbackReadSlice)?
    @role_bindings : Array(BodyBinding)?
    @callback_pairs : Array(CallbackPair)?
    @body_capture_started : Bool
    @body_capture_finished : Bool

    def initialize(
      @descriptor : BinaryDataType,
      @json_descriptor_depth : Int32,
      @typed_descriptor_root_depth : Int32,
      @inferred_actual_root_depth : Int32,
      @physical_prefix : String,
      @callback_prefix : String,
      @array_level : UInt64,
      @nested_context : ObjectSharedNestedSerializationContext,
      @object_structure_statistics_offset : Int32,
      @statistics_context : StatisticsContext,
      @plan : ObjectDocumentPlan,
      @structures : ObjectDynamicStructureSet,
      prefix_callbacks : Array(Callback),
      typed_dynamic_sites : Hash(String, Hash(String, DynamicStructure)),
      root_dynamic_sites : Hash(String, Hash(String, DynamicStructure)),
      typed_dynamic_plans : Hash(String, BinaryDynamicBulkPlan),
      root_dynamic_plans : Hash(String, BinaryDynamicBulkPlan),
      root_dynamic_json_prefixes : Hash(String, ObjectSharedPathJsonTapeCodec::PrefixMap),
    )
      # These owner arrays and site maps are moved, not copied, into this exact
      # selected-site state. Child-prefix maps remain keyed by real Dynamic
      # leaves and are never populated with static Object identities.
      @prefix_callbacks = prefix_callbacks
      @typed_dynamic_sites = typed_dynamic_sites
      @root_dynamic_sites = root_dynamic_sites
      @typed_dynamic_plans = typed_dynamic_plans
      @root_dynamic_plans = root_dynamic_plans
      @root_dynamic_json_prefixes = root_dynamic_json_prefixes
      @physical_plan = nil
      @body_callbacks = nil
      @body_callback_slices = nil
      @role_bindings = nil
      @callback_pairs = nil
      @body_capture_started = false
      @body_capture_finished = false
    end

    def prefix_callback_count : Int32
      @prefix_callbacks.size
    end

    def prefix_callback_at(index : Int, budget : BinaryCodecBudget) : Callback
      callback = @prefix_callbacks[index]
      budget.preflight_children(1_u64)
      budget.charge_wire_bytes(callback[0].bytesize.to_u64)
      budget.charge_node
      {String.new(callback[0].to_slice), callback[1]}
    end

    def bind_physical_plan!(physical_plan : ObjectDocumentPhysicalPlan) : Nil
      canonical = ObjectDocumentInlineCallbackOrder.canonical_root_prefix(physical_plan)
      unless canonical == @physical_prefix
        raise CorruptPartError.new("Object callback prefix plan belongs to a different canonical owner")
      end
      if existing = @physical_plan
        unless existing.same?(physical_plan)
          raise CorruptPartError.new("Object callback prefix was rebound to a different physical plan")
        end
        return nil
      end
      @physical_plan = physical_plan
      nil
    end

    def physical_plan : ObjectDocumentPhysicalPlan
      @physical_plan || raise(ArgumentError.new("Object callback prefix has not been bound to its physical owner"))
    end

    def validate_physical_owner!(candidate : ObjectDocumentPhysicalPlan) : Nil
      unless retained = @physical_plan
        raise CorruptPartError.new("Object callback prefix has no retained physical owner")
      end
      unless retained.same?(candidate)
        raise CorruptPartError.new("Object callback prefix belongs to a different physical owner")
      end
      nil
    end

    def bind_body_schedule!(
      bindings : Array(BodyBinding),
      pairs : Array(CallbackPair),
    ) : Nil
      unless bindings.size == pairs.size
        raise CorruptPartError.new("Object callback role schedule has mismatched bindings and identities")
      end
      if @role_bindings || @callback_pairs
        raise CorruptPartError.new("Object callback role schedule was bound more than once")
      end
      @role_bindings = bindings
      @callback_pairs = pairs
      nil
    end

    def body_role_bindings : Array(BodyBinding)
      @role_bindings || raise(ArgumentError.new("Object callback body role schedule is not bound"))
    end

    def body_callback_pairs : Array(CallbackPair)
      @callback_pairs || raise(ArgumentError.new("Object callback body role identities are not bound"))
    end

    def bind_body_callbacks!(
      callbacks : Array(Callback),
      slices : Array(ObjectSharedInlineCallbackReadSlice),
    ) : Nil
      unless callbacks.size == slices.size
        raise CorruptPartError.new("Object body callback roster differs from its authenticated slices")
      end
      unless callbacks.size == body_role_bindings.size && callbacks.size == body_callback_pairs.size
        raise CorruptPartError.new("Object body callbacks differ from their bound role schedule")
      end
      if @body_callbacks || @body_callback_slices
        raise CorruptPartError.new("Object body callbacks were bound more than once")
      end
      @body_callbacks = callbacks
      @body_callback_slices = slices
      @body_capture_started = true
      @body_capture_finished = true
      nil
    end

    # Shared body-capture state for nested and direct Compact owners. Payload
    # bytes remain borrowed from their authenticated source interval.
    def preflight_body_capture! : Nil
      if @body_capture_started || @body_capture_finished
        raise CorruptPartError.new("Object body callbacks were captured more than once")
      end
      nil
    end

    def start_body_capture! : Nil
      preflight_body_capture!
      @body_capture_started = true
      @body_callbacks = [] of Callback
      @body_callback_slices = [] of ObjectSharedInlineCallbackReadSlice
      nil
    end

    def preflight_body_callback!(canonical_name : String) : Nil
      unless @body_capture_started && !@body_capture_finished
        raise CorruptPartError.new("Object body callback arrived outside its capture phase")
      end
      callbacks = @body_callbacks.not_nil!
      if callbacks.any? { |entry| entry[0] == canonical_name }
        raise CorruptPartError.new("Object body callback is duplicated in its owner scope")
      end
      nil
    end

    def append_body_callback!(
      canonical_name : String,
      slice : ObjectSharedInlineCallbackReadSlice,
      budget : BinaryCodecBudget,
    ) : Nil
      preflight_and_charge_body_callback!(canonical_name, budget)
      append_precharged_body_callback!(canonical_name, slice)
      nil
    end

    # Parser-owned callback providers preflight the lifecycle/name and charge
    # the single callback node before advancing their source, then pass the
    # exact captured interval back for mutation-only retention. The protected
    # append helper remains unavailable to callers that could bypass budget
    # accounting.
    def capture_body_callback_from!(
      canonical_name : String,
      callback_name : String,
      budget : BinaryCodecBudget,
      &capture : -> ObjectSharedInlineCallbackReadSlice
    ) : Nil
      preflight_and_charge_body_callback!(canonical_name, budget)
      slice = capture.call
      unless slice.canonical_name == canonical_name && slice.callback_name == callback_name
        raise CorruptPartError.new("Object body callback source returned a different owner interval")
      end
      append_precharged_body_callback!(canonical_name, slice)
      nil
    end

    # Caller-owned callback capture precharges before consuming its source
    # tape, then uses this mutation-only step to avoid charging the node twice.
    protected def preflight_and_charge_body_callback!(
      canonical_name : String,
      budget : BinaryCodecBudget,
    ) : Nil
      preflight_body_callback!(canonical_name)
      budget.preflight_children(1_u64)
      budget.charge_node
      nil
    end

    protected def append_precharged_body_callback!(
      canonical_name : String,
      slice : ObjectSharedInlineCallbackReadSlice,
    ) : Nil
      preflight_body_callback!(canonical_name)
      callbacks = @body_callbacks.not_nil!
      slices = @body_callback_slices.not_nil!
      callbacks << {canonical_name, slice.bytes}
      slices << slice
      nil
    end

    def finish_body_capture!(expected_count : Int32) : Nil
      unless @body_capture_started
        if expected_count == 0
          @body_callbacks = [] of Callback
          @body_callback_slices = [] of ObjectSharedInlineCallbackReadSlice
          @body_capture_started = true
          @body_capture_finished = true
          return nil
        end
        raise CorruptPartError.new("Object body callbacks were not captured for their owner")
      end
      if @body_capture_finished
        raise CorruptPartError.new("Object body capture was finished more than once")
      end
      unless @body_callbacks.try(&.size) == expected_count &&
             @body_callback_slices.try(&.size) == expected_count
        raise CorruptPartError.new("Object body callback count differs from its owner schedule")
      end
      @body_capture_finished = true
      nil
    end

    def body_callback_count : Int32
      unless @body_capture_finished
        raise ArgumentError.new("Object body callbacks are not completely captured")
      end
      @body_callbacks.try(&.size) || raise(ArgumentError.new("Object body callbacks have not been captured"))
    end

    def body_callback_at(index : Int, budget : BinaryCodecBudget) : Callback
      unless @body_capture_finished
        raise ArgumentError.new("Object body callbacks are not completely captured")
      end
      callbacks = @body_callbacks || raise(ArgumentError.new("Object body callbacks have not been captured"))
      callback = callbacks[index]
      budget.preflight_children(1_u64)
      budget.charge_wire_bytes(callback[0].bytesize.to_u64)
      budget.charge_node
      {String.new(callback[0].to_slice), callback[1]}
    end

    def body_callback_slice_count : Int32
      unless @body_capture_finished
        raise ArgumentError.new("Object body callback slices are not completely captured")
      end
      @body_callback_slices.try(&.size) || raise(ArgumentError.new("Object body callback slices have not been captured"))
    end

    def body_callback_slice_at(index : Int) : ObjectSharedInlineCallbackReadSlice
      unless @body_capture_finished
        raise ArgumentError.new("Object body callback slices are not completely captured")
      end
      slices = @body_callback_slices || raise(ArgumentError.new("Object body callback slices have not been captured"))
      slices[index]
    end

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

    def typed_dynamic_sites_for(path : String, budget : BinaryCodecBudget) : Hash(String, DynamicStructure)
      sites = @typed_dynamic_sites[path]? || raise(KeyError.new("Object typed Dynamic sites not found: #{path.inspect}"))
      copy_sites(sites, budget)
    end

    def typed_dynamic_plan_for(path : String) : BinaryDynamicBulkPlan
      @typed_dynamic_plans[path]? || raise(KeyError.new("Object typed Dynamic plan not found: #{path.inspect}"))
    end

    def root_dynamic_plan_for(path : String) : BinaryDynamicBulkPlan
      @root_dynamic_plans[path]? || raise(KeyError.new("Object root Dynamic plan not found: #{path.inspect}"))
    end

    def root_dynamic_sites_for(path : String, budget : BinaryCodecBudget) : Hash(String, DynamicStructure)
      sites = @root_dynamic_sites[path]? || raise(KeyError.new("Object root Dynamic sites not found: #{path.inspect}"))
      copy_sites(sites, budget)
    end

    def root_dynamic_json_prefixes_for(path : String) : ObjectSharedPathJsonTapeCodec::PrefixMap
      @root_dynamic_json_prefixes[path]? || raise(KeyError.new("Object root Dynamic JSON prefixes not found: #{path.inspect}"))
    end

    private def copy_sites(
      sites : Hash(String, DynamicStructure),
      budget : BinaryCodecBudget,
    ) : Hash(String, DynamicStructure)
      count = sites.size.to_u64
      byte_count = 0_u64
      sites.each_key { |path| byte_count = checked_add(byte_count, path.bytesize.to_u64) }
      budget.preflight_children(count) if count > 0_u64
      budget.charge_wire_bytes(byte_count) if byte_count > 0_u64
      count.times { budget.charge_node }
      copied = Hash(String, DynamicStructure).new(initial_capacity: sites.size)
      sites.each { |path, structure| copied[path] = structure }
      copied
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        raise UnsupportedFormatError.new("Object callback state work size overflows UInt64")
      end
      left + right
    end
  end
end
