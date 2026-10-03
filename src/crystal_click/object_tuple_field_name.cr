module CrystalClick
  # Canonical spelling and bounded decoding for named Tuple fields in Object
  # declarations. Keeping this policy separate makes descriptor identity and
  # text parsing agree on quoted, escaped, and reserved identifiers.
  module ObjectTupleFieldName
    def self.append(io : IO, type : BinaryDataType, index : Int32) : Nil
      bare = bare?(type, index)
      unless bare
        io << '`'
      end
      type.field_name_byte_size(index).times do |byte_index|
        byte = type.field_name_byte_at(index, byte_index)
        if bare
          io.write_byte(byte)
        else
          case byte
          when 0x5c_u8 then io << "\\\\"
          when 0x60_u8 then io << "\\`"
          when 0x0a_u8 then io << "\\n"
          when 0x0d_u8 then io << "\\r"
          when 0x09_u8 then io << "\\t"
          when 0x08_u8 then io << "\\b"
          when 0x0c_u8 then io << "\\f"
          when 0x00_u8 then io << "\\0"
          else              io.write_byte(byte)
          end
        end
      end
      io << '`' unless bare
      nil
    end

    def self.rendered_size(type : BinaryDataType, index : Int32) : Int32
      bytes = type.field_name_byte_size(index)
      return bytes if bare?(type, index)
      total = 2
      bytes.times do |byte_index|
        byte = type.field_name_byte_at(index, byte_index)
        total += escaped?(byte) ? 2 : 1
      end
      total
    end

    def self.bare?(type : BinaryDataType, index : Int32) : Bool
      size = type.field_name_byte_size(index)
      return false if size == 0
      size.times do |byte_index|
        byte = type.field_name_byte_at(index, byte_index)
        return false unless byte_index == 0 ? identifier_start?(byte) : identifier_continue?(byte)
      end
      !reserved_type_name?(type, index)
    end

    # Returns {name_first, name_after, child_first} for a canonical named
    # Tuple field; bare and quoted fields use the same identity rules.
    def self.prefix(bytes : Bytes, first : Int32, after : Int32) : {Int32, Int32, Int32}?
      return nil if first >= after
      if bytes[first] == '`'.ord.to_u8
        index = first + 1
        escaped = false
        while index < after
          byte = bytes[index]
          if escaped
            escaped = false
          elsif byte == '\\'.ord.to_u8
            escaped = true
          elsif byte == '`'.ord.to_u8
            return nil unless index + 1 < after && bytes[index + 1] == ' '.ord.to_u8
            return {first, index + 1, index + 2}
          end
          index += 1
        end
        nil
      else
        index = first
        while index < after && identifier_continue?(bytes[index])
          index += 1
        end
        return nil if index == first || index >= after || bytes[index] != ' '.ord.to_u8
        name_after = index
        index += 1
        return nil if index >= after
        {first, name_after, index}
      end
    end

    # Returns {decoded_name_bytes, canonical_spelling_bytes}, or nil for a
    # malformed/noncanonical name. Parsing is bytewise and does not allocate.
    def self.shape(bytes : Bytes, first : Int32, after : Int32) : {UInt64, UInt64}?
      return nil if first < 0 || after <= first || after > bytes.size
      if bytes[first] == '`'.ord.to_u8
        return nil unless after > first + 1 && bytes[after - 1] == '`'.ord.to_u8
        decoded = 0_u64
        index = first + 1
        bare_identifier = true
        while index < after - 1
          byte = bytes[index]
          if byte == '\\'.ord.to_u8
            return nil if index + 1 >= after - 1
            escaped = bytes[index + 1]
            return nil unless valid_escape?(escaped)
            decoded_byte = decoded_escape(escaped)
            decoded += 1_u64
            bare_identifier = false unless decoded == 1_u64 ? identifier_start?(decoded_byte) : identifier_continue?(decoded_byte)
            index += 2
          else
            # BinaryDataType#format_field_name emits these bytes only through
            # the canonical backslash escapes below. Accepting them raw would
            # make preflight size differ from the identity-preserving render.
            return nil if escaped?(byte)
            decoded += 1_u64
            bare_identifier = false unless decoded == 1_u64 ? identifier_start?(byte) : identifier_continue?(byte)
            index += 1
          end
        end
        return nil if decoded == 0_u64
        needs_quotes = !bare_identifier || decoded_reserved?(bytes, first, after)
        return nil unless needs_quotes
        canonical = 2_u64
        index = first + 1
        while index < after - 1
          canonical += bytes[index] == '\\'.ord.to_u8 ? 2_u64 : 1_u64
          index += bytes[index] == '\\'.ord.to_u8 ? 2 : 1
        end
        {decoded, canonical}
      else
        size = after - first
        size.times do |offset|
          byte = bytes[first + offset]
          return nil unless offset == 0 ? identifier_start?(byte) : identifier_continue?(byte)
        end
        return nil if reserved_slice?(bytes, first, after)
        {size.to_u64, size.to_u64}
      end
    end

    def self.null?(bytes : Bytes, first : Int32, after : Int32) : Bool
      if bytes[first] == '`'.ord.to_u8
        decoded_equals?(bytes, first, after, "null")
      else
        after - first == 4 && slice_equals?(bytes, first, after, "null")
      end
    end

    def self.decode(bytes : Bytes, first : Int32, after : Int32) : String
      return String.new(bytes[first, after - first]) if bytes[first] != '`'.ord.to_u8
      String.build do |io|
        index = first + 1
        while index < after - 1
          byte = bytes[index]
          if byte == '\\'.ord.to_u8
            index += 1
            io.write_byte(decoded_escape(bytes[index]))
          else
            io.write_byte(byte)
          end
          index += 1
        end
      end
    end

    private def self.reserved_type_name?(type : BinaryDataType, index : Int32) : Bool
      RESERVED_WORDS.any? do |word|
        next false unless type.field_name_byte_size(index) == word.bytesize
        word.to_slice.each_with_index.all? do |byte, offset|
          ascii_lower(type.field_name_byte_at(index, offset)) == byte
        end
      end
    end

    private def self.reserved_slice?(bytes : Bytes, first : Int32, after : Int32) : Bool
      return false if bytes[first] == '`'.ord.to_u8
      RESERVED_WORDS.any? { |word| slice_case_equal?(bytes, first, after, word) }
    end

    private def self.decoded_reserved?(bytes : Bytes, first : Int32, after : Int32) : Bool
      RESERVED_WORDS.any? do |word|
        index = first + 1
        decoded_index = 0
        matches = true
        while index < after - 1
          byte = bytes[index]
          if byte == '\\'.ord.to_u8
            index += 1
            byte = decoded_escape(bytes[index])
          end
          if decoded_index >= word.bytesize || ascii_lower(byte) != word.to_slice[decoded_index]
            matches = false
            break
          end
          decoded_index += 1
          index += 1
        end
        matches && decoded_index == word.bytesize
      end
    end

    private def self.decoded_equals?(bytes : Bytes, first : Int32, after : Int32, expected : String) : Bool
      return false if after <= first + 1 || bytes[after - 1] != '`'.ord.to_u8
      index = first + 1
      decoded_index = 0
      while index < after - 1
        byte = bytes[index]
        if byte == '\\'.ord.to_u8
          index += 1
          return false if index >= after - 1 || !valid_escape?(bytes[index])
          byte = decoded_escape(bytes[index])
        end
        return false if decoded_index >= expected.bytesize || byte != expected.to_slice[decoded_index]
        decoded_index += 1
        index += 1
      end
      decoded_index == expected.bytesize
    end

    private def self.slice_case_equal?(bytes : Bytes, first : Int32, after : Int32, expected : String) : Bool
      return false if after - first != expected.bytesize
      expected.to_slice.each_with_index.all? do |byte, offset|
        ascii_lower(bytes[first + offset]) == byte
      end
    end

    private def self.slice_equals?(bytes : Bytes, first : Int32, after : Int32, expected : String) : Bool
      return false if first < 0 || after < first || after > bytes.size
      return false unless after - first == expected.bytesize
      expected.to_slice.each_with_index.all? { |byte, offset| bytes[first + offset] == byte }
    end

    private def self.identifier_start?(byte : UInt8) : Bool
      (byte >= 'a'.ord.to_u8 && byte <= 'z'.ord.to_u8) ||
        (byte >= 'A'.ord.to_u8 && byte <= 'Z'.ord.to_u8) || byte == '_'.ord.to_u8
    end

    private def self.identifier_continue?(byte : UInt8) : Bool
      identifier_start?(byte) || (byte >= '0'.ord.to_u8 && byte <= '9'.ord.to_u8)
    end

    private def self.escaped?(byte : UInt8) : Bool
      byte == 0x5c_u8 || byte == 0x60_u8 || byte == 0x0a_u8 || byte == 0x0d_u8 ||
        byte == 0x09_u8 || byte == 0x08_u8 || byte == 0x0c_u8 || byte == 0x00_u8
    end

    private def self.valid_escape?(byte : UInt8) : Bool
      byte == '\\'.ord.to_u8 || byte == '`'.ord.to_u8 || byte == 'n'.ord.to_u8 ||
        byte == 'r'.ord.to_u8 || byte == 't'.ord.to_u8 || byte == 'b'.ord.to_u8 ||
        byte == 'f'.ord.to_u8 || byte == '0'.ord.to_u8
    end

    private def self.decoded_escape(byte : UInt8) : UInt8
      case byte
      when '\\'.ord.to_u8 then '\\'.ord.to_u8
      when '`'.ord.to_u8  then '`'.ord.to_u8
      when 'n'.ord.to_u8  then 0x0a_u8
      when 'r'.ord.to_u8  then 0x0d_u8
      when 't'.ord.to_u8  then 0x09_u8
      when 'b'.ord.to_u8  then 0x08_u8
      when 'f'.ord.to_u8  then 0x0c_u8
      when '0'.ord.to_u8  then 0x00_u8
      else                     raise ArgumentError.new("invalid canonical Tuple field-name escape")
      end
    end

    private def self.ascii_lower(byte : UInt8) : UInt8
      byte >= 'A'.ord.to_u8 && byte <= 'Z'.ord.to_u8 ? byte + 32_u8 : byte
    end

    RESERVED_WORDS = {
      "inf", "infinity", "nan", "true", "false", "null", "distinct", "all", "some",
      "table", "select", "cube", "rollup", "recursive", "from", "top", "values",
    }
  end
end
