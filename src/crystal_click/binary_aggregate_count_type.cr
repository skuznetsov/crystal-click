module CrystalClick
  # Nominal identity for the admitted AggregateFunction(count) profile. Its
  # optional argument is immutable descriptor metadata, never a value child.
  class BinaryAggregateCountType
    VERSION = 0_u8

    getter argument_type : BinaryDataType?

    def initialize(@argument_type : BinaryDataType? = nil)
      BinaryAggregateCountArgumentPolicy.require!(@argument_type)
    end

    def function_name : String
      "count"
    end

    def type_name : String
      if argument = @argument_type
        "AggregateFunction(count, #{argument.name})"
      else
        "AggregateFunction(count)"
      end
    end

    def ==(other : BinaryAggregateCountType) : Bool
      @argument_type == other.@argument_type
    end

    def_hash @argument_type
  end
end
