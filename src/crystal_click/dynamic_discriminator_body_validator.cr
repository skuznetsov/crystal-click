module CrystalClick
  # Non-allocating structural validator for one decompressed Dynamic
  # discriminator mark body. Roster/tag materialization remains selected-only
  # in DynamicDiscriminatorCodec; physical owners may use this to validate a
  # complete body grid before binding lanes.
  class DynamicDiscriminatorBodyValidator
    BASIC_MODE   = 0_u64
    COMPACT_MODE = 1_u64

    BASIC_TAGS          = 2_u8
    COMPACT_ROW_TAGS    = 0_u8
    COMPACT_UNIFORM_TAG = 1_u8
    COMPACT_EMPTY       = 3_u8

    # Returns a validated mode word from the stream header. A caller decides
    # whether malformed bytes are untrusted input (CorruptPartError) or an
    # unsupported write-side lane (UnsupportedFormatError).
    def self.read_mode(stream : DynamicDiscriminatorStream, writing : Bool = false) : UInt64
      if stream.byte_size < 8
        fail!("Dynamic discriminator stream is shorter than its mode header", writing)
      end

      mode = 0_u64
      8.times do |index|
        mode |= stream.byte_at(index).to_u64 << (index * 8)
      end
      unless mode == BASIC_MODE || mode == COMPACT_MODE
        fail!("unknown Dynamic discriminator mode", writing)
      end
      mode
    end

    # Validates a complete mark-body layout without allocating a tag vector.
    # The result is {format, tag_offset}; BASIC and row-tag COMPACT use the
    # offset as a byte-per-row start, uniform COMPACT points to its one tag.
    # Empty COMPACT marks have no frame at all and therefore no tag offset.
    def self.inspect_body(
      mode : UInt64,
      body : Bytes,
      expected_rows : UInt64,
      writing : Bool = false,
    ) : Tuple(UInt8, Int32)
      if expected_rows > Int32::MAX.to_u64
        fail!("Dynamic discriminator mark rows exceed the supported domain", writing)
      end

      if mode == BASIC_MODE
        unless body.size.to_u64 == expected_rows
          fail!("Dynamic BASIC body extent does not equal its mark rows", writing)
        end
        return {BASIC_TAGS, 0}
      elsif mode != COMPACT_MODE
        fail!("unknown Dynamic discriminator mode", writing)
      end

      # ClickHouse emits no per-mark discriminator bytes for a zero-row
      # child group. In particular, do not synthesize the positive-row
      # VarUInt/format/tag frame for C=0.
      if expected_rows == 0_u64
        unless body.empty?
          fail!("empty Dynamic COMPACT child group contains body bytes", writing)
        end
        return {COMPACT_EMPTY, 0}
      end

      inner_rows, format, tag_offset, frame_end = inspect_frame(body, 0, writing)
      unless inner_rows == expected_rows
        fail!("Dynamic COMPACT row count does not equal its mark rows", writing)
      end
      unless frame_end == body.size
        fail!("Dynamic COMPACT frame has trailing bytes", writing)
      end
      {format, tag_offset}
    end

    # Inspects one positive COMPACT frame starting at `cursor` without
    # materializing tags. The returned tuple is {rows, format, tag_offset,
    # frame_end}; tag_offset and frame_end are relative to `body`. Unlike
    # inspect_body, this parser deliberately permits a following frame so
    # physical adapters can normalize concatenated frame sequences.
    def self.inspect_frame(
      body : Bytes,
      cursor : Int32 = 0,
      writing : Bool = false,
    ) : Tuple(UInt64, UInt8, Int32, Int32)
      if cursor < 0 || cursor >= body.size
        fail!("Dynamic COMPACT frame is missing its row count", writing)
      end

      rows, cursor = read_var_uint(body, cursor, writing)
      if rows == 0_u64
        fail!("Dynamic COMPACT frame row count must be positive", writing)
      end
      if rows > Int32::MAX.to_u64
        fail!("Dynamic COMPACT row count exceeds the supported domain", writing)
      end
      if cursor >= body.size
        fail!("Dynamic COMPACT frame is missing its format", writing)
      end

      format = body[cursor]
      cursor += 1
      case format
      when COMPACT_ROW_TAGS
        remaining = (body.size - cursor).to_u64
        if rows > remaining
          fail!("Dynamic COMPACT row-tag frame is truncated", writing)
        end
        frame_end = cursor + rows.to_i32
        {rows, format, cursor, frame_end}
      when COMPACT_UNIFORM_TAG
        if cursor >= body.size
          fail!("Dynamic COMPACT uniform frame is truncated", writing)
        end
        {rows, format, cursor, cursor + 1}
      else
        fail!("unknown Dynamic COMPACT granule format", writing)
      end
    end

    # Reads one selected tag from a previously inspected body. The caller
    # validates its canonical roster before retaining/using the tag.
    def self.tag_at(body : Bytes, layout : Tuple(UInt8, Int32), row_index : Int) : UInt8
      format, tag_offset = layout
      if format == COMPACT_EMPTY
        raise IndexError.new("empty Dynamic discriminator body has no tags")
      end
      offset = if format == COMPACT_UNIFORM_TAG
                 tag_offset
               else
                 tag_offset + row_index
               end
      body[offset]
    end

    private def self.read_var_uint(bytes : Bytes, cursor : Int32, writing : Bool) : Tuple(UInt64, Int32)
      value = 0_u64
      10.times do |index|
        if cursor >= bytes.size
          fail!("Dynamic COMPACT row count is truncated", writing)
        end
        byte = bytes[cursor]
        cursor += 1
        payload = (byte & 0x7f_u8).to_u64
        if index == 9 && payload > 1_u64
          fail!("Dynamic COMPACT row count overflows UInt64", writing)
        end
        value |= payload << (index * 7)
        continuing = (byte & 0x80_u8) != 0_u8
        unless continuing
          if index > 0 && payload == 0_u64
            fail!("Dynamic COMPACT row count is nonminimal", writing)
          end
          return {value, cursor}
        end
        if index == 9
          fail!("Dynamic COMPACT row count is too long", writing)
        end
      end
      fail!("Dynamic COMPACT row count is too long", writing)
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
