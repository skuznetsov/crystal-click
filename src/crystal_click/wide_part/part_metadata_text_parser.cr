module CrystalClick
  class WidePart
    private class PartMetadataTextParser
      def self.parse_columns(text : String) : Array({String, String})
        bytes = text.to_slice
        cursor = 0
        require_metadata_line(bytes, cursor, "columns format version: 1", "columns.txt")
        cursor += line_length(bytes, cursor)
        count_line = metadata_line(bytes, cursor, "columns.txt")
        cursor += line_length(bytes, cursor)
        count = parse_count_line(count_line, " columns:", WidePart::MAX_METADATA_COLUMNS, "columns.txt")
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

      def self.parse_count_line(line : String, suffix : String, limit : Int, file : String) : Int
        raise UnsupportedFormatError.new("invalid count in #{file}") unless line.ends_with?(suffix)
        line_bytes = line.to_slice
        digits = String.new(line_bytes[0, line_bytes.size - suffix.bytesize])
        value = parse_decimal(digits, limit.to_u64, file)
        value.to_i
      end

      def self.parse_decimal(text : String, limit : UInt64, file : String) : UInt64
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

      def self.metadata_line(bytes : Bytes, cursor : Int, file : String) : String
        length = line_length(bytes, cursor)
        raise UnsupportedFormatError.new("line exceeds metadata limit in #{file}") if length > WidePart::MAX_METADATA_LINE_BYTES
        String.new(bytes[cursor, length - 1])
      end

      def self.require_metadata_line(bytes : Bytes, cursor : Int, expected : String, file : String)
        raise UnsupportedFormatError.new("unsupported #{file}") unless metadata_line(bytes, cursor, file) == expected
      end

      def self.line_length(bytes : Bytes, cursor : Int) : Int
        raise UnsupportedFormatError.new("truncated metadata line") if cursor < 0 || cursor >= bytes.size
        index = cursor
        while index < bytes.size && bytes[index] != 10
          index += 1
        end
        raise UnsupportedFormatError.new("truncated metadata line") if index >= bytes.size
        index - cursor + 1
      end

      def self.parse_column_line(line : String) : {String, String}
        name, end_index = parse_quoted_name(line, 0)
        bytes = line.to_slice
        raise UnsupportedFormatError.new("invalid column type") if end_index >= bytes.size || bytes[end_index] != ' '.ord
        type_text = String.new(bytes[end_index + 1, bytes.size - end_index - 1])
        raise UnsupportedFormatError.new("invalid column type") if type_text.empty? || type_text.each_byte.any? { |byte| byte == 0 || byte == 13 }
        {name, type_text}
      end

      def self.parse_substream_header(line : String) : {Int32, String}
        marker = " substreams for column "
        marker_index = line.index(marker)
        raise UnsupportedFormatError.new("invalid substream header") unless marker_index
        line_bytes = line.to_slice
        count = parse_decimal(String.new(line_bytes[0, marker_index]), WidePart::MAX_METADATA_SUBSTREAMS.to_u64, "columns_substreams.txt").to_i
        start = marker_index + marker.bytesize
        name, end_index = parse_quoted_name(line, start)
        bytes = line.to_slice
        raise UnsupportedFormatError.new("invalid substream header") unless end_index < bytes.size && bytes[end_index] == ':'.ord
        raise UnsupportedFormatError.new("invalid substream header") unless end_index + 1 == bytes.size
        {count, name}
      end

      def self.parse_quoted_name(line : String, start : Int) : {String, Int32}
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

      def self.hex_digit(byte : UInt8) : UInt8?
        if byte >= '0'.ord && byte <= '9'.ord
          byte - '0'.ord
        elsif byte >= 'a'.ord && byte <= 'f'.ord
          byte - 'a'.ord + 10
        elsif byte >= 'A'.ord && byte <= 'F'.ord
          byte - 'A'.ord + 10
        end
      end

      def self.validate_opaque_name(name : String)
        raise UnsupportedFormatError.new("invalid physical stream name") if name.empty? || name.bytesize > WidePart::MAX_METADATA_LINE_BYTES
        name.each_byte do |byte|
          raise UnsupportedFormatError.new("invalid physical stream name") if byte < 0x20 || byte == 0x7f
        end
      end

      def self.validate_selected_stream_name(name : String)
        validate_opaque_name(name)
        if name.includes?("/") || name.includes?("\\")
          raise UnsupportedFormatError.new("selected physical stream name is not a filename component")
        end
      end
    end
  end
end
