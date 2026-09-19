module CrystalClick
  class WidePart
    MAX_ROWS                     = 100_000_000_u64
    MAX_DATA_FILE_BYTES          = 256_i64 * 1024 * 1024
    MAX_MARK_FILE_BYTES          = 64_i64 * 1024 * 1024
    MAX_FRAME_COMPRESSED_BYTES   = 64 * 1024 * 1024
    MAX_FRAME_DECOMPRESSED_BYTES = 64 * 1024 * 1024
    MARK_SIZE                    = 24
    FRAME_HEADER_SIZE            = 25

    getter path : String
    getter row_count : UInt64
    getter data_path : String
    getter mark_path : String
    getter checksum_verification : ChecksumVerification

    def self.open(path : String) : WidePart
      new(path)
    rescue ex : IO::Error
      raise InvalidPartError.new(ex.message || "cannot read part")
    end

    def mark_count : Int
      @marks.size
    end

    def read_uint64(column : String = @column) : Array(UInt64)
      read_uint64_mark_range(column, 0, mark_count)
    end

    def read_uint64_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(UInt64)
      ensure_column(column)
      raise BoundsError.new("negative mark range") if first_mark < 0 || mark_count < 0
      raise BoundsError.new("empty mark range") if mark_count == 0
      raise BoundsError.new("mark range exceeds data marks") if first_mark > @marks.size || mark_count > @marks.size - first_mark

      start_mark = @marks[first_mark] if first_mark < @marks.size
      end_index = first_mark + mark_count
      end_mark = end_index == @marks.size ? @sentinel : @marks[end_index]
      expected_rows = rows_in_range(first_mark, mark_count)
      bytes = read_mark_range(start_mark, end_mark)
      expected_bytes = checked_byte_count(expected_rows)
      raise CorruptPartError.new("mark range byte count mismatch") unless bytes.size == expected_bytes
      decode_uint64(bytes)
    end

    @column : String
    @marks : Array(Mark)
    @sentinel : Mark

    private def initialize(path : String)
      @path = path
      raise InvalidPartError.new("part is not a directory") unless Dir.exists?(@path)
      @checksum_verification = ChecksumVerification::Unverified
      @column, @row_count = parse_metadata
      @data_path, @mark_path = resolve_stream(@column)
      data_size = File.size(@data_path)
      raise CorruptPartError.new("data file exceeds limit") if data_size > MAX_DATA_FILE_BYTES
      @marks, @sentinel = parse_marks(@mark_path, data_size)
      validate_rows
    end

    private def parse_metadata : {String, UInt64}
      column_lines = File.read(File.join(@path, "columns.txt")).lines.map(&.chomp)
      unless column_lines.size == 3 && column_lines[0] == "columns format version: 1" && column_lines[1] == "1 columns:"
        raise UnsupportedFormatError.new("unsupported columns.txt")
      end
      match = column_lines[2].match(/\A`([A-Za-z_][A-Za-z0-9_]*)` UInt64\z/)
      raise UnsupportedFormatError.new("only one exact UInt64 column is supported") unless match
      column = match[1]

      substream_lines = File.read(File.join(@path, "columns_substreams.txt")).lines.map(&.chomp)
      expected_substreams = [
        "columns substreams version: 1",
        "1 columns:",
        "1 substreams for column `#{column}`:",
        "\t#{column}",
      ]
      raise UnsupportedFormatError.new("unsupported columns_substreams.txt") unless substream_lines == expected_substreams

      codec = File.read(File.join(@path, "default_compression_codec.txt")).strip
      raise UnsupportedFormatError.new("only CODEC(LZ4) is supported") unless codec == "CODEC(LZ4)"

      count_text = File.read(File.join(@path, "count.txt")).strip
      row_count = count_text.to_u64?
      raise CorruptPartError.new("invalid row count") unless row_count
      raise CorruptPartError.new("row count exceeds limit") if row_count > MAX_ROWS
      {column, row_count}
    rescue ex : ArgumentError
      raise CorruptPartError.new("invalid metadata")
    end

    private def resolve_stream(column : String) : {String, String}
      reject_unsupported_mark_extensions
      names = [column, StreamName.hash(column)]
      saw_partial = false
      names.each do |name|
        data = File.join(@path, "#{name}.bin")
        marks = File.join(@path, "#{name}.mrk2")
        data_exists = File.file?(data)
        marks_exists = File.file?(marks)
        saw_partial ||= data_exists != marks_exists
        return {data, marks} if data_exists && marks_exists
      end
      if saw_partial
        raise CorruptPartError.new("data and mark streams do not form a pair")
      end
      raise InvalidPartError.new("UInt64 stream files not found")
    end

    private def reject_unsupported_mark_extensions
      Dir.each_child(@path) do |entry|
        if entry.ends_with?(".mrk") || entry.ends_with?(".mrk3") || entry.ends_with?(".mrk4") || entry.starts_with?(".") && entry.includes?(".cmrk") || entry.includes?(".cmrk")
          raise UnsupportedFormatError.new("unsupported mark extension")
        end
      end
    end

    private def parse_marks(file : String, data_size : Int64) : {Array(Mark), Mark}
      size = File.size(file)
      raise CorruptPartError.new("mark file exceeds limit") if size > MAX_MARK_FILE_BYTES
      raise CorruptPartError.new("mark file is empty or truncated") if size <= 0 || size % MARK_SIZE != 0
      bytes = File.read(file).to_slice
      records = Array(Mark).new(bytes.size // MARK_SIZE)
      previous_compressed = 0_u64
      previous_decompressed = 0_u64
      offset = 0
      while offset < bytes.size
        compressed = u64(bytes, offset)
        decompressed = u64(bytes, offset + 8)
        rows = u64(bytes, offset + 16)
        raise CorruptPartError.new("first mark must start at zero") if offset == 0 && (compressed != 0 || decompressed != 0)
        raise CorruptPartError.new("mark compressed offset exceeds data") if compressed >= data_size && !(offset + MARK_SIZE == bytes.size && rows == 0 && compressed == data_size)
        raise CorruptPartError.new("mark offset is not monotonic") if compressed < previous_compressed
        raise CorruptPartError.new("mark decompressed offset is not monotonic") if compressed == previous_compressed && decompressed < previous_decompressed
        raise CorruptPartError.new("mark offset exceeds limit") if decompressed > MAX_FRAME_DECOMPRESSED_BYTES
        raise CorruptPartError.new("mark decompressed offset is not UInt64-aligned") unless decompressed % 8 == 0
        if rows == 0
          raise CorruptPartError.new("zero-row mark must be the sentinel") unless offset + MARK_SIZE == bytes.size
          raise CorruptPartError.new("EOF sentinel must have zero local offset") if compressed == data_size && decompressed != 0
        else
          raise CorruptPartError.new("mark row count is not aligned") if rows > MAX_FRAME_DECOMPRESSED_BYTES.to_u64 // 8
        end
        records << Mark.new(compressed, decompressed, rows)
        previous_compressed = compressed
        previous_decompressed = decompressed
        offset += MARK_SIZE
      end
      raise CorruptPartError.new("missing mark sentinel") unless records.last.rows == 0
      sentinel = records.pop
      raise CorruptPartError.new("no data marks") if records.empty?
      {records, sentinel}
    end

    private def validate_rows
      total = 0_u64
      @marks.each do |mark|
        total = total &+ mark.rows
        raise CorruptPartError.new("row count overflow") if total < mark.rows
      end
      raise CorruptPartError.new("row count does not match marks") unless total == @row_count
    end

    private def ensure_column(column : String)
      raise UnsupportedFormatError.new("column is not present") unless column == @column
    end

    private def rows_in_range(first_mark : Int, count : Int) : UInt64
      total = 0_u64
      count.times do |index|
        rows = @marks[first_mark + index].rows
        total = total &+ rows
        raise CorruptPartError.new("mark range row count overflow") if total < rows
      end
      total
    end

    private def checked_byte_count(rows : UInt64) : Int
      raise CorruptPartError.new("row byte count overflow") if rows > (Int32::MAX.to_u64 / 8)
      (rows * 8).to_i
    end

    private def read_mark_range(start_mark : Mark?, end_mark : Mark) : Bytes
      raise BoundsError.new("empty mark range") unless start_mark
      data_size = File.size(@data_path)
      raise CorruptPartError.new("data file exceeds limit") if data_size > MAX_DATA_FILE_BYTES
      data = File.read(@data_path).to_slice
      start_offset = start_mark.not_nil!.compressed_offset
      end_offset = end_mark.compressed_offset
      eof_sentinel = end_mark == @sentinel && end_offset == data_size.to_u64 && end_mark.decompressed_offset == 0
      raise CorruptPartError.new("mark frame offset exceeds data") if start_offset >= data_size || end_offset > data_size || end_offset == data_size && !eof_sentinel
      raise CorruptPartError.new("mark frame offsets are reversed") if start_offset > end_offset

      selected = IO::Memory.new
      frame_offset = start_offset.to_i64
      started = false
      loop do
        frame = decode_frame(data, frame_offset)
        current = frame_offset.to_u64
        started ||= current == start_offset
        raise CorruptPartError.new("mark does not start at a frame") unless started
        local_start = current == start_offset ? start_mark.not_nil!.decompressed_offset : 0_u64
        local_end = current == end_offset ? end_mark.decompressed_offset : frame[1].size.to_u64
        raise CorruptPartError.new("mark offset exceeds frame output") if local_start > frame[1].size || local_end > frame[1].size || local_start > local_end
        selected.write(frame[1][local_start.to_i, (local_end - local_start).to_i])
        if current == end_offset
          raise CorruptPartError.new("data has trailing bytes after final frame") if end_mark == @sentinel && frame[0] != data_size
          break
        end
        next_offset = frame[0]
        break if eof_sentinel && next_offset == data_size
        raise CorruptPartError.new("mark frame offset was not found") if next_offset <= frame_offset || next_offset > data_size
        frame_offset = next_offset
      end
      selected.to_slice
    end

    private def decode_frame(data : Bytes, offset : Int64) : {Int64, Bytes}
      raise CorruptPartError.new("frame offset out of bounds") if offset < 0 || offset > data.size - FRAME_HEADER_SIZE
      method = data[offset.to_i + 16]
      raise UnsupportedFormatError.new("only ClickHouse LZ4 frames are supported") unless method == 0x82
      compressed_size = u32(data, offset.to_i + 17).to_i64
      decompressed_size = u32(data, offset.to_i + 21).to_i64
      raise CorruptPartError.new("compressed frame size is invalid") if compressed_size < 9 || compressed_size > MAX_FRAME_COMPRESSED_BYTES
      raise CorruptPartError.new("decompressed frame size is invalid") if decompressed_size <= 0 || decompressed_size > MAX_FRAME_DECOMPRESSED_BYTES
      frame_end = offset + 16 + compressed_size
      raise CorruptPartError.new("compressed frame is truncated") if frame_end > data.size
      payload_offset = offset.to_i + FRAME_HEADER_SIZE
      payload_size = compressed_size.to_i - 9
      payload = data[payload_offset, payload_size]
      output = LZ4.decode(payload, decompressed_size.to_i)
      {frame_end, output}
    end

    private def decode_uint64(bytes : Bytes) : Array(UInt64)
      raise CorruptPartError.new("UInt64 bytes are not aligned") unless bytes.size % 8 == 0
      values = Array(UInt64).new(bytes.size // 8)
      offset = 0
      while offset < bytes.size
        values << u64(bytes, offset)
        offset += 8
      end
      values
    end

    private def u32(bytes : Bytes, offset : Int) : UInt32
      raise CorruptPartError.new("truncated integer") if offset < 0 || offset > bytes.size - 4
      bytes[offset].to_u32 |
        (bytes[offset + 1].to_u32 << 8) |
        (bytes[offset + 2].to_u32 << 16) |
        (bytes[offset + 3].to_u32 << 24)
    end

    private def u64(bytes : Bytes, offset : Int) : UInt64
      raise CorruptPartError.new("truncated integer") if offset < 0 || offset > bytes.size - 8
      value = 0_u64
      8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
      value
    end
  end
end
