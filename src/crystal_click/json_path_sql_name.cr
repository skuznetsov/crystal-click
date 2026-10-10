module CrystalClick
  # Shared raw identity and canonical SQL spelling for flattened JSON paths.
  # This owns presentation only; descriptor and row codecs retain raw bytes.
  class JsonPathSqlName
    RESERVED_WORDS = [
      "inf", "infinity", "nan", "true", "false", "null", "distinct", "all",
      "some", "table", "select", "cube", "rollup", "recursive", "from",
      "top", "values", "skip",
    ]

    struct TokenMeasure
      getter token_start : Int32
      getter token_after : Int32
      getter content_start : Int32
      getter content_after : Int32
      getter decoded_bytes : UInt64
      getter quoted : Bool

      def initialize(
        @token_start : Int32,
        @token_after : Int32,
        @content_start : Int32,
        @content_after : Int32,
        @decoded_bytes : UInt64,
        @quoted : Bool,
      )
      end
    end

    def self.valid_raw_bytes?(bytes : Bytes) : Bool
      !bytes.empty?
    end

    def self.validate_raw_bytes!(bytes : Bytes) : Nil
      unless valid_raw_bytes?(bytes)
        raise ArgumentError.new("JSON path must contain at least one raw byte")
      end
    end

    # SKIP roster names use ClickHouse's `backQuoteIfNeed` presentation, where
    # the raw word SKIP is emitted bare after the SKIP clause. Typed-path
    # callers keep the default and quote that reserved word.
    def self.canonical_size(bytes : Bytes, quote_skip_keyword : Bool = true) : UInt64
      canonical_size(bytes.size, quote_skip_keyword) { |index| bytes[index] }
    end

    # Byte-at form lets descriptor owners measure escaped output without
    # materializing a path String before their shared budget preflight.
    def self.canonical_size(byte_size : Int32, quote_skip_keyword : Bool = true, &byte_at : Int32 -> UInt8) : UInt64
      validate_raw_size!(byte_size)
      return byte_size.to_u64 unless needs_quotes?(byte_size, quote_skip_keyword, &byte_at)

      size = 2_u64
      byte_size.times do |index|
        size += escaped_byte?(byte_at.call(index)) ? 2_u64 : 1_u64
      end
      size
    end

    def self.write_canonical(io : IO, bytes : Bytes, quote_skip_keyword : Bool = true) : Nil
      write_canonical(io, bytes.size, quote_skip_keyword) { |index| bytes[index] }
    end

    def self.write_canonical(io : IO, byte_size : Int32, quote_skip_keyword : Bool = true, &byte_at : Int32 -> UInt8) : Nil
      validate_raw_size!(byte_size)
      unless needs_quotes?(byte_size, quote_skip_keyword, &byte_at)
        byte_size.times { |index| io.write_byte(byte_at.call(index)) }
        return nil
      end

      io.write_byte('`'.ord.to_u8)
      byte_size.times do |index|
        byte = byte_at.call(index)
        escape = escaped_byte_as?(byte)
        if escape
          io.write_byte('\\'.ord.to_u8)
          io.write_byte(escape.not_nil!)
        else
          io.write_byte(byte)
        end
      end
      io.write_byte('`'.ord.to_u8)
      nil
    end

    # Scans either a bare SQL identifier or one backtick-quoted raw path.
    # The optional cap is on decoded raw bytes, not the longer SQL token.
    # Invalid syntax and token continuations return nil without allocation.
    def self.scan_token(source : Bytes, offset : Int32, max_raw_bytes : Int32? = nil) : TokenMeasure?
      return nil if offset < 0 || offset >= source.size

      if source[offset] == '`'.ord.to_u8
        index = offset + 1
        decoded = 0_u64
        while index < source.size
          byte = source[index]
          if byte == '`'.ord.to_u8
            return nil if decoded == 0_u64
            return nil unless token_boundary?(source, index + 1, quoted: true)
            return nil if exceeds_cap?(decoded, max_raw_bytes)
            return TokenMeasure.new(offset, index + 1, offset + 1, index, decoded, true)
          elsif byte == '\\'.ord.to_u8
            index += 1
            escaped = source[index]?
            return nil unless escaped
            return nil if decoded_escape(escaped).nil?
            decoded += 1_u64
            return nil if exceeds_cap?(decoded, max_raw_bytes)
            index += 1
          else
            decoded += 1_u64
            return nil if exceeds_cap?(decoded, max_raw_bytes)
            index += 1
          end
        end
        nil
      else
        return nil unless identifier_start?(source[offset])
        index = offset + 1
        while index < source.size && identifier_continue?(source[index])
          index += 1
        end
        return nil unless token_boundary?(source, index, quoted: false)
        decoded = (index - offset).to_u64
        return nil if exceeds_cap?(decoded, max_raw_bytes)
        TokenMeasure.new(offset, index, offset, index, decoded, false)
      end
    end

    # Revalidates the measured span and charges decoded bytes before creating
    # the retained String. Quoted input is decoded bytewise, preserving raw
    # UTF-8 and arbitrary non-UTF-8 identities without normalization.
    def self.decode_token(source : Bytes, measured : TokenMeasure, budget : BinaryCodecBudget) : String
      unless measured.decoded_bytes <= Int32::MAX.to_u64
        raise ArgumentError.new("JSON path token exceeds the supported byte domain")
      end
      verified = scan_token(source, measured.token_start, measured.decoded_bytes.to_i32) ||
                 raise ArgumentError.new("JSON path token measure is invalid")
      unless same_measure?(verified, measured)
        raise ArgumentError.new("JSON path token measure does not match its source")
      end

      budget.charge_wire_bytes(measured.decoded_bytes)
      unless measured.quoted
        return String.new(source[measured.content_start, measured.content_after - measured.content_start])
      end

      String.build do |io|
        index = measured.content_start
        while index < measured.content_after
          byte = source[index]
          if byte == '\\'.ord.to_u8
            index += 1
            byte = decoded_escape(source[index]?).not_nil!
          end
          io.write_byte(byte)
          index += 1
        end
      end
    end

    private def self.needs_quotes?(byte_size : Int32, quote_skip_keyword : Bool = true, &byte_at : Int32 -> UInt8) : Bool
      return false if !quote_skip_keyword && skip_keyword?(byte_size, &byte_at)
      return true unless identifier_start?(byte_at.call(0))
      (1...byte_size).each do |index|
        return true unless identifier_continue?(byte_at.call(index))
      end
      reserved_word?(byte_size, &byte_at)
    end

    private def self.skip_keyword?(byte_size : Int32, &byte_at : Int32 -> UInt8) : Bool
      return false unless byte_size == 4
      word = "skip".to_slice
      4.times do |index|
        return false unless ascii_lower(byte_at.call(index)) == word[index]
      end
      true
    end

    private def self.reserved_word?(byte_size : Int32, &byte_at : Int32 -> UInt8) : Bool
      RESERVED_WORDS.each do |word|
        next unless word.bytesize == byte_size
        matches = true
        byte_size.times do |index|
          if ascii_lower(byte_at.call(index)) != word.to_slice[index]
            matches = false
            break
          end
        end
        return true if matches
      end
      false
    end

    private def self.identifier_start?(byte : UInt8) : Bool
      (byte >= 'a'.ord.to_u8 && byte <= 'z'.ord.to_u8) ||
        (byte >= 'A'.ord.to_u8 && byte <= 'Z'.ord.to_u8) || byte == '_'.ord.to_u8
    end

    private def self.identifier_continue?(byte : UInt8) : Bool
      identifier_start?(byte) || (byte >= '0'.ord.to_u8 && byte <= '9'.ord.to_u8)
    end

    private def self.ascii_lower(byte : UInt8) : UInt8
      byte >= 'A'.ord.to_u8 && byte <= 'Z'.ord.to_u8 ? byte + 0x20_u8 : byte
    end

    private def self.escaped_byte?(byte : UInt8) : Bool
      !escaped_byte_as?(byte).nil?
    end

    private def self.escaped_byte_as?(byte : UInt8) : UInt8?
      case byte
      when 0x5c_u8 then 0x5c_u8
      when 0x60_u8 then 0x60_u8
      when 0x00_u8 then '0'.ord.to_u8
      when 0x08_u8 then 'b'.ord.to_u8
      when 0x0c_u8 then 'f'.ord.to_u8
      when 0x0a_u8 then 'n'.ord.to_u8
      when 0x0d_u8 then 'r'.ord.to_u8
      when 0x09_u8 then 't'.ord.to_u8
      else              nil
      end
    end

    private def self.decoded_escape(byte : UInt8?) : UInt8?
      case byte
      when 0x5c_u8       then 0x5c_u8
      when 0x60_u8       then 0x60_u8
      when '0'.ord.to_u8 then 0x00_u8
      when 'b'.ord.to_u8 then 0x08_u8
      when 'f'.ord.to_u8 then 0x0c_u8
      when 'n'.ord.to_u8 then 0x0a_u8
      when 'r'.ord.to_u8 then 0x0d_u8
      when 't'.ord.to_u8 then 0x09_u8
      else                    nil
      end
    end

    private def self.token_boundary?(source : Bytes, offset : Int32, quoted : Bool) : Bool
      return true if offset == source.size
      byte = source[offset]
      return true if whitespace?(byte) || byte == ','.ord.to_u8 || byte == ')'.ord.to_u8
      !quoted && byte == '='.ord.to_u8
    end

    private def self.whitespace?(byte : UInt8) : Bool
      byte == ' '.ord.to_u8 || byte == '\t'.ord.to_u8 || byte == '\r'.ord.to_u8 || byte == '\n'.ord.to_u8
    end

    private def self.exceeds_cap?(size : UInt64, maximum : Int32?) : Bool
      if maximum
        size > maximum.to_u64
      else
        false
      end
    end

    private def self.same_measure?(left : TokenMeasure, right : TokenMeasure) : Bool
      left.token_start == right.token_start &&
        left.token_after == right.token_after &&
        left.content_start == right.content_start &&
        left.content_after == right.content_after &&
        left.decoded_bytes == right.decoded_bytes &&
        left.quoted == right.quoted
    end

    private def self.validate_raw_size!(size : Int32) : Nil
      if size <= 0
        raise ArgumentError.new("JSON path must contain at least one raw byte")
      end
    end
  end
end
