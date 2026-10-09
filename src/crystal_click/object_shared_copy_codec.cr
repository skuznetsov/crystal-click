module CrystalClick
  # Paired exact-slice codec for one normalized Object shared Copy chunk.
  # Physical mark mapping and persisted Object-version admission remain owned
  # by their enclosing layouts.
  module ObjectSharedCopyCodec
    def self.encode(
      rows : Array(ObjectSharedMapRow),
      bucket_structures : Array(ObjectSharedChunkStructure),
      limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
    ) : ObjectSharedCopyStreams
      encode_with_budget(rows, bucket_structures, BinaryCodecBudget.new(limits, true))
    end

    def self.decode(
      sizes : Bytes,
      indexes : Bytes,
      values : Bytes,
      bucket_structures : Array(ObjectSharedChunkStructure),
      limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
    ) : Array(ObjectSharedMapRow)
      decode_with_budget(
        sizes,
        indexes,
        values,
        bucket_structures,
        BinaryCodecBudget.new(limits),
      )
    end

    def self.encode_with_budget(
      rows : Array(ObjectSharedMapRow),
      bucket_structures : Array(ObjectSharedChunkStructure),
      budget : BinaryCodecBudget,
    ) : ObjectSharedCopyStreams
      unless budget.writing?
        raise ArgumentError.new("Object shared Copy encode requires a writing budget")
      end

      dictionary = ObjectSharedCopyDictionary.new(bucket_structures, budget)
      unless rows.size == dictionary.row_count
        raise UnsupportedFormatError.new("Object shared Copy rows disagree with bucket structure row count")
      end

      rows_u64 = rows.size.to_u64
      total_entries = 0_u64
      referenced_path_bytes = 0_u64
      rows.each do |row|
        count = row.entry_count.to_u64
        if count > Int32::MAX.to_u64 || count > UInt64::MAX - total_entries
          raise UnsupportedFormatError.new("Object shared Copy entry count exceeds the in-memory domain")
        end
        total_entries += count
        row.entry_count.times do |entry_index|
          path_size = row.entry_at(entry_index).path_byte_size.to_u64
          if path_size > UInt64::MAX - referenced_path_bytes
            raise UnsupportedFormatError.new("Object shared Copy path work overflows UInt64")
          end
          referenced_path_bytes += path_size
        end
      end
      if total_entries > Int32::MAX.to_u64
        raise UnsupportedFormatError.new("Object shared Copy total entry count exceeds the in-memory domain")
      end

      preflight_rows_and_entries(budget, rows_u64, total_entries)

      width = dictionary.index_width
      sizes_bytes = checked_lane_bytes(rows_u64 * 8_u64, "sizes", true)
      indexes_bytes = checked_lane_bytes(total_entries * width.to_u64, "indexes", true)
      minimum_values_bytes = checked_multiply(total_entries, 2_u64, true, "minimum values size")
      minimum_wire = checked_add(checked_add(sizes_bytes, indexes_bytes, true, "lane size"), minimum_values_bytes, true, "minimum Copy wire size")
      # Establish the complete mandatory lane/framing envelope before creating
      # a materialized dictionary, used bitmap, or resolved-index array.
      budget.ensure_wire_bytes(minimum_wire)

      budget.charge_elements(dictionary.path_count.to_u64) # used-path bitmap
      dictionary.materialize!(budget, referenced_path_bytes)

      used = Array(Bool).new(dictionary.path_count, false)
      resolved_indexes = Array(Int32).new(total_entries.to_i)
      rows.each do |row|
        row.entry_count.times do |entry_index|
          entry = row.entry_at(entry_index)
          dictionary_index = dictionary.find_index(entry.path_byte_size) do |byte_index|
            entry.path_byte_at(byte_index)
          end
          index = dictionary_index || raise UnsupportedFormatError.new("Object shared Copy row path is absent from its bucket dictionary")
          used[index] = true
          resolved_indexes << index
        end
      end
      unless every_path_used?(used)
        raise UnsupportedFormatError.new("Object shared Copy dictionary contains an unreferenced path")
      end

      # Reserve/charge both fixed lanes before scalar envelopes are built, so
      # no value can consume bytes needed by later sizes or dictionary indexes.
      budget.charge_wire_bytes(sizes_bytes + indexes_bytes)
      sizes = Bytes.new(sizes_bytes.to_i32)
      encoded_indexes = Bytes.new(indexes_bytes.to_i32)
      write_counts_and_indexes(rows, resolved_indexes, width, sizes, encoded_indexes)

      values_context = BinaryCodecContext.new(budget.limits, nil, true, budget)
      flat_entry_index = 0_u64
      rows.each do |row|
        row.entry_count.times do |entry_index|
          entry = row.entry_at(entry_index)
          pending_after = total_entries - flat_entry_index - 1_u64
          future_minimum = checked_multiply(pending_after, 2_u64, true, "pending value framing")
          reserved = checked_add(1_u64, future_minimum, true, "pending value framing")
          envelope = BinaryValueCodec.encode_dynamic_bulk_child(
            entry.value,
            budget,
            1,
            reserved,
            allow_recursive_qbit: true,
            allow_qbit_variants: false,
          )
          frame_size = var_uint_size(envelope.size.to_u64)
          required = checked_add(
            checked_add(frame_size, envelope.size.to_u64, true, "value frame"),
            future_minimum,
            true,
            "pending value wire",
          )
          budget.ensure_wire_bytes(required)
          values_context.write_var_uint(envelope.size.to_u64)
          values_context.write_slice(envelope)
          flat_entry_index += 1_u64
        end
      end

      ObjectSharedCopyStreams.new(sizes, encoded_indexes, values_context.finish_bytes)
    end

    def self.decode_with_budget(
      sizes : Bytes,
      indexes : Bytes,
      values : Bytes,
      bucket_structures : Array(ObjectSharedChunkStructure),
      budget : BinaryCodecBudget,
    ) : Array(ObjectSharedMapRow)
      if budget.writing?
        raise ArgumentError.new("Object shared Copy decode requires a reading budget")
      end

      lane_bytes = checked_add(
        checked_add(sizes.size.to_u64, indexes.size.to_u64, false, "Copy lane size"),
        values.size.to_u64,
        false,
        "Copy lane size",
      )
      budget.charge_wire_bytes(lane_bytes)
      dictionary = ObjectSharedCopyDictionary.new(bucket_structures, budget)
      unless sizes.size % 8 == 0
        raise CorruptPartError.new("Object shared Copy sizes lane is not a whole UInt64 count array")
      end
      row_count = sizes.size // 8
      unless row_count == dictionary.row_count
        raise CorruptPartError.new("Object shared Copy sizes row count disagrees with bucket structures")
      end

      total_entries = 0_u64
      row_index = 0
      while row_index < row_count
        count = read_u64_le(sizes, row_index * 8)
        if count > Int32::MAX.to_u64 || count > UInt64::MAX - total_entries
          raise CorruptPartError.new("Object shared Copy row count exceeds the in-memory domain")
        end
        total_entries += count
        row_index += 1
      end
      if total_entries > Int32::MAX.to_u64
        raise CorruptPartError.new("Object shared Copy total entry count exceeds the in-memory domain")
      end

      width = dictionary.index_width
      expected_indexes = checked_multiply(total_entries, width.to_u64, false, "index extent")
      unless expected_indexes == indexes.size.to_u64
        raise CorruptPartError.new("Object shared Copy indexes lane has the wrong fixed-width extent")
      end
      minimum_values = checked_multiply(total_entries, 2_u64, false, "minimum values extent")
      if minimum_values > values.size.to_u64
        raise CorruptPartError.new("Object shared Copy values lane is too short for declared entries")
      end

      rows_u64 = row_count.to_u64
      preflight_rows_and_entries(budget, rows_u64, total_entries)
      budget.charge_elements(dictionary.path_count.to_u64) # used-path bitmap
      used = Array(Bool).new(dictionary.path_count, false)

      # Scan counts and fixed-width indexes before retaining any names, rows or
      # entries. This proves row byte order, exact dictionary use and the full
      # repeated path-copy work against the shared element budget.
      referenced_path_bytes = scan_indexes(indexes, sizes, dictionary, used, width)
      unless every_path_used?(used)
        raise CorruptPartError.new("Object shared Copy dictionary contains an unreferenced path")
      end
      dictionary.materialize!(budget, referenced_path_bytes)

      rows = Array(ObjectSharedMapRow).new(row_count)
      values_context = BinaryCodecContext.new(budget.limits, values, false, budget, false)
      index_offset = 0
      row_index = 0
      while row_index < row_count
        entry_count = read_u64_le(sizes, row_index * 8).to_i
        entries = Array(ObjectSharedMapEntry).new(entry_count)
        previous_index : Int32? = nil
        entry_index = 0
        while entry_index < entry_count
          dictionary_index = read_index(indexes, index_offset, width).to_i
          if previous = previous_index
            if dictionary.compare_source_paths(previous, dictionary_index) >= 0
              raise CorruptPartError.new("Object shared Copy row indexes are not in byte-path order")
            end
          end
          index_offset += width

          envelope_size = values_context.read_var_uint
          envelope = values_context.read_slice(envelope_size)
          type, decoded_value = BinaryValueCodec.decode_dynamic_bulk_child(
            envelope,
            budget,
            1,
            allow_recursive_qbit: true,
            allow_qbit_variants: false,
          )
          value = decoded_value || BinaryValue.null(type)
          entries << dictionary.map_entry(dictionary_index, value)
          previous_index = dictionary_index
          entry_index += 1
        end
        begin
          rows << ObjectSharedMapRow.new(entries)
        rescue ex : ArgumentError
          raise CorruptPartError.new("invalid Object shared Copy row: #{ex.message}")
        end
        row_index += 1
      end
      values_context.ensure_consumed
      rows
    end

    private def self.scan_indexes(
      indexes : Bytes,
      sizes : Bytes,
      dictionary : ObjectSharedCopyDictionary,
      used : Array(Bool),
      width : Int32,
    ) : UInt64
      referenced_bytes = 0_u64
      index_offset = 0
      row_index = 0
      while row_index < sizes.size // 8
        count = read_u64_le(sizes, row_index * 8).to_i
        previous_index : Int32? = nil
        entry_index = 0
        while entry_index < count
          raw_index = read_index(indexes, index_offset, width)
          if raw_index >= dictionary.path_count.to_u64
            raise CorruptPartError.new("Object shared Copy index is outside its chunk dictionary")
          end
          dictionary_index = raw_index.to_i32
          if previous = previous_index
            if dictionary.compare_source_paths(previous, dictionary_index) >= 0
              raise CorruptPartError.new("Object shared Copy row indexes are not in byte-path order")
            end
          end
          path_size = dictionary.source_path_byte_size(dictionary_index).to_u64
          if path_size > UInt64::MAX - referenced_bytes
            raise CorruptPartError.new("Object shared Copy repeated path work overflows UInt64")
          end
          referenced_bytes += path_size
          used[dictionary_index] = true
          previous_index = dictionary_index
          index_offset += width
          entry_index += 1
        end
        row_index += 1
      end
      referenced_bytes
    end

    private def self.write_counts_and_indexes(
      rows : Array(ObjectSharedMapRow),
      resolved_indexes : Array(Int32),
      width : Int32,
      sizes : Bytes,
      indexes : Bytes,
    ) : Nil
      index_offset = 0
      rows.each_with_index do |row, row_index|
        write_u64_le(sizes, row_index * 8, row.entry_count.to_u64)
        row.entry_count.times do |entry_index|
          write_index(indexes, index_offset, resolved_indexes[index_offset // width].to_u64, width)
          index_offset += width
        end
      end
    end

    private def self.preflight_rows_and_entries(
      budget : BinaryCodecBudget,
      rows : UInt64,
      entries : UInt64,
    ) : Nil
      if entries > UInt64::MAX - rows
        fail_layout!(budget.writing?, "Object shared Copy minimum work overflows UInt64")
      end
      budget.preflight_children(rows + entries)
      (rows + entries).times { budget.charge_node }
      nil
    end

    private def self.every_path_used?(used : Array(Bool)) : Bool
      used.each do |seen|
        return false unless seen
      end
      true
    end

    private def self.read_index(bytes : Bytes, offset : Int, width : Int32) : UInt64
      value = 0_u64
      width.times do |byte_index|
        value |= bytes[offset + byte_index].to_u64 << (byte_index * 8)
      end
      value
    end

    private def self.write_index(bytes : Bytes, offset : Int, value : UInt64, width : Int32) : Nil
      width.times do |byte_index|
        bytes[offset + byte_index] = ((value >> (byte_index * 8)) & 0xff_u64).to_u8
      end
    end

    private def self.read_u64_le(bytes : Bytes, offset : Int) : UInt64
      value = 0_u64
      8.times do |byte_index|
        value |= bytes[offset + byte_index].to_u64 << (byte_index * 8)
      end
      value
    end

    private def self.write_u64_le(bytes : Bytes, offset : Int, value : UInt64) : Nil
      8.times do |byte_index|
        bytes[offset + byte_index] = ((value >> (byte_index * 8)) & 0xff_u64).to_u8
      end
    end

    private def self.checked_lane_bytes(
      value : UInt64,
      label : String,
      writing : Bool,
    ) : UInt64
      if value > Int32::MAX.to_u64
        fail_layout!(writing, "Object shared Copy #{label} lane exceeds the in-memory byte domain")
      end
      value
    end

    private def self.checked_multiply(
      left : UInt64,
      right : UInt64,
      writing : Bool,
      label : String,
    ) : UInt64
      if right != 0_u64 && left > UInt64::MAX // right
        fail_layout!(writing, "Object shared Copy #{label} overflows UInt64")
      end
      left * right
    end

    private def self.checked_add(
      left : UInt64,
      right : UInt64,
      writing : Bool,
      label : String,
    ) : UInt64
      if right > UInt64::MAX - left
        fail_layout!(writing, "Object shared Copy #{label} overflows UInt64")
      end
      left + right
    end

    private def self.var_uint_size(value : UInt64) : UInt64
      size = 1_u64
      remaining = value >> 7
      while remaining > 0_u64
        size += 1_u64
        remaining >>= 7
      end
      size
    end

    private def self.fail_layout!(writing : Bool, message : String) : NoReturn
      if writing
        raise UnsupportedFormatError.new(message)
      else
        raise CorruptPartError.new(message)
      end
    end
  end
end
