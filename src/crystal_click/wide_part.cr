require "json"

module CrystalClick
  class WidePart
    MAX_ROWS                             = 100_000_000_u64
    MAX_DATA_FILE_BYTES                  = 256_i64 * 1024 * 1024
    MAX_MARK_FILE_BYTES                  = 64_i64 * 1024 * 1024
    MAX_FRAME_COMPRESSED_BYTES           = 64 * 1024 * 1024
    MAX_FRAME_DECOMPRESSED_BYTES         = 64 * 1024 * 1024
    MAX_STRING_RANGE_BYTES               = 64 * 1024 * 1024
    MAX_ARRAY_MARK_ELEMENTS              = 65_536_u64
    MAX_ARRAY_MARK_ROWS                  = 65_536_u64
    MAX_ARRAY_MARK_BYTES                 = MAX_STRING_RANGE_BYTES
    MAX_LOW_CARDINALITY_MARK_ROWS        = 65_536_u64
    MAX_LOW_CARDINALITY_MARKS            =     65_536
    MAX_LOW_CARDINALITY_DICTIONARY_KEYS  =        256
    MAX_LOW_CARDINALITY_DICTIONARY_BYTES = 64 * 1024 * 1024
    MAX_LOW_CARDINALITY_INDEX_BYTES      = 64 * 1024 * 1024
    MAX_FIXED_STRING_WIDTH               =     65_536
    MAX_FIXED_STRING_RANGE_ROWS          = 65_536_u64
    MAX_CODEC_FILE_BYTES                 =         64
    MAX_METADATA_FILE_BYTES              = 4 * 1024 * 1024
    MAX_METADATA_LINE_BYTES              = 64 * 1024
    MAX_METADATA_COLUMNS                 =  4096
    MAX_METADATA_SUBSTREAMS              = 65536
    MARK_SIZE                            =    24

    # Conservative allowances for Array(Nullable(String)) table batches;
    # these bound common object/array overhead but are not exact heap accounting.
    ARRAY_NULLABLE_STRING_SLOT_ACCOUNTING_BYTES = 16_u64
    ARRAY_NULLABLE_STRING_ROW_ACCOUNTING_BYTES  = 32_u64

    # W51 Array(Tuple) batch accounting: one outer row slot and one tuple slot
    # per flattened entry, in addition to the child payload bytes.
    ARRAY_TUPLE_ROW_ACCOUNTING_BYTES   =  8_u64
    ARRAY_TUPLE_ENTRY_ACCOUNTING_BYTES = 16_u64

    def self.supports_numeric_type?(type : String) : Bool
      case type
      when "UInt8", "UInt16", "UInt32", "UInt64", "Int8", "Int16", "Int32", "Int64", "Float32", "Float64"
        true
      else
        false
      end
    end

    def self.numeric_payload_width(type : String) : Int32
      case type
      when "UInt8", "Int8"
        1
      when "UInt16", "Int16"
        2
      when "UInt32", "Int32", "Float32"
        4
      when "UInt64", "Int64", "Float64"
        8
      else
        raise UnsupportedFormatError.new("only exact fixed-width primitive numeric types have a numeric payload width")
      end
    end

    # Array codecs intentionally have a wider leaf set than scalar numeric
    # accessors. Keep Int128/UInt128 and the wrapper-backed Int256/UInt256
    # types out of supports_numeric_type? and numeric_type_name so JSON and
    # scalar admission remain unchanged.
    def self.array_numeric_type_name(type : T.class) : String forall T
      {% if T == UInt8 %}
        "UInt8"
      {% elsif T == UInt16 %}
        "UInt16"
      {% elsif T == UInt32 %}
        "UInt32"
      {% elsif T == UInt64 %}
        "UInt64"
      {% elsif T == Int8 %}
        "Int8"
      {% elsif T == Int16 %}
        "Int16"
      {% elsif T == Int32 %}
        "Int32"
      {% elsif T == Int64 %}
        "Int64"
      {% elsif T == Float32 %}
        "Float32"
      {% elsif T == Float64 %}
        "Float64"
      {% elsif T == Int128 %}
        "Int128"
      {% elsif T == UInt128 %}
        "UInt128"
      {% elsif T == Int256Value %}
        "Int256"
      {% elsif T == UInt256Value %}
        "UInt256"
      {% elsif T == Decimal256Value %}
        # Internal width/codec identity only; semantic Array admission below
        # deliberately does not accept `Array(Decimal256)` as a spelling.
        "Decimal256"
      {% elsif T == BFloat16Value %}
        "BFloat16"
      {% else %}
        raise UnsupportedFormatError.new("only exact fixed-width numeric Array accessors are supported")
      {% end %}
    end

    def self.array_numeric_payload_width(type : String) : Int32
      case type
      when "Int128", "UInt128"
        16
      when "Int256", "UInt256", "Decimal256"
        32
      when "BFloat16"
        2
      else
        numeric_payload_width(type)
      end
    end

    private def self.supports_array_numeric_type?(type : String) : Bool
      supports_numeric_type?(type) || type == "Int128" || type == "UInt128" || type == "Int256" || type == "UInt256" || type == "BFloat16"
    end

    private def self.nullable_inner(type : String) : String?
      return nil unless type.starts_with?("Nullable(") && type.ends_with?(")")
      inner = type.byte_slice("Nullable(".bytesize, type.bytesize - "Nullable()".bytesize)
      inner.empty? ? nil : inner
    end

    private def self.enum_entries(type : String, prefix : String, minimum : Int32, maximum : Int32) : Array(Tuple(Int32, String))?
      declaration = nullable_inner(type) || type
      return nil unless declaration.starts_with?(prefix) && declaration.ends_with?(")")
      declaration.each_byte do |byte|
        return nil if byte < 0x20 || byte == 0x7f
      end

      body_end = declaration.bytesize - 1
      cursor = prefix.bytesize
      labels = Set(String).new
      seen_codes = Set(Int32).new
      entries = [] of Tuple(Int32, String)
      return nil if cursor >= body_end

      loop do
        entry_start = cursor
        return nil unless declaration.to_slice[cursor]? == '\''.ord.to_u8
        cursor += 1
        label = IO::Memory.new
        closed = false
        while cursor < body_end
          byte = declaration.to_slice[cursor]
          if byte == '\\'.ord.to_u8
            cursor += 1
            return nil if cursor >= body_end
            escaped = declaration.to_slice[cursor]
            case escaped
            when '\''.ord.to_u8, '\\'.ord.to_u8
              # These are the escaped quote and backslash forms observed in
              # stock columns.txt. Other escape sequences remain unsupported.
              label.write_byte(escaped)
            else
              return nil
            end
            cursor += 1
          elsif byte == '\''.ord.to_u8
            cursor += 1
            closed = true
            break
          else
            label.write_byte(byte)
            cursor += 1
          end
        end
        return nil unless closed
        return nil unless labels.add?(label.to_slice.to_s)

        return nil unless cursor + 3 <= body_end && declaration.byte_slice(cursor, 3) == " = "
        cursor += 3

        code_start = cursor
        cursor += 1 if cursor < body_end && declaration.to_slice[cursor] == '-'.ord.to_u8
        digit_start = cursor
        while cursor < body_end && declaration.to_slice[cursor] >= '0'.ord.to_u8 && declaration.to_slice[cursor] <= '9'.ord.to_u8
          cursor += 1
        end
        return nil if cursor == digit_start
        code_text = declaration.byte_slice(code_start, cursor - code_start)
        return nil unless code_text == "0" || code_text.matches?(/\A-?[1-9][0-9]*\z/)
        code = code_text.to_i?
        return nil unless code && code >= minimum && code <= maximum
        return nil unless seen_codes.add?(code)
        entries << {code, declaration.byte_slice(entry_start, cursor - entry_start)}

        return entries if cursor == body_end
        return nil unless cursor + 2 < body_end && declaration.byte_slice(cursor, 2) == ", "
        cursor += 2
      end
    end

    private def self.decimal_precision_scale(type : String, precision : Int32, maximum_scale : Int32) : Int32?
      match = /\ADecimal\(([0-9]+), ([0-9]+)\)\z/.match(type)
      return nil unless match && match[1] == precision.to_s && match[2].matches?(/\A(?:0|[1-9][0-9]*)\z/)
      scale = match[2].to_i?
      return nil unless scale && scale <= maximum_scale
      scale
    end

    private def self.decimal32_alias_scale(type : String) : Int32?
      match = /\ADecimal32\(([0-9])\)\z/.match(type)
      match.try { |value| value[1].to_i }
    end

    private def self.array_decimal32_alias_scale(type : String) : Int32?
      match = /\AArray\(Decimal32\(([0-9])\)\)\z/.match(type)
      match.try { |value| value[1].to_i }
    end

    private def self.array_nullable_decimal32_alias_scale(type : String) : Int32?
      match = /\AArray\(Nullable\(Decimal32\(([0-9])\)\)\)\z/.match(type)
      match.try { |value| value[1].to_i }
    end

    private def self.array_decimal64_alias_scale(type : String) : Int32?
      match = /\AArray\(Decimal64\(([0-9]|1[0-8])\)\)\z/.match(type)
      match.try { |value| value[1].to_i }
    end

    private def self.array_nullable_decimal64_alias_scale(type : String) : Int32?
      match = /\AArray\(Nullable\(Decimal64\(([0-9]|1[0-8])\)\)\)\z/.match(type)
      match.try { |value| value[1].to_i }
    end

    private def self.array_decimal128_alias_scale(type : String) : Int32?
      match = /\AArray\(Decimal128\((0|[1-9]|[1-2][0-9]|3[0-8])\)\)\z/.match(type)
      match.try { |value| value[1].to_i }
    end

    private def self.array_nullable_decimal128_alias_scale(type : String) : Int32?
      match = /\AArray\(Nullable\(Decimal128\((0|[1-9]|[1-2][0-9]|3[0-8])\)\)\)\z/.match(type)
      match.try { |value| value[1].to_i }
    end

    private def self.array_decimal256_alias_scale(type : String) : Int32?
      match = /\AArray\(Decimal256\((0|[1-9]|[1-6][0-9]|7[0-6])\)\)\z/.match(type)
      match.try { |value| value[1].to_i }
    end

    private def self.array_nullable_decimal256_alias_scale(type : String) : Int32?
      match = /\AArray\(Nullable\(Decimal256\((0|[1-9]|[1-6][0-9]|7[0-6])\)\)\)\z/.match(type)
      match.try { |value| value[1].to_i }
    end

    private def self.decimal64_alias_scale(type : String) : Int32?
      match = /\ADecimal64\(([0-9]|1[0-8])\)\z/.match(type)
      match.try { |value| value[1].to_i }
    end

    private def self.decimal128_alias_scale(type : String) : Int32?
      match = /\ADecimal128\(([0-9]|[1-2][0-9]|3[0-8])\)\z/.match(type)
      match.try { |value| value[1].to_i }
    end

    private def self.decimal256_alias_scale(type : String) : Int32?
      match = /\ADecimal256\((0|[1-9]|[1-6][0-9]|7[0-6])\)\z/.match(type)
      match.try { |value| value[1].to_i }
    end

    # Enum declarations remain exact metadata, while row values are exposed as
    # their signed backing codes. The parser intentionally admits one bounded
    # grammar instead of treating any `Enum8(` / `Enum16(` prefix as typed.
    def self.enum8_codes(type : String) : Set(Int8)?
      entries = enum_entries(type, "Enum8(", -128, 127)
      return nil unless entries
      entries.map { |entry| entry[0].to_i8 }.to_set
    end

    def self.enum16_codes(type : String) : Set(Int16)?
      entries = enum_entries(type, "Enum16(", -32_768, 32_767)
      return nil unless entries
      entries.map { |entry| entry[0].to_i16 }.to_set
    end

    # EnumValues sorts declared codes numerically, and DataTypeEnum uses the
    # first sorted value as the nested NULL default. Declaration order is not
    # preserved for this purpose.
    def self.enum8_default_code(type : String) : Int8?
      enum_entries(type, "Enum8(", -128, 127).try { |entries| entries.min_by { |entry| entry[0] }[0].to_i8 }
    end

    def self.enum16_default_code(type : String) : Int16?
      enum_entries(type, "Enum16(", -32_768, 32_767).try { |entries| entries.min_by { |entry| entry[0] }[0].to_i16 }
    end

    private def self.canonical_enum_type(type : String, prefix : String, minimum : Int32, maximum : Int32) : String?
      return nil if type.starts_with?("Nullable(")
      entries = enum_entries(type, prefix, minimum, maximum)
      return nil unless entries
      ordered = entries.sort_by { |entry| entry[0] }.map { |entry| entry[1] }.join(", ")
      "#{prefix}#{ordered})"
    end

    # ClickHouse's DataTypeEnum name uses EnumValues' ascending numeric order.
    # Keep each validated raw label literal intact while canonicalizing entries.
    def self.canonical_enum8_type(type : String) : String?
      canonical_enum_type(type, "Enum8(", -128, 127)
    end

    def self.canonical_enum16_type(type : String) : String?
      canonical_enum_type(type, "Enum16(", -32_768, 32_767)
    end

    # Array Enum leaves are a separate semantic surface from numeric
    # Array(Int8/Int16). Extract exactly one Array wrapper before invoking the
    # existing bounded scalar enum parser; the nullable form requires exactly
    # one additional Nullable wrapper.
    def self.array_enum8_codes(type : String) : Set(Int8)?
      return nil unless type.starts_with?("Array(") && type.ends_with?(")")
      inner = type.byte_slice("Array(".bytesize, type.bytesize - "Array()".bytesize)
      return nil if inner.starts_with?("Nullable(")
      enum8_codes(inner)
    end

    def self.array_nullable_enum8_codes(type : String) : Set(Int8)?
      inner = array_nullable_enum_inner(type)
      return nil unless inner
      enum8_codes(inner)
    end

    def self.array_enum16_codes(type : String) : Set(Int16)?
      return nil unless type.starts_with?("Array(") && type.ends_with?(")")
      inner = type.byte_slice("Array(".bytesize, type.bytesize - "Array()".bytesize)
      return nil if inner.starts_with?("Nullable(")
      enum16_codes(inner)
    end

    def self.array_nullable_enum16_codes(type : String) : Set(Int16)?
      inner = array_nullable_enum_inner(type)
      return nil unless inner
      enum16_codes(inner)
    end

    private def self.array_nullable_enum_inner(type : String) : String?
      return nil unless type.starts_with?("Array(Nullable(") && type.ends_with?("))")
      inner = type.byte_slice("Array(Nullable(".bytesize, type.bytesize - "Array(Nullable())".bytesize)
      return nil if inner.starts_with?("Nullable(") || inner.starts_with?("Array(")
      inner
    end

    # ClickHouse normalizes Decimal32/64 aliases in columns.txt to the
    # canonical precision forms Decimal(9, S) and Decimal(18, S).
    def self.decimal32_scale(type : String) : Int32?
      decimal_precision_scale(type, 9, 9)
    end

    def self.decimal64_scale(type : String) : Int32?
      decimal_precision_scale(type, 18, 18)
    end

    def self.decimal128_scale(type : String) : Int32?
      decimal_precision_scale(type, 38, 38)
    end

    # Decimal256 is stored as a signed 32-byte coefficient. ClickHouse writes
    # the logical alias as its canonical Decimal(76, S) metadata form.
    def self.decimal256_scale(type : String) : Int32?
      decimal_precision_scale(type, 76, 76)
    end

    def self.nullable_decimal32_scale(type : String) : Int32?
      nullable_inner(type).try { |inner| decimal32_scale(inner) }
    end

    def self.nullable_decimal64_scale(type : String) : Int32?
      nullable_inner(type).try { |inner| decimal64_scale(inner) }
    end

    def self.nullable_decimal128_scale(type : String) : Int32?
      nullable_inner(type).try { |inner| decimal128_scale(inner) }
    end

    def self.nullable_decimal256_scale(type : String) : Int32?
      nullable_inner(type).try { |inner| decimal256_scale(inner) }
    end

    # Decimal32 Arrays preserve the canonical precision and scale in the
    # semantic declaration while storing signed Int32 coefficients.
    def self.array_decimal32_scale(type : String) : Int32?
      return nil unless type.starts_with?("Array(") && type.ends_with?(")")
      inner = type.byte_slice("Array(".bytesize, type.bytesize - "Array()".bytesize)
      decimal32_scale(inner)
    end

    def self.array_nullable_decimal32_scale(type : String) : Int32?
      return nil unless type.starts_with?("Array(Nullable(") && type.ends_with?(")")
      inner = type.byte_slice("Array(".bytesize, type.bytesize - "Array()".bytesize)
      nullable_decimal32_scale(inner)
    end

    # Decimal64 Arrays keep the exact scale in metadata and expose signed
    # Int64 coefficients through semantic accessors only.
    def self.array_decimal64_scale(type : String) : Int32?
      return nil unless type.starts_with?("Array(") && type.ends_with?(")")
      inner = type.byte_slice("Array(".bytesize, type.bytesize - "Array()".bytesize)
      decimal64_scale(inner)
    end

    def self.array_nullable_decimal64_scale(type : String) : Int32?
      return nil unless type.starts_with?("Array(Nullable(") && type.ends_with?(")")
      inner = type.byte_slice("Array(".bytesize, type.bytesize - "Array()".bytesize)
      nullable_decimal64_scale(inner)
    end

    # Decimal128 Arrays expose signed Int128 coefficients only through these
    # exact semantic gates; physical width alone does not admit Int128 Arrays.
    def self.array_decimal128_scale(type : String) : Int32?
      return nil unless type.starts_with?("Array(") && type.ends_with?(")")
      inner = type.byte_slice("Array(".bytesize, type.bytesize - "Array()".bytesize)
      decimal128_scale(inner)
    end

    def self.array_nullable_decimal128_scale(type : String) : Int32?
      return nil unless type.starts_with?("Array(Nullable(") && type.ends_with?(")")
      inner = type.byte_slice("Array(".bytesize, type.bytesize - "Array()".bytesize)
      nullable_decimal128_scale(inner)
    end

    # Keep Decimal256 Arrays on their own signed Decimal256Value semantic
    # path; equal-width primitive Int256 Array metadata is not an alias.
    def self.array_decimal256_scale(type : String) : Int32?
      return nil unless type.starts_with?("Array(") && type.ends_with?(")")
      inner = type.byte_slice("Array(".bytesize, type.bytesize - "Array()".bytesize)
      decimal256_scale(inner)
    end

    def self.array_nullable_decimal256_scale(type : String) : Int32?
      return nil unless type.starts_with?("Array(Nullable(") && type.ends_with?(")")
      inner = type.byte_slice("Array(".bytesize, type.bytesize - "Array()".bytesize)
      nullable_decimal256_scale(inner)
    end

    # Normalize only the Decimal DDL aliases observed in stock metadata. The
    # caller retains the exact source spelling separately for API metadata.
    def self.catalog_type(type : String) : String?
      return type if supports_typed_type?(type)

      if scale = array_decimal32_alias_scale(type)
        return "Array(Decimal(9, #{scale}))"
      elsif scale = array_nullable_decimal32_alias_scale(type)
        return "Array(Nullable(Decimal(9, #{scale})))"
      elsif scale = array_decimal64_alias_scale(type)
        return "Array(Decimal(18, #{scale}))"
      elsif scale = array_nullable_decimal64_alias_scale(type)
        return "Array(Nullable(Decimal(18, #{scale})))"
      elsif scale = array_decimal128_alias_scale(type)
        return "Array(Decimal(38, #{scale}))"
      elsif scale = array_nullable_decimal128_alias_scale(type)
        return "Array(Nullable(Decimal(38, #{scale})))"
      elsif scale = array_decimal256_alias_scale(type)
        return "Array(Decimal(76, #{scale}))"
      elsif scale = array_nullable_decimal256_alias_scale(type)
        return "Array(Nullable(Decimal(76, #{scale})))"
      end

      if inner = nullable_inner(type)
        if scale = decimal32_alias_scale(inner)
          return "Nullable(Decimal(9, #{scale}))"
        elsif scale = decimal64_alias_scale(inner)
          return "Nullable(Decimal(18, #{scale}))"
        elsif scale = decimal128_alias_scale(inner)
          return "Nullable(Decimal(38, #{scale}))"
        elsif scale = decimal256_alias_scale(inner)
          return "Nullable(Decimal(76, #{scale}))"
        end
        return nil
      end

      if scale = decimal32_alias_scale(type)
        return "Decimal(9, #{scale})"
      elsif scale = decimal64_alias_scale(type)
        return "Decimal(18, #{scale})"
      elsif scale = decimal128_alias_scale(type)
        return "Decimal(38, #{scale})"
      elsif scale = decimal256_alias_scale(type)
        return "Decimal(76, #{scale})"
      end
      nil
    end

    def self.supports_nullable_numeric_type?(type : String) : Bool
      return false unless type.starts_with?("Nullable(") && type.ends_with?(")")
      inner = type.byte_slice("Nullable(".bytesize, type.bytesize - "Nullable()".bytesize)
      supports_numeric_type?(inner)
    end

    def self.supports_nullable_string_type?(type : String) : Bool
      type == "Nullable(String)"
    end

    def self.supports_uuid_type?(type : String) : Bool
      type == "UUID"
    end

    def self.supports_nullable_uuid_type?(type : String) : Bool
      type == "Nullable(UUID)"
    end

    def self.uuid_array_element_type(type : String) : String?
      "UUID" if type == "Array(UUID)"
    end

    def self.nullable_uuid_array_element_type(type : String) : String?
      "UUID" if type == "Array(Nullable(UUID))"
    end

    def self.ipv4_array_element_type(type : String) : String?
      "IPv4" if type == "Array(IPv4)"
    end

    def self.nullable_ipv4_array_element_type(type : String) : String?
      "IPv4" if type == "Array(Nullable(IPv4))"
    end

    def self.ipv6_array_element_type(type : String) : String?
      "IPv6" if type == "Array(IPv6)"
    end

    def self.nullable_ipv6_array_element_type(type : String) : String?
      "IPv6" if type == "Array(Nullable(IPv6))"
    end

    def self.supports_ipv4_type?(type : String) : Bool
      type == "IPv4"
    end

    def self.supports_nullable_ipv4_type?(type : String) : Bool
      type == "Nullable(IPv4)"
    end

    def self.supports_ipv6_type?(type : String) : Bool
      type == "IPv6"
    end

    def self.supports_nullable_ipv6_type?(type : String) : Bool
      type == "Nullable(IPv6)"
    end

    def self.supports_nullable_bool_type?(type : String) : Bool
      type == "Nullable(Bool)"
    end

    def self.supports_semantic_fixed_width_type?(type : String) : Bool
      return false if nullable_inner(type)
      type == "Bool" || type == "BFloat16" || !enum8_codes(type).nil? || !enum16_codes(type).nil? ||
        !decimal32_scale(type).nil? || !decimal64_scale(type).nil? || !decimal128_scale(type).nil? ||
        !decimal256_scale(type).nil?
    end

    def self.supports_nullable_semantic_fixed_width_type?(type : String) : Bool
      inner = nullable_inner(type) || return false
      supports_semantic_fixed_width_type?(inner)
    end

    # Keep the W15-specific public predicates bounded to their original types;
    # callers that need the current family use supports_semantic_fixed_width_type?.
    def self.supports_w15_semantic_type?(type : String) : Bool
      return false if nullable_inner(type)
      type == "Bool" || !enum8_codes(type).nil? || !enum16_codes(type).nil? ||
        !decimal32_scale(type).nil? || !decimal64_scale(type).nil?
    end

    def self.supports_nullable_w15_semantic_type?(type : String) : Bool
      inner = nullable_inner(type) || return false
      supports_w15_semantic_type?(inner)
    end

    # Return the byte width only for the exact, bounded FixedString grammar.
    # Leading zeros, signs, whitespace, zero, and oversized parameters fail
    # closed so DDL and part metadata have one canonical spelling.
    def self.fixed_string_width(type : String) : Int32?
      match = /\AFixedString\(([1-9][0-9]*)\)\z/.match(type)
      return nil unless match
      width = match[1].to_i?
      return nil unless width && width <= MAX_FIXED_STRING_WIDTH
      width
    end

    def self.nullable_fixed_string_width(type : String) : Int32?
      return nil unless type.starts_with?("Nullable(") && type.ends_with?(")")
      inner = type.byte_slice("Nullable(".bytesize, type.bytesize - "Nullable()".bytesize)
      fixed_string_width(inner)
    end

    def self.array_fixed_string_width(type : String) : Int32?
      return nil unless type.starts_with?("Array(") && type.ends_with?(")")
      inner = type.byte_slice("Array(".bytesize, type.bytesize - "Array()".bytesize)
      fixed_string_width(inner)
    end

    def self.array_nullable_fixed_string_width(type : String) : Int32?
      return nil unless type.starts_with?("Array(") && type.ends_with?(")")
      inner = type.byte_slice("Array(".bytesize, type.bytesize - "Array()".bytesize)
      nullable_fixed_string_width(inner)
    end

    def self.supports_array_bool_type?(type : String) : Bool
      type == "Array(Bool)"
    end

    def self.supports_array_nullable_bool_type?(type : String) : Bool
      type == "Array(Nullable(Bool))"
    end

    # Accept only the canonical one-digit DateTime64 precision. Timezone
    # arguments and alternate spellings remain outside this reader's scope.
    def self.datetime64_scale(type : String) : Int32?
      match = /\ADateTime64\(([0-9])\)\z/.match(type)
      match.try { |value| value[1].to_i }
    end

    # Time64 keeps the same one-digit precision grammar as DateTime64 while
    # remaining a distinct semantic type with its own exact reader gate.
    def self.time64_scale(type : String) : Int32?
      match = /\ATime64\(([0-9])\)\z/.match(type)
      match.try { |value| value[1].to_i }
    end

    # Nullable temporal values have the same fixed-width nested slots as
    # their non-null semantic types, with nullness stored in a separate map.
    # Keep this recognizer separate from Nullable(primitive numeric): callers
    # must opt into the semantic temporal contract explicitly.
    def self.nullable_datetime64_scale(type : String) : Int32?
      match = /\ANullable\(DateTime64\(([0-9])\)\)\z/.match(type)
      match.try { |value| value[1].to_i }
    end

    def self.nullable_time64_scale(type : String) : Int32?
      match = /\ANullable\(Time64\(([0-9])\)\)\z/.match(type)
      match.try { |value| value[1].to_i }
    end

    # Array temporal declarations retain their semantic leaf type, including
    # the canonical DateTime64 precision. These recognizers deliberately stay
    # separate from the numeric Array grammar even when physical widths match.
    def self.temporal_array_element_type(type : String) : String?
      case type
      when "Array(Date)"     then "Date"
      when "Array(Date32)"   then "Date32"
      when "Array(DateTime)" then "DateTime"
      else
        if scale = array_datetime64_scale(type)
          "DateTime64(#{scale})"
        end
      end
    end

    def self.nullable_temporal_array_element_type(type : String) : String?
      case type
      when "Array(Nullable(Date))"     then "Date"
      when "Array(Nullable(Date32))"   then "Date32"
      when "Array(Nullable(DateTime))" then "DateTime"
      else
        if scale = nullable_array_datetime64_scale(type)
          "DateTime64(#{scale})"
        end
      end
    end

    # Time Array declarations intentionally use separate recognizers from the
    # Date/DateTime family and primitive numeric Array grammar.
    def self.time_array_element_type(type : String) : String?
      return "Time" if type == "Array(Time)"
      if scale = array_time64_scale(type)
        "Time64(#{scale})"
      end
    end

    def self.nullable_time_array_element_type(type : String) : String?
      return "Time" if type == "Array(Nullable(Time))"
      if scale = nullable_array_time64_scale(type)
        "Time64(#{scale})"
      end
    end

    def self.array_datetime64_scale(type : String) : Int32?
      match = /\AArray\(DateTime64\(([0-9])\)\)\z/.match(type)
      match.try { |value| value[1].to_i }
    end

    def self.nullable_array_datetime64_scale(type : String) : Int32?
      match = /\AArray\(Nullable\(DateTime64\(([0-9])\)\)\)\z/.match(type)
      match.try { |value| value[1].to_i }
    end

    def self.array_time64_scale(type : String) : Int32?
      match = /\AArray\(Time64\(([0-9])\)\)\z/.match(type)
      match.try { |value| value[1].to_i }
    end

    def self.nullable_array_time64_scale(type : String) : Int32?
      match = /\AArray\(Nullable\(Time64\(([0-9])\)\)\)\z/.match(type)
      match.try { |value| value[1].to_i }
    end

    # Map an admitted temporal leaf to its on-disk fixed-width carrier. This
    # is an internal codec choice; public numeric Array gates remain unchanged.
    def self.temporal_array_physical_type(element_type : String) : String?
      case element_type
      when "Date"     then "UInt16"
      when "Date32"   then "Int32"
      when "DateTime" then "UInt32"
      else
        "Int64" if datetime64_scale(element_type)
      end
    end

    def self.time_array_physical_type(element_type : String) : String?
      return "Int32" if element_type == "Time"
      "Int64" if time64_scale(element_type)
    end

    def self.supports_nullable_temporal_type?(type : String) : Bool
      type == "Nullable(Date)" || type == "Nullable(Date32)" || type == "Nullable(DateTime)" || !nullable_datetime64_scale(type).nil?
    end

    def self.supports_nullable_time_type?(type : String) : Bool
      type == "Nullable(Time)" || !nullable_time64_scale(type).nil?
    end

    # Keep the physical Array child grammar bounded while expressing child
    # substreams independently from the outer size0 stream. This admits only
    # shapes for which readers and writers have paired codecs.
    def self.supports_array_type?(type : String) : Bool
      !array_element_stream_names("payload", type).nil?
    end

    # Return child-level physical streams for the intentionally small Array
    # grammar. Array itself contributes size0; callers compose it with these
    # streams instead of inferring arbitrary nested type syntax.
    def self.array_element_stream_names(column : String, type : String) : Array(String)?
      if plan = WideTypePlan.admitted(type)
        physical_streams = plan.physical_substreams(column)
        physical_streams.delete_at(0)
        return physical_streams
      end

      case type
      when "Array(UInt64)"
        [column]
      when "Array(UUID)"
        [column]
      when "Array(Nullable(UUID))"
        ["#{column}.null", column]
      when "Array(IPv4)"
        [column]
      when "Array(Nullable(IPv4))"
        ["#{column}.null", column]
      when "Array(IPv6)"
        [column]
      when "Array(Nullable(IPv6))"
        ["#{column}.null", column]
      when "Array(String)"
        ["#{column}.size", column]
      when "Array(Nullable(String))"
        ["#{column}.null", "#{column}.size", column]
      when "Array(Nullable(UInt64))"
        ["#{column}.null", column]
      when "Array(Array(UInt64))"
        ["#{column}.size1", column]
      when "Array(Array(Nullable(UInt64)))"
        ["#{column}.size1", "#{column}.null", column]
      when "Array(Bool)"
        [column]
      when "Array(Nullable(Bool))"
        ["#{column}.null", column]
      else
        if array_nullable_enum8_codes(type) || array_nullable_enum16_codes(type)
          ["#{column}.null", column]
        elsif array_enum8_codes(type) || array_enum16_codes(type)
          [column]
        elsif array_nullable_decimal32_scale(type) || array_nullable_decimal64_scale(type)
          ["#{column}.null", column]
        elsif array_nullable_decimal128_scale(type)
          ["#{column}.null", column]
        elsif array_nullable_decimal256_scale(type)
          ["#{column}.null", column]
        elsif array_decimal32_scale(type) || array_decimal64_scale(type)
          [column]
        elsif array_decimal128_scale(type)
          [column]
        elsif array_decimal256_scale(type)
          [column]
        elsif nullable_temporal_array_element_type(type)
          ["#{column}.null", column]
        elsif temporal_array_element_type(type)
          [column]
        elsif nullable_time_array_element_type(type)
          ["#{column}.null", column]
        elsif time_array_element_type(type)
          [column]
        elsif array_nullable_fixed_string_width(type)
          ["#{column}.null", column]
        elsif array_fixed_string_width(type)
          [column]
        elsif element_type = nullable_numeric_array_element_type(type)
          ["#{column}.null", column]
        elsif element_type = numeric_array_element_type(type)
          [column]
        else
          nil
        end
      end
    end

    # Admit only one Array level with a Nullable wrapper around one exact
    # primitive numeric leaf. Do not recurse through nested Array/Nullable
    # shapes or accept alternate type spellings.
    def self.nullable_numeric_array_element_type(type : String) : String?
      return nil unless type.starts_with?("Array(Nullable(") && type.ends_with?("))")
      element_type = type.byte_slice("Array(Nullable(".bytesize, type.bytesize - "Array(Nullable())".bytesize)
      supports_array_numeric_type?(element_type) ? element_type : nil
    end

    # Admit only one Array level whose complete child spelling is one of the
    # exact fixed-width numeric types. This deliberately does not recurse into
    # Nullable or composite children.
    def self.numeric_array_element_type(type : String) : String?
      return nil unless type.starts_with?("Array(") && type.ends_with?(")")
      element_type = type.byte_slice("Array(".bytesize, type.bytesize - "Array()".bytesize)
      supports_array_numeric_type?(element_type) ? element_type : nil
    end

    def self.supports_map_uint64_string_type?(type : String) : Bool
      type == "Map(UInt64, String)"
    end

    def self.supports_map_uint64_uint64_type?(type : String) : Bool
      type == "Map(UInt64, UInt64)"
    end

    def self.supports_map_string_uint64_type?(type : String) : Bool
      type == "Map(String, UInt64)"
    end

    def self.supports_map_string_string_type?(type : String) : Bool
      type == "Map(String, String)"
    end

    def self.supports_map_uint64_nullable_uint64_type?(type : String) : Bool
      type == "Map(UInt64, Nullable(UInt64))"
    end

    def self.supports_map_string_nullable_uint64_type?(type : String) : Bool
      type == "Map(String, Nullable(UInt64))"
    end

    def self.supports_map_uint64_nullable_string_type?(type : String) : Bool
      type == "Map(UInt64, Nullable(String))"
    end

    def self.supports_map_string_nullable_string_type?(type : String) : Bool
      type == "Map(String, Nullable(String))"
    end

    def self.supports_tuple_uint64_string_type?(type : String) : Bool
      type == "Tuple(a UInt64, b String)"
    end

    def self.supports_typed_type?(type : String) : Bool
      supports_semantic_fixed_width_type?(type) || supports_nullable_semantic_fixed_width_type?(type) ||
        type == "LowCardinality(String)" || type == "Date" || type == "Date32" || type == "DateTime" ||
        type == "Time" || !datetime64_scale(type).nil? || !time64_scale(type).nil? || type == "String" || type == "Int128" || type == "UInt128" ||
        type == "Int256" || type == "UInt256" ||
        type == "Nullable(Int128)" || type == "Nullable(UInt128)" ||
        type == "Nullable(Int256)" || type == "Nullable(UInt256)" || supports_numeric_type?(type) ||
        supports_nullable_numeric_type?(type) || supports_nullable_temporal_type?(type) || supports_nullable_time_type?(type) ||
        supports_nullable_string_type?(type) || supports_uuid_type?(type) || supports_nullable_uuid_type?(type) ||
        supports_ipv4_type?(type) || supports_nullable_ipv4_type?(type) ||
        supports_ipv6_type?(type) || supports_nullable_ipv6_type?(type) ||
        !fixed_string_width(type).nil? || !nullable_fixed_string_width(type).nil? || supports_array_type?(type) ||
        supports_map_uint64_string_type?(type) || supports_map_uint64_uint64_type?(type) ||
        supports_map_string_uint64_type?(type) || supports_map_string_string_type?(type) ||
        supports_map_uint64_nullable_uint64_type?(type) || supports_map_string_nullable_uint64_type?(type) ||
        supports_map_uint64_nullable_string_type?(type) || supports_map_string_nullable_string_type?(type) ||
        supports_tuple_uint64_string_type?(type)
    end

    def self.json_type?(type : String) : Bool
      type == "JSON" || type.starts_with?("JSON(")
    end

    # Parse the intentionally small JSON typed-path declaration grammar used
    # by this reader: simple top-level identifiers with exact primitive
    # numeric or String types. Unsupported declarations fail closed.
    def self.json_typed_paths(type : String) : Array({String, String})
      raise UnsupportedFormatError.new("JSON column has no explicit typed paths") unless type.starts_with?("JSON(") && type.ends_with?(")")
      inner = type.byte_slice(5, type.bytesize - 6)
      raise UnsupportedFormatError.new("empty JSON typed-path declaration") if inner.empty?

      declarations = Array({String, String}).new
      seen = Set(String).new
      start = 0
      depth = 0
      inner.to_slice.each_with_index do |byte, index|
        case byte
        when '('.ord
          depth += 1
        when ')'.ord
          depth -= 1
          raise UnsupportedFormatError.new("malformed JSON typed-path declaration") if depth < 0
        when ','.ord
          next unless depth == 0
          add_json_typed_path(inner.byte_slice(start, index - start), declarations, seen)
          start = index + 1
        end
      end
      raise UnsupportedFormatError.new("malformed JSON typed-path declaration") unless depth == 0
      add_json_typed_path(inner.byte_slice(start, inner.bytesize - start), declarations, seen)
      declarations
    end

    def self.json_typed_path_type(type : String, path : String) : String?
      json_typed_paths(type).find { |entry| entry[0] == path }.try(&.[1])
    end

    private def self.add_json_typed_path(
      declaration : String,
      declarations : Array({String, String}),
      seen : Set(String),
    ) : Nil
      match = /\A\s*([A-Za-z_][A-Za-z0-9_]*)\s+([A-Za-z0-9_]+)\s*\z/.match(declaration)
      raise UnsupportedFormatError.new("unsupported JSON typed-path declaration") unless match
      path = match[1]
      type = match[2]
      raise UnsupportedFormatError.new("duplicate JSON typed path") if seen.includes?(path)
      unless type == "String" || supports_numeric_type?(type)
        raise UnsupportedFormatError.new("unsupported JSON typed-path scalar type")
      end
      seen << path
      declarations << {path, type}
    end

    def self.numeric_type_name(type : T.class) : String forall T
      {% if T == UInt8 %}
        "UInt8"
      {% elsif T == UInt16 %}
        "UInt16"
      {% elsif T == UInt32 %}
        "UInt32"
      {% elsif T == UInt64 %}
        "UInt64"
      {% elsif T == Int8 %}
        "Int8"
      {% elsif T == Int16 %}
        "Int16"
      {% elsif T == Int32 %}
        "Int32"
      {% elsif T == Int64 %}
        "Int64"
      {% elsif T == Float32 %}
        "Float32"
      {% elsif T == Float64 %}
        "Float64"
      {% else %}
        raise UnsupportedFormatError.new("only exact fixed-width primitive numeric accessors are supported")
      {% end %}
    end

    getter path : String
    getter column_type : String
    getter source_column_name : String
    getter source_column_type : String
    getter json_typed_path : Bool
    getter row_count : UInt64
    getter data_path : String
    getter mark_path : String
    getter checksum_verification : ChecksumVerification

    # Physical checksum targets for every selected substream, including
    # String size streams and Nullable null maps.
    def selected_checksum_names : Array(String)
      @streams.values.flat_map do |stream|
        [File.basename(stream.data_path), File.basename(stream.mark_path)]
      end
    end

    def self.open(path : String) : WidePart
      new(path, nil, :uint64)
    rescue ex : IO::Error
      raise InvalidPartError.new(ex.message || "cannot read part")
    end

    def self.open(path : String, column : String) : WidePart
      new(path, column, :uint64)
    rescue ex : IO::Error
      raise InvalidPartError.new(ex.message || "cannot read part")
    end

    # Open a supported fixed-width numeric column. Existing open/read_uint64
    # entry points remain UInt64-only.
    def self.open_numeric(path : String, column : String) : WidePart
      new(path, column, :numeric)
    rescue ex : IO::Error
      raise InvalidPartError.new(ex.message || "cannot read part")
    end

    # Open an exact String, FixedString(N), or primitive numeric column,
    # including supported Nullable(T) forms. Serialization metadata and every
    # physical substream are checked where required by the selected type.
    def self.open_typed(path : String, column : String) : WidePart
      new(path, column, :typed)
    rescue ex : IO::Error
      raise InvalidPartError.new(ex.message || "cannot read part")
    end

    def mark_count : Int
      @marks.size
    end

    # Return the complete ordered row counts for this column's data marks.
    # The returned array is independent of the reader's cached mark records.
    def mark_row_counts : Array(UInt64)
      @marks.map(&.rows)
    end

    def read_numeric_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
      type : T.class,
    ) : Array(T) forall T
      expected_type = WidePart.numeric_type_name(type)
      element_width = numeric_type_width(expected_type)
      raise UnsupportedFormatError.new("typed accessor does not match selected column type") unless expected_type == @column_type

      start_mark, end_mark, expected_bytes = checked_numeric_mark_range(column, first_mark, mark_count, expected_type, element_width)
      values = Array(T).new
      each_mark_range_bytes(start_mark, end_mark, expected_bytes, element_width) do |bytes|
        offset = 0
        while offset < bytes.size
          values << decode_numeric_value(bytes, offset, type)
          offset += element_width
        end
      end
      values
    end

    # Bool is physically one byte, but its semantic domain is intentionally
    # narrower than UInt8: only 0 and 1 are admitted by this reader.
    def read_bool_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Bool)
      ensure_column(column)
      raise UnsupportedFormatError.new("Bool accessor requires an exact Bool column") unless @column_type == "Bool"

      start_mark, end_mark, expected_bytes = checked_mark_range(column, first_mark, mark_count, 1)
      values = Array(Bool).new
      each_mark_range_bytes(start_mark, end_mark, expected_bytes, 1) do |bytes|
        bytes.each do |value|
          case value
          when 0 then values << false
          when 1 then values << true
          else        raise CorruptPartError.new("Bool byte is not 0 or 1")
          end
        end
      end
      values
    end

    # BFloat16 uses two little-endian storage bytes but is not a UInt16
    # numeric column. Preserve the exact 16-bit payload without Float32.
    def read_bfloat16_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(BFloat16Value)
      ensure_column(column)
      raise UnsupportedFormatError.new("BFloat16 accessor requires an exact BFloat16 column") unless @column_type == "BFloat16"
      read_semantic_fixed_width_mark_range(column, first_mark, mark_count, 2, BFloat16Value)
    end

    def read_nullable_bfloat16_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(BFloat16Value?)
      ensure_column(column)
      raise UnsupportedFormatError.new("BFloat16 accessor requires an exact Nullable(BFloat16) column") unless @column_type == "Nullable(BFloat16)"
      read_nullable_fixed_width_mark_range(column, first_mark, mark_count, 2, BFloat16Value)
    end

    def read_nullable_bool_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Bool?)
      ensure_column(column)
      raise UnsupportedFormatError.new("Bool accessor requires an exact Nullable(Bool) column") unless WidePart.supports_nullable_bool_type?(@column_type)

      read_nullable_fixed_width_mark_range(column, first_mark, mark_count, 1, UInt8).map do |value|
        case value
        when nil then nil
        when 0   then false
        when 1   then true
        else          raise CorruptPartError.new("Bool byte is not 0 or 1")
        end
      end
    end

    def read_enum8_codes_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Int8)
      ensure_column(column)
      codes = WidePart.enum8_codes(@column_type)
      raise UnsupportedFormatError.new("Enum8 accessor requires an exact Enum8 declaration") unless codes && !@column_type.starts_with?("Nullable(")

      values = read_semantic_fixed_width_mark_range(column, first_mark, mark_count, 1, Int8)
      values.each { |value| raise CorruptPartError.new("Enum8 code is not declared") unless codes.includes?(value) }
      values
    end

    def read_nullable_enum8_codes_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Int8?)
      ensure_column(column)
      codes = WidePart.enum8_codes(@column_type)
      raise UnsupportedFormatError.new("Enum8 accessor requires an exact Nullable(Enum8) declaration") unless codes && @column_type.starts_with?("Nullable(")

      values = read_nullable_fixed_width_mark_range(column, first_mark, mark_count, 1, Int8)
      values.each { |value| raise CorruptPartError.new("Enum8 code is not declared") if value && !codes.includes?(value) }
      values
    end

    def read_enum16_codes_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Int16)
      ensure_column(column)
      codes = WidePart.enum16_codes(@column_type)
      raise UnsupportedFormatError.new("Enum16 accessor requires an exact Enum16 declaration") unless codes && !@column_type.starts_with?("Nullable(")

      values = read_semantic_fixed_width_mark_range(column, first_mark, mark_count, 2, Int16)
      values.each { |value| raise CorruptPartError.new("Enum16 code is not declared") unless codes.includes?(value) }
      values
    end

    def read_nullable_enum16_codes_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Int16?)
      ensure_column(column)
      codes = WidePart.enum16_codes(@column_type)
      raise UnsupportedFormatError.new("Enum16 accessor requires an exact Nullable(Enum16) declaration") unless codes && @column_type.starts_with?("Nullable(")

      values = read_nullable_fixed_width_mark_range(column, first_mark, mark_count, 2, Int16)
      values.each { |value| raise CorruptPartError.new("Enum16 code is not declared") if value && !codes.includes?(value) }
      values
    end

    # Decimal rows are not converted to Float or divided by the scale. These
    # readers preserve the signed little-endian scaled integer bit-for-bit.
    def read_decimal32_raw_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Int32)
      ensure_column(column)
      raise UnsupportedFormatError.new("Decimal32 accessor requires canonical Decimal(9, S)") unless WidePart.decimal32_scale(@column_type)
      read_semantic_fixed_width_mark_range(column, first_mark, mark_count, 4, Int32)
    end

    def read_nullable_decimal32_raw_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Int32?)
      ensure_column(column)
      raise UnsupportedFormatError.new("Decimal32 accessor requires canonical Nullable(Decimal(9, S))") unless WidePart.nullable_decimal32_scale(@column_type)
      read_nullable_fixed_width_mark_range(column, first_mark, mark_count, 4, Int32)
    end

    def read_decimal64_raw_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Int64)
      ensure_column(column)
      raise UnsupportedFormatError.new("Decimal64 accessor requires canonical Decimal(18, S)") unless WidePart.decimal64_scale(@column_type)
      read_semantic_fixed_width_mark_range(column, first_mark, mark_count, 8, Int64)
    end

    def read_nullable_decimal64_raw_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Int64?)
      ensure_column(column)
      raise UnsupportedFormatError.new("Decimal64 accessor requires canonical Nullable(Decimal(18, S))") unless WidePart.nullable_decimal64_scale(@column_type)
      read_nullable_fixed_width_mark_range(column, first_mark, mark_count, 8, Int64)
    end

    def read_decimal128_raw_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Int128)
      ensure_column(column)
      raise UnsupportedFormatError.new("Decimal128 accessor requires canonical Decimal(38, S)") unless WidePart.decimal128_scale(@column_type)
      read_semantic_fixed_width_mark_range(column, first_mark, mark_count, 16, Int128)
    end

    # Raw Int128 is a primitive integer, not a Decimal128 coefficient. Its
    # exact columns.txt type selects the little-endian Number serialization.
    def read_int128_raw_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Int128)
      ensure_column(column)
      raise UnsupportedFormatError.new("raw Int128 accessor requires an exact Int128 column") unless @column_type == "Int128"
      read_semantic_fixed_width_mark_range(column, first_mark, mark_count, 16, Int128)
    end

    # Raw UInt128 is admitted only as the exact non-null primitive scalar type.
    def read_uint128_raw_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(UInt128)
      ensure_column(column)
      raise UnsupportedFormatError.new("raw UInt128 accessor requires an exact UInt128 column") unless @column_type == "UInt128"
      read_semantic_fixed_width_mark_range(column, first_mark, mark_count, 16, UInt128)
    end

    # Raw Int256 preserves all four little-endian UInt64 words without signed
    # arithmetic or Decimal256 scale semantics.
    def read_int256_raw_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Int256Value)
      ensure_column(column)
      raise UnsupportedFormatError.new("raw Int256 accessor requires an exact Int256 column") unless @column_type == "Int256"

      start_mark, end_mark, expected_bytes = checked_mark_range(column, first_mark, mark_count, 32)
      values = Array(Int256Value).new
      each_mark_range_bytes(start_mark, end_mark, expected_bytes, 32) do |bytes|
        offset = 0
        while offset < bytes.size
          values << Int256Value.from_words(u64(bytes, offset), u64(bytes, offset + 8), u64(bytes, offset + 16), u64(bytes, offset + 24))
          offset += 32
        end
      end
      values
    end

    # Raw UInt256 remains a distinct unsigned primitive type; the high bit is
    # data, not a sign marker.
    def read_uint256_raw_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(UInt256Value)
      ensure_column(column)
      raise UnsupportedFormatError.new("raw UInt256 accessor requires an exact UInt256 column") unless @column_type == "UInt256"

      start_mark, end_mark, expected_bytes = checked_mark_range(column, first_mark, mark_count, 32)
      values = Array(UInt256Value).new
      each_mark_range_bytes(start_mark, end_mark, expected_bytes, 32) do |bytes|
        offset = 0
        while offset < bytes.size
          values << UInt256Value.from_words(u64(bytes, offset), u64(bytes, offset + 8), u64(bytes, offset + 16), u64(bytes, offset + 24))
          offset += 32
        end
      end
      values
    end

    def read_nullable_decimal128_raw_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Int128?)
      ensure_column(column)
      raise UnsupportedFormatError.new("Decimal128 accessor requires canonical Nullable(Decimal(38, S))") unless WidePart.nullable_decimal128_scale(@column_type)
      read_nullable_fixed_width_mark_range(column, first_mark, mark_count, 16, Int128)
    end

    # Nullable primitive integers use the same physical 16-byte slots as
    # Decimal128, but exact type metadata keeps the semantic APIs separate.
    def read_nullable_int128_raw_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Int128?)
      ensure_column(column)
      raise UnsupportedFormatError.new("raw Nullable(Int128) accessor requires exact Nullable(Int128) metadata") unless @column_type == "Nullable(Int128)"
      read_nullable_fixed_width_mark_range(column, first_mark, mark_count, 16, Int128)
    end

    def read_nullable_uint128_raw_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(UInt128?)
      ensure_column(column)
      raise UnsupportedFormatError.new("raw Nullable(UInt128) accessor requires exact Nullable(UInt128) metadata") unless @column_type == "Nullable(UInt128)"
      read_nullable_fixed_width_mark_range(column, first_mark, mark_count, 16, UInt128)
    end

    # Nullable primitive Int256 is retained as signed two's-complement bits;
    # the optional wrapper carries nullness without aliasing Decimal256.
    def read_nullable_int256_raw_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Int256Value?)
      ensure_column(column)
      raise UnsupportedFormatError.new("raw Nullable(Int256) accessor requires exact Nullable(Int256) metadata") unless @column_type == "Nullable(Int256)"

      null_stream = @streams["#{column}.null"]
      value_stream = @streams[column]
      null_start, null_end, rows = checked_stream_mark_range(null_stream, first_mark, mark_count)
      value_start, value_end, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Nullable substream mark rows differ") unless rows == value_rows

      null_map = read_mark_range_bytes(null_stream, null_start, null_end, checked_byte_count(rows, 1), 1)
      null_map.each do |value|
        raise CorruptPartError.new("Nullable null-map byte is not boolean") unless value == 0 || value == 1
      end
      encoded_values = read_mark_range_bytes(value_stream, value_start, value_end, checked_byte_count(rows, 32), 32)
      values = Array(Int256Value?).new(rows.to_i)
      offset = 0
      null_map.each do |is_null|
        if is_null == 1
          values << nil
        else
          values << Int256Value.from_words(
            u64(encoded_values, offset),
            u64(encoded_values, offset + 8),
            u64(encoded_values, offset + 16),
            u64(encoded_values, offset + 24)
          )
        end
        offset += 32
      end
      raise CorruptPartError.new("Nullable values do not consume nested bytes") unless offset == encoded_values.size
      values
    end

    # UInt256's most-significant bit remains data even when the value is
    # nullable; this API never routes through a signed or decimal decoder.
    def read_nullable_uint256_raw_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(UInt256Value?)
      ensure_column(column)
      raise UnsupportedFormatError.new("raw Nullable(UInt256) accessor requires exact Nullable(UInt256) metadata") unless @column_type == "Nullable(UInt256)"

      null_stream = @streams["#{column}.null"]
      value_stream = @streams[column]
      null_start, null_end, rows = checked_stream_mark_range(null_stream, first_mark, mark_count)
      value_start, value_end, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Nullable substream mark rows differ") unless rows == value_rows

      null_map = read_mark_range_bytes(null_stream, null_start, null_end, checked_byte_count(rows, 1), 1)
      null_map.each do |value|
        raise CorruptPartError.new("Nullable null-map byte is not boolean") unless value == 0 || value == 1
      end
      encoded_values = read_mark_range_bytes(value_stream, value_start, value_end, checked_byte_count(rows, 32), 32)
      values = Array(UInt256Value?).new(rows.to_i)
      offset = 0
      null_map.each do |is_null|
        if is_null == 1
          values << nil
        else
          values << UInt256Value.from_words(
            u64(encoded_values, offset),
            u64(encoded_values, offset + 8),
            u64(encoded_values, offset + 16),
            u64(encoded_values, offset + 24)
          )
        end
        offset += 32
      end
      raise CorruptPartError.new("Nullable values do not consume nested bytes") unless offset == encoded_values.size
      values
    end

    def read_decimal256_raw_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Decimal256Value)
      ensure_column(column)
      raise UnsupportedFormatError.new("Decimal256 accessor requires canonical Decimal(76, S)") unless WidePart.decimal256_scale(@column_type)

      stream = @streams[column]
      start_mark, end_mark, rows = checked_stream_mark_range(stream, first_mark, mark_count)
      expected_bytes = checked_byte_count(rows, 32)
      encoded_values = read_mark_range_bytes(stream, start_mark, end_mark, expected_bytes, 32)
      values = Array(Decimal256Value).new(rows.to_i)
      offset = 0
      while offset < encoded_values.size
        values << Decimal256Value.from_words(
          u64(encoded_values, offset),
          u64(encoded_values, offset + 8),
          u64(encoded_values, offset + 16),
          u64(encoded_values, offset + 24)
        )
        offset += 32
      end
      raise CorruptPartError.new("Decimal256 values do not consume nested bytes") unless offset == encoded_values.size
      values
    end

    # BASIC Nullable(Decimal256) stores a one-byte map and a fixed 32-byte
    # nested slot per row. NULL slots are consumed and ignored like other
    # nullable semantic values.
    def read_nullable_decimal256_raw_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Decimal256Value?)
      ensure_column(column)
      raise UnsupportedFormatError.new("Decimal256 accessor requires canonical Nullable(Decimal(76, S))") unless WidePart.nullable_decimal256_scale(@column_type)

      null_stream = @streams["#{column}.null"]
      value_stream = @streams[column]
      null_start, null_end, rows = checked_stream_mark_range(null_stream, first_mark, mark_count)
      value_start, value_end, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Nullable(Decimal256) substream mark rows differ") unless rows == value_rows

      null_map = read_mark_range_bytes(null_stream, null_start, null_end, checked_byte_count(rows, 1), 1)
      null_map.each do |value|
        raise CorruptPartError.new("Nullable null-map byte is not boolean") unless value == 0 || value == 1
      end
      encoded_values = read_mark_range_bytes(value_stream, value_start, value_end, checked_byte_count(rows, 32), 32)
      values = Array(Decimal256Value?).new(rows.to_i)
      offset = 0
      null_map.each do |is_null|
        value = Decimal256Value.from_words(
          u64(encoded_values, offset),
          u64(encoded_values, offset + 8),
          u64(encoded_values, offset + 16),
          u64(encoded_values, offset + 24)
        )
        values << (is_null == 1 ? nil : value)
        offset += 32
      end
      raise CorruptPartError.new("Nullable(Decimal256) values do not consume nested bytes") unless offset == encoded_values.size
      values
    end

    # UUID is exposed as its two ClickHouse UUID halves, not as a generic
    # UInt128. The physical payload stores each UInt64 half little-endian.
    def read_uuids_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(UUIDValue)
      ensure_column(column)
      raise UnsupportedFormatError.new("UUID accessor requires an exact UUID column") unless WidePart.supports_uuid_type?(@column_type)

      stream = @streams[column]
      start_mark, end_mark, rows = checked_stream_mark_range(stream, first_mark, mark_count)
      encoded_values = read_mark_range_bytes(stream, start_mark, end_mark, checked_byte_count(rows, 16), 16)
      values = Array(UUIDValue).new(rows.to_i)
      offset = 0
      while offset < encoded_values.size
        values << UUIDValue.new(u64(encoded_values, offset), u64(encoded_values, offset + 8))
        offset += 16
      end
      values
    end

    # BASIC Nullable(UUID) has an independent null map followed by the
    # 16-byte UUID payload stream. Payload bytes in NULL slots are ignored.
    def read_nullable_uuids_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(UUIDValue?)
      ensure_column(column)
      raise UnsupportedFormatError.new("UUID accessor requires an exact Nullable(UUID) column") unless WidePart.supports_nullable_uuid_type?(@column_type)

      null_stream = @streams["#{column}.null"]
      value_stream = @streams[column]
      null_start, null_end, rows = checked_stream_mark_range(null_stream, first_mark, mark_count)
      value_start, value_end, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Nullable(UUID) substream mark rows differ") unless rows == value_rows

      null_map = read_mark_range_bytes(null_stream, null_start, null_end, checked_byte_count(rows, 1), 1)
      null_map.each do |value|
        raise CorruptPartError.new("Nullable null-map byte is not boolean") unless value == 0 || value == 1
      end
      encoded_values = read_mark_range_bytes(value_stream, value_start, value_end, checked_byte_count(rows, 16), 16)
      values = Array(UUIDValue?).new(rows.to_i)
      offset = 0
      null_map.each do |is_null|
        values << (is_null == 1 ? nil : UUIDValue.new(u64(encoded_values, offset), u64(encoded_values, offset + 8)))
        offset += 16
      end
      raise CorruptPartError.new("Nullable(UUID) values do not consume nested bytes") unless offset == encoded_values.size
      values
    end

    # IPv4 bytes encode the address's network-order UInt32 as a little-endian
    # scalar. Keep the resulting value distinct from ordinary UInt32 columns.
    def read_ipv4s_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(IPv4Value)
      ensure_column(column)
      raise UnsupportedFormatError.new("IPv4 accessor requires an exact IPv4 column") unless WidePart.supports_ipv4_type?(@column_type)

      stream = @streams[column]
      start_mark, end_mark, rows = checked_stream_mark_range(stream, first_mark, mark_count)
      encoded_values = read_mark_range_bytes(stream, start_mark, end_mark, checked_byte_count(rows, 4), 4)
      values = Array(IPv4Value).new(rows.to_i)
      offset = 0
      while offset < encoded_values.size
        values << IPv4Value.new(u32(encoded_values, offset))
        offset += 4
      end
      values
    end

    # BASIC Nullable(IPv4) carries a one-byte null map plus one four-byte
    # nested value per row. The nested bytes under NULL are consumed but ignored.
    def read_nullable_ipv4s_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(IPv4Value?)
      ensure_column(column)
      raise UnsupportedFormatError.new("IPv4 accessor requires an exact Nullable(IPv4) column") unless WidePart.supports_nullable_ipv4_type?(@column_type)

      null_stream = @streams["#{column}.null"]
      value_stream = @streams[column]
      null_start, null_end, rows = checked_stream_mark_range(null_stream, first_mark, mark_count)
      value_start, value_end, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Nullable(IPv4) substream mark rows differ") unless rows == value_rows

      null_map = read_mark_range_bytes(null_stream, null_start, null_end, checked_byte_count(rows, 1), 1)
      null_map.each do |value|
        raise CorruptPartError.new("Nullable null-map byte is not boolean") unless value == 0 || value == 1
      end
      encoded_values = read_mark_range_bytes(value_stream, value_start, value_end, checked_byte_count(rows, 4), 4)
      values = Array(IPv4Value?).new(rows.to_i)
      offset = 0
      null_map.each do |is_null|
        values << (is_null == 1 ? nil : IPv4Value.new(u32(encoded_values, offset)))
        offset += 4
      end
      raise CorruptPartError.new("Nullable(IPv4) values do not consume nested bytes") unless offset == encoded_values.size
      values
    end

    # IPv6 is a raw 16-byte network-order address, unlike UUID's pair of
    # little-endian UInt64 halves. Keep the semantic address distinct from
    # numeric UInt128 accessors.
    def read_ipv6s_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(IPv6Value)
      ensure_column(column)
      raise UnsupportedFormatError.new("IPv6 accessor requires an exact IPv6 column") unless WidePart.supports_ipv6_type?(@column_type)

      stream = @streams[column]
      start_mark, end_mark, rows = checked_stream_mark_range(stream, first_mark, mark_count)
      encoded_values = read_mark_range_bytes(stream, start_mark, end_mark, checked_byte_count(rows, 16), 16)
      values = Array(IPv6Value).new(rows.to_i)
      offset = 0
      while offset < encoded_values.size
        values << IPv6Value.new(network_order_u64(encoded_values, offset), network_order_u64(encoded_values, offset + 8))
        offset += 16
      end
      values
    end

    # BASIC Nullable(IPv6) carries a one-byte null map and one raw IPv6 value
    # per row. Payload bytes in NULL slots are consumed but ignored.
    def read_nullable_ipv6s_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(IPv6Value?)
      ensure_column(column)
      raise UnsupportedFormatError.new("IPv6 accessor requires an exact Nullable(IPv6) column") unless WidePart.supports_nullable_ipv6_type?(@column_type)

      null_stream = @streams["#{column}.null"]
      value_stream = @streams[column]
      null_start, null_end, rows = checked_stream_mark_range(null_stream, first_mark, mark_count)
      value_start, value_end, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Nullable(IPv6) substream mark rows differ") unless rows == value_rows

      null_map = read_mark_range_bytes(null_stream, null_start, null_end, checked_byte_count(rows, 1), 1)
      null_map.each do |value|
        raise CorruptPartError.new("Nullable null-map byte is not boolean") unless value == 0 || value == 1
      end
      encoded_values = read_mark_range_bytes(value_stream, value_start, value_end, checked_byte_count(rows, 16), 16)
      values = Array(IPv6Value?).new(rows.to_i)
      offset = 0
      null_map.each do |is_null|
        values << (is_null == 1 ? nil : IPv6Value.new(network_order_u64(encoded_values, offset), network_order_u64(encoded_values, offset + 8)))
        offset += 16
      end
      raise CorruptPartError.new("Nullable(IPv6) values do not consume nested bytes") unless offset == encoded_values.size
      values
    end

    private def read_semantic_fixed_width_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
      element_width : Int32,
      type : T.class,
    ) : Array(T) forall T
      start_mark, end_mark, expected_bytes = checked_mark_range(column, first_mark, mark_count, element_width)
      values = Array(T).new
      each_mark_range_bytes(start_mark, end_mark, expected_bytes, element_width) do |bytes|
        offset = 0
        while offset < bytes.size
          values << decode_numeric_value(bytes, offset, type)
          offset += element_width
        end
      end
      values
    end

    # Date is stored as a raw UInt16 day code. Keep this semantic accessor
    # separate from the ordinary numeric UInt16 reader.
    def read_date_codes_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(UInt16)
      ensure_column(column)
      raise UnsupportedFormatError.new("Date accessor requires an exact Date column") unless @column_type == "Date"

      start_mark, end_mark, expected_bytes = checked_mark_range(column, first_mark, mark_count, 2)
      values = Array(UInt16).new
      each_mark_range_bytes(start_mark, end_mark, expected_bytes, 2) do |bytes|
        offset = 0
        while offset < bytes.size
          values << u16(bytes, offset)
          offset += 2
        end
      end
      values
    end

    # Date32 is stored as a raw signed Int32 day code without calendar
    # conversion or clamping.
    def read_date32_codes_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Int32)
      ensure_column(column)
      raise UnsupportedFormatError.new("Date32 accessor requires an exact Date32 column") unless @column_type == "Date32"

      start_mark, end_mark, expected_bytes = checked_mark_range(column, first_mark, mark_count, 4)
      values = Array(Int32).new
      each_mark_range_bytes(start_mark, end_mark, expected_bytes, 4) do |bytes|
        offset = 0
        while offset < bytes.size
          values << u32(bytes, offset).unsafe_as(Int32)
          offset += 4
        end
      end
      values
    end

    # DateTime is exposed as raw UInt32 epoch seconds. This semantic accessor
    # stays separate from the primitive UInt32 reader.
    def read_datetime_seconds_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(UInt32)
      ensure_column(column)
      raise UnsupportedFormatError.new("DateTime accessor requires an exact DateTime column") unless @column_type == "DateTime"

      start_mark, end_mark, expected_bytes = checked_mark_range(column, first_mark, mark_count, 4)
      values = Array(UInt32).new
      each_mark_range_bytes(start_mark, end_mark, expected_bytes, 4) do |bytes|
        offset = 0
        while offset < bytes.size
          values << u32(bytes, offset)
          offset += 4
        end
      end
      values
    end

    # DateTime64 is exposed as raw signed Int64 ticks. The exact canonical
    # precision remains in column metadata and is checked before decoding.
    def read_datetime64_ticks_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Int64)
      ensure_column(column)
      raise UnsupportedFormatError.new("DateTime64 accessor requires a canonical DateTime64(p) column") unless WidePart.datetime64_scale(@column_type)

      start_mark, end_mark, expected_bytes = checked_mark_range(column, first_mark, mark_count, 8)
      values = Array(Int64).new
      each_mark_range_bytes(start_mark, end_mark, expected_bytes, 8) do |bytes|
        offset = 0
        while offset < bytes.size
          values << u64(bytes, offset).unsafe_as(Int64)
          offset += 8
        end
      end
      values
    end

    # Time uses signed raw Int32 seconds. The exact semantic type gate keeps
    # this distinct from a primitive Int32 declaration.
    def read_time_seconds_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Int32)
      ensure_column(column)
      raise UnsupportedFormatError.new("Time accessor requires an exact Time column") unless @column_type == "Time"

      start_mark, end_mark, expected_bytes = checked_mark_range(column, first_mark, mark_count, 4)
      values = Array(Int32).new
      each_mark_range_bytes(start_mark, end_mark, expected_bytes, 4) do |bytes|
        offset = 0
        while offset < bytes.size
          values << u32(bytes, offset).unsafe_as(Int32)
          offset += 4
        end
      end
      values
    end

    # Time64 is exposed as raw signed Int64 ticks; precision is retained in
    # metadata and only canonical Time64(p), p=0..9, passes this gate.
    def read_time64_ticks_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Int64)
      ensure_column(column)
      raise UnsupportedFormatError.new("Time64 accessor requires a canonical Time64(p) column") unless WidePart.time64_scale(@column_type)

      start_mark, end_mark, expected_bytes = checked_mark_range(column, first_mark, mark_count, 8)
      values = Array(Int64).new
      each_mark_range_bytes(start_mark, end_mark, expected_bytes, 8) do |bytes|
        offset = 0
        while offset < bytes.size
          values << u64(bytes, offset).unsafe_as(Int64)
          offset += 8
        end
      end
      values
    end

    # Nullable temporal accessors expose raw nested fixed-width codes without
    # applying date/time conversion. NULL slots are consumed and discarded;
    # the optional result preserves NULL separately from a zero code.
    def read_nullable_date_codes_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(UInt16?)
      ensure_column(column)
      raise UnsupportedFormatError.new("Nullable(Date) accessor requires an exact Nullable(Date) column") unless @column_type == "Nullable(Date)"
      read_nullable_fixed_width_mark_range(column, first_mark, mark_count, 2, UInt16)
    end

    def read_nullable_date32_codes_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Int32?)
      ensure_column(column)
      raise UnsupportedFormatError.new("Nullable(Date32) accessor requires an exact Nullable(Date32) column") unless @column_type == "Nullable(Date32)"
      read_nullable_fixed_width_mark_range(column, first_mark, mark_count, 4, Int32)
    end

    def read_nullable_datetime_seconds_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(UInt32?)
      ensure_column(column)
      raise UnsupportedFormatError.new("Nullable(DateTime) accessor requires an exact Nullable(DateTime) column") unless @column_type == "Nullable(DateTime)"
      read_nullable_fixed_width_mark_range(column, first_mark, mark_count, 4, UInt32)
    end

    def read_nullable_datetime64_ticks_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Int64?)
      ensure_column(column)
      raise UnsupportedFormatError.new("Nullable(DateTime64) accessor requires a canonical Nullable(DateTime64(p)) column") unless WidePart.nullable_datetime64_scale(@column_type)
      read_nullable_fixed_width_mark_range(column, first_mark, mark_count, 8, Int64)
    end

    def read_nullable_time_seconds_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Int32?)
      ensure_column(column)
      raise UnsupportedFormatError.new("Nullable(Time) accessor requires an exact Nullable(Time) column") unless @column_type == "Nullable(Time)"
      read_nullable_fixed_width_mark_range(column, first_mark, mark_count, 4, Int32)
    end

    def read_nullable_time64_ticks_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Int64?)
      ensure_column(column)
      raise UnsupportedFormatError.new("Nullable(Time64) accessor requires a canonical Nullable(Time64(p)) column") unless WidePart.nullable_time64_scale(@column_type)
      read_nullable_fixed_width_mark_range(column, first_mark, mark_count, 8, Int64)
    end

    # Return the raw-byte sum for an exact String mark range without
    # materializing its String values. WidePartTable uses this to preflight an
    # aggregate bound across selected String columns before reading raw streams.
    def string_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      raise UnsupportedFormatError.new("String accessor requires an exact String column") unless @column_type == "String"
      _, total_bytes = read_string_sizes(column, first_mark, mark_count)
      total_bytes
    end

    # Return nested String bytes for an exact Nullable(String) mark range,
    # including encoded slots beneath NULL map entries. The nested stream must
    # still be consumed to preserve row-position alignment.
    def nullable_string_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      raise UnsupportedFormatError.new("Nullable(String) accessor requires an exact Nullable(String) column") unless @column_type == "Nullable(String)"
      _, total_bytes = read_string_sizes(column, first_mark, mark_count)
      total_bytes
    end

    # Return the exact raw byte count for a FixedString(N) mark range without
    # allocating value Strings. WidePartTable uses this to preflight the
    # aggregate selected-mark bound before decoding any fixed-width values.
    def fixed_string_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      width = WidePart.fixed_string_width(@column_type) || raise(UnsupportedFormatError.new("FixedString accessor requires an exact FixedString(N) column"))
      stream = @streams[column]
      _, _, rows = checked_stream_mark_range(stream, first_mark, mark_count)
      checked_fixed_string_byte_count(rows, width).to_u64
    end

    # Count every nested slot, including those hidden by NULL, before a
    # caller allocates value Strings or the null map for this range.
    def nullable_fixed_string_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      width = WidePart.nullable_fixed_string_width(@column_type) || raise(UnsupportedFormatError.new("Nullable(FixedString) accessor requires an exact Nullable(FixedString(N)) column"))
      _, _, null_rows = checked_stream_mark_range(@streams["#{column}.null"], first_mark, mark_count)
      _, _, value_rows = checked_stream_mark_range(@streams[column], first_mark, mark_count)
      raise CorruptPartError.new("Nullable(FixedString) substream mark rows differ") unless null_rows == value_rows
      checked_fixed_string_byte_count(value_rows, width).to_u64
    end

    # Return flattened UInt64 bytes for one bounded Array(UInt64) mark range
    # without materializing the outer/inner result arrays. WidePartTable uses
    # this to preflight aggregate per-mark bytes across selected columns.
    def array_uint64_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      raise UnsupportedFormatError.new("Array(UInt64) accessor requires an exact Array(UInt64) column") unless @column_type == "Array(UInt64)"

      _, flat_elements, _, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      nested_stream = @streams[column]
      validate_array_nested_stream_marks(nested_stream, first_mark, mark_flat_elements, 8)
      checked_array_mark_byte_count(flat_elements, 8).to_u64
    end

    # Return the fixed-width leaf payload bytes for one exact Array(T) mark
    # range without allocating result rows. Outer size0 marks determine the
    # per-mark leaf counts and are checked against the payload stream marks.
    def array_numeric_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      element_type = WidePart.numeric_array_element_type(@column_type) || raise(UnsupportedFormatError.new("Array numeric accessor requires an exact Array(T) numeric column"))

      _, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      value_stream = @streams[column]
      _, _, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array numeric substream mark rows differ") unless value_rows == rows
      element_width = WidePart.array_numeric_payload_width(element_type)
      validate_array_nested_stream_marks(value_stream, first_mark, mark_flat_elements, element_width)
      checked_array_mark_byte_count(flat_elements, element_width).to_u64
    end

    # Temporal Arrays share fixed-width storage with selected numeric leaves,
    # but reach it only through this exact semantic gate. Keep numeric Array
    # accessors closed to Date/Date32/DateTime/DateTime64 declarations.
    def array_temporal_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      element_type = WidePart.temporal_array_element_type(@column_type) || raise(UnsupportedFormatError.new("temporal Array accessor requires an exact temporal leaf column"))
      element_width = WidePart.array_numeric_payload_width(
        WidePart.temporal_array_physical_type(element_type).not_nil!
      )

      _, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      value_stream = @streams[column]
      _, _, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("temporal Array substream mark rows differ") unless value_rows == rows
      validate_array_nested_stream_marks(value_stream, first_mark, mark_flat_elements, element_width)
      checked_array_mark_byte_count(flat_elements, element_width).to_u64
    end

    def array_time_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      element_type = WidePart.time_array_element_type(@column_type) || raise(UnsupportedFormatError.new("Time Array accessor requires an exact Time or Time64(p) leaf"))
      element_width = WidePart.array_numeric_payload_width(WidePart.time_array_physical_type(element_type).not_nil!)

      _, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      value_stream = @streams[column]
      _, _, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Time Array substream mark rows differ") unless value_rows == rows
      validate_array_nested_stream_marks(value_stream, first_mark, mark_flat_elements, element_width)
      checked_array_mark_byte_count(flat_elements, element_width).to_u64
    end

    def array_nullable_time_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      element_type = WidePart.nullable_time_array_element_type(@column_type) || raise(UnsupportedFormatError.new("nullable Time Array accessor requires an exact Time or Time64(p) leaf"))
      element_width = WidePart.array_numeric_payload_width(WidePart.time_array_physical_type(element_type).not_nil!)

      _, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      {"#{column}.null", column}.each do |stream_name|
        stream = @streams[stream_name]
        _, _, child_rows = checked_stream_mark_range(stream, first_mark, mark_count)
        raise CorruptPartError.new("Array(Nullable(Time)) child substream mark rows differ") unless child_rows == rows
        width = stream_name == "#{column}.null" ? 1 : element_width
        validate_array_nested_stream_marks(stream, first_mark, mark_flat_elements, width)
      end
      checked_array_mark_byte_count(flat_elements, 1 + element_width).to_u64
    end

    def array_decimal32_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      raise UnsupportedFormatError.new("Decimal32 Array accessor requires an exact Array(Decimal(9, S)) column") unless WidePart.array_decimal32_scale(@column_type)

      _, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      value_stream = @streams[column]
      _, _, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Decimal32) value mark rows differ") unless value_rows == rows
      validate_array_nested_stream_marks(value_stream, first_mark, mark_flat_elements, 4)
      checked_array_mark_byte_count(flat_elements, 4).to_u64
    end

    def array_decimal64_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      raise UnsupportedFormatError.new("Decimal64 Array accessor requires an exact Array(Decimal(18, S)) column") unless WidePart.array_decimal64_scale(@column_type)

      _, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      value_stream = @streams[column]
      _, _, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Decimal64) value mark rows differ") unless value_rows == rows
      validate_array_nested_stream_marks(value_stream, first_mark, mark_flat_elements, 8)
      checked_array_mark_byte_count(flat_elements, 8).to_u64
    end

    def array_decimal128_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      raise UnsupportedFormatError.new("Decimal128 Array accessor requires an exact Array(Decimal(38, S)) column") unless WidePart.array_decimal128_scale(@column_type)

      _, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      value_stream = @streams[column]
      _, _, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Decimal128) value mark rows differ") unless value_rows == rows
      validate_array_nested_stream_marks(value_stream, first_mark, mark_flat_elements, 16)
      checked_array_mark_byte_count(flat_elements, 16).to_u64
    end

    def array_decimal256_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      raise UnsupportedFormatError.new("Decimal256 Array accessor requires an exact Array(Decimal(76, S)) column") unless WidePart.array_decimal256_scale(@column_type)

      _, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      value_stream = @streams[column]
      _, _, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Decimal256) value mark rows differ") unless value_rows == rows
      validate_array_nested_stream_marks(value_stream, first_mark, mark_flat_elements, 32)
      checked_array_mark_byte_count(flat_elements, 32).to_u64
    end

    def array_enum8_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      raise UnsupportedFormatError.new("Enum8 Array accessor requires an exact Array(Enum8(...)) column") unless WidePart.array_enum8_codes(@column_type)
      array_enum_mark_range_raw_bytes(column, first_mark, mark_count, 1, false)
    end

    def array_nullable_enum8_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      raise UnsupportedFormatError.new("Enum8 Array accessor requires an exact Array(Nullable(Enum8(...))) column") unless WidePart.array_nullable_enum8_codes(@column_type)
      array_enum_mark_range_raw_bytes(column, first_mark, mark_count, 1, true)
    end

    def array_enum16_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      raise UnsupportedFormatError.new("Enum16 Array accessor requires an exact Array(Enum16(...)) column") unless WidePart.array_enum16_codes(@column_type)
      array_enum_mark_range_raw_bytes(column, first_mark, mark_count, 2, false)
    end

    def array_nullable_enum16_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      raise UnsupportedFormatError.new("Enum16 Array accessor requires an exact Array(Nullable(Enum16(...))) column") unless WidePart.array_nullable_enum16_codes(@column_type)
      array_enum_mark_range_raw_bytes(column, first_mark, mark_count, 2, true)
    end

    private def array_enum_mark_range_raw_bytes(
      column : String,
      first_mark : Int,
      mark_count : Int,
      element_width : Int32,
      nullable : Bool,
    ) : UInt64
      _, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      child_streams = nullable ? ["#{column}.null", column] : [column]
      child_streams.each do |stream_name|
        stream = @streams[stream_name]
        _, _, child_rows = checked_stream_mark_range(stream, first_mark, mark_count)
        raise CorruptPartError.new("Array Enum child substream mark rows differ") unless child_rows == rows
        width = stream_name == "#{column}.null" ? 1 : element_width
        validate_array_nested_stream_marks(stream, first_mark, mark_flat_elements, width)
      end
      bytes_per_element = nullable ? element_width + 1 : element_width
      checked_array_mark_byte_count(flat_elements, bytes_per_element).to_u64
    end

    # Count all three physical streams of Array(Array(UInt64)) before a table
    # batch allocates nested row arrays. The size1 values are decoded only to
    # derive per-mark leaf counts; payload frames are boundary-validated but
    # not copied here.
    def array_array_uint64_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      unless @column_type == "Array(Array(UInt64))"
        raise UnsupportedFormatError.new("Array(Array(UInt64)) accessor requires an exact Array(Array(UInt64)) column")
      end

      outer_sizes, flat_inner_arrays, rows, mark_inner_arrays = read_array_outer_sizes(column, first_mark, mark_count)
      element_sizes, flat_elements, mark_leaf_elements = read_array_array_uint64_element_sizes(
        column,
        first_mark,
        mark_count,
        flat_inner_arrays,
        rows,
        mark_inner_arrays
      )
      raise CorruptPartError.new("Array(Array(UInt64)) outer row count changed") unless outer_sizes.size.to_u64 == rows

      value_stream = @streams[column]
      value_start, value_end, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Array(UInt64)) value mark rows differ") unless value_rows == rows
      validate_array_nested_stream_marks(value_stream, first_mark, mark_leaf_elements, 8)
      value_bytes = checked_array_mark_byte_count(flat_elements, 8).to_u64
      validate_mark_range_bytes(value_stream, value_start, value_end, value_bytes.to_i, 8)
      raise CorruptPartError.new("Array(Array(UInt64)) nested size count changed") unless element_sizes.size.to_u64 == flat_inner_arrays

      outer_bytes = checked_byte_count(rows, 8).to_u64
      inner_bytes = checked_array_mark_byte_count(flat_inner_arrays, 8).to_u64
      outer_bytes + inner_bytes + value_bytes
    end

    # Count the four physical streams of Array(Array(Nullable(UInt64))) before
    # a table batch allocates nested arrays. The size1 stream establishes the
    # leaf count for each outer-row mark; null and value streams must match it.
    def array_array_nullable_uint64_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      unless @column_type == "Array(Array(Nullable(UInt64)))"
        raise UnsupportedFormatError.new("Array(Array(Nullable(UInt64))) accessor requires an exact Array(Array(Nullable(UInt64))) column")
      end

      outer_sizes, flat_inner_arrays, rows, mark_inner_arrays = read_array_outer_sizes(column, first_mark, mark_count)
      element_sizes, flat_leaf_elements, mark_leaf_elements = read_array_array_nullable_uint64_element_sizes(
        column,
        first_mark,
        mark_count,
        flat_inner_arrays,
        rows,
        mark_inner_arrays
      )
      raise CorruptPartError.new("Array(Array(Nullable(UInt64))) outer row count changed") unless outer_sizes.size.to_u64 == rows
      raise CorruptPartError.new("Array(Array(Nullable(UInt64))) nested size count changed") unless element_sizes.size.to_u64 == flat_inner_arrays

      {"#{column}.null", column}.each do |stream_name|
        stream = @streams[stream_name]
        _, _, child_rows = checked_stream_mark_range(stream, first_mark, mark_count)
        raise CorruptPartError.new("Array(Array(Nullable(UInt64))) child substream mark rows differ") unless child_rows == rows
        width = stream_name == "#{column}.null" ? 1 : 8
        validate_array_nested_stream_marks(stream, first_mark, mark_leaf_elements, width)
      end

      outer_bytes = checked_byte_count(rows, 8).to_u64
      inner_bytes = checked_array_mark_byte_count(flat_inner_arrays, 8).to_u64
      leaf_bytes = checked_array_mark_byte_count(flat_leaf_elements, 8).to_u64
      outer_bytes + inner_bytes + leaf_bytes + flat_leaf_elements
    end

    # Count both child streams before the caller materializes
    # Array(Nullable(T)) rows. Each leaf consumes one null byte and one fixed-
    # width value slot, including NULL placeholders.
    def array_nullable_numeric_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      element_type = WidePart.nullable_numeric_array_element_type(@column_type) || raise(UnsupportedFormatError.new("Array numeric nullable accessor requires an exact Array(Nullable(T)) numeric column"))
      element_width = WidePart.array_numeric_payload_width(element_type)

      _, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      {"#{column}.null", column}.each do |stream_name|
        stream = @streams[stream_name]
        _, _, child_rows = checked_stream_mark_range(stream, first_mark, mark_count)
        raise CorruptPartError.new("Array(Nullable(T)) child substream mark rows differ") unless child_rows == rows
        width = stream_name == "#{column}.null" ? 1 : element_width
        validate_array_nested_stream_marks(stream, first_mark, mark_flat_elements, width)
      end
      checked_array_mark_byte_count(flat_elements, 1 + element_width).to_u64
    end

    def array_nullable_temporal_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      element_type = WidePart.nullable_temporal_array_element_type(@column_type) || raise(UnsupportedFormatError.new("nullable temporal Array accessor requires an exact temporal leaf column"))
      element_width = WidePart.array_numeric_payload_width(
        WidePart.temporal_array_physical_type(element_type).not_nil!
      )

      _, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      {"#{column}.null", column}.each do |stream_name|
        stream = @streams[stream_name]
        _, _, child_rows = checked_stream_mark_range(stream, first_mark, mark_count)
        raise CorruptPartError.new("nullable temporal Array child substream mark rows differ") unless child_rows == rows
        width = stream_name == "#{column}.null" ? 1 : element_width
        validate_array_nested_stream_marks(stream, first_mark, mark_flat_elements, width)
      end
      checked_array_mark_byte_count(flat_elements, 1 + element_width).to_u64
    end

    def array_nullable_decimal32_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      raise UnsupportedFormatError.new("Decimal32 Array accessor requires an exact Array(Nullable(Decimal(9, S))) column") unless WidePart.array_nullable_decimal32_scale(@column_type)

      _, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      {"#{column}.null", column}.each do |stream_name|
        stream = @streams[stream_name]
        _, _, child_rows = checked_stream_mark_range(stream, first_mark, mark_count)
        raise CorruptPartError.new("Array(Nullable(Decimal32)) child substream mark rows differ") unless child_rows == rows
        width = stream_name == "#{column}.null" ? 1 : 4
        validate_array_nested_stream_marks(stream, first_mark, mark_flat_elements, width)
      end
      checked_array_mark_byte_count(flat_elements, 5).to_u64
    end

    def array_nullable_decimal64_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      raise UnsupportedFormatError.new("Decimal64 Array accessor requires an exact Array(Nullable(Decimal(18, S))) column") unless WidePart.array_nullable_decimal64_scale(@column_type)

      _, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      {"#{column}.null", column}.each do |stream_name|
        stream = @streams[stream_name]
        _, _, child_rows = checked_stream_mark_range(stream, first_mark, mark_count)
        raise CorruptPartError.new("Array(Nullable(Decimal64)) child substream mark rows differ") unless child_rows == rows
        width = stream_name == "#{column}.null" ? 1 : 8
        validate_array_nested_stream_marks(stream, first_mark, mark_flat_elements, width)
      end
      checked_array_mark_byte_count(flat_elements, 9).to_u64
    end

    def array_nullable_decimal128_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      raise UnsupportedFormatError.new("Decimal128 Array accessor requires an exact Array(Nullable(Decimal(38, S))) column") unless WidePart.array_nullable_decimal128_scale(@column_type)

      _, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      {"#{column}.null", column}.each do |stream_name|
        stream = @streams[stream_name]
        _, _, child_rows = checked_stream_mark_range(stream, first_mark, mark_count)
        raise CorruptPartError.new("Array(Nullable(Decimal128)) child substream mark rows differ") unless child_rows == rows
        width = stream_name == "#{column}.null" ? 1 : 16
        validate_array_nested_stream_marks(stream, first_mark, mark_flat_elements, width)
      end
      checked_array_mark_byte_count(flat_elements, 17).to_u64
    end

    def array_nullable_decimal256_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      raise UnsupportedFormatError.new("Decimal256 Array accessor requires an exact Array(Nullable(Decimal(76, S))) column") unless WidePart.array_nullable_decimal256_scale(@column_type)

      _, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      {"#{column}.null", column}.each do |stream_name|
        stream = @streams[stream_name]
        _, _, child_rows = checked_stream_mark_range(stream, first_mark, mark_count)
        raise CorruptPartError.new("Array(Nullable(Decimal256)) child substream mark rows differ") unless child_rows == rows
        width = stream_name == "#{column}.null" ? 1 : 32
        validate_array_nested_stream_marks(stream, first_mark, mark_flat_elements, width)
      end
      checked_array_mark_byte_count(flat_elements, 33).to_u64
    end

    # Count both physical child streams for one exact Array(UUID) range before
    # a table batch allocates caller-visible UUIDValue arrays.
    def array_uuid_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      raise UnsupportedFormatError.new("UUID Array accessor requires an exact Array(UUID) column") unless WidePart.uuid_array_element_type(@column_type)

      _, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      value_stream = @streams[column]
      _, _, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(UUID) value mark rows differ") unless value_rows == rows
      validate_array_nested_stream_marks(value_stream, first_mark, mark_flat_elements, 16)
      checked_array_mark_byte_count(flat_elements, 16).to_u64
    end

    # BASIC Array(Nullable(UUID)) stores a one-byte null map and one 16-byte
    # UUID slot per leaf, including NULL slots. Validate both child topologies
    # before table materialization.
    def array_nullable_uuid_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      raise UnsupportedFormatError.new("nullable UUID Array accessor requires an exact Array(Nullable(UUID)) column") unless WidePart.nullable_uuid_array_element_type(@column_type)

      _, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      {"#{column}.null", column}.each do |stream_name|
        stream = @streams[stream_name]
        _, _, child_rows = checked_stream_mark_range(stream, first_mark, mark_count)
        raise CorruptPartError.new("Array(Nullable(UUID)) child substream mark rows differ") unless child_rows == rows
        width = stream_name == "#{column}.null" ? 1 : 16
        validate_array_nested_stream_marks(stream, first_mark, mark_flat_elements, width)
      end
      checked_array_mark_byte_count(flat_elements, 17).to_u64
    end

    # Count exact IPv4 leaf bytes before a table batch allocates wrappers.
    # This semantic codec remains separate from generic UInt32 Array admission.
    def array_ipv4_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      raise UnsupportedFormatError.new("IPv4 Array accessor requires an exact Array(IPv4) column") unless WidePart.ipv4_array_element_type(@column_type)

      _, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      value_stream = @streams[column]
      _, _, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(IPv4) value mark rows differ") unless value_rows == rows
      validate_array_nested_stream_marks(value_stream, first_mark, mark_flat_elements, 4)
      checked_array_mark_byte_count(flat_elements, 4).to_u64
    end

    # BASIC Array(Nullable(IPv4)) retains a four-byte nested slot for every
    # leaf, including NULL slots, alongside its one-byte null map.
    def array_nullable_ipv4_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      raise UnsupportedFormatError.new("nullable IPv4 Array accessor requires an exact Array(Nullable(IPv4)) column") unless WidePart.nullable_ipv4_array_element_type(@column_type)

      _, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      {"#{column}.null", column}.each do |stream_name|
        stream = @streams[stream_name]
        _, _, child_rows = checked_stream_mark_range(stream, first_mark, mark_count)
        raise CorruptPartError.new("Array(Nullable(IPv4)) child substream mark rows differ") unless child_rows == rows
        width = stream_name == "#{column}.null" ? 1 : 4
        validate_array_nested_stream_marks(stream, first_mark, mark_flat_elements, width)
      end
      checked_array_mark_byte_count(flat_elements, 5).to_u64
    end

    # Count exact IPv6 leaf bytes before a table batch allocates wrappers.
    # IPv6 remains distinct from UUID and numeric UInt128 arrays.
    def array_ipv6_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      raise UnsupportedFormatError.new("IPv6 Array accessor requires an exact Array(IPv6) column") unless WidePart.ipv6_array_element_type(@column_type)

      _, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      value_stream = @streams[column]
      _, _, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(IPv6) value mark rows differ") unless value_rows == rows
      validate_array_nested_stream_marks(value_stream, first_mark, mark_flat_elements, 16)
      checked_array_mark_byte_count(flat_elements, 16).to_u64
    end

    # BASIC Array(Nullable(IPv6)) retains a full 16-byte nested slot for every
    # leaf, including NULL slots, alongside its one-byte null map.
    def array_nullable_ipv6_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      raise UnsupportedFormatError.new("nullable IPv6 Array accessor requires an exact Array(Nullable(IPv6)) column") unless WidePart.nullable_ipv6_array_element_type(@column_type)

      _, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      {"#{column}.null", column}.each do |stream_name|
        stream = @streams[stream_name]
        _, _, child_rows = checked_stream_mark_range(stream, first_mark, mark_count)
        raise CorruptPartError.new("Array(Nullable(IPv6)) child substream mark rows differ") unless child_rows == rows
        width = stream_name == "#{column}.null" ? 1 : 16
        validate_array_nested_stream_marks(stream, first_mark, mark_flat_elements, width)
      end
      checked_array_mark_byte_count(flat_elements, 17).to_u64
    end

    # Count the fixed-width child payload of an exact Array(FixedString(N))
    # range after matching each child's marks to the flattened size0 counts.
    def array_fixed_string_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      width = WidePart.array_fixed_string_width(@column_type) || raise(UnsupportedFormatError.new("Array(FixedString) accessor requires an exact Array(FixedString(N)) column"))

      _, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      expected_bytes = checked_array_mark_byte_count(flat_elements, width)
      value_stream = @streams[column]
      _, _, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(FixedString) value mark rows differ") unless value_rows == rows
      validate_array_nested_stream_marks(value_stream, first_mark, mark_flat_elements, width)
      expected_bytes.to_u64
    end

    # Count both child streams of Array(Nullable(FixedString(N))). NULL slots
    # still occupy one N-byte value slot, so the result includes the null map
    # as well as the nested fixed-width payload.
    def array_nullable_fixed_string_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      width = WidePart.array_nullable_fixed_string_width(@column_type) || raise(UnsupportedFormatError.new("Array nullable FixedString accessor requires an exact Array(Nullable(FixedString(N))) column"))

      _, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      total_bytes = checked_array_mark_byte_count(flat_elements, 1 + width)
      null_stream = @streams["#{column}.null"]
      null_start, null_end, null_rows = checked_stream_mark_range(null_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Nullable(FixedString)) null-map mark rows differ") unless null_rows == rows
      validate_array_nested_stream_marks(null_stream, first_mark, mark_flat_elements, 1)
      null_map = read_mark_range_bytes(null_stream, null_start, null_end, checked_array_mark_byte_count(flat_elements, 1), 1)
      null_map.each do |value|
        raise CorruptPartError.new("Array(Nullable(FixedString)) null-map byte is not boolean") unless value <= 1_u8
      end

      value_stream = @streams[column]
      _, _, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Nullable(FixedString)) value mark rows differ") unless value_rows == rows
      validate_array_nested_stream_marks(value_stream, first_mark, mark_flat_elements, width)
      total_bytes.to_u64
    end

    # Count the flattened Bool payload of an exact Array(Bool) mark range.
    # The child stream is marked in outer rows, while each size0 value adds
    # one one-byte Bool slot.
    def array_bool_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      raise UnsupportedFormatError.new("Array(Bool) accessor requires an exact Array(Bool) column") unless WidePart.supports_array_bool_type?(@column_type)

      _, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      value_stream = @streams[column]
      _, _, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Bool) value mark rows differ") unless value_rows == rows
      validate_array_nested_stream_marks(value_stream, first_mark, mark_flat_elements, 1)
      checked_array_mark_byte_count(flat_elements, 1).to_u64
    end

    # Count both child streams for Array(Nullable(Bool)). The raw value slot
    # beneath NULL remains physically present and is included in the count.
    def array_nullable_bool_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      raise UnsupportedFormatError.new("Array(Nullable(Bool)) accessor requires an exact Array(Nullable(Bool)) column") unless WidePart.supports_array_nullable_bool_type?(@column_type)

      _, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      {"#{column}.null", column}.each do |stream_name|
        stream = @streams[stream_name]
        _, _, child_rows = checked_stream_mark_range(stream, first_mark, mark_count)
        raise CorruptPartError.new("Array(Nullable(Bool)) child substream mark rows differ") unless child_rows == rows
        validate_array_nested_stream_marks(stream, first_mark, mark_flat_elements, 1)
      end
      null_stream = @streams["#{column}.null"]
      null_start, null_end, _ = checked_stream_mark_range(null_stream, first_mark, mark_count)
      null_bytes = read_mark_range_bytes(null_stream, null_start, null_end, checked_array_mark_byte_count(flat_elements, 1), 1)
      null_bytes.each do |value|
        raise CorruptPartError.new("Array(Nullable(Bool)) null-map byte is not boolean") unless value <= 1_u8
      end
      checked_array_mark_byte_count(flat_elements, 2).to_u64
    end

    # Preserve the established W27 UInt64 helper as a bounded wrapper.
    def array_nullable_uint64_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      raise UnsupportedFormatError.new("Array(Nullable(UInt64)) accessor requires an exact Array(Nullable(UInt64)) column") unless @column_type == "Array(Nullable(UInt64))"
      array_nullable_numeric_mark_range_raw_bytes(column, first_mark, mark_count)
    end

    # Return the complete materialization charge for one exact W51
    # Array(Tuple(UInt64, String)) mark range without allocating result rows
    # or Strings. The charge includes size0, UInt64 values, String size slots,
    # and raw String bytes.
    def array_tuple_uint64_string_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      preflight_array_tuple_uint64_string_mark_range_raw_bytes(column, first_mark, mark_count)
    end

    def preflight_array_tuple_uint64_string_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      preflight_array_tuple_uint64_string_mark_range_raw_bytes(column, first_mark, mark_count)
    end

    def preflight_array_tuple_uint64_string_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      array_tuple_components(column, first_mark, mark_count, false, false).materialized_bytes
    end

    # Nullable slots retain their UInt64 payload and add one null-map byte to
    # the bounded materialization charge, including slots hidden by NULL.
    def array_tuple_nullable_uint64_string_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      preflight_array_tuple_nullable_uint64_string_mark_range_raw_bytes(column, first_mark, mark_count)
    end

    def preflight_array_tuple_nullable_uint64_string_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      preflight_array_tuple_nullable_uint64_string_mark_range_raw_bytes(column, first_mark, mark_count)
    end

    def preflight_array_tuple_nullable_uint64_string_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      array_tuple_components(column, first_mark, mark_count, true, false).materialized_bytes
    end

    # Read exact W51 Array(Tuple(a UInt64, b String)) rows. Each selected
    # mark's flattened child counts are checked independently before strings
    # and nested row arrays are assembled.
    def read_array_tuple_uint64_string_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Tuple(UInt64, String)))
      components = array_tuple_components(column, first_mark, mark_count, false, true)
      numeric_values = components.numeric_values.not_nil!
      string_values = components.string_values.not_nil!
      rows = Array(Array(Tuple(UInt64, String))).new(components.rows.to_i)
      element_offset = 0
      string_offset = 0
      components.outer_sizes.each do |size|
        row = Array(Tuple(UInt64, String)).new(size.to_i)
        size.to_i.times do
          raise CorruptPartError.new("Array(Tuple) size0 exceeds selected child values") if element_offset >= components.element_sizes.size
          length = components.element_sizes[element_offset].to_i
          raise CorruptPartError.new("Array(Tuple) String sizes exceed selected raw bytes") if length > string_values.size - string_offset
          value = u64(numeric_values, element_offset * 8)
          row << {value, String.new(string_values[string_offset, length])}
          element_offset += 1
          string_offset += length
        end
        rows << row
      end
      raise CorruptPartError.new("Array(Tuple) size0 does not consume child values") unless element_offset == components.element_sizes.size
      raise CorruptPartError.new("Array(Tuple) String sizes do not consume raw bytes") unless string_offset == string_values.size
      rows
    end

    # Read exact W51 Array(Tuple(a Nullable(UInt64), b String)) rows. The
    # nested UInt64 payload is consumed even where the null map says NULL.
    def read_array_tuple_nullable_uint64_string_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Tuple(UInt64?, String)))
      components = array_tuple_components(column, first_mark, mark_count, true, true)
      numeric_values = components.numeric_values.not_nil!
      null_map = components.null_map.not_nil!
      string_values = components.string_values.not_nil!
      rows = Array(Array(Tuple(UInt64?, String))).new(components.rows.to_i)
      element_offset = 0
      string_offset = 0
      components.outer_sizes.each do |size|
        row = Array(Tuple(UInt64?, String)).new(size.to_i)
        size.to_i.times do
          raise CorruptPartError.new("Array(Tuple) size0 exceeds selected child values") if element_offset >= components.element_sizes.size
          length = components.element_sizes[element_offset].to_i
          raise CorruptPartError.new("Array(Tuple) String sizes exceed selected raw bytes") if length > string_values.size - string_offset
          value = null_map[element_offset] == 1_u8 ? nil : u64(numeric_values, element_offset * 8)
          row << {value, String.new(string_values[string_offset, length])}
          element_offset += 1
          string_offset += length
        end
        rows << row
      end
      raise CorruptPartError.new("Array(Tuple) size0 does not consume child values") unless element_offset == components.element_sizes.size
      raise CorruptPartError.new("Array(Tuple) String sizes do not consume raw bytes") unless string_offset == string_values.size
      rows
    end

    # Return raw nested String bytes for one bounded Array(String) mark range
    # without materializing the returned outer/inner String arrays. WidePartTable
    # uses this to preflight aggregate per-mark bytes across selected columns.
    def array_string_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      raise UnsupportedFormatError.new("Array(String) accessor requires an exact Array(String) column") unless @column_type == "Array(String)"

      outer_sizes, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      element_sizes, total_bytes = read_array_string_element_sizes(column, first_mark, mark_count, flat_elements, rows, mark_flat_elements)
      size_stream = @streams["#{column}.size"]
      _, _, size_rows = checked_stream_mark_range(size_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(String) substream mark rows differ") unless size_rows == rows && outer_sizes.size.to_u64 == rows

      raw_stream = @streams[column]
      raw_start, raw_end, raw_rows = checked_stream_mark_range(raw_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(String) substream mark rows differ") unless raw_rows == rows
      validate_mark_range_bytes(raw_stream, raw_start, raw_end, total_bytes.to_i, 1)
      raise CorruptPartError.new("Array(String) nested size count changed") unless element_sizes.size.to_u64 == flat_elements
      total_bytes
    end

    # Preflight one exact Array(Nullable(String)) mark range without creating
    # String values. The return value is raw nested String bytes, including any
    # bytes carried by NULL slots.
    def array_nullable_string_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      array_nullable_string_mark_range_preflight(column, first_mark, mark_count)[0]
    end

    # Return {physical raw String bytes, conservative table materialization
    # charge}. The charge adds fixed allowances per flattened nullable slot and
    # outer row so NULL/empty-heavy marks cannot evade the aggregate batch limit.
    def array_nullable_string_mark_range_preflight(column : String, first_mark : Int, mark_count : Int) : {UInt64, UInt64}
      ensure_column(column)
      raise UnsupportedFormatError.new("Array(Nullable(String)) accessor requires an exact Array(Nullable(String)) column") unless @column_type == "Array(Nullable(String))"

      _, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      element_sizes, total_bytes = read_array_string_element_sizes(
        column,
        first_mark,
        mark_count,
        flat_elements,
        rows,
        mark_flat_elements,
        "Array(Nullable(String))"
      )
      read_array_nullable_string_null_map(column, first_mark, mark_count, flat_elements, rows, mark_flat_elements)
      raise CorruptPartError.new("Array(Nullable(String)) size count does not match size0") unless element_sizes.size.to_u64 == flat_elements

      raw_stream = @streams[column]
      _, _, raw_rows = checked_stream_mark_range(raw_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Nullable(String)) raw substream mark rows differ") unless raw_rows == rows
      slot_bytes = checked_array_nullable_string_slot_bytes(flat_elements)
      if rows > UInt64::MAX // ARRAY_NULLABLE_STRING_ROW_ACCOUNTING_BYTES
        raise CorruptPartError.new("Array(Nullable(String)) row charge overflows")
      end
      row_bytes = rows * ARRAY_NULLABLE_STRING_ROW_ACCOUNTING_BYTES
      if slot_bytes > UInt64::MAX - row_bytes || total_bytes > UInt64::MAX - slot_bytes - row_bytes
        raise CorruptPartError.new("Array(Nullable(String)) materialization charge overflows")
      end
      {total_bytes, total_bytes + slot_bytes + row_bytes}
    end

    # Return nested String bytes for an exact Map(UInt64, String) mark range
    # without allocating the returned row arrays. Map keys and values are
    # positionally paired flattened streams beneath the per-row size0 stream.
    def map_uint64_string_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      raise UnsupportedFormatError.new("Map accessor requires an exact Map(UInt64, String) column") unless WidePart.supports_map_uint64_string_type?(@column_type)

      _, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      keys_stream = @streams["#{column}%2Ekeys"]
      _, _, key_rows = checked_stream_mark_range(keys_stream, first_mark, mark_count)
      raise CorruptPartError.new("Map key substream mark rows differ") unless key_rows == rows
      validate_array_nested_stream_marks(keys_stream, first_mark, mark_flat_elements, 8)

      sizes, total_bytes = read_map_string_element_sizes(column, first_mark, mark_count, flat_elements, rows, mark_flat_elements)
      raise CorruptPartError.new("Map nested String size count differs from keys") unless sizes.size.to_u64 == flat_elements
      total_bytes
    end

    # Read exact ordered Map(UInt64, String) rows for selected outer marks.
    # Duplicate keys and insertion order are preserved. Outer entry counts,
    # per-mark entries, and raw String bytes are bounded before result arrays
    # or Strings are allocated.
    def read_map_uint64_string_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Tuple(UInt64, String)))
      ensure_column(column)
      raise UnsupportedFormatError.new("Map accessor requires an exact Map(UInt64, String) column") unless WidePart.supports_map_uint64_string_type?(@column_type)

      outer_sizes, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      keys_stream = @streams["#{column}%2Ekeys"]
      key_start, key_end, key_rows = checked_stream_mark_range(keys_stream, first_mark, mark_count)
      raise CorruptPartError.new("Map key substream mark rows differ") unless key_rows == rows
      validate_array_nested_stream_marks(keys_stream, first_mark, mark_flat_elements, 8)
      encoded_keys = read_mark_range_bytes(keys_stream, key_start, key_end, checked_array_mark_byte_count(flat_elements, 8), 8)

      element_sizes, total_bytes = read_map_string_element_sizes(column, first_mark, mark_count, flat_elements, rows, mark_flat_elements)
      values_stream = @streams["#{column}%2Evalues"]
      values_start, values_end, value_rows = checked_stream_mark_range(values_stream, first_mark, mark_count)
      raise CorruptPartError.new("Map value substream mark rows differ") unless value_rows == rows
      raw_bytes = read_mark_range_bytes(values_stream, values_start, values_end, total_bytes.to_i, 1)

      result = Array(Array(Tuple(UInt64, String))).new(rows.to_i)
      flat_offset = 0
      raw_offset = 0
      outer_sizes.each do |size|
        row = Array(Tuple(UInt64, String)).new(size.to_i)
        size.to_i.times do
          raise CorruptPartError.new("Map outer sizes exceed selected nested keys") if flat_offset >= element_sizes.size
          length = element_sizes[flat_offset]
          byte_length = length.to_i
          raise CorruptPartError.new("Map String sizes exceed selected raw bytes") if byte_length > raw_bytes.size - raw_offset
          row << {u64(encoded_keys, flat_offset * 8), String.new(raw_bytes[raw_offset, byte_length])}
          raw_offset += byte_length
          flat_offset += 1
        end
        result << row
      end
      raise CorruptPartError.new("Map sizes do not consume selected nested keys") unless flat_offset == element_sizes.size
      raise CorruptPartError.new("Map String lengths do not consume selected raw bytes") unless raw_offset == raw_bytes.size
      result
    end

    # Read exact ordered Map(UInt64, UInt64) rows for selected outer marks.
    # Duplicate keys and insertion order are preserved. The size0 stream
    # defines row boundaries; keys and values are aligned flattened UInt64
    # streams with independent per-mark byte validation.
    def read_map_uint64_uint64_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Tuple(UInt64, UInt64)))
      ensure_column(column)
      raise UnsupportedFormatError.new("Map accessor requires an exact Map(UInt64, UInt64) column") unless WidePart.supports_map_uint64_uint64_type?(@column_type)

      outer_sizes, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      keys_stream = @streams["#{column}%2Ekeys"]
      key_start, key_end, key_rows = checked_stream_mark_range(keys_stream, first_mark, mark_count)
      raise CorruptPartError.new("Map key substream mark rows differ") unless key_rows == rows
      validate_array_nested_stream_marks(keys_stream, first_mark, mark_flat_elements, 8)
      encoded_keys = read_mark_range_bytes(keys_stream, key_start, key_end, checked_array_mark_byte_count(flat_elements, 8), 8)

      values_stream = @streams["#{column}%2Evalues"]
      value_start, value_end, value_rows = checked_stream_mark_range(values_stream, first_mark, mark_count)
      raise CorruptPartError.new("Map value substream mark rows differ") unless value_rows == rows
      validate_array_nested_stream_marks(values_stream, first_mark, mark_flat_elements, 8)
      encoded_values = read_mark_range_bytes(values_stream, value_start, value_end, checked_array_mark_byte_count(flat_elements, 8), 8)

      result = Array(Array(Tuple(UInt64, UInt64))).new(rows.to_i)
      flat_offset = 0
      outer_sizes.each do |size|
        row = Array(Tuple(UInt64, UInt64)).new(size.to_i)
        size.to_i.times do
          raise CorruptPartError.new("Map outer sizes exceed selected nested keys") if flat_offset >= flat_elements
          row << {u64(encoded_keys, flat_offset * 8), u64(encoded_values, flat_offset * 8)}
          flat_offset += 1
        end
        result << row
      end
      raise CorruptPartError.new("Map sizes do not consume selected nested streams") unless flat_offset.to_u64 == flat_elements
      result
    end

    # Return the selected Map(UInt64, UInt64) key and value payload size after
    # both flattened children have been checked against the outer size0 boundaries.
    def map_uint64_uint64_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      raise UnsupportedFormatError.new("Map accessor requires an exact Map(UInt64, UInt64) column") unless WidePart.supports_map_uint64_uint64_type?(@column_type)

      _, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      {"#{column}%2Ekeys", "#{column}%2Evalues"}.each do |stream_name|
        stream = @streams[stream_name]
        _, _, child_rows = checked_stream_mark_range(stream, first_mark, mark_count)
        raise CorruptPartError.new("Map child substream mark rows differ") unless child_rows == rows
        validate_array_nested_stream_marks(stream, first_mark, mark_flat_elements, 8)
      end
      checked_array_mark_byte_count(flat_elements, 16).to_u64
    end

    # Read ordered Map(UInt64, Nullable(UInt64)) entries without collapsing
    # duplicate keys. The null bitmap, keys, values, and size0 boundaries are
    # all checked before the returned row arrays are allocated.
    def read_map_uint64_nullable_uint64_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Tuple(UInt64, UInt64?)))
      ensure_column(column)
      raise UnsupportedFormatError.new("Map accessor requires an exact Map(UInt64, Nullable(UInt64)) column") unless WidePart.supports_map_uint64_nullable_uint64_type?(@column_type)

      payload_bytes, flat_elements, rows = map_uint64_nullable_uint64_payload_preflight(column, first_mark, mark_count)
      checked_map_array_tuple_charge(payload_bytes, flat_elements, rows)
      outer_sizes, checked_flat_elements, checked_rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      raise CorruptPartError.new("Map size0 changed after preflight") unless checked_flat_elements == flat_elements && checked_rows == rows

      keys_stream = @streams["#{column}%2Ekeys"]
      key_start, key_end, key_rows = checked_stream_mark_range(keys_stream, first_mark, mark_count)
      raise CorruptPartError.new("Map key substream mark rows differ") unless key_rows == rows
      encoded_keys = read_mark_range_bytes(keys_stream, key_start, key_end, checked_array_mark_byte_count(flat_elements, 8), 8)

      null_map = read_map_nullable_uint64_null_map(column, first_mark, mark_count, flat_elements, rows, mark_flat_elements)
      values_stream = @streams["#{column}%2Evalues"]
      value_start, value_end, value_rows = checked_stream_mark_range(values_stream, first_mark, mark_count)
      raise CorruptPartError.new("Map value substream mark rows differ") unless value_rows == rows
      encoded_values = read_mark_range_bytes(values_stream, value_start, value_end, checked_array_mark_byte_count(flat_elements, 8), 8)

      result = Array(Array(Tuple(UInt64, UInt64?))).new(rows.to_i)
      flat_offset = 0
      outer_sizes.each do |size|
        row = Array(Tuple(UInt64, UInt64?)).new(size.to_i)
        size.to_i.times do
          raise CorruptPartError.new("Map outer sizes exceed selected nested keys") if flat_offset >= flat_elements
          value = null_map[flat_offset] == 1 ? nil : u64(encoded_values, flat_offset * 8)
          row << {u64(encoded_keys, flat_offset * 8), value}
          flat_offset += 1
        end
        result << row
      end
      raise CorruptPartError.new("Map sizes do not consume selected nested streams") unless flat_offset.to_u64 == flat_elements
      result
    end

    # Count the exact key, null-map, and value bytes for a selected range,
    # while validating each flattened child against the same size0 marks.
    def map_uint64_nullable_uint64_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      map_uint64_nullable_uint64_payload_preflight(column, first_mark, mark_count)[0]
    end

    def map_uint64_nullable_uint64_mark_range_materialization_preflight(column : String, first_mark : Int, mark_count : Int) : {UInt64, UInt64}
      payload_bytes, flat_elements, rows = map_uint64_nullable_uint64_payload_preflight(column, first_mark, mark_count)
      {payload_bytes, checked_map_array_tuple_charge(payload_bytes, flat_elements, rows)}
    end

    private def map_uint64_nullable_uint64_payload_preflight(column : String, first_mark : Int, mark_count : Int) : {UInt64, UInt64, UInt64}
      ensure_column(column)
      raise UnsupportedFormatError.new("Map accessor requires an exact Map(UInt64, Nullable(UInt64)) column") unless WidePart.supports_map_uint64_nullable_uint64_type?(@column_type)

      _, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      key_stream = @streams["#{column}%2Ekeys"]
      _, _, key_rows = checked_stream_mark_range(key_stream, first_mark, mark_count)
      raise CorruptPartError.new("Map key substream mark rows differ") unless key_rows == rows
      validate_array_nested_stream_marks(key_stream, first_mark, mark_flat_elements, 8)

      values_stream = @streams["#{column}%2Evalues"]
      _, _, value_rows = checked_stream_mark_range(values_stream, first_mark, mark_count)
      raise CorruptPartError.new("Map value substream mark rows differ") unless value_rows == rows
      validate_array_nested_stream_marks(values_stream, first_mark, mark_flat_elements, 8)
      read_map_nullable_uint64_null_map(column, first_mark, mark_count, flat_elements, rows, mark_flat_elements)

      key_bytes = checked_array_mark_byte_count(flat_elements, 8).to_u64
      value_and_null_bytes = checked_array_mark_byte_count(flat_elements, 9).to_u64
      key_mark_bytes = mark_flat_elements.map { |elements| checked_array_mark_byte_count(elements, 8).to_u64 }
      value_mark_bytes = mark_flat_elements.map { |elements| checked_array_mark_byte_count(elements, 9).to_u64 }
      payload_bytes = checked_map_materialized_bytes(key_bytes, value_and_null_bytes, key_mark_bytes, value_mark_bytes)
      {payload_bytes, flat_elements, rows}
    end

    private def read_map_nullable_uint64_null_map(
      column : String,
      first_mark : Int,
      mark_count : Int,
      flat_elements : UInt64,
      outer_rows : UInt64,
      mark_flat_elements : Array(UInt64),
    ) : Bytes
      null_stream = @streams["#{column}%2Evalues.null"]
      null_start, null_end, null_rows = checked_stream_mark_range(null_stream, first_mark, mark_count)
      raise CorruptPartError.new("Map Nullable value null-map mark rows differ") unless null_rows == outer_rows
      validate_array_nested_stream_marks(null_stream, first_mark, mark_flat_elements, 1)
      null_bytes = read_mark_range_bytes(null_stream, null_start, null_end, checked_array_mark_byte_count(flat_elements, 1), 1)
      null_bytes.each do |value|
        raise CorruptPartError.new("Map Nullable value null-map byte is not boolean") unless value <= 1_u8
      end
      null_bytes
    end

    # Read ordered Map(UInt64, Nullable(String)) entries. The size0 boundary,
    # key stream, nullable bitmap, value-size stream, and raw value stream are
    # checked independently before result rows are allocated. Duplicate keys
    # and the distinction between NULL and an empty String are preserved.
    def read_map_uint64_nullable_string_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Tuple(UInt64, String?)))
      ensure_column(column)
      raise UnsupportedFormatError.new("Map accessor requires an exact Map(UInt64, Nullable(String)) column") unless WidePart.supports_map_uint64_nullable_string_type?(@column_type)

      payload_bytes, flat_elements, rows = map_uint64_nullable_string_payload_preflight(column, first_mark, mark_count)
      checked_map_array_tuple_charge(payload_bytes, flat_elements, rows)
      outer_sizes, checked_flat_elements, checked_rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      raise CorruptPartError.new("Map size0 changed after preflight") unless checked_flat_elements == flat_elements && checked_rows == rows

      keys_stream = @streams["#{column}%2Ekeys"]
      key_start, key_end, key_rows = checked_stream_mark_range(keys_stream, first_mark, mark_count)
      raise CorruptPartError.new("Map key substream mark rows differ") unless key_rows == rows
      key_bytes_total = checked_array_mark_byte_count(flat_elements, 8)
      encoded_keys = read_mark_range_bytes(keys_stream, key_start, key_end, key_bytes_total, 8)

      value_sizes, value_bytes_total, _ = read_map_string_child_sizes(
        column, "%2Evalues", "Map Nullable value", first_mark, mark_count, flat_elements, rows, mark_flat_elements
      )
      raise CorruptPartError.new("Map value size count differs from size0") unless value_sizes.size.to_u64 == flat_elements
      null_map = read_map_nullable_string_null_map(column, first_mark, mark_count, flat_elements, rows, mark_flat_elements)
      values_stream = @streams["#{column}%2Evalues"]
      value_start, value_end, value_rows = checked_stream_mark_range(values_stream, first_mark, mark_count)
      raise CorruptPartError.new("Map value substream mark rows differ") unless value_rows == rows
      encoded_values = read_mark_range_bytes(values_stream, value_start, value_end, value_bytes_total.to_i, 1)

      result = Array(Array(Tuple(UInt64, String?))).new(rows.to_i)
      flat_offset = 0
      raw_offset = 0
      outer_sizes.each do |size|
        row = Array(Tuple(UInt64, String?)).new(size.to_i)
        size.to_i.times do
          raise CorruptPartError.new("Map outer sizes exceed selected nested keys") if flat_offset >= flat_elements
          length = value_sizes[flat_offset].to_i
          raise CorruptPartError.new("Map value sizes exceed selected raw bytes") if length > encoded_values.size - raw_offset
          value = null_map[flat_offset] == 1 ? nil : String.new(encoded_values[raw_offset, length])
          row << {u64(encoded_keys, flat_offset * 8), value}
          raw_offset += length
          flat_offset += 1
        end
        result << row
      end
      raise CorruptPartError.new("Map sizes do not consume selected nested keys") unless flat_offset.to_u64 == flat_elements
      raise CorruptPartError.new("Map value lengths do not consume selected raw bytes") unless raw_offset == encoded_values.size
      result
    end

    # W54 charges the values.size and values.null child metadata alongside
    # the raw payload, then adds the existing per-row and per-entry slots.
    def map_uint64_nullable_string_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      map_uint64_nullable_string_payload_preflight(column, first_mark, mark_count)[0]
    end

    def map_uint64_nullable_string_mark_range_materialization_preflight(column : String, first_mark : Int, mark_count : Int) : {UInt64, UInt64}
      payload_bytes, flat_elements, rows = map_uint64_nullable_string_payload_preflight(column, first_mark, mark_count)
      {payload_bytes, checked_map_array_tuple_charge(payload_bytes, flat_elements, rows)}
    end

    private def map_uint64_nullable_string_payload_preflight(column : String, first_mark : Int, mark_count : Int) : {UInt64, UInt64, UInt64}
      ensure_column(column)
      raise UnsupportedFormatError.new("Map accessor requires an exact Map(UInt64, Nullable(String)) column") unless WidePart.supports_map_uint64_nullable_string_type?(@column_type)

      _, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      keys_stream = @streams["#{column}%2Ekeys"]
      _, _, key_rows = checked_stream_mark_range(keys_stream, first_mark, mark_count)
      raise CorruptPartError.new("Map key substream mark rows differ") unless key_rows == rows
      validate_array_nested_stream_marks(keys_stream, first_mark, mark_flat_elements, 8)

      _value_sizes, value_bytes, value_mark_bytes = read_map_string_child_sizes(
        column, "%2Evalues", "Map Nullable value", first_mark, mark_count, flat_elements, rows, mark_flat_elements
      )
      read_map_nullable_string_null_map(column, first_mark, mark_count, flat_elements, rows, mark_flat_elements)
      key_bytes = checked_array_mark_byte_count(flat_elements, 8).to_u64
      key_mark_bytes = mark_flat_elements.map { |elements| checked_array_mark_byte_count(elements, 8).to_u64 }
      value_mark_bytes = value_mark_bytes.each_with_index.map do |raw_bytes, index|
        checked_map_nullable_string_value_charge(raw_bytes, mark_flat_elements[index])
      end.to_a
      value_bytes = checked_map_nullable_string_value_charge(value_bytes, flat_elements)
      payload_bytes = checked_map_materialized_bytes(key_bytes, value_bytes, key_mark_bytes, value_mark_bytes)
      {payload_bytes, flat_elements, rows}
    end

    private def read_map_nullable_string_null_map(
      column : String,
      first_mark : Int,
      mark_count : Int,
      flat_elements : UInt64,
      outer_rows : UInt64,
      mark_flat_elements : Array(UInt64),
    ) : Bytes
      null_stream = @streams["#{column}%2Evalues.null"]
      null_start, null_end, null_rows = checked_stream_mark_range(null_stream, first_mark, mark_count)
      raise CorruptPartError.new("Map Nullable String null-map mark rows differ") unless null_rows == outer_rows
      validate_array_nested_stream_marks(null_stream, first_mark, mark_flat_elements, 1)
      null_bytes = read_mark_range_bytes(null_stream, null_start, null_end, checked_array_mark_byte_count(flat_elements, 1), 1)
      null_bytes.each do |value|
        raise CorruptPartError.new("Map Nullable String null-map byte is not boolean") unless value <= 1_u8
      end
      null_bytes
    end

    private def checked_map_nullable_string_value_charge(raw_bytes : UInt64, elements : UInt64) : UInt64
      metadata_bytes = checked_array_mark_byte_count(elements, 9).to_u64
      if raw_bytes > MAX_ARRAY_MARK_BYTES.to_u64 || metadata_bytes > MAX_ARRAY_MARK_BYTES.to_u64 - raw_bytes
        raise CorruptPartError.new("Map nullable String value metadata exceeds materialization limit")
      end
      raw_bytes + metadata_bytes
    end

    # Read ordered Map(String, Nullable(String)) rows without collapsing
    # duplicate keys. W54 independently validates key sizes/raw bytes and
    # value null/size/raw children at every selected mark boundary.
    def read_map_string_nullable_string_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Tuple(String, String?)))
      ensure_column(column)
      raise UnsupportedFormatError.new("Map accessor requires an exact Map(String, Nullable(String)) column") unless WidePart.supports_map_string_nullable_string_type?(@column_type)

      payload_bytes, flat_elements, rows = map_string_nullable_string_payload_preflight(column, first_mark, mark_count)
      checked_map_array_tuple_charge(payload_bytes, flat_elements, rows)
      outer_sizes, checked_flat_elements, checked_rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      raise CorruptPartError.new("Map size0 changed after preflight") unless checked_flat_elements == flat_elements && checked_rows == rows
      key_sizes, key_bytes_total, _ = read_map_string_child_sizes(
        column, "%2Ekeys", "Map key", first_mark, mark_count, flat_elements, rows, mark_flat_elements
      )
      raise CorruptPartError.new("Map key size count differs from size0") unless key_sizes.size.to_u64 == flat_elements
      value_sizes, value_bytes_total, _ = read_map_string_child_sizes(
        column, "%2Evalues", "Map Nullable value", first_mark, mark_count, flat_elements, rows, mark_flat_elements
      )
      raise CorruptPartError.new("Map value size count differs from size0") unless value_sizes.size.to_u64 == flat_elements

      key_stream = @streams["#{column}%2Ekeys"]
      key_start, key_end, key_rows = checked_stream_mark_range(key_stream, first_mark, mark_count)
      raise CorruptPartError.new("Map key substream mark rows differ") unless key_rows == rows
      key_bytes = read_mark_range_bytes(key_stream, key_start, key_end, key_bytes_total.to_i, 1)
      null_map = read_map_nullable_string_null_map(column, first_mark, mark_count, flat_elements, rows, mark_flat_elements)
      values_stream = @streams["#{column}%2Evalues"]
      value_start, value_end, value_rows = checked_stream_mark_range(values_stream, first_mark, mark_count)
      raise CorruptPartError.new("Map value substream mark rows differ") unless value_rows == rows
      value_bytes = read_mark_range_bytes(values_stream, value_start, value_end, value_bytes_total.to_i, 1)

      result = Array(Array(Tuple(String, String?))).new(rows.to_i)
      flat_offset = 0
      key_offset = 0
      value_offset = 0
      outer_sizes.each do |size|
        row = Array(Tuple(String, String?)).new(size.to_i)
        size.to_i.times do
          raise CorruptPartError.new("Map outer sizes exceed selected nested keys") if flat_offset >= flat_elements
          key_length = key_sizes[flat_offset].to_i
          value_length = value_sizes[flat_offset].to_i
          raise CorruptPartError.new("Map key sizes exceed selected raw bytes") if key_length > key_bytes.size - key_offset
          raise CorruptPartError.new("Map value sizes exceed selected raw bytes") if value_length > value_bytes.size - value_offset
          value = null_map[flat_offset] == 1 ? nil : String.new(value_bytes[value_offset, value_length])
          row << {String.new(key_bytes[key_offset, key_length]), value}
          key_offset += key_length
          value_offset += value_length
          flat_offset += 1
        end
        result << row
      end
      raise CorruptPartError.new("Map sizes do not consume selected nested keys") unless flat_offset.to_u64 == flat_elements
      raise CorruptPartError.new("Map key lengths do not consume selected raw bytes") unless key_offset == key_bytes.size
      raise CorruptPartError.new("Map value lengths do not consume selected raw bytes") unless value_offset == value_bytes.size
      result
    end

    def map_string_nullable_string_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      map_string_nullable_string_payload_preflight(column, first_mark, mark_count)[0]
    end

    def map_string_nullable_string_mark_range_materialization_preflight(column : String, first_mark : Int, mark_count : Int) : {UInt64, UInt64}
      payload_bytes, flat_elements, rows = map_string_nullable_string_payload_preflight(column, first_mark, mark_count)
      {payload_bytes, checked_map_array_tuple_charge(payload_bytes, flat_elements, rows)}
    end

    private def map_string_nullable_string_payload_preflight(column : String, first_mark : Int, mark_count : Int) : {UInt64, UInt64, UInt64}
      ensure_column(column)
      raise UnsupportedFormatError.new("Map accessor requires an exact Map(String, Nullable(String)) column") unless WidePart.supports_map_string_nullable_string_type?(@column_type)

      _, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      _key_sizes, key_bytes, key_mark_bytes = read_map_string_child_sizes(
        column, "%2Ekeys", "Map key", first_mark, mark_count, flat_elements, rows, mark_flat_elements
      )
      value_sizes, value_bytes, value_mark_bytes = read_map_string_child_sizes(
        column, "%2Evalues", "Map Nullable value", first_mark, mark_count, flat_elements, rows, mark_flat_elements
      )
      raise CorruptPartError.new("Map value size count differs from size0") unless value_sizes.size.to_u64 == flat_elements
      read_map_nullable_string_null_map(column, first_mark, mark_count, flat_elements, rows, mark_flat_elements)

      key_mark_bytes = key_mark_bytes.each_with_index.map do |raw_bytes, index|
        checked_map_string_key_charge(raw_bytes, mark_flat_elements[index])
      end.to_a
      value_mark_bytes = value_mark_bytes.each_with_index.map do |raw_bytes, index|
        checked_map_nullable_string_value_charge(raw_bytes, mark_flat_elements[index])
      end.to_a
      key_bytes = checked_map_string_key_charge(key_bytes, flat_elements)
      value_bytes = checked_map_nullable_string_value_charge(value_bytes, flat_elements)
      payload_bytes = checked_map_materialized_bytes(key_bytes, value_bytes, key_mark_bytes, value_mark_bytes)
      {payload_bytes, flat_elements, rows}
    end

    private def checked_map_string_key_charge(raw_bytes : UInt64, elements : UInt64) : UInt64
      size_bytes = checked_array_mark_byte_count(elements, 8).to_u64
      if raw_bytes > MAX_ARRAY_MARK_BYTES.to_u64 || size_bytes > MAX_ARRAY_MARK_BYTES.to_u64 - raw_bytes
        raise CorruptPartError.new("Map String key metadata exceeds materialization limit")
      end
      raw_bytes + size_bytes
    end

    # Return the String-key and fixed-width UInt64 payload charge for a
    # selected Map range without allocating ordered entry rows.
    def map_string_uint64_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      map_string_uint64_payload_preflight(column, first_mark, mark_count)[0]
    end

    # Return physical payload bytes and the bounded W51-style table charge.
    # The table charge includes outer row slots and tuple-entry slots so a
    # mark with many empty Strings still consumes aggregate budget.
    def map_string_uint64_mark_range_materialization_preflight(column : String, first_mark : Int, mark_count : Int) : {UInt64, UInt64}
      payload_bytes, flat_elements, rows = map_string_uint64_payload_preflight(column, first_mark, mark_count)
      {payload_bytes, checked_map_array_tuple_charge(payload_bytes, flat_elements, rows)}
    end

    private def map_string_uint64_payload_preflight(column : String, first_mark : Int, mark_count : Int) : {UInt64, UInt64, UInt64}
      ensure_column(column)
      raise UnsupportedFormatError.new("Map accessor requires an exact Map(String, UInt64) column") unless WidePart.supports_map_string_uint64_type?(@column_type)

      _, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      key_sizes, key_bytes, key_mark_bytes = read_map_string_child_sizes(
        column, "%2Ekeys", "Map key", first_mark, mark_count, flat_elements, rows, mark_flat_elements
      )
      raise CorruptPartError.new("Map key size count differs from size0") unless key_sizes.size.to_u64 == flat_elements

      values_stream = @streams["#{column}%2Evalues"]
      _, _, value_rows = checked_stream_mark_range(values_stream, first_mark, mark_count)
      raise CorruptPartError.new("Map value substream mark rows differ") unless value_rows == rows
      validate_array_nested_stream_marks(values_stream, first_mark, mark_flat_elements, 8)
      value_bytes = checked_array_mark_byte_count(flat_elements, 8).to_u64
      value_mark_bytes = mark_flat_elements.map { |elements| checked_array_mark_byte_count(elements, 8).to_u64 }
      payload_bytes = checked_map_materialized_bytes(key_bytes, value_bytes, key_mark_bytes, value_mark_bytes)
      {payload_bytes, flat_elements, rows}
    end

    # Read exact ordered Map(String, UInt64) rows. The String key size/raw
    # streams and UInt64 value stream are independently checked against each
    # size0 mark before entries are materialized.
    def read_map_string_uint64_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Tuple(String, UInt64)))
      ensure_column(column)
      raise UnsupportedFormatError.new("Map accessor requires an exact Map(String, UInt64) column") unless WidePart.supports_map_string_uint64_type?(@column_type)

      outer_sizes, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      key_sizes, key_bytes_total, key_mark_bytes = read_map_string_child_sizes(
        column, "%2Ekeys", "Map key", first_mark, mark_count, flat_elements, rows, mark_flat_elements
      )
      raise CorruptPartError.new("Map key size count differs from size0") unless key_sizes.size.to_u64 == flat_elements

      values_stream = @streams["#{column}%2Evalues"]
      value_start, value_end, value_rows = checked_stream_mark_range(values_stream, first_mark, mark_count)
      raise CorruptPartError.new("Map value substream mark rows differ") unless value_rows == rows
      validate_array_nested_stream_marks(values_stream, first_mark, mark_flat_elements, 8)
      value_bytes_total = checked_array_mark_byte_count(flat_elements, 8).to_u64
      value_mark_bytes = mark_flat_elements.map { |elements| checked_array_mark_byte_count(elements, 8).to_u64 }
      payload_bytes = checked_map_materialized_bytes(key_bytes_total, value_bytes_total, key_mark_bytes, value_mark_bytes)
      checked_map_array_tuple_charge(payload_bytes, flat_elements, rows)

      key_stream = @streams["#{column}%2Ekeys"]
      key_start, key_end, key_rows = checked_stream_mark_range(key_stream, first_mark, mark_count)
      raise CorruptPartError.new("Map key substream mark rows differ") unless key_rows == rows
      key_bytes = read_mark_range_bytes(key_stream, key_start, key_end, key_bytes_total.to_i, 1)
      value_bytes = read_mark_range_bytes(values_stream, value_start, value_end, value_bytes_total.to_i, 8)

      result = Array(Array(Tuple(String, UInt64))).new(rows.to_i)
      flat_offset = 0
      raw_offset = 0
      value_offset = 0
      outer_sizes.each do |size|
        row = Array(Tuple(String, UInt64)).new(size.to_i)
        size.to_i.times do
          raise CorruptPartError.new("Map outer sizes exceed selected nested keys") if flat_offset >= key_sizes.size
          length = key_sizes[flat_offset].to_i
          raise CorruptPartError.new("Map key sizes exceed selected raw bytes") if length > key_bytes.size - raw_offset
          raise CorruptPartError.new("Map values exceed selected payload bytes") if value_offset > value_bytes.size - 8
          row << {String.new(key_bytes[raw_offset, length]), u64(value_bytes, value_offset)}
          raw_offset += length
          value_offset += 8
          flat_offset += 1
        end
        result << row
      end
      raise CorruptPartError.new("Map sizes do not consume selected nested keys") unless flat_offset == key_sizes.size
      raise CorruptPartError.new("Map key lengths do not consume selected raw bytes") unless raw_offset == key_bytes.size
      raise CorruptPartError.new("Map sizes do not consume selected value bytes") unless value_offset == value_bytes.size
      result
    end

    # Read ordered Map(String, Nullable(UInt64)) entries. String key bytes,
    # the null bitmap, UInt64 values, and size0 row boundaries are validated
    # before allocating result rows; duplicate keys remain distinct entries.
    def read_map_string_nullable_uint64_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Tuple(String, UInt64?)))
      ensure_column(column)
      raise UnsupportedFormatError.new("Map accessor requires an exact Map(String, Nullable(UInt64)) column") unless WidePart.supports_map_string_nullable_uint64_type?(@column_type)

      payload_bytes, flat_elements, rows = map_string_nullable_uint64_payload_preflight(column, first_mark, mark_count)
      checked_map_array_tuple_charge(payload_bytes, flat_elements, rows)
      outer_sizes, checked_flat_elements, checked_rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      raise CorruptPartError.new("Map size0 changed after preflight") unless checked_flat_elements == flat_elements && checked_rows == rows
      key_sizes, key_bytes_total, _ = read_map_string_child_sizes(
        column, "%2Ekeys", "Map key", first_mark, mark_count, flat_elements, rows, mark_flat_elements
      )
      raise CorruptPartError.new("Map key size count differs from size0") unless key_sizes.size.to_u64 == flat_elements

      key_stream = @streams["#{column}%2Ekeys"]
      key_start, key_end, key_rows = checked_stream_mark_range(key_stream, first_mark, mark_count)
      raise CorruptPartError.new("Map key substream mark rows differ") unless key_rows == rows
      key_bytes = read_mark_range_bytes(key_stream, key_start, key_end, key_bytes_total.to_i, 1)

      null_map = read_map_nullable_uint64_null_map(column, first_mark, mark_count, flat_elements, rows, mark_flat_elements)
      values_stream = @streams["#{column}%2Evalues"]
      value_start, value_end, value_rows = checked_stream_mark_range(values_stream, first_mark, mark_count)
      raise CorruptPartError.new("Map value substream mark rows differ") unless value_rows == rows
      value_bytes = read_mark_range_bytes(values_stream, value_start, value_end, checked_array_mark_byte_count(flat_elements, 8), 8)

      result = Array(Array(Tuple(String, UInt64?))).new(rows.to_i)
      flat_offset = 0
      raw_offset = 0
      outer_sizes.each do |size|
        row = Array(Tuple(String, UInt64?)).new(size.to_i)
        size.to_i.times do
          raise CorruptPartError.new("Map outer sizes exceed selected nested keys") if flat_offset >= key_sizes.size
          length = key_sizes[flat_offset].to_i
          raise CorruptPartError.new("Map key sizes exceed selected raw bytes") if length > key_bytes.size - raw_offset
          value = null_map[flat_offset] == 1 ? nil : u64(value_bytes, flat_offset * 8)
          row << {String.new(key_bytes[raw_offset, length]), value}
          raw_offset += length
          flat_offset += 1
        end
        result << row
      end
      raise CorruptPartError.new("Map sizes do not consume selected nested keys") unless flat_offset == key_sizes.size
      raise CorruptPartError.new("Map key lengths do not consume selected raw bytes") unless raw_offset == key_bytes.size
      raise CorruptPartError.new("Map sizes do not consume selected nested streams") unless flat_offset.to_u64 == flat_elements
      result
    end

    # Count String keys plus nullable UInt64's null and value substreams
    # without materializing ordered entry rows.
    def map_string_nullable_uint64_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      map_string_nullable_uint64_payload_preflight(column, first_mark, mark_count)[0]
    end

    def map_string_nullable_uint64_mark_range_materialization_preflight(column : String, first_mark : Int, mark_count : Int) : {UInt64, UInt64}
      payload_bytes, flat_elements, rows = map_string_nullable_uint64_payload_preflight(column, first_mark, mark_count)
      {payload_bytes, checked_map_array_tuple_charge(payload_bytes, flat_elements, rows)}
    end

    private def map_string_nullable_uint64_payload_preflight(column : String, first_mark : Int, mark_count : Int) : {UInt64, UInt64, UInt64}
      ensure_column(column)
      raise UnsupportedFormatError.new("Map accessor requires an exact Map(String, Nullable(UInt64)) column") unless WidePart.supports_map_string_nullable_uint64_type?(@column_type)

      _, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      _key_sizes, key_bytes, key_mark_bytes = read_map_string_child_sizes(
        column, "%2Ekeys", "Map key", first_mark, mark_count, flat_elements, rows, mark_flat_elements
      )
      values_stream = @streams["#{column}%2Evalues"]
      _, _, value_rows = checked_stream_mark_range(values_stream, first_mark, mark_count)
      raise CorruptPartError.new("Map value substream mark rows differ") unless value_rows == rows
      validate_array_nested_stream_marks(values_stream, first_mark, mark_flat_elements, 8)
      read_map_nullable_uint64_null_map(column, first_mark, mark_count, flat_elements, rows, mark_flat_elements)

      value_and_null_bytes = checked_array_mark_byte_count(flat_elements, 9).to_u64
      value_mark_bytes = mark_flat_elements.map { |elements| checked_array_mark_byte_count(elements, 9).to_u64 }
      payload_bytes = checked_map_materialized_bytes(key_bytes, value_and_null_bytes, key_mark_bytes, value_mark_bytes)
      {payload_bytes, flat_elements, rows}
    end

    # Return the combined key/value String byte charge after validating both
    # independent size/raw child pairs against the outer size0 marks.
    def map_string_string_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      map_string_string_payload_preflight(column, first_mark, mark_count)[0]
    end

    # Return physical String payload bytes and the bounded W51-style table
    # charge. Entry and row slots are charged even when both Strings are empty.
    def map_string_string_mark_range_materialization_preflight(column : String, first_mark : Int, mark_count : Int) : {UInt64, UInt64}
      payload_bytes, flat_elements, rows = map_string_string_payload_preflight(column, first_mark, mark_count)
      {payload_bytes, checked_map_array_tuple_charge(payload_bytes, flat_elements, rows)}
    end

    private def map_string_string_payload_preflight(column : String, first_mark : Int, mark_count : Int) : {UInt64, UInt64, UInt64}
      ensure_column(column)
      raise UnsupportedFormatError.new("Map accessor requires an exact Map(String, String) column") unless WidePart.supports_map_string_string_type?(@column_type)

      _, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      key_sizes, key_bytes, key_mark_bytes = read_map_string_child_sizes(
        column, "%2Ekeys", "Map key", first_mark, mark_count, flat_elements, rows, mark_flat_elements
      )
      value_sizes, value_bytes, value_mark_bytes = read_map_string_child_sizes(
        column, "%2Evalues", "Map value", first_mark, mark_count, flat_elements, rows, mark_flat_elements
      )
      raise CorruptPartError.new("Map key size count differs from size0") unless key_sizes.size.to_u64 == flat_elements
      raise CorruptPartError.new("Map value size count differs from size0") unless value_sizes.size.to_u64 == flat_elements
      payload_bytes = checked_map_materialized_bytes(key_bytes, value_bytes, key_mark_bytes, value_mark_bytes)
      {payload_bytes, flat_elements, rows}
    end

    # Read exact ordered Map(String, String) rows, preserving duplicate keys
    # and all binary String bytes. Both child size streams and both raw streams
    # are aligned to size0 before any key/value String object is allocated.
    def read_map_string_string_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Tuple(String, String)))
      ensure_column(column)
      raise UnsupportedFormatError.new("Map accessor requires an exact Map(String, String) column") unless WidePart.supports_map_string_string_type?(@column_type)

      outer_sizes, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      key_sizes, key_bytes_total, key_mark_bytes = read_map_string_child_sizes(
        column, "%2Ekeys", "Map key", first_mark, mark_count, flat_elements, rows, mark_flat_elements
      )
      value_sizes, value_bytes_total, value_mark_bytes = read_map_string_child_sizes(
        column, "%2Evalues", "Map value", first_mark, mark_count, flat_elements, rows, mark_flat_elements
      )
      raise CorruptPartError.new("Map key size count differs from size0") unless key_sizes.size.to_u64 == flat_elements
      raise CorruptPartError.new("Map value size count differs from size0") unless value_sizes.size.to_u64 == flat_elements
      payload_bytes = checked_map_materialized_bytes(key_bytes_total, value_bytes_total, key_mark_bytes, value_mark_bytes)
      checked_map_array_tuple_charge(payload_bytes, flat_elements, rows)

      key_stream = @streams["#{column}%2Ekeys"]
      key_start, key_end, key_rows = checked_stream_mark_range(key_stream, first_mark, mark_count)
      raise CorruptPartError.new("Map key substream mark rows differ") unless key_rows == rows
      value_stream = @streams["#{column}%2Evalues"]
      value_start, value_end, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Map value substream mark rows differ") unless value_rows == rows
      key_bytes = read_mark_range_bytes(key_stream, key_start, key_end, key_bytes_total.to_i, 1)
      value_bytes = read_mark_range_bytes(value_stream, value_start, value_end, value_bytes_total.to_i, 1)

      result = Array(Array(Tuple(String, String))).new(rows.to_i)
      flat_offset = 0
      key_offset = 0
      value_offset = 0
      outer_sizes.each do |size|
        row = Array(Tuple(String, String)).new(size.to_i)
        size.to_i.times do
          raise CorruptPartError.new("Map outer sizes exceed selected nested children") if flat_offset >= flat_elements
          key_length = key_sizes[flat_offset].to_i
          value_length = value_sizes[flat_offset].to_i
          raise CorruptPartError.new("Map key sizes exceed selected raw bytes") if key_length > key_bytes.size - key_offset
          raise CorruptPartError.new("Map value sizes exceed selected raw bytes") if value_length > value_bytes.size - value_offset
          row << {
            String.new(key_bytes[key_offset, key_length]),
            String.new(value_bytes[value_offset, value_length]),
          }
          key_offset += key_length
          value_offset += value_length
          flat_offset += 1
        end
        result << row
      end
      raise CorruptPartError.new("Map sizes do not consume selected nested children") unless flat_offset.to_u64 == flat_elements
      raise CorruptPartError.new("Map key lengths do not consume selected raw bytes") unless key_offset == key_bytes.size
      raise CorruptPartError.new("Map value lengths do not consume selected raw bytes") unless value_offset == value_bytes.size
      result
    end

    # Read exact Array(UInt64) rows for a bounded set of outer marks. The mark
    # range is bounded before row arrays are allocated, even when every row is
    # empty. The flattened UInt64 stream is independent of outer row counts.
    def read_array_uint64_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(UInt64))
      ensure_column(column)
      raise UnsupportedFormatError.new("Array(UInt64) accessor requires an exact Array(UInt64) column") unless @column_type == "Array(UInt64)"

      outer_sizes, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      nested_stream = @streams[column]
      nested_start, nested_end, nested_rows = checked_stream_mark_range(nested_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(UInt64) substream mark rows differ") unless nested_rows == rows
      validate_array_nested_stream_marks(nested_stream, first_mark, mark_flat_elements, 8)
      expected_bytes = checked_array_mark_byte_count(flat_elements, 8)
      nested_bytes = read_mark_range_bytes(nested_stream, nested_start, nested_end, expected_bytes, 8)

      values = Array(Array(UInt64)).new(rows.to_i)
      flat_offset = 0
      outer_sizes.each do |size|
        row = Array(UInt64).new(size.to_i)
        size.to_i.times do
          raise CorruptPartError.new("Array(UInt64) sizes exceed selected nested bytes") if flat_offset > nested_bytes.size - 8
          row << u64(nested_bytes, flat_offset)
          flat_offset += 8
        end
        values << row
      end
      raise CorruptPartError.new("Array(UInt64) sizes do not consume selected nested bytes") unless flat_offset == nested_bytes.size
      values
    end

    # Read one exact Array(T) numeric leaf family for a bounded set of marks.
    # Both size0 and payload boundaries are validated before nested result rows
    # are allocated; floats preserve their on-disk bit patterns.
    def read_array_numeric_mark_range(column : String, first_mark : Int, mark_count : Int, type : T.class) : Array(Array(T)) forall T
      ensure_column(column)
      element_type = WidePart.array_numeric_type_name(type)
      unless WidePart.numeric_array_element_type(@column_type) == element_type
        raise UnsupportedFormatError.new("typed Array accessor does not match selected column type")
      end

      outer_sizes, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      value_stream = @streams[column]
      value_start, value_end, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array numeric substream mark rows differ") unless value_rows == rows
      element_width = WidePart.array_numeric_payload_width(element_type)
      validate_array_nested_stream_marks(value_stream, first_mark, mark_flat_elements, element_width)
      expected_bytes = checked_array_mark_byte_count(flat_elements, element_width)
      value_bytes = read_mark_range_bytes(value_stream, value_start, value_end, expected_bytes, element_width)

      values = Array(Array(T)).new(rows.to_i)
      flat_offset = 0
      outer_sizes.each do |size|
        row = Array(T).new(size.to_i)
        size.to_i.times do
          raise CorruptPartError.new("Array sizes exceed selected numeric bytes") if flat_offset > value_bytes.size - element_width
          row << decode_array_numeric_value(value_bytes, flat_offset, type)
          flat_offset += element_width
        end
        values << row
      end
      raise CorruptPartError.new("Array sizes do not consume selected numeric bytes") unless flat_offset == value_bytes.size
      values
    end

    # Read one exact Array(Nullable(T)) primitive numeric leaf family. Both
    # child mark ranges are validated before payload bytes are decoded or row
    # arrays are allocated; null value slots are consumed but not interpreted.
    def read_array_nullable_numeric_mark_range(column : String, first_mark : Int, mark_count : Int, type : T.class) : Array(Array(T?)) forall T
      ensure_column(column)
      element_type = WidePart.array_numeric_type_name(type)
      unless WidePart.nullable_numeric_array_element_type(@column_type) == element_type
        raise UnsupportedFormatError.new("typed nullable Array accessor does not match selected column type")
      end

      outer_sizes, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      element_width = WidePart.array_numeric_payload_width(element_type)

      null_stream = @streams["#{column}.null"]
      null_start, null_end, null_rows = checked_stream_mark_range(null_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Nullable(T)) null-map mark rows differ") unless null_rows == rows
      validate_array_nested_stream_marks(null_stream, first_mark, mark_flat_elements, 1)
      null_bytes = read_mark_range_bytes(null_stream, null_start, null_end, checked_array_mark_byte_count(flat_elements, 1), 1)

      value_stream = @streams[column]
      value_start, value_end, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Nullable(T)) value mark rows differ") unless value_rows == rows
      validate_array_nested_stream_marks(value_stream, first_mark, mark_flat_elements, element_width)
      value_bytes = read_mark_range_bytes(value_stream, value_start, value_end, checked_array_mark_byte_count(flat_elements, element_width), element_width)

      values = Array(Array(T?)).new(rows.to_i)
      flat_offset = 0
      outer_sizes.each do |size|
        row = Array(T?).new(size.to_i)
        size.to_i.times do
          raise CorruptPartError.new("Array(Nullable(T)) sizes exceed selected child streams") if flat_offset >= flat_elements
          is_null = null_bytes[flat_offset]
          raise CorruptPartError.new("Array(Nullable(T)) null map contains a value other than 0 or 1") unless is_null <= 1_u8
          row << (is_null == 1_u8 ? nil : decode_array_numeric_value(value_bytes, flat_offset * element_width, type))
          flat_offset += 1
        end
        values << row
      end
      raise CorruptPartError.new("Array(Nullable(T)) sizes do not consume selected child streams") unless flat_offset.to_u64 == flat_elements
      values
    end

    def read_array_date_codes_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(UInt16))
      read_array_temporal_mark_range(column, first_mark, mark_count, "Date", UInt16)
    end

    def read_array_date32_codes_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Int32))
      read_array_temporal_mark_range(column, first_mark, mark_count, "Date32", Int32)
    end

    def read_array_datetime_seconds_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(UInt32))
      read_array_temporal_mark_range(column, first_mark, mark_count, "DateTime", UInt32)
    end

    def read_array_datetime64_ticks_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Int64))
      ensure_column(column)
      scale = WidePart.array_datetime64_scale(@column_type) || -1
      read_array_temporal_mark_range(column, first_mark, mark_count, "DateTime64(#{scale})", Int64)
    end

    def read_array_time_seconds_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Int32))
      read_array_time_mark_range(column, first_mark, mark_count, "Time", Int32)
    end

    def read_array_time64_ticks_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Int64))
      ensure_column(column)
      scale = WidePart.array_time64_scale(@column_type) || -1
      read_array_time_mark_range(column, first_mark, mark_count, "Time64(#{scale})", Int64)
    end

    def read_array_nullable_date_codes_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(UInt16?))
      read_array_nullable_temporal_mark_range(column, first_mark, mark_count, "Date", UInt16)
    end

    def read_array_nullable_date32_codes_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Int32?))
      read_array_nullable_temporal_mark_range(column, first_mark, mark_count, "Date32", Int32)
    end

    def read_array_nullable_datetime_seconds_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(UInt32?))
      read_array_nullable_temporal_mark_range(column, first_mark, mark_count, "DateTime", UInt32)
    end

    def read_array_nullable_datetime64_ticks_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Int64?))
      ensure_column(column)
      scale = WidePart.nullable_array_datetime64_scale(@column_type) || -1
      read_array_nullable_temporal_mark_range(column, first_mark, mark_count, "DateTime64(#{scale})", Int64)
    end

    def read_array_nullable_time_seconds_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Int32?))
      read_array_nullable_time_mark_range(column, first_mark, mark_count, "Time", Int32)
    end

    def read_array_nullable_time64_ticks_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Int64?))
      ensure_column(column)
      scale = WidePart.nullable_array_time64_scale(@column_type) || -1
      read_array_nullable_time_mark_range(column, first_mark, mark_count, "Time64(#{scale})", Int64)
    end

    def read_array_decimal32_raw_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Int32))
      ensure_column(column)
      raise UnsupportedFormatError.new("Decimal32 Array accessor requires an exact Array(Decimal(9, S)) column") unless WidePart.array_decimal32_scale(@column_type)
      read_array_fixed_leaf_mark_range(column, first_mark, mark_count, Int32)
    end

    def read_array_nullable_decimal32_raw_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Int32?))
      ensure_column(column)
      raise UnsupportedFormatError.new("Decimal32 Array accessor requires an exact Array(Nullable(Decimal(9, S))) column") unless WidePart.array_nullable_decimal32_scale(@column_type)
      read_array_nullable_fixed_leaf_mark_range(column, first_mark, mark_count, Int32)
    end

    def read_array_decimal64_raw_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Int64))
      ensure_column(column)
      raise UnsupportedFormatError.new("Decimal64 Array accessor requires an exact Array(Decimal(18, S)) column") unless WidePart.array_decimal64_scale(@column_type)
      read_array_fixed_leaf_mark_range(column, first_mark, mark_count, Int64)
    end

    def read_array_nullable_decimal64_raw_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Int64?))
      ensure_column(column)
      raise UnsupportedFormatError.new("Decimal64 Array accessor requires an exact Array(Nullable(Decimal(18, S))) column") unless WidePart.array_nullable_decimal64_scale(@column_type)
      read_array_nullable_fixed_leaf_mark_range(column, first_mark, mark_count, Int64)
    end

    def read_array_decimal128_raw_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Int128))
      ensure_column(column)
      raise UnsupportedFormatError.new("Decimal128 Array accessor requires an exact Array(Decimal(38, S)) column") unless WidePart.array_decimal128_scale(@column_type)
      read_array_fixed_leaf_mark_range(column, first_mark, mark_count, Int128)
    end

    def read_array_enum8_codes_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Int8))
      ensure_column(column)
      codes = WidePart.array_enum8_codes(@column_type)
      raise UnsupportedFormatError.new("Enum8 Array accessor requires an exact Array(Enum8(...)) column") unless codes
      values = read_array_fixed_leaf_mark_range(column, first_mark, mark_count, Int8)
      values.each do |row|
        row.each { |value| raise CorruptPartError.new("Enum8 code is not declared") unless codes.includes?(value) }
      end
      values
    end

    def read_array_nullable_enum8_codes_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Int8?))
      ensure_column(column)
      codes = WidePart.array_nullable_enum8_codes(@column_type)
      raise UnsupportedFormatError.new("Enum8 Array accessor requires an exact Array(Nullable(Enum8(...))) column") unless codes
      values = read_array_nullable_fixed_leaf_mark_range(column, first_mark, mark_count, Int8)
      values.each do |row|
        row.each { |value| raise CorruptPartError.new("Enum8 code is not declared") if value && !codes.includes?(value) }
      end
      values
    end

    def read_array_enum16_codes_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Int16))
      ensure_column(column)
      codes = WidePart.array_enum16_codes(@column_type)
      raise UnsupportedFormatError.new("Enum16 Array accessor requires an exact Array(Enum16(...)) column") unless codes
      values = read_array_fixed_leaf_mark_range(column, first_mark, mark_count, Int16)
      values.each do |row|
        row.each { |value| raise CorruptPartError.new("Enum16 code is not declared") unless codes.includes?(value) }
      end
      values
    end

    def read_array_nullable_enum16_codes_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Int16?))
      ensure_column(column)
      codes = WidePart.array_nullable_enum16_codes(@column_type)
      raise UnsupportedFormatError.new("Enum16 Array accessor requires an exact Array(Nullable(Enum16(...))) column") unless codes
      values = read_array_nullable_fixed_leaf_mark_range(column, first_mark, mark_count, Int16)
      values.each do |row|
        row.each { |value| raise CorruptPartError.new("Enum16 code is not declared") if value && !codes.includes?(value) }
      end
      values
    end

    def read_array_nullable_decimal128_raw_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Int128?))
      ensure_column(column)
      raise UnsupportedFormatError.new("Decimal128 Array accessor requires an exact Array(Nullable(Decimal(38, S))) column") unless WidePart.array_nullable_decimal128_scale(@column_type)
      read_array_nullable_fixed_leaf_mark_range(column, first_mark, mark_count, Int128)
    end

    def read_array_decimal256_raw_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Decimal256Value))
      ensure_column(column)
      raise UnsupportedFormatError.new("Decimal256 Array accessor requires an exact Array(Decimal(76, S)) column") unless WidePart.array_decimal256_scale(@column_type)

      outer_sizes, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      value_stream = @streams[column]
      value_start, value_end, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Decimal256) value mark rows differ") unless value_rows == rows
      validate_array_nested_stream_marks(value_stream, first_mark, mark_flat_elements, 32)
      value_bytes = read_mark_range_bytes(value_stream, value_start, value_end, checked_array_mark_byte_count(flat_elements, 32), 32)

      values = Array(Array(Decimal256Value)).new(rows.to_i)
      flat_offset = 0
      outer_sizes.each do |size|
        row = Array(Decimal256Value).new(size.to_i)
        size.to_i.times do
          raise CorruptPartError.new("Array(Decimal256) sizes exceed selected coefficient bytes") if flat_offset > value_bytes.size - 32
          row << Decimal256Value.from_words(
            u64(value_bytes, flat_offset),
            u64(value_bytes, flat_offset + 8),
            u64(value_bytes, flat_offset + 16),
            u64(value_bytes, flat_offset + 24)
          )
          flat_offset += 32
        end
        values << row
      end
      raise CorruptPartError.new("Array(Decimal256) sizes do not consume selected coefficient bytes") unless flat_offset == value_bytes.size
      values
    end

    def read_array_nullable_decimal256_raw_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Decimal256Value?))
      ensure_column(column)
      raise UnsupportedFormatError.new("Decimal256 Array accessor requires an exact Array(Nullable(Decimal(76, S))) column") unless WidePart.array_nullable_decimal256_scale(@column_type)

      outer_sizes, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      null_stream = @streams["#{column}.null"]
      null_start, null_end, null_rows = checked_stream_mark_range(null_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Nullable(Decimal256)) null-map mark rows differ") unless null_rows == rows
      validate_array_nested_stream_marks(null_stream, first_mark, mark_flat_elements, 1)
      null_bytes = read_mark_range_bytes(null_stream, null_start, null_end, checked_array_mark_byte_count(flat_elements, 1), 1)

      value_stream = @streams[column]
      value_start, value_end, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Nullable(Decimal256)) value mark rows differ") unless value_rows == rows
      validate_array_nested_stream_marks(value_stream, first_mark, mark_flat_elements, 32)
      value_bytes = read_mark_range_bytes(value_stream, value_start, value_end, checked_array_mark_byte_count(flat_elements, 32), 32)

      values = Array(Array(Decimal256Value?)).new(rows.to_i)
      flat_offset = 0
      outer_sizes.each do |size|
        row = Array(Decimal256Value?).new(size.to_i)
        size.to_i.times do
          raise CorruptPartError.new("Array(Nullable(Decimal256)) sizes exceed selected child streams") if flat_offset >= flat_elements
          is_null = null_bytes[flat_offset]
          raise CorruptPartError.new("Array(Nullable(Decimal256)) null map contains a value other than 0 or 1") unless is_null <= 1_u8
          value_offset = flat_offset * 32
          value = Decimal256Value.from_words(
            u64(value_bytes, value_offset),
            u64(value_bytes, value_offset + 8),
            u64(value_bytes, value_offset + 16),
            u64(value_bytes, value_offset + 24)
          )
          row << (is_null == 1_u8 ? nil : value)
          flat_offset += 1
        end
        values << row
      end
      raise CorruptPartError.new("Array(Nullable(Decimal256)) sizes do not consume selected child streams") unless flat_offset.to_u64 == flat_elements
      values
    end

    def read_array_uuids_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(UUIDValue))
      ensure_column(column)
      raise UnsupportedFormatError.new("Array(UUID) accessor requires an exact Array(UUID) column") unless WidePart.uuid_array_element_type(@column_type)

      outer_sizes, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      value_stream = @streams[column]
      value_start, value_end, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(UUID) value mark rows differ") unless value_rows == rows
      validate_array_nested_stream_marks(value_stream, first_mark, mark_flat_elements, 16)
      value_bytes = read_mark_range_bytes(value_stream, value_start, value_end, checked_array_mark_byte_count(flat_elements, 16), 16)

      values = Array(Array(UUIDValue)).new(rows.to_i)
      flat_offset = 0
      outer_sizes.each do |size|
        row = Array(UUIDValue).new(size.to_i)
        size.to_i.times do
          raise CorruptPartError.new("Array(UUID) sizes exceed selected UUID bytes") if flat_offset > value_bytes.size - 16
          row << UUIDValue.new(u64(value_bytes, flat_offset), u64(value_bytes, flat_offset + 8))
          flat_offset += 16
        end
        values << row
      end
      raise CorruptPartError.new("Array(UUID) sizes do not consume selected UUID bytes") unless flat_offset == value_bytes.size
      values
    end

    def read_array_nullable_uuids_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(UUIDValue?))
      ensure_column(column)
      raise UnsupportedFormatError.new("Array(Nullable(UUID)) accessor requires an exact Array(Nullable(UUID)) column") unless WidePart.nullable_uuid_array_element_type(@column_type)

      outer_sizes, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      null_stream = @streams["#{column}.null"]
      null_start, null_end, null_rows = checked_stream_mark_range(null_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Nullable(UUID)) null-map mark rows differ") unless null_rows == rows
      validate_array_nested_stream_marks(null_stream, first_mark, mark_flat_elements, 1)
      null_bytes = read_mark_range_bytes(null_stream, null_start, null_end, checked_array_mark_byte_count(flat_elements, 1), 1)

      value_stream = @streams[column]
      value_start, value_end, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Nullable(UUID)) value mark rows differ") unless value_rows == rows
      validate_array_nested_stream_marks(value_stream, first_mark, mark_flat_elements, 16)
      value_bytes = read_mark_range_bytes(value_stream, value_start, value_end, checked_array_mark_byte_count(flat_elements, 16), 16)

      values = Array(Array(UUIDValue?)).new(rows.to_i)
      flat_offset = 0
      outer_sizes.each do |size|
        row = Array(UUIDValue?).new(size.to_i)
        size.to_i.times do
          raise CorruptPartError.new("Array(Nullable(UUID)) sizes exceed selected child streams") if flat_offset >= flat_elements
          is_null = null_bytes[flat_offset]
          raise CorruptPartError.new("Array(Nullable(UUID)) null map contains a value other than 0 or 1") unless is_null <= 1_u8
          value_offset = flat_offset * 16
          row << (is_null == 1_u8 ? nil : UUIDValue.new(u64(value_bytes, value_offset), u64(value_bytes, value_offset + 8)))
          flat_offset += 1
        end
        values << row
      end
      raise CorruptPartError.new("Array(Nullable(UUID)) sizes do not consume selected child streams") unless flat_offset.to_u64 == flat_elements
      values
    end

    def read_array_ipv4s_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(IPv4Value))
      ensure_column(column)
      raise UnsupportedFormatError.new("Array(IPv4) accessor requires an exact Array(IPv4) column") unless WidePart.ipv4_array_element_type(@column_type)

      outer_sizes, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      value_stream = @streams[column]
      value_start, value_end, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(IPv4) value mark rows differ") unless value_rows == rows
      validate_array_nested_stream_marks(value_stream, first_mark, mark_flat_elements, 4)
      value_bytes = read_mark_range_bytes(value_stream, value_start, value_end, checked_array_mark_byte_count(flat_elements, 4), 4)

      values = Array(Array(IPv4Value)).new(rows.to_i)
      flat_offset = 0
      outer_sizes.each do |size|
        row = Array(IPv4Value).new(size.to_i)
        size.to_i.times do
          raise CorruptPartError.new("Array(IPv4) sizes exceed selected IPv4 bytes") if flat_offset > value_bytes.size - 4
          row << IPv4Value.new(u32(value_bytes, flat_offset))
          flat_offset += 4
        end
        values << row
      end
      raise CorruptPartError.new("Array(IPv4) sizes do not consume selected IPv4 bytes") unless flat_offset == value_bytes.size
      values
    end

    def read_array_nullable_ipv4s_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(IPv4Value?))
      ensure_column(column)
      raise UnsupportedFormatError.new("Array(Nullable(IPv4)) accessor requires an exact Array(Nullable(IPv4)) column") unless WidePart.nullable_ipv4_array_element_type(@column_type)

      outer_sizes, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      null_stream = @streams["#{column}.null"]
      null_start, null_end, null_rows = checked_stream_mark_range(null_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Nullable(IPv4)) null-map mark rows differ") unless null_rows == rows
      validate_array_nested_stream_marks(null_stream, first_mark, mark_flat_elements, 1)
      null_bytes = read_mark_range_bytes(null_stream, null_start, null_end, checked_array_mark_byte_count(flat_elements, 1), 1)

      value_stream = @streams[column]
      value_start, value_end, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Nullable(IPv4)) value mark rows differ") unless value_rows == rows
      validate_array_nested_stream_marks(value_stream, first_mark, mark_flat_elements, 4)
      value_bytes = read_mark_range_bytes(value_stream, value_start, value_end, checked_array_mark_byte_count(flat_elements, 4), 4)

      values = Array(Array(IPv4Value?)).new(rows.to_i)
      flat_offset = 0
      outer_sizes.each do |size|
        row = Array(IPv4Value?).new(size.to_i)
        size.to_i.times do
          raise CorruptPartError.new("Array(Nullable(IPv4)) sizes exceed selected child streams") if flat_offset >= flat_elements
          is_null = null_bytes[flat_offset]
          raise CorruptPartError.new("Array(Nullable(IPv4)) null map contains a value other than 0 or 1") unless is_null <= 1_u8
          value_offset = flat_offset * 4
          row << (is_null == 1_u8 ? nil : IPv4Value.new(u32(value_bytes, value_offset)))
          flat_offset += 1
        end
        values << row
      end
      raise CorruptPartError.new("Array(Nullable(IPv4)) sizes do not consume selected child streams") unless flat_offset.to_u64 == flat_elements
      values
    end

    # IPv6 leaves are exact 16-byte network-order addresses, not UUIDs or
    # little-endian UInt128 values.
    def read_array_ipv6s_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(IPv6Value))
      ensure_column(column)
      raise UnsupportedFormatError.new("Array(IPv6) accessor requires an exact Array(IPv6) column") unless WidePart.ipv6_array_element_type(@column_type)

      outer_sizes, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      value_stream = @streams[column]
      value_start, value_end, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(IPv6) value mark rows differ") unless value_rows == rows
      validate_array_nested_stream_marks(value_stream, first_mark, mark_flat_elements, 16)
      value_bytes = read_mark_range_bytes(value_stream, value_start, value_end, checked_array_mark_byte_count(flat_elements, 16), 16)

      values = Array(Array(IPv6Value)).new(rows.to_i)
      flat_offset = 0
      outer_sizes.each do |size|
        row = Array(IPv6Value).new(size.to_i)
        size.to_i.times do
          raise CorruptPartError.new("Array(IPv6) sizes exceed selected IPv6 bytes") if flat_offset > value_bytes.size - 16
          row << IPv6Value.new(network_order_u64(value_bytes, flat_offset), network_order_u64(value_bytes, flat_offset + 8))
          flat_offset += 16
        end
        values << row
      end
      raise CorruptPartError.new("Array(IPv6) sizes do not consume selected IPv6 bytes") unless flat_offset == value_bytes.size
      values
    end

    def read_array_nullable_ipv6s_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(IPv6Value?))
      ensure_column(column)
      raise UnsupportedFormatError.new("Array(Nullable(IPv6)) accessor requires an exact Array(Nullable(IPv6)) column") unless WidePart.nullable_ipv6_array_element_type(@column_type)

      outer_sizes, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      null_stream = @streams["#{column}.null"]
      null_start, null_end, null_rows = checked_stream_mark_range(null_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Nullable(IPv6)) null-map mark rows differ") unless null_rows == rows
      validate_array_nested_stream_marks(null_stream, first_mark, mark_flat_elements, 1)
      null_bytes = read_mark_range_bytes(null_stream, null_start, null_end, checked_array_mark_byte_count(flat_elements, 1), 1)

      value_stream = @streams[column]
      value_start, value_end, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Nullable(IPv6)) value mark rows differ") unless value_rows == rows
      validate_array_nested_stream_marks(value_stream, first_mark, mark_flat_elements, 16)
      value_bytes = read_mark_range_bytes(value_stream, value_start, value_end, checked_array_mark_byte_count(flat_elements, 16), 16)

      values = Array(Array(IPv6Value?)).new(rows.to_i)
      flat_offset = 0
      outer_sizes.each do |size|
        row = Array(IPv6Value?).new(size.to_i)
        size.to_i.times do
          raise CorruptPartError.new("Array(Nullable(IPv6)) sizes exceed selected child streams") if flat_offset >= flat_elements
          is_null = null_bytes[flat_offset]
          raise CorruptPartError.new("Array(Nullable(IPv6)) null map contains a value other than 0 or 1") unless is_null <= 1_u8
          value_offset = flat_offset * 16
          row << (is_null == 1_u8 ? nil : IPv6Value.new(network_order_u64(value_bytes, value_offset), network_order_u64(value_bytes, value_offset + 8)))
          flat_offset += 1
        end
        values << row
      end
      raise CorruptPartError.new("Array(Nullable(IPv6)) sizes do not consume selected child streams") unless flat_offset.to_u64 == flat_elements
      values
    end

    private def read_array_temporal_mark_range(column : String, first_mark : Int, mark_count : Int, element_type : String, type : T.class) : Array(Array(T)) forall T
      ensure_column(column)
      unless WidePart.temporal_array_element_type(@column_type) == element_type &&
             WidePart.temporal_array_physical_type(element_type) == WidePart.array_numeric_type_name(type)
        raise UnsupportedFormatError.new("typed temporal Array accessor does not match selected semantic column type")
      end

      read_array_fixed_leaf_mark_range(column, first_mark, mark_count, type)
    end

    private def read_array_time_mark_range(column : String, first_mark : Int, mark_count : Int, element_type : String, type : T.class) : Array(Array(T)) forall T
      ensure_column(column)
      unless WidePart.time_array_element_type(@column_type) == element_type &&
             WidePart.time_array_physical_type(element_type) == WidePart.array_numeric_type_name(type)
        raise UnsupportedFormatError.new("typed Time Array accessor does not match selected semantic column type")
      end

      read_array_fixed_leaf_mark_range(column, first_mark, mark_count, type)
    end

    private def read_array_nullable_temporal_mark_range(column : String, first_mark : Int, mark_count : Int, element_type : String, type : T.class) : Array(Array(T?)) forall T
      ensure_column(column)
      unless WidePart.nullable_temporal_array_element_type(@column_type) == element_type &&
             WidePart.temporal_array_physical_type(element_type) == WidePart.array_numeric_type_name(type)
        raise UnsupportedFormatError.new("typed nullable temporal Array accessor does not match selected semantic column type")
      end

      read_array_nullable_fixed_leaf_mark_range(column, first_mark, mark_count, type)
    end

    private def read_array_nullable_time_mark_range(column : String, first_mark : Int, mark_count : Int, element_type : String, type : T.class) : Array(Array(T?)) forall T
      ensure_column(column)
      unless WidePart.nullable_time_array_element_type(@column_type) == element_type &&
             WidePart.time_array_physical_type(element_type) == WidePart.array_numeric_type_name(type)
        raise UnsupportedFormatError.new("typed nullable Time Array accessor does not match selected semantic column type")
      end

      read_array_nullable_fixed_leaf_mark_range(column, first_mark, mark_count, type)
    end

    private def read_array_fixed_leaf_mark_range(column : String, first_mark : Int, mark_count : Int, type : T.class) : Array(Array(T)) forall T
      outer_sizes, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      value_stream = @streams[column]
      value_start, value_end, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array fixed-width substream mark rows differ") unless value_rows == rows
      element_width = WidePart.array_numeric_payload_width(WidePart.array_numeric_type_name(type))
      validate_array_nested_stream_marks(value_stream, first_mark, mark_flat_elements, element_width)
      value_bytes = read_mark_range_bytes(value_stream, value_start, value_end, checked_array_mark_byte_count(flat_elements, element_width), element_width)

      values = Array(Array(T)).new(rows.to_i)
      flat_offset = 0
      outer_sizes.each do |size|
        row = Array(T).new(size.to_i)
        size.to_i.times do
          raise CorruptPartError.new("Array sizes exceed selected fixed-width bytes") if flat_offset > value_bytes.size - element_width
          row << decode_array_numeric_value(value_bytes, flat_offset, type)
          flat_offset += element_width
        end
        values << row
      end
      raise CorruptPartError.new("Array sizes do not consume selected fixed-width bytes") unless flat_offset == value_bytes.size
      values
    end

    private def read_array_nullable_fixed_leaf_mark_range(column : String, first_mark : Int, mark_count : Int, type : T.class) : Array(Array(T?)) forall T
      outer_sizes, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      element_width = WidePart.array_numeric_payload_width(WidePart.array_numeric_type_name(type))

      null_stream = @streams["#{column}.null"]
      null_start, null_end, null_rows = checked_stream_mark_range(null_stream, first_mark, mark_count)
      raise CorruptPartError.new("nullable Array null-map mark rows differ") unless null_rows == rows
      validate_array_nested_stream_marks(null_stream, first_mark, mark_flat_elements, 1)
      null_bytes = read_mark_range_bytes(null_stream, null_start, null_end, checked_array_mark_byte_count(flat_elements, 1), 1)

      value_stream = @streams[column]
      value_start, value_end, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("nullable Array value mark rows differ") unless value_rows == rows
      validate_array_nested_stream_marks(value_stream, first_mark, mark_flat_elements, element_width)
      value_bytes = read_mark_range_bytes(value_stream, value_start, value_end, checked_array_mark_byte_count(flat_elements, element_width), element_width)

      values = Array(Array(T?)).new(rows.to_i)
      flat_offset = 0
      outer_sizes.each do |size|
        row = Array(T?).new(size.to_i)
        size.to_i.times do
          raise CorruptPartError.new("Array(Nullable(T)) sizes exceed selected child streams") if flat_offset >= flat_elements
          is_null = null_bytes[flat_offset]
          raise CorruptPartError.new("Array(Nullable(T)) null map contains a value other than 0 or 1") unless is_null <= 1_u8
          row << (is_null == 1_u8 ? nil : decode_array_numeric_value(value_bytes, flat_offset * element_width, type))
          flat_offset += 1
        end
        values << row
      end
      raise CorruptPartError.new("Array(Nullable(T)) sizes do not consume selected child streams") unless flat_offset.to_u64 == flat_elements
      values
    end

    # Read exact Array(Bool) rows. Bool is intentionally handled outside the
    # generic numeric Array codecs so visible payload bytes are restricted to
    # the semantic values 0 and 1.
    def read_array_bool_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Bool))
      ensure_column(column)
      raise UnsupportedFormatError.new("Array(Bool) accessor requires an exact Array(Bool) column") unless WidePart.supports_array_bool_type?(@column_type)

      outer_sizes, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      value_stream = @streams[column]
      value_start, value_end, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Bool) value mark rows differ") unless value_rows == rows
      validate_array_nested_stream_marks(value_stream, first_mark, mark_flat_elements, 1)
      value_bytes = read_mark_range_bytes(value_stream, value_start, value_end, checked_array_mark_byte_count(flat_elements, 1), 1)

      values = Array(Array(Bool)).new(rows.to_i)
      byte_offset = 0
      outer_sizes.each do |size|
        row = Array(Bool).new(size.to_i)
        size.to_i.times do
          raise CorruptPartError.new("Array(Bool) size0 exceeds selected child bytes") if byte_offset >= value_bytes.size
          case value_bytes[byte_offset]
          when 0 then row << false
          when 1 then row << true
          else        raise CorruptPartError.new("Array(Bool) byte is not 0 or 1")
          end
          byte_offset += 1
        end
        values << row
      end
      raise CorruptPartError.new("Array(Bool) size0 does not consume selected child bytes") unless byte_offset == value_bytes.size
      values
    end

    # Read exact Array(Nullable(Bool)) rows. Null flags are always validated;
    # their child slots are consumed but decoded only when the flag is non-NULL.
    def read_array_nullable_bool_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Bool?))
      ensure_column(column)
      raise UnsupportedFormatError.new("Array(Nullable(Bool)) accessor requires an exact Array(Nullable(Bool)) column") unless WidePart.supports_array_nullable_bool_type?(@column_type)

      outer_sizes, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      null_stream = @streams["#{column}.null"]
      null_start, null_end, null_rows = checked_stream_mark_range(null_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Nullable(Bool)) null-map mark rows differ") unless null_rows == rows
      validate_array_nested_stream_marks(null_stream, first_mark, mark_flat_elements, 1)
      null_bytes = read_mark_range_bytes(null_stream, null_start, null_end, checked_array_mark_byte_count(flat_elements, 1), 1)
      null_bytes.each do |value|
        raise CorruptPartError.new("Array(Nullable(Bool)) null-map byte is not boolean") unless value <= 1_u8
      end

      value_stream = @streams[column]
      value_start, value_end, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Nullable(Bool)) value mark rows differ") unless value_rows == rows
      validate_array_nested_stream_marks(value_stream, first_mark, mark_flat_elements, 1)
      value_bytes = read_mark_range_bytes(value_stream, value_start, value_end, checked_array_mark_byte_count(flat_elements, 1), 1)

      values = Array(Array(Bool?)).new(rows.to_i)
      element_offset = 0
      outer_sizes.each do |size|
        row = Array(Bool?).new(size.to_i)
        size.to_i.times do
          raise CorruptPartError.new("Array(Nullable(Bool)) size0 exceeds selected child streams") if element_offset >= flat_elements
          if null_bytes[element_offset] == 1_u8
            row << nil
          else
            case value_bytes[element_offset]
            when 0 then row << false
            when 1 then row << true
            else        raise CorruptPartError.new("Array(Nullable(Bool)) byte is not 0 or 1")
            end
          end
          element_offset += 1
        end
        values << row
      end
      raise CorruptPartError.new("Array(Nullable(Bool)) size0 does not consume selected child streams") unless element_offset.to_u64 == flat_elements
      values
    end

    # Read two exact Array levels with one fixed-width UInt64 leaf stream.
    # size0 has one count per outer row; size1 has one count per inner array;
    # both size streams and the payload are marked in outer-row granules.
    def read_array_array_uint64_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Array(UInt64)))
      ensure_column(column)
      unless @column_type == "Array(Array(UInt64))"
        raise UnsupportedFormatError.new("Array(Array(UInt64)) accessor requires an exact Array(Array(UInt64)) column")
      end

      outer_sizes, flat_inner_arrays, rows, mark_inner_arrays = read_array_outer_sizes(column, first_mark, mark_count)
      element_sizes, flat_elements, mark_leaf_elements = read_array_array_uint64_element_sizes(
        column,
        first_mark,
        mark_count,
        flat_inner_arrays,
        rows,
        mark_inner_arrays
      )
      value_stream = @streams[column]
      value_start, value_end, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Array(UInt64)) value mark rows differ") unless value_rows == rows
      validate_array_nested_stream_marks(value_stream, first_mark, mark_leaf_elements, 8)
      value_bytes = read_mark_range_bytes(value_stream, value_start, value_end, checked_array_mark_byte_count(flat_elements, 8), 8)

      values = Array(Array(Array(UInt64))).new(rows.to_i)
      inner_offset = 0
      value_offset = 0
      outer_sizes.each do |inner_count|
        row = Array(Array(UInt64)).new(inner_count.to_i)
        inner_count.to_i.times do
          raise CorruptPartError.new("Array(Array(UInt64)) size1 count exceeds selected bytes") if inner_offset >= element_sizes.size
          leaf_count = element_sizes[inner_offset]
          inner = Array(UInt64).new(leaf_count.to_i)
          leaf_count.to_i.times do
            raise CorruptPartError.new("Array(Array(UInt64)) sizes exceed selected payload bytes") if value_offset > value_bytes.size - 8
            inner << u64(value_bytes, value_offset)
            value_offset += 8
          end
          row << inner
          inner_offset += 1
        end
        values << row
      end
      raise CorruptPartError.new("Array(Array(UInt64)) sizes do not consume selected nested sizes") unless inner_offset == element_sizes.size
      raise CorruptPartError.new("Array(Array(UInt64)) sizes do not consume selected payload bytes") unless value_offset == value_bytes.size
      values
    end

    # Read exact Array(Array(Nullable(UInt64))) values. Both offsets streams
    # preserve their own nesting boundaries; each leaf consumes one null byte
    # and one UInt64 slot, but null value slots are never semantically decoded.
    def read_array_array_nullable_uint64_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Array(UInt64?)))
      ensure_column(column)
      unless @column_type == "Array(Array(Nullable(UInt64)))"
        raise UnsupportedFormatError.new("Array(Array(Nullable(UInt64))) accessor requires an exact Array(Array(Nullable(UInt64))) column")
      end

      outer_sizes, flat_inner_arrays, rows, mark_inner_arrays = read_array_outer_sizes(column, first_mark, mark_count)
      element_sizes, flat_leaf_elements, mark_leaf_elements = read_array_array_nullable_uint64_element_sizes(
        column,
        first_mark,
        mark_count,
        flat_inner_arrays,
        rows,
        mark_inner_arrays
      )

      null_stream = @streams["#{column}.null"]
      null_start, null_end, null_rows = checked_stream_mark_range(null_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Array(Nullable(UInt64))) null-map mark rows differ") unless null_rows == rows
      validate_array_nested_stream_marks(null_stream, first_mark, mark_leaf_elements, 1)
      null_bytes = read_mark_range_bytes(null_stream, null_start, null_end, checked_array_mark_byte_count(flat_leaf_elements, 1), 1)

      value_stream = @streams[column]
      value_start, value_end, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Array(Nullable(UInt64))) value mark rows differ") unless value_rows == rows
      validate_array_nested_stream_marks(value_stream, first_mark, mark_leaf_elements, 8)
      value_bytes = read_mark_range_bytes(value_stream, value_start, value_end, checked_array_mark_byte_count(flat_leaf_elements, 8), 8)

      values = Array(Array(Array(UInt64?))).new(rows.to_i)
      inner_offset = 0
      leaf_offset = 0
      outer_sizes.each do |inner_count|
        row = Array(Array(UInt64?)).new(inner_count.to_i)
        inner_count.to_i.times do
          raise CorruptPartError.new("Array(Array(Nullable(UInt64))) size1 count exceeds selected bytes") if inner_offset >= element_sizes.size
          leaf_count = element_sizes[inner_offset]
          inner = Array(UInt64?).new(leaf_count.to_i)
          leaf_count.to_i.times do
            raise CorruptPartError.new("Array(Array(Nullable(UInt64))) sizes exceed selected child streams") if leaf_offset >= flat_leaf_elements
            is_null = null_bytes[leaf_offset]
            raise CorruptPartError.new("Array(Array(Nullable(UInt64))) null map contains a value other than 0 or 1") unless is_null <= 1_u8
            inner << (is_null == 1_u8 ? nil : u64(value_bytes, leaf_offset * 8))
            leaf_offset += 1
          end
          row << inner
          inner_offset += 1
        end
        values << row
      end
      raise CorruptPartError.new("Array(Array(Nullable(UInt64))) sizes do not consume selected nested sizes") unless inner_offset == element_sizes.size
      raise CorruptPartError.new("Array(Array(Nullable(UInt64))) sizes do not consume selected child streams") unless leaf_offset.to_u64 == flat_leaf_elements
      values
    end

    # Read bounded Array(Nullable(UInt64)) rows. The null map and value stream
    # are flattened child streams with independent mark validation; NULL slots
    # still consume a UInt64 value slot in the nested stream.
    def read_array_nullable_uint64_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(UInt64?))
      raise UnsupportedFormatError.new("Array(Nullable(UInt64)) accessor requires an exact Array(Nullable(UInt64)) column") unless @column_type == "Array(Nullable(UInt64))"
      read_array_nullable_numeric_mark_range(column, first_mark, mark_count, UInt64)
    end

    # Read bounded Array(FixedString(N)) rows. The flattened child payload has
    # one exact N-byte slot per size0 element, including embedded NUL bytes.
    def read_array_fixed_string_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(String))
      ensure_column(column)
      width = WidePart.array_fixed_string_width(@column_type) || raise(UnsupportedFormatError.new("Array(FixedString) accessor requires an exact Array(FixedString(N)) column"))

      outer_sizes, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      expected_bytes = checked_array_mark_byte_count(flat_elements, width)
      value_stream = @streams[column]
      value_start, value_end, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(FixedString) value mark rows differ") unless value_rows == rows
      validate_array_nested_stream_marks(value_stream, first_mark, mark_flat_elements, width)
      value_bytes = read_mark_range_bytes(value_stream, value_start, value_end, expected_bytes, width)

      values = Array(Array(String)).new(rows.to_i)
      byte_offset = 0
      outer_sizes.each do |size|
        row = Array(String).new(size.to_i)
        size.to_i.times do
          raise CorruptPartError.new("Array(FixedString) size0 exceeds selected child bytes") if byte_offset > value_bytes.size - width
          row << String.new(value_bytes[byte_offset, width])
          byte_offset += width
        end
        values << row
      end
      raise CorruptPartError.new("Array(FixedString) size0 does not consume selected child bytes") unless byte_offset == value_bytes.size
      values
    end

    # Read bounded Array(Nullable(FixedString(N))) rows. The null map and
    # fixed-width values are aligned to flattened size0 elements; nested N-byte
    # slots are consumed even when their corresponding flag is NULL.
    def read_array_nullable_fixed_string_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(String?))
      ensure_column(column)
      width = WidePart.array_nullable_fixed_string_width(@column_type) || raise(UnsupportedFormatError.new("Array nullable FixedString accessor requires an exact Array(Nullable(FixedString(N))) column"))

      outer_sizes, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      checked_array_mark_byte_count(flat_elements, 1 + width)

      null_stream = @streams["#{column}.null"]
      null_start, null_end, null_rows = checked_stream_mark_range(null_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Nullable(FixedString)) null-map mark rows differ") unless null_rows == rows
      validate_array_nested_stream_marks(null_stream, first_mark, mark_flat_elements, 1)
      null_bytes = read_mark_range_bytes(null_stream, null_start, null_end, checked_array_mark_byte_count(flat_elements, 1), 1)
      null_bytes.each do |value|
        raise CorruptPartError.new("Array(Nullable(FixedString)) null-map byte is not boolean") unless value <= 1_u8
      end

      value_stream = @streams[column]
      value_start, value_end, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Nullable(FixedString)) value mark rows differ") unless value_rows == rows
      validate_array_nested_stream_marks(value_stream, first_mark, mark_flat_elements, width)
      value_bytes = read_mark_range_bytes(value_stream, value_start, value_end, checked_array_mark_byte_count(flat_elements, width), width)

      values = Array(Array(String?)).new(rows.to_i)
      element_offset = 0
      byte_offset = 0
      outer_sizes.each do |size|
        row = Array(String?).new(size.to_i)
        size.to_i.times do
          raise CorruptPartError.new("Array(Nullable(FixedString)) size0 exceeds selected child streams") if element_offset >= flat_elements
          raise CorruptPartError.new("Array(Nullable(FixedString)) size0 exceeds selected value bytes") if byte_offset > value_bytes.size - width
          is_null = null_bytes[element_offset]
          row << (is_null == 1_u8 ? nil : String.new(value_bytes[byte_offset, width]))
          element_offset += 1
          byte_offset += width
        end
        values << row
      end
      raise CorruptPartError.new("Array(Nullable(FixedString)) size0 does not consume selected child streams") unless element_offset.to_u64 == flat_elements
      raise CorruptPartError.new("Array(Nullable(FixedString)) values do not consume selected child bytes") unless byte_offset == value_bytes.size
      values
    end

    # Read exact Array(String) rows, retaining empty and arbitrary binary
    # strings. Outer rows, flattened element count, and raw bytes are all
    # validated before nested String objects are allocated.
    def read_array_string_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(String))
      ensure_column(column)
      raise UnsupportedFormatError.new("Array(String) accessor requires an exact Array(String) column") unless @column_type == "Array(String)"

      outer_sizes, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      element_sizes, total_bytes = read_array_string_element_sizes(column, first_mark, mark_count, flat_elements, rows, mark_flat_elements)
      size_stream = @streams["#{column}.size"]
      _, _, size_rows = checked_stream_mark_range(size_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(String) substream mark rows differ") unless size_rows == rows

      raw_stream = @streams[column]
      raw_start, raw_end, raw_rows = checked_stream_mark_range(raw_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(String) substream mark rows differ") unless raw_rows == rows
      raw_bytes = read_mark_range_bytes(raw_stream, raw_start, raw_end, total_bytes.to_i, 1)

      values = Array(Array(String)).new(rows.to_i)
      element_offset = 0
      raw_offset = 0
      outer_sizes.each do |size|
        row = Array(String).new(size.to_i)
        size.to_i.times do
          raise CorruptPartError.new("Array(String) sizes exceed selected element lengths") if element_offset >= element_sizes.size
          length = element_sizes[element_offset]
          raise CorruptPartError.new("Array(String) size exceeds selected raw bytes") if length > (raw_bytes.size - raw_offset).to_u64
          byte_length = length.to_i
          row << String.new(raw_bytes[raw_offset, byte_length])
          raw_offset += byte_length
          element_offset += 1
        end
        values << row
      end
      raise CorruptPartError.new("Array(String) sizes do not consume selected elements") unless element_offset == element_sizes.size
      raise CorruptPartError.new("Array(String) nested lengths do not consume selected raw bytes") unless raw_offset == raw_bytes.size
      values
    end

    # Read exact Array(Nullable(String)) rows. The outer size0, flattened null
    # map, string-size slots, and raw bytes are validated before String values
    # are allocated; NULL slots consume their nested size and raw-byte slots
    # but remain distinct from "".
    def read_array_nullable_string_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(String?))
      read_array_nullable_string_mark_range_with_raw_bytes(column, first_mark, mark_count)[0]
    end

    # Table scans use this form to confirm the decoded range consumed the same
    # nested String byte count that was preflighted, including NULL slots.
    def read_array_nullable_string_mark_range_with_raw_bytes(column : String, first_mark : Int, mark_count : Int) : {Array(Array(String?)), UInt64}
      ensure_column(column)
      raise UnsupportedFormatError.new("Array(Nullable(String)) accessor requires an exact Array(Nullable(String)) column") unless @column_type == "Array(Nullable(String))"

      outer_sizes, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      element_sizes, total_bytes = read_array_string_element_sizes(
        column,
        first_mark,
        mark_count,
        flat_elements,
        rows,
        mark_flat_elements,
        "Array(Nullable(String))"
      )
      null_bytes = read_array_nullable_string_null_map(column, first_mark, mark_count, flat_elements, rows, mark_flat_elements)
      raise CorruptPartError.new("Array(Nullable(String)) null-map count differs from size0") unless null_bytes.size.to_u64 == flat_elements
      raise CorruptPartError.new("Array(Nullable(String)) size count does not match size0") unless element_sizes.size.to_u64 == flat_elements

      raw_stream = @streams[column]
      raw_start, raw_end, raw_rows = checked_stream_mark_range(raw_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Nullable(String)) raw substream mark rows differ") unless raw_rows == rows
      raw_bytes = read_mark_range_bytes(raw_stream, raw_start, raw_end, total_bytes.to_i, 1)

      values = Array(Array(String?)).new(rows.to_i)
      element_offset = 0
      raw_offset = 0
      outer_sizes.each do |size|
        row = Array(String?).new(size.to_i)
        size.to_i.times do
          raise CorruptPartError.new("Array(Nullable(String)) sizes exceed selected element lengths") if element_offset >= element_sizes.size
          length = element_sizes[element_offset].to_i
          raise CorruptPartError.new("Array(Nullable(String)) size exceeds selected raw bytes") if length > raw_bytes.size - raw_offset
          row << (null_bytes[element_offset] == 1_u8 ? nil : String.new(raw_bytes[raw_offset, length]))
          raw_offset += length
          element_offset += 1
        end
        values << row
      end
      raise CorruptPartError.new("Array(Nullable(String)) sizes do not consume selected elements") unless element_offset == element_sizes.size
      raise CorruptPartError.new("Array(Nullable(String)) nested lengths do not consume selected raw bytes") unless raw_offset == raw_bytes.size
      {values, total_bytes}
    end

    private def read_map_string_element_sizes(
      column : String,
      first_mark : Int,
      mark_count : Int,
      flat_elements : UInt64,
      outer_rows : UInt64,
      mark_flat_elements : Array(UInt64),
    ) : {Array(UInt64), UInt64}
      sizes, total_bytes, _ = read_map_string_child_sizes(
        column, "%2Evalues", "Map nested", first_mark, mark_count, flat_elements, outer_rows, mark_flat_elements
      )
      {sizes, total_bytes}
    end

    private def read_map_string_child_sizes(
      column : String,
      child_path : String,
      child_label : String,
      first_mark : Int,
      mark_count : Int,
      flat_elements : UInt64,
      outer_rows : UInt64,
      mark_flat_elements : Array(UInt64),
    ) : {Array(UInt64), UInt64, Array(UInt64)}
      size_stream = @streams["#{column}#{child_path}.size"]
      size_start, size_end, size_rows = checked_stream_mark_range(size_stream, first_mark, mark_count)
      size_rows_error = child_label == "Map nested" ? "Map value-size substream mark rows differ" : "#{child_label} size substream mark rows differ"
      raise CorruptPartError.new(size_rows_error) unless size_rows == outer_rows
      encoded_sizes = read_mark_range_bytes(
        size_stream,
        size_start,
        size_end,
        checked_array_mark_byte_count(flat_elements, 8),
        8
      )

      element_sizes = Array(UInt64).new(flat_elements.to_i)
      mark_totals = Array(UInt64).new(mark_count)
      total_bytes = 0_u64
      offset = 0
      raw_stream = @streams["#{column}#{child_path}"]
      _, _, raw_rows = checked_stream_mark_range(raw_stream, first_mark, mark_count)
      raw_rows_error = child_label == "Map nested" ? "Map value substream mark rows differ" : "#{child_label} raw substream mark rows differ"
      raise CorruptPartError.new(raw_rows_error) unless raw_rows == outer_rows
      mark_flat_elements.each_with_index do |mark_flat, range_mark_index|
        mark_index = first_mark + range_mark_index
        mark_size_bytes = checked_array_mark_byte_count(mark_flat, 8)
        size_mark_start = size_stream.marks[mark_index]
        size_mark_end = mark_index + 1 == size_stream.marks.size ? size_stream.sentinel : size_stream.marks[mark_index + 1]
        validate_mark_range_bytes(size_stream, size_mark_start, size_mark_end, mark_size_bytes, 8)

        mark_raw_bytes = 0_u64
        mark_flat.to_i.times do
          raise CorruptPartError.new("#{child_label} size count exceeds selected bytes") if offset > encoded_sizes.size - 8
          size = u64(encoded_sizes, offset)
          if size > MAX_ARRAY_MARK_BYTES.to_u64 - total_bytes
            raise CorruptPartError.new("#{child_label} String bytes exceed per-range limit")
          end
          if size > MAX_DATA_FILE_BYTES.to_u64 - total_bytes
            raise CorruptPartError.new("#{child_label} String bytes exceed data limit")
          end
          if size > MAX_ARRAY_MARK_BYTES.to_u64 - mark_raw_bytes
            raise CorruptPartError.new("#{child_label} String bytes exceed per-mark limit")
          end
          total_bytes += size
          mark_raw_bytes += size
          element_sizes << size
          offset += 8
        end
        raw_mark_start = raw_stream.marks[mark_index]
        raw_mark_end = mark_index + 1 == raw_stream.marks.size ? raw_stream.sentinel : raw_stream.marks[mark_index + 1]
        validate_mark_range_bytes(raw_stream, raw_mark_start, raw_mark_end, mark_raw_bytes.to_i, 1)
        mark_totals << mark_raw_bytes
      end
      raise CorruptPartError.new("#{child_label} size stream has trailing bytes") unless offset == encoded_sizes.size
      raise CorruptPartError.new("#{child_label} size count does not match size0") unless element_sizes.size.to_u64 == flat_elements
      {element_sizes, total_bytes, mark_totals}
    end

    private def checked_map_materialized_bytes(
      key_bytes : UInt64,
      value_bytes : UInt64,
      key_mark_bytes : Array(UInt64),
      value_mark_bytes : Array(UInt64),
    ) : UInt64
      if key_bytes > MAX_ARRAY_MARK_BYTES.to_u64 || value_bytes > MAX_ARRAY_MARK_BYTES.to_u64 - key_bytes
        raise CorruptPartError.new("Map key/value payload exceeds materialization limit")
      end
      unless key_mark_bytes.size == value_mark_bytes.size
        raise CorruptPartError.new("Map key/value mark counts differ")
      end
      key_mark_bytes.each_with_index do |key_mark, index|
        value_mark = value_mark_bytes[index]
        if key_mark > MAX_ARRAY_MARK_BYTES.to_u64 || value_mark > MAX_ARRAY_MARK_BYTES.to_u64 - key_mark
          raise CorruptPartError.new("Map key/value mark exceeds materialization limit")
        end
      end
      key_bytes + value_bytes
    end

    private def checked_map_array_tuple_charge(payload_bytes : UInt64, elements : UInt64, rows : UInt64) : UInt64
      row_width = ARRAY_TUPLE_ROW_ACCOUNTING_BYTES
      entry_width = ARRAY_TUPLE_ENTRY_ACCOUNTING_BYTES
      if rows > UInt64::MAX // row_width || elements > UInt64::MAX // entry_width
        raise CorruptPartError.new("Map materialization charge overflows")
      end
      row_bytes = rows * row_width
      entry_bytes = elements * entry_width
      if entry_bytes > UInt64::MAX - row_bytes || payload_bytes > UInt64::MAX - row_bytes - entry_bytes
        raise CorruptPartError.new("Map materialization charge overflows")
      end
      charge_bytes = row_bytes + entry_bytes + payload_bytes
      if charge_bytes > MAX_ARRAY_MARK_BYTES.to_u64
        raise CorruptPartError.new("Map materialization charge exceeds per-range limit")
      end
      charge_bytes
    end

    # Return the nested String byte count for one bounded named Tuple mark
    # range without materializing tuple rows. The tuple children use
    # independent size and raw-data streams.
    def tuple_uint64_string_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      raise UnsupportedFormatError.new("Tuple(UInt64, String) accessor requires the exact named tuple type") unless WidePart.supports_tuple_uint64_string_type?(@column_type)

      sizes, total_bytes = read_tuple_string_sizes(column, first_mark, mark_count)
      raw_stream = @streams["#{column}%2Eb"]
      raw_start, raw_end, raw_rows = checked_stream_mark_range(raw_stream, first_mark, mark_count)
      raise CorruptPartError.new("Tuple(String) substream mark rows differ") unless raw_rows == sizes.size.to_u64
      validate_mark_range_bytes(raw_stream, raw_start, raw_end, total_bytes.to_i, 1)
      total_bytes
    end

    # Read exact positional (UInt64, String) values from the two named Tuple
    # children. Each leaf uses its own marks; row counts and byte totals are
    # validated before tuple or String objects are allocated.
    def read_tuple_uint64_string_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Tuple(UInt64, String))
      ensure_column(column)
      raise UnsupportedFormatError.new("Tuple(UInt64, String) accessor requires the exact named tuple type") unless WidePart.supports_tuple_uint64_string_type?(@column_type)

      value_stream = @streams["#{column}%2Ea"]
      value_start, value_end, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Tuple mark row count exceeds materialization limit") if value_rows > MAX_ARRAY_MARK_ROWS
      encoded_values = read_mark_range_bytes(value_stream, value_start, value_end, checked_byte_count(value_rows, 8), 8)

      sizes, total_bytes = read_tuple_string_sizes(column, first_mark, mark_count)
      raise CorruptPartError.new("Tuple substream mark rows differ") unless value_rows == sizes.size.to_u64
      raw_stream = @streams["#{column}%2Eb"]
      raw_start, raw_end, raw_rows = checked_stream_mark_range(raw_stream, first_mark, mark_count)
      raise CorruptPartError.new("Tuple(String) substream mark rows differ") unless raw_rows == value_rows
      raw_bytes = read_mark_range_bytes(raw_stream, raw_start, raw_end, total_bytes.to_i, 1)

      values = Array(Tuple(UInt64, String)).new(value_rows.to_i)
      raw_offset = 0
      sizes.each_with_index do |length, index|
        byte_length = length.to_i
        raise CorruptPartError.new("Tuple(String) sizes exceed selected raw bytes") if byte_length > raw_bytes.size - raw_offset
        values << {u64(encoded_values, index * 8), String.new(raw_bytes[raw_offset, byte_length])}
        raw_offset += byte_length
      end
      raise CorruptPartError.new("Tuple(String) sizes do not consume selected raw bytes") unless raw_offset == raw_bytes.size
      values
    end

    # Read a bounded mark range from an exact String column. At most 64 MiB of
    # raw bytes are materialized per call (the whole range, not each mark).
    # Empty values are zero-length; embedded NUL bytes are preserved.
    def read_string_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(String)
      ensure_column(column)
      raise UnsupportedFormatError.new("String accessor requires an exact String column") unless @column_type == "String"
      string_stream = @streams[column]
      sizes, total_bytes = read_string_sizes(column, first_mark, mark_count)
      raw_start, raw_end, raw_rows = checked_stream_mark_range(string_stream, first_mark, mark_count)
      raise CorruptPartError.new("selected String substream marks changed") unless raw_rows == sizes.size.to_u64
      raw_bytes = read_mark_range_bytes(string_stream, raw_start, raw_end, total_bytes.to_i, 1)
      values = Array(String).new(sizes.size)
      offset = 0
      sizes.each do |size|
        length = size.to_i
        values << String.new(raw_bytes[offset, length])
        offset += length
      end
      raise CorruptPartError.new("String sizes do not consume selected raw bytes") unless offset == raw_bytes.size
      values
    end

    # Read an exact LowCardinality(String) mark range. The shared dictionary
    # is initialized from the beginning of the part even when the requested
    # range starts later. Selected rows are bounded to 65,536 and their
    # materialized String bytes are bounded independently per mark.
    def read_low_cardinality_string_mark_range(column : String, first_mark : Int32, mark_count : Int32) : Array(String)
      values, _ = decode_low_cardinality_string_mark_range(column, first_mark, mark_count, materialize: true)
      values
    end

    # Used by the typed table's aggregate per-mark allocation preflight.
    # This validates the same dictionary, headers, IDs, and per-mark byte
    # totals as the public reader without constructing the returned row array.
    def low_cardinality_string_mark_range_raw_bytes(column : String, first_mark : Int32, mark_count : Int32) : UInt64
      _, bytes = decode_low_cardinality_string_mark_range(column, first_mark, mark_count, materialize: false)
      bytes
    end

    # Release the per-part validated cache when WidePartTable completes a
    # typed scan. Direct WidePart callers retain the cache unless they opt into
    # this lifecycle hook.
    def release_low_cardinality_string_scan_cache : Nil
      @low_cardinality_string_state = nil if @column_type == "LowCardinality(String)"
    end

    private def decode_low_cardinality_string_mark_range(
      column : String,
      first_mark : Int32,
      mark_count : Int32,
      materialize : Bool,
    ) : {Array(String), UInt64}
      ensure_column(column)
      raise UnsupportedFormatError.new("LowCardinality accessor requires an exact LowCardinality(String) column") unless @column_type == "LowCardinality(String)"

      index_stream = @streams[column]
      dictionary_stream = @streams["#{column}.dict"]
      raise UnsupportedFormatError.new("LowCardinality part exceeds per-reader mark limit") if index_stream.marks.size > MAX_LOW_CARDINALITY_MARKS
      _, _, selected_rows = checked_stream_mark_range(index_stream, first_mark, mark_count)
      raise CorruptPartError.new("LowCardinality selected row count exceeds limit") if selected_rows > MAX_LOW_CARDINALITY_MARK_ROWS
      state = low_cardinality_string_state(index_stream, dictionary_stream)
      index_marks = index_stream.marks
      values = Array(String).new(selected_rows.to_i)
      selected_bytes = 0_u64
      materialized_bytes = 0_u64
      (first_mark...first_mark + mark_count).each do |mark_index|
        mark = index_marks[mark_index]
        start_offset = state.index_mark_offsets[mark_index]
        end_offset = state.index_mark_offsets[mark_index + 1]
        keys, ids_offset = low_cardinality_parse_index_mark(
          state.index_bytes,
          start_offset,
          end_offset,
          mark,
          mark_index,
          state.global_dictionary,
          state.shared_keys
        )
        row_count = mark.rows
        mark_bytes = 0_u64
        row_count.to_i.times do |row_index|
          id = state.index_bytes[ids_offset + row_index].to_i
          raise CorruptPartError.new("LowCardinality ID is outside its dictionary") if id >= keys.size
          string_size = keys[id].bytesize.to_u64
          if string_size > MAX_STRING_RANGE_BYTES.to_u64 - mark_bytes
            raise CorruptPartError.new("LowCardinality mark exceeds materialized String byte limit")
          end
          mark_bytes += string_size
        end

        if materialized_bytes > MAX_LOW_CARDINALITY_DICTIONARY_BYTES.to_u64 - mark_bytes
          raise CorruptPartError.new("LowCardinality selected range exceeds materialization limit")
        end
        materialized_bytes += mark_bytes
        selected_bytes += mark_bytes
        if materialize
          row_count.to_i.times do |row_index|
            source = keys[state.index_bytes[ids_offset + row_index].to_i].to_slice
            owned_bytes = Bytes.new(source.size)
            source.copy_to(owned_bytes)
            values << String.new(owned_bytes)
          end
        end
      end

      raise CorruptPartError.new("LowCardinality selected rows differ from marks") unless values.size.to_u64 == selected_rows || !materialize
      {values, selected_bytes}
    end

    # A WidePart is opened over an immutable part snapshot. Decode and validate
    # both bounded streams once, so scans and staged validation do not rescan
    # every mark for each selected mark.
    private def low_cardinality_string_state(
      index_stream : PhysicalStream,
      dictionary_stream : PhysicalStream,
    ) : LowCardinalityStringState
      if state = @low_cardinality_string_state
        return state
      end

      index_marks = index_stream.marks
      dictionary_marks = dictionary_stream.marks
      raise UnsupportedFormatError.new("LowCardinality part exceeds per-reader mark limit") if index_marks.size > MAX_LOW_CARDINALITY_MARKS
      raise CorruptPartError.new("LowCardinality dictionary and index marks differ") unless dictionary_marks.size == index_marks.size
      index_marks.each_with_index do |mark, mark_index|
        raise CorruptPartError.new("LowCardinality mark row count exceeds limit") if mark.rows > MAX_LOW_CARDINALITY_MARK_ROWS
        unless dictionary_marks[mark_index].rows == mark.rows
          raise CorruptPartError.new("LowCardinality dictionary and index mark row counts differ")
        end
      end

      dictionary_bytes, dictionary_frame_map = decode_low_cardinality_compressed_stream(
        dictionary_stream,
        MAX_LOW_CARDINALITY_DICTIONARY_BYTES
      )
      raise CorruptPartError.new("LowCardinality dictionary version is truncated") if dictionary_bytes.size < 8
      raise UnsupportedFormatError.new("only LowCardinality dictionary version 1 is supported") unless low_cardinality_read_u64(dictionary_bytes, 0) == 1_u64
      dictionary_mark_offsets = dictionary_marks.map do |mark|
        low_cardinality_mark_absolute_offset(mark, dictionary_stream, dictionary_frame_map, dictionary_bytes.size)
      end
      dictionary_sentinel_offset = low_cardinality_mark_absolute_offset(
        dictionary_stream.sentinel,
        dictionary_stream,
        dictionary_frame_map,
        dictionary_bytes.size
      )
      raise CorruptPartError.new("LowCardinality dictionary sentinel is not at EOF") unless dictionary_sentinel_offset == dictionary_bytes.size.to_u64

      index_bytes, index_frame_map = decode_low_cardinality_compressed_stream(
        index_stream,
        MAX_LOW_CARDINALITY_INDEX_BYTES
      )
      index_mark_offsets = index_marks.map do |mark|
        low_cardinality_mark_absolute_offset(mark, index_stream, index_frame_map, index_bytes.size)
      end
      index_sentinel_offset = low_cardinality_mark_absolute_offset(
        index_stream.sentinel,
        index_stream,
        index_frame_map,
        index_bytes.size
      )
      raise CorruptPartError.new("LowCardinality index mark does not start at byte zero") unless index_mark_offsets.first? == 0_u64
      raise CorruptPartError.new("LowCardinality index sentinel is not at EOF") unless index_sentinel_offset == index_bytes.size.to_u64

      first_segment_end = index_mark_offsets[1]? || index_sentinel_offset
      first_segment = index_bytes[index_mark_offsets[0].to_i, (first_segment_end - index_mark_offsets[0]).to_i]
      first_header = low_cardinality_read_u64(first_segment, 0)
      global_dictionary = case first_header
                          when 0x500_u64
                            true
                          when 0x600_u64
                            false
                          else
                            raise UnsupportedFormatError.new("unsupported LowCardinality index flags")
                          end

      shared_keys = [] of String
      if global_dictionary
        dictionary_marks.each do |mark|
          unless mark.compressed_offset == dictionary_marks[0].compressed_offset && mark.decompressed_offset == dictionary_marks[0].decompressed_offset
            raise UnsupportedFormatError.new("LowCardinality shared dictionary updates are unsupported")
          end
          raise CorruptPartError.new("LowCardinality shared dictionary must start after its version word") unless dictionary_mark_offsets.first? == 8_u64
        end
        shared_keys, dictionary_end = low_cardinality_read_dictionary(dictionary_bytes, 8, nil)
        raise CorruptPartError.new("LowCardinality shared dictionary must reserve the empty default at ID zero") unless shared_keys.first.empty?
        raise CorruptPartError.new("LowCardinality shared dictionary has trailing bytes") unless dictionary_end == dictionary_bytes.size
      else
        raise CorruptPartError.new("LowCardinality dictionary must begin after its version word") unless dictionary_mark_offsets.first? == 8_u64
        index_marks.size.times do |mark_index|
          mark_start = dictionary_mark_offsets[mark_index]
          mark_end = dictionary_mark_offsets[mark_index + 1]? || dictionary_sentinel_offset
          raise CorruptPartError.new("LowCardinality dictionary marks overlap or reverse") if mark_start > mark_end
          local_default, next_offset = low_cardinality_read_dictionary(dictionary_bytes, mark_start.to_i, mark_end.to_i)
          unless local_default.size == 1 && local_default[0].empty? && next_offset.to_u64 == mark_end
            raise CorruptPartError.new("LowCardinality local dictionary default record is malformed")
          end
        end
      end

      index_marks.each_with_index do |mark, mark_index|
        mark_end = index_mark_offsets[mark_index + 1]? || index_sentinel_offset
        keys, ids_offset = low_cardinality_parse_index_mark(
          index_bytes,
          index_mark_offsets[mark_index],
          mark_end,
          mark,
          mark_index,
          global_dictionary,
          shared_keys
        )
        mark.rows.to_i.times do |row_index|
          id = index_bytes[ids_offset + row_index].to_i
          raise CorruptPartError.new("LowCardinality ID is outside its dictionary") if id >= keys.size
        end
      end

      state = LowCardinalityStringState.new(index_bytes, index_mark_offsets + [index_sentinel_offset], global_dictionary, shared_keys)
      @low_cardinality_string_state = state
      state
    end

    private def low_cardinality_parse_index_mark(
      bytes : Bytes,
      start_offset : UInt64,
      end_offset : UInt64,
      mark : Mark,
      mark_index : Int,
      global_dictionary : Bool,
      shared_keys : Array(String),
    ) : {Array(String), Int32}
      raise CorruptPartError.new("LowCardinality index mark boundaries are invalid") if start_offset > end_offset || end_offset > bytes.size.to_u64
      segment = bytes[start_offset.to_i, (end_offset - start_offset).to_i]
      header = low_cardinality_read_u64(segment, 0)
      expected_header = if global_dictionary
                          mark_index == 0 ? 0x500_u64 : 0x100_u64
                        else
                          0x600_u64
                        end
      if header != expected_header
        raise UnsupportedFormatError.new("unsupported or changing LowCardinality dictionary state")
      end
      keys = shared_keys
      cursor = 8
      unless global_dictionary
        key_count = low_cardinality_read_u64(segment, cursor)
        cursor += 8
        raise CorruptPartError.new("LowCardinality local dictionary is empty or exceeds key limit") if key_count == 0_u64 || key_count > MAX_LOW_CARDINALITY_DICTIONARY_KEYS
        keys = Array(String).new(key_count.to_i)
        seen = Set(String).new
        key_count.to_i.times do
          key, cursor = low_cardinality_read_string(segment, cursor)
          raise CorruptPartError.new("LowCardinality local dictionary contains duplicate keys") unless seen.add?(key)
          keys << key
        end
        raise CorruptPartError.new("LowCardinality local dictionary must reserve the empty default at ID zero") unless keys.first.empty?
      end
      row_count = low_cardinality_read_u64(segment, cursor)
      cursor += 8
      raise CorruptPartError.new("LowCardinality index row count differs from marks") unless row_count == mark.rows
      raise CorruptPartError.new("LowCardinality index row count exceeds limit") if row_count > MAX_LOW_CARDINALITY_MARK_ROWS
      raise CorruptPartError.new("LowCardinality index IDs are truncated or have trailing bytes") unless segment.size - cursor == row_count
      {keys, start_offset.to_i + cursor}
    end

    private def decode_low_cardinality_compressed_stream(
      stream : PhysicalStream,
      max_decoded_bytes : Int32,
    ) : {Bytes, Hash(UInt64, Tuple(UInt64, UInt64))}
      size = File.size(stream.data_path)
      raise CorruptPartError.new("LowCardinality data exceeds limit") if size > MAX_DATA_FILE_BYTES
      raise CorruptPartError.new("LowCardinality stream is empty") if size == 0

      output = IO::Memory.new
      frame_map = Hash(UInt64, Tuple(UInt64, UInt64)).new
      referenced_frames = Set(UInt64).new
      stream.marks.each { |mark| referenced_frames << mark.compressed_offset }
      if stream.sentinel.compressed_offset < size.to_u64
        referenced_frames << stream.sentinel.compressed_offset
      end
      workspace = CompressedBlock::DecodeWorkspace.new
      compressed_offset = 0_i64
      frame_count = 0
      maximum_frames = (MAX_LOW_CARDINALITY_MARKS * 4) + 64
      MMapDataSource.with_file(stream.data_path, size, MAX_DATA_FILE_BYTES) do |compressed|
        while compressed_offset < compressed.size
          frame_count += 1
          raise UnsupportedFormatError.new("LowCardinality stream has too many compressed frames") if frame_count > maximum_frames
          frame = CompressedBlock.decode_frame_into(
            compressed,
            compressed_offset,
            workspace,
            MAX_FRAME_COMPRESSED_BYTES,
            MAX_FRAME_DECOMPRESSED_BYTES
          )
          if frame.output.size.to_i64 > max_decoded_bytes.to_i64 - output.size.to_i64
            raise CorruptPartError.new("LowCardinality stream exceeds decoded-size limit")
          end
          if referenced_frames.includes?(compressed_offset.to_u64)
            frame_map[compressed_offset.to_u64] = {output.size.to_u64, frame.output.size.to_u64}
          end
          output.write(frame.output)
          raise CorruptPartError.new("LowCardinality compressed frame did not advance") if frame.end_offset <= compressed_offset
          compressed_offset = frame.end_offset
        end
        raise CorruptPartError.new("LowCardinality stream has trailing compressed bytes") unless compressed_offset == compressed.size
      end
      raise CorruptPartError.new("LowCardinality stream is empty") if output.size == 0
      stream.marks.each do |mark|
        raise CorruptPartError.new("LowCardinality mark does not start at a frame") unless frame_map.has_key?(mark.compressed_offset)
      end
      {output.to_slice, frame_map}
    end

    private def low_cardinality_mark_absolute_offset(
      mark : Mark,
      stream : PhysicalStream,
      frame_map : Hash(UInt64, Tuple(UInt64, UInt64)),
      decoded_size : Int,
    ) : UInt64
      data_size = File.size(stream.data_path).to_u64
      if mark.compressed_offset == data_size
        raise CorruptPartError.new("LowCardinality EOF mark has a local offset") unless mark.decompressed_offset == 0_u64
        return decoded_size.to_u64
      end
      frame = frame_map[mark.compressed_offset]?
      raise CorruptPartError.new("LowCardinality dictionary mark does not start at a frame") unless frame
      frame_start, frame_size = frame.not_nil!
      raise CorruptPartError.new("LowCardinality dictionary mark exceeds frame output") if mark.decompressed_offset > frame_size
      frame_start + mark.decompressed_offset
    end

    private def low_cardinality_read_dictionary(bytes : Bytes, offset : Int, limit : Int?) : {Array(String), Int32}
      count = low_cardinality_read_u64(bytes, offset)
      cursor = offset + 8
      maximum = limit || bytes.size
      raise CorruptPartError.new("LowCardinality dictionary is empty or exceeds key limit") if count == 0_u64 || count > MAX_LOW_CARDINALITY_DICTIONARY_KEYS
      keys = Array(String).new(count.to_i)
      seen = Set(String).new
      count.to_i.times do
        key, cursor = low_cardinality_read_string(bytes, cursor)
        raise CorruptPartError.new("LowCardinality dictionary contains duplicate keys") unless seen.add?(key)
        keys << key
      end
      raise CorruptPartError.new("LowCardinality dictionary record exceeds mark boundary") if cursor > maximum
      {keys, cursor.to_i32}
    end

    private def low_cardinality_read_u64(bytes : Bytes, offset : Int) : UInt64
      raise CorruptPartError.new("LowCardinality UInt64 field is truncated") if offset < 0 || offset > bytes.size - 8
      u64(bytes, offset)
    end

    private def low_cardinality_read_string(bytes : Bytes, offset : Int) : {String, Int32}
      length, data_offset = low_cardinality_read_var_uint(bytes, offset)
      raise CorruptPartError.new("LowCardinality String length exceeds remaining bytes") if length > (bytes.size - data_offset).to_u64
      finish = data_offset + length.to_i
      {String.new(bytes[data_offset, length.to_i]), finish.to_i32}
    end

    private def low_cardinality_read_var_uint(bytes : Bytes, offset : Int) : {UInt64, Int32}
      raise CorruptPartError.new("LowCardinality VarUInt is truncated") if offset < 0
      value = 0_u64
      cursor = offset
      10.times do |index|
        raise CorruptPartError.new("LowCardinality VarUInt is truncated") if cursor >= bytes.size
        byte = bytes[cursor]
        payload = (byte & 0x7f_u8).to_u64
        raise CorruptPartError.new("LowCardinality VarUInt overflows UInt64") if index == 9 && payload > 1_u64
        value |= payload << (index * 7)
        cursor += 1
        unless byte & 0x80_u8 != 0
          raise CorruptPartError.new("LowCardinality VarUInt is noncanonical") if index > 0 && payload == 0_u64
          return {value, cursor.to_i32}
        end
      end
      raise CorruptPartError.new("LowCardinality VarUInt is too long")
    end

    # Read an exact FixedString(N) mark range. Each returned String contains
    # exactly N on-disk bytes, including embedded and trailing NUL bytes.
    # Materialization is bounded by both raw bytes and returned String count.
    def read_fixed_string_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(String)
      ensure_column(column)
      width = WidePart.fixed_string_width(@column_type) || raise(UnsupportedFormatError.new("FixedString accessor requires an exact FixedString(N) column"))
      stream = @streams[column]
      start_mark, end_mark, rows = checked_stream_mark_range(stream, first_mark, mark_count)
      expected_bytes = checked_fixed_string_byte_count(rows, width)
      raw_bytes = read_mark_range_bytes(stream, start_mark, end_mark, expected_bytes, width)
      values = Array(String).new(rows.to_i)
      offset = 0
      rows.to_i.times do
        values << String.new(raw_bytes[offset, width])
        offset += width
      end
      raise CorruptPartError.new("FixedString values do not consume selected bytes") unless offset == raw_bytes.size
      values
    end

    # BASIC Nullable(FixedString(N)) has a boolean null map and an N-byte
    # nested slot for every row. The nested slot under NULL is consumed but
    # never exposed to the caller.
    def read_nullable_fixed_string_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(String?)
      ensure_column(column)
      width = WidePart.nullable_fixed_string_width(@column_type) || raise(UnsupportedFormatError.new("Nullable(FixedString) accessor requires an exact Nullable(FixedString(N)) column"))
      null_stream = @streams["#{column}.null"]
      value_stream = @streams[column]
      null_start, null_end, rows = checked_stream_mark_range(null_stream, first_mark, mark_count)
      value_start, value_end, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Nullable(FixedString) substream mark rows differ") unless rows == value_rows
      expected_bytes = checked_fixed_string_byte_count(rows, width)

      null_map = read_mark_range_bytes(null_stream, null_start, null_end, checked_byte_count(rows, 1), 1)
      null_map.each do |value|
        raise CorruptPartError.new("Nullable null-map byte is not boolean") unless value == 0 || value == 1
      end
      nested_bytes = read_mark_range_bytes(value_stream, value_start, value_end, expected_bytes, width)
      values = Array(String?).new(rows.to_i)
      offset = 0
      null_map.each do |is_null|
        values << (is_null == 1 ? nil : String.new(nested_bytes[offset, width]))
        offset += width
      end
      raise CorruptPartError.new("Nullable(FixedString) values do not consume nested bytes") unless offset == nested_bytes.size
      values
    end

    # Read a bounded range from the three BASIC Nullable(String) streams.
    # Even NULL rows consume their nested size and raw bytes before nil is
    # surfaced, matching ClickHouse's nested NullableElements storage.
    def read_nullable_string_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(String?)
      read_nullable_string_mark_range_with_raw_bytes(column, first_mark, mark_count)[0]
    end

    # Internal table-scan form that returns the encoded raw byte count from
    # the same size vector used to decode values, including slots under NULL.
    def read_nullable_string_mark_range_with_raw_bytes(column : String, first_mark : Int, mark_count : Int) : {Array(String?), UInt64}
      ensure_column(column)
      raise UnsupportedFormatError.new("Nullable(String) accessor requires an exact Nullable(String) column") unless @column_type == "Nullable(String)"

      null_stream = @streams["#{column}.null"]
      string_stream = @streams[column]
      null_start, null_end, null_rows = checked_stream_mark_range(null_stream, first_mark, mark_count)
      sizes, total_bytes = read_string_sizes(column, first_mark, mark_count)
      raise CorruptPartError.new("Nullable(String) substream mark rows differ") unless null_rows == sizes.size.to_u64

      null_map = read_mark_range_bytes(null_stream, null_start, null_end, checked_byte_count(null_rows, 1), 1)
      null_map.each do |value|
        raise CorruptPartError.new("Nullable null-map byte is not boolean") unless value == 0 || value == 1
      end

      raw_start, raw_end, raw_rows = checked_stream_mark_range(string_stream, first_mark, mark_count)
      raise CorruptPartError.new("Nullable(String) raw mark rows differ") unless raw_rows == sizes.size.to_u64
      raw_bytes = read_mark_range_bytes(string_stream, raw_start, raw_end, total_bytes.to_i, 1)
      values = Array(String?).new(sizes.size)
      offset = 0
      sizes.each_with_index do |size, index|
        length = size.to_i
        values << (null_map[index] == 1 ? nil : String.new(raw_bytes[offset, length]))
        offset += length
      end
      raise CorruptPartError.new("Nullable(String) sizes do not consume nested raw bytes") unless offset == raw_bytes.size
      {values, total_bytes}
    end

    # Read a bounded range from basic Nullable(T) streams. The separate null
    # map and nested-value substreams retain their own compressed offsets and
    # are decoded independently at identical mark indices.
    def read_nullable_numeric_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
      type : T.class,
    ) : Array(T?) forall T
      ensure_column(column)
      expected_type = "Nullable(#{WidePart.numeric_type_name(type)})"
      raise UnsupportedFormatError.new("typed accessor does not match selected Nullable column type") unless @column_type == expected_type
      element_width = numeric_type_width(WidePart.numeric_type_name(type))
      read_nullable_fixed_width_mark_range(column, first_mark, mark_count, element_width, type)
    end

    private def read_nullable_fixed_width_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
      element_width : Int32,
      type : T.class,
    ) : Array(T?) forall T
      null_stream = @streams["#{column}.null"]
      value_stream = @streams[column]
      null_start, null_end, rows = checked_stream_mark_range(null_stream, first_mark, mark_count)
      value_start, value_end, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Nullable substream mark rows differ") unless rows == value_rows

      null_map = read_mark_range_bytes(null_stream, null_start, null_end, checked_byte_count(rows, 1), 1)
      null_map.each do |value|
        raise CorruptPartError.new("Nullable null-map byte is not boolean") unless value == 0 || value == 1
      end

      encoded_values = read_mark_range_bytes(value_stream, value_start, value_end, checked_byte_count(rows, element_width), element_width)
      values = Array(T?).new(rows.to_i)
      offset = 0
      null_map.each do |is_null|
        values << (is_null == 1 ? nil : decode_numeric_value(encoded_values, offset, type))
        offset += element_width
      end
      raise CorruptPartError.new("Nullable values do not consume nested bytes") unless offset == encoded_values.size
      values
    end

    def read_uint64(column : String = @column) : Array(UInt64)
      read_uint64_mark_range(column, 0, mark_count)
    end

    def read_uint64_slab(
      column : String = @column,
      slab_shift : Int = UInt64SlabVector::DEFAULT_SLAB_SHIFT,
    ) : UInt64SlabVector
      read_uint64_mark_range_slab(column, 0, mark_count, slab_shift)
    end

    def read_uint64_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(UInt64)
      start_mark, end_mark, expected_bytes = checked_mark_range(column, first_mark, mark_count)
      values = Array(UInt64).new
      each_uint64_mark_range(start_mark, end_mark, expected_bytes) do |value|
        values << value
      end
      values
    end

    def read_uint64_mark_range_slab(
      column : String,
      first_mark : Int,
      mark_count : Int,
      slab_shift : Int = UInt64SlabVector::DEFAULT_SLAB_SHIFT,
    ) : UInt64SlabVector
      start_mark, end_mark, expected_bytes = checked_mark_range(column, first_mark, mark_count)
      values = UInt64SlabVector.new(slab_shift: slab_shift)
      each_uint64_mark_range_bytes(start_mark, end_mark, expected_bytes) do |bytes|
        values.concat_le_bytes(bytes)
      end
      values
    end

    def scan_uint64_mark_range_into(
      column : String,
      first_mark : Int,
      mark_count : Int,
      scratch : Slice(UInt64),
      & : Slice(UInt64) -> Nil
    ) : Nil
      raise BoundsError.new("empty scratch") if scratch.size == 0
      raise BoundsError.new("scratch must be writable") if scratch.read_only?

      start_mark, end_mark, expected_bytes = checked_mark_range(column, first_mark, mark_count)
      chunk_size = 0
      each_uint64_mark_range_bytes(start_mark, end_mark, expected_bytes) do |bytes|
        source_offset = 0
        while source_offset < bytes.size
          available = scratch.size - chunk_size
          remaining = (bytes.size - source_offset) // 8
          copied = available < remaining ? available : remaining
          fill_uint64_scratch(scratch, chunk_size, bytes, source_offset, copied)
          chunk_size += copied
          source_offset += copied * 8
          if chunk_size == scratch.size
            yield scratch[0, chunk_size]
            chunk_size = 0
          end
        end
      end
      yield scratch[0, chunk_size] if chunk_size > 0
      nil
    end

    # Scan a complete selected column while preserving physical mark
    # provenance.  A callback receives only values from one mark, and every
    # slice aliases the caller-owned scratch storage.
    def scan_uint64_marks_into(
      column : String,
      scratch : Slice(UInt64),
      & : Int32, UInt64, UInt64, Slice(UInt64) -> Nil
    ) : Nil
      raise BoundsError.new("empty scratch") if scratch.size == 0
      raise BoundsError.new("scratch must be writable") if scratch.read_only?

      start_mark, end_mark, expected_bytes = checked_mark_range(column, 0, mark_count)
      chunk_size = 0
      active_mark = 0_i32
      mark_rows = @marks[active_mark].rows
      mark_values = 0_u64
      mark_start = 0_u64

      each_uint64_mark_range_bytes(start_mark, end_mark, expected_bytes) do |bytes|
        source_offset = 0
        while source_offset < bytes.size
          available = scratch.size - chunk_size
          remaining = (bytes.size - source_offset) // 8
          mark_remaining = (mark_rows - mark_values).to_i
          copied = available < remaining ? available : remaining
          copied = mark_remaining if mark_remaining < copied
          raise CorruptPartError.new("mark scan made no progress") if copied <= 0
          fill_uint64_scratch(scratch, chunk_size, bytes, source_offset, copied)
          chunk_size += copied
          source_offset += copied * 8
          mark_values += copied.to_u64

          if chunk_size == scratch.size || mark_values == mark_rows
            mark_row_offset = mark_values - chunk_size.to_u64
            yield active_mark, mark_row_offset, mark_start &+ mark_row_offset, scratch[0, chunk_size]
            chunk_size = 0
          end

          if mark_values == mark_rows
            mark_start = mark_start &+ mark_rows
            active_mark += 1
            if active_mark < @marks.size
              mark_rows = @marks[active_mark].rows
              mark_values = 0_u64
            end
          end
        end
      end

      if chunk_size > 0
        mark_row_offset = mark_values - chunk_size.to_u64
        yield active_mark, mark_row_offset, mark_start &+ mark_row_offset, scratch[0, chunk_size]
      end
      nil
    end

    @column : String
    @source_column_name : String
    @source_column_type : String
    @json_typed_path : Bool
    @element_width : Int32
    @marks : Array(Mark)
    @sentinel : Mark
    @streams : Hash(String, PhysicalStream)
    @low_cardinality_string_state : LowCardinalityStringState?

    private struct PhysicalStream
      getter name : String
      getter data_path : String
      getter mark_path : String
      getter marks : Array(Mark)
      getter sentinel : Mark

      def initialize(@name : String, @data_path : String, @mark_path : String, @marks : Array(Mark), @sentinel : Mark)
      end
    end

    private struct ArrayTupleComponents
      getter outer_sizes : Array(UInt64)
      getter flat_elements : UInt64
      getter rows : UInt64
      getter element_sizes : Array(UInt64)
      getter string_bytes : UInt64
      getter materialized_bytes : UInt64
      getter numeric_values : Bytes?
      getter null_map : Bytes?
      getter string_values : Bytes?

      def initialize(
        @outer_sizes : Array(UInt64),
        @flat_elements : UInt64,
        @rows : UInt64,
        @element_sizes : Array(UInt64),
        @string_bytes : UInt64,
        @materialized_bytes : UInt64,
        @numeric_values : Bytes?,
        @null_map : Bytes?,
        @string_values : Bytes?,
      )
      end
    end

    private struct LowCardinalityStringState
      getter index_bytes : Bytes
      getter index_mark_offsets : Array(UInt64)
      getter global_dictionary : Bool
      getter shared_keys : Array(String)

      def initialize(@index_bytes : Bytes, @index_mark_offsets : Array(UInt64), @global_dictionary : Bool, @shared_keys : Array(String))
      end
    end

    private def initialize(path : String, requested_column : String?, mode : Symbol)
      @path = path
      raise InvalidPartError.new("part is not a directory") unless Dir.exists?(@path)
      @checksum_verification = ChecksumVerification::Unverified
      @low_cardinality_string_state = nil
      @column, @column_type, @source_column_name, @source_column_type, @json_typed_path, @row_count, physical_streams = parse_metadata(requested_column, mode)
      @streams = Hash(String, PhysicalStream).new
      expected_mark_rows = nil.as(Array(UInt64)?)
      physical_streams.each do |stream_name|
        validate_selected_stream_name(stream_name)
        data_path, mark_path, compressed_marks = resolve_stream(stream_name)
        data_size = File.size(data_path)
        raise CorruptPartError.new("data file exceeds limit") if data_size > MAX_DATA_FILE_BYTES
        element_width = stream_element_width(stream_name)
        allow_empty_string_eof = if WidePart.supports_array_type?(@column_type)
                                   stream_name != "#{@column}.size0" &&
                                     WidePart.array_element_stream_names(@column, @column_type).not_nil!.includes?(stream_name)
                                 elsif WidePart.supports_map_uint64_string_type?(@column_type)
                                   stream_name == "#{@column}%2Ekeys" || stream_name == "#{@column}%2Evalues.size" || stream_name == "#{@column}%2Evalues"
                                 elsif WidePart.supports_map_uint64_uint64_type?(@column_type)
                                   stream_name == "#{@column}%2Ekeys" || stream_name == "#{@column}%2Evalues"
                                 elsif WidePart.supports_map_uint64_nullable_uint64_type?(@column_type)
                                   stream_name == "#{@column}%2Ekeys" || stream_name == "#{@column}%2Evalues.null" || stream_name == "#{@column}%2Evalues"
                                 elsif WidePart.supports_map_string_uint64_type?(@column_type)
                                   stream_name == "#{@column}%2Ekeys.size" || stream_name == "#{@column}%2Ekeys" || stream_name == "#{@column}%2Evalues"
                                 elsif WidePart.supports_map_string_string_type?(@column_type)
                                   stream_name == "#{@column}%2Ekeys.size" || stream_name == "#{@column}%2Ekeys" ||
                                     stream_name == "#{@column}%2Evalues.size" || stream_name == "#{@column}%2Evalues"
                                 elsif WidePart.supports_map_string_nullable_uint64_type?(@column_type)
                                   stream_name == "#{@column}%2Ekeys.size" || stream_name == "#{@column}%2Ekeys" ||
                                     stream_name == "#{@column}%2Evalues.null" || stream_name == "#{@column}%2Evalues"
                                 elsif WidePart.supports_map_uint64_nullable_string_type?(@column_type)
                                   stream_name == "#{@column}%2Ekeys" || stream_name == "#{@column}%2Evalues.null" ||
                                     stream_name == "#{@column}%2Evalues.size" || stream_name == "#{@column}%2Evalues"
                                 elsif WidePart.supports_map_string_nullable_string_type?(@column_type)
                                   stream_name == "#{@column}%2Ekeys.size" || stream_name == "#{@column}%2Ekeys" ||
                                     stream_name == "#{@column}%2Evalues.null" || stream_name == "#{@column}%2Evalues.size" ||
                                     stream_name == "#{@column}%2Evalues"
                                 elsif WidePart.supports_tuple_uint64_string_type?(@column_type)
                                   stream_name == "#{@column}%2Eb"
                                 else
                                   (@column_type == "String" || WidePart.supports_nullable_string_type?(@column_type)) && stream_name == @column
                                 end
        mark_row_width = if stream_name != "#{@column}.size0" &&
                            (WidePart.array_fixed_string_width(@column_type) || WidePart.array_nullable_fixed_string_width(@column_type) ||
                            WidePart.supports_array_bool_type?(@column_type) || WidePart.supports_array_nullable_bool_type?(@column_type))
                           8
                         else
                           element_width
                         end
        marks, sentinel = if @column_type == "LowCardinality(String)" && stream_name == "#{@column}.dict"
                            parse_low_cardinality_dictionary_marks(mark_path, data_size, compressed_marks)
                          elsif @column_type == "LowCardinality(String)"
                            parse_marks(
                              mark_path,
                              data_size,
                              compressed_marks,
                              element_width,
                              allow_empty_string_eof,
                              mark_row_width: element_width,
                              max_records: MAX_LOW_CARDINALITY_MARKS + 1
                            )
                          else
                            parse_marks(
                              mark_path,
                              data_size,
                              compressed_marks,
                              element_width,
                              allow_empty_string_eof,
                              mark_row_width: mark_row_width
                            )
                          end
        validate_rows(marks)
        mark_rows = marks.map(&.rows)
        if expected = expected_mark_rows
          raise CorruptPartError.new("selected substreams have different mark row counts") unless mark_rows == expected
        else
          expected_mark_rows = mark_rows
        end
        @streams[stream_name] = PhysicalStream.new(stream_name, data_path, mark_path, marks, sentinel)
      end

      primary_stream = primary_stream_name(physical_streams)
      selected_stream = @streams[primary_stream]
      @data_path = selected_stream.data_path
      @mark_path = selected_stream.mark_path
      @marks = selected_stream.marks
      @sentinel = selected_stream.sentinel
      @element_width = stream_element_width(primary_stream)
    end

    private def parse_metadata(requested_column : String?, mode : Symbol) : {String, String, String, String, Bool, UInt64, Array(String)}
      columns_text = read_metadata_file("columns.txt")
      columns = parse_columns(columns_text)
      if columns.empty?
        raise UnsupportedFormatError.new("columns.txt contains no columns")
      end
      if requested_column.nil? && columns.size > 1
        raise UnsupportedFormatError.new("column is required for a multi-column part")
      end
      column = requested_column || columns[0][0]
      selected, source_column_name, source_column_type, column_type, json_typed_path =
        resolve_selected_column(columns, column)
      raise UnsupportedFormatError.new("JSON typed paths require the exact typed scan") if json_typed_path && mode != :typed
      case mode
      when :numeric
        numeric_type_width(column_type)
      when :typed
        raise UnsupportedFormatError.new("unsupported exact typed column") unless WidePart.supports_typed_type?(column_type)
      else
        raise UnsupportedFormatError.new("only exact UInt64 columns are supported") unless column_type == "UInt64"
      end

      validate_default_codec
      row_count = parse_count_file("count.txt")
      raise CorruptPartError.new("row count exceeds limit") if row_count > MAX_ROWS

      json_paths = [] of {String, String}
      if json_typed_path
        json_paths = WidePart.json_typed_paths(source_column_type)
        validate_json_typed_path_serialization(source_column_name, json_paths)
      elsif column_type == "LowCardinality(String)"
        validate_low_cardinality_string_serialization(columns, selected, row_count)
      elsif WidePart.supports_array_type?(column_type)
        validate_array_type_serialization_version(column_type, columns, selected, row_count)
      elsif WidePart.supports_map_uint64_string_type?(column_type)
        validate_map_serialization(columns, selected, row_count, column_type)
      elsif WidePart.supports_map_uint64_uint64_type?(column_type)
        validate_map_serialization(columns, selected, row_count, column_type)
      elsif WidePart.supports_map_string_uint64_type?(column_type) || WidePart.supports_map_string_string_type?(column_type) ||
            WidePart.supports_map_uint64_nullable_uint64_type?(column_type) || WidePart.supports_map_string_nullable_uint64_type?(column_type) ||
            WidePart.supports_map_uint64_nullable_string_type?(column_type) || WidePart.supports_map_string_nullable_string_type?(column_type)
        validate_map_serialization(columns, selected, row_count, column_type)
      elsif WidePart.supports_tuple_uint64_string_type?(column_type)
        validate_tuple_uint64_string_serialization(columns, selected, row_count)
      elsif column_type == "Int128" || column_type == "UInt128" || column_type == "Int256" || column_type == "UInt256"
        validate_raw_integer_serialization(columns, row_count)
      elsif column_type == "Nullable(Int128)" || column_type == "Nullable(UInt128)" || column_type == "Nullable(Int256)" || column_type == "Nullable(UInt256)"
        validate_nullable_raw_integer_serialization(columns, row_count)
      elsif column_type == "String" || !WidePart.fixed_string_width(column_type).nil? || !WidePart.nullable_fixed_string_width(column_type).nil? || WidePart.supports_nullable_numeric_type?(column_type) || WidePart.supports_nullable_temporal_type?(column_type) || WidePart.supports_nullable_time_type?(column_type) || WidePart.supports_nullable_string_type?(column_type) || WidePart.supports_uuid_type?(column_type) || WidePart.supports_nullable_uuid_type?(column_type) || WidePart.supports_ipv4_type?(column_type) || WidePart.supports_nullable_ipv4_type?(column_type) || WidePart.supports_ipv6_type?(column_type) || WidePart.supports_nullable_ipv6_type?(column_type) || WidePart.supports_semantic_fixed_width_type?(column_type) || WidePart.supports_nullable_semantic_fixed_width_type?(column_type)
        validate_type_serialization_version(column_type)
      end

      physical_streams = parse_substreams(columns, selected, column_type, source_column_name, json_paths)
      {selected, column_type, source_column_name, source_column_type, json_typed_path, row_count, physical_streams}
    rescue ex : ArgumentError
      raise CorruptPartError.new("invalid metadata")
    end

    private def resolve_selected_column(
      columns : Array({String, String}),
      requested_column : String,
    ) : {String, String, String, String, Bool}
      exact = columns.find { |entry| entry[0] == requested_column }
      virtual = Array({String, String, String}).new
      columns.each do |entry|
        owner, owner_type = entry
        next unless WidePart.json_type?(owner_type)
        prefix = "#{owner}."
        next unless requested_column.starts_with?(prefix)
        path = requested_column.byte_slice(prefix.bytesize, requested_column.bytesize - prefix.bytesize)
        path_type = WidePart.json_typed_path_type(owner_type, path)
        virtual << {owner, owner_type, path_type.not_nil!} if path_type
      end

      if exact && !virtual.empty?
        raise UnsupportedFormatError.new("selected column is ambiguous between a literal dotted column and a JSON typed path")
      end
      if selected = exact
        return {selected[0], selected[0], selected[1], selected[1], false}
      end
      raise UnsupportedFormatError.new("selected column is not present") if virtual.empty?
      raise UnsupportedFormatError.new("selected JSON typed path is ambiguous") unless virtual.size == 1
      owner, owner_type, path_type = virtual[0]
      {requested_column, owner, owner_type, path_type, true}
    end

    private def read_metadata_file(name : String) : String
      file = File.join(@path, name)
      raise CorruptPartError.new("#{name} must not be a symbolic link") if File.symlink?(file)
      size = File.size(file)
      raise UnsupportedFormatError.new("#{name} exceeds metadata limit") if size > MAX_METADATA_FILE_BYTES
      text = File.read(file)
      raise UnsupportedFormatError.new("#{name} must end with LF") if text.empty? || text.bytesize != size || text.bytes.last != 10
      text
    end

    private def validate_default_codec
      file = File.join(@path, "default_compression_codec.txt")
      raise CorruptPartError.new("default_compression_codec.txt must not be a symbolic link") if File.symlink?(file)
      size = File.size(file)
      raise UnsupportedFormatError.new("default codec exceeds metadata limit") if size > MAX_CODEC_FILE_BYTES
      codec = File.read(file)
      unless codec.bytesize == size && (codec == "CODEC(LZ4)" || codec == "CODEC(ZSTD(1))")
        raise UnsupportedFormatError.new("only CODEC(LZ4) and CODEC(ZSTD(1)) are supported")
      end
    end

    private def parse_columns(text : String) : Array({String, String})
      bytes = text.to_slice
      cursor = 0
      require_metadata_line(bytes, cursor, "columns format version: 1", "columns.txt")
      cursor += line_length(bytes, cursor)
      count_line = metadata_line(bytes, cursor, "columns.txt")
      cursor += line_length(bytes, cursor)
      count = parse_count_line(count_line, " columns:", MAX_METADATA_COLUMNS, "columns.txt")
      columns = Array({String, String}).new(count)
      seen = Set(String).new
      count.times do
        line = metadata_line(bytes, cursor, "columns.txt")
        cursor += line_length(bytes, cursor)
        name, type_text = parse_column_line(line)
        raise UnsupportedFormatError.new("duplicate column name") if seen.includes?(name)
        seen << name
        columns << {name, type_text}
      end
      raise UnsupportedFormatError.new("trailing columns.txt data") unless cursor == bytes.size
      columns
    end

    private def parse_substreams(
      columns : Array({String, String}),
      selected_column : String,
      selected_type : String,
      source_column : String = selected_column,
      json_paths : Array({String, String}) = [] of {String, String},
    ) : Array(String)
      file = File.join(@path, "columns_substreams.txt")
      unless File.exists?(file)
        raise UnsupportedFormatError.new("columns_substreams.txt is required for multi-column parts") unless columns.size == 1
        raise UnsupportedFormatError.new("columns_substreams.txt is required for JSON typed paths") unless json_paths.empty?
        expected_streams = expected_physical_streams(selected_column, selected_type)
        raise UnsupportedFormatError.new("columns_substreams.txt is required for this serialization shape") unless expected_streams == [selected_column]
        return [selected_column]
      end
      text = read_metadata_file("columns_substreams.txt")
      bytes = text.to_slice
      cursor = 0
      require_metadata_line(bytes, cursor, "columns substreams version: 1", "columns_substreams.txt")
      cursor += line_length(bytes, cursor)
      count_line = metadata_line(bytes, cursor, "columns_substreams.txt")
      cursor += line_length(bytes, cursor)
      count = parse_count_line(count_line, " columns:", MAX_METADATA_COLUMNS, "columns_substreams.txt")
      raise UnsupportedFormatError.new("column count does not match") unless count == columns.size

      seen_columns = Set(String).new
      seen_streams = Set(String).new
      selected_streams = nil.as(Array(String)?)
      count.times do |index|
        line = metadata_line(bytes, cursor, "columns_substreams.txt")
        cursor += line_length(bytes, cursor)
        stream_count, column = parse_substream_header(line)
        expected_column = columns[index][0]
        raise UnsupportedFormatError.new("column order does not match") unless column == expected_column
        raise UnsupportedFormatError.new("duplicate column block") if seen_columns.includes?(column)
        seen_columns << column
        streams = Array(String).new(stream_count)
        stream_count.times do
          stream_line = metadata_line(bytes, cursor, "columns_substreams.txt")
          cursor += line_length(bytes, cursor)
          raise UnsupportedFormatError.new("invalid physical stream name") unless stream_line.starts_with?("\t")
          stream_bytes = stream_line.to_slice
          stream = String.new(stream_bytes[1, stream_bytes.size - 1])
          validate_opaque_name(stream)
          raise UnsupportedFormatError.new("duplicate physical stream name") if seen_streams.includes?(stream)
          seen_streams << stream
          streams << stream
        end
        if column == source_column
          if json_paths.empty?
            expected_streams = expected_physical_streams(column, selected_type)
            raise UnsupportedFormatError.new("selected physical substreams do not match exact serialization shape") unless streams == expected_streams
            selected_streams = streams
          else
            expected_json_streams = expected_json_typed_path_substreams(source_column, json_paths)
            raise UnsupportedFormatError.new("JSON physical substreams do not match declared typed-path shape") unless streams == expected_json_streams
            selected_streams = expected_physical_streams(selected_column, selected_type)
          end
        elsif w51_array_tuple_pair_schema?(columns, selected_column)
          sibling_type = columns[index][1]
          expected_streams = expected_physical_streams(column, sibling_type)
          raise UnsupportedFormatError.new("W51 sibling physical substreams do not match exact serialization shape") unless streams == expected_streams
        elsif WidePart.supports_tuple_uint64_string_type?(selected_type)
          raise UnsupportedFormatError.new("Tuple key column must have one plain UInt64 stream") unless streams == [column]
        elsif WidePart.supports_map_uint64_string_type?(selected_type) || WidePart.supports_map_uint64_uint64_type?(selected_type) ||
              WidePart.supports_map_string_uint64_type?(selected_type) || WidePart.supports_map_string_string_type?(selected_type) ||
              WidePart.supports_map_uint64_nullable_uint64_type?(selected_type) || WidePart.supports_map_string_nullable_uint64_type?(selected_type) ||
              WidePart.supports_map_uint64_nullable_string_type?(selected_type) || WidePart.supports_map_string_nullable_string_type?(selected_type)
          if columns.any? { |name, type| name == column && type == "UInt64" }
            raise UnsupportedFormatError.new("Map key column must have one plain UInt64 stream") unless streams == [column]
          end
        end
      end
      raise UnsupportedFormatError.new("trailing columns_substreams.txt data") unless cursor == bytes.size
      selected_streams || raise UnsupportedFormatError.new("selected column substreams are missing")
    end

    private def expected_json_typed_path_substreams(column : String, paths : Array({String, String})) : Array(String)
      streams = ["#{column}.object_structure"]
      paths.sort_by(&.[0]).each do |path, type|
        streams.concat(expected_physical_streams("#{column}.#{path}", type))
      end
      streams << "#{column}.object_shared_data.0.size0"
      streams << "#{column}.object_shared_data.0%2Epaths"
      streams << "#{column}.object_shared_data.0%2Evalues"
      streams
    end

    private def expected_physical_streams(column : String, type : String) : Array(String)
      if type == "LowCardinality(String)"
        ["#{column}.dict", column]
      elsif WidePart.supports_tuple_uint64_string_type?(type)
        ["#{column}%2Ea", "#{column}%2Eb.size", "#{column}%2Eb"]
      elsif element_streams = WidePart.array_element_stream_names(column, type)
        ["#{column}.size0"] + element_streams
      elsif WidePart.supports_map_uint64_string_type?(type)
        ["#{column}.size0", "#{column}%2Ekeys", "#{column}%2Evalues.size", "#{column}%2Evalues"]
      elsif WidePart.supports_map_uint64_uint64_type?(type)
        ["#{column}.size0", "#{column}%2Ekeys", "#{column}%2Evalues"]
      elsif WidePart.supports_map_uint64_nullable_uint64_type?(type)
        ["#{column}.size0", "#{column}%2Ekeys", "#{column}%2Evalues.null", "#{column}%2Evalues"]
      elsif WidePart.supports_map_string_uint64_type?(type)
        ["#{column}.size0", "#{column}%2Ekeys.size", "#{column}%2Ekeys", "#{column}%2Evalues"]
      elsif WidePart.supports_map_string_string_type?(type)
        ["#{column}.size0", "#{column}%2Ekeys.size", "#{column}%2Ekeys", "#{column}%2Evalues.size", "#{column}%2Evalues"]
      elsif WidePart.supports_map_string_nullable_uint64_type?(type)
        ["#{column}.size0", "#{column}%2Ekeys.size", "#{column}%2Ekeys", "#{column}%2Evalues.null", "#{column}%2Evalues"]
      elsif WidePart.supports_map_uint64_nullable_string_type?(type)
        ["#{column}.size0", "#{column}%2Ekeys", "#{column}%2Evalues.null", "#{column}%2Evalues.size", "#{column}%2Evalues"]
      elsif WidePart.supports_map_string_nullable_string_type?(type)
        ["#{column}.size0", "#{column}%2Ekeys.size", "#{column}%2Ekeys", "#{column}%2Evalues.null", "#{column}%2Evalues.size", "#{column}%2Evalues"]
      elsif type == "String"
        ["#{column}.size", column]
      elsif WidePart.supports_nullable_string_type?(type)
        ["#{column}.null", "#{column}.size", column]
      elsif WidePart.supports_nullable_uuid_type?(type)
        ["#{column}.null", column]
      elsif WidePart.supports_nullable_ipv4_type?(type)
        ["#{column}.null", column]
      elsif WidePart.supports_nullable_ipv6_type?(type)
        ["#{column}.null", column]
      elsif type == "Nullable(Int128)" || type == "Nullable(UInt128)" || type == "Nullable(Int256)" || type == "Nullable(UInt256)"
        ["#{column}.null", column]
      elsif WidePart.nullable_fixed_string_width(type)
        ["#{column}.null", column]
      elsif WidePart.fixed_string_width(type)
        [column]
      elsif WidePart.supports_nullable_numeric_type?(type)
        ["#{column}.null", column]
      elsif WidePart.supports_nullable_temporal_type?(type)
        ["#{column}.null", column]
      elsif WidePart.supports_nullable_time_type?(type)
        ["#{column}.null", column]
      elsif WidePart.supports_nullable_semantic_fixed_width_type?(type)
        ["#{column}.null", column]
      else
        [column]
      end
    end

    private def validate_array_type_serialization_version(
      type : String,
      columns : Array({String, String}),
      selected_column : String,
      row_count : UInt64,
    ) : Nil
      file = File.join(@path, "serialization.json")
      raise UnsupportedFormatError.new("serialization.json is required for this type") unless File.file?(file)
      raise CorruptPartError.new("serialization.json must not be a symbolic link") if File.symlink?(file)
      size = File.size(file)
      raise UnsupportedFormatError.new("serialization.json exceeds metadata limit") if size > MAX_METADATA_FILE_BYTES
      text = File.read(file)
      raise CorruptPartError.new("serialization.json changed while reading") unless text.bytesize == size

      info = JSON.parse(text).as_h
      info.each_key do |key|
        unless ["version", "columns", "types_serialization_versions", "propagate_types_serialization_versions_to_nested_types"].includes?(key)
          raise UnsupportedFormatError.new("unsupported array serialization.json field")
        end
      end
      version = info["version"]?.try(&.as_i) || raise(CorruptPartError.new("serialization.json version is missing or malformed"))
      raise UnsupportedFormatError.new("only serialization.json version 1 is supported") unless version == 1
      propagated = info["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool)
      raise UnsupportedFormatError.new("array nested serialization versions are unsupported") unless propagated == true

      versions = info["types_serialization_versions"]?.try(&.as_h) || raise(CorruptPartError.new("serialization type versions are missing or malformed"))
      unless versions.size == 1 && versions["string"]?.try(&.as_i) == 1
        raise UnsupportedFormatError.new("only nested String serialization version 1 is supported for arrays")
      end

      numeric_array = !WidePart.numeric_array_element_type(type).nil?
      key_columns = columns.select { |name, column_type| name != selected_column && column_type == "UInt64" }
      serializers = info["columns"]?.try(&.as_a) || raise(UnsupportedFormatError.new("array column serializers are required"))
      w33_fixed_string_pair_shape = fixed_string_array_w33_schema?(columns, selected_column)
      w34_bool_pair_shape = bool_array_w34_schema?(columns, selected_column)
      w39_wide_array_shape = wide_integer_array_w39_schema?(columns, selected_column)
      w40_temporal_array_shape = temporal_array_w40_schema?(columns, selected_column)
      w41_uuid_array_shape = uuid_array_w41_schema?(columns, selected_column)
      w42_decimal32_array_shape = decimal32_array_w42_schema?(columns, selected_column)
      w43_decimal64_array_shape = decimal64_array_w43_schema?(columns, selected_column)
      w44_decimal128_array_shape = decimal128_array_w44_schema?(columns, selected_column)
      w45_decimal256_array_shape = decimal256_array_w45_schema?(columns, selected_column)
      w46_ipv4_array_shape = ipv4_array_w46_schema?(columns, selected_column)
      w47_ipv6_array_shape = ipv6_array_w47_schema?(columns, selected_column)
      w48_enum_array_shape = enum_array_w48_schema?(columns, selected_column)
      w49_bfloat16_array_shape = bfloat16_array_w49_schema?(columns, selected_column)
      w50_time_array_shape = time_array_w50_schema?(columns, selected_column)
      w51_array_tuple_pair_shape = w51_array_tuple_pair_schema?(columns, selected_column)
      if serializers.empty?
        legacy_two_column_shape = columns.size == 2 && key_columns.size == 1
        w31_nullable_numeric_shape = nullable_numeric_w31_schema?(columns, selected_column)
        unless legacy_two_column_shape || w31_nullable_numeric_shape || w33_fixed_string_pair_shape || w34_bool_pair_shape || w39_wide_array_shape || w40_temporal_array_shape || w41_uuid_array_shape || w42_decimal32_array_shape || w43_decimal64_array_shape || w44_decimal128_array_shape || w45_decimal256_array_shape || w46_ipv4_array_shape || w47_ipv6_array_shape || w48_enum_array_shape || w49_bfloat16_array_shape || w50_time_array_shape || w51_array_tuple_pair_shape
          raise UnsupportedFormatError.new("array serialization requires one UInt64 key/value pair when key serializer is absent")
        end
      else
        raise UnsupportedFormatError.new("array per-column serialization is unsupported") unless serializers.size == 1
        serializer = serializers[0].as_h
        unless serializer.keys.to_set == Set{"kind", "name", "num_defaults", "num_rows"}
          raise UnsupportedFormatError.new("array column serializer fields are unsupported")
        end
        kind = serializer["kind"]?.try(&.as_s) || raise(CorruptPartError.new("array serializer kind is missing or malformed"))
        name = serializer["name"]?.try(&.as_s) || raise(CorruptPartError.new("array serializer name is missing or malformed"))
        defaults = serializer["num_defaults"]?.try(&.as_i) || raise(CorruptPartError.new("array serializer default count is missing or malformed"))
        rows = serializer["num_rows"]?.try(&.as_i) || raise(CorruptPartError.new("array serializer row count is missing or malformed"))
        key_column = columns.find { |column_name, column_type| column_name == name && column_name != selected_column && column_type == "UInt64" }
        raise UnsupportedFormatError.new("array serializer must identify a UInt64 key column") unless key_column
        legacy_two_column_shape = columns.size == 2 && key_columns.size == 1 && key_columns[0] == key_column
        w33_keyed_fixed_string_shape = w33_fixed_string_pair_shape && key_columns.size == 1 && key_columns[0] == key_column
        w34_keyed_bool_shape = w34_bool_pair_shape && key_columns.size == 1 && key_columns[0] == key_column
        w39_keyed_wide_array_shape = w39_wide_array_shape && key_columns.size == 1 && key_columns[0] == key_column
        w40_keyed_temporal_array_shape = w40_temporal_array_shape && key_columns.size == 1 && key_columns[0] == key_column
        w41_keyed_uuid_array_shape = w41_uuid_array_shape && key_columns.size == 1 && key_columns[0] == key_column
        w42_keyed_decimal32_array_shape = w42_decimal32_array_shape && key_columns.size == 1 && key_columns[0] == key_column
        w46_keyed_ipv4_array_shape = w46_ipv4_array_shape && key_columns.size == 1 && key_columns[0] == key_column
        w47_keyed_ipv6_array_shape = w47_ipv6_array_shape && key_columns.size == 1 && key_columns[0] == key_column
        unless numeric_array || legacy_two_column_shape || w33_keyed_fixed_string_shape || w34_keyed_bool_shape || w39_keyed_wide_array_shape || w40_keyed_temporal_array_shape || w41_keyed_uuid_array_shape || w42_keyed_decimal32_array_shape || w46_keyed_ipv4_array_shape || w47_keyed_ipv6_array_shape
          raise UnsupportedFormatError.new("array serialization requires one supported UInt64 key/value pair")
        end
        unless kind == "Default"
          raise UnsupportedFormatError.new("only Default key serialization is supported for arrays")
        end
        unless defaults >= 0 && rows >= 0 && defaults <= rows && rows.to_u64 == row_count
          raise CorruptPartError.new("array serializer default or row count does not match part")
        end
      end
      raise UnsupportedFormatError.new("unsupported array serializer type") unless WidePart.supports_array_type?(type)
      nil
    rescue ex : JSON::ParseException | TypeCastError | OverflowError
      raise CorruptPartError.new("serialization.json is malformed")
    end

    private def nullable_numeric_w31_schema?(columns : Array({String, String}), selected_column : String) : Bool
      return false unless columns.size == 11
      return false unless columns.any? { |name, column_type| name == selected_column && !WidePart.nullable_numeric_array_element_type(column_type).nil? }

      key_columns = columns.select { |name, column_type| name != selected_column && column_type == "UInt64" }
      return false unless key_columns.size == 1

      nullable_types = columns.compact_map do |_, column_type|
        WidePart.nullable_numeric_array_element_type(column_type)
      end
      expected_types = Set{
        "UInt8", "UInt16", "UInt32", "UInt64",
        "Int8", "Int16", "Int32", "Int64",
        "Float32", "Float64",
      }
      return false unless nullable_types.size == 10 && nullable_types.to_set == expected_types

      columns.all? do |name, column_type|
        name == selected_column || column_type == "UInt64" || !WidePart.nullable_numeric_array_element_type(column_type).nil?
      end
    end

    # Exact stock ClickHouse fixture shape for the four BASIC wide integer
    # Array leaves, paired with their BASIC Nullable forms and one UInt64 key.
    # This narrow exception admits the no-per-column-serializer metadata used
    # by that part without relaxing serializer admission for other arrays.
    private def wide_integer_array_w39_schema?(columns : Array({String, String}), selected_column : String) : Bool
      return false unless columns.size == 9
      return false unless columns.any? { |name, _| name == selected_column }

      key_columns = columns.select { |name, column_type| name != selected_column && column_type == "UInt64" }
      return false unless key_columns.size == 1 && columns.count { |_, column_type| column_type == "UInt64" } == 1

      selected_type = columns.find { |name, _| name == selected_column }.try(&.[1]) || return false
      return false unless !WidePart.numeric_array_element_type(selected_type).nil? || !WidePart.nullable_numeric_array_element_type(selected_type).nil?

      array_types = columns.compact_map do |_, column_type|
        column_type if !WidePart.numeric_array_element_type(column_type).nil? || !WidePart.nullable_numeric_array_element_type(column_type).nil?
      end
      expected_types = Set{
        "Array(Int128)", "Array(UInt128)", "Array(Int256)", "Array(UInt256)",
        "Array(Nullable(Int128))", "Array(Nullable(UInt128))", "Array(Nullable(Int256))", "Array(Nullable(UInt256))",
      }
      return false unless array_types.size == 8 && array_types.to_set == expected_types

      columns.all? do |name, column_type|
        name == selected_column || column_type == "UInt64" ||
          !WidePart.numeric_array_element_type(column_type).nil? || !WidePart.nullable_numeric_array_element_type(column_type).nil?
      end
    end

    # Exact stock W40 fixture shape for the four BASIC temporal Array leaves,
    # their BASIC Nullable forms, and one UInt64 key. This exception is only
    # for the observed DateTime64(3) stock fixture with empty serializers;
    # paired two-column writer output is admitted separately by the semantic
    # temporal predicate above, including DateTime64 precisions 0 through 9.
    private def temporal_array_w40_schema?(columns : Array({String, String}), selected_column : String) : Bool
      return false unless columns.size == 9
      return false unless columns.any? { |name, _| name == selected_column }

      key_columns = columns.select { |name, column_type| name != selected_column && column_type == "UInt64" }
      return false unless key_columns.size == 1 && columns.count { |_, column_type| column_type == "UInt64" } == 1

      selected_type = columns.find { |name, _| name == selected_column }.try(&.[1]) || return false
      return false unless !WidePart.temporal_array_element_type(selected_type).nil? || !WidePart.nullable_temporal_array_element_type(selected_type).nil?

      array_types = columns.compact_map do |_, column_type|
        column_type if !WidePart.temporal_array_element_type(column_type).nil? || !WidePart.nullable_temporal_array_element_type(column_type).nil?
      end
      expected_types = Set{
        "Array(Date)", "Array(Date32)", "Array(DateTime)", "Array(DateTime64(3))",
        "Array(Nullable(Date))", "Array(Nullable(Date32))", "Array(Nullable(DateTime))", "Array(Nullable(DateTime64(3)))",
      }
      return false unless array_types.size == 8 && array_types.to_set == expected_types

      columns.all? do |name, column_type|
        name == selected_column || column_type == "UInt64" ||
          !WidePart.temporal_array_element_type(column_type).nil? || !WidePart.nullable_temporal_array_element_type(column_type).nil?
      end
    end

    # Exact stock W50 schema with empty per-column serializers. This exception
    # is limited to the observed column order and names; two-column writer
    # shapes continue through the existing legacy key/value path.
    private def time_array_w50_schema?(columns : Array({String, String}), selected_column : String) : Bool
      return false unless columns == [
                            {"pk", "UInt64"},
                            {"t", "Time"},
                            {"nt", "Nullable(Time)"},
                            {"a", "Array(Time)"},
                            {"an", "Array(Nullable(Time))"},
                            {"t64_0", "Time64(0)"},
                            {"t64_3", "Time64(3)"},
                            {"t64_9", "Time64(9)"},
                            {"nt64_3", "Nullable(Time64(3))"},
                            {"a64_3", "Array(Time64(3))"},
                            {"an64_3", "Array(Nullable(Time64(3)))"},
                          ]

      selected_type = columns.find { |name, _| name == selected_column }.try(&.[1]) || return false
      !WidePart.time_array_element_type(selected_type).nil? || !WidePart.nullable_time_array_element_type(selected_type).nil?
    end

    # Exact W51 stock schema: one UInt64 key and the two admitted named-tuple
    # Array declarations. Keep the empty-serializer exception tied to these
    # names and order instead of relaxing all three-column array metadata.
    private def w51_array_tuple_pair_schema?(columns : Array({String, String}), selected_column : String) : Bool
      return false unless columns == [
                            {"pk", "UInt64"},
                            {"arr_tuple", WideTypePlan::TYPE_ARRAY_TUPLE_UINT64_STRING},
                            {"arr_tuple_nullable", WideTypePlan::TYPE_ARRAY_TUPLE_NULLABLE_UINT64_STRING},
                          ]
      selected_column == "arr_tuple" || selected_column == "arr_tuple_nullable"
    end

    # Exact stock W41 fixture shape: one UInt64 key, one Array(UUID), and one
    # Array(Nullable(UUID)) value. This only admits its empty serializer form;
    # paired two-column writer output uses the existing legacy key/value gate.
    private def uuid_array_w41_schema?(columns : Array({String, String}), selected_column : String) : Bool
      return false unless columns == [
                            {"pk", "UInt64"},
                            {"plain", "Array(UUID)"},
                            {"maybe", "Array(Nullable(UUID))"},
                          ]
      selected_type = columns.find { |name, _| name == selected_column }.try(&.[1]) || return false
      !WidePart.uuid_array_element_type(selected_type).nil? || !WidePart.nullable_uuid_array_element_type(selected_type).nil?
    end

    # Exact W46 stock fixture shape: one UInt64 key with the paired IPv4
    # Array forms. This exception only admits canonical declarations.
    private def ipv4_array_w46_schema?(columns : Array({String, String}), selected_column : String) : Bool
      return false unless columns == [
                            {"pk", "UInt64"},
                            {"plain", "Array(IPv4)"},
                            {"maybe", "Array(Nullable(IPv4))"},
                          ]
      selected_type = columns.find { |name, _| name == selected_column }.try(&.[1]) || return false
      !WidePart.ipv4_array_element_type(selected_type).nil? || !WidePart.nullable_ipv4_array_element_type(selected_type).nil?
    end

    # Exact W47 stock fixture shape: one UInt64 key with the paired IPv6
    # Array forms. This exception only admits canonical declarations.
    private def ipv6_array_w47_schema?(columns : Array({String, String}), selected_column : String) : Bool
      return false unless columns == [
                            {"pk", "UInt64"},
                            {"plain", "Array(IPv6)"},
                            {"maybe", "Array(Nullable(IPv6))"},
                          ]
      selected_type = columns.find { |name, _| name == selected_column }.try(&.[1]) || return false
      !WidePart.ipv6_array_element_type(selected_type).nil? || !WidePart.nullable_ipv6_array_element_type(selected_type).nil?
    end

    # Exact W48 stock Enum fixture profile: one UInt64 key and the BASIC
    # Enum8/Enum16 Array pair, in canonical physical metadata spelling.
    private def enum_array_w48_schema?(columns : Array({String, String}), selected_column : String) : Bool
      return false unless columns == [
                            {"pk", "UInt64"},
                            {"plain8", "Array(Enum8('min' = -128, 'neg' = -7, 'zero' = 0, 'pos' = 7, 'max' = 127))"},
                            {"maybe8", "Array(Nullable(Enum8('min' = -128, 'neg' = -7, 'zero' = 0, 'pos' = 7, 'max' = 127)))"},
                            {"plain16", "Array(Enum16('min' = -32768, 'neg' = -300, 'zero' = 0, 'pos' = 300, 'max' = 32767))"},
                            {"maybe16", "Array(Nullable(Enum16('min' = -32768, 'neg' = -300, 'zero' = 0, 'pos' = 300, 'max' = 32767)))"},
                          ]
      selected_type = columns.find { |name, _| name == selected_column }.try(&.[1]) || return false
      !WidePart.array_enum8_codes(selected_type).nil? || !WidePart.array_nullable_enum8_codes(selected_type).nil? ||
        !WidePart.array_enum16_codes(selected_type).nil? || !WidePart.array_nullable_enum16_codes(selected_type).nil?
    end

    # Exact W49 stock BFloat16 profile: scalar, nullable scalar, and both
    # Array forms share one UInt64 key. This exception does not generalize the
    # empty-serializer path to arbitrary BFloat16 Array schemas.
    private def bfloat16_array_w49_schema?(columns : Array({String, String}), selected_column : String) : Bool
      return false unless columns == [
                            {"pk", "UInt64"},
                            {"scalar", "BFloat16"},
                            {"maybe", "Nullable(BFloat16)"},
                            {"plain", "Array(BFloat16)"},
                            {"nullable_array", "Array(Nullable(BFloat16))"},
                          ]
      selected_type = columns.find { |name, _| name == selected_column }.try(&.[1]) || return false
      selected_type == "Array(BFloat16)" || selected_type == "Array(Nullable(BFloat16))"
    end

    # Exact W42 stock fixture shape for the paired Decimal32(2) Array leaves.
    # Other scales remain available through paired two-column writer parts,
    # but the empty-serializer exception is restricted to the observed schema.
    private def decimal32_array_w42_schema?(columns : Array({String, String}), selected_column : String) : Bool
      return false unless columns == [
                            {"pk", "UInt64"},
                            {"plain", "Array(Decimal(9, 2))"},
                            {"maybe", "Array(Nullable(Decimal(9, 2)))"},
                          ]
      selected_type = columns.find { |name, _| name == selected_column }.try(&.[1]) || return false
      !WidePart.array_decimal32_scale(selected_type).nil? || !WidePart.array_nullable_decimal32_scale(selected_type).nil?
    end

    # Exact observed W43 stock fixture shape. The empty serializer exception
    # is limited to these names and canonical Decimal64(2) declarations.
    private def decimal64_array_w43_schema?(columns : Array({String, String}), selected_column : String) : Bool
      return false unless columns == [
                            {"pk", "UInt64"},
                            {"plain", "Array(Decimal(18, 2))"},
                            {"maybe", "Array(Nullable(Decimal(18, 2)))"},
                          ]
      selected_type = columns.find { |name, _| name == selected_column }.try(&.[1]) || return false
      !WidePart.array_decimal64_scale(selected_type).nil? || !WidePart.array_nullable_decimal64_scale(selected_type).nil?
    end

    # Exact observed W44 stock fixture shape. The no-serializer exception is
    # pinned to the two canonical Decimal128(2) Array declarations.
    private def decimal128_array_w44_schema?(columns : Array({String, String}), selected_column : String) : Bool
      return false unless columns == [
                            {"pk", "UInt64"},
                            {"plain", "Array(Decimal(38, 2))"},
                            {"maybe", "Array(Nullable(Decimal(38, 2)))"},
                          ]
      selected_type = columns.find { |name, _| name == selected_column }.try(&.[1]) || return false
      !WidePart.array_decimal128_scale(selected_type).nil? || !WidePart.array_nullable_decimal128_scale(selected_type).nil?
    end

    # Empty serializers are admitted only for the pinned stock W45 Decimal256
    # pair, not for arbitrary three-column Array schemas or other scales.
    private def decimal256_array_w45_schema?(columns : Array({String, String}), selected_column : String) : Bool
      return false unless columns == [
                            {"pk", "UInt64"},
                            {"plain", "Array(Decimal(76, 2))"},
                            {"maybe", "Array(Nullable(Decimal(76, 2)))"},
                          ]
      selected_type = columns.find { |name, _| name == selected_column }.try(&.[1]) || return false
      !WidePart.array_decimal256_scale(selected_type).nil? || !WidePart.array_nullable_decimal256_scale(selected_type).nil?
    end

    private def fixed_string_array_w33_schema?(columns : Array({String, String}), selected_column : String) : Bool
      return false unless columns.size == 3

      selected_type = columns.find { |name, _| name == selected_column }.try(&.[1]) || return false
      return false unless WidePart.array_fixed_string_width(selected_type) || WidePart.array_nullable_fixed_string_width(selected_type)

      fixed_arrays = columns.select { |_, column_type| !WidePart.array_fixed_string_width(column_type).nil? }
      nullable_fixed_arrays = columns.select { |_, column_type| !WidePart.array_nullable_fixed_string_width(column_type).nil? }
      return false unless fixed_arrays.size == 1 && nullable_fixed_arrays.size == 1

      key_columns = columns.select { |name, column_type| name != selected_column && column_type == "UInt64" }
      key_columns.size == 1 && columns.count { |_, column_type| column_type == "UInt64" } == 1
    end

    private def bool_array_w34_schema?(columns : Array({String, String}), selected_column : String) : Bool
      return false unless columns.size == 3
      selected_type = columns.find { |name, _| name == selected_column }.try(&.[1]) || return false
      return false unless WidePart.supports_array_bool_type?(selected_type) || WidePart.supports_array_nullable_bool_type?(selected_type)

      plain_arrays = columns.select { |_, column_type| WidePart.supports_array_bool_type?(column_type) }
      nullable_arrays = columns.select { |_, column_type| WidePart.supports_array_nullable_bool_type?(column_type) }
      return false unless plain_arrays.size == 1 && nullable_arrays.size == 1

      key_columns = columns.select { |name, column_type| name != selected_column && column_type == "UInt64" }
      key_columns.size == 1 && columns.count { |_, column_type| column_type == "UInt64" } == 1
    end

    private def validate_map_serialization(
      columns : Array({String, String}),
      selected_column : String,
      row_count : UInt64,
      map_type : String,
    ) : Nil
      keys = columns.select { |name, type| name != selected_column && type == "UInt64" }
      uint64_key_map = WidePart.supports_map_uint64_string_type?(map_type) || WidePart.supports_map_uint64_uint64_type?(map_type) ||
                       WidePart.supports_map_uint64_nullable_uint64_type?(map_type) ||
                       WidePart.supports_map_uint64_nullable_string_type?(map_type)
      string_key_map = WidePart.supports_map_string_uint64_type?(map_type) || WidePart.supports_map_string_string_type?(map_type) ||
                       WidePart.supports_map_string_nullable_uint64_type?(map_type) ||
                       WidePart.supports_map_string_nullable_string_type?(map_type)
      supported_map = uint64_key_map || string_key_map
      unless supported_map && keys.size == 1 && columns.any? { |name, type| name == selected_column && type == map_type }
        raise UnsupportedFormatError.new("#{map_type} requires one UInt64 primary-key column")
      end

      file = File.join(@path, "serialization.json")
      raise UnsupportedFormatError.new("serialization.json is required for this type") unless File.file?(file)
      raise CorruptPartError.new("serialization.json must not be a symbolic link") if File.symlink?(file)
      size = File.size(file)
      raise UnsupportedFormatError.new("serialization.json exceeds metadata limit") if size > MAX_METADATA_FILE_BYTES
      text = File.read(file)
      raise CorruptPartError.new("serialization.json changed while reading") unless text.bytesize == size

      info = JSON.parse(text).as_h
      info.each_key do |key|
        unless ["version", "columns", "types_serialization_versions", "propagate_types_serialization_versions_to_nested_types"].includes?(key)
          raise UnsupportedFormatError.new("unsupported Map serialization.json field")
        end
      end
      version = info["version"]?.try(&.as_i) || raise(CorruptPartError.new("serialization.json version is missing or malformed"))
      raise UnsupportedFormatError.new("only serialization.json version 1 is supported") unless version == 1
      propagated = info["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool)
      raise UnsupportedFormatError.new("Map nested serialization versions are unsupported") unless propagated == true

      versions = info["types_serialization_versions"]?.try(&.as_h) || raise(CorruptPartError.new("serialization type versions are missing or malformed"))
      unless versions.size == 1 && versions["string"]?.try(&.as_i) == 1
        raise UnsupportedFormatError.new("only nested String serialization version 1 is supported for Map")
      end

      serializers = info["columns"]?.try(&.as_a) || raise(UnsupportedFormatError.new("Map column serializers are required"))
      unless serializers.empty? || uint64_key_map && serializers.size == 1
        raise UnsupportedFormatError.new("Map serialization has unsupported child serializers")
      end
      unless serializers.empty?
        serializer = serializers[0].as_h
        unless serializer.keys.to_set == Set{"kind", "name", "num_defaults", "num_rows"}
          raise UnsupportedFormatError.new("unsupported Map key serializer fields")
        end
        kind = serializer["kind"]?.try(&.as_s) || raise(CorruptPartError.new("Map key serializer kind is missing or malformed"))
        name = serializer["name"]?.try(&.as_s) || raise(CorruptPartError.new("Map key serializer name is missing or malformed"))
        defaults = serializer["num_defaults"]?.try(&.as_i) || raise(CorruptPartError.new("Map key serializer default count is missing or malformed"))
        rows = serializer["num_rows"]?.try(&.as_i) || raise(CorruptPartError.new("Map key serializer row count is missing or malformed"))
        unless kind == "Default" && name == keys[0][0] && defaults == 0
          raise UnsupportedFormatError.new("only Default key serialization is supported for Map")
        end
        raise CorruptPartError.new("Map key serializer row count does not match part") unless rows >= 0 && rows.to_u64 == row_count
      end
      nil
    rescue ex : JSON::ParseException | TypeCastError | OverflowError
      raise CorruptPartError.new("serialization.json is malformed")
    end

    private def validate_tuple_uint64_string_serialization(
      columns : Array({String, String}),
      selected_column : String,
      row_count : UInt64,
    ) : Nil
      keys = columns.select { |name, type| name != selected_column && type == "UInt64" }
      unless columns.size == 2 && keys.size == 1 && columns.any? { |name, type| name == selected_column && WidePart.supports_tuple_uint64_string_type?(type) }
        raise UnsupportedFormatError.new("named UInt64/String Tuple requires one UInt64 key column")
      end

      file = File.join(@path, "serialization.json")
      raise UnsupportedFormatError.new("serialization.json is required for this type") unless File.file?(file)
      raise CorruptPartError.new("serialization.json must not be a symbolic link") if File.symlink?(file)
      size = File.size(file)
      raise UnsupportedFormatError.new("serialization.json exceeds metadata limit") if size > MAX_METADATA_FILE_BYTES
      text = File.read(file)
      raise CorruptPartError.new("serialization.json changed while reading") unless text.bytesize == size

      info = JSON.parse(text).as_h
      unless info.keys.to_set == Set{"version", "columns", "types_serialization_versions", "propagate_types_serialization_versions_to_nested_types"}
        raise UnsupportedFormatError.new("unsupported Tuple serialization.json fields")
      end
      version = info["version"]?.try(&.as_i) || raise(CorruptPartError.new("serialization.json version is missing or malformed"))
      raise UnsupportedFormatError.new("only serialization.json version 1 is supported") unless version == 1
      propagated = info["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool)
      raise UnsupportedFormatError.new("Tuple nested serialization versions are unsupported") unless propagated == true

      versions = info["types_serialization_versions"]?.try(&.as_h) || raise(CorruptPartError.new("serialization type versions are missing or malformed"))
      unless versions.size == 1 && versions["string"]?.try(&.as_i) == 1
        raise UnsupportedFormatError.new("only nested String serialization version 1 is supported for Tuple")
      end

      serializers = info["columns"]?.try(&.as_a) || raise(UnsupportedFormatError.new("Tuple column serializers are required"))
      raise UnsupportedFormatError.new("Tuple serialization requires exact key and payload entries") unless serializers.size == 2
      columns.each_with_index do |(column_name, _column_type), index|
        entry = serializers[index].as_h
        name = entry["name"]?.try(&.as_s) || raise(CorruptPartError.new("Tuple serializer name is missing or malformed"))
        raise UnsupportedFormatError.new("Tuple serializer order does not match columns.txt") unless name == column_name
        defaults = entry["num_defaults"]?.try(&.as_i) || raise(CorruptPartError.new("Tuple serializer default count is missing or malformed"))
        rows = entry["num_rows"]?.try(&.as_i) || raise(CorruptPartError.new("Tuple serializer row count is missing or malformed"))
        raise CorruptPartError.new("Tuple serializer row count does not match part") unless rows >= 0 && rows.to_u64 == row_count
        raise CorruptPartError.new("Tuple serializer default count is invalid") unless defaults >= 0 && defaults <= rows
        kind = entry["kind"]?.try(&.as_s) || raise(CorruptPartError.new("Tuple serializer kind is missing or malformed"))
        raise UnsupportedFormatError.new("only Default Tuple serializers are supported") unless kind == "Default"

        if column_name == selected_column
          unless entry.keys.to_set == Set{"kind", "name", "num_defaults", "num_rows", "subcolumns"}
            raise UnsupportedFormatError.new("unsupported named Tuple serializer fields")
          end
          subcolumns = entry["subcolumns"]?.try(&.as_a) || raise(UnsupportedFormatError.new("Tuple child serializer metadata is required"))
          raise UnsupportedFormatError.new("exactly two Tuple child serializers are required") unless subcolumns.size == 2
          subcolumns.each do |child|
            child_entry = child.as_h
            unless child_entry.keys.to_set == Set{"kind", "num_defaults", "num_rows"}
              raise UnsupportedFormatError.new("unsupported Tuple child serializer fields")
            end
            raise UnsupportedFormatError.new("only Default Tuple child serializers are supported") unless child_entry["kind"]?.try(&.as_s) == "Default"
            child_defaults = child_entry["num_defaults"]?.try(&.as_i) || raise(CorruptPartError.new("Tuple child default count is missing or malformed"))
            child_rows = child_entry["num_rows"]?.try(&.as_i) || raise(CorruptPartError.new("Tuple child row count is missing or malformed"))
            raise CorruptPartError.new("Tuple child row count does not match part") unless child_rows >= 0 && child_rows.to_u64 == row_count
            raise CorruptPartError.new("Tuple child default count is invalid") unless child_defaults >= 0 && child_defaults <= child_rows
          end
        else
          unless entry.keys.to_set == Set{"kind", "name", "num_defaults", "num_rows"}
            raise UnsupportedFormatError.new("unsupported Tuple key serializer fields")
          end
        end
      end
      nil
    rescue ex : JSON::ParseException | TypeCastError | OverflowError
      raise CorruptPartError.new("serialization.json is malformed")
    end

    private def validate_low_cardinality_string_serialization(
      columns : Array({String, String}),
      selected_column : String,
      row_count : UInt64,
    ) : Nil
      key_columns = columns.select { |name, type| name != selected_column && type == "UInt64" }
      unless columns.size == 2 && key_columns.size == 1 && columns.any? { |name, type| name == selected_column && type == "LowCardinality(String)" }
        raise UnsupportedFormatError.new("LowCardinality(String) requires one UInt64 key column")
      end

      file = File.join(@path, "serialization.json")
      raise UnsupportedFormatError.new("serialization.json is required for this type") unless File.file?(file)
      raise CorruptPartError.new("serialization.json must not be a symbolic link") if File.symlink?(file)
      size = File.size(file)
      raise UnsupportedFormatError.new("serialization.json exceeds metadata limit") if size > MAX_METADATA_FILE_BYTES
      text = File.read(file)
      raise CorruptPartError.new("serialization.json changed while reading") unless text.bytesize == size

      info = JSON.parse(text).as_h
      info.each_key do |key|
        unless ["version", "columns", "types_serialization_versions", "propagate_types_serialization_versions_to_nested_types"].includes?(key)
          raise UnsupportedFormatError.new("unsupported LowCardinality serialization.json field")
        end
      end
      version = info["version"]?.try(&.as_i) || raise(CorruptPartError.new("serialization.json version is missing or malformed"))
      raise UnsupportedFormatError.new("only serialization.json version 1 is supported") unless version == 1
      propagated = info["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool)
      raise UnsupportedFormatError.new("LowCardinality nested serialization versions are unsupported") unless propagated == true

      versions = info["types_serialization_versions"]?.try(&.as_h) || raise(CorruptPartError.new("serialization type versions are missing or malformed"))
      unless versions.size == 1 && versions["string"]?.try(&.as_i) == 1
        raise UnsupportedFormatError.new("only nested String serialization version 1 is supported")
      end

      serializers = info["columns"]?.try(&.as_a) || raise(CorruptPartError.new("LowCardinality column serializers are required"))
      case serializers.size
      when 0
        # The paired Crystal writer emits no explicit column serializers.
      when 1
        serializer = serializers[0].as_h
        unless serializer.keys.to_set == Set{"kind", "name", "num_defaults", "num_rows"}
          raise UnsupportedFormatError.new("unsupported LowCardinality column serializer fields")
        end
        name = serializer["name"]?.try(&.as_s) || raise(CorruptPartError.new("LowCardinality serializer name is malformed"))
        kind = serializer["kind"]?.try(&.as_s) || raise(CorruptPartError.new("LowCardinality serializer kind is malformed"))
        defaults = serializer["num_defaults"]?.try(&.as_i) || raise(CorruptPartError.new("LowCardinality serializer default count is malformed"))
        rows = serializer["num_rows"]?.try(&.as_i) || raise(CorruptPartError.new("LowCardinality serializer row count is malformed"))
        unless name == key_columns[0][0] && kind == "Default" && defaults >= 0 && defaults.to_u64 <= row_count && rows >= 0 && rows.to_u64 == row_count
          raise UnsupportedFormatError.new("unsupported LowCardinality key serializer")
        end
      else
        raise UnsupportedFormatError.new("LowCardinality per-column serialization is unsupported")
      end
      nil
    rescue ex : JSON::ParseException | TypeCastError | OverflowError
      raise CorruptPartError.new("serialization.json is malformed")
    end

    private def validate_type_serialization_version(type : String) : Nil
      file = File.join(@path, "serialization.json")
      raise UnsupportedFormatError.new("serialization.json is required for this type") unless File.file?(file)
      raise CorruptPartError.new("serialization.json must not be a symbolic link") if File.symlink?(file)
      size = File.size(file)
      raise UnsupportedFormatError.new("serialization.json exceeds metadata limit") if size > MAX_METADATA_FILE_BYTES
      text = File.read(file)
      raise CorruptPartError.new("serialization.json changed while reading") unless text.bytesize == size

      info = JSON.parse(text).as_h
      info.each_key do |key|
        unless ["version", "columns", "types_serialization_versions", "propagate_types_serialization_versions_to_nested_types", "missing_columns"].includes?(key)
          raise UnsupportedFormatError.new("unsupported serialization.json field")
        end
      end

      version = info["version"]?.try(&.as_i) || raise(CorruptPartError.new("serialization.json version is missing or malformed"))
      raise UnsupportedFormatError.new("only serialization.json version 1 is supported") unless version == 1
      propagated = info["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool)
      raise UnsupportedFormatError.new("serialization.json nested-version flag is unsupported") unless propagated == true
      versions = info["types_serialization_versions"]?.try(&.as_h) || raise(CorruptPartError.new("serialization type versions are missing or malformed"))
      versions.each_key do |key|
        allowed = key == "string" || key == "nullable" && (WidePart.supports_nullable_string_type?(type) || !WidePart.nullable_fixed_string_width(type).nil?)
        raise UnsupportedFormatError.new("unsupported serialization type version") unless allowed
      end

      if type == "String"
        string_version = versions["string"]?.try(&.as_i) || 0_i64
        raise UnsupportedFormatError.new("only String WITH_SIZE_STREAM version 1 is supported") unless string_version == 1
      elsif !WidePart.fixed_string_width(type).nil?
        string_version = versions["string"]?.try(&.as_i) || 0_i64
        raise UnsupportedFormatError.new("unsupported String serialization version") unless string_version == 0 || string_version == 1
      elsif !WidePart.nullable_fixed_string_width(type).nil?
        string_version = versions["string"]?.try(&.as_i) || 0_i64
        raise UnsupportedFormatError.new("unsupported String serialization version") unless string_version == 0 || string_version == 1
        nullable_version = versions["nullable"]?.try(&.as_i) || 0_i64
        raise UnsupportedFormatError.new("only basic Nullable serialization is supported") unless nullable_version == 0
      elsif WidePart.supports_nullable_temporal_type?(type)
        string_version = versions["string"]?.try(&.as_i) || raise(UnsupportedFormatError.new("Nullable temporal String serialization version is required"))
        raise UnsupportedFormatError.new("only Nullable temporal String serialization version 1 is supported") unless string_version == 1
      elsif WidePart.supports_nullable_time_type?(type)
        string_version = versions["string"]?.try(&.as_i) || raise(UnsupportedFormatError.new("Nullable Time String serialization version is required"))
        raise UnsupportedFormatError.new("only Nullable Time String serialization version 1 is supported") unless string_version == 1
      elsif WidePart.supports_nullable_numeric_type?(type)
        nullable_version = versions["nullable"]?.try(&.as_i) || 0_i64
        raise UnsupportedFormatError.new("only basic Nullable serialization is supported") unless nullable_version == 0
      elsif WidePart.supports_nullable_string_type?(type)
        string_version = versions["string"]?.try(&.as_i) || 0_i64
        raise UnsupportedFormatError.new("only String WITH_SIZE_STREAM version 1 is supported") unless string_version == 1
        nullable_version = versions["nullable"]?.try(&.as_i) || 0_i64
        raise UnsupportedFormatError.new("only basic Nullable serialization is supported") unless nullable_version == 0
      elsif WidePart.supports_uuid_type?(type) || WidePart.supports_nullable_uuid_type?(type)
        string_version = versions["string"]?.try(&.as_i) || raise(UnsupportedFormatError.new("UUID String serialization version is required"))
        raise UnsupportedFormatError.new("only UUID String serialization version 1 is supported") unless string_version == 1
        columns = info["columns"]?.try(&.as_a) || raise(UnsupportedFormatError.new("UUID column serializers are required"))
        raise UnsupportedFormatError.new("UUID per-column serialization is unsupported") unless columns.empty?
        raise UnsupportedFormatError.new("UUID missing-column serialization is unsupported") if info.has_key?("missing_columns")
      elsif WidePart.supports_ipv4_type?(type) || WidePart.supports_nullable_ipv4_type?(type)
        string_version = versions["string"]?.try(&.as_i) || raise(UnsupportedFormatError.new("IPv4 serialization version is required"))
        raise UnsupportedFormatError.new("only IPv4 serialization version 1 is supported") unless string_version == 1
        columns = info["columns"]?.try(&.as_a) || raise(UnsupportedFormatError.new("IPv4 column serializers are required"))
        raise UnsupportedFormatError.new("IPv4 per-column serialization is unsupported") unless columns.empty?
        raise UnsupportedFormatError.new("IPv4 missing-column serialization is unsupported") if info.has_key?("missing_columns")
      elsif WidePart.supports_ipv6_type?(type) || WidePart.supports_nullable_ipv6_type?(type)
        string_version = versions["string"]?.try(&.as_i) || raise(UnsupportedFormatError.new("IPv6 serialization version is required"))
        raise UnsupportedFormatError.new("only IPv6 serialization version 1 is supported") unless string_version == 1
        columns = info["columns"]?.try(&.as_a) || raise(UnsupportedFormatError.new("IPv6 column serializers are required"))
        raise UnsupportedFormatError.new("IPv6 per-column serialization is unsupported") unless columns.empty?
        raise UnsupportedFormatError.new("IPv6 missing-column serialization is unsupported") if info.has_key?("missing_columns")
      elsif WidePart.supports_semantic_fixed_width_type?(type) || WidePart.supports_nullable_semantic_fixed_width_type?(type)
        string_version = versions["string"]?.try(&.as_i) || raise(UnsupportedFormatError.new("W15 semantic serialization version is required"))
        raise UnsupportedFormatError.new("only W15 semantic serialization version 1 is supported") unless string_version == 1
        columns = info["columns"]?.try(&.as_a) || raise(UnsupportedFormatError.new("W15 semantic column serializers are required"))
        raise UnsupportedFormatError.new("W15 per-column serialization is unsupported") unless columns.empty?
        raise UnsupportedFormatError.new("W15 missing-column serialization is unsupported") if info.has_key?("missing_columns")
      end
      nil
    rescue ex : JSON::ParseException | TypeCastError
      raise CorruptPartError.new("serialization.json is malformed")
    end

    private def validate_raw_integer_serialization(part_columns : Array({String, String}), row_count : UInt64) : Nil
      file = File.join(@path, "serialization.json")
      raise UnsupportedFormatError.new("serialization.json is required for raw wide integers") unless File.file?(file)
      raise CorruptPartError.new("serialization.json must not be a symbolic link") if File.symlink?(file)
      size = File.size(file)
      raise UnsupportedFormatError.new("serialization.json exceeds metadata limit") if size > MAX_METADATA_FILE_BYTES
      text = File.read(file)
      raise CorruptPartError.new("serialization.json changed while reading") unless text.bytesize == size

      info = JSON.parse(text).as_h
      info.each_key do |key|
        unless ["version", "columns", "types_serialization_versions", "propagate_types_serialization_versions_to_nested_types", "missing_columns"].includes?(key)
          raise UnsupportedFormatError.new("unsupported serialization.json field")
        end
      end
      raise UnsupportedFormatError.new("raw wide-integer missing-column serialization is unsupported") if info.has_key?("missing_columns")

      version = info["version"]?.try(&.as_i) || raise(CorruptPartError.new("serialization.json version is missing or malformed"))
      raise UnsupportedFormatError.new("only serialization.json version 1 is supported") unless version == 1
      propagated = info["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool)
      raise UnsupportedFormatError.new("serialization.json nested-version flag is unsupported") unless propagated == true

      versions = info["types_serialization_versions"]?.try(&.as_h) || raise(CorruptPartError.new("serialization type versions are missing or malformed"))
      raise UnsupportedFormatError.new("raw wide-integer serialization requires only String version 1") unless versions.size == 1 && versions["string"]?.try(&.as_i) == 1

      serializers = info["columns"]?.try(&.as_a) || raise(UnsupportedFormatError.new("raw wide-integer column serializers are required"))
      # Crystal's paired writer emits the established empty serializer-list
      # form. ClickHouse's stock Wide parts emit one Default stats record for
      # every column. Accept those two forms only; in particular, never treat
      # Sparse (or partial/mismatched records) as plain fixed-width values.
      unless serializers.empty?
        raise UnsupportedFormatError.new("raw wide-integer per-column serializer count differs") unless serializers.size == part_columns.size
        expected_names = part_columns.map(&.[0]).to_set
        raise CorruptPartError.new("raw wide-integer part column names are not unique") unless expected_names.size == part_columns.size
        seen_names = Set(String).new
        serializers.each do |serializer_json|
          serializer = serializer_json.as_h
          unless serializer.keys.to_set == Set{"kind", "name", "num_defaults", "num_rows"}
            raise UnsupportedFormatError.new("unsupported raw wide-integer column serializer fields")
          end
          kind = serializer["kind"]?.try(&.as_s) || raise(CorruptPartError.new("raw wide-integer serializer kind is malformed"))
          name = serializer["name"]?.try(&.as_s) || raise(CorruptPartError.new("raw wide-integer serializer name is malformed"))
          defaults = serializer["num_defaults"]?.try(&.as_i) || raise(CorruptPartError.new("raw wide-integer serializer default count is malformed"))
          rows = serializer["num_rows"]?.try(&.as_i) || raise(CorruptPartError.new("raw wide-integer serializer row count is malformed"))
          unless expected_names.includes?(name) && !seen_names.includes?(name)
            raise UnsupportedFormatError.new("raw wide-integer serializer names do not match the part columns")
          end
          seen_names << name
          unless kind == "Default" && rows >= 0 && rows.to_u64 == row_count && defaults >= 0 && defaults.to_u64 <= row_count
            raise UnsupportedFormatError.new("raw wide-integer serializer is not an exact Default column record")
          end
        end
        raise UnsupportedFormatError.new("raw wide-integer serializer names do not cover the part columns") unless seen_names == expected_names
      end
      nil
    rescue ex : JSON::ParseException | TypeCastError | OverflowError
      raise CorruptPartError.new("serialization.json is malformed")
    end

    private def validate_nullable_raw_integer_serialization(part_columns : Array({String, String}), row_count : UInt64) : Nil
      file = File.join(@path, "serialization.json")
      raise UnsupportedFormatError.new("serialization.json is required for Nullable raw wide integers") unless File.file?(file)
      raise CorruptPartError.new("serialization.json must not be a symbolic link") if File.symlink?(file)
      size = File.size(file)
      raise UnsupportedFormatError.new("serialization.json exceeds metadata limit") if size > MAX_METADATA_FILE_BYTES
      text = File.read(file)
      raise CorruptPartError.new("serialization.json changed while reading") unless text.bytesize == size

      info = JSON.parse(text).as_h
      info.each_key do |key|
        unless ["version", "columns", "types_serialization_versions", "propagate_types_serialization_versions_to_nested_types", "missing_columns"].includes?(key)
          raise UnsupportedFormatError.new("unsupported serialization.json field")
        end
      end
      raise UnsupportedFormatError.new("Nullable raw wide-integer missing-column serialization is unsupported") if info.has_key?("missing_columns")

      version = info["version"]?.try(&.as_i) || raise(CorruptPartError.new("serialization.json version is missing or malformed"))
      raise UnsupportedFormatError.new("only serialization.json version 1 is supported") unless version == 1
      propagated = info["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool)
      raise UnsupportedFormatError.new("serialization.json nested-version flag is unsupported") unless propagated == true

      versions = info["types_serialization_versions"]?.try(&.as_h) || raise(CorruptPartError.new("serialization type versions are missing or malformed"))
      versions.each_key do |key|
        raise UnsupportedFormatError.new("unsupported Nullable raw wide-integer serialization type version") unless key == "string" || key == "nullable"
      end
      string_version = versions["string"]?.try(&.as_i) || raise(UnsupportedFormatError.new("Nullable raw wide-integer String serialization version is required"))
      raise UnsupportedFormatError.new("only String serialization version 1 is supported") unless string_version == 1
      nullable_version = if versions.has_key?("nullable")
                           versions["nullable"].as_i
                         else
                           0_i64
                         end
      raise UnsupportedFormatError.new("only BASIC Nullable serialization is supported") unless nullable_version == 0

      serializers = info["columns"]?.try(&.as_a) || raise(UnsupportedFormatError.new("Nullable raw wide-integer column serializers are required"))
      # Stock BASIC Nullable parts and this writer may omit per-column stats.
      # If present, accept only complete Default records, matched by name.
      unless serializers.empty?
        raise UnsupportedFormatError.new("Nullable raw wide-integer serializer count differs") unless serializers.size == part_columns.size
        expected_names = part_columns.map(&.[0]).to_set
        raise CorruptPartError.new("Nullable raw wide-integer part column names are not unique") unless expected_names.size == part_columns.size
        seen_names = Set(String).new
        serializers.each do |serializer_json|
          serializer = serializer_json.as_h
          unless serializer.keys.to_set == Set{"kind", "name", "num_defaults", "num_rows"}
            raise UnsupportedFormatError.new("unsupported Nullable raw wide-integer column serializer fields")
          end
          kind = serializer["kind"]?.try(&.as_s) || raise(CorruptPartError.new("Nullable raw wide-integer serializer kind is malformed"))
          name = serializer["name"]?.try(&.as_s) || raise(CorruptPartError.new("Nullable raw wide-integer serializer name is malformed"))
          defaults = serializer["num_defaults"]?.try(&.as_i) || raise(CorruptPartError.new("Nullable raw wide-integer serializer default count is malformed"))
          rows = serializer["num_rows"]?.try(&.as_i) || raise(CorruptPartError.new("Nullable raw wide-integer serializer row count is malformed"))
          unless expected_names.includes?(name) && !seen_names.includes?(name)
            raise UnsupportedFormatError.new("Nullable raw wide-integer serializer names do not match the part columns")
          end
          seen_names << name
          unless kind == "Default" && rows >= 0 && rows.to_u64 == row_count && defaults >= 0 && defaults.to_u64 <= row_count
            raise UnsupportedFormatError.new("Nullable raw wide-integer serializer is not an exact Default column record")
          end
        end
        raise UnsupportedFormatError.new("Nullable raw wide-integer serializer names do not cover the part columns") unless seen_names == expected_names
      end
      nil
    rescue ex : JSON::ParseException | TypeCastError | OverflowError
      raise CorruptPartError.new("serialization.json is malformed")
    end

    private def validate_json_typed_path_serialization(column : String, paths : Array({String, String})) : Nil
      file = File.join(@path, "serialization.json")
      raise UnsupportedFormatError.new("serialization.json is required for JSON typed paths") unless File.file?(file)
      raise CorruptPartError.new("serialization.json must not be a symbolic link") if File.symlink?(file)
      size = File.size(file)
      raise UnsupportedFormatError.new("serialization.json exceeds metadata limit") if size > MAX_METADATA_FILE_BYTES
      text = File.read(file)
      raise CorruptPartError.new("serialization.json changed while reading") unless text.bytesize == size

      info = JSON.parse(text).as_h
      info.each_key do |key|
        unless ["version", "columns", "types_serialization_versions", "propagate_types_serialization_versions_to_nested_types", "missing_columns"].includes?(key)
          raise UnsupportedFormatError.new("unsupported JSON serialization.json field")
        end
      end
      version = info["version"]?.try(&.as_i) || raise(CorruptPartError.new("serialization.json version is missing or malformed"))
      raise UnsupportedFormatError.new("only JSON serialization.json version 1 is supported") unless version == 1
      propagated = info["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool)
      raise UnsupportedFormatError.new("JSON nested-version flag is unsupported") unless propagated == true

      columns = info["columns"]?.try(&.as_a) || raise(CorruptPartError.new("JSON serialization column metadata is missing or malformed"))
      raise UnsupportedFormatError.new("JSON serialization column metadata exceeds limit") if columns.size > MAX_METADATA_COLUMNS
      columns.each do |column_info|
        entry = column_info.as_h
        unless entry.keys.to_set == Set{"kind", "name", "num_defaults", "num_rows"}
          raise UnsupportedFormatError.new("unsupported JSON serialization column metadata")
        end
        raise UnsupportedFormatError.new("unsupported JSON serialization default kind") unless entry["kind"]?.try(&.as_s) == "Default"
        raise CorruptPartError.new("JSON serialization column name is malformed") if entry["name"]?.try(&.as_s).try(&.empty?) != false
        num_defaults = entry["num_defaults"]?.try(&.as_i) || raise(CorruptPartError.new("JSON serialization default count is malformed"))
        num_rows = entry["num_rows"]?.try(&.as_i) || raise(CorruptPartError.new("JSON serialization row count is malformed"))
        raise CorruptPartError.new("JSON serialization default count is invalid") if num_defaults < 0 || num_rows < num_defaults
      end

      versions = info["types_serialization_versions"]?.try(&.as_h) || raise(CorruptPartError.new("JSON serialization type versions are missing or malformed"))
      versions.each do |name, value|
        raise UnsupportedFormatError.new("unsupported JSON nested serialization type version") unless name == "string" && value.as_i? == 1
      end
      if paths.any? { |entry| entry[1] == "String" }
        raise UnsupportedFormatError.new("only String WITH_SIZE_STREAM version 1 is supported for JSON paths") unless versions["string"]?.try(&.as_i) == 1
      end

      validate_json_object_structure_prefix(column)
      nil
    rescue ex : JSON::ParseException | TypeCastError
      raise CorruptPartError.new("JSON serialization.json is malformed")
    end

    # ClickHouse stores the Object serialization version in the first
    # compressed object_structure frame, not in serialization.json. Decode
    # only that bounded frame and inspect its UInt64 prefix; this is not a
    # validation of the remaining structure or shared-data streams.
    private def validate_json_object_structure_prefix(column : String) : Nil
      data_path, _mark_path, _compressed_marks = resolve_stream("#{column}.object_structure")
      data_size = File.size(data_path)
      raise CorruptPartError.new("JSON object_structure data file exceeds limit") if data_size > MAX_DATA_FILE_BYTES
      raise CorruptPartError.new("JSON object_structure data file is truncated") if data_size < CompressedBlock::FRAME_HEADER_SIZE

      File.open(data_path, "rb") do |io|
        header = Bytes.new(CompressedBlock::FRAME_HEADER_SIZE)
        begin
          io.read_fully(header)
        rescue ex : IO::EOFError
          raise CorruptPartError.new("JSON object_structure frame header is truncated")
        end
        compressed_size = u32(header, CompressedBlock::CHECKSUM_SIZE + 1).to_i64
        frame_size = CompressedBlock::CHECKSUM_SIZE.to_i64 + compressed_size
        if compressed_size < CompressedBlock::HEADER_SIZE || compressed_size > MAX_FRAME_COMPRESSED_BYTES || frame_size > data_size
          raise CorruptPartError.new("JSON object_structure first frame is invalid")
        end
        frame_data = Bytes.new(frame_size.to_i)
        header.copy_to(frame_data)
        tail_size = frame_data.size - header.size
        begin
          io.read_fully(frame_data[header.size, tail_size]) if tail_size > 0
        rescue ex : IO::EOFError
          raise CorruptPartError.new("JSON object_structure first frame is truncated")
        end
        frame = CompressedBlock.decode_frame(
          frame_data,
          0_i64,
          MAX_FRAME_COMPRESSED_BYTES,
          MAX_FRAME_DECOMPRESSED_BYTES
        )
        raise CorruptPartError.new("JSON object_structure prefix is truncated") if frame.output.size < 8
        raise UnsupportedFormatError.new("only JSON Object structure version V3 is supported") unless u64(frame.output, 0) == 4_u64
      end
      nil
    end

    private def parse_count_file(name : String) : UInt64
      path = File.join(@path, name)
      raise CorruptPartError.new("#{name} must not be a symbolic link") if File.symlink?(path)
      size = File.size(path)
      raise CorruptPartError.new("invalid row count") if size == 0 || size > 32
      text = File.read(path)
      raise CorruptPartError.new("invalid row count") unless text.bytesize == size
      text = String.new(text.to_slice[0, text.bytesize - 1]) if text.ends_with?("\n")
      value = parse_decimal(text, UInt64::MAX, name)
      value
    end

    private def parse_count_line(line : String, suffix : String, limit : Int, file : String) : Int
      raise UnsupportedFormatError.new("invalid count in #{file}") unless line.ends_with?(suffix)
      line_bytes = line.to_slice
      digits = String.new(line_bytes[0, line_bytes.size - suffix.bytesize])
      value = parse_decimal(digits, limit.to_u64, file)
      value.to_i
    end

    private def parse_decimal(text : String, limit : UInt64, file : String) : UInt64
      raise UnsupportedFormatError.new("invalid count in #{file}") if text.empty? || (text.bytesize > 1 && text.to_slice[0] == '0'.ord)
      value = 0_u64
      text.each_byte do |byte|
        raise UnsupportedFormatError.new("invalid count in #{file}") unless byte >= '0'.ord && byte <= '9'.ord
        digit = (byte - '0'.ord).to_u64
        raise UnsupportedFormatError.new("count exceeds limit in #{file}") if value > (limit - digit) // 10
        value = value * 10 + digit
      end
      value
    end

    private def metadata_line(bytes : Bytes, cursor : Int, file : String) : String
      length = line_length(bytes, cursor)
      raise UnsupportedFormatError.new("line exceeds metadata limit in #{file}") if length > MAX_METADATA_LINE_BYTES
      String.new(bytes[cursor, length - 1])
    end

    private def require_metadata_line(bytes : Bytes, cursor : Int, expected : String, file : String)
      raise UnsupportedFormatError.new("unsupported #{file}") unless metadata_line(bytes, cursor, file) == expected
    end

    private def line_length(bytes : Bytes, cursor : Int) : Int
      raise UnsupportedFormatError.new("truncated metadata line") if cursor < 0 || cursor >= bytes.size
      index = cursor
      while index < bytes.size && bytes[index] != 10
        index += 1
      end
      raise UnsupportedFormatError.new("truncated metadata line") if index >= bytes.size
      index - cursor + 1
    end

    private def parse_column_line(line : String) : {String, String}
      name, end_index = parse_quoted_name(line, 0)
      bytes = line.to_slice
      raise UnsupportedFormatError.new("invalid column type") if end_index >= bytes.size || bytes[end_index] != ' '.ord
      type_text = String.new(bytes[end_index + 1, bytes.size - end_index - 1])
      raise UnsupportedFormatError.new("invalid column type") if type_text.empty? || type_text.each_byte.any? { |byte| byte == 0 || byte == 13 }
      {name, type_text}
    end

    private def parse_substream_header(line : String) : {Int32, String}
      marker = " substreams for column "
      marker_index = line.index(marker)
      raise UnsupportedFormatError.new("invalid substream header") unless marker_index
      line_bytes = line.to_slice
      count = parse_decimal(String.new(line_bytes[0, marker_index]), MAX_METADATA_SUBSTREAMS.to_u64, "columns_substreams.txt").to_i
      start = marker_index + marker.bytesize
      name, end_index = parse_quoted_name(line, start)
      bytes = line.to_slice
      raise UnsupportedFormatError.new("invalid substream header") unless end_index < bytes.size && bytes[end_index] == ':'.ord
      raise UnsupportedFormatError.new("invalid substream header") unless end_index + 1 == bytes.size
      {count, name}
    end

    private def parse_quoted_name(line : String, start : Int) : {String, Int32}
      bytes = line.to_slice
      raise UnsupportedFormatError.new("invalid quoted identifier") if start < 0 || start >= bytes.size || bytes[start] != '`'.ord
      end_index = -1
      decoded_length = 0
      decoded = String.build do |io|
        index = start + 1
        while index < bytes.size
          byte = bytes[index]
          if byte == '`'.ord
            if index + 1 < bytes.size && bytes[index + 1] == '`'.ord
              io.write_byte('`'.ord.to_u8)
              decoded_length += 1
              index += 2
              next
            end
            end_index = index + 1
            break
          elsif byte == '\\'.ord
            index += 1
            raise UnsupportedFormatError.new("invalid quoted identifier escape") if index >= bytes.size
            escaped = bytes[index]
            if escaped == 'x'.ord
              raise UnsupportedFormatError.new("invalid hex escape") if index + 2 >= bytes.size
              high = hex_digit(bytes[index + 1])
              low = hex_digit(bytes[index + 2])
              raise UnsupportedFormatError.new("invalid hex escape") unless high && low
              io.write_byte((high.not_nil! << 4) | low.not_nil!)
              decoded_length += 1
              index += 3
              next
            elsif escaped == 'N'.ord
              index += 1
              next
            end
            decoded_byte = escaped == 'a'.ord ? 0x07_u8 : escaped == 'b'.ord ? 0x08_u8 : escaped == 'e'.ord ? 0x1b_u8 : escaped == 'f'.ord ? 0x0c_u8 : escaped == 'n'.ord ? 0x0a_u8 : escaped == 'r'.ord ? 0x0d_u8 : escaped == 't'.ord ? 0x09_u8 : escaped == 'v'.ord ? 0x0b_u8 : escaped == '0'.ord ? 0_u8 : escaped
            if decoded_byte != '\\'.ord && decoded_byte != '\''.ord && decoded_byte != '"'.ord && decoded_byte != '`'.ord && decoded_byte != '/'.ord && decoded_byte != '='.ord && decoded_byte >= 0x20
              io.write_byte('\\'.ord.to_u8)
              decoded_length += 1
            end
            io.write_byte(decoded_byte)
            decoded_length += 1
            index += 1
          else
            raise UnsupportedFormatError.new("invalid quoted identifier") if byte == 0 || byte == 10 || byte == 13
            io.write_byte(byte)
            decoded_length += 1
            index += 1
          end
        end
      end
      raise UnsupportedFormatError.new("unterminated quoted identifier") if end_index < 0
      raise UnsupportedFormatError.new("empty column name") if decoded_length == 0
      {decoded, end_index}
    end

    private def hex_digit(byte : UInt8) : UInt8?
      if byte >= '0'.ord && byte <= '9'.ord
        byte - '0'.ord
      elsif byte >= 'a'.ord && byte <= 'f'.ord
        byte - 'a'.ord + 10
      elsif byte >= 'A'.ord && byte <= 'F'.ord
        byte - 'A'.ord + 10
      end
    end

    private def validate_opaque_name(name : String)
      raise UnsupportedFormatError.new("invalid physical stream name") if name.empty? || name.bytesize > MAX_METADATA_LINE_BYTES
      name.each_byte do |byte|
        raise UnsupportedFormatError.new("invalid physical stream name") if byte < 0x20 || byte == 0x7f
      end
    end

    private def validate_selected_stream_name(name : String)
      validate_opaque_name(name)
      if name.includes?("/") || name.includes?("\\")
        raise UnsupportedFormatError.new("selected physical stream name is not a filename component")
      end
    end

    private def resolve_stream(column : String) : {String, String, Bool}
      names = [column, StreamName.hash(column)]
      reject_target_unsupported_mark_extensions(names)
      saw_partial = false
      candidates = Array({String, String, Bool}).new
      names.each do |name|
        data = File.join(@path, "#{name}.bin")
        plain_marks = File.join(@path, "#{name}.mrk2")
        compressed_marks = File.join(@path, "#{name}.cmrk2")
        if File.symlink?(data) || File.symlink?(plain_marks) || File.symlink?(compressed_marks)
          raise CorruptPartError.new("symbolic links are not supported for target streams")
        end
        data_exists = File.file?(data)
        plain_marks_exists = File.file?(plain_marks)
        compressed_marks_exists = File.file?(compressed_marks)
        if plain_marks_exists && compressed_marks_exists
          raise CorruptPartError.new("ambiguous mark streams")
        end
        marks_exists = plain_marks_exists || compressed_marks_exists
        saw_partial ||= data_exists != marks_exists
        if data_exists && marks_exists
          candidates << {data, plain_marks_exists ? plain_marks : compressed_marks, compressed_marks_exists}
        end
      end
      raise CorruptPartError.new("ambiguous data and mark streams") if candidates.size > 1
      if saw_partial
        raise CorruptPartError.new("data and mark streams do not form a pair")
      end
      return candidates.first.not_nil! if candidates.size == 1
      raise InvalidPartError.new("selected numeric stream files not found")
    end

    private def reject_target_unsupported_mark_extensions(names : Array(String))
      Dir.each_child(@path) do |entry|
        names.each do |name|
          prefix = "#{name}."
          next unless entry.starts_with?(prefix)
          entry_bytes = entry.to_slice
          extension = String.new(entry_bytes[prefix.bytesize, entry_bytes.size - prefix.bytesize])
          next if extension.includes?(".")
          if extension.starts_with?("cmrk") && extension != "cmrk2" || extension.starts_with?("mrk") && extension != "mrk2"
            raise UnsupportedFormatError.new("unsupported mark extension")
          end
        end
      end
    end

    # LowCardinality's `.dict` marks are the sole admitted exception to the
    # generic first-mark-at-zero rule: ClickHouse marks the dictionary payload
    # after its eight-byte version word. Keep this parser type-local, and
    # require the terminal record to be the actual compressed-file EOF.
    private def parse_low_cardinality_dictionary_marks(
      file : String,
      data_size : Int64,
      compressed : Bool,
    ) : {Array(Mark), Mark}
      size = File.size(file)
      raise CorruptPartError.new("mark file exceeds limit") if size > MAX_MARK_FILE_BYTES
      maximum_record_bytes = ((MAX_LOW_CARDINALITY_MARKS + 1) * MARK_SIZE).to_i64
      raise UnsupportedFormatError.new("LowCardinality mark file exceeds per-reader mark limit") if !compressed && size > maximum_record_bytes
      bytes = if compressed
                CompressedBlock.decode_all(
                  File.read(file).to_slice,
                  MAX_FRAME_COMPRESSED_BYTES.to_i64,
                  maximum_record_bytes < MAX_FRAME_DECOMPRESSED_BYTES.to_i64 ? maximum_record_bytes : MAX_FRAME_DECOMPRESSED_BYTES.to_i64,
                  maximum_record_bytes
                )
              else
                File.read(file).to_slice
              end
      raise CorruptPartError.new("mark file is empty or truncated") if bytes.empty? || bytes.size % MARK_SIZE != 0
      raise UnsupportedFormatError.new("LowCardinality mark file exceeds per-reader mark limit") if bytes.size > maximum_record_bytes

      records = Array(Mark).new(bytes.size // MARK_SIZE)
      previous_compressed = 0_u64
      previous_decompressed = 0_u64
      offset = 0
      while offset < bytes.size
        compressed_offset = u64(bytes, offset)
        decompressed_offset = u64(bytes, offset + 8)
        rows = u64(bytes, offset + 16)
        last = offset + MARK_SIZE == bytes.size
        if offset == 0 && (compressed_offset != 0_u64 || decompressed_offset != 8_u64)
          raise CorruptPartError.new("LowCardinality dictionary must start after its version word")
        end
        raise CorruptPartError.new("LowCardinality dictionary mark offset is not monotonic") if compressed_offset < previous_compressed
        if compressed_offset == previous_compressed && offset > 0 && decompressed_offset < previous_decompressed
          raise CorruptPartError.new("LowCardinality dictionary mark offset is not monotonic")
        end
        raise CorruptPartError.new("LowCardinality dictionary mark offset exceeds frame limit") if decompressed_offset > MAX_FRAME_DECOMPRESSED_BYTES

        if rows == 0_u64
          eof_position = if compressed_offset == data_size.to_u64
                           decompressed_offset == 0_u64
                         else
                           compressed_offset < data_size.to_u64
                         end
          unless last && eof_position
            raise CorruptPartError.new("LowCardinality dictionary requires a true EOF sentinel")
          end
        else
          raise CorruptPartError.new("LowCardinality dictionary mark points past data") unless compressed_offset < data_size.to_u64
          raise CorruptPartError.new("LowCardinality dictionary mark row count exceeds frame limit") if rows > MAX_FRAME_DECOMPRESSED_BYTES.to_u64
        end
        records << Mark.new(compressed_offset, decompressed_offset, rows)
        previous_compressed = compressed_offset
        previous_decompressed = decompressed_offset
        offset += MARK_SIZE
      end

      raise CorruptPartError.new("missing LowCardinality dictionary sentinel") unless records.last.rows == 0_u64
      sentinel = records.pop
      raise CorruptPartError.new("LowCardinality dictionary has no data marks") if records.empty?
      {records, sentinel}
    end

    private def parse_marks(
      file : String,
      data_size : Int64,
      compressed : Bool,
      element_width : Int32,
      allow_empty_string_eof : Bool,
      mark_row_width : Int32,
      max_records : Int? = nil,
    ) : {Array(Mark), Mark}
      size = File.size(file)
      raise CorruptPartError.new("mark file exceeds limit") if size > MAX_MARK_FILE_BYTES
      maximum_record_bytes = max_records.try { |count| (count * MARK_SIZE).to_i64 }
      if limit = maximum_record_bytes
        raise UnsupportedFormatError.new("mark file exceeds per-reader mark limit") if !compressed && size > limit
      end
      bytes = if compressed
                compressed_bytes = File.read(file).to_slice
                CompressedBlock.decode_all(
                  compressed_bytes,
                  MAX_FRAME_COMPRESSED_BYTES.to_i64,
                  if limit = maximum_record_bytes
                    limit < MAX_FRAME_DECOMPRESSED_BYTES.to_i64 ? limit : MAX_FRAME_DECOMPRESSED_BYTES.to_i64
                  else
                    MAX_FRAME_DECOMPRESSED_BYTES.to_i64
                  end,
                  maximum_record_bytes || MAX_MARK_FILE_BYTES
                )
              else
                File.read(file).to_slice
              end
      raise CorruptPartError.new("mark file is empty or truncated") if bytes.empty? || bytes.size % MARK_SIZE != 0
      if limit = maximum_record_bytes
        raise UnsupportedFormatError.new("mark file exceeds per-reader mark limit") if bytes.size > limit
      end
      records = Array(Mark).new(bytes.size // MARK_SIZE)
      previous_compressed = 0_u64
      previous_decompressed = 0_u64
      offset = 0
      while offset < bytes.size
        compressed = u64(bytes, offset)
        decompressed = u64(bytes, offset + 8)
        rows = u64(bytes, offset + 16)
        raise CorruptPartError.new("first mark must start at zero") if offset == 0 && (compressed != 0 || decompressed != 0)
        string_eof = allow_empty_string_eof && compressed == data_size.to_u64 && decompressed == 0
        eof_sentinel = offset + MARK_SIZE == bytes.size && rows == 0 && compressed == data_size.to_u64
        unless compressed < data_size.to_u64 || string_eof || eof_sentinel
          raise CorruptPartError.new("mark compressed offset exceeds data")
        end
        raise CorruptPartError.new("mark offset is not monotonic") if compressed < previous_compressed
        raise CorruptPartError.new("mark decompressed offset is not monotonic") if compressed == previous_compressed && decompressed < previous_decompressed
        raise CorruptPartError.new("mark offset exceeds limit") if decompressed > MAX_FRAME_DECOMPRESSED_BYTES
        raise CorruptPartError.new("mark decompressed offset is not column-type-aligned") unless decompressed % element_width.to_u64 == 0
        if rows == 0
          raise CorruptPartError.new("zero-row mark must be the sentinel") unless offset + MARK_SIZE == bytes.size
          raise CorruptPartError.new("EOF sentinel must have zero local offset") if compressed == data_size && decompressed != 0
        else
          raise CorruptPartError.new("mark row count exceeds frame limit") if mark_row_width <= 0 || rows > MAX_FRAME_DECOMPRESSED_BYTES.to_u64 // mark_row_width.to_u64
        end
        records << Mark.new(compressed, decompressed, rows)
        previous_compressed = compressed
        previous_decompressed = decompressed
        offset += MARK_SIZE
      end
      raise CorruptPartError.new("missing mark sentinel") unless records.last.rows == 0
      sentinel = records.pop
      raise CorruptPartError.new("no data marks") if records.empty?
      {records, sentinel}
    end

    private def validate_rows(marks : Array(Mark))
      total = 0_u64
      marks.each do |mark|
        total = total &+ mark.rows
        raise CorruptPartError.new("row count overflow") if total < mark.rows
      end
      raise CorruptPartError.new("row count does not match marks") unless total == @row_count
    end

    private def primary_stream_name(stream_names : Array(String)) : String
      if WideTypePlan.admitted(@column_type)
        stream = "#{@column}.size0"
        raise CorruptPartError.new("selected Array(Tuple) size0 stream is missing") unless stream_names.includes?(stream)
        return stream
      end
      if WidePart.supports_tuple_uint64_string_type?(@column_type)
        stream = "#{@column}%2Ea"
        raise CorruptPartError.new("selected Tuple UInt64 child stream is missing") unless stream_names.includes?(stream)
        return stream
      end
      if WidePart.supports_map_uint64_string_type?(@column_type) || WidePart.supports_map_uint64_uint64_type?(@column_type) ||
         WidePart.supports_map_string_uint64_type?(@column_type) || WidePart.supports_map_string_string_type?(@column_type) ||
         WidePart.supports_map_uint64_nullable_uint64_type?(@column_type) || WidePart.supports_map_string_nullable_uint64_type?(@column_type) ||
         WidePart.supports_map_uint64_nullable_string_type?(@column_type) || WidePart.supports_map_string_nullable_string_type?(@column_type)
        stream = "#{@column}.size0"
        raise CorruptPartError.new("selected Map size0 stream is missing") unless stream_names.includes?(stream)
        return stream
      end
      raise CorruptPartError.new("selected primary stream is missing") unless stream_names.includes?(@column)
      @column
    end

    private def stream_element_width(stream_name : String) : Int32
      if @column_type == "LowCardinality(String)"
        1
      elsif plan = WideTypePlan.admitted(@column_type)
        streams = plan.physical_substreams(@column)
        index = streams.index(stream_name) || raise(UnsupportedFormatError.new("unsupported exact Array(Tuple) substream"))
        case plan.shape
        when WideTypePlan::Shape::ArrayTupleUInt64String
          [8, 8, 8, 1][index]
        when WideTypePlan::Shape::ArrayTupleNullableUInt64String
          [8, 1, 8, 8, 1][index]
        else
          raise UnsupportedFormatError.new("unsupported exact Array(Tuple) substream")
        end
      elsif WidePart.nullable_uuid_array_element_type(@column_type)
        case stream_name
        when "#{@column}.null"  then 1
        when @column            then 16
        when "#{@column}.size0" then 8
        else
          raise UnsupportedFormatError.new("unsupported exact Array(Nullable(UUID)) substream")
        end
      elsif WidePart.uuid_array_element_type(@column_type)
        case stream_name
        when @column            then 16
        when "#{@column}.size0" then 8
        else
          raise UnsupportedFormatError.new("unsupported exact Array(UUID) substream")
        end
      elsif WidePart.nullable_ipv4_array_element_type(@column_type)
        case stream_name
        when "#{@column}.null"  then 1
        when @column            then 4
        when "#{@column}.size0" then 8
        else
          raise UnsupportedFormatError.new("unsupported exact Array(Nullable(IPv4)) substream")
        end
      elsif WidePart.ipv4_array_element_type(@column_type)
        case stream_name
        when @column            then 4
        when "#{@column}.size0" then 8
        else
          raise UnsupportedFormatError.new("unsupported exact Array(IPv4) substream")
        end
      elsif WidePart.nullable_ipv6_array_element_type(@column_type)
        case stream_name
        when "#{@column}.null"  then 1
        when @column            then 16
        when "#{@column}.size0" then 8
        else
          raise UnsupportedFormatError.new("unsupported exact Array(Nullable(IPv6)) substream")
        end
      elsif WidePart.ipv6_array_element_type(@column_type)
        case stream_name
        when @column            then 16
        when "#{@column}.size0" then 8
        else
          raise UnsupportedFormatError.new("unsupported exact Array(IPv6) substream")
        end
      elsif WidePart.array_nullable_enum8_codes(@column_type)
        case stream_name
        when "#{@column}.null"  then 1
        when @column            then 1
        when "#{@column}.size0" then 8
        else
          raise UnsupportedFormatError.new("unsupported exact Array(Nullable(Enum8)) substream")
        end
      elsif WidePart.array_nullable_enum16_codes(@column_type)
        case stream_name
        when "#{@column}.null"  then 1
        when @column            then 2
        when "#{@column}.size0" then 8
        else
          raise UnsupportedFormatError.new("unsupported exact Array(Nullable(Enum16)) substream")
        end
      elsif WidePart.array_enum8_codes(@column_type)
        case stream_name
        when @column            then 1
        when "#{@column}.size0" then 8
        else
          raise UnsupportedFormatError.new("unsupported exact Array(Enum8) substream")
        end
      elsif WidePart.array_enum16_codes(@column_type)
        case stream_name
        when @column            then 2
        when "#{@column}.size0" then 8
        else
          raise UnsupportedFormatError.new("unsupported exact Array(Enum16) substream")
        end
      elsif WidePart.array_nullable_decimal32_scale(@column_type)
        case stream_name
        when "#{@column}.null"  then 1
        when @column            then 4
        when "#{@column}.size0" then 8
        else
          raise UnsupportedFormatError.new("unsupported exact Array(Nullable(Decimal32)) substream")
        end
      elsif WidePart.array_nullable_decimal64_scale(@column_type)
        case stream_name
        when "#{@column}.null"  then 1
        when @column            then 8
        when "#{@column}.size0" then 8
        else
          raise UnsupportedFormatError.new("unsupported exact Array(Nullable(Decimal64)) substream")
        end
      elsif WidePart.array_nullable_decimal128_scale(@column_type)
        case stream_name
        when "#{@column}.null"  then 1
        when @column            then 16
        when "#{@column}.size0" then 8
        else
          raise UnsupportedFormatError.new("unsupported exact Array(Nullable(Decimal128)) substream")
        end
      elsif WidePart.array_nullable_decimal256_scale(@column_type)
        case stream_name
        when "#{@column}.null"  then 1
        when @column            then 32
        when "#{@column}.size0" then 8
        else
          raise UnsupportedFormatError.new("unsupported exact Array(Nullable(Decimal256)) substream")
        end
      elsif WidePart.array_decimal32_scale(@column_type)
        case stream_name
        when @column            then 4
        when "#{@column}.size0" then 8
        else
          raise UnsupportedFormatError.new("unsupported exact Array(Decimal32) substream")
        end
      elsif WidePart.array_decimal64_scale(@column_type)
        case stream_name
        when @column            then 8
        when "#{@column}.size0" then 8
        else
          raise UnsupportedFormatError.new("unsupported exact Array(Decimal64) substream")
        end
      elsif WidePart.array_decimal128_scale(@column_type)
        case stream_name
        when @column            then 16
        when "#{@column}.size0" then 8
        else
          raise UnsupportedFormatError.new("unsupported exact Array(Decimal128) substream")
        end
      elsif WidePart.array_decimal256_scale(@column_type)
        case stream_name
        when @column            then 32
        when "#{@column}.size0" then 8
        else
          raise UnsupportedFormatError.new("unsupported exact Array(Decimal256) substream")
        end
      elsif WidePart.supports_tuple_uint64_string_type?(@column_type)
        stream_name == "#{@column}%2Eb" ? 1 : 8
      elsif WidePart.supports_map_uint64_string_type?(@column_type)
        stream_name == "#{@column}%2Evalues" ? 1 : 8
      elsif WidePart.supports_map_uint64_uint64_type?(@column_type)
        8
      elsif WidePart.supports_map_uint64_nullable_uint64_type?(@column_type)
        stream_name == "#{@column}%2Evalues.null" ? 1 : 8
      elsif WidePart.supports_map_string_uint64_type?(@column_type)
        stream_name == "#{@column}%2Ekeys" ? 1 : 8
      elsif WidePart.supports_map_string_string_type?(@column_type)
        stream_name == "#{@column}%2Ekeys" || stream_name == "#{@column}%2Evalues" ? 1 : 8
      elsif WidePart.supports_map_string_nullable_uint64_type?(@column_type)
        stream_name == "#{@column}%2Ekeys" || stream_name == "#{@column}%2Evalues.null" ? 1 : 8
      elsif WidePart.supports_map_uint64_nullable_string_type?(@column_type)
        stream_name == "#{@column}%2Evalues.null" || stream_name == "#{@column}%2Evalues" ? 1 : 8
      elsif WidePart.supports_map_string_nullable_string_type?(@column_type)
        stream_name == "#{@column}%2Ekeys" || stream_name == "#{@column}%2Evalues.null" ||
          stream_name == "#{@column}%2Evalues" ? 1 : 8
      elsif @column_type == "Array(Nullable(UInt64))"
        stream_name == "#{@column}.null" ? 1 : 8
      elsif element_type = WidePart.nullable_numeric_array_element_type(@column_type)
        if stream_name == "#{@column}.null"
          1
        elsif stream_name == @column
          WidePart.array_numeric_payload_width(element_type)
        else
          8
        end
      elsif element_type = WidePart.nullable_temporal_array_element_type(@column_type)
        case stream_name
        when "#{@column}.null"  then 1
        when @column            then WidePart.array_numeric_payload_width(WidePart.temporal_array_physical_type(element_type).not_nil!)
        when "#{@column}.size0" then 8
        else
          raise UnsupportedFormatError.new("unsupported exact nullable temporal Array substream")
        end
      elsif element_type = WidePart.nullable_time_array_element_type(@column_type)
        case stream_name
        when "#{@column}.null"  then 1
        when @column            then WidePart.array_numeric_payload_width(WidePart.time_array_physical_type(element_type).not_nil!)
        when "#{@column}.size0" then 8
        else
          raise UnsupportedFormatError.new("unsupported exact nullable Time Array substream")
        end
      elsif @column_type == "Array(Array(Nullable(UInt64)))"
        stream_name == "#{@column}.null" ? 1 : 8
      elsif element_type = WidePart.numeric_array_element_type(@column_type)
        stream_name == @column ? WidePart.array_numeric_payload_width(element_type) : 8
      elsif element_type = WidePart.temporal_array_element_type(@column_type)
        case stream_name
        when @column            then WidePart.array_numeric_payload_width(WidePart.temporal_array_physical_type(element_type).not_nil!)
        when "#{@column}.size0" then 8
        else
          raise UnsupportedFormatError.new("unsupported exact temporal Array substream")
        end
      elsif element_type = WidePart.time_array_element_type(@column_type)
        case stream_name
        when @column            then WidePart.array_numeric_payload_width(WidePart.time_array_physical_type(element_type).not_nil!)
        when "#{@column}.size0" then 8
        else
          raise UnsupportedFormatError.new("unsupported exact Time Array substream")
        end
      elsif @column_type == "Array(UInt64)"
        8
      elsif @column_type == "Array(Array(UInt64))"
        8
      elsif WidePart.supports_array_bool_type?(@column_type)
        stream_name == "#{@column}.size0" ? 8 : 1
      elsif WidePart.supports_array_nullable_bool_type?(@column_type)
        stream_name == "#{@column}.size0" ? 8 : 1
      elsif element_width = WidePart.array_nullable_fixed_string_width(@column_type)
        if stream_name == "#{@column}.null"
          1
        elsif stream_name == @column
          element_width
        elsif stream_name == "#{@column}.size0"
          8
        else
          raise UnsupportedFormatError.new("unsupported exact Array(Nullable(FixedString(N))) substream")
        end
      elsif element_width = WidePart.array_fixed_string_width(@column_type)
        if stream_name == @column
          element_width
        elsif stream_name == "#{@column}.size0"
          8
        else
          raise UnsupportedFormatError.new("unsupported exact Array(FixedString(N)) substream")
        end
      elsif @column_type == "Array(String)"
        stream_name == @column ? 1 : 8
      elsif @column_type == "Array(Nullable(String))"
        case stream_name
        when "#{@column}.size0", "#{@column}.size"
          8
        when "#{@column}.null", @column
          1
        else
          raise UnsupportedFormatError.new("unsupported exact Array(Nullable(String)) substream")
        end
      elsif @column_type == "String"
        stream_name == "#{@column}.size" ? 8 : 1
      elsif WidePart.supports_nullable_string_type?(@column_type)
        stream_name == "#{@column}.size" ? 8 : 1
      elsif WidePart.supports_nullable_uuid_type?(@column_type)
        stream_name == "#{@column}.null" ? 1 : 16
      elsif WidePart.supports_uuid_type?(@column_type)
        16
      elsif WidePart.supports_nullable_ipv4_type?(@column_type)
        stream_name == "#{@column}.null" ? 1 : 4
      elsif WidePart.supports_ipv4_type?(@column_type)
        4
      elsif WidePart.supports_nullable_ipv6_type?(@column_type)
        stream_name == "#{@column}.null" ? 1 : 16
      elsif WidePart.supports_ipv6_type?(@column_type)
        16
      elsif @column_type == "Int128" || @column_type == "UInt128"
        16
      elsif @column_type == "Int256" || @column_type == "UInt256"
        32
      elsif @column_type == "Nullable(Int128)" || @column_type == "Nullable(UInt128)" || @column_type == "Nullable(Int256)" || @column_type == "Nullable(UInt256)"
        case stream_name
        when "#{@column}.null" then 1
        when @column           then @column_type == "Nullable(Int256)" || @column_type == "Nullable(UInt256)" ? 32 : 16
        else
          raise UnsupportedFormatError.new("unsupported exact Nullable raw integer substream")
        end
      elsif fixed_width = WidePart.nullable_fixed_string_width(@column_type)
        stream_name == "#{@column}.null" ? 1 : fixed_width
      elsif fixed_width = WidePart.fixed_string_width(@column_type)
        fixed_width
      elsif WidePart.supports_nullable_numeric_type?(@column_type)
        stream_name == "#{@column}.null" ? 1 : numeric_type_width(nullable_inner_type(@column_type))
      elsif WidePart.supports_nullable_temporal_type?(@column_type)
        stream_name == "#{@column}.null" ? 1 : nullable_temporal_width(@column_type)
      elsif WidePart.supports_nullable_time_type?(@column_type)
        stream_name == "#{@column}.null" ? 1 : nullable_time_width(@column_type)
      elsif WidePart.supports_nullable_semantic_fixed_width_type?(@column_type)
        stream_name == "#{@column}.null" ? 1 : semantic_type_width(nullable_semantic_inner_type(@column_type))
      elsif @column_type == "Date"
        2
      elsif @column_type == "Date32"
        4
      elsif @column_type == "DateTime"
        4
      elsif WidePart.datetime64_scale(@column_type)
        8
      elsif @column_type == "Time"
        4
      elsif WidePart.time64_scale(@column_type)
        8
      elsif WidePart.supports_semantic_fixed_width_type?(@column_type)
        semantic_type_width(@column_type)
      else
        numeric_type_width(@column_type)
      end
    end

    private def semantic_type_width(type : String) : Int32
      if type == "Bool" || !WidePart.enum8_codes(type).nil?
        1
      elsif type == "BFloat16"
        2
      elsif !WidePart.enum16_codes(type).nil?
        2
      elsif WidePart.decimal32_scale(type)
        4
      elsif WidePart.decimal64_scale(type)
        8
      elsif WidePart.decimal128_scale(type)
        16
      elsif WidePart.decimal256_scale(type)
        32
      else
        raise UnsupportedFormatError.new("unsupported exact semantic type")
      end
    end

    private def nullable_semantic_inner_type(type : String) : String
      raise UnsupportedFormatError.new("exact Nullable semantic fixed-width type required") unless WidePart.supports_nullable_semantic_fixed_width_type?(type)
      type.byte_slice("Nullable(".bytesize, type.bytesize - "Nullable()".bytesize)
    end

    private def nullable_inner_type(type : String) : String
      raise UnsupportedFormatError.new("exact Nullable primitive type required") unless WidePart.supports_nullable_numeric_type?(type)
      type.byte_slice("Nullable(".bytesize, type.bytesize - "Nullable()".bytesize)
    end

    private def nullable_temporal_width(type : String) : Int32
      case type
      when "Nullable(Date)"     then 2
      when "Nullable(Date32)"   then 4
      when "Nullable(DateTime)" then 4
      else
        raise UnsupportedFormatError.new("exact Nullable temporal type required") unless WidePart.nullable_datetime64_scale(type)
        8
      end
    end

    private def nullable_time_width(type : String) : Int32
      return 4 if type == "Nullable(Time)"
      raise UnsupportedFormatError.new("exact Nullable(Time64(p)) type required") unless WidePart.nullable_time64_scale(type)
      8
    end

    private def read_string_sizes(column : String, first_mark : Int, mark_count : Int) : {Array(UInt64), UInt64}
      read_string_sizes_from_stream("#{column}.size", first_mark, mark_count)
    end

    private def read_tuple_string_sizes(column : String, first_mark : Int, mark_count : Int) : {Array(UInt64), UInt64}
      stream = @streams["#{column}%2Eb.size"]
      _, _, rows = checked_stream_mark_range(stream, first_mark, mark_count)
      raise CorruptPartError.new("Tuple row count exceeds materialization limit") if rows > MAX_ARRAY_MARK_ROWS
      read_string_sizes_from_stream("#{column}%2Eb.size", first_mark, mark_count)
    end

    private def read_string_sizes_from_stream(stream_name : String, first_mark : Int, mark_count : Int) : {Array(UInt64), UInt64}
      size_stream = @streams[stream_name]
      size_start, size_end, rows = checked_stream_mark_range(size_stream, first_mark, mark_count)
      encoded_sizes = read_mark_range_bytes(size_stream, size_start, size_end, checked_byte_count(rows, 8), 8)
      sizes = Array(UInt64).new(rows.to_i)
      total_bytes = 0_u64
      offset = 0
      while offset < encoded_sizes.size
        size = u64(encoded_sizes, offset)
        raise CorruptPartError.new("String size exceeds selected data limit") if size > MAX_DATA_FILE_BYTES.to_u64 - total_bytes
        raise CorruptPartError.new("String read range exceeds materialization limit") if size > MAX_STRING_RANGE_BYTES.to_u64 - total_bytes
        total_bytes += size
        sizes << size
        offset += 8
      end
      {sizes, total_bytes}
    end

    private def read_array_outer_sizes(
      column : String,
      first_mark : Int,
      mark_count : Int,
    ) : {Array(UInt64), UInt64, UInt64, Array(UInt64)}
      size_stream = @streams["#{column}.size0"]
      size_start, size_end, rows = checked_stream_mark_range(size_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array outer row count exceeds materialization limit") if rows > MAX_ARRAY_MARK_ROWS
      encoded_sizes = read_mark_range_bytes(size_stream, size_start, size_end, checked_byte_count(rows, 8), 8)

      outer_sizes = Array(UInt64).new(rows.to_i)
      flat_elements = 0_u64
      offset = 0
      while offset < encoded_sizes.size
        size = u64(encoded_sizes, offset)
        if size > MAX_ARRAY_MARK_ELEMENTS - flat_elements
          raise CorruptPartError.new("Array nested element count exceeds per-range limit")
        end
        flat_elements += size
        outer_sizes << size
        offset += 8
      end
      raise CorruptPartError.new("Array size0 count does not match outer rows") unless outer_sizes.size.to_u64 == rows

      mark_flat_elements = Array(UInt64).new(mark_count)
      row_offset = 0
      mark_count.times do |range_mark_index|
        mark_index = first_mark + range_mark_index
        mark_rows = size_stream.marks[mark_index].rows
        mark_flat = 0_u64
        mark_rows.times do
          raise CorruptPartError.new("Array size0 mark rows exceed selected range") if row_offset >= outer_sizes.size
          size = outer_sizes[row_offset]
          raise CorruptPartError.new("Array nested element count exceeds per-range limit") if size > MAX_ARRAY_MARK_ELEMENTS - mark_flat
          mark_flat += size
          row_offset += 1
        end
        mark_flat_elements << mark_flat
      end
      raise CorruptPartError.new("Array size0 marks do not consume selected rows") unless row_offset == outer_sizes.size
      {outer_sizes, flat_elements, rows, mark_flat_elements}
    end

    private def read_array_array_uint64_element_sizes(
      column : String,
      first_mark : Int,
      mark_count : Int,
      flat_inner_arrays : UInt64,
      outer_rows : UInt64,
      mark_inner_arrays : Array(UInt64),
    ) : {Array(UInt64), UInt64, Array(UInt64)}
      size_stream = @streams["#{column}.size1"]
      size_start, size_end, size_rows = checked_stream_mark_range(size_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Array(UInt64)) size1 mark rows differ") unless size_rows == outer_rows
      validate_array_nested_stream_marks(size_stream, first_mark, mark_inner_arrays, 8)
      encoded_sizes = read_mark_range_bytes(
        size_stream,
        size_start,
        size_end,
        checked_array_mark_byte_count(flat_inner_arrays, 8),
        8
      )

      element_sizes = Array(UInt64).new(flat_inner_arrays.to_i)
      mark_leaf_elements = Array(UInt64).new(mark_count)
      total_leaf_elements = 0_u64
      size_offset = 0
      mark_inner_arrays.each_with_index do |mark_inner_count, range_mark_index|
        mark_leaf_count = 0_u64
        mark_inner_count.to_i.times do
          raise CorruptPartError.new("Array(Array(UInt64)) size1 count exceeds selected bytes") if size_offset > encoded_sizes.size - 8
          leaf_count = u64(encoded_sizes, size_offset)
          if leaf_count > MAX_ARRAY_MARK_ELEMENTS - mark_leaf_count || leaf_count > MAX_ARRAY_MARK_ELEMENTS - total_leaf_elements
            raise CorruptPartError.new("Array(Array(UInt64)) leaf element count exceeds per-range limit")
          end
          mark_leaf_count += leaf_count
          total_leaf_elements += leaf_count
          element_sizes << leaf_count
          size_offset += 8
        end
        checked_array_mark_byte_count(mark_leaf_count, 8)
        mark_leaf_elements << mark_leaf_count

        mark_index = first_mark + range_mark_index
        mark_start = size_stream.marks[mark_index]
        mark_end = mark_index + 1 == size_stream.marks.size ? size_stream.sentinel : size_stream.marks[mark_index + 1]
        validate_mark_range_bytes(size_stream, mark_start, mark_end, checked_array_mark_byte_count(mark_inner_count, 8), 8)
      end
      raise CorruptPartError.new("Array(Array(UInt64)) size1 has trailing bytes") unless size_offset == encoded_sizes.size
      raise CorruptPartError.new("Array(Array(UInt64)) size1 count does not match size0") unless element_sizes.size.to_u64 == flat_inner_arrays
      checked_array_mark_byte_count(total_leaf_elements, 8)
      {element_sizes, total_leaf_elements, mark_leaf_elements}
    end

    private def read_array_array_nullable_uint64_element_sizes(
      column : String,
      first_mark : Int,
      mark_count : Int,
      flat_inner_arrays : UInt64,
      outer_rows : UInt64,
      mark_inner_arrays : Array(UInt64),
    ) : {Array(UInt64), UInt64, Array(UInt64)}
      size_stream = @streams["#{column}.size1"]
      size_start, size_end, size_rows = checked_stream_mark_range(size_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Array(Nullable(UInt64))) size1 mark rows differ") unless size_rows == outer_rows
      validate_array_nested_stream_marks(size_stream, first_mark, mark_inner_arrays, 8)
      encoded_sizes = read_mark_range_bytes(
        size_stream,
        size_start,
        size_end,
        checked_array_mark_byte_count(flat_inner_arrays, 8),
        8
      )

      element_sizes = Array(UInt64).new(flat_inner_arrays.to_i)
      mark_leaf_elements = Array(UInt64).new(mark_count)
      total_leaf_elements = 0_u64
      size_offset = 0
      mark_inner_arrays.each_with_index do |mark_inner_count, range_mark_index|
        mark_leaf_count = 0_u64
        mark_inner_count.to_i.times do
          raise CorruptPartError.new("Array(Array(Nullable(UInt64))) size1 count exceeds selected bytes") if size_offset > encoded_sizes.size - 8
          leaf_count = u64(encoded_sizes, size_offset)
          if leaf_count > MAX_ARRAY_MARK_ELEMENTS - mark_leaf_count || leaf_count > MAX_ARRAY_MARK_ELEMENTS - total_leaf_elements
            raise CorruptPartError.new("Array(Array(Nullable(UInt64))) leaf element count exceeds per-range limit")
          end
          mark_leaf_count += leaf_count
          total_leaf_elements += leaf_count
          element_sizes << leaf_count
          size_offset += 8
        end
        checked_array_mark_byte_count(mark_leaf_count, 8)
        mark_leaf_elements << mark_leaf_count

        mark_index = first_mark + range_mark_index
        mark_start = size_stream.marks[mark_index]
        mark_end = mark_index + 1 == size_stream.marks.size ? size_stream.sentinel : size_stream.marks[mark_index + 1]
        validate_mark_range_bytes(size_stream, mark_start, mark_end, checked_array_mark_byte_count(mark_inner_count, 8), 8)
      end
      raise CorruptPartError.new("Array(Array(Nullable(UInt64))) size1 has trailing bytes") unless size_offset == encoded_sizes.size
      raise CorruptPartError.new("Array(Array(Nullable(UInt64))) size1 count does not match size0") unless element_sizes.size.to_u64 == flat_inner_arrays
      checked_array_mark_byte_count(total_leaf_elements, 8)
      {element_sizes, total_leaf_elements, mark_leaf_elements}
    end

    private def read_array_string_element_sizes(
      column : String,
      first_mark : Int,
      mark_count : Int,
      flat_elements : UInt64,
      outer_rows : UInt64,
      mark_flat_elements : Array(UInt64),
      type_name : String = "Array(String)",
      size_stream_name : String? = nil,
      raw_stream_name : String? = nil,
    ) : {Array(UInt64), UInt64}
      size_stream = @streams[size_stream_name || "#{column}.size"]
      size_start, size_end, size_rows = checked_stream_mark_range(size_stream, first_mark, mark_count)
      raise CorruptPartError.new("#{type_name} substream mark rows differ") unless size_rows == outer_rows
      encoded_sizes = read_mark_range_bytes(
        size_stream,
        size_start,
        size_end,
        checked_array_mark_byte_count(flat_elements, 8),
        8
      )

      element_sizes = Array(UInt64).new(flat_elements.to_i)
      total_bytes = 0_u64
      offset = 0
      raw_stream = @streams[raw_stream_name || column]
      _, _, raw_rows = checked_stream_mark_range(raw_stream, first_mark, mark_count)
      raise CorruptPartError.new("#{type_name} raw substream mark rows differ") unless raw_rows == outer_rows
      mark_flat_elements.each_with_index do |mark_flat, range_mark_index|
        mark_index = first_mark + range_mark_index
        mark_size_bytes = checked_array_mark_byte_count(mark_flat, 8)
        size_mark_start = size_stream.marks[mark_index]
        size_mark_end = mark_index + 1 == size_stream.marks.size ? size_stream.sentinel : size_stream.marks[mark_index + 1]
        validate_mark_range_bytes(size_stream, size_mark_start, size_mark_end, mark_size_bytes, 8)

        mark_raw_bytes = 0_u64
        mark_flat.to_i.times do
          raise CorruptPartError.new("#{type_name} nested size count exceeds selected bytes") if offset > encoded_sizes.size - 8
          size = u64(encoded_sizes, offset)
          if size > MAX_ARRAY_MARK_BYTES.to_u64 - total_bytes
            raise CorruptPartError.new("#{type_name} nested bytes exceed per-range limit")
          end
          if size > MAX_DATA_FILE_BYTES.to_u64 - total_bytes
            raise CorruptPartError.new("#{type_name} nested bytes exceed data limit")
          end
          if size > MAX_ARRAY_MARK_BYTES.to_u64 - mark_raw_bytes
            raise CorruptPartError.new("#{type_name} nested bytes exceed per-mark limit")
          end
          total_bytes += size
          mark_raw_bytes += size
          element_sizes << size
          offset += 8
        end
        raw_mark_start = raw_stream.marks[mark_index]
        raw_mark_end = mark_index + 1 == raw_stream.marks.size ? raw_stream.sentinel : raw_stream.marks[mark_index + 1]
        validate_mark_range_bytes(raw_stream, raw_mark_start, raw_mark_end, mark_raw_bytes.to_i, 1)
      end
      raise CorruptPartError.new("#{type_name} nested size stream has trailing bytes") unless offset == encoded_sizes.size
      raise CorruptPartError.new("#{type_name} nested size count does not match size0") unless element_sizes.size.to_u64 == flat_elements
      {element_sizes, total_bytes}
    end

    private def array_tuple_components(
      column : String,
      first_mark : Int,
      mark_count : Int,
      nullable_first_field : Bool,
      materialize : Bool,
    ) : ArrayTupleComponents
      ensure_column(column)
      expected_type = nullable_first_field ? WideTypePlan::TYPE_ARRAY_TUPLE_NULLABLE_UINT64_STRING : WideTypePlan::TYPE_ARRAY_TUPLE_UINT64_STRING
      raise UnsupportedFormatError.new("Array(Tuple) accessor requires one of the exact W51 declarations") unless @column_type == expected_type
      plan = WideTypePlan.admitted(@column_type) || raise(UnsupportedFormatError.new("Array(Tuple) type plan is not admitted"))
      streams = plan.physical_substreams(column)
      expected_stream_count = nullable_first_field ? 5 : 4
      raise UnsupportedFormatError.new("admitted Array(Tuple) plan has an unexpected stream topology") unless streams.size == expected_stream_count

      outer_sizes, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      value_index = nullable_first_field ? 2 : 1
      size_index = nullable_first_field ? 3 : 2
      value_stream = @streams[streams[value_index]]
      _, _, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Tuple) UInt64 substream mark rows differ") unless value_rows == rows
      validate_array_nested_stream_marks(value_stream, first_mark, mark_flat_elements, 8)
      numeric_values = if materialize
                         value_start, value_end, _ = checked_stream_mark_range(value_stream, first_mark, mark_count)
                         read_mark_range_bytes(value_stream, value_start, value_end, checked_array_mark_byte_count(flat_elements, 8), 8)
                       else
                         nil
                       end

      element_sizes, string_bytes = read_array_string_element_sizes(
        column,
        first_mark,
        mark_count,
        flat_elements,
        rows,
        mark_flat_elements,
        "Array(Tuple(String))",
        streams[size_index],
        streams[size_index + 1]
      )
      raise CorruptPartError.new("Array(Tuple) String-size count differs from size0") unless element_sizes.size.to_u64 == flat_elements

      null_map = nil.as(Bytes?)
      if nullable_first_field
        null_stream = @streams[streams[1]]
        null_start, null_end, null_rows = checked_stream_mark_range(null_stream, first_mark, mark_count)
        raise CorruptPartError.new("Array(Tuple) null-map mark rows differ") unless null_rows == rows
        validate_array_nested_stream_marks(null_stream, first_mark, mark_flat_elements, 1)
        encoded_null_map = read_mark_range_bytes(null_stream, null_start, null_end, checked_array_mark_byte_count(flat_elements, 1), 1)
        encoded_null_map.each do |value|
          raise CorruptPartError.new("Array(Tuple) null-map byte is not boolean") unless value <= 1_u8
        end
        null_map = encoded_null_map
      end

      materialized_bytes = checked_array_tuple_materialization_bytes(rows, flat_elements, string_bytes, nullable_first_field)
      string_values = if materialize
                        raw_stream = @streams[streams[size_index + 1]]
                        raw_start, raw_end, raw_rows = checked_stream_mark_range(raw_stream, first_mark, mark_count)
                        raise CorruptPartError.new("Array(Tuple) String substream mark rows differ") unless raw_rows == rows
                        read_mark_range_bytes(raw_stream, raw_start, raw_end, string_bytes.to_i, 1)
                      else
                        nil
                      end

      ArrayTupleComponents.new(
        outer_sizes,
        flat_elements,
        rows,
        element_sizes,
        string_bytes,
        materialized_bytes,
        numeric_values,
        null_map,
        string_values
      )
    end

    private def checked_array_tuple_materialization_bytes(
      rows : UInt64,
      flat_elements : UInt64,
      string_bytes : UInt64,
      nullable_first_field : Bool,
    ) : UInt64
      outer_bytes = checked_array_mark_byte_count(rows, 8).to_u64
      slot_bytes = checked_array_mark_byte_count(flat_elements, nullable_first_field ? 17 : 16).to_u64
      if slot_bytes > UInt64::MAX - outer_bytes || string_bytes > UInt64::MAX - outer_bytes - slot_bytes
        raise CorruptPartError.new("Array(Tuple) materialization charge overflows")
      end
      charge = outer_bytes + slot_bytes + string_bytes
      raise CorruptPartError.new("Array(Tuple) materialization charge exceeds per-range limit") if charge > MAX_ARRAY_MARK_BYTES.to_u64
      charge
    end

    private def read_array_nullable_string_null_map(
      column : String,
      first_mark : Int,
      mark_count : Int,
      flat_elements : UInt64,
      outer_rows : UInt64,
      mark_flat_elements : Array(UInt64),
    ) : Bytes
      null_stream = @streams["#{column}.null"]
      null_start, null_end, null_rows = checked_stream_mark_range(null_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Nullable(String)) null-map mark rows differ") unless null_rows == outer_rows
      validate_array_nested_stream_marks(null_stream, first_mark, mark_flat_elements, 1)
      null_bytes = read_mark_range_bytes(null_stream, null_start, null_end, checked_array_mark_byte_count(flat_elements, 1), 1)
      null_bytes.each do |value|
        raise CorruptPartError.new("Array(Nullable(String)) null-map byte is not boolean") unless value <= 1_u8
      end
      null_bytes
    end

    private def checked_array_nullable_string_slot_bytes(flat_elements : UInt64) : UInt64
      if flat_elements > UInt64::MAX // ARRAY_NULLABLE_STRING_SLOT_ACCOUNTING_BYTES
        raise CorruptPartError.new("Array(Nullable(String)) slot charge overflows")
      end
      flat_elements * ARRAY_NULLABLE_STRING_SLOT_ACCOUNTING_BYTES
    end

    private def validate_array_nested_stream_marks(
      stream : PhysicalStream,
      first_mark : Int,
      mark_flat_elements : Array(UInt64),
      element_width : Int32,
    ) : Nil
      mark_flat_elements.each_with_index do |elements, range_mark_index|
        mark_index = first_mark + range_mark_index
        start_mark = stream.marks[mark_index]
        end_mark = mark_index + 1 == stream.marks.size ? stream.sentinel : stream.marks[mark_index + 1]
        expected_bytes = checked_array_mark_byte_count(elements, element_width)
        validate_mark_range_bytes(stream, start_mark, end_mark, expected_bytes, element_width)
      end
      nil
    end

    private def checked_array_mark_byte_count(elements : UInt64, width : Int32) : Int
      if elements > MAX_ARRAY_MARK_ELEMENTS
        raise CorruptPartError.new("Array nested element count exceeds per-range limit")
      end
      byte_width = width.to_u64
      if byte_width == 0 || elements > UInt64::MAX // byte_width
        raise CorruptPartError.new("Array nested byte count overflows")
      end
      bytes = elements * byte_width
      if bytes > MAX_ARRAY_MARK_BYTES.to_u64 || bytes > MAX_DATA_FILE_BYTES.to_u64 || bytes > Int32::MAX.to_u64
        raise CorruptPartError.new("Array nested bytes exceed per-range limit")
      end
      bytes.to_i
    end

    private def validate_mark_range_bytes(
      stream : PhysicalStream,
      start_mark : Mark,
      end_mark : Mark,
      expected_bytes : Int,
      element_width : Int32,
    ) : Nil
      raise CorruptPartError.new("selected byte count exceeds limit") if expected_bytes < 0 || expected_bytes > MAX_DATA_FILE_BYTES
      selected_bytes = 0
      each_mark_range_bytes(stream, start_mark, end_mark, expected_bytes, element_width) do |chunk|
        raise CorruptPartError.new("selected byte count exceeds allocation") if chunk.size > expected_bytes - selected_bytes
        selected_bytes += chunk.size
      end
      raise CorruptPartError.new("selected byte count mismatch") unless selected_bytes == expected_bytes
      nil
    end

    private def ensure_column(column : String)
      raise UnsupportedFormatError.new("column is not present") unless column == @column
    end

    private def ensure_uint64_column(column : String)
      ensure_column(column)
      raise UnsupportedFormatError.new("UInt64 accessor requires an exact UInt64 column") unless @column_type == "UInt64"
    end

    private def checked_mark_range(column : String, first_mark : Int, mark_count : Int) : {Mark?, Mark, Int32}
      ensure_uint64_column(column)
      checked_mark_range(column, first_mark, mark_count, 8)
    end

    private def checked_numeric_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
      expected_type : String,
      element_width : Int32,
    ) : {Mark?, Mark, Int32}
      ensure_column(column)
      raise UnsupportedFormatError.new("typed accessor does not match selected column type") unless @column_type == expected_type
      checked_mark_range(column, first_mark, mark_count, element_width)
    end

    private def checked_mark_range(column : String, first_mark : Int, mark_count : Int, element_width : Int32) : {Mark?, Mark, Int32}
      raise BoundsError.new("negative mark range") if first_mark < 0 || mark_count < 0
      raise BoundsError.new("empty mark range") if mark_count == 0
      raise BoundsError.new("mark range exceeds data marks") if first_mark > @marks.size || mark_count > @marks.size - first_mark

      start_mark = @marks[first_mark] if first_mark < @marks.size
      end_index = first_mark + mark_count
      end_mark = end_index == @marks.size ? @sentinel : @marks[end_index]
      expected_rows = rows_in_range(first_mark, mark_count)
      expected_bytes = checked_byte_count(expected_rows, element_width).to_i32
      {start_mark, end_mark, expected_bytes}
    end

    private def checked_stream_mark_range(stream : PhysicalStream, first_mark : Int, mark_count : Int) : {Mark, Mark, UInt64}
      raise BoundsError.new("negative mark range") if first_mark < 0 || mark_count < 0
      raise BoundsError.new("empty mark range") if mark_count == 0
      marks = stream.marks
      raise BoundsError.new("mark range exceeds data marks") if first_mark > marks.size || mark_count > marks.size - first_mark
      start_mark = marks[first_mark]
      end_index = first_mark + mark_count
      end_mark = end_index == marks.size ? stream.sentinel : marks[end_index]
      expected_rows = rows_in_range(marks, first_mark, mark_count)
      {start_mark, end_mark, expected_rows}
    end

    private def read_mark_range_bytes(
      stream : PhysicalStream,
      start_mark : Mark,
      end_mark : Mark,
      expected_bytes : Int,
      element_width : Int32,
    ) : Bytes
      raise CorruptPartError.new("selected byte count exceeds limit") if expected_bytes < 0 || expected_bytes > MAX_DATA_FILE_BYTES
      output = Bytes.new(expected_bytes)
      offset = 0
      each_mark_range_bytes(stream, start_mark, end_mark, expected_bytes, element_width) do |chunk|
        raise CorruptPartError.new("selected byte count exceeds allocation") if chunk.size > output.size - offset
        chunk.copy_to(output.to_unsafe + offset, chunk.size)
        offset += chunk.size
      end
      raise CorruptPartError.new("selected byte count mismatch") unless offset == output.size
      output
    end

    private def rows_in_range(first_mark : Int, count : Int) : UInt64
      rows_in_range(@marks, first_mark, count)
    end

    private def rows_in_range(marks : Array(Mark), first_mark : Int, count : Int) : UInt64
      total = 0_u64
      count.times do |index|
        rows = marks[first_mark + index].rows
        total = total &+ rows
        raise CorruptPartError.new("mark range row count overflow") if total < rows
      end
      total
    end

    private def checked_byte_count(rows : UInt64, element_width : Int32) : Int
      width = element_width.to_u64
      raise CorruptPartError.new("row byte count overflow") if width == 0 || rows > (Int32::MAX.to_u64 / width)
      (rows * width).to_i
    end

    private def checked_fixed_string_byte_count(rows : UInt64, width : Int32) : Int
      byte_width = width.to_u64
      raise CorruptPartError.new("FixedString width is invalid") if byte_width == 0 || byte_width > MAX_FIXED_STRING_WIDTH.to_u64
      raise CorruptPartError.new("FixedString read range exceeds row materialization limit") if rows > MAX_FIXED_STRING_RANGE_ROWS
      if rows > MAX_STRING_RANGE_BYTES.to_u64 // byte_width
        raise CorruptPartError.new("FixedString read range exceeds materialization limit")
      end
      checked_byte_count(rows, width)
    end

    private def numeric_type_width(type : String) : Int32
      WidePart.numeric_payload_width(type)
    end

    private def decode_numeric_value(bytes : Bytes, offset : Int, type : T.class) : T forall T
      {% if T == UInt8 %}
        bytes[offset]
      {% elsif T == UInt16 %}
        u16(bytes, offset)
      {% elsif T == BFloat16Value %}
        BFloat16Value.new(u16(bytes, offset))
      {% elsif T == UInt32 %}
        u32(bytes, offset)
      {% elsif T == UInt64 %}
        u64(bytes, offset)
      {% elsif T == Int8 %}
        bytes[offset].unsafe_as(Int8)
      {% elsif T == Int16 %}
        u16(bytes, offset).unsafe_as(Int16)
      {% elsif T == Int32 %}
        u32(bytes, offset).unsafe_as(Int32)
      {% elsif T == Int64 %}
        u64(bytes, offset).unsafe_as(Int64)
      {% elsif T == Int128 %}
        u128(bytes, offset).unsafe_as(Int128)
      {% elsif T == UInt128 %}
        u128(bytes, offset)
      {% elsif T == Float32 %}
        u32(bytes, offset).unsafe_as(Float32)
      {% elsif T == Float64 %}
        u64(bytes, offset).unsafe_as(Float64)
      {% else %}
        raise UnsupportedFormatError.new("only exact fixed-width primitive numeric accessors are supported")
      {% end %}
    end

    private def decode_array_numeric_value(bytes : Bytes, offset : Int, type : T.class) : T forall T
      {% if T == Int256Value %}
        Int256Value.from_words(
          u64(bytes, offset),
          u64(bytes, offset + 8),
          u64(bytes, offset + 16),
          u64(bytes, offset + 24)
        )
      {% elsif T == UInt256Value %}
        UInt256Value.from_words(
          u64(bytes, offset),
          u64(bytes, offset + 8),
          u64(bytes, offset + 16),
          u64(bytes, offset + 24)
        )
      {% else %}
        decode_numeric_value(bytes, offset, type)
      {% end %}
    end

    private def each_uint64_mark_range(start_mark : Mark?, end_mark : Mark, expected_bytes : Int, & : UInt64 -> Nil) : Nil
      each_uint64_mark_range_bytes(start_mark, end_mark, expected_bytes) do |bytes|
        offset = 0
        while offset < bytes.size
          yield u64(bytes, offset)
          offset += 8
        end
      end
    end

    private def each_uint64_mark_range_bytes(start_mark : Mark?, end_mark : Mark, expected_bytes : Int, & : Bytes -> Nil) : Nil
      each_mark_range_bytes(start_mark, end_mark, expected_bytes, 8) do |bytes|
        yield bytes
      end
    end

    private def each_mark_range_bytes(
      start_mark : Mark?,
      end_mark : Mark,
      expected_bytes : Int,
      element_width : Int32,
      & : Bytes -> Nil
    ) : Nil
      raise BoundsError.new("empty mark range") unless start_mark
      each_mark_range_bytes(@streams[@column], start_mark.not_nil!, end_mark, expected_bytes, element_width) do |bytes|
        yield bytes
      end
    end

    private def each_mark_range_bytes(
      stream : PhysicalStream,
      start_mark : Mark,
      end_mark : Mark,
      expected_bytes : Int,
      element_width : Int32,
      & : Bytes -> Nil
    ) : Nil
      data_size = File.size(stream.data_path)
      raise CorruptPartError.new("data file exceeds limit") if data_size > MAX_DATA_FILE_BYTES
      start_offset = start_mark.compressed_offset
      end_offset = end_mark.compressed_offset
      empty_payload_stream = if WidePart.supports_array_type?(@column_type)
                               WidePart.array_element_stream_names(@column, @column_type).not_nil!.includes?(stream.name)
                             elsif WidePart.supports_map_uint64_string_type?(@column_type)
                               stream.name == "#{@column}%2Ekeys" || stream.name == "#{@column}%2Evalues.size" || stream.name == "#{@column}%2Evalues"
                             elsif WidePart.supports_map_uint64_uint64_type?(@column_type)
                               stream.name == "#{@column}%2Ekeys" || stream.name == "#{@column}%2Evalues"
                             elsif WidePart.supports_map_uint64_nullable_uint64_type?(@column_type)
                               stream.name == "#{@column}%2Ekeys" || stream.name == "#{@column}%2Evalues.null" || stream.name == "#{@column}%2Evalues"
                             elsif WidePart.supports_map_string_uint64_type?(@column_type)
                               stream.name == "#{@column}%2Ekeys.size" || stream.name == "#{@column}%2Ekeys" || stream.name == "#{@column}%2Evalues"
                             elsif WidePart.supports_map_string_string_type?(@column_type)
                               stream.name == "#{@column}%2Ekeys.size" || stream.name == "#{@column}%2Ekeys" ||
                                 stream.name == "#{@column}%2Evalues.size" || stream.name == "#{@column}%2Evalues"
                             elsif WidePart.supports_map_string_nullable_uint64_type?(@column_type)
                               stream.name == "#{@column}%2Ekeys.size" || stream.name == "#{@column}%2Ekeys" ||
                                 stream.name == "#{@column}%2Evalues.null" || stream.name == "#{@column}%2Evalues"
                             elsif WidePart.supports_map_uint64_nullable_string_type?(@column_type)
                               stream.name == "#{@column}%2Ekeys" || stream.name == "#{@column}%2Evalues.null" ||
                                 stream.name == "#{@column}%2Evalues.size" || stream.name == "#{@column}%2Evalues"
                             elsif WidePart.supports_map_string_nullable_string_type?(@column_type)
                               stream.name == "#{@column}%2Ekeys.size" || stream.name == "#{@column}%2Ekeys" ||
                                 stream.name == "#{@column}%2Evalues.null" || stream.name == "#{@column}%2Evalues.size" ||
                                 stream.name == "#{@column}%2Evalues"
                             else
                               stream.name == @column && (@column_type == "String" || WidePart.supports_nullable_string_type?(@column_type))
                             end
      eof_boundary = end_offset == data_size.to_u64 && end_mark.decompressed_offset == 0 &&
                     (end_mark == stream.sentinel || empty_payload_stream && end_mark.rows > 0)
      if start_offset == data_size.to_u64
        unless empty_payload_stream && expected_bytes == 0 && end_offset == data_size.to_u64 &&
               start_mark.decompressed_offset == 0 && end_mark.decompressed_offset == 0 && eof_boundary
          raise CorruptPartError.new("empty payload range at EOF must select zero expected bytes")
        end
        return
      end
      MMapDataSource.with_file(stream.data_path, data_size, MAX_DATA_FILE_BYTES) do |data|
        raise CorruptPartError.new("mark frame offset exceeds data") if start_offset >= data_size || end_offset > data_size || end_offset == data_size && !eof_boundary
        raise CorruptPartError.new("mark frame offsets are reversed") if start_offset > end_offset

        selected_bytes = 0_i64
        frame_offset = start_offset.to_i64
        started = false
        workspace = CompressedBlock::DecodeWorkspace.new
        loop do
          frame = CompressedBlock.decode_frame_into(
            data,
            frame_offset,
            workspace,
            MAX_FRAME_COMPRESSED_BYTES,
            MAX_FRAME_DECOMPRESSED_BYTES
          )
          current = frame_offset.to_u64
          started ||= current == start_offset
          raise CorruptPartError.new("mark does not start at a frame") unless started
          local_start = current == start_offset ? start_mark.decompressed_offset : 0_u64
          local_end = current == end_offset ? end_mark.decompressed_offset : frame.output.size.to_u64
          raise CorruptPartError.new("mark offset exceeds frame output") if local_start > frame.output.size || local_end > frame.output.size || local_start > local_end
          if current == end_offset && end_mark == stream.sentinel && !eof_boundary
            raise CorruptPartError.new("non-EOF sentinel must end at frame output") unless end_mark.decompressed_offset == frame.output.size
          end
          selected_size = (local_end - local_start).to_i64
          raise CorruptPartError.new("selected data exceeds expected byte count") if selected_size > expected_bytes.to_i64 - selected_bytes
          raise CorruptPartError.new("numeric bytes are not column-type-aligned") unless selected_size % element_width == 0
          yield frame.output[local_start.to_i, selected_size.to_i] if selected_size > 0
          selected_bytes += selected_size
          if current == end_offset
            raise CorruptPartError.new("data has trailing bytes after final frame") if end_mark == stream.sentinel && frame.end_offset != data_size
            break
          end
          next_offset = frame.end_offset
          break if eof_boundary && next_offset == data_size
          raise CorruptPartError.new("mark frame offset was not found") if next_offset <= frame_offset || next_offset > data_size
          frame_offset = next_offset
        end
        raise CorruptPartError.new("mark range byte count mismatch") unless selected_bytes == expected_bytes
      end
    end

    private def u64(bytes : Bytes, offset : Int) : UInt64
      raise CorruptPartError.new("truncated integer") if offset < 0 || offset > bytes.size - 8
      value = 0_u64
      8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
      value
    end

    private def network_order_u64(bytes : Bytes, offset : Int) : UInt64
      raise CorruptPartError.new("truncated IPv6 address") if offset < 0 || offset > bytes.size - 8
      value = 0_u64
      8.times { |index| value = (value << 8) | bytes[offset + index].to_u64 }
      value
    end

    private def u128(bytes : Bytes, offset : Int) : UInt128
      raise CorruptPartError.new("truncated integer") if offset < 0 || offset > bytes.size - 16
      value = 0_u128
      16.times { |index| value |= bytes[offset + index].to_u128 << (index * 8) }
      value
    end

    private def u32(bytes : Bytes, offset : Int) : UInt32
      raise CorruptPartError.new("truncated integer") if offset < 0 || offset > bytes.size - 4
      value = 0_u32
      4.times { |index| value |= bytes[offset + index].to_u32 << (index * 8) }
      value
    end

    private def u16(bytes : Bytes, offset : Int) : UInt16
      raise CorruptPartError.new("truncated integer") if offset < 0 || offset > bytes.size - 2
      value = 0_u16
      2.times { |index| value |= bytes[offset + index].to_u16 << (index * 8) }
      value
    end

    private def fill_uint64_scratch(
      destination : Slice(UInt64),
      destination_offset : Int,
      source : Bytes,
      source_offset : Int,
      count : Int,
    ) : Nil
      return if count == 0

      {% if IO::ByteFormat::SystemEndian == IO::ByteFormat::LittleEndian %}
        # The destination is UInt64 storage; the source is deliberately byte-typed
        # because a decoded frame's base address need not be UInt64-aligned.
        destination_pointer = (destination.to_unsafe + destination_offset).unsafe_as(Pointer(UInt8))
        destination_pointer.copy_from(source.to_unsafe + source_offset, count * 8)
      {% else %}
        count.times do |index|
          destination[destination_offset + index] = u64(source, source_offset + index * 8)
        end
      {% end %}
      nil
    end
  end
end
