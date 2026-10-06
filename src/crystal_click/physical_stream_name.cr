module CrystalClick
  # Bytewise ClickHouse filename escaping and bounded name construction.
  # Raw names and already-escaped prefixes deliberately use different entry
  # points: a raw percent is escaped to %25, never trusted as an escape.
  module PhysicalStreamName
    HEX = "0123456789ABCDEF"

    def self.escaped_size(raw : String) : UInt64
      size = 0_u64
      raw.to_slice.each do |byte|
        size = add_size(size, word_byte?(byte) ? 1_u64 : 3_u64)
      end
      size
    end

    def self.escaped_size(size : Int32, &byte_at : Int32 -> UInt8) : UInt64
      rendered_size = 0_u64
      size.times do |index|
        rendered_size = add_size(rendered_size, word_byte?(byte_at.call(index)) ? 1_u64 : 3_u64)
      end
      rendered_size
    end

    def self.escape(raw : String, context : PhysicalStreamPlanContext? = nil) : String
      expected_size = escaped_size(raw)
      context.try(&.preflight_name_bytes(expected_size))
      rendered = String.build(expected_size.to_i) do |io|
        raw.to_slice.each do |byte|
          if word_byte?(byte)
            io.write_byte(byte)
          else
            io.write_byte('%'.ord.to_u8)
            io.write_byte(HEX.byte_at((byte >> 4).to_i))
            io.write_byte(HEX.byte_at((byte & 0x0f).to_i))
          end
        end
      end
      rendered
    end

    # Append a raw field as ClickHouse does for a TupleElement: the separator
    # dot is part of the escaped field, not a structural filename dot.
    def self.append_escaped_field(prefix : String, raw_field : String, context : PhysicalStreamPlanContext? = nil) : String
      field_size = add_size(3_u64, escaped_size(raw_field))
      total_size = add_size(prefix.bytesize.to_u64, field_size)
      context.try(&.preflight_name_bytes(total_size))
      String.build(total_size.to_i) do |io|
        io << prefix
        io << "%2E"
        raw_field.to_slice.each do |byte|
          if word_byte?(byte)
            io.write_byte(byte)
          else
            io.write_byte('%'.ord.to_u8)
            io.write_byte(HEX.byte_at((byte >> 4).to_i))
            io.write_byte(HEX.byte_at((byte & 0x0f).to_i))
          end
        end
      end
    end

    # Append an escaped Object path or Variant type name. Its leading dot is
    # structural, unlike the dot included in an escaped Tuple field.
    def self.append_escaped_component(prefix : String, raw_component : String, context : PhysicalStreamPlanContext? = nil) : String
      component_size = escaped_size(raw_component)
      total_size = add_size(prefix.bytesize.to_u64, add_size(1_u64, component_size))
      context.try(&.preflight_name_bytes(total_size))
      String.build(total_size.to_i) do |io|
        io << prefix << '.'
        raw_component.to_slice.each do |byte|
          if word_byte?(byte)
            io.write_byte(byte)
          else
            io.write_byte('%'.ord.to_u8)
            io.write_byte(HEX.byte_at((byte >> 4).to_i))
            io.write_byte(HEX.byte_at((byte & 0x0f).to_i))
          end
        end
      end
    end

    def self.append_literal(prefix : String, suffix : String, context : PhysicalStreamPlanContext? = nil) : String
      total_size = add_size(prefix.bytesize.to_u64, suffix.bytesize.to_u64)
      context.try(&.preflight_name_bytes(total_size))
      String.build(total_size.to_i) do |io|
        io << prefix << suffix
      end
    end

    # Validate a pre-rendered prefix before accepting it as trusted syntax.
    # Structural dots remain literal; separators and all opaque bytes must be
    # represented by uppercase %HH escapes.
    def self.validate_escaped_prefix(prefix : String) : Nil
      bytes = prefix.to_slice
      index = 0
      while index < bytes.size
        byte = bytes[index]
        if byte == '%'.ord.to_u8
          if index + 2 >= bytes.size || !uppercase_hex?(bytes[index + 1]) || !uppercase_hex?(bytes[index + 2])
            raise ArgumentError.new("escaped physical prefix contains a malformed percent escape")
          end
          index += 3
        elsif word_byte?(byte) || byte == '.'.ord.to_u8
          index += 1
        else
          raise ArgumentError.new("escaped physical prefix contains an unescaped separator or opaque byte")
        end
      end
      nil
    end

    # Validate a rendered prefix that will be reused by a nested site. Every
    # escaped byte must be canonical: bytes normally emitted literally by
    # `escape` may not be hidden behind `%HH`. Structural dots remain literal.
    def self.validate_canonical_escaped_prefix(prefix : String) : Nil
      if prefix.empty?
        raise ArgumentError.new("escaped physical site prefix must not be empty")
      end
      validate_escaped_prefix(prefix)
      bytes = prefix.to_slice
      index = 0
      while index < bytes.size
        if bytes[index] == '%'.ord.to_u8
          decoded = (hex_value(bytes[index + 1]) << 4) | hex_value(bytes[index + 2])
          if word_byte?(decoded)
            raise ArgumentError.new("escaped physical prefix is not canonically encoded")
          end
          index += 3
        else
          index += 1
        end
      end
      nil
    end

    private def self.word_byte?(byte : UInt8) : Bool
      (byte >= 'A'.ord.to_u8 && byte <= 'Z'.ord.to_u8) ||
        (byte >= 'a'.ord.to_u8 && byte <= 'z'.ord.to_u8) ||
        (byte >= '0'.ord.to_u8 && byte <= '9'.ord.to_u8) ||
        byte == '_'.ord.to_u8
    end

    private def self.hex_value(byte : UInt8) : UInt8
      if byte >= '0'.ord.to_u8 && byte <= '9'.ord.to_u8
        byte - '0'.ord.to_u8
      elsif byte >= 'A'.ord.to_u8 && byte <= 'F'.ord.to_u8
        byte - 'A'.ord.to_u8 + 10_u8
      else
        raise ArgumentError.new("escaped physical prefix contains a malformed percent escape")
      end
    end

    private def self.uppercase_hex?(byte : UInt8) : Bool
      (byte >= '0'.ord.to_u8 && byte <= '9'.ord.to_u8) ||
        (byte >= 'A'.ord.to_u8 && byte <= 'F'.ord.to_u8)
    end

    private def self.add_size(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        raise UnsupportedFormatError.new("physical stream name size overflows UInt64")
      end
      left + right
    end
  end
end
