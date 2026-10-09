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
    @body_callbacks : Array(Tuple(String, Bytes))?
    @body_callback_slices : Array(ObjectSharedInlineCallbackReadSlice)?

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
    )
      # The reader transfers ownership of this array; copying it here would
      # duplicate the retained callback roster without operation-budget work.
      @prefix_callbacks = prefix_callbacks
      @typed_dynamic_sites = typed_dynamic_sites
      @root_dynamic_sites = root_dynamic_sites
      @typed_dynamic_plans = typed_dynamic_plans
      @root_dynamic_plans = root_dynamic_plans
      @body_callbacks = nil
      @body_callback_slices = nil
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
      if @body_callbacks
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
      callback_pairs.each do |canonical_name, callback_name|
        slice = tape.take_inline_fragment_slice(canonical_name, callback_name)
        callbacks << {canonical_name, slice.bytes}
        slices << slice
      end
      @body_callbacks = callbacks
      @body_callback_slices = slices
      nil
    end

    def body_callback_count : Int32
      @body_callbacks.try(&.size) || raise(ArgumentError.new("inline Object body callbacks have not been captured"))
    end

    # Budgeted detached callback-name snapshot; payload bytes remain borrowed
    # from the parent Data tape and are never copied by this accessor.
    def body_callback_at(index : Int, budget : BinaryCodecBudget) : Tuple(String, Bytes)
      callbacks = @body_callbacks || raise(ArgumentError.new("inline Object body callbacks have not been captured"))
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
      @body_callback_slices.try(&.size) || raise(ArgumentError.new("inline Object body callbacks have not been captured"))
    end

    def body_callback_slice_at(index : Int) : ObjectSharedInlineCallbackReadSlice
      slices = @body_callback_slices || raise(ArgumentError.new("inline Object body callbacks have not been captured"))
      slices[index]
    end

    def typed_dynamic_plan_for(path : String) : BinaryDynamicBulkPlan
      @typed_dynamic_plans[path]? || raise(KeyError.new("inline typed Dynamic plan not found: #{path.inspect}"))
    end

    def root_dynamic_plan_for(path : String) : BinaryDynamicBulkPlan
      @root_dynamic_plans[path]? || raise(KeyError.new("inline root Dynamic plan not found: #{path.inspect}"))
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
