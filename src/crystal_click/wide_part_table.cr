module CrystalClick
  alias WidePartNumericArray = Array(UInt8) | Array(UInt16) | Array(UInt32) | Array(UInt64) |
                               Array(Int8) | Array(Int16) | Array(Int32) | Array(Int64) | Array(Int128) | Array(Bool) |
                               Array(Float32) | Array(Float64) | Array(UUIDValue) | Array(IPv4Value) | Array(IPv6Value) | Array(Decimal256Value)
  alias WidePartNumericSlice = Slice(UInt8) | Slice(UInt16) | Slice(UInt32) | Slice(UInt64) |
                               Slice(Int8) | Slice(Int16) | Slice(Int32) | Slice(Int64) | Slice(Int128) | Slice(Bool) |
                               Slice(Float32) | Slice(Float64) | Slice(UUIDValue) | Slice(IPv4Value) | Slice(IPv6Value) | Slice(Decimal256Value)
  alias WidePartNullableArray = Array(UInt8?) | Array(UInt16?) | Array(UInt32?) | Array(UInt64?) |
                                Array(Int8?) | Array(Int16?) | Array(Int32?) | Array(Int64?) | Array(Int128?) | Array(Bool?) |
                                Array(Float32?) | Array(Float64?) | Array(UUIDValue?) | Array(IPv4Value?) | Array(IPv6Value?) | Array(Decimal256Value?)
  alias WidePartNullableSlice = Slice(UInt8?) | Slice(UInt16?) | Slice(UInt32?) | Slice(UInt64?) |
                                Slice(Int8?) | Slice(Int16?) | Slice(Int32?) | Slice(Int64?) | Slice(Int128?) | Slice(Bool?) |
                                Slice(Float32?) | Slice(Float64?) | Slice(UUIDValue?) | Slice(IPv4Value?) | Slice(IPv6Value?) | Slice(Decimal256Value?)
  alias WidePartNullableStringArray = Array(String?)
  alias WidePartNullableStringSlice = Slice(String?)

  # A callback view over aligned selected columns from one bounded table batch.
  # Column slices alias per-mark arrays and are valid only until the callback
  # returns; callers that need to retain values must copy them.
  struct WidePartTableBatch
    getter part_index : Int32
    getter part_name : String
    getter part_path : String
    getter mark_index : Int32
    getter mark_row_offset : UInt64
    getter part_row_offset : UInt64
    getter source_row_offset : UInt64

    @column_names : Array(String)
    @column_types : Array(String)
    @column_values : Array(WidePartNumericSlice)
    @typed_numeric_values : Hash(String, WidePartNumericSlice)
    @string_values : Hash(String, Slice(String))
    @fixed_string_values : Hash(String, Slice(String))
    @nullable_values : Hash(String, WidePartNullableSlice)
    @nullable_string_values : Hash(String, WidePartNullableStringSlice)
    @nullable_fixed_string_values : Hash(String, WidePartNullableStringSlice)
    @array_uint64_values : Hash(String, Slice(Array(UInt64)))
    @array_string_values : Hash(String, Slice(Array(String)))

    def initialize(
      @part_index : Int32,
      @part_name : String,
      @part_path : String,
      @mark_index : Int32,
      @mark_row_offset : UInt64,
      @part_row_offset : UInt64,
      @source_row_offset : UInt64,
      @column_names : Array(String),
      column_types : Array(String),
      @column_values : Array(WidePartNumericSlice),
    )
      @column_types = column_types
      @typed_numeric_values = Hash(String, WidePartNumericSlice).new
      @string_values = Hash(String, Slice(String)).new
      @fixed_string_values = Hash(String, Slice(String)).new
      @nullable_values = Hash(String, WidePartNullableSlice).new
      @nullable_string_values = Hash(String, WidePartNullableStringSlice).new
      @nullable_fixed_string_values = Hash(String, WidePartNullableStringSlice).new
      @array_uint64_values = Hash(String, Slice(Array(UInt64))).new
      @array_string_values = Hash(String, Slice(Array(String))).new
    end

    # Preserve the original UInt64 batch construction contract.
    def initialize(
      @part_index : Int32,
      @part_name : String,
      @part_path : String,
      @mark_index : Int32,
      @mark_row_offset : UInt64,
      @part_row_offset : UInt64,
      @source_row_offset : UInt64,
      @column_names : Array(String),
      column_values : Array(Slice(UInt64)),
    )
      @column_types = Array(String).new(column_values.size, "UInt64")
      @column_values = column_values.map { |values| values.as(WidePartNumericSlice) }
      @typed_numeric_values = Hash(String, WidePartNumericSlice).new
      @string_values = Hash(String, Slice(String)).new
      @fixed_string_values = Hash(String, Slice(String)).new
      @nullable_values = Hash(String, WidePartNullableSlice).new
      @nullable_string_values = Hash(String, WidePartNullableStringSlice).new
      @nullable_fixed_string_values = Hash(String, WidePartNullableStringSlice).new
      @array_uint64_values = Hash(String, Slice(Array(UInt64))).new
      @array_string_values = Hash(String, Slice(Array(String))).new
    end

    # Preserve the existing typed/hash construction contract. Batches created
    # through this overload simply have no materialized Nullable(String) data.
    def initialize(
      @part_index : Int32,
      @part_name : String,
      @part_path : String,
      @mark_index : Int32,
      @mark_row_offset : UInt64,
      @part_row_offset : UInt64,
      @source_row_offset : UInt64,
      @column_names : Array(String),
      @column_types : Array(String),
      @typed_numeric_values : Hash(String, WidePartNumericSlice),
      @string_values : Hash(String, Slice(String)),
      @nullable_values : Hash(String, WidePartNullableSlice),
    )
      @column_values = [] of WidePartNumericSlice
      @fixed_string_values = Hash(String, Slice(String)).new
      @nullable_string_values = Hash(String, WidePartNullableStringSlice).new
      @nullable_fixed_string_values = Hash(String, WidePartNullableStringSlice).new
      @array_uint64_values = Hash(String, Slice(Array(UInt64))).new
      @array_string_values = Hash(String, Slice(Array(String))).new
    end

    def initialize(
      @part_index : Int32,
      @part_name : String,
      @part_path : String,
      @mark_index : Int32,
      @mark_row_offset : UInt64,
      @part_row_offset : UInt64,
      @source_row_offset : UInt64,
      @column_names : Array(String),
      @column_types : Array(String),
      @typed_numeric_values : Hash(String, WidePartNumericSlice),
      @string_values : Hash(String, Slice(String)),
      @nullable_values : Hash(String, WidePartNullableSlice),
      @nullable_string_values : Hash(String, WidePartNullableStringSlice),
      fixed_string_values : Hash(String, Slice(String)) = Hash(String, Slice(String)).new,
      nullable_fixed_string_values : Hash(String, WidePartNullableStringSlice) = Hash(String, WidePartNullableStringSlice).new,
      @array_uint64_values : Hash(String, Slice(Array(UInt64))) = Hash(String, Slice(Array(UInt64))).new,
      @array_string_values : Hash(String, Slice(Array(String))) = Hash(String, Slice(Array(String))).new,
    )
      @column_values = [] of WidePartNumericSlice
      @fixed_string_values = fixed_string_values
      @nullable_fixed_string_values = nullable_fixed_string_values
    end

    def column_names : Array(String)
      @column_names.dup
    end

    def values_for(column : String) : Slice(UInt64)
      index = column_index(column)
      raise UnsupportedFormatError.new("UInt64 accessor requires an exact UInt64 column") unless @column_types[index] == "UInt64"
      return @typed_numeric_values[column].as(Slice(UInt64)) if @typed_numeric_values.has_key?(column)
      @column_values[index].as(Slice(UInt64))
    end

    # Return a typed view only when the caller's exact type matches the on-disk
    # declaration; equal-width signed/unsigned or float/integer reinterpretation
    # is not permitted.
    def values_for(column : String, type : T.class) : Slice(T) forall T
      index = column_index(column)
      type_name = WidePart.numeric_type_name(type)
      unless WidePart.supports_numeric_type?(type_name) && @column_types[index] == type_name
        raise UnsupportedFormatError.new("typed accessor does not match selected column type")
      end
      return @typed_numeric_values[column].as(Slice(T)) if @typed_numeric_values.has_key?(column)
      @column_values[index].as(Slice(T))
    end

    # Return raw UInt16 day codes only for an exact Date column.
    def date_codes_for(column : String) : Slice(UInt16)
      index = column_index(column)
      raise UnsupportedFormatError.new("Date accessor requires an exact Date column") unless @column_types[index] == "Date"
      return @typed_numeric_values[column].as(Slice(UInt16)) if @typed_numeric_values.has_key?(column)
      @column_values[index].as(Slice(UInt16))
    end

    # Return raw signed Int32 day codes only for an exact Date32 column.
    def date32_codes_for(column : String) : Slice(Int32)
      index = column_index(column)
      raise UnsupportedFormatError.new("Date32 accessor requires an exact Date32 column") unless @column_types[index] == "Date32"
      return @typed_numeric_values[column].as(Slice(Int32)) if @typed_numeric_values.has_key?(column)
      @column_values[index].as(Slice(Int32))
    end

    # Return raw UInt32 epoch seconds only for an exact bare DateTime column.
    def datetime_seconds_for(column : String) : Slice(UInt32)
      index = column_index(column)
      raise UnsupportedFormatError.new("DateTime accessor requires an exact DateTime column") unless @column_types[index] == "DateTime"
      return @typed_numeric_values[column].as(Slice(UInt32)) if @typed_numeric_values.has_key?(column)
      @column_values[index].as(Slice(UInt32))
    end

    # Return raw signed Int64 ticks only for a canonical DateTime64(p) column.
    def datetime64_ticks_for(column : String) : Slice(Int64)
      index = column_index(column)
      unless WidePart.datetime64_scale(@column_types[index])
        raise UnsupportedFormatError.new("DateTime64 accessor requires a canonical DateTime64(p) column")
      end
      return @typed_numeric_values[column].as(Slice(Int64)) if @typed_numeric_values.has_key?(column)
      @column_values[index].as(Slice(Int64))
    end

    def bools_for(column : String) : Slice(Bool)
      index = column_index(column)
      raise UnsupportedFormatError.new("Bool accessor requires an exact Bool column") unless @column_types[index] == "Bool"
      return @typed_numeric_values[column].as(Slice(Bool)) if @typed_numeric_values.has_key?(column)
      @column_values[index].as(Slice(Bool))
    end

    def nullable_bools_for(column : String) : Slice(Bool?)
      index = column_index(column)
      raise UnsupportedFormatError.new("Bool accessor requires an exact Nullable(Bool) column") unless WidePart.supports_nullable_bool_type?(@column_types[index])
      @nullable_values[column]?.try(&.as(Slice(Bool?))) || raise(UnsupportedFormatError.new("Nullable(Bool) column was not materialized in this batch"))
    end

    def enum8_codes_for(column : String) : Slice(Int8)
      index = column_index(column)
      unless WidePart.enum8_codes(@column_types[index]) && !@column_types[index].starts_with?("Nullable(")
        raise UnsupportedFormatError.new("Enum8 accessor requires an exact Enum8 declaration")
      end
      return @typed_numeric_values[column].as(Slice(Int8)) if @typed_numeric_values.has_key?(column)
      @column_values[index].as(Slice(Int8))
    end

    def nullable_enum8_codes_for(column : String) : Slice(Int8?)
      index = column_index(column)
      unless @column_types[index].starts_with?("Nullable(") && WidePart.enum8_codes(@column_types[index])
        raise UnsupportedFormatError.new("Enum8 accessor requires an exact Nullable(Enum8) declaration")
      end
      @nullable_values[column]?.try(&.as(Slice(Int8?))) || raise(UnsupportedFormatError.new("Nullable(Enum8) column was not materialized in this batch"))
    end

    def enum16_codes_for(column : String) : Slice(Int16)
      index = column_index(column)
      unless WidePart.enum16_codes(@column_types[index]) && !@column_types[index].starts_with?("Nullable(")
        raise UnsupportedFormatError.new("Enum16 accessor requires an exact Enum16 declaration")
      end
      return @typed_numeric_values[column].as(Slice(Int16)) if @typed_numeric_values.has_key?(column)
      @column_values[index].as(Slice(Int16))
    end

    def nullable_enum16_codes_for(column : String) : Slice(Int16?)
      index = column_index(column)
      unless @column_types[index].starts_with?("Nullable(") && WidePart.enum16_codes(@column_types[index])
        raise UnsupportedFormatError.new("Enum16 accessor requires an exact Nullable(Enum16) declaration")
      end
      @nullable_values[column]?.try(&.as(Slice(Int16?))) || raise(UnsupportedFormatError.new("Nullable(Enum16) column was not materialized in this batch"))
    end

    def decimal32_raw_for(column : String) : Slice(Int32)
      index = column_index(column)
      raise UnsupportedFormatError.new("Decimal32 accessor requires canonical Decimal(9, S)") unless WidePart.decimal32_scale(@column_types[index])
      return @typed_numeric_values[column].as(Slice(Int32)) if @typed_numeric_values.has_key?(column)
      @column_values[index].as(Slice(Int32))
    end

    def nullable_decimal32_raw_for(column : String) : Slice(Int32?)
      index = column_index(column)
      raise UnsupportedFormatError.new("Decimal32 accessor requires canonical Nullable(Decimal(9, S))") unless WidePart.nullable_decimal32_scale(@column_types[index])
      @nullable_values[column]?.try(&.as(Slice(Int32?))) || raise(UnsupportedFormatError.new("Nullable(Decimal32) column was not materialized in this batch"))
    end

    def decimal64_raw_for(column : String) : Slice(Int64)
      index = column_index(column)
      raise UnsupportedFormatError.new("Decimal64 accessor requires canonical Decimal(18, S)") unless WidePart.decimal64_scale(@column_types[index])
      return @typed_numeric_values[column].as(Slice(Int64)) if @typed_numeric_values.has_key?(column)
      @column_values[index].as(Slice(Int64))
    end

    def nullable_decimal64_raw_for(column : String) : Slice(Int64?)
      index = column_index(column)
      raise UnsupportedFormatError.new("Decimal64 accessor requires canonical Nullable(Decimal(18, S))") unless WidePart.nullable_decimal64_scale(@column_types[index])
      @nullable_values[column]?.try(&.as(Slice(Int64?))) || raise(UnsupportedFormatError.new("Nullable(Decimal64) column was not materialized in this batch"))
    end

    def decimal128_raw_for(column : String) : Slice(Int128)
      index = column_index(column)
      raise UnsupportedFormatError.new("Decimal128 accessor requires canonical Decimal(38, S)") unless WidePart.decimal128_scale(@column_types[index])
      return @typed_numeric_values[column].as(Slice(Int128)) if @typed_numeric_values.has_key?(column)
      @column_values[index].as(Slice(Int128))
    end

    def nullable_decimal128_raw_for(column : String) : Slice(Int128?)
      index = column_index(column)
      raise UnsupportedFormatError.new("Decimal128 accessor requires canonical Nullable(Decimal(38, S))") unless WidePart.nullable_decimal128_scale(@column_types[index])
      @nullable_values[column]?.try(&.as(Slice(Int128?))) || raise(UnsupportedFormatError.new("Nullable(Decimal128) column was not materialized in this batch"))
    end

    def decimal256_raw_for(column : String) : Slice(Decimal256Value)
      index = column_index(column)
      raise UnsupportedFormatError.new("Decimal256 accessor requires canonical Decimal(76, S)") unless WidePart.decimal256_scale(@column_types[index])
      return @typed_numeric_values[column].as(Slice(Decimal256Value)) if @typed_numeric_values.has_key?(column)
      @column_values[index].as(Slice(Decimal256Value))
    end

    def nullable_decimal256_raw_for(column : String) : Slice(Decimal256Value?)
      index = column_index(column)
      raise UnsupportedFormatError.new("Decimal256 accessor requires canonical Nullable(Decimal(76, S))") unless WidePart.nullable_decimal256_scale(@column_types[index])
      @nullable_values[column]?.try(&.as(Slice(Decimal256Value?))) || raise(UnsupportedFormatError.new("Nullable(Decimal256) column was not materialized in this batch"))
    end

    def uuids_for(column : String) : Slice(UUIDValue)
      index = column_index(column)
      raise UnsupportedFormatError.new("UUID accessor requires an exact UUID column") unless WidePart.supports_uuid_type?(@column_types[index])
      @typed_numeric_values[column]?.try(&.as(Slice(UUIDValue))) || @column_values[index].as(Slice(UUIDValue))
    end

    def nullable_uuids_for(column : String) : Slice(UUIDValue?)
      index = column_index(column)
      raise UnsupportedFormatError.new("UUID accessor requires an exact Nullable(UUID) column") unless WidePart.supports_nullable_uuid_type?(@column_types[index])
      @nullable_values[column]?.try(&.as(Slice(UUIDValue?))) || raise(UnsupportedFormatError.new("Nullable(UUID) column was not materialized in this batch"))
    end

    def ipv4s_for(column : String) : Slice(IPv4Value)
      index = column_index(column)
      raise UnsupportedFormatError.new("IPv4 accessor requires an exact IPv4 column") unless WidePart.supports_ipv4_type?(@column_types[index])
      return @typed_numeric_values[column].as(Slice(IPv4Value)) if @typed_numeric_values.has_key?(column)
      @column_values[index].as(Slice(IPv4Value))
    end

    def nullable_ipv4s_for(column : String) : Slice(IPv4Value?)
      index = column_index(column)
      raise UnsupportedFormatError.new("IPv4 accessor requires an exact Nullable(IPv4) column") unless WidePart.supports_nullable_ipv4_type?(@column_types[index])
      @nullable_values[column]?.try(&.as(Slice(IPv4Value?))) || raise(UnsupportedFormatError.new("Nullable(IPv4) column was not materialized in this batch"))
    end

    def ipv6s_for(column : String) : Slice(IPv6Value)
      index = column_index(column)
      raise UnsupportedFormatError.new("IPv6 accessor requires an exact IPv6 column") unless WidePart.supports_ipv6_type?(@column_types[index])
      return @typed_numeric_values[column].as(Slice(IPv6Value)) if @typed_numeric_values.has_key?(column)
      @column_values[index].as(Slice(IPv6Value))
    end

    def nullable_ipv6s_for(column : String) : Slice(IPv6Value?)
      index = column_index(column)
      raise UnsupportedFormatError.new("IPv6 accessor requires an exact Nullable(IPv6) column") unless WidePart.supports_nullable_ipv6_type?(@column_types[index])
      @nullable_values[column]?.try(&.as(Slice(IPv6Value?))) || raise(UnsupportedFormatError.new("Nullable(IPv6) column was not materialized in this batch"))
    end

    def strings_for(column : String) : Slice(String)
      index = column_index(column)
      raise UnsupportedFormatError.new("String accessor requires an exact String column") unless @column_types[index] == "String"
      @string_values[column]? || raise(UnsupportedFormatError.new("String column was not materialized in this batch"))
    end

    def low_cardinality_strings_for(column : String) : Slice(String)
      index = column_index(column)
      raise UnsupportedFormatError.new("LowCardinality(String) accessor requires an exact LowCardinality(String) column") unless @column_types[index] == "LowCardinality(String)"
      @string_values[column]? || raise(UnsupportedFormatError.new("LowCardinality(String) column was not materialized in this batch"))
    end

    def array_uint64s_for(column : String) : Slice(Array(UInt64))
      index = column_index(column)
      raise UnsupportedFormatError.new("Array(UInt64) accessor requires an exact Array(UInt64) column") unless @column_types[index] == "Array(UInt64)"
      @array_uint64_values[column]? || raise(UnsupportedFormatError.new("Array(UInt64) column was not materialized in this batch"))
    end

    def array_strings_for(column : String) : Slice(Array(String))
      index = column_index(column)
      raise UnsupportedFormatError.new("Array(String) accessor requires an exact Array(String) column") unless @column_types[index] == "Array(String)"
      @array_string_values[column]? || raise(UnsupportedFormatError.new("Array(String) column was not materialized in this batch"))
    end

    def fixed_strings_for(column : String) : Slice(String)
      index = column_index(column)
      unless WidePart.fixed_string_width(@column_types[index])
        raise UnsupportedFormatError.new("FixedString accessor requires an exact FixedString(N) column")
      end
      @fixed_string_values[column]? || raise(UnsupportedFormatError.new("FixedString column was not materialized in this batch"))
    end

    def nullable_values_for(column : String, type : T.class) : Slice(T?) forall T
      index = column_index(column)
      type_name = "Nullable(#{WidePart.numeric_type_name(type)})"
      raise UnsupportedFormatError.new("typed accessor does not match selected Nullable column type") unless @column_types[index] == type_name
      (@nullable_values[column]? || raise(UnsupportedFormatError.new("Nullable column was not materialized in this batch"))).as(Slice(T?))
    end

    def nullable_date_codes_for(column : String) : Slice(UInt16?)
      index = column_index(column)
      raise UnsupportedFormatError.new("Nullable(Date) accessor requires an exact Nullable(Date) column") unless @column_types[index] == "Nullable(Date)"
      @nullable_values[column]?.try(&.as(Slice(UInt16?))) || raise(UnsupportedFormatError.new("Nullable(Date) column was not materialized in this batch"))
    end

    def nullable_date32_codes_for(column : String) : Slice(Int32?)
      index = column_index(column)
      raise UnsupportedFormatError.new("Nullable(Date32) accessor requires an exact Nullable(Date32) column") unless @column_types[index] == "Nullable(Date32)"
      @nullable_values[column]?.try(&.as(Slice(Int32?))) || raise(UnsupportedFormatError.new("Nullable(Date32) column was not materialized in this batch"))
    end

    def nullable_datetime_seconds_for(column : String) : Slice(UInt32?)
      index = column_index(column)
      raise UnsupportedFormatError.new("Nullable(DateTime) accessor requires an exact Nullable(DateTime) column") unless @column_types[index] == "Nullable(DateTime)"
      @nullable_values[column]?.try(&.as(Slice(UInt32?))) || raise(UnsupportedFormatError.new("Nullable(DateTime) column was not materialized in this batch"))
    end

    def nullable_datetime64_ticks_for(column : String) : Slice(Int64?)
      index = column_index(column)
      unless WidePart.nullable_datetime64_scale(@column_types[index])
        raise UnsupportedFormatError.new("Nullable(DateTime64) accessor requires a canonical Nullable(DateTime64(p)) column")
      end
      @nullable_values[column]?.try(&.as(Slice(Int64?))) || raise(UnsupportedFormatError.new("Nullable(DateTime64) column was not materialized in this batch"))
    end

    def nullable_strings_for(column : String) : Slice(String?)
      index = column_index(column)
      raise UnsupportedFormatError.new("Nullable(String) accessor requires an exact Nullable(String) column") unless @column_types[index] == "Nullable(String)"
      @nullable_string_values[column]? || raise(UnsupportedFormatError.new("Nullable(String) column was not materialized in this batch"))
    end

    def nullable_fixed_strings_for(column : String) : Slice(String?)
      index = column_index(column)
      unless WidePart.nullable_fixed_string_width(@column_types[index])
        raise UnsupportedFormatError.new("Nullable(FixedString) accessor requires an exact Nullable(FixedString(N)) column")
      end
      @nullable_fixed_string_values[column]? || raise(UnsupportedFormatError.new("Nullable(FixedString) column was not materialized in this batch"))
    end

    private def column_index(column : String) : Int
      index = @column_names.index(column)
      raise UnsupportedFormatError.new("column is not selected") unless index
      index
    end
  end

  # A correctness-first reader over caller-selected immutable Wide-part paths.
  # It does not discover active parts or execute a query language. Each mark is
  # materialized for selected columns, checked for row alignment, then exposed
  # in bounded callback slices.
  class WidePartTable
    MAX_PARTS             = 1_024
    MAX_COLUMNS           =    16
    MAX_PART_NAME_BYTES   = MergeTreePartInfo::MAX_NAME_BYTES
    MAX_PART_PATH_BYTES   =         4_096
    MAX_COLUMN_NAME_BYTES =         4_096
    MAX_MARKS_PER_READER  =        65_536
    MAX_TOTAL_MARKS       = 1_000_000_u64
    # At the 16-column limit a full mark is capped at 8 MiB for the widest types.
    MAX_MARK_ROWS = 65_536_u64
    # Selected String-like payloads are preflighted and then rechecked after
    # materialization; one mark is capped independently of batch_rows.
    MAX_MARK_MATERIALIZED_BYTES = 64 * 1024 * 1024
    MAX_TOTAL_ROWS              = 100_000_000_000_u64
    DEFAULT_BATCH_ROWS          =               4_096
    MAX_BATCH_ROWS              =               4_096

    getter part_count : Int32
    getter total_row_count : UInt64
    getter checksum_verification : ChecksumVerification

    private struct ColumnReader
      getter name : String
      getter reader : WidePart

      def column_type : String
        @reader.column_type
      end

      def initialize(@name : String, @reader : WidePart)
      end
    end

    private struct PartEntry
      getter name : String
      getter path : String
      getter row_count : UInt64
      getter mark_row_counts : Array(UInt64)
      getter readers : Array(ColumnReader)
      getter column_types : Array(String)
      getter column_sources : Array({String, String, String})

      def initialize(
        @name : String,
        @path : String,
        @row_count : UInt64,
        @mark_row_counts : Array(UInt64),
        @readers : Array(ColumnReader),
        @column_types : Array(String),
        @column_sources : Array({String, String, String}),
      )
      end
    end

    @columns : Array(String)
    @entries : Array(PartEntry)
    @numeric_mode : Bool
    @typed_mode : Bool

    def self.open_selected(parts : Array(String), columns : Array(String)) : WidePartTable
      new(parts, columns, false, false)
    end

    def self.open_selected_numeric(parts : Array(String), columns : Array(String)) : WidePartTable
      new(parts, columns, true, false)
    end

    def self.open_selected_typed(parts : Array(String), columns : Array(String)) : WidePartTable
      new(parts, columns, false, true)
    end

    def columns : Array(String)
      @columns.dup
    end

    def column_types : Array({String, String})
      return [] of {String, String} if @entries.empty?
      @entries.first.readers.map { |selected| {selected.name, selected.column_type} }
    end

    # Retain the physical source identity for virtual JSON typed paths so the
    # offline table can compare full JSON schemas before exposing callbacks.
    def column_sources : Array({String, String, String})
      return [] of {String, String, String} if @entries.empty?
      @entries.first.readers.map do |selected|
        {selected.name, selected.reader.source_column_name, selected.reader.source_column_type}
      end
    end

    # Return each selected part's data-mark row counts in physical part order.
    def part_mark_row_counts : Array(Array(UInt64))
      @entries.map { |part| part.mark_row_counts.dup }
    end

    # The callback receives one row-aligned slice per selected column. Slices
    # alias the current mark arrays and must not be retained past the callback.
    def scan(batch_rows : Int = DEFAULT_BATCH_ROWS, & : WidePartTableBatch -> Nil) : Nil
      raise BoundsError.new("batch row count is out of range") if batch_rows <= 0 || batch_rows > MAX_BATCH_ROWS
      unless @entries.all? { |part| part.readers.all? { |selected| selected.column_type == "UInt64" } }
        raise UnsupportedFormatError.new("UInt64 scan requires exact UInt64 columns")
      end

      scan_rows(batch_rows) { |batch| yield batch }
    end

    # Scan only the caller-selected data marks. Each callback receives one
    # complete candidate granule; skipped marks still advance physical row
    # offsets and are never materialized.
    def scan_candidate_marks(mark_indices : Array(Array(Int32)), & : WidePartTableBatch -> Nil) : Nil
      unless @entries.all? { |part| part.readers.all? { |selected| selected.column_type == "UInt64" } }
        raise UnsupportedFormatError.new("UInt64 candidate scan requires exact UInt64 columns")
      end
      raise BoundsError.new("candidate mark list does not match selected parts") unless mark_indices.size == @entries.size

      # Validate the complete schedule before exposing the first callback.
      mark_indices.each_with_index do |part_marks, part_index|
        mark_count = @entries[part_index].mark_row_counts.size
        previous = -1
        part_marks.each do |mark_index|
          raise BoundsError.new("candidate mark index is out of range") if mark_index < 0 || mark_index >= mark_count
          raise BoundsError.new("candidate mark indices must be strictly increasing") if mark_index <= previous
          previous = mark_index
        end
      end

      source_row_offset = 0_u64
      @entries.each_with_index do |part, part_index|
        part_row_offset = 0_u64
        selected_marks = mark_indices[part_index]
        selected_index = 0
        part.mark_row_counts.each_with_index do |mark_rows, mark_index|
          if selected_index < selected_marks.size && selected_marks[selected_index] == mark_index.to_i32
            selected_index += 1
            column_values = Array(WidePartNumericArray).new(@columns.size)
            part.readers.each do |selected|
              values = read_numeric_values(selected, mark_index)
              raise CorruptPartError.new("selected column mark row count changed") unless values.size.to_u64 == mark_rows
              column_values << values
            end

            slices = Array(WidePartNumericSlice).new(column_values.size)
            column_values.each do |values|
              slices << slice_numeric_values(values, 0, values.size)
            end
            yield WidePartTableBatch.new(
              part_index.to_i32,
              part.name,
              part.path,
              mark_index.to_i32,
              0_u64,
              part_row_offset,
              source_row_offset &+ part_row_offset,
              @columns,
              part.column_types,
              slices
            )
          end
          part_row_offset &+= mark_rows
        end

        raise CorruptPartError.new("part row count changed during candidate scan") unless part_row_offset == part.row_count
        source_row_offset &+= part.row_count
      end

      raise CorruptPartError.new("source row count mismatch") unless source_row_offset == @total_row_count
      nil
    end

    # Scan selected candidate marks through the typed reader. Every selected
    # mark is exposed in one callback, while unselected marks advance offsets
    # without reading any selected column data.
    def scan_typed_candidate_marks(mark_indices : Array(Array(Int32)), & : WidePartTableBatch -> Nil) : Nil
      raise UnsupportedFormatError.new("typed candidate scan requires typed readers") unless @typed_mode
      raise BoundsError.new("candidate mark list does not match selected parts") unless mark_indices.size == @entries.size

      # Snapshot and validate the complete schedule before any callback. This
      # prevents a callback from changing later selections through the caller's
      # mutable arrays.
      validated_mark_indices = Array(Array(Int32)).new(mark_indices.size)
      mark_indices.each_with_index do |part_marks, part_index|
        mark_count = @entries[part_index].mark_row_counts.size
        validated_part_marks = part_marks.dup
        previous = -1
        validated_part_marks.each do |mark_index|
          raise BoundsError.new("candidate mark index is out of range") if mark_index < 0 || mark_index >= mark_count
          raise BoundsError.new("candidate mark indices must be strictly increasing") if mark_index <= previous
          previous = mark_index
        end
        validated_mark_indices << validated_part_marks
      end

      # All source marks are bounded by MAX_MARK_ROWS, so this batch size emits
      # a selected granule as one complete callback. whole_marks also preserves
      # the one-callback contract for a selected zero-row mark.
      scan_typed_rows(MAX_MARK_ROWS.to_i, validated_mark_indices, whole_marks: true) { |batch| yield batch }
      nil
    end

    # Scan mixed fixed-width primitive numeric columns. Typed values are
    # retrieved from each batch with values_for(column, CrystalType).
    def scan_numeric(batch_rows : Int = DEFAULT_BATCH_ROWS, & : WidePartTableBatch -> Nil) : Nil
      raise BoundsError.new("batch row count is out of range") if batch_rows <= 0 || batch_rows > MAX_BATCH_ROWS
      unless @entries.all? { |part| part.readers.all? { |selected| WidePart.supports_numeric_type?(selected.column_type) } }
        raise UnsupportedFormatError.new("numeric scan requires exact primitive numeric columns")
      end

      scan_rows(batch_rows) { |batch| yield batch }
    end

    # Scan exact String, Date/Date32 raw day codes, primitive numeric, and
    # supported Nullable columns. Each selected column's declared type is
    # retained in the callback; no equal-width reinterpretation is permitted.
    def scan_typed(batch_rows : Int = DEFAULT_BATCH_ROWS, & : WidePartTableBatch -> Nil) : Nil
      raise BoundsError.new("batch row count is out of range") if batch_rows <= 0 || batch_rows > MAX_BATCH_ROWS
      scan_typed_rows(batch_rows) { |batch| yield batch }
    end

    # Scan a bounded physical-row interval in caller-selected part order.
    # Only marks intersecting the interval have selected column payloads
    # materialized; each selected mark is still decoded under the existing
    # per-mark bounds, then the callback receives only the intersecting rows.
    def scan_typed_window(
      start_row : UInt64,
      max_rows : Int = DEFAULT_BATCH_ROWS,
      & : WidePartTableBatch -> Nil
    ) : Nil
      raise BoundsError.new("window row count is out of range") if max_rows <= 0 || max_rows > MAX_BATCH_ROWS
      raise BoundsError.new("window start is beyond the source row count") if start_row > @total_row_count
      return nil if start_row == @total_row_count

      available_rows = @total_row_count - start_row
      window_rows = max_rows.to_u64 < available_rows ? max_rows.to_u64 : available_rows
      # window_rows is bounded by total_row_count - start_row, so this addition
      # is checked by construction and cannot overflow UInt64.
      end_row = start_row + window_rows
      scan_typed_rows(max_rows, window_rows: {start_row, end_row}) { |batch| yield batch }
      nil
    end

    private def scan_typed_rows(
      batch_rows : Int,
      candidate_marks : Array(Array(Int32))? = nil,
      whole_marks : Bool = false,
      window_rows : {UInt64, UInt64}? = nil,
      & : WidePartTableBatch -> Nil
    ) : Nil
      source_row_offset = 0_u64
      @entries.each_with_index do |part, part_index|
        begin
          part_row_offset = 0_u64
          selected_marks = candidate_marks ? candidate_marks[part_index] : nil
          selected_index = 0
          part.mark_row_counts.each_with_index do |mark_rows, mark_index|
            mark_start_part_row_offset = part_row_offset
            part_row_offset &+= mark_rows

            selected_mark = true
            if part_marks = selected_marks
              selected_mark = selected_index < part_marks.size && part_marks[selected_index] == mark_index
              selected_index += 1 if selected_mark
            end
            next unless selected_mark

            selected_mark_row_start = 0_u64
            selected_mark_row_end = mark_rows
            if window = window_rows
              mark_source_start = source_row_offset &+ mark_start_part_row_offset
              mark_source_end = mark_source_start &+ mark_rows
              window_start, window_end = window
              next if mark_rows == 0_u64 || window_start >= mark_source_end || window_end <= mark_source_start

              selected_mark_row_start = window_start > mark_source_start ? window_start - mark_source_start : 0_u64
              selected_mark_row_end = window_end < mark_source_end ? window_end - mark_source_start : mark_rows
            end

            # Selected String, Nullable(String), and fixed-width String payloads are
            # preflighted before any String array is allocated. The immutable-
            # parts contract is not transactional; the actual aggregate is
            # checked again before callback exposure.
            preflight_string_bytes = 0_u64
            part.readers.each do |selected|
              if selected.column_type == "String" || WidePart.supports_nullable_string_type?(selected.column_type)
                bytes = if selected.column_type == "String"
                          selected.reader.string_mark_range_raw_bytes(selected.name, mark_index, 1)
                        else
                          selected.reader.nullable_string_mark_range_raw_bytes(selected.name, mark_index, 1)
                        end
              elsif selected.column_type == "LowCardinality(String)"
                bytes = selected.reader.low_cardinality_string_mark_range_raw_bytes(selected.name, mark_index, 1)
              elsif WidePart.fixed_string_width(selected.column_type)
                bytes = selected.reader.fixed_string_mark_range_raw_bytes(selected.name, mark_index, 1)
              elsif WidePart.nullable_fixed_string_width(selected.column_type)
                bytes = selected.reader.nullable_fixed_string_mark_range_raw_bytes(selected.name, mark_index, 1)
              elsif selected.column_type == "Array(UInt64)"
                bytes = selected.reader.array_uint64_mark_range_raw_bytes(selected.name, mark_index, 1)
              elsif selected.column_type == "Array(String)"
                bytes = selected.reader.array_string_mark_range_raw_bytes(selected.name, mark_index, 1)
              else
                next
              end
              if bytes > (MAX_MARK_MATERIALIZED_BYTES.to_u64 - preflight_string_bytes)
                raise CorruptPartError.new("selected String mark exceeds aggregate materialization limit")
              end
              preflight_string_bytes += bytes
            end

            numeric_values = Hash(String, WidePartNumericArray).new
            string_values = Hash(String, Array(String)).new
            fixed_string_values = Hash(String, Array(String)).new
            nullable_values = Hash(String, WidePartNullableArray).new
            nullable_string_values = Hash(String, WidePartNullableStringArray).new
            nullable_fixed_string_values = Hash(String, WidePartNullableStringArray).new
            array_uint64_values = Hash(String, Array(Array(UInt64))).new
            array_string_values = Hash(String, Array(Array(String))).new
            actual_string_bytes = 0_u64
            part.readers.each do |selected|
              case selected.column_type
              when "String"
                values = selected.reader.read_string_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected String mark row count changed") unless values.size.to_u64 == mark_rows
                values.each do |value|
                  bytes = value.bytesize.to_u64
                  raise CorruptPartError.new("selected String mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                  actual_string_bytes += bytes
                end
                string_values[selected.name] = values
              when "LowCardinality(String)"
                values = selected.reader.read_low_cardinality_string_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected LowCardinality(String) mark row count changed") unless values.size.to_u64 == mark_rows
                values.each do |value|
                  bytes = value.bytesize.to_u64
                  raise CorruptPartError.new("selected LowCardinality(String) mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                  actual_string_bytes += bytes
                end
                string_values[selected.name] = values
              when "Nullable(String)"
                values, bytes = selected.reader.read_nullable_string_mark_range_with_raw_bytes(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Nullable(String) mark row count changed") unless values.size.to_u64 == mark_rows
                raise CorruptPartError.new("selected Nullable(String) mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                nullable_string_values[selected.name] = values
              when .starts_with?("FixedString(")
                values = selected.reader.read_fixed_string_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected FixedString mark row count changed") unless values.size.to_u64 == mark_rows
                width = WidePart.fixed_string_width(selected.column_type) || raise(UnsupportedFormatError.new("unsupported exact FixedString type"))
                bytes = values.size.to_u64 * width.to_u64
                raise CorruptPartError.new("selected FixedString mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                fixed_string_values[selected.name] = values
              when .starts_with?("Nullable(FixedString(")
                width = WidePart.nullable_fixed_string_width(selected.column_type) || raise(UnsupportedFormatError.new("unsupported exact Nullable(FixedString) type"))
                values = selected.reader.read_nullable_fixed_string_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Nullable(FixedString) mark row count changed") unless values.size.to_u64 == mark_rows
                bytes = values.size.to_u64 * width.to_u64
                raise CorruptPartError.new("selected Nullable(FixedString) mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                nullable_fixed_string_values[selected.name] = values
              when "Array(UInt64)"
                values = selected.reader.read_array_uint64_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Array(UInt64) mark row count changed") unless values.size.to_u64 == mark_rows
                elements = values.sum(&.size).to_u64
                bytes = elements * 8_u64
                raise CorruptPartError.new("selected array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_uint64_values[selected.name] = values
              when "Array(String)"
                values = selected.reader.read_array_string_mark_range(selected.name, mark_index, 1)
                raise CorruptPartError.new("selected Array(String) mark row count changed") unless values.size.to_u64 == mark_rows
                bytes = values.sum { |row| row.sum(&.bytesize) }.to_u64
                raise CorruptPartError.new("selected array mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
                array_string_values[selected.name] = values
              when .starts_with?("Nullable(")
                values = read_nullable_values(selected, mark_index)
                raise CorruptPartError.new("selected Nullable mark row count changed") unless nullable_array_size(values).to_u64 == mark_rows
                nullable_values[selected.name] = values
              else
                values = read_numeric_values(selected, mark_index)
                raise CorruptPartError.new("selected column mark row count changed") unless values.size.to_u64 == mark_rows
                numeric_values[selected.name] = values
              end
            end

            mark_row_offset = selected_mark_row_start
            first_whole_mark_batch = whole_marks
            while mark_row_offset < selected_mark_row_end || first_whole_mark_batch
              first_whole_mark_batch = false
              remaining = selected_mark_row_end - mark_row_offset
              size = if whole_marks
                       remaining.to_i
                     else
                       remaining < batch_rows.to_u64 ? remaining.to_i : batch_rows
                     end
              numeric_slices = Hash(String, WidePartNumericSlice).new
              string_slices = Hash(String, Slice(String)).new
              fixed_string_slices = Hash(String, Slice(String)).new
              nullable_slices = Hash(String, WidePartNullableSlice).new
              nullable_string_slices = Hash(String, WidePartNullableStringSlice).new
              nullable_fixed_string_slices = Hash(String, WidePartNullableStringSlice).new
              array_uint64_slices = Hash(String, Slice(Array(UInt64))).new
              array_string_slices = Hash(String, Slice(Array(String))).new
              part.readers.each do |selected|
                if values = numeric_values[selected.name]?
                  numeric_slices[selected.name] = slice_numeric_values(values, mark_row_offset.to_i, size)
                elsif values = string_values[selected.name]?
                  string_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = fixed_string_values[selected.name]?
                  fixed_string_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = nullable_values[selected.name]?
                  nullable_slices[selected.name] = slice_nullable_values(values, mark_row_offset.to_i, size)
                elsif values = nullable_string_values[selected.name]?
                  nullable_string_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = nullable_fixed_string_values[selected.name]?
                  nullable_fixed_string_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = array_uint64_values[selected.name]?
                  array_uint64_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                elsif values = array_string_values[selected.name]?
                  array_string_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
                else
                  raise CorruptPartError.new("selected typed column was not materialized")
                end
              end
              batch = WidePartTableBatch.new(
                part_index.to_i32,
                part.name,
                part.path,
                mark_index.to_i32,
                mark_row_offset,
                mark_start_part_row_offset &+ mark_row_offset,
                source_row_offset &+ mark_start_part_row_offset &+ mark_row_offset,
                @columns,
                part.column_types,
                numeric_slices,
                string_slices,
                nullable_slices,
                nullable_string_slices,
                fixed_string_slices,
                nullable_fixed_string_slices,
                array_uint64_slices,
                array_string_slices
              )
              yield batch
              mark_row_offset &+= size.to_u64
              break if whole_marks
            end
          end

          raise CorruptPartError.new("part row count changed during scan") unless part_row_offset == part.row_count
          source_row_offset &+= part.row_count
        ensure
          part.readers.each do |selected|
            selected.reader.release_low_cardinality_string_scan_cache if selected.column_type == "LowCardinality(String)"
          end
        end
      end

      raise CorruptPartError.new("source row count mismatch") unless source_row_offset == @total_row_count
      nil
    end

    private def scan_rows(batch_rows : Int, & : WidePartTableBatch -> Nil) : Nil
      source_row_offset = 0_u64
      @entries.each_with_index do |part, part_index|
        part_row_offset = 0_u64
        part.mark_row_counts.each_with_index do |mark_rows, mark_index|
          column_values = Array(WidePartNumericArray).new(@columns.size)
          part.readers.each do |selected|
            values = read_numeric_values(selected, mark_index)
            raise CorruptPartError.new("selected column mark row count changed") unless values.size.to_u64 == mark_rows
            column_values << values
          end

          mark_row_offset = 0_u64
          while mark_row_offset < mark_rows
            remaining = mark_rows - mark_row_offset
            size = remaining < batch_rows.to_u64 ? remaining.to_i : batch_rows
            slices = Array(WidePartNumericSlice).new(column_values.size)
            column_values.each do |values|
              slices << slice_numeric_values(values, mark_row_offset.to_i, size)
            end
            batch = WidePartTableBatch.new(
              part_index.to_i32,
              part.name,
              part.path,
              mark_index.to_i32,
              mark_row_offset,
              # Preflight bounds each part and the concatenated source before
              # these additions; WidePart also proves marks sum to row_count.
              part_row_offset &+ mark_row_offset,
              source_row_offset &+ part_row_offset &+ mark_row_offset,
              @columns,
              part.column_types,
              slices
            )
            yield batch
            mark_row_offset &+= size.to_u64
          end

          part_row_offset &+= mark_rows
        end

        raise CorruptPartError.new("part row count changed during scan") unless part_row_offset == part.row_count
        source_row_offset &+= part.row_count
      end

      raise CorruptPartError.new("source row count mismatch") unless source_row_offset == @total_row_count
      nil
    end

    private def read_numeric_values(selected : ColumnReader, mark_index : Int) : WidePartNumericArray
      reader = selected.reader
      type = selected.column_type
      if WidePart.supports_uuid_type?(type)
        return reader.read_uuids_mark_range(selected.name, mark_index, 1)
      elsif WidePart.supports_ipv4_type?(type)
        return reader.read_ipv4s_mark_range(selected.name, mark_index, 1)
      elsif WidePart.supports_ipv6_type?(type)
        return reader.read_ipv6s_mark_range(selected.name, mark_index, 1)
      elsif type == "Bool"
        return reader.read_bool_mark_range(selected.name, mark_index, 1)
      elsif !WidePart.enum8_codes(type).nil? && !type.starts_with?("Nullable(")
        return reader.read_enum8_codes_mark_range(selected.name, mark_index, 1)
      elsif !WidePart.enum16_codes(type).nil? && !type.starts_with?("Nullable(")
        return reader.read_enum16_codes_mark_range(selected.name, mark_index, 1)
      elsif !WidePart.decimal32_scale(type).nil?
        return reader.read_decimal32_raw_mark_range(selected.name, mark_index, 1)
      elsif !WidePart.decimal64_scale(type).nil?
        return reader.read_decimal64_raw_mark_range(selected.name, mark_index, 1)
      elsif !WidePart.decimal128_scale(type).nil?
        return reader.read_decimal128_raw_mark_range(selected.name, mark_index, 1)
      elsif !WidePart.decimal256_scale(type).nil?
        return reader.read_decimal256_raw_mark_range(selected.name, mark_index, 1)
      end

      case selected.column_type
      when "Date"
        reader.read_date_codes_mark_range(selected.name, mark_index, 1)
      when "Date32"
        reader.read_date32_codes_mark_range(selected.name, mark_index, 1)
      when "DateTime"
        reader.read_datetime_seconds_mark_range(selected.name, mark_index, 1)
      when .starts_with?("DateTime64(")
        unless WidePart.datetime64_scale(selected.column_type)
          raise UnsupportedFormatError.new("unsupported exact DateTime64 type")
        end
        reader.read_datetime64_ticks_mark_range(selected.name, mark_index, 1)
      when "UInt8"
        reader.read_numeric_mark_range(selected.name, mark_index, 1, UInt8)
      when "UInt16"
        reader.read_numeric_mark_range(selected.name, mark_index, 1, UInt16)
      when "UInt32"
        reader.read_numeric_mark_range(selected.name, mark_index, 1, UInt32)
      when "UInt64"
        reader.read_numeric_mark_range(selected.name, mark_index, 1, UInt64)
      when "Int8"
        reader.read_numeric_mark_range(selected.name, mark_index, 1, Int8)
      when "Int16"
        reader.read_numeric_mark_range(selected.name, mark_index, 1, Int16)
      when "Int32"
        reader.read_numeric_mark_range(selected.name, mark_index, 1, Int32)
      when "Int64"
        reader.read_numeric_mark_range(selected.name, mark_index, 1, Int64)
      when "Float32"
        reader.read_numeric_mark_range(selected.name, mark_index, 1, Float32)
      when "Float64"
        reader.read_numeric_mark_range(selected.name, mark_index, 1, Float64)
      else
        raise UnsupportedFormatError.new("unsupported numeric column type")
      end
    end

    private def slice_numeric_values(values : WidePartNumericArray, offset : Int, size : Int) : WidePartNumericSlice
      case values
      when Array(UInt8)
        values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(UInt16)
        values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(UInt32)
        values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(UInt64)
        values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Int8)
        values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Int16)
        values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Int32)
        values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Int64)
        values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Int128)
        values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Decimal256Value)
        values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Bool)
        values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Float32)
        values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Float64)
        values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(UUIDValue)
        values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(IPv4Value)
        values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(IPv6Value)
        values.to_unsafe.to_slice(values.size)[offset, size]
      else
        raise UnsupportedFormatError.new("unsupported numeric column type")
      end
    end

    private def read_nullable_values(selected : ColumnReader, mark_index : Int) : WidePartNullableArray
      reader = selected.reader
      type = selected.column_type
      if WidePart.supports_nullable_uuid_type?(type)
        return reader.read_nullable_uuids_mark_range(selected.name, mark_index, 1)
      elsif WidePart.supports_nullable_ipv4_type?(type)
        return reader.read_nullable_ipv4s_mark_range(selected.name, mark_index, 1)
      elsif WidePart.supports_nullable_ipv6_type?(type)
        return reader.read_nullable_ipv6s_mark_range(selected.name, mark_index, 1)
      elsif type == "Nullable(Bool)"
        return reader.read_nullable_bool_mark_range(selected.name, mark_index, 1)
      elsif !WidePart.enum8_codes(type).nil? && type.starts_with?("Nullable(")
        return reader.read_nullable_enum8_codes_mark_range(selected.name, mark_index, 1)
      elsif !WidePart.enum16_codes(type).nil? && type.starts_with?("Nullable(")
        return reader.read_nullable_enum16_codes_mark_range(selected.name, mark_index, 1)
      elsif !WidePart.nullable_decimal32_scale(type).nil?
        return reader.read_nullable_decimal32_raw_mark_range(selected.name, mark_index, 1)
      elsif !WidePart.nullable_decimal64_scale(type).nil?
        return reader.read_nullable_decimal64_raw_mark_range(selected.name, mark_index, 1)
      elsif !WidePart.nullable_decimal128_scale(type).nil?
        return reader.read_nullable_decimal128_raw_mark_range(selected.name, mark_index, 1)
      elsif !WidePart.nullable_decimal256_scale(type).nil?
        return reader.read_nullable_decimal256_raw_mark_range(selected.name, mark_index, 1)
      end

      case selected.column_type
      when "Nullable(Date)"     then reader.read_nullable_date_codes_mark_range(selected.name, mark_index, 1)
      when "Nullable(Date32)"   then reader.read_nullable_date32_codes_mark_range(selected.name, mark_index, 1)
      when "Nullable(DateTime)" then reader.read_nullable_datetime_seconds_mark_range(selected.name, mark_index, 1)
      when "Nullable(UInt8)"    then reader.read_nullable_numeric_mark_range(selected.name, mark_index, 1, UInt8)
      when "Nullable(UInt16)"   then reader.read_nullable_numeric_mark_range(selected.name, mark_index, 1, UInt16)
      when "Nullable(UInt32)"   then reader.read_nullable_numeric_mark_range(selected.name, mark_index, 1, UInt32)
      when "Nullable(UInt64)"   then reader.read_nullable_numeric_mark_range(selected.name, mark_index, 1, UInt64)
      when "Nullable(Int8)"     then reader.read_nullable_numeric_mark_range(selected.name, mark_index, 1, Int8)
      when "Nullable(Int16)"    then reader.read_nullable_numeric_mark_range(selected.name, mark_index, 1, Int16)
      when "Nullable(Int32)"    then reader.read_nullable_numeric_mark_range(selected.name, mark_index, 1, Int32)
      when "Nullable(Int64)"    then reader.read_nullable_numeric_mark_range(selected.name, mark_index, 1, Int64)
      when "Nullable(Float32)"  then reader.read_nullable_numeric_mark_range(selected.name, mark_index, 1, Float32)
      when "Nullable(Float64)"  then reader.read_nullable_numeric_mark_range(selected.name, mark_index, 1, Float64)
      else
        if WidePart.nullable_datetime64_scale(selected.column_type)
          return reader.read_nullable_datetime64_ticks_mark_range(selected.name, mark_index, 1)
        end
        raise UnsupportedFormatError.new("unsupported Nullable numeric column type")
      end
    end

    private def nullable_array_size(values : WidePartNullableArray) : Int
      case values
      when Array(UInt8?)           then values.size
      when Array(UInt16?)          then values.size
      when Array(UInt32?)          then values.size
      when Array(UInt64?)          then values.size
      when Array(Int8?)            then values.size
      when Array(Int16?)           then values.size
      when Array(Int32?)           then values.size
      when Array(Int64?)           then values.size
      when Array(Int128?)          then values.size
      when Array(Decimal256Value?) then values.size
      when Array(Bool?)            then values.size
      when Array(Float32?)         then values.size
      when Array(Float64?)         then values.size
      when Array(UUIDValue?)       then values.size
      when Array(IPv4Value?)       then values.size
      when Array(IPv6Value?)       then values.size
      else
        raise UnsupportedFormatError.new("unsupported Nullable numeric column type")
      end
    end

    private def slice_nullable_values(values : WidePartNullableArray, offset : Int, size : Int) : WidePartNullableSlice
      case values
      when Array(UInt8?)           then values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(UInt16?)          then values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(UInt32?)          then values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(UInt64?)          then values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Int8?)            then values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Int16?)           then values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Int32?)           then values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Int64?)           then values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Int128?)          then values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Decimal256Value?) then values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Bool?)            then values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Float32?)         then values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Float64?)         then values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(UUIDValue?)       then values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(IPv4Value?)       then values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(IPv6Value?)       then values.to_unsafe.to_slice(values.size)[offset, size]
      else
        raise UnsupportedFormatError.new("unsupported Nullable numeric column type")
      end
    end

    private def initialize(parts : Array(String), columns : Array(String), @numeric_mode : Bool, @typed_mode : Bool)
      raise BoundsError.new("no parts selected") if parts.empty?
      raise BoundsError.new("part count exceeds limit") if parts.size > MAX_PARTS
      raise BoundsError.new("no columns selected") if columns.empty?
      raise BoundsError.new("column count exceeds limit") if columns.size > MAX_COLUMNS

      @columns = Array(String).new(columns.size)
      seen_columns = Set(String).new
      columns.each do |column|
        raise BoundsError.new("column name is empty or exceeds limit") if column.empty? || column.bytesize > MAX_COLUMN_NAME_BYTES
        raise BoundsError.new("duplicate selected column") if seen_columns.includes?(column)
        seen_columns << column
        @columns << column.dup
      end

      @entries = Array(PartEntry).new(parts.size)
      seen_paths = Set(String).new
      selected_parts = Array({String, String, MergeTreePartInfo}).new(parts.size)
      parts.each do |requested_path|
        path, name, info = validate_selected_part(requested_path)
        raise BoundsError.new("duplicate selected part path") if seen_paths.includes?(path)
        seen_paths << path
        selected_parts << {path, name, info}
      end
      reject_overlapping_parts(selected_parts)

      total_rows = 0_u64
      total_marks = 0_u64
      expected_column_types = nil.as(Array(String)?)
      expected_column_sources = nil.as(Array({String, String, String})?)

      # selected_parts remains in caller order. The parsed identities above
      # are used only for the overlap guard; they do not imply Active status.
      selected_parts.each do |selected_part|
        path = selected_part[0]
        name = selected_part[1]
        readers = Array(ColumnReader).new(@columns.size)
        expected_mark_rows = nil.as(Array(UInt64)?)
        expected_row_count = nil.as(UInt64?)
        checksums = PartChecksums.open(path)

        @columns.each do |column|
          reader = if @numeric_mode
                     WidePart.open_numeric(path, column)
                   elsif @typed_mode
                     WidePart.open_typed(path, column)
                   else
                     WidePart.open(path, column)
                   end
          raise BoundsError.new("mark count exceeds per-reader limit") if reader.mark_count > MAX_MARKS_PER_READER
          mark_rows = reader.mark_row_counts
          mark_rows.each do |rows|
            raise BoundsError.new("mark row count exceeds limit") if rows > MAX_MARK_ROWS
          end

          if current_rows = expected_row_count
            raise CorruptPartError.new("selected columns have different row counts") unless reader.row_count == current_rows
          else
            expected_row_count = reader.row_count
          end

          if current_marks = expected_mark_rows
            raise CorruptPartError.new("selected columns have different mark row counts") unless mark_rows == current_marks
          else
            expected_mark_rows = mark_rows
          end

          reader.selected_checksum_names.each do |checksum_name|
            checksums.validate_selected_entries(path, checksum_name)
          end
          readers << ColumnReader.new(column, reader)
          total_marks = checked_total_marks(total_marks, reader.mark_count.to_u64)
        end

        current_column_types = readers.map(&.column_type)
        current_column_sources = readers.map do |selected|
          {selected.name, selected.reader.source_column_name, selected.reader.source_column_type}
        end
        if current_types = expected_column_types
          raise CorruptPartError.new("selected columns have different types across parts") unless current_column_types == current_types
        else
          expected_column_types = current_column_types
        end
        if current_sources = expected_column_sources
          raise CorruptPartError.new("selected columns have different source schemas across parts") unless current_column_sources == current_sources
        else
          expected_column_sources = current_column_sources
        end

        row_count = expected_row_count || raise(CorruptPartError.new("selected part has no readers"))
        mark_row_counts = expected_mark_rows || raise(CorruptPartError.new("selected part has no mark rows"))
        total_rows = checked_total_rows(total_rows, row_count)
        @entries << PartEntry.new(name, path, row_count, mark_row_counts, readers, current_column_types, current_column_sources)
      end

      @part_count = @entries.size.to_i32
      @total_row_count = total_rows
      @checksum_verification = ChecksumVerification::SizeChecked
    end

    private def validate_selected_part(requested_path : String) : {String, String, MergeTreePartInfo}
      raise BoundsError.new("part path is empty or exceeds limit") if requested_path.empty? || requested_path.bytesize > MAX_PART_PATH_BYTES
      path = File.expand_path(requested_path)
      name = File.basename(path)
      raise BoundsError.new("part name exceeds limit") if name.bytesize > MAX_PART_NAME_BYTES
      info = MergeTreePartInfo.parse(name) || raise(InvalidPartError.new("invalid selected part name: #{name}"))
      raise UnsupportedFormatError.new("patch parts are not supported") if info.patch?
      raise InvalidPartError.new("selected part is a symbolic link: #{name}") if File.symlink?(path)
      raise InvalidPartError.new("selected part is not a directory: #{name}") unless Dir.exists?(path)
      {path, name, info}
    rescue ex : IO::Error
      raise InvalidPartError.new(ex.message || "cannot read selected part")
    end

    private def reject_overlapping_parts(parts : Array({String, String, MergeTreePartInfo})) : Nil
      parts.each_with_index do |left, left_index|
        (left_index + 1...parts.size).each do |right_index|
          right = parts[right_index]
          if left[2].overlaps?(right[2])
            raise InvalidPartError.new("selected parts overlap: #{left[1]} and #{right[1]}")
          end
        end
      end
    end

    private def checked_total_rows(total : UInt64, rows : UInt64) : UInt64
      raise BoundsError.new("total row count exceeds limit") if rows > MAX_TOTAL_ROWS - total
      total + rows
    end

    private def checked_total_marks(total : UInt64, marks : UInt64) : UInt64
      raise BoundsError.new("total mark count exceeds limit") if marks > MAX_TOTAL_MARKS - total
      total + marks
    end
  end
end
