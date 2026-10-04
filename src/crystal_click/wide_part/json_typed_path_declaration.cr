module CrystalClick
  class WidePart
    # Parses only the reader's bounded JSON typed-path declaration grammar.
    # Whole Object JSON schemas are parsed by ObjectDocumentSchema instead.
    private class JsonTypedPathDeclaration
      def self.parse(policy : T.class, type : String) : Array({String, String}) forall T
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
            add_path(policy, inner.byte_slice(start, index - start), declarations, seen)
            start = index + 1
          end
        end
        raise UnsupportedFormatError.new("malformed JSON typed-path declaration") unless depth == 0
        add_path(policy, inner.byte_slice(start, inner.bytesize - start), declarations, seen)
        declarations
      end

      private def self.add_path(
        policy : T.class,
        declaration : String,
        declarations : Array({String, String}),
        seen : Set(String),
      ) : Nil forall T
        match = /\A\s*([A-Za-z_][A-Za-z0-9_]*)\s+([A-Za-z0-9_]+)\s*\z/.match(declaration)
        raise UnsupportedFormatError.new("unsupported JSON typed-path declaration") unless match
        path = match[1]
        type = match[2]
        raise UnsupportedFormatError.new("duplicate JSON typed path") if seen.includes?(path)
        unless type == "String" || policy.supports_numeric_type?(type)
          raise UnsupportedFormatError.new("unsupported JSON typed-path scalar type")
        end
        seen << path
        declarations << {path, type}
      end
    end
  end
end
