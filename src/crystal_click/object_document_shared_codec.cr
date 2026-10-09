module CrystalClick
  # The V3 Object shared MAP is a bulk Array(Tuple(paths String, values
  # String)) lane. Each values String holds one borrowed W117 scalar envelope;
  # physical String framing is selected independently of typed/Dynamic lanes.
  module ObjectDocumentSharedCodec
    alias Entry = Tuple(String, BinaryValue)

    def self.encode_with_budget(
      granules : Array(Array(Array(Entry))),
      budget : BinaryCodecBudget,
      profile : BinaryBulkProfile,
    ) : BinaryBulkStreams
      unless budget.writing?
        raise ArgumentError.new("Object shared document encode requires a writing budget")
      end

      row_count = 0_u64
      entry_count = 0_u64
      fixed_wire_bytes = 0_u64
      granules.each do |mark_rows|
        mark_rows.each do |entries|
          row_count = checked_add(row_count, 1_u64, true)
          fixed_wire_bytes = checked_add(fixed_wire_bytes, 8_u64, true) # Array row size
          previous_path : String? = nil
          entries.each do |entry|
            path = entry[0]
            if previous = previous_path
              if compare_paths(previous, path) >= 0
                raise UnsupportedFormatError.new("shared Object paths must be strictly byte-sorted")
              end
            end
            previous_path = path
            path_size = path.bytesize.to_u64
            path_frame = profile.with_size_stream? ? 8_u64 : var_uint_size(path_size)
            fixed_wire_bytes = checked_add(fixed_wire_bytes, checked_add(path_frame, path_size, true), true)
            value_frame = profile.with_size_stream? ? 8_u64 : 1_u64
            fixed_wire_bytes = checked_add(fixed_wire_bytes, value_frame, true)
            entry_count = checked_add(entry_count, 1_u64, true)
          end
        end
      end

      # Preflight all count-derived shared value wrappers before making an
      # envelope copy. Bulk encoding charges these same rows and children.
      wrapper_nodes = checked_add(row_count, checked_multiply(entry_count, 3_u64, true), true)
      wrapper_edges = checked_multiply(entry_count, 3_u64, true)
      budget.ensure_future_nodes(wrapper_nodes)
      budget.ensure_future_elements(wrapper_edges)
      budget.ensure_wire_bytes(fixed_wire_bytes)

      type = physical_type
      encoded_rows = Array(Array(BinaryValue)).new(granules.size)
      encoded_payload_bytes = 0_u64
      granules.each do |mark_rows|
        values = Array(BinaryValue).new(mark_rows.size)
        mark_rows.each do |entries|
          tuples = Array(BinaryValue).new(entries.size)
          entries.each do |entry|
            path = entry[0]
            value = entry[1]
            if value.type.tag == BinaryDataType::TAG_NOTHING
              raise UnsupportedFormatError.new("shared Nothing NULL values must be omitted")
            end
            if value.type.tag == BinaryDataType::TAG_NULLABLE
              raise UnsupportedFormatError.new("top-level Nullable shared values are outside the canonical profile")
            end

            budget.ensure_future_nodes(wrapper_nodes)
            budget.ensure_future_elements(wrapper_edges)
            reserved_wire_bytes = checked_add(fixed_wire_bytes, encoded_payload_bytes, true)
            envelope = BinaryValueCodec.encode_shared_json_envelope(value, budget, reserved_wire_bytes)
            encoded_payload_bytes = checked_add(encoded_payload_bytes, envelope.size.to_u64, true)
            frame_size = profile.with_size_stream? ? 8_u64 : var_uint_size(envelope.size.to_u64)
            minimum_frame = profile.with_size_stream? ? 8_u64 : 1_u64
            if frame_size > minimum_frame
              fixed_wire_bytes = checked_add(fixed_wire_bytes, frame_size - minimum_frame, true)
            end
            budget.ensure_wire_bytes(checked_add(fixed_wire_bytes, encoded_payload_bytes, true))

            tuple_type = type.child_at(0)
            path_value = BinaryValue.string(path)
            envelope_value = BinaryValue.string(String.new(envelope))
            tuples << BinaryValue.tuple(tuple_type, [path_value, envelope_value])
          end
          values << BinaryValue.array(type, tuples)
        end
        encoded_rows << values
      end

      BinaryBulkCodec.encode_with_budget(type, encoded_rows, budget, profile: profile)
    end

    def self.decode_with_budget(
      streams : BinaryBulkStreams,
      rows_per_mark : Array(UInt64),
      object : ObjectStructure,
      typed_schema : Hash(String, BinaryDataType),
      budget : BinaryCodecBudget,
      first_mark : Int,
      mark_count : Int?,
      profile : BinaryBulkProfile,
    ) : Array(Array(Array(Entry)))
      if budget.writing?
        raise ArgumentError.new("Object shared document decode requires a reading budget")
      end

      type = physical_type
      decoded = BinaryBulkCodec.decode_with_budget(
        type,
        streams,
        rows_per_mark,
        budget,
        first_mark: first_mark,
        mark_count: mark_count,
        profile: profile
      )

      output_entries = 0_u64
      decoded.each do |mark_rows|
        mark_rows.each do |row|
          output_entries = checked_add(output_entries, row.element_count.to_u64, false)
        end
      end
      # These are count-derived result arrays. Envelope decoding below also
      # consumes the same aggregate visit budget, so prove the output lower
      # bound before allocating any row entry collection.
      budget.ensure_future_nodes(output_entries)
      budget.ensure_future_elements(output_entries)

      result = Array(Array(Array(Entry))).new(decoded.size)
      decoded.each do |mark_rows|
        mark_result = Array(Array(Entry)).new(mark_rows.size)
        mark_rows.each do |row|
          entries = Array(Entry).new(row.element_count)
          previous_path : String? = nil
          row.element_count.times do |entry_index|
            tuple = row.element_at(entry_index)
            path = tuple.element_at(0).as_string
            if previous = previous_path
              if compare_paths(previous, path) >= 0
                raise CorruptPartError.new("shared Object paths are not strictly byte-sorted")
              end
            end
            if typed_schema.has_key?(path) || object.has_dynamic_path?(path)
              raise CorruptPartError.new("shared Object path overlaps a typed or Dynamic path")
            end
            previous_path = path

            envelope_string = tuple.element_at(1).as_string
            envelope = envelope_string.to_slice
            value = BinaryValueCodec.decode_shared_json_envelope(envelope, budget)
            if value.type.tag == BinaryDataType::TAG_NOTHING || value.type.tag == BinaryDataType::TAG_NULLABLE
              raise CorruptPartError.new("top-level Nothing and Nullable shared values are outside the canonical profile")
            end
            entries << {path, value}
          end
          mark_result << entries
        end
        result << mark_result
      end
      result
    end

    private def self.physical_type : BinaryDataType
      string = BinaryDataType.primitive("String")
      tuple = BinaryDataType.tuple([string, string], ["paths", "values"] of String)
      BinaryDataType.array(tuple)
    end

    private def self.compare_paths(left : String, right : String) : Int32
      left_bytes = left.to_slice
      right_bytes = right.to_slice
      common_size = Math.min(left_bytes.size, right_bytes.size)
      common_size.times do |index|
        return -1 if left_bytes[index] < right_bytes[index]
        return 1 if left_bytes[index] > right_bytes[index]
      end
      left_bytes.size <=> right_bytes.size
    end

    private def self.var_uint_size(value : UInt64) : UInt64
      size = 1_u64
      remaining = value
      while remaining >= 0x80_u64
        size += 1_u64
        remaining >>= 7
      end
      size
    end

    private def self.checked_add(left : UInt64, right : UInt64, writing : Bool) : UInt64
      if right > UInt64::MAX - left
        if writing
          raise UnsupportedFormatError.new("shared Object size count overflows UInt64")
        else
          raise CorruptPartError.new("shared Object size count overflows UInt64")
        end
      end
      left + right
    end

    private def self.checked_multiply(left : UInt64, right : UInt64, writing : Bool) : UInt64
      if right != 0_u64 && left > UInt64::MAX // right
        if writing
          raise UnsupportedFormatError.new("shared Object size count overflows UInt64")
        else
          raise CorruptPartError.new("shared Object size count overflows UInt64")
        end
      end
      left * right
    end
  end
end
