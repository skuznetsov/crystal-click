module CrystalClick
  # Exact canonical function identity for the finite W161
  # SimpleAggregateFunction(UInt64) descriptor profile.
  class BinarySimpleAggregateType
    TYPE_PREFIX = "SimpleAggregateFunction("
    TYPE_SUFFIX = ", UInt64)"

    enum Function
      Any
      AnyLast
      Min
      Max
      Sum
      SumWithOverflow
      GroupBitAnd
      GroupBitOr
      GroupBitXor
    end

    getter function : Function

    def initialize(@function : Function)
      unless valid_function?(@function)
        raise ArgumentError.new("invalid SimpleAggregateFunction function")
      end
    end

    def function_name : String
      case @function
      when Function::Any             then "any"
      when Function::AnyLast         then "anyLast"
      when Function::Min             then "min"
      when Function::Max             then "max"
      when Function::Sum             then "sum"
      when Function::SumWithOverflow then "sumWithOverflow"
      when Function::GroupBitAnd     then "groupBitAnd"
      when Function::GroupBitOr      then "groupBitOr"
      when Function::GroupBitXor     then "groupBitXor"
      else
        raise ArgumentError.new("invalid SimpleAggregateFunction function")
      end
    end

    def type_name : String
      "#{TYPE_PREFIX}#{function_name}#{TYPE_SUFFIX}"
    end

    def name_byte_size : UInt64
      (TYPE_PREFIX.bytesize + function_name.bytesize + TYPE_SUFFIX.bytesize).to_u64
    end

    def self.parse(type_name : String) : BinarySimpleAggregateType?
      return nil unless type_name.starts_with?(TYPE_PREFIX) && type_name.ends_with?(TYPE_SUFFIX)
      function_name_size = type_name.bytesize - TYPE_PREFIX.bytesize - TYPE_SUFFIX.bytesize
      return nil unless 3 <= function_name_size <= 15

      function_name = type_name.byte_slice(
        TYPE_PREFIX.bytesize,
        function_name_size
      )
      from_name(function_name)
    end

    def self.from_name(name : String) : BinarySimpleAggregateType?
      function = case name
                 when "any"             then Function::Any
                 when "anyLast"         then Function::AnyLast
                 when "min"             then Function::Min
                 when "max"             then Function::Max
                 when "sum"             then Function::Sum
                 when "sumWithOverflow" then Function::SumWithOverflow
                 when "groupBitAnd"     then Function::GroupBitAnd
                 when "groupBitOr"      then Function::GroupBitOr
                 when "groupBitXor"     then Function::GroupBitXor
                 else
                   return nil
                 end
      new(function)
    end

    def ==(other : BinarySimpleAggregateType) : Bool
      @function == other.function
    end

    def_hash @function

    private def valid_function?(function : Function) : Bool
      case function
      when Function::Any, Function::AnyLast, Function::Min, Function::Max,
           Function::Sum, Function::SumWithOverflow, Function::GroupBitAnd,
           Function::GroupBitOr, Function::GroupBitXor
        true
      else
        false
      end
    end
  end
end
