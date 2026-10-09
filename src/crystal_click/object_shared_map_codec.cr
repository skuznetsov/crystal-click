module CrystalClick
  # Paired codec for the bounded three-lane physical shared Object MAP block.
  # It is intentionally below WidePart orchestration and accepts only exact
  # caller-selected, fully decompressed stream slices plus their local rows.
  module ObjectSharedMapCodec
    def self.decode(
      sizes : Bytes,
      paths : Bytes,
      values : Bytes,
      row_count : Int,
      limits : BinaryCodecLimits = BinaryCodecLimits.default,
    ) : Array(ObjectSharedMapRow)
      unless row_count >= 0 && row_count <= Int32::MAX
        raise CorruptPartError.new("Object shared MAP row count is outside the supported in-memory range")
      end

      rows_u64 = row_count.to_u64
      expected_sizes = rows_u64 * 8_u64
      if expected_sizes > Int32::MAX.to_u64 || sizes.size.to_u64 != expected_sizes
        raise CorruptPartError.new("Object shared MAP sizes lane does not contain one UInt64 per row")
      end

      budget = BinaryCodecBudget.new(limits)
      input_bytes = sizes.size.to_u64 + paths.size.to_u64 + values.size.to_u64
      budget.charge_wire_bytes(input_bytes)

      # First count pass uses only the fixed-width borrowed sizes lane. It does
      # not allocate a count array or any row/entry collection.
      budget.ensure_future_nodes(rows_u64)
      budget.ensure_future_elements(rows_u64)
      total_entries = 0_u64
      row_index = 0
      while row_index < row_count
        count = read_u64_le(sizes, row_index * 8)
        if count > Int32::MAX.to_u64
          raise CorruptPartError.new("Object shared MAP row entry count exceeds in-memory range")
        end
        if count > UInt64::MAX - total_entries
          raise CorruptPartError.new("Object shared MAP total entry count overflows UInt64")
        end
        total_entries += count
        row_index += 1
      end

      minimum_nodes = checked_minimum_nodes(rows_u64, total_entries)
      minimum_elements = checked_minimum_elements(rows_u64, total_entries)
      budget.ensure_future_nodes(minimum_nodes)
      budget.ensure_future_elements(minimum_elements)

      # Each entry requires at least a path length byte and a value-frame
      # length plus one descriptor byte. Prove these cardinalities before any
      # count-derived Array allocation, even with raised logical limits.
      if total_entries > paths.size.to_u64
        raise CorruptPartError.new("Object shared MAP paths lane cannot contain the declared entry count")
      end
      if total_entries > values.size.to_u64 // 2_u64
        raise CorruptPartError.new("Object shared MAP values lane cannot contain the declared entry count")
      end

      # Charge outer row/entry visits and edges without imposing recursive
      # depth; each W117 envelope starts its own depth tree at one.
      rows_u64.times do
        budget.charge_node
        budget.charge_elements(1_u64)
      end
      total_entries.times do
        budget.charge_node
        budget.charge_elements(1_u64)
      end

      decoded = Array(ObjectSharedMapRow).new(row_count)
      path_context = BinaryCodecContext.new(limits, paths, false, budget, false)
      value_context = BinaryCodecContext.new(limits, values, false, budget, false)
      row_index = 0
      while row_index < row_count
        entry_count = read_u64_le(sizes, row_index * 8).to_i
        entries = Array(ObjectSharedMapEntry).new(entry_count)
        previous_path : Bytes? = nil
        entry_index = 0
        while entry_index < entry_count
          path_size = path_context.read_var_uint
          path = path_context.read_slice(path_size)
          if previous = previous_path
            if compare_paths(previous, path) >= 0
              raise CorruptPartError.new("Object shared MAP paths are not strictly byte-sorted")
            end
          end

          value_size = value_context.read_var_uint
          envelope = value_context.read_slice(value_size)
          value = BinaryValueCodec.decode_shared_json_envelope(envelope, budget)
          entries << ObjectSharedMapEntry.new(path, value)
          previous_path = path
          entry_index += 1
        end
        decoded << ObjectSharedMapRow.new(entries)
        row_index += 1
      end
      path_context.ensure_consumed
      value_context.ensure_consumed
      decoded
    end

    def self.encode(
      rows : Array(ObjectSharedMapRow),
      limits : BinaryCodecLimits = BinaryCodecLimits.default,
    ) : ObjectSharedMapStreams
      row_count = rows.size
      rows_u64 = row_count.to_u64
      total_entries = 0_u64
      rows.each do |row|
        count = row.entry_count.to_u64
        if count > UInt64::MAX - total_entries
          raise UnsupportedFormatError.new("Object shared MAP total entry count overflows UInt64")
        end
        total_entries += count
      end

      budget = BinaryCodecBudget.new(limits, true)
      minimum_nodes = checked_minimum_nodes(rows_u64, total_entries)
      minimum_elements = checked_minimum_elements(rows_u64, total_entries)
      budget.ensure_future_nodes(minimum_nodes)
      budget.ensure_future_elements(minimum_elements)

      # Outer row and entry visits are not recursive type/value depth nodes.
      rows_u64.times do
        budget.charge_node
        budget.charge_elements(1_u64)
      end
      total_entries.times do
        budget.charge_node
        budget.charge_elements(1_u64)
      end

      sizes_context = BinaryCodecContext.new(limits, nil, true, budget)
      paths_context = BinaryCodecContext.new(limits, nil, true, budget)
      values_context = BinaryCodecContext.new(limits, nil, true, budget)
      rows.each do |row|
        write_u64_le(sizes_context, row.entry_count.to_u64)
        row.entry_count.times do |entry_index|
          entry = row.entry_at(entry_index)
          path_size = entry.path_byte_size
          paths_context.write_var_uint(path_size.to_u64)
          path_size.times do |byte_index|
            paths_context.write_byte(entry.path_byte_at(byte_index))
          end

          envelope = BinaryValueCodec.encode_shared_json_envelope(entry.value, budget)
          values_context.write_var_uint(envelope.size.to_u64)
          values_context.write_slice(envelope)
        end
      end

      ObjectSharedMapStreams.new(
        sizes_context.finish_bytes,
        paths_context.finish_bytes,
        values_context.finish_bytes
      )
    end

    private def self.read_u64_le(bytes : Bytes, offset : Int) : UInt64
      value = 0_u64
      8.times do |byte_index|
        value |= bytes[offset + byte_index].to_u64 << (byte_index * 8)
      end
      value
    end

    private def self.write_u64_le(context : BinaryCodecContext, value : UInt64) : Nil
      8.times do |byte_index|
        context.write_byte(((value >> (byte_index * 8)) & 0xff_u64).to_u8)
      end
    end

    private def self.checked_minimum_nodes(rows : UInt64, entries : UInt64) : UInt64
      if entries > (UInt64::MAX - rows) // 3_u64
        raise CorruptPartError.new("Object shared MAP minimum node count overflows UInt64")
      end
      rows + entries * 3_u64
    end

    private def self.checked_minimum_elements(rows : UInt64, entries : UInt64) : UInt64
      if entries > UInt64::MAX - rows
        raise CorruptPartError.new("Object shared MAP minimum element count overflows UInt64")
      end
      rows + entries
    end

    private def self.compare_paths(left : Bytes, right : Bytes) : Int32
      common_size = Math.min(left.size, right.size)
      common_size.times do |index|
        left_byte = left[index]
        right_byte = right[index]
        return -1 if left_byte < right_byte
        return 1 if left_byte > right_byte
      end
      left.size <=> right.size
    end
  end
end
