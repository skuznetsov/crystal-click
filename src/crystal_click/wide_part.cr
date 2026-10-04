require "json"
require "./wide_part/variant_discriminator_decoder"
require "./wide_part/low_cardinality_binary_codec"

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
    MAX_VARIANT_RANGE_ROWS               = 65_536_u64
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

    # W76 numeric Map rows each retain an Array object, including empty rows.
    # This allowance covers the row header, outer pointer, and allocator
    # overhead. It is a conservative logical charge, not exact RSS accounting.
    NUMERIC_MAP_ROW_ACCOUNTING_BYTES = 64_u64

    # W63 Map(String, Array(UInt64)) accounting includes one retained nested
    # Array header for every Map entry, including entries whose Array is empty.
    MAP_ARRAY_UINT64_CONTAINER_ACCOUNTING_BYTES = 24_u64

    # W80 nested Array(Map) accounting: one outer array per table row, one
    # Map-entry array per inner map (including empty maps), and one tuple per
    # entry. This is a conservative batch charge, not a heap-size estimate.
    ARRAY_MAP_ROW_ACCOUNTING_BYTES       = NUMERIC_MAP_ROW_ACCOUNTING_BYTES
    ARRAY_MAP_CONTAINER_ACCOUNTING_BYTES = 24_u64

    private struct ArrayMapStringUInt64Streams
      getter outer_sizes : WideTypePlan::WidePhysicalPlanShadow::Stream
      getter map_sizes : WideTypePlan::WidePhysicalPlanShadow::Stream
      getter key_sizes : WideTypePlan::WidePhysicalPlanShadow::Stream
      getter keys : WideTypePlan::WidePhysicalPlanShadow::Stream
      getter values : WideTypePlan::WidePhysicalPlanShadow::Stream

      def initialize(
        @outer_sizes : WideTypePlan::WidePhysicalPlanShadow::Stream,
        @map_sizes : WideTypePlan::WidePhysicalPlanShadow::Stream,
        @key_sizes : WideTypePlan::WidePhysicalPlanShadow::Stream,
        @keys : WideTypePlan::WidePhysicalPlanShadow::Stream,
        @values : WideTypePlan::WidePhysicalPlanShadow::Stream,
      )
      end
    end

    private struct ArrayMapStringUInt64Preflight
      getter streams : ArrayMapStringUInt64Streams
      getter outer_sizes : Array(UInt64)
      getter map_sizes : Array(UInt64)
      getter key_sizes : Array(UInt64)
      getter rows : UInt64
      getter maps : UInt64
      getter entries : UInt64
      getter key_bytes : UInt64
      getter value_bytes : UInt64
      getter payload_bytes : UInt64
      getter charge_bytes : UInt64

      def initialize(
        @streams : ArrayMapStringUInt64Streams,
        @outer_sizes : Array(UInt64),
        @map_sizes : Array(UInt64),
        @key_sizes : Array(UInt64),
        @rows : UInt64,
        @maps : UInt64,
        @entries : UInt64,
        @key_bytes : UInt64,
        @value_bytes : UInt64,
        @payload_bytes : UInt64,
        @charge_bytes : UInt64,
      )
      end
    end

    private struct ArrayMapNumericStreams
      getter outer_sizes : WideTypePlan::WidePhysicalPlanShadow::Stream
      getter map_sizes : WideTypePlan::WidePhysicalPlanShadow::Stream
      getter key_sizes : WideTypePlan::WidePhysicalPlanShadow::Stream?
      getter keys : WideTypePlan::WidePhysicalPlanShadow::Stream
      getter null_map : WideTypePlan::WidePhysicalPlanShadow::Stream?
      getter values : WideTypePlan::WidePhysicalPlanShadow::Stream

      def initialize(
        @outer_sizes : WideTypePlan::WidePhysicalPlanShadow::Stream,
        @map_sizes : WideTypePlan::WidePhysicalPlanShadow::Stream,
        @key_sizes : WideTypePlan::WidePhysicalPlanShadow::Stream?,
        @keys : WideTypePlan::WidePhysicalPlanShadow::Stream,
        @null_map : WideTypePlan::WidePhysicalPlanShadow::Stream?,
        @values : WideTypePlan::WidePhysicalPlanShadow::Stream,
      )
      end
    end

    private struct ArrayMapNumericPreflight
      getter streams : ArrayMapNumericStreams
      getter outer_sizes : Array(UInt64)
      getter map_sizes : Array(UInt64)
      getter key_sizes : Array(UInt64)
      getter rows : UInt64
      getter maps : UInt64
      getter entries : UInt64
      getter key_bytes : UInt64
      getter value_bytes : UInt64
      getter payload_bytes : UInt64
      getter charge_bytes : UInt64
      getter null_map : Bytes?

      def initialize(
        @streams : ArrayMapNumericStreams,
        @outer_sizes : Array(UInt64),
        @map_sizes : Array(UInt64),
        @key_sizes : Array(UInt64),
        @rows : UInt64,
        @maps : UInt64,
        @entries : UInt64,
        @key_bytes : UInt64,
        @value_bytes : UInt64,
        @payload_bytes : UInt64,
        @charge_bytes : UInt64,
        @null_map : Bytes?,
      )
      end
    end

    # W82 String-leaf Array(Map) columns keep both String byte axes explicit.
    # This remains separate from W81 numeric leaves so String syntax cannot
    # enter the numeric admission path by width or wrapper coincidence.
    private struct ArrayMapStringLeafStreams
      getter outer_sizes : WideTypePlan::WidePhysicalPlanShadow::Stream
      getter map_sizes : WideTypePlan::WidePhysicalPlanShadow::Stream
      getter key_sizes : WideTypePlan::WidePhysicalPlanShadow::Stream?
      getter keys : WideTypePlan::WidePhysicalPlanShadow::Stream
      getter null_map : WideTypePlan::WidePhysicalPlanShadow::Stream?
      getter value_sizes : WideTypePlan::WidePhysicalPlanShadow::Stream
      getter values : WideTypePlan::WidePhysicalPlanShadow::Stream

      def initialize(
        @outer_sizes : WideTypePlan::WidePhysicalPlanShadow::Stream,
        @map_sizes : WideTypePlan::WidePhysicalPlanShadow::Stream,
        @key_sizes : WideTypePlan::WidePhysicalPlanShadow::Stream?,
        @keys : WideTypePlan::WidePhysicalPlanShadow::Stream,
        @null_map : WideTypePlan::WidePhysicalPlanShadow::Stream?,
        @value_sizes : WideTypePlan::WidePhysicalPlanShadow::Stream,
        @values : WideTypePlan::WidePhysicalPlanShadow::Stream,
      )
      end
    end

    private struct ArrayMapStringLeafPreflight
      getter streams : ArrayMapStringLeafStreams
      getter outer_sizes : Array(UInt64)
      getter map_sizes : Array(UInt64)
      getter key_sizes : Array(UInt64)
      getter value_sizes : Array(UInt64)
      getter rows : UInt64
      getter maps : UInt64
      getter entries : UInt64
      getter key_bytes : UInt64
      getter value_bytes : UInt64
      getter payload_bytes : UInt64
      getter charge_bytes : UInt64
      getter null_map : Bytes?

      def initialize(
        @streams : ArrayMapStringLeafStreams,
        @outer_sizes : Array(UInt64),
        @map_sizes : Array(UInt64),
        @key_sizes : Array(UInt64),
        @value_sizes : Array(UInt64),
        @rows : UInt64,
        @maps : UInt64,
        @entries : UInt64,
        @key_bytes : UInt64,
        @value_bytes : UInt64,
        @payload_bytes : UInt64,
        @charge_bytes : UInt64,
        @null_map : Bytes?,
      )
      end
    end

    # W83 Bool leaves have one fixed-width semantic payload byte per Map
    # entry. Keep this separate from W82 String-size accounting.
    private struct ArrayMapBoolLeafStreams
      getter outer_sizes : WideTypePlan::WidePhysicalPlanShadow::Stream
      getter map_sizes : WideTypePlan::WidePhysicalPlanShadow::Stream
      getter key_sizes : WideTypePlan::WidePhysicalPlanShadow::Stream?
      getter keys : WideTypePlan::WidePhysicalPlanShadow::Stream
      getter null_map : WideTypePlan::WidePhysicalPlanShadow::Stream?
      getter values : WideTypePlan::WidePhysicalPlanShadow::Stream

      def initialize(
        @outer_sizes : WideTypePlan::WidePhysicalPlanShadow::Stream,
        @map_sizes : WideTypePlan::WidePhysicalPlanShadow::Stream,
        @key_sizes : WideTypePlan::WidePhysicalPlanShadow::Stream?,
        @keys : WideTypePlan::WidePhysicalPlanShadow::Stream,
        @null_map : WideTypePlan::WidePhysicalPlanShadow::Stream?,
        @values : WideTypePlan::WidePhysicalPlanShadow::Stream,
      )
      end
    end

    private struct ArrayMapBoolLeafPreflight
      getter streams : ArrayMapBoolLeafStreams
      getter outer_sizes : Array(UInt64)
      getter map_sizes : Array(UInt64)
      getter key_sizes : Array(UInt64)
      getter rows : UInt64
      getter maps : UInt64
      getter entries : UInt64
      getter key_bytes : UInt64
      getter value_bytes : UInt64
      getter payload_bytes : UInt64
      getter charge_bytes : UInt64
      getter null_map : Bytes?

      def initialize(
        @streams : ArrayMapBoolLeafStreams,
        @outer_sizes : Array(UInt64),
        @map_sizes : Array(UInt64),
        @key_sizes : Array(UInt64),
        @rows : UInt64,
        @maps : UInt64,
        @entries : UInt64,
        @key_bytes : UInt64,
        @value_bytes : UInt64,
        @payload_bytes : UInt64,
        @charge_bytes : UInt64,
        @null_map : Bytes?,
      )
      end
    end

    # W84 keeps the value Array's third count axis explicit. These descriptors
    # are shared by all four exact key/value pairings; the type gate remains
    # the four-declaration whitelist in WideTypePlan.
    private struct ArrayMapArrayLeafStreams
      getter outer_sizes : WideTypePlan::WidePhysicalPlanShadow::Stream
      getter map_sizes : WideTypePlan::WidePhysicalPlanShadow::Stream
      getter key_sizes : WideTypePlan::WidePhysicalPlanShadow::Stream?
      getter keys : WideTypePlan::WidePhysicalPlanShadow::Stream
      getter value_sizes : WideTypePlan::WidePhysicalPlanShadow::Stream
      getter value_string_sizes : WideTypePlan::WidePhysicalPlanShadow::Stream?
      getter values : WideTypePlan::WidePhysicalPlanShadow::Stream

      def initialize(
        @outer_sizes : WideTypePlan::WidePhysicalPlanShadow::Stream,
        @map_sizes : WideTypePlan::WidePhysicalPlanShadow::Stream,
        @key_sizes : WideTypePlan::WidePhysicalPlanShadow::Stream?,
        @keys : WideTypePlan::WidePhysicalPlanShadow::Stream,
        @value_sizes : WideTypePlan::WidePhysicalPlanShadow::Stream,
        @value_string_sizes : WideTypePlan::WidePhysicalPlanShadow::Stream?,
        @values : WideTypePlan::WidePhysicalPlanShadow::Stream,
      )
      end
    end

    private struct ArrayMapArrayLeafPreflight
      getter streams : ArrayMapArrayLeafStreams
      getter outer_sizes : Array(UInt64)
      getter map_sizes : Array(UInt64)
      getter value_sizes : Array(UInt64)
      getter key_sizes : Array(UInt64)
      getter value_string_sizes : Array(UInt64)
      getter mark_maps : Array(UInt64)
      getter mark_entries : Array(UInt64)
      getter mark_values : Array(UInt64)
      getter rows : UInt64
      getter maps : UInt64
      getter entries : UInt64
      getter values_count : UInt64
      getter key_bytes : UInt64
      getter value_bytes : UInt64
      getter payload_bytes : UInt64
      getter charge_bytes : UInt64

      def initialize(
        @streams : ArrayMapArrayLeafStreams,
        @outer_sizes : Array(UInt64),
        @map_sizes : Array(UInt64),
        @value_sizes : Array(UInt64),
        @key_sizes : Array(UInt64),
        @value_string_sizes : Array(UInt64),
        @mark_maps : Array(UInt64),
        @mark_entries : Array(UInt64),
        @mark_values : Array(UInt64),
        @rows : UInt64,
        @maps : UInt64,
        @entries : UInt64,
        @values_count : UInt64,
        @key_bytes : UInt64,
        @value_bytes : UInt64,
        @payload_bytes : UInt64,
        @charge_bytes : UInt64,
      )
      end
    end

    # Bounded Variant table accounting: one union slot per row.
    # This is conservative batch accounting, not an exact heap measurement.
    VARIANT_STRING_UINT64_ROW_ACCOUNTING_BYTES      = 64_u64
    VARIANT_BOOL_STRING_UINT64_ROW_ACCOUNTING_BYTES = 64_u64

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

    private def self.decimal_column_scale(
      type : String,
      shape : DecimalColumnShape,
      storage_width : Int32,
    ) : Int32?
      descriptor = DecimalColumnType.parse(type) || return nil
      return nil unless descriptor.shape == shape && descriptor.storage_width == storage_width
      descriptor.scale
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

    # ClickHouse normalizes Decimal32/64 aliases in columns.txt to canonical
    # Decimal(P, S) leaves; P selects the physical storage-width family.
    def self.decimal32_scale(type : String) : Int32?
      decimal_column_scale(type, DecimalColumnShape::Scalar, 4)
    end

    def self.decimal64_scale(type : String) : Int32?
      decimal_column_scale(type, DecimalColumnShape::Scalar, 8)
    end

    def self.decimal128_scale(type : String) : Int32?
      decimal_column_scale(type, DecimalColumnShape::Scalar, 16)
    end

    # Decimal256 is stored as a signed 32-byte coefficient. ClickHouse writes
    # the logical alias as its canonical Decimal(P, S) metadata form.
    def self.decimal256_scale(type : String) : Int32?
      decimal_column_scale(type, DecimalColumnShape::Scalar, 32)
    end

    def self.nullable_decimal32_scale(type : String) : Int32?
      decimal_column_scale(type, DecimalColumnShape::NullableScalar, 4)
    end

    def self.nullable_decimal64_scale(type : String) : Int32?
      decimal_column_scale(type, DecimalColumnShape::NullableScalar, 8)
    end

    def self.nullable_decimal128_scale(type : String) : Int32?
      decimal_column_scale(type, DecimalColumnShape::NullableScalar, 16)
    end

    def self.nullable_decimal256_scale(type : String) : Int32?
      decimal_column_scale(type, DecimalColumnShape::NullableScalar, 32)
    end

    # Decimal32 Arrays preserve the canonical precision and scale in the
    # semantic declaration while storing signed Int32 coefficients.
    def self.array_decimal32_scale(type : String) : Int32?
      decimal_column_scale(type, DecimalColumnShape::Array, 4)
    end

    def self.array_nullable_decimal32_scale(type : String) : Int32?
      decimal_column_scale(type, DecimalColumnShape::ArrayNullable, 4)
    end

    # Decimal64 Arrays keep the exact scale in metadata and expose signed
    # Int64 coefficients through semantic accessors only.
    def self.array_decimal64_scale(type : String) : Int32?
      decimal_column_scale(type, DecimalColumnShape::Array, 8)
    end

    def self.array_nullable_decimal64_scale(type : String) : Int32?
      decimal_column_scale(type, DecimalColumnShape::ArrayNullable, 8)
    end

    # Decimal128 Arrays expose signed Int128 coefficients only through these
    # exact semantic gates; physical width alone does not admit Int128 Arrays.
    def self.array_decimal128_scale(type : String) : Int32?
      decimal_column_scale(type, DecimalColumnShape::Array, 16)
    end

    def self.array_nullable_decimal128_scale(type : String) : Int32?
      decimal_column_scale(type, DecimalColumnShape::ArrayNullable, 16)
    end

    # Keep Decimal256 Arrays on their own signed Decimal256Value semantic
    # path; equal-width primitive Int256 Array metadata is not an alias.
    def self.array_decimal256_scale(type : String) : Int32?
      decimal_column_scale(type, DecimalColumnShape::Array, 32)
    end

    def self.array_nullable_decimal256_scale(type : String) : Int32?
      decimal_column_scale(type, DecimalColumnShape::ArrayNullable, 32)
    end

    # W64 admits only exactly two Array levels over canonical Decimal(P, S)
    # declarations. Keep these semantic gates separate from primitive numeric
    # Array parsing so equal-width Int* leaves do not inherit Decimal admission.
    def self.array_array_decimal32_scale(type : String) : Int32?
      decimal_column_scale(type, DecimalColumnShape::ArrayArray, 4)
    end

    def self.array_array_nullable_decimal32_scale(type : String) : Int32?
      decimal_column_scale(type, DecimalColumnShape::ArrayArrayNullable, 4)
    end

    def self.array_array_decimal64_scale(type : String) : Int32?
      decimal_column_scale(type, DecimalColumnShape::ArrayArray, 8)
    end

    def self.array_array_nullable_decimal64_scale(type : String) : Int32?
      decimal_column_scale(type, DecimalColumnShape::ArrayArrayNullable, 8)
    end

    def self.array_array_decimal128_scale(type : String) : Int32?
      decimal_column_scale(type, DecimalColumnShape::ArrayArray, 16)
    end

    def self.array_array_nullable_decimal128_scale(type : String) : Int32?
      decimal_column_scale(type, DecimalColumnShape::ArrayArrayNullable, 16)
    end

    def self.array_array_decimal256_scale(type : String) : Int32?
      decimal_column_scale(type, DecimalColumnShape::ArrayArray, 32)
    end

    def self.array_array_nullable_decimal256_scale(type : String) : Int32?
      decimal_column_scale(type, DecimalColumnShape::ArrayArrayNullable, 32)
    end

    def self.array_array_decimal_payload_width(type : String) : Int32?
      return 4 if array_array_decimal32_scale(type) || array_array_nullable_decimal32_scale(type)
      return 8 if array_array_decimal64_scale(type) || array_array_nullable_decimal64_scale(type)
      return 16 if array_array_decimal128_scale(type) || array_array_nullable_decimal128_scale(type)
      return 32 if array_array_decimal256_scale(type) || array_array_nullable_decimal256_scale(type)
      nil
    end

    # Normalize only the Decimal DDL aliases observed in stock metadata. The
    # caller retains the exact source spelling separately for API metadata.
    def self.catalog_type(type : String) : String?
      if normalized = DecimalColumnType.catalog_type(type)
        return normalized
      end
      if normalized = DateTimeColumnType.catalog_type(type)
        return normalized
      end
      type if supports_typed_type?(type)
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

    # Accept only the exact scalar DateTime64 leaf spelling. The timezone is
    # retained in the descriptor but does not change its raw tick precision.
    def self.datetime64_scale(type : String) : Int32?
      descriptor = DateTimeColumnType.parse_leaf(type) || return nil
      return nil unless descriptor.family == DateTimeColumnType::Family::DateTime64
      descriptor.precision?.try(&.to_i)
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
      descriptor = DateTimeColumnType.parse(type) || return nil
      return nil unless descriptor.shape == DateTimeColumnType::Shape::Nullable &&
                        descriptor.family == DateTimeColumnType::Family::DateTime64
      descriptor.precision?.try(&.to_i)
    end

    def self.nullable_time64_scale(type : String) : Int32?
      match = /\ANullable\(Time64\(([0-9])\)\)\z/.match(type)
      match.try { |value| value[1].to_i }
    end

    # Array temporal declarations retain their semantic leaf type, including
    # the canonical DateTime64 precision. These recognizers deliberately stay
    # separate from the numeric Array grammar even when physical widths match.
    def self.temporal_array_element_type(type : String) : String?
      if descriptor = DateTimeColumnType.parse(type)
        return descriptor.leaf_type_name if descriptor.shape == DateTimeColumnType::Shape::Array
      end
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
      if descriptor = DateTimeColumnType.parse(type)
        return descriptor.leaf_type_name if descriptor.shape == DateTimeColumnType::Shape::ArrayNullable
      end
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

    # W65 admits exactly two Array levels over the existing temporal leaf
    # family. Keep this semantic gate separate from the nested numeric gate:
    # Date and DateTime intentionally share physical widths with integers.
    def self.array_array_temporal_element_type(type : String) : String?
      if descriptor = DateTimeColumnType.parse(type)
        return descriptor.leaf_type_name if descriptor.shape == DateTimeColumnType::Shape::ArrayArray
      end
      case type
      when "Array(Array(Date))"     then "Date"
      when "Array(Array(Date32))"   then "Date32"
      when "Array(Array(DateTime))" then "DateTime"
      else
        if scale = array_array_datetime64_scale(type)
          "DateTime64(#{scale})"
        end
      end
    end

    def self.array_array_nullable_temporal_element_type(type : String) : String?
      if descriptor = DateTimeColumnType.parse(type)
        return descriptor.leaf_type_name if descriptor.shape == DateTimeColumnType::Shape::ArrayArrayNullable
      end
      case type
      when "Array(Array(Nullable(Date)))"     then "Date"
      when "Array(Array(Nullable(Date32)))"   then "Date32"
      when "Array(Array(Nullable(DateTime)))" then "DateTime"
      else
        if scale = array_array_nullable_datetime64_scale(type)
          "DateTime64(#{scale})"
        end
      end
    end

    def self.array_array_datetime64_scale(type : String) : Int32?
      datetime64_array_scale(type, DateTimeColumnType::Shape::ArrayArray)
    end

    def self.array_array_nullable_datetime64_scale(type : String) : Int32?
      datetime64_array_scale(type, DateTimeColumnType::Shape::ArrayArrayNullable)
    end

    # W66's paired nested Time family remains separate from the W65
    # Date/DateTime semantic gate despite sharing fixed-width carriers.
    def self.array_array_time_element_type(type : String) : String?
      return "Time" if type == "Array(Array(Time))"
      if scale = array_array_time64_scale(type)
        "Time64(#{scale})"
      end
    end

    def self.array_array_nullable_time_element_type(type : String) : String?
      return "Time" if type == "Array(Array(Nullable(Time)))"
      if scale = array_array_nullable_time64_scale(type)
        "Time64(#{scale})"
      end
    end

    def self.array_array_time64_scale(type : String) : Int32?
      match = /\AArray\(Array\(Time64\(([0-9])\)\)\)\z/.match(type)
      match.try { |value| value[1].to_i }
    end

    def self.array_array_nullable_time64_scale(type : String) : Int32?
      match = /\AArray\(Array\(Nullable\(Time64\(([0-9])\)\)\)\)\z/.match(type)
      match.try { |value| value[1].to_i }
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
      datetime64_array_scale(type, DateTimeColumnType::Shape::Array)
    end

    def self.nullable_array_datetime64_scale(type : String) : Int32?
      datetime64_array_scale(type, DateTimeColumnType::Shape::ArrayNullable)
    end

    private def self.datetime64_array_scale(type : String, expected_shape : DateTimeColumnType::Shape) : Int32?
      descriptor = DateTimeColumnType.parse(type) || return nil
      return nil unless descriptor.shape == expected_shape &&
                        descriptor.family == DateTimeColumnType::Family::DateTime64
      descriptor.precision?.try(&.to_i)
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
      if descriptor = DateTimeColumnType.parse_leaf(element_type)
        return descriptor.family == DateTimeColumnType::Family::DateTime ? "UInt32" : "Int64"
      end
      case element_type
      when "Date"     then "UInt16"
      when "Date32"   then "Int32"
      when "DateTime" then "UInt32"
      else
        "Int64" if datetime64_scale(element_type)
      end
    end

    # Raw reader entry points select a semantic family while retaining the
    # full declared name in column metadata. Timezone is provenance and does
    # not relabel or rescale the UInt32/Int64 carrier.
    def self.same_temporal_leaf_family?(left : String, right : String) : Bool
      left_datetime = DateTimeColumnType.parse_leaf(left)
      right_datetime = DateTimeColumnType.parse_leaf(right)
      if left_datetime && right_datetime
        left_datetime.family == right_datetime.family && left_datetime.precision? == right_datetime.precision?
      else
        left == right
      end
    end

    def self.time_array_physical_type(element_type : String) : String?
      return "Int32" if element_type == "Time"
      "Int64" if time64_scale(element_type)
    end

    def self.supports_nullable_temporal_type?(type : String) : Bool
      if descriptor = DateTimeColumnType.parse(type)
        return descriptor.shape == DateTimeColumnType::Shape::Nullable
      end
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

    def self.supports_array_map_string_uint64_type?(type : String) : Bool
      type == WideTypePlan::TYPE_ARRAY_MAP_STRING_UINT64
    end

    # W81 admits one exact Array(Map(K, V)) layer for UInt64 or String keys
    # and primitive numeric values, optionally wrapped once in Nullable.
    def self.array_map_uint64_numeric_value_type(type : String) : String?
      array_map_numeric_value_type(type, "UInt64", false)
    end

    def self.array_map_string_numeric_value_type(type : String) : String?
      array_map_numeric_value_type(type, "String", false)
    end

    def self.array_map_uint64_nullable_numeric_value_type(type : String) : String?
      array_map_numeric_value_type(type, "UInt64", true)
    end

    def self.array_map_string_nullable_numeric_value_type(type : String) : String?
      array_map_numeric_value_type(type, "String", true)
    end

    def self.supports_array_map_numeric_type?(type : String) : Bool
      !array_map_uint64_numeric_value_type(type).nil? ||
        !array_map_string_numeric_value_type(type).nil? ||
        !array_map_uint64_nullable_numeric_value_type(type).nil? ||
        !array_map_string_nullable_numeric_value_type(type).nil?
    end

    # W82's bounded String leaf profile is deliberately an exact four-type
    # set. The tuple carries the key declaration and whether values are
    # nullable; no generalized parser is used for String Map children.
    def self.array_map_string_leaf_shape(type : String) : {String, Bool}?
      case type
      when "Array(Map(UInt64, String))"           then {"UInt64", false}
      when "Array(Map(String, String))"           then {"String", false}
      when "Array(Map(UInt64, Nullable(String)))" then {"UInt64", true}
      when "Array(Map(String, Nullable(String)))" then {"String", true}
      else
        nil
      end
    end

    def self.supports_array_map_string_leaf_type?(type : String) : Bool
      !array_map_string_leaf_shape(type).nil?
    end

    # W83's semantic Bool leaf stays exact and is not admitted as UInt8.
    # The tuple carries the key declaration and whether values are nullable.
    def self.array_map_bool_leaf_shape(type : String) : {String, Bool}?
      case type
      when "Array(Map(UInt64, Bool))"           then {"UInt64", false}
      when "Array(Map(String, Bool))"           then {"String", false}
      when "Array(Map(UInt64, Nullable(Bool)))" then {"UInt64", true}
      when "Array(Map(String, Nullable(Bool)))" then {"String", true}
      else
        nil
      end
    end

    def self.supports_array_map_bool_leaf_type?(type : String) : Bool
      !array_map_bool_leaf_shape(type).nil?
    end

    # W85 adds fixed-width primitive numeric leaves under the existing Array
    # shape. W84's String leaves remain admitted through its exact helper.
    def self.array_map_array_leaf_shape(type : String) : {String, String}?
      WideTypePlan.array_map_array_numeric_leaf_shape(type) || WideTypePlan.array_map_array_leaf_shape(type)
    end

    def self.supports_array_map_array_leaf_type?(type : String) : Bool
      !array_map_array_leaf_shape(type).nil?
    end

    def self.supports_array_map_type?(type : String) : Bool
      supports_array_map_string_uint64_type?(type) || supports_array_map_numeric_type?(type) ||
        supports_array_map_string_leaf_type?(type) || supports_array_map_bool_leaf_type?(type) ||
        supports_array_map_array_leaf_type?(type)
    end

    private def self.array_map_numeric_value_type(type : String, key_type : String, nullable : Bool) : String?
      prefix = nullable ? "Array(Map(#{key_type}, Nullable(" : "Array(Map(#{key_type}, "
      suffix = nullable ? ")))" : "))"
      return nil unless type.starts_with?(prefix) && type.ends_with?(suffix)
      value_type = type.byte_slice(prefix.bytesize, type.bytesize - prefix.bytesize - suffix.bytesize)
      return nil unless supports_numeric_type?(value_type)
      type == "#{prefix}#{value_type}#{suffix}" ? value_type : nil
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
        elsif array_array_nullable_decimal32_scale(type) || array_array_nullable_decimal64_scale(type) ||
              array_array_nullable_decimal128_scale(type) || array_array_nullable_decimal256_scale(type)
          ["#{column}.size1", "#{column}.null", column]
        elsif array_array_decimal32_scale(type) || array_array_decimal64_scale(type) ||
              array_array_decimal128_scale(type) || array_array_decimal256_scale(type)
          ["#{column}.size1", column]
        elsif array_array_nullable_temporal_element_type(type)
          ["#{column}.size1", "#{column}.null", column]
        elsif array_array_temporal_element_type(type)
          ["#{column}.size1", column]
        elsif array_array_nullable_time_element_type(type)
          ["#{column}.size1", "#{column}.null", column]
        elsif array_array_time_element_type(type)
          ["#{column}.size1", column]
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
        elsif array_array_nullable_numeric_element_type(type)
          ["#{column}.size1", "#{column}.null", column]
        elsif element_type = numeric_array_element_type(type)
          [column]
        elsif array_array_numeric_element_type(type)
          ["#{column}.size1", column]
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

    # Admit exactly two Array levels over the numeric leaves supported by the
    # one-level Array codec. This deliberately does not extend the bounded
    # grammar to recursive or semantic leaves.
    def self.array_array_numeric_element_type(type : String) : String?
      return nil unless type.starts_with?("Array(Array(") && type.ends_with?("))")
      element_type = type.byte_slice("Array(Array(".bytesize, type.bytesize - "Array(Array())".bytesize)
      supports_array_numeric_type?(element_type) ? element_type : nil
    end

    # Admit exactly two Array levels with one nullable wrapper around a leaf
    # from the same bounded nested numeric family.
    def self.array_array_nullable_numeric_element_type(type : String) : String?
      prefix = "Array(Array(Nullable("
      return nil unless type.starts_with?(prefix) && type.ends_with?(")))")
      element_type = type.byte_slice(prefix.bytesize, type.bytesize - prefix.bytesize - 3)
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

    # Return the primitive numeric value type only for an exact W76 Map
    # declaration. Keep this grammar deliberately closed: these predicates
    # admit the declaration; they do not normalize whitespace or wrappers.
    def self.map_uint64_numeric_value_type(type : String) : String?
      numeric_map_value_type(type, "Map(UInt64, ")
    end

    def self.map_string_numeric_value_type(type : String) : String?
      numeric_map_value_type(type, "Map(String, ")
    end

    def self.supports_numeric_map_type?(type : String) : Bool
      !map_uint64_numeric_value_type(type).nil? || !map_string_numeric_value_type(type).nil?
    end

    # Admit exactly one Array layer over the W76 primitive numeric leaves for
    # the two supported Map key shapes. No whitespace normalization or
    # recursive composite parsing is performed.
    def self.map_uint64_array_numeric_value_type(type : String) : String?
      numeric_map_array_value_type(type, "Map(UInt64, Array(")
    end

    def self.map_string_array_numeric_value_type(type : String) : String?
      numeric_map_array_value_type(type, "Map(String, Array(")
    end

    def self.supports_numeric_map_array_type?(type : String) : Bool
      !map_uint64_array_numeric_value_type(type).nil? || !map_string_array_numeric_value_type(type).nil?
    end

    # W79's paired Map(Array(Nullable(T))) numeric leaf family. Keep this
    # exact parser separate from the older Nullable(UInt64) and Nullable(String)
    # specializations so generic dispatch cannot shadow those controls.
    def self.map_uint64_array_nullable_numeric_value_type(type : String) : String?
      nullable_numeric_map_array_value_type(type, "Map(UInt64, Array(Nullable(")
    end

    def self.map_string_array_nullable_numeric_value_type(type : String) : String?
      nullable_numeric_map_array_value_type(type, "Map(String, Array(Nullable(")
    end

    def self.supports_nullable_numeric_map_array_type?(type : String) : Bool
      !map_uint64_array_nullable_numeric_value_type(type).nil? || !map_string_array_nullable_numeric_value_type(type).nil?
    end

    # Return the primitive numeric value type only for an exact W77 Map with
    # one Nullable wrapper around the value leaf. Keep the grammar closed and
    # share the leaf family with the W76 non-nullable Map readers.
    def self.map_uint64_nullable_numeric_value_type(type : String) : String?
      nullable_numeric_map_value_type(type, "Map(UInt64, Nullable(")
    end

    def self.map_string_nullable_numeric_value_type(type : String) : String?
      nullable_numeric_map_value_type(type, "Map(String, Nullable(")
    end

    def self.supports_nullable_numeric_map_type?(type : String) : Bool
      !map_uint64_nullable_numeric_value_type(type).nil? || !map_string_nullable_numeric_value_type(type).nil?
    end

    private def self.numeric_map_value_type(type : String, prefix : String) : String?
      return nil unless type.starts_with?(prefix) && type.ends_with?(")")
      value_type = type.byte_slice(prefix.bytesize, type.bytesize - prefix.bytesize - 1)
      return nil unless supports_numeric_type?(value_type)
      type == "#{prefix}#{value_type})" ? value_type : nil
    end

    private def self.numeric_map_array_value_type(type : String, prefix : String) : String?
      return nil unless type.starts_with?(prefix) && type.ends_with?(")")
      return nil if type.bytesize < prefix.bytesize + 3
      value_type = type.byte_slice(prefix.bytesize, type.bytesize - prefix.bytesize - 2)
      return nil unless supports_numeric_type?(value_type)
      type == "#{prefix}#{value_type}))" ? value_type : nil
    end

    private def self.nullable_numeric_map_value_type(type : String, prefix : String) : String?
      return nil unless type.starts_with?(prefix) && type.ends_with?(")")
      return nil if type.bytesize < prefix.bytesize + 2
      value_type = type.byte_slice(prefix.bytesize, type.bytesize - prefix.bytesize - 2)
      return nil unless supports_numeric_type?(value_type)
      type == "#{prefix}#{value_type}))" ? value_type : nil
    end

    private def self.nullable_numeric_map_array_value_type(type : String, prefix : String) : String?
      return nil unless type.starts_with?(prefix) && type.ends_with?(")))")
      return nil if type.bytesize < prefix.bytesize + 3
      value_type = type.byte_slice(prefix.bytesize, type.bytesize - prefix.bytesize - 3)
      return nil unless supports_numeric_type?(value_type)
      type == "#{prefix}#{value_type})))" ? value_type : nil
    end

    def self.supports_map_string_array_uint64_type?(type : String) : Bool
      type == "Map(String, Array(UInt64))"
    end

    def self.supports_map_string_array_nullable_uint64_type?(type : String) : Bool
      type == "Map(String, Array(Nullable(UInt64)))"
    end

    def self.supports_map_string_array_nullable_string_type?(type : String) : Bool
      type == "Map(String, Array(Nullable(String)))"
    end

    def self.supports_map_uint64_array_nullable_uint64_type?(type : String) : Bool
      type == "Map(UInt64, Array(Nullable(UInt64)))"
    end

    def self.supports_map_uint64_array_nullable_string_type?(type : String) : Bool
      type == "Map(UInt64, Array(Nullable(String)))"
    end

    def self.supports_map_uint64_array_uint64_type?(type : String) : Bool
      type == "Map(UInt64, Array(UInt64))"
    end

    def self.supports_map_string_array_string_type?(type : String) : Bool
      type == "Map(String, Array(String))"
    end

    def self.supports_map_uint64_array_string_type?(type : String) : Bool
      type == "Map(UInt64, Array(String))"
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

    def self.supports_named_scalar_tuple_type?(type : String) : Bool
      !WideTupleTypePlan.for_type(type).nil?
    end

    def self.supports_variant_string_uint64_type?(type : String) : Bool
      WideVariantStringUInt64TypePlan.admitted?(type)
    end

    def self.supports_variant_bool_string_uint64_type?(type : String) : Bool
      WideVariantBoolStringUInt64TypePlan.admitted?(type)
    end

    def self.variant_type_plan(type : String) : WideVariantTypePlanDescriptor?
      WideVariantTypePlanDescriptor.for_type(type)
    end

    def self.supports_variant_type?(type : String) : Bool
      !variant_type_plan(type).nil?
    end

    def self.supports_typed_type?(type : String) : Bool
      !GeometryColumnType.for_type(type).nil? || !GeoArrayColumnType.for_type(type).nil? || !PointColumnType.for_type(type).nil? || !QBitColumnType.for_type(type).nil? || supports_semantic_fixed_width_type?(type) || supports_nullable_semantic_fixed_width_type?(type) ||
        !DateTimeColumnType.parse(type).nil? ||
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
        supports_map_uint64_string_type?(type) || supports_map_uint64_uint64_type?(type) || supports_numeric_map_type?(type) ||
        supports_numeric_map_array_type?(type) ||
        supports_nullable_numeric_map_array_type?(type) ||
        supports_nullable_numeric_map_type?(type) ||
        supports_map_string_uint64_type?(type) || supports_array_map_string_uint64_type?(type) || supports_array_map_numeric_type?(type) ||
        supports_array_map_string_leaf_type?(type) || supports_array_map_bool_leaf_type?(type) ||
        supports_array_map_array_leaf_type?(type) ||
        supports_map_string_array_uint64_type?(type) ||
        supports_map_string_array_nullable_uint64_type?(type) || supports_map_string_array_nullable_string_type?(type) ||
        supports_map_string_string_type?(type) ||
        supports_map_uint64_array_nullable_uint64_type?(type) || supports_map_uint64_array_nullable_string_type?(type) ||
        supports_map_uint64_array_uint64_type?(type) || supports_map_string_array_string_type?(type) ||
        supports_map_uint64_array_string_type?(type) ||
        supports_map_uint64_nullable_uint64_type?(type) || supports_map_string_nullable_uint64_type?(type) ||
        supports_map_uint64_nullable_string_type?(type) || supports_map_string_nullable_string_type?(type) ||
        supports_named_scalar_tuple_type?(type) || supports_named_array_tuple_type?(type) ||
        supports_named_map_tuple_type?(type) ||
        supports_variant_type?(type) || type == "Dynamic"
    end

    def self.json_type?(type : String) : Bool
      type == "JSON" || type.starts_with?("JSON(")
    end

    # Return the stored declaration only when the requested name is an exact
    # literal JSON root. This is a metadata-only dispatch probe: it does not
    # make whole JSON columns readable through WidePart's scalar codecs.
    # Preserve the existing dotted-literal/virtual-path ambiguity guard before
    # allowing a table adapter to route the exact column to ObjectColumnReader.
    def self.selected_json_declaration(part_path : String, column_name : String) : String?
      SelectedJsonMetadataProbe.read(part_path, column_name)
    end

    # Parse the intentionally small JSON typed-path declaration grammar used
    # by this reader: simple top-level identifiers with exact primitive
    # numeric or String types. Unsupported declarations fail closed.
    def self.json_typed_paths(type : String) : Array({String, String})
      JsonTypedPathDeclaration.parse(self, type)
    end

    def self.json_typed_path_type(type : String, path : String) : String?
      json_typed_paths(type).find { |entry| entry[0] == path }.try(&.[1])
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

    # Preserve the exact nominal QBit descriptor and raw element bytes. Range
    # budgeting and all plane/null schedules are checked before payload reads.
    def read_qbit_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
      max_materialized_bytes : UInt64 = QBitColumnType::MAX_MATERIALIZED_BYTES,
    ) : Array(QBitValue)
      plan = ensure_qbit_reader_type(column, false)
      checked_first_mark, checked_mark_count = qbit_reader_checked_range(plan, column, first_mark, mark_count)
      qbit_reader(plan, column).read_scalar(checked_first_mark, checked_mark_count, max_materialized_bytes)
    end

    def read_nullable_qbit_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
      max_materialized_bytes : UInt64 = QBitColumnType::MAX_MATERIALIZED_BYTES,
    ) : Array(QBitValue?)
      plan = ensure_qbit_reader_type(column, true)
      checked_first_mark, checked_mark_count = qbit_reader_checked_range(plan, column, first_mark, mark_count)
      qbit_reader(plan, column).read_nullable(checked_first_mark, checked_mark_count, max_materialized_bytes)
    end

    # Dense nested rows include nullable zero placeholders. The null map is
    # still read and validated, so this is also suitable for staged readback.
    def read_qbit_dense_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
      max_materialized_bytes : UInt64 = QBitColumnType::MAX_MATERIALIZED_BYTES,
    ) : Array(QBitValue)
      plan = ensure_qbit_reader_type(column, nil)
      checked_first_mark, checked_mark_count = qbit_reader_checked_range(plan, column, first_mark, mark_count)
      qbit_reader(plan, column).read_dense(checked_first_mark, checked_mark_count, max_materialized_bytes)
    end

    # Preflight only: verifies every physical mark schedule and returns the
    # conservative result charge without opening a selected payload stream.
    def qbit_mark_range_materialization_charge(column : String, first_mark : Int, mark_count : Int) : UInt64
      plan = ensure_qbit_reader_type(column, nil)
      checked_first_mark, checked_mark_count = qbit_reader_checked_range(plan, column, first_mark, mark_count)
      qbit_reader(plan, column).materialization_charge(checked_first_mark, checked_mark_count)
    end

    # Point is a fixed two-coordinate Float64 value. Both coordinate marks are
    # structurally checked before this method returns any selected values.
    def read_point_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
      max_materialized_bytes : UInt64 = PointColumnType::MAX_MATERIALIZED_BYTES,
    ) : Array(WidePointValue)
      plan = ensure_point_reader_type(column)
      checked_first_mark, checked_mark_count = point_reader_checked_range(plan, column, first_mark, mark_count)
      point_reader(plan, column).read(checked_first_mark, checked_mark_count, max_materialized_bytes)
    end

    # Mark-local values are delivered only after every selected mark boundary
    # and the combined retained-schedule/per-mark charge has been checked.
    def each_point_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
      max_materialized_bytes : UInt64 = PointColumnType::MAX_MATERIALIZED_BYTES,
      & : Array(WidePointValue), Int32 -> Nil
    ) : Nil
      plan = ensure_point_reader_type(column)
      checked_first_mark, checked_mark_count = point_reader_checked_range(plan, column, first_mark, mark_count)
      point_reader(plan, column).each(checked_first_mark, checked_mark_count, max_materialized_bytes) do |values, mark_index|
        yield values, mark_index
      end
      nil
    end

    # Metadata-only table-scan preflight. It verifies selected mark row counts
    # and the combined Point charge without reading/decompressing payloads.
    def point_mark_range_materialization_charge(
      column : String,
      first_mark : Int,
      mark_count : Int,
      max_materialized_bytes : UInt64 = PointColumnType::MAX_MATERIALIZED_BYTES,
    ) : UInt64
      plan = ensure_point_reader_type(column)
      checked_first_mark, checked_mark_count = point_reader_checked_range(plan, column, first_mark, mark_count)
      point_reader(plan, column).materialization_charge(
        checked_first_mark,
        checked_mark_count,
        max_materialized_bytes
      )
    end

    # Structural selected-range preflight for table scans. It checks both
    # coordinate boundaries before a batch callback but does not materialize
    # Point values.
    def validate_point_mark_range_structure(
      column : String,
      first_mark : Int,
      mark_count : Int,
      max_materialized_bytes : UInt64 = PointColumnType::MAX_MATERIALIZED_BYTES,
    ) : Nil
      plan = ensure_point_reader_type(column)
      checked_first_mark, checked_mark_count = point_reader_checked_range(plan, column, first_mark, mark_count)
      point_reader(plan, column).validate_selected_structure(
        checked_first_mark,
        checked_mark_count,
        max_materialized_bytes
      )
    end

    # Ragged cardinality discovery reads bounded size streams. All selected
    # structural boundaries pass before coordinates or callbacks are exposed.
    def read_geo_array_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
      max_materialized_bytes : UInt64 = GeoArrayColumnType::MAX_MATERIALIZED_BYTES,
    ) : WideGeoArrayColumnData
      plan = ensure_geo_array_reader_type(column)
      first, count = geo_array_reader_checked_range(plan, column, first_mark, mark_count)
      geo_array_reader(plan, column).read(first, count, max_materialized_bytes)
    end

    def each_geo_array_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
      max_materialized_bytes : UInt64 = GeoArrayColumnType::MAX_MATERIALIZED_BYTES,
      & : WideGeoArrayColumnData, Int32 -> Nil
    ) : Nil
      plan = ensure_geo_array_reader_type(column)
      first, count = geo_array_reader_checked_range(plan, column, first_mark, mark_count)
      geo_array_reader(plan, column).each(first, count, max_materialized_bytes) do |data, mark_index|
        yield data, mark_index
      end
      nil
    end

    # This is bounded size-stream I/O, not a metadata-only estimate.
    def geo_array_mark_range_materialization_charge(
      column : String,
      first_mark : Int,
      mark_count : Int,
      max_materialized_bytes : UInt64 = GeoArrayColumnType::MAX_MATERIALIZED_BYTES,
    ) : UInt64
      plan = ensure_geo_array_reader_type(column)
      first, count = geo_array_reader_checked_range(plan, column, first_mark, mark_count)
      geo_array_reader(plan, column).materialization_charge(first, count, max_materialized_bytes)
    end

    def validate_geo_array_mark_range_structure(
      column : String,
      first_mark : Int,
      mark_count : Int,
      max_materialized_bytes : UInt64 = GeoArrayColumnType::MAX_MATERIALIZED_BYTES,
    ) : Nil
      plan = ensure_geo_array_reader_type(column)
      first, count = geo_array_reader_checked_range(plan, column, first_mark, mark_count)
      geo_array_reader(plan, column).validate_selected_structure(first, count, max_materialized_bytes)
    end

    # Geometry retains its outer table-mark origin while each discriminator
    # arm carries a separate sparse, window-local lane schedule.
    def read_geometry_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
      max_materialized_bytes : UInt64 = GeometryColumnType::MAX_MATERIALIZED_BYTES,
    ) : WideGeometryColumnData
      plan = ensure_geometry_reader_type(column)
      first, count = geometry_reader_checked_range(plan, column, first_mark, mark_count)
      geometry_reader(plan, column).read(first, count, max_materialized_bytes)
    end

    def each_geometry_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
      max_materialized_bytes : UInt64 = GeometryColumnType::MAX_MATERIALIZED_BYTES,
      & : WideGeometryColumnData, Int32 -> Nil
    ) : Nil
      plan = ensure_geometry_reader_type(column)
      first, count = geometry_reader_checked_range(plan, column, first_mark, mark_count)
      geometry_reader(plan, column).each(first, count, max_materialized_bytes) do |data, mark_index|
        yield data, mark_index
      end
      nil
    end

    def geometry_mark_range_materialization_charge(
      column : String,
      first_mark : Int,
      mark_count : Int,
      max_materialized_bytes : UInt64 = GeometryColumnType::MAX_MATERIALIZED_BYTES,
    ) : UInt64
      plan = ensure_geometry_reader_type(column)
      first, count = geometry_reader_checked_range(plan, column, first_mark, mark_count)
      geometry_reader(plan, column).materialization_charge(first, count, max_materialized_bytes)
    end

    def validate_geometry_mark_range_structure(
      column : String,
      first_mark : Int,
      mark_count : Int,
      max_materialized_bytes : UInt64 = GeometryColumnType::MAX_MATERIALIZED_BYTES,
    ) : Nil
      plan = ensure_geometry_reader_type(column)
      first, count = geometry_reader_checked_range(plan, column, first_mark, mark_count)
      geometry_reader(plan, column).validate_selected_structure(first, count, max_materialized_bytes)
    end

    # Bool payload values use the shared semantic codec: zero is false and
    # every nonzero source byte is true.
    def read_bool_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Bool)
      ensure_column(column)
      raise UnsupportedFormatError.new("Bool accessor requires an exact Bool column") unless @column_type == "Bool"

      start_mark, end_mark, expected_bytes = checked_mark_range(column, first_mark, mark_count, 1)
      values = Array(Bool).new
      each_mark_range_bytes(start_mark, end_mark, expected_bytes, 1) do |bytes|
        bytes.each { |byte| values << BoolValueCodec.decode(byte) }
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
        if value.nil?
          nil
        else
          BoolValueCodec.decode(value.not_nil!)
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
      raise UnsupportedFormatError.new("Decimal32 accessor requires canonical Decimal(P, S) with P in 1..9") unless WidePart.decimal32_scale(@column_type)
      read_semantic_fixed_width_mark_range(column, first_mark, mark_count, 4, Int32)
    end

    def read_nullable_decimal32_raw_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Int32?)
      ensure_column(column)
      raise UnsupportedFormatError.new("Decimal32 accessor requires canonical Nullable(Decimal(P, S)) with P in 1..9") unless WidePart.nullable_decimal32_scale(@column_type)
      read_nullable_fixed_width_mark_range(column, first_mark, mark_count, 4, Int32)
    end

    def read_decimal64_raw_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Int64)
      ensure_column(column)
      raise UnsupportedFormatError.new("Decimal64 accessor requires canonical Decimal(P, S) with P in 10..18") unless WidePart.decimal64_scale(@column_type)
      read_semantic_fixed_width_mark_range(column, first_mark, mark_count, 8, Int64)
    end

    def read_nullable_decimal64_raw_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Int64?)
      ensure_column(column)
      raise UnsupportedFormatError.new("Decimal64 accessor requires canonical Nullable(Decimal(P, S)) with P in 10..18") unless WidePart.nullable_decimal64_scale(@column_type)
      read_nullable_fixed_width_mark_range(column, first_mark, mark_count, 8, Int64)
    end

    def read_decimal128_raw_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Int128)
      ensure_column(column)
      raise UnsupportedFormatError.new("Decimal128 accessor requires canonical Decimal(P, S) with P in 19..38") unless WidePart.decimal128_scale(@column_type)
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
      raise UnsupportedFormatError.new("Decimal128 accessor requires canonical Nullable(Decimal(P, S)) with P in 19..38") unless WidePart.nullable_decimal128_scale(@column_type)
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
      raise UnsupportedFormatError.new("Decimal256 accessor requires canonical Decimal(P, S) with P in 39..76") unless WidePart.decimal256_scale(@column_type)

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
      raise UnsupportedFormatError.new("Decimal256 accessor requires canonical Nullable(Decimal(P, S)) with P in 39..76") unless WidePart.nullable_decimal256_scale(@column_type)

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
      datetime_type = DateTimeColumnType.parse_leaf(@column_type)
      raise UnsupportedFormatError.new("DateTime accessor requires an exact DateTime column") unless datetime_type && datetime_type.family == DateTimeColumnType::Family::DateTime

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
      datetime_type = DateTimeColumnType.parse(@column_type)
      raise UnsupportedFormatError.new("Nullable(DateTime) accessor requires an exact Nullable(DateTime) column") unless datetime_type && datetime_type.shape == DateTimeColumnType::Shape::Nullable && datetime_type.family == DateTimeColumnType::Family::DateTime
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

    # Count the three physical streams of Array(Array(T)) before a table batch
    # allocates nested values. Both offset streams are decoded and validated;
    # the leaf stream is boundary-checked with its exact primitive width.
    def array_array_numeric_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      element_type = WidePart.array_array_numeric_element_type(@column_type) ||
                     raise(UnsupportedFormatError.new("nested Array numeric accessor requires an exact Array(Array(T)) numeric column"))

      validate_array_array_numeric_size0_marks(column, first_mark, mark_count)
      outer_sizes, flat_inner_arrays, rows, mark_inner_arrays = read_array_outer_sizes(column, first_mark, mark_count)
      element_sizes, flat_elements, mark_leaf_elements = read_array_array_numeric_element_sizes(
        column,
        first_mark,
        mark_count,
        flat_inner_arrays,
        rows,
        mark_inner_arrays,
        WidePart.array_numeric_payload_width(element_type)
      )
      raise CorruptPartError.new("Array(Array(T)) outer row count changed") unless outer_sizes.size.to_u64 == rows

      value_stream = @streams[column]
      value_start, value_end, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Array(T)) value mark rows differ") unless value_rows == rows
      element_width = WidePart.array_numeric_payload_width(element_type)
      validate_array_nested_stream_marks(value_stream, first_mark, mark_leaf_elements, element_width)
      value_bytes = checked_array_mark_byte_count(flat_elements, element_width).to_u64
      validate_mark_range_bytes(value_stream, value_start, value_end, value_bytes.to_i, element_width)
      raise CorruptPartError.new("Array(Array(T)) nested size count changed") unless element_sizes.size.to_u64 == flat_inner_arrays

      outer_bytes = checked_byte_count(rows, 8).to_u64
      inner_bytes = checked_array_mark_byte_count(flat_inner_arrays, 8).to_u64
      if inner_bytes > UInt64::MAX - outer_bytes || value_bytes > UInt64::MAX - outer_bytes - inner_bytes
        raise CorruptPartError.new("Array(Array(T)) raw byte count overflows")
      end
      outer_bytes + inner_bytes + value_bytes
    end

    # Temporal nested leaves use the same fixed-width physical codec as
    # selected integer carriers, but remain admitted only by exact temporal
    # metadata. This guard prevents Date/DateTime declarations from entering
    # the general numeric nested accessor.
    def array_array_temporal_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      element_type = WidePart.array_array_temporal_element_type(@column_type) ||
                     raise(UnsupportedFormatError.new("nested temporal Array accessor requires an exact Array(Array(T)) temporal column"))
      physical_type = WidePart.temporal_array_physical_type(element_type).not_nil!
      array_array_decimal_mark_range_raw_bytes(
        column,
        first_mark,
        mark_count,
        WidePart.array_numeric_payload_width(physical_type),
        false
      )
    end

    def array_array_nullable_temporal_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      element_type = WidePart.array_array_nullable_temporal_element_type(@column_type) ||
                     raise(UnsupportedFormatError.new("nested nullable temporal Array accessor requires an exact Array(Array(Nullable(T))) temporal column"))
      physical_type = WidePart.temporal_array_physical_type(element_type).not_nil!
      array_array_decimal_mark_range_raw_bytes(
        column,
        first_mark,
        mark_count,
        WidePart.array_numeric_payload_width(physical_type),
        true
      )
    end

    def array_array_time_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      element_type = WidePart.array_array_time_element_type(@column_type) ||
                     raise(UnsupportedFormatError.new("nested Time Array accessor requires an exact Array(Array(Time)) declaration"))
      physical_type = WidePart.time_array_physical_type(element_type).not_nil!
      array_array_decimal_mark_range_raw_bytes(
        column,
        first_mark,
        mark_count,
        WidePart.array_numeric_payload_width(physical_type),
        false
      )
    end

    def array_array_nullable_time_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      element_type = WidePart.array_array_nullable_time_element_type(@column_type) ||
                     raise(UnsupportedFormatError.new("nested nullable Time Array accessor requires an exact Array(Array(Nullable(Time))) declaration"))
      physical_type = WidePart.time_array_physical_type(element_type).not_nil!
      array_array_decimal_mark_range_raw_bytes(
        column,
        first_mark,
        mark_count,
        WidePart.array_numeric_payload_width(physical_type),
        true
      )
    end

    # Preflight all four physical streams for the exact W59 nested String
    # shape before a table batch allocates values. The returned count includes
    # size0, size1, String-size slots, and raw String bytes.
    def array_array_string_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      components = array_array_string_components(column, first_mark, mark_count)
      outer_bytes = checked_byte_count(components.rows, 8).to_u64
      inner_bytes = checked_array_mark_byte_count(components.flat_inner_arrays, 8).to_u64
      string_size_bytes = checked_array_mark_byte_count(components.flat_strings, 8).to_u64
      payload_bytes = components.string_bytes
      if inner_bytes > UInt64::MAX - outer_bytes || string_size_bytes > UInt64::MAX - outer_bytes - inner_bytes ||
         payload_bytes > UInt64::MAX - outer_bytes - inner_bytes - string_size_bytes
        raise CorruptPartError.new("Array(Array(String)) raw byte count overflows")
      end
      outer_bytes + inner_bytes + string_size_bytes + payload_bytes
    end

    # Preflight all five physical streams for the exact W61 nested nullable
    # String shape before a table batch allocates values.
    def array_array_nullable_string_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      components = array_array_nullable_string_components(column, first_mark, mark_count)
      total_bytes = checked_byte_count(components.rows, 8).to_u64
      {
        checked_array_mark_byte_count(components.flat_inner_arrays, 8).to_u64,
        checked_array_mark_byte_count(components.flat_strings, 1).to_u64,
        checked_array_mark_byte_count(components.flat_strings, 8).to_u64,
        components.string_bytes,
      }.each do |bytes|
        raise CorruptPartError.new("Array(Array(Nullable(String))) raw byte count overflows") if bytes > UInt64::MAX - total_bytes
        total_bytes += bytes
      end
      total_bytes
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
      raise UnsupportedFormatError.new("Decimal32 Array accessor requires Array(Decimal(P, S)) with P in 1..9") unless WidePart.array_decimal32_scale(@column_type)

      _, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      value_stream = @streams[column]
      _, _, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Decimal32) value mark rows differ") unless value_rows == rows
      validate_array_nested_stream_marks(value_stream, first_mark, mark_flat_elements, 4)
      checked_array_mark_byte_count(flat_elements, 4).to_u64
    end

    def array_decimal64_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      raise UnsupportedFormatError.new("Decimal64 Array accessor requires Array(Decimal(P, S)) with P in 10..18") unless WidePart.array_decimal64_scale(@column_type)

      _, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      value_stream = @streams[column]
      _, _, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Decimal64) value mark rows differ") unless value_rows == rows
      validate_array_nested_stream_marks(value_stream, first_mark, mark_flat_elements, 8)
      checked_array_mark_byte_count(flat_elements, 8).to_u64
    end

    def array_decimal128_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      raise UnsupportedFormatError.new("Decimal128 Array accessor requires Array(Decimal(P, S)) with P in 19..38") unless WidePart.array_decimal128_scale(@column_type)

      _, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      value_stream = @streams[column]
      _, _, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Decimal128) value mark rows differ") unless value_rows == rows
      validate_array_nested_stream_marks(value_stream, first_mark, mark_flat_elements, 16)
      checked_array_mark_byte_count(flat_elements, 16).to_u64
    end

    def array_decimal256_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      raise UnsupportedFormatError.new("Decimal256 Array accessor requires Array(Decimal(P, S)) with P in 39..76") unless WidePart.array_decimal256_scale(@column_type)

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

    # Count all four physical streams for an exact
    # Array(Array(Nullable(T))) range before allocating nested rows. Nullable
    # slots retain one null byte and one fixed-width value slot per leaf.
    def array_array_nullable_numeric_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      element_type = WidePart.array_array_nullable_numeric_element_type(@column_type) ||
                     raise(UnsupportedFormatError.new("nested Array nullable numeric accessor requires an exact Array(Array(Nullable(T))) numeric column"))

      validate_array_array_numeric_size0_marks(column, first_mark, mark_count)
      validate_array_array_nullable_numeric_stream_mark_rows(column, first_mark, mark_count)
      outer_sizes, flat_inner_arrays, rows, mark_inner_arrays = read_array_outer_sizes(column, first_mark, mark_count)
      element_sizes, flat_leaf_elements, mark_leaf_elements = read_array_array_numeric_element_sizes(
        column,
        first_mark,
        mark_count,
        flat_inner_arrays,
        rows,
        mark_inner_arrays,
        WidePart.array_numeric_payload_width(element_type)
      )
      raise CorruptPartError.new("Array(Array(Nullable(T))) outer row count changed") unless outer_sizes.size.to_u64 == rows
      raise CorruptPartError.new("Array(Array(Nullable(T))) nested size count changed") unless element_sizes.size.to_u64 == flat_inner_arrays

      null_stream = @streams["#{column}.null"]
      null_start, null_end, null_rows = checked_stream_mark_range(null_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Array(Nullable(T))) null-map mark rows differ") unless null_rows == rows
      validate_array_nested_stream_marks(null_stream, first_mark, mark_leaf_elements, 1)

      value_stream = @streams[column]
      value_start, value_end, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Array(Nullable(T))) value mark rows differ") unless value_rows == rows
      element_width = WidePart.array_numeric_payload_width(element_type)
      validate_array_nested_stream_marks(value_stream, first_mark, mark_leaf_elements, element_width)

      outer_bytes = checked_byte_count(rows, 8).to_u64
      inner_bytes = checked_array_mark_byte_count(flat_inner_arrays, 8).to_u64
      null_bytes = checked_array_mark_byte_count(flat_leaf_elements, 1).to_u64
      value_bytes = checked_array_mark_byte_count(flat_leaf_elements, element_width).to_u64
      {inner_bytes, null_bytes, value_bytes}.each do |bytes|
        raise CorruptPartError.new("Array(Array(Nullable(T))) raw byte count overflows") if bytes > UInt64::MAX - outer_bytes
        outer_bytes += bytes
      end
      outer_bytes
    end

    # W64 Decimal accessors use the same bounded depth-two offset codec as
    # primitive numeric leaves, but reach it only through exact Decimal(P, S)
    # metadata gates. These byte counts preflight every selected physical
    # stream before table materialization.
    def array_array_decimal32_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      raise UnsupportedFormatError.new("Decimal32 nested Array accessor requires Array(Array(Decimal(P, S))) with P in 1..9") unless WidePart.array_array_decimal32_scale(@column_type)
      array_array_decimal_mark_range_raw_bytes(column, first_mark, mark_count, 4, false)
    end

    def array_array_decimal64_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      raise UnsupportedFormatError.new("Decimal64 nested Array accessor requires Array(Array(Decimal(P, S))) with P in 10..18") unless WidePart.array_array_decimal64_scale(@column_type)
      array_array_decimal_mark_range_raw_bytes(column, first_mark, mark_count, 8, false)
    end

    def array_array_decimal128_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      raise UnsupportedFormatError.new("Decimal128 nested Array accessor requires Array(Array(Decimal(P, S))) with P in 19..38") unless WidePart.array_array_decimal128_scale(@column_type)
      array_array_decimal_mark_range_raw_bytes(column, first_mark, mark_count, 16, false)
    end

    def array_array_decimal256_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      raise UnsupportedFormatError.new("Decimal256 nested Array accessor requires Array(Array(Decimal(P, S))) with P in 39..76") unless WidePart.array_array_decimal256_scale(@column_type)
      array_array_decimal_mark_range_raw_bytes(column, first_mark, mark_count, 32, false)
    end

    def array_array_nullable_decimal32_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      raise UnsupportedFormatError.new("Decimal32 nested nullable Array accessor requires Array(Array(Nullable(Decimal(P, S)))) with P in 1..9") unless WidePart.array_array_nullable_decimal32_scale(@column_type)
      array_array_decimal_mark_range_raw_bytes(column, first_mark, mark_count, 4, true)
    end

    def array_array_nullable_decimal64_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      raise UnsupportedFormatError.new("Decimal64 nested nullable Array accessor requires Array(Array(Nullable(Decimal(P, S)))) with P in 10..18") unless WidePart.array_array_nullable_decimal64_scale(@column_type)
      array_array_decimal_mark_range_raw_bytes(column, first_mark, mark_count, 8, true)
    end

    def array_array_nullable_decimal128_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      raise UnsupportedFormatError.new("Decimal128 nested nullable Array accessor requires Array(Array(Nullable(Decimal(P, S)))) with P in 19..38") unless WidePart.array_array_nullable_decimal128_scale(@column_type)
      array_array_decimal_mark_range_raw_bytes(column, first_mark, mark_count, 16, true)
    end

    def array_array_nullable_decimal256_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_column(column)
      raise UnsupportedFormatError.new("Decimal256 nested nullable Array accessor requires Array(Array(Nullable(Decimal(P, S)))) with P in 39..76") unless WidePart.array_array_nullable_decimal256_scale(@column_type)
      array_array_decimal_mark_range_raw_bytes(column, first_mark, mark_count, 32, true)
    end

    private def array_array_decimal_mark_range_raw_bytes(
      column : String,
      first_mark : Int,
      mark_count : Int,
      element_width : Int32,
      nullable : Bool,
    ) : UInt64
      validate_array_array_numeric_size0_marks(column, first_mark, mark_count)
      validate_array_array_decimal_stream_mark_rows(column, first_mark, mark_count, nullable)
      outer_sizes, flat_inner_arrays, rows, mark_inner_arrays = read_array_outer_sizes(column, first_mark, mark_count)
      element_sizes, flat_leaf_elements, mark_leaf_elements = read_array_array_numeric_element_sizes(
        column,
        first_mark,
        mark_count,
        flat_inner_arrays,
        rows,
        mark_inner_arrays,
        element_width
      )
      raise CorruptPartError.new("Array(Array(Decimal)) outer row count changed") unless outer_sizes.size.to_u64 == rows
      raise CorruptPartError.new("Array(Array(Decimal)) nested size count changed") unless element_sizes.size.to_u64 == flat_inner_arrays

      value_stream = @streams[column]
      value_start, value_end, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Array(Decimal)) value mark rows differ") unless value_rows == rows
      validate_array_nested_stream_marks(value_stream, first_mark, mark_leaf_elements, element_width)
      validate_mark_range_bytes(
        value_stream,
        value_start,
        value_end,
        checked_array_mark_byte_count(flat_leaf_elements, element_width),
        element_width
      )

      outer_bytes = checked_byte_count(rows, 8).to_u64
      inner_bytes = checked_array_mark_byte_count(flat_inner_arrays, 8).to_u64
      value_bytes = checked_array_mark_byte_count(flat_leaf_elements, element_width).to_u64
      if nullable
        null_stream = @streams["#{column}.null"]
        null_start, null_end, null_rows = checked_stream_mark_range(null_stream, first_mark, mark_count)
        raise CorruptPartError.new("Array(Array(Nullable(Decimal))) null-map mark rows differ") unless null_rows == rows
        validate_array_nested_stream_marks(null_stream, first_mark, mark_leaf_elements, 1)
        null_map = read_mark_range_bytes(
          null_stream,
          null_start,
          null_end,
          checked_array_mark_byte_count(flat_leaf_elements, 1),
          1
        )
        null_map.each do |value|
          raise CorruptPartError.new("Array(Array(Nullable(Decimal))) null-map byte is not boolean") unless value <= 1_u8
        end
        null_bytes = checked_array_mark_byte_count(flat_leaf_elements, 1).to_u64
        {inner_bytes, null_bytes, value_bytes}.each do |bytes|
          raise CorruptPartError.new("Array(Array(Nullable(Decimal))) raw byte count overflows") if bytes > UInt64::MAX - outer_bytes
          outer_bytes += bytes
        end
      else
        if inner_bytes > UInt64::MAX - outer_bytes || value_bytes > UInt64::MAX - outer_bytes - inner_bytes
          raise CorruptPartError.new("Array(Array(Decimal)) raw byte count overflows")
        end
        outer_bytes += inner_bytes + value_bytes
      end
      outer_bytes
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
      raise UnsupportedFormatError.new("Decimal32 Array accessor requires Array(Nullable(Decimal(P, S))) with P in 1..9") unless WidePart.array_nullable_decimal32_scale(@column_type)

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
      raise UnsupportedFormatError.new("Decimal64 Array accessor requires Array(Nullable(Decimal(P, S))) with P in 10..18") unless WidePart.array_nullable_decimal64_scale(@column_type)

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
      raise UnsupportedFormatError.new("Decimal128 Array accessor requires Array(Nullable(Decimal(P, S))) with P in 19..38") unless WidePart.array_nullable_decimal128_scale(@column_type)

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
      raise UnsupportedFormatError.new("Decimal256 Array accessor requires Array(Nullable(Decimal(P, S))) with P in 39..76") unless WidePart.array_nullable_decimal256_scale(@column_type)

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
      ensure_array_tuple_type(column, WideTypePlan::TYPE_ARRAY_TUPLE_UINT64_STRING)
      array_tuple_components(column, first_mark, mark_count, false).materialized_bytes
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
      ensure_array_tuple_type(column, WideTypePlan::TYPE_ARRAY_TUPLE_NULLABLE_UINT64_STRING)
      array_tuple_components(column, first_mark, mark_count, false).materialized_bytes
    end

    def array_tuple_uint64_uint64_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      preflight_array_tuple_uint64_uint64_mark_range_raw_bytes(column, first_mark, mark_count)
    end

    def preflight_array_tuple_uint64_uint64_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      ensure_array_tuple_type(column, WideTypePlan::TYPE_ARRAY_TUPLE_UINT64_UINT64)
      array_tuple_components(column, first_mark, mark_count, false).materialized_bytes
    end

    # Read exact W51 Array(Tuple(a UInt64, b String)) rows. Each selected
    # mark's flattened child counts are checked independently before strings
    # and nested row arrays are assembled.
    def read_array_tuple_uint64_string_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Tuple(UInt64, String)))
      ensure_array_tuple_type(column, WideTypePlan::TYPE_ARRAY_TUPLE_UINT64_STRING)
      components = array_tuple_components(column, first_mark, mark_count, true)
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
      ensure_array_tuple_type(column, WideTypePlan::TYPE_ARRAY_TUPLE_NULLABLE_UINT64_STRING)
      components = array_tuple_components(column, first_mark, mark_count, true)
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

    # Read exact W55 Array(Tuple(a UInt64, b UInt64)) rows through the shared
    # plan-driven child validation and fixed-width leaf reader used by W51.
    def read_array_tuple_uint64_uint64_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Tuple(UInt64, UInt64)))
      ensure_array_tuple_type(column, WideTypePlan::TYPE_ARRAY_TUPLE_UINT64_UINT64)
      components = array_tuple_components(column, first_mark, mark_count, true)
      first_values = components.numeric_values.not_nil!
      second_values = components.second_numeric_values.not_nil!
      rows = Array(Array(Tuple(UInt64, UInt64))).new(components.rows.to_i)
      element_offset = 0
      components.outer_sizes.each do |size|
        row = Array(Tuple(UInt64, UInt64)).new(size.to_i)
        size.to_i.times do
          value_offset = element_offset * 8
          row << {u64(first_values, value_offset), u64(second_values, value_offset)}
          element_offset += 1
        end
        rows << row
      end
      raise CorruptPartError.new("Array(Tuple) size0 does not consume child values") unless element_offset.to_u64 == components.flat_elements
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

    # Validate a selected W76 Map(UInt64, T) range and return its raw payload
    # and bounded table materialization charge without building row objects.
    def map_uint64_numeric_mark_range_materialization_preflight(
      column : String,
      first_mark : Int,
      mark_count : Int,
      type : T.class,
    ) : {UInt64, UInt64} forall T
      expected_type = WidePart.numeric_type_name(type)
      preflight = numeric_map_preflight(column, first_mark, mark_count, expected_type, false)
      {preflight.payload_bytes, preflight.charge_bytes}
    end

    # Read exact ordered Map(UInt64, T) rows. Duplicate keys and insertion
    # order are retained, and each child mark is checked against size0.
    def read_map_uint64_numeric_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
      type : T.class,
    ) : Array(Array(Tuple(UInt64, T))) forall T
      expected_type = WidePart.numeric_type_name(type)
      preflight = numeric_map_preflight(column, first_mark, mark_count, expected_type, false)
      key_stream = @streams["#{column}%2Ekeys"]
      key_start, key_end, _ = checked_stream_mark_range(key_stream, first_mark, mark_count)
      key_bytes = read_mark_range_bytes(key_stream, key_start, key_end, preflight.key_payload_bytes.to_i, 8)

      value_stream = @streams["#{column}%2Evalues"]
      value_start, value_end, _ = checked_stream_mark_range(value_stream, first_mark, mark_count)
      width = WidePart.numeric_payload_width(expected_type)
      value_bytes = read_mark_range_bytes(
        value_stream,
        value_start,
        value_end,
        preflight.value_payload_bytes.to_i,
        width
      )

      result = Array(Array(Tuple(UInt64, T))).new(preflight.rows.to_i)
      flat_offset = 0
      value_offset = 0
      preflight.outer_sizes.each do |size|
        row = Array(Tuple(UInt64, T)).new(size.to_i)
        size.to_i.times do
          raise CorruptPartError.new("Map outer sizes exceed selected numeric children") if flat_offset >= preflight.flat_elements
          raise CorruptPartError.new("Map numeric values exceed selected payload bytes") if value_offset > value_bytes.size - width
          row << {u64(key_bytes, flat_offset * 8), decode_numeric_value(value_bytes, value_offset, type)}
          flat_offset += 1
          value_offset += width
        end
        result << row
      end
      raise CorruptPartError.new("Map sizes do not consume selected keys") unless flat_offset.to_u64 == preflight.flat_elements
      raise CorruptPartError.new("Map sizes do not consume selected numeric values") unless value_offset == value_bytes.size
      result
    end

    # Validate a selected W76 Map(String, T) range and return its raw payload
    # and bounded table materialization charge without building row objects.
    def map_string_numeric_mark_range_materialization_preflight(
      column : String,
      first_mark : Int,
      mark_count : Int,
      type : T.class,
    ) : {UInt64, UInt64} forall T
      expected_type = WidePart.numeric_type_name(type)
      preflight = numeric_map_preflight(column, first_mark, mark_count, expected_type, true)
      {preflight.payload_bytes, preflight.charge_bytes}
    end

    # Read exact ordered Map(String, T) rows, preserving duplicate keys and
    # the insertion order represented by the flattened child streams.
    def read_map_string_numeric_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
      type : T.class,
    ) : Array(Array(Tuple(String, T))) forall T
      expected_type = WidePart.numeric_type_name(type)
      preflight = numeric_map_preflight(column, first_mark, mark_count, expected_type, true)
      key_stream = @streams["#{column}%2Ekeys"]
      key_start, key_end, _ = checked_stream_mark_range(key_stream, first_mark, mark_count)
      key_bytes = read_mark_range_bytes(key_stream, key_start, key_end, preflight.key_payload_bytes.to_i, 1)

      value_stream = @streams["#{column}%2Evalues"]
      value_start, value_end, _ = checked_stream_mark_range(value_stream, first_mark, mark_count)
      width = WidePart.numeric_payload_width(expected_type)
      value_bytes = read_mark_range_bytes(
        value_stream,
        value_start,
        value_end,
        preflight.value_payload_bytes.to_i,
        width
      )

      result = Array(Array(Tuple(String, T))).new(preflight.rows.to_i)
      flat_offset = 0
      raw_offset = 0
      value_offset = 0
      preflight.outer_sizes.each do |size|
        row = Array(Tuple(String, T)).new(size.to_i)
        size.to_i.times do
          raise CorruptPartError.new("Map outer sizes exceed selected numeric keys") if flat_offset >= preflight.key_sizes.size
          length = preflight.key_sizes[flat_offset].to_i
          raise CorruptPartError.new("Map key sizes exceed selected raw bytes") if length > key_bytes.size - raw_offset
          raise CorruptPartError.new("Map numeric values exceed selected payload bytes") if value_offset > value_bytes.size - width
          row << {String.new(key_bytes[raw_offset, length]), decode_numeric_value(value_bytes, value_offset, type)}
          raw_offset += length
          value_offset += width
          flat_offset += 1
        end
        result << row
      end
      raise CorruptPartError.new("Map sizes do not consume selected key lengths") unless flat_offset == preflight.key_sizes.size
      raise CorruptPartError.new("Map key lengths do not consume selected raw bytes") unless raw_offset == key_bytes.size
      raise CorruptPartError.new("Map sizes do not consume selected numeric values") unless value_offset == value_bytes.size
      result
    end

    # Return physical payload and bounded materialization charge for one
    # exact Map(K, Array(T)) selection. The W73 accounting contract charges
    # visible keys plus numeric leaves, row/entry slots, and one Array header
    # per Map entry; size streams are validation metadata, not payload.
    private def numeric_array_map_preflight(
      column : String,
      first_mark : Int,
      mark_count : Int,
      string_keys : Bool,
      expected_type : String?,
      nullable_values : Bool = false,
    ) : NumericArrayMapPreflight
      ensure_column(column)
      declared_type = if string_keys
                        nullable_values ? WidePart.map_string_array_nullable_numeric_value_type(@column_type) : WidePart.map_string_array_numeric_value_type(@column_type)
                      else
                        nullable_values ? WidePart.map_uint64_array_nullable_numeric_value_type(@column_type) : WidePart.map_uint64_array_numeric_value_type(@column_type)
                      end
      unless declared_type
        key_shape = string_keys ? "String" : "UInt64"
        value_shape = nullable_values ? "Array(Nullable(T))" : "Array(T)"
        raise UnsupportedFormatError.new("Map accessor requires an exact Map(#{key_shape}, #{value_shape}) column")
      end
      unless expected_type.nil? || declared_type == expected_type
        raise UnsupportedFormatError.new("numeric Map Array accessor type does not match its exact declared T")
      end

      outer_sizes, entries, rows, mark_entries = read_array_outer_sizes(column, first_mark, mark_count)
      validate_map_array_uint64_size0_marks(column, first_mark, mark_count, rows)
      validate_numeric_array_map_child_rows(column, first_mark, mark_count, string_keys, nullable_values)

      key_sizes = [] of UInt64
      key_payload_bytes = 0_u64
      key_mark_bytes = [] of UInt64
      if string_keys
        key_sizes, key_payload_bytes, key_mark_bytes = read_map_string_child_sizes(
          column, "%2Ekeys", "Map key", first_mark, mark_count, entries, rows, mark_entries
        )
        raise CorruptPartError.new("Map key size count differs from size0") unless key_sizes.size.to_u64 == entries
      else
        key_stream = @streams["#{column}%2Ekeys"]
        validate_array_nested_stream_marks(key_stream, first_mark, mark_entries, 8)
        key_payload_bytes = checked_array_mark_byte_count(entries, 8).to_u64
        key_mark_bytes = mark_entries.map { |mark_entries| checked_array_mark_byte_count(mark_entries, 8).to_u64 }
      end

      value_type = declared_type.not_nil!
      width = WidePart.numeric_payload_width(value_type)
      value_sizes, leaves, mark_leaf_counts = read_map_array_numeric_value_sizes(
        column, first_mark, mark_count, entries, rows, mark_entries, width
      )
      value_payload_bytes = checked_array_mark_byte_count(leaves, width).to_u64
      null_map = if nullable_values
                   read_map_nullable_uint64_null_map(column, first_mark, mark_count, leaves, rows, mark_leaf_counts)
                 else
                   nil
                 end
      null_payload_bytes = nullable_values ? checked_array_mark_byte_count(leaves, 1).to_u64 : 0_u64
      combined_value_bytes = checked_array_mark_byte_count(leaves, width + (nullable_values ? 1 : 0)).to_u64
      value_mark_bytes = mark_leaf_counts.map do |mark_leaves|
        checked_array_mark_byte_count(mark_leaves, width + (nullable_values ? 1 : 0)).to_u64
      end
      payload_bytes = checked_map_materialized_bytes(key_payload_bytes, combined_value_bytes, key_mark_bytes, value_mark_bytes)
      charge_bytes = checked_map_string_array_charge(payload_bytes, entries, rows, @column_type)
      NumericArrayMapPreflight.new(
        outer_sizes,
        key_sizes,
        value_sizes,
        entries,
        leaves,
        rows,
        key_payload_bytes,
        value_payload_bytes,
        payload_bytes,
        charge_bytes,
        null_payload_bytes,
        null_map
      )
    end

    # Decode W78's per-entry values.size1 counts and preflight each numeric
    # leaf mark at its declared physical width before any row materialization.
    private def read_map_array_numeric_value_sizes(
      column : String,
      first_mark : Int,
      mark_count : Int,
      entries : UInt64,
      outer_rows : UInt64,
      mark_entries : Array(UInt64),
      width : Int32,
    ) : {Array(UInt64), UInt64, Array(UInt64)}
      size_stream = @streams["#{column}%2Evalues.size1"]
      size_start, size_end, size_rows = checked_stream_mark_range(size_stream, first_mark, mark_count)
      raise CorruptPartError.new("Map value-size substream mark rows differ") unless size_rows == outer_rows
      validate_array_nested_stream_marks(size_stream, first_mark, mark_entries, 8)
      encoded_sizes = read_mark_range_bytes(
        size_stream, size_start, size_end, checked_array_mark_byte_count(entries, 8), 8
      )

      value_sizes = Array(UInt64).new(entries.to_i)
      mark_leaf_counts = Array(UInt64).new(mark_count)
      total_leaves = 0_u64
      size_offset = 0
      mark_entries.each do |mark_entry_count|
        mark_leaf_count = 0_u64
        mark_entry_count.to_i.times do
          raise CorruptPartError.new("Map value-size count exceeds selected bytes") if size_offset > encoded_sizes.size - 8
          leaf_count = u64(encoded_sizes, size_offset)
          if leaf_count > MAX_ARRAY_MARK_ELEMENTS - mark_leaf_count || leaf_count > MAX_ARRAY_MARK_ELEMENTS - total_leaves
            raise CorruptPartError.new("Map nested numeric Array count exceeds per-range limit")
          end
          mark_leaf_count += leaf_count
          total_leaves += leaf_count
          value_sizes << leaf_count
          size_offset += 8
        end
        checked_array_mark_byte_count(mark_leaf_count, width)
        mark_leaf_counts << mark_leaf_count
      end
      raise CorruptPartError.new("Map value-size stream has trailing bytes") unless size_offset == encoded_sizes.size
      raise CorruptPartError.new("Map value-size count does not match size0") unless value_sizes.size.to_u64 == entries
      checked_array_mark_byte_count(total_leaves, width)

      values_stream = @streams["#{column}%2Evalues"]
      _, _, value_rows = checked_stream_mark_range(values_stream, first_mark, mark_count)
      raise CorruptPartError.new("Map value substream mark rows differ") unless value_rows == outer_rows
      validate_array_nested_stream_marks(values_stream, first_mark, mark_leaf_counts, width)
      {value_sizes, total_leaves, mark_leaf_counts}
    end

    # Every child retains the root size0 table-row coordinate at each selected
    # mark, including empty marks and the terminal all-empty boundary.
    private def validate_numeric_array_map_child_rows(
      column : String,
      first_mark : Int,
      mark_count : Int,
      string_keys : Bool,
      nullable_values : Bool = false,
    ) : Nil
      size0_stream = @streams["#{column}.size0"]
      child_names = if string_keys
                      nullable_values ? ["#{column}%2Ekeys.size", "#{column}%2Ekeys", "#{column}%2Evalues.size1", "#{column}%2Evalues.null", "#{column}%2Evalues"] : ["#{column}%2Ekeys.size", "#{column}%2Ekeys", "#{column}%2Evalues.size1", "#{column}%2Evalues"]
                    else
                      nullable_values ? ["#{column}%2Ekeys", "#{column}%2Evalues.size1", "#{column}%2Evalues.null", "#{column}%2Evalues"] : ["#{column}%2Ekeys", "#{column}%2Evalues.size1", "#{column}%2Evalues"]
                    end
      child_names.each do |name|
        child = @streams[name]
        _, _, rows = checked_stream_mark_range(child, first_mark, mark_count)
        raise CorruptPartError.new("Map child substream mark rows differ") unless rows == rows_in_range(first_mark, mark_count)
        mark_count.times do |range_mark_index|
          mark_index = first_mark + range_mark_index
          unless child.marks[mark_index].rows == size0_stream.marks[mark_index].rows
            raise CorruptPartError.new("Map child substream mark rows differ")
          end
        end
      end
      nil
    end

    # Return physical key and numeric leaf bytes for an exact W78
    # Map(UInt64, Array(T)) range without materializing ordered rows.
    def map_uint64_array_numeric_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      numeric_array_map_preflight(column, first_mark, mark_count, false, nil).payload_bytes
    end

    # Return physical key and numeric leaf bytes for an exact W78
    # Map(String, Array(T)) range without materializing ordered rows.
    def map_string_array_numeric_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      numeric_array_map_preflight(column, first_mark, mark_count, true, nil).payload_bytes
    end

    # Validate a selected W78 Map(UInt64, Array(T)) range and return its raw
    # payload plus the W73 row/entry/nested-Array materialization charge.
    def map_uint64_array_numeric_mark_range_materialization_preflight(
      column : String,
      first_mark : Int,
      mark_count : Int,
      type : T.class,
    ) : {UInt64, UInt64} forall T
      expected_type = WidePart.numeric_type_name(type)
      preflight = numeric_array_map_preflight(column, first_mark, mark_count, false, expected_type)
      {preflight.payload_bytes, preflight.charge_bytes}
    end

    # Validate a selected W78 Map(String, Array(T)) range and return its raw
    # payload plus the W73 row/entry/nested-Array materialization charge.
    def map_string_array_numeric_mark_range_materialization_preflight(
      column : String,
      first_mark : Int,
      mark_count : Int,
      type : T.class,
    ) : {UInt64, UInt64} forall T
      expected_type = WidePart.numeric_type_name(type)
      preflight = numeric_array_map_preflight(column, first_mark, mark_count, true, expected_type)
      {preflight.payload_bytes, preflight.charge_bytes}
    end

    # Decode ordered UInt64-key W78 Map entries. Duplicate keys and empty
    # nested Arrays are retained; numeric leaves use W76 bit-preserving decode.
    def read_map_uint64_array_numeric_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
      type : T.class,
    ) : Array(Array(Tuple(UInt64, Array(T)))) forall T
      expected_type = WidePart.numeric_type_name(type)
      preflight = numeric_array_map_preflight(column, first_mark, mark_count, false, expected_type)
      key_stream = @streams["#{column}%2Ekeys"]
      key_start, key_end, _ = checked_stream_mark_range(key_stream, first_mark, mark_count)
      key_bytes = read_mark_range_bytes(
        key_stream, key_start, key_end, checked_array_mark_byte_count(preflight.entries, 8), 8
      )
      value_stream = @streams["#{column}%2Evalues"]
      value_start, value_end, _ = checked_stream_mark_range(value_stream, first_mark, mark_count)
      width = WidePart.numeric_payload_width(expected_type)
      value_bytes = read_mark_range_bytes(value_stream, value_start, value_end, preflight.value_payload_bytes.to_i, width)

      result = Array(Array(Tuple(UInt64, Array(T)))).new(preflight.rows.to_i)
      entry_offset = 0
      value_offset = 0
      preflight.outer_sizes.each do |entry_count|
        row = Array(Tuple(UInt64, Array(T))).new(entry_count.to_i)
        entry_count.to_i.times do
          raise CorruptPartError.new("Map outer sizes exceed selected numeric Array entries") if entry_offset >= preflight.entries
          value_count = preflight.value_sizes[entry_offset]
          remaining_values = value_offset > value_bytes.size ? 0 : ((value_bytes.size - value_offset) // width).to_u64
          raise CorruptPartError.new("Map nested sizes exceed selected numeric Array values") if value_count > remaining_values
          nested_values = Array(T).new(value_count.to_i)
          value_count.to_i.times do
            nested_values << decode_numeric_value(value_bytes, value_offset, type)
            value_offset += width
          end
          row << {u64(key_bytes, entry_offset * 8), nested_values}
          entry_offset += 1
        end
        result << row
      end
      raise CorruptPartError.new("Map sizes do not consume selected numeric Array entries") unless entry_offset.to_u64 == preflight.entries
      raise CorruptPartError.new("Map nested sizes do not consume selected numeric Array values") unless value_offset == value_bytes.size
      result
    end

    # Decode ordered String-key W78 Map entries. Binary and empty keys,
    # duplicate keys, empty nested Arrays, and floating payload bits survive.
    def read_map_string_array_numeric_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
      type : T.class,
    ) : Array(Array(Tuple(String, Array(T)))) forall T
      expected_type = WidePart.numeric_type_name(type)
      preflight = numeric_array_map_preflight(column, first_mark, mark_count, true, expected_type)
      key_stream = @streams["#{column}%2Ekeys"]
      key_start, key_end, _ = checked_stream_mark_range(key_stream, first_mark, mark_count)
      key_bytes = read_mark_range_bytes(key_stream, key_start, key_end, preflight.key_payload_bytes.to_i, 1)
      value_stream = @streams["#{column}%2Evalues"]
      value_start, value_end, _ = checked_stream_mark_range(value_stream, first_mark, mark_count)
      width = WidePart.numeric_payload_width(expected_type)
      value_bytes = read_mark_range_bytes(value_stream, value_start, value_end, preflight.value_payload_bytes.to_i, width)

      result = Array(Array(Tuple(String, Array(T)))).new(preflight.rows.to_i)
      entry_offset = 0
      key_offset = 0
      value_offset = 0
      preflight.outer_sizes.each do |entry_count|
        row = Array(Tuple(String, Array(T))).new(entry_count.to_i)
        entry_count.to_i.times do
          raise CorruptPartError.new("Map outer sizes exceed selected numeric Array keys") if entry_offset >= preflight.entries
          key_size = preflight.key_sizes[entry_offset].to_i
          if key_offset > key_bytes.size || key_size > key_bytes.size - key_offset
            raise CorruptPartError.new("Map key sizes exceed selected raw bytes")
          end
          value_count = preflight.value_sizes[entry_offset]
          remaining_values = value_offset > value_bytes.size ? 0 : ((value_bytes.size - value_offset) // width).to_u64
          raise CorruptPartError.new("Map nested sizes exceed selected numeric Array values") if value_count > remaining_values
          nested_values = Array(T).new(value_count.to_i)
          value_count.to_i.times do
            nested_values << decode_numeric_value(value_bytes, value_offset, type)
            value_offset += width
          end
          row << {String.new(key_bytes[key_offset, key_size]), nested_values}
          key_offset += key_size
          entry_offset += 1
        end
        result << row
      end
      raise CorruptPartError.new("Map sizes do not consume selected numeric Array entries") unless entry_offset.to_u64 == preflight.entries
      raise CorruptPartError.new("Map key lengths do not consume selected raw bytes") unless key_offset == key_bytes.size
      raise CorruptPartError.new("Map nested sizes do not consume selected numeric Array values") unless value_offset == value_bytes.size
      result
    end

    # Return key bytes, nullable bitmap bytes, and fixed-width leaf bytes for
    # a W79 Map(UInt64, Array(Nullable(T))) selection, without materializing
    # ordered rows.
    def map_uint64_array_nullable_numeric_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      numeric_array_map_preflight(column, first_mark, mark_count, false, nil, true).payload_bytes
    end

    # Return key bytes, nullable bitmap bytes, and fixed-width leaf bytes for
    # a W79 Map(String, Array(Nullable(T))) selection, without materializing
    # ordered rows.
    def map_string_array_nullable_numeric_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      numeric_array_map_preflight(column, first_mark, mark_count, true, nil, true).payload_bytes
    end

    # Validate one W79 UInt64-key mark range and return physical payload bytes
    # plus the bounded Map/entry/nested-Array materialization charge.
    def map_uint64_array_nullable_numeric_mark_range_materialization_preflight(
      column : String,
      first_mark : Int,
      mark_count : Int,
      type : T.class,
    ) : {UInt64, UInt64} forall T
      expected_type = WidePart.numeric_type_name(type)
      preflight = numeric_array_map_preflight(column, first_mark, mark_count, false, expected_type, true)
      {preflight.payload_bytes, preflight.charge_bytes}
    end

    # Validate one W79 String-key mark range and return physical payload bytes
    # plus the bounded Map/entry/nested-Array materialization charge.
    def map_string_array_nullable_numeric_mark_range_materialization_preflight(
      column : String,
      first_mark : Int,
      mark_count : Int,
      type : T.class,
    ) : {UInt64, UInt64} forall T
      expected_type = WidePart.numeric_type_name(type)
      preflight = numeric_array_map_preflight(column, first_mark, mark_count, true, expected_type, true)
      {preflight.payload_bytes, preflight.charge_bytes}
    end

    # Decode ordered W79 UInt64-key Map entries. NULL leaves consume their
    # fixed-width slot in `%2Evalues`, preserving the next leaf's alignment.
    def read_map_uint64_array_nullable_numeric_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
      type : T.class,
    ) : Array(Array(Tuple(UInt64, Array(T?)))) forall T
      expected_type = WidePart.numeric_type_name(type)
      preflight = numeric_array_map_preflight(column, first_mark, mark_count, false, expected_type, true)
      key_stream = @streams["#{column}%2Ekeys"]
      key_start, key_end, _ = checked_stream_mark_range(key_stream, first_mark, mark_count)
      key_bytes = read_mark_range_bytes(key_stream, key_start, key_end, checked_array_mark_byte_count(preflight.entries, 8), 8)
      null_map = preflight.null_map.not_nil!
      value_stream = @streams["#{column}%2Evalues"]
      value_start, value_end, _ = checked_stream_mark_range(value_stream, first_mark, mark_count)
      width = WidePart.numeric_payload_width(expected_type)
      value_bytes = read_mark_range_bytes(value_stream, value_start, value_end, preflight.value_payload_bytes.to_i, width)

      result = Array(Array(Tuple(UInt64, Array(T?)))).new(preflight.rows.to_i)
      entry_offset = 0
      leaf_offset = 0
      value_offset = 0
      preflight.outer_sizes.each do |entry_count|
        row = Array(Tuple(UInt64, Array(T?))).new(entry_count.to_i)
        entry_count.to_i.times do
          raise CorruptPartError.new("Map outer sizes exceed selected nullable numeric Array entries") if entry_offset >= preflight.entries
          value_count = preflight.value_sizes[entry_offset]
          remaining_values = value_offset > value_bytes.size ? 0 : ((value_bytes.size - value_offset) // width).to_u64
          raise CorruptPartError.new("Map nested sizes exceed selected nullable numeric Array values") if value_count > remaining_values
          nested_values = Array(T?).new(value_count.to_i)
          value_count.to_i.times do
            raise CorruptPartError.new("Map nullable leaf count exceeds selected null map") if leaf_offset >= null_map.size
            value : T? = null_map[leaf_offset] == 1 ? nil : decode_numeric_value(value_bytes, value_offset, type)
            nested_values << value
            value_offset += width
            leaf_offset += 1
          end
          row << {u64(key_bytes, entry_offset * 8), nested_values}
          entry_offset += 1
        end
        result << row
      end
      raise CorruptPartError.new("Map sizes do not consume selected nullable numeric Array entries") unless entry_offset.to_u64 == preflight.entries
      raise CorruptPartError.new("Map sizes do not consume selected null-map bytes") unless leaf_offset == null_map.size
      raise CorruptPartError.new("Map nested sizes do not consume selected nullable numeric Array values") unless value_offset == value_bytes.size
      result
    end

    # Decode ordered W79 String-key Map entries. Binary/empty keys, duplicate
    # keys, NULL-vs-zero, and nullable hidden-slot alignment are preserved.
    def read_map_string_array_nullable_numeric_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
      type : T.class,
    ) : Array(Array(Tuple(String, Array(T?)))) forall T
      expected_type = WidePart.numeric_type_name(type)
      preflight = numeric_array_map_preflight(column, first_mark, mark_count, true, expected_type, true)
      key_stream = @streams["#{column}%2Ekeys"]
      key_start, key_end, _ = checked_stream_mark_range(key_stream, first_mark, mark_count)
      key_bytes = read_mark_range_bytes(key_stream, key_start, key_end, preflight.key_payload_bytes.to_i, 1)
      null_map = preflight.null_map.not_nil!
      value_stream = @streams["#{column}%2Evalues"]
      value_start, value_end, _ = checked_stream_mark_range(value_stream, first_mark, mark_count)
      width = WidePart.numeric_payload_width(expected_type)
      value_bytes = read_mark_range_bytes(value_stream, value_start, value_end, preflight.value_payload_bytes.to_i, width)

      result = Array(Array(Tuple(String, Array(T?)))).new(preflight.rows.to_i)
      entry_offset = 0
      key_offset = 0
      leaf_offset = 0
      value_offset = 0
      preflight.outer_sizes.each do |entry_count|
        row = Array(Tuple(String, Array(T?))).new(entry_count.to_i)
        entry_count.to_i.times do
          raise CorruptPartError.new("Map outer sizes exceed selected nullable numeric Array keys") if entry_offset >= preflight.entries
          key_size = preflight.key_sizes[entry_offset].to_i
          if key_offset > key_bytes.size || key_size > key_bytes.size - key_offset
            raise CorruptPartError.new("Map key sizes exceed selected raw bytes")
          end
          value_count = preflight.value_sizes[entry_offset]
          remaining_values = value_offset > value_bytes.size ? 0 : ((value_bytes.size - value_offset) // width).to_u64
          raise CorruptPartError.new("Map nested sizes exceed selected nullable numeric Array values") if value_count > remaining_values
          nested_values = Array(T?).new(value_count.to_i)
          value_count.to_i.times do
            raise CorruptPartError.new("Map nullable leaf count exceeds selected null map") if leaf_offset >= null_map.size
            value : T? = null_map[leaf_offset] == 1 ? nil : decode_numeric_value(value_bytes, value_offset, type)
            nested_values << value
            value_offset += width
            leaf_offset += 1
          end
          row << {String.new(key_bytes[key_offset, key_size]), nested_values}
          key_offset += key_size
          entry_offset += 1
        end
        result << row
      end
      raise CorruptPartError.new("Map sizes do not consume selected nullable numeric Array entries") unless entry_offset.to_u64 == preflight.entries
      raise CorruptPartError.new("Map key lengths do not consume selected raw bytes") unless key_offset == key_bytes.size
      raise CorruptPartError.new("Map sizes do not consume selected null-map bytes") unless leaf_offset == null_map.size
      raise CorruptPartError.new("Map nested sizes do not consume selected nullable numeric Array values") unless value_offset == value_bytes.size
      result
    end

    # Validate a selected W77 Map(UInt64, Nullable(T)) range and return its
    # exact key, null-map, and value payload plus bounded materialization charge.
    def map_uint64_nullable_numeric_mark_range_materialization_preflight(
      column : String,
      first_mark : Int,
      mark_count : Int,
      type : T.class,
    ) : {UInt64, UInt64} forall T
      expected_type = WidePart.numeric_type_name(type)
      preflight = numeric_map_preflight(column, first_mark, mark_count, expected_type, false, true)
      {preflight.payload_bytes, preflight.charge_bytes}
    end

    # Read exact ordered Map(UInt64, Nullable(T)) rows. NULL entries retain
    # their key and position, while duplicate keys and insertion order remain
    # unchanged.
    def read_map_uint64_nullable_numeric_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
      type : T.class,
    ) : Array(Array(Tuple(UInt64, T?))) forall T
      expected_type = WidePart.numeric_type_name(type)
      preflight = numeric_map_preflight(column, first_mark, mark_count, expected_type, false, true)
      key_stream = @streams["#{column}%2Ekeys"]
      key_start, key_end, _ = checked_stream_mark_range(key_stream, first_mark, mark_count)
      key_bytes = read_mark_range_bytes(key_stream, key_start, key_end, preflight.key_payload_bytes.to_i, 8)

      null_map = preflight.null_map.not_nil!
      value_stream = @streams["#{column}%2Evalues"]
      value_start, value_end, _ = checked_stream_mark_range(value_stream, first_mark, mark_count)
      width = WidePart.numeric_payload_width(expected_type)
      value_bytes = read_mark_range_bytes(
        value_stream,
        value_start,
        value_end,
        preflight.value_payload_bytes.to_i,
        width
      )

      result = Array(Array(Tuple(UInt64, T?))).new(preflight.rows.to_i)
      flat_offset = 0
      value_offset = 0
      preflight.outer_sizes.each do |size|
        row = Array(Tuple(UInt64, T?)).new(size.to_i)
        size.to_i.times do
          raise CorruptPartError.new("Map outer sizes exceed selected nullable numeric children") if flat_offset >= preflight.flat_elements
          raise CorruptPartError.new("Map Nullable numeric values exceed selected payload bytes") if value_offset > value_bytes.size - width
          value : T? = null_map[flat_offset] == 1 ? nil : decode_numeric_value(value_bytes, value_offset, type)
          row << {u64(key_bytes, flat_offset * 8), value}
          flat_offset += 1
          value_offset += width
        end
        result << row
      end
      raise CorruptPartError.new("Map sizes do not consume selected keys") unless flat_offset.to_u64 == preflight.flat_elements
      raise CorruptPartError.new("Map sizes do not consume selected nullable numeric values") unless value_offset == value_bytes.size
      result
    end

    # Validate a selected W77 Map(String, Nullable(T)) range and return its
    # exact raw key, null-map, and value payload plus bounded materialization charge.
    def map_string_nullable_numeric_mark_range_materialization_preflight(
      column : String,
      first_mark : Int,
      mark_count : Int,
      type : T.class,
    ) : {UInt64, UInt64} forall T
      expected_type = WidePart.numeric_type_name(type)
      preflight = numeric_map_preflight(column, first_mark, mark_count, expected_type, true, true)
      {preflight.payload_bytes, preflight.charge_bytes}
    end

    # Read exact ordered Map(String, Nullable(T)) rows, preserving empty and
    # binary keys, NULL values, duplicate keys, and insertion order.
    def read_map_string_nullable_numeric_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
      type : T.class,
    ) : Array(Array(Tuple(String, T?))) forall T
      expected_type = WidePart.numeric_type_name(type)
      preflight = numeric_map_preflight(column, first_mark, mark_count, expected_type, true, true)
      key_stream = @streams["#{column}%2Ekeys"]
      key_start, key_end, _ = checked_stream_mark_range(key_stream, first_mark, mark_count)
      key_bytes = read_mark_range_bytes(key_stream, key_start, key_end, preflight.key_payload_bytes.to_i, 1)

      null_map = preflight.null_map.not_nil!
      value_stream = @streams["#{column}%2Evalues"]
      value_start, value_end, _ = checked_stream_mark_range(value_stream, first_mark, mark_count)
      width = WidePart.numeric_payload_width(expected_type)
      value_bytes = read_mark_range_bytes(
        value_stream,
        value_start,
        value_end,
        preflight.value_payload_bytes.to_i,
        width
      )

      result = Array(Array(Tuple(String, T?))).new(preflight.rows.to_i)
      flat_offset = 0
      raw_offset = 0
      value_offset = 0
      preflight.outer_sizes.each do |size|
        row = Array(Tuple(String, T?)).new(size.to_i)
        size.to_i.times do
          raise CorruptPartError.new("Map outer sizes exceed selected nullable numeric keys") if flat_offset >= preflight.key_sizes.size
          length = preflight.key_sizes[flat_offset].to_i
          raise CorruptPartError.new("Map key sizes exceed selected raw bytes") if length > key_bytes.size - raw_offset
          raise CorruptPartError.new("Map Nullable numeric values exceed selected payload bytes") if value_offset > value_bytes.size - width
          value : T? = null_map[flat_offset] == 1 ? nil : decode_numeric_value(value_bytes, value_offset, type)
          row << {String.new(key_bytes[raw_offset, length]), value}
          raw_offset += length
          value_offset += width
          flat_offset += 1
        end
        result << row
      end
      raise CorruptPartError.new("Map sizes do not consume selected key lengths") unless flat_offset == preflight.key_sizes.size
      raise CorruptPartError.new("Map key lengths do not consume selected raw bytes") unless raw_offset == key_bytes.size
      raise CorruptPartError.new("Map sizes do not consume selected nullable numeric values") unless value_offset == value_bytes.size
      result
    end

    # Return the String-key and nested UInt64 payload bytes for a selected W63
    # Map range without constructing ordered rows.
    def map_string_array_uint64_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      map_string_array_uint64_payload_preflight(column, first_mark, mark_count)[0]
    end

    # Return payload bytes and bounded materialization charge for W63. Charge
    # includes Map row/tuple slots and one 24-byte nested Array header per
    # entry, including empty value Arrays; UInt64 backing bytes are in payload.
    def map_string_array_uint64_mark_range_materialization_preflight(column : String, first_mark : Int, mark_count : Int) : {UInt64, UInt64}
      payload_bytes, flat_entries, rows = map_string_array_uint64_payload_preflight(column, first_mark, mark_count)
      {payload_bytes, checked_map_string_array_uint64_charge(payload_bytes, flat_entries, rows)}
    end

    private def map_string_array_uint64_payload_preflight(column : String, first_mark : Int, mark_count : Int) : {UInt64, UInt64, UInt64}
      ensure_column(column)
      unless WidePart.supports_map_string_array_uint64_type?(@column_type)
        raise UnsupportedFormatError.new("Map accessor requires an exact Map(String, Array(UInt64)) column")
      end

      _, flat_entries, rows, mark_flat_entries = read_array_outer_sizes(column, first_mark, mark_count)
      validate_map_array_uint64_size0_marks(column, first_mark, mark_count, rows)
      key_sizes, key_bytes, key_mark_bytes = read_map_string_child_sizes(
        column, "%2Ekeys", "Map key", first_mark, mark_count, flat_entries, rows, mark_flat_entries
      )
      raise CorruptPartError.new("Map key size count differs from size0") unless key_sizes.size.to_u64 == flat_entries

      _, flat_values, mark_value_elements = read_map_array_uint64_element_sizes(
        column, first_mark, mark_count, flat_entries, rows, mark_flat_entries
      )
      value_bytes = checked_array_mark_byte_count(flat_values, 8).to_u64
      value_mark_bytes = mark_value_elements.map { |elements| checked_array_mark_byte_count(elements, 8).to_u64 }
      payload_bytes = checked_map_materialized_bytes(key_bytes, value_bytes, key_mark_bytes, value_mark_bytes)
      {payload_bytes, flat_entries, rows}
    end

    # Decode exact ordered Map(String, Array(UInt64)) rows. size0 determines
    # Map-entry order; values.size1 determines each entry's Array length.
    # Duplicate String keys and empty nested Arrays are retained as-is.
    def read_map_string_array_uint64_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Tuple(String, Array(UInt64))))
      ensure_column(column)
      unless WidePart.supports_map_string_array_uint64_type?(@column_type)
        raise UnsupportedFormatError.new("Map accessor requires an exact Map(String, Array(UInt64)) column")
      end

      outer_sizes, flat_entries, rows, mark_flat_entries = read_array_outer_sizes(column, first_mark, mark_count)
      validate_map_array_uint64_size0_marks(column, first_mark, mark_count, rows)
      key_sizes, key_bytes_total, key_mark_bytes = read_map_string_child_sizes(
        column, "%2Ekeys", "Map key", first_mark, mark_count, flat_entries, rows, mark_flat_entries
      )
      raise CorruptPartError.new("Map key size count differs from size0") unless key_sizes.size.to_u64 == flat_entries

      value_sizes, flat_values, mark_value_elements = read_map_array_uint64_element_sizes(
        column, first_mark, mark_count, flat_entries, rows, mark_flat_entries
      )
      value_bytes_total = checked_array_mark_byte_count(flat_values, 8).to_u64
      value_mark_bytes = mark_value_elements.map { |elements| checked_array_mark_byte_count(elements, 8).to_u64 }
      payload_bytes = checked_map_materialized_bytes(key_bytes_total, value_bytes_total, key_mark_bytes, value_mark_bytes)
      checked_map_string_array_uint64_charge(payload_bytes, flat_entries, rows)

      key_stream = @streams["#{column}%2Ekeys"]
      key_start, key_end, key_rows = checked_stream_mark_range(key_stream, first_mark, mark_count)
      raise CorruptPartError.new("Map key substream mark rows differ") unless key_rows == rows
      values_stream = @streams["#{column}%2Evalues"]
      value_start, value_end, value_rows = checked_stream_mark_range(values_stream, first_mark, mark_count)
      raise CorruptPartError.new("Map value substream mark rows differ") unless value_rows == rows

      # Payload copies and result rows are allocated only after all size and
      # mark-level counts, byte lengths, and aggregate charge have passed.
      key_bytes = read_mark_range_bytes(key_stream, key_start, key_end, key_bytes_total.to_i, 1)
      value_bytes = read_mark_range_bytes(values_stream, value_start, value_end, value_bytes_total.to_i, 8)
      result = Array(Array(Tuple(String, Array(UInt64)))).new(rows.to_i)
      entry_offset = 0
      key_offset = 0
      value_offset = 0
      outer_sizes.each do |entry_count|
        row = Array(Tuple(String, Array(UInt64))).new(entry_count.to_i)
        entry_count.to_i.times do
          raise CorruptPartError.new("Map outer sizes exceed selected nested keys") if entry_offset >= key_sizes.size
          key_size = key_sizes[entry_offset].to_i
          raise CorruptPartError.new("Map key sizes exceed selected raw bytes") if key_offset > key_bytes.size || key_size > key_bytes.size - key_offset
          value_count = value_sizes[entry_offset]
          raise CorruptPartError.new("Map value sizes exceed selected UInt64 payload") if value_offset > value_bytes.size || value_count > ((value_bytes.size - value_offset) // 8).to_u64

          nested_values = Array(UInt64).new(value_count.to_i)
          value_count.to_i.times do
            nested_values << u64(value_bytes, value_offset)
            value_offset += 8
          end
          row << {String.new(key_bytes[key_offset, key_size]), nested_values}
          key_offset += key_size
          entry_offset += 1
        end
        result << row
      end
      raise CorruptPartError.new("Map sizes do not consume selected nested keys") unless entry_offset == key_sizes.size
      raise CorruptPartError.new("Map key lengths do not consume selected raw bytes") unless key_offset == key_bytes.size
      raise CorruptPartError.new("Map nested sizes do not consume selected value bytes") unless value_offset == value_bytes.size
      result
    end

    # Return String-key and nested Nullable(UInt64) payload bytes for a
    # selected W68 Map range without constructing ordered rows.
    def map_string_array_nullable_uint64_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      map_string_array_nullable_uint64_payload_preflight(column, first_mark, mark_count)[0]
    end

    # Return payload bytes and the bounded row/entry/nested-Array
    # materialization charge for W68.
    def map_string_array_nullable_uint64_mark_range_materialization_preflight(column : String, first_mark : Int, mark_count : Int) : {UInt64, UInt64}
      payload_bytes, flat_entries, rows = map_string_array_nullable_uint64_payload_preflight(column, first_mark, mark_count)
      {payload_bytes, checked_map_string_array_nullable_uint64_charge(payload_bytes, flat_entries, rows)}
    end

    private def map_string_array_nullable_uint64_payload_preflight(column : String, first_mark : Int, mark_count : Int) : {UInt64, UInt64, UInt64}
      ensure_column(column)
      unless WidePart.supports_map_string_array_nullable_uint64_type?(@column_type)
        raise UnsupportedFormatError.new("Map accessor requires an exact Map(String, Array(Nullable(UInt64))) column")
      end

      _, flat_entries, rows, mark_flat_entries = read_array_outer_sizes(column, first_mark, mark_count)
      validate_map_array_uint64_size0_marks(column, first_mark, mark_count, rows)
      key_sizes, key_bytes, key_mark_bytes = read_map_string_child_sizes(
        column, "%2Ekeys", "Map key", first_mark, mark_count, flat_entries, rows, mark_flat_entries
      )
      raise CorruptPartError.new("Map key size count differs from size0") unless key_sizes.size.to_u64 == flat_entries

      _, flat_values, mark_value_elements = read_map_array_uint64_element_sizes(
        column, first_mark, mark_count, flat_entries, rows, mark_flat_entries
      )
      # ClickHouse Nullable stores one null byte and one fixed-width value
      # slot for every nested element, including elements whose null flag is 1.
      read_map_nullable_uint64_null_map(column, first_mark, mark_count, flat_values, rows, mark_value_elements)
      value_bytes = checked_array_mark_byte_count(flat_values, 9).to_u64
      value_mark_bytes = mark_value_elements.map { |elements| checked_array_mark_byte_count(elements, 9).to_u64 }
      payload_bytes = checked_map_materialized_bytes(key_bytes, value_bytes, key_mark_bytes, value_mark_bytes)
      {payload_bytes, flat_entries, rows}
    end

    # Decode exact ordered Map(String, Array(Nullable(UInt64))) rows.
    # size0 counts Map entries; values.size1 counts each entry's nested
    # elements. Every nested element consumes one null byte and one UInt64
    # slot, even when the result is NULL; duplicate keys and empty Arrays stay
    # in their original entry order.
    def read_map_string_array_nullable_uint64_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Tuple(String, Array(UInt64?))))
      ensure_column(column)
      unless WidePart.supports_map_string_array_nullable_uint64_type?(@column_type)
        raise UnsupportedFormatError.new("Map accessor requires an exact Map(String, Array(Nullable(UInt64))) column")
      end

      payload_bytes, flat_entries, rows = map_string_array_nullable_uint64_payload_preflight(column, first_mark, mark_count)
      checked_map_string_array_nullable_uint64_charge(payload_bytes, flat_entries, rows)
      outer_sizes, checked_flat_entries, checked_rows, mark_flat_entries = read_array_outer_sizes(column, first_mark, mark_count)
      unless checked_flat_entries == flat_entries && checked_rows == rows
        raise CorruptPartError.new("Map size0 changed after preflight")
      end
      validate_map_array_uint64_size0_marks(column, first_mark, mark_count, rows)
      key_sizes, key_bytes_total, _ = read_map_string_child_sizes(
        column, "%2Ekeys", "Map key", first_mark, mark_count, flat_entries, rows, mark_flat_entries
      )
      raise CorruptPartError.new("Map key size count differs from size0") unless key_sizes.size.to_u64 == flat_entries
      value_sizes, flat_values, mark_value_elements = read_map_array_uint64_element_sizes(
        column, first_mark, mark_count, flat_entries, rows, mark_flat_entries
      )

      key_stream = @streams["#{column}%2Ekeys"]
      key_start, key_end, key_rows = checked_stream_mark_range(key_stream, first_mark, mark_count)
      raise CorruptPartError.new("Map key substream mark rows differ") unless key_rows == rows
      key_bytes = read_mark_range_bytes(key_stream, key_start, key_end, key_bytes_total.to_i, 1)

      null_map = read_map_nullable_uint64_null_map(column, first_mark, mark_count, flat_values, rows, mark_value_elements)
      values_stream = @streams["#{column}%2Evalues"]
      value_start, value_end, value_rows = checked_stream_mark_range(values_stream, first_mark, mark_count)
      raise CorruptPartError.new("Map value substream mark rows differ") unless value_rows == rows
      value_bytes = read_mark_range_bytes(values_stream, value_start, value_end, checked_array_mark_byte_count(flat_values, 8), 8)

      result = Array(Array(Tuple(String, Array(UInt64?)))).new(rows.to_i)
      entry_offset = 0
      leaf_offset = 0
      key_offset = 0
      value_offset = 0
      outer_sizes.each do |entry_count|
        row = Array(Tuple(String, Array(UInt64?))).new(entry_count.to_i)
        entry_count.to_i.times do
          raise CorruptPartError.new("Map outer sizes exceed selected nested keys") if entry_offset >= key_sizes.size
          key_size = key_sizes[entry_offset].to_i
          raise CorruptPartError.new("Map key sizes exceed selected raw bytes") if key_offset > key_bytes.size || key_size > key_bytes.size - key_offset
          value_count = value_sizes[entry_offset]
          remaining_values = value_offset > value_bytes.size ? 0 : ((value_bytes.size - value_offset) // 8).to_u64
          raise CorruptPartError.new("Map value sizes exceed selected UInt64 payload") if value_count > remaining_values

          nested_values = Array(UInt64?).new(value_count.to_i)
          value_count.to_i.times do
            raise CorruptPartError.new("Map Nullable values exceed selected null-map bytes") if leaf_offset >= null_map.size
            nested_values << (null_map[leaf_offset] == 1 ? nil : u64(value_bytes, value_offset))
            # A NULL still owns a physical UInt64 slot. Consume it so later
            # non-NULL leaves cannot shift into its position.
            value_offset += 8
            leaf_offset += 1
          end
          row << {String.new(key_bytes[key_offset, key_size]), nested_values}
          key_offset += key_size
          entry_offset += 1
        end
        result << row
      end
      raise CorruptPartError.new("Map sizes do not consume selected nested keys") unless entry_offset == key_sizes.size
      raise CorruptPartError.new("Map key lengths do not consume selected raw bytes") unless key_offset == key_bytes.size
      raise CorruptPartError.new("Map nested sizes do not consume selected null-map slots") unless leaf_offset == null_map.size
      raise CorruptPartError.new("Map nested sizes do not consume selected UInt64 slots") unless value_offset == value_bytes.size
      result
    end

    # Return the physical String-key and nullable String-leaf payload bytes
    # plus bounded materialization charge for one exact W70 Map range.
    def map_string_array_nullable_string_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      map_string_array_nullable_string_payload_preflight(column, first_mark, mark_count)[0]
    end

    def map_string_array_nullable_string_mark_range_materialization_preflight(column : String, first_mark : Int, mark_count : Int) : {UInt64, UInt64}
      payload_bytes, entries, rows, leaves = map_string_array_nullable_string_payload_preflight(column, first_mark, mark_count)
      {payload_bytes, checked_map_string_array_nullable_string_charge(payload_bytes, entries, leaves, rows)}
    end

    private def map_string_array_nullable_string_payload_preflight(column : String, first_mark : Int, mark_count : Int) : {UInt64, UInt64, UInt64, UInt64}
      ensure_column(column)
      unless WidePart.supports_map_string_array_nullable_string_type?(@column_type)
        raise UnsupportedFormatError.new("Map accessor requires an exact Map(String, Array(Nullable(String))) column")
      end

      _, entries, rows, mark_entries = read_array_outer_sizes(column, first_mark, mark_count)
      validate_map_array_uint64_size0_marks(column, first_mark, mark_count, rows)
      _key_sizes, key_bytes, key_mark_bytes = read_map_string_child_sizes(
        column, "%2Ekeys", "Map key", first_mark, mark_count, entries, rows, mark_entries
      )
      _, leaves, mark_leaf_counts = read_map_array_nullable_string_value_sizes(
        column, first_mark, mark_count, entries, rows, mark_entries
      )
      read_map_nullable_string_null_map(column, first_mark, mark_count, leaves, rows, mark_leaf_counts)
      value_sizes, value_bytes, value_mark_bytes = read_map_string_child_sizes(
        column, "%2Evalues", "Map nested Nullable String", first_mark, mark_count, leaves, rows, mark_leaf_counts
      )
      raise CorruptPartError.new("Map nested String size count differs from size1") unless value_sizes.size.to_u64 == leaves

      key_mark_bytes = key_mark_bytes.each_with_index.map do |raw_bytes, index|
        checked_map_string_key_charge(raw_bytes, mark_entries[index])
      end.to_a
      value_mark_bytes = value_mark_bytes.each_with_index.map do |raw_bytes, index|
        checked_map_nullable_string_value_charge(raw_bytes, mark_leaf_counts[index])
      end.to_a
      key_bytes = checked_map_string_key_charge(key_bytes, entries)
      value_bytes = checked_map_nullable_string_value_charge(value_bytes, leaves)
      payload_bytes = checked_map_materialized_bytes(key_bytes, value_bytes, key_mark_bytes, value_mark_bytes)
      {payload_bytes, entries, rows, leaves}
    end

    # Decode exact ordered Map(String, Array(Nullable(String))) rows. The
    # size1 stream is per Map entry; NULL, String-size, and raw-byte streams
    # are per flattened leaf. Every leaf consumes its full raw span, even
    # when its null flag hides the returned String.
    def read_map_string_array_nullable_string_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Tuple(String, Array(String?))))
      ensure_column(column)
      unless WidePart.supports_map_string_array_nullable_string_type?(@column_type)
        raise UnsupportedFormatError.new("Map accessor requires an exact Map(String, Array(Nullable(String))) column")
      end

      payload_bytes, entries, rows, leaves = map_string_array_nullable_string_payload_preflight(column, first_mark, mark_count)
      checked_map_string_array_nullable_string_charge(payload_bytes, entries, leaves, rows)
      outer_sizes, checked_entries, checked_rows, mark_entries = read_array_outer_sizes(column, first_mark, mark_count)
      unless checked_entries == entries && checked_rows == rows
        raise CorruptPartError.new("Map size0 changed after preflight")
      end
      validate_map_array_uint64_size0_marks(column, first_mark, mark_count, rows)

      key_sizes, key_bytes_total, _ = read_map_string_child_sizes(
        column, "%2Ekeys", "Map key", first_mark, mark_count, entries, rows, mark_entries
      )
      raise CorruptPartError.new("Map key size count differs from size0") unless key_sizes.size.to_u64 == entries
      value_sizes, checked_leaves, mark_leaf_counts = read_map_array_nullable_string_value_sizes(
        column, first_mark, mark_count, entries, rows, mark_entries
      )
      raise CorruptPartError.new("Map size1 changed after preflight") unless checked_leaves == leaves
      value_string_sizes, value_bytes_total, _ = read_map_string_child_sizes(
        column, "%2Evalues", "Map nested Nullable String", first_mark, mark_count, leaves, rows, mark_leaf_counts
      )
      raise CorruptPartError.new("Map nested String size count differs from size1") unless value_string_sizes.size.to_u64 == leaves

      key_stream = @streams["#{column}%2Ekeys"]
      key_start, key_end, key_rows = checked_stream_mark_range(key_stream, first_mark, mark_count)
      raise CorruptPartError.new("Map key substream mark rows differ") unless key_rows == rows
      key_bytes = read_mark_range_bytes(key_stream, key_start, key_end, key_bytes_total.to_i, 1)
      null_map = read_map_nullable_string_null_map(column, first_mark, mark_count, leaves, rows, mark_leaf_counts)
      values_stream = @streams["#{column}%2Evalues"]
      value_start, value_end, value_rows = checked_stream_mark_range(values_stream, first_mark, mark_count)
      raise CorruptPartError.new("Map nested String raw substream mark rows differ") unless value_rows == rows
      value_bytes = read_mark_range_bytes(values_stream, value_start, value_end, value_bytes_total.to_i, 1)

      result = Array(Array(Tuple(String, Array(String?)))).new(rows.to_i)
      entry_offset = 0
      leaf_offset = 0
      key_offset = 0
      value_offset = 0
      outer_sizes.each do |entry_count|
        row = Array(Tuple(String, Array(String?))).new(entry_count.to_i)
        entry_count.to_i.times do
          raise CorruptPartError.new("Map outer sizes exceed selected nested keys") if entry_offset >= key_sizes.size
          key_size = key_sizes[entry_offset].to_i
          if key_offset > key_bytes.size || key_size > key_bytes.size - key_offset
            raise CorruptPartError.new("Map key sizes exceed selected raw bytes")
          end
          value_count = value_sizes[entry_offset]
          if value_count > leaves - leaf_offset.to_u64
            raise CorruptPartError.new("Map nested sizes exceed selected Nullable String leaves")
          end

          nested_values = Array(String?).new(value_count.to_i)
          value_count.to_i.times do
            raise CorruptPartError.new("Map Nullable String values exceed selected null-map bytes") if leaf_offset >= null_map.size
            length = value_string_sizes[leaf_offset].to_i
            if value_offset > value_bytes.size || length > value_bytes.size - value_offset
              raise CorruptPartError.new("Map nested String sizes exceed selected raw bytes")
            end
            nested_values << (null_map[leaf_offset] == 1_u8 ? nil : String.new(value_bytes[value_offset, length]))
            value_offset += length
            leaf_offset += 1
          end
          row << {String.new(key_bytes[key_offset, key_size]), nested_values}
          key_offset += key_size
          entry_offset += 1
        end
        result << row
      end
      raise CorruptPartError.new("Map sizes do not consume selected nested keys") unless entry_offset == key_sizes.size
      raise CorruptPartError.new("Map key lengths do not consume selected raw bytes") unless key_offset == key_bytes.size
      raise CorruptPartError.new("Map nested sizes do not consume selected Nullable String leaves") unless leaf_offset.to_u64 == leaves
      raise CorruptPartError.new("Map nested String lengths do not consume selected raw bytes") unless value_offset == value_bytes.size
      result
    end

    private def checked_map_string_array_nullable_string_charge(payload_bytes : UInt64, entries : UInt64, leaves : UInt64, rows : UInt64) : UInt64
      array_charge = checked_map_string_array_charge(payload_bytes, entries, rows, "Map(Array(Nullable(String)))")
      leaf_width = ARRAY_NULLABLE_STRING_SLOT_ACCOUNTING_BYTES
      if leaves > UInt64::MAX // leaf_width
        raise CorruptPartError.new("Map(Array(Nullable(String))) materialization charge overflows")
      end
      leaf_bytes = leaves * leaf_width
      if leaf_bytes > MAX_ARRAY_MARK_BYTES.to_u64 || array_charge > MAX_ARRAY_MARK_BYTES.to_u64 - leaf_bytes
        raise CorruptPartError.new("Map(Array(Nullable(String))) materialization charge exceeds per-range limit")
      end
      array_charge + leaf_bytes
    end

    # Return the fixed-width key and nullable leaf bytes for one exact W69
    # Map range, validating each nested stream against the size0/size1 marks.
    def map_uint64_array_nullable_uint64_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      map_uint64_array_nullable_uint64_payload_preflight(column, first_mark, mark_count)[0]
    end

    # Return physical bytes and bounded row/entry/nested-Array materialization
    # charge for the exact W69 shape.
    def map_uint64_array_nullable_uint64_mark_range_materialization_preflight(column : String, first_mark : Int, mark_count : Int) : {UInt64, UInt64}
      payload_bytes, flat_entries, rows = map_uint64_array_nullable_uint64_payload_preflight(column, first_mark, mark_count)
      {payload_bytes, checked_map_uint64_array_nullable_uint64_charge(payload_bytes, flat_entries, rows)}
    end

    private def map_uint64_array_nullable_uint64_payload_preflight(column : String, first_mark : Int, mark_count : Int) : {UInt64, UInt64, UInt64}
      ensure_column(column)
      unless WidePart.supports_map_uint64_array_nullable_uint64_type?(@column_type)
        raise UnsupportedFormatError.new("Map accessor requires an exact Map(UInt64, Array(Nullable(UInt64))) column")
      end

      _, flat_entries, rows, mark_flat_entries = read_array_outer_sizes(column, first_mark, mark_count)
      validate_map_array_uint64_size0_marks(column, first_mark, mark_count, rows)

      keys_stream = @streams["#{column}%2Ekeys"]
      _, _, key_rows = checked_stream_mark_range(keys_stream, first_mark, mark_count)
      raise CorruptPartError.new("Map key substream mark rows differ") unless key_rows == rows
      validate_array_nested_stream_marks(keys_stream, first_mark, mark_flat_entries, 8)

      _, flat_values, mark_value_elements = read_map_array_uint64_element_sizes(
        column, first_mark, mark_count, flat_entries, rows, mark_flat_entries
      )
      read_map_nullable_uint64_null_map(column, first_mark, mark_count, flat_values, rows, mark_value_elements)

      key_bytes = checked_array_mark_byte_count(flat_entries, 8).to_u64
      value_and_null_bytes = checked_array_mark_byte_count(flat_values, 9).to_u64
      key_mark_bytes = mark_flat_entries.map { |entries| checked_array_mark_byte_count(entries, 8).to_u64 }
      value_mark_bytes = mark_value_elements.map { |elements| checked_array_mark_byte_count(elements, 9).to_u64 }
      payload_bytes = checked_map_materialized_bytes(key_bytes, value_and_null_bytes, key_mark_bytes, value_mark_bytes)
      {payload_bytes, flat_entries, rows}
    end

    # Decode exact ordered Map(UInt64, Array(Nullable(UInt64))) rows. size0
    # gives entry counts and values.size1 gives each nested Array length;
    # duplicate keys and NULL-hidden UInt64 slots remain positionally intact.
    def read_map_uint64_array_nullable_uint64_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Tuple(UInt64, Array(UInt64?))))
      ensure_column(column)
      unless WidePart.supports_map_uint64_array_nullable_uint64_type?(@column_type)
        raise UnsupportedFormatError.new("Map accessor requires an exact Map(UInt64, Array(Nullable(UInt64))) column")
      end

      payload_bytes, flat_entries, rows = map_uint64_array_nullable_uint64_payload_preflight(column, first_mark, mark_count)
      checked_map_uint64_array_nullable_uint64_charge(payload_bytes, flat_entries, rows)
      outer_sizes, checked_flat_entries, checked_rows, mark_flat_entries = read_array_outer_sizes(column, first_mark, mark_count)
      unless checked_flat_entries == flat_entries && checked_rows == rows
        raise CorruptPartError.new("Map size0 changed after preflight")
      end
      validate_map_array_uint64_size0_marks(column, first_mark, mark_count, rows)

      keys_stream = @streams["#{column}%2Ekeys"]
      key_start, key_end, key_rows = checked_stream_mark_range(keys_stream, first_mark, mark_count)
      raise CorruptPartError.new("Map key substream mark rows differ") unless key_rows == rows
      validate_array_nested_stream_marks(keys_stream, first_mark, mark_flat_entries, 8)
      encoded_keys = read_mark_range_bytes(keys_stream, key_start, key_end, checked_array_mark_byte_count(flat_entries, 8), 8)

      value_sizes, flat_values, mark_value_elements = read_map_array_uint64_element_sizes(
        column, first_mark, mark_count, flat_entries, rows, mark_flat_entries
      )
      null_map = read_map_nullable_uint64_null_map(column, first_mark, mark_count, flat_values, rows, mark_value_elements)
      values_stream = @streams["#{column}%2Evalues"]
      value_start, value_end, value_rows = checked_stream_mark_range(values_stream, first_mark, mark_count)
      raise CorruptPartError.new("Map value substream mark rows differ") unless value_rows == rows
      encoded_values = read_mark_range_bytes(values_stream, value_start, value_end, checked_array_mark_byte_count(flat_values, 8), 8)

      result = Array(Array(Tuple(UInt64, Array(UInt64?)))).new(rows.to_i)
      entry_offset = 0
      leaf_offset = 0
      value_offset = 0
      outer_sizes.each do |entry_count|
        row = Array(Tuple(UInt64, Array(UInt64?))).new(entry_count.to_i)
        entry_count.to_i.times do
          raise CorruptPartError.new("Map outer sizes exceed selected nested keys") if entry_offset >= value_sizes.size
          value_count = value_sizes[entry_offset]
          remaining_values = value_offset > encoded_values.size ? 0 : ((encoded_values.size - value_offset) // 8).to_u64
          raise CorruptPartError.new("Map value sizes exceed selected UInt64 payload") if value_count > remaining_values

          nested_values = Array(UInt64?).new(value_count.to_i)
          value_count.to_i.times do
            raise CorruptPartError.new("Map Nullable values exceed selected null-map bytes") if leaf_offset >= null_map.size
            nested_values << (null_map[leaf_offset] == 1 ? nil : u64(encoded_values, value_offset))
            # NULL leaves still own and consume their UInt64 value slot.
            value_offset += 8
            leaf_offset += 1
          end
          row << {u64(encoded_keys, entry_offset * 8), nested_values}
          entry_offset += 1
        end
        result << row
      end
      raise CorruptPartError.new("Map sizes do not consume selected nested keys") unless entry_offset.to_u64 == flat_entries
      raise CorruptPartError.new("Map nested sizes do not consume selected null-map slots") unless leaf_offset == null_map.size
      raise CorruptPartError.new("Map nested sizes do not consume selected UInt64 slots") unless value_offset == encoded_values.size
      result
    end

    # Return fixed-width UInt64 key slots plus the nested nullable String
    # payload bytes for one exact W71 Map range, validating each mark against
    # its own row, entry, leaf, and byte counts.
    def map_uint64_array_nullable_string_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      map_uint64_array_nullable_string_payload_preflight(column, first_mark, mark_count)[0]
    end

    def map_uint64_array_nullable_string_mark_range_materialization_preflight(column : String, first_mark : Int, mark_count : Int) : {UInt64, UInt64}
      payload_bytes, entries, rows, leaves = map_uint64_array_nullable_string_payload_preflight(column, first_mark, mark_count)
      {payload_bytes, checked_map_uint64_array_nullable_string_charge(payload_bytes, entries, leaves, rows)}
    end

    private def map_uint64_array_nullable_string_payload_preflight(column : String, first_mark : Int, mark_count : Int) : {UInt64, UInt64, UInt64, UInt64}
      ensure_column(column)
      unless WidePart.supports_map_uint64_array_nullable_string_type?(@column_type)
        raise UnsupportedFormatError.new("Map accessor requires an exact Map(UInt64, Array(Nullable(String))) column")
      end

      _, entries, rows, mark_entries = read_array_outer_sizes(column, first_mark, mark_count)
      validate_map_array_uint64_size0_marks(column, first_mark, mark_count, rows)

      keys_stream = @streams["#{column}%2Ekeys"]
      _, _, key_rows = checked_stream_mark_range(keys_stream, first_mark, mark_count)
      raise CorruptPartError.new("Map key substream mark rows differ") unless key_rows == rows
      validate_array_nested_stream_marks(keys_stream, first_mark, mark_entries, 8)

      _, leaves, mark_leaf_counts = read_map_array_nullable_string_value_sizes(
        column, first_mark, mark_count, entries, rows, mark_entries
      )
      read_map_nullable_string_null_map(column, first_mark, mark_count, leaves, rows, mark_leaf_counts)
      string_sizes, raw_bytes, raw_mark_bytes = read_map_string_child_sizes(
        column, "%2Evalues", "Map nested Nullable String", first_mark, mark_count, leaves, rows, mark_leaf_counts
      )
      raise CorruptPartError.new("Map nested String size count differs from size1") unless string_sizes.size.to_u64 == leaves

      key_bytes = checked_array_mark_byte_count(entries, 8).to_u64
      entry_size_bytes = checked_array_mark_byte_count(entries, 8).to_u64
      leaf_metadata_bytes = checked_array_mark_byte_count(leaves, 9).to_u64
      key_mark_bytes = mark_entries.map { |count| checked_array_mark_byte_count(count, 8).to_u64 }
      value_mark_bytes = mark_entries.each_with_index.map do |entry_count, index|
        leaf_count = mark_leaf_counts[index]
        checked_array_mark_byte_count(entry_count, 8).to_u64 + checked_array_mark_byte_count(leaf_count, 9).to_u64 + raw_mark_bytes[index]
      end.to_a
      value_bytes = entry_size_bytes + leaf_metadata_bytes + raw_bytes
      payload_bytes = checked_map_materialized_bytes(key_bytes, value_bytes, key_mark_bytes, value_mark_bytes)
      {payload_bytes, entries, rows, leaves}
    end

    # Decode exact ordered Map(UInt64, Array(Nullable(String))) rows. A NULL
    # leaf still consumes its full String-size span; the writer canonicalizes
    # NULL sizes to zero, while readers safely preserve foreign hidden bytes.
    def read_map_uint64_array_nullable_string_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Tuple(UInt64, Array(String?))))
      ensure_column(column)
      unless WidePart.supports_map_uint64_array_nullable_string_type?(@column_type)
        raise UnsupportedFormatError.new("Map accessor requires an exact Map(UInt64, Array(Nullable(String))) column")
      end

      payload_bytes, entries, rows, leaves = map_uint64_array_nullable_string_payload_preflight(column, first_mark, mark_count)
      checked_map_uint64_array_nullable_string_charge(payload_bytes, entries, leaves, rows)
      outer_sizes, checked_entries, checked_rows, mark_entries = read_array_outer_sizes(column, first_mark, mark_count)
      unless checked_entries == entries && checked_rows == rows
        raise CorruptPartError.new("Map size0 changed after preflight")
      end
      validate_map_array_uint64_size0_marks(column, first_mark, mark_count, rows)

      keys_stream = @streams["#{column}%2Ekeys"]
      key_start, key_end, key_rows = checked_stream_mark_range(keys_stream, first_mark, mark_count)
      raise CorruptPartError.new("Map key substream mark rows differ") unless key_rows == rows
      validate_array_nested_stream_marks(keys_stream, first_mark, mark_entries, 8)
      encoded_keys = read_mark_range_bytes(keys_stream, key_start, key_end, checked_array_mark_byte_count(entries, 8), 8)

      value_sizes, checked_leaves, mark_leaf_counts = read_map_array_nullable_string_value_sizes(
        column, first_mark, mark_count, entries, rows, mark_entries
      )
      raise CorruptPartError.new("Map size1 changed after preflight") unless checked_leaves == leaves
      string_sizes, raw_bytes_total, _ = read_map_string_child_sizes(
        column, "%2Evalues", "Map nested Nullable String", first_mark, mark_count, leaves, rows, mark_leaf_counts
      )
      raise CorruptPartError.new("Map nested String size count differs from size1") unless string_sizes.size.to_u64 == leaves
      null_map = read_map_nullable_string_null_map(column, first_mark, mark_count, leaves, rows, mark_leaf_counts)
      values_stream = @streams["#{column}%2Evalues"]
      value_start, value_end, value_rows = checked_stream_mark_range(values_stream, first_mark, mark_count)
      raise CorruptPartError.new("Map nested String raw substream mark rows differ") unless value_rows == rows
      raw_bytes = read_mark_range_bytes(values_stream, value_start, value_end, raw_bytes_total.to_i, 1)

      result = Array(Array(Tuple(UInt64, Array(String?)))).new(rows.to_i)
      entry_offset = 0
      leaf_offset = 0
      raw_offset = 0
      outer_sizes.each do |entry_count|
        row = Array(Tuple(UInt64, Array(String?))).new(entry_count.to_i)
        entry_count.to_i.times do
          raise CorruptPartError.new("Map outer sizes exceed selected nested keys") if entry_offset >= value_sizes.size
          value_count = value_sizes[entry_offset]
          if value_count > leaves - leaf_offset.to_u64
            raise CorruptPartError.new("Map nested sizes exceed selected Nullable String leaves")
          end

          nested_values = Array(String?).new(value_count.to_i)
          value_count.to_i.times do
            raise CorruptPartError.new("Map Nullable String values exceed selected null-map bytes") if leaf_offset >= null_map.size
            length = string_sizes[leaf_offset].to_i
            if raw_offset > raw_bytes.size || length > raw_bytes.size - raw_offset
              raise CorruptPartError.new("Map nested String sizes exceed selected raw bytes")
            end
            nested_values << (null_map[leaf_offset] == 1_u8 ? nil : String.new(raw_bytes[raw_offset, length]))
            raw_offset += length
            leaf_offset += 1
          end
          row << {u64(encoded_keys, entry_offset * 8), nested_values}
          entry_offset += 1
        end
        result << row
      end
      raise CorruptPartError.new("Map sizes do not consume selected nested keys") unless entry_offset.to_u64 == entries
      raise CorruptPartError.new("Map nested sizes do not consume selected Nullable String leaves") unless leaf_offset.to_u64 == leaves
      raise CorruptPartError.new("Map nested String lengths do not consume selected raw bytes") unless raw_offset == raw_bytes.size
      result
    end

    private def checked_map_uint64_array_nullable_string_charge(payload_bytes : UInt64, entries : UInt64, leaves : UInt64, rows : UInt64) : UInt64
      array_charge = checked_map_string_array_charge(payload_bytes, entries, rows, "Map(UInt64, Array(Nullable(String)))")
      if leaves > UInt64::MAX // ARRAY_NULLABLE_STRING_SLOT_ACCOUNTING_BYTES
        raise CorruptPartError.new("Map(UInt64, Array(Nullable(String))) materialization charge overflows")
      end
      leaf_bytes = leaves * ARRAY_NULLABLE_STRING_SLOT_ACCOUNTING_BYTES
      if leaf_bytes > MAX_ARRAY_MARK_BYTES.to_u64 || array_charge > MAX_ARRAY_MARK_BYTES.to_u64 - leaf_bytes
        raise CorruptPartError.new("Map(UInt64, Array(Nullable(String))) materialization charge exceeds per-range limit")
      end
      array_charge + leaf_bytes
    end

    # W73 exact Map(UInt64, Array(UInt64)) reader. Row, entry, and leaf
    # streams are preflighted against their own mark axes before allocation.
    def map_uint64_array_uint64_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      map_uint64_array_uint64_payload_preflight(column, first_mark, mark_count)[0]
    end

    def map_uint64_array_uint64_mark_range_materialization_preflight(column : String, first_mark : Int, mark_count : Int) : {UInt64, UInt64}
      payload_bytes, entries, rows = map_uint64_array_uint64_payload_preflight(column, first_mark, mark_count)
      {payload_bytes, checked_map_string_array_charge(payload_bytes, entries, rows, "Map(UInt64, Array(UInt64))")}
    end

    private def map_uint64_array_uint64_payload_preflight(column : String, first_mark : Int, mark_count : Int) : {UInt64, UInt64, UInt64}
      ensure_column(column)
      unless WidePart.supports_map_uint64_array_uint64_type?(@column_type)
        raise UnsupportedFormatError.new("Map accessor requires an exact Map(UInt64, Array(UInt64)) column")
      end

      _, entries, rows, mark_entries = read_array_outer_sizes(column, first_mark, mark_count)
      validate_map_array_uint64_size0_marks(column, first_mark, mark_count, rows)
      keys_stream = @streams["#{column}%2Ekeys"]
      _, _, key_rows = checked_stream_mark_range(keys_stream, first_mark, mark_count)
      raise CorruptPartError.new("Map key substream mark rows differ") unless key_rows == rows
      validate_array_nested_stream_marks(keys_stream, first_mark, mark_entries, 8)
      _, leaves, mark_leaf_counts = read_map_array_uint64_element_sizes(
        column, first_mark, mark_count, entries, rows, mark_entries
      )
      key_bytes = checked_array_mark_byte_count(entries, 8).to_u64
      value_bytes = checked_array_mark_byte_count(leaves, 8).to_u64
      key_mark_bytes = mark_entries.map { |count| checked_array_mark_byte_count(count, 8).to_u64 }
      value_mark_bytes = mark_leaf_counts.map { |count| checked_array_mark_byte_count(count, 8).to_u64 }
      payload_bytes = checked_map_materialized_bytes(key_bytes, value_bytes, key_mark_bytes, value_mark_bytes)
      {payload_bytes, entries, rows}
    end

    def read_map_uint64_array_uint64_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Tuple(UInt64, Array(UInt64))))
      payload_bytes, entries, rows = map_uint64_array_uint64_payload_preflight(column, first_mark, mark_count)
      checked_map_string_array_charge(payload_bytes, entries, rows, "Map(UInt64, Array(UInt64))")
      outer_sizes, checked_entries, checked_rows, mark_entries = read_array_outer_sizes(column, first_mark, mark_count)
      unless checked_entries == entries && checked_rows == rows
        raise CorruptPartError.new("Map size0 changed after preflight")
      end
      validate_map_array_uint64_size0_marks(column, first_mark, mark_count, rows)

      keys_stream = @streams["#{column}%2Ekeys"]
      key_start, key_end, key_rows = checked_stream_mark_range(keys_stream, first_mark, mark_count)
      raise CorruptPartError.new("Map key substream mark rows differ") unless key_rows == rows
      validate_array_nested_stream_marks(keys_stream, first_mark, mark_entries, 8)
      key_bytes = read_mark_range_bytes(keys_stream, key_start, key_end, checked_array_mark_byte_count(entries, 8), 8)
      value_sizes, leaves, _ = read_map_array_uint64_element_sizes(
        column, first_mark, mark_count, entries, rows, mark_entries
      )
      values_stream = @streams["#{column}%2Evalues"]
      value_start, value_end, value_rows = checked_stream_mark_range(values_stream, first_mark, mark_count)
      raise CorruptPartError.new("Map value substream mark rows differ") unless value_rows == rows
      value_bytes = read_mark_range_bytes(values_stream, value_start, value_end, checked_array_mark_byte_count(leaves, 8), 8)

      result = Array(Array(Tuple(UInt64, Array(UInt64)))).new(rows.to_i)
      entry_offset = 0
      leaf_offset = 0_u64
      outer_sizes.each do |entry_count|
        row = Array(Tuple(UInt64, Array(UInt64))).new(entry_count.to_i)
        entry_count.to_i.times do
          raise CorruptPartError.new("Map outer sizes exceed selected nested keys") if entry_offset >= value_sizes.size
          value_count = value_sizes[entry_offset]
          if value_count > leaves - leaf_offset
            raise CorruptPartError.new("Map value sizes exceed selected UInt64 leaves")
          end
          nested_values = Array(UInt64).new(value_count.to_i)
          value_count.to_i.times do
            nested_values << u64(value_bytes, (leaf_offset * 8).to_i)
            leaf_offset += 1
          end
          row << {u64(key_bytes, entry_offset * 8), nested_values}
          entry_offset += 1
        end
        result << row
      end
      raise CorruptPartError.new("Map sizes do not consume selected nested keys") unless entry_offset.to_u64 == entries
      raise CorruptPartError.new("Map nested sizes do not consume selected UInt64 leaves") unless leaf_offset == leaves
      result
    end

    # W73 exact Map(String, Array(String)) preflight and decoder. Key Strings
    # and nested String leaves have distinct byte/count axes.
    def map_string_array_string_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      map_string_array_string_payload_preflight(column, first_mark, mark_count)[0]
    end

    def map_string_array_string_mark_range_materialization_preflight(column : String, first_mark : Int, mark_count : Int) : {UInt64, UInt64}
      payload_bytes, entries, leaves, rows = map_string_array_string_payload_preflight(column, first_mark, mark_count)
      {payload_bytes, checked_map_string_array_string_charge(payload_bytes, entries, leaves, rows)}
    end

    private def map_string_array_string_payload_preflight(column : String, first_mark : Int, mark_count : Int) : {UInt64, UInt64, UInt64, UInt64}
      ensure_column(column)
      unless WidePart.supports_map_string_array_string_type?(@column_type)
        raise UnsupportedFormatError.new("Map accessor requires an exact Map(String, Array(String)) column")
      end

      _, entries, rows, mark_entries = read_array_outer_sizes(column, first_mark, mark_count)
      validate_map_array_uint64_size0_marks(column, first_mark, mark_count, rows)
      key_sizes, key_raw_bytes, key_raw_mark_bytes = read_map_string_child_sizes(
        column, "%2Ekeys", "Map key", first_mark, mark_count, entries, rows, mark_entries
      )
      raise CorruptPartError.new("Map key size count differs from size0") unless key_sizes.size.to_u64 == entries
      _, leaves, mark_leaf_counts = read_map_array_nullable_string_value_sizes(
        column, first_mark, mark_count, entries, rows, mark_entries
      )
      value_sizes, value_raw_bytes, value_raw_mark_bytes = read_map_string_child_sizes(
        column, "%2Evalues", "Map nested String", first_mark, mark_count, leaves, rows, mark_leaf_counts
      )
      raise CorruptPartError.new("Map nested String size count differs from size1") unless value_sizes.size.to_u64 == leaves

      key_bytes = checked_map_string_key_charge(key_raw_bytes, entries)
      value_bytes = checked_map_nested_string_value_charge(value_raw_bytes, entries, leaves)
      key_mark_bytes = key_raw_mark_bytes.each_with_index.map do |raw_bytes, index|
        checked_map_string_key_charge(raw_bytes, mark_entries[index])
      end.to_a
      value_mark_bytes = value_raw_mark_bytes.each_with_index.map do |raw_bytes, index|
        checked_map_nested_string_value_charge(raw_bytes, mark_entries[index], mark_leaf_counts[index])
      end.to_a
      payload_bytes = checked_map_materialized_bytes(key_bytes, value_bytes, key_mark_bytes, value_mark_bytes)
      {payload_bytes, entries, leaves, rows}
    end

    def read_map_string_array_string_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Tuple(String, Array(String))))
      payload_bytes, entries, leaves, rows = map_string_array_string_payload_preflight(column, first_mark, mark_count)
      checked_map_string_array_string_charge(payload_bytes, entries, leaves, rows)
      outer_sizes, checked_entries, checked_rows, mark_entries = read_array_outer_sizes(column, first_mark, mark_count)
      unless checked_entries == entries && checked_rows == rows
        raise CorruptPartError.new("Map size0 changed after preflight")
      end
      validate_map_array_uint64_size0_marks(column, first_mark, mark_count, rows)
      key_sizes, key_raw_bytes, _ = read_map_string_child_sizes(
        column, "%2Ekeys", "Map key", first_mark, mark_count, entries, rows, mark_entries
      )
      value_sizes, checked_leaves, mark_leaf_counts = read_map_array_nullable_string_value_sizes(
        column, first_mark, mark_count, entries, rows, mark_entries
      )
      raise CorruptPartError.new("Map size1 changed after preflight") unless checked_leaves == leaves
      value_string_sizes, value_raw_bytes, _ = read_map_string_child_sizes(
        column, "%2Evalues", "Map nested String", first_mark, mark_count, leaves, rows, mark_leaf_counts
      )
      raise CorruptPartError.new("Map nested String size count differs from size1") unless value_string_sizes.size.to_u64 == leaves

      key_stream = @streams["#{column}%2Ekeys"]
      key_start, key_end, key_rows = checked_stream_mark_range(key_stream, first_mark, mark_count)
      raise CorruptPartError.new("Map key substream mark rows differ") unless key_rows == rows
      key_bytes = read_mark_range_bytes(key_stream, key_start, key_end, key_raw_bytes.to_i, 1)
      value_stream = @streams["#{column}%2Evalues"]
      value_start, value_end, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Map nested String raw substream mark rows differ") unless value_rows == rows
      value_bytes = read_mark_range_bytes(value_stream, value_start, value_end, value_raw_bytes.to_i, 1)

      result = Array(Array(Tuple(String, Array(String)))).new(rows.to_i)
      entry_offset = 0
      leaf_offset = 0
      key_offset = 0
      value_offset = 0
      outer_sizes.each do |entry_count|
        row = Array(Tuple(String, Array(String))).new(entry_count.to_i)
        entry_count.to_i.times do
          raise CorruptPartError.new("Map outer sizes exceed selected nested keys") if entry_offset >= key_sizes.size
          key_length = key_sizes[entry_offset].to_i
          if key_offset > key_bytes.size || key_length > key_bytes.size - key_offset
            raise CorruptPartError.new("Map key sizes exceed selected raw bytes")
          end
          value_count = value_sizes[entry_offset]
          if value_count > leaves - leaf_offset.to_u64
            raise CorruptPartError.new("Map nested sizes exceed selected String leaves")
          end
          nested_values = Array(String).new(value_count.to_i)
          value_count.to_i.times do
            length = value_string_sizes[leaf_offset].to_i
            if value_offset > value_bytes.size || length > value_bytes.size - value_offset
              raise CorruptPartError.new("Map nested String sizes exceed selected raw bytes")
            end
            nested_values << String.new(value_bytes[value_offset, length])
            value_offset += length
            leaf_offset += 1
          end
          row << {String.new(key_bytes[key_offset, key_length]), nested_values}
          key_offset += key_length
          entry_offset += 1
        end
        result << row
      end
      raise CorruptPartError.new("Map sizes do not consume selected nested keys") unless entry_offset.to_u64 == entries
      raise CorruptPartError.new("Map nested sizes do not consume selected String leaves") unless leaf_offset.to_u64 == leaves
      raise CorruptPartError.new("Map key lengths do not consume selected raw bytes") unless key_offset == key_bytes.size
      raise CorruptPartError.new("Map nested String lengths do not consume selected raw bytes") unless value_offset == value_bytes.size
      result
    end

    # W73 exact Map(UInt64, Array(String)); fixed-width keys remain on the
    # Map-entry axis while nested string lengths and bytes use leaf axes.
    def map_uint64_array_string_mark_range_raw_bytes(column : String, first_mark : Int, mark_count : Int) : UInt64
      map_uint64_array_string_payload_preflight(column, first_mark, mark_count)[0]
    end

    def map_uint64_array_string_mark_range_materialization_preflight(column : String, first_mark : Int, mark_count : Int) : {UInt64, UInt64}
      payload_bytes, entries, leaves, rows = map_uint64_array_string_payload_preflight(column, first_mark, mark_count)
      {payload_bytes, checked_map_uint64_array_string_charge(payload_bytes, entries, leaves, rows)}
    end

    private def map_uint64_array_string_payload_preflight(column : String, first_mark : Int, mark_count : Int) : {UInt64, UInt64, UInt64, UInt64}
      ensure_column(column)
      unless WidePart.supports_map_uint64_array_string_type?(@column_type)
        raise UnsupportedFormatError.new("Map accessor requires an exact Map(UInt64, Array(String)) column")
      end

      _, entries, rows, mark_entries = read_array_outer_sizes(column, first_mark, mark_count)
      validate_map_array_uint64_size0_marks(column, first_mark, mark_count, rows)
      keys_stream = @streams["#{column}%2Ekeys"]
      _, _, key_rows = checked_stream_mark_range(keys_stream, first_mark, mark_count)
      raise CorruptPartError.new("Map key substream mark rows differ") unless key_rows == rows
      validate_array_nested_stream_marks(keys_stream, first_mark, mark_entries, 8)
      _, leaves, mark_leaf_counts = read_map_array_nullable_string_value_sizes(
        column, first_mark, mark_count, entries, rows, mark_entries
      )
      value_sizes, value_raw_bytes, value_raw_mark_bytes = read_map_string_child_sizes(
        column, "%2Evalues", "Map nested String", first_mark, mark_count, leaves, rows, mark_leaf_counts
      )
      raise CorruptPartError.new("Map nested String size count differs from size1") unless value_sizes.size.to_u64 == leaves

      key_bytes = checked_array_mark_byte_count(entries, 8).to_u64
      value_bytes = checked_map_nested_string_value_charge(value_raw_bytes, entries, leaves)
      key_mark_bytes = mark_entries.map { |count| checked_array_mark_byte_count(count, 8).to_u64 }
      value_mark_bytes = value_raw_mark_bytes.each_with_index.map do |raw_bytes, index|
        checked_map_nested_string_value_charge(raw_bytes, mark_entries[index], mark_leaf_counts[index])
      end.to_a
      payload_bytes = checked_map_materialized_bytes(key_bytes, value_bytes, key_mark_bytes, value_mark_bytes)
      {payload_bytes, entries, leaves, rows}
    end

    def read_map_uint64_array_string_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Tuple(UInt64, Array(String))))
      payload_bytes, entries, leaves, rows = map_uint64_array_string_payload_preflight(column, first_mark, mark_count)
      checked_map_uint64_array_string_charge(payload_bytes, entries, leaves, rows)
      outer_sizes, checked_entries, checked_rows, mark_entries = read_array_outer_sizes(column, first_mark, mark_count)
      unless checked_entries == entries && checked_rows == rows
        raise CorruptPartError.new("Map size0 changed after preflight")
      end
      validate_map_array_uint64_size0_marks(column, first_mark, mark_count, rows)
      keys_stream = @streams["#{column}%2Ekeys"]
      key_start, key_end, key_rows = checked_stream_mark_range(keys_stream, first_mark, mark_count)
      raise CorruptPartError.new("Map key substream mark rows differ") unless key_rows == rows
      validate_array_nested_stream_marks(keys_stream, first_mark, mark_entries, 8)
      key_bytes = read_mark_range_bytes(keys_stream, key_start, key_end, checked_array_mark_byte_count(entries, 8), 8)
      value_sizes, checked_leaves, mark_leaf_counts = read_map_array_nullable_string_value_sizes(
        column, first_mark, mark_count, entries, rows, mark_entries
      )
      raise CorruptPartError.new("Map size1 changed after preflight") unless checked_leaves == leaves
      value_string_sizes, value_raw_bytes, _ = read_map_string_child_sizes(
        column, "%2Evalues", "Map nested String", first_mark, mark_count, leaves, rows, mark_leaf_counts
      )
      raise CorruptPartError.new("Map nested String size count differs from size1") unless value_string_sizes.size.to_u64 == leaves
      values_stream = @streams["#{column}%2Evalues"]
      value_start, value_end, value_rows = checked_stream_mark_range(values_stream, first_mark, mark_count)
      raise CorruptPartError.new("Map nested String raw substream mark rows differ") unless value_rows == rows
      value_bytes = read_mark_range_bytes(values_stream, value_start, value_end, value_raw_bytes.to_i, 1)

      result = Array(Array(Tuple(UInt64, Array(String)))).new(rows.to_i)
      entry_offset = 0
      leaf_offset = 0
      value_offset = 0
      outer_sizes.each do |entry_count|
        row = Array(Tuple(UInt64, Array(String))).new(entry_count.to_i)
        entry_count.to_i.times do
          raise CorruptPartError.new("Map outer sizes exceed selected nested keys") if entry_offset >= value_sizes.size
          value_count = value_sizes[entry_offset]
          if value_count > leaves - leaf_offset.to_u64
            raise CorruptPartError.new("Map nested sizes exceed selected String leaves")
          end
          nested_values = Array(String).new(value_count.to_i)
          value_count.to_i.times do
            length = value_string_sizes[leaf_offset].to_i
            if value_offset > value_bytes.size || length > value_bytes.size - value_offset
              raise CorruptPartError.new("Map nested String sizes exceed selected raw bytes")
            end
            nested_values << String.new(value_bytes[value_offset, length])
            value_offset += length
            leaf_offset += 1
          end
          row << {u64(key_bytes, entry_offset * 8), nested_values}
          entry_offset += 1
        end
        result << row
      end
      raise CorruptPartError.new("Map sizes do not consume selected nested keys") unless entry_offset.to_u64 == entries
      raise CorruptPartError.new("Map nested sizes do not consume selected String leaves") unless leaf_offset.to_u64 == leaves
      raise CorruptPartError.new("Map nested String lengths do not consume selected raw bytes") unless value_offset == value_bytes.size
      result
    end

    private def checked_map_nested_string_value_charge(raw_bytes : UInt64, entries : UInt64, leaves : UInt64) : UInt64
      size1_bytes = checked_array_mark_byte_count(entries, 8).to_u64
      leaf_size_bytes = checked_array_mark_byte_count(leaves, 8).to_u64
      if raw_bytes > MAX_ARRAY_MARK_BYTES.to_u64 || leaf_size_bytes > MAX_ARRAY_MARK_BYTES.to_u64 - raw_bytes ||
         size1_bytes > MAX_ARRAY_MARK_BYTES.to_u64 - raw_bytes - leaf_size_bytes
        raise CorruptPartError.new("Map nested String metadata exceeds materialization limit")
      end
      raw_bytes + leaf_size_bytes + size1_bytes
    end

    private def checked_map_string_array_string_charge(payload_bytes : UInt64, entries : UInt64, leaves : UInt64, rows : UInt64) : UInt64
      array_charge = checked_map_string_array_charge(payload_bytes, entries, rows, "Map(String, Array(String))")
      checked_map_string_array_leaf_charge(array_charge, leaves, "Map(String, Array(String))")
    end

    private def checked_map_uint64_array_string_charge(payload_bytes : UInt64, entries : UInt64, leaves : UInt64, rows : UInt64) : UInt64
      array_charge = checked_map_string_array_charge(payload_bytes, entries, rows, "Map(UInt64, Array(String))")
      checked_map_string_array_leaf_charge(array_charge, leaves, "Map(UInt64, Array(String))")
    end

    private def checked_map_string_array_leaf_charge(array_charge : UInt64, leaves : UInt64, type_label : String) : UInt64
      slot_width = ARRAY_NULLABLE_STRING_SLOT_ACCOUNTING_BYTES
      if leaves > UInt64::MAX // slot_width
        raise CorruptPartError.new("#{type_label} materialization charge overflows")
      end
      leaf_bytes = leaves * slot_width
      if leaf_bytes > MAX_ARRAY_MARK_BYTES.to_u64 || array_charge > MAX_ARRAY_MARK_BYTES.to_u64 - leaf_bytes
        raise CorruptPartError.new("#{type_label} materialization charge exceeds per-range limit")
      end
      array_charge + leaf_bytes
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

    # Read two exact Array levels over one fixed-width primitive numeric leaf.
    # Both offset streams and the leaf's width-dependent mark boundaries are
    # checked before allocating the nested result arrays.
    def read_array_array_numeric_mark_range(column : String, first_mark : Int, mark_count : Int, type : T.class) : Array(Array(Array(T))) forall T
      ensure_column(column)
      element_type = WidePart.array_numeric_type_name(type)
      unless WidePart.array_array_numeric_element_type(@column_type) == element_type
        raise UnsupportedFormatError.new("typed nested Array accessor does not match selected column type")
      end

      validate_array_array_numeric_size0_marks(column, first_mark, mark_count)
      outer_sizes, flat_inner_arrays, rows, mark_inner_arrays = read_array_outer_sizes(column, first_mark, mark_count)
      element_width = WidePart.array_numeric_payload_width(element_type)
      element_sizes, flat_elements, mark_leaf_elements = read_array_array_numeric_element_sizes(
        column,
        first_mark,
        mark_count,
        flat_inner_arrays,
        rows,
        mark_inner_arrays,
        element_width
      )
      raise CorruptPartError.new("Array(Array(T)) outer row count changed") unless outer_sizes.size.to_u64 == rows
      raise CorruptPartError.new("Array(Array(T)) nested size count changed") unless element_sizes.size.to_u64 == flat_inner_arrays

      value_stream = @streams[column]
      value_start, value_end, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Array(T)) value mark rows differ") unless value_rows == rows
      validate_array_nested_stream_marks(value_stream, first_mark, mark_leaf_elements, element_width)
      value_bytes = read_mark_range_bytes(
        value_stream,
        value_start,
        value_end,
        checked_array_mark_byte_count(flat_elements, element_width),
        element_width
      )

      values = Array(Array(Array(T))).new(rows.to_i)
      inner_offset = 0
      value_offset = 0
      outer_sizes.each do |inner_count|
        row = Array(Array(T)).new(inner_count.to_i)
        inner_count.to_i.times do
          raise CorruptPartError.new("Array(Array(T)) size1 count exceeds selected bytes") if inner_offset >= element_sizes.size
          leaf_count = element_sizes[inner_offset]
          inner = Array(T).new(leaf_count.to_i)
          leaf_count.to_i.times do
            raise CorruptPartError.new("Array(Array(T)) sizes exceed selected numeric bytes") if value_offset > value_bytes.size - element_width
            inner << decode_array_numeric_value(value_bytes, value_offset, type)
            value_offset += element_width
          end
          row << inner
          inner_offset += 1
        end
        values << row
      end
      raise CorruptPartError.new("Array(Array(T)) sizes do not consume selected nested sizes") unless inner_offset == element_sizes.size
      raise CorruptPartError.new("Array(Array(T)) sizes do not consume selected numeric bytes") unless value_offset == value_bytes.size
      values
    end

    # Temporal nested values expose raw physical codes/ticks without changing
    # semantic type identity. Both levels of offsets and all selected child
    # boundaries are validated before nested arrays are allocated.
    def read_array_array_temporal_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
      element_type : String,
      type : T.class,
    ) : Array(Array(Array(T))) forall T
      ensure_column(column)
      unless WidePart.array_array_temporal_element_type(@column_type).try { |actual| WidePart.same_temporal_leaf_family?(actual, element_type) } &&
             WidePart.temporal_array_physical_type(element_type) == WidePart.array_numeric_type_name(type)
        raise UnsupportedFormatError.new("typed nested temporal Array accessor does not match selected semantic column type")
      end
      read_array_array_temporal_values(column, first_mark, mark_count, type)
    end

    def read_array_array_nullable_temporal_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
      element_type : String,
      type : T.class,
    ) : Array(Array(Array(T?))) forall T
      ensure_column(column)
      unless WidePart.array_array_nullable_temporal_element_type(@column_type).try { |actual| WidePart.same_temporal_leaf_family?(actual, element_type) } &&
             WidePart.temporal_array_physical_type(element_type) == WidePart.array_numeric_type_name(type)
        raise UnsupportedFormatError.new("typed nested nullable temporal Array accessor does not match selected semantic column type")
      end
      read_array_array_nullable_temporal_values(column, first_mark, mark_count, type)
    end

    def read_array_array_time_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
      element_type : String,
      type : T.class,
    ) : Array(Array(Array(T))) forall T
      ensure_column(column)
      unless WidePart.array_array_time_element_type(@column_type) == element_type &&
             WidePart.time_array_physical_type(element_type) == WidePart.array_numeric_type_name(type)
        raise UnsupportedFormatError.new("typed nested Time Array accessor does not match selected semantic column type")
      end
      read_array_array_temporal_values(column, first_mark, mark_count, type)
    end

    def read_array_array_nullable_time_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
      element_type : String,
      type : T.class,
    ) : Array(Array(Array(T?))) forall T
      ensure_column(column)
      unless WidePart.array_array_nullable_time_element_type(@column_type) == element_type &&
             WidePart.time_array_physical_type(element_type) == WidePart.array_numeric_type_name(type)
        raise UnsupportedFormatError.new("typed nested nullable Time Array accessor does not match selected semantic column type")
      end
      read_array_array_nullable_temporal_values(column, first_mark, mark_count, type)
    end

    def read_array_array_time_seconds_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Array(Int32)))
      read_array_array_time_mark_range(column, first_mark, mark_count, "Time", Int32)
    end

    def read_array_array_time64_ticks_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Array(Int64)))
      ensure_column(column)
      scale = WidePart.array_array_time64_scale(@column_type) || -1
      read_array_array_time_mark_range(column, first_mark, mark_count, "Time64(#{scale})", Int64)
    end

    def read_array_array_nullable_time_seconds_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Array(Int32?)))
      read_array_array_nullable_time_mark_range(column, first_mark, mark_count, "Time", Int32)
    end

    def read_array_array_nullable_time64_ticks_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Array(Int64?)))
      ensure_column(column)
      scale = WidePart.array_array_nullable_time64_scale(@column_type) || -1
      read_array_array_nullable_time_mark_range(column, first_mark, mark_count, "Time64(#{scale})", Int64)
    end

    def read_array_array_date_codes_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Array(UInt16)))
      read_array_array_temporal_mark_range(column, first_mark, mark_count, "Date", UInt16)
    end

    def read_array_array_date32_codes_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Array(Int32)))
      read_array_array_temporal_mark_range(column, first_mark, mark_count, "Date32", Int32)
    end

    def read_array_array_datetime_seconds_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Array(UInt32)))
      read_array_array_temporal_mark_range(column, first_mark, mark_count, "DateTime", UInt32)
    end

    def read_array_array_datetime64_ticks_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Array(Int64)))
      ensure_column(column)
      scale = WidePart.array_array_datetime64_scale(@column_type) || -1
      read_array_array_temporal_mark_range(column, first_mark, mark_count, "DateTime64(#{scale})", Int64)
    end

    def read_array_array_nullable_date_codes_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Array(UInt16?)))
      read_array_array_nullable_temporal_mark_range(column, first_mark, mark_count, "Date", UInt16)
    end

    def read_array_array_nullable_date32_codes_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Array(Int32?)))
      read_array_array_nullable_temporal_mark_range(column, first_mark, mark_count, "Date32", Int32)
    end

    def read_array_array_nullable_datetime_seconds_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Array(UInt32?)))
      read_array_array_nullable_temporal_mark_range(column, first_mark, mark_count, "DateTime", UInt32)
    end

    def read_array_array_nullable_datetime64_ticks_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Array(Int64?)))
      ensure_column(column)
      scale = WidePart.array_array_nullable_datetime64_scale(@column_type) || -1
      read_array_array_nullable_temporal_mark_range(column, first_mark, mark_count, "DateTime64(#{scale})", Int64)
    end

    def read_array_array_decimal32_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Array(Int32)))
      ensure_column(column)
      raise UnsupportedFormatError.new("Decimal32 nested Array accessor requires Array(Array(Decimal(P, S))) with P in 1..9") unless WidePart.array_array_decimal32_scale(@column_type)
      read_array_array_decimal_values(column, first_mark, mark_count, 4, Int32)
    end

    def read_array_array_decimal64_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Array(Int64)))
      ensure_column(column)
      raise UnsupportedFormatError.new("Decimal64 nested Array accessor requires Array(Array(Decimal(P, S))) with P in 10..18") unless WidePart.array_array_decimal64_scale(@column_type)
      read_array_array_decimal_values(column, first_mark, mark_count, 8, Int64)
    end

    def read_array_array_decimal128_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Array(Int128)))
      ensure_column(column)
      raise UnsupportedFormatError.new("Decimal128 nested Array accessor requires Array(Array(Decimal(P, S))) with P in 19..38") unless WidePart.array_array_decimal128_scale(@column_type)
      read_array_array_decimal_values(column, first_mark, mark_count, 16, Int128)
    end

    def read_array_array_decimal256_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Array(Decimal256Value)))
      ensure_column(column)
      raise UnsupportedFormatError.new("Decimal256 nested Array accessor requires Array(Array(Decimal(P, S))) with P in 39..76") unless WidePart.array_array_decimal256_scale(@column_type)
      read_array_array_decimal_values(column, first_mark, mark_count, 32, Decimal256Value)
    end

    def read_array_array_nullable_decimal32_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Array(Int32?)))
      ensure_column(column)
      raise UnsupportedFormatError.new("Decimal32 nested nullable Array accessor requires Array(Array(Nullable(Decimal(P, S)))) with P in 1..9") unless WidePart.array_array_nullable_decimal32_scale(@column_type)
      read_array_array_nullable_decimal_values(column, first_mark, mark_count, 4, Int32)
    end

    def read_array_array_nullable_decimal64_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Array(Int64?)))
      ensure_column(column)
      raise UnsupportedFormatError.new("Decimal64 nested nullable Array accessor requires Array(Array(Nullable(Decimal(P, S)))) with P in 10..18") unless WidePart.array_array_nullable_decimal64_scale(@column_type)
      read_array_array_nullable_decimal_values(column, first_mark, mark_count, 8, Int64)
    end

    def read_array_array_nullable_decimal128_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Array(Int128?)))
      ensure_column(column)
      raise UnsupportedFormatError.new("Decimal128 nested nullable Array accessor requires Array(Array(Nullable(Decimal(P, S)))) with P in 19..38") unless WidePart.array_array_nullable_decimal128_scale(@column_type)
      read_array_array_nullable_decimal_values(column, first_mark, mark_count, 16, Int128)
    end

    def read_array_array_nullable_decimal256_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Array(Decimal256Value?)))
      ensure_column(column)
      raise UnsupportedFormatError.new("Decimal256 nested nullable Array accessor requires Array(Array(Nullable(Decimal(P, S)))) with P in 39..76") unless WidePart.array_array_nullable_decimal256_scale(@column_type)
      read_array_array_nullable_decimal_values(column, first_mark, mark_count, 32, Decimal256Value)
    end

    private def read_array_array_temporal_values(
      column : String,
      first_mark : Int,
      mark_count : Int,
      type : T.class,
    ) : Array(Array(Array(T))) forall T
      element_width = WidePart.array_numeric_payload_width(WidePart.array_numeric_type_name(type))
      validate_array_array_numeric_size0_marks(column, first_mark, mark_count)
      validate_array_array_decimal_stream_mark_rows(column, first_mark, mark_count, false)
      outer_sizes, flat_inner_arrays, rows, mark_inner_arrays = read_array_outer_sizes(column, first_mark, mark_count)
      element_sizes, flat_elements, mark_leaf_elements = read_array_array_numeric_element_sizes(
        column,
        first_mark,
        mark_count,
        flat_inner_arrays,
        rows,
        mark_inner_arrays,
        element_width
      )
      raise CorruptPartError.new("Array(Array(temporal)) outer row count changed") unless outer_sizes.size.to_u64 == rows
      raise CorruptPartError.new("Array(Array(temporal)) nested size count changed") unless element_sizes.size.to_u64 == flat_inner_arrays

      value_stream = @streams[column]
      value_start, value_end, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Array(temporal)) value mark rows differ") unless value_rows == rows
      validate_array_nested_stream_marks(value_stream, first_mark, mark_leaf_elements, element_width)
      value_bytes = read_mark_range_bytes(
        value_stream,
        value_start,
        value_end,
        checked_array_mark_byte_count(flat_elements, element_width),
        element_width
      )

      NestedFixedWidthPayloadDecoder.decode(
        outer_sizes,
        element_sizes,
        rows,
        value_bytes,
        element_width,
        type,
        "Array(Array(temporal))",
        "temporal"
      ) do |value_offset|
        decode_array_numeric_value(value_bytes, value_offset, type)
      end
    end

    private def read_array_array_nullable_temporal_values(
      column : String,
      first_mark : Int,
      mark_count : Int,
      type : T.class,
    ) : Array(Array(Array(T?))) forall T
      element_width = WidePart.array_numeric_payload_width(WidePart.array_numeric_type_name(type))
      validate_array_array_numeric_size0_marks(column, first_mark, mark_count)
      validate_array_array_decimal_stream_mark_rows(column, first_mark, mark_count, true)
      outer_sizes, flat_inner_arrays, rows, mark_inner_arrays = read_array_outer_sizes(column, first_mark, mark_count)
      element_sizes, flat_leaf_elements, mark_leaf_elements = read_array_array_numeric_element_sizes(
        column,
        first_mark,
        mark_count,
        flat_inner_arrays,
        rows,
        mark_inner_arrays,
        element_width
      )
      raise CorruptPartError.new("Array(Array(Nullable(temporal))) outer row count changed") unless outer_sizes.size.to_u64 == rows
      raise CorruptPartError.new("Array(Array(Nullable(temporal))) nested size count changed") unless element_sizes.size.to_u64 == flat_inner_arrays

      null_stream = @streams["#{column}.null"]
      null_start, null_end, null_rows = checked_stream_mark_range(null_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Array(Nullable(temporal))) null-map mark rows differ") unless null_rows == rows
      validate_array_nested_stream_marks(null_stream, first_mark, mark_leaf_elements, 1)
      null_bytes = read_mark_range_bytes(
        null_stream,
        null_start,
        null_end,
        checked_array_mark_byte_count(flat_leaf_elements, 1),
        1
      )
      null_bytes.each do |value|
        raise CorruptPartError.new("Array(Array(Nullable(temporal))) null-map byte is not boolean") unless value <= 1_u8
      end

      value_stream = @streams[column]
      value_start, value_end, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Array(Nullable(temporal))) value mark rows differ") unless value_rows == rows
      validate_array_nested_stream_marks(value_stream, first_mark, mark_leaf_elements, element_width)
      value_bytes = read_mark_range_bytes(
        value_stream,
        value_start,
        value_end,
        checked_array_mark_byte_count(flat_leaf_elements, element_width),
        element_width
      )

      NestedFixedWidthPayloadDecoder.decode_nullable(
        outer_sizes,
        element_sizes,
        rows,
        value_bytes,
        null_bytes,
        flat_leaf_elements,
        element_width,
        type,
        "Array(Array(Nullable(temporal)))",
        "temporal"
      ) do |value_offset|
        decode_array_numeric_value(value_bytes, value_offset, type)
      end
    end

    private def read_array_array_decimal_values(
      column : String,
      first_mark : Int,
      mark_count : Int,
      element_width : Int32,
      type : T.class,
    ) : Array(Array(Array(T))) forall T
      validate_array_array_numeric_size0_marks(column, first_mark, mark_count)
      validate_array_array_decimal_stream_mark_rows(column, first_mark, mark_count, false)
      outer_sizes, flat_inner_arrays, rows, mark_inner_arrays = read_array_outer_sizes(column, first_mark, mark_count)
      element_sizes, flat_elements, mark_leaf_elements = read_array_array_numeric_element_sizes(
        column,
        first_mark,
        mark_count,
        flat_inner_arrays,
        rows,
        mark_inner_arrays,
        element_width
      )
      raise CorruptPartError.new("Array(Array(Decimal)) outer row count changed") unless outer_sizes.size.to_u64 == rows
      raise CorruptPartError.new("Array(Array(Decimal)) nested size count changed") unless element_sizes.size.to_u64 == flat_inner_arrays

      value_stream = @streams[column]
      value_start, value_end, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Array(Decimal)) value mark rows differ") unless value_rows == rows
      validate_array_nested_stream_marks(value_stream, first_mark, mark_leaf_elements, element_width)
      value_bytes = read_mark_range_bytes(
        value_stream,
        value_start,
        value_end,
        checked_array_mark_byte_count(flat_elements, element_width),
        element_width
      )

      NestedFixedWidthPayloadDecoder.decode(
        outer_sizes,
        element_sizes,
        rows,
        value_bytes,
        element_width,
        type,
        "Array(Array(Decimal))",
        "coefficient"
      ) do |value_offset|
        decode_array_decimal_value(value_bytes, value_offset, type)
      end
    end

    private def read_array_array_nullable_decimal_values(
      column : String,
      first_mark : Int,
      mark_count : Int,
      element_width : Int32,
      type : T.class,
    ) : Array(Array(Array(T?))) forall T
      validate_array_array_numeric_size0_marks(column, first_mark, mark_count)
      validate_array_array_decimal_stream_mark_rows(column, first_mark, mark_count, true)
      outer_sizes, flat_inner_arrays, rows, mark_inner_arrays = read_array_outer_sizes(column, first_mark, mark_count)
      element_sizes, flat_leaf_elements, mark_leaf_elements = read_array_array_numeric_element_sizes(
        column,
        first_mark,
        mark_count,
        flat_inner_arrays,
        rows,
        mark_inner_arrays,
        element_width
      )
      raise CorruptPartError.new("Array(Array(Nullable(Decimal))) outer row count changed") unless outer_sizes.size.to_u64 == rows
      raise CorruptPartError.new("Array(Array(Nullable(Decimal))) nested size count changed") unless element_sizes.size.to_u64 == flat_inner_arrays

      null_stream = @streams["#{column}.null"]
      null_start, null_end, null_rows = checked_stream_mark_range(null_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Array(Nullable(Decimal))) null-map mark rows differ") unless null_rows == rows
      validate_array_nested_stream_marks(null_stream, first_mark, mark_leaf_elements, 1)
      null_map = read_mark_range_bytes(
        null_stream,
        null_start,
        null_end,
        checked_array_mark_byte_count(flat_leaf_elements, 1),
        1
      )
      null_map.each do |value|
        raise CorruptPartError.new("Array(Array(Nullable(Decimal))) null-map byte is not boolean") unless value <= 1_u8
      end

      value_stream = @streams[column]
      value_start, value_end, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Array(Nullable(Decimal))) value mark rows differ") unless value_rows == rows
      validate_array_nested_stream_marks(value_stream, first_mark, mark_leaf_elements, element_width)
      value_bytes = read_mark_range_bytes(
        value_stream,
        value_start,
        value_end,
        checked_array_mark_byte_count(flat_leaf_elements, element_width),
        element_width
      )

      NestedFixedWidthPayloadDecoder.decode_nullable(
        outer_sizes,
        element_sizes,
        rows,
        value_bytes,
        null_map,
        flat_leaf_elements,
        element_width,
        type,
        "Array(Array(Nullable(Decimal)))",
        "coefficient"
      ) do |value_offset|
        decode_array_decimal_value(value_bytes, value_offset, type)
      end
    end

    # Read the exact W59 Array(Array(String)) shape. Counts and mark-local
    # byte boundaries for size0, size1, String sizes, and String data are all
    # validated before nested values are allocated.
    def read_array_array_string_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Array(String)))
      components = array_array_string_components(column, first_mark, mark_count)
      raw_stream = @streams[column]
      raw_start, raw_end, raw_rows = checked_stream_mark_range(raw_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Array(String)) raw mark rows differ") unless raw_rows == components.rows
      raw_bytes = read_mark_range_bytes(raw_stream, raw_start, raw_end, components.string_bytes.to_i, 1)

      values = Array(Array(Array(String))).new(components.rows.to_i)
      inner_offset = 0
      string_offset = 0
      raw_offset = 0
      components.outer_sizes.each do |inner_count|
        row = Array(Array(String)).new(inner_count.to_i)
        inner_count.to_i.times do
          raise CorruptPartError.new("Array(Array(String)) size1 count exceeds selected sizes") if inner_offset >= components.inner_sizes.size
          string_count = components.inner_sizes[inner_offset]
          inner = Array(String).new(string_count.to_i)
          string_count.to_i.times do
            raise CorruptPartError.new("Array(Array(String)) size count exceeds selected sizes") if string_offset >= components.string_sizes.size
            length = components.string_sizes[string_offset]
            raise CorruptPartError.new("Array(Array(String)) size exceeds selected raw bytes") if length > (raw_bytes.size - raw_offset).to_u64
            byte_length = length.to_i
            inner << String.new(raw_bytes[raw_offset, byte_length])
            raw_offset += byte_length
            string_offset += 1
          end
          row << inner
          inner_offset += 1
        end
        values << row
      end
      raise CorruptPartError.new("Array(Array(String)) sizes do not consume selected inner Arrays") unless inner_offset == components.inner_sizes.size
      raise CorruptPartError.new("Array(Array(String)) sizes do not consume selected String lengths") unless string_offset == components.string_sizes.size
      raise CorruptPartError.new("Array(Array(String)) lengths do not consume selected raw bytes") unless raw_offset == raw_bytes.size
      values
    end

    # Read exactly two Array levels over Nullable(String). All five selected
    # stream ranges are preflighted before the nested result rows are allocated;
    # bytes hidden below NULL slots are still consumed to preserve alignment.
    def read_array_array_nullable_string_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Array(String?)))
      components = array_array_nullable_string_components(column, first_mark, mark_count)
      raw_stream = @streams[column]
      raw_start, raw_end, raw_rows = checked_stream_mark_range(raw_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Array(Nullable(String))) raw mark rows differ") unless raw_rows == components.rows
      raw_bytes = read_mark_range_bytes(raw_stream, raw_start, raw_end, components.string_bytes.to_i, 1)

      values = Array(Array(Array(String?))).new(components.rows.to_i)
      inner_offset = 0
      string_offset = 0
      raw_offset = 0
      components.outer_sizes.each do |inner_count|
        row = Array(Array(String?)).new(inner_count.to_i)
        inner_count.to_i.times do
          raise CorruptPartError.new("Array(Array(Nullable(String))) size1 count exceeds selected sizes") if inner_offset >= components.inner_sizes.size
          string_count = components.inner_sizes[inner_offset]
          inner = Array(String?).new(string_count.to_i)
          string_count.to_i.times do
            raise CorruptPartError.new("Array(Array(Nullable(String))) size count exceeds selected sizes") if string_offset >= components.string_sizes.size
            length = components.string_sizes[string_offset]
            raise CorruptPartError.new("Array(Array(Nullable(String))) size exceeds selected raw bytes") if length > (raw_bytes.size - raw_offset).to_u64
            byte_length = length.to_i
            inner << (components.null_map[string_offset] == 1_u8 ? nil : String.new(raw_bytes[raw_offset, byte_length]))
            raw_offset += byte_length
            string_offset += 1
          end
          row << inner
          inner_offset += 1
        end
        values << row
      end
      raise CorruptPartError.new("Array(Array(Nullable(String))) sizes do not consume selected inner Arrays") unless inner_offset == components.inner_sizes.size
      raise CorruptPartError.new("Array(Array(Nullable(String))) sizes do not consume selected String lengths") unless string_offset == components.string_sizes.size
      raise CorruptPartError.new("Array(Array(Nullable(String))) lengths do not consume selected raw bytes") unless raw_offset == raw_bytes.size
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
      raise UnsupportedFormatError.new("Decimal32 Array accessor requires Array(Decimal(P, S)) with P in 1..9") unless WidePart.array_decimal32_scale(@column_type)
      read_array_fixed_leaf_mark_range(column, first_mark, mark_count, Int32)
    end

    def read_array_nullable_decimal32_raw_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Int32?))
      ensure_column(column)
      raise UnsupportedFormatError.new("Decimal32 Array accessor requires Array(Nullable(Decimal(P, S))) with P in 1..9") unless WidePart.array_nullable_decimal32_scale(@column_type)
      read_array_nullable_fixed_leaf_mark_range(column, first_mark, mark_count, Int32)
    end

    def read_array_decimal64_raw_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Int64))
      ensure_column(column)
      raise UnsupportedFormatError.new("Decimal64 Array accessor requires Array(Decimal(P, S)) with P in 10..18") unless WidePart.array_decimal64_scale(@column_type)
      read_array_fixed_leaf_mark_range(column, first_mark, mark_count, Int64)
    end

    def read_array_nullable_decimal64_raw_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Int64?))
      ensure_column(column)
      raise UnsupportedFormatError.new("Decimal64 Array accessor requires Array(Nullable(Decimal(P, S))) with P in 10..18") unless WidePart.array_nullable_decimal64_scale(@column_type)
      read_array_nullable_fixed_leaf_mark_range(column, first_mark, mark_count, Int64)
    end

    def read_array_decimal128_raw_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Int128))
      ensure_column(column)
      raise UnsupportedFormatError.new("Decimal128 Array accessor requires Array(Decimal(P, S)) with P in 19..38") unless WidePart.array_decimal128_scale(@column_type)
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
      raise UnsupportedFormatError.new("Decimal128 Array accessor requires Array(Nullable(Decimal(P, S))) with P in 19..38") unless WidePart.array_nullable_decimal128_scale(@column_type)
      read_array_nullable_fixed_leaf_mark_range(column, first_mark, mark_count, Int128)
    end

    def read_array_decimal256_raw_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(Array(Decimal256Value))
      ensure_column(column)
      raise UnsupportedFormatError.new("Decimal256 Array accessor requires Array(Decimal(P, S)) with P in 39..76") unless WidePart.array_decimal256_scale(@column_type)

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
      raise UnsupportedFormatError.new("Decimal256 Array accessor requires Array(Nullable(Decimal(P, S))) with P in 39..76") unless WidePart.array_nullable_decimal256_scale(@column_type)

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
      unless WidePart.temporal_array_element_type(@column_type).try { |actual| WidePart.same_temporal_leaf_family?(actual, element_type) } &&
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
      unless WidePart.nullable_temporal_array_element_type(@column_type).try { |actual| WidePart.same_temporal_leaf_family?(actual, element_type) } &&
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
    # generic numeric Array codecs and uses the shared semantic value codec.
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
          row << BoolValueCodec.decode(value_bytes[byte_offset])
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
            row << BoolValueCodec.decode(value_bytes[element_offset])
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

    # Read exactly two Array levels over a nullable primitive numeric leaf.
    # size0, size1, null-map, and value marks are checked per selected mark
    # before result rows are allocated; floating leaves retain their raw bits.
    def read_array_array_nullable_numeric_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
      type : T.class,
    ) : Array(Array(Array(T?))) forall T
      ensure_column(column)
      element_type = WidePart.array_numeric_type_name(type)
      unless WidePart.array_array_nullable_numeric_element_type(@column_type) == element_type
        raise UnsupportedFormatError.new("typed nested nullable Array accessor does not match selected column type")
      end

      validate_array_array_numeric_size0_marks(column, first_mark, mark_count)
      validate_array_array_nullable_numeric_stream_mark_rows(column, first_mark, mark_count)
      outer_sizes, flat_inner_arrays, rows, mark_inner_arrays = read_array_outer_sizes(column, first_mark, mark_count)
      element_width = WidePart.array_numeric_payload_width(element_type)
      element_sizes, flat_leaf_elements, mark_leaf_elements = read_array_array_numeric_element_sizes(
        column,
        first_mark,
        mark_count,
        flat_inner_arrays,
        rows,
        mark_inner_arrays,
        element_width
      )
      raise CorruptPartError.new("Array(Array(Nullable(T))) outer row count changed") unless outer_sizes.size.to_u64 == rows
      raise CorruptPartError.new("Array(Array(Nullable(T))) nested size count changed") unless element_sizes.size.to_u64 == flat_inner_arrays

      null_stream = @streams["#{column}.null"]
      null_start, null_end, null_rows = checked_stream_mark_range(null_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Array(Nullable(T))) null-map mark rows differ") unless null_rows == rows
      validate_array_nested_stream_marks(null_stream, first_mark, mark_leaf_elements, 1)
      null_bytes = read_mark_range_bytes(
        null_stream,
        null_start,
        null_end,
        checked_array_mark_byte_count(flat_leaf_elements, 1),
        1
      )

      value_stream = @streams[column]
      value_start, value_end, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Array(Nullable(T))) value mark rows differ") unless value_rows == rows
      validate_array_nested_stream_marks(value_stream, first_mark, mark_leaf_elements, element_width)
      value_bytes = read_mark_range_bytes(
        value_stream,
        value_start,
        value_end,
        checked_array_mark_byte_count(flat_leaf_elements, element_width),
        element_width
      )

      values = Array(Array(Array(T?))).new(rows.to_i)
      inner_offset = 0
      leaf_offset = 0
      value_offset = 0
      outer_sizes.each do |inner_count|
        row = Array(Array(T?)).new(inner_count.to_i)
        inner_count.to_i.times do
          raise CorruptPartError.new("Array(Array(Nullable(T))) size1 count exceeds selected bytes") if inner_offset >= element_sizes.size
          leaf_count = element_sizes[inner_offset]
          inner = Array(T?).new(leaf_count.to_i)
          leaf_count.to_i.times do
            raise CorruptPartError.new("Array(Array(Nullable(T))) sizes exceed selected child streams") if leaf_offset >= flat_leaf_elements
            is_null = null_bytes[leaf_offset]
            raise CorruptPartError.new("Array(Array(Nullable(T))) null map contains a value other than 0 or 1") unless is_null <= 1_u8
            raise CorruptPartError.new("Array(Array(Nullable(T))) sizes exceed selected value bytes") if value_offset > value_bytes.size - element_width
            inner << (is_null == 1_u8 ? nil : decode_array_numeric_value(value_bytes, value_offset, type))
            value_offset += element_width
            leaf_offset += 1
          end
          row << inner
          inner_offset += 1
        end
        values << row
      end
      raise CorruptPartError.new("Array(Array(Nullable(T))) sizes do not consume selected nested sizes") unless inner_offset == element_sizes.size
      raise CorruptPartError.new("Array(Array(Nullable(T))) sizes do not consume selected child streams") unless leaf_offset.to_u64 == flat_leaf_elements
      raise CorruptPartError.new("Array(Array(Nullable(T))) sizes do not consume selected value bytes") unless value_offset == value_bytes.size
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
      size_stream_name : String? = nil,
      raw_stream_name : String? = nil,
    ) : {Array(UInt64), UInt64, Array(UInt64)}
      size_stream = @streams[size_stream_name || "#{column}#{child_path}.size"]
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
      raw_stream = @streams[raw_stream_name || "#{column}#{child_path}"]
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

    # Map size0 is the row-count stream for this exact W63 shape. Check its
    # byte extent at every selected mark instead of trusting only the joined
    # range, so a shifted middle mark cannot borrow bytes from its neighbor.
    private def validate_map_array_uint64_size0_marks(
      column : String,
      first_mark : Int,
      mark_count : Int,
      expected_rows : UInt64,
    ) : Nil
      size_stream = @streams["#{column}.size0"]
      _, _, size_rows = checked_stream_mark_range(size_stream, first_mark, mark_count)
      raise CorruptPartError.new("Map size0 row count changed") unless size_rows == expected_rows
      mark_count.times do |range_mark_index|
        mark_index = first_mark + range_mark_index
        start_mark = size_stream.marks[mark_index]
        end_mark = mark_index + 1 == size_stream.marks.size ? size_stream.sentinel : size_stream.marks[mark_index + 1]
        expected_bytes = checked_array_mark_byte_count(start_mark.rows, 8)
        validate_mark_range_bytes(size_stream, start_mark, end_mark, expected_bytes, 8)
      end
      nil
    end

    # Decode per-entry nested Array leaf counts for W70. These counts have
    # the Map-entry coordinate system, while every child mark row count stays
    # in the table-row coordinate system.
    private def read_map_array_nullable_string_value_sizes(
      column : String,
      first_mark : Int,
      mark_count : Int,
      flat_entries : UInt64,
      outer_rows : UInt64,
      mark_flat_entries : Array(UInt64),
    ) : {Array(UInt64), UInt64, Array(UInt64)}
      size_stream = @streams["#{column}%2Evalues.size1"]
      size_start, size_end, size_rows = checked_stream_mark_range(size_stream, first_mark, mark_count)
      raise CorruptPartError.new("Map value-size substream mark rows differ") unless size_rows == outer_rows
      validate_array_nested_stream_marks(size_stream, first_mark, mark_flat_entries, 8)
      encoded_sizes = read_mark_range_bytes(
        size_stream,
        size_start,
        size_end,
        checked_array_mark_byte_count(flat_entries, 8),
        8
      )

      entry_sizes = Array(UInt64).new(flat_entries.to_i)
      mark_leaf_counts = Array(UInt64).new(mark_count)
      total_leaves = 0_u64
      size_offset = 0
      mark_flat_entries.each do |mark_entry_count|
        mark_leaf_count = 0_u64
        mark_entry_count.to_i.times do
          raise CorruptPartError.new("Map value-size count exceeds selected bytes") if size_offset > encoded_sizes.size - 8
          leaf_count = u64(encoded_sizes, size_offset)
          if leaf_count > MAX_ARRAY_MARK_ELEMENTS - mark_leaf_count || leaf_count > MAX_ARRAY_MARK_ELEMENTS - total_leaves
            raise CorruptPartError.new("Map nested Nullable String count exceeds per-range limit")
          end
          mark_leaf_count += leaf_count
          total_leaves += leaf_count
          entry_sizes << leaf_count
          size_offset += 8
        end
        checked_array_mark_byte_count(mark_leaf_count, 1)
        mark_leaf_counts << mark_leaf_count
      end
      raise CorruptPartError.new("Map value-size stream has trailing bytes") unless size_offset == encoded_sizes.size
      raise CorruptPartError.new("Map value-size count does not match size0") unless entry_sizes.size.to_u64 == flat_entries
      checked_array_mark_byte_count(total_leaves, 1)
      {entry_sizes, total_leaves, mark_leaf_counts}
    end

    # Decode the per-entry values.size1 offsets for selected Map marks and
    # validate each corresponding fixed-width values mark before materializing.
    private def read_map_array_uint64_element_sizes(
      column : String,
      first_mark : Int,
      mark_count : Int,
      flat_entries : UInt64,
      outer_rows : UInt64,
      mark_flat_entries : Array(UInt64),
    ) : {Array(UInt64), UInt64, Array(UInt64)}
      size_stream = @streams["#{column}%2Evalues.size1"]
      size_start, size_end, size_rows = checked_stream_mark_range(size_stream, first_mark, mark_count)
      raise CorruptPartError.new("Map value-size substream mark rows differ") unless size_rows == outer_rows
      validate_array_nested_stream_marks(size_stream, first_mark, mark_flat_entries, 8)
      encoded_sizes = read_mark_range_bytes(
        size_stream,
        size_start,
        size_end,
        checked_array_mark_byte_count(flat_entries, 8),
        8
      )

      element_sizes = Array(UInt64).new(flat_entries.to_i)
      mark_value_elements = Array(UInt64).new(mark_count)
      total_values = 0_u64
      size_offset = 0
      mark_flat_entries.each do |mark_entry_count|
        mark_value_count = 0_u64
        mark_entry_count.to_i.times do
          raise CorruptPartError.new("Map value-size count exceeds selected bytes") if size_offset > encoded_sizes.size - 8
          value_count = u64(encoded_sizes, size_offset)
          if value_count > MAX_ARRAY_MARK_ELEMENTS - mark_value_count || value_count > MAX_ARRAY_MARK_ELEMENTS - total_values
            raise CorruptPartError.new("Map nested UInt64 count exceeds per-range limit")
          end
          mark_value_count += value_count
          total_values += value_count
          element_sizes << value_count
          size_offset += 8
        end
        checked_array_mark_byte_count(mark_value_count, 8)
        mark_value_elements << mark_value_count
      end
      raise CorruptPartError.new("Map value-size stream has trailing bytes") unless size_offset == encoded_sizes.size
      raise CorruptPartError.new("Map value-size count does not match size0") unless element_sizes.size.to_u64 == flat_entries
      checked_array_mark_byte_count(total_values, 8)

      values_stream = @streams["#{column}%2Evalues"]
      _, _, value_rows = checked_stream_mark_range(values_stream, first_mark, mark_count)
      raise CorruptPartError.new("Map value substream mark rows differ") unless value_rows == outer_rows
      validate_array_nested_stream_marks(values_stream, first_mark, mark_value_elements, 8)
      {element_sizes, total_values, mark_value_elements}
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

    private def checked_map_array_tuple_charge(
      payload_bytes : UInt64,
      elements : UInt64,
      rows : UInt64,
      row_width : UInt64 = ARRAY_TUPLE_ROW_ACCOUNTING_BYTES,
    ) : UInt64
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

    # W80's physical plan supplies the exact child stream names and axes.
    # Keep this bridge exact: it is not a generic nested Map dispatcher.
    private def array_map_string_uint64_streams(column : String) : ArrayMapStringUInt64Streams
      plan = WideTypePlan::WidePhysicalPlanShadow.for_type(@column_type, column) ||
             raise UnsupportedFormatError.new("no physical plan for exact Array(Map(String, UInt64)) column")
      descriptors = plan.streams
      raise UnsupportedFormatError.new("unexpected Array(Map(String, UInt64)) physical plan") unless descriptors.size == 5

      outer_sizes = descriptors.find do |stream|
        stream.role.array_size0? && stream.semantic_path.empty?
      end || raise UnsupportedFormatError.new("physical plan omits the outer Array offsets")
      map_sizes = descriptors.find do |stream|
        stream.role.array_size1? && stream.semantic_path.empty?
      end || raise UnsupportedFormatError.new("physical plan omits the Map offsets")
      key_sizes = descriptors.find do |stream|
        stream.role.string_size? && stream.semantic_path == ["keys"]
      end || raise UnsupportedFormatError.new("physical plan omits String key sizes")
      keys = descriptors.find do |stream|
        stream.role.value? && stream.semantic_path == ["keys"]
      end || raise UnsupportedFormatError.new("physical plan omits String key data")
      values = descriptors.find do |stream|
        stream.role.value? && stream.semantic_path == ["values"]
      end || raise UnsupportedFormatError.new("physical plan omits UInt64 values")

      unless outer_sizes.cardinality_parent_axis.try(&.id) == plan.mark_row_axis.id &&
             outer_sizes.cardinality_child_axis.try(&.kind).try(&.array_elements?) &&
             map_sizes.cardinality_parent_axis.try(&.id) == outer_sizes.cardinality_child_axis.try(&.id) &&
             map_sizes.cardinality_child_axis.try(&.kind).try(&.map_entries?) &&
             key_sizes.cardinality_parent_axis.try(&.id) == map_sizes.cardinality_child_axis.try(&.id) &&
             key_sizes.cardinality_child_axis.try(&.kind).try(&.string_bytes?) &&
             keys.storage_axis.id == key_sizes.cardinality_child_axis.try(&.id) &&
             values.storage_axis.id == map_sizes.cardinality_child_axis.try(&.id)
        raise UnsupportedFormatError.new("Array(Map(String, UInt64)) physical axes are inconsistent")
      end
      unless descriptors.all? { |stream| stream.mark_row_axis.id == plan.mark_row_axis.id }
        raise UnsupportedFormatError.new("Array(Map(String, UInt64)) physical mark axis is inconsistent")
      end

      ArrayMapStringUInt64Streams.new(outer_sizes, map_sizes, key_sizes, keys, values)
    end

    private def array_map_string_uint64_stream_may_be_empty?(column : String, stream_name : String) : Bool
      array_map_stream_may_be_empty?(column, stream_name)
    end

    private def array_map_stream_may_be_empty?(column : String, stream_name : String) : Bool
      plan = WideTypePlan::WidePhysicalPlanShadow.for_type(@column_type, column) || return false
      descriptor = plan.streams.find(&.name.==(stream_name)) || return false
      descriptor.storage_axis.kind != WideTypePlan::WidePhysicalPlanShadow::AxisKind::TableRows
    end

    private def validate_array_map_string_uint64_mark_rows(
      streams : ArrayMapStringUInt64Streams,
      first_mark : Int,
      mark_count : Int,
      rows : UInt64,
    ) : Nil
      [streams.outer_sizes, streams.map_sizes, streams.key_sizes, streams.keys, streams.values].each do |descriptor|
        stream = @streams[descriptor.name]
        _, _, stream_rows = checked_stream_mark_range(stream, first_mark, mark_count)
        raise CorruptPartError.new("Array(Map(String, UInt64)) child mark rows differ") unless stream_rows == rows
        mark_count.times do |range_mark_index|
          mark_index = first_mark + range_mark_index
          expected_rows = @streams[streams.outer_sizes.name].marks[mark_index].rows
          unless stream.marks[mark_index].rows == expected_rows
            raise CorruptPartError.new("Array(Map(String, UInt64)) child mark rows differ")
          end
        end
      end
      nil
    end

    private def checked_array_map_string_uint64_charge(
      payload_bytes : UInt64,
      maps : UInt64,
      entries : UInt64,
      rows : UInt64,
    ) : UInt64
      row_width = ARRAY_MAP_ROW_ACCOUNTING_BYTES
      map_width = ARRAY_MAP_CONTAINER_ACCOUNTING_BYTES
      entry_width = ARRAY_TUPLE_ENTRY_ACCOUNTING_BYTES
      if rows > UInt64::MAX // row_width || maps > UInt64::MAX // map_width || entries > UInt64::MAX // entry_width
        raise CorruptPartError.new("Array(Map(String, UInt64)) materialization charge overflows")
      end
      row_bytes = rows * row_width
      map_bytes = maps * map_width
      entry_bytes = entries * entry_width
      if map_bytes > UInt64::MAX - row_bytes || entry_bytes > UInt64::MAX - row_bytes - map_bytes ||
         payload_bytes > UInt64::MAX - row_bytes - map_bytes - entry_bytes
        raise CorruptPartError.new("Array(Map(String, UInt64)) materialization charge overflows")
      end
      charge_bytes = row_bytes + map_bytes + entry_bytes + payload_bytes
      if charge_bytes > MAX_ARRAY_MARK_BYTES.to_u64
        raise CorruptPartError.new("Array(Map(String, UInt64)) materialization charge exceeds per-range limit")
      end
      charge_bytes
    end

    private def array_map_string_uint64_preflight(
      column : String,
      first_mark : Int,
      mark_count : Int,
    ) : ArrayMapStringUInt64Preflight
      ensure_column(column)
      unless WidePart.supports_array_map_string_uint64_type?(@column_type)
        raise UnsupportedFormatError.new("Array(Map) accessor requires the exact Array(Map(String, UInt64)) declaration")
      end

      streams = array_map_string_uint64_streams(column)
      outer_sizes, maps, rows, mark_maps = read_array_outer_sizes(
        column, first_mark, mark_count, streams.outer_sizes.name
      )
      validate_array_map_string_uint64_mark_rows(streams, first_mark, mark_count, rows)

      map_sizes, entries, mark_entries = read_array_array_numeric_element_sizes(
        column, first_mark, mark_count, maps, rows, mark_maps, 8, streams.map_sizes.name
      )
      unless map_sizes.size.to_u64 == maps
        raise CorruptPartError.new("Array(Map(String, UInt64)) map offsets do not match outer Array size")
      end

      key_sizes, key_bytes, key_mark_bytes = read_map_string_child_sizes(
        column,
        "%2Ekeys",
        "Array(Map) key",
        first_mark,
        mark_count,
        entries,
        rows,
        mark_entries,
        streams.key_sizes.name,
        streams.keys.name
      )
      unless key_sizes.size.to_u64 == entries
        raise CorruptPartError.new("Array(Map(String, UInt64)) key sizes do not match Map offsets")
      end

      values_stream = @streams[streams.values.name]
      _, _, values_rows = checked_stream_mark_range(values_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Map(String, UInt64)) values mark rows differ") unless values_rows == rows
      validate_array_nested_stream_marks(values_stream, first_mark, mark_entries, 8)
      value_bytes = checked_array_mark_byte_count(entries, 8).to_u64
      value_mark_bytes = mark_entries.map { |mark_count| checked_array_mark_byte_count(mark_count, 8).to_u64 }
      payload_bytes = checked_map_materialized_bytes(key_bytes, value_bytes, key_mark_bytes, value_mark_bytes)
      charge_bytes = checked_array_map_string_uint64_charge(payload_bytes, maps, entries, rows)

      ArrayMapStringUInt64Preflight.new(
        streams, outer_sizes, map_sizes, key_sizes, rows, maps, entries,
        key_bytes, value_bytes, payload_bytes, charge_bytes
      )
    end

    # Report just retained key/value payload and a conservative object charge;
    # offset and String-size streams are validated but excluded from payload_bytes.
    def array_map_string_uint64_mark_range_materialization_preflight(
      column : String,
      start_mark : Int,
      mark_count : Int,
    ) : {payload_bytes: UInt64, charge_bytes: UInt64}
      preflight = array_map_string_uint64_preflight(column, start_mark, mark_count)
      {payload_bytes: preflight.payload_bytes, charge_bytes: preflight.charge_bytes}
    end

    # Read rows of Arrays of ordered Maps while preserving duplicate keys and
    # arbitrary String key bytes. Full selected-range validation and charge
    # checks complete before any returned object graph is constructed.
    def read_array_map_string_uint64_mark_range(
      column : String,
      start_mark : Int,
      mark_count : Int,
    ) : Array(Array(Array(Tuple(String, UInt64))))
      preflight = array_map_string_uint64_preflight(column, start_mark, mark_count)

      keys_stream = @streams[preflight.streams.keys.name]
      keys_start, keys_end, _ = checked_stream_mark_range(keys_stream, start_mark, mark_count)
      key_bytes = read_mark_range_bytes(keys_stream, keys_start, keys_end, preflight.key_bytes.to_i, 1)
      values_stream = @streams[preflight.streams.values.name]
      values_start, values_end, _ = checked_stream_mark_range(values_stream, start_mark, mark_count)
      value_bytes = read_mark_range_bytes(values_stream, values_start, values_end, preflight.value_bytes.to_i, 8)

      result = Array(Array(Array(Tuple(String, UInt64)))).new(preflight.rows.to_i)
      map_offset = 0
      entry_offset = 0
      key_offset = 0
      value_offset = 0
      preflight.outer_sizes.each do |map_count|
        row = Array(Array(Tuple(String, UInt64))).new(map_count.to_i)
        map_count.to_i.times do
          raise CorruptPartError.new("Array(Map) outer sizes exceed selected Map offsets") if map_offset >= preflight.map_sizes.size
          entry_count = preflight.map_sizes[map_offset].to_i
          map = Array(Tuple(String, UInt64)).new(entry_count)
          entry_count.times do
            raise CorruptPartError.new("Array(Map) offsets exceed selected key sizes") if entry_offset >= preflight.key_sizes.size
            key_length = preflight.key_sizes[entry_offset].to_i
            if key_offset > key_bytes.size || key_length > key_bytes.size - key_offset
              raise CorruptPartError.new("Array(Map) key sizes exceed selected raw bytes")
            end
            if value_offset > value_bytes.size - 8
              raise CorruptPartError.new("Array(Map) values exceed selected payload bytes")
            end
            map << {String.new(key_bytes[key_offset, key_length]), u64(value_bytes, value_offset)}
            key_offset += key_length
            value_offset += 8
            entry_offset += 1
          end
          row << map
          map_offset += 1
        end
        result << row
      end
      unless map_offset == preflight.map_sizes.size && entry_offset.to_u64 == preflight.entries
        raise CorruptPartError.new("Array(Map) offsets do not consume selected Map entries")
      end
      raise CorruptPartError.new("Array(Map) key lengths do not consume selected raw bytes") unless key_offset == key_bytes.size
      raise CorruptPartError.new("Array(Map) sizes do not consume selected value bytes") unless value_offset == value_bytes.size
      result
    end

    # W82 String leaves have variable-width key/value children (or a fixed
    # UInt64 key) and optionally a separate value null bitmap. Bind each
    # descriptor to the exact admitted declaration before reading bytes.
    private def array_map_string_leaf_streams(
      column : String,
      string_keys : Bool,
      nullable_values : Bool,
    ) : ArrayMapStringLeafStreams
      plan = WideTypePlan::WidePhysicalPlanShadow.for_type(@column_type, column) ||
             raise UnsupportedFormatError.new("no physical plan for exact Array(Map) String leaf column")
      descriptors = plan.streams
      expected_count = 5 + (string_keys ? 1 : 0) + (nullable_values ? 1 : 0)
      raise UnsupportedFormatError.new("unexpected Array(Map) String leaf physical plan") unless descriptors.size == expected_count

      outer_sizes = descriptors.find do |stream|
        stream.name == "#{column}.size0" && stream.role.array_size0? && stream.semantic_path.empty?
      end || raise UnsupportedFormatError.new("physical plan omits the outer Array offsets")
      map_sizes = descriptors.find do |stream|
        stream.name == "#{column}.size1" && stream.role.array_size1? && stream.semantic_path.empty?
      end || raise UnsupportedFormatError.new("physical plan omits the inner Map offsets")
      keys = descriptors.find do |stream|
        stream.name == "#{column}%2Ekeys" && stream.role.value? && stream.semantic_path == ["keys"]
      end || raise UnsupportedFormatError.new("physical plan omits Map keys")
      key_sizes = if string_keys
                    descriptors.find do |stream|
                      stream.name == "#{column}%2Ekeys.size" && stream.role.string_size? && stream.semantic_path == ["keys"]
                    end || raise UnsupportedFormatError.new("physical plan omits String key sizes")
                  else
                    nil
                  end
      null_map = if nullable_values
                   descriptors.find do |stream|
                     stream.name == "#{column}%2Evalues.null" && stream.role.null_map? && stream.semantic_path == ["values"]
                   end || raise UnsupportedFormatError.new("physical plan omits the Nullable value map")
                 else
                   nil
                 end
      value_sizes = descriptors.find do |stream|
        stream.name == "#{column}%2Evalues.size" && stream.role.string_size? && stream.semantic_path == ["values"]
      end || raise UnsupportedFormatError.new("physical plan omits String value sizes")
      values = descriptors.find do |stream|
        stream.name == "#{column}%2Evalues" && stream.role.value? && stream.semantic_path == ["values"]
      end || raise UnsupportedFormatError.new("physical plan omits String values")

      array_axis = outer_sizes.cardinality_child_axis || raise UnsupportedFormatError.new("outer Array plan omits its element axis")
      entries_axis = map_sizes.cardinality_child_axis || raise UnsupportedFormatError.new("Map plan omits its entry axis")
      unless outer_sizes.cardinality_parent_axis.try(&.id) == plan.mark_row_axis.id &&
             outer_sizes.storage_mode.counts? && array_axis.kind.array_elements? &&
             map_sizes.cardinality_parent_axis.try(&.id) == array_axis.id &&
             map_sizes.storage_mode.counts? && entries_axis.kind.map_entries? &&
             value_sizes.cardinality_parent_axis.try(&.id) == entries_axis.id &&
             value_sizes.storage_mode.counts? &&
             value_sizes.cardinality_child_axis.try(&.kind).try(&.string_bytes?) &&
             values.storage_mode.variable_bytes? &&
             values.storage_axis.id == value_sizes.cardinality_child_axis.try(&.id)
        raise UnsupportedFormatError.new("Array(Map) String value physical axes are inconsistent")
      end
      if string_keys
        key_bytes_axis = key_sizes.not_nil!.cardinality_child_axis || raise UnsupportedFormatError.new("String key plan omits its byte axis")
        unless key_sizes.not_nil!.cardinality_parent_axis.try(&.id) == entries_axis.id &&
               key_sizes.not_nil!.storage_mode.counts? && key_bytes_axis.kind.string_bytes? &&
               keys.storage_mode.variable_bytes? && keys.storage_axis.id == key_bytes_axis.id
          raise UnsupportedFormatError.new("Array(Map) String key axes are inconsistent")
        end
      else
        unless keys.storage_mode.fixed_width_values? && keys.storage_axis.id == entries_axis.id
          raise UnsupportedFormatError.new("Array(Map) UInt64 key axis is inconsistent")
        end
      end
      if null_map && (!null_map.storage_mode.null_map_bytes? || null_map.storage_axis.id != entries_axis.id)
        raise UnsupportedFormatError.new("Array(Map) Nullable value axis is inconsistent")
      end
      unless descriptors.all? { |stream| stream.mark_row_axis.id == plan.mark_row_axis.id }
        raise UnsupportedFormatError.new("Array(Map) String leaf physical mark axis is inconsistent")
      end

      ArrayMapStringLeafStreams.new(outer_sizes, map_sizes, key_sizes, keys, null_map, value_sizes, values)
    end

    private def validate_array_map_string_leaf_mark_rows(
      streams : ArrayMapStringLeafStreams,
      first_mark : Int,
      mark_count : Int,
      rows : UInt64,
    ) : Nil
      descriptors = [streams.outer_sizes, streams.map_sizes, streams.keys, streams.value_sizes, streams.values]
      descriptors << streams.key_sizes.not_nil! if streams.key_sizes
      descriptors << streams.null_map.not_nil! if streams.null_map
      outer_stream = @streams[streams.outer_sizes.name]
      expected_mark_rows = Array(UInt64).new(mark_count)
      mark_count.times do |range_mark_index|
        expected_mark_rows << outer_stream.marks[first_mark + range_mark_index].rows
      end
      descriptors.each do |descriptor|
        stream = @streams[descriptor.name]
        _, _, stream_rows = checked_stream_mark_range(stream, first_mark, mark_count)
        raise CorruptPartError.new("Array(Map) String leaf child mark rows differ") unless stream_rows == rows
        mark_count.times do |range_mark_index|
          unless stream.marks[first_mark + range_mark_index].rows == expected_mark_rows[range_mark_index]
            raise CorruptPartError.new("Array(Map) String leaf child mark rows differ")
          end
        end
      end
      validate_array_nested_stream_marks(outer_stream, first_mark, expected_mark_rows, 8)
      nil
    end

    private def array_map_string_leaf_preflight(
      column : String,
      first_mark : Int,
      mark_count : Int,
      string_keys : Bool,
      nullable_values : Bool,
    ) : ArrayMapStringLeafPreflight
      ensure_column(column)
      expected_shape = {string_keys ? "String" : "UInt64", nullable_values}
      unless WidePart.array_map_string_leaf_shape(@column_type) == expected_shape
        key_type = string_keys ? "String" : "UInt64"
        value_type = nullable_values ? "Nullable(String)" : "String"
        raise UnsupportedFormatError.new("Array(Map) accessor requires exact Array(Map(#{key_type}, #{value_type}))")
      end

      streams = array_map_string_leaf_streams(column, string_keys, nullable_values)
      outer_sizes, maps, rows, mark_maps = read_array_outer_sizes(column, first_mark, mark_count, streams.outer_sizes.name)
      validate_array_map_string_leaf_mark_rows(streams, first_mark, mark_count, rows)
      map_sizes, entries, mark_entries = read_array_array_numeric_element_sizes(
        column, first_mark, mark_count, maps, rows, mark_maps, 1, streams.map_sizes.name
      )
      raise CorruptPartError.new("Array(Map) Map offsets do not match outer Array sizes") unless map_sizes.size.to_u64 == maps

      key_sizes = [] of UInt64
      key_bytes = 0_u64
      key_mark_bytes = [] of UInt64
      if string_keys
        key_sizes, key_bytes, key_mark_bytes = read_map_string_child_sizes(
          column, "%2Ekeys", "Array(Map) key", first_mark, mark_count,
          entries, rows, mark_entries, streams.key_sizes.not_nil!.name, streams.keys.name
        )
        raise CorruptPartError.new("Array(Map) key sizes do not match Map offsets") unless key_sizes.size.to_u64 == entries
      else
        key_stream = @streams[streams.keys.name]
        _, _, key_rows = checked_stream_mark_range(key_stream, first_mark, mark_count)
        raise CorruptPartError.new("Array(Map) key mark rows differ") unless key_rows == rows
        validate_array_nested_stream_marks(key_stream, first_mark, mark_entries, 8)
        key_bytes = checked_array_mark_byte_count(entries, 8).to_u64
        key_mark_bytes = mark_entries.map { |count| checked_array_mark_byte_count(count, 8).to_u64 }
      end

      value_sizes, value_bytes, value_mark_bytes = read_map_string_child_sizes(
        column, "%2Evalues", "Array(Map) value", first_mark, mark_count,
        entries, rows, mark_entries, streams.value_sizes.name, streams.values.name
      )
      raise CorruptPartError.new("Array(Map) value sizes do not match Map offsets") unless value_sizes.size.to_u64 == entries

      null_map : Bytes? = if nullable_values
        null_stream = @streams[streams.null_map.not_nil!.name]
        null_start, null_end, null_rows = checked_stream_mark_range(null_stream, first_mark, mark_count)
        raise CorruptPartError.new("Array(Map) Nullable mark rows differ") unless null_rows == rows
        validate_array_nested_stream_marks(null_stream, first_mark, mark_entries, 1)
        null_map_bytes = read_mark_range_bytes(null_stream, null_start, null_end, checked_array_mark_byte_count(entries, 1), 1)
        null_map_bytes.each do |value|
          raise CorruptPartError.new("Array(Map) null-map byte is not boolean") unless value <= 1_u8
        end
        null_map_bytes
      else
        nil
      end
      if nullable_values
        value_mark_bytes = value_mark_bytes.each_with_index.map do |mark_value_bytes, index|
          null_bytes = checked_array_mark_byte_count(mark_entries[index], 1).to_u64
          raise CorruptPartError.new("Array(Map) Nullable value mark byte count overflows") if mark_value_bytes > UInt64::MAX - null_bytes
          mark_value_bytes + null_bytes
        end.to_a
      end
      nullable_bytes = nullable_values ? checked_array_mark_byte_count(entries, 1).to_u64 : 0_u64
      if value_bytes > UInt64::MAX - nullable_bytes
        raise CorruptPartError.new("Array(Map) Nullable value byte count overflows")
      end
      payload_bytes = checked_map_materialized_bytes(
        key_bytes, value_bytes + nullable_bytes, key_mark_bytes, value_mark_bytes
      )
      charge_bytes = checked_array_map_numeric_charge(payload_bytes, maps, entries, rows)
      ArrayMapStringLeafPreflight.new(
        streams, outer_sizes, map_sizes, key_sizes, value_sizes, rows, maps, entries,
        key_bytes, value_bytes, payload_bytes, charge_bytes, null_map
      )
    end

    private def read_array_map_string_leaf_nullable_rows(
      column : String,
      first_mark : Int,
      mark_count : Int,
      key_type : K.class,
      nullable_values : Bool = true,
    ) : Array(Array(Array(Tuple(K, String?)))) forall K
      string_keys = K == String
      preflight = array_map_string_leaf_preflight(column, first_mark, mark_count, string_keys, nullable_values)
      key_stream = @streams[preflight.streams.keys.name]
      key_start, key_end, _ = checked_stream_mark_range(key_stream, first_mark, mark_count)
      key_width = string_keys ? 1 : 8
      key_bytes = read_mark_range_bytes(key_stream, key_start, key_end, preflight.key_bytes.to_i, key_width)
      null_map = preflight.null_map
      values_stream = @streams[preflight.streams.values.name]
      values_start, values_end, _ = checked_stream_mark_range(values_stream, first_mark, mark_count)
      value_bytes = read_mark_range_bytes(values_stream, values_start, values_end, preflight.value_bytes.to_i, 1)

      result = Array(Array(Array(Tuple(K, String?)))).new(preflight.rows.to_i)
      map_offset = 0
      entry_offset = 0
      key_offset = 0
      value_offset = 0
      preflight.outer_sizes.each do |map_count|
        row = Array(Array(Tuple(K, String?))).new(map_count.to_i)
        map_count.to_i.times do
          raise CorruptPartError.new("Array(Map) outer sizes exceed selected Map offsets") if map_offset >= preflight.map_sizes.size
          entry_count = preflight.map_sizes[map_offset].to_i
          map = Array(Tuple(K, String?)).new(entry_count)
          entry_count.times do
            key = uninitialized K
            {% if K == String %}
              raise CorruptPartError.new("Array(Map) offsets exceed selected key sizes") if entry_offset >= preflight.key_sizes.size
              key_length = preflight.key_sizes[entry_offset].to_i
              if key_offset > key_bytes.size || key_length > key_bytes.size - key_offset
                raise CorruptPartError.new("Array(Map) key sizes exceed selected raw bytes")
              end
              key = String.new(key_bytes[key_offset, key_length])
              key_offset += key_length
            {% else %}
              if entry_offset > key_bytes.size // 8 - 1
                raise CorruptPartError.new("Array(Map) keys exceed selected UInt64 bytes")
              end
              key = u64(key_bytes, entry_offset * 8)
            {% end %}
            raise CorruptPartError.new("Array(Map) values exceed selected raw bytes") if value_offset > value_bytes.size
            value_length = preflight.value_sizes[entry_offset].to_i
            if value_length > value_bytes.size - value_offset
              raise CorruptPartError.new("Array(Map) value sizes exceed selected raw bytes")
            end
            value = if null_map
                      null_map[entry_offset] == 1_u8 ? nil : String.new(value_bytes[value_offset, value_length])
                    else
                      String.new(value_bytes[value_offset, value_length])
                    end
            map << {key, value}
            value_offset += value_length
            entry_offset += 1
          end
          row << map
          map_offset += 1
        end
        result << row
      end
      unless map_offset == preflight.map_sizes.size && entry_offset.to_u64 == preflight.entries
        raise CorruptPartError.new("Array(Map) offsets do not consume selected Map entries")
      end
      raise CorruptPartError.new("Array(Map) key sizes do not consume selected raw bytes") if string_keys && key_offset != key_bytes.size
      raise CorruptPartError.new("Array(Map) key sizes do not consume selected UInt64 bytes") if !string_keys && entry_offset * 8 != key_bytes.size
      raise CorruptPartError.new("Array(Map) value sizes do not consume selected raw bytes") unless value_offset == value_bytes.size
      result
    end

    private def read_array_map_string_leaf_rows(
      column : String,
      first_mark : Int,
      mark_count : Int,
      key_type : K.class,
    ) : Array(Array(Array(Tuple(K, String)))) forall K
      nullable_rows = read_array_map_string_leaf_nullable_rows(column, first_mark, mark_count, key_type, false)
      result = Array(Array(Array(Tuple(K, String)))).new(nullable_rows.size)
      nullable_rows.each do |row|
        plain_row = Array(Array(Tuple(K, String))).new(row.size)
        row.each do |map|
          plain_map = Array(Tuple(K, String)).new(map.size)
          map.each do |key, value|
            plain_map << {key, value || raise(CorruptPartError.new("non-nullable Array(Map) value decoded as NULL"))}
          end
          plain_row << plain_map
        end
        result << plain_row
      end
      result
    end

    def array_map_string_leaf_mark_range_materialization_preflight(
      column : String,
      first_mark : Int,
      mark_count : Int,
    ) : {payload_bytes: UInt64, charge_bytes: UInt64}
      string_keys, nullable_values = WidePart.array_map_string_leaf_shape(@column_type).try do |shape|
        {shape[0] == "String", shape[1]}
      end || raise(UnsupportedFormatError.new("selected column is not an exact W82 Array(Map) String leaf"))
      preflight = array_map_string_leaf_preflight(column, first_mark, mark_count, string_keys, nullable_values)
      {payload_bytes: preflight.payload_bytes, charge_bytes: preflight.charge_bytes}
    end

    def read_array_map_uint64_string_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
    ) : Array(Array(Array(Tuple(UInt64, String))))
      read_array_map_string_leaf_rows(column, first_mark, mark_count, UInt64)
    end

    def read_array_map_string_string_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
    ) : Array(Array(Array(Tuple(String, String))))
      read_array_map_string_leaf_rows(column, first_mark, mark_count, String)
    end

    def read_array_map_uint64_nullable_string_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
    ) : Array(Array(Array(Tuple(UInt64, String?))))
      read_array_map_string_leaf_nullable_rows(column, first_mark, mark_count, UInt64)
    end

    def read_array_map_string_nullable_string_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
    ) : Array(Array(Array(Tuple(String, String?))))
      read_array_map_string_leaf_nullable_rows(column, first_mark, mark_count, String)
    end

    # W83 Bool leaves use fixed-width one-byte Bool payloads, never String
    # length streams. The descriptor gate keeps Bool semantically distinct
    # from UInt8 even though both currently occupy one byte.
    private def array_map_bool_leaf_streams(
      column : String,
      string_keys : Bool,
      nullable_values : Bool,
    ) : ArrayMapBoolLeafStreams
      plan = WideTypePlan::WidePhysicalPlanShadow.for_type(@column_type, column) ||
             raise UnsupportedFormatError.new("no physical plan for exact Array(Map) Bool leaf column")
      descriptors = plan.streams
      expected_count = 4 + (string_keys ? 1 : 0) + (nullable_values ? 1 : 0)
      raise UnsupportedFormatError.new("unexpected Array(Map) Bool leaf physical plan") unless descriptors.size == expected_count

      outer_sizes = descriptors.find do |stream|
        stream.name == "#{column}.size0" && stream.role.array_size0? && stream.semantic_path.empty?
      end || raise UnsupportedFormatError.new("physical plan omits the outer Array offsets")
      map_sizes = descriptors.find do |stream|
        stream.name == "#{column}.size1" && stream.role.array_size1? && stream.semantic_path.empty?
      end || raise UnsupportedFormatError.new("physical plan omits the inner Map offsets")
      keys = descriptors.find do |stream|
        stream.name == "#{column}%2Ekeys" && stream.role.value? && stream.semantic_path == ["keys"]
      end || raise UnsupportedFormatError.new("physical plan omits Map keys")
      key_sizes = if string_keys
                    descriptors.find do |stream|
                      stream.name == "#{column}%2Ekeys.size" && stream.role.string_size? && stream.semantic_path == ["keys"]
                    end || raise UnsupportedFormatError.new("physical plan omits String key sizes")
                  else
                    nil
                  end
      null_map = if nullable_values
                   descriptors.find do |stream|
                     stream.name == "#{column}%2Evalues.null" && stream.role.null_map? && stream.semantic_path == ["values"]
                   end || raise UnsupportedFormatError.new("physical plan omits the Nullable value map")
                 else
                   nil
                 end
      values = descriptors.find do |stream|
        stream.name == "#{column}%2Evalues" && stream.role.value? && stream.semantic_path == ["values"]
      end || raise UnsupportedFormatError.new("physical plan omits Bool values")

      array_axis = outer_sizes.cardinality_child_axis || raise UnsupportedFormatError.new("outer Array plan omits its element axis")
      entries_axis = map_sizes.cardinality_child_axis || raise UnsupportedFormatError.new("Map plan omits its entry axis")
      unless outer_sizes.cardinality_parent_axis.try(&.id) == plan.mark_row_axis.id &&
             outer_sizes.storage_mode.counts? && array_axis.kind.array_elements? &&
             map_sizes.cardinality_parent_axis.try(&.id) == array_axis.id &&
             map_sizes.storage_mode.counts? && entries_axis.kind.map_entries?
        raise UnsupportedFormatError.new("Array(Map) Bool cardinality axes are inconsistent")
      end
      if string_keys
        key_bytes_axis = key_sizes.not_nil!.cardinality_child_axis || raise(UnsupportedFormatError.new("String key plan omits its byte axis"))
        unless key_sizes.not_nil!.cardinality_parent_axis.try(&.id) == entries_axis.id &&
               key_sizes.not_nil!.storage_mode.counts? && key_bytes_axis.kind.string_bytes? &&
               keys.storage_mode.variable_bytes? && keys.storage_axis.id == key_bytes_axis.id
          raise UnsupportedFormatError.new("Array(Map) String key axes are inconsistent")
        end
      else
        unless keys.element_width == 8 && keys.storage_mode.fixed_width_values? && keys.storage_axis.id == entries_axis.id
          raise UnsupportedFormatError.new("Array(Map) UInt64 key axis is inconsistent")
        end
      end
      expected_value_type = nullable_values ? "Nullable(Bool)" : "Bool"
      unless values.semantic_type == expected_value_type && values.element_width == 1 &&
             values.storage_mode.fixed_width_values? && values.storage_axis.id == entries_axis.id
        raise UnsupportedFormatError.new("Array(Map) Bool value axis or semantic type is inconsistent")
      end
      if null_map && (!null_map.storage_mode.null_map_bytes? || null_map.element_width != 1 || null_map.storage_axis.id != entries_axis.id)
        raise UnsupportedFormatError.new("Array(Map) Nullable Bool map axis is inconsistent")
      end
      unless descriptors.all? { |stream| stream.mark_row_axis.id == plan.mark_row_axis.id }
        raise UnsupportedFormatError.new("Array(Map) Bool physical mark axis is inconsistent")
      end

      ArrayMapBoolLeafStreams.new(outer_sizes, map_sizes, key_sizes, keys, null_map, values)
    end

    private def validate_array_map_bool_leaf_mark_rows(
      streams : ArrayMapBoolLeafStreams,
      first_mark : Int,
      mark_count : Int,
      rows : UInt64,
    ) : Nil
      descriptors = [streams.outer_sizes, streams.map_sizes, streams.keys, streams.values]
      descriptors << streams.key_sizes.not_nil! if streams.key_sizes
      descriptors << streams.null_map.not_nil! if streams.null_map
      outer_stream = @streams[streams.outer_sizes.name]
      expected_mark_rows = Array(UInt64).new(mark_count)
      mark_count.times do |range_mark_index|
        expected_mark_rows << outer_stream.marks[first_mark + range_mark_index].rows
      end
      descriptors.each do |descriptor|
        stream = @streams[descriptor.name]
        _, _, stream_rows = checked_stream_mark_range(stream, first_mark, mark_count)
        raise CorruptPartError.new("Array(Map) Bool child mark rows differ") unless stream_rows == rows
        mark_count.times do |range_mark_index|
          unless stream.marks[first_mark + range_mark_index].rows == expected_mark_rows[range_mark_index]
            raise CorruptPartError.new("Array(Map) Bool child mark rows differ")
          end
        end
      end
      validate_array_nested_stream_marks(outer_stream, first_mark, expected_mark_rows, 8)
      nil
    end

    private def array_map_bool_leaf_preflight(
      column : String,
      first_mark : Int,
      mark_count : Int,
      string_keys : Bool,
      nullable_values : Bool,
    ) : ArrayMapBoolLeafPreflight
      ensure_column(column)
      expected_shape = {string_keys ? "String" : "UInt64", nullable_values}
      unless WidePart.array_map_bool_leaf_shape(@column_type) == expected_shape
        key_type = string_keys ? "String" : "UInt64"
        value_type = nullable_values ? "Nullable(Bool)" : "Bool"
        raise UnsupportedFormatError.new("Array(Map) accessor requires exact Array(Map(#{key_type}, #{value_type}))")
      end

      streams = array_map_bool_leaf_streams(column, string_keys, nullable_values)
      outer_sizes, maps, rows, mark_maps = read_array_outer_sizes(column, first_mark, mark_count, streams.outer_sizes.name)
      validate_array_map_bool_leaf_mark_rows(streams, first_mark, mark_count, rows)
      map_sizes, entries, mark_entries = read_array_array_numeric_element_sizes(
        column, first_mark, mark_count, maps, rows, mark_maps, 1, streams.map_sizes.name
      )
      raise CorruptPartError.new("Array(Map) Map offsets do not match outer Array sizes") unless map_sizes.size.to_u64 == maps

      key_sizes = [] of UInt64
      key_bytes = 0_u64
      key_mark_bytes = [] of UInt64
      if string_keys
        key_sizes, key_bytes, key_mark_bytes = read_map_string_child_sizes(
          column, "%2Ekeys", "Array(Map) key", first_mark, mark_count,
          entries, rows, mark_entries, streams.key_sizes.not_nil!.name, streams.keys.name
        )
        raise CorruptPartError.new("Array(Map) key sizes do not match Map offsets") unless key_sizes.size.to_u64 == entries
      else
        key_stream = @streams[streams.keys.name]
        _, _, key_rows = checked_stream_mark_range(key_stream, first_mark, mark_count)
        raise CorruptPartError.new("Array(Map) key mark rows differ") unless key_rows == rows
        validate_array_nested_stream_marks(key_stream, first_mark, mark_entries, 8)
        key_bytes = checked_array_mark_byte_count(entries, 8).to_u64
        key_mark_bytes = mark_entries.map { |count| checked_array_mark_byte_count(count, 8).to_u64 }
      end

      null_map : Bytes? = if nullable_values
        null_stream = @streams[streams.null_map.not_nil!.name]
        null_start, null_end, null_rows = checked_stream_mark_range(null_stream, first_mark, mark_count)
        raise CorruptPartError.new("Array(Map) Nullable mark rows differ") unless null_rows == rows
        validate_array_nested_stream_marks(null_stream, first_mark, mark_entries, 1)
        bytes = read_mark_range_bytes(null_stream, null_start, null_end, checked_array_mark_byte_count(entries, 1), 1)
        bytes.each do |value|
          raise CorruptPartError.new("Array(Map) null-map byte is not boolean") unless value <= 1_u8
        end
        bytes
      else
        nil
      end

      value_stream = @streams[streams.values.name]
      value_start, value_end, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Map) Bool value mark rows differ") unless value_rows == rows
      validate_array_nested_stream_marks(value_stream, first_mark, mark_entries, 1)
      value_bytes = checked_array_mark_byte_count(entries, 1)
      # Read and validate the complete selected value stream before yielding
      # rows; Bool payload interpretation happens only during materialization.
      read_mark_range_bytes(value_stream, value_start, value_end, value_bytes, 1)

      value_mark_bytes = mark_entries.map { |count| checked_array_mark_byte_count(count, 1).to_u64 }
      nullable_bytes = nullable_values ? checked_array_mark_byte_count(entries, 1).to_u64 : 0_u64
      if nullable_values
        value_mark_bytes = value_mark_bytes.each_with_index.map do |mark_value_bytes, index|
          null_bytes = checked_array_mark_byte_count(mark_entries[index], 1).to_u64
          raise CorruptPartError.new("Array(Map) Nullable value mark byte count overflows") if mark_value_bytes > UInt64::MAX - null_bytes
          mark_value_bytes + null_bytes
        end.to_a
      end
      if value_bytes > UInt64::MAX - nullable_bytes
        raise CorruptPartError.new("Array(Map) Nullable value byte count overflows")
      end
      value_bytes_u64 = value_bytes.to_u64
      if value_bytes_u64 > UInt64::MAX - nullable_bytes
        raise CorruptPartError.new("Array(Map) Nullable value byte count overflows")
      end
      payload_bytes = checked_map_materialized_bytes(
        key_bytes, value_bytes_u64 + nullable_bytes, key_mark_bytes, value_mark_bytes
      )
      charge_bytes = checked_array_map_numeric_charge(payload_bytes, maps, entries, rows)
      ArrayMapBoolLeafPreflight.new(
        streams, outer_sizes, map_sizes, key_sizes, rows, maps, entries,
        key_bytes, value_bytes_u64, payload_bytes, charge_bytes, null_map
      )
    end

    private def read_array_map_bool_leaf_nullable_rows(
      column : String,
      first_mark : Int,
      mark_count : Int,
      key_type : K.class,
      nullable_values : Bool = true,
    ) : Array(Array(Array(Tuple(K, Bool?)))) forall K
      string_keys = K == String
      preflight = array_map_bool_leaf_preflight(column, first_mark, mark_count, string_keys, nullable_values)
      key_stream = @streams[preflight.streams.keys.name]
      key_start, key_end, _ = checked_stream_mark_range(key_stream, first_mark, mark_count)
      key_width = string_keys ? 1 : 8
      key_bytes = read_mark_range_bytes(key_stream, key_start, key_end, preflight.key_bytes.to_i, key_width)
      value_stream = @streams[preflight.streams.values.name]
      value_start, value_end, _ = checked_stream_mark_range(value_stream, first_mark, mark_count)
      value_bytes = read_mark_range_bytes(value_stream, value_start, value_end, preflight.value_bytes.to_i, 1)
      null_map = preflight.null_map

      result = Array(Array(Array(Tuple(K, Bool?)))).new(preflight.rows.to_i)
      map_offset = 0
      entry_offset = 0
      key_offset = 0
      preflight.outer_sizes.each do |map_count|
        row = Array(Array(Tuple(K, Bool?))).new(map_count.to_i)
        map_count.to_i.times do
          raise CorruptPartError.new("Array(Map) outer sizes exceed selected Map offsets") if map_offset >= preflight.map_sizes.size
          entry_count = preflight.map_sizes[map_offset].to_i
          map = Array(Tuple(K, Bool?)).new(entry_count)
          entry_count.times do
            raise CorruptPartError.new("Array(Map) Map offsets exceed selected entries") if entry_offset >= preflight.entries
            key = uninitialized K
            {% if K == String %}
              raise CorruptPartError.new("Array(Map) offsets exceed selected key sizes") if entry_offset >= preflight.key_sizes.size
              key_length = preflight.key_sizes[entry_offset].to_i
              if key_offset > key_bytes.size || key_length > key_bytes.size - key_offset
                raise CorruptPartError.new("Array(Map) key sizes exceed selected raw bytes")
              end
              key = String.new(key_bytes[key_offset, key_length])
              key_offset += key_length
            {% else %}
              if entry_offset >= key_bytes.size // 8
                raise CorruptPartError.new("Array(Map) keys exceed selected UInt64 bytes")
              end
              key = u64(key_bytes, entry_offset * 8)
            {% end %}

            value = if null_map && null_map[entry_offset] == 1_u8
                      # ClickHouse retains a nested default Bool byte under
                      # NULL. Preserve W34 behavior: consume the slot but do
                      # not decode or validate the hidden value byte.
                      nil
                    else
                      value_byte = value_bytes[entry_offset]? || raise(CorruptPartError.new("Array(Map) Bool value bytes do not match selected Map entries"))
                      BoolValueCodec.decode(value_byte)
                    end
            map << {key, value}
            entry_offset += 1
          end
          row << map
          map_offset += 1
        end
        result << row
      end
      unless map_offset == preflight.map_sizes.size && entry_offset.to_u64 == preflight.entries
        raise CorruptPartError.new("Array(Map) offsets do not consume selected Map entries")
      end
      raise CorruptPartError.new("Array(Map) key sizes do not consume selected raw bytes") if string_keys && key_offset != key_bytes.size
      raise CorruptPartError.new("Array(Map) key sizes do not consume selected UInt64 bytes") if !string_keys && entry_offset * 8 != key_bytes.size
      raise CorruptPartError.new("Array(Map) value bytes do not match selected Map entries") unless entry_offset == value_bytes.size
      result
    end

    private def read_array_map_bool_leaf_rows(
      column : String,
      first_mark : Int,
      mark_count : Int,
      key_type : K.class,
    ) : Array(Array(Array(Tuple(K, Bool)))) forall K
      nullable_rows = read_array_map_bool_leaf_nullable_rows(column, first_mark, mark_count, key_type, false)
      result = Array(Array(Array(Tuple(K, Bool)))).new(nullable_rows.size)
      nullable_rows.each do |row|
        plain_row = Array(Array(Tuple(K, Bool))).new(row.size)
        row.each do |map|
          plain_map = Array(Tuple(K, Bool)).new(map.size)
          map.each do |key, value|
            plain_map << {
              key,
              value.nil? ? raise(CorruptPartError.new("non-nullable Array(Map) Bool decoded as NULL")) : value.not_nil!,
            }
          end
          plain_row << plain_map
        end
        result << plain_row
      end
      result
    end

    def array_map_bool_leaf_mark_range_materialization_preflight(
      column : String,
      first_mark : Int,
      mark_count : Int,
    ) : {payload_bytes: UInt64, charge_bytes: UInt64}
      string_keys, nullable_values = WidePart.array_map_bool_leaf_shape(@column_type).try do |shape|
        {shape[0] == "String", shape[1]}
      end || raise(UnsupportedFormatError.new("selected column is not an exact W83 Array(Map) Bool leaf"))
      preflight = array_map_bool_leaf_preflight(column, first_mark, mark_count, string_keys, nullable_values)
      {payload_bytes: preflight.payload_bytes, charge_bytes: preflight.charge_bytes}
    end

    def read_array_map_uint64_bool_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
    ) : Array(Array(Array(Tuple(UInt64, Bool))))
      read_array_map_bool_leaf_rows(column, first_mark, mark_count, UInt64)
    end

    def read_array_map_string_bool_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
    ) : Array(Array(Array(Tuple(String, Bool))))
      read_array_map_bool_leaf_rows(column, first_mark, mark_count, String)
    end

    def read_array_map_uint64_nullable_bool_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
    ) : Array(Array(Array(Tuple(UInt64, Bool?))))
      read_array_map_bool_leaf_nullable_rows(column, first_mark, mark_count, UInt64)
    end

    def read_array_map_string_nullable_bool_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
    ) : Array(Array(Array(Tuple(String, Bool?))))
      read_array_map_bool_leaf_nullable_rows(column, first_mark, mark_count, String)
    end

    private def array_map_array_leaf_streams(
      column : String,
      string_keys : Bool,
      value_type : String,
    ) : ArrayMapArrayLeafStreams
      plan = WideTypePlan::WidePhysicalPlanShadow.for_type(@column_type, column) ||
             raise(UnsupportedFormatError.new("no physical plan for exact W84 Array(Map) Array leaf column"))
      descriptors = plan.streams
      string_values = value_type == "String"
      numeric_values = WidePart.supports_numeric_type?(value_type)
      unless string_values || numeric_values
        raise UnsupportedFormatError.new("Array(Map) Array leaf is not an exact supported numeric type")
      end
      expected_count = 5 + (string_keys ? 1 : 0) + (string_values ? 1 : 0)
      raise UnsupportedFormatError.new("unexpected W84 Array(Map) Array leaf physical plan") unless descriptors.size == expected_count

      outer_sizes = descriptors.find do |stream|
        stream.name == "#{column}.size0" && stream.role.array_size0? && stream.semantic_path.empty?
      end || raise(UnsupportedFormatError.new("W84 physical plan omits outer Array offsets"))
      map_sizes = descriptors.find do |stream|
        stream.name == "#{column}.size1" && stream.role.array_size1? && stream.semantic_path.empty?
      end || raise(UnsupportedFormatError.new("W84 physical plan omits Map offsets"))
      keys = descriptors.find do |stream|
        stream.name == "#{column}%2Ekeys" && stream.role.value? && stream.semantic_path == ["keys"]
      end || raise(UnsupportedFormatError.new("W84 physical plan omits Map keys"))
      key_sizes = if string_keys
                    descriptors.find do |stream|
                      stream.name == "#{column}%2Ekeys.size" && stream.role.string_size? && stream.semantic_path == ["keys"]
                    end || raise(UnsupportedFormatError.new("W84 physical plan omits String key sizes"))
                  else
                    nil
                  end
      value_sizes = descriptors.find do |stream|
        stream.name == "#{column}%2Evalues.size2" && stream.role.array_size2? &&
          stream.semantic_path == ["values"]
      end || raise(UnsupportedFormatError.new("W84 physical plan omits the third value offsets"))
      value_string_sizes = if string_values
                             descriptors.find do |stream|
                               stream.name == "#{column}%2Evalues.size" && stream.role.string_size? &&
                                 stream.semantic_path == ["values"]
                             end || raise(UnsupportedFormatError.new("W84 physical plan omits String value sizes"))
                           else
                             nil
                           end
      values = descriptors.find do |stream|
        stream.name == "#{column}%2Evalues" && stream.role.value? && stream.semantic_path == ["values"]
      end || raise(UnsupportedFormatError.new("W84 physical plan omits value data"))

      outer_axis = outer_sizes.cardinality_child_axis || raise(UnsupportedFormatError.new("W84 outer Array omits its element axis"))
      entries_axis = map_sizes.cardinality_child_axis || raise(UnsupportedFormatError.new("W84 Map omits its entry axis"))
      value_axis = value_sizes.cardinality_child_axis || raise(UnsupportedFormatError.new("W84 values.size2 omits its child axis"))
      unless outer_sizes.cardinality_parent_axis.try(&.id) == plan.mark_row_axis.id &&
             outer_axis.kind.array_elements? &&
             map_sizes.cardinality_parent_axis.try(&.id) == outer_axis.id &&
             entries_axis.kind.map_entries? &&
             value_sizes.cardinality_parent_axis.try(&.id) == entries_axis.id &&
             value_axis.kind.array_elements? &&
             value_sizes.semantic_type == "Array(#{value_type})" &&
             value_sizes.storage_mode.counts?
        raise UnsupportedFormatError.new("W84 physical offset axes are inconsistent")
      end

      if string_keys
        key_bytes_axis = key_sizes.not_nil!.cardinality_child_axis ||
                         raise(UnsupportedFormatError.new("W84 String key sizes omit their byte axis"))
        unless key_sizes.not_nil!.cardinality_parent_axis.try(&.id) == entries_axis.id &&
               key_sizes.not_nil!.storage_mode.counts? && key_bytes_axis.kind.string_bytes? &&
               keys.storage_mode.variable_bytes? && keys.storage_axis.id == key_bytes_axis.id
          raise UnsupportedFormatError.new("W84 String key axes are inconsistent")
        end
      else
        unless keys.storage_mode.fixed_width_values? && keys.storage_axis.id == entries_axis.id && keys.element_width == 8
          raise UnsupportedFormatError.new("W84 UInt64 key axis is inconsistent")
        end
      end

      if string_values
        value_bytes_axis = value_string_sizes.not_nil!.cardinality_child_axis ||
                           raise(UnsupportedFormatError.new("W84 String value sizes omit their byte axis"))
        unless value_string_sizes.not_nil!.cardinality_parent_axis.try(&.id) == value_axis.id &&
               value_string_sizes.not_nil!.storage_mode.counts? && value_bytes_axis.kind.string_bytes? &&
               values.storage_mode.variable_bytes? && values.storage_axis.id == value_bytes_axis.id
          raise UnsupportedFormatError.new("W84 String value axes are inconsistent")
        end
      else
        unless numeric_values && values.storage_mode.fixed_width_values? &&
               values.storage_axis.id == value_axis.id &&
               values.element_width == WidePart.numeric_payload_width(value_type)
          raise UnsupportedFormatError.new("Array(Map) numeric value axis is inconsistent")
        end
      end
      unless descriptors.all? { |stream| stream.mark_row_axis.id == plan.mark_row_axis.id }
        raise UnsupportedFormatError.new("W84 physical mark axes are inconsistent")
      end

      ArrayMapArrayLeafStreams.new(outer_sizes, map_sizes, key_sizes, keys, value_sizes, value_string_sizes, values)
    end

    private def validate_array_map_array_leaf_mark_rows(
      streams : ArrayMapArrayLeafStreams,
      first_mark : Int,
      mark_count : Int,
      rows : UInt64,
    ) : Nil
      descriptors = [streams.outer_sizes, streams.map_sizes, streams.keys, streams.value_sizes, streams.values]
      descriptors << streams.key_sizes.not_nil! if streams.key_sizes
      descriptors << streams.value_string_sizes.not_nil! if streams.value_string_sizes
      outer_stream = @streams[streams.outer_sizes.name]
      expected_mark_rows = Array(UInt64).new(mark_count)
      mark_count.times do |range_mark_index|
        expected_mark_rows << outer_stream.marks[first_mark + range_mark_index].rows
      end
      descriptors.each do |descriptor|
        stream = @streams[descriptor.name]
        _, _, stream_rows = checked_stream_mark_range(stream, first_mark, mark_count)
        raise CorruptPartError.new("W84 child mark rows differ") unless stream_rows == rows
        mark_count.times do |range_mark_index|
          unless stream.marks[first_mark + range_mark_index].rows == expected_mark_rows[range_mark_index]
            raise CorruptPartError.new("W84 child mark rows differ")
          end
        end
      end
      # size0 is both the logical root row count and the source of each
      # selected mark's outer-array cardinality. Validate it before trusting
      # any descendant offsets.
      validate_array_nested_stream_marks(outer_stream, first_mark, expected_mark_rows, 8)
      nil
    end

    private def checked_array_map_array_leaf_charge(
      payload_bytes : UInt64,
      rows : UInt64,
      maps : UInt64,
      entries : UInt64,
      values : UInt64,
      string_keys : Bool,
      string_values : Bool,
    ) : UInt64
      # Include retained nested Array objects, tuple slots, String object
      # slots, and the decoded offset/length arrays in addition to stream
      # payloads. This is a bounded admission charge, not exact heap sizing.
      row_width = ARRAY_MAP_ROW_ACCOUNTING_BYTES + 8_u64
      map_width = ARRAY_MAP_CONTAINER_ACCOUNTING_BYTES + 8_u64
      entry_width = ARRAY_TUPLE_ENTRY_ACCOUNTING_BYTES + MAP_ARRAY_UINT64_CONTAINER_ACCOUNTING_BYTES + 8_u64
      value_width = string_values ? ARRAY_NULLABLE_STRING_SLOT_ACCOUNTING_BYTES + 8_u64 : 0_u64
      entry_width += ARRAY_NULLABLE_STRING_SLOT_ACCOUNTING_BYTES + 8_u64 if string_keys
      if rows > UInt64::MAX // row_width || maps > UInt64::MAX // map_width ||
         entries > UInt64::MAX // entry_width || (value_width > 0 && values > UInt64::MAX // value_width)
        raise CorruptPartError.new("W84 materialization charge overflows")
      end
      row_bytes = rows * row_width
      map_bytes = maps * map_width
      entry_bytes = entries * entry_width
      value_slot_bytes = values * value_width
      if map_bytes > UInt64::MAX - row_bytes || entry_bytes > UInt64::MAX - row_bytes - map_bytes ||
         value_slot_bytes > UInt64::MAX - row_bytes - map_bytes - entry_bytes ||
         payload_bytes > UInt64::MAX - row_bytes - map_bytes - entry_bytes - value_slot_bytes
        raise CorruptPartError.new("W84 materialization charge overflows")
      end
      charge_bytes = row_bytes + map_bytes + entry_bytes + value_slot_bytes + payload_bytes
      raise CorruptPartError.new("W84 materialization charge exceeds per-range limit") if charge_bytes > MAX_ARRAY_MARK_BYTES.to_u64
      charge_bytes
    end

    private def array_map_array_leaf_preflight(
      column : String,
      first_mark : Int,
      mark_count : Int,
      key_type : String,
      value_type : String,
    ) : ArrayMapArrayLeafPreflight
      ensure_column(column)
      expected_shape = {key_type, value_type}
      unless WidePart.array_map_array_leaf_shape(@column_type) == expected_shape
        raise UnsupportedFormatError.new("Array(Map) reader requires an exact W84 String or W85 numeric Array(Map(K, Array(V))) declaration")
      end

      string_keys = key_type == "String"
      string_values = value_type == "String"
      streams = array_map_array_leaf_streams(column, string_keys, value_type)
      outer_sizes, maps, rows, mark_maps = read_array_outer_sizes(column, first_mark, mark_count, streams.outer_sizes.name)
      validate_array_map_array_leaf_mark_rows(streams, first_mark, mark_count, rows)

      map_sizes, entries, mark_entries = read_array_array_numeric_element_sizes(
        column, first_mark, mark_count, maps, rows, mark_maps, 8, streams.map_sizes.name
      )
      raise CorruptPartError.new("W84 Map offsets do not match outer Array sizes") unless map_sizes.size.to_u64 == maps

      element_width = string_values ? 1 : WidePart.numeric_payload_width(value_type)
      value_sizes, values_count, mark_values = read_array_array_numeric_element_sizes(
        column, first_mark, mark_count, entries, rows, mark_entries, element_width, streams.value_sizes.name
      )
      raise CorruptPartError.new("W84 values.size2 does not match Map entries") unless value_sizes.size.to_u64 == entries

      key_sizes = [] of UInt64
      key_bytes = 0_u64
      key_mark_bytes = [] of UInt64
      if string_keys
        key_sizes, key_bytes, key_mark_bytes = read_map_string_child_sizes(
          column, "%2Ekeys", "W84 key", first_mark, mark_count,
          entries, rows, mark_entries, streams.key_sizes.not_nil!.name, streams.keys.name
        )
        raise CorruptPartError.new("W84 key sizes do not match Map offsets") unless key_sizes.size.to_u64 == entries
      else
        key_stream = @streams[streams.keys.name]
        _, _, key_rows = checked_stream_mark_range(key_stream, first_mark, mark_count)
        raise CorruptPartError.new("W84 key mark rows differ") unless key_rows == rows
        validate_array_nested_stream_marks(key_stream, first_mark, mark_entries, 8)
        key_bytes = checked_array_mark_byte_count(entries, 8).to_u64
        key_mark_bytes = mark_entries.map { |count| checked_array_mark_byte_count(count, 8).to_u64 }
      end

      value_string_sizes = [] of UInt64
      value_bytes = 0_u64
      value_mark_bytes = [] of UInt64
      if string_values
        value_string_sizes, value_bytes, value_mark_bytes = read_map_string_child_sizes(
          column, "%2Evalues", "W84 value", first_mark, mark_count,
          values_count, rows, mark_values, streams.value_string_sizes.not_nil!.name, streams.values.name
        )
        raise CorruptPartError.new("W84 String sizes do not match values.size2") unless value_string_sizes.size.to_u64 == values_count
      else
        value_stream = @streams[streams.values.name]
        _, _, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
        raise CorruptPartError.new("W84 value mark rows differ") unless value_rows == rows
        value_width = WidePart.numeric_payload_width(value_type)
        validate_array_nested_stream_marks(value_stream, first_mark, mark_values, value_width)
        value_bytes = checked_array_mark_byte_count(values_count, value_width).to_u64
        value_mark_bytes = mark_values.map { |count| checked_array_mark_byte_count(count, value_width).to_u64 }
      end

      payload_bytes = checked_map_materialized_bytes(key_bytes, value_bytes, key_mark_bytes, value_mark_bytes)
      charge_bytes = checked_array_map_array_leaf_charge(
        payload_bytes, rows, maps, entries, values_count, string_keys, string_values
      )
      ArrayMapArrayLeafPreflight.new(
        streams, outer_sizes, map_sizes, value_sizes, key_sizes, value_string_sizes,
        mark_maps, mark_entries, mark_values, rows, maps, entries, values_count,
        key_bytes, value_bytes, payload_bytes, charge_bytes
      )
    end

    private def read_array_map_array_leaf_rows(
      column : String,
      first_mark : Int,
      mark_count : Int,
      key_type : K.class,
      value_type : V.class,
    ) : Array(Array(Array(Tuple(K, Array(V))))) forall K, V
      expected_key_type = {% if K == String %} "String" {% else %} "UInt64" {% end %}
      expected_value_type = {% if V == String %} "String" {% else %} WidePart.numeric_type_name(V) {% end %}
      preflight = array_map_array_leaf_preflight(
        column, first_mark, mark_count, expected_key_type, expected_value_type
      )
      keys_stream = @streams[preflight.streams.keys.name]
      keys_start, keys_end, _ = checked_stream_mark_range(keys_stream, first_mark, mark_count)
      key_width = expected_key_type == "String" ? 1 : 8
      key_bytes = read_mark_range_bytes(keys_stream, keys_start, keys_end, preflight.key_bytes.to_i, key_width)
      values_stream = @streams[preflight.streams.values.name]
      values_start, values_end, _ = checked_stream_mark_range(values_stream, first_mark, mark_count)
      value_width = expected_value_type == "String" ? 1 : WidePart.numeric_payload_width(expected_value_type)
      value_bytes = read_mark_range_bytes(values_stream, values_start, values_end, preflight.value_bytes.to_i, value_width)

      result = Array(Array(Array(Tuple(K, Array(V))))).new(preflight.rows.to_i)
      map_offset = 0
      entry_offset = 0
      leaf_offset = 0
      key_offset = 0
      value_offset = 0
      preflight.outer_sizes.each do |map_count|
        row = Array(Array(Tuple(K, Array(V)))).new(map_count.to_i)
        map_count.to_i.times do
          raise CorruptPartError.new("W84 outer sizes exceed selected Map offsets") if map_offset >= preflight.map_sizes.size
          entry_count = preflight.map_sizes[map_offset].to_i
          map = Array(Tuple(K, Array(V))).new(entry_count)
          entry_count.times do
            key = uninitialized K
            {% if K == String %}
              raise CorruptPartError.new("W84 offsets exceed selected key sizes") if entry_offset >= preflight.key_sizes.size
              key_length = preflight.key_sizes[entry_offset].to_i
              if key_offset > key_bytes.size || key_length > key_bytes.size - key_offset
                raise CorruptPartError.new("W84 key sizes exceed selected raw bytes")
              end
              key = String.new(key_bytes[key_offset, key_length])
              key_offset += key_length
            {% else %}
              if entry_offset >= key_bytes.size // 8
                raise CorruptPartError.new("W84 keys exceed selected UInt64 bytes")
              end
              key = u64(key_bytes, entry_offset * 8)
            {% end %}

            raise CorruptPartError.new("W84 Map offsets exceed selected values.size2") if entry_offset >= preflight.value_sizes.size
            value_count = preflight.value_sizes[entry_offset].to_i
            value_array = Array(V).new(value_count)
            value_count.times do
              value = uninitialized V
              {% if V == String %}
                raise CorruptPartError.new("W84 values.size2 exceeds selected String sizes") if leaf_offset >= preflight.value_string_sizes.size
                value_length = preflight.value_string_sizes[leaf_offset].to_i
                if value_offset > value_bytes.size || value_length > value_bytes.size - value_offset
                  raise CorruptPartError.new("W84 String sizes exceed selected raw bytes")
                end
                value = String.new(value_bytes[value_offset, value_length])
                value_offset += value_length
              {% else %}
                if leaf_offset >= value_bytes.size // value_width
                  raise CorruptPartError.new("Array(Map) values.size2 exceeds selected numeric bytes")
                end
                value = decode_numeric_value(value_bytes, leaf_offset * value_width, V)
              {% end %}
              value_array << value
              leaf_offset += 1
            end
            map << {key, value_array}
            entry_offset += 1
          end
          row << map
          map_offset += 1
        end
        result << row
      end
      unless map_offset == preflight.map_sizes.size && entry_offset.to_u64 == preflight.entries &&
             leaf_offset.to_u64 == preflight.values_count
        raise CorruptPartError.new("W84 offsets do not consume selected nested values")
      end
      raise CorruptPartError.new("W84 key sizes do not consume selected raw bytes") if expected_key_type == "String" && key_offset != key_bytes.size
      raise CorruptPartError.new("W84 key sizes do not consume selected UInt64 bytes") if expected_key_type == "UInt64" && entry_offset * 8 != key_bytes.size
      raise CorruptPartError.new("W84 String sizes do not consume selected raw bytes") if expected_value_type == "String" && value_offset != value_bytes.size
      raise CorruptPartError.new("Array(Map) sizes do not consume selected numeric bytes") if expected_value_type != "String" && leaf_offset * value_width != value_bytes.size
      result
    end

    def array_map_array_leaf_mark_range_materialization_preflight(
      column : String,
      first_mark : Int,
      mark_count : Int,
    ) : {payload_bytes: UInt64, charge_bytes: UInt64}
      key_type, value_type = WidePart.array_map_array_leaf_shape(@column_type) ||
                             raise(UnsupportedFormatError.new("selected column is not an exact W84 Array(Map) Array leaf"))
      preflight = array_map_array_leaf_preflight(column, first_mark, mark_count, key_type, value_type)
      {payload_bytes: preflight.payload_bytes, charge_bytes: preflight.charge_bytes}
    end

    def read_array_map_uint64_array_uint64_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
    ) : Array(Array(Array(Tuple(UInt64, Array(UInt64)))))
      read_array_map_array_leaf_rows(column, first_mark, mark_count, UInt64, UInt64)
    end

    def read_array_map_uint64_array_string_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
    ) : Array(Array(Array(Tuple(UInt64, Array(String)))))
      read_array_map_array_leaf_rows(column, first_mark, mark_count, UInt64, String)
    end

    def read_array_map_string_array_uint64_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
    ) : Array(Array(Array(Tuple(String, Array(UInt64)))))
      read_array_map_array_leaf_rows(column, first_mark, mark_count, String, UInt64)
    end

    def read_array_map_string_array_string_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
    ) : Array(Array(Array(Tuple(String, Array(String)))))
      read_array_map_array_leaf_rows(column, first_mark, mark_count, String, String)
    end

    def read_array_map_uint64_array_numeric_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
      type : T.class,
    ) : Array(Array(Array(Tuple(UInt64, Array(T))))) forall T
      read_array_map_array_leaf_rows(column, first_mark, mark_count, UInt64, type)
    end

    def read_array_map_string_array_numeric_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
      type : T.class,
    ) : Array(Array(Array(Tuple(String, Array(T))))) forall T
      read_array_map_array_leaf_rows(column, first_mark, mark_count, String, type)
    end

    # W81 shares the W80 offset topology while selecting the exact leaf codec
    # from the declaration. Every selected mark is preflighted before any
    # nested Array or Map object is created.
    def array_map_uint64_numeric_mark_range_materialization_preflight(
      column : String,
      first_mark : Int,
      mark_count : Int,
      type : T.class,
    ) : {UInt64, UInt64} forall T
      expected_type = WidePart.numeric_type_name(type)
      preflight = array_map_numeric_preflight(column, first_mark, mark_count, expected_type, false, false)
      {preflight.payload_bytes, preflight.charge_bytes}
    end

    def array_map_string_numeric_mark_range_materialization_preflight(
      column : String,
      first_mark : Int,
      mark_count : Int,
      type : T.class,
    ) : {UInt64, UInt64} forall T
      expected_type = WidePart.numeric_type_name(type)
      preflight = array_map_numeric_preflight(column, first_mark, mark_count, expected_type, true, false)
      {preflight.payload_bytes, preflight.charge_bytes}
    end

    def array_map_uint64_nullable_numeric_mark_range_materialization_preflight(
      column : String,
      first_mark : Int,
      mark_count : Int,
      type : T.class,
    ) : {UInt64, UInt64} forall T
      expected_type = WidePart.numeric_type_name(type)
      preflight = array_map_numeric_preflight(column, first_mark, mark_count, expected_type, false, true)
      {preflight.payload_bytes, preflight.charge_bytes}
    end

    def array_map_string_nullable_numeric_mark_range_materialization_preflight(
      column : String,
      first_mark : Int,
      mark_count : Int,
      type : T.class,
    ) : {UInt64, UInt64} forall T
      expected_type = WidePart.numeric_type_name(type)
      preflight = array_map_numeric_preflight(column, first_mark, mark_count, expected_type, true, true)
      {preflight.payload_bytes, preflight.charge_bytes}
    end

    def read_array_map_uint64_numeric_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
      type : T.class,
    ) : Array(Array(Array(Tuple(UInt64, T)))) forall T
      read_array_map_numeric_mark_range_impl(column, first_mark, mark_count, type, UInt64)
    end

    def read_array_map_string_numeric_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
      type : T.class,
    ) : Array(Array(Array(Tuple(String, T)))) forall T
      read_array_map_numeric_mark_range_impl(column, first_mark, mark_count, type, String)
    end

    def read_array_map_uint64_nullable_numeric_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
      type : T.class,
    ) : Array(Array(Array(Tuple(UInt64, T?)))) forall T
      read_array_map_nullable_numeric_mark_range_impl(column, first_mark, mark_count, type, UInt64)
    end

    def read_array_map_string_nullable_numeric_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
      type : T.class,
    ) : Array(Array(Array(Tuple(String, T?)))) forall T
      read_array_map_nullable_numeric_mark_range_impl(column, first_mark, mark_count, type, String)
    end

    private def array_map_numeric_streams(
      column : String,
      string_keys : Bool,
      nullable_values : Bool,
    ) : ArrayMapNumericStreams
      plan = WideTypePlan::WidePhysicalPlanShadow.for_type(@column_type, column) ||
             raise UnsupportedFormatError.new("no physical plan for exact Array(Map) numeric column")
      descriptors = plan.streams
      expected_count = 4 + (string_keys ? 1 : 0) + (nullable_values ? 1 : 0)
      raise UnsupportedFormatError.new("unexpected Array(Map) numeric physical plan") unless descriptors.size == expected_count

      outer_sizes = descriptors.find do |stream|
        stream.name == "#{column}.size0" && stream.role.array_size0? && stream.semantic_path.empty?
      end || raise UnsupportedFormatError.new("physical plan omits the outer Array offsets")
      map_sizes = descriptors.find do |stream|
        stream.name == "#{column}.size1" && stream.role.array_size1? && stream.semantic_path.empty?
      end || raise UnsupportedFormatError.new("physical plan omits the inner Map offsets")
      keys = descriptors.find do |stream|
        stream.name == "#{column}%2Ekeys" && stream.role.value? && stream.semantic_path == ["keys"]
      end || raise UnsupportedFormatError.new("physical plan omits Map keys")
      values = descriptors.find do |stream|
        stream.name == "#{column}%2Evalues" && stream.role.value? && stream.semantic_path == ["values"]
      end || raise UnsupportedFormatError.new("physical plan omits Map values")
      key_sizes = if string_keys
                    descriptors.find do |stream|
                      stream.name == "#{column}%2Ekeys.size" && stream.role.string_size? && stream.semantic_path == ["keys"]
                    end || raise UnsupportedFormatError.new("physical plan omits String key sizes")
                  else
                    nil
                  end
      null_map = if nullable_values
                   descriptors.find do |stream|
                     stream.name == "#{column}%2Evalues.null" && stream.role.null_map? && stream.semantic_path == ["values"]
                   end || raise UnsupportedFormatError.new("physical plan omits the Nullable value map")
                 else
                   nil
                 end

      array_axis = outer_sizes.cardinality_child_axis || raise UnsupportedFormatError.new("outer Array plan omits its element axis")
      entries_axis = map_sizes.cardinality_child_axis || raise UnsupportedFormatError.new("Map plan omits its entry axis")
      unless outer_sizes.cardinality_parent_axis.try(&.id) == plan.mark_row_axis.id &&
             array_axis.kind.array_elements? &&
             map_sizes.cardinality_parent_axis.try(&.id) == array_axis.id &&
             entries_axis.kind.map_entries? &&
             (string_keys || keys.storage_axis.id == entries_axis.id) &&
             values.storage_axis.id == entries_axis.id
        raise UnsupportedFormatError.new("Array(Map) numeric physical axes are inconsistent")
      end
      if key_sizes
        key_bytes_axis = key_sizes.cardinality_child_axis || raise UnsupportedFormatError.new("String key plan omits its byte axis")
        unless key_sizes.cardinality_parent_axis.try(&.id) == entries_axis.id &&
               key_bytes_axis.kind.string_bytes? && keys.storage_axis.id == key_bytes_axis.id
          raise UnsupportedFormatError.new("Array(Map) String key axes are inconsistent")
        end
      end
      if null_map && null_map.storage_axis.id != entries_axis.id
        raise UnsupportedFormatError.new("Array(Map) Nullable value axis is inconsistent")
      end
      unless descriptors.all? { |stream| stream.mark_row_axis.id == plan.mark_row_axis.id }
        raise UnsupportedFormatError.new("Array(Map) numeric physical mark axis is inconsistent")
      end

      ArrayMapNumericStreams.new(outer_sizes, map_sizes, key_sizes, keys, null_map, values)
    end

    private def validate_array_map_numeric_mark_rows(
      streams : ArrayMapNumericStreams,
      first_mark : Int,
      mark_count : Int,
      rows : UInt64,
    ) : Nil
      descriptors = [streams.outer_sizes, streams.map_sizes, streams.keys, streams.values]
      descriptors << streams.key_sizes.not_nil! if streams.key_sizes
      descriptors << streams.null_map.not_nil! if streams.null_map
      outer_stream = @streams[streams.outer_sizes.name]
      outer_mark_rows = Array(UInt64).new(mark_count)
      mark_count.times do |range_mark_index|
        mark_index = first_mark + range_mark_index
        outer_mark_rows << outer_stream.marks[mark_index].rows
      end
      validate_array_nested_stream_marks(outer_stream, first_mark, outer_mark_rows, 8)

      descriptors.each do |descriptor|
        stream = @streams[descriptor.name]
        _, _, stream_rows = checked_stream_mark_range(stream, first_mark, mark_count)
        raise CorruptPartError.new("Array(Map) numeric child mark rows differ") unless stream_rows == rows
        mark_count.times do |range_mark_index|
          mark_index = first_mark + range_mark_index
          unless stream.marks[mark_index].rows == outer_mark_rows[range_mark_index]
            raise CorruptPartError.new("Array(Map) numeric child mark rows differ")
          end
        end
      end
      nil
    end

    private def checked_array_map_numeric_charge(
      payload_bytes : UInt64,
      maps : UInt64,
      entries : UInt64,
      rows : UInt64,
    ) : UInt64
      row_width = ARRAY_MAP_ROW_ACCOUNTING_BYTES
      map_width = ARRAY_MAP_CONTAINER_ACCOUNTING_BYTES
      entry_width = ARRAY_TUPLE_ENTRY_ACCOUNTING_BYTES
      if rows > UInt64::MAX // row_width || maps > UInt64::MAX // map_width || entries > UInt64::MAX // entry_width
        raise CorruptPartError.new("Array(Map) numeric materialization charge overflows")
      end
      row_bytes = rows * row_width
      map_bytes = maps * map_width
      entry_bytes = entries * entry_width
      if map_bytes > UInt64::MAX - row_bytes || entry_bytes > UInt64::MAX - row_bytes - map_bytes ||
         payload_bytes > UInt64::MAX - row_bytes - map_bytes - entry_bytes
        raise CorruptPartError.new("Array(Map) numeric materialization charge overflows")
      end
      charge_bytes = row_bytes + map_bytes + entry_bytes + payload_bytes
      raise CorruptPartError.new("Array(Map) numeric materialization charge exceeds per-range limit") if charge_bytes > MAX_ARRAY_MARK_BYTES.to_u64
      charge_bytes
    end

    private def array_map_numeric_preflight(
      column : String,
      first_mark : Int,
      mark_count : Int,
      expected_type : String,
      string_keys : Bool,
      nullable_values : Bool,
    ) : ArrayMapNumericPreflight
      ensure_column(column)
      declared_type = if string_keys
                        nullable_values ? WidePart.array_map_string_nullable_numeric_value_type(@column_type) : WidePart.array_map_string_numeric_value_type(@column_type)
                      else
                        nullable_values ? WidePart.array_map_uint64_nullable_numeric_value_type(@column_type) : WidePart.array_map_uint64_numeric_value_type(@column_type)
                      end
      unless declared_type == expected_type
        key_type = string_keys ? "String" : "UInt64"
        value_shape = nullable_values ? "Nullable(T)" : "T"
        raise UnsupportedFormatError.new("Array(Map) accessor requires an exact Array(Map(#{key_type}, #{value_shape})) declaration matching its T")
      end

      streams = array_map_numeric_streams(column, string_keys, nullable_values)
      outer_sizes, maps, rows, mark_maps = read_array_outer_sizes(column, first_mark, mark_count, streams.outer_sizes.name)
      validate_array_map_numeric_mark_rows(streams, first_mark, mark_count, rows)
      map_sizes, entries, mark_entries = read_array_array_numeric_element_sizes(
        column, first_mark, mark_count, maps, rows, mark_maps,
        WidePart.numeric_payload_width(expected_type), streams.map_sizes.name
      )
      raise CorruptPartError.new("Array(Map) Map offsets do not match outer Array sizes") unless map_sizes.size.to_u64 == maps

      key_sizes = [] of UInt64
      key_bytes = 0_u64
      key_mark_bytes = [] of UInt64
      if string_keys
        key_sizes, key_bytes, key_mark_bytes = read_map_string_child_sizes(
          column, "%2Ekeys", "Array(Map) key", first_mark, mark_count,
          entries, rows, mark_entries,
          streams.key_sizes.not_nil!.name, streams.keys.name
        )
        raise CorruptPartError.new("Array(Map) key sizes do not match Map offsets") unless key_sizes.size.to_u64 == entries
      else
        key_stream = @streams[streams.keys.name]
        _, _, key_rows = checked_stream_mark_range(key_stream, first_mark, mark_count)
        raise CorruptPartError.new("Array(Map) key mark rows differ") unless key_rows == rows
        validate_array_nested_stream_marks(key_stream, first_mark, mark_entries, 8)
        key_bytes = checked_array_mark_byte_count(entries, 8).to_u64
        key_mark_bytes = mark_entries.map { |count| checked_array_mark_byte_count(count, 8).to_u64 }
      end

      width = WidePart.numeric_payload_width(expected_type)
      values_stream = @streams[streams.values.name]
      _, _, value_rows = checked_stream_mark_range(values_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Map) value mark rows differ") unless value_rows == rows
      validate_array_nested_stream_marks(values_stream, first_mark, mark_entries, width)
      value_bytes = checked_array_mark_byte_count(entries, width).to_u64
      value_mark_bytes = mark_entries.map { |count| checked_array_mark_byte_count(count, width).to_u64 }
      null_map = if nullable_values
                   null_stream = @streams[streams.null_map.not_nil!.name]
                   _, _, null_rows = checked_stream_mark_range(null_stream, first_mark, mark_count)
                   raise CorruptPartError.new("Array(Map) Nullable mark rows differ") unless null_rows == rows
                   validate_array_nested_stream_marks(null_stream, first_mark, mark_entries, 1)
                   null_start, null_end, _ = checked_stream_mark_range(null_stream, first_mark, mark_count)
                   bytes = read_mark_range_bytes(null_stream, null_start, null_end, checked_array_mark_byte_count(entries, 1), 1)
                   bytes.each do |value|
                     raise CorruptPartError.new("Array(Map) null-map byte is not boolean") unless value <= 1_u8
                   end
                   bytes
                 else
                   nil
                 end
      combined_value_bytes = checked_array_mark_byte_count(entries, width + (nullable_values ? 1 : 0)).to_u64
      combined_value_mark_bytes = mark_entries.map do |count|
        checked_array_mark_byte_count(count, width + (nullable_values ? 1 : 0)).to_u64
      end
      value_with_null_mark_bytes = combined_value_mark_bytes
      payload_bytes = checked_map_materialized_bytes(
        key_bytes,
        combined_value_bytes,
        key_mark_bytes,
        value_with_null_mark_bytes
      )
      charge_bytes = checked_array_map_numeric_charge(payload_bytes, maps, entries, rows)
      ArrayMapNumericPreflight.new(
        streams, outer_sizes, map_sizes, key_sizes, rows, maps, entries,
        key_bytes, value_bytes, payload_bytes, charge_bytes, null_map
      )
    end

    private def read_array_map_numeric_mark_range_impl(
      column : String,
      first_mark : Int,
      mark_count : Int,
      type : T.class,
      key_type : K.class,
    ) : Array(Array(Array(Tuple(K, T)))) forall K, T
      string_keys = K == String
      expected_type = WidePart.numeric_type_name(type)
      preflight = array_map_numeric_preflight(column, first_mark, mark_count, expected_type, string_keys, false)
      keys_stream = @streams[preflight.streams.keys.name]
      keys_start, keys_end, _ = checked_stream_mark_range(keys_stream, first_mark, mark_count)
      key_width = string_keys ? 1 : 8
      key_bytes = read_mark_range_bytes(keys_stream, keys_start, keys_end, preflight.key_bytes.to_i, key_width)
      values_stream = @streams[preflight.streams.values.name]
      values_start, values_end, _ = checked_stream_mark_range(values_stream, first_mark, mark_count)
      width = WidePart.numeric_payload_width(expected_type)
      value_bytes = read_mark_range_bytes(values_stream, values_start, values_end, preflight.value_bytes.to_i, width)

      result = Array(Array(Array(Tuple(K, T)))).new(preflight.rows.to_i)
      map_offset = 0
      entry_offset = 0
      key_offset = 0
      value_offset = 0
      preflight.outer_sizes.each do |map_count|
        row = Array(Array(Tuple(K, T))).new(map_count.to_i)
        map_count.to_i.times do
          raise CorruptPartError.new("Array(Map) outer sizes exceed selected Map offsets") if map_offset >= preflight.map_sizes.size
          entry_count = preflight.map_sizes[map_offset].to_i
          map = Array(Tuple(K, T)).new(entry_count)
          entry_count.times do
            key = uninitialized K
            {% if K == String %}
              raise CorruptPartError.new("Array(Map) offsets exceed selected key sizes") if entry_offset >= preflight.key_sizes.size
              key_length = preflight.key_sizes[entry_offset].to_i
              if key_offset > key_bytes.size || key_length > key_bytes.size - key_offset
                raise CorruptPartError.new("Array(Map) key sizes exceed selected raw bytes")
              end
              key = String.new(key_bytes[key_offset, key_length])
              key_offset += key_length
            {% else %}
              if entry_offset > key_bytes.size // 8 - 1
                raise CorruptPartError.new("Array(Map) keys exceed selected UInt64 bytes")
              end
              key = u64(key_bytes, entry_offset * 8)
            {% end %}
            if value_offset > value_bytes.size - width
              raise CorruptPartError.new("Array(Map) values exceed selected payload bytes")
            end
            map << {key, decode_numeric_value(value_bytes, value_offset, type)}
            value_offset += width
            entry_offset += 1
          end
          row << map
          map_offset += 1
        end
        result << row
      end
      unless map_offset == preflight.map_sizes.size && entry_offset.to_u64 == preflight.entries
        raise CorruptPartError.new("Array(Map) offsets do not consume selected Map entries")
      end
      raise CorruptPartError.new("Array(Map) key sizes do not consume selected raw bytes") if string_keys && key_offset != key_bytes.size
      raise CorruptPartError.new("Array(Map) key sizes do not consume selected UInt64 bytes") if !string_keys && entry_offset * 8 != key_bytes.size
      raise CorruptPartError.new("Array(Map) sizes do not consume selected value bytes") unless value_offset == value_bytes.size
      result
    end

    private def read_array_map_nullable_numeric_mark_range_impl(
      column : String,
      first_mark : Int,
      mark_count : Int,
      type : T.class,
      key_type : K.class,
    ) : Array(Array(Array(Tuple(K, T?)))) forall K, T
      string_keys = K == String
      expected_type = WidePart.numeric_type_name(type)
      preflight = array_map_numeric_preflight(column, first_mark, mark_count, expected_type, string_keys, true)
      keys_stream = @streams[preflight.streams.keys.name]
      keys_start, keys_end, _ = checked_stream_mark_range(keys_stream, first_mark, mark_count)
      key_width = string_keys ? 1 : 8
      key_bytes = read_mark_range_bytes(keys_stream, keys_start, keys_end, preflight.key_bytes.to_i, key_width)
      null_map = preflight.null_map || raise(CorruptPartError.new("Array(Map) Nullable values were not preflighted"))
      values_stream = @streams[preflight.streams.values.name]
      values_start, values_end, _ = checked_stream_mark_range(values_stream, first_mark, mark_count)
      width = WidePart.numeric_payload_width(expected_type)
      value_bytes = read_mark_range_bytes(values_stream, values_start, values_end, preflight.value_bytes.to_i, width)

      result = Array(Array(Array(Tuple(K, T?)))).new(preflight.rows.to_i)
      map_offset = 0
      entry_offset = 0
      key_offset = 0
      value_offset = 0
      preflight.outer_sizes.each do |map_count|
        row = Array(Array(Tuple(K, T?))).new(map_count.to_i)
        map_count.to_i.times do
          raise CorruptPartError.new("Array(Map) outer sizes exceed selected Map offsets") if map_offset >= preflight.map_sizes.size
          entry_count = preflight.map_sizes[map_offset].to_i
          map = Array(Tuple(K, T?)).new(entry_count)
          entry_count.times do
            key = uninitialized K
            {% if K == String %}
              raise CorruptPartError.new("Array(Map) offsets exceed selected key sizes") if entry_offset >= preflight.key_sizes.size
              key_length = preflight.key_sizes[entry_offset].to_i
              if key_offset > key_bytes.size || key_length > key_bytes.size - key_offset
                raise CorruptPartError.new("Array(Map) key sizes exceed selected raw bytes")
              end
              key = String.new(key_bytes[key_offset, key_length])
              key_offset += key_length
            {% else %}
              if entry_offset > key_bytes.size // 8 - 1
                raise CorruptPartError.new("Array(Map) keys exceed selected UInt64 bytes")
              end
              key = u64(key_bytes, entry_offset * 8)
            {% end %}
            if value_offset > value_bytes.size - width
              raise CorruptPartError.new("Array(Map) values exceed selected payload bytes")
            end
            value : T? = null_map[entry_offset] == 1 ? nil : decode_numeric_value(value_bytes, value_offset, type)
            map << {key, value}
            value_offset += width
            entry_offset += 1
          end
          row << map
          map_offset += 1
        end
        result << row
      end
      unless map_offset == preflight.map_sizes.size && entry_offset.to_u64 == preflight.entries
        raise CorruptPartError.new("Array(Map) offsets do not consume selected Map entries")
      end
      raise CorruptPartError.new("Array(Map) key sizes do not consume selected raw bytes") if string_keys && key_offset != key_bytes.size
      raise CorruptPartError.new("Array(Map) key sizes do not consume selected UInt64 bytes") if !string_keys && entry_offset * 8 != key_bytes.size
      raise CorruptPartError.new("Array(Map) sizes do not consume selected nullable numeric values") unless value_offset == value_bytes.size
      result
    end

    private def numeric_map_preflight(
      column : String,
      first_mark : Int,
      mark_count : Int,
      expected_type : String,
      string_keys : Bool,
      nullable_values : Bool = false,
    ) : NumericMapPreflight
      ensure_column(column)
      declared_value_type = if string_keys
                              nullable_values ? WidePart.map_string_nullable_numeric_value_type(@column_type) : WidePart.map_string_numeric_value_type(@column_type)
                            else
                              nullable_values ? WidePart.map_uint64_nullable_numeric_value_type(@column_type) : WidePart.map_uint64_numeric_value_type(@column_type)
                            end
      unless declared_value_type == expected_type
        value_shape = nullable_values ? "Nullable(T)" : "T"
        key_shape = string_keys ? "Map(String, #{value_shape})" : "Map(UInt64, #{value_shape})"
        raise UnsupportedFormatError.new("numeric Map accessor requires an exact #{key_shape} declaration matching its T")
      end

      outer_sizes, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(column, first_mark, mark_count)
      validate_numeric_map_size0_and_child_rows(column, first_mark, mark_count)

      key_sizes = [] of UInt64
      key_payload_bytes = 0_u64
      key_mark_bytes = [] of UInt64
      if string_keys
        key_sizes, key_payload_bytes, key_mark_bytes = read_map_string_child_sizes(
          column, "%2Ekeys", "Map key", first_mark, mark_count, flat_elements, rows, mark_flat_elements
        )
        raise CorruptPartError.new("Map key size count differs from size0") unless key_sizes.size.to_u64 == flat_elements
      else
        keys_stream = @streams["#{column}%2Ekeys"]
        _, _, key_rows = checked_stream_mark_range(keys_stream, first_mark, mark_count)
        raise CorruptPartError.new("Map key substream mark rows differ") unless key_rows == rows
        validate_array_nested_stream_marks(keys_stream, first_mark, mark_flat_elements, 8)
        key_payload_bytes = checked_array_mark_byte_count(flat_elements, 8).to_u64
        key_mark_bytes = mark_flat_elements.map { |elements| checked_array_mark_byte_count(elements, 8).to_u64 }
      end

      width = WidePart.numeric_payload_width(expected_type)
      values_stream = @streams["#{column}%2Evalues"]
      _, _, value_rows = checked_stream_mark_range(values_stream, first_mark, mark_count)
      raise CorruptPartError.new("Map value substream mark rows differ") unless value_rows == rows
      validate_array_nested_stream_marks(values_stream, first_mark, mark_flat_elements, width)
      value_payload_bytes = checked_array_mark_byte_count(flat_elements, width).to_u64
      null_map = if nullable_values
                   read_map_nullable_uint64_null_map(column, first_mark, mark_count, flat_elements, rows, mark_flat_elements)
                 else
                   nil
                 end
      null_payload_bytes = nullable_values ? checked_array_mark_byte_count(flat_elements, 1).to_u64 : 0_u64
      combined_value_width = width + (nullable_values ? 1 : 0)
      combined_value_bytes = checked_array_mark_byte_count(flat_elements, combined_value_width).to_u64
      value_mark_bytes = mark_flat_elements.map { |elements| checked_array_mark_byte_count(elements, combined_value_width).to_u64 }
      payload_bytes = checked_map_materialized_bytes(key_payload_bytes, combined_value_bytes, key_mark_bytes, value_mark_bytes)
      charge_bytes = checked_map_array_tuple_charge(payload_bytes, flat_elements, rows, NUMERIC_MAP_ROW_ACCOUNTING_BYTES)
      NumericMapPreflight.new(
        outer_sizes,
        key_sizes,
        flat_elements,
        rows,
        key_payload_bytes,
        value_payload_bytes,
        payload_bytes,
        charge_bytes,
        null_payload_bytes,
        null_map
      )
    end

    # size0 owns the Map row boundaries. Every physical child must preserve
    # those per-mark row counts, even when an intermediate mark has no entries.
    private def validate_numeric_map_size0_and_child_rows(column : String, first_mark : Int, mark_count : Int) : Nil
      size0_stream = @streams["#{column}.size0"]
      child_names = if WidePart.map_string_numeric_value_type(@column_type)
                      ["#{column}%2Ekeys.size", "#{column}%2Ekeys", "#{column}%2Evalues"]
                    elsif WidePart.map_string_nullable_numeric_value_type(@column_type)
                      ["#{column}%2Ekeys.size", "#{column}%2Ekeys", "#{column}%2Evalues.null", "#{column}%2Evalues"]
                    elsif WidePart.map_uint64_nullable_numeric_value_type(@column_type)
                      ["#{column}%2Ekeys", "#{column}%2Evalues.null", "#{column}%2Evalues"]
                    else
                      ["#{column}%2Ekeys", "#{column}%2Evalues"]
                    end
      mark_count.times do |range_mark_index|
        mark_index = first_mark + range_mark_index
        size0_mark = size0_stream.marks[mark_index]
        size0_end = mark_index + 1 == size0_stream.marks.size ? size0_stream.sentinel : size0_stream.marks[mark_index + 1]
        validate_mark_range_bytes(size0_stream, size0_mark, size0_end, checked_array_mark_byte_count(size0_mark.rows, 8), 8)
        child_names.each do |name|
          child_mark = @streams[name].marks[mark_index]
          unless child_mark.rows == size0_mark.rows
            raise CorruptPartError.new("Map child substream mark rows differ")
          end
        end
      end
      nil
    end

    private def checked_map_string_array_uint64_charge(payload_bytes : UInt64, entries : UInt64, rows : UInt64) : UInt64
      checked_map_string_array_charge(payload_bytes, entries, rows, "Map(Array(UInt64))")
    end

    private def checked_map_string_array_nullable_uint64_charge(payload_bytes : UInt64, entries : UInt64, rows : UInt64) : UInt64
      checked_map_string_array_charge(payload_bytes, entries, rows, "Map(Array(Nullable(UInt64)))")
    end

    private def checked_map_uint64_array_nullable_uint64_charge(payload_bytes : UInt64, entries : UInt64, rows : UInt64) : UInt64
      checked_map_string_array_charge(payload_bytes, entries, rows, "Map(UInt64, Array(Nullable(UInt64)))")
    end

    private def checked_map_string_array_charge(payload_bytes : UInt64, entries : UInt64, rows : UInt64, type_label : String) : UInt64
      row_width = ARRAY_TUPLE_ROW_ACCOUNTING_BYTES
      entry_width = ARRAY_TUPLE_ENTRY_ACCOUNTING_BYTES
      array_width = MAP_ARRAY_UINT64_CONTAINER_ACCOUNTING_BYTES
      if rows > UInt64::MAX // row_width || entries > UInt64::MAX // entry_width || entries > UInt64::MAX // array_width
        raise CorruptPartError.new("#{type_label} materialization charge overflows")
      end
      row_bytes = rows * row_width
      entry_bytes = entries * entry_width
      array_bytes = entries * array_width
      if entry_bytes > UInt64::MAX - row_bytes || array_bytes > UInt64::MAX - row_bytes - entry_bytes ||
         payload_bytes > UInt64::MAX - row_bytes - entry_bytes - array_bytes
        raise CorruptPartError.new("#{type_label} materialization charge overflows")
      end
      charge_bytes = row_bytes + entry_bytes + array_bytes + payload_bytes
      if charge_bytes > MAX_ARRAY_MARK_BYTES.to_u64
        raise CorruptPartError.new("#{type_label} materialization charge exceeds per-range limit")
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
      StringPayloadDecoder.each(sizes, raw_bytes, "Tuple(String)") do |string_value, index|
        values << {decode_numeric_value(encoded_values, index * 8, UInt64), string_value}
        nil
      end
      values
    end

    # Read an owned, declaration-ordered range from a named Tuple whose leaves
    # are exact numeric, identifier/address, Bool, or String columns. This
    # compositional API does not widen the legacy positional Tuple accessor.
    def read_tuple_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
      max_materialized_bytes : UInt64 = WideTupleTypePlan::MAX_MATERIALIZED_BYTES,
    ) : WideTupleColumnData
      plan = ensure_compositional_tuple_column(column)
      checked_first_mark, checked_mark_count = tuple_reader_checked_range(plan, column, first_mark, mark_count)
      tuple_reader(plan, column).read(checked_first_mark, checked_mark_count, max_materialized_bytes)
    end

    # Yield one owned Tuple mark at a time. Schema and every selected stream's
    # mark schedule are checked before the first callback; payload validation
    # and charging remain lazy per materialized mark.
    def each_tuple_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
      max_materialized_bytes : UInt64 = WideTupleTypePlan::MAX_MATERIALIZED_BYTES,
      & : WideTupleColumnData, Int32 -> Nil
    ) : Nil
      plan = ensure_compositional_tuple_column(column)
      checked_first_mark, checked_mark_count = tuple_reader_checked_range(plan, column, first_mark, mark_count)
      tuple_reader(plan, column).each(checked_first_mark, checked_mark_count, max_materialized_bytes) do |data, mark_index|
        yield data, mark_index
        nil
      end
      nil
    end

    # Compute the existing Tuple reader's checked per-range materialization
    # charge without allocating decoded leaf arrays.
    def tuple_mark_range_materialization_charge(
      column : String,
      first_mark : Int,
      mark_count : Int,
      max_materialized_bytes : UInt64 = WideTupleTypePlan::MAX_MATERIALIZED_BYTES,
    ) : UInt64
      plan = ensure_compositional_tuple_column(column)
      checked_first_mark, checked_mark_count = tuple_reader_checked_range(plan, column, first_mark, mark_count)
      tuple_reader(plan, column).materialization_charge(
        checked_first_mark,
        checked_mark_count,
        max_materialized_bytes
      )
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
      StringPayloadDecoder.each(sizes, raw_bytes, "String") do |string_value, _index|
        values << string_value
        nil
      end
      values
    end

    # Read the admitted W74 Dynamic profile: one String arm and no
    # SharedVariant payload. Mixed String/UInt64/NULL parts use the explicit
    # W75 accessor below; this legacy method must not narrow their values.
    def read_dynamic_string_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(String)
      ensure_column(column)
      raise UnsupportedFormatError.new("Dynamic accessor requires exact Dynamic metadata") unless @column_type == "Dynamic"
      ensure_dynamic_string_only_profile
      values, _raw_bytes = decode_dynamic_string_mark_range(column, first_mark, mark_count, materialize: true)
      values
    end

    # Validate discriminator and child bytes before the table allocates a
    # String array or exposes the selected mark to a callback.
    def dynamic_string_mark_range_materialization_preflight(
      column : String,
      first_mark : Int,
      mark_count : Int,
    ) : UInt64
      ensure_column(column)
      raise UnsupportedFormatError.new("Dynamic preflight requires exact Dynamic metadata") unless @column_type == "Dynamic"
      ensure_dynamic_string_only_profile
      _, raw_bytes = decode_dynamic_string_mark_range(column, first_mark, mark_count, materialize: false)
      raw_bytes
    end

    # Read the exact W75 two-arm Dynamic profile. NULL is represented as nil;
    # UInt64 values are decoded from their sparse child stream, never coerced
    # through the String arm.
    def read_dynamic_string_uint64_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(VariantStringUInt64Value)
      ensure_column(column)
      raise UnsupportedFormatError.new("Dynamic accessor requires exact Dynamic metadata") unless @column_type == "Dynamic"
      ensure_dynamic_string_uint64_profile
      values, _string_bytes, _charge_bytes = decode_dynamic_string_uint64_mark_range(column, first_mark, mark_count, materialize: true)
      values
    end

    # Validate all selected child extents and compute the table's bounded
    # materialization charge before it allocates or exposes this mark.
    def dynamic_string_uint64_mark_range_materialization_preflight(
      column : String,
      first_mark : Int,
      mark_count : Int,
    ) : {UInt64, UInt64}
      ensure_column(column)
      raise UnsupportedFormatError.new("Dynamic preflight requires exact Dynamic metadata") unless @column_type == "Dynamic"
      ensure_dynamic_string_uint64_profile
      _, string_bytes, charge_bytes = decode_dynamic_string_uint64_mark_range(column, first_mark, mark_count, materialize: false)
      {string_bytes, charge_bytes}
    end

    def dynamic_string_uint64_profile? : Bool
      ensure_column(@column)
      raise UnsupportedFormatError.new("Dynamic profile query requires exact Dynamic metadata") unless @column_type == "Dynamic"
      structure = @streams["#{@column}.dynamic_structure"]
      bytes = read_lz4_stream_bounded(structure, 1024)
      variant_read_var_uint(bytes, 8)[0] == 2_u64
    end

    private def decode_dynamic_string_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
      materialize : Bool,
    ) : {Array(String), UInt64}
      discriminator = @streams["#{column}.variant_discr"]
      _, _, selected_rows = checked_stream_mark_range(discriminator, first_mark, mark_count)
      raise CorruptPartError.new("Dynamic mark range exceeds row limit") if selected_rows > MAX_VARIANT_RANGE_ROWS
      dynamic_discriminator_mode(discriminator)

      shared_size = @streams["#{column}.SharedVariant.size"]
      shared_data = @streams["#{column}.SharedVariant"]
      string_sizes = @streams["#{column}.String.size"]
      string_data = @streams["#{column}.String"]
      values = materialize ? Array(String).new(selected_rows.to_i) : Array(String).new(0)
      total_string_bytes = 0_u64

      mark_count.times do |range_offset|
        mark_index = first_mark + range_offset
        start_mark = discriminator.marks[mark_index]
        end_mark = mark_index + 1 == discriminator.marks.size ? discriminator.sentinel : discriminator.marks[mark_index + 1]
        rows = start_mark.rows
        read_dynamic_string_discriminator_mark(discriminator, start_mark, end_mark, mark_index, rows)

        _, _, shared_size_rows = checked_stream_mark_range(shared_size, mark_index, 1)
        _, _, shared_rows = checked_stream_mark_range(shared_data, mark_index, 1)
        raise CorruptPartError.new("Dynamic SharedVariant mark rows differ") unless shared_size_rows == rows && shared_rows == rows

        size_start, size_end, size_rows = checked_stream_mark_range(string_sizes, mark_index, 1)
        raise CorruptPartError.new("Dynamic String-size mark rows differ") unless size_rows == rows
        encoded_sizes = read_mark_range_bytes(string_sizes, size_start, size_end, checked_byte_count(rows, 8), 8)
        sizes = Array(UInt64).new(rows.to_i)
        mark_string_bytes = 0_u64
        rows.to_i.times do |index|
          length = u64(encoded_sizes, index * 8)
          if length > MAX_STRING_RANGE_BYTES.to_u64 - mark_string_bytes ||
             length > MAX_STRING_RANGE_BYTES.to_u64 - total_string_bytes
            raise CorruptPartError.new("Dynamic String bytes exceed materialization limit")
          end
          mark_string_bytes += length
          total_string_bytes += length
          sizes << length
        end

        raw_start, raw_end, raw_rows = checked_stream_mark_range(string_data, mark_index, 1)
        raise CorruptPartError.new("Dynamic String mark rows differ") unless raw_rows == rows
        raw_byte_count = mark_string_bytes.to_i
        raw_bytes = if materialize
                      read_mark_range_bytes(string_data, raw_start, raw_end, raw_byte_count, 1)
                    else
                      validate_mark_range_bytes(string_data, raw_start, raw_end, raw_byte_count, 1)
                      Bytes.empty
                    end

        if materialize
          offset = 0
          sizes.each do |length|
            byte_length = length.to_i
            raise CorruptPartError.new("Dynamic String sizes exceed selected raw bytes") if byte_length > raw_bytes.size - offset
            values << String.new(raw_bytes[offset, byte_length])
            offset += byte_length
          end
          raise CorruptPartError.new("Dynamic String sizes do not consume selected raw bytes") unless offset == raw_bytes.size
        end
      end

      raise CorruptPartError.new("Dynamic materialized row count differs from marks") if materialize && values.size.to_u64 != selected_rows
      {values, total_string_bytes}
    end

    private def validate_dynamic_string_structure : Nil
      structure = @streams["#{@column}.dynamic_structure"]
      marks = structure.marks
      bytes = read_lz4_stream_bounded(structure, 1024)
      unless structure.sentinel.compressed_offset == 0_u64 && structure.sentinel.decompressed_offset == bytes.size.to_u64
        raise CorruptPartError.new("Dynamic structure sentinel does not point to the decompressed structure end")
      end
      raise CorruptPartError.new("Dynamic structure is truncated") if bytes.size < 8
      version = u64(bytes, 0)
      raise UnsupportedFormatError.new("only Dynamic V4 structure is supported") unless version == 4_u64
      dynamic_type_count, cursor = variant_read_var_uint(bytes, 8)
      if dynamic_type_count == 1_u64
        type_code, cursor = variant_read_var_uint(bytes, cursor)
        raise UnsupportedFormatError.new("Dynamic one-arm profile must be String") unless type_code == 0x15_u64
      elsif dynamic_type_count == 2_u64
        first_type_code, cursor = variant_read_var_uint(bytes, cursor)
        second_type_code, cursor = variant_read_var_uint(bytes, cursor)
        unless first_type_code == 0x15_u64 && second_type_code == 0x04_u64
          raise UnsupportedFormatError.new("W75 Dynamic dictionary must be canonical String, UInt64")
        end
      else
        raise UnsupportedFormatError.new("Dynamic supports the W74 String-only or exact W75 String/UInt64 profile")
      end
      expected_streams = [
        "#{@column}.dynamic_structure",
        "#{@column}.variant_discr",
        "#{@column}.SharedVariant.size",
        "#{@column}.SharedVariant",
        "#{@column}.String.size",
        "#{@column}.String",
      ]
      expected_streams << "#{@column}.UInt64" if dynamic_type_count == 2_u64
      unless @streams.keys == expected_streams
        raise UnsupportedFormatError.new("Dynamic dictionary arms do not match physical substreams")
      end
      unless marks.all? { |mark| mark.compressed_offset == 0_u64 && mark.decompressed_offset == cursor.to_u64 }
        raise CorruptPartError.new("Dynamic structure marks do not point after the dictionary prefix")
      end
      raise CorruptPartError.new("Dynamic V4 statistics flag is truncated") if cursor >= bytes.size
      has_statistics = bytes[cursor]
      cursor += 1
      raise UnsupportedFormatError.new("Dynamic V4 prefix statistics are required") unless has_statistics == 1_u8
      shared_rows, cursor = variant_read_var_uint(bytes, cursor)
      arm_counts = Array(UInt64).new(dynamic_type_count.to_i)
      dynamic_type_count.to_i.times do
        arm_rows, cursor = variant_read_var_uint(bytes, cursor)
        arm_counts << arm_rows
      end
      shared_statistics_count, cursor = variant_read_var_uint(bytes, cursor)
      raise CorruptPartError.new("Dynamic SharedVariant statistics must be zero") unless shared_rows == 0_u64
      raise UnsupportedFormatError.new("Dynamic shared-type statistics are unsupported") unless shared_statistics_count == 0_u64
      raise CorruptPartError.new("Dynamic structure has trailing bytes") unless cursor == bytes.size
      if dynamic_type_count == 1_u64
        raise CorruptPartError.new("Dynamic String statistics do not match part row count") unless arm_counts[0] == @row_count
      else
        string_rows = arm_counts[0]
        uint64_rows = arm_counts[1]
        if string_rows == 0_u64 || uint64_rows == 0_u64 || string_rows > @row_count || uint64_rows > @row_count - string_rows
          raise UnsupportedFormatError.new("W75 Dynamic requires both String and UInt64 dictionary arms")
        end
        validate_dynamic_discriminator_statistics(string_rows, uint64_rows)
      end
      nil
    end

    private def ensure_dynamic_string_only_profile : Nil
      structure = @streams["#{@column}.dynamic_structure"]
      bytes = read_lz4_stream_bounded(structure, 1024)
      type_count = variant_read_var_uint(bytes, 8)[0]
      raise UnsupportedFormatError.new("String-only Dynamic accessor rejects mixed Dynamic parts") unless type_count == 1_u64
      nil
    end

    private def ensure_dynamic_string_uint64_profile : Nil
      structure = @streams["#{@column}.dynamic_structure"]
      bytes = read_lz4_stream_bounded(structure, 1024)
      type_count, cursor = variant_read_var_uint(bytes, 8)
      raise UnsupportedFormatError.new("mixed Dynamic accessor requires exactly String and UInt64") unless type_count == 2_u64
      first_type, cursor = variant_read_var_uint(bytes, cursor)
      second_type = variant_read_var_uint(bytes, cursor)[0]
      unless first_type == 0x15_u64 && second_type == 0x04_u64
        raise UnsupportedFormatError.new("mixed Dynamic accessor requires canonical String, UInt64 arms")
      end
      nil
    end

    private def validate_dynamic_discriminator_statistics(expected_string_rows : UInt64, expected_uint64_rows : UInt64) : Nil
      stream = @streams["#{@column}.variant_discr"]
      dynamic_discriminator_mode(stream)
      string_rows = 0_u64
      uint64_rows = 0_u64
      stream.marks.each_with_index do |start_mark, mark_index|
        end_mark = mark_index + 1 == stream.marks.size ? stream.sentinel : stream.marks[mark_index + 1]
        tags = read_dynamic_string_uint64_discriminator_mark(stream, start_mark, end_mark, mark_index, start_mark.rows)
        tags.each do |tag|
          case tag
          when 1_u8
            string_rows += 1_u64
          when 2_u8
            uint64_rows += 1_u64
          when 255_u8
          else
            raise CorruptPartError.new("Dynamic discriminator tag is unsupported")
          end
        end
      end
      unless string_rows == expected_string_rows && uint64_rows == expected_uint64_rows
        raise CorruptPartError.new("Dynamic discriminator arm counts differ from structure statistics")
      end
      nil
    end

    private def decode_dynamic_string_uint64_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
      materialize : Bool,
    ) : {Array(VariantStringUInt64Value), UInt64, UInt64}
      discriminator = @streams["#{column}.variant_discr"]
      _, _, selected_rows = checked_stream_mark_range(discriminator, first_mark, mark_count)
      raise CorruptPartError.new("Dynamic mark range exceeds row limit") if selected_rows > MAX_VARIANT_RANGE_ROWS
      dynamic_discriminator_mode(discriminator)

      shared_size = @streams["#{column}.SharedVariant.size"]
      shared_data = @streams["#{column}.SharedVariant"]
      string_sizes = @streams["#{column}.String.size"]
      string_data = @streams["#{column}.String"]
      uint64_data = @streams["#{column}.UInt64"]
      values = materialize ? Array(VariantStringUInt64Value).new(selected_rows.to_i) : Array(VariantStringUInt64Value).new(0)
      total_string_bytes = 0_u64
      total_charge_bytes = 0_u64

      mark_count.times do |range_offset|
        mark_index = first_mark + range_offset
        start_mark = discriminator.marks[mark_index]
        end_mark = mark_index + 1 == discriminator.marks.size ? discriminator.sentinel : discriminator.marks[mark_index + 1]
        rows = start_mark.rows
        tags = read_dynamic_string_uint64_discriminator_mark(discriminator, start_mark, end_mark, mark_index, rows)
        string_count = 0_u64
        uint64_count = 0_u64
        tags.each do |tag|
          case tag
          when 1_u8 then string_count += 1_u64
          when 2_u8 then uint64_count += 1_u64
          when 255_u8
          else raise CorruptPartError.new("Dynamic discriminator tag is unsupported")
          end
        end

        _, _, shared_size_rows = checked_stream_mark_range(shared_size, mark_index, 1)
        _, _, shared_rows = checked_stream_mark_range(shared_data, mark_index, 1)
        raise CorruptPartError.new("Dynamic SharedVariant mark rows differ") unless shared_size_rows == rows && shared_rows == rows

        size_start, size_end, size_rows = checked_stream_mark_range(string_sizes, mark_index, 1)
        raise CorruptPartError.new("Dynamic String-size mark rows differ") unless size_rows == rows
        size_bytes = checked_dynamic_child_bytes(string_count, 8)
        encoded_sizes = read_mark_range_bytes(string_sizes, size_start, size_end, size_bytes, 8)
        sizes = Array(UInt64).new(string_count.to_i)
        mark_string_bytes = 0_u64
        string_count.to_i.times do |index|
          length = u64(encoded_sizes, index * 8)
          if length > MAX_STRING_RANGE_BYTES.to_u64 - mark_string_bytes ||
             length > MAX_STRING_RANGE_BYTES.to_u64 - total_string_bytes
            raise CorruptPartError.new("Dynamic String bytes exceed materialization limit")
          end
          mark_string_bytes += length
          total_string_bytes += length
          sizes << length
        end

        if rows > UInt64::MAX // VARIANT_STRING_UINT64_ROW_ACCOUNTING_BYTES
          raise CorruptPartError.new("Dynamic materialization charge overflows")
        end
        row_charge = rows * VARIANT_STRING_UINT64_ROW_ACCOUNTING_BYTES
        if row_charge > MAX_STRING_RANGE_BYTES.to_u64 - total_charge_bytes ||
           mark_string_bytes > MAX_STRING_RANGE_BYTES.to_u64 - total_charge_bytes - row_charge
          raise CorruptPartError.new("Dynamic materialization charge exceeds per-range limit")
        end
        total_charge_bytes += row_charge + mark_string_bytes

        raw_start, raw_end, raw_rows = checked_stream_mark_range(string_data, mark_index, 1)
        raise CorruptPartError.new("Dynamic String mark rows differ") unless raw_rows == rows
        raw_byte_count = checked_dynamic_child_bytes(mark_string_bytes, 1)
        raw_bytes = if materialize
                      read_mark_range_bytes(string_data, raw_start, raw_end, raw_byte_count, 1)
                    else
                      validate_mark_range_bytes(string_data, raw_start, raw_end, raw_byte_count, 1)
                      Bytes.empty
                    end

        uint64_start, uint64_end, uint64_rows = checked_stream_mark_range(uint64_data, mark_index, 1)
        raise CorruptPartError.new("Dynamic UInt64 mark rows differ") unless uint64_rows == rows
        encoded_uint64 = read_mark_range_bytes(
          uint64_data,
          uint64_start,
          uint64_end,
          checked_dynamic_child_bytes(uint64_count, 8),
          8
        )

        if materialize
          string_index = 0
          string_offset = 0
          uint64_index = 0
          tags.each do |tag|
            case tag
            when 1_u8
              length = sizes[string_index].to_i
              raise CorruptPartError.new("Dynamic String sizes exceed selected raw bytes") if length > raw_bytes.size - string_offset
              values << String.new(raw_bytes[string_offset, length])
              string_offset += length
              string_index += 1
            when 2_u8
              values << u64(encoded_uint64, uint64_index * 8)
              uint64_index += 1
            when 255_u8
              values << nil
            end
          end
          raise CorruptPartError.new("Dynamic String sizes do not consume selected raw bytes") unless string_offset == raw_bytes.size
        end
      end

      raise CorruptPartError.new("Dynamic materialized row count differs from marks") if materialize && values.size.to_u64 != selected_rows
      {values, total_string_bytes, total_charge_bytes}
    end

    private def read_dynamic_string_uint64_discriminator_mark(
      stream : PhysicalStream,
      start_mark : Mark,
      end_mark : Mark,
      mark_index : Int,
      rows : UInt64,
    ) : Array(UInt8)
      raise CorruptPartError.new("Dynamic mark range exceeds row limit") if rows > MAX_VARIANT_RANGE_ROWS
      if mark_index == 0 && !(start_mark.compressed_offset == 0_u64 && start_mark.decompressed_offset == 8_u64)
        raise CorruptPartError.new("Dynamic discriminator first mark must start after eight-byte mode prefix")
      end
      bytes = read_bounded_mark_range_bytes(stream, start_mark, end_mark, rows.to_i + 11, 1)
      encoded_rows, cursor = variant_read_var_uint(bytes, 0)
      raise CorruptPartError.new("Dynamic discriminator row count does not match marks") unless encoded_rows == rows
      raise CorruptPartError.new("Dynamic discriminator format is truncated") if cursor >= bytes.size
      format = bytes[cursor]
      cursor += 1
      tags = Array(UInt8).new(rows.to_i)
      case format
      when 0_u8
        raise CorruptPartError.new("Dynamic row-tag discriminator is truncated") unless bytes.size - cursor == rows.to_i
        rows.to_i.times { |index| tags << bytes[cursor + index] }
        cursor += rows.to_i
      when 1_u8
        raise CorruptPartError.new("Dynamic uniform discriminator tag is truncated") unless bytes.size - cursor == 1
        tag = bytes[cursor]
        rows.to_i.times { tags << tag }
        cursor += 1
      else
        raise UnsupportedFormatError.new("Dynamic discriminator format is unsupported")
      end
      raise CorruptPartError.new("Dynamic discriminator mark has trailing bytes") unless cursor == bytes.size
      tags.each do |tag|
        raise CorruptPartError.new("Dynamic discriminator tag is unsupported") unless tag == 1_u8 || tag == 2_u8 || tag == 255_u8
      end
      tags
    end

    private def checked_dynamic_child_bytes(elements : UInt64, width : Int32) : Int
      byte_width = width.to_u64
      if byte_width == 0 || elements > UInt64::MAX // byte_width
        raise CorruptPartError.new("Dynamic child byte count overflows")
      end
      bytes = elements * byte_width
      if bytes > MAX_STRING_RANGE_BYTES.to_u64 || bytes > Int32::MAX.to_u64
        raise CorruptPartError.new("Dynamic child bytes exceed per-range limit")
      end
      bytes.to_i
    end

    private def dynamic_discriminator_mode(stream : PhysicalStream) : UInt64
      data_size = File.size(stream.data_path)
      raise CorruptPartError.new("data file exceeds limit") if data_size > MAX_DATA_FILE_BYTES
      raise CorruptPartError.new("Dynamic discriminator prefix is truncated") if data_size == 0
      mode = 0_u64
      MMapDataSource.with_file(stream.data_path, data_size, MAX_DATA_FILE_BYTES) do |data|
        if data.size <= CompressedBlock::CHECKSUM_SIZE || data[CompressedBlock::CHECKSUM_SIZE] != CompressedBlock::METHOD_LZ4
          raise UnsupportedFormatError.new("Dynamic requires LZ4 compressed streams")
        end
        frame = CompressedBlock.decode_frame_into(data, 0_i64, CompressedBlock::DecodeWorkspace.new, MAX_FRAME_COMPRESSED_BYTES, MAX_FRAME_DECOMPRESSED_BYTES)
        raise CorruptPartError.new("Dynamic discriminator prefix is truncated") if frame.output.size < 8
        mode = u64(frame.output, 0)
      end
      raise UnsupportedFormatError.new("Dynamic requires COMPACT discriminators") unless mode == 1_u64
      mode
    end

    private def read_dynamic_string_discriminator_mark(
      stream : PhysicalStream,
      start_mark : Mark,
      end_mark : Mark,
      mark_index : Int,
      rows : UInt64,
    ) : Nil
      raise CorruptPartError.new("Dynamic mark range exceeds row limit") if rows > MAX_VARIANT_RANGE_ROWS
      if mark_index == 0 && !(start_mark.compressed_offset == 0_u64 && start_mark.decompressed_offset == 8_u64)
        raise CorruptPartError.new("Dynamic discriminator first mark must start after eight-byte mode prefix")
      end
      bytes = read_bounded_mark_range_bytes(stream, start_mark, end_mark, rows.to_i + 11, 1)
      encoded_rows, cursor = variant_read_var_uint(bytes, 0)
      raise CorruptPartError.new("Dynamic discriminator row count does not match marks") unless encoded_rows == rows
      raise CorruptPartError.new("Dynamic discriminator format is truncated") if cursor >= bytes.size
      format = bytes[cursor]
      cursor += 1
      raise UnsupportedFormatError.new("Dynamic requires compact uniform discriminator marks") unless format == 1_u8
      raise CorruptPartError.new("Dynamic uniform discriminator tag is truncated") if cursor >= bytes.size
      tag = bytes[cursor]
      cursor += 1
      raise UnsupportedFormatError.new("Dynamic discriminator must select String") unless tag == 1_u8
      raise CorruptPartError.new("Dynamic discriminator mark has trailing bytes") unless cursor == bytes.size
      nil
    end

    private def read_lz4_stream_bounded(stream : PhysicalStream, maximum_output : Int) : Bytes
      data_size = File.size(stream.data_path)
      raise CorruptPartError.new("data file exceeds limit") if data_size > MAX_DATA_FILE_BYTES
      raise CorruptPartError.new("Dynamic structure stream is empty") if data_size == 0
      output = IO::Memory.new
      total_output = 0
      MMapDataSource.with_file(stream.data_path, data_size, MAX_DATA_FILE_BYTES) do |data|
        offset = 0_i64
        workspace = CompressedBlock::DecodeWorkspace.new
        while offset < data.size.to_i64
          if offset > data.size.to_i64 - CompressedBlock::FRAME_HEADER_SIZE ||
             data[offset.to_i + CompressedBlock::CHECKSUM_SIZE] != CompressedBlock::METHOD_LZ4
            raise UnsupportedFormatError.new("Dynamic requires LZ4 compressed streams")
          end
          frame = CompressedBlock.decode_frame_into(data, offset, workspace, MAX_FRAME_COMPRESSED_BYTES, MAX_FRAME_DECOMPRESSED_BYTES)
          raise CorruptPartError.new("Dynamic structure exceeds parser limit") if frame.output.size > maximum_output - total_output
          output.write(frame.output)
          total_output += frame.output.size
          raise CorruptPartError.new("Dynamic structure frame did not advance") if frame.end_offset <= offset
          offset = frame.end_offset
        end
        raise CorruptPartError.new("Dynamic structure stream has trailing bytes") unless offset == data.size.to_i64
      end
      output.to_slice
    end

    # Read one bounded mark range from the admitted Variant(String, UInt64)
    # profile. Sparse child streams are indexed by the discriminator tags, but
    # their mark records retain the top-level row count.
    def read_variant_string_uint64_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
    ) : Array(VariantStringUInt64Value)
      ensure_column(column)
      unless WidePart.supports_variant_string_uint64_type?(@column_type)
        raise UnsupportedFormatError.new("Variant accessor requires exact Variant(String, UInt64)")
      end
      values, _raw_string_bytes = decode_variant_string_uint64_mark_range(column, first_mark, mark_count, materialize: true)
      values
    end

    # Validate the exact same selected marks and child payloads as the public
    # reader without materializing returned Strings. The second tuple field is
    # a conservative allocation charge: raw String bytes plus 64 bytes per
    # top-level union slot.
    def variant_string_uint64_mark_range_materialization_preflight(
      column : String,
      first_mark : Int,
      mark_count : Int,
    ) : {UInt64, UInt64}
      ensure_column(column)
      unless WidePart.supports_variant_string_uint64_type?(@column_type)
        raise UnsupportedFormatError.new("Variant preflight requires exact Variant(String, UInt64)")
      end
      _, raw_string_bytes = decode_variant_string_uint64_mark_range(column, first_mark, mark_count, materialize: false)
      discriminator_stream = @streams[WideVariantStringUInt64TypePlan.discriminator_stream(column)]
      _, _, rows = checked_stream_mark_range(discriminator_stream, first_mark, mark_count)
      row_charge = VARIANT_STRING_UINT64_ROW_ACCOUNTING_BYTES
      raise CorruptPartError.new("Variant mark allocation charge overflows") if rows > (UInt64::MAX - raw_string_bytes) // row_charge
      {raw_string_bytes, raw_string_bytes + rows * row_charge}
    end

    # W57's exact Bool/String/UInt64 paired codec keeps an independent public
    # value type so the W56 accessor cannot accidentally admit Bool.
    def read_variant_bool_string_uint64_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
    ) : Array(VariantBoolStringUInt64Value)
      ensure_column(column)
      unless WidePart.supports_variant_bool_string_uint64_type?(@column_type)
        raise UnsupportedFormatError.new("Variant accessor requires exact Variant(Bool, String, UInt64)")
      end
      values, _raw_string_bytes = decode_variant_bool_string_uint64_mark_range(column, first_mark, mark_count, materialize: true)
      values
    end

    def variant_bool_string_uint64_mark_range_materialization_preflight(
      column : String,
      first_mark : Int,
      mark_count : Int,
    ) : {UInt64, UInt64}
      ensure_column(column)
      unless WidePart.supports_variant_bool_string_uint64_type?(@column_type)
        raise UnsupportedFormatError.new("Variant preflight requires exact Variant(Bool, String, UInt64)")
      end
      _, raw_string_bytes = decode_variant_bool_string_uint64_mark_range(column, first_mark, mark_count, materialize: false)
      discriminator_stream = @streams[WideVariantBoolStringUInt64TypePlan.discriminator_stream(column)]
      _, _, rows = checked_stream_mark_range(discriminator_stream, first_mark, mark_count)
      row_charge = VARIANT_BOOL_STRING_UINT64_ROW_ACCOUNTING_BYTES
      raise CorruptPartError.new("Variant mark allocation charge overflows") if rows > (UInt64::MAX - raw_string_bytes) // row_charge
      {raw_string_bytes, raw_string_bytes + rows * row_charge}
    end

    private def decode_variant_bool_string_uint64_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
      materialize : Bool,
    ) : {Array(VariantBoolStringUInt64Value), UInt64}
      discriminator_stream = @streams[WideVariantBoolStringUInt64TypePlan.discriminator_stream(column)]
      _, _, selected_rows = checked_stream_mark_range(discriminator_stream, first_mark, mark_count)
      raise CorruptPartError.new("Variant mark range exceeds row limit") if selected_rows > MAX_VARIANT_RANGE_ROWS

      mode = variant_discriminator_mode(discriminator_stream)
      bool_stream = @streams[WideVariantBoolStringUInt64TypePlan.bool_stream(column)]
      string_size_stream = @streams[WideVariantBoolStringUInt64TypePlan.string_size_stream(column)]
      string_stream = @streams[WideVariantBoolStringUInt64TypePlan.string_stream(column)]
      uint64_stream = @streams[WideVariantBoolStringUInt64TypePlan.uint64_stream(column)]
      values = materialize ? Array(VariantBoolStringUInt64Value).new(selected_rows.to_i) : Array(VariantBoolStringUInt64Value).new(0)
      total_string_bytes = 0_u64

      mark_count.times do |range_offset|
        mark_index = first_mark + range_offset
        start_mark = discriminator_stream.marks[mark_index]
        end_mark = mark_index + 1 == discriminator_stream.marks.size ? discriminator_stream.sentinel : discriminator_stream.marks[mark_index + 1]
        rows = start_mark.rows
        tags = read_variant_discriminator_mark(discriminator_stream, start_mark, end_mark, mark_index, rows, mode, WideVariantBoolStringUInt64TypePlan::DESCRIPTOR)
        bool_count = tags.count { |tag| tag == WideVariantBoolStringUInt64TypePlan::TAG_BOOL }.to_u64
        string_count = tags.count { |tag| tag == WideVariantBoolStringUInt64TypePlan::TAG_STRING }.to_u64
        uint64_count = tags.count { |tag| tag == WideVariantBoolStringUInt64TypePlan::TAG_UINT64 }.to_u64

        bool_start, bool_end, bool_rows = checked_stream_mark_range(bool_stream, mark_index, 1)
        raise CorruptPartError.new("Variant Bool child mark rows differ") unless bool_rows == rows
        bool_bytes = read_mark_range_bytes(bool_stream, bool_start, bool_end, bool_count.to_i, 1)
        size_start, size_end, size_rows = checked_stream_mark_range(string_size_stream, mark_index, 1)
        raise CorruptPartError.new("Variant String-size child mark rows differ") unless size_rows == rows
        size_bytes = checked_byte_count(string_count, 8)
        encoded_sizes = read_mark_range_bytes(string_size_stream, size_start, size_end, size_bytes, 8)
        sizes = Array(UInt64).new(string_count.to_i) { |index| u64(encoded_sizes, index * 8) }
        mark_string_bytes = 0_u64
        sizes.each do |length|
          if length > MAX_STRING_RANGE_BYTES.to_u64 - mark_string_bytes || length > MAX_STRING_RANGE_BYTES.to_u64 - total_string_bytes
            raise CorruptPartError.new("Variant String bytes exceed materialization limit")
          end
          mark_string_bytes += length
          total_string_bytes += length
        end

        raw_start, raw_end, raw_rows = checked_stream_mark_range(string_stream, mark_index, 1)
        raise CorruptPartError.new("Variant String child mark rows differ") unless raw_rows == rows
        raw_byte_count = mark_string_bytes.to_i
        raw_bytes = if materialize
                      read_mark_range_bytes(string_stream, raw_start, raw_end, raw_byte_count, 1)
                    else
                      validate_mark_range_bytes(string_stream, raw_start, raw_end, raw_byte_count, 1)
                      Bytes.empty
                    end

        uint64_start, uint64_end, uint64_rows = checked_stream_mark_range(uint64_stream, mark_index, 1)
        raise CorruptPartError.new("Variant UInt64 child mark rows differ") unless uint64_rows == rows
        uint64_bytes = read_mark_range_bytes(uint64_stream, uint64_start, uint64_end, checked_byte_count(uint64_count, 8), 8)

        if materialize
          bool_index = 0
          string_index = 0
          uint64_index = 0
          raw_offset = 0
          tags.each do |tag|
            case tag
            when WideVariantBoolStringUInt64TypePlan::TAG_BOOL
              values << BoolValueCodec.decode(bool_bytes[bool_index])
              bool_index += 1
            when WideVariantBoolStringUInt64TypePlan::TAG_STRING
              length = sizes[string_index].to_i
              raise CorruptPartError.new("Variant String sizes exceed selected raw bytes") if length > raw_bytes.size - raw_offset
              values << String.new(raw_bytes[raw_offset, length])
              raw_offset += length
              string_index += 1
            when WideVariantBoolStringUInt64TypePlan::TAG_UINT64
              values << u64(uint64_bytes, uint64_index * 8)
              uint64_index += 1
            when WideVariantBoolStringUInt64TypePlan::TAG_NULL
              values << nil
            else
              raise CorruptPartError.new("Variant discriminator tag is unsupported")
            end
          end
          unless bool_index.to_u64 == bool_count && string_index == sizes.size && uint64_index.to_u64 == uint64_count && raw_offset == raw_bytes.size
            raise CorruptPartError.new("Variant child cardinality differs from discriminator")
          end
        end
      end

      raise CorruptPartError.new("Variant materialized row count differs from marks") if materialize && values.size.to_u64 != selected_rows
      {values, total_string_bytes}
    end

    private def decode_variant_string_uint64_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
      materialize : Bool,
    ) : {Array(VariantStringUInt64Value), UInt64}
      plan = WideVariantStringUInt64TypePlan
      discriminator_stream = @streams[plan.discriminator_stream(column)]
      _, _, selected_rows = checked_stream_mark_range(discriminator_stream, first_mark, mark_count)
      raise CorruptPartError.new("Variant mark range exceeds row limit") if selected_rows > MAX_VARIANT_RANGE_ROWS

      mode = variant_discriminator_mode(discriminator_stream)
      string_size_stream = @streams[plan.string_size_stream(column)]
      string_stream = @streams[plan.string_stream(column)]
      uint64_stream = @streams[plan.uint64_stream(column)]
      values = materialize ? Array(VariantStringUInt64Value).new(selected_rows.to_i) : Array(VariantStringUInt64Value).new(0)
      total_string_bytes = 0_u64

      mark_count.times do |range_offset|
        mark_index = first_mark + range_offset
        start_mark = discriminator_stream.marks[mark_index]
        end_mark = mark_index + 1 == discriminator_stream.marks.size ? discriminator_stream.sentinel : discriminator_stream.marks[mark_index + 1]
        rows = start_mark.rows
        tags = read_variant_discriminator_mark(discriminator_stream, start_mark, end_mark, mark_index, rows, mode, WideVariantStringUInt64TypePlan::DESCRIPTOR)
        string_count = tags.count { |tag| tag == WideVariantStringUInt64TypePlan::TAG_STRING }.to_u64
        uint64_count = tags.count { |tag| tag == WideVariantStringUInt64TypePlan::TAG_UINT64 }.to_u64

        size_start, size_end, size_rows = checked_stream_mark_range(string_size_stream, mark_index, 1)
        raise CorruptPartError.new("Variant String-size child mark rows differ") unless size_rows == rows
        size_bytes = checked_byte_count(string_count, 8)
        encoded_sizes = read_mark_range_bytes(string_size_stream, size_start, size_end, size_bytes, 8)
        sizes = Array(UInt64).new(string_count.to_i) { |index| u64(encoded_sizes, index * 8) }
        mark_string_bytes = 0_u64
        sizes.each do |length|
          if length > MAX_STRING_RANGE_BYTES.to_u64 - mark_string_bytes || length > MAX_STRING_RANGE_BYTES.to_u64 - total_string_bytes
            raise CorruptPartError.new("Variant String bytes exceed materialization limit")
          end
          mark_string_bytes += length
          total_string_bytes += length
        end

        raw_start, raw_end, raw_rows = checked_stream_mark_range(string_stream, mark_index, 1)
        raise CorruptPartError.new("Variant String child mark rows differ") unless raw_rows == rows
        raw_byte_count = mark_string_bytes.to_i
        raw_bytes = if materialize
                      read_mark_range_bytes(string_stream, raw_start, raw_end, raw_byte_count, 1)
                    else
                      validate_mark_range_bytes(string_stream, raw_start, raw_end, raw_byte_count, 1)
                      Bytes.empty
                    end

        uint64_start, uint64_end, uint64_rows = checked_stream_mark_range(uint64_stream, mark_index, 1)
        raise CorruptPartError.new("Variant UInt64 child mark rows differ") unless uint64_rows == rows
        uint64_bytes = read_mark_range_bytes(uint64_stream, uint64_start, uint64_end, checked_byte_count(uint64_count, 8), 8)

        if materialize
          string_index = 0
          uint64_index = 0
          raw_offset = 0
          tags.each do |tag|
            case tag
            when WideVariantStringUInt64TypePlan::TAG_STRING
              length = sizes[string_index].to_i
              raise CorruptPartError.new("Variant String sizes exceed selected raw bytes") if length > raw_bytes.size - raw_offset
              values << String.new(raw_bytes[raw_offset, length])
              raw_offset += length
              string_index += 1
            when WideVariantStringUInt64TypePlan::TAG_UINT64
              values << u64(uint64_bytes, uint64_index * 8)
              uint64_index += 1
            when WideVariantStringUInt64TypePlan::TAG_NULL
              values << nil
            else
              raise CorruptPartError.new("Variant discriminator tag is unsupported")
            end
          end
          raise CorruptPartError.new("Variant child cardinality differs from discriminator") unless string_index == sizes.size && uint64_index.to_u64 == uint64_count && raw_offset == raw_bytes.size
        end
      end

      raise CorruptPartError.new("Variant materialized row count differs from marks") if materialize && values.size.to_u64 != selected_rows
      {values, total_string_bytes}
    end

    private def variant_discriminator_mode(stream : PhysicalStream) : UInt64
      data_size = File.size(stream.data_path)
      raise CorruptPartError.new("data file exceeds limit") if data_size > MAX_DATA_FILE_BYTES
      raise CorruptPartError.new("Variant discriminator prefix is truncated") if data_size == 0
      mode = 0_u64
      MMapDataSource.with_file(stream.data_path, data_size, MAX_DATA_FILE_BYTES) do |data|
        if data.size <= CompressedBlock::CHECKSUM_SIZE || data[CompressedBlock::CHECKSUM_SIZE] != CompressedBlock::METHOD_LZ4
          raise UnsupportedFormatError.new("Variant requires LZ4 compressed streams")
        end
        frame = CompressedBlock.decode_frame_into(
          data,
          0_i64,
          CompressedBlock::DecodeWorkspace.new,
          MAX_FRAME_COMPRESSED_BYTES,
          MAX_FRAME_DECOMPRESSED_BYTES
        )
        raise CorruptPartError.new("Variant discriminator prefix is truncated") if frame.output.size < 8
        mode = u64(frame.output, 0)
        unless mode == WideVariantTypePlanDescriptor::MODE_BASIC || mode == WideVariantTypePlanDescriptor::MODE_COMPACT
          raise CorruptPartError.new("Variant discriminator mode is unsupported")
        end
      end
      mode
    end

    private def read_variant_discriminator_mark(
      stream : PhysicalStream,
      start_mark : Mark,
      end_mark : Mark,
      mark_index : Int,
      rows : UInt64,
      mode : UInt64,
      plan : WideVariantTypePlanDescriptor,
    ) : Array(UInt8)
      if rows > MAX_VARIANT_RANGE_ROWS
        raise CorruptPartError.new("Variant mark range exceeds row limit")
      end
      maximum_bytes = rows.to_i + 19
      bytes = read_bounded_mark_range_bytes(stream, start_mark, end_mark, maximum_bytes, 1)
      if mark_index == 0
        unless start_mark.compressed_offset == 0_u64 && start_mark.decompressed_offset == 8_u64
          raise CorruptPartError.new("Variant discriminator first mark must start after eight-byte mode prefix")
        end
      end
      VariantDiscriminatorDecoder.decode(bytes, rows, mode, plan)
    end

    private def variant_read_var_uint(bytes : Bytes, offset : Int) : {UInt64, Int32}
      VariantDiscriminatorDecoder.read_var_uint(bytes, offset)
    end

    private def read_bounded_mark_range_bytes(
      stream : PhysicalStream,
      start_mark : Mark,
      end_mark : Mark,
      maximum_bytes : Int,
      element_width : Int32,
    ) : Bytes
      raise CorruptPartError.new("selected byte count exceeds limit") if maximum_bytes < 0 || maximum_bytes > MAX_STRING_RANGE_BYTES
      output = Bytes.new(maximum_bytes)
      offset = 0
      each_mark_range_bytes(stream, start_mark, end_mark, maximum_bytes, element_width, exact_bytes: false) do |chunk|
        raise CorruptPartError.new("selected byte count exceeds allocation") if chunk.size > output.size - offset
        chunk.copy_to(output.to_unsafe + offset, chunk.size)
        offset += chunk.size
      end
      output[0, offset]
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
      LowCardinalityBinaryCodec.parse_index_mark(
        bytes,
        start_offset,
        end_offset,
        mark,
        mark_index,
        global_dictionary,
        shared_keys
      )
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
      LowCardinalityBinaryCodec.read_dictionary(bytes, offset, limit)
    end

    private def low_cardinality_read_u64(bytes : Bytes, offset : Int) : UInt64
      LowCardinalityBinaryCodec.read_u64(bytes, offset)
    end

    private def low_cardinality_read_string(bytes : Bytes, offset : Int) : {String, Int32}
      LowCardinalityBinaryCodec.read_string(bytes, offset)
    end

    private def low_cardinality_read_var_uint(bytes : Bytes, offset : Int) : {UInt64, Int32}
      LowCardinalityBinaryCodec.read_var_uint(bytes, offset)
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
      getter second_numeric_values : Bytes?
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
        @second_numeric_values : Bytes?,
        @null_map : Bytes?,
        @string_values : Bytes?,
      )
      end
    end

    private struct NumericMapPreflight
      getter outer_sizes : Array(UInt64)
      getter key_sizes : Array(UInt64)
      getter flat_elements : UInt64
      getter rows : UInt64
      getter key_payload_bytes : UInt64
      getter value_payload_bytes : UInt64
      getter payload_bytes : UInt64
      getter charge_bytes : UInt64
      getter null_payload_bytes : UInt64
      getter null_map : Bytes?

      def initialize(
        @outer_sizes : Array(UInt64),
        @key_sizes : Array(UInt64),
        @flat_elements : UInt64,
        @rows : UInt64,
        @key_payload_bytes : UInt64,
        @value_payload_bytes : UInt64,
        @payload_bytes : UInt64,
        @charge_bytes : UInt64,
        @null_payload_bytes : UInt64 = 0_u64,
        @null_map : Bytes? = nil,
      )
      end
    end

    private struct NumericArrayMapPreflight
      getter outer_sizes : Array(UInt64)
      getter key_sizes : Array(UInt64)
      getter value_sizes : Array(UInt64)
      getter entries : UInt64
      getter leaves : UInt64
      getter rows : UInt64
      getter key_payload_bytes : UInt64
      getter value_payload_bytes : UInt64
      getter payload_bytes : UInt64
      getter charge_bytes : UInt64
      getter null_payload_bytes : UInt64
      getter null_map : Bytes?

      def initialize(
        @outer_sizes : Array(UInt64),
        @key_sizes : Array(UInt64),
        @value_sizes : Array(UInt64),
        @entries : UInt64,
        @leaves : UInt64,
        @rows : UInt64,
        @key_payload_bytes : UInt64,
        @value_payload_bytes : UInt64,
        @payload_bytes : UInt64,
        @charge_bytes : UInt64,
        @null_payload_bytes : UInt64 = 0_u64,
        @null_map : Bytes? = nil,
      )
      end
    end

    # Shared, mark-preflighted counts for the exact W59
    # Array(Array(String)) shape. `inner_sizes` contains one String count per
    # flattened inner Array; `string_sizes` contains one byte length per leaf.
    private struct ArrayArrayStringComponents
      getter outer_sizes : Array(UInt64)
      getter inner_sizes : Array(UInt64)
      getter string_sizes : Array(UInt64)
      getter flat_inner_arrays : UInt64
      getter flat_strings : UInt64
      getter rows : UInt64
      getter string_bytes : UInt64

      def initialize(
        @outer_sizes : Array(UInt64),
        @inner_sizes : Array(UInt64),
        @string_sizes : Array(UInt64),
        @flat_inner_arrays : UInt64,
        @flat_strings : UInt64,
        @rows : UInt64,
        @string_bytes : UInt64,
      )
      end
    end

    # Shared mark-preflighted counts for W61. `inner_sizes` has one child
    # count per flattened inner Array; the leaf sizes and null map each have
    # one entry per flattened Nullable(String) slot.
    private struct ArrayArrayNullableStringComponents
      getter outer_sizes : Array(UInt64)
      getter inner_sizes : Array(UInt64)
      getter string_sizes : Array(UInt64)
      getter null_map : Bytes
      getter flat_inner_arrays : UInt64
      getter flat_strings : UInt64
      getter rows : UInt64
      getter string_bytes : UInt64

      def initialize(
        @outer_sizes : Array(UInt64),
        @inner_sizes : Array(UInt64),
        @string_sizes : Array(UInt64),
        @null_map : Bytes,
        @flat_inner_arrays : UInt64,
        @flat_strings : UInt64,
        @rows : UInt64,
        @string_bytes : UInt64,
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
      geometry_plan = GeometryColumnType.for_type(@column_type)
      point_plan = PointColumnType.for_type(@column_type)
      geo_array_plan = GeoArrayColumnType.for_type(@column_type)
      qbit_plan = QBitColumnType.for_type(@column_type)
      variant_plan = WidePart.variant_type_plan(@column_type)
      array_tuple_plan = WideArrayTupleTypePlan.for_type(@column_type)
      map_tuple_plan = WideMapTupleTypePlan.for_type(@column_type)
      legacy_array_tuple_plan = !WideTypePlan.admitted(@column_type).nil?
      dynamic_string = @column_type == "Dynamic"
      expected_mark_rows = nil.as(Array(UInt64)?)
      physical_streams.each do |stream_name|
        PartMetadataTextParser.validate_selected_stream_name(stream_name)
        data_path, mark_path, compressed_marks = resolve_stream(stream_name)
        if (variant_plan || dynamic_string) && compressed_marks
          raise UnsupportedFormatError.new("Variant and Dynamic require plain .mrk2 marks")
        end
        if qbit_plan && compressed_marks
          raise UnsupportedFormatError.new("QBit requires plain .mrk2 marks")
        end
        if point_plan && compressed_marks
          raise UnsupportedFormatError.new("Point requires plain .mrk2 marks")
        end
        if geo_array_plan && compressed_marks
          raise UnsupportedFormatError.new("Geo arrays require plain .mrk2 marks")
        end
        if geometry_plan && compressed_marks
          raise UnsupportedFormatError.new("Geometry requires plain .mrk2 marks")
        end
        if WidePart.supports_array_map_type?(@column_type) && compressed_marks
          raise UnsupportedFormatError.new("Array(Map) numeric profile requires plain .mrk2 marks")
        end
        data_size = File.size(data_path)
        raise CorruptPartError.new("data file exceeds limit") if data_size > MAX_DATA_FILE_BYTES
        if dynamic_string && (stream_name == "#{@column}.SharedVariant.size" || stream_name == "#{@column}.SharedVariant") && data_size != 0
          raise UnsupportedFormatError.new("Dynamic W74/W75 profile requires empty SharedVariant streams")
        end
        element_width = stream_element_width(stream_name)
        allow_empty_string_eof = if plan = variant_plan
                                   stream_name != plan.discriminator_stream(@column)
                                 elsif point_plan
                                   true
                                 elsif geo_array_plan
                                   stream_name != geo_array_plan.size_stream(@column, 0)
                                 elsif geometry_plan
                                   stream_name != geometry_plan.discriminator_stream(@column)
                                 elsif dynamic_string
                                   stream_name == "#{@column}.SharedVariant.size" ||
                                     stream_name == "#{@column}.SharedVariant" ||
                                     stream_name == "#{@column}.String.size" ||
                                     stream_name == "#{@column}.String" ||
                                     stream_name == "#{@column}.UInt64"
                                 elsif WidePart.supports_array_type?(@column_type)
                                   stream_name != "#{@column}.size0" &&
                                     WidePart.array_element_stream_names(@column, @column_type).not_nil!.includes?(stream_name)
                                 elsif array_tuple_plan && !legacy_array_tuple_plan
                                   stream_name != array_tuple_plan.outer_size_stream(@column)
                                 elsif map_tuple_plan
                                   stream_name != map_tuple_plan.outer_size_stream(@column)
                                 elsif WidePart.supports_array_map_type?(@column_type)
                                   array_map_stream_may_be_empty?(@column, stream_name)
                                 elsif WidePart.map_string_numeric_value_type(@column_type)
                                   stream_name == "#{@column}%2Ekeys.size" || stream_name == "#{@column}%2Ekeys" ||
                                     stream_name == "#{@column}%2Evalues"
                                 elsif WidePart.map_string_nullable_numeric_value_type(@column_type)
                                   stream_name == "#{@column}%2Ekeys.size" || stream_name == "#{@column}%2Ekeys" ||
                                     stream_name == "#{@column}%2Evalues.null" || stream_name == "#{@column}%2Evalues"
                                 elsif WidePart.map_uint64_numeric_value_type(@column_type)
                                   stream_name == "#{@column}%2Ekeys" || stream_name == "#{@column}%2Evalues"
                                 elsif WidePart.map_uint64_nullable_numeric_value_type(@column_type)
                                   stream_name == "#{@column}%2Ekeys" || stream_name == "#{@column}%2Evalues.null" ||
                                     stream_name == "#{@column}%2Evalues"
                                 elsif WidePart.supports_map_uint64_string_type?(@column_type)
                                   stream_name == "#{@column}%2Ekeys" || stream_name == "#{@column}%2Evalues.size" || stream_name == "#{@column}%2Evalues"
                                 elsif WidePart.supports_map_uint64_uint64_type?(@column_type)
                                   stream_name == "#{@column}%2Ekeys" || stream_name == "#{@column}%2Evalues"
                                 elsif WidePart.supports_map_uint64_nullable_uint64_type?(@column_type)
                                   stream_name == "#{@column}%2Ekeys" || stream_name == "#{@column}%2Evalues.null" || stream_name == "#{@column}%2Evalues"
                                 elsif WidePart.supports_map_uint64_array_nullable_uint64_type?(@column_type)
                                   stream_name == "#{@column}%2Ekeys" || stream_name == "#{@column}%2Evalues.size1" ||
                                     stream_name == "#{@column}%2Evalues.null" || stream_name == "#{@column}%2Evalues"
                                 elsif WidePart.supports_map_uint64_array_uint64_type?(@column_type)
                                   stream_name == "#{@column}%2Ekeys" || stream_name == "#{@column}%2Evalues.size1" ||
                                     stream_name == "#{@column}%2Evalues"
                                 elsif WidePart.supports_map_uint64_array_nullable_string_type?(@column_type)
                                   stream_name == "#{@column}%2Ekeys" || stream_name == "#{@column}%2Evalues.size1" ||
                                     stream_name == "#{@column}%2Evalues.null" || stream_name == "#{@column}%2Evalues.size" ||
                                     stream_name == "#{@column}%2Evalues"
                                 elsif WidePart.supports_map_uint64_array_string_type?(@column_type)
                                   stream_name == "#{@column}%2Ekeys" || stream_name == "#{@column}%2Evalues.size1" ||
                                     stream_name == "#{@column}%2Evalues.size" || stream_name == "#{@column}%2Evalues"
                                 elsif WidePart.supports_map_string_array_string_type?(@column_type)
                                   stream_name == "#{@column}%2Ekeys.size" || stream_name == "#{@column}%2Ekeys" ||
                                     stream_name == "#{@column}%2Evalues.size1" || stream_name == "#{@column}%2Evalues.size" ||
                                     stream_name == "#{@column}%2Evalues"
                                 elsif WidePart.supports_map_string_uint64_type?(@column_type)
                                   stream_name == "#{@column}%2Ekeys.size" || stream_name == "#{@column}%2Ekeys" || stream_name == "#{@column}%2Evalues"
                                 elsif WidePart.supports_map_string_array_nullable_uint64_type?(@column_type)
                                   stream_name == "#{@column}%2Ekeys.size" || stream_name == "#{@column}%2Ekeys" ||
                                     stream_name == "#{@column}%2Evalues.size1" || stream_name == "#{@column}%2Evalues.null" ||
                                     stream_name == "#{@column}%2Evalues"
                                 elsif WidePart.map_string_array_nullable_numeric_value_type(@column_type)
                                   stream_name == "#{@column}%2Ekeys.size" || stream_name == "#{@column}%2Ekeys" ||
                                     stream_name == "#{@column}%2Evalues.size1" || stream_name == "#{@column}%2Evalues.null" ||
                                     stream_name == "#{@column}%2Evalues"
                                 elsif WidePart.supports_map_string_array_nullable_string_type?(@column_type)
                                   stream_name == "#{@column}%2Ekeys.size" || stream_name == "#{@column}%2Ekeys" ||
                                     stream_name == "#{@column}%2Evalues.size1" || stream_name == "#{@column}%2Evalues.null" ||
                                     stream_name == "#{@column}%2Evalues.size" || stream_name == "#{@column}%2Evalues"
                                 elsif WidePart.supports_map_string_array_uint64_type?(@column_type)
                                   stream_name == "#{@column}%2Ekeys.size" || stream_name == "#{@column}%2Ekeys" ||
                                     stream_name == "#{@column}%2Evalues.size1" || stream_name == "#{@column}%2Evalues"
                                 elsif WidePart.map_string_array_numeric_value_type(@column_type)
                                   stream_name == "#{@column}%2Ekeys.size" || stream_name == "#{@column}%2Ekeys" ||
                                     stream_name == "#{@column}%2Evalues.size1" || stream_name == "#{@column}%2Evalues"
                                 elsif WidePart.map_uint64_array_nullable_numeric_value_type(@column_type)
                                   stream_name == "#{@column}%2Ekeys" || stream_name == "#{@column}%2Evalues.size1" ||
                                     stream_name == "#{@column}%2Evalues.null" || stream_name == "#{@column}%2Evalues"
                                 elsif WidePart.map_uint64_array_numeric_value_type(@column_type)
                                   stream_name == "#{@column}%2Ekeys" || stream_name == "#{@column}%2Evalues.size1" ||
                                     stream_name == "#{@column}%2Evalues"
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
                                 elsif tuple_plan = WideTupleTypePlan.for_type(@column_type)
                                   tuple_plan.raw_string_stream?(@column, stream_name)
                                 else
                                   (@column_type == "String" || WidePart.supports_nullable_string_type?(@column_type)) && stream_name == @column
                                 end
        mark_row_width = if variant_plan
                           1
                         elsif geometry_plan
                           1
                         elsif dynamic_string && stream_name == "#{@column}.variant_discr"
                           1
                         elsif geo_array_plan
                           stream_name == geo_array_plan.size_stream(@column, 0) ? 8 : 1
                         elsif array_tuple_plan && !legacy_array_tuple_plan
                           stream_name == array_tuple_plan.outer_size_stream(@column) ? 8 : 1
                         elsif map_tuple_plan
                           stream_name == map_tuple_plan.outer_size_stream(@column) ? 8 : 1
                         elsif stream_name != "#{@column}.size0" &&
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
                              mark_row_width: mark_row_width,
                              alignment_width: qbit_plan ? 1 : nil,
                              required_first_mark_decompressed_offset: if (!!variant_plan &&
                                                                           stream_name == variant_plan.not_nil!.discriminator_stream(@column)) ||
                                                                          (!!geometry_plan &&
                                                                           stream_name == geometry_plan.not_nil!.discriminator_stream(@column)) ||
                                                                          dynamic_string && stream_name == "#{@column}.variant_discr"
                                8_u64
                              elsif dynamic_string && stream_name == "#{@column}.dynamic_structure"
                                nil
                              else
                                0_u64
                              end
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

      validate_dynamic_string_structure if dynamic_string

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
      columns = PartMetadataTextParser.parse_columns(columns_text)
      if columns.empty?
        raise UnsupportedFormatError.new("columns.txt contains no columns")
      end
      if requested_column.nil? && columns.size > 1
        raise UnsupportedFormatError.new("column is required for a multi-column part")
      end
      column = requested_column || columns[0][0]
      selected, source_column_name, source_column_type, column_type, json_typed_path =
        resolve_selected_column(columns, column)
      geometry_plan = GeometryColumnType.for_type(column_type)
      point_plan = PointColumnType.for_type(column_type)
      geo_array_plan = GeoArrayColumnType.for_type(column_type)
      array_tuple_plan = WideArrayTupleTypePlan.for_type(column_type)
      generic_array_tuple = !array_tuple_plan.nil? && WideTypePlan.admitted(column_type).nil?
      map_tuple_plan = WideMapTupleTypePlan.for_type(column_type)
      generic_map_tuple = !map_tuple_plan.nil?
      raise UnsupportedFormatError.new("JSON typed paths require the exact typed scan") if json_typed_path && mode != :typed
      case mode
      when :numeric
        numeric_type_width(column_type)
      when :typed
        raise UnsupportedFormatError.new("unsupported exact typed column") unless WidePart.supports_typed_type?(column_type)
      else
        raise UnsupportedFormatError.new("only exact UInt64 columns are supported") unless column_type == "UInt64"
      end

      codec = validate_default_codec
      if (geometry_plan || geo_array_plan || point_plan || WidePart.supports_variant_type?(column_type) || column_type == "Dynamic" || generic_array_tuple || generic_map_tuple ||
         WidePart.supports_array_map_type?(column_type) || !QBitColumnType.for_type(column_type).nil?) && codec != "CODEC(LZ4)"
        message = if geo_array_plan
                    "Geo Array bounded profile requires CODEC(LZ4)"
                  elsif geometry_plan
                    "Geometry bounded profile requires CODEC(LZ4)"
                  elsif point_plan
                    "Point bounded profile requires CODEC(LZ4)"
                  elsif !QBitColumnType.for_type(column_type).nil?
                    "QBit bounded profile requires CODEC(LZ4)"
                  elsif WidePart.supports_array_map_type?(column_type)
                    "Array(Map) bounded profile requires CODEC(LZ4)"
                  elsif generic_array_tuple
                    "Array(Tuple) bounded profile requires CODEC(LZ4)"
                  elsif generic_map_tuple
                    "Map(Tuple) bounded profile requires CODEC(LZ4)"
                  else
                    "Variant and Dynamic require CODEC(LZ4)"
                  end
        raise UnsupportedFormatError.new(message)
      end
      row_count = parse_count_file("count.txt")
      raise CorruptPartError.new("row count exceeds limit") if row_count > MAX_ROWS

      json_paths = [] of {String, String}
      if geometry_plan
        validate_geometry_serialization_profile(columns, selected, row_count)
      elsif geo_array_plan
        validate_geo_array_serialization_profile(columns, selected, row_count)
      elsif point_plan
        validate_point_serialization_profile(columns, selected, row_count)
      elsif QBitColumnType.for_type(column_type)
        validate_qbit_serialization_profile
      elsif json_typed_path
        json_paths = WidePart.json_typed_paths(source_column_type)
        validate_json_typed_path_serialization(source_column_name, json_paths)
      elsif column_type == "LowCardinality(String)"
        validate_low_cardinality_string_serialization(columns, selected, row_count)
      elsif WidePart.supports_array_map_array_leaf_type?(column_type)
        validate_array_map_array_leaf_serialization(columns, selected, column_type)
      elsif WidePart.supports_array_map_string_uint64_type?(column_type)
        validate_array_map_string_uint64_serialization(columns, selected)
      elsif WidePart.supports_array_map_string_leaf_type?(column_type)
        validate_array_map_string_leaf_serialization(columns, selected, column_type)
      elsif WidePart.supports_array_map_bool_leaf_type?(column_type)
        validate_array_map_bool_leaf_serialization(columns, selected, column_type)
      elsif WidePart.supports_array_map_numeric_type?(column_type)
        validate_array_map_numeric_serialization(columns, selected, column_type)
      elsif generic_array_tuple
        validate_array_type_serialization_version(column_type, columns, selected, row_count)
      elsif generic_map_tuple
        validate_map_serialization(columns, selected, row_count, column_type)
      elsif WidePart.supports_array_type?(column_type)
        validate_array_type_serialization_version(column_type, columns, selected, row_count)
      elsif WidePart.supports_map_uint64_string_type?(column_type)
        validate_map_serialization(columns, selected, row_count, column_type)
      elsif WidePart.supports_map_uint64_uint64_type?(column_type)
        validate_map_serialization(columns, selected, row_count, column_type)
      elsif WidePart.supports_numeric_map_array_type?(column_type)
        validate_map_serialization(columns, selected, row_count, column_type)
      elsif WidePart.supports_nullable_numeric_map_array_type?(column_type)
        validate_map_serialization(columns, selected, row_count, column_type)
      elsif WidePart.supports_numeric_map_type?(column_type)
        validate_map_serialization(columns, selected, row_count, column_type)
      elsif WidePart.supports_nullable_numeric_map_type?(column_type)
        validate_map_serialization(columns, selected, row_count, column_type)
      elsif WidePart.supports_map_string_uint64_type?(column_type) || WidePart.supports_map_string_array_uint64_type?(column_type) ||
            WidePart.supports_map_string_array_nullable_uint64_type?(column_type) ||
            WidePart.supports_map_string_array_nullable_string_type?(column_type) ||
            WidePart.supports_map_uint64_array_nullable_uint64_type?(column_type) ||
            WidePart.supports_map_uint64_array_nullable_string_type?(column_type) ||
            WidePart.supports_map_uint64_array_uint64_type?(column_type) ||
            WidePart.supports_map_uint64_array_string_type?(column_type) ||
            WidePart.supports_map_string_array_string_type?(column_type) ||
            WidePart.supports_map_string_string_type?(column_type) ||
            WidePart.supports_map_uint64_nullable_uint64_type?(column_type) || WidePart.supports_map_string_nullable_uint64_type?(column_type) ||
            WidePart.supports_map_uint64_nullable_string_type?(column_type) || WidePart.supports_map_string_nullable_string_type?(column_type)
        validate_map_serialization(columns, selected, row_count, column_type)
      elsif WidePart.supports_variant_type?(column_type)
        validate_variant_serialization(columns, selected, row_count)
      elsif column_type == "Dynamic"
        validate_dynamic_string_serialization(columns, selected, row_count)
      elsif WidePart.supports_named_scalar_tuple_type?(column_type)
        validate_tuple_uint64_string_serialization(columns, selected, column_type, row_count)
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

    private def validate_qbit_serialization_profile : Nil
      file = File.join(@path, "serialization.json")
      raise UnsupportedFormatError.new("serialization.json is required for QBit") unless File.file?(file)
      raise CorruptPartError.new("serialization.json must not be a symbolic link") if File.symlink?(file)
      size = File.size(file)
      raise UnsupportedFormatError.new("serialization.json exceeds metadata limit") if size > MAX_METADATA_FILE_BYTES
      text = File.read(file)
      raise CorruptPartError.new("serialization.json changed while reading") unless text.bytesize == size

      QBitSerializationProfile.validate!(text)
    end

    private def validate_geo_array_serialization_profile(
      columns : Array({String, String}),
      selected_column : String,
      row_count : UInt64,
    ) : Nil
      file = File.join(@path, "serialization.json")
      raise UnsupportedFormatError.new("serialization.json is required for Geo arrays") unless File.file?(file)
      raise CorruptPartError.new("serialization.json must not be a symbolic link") if File.symlink?(file)
      size = File.size(file)
      raise UnsupportedFormatError.new("serialization.json exceeds metadata limit") if size > MAX_METADATA_FILE_BYTES
      text = File.read(file)
      raise CorruptPartError.new("serialization.json changed while reading") unless text.bytesize == size
      GeoArraySerializationProfile.validate!(text, columns, selected_column, row_count)
    end

    private def validate_geometry_serialization_profile(
      columns : Array({String, String}),
      selected_column : String,
      row_count : UInt64,
    ) : Nil
      file = File.join(@path, "serialization.json")
      raise UnsupportedFormatError.new("serialization.json is required for Geometry") unless File.file?(file)
      raise CorruptPartError.new("serialization.json must not be a symbolic link") if File.symlink?(file)
      size = File.size(file)
      raise UnsupportedFormatError.new("serialization.json exceeds metadata limit") if size > MAX_METADATA_FILE_BYTES
      text = File.read(file)
      raise CorruptPartError.new("serialization.json changed while reading") unless text.bytesize == size

      GeometrySerializationProfile.validate!(text, columns, selected_column, row_count)
    end

    private def validate_point_serialization_profile(
      columns : Array({String, String}),
      selected_column : String,
      row_count : UInt64,
    ) : Nil
      file = File.join(@path, "serialization.json")
      raise UnsupportedFormatError.new("serialization.json is required for Point") unless File.file?(file)
      raise CorruptPartError.new("serialization.json must not be a symbolic link") if File.symlink?(file)
      size = File.size(file)
      raise UnsupportedFormatError.new("serialization.json exceeds metadata limit") if size > MAX_METADATA_FILE_BYTES
      text = File.read(file)
      raise CorruptPartError.new("serialization.json changed while reading") unless text.bytesize == size

      PointSerializationProfile.validate!(text, columns, selected_column, row_count)
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

    private def validate_default_codec : String
      file = File.join(@path, "default_compression_codec.txt")
      raise CorruptPartError.new("default_compression_codec.txt must not be a symbolic link") if File.symlink?(file)
      size = File.size(file)
      raise UnsupportedFormatError.new("default codec exceeds metadata limit") if size > MAX_CODEC_FILE_BYTES
      codec = File.read(file)
      unless codec.bytesize == size && (codec == "CODEC(LZ4)" || codec == "CODEC(ZSTD(1))")
        raise UnsupportedFormatError.new("only CODEC(LZ4) and CODEC(ZSTD(1)) are supported")
      end
      codec
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
      PartMetadataTextParser.require_metadata_line(bytes, cursor, "columns substreams version: 1", "columns_substreams.txt")
      cursor += PartMetadataTextParser.line_length(bytes, cursor)
      count_line = PartMetadataTextParser.metadata_line(bytes, cursor, "columns_substreams.txt")
      cursor += PartMetadataTextParser.line_length(bytes, cursor)
      count = PartMetadataTextParser.parse_count_line(count_line, " columns:", MAX_METADATA_COLUMNS, "columns_substreams.txt")
      raise UnsupportedFormatError.new("column count does not match") unless count == columns.size

      seen_columns = Set(String).new
      seen_streams = Set(String).new
      selected_streams = nil.as(Array(String)?)
      count.times do |index|
        line = PartMetadataTextParser.metadata_line(bytes, cursor, "columns_substreams.txt")
        cursor += PartMetadataTextParser.line_length(bytes, cursor)
        stream_count, column = PartMetadataTextParser.parse_substream_header(line)
        expected_column = columns[index][0]
        raise UnsupportedFormatError.new("column order does not match") unless column == expected_column
        raise UnsupportedFormatError.new("duplicate column block") if seen_columns.includes?(column)
        seen_columns << column
        streams = Array(String).new(stream_count)
        stream_count.times do
          stream_line = PartMetadataTextParser.metadata_line(bytes, cursor, "columns_substreams.txt")
          cursor += PartMetadataTextParser.line_length(bytes, cursor)
          raise UnsupportedFormatError.new("invalid physical stream name") unless stream_line.starts_with?("\t")
          stream_bytes = stream_line.to_slice
          stream = String.new(stream_bytes[1, stream_bytes.size - 1])
          PartMetadataTextParser.validate_opaque_name(stream)
          raise UnsupportedFormatError.new("duplicate physical stream name") if seen_streams.includes?(stream)
          seen_streams << stream
          streams << stream
        end
        if column == source_column
          if json_paths.empty?
            if selected_type == "Dynamic"
              raise UnsupportedFormatError.new("Dynamic physical substreams do not match a supported arm subset") unless valid_dynamic_substream_inventory?(column, streams)
            else
              expected_streams = expected_physical_streams(column, selected_type)
              raise UnsupportedFormatError.new("selected physical substreams do not match exact serialization shape") unless streams == expected_streams
            end
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
        elsif WideMapTupleTypePlan.for_type(selected_type)
          if columns.any? { |name, type| name == column && type == "UInt64" }
            raise UnsupportedFormatError.new("Map(Tuple) key column must have one plain UInt64 stream") unless streams == [column]
          end
        elsif PointColumnType.for_type(selected_type)
          if columns.any? { |name, type| name == column && type == "UInt64" }
            raise UnsupportedFormatError.new("Point primary key column must have one plain UInt64 stream") unless streams == [column]
          end
        elsif GeoArrayColumnType.for_type(selected_type)
          if columns.any? { |name, type| name == column && type == "UInt64" }
            raise UnsupportedFormatError.new("Geo Array primary key column must have one plain UInt64 stream") unless streams == [column]
          end
        elsif GeometryColumnType.for_type(selected_type)
          if columns.any? { |name, type| name == column && type == "UInt64" }
            raise UnsupportedFormatError.new("Geometry primary key column must have one plain UInt64 stream") unless streams == [column]
          end
        elsif WideArrayTupleTypePlan.for_type(selected_type) && WideTypePlan.admitted(selected_type).nil?
          if columns.any? { |name, type| name == column && type == "UInt64" }
            raise UnsupportedFormatError.new("Array(Tuple) key column must have one plain UInt64 stream") unless streams == [column]
          end
        elsif WidePart.supports_named_scalar_tuple_type?(selected_type)
          raise UnsupportedFormatError.new("Tuple key column must have one plain UInt64 stream") unless streams == [column]
        elsif WidePart.supports_variant_type?(selected_type)
          raise UnsupportedFormatError.new("Variant key column must have one plain UInt64 stream") unless streams == [column]
        elsif WidePart.supports_map_uint64_string_type?(selected_type) || WidePart.supports_map_uint64_uint64_type?(selected_type) ||
              WidePart.supports_numeric_map_type?(selected_type) || WidePart.supports_nullable_numeric_map_type?(selected_type) ||
              WidePart.supports_numeric_map_array_type?(selected_type) ||
              WidePart.supports_nullable_numeric_map_array_type?(selected_type) ||
              WidePart.supports_map_string_uint64_type?(selected_type) || WidePart.supports_map_string_array_uint64_type?(selected_type) ||
              WidePart.supports_map_string_array_nullable_uint64_type?(selected_type) ||
              WidePart.supports_map_string_array_nullable_string_type?(selected_type) ||
              WidePart.supports_map_uint64_array_nullable_uint64_type?(selected_type) ||
              WidePart.supports_map_uint64_array_nullable_string_type?(selected_type) ||
              WidePart.supports_map_uint64_array_uint64_type?(selected_type) ||
              WidePart.supports_map_uint64_array_string_type?(selected_type) ||
              WidePart.supports_map_string_array_string_type?(selected_type) ||
              WidePart.supports_map_string_string_type?(selected_type) ||
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
      if type == "Dynamic"
        ["#{column}.dynamic_structure", "#{column}.variant_discr", "#{column}.SharedVariant.size", "#{column}.SharedVariant", "#{column}.String.size", "#{column}.String"]
      elsif plan = GeometryColumnType.for_type(type)
        plan.physical_streams(column).map(&.[0])
      elsif variant_plan = WidePart.variant_type_plan(type)
        variant_plan.physical_streams(column)
      elsif type == "LowCardinality(String)"
        ["#{column}.dict", column]
      elsif plan = QBitColumnType.for_type(type)
        plan.physical_streams(column).map(&.[0])
      elsif plan = PointColumnType.for_type(type)
        plan.physical_streams(column).map(&.[0])
      elsif plan = GeoArrayColumnType.for_type(type)
        plan.size_streams(column) + plan.coordinate_streams(column).to_a
      elsif plan = WideTypePlan.admitted(type)
        plan.physical_streams(column).map(&.name)
      elsif plan = WideArrayTupleTypePlan.for_type(type)
        plan.physical_streams(column)
      elsif plan = WideMapTupleTypePlan.for_type(type)
        plan.physical_streams(column)
      elsif tuple_plan = WideTupleTypePlan.for_type(type)
        tuple_plan.physical_streams(column)
      elsif WidePart.supports_array_map_type?(type)
        plan = WideTypePlan::WidePhysicalPlanShadow.for_type(type, column) ||
               raise UnsupportedFormatError.new("no physical plan for exact Array(Map) column")
        plan.streams.map(&.name)
      elsif element_streams = WidePart.array_element_stream_names(column, type)
        ["#{column}.size0"] + element_streams
      elsif WidePart.supports_map_uint64_string_type?(type)
        ["#{column}.size0", "#{column}%2Ekeys", "#{column}%2Evalues.size", "#{column}%2Evalues"]
      elsif WidePart.supports_map_uint64_uint64_type?(type)
        ["#{column}.size0", "#{column}%2Ekeys", "#{column}%2Evalues"]
      elsif WidePart.supports_numeric_map_type?(type)
        if WidePart.map_uint64_numeric_value_type(type)
          ["#{column}.size0", "#{column}%2Ekeys", "#{column}%2Evalues"]
        else
          ["#{column}.size0", "#{column}%2Ekeys.size", "#{column}%2Ekeys", "#{column}%2Evalues"]
        end
      elsif WidePart.supports_nullable_numeric_map_type?(type)
        if WidePart.map_uint64_nullable_numeric_value_type(type)
          ["#{column}.size0", "#{column}%2Ekeys", "#{column}%2Evalues.null", "#{column}%2Evalues"]
        else
          ["#{column}.size0", "#{column}%2Ekeys.size", "#{column}%2Ekeys", "#{column}%2Evalues.null", "#{column}%2Evalues"]
        end
      elsif WidePart.supports_map_uint64_nullable_uint64_type?(type)
        ["#{column}.size0", "#{column}%2Ekeys", "#{column}%2Evalues.null", "#{column}%2Evalues"]
      elsif !WidePart.map_uint64_array_numeric_value_type(type).nil?
        ["#{column}.size0", "#{column}%2Ekeys", "#{column}%2Evalues.size1", "#{column}%2Evalues"]
      elsif WidePart.supports_map_uint64_array_nullable_uint64_type?(type)
        ["#{column}.size0", "#{column}%2Ekeys", "#{column}%2Evalues.size1", "#{column}%2Evalues.null", "#{column}%2Evalues"]
      elsif value_type = WidePart.map_uint64_array_nullable_numeric_value_type(type)
        ["#{column}.size0", "#{column}%2Ekeys", "#{column}%2Evalues.size1", "#{column}%2Evalues.null", "#{column}%2Evalues"]
      elsif WidePart.supports_map_uint64_array_uint64_type?(type)
        ["#{column}.size0", "#{column}%2Ekeys", "#{column}%2Evalues.size1", "#{column}%2Evalues"]
      elsif WidePart.supports_map_uint64_array_nullable_string_type?(type)
        ["#{column}.size0", "#{column}%2Ekeys", "#{column}%2Evalues.size1", "#{column}%2Evalues.null", "#{column}%2Evalues.size", "#{column}%2Evalues"]
      elsif WidePart.supports_map_uint64_array_string_type?(type)
        ["#{column}.size0", "#{column}%2Ekeys", "#{column}%2Evalues.size1", "#{column}%2Evalues.size", "#{column}%2Evalues"]
      elsif WidePart.supports_map_string_array_string_type?(type)
        ["#{column}.size0", "#{column}%2Ekeys.size", "#{column}%2Ekeys", "#{column}%2Evalues.size1", "#{column}%2Evalues.size", "#{column}%2Evalues"]
      elsif WidePart.supports_map_string_uint64_type?(type)
        ["#{column}.size0", "#{column}%2Ekeys.size", "#{column}%2Ekeys", "#{column}%2Evalues"]
      elsif !WidePart.map_string_array_numeric_value_type(type).nil?
        ["#{column}.size0", "#{column}%2Ekeys.size", "#{column}%2Ekeys", "#{column}%2Evalues.size1", "#{column}%2Evalues"]
      elsif WidePart.supports_map_string_array_uint64_type?(type)
        ["#{column}.size0", "#{column}%2Ekeys.size", "#{column}%2Ekeys", "#{column}%2Evalues.size1", "#{column}%2Evalues"]
      elsif WidePart.supports_map_string_array_nullable_uint64_type?(type)
        ["#{column}.size0", "#{column}%2Ekeys.size", "#{column}%2Ekeys", "#{column}%2Evalues.size1", "#{column}%2Evalues.null", "#{column}%2Evalues"]
      elsif value_type = WidePart.map_string_array_nullable_numeric_value_type(type)
        ["#{column}.size0", "#{column}%2Ekeys.size", "#{column}%2Ekeys", "#{column}%2Evalues.size1", "#{column}%2Evalues.null", "#{column}%2Evalues"]
      elsif WidePart.supports_map_string_array_nullable_string_type?(type)
        ["#{column}.size0", "#{column}%2Ekeys.size", "#{column}%2Ekeys", "#{column}%2Evalues.size1", "#{column}%2Evalues.null", "#{column}%2Evalues.size", "#{column}%2Evalues"]
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

    private def validate_array_map_array_leaf_serialization(
      columns : Array({String, String}),
      selected_column : String,
      selected_type : String,
    ) : Nil
      payload_columns = columns.reject { |_, type| type == "UInt64" }
      unless WidePart.supports_array_map_array_leaf_type?(selected_type) &&
             columns.any? { |name, type| name == selected_column && type == selected_type } &&
             columns.size >= 2 && columns.count { |_, type| type == "UInt64" } == 1 &&
             !payload_columns.empty? && payload_columns.all? { |_, type| WidePart.supports_array_map_array_leaf_type?(type) }
        raise UnsupportedFormatError.new("#{selected_type} requires one UInt64 sorting key and exact W84 payload columns")
      end

      file = File.join(@path, "serialization.json")
      raise UnsupportedFormatError.new("serialization.json is required for this type") unless File.file?(file)
      raise CorruptPartError.new("serialization.json must not be a symbolic link") if File.symlink?(file)
      size = File.size(file)
      raise UnsupportedFormatError.new("serialization.json exceeds metadata limit") if size > MAX_METADATA_FILE_BYTES
      text = File.read(file)
      raise CorruptPartError.new("serialization.json changed while reading") unless text.bytesize == size

      info = JSON.parse(text).as_h
      expected_fields = Set{"version", "columns", "types_serialization_versions", "propagate_types_serialization_versions_to_nested_types"}
      raise UnsupportedFormatError.new("unsupported W84 serialization.json fields") unless info.keys.to_set == expected_fields
      version = info["version"]?.try(&.as_i) || raise(CorruptPartError.new("serialization.json version is missing or malformed"))
      raise UnsupportedFormatError.new("only serialization.json version 1 is supported") unless version == 1
      propagated = info["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool)
      raise UnsupportedFormatError.new("W84 nested serialization versions are unsupported") unless propagated == true

      versions = info["types_serialization_versions"]?.try(&.as_h) ||
                 raise(CorruptPartError.new("serialization type versions are missing or malformed"))
      valid_versions = versions.size == 1 && versions["string"]?.try(&.as_i) == 1
      raise UnsupportedFormatError.new("W84 requires nested String serialization version 1") unless valid_versions
      serializers = info["columns"]?.try(&.as_a) ||
                    raise(CorruptPartError.new("serialization column serializers are missing or malformed"))
      raise UnsupportedFormatError.new("W84 per-column serializers are unsupported") unless serializers.empty?
      nil
    rescue ex : JSON::ParseException | TypeCastError | OverflowError
      raise CorruptPartError.new("serialization.json is malformed")
    end

    private def validate_array_map_string_uint64_serialization(
      columns : Array({String, String}),
      selected_column : String,
    ) : Nil
      selected_type = columns.find { |name, _| name == selected_column }.try(&.[1])
      key_columns = columns.select { |name, type| name != selected_column && type == "UInt64" }
      unless columns.size == 2 && selected_type == "Array(Map(String, UInt64))" && key_columns.size == 1 &&
             columns.count { |_, type| type == "UInt64" } == 1
        raise UnsupportedFormatError.new("Array(Map(String, UInt64)) requires one UInt64 key column")
      end

      file = File.join(@path, "serialization.json")
      raise UnsupportedFormatError.new("serialization.json is required for this type") unless File.file?(file)
      raise CorruptPartError.new("serialization.json must not be a symbolic link") if File.symlink?(file)
      size = File.size(file)
      raise UnsupportedFormatError.new("serialization.json exceeds metadata limit") if size > MAX_METADATA_FILE_BYTES
      text = File.read(file)
      raise CorruptPartError.new("serialization.json changed while reading") unless text.bytesize == size

      info = JSON.parse(text).as_h
      expected_fields = Set{"version", "columns", "types_serialization_versions", "propagate_types_serialization_versions_to_nested_types"}
      unless info.keys.to_set == expected_fields
        raise UnsupportedFormatError.new("unsupported Array(Map) serialization.json fields")
      end
      version = info["version"]?.try(&.as_i) || raise(CorruptPartError.new("serialization.json version is missing or malformed"))
      raise UnsupportedFormatError.new("only serialization.json version 1 is supported") unless version == 1
      propagated = info["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool)
      raise UnsupportedFormatError.new("Array(Map) nested serialization versions are unsupported") unless propagated == true

      versions = info["types_serialization_versions"]?.try(&.as_h) ||
                 raise(CorruptPartError.new("serialization type versions are missing or malformed"))
      unless versions.size == 1 && versions["string"]?.try(&.as_i) == 1
        raise UnsupportedFormatError.new("only nested String serialization version 1 is supported for Array(Map)")
      end
      serializers = info["columns"]?.try(&.as_a) ||
                    raise(CorruptPartError.new("Array(Map) column serializers are missing or malformed"))
      raise UnsupportedFormatError.new("Array(Map) per-column serializers are unsupported") unless serializers.empty?
      nil
    rescue ex : JSON::ParseException | TypeCastError | OverflowError
      raise CorruptPartError.new("serialization.json is malformed")
    end

    private def validate_array_map_string_leaf_serialization(
      columns : Array({String, String}),
      selected_column : String,
      selected_type : String,
    ) : Nil
      payload_columns = columns.reject { |_, type| type == "UInt64" }
      unless WidePart.supports_array_map_string_leaf_type?(selected_type) && columns.size >= 2 &&
             columns.count { |_, type| type == "UInt64" } == 1 && !payload_columns.empty? &&
             payload_columns.all? { |_, type| WidePart.supports_array_map_string_leaf_type?(type) }
        raise UnsupportedFormatError.new("#{selected_type} requires one UInt64 sorting-key column")
      end

      file = File.join(@path, "serialization.json")
      raise UnsupportedFormatError.new("serialization.json is required for this type") unless File.file?(file)
      raise CorruptPartError.new("serialization.json must not be a symbolic link") if File.symlink?(file)
      size = File.size(file)
      raise UnsupportedFormatError.new("serialization.json exceeds metadata limit") if size > MAX_METADATA_FILE_BYTES
      text = File.read(file)
      raise CorruptPartError.new("serialization.json changed while reading") unless text.bytesize == size

      info = JSON.parse(text).as_h
      expected_fields = Set{"version", "columns", "types_serialization_versions", "propagate_types_serialization_versions_to_nested_types"}
      raise UnsupportedFormatError.new("unsupported Array(Map) serialization.json fields") unless info.keys.to_set == expected_fields
      version = info["version"]?.try(&.as_i) || raise(CorruptPartError.new("serialization.json version is missing or malformed"))
      raise UnsupportedFormatError.new("only serialization.json version 1 is supported") unless version == 1
      propagated = info["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool)
      raise UnsupportedFormatError.new("Array(Map) nested serialization versions are unsupported") unless propagated == true

      versions = info["types_serialization_versions"]?.try(&.as_h) ||
                 raise(CorruptPartError.new("serialization type versions are missing or malformed"))
      unless versions.size == 1 && versions["string"]?.try(&.as_i) == 1
        raise UnsupportedFormatError.new("only nested String serialization version 1 is supported for Array(Map)")
      end
      serializers = info["columns"]?.try(&.as_a) ||
                    raise(CorruptPartError.new("Array(Map) column serializers are missing or malformed"))
      raise UnsupportedFormatError.new("Array(Map) per-column serializers are unsupported") unless serializers.empty?
      nil
    rescue ex : JSON::ParseException | TypeCastError | OverflowError
      raise CorruptPartError.new("serialization.json is malformed")
    end

    private def validate_array_map_bool_leaf_serialization(
      columns : Array({String, String}),
      selected_column : String,
      selected_type : String,
    ) : Nil
      payload_columns = columns.reject { |_, type| type == "UInt64" }
      unless WidePart.supports_array_map_bool_leaf_type?(selected_type) &&
             columns.any? { |name, type| name == selected_column && type == selected_type } && columns.size >= 2 &&
             columns.count { |_, type| type == "UInt64" } == 1 && !payload_columns.empty? &&
             payload_columns.all? { |_, type| WidePart.supports_array_map_bool_leaf_type?(type) }
        raise UnsupportedFormatError.new("#{selected_type} requires one UInt64 sorting-key column and exact W83 payload columns")
      end

      file = File.join(@path, "serialization.json")
      raise UnsupportedFormatError.new("serialization.json is required for this type") unless File.file?(file)
      raise CorruptPartError.new("serialization.json must not be a symbolic link") if File.symlink?(file)
      size = File.size(file)
      raise UnsupportedFormatError.new("serialization.json exceeds metadata limit") if size > MAX_METADATA_FILE_BYTES
      text = File.read(file)
      raise CorruptPartError.new("serialization.json changed while reading") unless text.bytesize == size

      info = JSON.parse(text).as_h
      expected_fields = Set{"version", "columns", "types_serialization_versions", "propagate_types_serialization_versions_to_nested_types"}
      raise UnsupportedFormatError.new("unsupported Array(Map) serialization.json fields") unless info.keys.to_set == expected_fields
      version = info["version"]?.try(&.as_i) || raise(CorruptPartError.new("serialization.json version is missing or malformed"))
      raise UnsupportedFormatError.new("only serialization.json version 1 is supported") unless version == 1
      propagated = info["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool)
      raise UnsupportedFormatError.new("Array(Map) nested serialization versions are unsupported") unless propagated == true

      versions = info["types_serialization_versions"]?.try(&.as_h) ||
                 raise(CorruptPartError.new("serialization type versions are missing or malformed"))
      unless versions.size == 1 && versions["string"]?.try(&.as_i) == 1
        raise UnsupportedFormatError.new("only nested String serialization version 1 is supported for Array(Map)")
      end
      serializers = info["columns"]?.try(&.as_a) ||
                    raise(CorruptPartError.new("Array(Map) column serializers are missing or malformed"))
      raise UnsupportedFormatError.new("Array(Map) per-column serializers are unsupported") unless serializers.empty?
      nil
    rescue ex : JSON::ParseException | TypeCastError | OverflowError
      raise CorruptPartError.new("serialization.json is malformed")
    end

    private def validate_array_map_numeric_serialization(
      columns : Array({String, String}),
      selected_column : String,
      selected_type : String,
    ) : Nil
      key_columns = columns.select { |name, type| name != selected_column && type == "UInt64" }
      unless WidePart.supports_array_map_numeric_type?(selected_type) && columns.size == 2 && key_columns.size == 1 &&
             columns.count { |_, type| type == "UInt64" } == 1
        raise UnsupportedFormatError.new("#{selected_type} requires one UInt64 sorting-key column")
      end

      file = File.join(@path, "serialization.json")
      raise UnsupportedFormatError.new("serialization.json is required for this type") unless File.file?(file)
      raise CorruptPartError.new("serialization.json must not be a symbolic link") if File.symlink?(file)
      size = File.size(file)
      raise UnsupportedFormatError.new("serialization.json exceeds metadata limit") if size > MAX_METADATA_FILE_BYTES
      text = File.read(file)
      raise CorruptPartError.new("serialization.json changed while reading") unless text.bytesize == size

      info = JSON.parse(text).as_h
      expected_fields = Set{"version", "columns", "types_serialization_versions", "propagate_types_serialization_versions_to_nested_types"}
      raise UnsupportedFormatError.new("unsupported Array(Map) serialization.json fields") unless info.keys.to_set == expected_fields
      version = info["version"]?.try(&.as_i) || raise(CorruptPartError.new("serialization.json version is missing or malformed"))
      raise UnsupportedFormatError.new("only serialization.json version 1 is supported") unless version == 1
      propagated = info["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool)
      raise UnsupportedFormatError.new("Array(Map) nested serialization versions are unsupported") unless propagated == true

      versions = info["types_serialization_versions"]?.try(&.as_h) ||
                 raise(CorruptPartError.new("serialization type versions are missing or malformed"))
      unless versions.size == 1 && versions["string"]?.try(&.as_i) == 1
        raise UnsupportedFormatError.new("only nested String serialization version 1 is supported for Array(Map)")
      end
      serializers = info["columns"]?.try(&.as_a) ||
                    raise(CorruptPartError.new("Array(Map) column serializers are missing or malformed"))
      raise UnsupportedFormatError.new("Array(Map) per-column serializers are unsupported") unless serializers.empty?
      nil
    rescue ex : JSON::ParseException | TypeCastError | OverflowError
      raise CorruptPartError.new("serialization.json is malformed")
    end

    private def valid_dynamic_substream_inventory?(column : String, streams : Array(String)) : Bool
      prefix = ["#{column}.dynamic_structure", "#{column}.variant_discr", "#{column}.SharedVariant.size", "#{column}.SharedVariant"]
      string_arm = ["#{column}.String.size", "#{column}.String"]
      uint64_arm = ["#{column}.UInt64"]
      [
        prefix,
        prefix + string_arm,
        prefix + uint64_arm,
        prefix + string_arm + uint64_arm,
      ].any? { |candidate| streams == candidate }
    end

    private def validate_array_type_serialization_version(
      type : String,
      columns : Array({String, String}),
      selected_column : String,
      row_count : UInt64,
    ) : Nil
      generic_array_tuple = !WideArrayTupleTypePlan.for_type(type).nil? && WideTypePlan.admitted(type).nil?
      if generic_array_tuple
        selected = columns.find { |name, column_type| name == selected_column && column_type == type }
        keys = columns.select { |name, column_type| name != selected_column && column_type == "UInt64" }
        unless columns.size == 2 && selected && keys.size == 1
          raise UnsupportedFormatError.new("Array(Tuple) serialization requires one UInt64 key and one selected payload")
        end
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
      unless WidePart.supports_array_type?(type) || generic_array_tuple
        raise UnsupportedFormatError.new("unsupported array serializer type")
      end
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
                       !WidePart.map_uint64_numeric_value_type(map_type).nil? ||
                       !WidePart.map_uint64_nullable_numeric_value_type(map_type).nil? ||
                       !WidePart.map_uint64_array_numeric_value_type(map_type).nil? ||
                       !WidePart.map_uint64_array_nullable_numeric_value_type(map_type).nil? ||
                       WidePart.supports_map_uint64_nullable_uint64_type?(map_type) ||
                       WidePart.supports_map_uint64_array_nullable_uint64_type?(map_type) ||
                       WidePart.supports_map_uint64_array_nullable_string_type?(map_type) ||
                       WidePart.supports_map_uint64_array_uint64_type?(map_type) ||
                       WidePart.supports_map_uint64_array_string_type?(map_type) ||
                       WidePart.supports_map_uint64_nullable_string_type?(map_type)
      string_key_map = WidePart.supports_map_string_uint64_type?(map_type) ||
                       !WidePart.map_string_numeric_value_type(map_type).nil? ||
                       !WidePart.map_string_nullable_numeric_value_type(map_type).nil? ||
                       !WidePart.map_string_array_numeric_value_type(map_type).nil? ||
                       !WidePart.map_string_array_nullable_numeric_value_type(map_type).nil? ||
                       WidePart.supports_map_string_array_uint64_type?(map_type) ||
                       WidePart.supports_map_string_array_nullable_uint64_type?(map_type) ||
                       WidePart.supports_map_string_array_nullable_string_type?(map_type) ||
                       WidePart.supports_map_string_array_string_type?(map_type) ||
                       WidePart.supports_map_string_string_type?(map_type) ||
                       WidePart.supports_map_string_nullable_uint64_type?(map_type) ||
                       WidePart.supports_map_string_nullable_string_type?(map_type)
      map_tuple = !WideMapTupleTypePlan.for_type(map_type).nil?
      supported_map = uint64_key_map || string_key_map || map_tuple
      valid_columns = columns.any? { |name, type| name == selected_column && type == map_type }
      valid_columns &&= columns.size == 2 if map_tuple
      unless supported_map && keys.size == 1 && valid_columns
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
      w70_map = WidePart.supports_map_string_array_nullable_string_type?(map_type)
      w71_map = WidePart.supports_map_uint64_array_nullable_string_type?(map_type)
      w73_map = WidePart.supports_map_uint64_array_uint64_type?(map_type) ||
                WidePart.supports_map_string_array_string_type?(map_type) ||
                WidePart.supports_map_uint64_array_string_type?(map_type) ||
                WidePart.supports_numeric_map_array_type?(map_type)
      numeric_map = WidePart.supports_numeric_map_type?(map_type) || WidePart.supports_nullable_numeric_map_type?(map_type)
      if map_tuple
        unless serializers.size == 1
          raise UnsupportedFormatError.new("Map(Tuple) serialization requires one external key serializer")
        end
      elsif !serializers.empty? && !((uint64_key_map || w70_map || w73_map || numeric_map) && serializers.size == 1)
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
        valid_default_count = w70_map || w71_map || w73_map || map_tuple ? defaults >= 0 && defaults <= row_count.to_i64 : defaults == 0
        unless kind == "Default" && name == keys[0][0] && valid_default_count
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
      selected_type : String,
      row_count : UInt64,
    ) : Nil
      tuple_plan = WideTupleTypePlan.for_type(selected_type)
      keys = columns.select { |name, type| name != selected_column && type == "UInt64" }
      unless columns.size == 2 && keys.size == 1 && tuple_plan &&
             columns.any? { |name, type| name == selected_column && type == selected_type && WidePart.supports_named_scalar_tuple_type?(type) }
        raise UnsupportedFormatError.new("named numeric/Bool/String Tuple requires one UInt64 key column")
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
      return if serializers.empty?
      raise UnsupportedFormatError.new("Tuple serialization requires exact key and payload entries") unless serializers.size == 2
      serializers_by_name = Hash(String, Hash(String, JSON::Any)).new
      serializers.each do |serializer|
        entry = serializer.as_h
        name = entry["name"]?.try(&.as_s) || raise(CorruptPartError.new("Tuple serializer name is missing or malformed"))
        raise UnsupportedFormatError.new("duplicate Tuple serializer name") if serializers_by_name.has_key?(name)
        serializers_by_name[name] = entry
      end
      expected_names = columns.map(&.[0]).to_set
      unless serializers_by_name.keys.to_set == expected_names
        raise UnsupportedFormatError.new("Tuple serialization requires exact key and payload entries")
      end
      ordered_columns = [keys[0][0], selected_column]
      ordered_columns.each do |column_name|
        entry = serializers_by_name[column_name]
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
          TupleSerializationMetadataValidator.validate_subcolumns!(
            subcolumns,
            tuple_plan.not_nil!.root_fields,
            row_count,
            WidePart.supports_tuple_uint64_string_type?(selected_type),
          )
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

    private def validate_variant_serialization(
      columns : Array({String, String}),
      selected_column : String,
      row_count : UInt64,
    ) : Nil
      key_columns = columns.select { |name, type| name != selected_column && type == "UInt64" }
      unless columns.size == 2 && key_columns.size == 1 &&
             columns.any? { |name, type| name == selected_column && WidePart.supports_variant_type?(type) }
        raise UnsupportedFormatError.new("Variant requires one UInt64 key column")
      end

      file = File.join(@path, "serialization.json")
      raise UnsupportedFormatError.new("serialization.json is required for Variant") unless File.file?(file)
      raise CorruptPartError.new("serialization.json must not be a symbolic link") if File.symlink?(file)
      size = File.size(file)
      raise UnsupportedFormatError.new("serialization.json exceeds metadata limit") if size > MAX_METADATA_FILE_BYTES
      text = File.read(file)
      raise CorruptPartError.new("serialization.json changed while reading") unless text.bytesize == size

      info = JSON.parse(text).as_h
      expected_fields = Set{"version", "columns", "types_serialization_versions", "propagate_types_serialization_versions_to_nested_types"}
      raise UnsupportedFormatError.new("unsupported Variant serialization.json fields") unless info.keys.to_set == expected_fields
      version = info["version"]?.try(&.as_i) || raise(CorruptPartError.new("serialization.json version is missing or malformed"))
      raise UnsupportedFormatError.new("only serialization.json version 1 is supported") unless version == 1
      propagated = info["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool)
      raise UnsupportedFormatError.new("Variant nested serialization versions are unsupported") unless propagated == true
      versions = info["types_serialization_versions"]?.try(&.as_h) || raise(CorruptPartError.new("serialization type versions are missing or malformed"))
      raise UnsupportedFormatError.new("only nested String serialization version 1 is supported for Variant") unless versions.size == 1 && versions["string"]?.try(&.as_i) == 1
      serializers = info["columns"]?.try(&.as_a) || raise(UnsupportedFormatError.new("Variant column serializers are required"))
      raise UnsupportedFormatError.new("Variant per-column serializers are unsupported") unless serializers.empty?
      nil
    rescue ex : JSON::ParseException | TypeCastError | OverflowError
      raise CorruptPartError.new("serialization.json is malformed")
    end

    private def validate_dynamic_string_serialization(
      columns : Array({String, String}),
      selected_column : String,
      row_count : UInt64,
    ) : Nil
      key_columns = columns.select { |name, type| name != selected_column && type == "UInt64" }
      unless columns.size == 2 && key_columns.size == 1 && columns.any? { |name, type| name == selected_column && type == "Dynamic" }
        raise UnsupportedFormatError.new("Dynamic String-only profile requires one UInt64 key column")
      end

      file = File.join(@path, "serialization.json")
      raise UnsupportedFormatError.new("serialization.json is required for Dynamic") unless File.file?(file)
      raise CorruptPartError.new("serialization.json must not be a symbolic link") if File.symlink?(file)
      size = File.size(file)
      raise UnsupportedFormatError.new("serialization.json exceeds metadata limit") if size > MAX_METADATA_FILE_BYTES
      text = File.read(file)
      raise CorruptPartError.new("serialization.json changed while reading") unless text.bytesize == size

      info = JSON.parse(text).as_h
      expected_fields = Set{"version", "columns", "types_serialization_versions", "propagate_types_serialization_versions_to_nested_types"}
      raise UnsupportedFormatError.new("unsupported Dynamic serialization.json fields") unless info.keys.to_set == expected_fields
      version = info["version"]?.try(&.as_i) || raise(CorruptPartError.new("serialization.json version is missing or malformed"))
      raise UnsupportedFormatError.new("only serialization.json version 1 is supported") unless version == 1
      propagated = info["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool)
      raise UnsupportedFormatError.new("Dynamic nested serialization versions are unsupported") unless propagated == true
      versions = info["types_serialization_versions"]?.try(&.as_h) || raise(CorruptPartError.new("serialization type versions are missing or malformed"))
      raise UnsupportedFormatError.new("only nested String serialization version 1 is supported for Dynamic") unless versions.size == 1 && versions["string"]?.try(&.as_i) == 1
      serializers = info["columns"]?.try(&.as_a) || raise(CorruptPartError.new("Dynamic column serializers are required"))
      case serializers.size
      when 0
        # Stock ClickHouse emits no per-column serializer records for this shape.
      when 1
        serializer = serializers[0].as_h
        unless serializer.keys.to_set == Set{"kind", "name", "num_defaults", "num_rows"}
          raise UnsupportedFormatError.new("unsupported Dynamic key serializer fields")
        end
        name = serializer["name"]?.try(&.as_s) || raise(CorruptPartError.new("Dynamic key serializer name is malformed"))
        kind = serializer["kind"]?.try(&.as_s) || raise(CorruptPartError.new("Dynamic key serializer kind is malformed"))
        defaults = serializer["num_defaults"]?.try(&.as_i) || raise(CorruptPartError.new("Dynamic key serializer default count is malformed"))
        rows = serializer["num_rows"]?.try(&.as_i) || raise(CorruptPartError.new("Dynamic key serializer row count is malformed"))
        unless name == key_columns[0][0] && kind == "Default" && defaults >= 0 && defaults <= rows && rows >= 0 && rows.to_u64 == row_count
          raise UnsupportedFormatError.new("unsupported Dynamic key serializer")
        end
      else
        raise UnsupportedFormatError.new("Dynamic per-column serializers are unsupported")
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
      value = PartMetadataTextParser.parse_decimal(text, UInt64::MAX, name)
      value
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
      required_first_mark_decompressed_offset : UInt64? = 0_u64,
      alignment_width : Int32? = nil,
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
        if offset == 0
          first_mark_offset_valid = compressed == 0
          if required_offset = required_first_mark_decompressed_offset
            first_mark_offset_valid &&= decompressed == required_offset
          end
          unless first_mark_offset_valid
            message = if required_first_mark_decompressed_offset.nil?
                        "first mark must start at compressed offset zero"
                      elsif required_first_mark_decompressed_offset == 0_u64
                        "first mark must start at zero"
                      elsif required_first_mark_decompressed_offset == 8_u64 && @column_type == "Dynamic"
                        "Dynamic discriminator first mark must start after eight-byte mode prefix"
                      elsif required_first_mark_decompressed_offset == 8_u64
                        "Variant discriminator first mark must start after eight-byte mode prefix"
                      else
                        "first mark does not start at the expected stream prefix"
                      end
            raise CorruptPartError.new(message)
          end
        end
        string_eof = allow_empty_string_eof && compressed == data_size.to_u64 && decompressed == 0
        eof_sentinel = offset + MARK_SIZE == bytes.size && rows == 0 && compressed == data_size.to_u64
        unless compressed < data_size.to_u64 || string_eof || eof_sentinel
          raise CorruptPartError.new("mark compressed offset exceeds data")
        end
        raise CorruptPartError.new("mark offset is not monotonic") if compressed < previous_compressed
        raise CorruptPartError.new("mark decompressed offset is not monotonic") if compressed == previous_compressed && decompressed < previous_decompressed
        raise CorruptPartError.new("mark offset exceeds limit") if decompressed > MAX_FRAME_DECOMPRESSED_BYTES
        aligned_width = alignment_width || element_width
        raise CorruptPartError.new("mark decompressed offset is not column-type-aligned") unless aligned_width > 0 && decompressed % aligned_width.to_u64 == 0
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
      if @column_type == "Dynamic"
        stream = "#{@column}.variant_discr"
        raise CorruptPartError.new("selected Dynamic discriminator stream is missing") unless stream_names.includes?(stream)
        return stream
      end
      if plan = QBitColumnType.for_type(@column_type)
        stream = plan.physical_streams(@column).find { |candidate| candidate[0] != "#{@column}.null" }.try(&.[0])
        raise CorruptPartError.new("selected QBit plane stream is missing from its plan") unless stream
        raise CorruptPartError.new("selected QBit plane stream is missing") unless stream_names.includes?(stream)
        return stream
      end
      if plan = PointColumnType.for_type(@column_type)
        stream = plan.coordinate_streams(@column)[0]
        raise CorruptPartError.new("selected Point coordinate stream is missing from its plan") unless stream_names.includes?(stream)
        return stream
      end
      if plan = GeometryColumnType.for_type(@column_type)
        stream = plan.discriminator_stream(@column)
        raise CorruptPartError.new("selected Geometry discriminator stream is missing") unless stream_names.includes?(stream)
        return stream
      end
      if plan = GeoArrayColumnType.for_type(@column_type)
        stream = plan.size_stream(@column, 0)
        raise CorruptPartError.new("selected Geo Array size0 stream is missing") unless stream_names.includes?(stream)
        return stream
      end
      if plan = WidePart.variant_type_plan(@column_type)
        stream = plan.discriminator_stream(@column)
        raise CorruptPartError.new("selected Variant discriminator stream is missing") unless stream_names.includes?(stream)
        return stream
      end
      if plan = WideTypePlan.admitted(@column_type)
        stream = plan.physical_streams(@column).find do |candidate|
          candidate.kind.array_size0? && candidate.field_path.empty?
        end.try(&.name)
        raise CorruptPartError.new("selected Array(Tuple) size0 stream is missing from its plan") unless stream
        raise CorruptPartError.new("selected Array(Tuple) size0 stream is missing") unless stream_names.includes?(stream)
        return stream
      end
      if plan = WideArrayTupleTypePlan.for_type(@column_type)
        stream = plan.outer_size_stream(@column)
        raise CorruptPartError.new("selected Array(Tuple) size0 stream is missing from its plan") unless stream_names.includes?(stream)
        return stream
      end
      if plan = WideMapTupleTypePlan.for_type(@column_type)
        stream = plan.outer_size_stream(@column)
        raise CorruptPartError.new("selected Map(Tuple) size0 stream is missing from its plan") unless stream_names.includes?(stream)
        return stream
      end
      if tuple_plan = WideTupleTypePlan.for_type(@column_type)
        stream = tuple_plan.physical_streams(@column).first
        raise CorruptPartError.new("selected Tuple child stream is missing") unless stream_names.includes?(stream)
        return stream
      end
      if WidePart.supports_array_map_type?(@column_type)
        plan = WideTypePlan::WidePhysicalPlanShadow.for_type(@column_type, @column).not_nil!
        stream = plan.streams.find do |candidate|
          candidate.role.array_size0? && candidate.semantic_path.empty?
        end.try(&.name)
        raise CorruptPartError.new("selected Array(Map) size0 stream is missing from its plan") unless stream
        raise CorruptPartError.new("selected Array(Map) size0 stream is missing") unless stream_names.includes?(stream)
        return stream
      end
      if WidePart.array_array_numeric_element_type(@column_type) || WidePart.array_array_decimal_payload_width(@column_type)
        stream = "#{@column}.size0"
        raise CorruptPartError.new("selected nested numeric Array size0 stream is missing") unless stream_names.includes?(stream)
        return stream
      end
      if WidePart.supports_map_uint64_string_type?(@column_type) || WidePart.supports_map_uint64_uint64_type?(@column_type) ||
         WidePart.supports_numeric_map_type?(@column_type) ||
         WidePart.supports_nullable_numeric_map_type?(@column_type) ||
         WidePart.supports_numeric_map_array_type?(@column_type) ||
         WidePart.supports_nullable_numeric_map_array_type?(@column_type) ||
         WidePart.supports_map_string_uint64_type?(@column_type) || WidePart.supports_map_string_array_uint64_type?(@column_type) ||
         WidePart.supports_map_string_array_nullable_uint64_type?(@column_type) ||
         WidePart.supports_map_string_array_nullable_string_type?(@column_type) ||
         WidePart.supports_map_uint64_array_nullable_uint64_type?(@column_type) ||
         WidePart.supports_map_uint64_array_nullable_string_type?(@column_type) ||
         WidePart.supports_map_uint64_array_uint64_type?(@column_type) ||
         WidePart.supports_map_uint64_array_string_type?(@column_type) ||
         WidePart.supports_map_string_array_string_type?(@column_type) ||
         WidePart.supports_map_string_string_type?(@column_type) ||
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
      if plan = QBitColumnType.for_type(@column_type)
        plan.stream_width(@column, stream_name) || raise(UnsupportedFormatError.new("unsupported QBit substream"))
      elsif plan = PointColumnType.for_type(@column_type)
        plan.stream_width(@column, stream_name) || raise(UnsupportedFormatError.new("unsupported Point coordinate stream"))
      elsif plan = GeometryColumnType.for_type(@column_type)
        plan.stream_width(@column, stream_name) || raise(UnsupportedFormatError.new("unsupported Geometry stream"))
      elsif plan = GeoArrayColumnType.for_type(@column_type)
        plan.stream_width(@column, stream_name) || raise(UnsupportedFormatError.new("unsupported Geo Array stream"))
      elsif @column_type == "Dynamic"
        stream_name == "#{@column}.String.size" || stream_name == "#{@column}.UInt64" ? 8 : 1
      elsif WidePart.supports_array_map_type?(@column_type)
        plan = WideTypePlan::WidePhysicalPlanShadow.for_type(@column_type, @column).not_nil!
        plan.streams.find(&.name.==(stream_name)).try(&.element_width) ||
          raise UnsupportedFormatError.new("unsupported exact Array(Map) substream")
      elsif value_type = WidePart.map_uint64_array_numeric_value_type(@column_type)
        if stream_name == "#{@column}%2Evalues"
          WidePart.numeric_payload_width(value_type)
        else
          8
        end
      elsif value_type = WidePart.map_string_array_numeric_value_type(@column_type)
        if stream_name == "#{@column}%2Ekeys"
          1
        elsif stream_name == "#{@column}%2Evalues"
          WidePart.numeric_payload_width(value_type)
        else
          8
        end
      elsif plan = WidePart.variant_type_plan(@column_type)
        plan.stream_width(@column, stream_name) || raise(UnsupportedFormatError.new("unsupported Variant substream"))
      elsif @column_type == "LowCardinality(String)"
        1
      elsif plan = WideTypePlan.admitted(@column_type)
        stream = plan.physical_streams(@column).find(&.name.==(stream_name)) ||
                 raise(UnsupportedFormatError.new("unsupported exact Array(Tuple) substream"))
        stream.element_width
      elsif plan = WideArrayTupleTypePlan.for_type(@column_type)
        plan.stream_width(@column, stream_name) ||
          raise(UnsupportedFormatError.new("unsupported compositional Array(Tuple) substream"))
      elsif plan = WideMapTupleTypePlan.for_type(@column_type)
        plan.stream_width(@column, stream_name) ||
          raise(UnsupportedFormatError.new("unsupported compositional Map(Tuple) substream"))
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
      elsif tuple_plan = WideTupleTypePlan.for_type(@column_type)
        tuple_plan.stream_width(@column, stream_name) || raise(UnsupportedFormatError.new("unsupported named Tuple substream"))
      elsif WidePart.supports_map_uint64_string_type?(@column_type)
        stream_name == "#{@column}%2Evalues" ? 1 : 8
      elsif WidePart.supports_map_uint64_uint64_type?(@column_type)
        8
      elsif value_type = WidePart.map_uint64_numeric_value_type(@column_type)
        stream_name == "#{@column}%2Evalues" ? WidePart.numeric_payload_width(value_type) : 8
      elsif value_type = WidePart.map_uint64_nullable_numeric_value_type(@column_type)
        if stream_name == "#{@column}%2Evalues.null"
          1
        elsif stream_name == "#{@column}%2Evalues"
          WidePart.numeric_payload_width(value_type)
        else
          8
        end
      elsif value_type = WidePart.map_string_numeric_value_type(@column_type)
        if stream_name == "#{@column}%2Ekeys"
          1
        elsif stream_name == "#{@column}%2Evalues"
          WidePart.numeric_payload_width(value_type)
        else
          8
        end
      elsif value_type = WidePart.map_string_nullable_numeric_value_type(@column_type)
        if stream_name == "#{@column}%2Ekeys" || stream_name == "#{@column}%2Evalues.null"
          1
        elsif stream_name == "#{@column}%2Evalues"
          WidePart.numeric_payload_width(value_type)
        else
          8
        end
      elsif WidePart.supports_map_uint64_nullable_uint64_type?(@column_type)
        stream_name == "#{@column}%2Evalues.null" ? 1 : 8
      elsif WidePart.supports_map_uint64_array_nullable_uint64_type?(@column_type)
        stream_name == "#{@column}%2Evalues.null" ? 1 : 8
      elsif value_type = WidePart.map_uint64_array_nullable_numeric_value_type(@column_type)
        if stream_name == "#{@column}%2Evalues.null"
          1
        elsif stream_name == "#{@column}%2Evalues"
          WidePart.numeric_payload_width(value_type)
        else
          8
        end
      elsif WidePart.supports_map_uint64_array_uint64_type?(@column_type)
        8
      elsif WidePart.supports_map_uint64_array_nullable_string_type?(@column_type)
        stream_name == "#{@column}%2Evalues.null" || stream_name == "#{@column}%2Evalues" ? 1 : 8
      elsif WidePart.supports_map_uint64_array_string_type?(@column_type)
        stream_name == "#{@column}%2Evalues" ? 1 : 8
      elsif WidePart.supports_map_string_array_string_type?(@column_type)
        stream_name == "#{@column}%2Ekeys" || stream_name == "#{@column}%2Evalues" ? 1 : 8
      elsif WidePart.supports_map_string_uint64_type?(@column_type)
        stream_name == "#{@column}%2Ekeys" ? 1 : 8
      elsif WidePart.supports_map_string_array_uint64_type?(@column_type)
        stream_name == "#{@column}%2Ekeys" ? 1 : 8
      elsif WidePart.supports_map_string_array_nullable_uint64_type?(@column_type)
        stream_name == "#{@column}%2Ekeys" || stream_name == "#{@column}%2Evalues.null" ? 1 : 8
      elsif value_type = WidePart.map_string_array_nullable_numeric_value_type(@column_type)
        if stream_name == "#{@column}%2Ekeys" || stream_name == "#{@column}%2Evalues.null"
          1
        elsif stream_name == "#{@column}%2Evalues"
          WidePart.numeric_payload_width(value_type)
        else
          8
        end
      elsif WidePart.supports_map_string_array_nullable_string_type?(@column_type)
        stream_name == "#{@column}%2Ekeys" || stream_name == "#{@column}%2Evalues.null" ||
          stream_name == "#{@column}%2Evalues" ? 1 : 8
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
      elsif element_width = WidePart.array_array_decimal_payload_width(@column_type)
        if stream_name == "#{@column}.null"
          1
        elsif stream_name == @column
          element_width
        elsif stream_name == "#{@column}.size0" || stream_name == "#{@column}.size1"
          8
        else
          raise UnsupportedFormatError.new("unsupported exact nested Decimal Array substream")
        end
      elsif element_type = WidePart.array_array_nullable_temporal_element_type(@column_type)
        if stream_name == "#{@column}.null"
          1
        elsif stream_name == @column
          physical_type = WidePart.temporal_array_physical_type(element_type).not_nil!
          WidePart.array_numeric_payload_width(physical_type)
        elsif stream_name == "#{@column}.size0" || stream_name == "#{@column}.size1"
          8
        else
          raise UnsupportedFormatError.new("unsupported exact nested nullable temporal Array substream")
        end
      elsif element_type = WidePart.array_array_temporal_element_type(@column_type)
        if stream_name == @column
          physical_type = WidePart.temporal_array_physical_type(element_type).not_nil!
          WidePart.array_numeric_payload_width(physical_type)
        elsif stream_name == "#{@column}.size0" || stream_name == "#{@column}.size1"
          8
        else
          raise UnsupportedFormatError.new("unsupported exact nested temporal Array substream")
        end
      elsif element_type = WidePart.array_array_nullable_time_element_type(@column_type)
        if stream_name == "#{@column}.null"
          1
        elsif stream_name == @column
          WidePart.array_numeric_payload_width(WidePart.time_array_physical_type(element_type).not_nil!)
        elsif stream_name == "#{@column}.size0" || stream_name == "#{@column}.size1"
          8
        else
          raise UnsupportedFormatError.new("unsupported exact nested nullable Time Array substream")
        end
      elsif element_type = WidePart.array_array_time_element_type(@column_type)
        if stream_name == @column
          WidePart.array_numeric_payload_width(WidePart.time_array_physical_type(element_type).not_nil!)
        elsif stream_name == "#{@column}.size0" || stream_name == "#{@column}.size1"
          8
        else
          raise UnsupportedFormatError.new("unsupported exact nested Time Array substream")
        end
      elsif element_type = WidePart.array_array_nullable_numeric_element_type(@column_type)
        if stream_name == "#{@column}.null"
          1
        elsif stream_name == @column
          WidePart.array_numeric_payload_width(element_type)
        else
          8
        end
      elsif @column_type == "Array(Array(UInt64))"
        8
      elsif element_type = WidePart.array_array_numeric_element_type(@column_type)
        case stream_name
        when "#{@column}.size0", "#{@column}.size1" then 8
        when @column                                then WidePart.array_numeric_payload_width(element_type)
        else
          raise UnsupportedFormatError.new("unsupported exact nested numeric Array substream")
        end
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
      elsif datetime_type = DateTimeColumnType.parse_leaf(@column_type)
        datetime_type.raw_width
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
      if datetime_type = DateTimeColumnType.parse(type)
        return datetime_type.raw_width if datetime_type.shape == DateTimeColumnType::Shape::Nullable
      end
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
      size_stream_name : String? = nil,
    ) : {Array(UInt64), UInt64, UInt64, Array(UInt64)}
      size_stream = @streams[size_stream_name || "#{column}.size0"]
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

    # Each nested Decimal child mark must agree with its root row boundary
    # before materialization, including the nullable leaf's null-map.
    private def validate_array_array_decimal_stream_mark_rows(
      column : String,
      first_mark : Int,
      mark_count : Int,
      nullable : Bool,
    ) : Nil
      root_stream = @streams[column]
      _, _, rows = checked_stream_mark_range(root_stream, first_mark, mark_count)
      expected_mark_rows = Array(UInt64).new(mark_count)
      mark_count.times do |range_mark_index|
        expected_mark_rows << root_stream.marks[first_mark + range_mark_index].rows
      end

      stream_names = nullable ? ["#{column}.size1", "#{column}.null"] : ["#{column}.size1"]
      stream_names.each do |stream_name|
        stream = @streams[stream_name]
        _, _, stream_rows = checked_stream_mark_range(stream, first_mark, mark_count)
        raise CorruptPartError.new("Array(Array(Decimal)) substream mark rows differ") unless stream_rows == rows
        mark_count.times do |range_mark_index|
          unless stream.marks[first_mark + range_mark_index].rows == expected_mark_rows[range_mark_index]
            raise CorruptPartError.new("Array(Array(Decimal)) substream mark rows differ")
          end
        end
      end
      nil
    end

    # The generic Array(size0) reader checks only the combined selected byte
    # range. W58 also needs every physical .size0 mark boundary checked before
    # it consumes those decoded counts; keep this guard scoped to the new
    # numeric Array(Array(T)) readers so the established W28/W29 paths stay
    # unchanged.
    private def validate_array_array_numeric_size0_marks(column : String, first_mark : Int, mark_count : Int) : Nil
      value_stream = @streams[column]
      size_stream = @streams["#{column}.size0"]
      _, _, value_rows = checked_stream_mark_range(value_stream, first_mark, mark_count)
      _, _, size_rows = checked_stream_mark_range(size_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Array(T)) size0 mark rows differ") unless size_rows == value_rows

      expected_mark_rows = Array(UInt64).new(mark_count)
      mark_count.times do |range_mark_index|
        mark_index = first_mark + range_mark_index
        expected_rows = value_stream.marks[mark_index].rows
        unless size_stream.marks[mark_index].rows == expected_rows
          raise CorruptPartError.new("Array(Array(T)) size0 mark rows differ")
        end
        expected_mark_rows << expected_rows
      end

      begin
        validate_array_nested_stream_marks(size_stream, first_mark, expected_mark_rows, 8)
      rescue error : CorruptPartError
        raise CorruptPartError.new("Array(Array(T)) size0 mark boundary is corrupt: #{error.message}")
      end
      nil
    end

    # Nullable nested numeric children keep one base-row mark per selected
    # mark, even when their flattened leaf payload is empty. Match each child
    # mark's row count to the root stream; equal selected totals alone are not
    # sufficient to prove mark alignment.
    private def validate_array_array_nullable_numeric_stream_mark_rows(
      column : String,
      first_mark : Int,
      mark_count : Int,
    ) : Nil
      root_stream = @streams[column]
      _, _, rows = checked_stream_mark_range(root_stream, first_mark, mark_count)
      expected_mark_rows = Array(UInt64).new(mark_count)
      mark_count.times do |range_mark_index|
        expected_mark_rows << root_stream.marks[first_mark + range_mark_index].rows
      end

      ["#{column}.size1", "#{column}.null"].each do |stream_name|
        stream = @streams[stream_name]
        _, _, stream_rows = checked_stream_mark_range(stream, first_mark, mark_count)
        unless stream_rows == rows
          raise CorruptPartError.new("Array(Array(Nullable(T))) substream mark rows differ")
        end
        mark_count.times do |range_mark_index|
          unless stream.marks[first_mark + range_mark_index].rows == expected_mark_rows[range_mark_index]
            raise CorruptPartError.new("Array(Array(Nullable(T))) substream mark rows differ")
          end
        end
      end
      nil
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

    # Build one bounded depth-two count/leaf plan used by both W59 table
    # preflight and direct materialization. The existing nested count decoder
    # validates each size1 mark; the String-size decoder then validates each
    # flattened leaf length and its corresponding raw-data mark.
    private def array_array_string_components(
      column : String,
      first_mark : Int,
      mark_count : Int,
    ) : ArrayArrayStringComponents
      ensure_column(column)
      unless @column_type == "Array(Array(String))"
        raise UnsupportedFormatError.new("nested Array String accessor requires an exact Array(Array(String)) column")
      end

      validate_array_array_string_stream_marks(column, first_mark, mark_count)
      outer_sizes, flat_inner_arrays, rows, mark_inner_arrays = read_array_outer_sizes(column, first_mark, mark_count)
      inner_sizes, flat_strings, mark_string_counts = read_array_array_numeric_element_sizes(
        column,
        first_mark,
        mark_count,
        flat_inner_arrays,
        rows,
        mark_inner_arrays,
        8
      )
      string_sizes, string_bytes = read_array_string_element_sizes(
        column,
        first_mark,
        mark_count,
        flat_strings,
        rows,
        mark_string_counts,
        "Array(Array(String))",
        "#{column}.size",
        column
      )
      raise CorruptPartError.new("Array(Array(String)) outer row count changed") unless outer_sizes.size.to_u64 == rows
      raise CorruptPartError.new("Array(Array(String)) size1 count changed") unless inner_sizes.size.to_u64 == flat_inner_arrays
      raise CorruptPartError.new("Array(Array(String)) String size count changed") unless string_sizes.size.to_u64 == flat_strings

      ArrayArrayStringComponents.new(
        outer_sizes,
        inner_sizes,
        string_sizes,
        flat_inner_arrays,
        flat_strings,
        rows,
        string_bytes
      )
    end

    # Build the bounded W61 topology and preflight each selected mark across
    # size0, size1, null-map, String-size, and raw String streams.
    private def array_array_nullable_string_components(
      column : String,
      first_mark : Int,
      mark_count : Int,
    ) : ArrayArrayNullableStringComponents
      ensure_column(column)
      unless @column_type == "Array(Array(Nullable(String)))"
        raise UnsupportedFormatError.new("nested nullable Array String accessor requires an exact Array(Array(Nullable(String))) column")
      end

      validate_array_array_nullable_string_stream_marks(column, first_mark, mark_count)
      outer_sizes, flat_inner_arrays, rows, mark_inner_arrays = read_array_outer_sizes(column, first_mark, mark_count)
      inner_sizes, flat_strings, mark_string_counts = read_array_array_numeric_element_sizes(
        column,
        first_mark,
        mark_count,
        flat_inner_arrays,
        rows,
        mark_inner_arrays,
        8
      )
      string_sizes, string_bytes = read_array_string_element_sizes(
        column,
        first_mark,
        mark_count,
        flat_strings,
        rows,
        mark_string_counts,
        "Array(Array(Nullable(String)))",
        "#{column}.size",
        column
      )

      null_stream = @streams["#{column}.null"]
      null_start, null_end, null_rows = checked_stream_mark_range(null_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Array(Nullable(String))) null-map mark rows differ") unless null_rows == rows
      validate_array_nested_stream_marks(null_stream, first_mark, mark_string_counts, 1)
      null_map = read_mark_range_bytes(null_stream, null_start, null_end, checked_array_mark_byte_count(flat_strings, 1), 1)
      null_map.each do |value|
        raise CorruptPartError.new("Array(Array(Nullable(String))) null-map byte is not boolean") unless value <= 1_u8
      end

      raise CorruptPartError.new("Array(Array(Nullable(String))) outer row count changed") unless outer_sizes.size.to_u64 == rows
      raise CorruptPartError.new("Array(Array(Nullable(String))) size1 count changed") unless inner_sizes.size.to_u64 == flat_inner_arrays
      raise CorruptPartError.new("Array(Array(Nullable(String))) String size count changed") unless string_sizes.size.to_u64 == flat_strings
      raise CorruptPartError.new("Array(Array(Nullable(String))) null-map count changed") unless null_map.size.to_u64 == flat_strings

      ArrayArrayNullableStringComponents.new(
        outer_sizes,
        inner_sizes,
        string_sizes,
        null_map,
        flat_inner_arrays,
        flat_strings,
        rows,
        string_bytes
      )
    end

    # Every nested stream keeps the base row cardinality, even when a mark
    # contains no inner Arrays, no String leaves, or only zero-length Strings.
    # Validate that agreement at each selected mark before decoding its counts.
    private def validate_array_array_string_stream_marks(column : String, first_mark : Int, mark_count : Int) : Nil
      size0_stream = @streams["#{column}.size0"]
      size1_stream = @streams["#{column}.size1"]
      string_size_stream = @streams["#{column}.size"]
      raw_stream = @streams[column]
      _, _, rows = checked_stream_mark_range(raw_stream, first_mark, mark_count)
      expected_mark_rows = Array(UInt64).new(mark_count)
      mark_count.times do |range_mark_index|
        mark_index = first_mark + range_mark_index
        mark_rows = raw_stream.marks[mark_index].rows
        expected_mark_rows << mark_rows
      end

      [size0_stream, size1_stream, string_size_stream].each do |stream|
        _, _, stream_rows = checked_stream_mark_range(stream, first_mark, mark_count)
        raise CorruptPartError.new("Array(Array(String)) substream mark rows differ") unless stream_rows == rows
        mark_count.times do |range_mark_index|
          mark_index = first_mark + range_mark_index
          unless stream.marks[mark_index].rows == expected_mark_rows[range_mark_index]
            raise CorruptPartError.new("Array(Array(String)) substream mark rows differ")
          end
        end
      end

      validate_array_nested_stream_marks(size0_stream, first_mark, expected_mark_rows, 8)
      nil
    end

    private def validate_array_array_nullable_string_stream_marks(column : String, first_mark : Int, mark_count : Int) : Nil
      root_stream = @streams[column]
      _, _, rows = checked_stream_mark_range(root_stream, first_mark, mark_count)
      expected_mark_rows = Array(UInt64).new(mark_count)
      mark_count.times do |range_mark_index|
        expected_mark_rows << root_stream.marks[first_mark + range_mark_index].rows
      end

      [
        @streams["#{column}.size0"],
        @streams["#{column}.size1"],
        @streams["#{column}.null"],
        @streams["#{column}.size"],
      ].each do |stream|
        _, _, stream_rows = checked_stream_mark_range(stream, first_mark, mark_count)
        raise CorruptPartError.new("Array(Array(Nullable(String))) substream mark rows differ") unless stream_rows == rows
        mark_count.times do |range_mark_index|
          mark_index = first_mark + range_mark_index
          unless stream.marks[mark_index].rows == expected_mark_rows[range_mark_index]
            raise CorruptPartError.new("Array(Array(Nullable(String))) substream mark rows differ")
          end
        end
      end

      validate_array_nested_stream_marks(@streams["#{column}.size0"], first_mark, expected_mark_rows, 8)
      nil
    end

    private def read_array_array_numeric_element_sizes(
      column : String,
      first_mark : Int,
      mark_count : Int,
      flat_inner_arrays : UInt64,
      outer_rows : UInt64,
      mark_inner_arrays : Array(UInt64),
      element_width : Int32,
      size_stream_name : String? = nil,
    ) : {Array(UInt64), UInt64, Array(UInt64)}
      size_stream = @streams[size_stream_name || "#{column}.size1"]
      size_start, size_end, size_rows = checked_stream_mark_range(size_stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Array(T)) size1 mark rows differ") unless size_rows == outer_rows
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
          raise CorruptPartError.new("Array(Array(T)) size1 count exceeds selected bytes") if size_offset > encoded_sizes.size - 8
          leaf_count = u64(encoded_sizes, size_offset)
          if leaf_count > MAX_ARRAY_MARK_ELEMENTS - mark_leaf_count || leaf_count > MAX_ARRAY_MARK_ELEMENTS - total_leaf_elements
            raise CorruptPartError.new("Array(Array(T)) leaf element count exceeds per-range limit")
          end
          mark_leaf_count += leaf_count
          total_leaf_elements += leaf_count
          element_sizes << leaf_count
          size_offset += 8
        end
        checked_array_mark_byte_count(mark_leaf_count, element_width)
        mark_leaf_elements << mark_leaf_count

        mark_index = first_mark + range_mark_index
        mark_start = size_stream.marks[mark_index]
        mark_end = mark_index + 1 == size_stream.marks.size ? size_stream.sentinel : size_stream.marks[mark_index + 1]
        validate_mark_range_bytes(size_stream, mark_start, mark_end, checked_array_mark_byte_count(mark_inner_count, 8), 8)
      end
      raise CorruptPartError.new("Array(Array(T)) size1 has trailing bytes") unless size_offset == encoded_sizes.size
      raise CorruptPartError.new("Array(Array(T)) size1 count does not match size0") unless element_sizes.size.to_u64 == flat_inner_arrays
      checked_array_mark_byte_count(total_leaf_elements, element_width)
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

    private def ensure_array_tuple_type(column : String, expected_type : String) : Nil
      ensure_column(column)
      raise UnsupportedFormatError.new("Array(Tuple) accessor requires its exact admitted declaration") unless @column_type == expected_type
      nil
    end

    private def array_tuple_components(
      column : String,
      first_mark : Int,
      mark_count : Int,
      materialize : Bool,
    ) : ArrayTupleComponents
      ensure_column(column)
      plan = WideTypePlan.admitted(@column_type) || raise(UnsupportedFormatError.new("Array(Tuple) type plan is not admitted"))
      streams = plan.physical_streams(column)
      streams.each do |stream_plan|
        raise CorruptPartError.new("Array(Tuple) planned child stream is missing: #{stream_plan.name}") unless @streams.has_key?(stream_plan.name)
      end
      size_plan = streams.find { |stream| stream.kind.array_size0? && stream.field_path.empty? } ||
                  raise(UnsupportedFormatError.new("admitted Array(Tuple) plan has no outer size stream"))
      first_value_plan = streams.find { |stream| stream.field_path == ["a"] && stream.kind.u_int64? } ||
                         raise(UnsupportedFormatError.new("admitted Array(Tuple) plan has no UInt64 `a` leaf"))
      first_null_plan = streams.find { |stream| stream.field_path == ["a"] && stream.kind.null_map? }
      second_value_plan = streams.find { |stream| stream.field_path == ["b"] && stream.kind.u_int64? }
      second_size_plan = streams.find { |stream| stream.field_path == ["b"] && stream.kind.string_size? }
      second_raw_plan = streams.find { |stream| stream.field_path == ["b"] && stream.kind.string_data? }
      second_is_string = !second_size_plan.nil? && !second_raw_plan.nil?
      raise UnsupportedFormatError.new("admitted Array(Tuple) plan has an invalid `b` leaf") unless second_value_plan || second_is_string
      raise UnsupportedFormatError.new("admitted Array(Tuple) plan has ambiguous `b` leaves") if second_value_plan && second_is_string

      outer_sizes, flat_elements, rows, mark_flat_elements = read_array_outer_sizes(
        column,
        first_mark,
        mark_count,
        size_plan.name
      )
      numeric_values = read_array_tuple_uint64_leaf(
        first_value_plan,
        first_mark,
        mark_count,
        flat_elements,
        rows,
        mark_flat_elements,
        materialize,
        "Array(Tuple) `a`"
      )
      second_numeric_values = if value_plan = second_value_plan
                                read_array_tuple_uint64_leaf(
                                  value_plan,
                                  first_mark,
                                  mark_count,
                                  flat_elements,
                                  rows,
                                  mark_flat_elements,
                                  materialize,
                                  "Array(Tuple) `b`"
                                )
                              else
                                nil
                              end

      element_sizes = [] of UInt64
      string_bytes = 0_u64
      string_values = nil.as(Bytes?)
      if size_stream_plan = second_size_plan
        raw_stream_plan = second_raw_plan.not_nil!
        element_sizes, string_bytes = read_array_string_element_sizes(
          column,
          first_mark,
          mark_count,
          flat_elements,
          rows,
          mark_flat_elements,
          "Array(Tuple(String))",
          size_stream_plan.name,
          raw_stream_plan.name
        )
        raise CorruptPartError.new("Array(Tuple) String-size count differs from size0") unless element_sizes.size.to_u64 == flat_elements
        if materialize
          raw_stream = @streams[raw_stream_plan.name]
          raw_start, raw_end, raw_rows = checked_stream_mark_range(raw_stream, first_mark, mark_count)
          raise CorruptPartError.new("Array(Tuple) String substream mark rows differ") unless raw_rows == rows
          string_values = read_mark_range_bytes(
            raw_stream,
            raw_start,
            raw_end,
            string_bytes.to_i,
            raw_stream_plan.element_width
          )
        end
      end

      null_map = if null_plan = first_null_plan
                   read_array_tuple_null_leaf(null_plan, first_mark, mark_count, flat_elements, rows, mark_flat_elements)
                 else
                   nil
                 end
      materialized_bytes = checked_array_tuple_materialization_bytes(
        rows,
        flat_elements,
        string_bytes,
        !first_null_plan.nil?
      )

      ArrayTupleComponents.new(
        outer_sizes,
        flat_elements,
        rows,
        element_sizes,
        string_bytes,
        materialized_bytes,
        numeric_values,
        second_numeric_values,
        null_map,
        string_values
      )
    end

    private def read_array_tuple_uint64_leaf(
      stream_plan : WideTypePlan::PhysicalSubstream,
      first_mark : Int,
      mark_count : Int,
      flat_elements : UInt64,
      rows : UInt64,
      mark_flat_elements : Array(UInt64),
      materialize : Bool,
      label : String,
    ) : Bytes?
      stream = @streams[stream_plan.name]
      value_start, value_end, value_rows = checked_stream_mark_range(stream, first_mark, mark_count)
      raise CorruptPartError.new("#{label} mark rows differ from size0") unless value_rows == rows
      validate_array_nested_stream_marks(stream, first_mark, mark_flat_elements, stream_plan.element_width)
      return nil unless materialize
      read_mark_range_bytes(
        stream,
        value_start,
        value_end,
        checked_array_mark_byte_count(flat_elements, stream_plan.element_width),
        stream_plan.element_width
      )
    end

    private def read_array_tuple_null_leaf(
      stream_plan : WideTypePlan::PhysicalSubstream,
      first_mark : Int,
      mark_count : Int,
      flat_elements : UInt64,
      rows : UInt64,
      mark_flat_elements : Array(UInt64),
    ) : Bytes
      stream = @streams[stream_plan.name]
      null_start, null_end, null_rows = checked_stream_mark_range(stream, first_mark, mark_count)
      raise CorruptPartError.new("Array(Tuple) null-map mark rows differ from size0") unless null_rows == rows
      validate_array_nested_stream_marks(stream, first_mark, mark_flat_elements, stream_plan.element_width)
      encoded_null_map = read_mark_range_bytes(
        stream,
        null_start,
        null_end,
        checked_array_mark_byte_count(flat_elements, stream_plan.element_width),
        stream_plan.element_width
      )
      encoded_null_map.each do |value|
        raise CorruptPartError.new("Array(Tuple) null-map byte is not boolean") unless value <= 1_u8
      end
      encoded_null_map
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

    private def ensure_qbit_reader_type(column : String, nullable : Bool?) : QBitColumnType
      ensure_column(column)
      plan = QBitColumnType.for_type(@column_type) ||
             raise(UnsupportedFormatError.new("QBit accessor requires a canonical QBit column"))
      unless nullable.nil?
        expected_nullable = nullable
        unless plan.nullable == expected_nullable
          shape = expected_nullable ? "Nullable(QBit)" : "non-nullable QBit"
          raise UnsupportedFormatError.new("QBit accessor requires an exact #{shape} column")
        end
      end
      plan
    end

    private def qbit_reader_checked_range(
      plan : QBitColumnType,
      column : String,
      first_mark : Int,
      mark_count : Int,
    ) : {Int32, Int32}
      reference_stream = plan.physical_streams(column).first? ||
                         raise(CorruptPartError.new("QBit has no physical plane streams"))
      # Check caller-sized indices against the actual selected stream before
      # narrowing to the reader Proc's Int32 interface.
      checked_stream_mark_range(@streams[reference_stream[0]], first_mark, mark_count)
      {first_mark.to_i32, mark_count.to_i32}
    end

    private def qbit_reader(plan : QBitColumnType, column : String) : QBitReader
      QBitReader.new(
        plan,
        column,
        ->(stream_name : String, first_mark : Int32, mark_count : Int32, width : Int32?) {
          stream = @streams[stream_name]
          start_mark, end_mark, rows = checked_stream_mark_range(stream, first_mark, mark_count)
          if element_width = width
            bytes = read_mark_range_bytes(
              stream,
              start_mark,
              end_mark,
              checked_byte_count(rows, element_width),
              element_width
            )
            {rows, bytes}
          else
            {rows, nil}
          end
        }
      )
    end

    private def ensure_geo_array_reader_type(column : String) : GeoArrayColumnType
      ensure_column(column)
      GeoArrayColumnType.for_type(@column_type) ||
        raise UnsupportedFormatError.new("Geo Array accessor requires an exact admitted Geo Array column")
    end

    private def geo_array_reader_checked_range(
      plan : GeoArrayColumnType,
      column : String,
      first_mark : Int,
      mark_count : Int,
    ) : {Int32, Int32}
      checked_stream_mark_range(@streams[plan.size_stream(column, 0)], first_mark, mark_count)
      {first_mark.to_i32, mark_count.to_i32}
    end

    private def geo_array_reader(plan : GeoArrayColumnType, column : String) : GeoArrayReader
      GeoArrayReader.new(
        plan,
        column,
        ->(stream : String, first : Int32, count : Int32) { tuple_reader_range_rows(stream, first, count) },
        ->(stream : String, mark : Int32) { tuple_reader_mark_rows(stream, mark) },
        ->(stream : String, first : Int32, count : Int32, bytes : Int32, width : Int32, rows : UInt64) {
          tuple_reader_read_range(stream, first, count, bytes, width, rows)
        },
        ->(stream : String, first : Int32, count : Int32, bytes : Int32, width : Int32, rows : UInt64) {
          tuple_reader_validate_range(stream, first, count, bytes, width, rows)
        },
        ->(bytes : Bytes, offset : Int32) { decode_numeric_value(bytes, offset, UInt64) },
        ->(bytes : Bytes, offset : Int32) { decode_numeric_value(bytes, offset, Float64) }
      )
    end

    private def ensure_geometry_reader_type(column : String) : GeometryColumnType
      ensure_column(column)
      GeometryColumnType.for_type(@column_type) ||
        raise UnsupportedFormatError.new("Geometry accessor requires an exact Geometry column")
    end

    private def geometry_reader_checked_range(
      plan : GeometryColumnType,
      column : String,
      first_mark : Int,
      mark_count : Int,
    ) : {Int32, Int32}
      # Validate caller-width indices against the discriminator's real mark
      # grid before narrowing for GeometryReader's callback interface.
      checked_stream_mark_range(@streams[plan.discriminator_stream(column)], first_mark, mark_count)
      {first_mark.to_i32, mark_count.to_i32}
    end

    private def geometry_reader(plan : GeometryColumnType, column : String) : GeometryReader
      discriminator = @streams[plan.discriminator_stream(column)]
      GeometryReader.new(
        plan,
        column,
        ->(first_mark : Int32, mark_count : Int32) {
          geometry_outer_rows(first_mark, mark_count, discriminator)
        },
        -> { variant_discriminator_mode(discriminator) },
        ->(mark_index : Int32, rows : UInt64, mode : UInt64) {
          geometry_discriminator_mark(discriminator, mark_index, rows, mode)
        },
        ->(stream : String, first : Int32, count : Int32, bytes : Int32, width : Int32, rows : UInt64) {
          tuple_reader_read_range(stream, first, count, bytes, width, rows)
        },
        ->(stream : String, first : Int32, count : Int32, bytes : Int32, width : Int32, rows : UInt64) {
          tuple_reader_validate_range(stream, first, count, bytes, width, rows)
        },
        ->(bytes : Bytes, offset : Int32) { decode_numeric_value(bytes, offset, UInt64) },
        ->(bytes : Bytes, offset : Int32) { decode_numeric_value(bytes, offset, Float64) }
      )
    end

    private def geometry_outer_rows(
      first_mark : Int32,
      mark_count : Int32,
      discriminator : PhysicalStream,
    ) : Array(UInt64)
      raise CorruptPartError.new("Geometry requires exactly 25 physical streams") unless @streams.size == 25

      rows_by_mark = Array(UInt64).new(mark_count)
      mark_count.times do |offset|
        mark_index = first_mark + offset.to_i32
        expected_rows = tuple_reader_mark_rows(discriminator.name, mark_index)
        @streams.each_value do |stream|
          actual_rows = tuple_reader_mark_rows(stream.name, mark_index)
          unless actual_rows == expected_rows
            raise CorruptPartError.new("Geometry physical mark row grids differ")
          end
        end
        rows_by_mark << expected_rows
      end
      rows_by_mark
    end

    private def geometry_discriminator_mark(
      discriminator : PhysicalStream,
      mark_index : Int32,
      expected_rows : UInt64,
      mode : UInt64,
    ) : Array(UInt8)
      start_mark, end_mark, rows = checked_stream_mark_range(discriminator, mark_index, 1)
      unless rows == expected_rows
        raise CorruptPartError.new("Geometry discriminator mark rows differ from physical marks")
      end
      read_variant_discriminator_mark(
        discriminator,
        start_mark,
        end_mark,
        mark_index,
        rows,
        mode,
        GeometryReader::DISCRIMINATOR_PLAN
      )
    end

    private def ensure_point_reader_type(column : String) : PointColumnType
      ensure_column(column)
      PointColumnType.for_type(@column_type) ||
        raise UnsupportedFormatError.new("Point accessor requires an exact Point column")
    end

    private def point_reader_checked_range(
      plan : PointColumnType,
      column : String,
      first_mark : Int,
      mark_count : Int,
    ) : {Int32, Int32}
      reference_stream = plan.coordinate_streams(column)[0]
      # Check caller-width indices against the real stream before narrowing.
      checked_stream_mark_range(@streams[reference_stream], first_mark, mark_count)
      {first_mark.to_i32, mark_count.to_i32}
    end

    private def point_reader(plan : PointColumnType, column : String) : PointReader
      PointReader.new(
        plan,
        column,
        ->(stream_name : String, first_mark : Int32, mark_count : Int32) {
          tuple_reader_range_rows(stream_name, first_mark, mark_count)
        },
        ->(stream_name : String, mark_index : Int32) {
          tuple_reader_mark_rows(stream_name, mark_index)
        },
        ->(stream_name : String, first_mark : Int32, mark_count : Int32, expected_bytes : Int32, element_width : Int32, expected_rows : UInt64) {
          point_reader_read_range(stream_name, first_mark, mark_count, expected_bytes, element_width, expected_rows)
        },
        ->(stream_name : String, first_mark : Int32, mark_count : Int32, expected_bytes : Int32, element_width : Int32, expected_rows : UInt64) {
          point_reader_validate_range(stream_name, first_mark, mark_count, expected_bytes, element_width, expected_rows)
        },
        ->(bytes : Bytes, offset : Int32) {
          decode_numeric_value(bytes, offset, Float64)
        }
      )
    end

    private def point_reader_read_range(
      stream_name : String,
      first_mark : Int32,
      mark_count : Int32,
      expected_bytes : Int32,
      element_width : Int32,
      expected_rows : UInt64,
    ) : Bytes
      stream = @streams[stream_name]
      start_mark, end_mark, rows = checked_stream_mark_range(stream, first_mark, mark_count)
      raise CorruptPartError.new("Point coordinate mark rows differ") unless rows == expected_rows
      read_mark_range_bytes(stream, start_mark, end_mark, expected_bytes, element_width)
    end

    private def point_reader_validate_range(
      stream_name : String,
      first_mark : Int32,
      mark_count : Int32,
      expected_bytes : Int32,
      element_width : Int32,
      expected_rows : UInt64,
    ) : Nil
      stream = @streams[stream_name]
      start_mark, end_mark, rows = checked_stream_mark_range(stream, first_mark, mark_count)
      raise CorruptPartError.new("Point coordinate mark rows differ") unless rows == expected_rows
      validate_mark_range_bytes(stream, start_mark, end_mark, expected_bytes, element_width)
    end

    private def ensure_compositional_tuple_column(column : String) : WideTupleTypePlan
      ensure_column(column)
      WideTupleTypePlan.for_type(@column_type) ||
        raise UnsupportedFormatError.new("compositional Tuple accessor requires named supported scalar leaves")
    end

    private def tuple_reader(
      plan : WideTupleTypePlan,
      column : String,
      logical_rows : Proc(Int32, Int32, UInt64)? = nil,
      combined_charge : Proc(UInt64, UInt64, UInt64, UInt64?)? = nil,
      read_range : Proc(String, Int32, Int32, Int32, Int32, UInt64, Bytes)? = nil,
      validate_range : Proc(String, Int32, Int32, Int32, Int32, UInt64, Nil)? = nil,
    ) : TupleReader
      TupleReader.new(
        plan,
        column,
        ->(stream_name : String, first_mark : Int32, mark_count : Int32) {
          tuple_reader_range_rows(stream_name, first_mark, mark_count)
        },
        ->(stream_name : String, mark_index : Int32) {
          tuple_reader_mark_rows(stream_name, mark_index)
        },
        read_range || ->(stream_name : String, first_mark : Int32, mark_count : Int32, expected_bytes : Int32, element_width : Int32, expected_rows : UInt64) {
          tuple_reader_read_range(stream_name, first_mark, mark_count, expected_bytes, element_width, expected_rows)
        },
        validate_range || ->(stream_name : String, first_mark : Int32, mark_count : Int32, expected_bytes : Int32, element_width : Int32, expected_rows : UInt64) {
          tuple_reader_validate_range(stream_name, first_mark, mark_count, expected_bytes, element_width, expected_rows)
        },
        ->(bytes : Bytes, offset : Int32) {
          decode_numeric_value(bytes, offset, UInt64)
        },
        tuple_leaf_decoder,
        logical_rows,
        combined_charge
      )
    end

    private def tuple_leaf_decoder : TupleLeafDecoder
      TupleLeafDecoder.new(
        ->(name : String, type_name : String, bytes : Bytes, rows : UInt64, width : Int32) {
          decode_tuple_numeric_leaf(name, type_name, bytes, rows, width)
        },
        ->(name : String, bytes : Bytes, rows : UInt64, width : Int32) {
          decode_tuple_bool_leaf(name, bytes, rows, width)
        },
        ->(name : String, type_name : String, bytes : Bytes, rows : UInt64, width : Int32) {
          decode_tuple_identifier_leaf(name, type_name, bytes, rows, width)
        },
        ->(name : String, type_name : String, bytes : Bytes, rows : UInt64, width : Int32) {
          decode_tuple_temporal_leaf(name, type_name, bytes, rows, width)
        },
        ->(name : String, exact_type : DateTimeColumnType, bytes : Bytes, rows : UInt64, width : Int32) {
          decode_tuple_datetime_leaf(name, exact_type, bytes, rows, width)
        },
        ->(name : String, exact_type : WideTupleParameterizedType, bytes : Bytes, rows : UInt64, width : Int32) {
          decode_tuple_parameterized_leaf(name, exact_type, bytes, rows, width)
        },
        ->(name : String, leaf_type : WideTupleLeafType, bytes : Bytes, null_map : ScalarNullMap, rows : UInt64, width : Int32) {
          decode_tuple_nullable_leaf(name, leaf_type, bytes, null_map, rows, width)
        }
      )
    end

    # Named Tuple Bool uses the same semantic value-byte policy as root and
    # nested Bool accessors: any nonzero source byte becomes true.
    private def decode_tuple_bool_leaf(
      name : String,
      bytes : Bytes,
      rows : UInt64,
      width : Int32,
    ) : WideTupleLeafColumn
      raise CorruptPartError.new("Tuple Bool stream width does not match schema") unless width == 1
      if rows > Int32::MAX.to_u64 || bytes.size != rows.to_i
        raise CorruptPartError.new("Tuple Bool stream byte count does not match rows")
      end

      values = BoolValueCodec.decode_values(bytes)
      WideTupleLeafColumn.new(name, values)
    end

    private def decode_tuple_identifier_leaf(
      name : String,
      type_name : String,
      bytes : Bytes,
      rows : UInt64,
      width : Int32,
    ) : WideTupleLeafColumn
      expected_width = WideTupleIdentifierType.width(type_name) ||
                       raise(CorruptPartError.new("Tuple identifier stream has no fixed width"))
      raise CorruptPartError.new("Tuple identifier stream width does not match schema") unless width == expected_width

      case type_name
      when "UUID" then decode_tuple_identifier_leaf(name, bytes, rows, width, UUIDValue)
      when "IPv4" then decode_tuple_identifier_leaf(name, bytes, rows, width, IPv4Value)
      when "IPv6" then decode_tuple_identifier_leaf(name, bytes, rows, width, IPv6Value)
      else
        raise UnsupportedFormatError.new("unsupported identifier Tuple leaf type")
      end
    end

    private def decode_tuple_identifier_leaf(
      name : String,
      bytes : Bytes,
      rows : UInt64,
      width : Int32,
      type : T.class,
    ) : WideTupleLeafColumn forall T
      if rows > Int32::MAX.to_u64 || rows * width.to_u64 != bytes.size.to_u64
        raise CorruptPartError.new("Tuple identifier stream byte count does not match rows")
      end

      values = Array(T).new(rows.to_i) do |index|
        offset = index * width
        {% if T == UUIDValue %}
          UUIDValue.new(u64(bytes, offset), u64(bytes, offset + 8))
        {% elsif T == IPv4Value %}
          IPv4Value.new(u32(bytes, offset))
        {% elsif T == IPv6Value %}
          IPv6Value.new(network_order_u64(bytes, offset), network_order_u64(bytes, offset + 8))
        {% else %}
          raise UnsupportedFormatError.new("unsupported identifier Tuple leaf type")
        {% end %}
      end
      WideTupleLeafColumn.new(name, values)
    end

    # Temporal Tuple leaves reuse the established exact-width little-endian
    # primitive decoders, then retain semantic type and precision in nominal
    # wrappers instead of exposing or relabeling the raw carrier.
    private def decode_tuple_temporal_leaf(
      name : String,
      type_name : String,
      bytes : Bytes,
      rows : UInt64,
      width : Int32,
    ) : WideTupleLeafColumn
      expected_width = WideTupleTemporalType.width(type_name) ||
                       raise(CorruptPartError.new("Tuple temporal stream has no fixed width"))
      raise CorruptPartError.new("Tuple temporal stream width does not match schema") unless width == expected_width
      if rows > Int32::MAX.to_u64 // expected_width.to_u64 ||
         bytes.size.to_u64 != rows * expected_width.to_u64
        raise CorruptPartError.new("Tuple temporal stream byte count does not match rows")
      end

      values = if type_name == "Date"
                 Array(DateValue).new(rows.to_i) do |index|
                   DateValue.new(decode_numeric_value(bytes, index * width, UInt16))
                 end
               elsif type_name == "Date32"
                 Array(Date32Value).new(rows.to_i) do |index|
                   Date32Value.new(decode_numeric_value(bytes, index * width, Int32))
                 end
               elsif type_name == "DateTime"
                 Array(DateTimeValue).new(rows.to_i) do |index|
                   DateTimeValue.new(decode_numeric_value(bytes, index * width, UInt32))
                 end
               elsif type_name == "Time"
                 Array(TimeValue).new(rows.to_i) do |index|
                   TimeValue.new(decode_numeric_value(bytes, index * width, Int32))
                 end
               elsif type_name.starts_with?("DateTime64(")
                 precision = WideTupleTemporalType.precision(type_name) ||
                             raise(CorruptPartError.new("Tuple DateTime64 precision is not canonical"))
                 Array(DateTime64Value).new(rows.to_i) do |index|
                   raw = decode_numeric_value(bytes, index * width, Int64)
                   DateTime64Value.new(raw, precision.to_i)
                 end
               elsif type_name.starts_with?("Time64(")
                 precision = WideTupleTemporalType.precision(type_name) ||
                             raise(CorruptPartError.new("Tuple Time64 precision is not canonical"))
                 Array(Time64Value).new(rows.to_i) do |index|
                   raw = decode_numeric_value(bytes, index * width, Int64)
                   Time64Value.new(raw, precision.to_i)
                 end
               else
                 raise UnsupportedFormatError.new("unsupported temporal Tuple leaf type")
               end
      WideTupleLeafColumn.new(name, type_name, values)
    end

    private def decode_tuple_datetime_leaf(
      name : String,
      exact_type : DateTimeColumnType,
      bytes : Bytes,
      rows : UInt64,
      width : Int32,
    ) : WideTupleLeafColumn
      raise CorruptPartError.new("Tuple DateTime descriptor is not scalar") unless exact_type.shape == DateTimeColumnType::Shape::Scalar
      expected_width = exact_type.raw_width
      raise CorruptPartError.new("Tuple DateTime stream width does not match schema") unless width == expected_width
      if rows > Int32::MAX.to_u64 // expected_width.to_u64 ||
         bytes.size.to_u64 != rows * expected_width.to_u64
        raise CorruptPartError.new("Tuple DateTime stream byte count does not match rows")
      end

      values = case exact_type.family
               when DateTimeColumnType::Family::DateTime
                 Array(DateTimeValue).new(rows.to_i) do |index|
                   DateTimeValue.new(decode_numeric_value(bytes, index * width, UInt32))
                 end
               when DateTimeColumnType::Family::DateTime64
                 precision = exact_type.precision?.not_nil!.to_i
                 Array(DateTime64Value).new(rows.to_i) do |index|
                   raw = decode_numeric_value(bytes, index * width, Int64)
                   DateTime64Value.new(raw, precision)
                 end
               else
                 raise CorruptPartError.new("Tuple DateTime descriptor family is unsupported")
               end
      WideTupleLeafColumn.new(name, exact_type, values)
    end

    # Decode the unchanged scalar physical profile, retaining raw Enum,
    # Decimal, and Bool slots beneath NULL rather than normalizing hidden
    # bytes through their non-null semantic decoders.
    private def decode_tuple_nullable_leaf(
      name : String,
      leaf_type : WideTupleLeafType,
      bytes : Bytes,
      null_map : ScalarNullMap,
      rows : UInt64,
      width : Int32,
    ) : WideTupleLeafColumn
      raise CorruptPartError.new("Tuple Nullable descriptor is not nullable") unless leaf_type.nullable?
      expected_width = leaf_type.raw_width ||
                       raise(CorruptPartError.new("Nullable Tuple leaf has no fixed payload width"))
      raise CorruptPartError.new("Nullable Tuple leaf stream width does not match schema") unless width == expected_width
      if rows > Int32::MAX.to_u64 || rows > Int32::MAX.to_u64 // width.to_u64 ||
         bytes.size.to_u64 != rows * width.to_u64 || null_map.size.to_u64 != rows
        raise CorruptPartError.new("Nullable Tuple leaf byte count does not match rows")
      end

      base_type_name = leaf_type.base_type_name
      physical : WideTupleLeafColumn::Buffer = if base_type_name == "Bool"
        Array(UInt8).new(rows.to_i) { |index| bytes[index] }
      elsif exact_type = leaf_type.parameterized_type
        case exact_type
        when WideTupleFixedStringType
          decode_tuple_parameterized_leaf(name, exact_type, bytes, rows, width).physical_values
        when WideTupleEnumType
          if exact_type.definition.kind == :enum8
            Array(Int8).new(rows.to_i) do |index|
              decode_numeric_value(bytes, index * width, Int8)
            end
          else
            Array(Int16).new(rows.to_i) do |index|
              decode_numeric_value(bytes, index * width, Int16)
            end
          end
        when WideTupleDecimalType
          case exact_type.storage_width
          when 4
            Array(Int32).new(rows.to_i) do |index|
              decode_array_decimal_value(bytes, index * width, Int32)
            end
          when 8
            Array(Int64).new(rows.to_i) do |index|
              decode_array_decimal_value(bytes, index * width, Int64)
            end
          when 16
            Array(Int128).new(rows.to_i) do |index|
              decode_array_decimal_value(bytes, index * width, Int128)
            end
          else
            Array(Int256Value).new(rows.to_i) do |index|
              decode_array_numeric_value(bytes, index * width, Int256Value)
            end
          end
        else
          raise CorruptPartError.new("Nullable Tuple parameterized descriptor is unsupported")
        end
      elsif exact_type = leaf_type.datetime_type
        decode_tuple_datetime_leaf(name, exact_type, bytes, rows, width).physical_values
      elsif WideTupleIdentifierType.width(base_type_name)
        decode_tuple_identifier_leaf(name, base_type_name, bytes, rows, width).physical_values
      elsif WideTupleTemporalType.width(base_type_name)
        decode_tuple_temporal_leaf(name, base_type_name, bytes, rows, width).physical_values
      else
        decode_tuple_numeric_leaf(name, base_type_name, bytes, rows, width).physical_values
      end

      begin
        WideTupleLeafColumn.new(name, leaf_type, physical, null_map)
      rescue ex : ArgumentError
        raise CorruptPartError.new("Nullable Tuple leaf payload is invalid")
      end
    end

    # FixedString, Enum and Decimal share one raw leaf stream but retain their
    # exact semantic descriptor in the owned nominal wrappers, including when
    # the row range is empty.
    private def decode_tuple_parameterized_leaf(
      name : String,
      exact_type : WideTupleParameterizedType,
      bytes : Bytes,
      rows : UInt64,
      width : Int32,
    ) : WideTupleLeafColumn
      expected_width = case exact_type
                       when WideTupleFixedStringType then exact_type.width
                       when WideTupleEnumType        then exact_type.width
                       when WideTupleDecimalType     then exact_type.storage_width
                       else
                         raise UnsupportedFormatError.new("unsupported parameterized Tuple descriptor")
                       end
      raise CorruptPartError.new("Tuple parameterized stream width does not match schema") unless width == expected_width
      if width <= 0 || rows > Int32::MAX.to_u64 // width.to_u64 || bytes.size.to_u64 != rows * width.to_u64
        raise CorruptPartError.new("Tuple parameterized stream byte count does not match rows")
      end

      case exact_type
      when WideTupleFixedStringType
        values = Array(FixedStringValue).new(rows.to_i) do |index|
          FixedStringValue.from_raw(width, bytes[index * width, width])
        end
        WideTupleLeafColumn.new(name, exact_type, values)
      when WideTupleEnumType
        if exact_type.definition.kind == :enum8
          values = Array(Enum8Value).new(rows.to_i) do |index|
            code = decode_numeric_value(bytes, index * width, Int8)
            unless exact_type.definition.declared?(code)
              raise CorruptPartError.new("Tuple Enum stream contains an undeclared code")
            end
            Enum8Value.new(exact_type.definition, code)
          end
          WideTupleLeafColumn.new(name, exact_type, values)
        else
          values = Array(Enum16Value).new(rows.to_i) do |index|
            code = decode_numeric_value(bytes, index * width, Int16)
            unless exact_type.definition.declared?(code)
              raise CorruptPartError.new("Tuple Enum stream contains an undeclared code")
            end
            Enum16Value.new(exact_type.definition, code)
          end
          WideTupleLeafColumn.new(name, exact_type, values)
        end
      when WideTupleDecimalType
        precision = exact_type.precision
        scale = exact_type.scale
        values = case width
                 when 4
                   Array(Decimal32Value).new(rows.to_i) do |index|
                     raw = decode_array_decimal_value(bytes, index * width, Int32)
                     Decimal32Value.new(raw, precision, scale)
                   end
                 when 8
                   Array(Decimal64Value).new(rows.to_i) do |index|
                     raw = decode_array_decimal_value(bytes, index * width, Int64)
                     Decimal64Value.new(raw, precision, scale)
                   end
                 when 16
                   Array(Decimal128Value).new(rows.to_i) do |index|
                     raw = decode_array_decimal_value(bytes, index * width, Int128)
                     Decimal128Value.new(raw, precision, scale)
                   end
                 when 32
                   Array(Decimal256TupleValue).new(rows.to_i) do |index|
                     raw = decode_array_decimal_value(bytes, index * width, Decimal256Value)
                     Decimal256TupleValue.new(raw, precision, scale)
                   end
                 else
                   raise CorruptPartError.new("Tuple Decimal width is unsupported")
                 end
        WideTupleLeafColumn.new(name, exact_type, values)
      else
        raise UnsupportedFormatError.new("unsupported parameterized Tuple descriptor")
      end
    end

    private def decode_tuple_numeric_leaf(
      name : String,
      type_name : String,
      bytes : Bytes,
      rows : UInt64,
      width : Int32,
    ) : WideTupleLeafColumn
      expected_width = WideTupleNumericType.width(type_name) ||
                       raise(CorruptPartError.new("Tuple numeric stream has no fixed width"))
      raise CorruptPartError.new("Tuple numeric stream width does not match schema") unless width == expected_width

      case type_name
      when "Int8"     then decode_tuple_numeric_leaf(name, bytes, rows, width, Int8)
      when "UInt8"    then decode_tuple_numeric_leaf(name, bytes, rows, width, UInt8)
      when "Int16"    then decode_tuple_numeric_leaf(name, bytes, rows, width, Int16)
      when "UInt16"   then decode_tuple_numeric_leaf(name, bytes, rows, width, UInt16)
      when "Int32"    then decode_tuple_numeric_leaf(name, bytes, rows, width, Int32)
      when "UInt32"   then decode_tuple_numeric_leaf(name, bytes, rows, width, UInt32)
      when "Int64"    then decode_tuple_numeric_leaf(name, bytes, rows, width, Int64)
      when "UInt64"   then decode_tuple_numeric_leaf(name, bytes, rows, width, UInt64)
      when "Int128"   then decode_tuple_numeric_leaf(name, bytes, rows, width, Int128)
      when "UInt128"  then decode_tuple_numeric_leaf(name, bytes, rows, width, UInt128)
      when "Int256"   then decode_tuple_numeric_leaf(name, bytes, rows, width, Int256Value)
      when "UInt256"  then decode_tuple_numeric_leaf(name, bytes, rows, width, UInt256Value)
      when "Float32"  then decode_tuple_numeric_leaf(name, bytes, rows, width, Float32)
      when "Float64"  then decode_tuple_numeric_leaf(name, bytes, rows, width, Float64)
      when "BFloat16" then decode_tuple_numeric_leaf(name, bytes, rows, width, BFloat16Value)
      else
        raise UnsupportedFormatError.new("unsupported numeric Tuple leaf type")
      end
    end

    private def decode_tuple_numeric_leaf(
      name : String,
      bytes : Bytes,
      rows : UInt64,
      width : Int32,
      type : T.class,
    ) : WideTupleLeafColumn forall T
      values = Array(T).new(rows.to_i) do |index|
        decode_array_numeric_value(bytes, index * width, type)
      end
      WideTupleLeafColumn.new(name, values)
    end

    private def tuple_reader_checked_range(
      plan : WideTupleTypePlan,
      column : String,
      first_mark : Int,
      mark_count : Int,
    ) : {Int32, Int32}
      reference_stream = plan.physical_streams(column).first? ||
                         raise(CorruptPartError.new("Tuple has no physical leaf streams"))
      # Validate caller-sized Int values against the real stream before the
      # private reader narrows indices to Int32 for its Proc interfaces.
      checked_stream_mark_range(@streams[reference_stream], first_mark, mark_count)
      {first_mark.to_i32, mark_count.to_i32}
    end

    private def tuple_reader_range_rows(stream_name : String, first_mark : Int32, mark_count : Int32) : UInt64
      _start_mark, _end_mark, rows = checked_stream_mark_range(@streams[stream_name], first_mark, mark_count)
      rows
    end

    private def tuple_reader_mark_rows(stream_name : String, mark_index : Int32) : UInt64
      tuple_reader_range_rows(stream_name, mark_index, 1)
    end

    private def tuple_reader_read_range(
      stream_name : String,
      first_mark : Int32,
      mark_count : Int32,
      expected_bytes : Int32,
      element_width : Int32,
      expected_rows : UInt64,
    ) : Bytes
      stream = @streams[stream_name]
      start_mark, end_mark, rows = checked_stream_mark_range(stream, first_mark, mark_count)
      raise tuple_reader_row_mismatch(stream_name) unless rows == expected_rows
      read_mark_range_bytes(stream, start_mark, end_mark, expected_bytes, element_width)
    end

    private def tuple_reader_validate_range(
      stream_name : String,
      first_mark : Int32,
      mark_count : Int32,
      expected_bytes : Int32,
      element_width : Int32,
      expected_rows : UInt64,
    ) : Nil
      stream = @streams[stream_name]
      start_mark, end_mark, rows = checked_stream_mark_range(stream, first_mark, mark_count)
      raise tuple_reader_row_mismatch(stream_name) unless rows == expected_rows
      validate_mark_range_bytes(stream, start_mark, end_mark, expected_bytes, element_width)
    end

    private def tuple_reader_row_mismatch(stream_name : String) : CorruptPartError
      if WideTupleTypePlan.for_type(@column_type).try(&.raw_string_stream?(@column, stream_name))
        CorruptPartError.new("Tuple(String) substream mark rows differ")
      else
        CorruptPartError.new("Tuple substream mark rows differ")
      end
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

    private def decode_array_decimal_value(bytes : Bytes, offset : Int, type : T.class) : T forall T
      {% if T == Int32 %}
        u32(bytes, offset).unsafe_as(Int32)
      {% elsif T == Int64 %}
        u64(bytes, offset).unsafe_as(Int64)
      {% elsif T == Int128 %}
        u128(bytes, offset).unsafe_as(Int128)
      {% elsif T == Decimal256Value %}
        Decimal256Value.from_words(
          u64(bytes, offset),
          u64(bytes, offset + 8),
          u64(bytes, offset + 16),
          u64(bytes, offset + 24)
        )
      {% else %}
        raise UnsupportedFormatError.new("only exact Decimal coefficient widths are supported")
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
      exact_bytes : Bool = true,
      & : Bytes -> Nil
    ) : Nil
      data_size = File.size(stream.data_path)
      raise CorruptPartError.new("data file exceeds limit") if data_size > MAX_DATA_FILE_BYTES
      start_offset = start_mark.compressed_offset
      end_offset = end_mark.compressed_offset
      tuple_profile = false
      empty_payload_stream = if plan = WidePart.variant_type_plan(@column_type)
                               stream.name != plan.discriminator_stream(@column)
                             elsif plan = GeometryColumnType.for_type(@column_type)
                               tuple_profile = true
                               stream.name != plan.discriminator_stream(@column)
                             elsif plan = PointColumnType.for_type(@column_type)
                               tuple_profile = true
                               plan.coordinate_streams(@column).includes?(stream.name)
                             elsif plan = GeoArrayColumnType.for_type(@column_type)
                               tuple_profile = true
                               stream.name != plan.size_stream(@column, 0)
                             elsif @column_type == "Dynamic"
                               stream.name == "#{@column}.SharedVariant.size" ||
                                 stream.name == "#{@column}.SharedVariant" ||
                                 stream.name == "#{@column}.String.size" ||
                                 stream.name == "#{@column}.String" ||
                                 stream.name == "#{@column}.UInt64"
                             elsif WidePart.supports_array_type?(@column_type)
                               WidePart.array_element_stream_names(@column, @column_type).not_nil!.includes?(stream.name)
                             elsif array_tuple_plan = WideArrayTupleTypePlan.for_type(@column_type)
                               if WideTypePlan.admitted(@column_type).nil?
                                 tuple_profile = true
                                 stream.name != array_tuple_plan.outer_size_stream(@column)
                               else
                                 false
                               end
                             elsif map_tuple_plan = WideMapTupleTypePlan.for_type(@column_type)
                               tuple_profile = true
                               stream.name != map_tuple_plan.outer_size_stream(@column)
                             elsif WidePart.supports_array_map_type?(@column_type)
                               array_map_stream_may_be_empty?(@column, stream.name)
                             elsif WidePart.map_string_numeric_value_type(@column_type)
                               stream.name == "#{@column}%2Ekeys.size" || stream.name == "#{@column}%2Ekeys" ||
                                 stream.name == "#{@column}%2Evalues"
                             elsif WidePart.map_string_nullable_numeric_value_type(@column_type)
                               stream.name == "#{@column}%2Ekeys.size" || stream.name == "#{@column}%2Ekeys" ||
                                 stream.name == "#{@column}%2Evalues.null" || stream.name == "#{@column}%2Evalues"
                             elsif WidePart.map_uint64_numeric_value_type(@column_type)
                               stream.name == "#{@column}%2Ekeys" || stream.name == "#{@column}%2Evalues"
                             elsif WidePart.map_uint64_nullable_numeric_value_type(@column_type)
                               stream.name == "#{@column}%2Ekeys" || stream.name == "#{@column}%2Evalues.null" ||
                                 stream.name == "#{@column}%2Evalues"
                             elsif WidePart.supports_map_uint64_string_type?(@column_type)
                               stream.name == "#{@column}%2Ekeys" || stream.name == "#{@column}%2Evalues.size" || stream.name == "#{@column}%2Evalues"
                             elsif WidePart.supports_map_uint64_uint64_type?(@column_type)
                               stream.name == "#{@column}%2Ekeys" || stream.name == "#{@column}%2Evalues"
                             elsif WidePart.supports_map_uint64_nullable_uint64_type?(@column_type)
                               stream.name == "#{@column}%2Ekeys" || stream.name == "#{@column}%2Evalues.null" || stream.name == "#{@column}%2Evalues"
                             elsif WidePart.map_string_array_numeric_value_type(@column_type)
                               stream.name == "#{@column}%2Ekeys.size" || stream.name == "#{@column}%2Ekeys" ||
                                 stream.name == "#{@column}%2Evalues.size1" || stream.name == "#{@column}%2Evalues"
                             elsif WidePart.map_uint64_array_numeric_value_type(@column_type)
                               stream.name == "#{@column}%2Ekeys" || stream.name == "#{@column}%2Evalues.size1" ||
                                 stream.name == "#{@column}%2Evalues"
                             elsif WidePart.supports_map_uint64_array_nullable_uint64_type?(@column_type)
                               stream.name == "#{@column}%2Ekeys" || stream.name == "#{@column}%2Evalues.size1" ||
                                 stream.name == "#{@column}%2Evalues.null" || stream.name == "#{@column}%2Evalues"
                             elsif WidePart.map_uint64_array_nullable_numeric_value_type(@column_type)
                               stream.name == "#{@column}%2Ekeys" || stream.name == "#{@column}%2Evalues.size1" ||
                                 stream.name == "#{@column}%2Evalues.null" || stream.name == "#{@column}%2Evalues"
                             elsif WidePart.supports_map_uint64_array_nullable_string_type?(@column_type)
                               stream.name == "#{@column}%2Ekeys" || stream.name == "#{@column}%2Evalues.size1" ||
                                 stream.name == "#{@column}%2Evalues.null" || stream.name == "#{@column}%2Evalues.size" ||
                                 stream.name == "#{@column}%2Evalues"
                             elsif WidePart.supports_map_uint64_array_uint64_type?(@column_type)
                               stream.name == "#{@column}%2Ekeys" || stream.name == "#{@column}%2Evalues.size1" ||
                                 stream.name == "#{@column}%2Evalues"
                             elsif WidePart.supports_map_uint64_array_string_type?(@column_type)
                               stream.name == "#{@column}%2Ekeys" || stream.name == "#{@column}%2Evalues.size1" ||
                                 stream.name == "#{@column}%2Evalues.size" || stream.name == "#{@column}%2Evalues"
                             elsif WidePart.supports_map_string_array_string_type?(@column_type)
                               stream.name == "#{@column}%2Ekeys.size" || stream.name == "#{@column}%2Ekeys" ||
                                 stream.name == "#{@column}%2Evalues.size1" || stream.name == "#{@column}%2Evalues.size" ||
                                 stream.name == "#{@column}%2Evalues"
                             elsif WidePart.supports_map_string_uint64_type?(@column_type)
                               stream.name == "#{@column}%2Ekeys.size" || stream.name == "#{@column}%2Ekeys" || stream.name == "#{@column}%2Evalues"
                             elsif WidePart.supports_map_string_array_nullable_uint64_type?(@column_type)
                               stream.name == "#{@column}%2Ekeys.size" || stream.name == "#{@column}%2Ekeys" ||
                                 stream.name == "#{@column}%2Evalues.size1" || stream.name == "#{@column}%2Evalues.null" ||
                                 stream.name == "#{@column}%2Evalues"
                             elsif WidePart.map_string_array_nullable_numeric_value_type(@column_type)
                               stream.name == "#{@column}%2Ekeys.size" || stream.name == "#{@column}%2Ekeys" ||
                                 stream.name == "#{@column}%2Evalues.size1" || stream.name == "#{@column}%2Evalues.null" ||
                                 stream.name == "#{@column}%2Evalues"
                             elsif WidePart.supports_map_string_array_nullable_string_type?(@column_type)
                               stream.name == "#{@column}%2Ekeys.size" || stream.name == "#{@column}%2Ekeys" ||
                                 stream.name == "#{@column}%2Evalues.size1" || stream.name == "#{@column}%2Evalues.null" ||
                                 stream.name == "#{@column}%2Evalues.size" || stream.name == "#{@column}%2Evalues"
                             elsif WidePart.supports_map_string_array_uint64_type?(@column_type)
                               stream.name == "#{@column}%2Ekeys.size" || stream.name == "#{@column}%2Ekeys" ||
                                 stream.name == "#{@column}%2Evalues.size1" || stream.name == "#{@column}%2Evalues"
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
                             elsif tuple_plan = WideTupleTypePlan.for_type(@column_type)
                               tuple_profile = true
                               tuple_plan.raw_string_stream?(@column, stream.name)
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
          qbit_profile = !QBitColumnType.for_type(@column_type).nil?
          geometry_profile = !GeometryColumnType.for_type(@column_type).nil?
          point_profile = !PointColumnType.for_type(@column_type).nil?
          geo_array_profile = !GeoArrayColumnType.for_type(@column_type).nil?
          if WidePart.supports_variant_type?(@column_type) || @column_type == "Dynamic" ||
             WidePart.supports_array_map_type?(@column_type) || qbit_profile || geometry_profile || point_profile || geo_array_profile
            if frame_offset > data.size.to_i64 - CompressedBlock::FRAME_HEADER_SIZE ||
               data[frame_offset.to_i + CompressedBlock::CHECKSUM_SIZE] != CompressedBlock::METHOD_LZ4
              if WidePart.supports_array_map_type?(@column_type) &&
                 !valid_compressed_frame_checksum?(data, frame_offset)
                raise CorruptPartError.new("mark does not start at a valid compressed frame")
              end
              message = if @column_type == "Dynamic"
                          "Dynamic requires LZ4 compressed streams"
                        elsif WidePart.supports_array_map_type?(@column_type)
                          "Array(Map) numeric profile requires LZ4 compressed streams"
                        elsif qbit_profile
                          "QBit requires LZ4 compressed streams"
                        elsif geometry_profile
                          "Geometry requires LZ4 compressed streams"
                        elsif point_profile
                          "Point requires LZ4 compressed streams"
                        elsif geo_array_profile
                          "Geo arrays require LZ4 compressed streams"
                        else
                          "Variant requires LZ4 compressed streams"
                        end
              raise UnsupportedFormatError.new(message)
            end
          end
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
          frame_alignment = QBitColumnType.for_type(@column_type) ? 1 : element_width
          raise CorruptPartError.new("numeric bytes are not column-type-aligned") unless selected_size % frame_alignment == 0
          yield frame.output[local_start.to_i, selected_size.to_i] if selected_size > 0
          selected_bytes += selected_size
          if current == end_offset
            raise CorruptPartError.new("data has trailing bytes after final frame") if end_mark == stream.sentinel && frame.end_offset != data_size
            break
          end
          next_offset = frame.end_offset
          break if eof_boundary && next_offset == data_size
          raise CorruptPartError.new("mark frame offset was not found") if next_offset <= frame_offset || next_offset > data_size
          if tuple_profile && end_mark != stream.sentinel && end_mark.decompressed_offset == 0 &&
             next_offset.to_u64 == end_offset
            break
          end
          frame_offset = next_offset
        end
        raise CorruptPartError.new("mark range byte count mismatch") if exact_bytes && selected_bytes != expected_bytes
      end
    end

    private def valid_compressed_frame_checksum?(data : Bytes, frame_offset : Int64) : Bool
      return false if frame_offset < 0 || frame_offset > data.size.to_i64 - CompressedBlock::FRAME_HEADER_SIZE

      header_offset = frame_offset.to_i
      compressed_size = u32(data, header_offset + CompressedBlock::CHECKSUM_SIZE + 1).to_i64
      decompressed_size = u32(data, header_offset + CompressedBlock::CHECKSUM_SIZE + 5).to_i64
      return false if compressed_size < CompressedBlock::HEADER_SIZE || compressed_size > MAX_FRAME_COMPRESSED_BYTES
      return false if decompressed_size <= 0 || decompressed_size > MAX_FRAME_DECOMPRESSED_BYTES

      frame_size = CompressedBlock::CHECKSUM_SIZE.to_i64 + compressed_size
      return false if frame_size > data.size.to_i64 - frame_offset

      actual_checksum = CityHashV1.hash128(data[header_offset + CompressedBlock::CHECKSUM_SIZE, compressed_size.to_i])
      actual_checksum == {u64(data, header_offset), u64(data, header_offset + 8)}
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
