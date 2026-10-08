module CrystalClick
  # Immutable nominal AggregateFunction descriptor. The declared argument is
  # metadata, not a generic value child; family-specific admission preserves
  # nominal wrappers and metadata while canonicalizing function identity.
  class BinaryAggregateFunctionType
    VERSION = 0_u8

    getter function_name : String
    getter argument_type : BinaryDataType?
    getter version : UInt8

    def initialize(function_name : String, @argument_type : BinaryDataType? = nil, @version : UInt8 = VERSION)
      if function_name == "count"
        unless @version == BinaryAggregateCountType::VERSION
          raise ArgumentError.new("AggregateFunction version is outside the admitted Count profile")
        end
        BinaryAggregateCountArgumentPolicy.require!(@argument_type)
        @function_name = "count"
      else
        argument = @argument_type || raise ArgumentError.new("AggregateFunction Sum requires one argument type")
        @function_name = BinaryAggregateFunctionAdmission.require!(function_name, argument, @version)
      end
    end

    def type_name : String
      if argument = @argument_type
        "AggregateFunction(#{@function_name}, #{argument.name})"
      else
        "AggregateFunction(#{@function_name})"
      end
    end

    def ==(other : BinaryAggregateFunctionType) : Bool
      @function_name == other.@function_name && @argument_type == other.@argument_type && @version == other.@version
    end

    def_hash @function_name, @argument_type, @version
  end
end
