module CrystalClick
  # Closed nominal type policy for Object JSON typed fields. The static names
  # are also used during budget preflight so callers do not allocate a
  # BinaryDataType name before the declaration has been admitted.
  module ObjectTypedFieldType
    FIXED_STRING_PREFIX = "FixedString("
    TYPE_NAMES          = {
      {BinaryDataType::TAG_UINT8, "UInt8"},
      {BinaryDataType::TAG_UINT16, "UInt16"},
      {BinaryDataType::TAG_UINT32, "UInt32"},
      {BinaryDataType::TAG_UINT64, "UInt64"},
      {BinaryDataType::TAG_UINT128, "UInt128"},
      {BinaryDataType::TAG_UINT256, "UInt256"},
      {BinaryDataType::TAG_INT8, "Int8"},
      {BinaryDataType::TAG_INT16, "Int16"},
      {BinaryDataType::TAG_INT32, "Int32"},
      {BinaryDataType::TAG_INT64, "Int64"},
      {BinaryDataType::TAG_INT128, "Int128"},
      {BinaryDataType::TAG_INT256, "Int256"},
      {BinaryDataType::TAG_FLOAT32, "Float32"},
      {BinaryDataType::TAG_FLOAT64, "Float64"},
      {BinaryDataType::TAG_DATE, "Date"},
      {BinaryDataType::TAG_DATE32, "Date32"},
      {BinaryDataType::TAG_UUID, "UUID"},
      {BinaryDataType::TAG_IPV4, "IPv4"},
      {BinaryDataType::TAG_IPV6, "IPv6"},
      {BinaryDataType::TAG_BOOL, "Bool"},
      {BinaryDataType::TAG_STRING, "String"},
    }

    # Stack value returned by parser admission. It carries the canonical type
    # and its rendered byte count without constructing a BinaryDataType before
    # the caller charges its codec budget.
    struct Resolution
      getter byte_size : Int32

      @tag : UInt8
      @parameter : Int32

      def initialize(@tag : UInt8, @parameter : Int32, @byte_size : Int32)
      end

      def materialize : BinaryDataType
        if @tag == BinaryDataType::TAG_FIXED_STRING
          BinaryDataType.fixed_string(@parameter)
        else
          name = ObjectTypedFieldType.name_for_tag(@tag) ||
                 raise ArgumentError.new("typed Object field resolution has an unknown primitive tag")
          BinaryDataType.primitive(name)
        end
      end
    end

    def self.name_for(type : BinaryDataType) : String?
      name_for_tag(type.tag)
    end

    # Return the canonical rendered byte count without allocating a
    # parameterized type name. This is used during declaration preflight.
    def self.byte_size_for(type : BinaryDataType) : Int32?
      if name = name_for(type)
        return name.bytesize
      end
      return nil unless type.tag == BinaryDataType::TAG_FIXED_STRING
      width = type.fixed_size
      return nil unless width && width > 0 && width <= BinaryDataType::MAX_FIXED_STRING
      fixed_string_byte_size(width)
    end

    # Render a type only after its complete declaration passed byte-budget
    # admission. FixedString's numeric width is written directly to the IO.
    def self.append_name(io : IO, type : BinaryDataType) : Nil
      if name = name_for(type)
        io << name
        return nil
      end
      unless type.tag == BinaryDataType::TAG_FIXED_STRING
        raise ArgumentError.new("typed JSON schema admits only supported nominal scalar types")
      end
      width = type.fixed_size
      unless width && width > 0 && width <= BinaryDataType::MAX_FIXED_STRING
        raise ArgumentError.new("typed JSON schema has an invalid FixedString width")
      end
      io << FIXED_STRING_PREFIX << width << ')'
      nil
    end

    def self.name_for_tag(tag : UInt8) : String?
      TYPE_NAMES.each do |entry|
        return entry[1] if entry[0] == tag
      end
      nil
    end

    # Resolve a parser token directly to a canonical static literal without
    # first copying it or allocating a general BinaryDataType name.
    def self.name_for_slice(bytes : Bytes, first : Int32, after : Int32) : String?
      return nil if first < 0 || after < first || after > bytes.size

      TYPE_NAMES.each do |entry|
        name = entry[1]
        return name if slice_equals?(bytes, first, after, name)
      end
      nil
    end

    # Resolve exactly the bounded nominal grammar used by Object typed fields:
    # a static primitive name or canonical FixedString(positive-decimal-N).
    # The returned stack value carries the byte charge and is materialized
    # only after the parser has admitted that charge.
    def self.resolve_slice(bytes : Bytes, first : Int32, after : Int32) : Resolution?
      return nil if first < 0 || after < first || after > bytes.size

      TYPE_NAMES.each do |entry|
        name = entry[1]
        if slice_equals?(bytes, first, after, name)
          return Resolution.new(entry[0], 0, name.bytesize)
        end
      end

      width = fixed_string_width_for_slice(bytes, first, after)
      return nil unless width
      Resolution.new(BinaryDataType::TAG_FIXED_STRING, width, fixed_string_byte_size(width))
    end

    private def self.fixed_string_width_for_slice(bytes : Bytes, first : Int32, after : Int32) : Int32?
      return nil if first < 0 || after < first || after > bytes.size
      return nil if after - first < FIXED_STRING_PREFIX.bytesize + 2
      prefix_after = first + FIXED_STRING_PREFIX.bytesize
      return nil unless slice_equals?(bytes, first, prefix_after, FIXED_STRING_PREFIX)
      return nil unless bytes[after - 1] == ')'.ord.to_u8

      digits_first = prefix_after
      digits_after = after - 1
      return nil if digits_first >= digits_after
      return nil if bytes[digits_first] == '0'.ord.to_u8

      width = 0
      index = digits_first
      maximum = BinaryDataType::MAX_FIXED_STRING
      while index < digits_after
        byte = bytes[index]
        return nil if byte < '0'.ord.to_u8 || byte > '9'.ord.to_u8
        digit = (byte - '0'.ord.to_u8).to_i
        return nil if width > (maximum - digit) // 10
        width = width * 10 + digit
        index += 1
      end
      return nil if width <= 0
      width
    end

    private def self.fixed_string_byte_size(width : Int32) : Int32
      digits = 1
      remaining = width
      while remaining >= 10
        remaining //= 10
        digits += 1
      end
      FIXED_STRING_PREFIX.bytesize + digits + 1 # closing parenthesis
    end

    private def self.slice_equals?(bytes : Bytes, first : Int32, after : Int32, expected : String) : Bool
      return false unless after - first == expected.bytesize
      expected_bytes = expected.to_slice
      expected_bytes.size.times do |index|
        return false unless bytes[first + index] == expected_bytes[index]
      end
      true
    end
  end
end
