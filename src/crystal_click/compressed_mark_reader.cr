module CrystalClick
  # Reads one paired adaptive mark grid and returns an owned selected window.
  # The data mapping is callback-scoped; only the copied result survives it.
  module CompressedMarkReader
    MARK_RECORD_SIZE = 24

    private struct RangeSpan
      getter start : Int64
      getter finish : Int64
      getter output_index : Int32

      def initialize(@start : Int64, @finish : Int64, @output_index : Int32)
      end
    end

    def self.read(
      data_path : String,
      marks_path : String,
      expected_data_size : Int64,
      expected_mark_size : Int64,
      first_mark : Int = 0,
      mark_count : Int? = nil,
      prefix_size : Int = 0,
      budget : CompressedStreamBudget = CompressedStreamBudget.read_default,
    ) : CompressedMarkWindow
      budget.ensure_direction(false)
      validate_expected_size(expected_data_size, "data")
      validate_expected_size(expected_mark_size, "mark")
      raise ArgumentError.new("first mark must be nonnegative") if first_mark < 0
      raise ArgumentError.new("mark count must be nonnegative") if mark_count && mark_count < 0
      raise ArgumentError.new("prefix size must be nonnegative") if prefix_size < 0
      if prefix_size > Int32::MAX
        raise ArgumentError.new("prefix size exceeds supported in-memory domain")
      end

      limits = budget.limits
      if expected_mark_size > limits.max_mark_bytes
        raise CorruptPartError.new("mark file exceeds configured limit")
      end
      if expected_data_size > Int32::MAX || expected_mark_size > Int32::MAX
        raise CorruptPartError.new("paired file exceeds supported in-memory domain")
      end
      if expected_data_size > Int64::MAX - expected_mark_size
        raise ArgumentError.new("paired file sizes overflow")
      end
      budget.reserve_file_bytes(expected_data_size + expected_mark_size)

      mark_record_count = if expected_mark_size > 0 && expected_mark_size % MARK_RECORD_SIZE == 0
                            expected_mark_size // MARK_RECORD_SIZE
                          else
                            0_i64
                          end
      if mark_record_count > Int32::MAX
        raise CorruptPartError.new("mark grid exceeds supported in-memory domain")
      end
      # Known grid work is charged before mapping or allocating its records.
      budget.reserve_records(mark_record_count) if mark_record_count > 0

      marks = read_marks(marks_path, expected_mark_size, limits, budget, mark_record_count)
      lane_count = marks.size - 1
      raise ArgumentError.new("first mark is outside the grid") if first_mark > lane_count
      selected_count = mark_count || (lane_count - first_mark)
      if selected_count > lane_count - first_mark
        raise ArgumentError.new("mark selection is outside the grid")
      end
      if selected_count > Int32::MAX
        raise ArgumentError.new("mark selection exceeds supported in-memory domain")
      end

      if expected_data_size == 0
        validate_empty_grid!(marks, lane_count, prefix_size)
        verify_empty_regular_file(data_path)
        return empty_window(marks, first_mark, selected_count, prefix_size)
      end

      raise CorruptPartError.new("zero-domain mark grid requires empty data") if lane_count == 0
      ensure_not_symlink(data_path, "data file")

      window = nil.as(CompressedMarkWindow?)
      MMapDataSource.with_file(data_path, expected_data_size, limits.max_file_bytes) do |data|
        index = CompressedFrameIndex.new(data, limits, budget)
        positions = validate_grid!(marks, index, prefix_size)
        window = selected_window(data, marks, positions, index, first_mark, selected_count, prefix_size, budget)
      end
      window.not_nil!
    end

    # Inspects and validates the full physical row grid without authenticating
    # or decoding any compressed payload. Returned coordinates and row counts
    # are detached from both mmap lifetimes and parser-owned collections.
    def self.inspect(
      data_path : String,
      marks_path : String,
      expected_data_size : Int64,
      expected_mark_size : Int64,
      prefix_size : Int? = nil,
      budget : CompressedStreamBudget = CompressedStreamBudget.read_default,
    ) : CompressedMarkGrid
      budget.ensure_direction(false)
      validate_expected_size(expected_data_size, "data")
      validate_expected_size(expected_mark_size, "mark")
      if expected_mark_size > budget.limits.max_mark_bytes
        raise CorruptPartError.new("mark file exceeds configured limit")
      end
      if expected_data_size > Int32::MAX || expected_mark_size > Int32::MAX
        raise CorruptPartError.new("paired file exceeds supported in-memory domain")
      end
      if expected_data_size > Int64::MAX - expected_mark_size
        raise ArgumentError.new("paired file sizes overflow")
      end
      if requested_prefix = prefix_size
        if requested_prefix < 0 || requested_prefix > Int32::MAX
          raise ArgumentError.new("prefix size exceeds supported in-memory domain")
        end
      end
      budget.reserve_file_bytes(expected_data_size + expected_mark_size)

      mark_record_count = if expected_mark_size > 0 && expected_mark_size % MARK_RECORD_SIZE == 0
                            expected_mark_size // MARK_RECORD_SIZE
                          else
                            0_i64
                          end
      if mark_record_count > Int32::MAX
        raise CorruptPartError.new("mark grid exceeds supported in-memory domain")
      end
      # Bound proportional mark parsing before mapping or allocating records.
      budget.reserve_records(mark_record_count) if mark_record_count > 0

      marks = read_marks(marks_path, expected_mark_size, budget.limits, budget, mark_record_count)
      lane_count = marks.size - 1
      if expected_data_size == 0
        validate_empty_grid!(marks, lane_count, 0)
        if prefix_size && prefix_size != 0
          raise CorruptPartError.new("empty data requires a zero prefix")
        end
        verify_empty_regular_file(data_path)
        positions = Array(Int64).new(marks.size, 0_i64)
        rows = Array(UInt64).new(lane_count)
        lane_count.times { |mark| rows << marks[mark].rows }
        return CompressedMarkGrid.new(positions, rows, 0, 0_i64)
      end

      raise CorruptPartError.new("zero-domain mark grid requires empty data") if lane_count == 0
      ensure_not_symlink(data_path, "data file")

      grid = nil.as(CompressedMarkGrid?)
      MMapDataSource.with_file(data_path, expected_data_size, budget.limits.max_file_bytes) do |data|
        index = CompressedFrameIndex.new(data, budget.limits, budget)
        grid = inspected_grid(marks, index, prefix_size)
      end
      grid.not_nil!
    end

    # Reads an unmarked stream in full. This deliberately rejects empty input:
    # without a paired grid there is no lane-domain evidence for an empty file.
    def self.read_all(
      path : String,
      expected_size : Int64,
      budget : CompressedStreamBudget = CompressedStreamBudget.read_default,
      maximum_output_size : Int64? = nil,
      expected_file_hash : {UInt64, UInt64}? = nil,
    ) : Bytes
      budget.ensure_direction(false)
      validate_expected_size(expected_size, "data")
      if maximum_output_size && maximum_output_size < 0
        raise ArgumentError.new("maximum output size must be nonnegative")
      end
      raise CorruptPartError.new("empty compressed stream is unsupported without a mark grid") if expected_size == 0
      if expected_size > Int32::MAX
        raise CorruptPartError.new("data file exceeds supported in-memory domain")
      end
      budget.reserve_file_bytes(expected_size)
      ensure_not_symlink(path, "data file")

      output = nil.as(Bytes?)
      MMapDataSource.with_file(path, expected_size, budget.limits.max_file_bytes) do |data|
        limits = budget.limits
        if expected_file_hash && CityHashV1.file_hash(data) != expected_file_hash
          raise CorruptPartError.new("compressed file hash does not match checksums.txt")
        end
        index = CompressedFrameIndex.new(data, limits, budget)
        if maximum = maximum_output_size
          if index.logical_size > maximum
            raise CorruptPartError.new("decompressed result exceeds its declared output size")
          end
        end
        decoded_work = 0_i64
        index.frames.each do |frame|
          decoded_work = checked_add(decoded_work, frame.decompressed_size, "decoded work")
          if frame.method == CompressedBlock::METHOD_MULTIPLE
            nested_size = multiple_nested_size(data, frame, limits)
            decoded_work = checked_add(decoded_work, nested_size, "nested decoded work")
          end
        end
        budget.reserve_decoded_bytes(decoded_work)
        if index.logical_size > Int32::MAX
          raise CorruptPartError.new("decompressed result exceeds supported in-memory domain")
        end
        budget.reserve_result_bytes(index.logical_size)

        result = Bytes.new(index.logical_size.to_i)
        workspace = CompressedBlock::DecodeWorkspace.new
        index.frames.each do |frame|
          decoded = decode_touched_frame(data, frame, workspace, limits)
          decoded.copy_to(result[frame.logical_start.to_i, decoded.size])
        end
        output = result
      end
      output.not_nil!
    end

    # Reads ordered logical half-open intervals from an unprefixed compressed
    # stream. Frame indexing is fresh for each call; one decoded frame is
    # authenticated and decoded once even when several or duplicate ranges
    # overlap it. Result order and duplicate ranges match the input exactly.
    def self.read_ranges(
      data_path : String,
      expected_data_size : Int64,
      ranges : Array({Int64, Int64}),
      budget : CompressedStreamBudget,
    ) : Array(Bytes)
      budget.ensure_direction(false)
      validate_expected_size(expected_data_size, "data")
      if expected_data_size == 0
        raise CorruptPartError.new("empty compressed stream is unsupported without a mark grid")
      end
      if expected_data_size > budget.limits.max_file_bytes || expected_data_size > Int32::MAX
        raise CorruptPartError.new("data file exceeds supported in-memory limit")
      end
      if ranges.size > Int32::MAX
        raise CorruptPartError.new("logical range count exceeds supported in-memory domain")
      end

      # Charge even zero-byte ranges before allocating their detached result
      # descriptors. Empty intervals still carry caller-visible order.
      budget.reserve_records(ranges.size.to_i64)
      spans = Array(RangeSpan).new(ranges.size)
      total_result_size = 0_i64
      ranges.each_with_index do |range, index|
        start, finish = range
        if start < 0 || finish < start
          raise ArgumentError.new("logical range must be nonnegative and ordered")
        end
        size = finish - start
        if size > Int32::MAX || size > Int64::MAX - total_result_size
          raise CorruptPartError.new("logical range result exceeds supported in-memory domain")
        end
        total_result_size += size
        spans << RangeSpan.new(start, finish, index.to_i32) if finish > start
      end
      spans.sort_by! { |span| {span.start, span.finish, span.output_index} }

      preflight_regular_file(data_path, expected_data_size, "data file")
      budget.reserve_file_bytes(expected_data_size)
      results = nil.as(Array(Bytes)?)
      MMapDataSource.with_file(data_path, expected_data_size, budget.limits.max_file_bytes) do |data|
        limits = budget.limits
        index = CompressedFrameIndex.new(data, limits, budget)
        ranges.each do |range|
          if range[1] > index.logical_size
            raise ArgumentError.new("logical range is outside the decompressed stream")
          end
        end

        decoded_work = 0_i64
        each_touched_frame(index.frames, spans) do |frame, _active|
          decoded_work = checked_add(decoded_work, frame.decompressed_size, "decoded work")
          if frame.method == CompressedBlock::METHOD_MULTIPLE
            decoded_work = checked_add(decoded_work, multiple_nested_size(data, frame, limits), "nested decoded work")
          end
        end
        # Reserve the complete touched decode and all output bytes before any
        # result buffers or decoder workspace are grown.
        budget.reserve_decoded_bytes(decoded_work)
        budget.reserve_result_bytes(total_result_size)
        output = Array(Bytes).new(ranges.size)
        ranges.each do |range|
          output << Bytes.new((range[1] - range[0]).to_i)
        end

        workspace = CompressedBlock::DecodeWorkspace.new
        each_touched_frame(index.frames, spans) do |frame, active|
          decoded = decode_touched_frame(data, frame, workspace, limits)
          active.each do |span|
            copy_range_intersection(decoded, frame, span, output[span.output_index])
          end
        end
        results = output
      end
      results.not_nil!
    end

    # Shared adaptive-mark envelope check for physical formats whose record
    # width is not the legacy two-lane MARK_RECORD_SIZE. The caller charges
    # its known record count before allocating parsed mark descriptors.
    def self.validate_plain_marks!(
      bytes : Bytes,
      record_size : Int,
      budget : CompressedStreamBudget,
      prepaid_records : Int64 = 0_i64,
    ) : Nil
      raise ArgumentError.new("mark record size must be positive") if record_size <= 0
      if compressed_mark_stream?(bytes, budget, prepaid_records, record_size)
        raise UnsupportedFormatError.new("compressed mark streams are unsupported")
      end
      unless bytes.size % record_size == 0
        raise CorruptPartError.new("adaptive mark file size is not a whole record count")
      end
      nil
    end

    private def self.each_touched_frame(
      frames : Array(CompressedFrameDescriptor),
      spans : Array(RangeSpan),
      & : CompressedFrameDescriptor, Array(RangeSpan) ->
    ) : Nil
      span_cursor = 0
      active = Array(RangeSpan).new
      frames.each do |frame|
        write_index = 0
        active.each do |span|
          if span.finish > frame.logical_start
            active[write_index] = span
            write_index += 1
          end
        end
        active.pop(active.size - write_index) if write_index < active.size
        while span_cursor < spans.size && spans[span_cursor].start < frame.logical_end
          span = spans[span_cursor]
          active << span if span.finish > frame.logical_start
          span_cursor += 1
        end
        yield frame, active unless active.empty?
      end
    end

    private def self.copy_range_intersection(
      decoded : Bytes,
      frame : CompressedFrameDescriptor,
      span : RangeSpan,
      destination : Bytes,
    ) : Nil
      start = {frame.logical_start, span.start}.max
      finish = {frame.logical_end, span.finish}.min
      return if finish <= start
      source_offset = (start - frame.logical_start).to_i
      destination_offset = (start - span.start).to_i
      size = (finish - start).to_i
      decoded[source_offset, size].copy_to(destination[destination_offset, size])
    end

    private def self.read_marks(
      path : String,
      expected_size : Int64,
      limits : CompressedStreamLimits,
      budget : CompressedStreamBudget,
      record_count : Int64,
    ) : Array(Mark)
      raise CorruptPartError.new("mark file is empty") if expected_size == 0
      ensure_not_symlink(path, "mark file")

      records = nil.as(Array(Mark)?)
      MMapDataSource.with_file(path, expected_size, limits.max_mark_bytes) do |bytes|
        validate_plain_marks!(bytes, MARK_RECORD_SIZE, budget, record_count)
        actual_count = bytes.size // MARK_RECORD_SIZE
        unless actual_count.to_i64 == record_count
          raise CorruptPartError.new("mark record count changed")
        end
        parsed = Array(Mark).new(actual_count)
        actual_count.times do |index|
          offset = index * MARK_RECORD_SIZE
          parsed << Mark.new(read_u64(bytes, offset), read_u64(bytes, offset + 8), read_u64(bytes, offset + 16))
        end
        records = parsed
      end
      records.not_nil!
    end

    private def self.validate_grid!(
      marks : Array(Mark),
      index : CompressedFrameIndex,
      prefix_size : Int,
    ) : Array(Int64)
      lane_count = marks.size - 1
      raise CorruptPartError.new("zero-domain mark grid requires empty data") if lane_count == 0
      first = marks[0]
      unless first.compressed_offset == 0_u64 && first.decompressed_offset == prefix_size.to_u64
        raise CorruptPartError.new("first mark does not name the serialization prefix")
      end

      validated_grid_positions(marks, index)
    end

    private def self.validated_grid_positions(
      marks : Array(Mark),
      index : CompressedFrameIndex,
    ) : Array(Int64)
      lane_count = marks.size - 1
      raise CorruptPartError.new("zero-domain mark grid requires empty data") if lane_count == 0

      positions = Array(Int64).new(marks.size)
      previous = -1_i64
      marks.each_with_index do |mark, mark_index|
        terminal = mark_index == lane_count
        if terminal
          raise CorruptPartError.new("terminal mark rows must be zero") unless mark.rows == 0_u64
        elsif mark.rows == 0_u64 || mark.rows > Int32::MAX.to_u64
          raise CorruptPartError.new("real mark rows are outside the adaptive domain")
        end
        position = index.logical_position(mark.compressed_offset, mark.decompressed_offset, terminal)
        if position < previous
          raise CorruptPartError.new("adaptive mark positions are not monotone")
        end
        positions << position
        previous = position
      end
      unless positions.last == index.logical_size
        raise CorruptPartError.new("terminal mark does not name logical EOF")
      end
      positions
    end

    private def self.inspected_grid(
      marks : Array(Mark),
      index : CompressedFrameIndex,
      expected_prefix_size : Int?,
    ) : CompressedMarkGrid
      lane_count = marks.size - 1
      raise CorruptPartError.new("zero-domain mark grid requires empty data") if lane_count == 0

      positions = validated_grid_positions(marks, index)
      observed_prefix = positions.first? || raise CorruptPartError.new("adaptive mark grid has no first position")
      if expected_prefix_size && observed_prefix != expected_prefix_size.to_i64
        raise CorruptPartError.new("first mark does not name the expected serialization prefix")
      end
      if observed_prefix > Int32::MAX
        raise CorruptPartError.new("serialization prefix exceeds supported in-memory domain")
      end

      rows = Array(UInt64).new(lane_count)
      lane_count.times { |mark| rows << marks[mark].rows }
      CompressedMarkGrid.new(positions, rows, observed_prefix.to_i, index.logical_size)
    end

    private def self.validate_empty_grid!(marks : Array(Mark), lane_count : Int, prefix_size : Int) : Nil
      raise CorruptPartError.new("empty data requires a zero prefix") unless prefix_size == 0
      if lane_count == 0 && marks.size != 1
        raise CorruptPartError.new("zero-domain mark grid is invalid")
      end
      marks.each_with_index do |mark, index|
        terminal = index == lane_count
        if mark.compressed_offset != 0_u64 || mark.decompressed_offset != 0_u64
          raise CorruptPartError.new("empty data mark coordinates must be zero")
        end
        if terminal
          raise CorruptPartError.new("terminal mark rows must be zero") unless mark.rows == 0_u64
        elsif mark.rows == 0_u64 || mark.rows > Int32::MAX.to_u64
          raise CorruptPartError.new("real mark rows are outside the adaptive domain")
        end
      end
    end

    private def self.selected_window(
      data : Bytes,
      marks : Array(Mark),
      positions : Array(Int64),
      index : CompressedFrameIndex,
      first_mark : Int,
      selected_count : Int,
      prefix_size : Int,
      budget : CompressedStreamBudget,
    ) : CompressedMarkWindow
      first = first_mark.to_i
      count = selected_count.to_i
      body_start = positions[first]
      body_end = positions[first + count]
      body_size = body_end - body_start
      raise CorruptPartError.new("selected body range is invalid") if body_size < 0
      result_size = checked_add(prefix_size.to_i64, body_size, "selected result")
      if result_size > Int32::MAX
        raise CorruptPartError.new("selected result exceeds supported in-memory domain")
      end

      decoded_work = 0_i64
      index.frames.each do |frame|
        next unless frame_touched?(frame, prefix_size.to_i64, body_start, body_end)
        decoded_work = checked_add(decoded_work, frame.decompressed_size, "decoded work")
        if frame.method == CompressedBlock::METHOD_MULTIPLE
          nested_size = multiple_nested_size(data, frame, budget.limits)
          decoded_work = checked_add(decoded_work, nested_size, "nested decoded work")
        end
      end
      # Both aggregate logical reservations precede checksum inspection,
      # workspace growth, or result allocation.
      budget.reserve_decoded_bytes(decoded_work)
      budget.reserve_result_bytes(result_size)

      result = Bytes.new(result_size.to_i)
      workspace = CompressedBlock::DecodeWorkspace.new
      index.frames.each do |frame|
        next unless frame_touched?(frame, prefix_size.to_i64, body_start, body_end)
        decoded = decode_touched_frame(data, frame, workspace, budget.limits)
        copy_interval(decoded, frame, 0_i64, prefix_size.to_i64, result, 0_i64)
        copy_interval(decoded, frame, body_start, body_end, result, prefix_size.to_i64 - body_start)
      end

      local_offsets = Array(UInt64).new(count + 1)
      (0..count).each do |local_mark|
        local_offsets << (prefix_size.to_i64 + positions[first + local_mark] - body_start).to_u64
      end
      local_rows = Array(UInt64).new(count)
      count.times do |local_mark|
        local_rows << marks[first + local_mark].rows
      end
      CompressedMarkWindow.new(result, local_offsets, local_rows, first_mark, prefix_size)
    end

    private def self.frame_touched?(frame : CompressedFrameDescriptor, prefix_end : Int64, body_start : Int64, body_end : Int64) : Bool
      prefix_touched = prefix_end > 0 && frame.logical_start < prefix_end && frame.logical_end > 0
      body_touched = body_end > body_start && frame.logical_start < body_end && frame.logical_end > body_start
      prefix_touched || body_touched
    end

    private def self.copy_interval(
      decoded : Bytes,
      frame : CompressedFrameDescriptor,
      interval_start : Int64,
      interval_end : Int64,
      destination : Bytes,
      destination_bias : Int64,
    ) : Nil
      return if interval_end <= interval_start
      start = {frame.logical_start, interval_start}.max
      finish = {frame.logical_end, interval_end}.min
      return if finish <= start
      source_offset = (start - frame.logical_start).to_i
      target_offset = (start + destination_bias).to_i
      size = (finish - start).to_i
      decoded[source_offset, size].copy_to(destination[target_offset, size])
    end

    private def self.decode_touched_frame(
      data : Bytes,
      frame : CompressedFrameDescriptor,
      workspace : CompressedBlock::DecodeWorkspace,
      limits : CompressedStreamLimits,
    ) : Bytes
      verify_frame_checksum!(data, frame)
      decoded = CompressedBlock.decode_frame_into(
        data,
        frame.compressed_offset,
        workspace,
        limits.max_frame_compressed_bytes,
        limits.max_frame_decompressed_bytes
      )
      unless decoded.end_offset == frame.end_offset && decoded.output.size.to_i64 == frame.decompressed_size
        raise CorruptPartError.new("decoded compressed frame disagrees with its indexed header")
      end
      decoded.output
    end

    private def self.verify_frame_checksum!(data : Bytes, frame : CompressedFrameDescriptor) : Nil
      offset = frame.compressed_offset.to_i
      actual = CityHashV1.hash128(data[offset + CompressedBlock::CHECKSUM_SIZE, frame.compressed_size.to_i])
      expected_low = read_u64(data, offset)
      expected_high = read_u64(data, offset + 8)
      unless actual[0] == expected_low && actual[1] == expected_high
        raise CorruptPartError.new("compressed frame checksum mismatch")
      end
    end

    # Returns the visible nested ZSTD output size after validating every header
    # that controls the Multiple decoder's pre-checksum workspace allocation.
    private def self.multiple_nested_size(
      data : Bytes,
      frame : CompressedFrameDescriptor,
      limits : CompressedStreamLimits,
    ) : Int64
      payload_offset = frame.compressed_offset.to_i + CompressedBlock::FRAME_HEADER_SIZE
      payload_size = (frame.compressed_size - CompressedBlock::HEADER_SIZE).to_i
      if payload_size < 4
        raise CorruptPartError.new("Multiple payload header is truncated")
      end
      method_count = data[payload_offset].to_i
      if method_count > CompressedBlock::MAX_MULTIPLE_METHODS || payload_size < 1 + method_count
        raise CorruptPartError.new("Multiple method list is invalid")
      end
      unless method_count == 2 && data[payload_offset + 1] == CompressedBlock::METHOD_DELTA &&
             data[payload_offset + 2] == CompressedBlock::METHOD_ZSTD
        raise UnsupportedFormatError.new("unsupported ClickHouse Multiple codec list")
      end

      nested_offset = payload_offset + 3
      nested_size = payload_size - 3
      if nested_size < CompressedBlock::HEADER_SIZE
        raise CorruptPartError.new("nested ZSTD header is truncated")
      end
      unless data[nested_offset] == CompressedBlock::METHOD_ZSTD
        raise UnsupportedFormatError.new("unexpected nested ClickHouse compression method")
      end
      nested_compressed = read_u32(data, nested_offset + 1).to_i64
      nested_decompressed = read_u32(data, nested_offset + 5).to_i64
      unless nested_compressed >= CompressedBlock::HEADER_SIZE && nested_compressed == nested_size
        raise CorruptPartError.new("nested compressed block size is invalid")
      end
      if nested_decompressed <= 0 || nested_decompressed > limits.max_frame_decompressed_bytes
        raise CorruptPartError.new("nested decompressed size exceeds frame limit")
      end
      expected_nested = frame.decompressed_size + 11_i64
      unless nested_decompressed == expected_nested
        raise CorruptPartError.new("nested decompressed size does not match Delta work")
      end
      nested_decompressed
    end

    private def self.compressed_mark_stream?(
      bytes : Bytes,
      budget : CompressedStreamBudget,
      prepaid_records : Int64,
      record_size : Int = MARK_RECORD_SIZE,
    ) : Bool
      # A whole-record-sized payload is authoritative adaptive-mark input.
      # Header-shaped values inside its coordinates/row counts must not
      # relabel a valid plain grid as a compressed stream.
      return false if bytes.empty? || bytes.size % record_size == 0
      offset = 0
      frame_count = 0
      while offset < bytes.size
        return false if bytes.size - offset < CompressedBlock::FRAME_HEADER_SIZE
        method = bytes[offset + CompressedBlock::CHECKSUM_SIZE]
        unless method == CompressedBlock::METHOD_LZ4 || method == CompressedBlock::METHOD_ZSTD ||
               method == CompressedBlock::METHOD_MULTIPLE
          return false
        end
        # A divisible-size candidate already has one preflighted token per
        # would-be mark record; non-grid compressed input charges each
        # recognized frame header here before inspecting its sizes.
        budget.reserve_records(1_i64) if frame_count >= prepaid_records
        compressed_size = read_u32(bytes, offset + CompressedBlock::CHECKSUM_SIZE + 1).to_i64
        decompressed_size = read_u32(bytes, offset + CompressedBlock::CHECKSUM_SIZE + 5).to_i64
        return false if compressed_size < CompressedBlock::HEADER_SIZE || decompressed_size <= 0
        frame_size = CompressedBlock::CHECKSUM_SIZE.to_i64 + compressed_size
        return false if frame_size > bytes.size.to_i64 - offset
        offset += frame_size.to_i
        frame_count += 1
      end
      frame_count > 0 && offset == bytes.size
    end

    private def self.empty_window(
      marks : Array(Mark),
      first_mark : Int,
      selected_count : Int,
      prefix_size : Int,
    ) : CompressedMarkWindow
      offsets = Array(UInt64).new(selected_count + 1, 0_u64)
      rows = Array(UInt64).new(selected_count)
      first = first_mark.to_i
      selected_count.to_i.times { |index| rows << marks[first + index].rows }
      CompressedMarkWindow.new(Bytes.new(0), offsets, rows, first_mark, prefix_size)
    end

    private def self.verify_empty_regular_file(path : String) : Nil
      ensure_not_symlink(path, "data file")
      File.open(path, "rb") do |file|
        info = file.info
        raise CorruptPartError.new("data file is not a regular file") unless info.file?
        raise CorruptPartError.new("data file size changed") unless info.size == 0
      end
    rescue ex : IO::Error
      raise CorruptPartError.new(ex.message || "cannot inspect empty data file")
    end

    private def self.ensure_not_symlink(path : String, label : String) : Nil
      raise CorruptPartError.new("#{label} must not be a symbolic link") if File.symlink?(path)
    end

    private def self.validate_expected_size(size : Int64, label : String) : Nil
      raise ArgumentError.new("expected #{label} size must be nonnegative") if size < 0
    end

    private def self.preflight_regular_file(path : String, expected_size : Int64, label : String) : Nil
      info = File.info?(path, follow_symlinks: false) || raise(CorruptPartError.new("#{label} is missing or inaccessible"))
      raise CorruptPartError.new("#{label} must not be a symbolic link") if File.symlink?(path)
      raise CorruptPartError.new("#{label} is not a regular file") unless info.type.file?
      raise CorruptPartError.new("#{label} size does not match its physical input") unless info.size == expected_size
      nil
    rescue ex : IO::Error
      raise CorruptPartError.new(ex.message || "cannot inspect #{label}")
    end

    private def self.checked_add(left : Int64, right : Int64, label : String) : Int64
      if left < 0 || right < 0 || right > Int64::MAX - left
        raise CorruptPartError.new("#{label} size overflows")
      end
      left + right
    end

    private def self.read_u32(bytes : Bytes, offset : Int) : UInt32
      if offset < 0 || offset > bytes.size - 4
        raise CorruptPartError.new("truncated compressed frame header")
      end
      bytes[offset].to_u32 |
        (bytes[offset + 1].to_u32 << 8) |
        (bytes[offset + 2].to_u32 << 16) |
        (bytes[offset + 3].to_u32 << 24)
    end

    private def self.read_u64(bytes : Bytes, offset : Int) : UInt64
      if offset < 0 || offset > bytes.size - 8
        raise CorruptPartError.new("truncated UInt64 value")
      end
      value = 0_u64
      8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
      value
    end
  end
end
