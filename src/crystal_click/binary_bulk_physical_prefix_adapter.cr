module CrystalClick
  # Normalizes the BASIC serialization prefix owned by physical Variant
  # discriminator lanes. This does not bind names or handle Dynamic streams.
  class BinaryBulkPhysicalPrefixAdapter
    PREFIX_BYTES = 8_i32

    # Charges the aggregate Variant header bytes and every detached coordinate
    # array returned by write_lane before any caller asks for an adapted lane.
    # Production only invokes this adapter for typed Variant discriminators;
    # ordinary and LowCardinality dictionary lanes retain their existing path.
    def self.preflight_write(
      lanes : Array(Tuple(String, BinaryBulkStream, Int32)),
      budget : BinaryCodecBudget,
    ) : Nil
      unless budget.writing?
        raise ArgumentError.new("physical prefix write requires a writing budget")
      end

      header_bytes = 0_u64
      copied_coordinates = 0_u64
      lanes.each do |lane|
        role, stream, prefix = lane
        kind = classify(role, prefix, true)
        validate_write_grid!(stream, kind)
        # write_lane returns a detached coordinate array for every role.
        # Count it even for a no-header direct caller; the Object writer avoids
        # introducing these copies by adapting only discriminator lanes.
        copied_coordinates = checked_add(copied_coordinates, stream.offset_count.to_u64, true)
        if kind == :variant_discriminator
          header_bytes = checked_add(header_bytes, PREFIX_BYTES.to_u64, true)
        end
      end

      # Check every axis before consuming either, so one short dimension cannot
      # leave a partially charged operation that then allocates no lanes.
      budget.ensure_wire_bytes(header_bytes)
      budget.ensure_future_elements(copied_coordinates)
      budget.charge_wire_bytes(header_bytes)
      budget.charge_elements(copied_coordinates)
      nil
    end

    # Read-side windows are known by role, prefix, and their K+1 offset count
    # before PartStreamSource reads any selected bytes. The stripped Bytes
    # result is a borrowed Slice; its input window must remain alive until the
    # caller has copied it into the owning BinaryBulkStream.
    def self.preflight_read(
      lanes : Array(Tuple(String, Int32, Int32)),
      budget : BinaryCodecBudget,
    ) : Nil
      if budget.writing?
        raise ArgumentError.new("physical prefix read requires a reading budget")
      end

      header_bytes = 0_u64
      copied_coordinates = 0_u64
      lanes.each do |lane|
        role, prefix, coordinate_count = lane
        kind = classify(role, prefix, false)
        if coordinate_count < 1
          raise CorruptPartError.new("physical prefix lane has no terminal coordinate")
        end
        if kind == :variant_discriminator
          header_bytes = checked_add(header_bytes, PREFIX_BYTES.to_u64, false)
          copied_coordinates = checked_add(copied_coordinates, coordinate_count.to_u64, false)
        end
      end

      budget.ensure_wire_bytes(header_bytes)
      budget.ensure_future_elements(copied_coordinates)
      budget.charge_wire_bytes(header_bytes)
      budget.charge_elements(copied_coordinates)
      nil
    end

    # The role is a logical BinaryBulk role, never a physical basename. This
    # is public for Object owners that must preflight only transformed lanes.
    def self.variant_discriminator_role?(role : String, prefix_size : Int32) : Bool
      classify(role, prefix_size, false) == :variant_discriminator
    end

    # Returns (bytes, offsets, physical prefix size). Variant discriminator
    # output owns one new byte buffer with BASIC's eight-byte UInt64(0) mode
    # before the logical RowBinary discriminator bytes.
    def self.write_lane(
      role : String,
      stream : BinaryBulkStream,
      prefix_size : Int,
    ) : Tuple(Bytes, Array(UInt64), Int32)
      unless prefix_size >= 0 && prefix_size <= Int32::MAX
        raise UnsupportedFormatError.new("physical prefix size is outside the supported domain")
      end
      kind = classify(role, prefix_size.to_i32, true)
      validate_write_grid!(stream, kind)

      case kind
      when :variant_discriminator
        if stream.byte_size > Int32::MAX - PREFIX_BYTES
          raise UnsupportedFormatError.new("Variant physical discriminator lane exceeds the supported byte domain")
        end
        stream.offset_count.times do |index|
          if stream.offset_at(index) > UInt64::MAX - PREFIX_BYTES.to_u64
            raise UnsupportedFormatError.new("Variant physical discriminator coordinate overflows UInt64")
          end
        end
        bytes = Bytes.new(stream.byte_size + PREFIX_BYTES) do |index|
          if index < PREFIX_BYTES
            0_u8
          else
            stream.byte_at(index - PREFIX_BYTES)
          end
        end
        offsets = Array(UInt64).new(stream.offset_count) do |index|
          stream.offset_at(index) + PREFIX_BYTES.to_u64
        end
        {bytes, offsets, PREFIX_BYTES}
      when :low_cardinality_dictionary
        {stream.borrowed_slice(0, stream.byte_size), offsets_for(stream), PREFIX_BYTES}
      else
        {stream.borrowed_slice(0, stream.byte_size), offsets_for(stream), 0_i32}
      end
    end

    # The discriminator's physical UInt64(0) is validated and removed without
    # copying its payload. The returned Slice borrows `bytes`; caller retains
    # that window through BinaryBulkStream construction. Coordinate rebasing
    # creates one bounded K+1 array.
    def self.read_lane(
      role : String,
      bytes : Bytes,
      offsets : Array(UInt64),
      prefix_size : Int,
    ) : Tuple(Bytes, Array(UInt64), Int32)
      unless prefix_size >= 0 && prefix_size <= Int32::MAX
        raise CorruptPartError.new("physical prefix size is outside the supported domain")
      end
      kind = classify(role, prefix_size.to_i32, false)
      validate_read_grid!(bytes, offsets, kind)

      case kind
      when :variant_discriminator
        {bytes[PREFIX_BYTES, bytes.size - PREFIX_BYTES], Array(UInt64).new(offsets.size) do |index|
          offsets[index] - PREFIX_BYTES.to_u64
        end, 0_i32}
      when :low_cardinality_dictionary
        {bytes, offsets, PREFIX_BYTES}
      else
        {bytes, offsets, 0_i32}
      end
    end

    private def self.classify(role : String, prefix_size : Int32, writing : Bool) : Symbol
      kind = if role.ends_with?(".discriminators")
               :variant_discriminator
             elsif role.ends_with?(".dictionary")
               :low_cardinality_dictionary
             else
               :ordinary
             end

      expected_prefix = kind == :ordinary ? 0_i32 : PREFIX_BYTES
      if prefix_size != expected_prefix
        message = "physical prefix does not match its binary bulk role"
        if writing
          raise UnsupportedFormatError.new(message)
        else
          raise CorruptPartError.new(message)
        end
      end
      kind
    end

    private def self.validate_write_grid!(stream : BinaryBulkStream, kind : Symbol) : Nil
      expected_prefix = kind == :variant_discriminator ? 0_u64 : (kind == :low_cardinality_dictionary ? PREFIX_BYTES.to_u64 : 0_u64)
      if stream.offset_count == 0 || stream.offset_at(0) != expected_prefix ||
         stream.offset_at(stream.offset_count - 1) != stream.byte_size.to_u64
        raise UnsupportedFormatError.new("physical prefix lane coordinates disagree with its byte domain")
      end
      validate_prefix_header!(stream, kind, true)
      previous = expected_prefix
      stream.offset_count.times do |index|
        offset = stream.offset_at(index)
        if offset < previous || offset > stream.byte_size.to_u64
          raise UnsupportedFormatError.new("physical prefix lane coordinates are not monotone")
        end
        previous = offset
      end
      nil
    end

    private def self.validate_read_grid!(bytes : Bytes, offsets : Array(UInt64), kind : Symbol) : Nil
      expected_prefix = kind == :variant_discriminator ? PREFIX_BYTES.to_u64 : (kind == :low_cardinality_dictionary ? PREFIX_BYTES.to_u64 : 0_u64)
      if offsets.empty? || offsets.first != expected_prefix || offsets.last != bytes.size.to_u64
        raise CorruptPartError.new("physical prefix lane coordinates disagree with its byte domain")
      end
      validate_prefix_header!(bytes, kind, false)
      previous = expected_prefix
      offsets.each do |offset|
        if offset < previous || offset > bytes.size.to_u64
          raise CorruptPartError.new("physical prefix lane coordinates are not monotone")
        end
        previous = offset
      end
      nil
    end

    private def self.validate_prefix_header!(stream : BinaryBulkStream, kind : Symbol, writing : Bool) : Nil
      return nil unless kind == :low_cardinality_dictionary
      unless stream.byte_size >= PREFIX_BYTES && stream.byte_at(0) == 1_u8
        if writing
          raise UnsupportedFormatError.new("LowCardinality dictionary lane has an invalid version header")
        else
          raise CorruptPartError.new("LowCardinality dictionary lane has an invalid version header")
        end
      end
      1.upto(PREFIX_BYTES - 1) do |index|
        unless stream.byte_at(index) == 0_u8
          if writing
            raise UnsupportedFormatError.new("LowCardinality dictionary lane has an invalid version header")
          else
            raise CorruptPartError.new("LowCardinality dictionary lane has an invalid version header")
          end
        end
      end
      nil
    end

    private def self.validate_prefix_header!(bytes : Bytes, kind : Symbol, writing : Bool) : Nil
      case kind
      when :low_cardinality_dictionary
        unless bytes.size >= PREFIX_BYTES && bytes[0] == 1_u8
          if writing
            raise UnsupportedFormatError.new("LowCardinality dictionary lane has an invalid version header")
          else
            raise CorruptPartError.new("LowCardinality dictionary lane has an invalid version header")
          end
        end
        1.upto(PREFIX_BYTES - 1) do |index|
          unless bytes[index] == 0_u8
            if writing
              raise UnsupportedFormatError.new("LowCardinality dictionary lane has an invalid version header")
            else
              raise CorruptPartError.new("LowCardinality dictionary lane has an invalid version header")
            end
          end
        end
      when :variant_discriminator
        unless bytes.size >= PREFIX_BYTES
          raise CorruptPartError.new("Variant discriminator lane is shorter than its BASIC mode header")
        end
        PREFIX_BYTES.times do |index|
          unless bytes[index] == 0_u8
            raise CorruptPartError.new("Variant discriminator lane has a nonzero BASIC mode header")
          end
        end
      end
      nil
    end

    private def self.offsets_for(stream : BinaryBulkStream) : Array(UInt64)
      Array(UInt64).new(stream.offset_count) { |index| stream.offset_at(index) }
    end

    private def self.checked_add(left : UInt64, right : UInt64, writing : Bool) : UInt64
      if left > UInt64::MAX - right
        if writing
          raise UnsupportedFormatError.new("physical prefix budget total overflows UInt64")
        else
          raise CorruptPartError.new("physical prefix budget total overflows UInt64")
        end
      end
      left + right
    end
  end
end
