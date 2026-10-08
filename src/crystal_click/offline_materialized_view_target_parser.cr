module CrystalClick
  # Parses only the persisted MATERIALIZED VIEW target prefix. It does not
  # resolve table identities; catalog resolution is a separate operation.
  class OfflineMaterializedViewTargetParser
    def self.consume(text : String, declaring_database : String) : {Int32, OfflineMaterializedViewTarget}?
      bytes = text.to_slice
      start = skip_whitespace(bytes, 0)
      return nil unless keyword_at?(bytes, start, "TO")

      cursor = skip_whitespace(bytes, start + 2)
      if keyword_at?(bytes, cursor, "INNER")
        cursor = skip_whitespace(bytes, cursor + 5)
        raise UnsupportedFormatError.new("INNER MATERIALIZED VIEW target is missing UUID") unless keyword_at?(bytes, cursor, "UUID")
        cursor = skip_whitespace(bytes, cursor + 4)
        uuid, cursor = parse_uuid_literal(bytes, cursor)
        consumed = cursor
        return {consumed, OfflineMaterializedViewTarget.inner_uuid(uuid)}
      end

      first, cursor = parse_identifier(bytes, cursor)
      cursor = skip_whitespace(bytes, cursor)
      qualified = false
      database = declaring_database
      name = first
      if cursor < bytes.size && bytes[cursor] == '.'.ord
        qualified = true
        second_start = skip_whitespace(bytes, cursor + 1)
        name, cursor = parse_identifier(bytes, second_start)
        database = first
        cursor = skip_whitespace(bytes, cursor)
      end

      uuid = nil.as(String?)
      if keyword_at?(bytes, cursor, "UUID")
        cursor = skip_whitespace(bytes, cursor + 4)
        uuid, cursor = parse_uuid_literal(bytes, cursor)
      end

      reference = OfflineTableReference.new(database, name, qualified)
      {cursor, OfflineMaterializedViewTarget.named(reference, uuid)}
    rescue ex : UnsupportedFormatError
      raise ex
    rescue ex
      raise UnsupportedFormatError.new("unsupported MATERIALIZED VIEW TO target")
    end

    private def self.parse_identifier(bytes : Bytes, index : Int32) : {String, Int32}
      raise UnsupportedFormatError.new("MATERIALIZED VIEW target identifier is missing") if index >= bytes.size
      quote = bytes[index]
      if quote == '`'.ord || quote == '"'.ord
        cursor = index + 1
        value = String.build do |io|
          closed = false
          while cursor < bytes.size
            byte = bytes[cursor]
            if byte == '\\'.ord
              raise UnsupportedFormatError.new("escaped MATERIALIZED VIEW target identifiers are unsupported")
            elsif byte == quote
              if cursor + 1 < bytes.size && bytes[cursor + 1] == quote
                io.write_byte(quote)
                cursor += 2
              else
                cursor += 1
                closed = true
                break
              end
            else
              io.write_byte(byte)
              cursor += 1
            end
          end
          raise UnsupportedFormatError.new("unterminated MATERIALIZED VIEW target identifier") unless closed
        end
        raise UnsupportedFormatError.new("empty MATERIALIZED VIEW target identifier") if value.empty?
        return {value, cursor}
      end

      return parse_error("MATERIALIZED VIEW target identifier is malformed") unless identifier_start?(quote)
      cursor = index + 1
      while cursor < bytes.size && identifier_continue?(bytes[cursor])
        cursor += 1
      end
      {String.new(bytes[index, cursor - index]), cursor}
    end

    private def self.parse_uuid_literal(bytes : Bytes, index : Int32) : {String, Int32}
      raise UnsupportedFormatError.new("MATERIALIZED VIEW target UUID literal is missing") if index >= bytes.size || bytes[index] != '\''.ord
      cursor = index + 1
      value = String.build do |io|
        closed = false
        while cursor < bytes.size
          byte = bytes[cursor]
          if byte == '\\'.ord
            raise UnsupportedFormatError.new("escaped MATERIALIZED VIEW target UUID is unsupported")
          elsif byte == '\''.ord
            if cursor + 1 < bytes.size && bytes[cursor + 1] == '\''.ord
              io.write_byte(byte)
              cursor += 2
            else
              cursor += 1
              closed = true
              break
            end
          else
            io.write_byte(byte)
            cursor += 1
          end
        end
        raise UnsupportedFormatError.new("unterminated MATERIALIZED VIEW target UUID") unless closed
      end
      {normalize_uuid(value), cursor}
    end

    private def self.normalize_uuid(value : String) : String
      unless /\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/.matches?(value)
        raise UnsupportedFormatError.new("invalid UUID in MATERIALIZED VIEW target")
      end
      value.downcase
    end

    private def self.keyword_at?(bytes : Bytes, index : Int32, keyword : String) : Bool
      return false if index < 0 || index + keyword.bytesize > bytes.size
      return false unless String.new(bytes[index, keyword.bytesize]).compare(keyword, case_insensitive: true) == 0
      after = index + keyword.bytesize
      after == bytes.size || !identifier_continue?(bytes[after])
    end

    private def self.skip_whitespace(bytes : Bytes, index : Int32) : Int32
      cursor = index
      while cursor < bytes.size && whitespace?(bytes[cursor])
        cursor += 1
      end
      cursor
    end

    private def self.identifier_start?(byte : UInt8) : Bool
      byte == '_'.ord || byte == '$'.ord || byte >= 0x80 ||
        byte >= 'A'.ord && byte <= 'Z'.ord || byte >= 'a'.ord && byte <= 'z'.ord
    end

    private def self.identifier_continue?(byte : UInt8) : Bool
      identifier_start?(byte) || byte >= '0'.ord && byte <= '9'.ord
    end

    private def self.whitespace?(byte : UInt8) : Bool
      byte == ' '.ord || byte == '\t'.ord || byte == '\r'.ord || byte == '\n'.ord
    end

    private def self.parse_error(message : String) : NoReturn
      raise UnsupportedFormatError.new(message)
    end
  end
end
