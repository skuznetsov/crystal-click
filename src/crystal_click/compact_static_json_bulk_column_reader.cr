module CrystalClick
  # Direct reader for one static root JSON column in a plain Compact part.
  # The bounded checkpoints admit named mrk4 MAP/ADVANCED_CHUNKED events and
  # one unlabelled mrk3 MAP root tape. Each validates the complete selected
  # mark grid at EOF before decoding any ObjectDocument value.
  class CompactStaticJsonBulkColumnReader
    getter row_count : UInt64
    getter mark_count : Int32
    getter ordinary_profile : BinaryBulkProfile
    getter logical_read_bytes : UInt64

    @part_path : String
    @column_name : String
    @type : BinaryDataType
    @limits : BinaryCodecLimits
    @transport_limits : CompressedStreamLimits
    @codec_budget : BinaryCodecBudget?
    @transport_budget : CompressedStreamBudget?
    @context : CompactPartPhysicalContext
    @serialization_profile : CompactSerializationProfile
    @manifest : CompactStaticJsonSiteManifest
    @mark_row_counts : Array(UInt64)
    @schema_declaration : String
    @source_declaration : String
    @physical_stream_names : Array(String)
    @selected_checksum_names : Array(String)
    @prepared_context : CompactStaticJsonPreparedContext?
    @frozen_event_names : Array(String)?
    @advanced_layout : Bool?

    def self.open(
      part_path : String,
      column_name : String,
      expected_type : BinaryDataType,
      limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
      transport_limits : CompressedStreamLimits = CompressedStreamLimits.new,
      codec_budget : BinaryCodecBudget? = nil,
      transport_budget : CompressedStreamBudget? = nil,
    ) : CompactStaticJsonBulkColumnReader
      new(part_path, column_name, expected_type, limits, transport_limits, codec_budget, transport_budget)
    end

    private def initialize(
      part_path : String,
      column_name : String,
      @type : BinaryDataType,
      @limits : BinaryCodecLimits,
      @transport_limits : CompressedStreamLimits,
      codec_budget : BinaryCodecBudget?,
      transport_budget : CompressedStreamBudget?,
    )
      StorageReadBudgetValidator.validate!(
        codec_budget,
        transport_budget,
        @limits,
        @transport_limits,
        "Compact static JSON codec budget differs from its read limits",
        "Compact static JSON transport budget differs from its read limits",
      )
      @codec_budget = codec_budget
      @transport_budget = transport_budget

      unless @type.tag == BinaryDataType::TAG_JSON
        raise UnsupportedFormatError.new("Compact static JSON reader requires a root JSON declaration")
      end
      if column_name.empty? || column_name.bytesize > WidePartTable::MAX_COLUMN_NAME_BYTES
        raise ArgumentError.new("Compact static JSON column name is empty or exceeds its bound")
      end

      @part_path = File.expand_path(part_path)
      @column_name = String.new(column_name.to_slice)
      name_budget = codec_budget || BinaryCodecBudget.new(@limits)
      name_bounds = BinaryTypeNameBudget.measure(@type, name_budget)
      canonical = BinaryTypeNameBudget.materialize(@type, name_budget, name_bounds)
      name_budget.ensure_wire_bytes(canonical.bytesize.to_u64)
      name_budget.charge_wire_bytes(canonical.bytesize.to_u64)
      @schema_declaration = String.new(canonical.to_slice)
      @source_declaration = String.new(canonical.to_slice)

      operation_transport_budget = transport_budget || CompressedStreamBudget.new(@transport_limits)
      @transport_budget = operation_transport_budget
      @context = CompactPartPhysicalContext.open(@part_path, operation_transport_budget)
      unless @context.mode.mrk3? || @context.mode.mrk4?
        raise UnsupportedFormatError.new("Compact static JSON reader requires plain mrk3 or mrk4 marks")
      end
      if @context.row_count == 0_u64 || @context.row_count > WidePartTable::MAX_TOTAL_ROWS
        raise CorruptPartError.new("Compact static JSON row count is outside the typed reader bound")
      end

      physical_columns = @context.columns
      source_type = physical_columns.find { |name, _| name == @column_name }.try(&.[1])
      unless source_type == canonical
        raise CorruptPartError.new("Compact static JSON declaration differs from columns.txt")
      end

      @serialization_profile = CompactSerializationProfile.open(
        @part_path,
        physical_columns,
        @column_name,
        @type,
        @context.row_count,
        operation_transport_budget,
      )
      @ordinary_profile = @serialization_profile.ordinary_profile
      @manifest = CompactStaticJsonSiteManifest.new(@column_name, @type)

      selected_slots = @context.physical_roster.select { |slot| slot.column_name == @column_name }
      if selected_slots.empty?
        raise CorruptPartError.new("Compact static JSON column has no physical callback slots")
      end
      if @context.mode.mrk4?
        names = selected_slots.map do |slot|
          slot.stream_name || raise(CorruptPartError.new("Compact mrk4 static JSON callback has no stream name"))
        end
        seen_names = Set(String).new
        names.each do |name|
          unless seen_names.add?(name)
            raise CorruptPartError.new("Compact static JSON physical callback roster is duplicated")
          end
        end
        @physical_stream_names = copy_strings(names)
      else
        unless selected_slots.size == 1 && selected_slots[0].stream_name.nil?
          raise CorruptPartError.new("Compact mrk3 JSON column is not one unlabelled physical tape")
        end
        @physical_stream_names = [] of String
      end

      @mark_row_counts = @context.mark_row_counts
      if @mark_row_counts.empty? || @mark_row_counts.size > WidePartTable::MAX_MARKS_PER_READER
        raise CorruptPartError.new("Compact static JSON mark count is outside the reader bound")
      end
      total_rows = 0_u64
      @mark_row_counts.each do |rows|
        if rows == 0_u64 || rows > WidePartTable::MAX_MARK_ROWS ||
           rows > WidePartTable::MAX_TOTAL_ROWS - total_rows
          raise CorruptPartError.new("Compact static JSON mark rows are outside the reader bound")
        end
        total_rows += rows
      end
      unless total_rows == @context.row_count
        raise CorruptPartError.new("Compact static JSON mark grid differs from its part row count")
      end

      @row_count = @context.row_count
      @mark_count = @mark_row_counts.size.to_i32
      @selected_checksum_names = @context.mode.mrk4? ? ["data.bin", "data.mrk4"] : ["data.bin", "data.mrk3"]
      @logical_read_bytes = @context.logical_bytes_for(@column_name)
      @prepared_context = nil
      @frozen_event_names = nil
      @advanced_layout = nil
    end

    def schema_declaration : String
      String.new(@schema_declaration.to_slice)
    end

    def source_declaration : String
      String.new(@source_declaration.to_slice)
    end

    def mark_row_counts : Array(UInt64)
      @mark_row_counts.dup
    end

    def physical_stream_names : Array(String)
      copy_strings(@physical_stream_names)
    end

    def selected_checksum_names : Array(String)
      copy_strings(@selected_checksum_names)
    end

    def prepared_context : CompactStaticJsonPreparedContext
      @prepared_context || raise(ArgumentError.new("Compact static JSON reader has not completed EOF-first preparation"))
    end

    def retained_grid_workspace_bytes : UInt64
      @context.retained_grid_workspace_bytes
    end

    # Logical retained-owner estimate, not allocator capacity or RSS. During
    # preparation/decoding the observer receives conservative physical-window,
    # framer, prefix/stream and output estimates at named phase boundaries,
    # not a complete decoder-internal transient peak or predecode byte ceiling.
    def retained_workspace_bytes : UInt64
      bytes = instance_sizeof(CompactStaticJsonBulkColumnReader).to_u64
      bytes = checked_add(bytes, @context.retained_workspace_bytes)
      bytes = checked_add(bytes, retained_grid_workspace_bytes)
      bytes = checked_add(bytes, instance_sizeof(CompactSerializationProfile).to_u64)
      bytes = checked_add(bytes, instance_sizeof(CompactStaticJsonSiteManifest).to_u64)
      bytes = checked_add(bytes, instance_sizeof(BinaryDataType).to_u64)
      bytes = checked_add(bytes, string_owner_bytes(@part_path))
      bytes = checked_add(bytes, string_owner_bytes(@column_name))
      bytes = checked_add(bytes, string_owner_bytes(@schema_declaration))
      bytes = checked_add(bytes, string_owner_bytes(@source_declaration))
      bytes = checked_add(bytes, string_owner_bytes(@manifest.column_name))
      bytes = checked_add(bytes, string_owner_bytes(@manifest.physical_prefix))
      bytes = checked_add(bytes, string_owner_bytes(@manifest.callback_prefix))
      bytes = checked_add(bytes, string_array_bytes(@physical_stream_names))
      bytes = checked_add(bytes, string_array_bytes(@selected_checksum_names))
      bytes = checked_add(bytes, instance_sizeof(Array(UInt64)).to_u64)
      bytes = checked_add(bytes, checked_multiply(@mark_row_counts.size.to_u64, sizeof(UInt64).to_u64))
      if prepared = @prepared_context
        bytes = checked_add(bytes, prepared.retained_workspace_bytes)
      end
      if events = @frozen_event_names
        bytes = checked_add(bytes, string_array_bytes(events))
      end
      bytes
    end

    # Validate and freeze all selected marks even for an empty selection at
    # physical EOF. ObjectDocument values are decoded only after this finishes.
    def read_marks(first_mark : Int, mark_count : Int) : Array(Array(ObjectDocument))
      no_workspace_observer = ->(_workspace_bytes : UInt64) { nil }
      read_marks(first_mark, mark_count, no_workspace_observer)
    end

    def read_marks(
      first_mark : Int,
      mark_count : Int,
      workspace_observer : Proc(UInt64, Nil),
    ) : Array(Array(ObjectDocument))
      validate_selection!(first_mark, mark_count)
      # One budget covers EOF preparation and every selected mark in this
      # operation. A caller-supplied budget remains cumulative across calls;
      # otherwise this is the fresh per-call budget.
      request_budget = @codec_budget || BinaryCodecBudget.new(@limits)
      advanced_marks = nil.as(Array(CompactStaticJsonAdvancedPreparedMark)?)
      if @advanced_layout == true || @prepared_context.nil?
        advanced_marks = ensure_prepared!(request_budget, workspace_observer)
      end

      prepared = @prepared_context || raise(CorruptPartError.new("Compact static JSON prepared context is missing"))
      selected_rows = selected_rows(first_mark, mark_count)
      advanced_layout = @advanced_layout
      if advanced_layout.nil?
        raise CorruptPartError.new("Compact static JSON layout was not prepared")
      end
      advanced_layout = advanced_layout.not_nil!
      request_owner_bytes = if advanced_layout
                              owners = advanced_marks || raise(CorruptPartError.new("Advanced Compact request owners are missing"))
                              advanced_request_workspace_bytes(owners)
                            else
                              0_u64
                            end
      output_reservation = checked_add(
        instance_sizeof(Array(Array(ObjectDocument))).to_u64,
        checked_add(
          checked_multiply(mark_count.to_u64, sizeof(Pointer(Array(ObjectDocument))).to_u64),
          checked_multiply(selected_rows, sizeof(Pointer(ObjectDocument)).to_u64),
        ),
      )
      workspace_observer.call(checked_add(retained_workspace_bytes,
        checked_add(request_owner_bytes, output_reservation)))

      output = Array(Array(ObjectDocument)).new(mark_count)
      mark_count.times do |selection_index|
        mark_index = first_mark + selection_index
        documents = if advanced_layout
                      owners = advanced_marks || raise(CorruptPartError.new("Advanced Compact request owners are missing"))
                      owner = owners[mark_index]?
                      unless owner && owner.logical_row_count == prepared.mark_row_count_at(mark_index)
                        raise CorruptPartError.new("Advanced Compact prepared mark differs from the validated row grid")
                      end
                      owner_observer = ->(owner_bytes : UInt64) do
                        active = checked_add(retained_workspace_bytes, request_owner_bytes)
                        active = checked_add(active, documents_workspace_bytes(output))
                        workspace_observer.call(checked_add(active, owner_bytes))
                        nil
                      end
                      owner.decode_with_budget(request_budget, owner_observer)
                    else
                      prepared.decode_mark_with_budget(mark_index, request_budget, @ordinary_profile)
                    end
        output << documents
        active = checked_add(retained_workspace_bytes, request_owner_bytes)
        workspace_observer.call(checked_add(active, documents_workspace_bytes(output)))
      end
      output
    end

    private def ensure_prepared!(
      budget : BinaryCodecBudget,
      workspace_observer : Proc(UInt64, Nil),
    ) : Array(CompactStaticJsonAdvancedPreparedMark)?
      base_workspace = retained_workspace_bytes
      physical_workspace = physical_window_workspace_bytes
      workspace_observer.call(checked_add(base_workspace, @logical_read_bytes))
      workspace_observer.call(checked_add(base_workspace, physical_workspace))

      # read_window authenticates every selected slot before parsing starts;
      # keeping the whole detached window alive lets late corruption fail
      # before any ObjectDocument value is decoded or returned.
      window = @context.read_window(@column_name, 0, @mark_count)
      granules = window.granules
      unless granules.size == @mark_count
        raise CorruptPartError.new("Compact static JSON physical window has the wrong mark count")
      end

      streams = Array(ObjectDocumentStreams).new(@mark_count)
      rows = Array(UInt64).new(@mark_count)
      object_prefixes = Array(Bytes).new(@mark_count)
      object_statistics_offsets = Array(Int32).new(@mark_count)
      dynamic_prefixes = Array(Hash(String, Bytes)).new(@mark_count)
      dynamic_statistics_offsets = Array(Hash(String, Int32)).new(@mark_count)
      advanced_marks = Array(CompactStaticJsonAdvancedPreparedMark).new(@mark_count)
      advanced_layout = @advanced_layout
      typed_schema = nil.as(Hash(String, BinaryDataType)?)
      frozen_names = @frozen_event_names.try { |names| copy_strings(names) }

      granules.each_with_index do |granule, mark_index|
        unless granule.mark == mark_index && granule.row_count == @mark_row_counts[mark_index]
          raise CorruptPartError.new("Compact static JSON physical window differs from its validated mark grid")
        end
        site_identity = "#{@manifest.physical_prefix}:mark=#{mark_index}"
        framer = if @context.mode.mrk4?
                   CompactJsonObjectSiteFramer.new(@context.mode, granule.shards, budget, @context, site_identity)
                 else
                   CompactJsonObjectSiteFramer.new(@context.mode, granule.shards, budget)
                 end
        observed_dynamic_offsets = Hash(String, Int32).new
        statistics_offset_observer = ->(name : String, offset : Int32) do
          if previous = observed_dynamic_offsets[name]?
            unless previous == offset
              raise CorruptPartError.new("Compact static JSON Dynamic statistics offset changed within one prefix")
            end
          else
            observed_dynamic_offsets[String.new(name.to_slice)] = offset
          end
          nil
        end
        nested_context = ObjectSharedNestedSerializationContext.for_read(0_u64, @ordinary_profile)
        prefix = ObjectDocumentCallbackPrefixReader.read_static_json_prefix(
          framer,
          @type,
          1_i32,
          @manifest.physical_prefix,
          @manifest.callback_prefix,
          0_u64,
          nested_context,
          budget,
          true,
          statistics_offset_observer,
        )
        physical_plan = ObjectDocumentPhysicalPlan.from_escaped_prefix(
          @manifest.physical_prefix,
          prefix.plan,
          @ordinary_profile,
          BinaryBulkProfile.single_stream,
          @limits,
          prefix.array_level,
          typed_descriptor_root_depth: prefix.typed_descriptor_root_depth,
          inferred_actual_root_depth: prefix.inferred_actual_root_depth,
          root_dynamic_json_budget: budget,
        )
        prefix.bind_physical_plan!(physical_plan)

        reject_nested_static_json_sites!(prefix, budget)
        # The MRK3 body tape framer recognizes only the single-MAP lane set;
        # bucketed MAP and later shared layouts need distinct role framing.
        if @context.mode.mrk3? && prefix.plan.structures.object.shared_data_version >= 1_u64
          raise UnsupportedFormatError.new("Compact mrk3 static JSON non-MAP shared-data layouts are not admitted")
        end
        schedule = CompactJsonObjectRoleSchedule.build(prefix, physical_plan, @ordinary_profile, budget)
        if advanced_layout.nil?
          advanced_layout = schedule.advanced
        elsif schedule.advanced != advanced_layout.not_nil!
          raise CorruptPartError.new("Compact static JSON shared-data layout changed between marks")
        end
        if expected_names = frozen_names
          unless schedule.event_names == expected_names
            raise CorruptPartError.new("Compact static JSON callback schedule changed between marks")
          end
        else
          frozen_names = copy_strings(schedule.event_names)
        end
        prefix.start_body_capture!
        if @context.mode.mrk3?
          CompactJsonObjectMapTapeFramer.capture_body!(
            prefix,
            physical_plan,
            schedule,
            framer,
            granule.row_count,
            @ordinary_profile,
            @limits,
            budget,
          )
        else
          schedule.body_pairs.each do |canonical_name, callback_name|
            prefix.capture_body_callback_from!(canonical_name, callback_name, budget) do
              framer.take_inline_fragment_slice(canonical_name, callback_name)
            end
          end
        end
        prefix.finish_body_capture!(schedule.body_pairs.size)
        framer.validate_expected_events!(schedule.event_names)
        framer.finish!

        grid = StorageOccurrenceGrid.new(
          [granule.row_count] of UInt64,
          [granule.row_count] of UInt64,
          budget,
        )
        complete_statistics_offsets = Hash(String, Int32).new(initial_capacity: observed_dynamic_offsets.size + 1)
        observed_dynamic_offsets.each { |name, offset| complete_statistics_offsets[name] = offset }
        object_callback_name = PhysicalStreamName.append_literal(@manifest.callback_prefix, ".object_structure")
        complete_statistics_offsets[object_callback_name] = prefix.object_structure_statistics_offset
        if schedule.advanced
          owner_observer = ->(owner_bytes : UInt64) do
            active_bytes = checked_add(base_workspace, physical_workspace)
            active_bytes = checked_add(active_bytes, framer.retained_workspace_bytes)
            active_bytes = checked_add(active_bytes, advanced_request_workspace_bytes(advanced_marks))
            active_bytes = checked_add(active_bytes,
              preparation_collections_workspace_bytes(
                streams,
                rows,
                typed_schema,
                object_prefixes,
                object_statistics_offsets,
                dynamic_prefixes,
                dynamic_statistics_offsets,
              ))
            workspace_observer.call(checked_add(active_bytes, owner_bytes))
            nil
          end
          mark_owner = CompactStaticJsonAdvancedPreparedMark.prepare_from_source(
            prefix,
            physical_plan,
            grid,
            budget,
            schedule.body_bindings,
            schedule.body_pairs,
            complete_statistics_offsets,
            @ordinary_profile,
            framer,
            owner_observer,
          )
          unless mark_owner.logical_row_count == granule.row_count
            raise CorruptPartError.new("Advanced Compact prepared mark returned the wrong row count")
          end
          advanced_marks << mark_owner
        else
          mark_streams = ObjectDocumentCallbackBodyMaterializer.materialize(
            prefix,
            physical_plan,
            grid,
            budget,
            schedule.body_bindings,
            schedule.body_pairs,
            complete_statistics_offsets,
          )
          unless mark_streams.mark_count == 1 && mark_streams.row_count_at(0) == granule.row_count
            raise CorruptPartError.new("Compact static JSON body materializer returned the wrong mark grid")
          end
          streams << mark_streams
        end

        mark_typed_schema = prefix.typed_schema_for(budget)
        if existing = typed_schema
          unless same_typed_schema?(existing, mark_typed_schema)
            raise CorruptPartError.new("Compact static JSON typed schema changed between marks")
          end
        else
          typed_schema = mark_typed_schema
        end

        retained_object_prefix, retained_dynamic_prefixes = retain_prefix_metadata(
          prefix,
          object_callback_name,
          observed_dynamic_offsets,
          budget,
        )
        rows << granule.row_count
        object_prefixes << retained_object_prefix[0]
        object_statistics_offsets << retained_object_prefix[1]
        dynamic_prefixes << retained_dynamic_prefixes[0]
        dynamic_statistics_offsets << retained_dynamic_prefixes[1]

        active_bytes = checked_add(base_workspace, physical_workspace)
        active_bytes = checked_add(active_bytes, framer.retained_workspace_bytes)
        if schedule.advanced
          active_bytes = checked_add(active_bytes, advanced_request_workspace_bytes(advanced_marks))
        end
        active_bytes = checked_add(active_bytes,
          preparation_collections_workspace_bytes(
            streams,
            rows,
            typed_schema,
            object_prefixes,
            object_statistics_offsets,
            dynamic_prefixes,
            dynamic_statistics_offsets,
          ))
        workspace_observer.call(active_bytes)
      end

      if advanced_layout.nil?
        raise CorruptPartError.new("Compact static JSON layout was not observed")
      end
      is_advanced = advanced_layout.not_nil!
      # Keep this value out of the preparation observer's closure-captured
      # nilable accumulator. Empty schemas are valid; only the absent
      # pre-publication state gets the empty fallback.
      prepared_typed_schema = if schema = typed_schema
                                schema
                              else
                                Hash(String, BinaryDataType).new
                              end
      prepared_context = CompactStaticJsonPreparedContext.new(
        is_advanced ? nil : streams,
        rows,
        prepared_typed_schema,
        object_prefixes,
        object_statistics_offsets,
        dynamic_prefixes,
        dynamic_statistics_offsets,
        2_i32,
        2_i32,
      )

      # This is the final preparation boundary. Run every potentially throwing
      # observer call before publishing the new metadata/context, so a caller
      # that rejects the logical workspace estimate cannot leave a partial
      # cache behind.
      active_bytes = checked_add(base_workspace, physical_workspace)
      active_bytes = checked_add(active_bytes, prepared_context.retained_workspace_bytes)
      if is_advanced
        active_bytes = checked_add(active_bytes, advanced_request_workspace_bytes(advanced_marks))
      end
      active_bytes = checked_add(active_bytes,
        preparation_collections_workspace_bytes(
          streams,
          rows,
          typed_schema,
          object_prefixes,
          object_statistics_offsets,
          dynamic_prefixes,
          dynamic_statistics_offsets,
        ))
      workspace_observer.call(active_bytes)

      @prepared_context = prepared_context
      @frozen_event_names = frozen_names || [] of String
      @advanced_layout = is_advanced
      is_advanced ? advanced_marks : nil
    end

    private def retain_prefix_metadata(
      prefix : ObjectDocumentCallbackPrefix,
      object_callback_name : String,
      dynamic_offsets : Hash(String, Int32),
      budget : BinaryCodecBudget,
    ) : Tuple(Tuple(Bytes, Int32), Tuple(Hash(String, Bytes), Hash(String, Int32)))
      object_bytes = nil.as(Bytes?)
      dynamic_bytes = Hash(String, Bytes).new(initial_capacity: dynamic_offsets.size)
      prefix.prefix_callback_count.times do |index|
        name, bytes = prefix.prefix_callback_at(index, budget)
        if name == object_callback_name
          if object_bytes
            raise CorruptPartError.new("Compact static JSON Object statistics prefix is duplicated")
          end
          object_bytes = bytes
        elsif dynamic_offsets.has_key?(name)
          dynamic_bytes[String.new(name.to_slice)] = bytes
        end
      end
      dynamic_offsets.each_key do |name|
        unless dynamic_bytes.has_key?(name)
          raise CorruptPartError.new("Compact static JSON Dynamic statistics prefix is missing its parsed bytes")
        end
      end
      object_prefix = object_bytes || raise(CorruptPartError.new("Compact static JSON Object statistics prefix is missing"))
      {
        {object_prefix, prefix.object_structure_statistics_offset},
        {dynamic_bytes, dynamic_offsets.dup},
      }
    end

    private def reject_nested_static_json_sites!(prefix : ObjectDocumentCallbackPrefix, budget : BinaryCodecBudget) : Nil
      unless prefix.plan.root_dynamic_json_object_leaf_plans(budget).empty? &&
             prefix.plan.typed_dynamic_json_object_leaf_plans(budget).empty?
        raise UnsupportedFormatError.new("nested JSON Object sites are outside this Compact static-root checkpoint")
      end
      nil
    end

    private def same_typed_schema?(left : Hash(String, BinaryDataType), right : Hash(String, BinaryDataType)) : Bool
      return false unless left.size == right.size
      left.each do |path, type|
        return false unless right[path]? == type
      end
      true
    end

    private def partial_stream_workspace_bytes(values : Array(ObjectDocumentStreams)) : UInt64
      bytes = instance_sizeof(Array(ObjectDocumentStreams)).to_u64
      bytes = checked_add(bytes, checked_multiply(values.size.to_u64, sizeof(Pointer(ObjectDocumentStreams)).to_u64))
      values.each do |streams|
        bytes = checked_add(bytes, instance_sizeof(ObjectDocumentStreams).to_u64)
        structures = streams.structures
        bytes = checked_add(bytes, instance_sizeof(ObjectDynamicStructureStreams).to_u64)
        bytes = checked_add(bytes, structures.total_input_byte_size)
        streams.typed_path_count.times do |index|
          lanes = streams.typed_for(streams.typed_path_at(index))
          bytes = checked_add(bytes, bulk_stream_workspace_bytes(lanes))
        end
        streams.typed_dynamic_path_count.times do |index|
          dynamic = streams.typed_dynamic_for(streams.typed_dynamic_path_at(index))
          bytes = checked_add(bytes, structures_and_data_workspace_bytes(dynamic.structures.total_input_byte_size, dynamic.data))
        end
        streams.dynamic_path_count.times do |index|
          dynamic = streams.dynamic_for(streams.dynamic_path_at(index))
          bytes = checked_add(bytes, instance_sizeof(DynamicValueStreams).to_u64)
          bytes = checked_add(bytes, dynamic.discriminators.byte_size.to_u64)
          dynamic.arm_names.each { |name| bytes = checked_add(bytes, bulk_stream_workspace_bytes(dynamic.arm(name))) }
        end
        streams.shared_bucket_count.times do |index|
          bytes = checked_add(bytes, bulk_stream_workspace_bytes(streams.shared_bucket(index)))
        end
      end
      # The normalizer and the returned stream owners can overlap while a
      # granule is being materialized; this conservative factor covers their
      # independently owned lane buffers and descriptors.
      checked_multiply(bytes, 2_u64)
    end

    private def advanced_request_workspace_bytes(
      values : Array(CompactStaticJsonAdvancedPreparedMark),
    ) : UInt64
      bytes = instance_sizeof(Array(CompactStaticJsonAdvancedPreparedMark)).to_u64
      bytes = checked_add(bytes,
        checked_multiply(values.size.to_u64, sizeof(Pointer(CompactStaticJsonAdvancedPreparedMark)).to_u64))
      values.each { |owner| bytes = checked_add(bytes, owner.retained_workspace_bytes) }
      bytes
    end

    private def preparation_collections_workspace_bytes(
      streams : Array(ObjectDocumentStreams),
      rows : Array(UInt64),
      typed_schema : Hash(String, BinaryDataType)?,
      object_prefixes : Array(Bytes),
      object_statistics_offsets : Array(Int32),
      dynamic_prefixes : Array(Hash(String, Bytes)),
      dynamic_statistics_offsets : Array(Hash(String, Int32)),
    ) : UInt64
      bytes = partial_stream_workspace_bytes(streams)
      bytes = checked_add(bytes, instance_sizeof(Array(UInt64)).to_u64)
      bytes = checked_add(bytes, checked_multiply(rows.size.to_u64, sizeof(UInt64).to_u64))
      if schema = typed_schema
        bytes = checked_add(bytes, instance_sizeof(Hash(String, BinaryDataType)).to_u64)
        schema.each do |path, type|
          bytes = checked_add(bytes, string_owner_bytes(path))
          bytes = checked_add(bytes, instance_sizeof(BinaryDataType).to_u64)
        end
      end

      bytes = checked_add(bytes, instance_sizeof(Array(Bytes)).to_u64)
      bytes = checked_add(bytes, checked_multiply(object_prefixes.size.to_u64, sizeof(Bytes).to_u64))
      object_prefixes.each do |payload|
        bytes = checked_add(bytes, checked_add(sizeof(Bytes).to_u64, payload.size.to_u64))
      end

      bytes = checked_add(bytes, instance_sizeof(Array(Int32)).to_u64)
      bytes = checked_add(bytes,
        checked_multiply(object_statistics_offsets.size.to_u64, sizeof(Int32).to_u64))

      bytes = checked_add(bytes, instance_sizeof(Array(Hash(String, Bytes))).to_u64)
      bytes = checked_add(bytes,
        checked_multiply(dynamic_prefixes.size.to_u64, sizeof(Pointer(Hash(String, Bytes))).to_u64))
      dynamic_prefixes.each do |entries|
        bytes = checked_add(bytes, instance_sizeof(Hash(String, Bytes)).to_u64)
        entries.each do |name, payload|
          bytes = checked_add(bytes, string_owner_bytes(name))
          bytes = checked_add(bytes, checked_add(sizeof(Bytes).to_u64, payload.size.to_u64))
        end
      end

      bytes = checked_add(bytes, instance_sizeof(Array(Hash(String, Int32))).to_u64)
      bytes = checked_add(bytes,
        checked_multiply(dynamic_statistics_offsets.size.to_u64, sizeof(Pointer(Hash(String, Int32))).to_u64))
      dynamic_statistics_offsets.each do |entries|
        bytes = checked_add(bytes, instance_sizeof(Hash(String, Int32)).to_u64)
        entries.each_key { |name| bytes = checked_add(bytes, string_owner_bytes(name)) }
      end
      bytes
    end

    private def structures_and_data_workspace_bytes(structure_bytes : UInt64, data : BinaryBulkStreams) : UInt64
      checked_add(instance_sizeof(BinaryDynamicBulkStreams).to_u64,
        checked_add(structure_bytes, bulk_stream_workspace_bytes(data)))
    end

    private def bulk_stream_workspace_bytes(streams : BinaryBulkStreams) : UInt64
      bytes = instance_sizeof(BinaryBulkStreams).to_u64
      bytes = checked_add(bytes, streams.total_input_byte_size)
      bytes = checked_add(bytes, checked_multiply(streams.role_count.to_u64, sizeof(Pointer(BinaryBulkStream)).to_u64))
      streams.roles.each do |role|
        bytes = checked_add(bytes, string_owner_bytes(role))
        stream = streams.stream(role)
        bytes = checked_add(bytes, instance_sizeof(BinaryBulkStream).to_u64)
        bytes = checked_add(bytes, checked_multiply(stream.offset_count.to_u64, sizeof(UInt64).to_u64))
      end
      bytes
    end

    private def physical_window_workspace_bytes : UInt64
      marks = @mark_count.to_u64
      slots = (@context.mode.mrk3? ? 1 : @physical_stream_names.size).to_u64
      shard_count = checked_multiply(marks, slots)
      bytes = checked_multiply(@logical_read_bytes, 4_u64)
      shard_owner = checked_add(
        instance_sizeof(CompactPartPhysicalShard).to_u64,
        checked_add(sizeof(Pointer(CompactPartPhysicalShard)).to_u64,
          checked_add(sizeof(Bytes).to_u64, instance_sizeof(String).to_u64)),
      )
      bytes = checked_add(bytes, checked_multiply(checked_multiply(shard_count, shard_owner), 4_u64))
      granule_owner = checked_add(
        instance_sizeof(CompactPartPhysicalGranule).to_u64,
        checked_add(instance_sizeof(Array(CompactPartPhysicalShard)).to_u64,
          sizeof(Pointer(CompactPartPhysicalGranule)).to_u64),
      )
      bytes = checked_add(bytes, checked_multiply(checked_multiply(marks, granule_owner), 4_u64))
      bytes = checked_add(bytes,
        checked_multiply(checked_multiply(shard_count, sizeof(Pointer(CompactPartPhysicalShard)).to_u64), 4_u64))
      @physical_stream_names.each do |name|
        bytes = checked_add(bytes, checked_multiply(string_owner_bytes(name), marks + 1_u64))
      end
      bytes
    end

    private def documents_workspace_bytes(marks : Array(Array(ObjectDocument))) : UInt64
      bytes = instance_sizeof(Array(Array(ObjectDocument))).to_u64
      bytes = checked_add(bytes, checked_multiply(marks.size.to_u64, sizeof(Pointer(Array(ObjectDocument))).to_u64))
      marks.each do |documents|
        bytes = checked_add(bytes, instance_sizeof(Array(ObjectDocument)).to_u64)
        bytes = checked_add(bytes, checked_multiply(documents.size.to_u64, sizeof(Pointer(ObjectDocument)).to_u64))
        documents.each do |document|
          bytes = checked_add(bytes, instance_sizeof(ObjectDocument).to_u64)
          bytes = checked_add(bytes, checked_multiply(document.path_count.to_u64,
            sizeof(Pointer(String)).to_u64 + sizeof(Pointer(BinaryValue)).to_u64))
          document.path_count.times do |path_index|
            bytes = checked_add(bytes, document.path_byte_size_at(path_index).to_u64 + 1_u64)
            value = document.value_for(document.path_at(path_index))
            bytes = checked_add(bytes, binary_value_workspace_bytes(value))
          end
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
          bytes = checked_add(bytes, row.path_byte_size(index).to_u64 + 1_u64)
          nested = row.value_at(index)
          if nested
            bytes = checked_add(bytes, binary_value_workspace_bytes(nested))
          end
        end
      end
      bytes
    end

    private def selected_rows(first_mark : Int, mark_count : Int) : UInt64
      total = 0_u64
      mark_count.times do |index|
        rows = @mark_row_counts[first_mark + index]
        if rows > UInt64::MAX - total
          raise CorruptPartError.new("Compact static JSON selected row count overflows")
        end
        total += rows
      end
      total
    end

    private def validate_selection!(first_mark : Int, mark_count : Int) : Nil
      first = first_mark.to_i128
      count = mark_count.to_i128
      if first < 0 || count < 0 || first > @mark_count.to_i128 || count > @mark_count.to_i128 - first
        raise ArgumentError.new("Compact static JSON mark selection is outside the validated grid")
      end
      nil
    end

    private def copy_strings(values : Array(String)) : Array(String)
      values.map { |value| String.new(value.to_slice) }
    end

    private def string_array_bytes(values : Array(String)) : UInt64
      bytes = instance_sizeof(Array(String)).to_u64
      bytes = checked_add(bytes, checked_multiply(values.size.to_u64, sizeof(Pointer(String)).to_u64))
      values.each { |value| bytes = checked_add(bytes, string_owner_bytes(value)) }
      bytes
    end

    private def string_owner_bytes(value : String) : UInt64
      checked_add(instance_sizeof(String).to_u64, checked_add(value.bytesize.to_u64, 1_u64))
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      if right > UInt64::MAX - left
        raise CorruptPartError.new("Compact static JSON workspace estimate overflows")
      end
      left + right
    end

    private def checked_multiply(left : UInt64, right : UInt64) : UInt64
      if left > 0_u64 && right > UInt64::MAX // left
        raise CorruptPartError.new("Compact static JSON workspace estimate overflows")
      end
      left * right
    end
  end
end
