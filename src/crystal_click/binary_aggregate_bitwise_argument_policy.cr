module CrystalClick
  # Exact argument admission for the bitwise AggregateFunction state family.
  # These functions accept only a bare integer descriptor; unlike Sum-family
  # aggregates, Nullable and LowCardinality wrappers are not dispatched.
  class BinaryAggregateBitwiseArgumentPolicy
    def self.bitwise_function?(function_name : String) : Bool
      function_name == "groupBitOr" || function_name == "groupBitAnd" || function_name == "groupBitXor"
    end

    def self.integer_argument?(argument_type : BinaryDataType) : Bool
      case argument_type.tag
      when BinaryDataType::TAG_UINT8, BinaryDataType::TAG_UINT16,
           BinaryDataType::TAG_UINT32, BinaryDataType::TAG_UINT64,
           BinaryDataType::TAG_UINT128, BinaryDataType::TAG_UINT256,
           BinaryDataType::TAG_INT8, BinaryDataType::TAG_INT16,
           BinaryDataType::TAG_INT32, BinaryDataType::TAG_INT64,
           BinaryDataType::TAG_INT128, BinaryDataType::TAG_INT256
        true
      else
        false
      end
    end

    def self.require!(argument_type : BinaryDataType) : Nil
      unless integer_argument?(argument_type)
        raise ArgumentError.new("AggregateFunction bitwise argument must be a bare integer type")
      end
      nil
    end

    def self.state_width(argument_type : BinaryDataType) : Int32
      require!(argument_type)
      argument_type.fixed_width || raise ArgumentError.new("AggregateFunction bitwise integer has no fixed state width")
    end
  end
end
