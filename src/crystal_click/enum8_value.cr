module CrystalClick
  # Signed Enum8 code paired with its immutable complete declared map.
  struct Enum8Value
    @definition : WideTupleEnumDefinition
    @code : Int8

    def initialize(@definition : WideTupleEnumDefinition, @code : Int8)
      raise ArgumentError.new("Enum8 value requires an Enum8 definition") unless @definition.kind == :enum8
      raise ArgumentError.new("Enum8 code is not declared") unless @definition.declared?(@code)
    end

    def definition : WideTupleEnumDefinition
      @definition
    end

    def code : Int8
      @code
    end

    def label : String
      @definition.label_for(@code) || raise(ArgumentError.new("Enum8 code is not declared"))
    end

    def with_definition(definition : WideTupleEnumDefinition) : Enum8Value
      raise ArgumentError.new("Enum8 definition does not match value") unless definition == @definition && definition.declared?(@code)
      Enum8Value.new(definition, @code)
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
