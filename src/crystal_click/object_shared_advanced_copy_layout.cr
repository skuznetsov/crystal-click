module CrystalClick
  # Joins chunk-local Copy lanes across logical chunks and physical parent
  # marks, then reverses that framing without resetting either caller budget.
  module ObjectSharedAdvancedCopyLayout
    COPY_LANES = ["sizes", "indexes", "values"]

    private struct ChunkShape
      getter row_count : UInt64
      getter dictionary_count : UInt64

      def initialize(@row_count : UInt64, @dictionary_count : UInt64)
      end
    end

    private struct CopyExtent
      getter sizes_start : Int32
      getter sizes_size : Int32
      getter indexes_start : Int32
      getter indexes_size : Int32
      getter values_start : Int32
      getter values_size : Int32

      def initialize(
        @sizes_start : Int32,
        @sizes_size : Int32,
        @indexes_start : Int32,
        @indexes_size : Int32,
        @values_start : Int32,
        @values_size : Int32,
      )
      end
    end

    def self.encode(
      chunks_by_parent : Array(Array(ObjectSharedAdvancedChunk)),
      physical_rows : Array(UInt64),
      codec_budget : BinaryCodecBudget,
      transport_budget : CompressedStreamBudget,
      frame_bytes : Int = 4096,
    ) : Hash(String, CompressedMarkFiles)
      unless codec_budget.writing?
        raise ArgumentError.new("Object shared Copy layout encode requires a write-direction codec budget")
      end
      transport_budget.ensure_direction(true)
      codec_budget.ensure_depth(1)
      total_chunks, visit_count = preflight_encode_visits(chunks_by_parent, physical_rows, codec_budget)
      validate_encode_grid!(chunks_by_parent, physical_rows)

      parent_lane_sizes, lane_totals, total_wire_bytes, measured_chunks = measure_encode_lanes(chunks_by_parent)
      unless measured_chunks == total_chunks
        raise UnsupportedFormatError.new("Object shared Copy chunk schedule changed during preflight")
      end
      codec_budget.ensure_wire_bytes(total_wire_bytes)
      codec_budget.ensure_future_nodes(visit_count)
      codec_budget.ensure_future_elements(visit_count)
      CompressedMarkWriter.preflight_batch(
        lane_totals,
        physical_rows.size + 1,
        frame_bytes,
        transport_budget,
      )

      # The W192 codec charged semantic Copy serialization. Charge these
      # bytes again as the distinct physical-lane assembly operation before
      # requesting detached getters or allocating concatenated lane buffers.
      codec_budget.charge_wire_bytes(total_wire_bytes)
      codec_budget.charge_elements(visit_count)
      visit_count.times { codec_budget.charge_node }

      files = Hash(String, CompressedMarkFiles).new
      COPY_LANES.each_with_index do |name, lane_index|
        raw, offsets = materialize_lane(
          chunks_by_parent,
          lane_index,
          parent_lane_sizes,
          lane_totals[lane_index],
        )
        files[name] = CompressedMarkWriter.encode(
          raw,
          offsets,
          physical_rows,
          frame_bytes: frame_bytes,
          budget: transport_budget,
        )
      end
      files
    end

    # Returns detached raw Copy roles without compressing them independently.
    # The parent interval table is retained so a containing Data writer can
    # authenticate each target offset before resolving inline mark fields.
    def self.materialize_inline_raw(
      chunks_by_parent : Array(Array(ObjectSharedAdvancedChunk)),
      physical_rows : Array(UInt64),
      codec_budget : BinaryCodecBudget,
    ) : ObjectSharedAdvancedCopyRawLayout
      unless codec_budget.writing?
        raise ArgumentError.new("Object shared Copy raw materialization requires a write-direction codec budget")
      end
      codec_budget.ensure_depth(1)
      total_chunks, visit_count = preflight_encode_visits(chunks_by_parent, physical_rows, codec_budget)
      validate_encode_grid!(chunks_by_parent, physical_rows)

      parent_lane_sizes, lane_totals, total_wire_bytes, measured_chunks = measure_encode_lanes(chunks_by_parent)
      unless measured_chunks == total_chunks
        raise UnsupportedFormatError.new("Object shared Copy chunk schedule changed during raw preflight")
      end
      codec_budget.ensure_wire_bytes(total_wire_bytes)
      codec_budget.ensure_future_nodes(visit_count)
      codec_budget.ensure_future_elements(visit_count)

      if total_wire_bytes > UInt64::MAX // 2_u64
        raise UnsupportedFormatError.new("Object shared Copy raw materialization size overflows")
      end
      codec_budget.ensure_wire_bytes(total_wire_bytes * 2_u64)
      codec_budget.charge_wire_bytes(total_wire_bytes) if total_wire_bytes > 0_u64
      visit_count.times { codec_budget.charge_node }
      codec_budget.charge_elements(visit_count) if visit_count > 0_u64

      lanes = Hash(String, Bytes).new(initial_capacity: COPY_LANES.size)
      offsets_by_lane = Hash(String, Array(UInt64)).new(initial_capacity: COPY_LANES.size)
      COPY_LANES.each_with_index do |name, lane_index|
        raw, offsets = materialize_lane(
          chunks_by_parent,
          lane_index.to_i32,
          parent_lane_sizes,
          lane_totals[lane_index],
        )
        lanes[name] = raw
        offsets_by_lane[name] = offsets
      end
      ObjectSharedAdvancedCopyRawLayout.new(lanes, offsets_by_lane, codec_budget)
    end

    def self.decode(
      copy_inputs : Hash(String, ObjectSharedPhysicalLaneInput),
      bucket_parents : Array(Array(ObjectSharedPhysicalParentMark)),
      expected_parent_rows : Array(UInt64),
      codec_budget : BinaryCodecBudget,
      transport_budget : CompressedStreamBudget,
    ) : Array(Array(ObjectSharedCopyStreams))
      if codec_budget.writing?
        raise ArgumentError.new("Object shared Copy layout decode requires a read-direction codec budget")
      end
      transport_budget.ensure_direction(false)
      codec_budget.ensure_depth(1)
      validate_copy_inputs!(copy_inputs)
      codec_budget.ensure_future_elements(expected_parent_rows.size.to_u64)
      codec_budget.ensure_future_nodes(expected_parent_rows.size.to_u64)
      shapes, total_chunks = measure_decode_shapes(bucket_parents, expected_parent_rows, codec_budget)

      readers = Hash(String, ObjectSharedPhysicalLaneReader).new
      COPY_LANES.each do |name|
        readers[name] = ObjectSharedPhysicalLaneReader.new(
          name,
          copy_inputs[name],
          expected_parent_rows,
          codec_budget,
          transport_budget,
        )
      end
      sizes_reader = readers["sizes"]
      indexes_reader = readers["indexes"]
      values_reader = readers["values"]

      extents = scan_chunk_extents(
        shapes,
        sizes_reader,
        indexes_reader,
        values_reader,
        codec_budget,
      )
      output_bytes = total_extent_bytes(extents)
      # lane_slice creates detached bytes, then ObjectSharedCopyStreams takes
      # its own defensive copy. Count both logical materialization passes
      # before creating either set of chunk buffers.
      materialization_work = checked_multiply(output_bytes, 2_u64, false,
        "Copy detached stream materialization")
      codec_budget.ensure_wire_bytes(materialization_work)
      codec_budget.charge_wire_bytes(materialization_work)
      codec_budget.ensure_future_elements(expected_parent_rows.size.to_u64)
      codec_budget.ensure_future_nodes(total_chunks)

      result = Array(Array(ObjectSharedCopyStreams)).new(expected_parent_rows.size)
      extents.each do |parent_extents|
        parent_streams = Array(ObjectSharedCopyStreams).new(parent_extents.size)
        parent_extents.each do |extent|
          sizes = lane_slice(sizes_reader, extent.sizes_start, extent.sizes_size)
          indexes = lane_slice(indexes_reader, extent.indexes_start, extent.indexes_size)
          values = lane_slice(values_reader, extent.values_start, extent.values_size)
          parent_streams << ObjectSharedCopyStreams.new(sizes, indexes, values)
          codec_budget.charge_node
        end
        result << parent_streams
      end
      result
    end

    # Reverses the global Copy callbacks captured from one inline child Data
    # envelope. The structure-derived parent/chunk schedule supplies the
    # boundaries; no synthetic per-parent marks are introduced for these
    # uncompressed callback roles.
    def self.decode_inline(
      views : Hash(String, ObjectSharedInlineRoleReadView),
      bucket_parents : Array(Array(ObjectSharedPhysicalParentMark)),
      expected_parent_rows : Array(UInt64),
      budget : BinaryCodecBudget,
    ) : Array(Array(ObjectSharedCopyStreams))
      if budget.writing?
        raise ArgumentError.new("inline Object shared Copy decode requires a read-direction budget")
      end
      budget.ensure_depth(1)
      unless views.size == COPY_LANES.size && COPY_LANES.all? { |name| views.has_key?(name) }
        raise CorruptPartError.new("inline Object shared Copy role roster is incomplete or has extra roles")
      end
      first_context = nil.as(ObjectSharedInlineCoordinateContext?)
      COPY_LANES.each do |name|
        view = views[name]
        unless view.role_name == name && view.authenticated_context? && view.segment_count > 0
          raise CorruptPartError.new("inline Object shared Copy role has invalid provenance")
        end
        context = view.segment_at(0).context
        if existing = first_context
          unless view.same_context?(existing)
            raise CorruptPartError.new("inline Object shared Copy roles do not share one authenticated Data path")
          end
        else
          first_context = context
        end
      end
      budget.ensure_future_elements(expected_parent_rows.size.to_u64)
      budget.ensure_future_nodes(expected_parent_rows.size.to_u64)
      shapes, total_chunks = measure_decode_shapes(bucket_parents, expected_parent_rows, budget)

      readers = Hash(String, ObjectSharedPhysicalLaneReader).new(initial_capacity: COPY_LANES.size)
      COPY_LANES.each do |name|
        readers[name] = ObjectSharedPhysicalLaneReader.new(name, views[name], budget)
      end
      sizes_reader = readers["sizes"]
      indexes_reader = readers["indexes"]
      values_reader = readers["values"]

      extents = scan_inline_chunk_extents(
        shapes,
        sizes_reader,
        indexes_reader,
        values_reader,
        budget,
      )
      output_bytes = total_extent_bytes(extents)
      materialization_work = checked_multiply(output_bytes, 2_u64, false,
        "inline Copy detached stream materialization")
      budget.ensure_wire_bytes(materialization_work)
      budget.charge_wire_bytes(materialization_work) if materialization_work > 0_u64
      budget.ensure_future_elements(expected_parent_rows.size.to_u64)
      budget.ensure_future_nodes(total_chunks)

      result = Array(Array(ObjectSharedCopyStreams)).new(expected_parent_rows.size)
      extents.each do |parent_extents|
        parent_streams = Array(ObjectSharedCopyStreams).new(parent_extents.size)
        parent_extents.each do |extent|
          sizes = lane_slice(sizes_reader, extent.sizes_start, extent.sizes_size)
          indexes = lane_slice(indexes_reader, extent.indexes_start, extent.indexes_size)
          values = lane_slice(values_reader, extent.values_start, extent.values_size)
          parent_streams << ObjectSharedCopyStreams.new(sizes, indexes, values)
          budget.charge_node
        end
        result << parent_streams
      end
      result
    end

    private def self.validate_encode_grid!(
      chunks_by_parent : Array(Array(ObjectSharedAdvancedChunk)),
      physical_rows : Array(UInt64),
    ) : Nil
      if chunks_by_parent.empty? || chunks_by_parent.size >= Int32::MAX
        raise ArgumentError.new("Object shared Copy layout requires a bounded nonempty physical parent grid")
      end
      unless physical_rows.size == chunks_by_parent.size
        raise ArgumentError.new("Object shared Copy layout physical mark grid disagrees with its parents")
      end
      if chunks_by_parent[0].empty?
        raise ArgumentError.new("Object shared physical parent has no logical Copy chunks")
      end
      bucket_count = chunks_by_parent[0][0].bucket_count
      unless 1 <= bucket_count <= ObjectSharedBucketLayout::MAX_BUCKET_COUNT.to_i
        raise UnsupportedFormatError.new("Object shared Copy layout bucket count is invalid")
      end

      physical_rows.each do |rows|
        if rows == 0_u64 || rows > Int32::MAX.to_u64
          raise ArgumentError.new("Object shared physical parent rows must be positive Int32 values")
        end
      end
      chunks_by_parent.each do |chunks|
        if chunks.empty?
          raise ArgumentError.new("Object shared physical parent has no logical Copy chunks")
        end
        chunks.each do |chunk|
          unless chunk.bucket_count == bucket_count
            raise UnsupportedFormatError.new("Object shared Copy chunk bucket counts disagree")
          end
          if chunk.row_count > Int32::MAX.to_u64
            raise UnsupportedFormatError.new("Object shared Copy chunk row count exceeds Int32")
          end
        end
      end
      nil
    end

    # Bound the parent/chunk traversal before inspecting any borrowed chunk
    # metadata. Counts are already present in the input arrays, so this pass
    # allocates nothing and charges only after the full schedule is known.
    private def self.preflight_encode_visits(
      chunks_by_parent : Array(Array(ObjectSharedAdvancedChunk)),
      physical_rows : Array(UInt64),
      budget : BinaryCodecBudget,
    ) : Tuple(UInt64, UInt64)
      parent_count = chunks_by_parent.size.to_u64
      if parent_count == 0_u64 || parent_count >= Int32::MAX.to_u64
        raise ArgumentError.new("Object shared Copy layout requires a bounded nonempty physical parent grid")
      end
      budget.ensure_future_elements(parent_count)
      budget.ensure_future_nodes(parent_count)
      unless physical_rows.size.to_u64 == parent_count
        raise ArgumentError.new("Object shared Copy layout physical mark grid disagrees with its parents")
      end
      total_chunks = 0_u64
      chunks_by_parent.each do |chunks|
        total_chunks = checked_add(total_chunks, chunks.size.to_u64, true, "Copy chunk count")
        if total_chunks > Int32::MAX.to_u64
          raise UnsupportedFormatError.new("Object shared Copy logical chunk count exceeds Int32")
        end
      end
      if total_chunks == 0_u64
        raise ArgumentError.new("Object shared physical parent has no logical Copy chunks")
      end
      work_count = checked_add(parent_count, total_chunks, true, "Copy layout visit count")
      budget.ensure_future_elements(work_count)
      budget.ensure_future_nodes(work_count)
      {total_chunks, work_count}
    end

    private def self.measure_encode_lanes(
      chunks_by_parent : Array(Array(ObjectSharedAdvancedChunk)),
    ) : Tuple(Array(Array(Int32)), Array(Int32), UInt64, UInt64)
      parent_lane_sizes = Array(Array(Int32)).new(chunks_by_parent.size)
      lane_totals = Array(UInt64).new(3, 0_u64)
      total_wire_bytes = 0_u64
      total_chunks = 0_u64
      chunks_by_parent.each do |chunks|
        parent_totals = Array(UInt64).new(3, 0_u64)
        chunks.each do |chunk|
          total_chunks = checked_add(total_chunks, 1_u64, true, "Copy chunk count")
          streams = chunk.copy_streams
          3.times do |lane_index|
            size = lane_size(streams, lane_index).to_u64
            parent_totals[lane_index] = checked_add(parent_totals[lane_index], size, true,
              "Copy physical parent lane size")
            lane_totals[lane_index] = checked_add(lane_totals[lane_index], size, true,
              "Copy physical lane size")
            total_wire_bytes = checked_add(total_wire_bytes, size, true, "Copy lane wire size")
          end
        end
        parent_sizes = Array(Int32).new(3)
        3.times do |lane_index|
          parent_sizes << checked_int32(parent_totals[lane_index], true, "Copy physical parent lane size")
        end
        parent_lane_sizes << parent_sizes
      end
      lane_total_sizes = Array(Int32).new(3)
      3.times do |lane_index|
        lane_total_sizes << checked_int32(lane_totals[lane_index], true, "Copy physical lane size")
      end
      {parent_lane_sizes, lane_total_sizes, total_wire_bytes, total_chunks}
    end

    private def self.materialize_lane(
      chunks_by_parent : Array(Array(ObjectSharedAdvancedChunk)),
      lane_index : Int32,
      parent_lane_sizes : Array(Array(Int32)),
      total_size : Int32,
    ) : Tuple(Bytes, Array(UInt64))
      raw = Bytes.new(total_size, 0_u8)
      offsets = Array(UInt64).new(parent_lane_sizes.size + 1)
      offsets << 0_u64
      cursor = 0
      chunks_by_parent.each_with_index do |chunks, parent_index|
        chunks.each do |chunk|
          streams = chunk.copy_streams
          source = lane_bytes(streams, lane_index)
          expected = lane_size(streams, lane_index)
          unless source.size == expected
            raise UnsupportedFormatError.new("Object shared Copy lane extent changed after preflight")
          end
          source.copy_to(raw[cursor, source.size])
          cursor += source.size
        end
        parent_size = parent_lane_sizes[parent_index][lane_index]
        unless cursor.to_i64 == offsets[parent_index].to_i64 + parent_size.to_i64
          raise UnsupportedFormatError.new("Object shared Copy lane parent extent changed after preflight")
        end
        offsets << cursor.to_u64
      end
      unless cursor == total_size
        raise UnsupportedFormatError.new("Object shared Copy lane total extent changed after preflight")
      end
      {raw, offsets}
    end

    private def self.validate_copy_inputs!(
      copy_inputs : Hash(String, ObjectSharedPhysicalLaneInput),
    ) : Nil
      unless copy_inputs.size == COPY_LANES.size && COPY_LANES.all? { |name| copy_inputs.has_key?(name) }
        raise CorruptPartError.new("Object shared Copy physical lane roster is incomplete or has extra lanes")
      end
      nil
    end

    private def self.measure_decode_shapes(
      bucket_parents : Array(Array(ObjectSharedPhysicalParentMark)),
      expected_parent_rows : Array(UInt64),
      budget : BinaryCodecBudget,
    ) : Tuple(Array(Array(ChunkShape)), UInt64)
      bucket_count = bucket_parents.size
      unless 1 <= bucket_count <= ObjectSharedBucketLayout::MAX_BUCKET_COUNT.to_i
        raise CorruptPartError.new("Object shared Copy bucket schedule has an invalid bucket count")
      end
      if expected_parent_rows.empty? || expected_parent_rows.size >= Int32::MAX
        raise CorruptPartError.new("Object shared Copy physical parent grid is empty or oversized")
      end
      if expected_parent_rows.size != bucket_parents[0].size
        raise CorruptPartError.new("Object shared Copy bucket parent grid disagrees with expected rows")
      end
      matrix_entries = checked_multiply(bucket_count.to_u64, expected_parent_rows.size.to_u64, false,
        "Copy bucket parent schedule")
      budget.preflight_children(matrix_entries)

      expected_parent_rows.each do |rows|
        if rows == 0_u64 || rows > Int32::MAX.to_u64
          raise CorruptPartError.new("Object shared Copy physical parent rows are outside the adaptive domain")
        end
      end
      bucket_parents.each do |parents|
        unless parents.size == expected_parent_rows.size
          raise CorruptPartError.new("Object shared Copy bucket parent grids disagree")
        end
      end

      total_chunks = 0_u64
      expected_parent_rows.each_with_index do |rows, parent_index|
        chunk_count = bucket_parents[0][parent_index].chunk_count
        if chunk_count == 0
          raise CorruptPartError.new("Object shared Copy physical parent has no logical chunks")
        end
        total_chunks = checked_add(total_chunks, chunk_count.to_u64, false, "Copy chunk count")
        bucket_count.times do |bucket_index|
          parent = bucket_parents[bucket_index][parent_index]
          unless parent.physical_rows == rows && parent.chunk_count == chunk_count
            raise CorruptPartError.new("Object shared Copy bucket parent marks disagree")
          end
        end
      end
      if total_chunks > Int32::MAX.to_u64
        raise CorruptPartError.new("Object shared Copy logical chunk count exceeds Int32")
      end
      budget.preflight_children(total_chunks)
      budget.ensure_future_nodes(total_chunks)

      shapes = Array(Array(ChunkShape)).new(expected_parent_rows.size)
      expected_parent_rows.each_index do |parent_index|
        parent_shapes = Array(ChunkShape).new(bucket_parents[0][parent_index].chunk_count)
        bucket_parents[0][parent_index].chunk_count.times do |chunk_index|
          first_chunk = bucket_parents[0][parent_index].chunk_at(chunk_index)
          row_count = first_chunk.row_count
          if row_count > Int32::MAX.to_u64
            raise CorruptPartError.new("Object shared Copy chunk row count exceeds Int32")
          end
          dictionary_count = 0_u64
          bucket_count.times do |bucket_index|
            chunk = bucket_parents[bucket_index][parent_index].chunk_at(chunk_index)
            unless chunk.row_count == row_count
              raise CorruptPartError.new("Object shared Copy bucket chunk row counts disagree")
            end
            dictionary_count = checked_add(dictionary_count, chunk.path_count.to_u64, false,
              "Copy chunk dictionary count")
          end
          if dictionary_count > Int32::MAX.to_u64
            raise CorruptPartError.new("Object shared Copy chunk dictionary exceeds Int32")
          end
          parent_shapes << ChunkShape.new(row_count, dictionary_count)
          budget.charge_node
        end
        shapes << parent_shapes
      end
      {shapes, total_chunks}
    end

    private def self.scan_chunk_extents(
      shapes : Array(Array(ChunkShape)),
      sizes_reader : ObjectSharedPhysicalLaneReader,
      indexes_reader : ObjectSharedPhysicalLaneReader,
      values_reader : ObjectSharedPhysicalLaneReader,
      budget : BinaryCodecBudget,
    ) : Array(Array(CopyExtent))
      all_extents = Array(Array(CopyExtent)).new(shapes.size)
      shapes.each_with_index do |parent_shapes, parent_index|
        sizes_start = lane_position(sizes_reader, parent_index)
        sizes_end = lane_position(sizes_reader, parent_index + 1)
        indexes_start = lane_position(indexes_reader, parent_index)
        indexes_end = lane_position(indexes_reader, parent_index + 1)
        values_start = lane_position(values_reader, parent_index)
        values_end = lane_position(values_reader, parent_index + 1)

        expected_sizes = 0_u64
        parent_shapes.each do |shape|
          expected_sizes = checked_add(expected_sizes,
            checked_multiply(shape.row_count, 8_u64, false, "Copy sizes extent"), false,
            "Copy sizes extent")
        end
        unless sizes_end - sizes_start == checked_int32(expected_sizes, false, "Copy sizes extent")
          raise CorruptPartError.new("Object shared Copy sizes parent extent disagrees with chunk rows")
        end

        size_cursor = sizes_start
        index_cursor = indexes_start
        value_cursor = values_start
        parent_extents = Array(CopyExtent).new(parent_shapes.size)
        parent_shapes.each do |shape|
          sizes_chunk_start = size_cursor
          sizes_chunk_size = checked_int32(shape.row_count * 8_u64, false, "Copy sizes chunk extent")
          entries = 0_u64
          budget.preflight_children(shape.row_count)
          shape.row_count.times do
            count = read_u64_le(sizes_reader, size_cursor, sizes_end)
            if count > Int32::MAX.to_u64
              raise CorruptPartError.new("Object shared Copy row count exceeds Int32")
            end
            entries = checked_add(entries, count, false, "Copy entry count")
            if entries > Int32::MAX.to_u64
              raise CorruptPartError.new("Object shared Copy total entries exceed Int32")
            end
            size_cursor += 8
            budget.charge_node
          end

          width = index_width(shape.dictionary_count)
          indexes_chunk_size = checked_int32(
            checked_multiply(entries, width.to_u64, false, "Copy indexes extent"),
            false,
            "Copy indexes extent",
          )
          indexes_chunk_end = checked_end(index_cursor, indexes_chunk_size, indexes_end, "Copy indexes")
          minimum_values = checked_multiply(entries, 2_u64, false, "Copy values minimum extent")
          if minimum_values > (values_end - value_cursor).to_u64
            raise CorruptPartError.new("Object shared Copy values lane is too short for declared entries")
          end

          budget.preflight_children(entries)
          values_chunk_start = value_cursor
          entries.times do
            envelope_size, prefix_size = read_var_uint(values_reader, value_cursor, values_end)
            if envelope_size == 0_u64 || envelope_size > Int32::MAX.to_u64
              raise CorruptPartError.new("Object shared Copy value envelope has an invalid size")
            end
            frame_size = checked_add(prefix_size.to_u64, envelope_size, false, "Copy value frame")
            value_cursor = checked_end(value_cursor, checked_int32(frame_size, false, "Copy value frame"),
              values_end, "Copy values")
            budget.charge_node
          end

          parent_extents << CopyExtent.new(
            sizes_chunk_start,
            sizes_chunk_size,
            index_cursor,
            indexes_chunk_size,
            values_chunk_start,
            value_cursor - values_chunk_start,
          )
          index_cursor = indexes_chunk_end
        end
        unless size_cursor == sizes_end && index_cursor == indexes_end && value_cursor == values_end
          raise CorruptPartError.new("Object shared Copy parent lanes contain unreferenced trailing bytes")
        end
        all_extents << parent_extents
      end
      all_extents
    end

    # Inline Copy callbacks concatenate all physical parents into one
    # callback each, so parent boundaries come from the authenticated bucket
    # chunk schedule and sizes lane rather than fabricated marks. Index/value
    # cursors remain global and must exactly consume their role extents.
    private def self.scan_inline_chunk_extents(
      shapes : Array(Array(ChunkShape)),
      sizes_reader : ObjectSharedPhysicalLaneReader,
      indexes_reader : ObjectSharedPhysicalLaneReader,
      values_reader : ObjectSharedPhysicalLaneReader,
      budget : BinaryCodecBudget,
    ) : Array(Array(CopyExtent))
      all_extents = Array(Array(CopyExtent)).new(shapes.size)
      sizes_cursor = 0_i32
      indexes_cursor = 0_i32
      values_cursor = 0_i32

      shapes.each do |parent_shapes|
        expected_sizes = 0_u64
        parent_shapes.each do |shape|
          expected_sizes = checked_add(
            expected_sizes,
            checked_multiply(shape.row_count, 8_u64, false, "inline Copy sizes extent"),
            false,
            "inline Copy sizes extent",
          )
        end
        sizes_end = checked_end(
          sizes_cursor,
          checked_int32(expected_sizes, false, "inline Copy sizes extent"),
          sizes_reader.byte_size,
          "inline Copy sizes parent",
        )
        parent_extents = Array(CopyExtent).new(parent_shapes.size)

        parent_shapes.each do |shape|
          sizes_chunk_start = sizes_cursor
          sizes_chunk_size = checked_int32(
            checked_multiply(shape.row_count, 8_u64, false, "inline Copy sizes chunk extent"),
            false,
            "inline Copy sizes chunk extent",
          )
          entries = 0_u64
          budget.preflight_children(shape.row_count)
          shape.row_count.times do
            count = read_u64_le(sizes_reader, sizes_cursor, sizes_end)
            if count > Int32::MAX.to_u64
              raise CorruptPartError.new("Object shared Copy row count exceeds Int32")
            end
            entries = checked_add(entries, count, false, "inline Copy entry count")
            if entries > Int32::MAX.to_u64
              raise CorruptPartError.new("Object shared Copy total entries exceed Int32")
            end
            sizes_cursor += 8
            budget.charge_node
          end

          indexes_chunk_start = indexes_cursor
          indexes_chunk_size = checked_int32(
            checked_multiply(entries, index_width(shape.dictionary_count).to_u64, false,
              "inline Copy indexes extent"),
            false,
            "inline Copy indexes extent",
          )
          indexes_cursor = checked_end(
            indexes_cursor,
            indexes_chunk_size,
            indexes_reader.byte_size,
            "inline Copy indexes",
          )

          minimum_values = checked_multiply(entries, 2_u64, false, "inline Copy values minimum extent")
          if minimum_values > (values_reader.byte_size - values_cursor).to_u64
            raise CorruptPartError.new("Object shared Copy values lane is too short for declared entries")
          end
          budget.preflight_children(entries)
          values_chunk_start = values_cursor
          entries.times do
            envelope_size, prefix_size = read_var_uint(values_reader, values_cursor, values_reader.byte_size)
            if envelope_size == 0_u64 || envelope_size > Int32::MAX.to_u64
              raise CorruptPartError.new("Object shared Copy value envelope has an invalid size")
            end
            frame_size = checked_add(prefix_size.to_u64, envelope_size, false, "inline Copy value frame")
            values_cursor = checked_end(
              values_cursor,
              checked_int32(frame_size, false, "inline Copy value frame"),
              values_reader.byte_size,
              "inline Copy values",
            )
            budget.charge_node
          end

          parent_extents << CopyExtent.new(
            sizes_chunk_start,
            sizes_chunk_size,
            indexes_chunk_start,
            indexes_chunk_size,
            values_chunk_start,
            values_cursor - values_chunk_start,
          )
        end
        unless sizes_cursor == sizes_end
          raise CorruptPartError.new("Object shared inline Copy sizes parent extent disagrees with chunk rows")
        end
        all_extents << parent_extents
      end

      unless sizes_cursor == sizes_reader.byte_size &&
             indexes_cursor == indexes_reader.byte_size &&
             values_cursor == values_reader.byte_size
        raise CorruptPartError.new("Object shared inline Copy roles contain unreferenced trailing bytes")
      end
      all_extents
    end

    private def self.total_extent_bytes(extents : Array(Array(CopyExtent))) : UInt64
      total = 0_u64
      extents.each do |parent_extents|
        parent_extents.each do |extent|
          total = checked_add(total, extent.sizes_size.to_u64, false, "Copy output size")
          total = checked_add(total, extent.indexes_size.to_u64, false, "Copy output size")
          total = checked_add(total, extent.values_size.to_u64, false, "Copy output size")
        end
      end
      total
    end

    private def self.lane_position(reader : ObjectSharedPhysicalLaneReader, index : Int) : Int32
      position = reader.outer_position(index)
      if position < 0 || position > Int32::MAX
        raise CorruptPartError.new("Object shared Copy outer position exceeds Int32")
      end
      position.to_i32
    end

    private def self.lane_slice(
      reader : ObjectSharedPhysicalLaneReader,
      start : Int32,
      size : Int32,
    ) : Bytes
      if start < 0 || size < 0 || start > reader.byte_size - size
        raise CorruptPartError.new("Object shared Copy chunk slice is outside its lane")
      end
      Bytes.new(size) { |index| reader.byte_at(start + index) }
    end

    private def self.read_u64_le(
      reader : ObjectSharedPhysicalLaneReader,
      offset : Int32,
      limit : Int32,
    ) : UInt64
      if offset < 0 || offset > limit - 8
        raise CorruptPartError.new("Object shared Copy sizes lane is truncated")
      end
      value = 0_u64
      8.times { |index| value |= reader.byte_at(offset + index).to_u64 << (index * 8) }
      value
    end

    private def self.read_var_uint(
      reader : ObjectSharedPhysicalLaneReader,
      offset : Int32,
      limit : Int32,
    ) : Tuple(UInt64, Int32)
      value = 0_u64
      10.times do |index|
        if offset < 0 || offset > limit || index >= limit - offset
          raise CorruptPartError.new("Object shared Copy value length is truncated")
        end
        byte_offset = offset + index
        byte = reader.byte_at(byte_offset)
        payload = (byte & 0x7f_u8).to_u64
        if index == 9 && payload > 1_u64
          raise CorruptPartError.new("Object shared Copy value length overflows UInt64")
        end
        value |= payload << (index * 7)
        continuing = (byte & 0x80_u8) != 0_u8
        unless continuing
          if index > 0 && payload == 0_u64
            raise CorruptPartError.new("Object shared Copy value length is nonminimal")
          end
          return {value, index + 1}
        end
        if index == 9
          raise CorruptPartError.new("Object shared Copy value length is too long")
        end
      end
      raise CorruptPartError.new("Object shared Copy value length is too long")
    end

    private def self.lane_size(streams : ObjectSharedCopyStreams, lane_index : Int32) : Int32
      case lane_index
      when 0 then streams.sizes_size
      when 1 then streams.indexes_size
      else        streams.values_size
      end
    end

    private def self.lane_bytes(streams : ObjectSharedCopyStreams, lane_index : Int32) : Bytes
      case lane_index
      when 0 then streams.sizes
      when 1 then streams.indexes
      else        streams.values
      end
    end

    private def self.index_width(dictionary_count : UInt64) : Int32
      if dictionary_count <= 256_u64
        1
      elsif dictionary_count <= 65_536_u64
        2
      else
        4
      end
    end

    private def self.checked_end(
      start : Int32,
      size : Int32,
      limit : Int32,
      label : String,
    ) : Int32
      if start < 0 || size < 0 || start > limit || size > limit - start
        raise CorruptPartError.new("Object shared #{label} extent is outside its parent lane")
      end
      start + size
    end

    private def self.checked_int32(value : UInt64, writing : Bool, label : String) : Int32
      if value > Int32::MAX.to_u64
        fail_layout!(writing, "#{label} exceeds Int32")
      end
      value.to_i32
    end

    private def self.checked_add(
      left : UInt64,
      right : UInt64,
      writing : Bool,
      label : String,
    ) : UInt64
      if right > UInt64::MAX - left
        fail_layout!(writing, "#{label} overflows UInt64")
      end
      left + right
    end

    private def self.checked_multiply(
      left : UInt64,
      right : UInt64,
      writing : Bool,
      label : String,
    ) : UInt64
      if right > 0_u64 && left > UInt64::MAX // right
        fail_layout!(writing, "#{label} overflows UInt64")
      end
      left * right
    end

    private def self.fail_layout!(writing : Bool, message : String) : NoReturn
      if writing
        raise UnsupportedFormatError.new(message)
      else
        raise CorruptPartError.new(message)
      end
    end
  end
end
