module CrystalClick
  # Writes admitted static and explicitly bound Dynamic/Object columns
  # into one granule-major Compact tape and selected MRK3/MRK4 coordinate
  # grid. Metadata and publication remain owned by the table writer.
  class CompactStaticWriter
    private struct GranuleLayout
      getter raw_size : UInt64
      getter compressed_size : UInt64
      getter positions : Array(Tuple(UInt64, UInt64))

      def initialize(
        @raw_size : UInt64,
        @compressed_size : UInt64,
        @positions : Array(Tuple(UInt64, UInt64)),
      )
      end
    end

    def self.encode(
      columns : Array(CompactStaticColumnInput),
      rows_per_mark : Array(UInt64),
      limits : BinaryCodecLimits,
      frame_bytes : Int,
      transport_budget : CompressedStreamBudget,
      codec_budget : BinaryCodecBudget,
      plan : CompactStaticWritePlan,
    ) : CompactStaticPartFiles
      validate_codec_budget!(codec_budget, limits)
      validate_transport_budget!(transport_budget)
      validate_frame_bytes!(frame_bytes)
      mark_count, column_count, row_count = validate_input_grid!(columns, rows_per_mark)
      validate_write_plan!(columns, plan, limits, column_count)

      plans = plan.column_plans
      encoded = Array(CompactPartEncodedColumn).new(column_count)
      columns.each_with_index do |column, index|
        callback_plan = plans[index]
        encoded << CompactEncodedColumn.encode(callback_plan, column.granules, codec_budget)
      end

      encode_prepared(
        encoded,
        rows_per_mark,
        mark_count,
        frame_bytes,
        transport_budget,
        plan.mark_format,
        plan.slot_count,
      )
    end

    # Mixed entry point. The existing static entry point and its strict static
    # callback-plan contract remain unchanged.
    def self.encode_mixed(
      columns : Array(CompactPartWriteInput),
      rows_per_mark : Array(UInt64),
      limits : BinaryCodecLimits,
      frame_bytes : Int,
      transport_budget : CompressedStreamBudget,
      codec_budget : BinaryCodecBudget,
      plan : CompactPartWritePlan,
    ) : CompactStaticPartFiles
      validate_codec_budget!(codec_budget, limits)
      validate_transport_budget!(transport_budget)
      validate_frame_bytes!(frame_bytes)
      mark_count, column_count, _row_count = validate_input_grid!(columns, rows_per_mark)
      validate_mixed_write_plan!(columns, plan, limits, column_count)

      callback_plans = plan.column_plans
      encoded = Array(CompactPartEncodedColumn).new(column_count)
      columns.each_with_index do |column, index|
        callback_plan = callback_plans[index]
        case column
        when CompactStaticColumnInput
          static_plan = callback_plan.as?(CompactStaticCallbackPlan) ||
                        raise(ArgumentError.new("Compact mixed static callback plan differs from its input"))
          encoded << CompactEncodedColumn.encode(static_plan, column.granules, codec_budget)
        when CompactDynamicColumnInput
          dynamic_plan = callback_plan.as?(CompactDynamicCallbackPlan) ||
                         raise(ArgumentError.new("Compact mixed Dynamic callback plan differs from its input"))
          encoded << CompactDynamicEncodedColumn.encode(dynamic_plan, column.granules, codec_budget)
        when CompactJsonColumnInput
          json_plan = callback_plan.as?(CompactJsonCallbackPlan) ||
                      raise(ArgumentError.new("Compact mixed JSON callback plan differs from its input"))
          encoded << CompactJsonEncodedColumn.encode(json_plan, codec_budget)
        else
          raise UnsupportedFormatError.new("unsupported Compact mixed writer input")
        end
      end

      encode_prepared(
        encoded,
        rows_per_mark,
        mark_count,
        frame_bytes,
        transport_budget,
        plan.mark_format,
        plan.slot_count,
      )
    end

    private def self.encode_prepared(
      encoded : Array(CompactPartEncodedColumn),
      rows_per_mark : Array(UInt64),
      mark_count : Int32,
      frame_bytes : Int,
      transport_budget : CompressedStreamBudget,
      mark_format : CompactMarkFormat,
      slot_count : Int32,
    ) : CompactStaticPartFiles
      mark_size, mark_record_entries, position_query_count, position_result_bytes =
        preflight_mark_grid!(slot_count, mark_count, transport_budget)

      layouts = Array(GranuleLayout).new(mark_count)
      total_raw_size = 0_u64
      total_compressed_size = 0_u64
      total_frame_count = 0_i64

      mark_count.times do |mark_index|
        position_queries = Array(UInt64).new(slot_count + 1)
        segment_raw_size = 0_u64
        encoded.each do |column|
          unless mark_format.mrk4?
            # MRK3 retains one whole-column coordinate before its first
            # callback, even when every callback for that column is empty.
            position_queries << segment_raw_size
          end
          column.each_callback_event do |callback|
            if mark_format.mrk4?
              # MRK4 has one ordered slot per actual callback. Equal offsets
              # are significant when this callback emits no bytes.
              position_queries << segment_raw_size
            end
            length = column.callback_bytes(callback, mark_index).size.to_u64
            segment_raw_size = checked_add_u64(segment_raw_size, length)
            if segment_raw_size > Int32::MAX.to_u64
              raise UnsupportedFormatError.new("Compact granule exceeds the in-memory raw tape domain")
            end
          end
        end
        position_queries << segment_raw_size
        unless position_queries.size == slot_count + 1
          raise UnsupportedFormatError.new("Compact granule query grid differs from its physical slot roster")
        end

        positions = CompressedMarkWriter.plan_literal_positions(
          segment_raw_size.to_i64,
          position_queries,
          frame_bytes,
          transport_budget,
        )
        unless positions.size == slot_count + 1
          raise UnsupportedFormatError.new("Compact granule position plan is incomplete")
        end
        compressed_size = positions[slot_count][0]
        unless positions[slot_count][1] == 0_u64
          raise UnsupportedFormatError.new("Compact granule EOF position is not frame-aligned")
        end
        positions.each do |position|
          if position[0] > compressed_size || (position[0] == compressed_size && position[1] != 0_u64)
            raise UnsupportedFormatError.new("Compact granule coordinate is outside its compressed segment")
          end
        end

        total_raw_size = checked_add_u64(total_raw_size, segment_raw_size)
        total_compressed_size = checked_add_u64(total_compressed_size, compressed_size)
        total_frame_count = checked_add_i64(total_frame_count, frame_count(segment_raw_size, frame_bytes))
        layouts << GranuleLayout.new(segment_raw_size, compressed_size, positions)
      end

      unless total_raw_size > 0_u64 && total_compressed_size > 0_u64
        raise UnsupportedFormatError.new("Compact data.bin must contain a nonempty compressed tape")
      end
      if total_raw_size > transport_budget.limits.max_decoded_bytes.to_u64
        raise UnsupportedFormatError.new("Compact raw tape exceeds the shared decoded-byte budget")
      end
      if total_compressed_size > Int32::MAX.to_u64 || mark_size > Int32::MAX.to_i64
        raise UnsupportedFormatError.new("Compact output exceeds the in-memory file domain")
      end

      data_size = total_compressed_size.to_i64
      total_file_size = checked_add_i64(data_size, mark_size)
      if total_file_size > Int32::MAX.to_i64
        raise UnsupportedFormatError.new("Compact output pair exceeds the in-memory file domain")
      end

      # Position planning has already consumed the query records/results. Check
      # every future frame, physical mark field, raw byte, file byte and result
      # before allocating the assembled tape or either final file.
      future_record_count = checked_add_i64(total_frame_count, mark_record_entries)
      # Account for compressed segment temporaries, the assembled output pair,
      # and the defensive copies retained by CompactStaticPartFiles.
      temporary_and_final_result_bytes = checked_add_i64(
        checked_multiply_i64(data_size, 3_i64),
        checked_multiply_i64(mark_size, 2_i64),
      )
      transport_budget.preflight_records(future_record_count)
      transport_budget.preflight_decoded_bytes(total_raw_size.to_i64)
      transport_budget.preflight_file_bytes(total_file_size)
      transport_budget.preflight_result_bytes(temporary_and_final_result_bytes)

      transport_budget.reserve_records(mark_record_entries)
      transport_budget.reserve_file_bytes(mark_size)
      transport_budget.reserve_result_bytes(total_file_size)

      data = Bytes.new(data_size.to_i)
      marks = Bytes.new(mark_size.to_i)
      raw_hasher = CityHashV1::FileHasher.new
      data_cursor = 0
      mark_cursor = 0
      compressed_base = 0_u64

      layouts.each_with_index do |layout, mark_index|
        raw_segment = assemble_granule(encoded, mark_index, layout.raw_size)
        raw_hasher.update(raw_segment)

        if raw_segment.empty?
          unless layout.compressed_size == 0_u64
            raise UnsupportedFormatError.new("empty Compact granule planned a nonempty compressed segment")
          end
        else
          compressed_segment = CompressedMarkWriter.encode_all(
            raw_segment,
            frame_bytes,
            transport_budget,
          )
          unless compressed_segment.size.to_u64 == layout.compressed_size
            raise UnsupportedFormatError.new("Compact compressed segment differs from its authenticated position plan")
          end
          if compressed_segment.size > data.size - data_cursor
            raise UnsupportedFormatError.new("Compact compressed segment exceeds its output file")
          end
          compressed_segment.copy_to(data[data_cursor, compressed_segment.size])
          data_cursor += compressed_segment.size
        end

        layout.positions.each_with_index do |position, slot_index|
          next if slot_index == slot_count
          global_compressed_offset = checked_add_u64(compressed_base, position[0])
          if global_compressed_offset > total_compressed_size
            raise UnsupportedFormatError.new("Compact mark coordinate exceeds data.bin")
          end
          write_u64_le(marks, mark_cursor, global_compressed_offset)
          write_u64_le(marks, mark_cursor + 8, position[1])
          mark_cursor += 16
        end
        write_u64_le(marks, mark_cursor, rows_per_mark[mark_index])
        mark_cursor += 8
        compressed_base = checked_add_u64(compressed_base, layout.compressed_size)
      end

      terminal_record_size = checked_add_i64(
        checked_multiply_i64(slot_count.to_i64, 16_i64),
        8_i64,
      )
      expected_terminal_offset = mark_size - terminal_record_size
      unless data_cursor == data.size && compressed_base == total_compressed_size &&
             mark_cursor.to_i64 == expected_terminal_offset
        raise UnsupportedFormatError.new("Compact data.bin/mark assembly did not consume its complete planned grid")
      end

      slot_count.times do
        write_u64_le(marks, mark_cursor, total_compressed_size)
        write_u64_le(marks, mark_cursor + 8, 0_u64)
        mark_cursor += 16
      end
      write_u64_le(marks, mark_cursor, 0_u64)
      mark_cursor += 8
      unless mark_cursor == marks.size
        raise UnsupportedFormatError.new("Compact terminal mark record has an invalid width")
      end

      raw_digest = raw_hasher.finish
      raw_digest_bytes = Bytes.new(16)
      write_u64_le(raw_digest_bytes, 0, raw_digest[0])
      write_u64_le(raw_digest_bytes, 8, raw_digest[1])
      raw_hash_fold = CityHashV1.hash128_with_seed(raw_digest_bytes, 0_u64, 0_u64)

      # The output carrier snapshots the completed files, so charge that
      # operation-owned copy before its constructor allocates either buffer.
      transport_budget.reserve_result_bytes(total_file_size)
      CompactStaticPartFiles.new(
        data,
        marks,
        total_raw_size,
        raw_hash_fold,
        CityHashV1.file_hash(data),
        CityHashV1.file_hash(marks),
      )
    end

    private def self.validate_write_plan!(
      columns : Array(CompactStaticColumnInput),
      plan : CompactStaticWritePlan,
      limits : BinaryCodecLimits,
      column_count : Int32,
    ) : Nil
      callback_plans = plan.column_plans
      unless plan.same_limits?(limits) && plan.column_count == column_count &&
             callback_plans.size == column_count
        raise ArgumentError.new("Compact static write plan differs from the supplied column roster")
      end
      columns.each_with_index do |column, index|
        callback_plan = callback_plans[index]
        unless callback_plan.column_name == column.name && callback_plan.type == column.type &&
               callback_plan.profile == column.profile &&
               callback_plan.variant_discriminator_mode == plan.variant_discriminator_mode &&
               column.map_basic?
          raise ArgumentError.new("Compact static write plan is bound to different column inputs")
        end
      end
      expected_slots = case plan.mark_format
                       when CompactMarkFormat::Mrk3
                         column_count
                       when CompactMarkFormat::Mrk4
                         callback_plans.sum(&.callback_names.size)
                       else
                         raise UnsupportedFormatError.new("Compact static writer does not admit this mark format")
                       end
      unless plan.slot_count == expected_slots
        raise ArgumentError.new("Compact static write plan has an inconsistent mark-slot count")
      end
      nil
    end

    private def self.validate_mixed_write_plan!(
      columns : Array(CompactPartWriteInput),
      plan : CompactPartWritePlan,
      limits : BinaryCodecLimits,
      column_count : Int32,
    ) : Nil
      unless plan.same_limits?(limits) && plan.column_count == column_count &&
             plan.column_plans.size == column_count
        raise ArgumentError.new("Compact mixed write plan differs from the supplied column roster")
      end
      columns.each_with_index do |column, index|
        unless plan.same_input?(column, index)
          raise ArgumentError.new("Compact mixed write plan is bound to different column inputs")
        end
      end
      expected_slots = case plan.mark_format
                       when CompactMarkFormat::Mrk3
                         column_count
                       when CompactMarkFormat::Mrk4
                         plan.column_plans.sum(&.callback_names.size)
                       else
                         raise UnsupportedFormatError.new("Compact mixed writer does not admit this mark format")
                       end
      unless plan.slot_count == expected_slots
        raise ArgumentError.new("Compact mixed write plan has an inconsistent mark-slot count")
      end
      nil
    end

    private def self.validate_input_grid!(
      columns : Array(T),
      rows_per_mark : Array(UInt64),
    ) : Tuple(Int32, Int32, UInt64) forall T
      if columns.empty?
        raise ArgumentError.new("Compact static writer requires at least one column")
      end
      if rows_per_mark.empty? || rows_per_mark.size > Int32::MAX - 1
        raise ArgumentError.new("Compact static writer requires a bounded nonempty mark grid")
      end
      if columns.size > Int32::MAX
        raise UnsupportedFormatError.new("Compact column roster exceeds the supported slot domain")
      end

      row_total = 0_u64
      rows_per_mark.each do |rows|
        if rows == 0_u64 || rows > Int32::MAX.to_u64
          raise ArgumentError.new("Compact real mark rows must be positive Int32 values")
        end
        row_total = checked_add_u64(row_total, rows)
      end

      columns.each do |column|
        granules = column.granules
        unless granules.size == rows_per_mark.size
          raise ArgumentError.new("Compact column granules differ from the common mark grid")
        end
        granules.each_with_index do |granule, mark_index|
          unless granule.size.to_u64 == rows_per_mark[mark_index]
            raise ArgumentError.new("Compact column row count differs from its mark grid")
          end
        end
      end

      {rows_per_mark.size.to_i32, columns.size.to_i32, row_total}
    end

    private def self.preflight_mark_grid!(
      slot_count : Int32,
      mark_count : Int32,
      budget : CompressedStreamBudget,
    ) : Tuple(Int64, Int64, Int64, Int64)
      record_count = mark_count.to_i64 + 1_i64
      fields_per_record = checked_add_i64(checked_multiply_i64(slot_count.to_i64, 2_i64), 1_i64)
      mark_record_entries = checked_multiply_i64(record_count, fields_per_record)
      record_width = checked_add_i64(checked_multiply_i64(slot_count.to_i64, 16_i64), 8_i64)
      mark_size = checked_multiply_i64(record_count, record_width)
      if record_width > Int32::MAX.to_i64 || mark_size > Int32::MAX.to_i64
        raise UnsupportedFormatError.new("Compact mark grid exceeds the in-memory file domain")
      end
      if mark_size > budget.limits.max_mark_bytes
        raise UnsupportedFormatError.new("Compact mark grid exceeds the configured mark-size limit")
      end

      position_queries_per_mark = slot_count.to_i64 + 1_i64
      position_query_count = checked_multiply_i64(mark_count.to_i64, position_queries_per_mark)
      position_result_bytes = checked_multiply_i64(position_query_count, 16_i64)
      initial_record_count = checked_add_i64(mark_record_entries, position_query_count)
      initial_result_bytes = checked_add_i64(mark_size, position_result_bytes)

      budget.preflight_records(initial_record_count)
      budget.preflight_result_bytes(initial_result_bytes)
      budget.preflight_file_bytes(mark_size)
      {mark_size, mark_record_entries, position_query_count, position_result_bytes}
    end

    private def self.assemble_granule(
      columns : Array(CompactPartEncodedColumn),
      mark_index : Int32,
      expected_size : UInt64,
    ) : Bytes
      if expected_size > Int32::MAX.to_u64
        raise UnsupportedFormatError.new("Compact raw granule exceeds the in-memory domain")
      end
      raw = Bytes.new(expected_size.to_i)
      cursor = 0
      columns.each do |column|
        column.each_callback_event do |callback|
          bytes = column.callback_bytes(callback, mark_index)
          if bytes.size > raw.size - cursor
            raise UnsupportedFormatError.new("Compact callback exceeds its planned raw granule")
          end
          unless bytes.empty?
            bytes.copy_to(raw[cursor, bytes.size])
            cursor += bytes.size
          end
        end
      end
      unless cursor == raw.size
        raise UnsupportedFormatError.new("Compact callbacks do not fill their planned raw granule")
      end
      raw
    end

    private def self.frame_count(raw_size : UInt64, frame_bytes : Int) : Int64
      return 0_i64 if raw_size == 0_u64
      ((raw_size - 1_u64) // frame_bytes.to_u64 + 1_u64).to_i64
    end

    private def self.validate_frame_bytes!(frame_bytes : Int) : Nil
      if frame_bytes <= 0 || frame_bytes > Int32::MAX
        raise ArgumentError.new("Compact frame size must be a positive Int32 value")
      end
    end

    private def self.validate_codec_budget!(budget : BinaryCodecBudget, limits : BinaryCodecLimits) : Nil
      unless budget.writing? && same_codec_limits?(budget.limits, limits)
        raise ArgumentError.new("Compact static writer requires a compatible write codec budget")
      end
      nil
    end

    private def self.same_codec_limits?(left : BinaryCodecLimits, right : BinaryCodecLimits) : Bool
      left.max_depth == right.max_depth && left.max_nodes == right.max_nodes &&
        left.max_elements == right.max_elements && left.max_bytes == right.max_bytes
    end

    private def self.validate_transport_budget!(budget : CompressedStreamBudget) : Nil
      budget.ensure_direction(true)
      nil
    end

    private def self.write_u64_le(bytes : Bytes, offset : Int, value : UInt64) : Nil
      if offset < 0 || offset > bytes.size - 8
        raise UnsupportedFormatError.new("Compact mark field is outside the allocated output")
      end
      8.times do |index|
        byte = (value >> (index * 8)) & 0xff_u64
        bytes[offset + index] = byte.to_u8
      end
      nil
    end

    private def self.checked_add_u64(left : UInt64, right : UInt64) : UInt64
      if right > UInt64::MAX - left
        raise UnsupportedFormatError.new("Compact writer size arithmetic overflows UInt64")
      end
      left + right
    end

    private def self.checked_add_i64(left : Int64, right : Int64) : Int64
      if right < 0 || right > Int64::MAX - left
        raise UnsupportedFormatError.new("Compact writer size arithmetic overflows Int64")
      end
      left + right
    end

    private def self.checked_multiply_i64(left : Int64, right : Int64) : Int64
      if left < 0 || right < 0 || (left > 0 && right > Int64::MAX // left)
        raise UnsupportedFormatError.new("Compact writer size arithmetic overflows Int64")
      end
      left * right
    end
  end
end
