module CrystalClick
  # PREWHERE receipt for one root Advanced MRK4 JSON column. The key predicate
  # is evaluated before selected JSON spans are captured; only matching
  # absolute marks retain JSON owners and mark-local matching row ordinals.
  class CompactFilteredJsonPartPlan
    getter json_plan : CompactStaticJsonAdvancedPartPlan?

    @reader : CompactStaticJsonBulkColumnReader
    @mark_indices : Array(Int32)
    @row_indices : Array(Array(Int32))
    @part_row_offsets : Array(UInt64)
    @key_frames : Array(CompressedFrameFingerprint)
    @retained_selection_bytes : UInt64

    def initialize(
      @reader : CompactStaticJsonBulkColumnReader,
      @json_plan : CompactStaticJsonAdvancedPartPlan?,
      filter_column : String,
      mark_indices : Array(Int32),
      row_indices : Array(Array(Int32)),
      part_row_offsets : Array(UInt64),
      filter_capture : CompactPartPhysicalWindowCapture,
    )
      @reader.validate_filter_capture!(filter_capture, filter_column)
      unless mark_indices.size == row_indices.size && mark_indices.size == part_row_offsets.size
        raise CorruptPartError.new("Compact filtered JSON receipt arrays differ in cardinality")
      end
      if plan = @json_plan
        plan.validate_reader!(@reader)
        unless plan.mark_count == @reader.mark_count && plan.companion_columns == [filter_column] &&
               plan.prepared_mark_indices == mark_indices
          raise CorruptPartError.new("Compact filtered JSON receipt differs from its selected Advanced plan")
        end
      elsif !mark_indices.empty?
        raise CorruptPartError.new("Compact filtered JSON receipt omitted a nonempty JSON plan")
      end

      @mark_indices = mark_indices.dup
      @row_indices = Array(Array(Int32)).new(row_indices.size)
      @part_row_offsets = part_row_offsets.dup
      @key_frames = @json_plan ? [] of CompressedFrameFingerprint : filter_capture.authenticated_frames
      previous = -1_i32
      mark_indices.each_with_index do |mark, ordinal|
        unless mark > previous && mark < @reader.mark_count
          raise CorruptPartError.new("Compact filtered JSON marks are unordered or outside the physical grid")
        end
        unless plan = @json_plan
          raise CorruptPartError.new("Compact filtered JSON mark has no selected Advanced plan")
        end
        unless filter_capture.root_mark_row_offset(mark) == part_row_offsets[ordinal]
          raise CorruptPartError.new("Compact filtered JSON part offset differs from its authenticated physical granule")
        end
        if row_indices[ordinal].empty?
          raise CorruptPartError.new("Compact filtered JSON selected mark has no matching row")
        end
        row_indices[ordinal].each_with_index do |row_index, row_ordinal|
          unless row_index >= 0 && plan.mark_row_count_at(mark) > row_index.to_u64 &&
                 (row_ordinal == 0 || row_index > row_indices[ordinal][row_ordinal - 1])
            raise CorruptPartError.new("Compact filtered JSON row indices are unordered or duplicated")
          end
        end
        @row_indices << row_indices[ordinal].dup
        previous = mark
      end
      @retained_selection_bytes = calculate_selection_workspace_bytes
    end

    # A detached copy protects the sorted absolute mark order from callers.
    def mark_indices : Array(Int32)
      @mark_indices.dup
    end

    # Returns a read-only slice of matching row ordinals relative to `mark`.
    # Unselected marks have an empty slice.
    def row_indices_for(mark : Int) : Slice(Int32)
      ordinal = selected_ordinal(mark)
      return Slice(Int32).new(Pointer(Int32).null, 0, read_only: true) unless ordinal
      rows = @row_indices[ordinal]
      Slice(Int32).new(rows.to_unsafe, rows.size, read_only: true)
    end

    # Absolute part-row starting offset retained from the authenticated sparse
    # physical granule. Only selected marks have a result offset.
    def part_row_offset_for(mark : Int) : UInt64
      ordinal = selected_ordinal(mark) ||
                raise(ArgumentError.new("Compact filtered JSON part offset requested for an unselected mark"))
      @part_row_offsets[ordinal]
    end

    # Revalidates the source before delivery. For nonempty selections the
    # Advanced JSON plan owns the union of filter and selected JSON frame
    # receipts; empty selections still validate the key frames that determined
    # the negative predicate result plus the admitted metadata.
    def validate_source! : Nil
      if plan = @json_plan
        plan.validate_source!
      else
        @reader.validate_filtered_source!(@key_frames)
      end
      nil
    end

    # Includes the retained Advanced JSON plan and every selection owner. The
    # parent table uses this before allocating worker output arenas.
    def retained_workspace_bytes : UInt64
      bytes = @retained_selection_bytes
      if plan = @json_plan
        bytes = checked_add(bytes, plan.retained_workspace_bytes)
      end
      bytes
    end

    private def selected_ordinal(mark : Int) : Int32?
      return nil if mark < 0 || mark >= @reader.mark_count
      low = 0
      high = @mark_indices.size - 1
      while low <= high
        middle = low + (high - low) // 2
        candidate = @mark_indices[middle]
        if candidate == mark
          return middle.to_i32
        elsif candidate < mark
          low = middle + 1
        else
          high = middle - 1
        end
      end
      nil
    end

    private def calculate_selection_workspace_bytes : UInt64
      bytes = instance_sizeof(CompactFilteredJsonPartPlan).to_u64
      bytes = checked_add(bytes, instance_sizeof(Array(Int32)).to_u64)
      bytes = checked_add(bytes, checked_multiply(@mark_indices.size.to_u64, sizeof(Int32).to_u64))
      bytes = checked_add(bytes, instance_sizeof(Array(Array(Int32))).to_u64)
      bytes = checked_add(bytes, checked_multiply(@row_indices.size.to_u64, sizeof(Pointer(Array(Int32))).to_u64))
      @row_indices.each do |rows|
        bytes = checked_add(bytes, instance_sizeof(Array(Int32)).to_u64)
        bytes = checked_add(bytes, checked_multiply(rows.size.to_u64, sizeof(Int32).to_u64))
      end
      bytes = checked_add(bytes, instance_sizeof(Array(UInt64)).to_u64)
      bytes = checked_add(bytes, checked_multiply(@part_row_offsets.size.to_u64, sizeof(UInt64).to_u64))
      bytes = checked_add(bytes, instance_sizeof(Array(CompressedFrameFingerprint)).to_u64)
      bytes = checked_add(bytes,
        checked_multiply(@key_frames.size.to_u64, sizeof(CompressedFrameFingerprint).to_u64))
      bytes
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      raise CorruptPartError.new("Compact filtered JSON workspace overflows") if right > UInt64::MAX - left
      left + right
    end

    private def checked_multiply(left : UInt64, right : UInt64) : UInt64
      raise CorruptPartError.new("Compact filtered JSON workspace overflows") if left > 0_u64 && right > UInt64::MAX // left
      left * right
    end
  end
end
