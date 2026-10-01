module CrystalClick
  class WidePart
    # QBit range orchestration is separate from the shared stream/frame reader.
    # The owning WidePart facade supplies metadata-only row checks and the
    # selected stream byte operation through one narrow callback.
    private class QBitReader
      alias ReadStream = Proc(String, Int32, Int32, Int32?, Tuple(UInt64, Bytes?))

      @plan : QBitColumnType
      @column : String
      @read_stream : ReadStream

      def initialize(@plan : QBitColumnType, @column : String, @read_stream : ReadStream)
      end

      def read_scalar(first_mark : Int32, mark_count : Int32, max_materialized_bytes : UInt64) : Array(QBitValue)
        raise UnsupportedFormatError.new("scalar QBit accessor requires an exact non-nullable QBit column") if @plan.nullable
        rows, planes, _null_map = read_components(first_mark, mark_count, max_materialized_bytes)
        materialize_dense_rows(rows, planes)
      end

      def read_nullable(first_mark : Int32, mark_count : Int32, max_materialized_bytes : UInt64) : Array(QBitValue?)
        raise UnsupportedFormatError.new("nullable QBit accessor requires exact Nullable(QBit) metadata") unless @plan.nullable
        rows, planes, null_map = read_components(first_mark, mark_count, max_materialized_bytes)
        nullable_rows(rows, planes, null_map || raise(CorruptPartError.new("Nullable(QBit) null map was not read")))
      end

      def read_dense(first_mark : Int32, mark_count : Int32, max_materialized_bytes : UInt64) : Array(QBitValue)
        rows, planes, _null_map = read_components(first_mark, mark_count, max_materialized_bytes)
        materialize_dense_rows(rows, planes)
      end

      # Metadata-only charge used by table scans before they allocate any
      # selected mark values. This deliberately validates all selected stream
      # schedules without asking the callback to return payload bytes.
      def materialization_charge(first_mark : Int32, mark_count : Int32) : UInt64
        selected_rows = preflight_row_count(first_mark, mark_count)
        begin
          @plan.materialization_charge(selected_rows)
        rescue ex : ArgumentError
          raise CorruptPartError.new("QBit selected range exceeds materialization limit")
        end
      end

      private def read_components(
        first_mark : Int32,
        mark_count : Int32,
        max_materialized_bytes : UInt64,
      ) : {UInt64, Array(Bytes), Bytes?}
        if max_materialized_bytes > QBitColumnType::MAX_MATERIALIZED_BYTES
          raise ArgumentError.new("QBit materialization budget cannot exceed 64 MiB")
        end

        streams = @plan.physical_streams(@column)
        raise CorruptPartError.new("QBit has no physical plane streams") if streams.empty?

        selected_rows = preflight_row_count(first_mark, mark_count)

        charge = begin
          @plan.materialization_charge(selected_rows)
        rescue ex : ArgumentError
          raise CorruptPartError.new("QBit selected range exceeds materialization limit")
        end
        if charge > max_materialized_bytes
          raise CorruptPartError.new("QBit selected range exceeds materialization limit")
        end

        # The null map is read and validated even when callers request dense
        # placeholder rows. This keeps its physical contract independent from
        # the nullable presentation API.
        null_map = if @plan.nullable
                     read_stream_bytes("#{@column}.null", first_mark, mark_count, 1, selected_rows)
                   end

        planes = Array(Bytes).new(@plan.value_type.plane_count)
        1.upto(@plan.value_type.plane_count) do |plane_index|
          stream_name = "#{@column}%2E#{plane_index}"
          planes << read_stream_bytes(stream_name, first_mark, mark_count, @plan.value_type.plane_width, selected_rows)
        end
        {selected_rows, planes, null_map}
      end

      private def preflight_row_count(first_mark : Int32, mark_count : Int32) : UInt64
        QBitStreamValidator.selected_row_count(@plan, @column, first_mark, mark_count, @read_stream)
      end

      private def read_stream_bytes(
        stream_name : String,
        first_mark : Int32,
        mark_count : Int32,
        width : Int32,
        expected_rows : UInt64,
      ) : Bytes
        rows, payload = @read_stream.call(stream_name, first_mark, mark_count, width)
        raise CorruptPartError.new("QBit substream mark rows differ") unless rows == expected_rows
        bytes = payload || raise(CorruptPartError.new("QBit selected payload was not read"))
        expected_size = checked_byte_count(expected_rows, width)
        raise CorruptPartError.new("QBit selected byte count mismatch") unless bytes.size == expected_size
        if stream_name == "#{@column}.null"
          QBitStreamValidator.validate_null_map!(bytes)
        end
        bytes
      end

      private def materialize_dense_rows(rows : UInt64, planes : Array(Bytes)) : Array(QBitValue)
        count = rows.to_i
        result = Array(QBitValue).new(count)
        row = 0
        while row < count
          result << decode_row(planes, row)
          row += 1
        end
        result
      end

      private def nullable_rows(rows : UInt64, planes : Array(Bytes), null_map : Bytes) : Array(QBitValue?)
        count = rows.to_i
        raise CorruptPartError.new("Nullable(QBit) null map row count mismatch") unless null_map.size == count
        result = Array(QBitValue?).new(count)
        row = 0
        while row < count
          if null_map[row] == 1_u8
            result << nil
          else
            result << decode_row(planes, row)
          end
          row += 1
        end
        result
      end

      private def decode_row(planes : Array(Bytes), row : Int32) : QBitValue
        type = @plan.value_type
        row_offset = row * type.plane_width
        QBitPlaneCodec.decode_row(type) do |plane_index, byte_index|
          planes[plane_index][row_offset + byte_index]
        end
      end

      private def checked_byte_count(rows : UInt64, width : Int32) : Int32
        byte_width = width.to_u64
        if byte_width == 0_u64 || rows > Int32::MAX.to_u64 // byte_width
          raise CorruptPartError.new("QBit selected row byte count exceeds reader limit")
        end
        (rows * byte_width).to_i32
      end
    end
  end
end
