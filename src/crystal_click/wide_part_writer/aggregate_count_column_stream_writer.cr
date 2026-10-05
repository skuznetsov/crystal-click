module CrystalClick
  module WidePartWriter
    # Writes the single raw AggregateFunction(count) state stream. Descriptor
    # identity is carried by the part metadata; this leaf lane contains only
    # canonical VarUInt state bytes, with one independently framed mark.
    private class AggregateCountColumnStreamWriter
      def self.write(
        stage : String,
        column : String,
        values : Slice(BinaryValue),
        rows_per_mark : Int32,
      ) : Array(ChecksumRecord)
        base_name = StreamName.hash(column)
        data_name = "#{base_name}.bin"
        marks_name = "#{base_name}.mrk2"
        data_path = File.join(stage, data_name)
        marks_path = File.join(stage, marks_name)
        data_hash = CityHashV1::FileHasher.new
        raw_hash = CityHashV1::FileHasher.new
        mark_bytes = IO::Memory.new
        data_size = 0_u64
        raw_size_total = 0_u64
        start_row = 0

        File.open(data_path, "wb") do |data_file|
          while start_row < values.size
            rows = {rows_per_mark, values.size - start_row}.min
            raw = IO::Memory.new
            rows.times do |offset|
              BinaryAggregateCountStateCodec.write_lane(values[start_row + offset].count_state) do |byte|
                raw.write_byte(byte)
              end
            end
            raw_bytes = raw.to_slice
            raise ArgumentError.new("AggregateFunction(count) mark is empty") if raw_bytes.empty?

            StreamEncoding.write_uint64_le(mark_bytes, data_size)
            StreamEncoding.write_uint64_le(mark_bytes, 0_u64)
            StreamEncoding.write_uint64_le(mark_bytes, rows.to_u64)

            frame = StreamEncoding.encode_lz4_frame(raw_bytes)
            raise ArgumentError.new("AggregateFunction(count) data exceeds reader limit") if frame.size.to_i64 > WidePart::MAX_DATA_FILE_BYTES - data_size.to_i64
            data_file.write(frame)
            data_hash.update(frame)
            raw_hash.update(raw_bytes)
            data_size += frame.size.to_u64
            raw_size_total += raw_bytes.size.to_u64
            start_row += rows
          end
        end

        StreamEncoding.write_uint64_le(mark_bytes, data_size)
        StreamEncoding.write_uint64_le(mark_bytes, 0_u64)
        StreamEncoding.write_uint64_le(mark_bytes, 0_u64)
        marks = mark_bytes.to_slice
        raise ArgumentError.new("AggregateFunction(count) marks exceed reader limit") if marks.size.to_i64 > WidePart::MAX_MARK_FILE_BYTES
        File.write(marks_path, marks)

        [
          ChecksumRecord.new(data_name, data_size, data_hash.finish, true, raw_size_total, raw_hash.finish),
          ChecksumRecord.new(marks_name, marks.size.to_u64, CityHashV1.file_hash(marks), false),
        ]
      end
    end
  end
end
