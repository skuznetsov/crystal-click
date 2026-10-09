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
      getter total_inline_relocations : UInt64
      getter total_inline_relocation_name_bytes : UInt64
      getter total_inline_interval_events : UInt64
      getter total_inline_interval_name_bytes : UInt64
      getter total_raw_size : Int64

      def initialize(
        @raw_sizes : Array(Int32),
        @total_paths : UInt64,
        @total_events : UInt64,
        @total_name_bytes : UInt64,
        @total_chunks : UInt64,
        @total_inline_relocations : UInt64,
        @total_inline_relocation_name_bytes : UInt64,
        @total_inline_interval_events : UInt64,
        @total_inline_interval_name_bytes : UInt64,
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
      query_count = checked_query_count(
        measured.total_chunks,
        measured.total_paths,
        measured.total_events,
        measured.total_inline_relocations,
      )
      preflight_query_count = checked_add(query_count.to_u64, measured.total_inline_relocations)
      unless preflight_query_count <= Int32::MAX.to_u64
        raise UnsupportedFormatError.new("Object shared coordinate query count exceeds Int32")
      end
      codec_budget.ensure_wire_bytes(measured.total_raw_size.to_u64)
      codec_budget.ensure_future_nodes(checked_add(checked_add(measured.total_chunks, measured.total_paths), measured.total_events))
      codec_budget.ensure_future_elements(checked_add(checked_add(measured.total_paths, measured.total_events), measured.total_name_bytes))
      CompressedMarkWriter.preflight_batch_with_positions(
        measured.raw_sizes, parents.size + 1, preflight_query_count.to_i64, frame_bytes, transport_budget
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
      inline_target_queries = Array(UInt64).new(measured.total_inline_relocations.to_i)
      inline_data_patches = Array(Int32).new(measured.total_inline_relocations.to_i)
      inline_work = checked_multiply(measured.total_inline_relocations, 2_u64)
      codec_budget.ensure_future_elements(inline_work)
      codec_budget.charge_elements(inline_work) if inline_work > 0_u64

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
            streams = path_layout.path.streams
            if streams.callback_relocation_count > 0
              callback_intervals = callback_interval_map(streams, codec_budget)
              validate_callback_relocations!(streams, callback_intervals, codec_budget)
              streams.callback_relocation_count.times do |relocation_index|
                relocation = streams.callback_relocation_at(relocation_index)
                source = callback_intervals[relocation.source_callback]? ||
                         raise(UnsupportedFormatError.new("inline Data relocation source callback is absent"))
                target = callback_intervals[relocation.target_callback]? ||
                         raise(UnsupportedFormatError.new("inline Data relocation target callback is absent"))
                source_offset = checked_add(
                  path_layout.data_start,
                  checked_add(source[0], relocation.source_offset),
                )
                target_offset = checked_add(
                  path_layout.data_start,
                  checked_add(target[0], relocation.target_offset),
                )
                inline_data_patches << checked_callback_offset(source_offset)
                inline_target_queries << target_offset
              end
            end
          end
        end
      end
      unless inline_target_queries.size == measured.total_inline_relocations &&
             inline_data_patches.size == inline_target_queries.size
        raise UnsupportedFormatError.new("inline Data relocation query roster changed after preflight")
      end
      standard_data_query_count = data_queries.size
      unless data_patches.size == standard_data_query_count
        raise UnsupportedFormatError.new("Object shared standard Data query and patch rosters differ")
      end
      inline_target_queries.each { |query| data_queries << query }

      planned_inline_positions = if inline_target_queries.empty?
                                   [] of Tuple(UInt64, UInt64)
                                 else
                                   CompressedMarkWriter.plan_literal_positions(
                                     data.size.to_i64,
                                     inline_target_queries,
                                     frame_bytes: frame_bytes,
                                     budget: transport_budget,
                                   )
                                 end
      inline_data_patches.each_with_index do |source_offset, index|
        coordinate = planned_inline_positions[index]? ||
                     raise(UnsupportedFormatError.new("inline Data position plan is truncated"))
        write_u64_le(data, source_offset, coordinate[0])
        write_u64_le(data, source_offset + 8, coordinate[1])
      end

      output = Hash(String, CompressedMarkFiles).new
      data_positions = CompressedMarkWriter.encode_with_positions(
        data, offsets[1], rows, data_queries, frame_bytes: frame_bytes, budget: transport_budget
      )
      unless data_positions.count == data_queries.size
        raise UnsupportedFormatError.new("Object shared Data position query count changed during compression")
      end
      planned_inline_positions.each_with_index do |planned, index|
        actual = data_positions.position_at(standard_data_query_count + index)
        unless actual == planned
          raise UnsupportedFormatError.new("literal-LZ4 Data position plan disagrees with encoded positions")
        end
      end
      output["data"] = data_positions.files
      patch_positions!(data_positions, data_patches, {
        "structure"        => structure,
        "paths_marks"      => paths_marks,
        "substreams_marks" => substreams_marks,
      }, 0, data_queries.size, standard_data_query_count)

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

    # Produces the same validated bucket layout as `encode`, but leaves every
    # MarkInCompressedFile coordinate unresolved and returns its exact lane
    # target as a relocation. Compact nested callbacks must be assembled into
    # the containing Data stream before those coordinates can be finalized.
    def self.materialize_inline_raw(
      version : Int,
      parents : Array(ObjectSharedPhysicalParentMark),
      codec_budget : BinaryCodecBudget,
    ) : ObjectSharedPhysicalBucketRawLayout
      validate_version!(version)
      unless codec_budget.writing?
        raise ArgumentError.new("Object shared physical raw materialization requires a write-direction codec budget")
      end
      codec_budget.ensure_depth(1)
      validate_parents!(version, parents)

      measured = measure_input(parents, codec_budget)
      # A path Data stream may itself carry callback-local mark relocations.
      # They are rebased through the exact callback event intervals below;
      # the containing Data lane resolves them only after its literal-LZ4
      # positions are known.
      codec_budget.ensure_future_elements(measured.total_paths)
      parents.each do |parent|
        parent.chunk_count.times do |chunk_index|
          chunk = parent.chunk_at(chunk_index)
          chunk.path_count.times do |path_index|
            path = chunk.path_at(path_index)
            codec_budget.charge_elements(1_u64)
          end
        end
      end
      codec_budget.ensure_wire_bytes(measured.total_raw_size.to_u64)
      codec_budget.ensure_future_nodes(checked_add(checked_add(measured.total_chunks, measured.total_paths), measured.total_events))
      codec_budget.ensure_future_elements(checked_add(checked_add(measured.total_paths, measured.total_events), measured.total_name_bytes))

      layouts, raw_sizes, _rows, _offsets = plan_layouts(parents)
      unless raw_sizes == measured.raw_sizes
        raise UnsupportedFormatError.new("Object shared input changed after inline raw preflight")
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
      populate_lane_bytes!(layouts, data, paths_marks, substreams, substreams_marks, metadata,
        structure, codec_budget)

      structure_prefix_size = raw_sizes[0].to_i64 - measured.total_chunks.to_i64 * ObjectSharedChunkStructureCodec::TRANSPORT_SUFFIX_BYTES.to_i64
      if structure_prefix_size < 0 || structure_prefix_size > Int32::MAX
        raise UnsupportedFormatError.new("Object shared inline structure prefix extent is invalid")
      end
      suffix_size = checked_int32(measured.total_chunks.to_i64 * ObjectSharedChunkStructureCodec::TRANSPORT_SUFFIX_BYTES.to_i64)
      codec_budget.ensure_wire_bytes(structure_prefix_size.to_u64 + suffix_size.to_u64)
      structure_prefix = Bytes.new(structure_prefix_size.to_i32, 0_u8)
      structure_suffix = Bytes.new(suffix_size, 0_u8)

      # Three fixed marks per chunk, three per path, one per callback event,
      # plus every child callback relocation folded into this Data lane.
      # Reserve the complete roster (including owned lane-name bytes) before
      # allocating relocation records or appending to the array.
      expected_relocation_count = checked_add(
        checked_add(
          checked_add(
            checked_multiply(measured.total_chunks, 3_u64),
            checked_multiply(measured.total_paths, 3_u64),
          ),
          measured.total_events,
        ),
        measured.total_inline_relocations,
      )
      unless expected_relocation_count <= Int32::MAX.to_u64
        raise UnsupportedFormatError.new("Object shared inline relocation roster exceeds Int32")
      end
      relocation_elements = checked_multiply(expected_relocation_count, 3_u64)
      relocation_name_bytes = checked_add(
        checked_add(
          checked_add(
            checked_multiply(measured.total_chunks,
              "structure_suffix".bytesize.to_u64 * 3_u64 + "data".bytesize.to_u64 +
              "paths_marks".bytesize.to_u64 + "paths_substreams_metadata".bytesize.to_u64),
            checked_multiply(measured.total_paths,
              "paths_marks".bytesize.to_u64 + "data".bytesize.to_u64 +
              "paths_substreams_metadata".bytesize.to_u64 * 2_u64 + "substreams".bytesize.to_u64 +
              "substreams_marks".bytesize.to_u64),
          ),
          checked_multiply(measured.total_events,
            "substreams_marks".bytesize.to_u64 + "data".bytesize.to_u64),
        ),
        checked_multiply(measured.total_inline_relocations,
          "data".bytesize.to_u64 * 2_u64),
      )
      codec_budget.ensure_future_nodes(expected_relocation_count)
      codec_budget.ensure_future_elements(relocation_elements)
      codec_budget.ensure_wire_bytes(relocation_name_bytes)
      expected_relocation_count.times { codec_budget.charge_node }
      codec_budget.charge_elements(relocation_elements) if relocation_elements > 0_u64
      codec_budget.charge_wire_bytes(relocation_name_bytes) if relocation_name_bytes > 0_u64

      relocations = Array(ObjectSharedInlineLaneRelocation).new(expected_relocation_count.to_i)
      prefix_cursor = 0
      suffix_cursor = 0
      layouts.each do |parent_chunks|
        parent_chunks.each do |layout|
          record_size = structure_record_size(layout.record)
          record_start = layout.suffix_offset + ObjectSharedChunkStructureCodec::TRANSPORT_SUFFIX_BYTES.to_i - record_size
          prefix_size = layout.suffix_offset - record_start
          unless record_start == prefix_cursor + suffix_cursor && prefix_size >= 0 &&
                 layout.suffix_offset + ObjectSharedChunkStructureCodec::TRANSPORT_SUFFIX_BYTES.to_i <= structure.size
            raise UnsupportedFormatError.new("Object shared inline structure split changed after layout preflight")
          end
          if prefix_size > 0
            structure[record_start, prefix_size].copy_to(structure_prefix[prefix_cursor, prefix_size])
            prefix_cursor += prefix_size
          end
          source_suffix = structure[layout.suffix_offset, ObjectSharedChunkStructureCodec::TRANSPORT_SUFFIX_BYTES]
          target_suffix = structure_suffix[suffix_cursor, ObjectSharedChunkStructureCodec::TRANSPORT_SUFFIX_BYTES]
          source_suffix.copy_to(target_suffix)

          suffix_base = suffix_cursor.to_u64
          relocations << ObjectSharedInlineLaneRelocation.new(
            "structure_suffix", suffix_base, "data", layout.data_start
          )
          relocations << ObjectSharedInlineLaneRelocation.new(
            "structure_suffix", suffix_base + 16_u64, "paths_marks", layout.paths_mark_start
          )
          relocations << ObjectSharedInlineLaneRelocation.new(
            "structure_suffix", suffix_base + 32_u64, "paths_substreams_metadata", layout.metadata_start
          )

          layout.paths.each do |path_layout|
            relocations << ObjectSharedInlineLaneRelocation.new(
              "paths_marks", path_layout.paths_mark_offset.to_u64, "data", path_layout.data_start
            )
            relocations << ObjectSharedInlineLaneRelocation.new(
              "paths_substreams_metadata", path_layout.metadata_offset.to_u64,
              "substreams", path_layout.substreams_offset.to_u64
            )
            relocations << ObjectSharedInlineLaneRelocation.new(
              "paths_substreams_metadata", path_layout.metadata_offset.to_u64 + 16_u64,
              "substreams_marks", path_layout.substreams_marks_offset.to_u64
            )
            path_layout.path.streams.event_count.times do |event_index|
              event = path_layout.path.streams.event_at(event_index)
              relocations << ObjectSharedInlineLaneRelocation.new(
                "substreams_marks",
                path_layout.substreams_marks_offset.to_u64 + event_index.to_u64 * 16_u64,
                "data",
                checked_add(path_layout.data_start, event.relative_offset),
              )
            end
            streams = path_layout.path.streams
            if streams.callback_relocation_count > 0
              callback_intervals = callback_interval_map(streams, codec_budget)
              validate_callback_relocations!(streams, callback_intervals, codec_budget)
              streams.callback_relocation_count.times do |relocation_index|
                relocation = streams.callback_relocation_at(relocation_index)
                source = callback_intervals[relocation.source_callback]? ||
                         raise(UnsupportedFormatError.new("inline Data relocation source callback is absent"))
                target = callback_intervals[relocation.target_callback]? ||
                         raise(UnsupportedFormatError.new("inline Data relocation target callback is absent"))
                source_offset = checked_add(
                  path_layout.data_start,
                  checked_add(source[0], relocation.source_offset),
                )
                target_offset = checked_add(
                  path_layout.data_start,
                  checked_add(target[0], relocation.target_offset),
                )
                relocations << ObjectSharedInlineLaneRelocation.new(
                  "data",
                  source_offset,
                  "data",
                  target_offset,
                )
              end
            end
          end
          suffix_cursor += ObjectSharedChunkStructureCodec::TRANSPORT_SUFFIX_BYTES
        end
      end
      unless prefix_cursor == structure_prefix.size && suffix_cursor == structure_suffix.size
        raise UnsupportedFormatError.new("Object shared inline structure split does not cover its measured extent")
      end
      unless relocations.size.to_u64 == expected_relocation_count
        raise UnsupportedFormatError.new("Object shared inline relocation roster changed after preflight")
      end

      lanes = {
        "structure_prefix"          => structure_prefix,
        "data"                      => data,
        "paths_marks"               => paths_marks,
        "substreams"                => substreams,
        "substreams_marks"          => substreams_marks,
        "paths_substreams_metadata" => metadata,
        "structure_suffix"          => structure_suffix,
      }
      ObjectSharedPhysicalBucketRawLayout.new(lanes, relocations, codec_budget)
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
      position_start : Int = 0,
      expected_position_count : Int? = nil,
      expected_patch_count : Int? = nil,
    ) : Nil
      expected_count = expected_position_count || patches.size
      unless positions.count == expected_count && position_start >= 0 &&
             position_start <= positions.count && patches.size <= positions.count - position_start
        raise UnsupportedFormatError.new("Object shared coordinate query count changed")
      end
      if expected_patches = expected_patch_count
        unless patches.size == expected_patches
          raise UnsupportedFormatError.new("Object shared coordinate patch roster changed")
        end
      end
      patches.each_with_index do |patch, index|
        bytes = lanes[patch.lane]? || raise(UnsupportedFormatError.new("Object shared coordinate patch lane is missing"))
        coordinate = positions.position_at(position_start + index)
        write_u64_le(bytes, patch.offset, coordinate[0])
        write_u64_le(bytes, patch.offset + 8, coordinate[1])
      end
      nil
    end

    private def self.callback_interval_map(
      streams : ObjectSharedPathStreams,
      budget : BinaryCodecBudget,
    ) : Hash(String, Tuple(UInt64, UInt64))
      count = streams.event_count.to_u64
      element_count = checked_multiply(count, 2_u64)
      name_bytes = 0_u64
      count.to_i.times do |index|
        name_bytes = checked_add(name_bytes, streams.event_at(index).name_byte_size.to_u64)
      end
      budget.ensure_future_nodes(count)
      budget.ensure_future_elements(element_count)
      budget.ensure_wire_bytes(name_bytes)
      count.times { budget.charge_node }
      budget.charge_elements(element_count) if element_count > 0_u64
      budget.charge_wire_bytes(name_bytes) if name_bytes > 0_u64

      intervals = Hash(String, Tuple(UInt64, UInt64)).new(initial_capacity: count.to_i)
      previous_offset = 0_u64
      count.to_i.times do |index|
        event = streams.event_at(index)
        start = event.relative_offset
        finish = if index + 1 < count.to_i
                   streams.event_at(index + 1).relative_offset
                 else
                   streams.data_size.to_u64
                 end
        unless start >= previous_offset && start <= finish && finish <= streams.data_size.to_u64
          raise UnsupportedFormatError.new("inline callback event intervals are not monotone within path Data")
        end
        name = event.name
        if intervals.has_key?(name)
          raise UnsupportedFormatError.new("inline callback event names are duplicated")
        end
        intervals[name] = {start, finish}
        previous_offset = start
      end
      intervals
    end

    private def self.validate_callback_relocations!(
      streams : ObjectSharedPathStreams,
      intervals : Hash(String, Tuple(UInt64, UInt64)),
      budget : BinaryCodecBudget,
    ) : Nil
      count = streams.callback_relocation_count.to_u64
      return nil if count == 0_u64
      unless count <= Int32::MAX.to_u64
        raise UnsupportedFormatError.new("inline Data relocation roster exceeds Int32")
      end

      name_bytes = 0_u64
      count.to_i.times do |index|
        relocation = streams.callback_relocation_at(index)
        name_bytes = checked_add(name_bytes, relocation.source_callback_byte_size.to_u64)
        name_bytes = checked_add(name_bytes, relocation.target_callback_byte_size.to_u64)
      end
      work = relocation_validation_work(count)
      budget.ensure_future_nodes(count)
      budget.ensure_future_elements(work)
      budget.ensure_wire_bytes(name_bytes)
      count.times { budget.charge_node }
      budget.charge_elements(work) if work > 0_u64
      budget.charge_wire_bytes(name_bytes) if name_bytes > 0_u64

      source_fields = Array(Tuple(String, UInt64, UInt64)).new(count.to_i)
      count.to_i.times do |index|
        relocation = streams.callback_relocation_at(index)
        source_name = relocation.source_callback
        target_name = relocation.target_callback
        source = intervals[source_name]? ||
                 raise(UnsupportedFormatError.new("inline Data relocation source callback is absent"))
        target = intervals[target_name]? ||
                 raise(UnsupportedFormatError.new("inline Data relocation target callback is absent"))
        source_size = source[1] - source[0]
        target_size = target[1] - target[0]
        source_end = checked_add(relocation.source_offset, ObjectSharedInlineCallbackRelocation::COORDINATE_BYTES)
        unless source_end <= source_size && relocation.target_offset <= target_size
          raise UnsupportedFormatError.new("inline Data relocation exceeds its callback interval")
        end
        source_fields << {source_name, relocation.source_offset, source_end}
      end
      unless source_fields.size.to_u64 == count
        raise UnsupportedFormatError.new("inline Data relocation source roster changed after preflight")
      end
      source_fields.sort! do |left, right|
        name_order = left[0] <=> right[0]
        name_order == 0 ? left[1] <=> right[1] : name_order
      end
      source_fields.each_cons(2) do |pair|
        if pair[0][0] == pair[1][0] && pair[1][1] < pair[0][2]
          raise UnsupportedFormatError.new("inline Data relocation source fields overlap")
        end
      end
      nil
    end

    private def self.relocation_validation_work(count : UInt64) : UInt64
      return 0_u64 if count == 0_u64
      if count > UInt64::MAX // 3_u64
        raise UnsupportedFormatError.new("inline relocation validation work overflows UInt64")
      end
      sort_levels = 0_u64
      remaining = count - 1_u64
      while remaining > 0_u64
        sort_levels += 1_u64
        remaining >>= 1
      end
      sort_work = checked_multiply(count, sort_levels)
      checked_add(count * 3_u64, sort_work)
    end

    private def self.checked_callback_offset(value : UInt64) : Int32
      unless value <= Int32::MAX.to_u64
        raise UnsupportedFormatError.new("inline Data relocation source exceeds Int32")
      end
      value.to_i32
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
      inline_relocations = 0_u64
      inline_relocation_name_bytes = 0_u64
      inline_interval_events = 0_u64
      inline_interval_name_bytes = 0_u64
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
            if path.streams.callback_relocation_count > 0
              inline_relocations = checked_add(
                inline_relocations,
                path.streams.callback_relocation_count.to_u64,
              )
              inline_interval_events = checked_add(
                inline_interval_events,
                path.streams.event_count.to_u64,
              )
              path.streams.event_count.times do |event_index|
                inline_interval_name_bytes = checked_add(
                  inline_interval_name_bytes,
                  path.streams.event_at(event_index).name_byte_size.to_u64,
                )
              end
              path.streams.callback_relocation_count.times do |relocation_index|
                relocation = path.streams.callback_relocation_at(relocation_index)
                inline_relocation_name_bytes = checked_add(
                  inline_relocation_name_bytes,
                  relocation.source_callback_byte_size.to_u64,
                )
                inline_relocation_name_bytes = checked_add(
                  inline_relocation_name_bytes,
                  relocation.target_callback_byte_size.to_u64,
                )
              end
            end
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
      callback_interval_elements = checked_multiply(inline_interval_events, 2_u64)
      relocation_validation_elements = relocation_validation_work(inline_relocations)
      inline_sidecar_elements = checked_multiply(inline_relocations, 2_u64)
      callback_extra_nodes = checked_add(inline_interval_events, inline_relocations)
      callback_extra_elements = checked_add(
        checked_add(callback_interval_elements, relocation_validation_elements),
        inline_sidecar_elements,
      )
      callback_name_bytes = checked_add(inline_interval_name_bytes, inline_relocation_name_bytes)
      base_nodes = checked_add(checked_add(chunks, paths), events)
      base_elements = checked_add(checked_add(paths, events), names)
      budget.ensure_future_nodes(checked_add(base_nodes, callback_extra_nodes))
      budget.ensure_future_elements(checked_add(base_elements, callback_extra_elements))
      budget.ensure_wire_bytes(checked_add(lower_wire, callback_name_bytes))
      InputMeasurement.new(raw_sizes.map { |size| checked_int32(size) }, paths, events, names,
        chunks, inline_relocations, inline_relocation_name_bytes, inline_interval_events,
        inline_interval_name_bytes, total_raw)
    end

    private def self.checked_query_count(
      chunks : UInt64,
      paths : UInt64,
      events : UInt64,
      inline_relocations : UInt64,
    ) : Int64
      if chunks > UInt64::MAX // 3_u64 || paths > UInt64::MAX // 3_u64
        raise UnsupportedFormatError.new("Object shared coordinate query count overflows")
      end
      total = checked_add(checked_add(checked_add(chunks * 3_u64, paths * 3_u64), events), inline_relocations)
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
