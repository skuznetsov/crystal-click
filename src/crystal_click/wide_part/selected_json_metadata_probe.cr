module CrystalClick
  class WidePart
    # Narrow metadata reader for table dispatch. It deliberately reads only
    # columns.txt, so unrelated physical codecs and Object declarations are
    # not interpreted when a scalar column is selected.
    private class SelectedJsonMetadataProbe
      def self.read(part_path : String, requested_column : String) : String?
        raise ArgumentError.new("selected column name must not be empty") if requested_column.empty?

        columns_path = File.join(part_path, "columns.txt")
        info = File.info?(columns_path, follow_symlinks: false) || raise(InvalidPartError.new("columns.txt is missing or inaccessible"))
        raise CorruptPartError.new("columns.txt must not be a symbolic link") if info.type.symlink?
        raise CorruptPartError.new("columns.txt is not a regular file") unless info.type.file?
        raise UnsupportedFormatError.new("columns.txt exceeds metadata limit") if info.size > WidePart::MAX_METADATA_FILE_BYTES
        text = File.read(columns_path)
        unless text.bytesize.to_i64 == info.size && !text.empty? && text.to_slice[text.bytesize - 1] == 10
          raise CorruptPartError.new("columns.txt changed while reading or is missing LF")
        end

        columns = parse_columns(text)
        exact = columns.find { |column| column[0] == requested_column }
        virtual_path_found = false
        columns.each do |column|
          next unless WidePart.json_type?(column[1])
          prefix = "#{column[0]}."
          next unless requested_column.starts_with?(prefix)
          path = requested_column.byte_slice(prefix.bytesize, requested_column.bytesize - prefix.bytesize)
          virtual_path_found ||= !WidePart.json_typed_path_type(column[1], path).nil?
        end

        if exact && virtual_path_found
          raise UnsupportedFormatError.new("selected column is ambiguous between a literal dotted column and a JSON typed path")
        end
        return nil unless selected = exact
        return nil unless WidePart.json_type?(selected[1])
        String.new(selected[1].to_slice)
      rescue ex : IO::Error
        raise InvalidPartError.new(ex.message || "cannot read selected JSON declaration")
      end

      private def self.parse_columns(text : String) : Array({String, String})
        bytes = text.to_slice
        cursor = 0
        header, cursor = metadata_line(bytes, cursor)
        raise UnsupportedFormatError.new("unsupported columns.txt") unless header == "columns format version: 1"
        count_line, cursor = metadata_line(bytes, cursor)
        match = /\A(0|[1-9][0-9]*) columns:\z/.match(count_line) || raise(UnsupportedFormatError.new("invalid count in columns.txt"))
        count = match[1].to_i? || raise(UnsupportedFormatError.new("invalid count in columns.txt"))
        raise UnsupportedFormatError.new("columns.txt contains no columns") if count == 0
        raise UnsupportedFormatError.new("columns.txt exceeds the column limit") if count > WidePart::MAX_METADATA_COLUMNS

        columns = Array({String, String}).new(count)
        names = Array(String).new(count)
        count.times do
          line, cursor = metadata_line(bytes, cursor)
          name, type = parse_column_line(line)
          raise UnsupportedFormatError.new("duplicate column name") if names.includes?(name)
          names << name
          columns << {name, type}
        end
        raise UnsupportedFormatError.new("trailing columns.txt data") unless cursor == bytes.size
        columns
      end

      private def self.metadata_line(bytes : Bytes, cursor : Int) : {String, Int32}
        raise UnsupportedFormatError.new("truncated metadata line in columns.txt") if cursor < 0 || cursor >= bytes.size
        ending = cursor
        while ending < bytes.size && bytes[ending] != 10
          ending += 1
        end
        raise UnsupportedFormatError.new("truncated metadata line in columns.txt") if ending >= bytes.size
        length = ending - cursor + 1
        raise UnsupportedFormatError.new("line exceeds metadata limit in columns.txt") if length > WidePart::MAX_METADATA_LINE_BYTES
        {String.new(bytes[cursor, length - 1]), (cursor + length).to_i32}
      end

      private def self.parse_column_line(line : String) : {String, String}
        name, end_index = parse_quoted_name(line, 0)
        bytes = line.to_slice
        raise UnsupportedFormatError.new("invalid column type") if end_index >= bytes.size || bytes[end_index] != ' '.ord
        type = String.new(bytes[end_index + 1, bytes.size - end_index - 1])
        raise UnsupportedFormatError.new("invalid column type") if type.empty? || type.each_byte.any? { |byte| byte == 0 || byte == 13 }
        {name, type}
      end

      private def self.parse_quoted_name(line : String, start : Int) : {String, Int32}
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

      private def self.hex_digit(byte : UInt8) : UInt8?
        if byte >= '0'.ord && byte <= '9'.ord
          byte - '0'.ord
        elsif byte >= 'a'.ord && byte <= 'f'.ord
          byte - 'a'.ord + 10
        elsif byte >= 'A'.ord && byte <= 'F'.ord
          byte - 'A'.ord + 10
        end
      end
    end
  end
end
