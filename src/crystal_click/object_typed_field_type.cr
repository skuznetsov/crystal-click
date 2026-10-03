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
      getter enum_entry_count : UInt64
      getter decoded_label_bytes : UInt64
      getter explicit_zone_bytes : UInt64

      @tag : UInt8
      @parameter : Int32
      @scale : Int32
      @enum_preflight : ObjectEnumDeclaration::Preflight?
      @temporal_preflight : ObjectTemporalDeclaration::Preflight?

      def initialize(
        @tag : UInt8,
        @parameter : Int32,
        @byte_size : Int32,
        @scale : Int32 = 0,
        @enum_entry_count : UInt64 = 0_u64,
        @decoded_label_bytes : UInt64 = 0_u64,
        @enum_preflight : ObjectEnumDeclaration::Preflight? = nil,
        @temporal_preflight : ObjectTemporalDeclaration::Preflight? = nil,
        @explicit_zone_bytes : UInt64 = 0_u64,
      )
      end

      def materialize : BinaryDataType
        if temporal = @temporal_preflight
          unless temporal.tag == @tag && temporal.scale == @scale &&
                 temporal.byte_size == @byte_size && temporal.zone_byte_size == @explicit_zone_bytes &&
                 @parameter == 0 && @enum_preflight.nil? && @enum_entry_count == 0_u64 &&
                 @decoded_label_bytes == 0_u64
            raise ArgumentError.new("temporal typed Object resolution metadata changed after preflight")
          end
          temporal.materialize
        elsif @tag == BinaryDataType::TAG_ENUM8 || @tag == BinaryDataType::TAG_ENUM16
          entries = @enum_preflight.not_nil!.materialize_entries
          @tag == BinaryDataType::TAG_ENUM8 ? BinaryDataType.enum8(entries) : BinaryDataType.enum16(entries)
        elsif @tag == BinaryDataType::TAG_FIXED_STRING
          BinaryDataType.fixed_string(@parameter)
        elsif ObjectTypedFieldType.decimal_tag?(@tag)
          width_bits = case @tag
                       when BinaryDataType::TAG_DECIMAL32  then 32
                       when BinaryDataType::TAG_DECIMAL64  then 64
                       when BinaryDataType::TAG_DECIMAL128 then 128
                       when BinaryDataType::TAG_DECIMAL256 then 256
                       else
                         raise ArgumentError.new("typed Object field resolution has an unknown Decimal tag")
                       end
          BinaryDataType.decimal(width_bits, @parameter, @scale)
        else
          name = ObjectTypedFieldType.name_for_tag(@tag) ||
                 raise ArgumentError.new("typed Object field resolution has an unknown primitive tag")
          BinaryDataType.primitive(name)
        end
      end
    end

    def self.name_for(type : BinaryDataType) : String?
      ObjectTemporalDeclaration.name_for(type) || name_for_tag(type.tag)
    end

    # Return the canonical rendered byte count without allocating a
    # parameterized type name. This is used during declaration preflight.
    def self.byte_size_for(type : BinaryDataType) : UInt64?
      if ObjectTemporalDeclaration.handles_type?(type)
        ObjectTemporalDeclaration.byte_size_for(type)
      elsif name = name_for(type)
        return name.bytesize.to_u64
      elsif type.tag == BinaryDataType::TAG_FIXED_STRING
        width = type.fixed_size
        return nil unless width && width > 0 && width <= BinaryDataType::MAX_FIXED_STRING
        fixed_string_byte_size(width).to_u64
      elsif decimal_tag?(type.tag)
        decimal = canonical_decimal_for_binary_type(type) || return nil
        decimal_byte_size(decimal.precision, decimal.scale).to_u64
      elsif type.tag == BinaryDataType::TAG_ENUM8 || type.tag == BinaryDataType::TAG_ENUM16
        definition = canonical_enum_for_binary_type(type) || return nil
        ObjectEnumDeclaration.byte_size_for(definition)
      else
        nil
      end
    end

    # Render a type only after its complete declaration passed byte-budget
    # admission. FixedString's numeric width is written directly to the IO.
    def self.append_name(io : IO, type : BinaryDataType) : Nil
      if ObjectTemporalDeclaration.handles_type?(type)
        return ObjectTemporalDeclaration.append_name(io, type)
      end
      if name = name_for(type)
        io << name
        return nil
      end
      if type.tag == BinaryDataType::TAG_ENUM8 || type.tag == BinaryDataType::TAG_ENUM16
        definition = canonical_enum_for_binary_type(type) ||
                     raise ArgumentError.new("typed JSON schema has a noncanonical Enum descriptor")
        ObjectEnumDeclaration.append_name(io, definition)
        return nil
      end
      unless type.tag == BinaryDataType::TAG_FIXED_STRING
        if decimal_tag?(type.tag)
          decimal = canonical_decimal_for_binary_type(type) ||
                    raise ArgumentError.new("typed JSON schema has a noncanonical Decimal descriptor")
          io << "Decimal(" << decimal.precision << ", " << decimal.scale << ')'
          return nil
        end
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
    # a static primitive, temporal declaration, canonical FixedString(N),
    # Decimal(P, S), or canonical bare Enum8/Enum16 declaration. The returned
    # stack value carries the byte and map-edge charges and is materialized
    # only after admission.
    def self.resolve_slice(bytes : Bytes, first : Int32, after : Int32) : Resolution?
      return nil if first < 0 || after < first || after > bytes.size

      if temporal = ObjectTemporalDeclaration.resolve_slice(bytes, first, after)
        return Resolution.new(
          temporal.tag,
          0,
          temporal.byte_size,
          temporal.scale,
          temporal_preflight: temporal,
          explicit_zone_bytes: temporal.zone_byte_size,
        )
      end

      TYPE_NAMES.each do |entry|
        name = entry[1]
        if slice_equals?(bytes, first, after, name)
          return Resolution.new(entry[0], 0, name.bytesize)
        end
      end

      width = fixed_string_width_for_slice(bytes, first, after)
      if width
        return Resolution.new(BinaryDataType::TAG_FIXED_STRING, width, fixed_string_byte_size(width))
      end

      if decimal = decimal_type_for_slice(bytes, first, after)
        tag = decimal_tag_for_storage_width(decimal.storage_width)
        return Resolution.new(tag, decimal.precision, decimal_byte_size(decimal.precision, decimal.scale), decimal.scale)
      end

      enum_preflight = ObjectEnumDeclaration.preflight_slice(bytes, first, after)
      return nil unless enum_preflight
      Resolution.new(
        enum_preflight.tag,
        0,
        enum_preflight.byte_size,
        enum_entry_count: enum_preflight.entry_count.to_u64,
        decoded_label_bytes: enum_preflight.decoded_label_bytes,
        enum_preflight: enum_preflight,
      )
    end

    def self.decimal_tag?(tag : UInt8) : Bool
      tag == BinaryDataType::TAG_DECIMAL32 || tag == BinaryDataType::TAG_DECIMAL64 ||
        tag == BinaryDataType::TAG_DECIMAL128 || tag == BinaryDataType::TAG_DECIMAL256
    end

    private def self.canonical_decimal_for_binary_type(type : BinaryDataType) : DecimalType?
      return nil unless decimal_tag?(type.tag)
      binary = type.decimal_type || return nil
      decimal = DecimalType.new(binary.precision, binary.scale)
      return nil unless binary.width_bits == decimal.storage_width * 8
      return nil unless type.tag == decimal_tag_for_storage_width(decimal.storage_width)
      decimal
    rescue ArgumentError
      nil
    end

    private def self.decimal_type_for_slice(bytes : Bytes, first : Int32, after : Int32) : DecimalType?
      prefix = "Decimal("
      return nil if after - first < prefix.bytesize + 5
      return nil unless slice_equals?(bytes, first, first + prefix.bytesize, prefix)
      return nil unless bytes[after - 1] == ')'.ord.to_u8

      precision_first = first + prefix.bytesize
      comma = precision_first
      while comma < after - 1 && bytes[comma] != ','.ord.to_u8
        comma += 1
      end
      return nil if comma >= after - 1
      return nil if comma + 2 >= after - 1
      return nil unless bytes[comma + 1] == ' '.ord.to_u8

      precision = canonical_decimal_number(bytes, precision_first, comma, allow_zero: false) || return nil
      scale = canonical_decimal_number(bytes, comma + 2, after - 1, allow_zero: true) || return nil
      DecimalType.new(precision, scale)
    rescue ArgumentError
      nil
    end

    private def self.canonical_decimal_number(bytes : Bytes, first : Int32, after : Int32, allow_zero : Bool) : Int32?
      return nil if first >= after
      return nil if after - first > 1 && bytes[first] == '0'.ord.to_u8

      value = 0
      index = first
      while index < after
        byte = bytes[index]
        return nil if byte < '0'.ord.to_u8 || byte > '9'.ord.to_u8
        digit = (byte - '0'.ord.to_u8).to_i
        return nil if value > (76 - digit) // 10
        value = value * 10 + digit
        index += 1
      end
      return nil if !allow_zero && value == 0
      value
    end

    private def self.decimal_tag_for_storage_width(width : Int32) : UInt8
      case width
      when  4 then BinaryDataType::TAG_DECIMAL32
      when  8 then BinaryDataType::TAG_DECIMAL64
      when 16 then BinaryDataType::TAG_DECIMAL128
      when 32 then BinaryDataType::TAG_DECIMAL256
      else
        raise ArgumentError.new("Decimal storage width is outside the supported range")
      end
    end

    private def self.canonical_enum_for_binary_type(type : BinaryDataType) : BinaryEnumDefinition?
      definition = type.enum_definition || return nil
      return nil if type.tag == BinaryDataType::TAG_ENUM8 && definition.width_bits != 8
      return nil if type.tag == BinaryDataType::TAG_ENUM16 && definition.width_bits != 16
      definition
    end

    private def self.decimal_byte_size(precision : Int32, scale : Int32) : Int32
      "Decimal(".bytesize + decimal_digits(precision) + 2 + decimal_digits(scale) + 1
    end

    private def self.decimal_digits(value : Int32) : Int32
      digits = 1
      remaining = value
      while remaining >= 10
        remaining //= 10
        digits += 1
      end
      digits
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
      return false if first < 0 || after < first || after > bytes.size
      return false unless after - first == expected.bytesize
      expected_bytes = expected.to_slice
      expected_bytes.size.times do |index|
        return false unless bytes[first + index] == expected_bytes[index]
      end
      true
    end
  end
end
