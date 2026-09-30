module CrystalClick
  # A bounded syntax tree for ClickHouse type expressions. Parsing describes
  # syntax only; callers must use exact admission before selecting physical codecs.
  class WideTypeExpression
    alias Node = WideTypePlan::Node
    alias Parser = WideTypePlan::Parser

    # Parse a bounded recursive type-expression grammar. A nil result means
    # malformed or over-limit syntax; it does not imply codec support.
    def self.parse(type : String) : Node?
      return nil if type.empty? || type.bytesize > 4_096
      Parser.new(type).parse
    end
  end
end
