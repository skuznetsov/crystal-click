module CrystalClick
  # Owned flat representation of one exact Compact
  # Array(Tuple(a UInt64, b String)) mark. The slices borrow this result's
  # buffers and are exposed as read-only slices; String payload bytes are
  # copied from authenticated normalized lanes before this owner is returned.
  class CompactArrayTupleUInt64StringMark
    MAX_ITEMS = (Int32::MAX - 1).to_u64

    @row_offsets : Array(UInt64)
    @uint64_values : Array(UInt64)
    @string_offsets : Array(UInt64)
    @string_payload : Bytes

    getter row_count : Int32
    getter element_count : Int32
    getter string_byte_count : Int32

    private def initialize(
      @row_count : Int32,
      @element_count : Int32,
      @string_byte_count : Int32,
      @row_offsets : Array(UInt64),
      @uint64_values : Array(UInt64),
      @string_offsets : Array(UInt64),
      @string_payload : Bytes,
    )
    end

    # Borrowed read-only views over this result's owned buffers. Keep this owner
    # alive for as long as any returned slice is used.
    def row_offsets : Slice(UInt64)
      Slice.new(@row_offsets.to_unsafe, @row_offsets.size, read_only: true)
    end

    def uint64_values : Slice(UInt64)
      Slice.new(@uint64_values.to_unsafe, @uint64_values.size, read_only: true)
    end

    def string_offsets : Slice(UInt64)
      Slice.new(@string_offsets.to_unsafe, @string_offsets.size, read_only: true)
    end

    def string_payload : Bytes
      Bytes.new(@string_payload.to_unsafe, @string_payload.size, read_only: true)
    end

    def string_bytes_at(element_index : Int) : Bytes
      unless element_index >= 0 && element_index < @element_count
        raise IndexError.new("Array(Tuple) element index is outside the selected mark")
      end
      first = @string_offsets[element_index]
      limit = @string_offsets[element_index + 1]
      Bytes.new(@string_payload.to_unsafe + first.to_i32, (limit - first).to_i32, read_only: true)
    end

    # :nodoc:
    # Decode one already-normalized exact-type mark without BinaryValue
    # construction. The caller owns Compact grammar/authentication; this
    # method proves exact normalized roles, extents, budgets, and output bounds.
    def self.decode(
      type : BinaryDataType,
      streams : BinaryBulkStreams,
      rows_per_mark : Array(UInt64),
      profile : BinaryBulkProfile,
      budget : BinaryCodecBudget,
      workspace_observer : Proc(UInt64, Nil),
      physical_workspace_bytes : UInt64,
    ) : CompactArrayTupleUInt64StringMark
      if budget.writing?
        raise ArgumentError.new("Compact exact Array(Tuple) reader requires a read-direction budget")
      end
      unless type.name == WideTypePlan::TYPE_ARRAY_TUPLE_UINT64_STRING &&
             type.tag == BinaryDataType::TAG_ARRAY
        raise UnsupportedFormatError.new("Compact flat Array(Tuple) reader requires its exact named declaration")
      end
      tuple_type = type.child_at(0)
      unless tuple_type.tag == BinaryDataType::TAG_NAMED_TUPLE && tuple_type.child_count == 2 &&
             tuple_type.field_name_at(0) == "a" && tuple_type.field_name_at(1) == "b" &&
             tuple_type.child_at(0).tag == BinaryDataType::TAG_UINT64 &&
             tuple_type.child_at(1).tag == BinaryDataType::TAG_STRING
        raise CorruptPartError.new("Compact flat Array(Tuple) descriptor differs from its exact declaration")
      end
      unless streams.mark_count == 1 && rows_per_mark.size == 1
        raise CorruptPartError.new("Compact flat Array(Tuple) reader requires exactly one normalized mark")
      end

      traversal = BinaryCodecContext.new(budget.limits, nil, false, budget, false, false)
      traversal.validate_type_tree(type)
      plan = BinaryBulkTypePlan.new(type, profile, nil, budget.limits, false)
      roles = plan.roles
      unless plan.ordinary_role_count == roles.size && streams.role_count == roles.size
        raise CorruptPartError.new("Compact flat Array(Tuple) lane count differs from its exact plan")
      end
      roles.each do |role|
        unless streams.has_role?(role)
          raise CorruptPartError.new("Compact flat Array(Tuple) lane is missing")
        end
      end
      validate_grids!(streams, roles)

      # Match BinaryBulkDecoder's descriptor-grid accounting for a one-mark,
      # non-LowCardinality root after normalization's own grid charges.
      mark_count = streams.mark_count.to_u64
      offsets_per_role = checked_add(mark_count, 1_u64)
      metadata_records = checked_add(checked_multiply(roles.size.to_u64, offsets_per_role), mark_count)
      traversal.preflight_children(metadata_records)
      metadata_records.times { budget.charge_node }

      row_count = rows_per_mark[0]
      if row_count >= Int32::MAX.to_u64
        raise CorruptPartError.new("Compact flat Array(Tuple) row count exceeds its supported domain")
      end
      budget.ensure_future_nodes(row_count)

      wire_bytes = streams.total_input_byte_size
      budget.ensure_wire_bytes(wire_bytes)
      budget.charge_wire_bytes(wire_bytes)

      sizes = streams.stream("root.sizes")
      values = streams.stream("root.elements.field.0.data")
      string_data = streams.stream("root.elements.field.1.data")
      string_sizes = if profile.with_size_stream?
                       streams.stream("root.elements.field.1.string_sizes")
                     else
                       nil
                     end

      sizes_start = sizes.offset_at(0)
      sizes_end = sizes.offset_at(1)
      size_bytes = checked_multiply(row_count, 8_u64)
      unless sizes_end - sizes_start == size_bytes
        raise CorruptPartError.new("Compact flat Array(Tuple) size lane differs from the parent row count")
      end
      outer_sizes = sizes.borrowed_slice(sizes_start, size_bytes)

      element_count = 0_u64
      row_count.to_i.times do |row_index|
        count = read_u64_le(outer_sizes, row_index * 8)
        if count > MAX_ITEMS || element_count > MAX_ITEMS - count
          raise CorruptPartError.new("Compact flat Array(Tuple) element count exceeds its supported domain")
        end
        element_count += count
      end

      fixed_bytes = checked_multiply(element_count, 8_u64)
      value_bytes = lane_slice!(values, fixed_bytes, "UInt64 field")
      size_lane_bytes = if lane = string_sizes
                          lane_slice!(lane, fixed_bytes, "String size")
                        else
                          nil
                        end
      data_bytes = lane_slice!(string_data, nil, "String data")

      string_byte_count = 0_u64
      if profile.with_size_stream?
        string_size_bytes = size_lane_bytes || raise(CorruptPartError.new("Compact flat String size lane is missing"))
        element_count.to_i.times do |index|
          string_byte_count = checked_add(string_byte_count, read_u64_le(string_size_bytes, index * 8))
        end
        unless string_byte_count == data_bytes.size.to_u64
          raise CorruptPartError.new("Compact flat String size lane differs from its payload")
        end
      else
        data_context = BinaryCodecContext.new(budget.limits, data_bytes, false, budget, false, false)
        element_count.to_i.times do
          length = data_context.read_var_uint
          data_context.read_slice(length)
          string_byte_count = checked_add(string_byte_count, length)
        end
        data_context.ensure_consumed
      end
      if string_byte_count > Int32::MAX.to_u64
        raise CorruptPartError.new("Compact flat String payload exceeds its supported domain")
      end

      tuple_edges = checked_multiply(element_count, 3_u64)
      tuple_nodes = checked_multiply(element_count, 3_u64)
      budget.ensure_future_elements(tuple_edges)
      budget.ensure_future_nodes(checked_add(row_count, tuple_nodes))

      result_bytes = checked_add(
        checked_multiply(checked_add(row_count, 1_u64), 8_u64),
        checked_add(
          checked_multiply(checked_add(element_count, 1_u64), 8_u64),
          checked_add(checked_multiply(element_count, 8_u64), string_byte_count),
        ),
      )
      if result_bytes > WidePartTable::MAX_MARK_MATERIALIZED_BYTES.to_u64
        raise CorruptPartError.new("Compact flat Array(Tuple) mark exceeds the materialization limit")
      end

      retained_normalized = retained_stream_workspace_bytes(streams, roles)
      output_workspace = checked_add(
        instance_sizeof(CompactArrayTupleUInt64StringMark).to_u64,
        checked_add(
          result_bytes,
          checked_add(
            instance_sizeof(Array(UInt64)).to_u64 * 3_u64,
            sizeof(Bytes).to_u64,
          ),
        ),
      )
      workspace = checked_add(physical_workspace_bytes, checked_add(retained_normalized, output_workspace))
      workspace_observer.call(workspace)

      row_count_i32 = row_count.to_i32
      element_count_i32 = element_count.to_i32
      payload_size = string_byte_count.to_i32
      row_offsets = Array(UInt64).new(row_count_i32 + 1, 0_u64)
      uint64_values = Array(UInt64).new(element_count_i32, 0_u64)
      string_offsets = Array(UInt64).new(element_count_i32 + 1, 0_u64)
      string_payload = Bytes.new(payload_size)

      value_cursor = 0
      string_cursor = 0
      payload_cursor = 0
      string_context = if profile.with_size_stream?
                         nil
                       else
                         BinaryCodecContext.new(budget.limits, data_bytes, false, budget, false, false)
                       end
      row_count_i32.times do |row_index|
        element_count_for_row = read_u64_le(outer_sizes, row_index * 8)
        traversal.visit_node(1)
        traversal.preflight_children(element_count_for_row)
        traversal.ensure_depth(2) if element_count_for_row > 0_u64
        element_count_for_row.to_i.times do
          traversal.visit_node(2)
          traversal.preflight_children(2_u64)
          traversal.ensure_depth(3)
          traversal.visit_node(3)
          traversal.visit_node(3)

          uint64_values[value_cursor] = read_u64_le(value_bytes, value_cursor * 8)
          string_offsets[value_cursor] = payload_cursor.to_u64
          length = if size_bytes = size_lane_bytes
                     read_u64_le(size_bytes, value_cursor * 8)
                   else
                     context = string_context || raise(CorruptPartError.new("Compact flat String cursor is missing"))
                     context.read_var_uint
                   end
          part = if size_lane_bytes
                   if length > (data_bytes.size - payload_cursor).to_u64
                     raise CorruptPartError.new("Compact flat String extent is outside its payload lane")
                   end
                   data_bytes[payload_cursor, length.to_i32]
                 else
                   (string_context || raise(CorruptPartError.new("Compact flat String cursor is missing"))).read_slice(length)
                 end
          part.copy_to(string_payload.to_unsafe + payload_cursor, part.size)
          payload_cursor += part.size
          string_cursor += 8 if size_lane_bytes
          value_cursor += 1
        end
        row_offsets[row_index + 1] = value_cursor.to_u64
      end
      string_context.try(&.ensure_consumed)
      string_offsets[element_count_i32] = payload_cursor.to_u64
      unless value_cursor == element_count_i32 && payload_cursor == payload_size &&
             (!size_lane_bytes || string_cursor == size_lane_bytes.not_nil!.size)
        raise CorruptPartError.new("Compact flat Array(Tuple) traversal differs from its preflight")
      end

      new(
        row_count_i32,
        element_count_i32,
        payload_size,
        row_offsets,
        uint64_values,
        string_offsets,
        string_payload,
      )
    end

    private def self.validate_grids!(streams : BinaryBulkStreams, roles : Array(String)) : Nil
      roles.each do |role|
        stream = streams.stream(role)
        unless stream.mark_count == 1 && stream.offset_count == 2 && stream.offset_at(0) == 0_u64
          raise CorruptPartError.new("Compact flat Array(Tuple) lane has an invalid mark grid")
        end
        terminal = stream.offset_at(1)
        unless terminal == stream.byte_size.to_u64
          raise CorruptPartError.new("Compact flat Array(Tuple) lane terminal offset is invalid")
        end
      end
    end

    private def self.lane_slice!(stream : BinaryBulkStream, expected_size : UInt64?, label : String) : Bytes
      first = stream.offset_at(0)
      finish = stream.offset_at(1)
      size = finish - first
      if expected = expected_size
        unless size == expected
          raise CorruptPartError.new("Compact flat #{label} lane differs from its element count")
        end
      end
      stream.borrowed_slice(first, size)
    end

    private def self.retained_stream_workspace_bytes(streams : BinaryBulkStreams, roles : Array(String)) : UInt64
      bytes = checked_add(instance_sizeof(BinaryBulkStreams).to_u64, instance_sizeof(Hash(String, BinaryBulkStream)).to_u64)
      bytes = checked_add(bytes, streams.total_input_byte_size)
      bytes = checked_add(bytes, checked_multiply(checked_multiply(roles.size.to_u64, 2_u64), sizeof(UInt64).to_u64))
      roles.each do |role|
        bytes = checked_add(bytes, instance_sizeof(BinaryBulkStream).to_u64)
        bytes = checked_add(bytes, checked_add(instance_sizeof(String).to_u64, role.bytesize.to_u64 + 1_u64))
        bytes = checked_add(bytes, sizeof(Bytes).to_u64)
        bytes = checked_add(bytes, instance_sizeof(Array(UInt64)).to_u64)
      end
      bytes
    end

    private def self.read_u64_le(bytes : Bytes, offset : Int) : UInt64
      if offset < 0 || offset > bytes.size - 8
        raise CorruptPartError.new("Compact flat Array(Tuple) UInt64 lane is truncated")
      end
      value = 0_u64
      8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
      value
    end

    private def self.checked_add(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        raise CorruptPartError.new("Compact flat Array(Tuple) size overflows UInt64")
      end
      left + right
    end

    private def self.checked_multiply(left : UInt64, right : UInt64) : UInt64
      if right > 0_u64 && left > UInt64::MAX // right
        raise CorruptPartError.new("Compact flat Array(Tuple) size overflows UInt64")
      end
      left * right
    end
  end
end
