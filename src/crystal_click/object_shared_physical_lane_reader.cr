module CrystalClick
  # Owns one fully authenticated logical lane and its private coordinate map.
  # A header-only index first bounds/charges logical bytes before the paired
  # reader authenticates marks, checksums, and decompressed payloads. The index
  # retains frame descriptors only; both mmap lifetimes remain scoped.
  class ObjectSharedPhysicalLaneReader
    @name : String
    @data : Bytes
    @outer_positions : Array(Int64)
    @outer_rows : Array(UInt64)
    @data_size : UInt64
    @index : CompressedFrameIndex?
    @inline_role_read_view : ObjectSharedInlineRoleReadView?

    def initialize(
      name : String,
      input : ObjectSharedPhysicalLaneInput,
      expected_parent_rows : Array(UInt64),
      codec_budget : BinaryCodecBudget,
      budget : CompressedStreamBudget,
    )
      budget.ensure_direction(false)
      @name = String.new(name.to_slice)
      @inline_role_read_view = nil
      @data_size = input.expected_data_size.to_u64
      if expected_parent_rows.empty? || expected_parent_rows.size >= Int32::MAX
        raise CorruptPartError.new("Object shared physical parent grid is empty or oversized")
      end

      data_path = input.data_path
      marks_path = input.marks_path
      data_size = input.expected_data_size
      mark_size = input.expected_mark_size
      preflight_input!(data_path, marks_path, data_size, mark_size, budget)

      indexed = nil.as(CompressedFrameIndex?)
      if data_size > 0
        # Preserve CompressedMarkReader's paired-file work while moving only
        # the header scan before binary-byte admission. The later full reader
        # still consumes its ordinary data+marks file-byte charge.
        budget.reserve_file_bytes(data_size)
        MMapDataSource.with_file(data_path, data_size, budget.limits.max_file_bytes) do |mapped|
          indexed = CompressedFrameIndex.new(mapped, budget.limits, budget)
        end
        index = indexed.not_nil!
        if index.logical_size > Int32::MAX
          raise CorruptPartError.new("decompressed result exceeds supported in-memory domain")
        end
        codec_budget.ensure_wire_bytes(index.logical_size.to_u64)
        codec_budget.charge_wire_bytes(index.logical_size.to_u64)
      else
        codec_budget.ensure_wire_bytes(0_u64)
        codec_budget.charge_wire_bytes(0_u64)
      end
      @index = indexed

      window = CompressedMarkReader.read(
        data_path,
        marks_path,
        data_size,
        mark_size,
        prefix_size: 0,
        budget: budget
      )
      rows = window.rows_per_mark
      positions = window.offsets
      unless rows == expected_parent_rows
        raise CorruptPartError.new("Object shared #{@name} outer rows disagree with the physical parent grid")
      end
      unless positions.size == expected_parent_rows.size + 1 && positions.first? == 0_u64
        raise CorruptPartError.new("Object shared #{@name} outer mark grid has an invalid extent")
      end
      @data = window.bytes
      unless @data.size.to_i64 == positions.last.to_i64
        raise CorruptPartError.new("Object shared #{@name} decompressed lane size disagrees with terminal mark")
      end
      @outer_positions = positions.map(&.to_i64)
      @outer_rows = rows

      if index = @index
        unless index.logical_size == @data.size.to_i64
          raise CorruptPartError.new("Object shared #{@name} coordinate index disagrees with decoded lane")
        end
      else
        unless @data.empty? && @outer_positions.all?(&.zero?)
          raise CorruptPartError.new("empty Object shared #{@name} lane has nonempty logical coordinates")
        end
      end
    end

    # Builds a logical role reader over callback fragments captured from one
    # authenticated parent Data tape. The caller must provide the parent mark
    # boundaries derived from that Object's source structure schedule; this
    # owner validates their complete extent before exposing the lane.
    def initialize(
      name : String,
      role_view : ObjectSharedInlineRoleReadView,
      outer_positions : Array(Int64),
      expected_parent_rows : Array(UInt64),
      codec_budget : BinaryCodecBudget,
    )
      if codec_budget.writing?
        raise ArgumentError.new("inline physical lane read view requires a read-direction codec budget")
      end
      codec_budget.ensure_depth(1)
      unless name == role_view.role_name
        raise CorruptPartError.new("inline physical lane name differs from its source-scheduled role")
      end
      if expected_parent_rows.empty? || expected_parent_rows.size >= Int32::MAX
        raise CorruptPartError.new("inline physical parent grid is empty or oversized")
      end
      unless outer_positions.size == expected_parent_rows.size + 1 && outer_positions[0]? == 0_i64
        raise CorruptPartError.new("inline physical role mark positions have an invalid extent")
      end
      role_size = role_view.byte_size
      if role_size > Int32::MAX.to_u64 || outer_positions.last? != role_size.to_i64
        raise CorruptPartError.new("inline physical role terminal differs from its captured extent")
      end
      outer_positions.each_cons(2) do |pair|
        if pair[0] < 0 || pair[1] < pair[0] || pair[1] > role_size
          raise CorruptPartError.new("inline physical role mark positions are outside its captured extent")
        end
      end
      expected_parent_rows.each do |rows|
        if rows == 0_u64 || rows > Int32::MAX.to_u64
          raise CorruptPartError.new("inline physical parent rows must be positive Int32 values")
        end
      end

      outer_count = outer_positions.size.to_u64
      row_count = expected_parent_rows.size.to_u64
      if row_count > UInt64::MAX - outer_count
        raise CorruptPartError.new("inline physical mark record count overflows UInt64")
      end
      mark_records = outer_count + row_count
      codec_budget.ensure_future_nodes(mark_records)
      codec_budget.ensure_future_elements(mark_records)
      codec_budget.charge_elements(mark_records)
      mark_records.times { codec_budget.charge_node }

      @name = String.new(name.to_slice)
      @inline_role_read_view = role_view
      @data_size = role_size
      @data = role_view.materialize_bytes(codec_budget)
      @outer_positions = outer_positions.dup
      @outer_rows = expected_parent_rows.dup
      @index = nil
    end

    # Builds one role-wide logical byte view for the inline advanced decoder.
    # These two offsets delimit the captured role itself; they are not a
    # fabricated physical-parent mark grid (outer_rows is intentionally empty).
    def initialize(
      name : String,
      role_view : ObjectSharedInlineRoleReadView,
      codec_budget : BinaryCodecBudget,
    )
      if codec_budget.writing?
        raise ArgumentError.new("inline physical lane read view requires a read-direction codec budget")
      end
      codec_budget.ensure_depth(1)
      unless name == role_view.role_name
        raise CorruptPartError.new("inline physical lane name differs from its source-scheduled role")
      end
      role_size = role_view.byte_size
      if role_size > Int32::MAX.to_u64
        raise CorruptPartError.new("inline physical role exceeds the supported logical byte domain")
      end
      codec_budget.ensure_future_nodes(1_u64)
      codec_budget.charge_node

      @name = String.new(name.to_slice)
      @inline_role_read_view = role_view
      @data_size = role_size
      @data = role_view.materialize_bytes(codec_budget)
      @outer_positions = [0_i64, role_size.to_i64]
      @outer_rows = [] of UInt64
      @index = nil
    end

    private def preflight_input!(
      data_path : String,
      marks_path : String,
      data_size : Int64,
      mark_size : Int64,
      budget : CompressedStreamBudget,
    ) : Nil
      if data_size < 0 || mark_size < 0
        raise ArgumentError.new("expected Object shared lane sizes must be nonnegative")
      end
      if data_size > Int32::MAX || mark_size > Int32::MAX
        raise CorruptPartError.new("paired file exceeds supported in-memory domain")
      end
      if mark_size > budget.limits.max_mark_bytes
        raise CorruptPartError.new("mark file exceeds configured limit")
      end
      if data_size > budget.limits.max_file_bytes
        raise CorruptPartError.new("data file size is invalid")
      end
      if data_size > Int64::MAX - mark_size
        raise ArgumentError.new("paired file sizes overflow")
      end
      if mark_size == 0
        raise CorruptPartError.new("mark file is empty")
      end
      if mark_size % CompressedMarkReader::MARK_RECORD_SIZE != 0
        raise CorruptPartError.new("adaptive mark file size is not a whole record count")
      end

      # Reserve admission for both existing passes up front: the index maps
      # data once, then CompressedMarkReader charges/maps the paired files.
      first_pass_bytes = data_size
      full_pass_bytes = data_size + mark_size
      if first_pass_bytes > Int64::MAX - full_pass_bytes
        raise ArgumentError.new("Object shared lane file work overflows")
      end
      budget.preflight_file_bytes(first_pass_bytes + full_pass_bytes)

      if data_size > 0
        raise CorruptPartError.new("data file must not be a symbolic link") if File.symlink?(data_path)
        raise CorruptPartError.new("mark file must not be a symbolic link") if File.symlink?(marks_path)
      end
      nil
    end

    def logical_size : Int64
      @data.size.to_i64
    end

    def name : String
      String.new(@name.to_slice)
    end

    def byte_size : Int32
      @data.size
    end

    def byte_at(index : Int) : UInt8
      @data[index]
    end

    def bytes : Bytes
      @data.dup
    end

    # Borrowed payload for a decoder that has already charged and retained this
    # lane through the reader. Callers must treat the returned bytes as
    # immutable and must not outlive the lane owner.
    def borrowed_bytes_for_decode : Bytes
      @data
    end

    def outer_position(index : Int) : Int64
      if index < 0 || index >= @outer_positions.size
        raise CorruptPartError.new("Object shared #{@name} parent mark index is outside the grid")
      end
      @outer_positions[index]
    end

    def outer_rows : Array(UInt64)
      @outer_rows.dup
    end

    def logical_position(compressed_offset : UInt64, decompressed_offset : UInt64) : Int64
      if role_view = @inline_role_read_view
        return role_view.logical_position({compressed_offset, decompressed_offset})
      end
      if @data_size == 0_u64
        unless compressed_offset == 0_u64 && decompressed_offset == 0_u64
          raise CorruptPartError.new("Object shared #{@name} empty lane coordinate is not zero")
        end
        return 0_i64
      end
      index = @index || raise(CorruptPartError.new("Object shared #{@name} coordinate index is missing"))
      index.logical_position(compressed_offset, decompressed_offset, false)
    end
  end
end
