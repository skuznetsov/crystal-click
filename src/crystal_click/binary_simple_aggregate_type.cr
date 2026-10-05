module CrystalClick
  # Exact canonical function and storage identity for the bounded
  # SimpleAggregateFunction numeric descriptor profile.
  class BinarySimpleAggregateType
    TYPE_PREFIX = "SimpleAggregateFunction("
    # Retained as the default profile suffix for callers that use the legacy
    # UInt64 constructor and constant.
    TYPE_SUFFIX               = ", UInt64)"
    DEFAULT_STORAGE_TYPE_NAME = "UInt64"
    MAX_TYPE_BYTES            = 80

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
    @storage_type_name : String

    def initialize(
      @function : Function,
      storage_type_name : String = DEFAULT_STORAGE_TYPE_NAME,
    )
      unless valid_function?(@function)
        raise ArgumentError.new("invalid SimpleAggregateFunction function")
      end
      unless self.class.admitted_function_storage?(@function, storage_type_name)
        raise ArgumentError.new("SimpleAggregateFunction function/storage pair is outside the admitted numeric profile")
      end
      @storage_type_name = String.new(storage_type_name.to_slice)
    end

    def storage_type_name : String
      String.new(@storage_type_name.to_slice)
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
      "#{TYPE_PREFIX}#{function_name}, #{@storage_type_name})"
    end

    def name_byte_size : UInt64
      (TYPE_PREFIX.bytesize + function_name.bytesize + 2 + @storage_type_name.bytesize + 1).to_u64
    end

    def self.parse(type_name : String) : BinarySimpleAggregateType?
      return nil if type_name.bytesize > MAX_TYPE_BYTES
      return nil unless type_name.starts_with?(TYPE_PREFIX) && type_name.ends_with?(")")

      body_start = TYPE_PREFIX.bytesize
      body_size = type_name.bytesize - TYPE_PREFIX.bytesize - 1
      return nil if body_size <= 0
      body = type_name.byte_slice(body_start, body_size)
      separator = body.index(", ") || return nil
      return nil if body.index(", ", separator + 2)

      function_name = body.byte_slice(0, separator)
      storage_type_name = body.byte_slice(separator + 2, body.bytesize - separator - 2)
      return nil unless 3 <= function_name.bytesize <= 15
      return nil if storage_type_name.empty?

      from_name(function_name, storage_type_name)
    end

    def self.from_name(
      name : String,
      storage_type_name : String = DEFAULT_STORAGE_TYPE_NAME,
    ) : BinarySimpleAggregateType?
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
      return nil unless admitted_function_storage?(function, storage_type_name)
      new(function, storage_type_name)
    end

    def self.storage_width(storage_type_name : String) : Int32?
      case storage_type_name
      when "UInt8", "Int8"
        1
      when "UInt16", "Int16"
        2
      when "UInt32", "Int32", "Float32"
        4
      when "UInt64", "Int64", "Float64"
        8
      when "UInt128", "Int128"
        16
      when "UInt256", "Int256"
        32
      when "BFloat16"
        2
      else
        nil
      end
    end

    def self.admitted_function_storage?(
      function : Function,
      storage_type_name : String,
    ) : Bool
      return false unless storage_width(storage_type_name)

      case function
      when Function::Any, Function::AnyLast, Function::Min, Function::Max,
           Function::SumWithOverflow
        true
      when Function::Sum
        case storage_type_name
        when "UInt64", "Int64", "Float64", "UInt128", "Int128", "UInt256", "Int256"
          true
        else
          false
        end
      when Function::GroupBitAnd, Function::GroupBitOr, Function::GroupBitXor
        case storage_type_name
        when "UInt8", "UInt16", "UInt32", "UInt64", "UInt128", "UInt256",
             "Int8", "Int16", "Int32", "Int64", "Int128", "Int256"
          true
        else
          false
        end
      else
        false
      end
    end

    def ==(other : BinarySimpleAggregateType) : Bool
      @function == other.function && @storage_type_name == other.storage_type_name
    end

    def_hash @function, @storage_type_name

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
