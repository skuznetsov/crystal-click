module CrystalClick
  # Resolves callback-local Object coordinates inside one assembled Compact
  # raw granule. The owner is deliberately per mark: a target can only name a
  # callback in the same encoded JSON column and the same mark.
  class CompactGranuleRelocationPlan
    private struct Patch
      getter source_offset : UInt64
      getter source_end : UInt64
      getter target_query_index : Int32

      def initialize(@source_offset : UInt64, @source_end : UInt64, @target_query_index : Int32)
      end
    end

    @first_aux_query_index : Int32
    @raw_size : UInt64
    @target_offsets : Array(UInt64)
    @patches : Array(Patch)
    @patched : Bool

    def initialize(
      columns : Array(CompactPartEncodedColumn),
      mark_index : Int32,
      @first_aux_query_index : Int32,
      @raw_size : UInt64,
      column_raw_starts : Array(UInt64),
      codec_budget : BinaryCodecBudget,
    )
      unless codec_budget.writing?
        raise ArgumentError.new("Compact relocation planning requires a write-direction codec budget")
      end
      unless mark_index >= 0 && !columns.empty? && columns.size == column_raw_starts.size
        raise ArgumentError.new("Compact relocation plan differs from its encoded-column boundary grid")
      end
      unless @first_aux_query_index > 0 && column_raw_starts[0] == 0_u64
        raise ArgumentError.new("Compact relocation plan has an invalid auxiliary-query or raw start")
      end

      previous_start = 0_u64
      column_raw_starts.each do |start|
        unless start >= previous_start && start <= @raw_size
          raise UnsupportedFormatError.new("Compact relocation column starts are outside the raw granule")
        end
        previous_start = start
      end

      relocation_count = 0_u64
      relocation_column_count = 0_u64
      callback_count = 0_u64
      callback_name_bytes = 0_u64
      relocation_name_bytes = 0_u64
      columns.each do |column|
        json_column = column.as?(CompactJsonEncodedColumn)
        next unless json_column
        count = json_column.callback_relocation_count_at(mark_index)
        next if count == 0
        relocation_column_count = checked_add(relocation_column_count, 1_u64)
        relocation_count = checked_add(relocation_count, count.to_u64)
        callback_count = checked_add(callback_count, json_column.callback_event_count.to_u64)
        json_column.each_callback_fragment_at(mark_index) do |name, _bytes|
          callback_name_bytes = checked_add(callback_name_bytes, name.bytesize.to_u64)
        end
        json_column.each_callback_relocation_at(mark_index) do |relocation|
          relocation_name_bytes = checked_add(relocation_name_bytes, relocation.source_callback_byte_size.to_u64)
          relocation_name_bytes = checked_add(relocation_name_bytes, relocation.target_callback_byte_size.to_u64)
        end
      end
      unless relocation_count > 0_u64 && relocation_count <= Int32::MAX.to_u64
        raise ArgumentError.new("Compact relocation plan requires a bounded nonempty relocation roster")
      end
      if relocation_count > Int32::MAX.to_u64 - @first_aux_query_index.to_u64
        raise UnsupportedFormatError.new("Compact relocation query index exceeds the in-memory domain")
      end

      patch_count = relocation_count
      validation_work = relocation_validation_work(patch_count)
      # Each relocation-name accessor returns a detached String. Account for
      # both temporary names per patch before interval lookups allocate them.
      temporary_name_nodes = checked_multiply(patch_count, 2_u64)
      future_nodes = checked_add(
        checked_add(checked_add(callback_count, relocation_column_count), 2_u64),
        temporary_name_nodes,
      )
      future_elements = checked_add(callback_count, checked_multiply(patch_count, 2_u64))
      future_elements = checked_add(future_elements, validation_work)
      # Hashing final physical callback names is bounded by their byte length.
      future_elements = checked_add(future_elements, callback_name_bytes)
      future_elements = checked_add(future_elements, relocation_name_bytes)
      codec_budget.ensure_future_nodes(future_nodes)
      codec_budget.ensure_future_elements(future_elements)
      codec_budget.ensure_wire_bytes(relocation_name_bytes)
      future_nodes.times { codec_budget.charge_node }
      codec_budget.charge_elements(future_elements) if future_elements > 0_u64
      codec_budget.charge_wire_bytes(relocation_name_bytes) if relocation_name_bytes > 0_u64

      @target_offsets = Array(UInt64).new(patch_count.to_i)
      @patches = Array(Patch).new(patch_count.to_i)
      @patched = false
      columns.each_with_index do |column, column_index|
        json_column = column.as?(CompactJsonEncodedColumn)
        next unless json_column
        next if json_column.callback_relocation_count_at(mark_index) == 0

        column_start = column_raw_starts[column_index]
        column_end = column_index + 1 < column_raw_starts.size ? column_raw_starts[column_index + 1] : @raw_size
        intervals = Hash(String, Tuple(UInt64, UInt64)).new
        callback_offset = column_start
        callback_seen = 0
        json_column.each_callback_fragment_at(mark_index) do |name, bytes|
          if intervals.has_key?(name)
            raise UnsupportedFormatError.new("Compact JSON relocation column has duplicate callback names")
          end
          intervals[name] = {callback_offset, bytes.size.to_u64}
          callback_offset = checked_add(callback_offset, bytes.size.to_u64)
          callback_seen += 1
        end
        unless callback_seen == json_column.callback_event_count && callback_offset == column_end
          raise UnsupportedFormatError.new("Compact JSON callback extents differ from their physical column interval")
        end

        json_column.each_callback_relocation_at(mark_index) do |relocation|
          source_name = relocation.source_callback
          target_name = relocation.target_callback
          source = intervals[source_name]? ||
                   raise(UnsupportedFormatError.new("Compact relocation source callback is outside its JSON column"))
          target = intervals[target_name]? ||
                   raise(UnsupportedFormatError.new("Compact relocation target callback is outside its JSON column"))
          source_field_end = checked_add(relocation.source_offset, ObjectSharedInlineCallbackRelocation::COORDINATE_BYTES)
          unless source_field_end <= source[1] && relocation.target_offset <= target[1]
            raise UnsupportedFormatError.new("Compact callback relocation exceeds its raw callback interval")
          end
          source_offset = checked_add(source[0], relocation.source_offset)
          source_end = checked_add(source_offset, ObjectSharedInlineCallbackRelocation::COORDINATE_BYTES)
          target_offset = checked_add(target[0], relocation.target_offset)
          unless source_end <= @raw_size && target_offset <= @raw_size
            raise UnsupportedFormatError.new("Compact callback relocation exceeds its raw granule")
          end
          target_query_index = @first_aux_query_index + @target_offsets.size.to_i32
          @target_offsets << target_offset
          @patches << Patch.new(source_offset, source_end, target_query_index)
        end
      end
      unless @target_offsets.size.to_u64 == relocation_count && @patches.size.to_u64 == relocation_count
        raise UnsupportedFormatError.new("Compact relocation query and patch rosters differ")
      end

      @patches.sort! { |left, right| left.source_offset <=> right.source_offset }
      @patches.each_cons(2) do |pair|
        if pair[1].source_offset < pair[0].source_end
          raise UnsupportedFormatError.new("Compact relocation source fields overlap in the assembled granule")
        end
      end
    end

    def target_query_count : Int32
      @target_offsets.size
    end

    # Auxiliary queries follow the complete physical slot roster, including
    # the EOF query. They never become MRK3/MRK4 fields.
    def append_target_queries!(queries : Array(UInt64)) : Nil
      unless queries.size == @first_aux_query_index
        raise UnsupportedFormatError.new("Compact relocation targets must follow the physical EOF query")
      end
      @target_offsets.each { |offset| queries << offset }
      unless queries.size == @first_aux_query_index + @target_offsets.size
        raise UnsupportedFormatError.new("Compact relocation query roster changed while appending targets")
      end
      nil
    end

    # Patch only a private, fully assembled granule after literal frame
    # coordinates are known and before its bytes are hashed or compressed.
    def patch!(
      raw_segment : Bytes,
      positions : Array(Tuple(UInt64, UInt64)),
      compressed_base : UInt64,
      compressed_limit : UInt64,
      frame_bytes : Int,
    ) : Nil
      if @patched
        raise UnsupportedFormatError.new("Compact relocation plan cannot patch a granule more than once")
      end
      unless raw_segment.size.to_u64 == @raw_size &&
             positions.size == @first_aux_query_index + @target_offsets.size
        raise UnsupportedFormatError.new("Compact relocation patch grid differs from its owning granule")
      end
      unless compressed_base <= compressed_limit
        raise UnsupportedFormatError.new("Compact relocation compressed base exceeds the data file")
      end
      unless frame_bytes > 0 && frame_bytes <= Int32::MAX
        raise ArgumentError.new("Compact relocation frame size must be a positive Int32 value")
      end
      frame_limit = frame_bytes.to_u64
      positions.each do |position|
        if position[1] >= frame_limit
          raise UnsupportedFormatError.new("Compact relocation coordinate exceeds its literal frame")
        end
      end

      eof_query_index = @first_aux_query_index - 1
      eof_position = positions[eof_query_index]? ||
                     raise(UnsupportedFormatError.new("Compact relocation granule EOF position is missing"))
      eof_compressed_offset = eof_position[0]
      eof_frame_offset = eof_position[1]
      unless eof_frame_offset == 0_u64
        raise UnsupportedFormatError.new("Compact relocation granule EOF is not frame-aligned")
      end
      global_eof_offset = checked_add(compressed_base, eof_compressed_offset)
      unless global_eof_offset <= compressed_limit
        raise UnsupportedFormatError.new("Compact relocation granule EOF exceeds the compressed data file")
      end

      # Validate every source and target before mutating even the first field.
      # A malformed later target must not leave a partially patched raw tape.
      @patches.each do |patch|
        if patch.source_end > raw_segment.size.to_u64
          raise UnsupportedFormatError.new("Compact relocation source field is outside its assembled granule")
        end
        coordinate = positions[patch.target_query_index]? ||
                     raise(UnsupportedFormatError.new("Compact relocation target position is missing"))
        unless coordinate[0] < eof_compressed_offset ||
               (coordinate[0] == eof_compressed_offset && coordinate[1] <= eof_frame_offset)
          raise UnsupportedFormatError.new("Compact relocation target exceeds its owning granule EOF")
        end
        global_compressed_offset = checked_add(compressed_base, coordinate[0])
        if global_compressed_offset > compressed_limit
          raise UnsupportedFormatError.new("Compact relocation target exceeds the compressed data file")
        end
      end

      @patches.each do |patch|
        coordinate = positions[patch.target_query_index]
        global_compressed_offset = compressed_base + coordinate[0]
        write_u64_le(raw_segment, patch.source_offset.to_i, global_compressed_offset)
        write_u64_le(raw_segment, patch.source_offset.to_i + 8, coordinate[1])
      end
      @patched = true
      nil
    end

    private def relocation_validation_work(count : UInt64) : UInt64
      return 0_u64 if count == 0_u64
      levels = 0_u64
      remaining = count - 1_u64
      while remaining > 0_u64
        levels = checked_add(levels, 1_u64)
        remaining >>= 1
      end
      checked_add(checked_multiply(count, 3_u64), checked_multiply(count, levels))
    end

    private def write_u64_le(bytes : Bytes, offset : Int, value : UInt64) : Nil
      8.times do |index|
        bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8
      end
      nil
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      if right > UInt64::MAX - left
        raise UnsupportedFormatError.new("Compact relocation arithmetic overflows UInt64")
      end
      left + right
    end

    private def checked_multiply(left : UInt64, right : UInt64) : UInt64
      if left > 0_u64 && right > UInt64::MAX // left
        raise UnsupportedFormatError.new("Compact relocation work overflows UInt64")
      end
      left * right
    end
  end
end
