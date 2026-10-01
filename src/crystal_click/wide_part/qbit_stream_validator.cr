module CrystalClick
  # Shared low-level validation for QBit physical mark schedules. Kept below
  # table consumers so the storage reader has no dependency on table adapters.
  class QBitStreamValidator
    alias ReadStream = Proc(String, Int32, Int32, Int32?, Tuple(UInt64, Bytes?))

    def self.selected_row_count(
      plan : QBitColumnType,
      column : String,
      first_mark : Int32,
      mark_count : Int32,
      read_stream : ReadStream,
    ) : UInt64
      streams = plan.physical_streams(column)
      raise CorruptPartError.new("QBit has no physical plane streams") if streams.empty?
      rows = nil.as(UInt64?)
      streams.each do |stream_name, _width|
        stream_rows, payload = read_stream.call(stream_name, first_mark, mark_count, nil)
        raise CorruptPartError.new("QBit row preflight unexpectedly read payload") if payload
        if expected_rows = rows
          raise CorruptPartError.new("QBit substream mark rows differ") unless stream_rows == expected_rows
        else
          rows = stream_rows
        end
      end
      rows || raise(CorruptPartError.new("QBit mark range has no row schedule"))
    end

    def self.validate_null_map!(bytes : Bytes) : Nil
      bytes.each do |value|
        raise CorruptPartError.new("Nullable(QBit) null map contains a value outside 0/1") unless value == 0_u8 || value == 1_u8
      end
      nil
    end
  end
end
