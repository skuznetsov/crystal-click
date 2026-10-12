module CrystalClick
  # Writes stateless BinaryBulk lanes as one granule-major Compact data.bin
  # tape plus the corresponding plain MRK3 slot grid. This owner deliberately
  # does not write metadata or publish files.
  class CompactStaticMRK3Writer
    private struct EncodedColumn
      getter plan : CompactStaticCallbackPlan
      getter streams : BinaryBulkStreams
      getter callback_roles : Array(String)

      def initialize(@plan : CompactStaticCallbackPlan, @streams : BinaryBulkStreams)
        @callback_roles = @plan.callback_roles
      end
    end

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
    ) : CompactStaticPartFiles
      validate_codec_budget!(codec_budget, limits)
      validate_transport_budget!(transport_budget)
      validate_frame_bytes!(frame_bytes)
      mark_count, column_count, row_count = validate_input_grid!(columns, rows_per_mark)

      plans = Array(CompactStaticCallbackPlan).new(column_count)
      names = Set(String).new
      columns.each do |column|
        if !names.add?(column.name)
          raise UnsupportedFormatError.new("Compact static column names must be unique")
        end
        plans << CompactStaticCallbackPlan.new(column, limits)
      end

      encoded = Array(EncodedColumn).new(column_count)
      columns.each_with_index do |column, index|
        plan = plans[index]
        granules = column.granules
        streams = BinaryBulkCodec.encode_with_budget(
          plan.type,
          granules,
          codec_budget,
          profile: plan.profile,
        )
        validate_stream_roster!(plan, streams, mark_count)
        encoded << EncodedColumn.new(plan, streams)
      end

      mark_size, mark_record_entries, position_query_count, position_result_bytes =
        preflight_mark_grid!(column_count, mark_count, transport_budget)

      layouts = Array(GranuleLayout).new(mark_count)
      total_raw_size = 0_u64
      total_compressed_size = 0_u64
      total_frame_count = 0_i64

      mark_count.times do |mark_index|
        position_queries = Array(UInt64).new(column_count + 1)
        segment_raw_size = 0_u64
        encoded.each do |column|
          # Each physical Compact slot starts before the first callback of
          # that column, even when every callback is empty in this granule.
          position_queries << segment_raw_size
          column.callback_roles.each do |role|
            stream = column.streams.stream(role)
            start, length = stream_extent(stream, mark_index)
            segment_raw_size = checked_add_u64(segment_raw_size, length)
            if segment_raw_size > Int32::MAX.to_u64
              raise UnsupportedFormatError.new("Compact granule exceeds the in-memory raw tape domain")
            end
          end
        end
        position_queries << segment_raw_size
        unless position_queries.size == column_count + 1
          raise UnsupportedFormatError.new("Compact granule query grid differs from its column roster")
        end

        positions = CompressedMarkWriter.plan_literal_positions(
          segment_raw_size.to_i64,
          position_queries,
          frame_bytes,
          transport_budget,
        )
        unless positions.size == column_count + 1
          raise UnsupportedFormatError.new("Compact granule position plan is incomplete")
        end
        compressed_size = positions[column_count][0]
        unless positions[column_count][1] == 0_u64
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
      # every future frame, MRK3 field, raw byte, file byte and result before
      # allocating the assembled tape or either final file.
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

        layout.positions.each_with_index do |position, column_index|
          next if column_index == column_count
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
        checked_multiply_i64(column_count.to_i64, 16_i64),
        8_i64,
      )
      expected_terminal_offset = mark_size - terminal_record_size
      unless data_cursor == data.size && compressed_base == total_compressed_size &&
             mark_cursor.to_i64 == expected_terminal_offset
        raise UnsupportedFormatError.new("Compact data.bin/MRK3 assembly did not consume its complete planned grid")
      end

      columns.size.times do
        write_u64_le(marks, mark_cursor, total_compressed_size)
        write_u64_le(marks, mark_cursor + 8, 0_u64)
        mark_cursor += 16
      end
      write_u64_le(marks, mark_cursor, 0_u64)
      mark_cursor += 8
      unless mark_cursor == marks.size
        raise UnsupportedFormatError.new("Compact terminal MRK3 record has an invalid width")
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

    private def self.validate_input_grid!(
      columns : Array(CompactStaticColumnInput),
      rows_per_mark : Array(UInt64),
    ) : Tuple(Int32, Int32, UInt64)
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

    private def self.validate_stream_roster!(
      plan : CompactStaticCallbackPlan,
      streams : BinaryBulkStreams,
      mark_count : Int32,
    ) : Nil
      unless streams.mark_count == mark_count
        raise UnsupportedFormatError.new("Compact BinaryBulk streams differ from the selected mark grid")
      end
      expected_roles = plan.callback_roles.sort!
      unless streams.roles == expected_roles
        raise UnsupportedFormatError.new("Compact BinaryBulk role roster differs from the ordered callback plan")
      end
      expected_roles.each do |role|
        stream = streams.stream(role)
        unless stream.mark_count == mark_count && stream.offset_count == mark_count + 1
          raise UnsupportedFormatError.new("Compact BinaryBulk lane has an incomplete offset grid")
        end
        previous = 0_u64
        (mark_count + 1).times do |offset_index|
          offset = stream.offset_at(offset_index)
          if offset < previous || offset > stream.byte_size.to_u64
            raise UnsupportedFormatError.new("Compact BinaryBulk lane offsets are not monotone")
          end
          previous = offset
        end
        unless previous == stream.byte_size.to_u64
          raise UnsupportedFormatError.new("Compact BinaryBulk lane terminal offset differs from its bytes")
        end
      end
      nil
    end

    private def self.preflight_mark_grid!(
      column_count : Int32,
      mark_count : Int32,
      budget : CompressedStreamBudget,
    ) : Tuple(Int64, Int64, Int64, Int64)
      record_count = mark_count.to_i64 + 1_i64
      fields_per_record = checked_add_i64(checked_multiply_i64(column_count.to_i64, 2_i64), 1_i64)
      mark_record_entries = checked_multiply_i64(record_count, fields_per_record)
      record_width = checked_add_i64(checked_multiply_i64(column_count.to_i64, 16_i64), 8_i64)
      mark_size = checked_multiply_i64(record_count, record_width)
      if record_width > Int32::MAX.to_i64 || mark_size > Int32::MAX.to_i64
        raise UnsupportedFormatError.new("Compact MRK3 grid exceeds the in-memory file domain")
      end
      if mark_size > budget.limits.max_mark_bytes
        raise UnsupportedFormatError.new("Compact MRK3 grid exceeds the configured mark-size limit")
      end

      position_queries_per_mark = column_count.to_i64 + 1_i64
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
      columns : Array(EncodedColumn),
      mark_index : Int32,
      expected_size : UInt64,
    ) : Bytes
      if expected_size > Int32::MAX.to_u64
        raise UnsupportedFormatError.new("Compact raw granule exceeds the in-memory domain")
      end
      raw = Bytes.new(expected_size.to_i)
      cursor = 0
      columns.each do |column|
        column.callback_roles.each do |role|
          stream = column.streams.stream(role)
          start, length = stream_extent(stream, mark_index)
          if length > (raw.size - cursor).to_u64
            raise UnsupportedFormatError.new("Compact callback exceeds its planned raw granule")
          end
          unless length == 0_u64
            slice = stream.borrowed_slice(start, length)
            slice.copy_to(raw[cursor, slice.size])
            cursor += slice.size
          end
        end
      end
      unless cursor == raw.size
        raise UnsupportedFormatError.new("Compact callbacks do not fill their planned raw granule")
      end
      raw
    end

    private def self.stream_extent(stream : BinaryBulkStream, mark_index : Int32) : Tuple(UInt64, UInt64)
      start = stream.offset_at(mark_index)
      finish = stream.offset_at(mark_index + 1)
      if finish < start || finish > stream.byte_size.to_u64
        raise UnsupportedFormatError.new("Compact callback extent is outside its BinaryBulk lane")
      end
      {start, finish - start}
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
        raise UnsupportedFormatError.new("Compact MRK3 field is outside the allocated output")
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
