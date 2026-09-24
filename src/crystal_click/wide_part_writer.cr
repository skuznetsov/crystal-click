module CrystalClick
  # Bounded writer for the initial two-column UInt64 Wide-part slice.
  #
  # Each data granule is one literal-only LZ4 block in a ClickHouse compressed
  # frame. The implementation intentionally accepts less than the theoretical
  # format maximum per granule so its output stays within this repository's
  # table-reader materialization bound as well as the frame decoder's bounds.
  module WidePartWriter
    MAX_ROWS_PER_MARK       = 65_536
    MAX_MARKS               = WidePartTable::MAX_MARKS_PER_READER
    MAX_COLUMN_NAME_BYTES   = 128
    MAX_FRAME_RAW_BYTES     = WidePart::MAX_FRAME_DECOMPRESSED_BYTES
    MAX_FRAME_COMPRESSED    = WidePart::MAX_FRAME_COMPRESSED_BYTES
    MAX_DATA_FILE_BYTES     = WidePart::MAX_DATA_FILE_BYTES
    MAX_MARK_FILE_BYTES     = WidePart::MAX_MARK_FILE_BYTES
    MAX_PRIMARY_INDEX_BYTES = PrimaryKeyIndex::MAX_INDEX_FILE_BYTES
    RENAME_EXCL             = 0x0000_0004_u32

    private struct ChecksumRecord
      getter name : String
      getter physical_size : UInt64
      getter file_hash : {UInt64, UInt64}
      getter compressed : Bool
      getter uncompressed_size : UInt64?
      getter uncompressed_hash : {UInt64, UInt64}?

      def initialize(
        @name : String,
        @physical_size : UInt64,
        @file_hash : {UInt64, UInt64},
        @compressed : Bool,
        @uncompressed_size : UInt64? = nil,
        @uncompressed_hash : {UInt64, UInt64}? = nil,
      )
      end
    end

    {% if flag?(:darwin) %}
      @[Link("c")]
      lib LibWidePartWriterAtomicPublish
        fun renamex_np(old_path : UInt8*, new_path : UInt8*, flags : UInt32) : Int32
      end
    {% end %}

    # Write one immutable part at `destination`. The parent directory must
    # already exist. Publication is a same-filesystem atomic exclusive rename;
    # an existing path is never replaced.
    def self.write_uint64_pair(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(UInt64),
      rows_per_mark : Int32 = 8192,
    ) : String
      validate_inputs(destination, key_name, keys, value_name, values, rows_per_mark)

      target = File.expand_path(destination)
      parent = File.dirname(target)
      raise ArgumentError.new("destination parent must exist") unless Dir.exists?(parent)
      raise ArgumentError.new("destination must not already exist") if File.exists?(target) || File.symlink?(target)

      stage = create_stage(parent)
      begin
        records = [] of ChecksumRecord
        records.concat(write_uint64_stream(stage, key_name, keys, rows_per_mark))
        records.concat(write_uint64_stream(stage, value_name, values, rows_per_mark))
        records << write_primary_index(stage, keys, rows_per_mark)
        records << write_checksummed_file(stage, "count.txt", keys.size.to_s)
        write_plain_metadata(stage, "columns.txt", columns_metadata(key_name, value_name))
        write_plain_metadata(stage, "default_compression_codec.txt", "CODEC(LZ4)")
        write_plain_metadata(stage, "metadata_version.txt", "0")
        write_plain_metadata(stage, "columns_substreams.txt", substreams_metadata(key_name, value_name))
        write_checksums(stage, records)
        validate_staged_part(stage, key_name, value_name, keys, values, rows_per_mark)
        publish_exclusively(stage, target)
        target
      ensure
        FileUtils.rm_rf(stage) if Dir.exists?(stage)
      end
    end

    private def self.validate_inputs(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      values : Slice(UInt64),
      rows_per_mark : Int32,
    ) : Nil
      raise ArgumentError.new("destination must not be empty") if destination.empty?
      validate_column_name(key_name)
      validate_column_name(value_name)
      raise ArgumentError.new("column names must be distinct") if key_name == value_name
      raise ArgumentError.new("columns must contain the same nonzero row count") if keys.empty? || keys.size != values.size
      raise ArgumentError.new("row count exceeds writer limit") if keys.size.to_u64 > WidePart::MAX_ROWS
      raise ArgumentError.new("rows_per_mark must be positive") if rows_per_mark <= 0
      raise ArgumentError.new("rows_per_mark exceeds writer limit") if rows_per_mark > MAX_ROWS_PER_MARK

      mark_count = checked_mark_count(keys.size, rows_per_mark)

      mark_file_size = (mark_count.to_i64 + 1_i64) * WidePart::MARK_SIZE
      raise ArgumentError.new("mark file exceeds reader limit") if mark_file_size > MAX_MARK_FILE_BYTES
      index_size = (mark_count.to_i64 + 1_i64) * 8_i64
      raise ArgumentError.new("primary index exceeds reader limit") if index_size > MAX_PRIMARY_INDEX_BYTES
      raw_file_bytes = keys.size.to_i64 * 8_i64
      raise ArgumentError.new("UInt64 data exceeds reader limit") if raw_file_bytes > MAX_DATA_FILE_BYTES

      previous = keys[0]
      keys.each_with_index do |key, index|
        raise ArgumentError.new("primary keys must be nondecreasing") if index > 0 && key < previous
        previous = key
      end

      # Ensure every possible full granule, including literal-LZ4 expansion,
      # fits both the frame decoder and this table reader's row bound.
      full_granule_rows = rows_per_mark
      raw_size = full_granule_rows.to_i64 * 8_i64
      raise ArgumentError.new("granule exceeds decompressed frame limit") if raw_size > MAX_FRAME_RAW_BYTES
      raise ArgumentError.new("granule literal frame exceeds compressed frame limit") if literal_frame_size(raw_size) > MAX_FRAME_COMPRESSED.to_i64
      nil
    end

    private def self.checked_mark_count(row_count : Int, rows_per_mark : Int32) : Int32
      count = (row_count.to_i64 + rows_per_mark.to_i64 - 1_i64) // rows_per_mark.to_i64
      raise ArgumentError.new("mark count exceeds writer limit") if count > MAX_MARKS
      count.to_i32
    end

    private def self.validate_column_name(name : String) : Nil
      unless name.bytesize > 0 && name.bytesize <= MAX_COLUMN_NAME_BYTES && /\A[A-Za-z_][A-Za-z0-9_]*\z/.matches?(name)
        raise ArgumentError.new("column name must be a bounded ASCII identifier")
      end
    end

    private def self.create_stage(parent : String) : String
      8.times do
        candidate = File.tempname(".crystal-click-wide-writer-", nil, dir: parent)
        next if File.exists?(candidate) || File.symlink?(candidate)
        begin
          Dir.mkdir(candidate)
          return candidate
        rescue ex : File::Error
          raise ex unless Errno.value == Errno::EEXIST
        end
      end
      raise IO::Error.new("cannot allocate a unique Wide-part staging directory")
    end

    private def self.write_uint64_stream(
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
            write_uint64_le(raw, row * 8, values[start_row + row])
          end

          write_uint64_le(mark_bytes, data_size)
          write_uint64_le(mark_bytes, 0_u64)
          write_uint64_le(mark_bytes, rows.to_u64)

          frame = encode_lz4_frame(raw)
          raise ArgumentError.new("data stream exceeds reader limit") if data_size > MAX_DATA_FILE_BYTES.to_u64 - frame.size.to_u64
          data_file.write(frame)
          data_hash.update(frame)
          raw_hash.update(raw)
          data_size += frame.size.to_u64
          start_row += rows
        end
      end

      write_uint64_le(mark_bytes, data_size)
      write_uint64_le(mark_bytes, 0_u64)
      write_uint64_le(mark_bytes, 0_u64)
      marks = mark_bytes.to_slice
      raise ArgumentError.new("mark stream exceeds reader limit") if marks.size.to_i64 > MAX_MARK_FILE_BYTES
      File.write(mark_path, marks)
      mark_hash = CityHashV1.file_hash(marks)

      [
        ChecksumRecord.new(data_name, data_size, data_hash.finish, true, values.size.to_u64 * 8_u64, raw_hash.finish),
        ChecksumRecord.new(marks_name, marks.size.to_u64, mark_hash, false),
      ]
    end

    private def self.write_primary_index(stage : String, keys : Slice(UInt64), rows_per_mark : Int32) : ChecksumRecord
      bytes = IO::Memory.new
      row = 0
      while row < keys.size
        write_uint64_le(bytes, keys[row])
        row += rows_per_mark
      end
      write_uint64_le(bytes, keys.last)
      raw = bytes.to_slice
      raise ArgumentError.new("primary index exceeds reader limit") if raw.size.to_i64 > MAX_PRIMARY_INDEX_BYTES
      File.write(File.join(stage, "primary.idx"), raw)
      ChecksumRecord.new("primary.idx", raw.size.to_u64, CityHashV1.file_hash(raw), false)
    end

    private def self.write_checksummed_file(stage : String, name : String, content : String) : ChecksumRecord
      File.write(File.join(stage, name), content)
      bytes = content.to_slice
      ChecksumRecord.new(name, bytes.size.to_u64, CityHashV1.file_hash(bytes), false)
    end

    private def self.write_plain_metadata(stage : String, name : String, content : String) : Nil
      File.write(File.join(stage, name), content)
      nil
    end

    private def self.write_checksums(stage : String, records : Array(ChecksumRecord)) : Nil
      sorted_records = records.sort_by(&.name)
      payload = IO::Memory.new
      write_var_uint(payload, sorted_records.size.to_u64)
      sorted_records.each do |record|
        name = record.name.to_slice
        write_var_uint(payload, name.size.to_u64)
        payload.write(name)
        write_var_uint(payload, record.physical_size)
        write_hash128_le(payload, record.file_hash)
        if record.compressed
          payload.write_byte(1_u8)
          write_var_uint(payload, record.uncompressed_size || raise "compressed checksum has no raw size")
          write_hash128_le(payload, record.uncompressed_hash || raise "compressed checksum has no raw hash")
        else
          payload.write_byte(0_u8)
        end
      end

      frame = encode_lz4_frame(payload.to_slice)
      File.open(File.join(stage, "checksums.txt"), "wb") do |file|
        file << PartChecksums::CHECKSUMS_HEADER
        file.write(frame)
      end
    end

    private def self.validate_staged_part(
      stage : String,
      key_name : String,
      value_name : String,
      keys : Slice(UInt64),
      values : Slice(UInt64),
      rows_per_mark : Int32,
    ) : Nil
      checksums = PartChecksums.open(stage)
      checksums.entries.each_key do |name|
        checksums.validate_selected_entries(stage, name)
      end

      mark_count = checked_mark_count(keys.size, rows_per_mark)
      key_part = WidePart.open(stage, key_name)
      value_part = WidePart.open(stage, value_name)
      raise CorruptPartError.new("staged key row count does not match") unless key_part.row_count == keys.size.to_u64
      raise CorruptPartError.new("staged value row count does not match") unless value_part.row_count == values.size.to_u64
      expected_mark_rows = Array(UInt64).new(mark_count)
      start = 0
      while start < keys.size
        rows = {rows_per_mark, keys.size - start}.min
        expected_mark_rows << rows.to_u64
        expected_keys = key_part.read_uint64_mark_range(key_name, expected_mark_rows.size - 1, 1)
        expected_values = value_part.read_uint64_mark_range(value_name, expected_mark_rows.size - 1, 1)
        rows.times do |offset|
          unless expected_keys[offset] == keys[start + offset] && expected_values[offset] == values[start + offset]
            raise CorruptPartError.new("staged UInt64 stream readback differs from input")
          end
        end
        start += rows
      end
      raise CorruptPartError.new("staged key marks do not match") unless key_part.mark_row_counts == expected_mark_rows
      raise CorruptPartError.new("staged value marks do not match") unless value_part.mark_row_counts == expected_mark_rows

      index = PrimaryKeyIndex.open(stage, mark_count, checksums)
      expected_index = Array(UInt64).new(mark_count + 1)
      row = 0
      while row < keys.size
        expected_index << keys[row]
        row += rows_per_mark
      end
      expected_index << keys.last
      raise CorruptPartError.new("staged primary index differs from input") unless index.keys == expected_index
      nil
    end

    private def self.publish_exclusively(stage : String, target : String) : Nil
      {% if flag?(:darwin) %}
        result = LibWidePartWriterAtomicPublish.renamex_np(stage.to_unsafe, target.to_unsafe, RENAME_EXCL)
        if result != 0
          raise ArgumentError.new("destination already exists") if Errno.value == Errno::EEXIST
          raise IO::Error.from_errno("atomic Wide-part publish failed")
        end
      {% else %}
        raise UnsupportedFormatError.new("atomic exclusive Wide-part publication is unsupported on this platform")
      {% end %}
      nil
    end

    private def self.columns_metadata(key_name : String, value_name : String) : String
      "columns format version: 1\n2 columns:\n`#{key_name}` UInt64\n`#{value_name}` UInt64\n"
    end

    private def self.substreams_metadata(key_name : String, value_name : String) : String
      "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n1 substreams for column `#{value_name}`:\n\t#{value_name}\n"
    end

    private def self.literal_frame_size(raw_size : Int64) : Int64
      extension_size = raw_size < 15 ? 0_i64 : ((raw_size - 15) // 255) + 1
      CompressedBlock::HEADER_SIZE.to_i64 + 16_i64 + 1_i64 + extension_size + raw_size
    end

    private def self.encode_lz4_frame(raw : Bytes) : Bytes
      raise ArgumentError.new("empty LZ4 blocks are unsupported") if raw.empty?
      extension_size = raw.size < 15 ? 0 : ((raw.size - 15) // 255) + 1
      payload_size = 1 + extension_size + raw.size
      compressed_size = CompressedBlock::HEADER_SIZE + payload_size
      raise ArgumentError.new("compressed frame exceeds reader limit") if compressed_size > MAX_FRAME_COMPRESSED

      frame = Bytes.new(CompressedBlock::FRAME_HEADER_SIZE + payload_size, 0_u8)
      header = CompressedBlock::CHECKSUM_SIZE
      frame[header] = CompressedBlock::METHOD_LZ4
      write_uint32_le(frame, header + 1, compressed_size.to_u32)
      write_uint32_le(frame, header + 5, raw.size.to_u32)

      cursor = CompressedBlock::FRAME_HEADER_SIZE
      if raw.size < 15
        frame[cursor] = (raw.size << 4).to_u8
        cursor += 1
      else
        frame[cursor] = 0xf0_u8
        cursor += 1
        remaining = raw.size - 15
        while remaining >= 255
          frame[cursor] = 255_u8
          cursor += 1
          remaining -= 255
        end
        frame[cursor] = remaining.to_u8
        cursor += 1
      end
      raw.copy_to(frame[cursor, raw.size])
      checksum = CityHashV1.hash128(frame[CompressedBlock::CHECKSUM_SIZE, compressed_size])
      write_hash128_le(frame, checksum)
      frame
    end

    private def self.write_var_uint(io : IO, value : UInt64) : Nil
      remaining = value
      while remaining >= 0x80_u64
        io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
        remaining >>= 7
      end
      io.write_byte(remaining.to_u8)
    end

    private def self.write_hash128_le(io : IO, hash : {UInt64, UInt64}) : Nil
      write_uint64_le(io, hash[0])
      write_uint64_le(io, hash[1])
    end

    private def self.write_hash128_le(bytes : Bytes, hash : {UInt64, UInt64}) : Nil
      write_uint64_le(bytes, 0, hash[0])
      write_uint64_le(bytes, 8, hash[1])
    end

    private def self.write_uint64_le(io : IO, value : UInt64) : Nil
      8.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
    end

    private def self.write_uint64_le(bytes : Bytes, offset : Int, value : UInt64) : Nil
      8.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
    end

    private def self.write_uint32_le(bytes : Bytes, offset : Int, value : UInt32) : Nil
      4.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u32).to_u8 }
    end
  end
end
