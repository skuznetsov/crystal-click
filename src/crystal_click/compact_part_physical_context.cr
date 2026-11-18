module CrystalClick
  # Schema-neutral reader for a complete Compact physical mark grid.
  # It retains detached metadata, coordinates and frame headers plus a
  # borrowed, consumptive budget; payload reads still authenticate selected
  # frames through the paired physical reader.
  class CompactPartPhysicalContext
    getter mode : CompactMarkFormat
    getter row_count : UInt64
    getter granule_count : Int32

    @columns_substreams : CompactColumnsSubstreams
    @mark_index : CompactMarkIndex
    @data_input : PartPhysicalInput
    @budget : CompressedStreamBudget
    @compressed_primary_index_signal : Bool

    private def initialize(
      @mode : CompactMarkFormat,
      @row_count : UInt64,
      @columns_substreams : CompactColumnsSubstreams,
      @mark_index : CompactMarkIndex,
      @data_input : PartPhysicalInput,
      @budget : CompressedStreamBudget,
      @compressed_primary_index_signal : Bool,
    )
      @granule_count = @mark_index.mark_count
    end

    def self.open(
      part_path : String,
      budget : CompressedStreamBudget = CompressedStreamBudget.read_default,
    ) : CompactPartPhysicalContext
      budget.ensure_direction(false)

      # Read and charge checksums.txt before constructing a source so a FIFO,
      # symlink or oversized file cannot enter the legacy unbounded read path.
      metadata = PartMetadataFileReader.new(part_path, budget)
      checksum_text = metadata.read("checksums.txt", PartChecksums::MAX_CHECKSUM_FILE_BYTES)
      checksums = PartChecksums.parse(checksum_text.to_slice)
      source = PartStreamSource.new(part_path, checksums)
      metadata = PartMetadataFileReader.new(part_path, budget, source)
      mark_file = CompactMarkFileAdapter.new(part_path, checksums, source)
      mode = mark_file.mode
      compressed_index_path = File.join(part_path, "primary.cidx")
      compressed_index_signal = File.exists?(compressed_index_path) ||
                                File.symlink?(compressed_index_path) ||
                                !checksums.entry("primary.cidx").nil?

      columns = WidePart.parse_columns_metadata(metadata.read("columns.txt"))
      row_count = WidePart.parse_count_metadata(metadata.read("count.txt", 32_i64), WidePart::MAX_ROWS)
      roster = if mode.mrk4?
                 substreams = WidePart.parse_columns_substreams_metadata(
                   metadata.read("columns_substreams.txt"),
                   columns
                 )
                 CompactColumnsSubstreams.new(mode, columns, substreams)
               else
                 # A substreams sidecar cannot refine the physical identity of
                 # an mrk3 whole-column mark slot.
                 CompactColumnsSubstreams.new(mode, columns)
               end

      input = source.physical_input("data.bin", mark_file.marks_name)
      canonical_marks = mark_file.read_canonical_marks(input, budget)
      index = CompactMarkIndex.read(input, roster, row_count, budget, canonical_marks)
      new(mode, row_count, roster, index, input, budget, compressed_index_signal)
    end

    def columns : Array({String, String})
      @columns_substreams.columns
    end

    # :nodoc:
    # Rebind selected path metadata to the declaration retained by this
    # independently opened physical context.
    def physical_column_type_matches?(column_name : String, type_name : String) : Bool
      @columns_substreams.column_type_matches?(column_name, type_name)
    end

    # The selected checksum identity is detached from the retained input.
    def marks_name : String
      String.new(@data_input.marks_name.to_slice)
    end

    # :nodoc:
    # Scan-image identity is bound to the physical input admitted by this
    # context; callers receive detached path text, never its retained owner.
    def data_path : String
      String.new(@data_input.data_path.to_slice)
    end

    def data_size : Int64
      @data_input.data_size
    end

    def frame_index : CompressedFrameIndex
      @mark_index.frame_index
    end

    def transport_budget : CompressedStreamBudget
      @budget
    end

    def compressed_primary_index_signal? : Bool
      @compressed_primary_index_signal
    end

    # Internal binding used by one-child projection admission sessions. A
    # separate reader context for the same path is valid when it borrows the
    # exact same consumptive budget.
    def matches_projection_child_scope?(part_path : String, budget : CompressedStreamBudget) : Bool
      path = File.expand_path(part_path)
      @budget.same?(budget) && @data_input.data_name == "data.bin" &&
        File.expand_path(@data_input.data_path) == File.join(path, "data.bin") &&
        File.expand_path(@data_input.marks_path) == File.join(path, @data_input.marks_name)
    end

    def physical_roster : Array(CompactPhysicalSlot)
      @columns_substreams.roster
    end

    # Logical retained non-grid owner census. The borrowed budget object is
    # charged conservatively for each context even when several contexts share
    # one instance; capacities and allocator/RSS overhead are excluded.
    def retained_workspace_bytes : UInt64
      bytes = instance_sizeof(CompactPartPhysicalContext).to_u64
      bytes = checked_add(bytes, @columns_substreams.retained_workspace_bytes)
      bytes = checked_add(bytes, @data_input.retained_string_workspace_bytes)
      checked_add(bytes, instance_sizeof(CompressedStreamBudget).to_u64)
    end

    def retained_lookup_index_workspace_bytes : UInt64
      @columns_substreams.retained_lookup_index_workspace_bytes
    end

    def retained_grid_workspace_bytes : UInt64
      @mark_index.retained_grid_workspace_bytes
    end

    # Resolve a persisted mark pair in the original whole data.bin coordinate
    # domain. The retained index is header metadata only; callers must still
    # bind detached bytes through exact authenticated shard provenance.
    def logical_position(pair : Tuple(UInt64, UInt64)) : Int64
      @mark_index.logical_position(pair)
    end

    # Rejects public/fabricated shard values unless both their slot interval
    # and detached bytes match this part's authenticated physical source.
    def validate_shard_provenance!(shards : Array(CompactPartPhysicalShard)) : Nil
      if shards.empty? || shards.size > Int32::MAX
        raise CorruptPartError.new("Compact shard provenance roster is empty or oversized")
      end

      record_count = shards.size.to_i64
      # The exact range tape and path-owned shard/path-start descriptors are
      # all allocated below. Reserve their known cardinality first; the paired
      # reader separately charges its own temporary frame/output descriptors.
      if record_count > Int64::MAX // 3_i64
        raise CorruptPartError.new("Compact shard provenance descriptor count overflows")
      end
      @budget.preflight_records(record_count * 3_i64)
      @budget.reserve_records(record_count * 3_i64)
      ranges = Array({Int64, Int64}).new(shards.size)
      previous_end = -1_i64
      shards.each do |shard|
        unless @columns_substreams.slot_matches?(shard.slot_index, shard.stream_name)
          raise CorruptPartError.new("Compact shard stream identity differs from the physical roster")
        end
        if shard.logical_start < previous_end
          raise CorruptPartError.new("Compact path shard intervals overlap or are out of source order")
        end
        unless grid_contains_interval?(shard.slot_index, shard.logical_start, shard.logical_end)
          raise CorruptPartError.new("Compact shard interval is not a saved physical mark-slot interval")
        end
        ranges << {shard.logical_start, shard.logical_end}
        previous_end = shard.logical_end
      end

      authenticated = CompressedMarkReader.read_ranges(
        @data_input.data_path,
        @data_input.data_size,
        ranges,
        @budget,
      )
      unless authenticated.size == shards.size
        raise CorruptPartError.new("Compact shard provenance reader returned an incomplete byte set")
      end
      shards.each_with_index do |shard, index|
        unless shard.matches_bytes?(authenticated[index])
          raise CorruptPartError.new("Compact shard bytes differ from their authenticated physical source")
        end
      end
      nil
    end

    # Binds the exact detached shard snapshot consumed by the caller's parent
    # ledger to the selected column and saved physical mark. Unlike
    # validate_shard_provenance!, this does not accept a shard merely because
    # its interval happens to match some mark in the part. Identity,
    # coordinates, row metadata, and authenticated payload are checked as one
    # parent-column certificate.
    def validate_parent_granule!(
      column_name : String,
      granule : CompactPartPhysicalGranule,
      shards : Array(CompactPartPhysicalShard),
    ) : Nil
      if column_name.empty? || granule.mark < 0 || granule.mark >= @mark_index.mark_count
        raise CorruptPartError.new("Compact parent granule does not identify a selected physical mark")
      end

      slot_count = begin
        @columns_substreams.slot_count_for(column_name)
      rescue ex : ArgumentError
        raise CorruptPartError.new("Compact parent granule names an unknown selected column")
      end
      @budget.preflight_records(slot_count.to_i64)
      @budget.reserve_records(slot_count.to_i64)
      slots = begin
        @columns_substreams.slots_for(column_name)
      rescue ex : ArgumentError
        raise CorruptPartError.new("Compact parent granule names an unknown selected column")
      end
      unless !slots.empty? && slots.size == slot_count && shards.size == slots.size
        raise CorruptPartError.new("Compact parent granule shard roster differs from its selected column")
      end

      expected_row_offset = 0_u64
      granule.mark.times do |mark|
        rows = @mark_index.row_count_at(mark)
        if rows > UInt64::MAX - expected_row_offset
          raise CorruptPartError.new("Compact parent row offset overflows UInt64")
        end
        expected_row_offset += rows
      end
      expected_rows = @mark_index.row_count_at(granule.mark)
      unless granule.row_offset == expected_row_offset && granule.row_count == expected_rows
        raise CorruptPartError.new("Compact parent granule row metadata differs from its saved mark")
      end

      shards.each_with_index do |shard, index|
        slot = slots[index]
        unless shard.slot_index == slot.index && shard.stream_name == slot.stream_name
          raise CorruptPartError.new("Compact parent granule callback order differs from its selected column roster")
        end
        expected_start = @mark_index.position_at(granule.mark, slot.index)
        expected_end = if slot.index + 1 < @mark_index.slot_count
                         @mark_index.position_at(granule.mark, slot.index + 1)
                       else
                         @mark_index.position_at(granule.mark + 1, 0)
                       end
        unless shard.logical_start == expected_start && shard.logical_end == expected_end
          raise CorruptPartError.new("Compact parent granule interval differs from its selected saved mark slot")
        end
      end

      # This second source read is intentional: detached shard objects are
      # public values, so their bytes must be rebound to authenticated payload
      # provenance before any child path can retain them.
      validate_shard_provenance!(shards)
      nil
    end

    # Metadata-only prepared-site binding for an MRK3 root Object. The byte
    # shard has already been authenticated by validate_shard_provenance! when
    # its coordinate context was constructed; this additionally proves that
    # it is the single whole-column slot and exact saved mark interval named by
    # the prepared root identity.
    def validate_mrk3_site!(
      column_name : String,
      physical_prefix : String,
      mark_index : Int,
      shards : Array(CompactPartPhysicalShard),
    ) : Nil
      unless @mode.mrk3? && !column_name.empty? &&
             PhysicalStreamName.escape(column_name) == physical_prefix &&
             shards.size == 1
        raise_invalid_mrk3_site!
      end

      shard = shards[0]
      unless shard.stream_name.nil? &&
             @columns_substreams.slot_column_matches?(shard.slot_index, column_name) &&
             mark_index >= 0 && mark_index < @mark_index.mark_count
        raise_invalid_mrk3_site!
      end

      start = @mark_index.position_at(mark_index, shard.slot_index)
      finish = if shard.slot_index + 1 < @mark_index.slot_count
                 @mark_index.position_at(mark_index, shard.slot_index + 1)
               else
                 @mark_index.position_at(mark_index + 1, 0)
               end
      unless shard.logical_start == start && shard.logical_end == finish
        raise_invalid_mrk3_site!
      end
      nil
    end

    # Detached parent-row grid validated while the Compact mark index was
    # opened. Typed consumers use the same grid as the physical windows; this
    # snapshot does not read or authenticate payload bytes.
    def mark_row_counts : Array(UInt64)
      count = @mark_index.mark_count.to_i64
      @budget.preflight_records(count)
      @budget.reserve_records(count)
      Array(UInt64).new(@mark_index.mark_count) do |index|
        @mark_index.row_count_at(index)
      end
    end

    # Logical payload span for one selected column, derived only from its
    # validated per-mark slot intervals. Compact coordinates are interleaved
    # across columns, so subtracting a selected slot's first coordinate from
    # its terminal coordinate would include unrelated columns (and summing
    # those spans would double-count). This does not open or authenticate data
    # payload frames.
    def logical_bytes_for(column_name : String) : UInt64
      count = @columns_substreams.slot_count_for(column_name).to_i64
      @budget.preflight_records(count)
      @budget.reserve_records(count)
      slots = @columns_substreams.slots_for(column_name)
      total = 0_u64
      @mark_index.mark_count.times do |mark|
        slots.each do |slot|
          first = @mark_index.position_at(mark, slot.index)
          finish = if slot.index + 1 < @mark_index.slot_count
                     @mark_index.position_at(mark, slot.index + 1)
                   else
                     @mark_index.position_at(mark + 1, 0)
                   end
          if finish < first
            raise CorruptPartError.new("Compact selected logical span has descending coordinates")
          end
          size = (finish - first).to_u64
          if size > UInt64::MAX - total
            raise CorruptPartError.new("Compact selected logical span overflows UInt64")
          end
          total += size
        end
      end
      total
    end

    # Internal metadata-only guard for the hidden UInt64 sibling used by the
    # Compact projection Count reader. Its one callback must span exactly
    # eight bytes per parent row on every mark, including marks outside a
    # selected value window.
    def validate_uint64_single_callback_spans!(column_name : String, expected_stream_name : String) : Nil
      validate_uint64_single_callback_span_and_slot!(column_name, expected_stream_name)
      nil
    end

    # The endpoint reader also needs the exact slot just validated. Returning
    # its index avoids constructing and retaining a second detached slot copy.
    def validate_uint64_single_callback_span_and_slot!(column_name : String, expected_stream_name : String) : Int32
      validate_fixed_width_single_callback_span_slot!(column_name, expected_stream_name, 8_u64, "UInt64 key")
    end

    # Authenticates the tuple entries needed by primary.cidx against every
    # leading UInt64 lane in one bounded physical read. The index grid is
    # already size-bounded by admission before this method is called; this
    # method independently derives the endpoint cardinality before allocating
    # the range tape.
    def validate_projection_uint64_index_endpoints!(key_names : Array(String), index_bytes : Bytes) : Nil
      unless @mode == CompactMarkFormat::Mrk4 && !key_names.empty? && @mark_index.mark_count > 0
        raise UnsupportedFormatError.new("Compact compressed projection index requires MRK4 UInt64 key lanes")
      end

      key_count = key_names.size.to_i64
      mark_count = @mark_index.mark_count.to_i64
      entry_count = mark_count + 1_i64
      if key_count <= 0 || entry_count <= 0 || key_count > Int64::MAX // sizeof(UInt64).to_i64
        raise CorruptPartError.new("Compact compressed primary index tuple cardinality overflows")
      end
      bytes_per_entry = key_count * sizeof(UInt64).to_i64
      if entry_count > PrimaryKeyIndex::MAX_INDEX_ENTRIES.to_i64 ||
         entry_count > PrimaryKeyIndex::MAX_INDEX_FILE_BYTES // bytes_per_entry
        raise CorruptPartError.new("Compact compressed primary index exceeds its tuple bound")
      end
      expected_bytes = entry_count * bytes_per_entry
      unless expected_bytes <= Int32::MAX && index_bytes.size.to_i64 == expected_bytes
        raise CorruptPartError.new("Compact compressed primary index byte size differs from its mark grid")
      end
      range_count = entry_count * key_count
      unless range_count <= Int32::MAX
        raise CorruptPartError.new("Compact compressed primary index endpoint count exceeds its reader bound")
      end

      # The range tape below and read_ranges' detached span/output descriptors
      # are both charged before allocation. read_ranges also charges the
      # touched frame headers, decode work, and result bytes against this same
      # context budget.
      if range_count > Int64::MAX // 2_i64
        raise CorruptPartError.new("Compact compressed primary index endpoint records overflow")
      end
      @budget.preflight_records(range_count * 2_i64)
      @budget.reserve_records(range_count)

      slot_indices = Array(Int32).new(key_names.size)
      key_names.each do |key_name|
        slot_indices << validate_uint64_single_callback_span_and_slot!(
          key_name,
          PhysicalStreamName.escape(key_name),
        )
      end

      ranges = Array({Int64, Int64}).new(range_count.to_i)
      mark_count.to_i.times do |mark|
        slot_indices.each do |slot_index|
          start = @mark_index.position_at(mark, slot_index)
          finish = if slot_index + 1 < @mark_index.slot_count
                     @mark_index.position_at(mark, slot_index + 1)
                   else
                     @mark_index.position_at(mark + 1, 0)
                   end
          if finish < start || finish - start < sizeof(UInt64).to_i64
            raise CorruptPartError.new("Compact compressed primary index mark-start endpoint is outside its key span")
          end
          ranges << {start, start + sizeof(UInt64).to_i64}
        end
      end

      slot_indices.each do |slot_index|
        start = @mark_index.position_at(mark_count.to_i - 1, slot_index)
        finish = if slot_index + 1 < @mark_index.slot_count
                   @mark_index.position_at(mark_count.to_i - 1, slot_index + 1)
                 else
                   @mark_index.position_at(mark_count.to_i, 0)
                 end
        if finish < start || finish - start < sizeof(UInt64).to_i64
          raise CorruptPartError.new("Compact compressed primary index terminal endpoint is outside its key span")
        end
        ranges << {finish - sizeof(UInt64).to_i64, finish}
      end

      endpoint_bytes = CompressedMarkReader.read_ranges(
        @data_input.data_path,
        @data_input.data_size,
        ranges,
        @budget,
      )
      unless endpoint_bytes.size.to_i64 == range_count
        raise CorruptPartError.new("Compact compressed primary index endpoint reader returned an incomplete tuple grid")
      end

      index_offset = 0
      endpoint_bytes.each_with_index do |actual_bytes, endpoint_index|
        unless actual_bytes.size == sizeof(UInt64)
          raise CorruptPartError.new("Compact compressed primary index endpoint is not one UInt64 value")
        end
        expected_value = IO::ByteFormat::LittleEndian.decode(UInt64, index_bytes[index_offset, sizeof(UInt64)])
        actual_value = IO::ByteFormat::LittleEndian.decode(UInt64, actual_bytes)
        unless expected_value == actual_value
          raise CorruptPartError.new("compressed primary index differs from the ordered Compact key marks")
        end
        index_offset += sizeof(UInt64)
      end
      unless index_offset.to_i64 == expected_bytes
        raise CorruptPartError.new("Compact compressed primary index did not validate every ordered tuple endpoint")
      end
      nil
    end

    # Projection aggregate admission uses this for fixed-width state lanes as
    # well as the hidden UInt64 key. Validation covers the complete physical
    # mark grid so windows and EOF reads cannot hide a malformed later span.
    def validate_fixed_width_single_callback_spans!(
      column_name : String,
      expected_stream_name : String,
      width : UInt64,
      lane_label : String,
    ) : Nil
      validate_fixed_width_single_callback_span_slot!(column_name, expected_stream_name, width, lane_label)
      nil
    end

    # :nodoc:
    # Validate one exact MRK4 stream even when its parent JSON column has
    # other callback streams. Every mark is checked before a caller can emit.
    def validate_fixed_width_stream_spans!(
      column_name : String,
      expected_stream_name : String,
      width : UInt64,
      lane_label : String,
    ) : Int32
      unless @mode.mrk4?
        raise UnsupportedFormatError.new("Compact #{lane_label} stream selection requires MRK4")
      end
      if width == 0_u64
        raise ArgumentError.new("Compact fixed-width stream width must be positive")
      end

      slot_count = @columns_substreams.slot_count_for(column_name)
      @budget.preflight_records(slot_count.to_i64)
      @budget.reserve_records(slot_count.to_i64)
      slot_index = @columns_substreams.unique_slot_index_for(column_name, expected_stream_name)
      validate_fixed_width_stream_mark_spans!(column_name, slot_index, expected_stream_name, width, lane_label)
      slot_index
    end

    # :nodoc:
    # Exact transient decoder-buffer upper bound for the frames a selected
    # mark may need. Whole ordinary frames decode into the result directly;
    # partial frames use their decoded size, and Multiple needs its 11-byte
    # nested-envelope overhead as well.
    def fixed_width_stream_workspace_bytes(
      column_name : String,
      slot_index : Int32,
      mark_index : Int,
      expected_stream_name : String,
      width : UInt64,
      lane_label : String,
    ) : UInt64
      start, finish, _ = validated_fixed_width_stream_mark_range(
        column_name,
        slot_index,
        mark_index,
        expected_stream_name,
        width,
        lane_label,
      )
      first, last = @mark_index.frame_index.touched_frame_bounds(start, finish)
      workspace_bytes = 0_u64
      frame_index = first
      while frame_index < last
        frame = @mark_index.frame_index.frames[frame_index]
        partial = frame.logical_start < start || frame.logical_end > finish
        if partial || frame.method == CompressedBlock::METHOD_MULTIPLE
          frame_bytes = frame.decompressed_size.to_u64
          if frame.method == CompressedBlock::METHOD_MULTIPLE
            frame_bytes = checked_add(frame_bytes, 11_u64)
          end
          workspace_bytes = frame_bytes if frame_bytes > workspace_bytes
        end
        frame_index += 1
      end
      workspace_bytes
    end

    # :nodoc:
    # Authenticate one exact fixed-width MRK4 stream mark into caller-owned
    # storage, preserving the ordinary frame checksum and transport path.
    def read_fixed_width_stream_mark_into(
      column_name : String,
      slot_index : Int32,
      mark_index : Int,
      expected_stream_name : String,
      width : UInt64,
      lane_label : String,
      destination : Bytes,
      workspace : CompressedBlock::DecodeWorkspace,
    ) : Nil
      start, finish, expected_bytes = validated_fixed_width_stream_mark_range(
        column_name,
        slot_index,
        mark_index,
        expected_stream_name,
        width,
        lane_label,
      )
      unless destination.size.to_u64 == expected_bytes
        raise CorruptPartError.new("Compact #{lane_label} destination width differs from its exact row width")
      end

      # The physical caller range and the transport range descriptor are
      # accounted separately, matching the existing direct UInt64 reader.
      @budget.preflight_records(2_i64)
      @budget.reserve_records(1_i64)
      @budget.preflight_file_bytes(@data_input.data_size)
      MMapDataSource.with_file(
        @data_input.data_path,
        @data_input.data_size,
        @budget.limits.max_file_bytes,
      ) do |data|
        @budget.reserve_file_bytes(@data_input.data_size)
        index = @mark_index.frame_index
        index.validate_data_geometry!(data, @budget.limits, @budget)
        CompressedMarkReader.read_range_into_indexed(
          data,
          index,
          start,
          finish,
          destination,
          workspace,
          @budget,
        )
      end
      nil
    end

    private def validate_fixed_width_single_callback_span_slot!(
      column_name : String,
      expected_stream_name : String,
      width : UInt64,
      lane_label : String,
    ) : Int32
      unless @mode.mrk4?
        raise UnsupportedFormatError.new("Compact fixed-width projection lane validation requires MRK4")
      end
      if width == 0_u64
        raise ArgumentError.new("Compact fixed-width projection lane width must be positive")
      end

      slot_count = @columns_substreams.slot_count_for(column_name)
      unless slot_count == 1
        raise CorruptPartError.new("Compact #{lane_label} span requires exactly one physical callback")
      end
      @budget.preflight_records(slot_count.to_i64)
      @budget.reserve_records(slot_count.to_i64)

      slots = @columns_substreams.slots_for(column_name)
      unless slots.size == 1
        raise CorruptPartError.new("Compact #{lane_label} span descriptor differs from its bounded slot count")
      end
      slot = slots[0]
      unless slot.stream_name == expected_stream_name
        raise CorruptPartError.new("Compact #{lane_label} callback identity differs from its expected span")
      end

      @mark_index.mark_count.times do |mark|
        rows = @mark_index.row_count_at(mark)
        if rows > UInt64::MAX // width
          raise CorruptPartError.new("Compact #{lane_label} span row width overflows")
        end
        expected_bytes = rows * width
        start = @mark_index.position_at(mark, slot.index)
        finish = if slot.index + 1 < @mark_index.slot_count
                   @mark_index.position_at(mark, slot.index + 1)
                 else
                   @mark_index.position_at(mark + 1, 0)
                 end
        if finish < start
          raise CorruptPartError.new("Compact #{lane_label} span has descending coordinates")
        end
        unless (finish - start).to_u64 == expected_bytes
          raise CorruptPartError.new("Compact #{lane_label} span differs from its exact row width")
        end
      end
      slot.index
    end

    def read_window(
      column_name : String,
      first_mark : Int,
      mark_count : Int,
    ) : CompactPartPhysicalWindow
      raise ArgumentError.new("first mark must be nonnegative") if first_mark < 0
      raise ArgumentError.new("mark count must be nonnegative") if mark_count < 0
      if first_mark > @mark_index.mark_count || mark_count > @mark_index.mark_count - first_mark
        raise ArgumentError.new("Compact mark selection is outside the grid")
      end
      if first_mark > Int32::MAX || mark_count > Int32::MAX
        raise ArgumentError.new("Compact mark selection exceeds supported in-memory domain")
      end

      slot_count = @columns_substreams.slot_count_for(column_name)
      shard_count = mark_count.to_i64 * slot_count.to_i64
      if shard_count > Int32::MAX || mark_count > Int32::MAX
        raise CorruptPartError.new("Compact window descriptor count exceeds supported in-memory domain")
      end
      # Include the detached per-window slot copy even for an empty window.
      # Context descriptors and selected-slot clones are charged before the
      # range tape is allocated; read_ranges consumes its own range-record
      # charge before making its detached output descriptors.
      descriptor_charge = mark_count.to_i64 + shard_count + slot_count.to_i64
      if shard_count > Int64::MAX - descriptor_charge
        raise CorruptPartError.new("Compact window descriptor count overflows")
      end
      @budget.preflight_records(descriptor_charge + shard_count)
      @budget.reserve_records(descriptor_charge)

      slots = @columns_substreams.slots_for(column_name)
      ranges = Array({Int64, Int64}).new(shard_count.to_i)
      mark_count.times do |window_index|
        mark = first_mark + window_index
        slots.each do |slot|
          start = @mark_index.position_at(mark, slot.index)
          finish = if slot.index + 1 < @mark_index.slot_count
                     @mark_index.position_at(mark, slot.index + 1)
                   else
                     @mark_index.position_at(mark + 1, 0)
                   end
          if finish < start
            raise CorruptPartError.new("Compact slot interval has descending logical coordinates")
          end
          ranges << {start, finish}
        end
      end

      shard_bytes = CompressedMarkReader.read_ranges(
        @data_input.data_path,
        @data_input.data_size,
        ranges,
        @budget
      )
      unless shard_bytes.size == ranges.size
        raise CorruptPartError.new("Compact physical reader returned an incomplete shard set")
      end

      row_offset = row_offset_at(first_mark)
      granules = Array(CompactPartPhysicalGranule).new(mark_count)
      shard_index = 0
      mark_count.times do |window_index|
        mark = first_mark + window_index
        row_count = @mark_index.row_count_at(mark)
        shards = Array(CompactPartPhysicalShard).new(slots.size)
        slots.each do |slot|
          start, finish = ranges[shard_index]
          shards << CompactPartPhysicalShard.new(
            slot.index,
            slot.stream_name,
            start,
            finish,
            shard_bytes[shard_index]
          )
          shard_index += 1
        end
        granules << CompactPartPhysicalGranule.new(mark.to_i32, row_offset, row_count, shards)
        if row_count > UInt64::MAX - row_offset
          raise CorruptPartError.new("Compact window row offset overflows")
        end
        row_offset += row_count
      end

      CompactPartPhysicalWindow.new(
        @mode,
        column_name,
        first_mark.to_i32,
        row_offset_at(first_mark),
        granules
      )
    end

    # Reads one admitted ordinary UInt64 mark without constructing detached
    # shard/granule/window copies. The caller supplies the slot index retained
    # during reader admission; this method rebinds it to the retained physical
    # roster, checks the exact selected-mark width, and authenticates only that
    # range through the normal compressed-frame reader.
    def read_uint64_mark(
      column_name : String,
      slot_index : Int32,
      mark_index : Int,
      expected_stream_name : String?,
      scan_image : CompactUInt64ScanImage? = nil,
    ) : Bytes
      start, finish, expected_bytes = validated_uint64_mark_range(
        column_name,
        slot_index,
        mark_index,
        expected_stream_name,
      )

      # One retained input range plus the output descriptor that read_ranges
      # reserves before allocating its result array.
      reserve_uint64_mark_range_records!
      if image = scan_image
        image.validate_context!(self)
        bytes = CompressedMarkReader.read_range_indexed(
          image.data,
          image.frame_index,
          start,
          finish,
          @budget,
        )
        unless bytes.size.to_u64 == expected_bytes
          raise CorruptPartError.new("Compact UInt64 reader returned an invalid selected mark width")
        end
        return bytes
      end
      ranges = [{start, finish}]
      authenticated = CompressedMarkReader.read_ranges(
        @data_input.data_path,
        @data_input.data_size,
        ranges,
        @budget,
      )
      unless authenticated.size == 1 && authenticated[0].size.to_u64 == expected_bytes
        raise CorruptPartError.new("Compact UInt64 reader returned an invalid selected mark")
      end
      authenticated[0]
    end

    # Authenticates one admitted ordinary UInt64 mark directly into a
    # caller-owned, aligned destination. The caller keeps this workspace alive
    # until all callback acknowledgements for the mark have returned.
    def read_uint64_mark_into(
      column_name : String,
      slot_index : Int32,
      mark_index : Int,
      expected_stream_name : String?,
      destination : Bytes,
      workspace : CompressedBlock::DecodeWorkspace,
      scan_image : CompactUInt64ScanImage? = nil,
    ) : Nil
      start, finish, expected_bytes = validated_uint64_mark_range(
        column_name,
        slot_index,
        mark_index,
        expected_stream_name,
      )
      unless destination.size.to_u64 == expected_bytes
        raise CorruptPartError.new("Compact UInt64 destination width differs from its exact row width")
      end

      # Match read_ranges' operation-level accounting: one caller range and
      # one transport range descriptor, plus the same touched frame headers.
      reserve_uint64_mark_range_records!
      if image = scan_image
        image.validate_context!(self)
        CompressedMarkReader.read_range_into_indexed(
          image.data,
          image.frame_index,
          start,
          finish,
          destination,
          workspace,
          @budget,
        )
        return nil
      end
      CompressedMarkReader.read_range_into(
        @data_input.data_path,
        @data_input.data_size,
        start,
        finish,
        destination,
        workspace,
        @budget,
      )
      nil
    end

    private def validate_fixed_width_stream_mark_spans!(
      column_name : String,
      slot_index : Int32,
      expected_stream_name : String,
      width : UInt64,
      lane_label : String,
    ) : Nil
      @mark_index.mark_count.times do |mark_index|
        validated_fixed_width_stream_mark_range(
          column_name,
          slot_index,
          mark_index,
          expected_stream_name,
          width,
          lane_label,
        )
      end
      nil
    end

    private def validated_fixed_width_stream_mark_range(
      column_name : String,
      slot_index : Int32,
      mark_index : Int,
      expected_stream_name : String,
      width : UInt64,
      lane_label : String,
    ) : {Int64, Int64, UInt64}
      unless @mode.mrk4?
        raise UnsupportedFormatError.new("Compact #{lane_label} stream selection requires MRK4")
      end
      if width == 0_u64
        raise ArgumentError.new("Compact fixed-width stream width must be positive")
      end
      unless mark_index >= 0 && mark_index < @mark_index.mark_count
        raise ArgumentError.new("Compact #{lane_label} mark selection is outside the grid")
      end
      unless @columns_substreams.slot_matches?(slot_index, column_name, expected_stream_name)
        raise CorruptPartError.new("Compact #{lane_label} slot identity differs from its admitted roster")
      end

      rows = @mark_index.row_count_at(mark_index)
      if rows > UInt64::MAX // width
        raise CorruptPartError.new("Compact #{lane_label} mark width overflows")
      end
      expected_bytes = rows * width
      if expected_bytes > Int32::MAX.to_u64
        raise CorruptPartError.new("Compact #{lane_label} mark exceeds its in-memory bound")
      end
      start = @mark_index.position_at(mark_index, slot_index)
      finish = if slot_index + 1 < @mark_index.slot_count
                 @mark_index.position_at(mark_index, slot_index + 1)
               else
                 @mark_index.position_at(mark_index + 1, 0)
               end
      if finish < start
        raise CorruptPartError.new("Compact #{lane_label} mark has descending coordinates")
      end
      unless (finish - start).to_u64 == expected_bytes
        raise CorruptPartError.new("Compact #{lane_label} mark span differs from its exact row width")
      end
      {start, finish, expected_bytes}
    end

    private def validated_uint64_mark_range(
      column_name : String,
      slot_index : Int32,
      mark_index : Int,
      expected_stream_name : String?,
    ) : {Int64, Int64, UInt64}
      unless mark_index >= 0 && mark_index < @mark_index.mark_count
        raise ArgumentError.new("Compact UInt64 mark selection is outside the grid")
      end
      case @mode
      when CompactMarkFormat::Mrk3
        unless expected_stream_name.nil?
          raise CorruptPartError.new("Compact MRK3 UInt64 callback cannot have a name")
        end
      when CompactMarkFormat::Mrk4
        unless expected_stream_name
          raise CorruptPartError.new("Compact MRK4 UInt64 callback has no expected name")
        end
      end
      unless @columns_substreams.slot_matches?(slot_index, column_name, expected_stream_name)
        raise CorruptPartError.new("Compact UInt64 slot identity differs from its admitted roster")
      end

      rows = @mark_index.row_count_at(mark_index)
      if rows > UInt64::MAX // sizeof(UInt64).to_u64
        raise CorruptPartError.new("Compact UInt64 mark width overflows")
      end
      expected_bytes = rows * sizeof(UInt64).to_u64
      if expected_bytes > Int32::MAX.to_u64
        raise CorruptPartError.new("Compact UInt64 mark exceeds its in-memory bound")
      end
      start = @mark_index.position_at(mark_index, slot_index)
      finish = if slot_index + 1 < @mark_index.slot_count
                 @mark_index.position_at(mark_index, slot_index + 1)
               else
                 @mark_index.position_at(mark_index + 1, 0)
               end
      if finish < start
        raise CorruptPartError.new("Compact UInt64 mark has descending coordinates")
      end
      unless (finish - start).to_u64 == expected_bytes
        raise CorruptPartError.new("Compact UInt64 mark span differs from its exact row width")
      end
      {start, finish, expected_bytes}
    end

    private def reserve_uint64_mark_range_records! : Nil
      @budget.preflight_records(2_i64)
      @budget.reserve_records(1_i64)
      nil
    end

    private def row_offset_at(mark : Int) : UInt64
      offset = 0_u64
      mark.times do |index|
        rows = @mark_index.row_count_at(index)
        if rows > UInt64::MAX - offset
          raise CorruptPartError.new("Compact row offset overflows")
        end
        offset += rows
      end
      offset
    end

    private def raise_invalid_mrk3_site! : Nil
      raise CorruptPartError.new("Compact MRK3 prepared site is not bound to its selected root mark slot")
    end

    private def grid_contains_interval?(slot_index : Int, start : Int64, finish : Int64) : Bool
      return false if start < 0 || finish < start
      @mark_index.mark_count.times do |mark|
        saved_start = @mark_index.position_at(mark, slot_index)
        saved_finish = if slot_index + 1 < @mark_index.slot_count
                         @mark_index.position_at(mark, slot_index + 1)
                       else
                         @mark_index.position_at(mark + 1, 0)
                       end
        return true if saved_start == start && saved_finish == finish
      end
      false
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      if right > UInt64::MAX - left
        raise CorruptPartError.new("Compact physical context workspace estimate overflows UInt64")
      end
      left + right
    end
  end
end
