module CrystalClick
  # Canonical bare Enum8/Enum16 declaration grammar and direct name renderer
  # for Object typed fields. The preflight borrows the input bytes and retains
  # only bounded scalar metadata; callers admit its map edges/nodes/decoded
  # label buffers before asking for materialized entries.
  module ObjectEnumDeclaration
    struct Preflight
      getter tag : UInt8
      getter byte_size : Int32
      getter entry_count : Int32
      getter decoded_label_bytes : UInt64

      @bytes : Bytes
      @first : Int32
      @after : Int32

      def initialize(
        @tag : UInt8,
        @byte_size : Int32,
        @entry_count : Int32,
        @decoded_label_bytes : UInt64,
        @bytes : Bytes,
        @first : Int32,
        @after : Int32,
      )
      end

      def materialize_entries : Array(BinaryEnumDefinition::Entry)
        ObjectEnumDeclaration.materialize_entries(self)
      end

      def source : Bytes
        @bytes
      end

      def first : Int32
        @first
      end

      def after : Int32
        @after
      end
    end

    private struct Scan
      getter tag : UInt8
      getter entry_count : Int32
      getter decoded_label_bytes : UInt64

      def initialize(@tag : UInt8, @entry_count : Int32, @decoded_label_bytes : UInt64)
      end
    end

    # Validate a complete canonical declaration without allocating label
    # strings, an entry table, or a cached type name. Duplicate labels remain
    # the immutable BinaryEnumDefinition owner's responsibility after budget
    # admission; strictly increasing codes reject duplicates without a set.
    def self.preflight_slice(bytes : Bytes, first : Int32, after : Int32) : Preflight?
      scan = scan_enum_entries(bytes, first, after) { |_label_first, _label_after, _code| }
      return nil unless scan
      Preflight.new(scan.tag, after - first, scan.entry_count, scan.decoded_label_bytes, bytes, first, after)
    end

    # Materialize only after callers preflight map node/element limits and the
    # two known decoded-label buffers (temporary entries plus owned labels).
    def self.materialize_entries(preflight : Preflight) : Array(BinaryEnumDefinition::Entry)
      # Preflight is publicly constructible and borrows mutable bytes. Recheck
      # all admission metadata before trusting its count as an allocation size.
      scan = scan_enum_entries(preflight.source, preflight.first, preflight.after) { |_label_first, _label_after, _code| }
      unless scan && scan_matches_preflight?(scan, preflight)
        raise ArgumentError.new("enum declaration changed after preflight")
      end

      entries = Array(BinaryEnumDefinition::Entry).new(preflight.entry_count)
      materialized_scan = scan_enum_entries(preflight.source, preflight.first, preflight.after) do |label_first, label_after, code|
        entries << {decode_enum_label(preflight.source, label_first, label_after), code}
        nil
      end
      unless materialized_scan && scan_matches_preflight?(materialized_scan, preflight)
        raise ArgumentError.new("enum declaration changed after preflight")
      end
      entries
    end

    private def self.scan_matches_preflight?(scan : Scan, preflight : Preflight) : Bool
      scan.tag == preflight.tag &&
        scan.entry_count == preflight.entry_count &&
        scan.decoded_label_bytes == preflight.decoded_label_bytes &&
        preflight.byte_size == preflight.after - preflight.first
    end

    # Count canonical output directly from the descriptor's borrowed-label
    # accessors. This does not allocate BinaryEnumDefinition#type_name.
    def self.byte_size_for(definition : BinaryEnumDefinition) : UInt64
      total = definition.width_bits == 8 ? 7_u64 : 8_u64
      definition.size.times do |index|
        total += 2_u64 unless index == 0
        total += 5_u64 + enum_code_byte_size(definition.code_at(index)).to_u64
        definition.label_byte_size(index).times do |byte_index|
          total += escaped_enum_byte?(definition.label_byte_at(index, byte_index)) ? 2_u64 : 1_u64
        end
      end
      total
    end

    # Render directly from the immutable descriptor, avoiding any intermediate
    # full type-name String during schema preflight or declaration emission.
    def self.append_name(io : IO, definition : BinaryEnumDefinition) : Nil
      io << (definition.width_bits == 8 ? "Enum8(" : "Enum16(")
      definition.size.times do |index|
        io << ", " unless index == 0
        io << '\''
        definition.label_byte_size(index).times do |byte_index|
          byte = definition.label_byte_at(index, byte_index)
          case byte
          when 0x00_u8 then io << "\\0"
          when 0x08_u8 then io << "\\b"
          when 0x09_u8 then io << "\\t"
          when 0x0a_u8 then io << "\\n"
          when 0x0c_u8 then io << "\\f"
          when 0x0d_u8 then io << "\\r"
          when 0x27_u8 then io << "\\'"
          when 0x5c_u8 then io << "\\\\"
          else              io.write_byte(byte)
          end
        end
        io << "' = " << definition.code_at(index)
      end
      io << ')'
      nil
    end

    private def self.scan_enum_entries(bytes : Bytes, first : Int32, after : Int32, &block : Int32, Int32, Int16 -> Nil) : Scan?
      return nil if first < 0 || after < first || after > bytes.size
      tag, prefix = if slice_equals?(bytes, first, first + "Enum8(".bytesize, "Enum8(")
                      {BinaryDataType::TAG_ENUM8, "Enum8(".bytesize}
                    elsif slice_equals?(bytes, first, first + "Enum16(".bytesize, "Enum16(")
                      {BinaryDataType::TAG_ENUM16, "Enum16(".bytesize}
                    else
                      return nil
                    end
      return nil if after - first <= prefix || bytes[after - 1] != ')'.ord.to_u8

      minimum = tag == BinaryDataType::TAG_ENUM8 ? -128 : -32_768
      maximum = tag == BinaryDataType::TAG_ENUM8 ? 127 : 32_767
      body_after = after - 1
      cursor = first + prefix
      previous_code : Int32? = nil
      count = 0
      decoded_bytes = 0_u64

      while cursor < body_after
        return nil unless bytes[cursor] == '\''.ord.to_u8
        label_first = cursor + 1
        cursor = label_first
        while cursor < body_after && bytes[cursor] != '\''.ord.to_u8
          byte = bytes[cursor]
          if byte == '\\'.ord.to_u8
            return nil if cursor + 1 >= body_after
            return nil unless valid_enum_escape?(bytes[cursor + 1])
            cursor += 2
            decoded_bytes += 1_u64
          else
            return nil if canonical_enum_escape_byte?(byte)
            cursor += 1
            decoded_bytes += 1_u64
          end
        end
        return nil if cursor >= body_after
        label_after = cursor
        cursor += 1
        return nil unless slice_equals?(bytes, cursor, cursor + 3, " = ")
        cursor += 3

        code_first = cursor
        while cursor < body_after && bytes[cursor] != ','.ord.to_u8
          cursor += 1
        end
        code = parse_code(bytes, code_first, cursor, minimum, maximum) || return nil
        return nil if previous_code && code <= previous_code
        previous_code = code
        count += 1
        return nil if count > maximum - minimum + 1
        yield label_first, label_after, code.to_i16

        break if cursor == body_after
        return nil unless cursor + 2 < body_after && bytes[cursor + 1] == ' '.ord.to_u8
        cursor += 2
        return nil if cursor >= body_after
      end

      return nil if count == 0 || cursor != body_after
      Scan.new(tag, count, decoded_bytes)
    end

    private def self.parse_code(bytes : Bytes, first : Int32, after : Int32, minimum : Int32, maximum : Int32) : Int32?
      return nil if first >= after
      negative = bytes[first] == '-'.ord.to_u8
      digits_first = negative ? first + 1 : first
      return nil if digits_first >= after
      return nil if after - digits_first > 1 && bytes[digits_first] == '0'.ord.to_u8

      magnitude = 0
      index = digits_first
      limit = negative ? -minimum : maximum
      while index < after
        byte = bytes[index]
        return nil if byte < '0'.ord.to_u8 || byte > '9'.ord.to_u8
        digit = (byte - '0'.ord.to_u8).to_i
        return nil if magnitude > (limit - digit) // 10
        magnitude = magnitude * 10 + digit
        index += 1
      end
      return nil if negative && magnitude == 0
      code = negative ? -magnitude : magnitude
      return nil if code < minimum || code > maximum
      code
    end

    private def self.decode_enum_label(bytes : Bytes, first : Int32, after : Int32) : String
      String.build do |io|
        index = first
        while index < after
          byte = bytes[index]
          if byte == '\\'.ord.to_u8
            index += 1
            io.write_byte(decoded_enum_escape(bytes[index]))
          else
            io.write_byte(byte)
          end
          index += 1
        end
      end
    end

    private def self.valid_enum_escape?(byte : UInt8) : Bool
      byte == '0'.ord.to_u8 || byte == 'b'.ord.to_u8 || byte == 't'.ord.to_u8 ||
        byte == 'n'.ord.to_u8 || byte == 'f'.ord.to_u8 || byte == 'r'.ord.to_u8 ||
        byte == '\''.ord.to_u8 || byte == '\\'.ord.to_u8
    end

    private def self.decoded_enum_escape(byte : UInt8) : UInt8
      case byte
      when '0'.ord.to_u8  then 0x00_u8
      when 'b'.ord.to_u8  then 0x08_u8
      when 't'.ord.to_u8  then 0x09_u8
      when 'n'.ord.to_u8  then 0x0a_u8
      when 'f'.ord.to_u8  then 0x0c_u8
      when 'r'.ord.to_u8  then 0x0d_u8
      when '\''.ord.to_u8 then 0x27_u8
      when '\\'.ord.to_u8 then 0x5c_u8
      else
        raise ArgumentError.new("invalid canonical enum escape")
      end
    end

    private def self.canonical_enum_escape_byte?(byte : UInt8) : Bool
      byte == 0x00_u8 || byte == 0x08_u8 || byte == 0x09_u8 || byte == 0x0a_u8 ||
        byte == 0x0c_u8 || byte == 0x0d_u8
    end

    private def self.enum_code_byte_size(code : Int16) : Int32
      value = code.to_i32
      count = 0
      if value < 0
        count += 1
        value = -value
      end
      loop do
        count += 1
        value //= 10
        break if value == 0
      end
      count
    end

    private def self.escaped_enum_byte?(byte : UInt8) : Bool
      byte == 0x00_u8 || byte == 0x08_u8 || byte == 0x09_u8 || byte == 0x0a_u8 ||
        byte == 0x0c_u8 || byte == 0x0d_u8 || byte == 0x27_u8 || byte == 0x5c_u8
    end

    private def self.slice_equals?(bytes : Bytes, first : Int32, after : Int32, expected : String) : Bool
      return false if first < 0 || after < first || after > bytes.size
      return false unless after - first == expected.bytesize
      expected_bytes = expected.to_slice
      expected_bytes.size.times do |index|
        return false unless bytes[first + index] == expected_bytes[index]
      end
      true
    end
  end
end
