module CrystalClick
  # Signed Enum16 code paired with its immutable complete declared map.
  struct Enum16Value
    @definition : WideTupleEnumDefinition
    @code : Int16

    def initialize(@definition : WideTupleEnumDefinition, @code : Int16)
      raise ArgumentError.new("Enum16 value requires an Enum16 definition") unless @definition.kind == :enum16
      raise ArgumentError.new("Enum16 code is not declared") unless @definition.declared?(@code)
    end

    def definition : WideTupleEnumDefinition
      @definition
    end

    def code : Int16
      @code
    end

    def label : String
      @definition.label_for(@code) || raise(ArgumentError.new("Enum16 code is not declared"))
    end

    def with_definition(definition : WideTupleEnumDefinition) : Enum16Value
      raise ArgumentError.new("Enum16 definition does not match value") unless definition == @definition && definition.declared?(@code)
      Enum16Value.new(definition, @code)
    end

    def ==(other : self) : Bool
      @code == other.code && @definition == other.definition
    end

    def hash(hasher)
      hasher = @definition.hash(hasher)
      hasher = @code.hash(hasher)
      hasher
    end
  end
end
