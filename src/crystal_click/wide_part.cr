module CrystalClick
  class WidePart
    MAX_ROWS                     = 100_000_000_u64
    MAX_DATA_FILE_BYTES          = 256_i64 * 1024 * 1024
    MAX_MARK_FILE_BYTES          = 64_i64 * 1024 * 1024
    MAX_FRAME_COMPRESSED_BYTES   = 64 * 1024 * 1024
    MAX_FRAME_DECOMPRESSED_BYTES = 64 * 1024 * 1024
    MARK_SIZE                    = 24

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
      expected_bytes = checked_byte_count(expected_rows)
      bytes = read_mark_range(start_mark, end_mark, expected_bytes)
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
      @data_path, @mark_path, compressed_marks = resolve_stream(@column)
      data_size = File.size(@data_path)
      raise CorruptPartError.new("data file exceeds limit") if data_size > MAX_DATA_FILE_BYTES
      @marks, @sentinel = parse_marks(@mark_path, data_size, compressed_marks)
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
      unless codec == "CODEC(LZ4)" || codec == "CODEC(ZSTD(1))"
        raise UnsupportedFormatError.new("only CODEC(LZ4) and CODEC(ZSTD(1)) are supported")
      end

      count_text = File.read(File.join(@path, "count.txt")).strip
      row_count = count_text.to_u64?
      raise CorruptPartError.new("invalid row count") unless row_count
      raise CorruptPartError.new("row count exceeds limit") if row_count > MAX_ROWS
      {column, row_count}
    rescue ex : ArgumentError
      raise CorruptPartError.new("invalid metadata")
    end

    private def resolve_stream(column : String) : {String, String, Bool}
      reject_unsupported_mark_extensions
      names = [column, StreamName.hash(column)]
      saw_partial = false
      candidates = Array({String, String, Bool}).new
      names.each do |name|
        data = File.join(@path, "#{name}.bin")
        plain_marks = File.join(@path, "#{name}.mrk2")
        compressed_marks = File.join(@path, "#{name}.cmrk2")
        data_exists = File.file?(data)
        plain_marks_exists = File.file?(plain_marks)
        compressed_marks_exists = File.file?(compressed_marks)
        if plain_marks_exists && compressed_marks_exists
          raise CorruptPartError.new("ambiguous mark streams")
        end
        marks_exists = plain_marks_exists || compressed_marks_exists
        saw_partial ||= data_exists != marks_exists
        if data_exists && marks_exists
          candidates << {data, plain_marks_exists ? plain_marks : compressed_marks, compressed_marks_exists}
        end
      end
      raise CorruptPartError.new("ambiguous data and mark streams") if candidates.size > 1
      return candidates.first.not_nil! if candidates.size == 1
      if saw_partial
        raise CorruptPartError.new("data and mark streams do not form a pair")
      end
      raise InvalidPartError.new("UInt64 stream files not found")
    end

    private def reject_unsupported_mark_extensions
      Dir.each_child(@path) do |entry|
        if entry.includes?(".cmrk") && !entry.ends_with?(".cmrk2")
          raise UnsupportedFormatError.new("unsupported mark extension")
        end
        if entry.includes?(".mrk") && !entry.ends_with?(".mrk2")
          raise UnsupportedFormatError.new("unsupported mark extension")
        end
      end
    end

    private def parse_marks(file : String, data_size : Int64, compressed : Bool) : {Array(Mark), Mark}
      size = File.size(file)
      raise CorruptPartError.new("mark file exceeds limit") if size > MAX_MARK_FILE_BYTES
      bytes = if compressed
                compressed_bytes = File.read(file).to_slice
                CompressedBlock.decode_all(
                  compressed_bytes,
                  MAX_FRAME_COMPRESSED_BYTES,
                  MAX_FRAME_DECOMPRESSED_BYTES,
                  MAX_MARK_FILE_BYTES
                )
              else
                File.read(file).to_slice
              end
      raise CorruptPartError.new("mark file is empty or truncated") if bytes.empty? || bytes.size % MARK_SIZE != 0
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

    private def read_mark_range(start_mark : Mark?, end_mark : Mark, max_output_bytes : Int) : Bytes
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
      selected_bytes = 0_i64
      frame_offset = start_offset.to_i64
      started = false
      loop do
        frame = CompressedBlock.decode_frame(
          data,
          frame_offset,
          MAX_FRAME_COMPRESSED_BYTES,
          MAX_FRAME_DECOMPRESSED_BYTES
        )
        current = frame_offset.to_u64
        started ||= current == start_offset
        raise CorruptPartError.new("mark does not start at a frame") unless started
        local_start = current == start_offset ? start_mark.not_nil!.decompressed_offset : 0_u64
        local_end = current == end_offset ? end_mark.decompressed_offset : frame.output.size.to_u64
        raise CorruptPartError.new("mark offset exceeds frame output") if local_start > frame.output.size || local_end > frame.output.size || local_start > local_end
        if current == end_offset && end_mark == @sentinel && !eof_sentinel
          raise CorruptPartError.new("non-EOF sentinel must end at frame output") unless end_mark.decompressed_offset == frame.output.size
        end
        selected_size = (local_end - local_start).to_i64
        raise CorruptPartError.new("selected data exceeds expected byte count") if selected_size > max_output_bytes.to_i64 - selected_bytes
        selected.write(frame.output[local_start.to_i, selected_size.to_i])
        selected_bytes += selected_size
        if current == end_offset
          raise CorruptPartError.new("data has trailing bytes after final frame") if end_mark == @sentinel && frame.end_offset != data_size
          break
        end
        next_offset = frame.end_offset
        break if eof_sentinel && next_offset == data_size
        raise CorruptPartError.new("mark frame offset was not found") if next_offset <= frame_offset || next_offset > data_size
        frame_offset = next_offset
      end
      selected.to_slice
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

    private def u64(bytes : Bytes, offset : Int) : UInt64
      raise CorruptPartError.new("truncated integer") if offset < 0 || offset > bytes.size - 8
      value = 0_u64
      8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
      value
    end
  end
end
