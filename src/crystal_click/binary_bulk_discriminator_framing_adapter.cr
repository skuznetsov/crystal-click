module CrystalClick
  # Converts typed-Dynamic BinaryBulk discriminator tags to and from the
  # physical Variant discriminator framing. Generic Bulk tags remain
  # byte-per-occurrence; only this physical boundary knows BASIC/COMPACT.
  class BinaryBulkDiscriminatorFramingAdapter
    PREFIX_BYTES = 8_i32

    # Returns the complete physical lane size, including its UInt64 mode
    # header. This is nonallocating and also validates the logical mark grid.
    def self.physical_size(stream : BinaryBulkStream, mode : UInt64) : Int32
      validate_logical_grid!(stream, true)
      unless mode == DynamicDiscriminatorBodyValidator::BASIC_MODE ||
             mode == DynamicDiscriminatorBodyValidator::COMPACT_MODE
        raise UnsupportedFormatError.new("unknown typed Dynamic discriminator mode")
      end

      size = PREFIX_BYTES.to_u64
      if mode == DynamicDiscriminatorBodyValidator::BASIC_MODE
        size = checked_add(size, stream.byte_size.to_u64, true)
      else
        (stream.offset_count - 1).times do |mark_index|
          first = stream.offset_at(mark_index)
          following = stream.offset_at(mark_index + 1)
          count = following - first
          next if count == 0_u64

          uniform = uniform_tag?(stream, first, count)
          frame_size = checked_add(var_uint_size(count), 1_u64, true)
          frame_size = checked_add(frame_size, uniform ? 1_u64 : count, true)
          size = checked_add(size, frame_size, true)
        end
      end
      checked_byte_domain(size, true)
    end

    # Reserves all new physical output work and detached mark-coordinate
    # arrays before a caller invokes write_lane. Mode 0 preserves the legacy
    # accounting contract (header delta only); COMPACT is new work, so its
    # complete adapted output buffer is charged in addition to retained tags.
    def self.preflight_write(
      lanes : Array(Tuple(String, BinaryBulkStream, UInt64)),
      budget : BinaryCodecBudget,
    ) : Nil
      unless budget.writing?
        raise ArgumentError.new("typed Dynamic discriminator write requires a writing budget")
      end

      output_bytes = 0_u64
      copied_coordinates = 0_u64
      lanes.each do |lane|
        role, stream, mode = lane
        validate_role!(role, true)
        validate_logical_grid!(stream, true)
        lane_bytes = if mode == DynamicDiscriminatorBodyValidator::BASIC_MODE
                       physical_size(stream, mode)
                       PREFIX_BYTES.to_u64
                     elsif mode == DynamicDiscriminatorBodyValidator::COMPACT_MODE
                       physical_size(stream, mode).to_u64
                     else
                       raise UnsupportedFormatError.new("unknown typed Dynamic discriminator mode")
                     end
        output_bytes = checked_add(output_bytes, lane_bytes, true)
        copied_coordinates = checked_add(copied_coordinates, stream.offset_count.to_u64, true)
      end

      # Check both aggregate axes before charging either or allowing an output
      # lane/coordinate array to be allocated.
      budget.ensure_wire_bytes(output_bytes)
      budget.ensure_future_elements(copied_coordinates)
      budget.charge_wire_bytes(output_bytes)
      budget.charge_elements(copied_coordinates)
      nil
    end

    # Returns {physical bytes, per-mark physical byte offsets, prefix size}.
    # The caller must have run preflight_write for the complete batch first.
    def self.write_lane(
      role : String,
      stream : BinaryBulkStream,
      mode : UInt64,
    ) : Tuple(Bytes, Array(UInt64), Int32)
      validate_role!(role, true)
      validate_logical_grid!(stream, true)
      unless mode == DynamicDiscriminatorBodyValidator::BASIC_MODE ||
             mode == DynamicDiscriminatorBodyValidator::COMPACT_MODE
        raise UnsupportedFormatError.new("unknown typed Dynamic discriminator mode")
      end

      if mode == DynamicDiscriminatorBodyValidator::BASIC_MODE
        return BinaryBulkPhysicalPrefixAdapter.write_lane(role, stream, PREFIX_BYTES)
      end

      size = physical_size(stream, mode)
      bytes = Bytes.new(size)
      PREFIX_BYTES.times do |index|
        bytes[index] = ((mode >> (index * 8)) & 0xff_u64).to_u8
      end

      offsets = Array(UInt64).new(stream.offset_count)
      offsets << PREFIX_BYTES.to_u64
      cursor = PREFIX_BYTES
      (stream.offset_count - 1).times do |mark_index|
        first = stream.offset_at(mark_index).to_i32
        following = stream.offset_at(mark_index + 1).to_i32
        count = (following - first).to_u64
        if count > 0_u64
          uniform = uniform_tag?(stream, first.to_u64, count)
          cursor = write_var_uint(bytes, cursor, count)
          if uniform
            bytes[cursor] = DynamicDiscriminatorBodyValidator::COMPACT_UNIFORM_TAG
            cursor += 1
            bytes[cursor] = stream.byte_at(first)
            cursor += 1
          else
            bytes[cursor] = DynamicDiscriminatorBodyValidator::COMPACT_ROW_TAGS
            cursor += 1
            count.to_i32.times do |row_index|
              bytes[cursor] = stream.byte_at(first + row_index)
              cursor += 1
            end
          end
        end
        offsets << cursor.to_u64
      end

      unless cursor == bytes.size
        raise UnsupportedFormatError.new("typed Dynamic discriminator size calculation disagrees with output")
      end
      {bytes, offsets, PREFIX_BYTES}
    end

    # Validates just the UInt64 mode header. Header-only streams are valid for
    # empty lanes and for selected zero-mark windows.
    def self.validate_header(role : String, bytes : Bytes, prefix_size : Int) : UInt64
      validate_role!(role, false)
      unless prefix_size == PREFIX_BYTES
        raise CorruptPartError.new("typed Dynamic discriminator prefix is not eight bytes")
      end
      if bytes.size < PREFIX_BYTES
        raise CorruptPartError.new("typed Dynamic discriminator lane is shorter than its mode header")
      end

      mode = 0_u64
      PREFIX_BYTES.times do |index|
        mode |= bytes[index].to_u64 << (index * 8)
      end
      unless mode == DynamicDiscriminatorBodyValidator::BASIC_MODE ||
             mode == DynamicDiscriminatorBodyValidator::COMPACT_MODE
        raise CorruptPartError.new("unknown typed Dynamic discriminator mode")
      end
      mode
    end

    # Strips physical framing and returns normalized byte-per-occurrence tags,
    # zero-based per-mark offsets, and prefix size zero. For COMPACT, frame
    # counts determine bounded expansion work; wrapper schedules are checked
    # later by BinaryBulkDecoder, not inferred here.
    def self.read_lane(
      role : String,
      bytes : Bytes,
      offsets : Array(UInt64),
      prefix_size : Int,
      budget : BinaryCodecBudget,
    ) : Tuple(Bytes, Array(UInt64), Int32)
      if budget.writing?
        raise ArgumentError.new("typed Dynamic discriminator read requires a reading budget")
      end
      mode = validate_header(role, bytes, prefix_size)

      if mode == DynamicDiscriminatorBodyValidator::BASIC_MODE
        return BinaryBulkPhysicalPrefixAdapter.read_lane(role, bytes, offsets, prefix_size)
      end

      validate_physical_grid!(bytes, offsets)
      total_rows = 0_u64
      (offsets.size - 1).times do |mark_index|
        first = offsets[mark_index].to_i32
        following = offsets[mark_index + 1].to_i32
        interval = bytes[first, following - first]
        rows = inspect_interval_rows(interval)
        total_rows = checked_add(total_rows, rows, false)
        if total_rows > Int32::MAX.to_u64
          raise CorruptPartError.new("expanded typed Dynamic discriminator exceeds the supported byte domain")
        end
      end

      # The caller already reserved the header and K+1 physical coordinates.
      # Charge the distinct expanded tag buffer here, before allocating it.
      budget.ensure_wire_bytes(total_rows)
      budget.charge_wire_bytes(total_rows)

      expanded = Bytes.new(total_rows.to_i32)
      normalized_offsets = Array(UInt64).new(offsets.size)
      normalized_offsets << 0_u64
      output_cursor = 0_i32
      (offsets.size - 1).times do |mark_index|
        first = offsets[mark_index].to_i32
        following = offsets[mark_index + 1].to_i32
        interval = bytes[first, following - first]
        output_cursor = expand_interval(interval, expanded, output_cursor)
        normalized_offsets << output_cursor.to_u64
      end

      unless output_cursor == expanded.size
        raise CorruptPartError.new("typed Dynamic discriminator expansion disagrees with its preflight")
      end
      {expanded, normalized_offsets, 0_i32}
    end

    # Normalizes one per-mark Variant body and reports the exact physical
    # extent consumed from its callback/tape. BASIC tags are a read-only view;
    # COMPACT tags are expanded into an owned byte-per-row lane before the
    # caller commits the enclosing callback transaction. MRK3 callers pass
    # `require_exact: false` so the following sibling remains available to
    # the parent ledger; MRK4's named-shard owner requires exact consumption.
    def self.read_mark_body(
      role : String,
      mode : UInt64,
      body : Bytes,
      expected_rows : UInt64,
      budget : BinaryCodecBudget,
      require_exact : Bool = true,
    ) : Tuple(Bytes, Int32)
      if budget.writing?
        raise ArgumentError.new("typed Variant mark-body read requires a reading budget")
      end
      validate_role!(role, false)
      if expected_rows > Int32::MAX.to_u64
        raise CorruptPartError.new("typed Variant mark rows exceed the supported domain")
      end
      unless mode == DynamicDiscriminatorBodyValidator::BASIC_MODE ||
             mode == DynamicDiscriminatorBodyValidator::COMPACT_MODE
        raise CorruptPartError.new("unknown typed Variant discriminator mode")
      end

      if mode == DynamicDiscriminatorBodyValidator::BASIC_MODE
        extent = expected_rows.to_i32
        if body.size < extent || (require_exact && body.size != extent)
          raise CorruptPartError.new("typed Variant BASIC body extent does not match its mark rows")
        end
        return {Bytes.new(body.to_unsafe, extent, read_only: true), extent}
      end

      if expected_rows == 0_u64
        if require_exact && !body.empty?
          raise CorruptPartError.new("empty typed Variant COMPACT body contains bytes")
        end
        return {Bytes.new(0), 0}
      end

      rows, format, tag_offset, frame_end = DynamicDiscriminatorBodyValidator.inspect_frame(body)
      unless rows == expected_rows
        raise CorruptPartError.new("typed Variant COMPACT row count differs from its inherited occurrence count")
      end
      if require_exact && frame_end != body.size
        raise CorruptPartError.new("typed Variant COMPACT frame has trailing bytes")
      end

      # The normalized discriminator lane is an owned BinaryBulk byte lane.
      # Reserve it before allocation; the parent cursor has already charged
      # the raw physical input exactly once.
      budget.ensure_wire_bytes(expected_rows)
      budget.charge_wire_bytes(expected_rows)
      expanded = Bytes.new(expected_rows.to_i32)
      expanded_end = expand_interval(body[0, frame_end], expanded, 0_i32)
      unless expanded_end == expected_rows.to_i32
        raise CorruptPartError.new("typed Variant COMPACT expansion disagrees with its validated frame")
      end
      {expanded, frame_end}
    end

    private def self.validate_role!(role : String, writing : Bool) : Nil
      return nil if role.ends_with?(".discriminators")
      if writing
        raise UnsupportedFormatError.new("typed Dynamic discriminator adapter received a non-discriminator role")
      else
        raise CorruptPartError.new("typed Dynamic discriminator adapter received a non-discriminator role")
      end
    end

    private def self.validate_logical_grid!(stream : BinaryBulkStream, writing : Bool) : Nil
      if stream.offset_count == 0 || stream.offset_at(0) != 0_u64 ||
         stream.offset_at(stream.offset_count - 1) != stream.byte_size.to_u64
        fail!("typed Dynamic logical discriminator coordinates disagree with the byte domain", writing)
      end

      previous = 0_u64
      stream.offset_count.times do |index|
        offset = stream.offset_at(index)
        if offset < previous || offset > stream.byte_size.to_u64
          fail!("typed Dynamic logical discriminator coordinates are not monotone", writing)
        end
        previous = offset
      end
      nil
    end

    private def self.validate_physical_grid!(bytes : Bytes, offsets : Array(UInt64)) : Nil
      if offsets.empty? || offsets.first != PREFIX_BYTES.to_u64 || offsets.last != bytes.size.to_u64
        raise CorruptPartError.new("typed Dynamic physical discriminator coordinates disagree with the byte domain")
      end
      previous = PREFIX_BYTES.to_u64
      offsets.each do |offset|
        if offset < previous || offset > bytes.size.to_u64
          raise CorruptPartError.new("typed Dynamic physical discriminator coordinates are not monotone")
        end
        previous = offset
      end
      nil
    end

    private def self.inspect_interval_rows(interval : Bytes) : UInt64
      cursor = 0_i32
      total = 0_u64
      while cursor < interval.size
        rows, _format, _tag_offset, frame_end = DynamicDiscriminatorBodyValidator.inspect_frame(interval, cursor)
        total = checked_add(total, rows, false)
        if total > Int32::MAX.to_u64
          raise CorruptPartError.new("typed Dynamic discriminator interval exceeds the supported row domain")
        end
        if frame_end <= cursor
          raise CorruptPartError.new("typed Dynamic discriminator frame made no progress")
        end
        cursor = frame_end
      end
      total
    end

    private def self.expand_interval(interval : Bytes, output : Bytes, output_cursor : Int32) : Int32
      cursor = 0_i32
      while cursor < interval.size
        rows, format, tag_offset, frame_end = DynamicDiscriminatorBodyValidator.inspect_frame(interval, cursor)
        if format == DynamicDiscriminatorBodyValidator::COMPACT_UNIFORM_TAG
          tag = interval[tag_offset]
          rows.to_i32.times do
            output[output_cursor] = tag
            output_cursor += 1
          end
        else
          rows.to_i32.times do |row_index|
            output[output_cursor] = interval[tag_offset + row_index]
            output_cursor += 1
          end
        end
        cursor = frame_end
      end
      output_cursor
    end

    private def self.uniform_tag?(stream : BinaryBulkStream, first : UInt64, count : UInt64) : Bool
      tag = stream.byte_at(first.to_i32)
      index = 1_u64
      while index < count
        return false if stream.byte_at((first + index).to_i32) != tag
        index += 1_u64
      end
      true
    end

    private def self.write_var_uint(bytes : Bytes, cursor : Int32, original : UInt64) : Int32
      value = original
      position = cursor
      loop do
        byte = (value & 0x7f_u64).to_u8
        value >>= 7
        byte |= 0x80_u8 if value > 0_u64
        bytes[position] = byte
        position += 1
        break if value == 0_u64
      end
      position
    end

    private def self.var_uint_size(original : UInt64) : UInt64
      size = 1_u64
      value = original
      while value >= 0x80_u64
        value >>= 7
        size += 1_u64
      end
      size
    end

    private def self.checked_byte_domain(size : UInt64, writing : Bool) : Int32
      if size > Int32::MAX.to_u64
        fail!("typed Dynamic physical discriminator exceeds the supported byte domain", writing)
      end
      size.to_i32
    end

    private def self.checked_add(left : UInt64, right : UInt64, writing : Bool) : UInt64
      if left > UInt64::MAX - right
        fail!("typed Dynamic discriminator size overflows UInt64", writing)
      end
      left + right
    end

    private def self.fail!(message : String, writing : Bool) : NoReturn
      if writing
        raise UnsupportedFormatError.new(message)
      else
        raise CorruptPartError.new(message)
      end
    end
  end
end
