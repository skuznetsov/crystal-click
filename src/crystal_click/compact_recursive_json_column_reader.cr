module CrystalClick
  # EOF-first reader for the bounded static Compact JSON tree slice. Root
  # Object keeps its existing root framer; recursive forms share one physical
  # parent-mark cursor and prepare each child only after the complete parent
  # lifecycle is sealed.
  class CompactRecursiveJsonColumnReader
    getter row_count : UInt64
    getter mark_count : Int32
    getter logical_read_bytes : UInt64

    private struct PreparedObjectMark
      getter typed_schema : Hash(String, BinaryDataType)
      getter streams : ObjectDocumentStreams?
      getter advanced : CompactStaticJsonAdvancedPreparedMark?
      getter grid : StorageOccurrenceGrid
      getter rows : UInt64
      getter typed_descriptor_root_depth : Int32
      getter inferred_actual_root_depth : Int32
      getter typed_json_context : ObjectDocumentTypedDynamicJsonReadContext?

      def initialize(
        @typed_schema : Hash(String, BinaryDataType),
        @streams : ObjectDocumentStreams?,
        @advanced : CompactStaticJsonAdvancedPreparedMark?,
        @grid : StorageOccurrenceGrid,
        @rows : UInt64,
        @typed_descriptor_root_depth : Int32,
        @inferred_actual_root_depth : Int32,
        @typed_json_context : ObjectDocumentTypedDynamicJsonReadContext?,
      )
      end
    end

    private class PreparedState
      getter budget : BinaryCodecBudget
      getter object_marks : Hash(String, Array(PreparedObjectMark))
      getter uint8_bytes : Hash(String, Array(Bytes))
      getter bulk_values : Hash(String, Array(Array(BinaryValue)))
      getter array_frames : Hash(String, StorageArrayOccurrenceFrame)

      def initialize(
        @budget : BinaryCodecBudget,
        @object_marks : Hash(String, Array(PreparedObjectMark)),
        @uint8_bytes : Hash(String, Array(Bytes)),
        @bulk_values : Hash(String, Array(Array(BinaryValue))),
        @array_frames : Hash(String, StorageArrayOccurrenceFrame),
      )
      end
    end

    private struct PrefixCapture
      getter site : CompactRecursiveJsonSchemaPlan::JsonSite
      getter prefix : ObjectDocumentCallbackPrefix
      getter physical_plan : ObjectDocumentPhysicalPlan
      getter schedule : CompactJsonObjectRoleSchedule
      getter source : CompactRecursiveJsonObjectSiteSource
      getter statistics_offsets : Hash(String, Int32)

      def initialize(
        @site : CompactRecursiveJsonSchemaPlan::JsonSite,
        @prefix : ObjectDocumentCallbackPrefix,
        @physical_plan : ObjectDocumentPhysicalPlan,
        @schedule : CompactJsonObjectRoleSchedule,
        @source : CompactRecursiveJsonObjectSiteSource,
        @statistics_offsets : Hash(String, Int32),
      )
      end
    end

    private struct OpenMetadata
      getter row_count : UInt64
      getter mark_count : Int32
      getter mark_row_counts : Array(UInt64)
      getter source_declaration : String
      getter ordinary_profile : BinaryBulkProfile
      getter physical_stream_names : Array(String)
      getter selected_checksum_names : Array(String)
      getter logical_read_bytes : UInt64

      def initialize(
        @row_count : UInt64,
        @mark_count : Int32,
        @mark_row_counts : Array(UInt64),
        @source_declaration : String,
        @ordinary_profile : BinaryBulkProfile,
        @physical_stream_names : Array(String),
        @selected_checksum_names : Array(String),
        @logical_read_bytes : UInt64,
      )
      end
    end

    @part_path : String
    @column_name : String
    @schema : StorageColumnSchema
    @type : BinaryDataType
    @limits : BinaryCodecLimits
    @transport_limits : CompressedStreamLimits
    @codec_budget : BinaryCodecBudget?
    @transport_budget : CompressedStreamBudget
    @context : CompactPartPhysicalContext?
    @serialization_profile : CompactSerializationProfile?
    @root_reader : CompactStaticJsonBulkColumnReader?
    @plan : CompactRecursiveJsonSchemaPlan?
    @mark_row_counts : Array(UInt64)
    @schema_declaration : String
    @source_declaration : String
    @ordinary_profile : BinaryBulkProfile
    @physical_stream_names : Array(String)
    @selected_checksum_names : Array(String)
    @prepared_state : PreparedState?

    def self.open(
      part_path : String,
      column_name : String,
      expected_schema : StorageColumnSchema,
      limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
      transport_limits : CompressedStreamLimits = CompressedStreamLimits.new,
      codec_budget : BinaryCodecBudget? = nil,
      transport_budget : CompressedStreamBudget? = nil,
    ) : CompactRecursiveJsonColumnReader
      new(part_path, column_name, expected_schema, limits, transport_limits, codec_budget, transport_budget)
    end

    def self.admitted_schema?(
      schema : StorageColumnSchema,
      limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
    ) : Bool
      CompactRecursiveJsonSchemaPlan.admitted_schema?(schema, limits)
    rescue ex : ArgumentError | UnsupportedFormatError
      false
    end

    private def initialize(
      part_path : String,
      column_name : String,
      @schema : StorageColumnSchema,
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
        "Compact recursive JSON codec budget differs from its read limits",
        "Compact recursive JSON transport budget differs from its read limits",
      )
      @codec_budget = codec_budget
      @transport_budget = transport_budget || CompressedStreamBudget.new(@transport_limits)
      unless self.class.admitted_schema?(@schema, @limits)
        raise UnsupportedFormatError.new("Compact recursive JSON schema is outside the bounded static-site subset")
      end
      if column_name.empty? || column_name.bytesize > WidePartTable::MAX_COLUMN_NAME_BYTES
        raise ArgumentError.new("Compact recursive JSON column name is empty or exceeds its bound")
      end

      @part_path = File.expand_path(part_path)
      @column_name = String.new(column_name.to_slice)
      begin
        if @schema.object?
          validate_root_object_source!(@schema, @limits)
        else
          @schema.validate_source_tree!(@limits)
        end
      rescue ex : ArgumentError
        raise ArgumentError.new(ex.message || "Compact recursive JSON schema differs from its source declaration")
      end
      validate_json_site_limits!(@schema, @limits)

      open_budget = codec_budget || BinaryCodecBudget.new(@limits)
      @type = BinaryRecursiveDataTypeNameReader.parse_canonical_with_budget(
        @schema.declaration,
        open_budget,
        1_i32,
      ) || raise(UnsupportedFormatError.new("Compact recursive JSON declaration is not a supported recursive BinaryDataType"))
      unless @type.contains_json? && !@type.contains_dynamic?
        raise UnsupportedFormatError.new("Compact recursive JSON reader requires static JSON and no Dynamic subtree")
      end
      @schema_declaration = String.new(@schema.declaration.to_slice)
      name_bounds = BinaryTypeNameBudget.measure(@type, open_budget)
      canonical = BinaryTypeNameBudget.materialize(@type, open_budget, name_bounds)
      open_budget.ensure_wire_bytes(canonical.bytesize.to_u64)
      open_budget.charge_wire_bytes(canonical.bytesize.to_u64)
      unless canonical == @schema_declaration
        raise CorruptPartError.new("Compact recursive JSON schema is not in canonical declaration form")
      end

      @prepared_state = nil
      @plan = nil
      @root_reader = nil

      metadata = if @schema.object?
                   initialize_root_delegate!(codec_budget)
                 else
                   initialize_recursive_source!(open_budget)
                 end
      @row_count = metadata.row_count
      @mark_count = metadata.mark_count
      @mark_row_counts = metadata.mark_row_counts
      @source_declaration = metadata.source_declaration
      @ordinary_profile = metadata.ordinary_profile
      @physical_stream_names = metadata.physical_stream_names
      @selected_checksum_names = metadata.selected_checksum_names
      @logical_read_bytes = metadata.logical_read_bytes
    end

    def schema_declaration : String
      String.new(@schema_declaration.to_slice)
    end

    def source_declaration : String
      String.new(@source_declaration.to_slice)
    end

    def ordinary_profile : BinaryBulkProfile
      @ordinary_profile
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

    def retained_grid_workspace_bytes : UInt64
      if reader = @root_reader
        reader.retained_grid_workspace_bytes
      else
        context = @context || raise(CorruptPartError.new("Compact recursive JSON physical context is missing"))
        context.retained_grid_workspace_bytes
      end
    end

    # Retained logical-owner estimate; it is not allocator capacity or RSS.
    # Source preparation notifications include the complete physical parent
    # grid, while this accessor covers owners retained after publication.
    def retained_workspace_bytes : UInt64
      bytes = instance_sizeof(CompactRecursiveJsonColumnReader).to_u64
      bytes = checked_add(bytes, string_owner_bytes(@part_path))
      bytes = checked_add(bytes, string_owner_bytes(@column_name))
      bytes = checked_add(bytes, string_owner_bytes(@schema_declaration))
      bytes = checked_add(bytes, string_owner_bytes(@source_declaration))
      bytes = checked_add(bytes, instance_sizeof(BinaryDataType).to_u64)
      bytes = checked_add(bytes, instance_sizeof(CompressedStreamLimits).to_u64)
      bytes = checked_add(bytes, instance_sizeof(CompressedStreamBudget).to_u64)
      bytes = checked_add(bytes, instance_sizeof(Array(UInt64)).to_u64)
      bytes = checked_add(bytes, checked_multiply(@mark_row_counts.size.to_u64, sizeof(UInt64).to_u64))
      bytes = checked_add(bytes, string_array_bytes(@physical_stream_names))
      bytes = checked_add(bytes, string_array_bytes(@selected_checksum_names))
      if plan = @plan
        bytes = checked_add(bytes, plan.retained_workspace_bytes)
        context = @context || raise(CorruptPartError.new("Compact recursive JSON physical context is missing"))
        bytes = checked_add(bytes, context.retained_workspace_bytes)
        bytes = checked_add(bytes, context.retained_grid_workspace_bytes)
        bytes = checked_add(bytes, instance_sizeof(CompactSerializationProfile).to_u64)
      end
      if reader = @root_reader
        bytes = checked_add(bytes, reader.retained_workspace_bytes)
      end
      if state = @prepared_state
        bytes = checked_add(bytes, prepared_state_workspace_bytes(state))
      end
      bytes
    end

    # Always prepares the complete selected physical grid, including an empty
    # read at EOF. No ObjectDocument or BinaryValue is decoded here.
    def validate_complete_schedule(observer : Proc(UInt64, Nil)? = nil) : Nil
      workspace_observer = observer || no_workspace_observer
      budget = request_budget
      if reader = @root_reader
        outer = outer_workspace_without_root_delegate(reader)
        delegate_observer = ->(workspace : UInt64) do
          workspace_observer.call(checked_add(outer, workspace))
          nil
        end
        reader.read_marks_with_budget(0, 0, budget, delegate_observer)
      else
        prepare_recursive_state!(budget, workspace_observer)
      end
      nil
    end

    def storage_value_shape_for_mark(mark_index : Int) : StorageValueShape
      unless mark_index >= 0 && mark_index < @mark_count
        raise ArgumentError.new("Compact recursive JSON shape mark is outside the physical grid")
      end
      if @schema.object?
        # The root delegate owns the same whole-grid preparation gate as its
        # direct reader; shape inspection must not certify an unprepared grid.
        validate_complete_schedule
        return simple_shape(@mark_row_counts[mark_index])
      end
      budget = request_budget
      if @prepared_state.try(&.budget.same?(budget))
        state = @prepared_state.not_nil!
      else
        # Do not retain an operation-owned prepared state while rebuilding it
        # for a different explicit request budget.
        @prepared_state = nil
        prepare_recursive_state!(budget, no_workspace_observer)
        state = @prepared_state
      end
      prepared = state || raise(CorruptPartError.new("Compact recursive JSON occurrence grid was not prepared"))
      shape_for_domain(@schema, "root", mark_index, @mark_row_counts[mark_index], prepared)
    end

    def read_marks(
      first_mark : Int,
      mark_count : Int,
      workspace_observer : Proc(UInt64, Nil)? = nil,
    ) : Array(Array(StorageColumnValue))
      validate_selection!(first_mark, mark_count)
      observer = workspace_observer || no_workspace_observer
      budget = request_budget
      if reader = @root_reader
        charge_selected_shape!(first_mark, mark_count, budget)
        read_root_marks(reader, first_mark, mark_count, budget, observer)
      else
        # Authenticate and prepare the complete physical parent grid while the
        # caller's observer is active, before charging or decoding its output.
        state = prepared_state_for!(budget, observer)
        charge_selected_shape!(first_mark, mark_count, budget)
        observer.call(retained_workspace_bytes)
        decode_recursive_marks(state, first_mark, mark_count, budget, observer)
      end
    end

    private def initialize_root_delegate!(codec_budget : BinaryCodecBudget?) : OpenMetadata
      reader = CompactStaticJsonBulkColumnReader.open(
        @part_path,
        @column_name,
        @type,
        @limits,
        @transport_limits,
        codec_budget,
        @transport_budget,
      )
      unless reader.schema_declaration == @schema_declaration
        raise CorruptPartError.new("Compact root JSON delegate schema differs from its recursive reader")
      end
      @root_reader = reader
      @context = nil
      @serialization_profile = nil
      @plan = nil
      OpenMetadata.new(
        reader.row_count,
        reader.mark_count,
        reader.mark_row_counts,
        reader.source_declaration,
        reader.ordinary_profile,
        reader.physical_stream_names,
        reader.selected_checksum_names,
        reader.logical_read_bytes,
      )
    end

    private def initialize_recursive_source!(open_budget : BinaryCodecBudget) : OpenMetadata
      context = CompactPartPhysicalContext.open(@part_path, @transport_budget)
      unless context.mode.mrk3? || context.mode.mrk4?
        raise UnsupportedFormatError.new("Compact recursive JSON reader requires plain mrk3 or mrk4 marks")
      end
      if context.row_count == 0_u64 || context.row_count > WidePartTable::MAX_TOTAL_ROWS
        raise CorruptPartError.new("Compact recursive JSON row count is outside the typed reader bound")
      end

      physical_columns = context.columns
      source_type = physical_columns.find { |name, _type| name == @column_name }.try(&.[1])
      unless source_type == @schema_declaration
        raise CorruptPartError.new("Compact recursive JSON declaration differs from columns.txt")
      end
      serialization_profile = CompactSerializationProfile.open(
        @part_path,
        physical_columns,
        @column_name,
        @type,
        context.row_count,
        @transport_budget,
      )
      plan = CompactRecursiveJsonSchemaPlan.new(
        @schema,
        @column_name,
        @limits,
        open_budget,
        serialization_profile.ordinary_profile,
      )

      slots = context.physical_roster.select { |slot| slot.column_name == @column_name }
      if slots.empty?
        raise CorruptPartError.new("Compact recursive JSON column has no physical callback slots")
      end
      stream_names = if context.mode.mrk4?
                       names = slots.map do |slot|
                         slot.stream_name || raise(CorruptPartError.new("Compact mrk4 recursive JSON callback has no stream name"))
                       end
                       seen = Set(String).new
                       names.each do |name|
                         unless seen.add?(name)
                           raise CorruptPartError.new("Compact recursive JSON physical callback roster is duplicated")
                         end
                       end
                       copy_strings(names)
                     else
                       unless slots.size == 1 && slots[0].stream_name.nil?
                         raise CorruptPartError.new("Compact mrk3 recursive JSON column is not one unlabelled parent tape")
                       end
                       [] of String
                     end

      rows = context.mark_row_counts
      if rows.empty? || rows.size > WidePartTable::MAX_MARKS_PER_READER
        raise CorruptPartError.new("Compact recursive JSON mark count is outside the reader bound")
      end
      total_rows = 0_u64
      rows.each do |count|
        if count == 0_u64 || count > WidePartTable::MAX_MARK_ROWS ||
           count > WidePartTable::MAX_TOTAL_ROWS - total_rows
          raise CorruptPartError.new("Compact recursive JSON mark rows are outside the reader bound")
        end
        total_rows += count
      end
      unless total_rows == context.row_count
        raise CorruptPartError.new("Compact recursive JSON mark grid differs from its part row count")
      end

      @context = context
      @serialization_profile = serialization_profile
      @plan = plan
      OpenMetadata.new(
        context.row_count,
        rows.size.to_i32,
        rows,
        String.new(source_type.not_nil!.to_slice),
        serialization_profile.ordinary_profile,
        stream_names,
        ["data.bin", context.marks_name],
        context.logical_bytes_for(@column_name),
      )
    end

    private def read_root_marks(
      reader : CompactStaticJsonBulkColumnReader,
      first_mark : Int,
      mark_count : Int,
      budget : BinaryCodecBudget,
      observer : Proc(UInt64, Nil),
    ) : Array(Array(StorageColumnValue))
      shape = simple_shape(selected_rows(first_mark, mark_count).sum(0_u64))
      reservation = output_grid_shell_bytes(first_mark, mark_count)
      outer = outer_workspace_without_root_delegate(reader)
      delegate_observer = ->(workspace : UInt64) do
        observer.call(checked_add(outer, checked_add(workspace, checked_add(shape.bytes, reservation))))
        nil
      end
      documents = reader.read_marks_with_budget(first_mark, mark_count, budget, delegate_observer)
      unless documents.size == mark_count
        raise CorruptPartError.new("Compact root JSON delegate returned the wrong mark count")
      end
      documents.each_with_index do |mark_documents, index|
        unless mark_documents.size.to_u64 == @mark_row_counts[first_mark + index]
          raise CorruptPartError.new("Compact root JSON delegate returned the wrong physical mark row count")
        end
      end
      output = Array(Array(StorageColumnValue)).new(mark_count)
      documents.each do |mark_documents|
        row_values = Array(StorageColumnValue).new(mark_documents.size)
        mark_documents.each { |document| row_values << StorageColumnValue.object_document(document) }
        output << row_values
      end
      observer.call(checked_add(
        retained_workspace_bytes,
        checked_add(reservation, checked_add(shape.bytes, documents_grid_workspace_bytes(documents))),
      ))
      output
    end

    private def prepared_state_for!(
      budget : BinaryCodecBudget,
      observer : Proc(UInt64, Nil),
    ) : PreparedState
      if @prepared_state.try(&.budget.same?(budget))
        return @prepared_state.not_nil!
      end
      @prepared_state = nil
      prepare_recursive_state!(budget, observer)
      @prepared_state || raise(CorruptPartError.new("Compact recursive JSON preparation did not publish its complete source state"))
    end

    private def prepare_recursive_state!(
      budget : BinaryCodecBudget,
      observer : Proc(UInt64, Nil),
    ) : Nil
      if @prepared_state.try(&.budget.same?(budget))
        return nil
      end
      # A prepared source is operation-budget-owned. Release the stale source
      # before any observer reports the new operation's live owners.
      @prepared_state = nil
      context = @context || raise(CorruptPartError.new("Compact recursive JSON physical context is missing"))
      plan = @plan || raise(CorruptPartError.new("Compact recursive JSON schema plan is missing"))
      observer.call(checked_add(retained_workspace_bytes_without_prepared, @logical_read_bytes))
      window = context.read_window(@column_name, 0, @mark_count)
      granules = window.granules
      unless granules.size == @mark_count
        raise CorruptPartError.new("Compact recursive JSON physical window has the wrong mark count")
      end
      physical_workspace = physical_window_workspace_bytes
      observer.call(checked_add(retained_workspace_bytes_without_prepared, physical_workspace))

      json_sites = plan.json_sites
      array_sites = plan.array_sites
      uint8_sites = plan.uint8_sites
      bulk_sites = plan.bulk_sites
      object_marks = Hash(String, Array(PreparedObjectMark)).new(initial_capacity: json_sites.size)
      json_sites.each { |site| object_marks[site.key] = Array(PreparedObjectMark).new(@mark_count) }
      uint8_bytes = Hash(String, Array(Bytes)).new(initial_capacity: uint8_sites.size)
      uint8_sites.each { |site| uint8_bytes[site.key] = Array(Bytes).new(@mark_count) }
      bulk_values = Hash(String, Array(Array(BinaryValue))).new(initial_capacity: bulk_sites.size)
      bulk_sites.each { |site| bulk_values[site.key] = Array(Array(BinaryValue)).new(@mark_count) }
      array_sizes = Hash(String, Array(Array(UInt64))).new(initial_capacity: array_sites.size)
      array_sites.each { |site| array_sizes[site.key] = Array(Array(UInt64)).new(@mark_count) }
      array_parent_rows = Hash(String, Array(UInt64)).new(initial_capacity: array_sites.size)
      array_sites.each { |site| array_parent_rows[site.key] = Array(UInt64).new(@mark_count) }
      frozen_events = nil.as(Array(String)?)
      typed_schemas = Hash(String, Hash(String, BinaryDataType)).new

      granules.each_with_index do |granule, mark_index|
        unless granule.mark == mark_index && granule.row_count == @mark_row_counts[mark_index]
          raise CorruptPartError.new("Compact recursive JSON physical window differs from its complete P grid")
        end
        ledger = CompactRecursiveJsonParentMarkLedger.new(context, @column_name, granule, budget)
        captures = Hash(String, PrefixCapture).new(initial_capacity: json_sites.size)
        prefixes = Hash(String, Array(String)).new(initial_capacity: json_sites.size)

        json_sites.each do |site|
          source = ledger.site_source(site.key)
          observed_offsets = Hash(String, Int32).new
          stats_observer = ->(name : String, offset : Int32) do
            if previous = observed_offsets[name]?
              unless previous == offset
                raise CorruptPartError.new("Compact recursive JSON statistics offset changed within one prefix")
              end
            else
              observed_offsets[String.new(name.to_slice)] = offset
            end
            nil
          end
          nested_context = ObjectSharedNestedSerializationContext.for_read(0_u64, @ordinary_profile)
          prefix = ObjectDocumentCallbackPrefixReader.read_static_json_prefix(
            source,
            site.descriptor,
            site.descriptor_depth,
            site.physical_prefix,
            site.callback_prefix,
            site.array_level,
            nested_context,
            budget,
            true,
            stats_observer,
          )
          physical_plan = ObjectDocumentPhysicalPlan.from_escaped_prefix(
            site.physical_prefix,
            prefix.plan,
            @ordinary_profile,
            BinaryBulkProfile.single_stream,
            @limits,
            site.array_level,
            typed_descriptor_root_depth: prefix.typed_descriptor_root_depth,
            inferred_actual_root_depth: prefix.inferred_actual_root_depth,
            root_dynamic_json_budget: budget,
          )
          prefix.bind_physical_plan!(physical_plan)
          unless prefix.plan.root_dynamic_json_object_leaf_plans(budget).empty?
            raise UnsupportedFormatError.new("Compact recursive root-Dynamic JSON sites are outside this capture slice")
          end
          schedule = CompactJsonObjectRoleSchedule.build(prefix, physical_plan, @ordinary_profile, budget)
          prefixes[site.key] = schedule.prefix_events.map { |_owner, _canonical, callback| String.new(callback.to_slice) }
          source.begin_body_capture!
          captures[site.key] = PrefixCapture.new(
            site,
            prefix,
            physical_plan,
            schedule,
            source,
            observed_offsets,
          )
        end

        ledger.finish_prefixes!
        expected_size_lanes = array_sites.size.to_u64
        bulk_sites.each do |site|
          expected_size_lanes = checked_add(expected_size_lanes, site.size_lane_count.to_u64)
        end
        if expected_size_lanes > Int32::MAX.to_u64
          raise CorruptPartError.new("Compact recursive mixed Array-size schedule exceeds Int32")
        end
        ledger.begin_mixed_body_schedule!(expected_size_lanes.to_i32)
        mark_sizes = Hash(String, Array(UInt64)).new(initial_capacity: array_sites.size)
        mark_parent_rows = Hash(String, UInt64).new(initial_capacity: array_sites.size)
        mark_bulk_streams = Hash(String, BinaryBulkStreams).new(initial_capacity: bulk_sites.size)
        capture_body_traversal(
          @schema,
          "root",
          granule.row_count,
          captures,
          uint8_bytes,
          array_sizes,
          array_parent_rows,
          mark_sizes,
          mark_parent_rows,
          mark_bulk_streams,
          ledger,
          budget,
        )
        site_rows = plan.mark_site_rows(granule.row_count, mark_sizes)
        array_sites.each do |site|
          captured_parent_rows = mark_parent_rows[site.key]? ||
                                 raise(CorruptPartError.new("Compact recursive Array traversal omitted its inherited Q domain"))
          planned_parent_rows = site_rows[site.key]? ||
                                raise(CorruptPartError.new("Compact recursive Array plan omitted its inherited Q domain"))
          unless captured_parent_rows == planned_parent_rows
            raise CorruptPartError.new("Compact recursive Array traversal differs from its inherited Q row domain")
          end
        end
        schedules = Hash(String, CompactJsonObjectRoleSchedule).new(initial_capacity: captures.size)
        captures.each { |key, capture| schedules[key] = capture.schedule }
        expected_events = plan.expected_event_names(prefixes, schedules)
        if frozen = frozen_events
          unless frozen == expected_events
            raise CorruptPartError.new("Compact recursive JSON callback schedule changed between parent marks")
          end
        else
          frozen_events = copy_strings(expected_events)
        end
        physical_events = if ledger.mode.mrk4?
                            physical_callback_names(expected_events, schedules, array_sites, uint8_sites, bulk_sites, budget)
                          else
                            expected_events
                          end
        ledger.finish_mark!(physical_events)

        # Opaque BinaryBulk children are decoded only after the shared parent
        # cursor has authenticated its exact complete mark schedule.
        bulk_sites.each do |site|
          streams = mark_bulk_streams[site.key]? ||
                    raise(CorruptPartError.new("Compact recursive Bulk site has no complete parent capture"))
          rows = site_rows[site.key]? ||
                 raise(CorruptPartError.new("Compact recursive Bulk site has no inherited Q row count"))
          observer.call(bulk_decode_workspace_bytes(
            physical_workspace,
            ledger,
            object_marks,
            uint8_bytes,
            bulk_values,
            array_sizes,
            array_parent_rows,
            mark_bulk_streams,
          ))
          decoded = BinaryBulkCodec.decode_with_budget(
            site.type,
            streams,
            [rows] of UInt64,
            budget,
            first_mark: 0,
            mark_count: 1,
            profile: site.physical_plan.profile,
          )
          unless decoded.size == 1 && decoded[0].size.to_u64 == rows
            raise CorruptPartError.new("Compact recursive Bulk decoder returned the wrong inherited Q grid")
          end
          bulk_values[site.key] << decoded[0]
          observer.call(bulk_decode_workspace_bytes(
            physical_workspace,
            ledger,
            object_marks,
            uint8_bytes,
            bulk_values,
            array_sizes,
            array_parent_rows,
            mark_bulk_streams,
          ))
        end
        mark_bulk_streams.clear

        # Only after the entire parent mark has completed may any noncontiguous
        # child Object site publish streams or an Advanced prepared owner.
        json_sites.each do |site|
          capture = captures[site.key]? ||
                    raise(CorruptPartError.new("Compact recursive JSON prefix capture is missing from its parent ledger"))
          rows = site_rows[site.key]? ||
                 raise(CorruptPartError.new("Compact recursive JSON site has no inherited Q row count"))
          grid = StorageOccurrenceGrid.new(
            [granule.row_count] of UInt64,
            [rows] of UInt64,
            budget,
          )
          stats = Hash(String, Int32).new(initial_capacity: capture.statistics_offsets.size + 1)
          capture.statistics_offsets.each { |name, offset| stats[name] = offset }
          object_callback = PhysicalStreamName.append_literal(site.callback_prefix, ".object_structure")
          stats[object_callback] = capture.prefix.object_structure_statistics_offset
          typed_json_context = ObjectDocumentTypedDynamicJsonReadContext.from_prefix(capture.prefix, budget)
          object_mark = if capture.schedule.advanced
                          owner_observer = ->(owner_bytes : UInt64) do
                            active = checked_add(retained_workspace_bytes_without_prepared, physical_workspace)
                            active = checked_add(active, ledger.retained_workspace_bytes)
                            active = checked_add(
                              active,
                              local_prepared_workspace_bytes(object_marks, uint8_bytes, bulk_values, array_sizes, array_parent_rows),
                            )
                            if current_context = typed_json_context
                              active = checked_add(active, current_context.retained_workspace_bytes)
                            end
                            observer.call(checked_add(active, owner_bytes))
                            nil
                          end
                          advanced = CompactStaticJsonAdvancedPreparedMark.prepare_from_source(
                            capture.prefix,
                            capture.physical_plan,
                            grid,
                            budget,
                            capture.schedule.body_bindings,
                            capture.schedule.body_pairs,
                            stats,
                            @ordinary_profile,
                            capture.source,
                            owner_observer,
                            capture.schedule,
                          )
                          unless advanced.logical_row_count == rows
                            raise CorruptPartError.new("Compact recursive Advanced Object owner returned the wrong Q grid")
                          end
                          typed = capture.prefix.typed_schema_for(budget)
                          previous = typed_schemas[site.key]?
                          if previous && !same_typed_schema?(previous, typed)
                            raise CorruptPartError.new("Compact recursive Object typed schema changed between marks")
                          end
                          typed_schemas[site.key] ||= typed
                          PreparedObjectMark.new(
                            typed,
                            nil,
                            advanced,
                            grid,
                            rows,
                            capture.prefix.typed_descriptor_root_depth,
                            capture.prefix.inferred_actual_root_depth,
                            typed_json_context,
                          )
                        else
                          capture.source.validate_prepared_source!(
                            capture.prefix,
                            capture.physical_plan,
                            capture.schedule.body_bindings,
                            capture.schedule.body_pairs,
                            budget,
                            capture.schedule,
                          )
                          streams = ObjectDocumentCallbackBodyMaterializer.materialize(
                            capture.prefix,
                            capture.physical_plan,
                            grid,
                            budget,
                            capture.schedule.body_bindings,
                            capture.schedule.body_pairs,
                            stats,
                          )
                          unless streams.mark_count == 1 && streams.row_count_at(0) == rows
                            raise CorruptPartError.new("Compact recursive Object materializer returned the wrong Q grid")
                          end
                          typed = capture.prefix.typed_schema_for(budget)
                          previous = typed_schemas[site.key]?
                          if previous && !same_typed_schema?(previous, typed)
                            raise CorruptPartError.new("Compact recursive Object typed schema changed between marks")
                          end
                          typed_schemas[site.key] ||= typed
                          PreparedObjectMark.new(
                            typed,
                            streams,
                            nil,
                            grid,
                            rows,
                            capture.prefix.typed_descriptor_root_depth,
                            capture.prefix.inferred_actual_root_depth,
                            typed_json_context,
                          )
                        end
          object_marks[site.key] << object_mark
        end

        ledger_workspace = ledger.retained_workspace_bytes
        observer.call(checked_add(
          checked_add(retained_workspace_bytes_without_prepared, physical_workspace),
          checked_add(
            ledger_workspace,
            local_prepared_workspace_bytes(object_marks, uint8_bytes, bulk_values, array_sizes, array_parent_rows),
          ),
        ))
      end

      frames = Hash(String, StorageArrayOccurrenceFrame).new(initial_capacity: array_sites.size)
      array_sites.each do |site|
        frames[site.key] = StorageArrayOccurrenceFrame.for_read(
          site.array_level,
          @mark_row_counts,
          array_parent_rows[site.key]? || raise(CorruptPartError.new("Compact recursive Array has no complete parent Q grid")),
          array_sizes[site.key],
          budget,
        )
      end
      state = PreparedState.new(budget, object_marks, uint8_bytes, bulk_values, frames)
      observer.call(checked_add(retained_workspace_bytes_without_prepared, prepared_state_workspace_bytes(state)))
      @prepared_state = state
      nil
    end

    private def capture_body_traversal(
      schema : StorageColumnSchema,
      key : String,
      rows : UInt64,
      captures : Hash(String, PrefixCapture),
      uint8_bytes : Hash(String, Array(Bytes)),
      array_sizes : Hash(String, Array(Array(UInt64))),
      array_parent_rows : Hash(String, Array(UInt64)),
      mark_sizes : Hash(String, Array(UInt64)),
      mark_parent_rows : Hash(String, UInt64),
      mark_bulk_streams : Hash(String, BinaryBulkStreams),
      ledger : CompactRecursiveJsonParentMarkLedger,
      budget : BinaryCodecBudget,
    ) : Nil
      if schema.object?
        capture = captures[key]? || raise(CorruptPartError.new("Compact recursive Object site is absent from its parent prefix phase"))
        prefix = capture.prefix
        source = capture.source
        capture.schedule.begin_body_capture!(budget)
        if ledger.mode.mrk3?
          CompactJsonObjectMapTapeFramer.capture_body!(
            prefix,
            capture.physical_plan,
            capture.schedule,
            source,
            rows,
            @ordinary_profile,
            @limits,
            budget,
          )
        else
          capture.schedule.capture_physical_body_events!(source, budget)
        end
        capture.schedule.finish_body_capture!(budget)
        source.validate_expected_events!(capture.schedule.event_names)
        source.finish!
      elsif schema.bulk?
        plan = @plan || raise(CorruptPartError.new("Compact recursive schema plan is missing"))
        if schema.bulk_type.tag == BinaryDataType::TAG_UINT8
          site = plan.uint8_site(key)
          byte_count = checked_byte_count(rows, 1_u64, "Compact recursive UInt8 lane")
          budget.ensure_wire_bytes(byte_count.to_u64)
          captured = ledger.capture_uint8_body(site.callback_name, byte_count)
          owned = Bytes.new(captured.size)
          captured.copy_to(owned)
          uint8_bytes[key] << owned
        else
          site = plan.bulk_site(key)
          mark_bulk_streams[key] = capture_bulk_site_streams(site, rows, ledger, budget)
        end
      elsif schema.array?
        plan = @plan || raise(CorruptPartError.new("Compact recursive schema plan is missing"))
        site = plan.array_site(key)
        byte_count = checked_byte_count(rows, 8_u64, "Compact recursive Array size lane")
        budget.ensure_wire_bytes(byte_count.to_u64)
        budget.ensure_future_nodes(rows)
        budget.ensure_future_elements(rows)
        lane = ledger.capture_mixed_array_size_lane(site.callback_name, byte_count)
        sizes = decode_uint64_lane(lane, rows, "Compact recursive Array size lane", budget)
        mark_sizes[key] = sizes
        mark_parent_rows[key] = rows
        (array_sizes[key]? || raise(CorruptPartError.new("Compact recursive Array schedule is missing its owner"))) << sizes
        (array_parent_rows[key]? || raise(CorruptPartError.new("Compact recursive Array parent schedule is missing its owner"))) << rows
        child_rows = checked_child_rows(sizes, "Compact recursive Array child occurrence count")
        capture_body_traversal(
          schema.child_at(0),
          array_child_key(key),
          child_rows,
          captures,
          uint8_bytes,
          array_sizes,
          array_parent_rows,
          mark_sizes,
          mark_parent_rows,
          mark_bulk_streams,
          ledger,
          budget,
        )
      elsif schema.tuple?
        schema.child_count.times do |index|
          capture_body_traversal(
            schema.child_at(index),
            tuple_child_key(key, index),
            rows,
            captures,
            uint8_bytes,
            array_sizes,
            array_parent_rows,
            mark_sizes,
            mark_parent_rows,
            mark_bulk_streams,
            ledger,
            budget,
          )
        end
      else
        raise UnsupportedFormatError.new("Compact recursive JSON schema contains an unsupported body node")
      end
      nil
    end

    private def capture_bulk_site_streams(
      site : CompactRecursiveJsonBulkSite,
      rows : UInt64,
      ledger : CompactRecursiveJsonParentMarkLedger,
      budget : BinaryCodecBudget,
    ) : BinaryBulkStreams
      mark = CompactRecursiveJsonBulkMark.open(site, budget)
      capture_bulk_type!(site.type, "root", rows, site, mark, ledger, budget)
      mark.build_streams(budget)
    end

    private def capture_bulk_type!(
      type : BinaryDataType,
      role_name : String,
      rows : UInt64,
      site : CompactRecursiveJsonBulkSite,
      mark : CompactRecursiveJsonBulkMark,
      ledger : CompactRecursiveJsonParentMarkLedger,
      budget : BinaryCodecBudget,
    ) : Nil
      CompactRecursiveJsonStaticBulkGrammar.capture!(
        type,
        role_name,
        rows,
        site,
        mark,
        ledger,
        @limits,
        budget,
      )
    end

    private def checked_child_rows(sizes : Array(UInt64), label : String) : UInt64
      children = 0_u64
      sizes.each do |size|
        if size > Int32::MAX.to_u64 || children > UInt64::MAX - size
          raise CorruptPartError.new("#{label} exceeds its supported domain")
        end
        children += size
      end
      if children > Int32::MAX.to_u64
        raise CorruptPartError.new("#{label} exceeds Int32")
      end
      children
    end

    private def decode_recursive_marks(
      state : PreparedState,
      first_mark : Int,
      mark_count : Int,
      budget : BinaryCodecBudget,
      observer : Proc(UInt64, Nil),
    ) : Array(Array(StorageColumnValue))
      unless state.budget.same?(budget)
        raise ArgumentError.new("Compact recursive JSON prepared sources require their exact budget operation")
      end
      output = Array(Array(StorageColumnValue)).new(mark_count)
      observer.call(checked_add(retained_workspace_bytes, output_workspace_bytes(output)))
      plan = @plan || raise(CorruptPartError.new("Compact recursive schema plan is missing"))
      object_sites = plan.json_sites
      uint8_sites = plan.uint8_sites
      bulk_sites = plan.bulk_sites
      mark_count.times do |selection_index|
        mark = first_mark + selection_index
        object_rows = Hash(String, Array(ObjectDocument)).new(initial_capacity: object_sites.size)
        bulk_rows = Hash(String, Array(BinaryValue)).new(initial_capacity: object_sites.size + uint8_sites.size + bulk_sites.size)
        object_sites.each do |site|
          site_marks = state.object_marks[site.key]? ||
                       raise(CorruptPartError.new("Compact recursive Object site has no prepared mark grid"))
          prepared = site_marks[mark]? ||
                     raise(CorruptPartError.new("Compact recursive Object site has no prepared owner for this mark"))
          unless prepared.rows == occurrence_rows(@schema, "root", mark, @mark_row_counts[mark], site.key, state)
            raise CorruptPartError.new("Compact recursive Object prepared owner differs from its inherited Q grid")
          end
          documents = if advanced = prepared.advanced
                        advanced.decode_with_budget(budget, ->(owner_bytes : UInt64) do
                          active = output_workspace_bytes(output)
                          active = checked_add(active, output_shape_workspace_bytes(first_mark, output.size, state))
                          active = checked_add(active, output_leaf_workspace_bytes(output))
                          active = checked_add(active, decoded_leaf_workspace_bytes(object_rows, bulk_rows))
                          active = checked_add(active, decoded_site_leaf_workspace_bytes(object_rows, bulk_rows))
                          owner_retained = advanced.retained_workspace_bytes
                          owner_transient = owner_bytes >= owner_retained ? owner_bytes - owner_retained : 0_u64
                          observer.call(checked_add(retained_workspace_bytes, checked_add(active, owner_transient)))
                          nil
                        end)
                      else
                        streams = prepared.streams || raise(CorruptPartError.new("Compact recursive Object map streams are missing"))
                        decoded = ObjectDocumentCodec.decode_child_site_with_budget(
                          prepared.typed_schema,
                          streams,
                          prepared.grid,
                          budget,
                          first_mark: 0,
                          mark_count: 1,
                          profile: @ordinary_profile,
                          shared_profile: BinaryBulkProfile.single_stream,
                          typed_descriptor_root_depth: prepared.typed_descriptor_root_depth,
                          inferred_actual_root_depth: prepared.inferred_actual_root_depth,
                          typed_dynamic_json_read_context: prepared.typed_json_context,
                        )
                        unless decoded.size == 1
                          raise CorruptPartError.new("Compact recursive Object codec returned the wrong mark count")
                        end
                        decoded[0]
                      end
          unless documents.size.to_u64 == prepared.rows
            raise CorruptPartError.new("Compact recursive Object codec returned the wrong Q row count")
          end
          object_rows[site.key] = documents
          observe_partial_decode_workspace!(observer, first_mark, output, object_rows, bulk_rows, state)
        end

        uint8_sites.each do |site|
          rows = occurrence_rows(@schema, "root", mark, @mark_row_counts[mark], site.key, state)
          site_marks = state.uint8_bytes[site.key]? ||
                       raise(CorruptPartError.new("Compact recursive UInt8 site has no mark grid"))
          bytes = site_marks[mark]? ||
                  raise(CorruptPartError.new("Compact recursive UInt8 body bytes are missing for this mark"))
          unless bytes.size.to_u64 == rows
            raise CorruptPartError.new("Compact recursive UInt8 body differs from its complete Q grid")
          end
          stream = BinaryBulkStream.new(bytes, [0_u64, rows])
          streams = BinaryBulkStreams.new(1, {"root.data" => stream})
          decoded = BinaryBulkCodec.decode_with_budget(
            site.type,
            streams,
            [rows] of UInt64,
            budget,
            first_mark: 0,
            mark_count: 1,
            profile: @ordinary_profile,
          )
          unless decoded.size == 1 && decoded[0].size.to_u64 == rows
            raise CorruptPartError.new("Compact recursive UInt8 decoder returned the wrong Q grid")
          end
          bulk_rows[site.key] = decoded[0]
          observe_partial_decode_workspace!(observer, first_mark, output, object_rows, bulk_rows, state)
        end

        bulk_sites.each do |site|
          rows = occurrence_rows(@schema, "root", mark, @mark_row_counts[mark], site.key, state)
          site_marks = state.bulk_values[site.key]? ||
                       raise(CorruptPartError.new("Compact recursive Bulk site has no decoded mark grid"))
          values = site_marks[mark]? ||
                   raise(CorruptPartError.new("Compact recursive Bulk site has no value rows for this mark"))
          unless values.size.to_u64 == rows
            raise(CorruptPartError.new("Compact recursive Bulk values differ from their inherited Q grid"))
          end
          bulk_rows[site.key] = values
          observe_partial_decode_workspace!(observer, first_mark, output, object_rows, bulk_rows, state)
        end

        row_count = @mark_row_counts[mark]
        if row_count > Int32::MAX.to_u64
          raise CorruptPartError.new("Compact recursive parent mark exceeds the supported row domain")
        end
        row_values = Array(StorageColumnValue).new(row_count.to_i)
        array_parent_cursors = Hash(String, Int32).new(0)
        array_child_cursors = Hash(String, Int32).new(0)
        row_count.to_i.times do |row_index|
          value = assemble_value(
            @schema,
            "root",
            row_index,
            mark,
            object_rows,
            bulk_rows,
            array_parent_cursors,
            array_child_cursors,
            state,
          )
          StorageColumnDepthGuard.validate(value, @limits, false)
          row_values << value
        end
        validate_assembled_array_cursors!(mark, array_parent_cursors, array_child_cursors, state)
        output << row_values
        observer.call(checked_add(
          retained_workspace_bytes,
          checked_add(
            output_workspace_bytes(output),
            checked_add(
              output_shape_workspace_bytes(first_mark, output.size, state),
              checked_add(
                output_leaf_workspace_bytes(output),
                decoded_leaf_workspace_bytes(object_rows, bulk_rows),
              ),
            ),
          ),
        ))
      end
      output
    end

    private def assemble_value(
      schema : StorageColumnSchema,
      key : String,
      row_index : Int32,
      parent_mark : Int,
      object_rows : Hash(String, Array(ObjectDocument)),
      bulk_rows : Hash(String, Array(BinaryValue)),
      array_parent_cursors : Hash(String, Int32),
      array_child_cursors : Hash(String, Int32),
      state : PreparedState,
    ) : StorageColumnValue
      if schema.object?
        documents = object_rows[key]? || raise(CorruptPartError.new("Compact recursive Object row has no decoded site"))
        return StorageColumnValue.object_document(
          documents[row_index]? || raise(CorruptPartError.new("Compact recursive Object site is missing a row")),
        )
      elsif schema.bulk?
        values = bulk_rows[key]? || raise(CorruptPartError.new("Compact recursive Bulk row has no decoded site"))
        return StorageColumnValue.bulk(values[row_index]? || raise(CorruptPartError.new("Compact recursive Bulk site is missing a row")))
      elsif schema.array?
        frame = state.array_frames[key]? || raise(CorruptPartError.new("Compact recursive Array has no occurrence frame"))
        expected_parent = array_parent_cursors[key]?.try(&.to_i64) || 0_i64
        unless expected_parent == row_index.to_i64
          raise CorruptPartError.new("Compact recursive Array parents are not assembled in source order")
        end
        size = frame.size_at(parent_mark, row_index)
        if size > Int32::MAX.to_u64
          raise CorruptPartError.new("Compact recursive Array size exceeds the supported row domain")
        end
        child_start = array_child_cursors[key]?.try(&.to_i64) || 0_i64
        child_end = child_start + size.to_i64
        if child_end > Int32::MAX
          raise CorruptPartError.new("Compact recursive Array child cursor exceeds the supported row domain")
        end
        array_parent_cursors[key] = (expected_parent + 1_i64).to_i32
        array_child_cursors[key] = child_end.to_i32
        children = Array(StorageColumnValue).new(size.to_i)
        size.to_i.times do |child_index|
          children << assemble_value(
            schema.child_at(0),
            array_child_key(key),
            (child_start + child_index).to_i32,
            parent_mark,
            object_rows,
            bulk_rows,
            array_parent_cursors,
            array_child_cursors,
            state,
          )
        end
        StorageColumnValue.array(children)
      elsif schema.tuple?
        children = Array(StorageColumnValue).new(schema.child_count)
        schema.child_count.times do |index|
          children << assemble_value(
            schema.child_at(index),
            tuple_child_key(key, index),
            row_index,
            parent_mark,
            object_rows,
            bulk_rows,
            array_parent_cursors,
            array_child_cursors,
            state,
          )
        end
        StorageColumnValue.tuple(children)
      else
        raise CorruptPartError.new("Compact recursive JSON schema contains an unknown structural node")
      end
    end

    private def shape_for_domain(
      schema : StorageColumnSchema,
      key : String,
      mark : Int,
      rows : UInt64,
      state : PreparedState,
    ) : StorageValueShape
      node_bytes = checked_add(
        instance_sizeof(StorageColumnValue).to_u64,
        instance_sizeof(Array(StorageColumnValue)).to_u64,
      )
      shape = StorageValueShape.new(rows, 0_u64, 0_u64, checked_multiply(rows, node_bytes))
      if schema.tuple?
        slots = checked_multiply(rows, schema.child_count.to_u64)
        shape = StorageValueShape.new(
          shape.nodes,
          slots,
          slots,
          checked_add(shape.bytes, checked_multiply(slots, sizeof(Pointer(StorageColumnValue)).to_u64)),
        )
        schema.child_count.times do |index|
          shape = add_shapes(shape,
            shape_for_domain(schema.child_at(index), tuple_child_key(key, index), mark, rows, state))
        end
      elsif schema.array?
        frame = state.array_frames[key]? || raise(CorruptPartError.new("Compact recursive Array has no complete occurrence frame"))
        unless frame.parent_count_at(mark) == rows
          raise CorruptPartError.new("Compact recursive Array Q grid differs from its inherited parent rows")
        end
        children = frame.child_count_at(mark)
        shape = StorageValueShape.new(
          shape.nodes,
          shape.tuple_cells,
          checked_add(shape.elements, children),
          checked_add(shape.bytes, checked_multiply(children, sizeof(Pointer(StorageColumnValue)).to_u64)),
        )
        shape = add_shapes(shape,
          shape_for_domain(schema.child_at(0), array_child_key(key), mark, children, state))
      end
      shape
    end

    private def occurrence_rows(
      schema : StorageColumnSchema,
      current_key : String,
      mark : Int,
      rows : UInt64,
      target_key : String,
      state : PreparedState,
    ) : UInt64
      return rows if current_key == target_key
      if schema.tuple?
        schema.child_count.times do |index|
          child = schema.child_at(index)
          child_key = tuple_child_key(current_key, index)
          if target_key == child_key || target_key.starts_with?(child_key + "/")
            return occurrence_rows(child, child_key, mark, rows, target_key, state)
          end
        end
      elsif schema.array?
        child_key = array_child_key(current_key)
        if target_key == child_key || target_key.starts_with?(child_key + "/")
          frame = state.array_frames[current_key]? || raise(CorruptPartError.new("Compact recursive Array has no complete occurrence frame"))
          return occurrence_rows(schema.child_at(0), child_key, mark, frame.child_count_at(mark), target_key, state)
        end
      end
      raise CorruptPartError.new("Compact recursive site key is not in its schema topology")
    end

    private def validate_assembled_array_cursors!(
      mark : Int,
      parents : Hash(String, Int32),
      children : Hash(String, Int32),
      state : PreparedState,
    ) : Nil
      (@plan || raise(CorruptPartError.new("Compact recursive schema plan is missing"))).array_sites.each do |site|
        frame = state.array_frames[site.key]? || raise(CorruptPartError.new("Compact recursive Array frame is missing"))
        actual_parents = parents[site.key]?.try(&.to_u64) || 0_u64
        actual_children = children[site.key]?.try(&.to_u64) || 0_u64
        unless actual_parents == frame.parent_count_at(mark) && actual_children == frame.child_count_at(mark)
          raise CorruptPartError.new("Compact recursive Array reconstruction differs from its complete Q/C frame")
        end
      end
      nil
    end

    private def charge_selected_shape!(first_mark : Int, mark_count : Int, budget : BinaryCodecBudget) : Nil
      return if mark_count == 0
      if @schema.object?
        total_nodes = selected_rows(first_mark, mark_count).sum(0_u64)
        budget.ensure_future_nodes(total_nodes)
        budget.ensure_future_elements(0_u64)
        total_nodes.times { budget.charge_node }
        return
      end
      unless @prepared_state.try(&.budget.same?(budget))
        @prepared_state = nil
        prepare_recursive_state!(budget, no_workspace_observer)
      end
      state = @prepared_state || raise(CorruptPartError.new("Compact recursive shape preflight has no authenticated grids"))
      total = StorageValueShape.new(0_u64, 0_u64, 0_u64, 0_u64)
      mark_count.times do |index|
        total = add_shapes(total, shape_for_domain(@schema, "root", first_mark + index, @mark_row_counts[first_mark + index], state))
      end
      budget.ensure_future_nodes(total.nodes)
      budget.ensure_future_elements(total.elements)
      budget.charge_elements(total.elements) if total.elements > 0_u64
      remaining = total.nodes
      while remaining > 0_u64
        budget.charge_node
        remaining -= 1_u64
      end
      nil
    end

    private def simple_shape(rows : UInt64) : StorageValueShape
      node_bytes = checked_add(
        instance_sizeof(StorageColumnValue).to_u64,
        instance_sizeof(Array(StorageColumnValue)).to_u64,
      )
      StorageValueShape.new(rows, 0_u64, 0_u64, checked_multiply(rows, node_bytes))
    end

    private def add_shapes(left : StorageValueShape, right : StorageValueShape) : StorageValueShape
      StorageValueShape.new(
        checked_add(left.nodes, right.nodes),
        checked_add(left.tuple_cells, right.tuple_cells),
        checked_add(left.elements, right.elements),
        checked_add(left.bytes, right.bytes),
      )
    end

    private def selected_rows(first_mark : Int, mark_count : Int) : Array(UInt64)
      Array(UInt64).new(mark_count) { |index| @mark_row_counts[first_mark + index] }
    end

    private def output_grid_shell_bytes(first_mark : Int, mark_count : Int) : UInt64
      rows = selected_rows(first_mark, mark_count).sum(0_u64)
      bytes = instance_sizeof(Array(Array(StorageColumnValue))).to_u64
      bytes = checked_add(bytes, checked_multiply(mark_count.to_u64, sizeof(Pointer(Array(StorageColumnValue))).to_u64))
      bytes = checked_add(bytes, checked_multiply(mark_count.to_u64, instance_sizeof(Array(StorageColumnValue)).to_u64))
      checked_add(bytes, checked_multiply(rows, sizeof(Pointer(StorageColumnValue)).to_u64))
    end

    private def output_workspace_bytes(values : Array(Array(StorageColumnValue))) : UInt64
      bytes = instance_sizeof(Array(Array(StorageColumnValue))).to_u64
      bytes = checked_add(bytes, checked_multiply(values.size.to_u64, sizeof(Pointer(Array(StorageColumnValue))).to_u64))
      values.each do |rows|
        bytes = checked_add(bytes, instance_sizeof(Array(StorageColumnValue)).to_u64)
        bytes = checked_add(bytes, checked_multiply(rows.size.to_u64, sizeof(Pointer(StorageColumnValue)).to_u64))
      end
      bytes
    end

    private def output_shape_workspace_bytes(
      first_mark : Int,
      mark_count : Int,
      state : PreparedState,
    ) : UInt64
      bytes = 0_u64
      mark_count.times do |index|
        mark = first_mark + index
        shape = shape_for_domain(@schema, "root", mark, @mark_row_counts[mark], state)
        bytes = checked_add(bytes, shape.bytes)
      end
      bytes
    end

    private def output_leaf_workspace_bytes(values : Array(Array(StorageColumnValue))) : UInt64
      bytes = 0_u64
      values.each do |rows|
        rows.each { |value| bytes = checked_add(bytes, storage_leaf_workspace_bytes(value)) }
      end
      bytes
    end

    private def storage_leaf_workspace_bytes(value : StorageColumnValue) : UInt64
      if value.object?
        object_document_workspace_bytes(value.object_document)
      elsif value.bulk?
        binary_value_workspace_bytes(value.bulk_value)
      else
        bytes = 0_u64
        value.child_count.times do |index|
          bytes = checked_add(bytes, storage_leaf_workspace_bytes(value.child_at(index)))
        end
        bytes
      end
    end

    private def observe_partial_decode_workspace!(
      observer : Proc(UInt64, Nil),
      first_mark : Int,
      output : Array(Array(StorageColumnValue)),
      objects : Hash(String, Array(ObjectDocument)),
      bulk : Hash(String, Array(BinaryValue)),
      state : PreparedState,
    ) : Nil
      active = output_workspace_bytes(output)
      active = checked_add(active, output_shape_workspace_bytes(first_mark, output.size, state))
      active = checked_add(active, output_leaf_workspace_bytes(output))
      active = checked_add(active, decoded_leaf_workspace_bytes(objects, bulk))
      active = checked_add(active, decoded_site_leaf_workspace_bytes(objects, bulk))
      observer.call(checked_add(retained_workspace_bytes, active))
      nil
    end

    private def decoded_leaf_workspace_bytes(
      objects : Hash(String, Array(ObjectDocument)),
      bulk : Hash(String, Array(BinaryValue)),
    ) : UInt64
      # Temporary per-site value arrays are separate owners from the SCV tree,
      # but their document/BinaryValue leaves are already counted through the
      # assembled output or decoded_site_leaf_workspace_bytes.
      bytes = instance_sizeof(Hash(String, Array(ObjectDocument))).to_u64
      bytes = checked_add(bytes, instance_sizeof(Hash(String, Array(BinaryValue))).to_u64)
      objects.each_value do |documents|
        bytes = checked_add(bytes, instance_sizeof(Array(ObjectDocument)).to_u64)
        bytes = checked_add(bytes, checked_multiply(documents.size.to_u64, sizeof(Pointer(ObjectDocument)).to_u64))
      end
      bulk.each_value do |values|
        bytes = checked_add(bytes, instance_sizeof(Array(BinaryValue)).to_u64)
        bytes = checked_add(bytes, checked_multiply(values.size.to_u64, sizeof(Pointer(BinaryValue)).to_u64))
      end
      bytes
    end

    private def decoded_site_leaf_workspace_bytes(
      objects : Hash(String, Array(ObjectDocument)),
      bulk : Hash(String, Array(BinaryValue)),
    ) : UInt64
      bytes = 0_u64
      objects.each_value do |documents|
        documents.each do |document|
          bytes = checked_add(bytes, object_document_workspace_bytes(document))
        end
      end
      bulk.each_value do |values|
        values.each { |value| bytes = checked_add(bytes, binary_value_workspace_bytes(value)) }
      end
      bytes
    end

    private def object_document_workspace_bytes(document : ObjectDocument) : UInt64
      bytes = instance_sizeof(ObjectDocument).to_u64
      bytes = checked_add(bytes, checked_multiply(document.path_count.to_u64,
        sizeof(Pointer(String)).to_u64 + sizeof(Pointer(BinaryValue)).to_u64))
      document.path_count.times do |index|
        bytes = checked_add(bytes, document.path_byte_size_at(index).to_u64 + 1_u64)
        path = document.path_at(index)
        bytes = checked_add(bytes, binary_value_workspace_bytes(document.value_for(path)))
      end
      bytes
    end

    private def documents_grid_workspace_bytes(marks : Array(Array(ObjectDocument))) : UInt64
      bytes = instance_sizeof(Array(Array(ObjectDocument))).to_u64
      bytes = checked_add(bytes, checked_multiply(marks.size.to_u64, sizeof(Pointer(Array(ObjectDocument))).to_u64))
      marks.each do |documents|
        bytes = checked_add(bytes, instance_sizeof(Array(ObjectDocument)).to_u64)
        bytes = checked_add(bytes, checked_multiply(documents.size.to_u64, sizeof(Pointer(ObjectDocument)).to_u64))
        documents.each do |document|
          bytes = checked_add(bytes, object_document_workspace_bytes(document))
        end
      end
      bytes
    end

    private def documents_workspace_bytes(documents : Array(ObjectDocument)) : UInt64
      bytes = instance_sizeof(Array(ObjectDocument)).to_u64
      bytes = checked_add(bytes, checked_multiply(documents.size.to_u64, sizeof(Pointer(ObjectDocument)).to_u64))
      documents.each do |document|
        bytes = checked_add(bytes, object_document_workspace_bytes(document))
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
          if nested = row.value_at(index)
            bytes = checked_add(bytes, binary_value_workspace_bytes(nested))
          end
        end
      end
      bytes
    end

    private def prepared_state_workspace_bytes(state : PreparedState) : UInt64
      bytes = instance_sizeof(PreparedState).to_u64
      bytes = checked_add(bytes, instance_sizeof(Hash(String, Array(PreparedObjectMark))).to_u64)
      state.object_marks.each do |key, marks|
        bytes = checked_add(bytes, string_owner_bytes(key))
        bytes = checked_add(bytes, instance_sizeof(Array(PreparedObjectMark)).to_u64)
        bytes = checked_add(bytes, checked_multiply(marks.size.to_u64, sizeof(PreparedObjectMark).to_u64))
        marks.each do |mark|
          bytes = checked_add(bytes, object_mark_workspace_bytes(mark))
        end
      end
      bytes = checked_add(bytes, instance_sizeof(Hash(String, Array(Bytes))).to_u64)
      state.uint8_bytes.each do |key, marks|
        bytes = checked_add(bytes, string_owner_bytes(key))
        bytes = checked_add(bytes, instance_sizeof(Array(Bytes)).to_u64)
        bytes = checked_add(bytes, checked_multiply(marks.size.to_u64, sizeof(Bytes).to_u64))
        marks.each { |mark| bytes = checked_add(bytes, sizeof(Bytes).to_u64 + mark.size.to_u64) }
      end
      bytes = checked_add(bytes, instance_sizeof(Hash(String, Array(Array(BinaryValue)))).to_u64)
      state.bulk_values.each do |key, marks|
        bytes = checked_add(bytes, string_owner_bytes(key))
        bytes = checked_add(bytes, instance_sizeof(Array(Array(BinaryValue))).to_u64)
        bytes = checked_add(bytes, checked_multiply(marks.size.to_u64, sizeof(Array(BinaryValue)).to_u64))
        marks.each do |values|
          bytes = checked_add(bytes, instance_sizeof(Array(BinaryValue)).to_u64)
          bytes = checked_add(bytes, checked_multiply(values.size.to_u64, sizeof(Pointer(BinaryValue)).to_u64))
          values.each { |value| bytes = checked_add(bytes, binary_value_workspace_bytes(value)) }
        end
      end
      bytes = checked_add(bytes, instance_sizeof(Hash(String, StorageArrayOccurrenceFrame)).to_u64)
      state.array_frames.each do |key, frame|
        bytes = checked_add(bytes, string_owner_bytes(key))
        bytes = checked_add(bytes, array_frame_workspace_bytes(frame))
      end
      bytes
    end

    private def object_mark_workspace_bytes(mark : PreparedObjectMark) : UInt64
      bytes = sizeof(PreparedObjectMark).to_u64
      bytes = checked_add(bytes, typed_schema_workspace_bytes(mark.typed_schema))
      if typed_json_context = mark.typed_json_context
        bytes = checked_add(bytes, typed_json_context.retained_workspace_bytes)
      end
      if advanced = mark.advanced
        bytes = checked_add(bytes, advanced.retained_workspace_bytes)
      else
        bytes = checked_add(bytes, grid_workspace_bytes(mark.grid))
        streams = mark.streams || raise(CorruptPartError.new("Compact recursive map mark lost its materialized streams"))
        bytes = checked_add(bytes, object_streams_workspace_bytes(streams))
      end
      bytes
    end

    private def typed_schema_workspace_bytes(schema : Hash(String, BinaryDataType)) : UInt64
      bytes = instance_sizeof(Hash(String, BinaryDataType)).to_u64
      schema.each do |path, _type|
        bytes = checked_add(bytes, string_owner_bytes(path))
        bytes = checked_add(bytes, instance_sizeof(BinaryDataType).to_u64)
      end
      bytes
    end

    private def object_streams_workspace_bytes(streams : ObjectDocumentStreams) : UInt64
      bytes = instance_sizeof(ObjectDocumentStreams).to_u64
      bytes = checked_add(bytes, streams.structures.total_input_byte_size)
      streams.typed_path_count.times do |index|
        bytes = checked_add(bytes, binary_streams_workspace_bytes(streams.typed_for(streams.typed_path_at(index))))
      end
      streams.typed_dynamic_path_count.times do |index|
        dynamic = streams.typed_dynamic_for(streams.typed_dynamic_path_at(index))
        bytes = checked_add(bytes, dynamic.structures.total_input_byte_size)
        bytes = checked_add(bytes, binary_streams_workspace_bytes(dynamic.data))
      end
      streams.dynamic_path_count.times do |index|
        dynamic = streams.dynamic_for(streams.dynamic_path_at(index))
        bytes = checked_add(bytes, instance_sizeof(DynamicValueStreams).to_u64)
        bytes = checked_add(bytes, dynamic.discriminators.byte_size.to_u64)
        dynamic.arm_names.each { |name| bytes = checked_add(bytes, binary_streams_workspace_bytes(dynamic.arm(name))) }
      end
      streams.shared_bucket_count.times do |index|
        bytes = checked_add(bytes, binary_streams_workspace_bytes(streams.shared_bucket(index)))
      end
      checked_add(bytes, grid_workspace_bytes_for_stream_rows(streams))
    end

    private def binary_streams_workspace_bytes(streams : BinaryBulkStreams) : UInt64
      bytes = instance_sizeof(BinaryBulkStreams).to_u64
      bytes = checked_add(bytes, streams.total_input_byte_size)
      streams.roles.each do |role|
        stream = streams.stream(role)
        bytes = checked_add(bytes, string_owner_bytes(role))
        bytes = checked_add(bytes, instance_sizeof(BinaryBulkStream).to_u64)
        bytes = checked_add(bytes, checked_multiply(stream.offset_count.to_u64, sizeof(UInt64).to_u64))
      end
      bytes
    end

    private def grid_workspace_bytes(grid : StorageOccurrenceGrid) : UInt64
      bytes = instance_sizeof(StorageOccurrenceGrid).to_u64
      bytes = checked_add(bytes, 2_u64 * instance_sizeof(Array(UInt64)).to_u64)
      checked_add(bytes, checked_multiply(grid.mark_count.to_u64, 2_u64 * sizeof(UInt64).to_u64))
    end

    private def grid_workspace_bytes_for_stream_rows(streams : ObjectDocumentStreams) : UInt64
      bytes = instance_sizeof(Array(UInt64)).to_u64
      checked_add(bytes, checked_multiply(streams.mark_count.to_u64, sizeof(UInt64).to_u64))
    end

    private def array_frame_workspace_bytes(frame : StorageArrayOccurrenceFrame) : UInt64
      bytes = instance_sizeof(StorageArrayOccurrenceFrame).to_u64
      bytes = checked_add(bytes, grid_workspace_bytes(frame.parent_grid))
      bytes = checked_add(bytes, grid_workspace_bytes(frame.child_grid))
      stream = frame.size_stream
      bytes = checked_add(bytes, instance_sizeof(BinaryBulkStream).to_u64)
      bytes = checked_add(bytes, stream.byte_size.to_u64)
      checked_add(bytes, checked_multiply(stream.offset_count.to_u64, sizeof(UInt64).to_u64))
    end

    private def local_prepared_workspace_bytes(
      object_marks : Hash(String, Array(PreparedObjectMark)),
      uint8_bytes : Hash(String, Array(Bytes)),
      bulk_values : Hash(String, Array(Array(BinaryValue))),
      array_sizes : Hash(String, Array(Array(UInt64))),
      array_parent_rows : Hash(String, Array(UInt64)),
    ) : UInt64
      bytes = 0_u64
      object_marks.each do |key, marks|
        bytes = checked_add(bytes, string_owner_bytes(key))
        bytes = checked_add(bytes, instance_sizeof(Array(PreparedObjectMark)).to_u64)
        bytes = checked_add(bytes, checked_multiply(marks.size.to_u64, sizeof(PreparedObjectMark).to_u64))
        marks.each { |mark| bytes = checked_add(bytes, object_mark_workspace_bytes(mark)) }
      end
      uint8_bytes.each do |key, marks|
        bytes = checked_add(bytes, string_owner_bytes(key))
        bytes = checked_add(bytes, instance_sizeof(Array(Bytes)).to_u64)
        marks.each { |mark| bytes = checked_add(bytes, sizeof(Bytes).to_u64 + mark.size.to_u64) }
      end
      bulk_values.each do |key, marks|
        bytes = checked_add(bytes, string_owner_bytes(key))
        bytes = checked_add(bytes, instance_sizeof(Array(Array(BinaryValue))).to_u64)
        marks.each do |values|
          bytes = checked_add(bytes, instance_sizeof(Array(BinaryValue)).to_u64)
          bytes = checked_add(bytes, checked_multiply(values.size.to_u64, sizeof(Pointer(BinaryValue)).to_u64))
          values.each { |value| bytes = checked_add(bytes, binary_value_workspace_bytes(value)) }
        end
      end
      array_sizes.each do |key, marks|
        bytes = checked_add(bytes, string_owner_bytes(key))
        bytes = checked_add(bytes, instance_sizeof(Array(Array(UInt64))).to_u64)
        marks.each do |sizes|
          bytes = checked_add(bytes, instance_sizeof(Array(UInt64)).to_u64)
          bytes = checked_add(bytes, checked_multiply(sizes.size.to_u64, sizeof(UInt64).to_u64))
        end
      end
      array_parent_rows.each do |key, rows|
        bytes = checked_add(bytes, string_owner_bytes(key))
        bytes = checked_add(bytes, instance_sizeof(Array(UInt64)).to_u64)
        bytes = checked_add(bytes, checked_multiply(rows.size.to_u64, sizeof(UInt64).to_u64))
      end
      bytes
    end

    private def bulk_decode_workspace_bytes(
      physical_workspace : UInt64,
      ledger : CompactRecursiveJsonParentMarkLedger,
      object_marks : Hash(String, Array(PreparedObjectMark)),
      uint8_bytes : Hash(String, Array(Bytes)),
      bulk_values : Hash(String, Array(Array(BinaryValue))),
      array_sizes : Hash(String, Array(Array(UInt64))),
      array_parent_rows : Hash(String, Array(UInt64)),
      mark_bulk_streams : Hash(String, BinaryBulkStreams),
    ) : UInt64
      bytes = retained_workspace_bytes_without_prepared
      bytes = checked_add(bytes, physical_workspace)
      bytes = checked_add(bytes, ledger.retained_workspace_bytes)
      bytes = checked_add(bytes, local_prepared_workspace_bytes(
        object_marks,
        uint8_bytes,
        bulk_values,
        array_sizes,
        array_parent_rows,
      ))
      checked_add(bytes, mark_bulk_streams_workspace_bytes(mark_bulk_streams))
    end

    # This is a logical transient-owner estimate, not RSS or allocator capacity.
    # Decoder-internal allocations and retained PhysicalPlan internals are outside
    # this aggregate; the current mark's copied lanes are included here.
    private def mark_bulk_streams_workspace_bytes(
      mark_bulk_streams : Hash(String, BinaryBulkStreams),
    ) : UInt64
      bytes = instance_sizeof(Hash(String, BinaryBulkStreams)).to_u64
      mark_bulk_streams.each do |site_key, streams|
        bytes = checked_add(bytes, string_owner_bytes(site_key))
        bytes = checked_add(bytes, binary_streams_workspace_bytes(streams))
      end
      bytes
    end

    private def physical_window_workspace_bytes : UInt64
      context = @context || raise(CorruptPartError.new("Compact recursive JSON physical context is missing"))
      marks = @mark_count.to_u64
      slots = (context.mode.mrk3? ? 1 : @physical_stream_names.size).to_u64
      shard_count = checked_multiply(marks, slots)
      bytes = checked_multiply(@logical_read_bytes, 4_u64)
      shard_owner = instance_sizeof(CompactPartPhysicalShard).to_u64 +
                    sizeof(Pointer(CompactPartPhysicalShard)).to_u64 + sizeof(Bytes).to_u64 + instance_sizeof(String).to_u64
      bytes = checked_add(bytes, checked_multiply(checked_multiply(shard_count, shard_owner), 4_u64))
      granule_owner = instance_sizeof(CompactPartPhysicalGranule).to_u64 +
                      instance_sizeof(Array(CompactPartPhysicalShard)).to_u64 + sizeof(Pointer(CompactPartPhysicalGranule)).to_u64
      bytes = checked_add(bytes, checked_multiply(checked_multiply(marks, granule_owner), 4_u64))
      bytes = checked_add(bytes,
        checked_multiply(checked_multiply(shard_count, sizeof(Pointer(CompactPartPhysicalShard)).to_u64), 4_u64))
      @physical_stream_names.each do |name|
        bytes = checked_add(bytes, checked_multiply(string_owner_bytes(name), marks + 1_u64))
      end
      bytes
    end

    private def outer_workspace_without_root_delegate(reader : CompactStaticJsonBulkColumnReader) : UInt64
      # The delegate observer already includes the complete root reader base.
      # Subtract its base from our total to avoid charging that context twice.
      total = retained_workspace_bytes
      base = reader.retained_workspace_bytes
      total >= base ? total - base : 0_u64
    end

    private def retained_workspace_bytes_without_prepared : UInt64
      bytes = retained_workspace_bytes
      if state = @prepared_state
        state_bytes = prepared_state_workspace_bytes(state)
        bytes = bytes >= state_bytes ? bytes - state_bytes : 0_u64
      end
      bytes
    end

    private def object_streams_workspace_bytes_for_rows(streams : ObjectDocumentStreams) : UInt64
      object_streams_workspace_bytes(streams)
    end

    private def same_typed_schema?(left : Hash(String, BinaryDataType), right : Hash(String, BinaryDataType)) : Bool
      return false unless left.size == right.size
      left.all? { |path, type| right[path]? == type }
    end

    private def validate_json_site_limits!(schema : StorageColumnSchema, limits : BinaryCodecLimits) : Nil
      schema.each_json_site do |_key, object_schema|
        current = object_schema.limits
        unless current.max_depth == limits.max_depth && current.max_nodes == limits.max_nodes &&
               current.max_elements == limits.max_elements && current.max_bytes == limits.max_bytes
          raise ArgumentError.new("Compact recursive Object site limits must match the operation limits")
        end
      end
      nil
    end

    # Root Object declarations belong to ObjectDocumentSchemaParser rather
    # than StorageColumnSchemaParser, whose source grammar intentionally
    # requires a root Tuple or Array. Reparse the caller's exact source through
    # that dedicated owner and compare its canonical Object declaration with
    # the retained root descriptor.
    private def validate_root_object_source!(schema : StorageColumnSchema, limits : BinaryCodecLimits) : Nil
      parsed = ObjectDocumentSchema.parse_declaration(schema.source_declaration, limits)
      unless parsed.declaration == schema.object_schema.declaration
        raise ArgumentError.new("recursive storage descriptor differs from its root JSON source declaration")
      end
      nil
    end

    private def validate_selection!(first_mark : Int, mark_count : Int) : Nil
      first = first_mark.to_i128
      count = mark_count.to_i128
      marks = @mark_count.to_i128
      if first < 0 || count < 0 || first > marks || count > marks - first
        raise ArgumentError.new("Compact recursive JSON mark selection is outside the physical grid")
      end
      nil
    end

    private def request_budget : BinaryCodecBudget
      budget = @codec_budget || BinaryCodecBudget.new(@limits)
      if budget.writing?
        raise ArgumentError.new("Compact recursive JSON read requires a read-direction codec budget")
      end
      unless budget.limits == @limits
        raise ArgumentError.new("Compact recursive JSON request budget differs from its read limits")
      end
      budget
    end

    private def decode_uint64_lane(
      bytes : Bytes,
      count : UInt64,
      label : String,
      budget : BinaryCodecBudget,
    ) : Array(UInt64)
      expected = checked_byte_count(count, 8_u64, label)
      unless bytes.size == expected
        raise CorruptPartError.new("#{label} has the wrong exact callback extent")
      end
      budget.ensure_future_nodes(count)
      budget.ensure_future_elements(count)
      budget.charge_elements(count) if count > 0_u64
      remaining_nodes = count
      while remaining_nodes > 0_u64
        budget.charge_node
        remaining_nodes -= 1_u64
      end
      values = Array(UInt64).new(count.to_i)
      count.to_i.times do |value_index|
        value = 0_u64
        8.times do |byte_index|
          value |= bytes[value_index * 8 + byte_index].to_u64 << (byte_index * 8)
        end
        values << value
      end
      values
    end

    # The recursive schema plan freezes the logical serializer traversal, but
    # MRK4's parent cursor is keyed by the canonical side of the pairs emitted
    # by the parsed Object callback planner. Keep the logical list untouched
    # for per-site validation; project only the list passed to the physical
    # ledger. Array-size and ordinary UInt8 callbacks are identity pairs.
    private def physical_callback_names(
      logical_names : Array(String),
      schedules : Hash(String, CompactJsonObjectRoleSchedule),
      array_sites : Array(CompactRecursiveJsonSchemaPlan::ArraySite),
      uint8_sites : Array(CompactRecursiveJsonSchemaPlan::UInt8Site),
      bulk_sites : Array(CompactRecursiveJsonBulkSite),
      budget : BinaryCodecBudget,
    ) : Array(String)
      count = logical_names.size.to_u64
      if count > Int32::MAX.to_u64
        raise CorruptPartError.new("Compact recursive JSON callback roster exceeds its supported size")
      end
      added_nodes = checked_add(3_u64, checked_multiply(count, 2_u64))
      added_elements = checked_multiply(count, 4_u64)
      budget.ensure_future_nodes(added_nodes)
      budget.ensure_future_elements(added_elements)
      added_nodes.times { budget.charge_node }
      budget.charge_elements(added_elements) if added_elements > 0_u64

      canonical_by_callback = Hash(String, String).new(initial_capacity: logical_names.size)
      seen_canonical = Set(String).new(initial_capacity: logical_names.size)
      schedules.each_value do |schedule|
        schedule.prefix_events.each do |_owner, canonical, callback|
          register_physical_callback_pair!(canonical_by_callback, seen_canonical, canonical, callback)
        end
        schedule.body_events.each do |_owner, canonical, callback|
          register_physical_callback_pair!(canonical_by_callback, seen_canonical, canonical, callback)
        end
      end
      array_sites.each do |site|
        register_physical_callback_pair!(canonical_by_callback, seen_canonical, site.callback_name, site.callback_name)
      end
      uint8_sites.each do |site|
        register_physical_callback_pair!(canonical_by_callback, seen_canonical, site.callback_name, site.callback_name)
      end
      bulk_sites.each do |site|
        site.each_role do |role|
          callback = site.callback_name_for(role.name)
          register_physical_callback_pair!(canonical_by_callback, seen_canonical, callback, callback)
        end
      end
      unless canonical_by_callback.size.to_u64 == count
        raise CorruptPartError.new("Compact recursive JSON physical callback projection is not a complete roster")
      end

      physical_names = Array(String).new(logical_names.size)
      logical_names.each do |logical_name|
        physical_name = canonical_by_callback[logical_name]? ||
                        raise(CorruptPartError.new("Compact recursive JSON logical callback has no parsed physical-name pair"))
        physical_names << physical_name
      end
      unless physical_names.size == logical_names.size &&
             physical_names.all? { |name| seen_canonical.includes?(name) }
        raise CorruptPartError.new("Compact recursive JSON physical callback projection changed its ordered roster")
      end
      physical_names
    end

    private def register_physical_callback_pair!(
      canonical_by_callback : Hash(String, String),
      seen_canonical : Set(String),
      canonical : String,
      callback : String,
    ) : Nil
      if callback.empty? || canonical.empty? || canonical_by_callback.has_key?(callback) || !seen_canonical.add?(canonical)
        raise CorruptPartError.new("Compact recursive JSON physical callback pairs are not a one-to-one roster")
      end
      canonical_by_callback[callback] = canonical
      nil
    end

    private def checked_byte_count(count : UInt64, width : UInt64, label : String) : Int32
      bytes = checked_multiply(count, width)
      if count > Int32::MAX.to_u64 || bytes > Int32::MAX.to_u64
        raise CorruptPartError.new("#{label} exceeds the supported byte or row domain")
      end
      bytes.to_i32
    end

    private def tuple_child_key(parent : String, index : Int) : String
      String.build { |io| io << parent << "/tuple[" << index << ']' }
    end

    private def array_child_key(parent : String) : String
      String.build { |io| io << parent << "/array[0]" }
    end

    private def same_bytes?(left : Bytes, right : Bytes) : Bool
      return false unless left.size == right.size
      left.each_with_index.all? { |byte, index| byte == right[index] }
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
      checked_add(instance_sizeof(String).to_u64, value.bytesize.to_u64 + 1_u64)
    end

    private def no_workspace_observer : Proc(UInt64, Nil)
      ->(_workspace_bytes : UInt64) { nil }
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      if right > UInt64::MAX - left
        raise CorruptPartError.new("Compact recursive JSON workspace estimate overflows UInt64")
      end
      left + right
    end

    private def checked_multiply(left : UInt64, right : UInt64) : UInt64
      if left > 0_u64 && right > UInt64::MAX // left
        raise CorruptPartError.new("Compact recursive JSON workspace estimate overflows UInt64")
      end
      left * right
    end
  end
end
