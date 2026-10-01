module CrystalClick
  class WidePart
    # Owns compositional Tuple range orchestration. WidePart supplies only the
    # selected physical stream/frame operations and its existing scalar codecs.
    private class TupleReader
      alias RangeRows = Proc(String, Int32, Int32, UInt64)
      alias MarkRows = Proc(String, Int32, UInt64)
      alias ReadRange = Proc(String, Int32, Int32, Int32, Int32, UInt64, Bytes)
      alias ValidateRange = Proc(String, Int32, Int32, Int32, Int32, UInt64, Nil)
      alias DecodeUInt64 = Proc(Bytes, Int32, UInt64)
      alias LogicalRows = Proc(Int32, Int32, UInt64)
      alias CombinedCharge = Proc(UInt64, UInt64, UInt64, UInt64?)

      @plan : WideTupleTypePlan
      @column : String
      @range_rows : RangeRows
      @mark_rows : MarkRows
      @read_range : ReadRange
      @validate_range : ValidateRange
      @decode_uint64 : DecodeUInt64
      @leaf_decoder : TupleLeafDecoder
      @logical_rows : LogicalRows?
      @combined_charge : CombinedCharge?

      def initialize(
        @plan : WideTupleTypePlan,
        @column : String,
        @range_rows : RangeRows,
        @mark_rows : MarkRows,
        @read_range : ReadRange,
        @validate_range : ValidateRange,
        @decode_uint64 : DecodeUInt64,
        @leaf_decoder : TupleLeafDecoder,
        @logical_rows : LogicalRows? = nil,
        @combined_charge : CombinedCharge? = nil,
      )
      end

      def read(
        first_mark : Int32,
        mark_count : Int32,
        max_materialized_bytes : UInt64,
      ) : WideTupleColumnData
        validate_budget(max_materialized_bytes)
        materialize(first_mark, mark_count, max_materialized_bytes)
      end

      def each(
        first_mark : Int32,
        mark_count : Int32,
        max_materialized_bytes : UInt64,
        & : WideTupleColumnData, Int32 -> Nil
      ) : Nil
        validate_budget(max_materialized_bytes)
        validate_selected_schedule(first_mark, mark_count)
        mark_count.times do |offset|
          mark_index = first_mark + offset
          mark = materialize(mark_index, 1, max_materialized_bytes)
          yield mark, mark_index.to_i32
          nil
        end
        nil
      end

      # Reuse the normal size-stream preflight and plan charge calculation
      # without constructing the owned leaf arrays.
      def materialization_charge(
        first_mark : Int32,
        mark_count : Int32,
        max_materialized_bytes : UInt64,
      ) : UInt64
        validate_budget(max_materialized_bytes)
        _rows, _string_payload_bytes, charge = preflight_range(
          first_mark,
          mark_count,
          max_materialized_bytes
        )
        charge
      end

      private def validate_budget(max_materialized_bytes : UInt64) : Nil
        if max_materialized_bytes > WideTupleTypePlan::MAX_MATERIALIZED_BYTES
          raise ArgumentError.new("Tuple materialization budget cannot exceed 64 MiB")
        end
      end

      # Validate bounds and every selected stream's mark-row schedule before
      # any payload callback or result allocation. Payload bytes remain lazy
      # per mark in #each.
      private def validate_selected_schedule(first_mark : Int32, mark_count : Int32) : UInt64
        streams = @plan.physical_streams(@column)
        reference_stream = streams.first? || raise(CorruptPartError.new("Tuple has no physical leaf streams"))
        rows = @range_rows.call(reference_stream, first_mark, mark_count)
        streams.each do |stream_name|
          stream_rows = @range_rows.call(stream_name, first_mark, mark_count)
          unless stream_rows == rows
            raise tuple_row_mismatch(stream_name)
          end
        end

        mark_count.times do |offset|
          mark_index = first_mark + offset
          mark_rows = @mark_rows.call(reference_stream, mark_index)
          streams.each do |stream_name|
            unless @mark_rows.call(stream_name, mark_index) == mark_rows
              raise tuple_row_mismatch(stream_name)
            end
          end
        end
        rows
      end

      private def tuple_row_mismatch(stream_name : String) : CorruptPartError
        if @plan.raw_string_stream?(@column, stream_name)
          CorruptPartError.new("Tuple(String) substream mark rows differ")
        else
          CorruptPartError.new("Tuple substream mark rows differ")
        end
      end

      private def preflight_range(
        first_mark : Int32,
        mark_count : Int32,
        max_materialized_bytes : UInt64,
      ) : {UInt64, UInt64, UInt64}
        # Physical .mrk2 row counts remain the outer table-row axis for
        # Array(Tuple) child streams. Logical payload cardinality may instead
        # be the flattened element axis supplied by the schedule.
        outer_rows = validate_selected_schedule(first_mark, mark_count)
        rows = @logical_rows.try(&.call(first_mark, mark_count)) || outer_rows
        minimum_charge = checked_materialization_charge(outer_rows, rows, 0_u64) ||
                         raise(CorruptPartError.new("Tuple materialization charge overflows"))
        if minimum_charge > max_materialized_bytes
          raise CorruptPartError.new("Tuple materialization charge exceeds per-range limit")
        end

        string_payload_bytes = 0_u64
        validation_requests = [] of Tuple(String, Int32, Int32)
        @plan.fields.each do |field|
          leaf_stream = @plan.leaf_stream_name(@column, field)
          leaf_type = field.leaf_type
          if leaf_type.nullable?
            null_stream = "#{leaf_stream}.null"
            validation_requests << {null_stream, checked_byte_count(rows, 1), 1}
          end
          if leaf_type.base_type_name == "String"
            size_stream = "#{leaf_stream}.size"
            encoded_sizes = @read_range.call(
              size_stream,
              first_mark,
              mark_count,
              checked_byte_count(rows, 8),
              8,
              rows
            )
            field_payload_bytes = string_payload_byte_count(encoded_sizes)
            if field_payload_bytes > WidePart::MAX_ARRAY_MARK_BYTES.to_u64 - string_payload_bytes
              raise CorruptPartError.new("Tuple materialization charge exceeds per-range limit")
            end
            string_payload_bytes += field_payload_bytes
            validation_requests << {leaf_stream, field_payload_bytes.to_i32, 1}
          else
            width = @plan.stream_width(@column, leaf_stream) ||
                    raise(CorruptPartError.new("Tuple leaf stream has no fixed width"))
            expected_bytes = checked_byte_count(rows, width)
            if parameterized_type = field.parameterized_type
              if parameterized_type.is_a?(WideTupleFixedStringType)
                field_payload_bytes = expected_bytes.to_u64
                if field_payload_bytes > WidePart::MAX_ARRAY_MARK_BYTES.to_u64 - string_payload_bytes
                  raise CorruptPartError.new("Tuple materialization charge exceeds per-range limit")
                end
                string_payload_bytes += field_payload_bytes
              end
            end
            validation_requests << {leaf_stream, expected_bytes, width}
          end
        end

        charge = checked_materialization_charge(outer_rows, rows, string_payload_bytes) ||
                 raise(CorruptPartError.new("Tuple materialization charge overflows"))
        if charge > max_materialized_bytes
          raise CorruptPartError.new("Tuple materialization charge exceeds per-range limit")
        end

        # Physical frame validation decompresses payload frames. Keep it after
        # aggregate budget acceptance so an over-budget range is rejected
        # before any selected payload is decoded.
        validation_requests.each do |stream_name, expected_bytes, width|
          @validate_range.call(stream_name, first_mark, mark_count, expected_bytes, width, rows)
        end
        {rows, string_payload_bytes, charge}
      end

      private def checked_materialization_charge(
        outer_rows : UInt64,
        elements : UInt64,
        string_payload_bytes : UInt64,
      ) : UInt64?
        if combined_charge = @combined_charge
          combined_charge.call(outer_rows, elements, string_payload_bytes)
        else
          @plan.materialization_charge(elements, string_payload_bytes)
        end
      end

      private def string_payload_byte_count(encoded_sizes : Bytes) : UInt64
        raise CorruptPartError.new("Tuple(String) size bytes are not UInt64-aligned") unless encoded_sizes.size % 8 == 0
        total = 0_u64
        offset = 0_i32
        while offset < encoded_sizes.size
          size = @decode_uint64.call(encoded_sizes, offset)
          if size > WidePart::MAX_DATA_FILE_BYTES.to_u64 - total
            raise CorruptPartError.new("String size exceeds selected data limit")
          end
          if size > WidePart::MAX_ARRAY_MARK_BYTES.to_u64 - total
            raise CorruptPartError.new("String read range exceeds materialization limit")
          end
          total += size
          offset += 8
        end
        total
      end

      private def materialize(
        first_mark : Int32,
        mark_count : Int32,
        max_materialized_bytes : UInt64 = WideTupleTypePlan::MAX_MATERIALIZED_BYTES,
      ) : WideTupleColumnData
        rows, _string_payload_bytes, _charge = preflight_range(first_mark, mark_count, max_materialized_bytes)

        # Validate every selected mask before invoking any scalar payload
        # decoder. #each materializes one mark at a time, so a later corrupt
        # mark cannot make us claim eager validation of the whole selection.
        null_maps = Array(ScalarNullMap?).new(@plan.fields.size, nil)
        @plan.fields.each_with_index do |field, field_index|
          leaf_type = field.leaf_type
          next unless leaf_type.nullable?
          leaf_stream = "#{@plan.leaf_stream_name(@column, field)}.null"
          encoded = @read_range.call(
            leaf_stream,
            first_mark,
            mark_count,
            checked_byte_count(rows, 1),
            1,
            rows
          )
          begin
            null_maps[field_index] = ScalarNullMap.new(encoded, rows)
          rescue ex : ArgumentError
            raise CorruptPartError.new("Tuple Nullable null map is invalid")
          end
        end

        columns = Array(WideTupleLeafColumn).new(@plan.fields.size)
        @plan.fields.each_with_index do |field, field_index|
          leaf_stream = @plan.leaf_stream_name(@column, field)
          leaf_type = field.leaf_type
          if leaf_type.nullable? && leaf_type.base_type_name == "String"
            null_map = null_maps[field_index] || raise(CorruptPartError.new("Tuple Nullable null map is missing"))
            size_stream = "#{leaf_stream}.size"
            encoded_sizes = @read_range.call(
              size_stream,
              first_mark,
              mark_count,
              checked_byte_count(rows, 8),
              8,
              rows
            )
            sizes = decode_sizes(encoded_sizes, rows)
            payload_bytes = string_payload_byte_count(encoded_sizes)
            raw_bytes = @read_range.call(leaf_stream, first_mark, mark_count, payload_bytes.to_i32, 1, rows)
            values = Array(String).new(rows.to_i)
            StringPayloadDecoder.each(sizes, raw_bytes, "Tuple(Nullable(String))") do |string_value, _index|
              values << string_value
              nil
            end
            columns << WideTupleLeafColumn.new(field.name, leaf_type, values, null_map)
          elsif leaf_type.nullable?
            null_map = null_maps[field_index] || raise(CorruptPartError.new("Tuple Nullable null map is missing"))
            width = @plan.stream_width(@column, leaf_stream) ||
                    raise(CorruptPartError.new("Nullable Tuple leaf stream has no fixed width"))
            encoded = @read_range.call(
              leaf_stream,
              first_mark,
              mark_count,
              checked_byte_count(rows, width),
              width,
              rows
            )
            columns << @leaf_decoder.decode_nullable(field, encoded, null_map, rows, width)
          elsif leaf_type.base_type_name == "String"
            size_stream = "#{leaf_stream}.size"
            encoded_sizes = @read_range.call(
              size_stream,
              first_mark,
              mark_count,
              checked_byte_count(rows, 8),
              8,
              rows
            )
            sizes = decode_sizes(encoded_sizes, rows)
            payload_bytes = string_payload_byte_count(encoded_sizes)
            raw_bytes = @read_range.call(leaf_stream, first_mark, mark_count, payload_bytes.to_i32, 1, rows)
            values = Array(String).new(rows.to_i)
            StringPayloadDecoder.each(sizes, raw_bytes, "Tuple(String)") do |string_value, _index|
              values << string_value
              nil
            end
            columns << WideTupleLeafColumn.new(field.name, values)
          else
            width = @plan.stream_width(@column, leaf_stream) ||
                    raise(CorruptPartError.new("Tuple leaf stream has no fixed width"))
            encoded = @read_range.call(
              leaf_stream,
              first_mark,
              mark_count,
              checked_byte_count(rows, width),
              width,
              rows
            )
            columns << @leaf_decoder.decode_fixed(field, encoded, rows, width)
          end
        end
        WideTupleColumnData.new(@plan, columns)
      end

      private def decode_sizes(encoded_sizes : Bytes, rows : UInt64) : Array(UInt64)
        expected_size = checked_byte_count(rows, 8)
        raise CorruptPartError.new("Tuple(String) size count does not match rows") unless encoded_sizes.size == expected_size
        sizes = Array(UInt64).new(rows.to_i)
        offset = 0_i32
        while offset < encoded_sizes.size
          sizes << @decode_uint64.call(encoded_sizes, offset)
          offset += 8
        end
        sizes
      end

      private def checked_byte_count(rows : UInt64, width : Int32) : Int32
        if width <= 0 || rows > Int32::MAX.to_u64 // width.to_u64
          raise CorruptPartError.new("Tuple row byte count exceeds materialization limit")
        end
        (rows * width.to_u64).to_i32
      end
    end
  end
end
