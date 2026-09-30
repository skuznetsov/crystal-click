module CrystalClick
  # Exact Enum8/Enum16 Tuple descriptor, including its complete code/label
  # definition rather than only the signed physical width.
  class WideTupleEnumType
    alias Buffer = Array(Enum8Value) | Array(Enum16Value)

    @definition : WideTupleEnumDefinition

    def initialize(@definition : WideTupleEnumDefinition)
    end

    def definition : WideTupleEnumDefinition
      @definition
    end

    def width : Int32
      @definition.kind == :enum8 ? 1 : 2
    end

    def type_name : String
      @definition.type_name
    end

    def logical_charge : UInt64
      instance_sizeof(WideTupleEnumType).to_u64 + @definition.logical_charge
    end

    def validate_buffer!(buffer : Buffer) : Nil
      case @definition.kind
      when :enum8
        raise ArgumentError.new("Enum buffer does not match exact kind") unless buffer.is_a?(Array(Enum8Value))
        buffer.each do |value|
          unless value.definition == @definition && @definition.declared?(value.code)
            raise ArgumentError.new("Enum8 value definition does not match exact type")
          end
        end
      when :enum16
        raise ArgumentError.new("Enum buffer does not match exact kind") unless buffer.is_a?(Array(Enum16Value))
        buffer.each do |value|
          unless value.definition == @definition && @definition.declared?(value.code)
            raise ArgumentError.new("Enum16 value definition does not match exact type")
          end
        end
      end
      nil
    end

    def ==(other : self) : Bool
      @definition == other.definition
    end

    def hash(hasher)
      hasher = @definition.hash(hasher)
      hasher
    end
  end
end
