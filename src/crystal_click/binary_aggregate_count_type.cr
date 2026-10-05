module CrystalClick
  # Nominal identity for the deliberately narrow AggregateFunction(count)
  # descriptor profile. The argument kind is stored as a closed discriminator,
  # not as a generic BinaryDataType child: count's state is a leaf even when
  # the descriptor has one argument type.
  class BinaryAggregateCountType
    VERSION = 0_u8

    enum Argument
      None
      UInt64
      NullableUInt64
    end

    getter argument : Argument

    def initialize(@argument : Argument)
      case @argument
      when Argument::None, Argument::UInt64, Argument::NullableUInt64
        # Closed local profile.
      else
        raise ArgumentError.new("invalid AggregateFunction(count) argument kind")
      end
    end

    def function_name : String
      "count"
    end

    def type_name : String
      case @argument
      when Argument::None
        "AggregateFunction(count)"
      when Argument::UInt64
        "AggregateFunction(count, UInt64)"
      when Argument::NullableUInt64
        "AggregateFunction(count, Nullable(UInt64))"
      else
        raise ArgumentError.new("invalid AggregateFunction(count) argument kind")
      end
    end

    def ==(other : BinaryAggregateCountType) : Bool
      @argument == other.@argument
    end

    def_hash @argument
  end
end
