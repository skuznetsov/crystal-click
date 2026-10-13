module CrystalClick
  # Request-local owner for one selected-mark Advanced Compact Object read.
  # It binds the already-authenticated source capture to value-free ordinary
  # streams and raw shared-data preparation; ObjectDocument values are created
  # only by decode_with_budget for this mark.
  class CompactStaticJsonAdvancedPreparedMark
    @budget : BinaryCodecBudget
    @ordinary_profile : BinaryBulkProfile
    @typed_schema : Hash(String, BinaryDataType)
    @typed_descriptor_root_depth : Int32
    @inferred_actual_root_depth : Int32
    @ordinary_streams : ObjectDocumentStreams
    @shared_prepared : ObjectSharedAdvancedInlinePrepared
    @grid : StorageOccurrenceGrid
    @logical_row_count : UInt64

    def self.prepare_from_source(
      prefix : ObjectDocumentCallbackPrefix,
      physical_plan : ObjectDocumentPhysicalPlan,
      grid : StorageOccurrenceGrid,
      budget : BinaryCodecBudget,
      role_bindings : Array(ObjectDocumentInlineCallbackOrder::BodyLaneBinding),
      callback_pairs : Array(ObjectDocumentInlineCallbackOrder::CallbackPair),
      statistics_offsets : Hash(String, Int32),
      ordinary_profile : BinaryBulkProfile,
      source_framer : CompactJsonObjectSiteFramer | CompactRecursiveJsonObjectSiteSource,
      workspace_observer : Proc(UInt64, Nil)? = nil,
      schedule : CompactJsonObjectRoleSchedule? = nil,
    ) : CompactStaticJsonAdvancedPreparedMark
      nested_context = prefix.nested_context
      if budget.writing? || nested_context.writing?
        raise ArgumentError.new("prepared Compact Advanced mark requires read-direction contexts")
      end
      prefix.validate_physical_owner!(physical_plan)
      unless prefix.statistics_context == ObjectDocumentCallbackPrefix::StatisticsContext::Complete
        raise UnsupportedFormatError.new("prepared Compact Advanced mark requires complete Object statistics")
      end
      unless ordinary_profile == nested_context.profile
        raise CorruptPartError.new("prepared Compact ordinary profile differs from its inherited Object context")
      end

      object = prefix.plan.structures.object
      version = nested_context.shared_data_version
      unless version == 2_u64 || version == 3_u64
        raise UnsupportedFormatError.new("prepared Compact Advanced mark requires SharedData v2 or v3")
      end
      unless object.shared_data_version == version
        raise CorruptPartError.new("prepared Compact Advanced version differs from its Object structure")
      end

      # This is the source-authentication boundary: only a completed framer
      # for this exact physical owner, prefix, schedule, and budget can reach
      # either materializer below.
      prepared_schedule = schedule || begin
        unless prefix.plan.typed_dynamic_json_object_leaf_plans(budget).empty?
          raise UnsupportedFormatError.new("prepared Compact Advanced JSON child requires its captured callback schedule")
        end
        CompactJsonObjectRoleSchedule.build(prefix, physical_plan, ordinary_profile, budget)
      end
      source_framer.validate_prepared_source!(
        prefix,
        physical_plan,
        role_bindings,
        callback_pairs,
        budget,
        prepared_schedule,
      )

      ordinary_streams = ObjectDocumentInlineBodyMaterializer.materialize(
        prefix,
        physical_plan,
        grid,
        budget,
        role_bindings,
        callback_pairs,
        statistics_offsets,
        defer_advanced_values: true,
      )
      shared_prepared = ObjectSharedAdvancedInlinePrepared.prepare_from_source(
        prefix,
        physical_plan,
        grid,
        budget,
        role_bindings,
        callback_pairs,
      )
      typed_schema = prefix.typed_schema_for(budget)
      logical_rows = grid.logical_occurrences_at(0)
      unless ordinary_streams.mark_count == 1 &&
             ordinary_streams.row_count_at(0) == logical_rows &&
             ordinary_streams.shared_bucket_count == 0 &&
             ordinary_streams.advanced_shared_mark_count == 0 &&
             shared_prepared.logical_row_count == logical_rows
        raise CorruptPartError.new("prepared Compact Advanced mark components disagree with their one-mark grid")
      end

      owner = new(
        budget,
        ordinary_profile,
        typed_schema,
        prefix.typed_descriptor_root_depth,
        prefix.inferred_actual_root_depth,
        ordinary_streams,
        shared_prepared,
        grid,
        logical_rows,
      )
      if observer = workspace_observer
        observer.call(owner.retained_workspace_bytes)
      end
      owner
    end

    private def initialize(
      @budget : BinaryCodecBudget,
      @ordinary_profile : BinaryBulkProfile,
      @typed_schema : Hash(String, BinaryDataType),
      @typed_descriptor_root_depth : Int32,
      @inferred_actual_root_depth : Int32,
      @ordinary_streams : ObjectDocumentStreams,
      @shared_prepared : ObjectSharedAdvancedInlinePrepared,
      @grid : StorageOccurrenceGrid,
      @logical_row_count : UInt64,
    )
    end

    def logical_row_count : UInt64
      @logical_row_count
    end

    # Decode this prepared mark using the exact budget operation that captured
    # it. Workspace notifications are named logical-owner boundaries after
    # materialization; they are not a preallocation limit or RSS estimate.
    def decode_with_budget(
      budget : BinaryCodecBudget,
      workspace_observer : Proc(UInt64, Nil)? = nil,
    ) : Array(ObjectDocument)
      if budget.writing?
        raise ArgumentError.new("prepared Compact Advanced decode requires a read-direction budget")
      end
      unless @budget.same?(budget)
        raise ArgumentError.new("prepared Compact Advanced decode requires the same budget operation")
      end
      @shared_prepared.validate_decode_operation!(budget)

      advanced_rows = ObjectSharedAdvancedInlineDecoder.decode_prepared(@shared_prepared, budget)
      unless advanced_rows.size == 1 && advanced_rows[0].size.to_u64 == @logical_row_count
        raise CorruptPartError.new("prepared Compact Advanced decode returned the wrong mark grid")
      end
      observe_workspace(
        workspace_observer,
        checked_add(retained_workspace_bytes, shared_rows_workspace_bytes(advanced_rows)),
      )

      streams = streams_with_advanced_rows(advanced_rows)
      observe_workspace(
        workspace_observer,
        checked_add(
          checked_add(retained_workspace_bytes, shared_rows_workspace_bytes(advanced_rows)),
          stream_shell_workspace_bytes(streams),
        ),
      )

      decoded_marks = ObjectDocumentCodec.decode_child_site_with_budget(
        @typed_schema,
        streams,
        @grid,
        budget,
        first_mark: 0,
        mark_count: 1,
        profile: @ordinary_profile,
        shared_profile: BinaryBulkProfile.single_stream,
        typed_descriptor_root_depth: @typed_descriptor_root_depth,
        inferred_actual_root_depth: @inferred_actual_root_depth,
      )
      unless decoded_marks.size == 1 && decoded_marks[0].size.to_u64 == @logical_row_count
        raise CorruptPartError.new("prepared Compact Advanced decoder returned the wrong mark grid")
      end
      documents = decoded_marks[0]
      active = checked_add(retained_workspace_bytes, shared_rows_workspace_bytes(advanced_rows))
      active = checked_add(active, stream_shell_workspace_bytes(streams))
      observe_workspace(workspace_observer, checked_add(active, documents_workspace_bytes(documents)))
      documents
    end

    # Logical retained-owner estimate for this mark. It covers this owner's
    # schema/stream references, the ordinary detached lane owners, and the
    # raw advanced prepared holder. It intentionally excludes allocator
    # capacity, decoder-internal transient peaks, and RSS.
    def retained_workspace_bytes : UInt64
      bytes = instance_sizeof(CompactStaticJsonAdvancedPreparedMark).to_u64
      bytes = checked_add(bytes, sizeof(Pointer(BinaryCodecBudget)).to_u64)
      bytes = checked_add(bytes, sizeof(Pointer(BinaryBulkProfile)).to_u64)
      bytes = checked_add(bytes, sizeof(Pointer(ObjectDocumentStreams)).to_u64)
      bytes = checked_add(bytes, sizeof(Pointer(ObjectSharedAdvancedInlinePrepared)).to_u64)
      bytes = checked_add(bytes, grid_workspace_bytes)
      bytes = checked_add(bytes, typed_schema_workspace_bytes)
      bytes = checked_add(bytes, ordinary_stream_workspace_bytes(@ordinary_streams))
      checked_add(bytes, @shared_prepared.retained_workspace_bytes)
    end

    private def grid_workspace_bytes : UInt64
      bytes = instance_sizeof(StorageOccurrenceGrid).to_u64
      bytes = checked_add(bytes, 2_u64 * instance_sizeof(Array(UInt64)).to_u64)
      checked_add(bytes, checked_multiply(@grid.mark_count.to_u64, 2_u64 * sizeof(UInt64).to_u64))
    end

    private def streams_with_advanced_rows(
      advanced_rows : Array(Array(ObjectSharedMapRow)),
    ) : ObjectDocumentStreams
      typed_paths = Hash(String, BinaryBulkStreams).new(initial_capacity: @ordinary_streams.typed_path_count)
      @ordinary_streams.typed_path_count.times do |index|
        path = @ordinary_streams.typed_path_at(index)
        typed_paths[path] = @ordinary_streams.typed_for(path)
      end

      typed_dynamic_paths = Hash(String, BinaryDynamicBulkStreams).new(
        initial_capacity: @ordinary_streams.typed_dynamic_path_count,
      )
      typed_dynamic_statistics_offsets = Hash(String, Int32).new
      typed_dynamic_site_statistics_offsets = Hash(String, Hash(String, Int32)).new
      @ordinary_streams.typed_dynamic_path_count.times do |index|
        path = @ordinary_streams.typed_dynamic_path_at(index)
        dynamic = @ordinary_streams.typed_dynamic_for(path)
        if dynamic.json_object_count > 0
          raise UnsupportedFormatError.new("prepared Compact Advanced typed Dynamic JSON children are outside this root checkpoint")
        end
        typed_dynamic_paths[path] = dynamic
        if offset = @ordinary_streams.typed_dynamic_statistics_offset(path)
          typed_dynamic_statistics_offsets[path] = offset
        end
        offsets = Hash(String, Int32).new(initial_capacity: dynamic.structures.site_count)
        dynamic.structures.site_paths.each do |site_path|
          if offset = @ordinary_streams.typed_dynamic_site_statistics_offset(path, site_path)
            offsets[site_path] = offset
          end
        end
        typed_dynamic_site_statistics_offsets[path] = offsets
      end

      dynamic_paths = Hash(String, DynamicValueStreams).new(initial_capacity: @ordinary_streams.dynamic_path_count)
      @ordinary_streams.dynamic_path_count.times do |index|
        path = @ordinary_streams.dynamic_path_at(index)
        dynamic = @ordinary_streams.dynamic_for(path)
        if dynamic.json_object_leaf_count > 0
          raise UnsupportedFormatError.new("prepared Compact Advanced Dynamic JSON children are outside this root checkpoint")
        end
        dynamic_paths[path] = dynamic
      end

      ObjectDocumentStreams.new(
        @ordinary_streams.structures,
        @ordinary_streams.rows_per_mark,
        typed_paths,
        dynamic_paths,
        [] of BinaryBulkStreams,
        typed_dynamic_paths,
        typed_dynamic_statistics_offsets,
        typed_dynamic_site_statistics_offsets,
        @ordinary_streams.typed_dynamic_mode,
        advanced_rows,
      )
    end

    private def typed_schema_workspace_bytes : UInt64
      bytes = instance_sizeof(Hash(String, BinaryDataType)).to_u64
      @typed_schema.each do |path, _type|
        bytes = checked_add(bytes, string_owner_bytes(path.bytesize))
        bytes = checked_add(bytes, instance_sizeof(BinaryDataType).to_u64)
      end
      bytes
    end

    private def ordinary_stream_workspace_bytes(streams : ObjectDocumentStreams) : UInt64
      bytes = instance_sizeof(ObjectDocumentStreams).to_u64
      bytes = checked_add(bytes, instance_sizeof(Array(UInt64)).to_u64)
      bytes = checked_add(bytes, checked_multiply(streams.mark_count.to_u64, sizeof(UInt64).to_u64))
      structures = streams.structures
      bytes = checked_add(bytes, instance_sizeof(ObjectDynamicStructureStreams).to_u64)
      bytes = checked_add(bytes, structures.total_input_byte_size)

      bytes = checked_add(bytes, instance_sizeof(Array(String)).to_u64)
      bytes = checked_add(bytes, checked_multiply(streams.typed_path_count.to_u64, sizeof(Pointer(String)).to_u64))
      streams.typed_path_count.times do |index|
        path = streams.typed_path_at(index)
        bytes = checked_add(bytes, string_owner_bytes(path.bytesize))
        bytes = checked_add(bytes, bulk_stream_workspace_bytes(streams.typed_for(path)))
      end

      bytes = checked_add(bytes, instance_sizeof(Array(String)).to_u64)
      bytes = checked_add(bytes, checked_multiply(streams.typed_dynamic_path_count.to_u64, sizeof(Pointer(String)).to_u64))
      streams.typed_dynamic_path_count.times do |index|
        path = streams.typed_dynamic_path_at(index)
        bytes = checked_add(bytes, string_owner_bytes(path.bytesize))
        dynamic = streams.typed_dynamic_for(path)
        bytes = checked_add(bytes, instance_sizeof(BinaryDynamicBulkStreams).to_u64)
        bytes = checked_add(bytes, dynamic.structures.total_input_byte_size)
        bytes = checked_add(bytes, bulk_stream_workspace_bytes(dynamic.data))
        bytes = checked_add(bytes, checked_multiply(dynamic.structures.site_count.to_u64,
          sizeof(Pointer(String)).to_u64))
        dynamic.structures.site_paths.each { |site| bytes = checked_add(bytes, string_owner_bytes(site.bytesize)) }
      end

      bytes = checked_add(bytes, instance_sizeof(Array(String)).to_u64)
      bytes = checked_add(bytes, checked_multiply(streams.dynamic_path_count.to_u64, sizeof(Pointer(String)).to_u64))
      streams.dynamic_path_count.times do |index|
        path = streams.dynamic_path_at(index)
        bytes = checked_add(bytes, string_owner_bytes(path.bytesize))
        dynamic = streams.dynamic_for(path)
        bytes = checked_add(bytes, instance_sizeof(DynamicValueStreams).to_u64)
        discriminators = dynamic.discriminators
        bytes = checked_add(bytes, instance_sizeof(DynamicDiscriminatorStream).to_u64)
        bytes = checked_add(bytes, discriminators.byte_size.to_u64)
        bytes = checked_add(bytes, instance_sizeof(Array(DynamicDiscriminatorMark)).to_u64)
        bytes = checked_add(bytes, checked_multiply(discriminators.mark_count.to_u64,
          sizeof(DynamicDiscriminatorMark).to_u64))
        names = dynamic.arm_names
        bytes = checked_add(bytes, instance_sizeof(Array(String)).to_u64)
        bytes = checked_add(bytes, checked_multiply(names.size.to_u64, sizeof(Pointer(String)).to_u64))
        names.each do |name|
          bytes = checked_add(bytes, string_owner_bytes(name.bytesize))
          bytes = checked_add(bytes, bulk_stream_workspace_bytes(dynamic.arm(name)))
        end
      end

      bytes = checked_add(bytes, instance_sizeof(Array(BinaryBulkStreams)).to_u64)
      bytes = checked_add(bytes, checked_multiply(streams.shared_bucket_count.to_u64,
        sizeof(Pointer(BinaryBulkStreams)).to_u64))
      streams.shared_bucket_count.times do |index|
        bytes = checked_add(bytes, bulk_stream_workspace_bytes(streams.shared_bucket(index)))
      end
      bytes
    end

    private def bulk_stream_workspace_bytes(streams : BinaryBulkStreams) : UInt64
      bytes = instance_sizeof(BinaryBulkStreams).to_u64
      bytes = checked_add(bytes, streams.total_input_byte_size)
      bytes = checked_add(bytes, checked_multiply(streams.role_count.to_u64,
        sizeof(Pointer(BinaryBulkStream)).to_u64))
      streams.roles.each do |role|
        bytes = checked_add(bytes, string_owner_bytes(role.bytesize))
        stream = streams.stream(role)
        bytes = checked_add(bytes, instance_sizeof(BinaryBulkStream).to_u64)
        bytes = checked_add(bytes, checked_multiply(stream.offset_count.to_u64, sizeof(UInt64).to_u64))
      end
      bytes
    end

    private def stream_shell_workspace_bytes(streams : ObjectDocumentStreams) : UInt64
      # The stream owners and lane payloads are shared with @ordinary_streams;
      # count only the wrapper/roster copied for this decode invocation.
      bytes = instance_sizeof(ObjectDocumentStreams).to_u64
      bytes = checked_add(bytes, instance_sizeof(Array(UInt64)).to_u64)
      bytes = checked_add(bytes, checked_multiply(streams.mark_count.to_u64, sizeof(UInt64).to_u64))
      {streams.typed_path_count, streams.typed_dynamic_path_count, streams.dynamic_path_count}.each do |count|
        bytes = checked_add(bytes, instance_sizeof(Array(String)).to_u64)
        bytes = checked_add(bytes, checked_multiply(count.to_u64, sizeof(Pointer(String)).to_u64))
      end
      bytes = checked_add(bytes, instance_sizeof(Array(BinaryBulkStreams)).to_u64)
      bytes = checked_add(bytes, checked_multiply(streams.shared_bucket_count.to_u64,
        sizeof(Pointer(BinaryBulkStreams)).to_u64))
      bytes = checked_add(bytes, instance_sizeof(Array(Array(ObjectSharedMapRow))).to_u64)
      bytes = checked_add(bytes, sizeof(Pointer(Array(ObjectSharedMapRow))).to_u64)
      unless streams.advanced_shared_mark_count == 1
        raise CorruptPartError.new("prepared Compact Advanced stream wrapper lost its one-mark shared rows")
      end
      bytes = checked_add(bytes, instance_sizeof(Array(ObjectSharedMapRow)).to_u64)
      bytes = checked_add(bytes, checked_multiply(streams.advanced_shared_row_count_at(0).to_u64,
        sizeof(Pointer(ObjectSharedMapRow)).to_u64))
      bytes
    end

    private def shared_rows_workspace_bytes(groups : Array(Array(ObjectSharedMapRow))) : UInt64
      bytes = instance_sizeof(Array(Array(ObjectSharedMapRow))).to_u64
      bytes = checked_add(bytes, checked_multiply(groups.size.to_u64,
        sizeof(Pointer(Array(ObjectSharedMapRow))).to_u64))
      groups.each do |rows|
        bytes = checked_add(bytes, instance_sizeof(Array(ObjectSharedMapRow)).to_u64)
        bytes = checked_add(bytes, checked_multiply(rows.size.to_u64, sizeof(Pointer(ObjectSharedMapRow)).to_u64))
        rows.each do |row|
          bytes = checked_add(bytes, instance_sizeof(ObjectSharedMapRow).to_u64)
          bytes = checked_add(bytes, checked_multiply(row.entry_count.to_u64,
            sizeof(Pointer(ObjectSharedMapEntry)).to_u64))
          row.entry_count.times do |index|
            entry = row.entry_at(index)
            bytes = checked_add(bytes, instance_sizeof(ObjectSharedMapEntry).to_u64)
            bytes = checked_add(bytes, sizeof(Bytes).to_u64 + entry.path_byte_size.to_u64)
            bytes = checked_add(bytes, binary_value_workspace_bytes(entry.value))
          end
        end
      end
      bytes
    end

    private def documents_workspace_bytes(documents : Array(ObjectDocument)) : UInt64
      bytes = instance_sizeof(Array(ObjectDocument)).to_u64
      bytes = checked_add(bytes, checked_multiply(documents.size.to_u64, sizeof(Pointer(ObjectDocument)).to_u64))
      documents.each do |document|
        bytes = checked_add(bytes, instance_sizeof(ObjectDocument).to_u64)
        bytes = checked_add(bytes, checked_multiply(document.path_count.to_u64,
          sizeof(Pointer(String)).to_u64 + sizeof(Pointer(BinaryValue)).to_u64))
        document.path_count.times do |index|
          path = document.path_at(index)
          bytes = checked_add(bytes, string_owner_bytes(path.bytesize))
          bytes = checked_add(bytes, binary_value_workspace_bytes(document.value_for(path)))
        end
      end
      bytes
    end

    private def binary_value_workspace_bytes(value : BinaryValue) : UInt64
      bytes = checked_add(instance_sizeof(BinaryValue).to_u64, value.byte_size.to_u64)
      children = value.element_count
      bytes = checked_add(bytes, checked_multiply(children.to_u64, sizeof(Pointer(BinaryValue)).to_u64))
      children.times { |index| bytes = checked_add(bytes, binary_value_workspace_bytes(value.element_at(index))) }
      if value.type.tag == BinaryDataType::TAG_JSON
        row = value.json_row
        bytes = checked_add(bytes, instance_sizeof(BinaryJsonRow).to_u64)
        bytes = checked_add(bytes, checked_multiply(row.path_count.to_u64,
          sizeof(Pointer(String)).to_u64 + sizeof(Pointer(BinaryValue)).to_u64))
        row.path_count.times do |index|
          bytes = checked_add(bytes, string_owner_bytes(row.path_byte_size(index)))
          if nested = row.value_at(index)
            bytes = checked_add(bytes, binary_value_workspace_bytes(nested))
          end
        end
      end
      bytes
    end

    private def observe_workspace(observer : Proc(UInt64, Nil)?, bytes : UInt64) : Nil
      observer.try(&.call(bytes))
      nil
    end

    private def string_owner_bytes(byte_size : Int) : UInt64
      checked_add(instance_sizeof(String).to_u64, byte_size.to_u64 + 1_u64)
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      if right > UInt64::MAX - left
        raise CorruptPartError.new("prepared Compact Advanced workspace estimate overflows")
      end
      left + right
    end

    private def checked_multiply(left : UInt64, right : UInt64) : UInt64
      if left > 0_u64 && right > UInt64::MAX // left
        raise CorruptPartError.new("prepared Compact Advanced workspace estimate overflows")
      end
      left * right
    end
  end
end
