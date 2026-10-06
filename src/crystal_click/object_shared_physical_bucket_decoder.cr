module CrystalClick
  # Resolves the six authenticated logical lanes into physical-parent and
  # logical-chunk records. Coordinate indexes remain private to lane readers;
  # this owner enforces exact contiguous consumption across every parent.
  class ObjectSharedPhysicalBucketDecoder
    def self.decode(
      version : Int,
      lane_inputs : ObjectSharedPhysicalBucketLaneInputs,
      expected_parent_rows : Array(UInt64),
      codec_budget : BinaryCodecBudget,
      transport_budget : CompressedStreamBudget,
    ) : Array(ObjectSharedPhysicalParentMark)
      validate_version!(version)
      unless !codec_budget.writing?
        raise ArgumentError.new("Object shared physical decode requires a read-direction codec budget")
      end
      transport_budget.ensure_direction(false)
      codec_budget.ensure_depth(1)
      validate_expected_rows!(expected_parent_rows)

      lanes = Hash(String, ObjectSharedPhysicalLaneReader).new
      ObjectSharedPhysicalBucketLaneInputs::LANE_NAMES.each do |name|
        lanes[name] = ObjectSharedPhysicalLaneReader.new(
          name, lane_inputs.lane(name), expected_parent_rows, codec_budget, transport_budget
        )
      end

      structure = lanes["structure"]
      if expected_parent_rows.size > structure.logical_size // MINIMUM_CHUNK_STRUCTURE_BYTES
        raise CorruptPartError.new("Object shared structure cannot contain the expected physical parents")
      end
      structure_bytes = structure.bytes
      data_bytes = lanes["data"].bytes
      paths_marks_bytes = lanes["paths_marks"].bytes
      substreams_bytes = lanes["substreams"].bytes
      substreams_marks_bytes = lanes["substreams_marks"].bytes
      metadata_bytes = lanes["paths_substreams_metadata"].bytes

      parents = [] of ObjectSharedPhysicalParentMark
      expected_parent_rows.each_with_index do |physical_rows, parent_index|
        parent = decode_parent(
          version,
          parent_index,
          physical_rows,
          lanes,
          structure_bytes,
          data_bytes,
          paths_marks_bytes,
          substreams_bytes,
          substreams_marks_bytes,
          metadata_bytes,
          codec_budget
        )
        parents << parent
      end
      parents
    end

    private def self.decode_parent(
      version : Int,
      parent_index : Int,
      physical_rows : UInt64,
      lanes : Hash(String, ObjectSharedPhysicalLaneReader),
      structure_bytes : Bytes,
      data_bytes : Bytes,
      paths_marks_bytes : Bytes,
      substreams_bytes : Bytes,
      substreams_marks_bytes : Bytes,
      metadata_bytes : Bytes,
      budget : BinaryCodecBudget,
    ) : ObjectSharedPhysicalParentMark
      structure_lane = lanes["structure"]
      data_lane = lanes["data"]
      paths_marks_lane = lanes["paths_marks"]
      substreams_lane = lanes["substreams"]
      substreams_marks_lane = lanes["substreams_marks"]
      metadata_lane = lanes["paths_substreams_metadata"]

      structure_start = structure_lane.outer_position(parent_index)
      structure_end = structure_lane.outer_position(parent_index + 1)
      if structure_start < 0 || structure_end <= structure_start || structure_end > structure_bytes.size.to_i64
        raise CorruptPartError.new("Object shared structure parent interval is empty or outside its lane")
      end
      parent_structure_size = structure_end - structure_start
      structure_slice = structure_bytes[structure_start.to_i, parent_structure_size.to_i]
      context = BinaryCodecContext.new(budget.limits, structure_slice, false, budget, false)

      cursors = ObjectSharedPhysicalLaneCursors.new(
        data_lane.outer_position(parent_index),
        paths_marks_lane.outer_position(parent_index),
        substreams_lane.outer_position(parent_index),
        substreams_marks_lane.outer_position(parent_index),
        metadata_lane.outer_position(parent_index)
      )
      ends = ObjectSharedPhysicalLaneCursors.new(
        data_lane.outer_position(parent_index + 1),
        paths_marks_lane.outer_position(parent_index + 1),
        substreams_lane.outer_position(parent_index + 1),
        substreams_marks_lane.outer_position(parent_index + 1),
        metadata_lane.outer_position(parent_index + 1)
      )
      chunks = [] of ObjectSharedPhysicalChunk

      current = read_chunk_structure(context)
      chunk_count = 0
      while record = current
        next_record = if context.input_offset < structure_slice.size
                        read_chunk_structure(context)
                      else
                        nil
                      end
        if version == 2 && (chunk_count > 0 || next_record != nil)
          raise CorruptPartError.new("ADVANCED v2 physical parent must contain exactly one chunk")
        end
        chunk_data_end = if following = next_record
                           coordinate_position(data_lane, following.data_marks, "next chunk Data start")
                         else
                           ends.data
                         end
        chunk = decode_chunk(
          record,
          chunk_data_end,
          cursors,
          ends,
          data_lane,
          paths_marks_lane,
          substreams_lane,
          substreams_marks_lane,
          metadata_lane,
          data_bytes,
          paths_marks_bytes,
          substreams_bytes,
          substreams_marks_bytes,
          metadata_bytes,
          budget
        )
        chunks << chunk
        chunk_count += 1
        current = next_record
      end

      if chunk_count == 0
        raise CorruptPartError.new("Object shared physical parent contains no logical chunks")
      end
      context.ensure_consumed
      if cursors.data != ends.data || cursors.paths_marks != ends.paths_marks ||
         cursors.substreams != ends.substreams || cursors.substreams_marks != ends.substreams_marks ||
         cursors.metadata != ends.metadata
        raise CorruptPartError.new("Object shared logical records leave unreferenced bytes inside a physical parent")
      end
      begin
        ObjectSharedPhysicalParentMark.new(physical_rows, chunks)
      rescue ex : ArgumentError
        raise CorruptPartError.new("invalid Object shared physical parent: #{ex.message}")
      end
    end

    private def self.decode_chunk(
      record : ObjectSharedChunkStructure,
      chunk_data_end : Int64,
      cursors : ObjectSharedPhysicalLaneCursors,
      ends : ObjectSharedPhysicalLaneCursors,
      data_lane : ObjectSharedPhysicalLaneReader,
      paths_marks_lane : ObjectSharedPhysicalLaneReader,
      substreams_lane : ObjectSharedPhysicalLaneReader,
      substreams_marks_lane : ObjectSharedPhysicalLaneReader,
      metadata_lane : ObjectSharedPhysicalLaneReader,
      data_bytes : Bytes,
      paths_marks_bytes : Bytes,
      substreams_bytes : Bytes,
      substreams_marks_bytes : Bytes,
      metadata_bytes : Bytes,
      budget : BinaryCodecBudget,
    ) : ObjectSharedPhysicalChunk
      if record.row_count > Int32::MAX.to_u64
        raise CorruptPartError.new("Object shared logical chunk row count exceeds Int32")
      end
      if record.row_count == 0_u64 && record.path_count != 0
        raise CorruptPartError.new("zero-row Object shared chunks must be pathless")
      end

      chunk_data_start = coordinate_position(data_lane, record.data_marks, "chunk Data start")
      chunk_paths_start = coordinate_position(paths_marks_lane, record.paths_marks, "chunk PathsMarks start")
      chunk_metadata_start = coordinate_position(metadata_lane, record.paths_substreams_metadata_marks,
        "chunk path metadata start")
      unless chunk_data_start == cursors.data && chunk_paths_start == cursors.paths_marks &&
             chunk_metadata_start == cursors.metadata
        raise CorruptPartError.new("Object shared chunk lane starts are not contiguous within the parent")
      end
      if chunk_data_end < chunk_data_start || chunk_data_end > ends.data
        raise CorruptPartError.new("Object shared chunk Data interval is outside its physical parent")
      end

      if record.path_count == 0
        unless chunk_data_end == chunk_data_start
          raise CorruptPartError.new("pathless Object shared chunk has unowned Data bytes")
        end
      end
      chunk_paths_end = checked_add(cursors.paths_marks,
        checked_multiply(record.path_count.to_i64, 16_i64, "chunk PathsMarks size"), "chunk PathsMarks end")
      chunk_metadata_end = checked_add(cursors.metadata,
        checked_multiply(record.path_count.to_i64, 32_i64, "chunk metadata size"), "chunk metadata end")
      if chunk_paths_end > ends.paths_marks || chunk_metadata_end > ends.metadata
        raise CorruptPartError.new("Object shared chunk path rosters exceed a physical-parent lane interval")
      end

      paths = [] of ObjectSharedPhysicalPath
      record.path_count.times do |path_index|
        path_mark_offset = checked_add(cursors.paths_marks, checked_multiply(path_index.to_i64, 16_i64,
          "path mark offset"), "path mark offset")
        path_data_start = coordinate_position(data_lane,
          read_pair(paths_marks_bytes, path_mark_offset, ends.paths_marks, "PathsMarks entry"),
          "path Data start")
        path_data_end = if path_index + 1 < record.path_count
                          next_offset = checked_add(path_mark_offset, 16_i64, "next path mark offset")
                          coordinate_position(data_lane,
                            read_pair(paths_marks_bytes, next_offset, ends.paths_marks, "PathsMarks entry"),
                            "next path Data start")
                        else
                          chunk_data_end
                        end
        if path_data_start < chunk_data_start || path_data_end < path_data_start || path_data_end > chunk_data_end
          raise CorruptPartError.new("Object shared path Data interval is outside its chunk")
        end
        if path_index == 0 && path_data_start != chunk_data_start
          raise CorruptPartError.new("first Object shared path does not begin at its chunk Data start")
        end

        metadata_offset = checked_add(cursors.metadata, checked_multiply(path_index.to_i64, 32_i64,
          "path metadata offset"), "path metadata offset")
        substreams_start = coordinate_position(substreams_lane,
          read_pair(metadata_bytes, metadata_offset, ends.metadata, "path metadata substream pointer"),
          "path substreams start")
        substreams_marks_start = coordinate_position(substreams_marks_lane,
          read_pair(metadata_bytes, checked_add(metadata_offset, 16_i64, "path metadata marks pointer"),
            ends.metadata, "path metadata marks pointer"),
          "path substream marks start")
        unless substreams_start == cursors.substreams && substreams_marks_start == cursors.substreams_marks
          raise CorruptPartError.new("Object shared path substream starts are not contiguous within the parent")
        end

        path = decode_path(
          record.path_at(path_index),
          path_data_start,
          path_data_end,
          substreams_start,
          ends.substreams,
          substreams_marks_start,
          ends.substreams_marks,
          data_lane,
          substreams_lane,
          substreams_marks_lane,
          data_bytes,
          substreams_bytes,
          substreams_marks_bytes,
          budget
        )
        paths << path[0]
        cursors.substreams = path[1]
        cursors.substreams_marks = path[2]
      end

      cursors.data = chunk_data_end
      cursors.paths_marks = chunk_paths_end
      cursors.metadata = chunk_metadata_end
      if cursors.paths_marks > ends.paths_marks || cursors.metadata > ends.metadata ||
         cursors.substreams > ends.substreams || cursors.substreams_marks > ends.substreams_marks
        raise CorruptPartError.new("Object shared chunk exceeds a physical-parent lane interval")
      end
      begin
        ObjectSharedPhysicalChunk.new(record.row_count, paths)
      rescue ex : ArgumentError
        raise CorruptPartError.new("invalid Object shared physical chunk: #{ex.message}")
      end
    end

    private def self.decode_path(
      name : String,
      data_start : Int64,
      data_end : Int64,
      substreams_start : Int64,
      substreams_end : Int64,
      substreams_marks_start : Int64,
      substreams_marks_end : Int64,
      data_lane : ObjectSharedPhysicalLaneReader,
      substreams_lane : ObjectSharedPhysicalLaneReader,
      substreams_marks_lane : ObjectSharedPhysicalLaneReader,
      data_bytes : Bytes,
      substreams_bytes : Bytes,
      substreams_marks_bytes : Bytes,
      budget : BinaryCodecBudget,
    ) : Tuple(ObjectSharedPhysicalPath, Int64, Int64)
      if substreams_start < 0 || substreams_start > substreams_end || substreams_end > substreams_lane.logical_size
        raise CorruptPartError.new("Object shared substream record is outside its physical parent")
      end
      if substreams_marks_start < 0 || substreams_marks_start > substreams_marks_end ||
         substreams_marks_end > substreams_marks_lane.logical_size
        raise CorruptPartError.new("Object shared substream marks are outside their physical parent")
      end
      remaining = substreams_end - substreams_start
      input = substreams_bytes[substreams_start.to_i, remaining.to_i]
      context = BinaryCodecContext.new(budget.limits, input, false, budget, false)
      raw_event_count = context.read_var_uint
      event_count = context.preflight_metadata(
        raw_event_count,
        1_u64,
        Int32::MAX.to_u64,
        "Object shared path callback count"
      )
      marks_size = checked_multiply(event_count.to_i64, 16_i64, "path callback marks")
      marks_end = checked_add(substreams_marks_start, marks_size, "path callback marks end")
      if marks_end > substreams_marks_end
        raise CorruptPartError.new("Object shared callback count exceeds its path marks extent")
      end

      path_size = data_end - data_start
      if path_size < 0 || path_size > data_bytes.size.to_i64 || data_start < 0 || data_end > data_bytes.size
        raise CorruptPartError.new("Object shared path data interval is outside Data")
      end
      events = Array(ObjectSharedPathSubstreamEvent).new(event_count)
      previous_relative = 0_u64
      event_count.times do |event_index|
        name_size = context.read_var_uint
        if name_size > Int32::MAX.to_u64
          raise CorruptPartError.new("Object shared callback name exceeds Int32")
        end
        budget.ensure_future_elements(name_size)
        name_bytes = context.read_slice(name_size)
        budget.charge_elements(name_size)
        event_mark_offset = checked_add(substreams_marks_start,
          checked_multiply(event_index.to_i64, 16_i64, "callback mark offset"), "callback mark offset")
        absolute = coordinate_position(data_lane,
          read_pair(substreams_marks_bytes, event_mark_offset, substreams_marks_end,
            "callback Data mark"),
          "callback Data position")
        if absolute < data_start || absolute > data_end
          raise CorruptPartError.new("Object shared callback position is outside its path Data interval")
        end
        relative = (absolute - data_start).to_u64
        if relative < previous_relative || (event_index == 0 && relative != 0_u64)
          raise CorruptPartError.new("Object shared callback tape is not ordered from path byte zero")
        end
        budget.visit_node(1)
        begin
          events << ObjectSharedPathSubstreamEvent.new(String.new(name_bytes), relative)
        rescue ex : ArgumentError
          raise CorruptPartError.new("invalid Object shared callback name: #{ex.message}")
        end
        previous_relative = relative
      end

      next_substreams = checked_add(substreams_start, context.input_offset.to_i64, "next substream record")
      data = Bytes.new(path_size.to_i) do |index|
        data_bytes[data_start.to_i + index]
      end
      streams = ObjectSharedPathStreams.new(data, events)
      begin
        {ObjectSharedPhysicalPath.new(name, streams), next_substreams, marks_end}
      rescue ex : ArgumentError
        raise CorruptPartError.new("invalid Object shared physical path: #{ex.message}")
      end
    end

    private def self.read_chunk_structure(context : BinaryCodecContext) : ObjectSharedChunkStructure
      ObjectSharedChunkStructureCodec.read_from(context)
    rescue ex : ArgumentError
      raise CorruptPartError.new("invalid Object shared chunk structure: #{ex.message}")
    end

    private def self.coordinate_position(
      lane : ObjectSharedPhysicalLaneReader,
      pair : Tuple(UInt64, UInt64),
      label : String,
    ) : Int64
      position = lane.logical_position(pair[0], pair[1])
      if position < 0 || position > lane.logical_size || position > Int32::MAX
        raise CorruptPartError.new("Object shared #{label} is outside its lane")
      end
      position
    end

    private def self.read_pair(bytes : Bytes, offset : Int64, extent : Int64, label : String) : Tuple(UInt64, UInt64)
      if offset < 0 || offset > extent - 16 || offset > bytes.size.to_i64 - 16
        raise CorruptPartError.new("Object shared #{label} is truncated")
      end
      {read_u64_le(bytes, offset.to_i), read_u64_le(bytes, offset.to_i + 8)}
    end

    private def self.read_u64_le(bytes : Bytes, offset : Int) : UInt64
      if offset < 0 || offset > bytes.size - 8
        raise CorruptPartError.new("Object shared UInt64 coordinate is truncated")
      end
      value = 0_u64
      8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
      value
    end

    private def self.validate_expected_rows!(rows : Array(UInt64)) : Nil
      if rows.empty? || rows.size >= Int32::MAX
        raise CorruptPartError.new("Object shared expected physical parent grid is empty or oversized")
      end
      rows.each do |count|
        if count == 0_u64 || count > Int32::MAX.to_u64
          raise CorruptPartError.new("Object shared expected parent rows are outside the adaptive domain")
        end
      end
    end

    private def self.validate_version!(version : Int) : Nil
      unless version == 2 || version == 3
        raise UnsupportedFormatError.new("Object shared physical reader supports only ADVANCED v2/v3")
      end
    end

    private def self.checked_add(left : Int64, right : Int64, label : String) : Int64
      if left < 0 || right < 0 || right > Int64::MAX - left
        raise CorruptPartError.new("Object shared #{label} overflows")
      end
      left + right
    end

    private def self.checked_multiply(left : Int64, right : Int64, label : String) : Int64
      if left < 0 || right < 0 || (right > 0 && left > Int64::MAX // right)
        raise CorruptPartError.new("Object shared #{label} overflows")
      end
      left * right
    end

    MINIMUM_CHUNK_STRUCTURE_BYTES = 50_i64
  end
end
