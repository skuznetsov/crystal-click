module CrystalClick
  class WidePart
    MAX_ROWS                     = 100_000_000_u64
    MAX_DATA_FILE_BYTES          = 256_i64 * 1024 * 1024
    MAX_MARK_FILE_BYTES          = 64_i64 * 1024 * 1024
    MAX_FRAME_COMPRESSED_BYTES   = 64 * 1024 * 1024
    MAX_FRAME_DECOMPRESSED_BYTES = 64 * 1024 * 1024
    MAX_CODEC_FILE_BYTES         = 64
    MAX_METADATA_FILE_BYTES      = 4 * 1024 * 1024
    MAX_METADATA_LINE_BYTES      = 64 * 1024
    MAX_METADATA_COLUMNS         =  4096
    MAX_METADATA_SUBSTREAMS      = 65536
    MARK_SIZE                    =    24

    getter path : String
    getter row_count : UInt64
    getter data_path : String
    getter mark_path : String
    getter checksum_verification : ChecksumVerification

    def self.open(path : String) : WidePart
      new(path, nil)
    rescue ex : IO::Error
      raise InvalidPartError.new(ex.message || "cannot read part")
    end

    def self.open(path : String, column : String) : WidePart
      new(path, column)
    rescue ex : IO::Error
      raise InvalidPartError.new(ex.message || "cannot read part")
    end

    def mark_count : Int
      @marks.size
    end

    def read_uint64(column : String = @column) : Array(UInt64)
      read_uint64_mark_range(column, 0, mark_count)
    end

    def read_uint64_slab(
      column : String = @column,
      slab_shift : Int = UInt64SlabVector::DEFAULT_SLAB_SHIFT,
    ) : UInt64SlabVector
      read_uint64_mark_range_slab(column, 0, mark_count, slab_shift)
    end

    def read_uint64_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(UInt64)
      start_mark, end_mark, expected_bytes = checked_mark_range(column, first_mark, mark_count)
      values = Array(UInt64).new
      each_uint64_mark_range(start_mark, end_mark, expected_bytes) do |value|
        values << value
      end
      values
    end

    def read_uint64_mark_range_slab(
      column : String,
      first_mark : Int,
      mark_count : Int,
      slab_shift : Int = UInt64SlabVector::DEFAULT_SLAB_SHIFT,
    ) : UInt64SlabVector
      start_mark, end_mark, expected_bytes = checked_mark_range(column, first_mark, mark_count)
      values = UInt64SlabVector.new(slab_shift: slab_shift)
      each_uint64_mark_range_bytes(start_mark, end_mark, expected_bytes) do |bytes|
        values.concat_le_bytes(bytes)
      end
      values
    end

    def scan_uint64_mark_range_into(
      column : String,
      first_mark : Int,
      mark_count : Int,
      scratch : Slice(UInt64),
      & : Slice(UInt64) -> Nil
    ) : Nil
      raise BoundsError.new("empty scratch") if scratch.size == 0
      raise BoundsError.new("scratch must be writable") if scratch.read_only?

      start_mark, end_mark, expected_bytes = checked_mark_range(column, first_mark, mark_count)
      chunk_size = 0
      each_uint64_mark_range(start_mark, end_mark, expected_bytes) do |value|
        scratch[chunk_size] = value
        chunk_size += 1
        if chunk_size == scratch.size
          yield scratch[0, chunk_size]
          chunk_size = 0
        end
      end
      yield scratch[0, chunk_size] if chunk_size > 0
      nil
    end

    # Scan a complete selected column while preserving physical mark
    # provenance.  A callback receives only values from one mark, and every
    # slice aliases the caller-owned scratch storage.
    def scan_uint64_marks_into(
      column : String,
      scratch : Slice(UInt64),
      & : Int32, UInt64, UInt64, Slice(UInt64) -> Nil
    ) : Nil
      raise BoundsError.new("empty scratch") if scratch.size == 0
      raise BoundsError.new("scratch must be writable") if scratch.read_only?

      start_mark, end_mark, expected_bytes = checked_mark_range(column, 0, mark_count)
      chunk_size = 0
      active_mark = 0_i32
      mark_rows = @marks[active_mark].rows
      mark_values = 0_u64
      mark_start = 0_u64

      each_uint64_mark_range(start_mark, end_mark, expected_bytes) do |value|
        scratch[chunk_size] = value
        chunk_size += 1
        mark_values += 1

        if chunk_size == scratch.size || mark_values == mark_rows
          mark_row_offset = mark_values - chunk_size.to_u64
          yield active_mark, mark_row_offset, mark_start &+ mark_row_offset, scratch[0, chunk_size]
          chunk_size = 0
        end

        if mark_values == mark_rows
          mark_start = mark_start &+ mark_rows
          active_mark += 1
          if active_mark < @marks.size
            mark_rows = @marks[active_mark].rows
            mark_values = 0_u64
          end
        end
      end

      if chunk_size > 0
        mark_row_offset = mark_values - chunk_size.to_u64
        yield active_mark, mark_row_offset, mark_start &+ mark_row_offset, scratch[0, chunk_size]
      end
      nil
    end

    @column : String
    @marks : Array(Mark)
    @sentinel : Mark

    private def initialize(path : String, requested_column : String?)
      @path = path
      raise InvalidPartError.new("part is not a directory") unless Dir.exists?(@path)
      @checksum_verification = ChecksumVerification::Unverified
      @column, @row_count, physical_stream = parse_metadata(requested_column)
      validate_selected_stream_name(physical_stream)
      @data_path, @mark_path, compressed_marks = resolve_stream(physical_stream)
      data_size = File.size(@data_path)
      raise CorruptPartError.new("data file exceeds limit") if data_size > MAX_DATA_FILE_BYTES
      @marks, @sentinel = parse_marks(@mark_path, data_size, compressed_marks)
      validate_rows
    end

    private def parse_metadata(requested_column : String?) : {String, UInt64, String}
      columns_text = read_metadata_file("columns.txt")
      columns = parse_columns(columns_text)
      if columns.empty?
        raise UnsupportedFormatError.new("columns.txt contains no columns")
      end
      if requested_column.nil? && columns.size > 1
        raise UnsupportedFormatError.new("column is required for a multi-column part")
      end
      column = requested_column || columns[0][0]
      selected = columns.find { |entry| entry[0] == column }
      raise UnsupportedFormatError.new("column is not present") unless selected
      raise UnsupportedFormatError.new("only exact UInt64 columns are supported") unless selected.not_nil![1] == "UInt64"

      validate_default_codec

      row_count = parse_count_file("count.txt")
      raise CorruptPartError.new("row count exceeds limit") if row_count > MAX_ROWS

      physical_stream = parse_substreams(columns, column)
      {column, row_count, physical_stream}
    rescue ex : ArgumentError
      raise CorruptPartError.new("invalid metadata")
    end

    private def read_metadata_file(name : String) : String
      file = File.join(@path, name)
      size = File.size(file)
      raise UnsupportedFormatError.new("#{name} exceeds metadata limit") if size > MAX_METADATA_FILE_BYTES
      text = File.read(file)
      raise UnsupportedFormatError.new("#{name} must end with LF") if text.empty? || text.bytesize != size || text.bytes.last != 10
      text
    end

    private def validate_default_codec
      file = File.join(@path, "default_compression_codec.txt")
      size = File.size(file)
      raise UnsupportedFormatError.new("default codec exceeds metadata limit") if size > MAX_CODEC_FILE_BYTES
      codec = File.read(file)
      unless codec.bytesize == size && (codec == "CODEC(LZ4)" || codec == "CODEC(ZSTD(1))")
        raise UnsupportedFormatError.new("only CODEC(LZ4) and CODEC(ZSTD(1)) are supported")
      end
    end

    private def parse_columns(text : String) : Array({String, String})
      bytes = text.to_slice
      cursor = 0
      require_metadata_line(bytes, cursor, "columns format version: 1", "columns.txt")
      cursor += line_length(bytes, cursor)
      count_line = metadata_line(bytes, cursor, "columns.txt")
      cursor += line_length(bytes, cursor)
      count = parse_count_line(count_line, " columns:", MAX_METADATA_COLUMNS, "columns.txt")
      columns = Array({String, String}).new(count)
      seen = Set(String).new
      count.times do
        line = metadata_line(bytes, cursor, "columns.txt")
        cursor += line_length(bytes, cursor)
        name, type_text = parse_column_line(line)
        raise UnsupportedFormatError.new("duplicate column name") if seen.includes?(name)
        seen << name
        columns << {name, type_text}
      end
      raise UnsupportedFormatError.new("trailing columns.txt data") unless cursor == bytes.size
      columns
    end

    private def parse_substreams(columns : Array({String, String}), selected_column : String) : String
      file = File.join(@path, "columns_substreams.txt")
      unless File.exists?(file)
        raise UnsupportedFormatError.new("columns_substreams.txt is required for multi-column parts") unless columns.size == 1
        return selected_column
      end
      text = read_metadata_file("columns_substreams.txt")
      bytes = text.to_slice
      cursor = 0
      require_metadata_line(bytes, cursor, "columns substreams version: 1", "columns_substreams.txt")
      cursor += line_length(bytes, cursor)
      count_line = metadata_line(bytes, cursor, "columns_substreams.txt")
      cursor += line_length(bytes, cursor)
      count = parse_count_line(count_line, " columns:", MAX_METADATA_COLUMNS, "columns_substreams.txt")
      raise UnsupportedFormatError.new("column count does not match") unless count == columns.size

      seen_columns = Set(String).new
      seen_streams = Set(String).new
      selected_stream = nil
      count.times do |index|
        line = metadata_line(bytes, cursor, "columns_substreams.txt")
        cursor += line_length(bytes, cursor)
        stream_count, column = parse_substream_header(line)
        expected_column = columns[index][0]
        raise UnsupportedFormatError.new("column order does not match") unless column == expected_column
        raise UnsupportedFormatError.new("duplicate column block") if seen_columns.includes?(column)
        seen_columns << column
        streams = Array(String).new(stream_count)
        stream_count.times do
          stream_line = metadata_line(bytes, cursor, "columns_substreams.txt")
          cursor += line_length(bytes, cursor)
          raise UnsupportedFormatError.new("invalid physical stream name") unless stream_line.starts_with?("\t")
          stream_bytes = stream_line.to_slice
          stream = String.new(stream_bytes[1, stream_bytes.size - 1])
          validate_opaque_name(stream)
          raise UnsupportedFormatError.new("duplicate physical stream name") if seen_streams.includes?(stream)
          seen_streams << stream
          streams << stream
        end
        if column == selected_column
          raise UnsupportedFormatError.new("selected column must have one physical substream") unless streams.size == 1
          raise UnsupportedFormatError.new("selected physical substream does not match column") unless streams[0] == selected_column
          selected_stream = streams[0]
        end
      end
      raise UnsupportedFormatError.new("trailing columns_substreams.txt data") unless cursor == bytes.size
      selected_stream || raise UnsupportedFormatError.new("selected column substreams are missing")
    end

    private def parse_count_file(name : String) : UInt64
      path = File.join(@path, name)
      size = File.size(path)
      raise CorruptPartError.new("invalid row count") if size == 0 || size > 32
      text = File.read(path)
      raise CorruptPartError.new("invalid row count") unless text.bytesize == size
      text = String.new(text.to_slice[0, text.bytesize - 1]) if text.ends_with?("\n")
      value = parse_decimal(text, UInt64::MAX, name)
      value
    end

    private def parse_count_line(line : String, suffix : String, limit : Int, file : String) : Int
      raise UnsupportedFormatError.new("invalid count in #{file}") unless line.ends_with?(suffix)
      line_bytes = line.to_slice
      digits = String.new(line_bytes[0, line_bytes.size - suffix.bytesize])
      value = parse_decimal(digits, limit.to_u64, file)
      value.to_i
    end

    private def parse_decimal(text : String, limit : UInt64, file : String) : UInt64
      raise UnsupportedFormatError.new("invalid count in #{file}") if text.empty? || (text.bytesize > 1 && text.to_slice[0] == '0'.ord)
      value = 0_u64
      text.each_byte do |byte|
        raise UnsupportedFormatError.new("invalid count in #{file}") unless byte >= '0'.ord && byte <= '9'.ord
        digit = (byte - '0'.ord).to_u64
        raise UnsupportedFormatError.new("count exceeds limit in #{file}") if value > (limit - digit) // 10
        value = value * 10 + digit
      end
      value
    end

    private def metadata_line(bytes : Bytes, cursor : Int, file : String) : String
      length = line_length(bytes, cursor)
      raise UnsupportedFormatError.new("line exceeds metadata limit in #{file}") if length > MAX_METADATA_LINE_BYTES
      String.new(bytes[cursor, length - 1])
    end

    private def require_metadata_line(bytes : Bytes, cursor : Int, expected : String, file : String)
      raise UnsupportedFormatError.new("unsupported #{file}") unless metadata_line(bytes, cursor, file) == expected
    end

    private def line_length(bytes : Bytes, cursor : Int) : Int
      raise UnsupportedFormatError.new("truncated metadata line") if cursor < 0 || cursor >= bytes.size
      index = cursor
      while index < bytes.size && bytes[index] != 10
        index += 1
      end
      raise UnsupportedFormatError.new("truncated metadata line") if index >= bytes.size
      index - cursor + 1
    end

    private def parse_column_line(line : String) : {String, String}
      name, end_index = parse_quoted_name(line, 0)
      bytes = line.to_slice
      raise UnsupportedFormatError.new("invalid column type") if end_index >= bytes.size || bytes[end_index] != ' '.ord
      type_text = String.new(bytes[end_index + 1, bytes.size - end_index - 1])
      raise UnsupportedFormatError.new("invalid column type") if type_text.empty? || type_text.each_byte.any? { |byte| byte == 0 || byte == 13 }
      {name, type_text}
    end

    private def parse_substream_header(line : String) : {Int32, String}
      marker = " substreams for column "
      marker_index = line.index(marker)
      raise UnsupportedFormatError.new("invalid substream header") unless marker_index
      line_bytes = line.to_slice
      count = parse_decimal(String.new(line_bytes[0, marker_index]), MAX_METADATA_SUBSTREAMS.to_u64, "columns_substreams.txt").to_i
      start = marker_index + marker.bytesize
      name, end_index = parse_quoted_name(line, start)
      bytes = line.to_slice
      raise UnsupportedFormatError.new("invalid substream header") unless end_index < bytes.size && bytes[end_index] == ':'.ord
      raise UnsupportedFormatError.new("invalid substream header") unless end_index + 1 == bytes.size
      {count, name}
    end

    private def parse_quoted_name(line : String, start : Int) : {String, Int32}
      bytes = line.to_slice
      raise UnsupportedFormatError.new("invalid quoted identifier") if start < 0 || start >= bytes.size || bytes[start] != '`'.ord
      end_index = -1
      decoded_length = 0
      decoded = String.build do |io|
        index = start + 1
        while index < bytes.size
          byte = bytes[index]
          if byte == '`'.ord
            if index + 1 < bytes.size && bytes[index + 1] == '`'.ord
              io.write_byte('`'.ord.to_u8)
              decoded_length += 1
              index += 2
              next
            end
            end_index = index + 1
            break
          elsif byte == '\\'.ord
            index += 1
            raise UnsupportedFormatError.new("invalid quoted identifier escape") if index >= bytes.size
            escaped = bytes[index]
            if escaped == 'x'.ord
              raise UnsupportedFormatError.new("invalid hex escape") if index + 2 >= bytes.size
              high = hex_digit(bytes[index + 1])
              low = hex_digit(bytes[index + 2])
              raise UnsupportedFormatError.new("invalid hex escape") unless high && low
              io.write_byte((high.not_nil! << 4) | low.not_nil!)
              decoded_length += 1
              index += 3
              next
            elsif escaped == 'N'.ord
              index += 1
              next
            end
            decoded_byte = escaped == 'a'.ord ? 0x07_u8 : escaped == 'b'.ord ? 0x08_u8 : escaped == 'e'.ord ? 0x1b_u8 : escaped == 'f'.ord ? 0x0c_u8 : escaped == 'n'.ord ? 0x0a_u8 : escaped == 'r'.ord ? 0x0d_u8 : escaped == 't'.ord ? 0x09_u8 : escaped == 'v'.ord ? 0x0b_u8 : escaped == '0'.ord ? 0_u8 : escaped
            if decoded_byte != '\\'.ord && decoded_byte != '\''.ord && decoded_byte != '"'.ord && decoded_byte != '`'.ord && decoded_byte != '/'.ord && decoded_byte != '='.ord && decoded_byte >= 0x20
              io.write_byte('\\'.ord.to_u8)
              decoded_length += 1
            end
            io.write_byte(decoded_byte)
            decoded_length += 1
            index += 1
          else
            raise UnsupportedFormatError.new("invalid quoted identifier") if byte == 0 || byte == 10 || byte == 13
            io.write_byte(byte)
            decoded_length += 1
            index += 1
          end
        end
      end
      raise UnsupportedFormatError.new("unterminated quoted identifier") if end_index < 0
      raise UnsupportedFormatError.new("empty column name") if decoded_length == 0
      {decoded, end_index}
    end

    private def hex_digit(byte : UInt8) : UInt8?
      if byte >= '0'.ord && byte <= '9'.ord
        byte - '0'.ord
      elsif byte >= 'a'.ord && byte <= 'f'.ord
        byte - 'a'.ord + 10
      elsif byte >= 'A'.ord && byte <= 'F'.ord
        byte - 'A'.ord + 10
      end
    end

    private def validate_opaque_name(name : String)
      raise UnsupportedFormatError.new("invalid physical stream name") if name.empty? || name.bytesize > MAX_METADATA_LINE_BYTES
      name.each_byte do |byte|
        raise UnsupportedFormatError.new("invalid physical stream name") if byte < 0x20 || byte == 0x7f
      end
    end

    private def validate_selected_stream_name(name : String)
      validate_opaque_name(name)
      if name.includes?("/") || name.includes?("\\")
        raise UnsupportedFormatError.new("selected physical stream name is not a filename component")
      end
    end

    private def resolve_stream(column : String) : {String, String, Bool}
      names = [column, StreamName.hash(column)]
      reject_target_unsupported_mark_extensions(names)
      saw_partial = false
      candidates = Array({String, String, Bool}).new
      names.each do |name|
        data = File.join(@path, "#{name}.bin")
        plain_marks = File.join(@path, "#{name}.mrk2")
        compressed_marks = File.join(@path, "#{name}.cmrk2")
        if File.symlink?(data) || File.symlink?(plain_marks) || File.symlink?(compressed_marks)
          raise CorruptPartError.new("symbolic links are not supported for target streams")
        end
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
      if saw_partial
        raise CorruptPartError.new("data and mark streams do not form a pair")
      end
      return candidates.first.not_nil! if candidates.size == 1
      raise InvalidPartError.new("UInt64 stream files not found")
    end

    private def reject_target_unsupported_mark_extensions(names : Array(String))
      Dir.each_child(@path) do |entry|
        names.each do |name|
          prefix = "#{name}."
          next unless entry.starts_with?(prefix)
          entry_bytes = entry.to_slice
          extension = String.new(entry_bytes[prefix.bytesize, entry_bytes.size - prefix.bytesize])
          next if extension.includes?(".")
          if extension.starts_with?("cmrk") && extension != "cmrk2" || extension.starts_with?("mrk") && extension != "mrk2"
            raise UnsupportedFormatError.new("unsupported mark extension")
          end
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

    private def checked_mark_range(column : String, first_mark : Int, mark_count : Int) : {Mark?, Mark, Int32}
      ensure_column(column)
      raise BoundsError.new("negative mark range") if first_mark < 0 || mark_count < 0
      raise BoundsError.new("empty mark range") if mark_count == 0
      raise BoundsError.new("mark range exceeds data marks") if first_mark > @marks.size || mark_count > @marks.size - first_mark

      start_mark = @marks[first_mark] if first_mark < @marks.size
      end_index = first_mark + mark_count
      end_mark = end_index == @marks.size ? @sentinel : @marks[end_index]
      expected_rows = rows_in_range(first_mark, mark_count)
      expected_bytes = checked_byte_count(expected_rows).to_i32
      {start_mark, end_mark, expected_bytes}
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

    private def each_uint64_mark_range(start_mark : Mark?, end_mark : Mark, expected_bytes : Int, & : UInt64 -> Nil) : Nil
      each_uint64_mark_range_bytes(start_mark, end_mark, expected_bytes) do |bytes|
        offset = 0
        while offset < bytes.size
          yield u64(bytes, offset)
          offset += 8
        end
      end
    end

    private def each_uint64_mark_range_bytes(start_mark : Mark?, end_mark : Mark, expected_bytes : Int, & : Bytes -> Nil) : Nil
      raise BoundsError.new("empty mark range") unless start_mark
      data_size = File.size(@data_path)
      raise CorruptPartError.new("data file exceeds limit") if data_size > MAX_DATA_FILE_BYTES
      MMapDataSource.with_file(@data_path, data_size, MAX_DATA_FILE_BYTES) do |data|
        start_offset = start_mark.not_nil!.compressed_offset
        end_offset = end_mark.compressed_offset
        eof_sentinel = end_mark == @sentinel && end_offset == data_size.to_u64 && end_mark.decompressed_offset == 0
        raise CorruptPartError.new("mark frame offset exceeds data") if start_offset >= data_size || end_offset > data_size || end_offset == data_size && !eof_sentinel
        raise CorruptPartError.new("mark frame offsets are reversed") if start_offset > end_offset

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
          raise CorruptPartError.new("selected data exceeds expected byte count") if selected_size > expected_bytes.to_i64 - selected_bytes
          raise CorruptPartError.new("UInt64 bytes are not aligned") unless selected_size % 8 == 0
          yield frame.output[local_start.to_i, selected_size.to_i] if selected_size > 0
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
        raise CorruptPartError.new("mark range byte count mismatch") unless selected_bytes == expected_bytes
      end
    end

    private def u64(bytes : Bytes, offset : Int) : UInt64
      raise CorruptPartError.new("truncated integer") if offset < 0 || offset > bytes.size - 8
      value = 0_u64
      8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
      value
    end
  end
end
