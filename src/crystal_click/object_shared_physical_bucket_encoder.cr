module CrystalClick
  # Assembles all six logical lanes for one physical bucket, then compresses
  # each lane exactly once after its inbound coordinate fields are final.
  class ObjectSharedPhysicalBucketEncoder
    LANE_NAMES = ObjectSharedPhysicalBucketLaneInputs::LANE_NAMES

    private struct PathLayout
      getter path : ObjectSharedPhysicalPath
      getter data_start : UInt64
      getter paths_mark_offset : Int32
      getter substreams_offset : Int32
      getter substreams_marks_offset : Int32
      getter metadata_offset : Int32

      def initialize(
        @path : ObjectSharedPhysicalPath,
        @data_start : UInt64,
        @paths_mark_offset : Int32,
        @substreams_offset : Int32,
        @substreams_marks_offset : Int32,
        @metadata_offset : Int32,
      )
      end
    end

    private struct ChunkLayout
      getter record : ObjectSharedChunkStructure
      getter data_start : UInt64
      getter suffix_offset : Int32
      getter paths_mark_start : UInt64
      getter metadata_start : UInt64
      getter paths : Array(PathLayout)

      def initialize(
        @record : ObjectSharedChunkStructure,
        @data_start : UInt64,
        @suffix_offset : Int32,
        @paths_mark_start : UInt64,
        @metadata_start : UInt64,
        @paths : Array(PathLayout),
      )
      end
    end

    private struct CoordinatePatch
      getter lane : String
      getter offset : Int32

      def initialize(@lane : String, @offset : Int32)
      end
    end

    # Scalar-only result of walking caller-owned input before any count-sized
    # layout, query, row, or lane buffers are retained.
    private struct InputMeasurement
      getter raw_sizes : Array(Int32)
      getter total_paths : UInt64
      getter total_events : UInt64
      getter total_name_bytes : UInt64
      getter total_chunks : UInt64
      getter total_raw_size : Int64

      def initialize(
        @raw_sizes : Array(Int32),
        @total_paths : UInt64,
        @total_events : UInt64,
        @total_name_bytes : UInt64,
        @total_chunks : UInt64,
        @total_raw_size : Int64,
      )
      end
    end

    def self.encode(
      version : Int,
      parents : Array(ObjectSharedPhysicalParentMark),
      codec_budget : BinaryCodecBudget,
      transport_budget : CompressedStreamBudget,
      frame_bytes : Int = 4096,
    ) : ObjectSharedPhysicalBucketFiles
      validate_version!(version)
      unless codec_budget.writing?
        raise ArgumentError.new("Object shared physical encode requires a write-direction codec budget")
      end
      transport_budget.ensure_direction(true)
      codec_budget.ensure_depth(1)
      validate_parents!(version, parents)

      measured = measure_input(parents, codec_budget)
      query_count = checked_query_count(measured.total_chunks, measured.total_paths, measured.total_events)
      codec_budget.ensure_wire_bytes(measured.total_raw_size.to_u64)
      codec_budget.ensure_future_nodes(checked_add(checked_add(measured.total_chunks, measured.total_paths), measured.total_events))
      codec_budget.ensure_future_elements(checked_add(checked_add(measured.total_paths, measured.total_events), measured.total_name_bytes))
      CompressedMarkWriter.preflight_batch_with_positions(
        measured.raw_sizes, parents.size + 1, query_count, frame_bytes, transport_budget
      )

      layouts, raw_sizes, rows, offsets = plan_layouts(parents)
      unless raw_sizes == measured.raw_sizes
        raise UnsupportedFormatError.new("Object shared input changed after physical preflight")
      end

      data = Bytes.new(raw_sizes[1], 0_u8)
      paths_marks = Bytes.new(raw_sizes[2], 0_u8)
      substreams = Bytes.new(raw_sizes[3], 0_u8)
      substreams_marks = Bytes.new(raw_sizes[4], 0_u8)
      metadata = Bytes.new(raw_sizes[5], 0_u8)
      structure = Bytes.new(raw_sizes[0], 0_u8)
      codec_budget.charge_wire_bytes(raw_sizes[1].to_u64)
      codec_budget.charge_wire_bytes(raw_sizes[2].to_u64)
      codec_budget.charge_wire_bytes(raw_sizes[4].to_u64)
      codec_budget.charge_wire_bytes(raw_sizes[5].to_u64)

      data_queries = [] of UInt64
      data_patches = [] of CoordinatePatch
      paths_mark_queries = [] of UInt64
      paths_mark_patches = [] of CoordinatePatch
      substreams_queries = [] of UInt64
      substreams_patches = [] of CoordinatePatch
      substreams_mark_queries = [] of UInt64
      substreams_mark_patches = [] of CoordinatePatch
      metadata_queries = [] of UInt64
      metadata_patches = [] of CoordinatePatch

      populate_lane_bytes!(layouts, data, paths_marks, substreams, substreams_marks, metadata,
        structure, codec_budget)

      layouts.each do |parent_chunks|
        parent_chunks.each do |layout|
          data_queries << layout.data_start
          data_patches << CoordinatePatch.new("structure", layout.suffix_offset)
          paths_mark_queries << layout.paths_mark_start
          paths_mark_patches << CoordinatePatch.new("structure", layout.suffix_offset + 16)
          metadata_queries << layout.metadata_start
          metadata_patches << CoordinatePatch.new("structure", layout.suffix_offset + 32)
          layout.paths.each do |path_layout|
            data_queries << path_layout.data_start
            data_patches << CoordinatePatch.new("paths_marks", path_layout.paths_mark_offset)
            substreams_queries << path_layout.substreams_offset.to_u64
            substreams_patches << CoordinatePatch.new("paths_substreams_metadata", path_layout.metadata_offset)
            substreams_mark_queries << path_layout.substreams_marks_offset.to_u64
            substreams_mark_patches << CoordinatePatch.new("paths_substreams_metadata", path_layout.metadata_offset + 16)
            path_layout.path.streams.event_count.times do |event_index|
              event = path_layout.path.streams.event_at(event_index)
              absolute = checked_add(path_layout.data_start, event.relative_offset)
              data_queries << absolute
              data_patches << CoordinatePatch.new("substreams_marks",
                path_layout.substreams_marks_offset + event_index * 16)
            end
          end
        end
      end

      output = Hash(String, CompressedMarkFiles).new
      data_positions = CompressedMarkWriter.encode_with_positions(
        data, offsets[1], rows, data_queries, frame_bytes: frame_bytes, budget: transport_budget
      )
      output["data"] = data_positions.files
      patch_positions!(data_positions, data_patches, {
        "structure"        => structure,
        "paths_marks"      => paths_marks,
        "substreams_marks" => substreams_marks,
      })

      paths_mark_positions = CompressedMarkWriter.encode_with_positions(
        paths_marks, offsets[2], rows, paths_mark_queries, frame_bytes: frame_bytes, budget: transport_budget
      )
      output["paths_marks"] = paths_mark_positions.files
      patch_positions!(paths_mark_positions, paths_mark_patches, {"structure" => structure})

      substreams_positions = CompressedMarkWriter.encode_with_positions(
        substreams, offsets[3], rows, substreams_queries, frame_bytes: frame_bytes, budget: transport_budget
      )
      output["substreams"] = substreams_positions.files
      patch_positions!(substreams_positions, substreams_patches, {"paths_substreams_metadata" => metadata})

      substreams_mark_positions = CompressedMarkWriter.encode_with_positions(
        substreams_marks, offsets[4], rows, substreams_mark_queries, frame_bytes: frame_bytes, budget: transport_budget
      )
      output["substreams_marks"] = substreams_mark_positions.files
      patch_positions!(substreams_mark_positions, substreams_mark_patches, {"paths_substreams_metadata" => metadata})

      metadata_positions = CompressedMarkWriter.encode_with_positions(
        metadata, offsets[5], rows, metadata_queries, frame_bytes: frame_bytes, budget: transport_budget
      )
      output["paths_substreams_metadata"] = metadata_positions.files
      patch_positions!(metadata_positions, metadata_patches, {"structure" => structure})

      output["structure"] = CompressedMarkWriter.encode(
        structure, offsets[0], rows, frame_bytes: frame_bytes, budget: transport_budget
      )
      ObjectSharedPhysicalBucketFiles.new(output)
    end

    private def self.validate_version!(version : Int) : Nil
      unless version == 2 || version == 3
        raise UnsupportedFormatError.new("Object shared physical writer supports only ADVANCED v2/v3")
      end
    end

    private def self.validate_parents!(version : Int, parents : Array(ObjectSharedPhysicalParentMark)) : Nil
      if parents.empty? || parents.size >= Int32::MAX
        raise ArgumentError.new("Object shared physical bucket requires a bounded nonempty parent grid")
      end
      parents.each do |parent|
        if parent.chunk_count == 0
          raise ArgumentError.new("Object shared physical parent has no logical chunks")
        end
        if version == 2 && parent.chunk_count != 1
          raise ArgumentError.new("ADVANCED v2 requires exactly one chunk per physical parent")
        end
      end
    end

    private def self.plan_layouts(
      parents : Array(ObjectSharedPhysicalParentMark),
    ) : Tuple(Array(Array(ChunkLayout)), Array(Int32), Array(UInt64), Array(Array(UInt64)))
      cursors = Array(Int64).new(6, 0_i64)
      # Lane order is structure, Data, PathsMarks, Substreams, SubstreamsMarks, Metadata.
      all_layouts = [] of Array(ChunkLayout)
      rows = [] of UInt64
      offsets = Array(Array(UInt64)).new(6) { [] of UInt64 }
      6.times { |lane| offsets[lane] << 0_u64 }

      parents.each do |parent|
        parent_layouts = [] of ChunkLayout
        parent.chunks.each do |chunk|
          record = ObjectSharedChunkStructure.new(
            chunk.row_count,
            chunk.paths.map(&.name),
            {0_u64, 0_u64},
            {0_u64, 0_u64},
            {0_u64, 0_u64},
          )
          record_size = structure_record_size(record)
          suffix_offset = checked_int32(cursors[0] + record_size - ObjectSharedChunkStructureCodec::TRANSPORT_SUFFIX_BYTES.to_i64)
          chunk_data_start = checked_u64(cursors[1])
          paths_mark_start = checked_u64(cursors[2])
          metadata_start = checked_u64(cursors[5])
          path_layouts = [] of PathLayout

          chunk.path_count.times do |path_index|
            path = chunk.path_at(path_index)
            path_data_start = checked_u64(cursors[1])
            paths_mark_offset = checked_int32(cursors[2])
            substreams_offset = checked_int32(cursors[3])
            substreams_marks_offset = checked_int32(cursors[4])
            metadata_offset = checked_int32(cursors[5])
            path_layout = PathLayout.new(path, path_data_start, paths_mark_offset, substreams_offset,
              substreams_marks_offset, metadata_offset)
            path_layouts << path_layout

            cursors[1] = checked_add(cursors[1], path.streams.data_size.to_i64)
            cursors[2] = checked_add(cursors[2], 16_i64)
            cursors[3] = checked_add(cursors[3], substreams_record_size(path))
            cursors[4] = checked_add(cursors[4], path.streams.event_count.to_i64 * 16_i64)
            cursors[5] = checked_add(cursors[5], 32_i64)
          end

          cursors[0] = checked_add(cursors[0], record_size)
          parent_layouts << ChunkLayout.new(record, chunk_data_start, suffix_offset, paths_mark_start,
            metadata_start, path_layouts)
        end
        all_layouts << parent_layouts
        rows << parent.physical_rows
        6.times { |lane| offsets[lane] << checked_u64(cursors[lane]) }
      end

      raw_sizes = cursors.map { |size| checked_int32(size) }
      {all_layouts, raw_sizes, rows, offsets}
    end

    private def self.populate_lane_bytes!(
      layouts : Array(Array(ChunkLayout)),
      data : Bytes,
      paths_marks : Bytes,
      substreams : Bytes,
      substreams_marks : Bytes,
      metadata : Bytes,
      structure : Bytes,
      budget : BinaryCodecBudget,
    ) : Nil
      layouts.each do |parent_chunks|
        parent_chunks.each do |layout|
          layout.paths.each do |path_layout|
            path = path_layout.path
            path.streams.data_size.times do |byte_index|
              data[path_layout.data_start.to_i + byte_index] = path.streams.data_byte_at(byte_index)
            end
            write_substreams_record!(substreams, path_layout.substreams_offset, path, budget)
            path.streams.event_count.times do |event_index|
              event = path.streams.event_at(event_index)
              write_u64_le(substreams_marks, path_layout.substreams_marks_offset + event_index * 16,
                0_u64)
              write_u64_le(substreams_marks, path_layout.substreams_marks_offset + event_index * 16 + 8,
                0_u64)
              # Retain the relative coordinate in the second word until the
              # Data lane position query is resolved; the first word stays zero.
            end
            write_u64_le(paths_marks, path_layout.paths_mark_offset, 0_u64)
            write_u64_le(paths_marks, path_layout.paths_mark_offset + 8, 0_u64)
            4.times { |word| write_u64_le(metadata, path_layout.metadata_offset + word * 8, 0_u64) }
          end
          context = BinaryCodecContext.new(
            budget.limits,
            nil,
            true,
            budget: budget,
            output_byte_limit: structure_record_size(layout.record).to_u64,
          )
          ObjectSharedChunkStructureCodec.write_to(layout.record, context)
          record_bytes = context.finish_bytes
          expected = structure_record_size(layout.record)
          unless record_bytes.size == expected
            raise UnsupportedFormatError.new("Object shared chunk structure size changed during assembly")
          end
          # suffix_offset points at the first suffix byte; compute record start.
          record_start = layout.suffix_offset.to_i + ObjectSharedChunkStructureCodec::TRANSPORT_SUFFIX_BYTES.to_i - expected
          record_bytes.copy_to(structure[record_start, expected])
        end
      end
      nil
    end

    private def self.write_substreams_record!(
      destination : Bytes,
      offset : Int32,
      path : ObjectSharedPhysicalPath,
      budget : BinaryCodecBudget,
    ) : Nil
      size = substreams_record_size(path)
      context = BinaryCodecContext.new(budget.limits, nil, true, budget: budget, output_byte_limit: size.to_u64)
      context.write_var_uint(path.streams.event_count.to_u64)
      path.streams.event_count.times do |event_index|
        event = path.streams.event_at(event_index)
        name_size = event.name_byte_size
        context.write_var_uint(name_size.to_u64)
        name_size.times { |byte_index| context.write_byte(event.name_byte_at(byte_index)) }
        budget.charge_elements(1_u64)
        budget.charge_elements(name_size.to_u64)
        budget.visit_node(1)
      end
      record = context.finish_bytes
      unless record.size == size
        raise UnsupportedFormatError.new("Object shared substream record size changed during assembly")
      end
      record.copy_to(destination[offset, size])
      nil
    end

    private def self.patch_positions!(
      positions : CompressedMarkPositionFiles,
      patches : Array(CoordinatePatch),
      lanes : Hash(String, Bytes),
    ) : Nil
      unless positions.count == patches.size
        raise UnsupportedFormatError.new("Object shared coordinate query count changed")
      end
      patches.each_with_index do |patch, index|
        bytes = lanes[patch.lane]? || raise(UnsupportedFormatError.new("Object shared coordinate patch lane is missing"))
        coordinate = positions.position_at(index)
        write_u64_le(bytes, patch.offset, coordinate[0])
        write_u64_le(bytes, patch.offset + 8, coordinate[1])
      end
      nil
    end

    private def self.measure_input(
      parents : Array(ObjectSharedPhysicalParentMark),
      budget : BinaryCodecBudget,
    ) : InputMeasurement
      raw_sizes = Array(Int64).new(6, 0_i64)
      paths = 0_u64
      events = 0_u64
      names = 0_u64
      chunks = 0_u64
      parents.each { |parent| chunks = checked_add(chunks, parent.chunk_count.to_u64) }

      # Preflight chunk-derived work before walking any logical child arrays.
      # Every chunk has its two UInt64 marks, two minimum VarUInt prefixes,
      # and fixed 48-byte transport suffix.
      budget.ensure_future_nodes(chunks)
      lower_wire = checked_multiply(chunks, 50_u64)
      budget.ensure_wire_bytes(lower_wire)

      parents.each do |parent|
        parent.chunk_count.times do |chunk_index|
          chunk = parent.chunk_at(chunk_index)
          path_count = chunk.path_count.to_u64
          projected_paths = checked_add(paths, path_count)
          projected_nodes = checked_add(checked_add(chunks, projected_paths), events)
          projected_elements = checked_add(projected_paths, checked_add(events, names))
          budget.ensure_future_nodes(projected_nodes)
          budget.ensure_future_elements(projected_elements)

          # Fixed chunk prefix/suffix plus its row/path-count VarUInts.
          struct_size = 48_i64 + var_uint_size(chunk.row_count) + var_uint_size(chunk.path_count.to_u64)
          lower_wire = checked_add(lower_wire, var_uint_extra(chunk.row_count))
          lower_wire = checked_add(lower_wire, var_uint_extra(path_count))
          lower_wire = checked_add(lower_wire, checked_multiply(path_count, 50_u64))
          budget.ensure_wire_bytes(lower_wire)

          chunk.path_count.times do |path_index|
            path = chunk.path_at(path_index)
            path_name_size = path.name_byte_size.to_u64
            struct_size = checked_add(struct_size, var_uint_size(path_name_size) + path_name_size.to_i64)
            paths = checked_add(paths, 1_u64)
            event_count = path.streams.event_count.to_u64
            projected_events = checked_add(events, event_count)
            projected_nodes = checked_add(checked_add(chunks, paths), projected_events)
            projected_elements = checked_add(paths, checked_add(projected_events, names))
            budget.ensure_future_nodes(projected_nodes)
            budget.ensure_future_elements(projected_elements)

            # The path baseline (50 bytes) was preflighted with its chunk.
            # Add path-name bytes, Data bytes, callback-count excess, and the
            # one-byte-name/16-byte-mark minimum for each callback before
            # entering its count-sized event loop.
            lower_wire = checked_add(lower_wire, path_name_size)
            lower_wire = checked_add(lower_wire, var_uint_extra(path_name_size))
            lower_wire = checked_add(lower_wire, path.streams.data_size.to_u64)
            lower_wire = checked_add(lower_wire, var_uint_extra(event_count))
            lower_wire = checked_add(lower_wire, checked_multiply(event_count, 17_u64))
            budget.ensure_wire_bytes(lower_wire)

            raw_sizes[1] = checked_add(raw_sizes[1], path.streams.data_size.to_i64)
            raw_sizes[2] = checked_add(raw_sizes[2], 16_i64)
            raw_sizes[3] = checked_add(raw_sizes[3], var_uint_size(path.streams.event_count.to_u64))
            raw_sizes[4] = checked_add(raw_sizes[4], checked_multiply(path.streams.event_count.to_i64, 16_i64))
            raw_sizes[5] = checked_add(raw_sizes[5], 32_i64)
            path.streams.event_count.times do |event_index|
              event_name_size = path.streams.event_at(event_index).name_byte_size.to_u64
              events = checked_add(events, 1_u64)
              names = checked_add(names, event_name_size)
              lower_wire = checked_add(lower_wire, event_name_size)
              lower_wire = checked_add(lower_wire, var_uint_extra(event_name_size))
              budget.ensure_future_nodes(checked_add(checked_add(chunks, paths), events))
              budget.ensure_future_elements(checked_add(paths, checked_add(events, names)))
              budget.ensure_wire_bytes(lower_wire)
              raw_sizes[3] = checked_add(raw_sizes[3], var_uint_size(event_name_size) + event_name_size.to_i64)
            end
          end
          raw_sizes[0] = checked_add(raw_sizes[0], struct_size)
        end
      end
      total_raw = 0_i64
      raw_sizes.each { |size| total_raw = checked_add(total_raw, size) }
      unless lower_wire == total_raw.to_u64
        raise UnsupportedFormatError.new("Object shared physical preflight disagrees with measured lane bytes")
      end
      budget.ensure_wire_bytes(lower_wire)
      InputMeasurement.new(raw_sizes.map { |size| checked_int32(size) }, paths, events, names,
        chunks, total_raw)
    end

    private def self.checked_query_count(chunks : UInt64, paths : UInt64, events : UInt64) : Int64
      if chunks > UInt64::MAX // 3_u64 || paths > UInt64::MAX // 3_u64
        raise UnsupportedFormatError.new("Object shared coordinate query count overflows")
      end
      total = checked_add(checked_add(chunks * 3_u64, paths * 3_u64), events)
      unless total <= Int32::MAX.to_u64
        raise UnsupportedFormatError.new("Object shared coordinate query count exceeds Int32")
      end
      total.to_i64
    end

    private def self.structure_record_size(record : ObjectSharedChunkStructure) : Int32
      size = 48_i64 + var_uint_size(record.row_count) + var_uint_size(record.path_count.to_u64)
      record.path_count.times do |index|
        path_size = record.path_byte_size(index).to_u64
        size = checked_add(size, var_uint_size(path_size) + path_size.to_i64)
      end
      checked_int32(size)
    end

    private def self.substreams_record_size(path : ObjectSharedPhysicalPath) : Int64
      size = var_uint_size(path.streams.event_count.to_u64)
      path.streams.event_count.times do |index|
        name_size = path.streams.event_at(index).name_byte_size.to_u64
        size = checked_add(size, var_uint_size(name_size) + name_size.to_i64)
      end
      size
    end

    private def self.var_uint_size(value : UInt64) : Int64
      size = 1_i64
      remaining = value
      while remaining >= 0x80_u64
        remaining >>= 7
        size += 1_i64
      end
      size
    end

    private def self.var_uint_extra(value : UInt64) : UInt64
      (var_uint_size(value) - 1_i64).to_u64
    end

    private def self.checked_add(left : Int64, right : Int64) : Int64
      if right < 0 || left > Int64::MAX - right
        raise UnsupportedFormatError.new("Object shared physical lane size overflows")
      end
      left + right
    end

    private def self.checked_multiply(left : Int64, right : Int64) : Int64
      if left < 0 || right < 0 || (right > 0 && left > Int64::MAX // right)
        raise UnsupportedFormatError.new("Object shared physical lane size overflows")
      end
      left * right
    end

    private def self.checked_add(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        raise UnsupportedFormatError.new("Object shared physical coordinate overflows")
      end
      left + right
    end

    private def self.checked_multiply(left : UInt64, right : UInt64) : UInt64
      if right > 0_u64 && left > UInt64::MAX // right
        raise UnsupportedFormatError.new("Object shared physical lane size overflows")
      end
      left * right
    end

    private def self.checked_u64(value : Int64) : UInt64
      if value < 0
        raise UnsupportedFormatError.new("Object shared physical lane size is negative")
      end
      value.to_u64
    end

    private def self.checked_int32(value : Int64) : Int32
      if value < 0 || value > Int32::MAX
        raise UnsupportedFormatError.new("Object shared physical lane exceeds Int32")
      end
      value.to_i32
    end

    private def self.write_u64_le(bytes : Bytes, offset : Int32, value : UInt64) : Nil
      8.times do |index|
        bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8
      end
    end
  end
end
