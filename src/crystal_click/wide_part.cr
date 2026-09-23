require "json"

module CrystalClick
  class WidePart
    MAX_ROWS                     = 100_000_000_u64
    MAX_DATA_FILE_BYTES          = 256_i64 * 1024 * 1024
    MAX_MARK_FILE_BYTES          = 64_i64 * 1024 * 1024
    MAX_FRAME_COMPRESSED_BYTES   = 64 * 1024 * 1024
    MAX_FRAME_DECOMPRESSED_BYTES = 64 * 1024 * 1024
    MAX_STRING_RANGE_BYTES       = 64 * 1024 * 1024
    MAX_CODEC_FILE_BYTES         = 64
    MAX_METADATA_FILE_BYTES      = 4 * 1024 * 1024
    MAX_METADATA_LINE_BYTES      = 64 * 1024
    MAX_METADATA_COLUMNS         =  4096
    MAX_METADATA_SUBSTREAMS      = 65536
    MARK_SIZE                    =    24

    def self.supports_numeric_type?(type : String) : Bool
      case type
      when "UInt8", "UInt16", "UInt32", "UInt64", "Int8", "Int16", "Int32", "Int64", "Float32", "Float64"
        true
      else
        false
      end
    end

    def self.supports_nullable_numeric_type?(type : String) : Bool
      return false unless type.starts_with?("Nullable(") && type.ends_with?(")")
      inner = type.byte_slice("Nullable(".bytesize, type.bytesize - "Nullable()".bytesize)
      supports_numeric_type?(inner)
    end

    def self.supports_typed_type?(type : String) : Bool
      type == "String" || supports_numeric_type?(type) || supports_nullable_numeric_type?(type)
    end

    def self.json_type?(type : String) : Bool
      type == "JSON" || type.starts_with?("JSON(")
    end

    # Parse the intentionally small JSON typed-path declaration grammar used
    # by this reader: simple top-level identifiers with exact primitive
    # numeric or String types. Unsupported declarations fail closed.
    def self.json_typed_paths(type : String) : Array({String, String})
      raise UnsupportedFormatError.new("JSON column has no explicit typed paths") unless type.starts_with?("JSON(") && type.ends_with?(")")
      inner = type.byte_slice(5, type.bytesize - 6)
      raise UnsupportedFormatError.new("empty JSON typed-path declaration") if inner.empty?

      declarations = Array({String, String}).new
      seen = Set(String).new
      start = 0
      depth = 0
      inner.to_slice.each_with_index do |byte, index|
        case byte
        when '('.ord
          depth += 1
        when ')'.ord
          depth -= 1
          raise UnsupportedFormatError.new("malformed JSON typed-path declaration") if depth < 0
        when ','.ord
          next unless depth == 0
          add_json_typed_path(inner.byte_slice(start, index - start), declarations, seen)
          start = index + 1
        end
      end
      raise UnsupportedFormatError.new("malformed JSON typed-path declaration") unless depth == 0
      add_json_typed_path(inner.byte_slice(start, inner.bytesize - start), declarations, seen)
      declarations
    end

    def self.json_typed_path_type(type : String, path : String) : String?
      json_typed_paths(type).find { |entry| entry[0] == path }.try(&.[1])
    end

    private def self.add_json_typed_path(
      declaration : String,
      declarations : Array({String, String}),
      seen : Set(String),
    ) : Nil
      match = /\A\s*([A-Za-z_][A-Za-z0-9_]*)\s+([A-Za-z0-9_]+)\s*\z/.match(declaration)
      raise UnsupportedFormatError.new("unsupported JSON typed-path declaration") unless match
      path = match[1]
      type = match[2]
      raise UnsupportedFormatError.new("duplicate JSON typed path") if seen.includes?(path)
      unless type == "String" || supports_numeric_type?(type)
        raise UnsupportedFormatError.new("unsupported JSON typed-path scalar type")
      end
      seen << path
      declarations << {path, type}
    end

    def self.numeric_type_name(type : T.class) : String forall T
      {% if T == UInt8 %}
        "UInt8"
      {% elsif T == UInt16 %}
        "UInt16"
      {% elsif T == UInt32 %}
        "UInt32"
      {% elsif T == UInt64 %}
        "UInt64"
      {% elsif T == Int8 %}
        "Int8"
      {% elsif T == Int16 %}
        "Int16"
      {% elsif T == Int32 %}
        "Int32"
      {% elsif T == Int64 %}
        "Int64"
      {% elsif T == Float32 %}
        "Float32"
      {% elsif T == Float64 %}
        "Float64"
      {% else %}
        raise UnsupportedFormatError.new("only exact fixed-width primitive numeric accessors are supported")
      {% end %}
    end

    getter path : String
    getter column_type : String
    getter source_column_name : String
    getter source_column_type : String
    getter json_typed_path : Bool
    getter row_count : UInt64
    getter data_path : String
    getter mark_path : String
    getter checksum_verification : ChecksumVerification

    # Physical checksum targets for every selected substream, including
    # String size streams and Nullable null maps.
    def selected_checksum_names : Array(String)
      @streams.values.flat_map do |stream|
        [File.basename(stream.data_path), File.basename(stream.mark_path)]
      end
    end

    def self.open(path : String) : WidePart
      new(path, nil, :uint64)
    rescue ex : IO::Error
      raise InvalidPartError.new(ex.message || "cannot read part")
    end

    def self.open(path : String, column : String) : WidePart
      new(path, column, :uint64)
    rescue ex : IO::Error
      raise InvalidPartError.new(ex.message || "cannot read part")
    end

    # Open a supported fixed-width numeric column. Existing open/read_uint64
    # entry points remain UInt64-only.
    def self.open_numeric(path : String, column : String) : WidePart
      new(path, column, :numeric)
    rescue ex : IO::Error
      raise InvalidPartError.new(ex.message || "cannot read part")
    end

    # Open an exact String or primitive numeric column, including Nullable(T).
    # Serialization version metadata and every physical substream are checked.
    def self.open_typed(path : String, column : String) : WidePart
      new(path, column, :typed)
    rescue ex : IO::Error
      raise InvalidPartError.new(ex.message || "cannot read part")
    end

    def mark_count : Int
      @marks.size
    end

    # Return the complete ordered row counts for this column's data marks.
    # The returned array is independent of the reader's cached mark records.
    def mark_row_counts : Array(UInt64)
      @marks.map(&.rows)
    end

    def read_numeric_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
      type : T.class,
    ) : Array(T) forall T
      expected_type = WidePart.numeric_type_name(type)
      element_width = numeric_type_width(expected_type)
      raise UnsupportedFormatError.new("typed accessor does not match selected column type") unless expected_type == @column_type

      start_mark, end_mark, expected_bytes = checked_numeric_mark_range(column, first_mark, mark_count, expected_type, element_width)
      values = Array(T).new
      each_mark_range_bytes(start_mark, end_mark, expected_bytes, element_width) do |bytes|
        offset = 0
        while offset < bytes.size
          values << decode_numeric_value(bytes, offset, type)
          offset += element_width
        end
      end
      values
    end

    # Return the raw-byte sum for an exact String mark range without
    # materializing its String values. WidePartTable uses this to preflight an
    # aggregate bound across selected String columns before reading raw streams.
    def string_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      raise UnsupportedFormatError.new("String accessor requires an exact String column") unless @column_type == "String"
      _, total_bytes = read_string_sizes(column, first_mark, mark_count)
      total_bytes
    end

    # Read a bounded mark range from an exact String column. At most 64 MiB of
    # raw bytes are materialized per call (the whole range, not each mark).
    # Empty values are zero-length; embedded NUL bytes are preserved.
    def read_string_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(String)
      ensure_column(column)
      raise UnsupportedFormatError.new("String accessor requires an exact String column") unless @column_type == "String"
      string_stream = @streams[column]
      sizes, total_bytes = read_string_sizes(column, first_mark, mark_count)
      raw_start, raw_end, raw_rows = checked_stream_mark_range(string_stream, first_mark, mark_count)
      raise CorruptPartError.new("selected String substream marks changed") unless raw_rows == sizes.size.to_u64
      raw_bytes = read_mark_range_bytes(string_stream, raw_start, raw_end, total_bytes.to_i, 1)
      values = Array(String).new(sizes.size)
      offset = 0
      sizes.each do |size|
        length = size.to_i
        values << String.new(raw_bytes[offset, length])
        offset += length
      end
      raise CorruptPartError.new("String sizes do not consume selected raw bytes") unless offset == raw_bytes.size
      values
    end

    # Read a bounded range from basic Nullable(T) streams. The separate null
    # map and nested-value substreams retain their own compressed offsets and
    # are decoded independently at identical mark indices.
    def read_nullable_numeric_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
      type : T.class,
    ) : Array(T?) forall T
      ensure_column(column)
      expected_type = "Nullable(#{WidePart.numeric_type_name(type)})"
      raise UnsupportedFormatError.new("typed accessor does not match selected Nullable column type") unless @column_type == expected_type
      element_width = numeric_type_width(WidePart.numeric_type_name(type))
      null_stream = @streams["#{column}.null"]
      value_stream = @streams[column]
      null_start, null_end, rows = checked_stream_mark_range(null_stream, first_mark, mark_count)
      value_start, value_end, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Nullable substream mark rows differ") unless rows == value_rows

      null_map = read_mark_range_bytes(null_stream, null_start, null_end, checked_byte_count(rows, 1), 1)
      null_map.each do |value|
        raise CorruptPartError.new("Nullable null-map byte is not boolean") unless value == 0 || value == 1
      end

      encoded_values = read_mark_range_bytes(value_stream, value_start, value_end, checked_byte_count(rows, element_width), element_width)
      values = Array(T?).new(rows.to_i)
      offset = 0
      null_map.each do |is_null|
        values << (is_null == 1 ? nil : decode_numeric_value(encoded_values, offset, type))
        offset += element_width
      end
      raise CorruptPartError.new("Nullable values do not consume nested bytes") unless offset == encoded_values.size
      values
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
      each_uint64_mark_range_bytes(start_mark, end_mark, expected_bytes) do |bytes|
        source_offset = 0
        while source_offset < bytes.size
          available = scratch.size - chunk_size
          remaining = (bytes.size - source_offset) // 8
          copied = available < remaining ? available : remaining
          fill_uint64_scratch(scratch, chunk_size, bytes, source_offset, copied)
          chunk_size += copied
          source_offset += copied * 8
          if chunk_size == scratch.size
            yield scratch[0, chunk_size]
            chunk_size = 0
          end
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

      each_uint64_mark_range_bytes(start_mark, end_mark, expected_bytes) do |bytes|
        source_offset = 0
        while source_offset < bytes.size
          available = scratch.size - chunk_size
          remaining = (bytes.size - source_offset) // 8
          mark_remaining = (mark_rows - mark_values).to_i
          copied = available < remaining ? available : remaining
          copied = mark_remaining if mark_remaining < copied
          raise CorruptPartError.new("mark scan made no progress") if copied <= 0
          fill_uint64_scratch(scratch, chunk_size, bytes, source_offset, copied)
          chunk_size += copied
          source_offset += copied * 8
          mark_values += copied.to_u64

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
      end

      if chunk_size > 0
        mark_row_offset = mark_values - chunk_size.to_u64
        yield active_mark, mark_row_offset, mark_start &+ mark_row_offset, scratch[0, chunk_size]
      end
      nil
    end

    @column : String
    @source_column_name : String
    @source_column_type : String
    @json_typed_path : Bool
    @element_width : Int32
    @marks : Array(Mark)
    @sentinel : Mark
    @streams : Hash(String, PhysicalStream)

    private struct PhysicalStream
      getter name : String
      getter data_path : String
      getter mark_path : String
      getter marks : Array(Mark)
      getter sentinel : Mark

      def initialize(@name : String, @data_path : String, @mark_path : String, @marks : Array(Mark), @sentinel : Mark)
      end
    end

    private def initialize(path : String, requested_column : String?, mode : Symbol)
      @path = path
      raise InvalidPartError.new("part is not a directory") unless Dir.exists?(@path)
      @checksum_verification = ChecksumVerification::Unverified
      @column, @column_type, @source_column_name, @source_column_type, @json_typed_path, @row_count, physical_streams = parse_metadata(requested_column, mode)
      @streams = Hash(String, PhysicalStream).new
      expected_mark_rows = nil.as(Array(UInt64)?)
      physical_streams.each do |stream_name|
        validate_selected_stream_name(stream_name)
        data_path, mark_path, compressed_marks = resolve_stream(stream_name)
        data_size = File.size(data_path)
        raise CorruptPartError.new("data file exceeds limit") if data_size > MAX_DATA_FILE_BYTES
        element_width = stream_element_width(stream_name)
        marks, sentinel = parse_marks(mark_path, data_size, compressed_marks, element_width)
        validate_rows(marks)
        mark_rows = marks.map(&.rows)
        if expected = expected_mark_rows
          raise CorruptPartError.new("selected substreams have different mark row counts") unless mark_rows == expected
        else
          expected_mark_rows = mark_rows
        end
        @streams[stream_name] = PhysicalStream.new(stream_name, data_path, mark_path, marks, sentinel)
      end

      primary_stream = primary_stream_name(physical_streams)
      selected_stream = @streams[primary_stream]
      @data_path = selected_stream.data_path
      @mark_path = selected_stream.mark_path
      @marks = selected_stream.marks
      @sentinel = selected_stream.sentinel
      @element_width = stream_element_width(primary_stream)
    end

    private def parse_metadata(requested_column : String?, mode : Symbol) : {String, String, String, String, Bool, UInt64, Array(String)}
      columns_text = read_metadata_file("columns.txt")
      columns = parse_columns(columns_text)
      if columns.empty?
        raise UnsupportedFormatError.new("columns.txt contains no columns")
      end
      if requested_column.nil? && columns.size > 1
        raise UnsupportedFormatError.new("column is required for a multi-column part")
      end
      column = requested_column || columns[0][0]
      selected, source_column_name, source_column_type, column_type, json_typed_path =
        resolve_selected_column(columns, column)
      raise UnsupportedFormatError.new("JSON typed paths require the exact typed scan") if json_typed_path && mode != :typed
      case mode
      when :numeric
        numeric_type_width(column_type)
      when :typed
        raise UnsupportedFormatError.new("unsupported exact typed column") unless WidePart.supports_typed_type?(column_type)
      else
        raise UnsupportedFormatError.new("only exact UInt64 columns are supported") unless column_type == "UInt64"
      end

      json_paths = [] of {String, String}
      if json_typed_path
        json_paths = WidePart.json_typed_paths(source_column_type)
        validate_json_typed_path_serialization(source_column_name, json_paths)
      elsif column_type == "String" || WidePart.supports_nullable_numeric_type?(column_type)
        validate_type_serialization_version(column_type)
      end

      validate_default_codec

      row_count = parse_count_file("count.txt")
      raise CorruptPartError.new("row count exceeds limit") if row_count > MAX_ROWS

      physical_streams = parse_substreams(columns, selected, column_type, source_column_name, json_paths)
      {selected, column_type, source_column_name, source_column_type, json_typed_path, row_count, physical_streams}
    rescue ex : ArgumentError
      raise CorruptPartError.new("invalid metadata")
    end

    private def resolve_selected_column(
      columns : Array({String, String}),
      requested_column : String,
    ) : {String, String, String, String, Bool}
      exact = columns.find { |entry| entry[0] == requested_column }
      virtual = Array({String, String, String}).new
      columns.each do |entry|
        owner, owner_type = entry
        next unless WidePart.json_type?(owner_type)
        prefix = "#{owner}."
        next unless requested_column.starts_with?(prefix)
        path = requested_column.byte_slice(prefix.bytesize, requested_column.bytesize - prefix.bytesize)
        path_type = WidePart.json_typed_path_type(owner_type, path)
        virtual << {owner, owner_type, path_type.not_nil!} if path_type
      end

      if exact && !virtual.empty?
        raise UnsupportedFormatError.new("selected column is ambiguous between a literal dotted column and a JSON typed path")
      end
      if selected = exact
        return {selected[0], selected[0], selected[1], selected[1], false}
      end
      raise UnsupportedFormatError.new("selected column is not present") if virtual.empty?
      raise UnsupportedFormatError.new("selected JSON typed path is ambiguous") unless virtual.size == 1
      owner, owner_type, path_type = virtual[0]
      {requested_column, owner, owner_type, path_type, true}
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

    private def parse_substreams(
      columns : Array({String, String}),
      selected_column : String,
      selected_type : String,
      source_column : String = selected_column,
      json_paths : Array({String, String}) = [] of {String, String},
    ) : Array(String)
      file = File.join(@path, "columns_substreams.txt")
      unless File.exists?(file)
        raise UnsupportedFormatError.new("columns_substreams.txt is required for multi-column parts") unless columns.size == 1
        raise UnsupportedFormatError.new("columns_substreams.txt is required for JSON typed paths") unless json_paths.empty?
        expected_streams = expected_physical_streams(selected_column, selected_type)
        raise UnsupportedFormatError.new("columns_substreams.txt is required for this serialization shape") unless expected_streams == [selected_column]
        return [selected_column]
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
      selected_streams = nil.as(Array(String)?)
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
        if column == source_column
          if json_paths.empty?
            expected_streams = expected_physical_streams(column, selected_type)
            raise UnsupportedFormatError.new("selected physical substreams do not match exact serialization shape") unless streams == expected_streams
            selected_streams = streams
          else
            expected_json_streams = expected_json_typed_path_substreams(source_column, json_paths)
            raise UnsupportedFormatError.new("JSON physical substreams do not match declared typed-path shape") unless streams == expected_json_streams
            selected_streams = expected_physical_streams(selected_column, selected_type)
          end
        end
      end
      raise UnsupportedFormatError.new("trailing columns_substreams.txt data") unless cursor == bytes.size
      selected_streams || raise UnsupportedFormatError.new("selected column substreams are missing")
    end

    private def expected_json_typed_path_substreams(column : String, paths : Array({String, String})) : Array(String)
      streams = ["#{column}.object_structure"]
      paths.sort_by(&.[0]).each do |path, type|
        streams.concat(expected_physical_streams("#{column}.#{path}", type))
      end
      streams << "#{column}.object_shared_data.0.size0"
      streams << "#{column}.object_shared_data.0%2Epaths"
      streams << "#{column}.object_shared_data.0%2Evalues"
      streams
    end

    private def expected_physical_streams(column : String, type : String) : Array(String)
      if type == "String"
        ["#{column}.size", column]
      elsif WidePart.supports_nullable_numeric_type?(type)
        ["#{column}.null", column]
      else
        [column]
      end
    end

    private def validate_type_serialization_version(type : String) : Nil
      file = File.join(@path, "serialization.json")
      raise UnsupportedFormatError.new("serialization.json is required for this type") unless File.file?(file)
      raise CorruptPartError.new("serialization.json must not be a symbolic link") if File.symlink?(file)
      size = File.size(file)
      raise UnsupportedFormatError.new("serialization.json exceeds metadata limit") if size > MAX_METADATA_FILE_BYTES
      text = File.read(file)
      raise CorruptPartError.new("serialization.json changed while reading") unless text.bytesize == size

      info = JSON.parse(text).as_h
      info.each_key do |key|
        unless ["version", "columns", "types_serialization_versions", "propagate_types_serialization_versions_to_nested_types", "missing_columns"].includes?(key)
          raise UnsupportedFormatError.new("unsupported serialization.json field")
        end
      end

      version = info["version"]?.try(&.as_i) || raise(CorruptPartError.new("serialization.json version is missing or malformed"))
      raise UnsupportedFormatError.new("only serialization.json version 1 is supported") unless version == 1
      propagated = info["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool)
      raise UnsupportedFormatError.new("serialization.json nested-version flag is unsupported") unless propagated == true
      versions = info["types_serialization_versions"]?.try(&.as_h) || raise(CorruptPartError.new("serialization type versions are missing or malformed"))
      versions.each_key do |key|
        raise UnsupportedFormatError.new("unsupported serialization type version") unless key == "string"
      end

      if type == "String"
        string_version = versions["string"]?.try(&.as_i) || 0_i64
        raise UnsupportedFormatError.new("only String WITH_SIZE_STREAM version 1 is supported") unless string_version == 1
      elsif WidePart.supports_nullable_numeric_type?(type)
        nullable_version = versions["nullable"]?.try(&.as_i) || 0_i64
        raise UnsupportedFormatError.new("only basic Nullable serialization is supported") unless nullable_version == 0
      end
      nil
    rescue ex : JSON::ParseException | TypeCastError
      raise CorruptPartError.new("serialization.json is malformed")
    end

    private def validate_json_typed_path_serialization(column : String, paths : Array({String, String})) : Nil
      file = File.join(@path, "serialization.json")
      raise UnsupportedFormatError.new("serialization.json is required for JSON typed paths") unless File.file?(file)
      raise CorruptPartError.new("serialization.json must not be a symbolic link") if File.symlink?(file)
      size = File.size(file)
      raise UnsupportedFormatError.new("serialization.json exceeds metadata limit") if size > MAX_METADATA_FILE_BYTES
      text = File.read(file)
      raise CorruptPartError.new("serialization.json changed while reading") unless text.bytesize == size

      info = JSON.parse(text).as_h
      info.each_key do |key|
        unless ["version", "columns", "types_serialization_versions", "propagate_types_serialization_versions_to_nested_types", "missing_columns"].includes?(key)
          raise UnsupportedFormatError.new("unsupported JSON serialization.json field")
        end
      end
      version = info["version"]?.try(&.as_i) || raise(CorruptPartError.new("serialization.json version is missing or malformed"))
      raise UnsupportedFormatError.new("only JSON serialization.json version 1 is supported") unless version == 1
      propagated = info["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool)
      raise UnsupportedFormatError.new("JSON nested-version flag is unsupported") unless propagated == true

      columns = info["columns"]?.try(&.as_a) || raise(CorruptPartError.new("JSON serialization column metadata is missing or malformed"))
      raise UnsupportedFormatError.new("JSON serialization column metadata exceeds limit") if columns.size > MAX_METADATA_COLUMNS
      columns.each do |column_info|
        entry = column_info.as_h
        unless entry.keys.to_set == Set{"kind", "name", "num_defaults", "num_rows"}
          raise UnsupportedFormatError.new("unsupported JSON serialization column metadata")
        end
        raise UnsupportedFormatError.new("unsupported JSON serialization default kind") unless entry["kind"]?.try(&.as_s) == "Default"
        raise CorruptPartError.new("JSON serialization column name is malformed") if entry["name"]?.try(&.as_s).try(&.empty?) != false
        num_defaults = entry["num_defaults"]?.try(&.as_i) || raise(CorruptPartError.new("JSON serialization default count is malformed"))
        num_rows = entry["num_rows"]?.try(&.as_i) || raise(CorruptPartError.new("JSON serialization row count is malformed"))
        raise CorruptPartError.new("JSON serialization default count is invalid") if num_defaults < 0 || num_rows < num_defaults
      end

      versions = info["types_serialization_versions"]?.try(&.as_h) || raise(CorruptPartError.new("JSON serialization type versions are missing or malformed"))
      versions.each do |name, value|
        raise UnsupportedFormatError.new("unsupported JSON nested serialization type version") unless name == "string" && value.as_i? == 1
      end
      if paths.any? { |entry| entry[1] == "String" }
        raise UnsupportedFormatError.new("only String WITH_SIZE_STREAM version 1 is supported for JSON paths") unless versions["string"]?.try(&.as_i) == 1
      end

      validate_json_object_structure_prefix(column)
      nil
    rescue ex : JSON::ParseException | TypeCastError
      raise CorruptPartError.new("JSON serialization.json is malformed")
    end

    # ClickHouse stores the Object serialization version in the first
    # compressed object_structure frame, not in serialization.json. Decode
    # only that bounded frame and inspect its UInt64 prefix; this is not a
    # validation of the remaining structure or shared-data streams.
    private def validate_json_object_structure_prefix(column : String) : Nil
      data_path, _mark_path, _compressed_marks = resolve_stream("#{column}.object_structure")
      data_size = File.size(data_path)
      raise CorruptPartError.new("JSON object_structure data file exceeds limit") if data_size > MAX_DATA_FILE_BYTES
      raise CorruptPartError.new("JSON object_structure data file is truncated") if data_size < CompressedBlock::FRAME_HEADER_SIZE

      File.open(data_path, "rb") do |io|
        header = Bytes.new(CompressedBlock::FRAME_HEADER_SIZE)
        begin
          io.read_fully(header)
        rescue ex : IO::EOFError
          raise CorruptPartError.new("JSON object_structure frame header is truncated")
        end
        compressed_size = u32(header, CompressedBlock::CHECKSUM_SIZE + 1).to_i64
        frame_size = CompressedBlock::CHECKSUM_SIZE.to_i64 + compressed_size
        if compressed_size < CompressedBlock::HEADER_SIZE || compressed_size > MAX_FRAME_COMPRESSED_BYTES || frame_size > data_size
          raise CorruptPartError.new("JSON object_structure first frame is invalid")
        end
        frame_data = Bytes.new(frame_size.to_i)
        header.copy_to(frame_data)
        tail_size = frame_data.size - header.size
        begin
          io.read_fully(frame_data[header.size, tail_size]) if tail_size > 0
        rescue ex : IO::EOFError
          raise CorruptPartError.new("JSON object_structure first frame is truncated")
        end
        frame = CompressedBlock.decode_frame(
          frame_data,
          0_i64,
          MAX_FRAME_COMPRESSED_BYTES,
          MAX_FRAME_DECOMPRESSED_BYTES
        )
        raise CorruptPartError.new("JSON object_structure prefix is truncated") if frame.output.size < 8
        raise UnsupportedFormatError.new("only JSON Object structure version V3 is supported") unless u64(frame.output, 0) == 4_u64
      end
      nil
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
      raise InvalidPartError.new("selected numeric stream files not found")
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

    private def parse_marks(file : String, data_size : Int64, compressed : Bool, element_width : Int32) : {Array(Mark), Mark}
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
        raise CorruptPartError.new("mark decompressed offset is not column-type-aligned") unless decompressed % element_width.to_u64 == 0
        if rows == 0
          raise CorruptPartError.new("zero-row mark must be the sentinel") unless offset + MARK_SIZE == bytes.size
          raise CorruptPartError.new("EOF sentinel must have zero local offset") if compressed == data_size && decompressed != 0
        else
          raise CorruptPartError.new("mark row count exceeds frame limit") if rows > MAX_FRAME_DECOMPRESSED_BYTES.to_u64 // element_width.to_u64
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

    private def validate_rows(marks : Array(Mark))
      total = 0_u64
      marks.each do |mark|
        total = total &+ mark.rows
        raise CorruptPartError.new("row count overflow") if total < mark.rows
      end
      raise CorruptPartError.new("row count does not match marks") unless total == @row_count
    end

    private def primary_stream_name(stream_names : Array(String)) : String
      raise CorruptPartError.new("selected primary stream is missing") unless stream_names.includes?(@column)
      @column
    end

    private def stream_element_width(stream_name : String) : Int32
      if @column_type == "String"
        stream_name == "#{@column}.size" ? 8 : 1
      elsif WidePart.supports_nullable_numeric_type?(@column_type)
        stream_name == "#{@column}.null" ? 1 : numeric_type_width(nullable_inner_type(@column_type))
      else
        numeric_type_width(@column_type)
      end
    end

    private def nullable_inner_type(type : String) : String
      raise UnsupportedFormatError.new("exact Nullable primitive type required") unless WidePart.supports_nullable_numeric_type?(type)
      type.byte_slice("Nullable(".bytesize, type.bytesize - "Nullable()".bytesize)
    end

    private def read_string_sizes(column : String, first_mark : Int, mark_count : Int) : {Array(UInt64), UInt64}
      size_stream = @streams["#{column}.size"]
      size_start, size_end, rows = checked_stream_mark_range(size_stream, first_mark, mark_count)
      encoded_sizes = read_mark_range_bytes(size_stream, size_start, size_end, checked_byte_count(rows, 8), 8)
      sizes = Array(UInt64).new(rows.to_i)
      total_bytes = 0_u64
      offset = 0
      while offset < encoded_sizes.size
        size = u64(encoded_sizes, offset)
        raise CorruptPartError.new("String size exceeds selected data limit") if size > MAX_DATA_FILE_BYTES.to_u64 - total_bytes
        raise CorruptPartError.new("String read range exceeds materialization limit") if size > MAX_STRING_RANGE_BYTES.to_u64 - total_bytes
        total_bytes += size
        sizes << size
        offset += 8
      end
      {sizes, total_bytes}
    end

    private def ensure_column(column : String)
      raise UnsupportedFormatError.new("column is not present") unless column == @column
    end

    private def ensure_uint64_column(column : String)
      ensure_column(column)
      raise UnsupportedFormatError.new("UInt64 accessor requires an exact UInt64 column") unless @column_type == "UInt64"
    end

    private def checked_mark_range(column : String, first_mark : Int, mark_count : Int) : {Mark?, Mark, Int32}
      ensure_uint64_column(column)
      checked_mark_range(column, first_mark, mark_count, 8)
    end

    private def checked_numeric_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
      expected_type : String,
      element_width : Int32,
    ) : {Mark?, Mark, Int32}
      ensure_column(column)
      raise UnsupportedFormatError.new("typed accessor does not match selected column type") unless @column_type == expected_type
      checked_mark_range(column, first_mark, mark_count, element_width)
    end

    private def checked_mark_range(column : String, first_mark : Int, mark_count : Int, element_width : Int32) : {Mark?, Mark, Int32}
      raise BoundsError.new("negative mark range") if first_mark < 0 || mark_count < 0
      raise BoundsError.new("empty mark range") if mark_count == 0
      raise BoundsError.new("mark range exceeds data marks") if first_mark > @marks.size || mark_count > @marks.size - first_mark

      start_mark = @marks[first_mark] if first_mark < @marks.size
      end_index = first_mark + mark_count
      end_mark = end_index == @marks.size ? @sentinel : @marks[end_index]
      expected_rows = rows_in_range(first_mark, mark_count)
      expected_bytes = checked_byte_count(expected_rows, element_width).to_i32
      {start_mark, end_mark, expected_bytes}
    end

    private def checked_stream_mark_range(stream : PhysicalStream, first_mark : Int, mark_count : Int) : {Mark, Mark, UInt64}
      raise BoundsError.new("negative mark range") if first_mark < 0 || mark_count < 0
      raise BoundsError.new("empty mark range") if mark_count == 0
      marks = stream.marks
      raise BoundsError.new("mark range exceeds data marks") if first_mark > marks.size || mark_count > marks.size - first_mark
      start_mark = marks[first_mark]
      end_index = first_mark + mark_count
      end_mark = end_index == marks.size ? stream.sentinel : marks[end_index]
      expected_rows = rows_in_range(marks, first_mark, mark_count)
      {start_mark, end_mark, expected_rows}
    end

    private def read_mark_range_bytes(
      stream : PhysicalStream,
      start_mark : Mark,
      end_mark : Mark,
      expected_bytes : Int,
      element_width : Int32,
    ) : Bytes
      raise CorruptPartError.new("selected byte count exceeds limit") if expected_bytes < 0 || expected_bytes > MAX_DATA_FILE_BYTES
      output = Bytes.new(expected_bytes)
      offset = 0
      each_mark_range_bytes(stream, start_mark, end_mark, expected_bytes, element_width) do |chunk|
        raise CorruptPartError.new("selected byte count exceeds allocation") if chunk.size > output.size - offset
        chunk.copy_to(output.to_unsafe + offset, chunk.size)
        offset += chunk.size
      end
      raise CorruptPartError.new("selected byte count mismatch") unless offset == output.size
      output
    end

    private def rows_in_range(first_mark : Int, count : Int) : UInt64
      rows_in_range(@marks, first_mark, count)
    end

    private def rows_in_range(marks : Array(Mark), first_mark : Int, count : Int) : UInt64
      total = 0_u64
      count.times do |index|
        rows = marks[first_mark + index].rows
        total = total &+ rows
        raise CorruptPartError.new("mark range row count overflow") if total < rows
      end
      total
    end

    private def checked_byte_count(rows : UInt64, element_width : Int32) : Int
      width = element_width.to_u64
      raise CorruptPartError.new("row byte count overflow") if width == 0 || rows > (Int32::MAX.to_u64 / width)
      (rows * width).to_i
    end

    private def numeric_type_width(type : String) : Int32
      case type
      when "UInt8", "Int8"
        1
      when "UInt16", "Int16"
        2
      when "UInt32", "Int32", "Float32"
        4
      when "UInt64", "Int64", "Float64"
        8
      else
        raise UnsupportedFormatError.new("only exact fixed-width primitive numeric columns are supported")
      end
    end

    private def decode_numeric_value(bytes : Bytes, offset : Int, type : T.class) : T forall T
      {% if T == UInt8 %}
        bytes[offset]
      {% elsif T == UInt16 %}
        u16(bytes, offset)
      {% elsif T == UInt32 %}
        u32(bytes, offset)
      {% elsif T == UInt64 %}
        u64(bytes, offset)
      {% elsif T == Int8 %}
        bytes[offset].unsafe_as(Int8)
      {% elsif T == Int16 %}
        u16(bytes, offset).unsafe_as(Int16)
      {% elsif T == Int32 %}
        u32(bytes, offset).unsafe_as(Int32)
      {% elsif T == Int64 %}
        u64(bytes, offset).unsafe_as(Int64)
      {% elsif T == Float32 %}
        u32(bytes, offset).unsafe_as(Float32)
      {% elsif T == Float64 %}
        u64(bytes, offset).unsafe_as(Float64)
      {% else %}
        raise UnsupportedFormatError.new("only exact fixed-width primitive numeric accessors are supported")
      {% end %}
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
      each_mark_range_bytes(start_mark, end_mark, expected_bytes, 8) do |bytes|
        yield bytes
      end
    end

    private def each_mark_range_bytes(
      start_mark : Mark?,
      end_mark : Mark,
      expected_bytes : Int,
      element_width : Int32,
      & : Bytes -> Nil
    ) : Nil
      raise BoundsError.new("empty mark range") unless start_mark
      each_mark_range_bytes(@streams[@column], start_mark.not_nil!, end_mark, expected_bytes, element_width) do |bytes|
        yield bytes
      end
    end

    private def each_mark_range_bytes(
      stream : PhysicalStream,
      start_mark : Mark,
      end_mark : Mark,
      expected_bytes : Int,
      element_width : Int32,
      & : Bytes -> Nil
    ) : Nil
      data_size = File.size(stream.data_path)
      raise CorruptPartError.new("data file exceeds limit") if data_size > MAX_DATA_FILE_BYTES
      MMapDataSource.with_file(stream.data_path, data_size, MAX_DATA_FILE_BYTES) do |data|
        start_offset = start_mark.compressed_offset
        end_offset = end_mark.compressed_offset
        eof_sentinel = end_mark == stream.sentinel && end_offset == data_size.to_u64 && end_mark.decompressed_offset == 0
        raise CorruptPartError.new("mark frame offset exceeds data") if start_offset >= data_size || end_offset > data_size || end_offset == data_size && !eof_sentinel
        raise CorruptPartError.new("mark frame offsets are reversed") if start_offset > end_offset

        selected_bytes = 0_i64
        frame_offset = start_offset.to_i64
        started = false
        workspace = CompressedBlock::DecodeWorkspace.new
        loop do
          frame = CompressedBlock.decode_frame_into(
            data,
            frame_offset,
            workspace,
            MAX_FRAME_COMPRESSED_BYTES,
            MAX_FRAME_DECOMPRESSED_BYTES
          )
          current = frame_offset.to_u64
          started ||= current == start_offset
          raise CorruptPartError.new("mark does not start at a frame") unless started
          local_start = current == start_offset ? start_mark.decompressed_offset : 0_u64
          local_end = current == end_offset ? end_mark.decompressed_offset : frame.output.size.to_u64
          raise CorruptPartError.new("mark offset exceeds frame output") if local_start > frame.output.size || local_end > frame.output.size || local_start > local_end
          if current == end_offset && end_mark == stream.sentinel && !eof_sentinel
            raise CorruptPartError.new("non-EOF sentinel must end at frame output") unless end_mark.decompressed_offset == frame.output.size
          end
          selected_size = (local_end - local_start).to_i64
          raise CorruptPartError.new("selected data exceeds expected byte count") if selected_size > expected_bytes.to_i64 - selected_bytes
          raise CorruptPartError.new("numeric bytes are not column-type-aligned") unless selected_size % element_width == 0
          yield frame.output[local_start.to_i, selected_size.to_i] if selected_size > 0
          selected_bytes += selected_size
          if current == end_offset
            raise CorruptPartError.new("data has trailing bytes after final frame") if end_mark == stream.sentinel && frame.end_offset != data_size
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

    private def u32(bytes : Bytes, offset : Int) : UInt32
      raise CorruptPartError.new("truncated integer") if offset < 0 || offset > bytes.size - 4
      value = 0_u32
      4.times { |index| value |= bytes[offset + index].to_u32 << (index * 8) }
      value
    end

    private def u16(bytes : Bytes, offset : Int) : UInt16
      raise CorruptPartError.new("truncated integer") if offset < 0 || offset > bytes.size - 2
      value = 0_u16
      2.times { |index| value |= bytes[offset + index].to_u16 << (index * 8) }
      value
    end

    private def fill_uint64_scratch(
      destination : Slice(UInt64),
      destination_offset : Int,
      source : Bytes,
      source_offset : Int,
      count : Int,
    ) : Nil
      return if count == 0

      {% if IO::ByteFormat::SystemEndian == IO::ByteFormat::LittleEndian %}
        # The destination is UInt64 storage; the source is deliberately byte-typed
        # because a decoded frame's base address need not be UInt64-aligned.
        destination_pointer = (destination.to_unsafe + destination_offset).unsafe_as(Pointer(UInt8))
        destination_pointer.copy_from(source.to_unsafe + source_offset, count * 8)
      {% else %}
        count.times do |index|
          destination[destination_offset + index] = u64(source, source_offset + index * 8)
        end
      {% end %}
      nil
    end
  end
end
