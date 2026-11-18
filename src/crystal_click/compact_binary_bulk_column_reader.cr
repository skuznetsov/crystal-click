module CrystalClick
  # Binds one selected Compact physical column to the existing recursive
  # BinaryBulk decoder. Compact callback windows are normalized per granule;
  # the codec remains the sole owner of typed value semantics.
  class CompactBinaryBulkColumnReader
    getter row_count : UInt64
    getter mark_count : Int32
    getter ordinary_profile : BinaryBulkProfile
    getter logical_read_bytes : UInt64

    @part_path : String
    @column_name : String
    @type : BinaryDataType
    @projection_aggregate_descriptor : WidePartProjectionAggregateDescriptor?
    @projection_aggregate_key_names : Array(String)?
    @limits : BinaryCodecLimits
    @transport_limits : CompressedStreamLimits
    @codec_budget : BinaryCodecBudget?
    @transport_budget : CompressedStreamBudget?
    @context : CompactPartPhysicalContext
    @normalizer : CompactBinaryBulkNormalizer
    @mark_row_counts : Array(UInt64)
    @schema_declaration : String
    @source_declaration : String
    @physical_stream_names : Array(String)
    @selected_checksum_names : Array(String)
    @ordinary_uint64_slot_index : Int32?

    def self.open(
      part_path : String,
      column_name : String,
      expected_type : BinaryDataType,
      limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
      transport_limits : CompressedStreamLimits = CompressedStreamLimits.new,
      codec_budget : BinaryCodecBudget? = nil,
      transport_budget : CompressedStreamBudget? = nil,
      context : CompactPartPhysicalContext? = nil,
    ) : CompactBinaryBulkColumnReader
      if shared_context = context
        effective_budget = transport_budget || shared_context.transport_budget
        expected_data_path = File.join(File.expand_path(part_path), "data.bin")
        unless File.expand_path(shared_context.data_path) == expected_data_path &&
               shared_context.transport_budget.same?(effective_budget)
          raise CorruptPartError.new("shared Compact physical context does not match its part and transport budget")
        end
        transport_budget = effective_budget
      end
      new(
        part_path,
        column_name,
        expected_type,
        limits,
        transport_limits,
        codec_budget,
        transport_budget,
        nil,
        context,
      )
    end

    # Narrow stock projection route for the literal count() state column. This
    # retains BinaryBulk's nominal Count decoder while keeping Count outside
    # the ordinary static typed-carrier admission.
    def self.open_projection_count(
      part_path : String,
      limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
      transport_limits : CompressedStreamLimits = CompressedStreamLimits.new,
      codec_budget : BinaryCodecBudget? = nil,
      transport_budget : CompressedStreamBudget? = nil,
      admission_session : CompactProjectionAggregateReaderAdmissionSession? = nil,
    ) : CompactBinaryBulkColumnReader
      open_projection_state(
        part_path,
        "count()",
        WidePartProjectionAggregateDescriptor.count,
        true,
        limits,
        transport_limits,
        codec_budget,
        transport_budget,
        admission_session,
      )
    end

    # Narrow projection route for a canonical non-Count UInt64 aggregate
    # state. The physical roster is inspected before the selected reader is
    # constructed, then retained context is shared so metadata is charged once.
    def self.open_projection_aggregate(
      part_path : String,
      column_name : String,
      limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
      transport_limits : CompressedStreamLimits = CompressedStreamLimits.new,
      codec_budget : BinaryCodecBudget? = nil,
      transport_budget : CompressedStreamBudget? = nil,
    ) : CompactBinaryBulkColumnReader
      open_projection_state(
        part_path,
        column_name,
        nil,
        false,
        limits,
        transport_limits,
        codec_budget,
        transport_budget,
      )
    end

    # :nodoc:
    # Reuses the already-resolved descriptor when the table has it from its
    # bounded columns.txt admission. The public writer/readback seam above
    # remains name-based and resolves its descriptor from the physical child.
    def self.open_projection_aggregate_with_descriptor(
      part_path : String,
      descriptor : WidePartProjectionAggregateDescriptor,
      limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
      transport_limits : CompressedStreamLimits = CompressedStreamLimits.new,
      codec_budget : BinaryCodecBudget? = nil,
      transport_budget : CompressedStreamBudget? = nil,
      admission_session : CompactProjectionAggregateReaderAdmissionSession? = nil,
    ) : CompactBinaryBulkColumnReader
      unless !descriptor.count? && (descriptor.sum? || descriptor.minmax?)
        raise UnsupportedFormatError.new("Compact projection aggregate reader admits only UInt64 sum/min/max states")
      end
      open_projection_state(
        part_path,
        descriptor.column_name,
        descriptor,
        false,
        limits,
        transport_limits,
        codec_budget,
        transport_budget,
        admission_session,
      )
    end

    private def self.open_projection_state(
      part_path : String,
      column_name : String,
      requested_descriptor : WidePartProjectionAggregateDescriptor?,
      allow_count : Bool,
      limits : BinaryCodecLimits,
      transport_limits : CompressedStreamLimits,
      codec_budget : BinaryCodecBudget?,
      transport_budget : CompressedStreamBudget?,
      admission_session : CompactProjectionAggregateReaderAdmissionSession? = nil,
    ) : CompactBinaryBulkColumnReader
      if column_name.empty? || column_name.bytesize > WidePartTable::MAX_COLUMN_NAME_BYTES
        raise ArgumentError.new("Compact BinaryBulk column name is empty or exceeds its bound")
      end
      effective_transport_budget = transport_budget || CompressedStreamBudget.new(transport_limits)
      StorageReadBudgetValidator.validate!(
        codec_budget,
        effective_transport_budget,
        limits,
        transport_limits,
        "Compact BinaryBulk reader codec budget differs from its read limits",
        "Compact BinaryBulk reader transport budget differs from its read limits",
      )
      context = CompactPartPhysicalContext.open(part_path, effective_transport_budget)
      unless context.mode == CompactMarkFormat::Mrk4
        raise UnsupportedFormatError.new("Compact projection aggregates require MRK4 child marks")
      end
      type_name = context.columns.find { |name, _type| name == column_name }.try(&.[1]) ||
                  raise CorruptPartError.new("Compact selected aggregate is absent from columns.txt")
      descriptor = requested_descriptor || WidePartProjectionAggregateDescriptor.for_column(column_name, type_name) ||
                   raise UnsupportedFormatError.new("Compact projection aggregate has no canonical descriptor")
      unless descriptor.column_name == column_name && descriptor.type_name == type_name
        raise CorruptPartError.new("Compact selected aggregate differs from its canonical physical declaration")
      end
      if descriptor.count?
        unless allow_count && column_name == "count()"
          raise UnsupportedFormatError.new("Compact projection aggregate reader admits only UInt64 sum/min/max states")
        end
      elsif !(descriptor.sum? || descriptor.minmax?)
        raise UnsupportedFormatError.new("Compact projection aggregate reader admits only UInt64 sum/min/max states")
      end

      new(
        part_path,
        column_name,
        descriptor.type,
        limits,
        transport_limits,
        codec_budget,
        effective_transport_budget,
        descriptor,
        context,
        admission_session,
      )
    end

    private def initialize(
      part_path : String,
      column_name : String,
      @type : BinaryDataType,
      @limits : BinaryCodecLimits,
      @transport_limits : CompressedStreamLimits,
      codec_budget : BinaryCodecBudget?,
      transport_budget : CompressedStreamBudget?,
      @projection_aggregate_descriptor : WidePartProjectionAggregateDescriptor? = nil,
      context : CompactPartPhysicalContext? = nil,
      admission_session : CompactProjectionAggregateReaderAdmissionSession? = nil,
    )
      StorageReadBudgetValidator.validate!(
        codec_budget,
        transport_budget,
        @limits,
        @transport_limits,
        "Compact BinaryBulk reader codec budget differs from its read limits",
        "Compact BinaryBulk reader transport budget differs from its read limits",
      )
      @projection_aggregate_key_names = nil
      @ordinary_uint64_slot_index = nil
      @codec_budget = codec_budget
      @transport_budget = transport_budget

      if column_name.empty? || column_name.bytesize > WidePartTable::MAX_COLUMN_NAME_BYTES
        raise ArgumentError.new("Compact BinaryBulk column name is empty or exceeds its bound")
      end
      @part_path = File.expand_path(part_path)
      @column_name = String.new(column_name.to_slice)

      name_budget = codec_budget || BinaryCodecBudget.new(@limits)
      name_bounds = BinaryTypeNameBudget.measure(@type, name_budget)
      canonical = BinaryTypeNameBudget.materialize(@type, name_budget, name_bounds)
      name_budget.ensure_wire_bytes(canonical.bytesize.to_u64)
      name_budget.charge_wire_bytes(canonical.bytesize.to_u64)
      @schema_declaration = String.new(canonical.to_slice)

      if descriptor = @projection_aggregate_descriptor
        unless descriptor.column_name == column_name && descriptor.type == @type && canonical == descriptor.type_name
          raise UnsupportedFormatError.new("Compact projection reader differs from its canonical aggregate descriptor")
        end
        if descriptor.count?
          plan = WideAggregateCountStoragePlan.for_type(@type) ||
                 raise(UnsupportedFormatError.new("Compact projection reader requires an exact AggregateFunction(count) descriptor"))
          unless descriptor.column_name == "count()" && plan.type_name == WideAggregateCountStoragePlan::NO_ARGUMENT_TYPE_NAME &&
                 canonical == plan.type_name
            raise UnsupportedFormatError.new("Compact projection reader admits only the literal count() AggregateFunction(count) child")
          end
        else
          unless descriptor.sum? || descriptor.minmax?
            raise UnsupportedFormatError.new("Compact projection reader admits only UInt64 sum/min/max states")
          end
          aggregate_declaration = BinaryAggregateFunctionBulkColumnDeclaration.new(@type, @limits)
          unless aggregate_declaration.declaration == canonical
            raise CorruptPartError.new("Compact projection aggregate declaration differs from its canonical descriptor")
          end
        end
      else
        declaration = StaticBinaryBulkColumnDeclaration.new(@type, @limits)
        unless declaration.declaration == canonical
          raise CorruptPartError.new("Compact selected declaration differs from its canonical descriptor")
        end
      end
      unless !@projection_aggregate_descriptor.nil? || BinaryValueTypedBatchAdapter.admitted?(@type)
        raise UnsupportedFormatError.new("Compact selected type has no established typed batch carrier")
      end

      operation_transport_budget = transport_budget || CompressedStreamBudget.new(@transport_limits)
      @transport_budget = operation_transport_budget
      @context = context || CompactPartPhysicalContext.open(@part_path, operation_transport_budget)
      if !@projection_aggregate_descriptor.nil? && @context.mode != CompactMarkFormat::Mrk4
        raise UnsupportedFormatError.new("Compact projection aggregates require MRK4 child marks")
      end
      if @context.row_count == 0_u64 || @context.row_count > WidePartTable::MAX_TOTAL_ROWS
        raise CorruptPartError.new("Compact row count is outside the typed reader bound")
      end

      physical_columns = @context.columns
      selected_type = physical_columns.find { |name, _| name == @column_name }.try(&.[1])
      unless selected_type == canonical
        raise CorruptPartError.new("Compact selected declaration differs from columns.txt")
      end

      profile = CompactSerializationProfile.open(
        @part_path,
        physical_columns,
        @column_name,
        @type,
        @context.row_count,
        operation_transport_budget,
      )
      @ordinary_profile = profile.ordinary_profile
      @normalizer = CompactBinaryBulkNormalizer.new(
        @type,
        @column_name,
        @ordinary_profile,
        @limits,
      )

      roster = @context.physical_roster
      selected_slots = roster.select { |slot| slot.column_name == @column_name }
      if selected_slots.empty?
        raise CorruptPartError.new("Compact selected column has no physical callback slots")
      end
      case @context.mode
      when CompactMarkFormat::Mrk3
        unless selected_slots.size == 1 && selected_slots[0].stream_name.nil?
          raise CorruptPartError.new("Compact mrk3 column is not one unlabelled callback tape")
        end
        @physical_stream_names = [String.new(@column_name.to_slice)]
      when CompactMarkFormat::Mrk4
        expected_callbacks = @normalizer.expected_physical_callback_roster
        observed_callbacks = selected_slots.map do |slot|
          slot.stream_name || raise(CorruptPartError.new("Compact mrk4 callback has no stream name"))
        end
        unless observed_callbacks == expected_callbacks
          raise CorruptPartError.new("Compact selected callback roster differs from its recursive physical plan")
        end
        @physical_stream_names = copy_strings(observed_callbacks)
      else
        raise UnsupportedFormatError.new("unsupported Compact mark format for typed BinaryBulk reading")
      end
      if @schema_declaration == "UInt64" && @projection_aggregate_descriptor.nil?
        unless selected_slots.size == 1
          raise CorruptPartError.new("Compact ordinary UInt64 does not have one physical callback")
        end
        @ordinary_uint64_slot_index = selected_slots[0].index
      end

      @mark_row_counts = @context.mark_row_counts
      if @mark_row_counts.empty? || @mark_row_counts.size > WidePartTable::MAX_MARKS_PER_READER
        raise CorruptPartError.new("Compact mark count is outside the typed reader bound")
      end
      if @mark_row_counts.any? { |rows| rows == 0_u64 || rows > WidePartTable::MAX_MARK_ROWS }
        raise CorruptPartError.new("Compact mark rows are outside the typed reader bound")
      end
      total_rows = 0_u64
      @mark_row_counts.each do |rows|
        if rows > WidePartTable::MAX_TOTAL_ROWS - total_rows
          raise CorruptPartError.new("Compact mark row count exceeds the typed reader bound")
        end
        total_rows += rows
      end
      unless total_rows == @context.row_count
        raise CorruptPartError.new("Compact mark grid differs from the selected part row count")
      end

      @row_count = @context.row_count
      @mark_count = @mark_row_counts.size.to_i32
      @source_declaration = String.new(canonical.to_slice)
      @selected_checksum_names = ["data.bin", @context.marks_name]
      @logical_read_bytes = @context.logical_bytes_for(@column_name)
      if descriptor = @projection_aggregate_descriptor
        @projection_aggregate_key_names = CompactProjectionAggregateReaderAdmission.validate_projection_aggregate!(
          @part_path,
          @column_name,
          descriptor,
          self,
          operation_transport_budget,
          admission_session,
        )
      end
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

    # :nodoc:
    # Shared Compact metadata is exposed only to the projection admission
    # owner; callers still receive detached key rosters.
    def projection_aggregate_physical_context : CompactPartPhysicalContext
      @context
    end

    def projection_aggregate_limits : BinaryCodecLimits
      @limits
    end

    # Detached hidden UInt64 sibling roster for the projection-only Count
    # route. Ordinary Compact columns return nil.
    def aggregate_count_key_names : Array(String)?
      descriptor = @projection_aggregate_descriptor
      return nil unless descriptor && descriptor.count?
      @projection_aggregate_key_names.try { |names| copy_strings(names) }
    end

    # Detached key roster for any admitted Compact aggregate projection state.
    # Count keeps its historical accessor above; this covers count-free typed
    # scans that still need to compare mixed Wide/Compact group identities.
    def projection_aggregate_key_names : Array(String)?
      @projection_aggregate_key_names.try { |names| copy_strings(names) }
    end

    # Validates the projection's hidden leading key against the same Compact
    # columns, callback roster, and global mark grid already retained for the
    # Count state. The key is not selected for materialization.
    def projection_count_sibling_key_names! : Array(String)
      descriptor = @projection_aggregate_descriptor
      unless descriptor && descriptor.count? && @context.mode == CompactMarkFormat::Mrk4 &&
             @column_name == "count()" && @type == BinaryDataType.aggregate_count
        raise UnsupportedFormatError.new("Compact sibling key inspection requires the exact projection Count reader")
      end

      CompactProjectionAggregateReaderAdmission.validate_projection_roster!(@context, descriptor, @limits)
    end

    # :nodoc:
    # Used by CompactPartTable only for a selected ordinary UInt64 key in a
    # projection child. It validates a cidx candidate without publishing a
    # hidden aggregate roster on the ordinary reader.
    def validate_projection_aggregate_candidate!(session : CompactProjectionAggregateReaderAdmissionSession) : Nil
      return nil unless @projection_aggregate_descriptor.nil?
      CompactProjectionAggregateReaderAdmission.validate_projection_candidate!(
        @part_path,
        @column_name,
        @context,
        @limits,
        @transport_budget || raise(ArgumentError.new("Compact reader lost its borrowed transport budget")),
        session,
      )
    end

    # Retained physical mark-coordinate and parent-row arrays. The mark index
    # stores every global slot coordinate plus the explicit terminal record.
    def retained_grid_workspace_bytes : UInt64
      @context.retained_grid_workspace_bytes
    end

    # Logical charge for actual Compact reader owners and copied metadata.
    # This is intentionally an estimate of retained structures, not RSS.
    def retained_workspace_bytes : UInt64
      bytes = instance_sizeof(CompactBinaryBulkColumnReader).to_u64
      bytes = checked_add(bytes, @context.retained_workspace_bytes)
      bytes = checked_add(bytes, retained_grid_workspace_bytes)
      bytes = checked_add(bytes, @normalizer.retained_workspace_bytes)
      bytes = checked_add(bytes, string_owner_bytes(@part_path))
      bytes = checked_add(bytes, string_owner_bytes(@column_name))
      bytes = checked_add(bytes, string_owner_bytes(@schema_declaration))
      bytes = checked_add(bytes, string_owner_bytes(@source_declaration))
      bytes = checked_add(bytes, string_array_bytes(@physical_stream_names))
      bytes = checked_add(bytes, string_array_bytes(@selected_checksum_names))
      if key_names = @projection_aggregate_key_names
        bytes = checked_add(bytes, string_array_bytes(key_names))
      end
      bytes = checked_add(bytes, instance_sizeof(Array(UInt64)).to_u64)
      checked_add(bytes, checked_multiply(@mark_row_counts.size.to_u64, sizeof(UInt64).to_u64))
    end

    # :nodoc:
    # Reads one selected mark of an already-admitted ordinary UInt64 column.
    # The fast path is intentionally limited to the table's default codec
    # bounds; custom limits keep using the BinaryValue decoder and its budget.
    def read_ordinary_uint64_mark(
      mark_index : Int,
      scan_image : CompactUInt64ScanImage? = nil,
    ) : Bytes
      slot_index, expected_stream_name = ordinary_uint64_read_target
      @context.read_uint64_mark(
        @column_name,
        slot_index,
        mark_index,
        expected_stream_name,
        scan_image,
      )
    end

    # :nodoc:
    # Writes the selected ordinary UInt64 mark directly into scan-owned typed
    # storage after the same admission and physical-roster checks as the
    # detached path above.
    def read_ordinary_uint64_mark_into(
      mark_index : Int,
      destination : Bytes,
      workspace : CompressedBlock::DecodeWorkspace,
      scan_image : CompactUInt64ScanImage? = nil,
    ) : Nil
      slot_index, expected_stream_name = ordinary_uint64_read_target
      @context.read_uint64_mark_into(
        @column_name,
        slot_index,
        mark_index,
        expected_stream_name,
        destination,
        workspace,
        scan_image,
      )
      nil
    end

    private def ordinary_uint64_read_target : {Int32, String?}
      unless @schema_declaration == "UInt64" && @projection_aggregate_descriptor.nil?
        raise UnsupportedFormatError.new("Compact direct UInt64 reading requires an ordinary exact UInt64 column")
      end
      unless @codec_budget.nil? && @limits.same?(BinaryBulkCodec::DEFAULT_LIMITS)
        raise UnsupportedFormatError.new("Compact direct UInt64 reading requires default codec limits")
      end
      slot_index = @ordinary_uint64_slot_index ||
                   raise CorruptPartError.new("Compact ordinary UInt64 reader lost its admitted physical slot")
      expected_stream_name = if @context.mode.mrk4?
                               unless @physical_stream_names.size == 1
                                 raise CorruptPartError.new("Compact UInt64 reader has an invalid callback roster")
                               end
                               @physical_stream_names[0]
                             else
                               nil
                             end
      {slot_index, expected_stream_name}
    end

    # Returns selected marks → parent rows → exact-type BinaryValues. LC forces
    # complete-grid normalization/replay so a window cannot conceal an invalid
    # per-granule dictionary schedule.
    def read_marks(first_mark : Int, mark_count : Int) : Array(Array(BinaryValue))
      no_workspace_observer = ->(_workspace_bytes : UInt64) { nil }
      read_marks(first_mark, mark_count, no_workspace_observer)
    end

    # The observer receives a conservative logical upper bound before each
    # Compact-owned transient allocation phase. It is passed on this call
    # stack, rather than retained on the reader or normalizer, so nested reads
    # cannot reset shared accounting state.
    def read_marks(
      first_mark : Int,
      mark_count : Int,
      workspace_observer : Proc(UInt64, Nil),
    ) : Array(Array(BinaryValue))
      validate_selection!(first_mark, mark_count)
      codec_budget = @codec_budget || BinaryCodecBudget.new(@limits)
      transport_budget = @transport_budget || CompressedStreamBudget.new(@transport_limits)
      replay_complete = @type.contains_low_cardinality?
      read_first = replay_complete ? 0 : first_mark
      read_count = replay_complete ? @mark_count : mark_count
      normalized, rows, _ = read_normalized_window(read_first, read_count, codec_budget, workspace_observer)

      decoded = BinaryBulkDecoder.decode(
        @type,
        normalized,
        rows,
        codec_budget,
        replay_complete ? first_mark : 0,
        mark_count,
        @ordinary_profile,
      )
      unless decoded.size == mark_count
        raise CorruptPartError.new("Compact BinaryBulk decoder returned the wrong physical mark count")
      end
      decoded.each_with_index do |mark_values, index|
        unless mark_values.size.to_u64 == @mark_row_counts[first_mark + index]
          raise CorruptPartError.new("Compact BinaryBulk decoder returned the wrong parent row count")
        end
        mark_values.each do |value|
          unless value.type == @type
            raise CorruptPartError.new("Compact BinaryBulk decoder returned a mismatched value type")
          end
          if @projection_aggregate_descriptor.try(&.count?) && value.count_state == 0_u64
            raise CorruptPartError.new("Compact projection AggregateFunction(count) state is zero")
          end
        end
      end
      decoded
    end

    # Read one exact Array(Tuple(a UInt64, b String)) mark into owned flat
    # offset, value, and payload buffers. The observer sees the physical
    # window, normalized lanes, and flat result before output allocation.
    def read_array_tuple_uint64_string_mark(
      mark_index : Int,
      workspace_observer : Proc(UInt64, Nil),
    ) : CompactArrayTupleUInt64StringMark
      unless @projection_aggregate_descriptor.nil? &&
             @schema_declaration == WideTypePlan::TYPE_ARRAY_TUPLE_UINT64_STRING
        raise UnsupportedFormatError.new("Compact flat reader requires exact Array(Tuple(a UInt64, b String))")
      end
      validate_selection!(mark_index, 1)

      codec_budget = @codec_budget || BinaryCodecBudget.new(@limits)
      normalized, rows, physical_workspace = read_normalized_window(mark_index, 1, codec_budget, workspace_observer)
      CompactArrayTupleUInt64StringMark.decode(
        @type,
        normalized,
        rows,
        @ordinary_profile,
        codec_budget,
        workspace_observer,
        physical_workspace,
      )
    end

    # Convenience overload for callers that do not impose an aggregate
    # workspace observer.
    def read_array_tuple_uint64_string_mark(mark_index : Int) : CompactArrayTupleUInt64StringMark
      no_workspace_observer = ->(_workspace_bytes : UInt64) { nil }
      read_array_tuple_uint64_string_mark(mark_index, no_workspace_observer)
    end

    private def read_normalized_window(
      first_mark : Int,
      mark_count : Int,
      codec_budget : BinaryCodecBudget,
      workspace_observer : Proc(UInt64, Nil),
    ) : {BinaryBulkStreams, Array(UInt64), UInt64}
      # Bound the raw window and detached shards that coexist during normalization.
      workspace_observer.call(@logical_read_bytes)
      physical_workspace = physical_window_workspace_bytes(mark_count.to_i32)
      workspace_observer.call(physical_workspace)
      window = @context.read_window(@column_name, first_mark, mark_count)
      normalized, rows = @normalizer.normalize(window, codec_budget, workspace_observer, physical_workspace)
      unless rows == selected_rows(first_mark, mark_count)
        raise CorruptPartError.new("Compact normalized parent grid differs from the validated mark grid")
      end
      {normalized, rows, physical_workspace}
    end

    private def physical_window_workspace_bytes(mark_count : Int32) : UInt64
      marks = mark_count.to_u64
      slots = @physical_stream_names.size.to_u64
      shards = checked_multiply(marks, slots)

      # read_ranges, Compact shard construction, granule/window detachment,
      # and the normalizer's detached cursor all have owned byte snapshots.
      # Four full payload copies bounds the peak construction/consumption chain
      # without claiming allocator RSS.
      bytes = checked_multiply(@logical_read_bytes, 4_u64)

      shard_owner = checked_add(
        instance_sizeof(CompactPartPhysicalShard).to_u64,
        checked_add(sizeof(Pointer(CompactPartPhysicalShard)).to_u64, instance_sizeof(String).to_u64),
      )
      bytes = checked_add(bytes, checked_multiply(checked_multiply(shards, shard_owner), 4_u64))

      granule_owner = checked_add(
        instance_sizeof(CompactPartPhysicalGranule).to_u64,
        checked_add(instance_sizeof(Array(CompactPartPhysicalShard)).to_u64,
          sizeof(Pointer(CompactPartPhysicalGranule)).to_u64),
      )
      bytes = checked_add(bytes, checked_multiply(checked_multiply(marks, granule_owner), 4_u64))
      bytes = checked_add(
        bytes,
        checked_multiply(
          checked_multiply(shards, sizeof(Pointer(CompactPartPhysicalShard)).to_u64),
          4_u64,
        ),
      )

      # Slot/name snapshots are created even for a zero-mark window.
      bytes = checked_add(
        bytes,
        checked_multiply(slots, checked_add(instance_sizeof(CompactPhysicalSlot).to_u64,
          sizeof(Pointer(CompactPhysicalSlot)).to_u64)),
      )
      @physical_stream_names.each do |name|
        bytes = checked_add(bytes, checked_multiply(string_owner_bytes(name), marks + 1_u64))
      end
      bytes
    end

    private def validate_selection!(first_mark : Int, mark_count : Int) : Nil
      first = first_mark.to_i128
      count = mark_count.to_i128
      total = @mark_count.to_i128
      if first < 0 || first > total || count < 0 || count > total - first
        raise ArgumentError.new("Compact selected mark range is outside the physical grid")
      end
      nil
    end

    private def selected_rows(first_mark : Int, count : Int) : Array(UInt64)
      Array(UInt64).new(count) { |index| @mark_row_counts[first_mark + index] }
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
      raise BoundsError.new("Compact reader workspace charge overflows UInt64") if right > UInt64::MAX - left
      left + right
    end

    private def checked_multiply(left : UInt64, right : UInt64) : UInt64
      if left > 0_u64 && right > UInt64::MAX // left
        raise BoundsError.new("Compact reader workspace charge overflows UInt64")
      end
      left * right
    end
  end
end
