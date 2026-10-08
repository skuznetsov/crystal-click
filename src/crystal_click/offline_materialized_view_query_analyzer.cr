module CrystalClick
  # Bounded lexical analyzer for source references in a small SELECT subset.
  # Anything outside one source-free SELECT or one direct table FROM is
  # explicitly unknown rather than an incomplete edge list.
  class OfflineMaterializedViewQueryAnalyzer
    private struct Token
      getter value : String
      getter kind : Symbol
      getter depth : Int32

      def initialize(@value : String, @kind : Symbol, @depth : Int32)
      end

      def keyword?(word : String) : Bool
        @kind == :word && @value.compare(word, case_insensitive: true) == 0
      end

      def identifier? : Bool
        @kind == :word || @kind == :quoted_identifier
      end
    end

    FORBIDDEN_WORDS = Set(String).new(%w[WITH UNION INTERSECT EXCEPT JOIN IN])
    CLAUSE_WORDS    = Set(String).new(%w[WHERE PREWHERE GROUP HAVING ORDER LIMIT OFFSET SETTINGS FORMAT INTO WINDOW QUALIFY])

    def self.analyze(query : String, declaring_database : String) : Tuple(Array(OfflineTableReference), Symbol, String?)
      tokens = tokenize(query)
      return unknown("query contains unsupported or malformed lexical input") unless tokens
      return unknown("query is outside the supported SELECT subset") if tokens.empty? || !tokens.first.keyword?("SELECT")

      tokens.each_with_index do |token, index|
        if token.kind == :word && FORBIDDEN_WORDS.includes?(token.value.upcase)
          return unknown("query contains unsupported CTE, join, set, or IN relation syntax")
        end
        if token.keyword?("SELECT") && index != 0
          return unknown("query contains a nested SELECT")
        end
      end

      from_tokens = [] of Int32
      tokens.each_with_index do |token, index|
        from_tokens << index if token.keyword?("FROM")
      end
      return {[] of OfflineTableReference, :complete, nil} if from_tokens.empty?
      return unknown("query contains a nested or ambiguous FROM relation") unless from_tokens.size == 1

      from_index = from_tokens.first
      return unknown("query has no SELECT expression before FROM") if from_index <= 1
      return unknown("query contains a nested or ambiguous FROM relation") unless tokens[from_index].depth == 0

      cursor = from_index + 1
      return unknown("direct FROM table name is missing") if cursor >= tokens.size
      first = tokens[cursor]
      return unknown("direct FROM relation is not a simple table identifier") unless first.identifier?
      return unknown("direct FROM relation is a table function") if cursor + 1 < tokens.size && tokens[cursor + 1].value == "("

      cursor += 1
      database = declaring_database
      name = first.value
      qualified = false
      if cursor + 1 < tokens.size && tokens[cursor].value == "."
        second = tokens[cursor + 1]
        return unknown("qualified FROM relation is not a simple table identifier") unless second.identifier?
        database = first.value
        name = second.value
        qualified = true
        cursor += 2
        return unknown("multi-part FROM relation is unsupported") if cursor < tokens.size && tokens[cursor].value == "."
      end

      if cursor < tokens.size && tokens[cursor].keyword?("FINAL")
        cursor += 1
      end
      return unknown("SAMPLE relation modifiers are outside the supported source subset") if cursor < tokens.size && tokens[cursor].keyword?("SAMPLE")

      if cursor < tokens.size && tokens[cursor].keyword?("AS")
        cursor += 1
        return unknown("direct FROM alias is missing") if cursor >= tokens.size || !tokens[cursor].identifier?
        cursor += 1
      elsif cursor < tokens.size && tokens[cursor].identifier? && !clause_word?(tokens[cursor])
        cursor += 1
      end

      if cursor < tokens.size
        token = tokens[cursor]
        return unknown("direct FROM relation suffix is not a recognized clause boundary") unless token.depth == 0 && clause_word?(token)
      end

      reference = OfflineTableReference.new(database, name, qualified)
      {[reference], :complete, nil}
    rescue ex : UnsupportedFormatError
      unknown(ex.message || "query source identity is unsupported")
    rescue ex
      unknown("query source analysis failed closed")
    end

    private def self.unknown(reason : String) : Tuple(Array(OfflineTableReference), Symbol, String?)
      {[] of OfflineTableReference, :unknown, reason}
    end

    private def self.clause_word?(token : Token) : Bool
      token.kind == :word && CLAUSE_WORDS.includes?(token.value.upcase)
    end

    private def self.tokenize(query : String) : Array(Token)?
      bytes = query.to_slice
      tokens = [] of Token
      depth = 0
      index = 0

      while index < bytes.size
        byte = bytes[index]
        if whitespace?(byte)
          index += 1
        elsif byte == '\''.ord
          string_end = skip_string(bytes, index)
          return nil unless string_end >= 0
          tokens << Token.new("", :string_literal, depth)
          index = string_end
        elsif byte == '`'.ord || byte == '"'.ord
          parsed = parse_quoted_identifier(bytes, index, byte)
          return nil unless parsed
          value, index = parsed.not_nil!
          tokens << Token.new(value, :quoted_identifier, depth)
        elsif word_start?(byte)
          start = index
          index += 1
          while index < bytes.size && word_continue?(bytes[index])
            index += 1
          end
          tokens << Token.new(String.new(bytes[start, index - start]), :word, depth)
        elsif byte == '('.ord
          tokens << Token.new("(", :punctuation, depth)
          depth += 1
          index += 1
        elsif byte == ')'.ord
          depth -= 1
          return nil if depth < 0
          tokens << Token.new(")", :punctuation, depth)
          index += 1
        else
          tokens << Token.new(String.new(bytes[index, 1]), :punctuation, depth)
          index += 1
        end
      end

      return nil unless depth == 0
      tokens
    rescue ex
      nil
    end

    private def self.skip_string(bytes : Bytes, index : Int32) : Int32
      cursor = index + 1
      while cursor < bytes.size
        byte = bytes[cursor]
        if byte == '\\'.ord
          return -1 if cursor + 1 >= bytes.size
          cursor += 2
        elsif byte == '\''.ord
          if cursor + 1 < bytes.size && bytes[cursor + 1] == '\''.ord
            cursor += 2
          else
            return cursor + 1
          end
        else
          cursor += 1
        end
      end
      -1
    end

    private def self.parse_quoted_identifier(bytes : Bytes, index : Int32, quote : UInt8) : {String, Int32}?
      cursor = index + 1
      value = String.build do |io|
        closed = false
        while cursor < bytes.size
          byte = bytes[cursor]
          return nil if byte == '\\'.ord
          if byte == quote
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
        return nil unless closed
      end
      return nil if value.empty?
      {value, cursor}
    end

    private def self.whitespace?(byte : UInt8) : Bool
      byte == ' '.ord || byte == '\t'.ord || byte == '\r'.ord || byte == '\n'.ord
    end

    private def self.word_start?(byte : UInt8) : Bool
      byte == '_'.ord || byte == '$'.ord || byte >= 0x80 ||
        byte >= 'A'.ord && byte <= 'Z'.ord || byte >= 'a'.ord && byte <= 'z'.ord
    end

    private def self.word_continue?(byte : UInt8) : Bool
      word_start?(byte) || byte >= '0'.ord && byte <= '9'.ord
    end
  end
end
