module CrystalClick
  # Binds a selected Compact Dynamic-bearing column to one part-wide learned
  # Dynamic plan and the existing recursive BinaryBulk decoder. The complete
  # physical mark grid is normalized and frozen on first use, including an
  # empty selected window; only requested values are decoded.
  class CompactDynamicBulkColumnReader
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
    @normalizer : CompactBinaryBulkNormalizer
    @serialization_profile : CompactSerializationProfile
    @mark_row_counts : Array(UInt64)
    @schema_declaration : String
    @source_declaration : String
    @physical_stream_names : Array(String)
    @selected_checksum_names : Array(String)
    @normalized_streams : BinaryBulkStreams?
    @normalized_rows : Array(UInt64)?
    @prepared_context : CompactDynamicBulkPreparedContext?

    def self.open(
      part_path : String,
      column_name : String,
      expected_type : BinaryDataType,
      limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
      transport_limits : CompressedStreamLimits = CompressedStreamLimits.new,
      codec_budget : BinaryCodecBudget? = nil,
      transport_budget : CompressedStreamBudget? = nil,
    ) : CompactDynamicBulkColumnReader
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
        "Compact Dynamic reader codec budget differs from its read limits",
        "Compact Dynamic reader transport budget differs from its read limits",
      )
      @codec_budget = codec_budget
      @transport_budget = transport_budget

      unless @type.contains_dynamic?
        raise UnsupportedFormatError.new("Compact Dynamic reader requires a Dynamic-bearing declaration")
      end
      CompactDynamicBulkPrefixTraversal.validate_compact_type_admission!(@type, @limits)
      if column_name.empty? || column_name.bytesize > WidePartTable::MAX_COLUMN_NAME_BYTES
        raise ArgumentError.new("Compact Dynamic column name is empty or exceeds its bound")
      end

      @part_path = File.expand_path(part_path)
      @column_name = String.new(column_name.to_slice)
      name_budget = codec_budget || BinaryCodecBudget.new(@limits)
      name_bounds = BinaryTypeNameBudget.measure(@type, name_budget)
      canonical = BinaryTypeNameBudget.materialize(@type, name_budget, name_bounds)
      name_budget.ensure_wire_bytes(canonical.bytesize.to_u64)
      name_budget.charge_wire_bytes(canonical.bytesize.to_u64)
      @schema_declaration = String.new(canonical.to_slice)
      validate_dynamic_declaration!(canonical)

      operation_transport_budget = transport_budget || CompressedStreamBudget.new(@transport_limits)
      @transport_budget = operation_transport_budget
      @context = CompactPartPhysicalContext.open(@part_path, operation_transport_budget)
      if @context.row_count == 0_u64 || @context.row_count > WidePartTable::MAX_TOTAL_ROWS
        raise CorruptPartError.new("Compact Dynamic row count is outside the typed reader bound")
      end

      physical_columns = @context.columns
      source_type = physical_columns.find { |name, _| name == @column_name }.try(&.[1])
      unless source_type == canonical
        raise CorruptPartError.new("Compact Dynamic declaration differs from columns.txt")
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
      @normalizer = CompactBinaryBulkNormalizer.new(
        @type,
        @column_name,
        @ordinary_profile,
        @limits,
      )

      selected_slots = @context.physical_roster.select { |slot| slot.column_name == @column_name }
      if selected_slots.empty?
        raise CorruptPartError.new("Compact Dynamic column has no physical callback slots")
      end
      case @context.mode
      when CompactMarkFormat::Mrk3
        unless selected_slots.size == 1 && selected_slots[0].stream_name.nil?
          raise CorruptPartError.new("Compact mrk3 Dynamic column is not one unlabelled callback tape")
        end
        @physical_stream_names = [String.new(@column_name.to_slice)]
      when CompactMarkFormat::Mrk4
        observed_names = selected_slots.map do |slot|
          slot.stream_name || raise(CorruptPartError.new("Compact mrk4 Dynamic callback has no stream name"))
        end
        @physical_stream_names = copy_strings(observed_names)
      else
        raise UnsupportedFormatError.new("unsupported Compact mark format for Dynamic bulk reading")
      end

      @mark_row_counts = @context.mark_row_counts
      if @mark_row_counts.empty? || @mark_row_counts.size > WidePartTable::MAX_MARKS_PER_READER
        raise CorruptPartError.new("Compact Dynamic mark count is outside the typed reader bound")
      end
      total_rows = 0_u64
      @mark_row_counts.each do |rows|
        if rows == 0_u64 || rows > WidePartTable::MAX_MARK_ROWS || rows > WidePartTable::MAX_TOTAL_ROWS - total_rows
          raise CorruptPartError.new("Compact Dynamic mark rows are outside the typed reader bound")
        end
        total_rows += rows
      end
      unless total_rows == @context.row_count
        raise CorruptPartError.new("Compact Dynamic mark grid differs from its part row count")
      end

      @row_count = @context.row_count
      @mark_count = @mark_row_counts.size.to_i32
      @source_declaration = String.new(canonical.to_slice)
      marks_name = @context.mode.mrk3? ? "data.mrk3" : "data.mrk4"
      @selected_checksum_names = ["data.bin", marks_name]
      @logical_read_bytes = @context.logical_bytes_for(@column_name)
      @normalized_streams = nil
      @normalized_rows = nil
      @prepared_context = nil
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

    def retained_grid_workspace_bytes : UInt64
      @context.retained_grid_workspace_bytes
    end

    # Logical owner estimate includes the frozen prepared plan and cached
    # normalized lane grid after first use. It is an explicit workspace census,
    # not an allocator/RSS measurement.
    def retained_workspace_bytes : UInt64
      bytes = instance_sizeof(CompactDynamicBulkColumnReader).to_u64
      bytes = checked_add(bytes, @context.retained_workspace_bytes)
      bytes = checked_add(bytes, retained_grid_workspace_bytes)
      bytes = checked_add(bytes, @normalizer.retained_workspace_bytes)
      bytes = checked_add(bytes, string_owner_bytes(@part_path))
      bytes = checked_add(bytes, string_owner_bytes(@column_name))
      bytes = checked_add(bytes, string_owner_bytes(@schema_declaration))
      bytes = checked_add(bytes, string_owner_bytes(@source_declaration))
      bytes = checked_add(bytes, string_array_bytes(@physical_stream_names))
      bytes = checked_add(bytes, string_array_bytes(@selected_checksum_names))
      bytes = checked_add(bytes, instance_sizeof(Array(UInt64)).to_u64)
      bytes = checked_add(bytes, checked_multiply(@mark_row_counts.size.to_u64, sizeof(UInt64).to_u64))
      if prepared = @prepared_context
        bytes = checked_add(bytes, @normalizer.dynamic_prepared_context_workspace_bytes(prepared))
      end
      if rows = @normalized_rows
        bytes = checked_add(bytes, instance_sizeof(Array(UInt64)).to_u64)
        bytes = checked_add(bytes, checked_multiply(rows.size.to_u64, sizeof(UInt64).to_u64))
      end
      if streams = @normalized_streams
        bytes = checked_add(bytes, instance_sizeof(BinaryBulkStreams).to_u64)
        bytes = checked_add(bytes, checked_multiply(streams.role_count.to_u64, sizeof(Pointer(BinaryBulkStream)).to_u64))
        bytes = checked_add(bytes, streams.total_input_byte_size)
        offset_count = checked_multiply(streams.role_count.to_u64, (@mark_count.to_u64 + 1_u64))
        bytes = checked_add(bytes, checked_multiply(offset_count, sizeof(UInt64).to_u64))
        bytes = checked_add(bytes, checked_multiply(streams.role_count.to_u64, instance_sizeof(BinaryBulkStream).to_u64))
        # The shared prepared-plan census above already accounts for the
        # callback and role-name copies created from this immutable roster.
      end
      bytes
    end

    # Validate and freeze every prefix/body callback and normalized lane grid
    # even for a zero-width selection. Subsequent reads use that immutable
    # part-wide roster and only decode the caller's requested marks.
    def validate_complete_schedule : Nil
      no_workspace_observer = ->(_workspace_bytes : UInt64) { nil }
      validate_complete_schedule(no_workspace_observer)
    end

    def validate_complete_schedule(workspace_observer : Proc(UInt64, Nil)) : Nil
      read_marks(0, 0, workspace_observer)
      nil
    end

    def read_marks(first_mark : Int, mark_count : Int) : Array(Array(BinaryValue))
      no_workspace_observer = ->(_workspace_bytes : UInt64) { nil }
      read_marks(first_mark, mark_count, no_workspace_observer)
    end

    def read_marks(
      first_mark : Int,
      mark_count : Int,
      workspace_observer : Proc(UInt64, Nil),
    ) : Array(Array(BinaryValue))
      validate_selection!(first_mark, mark_count)
      codec_budget = @codec_budget || BinaryCodecBudget.new(@limits)
      ensure_prepared!(codec_budget, workspace_observer) unless @normalized_streams

      prepared = @prepared_context || raise(CorruptPartError.new("Compact Dynamic prepared context is missing"))
      streams = @normalized_streams || raise(CorruptPartError.new("Compact Dynamic normalized grid is missing"))
      rows = @normalized_rows || raise(CorruptPartError.new("Compact Dynamic normalized row grid is missing"))
      selected_rows = selected_rows(first_mark, mark_count)
      decode_workspace = checked_add(retained_workspace_bytes, checked_multiply(selected_rows, sizeof(Pointer(BinaryValue)).to_u64))
      workspace_observer.call(decode_workspace)

      decoded = BinaryBulkDecoder.decode(
        @type,
        streams,
        rows,
        codec_budget,
        first_mark,
        mark_count,
        @ordinary_profile,
        prepared.plan,
      )
      unless decoded.size == mark_count
        raise CorruptPartError.new("Compact Dynamic decoder returned the wrong physical mark count")
      end
      decoded.each_with_index do |mark_values, index|
        unless mark_values.size.to_u64 == @mark_row_counts[first_mark + index]
          raise CorruptPartError.new("Compact Dynamic decoder returned the wrong parent row count")
        end
        mark_values.each do |value|
          unless value.type == @type
            raise CorruptPartError.new("Compact Dynamic decoder returned a mismatched value type")
          end
        end
      end
      decoded
    end

    private def ensure_prepared!(
      budget : BinaryCodecBudget,
      workspace_observer : Proc(UInt64, Nil),
    ) : Nil
      retained_base_workspace = retained_workspace_bytes
      physical_workspace = physical_window_workspace_bytes(@mark_count)
      workspace_observer.call(checked_add(retained_base_workspace, @logical_read_bytes))
      workspace_observer.call(checked_add(retained_base_workspace, physical_workspace))
      normalizer_workspace_observer = ->(workspace_bytes : UInt64) {
        workspace_observer.call(checked_add(retained_base_workspace, workspace_bytes))
        nil
      }
      window = @context.read_window(@column_name, 0, @mark_count)
      prepared_observer = ->(prepared_context : CompactDynamicBulkPreparedContext) do
        validate_learned_serialization_profile!(prepared_context)
        nil
      end
      streams, rows, prepared = @normalizer.normalize_dynamic(
        window,
        budget,
        normalizer_workspace_observer,
        physical_workspace,
        nil,
        prepared_observer,
      )
      unless rows == @mark_row_counts
        raise CorruptPartError.new("Compact Dynamic normalized grid differs from the validated mark grid")
      end
      @normalized_streams = streams
      @normalized_rows = rows
      @prepared_context = prepared
      nil
    end

    private def validate_learned_serialization_profile!(prepared : CompactDynamicBulkPreparedContext) : Nil
      profile = @serialization_profile
      return nil unless profile.propagated_nested_versions && !profile.map_basic

      contains_map = contains_tag?(@type, BinaryDataType::TAG_MAP)
      prepared.plan.each_site_path do |path|
        prepared.plan.arm_count(path).times do |index|
          contains_map ||= contains_tag?(prepared.plan.arm_type(path, index), BinaryDataType::TAG_MAP)
        end
      end
      if contains_map
        raise UnsupportedFormatError.new("only BASIC Compact Map serialization is supported for learned Dynamic arms")
      end
      nil
    end

    private def validate_dynamic_declaration!(canonical : String) : Nil
      parsed = if canonical == "Dynamic"
                 bytes = canonical.to_slice
                 ObjectDeclaredDynamicDeclaration.resolve_slice(bytes, 0, bytes.size).try(&.materialize)
               else
                 DynamicBulkColumnDeclaration.parse(canonical)
               end
      unless parsed == @type
        raise UnsupportedFormatError.new("Compact Dynamic declaration is outside the admitted recursive profile")
      end
      nil
    end

    private def contains_tag?(type : BinaryDataType, tag : UInt8) : Bool
      return true if type.tag == tag
      type.child_count.times do |index|
        return true if contains_tag?(type.child_at(index), tag)
      end
      false
    end

    private def physical_window_workspace_bytes(mark_count : Int32) : UInt64
      marks = mark_count.to_u64
      slots = @physical_stream_names.size.to_u64
      shards = checked_multiply(marks, slots)
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
        checked_multiply(checked_multiply(shards, sizeof(Pointer(CompactPartPhysicalShard)).to_u64), 4_u64),
      )
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

    private def selected_rows(first_mark : Int, mark_count : Int) : UInt64
      total = 0_u64
      mark_count.times do |index|
        rows = @mark_row_counts[first_mark + index]
        if rows > UInt64::MAX - total
          raise CorruptPartError.new("Compact Dynamic selected row count overflows")
        end
        total += rows
      end
      total
    end

    private def validate_selection!(first_mark : Int, mark_count : Int) : Nil
      first = first_mark.to_i128
      count = mark_count.to_i128
      if first < 0 || count < 0 || first > @mark_count.to_i128 || count > @mark_count.to_i128 - first
        raise ArgumentError.new("Compact Dynamic mark selection is outside the validated grid")
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
        raise CorruptPartError.new("Compact Dynamic workspace estimate overflows")
      end
      left + right
    end

    private def checked_multiply(left : UInt64, right : UInt64) : UInt64
      if left > 0_u64 && right > UInt64::MAX // left
        raise CorruptPartError.new("Compact Dynamic workspace estimate overflows")
      end
      left * right
    end
  end
end
