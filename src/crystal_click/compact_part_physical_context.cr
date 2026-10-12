module CrystalClick
  # Schema-neutral reader for a complete plain Compact physical mark grid.
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

    private def initialize(
      @mode : CompactMarkFormat,
      @row_count : UInt64,
      @columns_substreams : CompactColumnsSubstreams,
      @mark_index : CompactMarkIndex,
      @data_input : PartPhysicalInput,
      @budget : CompressedStreamBudget,
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

      mark3_size = source.checksum_size_declaration("data.mrk3")
      mark4_size = source.checksum_size_declaration("data.mrk4")
      if mark3_size && mark4_size
        raise CorruptPartError.new("part declares both Compact mrk3 and mrk4 files")
      end

      unsupported_marks_present = false
      checksums.entries.each_key do |name|
        if name.starts_with?("data.cmrk") ||
           (name.starts_with?("data.mrk") && name != "data.mrk3" && name != "data.mrk4")
          unsupported_marks_present = true
          break
        end
      end
      if unsupported_marks_present
        raise UnsupportedFormatError.new("unsupported Compact mark layout")
      end
      unless mark3_size || mark4_size
        raise CorruptPartError.new("part does not declare a Compact mrk3 or mrk4 file")
      end

      mode, marks_name = if mark3_size
                           {CompactMarkFormat::Mrk3, "data.mrk3"}
                         elsif mark4_size
                           {CompactMarkFormat::Mrk4, "data.mrk4"}
                         else
                           raise CorruptPartError.new("part does not declare a Compact mrk3 or mrk4 file")
                         end

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

      input = source.physical_input("data.bin", marks_name)
      index = CompactMarkIndex.read(input, roster, row_count, budget)
      new(mode, row_count, roster, index, input, budget)
    end

    def columns : Array({String, String})
      @columns_substreams.columns
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
