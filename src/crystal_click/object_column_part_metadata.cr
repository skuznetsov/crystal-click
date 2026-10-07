require "json"

module CrystalClick
  # Shared bounded parser for columns.txt, columns_substreams.txt,
  # serialization.json, count.txt, and the normalized Object part codec.
  # It intentionally leaves declaration interpretation to its caller.
  class ObjectColumnPartMetadata
    MAX_METADATA_FILE_BYTES = 4 * 1024 * 1024
    MAX_METADATA_LINE_BYTES = 64 * 1024
    MAX_METADATA_COLUMNS    =  4_096
    MAX_METADATA_SUBSTREAMS = 65_536
    MAX_CODEC_FILE_BYTES    =     64
    MAX_ROWS                = WidePart::MAX_ROWS
    CODEC_LZ4               = "CODEC(LZ4)"

    getter source_declaration : String
    getter row_count : UInt64
    getter ordinary_profile : BinaryBulkProfile

    @part_path : String
    @column_name : String
    @checksums : PartChecksums
    @selected_stream_names : Array(String)

    def self.open(
      part_path : String,
      column_name : String,
      validate_source_declaration : Proc(String, Nil)? = nil,
      subcolumns_validator : Proc(Array(JSON::Any), UInt64, Nil)? = nil,
      require_selected_subcolumns : Bool = false,
    ) : ObjectColumnPartMetadata
      new(part_path, column_name, validate_source_declaration, subcolumns_validator, require_selected_subcolumns)
    end

    def initialize(
      part_path : String,
      column_name : String,
      validate_source_declaration : Proc(String, Nil)? = nil,
      @subcolumns_validator : Proc(Array(JSON::Any), UInt64, Nil)? = nil,
      @require_selected_subcolumns : Bool = false,
    )
      validate_part_directory!(part_path)
      raise ArgumentError.new("Object column name must not be empty") if column_name.empty?

      @part_path = File.expand_path(part_path)
      @column_name = String.new(column_name.to_slice)
      @checksums = PartChecksums.open(@part_path)
      @checksums.validate_selected_entries(@part_path, "count.txt", "serialization.json")

      columns = parse_columns(read_metadata_file("columns.txt", MAX_METADATA_FILE_BYTES))
      column_types = Hash(String, String).new(initial_capacity: columns.size)
      columns.each { |name, type| column_types[name] = type }
      declaration = column_types[@column_name]? ||
                    raise(UnsupportedFormatError.new("selected literal column is absent from columns.txt"))
      @source_declaration = String.new(declaration.to_slice)
      validate_source_declaration.try(&.call(@source_declaration))

      @row_count = parse_row_count(read_metadata_file("count.txt", 32))
      @selected_stream_names = parse_substreams(
        read_metadata_file("columns_substreams.txt", MAX_METADATA_FILE_BYTES),
        columns,
      )
      reject_selected_compressed_marks!(@selected_stream_names)
      validate_codec!(read_metadata_file("default_compression_codec.txt", MAX_CODEC_FILE_BYTES))
      @ordinary_profile = parse_serialization_profile(
        read_metadata_file("serialization.json", MAX_METADATA_FILE_BYTES),
        @row_count,
        column_types,
      )
    end

    def selected_stream_names : Array(String)
      @selected_stream_names.map { |name| String.new(name.to_slice) }
    end

    private def validate_part_directory!(part_path : String) : Nil
      raise CorruptPartError.new("part directory must not be a symbolic link") if File.symlink?(part_path)
      raise CorruptPartError.new("part path is not a directory") unless Dir.exists?(part_path)
      nil
    end

    private def read_metadata_file(name : String, maximum_size : Int) : String
      path = File.join(@part_path, name)
      raise CorruptPartError.new("#{name} must not be a symbolic link") if File.symlink?(path)
      raise CorruptPartError.new("#{name} is missing or not a regular file") unless File.file?(path)
      info = File.info(path)
      raise CorruptPartError.new("#{name} is not a regular file") unless info.file?
      size = info.size
      raise UnsupportedFormatError.new("#{name} exceeds metadata limit") if size < 0 || size > maximum_size
      text = File.read(path)
      raise CorruptPartError.new("#{name} changed while reading") unless text.bytesize == size
      text
    rescue ex : IO::Error
      raise CorruptPartError.new(ex.message || "cannot read #{name}")
    end

    private def parse_columns(text : String) : Array({String, String})
      bytes = text.to_slice
      cursor = 0
      line, cursor = next_metadata_line(bytes, cursor, "columns.txt")
      raise UnsupportedFormatError.new("unsupported columns.txt") unless line == "columns format version: 1"
      line, cursor = next_metadata_line(bytes, cursor, "columns.txt")
      count = parse_count_line(line, " columns:", MAX_METADATA_COLUMNS, "columns.txt")
      raise UnsupportedFormatError.new("columns.txt has no columns") if count == 0

      columns = Array({String, String}).new(count)
      seen = Hash(String, Bool).new(initial_capacity: count)
      count.times do
        line, cursor = next_metadata_line(bytes, cursor, "columns.txt")
        name, type = parse_column_line(line)
        raise CorruptPartError.new("columns.txt contains a duplicate column") if seen.has_key?(name)
        seen[name] = true
        columns << {name, type}
      end
      raise UnsupportedFormatError.new("columns.txt has trailing bytes") unless cursor == bytes.size
      columns
    end

    private def parse_substreams(text : String, columns : Array({String, String})) : Array(String)
      bytes = text.to_slice
      cursor = 0
      line, cursor = next_metadata_line(bytes, cursor, "columns_substreams.txt")
      raise UnsupportedFormatError.new("unsupported columns_substreams.txt") unless line == "columns substreams version: 1"
      line, cursor = next_metadata_line(bytes, cursor, "columns_substreams.txt")
      count = parse_count_line(line, " columns:", MAX_METADATA_COLUMNS, "columns_substreams.txt")
      unless count == columns.size
        raise CorruptPartError.new("columns_substreams.txt column count differs from columns.txt")
      end

      selected_names = [] of String
      total_substreams = 0
      columns.each do |column|
        line, cursor = next_metadata_line(bytes, cursor, "columns_substreams.txt")
        substream_count, column_name = parse_substream_header(line)
        unless column_name == column[0]
          raise CorruptPartError.new("columns_substreams.txt column order differs from columns.txt")
        end
        if substream_count > MAX_METADATA_SUBSTREAMS - total_substreams
          raise UnsupportedFormatError.new("columns_substreams.txt exceeds substream limit")
        end
        total_substreams += substream_count
        is_selected = column_name == @column_name
        selected_seen = Hash(String, Bool).new(initial_capacity: substream_count) if is_selected
        substream_count.times do
          line, cursor = next_metadata_line(bytes, cursor, "columns_substreams.txt")
          raise UnsupportedFormatError.new("invalid physical stream line") unless line.starts_with?("\t")
          stream_name = String.new(line.to_slice[1, line.bytesize - 1])
          validate_opaque_stream_name!(stream_name)
          if is_selected
            validate_selected_stream_name!(stream_name)
            seen = selected_seen.not_nil!
            if seen.has_key?(stream_name)
              raise CorruptPartError.new("selected columns_substreams roster contains a duplicate")
            end
            seen[stream_name] = true
            selected_names << stream_name
          end
        end
      end
      raise UnsupportedFormatError.new("columns_substreams.txt has trailing bytes") unless cursor == bytes.size
      selected_names
    end

    private def parse_serialization_profile(
      text : String,
      row_count : UInt64,
      columns : Hash(String, String),
    ) : BinaryBulkProfile
      info = JSON.parse(text).as_h
      required = Set{"version", "columns", "types_serialization_versions", "propagate_types_serialization_versions_to_nested_types"}
      unless required.all? { |key| info.has_key?(key) } && info.keys.all? { |key| required.includes?(key) }
        raise UnsupportedFormatError.new("unsupported Object serialization.json fields")
      end

      version = info["version"]?.try(&.as_i) || raise(CorruptPartError.new("serialization.json version is missing or malformed"))
      raise UnsupportedFormatError.new("only serialization.json version 1 is supported") unless version == 1
      propagated = info["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool)
      raise UnsupportedFormatError.new("Object nested serialization versions are unsupported") unless propagated == true

      versions = info["types_serialization_versions"]?.try(&.as_h) ||
                 raise(CorruptPartError.new("serialization type versions are missing or malformed"))
      unless versions.size == 1 && versions.has_key?("string")
        raise UnsupportedFormatError.new("only the global Object String serialization profile is supported")
      end
      string_version = versions["string"].as_i
      unless string_version == 0 || string_version == 1
        raise UnsupportedFormatError.new("Object String serialization version must be 0 or 1")
      end

      serializers = info["columns"]?.try(&.as_a) ||
                    raise(CorruptPartError.new("serialization column metadata is missing or malformed"))
      raise UnsupportedFormatError.new("serialization column metadata exceeds limit") if serializers.size > MAX_METADATA_COLUMNS
      seen_names = Hash(String, Bool).new(initial_capacity: serializers.size)
      serializers.each do |value|
        entry = value.as_h
        fields = entry.keys.to_set
        required_fields = Set{"kind", "name", "num_defaults", "num_rows"}
        extended_fields = required_fields.dup
        extended_fields << "exact_num_defaults"
        tuple_fields = required_fields.dup
        tuple_fields << "subcolumns"
        tuple_extended_fields = extended_fields.dup
        tuple_extended_fields << "subcolumns"
        accepted_fields = fields == required_fields || fields == extended_fields
        if @subcolumns_validator
          accepted_fields ||= fields == tuple_fields || fields == tuple_extended_fields
        end
        unless accepted_fields
          raise UnsupportedFormatError.new("unsupported Object serialization column metadata")
        end
        kind = entry["kind"]?.try(&.as_s) || raise(CorruptPartError.new("serializer kind is missing or malformed"))
        raise UnsupportedFormatError.new("only Default Object serializers are supported") unless kind == "Default"
        if exact = entry["exact_num_defaults"]?
          exact.as_bool
        end
        name = entry["name"]?.try(&.as_s) || raise(CorruptPartError.new("serializer name is missing or malformed"))
        if name.empty? || name.bytesize > MAX_METADATA_LINE_BYTES || !columns.has_key?(name) || seen_names.has_key?(name)
          raise CorruptPartError.new("serializer column name is invalid or duplicated")
        end
        seen_names[name] = true
        defaults = entry["num_defaults"]?.try(&.as_i) || raise(CorruptPartError.new("serializer default count is missing or malformed"))
        rows = entry["num_rows"]?.try(&.as_i) || raise(CorruptPartError.new("serializer row count is missing or malformed"))
        if defaults < 0 || rows < 0 || defaults > rows || rows.to_u64 > MAX_ROWS || rows.to_u64 != row_count
          raise CorruptPartError.new("serializer default or row count is outside the admitted part")
        end
        if name == @column_name && @require_selected_subcolumns && !entry.has_key?("subcolumns")
          raise UnsupportedFormatError.new("selected Tuple serializer is missing child metadata")
        end
        if raw_subcolumns = entry["subcolumns"]?
          unless name == @column_name
            raise UnsupportedFormatError.new("subcolumns metadata is supported only for the selected value column")
          end
          validator = @subcolumns_validator ||
                      raise UnsupportedFormatError.new("Tuple subcolumns metadata is unsupported for this Object reader")
          subcolumns = raw_subcolumns.as_a
          validator.call(subcolumns, row_count)
        end
      end

      string_version == 1 ? BinaryBulkProfile.with_size_stream : BinaryBulkProfile.single_stream
    rescue ex : JSON::ParseException | TypeCastError | OverflowError
      raise CorruptPartError.new("serialization.json is malformed")
    end

    private def validate_codec!(text : String) : Nil
      raise UnsupportedFormatError.new("only CODEC(LZ4) is supported for normalized Object parts") unless text == CODEC_LZ4
      nil
    end

    private def reject_selected_compressed_marks!(logical_names : Array(String)) : Nil
      logical_names.each do |logical_name|
        compressed_marks_name = "#{StreamName.hash(logical_name)}.cmrk2"
        if @checksums.entry(compressed_marks_name)
          raise UnsupportedFormatError.new("compressed marks are unsupported for selected Object streams")
        end
      end
      nil
    end

    private def parse_row_count(text : String) : UInt64
      text = String.new(text.to_slice[0, text.bytesize - 1]) if text.ends_with?("\n")
      parse_decimal(text, MAX_ROWS, "count.txt")
    end

    private def next_metadata_line(bytes : Bytes, cursor : Int, file : String) : {String, Int32}
      length = line_length(bytes, cursor, file)
      if length > MAX_METADATA_LINE_BYTES
        raise UnsupportedFormatError.new("line exceeds metadata limit in #{file}")
      end
      {String.new(bytes[cursor, length - 1]), cursor + length}
    end

    private def line_length(bytes : Bytes, cursor : Int, file : String) : Int32
      raise UnsupportedFormatError.new("truncated metadata line in #{file}") if cursor < 0 || cursor >= bytes.size
      index = cursor
      while index < bytes.size && bytes[index] != 10
        index += 1
      end
      raise UnsupportedFormatError.new("truncated metadata line in #{file}") if index >= bytes.size
      (index - cursor + 1).to_i32
    end

    private def parse_column_line(line : String) : {String, String}
      name, end_index = parse_quoted_name(line, 0)
      bytes = line.to_slice
      unless end_index < bytes.size && bytes[end_index] == ' '.ord
        raise UnsupportedFormatError.new("invalid column type")
      end
      type = String.new(bytes[end_index + 1, bytes.size - end_index - 1])
      if type.empty? || type.each_byte.any? { |byte| byte == 0 || byte == 13 }
        raise UnsupportedFormatError.new("invalid column type")
      end
      {name, type}
    end

    private def parse_substream_header(line : String) : {Int32, String}
      marker = " substreams for column "
      marker_index = line.index(marker)
      raise UnsupportedFormatError.new("invalid substream header") unless marker_index
      bytes = line.to_slice
      count_text = String.new(bytes[0, marker_index])
      count = parse_decimal(count_text, MAX_METADATA_SUBSTREAMS.to_u64, "columns_substreams.txt").to_i
      start = marker_index + marker.bytesize
      name, end_index = parse_quoted_name(line, start)
      unless end_index < bytes.size && bytes[end_index] == ':'.ord && end_index + 1 == bytes.size
        raise UnsupportedFormatError.new("invalid substream header")
      end
      {count, name}
    end

    private def parse_quoted_name(line : String, start : Int) : {String, Int32}
      bytes = line.to_slice
      unless start >= 0 && start < bytes.size && bytes[start] == '`'.ord
        raise UnsupportedFormatError.new("invalid quoted identifier")
      end
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
            if byte == 0 || byte == 10 || byte == 13
              raise UnsupportedFormatError.new("invalid quoted identifier")
            end
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

    private def parse_count_line(line : String, suffix : String, maximum : Int, file : String) : Int32
      raise UnsupportedFormatError.new("invalid count in #{file}") unless line.ends_with?(suffix)
      bytes = line.to_slice
      digits = String.new(bytes[0, bytes.size - suffix.bytesize])
      parse_decimal(digits, maximum.to_u64, file).to_i32
    end

    private def parse_decimal(text : String, maximum : UInt64, file : String) : UInt64
      if text.empty? || (text.bytesize > 1 && text.to_slice[0] == '0'.ord)
        raise UnsupportedFormatError.new("invalid count in #{file}")
      end
      value = 0_u64
      text.each_byte do |byte|
        unless byte >= '0'.ord && byte <= '9'.ord
          raise UnsupportedFormatError.new("invalid count in #{file}")
        end
        digit = (byte - '0'.ord).to_u64
        if value > (maximum - digit) // 10
          raise UnsupportedFormatError.new("count exceeds limit in #{file}")
        end
        value = value * 10 + digit
      end
      value
    end

    private def validate_opaque_stream_name!(name : String) : Nil
      if name.empty? || name.bytesize > MAX_METADATA_LINE_BYTES
        raise UnsupportedFormatError.new("invalid physical stream name")
      end
      name.each_byte do |byte|
        if byte < 0x20 || byte == 0x7f
          raise UnsupportedFormatError.new("invalid physical stream name")
        end
      end
      nil
    end

    private def validate_selected_stream_name!(name : String) : Nil
      validate_opaque_stream_name!(name)
      if name.includes?("/") || name.includes?("\\")
        raise UnsupportedFormatError.new("selected physical stream name is not a filename component")
      end
      nil
    end
  end
end
