module CrystalClick
  module WidePartWriter
    private class LeafStreamWriter
      def self.write_uint64_stream(
        stage : String,
        column : String,
        values : Slice(UInt64),
        rows_per_mark : Int32,
      ) : Array(ChecksumRecord)
        base_name = StreamName.hash(column)
        data_name = "#{base_name}.bin"
        marks_name = "#{base_name}.mrk2"
        data_path = File.join(stage, data_name)
        mark_path = File.join(stage, marks_name)
        data_hash = CityHashV1::FileHasher.new
        raw_hash = CityHashV1::FileHasher.new
        mark_bytes = IO::Memory.new
        data_size = 0_u64
        start_row = 0

        File.open(data_path, "wb") do |data_file|
          while start_row < values.size
            rows = {rows_per_mark, values.size - start_row}.min
            raw = Bytes.new(rows * 8)
            rows.times do |row|
              StreamEncoding.write_uint64_le(raw, row * 8, values[start_row + row])
            end

            StreamEncoding.write_uint64_le(mark_bytes, data_size)
            StreamEncoding.write_uint64_le(mark_bytes, 0_u64)
            StreamEncoding.write_uint64_le(mark_bytes, rows.to_u64)

            frame = StreamEncoding.encode_lz4_frame(raw)
            raise ArgumentError.new("data stream exceeds reader limit") if data_size > MAX_DATA_FILE_BYTES.to_u64 - frame.size.to_u64
            data_file.write(frame)
            data_hash.update(frame)
            raw_hash.update(raw)
            data_size += frame.size.to_u64
            start_row += rows
          end
        end

        StreamEncoding.write_uint64_le(mark_bytes, data_size)
        StreamEncoding.write_uint64_le(mark_bytes, 0_u64)
        StreamEncoding.write_uint64_le(mark_bytes, 0_u64)
        marks = mark_bytes.to_slice
        raise ArgumentError.new("mark stream exceeds reader limit") if marks.size.to_i64 > MAX_MARK_FILE_BYTES
        File.write(mark_path, marks)
        mark_hash = CityHashV1.file_hash(marks)

        [
          ChecksumRecord.new(data_name, data_size, data_hash.finish, true, values.size.to_u64 * 8_u64, raw_hash.finish),
          ChecksumRecord.new(marks_name, marks.size.to_u64, mark_hash, false),
        ]
      end

      def self.write_string_streams(
        stage : String,
        column : String,
        values : Slice(T),
        rows_per_mark : Int32,
      ) : Array(ChecksumRecord) forall T
        size_base = StreamName.hash("#{column}.size")
        value_base = StreamName.hash(column)
        size_data_name = "#{size_base}.bin"
        size_marks_name = "#{size_base}.mrk2"
        value_data_name = "#{value_base}.bin"
        value_marks_name = "#{value_base}.mrk2"
        size_data_path = File.join(stage, size_data_name)
        size_mark_path = File.join(stage, size_marks_name)
        value_data_path = File.join(stage, value_data_name)
        value_mark_path = File.join(stage, value_marks_name)
        size_data_hash = CityHashV1::FileHasher.new
        size_raw_hash = CityHashV1::FileHasher.new
        value_data_hash = CityHashV1::FileHasher.new
        value_raw_hash = CityHashV1::FileHasher.new
        size_mark_bytes = IO::Memory.new
        value_mark_bytes = IO::Memory.new
        size_data_size = 0_u64
        value_data_size = 0_u64
        total_raw_size = 0_u64
        start_row = 0

        File.open(size_data_path, "wb") do |size_data_file|
          File.open(value_data_path, "wb") do |value_data_file|
            while start_row < values.size
              rows = {rows_per_mark, values.size - start_row}.min
              sizes_raw = Bytes.new(rows * 8)
              string_raw_size = 0_i64
              rows.times do |row|
                value_size = typed_string_value(values[start_row + row]).bytesize.to_i64
                if value_size > MAX_FRAME_RAW_BYTES.to_i64 - string_raw_size
                  raise ArgumentError.new("String payload granule exceeds decompressed frame limit")
                end
                string_raw_size += value_size
                StreamEncoding.write_uint64_le(sizes_raw, row * 8, value_size.to_u64)
              end
              raise ArgumentError.new("String payload exceeds reader limit") if string_raw_size.to_u64 > MAX_DATA_FILE_BYTES.to_u64 - total_raw_size

              string_raw = Bytes.new(string_raw_size.to_i)
              string_offset = 0
              rows.times do |row|
                value = typed_string_value(values[start_row + row])
                value_bytes = value.to_slice
                if value_bytes.size > 0
                  value_bytes.copy_to(string_raw[string_offset, value_bytes.size])
                  string_offset += value_bytes.size
                end
              end

              StreamEncoding.write_uint64_le(size_mark_bytes, size_data_size)
              StreamEncoding.write_uint64_le(size_mark_bytes, 0_u64)
              StreamEncoding.write_uint64_le(size_mark_bytes, rows.to_u64)
              StreamEncoding.write_uint64_le(value_mark_bytes, value_data_size)
              StreamEncoding.write_uint64_le(value_mark_bytes, 0_u64)
              StreamEncoding.write_uint64_le(value_mark_bytes, rows.to_u64)

              size_frame = StreamEncoding.encode_lz4_frame(sizes_raw)
              raise ArgumentError.new("String size stream exceeds reader limit") if size_data_size > MAX_DATA_FILE_BYTES.to_u64 - size_frame.size.to_u64
              size_data_file.write(size_frame)
              size_data_hash.update(size_frame)
              size_raw_hash.update(sizes_raw)
              size_data_size += size_frame.size.to_u64

              unless string_raw.empty?
                string_frame = StreamEncoding.encode_lz4_frame(string_raw)
                raise ArgumentError.new("String data stream exceeds reader limit") if value_data_size > MAX_DATA_FILE_BYTES.to_u64 - string_frame.size.to_u64
                value_data_file.write(string_frame)
                value_data_hash.update(string_frame)
                value_data_size += string_frame.size.to_u64
              end
              value_raw_hash.update(string_raw)
              total_raw_size += string_raw.size.to_u64
              start_row += rows
            end
          end
        end

        StreamEncoding.write_uint64_le(size_mark_bytes, size_data_size)
        StreamEncoding.write_uint64_le(size_mark_bytes, 0_u64)
        StreamEncoding.write_uint64_le(size_mark_bytes, 0_u64)
        StreamEncoding.write_uint64_le(value_mark_bytes, value_data_size)
        StreamEncoding.write_uint64_le(value_mark_bytes, 0_u64)
        StreamEncoding.write_uint64_le(value_mark_bytes, 0_u64)
        size_marks = size_mark_bytes.to_slice
        value_marks = value_mark_bytes.to_slice
        raise ArgumentError.new("mark stream exceeds reader limit") if size_marks.size.to_i64 > MAX_MARK_FILE_BYTES
        raise ArgumentError.new("mark stream exceeds reader limit") if value_marks.size.to_i64 > MAX_MARK_FILE_BYTES
        File.write(size_mark_path, size_marks)
        File.write(value_mark_path, value_marks)

        [
          ChecksumRecord.new(size_data_name, size_data_size, size_data_hash.finish, true, values.size.to_u64 * 8_u64, size_raw_hash.finish),
          ChecksumRecord.new(size_marks_name, size_marks.size.to_u64, CityHashV1.file_hash(size_marks), false),
          ChecksumRecord.new(value_data_name, value_data_size, value_data_hash.finish, true, total_raw_size, value_raw_hash.finish),
          ChecksumRecord.new(value_marks_name, value_marks.size.to_u64, CityHashV1.file_hash(value_marks), false),
        ]
      end

      def self.typed_string_value(value : T) : String forall T
        {% if T.union_types.size == 2 && T.union_types.includes?(String) && T.union_types.includes?(Nil) %}
          value || ""
        {% elsif T == String %}
          value
        {% else %}
          raise UnsupportedFormatError.new("String stream requires String or Nullable(String) values")
        {% end %}
      end
    end
  end
end
