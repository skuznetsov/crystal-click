module CrystalClick
  # Emits unpublished literal-LZ4 frames paired with a plain adaptive mark
  # grid. Frame boundaries are independent of logical mark boundaries.
  module CompressedMarkWriter
    MARK_RECORD_SIZE = 24

    def self.encode(
      bytes : Bytes,
      offsets : Array(UInt64),
      rows_per_mark : Array(UInt64),
      prefix_size : Int = 0,
      frame_bytes : Int = 4096,
      budget : CompressedStreamBudget = CompressedStreamBudget.write_default,
    ) : CompressedMarkFiles
      files, _positions = encode_internal(bytes, offsets, rows_per_mark, prefix_size, frame_bytes, budget, nil)
      files
    end

    # Encodes the ordinary paired files while mapping arbitrary logical byte
    # coordinates into the same physical frame position space as the marks.
    # Query results consume record/result budget but are not file bytes.
    def self.encode_with_positions(
      bytes : Bytes,
      offsets : Array(UInt64),
      rows_per_mark : Array(UInt64),
      position_queries : Array(UInt64),
      prefix_size : Int = 0,
      frame_bytes : Int = 4096,
      budget : CompressedStreamBudget = CompressedStreamBudget.write_default,
    ) : CompressedMarkPositionFiles
      files, positions = encode_internal(bytes, offsets, rows_per_mark, prefix_size, frame_bytes, budget, position_queries)
      CompressedMarkPositionFiles.new(files, positions.not_nil!)
    end

    # Plans coordinates for this writer's literal-only LZ4 framing without
    # compressing or allocating paired files. This arithmetic is not valid for
    # content-dependent compression: keep it coupled to measure_frames and
    # physical_position, and invalidate it if frame encoding changes.
    def self.plan_literal_positions(
      byte_size : Int64,
      position_queries : Array(UInt64),
      frame_bytes : Int = 4096,
      budget : CompressedStreamBudget = CompressedStreamBudget.write_default,
    ) : Array(Tuple(UInt64, UInt64))
      budget.ensure_direction(true)
      validate_frame_bytes(frame_bytes)
      if byte_size < 0
        raise ArgumentError.new("negative compressed input size")
      end
      if byte_size > Int32::MAX.to_i64
        raise UnsupportedFormatError.new("compressed input exceeds supported in-memory domain")
      end

      query_count = position_queries.size.to_i64
      if query_count > Int64::MAX // 16_i64
        raise UnsupportedFormatError.new("compressed position result size overflows")
      end
      query_result_bytes = query_count * 16_i64

      # Fail capacity checks before traversing or allocating from the caller's
      # query collection. These are non-consumptive until every query is valid.
      budget.preflight_records(query_count)
      budget.preflight_result_bytes(query_result_bytes)
      position_queries.each do |query|
        if query > byte_size.to_u64
          raise ArgumentError.new("compressed position query is outside the logical byte domain")
        end
      end

      _frame_count, data_size, full_frame_size = measure_frames(
        byte_size, frame_bytes.to_i64, budget.limits
      )
      ensure_output_domain(data_size, "compressed data")

      # The result array is the only allocated output of planning, so charge
      # its retained coordinates before constructing it. No file or decoded
      # bytes are produced by this method.
      budget.reserve_records(query_count)
      budget.reserve_result_bytes(query_result_bytes)

      positions = Array(Tuple(UInt64, UInt64)).new(position_queries.size)
      position_queries.each do |query|
        compressed_offset, decompressed_offset = physical_position(
          query.to_i64,
          byte_size,
          frame_bytes.to_i64,
          full_frame_size,
          data_size,
        )
        positions << {compressed_offset.to_u64, decompressed_offset.to_u64}
      end
      positions
    end

    private def self.encode_internal(
      bytes : Bytes,
      offsets : Array(UInt64),
      rows_per_mark : Array(UInt64),
      prefix_size : Int,
      frame_bytes : Int,
      budget : CompressedStreamBudget,
      position_queries : Array(UInt64)?,
    ) : Tuple(CompressedMarkFiles, Array(Tuple(UInt64, UInt64))?)
      budget.ensure_direction(true)
      validate_frame_bytes(frame_bytes)
      validate_grid(bytes, offsets, rows_per_mark, prefix_size, frame_bytes)

      query_count = 0_i64
      if queries = position_queries
        query_count = queries.size.to_i64
      end
      if query_count > Int64::MAX // 16_i64
        raise UnsupportedFormatError.new("compressed position result size overflows")
      end
      query_result_bytes = query_count * 16_i64

      mark_count = offsets.size.to_i64
      if mark_count > Int32::MAX.to_i64 // MARK_RECORD_SIZE
        raise UnsupportedFormatError.new("adaptive mark output exceeds supported in-memory domain")
      end

      frame_count = frame_count_for(bytes.size.to_i64, frame_bytes.to_i64)
      base_record_count = frame_count + mark_count
      if query_count > Int64::MAX - base_record_count
        raise UnsupportedFormatError.new("compressed position record count overflows")
      end

      # Query count and result storage are known from the caller's array size.
      # Reject a capacity failure before traversing an attacker-sized query
      # list; these checks are non-consumptive, and the normal reservations
      # below still happen only after query values pass domain validation.
      if position_queries
        budget.preflight_records(base_record_count + query_count)
        budget.preflight_result_bytes(query_result_bytes)
      end
      if queries = position_queries
        queries.each do |query|
          if query > bytes.size.to_u64
            raise ArgumentError.new("compressed position query is outside the logical byte domain")
          end
        end
      end

      # Reserve known work before traversing a potentially highly-fragmented
      # logical stream. Frame sizes are measured arithmetically in O(1).
      # Position-query records are included before allocating their result.
      budget.reserve_records(base_record_count + query_count)
      budget.reserve_decoded_bytes(bytes.size.to_i64)

      _measured_frame_count, data_size, full_frame_size = measure_frames(bytes.size.to_i64, frame_bytes.to_i64, budget.limits)
      mark_size = mark_count * MARK_RECORD_SIZE
      total_size = data_size + mark_size
      if mark_size > budget.limits.max_mark_bytes
        raise UnsupportedFormatError.new("adaptive marks exceed configured mark-size limit")
      end
      ensure_output_domain(data_size, "compressed data")
      ensure_output_domain(mark_size, "adaptive marks")
      ensure_output_domain(total_size, "paired output")
      if query_result_bytes > Int64::MAX - total_size
        raise UnsupportedFormatError.new("compressed position result size overflows")
      end
      total_result_size = total_size + query_result_bytes

      # Account for every known record and byte before creating either output.
      budget.reserve_file_bytes(total_size)
      budget.reserve_result_bytes(total_result_size)

      data = encode_data(bytes, frame_bytes.to_i64, data_size, budget.limits)
      marks = encode_marks(offsets, rows_per_mark, bytes.size.to_i64, prefix_size.to_i64,
        frame_bytes.to_i64, full_frame_size, data_size, mark_size.to_i)
      positions = nil.as(Array(Tuple(UInt64, UInt64))?)
      if queries = position_queries
        encoded_positions = Array(Tuple(UInt64, UInt64)).new(queries.size)
        queries.each do |query|
          compressed_offset, decompressed_offset = physical_position(
            query.to_i64,
            bytes.size.to_i64,
            frame_bytes.to_i64,
            full_frame_size,
            data_size,
          )
          encoded_positions << {compressed_offset.to_u64, decompressed_offset.to_u64}
        end
        positions = encoded_positions
      end
      {CompressedMarkFiles.new(data, marks), positions}
    end

    # Encodes Object/Dynamic structure metadata whose repeated real marks name
    # the position immediately before its suffix statistics flag. Unlike the
    # ordinary lane API, this permits that prefix coordinate to cross frames.
    # The full metadata stream still receives a terminal physical-EOF record.
    def self.encode_metadata(
      bytes : Bytes,
      statistics_offset : Int,
      rows_per_mark : Array(UInt64),
      frame_bytes : Int = 4096,
      budget : CompressedStreamBudget = CompressedStreamBudget.write_default,
    ) : CompressedMarkFiles
      budget.ensure_direction(true)
      validate_frame_bytes(frame_bytes)
      unless statistics_offset >= 0 && statistics_offset < bytes.size
        raise ArgumentError.new("statistics offset must name a byte within the metadata stream")
      end
      if bytes.size > Int32::MAX
        raise UnsupportedFormatError.new("compressed input exceeds supported in-memory domain")
      end
      if rows_per_mark.empty?
        raise ArgumentError.new("metadata marks require at least one real outer row count")
      end
      if rows_per_mark.size > Int32::MAX - 1
        raise UnsupportedFormatError.new("adaptive metadata mark grid exceeds supported in-memory domain")
      end

      # Reserve header/mark work before traversing row counts or allocating a
      # repeated-offset collection. This is intentionally consumptive on a
      # later row-count validation failure.
      mark_count = rows_per_mark.size.to_i64 + 1_i64
      frame_count = frame_count_for(bytes.size.to_i64, frame_bytes.to_i64)
      budget.reserve_records(frame_count + mark_count)
      rows_per_mark.each do |rows|
        if rows == 0_u64 || rows > Int32::MAX.to_u64
          raise ArgumentError.new("real mark rows must be positive Int32 values")
        end
      end
      budget.reserve_decoded_bytes(bytes.size.to_i64)

      _measured_frame_count, data_size, full_frame_size = measure_frames(bytes.size.to_i64, frame_bytes.to_i64, budget.limits)
      mark_size = mark_count * MARK_RECORD_SIZE
      total_size = data_size + mark_size
      if mark_size > budget.limits.max_mark_bytes
        raise UnsupportedFormatError.new("adaptive marks exceed configured mark-size limit")
      end
      ensure_output_domain(data_size, "compressed data")
      ensure_output_domain(mark_size, "adaptive marks")
      ensure_output_domain(total_size, "paired output")
      budget.reserve_file_bytes(total_size)
      budget.reserve_result_bytes(total_size)

      data = encode_data(bytes, frame_bytes.to_i64, data_size, budget.limits)
      marks = encode_metadata_marks(
        rows_per_mark,
        bytes.size.to_i64,
        statistics_offset.to_i64,
        frame_bytes.to_i64,
        full_frame_size,
        data_size,
        mark_size.to_i
      )
      CompressedMarkFiles.new(data, marks)
    end

    # A side-effect-free aggregate guard used by a multi-lane owner before it
    # requests byte/offset snapshots. Each lane has the same outer mark count.
    def self.preflight_batch(
      raw_sizes : Array(Int32),
      mark_count : Int,
      frame_bytes : Int,
      budget : CompressedStreamBudget,
    ) : Nil
      preflight_batch_internal(raw_sizes, mark_count, 0_i64, frame_bytes, budget)
    end

    # Side-effect-free aggregate guard for paired lanes plus caller-owned
    # physical-position query results. Query records and their retained
    # coordinates share the same budget as the paired transport.
    def self.preflight_batch_with_positions(
      raw_sizes : Array(Int32),
      mark_count : Int,
      position_query_count : Int64,
      frame_bytes : Int,
      budget : CompressedStreamBudget,
    ) : Nil
      preflight_batch_internal(raw_sizes, mark_count, position_query_count, frame_bytes, budget)
    end

    private def self.preflight_batch_internal(
      raw_sizes : Array(Int32),
      mark_count : Int,
      position_query_count : Int64,
      frame_bytes : Int,
      budget : CompressedStreamBudget,
    ) : Nil
      budget.ensure_direction(true)
      validate_frame_bytes(frame_bytes)
      if position_query_count < 0
        raise ArgumentError.new("compressed position query count must be nonnegative")
      end
      if position_query_count > Int64::MAX // 16_i64
        raise UnsupportedFormatError.new("compressed position result size overflows")
      end
      query_result_bytes = position_query_count * 16_i64
      unless mark_count >= 2 && mark_count <= Int32::MAX
        raise ArgumentError.new("paired output requires at least one real mark and one terminal")
      end
      if raw_sizes.empty?
        raise ArgumentError.new("paired output requires at least one physical lane")
      end

      total_records = 0_i64
      total_decoded_bytes = 0_i64
      total_output_bytes = 0_i64
      mark_bytes = mark_count.to_i64 * MARK_RECORD_SIZE
      if mark_bytes > budget.limits.max_mark_bytes
        raise UnsupportedFormatError.new("adaptive marks exceed configured mark-size limit")
      end

      raw_sizes.each do |raw_size|
        if raw_size < 0
          raise ArgumentError.new("negative paired lane size")
        end
        frame_count = frame_count_for(raw_size.to_i64, frame_bytes.to_i64)
        _measured_frame_count, data_size, _full_frame_size = measure_frames(raw_size.to_i64, frame_bytes.to_i64, budget.limits)
        if total_records > Int64::MAX - frame_count - mark_count.to_i64 ||
           total_decoded_bytes > Int64::MAX - raw_size.to_i64 ||
           total_output_bytes > Int64::MAX - data_size - mark_bytes
          raise UnsupportedFormatError.new("paired output aggregate size overflows")
        end
        total_records += frame_count + mark_count.to_i64
        total_decoded_bytes += raw_size.to_i64
        total_output_bytes += data_size + mark_bytes
      end

      if position_query_count > Int64::MAX - total_records
        raise UnsupportedFormatError.new("compressed position record count overflows")
      end
      if query_result_bytes > Int64::MAX - total_output_bytes
        raise UnsupportedFormatError.new("compressed position result size overflows")
      end

      budget.preflight_records(total_records + position_query_count)
      budget.preflight_decoded_bytes(total_decoded_bytes)
      budget.preflight_file_bytes(total_output_bytes)
      budget.preflight_result_bytes(total_output_bytes + query_result_bytes)
      nil
    end

    # Encodes a complete unmarked stream. Empty input is ambiguous without a
    # paired grid and therefore remains a caller error.
    def self.encode_all(
      bytes : Bytes,
      frame_bytes : Int = 4096,
      budget : CompressedStreamBudget = CompressedStreamBudget.write_default,
    ) : Bytes
      budget.ensure_direction(true)
      validate_frame_bytes(frame_bytes)
      raise ArgumentError.new("empty compressed stream is unsupported without a mark grid") if bytes.empty?
      raise UnsupportedFormatError.new("compressed input exceeds supported in-memory domain") if bytes.size > Int32::MAX

      frame_count = frame_count_for(bytes.size.to_i64, frame_bytes.to_i64)
      budget.reserve_records(frame_count)
      budget.reserve_decoded_bytes(bytes.size.to_i64)

      _measured_frame_count, data_size, _full_frame_size = measure_frames(bytes.size.to_i64, frame_bytes.to_i64, budget.limits)
      ensure_output_domain(data_size, "compressed data")

      budget.reserve_file_bytes(data_size)
      budget.reserve_result_bytes(data_size)

      encode_data(bytes, frame_bytes.to_i64, data_size, budget.limits)
    end

    private def self.validate_frame_bytes(frame_bytes : Int) : Nil
      if frame_bytes <= 0 || frame_bytes > Int32::MAX
        raise ArgumentError.new("frame size must be a positive Int32 value")
      end
    end

    private def self.frame_count_for(byte_size : Int64, frame_bytes : Int64) : Int64
      return 0_i64 if byte_size == 0
      1_i64 + (byte_size - 1_i64) // frame_bytes
    end

    private def self.validate_grid(
      bytes : Bytes,
      offsets : Array(UInt64),
      rows_per_mark : Array(UInt64),
      prefix_size : Int,
      frame_bytes : Int,
    ) : Nil
      if prefix_size < 0 || prefix_size > Int32::MAX || prefix_size > bytes.size
        raise ArgumentError.new("prefix size is outside the input byte domain")
      end
      if prefix_size > frame_bytes
        raise ArgumentError.new("frame zero cannot contain the complete prefix")
      end
      raise ArgumentError.new("mark offsets must include the terminal record") if offsets.empty?
      if offsets.size != rows_per_mark.size + 1
        raise ArgumentError.new("mark offsets must contain one terminal after every real row count")
      end
      if bytes.size > Int32::MAX
        raise UnsupportedFormatError.new("compressed input exceeds supported in-memory domain")
      end
      if bytes.empty?
        raise ArgumentError.new("empty input requires a zero prefix") unless prefix_size == 0
      elsif rows_per_mark.empty?
        raise ArgumentError.new("nonempty data requires at least one real mark")
      end

      unless offsets.first == prefix_size.to_u64
        raise ArgumentError.new("first mark must name the serialization prefix")
      end
      unless offsets.last == bytes.size.to_u64
        raise ArgumentError.new("terminal mark offset must equal the logical byte size")
      end

      previous = offsets.first
      offsets.each_with_index do |offset, index|
        if offset < previous || offset > bytes.size.to_u64
          raise ArgumentError.new("mark offsets must be monotone and within the byte domain")
        end
        previous = offset

        next if index == rows_per_mark.size
        rows = rows_per_mark[index]
        if rows == 0_u64 || rows > Int32::MAX.to_u64
          raise ArgumentError.new("real mark rows must be positive Int32 values")
        end
      end
    end

    # Returns (frame count, complete physical data size, positioning unit).
    # Its work is O(1), including streams split into one-byte frames.
    private def self.measure_frames(
      byte_size : Int64,
      frame_bytes : Int64,
      limits : CompressedStreamLimits,
    ) : Tuple(Int64, Int64, Int64)
      return {0_i64, 0_i64, 0_i64} if byte_size == 0

      full_chunk_count = byte_size // frame_bytes
      remainder = byte_size % frame_bytes
      frame_count = full_chunk_count + (remainder == 0 ? 0_i64 : 1_i64)

      full_frame_size = 0_i64
      full_total_size = 0_i64
      if full_chunk_count > 0
        full_frame_size = physical_frame_size(frame_bytes, limits)
        if full_frame_size > Int64::MAX // full_chunk_count
          raise UnsupportedFormatError.new("compressed data output size overflows")
        end
        full_total_size = full_chunk_count * full_frame_size
      end

      total_size = full_total_size
      if remainder > 0
        remainder_frame_size = physical_frame_size(remainder, limits)
        full_frame_size = remainder_frame_size if full_chunk_count == 0
        if remainder_frame_size > Int32::MAX.to_i64 - total_size
          raise UnsupportedFormatError.new("compressed data output exceeds supported in-memory domain")
        end
        total_size += remainder_frame_size
      end
      if total_size > Int32::MAX.to_i64
        raise UnsupportedFormatError.new("compressed data output exceeds supported in-memory domain")
      end
      {frame_count, total_size, full_frame_size}
    end

    private def self.physical_frame_size(raw_size : Int64, limits : CompressedStreamLimits) : Int64
      if raw_size <= 0 || raw_size > Int32::MAX.to_i64 || raw_size > limits.max_frame_decompressed_bytes
        raise UnsupportedFormatError.new("LZ4 frame exceeds configured decompressed-size limit")
      end

      extension_size = raw_size < 15_i64 ? 0_i64 : ((raw_size - 15_i64) // 255_i64) + 1_i64
      payload_size = 1_i64 + extension_size + raw_size
      compressed_size = CompressedBlock::HEADER_SIZE.to_i64 + payload_size
      if compressed_size > UInt32::MAX.to_i64 || compressed_size > limits.max_frame_compressed_bytes
        raise UnsupportedFormatError.new("LZ4 frame exceeds configured compressed-size limit")
      end
      CompressedBlock::CHECKSUM_SIZE.to_i64 + compressed_size
    end

    private def self.ensure_output_domain(size : Int64, label : String) : Nil
      if size < 0 || size > Int32::MAX.to_i64
        raise UnsupportedFormatError.new("#{label} output exceeds supported in-memory domain")
      end
    end

    private def self.encode_data(
      bytes : Bytes,
      frame_bytes : Int64,
      expected_size : Int64,
      limits : CompressedStreamLimits,
    ) : Bytes
      output = Bytes.new(expected_size.to_i, 0_u8)
      source_offset = 0_i64
      output_offset = 0_i64
      while source_offset < bytes.size.to_i64
        remaining = bytes.size.to_i64 - source_offset
        chunk_size = remaining < frame_bytes ? remaining : frame_bytes
        frame_size = write_lz4_frame(output, output_offset.to_i, bytes, source_offset.to_i, chunk_size.to_i, limits)
        source_offset += chunk_size
        output_offset += frame_size
      end
      unless output_offset == expected_size
        raise UnsupportedFormatError.new("compressed output size changed during encoding")
      end
      output
    end

    private def self.write_lz4_frame(
      output : Bytes,
      output_offset : Int,
      source : Bytes,
      source_offset : Int,
      raw_size : Int,
      limits : CompressedStreamLimits,
    ) : Int64
      raw_size_i64 = raw_size.to_i64
      frame_size = physical_frame_size(raw_size_i64, limits)
      compressed_size = frame_size - CompressedBlock::CHECKSUM_SIZE
      header_offset = output_offset + CompressedBlock::CHECKSUM_SIZE
      output[header_offset] = CompressedBlock::METHOD_LZ4
      write_u32_le(output, header_offset + 1, compressed_size.to_u32)
      write_u32_le(output, header_offset + 5, raw_size.to_u32)

      cursor = output_offset + CompressedBlock::FRAME_HEADER_SIZE
      if raw_size < 15
        output[cursor] = (raw_size << 4).to_u8
        cursor += 1
      else
        output[cursor] = 0xf0_u8
        cursor += 1
        remaining = raw_size - 15
        while remaining >= 255
          output[cursor] = 255_u8
          cursor += 1
          remaining -= 255
        end
        output[cursor] = remaining.to_u8
        cursor += 1
      end
      source[source_offset, raw_size].copy_to(output[cursor, raw_size])

      checksum = CityHashV1.hash128(output[header_offset, compressed_size.to_i])
      write_u64_le(output, output_offset, checksum[0])
      write_u64_le(output, output_offset + 8, checksum[1])
      frame_size
    end

    private def self.encode_marks(
      offsets : Array(UInt64),
      rows_per_mark : Array(UInt64),
      byte_size : Int64,
      prefix_size : Int64,
      frame_bytes : Int64,
      full_frame_size : Int64,
      data_size : Int64,
      mark_size : Int,
    ) : Bytes
      marks = Bytes.new(mark_size, 0_u8)
      terminal_index = rows_per_mark.size
      offsets.each_with_index do |offset, index|
        # The prefix mark has a stricter wire identity than ordinary logical
        # EOF aliases: it is always frame zero plus the prefix offset, even if
        # the prefix consumes the entire logical stream.
        compressed_offset, decompressed_offset = if index == 0
                                                   {0_i64, prefix_size}
                                                 else
                                                   physical_position(offset.to_i64, byte_size, frame_bytes, full_frame_size, data_size)
                                                 end
        row_count = index == terminal_index ? 0_u64 : rows_per_mark[index]
        record_offset = index * MARK_RECORD_SIZE
        write_u64_le(marks, record_offset, compressed_offset.to_u64)
        write_u64_le(marks, record_offset + 8, decompressed_offset.to_u64)
        write_u64_le(marks, record_offset + 16, row_count)
      end
      marks
    end

    private def self.encode_metadata_marks(
      rows_per_mark : Array(UInt64),
      byte_size : Int64,
      statistics_offset : Int64,
      frame_bytes : Int64,
      full_frame_size : Int64,
      data_size : Int64,
      mark_size : Int,
    ) : Bytes
      marks = Bytes.new(mark_size, 0_u8)
      compressed_offset, decompressed_offset = physical_position(
        statistics_offset,
        byte_size,
        frame_bytes,
        full_frame_size,
        data_size
      )
      rows_per_mark.each_with_index do |rows, index|
        record_offset = index * MARK_RECORD_SIZE
        write_u64_le(marks, record_offset, compressed_offset.to_u64)
        write_u64_le(marks, record_offset + 8, decompressed_offset.to_u64)
        write_u64_le(marks, record_offset + 16, rows)
      end
      terminal_offset = rows_per_mark.size * MARK_RECORD_SIZE
      write_u64_le(marks, terminal_offset, data_size.to_u64)
      write_u64_le(marks, terminal_offset + 8, 0_u64)
      write_u64_le(marks, terminal_offset + 16, 0_u64)
      marks
    end

    private def self.physical_position(
      logical_offset : Int64,
      byte_size : Int64,
      frame_bytes : Int64,
      full_frame_size : Int64,
      data_size : Int64,
    ) : Tuple(Int64, Int64)
      if logical_offset == byte_size
        return {data_size, 0_i64}
      end

      frame_index = logical_offset // frame_bytes
      in_frame_offset = logical_offset % frame_bytes
      {frame_index * full_frame_size, in_frame_offset}
    end

    private def self.write_u32_le(bytes : Bytes, offset : Int, value : UInt32) : Nil
      4.times do |index|
        bytes[offset + index] = ((value >> (index * 8)) & 0xff_u32).to_u8
      end
    end

    private def self.write_u64_le(bytes : Bytes, offset : Int, value : UInt64) : Nil
      8.times do |index|
        bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8
      end
    end
  end
end
