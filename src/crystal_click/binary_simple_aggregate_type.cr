module CrystalClick
  # Exact canonical function and storage identity for the bounded
  # SimpleAggregateFunction descriptor profile.
  class BinarySimpleAggregateType
    TYPE_PREFIX = "SimpleAggregateFunction("
    # Retained as the default profile suffix for callers that use the legacy
    # UInt64 constructor and constant.
    TYPE_SUFFIX               = ", UInt64)"
    DEFAULT_STORAGE_TYPE_NAME = "UInt64"
    # Bounds the longest admitted function name, one inner Nullable shell, and
    # the complete bounded timezone token in a canonical temporal leaf.
    MAX_FUNCTION_NAME_BYTES = 21
    # The 107-byte descriptor cap leaves 59 bytes for its storage name.
    MAX_STORAGE_TYPE_BYTES = 59
    MAX_TYPE_BYTES         = 107
    # Existing local FixedString materialization limit; ClickHouse itself
    # permits wider declarations than this library profile admits.
    MAX_FIXED_STRING_WIDTH = 65_536

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
      AnyRespectNulls
      AnyLastRespectNulls
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
        raise ArgumentError.new("SimpleAggregateFunction function/storage pair is outside the admitted profile")
      end
      @storage_type_name = String.new(storage_type_name.to_slice)
    end

    def storage_type_name : String
      String.new(@storage_type_name.to_slice)
    end

    # Exact canonical Decimal(P, S) parameters when storage is exactly a
    # Decimal leaf. An inner Nullable wrapper is intentionally not erased.
    def decimal_type : DecimalType?
      DecimalType.parse(@storage_type_name)
    end

    # Exact canonical temporal identity when storage is exactly one of the six
    # scalar temporal leaves. An inner Nullable wrapper is not erased.
    def temporal_storage_type : TemporalStorageType?
      TemporalStorageType.parse(@storage_type_name)
    end

    def function_name : String
      case @function
      when Function::Any                 then "any"
      when Function::AnyLast             then "anyLast"
      when Function::AnyRespectNulls     then "any_respect_nulls"
      when Function::AnyLastRespectNulls then "anyLast_respect_nulls"
      when Function::Min                 then "min"
      when Function::Max                 then "max"
      when Function::Sum                 then "sum"
      when Function::SumWithOverflow     then "sumWithOverflow"
      when Function::GroupBitAnd         then "groupBitAnd"
      when Function::GroupBitOr          then "groupBitOr"
      when Function::GroupBitXor         then "groupBitXor"
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

      function_name = body.byte_slice(0, separator)
      storage_type_name = body.byte_slice(separator + 2, body.bytesize - separator - 2)
      return nil unless 3 <= function_name.bytesize <= MAX_FUNCTION_NAME_BYTES
      return nil if storage_type_name.empty?
      return nil if storage_type_name.bytesize > MAX_STORAGE_TYPE_BYTES

      # Decimal and zoned temporal leaves are the only admitted storage leaves
      # whose canonical names contain commas. Allow one exact inner Nullable
      # shell while keeping their leaf parsers responsible for full spellings.
      storage_leaf_name = nullable_storage_child_name(storage_type_name) || storage_type_name
      unless DecimalType.parse(storage_leaf_name) || TemporalStorageType.parse(storage_leaf_name)
        return nil if storage_leaf_name.includes?(',')
      end

      from_name(function_name, storage_type_name)
    end

    def self.from_name(
      name : String,
      storage_type_name : String = DEFAULT_STORAGE_TYPE_NAME,
    ) : BinarySimpleAggregateType?
      function = case name
                 when "any"                   then Function::Any
                 when "anyLast"               then Function::AnyLast
                 when "any_respect_nulls"     then Function::AnyRespectNulls
                 when "anyLast_respect_nulls" then Function::AnyLastRespectNulls
                 when "min"                   then Function::Min
                 when "max"                   then Function::Max
                 when "sum"                   then Function::Sum
                 when "sumWithOverflow"       then Function::SumWithOverflow
                 when "groupBitAnd"            then Function::GroupBitAnd
                 when "groupBitOr"             then Function::GroupBitOr
                 when "groupBitXor"            then Function::GroupBitXor
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

    # Returns a width only for the exact canonical FixedString(N) spelling
    # admitted by this profile. String is variable-width and deliberately has
    # no inferred raw_width.
    def self.fixed_string_width(storage_type_name : String) : Int32?
      prefix = "FixedString("
      return nil unless storage_type_name.starts_with?(prefix) && storage_type_name.ends_with?(")")

      digits = storage_type_name.byte_slice(prefix.bytesize, storage_type_name.bytesize - prefix.bytesize - 1)
      return nil if digits.empty? || digits.bytesize > 5 || digits.byte_at(0) == '0'.ord.to_u8

      width = 0
      digits.each_byte do |byte|
        return nil unless byte >= '0'.ord.to_u8 && byte <= '9'.ord.to_u8
        width = width * 10 + (byte - '0'.ord.to_u8).to_i
      end
      return nil unless width > 0 && width <= MAX_FIXED_STRING_WIDTH

      width
    end

    def self.string_storage?(storage_type_name : String) : Bool
      storage_type_name == "String"
    end

    private def self.admitted_text_function?(function : Function) : Bool
      case function
      when Function::Any, Function::AnyLast, Function::Min, Function::Max
        true
      else
        false
      end
    end

    def self.admitted_function_storage?(
      function : Function,
      storage_type_name : String,
    ) : Bool
      return false if storage_type_name.bytesize > MAX_STORAGE_TYPE_BYTES

      law_function = case function
                     when Function::AnyRespectNulls     then Function::Any
                     when Function::AnyLastRespectNulls then Function::AnyLast
                     else
                       function
                     end

      if storage_type_name.starts_with?("Nullable(")
        storage_leaf_name = nullable_storage_child_name(storage_type_name) || return false
        return admitted_function_storage?(law_function, storage_leaf_name)
      end

      if string_storage?(storage_type_name) || fixed_string_width(storage_type_name) != nil
        return admitted_text_function?(law_function)
      end

      if decimal_type = DecimalType.parse(storage_type_name)
        case law_function
        when Function::Any, Function::AnyLast, Function::Min, Function::Max,
             Function::SumWithOverflow
          return true
        when Function::Sum
          # ClickHouse widens Decimal32/64 sums to Decimal128. Decimal128 and
          # Decimal256 retain their carrier and pass its DataType equality
          # check; precision itself is not part of that equality.
          return decimal_type.storage_width >= 16
        when Function::GroupBitAnd, Function::GroupBitOr, Function::GroupBitXor
          return false
        else
          return false
        end
      end

      if TemporalStorageType.parse(storage_type_name)
        case law_function
        when Function::Any, Function::AnyLast, Function::Min, Function::Max
          return true
        else
          return false
        end
      end

      return false unless storage_width(storage_type_name)

      case law_function
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

    # Return a single canonical wrapper's child. This is only a syntax helper;
    # callers still run the child through the exact scalar leaf admission law.
    private def self.nullable_storage_child_name(storage_type_name : String) : String?
      return nil if storage_type_name.bytesize > MAX_STORAGE_TYPE_BYTES

      prefix = "Nullable("
      return nil unless storage_type_name.starts_with?(prefix) && storage_type_name.ends_with?(")")

      child_size = storage_type_name.bytesize - "Nullable()".bytesize
      return nil if child_size <= 0
      child_name = storage_type_name.byte_slice(prefix.bytesize, child_size)
      return nil if child_name.starts_with?(prefix)

      child_name
    end

    def ==(other : BinarySimpleAggregateType) : Bool
      @function == other.function && @storage_type_name == other.storage_type_name
    end

    def_hash @function, @storage_type_name

    private def valid_function?(function : Function) : Bool
      case function
      when Function::Any, Function::AnyLast, Function::Min, Function::Max,
           Function::AnyRespectNulls, Function::AnyLastRespectNulls,
           Function::Sum, Function::SumWithOverflow, Function::GroupBitAnd,
           Function::GroupBitOr, Function::GroupBitXor
        true
      else
        false
      end
    end
  end
end
